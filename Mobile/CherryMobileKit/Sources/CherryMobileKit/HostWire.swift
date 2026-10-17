import Foundation

/// The host protocol (v7, Host/crates/cherry-protocol) as `cherry control`
/// relays it on its standard input and output: the few messages the phone
/// sends and reads. The Mac app's `Sources/Cherry/HostControlProtocol.swift`
/// encodes the same frames; this copy goes once both share a core
/// (docs/specs/ios-app.md, Code sharing).
///
/// A frame is a 4-byte big-endian length, then that many bytes. A body
/// whose first byte is `{` is JSON: requests are tagged by `op`, replies and
/// events by `type`. A request may carry `"req": <u64>`, which the host
/// echoes on its reply. Events carry none. Any other body is a binary frame
/// of attachment traffic, which a control connection skips.
enum HostWire {
    static let version: UInt32 = 7
    static let maxFrameBytes = 16 * 1_024 * 1_024
    /// The most bytes one `SendInput` carries.
    static let maxInputBytes = 64 * 1_024
    /// A subscribed connection sends `Ping` at least this often (the host
    /// drops one silent for 45 s).
    static let heartbeatInterval: Duration = .seconds(15)

    enum ErrorCode {
        static let versionMismatch = "version_mismatch"
        static let unknownSession = "unknown_session"
        static let notRunning = "not_running"
    }

    static let jsonMarker = UInt8(ascii: "{")

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Length prefix + body.
    static func frame(body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= maxFrameBytes else {
            throw HostWireError.tooLarge(body.count)
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    static func encode(_ request: HostWireRequest) throws -> Data {
        try frame(body: encoder.encode(request))
    }
}

enum HostWireError: Error, Equatable {
    /// A length prefix of zero or over the limit: the stream is not frames.
    case invalidLength(Int)
    case tooLarge(Int)
}

/// Splits a byte stream into frame bodies; bytes may arrive in any pieces.
struct HostWireFrameDecoder {
    private var buffer: [UInt8] = []
    private var start = 0

    var bufferedByteCount: Int { buffer.count - start }

    mutating func append(_ data: Data) {
        if start > 0, start >= 64 * 1_024, start * 2 >= buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete frame body, or nil until more bytes arrive.
    mutating func nextFrame() throws -> Data? {
        guard bufferedByteCount >= 4 else { return nil }
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length > 0, length <= HostWire.maxFrameBytes else {
            throw HostWireError.invalidLength(length)
        }
        guard bufferedByteCount >= 4 + length else { return nil }
        let body = Data(buffer[(start + 4)..<(start + 4 + length)])
        start += 4 + length
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        return body
    }
}

/// The requests the phone's control connection sends.
enum HostWireMessage: Equatable, Sendable {
    case list
    case subscribe
    case ping
    /// `maxLines`: only the last this many lines; nil for all.
    case screen(id: String, scrollback: Bool, maxLines: Int?)
    case sendInput(id: String, data: Data)

    var op: String {
        switch self {
        case .list: "list"
        case .subscribe: "subscribe"
        case .ping: "ping"
        case .screen: "screen"
        case .sendInput: "send_input"
        }
    }
}

struct HostWireRequest: Encodable, Equatable, Sendable {
    var req: UInt64?
    var message: HostWireMessage

    private enum CodingKeys: String, CodingKey {
        case op, req, id, data, scrollback
        case maxLines = "max_lines"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message.op, forKey: .op)
        try container.encodeIfPresent(req, forKey: .req)
        switch message {
        case .list, .subscribe, .ping:
            break
        case .screen(let id, let scrollback, let maxLines):
            try container.encode(id, forKey: .id)
            try container.encode(scrollback, forKey: .scrollback)
            try container.encodeIfPresent(maxLines.map { UInt32(clamping: max($0, 1)) }, forKey: .maxLines)
        case .sendInput(let id, let data):
            try container.encode(id, forKey: .id)
            // Standard padded base64, as the host decodes it.
            try container.encode(data.base64EncodedString(), forKey: .data)
        }
    }
}

/// `SessionInfo`: the fields the phone reads. Unknown fields are ignored;
/// the ones a protocol 4 host left out decode with defaults.
struct HostWireSession: Decodable, Equatable, Sendable {
    struct Foreground: Decodable, Equatable, Sendable {
        let pid: UInt32
        let name: String
    }

    let id: String
    let name: String
    let cwd: String
    let command: [String]
    let cols: Int
    let rows: Int
    /// `running` or `exited`.
    let state: String
    let pid: UInt32?
    let exitCode: UInt32?
    let exitSignal: Int32?
    let title: String?
    /// As the program reported it: a percent-encoded `file://host/path`
    /// (OSC 7) or a plain path.
    let pwd: String?
    let foreground: Foreground?
    let clients: Int
    let owner: String?
    let tags: [String: String]
    /// Milliseconds since the Unix epoch; 0 when the host did not say.
    let createdAt: UInt64
    let alternateScreen: Bool?

    var isRunning: Bool { state == "running" }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, command, cols, rows, state, pid, title, pwd, foreground, clients, owner, tags
        case exitCode = "exit_code"
        case exitSignal = "exit_signal"
        case createdAt = "created_at"
        case alternateScreen = "alternate_screen"
    }

    init(
        id: String, name: String, cwd: String, command: [String] = [], cols: Int = 120, rows: Int = 32,
        state: String = "running", pid: UInt32? = nil, exitCode: UInt32? = nil, exitSignal: Int32? = nil,
        title: String? = nil, pwd: String? = nil, foreground: Foreground? = nil, clients: Int = 0,
        owner: String? = nil, tags: [String: String] = [:], createdAt: UInt64 = 0, alternateScreen: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
        self.state = state
        self.pid = pid
        self.exitCode = exitCode
        self.exitSignal = exitSignal
        self.title = title
        self.pwd = pwd
        self.foreground = foreground
        self.clients = clients
        self.owner = owner
        self.tags = tags
        self.createdAt = createdAt
        self.alternateScreen = alternateScreen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            cwd: try container.decode(String.self, forKey: .cwd),
            command: try container.decode([String].self, forKey: .command),
            cols: try container.decode(Int.self, forKey: .cols),
            rows: try container.decode(Int.self, forKey: .rows),
            state: try container.decode(String.self, forKey: .state),
            pid: try container.decodeIfPresent(UInt32.self, forKey: .pid),
            exitCode: try container.decodeIfPresent(UInt32.self, forKey: .exitCode),
            exitSignal: try container.decodeIfPresent(Int32.self, forKey: .exitSignal),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            pwd: try container.decodeIfPresent(String.self, forKey: .pwd),
            foreground: try container.decodeIfPresent(Foreground.self, forKey: .foreground),
            clients: try container.decodeIfPresent(Int.self, forKey: .clients) ?? 0,
            owner: try container.decodeIfPresent(String.self, forKey: .owner),
            tags: try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:],
            createdAt: try container.decodeIfPresent(UInt64.self, forKey: .createdAt) ?? 0,
            alternateScreen: try container.decodeIfPresent(Bool.self, forKey: .alternateScreen)
        )
    }
}

struct HostWireSessionList: Decodable, Equatable, Sendable {
    let hostID: String
    let sessions: [HostWireSession]

    private enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case sessions
    }
}

/// `ScreenText`: the screen as plain text, rows joined with `\n`.
struct HostWireScreenText: Decodable, Equatable, Sendable {
    let id: String
    let text: String
    let cursorRow: Int
    let cursorCol: Int
    let alternateScreen: Bool

    private enum CodingKeys: String, CodingKey {
        case id, text
        case cursorRow = "cursor_row"
        case cursorCol = "cursor_col"
        case alternateScreen = "alternate_screen"
    }
}

/// What the host pushes to a subscribed connection (`SessionEvent`).
enum HostWireEvent: Equatable, Sendable {
    case added(HostWireSession)
    case changed(HostWireSession)
    case removed(id: String)
    case bell(id: String)
    case notification(id: String, title: String, body: String)
    case progress(id: String)
    /// `exitCode` is 128 + the signal number when a signal ended it.
    case exited(id: String, exitCode: UInt32, signal: Int32?)
    /// The subscriber fell behind: list again.
    case resync
    /// A kind this version does not know; skipped.
    case unknown(kind: String)
}

extension HostWireEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, session, id, title, body, signal
        case exitCode = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "added": self = .added(try container.decode(HostWireSession.self, forKey: .session))
        case "changed": self = .changed(try container.decode(HostWireSession.self, forKey: .session))
        case "removed": self = .removed(id: try container.decode(String.self, forKey: .id))
        case "bell": self = .bell(id: try container.decode(String.self, forKey: .id))
        case "notification":
            self = .notification(
                id: try container.decode(String.self, forKey: .id),
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                body: try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            )
        case "progress": self = .progress(id: try container.decode(String.self, forKey: .id))
        case "exited":
            self = .exited(
                id: try container.decode(String.self, forKey: .id),
                exitCode: try container.decode(UInt32.self, forKey: .exitCode),
                signal: try container.decodeIfPresent(Int32.self, forKey: .signal)
            )
        case "resync": self = .resync
        default: self = .unknown(kind: kind)
        }
    }
}

/// The replies and events a control connection receives.
enum HostWireReply: Equatable, Sendable {
    case welcome(version: UInt32, hostID: String)
    case sessions(HostWireSessionList)
    case pong
    case ok
    case error(code: String, message: String)
    case event(HostWireEvent)
    case screenText(HostWireScreenText)
    /// Attachment traffic (binary frames) or a type this version does not
    /// know.
    case other(type: String)
}

/// A reply or event frame: the message and, on a direct reply, the `req`
/// it answers.
struct HostWireResponse: Equatable, Sendable {
    var req: UInt64?
    var reply: HostWireReply

    /// A frame body as a control connection reads it: JSON decodes, a
    /// binary frame becomes `.other` without a `req`.
    static func decode(frameBody body: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> HostWireResponse {
        guard body.first == HostWire.jsonMarker else {
            return HostWireResponse(req: nil, reply: .other(type: "binary \(body.first ?? 0)"))
        }
        return try decoder.decode(HostWireResponse.self, from: body)
    }

    /// The `req` of a frame whose message could not be decoded, so the
    /// request it answers fails at once instead of timing out.
    static func requestID(inUndecodable body: Data) -> UInt64? {
        struct Envelope: Decodable { let req: UInt64? }
        guard body.first == HostWire.jsonMarker else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.req
    }
}

extension HostWireResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, req, version, code, message, event
        case hostID = "host_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        req = try container.decodeIfPresent(UInt64.self, forKey: .req)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            reply = .welcome(
                version: try container.decode(UInt32.self, forKey: .version),
                hostID: try container.decode(String.self, forKey: .hostID)
            )
        case "sessions": reply = .sessions(try HostWireSessionList(from: decoder))
        case "pong": reply = .pong
        case "ok": reply = .ok
        case "error":
            reply = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "event": reply = .event(try container.decode(HostWireEvent.self, forKey: .event))
        case "screen_text": reply = .screenText(try HostWireScreenText(from: decoder))
        default: reply = .other(type: type)
        }
    }
}
