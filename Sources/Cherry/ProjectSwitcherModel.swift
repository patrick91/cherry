import CherryControl
import Foundation

// The projects on every Mac, the Macs and the open windows, as the Omni
// bar lists them (`OmniProviders`) and opens them
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

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
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
        defaults.set(next.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
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

        /// The Mac of a project location key (This Mac for a local path, or
        /// for none).
        init(projectKey: String?) {
            self = projectKey.flatMap { ProjectLocation(key: $0).deviceID }.map { Self.device($0) } ?? .thisMac
        }

        var deviceID: UUID? {
            if case .device(let id) = self { return id }
            return nil
        }
    }

    /// A Mac the Omni bar lists.
    struct MachineInfo: Equatable, Identifiable {
        var machine: Machine
        var name: String
        var dot: RemoteDeviceConnectionState.Dot
        /// Its host's sessions, when known.
        var sessionCount: Int?
        /// Answers now (or is This Mac): an unreachable Mac's row is
        /// Offline.
        var isReachable: Bool = true
        /// Its projects can be opened (never while another identity or
        /// protocol answers there).
        var allowsOpening: Bool = true
        /// An SF Symbol for its row.
        var symbol: String = "desktopcomputer"

        var id: Machine { machine }
    }

    /// What an open project window holds.
    struct OpenStatus: Equatable {
        var workingAgents: Int
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

        var id: String { key }
        var isOpen: Bool { openStatus != nil }
    }

    /// How many projects Projects › Recent lists.
    static let recentLimit = 5

    /// This Mac first, then each device.
    var machines: [MachineInfo]
    var locations: [Location]

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

    // MARK: Opening

    /// What opening a location does, through `ProjectSwitcherActions` (so
    /// a device's project and window reuse work as from any other row).
    /// Nil when its Mac does not allow opening now.
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

    /// Builds the model from cached state.
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
        localHome: String? = NSHomeDirectory()
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
        for entry in devices {
            let device = entry.device
            let machine = Machine.device(device.id)
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
                    lastOpened: recency[key]
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
            machines.append(machineInfo(for: entry))
        }
        return ProjectSwitcherModel(machines: machines, locations: locations)
    }

    static func machineInfo(for entry: TitlebarProjectMenuModel.Device) -> MachineInfo {
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
        return MachineInfo(
            machine: .device(device.id),
            name: device.name,
            dot: state.dot,
            sessionCount: sessionCount,
            isReachable: isReachable,
            allowsOpening: state.allowsOpening,
            symbol: "desktopcomputer"
        )
    }

    /// This Mac's row.
    static func thisMacInfo(sessionCount: Int?, symbol: String) -> MachineInfo {
        MachineInfo(machine: .thisMac, name: "This Mac", dot: .green, sessionCount: sessionCount, symbol: symbol)
    }
}
