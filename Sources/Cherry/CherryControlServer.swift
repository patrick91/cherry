import CherryControl
import Darwin
import Foundation

final class CherryControlServer: @unchecked Sendable {
    private weak var workspace: TerminalWorkspace?
    private let workspaceProvider: @MainActor () -> TerminalWorkspace?
    private let socketURL: URL
    private let queue = DispatchQueue(label: "Cherry.ControlServer", qos: .userInitiated)
    private var listenFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(workspace: TerminalWorkspace, socketURL: URL = CherryControl.socketURL) {
        self.workspace = workspace
        self.workspaceProvider = { workspace }
        self.socketURL = socketURL
    }

    init(workspaceProvider: @escaping @MainActor () -> TerminalWorkspace?, socketURL: URL = CherryControl.socketURL) {
        self.workspace = nil
        self.workspaceProvider = workspaceProvider
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    func start() {
        guard acceptSource == nil else { return }

        do {
            try prepareSocketDirectory()
            try bindAndListen()
        } catch {
            fputs("[control] failed to start: \(error.localizedDescription)\n", stderr)
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFileDescriptor >= 0 {
            close(listenFileDescriptor)
            listenFileDescriptor = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func prepareSocketDirectory() throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        chmod(directoryURL.path, S_IRWXU)
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func bindAndListen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            close(fd)
            throw CherryControlError(code: "socket_path_too_long", message: "Control socket path is too long.")
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { pathPointer in
                let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                strncpy(rawPointer, pathPointer, maximumPathLength)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, length)
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        chmod(path, S_IRUSR | S_IWUSR)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        listenFileDescriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    private nonisolated func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFileDescriptor, nil, nil)
            if clientFD >= 0 {
                handleConnection(fileDescriptor: clientFD)
                continue
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private nonisolated func handleConnection(fileDescriptor clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                close(clientFD)
                return
            }

            let requestData: Data
            do {
                requestData = try Self.readRequest(fileDescriptor: clientFD)
            } catch {
                Self.writeResponse(.init(error: Self.controlError(from: error)), to: clientFD)
                close(clientFD)
                return
            }

            Task { @MainActor [weak self] in
                let response: CherryControlResponse
                if let self {
                    response = await self.handleRequestData(requestData)
                } else {
                    response = .init(error: .init(code: "server_unavailable", message: "Cherry control server is unavailable."))
                }

                Self.writeResponse(response, to: clientFD)
                close(clientFD)
            }
        }
    }

    @MainActor
    private func handleRequestData(_ data: Data) async -> CherryControlResponse {
        do {
            let request = try JSONDecoder().decode(CherryControlRequest.self, from: data)
            return try await handle(request)
        } catch let error as CherryControlError {
            return .init(error: error)
        } catch {
            return .init(error: .init(code: "invalid_request", message: error.localizedDescription))
        }
    }

    @MainActor
    private func handle(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        guard let workspace = workspace ?? workspaceProvider() else {
            throw CherryControlError(code: "workspace_unavailable", message: "Cherry workspace is unavailable.")
        }

        switch request {
        case .listTerminals:
            return .init(result: .listTerminals(listTerminals(workspace: workspace)))
        case .createTerminal(let request):
            let session = workspace.addSession(
                title: request.title,
                workingDirectory: request.workingDirectory,
                command: request.command,
                select: false
            )
            return .init(result: .createTerminal(summary(for: session)))
        case .selectTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            workspace.select(session)
            return .init(result: .selectTerminal(.init(terminalID: session.id.uuidString, selected: true)))
        case .sendInput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            let payload = try inputPayload(from: request)
            session.send(data: payload)
            let waitMilliseconds = min(max(request.waitMilliseconds ?? 0, 0), 5_000)
            let lineLimit = min(max(request.lineLimit ?? 200, 1), 2_000)
            if waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
            }
            let output = waitMilliseconds > 0 ? terminalOutput(for: session, startLine: nil, lineLimit: lineLimit) : nil
            return .init(result: .sendInput(.init(terminalID: session.id.uuidString, sentBytes: payload.count, output: output)))
        case .getTerminalOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .getTerminalOutput(terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)))
        case .getTerminalRawOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .getTerminalRawOutput(rawOutput(for: session, maxBytes: request.maxBytes)))
        case .searchOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .searchOutput(searchOutput(for: session, request: request)))
        case .clearOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            session.clearScrollback()
            return .init(result: .clearOutput(.init(terminalID: session.id.uuidString, cleared: true)))
        case .restartTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            session.restart()
            return .init(result: .restartTerminal(summary(for: session)))
        case .closeTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            guard workspace.sessions.count > 1 else {
                throw CherryControlError(code: "last_terminal", message: "Cherry cannot close the last remaining terminal.")
            }
            workspace.close(session)
            return .init(result: .closeTerminal(.init(terminalID: session.id.uuidString, closed: true)))
        }
    }

    @MainActor
    private func listTerminals(workspace: TerminalWorkspace) -> ListTerminalsResult {
        ListTerminalsResult(
            terminals: workspace.sessions.map { session in
                TerminalInfo(
                    id: session.id.uuidString,
                    title: session.title,
                    state: session.state.label,
                    selected: workspace.selectedSessionID == session.id,
                    workingDirectory: session.workingDirectory,
                    lineCount: session.lineCount,
                    kind: session.kind.rawValue,
                    agentName: session.agentName
                )
            },
            selectedTerminalID: workspace.selectedSessionID?.uuidString
        )
    }

    @MainActor
    private func findSession(workspace: TerminalWorkspace, terminalID: String) throws -> TerminalSession {
        guard let session = workspace.session(id: terminalID) else {
            throw CherryControlError(code: "terminal_not_found", message: "No Cherry terminal exists with id \(terminalID).")
        }
        return session
    }

    @MainActor
    private func summary(for session: TerminalSession) -> TerminalSummaryResult {
        TerminalSummaryResult(
            terminalID: session.id.uuidString,
            title: session.title,
            state: session.state.label,
            kind: session.kind.rawValue,
            agentName: session.agentName
        )
    }

    private func inputPayload(from request: SendInputRequest) throws -> Data {
        switch (request.text, request.rawBase64) {
        case let (text?, nil):
            return Data(text.utf8)
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            return data
        default:
            throw CherryControlError(code: "invalid_input", message: "Provide exactly one of text or raw_base64.")
        }
    }

    @MainActor
    private func terminalOutput(for session: TerminalSession, startLine requestedStartLine: Int?, lineLimit requestedLineLimit: Int?) -> TerminalOutputResult {
        let totalLines = session.lineCount
        let lineLimit = min(max(requestedLineLimit ?? 200, 1), 2_000)
        let startLine = requestedStartLine.map { min(max($0, 0), totalLines) } ?? max(0, totalLines - lineLimit)
        let endLine = min(totalLines, startLine + lineLimit)
        let lines = startLine < endLine ? session.snapshot(range: startLine..<endLine) : []
        return TerminalOutputResult(
            terminalID: session.id.uuidString,
            startLine: startLine,
            endLineExclusive: endLine,
            totalLines: totalLines,
            lines: lines
        )
    }

    @MainActor
    private func rawOutput(for session: TerminalSession, maxBytes requestedMaxBytes: Int?) -> TerminalRawOutputResult {
        let maxBytes = min(max(requestedMaxBytes ?? 65_536, 1), 1_048_576)
        let snapshot = session.rawOutput(maxBytes: maxBytes)
        return TerminalRawOutputResult(
            terminalID: session.id.uuidString,
            text: String(decoding: snapshot.data, as: UTF8.self),
            byteCount: snapshot.data.count,
            truncated: snapshot.truncated
        )
    }

    @MainActor
    private func searchOutput(for session: TerminalSession, request: SearchOutputRequest) -> SearchOutputResult {
        let query = request.query
        let caseSensitive = request.caseSensitive ?? false
        let maxMatches = min(max(request.maxMatches ?? 50, 1), 500)
        guard !query.isEmpty else {
            return SearchOutputResult(terminalID: session.id.uuidString, matches: [])
        }

        var matches: [SearchOutputMatch] = []
        let lines = session.snapshot(range: 0..<session.lineCount)
        for (index, line) in lines.enumerated() {
            let didMatch = caseSensitive
                ? line.contains(query)
                : line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if didMatch {
                matches.append(.init(lineNumber: index, text: line))
                if matches.count >= maxMatches {
                    break
                }
            }
        }

        return SearchOutputResult(terminalID: session.id.uuidString, matches: matches)
    }

    private nonisolated static func readRequest(fileDescriptor fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.last == 0x0A {
                    data.removeLast()
                    return data
                }
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private nonisolated static func writeResponse(_ response: CherryControlResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private nonisolated static func controlError(from error: Error) -> CherryControlError {
        if let error = error as? CherryControlError {
            return error
        }
        return CherryControlError(code: "control_error", message: error.localizedDescription)
    }
}
