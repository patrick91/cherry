import Crypto
import Foundation
import NIOConcurrencyHelpers

/// Reaches a real Mac over SSH and runs Cherry's helpers there
/// (docs/specs/ios-app.md, Transport): one SSH connection per Mac, with a
/// long-lived `cherry control --no-start` for sessions, screens, input and
/// events, a PTY running `cherry attach` per terminal, and short runs of
/// Cherry's MCP helper for agent state.
public struct SSHMacConnector: MacConnector {
    public let identity: any DeviceIdentity
    /// How often agent state is read from the Mac's Cherry, at most.
    public var agentStateInterval: Duration = .seconds(3)

    public init(identity: any DeviceIdentity) {
        self.identity = identity
    }

    public func connect(to endpoint: MacEndpoint) async throws -> any MacConnection {
        guard let signing = identity as? any SSHSigningIdentity else {
            throw MacConnectionError.failed("This device's identity can't sign an SSH login.")
        }
        return try await SSHMacConnection.open(
            endpoint,
            key: try signing.signingKey(),
            deviceID: try signing.deviceID(),
            agentStateInterval: agentStateInterval
        )
    }
}

actor SSHMacConnection: MacConnection {
    private let endpointBox: NIOLockedValueBox<MacEndpoint>
    nonisolated var endpoint: MacEndpoint { endpointBox.withLockedValue { $0 } }

    private let ssh: SSHConnection
    private let control: SSHSessionChannel
    private let cherryPath: String
    private let deviceID: String
    private let agentStateInterval: Duration

    private var decoder = HostWireFrameDecoder()
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<HostWireReply, any Error>] = [:]
    private var welcome: CheckedContinuation<String, any Error>?
    /// The `Welcome`'s outcome when it came before anyone waited for it.
    private var earlyWelcome: Result<String, any Error>?
    private var hostID: String?
    private var subscribers: [UUID: AsyncStream<MacEvent>.Continuation] = [:]
    private var sessionsByID: [String: HostWireSession] = [:]
    private var agentStates = AgentStates.empty
    private var agentStatesReadAt: ContinuousClock.Instant?
    private var agentStatesRead: Task<AgentStates, Never>?
    private var closedReason: String?
    private var heartbeat: Task<Void, Never>?

    private init(
        endpoint: MacEndpoint,
        ssh: SSHConnection,
        control: SSHSessionChannel,
        cherryPath: String,
        deviceID: String,
        agentStateInterval: Duration
    ) {
        endpointBox = NIOLockedValueBox(endpoint)
        self.ssh = ssh
        self.control = control
        self.cherryPath = cherryPath
        self.deviceID = deviceID
        self.agentStateInterval = agentStateInterval
    }

    static func open(
        _ endpoint: MacEndpoint,
        key: Curve25519.Signing.PrivateKey,
        deviceID: String,
        agentStateInterval: Duration
    ) async throws -> SSHMacConnection {
        let ssh: SSHConnection
        do {
            ssh = try await SSHConnection.connect(
                host: endpoint.host,
                port: endpoint.port,
                user: endpoint.user,
                key: key,
                pinnedFingerprint: endpoint.hostKeyFingerprint
            )
        } catch let failure as SSHConnection.Failure {
            throw Self.error(for: failure)
        }
        do {
            let cherryPath = try await findCherry(ssh, endpoint: endpoint)
            var words = [cherryPath, "control", "--no-start"]
            if let expected = endpoint.expectedHostID { words += ["--expected-host-id", expected] }
            let control = try await ssh.session(command: ShellQuote.command(words))
            var connected = endpoint
            connected.hostKeyFingerprint = ssh.presentedFingerprint
            let connection = SSHMacConnection(
                endpoint: connected,
                ssh: ssh,
                control: control,
                cherryPath: cherryPath,
                deviceID: deviceID,
                agentStateInterval: agentStateInterval
            )
            try await connection.start()
            return connection
        } catch {
            await ssh.close()
            if let failure = error as? SSHConnection.Failure { throw Self.error(for: failure) }
            throw error
        }
    }

    private static func findCherry(_ ssh: SSHConnection, endpoint: MacEndpoint) async throws -> String {
        let found = try await ssh.run(CherryLocator.command(cherryPath: endpoint.cherryPath))
        let path = String(decoding: found.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, !path.isEmpty else { throw MacConnectionError.cherryNotFound }
        return path
    }

    static func error(for failure: SSHConnection.Failure) -> MacConnectionError {
        switch failure {
        case .hostKeyMismatch(let expected, let presented): .hostKeyMismatch(expected: expected, presented: presented)
        case .authenticationFailed: .authenticationFailed
        case .unreachable(let why): .unreachable(why)
        case .timedOut: .unreachable("timed out")
        case .closed: .unreachable("the connection closed")
        case .requestRefused(let what): .failed("The Mac refused the \(what) request.")
        }
    }

    // MARK: - Start

    /// Reads the host's `Welcome`, subscribes to its events, and keeps the
    /// connection alive.
    private func start() async throws {
        Task { await self.readControl() }
        let welcomeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            await self?.failWelcome(MacConnectionError.unreachable("the Mac's session host did not answer"))
        }
        defer { welcomeTimeout.cancel() }
        let hostID = try await withCheckedThrowingContinuation { continuation in
            if let earlyWelcome {
                continuation.resume(with: earlyWelcome)
            } else if let closedReason {
                continuation.resume(throwing: MacConnectionError.unreachable(closedReason))
            } else {
                welcome = continuation
            }
        }
        endpointBox.withLockedValue { $0.expectedHostID = hostID }
        guard case .ok = try await request(.subscribe) else {
            throw MacConnectionError.failed("The Mac's session host refused to send its events.")
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: HostWire.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                _ = try? await self.request(.ping)
            }
        }
    }

    private func failWelcome(_ error: any Error) {
        welcome?.resume(throwing: error)
        welcome = nil
    }

    // MARK: - MacConnection

    func sessions() async throws -> [MobileSession] {
        let reply = try await request(.list)
        guard case .sessions(let list) = reply else { throw unexpected(reply) }
        sessionsByID = Dictionary(list.sessions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // Only agents have a state to read.
        let hasAgents = list.sessions.contains { $0.isRunning && $0.tags[SessionMapping.Tag.kind] == "agent" }
        let states = hasAgents ? await currentAgentStates() : .empty
        let macID = endpoint.id
        return list.sessions.map { SessionMapping.session($0, macID: macID, states: states) }
    }

    func screen(of sessionID: String) async throws -> ScreenSnapshot {
        let reply = try await request(.screen(id: sessionID, scrollback: false, maxLines: nil))
        switch reply {
        case .screenText(let screen):
            let lines = SessionMapping.lines(of: screen)
            let size = sessionsByID[sessionID].map { TerminalSize(columns: $0.cols, rows: $0.rows) }
                ?? TerminalSize(columns: lines.map(\.count).max() ?? 80, rows: max(lines.count, 1))
            return ScreenSnapshot(lines: lines, size: size)
        case .error(let code, let message):
            throw sessionError(code: code, message: message, sessionID: sessionID)
        default:
            throw unexpected(reply)
        }
    }

    func send(_ keys: [MobileKey], to sessionID: String) async throws {
        var data = Data()
        for key in keys { data.append(key.bytes) }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: HostWire.maxInputBytes, limitedBy: data.endIndex) ?? data.endIndex
            let reply = try await request(.sendInput(id: sessionID, data: Data(data[offset..<end])))
            switch reply {
            case .ok: break
            case .error(let code, let message): throw sessionError(code: code, message: message, sessionID: sessionID)
            default: throw unexpected(reply)
            }
            offset = end
        }
    }

    nonisolated func events() -> AsyncStream<MacEvent> {
        let (stream, continuation) = AsyncStream<MacEvent>.makeStream()
        let id = UUID()
        continuation.onTermination = { _ in
            Task { await self.removeSubscriber(id) }
        }
        Task { await self.addSubscriber(id, continuation) }
        return stream
    }

    func attach(_ sessionID: String, size: TerminalSize) async throws -> any TerminalAttachment {
        if let closedReason { throw MacConnectionError.unreachable(closedReason) }
        var words = [cherryPath, "attach", sessionID, "--detach-key", "none", "--client-id", "mobile-\(deviceID)"]
        if let hostID { words += ["--expected-host-id", hostID] }
        do {
            let channel = try await ssh.session(command: ShellQuote.command(words), pty: size)
            return SSHTerminalAttachment(channel: channel)
        } catch let failure as SSHConnection.Failure {
            throw Self.error(for: failure)
        }
    }

    func disconnect() async {
        await end(reason: "Disconnected")
        await ssh.close()
    }

    // MARK: - Requests

    private func request(_ message: HostWireMessage, timeout: Duration = .seconds(15)) async throws -> HostWireReply {
        if let closedReason { throw MacConnectionError.unreachable(closedReason) }
        let id = nextRequestID
        nextRequestID += 1
        let frame = try HostWire.encode(HostWireRequest(req: id, message: message))
        let control = control
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.resolve(id, with: .failure(MacConnectionError.unreachable("the Mac's session host did not answer")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await control.write(frame)
                } catch {
                    await self?.resolve(id, with: .failure(MacConnectionError.unreachable("the connection closed")))
                }
            }
        }
    }

    private func resolve(_ id: UInt64, with result: Result<HostWireReply, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func sessionError(code: String, message: String, sessionID: String) -> MacConnectionError {
        switch code {
        case HostWire.ErrorCode.unknownSession, HostWire.ErrorCode.notRunning: .sessionGone(sessionID)
        default: .failed(message)
        }
    }

    private func unexpected(_ reply: HostWireReply) -> MacConnectionError {
        if case .error(_, let message) = reply { return .failed(message) }
        return .failed("The Mac's session host answered something unexpected.")
    }

    // MARK: - Reading

    private func readControl() async {
        for await chunk in control.output {
            decoder.append(chunk)
            do {
                while let body = try decoder.nextFrame() {
                    handle(body)
                }
            } catch {
                await control.close()
                await end(reason: "The Mac's cherry sent something that isn't the session host's protocol.")
                return
            }
        }
        // Standard output ended: why, from its standard error and status.
        let status = await control.exit()
        let stderr = String(decoding: control.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await end(reason: stderr.isEmpty ? "The Mac's session host connection ended." : stderr, status: status)
    }

    private func handle(_ body: Data) {
        let response: HostWireResponse
        do {
            response = try HostWireResponse.decode(frameBody: body)
        } catch {
            if let id = HostWireResponse.requestID(inUndecodable: body) {
                resolve(id, with: .failure(MacConnectionError.failed("The Mac's session host answered something this app can't read.")))
            }
            return
        }
        if case .welcome(let version, let hostID) = response.reply {
            guard self.hostID == nil, earlyWelcome == nil else { return }
            let outcome: Result<String, any Error>
            if version != HostWire.version {
                outcome = .failure(MacConnectionError.protocolMismatch(
                    "the Mac's session host speaks version \(version), this app \(HostWire.version)"
                ))
            } else {
                self.hostID = hostID
                outcome = .success(hostID)
            }
            if let welcome {
                self.welcome = nil
                welcome.resume(with: outcome)
            } else {
                earlyWelcome = outcome
            }
            return
        }
        if let id = response.req, pending[id] != nil {
            resolve(id, with: .success(response.reply))
            return
        }
        if case .event(let event) = response.reply {
            apply(event)
        }
    }

    private func apply(_ event: HostWireEvent) {
        switch event {
        case .added(let session), .changed(let session):
            sessionsByID[session.id] = session
            broadcast(.sessionsChanged)
        case .removed(let id):
            sessionsByID[id] = nil
            broadcast(.sessionsChanged)
        case .exited(let id, let exitCode, _):
            broadcast(.exited(sessionID: id, status: Int32(truncatingIfNeeded: exitCode)))
            broadcast(.sessionsChanged)
        case .bell(let id), .notification(let id, _, _), .progress(let id):
            broadcast(.screenChanged(sessionID: id))
        case .resync:
            broadcast(.sessionsChanged)
        case .unknown:
            break
        }
    }

    /// The connection ended (or was ended): every waiter fails, every
    /// subscriber hears why.
    private func end(reason: String, status: Int? = nil) async {
        guard closedReason == nil else { return }
        closedReason = reason
        heartbeat?.cancel()
        if let welcome {
            self.welcome = nil
            welcome.resume(throwing: Self.startError(reason: reason, status: status))
        }
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: MacConnectionError.unreachable(reason))
        }
        for continuation in subscribers.values {
            continuation.yield(.disconnected(reason: reason))
            continuation.finish()
        }
        subscribers.removeAll()
        await control.close()
    }

    /// Why `cherry control --no-start` ended before its `Welcome`.
    static func startError(reason: String, status: Int?) -> MacConnectionError {
        let lowercased = reason.lowercased()
        if lowercased.contains("no cherry-host is running") || lowercased.contains("never starts one") {
            return .noSessionHost(reason)
        }
        if status == 127 || lowercased.contains("command not found") || lowercased.contains("no such file") {
            return .cherryNotFound
        }
        if lowercased.contains("protocol") && lowercased.contains("version") {
            return .protocolMismatch(reason)
        }
        return .failed(reason)
    }

    private func addSubscriber(_ id: UUID, _ continuation: AsyncStream<MacEvent>.Continuation) {
        if let closedReason {
            continuation.yield(.disconnected(reason: closedReason))
            continuation.finish()
            return
        }
        subscribers[id] = continuation
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ event: MacEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - Agent state

    /// The Mac's Cherry's agent states, read at most every
    /// `agentStateInterval`; empty when it can't be read.
    private func currentAgentStates() async -> AgentStates {
        if let readAt = agentStatesReadAt, ContinuousClock.now - readAt < agentStateInterval {
            return agentStates
        }
        if let agentStatesRead {
            return await agentStatesRead.value
        }
        let ssh = ssh
        let mcpPath = AgentStateCommands.mcpPath(nextTo: cherryPath)
        let read = Task { await AgentStateReader.read(over: ssh, mcpPath: mcpPath) }
        agentStatesRead = read
        let states = await read.value
        agentStates = states
        agentStatesReadAt = .now
        agentStatesRead = nil
        return states
    }
}

/// Reads agent state with the Mac's MCP helper; nothing when it fails.
enum AgentStateReader {
    static func read(over ssh: SSHConnection, mcpPath: String) async -> AgentStates {
        guard let projects = try? await ssh.run(AgentStateCommands.listProjects(mcpPath: mcpPath), timeout: .seconds(10)),
              projects.status == 0
        else { return .empty }
        let roots = AgentStates.projectRoots(inListProjects: projects.stdout)
        guard !roots.isEmpty,
              let processes = try? await ssh.run(
                  AgentStateCommands.listProcesses(mcpPath: mcpPath, roots: roots),
                  timeout: .seconds(15)
              )
        else { return .empty }
        return AgentStates.parse(processLists: AgentStateCommands.lines(processes.stdout))
    }
}

/// A terminal attached over a PTY channel running `cherry attach`.
final class SSHTerminalAttachment: TerminalAttachment {
    private let channel: SSHSessionChannel
    var output: AsyncStream<Data> { channel.output }

    init(channel: SSHSessionChannel) {
        self.channel = channel
    }

    func write(_ data: Data) async throws {
        do {
            try await channel.write(data)
        } catch {
            throw MacConnectionError.unreachable("the terminal's connection closed")
        }
    }

    func resize(_ size: TerminalSize) async throws {
        do {
            try await channel.windowChange(size)
        } catch {
            throw MacConnectionError.unreachable("the terminal's connection closed")
        }
    }

    func detach() async {
        await channel.close()
    }
}
