import AppKit
import CherryControl
import Combine
import Foundation
import IOKit.ps
import SystemConfiguration

extension TitlebarProjectMenuModel {
    /// Each device and what is known of it now, from cached state: its
    /// control's sessions while connected, else what a look that starts
    /// nothing found (`RemoteDevicePeeks`). Never connects.
    @MainActor
    static func liveDevices(
        store: RemoteDeviceStore = .shared,
        controls: HostControlRegistry = .shared,
        peeks: RemoteDevicePeeks = .shared
    ) -> [Device] {
        let devices = store.devices.map { device -> Device in
            guard let host = device.host else {
                return .init(device: device, state: .offline(reason: "Its SSH destination is not valid."), sessions: [])
            }
            let control = controls.control(for: host)
            if control.state == .connected { store.noteSeen(device.id) }
            // Not connected: what a look that starts nothing found.
            let peek = control.state == .connected ? nil : peeks.result(for: host)
            let peeked = control.state == .connected ? nil : peeks.list(for: host)
            return .init(
                device: device,
                state: RemoteDeviceConnectionState(
                    control: control.state, sessionCount: control.sessions.count, lastSeen: device.lastSeen, peek: peek
                ),
                sessions: peeked?.sessions ?? control.sessions,
                bundledBuild: RemoteHostHelpers.cachedAppBuild
            )
        }
        // Read once in the background: the next menu offers Update Session
        // Host… for a device whose install is older.
        if !store.devices.isEmpty { RemoteHostHelpers.preloadApp() }
        return devices
    }
}

/// The palette's and the sidebar's model, kept current while one is shown:
/// on start every device's host is listed as the menu does (a connected
/// one over its connection, any other with a look that never starts or
/// replaces its daemon), and the model is rebuilt as they answer and, once
/// a second, for the open windows' tabs and agents.
@MainActor
final class ProjectSwitcherLiveModel: ObservableObject {
    @Published private(set) var model: ProjectSwitcherModel

    private let currentProjectKey: @MainActor () -> String?
    private let peeks: RemoteDevicePeeks
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?

    init(currentProjectKey: @escaping @MainActor () -> String?, peeks: RemoteDevicePeeks = .shared) {
        self.currentProjectKey = currentProjectKey
        self.peeks = peeks
        model = Self.build(currentProjectKey: currentProjectKey())
    }

    func rebuild() {
        let next = Self.build(currentProjectKey: currentProjectKey())
        if next != model { model = next }
    }

    func start() {
        stop()
        rebuild()
        subscriptions.append(peeks.$entries.dropFirst().debounce(for: .milliseconds(50), scheduler: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        subscriptions.append(ProjectRecencyStore.shared.$dates.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        })
        let controls = RemoteDeviceStore.shared.devices.compactMap { $0.host.map { HostControlRegistry.shared.control(for: $0) } }
        for control in controls {
            let changes = control.$state.map { _ in () }
                .merge(with: control.$sessions.map { _ in () })
                .dropFirst(2)
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            subscriptions.append(changes.sink { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            })
            if control.state == .connected {
                Task { _ = try? await control.list() }
            } else if TitlebarProjectMenuController.refreshesOnOpen(control.state) {
                let peeks = peeks
                Task { await peeks.refresh(control) }
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        subscriptions.removeAll()
        timer?.invalidate()
        timer = nil
    }

    /// The model from the app's state now.
    static func build(currentProjectKey: String?) -> ProjectSwitcherModel {
        let registry = ProjectWindowRegistry.shared
        let settings = AgentSettings.shared
        let recency = ProjectRecencyStore.shared
        let openWindows = registry.openProjectWindowStatuses()
        var localProjects = settings.projects
            .filter { !ProjectLocation.isRemoteKey($0.root) }
            .map { ProjectSwitcherModel.LocalProject(root: $0.root, name: $0.name) }
        // Open windows and recently opened folders that are not in the list
        // (Open Folder…) are This Mac's projects too.
        let listed = Set(localProjects.map(\.root))
        var extras = openWindows.keys.filter { !ProjectLocation.isRemoteKey($0) && !listed.contains($0) }
        for key in recency.recentKeys(limit: 30)
            where !ProjectLocation.isRemoteKey(key) && !listed.contains(key) && !extras.contains(key) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: key, isDirectory: &isDirectory), isDirectory.boolValue {
                extras.append(key)
            }
        }
        localProjects += extras.sorted().map { .init(root: $0, name: CherryProject(root: $0).name) }

        let localControl = HostControlRegistry.shared.all.first { $0.host.id == HostedSessionHost.local.id }
        let localSessions = localControl?.state == .connected ? localControl?.sessions.count : nil
        let thisMac = ProjectSwitcherModel.thisMacInfo(
            computerName: Self.computerName,
            sessionCount: localSessions,
            projectCount: localProjects.count,
            symbol: Self.thisMacSymbol
        )
        var canonical: [String: String] = [:]
        return ProjectSwitcherModel.make(
            localProjects: localProjects,
            devices: TitlebarProjectMenuModel.liveDevices(),
            openWindows: openWindows,
            recency: recency.dates,
            currentProjectKey: currentProjectKey,
            thisMac: thisMac,
            canonicalKey: { key in
                if let known = canonical[key] { return known }
                let value = registry.canonicalProjectRoot(for: key)
                canonical[key] = value
                return value
            }
        )
    }

    private static let computerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    /// A laptop's glyph for a Mac with a built-in battery, else a desktop's.
    private static let thisMacSymbol: String = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return "desktopcomputer" }
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return hasBattery ? "laptopcomputer" : "desktopcomputer"
    }()
}

/// What the picker's items, the palette and the sidebar do: the same code
/// path for each (a device's project opens through its key, window reuse
/// through `openProject`). Worktree actions stay the picker's.
@MainActor
struct ProjectSwitcherActions {
    let settings: AgentSettings
    let chromeState: ProjectWindowChromeState
    let openProject: (CherryProject) -> Void
    let openSettings: () -> Void

    /// Handles every action but the worktree ones (false for those).
    @discardableResult
    func perform(_ action: TitlebarProjectMenuModel.Action) -> Bool {
        let store = RemoteDeviceStore.shared
        switch action {
        case .activateWorktree, .newWorktree, .manageWorktrees:
            return false
        case .openProject(let root):
            openProject(settings.projects.first(where: { $0.root == root }) ?? CherryProject(root: root))
        case .addProject:
            chooseProjectRoot()
        case .editProjects:
            openSettings()
        case .openDeviceProject(let deviceID, let path):
            openProject(CherryProject(root: ProjectLocation.remote(deviceID: deviceID, path: path).key))
        case .openDeviceHome(let deviceID):
            guard let home = store.device(id: deviceID)?.homeDirectory else { return true }
            openProject(CherryProject(root: ProjectLocation.remote(deviceID: deviceID, path: home).key))
        case .openDeviceSessions(let deviceID):
            guard let host = store.device(id: deviceID)?.host else { return true }
            chromeState.hostedSessionsInitialHost = host
            chromeState.isHostedSessionsPresented = true
        case .addDeviceProject(let deviceID):
            chromeState.addProjectDevice = RemoteDeviceReference(id: deviceID)
        case .hideDeviceProject(let deviceID, let path):
            store.hideProject(path: path, on: deviceID)
        case .reconnectDevice(let deviceID):
            guard let host = store.device(id: deviceID)?.host else { return true }
            RemoteDevicePeeks.shared.retry(host)
            let control = HostControlRegistry.shared.control(for: host)
            if case .waitingToReconnect = control.state {
                control.reconnectNow()
            } else {
                Task { _ = try? await control.connect(retryingLoginEnvironment: true) }
            }
        case .trustDeviceIdentity(let deviceID):
            RemoteDeviceAlerts.confirmTrustNewIdentity(of: deviceID, store: store)
        case .updateDeviceHost(let deviceID):
            RemoteDeviceUpdatePresenter.present(deviceID: deviceID, store: store)
        case .setUpDeviceMCP(let deviceID):
            RemoteMCPSetupPresenter.present(deviceID: deviceID, store: store)
        case .renameDevice(let deviceID):
            RemoteDeviceAlerts.rename(deviceID, store: store)
        case .removeDevice(let deviceID):
            RemoteDeviceAlerts.confirmRemove(deviceID, store: store)
        case .addMac:
            chromeState.isAddDevicePresented = true
        }
        return true
    }

    /// Add Project…: a folder on This Mac, added to the list and opened;
    /// on a device, Add Project on <Mac>… (a path checked there).
    func addProject(on machine: ProjectSwitcherModel.Machine) {
        switch machine {
        case .thisMac: chooseProjectRoot()
        case .device(let id): perform(.addDeviceProject(id))
        }
    }

    /// Open Folder…: a folder on This Mac, opened without adding it; on a
    /// device, Add Project on <Mac>… (there is no remote folder browser).
    func openFolder(on machine: ProjectSwitcherModel.Machine) {
        switch machine {
        case .thisMac:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Open"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            openProject(CherryProject(root: url.path))
        case .device(let id):
            perform(.addDeviceProject(id))
        }
    }

    /// "Open “<query>” as a folder…": false when the query names no folder
    /// that can be opened (a missing one on This Mac, `~` on a device whose
    /// home is unknown).
    @discardableResult
    func openPath(_ query: String, on machine: ProjectSwitcherModel.Machine) -> Bool {
        switch machine {
        case .thisMac:
            guard let path = ProjectSwitcherModel.expandedPath(query, home: NSHomeDirectory()) else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
            openProject(CherryProject(root: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path))
        case .device(let id):
            let home = RemoteDeviceStore.shared.device(id: id)?.homeDirectory
            guard let path = ProjectSwitcherModel.expandedPath(query, home: home) else { return false }
            perform(.openDeviceProject(deviceID: id, path: path))
        }
        return true
    }

    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.addProject(path: url.path)
        if let project = settings.selectedProject(for: url.path) {
            openProject(project)
        }
    }
}
