import CherryControl
import Foundation

// The Omni bar (⌘P, ⌘O and the title-bar project button): one floating
// bar that finds projects on every Mac, the Macs, the tabs of every window
// and the background sessions, the current project's worktrees, and the
// commands. Everything here is pure: the live layer (`OmniBarLive.swift`)
// gathers `OmniSources` from the app's state without connecting to any
// host, `OmniProviders` turns them into rows, `OmniMatcher` and
// `OmniRanking` order them, and `OmniBarController` is the bar's state
// (scopes, query, selection, the ⌘K action list). The view is
// `OmniBarView.swift`.

// MARK: - Items

/// What a row is; its icon and what its detail says follow from it.
enum OmniKind: String, Equatable {
    case project
    case mac
    case tab
    /// A background session (`BackgroundSessionsModel`).
    case session
    case worktree
    case command
    case agent
}

/// The row's status dot.
enum OmniStatus: Equatable {
    /// An agent at work (orange).
    case working
    /// Open, or connected and idle (green).
    case idle
    /// A Mac that does not answer (grey).
    case offline
}

/// Where the bar is: the root (nil), or a scope the crumb names.
enum OmniScope: Hashable {
    case projects
    case macs
    /// A Mac drilled into: its tabs and sessions, then its projects.
    case mac(ProjectSwitcherModel.Machine, name: String)
    case tabs
    case worktrees
    case commands
    /// The launchable agents (New Agent).
    case agents
    /// The agent presets (Add Agent…).
    case agentPresets
    /// Every editor the project opens in (Open in Other Editor…).
    case editors

    var label: String {
        switch self {
        case .projects: "Projects"
        case .macs: "Macs"
        case .mac(_, let name): name
        case .tabs: "Tabs & Sessions"
        case .worktrees: "Worktrees"
        case .commands: "Commands"
        case .agents: "Agents"
        case .agentPresets: "Add Agent"
        case .editors: "Editors"
        }
    }

    var placeholder: String {
        switch self {
        case .mac(_, let name): "Search \(name)…"
        default: "Search \(label.lowercased())…"
        }
    }

    /// The scope a first character typed at the root enters.
    static func forPrefix(_ character: Character) -> OmniScope? {
        switch character {
        case ">": .commands
        case "@": .macs
        case "#": .tabs
        case "/": .worktrees
        default: nil
        }
    }
}

/// The app's menu actions the bar runs, through the menus' own code paths
/// (`OmniBarPerformer`).
enum OmniMenuCommand: String, CaseIterable {
    case newTab
    case splitRight
    case detachTab
    case closeTab
    case reopenClosedTab
    case clearScrollback
    case settings
    case addMac
    case endBackgroundSessions
    case persistentSessions
    case toggleSidebar
    // Ids of the command palette's commands, kept so their usage carries
    // over (`OmniFrecencyStore`).
    case addProject
    case newWorktree
    case manageWorktrees
    case toggleAppearance
}

/// What running a row, or one of its ⌘K actions, does.
enum OmniCommand: Equatable {
    case drill(OmniScope)
    /// Opens, or switches to, the project at this location key.
    case openProject(key: String)
    /// "Open “<query>” as a folder…".
    case openPath(String, on: ProjectSwitcherModel.Machine)
    case openProjectInEditor(key: String, editorID: String)
    case revealInFinder(path: String)
    case copyPath(String)
    /// New Worktree… in the open window of this project.
    case newWorktreeInProject(key: String)
    case removeProject(key: String)
    /// One of the picker menu's actions (`ProjectSwitcherActions.perform`).
    case switcher(TitlebarProjectMenuModel.Action)
    case openFolder(on: ProjectSwitcherModel.Machine)
    case addProject(on: ProjectSwitcherModel.Machine)
    case newTerminal(on: ProjectSwitcherModel.Machine)
    case endBackgroundSessions(on: ProjectSwitcherModel.Machine)
    case goToTab(UUID)
    case renameTab(UUID)
    case detachTab(UUID)
    case closeTab(UUID)
    case openBackgroundSession(id: String)
    case endBackgroundSession(id: String)
    case activateWorktree(root: String)
    /// New worktree “<name>”: New Worktree with the branch name filled in.
    case createWorktree(name: String)
    case renameWorktree(root: String)
    case removeWorktree(root: String)
    case menu(OmniMenuCommand)
    case launchAgent(id: String)
    case configureAgentPreset(id: String)
    case openInEditor(editorID: String)
}

/// A ⌘K action of a row.
struct OmniAction: Equatable, Identifiable {
    var title: String
    var command: OmniCommand
    var isDestructive = false

    var id: String { title }
}

/// One row of the bar.
struct OmniItem: Equatable, Identifiable {
    /// Unique among the rows, and the key of its frecency
    /// (`OmniFrecencyStore`): "project:<key>", "tab:<uuid>", "command:<id>"…
    var id: String
    var kind: OmniKind
    var title: String
    /// The one muted detail on the right.
    var detail = ""
    var status: OmniStatus?
    /// An SF Symbol.
    var symbol: String
    /// What ↵ does, named in the footer ("↵ Open").
    var primaryLabel: String
    var primary: OmniCommand
    /// ⌘K.
    var actions: [OmniAction] = []
    /// Also searched, after the title (a project's path, an agent's command
    /// line), without highlighting.
    var keywords: [String] = []
    /// The Mac it is on (projects, Macs, tabs and sessions).
    var machine: ProjectSwitcherModel.Machine?
    /// Added to its frecency in Recent: an open project, a working agent.
    var liveBoost: Double = 0
    /// Whether ↵ records it as used (not a "New worktree" row).
    var recordsUse = true

    var frecencyKey: String { id }

    /// The scope ⇥ and ↵ enter, when it has one.
    var drillScope: OmniScope? {
        if case .drill(let scope) = primary { return scope }
        return nil
    }

    var accessibilityLabel: String {
        var parts = [title]
        switch status {
        case .working?: parts.append("working")
        case .idle?: parts.append(kind == .mac ? "connected" : "open")
        case .offline?: parts.append("offline")
        case nil: break
        }
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Matching

/// A fuzzy match of a query in a title: its score and the characters it
/// matched (offsets in the title's `Character`s, for bold).
struct OmniMatch: Equatable {
    var score: Double
    var indices: [Int]
}

/// Scores a query against a title as a subsequence, case and diacritic
/// insensitively, whitespace in the query ignored: each matched character
/// counts 1, 8 more at the start of a word (after a space, `-`, `_`, `.`,
/// `/`, `:`, or a lower-to-upper case change) and 5 more right after the
/// one matched before it; a title that starts with the query gets 12 more
/// and one equal to it 20 more. The best alignment wins (dynamic
/// programming), and shorter titles win ties.
enum OmniMatcher {
    static let wordStartBonus = 8.0
    static let consecutiveBonus = 5.0
    static let prefixBonus = 12.0
    static let exactBonus = 20.0

    static func match(_ query: String, in text: String) -> OmniMatch? {
        let needle = Array(query.filter { !$0.isWhitespace }).map(fold)
        guard !needle.isEmpty else { return OmniMatch(score: 0, indices: []) }
        let characters = Array(text)
        let haystack = characters.map(fold)
        let m = needle.count
        let n = haystack.count
        guard m <= n else { return nil }

        var wordStart = [Bool](repeating: false, count: n)
        for j in 0 ..< n {
            if j == 0 {
                wordStart[j] = true
            } else {
                let previous = characters[j - 1]
                let current = characters[j]
                wordStart[j] = previous.isWhitespace || "-_./:".contains(previous)
                    || (previous.isLowercase && current.isUppercase)
                    || (!previous.isLetter && !previous.isNumber && (current.isLetter || current.isNumber))
            }
        }

        // best[i][j]: the best score with needle[i] matched at j.
        let unmatched = -Double.infinity
        var best = [[Double]](repeating: [Double](repeating: unmatched, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for i in 0 ..< m {
            // The best of row i-1 at positions before j-1, and where.
            var runningBest = unmatched
            var runningIndex = -1
            for j in i ..< n {
                if i > 0, j >= 2, best[i - 1][j - 2] > runningBest {
                    runningBest = best[i - 1][j - 2]
                    runningIndex = j - 2
                }
                guard haystack[j] == needle[i] else { continue }
                let own = 1 + (wordStart[j] ? wordStartBonus : 0)
                if i == 0 {
                    best[i][j] = own - Double(j) * 0.01
                    continue
                }
                var candidate = runningBest
                var source = runningIndex
                if j >= 1, best[i - 1][j - 1] > unmatched,
                   best[i - 1][j - 1] + consecutiveBonus >= candidate {
                    candidate = best[i - 1][j - 1] + consecutiveBonus
                    source = j - 1
                }
                guard candidate > unmatched else { continue }
                best[i][j] = candidate + own
                from[i][j] = source
            }
        }
        var end = -1
        var score = unmatched
        for j in 0 ..< n where best[m - 1][j] > score {
            score = best[m - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }
        var indices = [Int](repeating: 0, count: m)
        var position = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            indices[i] = position
            position = from[i][position]
        }
        if haystack.starts(with: needle) { score += prefixBonus }
        if haystack == needle { score += exactBonus }
        score -= Double(n) * 0.02
        return OmniMatch(score: score, indices: indices)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

// MARK: - Ranking

/// A row as shown: the item and the title's matched characters.
struct OmniRow: Equatable, Identifiable {
    var item: OmniItem
    var matched: [Int] = []

    var id: String { item.id }
}

/// A run of rows under an optional light header ("Recent", "Open").
struct OmniSection: Equatable, Identifiable {
    var title: String?
    var rows: [OmniRow]

    var id: String { title ?? "rows" }
}

/// Orders rows: by match score plus frecency, and Recent by frecency alone.
enum OmniRanking {
    /// Frecency (0 to about 200, `OmniFrecencyStore.scores`) counts this
    /// much against the match score: it orders matches of about the same
    /// quality, never a loose match over a prefix one.
    static let frecencyWeight = 0.08
    /// How many rows Recent shows, and at most how many of one kind.
    static let recentLimit = 7
    static let recentPerKindLimit = 3

    /// The items that match `query`, best first (ties: frecency, then
    /// title). Keywords match at half the score, unhighlighted.
    static func rank(
        _ items: [OmniItem],
        query: String,
        frecency: [String: Double],
        limit: Int? = nil
    ) -> [OmniRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var scored: [(row: OmniRow, score: Double, frecency: Double)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            let used = frecency[item.frecencyKey] ?? 0
            if let match = OmniMatcher.match(query, in: item.title) {
                scored.append((OmniRow(item: item, matched: match.indices), match.score + used * frecencyWeight, used))
            } else if let keywordScore = item.keywords.compactMap({ OmniMatcher.match(query, in: $0)?.score }).max() {
                scored.append((OmniRow(item: item), keywordScore * 0.5 + used * frecencyWeight, used))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
            let order = lhs.row.item.title.localizedStandardCompare(rhs.row.item.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.row.id < rhs.row.id
        }
        let rows = scored.map(\.row)
        if let limit { return Array(rows.prefix(limit)) }
        return rows
    }

    /// The root's Recent: the items used most, and most lately, together
    /// with what is live now (an open project, a working agent), at most
    /// `recentPerKindLimit` of a kind so projects, tabs, Macs and commands
    /// mix. Short of `recentLimit`, the rest in their given order.
    static func recent(_ items: [OmniItem], frecency: [String: Double]) -> [OmniRow] {
        func weight(_ item: OmniItem) -> Double {
            (frecency[item.frecencyKey] ?? 0) + item.liveBoost
        }
        let candidates = items.enumerated()
            .filter { weight($0.element) > 0 }
            .sorted { lhs, rhs in
                let l = weight(lhs.element)
                let r = weight(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)
        var picked: [OmniItem] = []
        var perKind: [OmniKind: Int] = [:]
        for item in candidates where picked.count < recentLimit {
            // Agents are commands here.
            let kind: OmniKind = item.kind == .agent ? .command : item.kind
            guard perKind[kind, default: 0] < recentPerKindLimit else { continue }
            perKind[kind, default: 0] += 1
            picked.append(item)
        }
        if picked.count < recentLimit {
            let taken = Set(picked.map(\.id))
            for item in items where picked.count < recentLimit && !taken.contains(item.id) && item.kind == .command {
                picked.append(item)
            }
        }
        return picked.map { OmniRow(item: $0) }
    }
}

// MARK: - Sources

/// A tab of an open window.
struct OmniTab: Equatable {
    var id: UUID
    var title: String
    /// Its window's project name.
    var projectName: String
    var machine: ProjectSwitcherModel.Machine
    var isWorking: Bool
    var canDetach: Bool
}

/// A background session (`BackgroundSessionsModel.allSessions`).
struct OmniBackgroundSession: Equatable {
    var id: String
    var title: String
    var machine: ProjectSwitcherModel.Machine
    var isAtWork: Bool
}

/// A worktree of the window's project.
struct OmniWorktree: Equatable {
    var root: String
    var name: String
    var branch: String?
    var isActive: Bool
    var canRename: Bool
    var canRemove: Bool
}

struct OmniEditor: Equatable {
    var id: String
    var name: String
}

struct OmniAgent: Equatable {
    var id: String
    var name: String
    var commandLine: String
}

/// What the window the bar is open in can do now (the commands offered).
struct OmniWindowContext: Equatable {
    var hasWorkspace = true
    var hasSelectedTab = false
    var canSplit = false
    var canDetach = false
    var canReopenClosedTab = false
    var hasProject = false
    var supportsWorktrees = false
    var isSidebarHidden = false
    var detachTitle = "Detach Tab"
    var closeTitle = "Close Tab"
}

/// Everything the bar lists, gathered from cached state (never by
/// connecting to a host): `OmniBarLiveModel.gather`.
struct OmniSources: Equatable {
    /// Projects and Macs (`ProjectSwitcherModel.make`).
    var projects = ProjectSwitcherModel(machines: [], locations: [])
    /// Each device as the picker menu knows it, for its actions.
    var devices: [TitlebarProjectMenuModel.Device] = []
    var tabs: [OmniTab] = []
    var backgroundSessions: [OmniBackgroundSession] = []
    var repositoryName = ""
    var worktrees: [OmniWorktree] = []
    var window = OmniWindowContext()
    /// Local projects in Settings › Projects (Remove from Projects).
    var listedLocalProjects: Set<String> = []
    /// Keys of open windows whose project has worktrees (New Worktree…).
    var worktreeProjectKeys: Set<String> = []
    /// The default editor each project opens in (Open in <editor>).
    var editorsByProjectKey: [String: OmniEditor] = [:]
    /// The editors the window's project opens in; the default one first.
    var editors: [OmniEditor] = []
    var agents: [OmniAgent] = []
    var agentPresets: [OmniAgent] = []
    var canModifyDevices = true
    var now = Date(timeIntervalSince1970: 0)
}

// MARK: - Providers

/// Turns the sources into rows, one function per kind.
enum OmniProviders {
    static func macName(_ machine: ProjectSwitcherModel.Machine, in sources: OmniSources) -> String {
        sources.projects.name(of: machine)
    }

    // MARK: Projects

    static func projects(_ sources: OmniSources, on machine: ProjectSwitcherModel.Machine? = nil) -> [OmniItem] {
        let model = sources.projects
        return model.locations
            .filter { machine == nil || $0.machine == machine }
            .map { location in
                let reachable = model.isReachable(location.machine)
                let status: OmniStatus? = if let open = location.openStatus {
                    open.workingAgents > 0 ? .working : .idle
                } else if !reachable {
                    .offline
                } else {
                    nil
                }
                return OmniItem(
                    id: "project:\(location.key)",
                    kind: .project,
                    title: location.name,
                    detail: location.machine == .thisMac ? "" : model.name(of: location.machine),
                    status: status,
                    symbol: "folder",
                    primaryLabel: location.isOpen ? "Switch" : "Open",
                    primary: .openProject(key: location.key),
                    actions: projectActions(location, sources: sources),
                    keywords: [location.displayPath],
                    machine: location.machine,
                    liveBoost: location.isOpen ? (location.isCurrent ? 10 : 40) : 0
                )
            }
    }

    static func projectActions(_ location: ProjectSwitcherModel.Location, sources: OmniSources) -> [OmniAction] {
        var actions: [OmniAction] = []
        if let editor = sources.editorsByProjectKey[location.key] {
            actions.append(.init(title: "Open in \(editor.name)", command: .openProjectInEditor(key: location.key, editorID: editor.id)))
        }
        if location.machine == .thisMac {
            actions.append(.init(title: "Reveal in Finder", command: .revealInFinder(path: location.path)))
        }
        actions.append(.init(title: "Copy Path", command: .copyPath(location.path)))
        if sources.worktreeProjectKeys.contains(location.key) {
            actions.append(.init(title: "New Worktree…", command: .newWorktreeInProject(key: location.key)))
        }
        switch location.machine {
        case .thisMac:
            if sources.listedLocalProjects.contains(location.key) {
                actions.append(.init(title: "Remove from Projects", command: .removeProject(key: location.key), isDestructive: true))
            }
        case .device(let id):
            if sources.canModifyDevices {
                actions.append(.init(
                    title: "Remove from Projects",
                    command: .switcher(.hideDeviceProject(deviceID: id, path: location.path)),
                    isDestructive: true
                ))
            }
        }
        return actions
    }

    /// Projects: Open, Recent (the five most recently opened of the rest)
    /// and All, alphabetical (then by Mac).
    static func projectSections(_ sources: OmniSources) -> [OmniSection] {
        let items = projects(sources)
        let locations = Dictionary(uniqueKeysWithValues: sources.projects.locations.map { ("project:\($0.key)", $0) })
        func location(_ item: OmniItem) -> ProjectSwitcherModel.Location? { locations[item.id] }
        let open = items.filter { location($0)?.isOpen == true }.sorted { lhs, rhs in
            let l = location(lhs)!, r = location(rhs)!
            if l.isCurrent != r.isCurrent { return l.isCurrent }
            return (l.lastOpened ?? .distantPast) > (r.lastOpened ?? .distantPast)
        }
        let recent = Array(items
            .filter { location($0)?.isOpen == false && location($0)?.lastOpened != nil }
            .sorted { (location($0)?.lastOpened ?? .distantPast) > (location($1)?.lastOpened ?? .distantPast) }
            .prefix(ProjectSwitcherModel.recentLimit))
        let listed = Set((open + recent).map(\.id))
        let all = items.filter { !listed.contains($0.id) }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.detail.localizedStandardCompare(rhs.detail) == .orderedAscending
        }
        return [
            OmniSection(title: "Open", rows: open.map { OmniRow(item: $0) }),
            OmniSection(title: "Recent", rows: recent.map { OmniRow(item: $0) }),
            OmniSection(title: "All", rows: all.map { OmniRow(item: $0) }),
        ].filter { !$0.rows.isEmpty }
    }

    /// "Open “<query>” as a folder…" for a path-like query.
    static func openPathItem(query: String, on machine: ProjectSwitcherModel.Machine = .thisMac) -> OmniItem? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectSwitcherModel.looksLikePath(query) else { return nil }
        return OmniItem(
            id: "open-path:\(query)",
            kind: .project,
            title: "Open “\(query)” as a folder…",
            symbol: "folder.badge.plus",
            primaryLabel: "Open",
            primary: .openPath(query, on: machine),
            recordsUse: false
        )
    }

    // MARK: Macs

    static func macs(_ sources: OmniSources) -> [OmniItem] {
        sources.projects.machines.map { info in
            let status: OmniStatus? = switch (info.machine, info.dot) {
            case (.thisMac, _): .idle
            case (_, .green): .idle
            case (_, .gray), (_, .red): .offline
            default: nil
            }
            let detail: String = if let count = info.sessionCount {
                count == 1 ? "1 session" : "\(count) sessions"
            } else if !info.isReachable {
                "Offline"
            } else {
                ""
            }
            let id = switch info.machine {
            case .thisMac: "mac:this"
            case .device(let uuid): "mac:\(uuid.uuidString)"
            }
            return OmniItem(
                id: id,
                kind: .mac,
                title: info.name,
                detail: detail,
                status: status,
                symbol: info.symbol,
                primaryLabel: "Show",
                primary: .drill(.mac(info.machine, name: info.name)),
                actions: macActions(info.machine, sources: sources),
                machine: info.machine
            )
        }
    }

    /// A Mac's ⌘K actions: its folders, a terminal on it, and, for a
    /// device, what the picker menu offers for it now (Reconnect, Trust New
    /// Identity…, Update Session Host…, Set Up Cherry MCP…, Rename…,
    /// Remove…; `TitlebarProjectMenuModel.deviceItem`).
    static func macActions(_ machine: ProjectSwitcherModel.Machine, sources: OmniSources) -> [OmniAction] {
        let hasBackground = sources.backgroundSessions.contains { $0.machine == machine }
        switch machine {
        case .thisMac:
            var actions: [OmniAction] = [
                .init(title: "Open Folder…", command: .openFolder(on: .thisMac)),
                .init(title: "Add Project…", command: .addProject(on: .thisMac)),
                .init(title: "New Terminal on This Mac", command: .newTerminal(on: .thisMac)),
                .init(title: "Persistent Sessions…", command: .menu(.persistentSessions)),
            ]
            if hasBackground {
                actions.append(.init(title: "End Background Sessions…", command: .endBackgroundSessions(on: .thisMac), isDestructive: true))
            }
            return actions
        case .device(let id):
            guard let entry = sources.devices.first(where: { $0.device.id == id }) else { return [] }
            let item = TitlebarProjectMenuModel.deviceItem(
                entry, currentProjectKey: nil, canModify: sources.canModifyDevices, now: sources.now
            )
            let offered: [TitlebarProjectMenuModel.Item] = (item.children ?? []).compactMap { child in
                guard case .item(let menuItem) = child, menuItem.isEnabled, !menuItem.isAlternate,
                      let action = menuItem.action
                else { return nil }
                switch action {
                case .openDeviceHome, .addDeviceProject, .reconnectDevice, .trustDeviceIdentity,
                     .updateDeviceHost, .setUpDeviceMCP, .renameDevice, .removeDevice:
                    return menuItem
                case .openDeviceSessions:
                    // "Other sessions" and "Persistent Sessions on …" are one.
                    return menuItem.title.hasPrefix("Persistent Sessions") ? menuItem : nil
                default:
                    return nil
                }
            }
            var actions: [OmniAction] = []
            for menuItem in offered {
                guard let action = menuItem.action else { continue }
                if case .renameDevice = action {
                    // The machine's own actions go before its management.
                    if hasBackground {
                        actions.append(.init(
                            title: "End Background Sessions…",
                            command: .endBackgroundSessions(on: machine),
                            isDestructive: true
                        ))
                    }
                }
                var isDestructive = false
                if case .removeDevice = action { isDestructive = true }
                actions.append(.init(title: menuItem.title, command: .switcher(action), isDestructive: isDestructive))
                if case .addDeviceProject = action {
                    actions.append(.init(title: "New Terminal on \(entry.device.name)", command: .newTerminal(on: machine)))
                }
            }
            if hasBackground, !actions.contains(where: { $0.title == "End Background Sessions…" }) {
                actions.append(.init(title: "End Background Sessions…", command: .endBackgroundSessions(on: machine), isDestructive: true))
            }
            return actions
        }
    }

    // MARK: Tabs and sessions

    static func tabs(_ sources: OmniSources, on machine: ProjectSwitcherModel.Machine? = nil) -> [OmniItem] {
        sources.tabs
            .filter { machine == nil || $0.machine == machine }
            .map { tab in
                var actions: [OmniAction] = [.init(title: "Rename…", command: .renameTab(tab.id))]
                if tab.canDetach { actions.append(.init(title: "Detach", command: .detachTab(tab.id))) }
                actions.append(.init(title: "Close", command: .closeTab(tab.id), isDestructive: true))
                return OmniItem(
                    id: "tab:\(tab.id.uuidString)",
                    kind: .tab,
                    title: tab.title,
                    detail: tab.projectName,
                    status: tab.isWorking ? .working : nil,
                    symbol: "terminal",
                    primaryLabel: "Go to Tab",
                    primary: .goToTab(tab.id),
                    actions: actions,
                    machine: tab.machine,
                    liveBoost: tab.isWorking ? 30 : 0
                )
            }
    }

    static func backgroundSessions(_ sources: OmniSources, on machine: ProjectSwitcherModel.Machine? = nil) -> [OmniItem] {
        sources.backgroundSessions
            .filter { machine == nil || $0.machine == machine }
            .map { session in
                OmniItem(
                    id: "session:\(session.id)",
                    kind: .session,
                    title: session.title,
                    detail: "background",
                    status: session.isAtWork ? .working : nil,
                    symbol: "terminal",
                    primaryLabel: "Open in Tab",
                    primary: .openBackgroundSession(id: session.id),
                    actions: [
                        .init(title: "Open in Tab", command: .openBackgroundSession(id: session.id)),
                        .init(title: "End Session", command: .endBackgroundSession(id: session.id), isDestructive: true),
                    ],
                    machine: session.machine
                )
            }
    }

    // MARK: Worktrees

    static func worktrees(_ sources: OmniSources) -> [OmniItem] {
        guard sources.window.supportsWorktrees else { return [] }
        return sources.worktrees.map { worktree in
            var actions: [OmniAction] = []
            if worktree.canRename {
                actions.append(.init(title: "Rename Branch…", command: .renameWorktree(root: worktree.root)))
            }
            if worktree.canRemove {
                actions.append(.init(title: "Remove…", command: .removeWorktree(root: worktree.root), isDestructive: true))
            }
            return OmniItem(
                id: "worktree:\(worktree.root)",
                kind: .worktree,
                title: worktree.name,
                detail: sources.repositoryName,
                status: worktree.isActive ? .idle : nil,
                symbol: "arrow.triangle.branch",
                primaryLabel: "Switch",
                primary: .activateWorktree(root: worktree.root),
                actions: actions,
                keywords: [worktree.branch].compactMap { $0 }
            )
        }
    }

    /// "New worktree “<query>”", when the query names no worktree.
    static func newWorktreeItem(query: String, sources: OmniSources) -> OmniItem? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sources.window.supportsWorktrees, !name.isEmpty else { return nil }
        let folded = name.lowercased()
        let exists = sources.worktrees.contains { worktree in
            worktree.name.lowercased() == folded || worktree.branch?.lowercased() == folded
        }
        guard !exists else { return nil }
        return OmniItem(
            id: "worktree-new:\(name)",
            kind: .worktree,
            title: "New worktree “\(name)”",
            symbol: "plus",
            primaryLabel: "Create",
            primary: .createWorktree(name: name),
            recordsUse: false
        )
    }

    // MARK: Commands

    static func command(
        _ command: OmniMenuCommand,
        title: String,
        shortcut: String = "",
        symbol: String,
        keywords: [String] = []
    ) -> OmniItem {
        OmniItem(
            id: "command:\(command.rawValue)",
            kind: .command,
            title: title,
            detail: shortcut,
            symbol: symbol,
            primaryLabel: "Run",
            primary: .menu(command),
            keywords: keywords
        )
    }

    /// The palette's commands and the main menu's actions this window can
    /// run now, then an agent row for each launchable agent.
    static func commands(_ sources: OmniSources) -> [OmniItem] {
        let window = sources.window
        var items: [OmniItem] = []
        if window.hasWorkspace {
            items.append(command(.newTab, title: "New Tab", shortcut: "⌘T", symbol: "plus.rectangle"))
        }
        if window.hasProject, !sources.agents.isEmpty {
            items.append(OmniItem(
                id: "command:agents",
                kind: .command,
                title: "New Agent",
                symbol: "sparkles",
                primaryLabel: "Show",
                primary: .drill(.agents)
            ))
        }
        if window.canSplit {
            items.append(command(.splitRight, title: "Split Right", shortcut: "⌘⇧D", symbol: "rectangle.split.2x1"))
        }
        if window.canDetach {
            items.append(command(.detachTab, title: window.detachTitle, shortcut: "⌘D", symbol: "rectangle.portrait.and.arrow.right"))
        }
        if window.hasSelectedTab {
            items.append(command(.closeTab, title: window.closeTitle, shortcut: "⌘W", symbol: "xmark.rectangle"))
        }
        if window.canReopenClosedTab {
            items.append(command(.reopenClosedTab, title: "Reopen Closed Tab", shortcut: "⌘Z", symbol: "arrow.uturn.backward"))
        }
        if window.hasSelectedTab {
            items.append(command(.clearScrollback, title: "Clear Scrollback", shortcut: "⌘K", symbol: "clear"))
        }
        if let editor = sources.editors.first {
            items.append(OmniItem(
                id: "editor:\(editor.id)",
                kind: .command,
                title: "Open in \(editor.name)",
                symbol: "arrow.up.forward.app",
                primaryLabel: "Open",
                primary: .openInEditor(editorID: editor.id)
            ))
            items.append(OmniItem(
                id: "command:openInOtherEditor",
                kind: .command,
                title: "Open in Other Editor…",
                symbol: "arrow.up.forward.app",
                primaryLabel: "Show",
                primary: .drill(.editors)
            ))
        }
        items.append(OmniItem(
            id: "command:projects",
            kind: .command,
            title: "Projects",
            detail: "⌘O",
            symbol: "folder",
            primaryLabel: "Show",
            primary: .drill(.projects)
        ))
        items.append(command(.addProject, title: "Add Project…", symbol: "folder.badge.plus"))
        if window.supportsWorktrees {
            items.append(OmniItem(
                id: "command:worktrees",
                kind: .command,
                title: "Worktrees",
                symbol: "arrow.triangle.branch",
                primaryLabel: "Show",
                primary: .drill(.worktrees)
            ))
            items.append(command(.newWorktree, title: "New Worktree…", symbol: "plus"))
            items.append(command(.manageWorktrees, title: "Manage Worktrees…", symbol: "list.bullet"))
        }
        items.append(OmniItem(
            id: "command:addAgent",
            kind: .command,
            title: "Add Agent…",
            symbol: "sparkles",
            primaryLabel: "Show",
            primary: .drill(.agentPresets)
        ))
        items.append(command(.persistentSessions, title: "Persistent Sessions…", shortcut: "⌘⇧R", symbol: "rectangle.stack"))
        if !sources.backgroundSessions.isEmpty {
            items.append(command(.endBackgroundSessions, title: "End Background Sessions…", symbol: "stop.circle"))
        }
        if sources.canModifyDevices {
            items.append(command(.addMac, title: "Add Mac…", symbol: "desktopcomputer"))
        }
        items.append(command(
            .toggleSidebar, title: window.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar",
            shortcut: "⌘S", symbol: "sidebar.left"
        ))
        items.append(command(
            .toggleAppearance, title: "Toggle Light/Dark Mode",
            symbol: "circle.lefthalf.filled", keywords: ["appearance", "theme"]
        ))
        items.append(command(.settings, title: "Settings", shortcut: "⌘,", symbol: "gearshape"))
        return items + agents(sources)
    }

    /// "New <agent> agent" for each launchable agent of the project.
    static func agents(_ sources: OmniSources) -> [OmniItem] {
        guard sources.window.hasProject else { return [] }
        return sources.agents.map { agent in
            OmniItem(
                id: "agent:\(agent.id)",
                kind: .agent,
                title: "New \(agent.name) agent",
                symbol: "sparkles",
                primaryLabel: "Start",
                primary: .launchAgent(id: agent.id),
                keywords: [agent.name, agent.commandLine]
            )
        }
    }

    static func agentScope(_ sources: OmniSources) -> [OmniItem] {
        agents(sources) + [OmniItem(
            id: "command:addAgent",
            kind: .command,
            title: "Add Agent…",
            symbol: "plus",
            primaryLabel: "Show",
            primary: .drill(.agentPresets)
        )]
    }

    static func agentPresets(_ sources: OmniSources) -> [OmniItem] {
        sources.agentPresets.map { preset in
            OmniItem(
                id: "preset:\(preset.id)",
                kind: .agent,
                title: preset.name,
                detail: preset.commandLine.isEmpty ? "Custom" : "",
                symbol: preset.commandLine.isEmpty ? "plus" : "sparkles",
                primaryLabel: "Add",
                primary: .configureAgentPreset(id: preset.id),
                keywords: [preset.commandLine]
            )
        }
    }

    static func editors(_ sources: OmniSources) -> [OmniItem] {
        sources.editors.map { editor in
            OmniItem(
                id: "editor:\(editor.id)",
                kind: .command,
                title: editor.name,
                symbol: "arrow.up.forward.app",
                primaryLabel: "Open",
                primary: .openInEditor(editorID: editor.id)
            )
        }
    }

    /// What the root searches: every kind.
    static func everything(_ sources: OmniSources) -> [OmniItem] {
        projects(sources) + tabs(sources) + backgroundSessions(sources) + macs(sources)
            + worktrees(sources) + commands(sources)
    }

    /// The Recent candidates at the root.
    static func recentCandidates(_ sources: OmniSources) -> [OmniItem] {
        projects(sources) + tabs(sources) + macs(sources) + commands(sources)
    }
}

// MARK: - Sections

enum OmniSections {
    /// How many rows a query at the root shows.
    static let rootResultLimit = 10

    static func build(scope: OmniScope?, query: String, sources: OmniSources, frecency: [String: Double]) -> [OmniSection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = query.isEmpty
        func ranked(_ items: [OmniItem], limit: Int? = nil) -> [OmniSection] {
            let rows = isEmpty ? items.map { OmniRow(item: $0) } : OmniRanking.rank(items, query: query, frecency: frecency, limit: limit)
            return rows.isEmpty ? [] : [OmniSection(title: nil, rows: rows)]
        }
        switch scope {
        case nil:
            if isEmpty {
                let rows = OmniRanking.recent(OmniProviders.recentCandidates(sources), frecency: frecency)
                return rows.isEmpty ? [] : [OmniSection(title: "Recent", rows: rows)]
            }
            var sections = ranked(OmniProviders.everything(sources), limit: rootResultLimit)
            if let open = OmniProviders.openPathItem(query: query) {
                sections.append(OmniSection(title: nil, rows: [OmniRow(item: open)]))
            }
            return merged(sections)
        case .projects?:
            if isEmpty { return OmniProviders.projectSections(sources) }
            var sections = ranked(OmniProviders.projects(sources))
            if let open = OmniProviders.openPathItem(query: query) {
                sections.append(OmniSection(title: nil, rows: [OmniRow(item: open)]))
            }
            return merged(sections)
        case .macs?:
            return ranked(OmniProviders.macs(sources))
        case .mac(let machine, _)?:
            let sessions = OmniProviders.tabs(sources, on: machine) + OmniProviders.backgroundSessions(sources, on: machine)
            let projects = OmniProviders.projects(sources, on: machine)
            if isEmpty {
                let byUse = projects.enumerated().sorted { lhs, rhs in
                    let l = (frecency[lhs.element.frecencyKey] ?? 0) + lhs.element.liveBoost
                    let r = (frecency[rhs.element.frecencyKey] ?? 0) + rhs.element.liveBoost
                    if l != r { return l > r }
                    return lhs.element.title.localizedStandardCompare(rhs.element.title) == .orderedAscending
                }.map(\.element)
                return ranked(sessions + byUse)
            }
            return ranked(sessions + projects)
        case .tabs?:
            return ranked(OmniProviders.tabs(sources) + OmniProviders.backgroundSessions(sources))
        case .worktrees?:
            var sections = ranked(OmniProviders.worktrees(sources))
            if !isEmpty, let create = OmniProviders.newWorktreeItem(query: query, sources: sources) {
                sections.append(OmniSection(title: nil, rows: [OmniRow(item: create)]))
            }
            return merged(sections)
        case .commands?:
            return ranked(OmniProviders.commands(sources))
        case .agents?:
            return ranked(OmniProviders.agentScope(sources))
        case .agentPresets?:
            return ranked(OmniProviders.agentPresets(sources))
        case .editors?:
            return ranked(OmniProviders.editors(sources))
        }
    }

    /// Untitled sections as one.
    private static func merged(_ sections: [OmniSection]) -> [OmniSection] {
        guard sections.allSatisfy({ $0.title == nil }), sections.count > 1 else { return sections }
        return [OmniSection(title: nil, rows: sections.flatMap(\.rows))]
    }
}

// MARK: - The bar's state

/// The bar's state: the scope stack (the crumb), the query, the selected
/// row and the ⌘K action list. Keys reach it from the search field
/// (`OmniBarView`) and ⌘K from `AppShortcutMonitor`, only while the bar is
/// open. Running a row goes to `run`; drilling stays here.
@MainActor
final class OmniBarController: ObservableObject {
    @Published private(set) var stack: [OmniScope] = []
    @Published private(set) var query = ""
    @Published private(set) var sections: [OmniSection] = []
    @Published private(set) var selection = 0
    @Published private(set) var isActionListOpen = false
    @Published private(set) var actionSelection = 0
    /// Bumped when the keyboard moves the selection: the list scrolls it
    /// into view.
    @Published private(set) var scrollRequest = 0
    /// Bumped when the rows change from the top (a new query or scope).
    @Published private(set) var resetScrollRequest = 0

    /// Runs a row's primary or ⌘K command (not a drill).
    var run: (OmniCommand) -> Void
    /// Records that a row was used (`OmniFrecencyStore`).
    var recordUse: (String) -> Void
    /// Closes the bar (Esc at the root).
    var close: () -> Void

    private(set) var sources: OmniSources
    private(set) var frecency: [String: Double]

    init(
        sources: OmniSources = OmniSources(),
        frecency: [String: Double] = [:],
        run: @escaping (OmniCommand) -> Void = { _ in },
        recordUse: @escaping (String) -> Void = { _ in },
        close: @escaping () -> Void = {}
    ) {
        self.sources = sources
        self.frecency = frecency
        self.run = run
        self.recordUse = recordUse
        self.close = close
        recompute(resetSelection: true)
    }

    var scope: OmniScope? { stack.last }

    var rows: [OmniRow] { sections.flatMap(\.rows) }

    var selectedItem: OmniItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection].item : nil
    }

    var selectedActions: [OmniAction] { selectedItem?.actions ?? [] }

    var placeholder: String { scope?.placeholder ?? "Search…" }

    var hint: String {
        scope == nil ? "@ Macs   # Tabs   / Worktrees   > Commands" : "⌫ to go back"
    }

    var primaryLabel: String { selectedItem?.primaryLabel ?? "Open" }

    // MARK: Data

    func update(sources: OmniSources? = nil, frecency: [String: Double]? = nil) {
        var changed = false
        if let sources, sources != self.sources {
            self.sources = sources
            changed = true
        }
        if let frecency, frecency != self.frecency {
            self.frecency = frecency
            changed = true
        }
        if changed { recompute(resetSelection: false) }
    }

    private func recompute(resetSelection: Bool) {
        let selectedID = resetSelection ? nil : selectedItem?.id
        sections = OmniSections.build(scope: scope, query: query, sources: sources, frecency: frecency)
        let rows = rows
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else {
            selection = resetSelection ? 0 : min(selection, max(rows.count - 1, 0))
        }
        if resetSelection {
            isActionListOpen = false
            resetScrollRequest &+= 1
        } else if isActionListOpen {
            let count = selectedActions.count
            if count == 0 {
                isActionListOpen = false
            } else {
                actionSelection = min(actionSelection, count - 1)
            }
        }
    }

    // MARK: Scopes

    /// Opens at the root (nil) or in `scope`, with an empty query.
    func open(at scope: OmniScope?) {
        stack = scope.map { [$0] } ?? []
        query = ""
        recompute(resetSelection: true)
    }

    func push(_ scope: OmniScope) {
        stack.append(scope)
        query = ""
        recompute(resetSelection: true)
    }

    func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        query = ""
        recompute(resetSelection: true)
    }

    /// The field's text changed. At the root, a first character that is a
    /// scope's prefix (`>`, `@`, `#`, `/`) enters that scope instead.
    func setQuery(_ text: String) {
        // A pasted path ("/Users/…") is a query, not the Worktrees scope.
        let isPastedPath = text.first == "/" && text.dropFirst().contains("/")
        if stack.isEmpty, query.isEmpty, !isPastedPath, let first = text.first, let scope = OmniScope.forPrefix(first) {
            stack = [scope]
            query = String(text.dropFirst().drop(while: \.isWhitespace))
            recompute(resetSelection: true)
            return
        }
        guard text != query else { return }
        query = text
        recompute(resetSelection: true)
    }

    // MARK: Keys

    /// ⌫ with an empty field steps out of the scope; false when there is
    /// nothing to step out of (the field handles it).
    func deleteBackwardOnEmptyField() -> Bool {
        guard query.isEmpty, !stack.isEmpty else { return false }
        if isActionListOpen {
            isActionListOpen = false
            return true
        }
        pop()
        return true
    }

    /// Esc: closes the action list, else clears the query, else steps out,
    /// else closes the bar.
    func escape() {
        if isActionListOpen {
            isActionListOpen = false
        } else if !query.isEmpty {
            query = ""
            recompute(resetSelection: true)
        } else if !stack.isEmpty {
            pop()
        } else {
            close()
        }
    }

    func moveSelection(by delta: Int) {
        if isActionListOpen {
            let count = selectedActions.count
            guard count > 0 else { return }
            actionSelection = min(max(actionSelection + delta, 0), count - 1)
            return
        }
        let count = rows.count
        guard count > 0 else { return }
        let next = min(max(selection + delta, 0), count - 1)
        guard next != selection else { return }
        selection = next
        scrollRequest &+= 1
    }

    /// The pointer moved over a row.
    func hover(_ index: Int) {
        guard !isActionListOpen, rows.indices.contains(index), selection != index else { return }
        selection = index
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selection = index
        isActionListOpen = false
    }

    /// ↵: the selected action while the action list is open, else the
    /// selected row's primary (a drill enters its scope).
    func activate() {
        if isActionListOpen {
            runAction(at: actionSelection)
            return
        }
        guard let item = selectedItem else { return }
        if item.recordsUse { recordUse(item.frecencyKey) }
        if let scope = item.drillScope {
            push(scope)
        } else {
            run(item.primary)
        }
    }

    /// ⇥: enters the selected row's scope (a Mac, New Agent…); false when
    /// it has none.
    @discardableResult
    func drillIntoSelection() -> Bool {
        guard !isActionListOpen, let item = selectedItem, let scope = item.drillScope else { return false }
        if item.recordsUse { recordUse(item.frecencyKey) }
        push(scope)
        return true
    }

    /// ⌘K: opens the selected row's actions (closes them when open);
    /// false when the row has none.
    @discardableResult
    func toggleActions() -> Bool {
        if isActionListOpen {
            isActionListOpen = false
            return true
        }
        guard !selectedActions.isEmpty else { return false }
        actionSelection = 0
        isActionListOpen = true
        return true
    }

    func hoverAction(_ index: Int) {
        guard isActionListOpen, selectedActions.indices.contains(index) else { return }
        actionSelection = index
    }

    func runAction(at index: Int) {
        let actions = selectedActions
        guard actions.indices.contains(index) else { return }
        isActionListOpen = false
        if let item = selectedItem, item.recordsUse { recordUse(item.frecencyKey) }
        run(actions[index].command)
    }
}
