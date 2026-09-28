import CherryControl
import Foundation

// The title bar's project switcher (the picker button, ⌘O): the classic
// `NSMenu` (`TitlebarProjectMenuModel`), a centred palette over the window
// (`ProjectSwitcherPalette`) or a popover with a rail of Macs
// (`ProjectSwitcherMacsSidebar`). The palette and the sidebar are built from
// `ProjectSwitcherModel`, which is pure: tests give it projects, devices,
// open windows and recency, and read its sections.

/// Which switcher the title-bar picker and ⌘O open (Prototype menu,
/// Settings › General).
enum ProjectSwitcherStyle: String, CaseIterable, Identifiable {
    case menu
    case palette
    case sidebar

    static let defaultsKey = "projectSwitcher.style"
    static let defaultStyle: Self = .palette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: "Menu"
        case .palette: "Palette"
        case .sidebar: "Macs Sidebar"
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultStyle
    }
}

// MARK: - Recency

/// When each project (by project location key: a local path or a
/// `device:` key) was last opened or brought to the front. The app's
/// project windows mark it (`ProjectWindowRegistry.projectRecency`, set at
/// launch; tests give their own UserDefaults and never touch the real one).
@MainActor
final class ProjectRecencyStore: ObservableObject {
    static let shared = ProjectRecencyStore(defaults: .standard)
    static let defaultsKey = "projectSwitcher.lastOpened.v1"
    /// The most keys kept (the oldest go first).
    static let capacity = 200

    @Published private(set) var dates: [String: Date]
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String = ProjectRecencyStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        dates = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func lastOpened(_ projectKey: String) -> Date? {
        dates[projectKey]
    }

    func markOpened(_ projectKey: String, at date: Date = Date()) {
        guard !projectKey.isEmpty else { return }
        // Focus changes between windows mark often: a key that is already
        // the most recent, marked within the last few seconds, is left be.
        if let existing = dates[projectKey],
           abs(date.timeIntervalSince(existing)) < 5,
           dates.values.allSatisfy({ $0 <= existing }) {
            return
        }
        var next = dates
        next[projectKey] = date
        if next.count > Self.capacity {
            let keep = next.sorted { $0.value > $1.value }.prefix(Self.capacity)
            next = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        dates = next
        defaults.set(next.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    /// Keys, most recent first.
    func recentKeys(limit: Int) -> [String] {
        dates.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}

// MARK: - Model

struct ProjectSwitcherModel: Equatable {
    enum Machine: Hashable {
        case thisMac
        case device(UUID)

        var deviceID: UUID? {
            if case .device(let id) = self { return id }
            return nil
        }
    }

    /// A Mac the switcher lists (a filter chip, a rail row).
    struct MachineInfo: Equatable, Identifiable {
        var machine: Machine
        var name: String
        /// "Connected · 2 sessions", "Offline", "14 sessions".
        var status: String
        var dot: RemoteDeviceConnectionState.Dot
        /// Its host's sessions, when known.
        var sessionCount: Int?
        /// The sidebar header's second line.
        var detail: String
        /// Answers now (or is This Mac): an unreachable Mac is greyed and
        /// the sidebar shows why.
        var isReachable: Bool = true
        /// Its projects can be opened (never while another identity or
        /// protocol answers there).
        var allowsOpening: Bool = true
        /// The sidebar's banner for a Mac that does not answer.
        var unreachableMessage: String?
        var offersTrustNewIdentity: Bool = false
        /// An SF Symbol for the rail.
        var symbol: String = "desktopcomputer"

        var id: Machine { machine }
    }

    /// What an open project window holds.
    struct OpenStatus: Equatable {
        var tabs: Int
        var workingAgents: Int

        var text: String {
            let tabsText = tabs == 1 ? "1 tab" : "\(tabs) tabs"
            guard workingAgents > 0 else { return tabsText }
            let agents = workingAgents == 1 ? "1 agent working" : "\(workingAgents) agents working"
            return "\(agents) · \(tabsText)"
        }
    }

    /// A project on one Mac.
    struct Location: Equatable, Identifiable {
        var machine: Machine
        /// Its project location key (a local path, or a `device:` key).
        var key: String
        var name: String
        /// Its folder on that Mac.
        var path: String
        /// `path` as shown (`~` for the home folder there).
        var displayPath: String
        /// Set when a window of it is open.
        var openStatus: OpenStatus?
        /// The window this switcher was opened from shows it.
        var isCurrent = false
        var lastOpened: Date?
        /// Sessions whose project it is (a device's, as its host listed).
        var sessionCount = 0

        var id: String { key }
        var isOpen: Bool { openStatus != nil }
    }

    /// One project, on each Mac that has it (matched by name).
    struct Group: Equatable, Identifiable {
        var id: String
        var name: String
        /// The primary location first: the one ↵ opens.
        var locations: [Location]

        var primary: Location { locations[0] }
        var openLocation: Location? { locations.first(where: \.isOpen) }
        var isOpen: Bool { openLocation != nil }
        var isCurrent: Bool { locations.contains(where: \.isCurrent) }
        var lastOpened: Date? { locations.compactMap(\.lastOpened).max() }
    }

    enum SectionKind: String, Equatable {
        case open, recent, all, results

        var title: String {
            switch self {
            case .open: "Open"
            case .recent: "Recent"
            case .all: "All Projects"
            case .results: "Results"
            }
        }
    }

    struct Section: Equatable, Identifiable {
        var kind: SectionKind
        var groups: [Group]

        var id: String { kind.rawValue }
        var title: String { kind.title }
    }

    static let recentLimit = 5

    /// This Mac first, then each device.
    var machines: [MachineInfo]
    var locations: [Location]
    /// The Mac of the window the switcher opened from.
    var currentMachine: Machine = .thisMac

    init(machines: [MachineInfo], locations: [Location], currentMachine: Machine = .thisMac) {
        self.machines = machines
        self.locations = locations
        self.currentMachine = currentMachine
    }

    func machine(_ machine: Machine) -> MachineInfo? {
        machines.first { $0.machine == machine }
    }

    func name(of machine: Machine) -> String {
        self.machine(machine)?.name ?? "This Mac"
    }

    func canOpen(_ location: Location) -> Bool {
        machine(location.machine)?.allowsOpening ?? false
    }

    func isReachable(_ machine: Machine) -> Bool {
        self.machine(machine)?.isReachable ?? false
    }

    func projectCount(on machine: Machine) -> Int {
        locations.filter { $0.machine == machine }.count
    }

    // MARK: Grouping

    /// The projects, one group per name, each Mac at most once in a group
    /// (two folders of one name on one Mac stay apart). `filter`: only that
    /// Mac's projects (nil: every Mac's).
    func groups(filter: Machine? = nil) -> [Group] {
        let order = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($1.machine, $0) })
        let candidates = locations
            .filter { filter == nil || $0.machine == filter }
            .sorted { lhs, rhs in
                let lhsOrder = order[lhs.machine] ?? .max
                let rhsOrder = order[rhs.machine] ?? .max
                return lhsOrder == rhsOrder ? lhs.path < rhs.path : lhsOrder < rhsOrder
            }
        var groups: [Group] = []
        var indexesByName: [String: [Int]] = [:]
        for location in candidates {
            let name = Self.fold(location.name)
            if let index = indexesByName[name]?.first(where: { index in
                !groups[index].locations.contains { $0.machine == location.machine }
            }) {
                groups[index].locations.append(location)
            } else {
                let suffix = indexesByName[name].map { "#\($0.count)" } ?? ""
                indexesByName[name, default: []].append(groups.count)
                groups.append(Group(id: name + suffix, name: location.name, locations: [location]))
            }
        }
        return groups.map { group in
            var group = group
            group.locations.sort { primaryOrder($0, $1, order: order) }
            return group
        }
    }

    /// The primary location of a group: the current window's, then an open
    /// one, then one on a Mac that answers, then the most recently opened,
    /// then This Mac's (the Macs' order).
    private func primaryOrder(_ lhs: Location, _ rhs: Location, order: [Machine: Int]) -> Bool {
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
        let lhsReachable = isReachable(lhs.machine) && canOpen(lhs)
        let rhsReachable = isReachable(rhs.machine) && canOpen(rhs)
        if lhsReachable != rhsReachable { return lhsReachable }
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (order[lhs.machine] ?? .max) < (order[rhs.machine] ?? .max)
        }
    }

    // MARK: Sections

    /// With no query: Open (current first, then most recent), Recent (the
    /// five most recently opened of the rest) and All Projects
    /// (alphabetical). With one: Results, ranked name prefix > name
    /// contains > path contains, then the most recent, then by name.
    func sections(query: String, filter: Machine? = nil) -> [Section] {
        let groups = groups(filter: filter)
        let query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if !query.isEmpty {
            let scored = groups.compactMap { group -> (Group, Int)? in
                let score = Self.score(group, query: query)
                return score > 0 ? (group, score) : nil
            }
            let results = scored.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return Self.recentFirst(lhs.0, rhs.0)
            }.map(\.0)
            return results.isEmpty ? [] : [Section(kind: .results, groups: results)]
        }
        let open = groups.filter(\.isOpen).sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return Self.recentFirst(lhs, rhs)
        }
        let recent = Array(groups
            .filter { !$0.isOpen && $0.lastOpened != nil }
            .sorted(by: Self.recentFirst)
            .prefix(Self.recentLimit))
        let listed = Set((open + recent).map(\.id))
        let all = groups.filter { !listed.contains($0.id) }.sorted(by: Self.alphabetical)
        return [
            Section(kind: .open, groups: open),
            Section(kind: .recent, groups: recent),
            Section(kind: .all, groups: all),
        ].filter { !$0.groups.isEmpty }
    }

    /// 3: the name starts with the query; 2: the name contains it; 1: a
    /// folder's path contains it; 0: no match.
    static func score(_ group: Group, query: String) -> Int {
        let name = fold(group.name)
        if name.hasPrefix(query) { return 3 }
        if name.contains(query) { return 2 }
        let pathMatches = group.locations.contains {
            fold($0.path).contains(query) || fold($0.displayPath).contains(query)
        }
        return pathMatches ? 1 : 0
    }

    private static func recentFirst(_ lhs: Group, _ rhs: Group) -> Bool {
        switch (lhs.lastOpened, rhs.lastOpened) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return alphabetical(lhs, rhs)
        }
    }

    private static func alphabetical(_ lhs: Group, _ rhs: Group) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Keys

    /// The Mac filter after (or before) `current`: All Macs, This Mac, then
    /// each device, round.
    func nextFilter(after current: Machine?, backwards: Bool = false) -> Machine? {
        let cycle: [Machine?] = [nil] + machines.map(\.machine)
        let index = cycle.firstIndex(of: current) ?? 0
        let step = backwards ? cycle.count - 1 : 1
        return cycle[(index + step) % cycle.count]
    }

    /// The sidebar's next Mac (no All Macs there).
    func nextMachine(after current: Machine, backwards: Bool = false) -> Machine {
        let cycle = machines.map(\.machine)
        guard !cycle.isEmpty else { return current }
        let index = cycle.firstIndex(of: current) ?? 0
        let step = backwards ? cycle.count - 1 : 1
        return cycle[(index + step) % cycle.count]
    }

    // MARK: Opening

    /// What opening a location does, through the picker's own actions (so
    /// a device's project, window reuse and worktrees work as from the
    /// menu). Nil when its Mac does not allow opening now.
    func action(opening location: Location) -> TitlebarProjectMenuModel.Action? {
        guard canOpen(location) else { return nil }
        switch location.machine {
        case .thisMac: return .openProject(location.key)
        case .device(let id): return .openDeviceProject(deviceID: id, path: location.path)
        }
    }

    /// Whether "Open “<query>” as a folder…" is offered: the query looks
    /// like a path (`/…`, `~`, `~/…`).
    static func looksLikePath(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.hasPrefix("/") || query == "~" || query.hasPrefix("~/")
    }

    /// The folder a path-like query names on a Mac whose home is `home`
    /// (nil: unknown, so `~` cannot be expanded there).
    static func expandedPath(_ query: String, home: String?) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikePath(query) else { return nil }
        guard query.hasPrefix("~") else { return query }
        guard let home else { return nil }
        let rest = query.dropFirst()
        return rest.isEmpty ? home : (home as NSString).appendingPathComponent(String(rest.dropFirst()))
    }

    /// `path` with the home folder there as `~`.
    static func displayPath(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }

    /// "5 min ago", "3 h ago", "yesterday", "4 days ago".
    static func agoLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<(60 * 24): return "\(minutes / 60) h ago"
        case ..<(60 * 48): return "yesterday"
        default: return "\(minutes / 1_440) days ago"
        }
    }
}

// MARK: - Building from the app's state

extension ProjectSwitcherModel {
    struct LocalProject: Equatable {
        var root: String
        var name: String
    }

    /// Builds the model from what the picker's menu already gathers.
    /// - `localProjects`: This Mac's projects (the settings' list, then any
    ///   other open or recently opened local folder).
    /// - `devices`: each device, its state and its host's sessions as last
    ///   listed (`TitlebarProjectMenuModel.Device`).
    /// - `openWindows`: each open project window by its key (canonical, as
    ///   `canonicalKey` gives it) with what it holds.
    /// - `recency`: last opened, by key.
    static func make(
        localProjects: [LocalProject],
        devices: [TitlebarProjectMenuModel.Device],
        openWindows: [String: OpenStatus],
        recency: [String: Date],
        currentProjectKey: String?,
        thisMac: MachineInfo,
        canonicalKey: (String) -> String = { $0 },
        localHome: String? = NSHomeDirectory(),
        now: Date = Date()
    ) -> ProjectSwitcherModel {
        let currentKey = currentProjectKey.map(canonicalKey)
        var machines = [thisMac]
        var locations: [Location] = []
        var seenLocalKeys = Set<String>()
        for project in localProjects {
            let key = canonicalKey(project.root)
            guard seenLocalKeys.insert(key).inserted else { continue }
            locations.append(Location(
                machine: .thisMac,
                key: project.root,
                name: project.name,
                path: project.root,
                displayPath: displayPath(project.root, home: localHome),
                openStatus: openWindows[key],
                isCurrent: key == currentKey,
                lastOpened: recency[project.root] ?? recency[key]
            ))
        }
        var currentMachine: Machine = .thisMac
        for entry in devices {
            let device = entry.device
            let machine = Machine.device(device.id)
            if let currentKey, ProjectLocation(key: currentKey).deviceID == device.id {
                currentMachine = machine
            }
            let (projects, _) = RemoteDeviceDiscovery.projects(
                sessions: entry.sessions, added: device.addedProjects, hidden: device.hiddenProjects
            )
            var paths = Set<String>()
            for project in projects {
                paths.insert(project.path)
                let key = device.projectKey(path: project.path)
                locations.append(Location(
                    machine: machine,
                    key: key,
                    name: project.name,
                    path: project.path,
                    displayPath: displayPath(project.path, home: device.homeDirectory),
                    openStatus: openWindows[canonicalKey(key)],
                    isCurrent: canonicalKey(key) == currentKey,
                    lastOpened: recency[key],
                    sessionCount: project.sessionCount
                ))
            }
            // A window of a folder its host does not list (its home, a
            // project whose sessions all ended) is still one of its projects.
            for (key, status) in openWindows where ProjectLocation(key: key).deviceID == device.id {
                let path = ProjectLocation(key: key).path
                guard paths.insert(path).inserted else { continue }
                let name = RemoteDeviceProject(path: path, sessionCount: 0, isAdded: false).name
                locations.append(Location(
                    machine: machine,
                    key: key,
                    name: name,
                    path: path,
                    displayPath: displayPath(path, home: device.homeDirectory),
                    openStatus: status,
                    isCurrent: key == currentKey,
                    lastOpened: recency[key]
                ))
            }
            machines.append(machineInfo(for: entry, projectCount: paths.count, now: now))
        }
        return ProjectSwitcherModel(machines: machines, locations: locations, currentMachine: currentMachine)
    }

    static func machineInfo(for entry: TitlebarProjectMenuModel.Device, projectCount: Int, now: Date) -> MachineInfo {
        let device = entry.device
        let state = entry.state
        let sessionCount: Int? = switch state {
        case .connected(let count), .reachable(let count): count
        default: nil
        }
        let isReachable: Bool = switch state {
        case .connected, .reachable, .connecting, .notRunning, .unknown: true
        case .offline, .identityChanged, .loginRefused, .incompatible, .hostMissing: false
        }
        var detailParts = ["\(device.sshDestination) over SSH"]
        if let build = device.installedBuild { detailParts.append("session host \(build)") }
        detailParts.append(projectCount == 1 ? "1 project" : "\(projectCount) projects")
        var message: String?
        if !isReachable {
            let lastSeen = device.lastSeen.map { " (last seen \(RemoteDeviceConnectionState.relative($0, now: now)))" } ?? ""
            switch state {
            case .offline:
                message = "\(device.name) isn't reachable\(lastSeen). Its projects open once it's back; its tabs wait for it."
            default:
                message = state.detail
            }
        }
        return MachineInfo(
            machine: .device(device.id),
            name: device.name,
            status: state.subtitle(now: now),
            dot: state.dot,
            sessionCount: sessionCount,
            detail: detailParts.joined(separator: " · "),
            isReachable: isReachable,
            allowsOpening: state.allowsOpening,
            unreachableMessage: message,
            offersTrustNewIdentity: state.offersTrustNewIdentity,
            symbol: "desktopcomputer"
        )
    }

    /// This Mac's chip and rail row.
    static func thisMacInfo(computerName: String?, sessionCount: Int?, projectCount: Int, symbol: String) -> MachineInfo {
        let sessions = sessionCount.map { $0 == 1 ? "1 session" : "\($0) sessions" }
        var detail: [String] = []
        if let computerName, !computerName.isEmpty { detail.append(computerName) }
        detail.append(projectCount == 1 ? "1 project" : "\(projectCount) projects")
        if let sessionCount { detail.append(sessionCount == 1 ? "1 session running" : "\(sessionCount) sessions running") }
        return MachineInfo(
            machine: .thisMac,
            name: "This Mac",
            status: sessions ?? "Local",
            dot: .green,
            sessionCount: sessionCount,
            detail: detail.joined(separator: " · "),
            symbol: symbol
        )
    }
}
