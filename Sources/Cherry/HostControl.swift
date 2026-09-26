import Combine
import Darwin
import Foundation

/// How a control helper is started: `cherry [--host H] [--ssh-control-path P]
/// control` with the helper environment.
struct HostControlLaunch: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

/// The pipes of one running control helper. `HostControlConnection` owns the
/// descriptors: it writes frames to `input` and reads them from `output`.
final class HostControlChannel: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private let errors: HostProcessErrorTail?
    private let onFinish: @Sendable () -> Void

    init(
        input: Int32,
        output: Int32,
        errors: HostProcessErrorTail? = nil,
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.input = input
        self.output = output
        self.errors = errors
        self.onFinish = onFinish
    }

    /// What the helper wrote to standard error, after waiting up to
    /// `timeout` for it to finish writing.
    func diagnostics(waiting timeout: TimeInterval) -> String {
        guard let errors else { return "" }
        errors.waitForEnd(timeout: timeout)
        return errors.text
    }

    /// Called once the connection stopped reading: the helper must end.
    func finish() { onFinish() }

    /// Starts the real helper. Closing its standard input asks it to stop;
    /// one that is still running a second later is terminated, then killed.
    static func process(_ launch: HostControlLaunch) throws -> HostControlChannel {
        let process = try HostSpawnedProcess.spawn(
            executable: launch.executableURL.path,
            arguments: launch.arguments,
            environment: launch.environment,
            input: true, output: true, errors: true
        )
        let errors = HostProcessErrorTail()
        errors.drain(process.errors)
        let child = HostSignallableProcess(pid: process.pid)
        child.startReaping(name: "cherry.host-control.reaper")
        return HostControlChannel(input: process.input, output: process.output, errors: errors) {
            child.escalateTermination(grace: 1)
        }
    }
}

typealias HostControlLauncher = @Sendable (HostControlLaunch) throws -> HostControlChannel

final class HostControlFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    func set() { lock.withLock { storage = true } }
    var value: Bool { lock.withLock { storage } }
}

/// One helper's frame stream. Reading, decoding, encoding and writing happen
/// off the main thread; everything received comes out of `received`, in
/// order, ending with `.closed`.
final class HostControlConnection: @unchecked Sendable {
    enum Received: Sendable {
        case frame(HostResponse)
        /// A frame whose message this version cannot read; `req` when it had one.
        case unreadable(req: UInt64?, reason: String)
        /// No more frames follow. `reason` is the helper's explanation (its
        /// standard error) or a stream error, when there is one.
        case closed(reason: String?)
    }

    let received: AsyncStream<Received>
    private let continuation: AsyncStream<Received>.Continuation
    private let channel: HostControlChannel
    private let writes = DispatchQueue(label: "cherry.host-control.write", qos: .userInitiated)
    private let lock = NSLock()
    private var isClosed = false
    /// Only touched on `writes`.
    private var inputClosed = false
    /// Written by `close()`: wakes the reader and a blocked writer.
    private let wakeRead: Int32
    private let wakeWrite: Int32

    init(channel: HostControlChannel) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            Darwin.close(channel.input)
            Darwin.close(channel.output)
            channel.finish()
            throw HostedSessionError.unavailable("Could not set up the session client connection.")
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        }
        wakeRead = descriptors[0]
        wakeWrite = descriptors[1]
        // A helper that stops reading must never block a writer for good,
        // and one that exited must not raise SIGPIPE in the app.
        _ = fcntl(channel.input, F_SETFL, fcntl(channel.input, F_GETFL) | O_NONBLOCK)
        _ = fcntl(channel.input, F_SETNOSIGPIPE, 1)
        self.channel = channel
        (received, continuation) = AsyncStream.makeStream(of: Received.self)
    }

    deinit {
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "cherry.host-control.read"
        thread.start()
    }

    /// Encodes and writes the frame in order after earlier ones. `completion`
    /// gets the error when it could not be written (the connection is then
    /// closed).
    func send(_ request: HostRequest, completion: @escaping @Sendable (Error?) -> Void) {
        writes.async { [self] in
            guard !inputClosed, !lock.withLock({ isClosed }) else {
                completion(HostedSessionError.transport("The connection to the session host was closed."))
                return
            }
            let frame: Data
            do {
                frame = try HostFrame.encode(request)
            } catch {
                completion(HostedSessionError.message(error.localizedDescription))
                return
            }
            do {
                try writeAll(frame)
                completion(nil)
            } catch {
                completion(error)
                close()
            }
        }
    }

    /// Stops reading and closes the helper's input, which asks it to exit.
    func close() {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        closeInput()
    }

    private func closeInput() {
        writes.async { [self] in
            guard !inputClosed else { return }
            inputClosed = true
            Darwin.close(channel.input)
        }
    }

    private func writeAll(_ frame: Data) throws {
        try frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(channel.input, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN else {
                    throw HostedSessionError.transport(
                        "The session client stopped reading requests (\(String(cString: strerror(errno))))."
                    )
                }
                var descriptors = [
                    pollfd(fd: channel.input, events: Int16(POLLOUT), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                ]
                if poll(&descriptors, 2, -1) < 0, errno != EINTR {
                    throw HostedSessionError.transport("The connection to the session host failed.")
                }
                if descriptors[1].revents != 0 {
                    throw HostedSessionError.transport("The connection to the session host was closed.")
                }
            }
        }
    }

    private func readLoop() {
        var decoder = HostFrameDecoder()
        let json = JSONDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var reason: String?
        reading: while true {
            var descriptors = [
                pollfd(fd: channel.output, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            if poll(&descriptors, 2, -1) < 0 {
                if errno == EINTR { continue }
                reason = "The connection to the session host failed (\(String(cString: strerror(errno))))."
                break
            }
            if descriptors[1].revents != 0 { break }
            guard descriptors[0].revents != 0 else { continue }
            let count = read(channel.output, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                reason = "The connection to the session host failed (\(String(cString: strerror(errno))))."
                break
            }
            buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            do {
                while let body = try decoder.nextFrame() {
                    do {
                        continuation.yield(.frame(try HostResponse.decode(frameBody: body, using: json)))
                    } catch {
                        continuation.yield(.unreadable(
                            req: HostResponse.requestID(inUndecodable: body), reason: String(describing: error)
                        ))
                    }
                }
            } catch {
                reason = error.localizedDescription
                break reading
            }
        }
        Darwin.close(channel.output)
        let closedByApp = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return isClosed
        }
        closeInput()
        // An exiting helper explains itself on standard error just before.
        let diagnostics = closedByApp ? "" : channel.diagnostics(waiting: 0.5)
        continuation.yield(.closed(reason: reason ?? diagnostics.nilIfEmpty))
        continuation.finish()
        channel.finish()
    }
}

/// Keeps a host's control connection up while held. Releasing twice is
/// harmless; a lease released by deallocation releases on the main actor.
final class HostControlLease: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { release() }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onRelease = nil }
            return onRelease
        }
        action?()
    }
}

/// The app's one control connection to a session host (`cherry control`,
/// protocol 6). It verifies the host's identity, subscribes to events, keeps
/// `sessions` current from them, pings every heartbeat interval, and — while
/// leased — reconnects with backoff, re-listing after every reconnect or
/// host resync.
///
/// Requests may overlap: each carries its own request ID. A request made
/// while disconnected connects first. Errors are `HostedSessionError`s:
/// `.unavailable` (nothing was sent: no connection could be made),
/// `.identityMismatch` (the host is not the one this Mac trusts; nothing was
/// sent), `.rejected` (the host's definite answer), `.transport` (sent, but no
/// definite answer: it may or may not have happened) and `.message`
/// (decided in the app).
@MainActor
final class HostControl: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        /// Lost or failed while leased; a new attempt follows the backoff.
        case waitingToReconnect(HostedSessionError)
        /// Failed with nothing leasing the connection, or for a reason a
        /// retry cannot fix (an untrusted identity, a disk image copy).
        /// The next request tries again.
        case failed(HostedSessionError)
    }

    struct Configuration: Sendable {
        /// From starting the helper to the host's Welcome. The helper's own
        /// SSH connection deadline is shorter.
        var handshakeTimeout: Duration = .seconds(60)
        var requestTimeout: Duration = .seconds(30)
        var heartbeatInterval: Duration = HostProtocol.heartbeatInterval
        /// A Ping unanswered this long means the connection is dead.
        var pingTimeout: Duration = .seconds(30)
        var reconnectDelay: (initial: Duration, maximum: Duration) = (.milliseconds(250), .seconds(30))
        /// A connection nothing leases or uses is closed after this.
        var idleDisconnectDelay: Duration = .seconds(60)
        /// How long a connection to an SSH host waits for the app's master.
        var masterStartTimeout: TimeInterval = 15
        /// How often `waitForSession` lists when the host sends no events.
        var pollInterval: Duration = .milliseconds(150)
        /// After a list that says holders are still expected (a daemon that
        /// just restarted), the host is listed again this often,
        /// `pendingHolderRelists` times in a row, then every
        /// `pendingHolderSlowRelistInterval` until a list is complete (a
        /// holder that is stopped registers once continued; one that is
        /// gone is no longer expected), so a session whose holder never
        /// came back is not kept as running.
        var pendingHolderRelistInterval: Duration = .milliseconds(500)
        var pendingHolderRelists = 20
        var pendingHolderSlowRelistInterval: Duration = .seconds(5)
    }

    let host: HostedSessionHost
    @Published private(set) var state: ConnectionState = .idle {
        didSet { resumeSessionWaiters() }
    }
    /// The host's sessions, kept current by events. Stale while not
    /// connected, including after another identity answered: they are the
    /// trusted host's last known sessions, never the other host's. While a
    /// daemon that just restarted still expects holders to register, the
    /// running sessions it does not list yet keep their last known state.
    @Published private(set) var sessions: [HostedSessionInfo] = [] {
        didSet { resumeSessionWaiters() }
    }
    /// The identity of the host connected to; nil while not connected.
    @Published private(set) var hostID: String?
    /// The latest list said the host still expects holders to register (a
    /// daemon that just restarted): running sessions it did not list may
    /// still come back (`holdersRegistered()`).
    @Published private(set) var expectsHolders = false
    /// How many connections have come up so far. It grows before `state`
    /// turns `.connected`, so an observer of that change sees the new count.
    private(set) var connectionCount = 0
    /// Whether the host pushes events on this connection.
    private(set) var isSubscribed = false
    /// The helper and login environment of the latest connection attempt,
    /// which attach adapters for this host should get too.
    private(set) var executableURL: URL?
    private(set) var loginEnvironment: HostedSessionLoginEnvironment.Capture?

    private let clientProvider: @MainActor () throws -> HostedSessionClient
    private let hostStore: HostedSessionHostStore
    private let masters: HostSSHMasterManager
    private let launcher: HostControlLauncher
    private let unavailableReason: String?
    let configuration: Configuration

    private let eventSubject = PassthroughSubject<HostSessionEvent, Never>()
    private var eventContinuations: [UUID: AsyncStream<HostSessionEvent>.Continuation] = [:]

    private struct PendingRequest {
        let connection: HostControlConnection
        let continuation: CheckedContinuation<HostServerMessage, Error>
        let timeout: Task<Void, Never>?
        /// Made by the control itself (a heartbeat Ping, a re-list after a
        /// host resync): it does not keep an unused connection open.
        let isBackground: Bool
        /// `eventSequence` when it was sent: an event counted after it
        /// is newer than the snapshot its reply carries.
        let sentAtEvent: UInt64
    }

    private var connection: HostControlConnection?
    private var connectAttempt: Task<HostControlConnection, Error>?
    private var handshakeWaiter: (connection: HostControlConnection, continuation: CheckedContinuation<(UInt32, String), Error>)?
    private var pending: [UInt64: PendingRequest] = [:]
    private var nextRequestID: UInt64 = 1
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var leaseCount = 0
    private var masterLease: HostSSHMasterLease?
    private var acceptsNewIdentity = false
    private var hasListed = false
    private var announcesResyncAfterNextList = false
    private var reconnectFailures = 0
    private var sessionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The background re-list while holders are pending, and how many were
    /// made since the last complete list.
    private var pendingHolderRelist: Task<Void, Never>?
    private var pendingHolderRelists = 0
    /// Counts the session events applied (and sessions this app removed),
    /// so a reply can tell what reached the app after its request was sent.
    /// The host builds a reply's snapshot (Created, a list) before it queues
    /// the reply, and session events can overtake it: an event counted
    /// after the request was sent is newer than (or as new as) the reply's
    /// snapshot, so the snapshot never overwrites it.
    private var eventSequence: UInt64 = 0
    /// The `eventSequence` of the last event that changed, ended or removed
    /// each session; only kept while a request sent before it may still
    /// answer (`pruneSessionEventSequences`).
    private var sessionEventSequence: [String: UInt64] = [:]

    init(
        host: HostedSessionHost,
        clientProvider: @escaping @MainActor () throws -> HostedSessionClient = { try HostedSessionClient.installed() },
        hostStore: HostedSessionHostStore = .shared,
        masters: HostSSHMasterManager = .shared,
        launcher: @escaping HostControlLauncher = { try HostControlChannel.process($0) },
        localHostUnavailableReason: String? = HostedSessionInstallation.localHostUnavailableReason(),
        configuration: Configuration = Configuration()
    ) {
        self.host = host
        self.clientProvider = clientProvider
        self.hostStore = hostStore
        self.masters = masters
        self.launcher = launcher
        unavailableReason = host.sshDestination == nil ? localHostUnavailableReason : nil
        self.configuration = configuration
    }

    isolated deinit {
        connection?.close()
    }

    // MARK: Events

    /// Every event, as the host sent it or as a re-list revealed it.
    var events: AnyPublisher<HostSessionEvent, Never> { eventSubject.eraseToAnyPublisher() }

    /// The events from now on, until the stream is dropped.
    func eventStream() -> AsyncStream<HostSessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: HostSessionEvent.self)
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.eventContinuations[id] = nil }
        }
        return stream
    }

    private func publish(_ event: HostSessionEvent) {
        eventSubject.send(event)
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    // MARK: Leases and connection

    /// Keeps the connection up (reconnecting after failures) while held.
    /// Starts connecting now.
    func retain() -> HostControlLease {
        leaseCount += 1
        idleTask?.cancel()
        idleTask = nil
        if connection == nil, connectAttempt == nil, reconnectTask == nil {
            Task { _ = try? await self.connect() }
        }
        return HostControlLease { [weak self] in
            Task { @MainActor in self?.releaseLease() }
        }
    }

    private func releaseLease() {
        leaseCount = max(0, leaseCount - 1)
        guard leaseCount == 0 else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        if case .waitingToReconnect(let error) = state { state = .failed(error) }
        if connection == nil, connectAttempt == nil {
            // No reconnect follows: nothing here needs the SSH master now.
            // (An attempt under way, or a connection, releases it when it ends.)
            masterLease?.release()
            masterLease = nil
        }
        scheduleIdleDisconnectIfUnused()
    }

    /// Connects unless connected. `retryingLoginEnvironment` makes a new
    /// connection try the login shell again at once (an explicit refresh).
    @discardableResult
    func connect(retryingLoginEnvironment: Bool = false) async throws -> HostControlConnection {
        if let connection, state == .connected { return connection }
        if let connectAttempt { return try await connectAttempt.value }
        reconnectTask?.cancel()
        reconnectTask = nil
        // Runs once this call suspends, so `connectAttempt` is set first.
        let attempt = Task { @MainActor in
            defer { self.connectAttempt = nil }
            return try await self.establishConnection(retryingLoginEnvironment: retryingLoginEnvironment)
        }
        connectAttempt = attempt
        return try await attempt.value
    }

    /// Closes the connection; the next request (or lease) connects again.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        idleTask?.cancel()
        idleTask = nil
        if let connection {
            connection.close()
            connectionEnded(connection, reason: "The connection to the session host was closed.", reconnect: false)
        }
        if case .connected = state { state = .idle }
        if case .connecting = state { state = .idle }
        masterLease?.release()
        masterLease = nil
    }

    /// Reconnects, trusting whatever identity the host now reports (an
    /// explicit user decision after a mismatch).
    func trustNewIdentity(retryingLoginEnvironment: Bool = false) async throws {
        disconnect()
        // An attempt that was under way ends with the closed connection.
        if let connectAttempt { _ = try? await connectAttempt.value }
        acceptsNewIdentity = true
        defer { acceptsNewIdentity = false }
        try await connect(retryingLoginEnvironment: retryingLoginEnvironment)
    }

    private func establishConnection(retryingLoginEnvironment: Bool) async throws -> HostControlConnection {
        state = .connecting
        do {
            let connection = try await openConnection(retryingLoginEnvironment: retryingLoginEnvironment)
            reconnectFailures = 0
            connectionCount += 1
            state = .connected
            startHeartbeat(on: connection)
            scheduleIdleDisconnectIfUnused()
            return connection
        } catch {
            var failure = Self.hostedError(error)
            // Setting up sends nothing the caller asked for.
            if case .transport(let message) = failure { failure = .unavailable(message) }
            if let connection {
                connection.close()
                connectionEnded(connection, reason: nil, reconnect: false)
            }
            connectionFailed(with: failure)
            throw failure
        }
    }

    private func openConnection(retryingLoginEnvironment: Bool) async throws -> HostControlConnection {
        if let unavailableReason { throw HostedSessionError.unavailable(unavailableReason) }
        let client: HostedSessionClient
        do {
            client = try clientProvider()
        } catch {
            throw Self.hostedError(error)
        }
        executableURL = client.executableURL
        let capture = await client.resolvedLoginEnvironment(retryingNow: retryingLoginEnvironment)
        loginEnvironment = capture
        let environment = HostedSessionLoginEnvironment.helperEnvironment(
            base: ProcessInfo.processInfo.environment, login: capture?.environment
        )
        var controlPath: String?
        if let destination = host.sshDestination {
            if masterLease == nil { masterLease = masters.acquire(destination, environment: environment) }
            controlPath = await masters.waitUntilUp(destination, timeout: configuration.masterStartTimeout)
        }
        // Trust on first use, per SSH destination. This Mac is never pinned:
        // the helper only accepts this user's own local host. The helper
        // checks a trusted identity before anything else, so a host that is
        // not the trusted one is neither used nor replaced (an older daemon
        // is asked to make way only after this check).
        let trusted = acceptsNewIdentity ? nil : hostStore.trustedHostID(for: host)
        let launch = HostControlLaunch(
            executableURL: client.executableURL,
            arguments: host.arguments(sshControlPath: controlPath)
                + Self.expectedHostIDArguments(trusted)
                + ["control"],
            environment: environment
        )
        let launcher = launcher
        let channel: HostControlChannel
        do {
            channel = try await Task.detached(priority: .userInitiated) { try launcher(launch) }.value
        } catch {
            throw HostedSessionError.unavailable(
                "Could not start the cherry session client: \(error.localizedDescription)"
            )
        }
        let connection = try HostControlConnection(channel: channel)
        self.connection = connection
        Task { [weak self] in
            for await received in connection.received {
                self?.receive(received, from: connection)
            }
        }

        let (version, hostID) = try await handshake(on: connection)
        guard version == HostProtocol.version else {
            throw HostedSessionError.unavailable(
                "The session host speaks protocol \(version), but this Cherry speaks \(HostProtocol.version). "
                    + "Install the same version of Cherry on both machines."
            )
        }
        if let destination = host.sshDestination {
            // Checked here too: the helper checks only an identity it was
            // given. `sessions` keeps the trusted host's last known list.
            if let trusted, trusted != hostID {
                throw HostedSessionError.identityMismatch("Expected host identity \(trusted), received \(hostID).")
            }
            hostStore.trust(hostID, for: host)
            if controlPath == nil {
                // The helper just connected on its own, so the master can
                // authenticate now too: one that failed to start tries again.
                masters.retry(destination, environment: environment)
            }
        }
        self.hostID = hostID

        do {
            _ = try expectOK(try await send(.subscribe, on: connection))
            isSubscribed = true
        } catch HostedSessionError.rejected(let code, _) where code == HostProtocol.ErrorCode.unsupportedOperation {
            // A host without events: lists are polled instead, and the idle
            // limit needs more frequent pings.
            isSubscribed = false
        }
        announcesResyncAfterNextList = hasListed
        guard case .sessions = try await send(.list, on: connection) else {
            throw HostedSessionError.message("The session host answered the session list with something else.")
        }
        return connection
    }

    private func handshake(on connection: HostControlConnection) async throws -> (UInt32, String) {
        let timeout = configuration.handshakeTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let waiter = handshakeWaiter, waiter.connection === connection else { return }
            handshakeWaiter = nil
            waiter.continuation.resume(throwing: HostedSessionError.unavailable(
                "The session host did not answer within \(Self.seconds(timeout)) seconds. Check the host and your SSH connection."
            ))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            handshakeWaiter = (connection, continuation)
            connection.start()
        }
    }

    private func connectionFailed(with error: HostedSessionError) {
        let permanent = error.isIdentityMismatch || (error.isUnavailable && unavailableReason != nil)
        if case .message = error {
            // Nothing a retry can fix without a change in the app.
            state = .failed(error)
        } else if leaseCount > 0, !permanent {
            scheduleReconnect(after: error)
            return
        } else {
            state = .failed(error)
        }
        masterLease?.release()
        masterLease = nil
    }

    private func scheduleReconnect(after error: HostedSessionError) {
        reconnectFailures += 1
        state = .waitingToReconnect(error)
        let initial = configuration.reconnectDelay.initial
        let delay = min(initial * (1 << min(reconnectFailures - 1, 16)), configuration.reconnectDelay.maximum)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            reconnectTask = nil
            _ = try? await connect()
        }
    }

    private func startHeartbeat(on connection: HostControlConnection) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connection === connection else { return }
                // Before subscribing (or on a host without events) the idle
                // limit applies instead.
                let interval = isSubscribed
                    ? configuration.heartbeatInterval
                    : min(configuration.heartbeatInterval, HostProtocol.idleTimeout / 2)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self.connection === connection else { return }
                do {
                    _ = try await send(.ping, on: connection, timeout: configuration.pingTimeout, background: true)
                } catch {
                    guard self.connection === connection, !(error is CancellationError) else { return }
                    connection.close()
                    return
                }
            }
        }
    }

    /// Starts the idle countdown unless it runs already: only a request
    /// someone made restarts it (heartbeats keep a connection alive, not in use).
    private func scheduleIdleDisconnectIfUnused() {
        guard leaseCount == 0, !hasRequestsInUse, connection != nil, idleTask == nil else { return }
        let delay = configuration.idleDisconnectDelay
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            idleTask = nil
            guard leaseCount == 0, !hasRequestsInUse else { return }
            disconnect()
        }
    }

    private var hasRequestsInUse: Bool {
        pending.values.contains { !$0.isBackground }
    }

    // MARK: Receiving

    private func receive(_ received: HostControlConnection.Received, from connection: HostControlConnection) {
        guard connection === self.connection else { return }
        switch received {
        case .frame(let response):
            if let waiter = handshakeWaiter, waiter.connection === connection {
                handshakeWaiter = nil
                switch response.message {
                case .welcome(let version, let hostID):
                    waiter.continuation.resume(returning: (version, hostID))
                case .error(_, let message):
                    waiter.continuation.resume(throwing: HostedSessionError.unavailable(message))
                default:
                    waiter.continuation.resume(throwing: HostedSessionError.unavailable(
                        "The cherry session client did not start with the host's welcome. "
                            + "Make sure the app and its cherry helper come from the same build."
                    ))
                }
                return
            }
            if let req = response.req {
                guard let request = pending.removeValue(forKey: req) else { return }
                request.timeout?.cancel()
                applyReply(response.message, sentAtEvent: request.sentAtEvent)
                pruneSessionEventSequences()
                request.continuation.resume(returning: response.message)
                scheduleIdleDisconnectIfUnused()
            } else if case .event(let event) = response.message {
                apply(event, from: connection)
            }
            // Anything else without a `req` (attachment traffic, which
            // includes every binary frame) is not for a control connection.
        case .unreadable(let req, _):
            guard let req, let request = pending.removeValue(forKey: req) else { return }
            request.timeout?.cancel()
            pruneSessionEventSequences()
            request.continuation.resume(throwing: HostedSessionError.message(
                "The session host sent a reply this version of Cherry cannot read. "
                    + "Make sure the app and its cherry helper come from the same build."
            ))
        case .closed(let reason):
            connectionEnded(connection, reason: reason, reconnect: true)
        }
    }

    private func connectionEnded(_ connection: HostControlConnection, reason: String?, reconnect: Bool) {
        guard connection === self.connection else { return }
        self.connection = nil
        isSubscribed = false
        hostID = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingHolderRelist?.cancel()
        pendingHolderRelist = nil
        pendingHolderRelists = 0
        idleTask?.cancel()
        idleTask = nil
        let explanation = reason ?? "The connection to the session host was lost."
        if let waiter = handshakeWaiter, waiter.connection === connection {
            handshakeWaiter = nil
            waiter.continuation.resume(throwing: Self.failureBeforeWelcome(
                reason ?? "The cherry session client exited before it connected to the host."
            ))
        }
        let requests = pending
        pending.removeAll()
        pruneSessionEventSequences()
        for request in requests.values {
            request.timeout?.cancel()
            request.continuation.resume(throwing: HostedSessionError.transport(explanation))
        }
        // Waiters that followed events poll from now on.
        resumeSessionWaiters()
        // A failure while connecting is handled by the attempt.
        guard reconnect, state == .connected else { return }
        if leaseCount > 0 {
            scheduleReconnect(after: .transport(explanation))
        } else {
            state = .idle
            masterLease?.release()
            masterLease = nil
        }
    }

    /// A reply's snapshot, unless an event about that session reached the
    /// app after the request was sent (`sentAtEvent`): the event is at
    /// least as new, and a later change would send another event.
    private func applyReply(_ message: HostServerMessage, sentAtEvent: UInt64) {
        switch message {
        case .sessions(let list):
            applyList(list, sentAtEvent: sentAtEvent)
        case .created(let session):
            guard !changedByEvent(session.id, after: sentAtEvent) else { break }
            upsert(session)
        default:
            break
        }
    }

    private func changedByEvent(_ id: String, after sentAtEvent: UInt64) -> Bool {
        (sessionEventSequence[id] ?? 0) > sentAtEvent
    }

    /// Records that an event (or this app's Remove) changed the session now.
    private func noteSessionEvent(_ id: String) {
        eventSequence += 1
        sessionEventSequence[id] = eventSequence
    }

    /// Forgets what no request still waiting was sent before.
    private func pruneSessionEventSequences() {
        guard !sessionEventSequence.isEmpty else { return }
        guard let oldest = pending.values.lazy.map(\.sentAtEvent).min() else {
            sessionEventSequence.removeAll()
            return
        }
        sessionEventSequence = sessionEventSequence.filter { $0.value > oldest }
    }

    /// `incoming`, unless `known` says the program exited already: an exit
    /// is final, and a snapshot that still shows it running is older.
    private static func keepingExit(_ incoming: HostedSessionInfo, over known: HostedSessionInfo?) -> HostedSessionInfo {
        guard let known, !known.isRunning, incoming.isRunning else { return incoming }
        return known
    }

    /// The list replaces `sessions`; what changed since the previous one is
    /// published as events (events may have been missed), then `.resync`
    /// after a reconnect or a host resync.
    ///
    /// A daemon that just restarted lists a session only once its holder
    /// registered again. While its list says holders are still expected
    /// (`pendingHolders` > 0), a running session it lacks keeps its last
    /// known state (no `.removed`), and the host is listed again until the
    /// list is complete (at most `pendingHolderRelists` times).
    private func applyList(_ list: HostedSessionList, sentAtEvent: UInt64) {
        let previous = sessions
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Sessions an event told about after the list was asked for keep
        // what that event said (one it removed stays removed), and those it
        // added stay even when the snapshot is too old to list them.
        var listed = list.sessions.compactMap { session -> HostedSessionInfo? in
            guard changedByEvent(session.id, after: sentAtEvent) else {
                return Self.keepingExit(session, over: known[session.id])
            }
            return known[session.id]
        }
        let snapshotIDs = Set(list.sessions.map(\.id))
        listed += previous.filter { !snapshotIDs.contains($0.id) && changedByEvent($0.id, after: sentAtEvent) }
        if list.awaitsHolders {
            let ids = Set(listed.map(\.id))
            listed += previous.filter { $0.isRunning && !ids.contains($0.id) }
            scheduleRelistWhileHoldersPending()
        } else {
            pendingHolderRelists = 0
        }
        if expectsHolders != list.awaitsHolders { expectsHolders = list.awaitsHolders }
        sessions = listed
        defer { hasListed = true }
        guard hasListed else {
            announcesResyncAfterNextList = false
            return
        }
        let current = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in previous where current[session.id] == nil {
            publish(.removed(id: session.id))
        }
        for session in listed {
            guard let before = old[session.id] else {
                publish(.added(session))
                continue
            }
            guard before != session else { continue }
            publish(.changed(session))
            if before.isRunning, !session.isRunning {
                publish(.exited(id: session.id, exitCode: session.exitCode ?? 0, signal: session.exitSignal))
            }
        }
        if announcesResyncAfterNextList {
            announcesResyncAfterNextList = false
            publish(.resync)
        }
    }

    /// Lists again (in the background) after a list that said holders are
    /// still expected: soon at first, then less often, until a list is
    /// complete or the connection ends.
    private func scheduleRelistWhileHoldersPending() {
        guard pendingHolderRelist == nil, let connection else { return }
        let delay = pendingHolderRelists < configuration.pendingHolderRelists
            ? configuration.pendingHolderRelistInterval
            : configuration.pendingHolderSlowRelistInterval
        pendingHolderRelists += 1
        pendingHolderRelist = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pendingHolderRelist = nil
            guard self.connection === connection else { return }
            _ = try? await send(.list, on: connection, background: true)
        }
    }

    /// Never turns an exited session back into a running one.
    private func upsert(_ session: HostedSessionInfo) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let kept = Self.keepingExit(session, over: sessions[index])
            if sessions[index] != kept { sessions[index] = kept }
        } else {
            sessions.append(session)
        }
    }

    private func apply(_ event: HostSessionEvent, from connection: HostControlConnection) {
        switch event {
        case .added(let session), .changed(let session):
            noteSessionEvent(session.id)
            upsert(session)
        case .removed(let id):
            noteSessionEvent(id)
            sessions.removeAll { $0.id == id }
        case .exited(let id, let code, let signal):
            noteSessionEvent(id)
            if let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].isRunning {
                sessions[index] = sessions[index].exited(code: code, signal: signal)
            }
        case .bell, .notification, .progress:
            break
        case .resync:
            // Missed events: list again, and announce it once that arrived.
            announcesResyncAfterNextList = true
            Task { [weak self] in _ = try? await self?.send(.list, on: connection, background: true) }
            return
        }
        publish(event)
    }

    // MARK: Requests

    /// `background` marks a request the control makes on its own, which
    /// does not count as using the connection.
    private func send(
        _ message: HostClientMessage,
        on connection: HostControlConnection,
        timeout: Duration? = nil,
        background: Bool = false
    ) async throws -> HostServerMessage {
        let req = nextRequestID
        nextRequestID += 1
        let timeout = timeout ?? configuration.requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HostServerMessage, Error>) in
                guard connection === self.connection else {
                    continuation.resume(throwing: HostedSessionError.transport("The connection to the session host was lost."))
                    return
                }
                if !background {
                    idleTask?.cancel()
                    idleTask = nil
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.fail(req, with: HostedSessionError.transport(
                        "The session host did not answer within \(Self.seconds(timeout)) seconds. Check the host and your SSH connection."
                    ))
                }
                pending[req] = PendingRequest(
                    connection: connection, continuation: continuation, timeout: timer, isBackground: background,
                    sentAtEvent: eventSequence
                )
                connection.send(HostRequest(req: req, message: message)) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.fail(req, with: (error as? HostedSessionError) ?? .transport(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(req, with: CancellationError()) }
        }
    }

    private func fail(_ req: UInt64, with error: Error) {
        guard let request = pending.removeValue(forKey: req) else { return }
        request.timeout?.cancel()
        pruneSessionEventSequences()
        request.continuation.resume(throwing: error)
        scheduleIdleDisconnectIfUnused()
    }

    /// Connects, and checks the connection reaches `expectedHostID` (the
    /// identity a tab attached to) when given.
    private func connection(expecting expectedHostID: String?) async throws -> HostControlConnection {
        let connection = try await connect()
        if let expectedHostID, let hostID, hostID != expectedHostID {
            throw HostedSessionError.identityMismatch(
                "The host's identity changed (expected \(expectedHostID), received \(hostID)); "
                    + "reconnect to the intended host before using this session."
            )
        }
        return connection
    }

    private func request(
        _ message: HostClientMessage,
        expectedHostID: String? = nil,
        timeout: Duration? = nil
    ) async throws -> HostServerMessage {
        let connection = try await connection(expecting: expectedHostID)
        return try Self.checked(try await send(message, on: connection, timeout: timeout))
    }

    private static func checked(_ message: HostServerMessage) throws -> HostServerMessage {
        if case .error(let code, let message) = message {
            throw HostedSessionError.rejected(code: code, message: message)
        }
        return message
    }

    private func expectOK(_ message: HostServerMessage) throws {
        switch try Self.checked(message) {
        case .ok: return
        case let other: throw Self.unexpected(other)
        }
    }

    private static func unexpected(_ message: HostServerMessage) -> HostedSessionError {
        .message("The session host sent an unexpected answer (\(message)). Make sure the app and its cherry helper come from the same build.")
    }

    /// The session as the host reports it now: only while connected to the
    /// host `hostID` names and following its events, which keep `sessions`
    /// current. Nil otherwise (`sessions` may then be stale).
    func currentSession(_ id: String, hostID expected: String) -> HostedSessionInfo? {
        guard state == .connected, isSubscribed, hostID == expected else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Fires once a list says the host expects no more holders (at once
    /// when the latest one said so). Until it fires, or its subscription is
    /// dropped, the connection is kept up, so the host goes on being listed
    /// (`Configuration.pendingHolderSlowRelistInterval`).
    func holdersRegistered() -> AnyPublisher<Void, Never> {
        let lease = retain()
        return $expectsHolders
            .filter { !$0 }
            .map { _ in () }
            .first()
            .handleEvents(receiveCompletion: { _ in lease.release() }, receiveCancel: { lease.release() })
            .eraseToAnyPublisher()
    }

    /// The host's sessions (and `sessions` is updated).
    func list(retryingLoginEnvironment: Bool = false) async throws -> HostedSessionList {
        let connection = try await connect(retryingLoginEnvironment: retryingLoginEnvironment)
        switch try Self.checked(try await send(.list, on: connection)) {
        case .sessions(let list): return list
        case let other: throw Self.unexpected(other)
        }
    }

    /// Lists the host again every `pollInterval` while a daemon that just
    /// restarted still expects holders to register (`pendingHolders` > 0),
    /// until none is pending or `timeout` passed; returns the last list
    /// (check `isComplete`). `first` is a list taken already. A host that
    /// does not report pending holders is listed once. Throws what a list
    /// throws, and CancellationError.
    func listUntilHoldersRegistered(
        after first: HostedSessionList? = nil,
        timeout: Duration,
        pollInterval: Duration
    ) async throws -> HostedSessionList {
        let deadline = ContinuousClock.now + timeout
        var list: HostedSessionList
        if let first {
            list = first
        } else {
            list = try await self.list()
        }
        while list.awaitsHolders, ContinuousClock.now < deadline {
            try await Task.sleep(for: min(pollInterval, deadline - ContinuousClock.now))
            list = try await self.list()
        }
        return list
    }

    /// Starts a session. The host creates at most one per request ID, so a
    /// request whose answer was lost is sent once more, with the same ID, on
    /// a new connection (the old one is closed when it merely stopped
    /// answering): it returns the session the first attempt created. When
    /// that retry fails too, in any way, the first attempt's `.transport`
    /// error is thrown: the session may have been created.
    ///
    /// `request.cwd` is used as given (a directory name may end in a space);
    /// it must be absolute or start with `~`, and empty means `~`. Text a
    /// person typed is trimmed by its caller
    /// (`HostedSessionClient.hostWorkingDirectory`).
    func create(_ request: HostCreateRequest, expectedHostID: String? = nil) async throws -> HostedSessionInfo {
        var request = request
        request.cwd = try HostedSessionClient.validatedHostWorkingDirectory(request.cwd)
        guard HostProtocol.isValidSize(cols: request.cols, rows: request.rows) else {
            throw HostedSessionError.message("A session must be 2 to 500 columns and 1 to 200 rows.")
        }
        if let owner = request.owner, owner.utf8.count > HostProtocol.maxOwnerBytes {
            throw HostedSessionError.message("A session owner is at most \(HostProtocol.maxOwnerBytes) bytes.")
        }
        if let problem = HostProtocol.tagProblem(request.tags) { throw HostedSessionError.message(problem) }
        do {
            return try await createOnce(request, expectedHostID: expectedHostID)
        } catch let lost as HostedSessionError where lost.isTransportFailure {
            do {
                return try await createOnce(request, expectedHostID: expectedHostID)
            } catch {
                // Whatever stopped the retry (no connection, a host that is
                // shutting down or full, another identity, a reply this
                // version cannot read), the first attempt may have created
                // the session: the caller must treat it as maybe created.
                throw lost
            }
        }
    }

    private func createOnce(_ request: HostCreateRequest, expectedHostID: String?) async throws -> HostedSessionInfo {
        let connection = try await connection(expecting: expectedHostID)
        let answer: HostServerMessage
        do {
            answer = try Self.checked(try await send(.create(request), on: connection))
        } catch let lost as HostedSessionError where lost.isTransportFailure {
            // No answer on this connection (it timed out, or a write failed):
            // the retry must not wait on it again.
            abandon(connection, reason: lost.localizedDescription)
            throw lost
        }
        switch answer {
        case .created(let session): return session
        case let other: throw Self.unexpected(other)
        }
    }

    /// Closes a connection that stopped answering, as if it had been lost:
    /// its other requests fail, and the next request connects anew.
    private func abandon(_ connection: HostControlConnection, reason: String) {
        guard connection === self.connection else { return }
        connection.close()
        connectionEnded(connection, reason: reason, reconnect: true)
    }

    func create(
        name: String,
        cwd: String,
        command: [String] = [],
        environment: [String: String] = [:],
        owner: String? = nil,
        tags: [String: String] = [:],
        cols: Int = HostProtocol.defaultCols,
        rows: Int = HostProtocol.defaultRows,
        requestID: UUID = UUID(),
        expectedHostID: String? = nil
    ) async throws -> HostedSessionInfo {
        try await create(HostCreateRequest(
            requestID: requestID, name: name, cwd: cwd, command: command, environment: environment,
            cols: cols, rows: rows, owner: owner, tags: tags
        ), expectedHostID: expectedHostID)
    }

    /// Asks the host to end the session (hangup, then terminate and kill).
    /// Acknowledged at once; its exit arrives as an event.
    func terminate(_ id: String, expectedHostID: String? = nil) async throws {
        try expectOK(try await request(.kill(id: id), expectedHostID: expectedHostID))
    }

    /// Forgets an exited session and its retained history.
    func remove(_ id: String, expectedHostID: String? = nil) async throws {
        try expectOK(try await request(.remove(id: id), expectedHostID: expectedHostID))
        // A list or Created answered after this must not bring it back.
        noteSessionEvent(id)
        sessions.removeAll { $0.id == id }
    }

    /// Types into the session without attaching. Longer input goes in
    /// several requests (`HostProtocol.maxInputBytes` each), in order. When
    /// the first request fails, its error is thrown (for `.transport`, that
    /// part may or may not have been typed). When a later one fails,
    /// `HostInputPartiallyDelivered` is thrown instead: the parts before it
    /// were typed.
    func sendInput(_ id: String, _ data: Data, expectedHostID: String? = nil) async throws {
        var offset = data.startIndex
        repeat {
            let end = data.index(offset, offsetBy: HostProtocol.maxInputBytes, limitedBy: data.endIndex) ?? data.endIndex
            do {
                try expectOK(try await request(
                    .sendInput(id: id, data: Data(data[offset..<end])), expectedHostID: expectedHostID
                ))
            } catch {
                let delivered = data.distance(from: data.startIndex, to: offset)
                guard delivered > 0 else { throw error }
                throw HostInputPartiallyDelivered(
                    deliveredBytes: delivered,
                    totalBytes: data.count,
                    failedPartBytes: data.distance(from: offset, to: end),
                    failure: Self.hostedError(error)
                )
            }
            offset = end
        } while offset < data.endIndex
    }

    /// The session's screen as text; with `scrollback`, its retained
    /// history first. `maxLines`: only the last this many lines of that
    /// (a host that does not know the limit sends all of them).
    func screen(
        _ id: String,
        scrollback: Bool = false,
        maxLines: Int? = nil,
        expectedHostID: String? = nil
    ) async throws -> HostScreenText {
        let timeout = scrollback && maxLines == nil ? configuration.requestTimeout * 2 : configuration.requestTimeout
        let message = HostClientMessage.screen(id: id, scrollback: scrollback, maxLines: maxLines)
        switch try await request(message, expectedHostID: expectedHostID, timeout: timeout) {
        case .screenText(let screen): return screen
        case let other: throw Self.unexpected(other)
        }
    }

    /// Renames the session or replaces its tags; nil keeps a field.
    func update(
        _ id: String,
        name: String? = nil,
        tags: [String: String]? = nil,
        expectedHostID: String? = nil
    ) async throws {
        if let tags, let problem = HostProtocol.tagProblem(tags) { throw HostedSessionError.message(problem) }
        try expectOK(try await request(.update(id: id, name: name, tags: tags), expectedHostID: expectedHostID))
    }

    /// Waits until `satisfied` holds for the session (nil once it is gone),
    /// following events, or polling the list on a host without events or
    /// after the connection was lost. False when `timeout` passes first, or
    /// at once when another identity answers for the host (`state` is then
    /// `.failed(.identityMismatch)`): nothing that host says is about this
    /// session. Throws only CancellationError.
    func waitForSession(
        _ id: String,
        timeout: Duration,
        until satisfied: (HostedSessionInfo?) -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if satisfied(sessions.first { $0.id == id }) { return true }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return false }
            switch state {
            case .failed(let error) where error.isIdentityMismatch:
                return false
            case .connected where isSubscribed, .connecting, .waitingToReconnect:
                // Events, or the reconnect under way (with its backoff), wake it.
                await waitForSessionsChange(until: deadline)
            case .connected, .idle, .failed:
                try await Task.sleep(for: min(configuration.pollInterval, deadline - ContinuousClock.now))
                _ = try? await list()
            }
        }
    }

    private func waitForSessionsChange(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionWaiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(until: deadline)
                    self?.sessionWaiters.removeValue(forKey: id)?.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.sessionWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func resumeSessionWaiters() {
        let waiters = sessionWaiters.values
        sessionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Helpers

    private static func hostedError(_ error: Error) -> HostedSessionError {
        (error as? HostedSessionError) ?? .message(error.localizedDescription)
    }

    /// `--expected-host-id` for a trusted identity. Hosts' identities are
    /// UUIDs, which is all the helper accepts; anything else is left to the
    /// app's own check of the Welcome.
    static func expectedHostIDArguments(_ trusted: String?) -> [String] {
        guard let trusted, UUID(uuidString: trusted) != nil else { return [] }
        return ["--expected-host-id", trusted]
    }

    /// Why a helper ended before the host's Welcome. The helper refuses a
    /// host other than the expected one with "host identity changed
    /// (expected E, received R)"; that is an identity mismatch, not an
    /// unreachable host.
    static func failureBeforeWelcome(_ reason: String) -> HostedSessionError {
        guard let marker = reason.range(of: "host identity changed") else { return .unavailable(reason) }
        guard let start = reason[marker.upperBound...].range(of: "(expected ") else { return .identityMismatch(reason) }
        let rest = reason[start.upperBound...]
        guard let separator = rest.range(of: ", received "),
              let end = rest[separator.upperBound...].firstIndex(of: ")")
        else { return .identityMismatch(reason) }
        let expected = rest[..<separator.lowerBound]
        let received = rest[separator.upperBound..<end]
        return .identityMismatch("Expected host identity \(expected), received \(received).")
    }

    private static func seconds(_ duration: Duration) -> Int {
        max(1, Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18).rounded(.up)))
    }
}

/// Input the host took only a first part of: it went in several requests
/// (`HostControl.sendInput`), and one after the first failed. The first
/// `deliveredBytes` reached the program, in order; the request that failed
/// (`failedPartBytes`; for `.transport`, it may or may not have been typed:
/// `unconfirmedBytes`) and those after it were not sent again. Resending
/// all of the input would type the first part twice.
struct HostInputPartiallyDelivered: Error, LocalizedError, Equatable, Sendable {
    let deliveredBytes: Int
    let totalBytes: Int
    /// The bytes of the request that failed.
    let failedPartBytes: Int
    let failure: HostedSessionError

    /// Bytes after `deliveredBytes` that may have been typed anyway: the
    /// part that failed, when no definite answer came for it (a transport
    /// failure: the connection failed or timed out after it was sent). 0
    /// when the host refused it or it never reached the host.
    var unconfirmedBytes: Int {
        failure.isTransportFailure ? failedPartBytes : 0
    }

    var errorDescription: String? {
        let reason = failure.errorDescription ?? failure.localizedDescription
        guard unconfirmedBytes > 0 else {
            return "Only the first \(deliveredBytes) of \(totalBytes) bytes reached the program: \(reason)"
        }
        return "Only the first \(deliveredBytes) of \(totalBytes) bytes are known to have reached the program "
            + "(the \(unconfirmedBytes) after them may have too; the host's answer was lost): \(reason)"
    }
}

/// One `HostControl` per host (`HostedSessionHost.id`) for the whole app.
@MainActor
final class HostControlRegistry {
    static let shared = HostControlRegistry()

    private var controls: [String: HostControl] = [:]
    private let makeControl: @MainActor (HostedSessionHost) -> HostControl

    init(makeControl: @escaping @MainActor (HostedSessionHost) -> HostControl = { HostControl(host: $0) }) {
        self.makeControl = makeControl
    }

    func control(for host: HostedSessionHost) -> HostControl {
        if let control = controls[host.id] { return control }
        let control = makeControl(host)
        controls[host.id] = control
        return control
    }

    /// The controls created so far.
    var all: [HostControl] { Array(controls.values) }

    func disconnectAll() {
        for control in controls.values { control.disconnect() }
    }
}
