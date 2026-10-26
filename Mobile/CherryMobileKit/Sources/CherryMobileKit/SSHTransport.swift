import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// One SSH connection to a Mac (swift-nio-ssh): public key login with this
/// device's Ed25519 key, the host key checked against its pin, and session
/// channels on it, each an exec with or without a PTY.
final class SSHConnection: Sendable {
    enum Failure: Error, Equatable {
        case hostKeyMismatch(expected: String, presented: String)
        case authenticationFailed
        case unreachable(String)
        case timedOut
        case closed
        case requestRefused(String)
    }

    private let channel: any Channel
    /// The host key the Mac presented, as OpenSSH prints its fingerprint.
    let presentedFingerprint: String

    private init(channel: any Channel, presentedFingerprint: String) {
        self.channel = channel
        self.presentedFingerprint = presentedFingerprint
    }

    var isActive: Bool { channel.isActive }

    /// Connects and logs in. With `pinnedFingerprint` nil any host key is
    /// accepted (and reported in `presentedFingerprint`); otherwise only
    /// that one.
    static func connect(
        host: String,
        port: Int,
        user: String,
        key: Curve25519.Signing.PrivateKey,
        pinnedFingerprint: String?,
        timeout: Duration = .seconds(15)
    ) async throws -> SSHConnection {
        let hostKeys = HostKeyCheck(pinned: pinnedFingerprint)
        let login = LoginState()
        let group = MultiThreadedEventLoopGroup.singleton
        let authenticated = group.next().makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: KeyLoginDelegate(user: user, key: key, state: login, authenticated: authenticated),
                            serverAuthDelegate: HostKeyDelegate(check: hostKeys)
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(ConnectionWatcher(authenticated: authenticated))
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            authenticated.fail(Failure.closed)
            throw Failure.unreachable(Self.connectProblem(error, host: host, port: port))
        }
        // A promise completes once: whichever comes first, the login or this.
        let deadline = authenticated.futureResult.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout.nanoseconds))) {
            authenticated.fail(Failure.timedOut)
        }
        do {
            try await authenticated.futureResult.get()
            deadline.cancel()
        } catch {
            try? await channel.close().get()
            if let mismatch = hostKeys.mismatch { throw mismatch }
            if login.wasRefused { throw Failure.authenticationFailed }
            if let failure = error as? Failure { throw failure }
            throw Failure.unreachable(Self.describe(error))
        }
        return SSHConnection(channel: channel, presentedFingerprint: hostKeys.presented ?? "SHA256:?")
    }

    /// A session channel running `command`, with a PTY of `pty`'s size when
    /// given. Its standard output streams; standard error is kept.
    func session(command: String, pty: TerminalSize? = nil) async throws -> SSHSessionChannel {
        let state = SessionState()
        let (output, continuation) = AsyncStream<Data>.makeStream()
        let promise = channel.eventLoop.makePromise(of: (any Channel).self)
        let parent = channel
        channel.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(Failure.requestRefused("channel type"))
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SessionHandler(state: state, output: continuation)
                        )
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        let child: any Channel
        do {
            child = try await promise.futureResult.get()
        } catch {
            continuation.finish()
            throw Failure.closed
        }
        let session = SSHSessionChannel(channel: child, state: state, output: output)
        do {
            if let pty {
                try await session.request(SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: pty.columns,
                    terminalRowHeight: pty.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                ), name: "pty")
            }
            try await session.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), name: "exec")
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    /// Runs `command` without a PTY to its end, its standard input closed.
    func run(_ command: String, timeout: Duration = .seconds(20)) async throws -> SSHCommandResult {
        let session = try await session(command: command)
        await session.closeInput()
        let timedOut = NIOLockedValueBox(false)
        let timer = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLockedValue { $0 = true }
            await session.close()
        }
        defer { timer.cancel() }
        var stdout = Data()
        for await chunk in session.output {
            stdout.append(chunk)
        }
        let exit = await session.exit()
        if timedOut.withLockedValue({ $0 }) { throw Failure.timedOut }
        return SSHCommandResult(stdout: stdout, stderr: session.standardError, status: exit)
    }

    func close() async {
        try? await channel.close().get()
    }

    /// Why the TCP connect to `host`:`port` failed, with what to check.
    static func connectProblem(_ error: any Error, host: String, port: Int) -> String {
        let codes = errnoCodes(in: error)
        if codes.contains(ECONNREFUSED) {
            return "nothing answers SSH at \(host):\(port). Turn on Remote Login on that Mac "
                + "(System Settings › General › Sharing)."
        }
        if let error = error as? NIOConnectionError, error.connectionErrors.isEmpty,
           error.dnsAError != nil || error.dnsAAAAError != nil {
            return "no address for \(host). Check the name, or use the Mac's Tailscale or LAN address."
        }
        let unanswered: Set<Int32> = [ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN]
        if codes.contains(where: unanswered.contains) || error is ChannelError {
            return "\(host) doesn't answer (\(describe(error))). Check the address; for a Tailscale "
                + "address, that Tailscale is on here; on Wi-Fi, that you're on the Mac's network "
                + "and allowed Cherry Local Network access."
        }
        return describe(error)
    }

    private static func errnoCodes(in error: any Error) -> [Int32] {
        if let error = error as? IOError { return [error.errnoCode] }
        if let error = error as? NIOConnectionError {
            return error.connectionErrors.flatMap { errnoCodes(in: $0.error) }
        }
        return []
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .timedOut: return "timed out"
            case .closed: return "the connection closed"
            default: return "\(failure)"
            }
        }
        if let error = error as? IOError { return error.description }
        return String(describing: error)
    }
}

struct SSHCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    /// The exit status; nil when the command ended without one (a signal,
    /// a closed channel).
    let status: Int?

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A session channel: its program's standard output as a stream, its
/// standard error kept (the first 64 KiB), its exit status.
final class SSHSessionChannel: Sendable {
    private let channel: any Channel
    private let state: SessionState
    let output: AsyncStream<Data>

    fileprivate init(channel: any Channel, state: SessionState, output: AsyncStream<Data>) {
        self.channel = channel
        self.state = state
        self.output = output
    }

    var standardError: Data { state.standardError }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let message = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data)))
        do {
            try await channel.writeAndFlush(message).get()
        } catch {
            throw SSHConnection.Failure.closed
        }
    }

    /// Ends the program's standard input (EOF).
    func closeInput() async {
        try? await channel.close(mode: .output).get()
    }

    func windowChange(_ size: TerminalSize) async throws {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        do {
            try await channel.triggerUserOutboundEvent(request).get()
        } catch {
            throw SSHConnection.Failure.closed
        }
    }

    /// Waits for the channel to close; its program's exit status, nil when
    /// it gave none.
    func exit() async -> Int? {
        try? await channel.closeFuture.get()
        return state.exitStatus
    }

    func close() async {
        try? await channel.close().get()
    }

    /// Sends a request that wants a reply and waits for it.
    fileprivate func request(_ event: any Sendable, name: String) async throws {
        let reply = channel.eventLoop.makePromise(of: Bool.self)
        state.expectReply(reply)
        do {
            try await channel.triggerUserOutboundEvent(event).get()
        } catch {
            throw SSHConnection.Failure.closed
        }
        guard try await reply.futureResult.get() else {
            throw SSHConnection.Failure.requestRefused(name)
        }
    }
}

// MARK: - Shared state

/// What a session channel's handler learns, read from any thread.
private final class SessionState: Sendable {
    private struct Values {
        var standardError = Data()
        var exitStatus: Int?
        var replies: [EventLoopPromise<Bool>] = []
        var closed = false
    }

    private let values = NIOLockedValueBox(Values())
    static let standardErrorLimit = 64 * 1_024

    var standardError: Data { values.withLockedValue { $0.standardError } }
    var exitStatus: Int? { values.withLockedValue { $0.exitStatus } }

    func appendStandardError(_ data: Data) {
        values.withLockedValue { values in
            let room = Self.standardErrorLimit - values.standardError.count
            if room > 0 { values.standardError.append(data.prefix(room)) }
        }
    }

    func setExitStatus(_ status: Int) {
        values.withLockedValue { $0.exitStatus = status }
    }

    func expectReply(_ promise: EventLoopPromise<Bool>) {
        let closed = values.withLockedValue { values in
            if !values.closed { values.replies.append(promise) }
            return values.closed
        }
        if closed { promise.fail(SSHConnection.Failure.closed) }
    }

    func reply(_ success: Bool) {
        let promise = values.withLockedValue { values in
            values.replies.isEmpty ? nil : values.replies.removeFirst()
        }
        promise?.succeed(success)
    }

    func close() {
        let pending = values.withLockedValue { values in
            values.closed = true
            defer { values.replies.removeAll() }
            return values.replies
        }
        for promise in pending { promise.fail(SSHConnection.Failure.closed) }
    }
}

private final class HostKeyCheck: Sendable {
    let pinned: String?
    private let values = NIOLockedValueBox<(presented: String?, mismatch: SSHConnection.Failure?)>((nil, nil))

    init(pinned: String?) {
        self.pinned = pinned
    }

    var presented: String? { values.withLockedValue { $0.presented } }
    var mismatch: SSHConnection.Failure? { values.withLockedValue { $0.mismatch } }

    /// Whether to trust `fingerprint`; a mismatch is kept for the caller.
    func accept(_ fingerprint: String) -> Bool {
        values.withLockedValue { values in
            values.presented = fingerprint
            if let pinned, pinned != fingerprint {
                values.mismatch = .hostKeyMismatch(expected: pinned, presented: fingerprint)
                return false
            }
            return true
        }
    }
}

private final class LoginState: Sendable {
    private let refused = NIOLockedValueBox(false)
    var wasRefused: Bool { refused.withLockedValue { $0 } }
    func markRefused() { refused.withLockedValue { $0 = true } }
}

// MARK: - Handlers

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let check: HostKeyCheck

    init(check: HostKeyCheck) {
        self.check = check
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if check.accept(SSHKeys.fingerprint(of: hostKey)) {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHConnection.Failure.hostKeyMismatch(
                expected: check.pinned ?? "",
                presented: check.presented ?? ""
            ))
        }
    }
}

/// Offers this device's key once; a second question means it was refused,
/// which ends the login at once (NIOSSH would wait for the server).
private final class KeyLoginDelegate: NIOSSHClientUserAuthenticationDelegate {
    let user: String
    let key: Curve25519.Signing.PrivateKey
    let state: LoginState
    let authenticated: EventLoopPromise<Void>
    private var offered = false

    init(user: String, key: Curve25519.Signing.PrivateKey, state: LoginState, authenticated: EventLoopPromise<Void>) {
        self.user = user
        self.key = key
        self.state = state
        self.authenticated = authenticated
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            state.markRefused()
            authenticated.fail(SSHConnection.Failure.authenticationFailed)
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user,
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        ))
    }
}

/// Completes `authenticated` once the login succeeded, and fails it (and
/// closes the connection) on the first error or close before that.
private final class ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(SSHConnection.Failure.closed)
        context.fireChannelInactive()
    }
}

private final class SessionHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let state: SessionState
    private let output: AsyncStream<Data>.Continuation

    init(state: SessionState, output: AsyncStream<Data>.Continuation) {
        self.state = state
        self.output = output
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch message.type {
        case .channel: output.yield(bytes)
        case .stdErr: state.appendStandardError(bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            state.setExitStatus(status.exitStatus)
        case is ChannelSuccessEvent:
            state.reply(true)
        case is ChannelFailureEvent:
            state.reply(false)
        case ChannelEvent.inputClosed:
            output.finish()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        output.finish()
        state.close()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
