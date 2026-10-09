import Foundation

/// A program status record (OSC 7501, https://www.superlogical.com/rex/docs/build/program-status):
/// the latest report a program sent about one id. A persistent tab's host
/// keeps them (`HostedSessionInfo.programStatus`); output Cherry parses
/// itself (the host-managed path, tests) is kept by `ProgramStatusRecords`,
/// by the same rules. A native tab, whose Ghostty surface owns its output,
/// has none: its program sees no answer to the support query. The text is the program's, decoded and without control or
/// invisible formatting characters, but untrusted: never markup, never
/// instructions.
struct ProgramStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// At rest, waiting for the user's next instruction.
        case idle
        case working
        /// Finished; the result waits for the user.
        case done
        /// Can't go on until the user does something (`kind`).
        case blocked
        /// Failed and stopped.
        case error
        /// A state a newer host knows.
        case unknown

        init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    enum Kind: String, Codable, Sendable {
        /// Approval to do something.
        case permission
        /// An answer the user has to give.
        case question
        /// A login, password, token or other credential.
        case auth
        /// A kind a newer host knows.
        case unknown

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// Empty for the root record, the program itself; `/` separates a
    /// child from its parent (`build/test`).
    var id: String = ""
    var state: State
    /// What a blocked program needs, when it said.
    var kind: Kind?
    /// 0–100, for `working` and `blocked` only.
    var progress: Int?
    /// A stable name for the program (`claude-code`, `pi`, `cargo`).
    var app: String = ""
    var title: String = ""
    /// One line saying what the record is doing, waiting for or finished.
    var message: String = ""

    enum CodingKeys: String, CodingKey {
        case id, state, kind, progress, app, title, message
    }

    init(
        id: String = "",
        state: State,
        kind: Kind? = nil,
        progress: Int? = nil,
        app: String = "",
        title: String = "",
        message: String = ""
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            state: try container.decode(State.self, forKey: .state),
            kind: try container.decodeIfPresent(Kind.self, forKey: .kind),
            progress: try container.decodeIfPresent(Int.self, forKey: .progress),
            app: try container.decodeIfPresent(String.self, forKey: .app) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            message: try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        )
    }

    /// As the host writes it: empty and absent values left out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !id.isEmpty { try container.encode(id, forKey: .id) }
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(progress, forKey: .progress)
        if !app.isEmpty { try container.encode(app, forKey: .app) }
        if !title.isEmpty { try container.encode(title, forKey: .title) }
        if !message.isEmpty { try container.encode(message, forKey: .message) }
    }

    var isRoot: Bool { id.isEmpty }
}

extension Array where Element == ProgramStatus {
    /// The record about the program itself (an empty id), when it sent one.
    var root: ProgramStatus? {
        first(where: \.isRoot)
    }
}

/// One report as Cherry's own parser reads it: a record to put, or a
/// clear (`state` nil) of an id and every id beneath it (every record when
/// the id is empty).
struct ProgramStatusReport: Equatable, Sendable {
    var state: ProgramStatus.State?
    var kind: ProgramStatus.Kind?
    var progress: Int?
    var id: String = ""
    var app: String = ""
    var title: String = ""
    var message: String = ""
}

/// Program status records of output Cherry parses itself, kept by the rules the host's
/// holder follows (`Host/crates/cherry-vt/src/program_status.rs`): a report
/// replaces its record whole; a clear removes the record and its children;
/// at most `maxRecords`, the one updated longest ago making room; the
/// program's exit or a new shell prompt removes `working`, `blocked` and
/// `idle` records, while `done` and `error` stay for the user to see.
struct ProgramStatusRecords: Equatable, Sendable {
    static let maxRecords = 64

    /// The one updated longest ago first.
    private(set) var records: [ProgramStatus] = []

    /// Whether the records changed.
    @discardableResult
    mutating func apply(_ report: ProgramStatusReport) -> Bool {
        guard let state = report.state else {
            let before = records.count
            if report.id.isEmpty {
                records.removeAll()
            } else {
                records.removeAll { Self.isWithin($0.id, report.id) }
            }
            return records.count != before
        }
        let record = ProgramStatus(
            id: report.id,
            state: state,
            kind: state == .blocked ? report.kind : nil,
            progress: (state == .working || state == .blocked)
                ? report.progress.flatMap { (0...100).contains($0) ? $0 : nil }
                : nil,
            app: report.app,
            title: Self.visible(report.title),
            message: Self.visible(report.message)
        )
        let previous = records.firstIndex { $0.id == record.id }.map { records.remove(at: $0) }
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst()
        }
        return previous != record
    }

    /// The program ended (it exited, or a shell started a new prompt).
    /// Whether any record went.
    @discardableResult
    mutating func endProgram() -> Bool {
        let before = records.count
        records.removeAll { $0.state != .done && $0.state != .error }
        return records.count != before
    }

    mutating func removeAll() {
        records.removeAll()
    }

    static func isWithin(_ id: String, _ ancestor: String) -> Bool {
        guard id.hasPrefix(ancestor) else { return false }
        let rest = id.dropFirst(ancestor.count)
        return rest.isEmpty || rest.hasPrefix("/")
    }

    /// Text without control characters and the invisible formatting
    /// characters a program could use to make it read as something else
    /// (direction overrides and isolates, zero width spaces and marks, word
    /// joiners, the byte order mark); the zero width joiner stays, as emoji
    /// need it.
    static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar.properties.generalCategory == .control { return false }
            switch scalar.value {
            case 0x00AD, 0x061C, 0x180E, 0x200B, 0x200C, 0x200E, 0x200F,
                 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069,
                 0xFEFF, 0xFFF9...0xFFFB:
                return false
            default:
                return true
            }
        }))
    }
}

extension ProgramStatusReport {
    /// The body of an OSC 7501 report (what follows `7501;`) as Cherry's
    /// own metadata parser reads it, for output Cherry processes itself
    /// (the host-managed path and injected test output; a native surface
    /// and the host's terminal parse reports with libghostty-vt). Nil for
    /// the support query (`?`) and for a report that breaks the
    /// specification's rules: no valid `state`, a key, value or id over
    /// its limit, text that is not base64 of UTF-8 without control
    /// characters.
    init?(osc body: String) {
        guard body != "?", body.utf8.count <= 4_096 else { return nil }
        var fields: [String: String] = [:]
        for pair in body.split(separator: ":", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<equals])
            guard !key.isEmpty, key.utf8.count <= 16 else { continue }
            fields[key] = String(pair[pair.index(after: equals)...])
        }
        let state: ProgramStatus.State?
        switch fields["state"] {
        case "idle": state = .idle
        case "working": state = .working
        case "done": state = .done
        case "blocked": state = .blocked
        case "error": state = .error
        case "clear": state = nil
        default: return nil
        }
        let id = fields["id"] ?? ""
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard id.utf8.count <= 128,
              id.isEmpty || (segments.count <= 8 && segments.allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 })
        else { return nil }
        let app = fields["app"] ?? ""
        guard app.utf8.count <= 32 else { return nil }
        func text(_ key: String, encodedLimit: Int, decodedLimit: Int) -> String?? {
            guard let encoded = fields[key], !encoded.isEmpty else { return .some(nil) }
            guard encoded.utf8.count <= encodedLimit,
                  let data = Data(base64Encoded: encoded),
                  data.count <= decodedLimit,
                  let decoded = String(data: data, encoding: .utf8),
                  !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { return nil }
            return .some(decoded)
        }
        guard let title = text("title", encodedLimit: 256, decodedLimit: 192),
              let message = text("msg", encodedLimit: 2_732, decodedLimit: 2_048)
        else { return nil }
        let kind: ProgramStatus.Kind? = state == .blocked
            ? fields["kind"].flatMap(ProgramStatus.Kind.init(rawValue:))
            : nil
        let progress = (state == .working || state == .blocked)
            ? fields["progress"].flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil }
            : nil
        self.init(
            state: state,
            kind: kind,
            progress: progress,
            id: id,
            app: app,
            title: title ?? "",
            message: message ?? ""
        )
    }
}
