import Foundation

/// Protocol v4 between Cherry and a session host (Host/crates/cherry-protocol),
/// as `cherry control` relays it on its standard input and output.
///
/// A frame is a 4-byte big-endian length followed by that many bytes of JSON.
/// Requests are tagged by `op`, replies and events by `type`. Any request may
/// carry `"req": <u64>`, which the host echoes on its direct reply, so several
/// requests can be in flight on one connection. Events carry none. Terminal
/// bytes travel as standard padded base64. Unknown fields are ignored.
enum HostProtocol {
    static let version: UInt32 = 4
    static let maxFrameBytes = 16 * 1_024 * 1_024
    /// The most bytes one `SendInput` carries.
    static let maxInputBytes = 64 * 1_024
    static let maxOwnerBytes = 256
    static let maxTags = 64
    static let maxTagKeyBytes = 128
    static let maxTagBytes = 16 * 1_024
    static let defaultCols = 120
    static let defaultRows = 32
    /// A connection that is neither attached nor subscribed must send a frame
    /// at least this often.
    static let idleTimeout: Duration = .seconds(10)
    /// Subscribed connections send `Ping` at least this often.
    static let heartbeatInterval: Duration = .seconds(15)
    /// The host drops a subscribed connection that sent nothing for this long.
    static let heartbeatTimeout: Duration = .seconds(45)

    enum ErrorCode {
        static let versionMismatch = "version_mismatch"
        static let requestFailed = "request_failed"
        static let unsupportedOperation = "unsupported_operation"
        static let unknownSession = "unknown_session"
        static let notRunning = "not_running"
    }

    static func isValidSize(cols: Int, rows: Int) -> Bool {
        (2...500).contains(cols) && (1...200).contains(rows)
    }

    /// Why tags exceed the host's limits (`check_tags`), or nil.
    static func tagProblem(_ tags: [String: String]) -> String? {
        if tags.count > maxTags { return "A session has at most \(maxTags) tags." }
        if tags.keys.contains(where: { $0.utf8.isEmpty || $0.utf8.count > maxTagKeyBytes }) {
            return "Tag keys must be 1 to \(maxTagKeyBytes) bytes long."
        }
        if tags.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) > maxTagBytes {
            return "Tags exceed \(maxTagBytes) bytes."
        }
        return nil
    }
}

enum HostFrameError: Error, Equatable, LocalizedError {
    /// A length prefix of zero or over the frame limit: the stream is not
    /// protocol frames (or is corrupt), so nothing after it can be trusted.
    case invalidLength(Int)
    /// A frame to send is larger than the host accepts.
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLength(let length):
            "The session helper sent a frame of invalid length \(length)."
        case .tooLarge(let length):
            "The request is \(length) bytes, more than the session host accepts."
        }
    }
}

enum HostFrame {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Length prefix + body.
    static func frame(body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= HostProtocol.maxFrameBytes else {
            throw HostFrameError.tooLarge(body.count)
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try frame(body: encoder.encode(value))
    }
}

/// Splits a byte stream into frame bodies. Bytes may arrive in any pieces.
struct HostFrameDecoder {
    private var buffer: [UInt8] = []
    private var start = 0

    var bufferedByteCount: Int { buffer.count - start }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    mutating func append(_ data: Data) {
        data.withUnsafeBytes { append($0) }
    }

    /// The next complete frame body, or nil until more bytes arrive.
    mutating func nextFrame() throws -> Data? {
        guard bufferedByteCount >= 4 else { return nil }
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length > 0, length <= HostProtocol.maxFrameBytes else {
            throw HostFrameError.invalidLength(length)
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

    private mutating func compactIfNeeded() {
        guard start > 0, start >= 64 * 1_024, start * 2 >= buffer.count else { return }
        buffer.removeFirst(start)
        start = 0
    }
}

/// `ClientMessage::Create`.
struct HostCreateRequest: Equatable, Sendable {
    /// Chosen by the client. The host creates at most one session per ID
    /// (for the same launch), so a retry returns the session the first made.
    var requestID: UUID
    var name: String
    /// Absolute, `~` or `~/…` on the host.
    var cwd: String
    /// Empty for the host user's login shell.
    var command: [String] = []
    var environment: [String: String] = [:]
    var cols: Int = HostProtocol.defaultCols
    var rows: Int = HostProtocol.defaultRows
    /// The app variant creating the session.
    var owner: String?
    var tags: [String: String] = [:]
}

/// The requests the control plane sends. Attachment requests (attach, input,
/// resize, detach) belong to `cherry attach`, never to a control connection.
enum HostClientMessage: Equatable, Sendable {
    case hello(version: UInt32)
    case replace
    case list
    case create(HostCreateRequest)
    case ping
    case kill(id: String)
    case remove(id: String)
    case subscribe
    case sendInput(id: String, data: Data)
    /// `maxLines`: only the last this many lines of the text (history
    /// included when `scrollback`); nil for all of it.
    case screen(id: String, scrollback: Bool, maxLines: Int? = nil)
    case update(id: String, name: String?, tags: [String: String]?)

    var op: String {
        switch self {
        case .hello: "hello"
        case .replace: "replace"
        case .list: "list"
        case .create: "create"
        case .ping: "ping"
        case .kill: "kill"
        case .remove: "remove"
        case .subscribe: "subscribe"
        case .sendInput: "send_input"
        case .screen: "screen"
        case .update: "update"
        }
    }
}

/// A request frame: the message, plus the ID its reply echoes.
struct HostRequest: Encodable, Equatable, Sendable {
    var req: UInt64?
    var message: HostClientMessage

    private enum CodingKeys: String, CodingKey {
        case op, req, version, id, name, cwd, command, env, cols, rows, owner, tags, data, scrollback
        case requestID = "request_id"
        case maxLines = "max_lines"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message.op, forKey: .op)
        try container.encodeIfPresent(req, forKey: .req)
        switch message {
        case .hello(let version):
            try container.encode(version, forKey: .version)
        case .replace, .list, .ping, .subscribe:
            break
        case .create(let create):
            try container.encode(create.requestID.uuidString.lowercased(), forKey: .requestID)
            try container.encode(create.name, forKey: .name)
            try container.encode(create.cwd, forKey: .cwd)
            try container.encode(create.command, forKey: .command)
            try container.encode(create.environment, forKey: .env)
            try container.encode(create.cols, forKey: .cols)
            try container.encode(create.rows, forKey: .rows)
            try container.encodeIfPresent(create.owner, forKey: .owner)
            try container.encode(create.tags, forKey: .tags)
        case .kill(let id), .remove(let id):
            try container.encode(id, forKey: .id)
        case .sendInput(let id, let data):
            try container.encode(id, forKey: .id)
            try container.encode(data.base64EncodedString(), forKey: .data)
        case .screen(let id, let scrollback, let maxLines):
            try container.encode(id, forKey: .id)
            try container.encode(scrollback, forKey: .scrollback)
            // Left out for the whole text, so a host without the field
            // answers as before.
            try container.encodeIfPresent(maxLines.map { UInt32(clamping: max($0, 1)) }, forKey: .maxLines)
        case .update(let id, let name, let tags):
            // A field left out is kept; tags replace the whole map.
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(tags, forKey: .tags)
        }
    }
}

/// `ProgressState` of an OSC 9;4 report.
enum HostProgressState: String, Codable, Sendable {
    case remove
    case set
    case error
    case indeterminate
    case pause
}

/// What the host pushes to a subscribed connection (`SessionEvent`).
enum HostSessionEvent: Equatable, Sendable {
    case added(HostedSessionInfo)
    /// Any field of the session changed: state, size, clients, title, pwd,
    /// foreground process, name or tags.
    case changed(HostedSessionInfo)
    case removed(id: String)
    case bell(id: String)
    /// `title` is empty when the program gave none.
    case notification(id: String, title: String, body: String)
    /// `value` is a percentage, nil when the program gave none.
    case progress(id: String, state: HostProgressState, value: Int?)
    /// `exitCode` is 128 + the signal number when a signal ended the program.
    case exited(id: String, exitCode: UInt32, signal: Int32?)
    /// The session list was refreshed after events may have been missed.
    case resync

    /// The session the event is about; nil for `resync`.
    var sessionID: String? {
        switch self {
        case .added(let session), .changed(let session): session.id
        case .removed(let id), .bell(let id), .notification(let id, _, _), .progress(let id, _, _),
             .exited(let id, _, _):
            id
        case .resync: nil
        }
    }
}

extension HostSessionEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, session, id, title, body, state, value, signal
        case exitCode = "exit_code"
    }

    /// Thrown for an event kind this version does not know; such events are
    /// skipped, never fatal.
    struct UnknownKind: Error, Equatable {
        let kind: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "added":
            self = .added(try container.decode(HostedSessionInfo.self, forKey: .session))
        case "changed":
            self = .changed(try container.decode(HostedSessionInfo.self, forKey: .session))
        case "removed":
            self = .removed(id: try container.decode(String.self, forKey: .id))
        case "bell":
            self = .bell(id: try container.decode(String.self, forKey: .id))
        case "notification":
            self = .notification(
                id: try container.decode(String.self, forKey: .id),
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                body: try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            )
        case "progress":
            guard let state = HostProgressState(rawValue: try container.decode(String.self, forKey: .state)) else {
                throw UnknownKind(kind: kind)
            }
            self = .progress(
                id: try container.decode(String.self, forKey: .id),
                state: state,
                value: try container.decodeIfPresent(Int.self, forKey: .value)
            )
        case "exited":
            self = .exited(
                id: try container.decode(String.self, forKey: .id),
                exitCode: try container.decode(UInt32.self, forKey: .exitCode),
                signal: try container.decodeIfPresent(Int32.self, forKey: .signal)
            )
        case "resync":
            self = .resync
        default:
            throw UnknownKind(kind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .added(let session):
            try container.encode("added", forKey: .kind)
            try container.encode(session, forKey: .session)
        case .changed(let session):
            try container.encode("changed", forKey: .kind)
            try container.encode(session, forKey: .session)
        case .removed(let id):
            try container.encode("removed", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .bell(let id):
            try container.encode("bell", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .notification(let id, let title, let body):
            try container.encode("notification", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
        case .progress(let id, let state, let value):
            try container.encode("progress", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(state, forKey: .state)
            try container.encode(value, forKey: .value)
        case .exited(let id, let exitCode, let signal):
            try container.encode("exited", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(exitCode, forKey: .exitCode)
            try container.encode(signal, forKey: .signal)
        case .resync:
            try container.encode("resync", forKey: .kind)
        }
    }
}

/// `ScreenText`: the screen as plain text, rows joined with `\n`. The cursor
/// is zero-based on the active screen, whatever `text` holds above it; for
/// a `Screen` with `max_lines`, `cursorRow` counts from the first line
/// returned.
struct HostScreenText: Codable, Equatable, Sendable {
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

/// The replies and events a control connection receives.
enum HostServerMessage: Equatable, Sendable {
    case welcome(version: UInt32, hostID: String)
    case sessions(HostedSessionList)
    case created(HostedSessionInfo)
    case pong
    case ok
    case error(code: String, message: String)
    case event(HostSessionEvent)
    /// An event of a kind this version does not know.
    case unknownEvent(kind: String)
    case screenText(HostScreenText)
    /// A message a control connection does not expect (attachment traffic)
    /// or does not know.
    case other(type: String)
}

/// A reply or event frame: the message and, on a direct reply, the `req` of
/// the request it answers.
struct HostResponse: Equatable, Sendable {
    var req: UInt64?
    var message: HostServerMessage
}

extension HostResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, req, version, session, sessions, code, message, event
        case hostID = "host_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        req = try container.decodeIfPresent(UInt64.self, forKey: .req)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            message = .welcome(
                version: try container.decode(UInt32.self, forKey: .version),
                hostID: try container.decode(String.self, forKey: .hostID)
            )
        case "sessions":
            message = .sessions(try HostedSessionList(from: decoder))
        case "created":
            message = .created(try container.decode(HostedSessionInfo.self, forKey: .session))
        case "pong":
            message = .pong
        case "ok":
            message = .ok
        case "error":
            message = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "event":
            do {
                message = .event(try container.decode(HostSessionEvent.self, forKey: .event))
            } catch let unknown as HostSessionEvent.UnknownKind {
                message = .unknownEvent(kind: unknown.kind)
            }
        case "screen_text":
            message = .screenText(try HostScreenText(from: decoder))
        default:
            message = .other(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(req, forKey: .req)
        switch message {
        case .welcome(let version, let hostID):
            try container.encode("welcome", forKey: .type)
            try container.encode(version, forKey: .version)
            try container.encode(hostID, forKey: .hostID)
        case .sessions(let list):
            try container.encode("sessions", forKey: .type)
            try list.encode(to: encoder)
        case .created(let session):
            try container.encode("created", forKey: .type)
            try container.encode(session, forKey: .session)
        case .pong:
            try container.encode("pong", forKey: .type)
        case .ok:
            try container.encode("ok", forKey: .type)
        case .error(let code, let message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .event(let event):
            try container.encode("event", forKey: .type)
            try container.encode(event, forKey: .event)
        case .unknownEvent(let kind):
            try container.encode("event", forKey: .type)
            try container.encode(["kind": kind], forKey: .event)
        case .screenText(let screen):
            try container.encode("screen_text", forKey: .type)
            try screen.encode(to: encoder)
        case .other(let type):
            try container.encode(type, forKey: .type)
        }
    }

    /// Just the `req` of a frame whose message could not be decoded, so the
    /// request it answers still fails instead of waiting for its timeout.
    static func requestID(inUndecodable body: Data) -> UInt64? {
        struct Envelope: Decodable { let req: UInt64? }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.req
    }
}
