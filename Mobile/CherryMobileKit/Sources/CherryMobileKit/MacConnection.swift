import Foundation

/// Makes connections to Macs: `SSHMacConnector` for real ones, `DemoMac`
/// for the demo and the app's previews and tests.
public protocol MacConnector: Sendable {
    func connect(to endpoint: MacEndpoint) async throws -> any MacConnection
}

/// One Mac's host, over one connection. It lists and reads without
/// changing anything there (`cherry control --no-start`), types into
/// sessions, and attaches terminals.
public protocol MacConnection: AnyObject, Sendable {
    /// The Mac connected to, its `hostKeyFingerprint` the key it presented:
    /// on a first connect (none pinned) the app shows it and saves it.
    var endpoint: MacEndpoint { get }

    /// The host's sessions, with their agents' state where the Mac's Cherry
    /// reports it.
    func sessions() async throws -> [MobileSession]

    /// The session's screen as the host keeps it. Never resizes it.
    func screen(of sessionID: String) async throws -> ScreenSnapshot

    /// Types `keys` into the session through the host, as one input.
    func send(_ keys: [MobileKey], to sessionID: String) async throws

    /// What the connection reports by itself, until it ends.
    func events() -> AsyncStream<MacEvent>

    /// Checks that the Mac still answers within `timeout`. A connection
    /// that does not is ended: its subscribers hear `disconnected`, and its
    /// terminals detach.
    func ping(timeout: Duration) async throws

    /// The conversation of the agent the session runs, as the Mac's `cherry
    /// host transcript` reads it from the agent's own session: the latest
    /// `limit` entries, or what came after `cursor` (an earlier read's).
    func transcript(of sessionID: String, after cursor: String?, limit: Int) async throws -> AgentTranscript

    /// Attaches a terminal to the session at `size` (its PTY size; the
    /// host's shared grid is the smallest among its clients).
    func attach(_ sessionID: String, size: TerminalSize) async throws -> any TerminalAttachment

    func disconnect() async
}

extension MacConnection {
    /// Types `text` into the session and submits it: the text, then Enter
    /// on its own `MobileKey.submitPause` later. Sent as one input, an
    /// agent such as Claude Code takes both as a paste, and the Enter only
    /// starts a new line in its composer.
    public func submit(_ text: String, to sessionID: String) async throws {
        try await send([.text(text)], to: sessionID)
        try? await Task.sleep(for: MobileKey.submitPause)
        try await send([.enter], to: sessionID)
    }
}

/// A terminal attached to a session (`cherry attach` on the Mac): its
/// output for a `UITerminalView`, and the bytes typed into it.
public protocol TerminalAttachment: AnyObject, Sendable {
    /// The terminal's output, until it detaches or the session ends.
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(_ size: TerminalSize) async throws
    func detach() async
}

/// This device's SSH identity.
public protocol DeviceIdentity: Sendable {
    /// The public key as a line for `authorized_keys`
    /// (`ssh-ed25519 AAAA… cherry-ios`), made on first use.
    func publicKey() throws -> String
}
