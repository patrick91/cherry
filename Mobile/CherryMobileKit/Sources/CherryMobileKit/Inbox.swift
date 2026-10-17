import Foundation

/// Where a session goes in the inbox.
public enum InboxSection: String, CaseIterable, Hashable, Sendable {
    /// Waits on you: an approval, a question, a result, an error.
    case needsYou
    case working
    /// Everything else: idle agents, commands, terminals.
    case other

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .other: "Other sessions"
        }
    }
}

/// A session of one of the phone's Macs. Host session ids are unique per
/// Mac only, so lists key sessions by both.
public struct SessionKey: Hashable, Sendable {
    public var macID: UUID
    public var sessionID: String

    public init(macID: UUID, sessionID: String) {
        self.macID = macID
        self.sessionID = sessionID
    }
}

public extension MobileSession {
    var key: SessionKey {
        SessionKey(macID: macID, sessionID: id)
    }

    var inboxSection: InboxSection {
        if attention.needsYou { return .needsYou }
        if attention == .working { return .working }
        return .other
    }

    /// The agent's name, or nil for a command or terminal.
    var agentName: String? {
        if case .agent(let name) = kind { return name }
        return nil
    }
}

public enum Inbox {
    /// `sessions` from every Mac in the inbox's sections and order, empty
    /// sections left out: what waits longest on you first after approvals
    /// and questions, which block a turn; the latest work first; then agents,
    /// commands and terminals by name.
    public static func sections(of sessions: [MobileSession]) -> [(section: InboxSection, sessions: [MobileSession])] {
        let grouped = Dictionary(grouping: sessions, by: \.inboxSection)
        return InboxSection.allCases.compactMap { section in
            guard let members = grouped[section], !members.isEmpty else { return nil }
            return (section, members.sorted(by: order(in: section)))
        }
    }

    private static func order(in section: InboxSection) -> (MobileSession, MobileSession) -> Bool {
        switch section {
        case .needsYou:
            { lhs, rhs in
                let (left, right) = (urgency(lhs.attention), urgency(rhs.attention))
                if left != right { return left < right }
                return (lhs.changedAt ?? .distantFuture) < (rhs.changedAt ?? .distantFuture)
            }
        case .working:
            { lhs, rhs in (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast) }
        case .other:
            { lhs, rhs in
                let (left, right) = (kindOrder(lhs.kind), kindOrder(rhs.kind))
                if left != right { return left < right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private static func urgency(_ attention: AgentAttention) -> Int {
        switch attention {
        case .approval: 0
        case .question: 1
        case .error: 2
        case .resultReady: 3
        case .working, .idle, .unknown: 4
        }
    }

    private static func kindOrder(_ kind: SessionKind) -> Int {
        switch kind {
        case .agent: 0
        case .command: 1
        case .terminal: 2
        }
    }
}
