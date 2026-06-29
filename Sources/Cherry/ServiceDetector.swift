import CherryControl
import Darwin
import Foundation

struct InspectableProcess: Equatable {
    let id: String
    let name: String
    let kind: String
    let rootPID: Int32?
    let commandName: String?
    let agentName: String?
}

protocol ServiceDetecting {
    func detectServices(processes: [InspectableProcess], includeUnattributed: Bool) async throws -> [ServiceRecord]
}

struct MacOSServiceDetector: ServiceDetecting {
    private let processTreeProvider: @Sendable () -> [Int32: Int32]
    private let lsofOutputProvider: @Sendable () throws -> String

    init(
        processTreeProvider: @escaping @Sendable () -> [Int32: Int32] = MacOSServiceDetector.currentProcessTree,
        lsofOutputProvider: @escaping @Sendable () throws -> String = MacOSServiceDetector.currentLsofOutput
    ) {
        self.processTreeProvider = processTreeProvider
        self.lsofOutputProvider = lsofOutputProvider
    }

    func detectServices(processes: [InspectableProcess], includeUnattributed: Bool) async throws -> [ServiceRecord] {
        // `ps`/`lsof` are blocking subprocesses; run them off the @MainActor control
        // server (mirrors AgentSummaryRunner) so they can't pin it and starve every
        // other MCP request — the cause of nested-agent "Transport closed" hangs.
        let processTreeProvider = self.processTreeProvider
        let lsofOutputProvider = self.lsofOutputProvider
        let (processTree, lsofOutput) = try await Task.detached(priority: .utility) {
            (processTreeProvider(), try lsofOutputProvider())
        }.value
        let inspectableByPID = processLookup(processes: processes, processTree: processTree)
        let listeners = Self.parseLsofOutput(lsofOutput)

        return listeners.compactMap { listener in
            guard listener.isLocalOrWildcard else { return nil }

            if let process = inspectableByPID[listener.pid] {
                return ServiceRecord(
                    processID: process.id,
                    processName: process.name,
                    kind: process.kind,
                    pid: listener.pid,
                    port: listener.port,
                    host: listener.host,
                    url: Self.localhostURL(port: listener.port),
                    attribution: .processTree,
                    protocolGuess: Self.protocolGuess(port: listener.port),
                    readiness: .bound,
                    lastSeenAt: Date(),
                    commandName: process.commandName,
                    agentName: process.agentName
                )
            }

            guard includeUnattributed else { return nil }
            return ServiceRecord(
                processID: nil,
                processName: nil,
                kind: nil,
                pid: nil,
                port: listener.port,
                host: listener.host,
                url: Self.localhostURL(port: listener.port),
                attribution: .unattributed,
                protocolGuess: Self.protocolGuess(port: listener.port),
                readiness: .bound,
                lastSeenAt: Date(),
                commandName: nil,
                agentName: nil
            )
        }
        .sorted(by: Self.serviceSort)
    }

    private func processLookup(
        processes: [InspectableProcess],
        processTree: [Int32: Int32]
    ) -> [Int32: InspectableProcess] {
        var lookup: [Int32: InspectableProcess] = [:]
        for process in processes {
            guard let rootPID = process.rootPID, rootPID > 0 else { continue }
            lookup[rootPID] = process
            for descendant in Self.descendants(of: rootPID, processTree: processTree) {
                lookup[descendant] = process
            }
        }
        return lookup
    }

    static func parseLsofOutput(_ output: String) -> [ListeningPort] {
        var listeners: [ListeningPort] = []
        var currentPID: Int32?
        var currentProtocol: String?
        var currentName: String?
        var currentState: String?

        func flushFile() {
            guard currentState == "LISTEN",
                  currentProtocol == "TCP",
                  let pid = currentPID,
                  let name = currentName,
                  let endpoint = endpoint(from: name)
            else {
                currentProtocol = nil
                currentName = nil
                currentState = nil
                return
            }

            listeners.append(.init(pid: pid, host: endpoint.host, port: endpoint.port))
            currentProtocol = nil
            currentName = nil
            currentState = nil
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                flushFile()
                currentPID = Int32(value)
            case "f":
                flushFile()
            case "P":
                currentProtocol = value
            case "n":
                currentName = value
            case "T":
                if value.hasPrefix("ST=") {
                    currentState = String(value.dropFirst(3))
                }
            default:
                continue
            }
        }
        flushFile()

        var seen = Set<String>()
        return listeners.filter { listener in
            seen.insert("\(listener.pid)-\(listener.host)-\(listener.port)").inserted
        }
    }

    private static func endpoint(from name: String) -> (host: String, port: Int)? {
        let trimmed = name
            .replacingOccurrences(of: "TCP ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        guard let separator = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: separator)...])
        else {
            return nil
        }

        var host = String(endpoint[..<separator])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return (host.isEmpty ? "*" : host, port)
    }

    private static func descendants(of rootPID: Int32, processTree: [Int32: Int32]) -> Set<Int32> {
        var descendants = Set<Int32>()
        var frontier = [rootPID]
        while let parent = frontier.popLast() {
            for (pid, ppid) in processTree where ppid == parent && !descendants.contains(pid) {
                descendants.insert(pid)
                frontier.append(pid)
            }
        }
        return descendants
    }

    private static func currentProcessTree() -> [Int32: Int32] {
        guard let output = try? runTool(path: "/bin/ps", arguments: ["-axo", "pid=,ppid="]) else {
            return [:]
        }

        var tree: [Int32: Int32] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1])
            else {
                continue
            }
            tree[pid] = ppid
        }
        return tree
    }

    private static func currentLsofOutput() throws -> String {
        try runTool(path: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcfnPT"])
    }

    private static func runTool(path: String, arguments: [String], timeout: TimeInterval = 4.0) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let startedAt = Date()
        try process.run()

        // Bound the wait: if ps/lsof ever hangs (weird network/filesystem state) it
        // must not block forever even off the main actor. Terminating closes the
        // pipe, which unblocks the read below.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Read BEFORE waitUntilExit: large output (many listeners) can exceed the
        // 64KB pipe buffer and deadlock if we wait first. readDataToEndOfFile drains
        // until EOF (process exit or watchdog kill).
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // Diagnostic: service detection used to run on the main actor; if these ever
        // get slow under load it explains MCP latency. Now off-actor, but worth a log.
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 0.5 {
            NSLog("[cherry] service-detect %@ took %.2fs", path, elapsed)
        }

        if process.terminationStatus == 0 {
            return String(decoding: output, as: UTF8.self)
        }

        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw CherryControlError(
            code: "service_detection_failed",
            message: message.isEmpty ? "Failed to inspect local listening ports." : message
        )
    }

    private static func localhostURL(port: Int) -> String {
        "http://localhost:\(port)"
    }

    private static func protocolGuess(port: Int) -> String? {
        let commonHTTPPorts: Set<Int> = [80, 3000, 3001, 4200, 5000, 5173, 5174, 8000, 8080, 8081, 8888]
        return commonHTTPPorts.contains(port) ? "http" : nil
    }

    private static func serviceSort(lhs: ServiceRecord, rhs: ServiceRecord) -> Bool {
        if lhs.attribution != rhs.attribution {
            return lhs.attribution == .processTree
        }
        if lhs.processName != rhs.processName {
            return (lhs.processName ?? "") < (rhs.processName ?? "")
        }
        return lhs.port < rhs.port
    }
}

struct ListeningPort: Equatable {
    let pid: Int32
    let host: String
    let port: Int

    var isLocalOrWildcard: Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "*"
            || normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0.0.0.0"
            || normalized == "::"
    }
}
