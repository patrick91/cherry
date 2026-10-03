import Foundation

/// Protocol v7 between Cherry and a session host (Host/crates/cherry-protocol),
/// as `cherry control` relays it on its standard input and output.
///
/// A frame is a 4-byte big-endian length followed by that many bytes. A body
/// whose first byte is `{` is JSON, which is all the control connection
/// sends and expects: requests are tagged by `op`, replies and events by
/// `type`. Any request may carry `"req": <u64>`, which the host echoes on its
/// direct reply, so several requests can be in flight on one connection.
/// Events carry none. Terminal bytes in JSON (`SendInput`) travel as standard
/// padded base64. Unknown fields are ignored. Any other body is a binary
/// frame of attachment traffic (`HostBinaryFrame`), which only `cherry
/// attach` sends and receives: a control connection skips one it gets.
enum HostProtocol {
    /// v6: attachment traffic (output, input, queries and snapshots) travels
    /// in binary frames instead of base64 in JSON. The app's control
    /// connection speaks the same JSON messages as in v5.
    /// v7: `ClearHistory`, `Create`'s `colors`, and `SessionInfo`'s
    /// `bracketed_paste`.
    static let version: UInt32 = 7
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

    /// The first byte of every JSON body; any other first byte is a binary
    /// frame's kind.
    static let jsonMarker = UInt8(ascii: "{")

    /// Whether a frame body is JSON rather than a binary frame.
    static func isJSON(_ body: Data) -> Bool {
        body.first == jsonMarker
    }

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

    /// A JSON frame. Every message the control connection sends is an
    /// object, so its body starts with `{` as the host requires.
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try frame(body: encoder.encode(value))
    }

    static func encode(_ binary: HostBinaryFrame) throws -> Data {
        try frame(body: binary.body)
    }
}

enum HostBinaryFrameError: Error, Equatable, LocalizedError {
    /// The body is too short for its kind, or its parts do not add up.
    case malformed(kind: UInt8, length: Int)
    case unknownKind(UInt8)

    var errorDescription: String? {
        switch self {
        case .malformed(let kind, let length):
            "The session host sent a malformed binary frame (kind \(kind), \(length) bytes)."
        case .unknownKind(let kind):
            "The session host sent a binary frame of unknown kind \(kind)."
        }
    }
}

/// A frame body that is not JSON: attachment traffic, raw bytes after a
/// one-byte kind, integers big-endian. Only `cherry attach` sends and
/// receives these; a control connection never attaches, so it skips any
/// that arrive (`HostResponse.decode(frameBody:using:)`).
enum HostBinaryFrame: Equatable, Sendable {
    /// Host to client: the output from byte position `offset` of the stream.
    case output(offset: UInt64, data: Data)
    /// Client to host: bytes for the attached session's program.
    case input(Data)
    /// Host to client: terminal queries for the client's terminal to answer.
    case query(Data)
    /// Host to client: a snapshot. `header` is the JSON object of the other
    /// `Attached` fields (session, offset, reason, …).
    case attached(header: Data, snapshot: Data)

    enum Kind {
        static let output: UInt8 = 1
        static let input: UInt8 = 2
        static let query: UInt8 = 3
        static let attached: UInt8 = 4
    }

    /// Output's kind byte and offset; Attached's kind byte and header length.
    private static let outputPrefix = 1 + 8
    private static let attachedPrefix = 1 + 4

    var kind: UInt8 {
        switch self {
        case .output: Kind.output
        case .input: Kind.input
        case .query: Kind.query
        case .attached: Kind.attached
        }
    }

    /// The `type` of the JSON message this frame replaced (v5).
    static func name(ofKind kind: UInt8) -> String {
        switch kind {
        case Kind.output: "output"
        case Kind.input: "input"
        case Kind.query: "query"
        case Kind.attached: "attached"
        default: "binary \(kind)"
        }
    }

    /// Checks a binary body's layout without copying its bytes and returns
    /// its kind. Throws `.unknownKind` for a kind this version does not
    /// know, whose layout it cannot check.
    @discardableResult
    static func validate(_ body: Data) throws -> UInt8 {
        guard let kind = body.first, kind != HostFrame.jsonMarker else {
            throw HostBinaryFrameError.malformed(kind: body.first ?? 0, length: body.count)
        }
        let malformed = HostBinaryFrameError.malformed(kind: kind, length: body.count)
        switch kind {
        case Kind.output:
            guard body.count >= outputPrefix else { throw malformed }
        case Kind.input, Kind.query:
            break
        case Kind.attached:
            guard body.count >= attachedPrefix else { throw malformed }
            let headerLength = Int(readUInt32(body, at: 1))
            // The header is a JSON object: at least `{}`.
            guard headerLength >= 2, headerLength <= body.count - attachedPrefix,
                  body[body.startIndex + attachedPrefix] == HostFrame.jsonMarker
            else { throw malformed }
        default:
            throw HostBinaryFrameError.unknownKind(kind)
        }
        return kind
    }

    /// Decodes a binary body (one `HostFrame.isJSON` rejects).
    init(body: Data) throws {
        let kind = try Self.validate(body)
        let start = body.startIndex
        switch kind {
        case Kind.output:
            self = .output(
                offset: Self.readUInt64(body, at: 1),
                data: Data(body[(start + Self.outputPrefix)...])
            )
        case Kind.input:
            self = .input(Data(body[(start + 1)...]))
        case Kind.query:
            self = .query(Data(body[(start + 1)...]))
        default:
            let headerEnd = start + Self.attachedPrefix + Int(Self.readUInt32(body, at: 1))
            self = .attached(
                header: Data(body[(start + Self.attachedPrefix)..<headerEnd]),
                snapshot: Data(body[headerEnd...])
            )
        }
    }

    /// The frame body (without its length prefix).
    var body: Data {
        var body = Data([kind])
        switch self {
        case .output(let offset, let data):
            withUnsafeBytes(of: offset.bigEndian) { body.append(contentsOf: $0) }
            body.append(data)
        case .input(let data), .query(let data):
            body.append(data)
        case .attached(let header, let snapshot):
            withUnsafeBytes(of: UInt32(clamping: header.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(header)
            body.append(snapshot)
        }
        return body
    }

    private static func readUInt32(_ body: Data, at index: Int) -> UInt32 {
        body[(body.startIndex + index)..<(body.startIndex + index + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ body: Data, at index: Int) -> UInt64 {
        body[(body.startIndex + index)..<(body.startIndex + index + 8)].reduce(0) { $0 << 8 | UInt64($1) }
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
    /// What the session's terminal reports of its colours and appearance to
    /// the program (OSC 10, 11, 12 and `CSI ? 996 n`); nil for the host's
    /// defaults (light grey on black, dark).
    var colors: HostTerminalColors?
    /// The pixels of one cell of the window the session is created for
    /// (`cell_width`, `cell_height`): the program's PTY reports them from
    /// the start, so that window's adapter attaching changes nothing. Nil
    /// leaves them out (the PTY reports no pixels until a client gives
    /// some); a host older than the fields ignores them.
    var cell: TerminalCellSize?
}

/// `TerminalColors`: the colours a session's terminal reports, as
/// `#rrggbb`.
struct HostTerminalColors: Equatable, Sendable, Encodable {
    var foreground: String
    var background: String
    var cursor: String?
    var dark: Bool

    /// Nil unless every colour is `#rrggbb` (the host would refuse the
    /// Create otherwise).
    init?(foreground: String, background: String, cursor: String? = nil, dark: Bool) {
        let normalized = [foreground, background, cursor ?? foreground].map(Self.normalized)
        guard let foreground = normalized[0], let background = normalized[1], let cursorColor = normalized[2] else {
            return nil
        }
        self.foreground = foreground
        self.background = background
        self.cursor = cursor == nil ? nil : cursorColor
        self.dark = dark
    }

    /// `#rrggbb` (lowercase) for `#rrggbb`, `rrggbb` or `#rgb`; nil otherwise.
    static func normalized(_ color: String) -> String? {
        var hex = color.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        // ASCII only, as the host reads it: `isHexDigit` also takes
        // fullwidth digits and letters.
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + hex.lowercased()
    }
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
    /// Clears the history above the session's screen (v7).
    case clearHistory(id: String)

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
        case .clearHistory: "clear_history"
        }
    }
}

/// A request frame: the message, plus the ID its reply echoes.
struct HostRequest: Encodable, Equatable, Sendable {
    var req: UInt64?
    var message: HostClientMessage

    private enum CodingKeys: String, CodingKey {
        case op, req, version, id, name, cwd, command, env, cols, rows, owner, tags, data, scrollback, colors
        case requestID = "request_id"
        case maxLines = "max_lines"
        case cellWidth = "cell_width"
        case cellHeight = "cell_height"
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
            // Left out without colours, so the host keeps its defaults.
            try container.encodeIfPresent(create.colors, forKey: .colors)
            try container.encodeIfPresent(create.cell?.width, forKey: .cellWidth)
            try container.encodeIfPresent(create.cell?.height, forKey: .cellHeight)
        case .kill(let id), .remove(let id), .clearHistory(let id):
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
    /// `end`: why, when the program did not end by itself (`ended_by`).
    case exited(id: String, exitCode: UInt32, signal: Int32?, end: HostSessionEnd? = nil)
    /// The session list was refreshed after events may have been missed.
    case resync

    /// The session the event is about; nil for `resync`.
    var sessionID: String? {
        switch self {
        case .added(let session), .changed(let session): session.id
        case .removed(let id), .bell(let id), .notification(let id, _, _), .progress(let id, _, _),
             .exited(let id, _, _, _):
            id
        case .resync: nil
        }
    }
}

extension HostSessionEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, session, id, title, body, state, value, signal
        case exitCode = "exit_code"
        case endedBy = "ended_by"
        case holderLog = "holder_log"
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
                signal: try container.decodeIfPresent(Int32.self, forKey: .signal),
                end: try container.decodeIfPresent(String.self, forKey: .endedBy).map { reason in
                    HostSessionEnd(reason: reason, holderLog: try container.decodeIfPresent(String.self, forKey: .holderLog))
                }
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
        case .exited(let id, let exitCode, let signal, let end):
            try container.encode("exited", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(exitCode, forKey: .exitCode)
            try container.encode(signal, forKey: .signal)
            try container.encodeIfPresent(end?.reason, forKey: .endedBy)
            try container.encodeIfPresent(end?.holderLog, forKey: .holderLog)
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
    /// A message a control connection does not expect (attachment traffic,
    /// binary frames included, named `HostBinaryFrame.name(ofKind:)`) or
    /// does not know.
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
    /// A binary frame answers no request.
    static func requestID(inUndecodable body: Data) -> UInt64? {
        struct Envelope: Decodable { let req: UInt64? }
        guard HostFrame.isJSON(body) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.req
    }

    /// A frame body as a control connection reads it. JSON decodes as a
    /// `HostResponse`. A binary frame is attachment traffic, which never
    /// answers a request, so it becomes `.other` without a `req`, named
    /// after its kind (a kind this version does not know too, like an
    /// unknown `type`); its bytes are checked, not copied. Throws for JSON
    /// it cannot decode and for a malformed binary frame.
    static func decode(frameBody body: Data, using decoder: JSONDecoder) throws -> HostResponse {
        if HostFrame.isJSON(body) { return try decoder.decode(HostResponse.self, from: body) }
        let kind: UInt8
        do {
            kind = try HostBinaryFrame.validate(body)
        } catch HostBinaryFrameError.unknownKind(let unknown) {
            kind = unknown
        }
        return HostResponse(req: nil, message: .other(type: HostBinaryFrame.name(ofKind: kind)))
    }
}
