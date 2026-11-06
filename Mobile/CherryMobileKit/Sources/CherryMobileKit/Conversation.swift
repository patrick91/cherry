import Foundation

/// A read of an agent's conversation, as the Mac's `cherry host transcript`
/// prints it (Host/README.md): Claude Code, Codex, Pi or Amp, from the
/// agent's own session.
public struct AgentTranscript: Equatable, Sendable, Decodable {
    /// `claude`, `codex`, `pi` or `amp`.
    public var agent: String
    /// The agent's own id for the session, which resumes it.
    public var sessionID: String?
    public var title: String?
    /// Where the next read starts (`after`).
    public var cursor: String
    /// The entries replace what an earlier read returned; otherwise they
    /// come after it.
    public var reset: Bool
    /// Older entries were left out.
    public var moreBefore: Bool
    public var entries: [TranscriptEntry]

    public init(
        agent: String,
        sessionID: String? = nil,
        title: String? = nil,
        cursor: String,
        reset: Bool,
        moreBefore: Bool = false,
        entries: [TranscriptEntry]
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.cursor = cursor
        self.reset = reset
        self.moreBefore = moreBefore
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case agent, title, cursor, reset, entries
        case sessionID = "session_id"
        case moreBefore = "more_before"
    }
}

/// One thing in an agent's conversation.
public struct TranscriptEntry: Identifiable, Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable {
        case user, assistant, tool, note
        /// A tool an earlier read returned finished: its result and status.
        case toolResult = "tool_result"
        /// One a newer Mac sends that this app doesn't know.
        case unknown
    }

    public enum ToolStatus: String, Sendable, Decodable {
        case running, ok, error
    }

    public var id: String
    public var kind: Kind
    public var time: String?
    /// A message's or a note's text.
    public var text: String?
    /// A tool's name, its input in one line, the start of its result.
    public var name: String?
    public var summary: String?
    public var result: String?
    public var status: ToolStatus?

    public init(
        id: String,
        kind: Kind,
        time: String? = nil,
        text: String? = nil,
        name: String? = nil,
        summary: String? = nil,
        result: String? = nil,
        status: ToolStatus? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.text = text
        self.name = name
        self.summary = summary
        self.result = result
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, time, text, name, summary, result, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .unknown
        time = try container.decodeIfPresent(String.self, forKey: .time)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        status = try? container.decodeIfPresent(ToolStatus.self, forKey: .status)
    }
}

/// What the app shows of an agent's conversation, kept up to date read by
/// read: a reset replaces it, an entry with an id it has replaces that one,
/// a tool result finishes its tool, anything else is appended. It keeps the
/// latest `capacity` entries.
public struct Conversation: Equatable, Sendable {
    public private(set) var entries: [TranscriptEntry] = []
    /// Where the next read starts; nil before the first.
    public private(set) var cursor: String?
    public private(set) var agent: String?
    public private(set) var sessionID: String?
    public private(set) var title: String?
    /// Older entries were left out.
    public private(set) var moreBefore = false
    public let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public mutating func apply(_ read: AgentTranscript) {
        agent = read.agent
        sessionID = read.sessionID ?? sessionID
        title = read.title ?? title
        cursor = read.cursor
        if read.reset {
            entries = []
            moreBefore = read.moreBefore
        }
        for entry in read.entries {
            switch entry.kind {
            case .unknown:
                continue
            case .toolResult:
                if let index = entries.lastIndex(where: { $0.id == entry.id }), entries[index].kind == .tool {
                    entries[index].result = entry.result
                    entries[index].status = entry.status
                }
            case .user, .assistant, .tool, .note:
                if let index = entries.lastIndex(where: { $0.id == entry.id }) {
                    entries[index] = entry
                } else {
                    entries.append(entry)
                }
            }
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
            moreBefore = true
        }
    }
}
