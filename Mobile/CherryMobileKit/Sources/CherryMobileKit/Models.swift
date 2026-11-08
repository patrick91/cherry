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
    /// The host keys the Mac's pairing code listed (`SHA256:…`): until one
    /// is pinned, a connect accepts only these, and pins the one presented
    /// without asking. Nil for a Mac added by hand.
    public var pairedHostKeyFingerprints: [String]?
    /// The identity of the Mac's session host (its `Welcome`'s `host_id`),
    /// pinned on the first connect like the host key: the phone then only
    /// talks to that host (`cherry … --expected-host-id`). Nil until then.
    public var expectedHostID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        user: String,
        cherryPath: String? = nil,
        hostKeyFingerprint: String? = nil,
        pairedHostKeyFingerprints: [String]? = nil,
        expectedHostID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.cherryPath = cherryPath
        self.hostKeyFingerprint = hostKeyFingerprint
        self.pairedHostKeyFingerprints = pairedHostKeyFingerprints
        self.expectedHostID = expectedHostID
    }
}

/// What a session's program needs from you, as it says itself: its
/// program status (OSC 7501), which its Mac's session host keeps.
public enum AgentAttention: String, Codable, Hashable, Sendable, CaseIterable {
    /// It waits for your approval (`blocked`, `kind=permission`).
    case approval
    /// It waits for an answer or a credential (`blocked`, another kind).
    case question
    /// It finished, and the result waits for you (`done`).
    case resultReady
    case working
    case idle
    case error
    /// It reports nothing: a program or version that doesn't speak the
    /// protocol (Codex, Amp), or not an agent.
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
    /// The folder of the project the Mac's Cherry opened it in, when it did.
    public var project: String?
    public var kind: SessionKind
    public var isRunning: Bool
    public var attention: AgentAttention
    /// What its program says it is doing, waiting for or finished (its
    /// status message), else nil.
    public var detail: String?
    /// The shared grid its clients see now.
    public var size: TerminalSize
    /// Since when its attention is what it is, when this connection saw it
    /// change.
    public var changedAt: Date?

    public init(
        id: String,
        macID: UUID,
        title: String,
        directory: String? = nil,
        project: String? = nil,
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
        self.project = project
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

/// The key modes a session's program set, as its host reports them: how
/// the keys the phone types must look for it to read them as a terminal
/// would type them.
public struct KeyModes: Hashable, Sendable {
    /// Application cursor keys (DECCKM: `less`, `vim`).
    public var applicationCursorKeys: Bool
    /// The kitty keyboard protocol flags (0: legacy keys).
    public var kittyKeyboardFlags: UInt32
    /// Bracketed paste (DECSET 2004); nil when the host can't tell.
    public var bracketedPaste: Bool?

    public init(applicationCursorKeys: Bool = false, kittyKeyboardFlags: UInt32 = 0, bracketedPaste: Bool? = nil) {
        self.applicationCursorKeys = applicationCursorKeys
        self.kittyKeyboardFlags = kittyKeyboardFlags
        self.bracketedPaste = bracketedPaste
    }

    /// The kitty flag that reports every key, Tab included, as an escape
    /// code.
    static let reportAllKeysAsEscapeCodes: UInt32 = 0b1000
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

    /// Between a reply's text and the Enter that submits it
    /// (`MacConnection.submit`), as the Mac's Cherry waits
    /// (`terminalSubmitPause`).
    public static let submitPause: Duration = .milliseconds(150)

    /// The bytes a terminal in legacy key mode types for it.
    public var bytes: Data { bytes(in: KeyModes()) }

    /// The bytes for a program in `modes`, as the Mac's Cherry types keys
    /// through the host (`cherry keys`, `TerminalInputNormalizer`): the host
    /// types what it is sent, so the phone encodes them itself.
    /// - Arrows are `ESC O x` while application cursor keys are on and the
    ///   kitty flags are 0 (the kitty encoding sends them as CSI).
    /// - Tab is `CSI 9 u` when the kitty flags report every key.
    /// - Text with a line break is bracketed as a paste unless the program
    ///   is known not to take one, so an agent's composer gets it as one
    ///   message instead of submitting each line.
    public func bytes(in modes: KeyModes) -> Data {
        let cursor = modes.applicationCursorKeys && modes.kittyKeyboardFlags == 0 ? "\u{1B}O" : "\u{1B}["
        switch self {
        case .text(let text):
            guard modes.bracketedPaste != false, text.contains(where: \.isNewline) else { return Data(text.utf8) }
            // Without ESC, nothing in it can end the paste early.
            let pasted = text.replacingOccurrences(of: "\u{1B}", with: "")
            return Data("\u{1B}[200~\(pasted)\u{1B}[201~".utf8)
        case .enter: return Data([0x0D])
        case .escape: return Data([0x1B])
        case .tab:
            return modes.kittyKeyboardFlags & KeyModes.reportAllKeysAsEscapeCodes != 0
                ? Data("\u{1B}[9u".utf8) : Data([0x09])
        case .backspace: return Data([0x7F])
        case .up: return Data((cursor + "A").utf8)
        case .down: return Data((cursor + "B").utf8)
        case .right: return Data((cursor + "C").utf8)
        case .left: return Data((cursor + "D").utf8)
        case .controlC: return Data([0x03])
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
    /// The Mac's `cherry` predates `cherry host transcript`.
    case transcriptUnsupported
    /// The session runs no agent whose conversation the Mac can read.
    case noConversation
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
        case .transcriptUnsupported: "The Mac's Cherry can't read agent conversations yet. Update Cherry there."
        case .noConversation: "No Claude Code, Codex, Pi or Amp conversation found in this session."
        case .failed(let why): why
        }
    }
}
