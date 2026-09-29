import CherryControl
import Foundation

// The projects on every Mac, the Macs and the open windows, as the Omni
// bar lists them (`OmniProviders`) and the picker menu opens them
// (`ProjectSwitcherActions`). `ProjectSwitcherModel` is pure: tests give it
// projects, devices, open windows and recency.

// MARK: - Recency

/// When each project (by project location key: a local path or a
/// `device:` key) was last opened or brought to the front: the Omni bar's
/// Projects › Recent and part of its frecency (`OmniFrecencyStore`). The
/// app's project windows mark it (`ProjectWindowRegistry.projectRecency`,
/// set at launch; tests give their own UserDefaults and never touch the
/// real one).
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

    /// A Mac the Omni bar lists.
    struct MachineInfo: Equatable, Identifiable {
        var machine: Machine
        var name: String
        /// "Connected · 2 sessions", "Offline", "14 sessions".
        var status: String
        var dot: RemoteDeviceConnectionState.Dot
        /// Its host's sessions, when known.
        var sessionCount: Int?
        /// "<destination> over SSH · session host <build> · N projects".
        var detail: String
        /// Answers now (or is This Mac): an unreachable Mac's row is
        /// Offline.
        var isReachable: Bool = true
        /// Its projects can be opened (never while another identity or
        /// protocol answers there).
        var allowsOpening: Bool = true
        /// Why a Mac does not answer.
        var unreachableMessage: String?
        var offersTrustNewIdentity: Bool = false
        /// An SF Symbol for its row.
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
        /// The window the bar was opened from shows it.
        var isCurrent = false
        var lastOpened: Date?
        /// Sessions whose project it is (a device's, as its host listed).
        var sessionCount = 0

        var id: String { key }
        var isOpen: Bool { openStatus != nil }
    }

    /// How many projects Projects › Recent lists.
    static let recentLimit = 5

    /// This Mac first, then each device.
    var machines: [MachineInfo]
    var locations: [Location]
    /// The Mac of the window the bar opened from.
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

    /// This Mac's row.
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
