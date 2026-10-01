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
    /// A folder of folder completion (`OmniFolderRows`).
    case folder
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
        case .mac(_, let name): "Search \(name), or type ~/ to browse it"
        case .projects: "Search projects, or type ~/ to browse"
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
    /// Add Project… and Open Folder… (on a Mac): folder completion there,
    /// with "~/" (the bar's own).
    case browseFolders(on: ProjectSwitcherModel.Machine, intent: OmniFolderIntent)
    /// A folder of folder completion: its folders (the bar's own; the
    /// query becomes this).
    case enterFolder(String)
    /// Adds the folder at this path (absolute, or `~/…` on a device) to
    /// the projects of its Mac, and opens it when `open`.
    case addFolder(path: String, on: ProjectSwitcherModel.Machine, open: Bool)
    /// A new terminal in this folder of that Mac.
    case newTerminalAt(path: String, on: ProjectSwitcherModel.Machine)
    /// Connects a device that is not connected (Reconnect), keeping the bar
    /// open: its folders list once it is.
    case connectDevice(UUID)
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
    /// An SF Symbol, shown when it has no `logo`.
    var symbol: String
    /// The agent's logo (`Resources/AgentLogos`,
    /// `AgentToolBrand.logoResourceName`), shown instead of `symbol`.
    var logo: String?
    /// An app bundle whose icon the row shows (an editor's), in full
    /// colour, instead of `logo` and `symbol`; the symbol when it is gone
    /// (`OmniAppIconCache`).
    var appPath: String? = nil
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
    /// The colour its `detail` is tinted with: a project on another Mac
    /// names that Mac in its colour.
    var detailColor: RemoteDeviceColor? = nil
    /// Added to its frecency in Recent: an open project, a working agent.
    var liveBoost: Double = 0
    /// Whether ↵ records it as used (not a "New worktree" row).
    var recordsUse = true
    /// What ⇥ puts in the field (a folder's path and "/").
    var completion: String? = nil
    /// Added to its match score when ranked (a repository not added yet
    /// goes after a project of the same name).
    var rankBias: Double = 0

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

/// Matches a query in a title, case and diacritic insensitively. A title
/// matches only when the query is in it as one run (a contiguous
/// substring), or as runs that each start a word ("nca" in "New Claude
/// agent", "fc" in "fastapi-cli"); letters scattered inside words never
/// match ("add" is not in "alpacas-and-ducks"). A word starts at the
/// title's start, after a space, `-`, `_`, `.`, `/`, `:`, `·` or `|`,
/// after a lower-to-upper case change, and where letters follow other
/// characters.
///
/// Scores: one run 40, 20 more at a word start and 10 more at the title's
/// start, 10 more for the whole title; runs at word starts 20, less a
/// little per run. Shorter titles win ties.
enum OmniMatcher {
    static let substringScore = 40.0
    static let wordStartBonus = 20.0
    static let prefixBonus = 10.0
    static let exactBonus = 10.0
    static let wordRunsScore = 20.0
    static let separators: Set<Character> = [" ", "-", "_", ".", "/", ":", "·", "|"]

    static func match(_ query: String, in text: String) -> OmniMatch? {
        let needle = Array(query.trimmingCharacters(in: .whitespacesAndNewlines)).map(fold)
        guard !needle.isEmpty else { return OmniMatch(score: 0, indices: []) }
        let characters = Array(text)
        let haystack = characters.map(fold)
        let starts = wordStarts(characters)
        let lengthPenalty = Double(haystack.count) * 0.02

        // One run: its best place (the title's start, then a word start).
        if needle.count <= haystack.count {
            var best: (score: Double, at: Int)?
            for at in 0 ... haystack.count - needle.count where haystack[at] == needle[0] {
                guard Array(haystack[at ..< at + needle.count]) == needle else { continue }
                var score = substringScore
                if starts[at] { score += wordStartBonus }
                if at == 0 { score += prefixBonus }
                if best == nil || score > best!.score { best = (score, at) }
                if at == 0 { break }
            }
            if let best {
                var score = best.score - lengthPenalty
                if needle.count == haystack.count { score += exactBonus }
                return OmniMatch(score: score, indices: Array(best.at ..< best.at + needle.count))
            }
        }

        // Runs that each start a word (the query's spaces only split runs).
        let compact = needle.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !compact.isEmpty else { return nil }
        let wordStartOffsets = starts.indices.filter { starts[$0] }
        guard let runs = wordRuns(compact, haystack: haystack, starts: wordStartOffsets) else { return nil }
        let indices = runs.flatMap { Array($0.start ..< $0.start + $0.length) }
        return OmniMatch(score: wordRunsScore - Double(runs.count) * 0.5 - lengthPenalty, indices: indices)
    }

    /// Whether each character starts a word.
    static func wordStarts(_ characters: [Character]) -> [Bool] {
        characters.indices.map { j in
            if j == 0 { return true }
            let previous = characters[j - 1]
            let current = characters[j]
            return previous.isWhitespace || separators.contains(previous)
                || (previous.isLowercase && current.isUppercase)
                || (!previous.isLetter && !previous.isNumber && (current.isLetter || current.isNumber))
        }
    }

    /// The query as runs, each starting at one of `starts` (after the one
    /// before it), longest runs first; nil when it cannot be.
    private static func wordRuns(_ needle: [String], haystack: [String], starts: [Int]) -> [(start: Int, length: Int)]? {
        var failed = Set<[Int]>()
        func solve(_ from: Int, _ startIndex: Int) -> [(start: Int, length: Int)]? {
            if from == needle.count { return [] }
            guard !failed.contains([from, startIndex]) else { return nil }
            for index in startIndex ..< starts.count {
                let start = starts[index]
                var length = 0
                while from + length < needle.count, start + length < haystack.count,
                      haystack[start + length] == needle[from + length] {
                    length += 1
                }
                while length > 0 {
                    let end = start + length
                    let next = starts[(index + 1)...].firstIndex { $0 >= end } ?? starts.count
                    if let rest = solve(from + length, next) { return [(start, length)] + rest }
                    length -= 1
                }
            }
            failed.insert([from, startIndex])
            return nil
        }
        return solve(0, 0)
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
    /// Tells apart two untitled sections (the rows, then the actions).
    var key: String? = nil

    var id: String { key ?? title ?? "rows" }
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
                scored.append((OmniRow(item: item, matched: match.indices), match.score + used * frecencyWeight + item.rankBias, used))
            } else if let keywordScore = item.keywords.compactMap({ OmniMatcher.match(query, in: $0)?.score }).max() {
                scored.append((OmniRow(item: item), keywordScore * 0.5 + used * frecencyWeight + item.rankBias, used))
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
    /// Its detail: its window's project name, or for a window with no
    /// project (its home folder) its directory's name, "~" at home
    /// (`OmniTab.detail`).
    var projectName: String
    var machine: ProjectSwitcherModel.Machine
    var isWorking: Bool
    var canDetach: Bool
    /// An agent tab's tool (a brand's raw value, or the agent's name), for
    /// its logo; nil for other tabs.
    var agentKey: String? = nil

    /// A tab's detail: its window's folder name, unless the window is at
    /// the home folder (no project), where it is the tab's directory's
    /// name, or "~" when that is the home folder too (never the bare home
    /// folder's name, the user's name). `home` is the Mac's home folder
    /// when known; otherwise a `/Users/<name>` or `/home/<name>` window
    /// counts as one.
    static func detail(windowPath: String, workingDirectory: String?, home: String?) -> String {
        if !SessionDisplayTitle.isHome(windowPath, home: home), windowPath != "/" {
            return SessionDisplayTitle.directoryName(windowPath, home: home)
        }
        guard let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty
        else { return "~" }
        return SessionDisplayTitle.directoryName(directory, home: home)
    }
}

/// A background session (`BackgroundSessionsModel.allSessions`).
struct OmniBackgroundSession: Equatable {
    var id: String
    /// Its own name (`BackgroundSession.displayTitle`): an agent's task
    /// title, a shell's command or directory; never its tool's name.
    var title: String
    var machine: ProjectSwitcherModel.Machine
    /// Its agent is known to be at work (`BackgroundSession.isWorking`); a
    /// session merely running is not.
    var isWorking: Bool
    /// An agent session's tool (`cherry.agent`), for its logo; nil for
    /// other sessions.
    var agentKey: String? = nil
    /// The project it belongs to (`cherry.project`), nil for none.
    var projectName: String? = nil

    /// "cloud · background", or "background" without a project.
    var detail: String {
        [projectName, "background"].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
    }
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
    /// Its app bundle (`InstalledEditor.appURL`), for its icon.
    var appPath: String? = nil
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
    /// Folder listings by the folder typed (`OmniFolderBrowser`).
    var folderListings: [OmniFolderRequest: OmniFolderListing] = [:]
    /// The git repositories found under the usual places on each Mac
    /// (`OmniRepositoryScanner`), added or not.
    var unaddedRepositories: [OmniUnaddedRepository] = []
    /// Each Mac's home folder, when known.
    var homes: [ProjectSwitcherModel.Machine: String] = [:]
    /// Folders never offered as "Not added yet": This Mac's projects the
    /// user removed, a device's hidden ones.
    var removedProjects: [ProjectSwitcherModel.Machine: Set<String>] = [:]
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
                    detailColor: location.machine.deviceID.flatMap { id in
                        sources.devices.first { $0.device.id == id }?.device.effectiveColor
                    },
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
    /// Only for "~" itself: a query starting with `~/` or `/` lists folders
    /// instead (`OmniFolderRows`).
    static func openPathItem(query: String, on machine: ProjectSwitcherModel.Machine = .thisMac) -> OmniItem? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectSwitcherModel.looksLikePath(query), OmniPathQuery.parse(query) == nil else { return nil }
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
                .init(title: "Open Folder…", command: .browseFolders(on: .thisMac, intent: .openOnce)),
                .init(title: "Add Project…", command: .browseFolders(on: .thisMac, intent: .add)),
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
                if case .addDeviceProject = action {
                    // Its folders, in the bar.
                    actions.append(.init(title: menuItem.title, command: .browseFolders(on: machine, intent: .add)))
                } else {
                    actions.append(.init(title: menuItem.title, command: .switcher(action), isDestructive: isDestructive))
                }
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
                    logo: tab.agentKey.flatMap(AgentToolBrand.logoResourceName(forAgentKey:)),
                    primaryLabel: "Go to Tab",
                    primary: .goToTab(tab.id),
                    actions: actions,
                    keywords: agentKeywords(tab.agentKey),
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
                    detail: session.detail,
                    status: session.isWorking ? .working : nil,
                    symbol: "terminal",
                    logo: session.agentKey.flatMap(AgentToolBrand.logoResourceName(forAgentKey:)),
                    primaryLabel: "Open in Tab",
                    primary: .openBackgroundSession(id: session.id),
                    actions: [
                        .init(title: "Open in Tab", command: .openBackgroundSession(id: session.id)),
                        .init(title: "End Session", command: .endBackgroundSession(id: session.id), isDestructive: true),
                    ],
                    keywords: agentKeywords(session.agentKey),
                    machine: session.machine
                )
            }
    }

    /// An agent's tool by name ("Claude"), so a query for it finds the
    /// agent's rows, whose titles are their tasks.
    static func agentKeywords(_ agentKey: String?) -> [String] {
        guard let agentKey = agentKey?.nilIfEmpty else { return [] }
        let brand = AgentToolBrand(rawValue: agentKey) ?? AgentToolBrand.detect(name: agentKey)
        return [brand?.displayName ?? agentKey]
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
                appPath: editor.appPath,
                primaryLabel: "Open",
                primary: .openInEditor(editorID: editor.id)
            ))
            // The first other editor's icon (the default's when it is the
            // only one).
            let other = sources.editors.dropFirst().first ?? editor
            items.append(OmniItem(
                id: "command:openInOtherEditor",
                kind: .command,
                title: "Open in Other Editor…",
                symbol: "arrow.up.forward.app",
                appPath: other.appPath,
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
        items += OmniFolderRows.browseItems(sources, on: .thisMac)
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
                logo: logo(for: agent),
                primaryLabel: "Start",
                primary: .launchAgent(id: agent.id),
                keywords: [agent.name, agent.commandLine]
            )
        }
    }

    /// An agent's (or a preset's, by its base tool) logo, as the sidebar
    /// resolves it; nil for a tool without one.
    static func logo(for agent: OmniAgent) -> String? {
        AgentToolBrand.detect(name: agent.name, commandLine: agent.commandLine)?.logoResourceName
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
                logo: preset.commandLine.isEmpty ? nil : logo(for: preset),
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
                appPath: editor.appPath,
                primaryLabel: "Open",
                primary: .openInEditor(editorID: editor.id)
            )
        }
    }

    /// What the root searches: every kind, the repositories not added yet
    /// and each Mac's Add Project and Open Folder rows.
    static func everything(_ sources: OmniSources) -> [OmniItem] {
        projects(sources) + tabs(sources) + backgroundSessions(sources) + macs(sources)
            + worktrees(sources) + commands(sources) + OmniFolderRows.browseItems(sources)
            + OmniUnaddedRows.items(sources, withQuery: true)
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

    static func build(
        scope: OmniScope?,
        query rawQuery: String,
        sources: OmniSources,
        frecency: [String: Double],
        folderIntent: OmniFolderIntent = .add
    ) -> [OmniSection] {
        // A path query lists the folders of the scope's Mac.
        if let machine = OmniFolderRows.machine(for: scope), let path = OmniPathQuery.parse(rawQuery) {
            let rows = OmniFolderRows.rows(path, on: machine, sources: sources, intent: folderIntent)
            return rows.isEmpty ? [] : [OmniSection(title: nil, rows: rows)]
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = query.isEmpty
        func ranked(_ items: [OmniItem], limit: Int? = nil) -> [OmniSection] {
            let rows = isEmpty ? items.map { OmniRow(item: $0) } : OmniRanking.rank(items, query: query, frecency: frecency, limit: limit)
            return rows.isEmpty ? [] : [OmniSection(title: nil, rows: rows)]
        }
        func unadded(on machine: ProjectSwitcherModel.Machine?) -> OmniSection {
            OmniSection(title: "Not added yet", rows: OmniUnaddedRows.items(sources, on: machine, withQuery: false).map { OmniRow(item: $0) })
        }
        func browse(on machine: ProjectSwitcherModel.Machine) -> OmniSection {
            OmniSection(title: nil, rows: OmniFolderRows.browseItems(sources, on: machine).map { OmniRow(item: $0) }, key: "browse")
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
            if isEmpty {
                return (OmniProviders.projectSections(sources) + [unadded(on: nil), browse(on: .thisMac)])
                    .filter { !$0.rows.isEmpty }
            }
            var sections = ranked(
                OmniProviders.projects(sources) + OmniUnaddedRows.items(sources, withQuery: true)
                    + OmniFolderRows.browseItems(sources)
            )
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
                return (ranked(sessions + byUse) + [unadded(on: machine), browse(on: machine)]).filter { !$0.rows.isEmpty }
            }
            return ranked(
                sessions + projects + OmniUnaddedRows.items(sources, on: machine, withQuery: true)
                    + OmniFolderRows.browseItems(sources, on: machine)
            )
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

    /// What the list says when it has no rows.
    static func emptyState(scope: OmniScope?, query: String, sources: OmniSources) -> OmniEmptyState {
        if let machine = OmniFolderRows.machine(for: scope), let path = OmniPathQuery.parse(query) {
            return OmniFolderRows.emptyState(path, on: machine, sources: sources)
        }
        switch scope {
        case .projects?:
            return OmniEmptyState(text: "No project matches · type ~/ to browse folders")
        case .mac(_, let name)?:
            return OmniEmptyState(text: "Nothing matches · type ~/ to browse \(name)")
        default:
            return OmniEmptyState()
        }
    }

    /// Each row once (its first), and no empty section: rows are keyed and
    /// selected by id, so two rows with one id would show two selections.
    static func unique(_ sections: [OmniSection]) -> [OmniSection] {
        var seen = Set<String>()
        return sections.compactMap { section in
            var section = section
            section.rows = section.rows.filter { seen.insert($0.id).inserted }
            return section.rows.isEmpty ? nil : section
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
///
/// The selection is a row id, and a list with rows always has one: a new
/// query or scope selects the first row; any other change of the rows (the
/// sources or frecency updating while the bar is open) keeps the selected
/// row when it is still listed, else selects the first. The pointer selects
/// the row it moves over (`hover(id:)`), the keys move from there.
@MainActor
final class OmniBarController: ObservableObject {
    @Published private(set) var stack: [OmniScope] = []
    @Published private(set) var query = ""
    @Published private(set) var sections: [OmniSection] = []
    /// The selected row's id; nil only while there are no rows.
    @Published private(set) var selectedID: String?
    @Published private(set) var isActionListOpen = false
    @Published private(set) var actionSelection = 0
    /// Bumped when the keyboard moves the selection: the list scrolls it
    /// into view.
    @Published private(set) var scrollRequest = 0
    /// Bumped when the rows change from the top (a new query or scope).
    @Published private(set) var resetScrollRequest = 0
    /// What the list says while it has no rows.
    @Published private(set) var emptyState = OmniEmptyState()
    /// What browsing folders is for: set by Add Project… (add) and Open
    /// Folder… (open once), back to add in a new scope.
    @Published private(set) var folderIntent: OmniFolderIntent = .add

    /// Asks for a folder's listing (`OmniFolderBrowser.request`), each time
    /// a path query or its scope changes; the listing comes back in the
    /// sources (`update`).
    var requestFolderListing: (OmniFolderRequest) -> Void = { _ in }

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

    /// The selected row's index in `rows` (0 when there are none).
    var selection: Int {
        guard let selectedID else { return 0 }
        return rows.firstIndex { $0.id == selectedID } ?? 0
    }

    var selectedItem: OmniItem? {
        guard let selectedID else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == selectedID }) { return row.item }
        }
        return nil
    }

    func isSelected(_ row: OmniRow) -> Bool { row.id == selectedID }

    var selectedActions: [OmniAction] { selectedItem?.actions ?? [] }

    var placeholder: String { scope?.placeholder ?? "Search…" }

    var hint: String {
        if let request = folderRequest {
            return "Folders on \(sources.projects.name(of: request.machine)) · ⇥ completes"
        }
        return scope == nil ? "~/ Folders   @ Macs   # Tabs   / Worktrees   > Commands" : "⌫ to go back"
    }

    /// The listing the query asks for, when it is a path query.
    var folderRequest: OmniFolderRequest? {
        OmniFolderRows.request(scope: scope, query: query)
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
        let kept = resetSelection ? nil : selectedID
        sections = OmniSections.unique(OmniSections.build(
            scope: scope, query: query, sources: sources, frecency: frecency, folderIntent: folderIntent
        ))
        let empty = OmniSections.emptyState(scope: scope, query: query, sources: sources)
        if emptyState != empty { emptyState = empty }
        if resetSelection, let request = folderRequest { requestFolderListing(request) }
        let rows = rows
        if let kept, rows.contains(where: { $0.id == kept }) {
            if selectedID != kept { selectedID = kept }
        } else {
            let first = rows.first?.id
            if selectedID != first { selectedID = first }
            // The selected row went away: show the first.
            if !resetSelection, kept != nil { scrollRequest &+= 1 }
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
        folderIntent = .add
        recompute(resetSelection: true)
    }

    func push(_ scope: OmniScope) {
        stack.append(scope)
        query = ""
        folderIntent = .add
        recompute(resetSelection: true)
    }

    func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        query = ""
        folderIntent = .add
        recompute(resetSelection: true)
    }

    /// Add Project… and Open Folder…: folder completion on `machine` with
    /// "~/": in Projects for This Mac (unless the bar is in This Mac's
    /// scope), in the Mac's scope for another.
    func browseFolders(on machine: ProjectSwitcherModel.Machine, intent: OmniFolderIntent) {
        isActionListOpen = false
        var inScope = false
        if case .mac(let scoped, _)? = scope, scoped == machine { inScope = true }
        if machine == .thisMac, scope == .projects { inScope = true }
        if !inScope {
            stack = machine == .thisMac ? [.projects] : [.macs, .mac(machine, name: sources.projects.name(of: machine))]
        }
        query = "~/"
        folderIntent = intent
        recompute(resetSelection: true)
    }

    /// Runs a command that is the bar's own (a scope, folder completion);
    /// false for any other.
    private func performInBar(_ command: OmniCommand) -> Bool {
        switch command {
        case .drill(let scope):
            push(scope)
        case .browseFolders(let machine, let intent):
            browseFolders(on: machine, intent: intent)
        case .enterFolder(let path):
            isActionListOpen = false
            setQuery(path)
        default:
            return false
        }
        return true
    }

    /// The field's text changed. At the root, a first character that is a
    /// scope's prefix (`>`, `@`, `#`, `/`) enters that scope instead.
    func setQuery(_ text: String) {
        // A pasted path ("/Users/…") is a query, not the Worktrees scope.
        let isPastedPath = text.first == "/" && text.dropFirst().contains("/")
        // Without worktrees, "/" starts a path.
        let isPath = text.first == "/" && !sources.window.supportsWorktrees
        if stack.isEmpty, query.isEmpty, !isPastedPath, !isPath, let first = text.first, let scope = OmniScope.forPrefix(first) {
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
        let rows = rows
        guard !rows.isEmpty else { return }
        let current = selection
        let next = min(max(current + delta, 0), rows.count - 1)
        guard next != current || selectedID != rows[next].id else { return }
        selectedID = rows[next].id
        scrollRequest &+= 1
    }

    /// The pointer moved over a row (the view calls this only when the
    /// pointer itself moved, never when a row moved under a still pointer:
    /// `OmniPointerTracker`).
    func hover(id: String) {
        guard !isActionListOpen, selectedID != id, rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func select(_ index: Int) {
        let rows = rows
        guard rows.indices.contains(index) else { return }
        selectedID = rows[index].id
        isActionListOpen = false
    }

    func select(id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
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
        if !performInBar(item.primary) {
            run(item.primary)
        }
    }

    /// ⇥: enters the selected row's scope (a Mac, New Agent…), or completes
    /// the selected folder with "/"; false when it has neither.
    @discardableResult
    func drillIntoSelection() -> Bool {
        guard !isActionListOpen, let item = selectedItem else { return false }
        if let completion = item.completion {
            setQuery(completion)
            return true
        }
        guard let scope = item.drillScope else { return false }
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
        if !performInBar(actions[index].command) {
            run(actions[index].command)
        }
    }
}
