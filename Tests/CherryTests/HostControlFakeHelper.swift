import Darwin
import Foundation
@testable import Cherry

/// An in-process stand-in for `cherry control` and the daemon behind it. Each
/// launch gets real pipes: the fake writes the host's Welcome, then answers
/// protocol 6 control requests (echoing `req`) until the app closes its
/// input. Given `--expected-host-id` for another identity it exits before
/// the Welcome with the CLI's message.
///
/// Defaults: subscribe → ok, list → the sessions (with `pendingHolders`, nil
/// for a host that does not report it), create → a running session
/// `session-<request id>` that reports its `request_id`, kill → ok and,
/// after `exitDelay`, `exited` + `changed` events (unless `killEndsSession`
/// is false), remove → ok, ping → pong, send_input/update → ok, screen → a
/// screen (its last `max_lines` lines when asked). `respond` overrides any
/// request; returning nil falls back to the default.
final class FakeControlHelper: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let op: String
        let req: UInt64?
        let json: [String: Any]
        let body: Data

        func string(_ key: String) -> String? { json[key] as? String }
    }

    enum Reply {
        case answer(HostServerMessage)
        /// Say nothing (the answer is lost).
        case silence
        /// Stop the helper, optionally explaining on standard error.
        case exit(stderr: String?)
    }

    final class Connection: @unchecked Sendable {
        let number: Int
        let launch: HostControlLaunch
        fileprivate let output: Int32
        fileprivate let errors: Int32
        private let lock = NSLock()
        private var closed = false
        fileprivate let ended = DispatchSemaphore(value: 0)

        fileprivate init(number: Int, launch: HostControlLaunch, output: Int32, errors: Int32) {
            self.number = number
            self.launch = launch
            self.output = output
            self.errors = errors
        }

        func push(_ message: HostServerMessage, req: UInt64? = nil) {
            guard let frame = try? HostFrame.encode(HostResponse(req: req, message: message)) else { return }
            write(frame)
        }

        /// Attachment traffic, which a control connection never asks for.
        func push(_ binary: HostBinaryFrame) {
            guard let frame = try? HostFrame.encode(binary) else { return }
            write(frame)
        }

        func write(_ bytes: Data) {
            lock.withLock {
                guard !closed else { return }
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(output, raw.baseAddress! + offset, raw.count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { return }
                        offset += written
                    }
                }
            }
        }

        /// The helper exits: its output and standard error close.
        func exit(stderr: String? = nil) {
            lock.withLock {
                guard !closed else { return }
                closed = true
                if let stderr {
                    _ = stderr.withCString { Darwin.write(errors, $0, strlen($0)) }
                }
                Darwin.close(errors)
                Darwin.close(output)
            }
        }

        var isClosed: Bool { lock.withLock { closed } }
    }

    private let lock = NSLock()
    private var _hostID = "host-a"
    private var _version: UInt32 = HostProtocol.version
    private var _sessions: [HostedSessionInfo] = []
    private var _supportsSubscribe = true
    private var _killEndsSession = true
    private var _welcome = true
    private var _launchFailure: String?
    private var _exitBeforeWelcome: String?
    private var _requests: [(connection: Int, request: Request)] = []
    private var _launches: [HostControlLaunch] = []
    private var _connections: [Connection] = []
    private var _respond: ((Request, Connection) -> Reply?)?
    private var _screenText = "fake screen"
    private var _screenIsAlternate = false
    private var _pendingHolders: Int?
    private var _lostSessionIDs: Set<String> = []
    let exitDelay: TimeInterval

    init(sessions: [HostedSessionInfo] = [], exitDelay: TimeInterval = 0.05) {
        _sessions = sessions
        self.exitDelay = exitDelay
    }

    var hostID: String {
        get { lock.withLock { _hostID } }
        set { lock.withLock { _hostID = newValue } }
    }

    var version: UInt32 {
        get { lock.withLock { _version } }
        set { lock.withLock { _version = newValue } }
    }

    var sessions: [HostedSessionInfo] {
        get { lock.withLock { _sessions } }
        set { lock.withLock { _sessions = newValue } }
    }

    var supportsSubscribe: Bool {
        get { lock.withLock { _supportsSubscribe } }
        set { lock.withLock { _supportsSubscribe = newValue } }
    }

    var killEndsSession: Bool {
        get { lock.withLock { _killEndsSession } }
        set { lock.withLock { _killEndsSession = newValue } }
    }

    /// Launches fail to start with this message.
    var launchFailure: String? {
        get { lock.withLock { _launchFailure } }
        set { lock.withLock { _launchFailure = newValue } }
    }

    /// The helper exits before any Welcome, writing this to standard error.
    var exitBeforeWelcome: String? {
        get { lock.withLock { _exitBeforeWelcome } }
        set { lock.withLock { _exitBeforeWelcome = newValue } }
    }

    /// What `screen` answers (its text), and whether on the alternate screen.
    var screenText: String {
        get { lock.withLock { _screenText } }
        set { lock.withLock { _screenText = newValue } }
    }

    var screenIsAlternate: Bool {
        get { lock.withLock { _screenIsAlternate } }
        set { lock.withLock { _screenIsAlternate = newValue } }
    }

    /// What `list` reports as `pending_holders`; nil leaves it out (a host
    /// from before it was reported).
    var pendingHolders: Int? {
        get { lock.withLock { _pendingHolders } }
        set { lock.withLock { _pendingHolders = newValue } }
    }

    /// What `list` reports as `lost_sessions` (holders a restarted daemon
    /// found gone); empty leaves it out.
    var lostSessionIDs: Set<String> {
        get { lock.withLock { _lostSessionIDs } }
        set { lock.withLock { _lostSessionIDs = newValue } }
    }

    var respond: ((Request, Connection) -> Reply?)? {
        get { lock.withLock { _respond } }
        set { lock.withLock { _respond = newValue } }
    }

    var launches: [HostControlLaunch] { lock.withLock { _launches } }
    var connections: [Connection] { lock.withLock { _connections } }
    var requests: [Request] { lock.withLock { _requests.map(\.request) } }

    func requests(_ op: String) -> [Request] { requests.filter { $0.op == op } }

    /// Every live connection's helper exits.
    func dropAll(stderr: String? = nil) {
        for connection in connections { connection.exit(stderr: stderr) }
    }

    var launcher: HostControlLauncher {
        { [self] launch in try start(launch) }
    }

    private func start(_ launch: HostControlLaunch) throws -> HostControlChannel {
        if let failure = launchFailure {
            lock.withLock { _launches.append(launch) }
            throw HostedSessionError.message(failure)
        }
        func makePipe() -> (read: Int32, write: Int32) {
            var descriptors: [Int32] = [-1, -1]
            precondition(pipe(&descriptors) == 0)
            for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            return (descriptors[0], descriptors[1])
        }
        let input = makePipe()
        let output = makePipe()
        let errors = makePipe()
        _ = fcntl(output.write, F_SETNOSIGPIPE, 1)
        let (connection, exitEarly, welcome): (Connection, String?, HostServerMessage?) = lock.withLock {
            _launches.append(launch)
            let connection = Connection(number: _connections.count, launch: launch, output: output.write, errors: errors.write)
            _connections.append(connection)
            // Like the CLI: an expected identity is checked before anything else.
            var exitEarly = _exitBeforeWelcome
            if let flag = launch.arguments.firstIndex(of: "--expected-host-id"),
               launch.arguments.indices.contains(flag + 1), launch.arguments[flag + 1] != _hostID {
                exitEarly = "cherry: host identity changed (expected \(launch.arguments[flag + 1]), received \(_hostID)); "
                    + "reconnect to the intended host before using this session\n"
            }
            return (connection, exitEarly, _welcome ? .welcome(version: _version, hostID: _hostID) : nil)
        }
        let tail = HostProcessErrorTail()
        tail.drain(errors.read)
        let thread = Thread { [self] in
            serve(connection, input: input.read, exitEarly: exitEarly, welcome: welcome)
        }
        thread.start()
        return HostControlChannel(input: input.write, output: output.read, errors: tail)
    }

    private func serve(_ connection: Connection, input: Int32, exitEarly: String?, welcome: HostServerMessage?) {
        defer {
            Darwin.close(input)
            connection.exit()
            connection.ended.signal()
        }
        if let exitEarly {
            connection.exit(stderr: exitEarly)
            return
        }
        if let welcome { connection.push(welcome) }
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !connection.isClosed {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            while let body = try? decoder.nextFrame() {
                guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let op = json["op"] as? String
                else { continue }
                let request = Request(op: op, req: (json["req"] as? NSNumber)?.uint64Value, json: json, body: body)
                lock.withLock { _requests.append((connection.number, request)) }
                let reply = respond?(request, connection) ?? defaultReply(to: request, on: connection)
                switch reply {
                case .answer(let message):
                    connection.push(message, req: request.req)
                case .silence:
                    break
                case .exit(let stderr):
                    connection.exit(stderr: stderr)
                    return
                }
            }
        }
    }

    func defaultReply(to request: Request, on connection: Connection) -> Reply {
        switch request.op {
        case "subscribe":
            return .answer(supportsSubscribe ? .ok : .error(code: "unsupported_operation", message: "not supported"))
        case "list":
            return .answer(.sessions(HostedSessionList(
                hostID: hostID, sessions: sessions, pendingHolders: pendingHolders, lostSessionIDs: lostSessionIDs
            )))
        case "create":
            let session = HostedSessionInfo(
                id: "session-\(request.string("request_id") ?? "?")",
                name: request.string("name") ?? "",
                cwd: request.string("cwd") ?? "~",
                command: request.json["command"] as? [String] ?? [],
                pid: 42,
                owner: request.string("owner"),
                tags: request.json["tags"] as? [String: String] ?? [:],
                requestID: request.string("request_id")
            )
            lock.withLock {
                _sessions.removeAll { $0.id == session.id }
                _sessions.append(session)
            }
            return .answer(.created(session))
        case "kill":
            let id = request.string("id") ?? ""
            if killEndsSession {
                DispatchQueue.global().asyncAfter(deadline: .now() + exitDelay) { [self] in
                    let exited: HostedSessionInfo? = lock.withLock {
                        guard let index = _sessions.firstIndex(where: { $0.id == id }) else { return nil }
                        _sessions[index] = _sessions[index].exited(code: 129, signal: 1)
                        return _sessions[index]
                    }
                    guard let exited else { return }
                    connection.push(.event(.exited(id: id, exitCode: 129, signal: 1)))
                    connection.push(.event(.changed(exited)))
                }
            }
            return .answer(.ok)
        case "remove":
            let id = request.string("id") ?? ""
            lock.withLock { _sessions.removeAll { $0.id == id } }
            return .answer(.ok)
        case "ping":
            return .answer(.pong)
        case "send_input", "update", "clear_history":
            return .answer(.ok)
        case "screen":
            var text = lock.withLock { _screenText }
            if let maxLines = (request.json["max_lines"] as? NSNumber)?.intValue {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                text = lines.suffix(max(maxLines, 0)).joined(separator: "\n")
            }
            return .answer(.screenText(HostScreenText(
                id: request.string("id") ?? "", text: text,
                cursorRow: 1, cursorCol: 2, alternateScreen: lock.withLock { _screenIsAlternate }
            )))
        default:
            return .answer(.error(code: "request_failed", message: "unknown request \(request.op)"))
        }
    }

    /// Waits (polling) until `condition` holds; false after `timeout`.
    @MainActor
    func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// HostControl settings for tests: quick reconnects, no idle disconnect.
extension HostControl.Configuration {
    static let fastTests: HostControl.Configuration = {
        var configuration = HostControl.Configuration()
        configuration.handshakeTimeout = .seconds(5)
        configuration.requestTimeout = .seconds(5)
        configuration.reconnectDelay = (.milliseconds(20), .milliseconds(200))
        configuration.idleDisconnectDelay = .seconds(600)
        configuration.pollInterval = .milliseconds(20)
        return configuration
    }()
}

/// SSH masters switched off, so no test ever runs a real ssh.
let disabledSSHMasters = HostSSHMasterManager(configuration: .init(directory: { nil }))

@MainActor
func makeFakeHostControl(
    _ fake: FakeControlHelper,
    host: HostedSessionHost = .local,
    hostStore: HostedSessionHostStore,
    loginEnvironment: [String: String] = [:],
    masters: HostSSHMasterManager = disabledSSHMasters,
    localHostUnavailableReason: String? = nil,
    configuration: HostControl.Configuration = .fastTests
) -> HostControl {
    HostControl(
        host: host,
        clientProvider: {
            HostedSessionClient(
                executableURL: URL(fileURLWithPath: "/fake/bin/cherry"),
                loginEnvironment: { _ in .init(environment: loginEnvironment) }
            )
        },
        hostStore: hostStore,
        masters: masters,
        launcher: fake.launcher,
        localHostUnavailableReason: localHostUnavailableReason,
        configuration: configuration
    )
}

@MainActor
func makeFakeHostControlRegistry(
    _ fake: FakeControlHelper,
    hostStore: HostedSessionHostStore,
    clientProvider: (@MainActor () throws -> HostedSessionClient)? = nil,
    configuration: HostControl.Configuration = .fastTests
) -> HostControlRegistry {
    HostControlRegistry { host in
        HostControl(
            host: host,
            clientProvider: clientProvider ?? {
                HostedSessionClient(
                    executableURL: URL(fileURLWithPath: "/fake/bin/cherry"),
                    loginEnvironment: { _ in .init(environment: [:]) }
                )
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: configuration
        )
    }
}

func hostedSession(
    _ id: String,
    name: String = "Session",
    state: HostedSessionState = .running,
    pid: UInt32? = 100,
    exitCode: UInt32? = nil,
    title: String? = nil
) -> HostedSessionInfo {
    HostedSessionInfo(
        id: id, name: name, cwd: "/remote", command: ["/bin/sh"], cols: 80, rows: 24, state: state,
        pid: pid, exitCode: exitCode, title: title
    )
}

/// A request a test answers itself, later (the fake says nothing meanwhile).
final class FakeHeldRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (request: FakeControlHelper.Request, connection: FakeControlHelper.Connection)?

    func hold(_ request: FakeControlHelper.Request, on connection: FakeControlHelper.Connection) -> FakeControlHelper.Reply {
        lock.withLock { held = (request, connection) }
        return .silence
    }

    var isHeld: Bool { lock.withLock { held != nil } }

    /// Sends the answer the fake held back.
    func answer(_ message: HostServerMessage) {
        guard let held = lock.withLock({ () -> (request: FakeControlHelper.Request, connection: FakeControlHelper.Connection)? in
            defer { self.held = nil }
            return self.held
        }) else { return }
        held.connection.push(message, req: held.request.req)
    }
}

/// A thread-safe countdown for fake behaviours ("lose the next N answers").
final class FakeCountdown: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ remaining: Int = 0) {
        self.remaining = remaining
    }

    func set(_ value: Int) { lock.withLock { remaining = value } }

    /// True (and one fewer left) while any remain.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
