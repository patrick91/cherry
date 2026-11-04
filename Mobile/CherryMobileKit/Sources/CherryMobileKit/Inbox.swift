import Foundation

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

    /// The agent's name, or nil for a command or terminal.
    var agentName: String? {
        if case .agent(let name) = kind { return name }
        return nil
    }

    /// The agent's name as its maker writes it ("Claude", "Codex", "Pi").
    var agentDisplayName: String? {
        agentName.map { name in
            switch name.lowercased() {
            case "claude": "Claude"
            case "codex": "Codex"
            case "pi": "Pi"
            case "amp": "Amp"
            case "opencode": "OpenCode"
            default: name.prefix(1).uppercased() + name.dropFirst()
            }
        }
    }

    /// An agent's task, nil while its title is only its tool's ("claude",
    /// "Claude Code").
    var task: String? {
        guard let agent = agentName?.lowercased() else { return nil }
        let title = self.title.lowercased()
        return title == agent || title == agent + " code" ? nil : self.title
    }

    /// Its project's folder on its Mac: the project the Mac's Cherry opened
    /// it in, else where it is; `~` for the home folder.
    var projectRoot: String {
        let root = DisplayPath.abbreviatingHome(project ?? directory ?? "~").trimmingSuffix("/")
        return root.isEmpty ? "/" : root
    }
}

/// Which of the inbox's sessions it shows.
public enum InboxFilter: String, CaseIterable, Hashable, Sendable {
    case all
    /// Agents that wait on you: an approval, a question, a result, an error.
    case needsYou
    case working

    func includes(_ session: MobileSession) -> Bool {
        switch self {
        case .all: true
        case .needsYou: session.agentName != nil && session.attention.needsYou
        case .working: session.agentName != nil && session.attention == .working
        }
    }
}

/// A project of one Mac, with the sessions the inbox shows of it.
public struct InboxProject: Identifiable, Hashable, Sendable {
    public var macID: UUID
    /// Its folder on the Mac, `~` for the home folder.
    public var root: String
    /// Its agents, what waits on you first, then by task.
    public var agents: [MobileSession]
    /// Its commands, then its terminals, by name.
    public var others: [MobileSession]

    public var id: String {
        "\(macID.uuidString):\(root)"
    }

    /// Its folder's name; the home folder's is Home, as on the Mac.
    public var name: String {
        root == "~" ? "Home" : root.split(separator: "/").last.map(String.init) ?? root
    }

    /// The folder its folder is in (`~/github/patrick91`).
    public var parent: String {
        guard let slash = root.lastIndex(of: "/") else { return root }
        return slash == root.startIndex ? "/" : String(root[..<slash])
    }

    /// No agent of it waits on you or works: the inbox folds it.
    public var isQuiet: Bool {
        urgency == Inbox.quiet
    }

    var urgency: Int {
        agents.map { Inbox.urgency($0) }.min() ?? Inbox.quiet
    }
}

public enum Inbox {
    /// `sessions` from every Mac by project, the sessions `filter` keeps
    /// (the others only with `all`): first the projects whose agents wait
    /// on you, approvals and questions (which block a turn) before errors
    /// and results, then those an agent works in, then the quiet ones, each
    /// by name, so a project keeps its place while its agents work.
    public static func projects(of sessions: [MobileSession], filter: InboxFilter = .all) -> [InboxProject] {
        let grouped = Dictionary(grouping: sessions.filter(filter.includes)) { session in
            "\(session.macID.uuidString):\(session.projectRoot)"
        }
        return grouped.values.map { members in
            InboxProject(
                macID: members[0].macID,
                root: members[0].projectRoot,
                agents: members.filter { $0.agentName != nil }.sorted(by: agentOrder),
                others: members.filter { $0.agentName == nil }.sorted(by: otherOrder)
            )
        }
        .sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
            let names = lhs.name.localizedStandardCompare(rhs.name)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// How many of `sessions` `filter` keeps.
    public static func count(_ filter: InboxFilter, in sessions: [MobileSession]) -> Int {
        sessions.filter(filter.includes).count
    }

    static let quiet = 5

    static func urgency(_ session: MobileSession) -> Int {
        guard session.isRunning else { return quiet }
        return switch session.attention {
        case .approval: 0
        case .question: 1
        case .error: 2
        case .resultReady: 3
        case .working: 4
        case .idle, .unknown: quiet
        }
    }

    private static func agentOrder(_ lhs: MobileSession, _ rhs: MobileSession) -> Bool {
        let (left, right) = (urgency(lhs), urgency(rhs))
        if left != right { return left < right }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func otherOrder(_ lhs: MobileSession, _ rhs: MobileSession) -> Bool {
        let (left, right) = (lhs.kind == .command ? 0 : 1, rhs.kind == .command ? 0 : 1)
        if left != right { return left < right }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
