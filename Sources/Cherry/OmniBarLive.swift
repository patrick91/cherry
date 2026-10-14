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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else if let data = defaults.data(forKey: Self.legacyStorageKey),
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
        defaults.set(data, forKey: Self.storageKey)
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
    /// Lists the folders path queries ask for.
    let browser: OmniFolderBrowser
    /// Finds the repositories not added yet.
    let scanner: OmniRepositoryScanner
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?

    init(
        controller: OmniBarController,
        gather: @escaping @MainActor () -> OmniSources,
        frecency: @escaping @MainActor () -> [String: Double],
        controls: @escaping @MainActor () -> [HostControl] = OmniBarLiveModel.deviceControls,
        peeks: RemoteDevicePeeks = .shared,
        browser: OmniFolderBrowser = .shared,
        scanner: OmniRepositoryScanner = .shared
    ) {
        self.controller = controller
        self.gather = gather
        self.frecency = frecency
        self.controls = controls
        self.peeks = peeks
        self.browser = browser
        self.scanner = scanner
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
        // A device that connected since its folder was asked: asked now.
        browser.retryDisconnected()
        var sources = gather()
        sources.folderListings = browser.listings
        sources.unaddedRepositories = scanner.repositories
        controller.update(sources: sources, frecency: frecency())
    }

    func start() {
        stop()
        browser.onChange = { [weak self] in self?.refresh() }
        scanner.onChange = { [weak self] in self?.refresh() }
        controller.requestFolderListing = { [weak self] request in self?.browser.request(request) }
        refresh()
        // The query the bar opened with (a path) is asked now too.
        if let request = controller.folderRequest { browser.request(request) }
        scanner.scanIfDue()
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
        browser.onChange = {}
        scanner.onChange = {}
        controller.requestFolderListing = { _ in }
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

        sources.tabs = tabs(registry: registry, current: window.workspace) { machine in
            switch machine {
            case .thisMac: NSHomeDirectory()
            case .device(let id): deviceStore.device(id: id)?.homeDirectory
            }
        }
        sources.backgroundSessions = background(backgroundSessions)
        sources.window = context(for: window, settings: settings)

        sources.listedLocalProjects = Set(settings.projects.map(\.root).filter { !ProjectLocation.isRemoteKey($0) })
        sources.homes[.thisMac] = NSHomeDirectory()
        sources.removedProjects[.thisMac] = settings.removedProjectRoots
        for entry in devices {
            let machine = ProjectSwitcherModel.Machine.device(entry.device.id)
            if let home = entry.device.homeDirectory?.nilIfEmpty { sources.homes[machine] = home }
            sources.removedProjects[machine] = Set(entry.device.hiddenProjects)
        }
        let installed = editorDiscovery.installedEditors
        for location in projects.locations {
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
            let machine = ProjectSwitcherModel.Machine(projectKey: canonical)
            let windowPath = location.isRemote ? location.path : canonical
            let machineHome = home(machine)
            return workspace.sessions.map { session in
                var directory: String? = session.workingDirectory
                if let key = directory, ProjectLocation.isRemoteKey(key) { directory = ProjectLocation(key: key).path }
                return OmniTab(
                    id: session.id,
                    title: title(of: session, workingDirectory: directory, home: machineHome),
                    projectName: OmniTab.detail(windowPath: windowPath, workingDirectory: directory, home: machineHome),
                    machine: machine,
                    isWorking: session.agentActivityState == .working,
                    canDetach: SessionCloseCoordinator.canDetach(session),
                    agentKey: agentKey(of: session)
                )
            }
        }
    }

    /// A tab's name in the bar (`SessionDisplayTitle.tab`): an agent's
    /// task title, a shell's command, title or directory, a rename first.
    /// A persistent shell's foreground command is what its host last
    /// reported.
    static func title(of session: TerminalSession, workingDirectory: String?, home: String?) -> String {
        let reported = session.kind == .terminal ? session.hostReportedSession : nil
        return SessionDisplayTitle.tab(
            kind: session.kind,
            title: session.title,
            titleSource: session.titleSource,
            agentName: session.agentName,
            commandLine: session.subtitle,
            foreground: reported.flatMap { $0.isBusy ? $0.foreground?.name : nil },
            workingDirectory: workingDirectory,
            home: home ?? session.pathHomeDirectory.nilIfEmpty
        )
    }

    /// An agent tab's tool, as the menu-bar agent list names it
    /// (`TerminalSession.agentToolKey`); nil for other tabs.
    static func agentKey(of session: TerminalSession) -> String? {
        session.kind == .agent ? session.agentToolKey : nil
    }

    /// This Mac's background sessions, then each device's.
    static func background(_ model: BackgroundSessionsModel) -> [OmniBackgroundSession] {
        func rows(_ sessions: [BackgroundSession], on machine: ProjectSwitcherModel.Machine) -> [OmniBackgroundSession] {
            sessions.filter(\.isRunning).map { background($0, on: machine) }
        }
        var result = rows(model.sessions, on: .thisMac)
        for device in model.devices {
            guard let id = device.device?.id else { continue }
            result += rows(device.sessions, on: .device(id))
        }
        return result
    }

    /// A background session as the bar lists it: its own name, its
    /// project, and a working dot only when its agent is known to work.
    static func background(_ session: BackgroundSession, on machine: ProjectSwitcherModel.Machine) -> OmniBackgroundSession {
        OmniBackgroundSession(
            id: session.id,
            title: BackgroundSessionPresentation.rowTitle(of: session),
            machine: machine,
            isWorking: session.isWorking,
            agentKey: session.kind == .agent ? (session.agentKey ?? session.title) : nil,
            projectName: session.projectRoot == nil ? nil : session.projectName
        )
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
        context.isSidebarHidden = chromeState.isSidebarHidden
        context.detachTitle = inSplit ? "Detach Pane" : "Detach Tab"
        context.closeTitle = inSplit ? "Close Pane" : "Close Tab"
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
    /// Forgets a Mac's folder listings once a folder is made there.
    var folderBrowser: OmniFolderBrowser = .shared

    private var chromeState: ProjectWindowChromeState { window.chromeState }
    private var backgroundSessions: BackgroundSessionsModel { backgroundSessionsModel() }
    private var workspace: TerminalWorkspace { window.workspace }
    private var repository: RepositoryWorkspace { window.repository }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func perform(_ command: OmniCommand) {
        switch command {
        case .drill, .configureAgentPreset, .browseFolders, .enterFolder:
            // The bar itself: a scope, folder completion, or its own sheet.
            break
        case .connectDevice(let id):
            switcher.perform(.reconnectDevice(id))
        case .addFolder(let path, let machine, let open):
            addFolder(path, on: machine, open: open)
        case .createFolder(let path, let machine, let intent):
            createFolder(path, on: machine, intent: intent)
        case .newTerminalAt(let path, let machine):
            newTerminal(on: machine, at: path)
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
        case .removeProject(let key):
            guard let project = settings.projects.first(where: { $0.root == key }) else { return }
            settings.removeProject(project)
        case .switcher(let action):
            switcher.perform(action)
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
            let context = closeContext(tab.workspace)
            SessionCloseCoordinator.detach(
                tab.session, in: tab.workspace, chromeState: context.chromeState, closingWindow: context.closingWindow
            )
        case .closeTab(let id):
            guard let tab = tab(id) else { return }
            let context = closeContext(tab.workspace)
            SessionCloseCoordinator.close(
                tab.session, in: tab.workspace, chromeState: context.chromeState, closingWindow: context.closingWindow
            )
        case .openBackgroundSession(let id):
            let model = backgroundSessions.model(listing: id) ?? backgroundSessions
            guard let item = model.sessions.first(where: { $0.id == id }) else { return NSSound.beep() }
            model.open(item)
        case .endBackgroundSession(let id):
            (backgroundSessions.model(listing: id) ?? backgroundSessions).end(sessionID: id)
        case .menu(let command):
            perform(command)
        case .launchAgent(let id):
            let project = settings.resolvedProject(for: window.projectRoot)
            guard let root = project.validProjectRoot,
                  let agent = project.launchableAgents.first(where: { $0.id == id })
            else { return NSSound.beep() }
            chromeState.selectTerminal()
            workspace.addAgentSession(agent: agent, projectRoot: root)
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
        case .toggleAppearance:
            toggleAppearance()
        }
    }

    /// Adds the folder at `path` to its Mac's projects (This Mac's list, or
    /// the device's through `RemoteDeviceProjectAdding`, whose key is
    /// `device:<uuid>:<path>`), then opens it when `open`; says so in a
    /// toast otherwise, and why not when it cannot.
    private func addFolder(_ path: String, on machine: ProjectSwitcherModel.Machine, open: Bool) {
        let toasts = chromeState.toasts
        let name = (path as NSString).lastPathComponent
        switch machine {
        case .thisMac:
            guard let expanded = ProjectSwitcherModel.expandedPath(path, home: NSHomeDirectory()),
                  let project = settings.addProject(path: expanded)
            else {
                toasts.show(ProjectWindowToast(name: "", predicate: "There is no folder at \(path)", symbolName: "exclamationmark.triangle.fill"))
                return
            }
            if open {
                switcher.perform(.openProject(project.root))
            } else {
                toasts.show(ProjectWindowToast(name: project.name, predicate: " was added to Projects", symbolName: "folder.badge.plus"))
            }
        case .device(let id):
            let switcher = switcher
            Task { @MainActor in
                switch await RemoteDeviceProjectAdding.add(path, to: id, store: .shared) {
                case .success(let key):
                    if open {
                        switcher.openProject(CherryProject(root: key))
                    } else {
                        toasts.show(ProjectWindowToast(name: name, predicate: " was added to Projects", symbolName: "folder.badge.plus"))
                    }
                case .failure(let failure):
                    toasts.show(ProjectWindowToast(
                        name: name, predicate: " could not be added", message: failure.message,
                        symbolName: "exclamationmark.triangle.fill"
                    ))
                }
            }
        }
    }

    /// New folder “…”: makes the folder at `path` (absolute; never its
    /// parents) on `machine`, This Mac's with FileManager and another Mac's
    /// over its SSH master (`OmniRemoteFolders.create`), forgets that Mac's
    /// folder listings, then adds and opens it (Add Project…) or opens it
    /// once (Open Folder…); says why not in a toast when it cannot be made.
    private func createFolder(_ path: String, on machine: ProjectSwitcherModel.Machine, intent: OmniFolderIntent) {
        let toasts = chromeState.toasts
        let name = (path as NSString).lastPathComponent
        let failed = { (message: String) in
            toasts.show(ProjectWindowToast(
                name: name, predicate: " could not be created", message: message,
                symbolName: "exclamationmark.triangle.fill"
            ))
        }
        let created = { [self] in
            folderBrowser.forgetListings(on: machine)
            switch intent {
            case .add: addFolder(path, on: machine, open: true)
            case .openOnce: if !switcher.openPath(path, on: machine) { NSSound.beep() }
            }
        }
        switch machine {
        case .thisMac:
            switch OmniLocalFolders.create(path) {
            case .created: created()
            case .failed(let message): failed(message)
            }
        case .device(let id):
            let store = RemoteDeviceStore.shared
            guard let device = store.device(id: id) else { return failed("That Mac is no longer one of your Macs.") }
            // Not made when it could not be added.
            if intent == .add, !store.canModify { return failed(RemoteDeviceStore.readOnlyReason) }
            Task { @MainActor in
                let shell = await OmniRemoteFolders.shell(for: device)
                switch await OmniRemoteFolders.create(path, on: device.sshDestination, shell: shell) {
                case .created: created()
                case .failed(let message): failed(message)
                }
            }
        }
    }

    /// A new terminal on `machine`, in `path` (New Terminal Here) or else
    /// its home folder: in this window when it is that Mac's, else in a
    /// window of that Mac (with no path, This Mac's active last), else in a
    /// new window of that folder.
    private func newTerminal(on machine: ProjectSwitcherModel.Machine, at path: String? = nil) {
        let directory = path.map { path -> String in
            let home: String? = switch machine {
            case .thisMac: NSHomeDirectory()
            case .device(let id): RemoteDeviceStore.shared.device(id: id)?.homeDirectory
            }
            return ProjectSwitcherModel.expandedPath(path, home: home) ?? path
        }
        if ProjectSwitcherModel.Machine(projectKey: window.projectRoot ?? workspace.projectRoot) == machine {
            chromeState.selectTerminal()
            workspace.addSession(workingDirectory: directory)
            return
        }
        let target = machine == .thisMac && path == nil
            ? registry.frontmostLocalWorkspace()
            : registry.workspacesByProjectRoot().first { ProjectSwitcherModel.Machine(projectKey: $0.projectRoot) == machine }?.workspace
        // That workspace's own window, never another window of its project.
        if let other = target, registry.focus(workspace: other) {
            registry.chromeState(for: other)?.selectTerminal()
            other.addSession(workingDirectory: directory)
        } else if let directory {
            if !switcher.openPath(directory, on: machine) { NSSound.beep() }
        } else if case .device(let id) = machine {
            switcher.perform(.openDeviceHome(id))
        } else if !switcher.openPath("~", on: .thisMac) {
            NSSound.beep()
        }
    }

    private func tab(_ id: UUID) -> (session: TerminalSession, workspace: TerminalWorkspace)? {
        for (_, workspace) in registry.workspacesByProjectRoot() {
            if let session = workspace.sessions.first(where: { $0.id == id }) {
                return (session, workspace)
            }
        }
        return nil
    }

    /// As ⌘W and ⌘D work out for the selected tab: the chrome of the
    /// tab's own window (its close question, toast and ⌘Z; never another
    /// window of its project's), and that window when it closes after its
    /// last tab.
    private func closeContext(
        _ workspace: TerminalWorkspace
    ) -> (chromeState: ProjectWindowChromeState?, closingWindow: NSWindow?) {
        let chromeState = registry.chromeState(for: workspace)
        let window = registry.window(for: workspace)
        return (chromeState, SessionCloseCoordinator.shouldCloseWindow(for: workspace) ? window : nil)
    }
}
