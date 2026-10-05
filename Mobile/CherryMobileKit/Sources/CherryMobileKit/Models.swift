import Foundation

/// A Mac the phone reaches over SSH.
public struct MacEndpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// What the app calls it ("patstudio").
    public var name: String
    /// A host name or address: a Tailscale name, `100.x.y.z`, or a LAN name.
    public var host: String
    public var port: Int
    public var user: String
    /// The `cherry` helper on that Mac; nil looks in the usual places
    /// (`~/Applications/Cherry.app`, then `/Applications/Cherry.app`).
    public var cherryPath: String?
    /// The Mac's host key as OpenSSH prints its fingerprint
    /// (`SHA256:…`), pinned on the first connect; nil until then.
    public var hostKeyFingerprint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        user: String,
        cherryPath: String? = nil,
        hostKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.cherryPath = cherryPath
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

/// What an agent needs from you, as Cherry on its Mac sees it.
public enum AgentAttention: String, Codable, Hashable, Sendable, CaseIterable {
    /// An approval prompt waits (`agent_activity_state` `permission`).
    case approval
    /// A question with a choice waits (`needs_input`).
    case question
    /// It finished a turn and waits at its composer.
    case resultReady
    case working
    case idle
    case error
    /// Its Mac's Cherry did not say (not running there, or not an agent).
    case unknown

    /// Whether the inbox puts it first.
    public var needsYou: Bool {
        switch self {
        case .approval, .question, .resultReady, .error: true
        case .working, .idle, .unknown: false
        }
    }
}

public enum SessionKind: Hashable, Codable, Sendable {
    /// An agent CLI: "claude", "codex", "pi", …
    case agent(String)
    case command
    case terminal
}

/// One of a Mac's host sessions, as the phone lists it.
public struct MobileSession: Identifiable, Hashable, Sendable {
    /// The host's session id.
    public var id: String
    public var macID: UUID
    public var title: String
    /// Its working directory on the Mac, when known.
    public var directory: String?
    public var kind: SessionKind
    public var isRunning: Bool
    public var attention: AgentAttention
    /// A Cherry task's label or result summary, else nil.
    public var detail: String?
    /// The shared grid its clients see now.
    public var size: TerminalSize
    /// When its screen last changed, when known.
    public var changedAt: Date?

    public init(
        id: String,
        macID: UUID,
        title: String,
        directory: String? = nil,
        kind: SessionKind,
        isRunning: Bool = true,
        attention: AgentAttention = .unknown,
        detail: String? = nil,
        size: TerminalSize = TerminalSize(columns: 120, rows: 32),
        changedAt: Date? = nil
    ) {
        self.id = id
        self.macID = macID
        self.title = title
        self.directory = directory
        self.kind = kind
        self.isRunning = isRunning
        self.attention = attention
        self.detail = detail
        self.size = size
        self.changedAt = changedAt
    }
}

public struct TerminalSize: Hashable, Codable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// A session's screen as its host keeps it: text only, at the session's
/// own width.
public struct ScreenSnapshot: Hashable, Sendable {
    public var lines: [String]
    public var size: TerminalSize
    public var takenAt: Date

    public init(lines: [String], size: TerminalSize, takenAt: Date = Date()) {
        self.lines = lines
        self.size = size
        self.takenAt = takenAt
    }
}

/// A key the phone types into a session without a terminal open: the
/// quick replies, and the inbox's approve and answer buttons.
public enum MobileKey: Hashable, Sendable {
    case text(String)
    case enter
    case escape
    case tab
    case backspace
    case up
    case down
    case left
    case right
    case controlC

    /// The bytes a legacy terminal types for it (cursor keys as `ESC [ x`;
    /// the host rewrites them for a program that set application cursor
    /// keys).
    public var bytes: Data {
        switch self {
        case .text(let text): Data(text.utf8)
        case .enter: Data([0x0D])
        case .escape: Data([0x1B])
        case .tab: Data([0x09])
        case .backspace: Data([0x7F])
        case .up: Data("\u{1B}[A".utf8)
        case .down: Data("\u{1B}[B".utf8)
        case .right: Data("\u{1B}[C".utf8)
        case .left: Data("\u{1B}[D".utf8)
        case .controlC: Data([0x03])
        }
    }
}

/// What a connection reports by itself.
public enum MacEvent: Hashable, Sendable {
    /// Sessions were added, removed, renamed, or changed state: list again.
    case sessionsChanged
    /// The session's screen changed.
    case screenChanged(sessionID: String)
    case exited(sessionID: String, status: Int32?)
    /// The connection ended; the reason is for people.
    case disconnected(reason: String)
}

public enum MacConnectionError: Error, Hashable, Sendable, LocalizedError {
    case unreachable(String)
    case authenticationFailed
    /// The Mac's host key is not the pinned one.
    case hostKeyMismatch(expected: String, presented: String)
    /// No session host of this version runs there (`--no-start`).
    case noSessionHost(String)
    case cherryNotFound
    case protocolMismatch(String)
    case sessionGone(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Can't reach the Mac: \(why)"
        case .authenticationFailed: "The Mac refused this iPhone's key. Add its public key to ~/.ssh/authorized_keys there."
        case .hostKeyMismatch(let expected, let presented):
            "The Mac's host key changed (expected \(expected), got \(presented)). Check it before trusting it."
        case .noSessionHost(let why): "No Cherry session host runs on the Mac: \(why)"
        case .cherryNotFound: "Cherry isn't installed on the Mac, or not where the app looked."
        case .protocolMismatch(let why): "This app and the Mac's Cherry don't speak the same version: \(why)"
        case .sessionGone(let id): "The session \(id) has ended."
        case .failed(let why): why
        }
    }
}
