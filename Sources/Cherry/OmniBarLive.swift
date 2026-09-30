import AppKit
import CherryControl
import Combine
import Foundation

// The Omni bar's live side: its frecency, what it lists gathered from the
// app's cached state (never connecting to a host or starting a daemon to
// find out), and what its rows do, through the code paths the menus, the
// picker and the sidebar already use.

// MARK: - Frecency

/// How often, and how lately, each Omni bar row was used, by row id
/// ("project:<key>", "tab:<uuid>", "command:<id>", "agent:<id>"…). One
/// store for every kind: it takes over the command palette's usage
/// (`commandPalette.usage.v1`, whose ids the bar keeps) the first time it
/// loads, and its project scores also count when a project's window was
/// last brought to the front (`ProjectRecencyStore`).
@MainActor
final class OmniFrecencyStore: ObservableObject {
    struct Entry: Codable, Equatable {
        var selectionCount: Int
        var lastSelectedAt: Date
    }

    static let shared = OmniFrecencyStore()
    static let storageKey = "omniBar.frecency.v1"
    static let legacyStorageKey = "commandPalette.usage.v1"
    static let capacity = 300

    @Published private(set) var entries: [String: Entry]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = OmniFrecencyStore.storageKey,
        legacyStorageKey: String? = OmniFrecencyStore.legacyStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else if let legacyStorageKey,
                  let data = defaults.data(forKey: legacyStorageKey),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
            persist()
        } else {
            entries = [:]
        }
    }

    func recordUse(id: String, at date: Date = Date()) {
        guard !id.isEmpty else { return }
        var entry = entries[id] ?? Entry(selectionCount: 0, lastSelectedAt: date)
        entry.selectionCount = min(entry.selectionCount + 1, 10_000)
        entry.lastSelectedAt = date
        entries[id] = entry
        if entries.count > Self.capacity {
            let retained = entries.sorted { $0.value.lastSelectedAt > $1.value.lastSelectedAt }.prefix(Self.capacity)
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        persist()
    }

    /// Each row's frecency, 0 to 200: up to 120 for how often it was used
    /// (logarithmic) and up to 80 for how lately it was used or, for a
    /// project, its window was brought to the front (`projectRecency`, by
    /// project key).
    func scores(at date: Date = Date(), projectRecency: [String: Date] = [:]) -> [String: Double] {
        var scores: [String: Double] = [:]
        for (id, entry) in entries {
            scores[id] = Self.frequencyPoints(entry.selectionCount) + Self.recencyPoints(entry.lastSelectedAt, now: date)
        }
        for (key, opened) in projectRecency {
            let id = "project:\(key)"
            let frequency = entries[id].map { Self.frequencyPoints($0.selectionCount) } ?? 0
            let recency = max(entries[id].map { Self.recencyPoints($0.lastSelectedAt, now: date) } ?? 0, Self.recencyPoints(opened, now: date))
            scores[id] = frequency + recency
        }
        return scores
    }

    static func frequencyPoints(_ count: Int) -> Double {
        min(120, (log2(Double(count) + 1) * 28).rounded(.down))
    }

    static func recencyPoints(_ last: Date, now: Date) -> Double {
        switch max(0, now.timeIntervalSince(last)) {
        case ..<3_600: 80
        case ..<86_400: 60
        case ..<604_800: 35
        case ..<2_592_000: 15
        default: 0
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Keeping the bar current

/// Keeps an open bar's rows current: gathers its sources when it opens,
/// looks at every device's host as the picker menu does (a connected one
/// over its connection, any other with a look that never starts or
/// replaces its daemon, `RemoteDevicePeeks`), and gathers again as they
/// answer and once a second (tabs, agents, background sessions). It never
/// connects to a host that is not connected, nor starts one.
@MainActor
final class OmniBarLiveModel: ObservableObject {
    let controller: OmniBarController
    private let gather: @MainActor () -> OmniSources
    private let frecency: @MainActor () -> [String: Double]
    private let controls: @MainActor () -> [HostControl]
    private let peeks: RemoteDevicePeeks
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?

    init(
        controller: OmniBarController,
        gather: @escaping @MainActor () -> OmniSources,
        frecency: @escaping @MainActor () -> [String: Double],
        controls: @escaping @MainActor () -> [HostControl] = OmniBarLiveModel.deviceControls,
        peeks: RemoteDevicePeeks = .shared
    ) {
        self.controller = controller
        self.gather = gather
        self.frecency = frecency
        self.controls = controls
        self.peeks = peeks
    }

    /// The app's: the window's sources and the shared frecency.
    static func make(for window: OmniBarWindow, at scope: OmniScope?) -> OmniBarLiveModel {
        let controller = OmniBarController()
        controller.open(at: scope)
        return OmniBarLiveModel(
            controller: controller,
            gather: { OmniBarGathering.sources(for: window) },
            frecency: { OmniFrecencyStore.shared.scores(projectRecency: ProjectRecencyStore.shared.dates) }
        )
    }

    /// The devices' controls (the registry makes one without connecting).
    static func deviceControls() -> [HostControl] {
        RemoteDeviceStore.shared.devices.compactMap { $0.host.map { HostControlRegistry.shared.control(for: $0) } }
    }

    func refresh() {
        controller.update(sources: gather(), frecency: frecency())
    }

    func start() {
        stop()
        refresh()
        subscriptions.append(peeks.$entries.dropFirst().debounce(for: .milliseconds(50), scheduler: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        let controls = controls()
        for control in controls {
            let changes = control.$state.map { _ in () }
                .merge(with: control.$sessions.map { _ in () })
                .dropFirst(2)
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            subscriptions.append(changes.sink { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        Self.lookAtHosts(controls, peeks: peeks)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        subscriptions.removeAll()
        timer?.invalidate()
        timer = nil
    }

    /// Lists each host again: a connected one over its connection, any
    /// other with a look that starts nothing there (throttled; never after
    /// a refused login, another identity or protocol,
    /// `RemoteDevicePeeks.refreshesOnOpen`).
    static func lookAtHosts(_ controls: [HostControl], peeks: RemoteDevicePeeks) {
        for control in controls {
            if control.state == .connected {
                Task { _ = try? await control.list() }
            } else if RemoteDevicePeeks.refreshesOnOpen(control.state) {
                Task { await peeks.refresh(control) }
            }
        }
    }
}

// MARK: - Gathering

/// Where the bar was opened: its window's state.
@MainActor
struct OmniBarWindow {
    let projectRoot: String?
    let repository: RepositoryWorkspace
    let workspace: TerminalWorkspace
    let chromeState: ProjectWindowChromeState
}

@MainActor
enum OmniBarGathering {
    /// What the bar lists now, from cached state.
    static func sources(
        for window: OmniBarWindow,
        registry: ProjectWindowRegistry = .shared,
        settings: AgentSettings = .shared,
        terminalSettings: TerminalSettings = .shared,
        editorDiscovery: ExternalEditorDiscovery = .shared,
        backgroundSessions: BackgroundSessionsModel = .shared,
        deviceStore: RemoteDeviceStore = .shared
    ) -> OmniSources {
        let devices = TitlebarProjectMenuModel.liveDevices(store: deviceStore)
        let projects = ProjectSwitcherLive.build(currentProjectKey: window.repository.repositoryRoot, devices: devices)
        var sources = OmniSources()
        sources.projects = projects
        sources.devices = devices
        sources.canModifyDevices = deviceStore.canModify
        // Minutes: a finer clock would change the sources every second.
        sources.now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)

        sources.tabs = tabs(registry: registry, current: window.workspace) { machine in
            switch machine {
            case .thisMac: NSHomeDirectory()
            case .device(let id): deviceStore.device(id: id)?.homeDirectory
            }
        }
        sources.backgroundSessions = background(backgroundSessions)

        let repository = window.repository
        sources.repositoryName = repository.repositoryName
        if repository.supportsWorktrees {
            sources.worktrees = repository.worktrees.map { worktree in
                OmniWorktree(
                    root: worktree.root,
                    name: worktree.displayName,
                    branch: worktree.branch,
                    isActive: worktree.root == repository.activeWorktreeRoot,
                    canRename: repository.canRename(worktree),
                    canRemove: repository.canRemove(worktree)
                )
            }
        }
        sources.window = context(for: window, settings: settings)

        sources.listedLocalProjects = Set(settings.projects.map(\.root).filter { !ProjectLocation.isRemoteKey($0) })
        let worktreeRoots = Set(registry.allRepositories.filter(\.supportsWorktrees).map(\.repositoryRoot))
        let installed = editorDiscovery.installedEditors
        for location in projects.locations {
            if worktreeRoots.contains(registry.canonicalProjectRoot(for: location.key)) {
                sources.worktreeProjectKeys.insert(location.key)
            }
            let editors = ExternalEditorLauncher.editors(installed, forProjectRoot: location.key)
            if let editor = ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: terminalSettings.defaultEditorID) {
                sources.editorsByProjectKey[location.key] = OmniEditor(id: editor.id, name: editor.displayName, appPath: editor.appURL.path)
            }
        }

        let project = settings.resolvedProject(for: window.projectRoot)
        sources.editors = editors(installed, projectRoot: project.validProjectRoot, preferredID: terminalSettings.defaultEditorID)
        sources.agents = project.launchableAgents.map { OmniAgent(id: $0.id, name: $0.name, commandLine: $0.commandLine) }
        sources.agentPresets = AgentConfiguration.presets.map { OmniAgent(id: $0.id, name: $0.name, commandLine: $0.commandLine) }
        return sources
    }

    /// The editors a project opens in (a device's: those that open folders
    /// over SSH), the default one first; none without a project.
    static func editors(_ installed: [InstalledEditor], projectRoot: String?, preferredID: String) -> [OmniEditor] {
        guard let projectRoot else { return [] }
        let editors = ExternalEditorLauncher.editors(installed, forProjectRoot: projectRoot)
        guard let preferred = ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: preferredID) else { return [] }
        return ([preferred] + editors.filter { $0.id != preferred.id }).map {
            OmniEditor(id: $0.id, name: $0.displayName, appPath: $0.appURL.path)
        }
    }

    /// The tabs of every open window, the bar's own window's first. Each
    /// one's detail is its window's project, or for a window at the home
    /// folder its directory (`OmniTab.detail`; `home` is each Mac's home
    /// folder when known).
    static func tabs(
        registry: ProjectWindowRegistry,
        current: TerminalWorkspace?,
        home: (ProjectSwitcherModel.Machine) -> String? = { _ in nil }
    ) -> [OmniTab] {
        var windows = registry.workspacesByProjectRoot()
        if let current, let index = windows.firstIndex(where: { $0.workspace === current }) {
            windows.insert(windows.remove(at: index), at: 0)
        }
        return windows.flatMap { projectRoot, workspace in
            let canonical = registry.canonicalProjectRoot(for: projectRoot)
            let location = ProjectLocation(key: canonical)
            let machine: ProjectSwitcherModel.Machine = location.deviceID.map { .device($0) } ?? .thisMac
            let windowPath = location.isRemote ? location.path : canonical
            let machineHome = home(machine)
            return workspace.sessions.map { session in
                var directory: String? = session.workingDirectory
                if let key = directory, ProjectLocation.isRemoteKey(key) { directory = ProjectLocation(key: key).path }
                return OmniTab(
                    id: session.id,
                    title: session.title,
                    projectName: OmniTab.detail(windowPath: windowPath, workingDirectory: directory, home: machineHome),
                    machine: machine,
                    isWorking: session.agentActivityState == .working,
                    canDetach: SessionCloseCoordinator.canDetach(session),
                    agentKey: agentKey(of: session)
                )
            }
        }
    }

    /// An agent tab's tool, as the menu-bar agent list names it
    /// (`MenuBarAgentsModel.refresh`); nil for other tabs.
    static func agentKey(of session: TerminalSession) -> String? {
        guard session.kind == .agent else { return nil }
        let brand = AgentToolBrand.detect(name: session.agentName ?? session.title, commandLine: session.subtitle)
        return brand?.rawValue ?? AgentToolDefinition.normalizedName(session.agentName ?? session.title)
    }

    /// This Mac's background sessions, then each device's.
    static func background(_ model: BackgroundSessionsModel) -> [OmniBackgroundSession] {
        func rows(_ sessions: [BackgroundSession], on machine: ProjectSwitcherModel.Machine) -> [OmniBackgroundSession] {
            sessions.filter(\.isRunning).map {
                OmniBackgroundSession(
                    id: $0.id, title: $0.title, machine: machine, isAtWork: $0.isAtWork,
                    agentKey: $0.kind == .agent ? ($0.agentKey ?? $0.title) : nil
                )
            }
        }
        var result = rows(model.sessions, on: .thisMac)
        for device in model.devices {
            guard let id = device.device?.id else { continue }
            result += rows(device.sessions, on: .device(id))
        }
        return result
    }

    static func context(for window: OmniBarWindow, settings: AgentSettings) -> OmniWindowContext {
        let workspace = window.workspace
        let chromeState = window.chromeState
        let selected = workspace.selectedSession
        let inSplit = selected.map { workspace.splitGroup(containing: $0.id) != nil } ?? false
        var context = OmniWindowContext()
        context.hasSelectedTab = selected != nil
        context.canSplit = selected.map { $0.kind == .terminal && workspace.canAddSplitPane(to: $0.id) } ?? false
        context.canDetach = chromeState.isShowingTerminalContent && selected.map(SessionCloseCoordinator.canDetach) == true
        context.canReopenClosedTab = !chromeState.closedTabs.entries.isEmpty
        context.hasProject = settings.resolvedProject(for: window.projectRoot).validProjectRoot != nil
        context.supportsWorktrees = window.repository.supportsWorktrees
        context.isSidebarHidden = chromeState.isSidebarHidden
        context.detachTitle = inSplit ? "Detach Pane" : "Detach Tab"
        context.closeTitle = chromeState.selectedNoteID != nil ? "Close Note" : (inSplit ? "Close Pane" : "Close Tab")
        return context
    }
}

// MARK: - Running rows

/// What the bar's rows and ⌘K actions do, each through the code path the
/// app already uses for it: the picker's `ProjectSwitcherActions`, the
/// menus' `SessionCloseCoordinator` and workspace calls, the Background
/// Sessions model, the window's sheets.
@MainActor
struct OmniBarPerformer {
    let window: OmniBarWindow
    let settings: AgentSettings
    let registry: ProjectWindowRegistry
    /// Background Sessions (`BackgroundSessionsModel.shared` in the app),
    /// asked for only by the rows that need it.
    let backgroundSessionsModel: @MainActor () -> BackgroundSessionsModel
    let switcher: ProjectSwitcherActions
    let editorDiscovery: ExternalEditorDiscovery
    let projects: () -> ProjectSwitcherModel
    let openSettings: () -> Void
    let toggleAppearance: () -> Void
    var pasteboard: NSPasteboard = .general

    private var chromeState: ProjectWindowChromeState { window.chromeState }
    private var backgroundSessions: BackgroundSessionsModel { backgroundSessionsModel() }
    private var workspace: TerminalWorkspace { window.workspace }
    private var repository: RepositoryWorkspace { window.repository }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func perform(_ command: OmniCommand) {
        switch command {
        case .drill, .removeWorktree, .configureAgentPreset:
            // The bar itself: a scope, or its own alert and sheet.
            break
        case .openProject(let key):
            let model = projects()
            guard let location = model.locations.first(where: { $0.key == key }),
                  let action = model.action(opening: location)
            else { return NSSound.beep() }
            switcher.perform(action)
        case .openPath(let query, let machine):
            if !switcher.openPath(query, on: machine) { NSSound.beep() }
        case .openProjectInEditor(let key, let editorID):
            let editors = ExternalEditorLauncher.editors(editorDiscovery.installedEditors, forProjectRoot: key)
            guard let editor = editors.first(where: { $0.id == editorID }) else { return NSSound.beep() }
            ExternalEditorLauncher().open(projectRoot: key, with: editor)
        case .revealInFinder(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
        case .copyPath(let path):
            pasteboard.clearContents()
            pasteboard.setString(path, forType: .string)
        case .newWorktreeInProject(let key):
            let root = registry.canonicalProjectRoot(for: key)
            if root == repository.repositoryRoot {
                chromeState.presentNewWorktree()
            } else if registry.focus(projectRoot: key), let other = registry.chromeState(for: key) {
                other.presentNewWorktree()
            }
        case .removeProject(let key):
            guard let project = settings.projects.first(where: { $0.root == key }) else { return }
            settings.removeProject(project)
        case .switcher(let action):
            switcher.perform(action)
        case .openFolder(let machine):
            switcher.openFolder(on: machine)
        case .addProject(let machine):
            switcher.addProject(on: machine)
        case .newTerminal(let machine):
            newTerminal(on: machine)
        case .endBackgroundSessions(let machine):
            let ids = OmniBarGathering.background(backgroundSessions).filter { $0.machine == machine }.map(\.id)
            guard !ids.isEmpty else { return }
            backgroundSessions.confirmEndAll(from: registry.window(for: chromeState), limitedTo: ids)
        case .goToTab(let id):
            if !registry.focusSession(sessionID: id, projectRoot: nil) { NSSound.beep() }
        case .renameTab(let id):
            guard let tab = tab(id) else { return }
            promptRenameSession(tab.session)
        case .detachTab(let id):
            guard let tab = tab(id) else { return }
            let context = closeContext(tab.workspace, projectRoot: tab.projectRoot)
            SessionCloseCoordinator.detach(
                tab.session, in: tab.workspace, chromeState: context.chromeState,
                allowEmptyWorkspace: context.allowEmptyWorkspace, closingWindow: context.closingWindow
            )
        case .closeTab(let id):
            guard let tab = tab(id) else { return }
            let context = closeContext(tab.workspace, projectRoot: tab.projectRoot)
            SessionCloseCoordinator.close(
                tab.session, in: tab.workspace, chromeState: context.chromeState,
                allowEmptyWorkspace: context.allowEmptyWorkspace, closingWindow: context.closingWindow
            )
        case .openBackgroundSession(let id):
            let model = backgroundSessions.model(listing: id) ?? backgroundSessions
            guard let item = model.sessions.first(where: { $0.id == id }) else { return NSSound.beep() }
            model.open(item)
        case .endBackgroundSession(let id):
            (backgroundSessions.model(listing: id) ?? backgroundSessions).end(sessionID: id)
        case .activateWorktree(let root):
            _ = repository.activate(worktreeRoot: root, chromeState: chromeState)
        case .createWorktree(let name):
            chromeState.presentNewWorktree(branchName: name)
        case .renameWorktree(let root):
            guard let worktree = repository.worktrees.first(where: { $0.root == root }) else { return }
            chromeState.presentRenameWorktree(worktree)
        case .menu(let command):
            perform(command)
        case .launchAgent(let id):
            let project = settings.resolvedProject(for: window.projectRoot)
            guard let root = project.validProjectRoot,
                  let agent = project.launchableAgents.first(where: { $0.id == id })
            else { return NSSound.beep() }
            chromeState.selectTerminal()
            workspace.addAgentSession(agent: agent.definition, projectRoot: root)
        case .openInEditor(let editorID):
            guard let root = settings.resolvedProject(for: window.projectRoot).validProjectRoot else { return }
            let editors = ExternalEditorLauncher.editors(editorDiscovery.installedEditors, forProjectRoot: root)
            guard let editor = editors.first(where: { $0.id == editorID }) else { return NSSound.beep() }
            ExternalEditorLauncher().open(projectRoot: root, with: editor)
        }
    }

    /// The main menu's actions, as the menus and `AppShortcutMonitor` run
    /// them.
    private func perform(_ command: OmniMenuCommand) {
        let appWindow = registry.window(for: chromeState)
        switch command {
        case .newTab:
            chromeState.selectTerminal()
            workspace.addSession()
        case .splitRight:
            _ = workspace.splitDuplicateActiveTerminal()
        case .detachTab:
            SessionCloseCoordinator.detachSelectedTabOrWindow(
                workspace: workspace, repository: repository, chromeState: chromeState, window: appWindow
            )
        case .closeTab:
            SessionCloseCoordinator.closeSelectedTabOrWindow(
                workspace: workspace, repository: repository, chromeState: chromeState, window: appWindow
            )
        case .reopenClosedTab:
            if !chromeState.closedTabs.undoLatest() { NSSound.beep() }
        case .clearScrollback:
            workspace.clearSelectedSessionScrollback()
        case .settings:
            openSettings()
        case .addMac:
            switcher.perform(.addMac)
        case .endBackgroundSessions:
            backgroundSessions.confirmEndAll(from: appWindow)
        case .persistentSessions:
            chromeState.isHostedSessionsPresented = true
        case .toggleSidebar:
            chromeState.toggleSidebar()
        case .addProject:
            switcher.chooseProjectRoot()
        case .newWorktree:
            chromeState.presentNewWorktree()
        case .manageWorktrees:
            chromeState.presentWorktreeManager()
        case .toggleAppearance:
            toggleAppearance()
        }
    }

    /// A new terminal on `machine`: in this window when it is that Mac's,
    /// else in the window of that Mac active last, else in a new window of
    /// its home folder.
    private func newTerminal(on machine: ProjectSwitcherModel.Machine) {
        func machineOf(_ key: String?) -> ProjectSwitcherModel.Machine {
            key.flatMap { ProjectLocation(key: $0).deviceID }.map { .device($0) } ?? .thisMac
        }
        if machineOf(window.projectRoot ?? workspace.projectRoot) == machine {
            chromeState.selectTerminal()
            workspace.addSession()
            return
        }
        switch machine {
        case .thisMac:
            if let other = registry.frontmostLocalWorkspace(), let root = other.projectRoot, registry.focus(projectRoot: root) {
                registry.chromeState(for: root)?.selectTerminal()
                other.addSession()
            } else if !switcher.openPath("~", on: .thisMac) {
                NSSound.beep()
            }
        case .device(let id):
            if let (root, other) = registry.workspacesByProjectRoot().first(where: { machineOf($0.projectRoot) == machine }),
               registry.focus(projectRoot: root) {
                registry.chromeState(for: root)?.selectTerminal()
                other.addSession()
            } else {
                switcher.perform(.openDeviceHome(id))
            }
        }
    }

    private func tab(_ id: UUID) -> (session: TerminalSession, workspace: TerminalWorkspace, projectRoot: String)? {
        for (root, workspace) in registry.workspacesByProjectRoot() {
            if let session = workspace.sessions.first(where: { $0.id == id }) {
                return (session, workspace, root)
            }
        }
        return nil
    }

    /// As ⌘W and ⌘D work out for the selected tab: the tab's window's
    /// chrome, whether its workspace may empty, and the window that closes
    /// after its last tab.
    private func closeContext(
        _ workspace: TerminalWorkspace,
        projectRoot: String
    ) -> (chromeState: ProjectWindowChromeState?, allowEmptyWorkspace: Bool, closingWindow: NSWindow?) {
        let chromeState = registry.chromeState(for: projectRoot)
        let repository = chromeState.flatMap { registry.repository(for: $0) }
        let window = chromeState.flatMap { registry.window(for: $0) }
        let closesWindow = SessionCloseCoordinator.shouldCloseWindow(for: workspace, repository: repository)
        return (
            chromeState,
            SessionCloseCoordinator.hasOpenSessionsInOtherWorktrees(than: workspace, repository: repository),
            closesWindow ? window : nil
        )
    }
}
