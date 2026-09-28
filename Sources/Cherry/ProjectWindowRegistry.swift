import AppKit
import CherryControl
import Darwin
import SwiftUI

@MainActor
final class ProjectWindowRegistry {
    static let shared = ProjectWindowRegistry()

    private var windows: [String: WeakWindow] = [:]
    private var workspaces: [String: WeakWorkspace] = [:]
    private var repositories: [String: WeakRepositoryWorkspace] = [:]
    private var repositoryRootByWorktreeRoot: [String: String] = [:]
    private var noteStores: [String: WeakNoteStore] = [:]
    private var todoStores: [String: WeakTodoStore] = [:]
    private var chromeStates: [String: WeakChromeState] = [:]
    /// The project windows (their repository roots) in the order they were
    /// last active, the most recent last.
    private var activationOrder: [String] = []
    private var activeProjectRoot: String?
    weak var activeWorkspace: TerminalWorkspace?
    weak var activeNoteStore: ProjectNoteStore?
    weak var activeTodoStore: ProjectTodoStore?
    weak var activeChromeState: ProjectWindowChromeState?
    /// Where the open project windows are saved for the next launch. The app
    /// sets it through `configureWorkspacePersistence(store:)`; tests leave it
    /// nil, so nothing is written.
    private(set) var workspaceStateStore: WorkspaceStateStore?
    private var projectWindowRootsToReopenAtLaunch: [String] = []
    private var lastSavedOpenWindowRoots: [String]?
    private var isTerminating = false
    /// Tells the user when this copy of the app leaves the persistent
    /// sessions alone (another copy holds the instance lock). The app sets
    /// it at launch (`installInstanceLockNotice`); tests leave it nil, so
    /// the app's real lock is never taken.
    private(set) var instanceLockNotice: InstanceLockNotice?
    /// Tells the user, at launch, about this app's sessions still running
    /// with no tab (`BackgroundSessionsNotice`). The app sets it at launch
    /// (`installBackgroundSessionsNotice`); tests leave it nil.
    private(set) var backgroundSessionsNotice: BackgroundSessionsNotice?
    /// Opens a project window for a root (nil: the default project's), or
    /// focuses the one open: Background Sessions → Open reopens a closed
    /// window's project. The app sets it (SwiftUI's `openWindow`); tests
    /// give their own.
    var projectWindowOpener: (@MainActor (String?) -> Void)?
    /// Brings a project window forward (`focus`). Tests replace it, so no
    /// test window comes on screen or takes focus from the user's apps.
    var bringWindowForward: @MainActor (NSWindow) -> Void = { window in
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Whether a project window is on screen, not minimized: a toast about
    /// a window that closed goes only to one the user sees. Tests replace
    /// it, as their windows never come on screen.
    var windowIsOnScreen: @MainActor (NSWindow) -> Bool = { window in
        window.isVisible && !window.isMiniaturized
    }
    /// Where each project window's frame is saved. The app sets it
    /// (`configureWindowFrames`); tests leave it nil unless they give their
    /// own, so the app's defaults are never written.
    private(set) var windowFrameStore: ProjectWindowFrameStore?
    private var windowFrameSavers: [String: ProjectWindowFrameSaver] = [:]

    /// Whether a saved window of another Mac's project (a `ProjectLocation`
    /// key) can open: its device is still known (`RemoteDeviceStore`).
    /// None by default; the app points it at its device store at launch
    /// (tests inject their own, never the real devices.json).
    var remoteProjectIsKnown: @MainActor (String) -> Bool = { _ in false }

    /// The app uses `shared`; tests make their own.
    init() {}

    /// Project windows open at their project's last frame and save it as
    /// they move or resize (`ProjectWindowFrameStore`).
    func configureWindowFrames(_ store: ProjectWindowFrameStore?) {
        windowFrameStore = store
    }

    /// Reads the windows to reopen before any window registers (registering
    /// saves the list again), then saves window changes to `store`.
    func configureWorkspacePersistence(store: WorkspaceStateStore) {
        guard workspaceStateStore == nil else { return }
        projectWindowRootsToReopenAtLaunch = store.projectWindowRootsToReopen(remoteProjectIsKnown: remoteProjectIsKnown)
        workspaceStateStore = store
    }

    /// Project windows that were open when Cherry last quit and had tabs,
    /// once: a later call returns nothing.
    func takeProjectWindowRootsToReopen() -> [String] {
        defer { projectWindowRootsToReopenAtLaunch = [] }
        return projectWindowRootsToReopenAtLaunch
    }

    /// Which project windows the app opens at launch, once (a later call
    /// reopens nothing). AppKit restores no project window (they are not
    /// restorable: `CherryApp`), so they come back from this list alone,
    /// whether the app was quit and opened again or macOS relaunched it
    /// after a restart or log out ("Reopen windows when logging back in").
    /// `hasVisibleWindow`: a key-capable window is on screen already (one
    /// a deep link opened).
    func launchWindowPlan(hasVisibleWindow: Bool) -> LaunchWindowPlan {
        let roots = takeProjectWindowRootsToReopen().filter { !hasWindow(for: $0) }
        if !roots.isEmpty { return .reopen(roots) }
        if hasRegisteredProjectWindow || hasVisibleWindow { return .nothing }
        return .openDefault
    }

    /// The sessions a quit that ends sessions would end, in every project
    /// window (`RepositoryWorkspace.localSessionsEndedByAQuit`): the open
    /// persistent tabs' of every host (`PersistentHostingRegistry`: This
    /// Mac's and each device's; they are recorded by host identity), and
    /// the saved tabs' of This Mac.
    func localSessionsEndedByAQuit() -> [(hostID: String, sessionID: String)] {
        repositories.values.compactMap(\.repository).flatMap { $0.localSessionsEndedByAQuit() }
    }

    /// Saves every project's tabs and the open windows now, synchronously.
    func flushWorkspacePersistence() {
        pruneStaleWindows()
        repositories.values.compactMap(\.repository).forEach { $0.flushPersistentState() }
        saveOpenWindowRootsIfChanged(synchronously: true)
        workspaceStateStore?.flush()
    }

    /// Right before quit tears anything down: saves, then keeps the saved
    /// window list as it is until `cancelTermination()`, so windows closing
    /// while the app terminates do not remove themselves from it.
    func prepareForTermination() {
        isTerminating = false
        flushWorkspacePersistence()
        isTerminating = true
    }

    /// The quit was cancelled.
    func cancelTermination() {
        isTerminating = false
    }

    /// A confirmed quit: saves what changed while the confirmation was up,
    /// ends the sessions of tabs closed with ⌘W that ⌘Z could still bring
    /// back (`endClosedTabsAwaitingUndo`), then closes, in every window, the
    /// tabs whose close does what the app's exit does not
    /// (`TerminalWorkspace.closeSessionsForQuit`): native tabs, whose
    /// process trees are stopped, and, for `.appQuitEndingSessions`,
    /// persistent tabs, whose sessions end. Tabs that only detach
    /// (`.appQuit` keeps local sessions running) are left to the exit. Used
    /// where the per-window `windowWillClose` teardown never runs; otherwise
    /// a SIGHUP-ignoring server would outlive Cherry. Returns whether a
    /// native tab's busy program was stopped.
    @discardableResult
    func tearDownForQuit(intent: SessionCloseIntent = .appQuit) -> Bool {
        // A copy of the app launched while this quit waits waits for it,
        // even with no project window open (each repository marks it too).
        workspaceStateStore?.noteAppQuitting()
        prepareForTermination()
        pruneStaleWindows()
        // Tabs closed while their close could still be undone end now,
        // whatever the quit does with the others.
        endClosedTabsAwaitingUndo()
        var stoppedNativeProgram = false
        // Repositories first: they stop saving before their workspaces empty,
        // and they own worktree workspaces `allWorkspaces()` cannot see yet.
        for repository in repositories.values.compactMap(\.repository) {
            stoppedNativeProgram = repository.closeSessionsForQuit(intent: intent) || stoppedNativeProgram
        }
        for workspace in allWorkspaces() {
            stoppedNativeProgram = workspace.closeSessionsForQuit(intent: intent) || stoppedNativeProgram
        }
        return stoppedNativeProgram
    }

    /// Every window's closed tabs that ⌘Z could still bring back go now,
    /// and those closed with ⌘W end (`ClosedTabHistory.endAll`).
    func endClosedTabsAwaitingUndo() {
        pruneStaleWindows()
        for chromeState in chromeStates.values.compactMap(\.chromeState) {
            chromeState.closedTabs.endAll()
        }
    }

    private func saveOpenWindowRootsIfChanged(synchronously: Bool = false) {
        guard let workspaceStateStore, !isTerminating else { return }
        // The repository's own root: its saved tabs are keyed by it, and a
        // reopened window passes it to `RepositoryWorkspace` again.
        let roots = windows.compactMap { root, weakWindow -> String? in
            guard weakWindow.window != nil else { return nil }
            return repositories[root]?.repository?.repositoryRoot ?? root
        }.sorted()
        guard roots != lastSavedOpenWindowRoots else { return }
        lastSavedOpenWindowRoots = roots
        workspaceStateStore.saveOpenProjectWindowRoots(roots, synchronously: synchronously)
    }

    /// Offers `notice` every project window that registers from now on, and
    /// the one already registered.
    func installInstanceLockNotice(_ notice: InstanceLockNotice) {
        guard instanceLockNotice == nil else { return }
        instanceLockNotice = notice
        if let window = firstRegisteredProjectWindow() {
            notice.projectWindowDidRegister(window)
        }
    }

    /// Offers `notice` every project window that registers from now on
    /// (once: a later call keeps the first). It checks once the launch's
    /// windows opened (`BackgroundSessionsNotice.launchWindowsOpened`).
    func installBackgroundSessionsNotice(_ notice: BackgroundSessionsNotice) {
        guard backgroundSessionsNotice == nil else { return }
        backgroundSessionsNotice = notice
    }

    /// Test seam: saves window changes to `store`, or stops saving them.
    func setWorkspaceStateStoreForTesting(_ store: WorkspaceStateStore?) {
        workspaceStateStore = store
        lastSavedOpenWindowRoots = nil
        isTerminating = false
    }

    var hasRegisteredProjectWindow: Bool {
        pruneStaleWindows()
        return !workspaces.isEmpty
    }

    /// A live project window still owned by the registry. AppKit can retain a
    /// closed SwiftUI `NSWindow` in `NSApp.windows`; callers must not use that
    /// broader list for app-reopen routing because the retained scene's
    /// workspace has already been torn down.
    func firstRegisteredProjectWindow() -> NSWindow? {
        pruneStaleWindows()
        if let activeProjectRoot,
           let window = windows[repositoryRoot(for: activeProjectRoot)]?.window {
            return window
        }
        return windows.values.lazy.compactMap(\.window).first
    }

    /// Live workspaces across every registered project window.
    func allWorkspaces() -> [TerminalWorkspace] {
        pruneStaleWindows()
        let repositoryWorkspaces = repositories.values.flatMap {
            $0.repository?.allLoadedWorkspaces() ?? []
        }
        let repositoryWorkspaceIDs = Set(repositoryWorkspaces.map(ObjectIdentifier.init))
        let legacyWorkspaces = workspaces.values.compactMap(\.workspace).filter {
            !repositoryWorkspaceIDs.contains(ObjectIdentifier($0))
        }
        return repositoryWorkspaces + legacyWorkspaces
    }

    /// Total sessions running a process across all windows that closing
    /// everything with `intent` would end: native tabs, and persistent tabs
    /// only when `intent` ends their sessions (a quit keeps them by default).
    func runningProcessCount(endingWith intent: SessionCloseIntent = .appQuit) -> Int {
        allWorkspaces().reduce(0) { $0 + $1.sessionsWithRunningProcess(endingWith: intent).count }
    }

    /// What quitting would do across every window
    /// (`RepositoryWorkspace.teardownSummary`), over the workspaces
    /// `tearDownForQuit` closes; each session is placed by its project.
    func teardownSummary(pathDisplayMode: SidebarTerminalPathDisplayMode) -> SessionTeardownSummary {
        pruneStaleWindows()
        let repositorySummary = repositories.values.compactMap(\.repository).reduce(SessionTeardownSummary()) {
            $0 + $1.teardownSummary(.quit, pathDisplayMode: pathDisplayMode)
        }
        // Windows without a repository.
        let others = workspaces.compactMap { root, entry in
            repositories[root]?.repository == nil ? entry.workspace : nil
        }
        return others.reduce(repositorySummary) { summary, workspace in
            summary + workspace.teardownSummary(
                .quit,
                place: workspace.projectRoot.map(MenuBarAgentPresentation.projectName(projectRoot:)),
                pathDisplayMode: pathDisplayMode
            )
        }
    }

    /// Live workspaces paired with the project-root key they're registered under —
    /// the key the reveal/focus helpers expect. Used to aggregate agents across
    /// every window (e.g. the menu-bar agent list).
    func workspacesByProjectRoot() -> [(projectRoot: String, workspace: TerminalWorkspace)] {
        pruneStaleWindows()
        return allWorkspaces().compactMap { workspace in
            workspace.projectRoot.map { (projectRoot: $0, workspace: workspace) }
        }
    }

    /// Bring a specific session to the foreground: focus its project window,
    /// select the session, and switch that window to the terminal view. Used by
    /// the menu-bar agent list's click-to-focus.
    func revealSession(id sessionID: UUID, projectRoot: String) {
        let owningRoot = self.projectRoot(containing: sessionID) ?? projectRoot
        guard focus(projectRoot: owningRoot),
              let workspace = workspace(for: owningRoot),
              let session = workspace.sessions.first(where: { $0.id == sessionID })
        else { return }
        workspace.select(session)
        chromeState(for: owningRoot)?.selectTerminal()
    }

    // MARK: Background sessions

    /// The repository of every open project window.
    var allRepositories: [RepositoryWorkspace] {
        pruneStaleWindows()
        return repositories.values.compactMap(\.repository)
    }

    /// Saved tabs the open windows may still restore
    /// (`RepositoryWorkspace.savedRecordsAwaitingRestore`).
    func sessionRecordsAwaitingRestore() -> [WorkspaceSessionRecord] {
        allRepositories.flatMap { $0.savedRecordsAwaitingRestore() }
    }

    /// The repository of the project window for `projectRoot` once it has
    /// registered, polling, or nil after `timeout`.
    func waitForRepository(projectRoot: String, timeout: Duration = .seconds(10)) async -> RepositoryWorkspace? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let repository = repository(for: projectRoot) { return repository }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return repository(for: projectRoot)
    }

    /// Background Sessions → Open: shows a session of this app that no open
    /// tab shows. Its project (`cherry.project`, a worktree) names the
    /// window: the open one, or else the project's window is opened, and its
    /// restore brings a closed window's session back with its sibling tabs
    /// and layout. Once that window's restore and look for orphaned
    /// sessions are done, the session's tab is revealed: the one that shows
    /// it now, or else it is adopted into that worktree
    /// (`RepositoryWorkspace.showBackgroundSession`). A session with no
    /// project, or whose window does not open, goes to the active window.
    func showBackgroundSession(
        _ info: HostedSessionInfo,
        localSessions: PersistentLocalSessions,
        attachedTabs: OpenHostedTabs = .shared,
        restoreWait: Duration = .seconds(10)
    ) async {
        let worktree = OrphanedSessionCriteria.projectRoot(of: info)
        var repository = worktree.flatMap { self.repository(for: $0) }
        if repository == nil, let worktree,
           let root = AgentSettings.shared.repositoryRoot(for: worktree), let opener = projectWindowOpener {
            opener(root)
            repository = await waitForRepository(projectRoot: root)
        }
        // A device's session shows only in a window of its project there,
        // never in one of This Mac's (docs/specs/remote-devices.md).
        let isDevice = !localSessions.profile.isThisMac
        if repository == nil, !isDevice {
            repository = activeProjectRoot.flatMap { self.repository(for: $0) } ?? allRepositories.first
        }
        if repository == nil, !isDevice, let opener = projectWindowOpener {
            opener(nil)
            let deadline = ContinuousClock.now + .seconds(10)
            while allRepositories.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            repository = allRepositories.first
        }
        guard let repository else { return }
        _ = focus(projectRoot: worktree.flatMap { repository.contains(worktreeRoot: $0) ? $0 : nil } ?? repository.repositoryRoot)
        await repository.waitUntilSessionsRestored(before: ContinuousClock.now + restoreWait)

        let hostID = localSessions.control.hostID
        if let shown = localSessions.owningTab(of: info.id)
            ?? hostID.flatMap({ attachedTabs.tab(showingSession: info.id, hostID: $0) }) {
            reveal(shown, repository: repository)
            return
        }
        if localSessions.attachment(for: info) == nil {
            _ = try? await localSessions.control.connect()
        }
        // Gone meanwhile, or going: the window's restore removes it (a
        // shell that exited cleanly), or End ended it while this waited.
        guard let current = localSessions.sessionInfo(info.id),
              let attachment = localSessions.attachment(for: current),
              !localSessions.isEnding(current.id),
              !localSessions.isScheduledToEnd(current, hostID: attachment.hostID),
              let tab = repository.showBackgroundSession(
                PersistentSessionLaunch(attachment: attachment, info: current),
                worktreeRoot: worktree,
                hosting: localSessions
              )
        else { return }
        reveal(tab, repository: repository)
    }

    /// The workspace of `worktreeRoot` in its project window, which is
    /// opened again (`projectWindowOpener`) when it closed, then given the
    /// time its restore takes: where a toast's Reopen attaches a session
    /// again after its tab closed, perhaps with its window. nil when no
    /// window shows or opens for it.
    func workspaceOpeningWindow(
        worktreeRoot: String,
        restoreWait: Duration = .seconds(10)
    ) async -> TerminalWorkspace? {
        if let repository = repository(for: worktreeRoot) {
            return repository.prepareWorkspace(worktreeRoot: worktreeRoot) ?? repository.activeWorkspace
        }
        if let workspace = workspace(for: worktreeRoot) {
            return workspace
        }
        guard let root = AgentSettings.shared.repositoryRoot(for: worktreeRoot), let opener = projectWindowOpener else {
            return nil
        }
        opener(root)
        guard let repository = await waitForRepository(projectRoot: root) else { return nil }
        await repository.waitUntilSessionsRestored(before: ContinuousClock.now + restoreWait)
        return repository.prepareWorkspace(worktreeRoot: worktreeRoot) ?? repository.activeWorkspace
    }

    /// Focuses the window and worktree that has `tab`, and selects it.
    private func reveal(_ tab: TerminalSession, repository: RepositoryWorkspace) {
        let root = projectRoot(containing: tab.id) ?? repository.repositoryRoot
        revealSession(id: tab.id, projectRoot: root)
    }

    var projectRoots: [String] {
        pruneStaleWindows()
        return allWorkspaces().compactMap(\.projectRoot)
    }

    /// Every root that can be focused through an open project window, including
    /// discovered worktrees whose terminal workspace has not been created yet.
    var knownProjectRoots: [String] {
        pruneStaleWindows()
        let repositoryRoots = repositories.values.flatMap {
            $0.repository?.worktrees.map(\.root) ?? []
        }
        return Array(Set(repositoryRoots + Array(workspaces.keys))).sorted()
    }

    func canonicalProjectRoot(for projectRoot: String) -> String {
        repositoryRoot(for: projectRoot)
    }

    func hasWindow(for projectRoot: String) -> Bool {
        pruneStaleWindows()
        return windows[repositoryRoot(for: projectRoot)]?.window != nil
    }

    func projectRoot(forProjectKey projectKey: String) -> String? {
        pruneStaleWindows()
        let normalizedKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var roots = repositories.values.flatMap { $0.repository?.worktrees.map(\.root) ?? [] }
        roots.append(contentsOf: workspaces.keys)
        roots.append(contentsOf: AgentSettings.shared.projects.map(\.root))
        if let activeProjectRoot {
            roots.append(activeProjectRoot)
        }

        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            if CherryDeepLink.projectKey(forProjectRoot: root) == normalizedKey {
                return root
            }
        }
        return nil
    }

    func workspace(for projectRoot: String) -> TerminalWorkspace? {
        pruneStaleWindows()
        if let repository = repository(for: projectRoot) {
            return repository.workspaceIfLoaded(for: projectRoot)
        }
        return workspaces[projectRoot]?.workspace
    }

    /// Workspace belonging to the current key window. Menu actions must
    /// resolve their target through this rather than SwiftUI focused values:
    /// `@FocusedValue` only updates while the SwiftUI hierarchy owns focus,
    /// so with the AppKit terminal view as first responder it can keep
    /// pointing at a previously focused window.
    var keyWindowWorkspace: TerminalWorkspace? {
        pruneStaleWindows()
        guard let projectRoot = projectRoot(for: NSApp.keyWindow) else { return nil }
        return workspaces[projectRoot]?.workspace
    }

    /// Repository belonging to the current key window. Used with
    /// `keyWindowWorkspace` when a menu action needs repository-wide state.
    var keyWindowRepository: RepositoryWorkspace? {
        pruneStaleWindows()
        guard let projectRoot = projectRoot(for: NSApp.keyWindow) else { return nil }
        return repositories[projectRoot]?.repository
    }

    /// Chrome state belonging to the current key window. See
    /// `keyWindowWorkspace` for why menu actions resolve through this.
    var keyWindowChromeState: ProjectWindowChromeState? {
        pruneStaleWindows()
        guard let projectRoot = projectRoot(for: NSApp.keyWindow) else { return nil }
        return chromeStates[projectRoot]?.chromeState
    }

    func window(for chromeState: ProjectWindowChromeState) -> NSWindow? {
        pruneStaleWindows()
        guard let projectRoot = chromeStates.first(where: { _, weakState in
            weakState.chromeState === chromeState
        })?.key else { return nil }
        return windows[projectRoot]?.window
    }

    /// The repository of the window `chromeState` belongs to.
    func repository(for chromeState: ProjectWindowChromeState) -> RepositoryWorkspace? {
        pruneStaleWindows()
        guard let projectRoot = chromeStates.first(where: { _, weakState in
            weakState.chromeState === chromeState
        })?.key else { return nil }
        return repositories[projectRoot]?.repository
    }

    /// A project window on screen (`windowIsOnScreen`) other than `window`
    /// (and the one `chromeState` belongs to), the one active most recently
    /// first: where a toast goes about a tab whose window closed with it.
    /// Its workspace is its repository's active one.
    func mostRecentlyActiveProjectWindow(
        excluding window: NSWindow?,
        chromeState excludedChromeState: ProjectWindowChromeState?
    ) -> (chromeState: ProjectWindowChromeState, workspace: TerminalWorkspace, repository: RepositoryWorkspace?)? {
        pruneStaleWindows()
        let roots = activationOrder.reversed() + windows.keys.sorted()
        for root in roots {
            guard let candidate = windows[root]?.window, candidate !== window, windowIsOnScreen(candidate),
                  let chromeState = chromeStates[root]?.chromeState, chromeState !== excludedChromeState,
                  let workspace = workspaces[root]?.workspace
            else { continue }
            let repository = repositories[root]?.repository
            return (chromeState, repository?.activeWorkspace ?? workspace, repository)
        }
        return nil
    }

    /// The workspace of the frontmost window of a project on This Mac: the
    /// key window's when it is one, else the one active most recently.
    func frontmostLocalWorkspace() -> TerminalWorkspace? {
        pruneStaleWindows()
        if let key = projectRoot(for: NSApp.keyWindow), !ProjectLocation.isRemoteKey(key),
           let workspace = repositories[key]?.repository?.activeWorkspace ?? workspaces[key]?.workspace {
            return workspace
        }
        for root in activationOrder.reversed() + windows.keys.sorted() where !ProjectLocation.isRemoteKey(root) {
            guard windows[root]?.window != nil,
                  let workspace = repositories[root]?.repository?.activeWorkspace ?? workspaces[root]?.workspace
            else { continue }
            return workspace
        }
        return nil
    }

    func noteStore(for projectRoot: String) -> ProjectNoteStore? {
        pruneStaleWindows()
        return noteStores[repositoryRoot(for: projectRoot)]?.noteStore
    }

    func todoStore(for projectRoot: String) -> ProjectTodoStore? {
        pruneStaleWindows()
        return todoStores[repositoryRoot(for: projectRoot)]?.todoStore
    }

    func chromeState(for projectRoot: String) -> ProjectWindowChromeState? {
        pruneStaleWindows()
        return chromeStates[repositoryRoot(for: projectRoot)]?.chromeState
    }

    /// The chrome state of the project window `window`: where a notice
    /// about it shows its toast.
    func chromeState(for window: NSWindow) -> ProjectWindowChromeState? {
        pruneStaleWindows()
        return projectRoot(for: window).flatMap { chromeStates[$0]?.chromeState }
    }

    @discardableResult
    func register(
        window: NSWindow,
        projectRoot: String?,
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace? = nil,
        noteStore: ProjectNoteStore?,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) -> Bool {
        guard let requestedRoot = projectRoot else { return false }
        pruneStaleWindows()
        let projectRoot = repositoryRoot(for: requestedRoot)
        if let existing = windows[projectRoot]?.window, existing !== window {
            // Another window already owns this project. Refuse to claim the
            // slot so the caller can close this duplicate. SwiftUI's
            // WindowGroup<Value> can spawn an extra default (value=nil)
            // window alongside the persisted one during scene restoration —
            // without this guard, the second registration overwrites the
            // first and both windows fight for the same workspace state.
            return false
        }
        // Cherry saves and reopens its windows, their tabs and frames
        // itself (`ProjectWindowFrameStore`). AppKit's restorable state
        // would only cost typing: while keys arrive it re-encodes and
        // snapshots the window on the main thread (25–135 ms stalls, longer
        // for bigger windows).
        window.isRestorable = false
        if windows[projectRoot]?.window !== window {
            // Newly claimed (a window registers again on every update): it
            // takes the frame its project's window last had.
            adoptSavedFrame(of: window, projectRoot: projectRoot)
        }
        windows[projectRoot] = WeakWindow(window)
        workspaces[projectRoot] = WeakWorkspace(workspace)
        if let repository {
            repositories[projectRoot] = WeakRepositoryWorkspace(repository)
            repository.windowRegistry = self
            updateWorktreeMappings(repositoryRoot: projectRoot, repository: repository)
        }
        if let noteStore {
            noteStores[projectRoot] = WeakNoteStore(noteStore)
        }
        if let todoStore {
            todoStores[projectRoot] = WeakTodoStore(todoStore)
        }
        if let chromeState {
            chromeStates[projectRoot] = WeakChromeState(chromeState)
        }

        if activeWorkspace == nil || window.isKeyWindow || window.isMainWindow {
            activate(
                projectRoot: projectRoot,
                workspace: workspace,
                noteStore: noteStore,
                todoStore: todoStore,
                chromeState: chromeState
            )
        }
        saveOpenWindowRootsIfChanged()
        instanceLockNotice?.projectWindowDidRegister(window)
        backgroundSessionsNotice?.projectWindowDidRegister(window)
        return true
    }

    /// Gives a newly claimed project window its project's saved frame, and
    /// saves the frame from then on.
    private func adoptSavedFrame(of window: NSWindow, projectRoot: String) {
        windowFrameSavers.removeValue(forKey: projectRoot)
        guard let windowFrameStore else { return }
        windowFrameStore.restore(window, projectRoot: projectRoot)
        windowFrameSavers[projectRoot] = ProjectWindowFrameSaver(
            window: window,
            projectRoot: projectRoot,
            store: windowFrameStore
        )
    }

    func unregister(window: NSWindow, projectRoot: String?) {
        guard let requestedRoot = projectRoot else { return }
        let projectRoot = repositoryRoot(for: requestedRoot)
        guard windows[projectRoot]?.window === window else { return }
        repositoryRootByWorktreeRoot = repositoryRootByWorktreeRoot.filter { $0.value != projectRoot }
        windowFrameSavers.removeValue(forKey: projectRoot)?.saveNow()
        windows.removeValue(forKey: projectRoot)
        workspaces.removeValue(forKey: projectRoot)
        repositories.removeValue(forKey: projectRoot)
        noteStores.removeValue(forKey: projectRoot)
        todoStores.removeValue(forKey: projectRoot)
        chromeStates.removeValue(forKey: projectRoot)
        activationOrder.removeAll { $0 == projectRoot }
        saveOpenWindowRootsIfChanged()
        if activeProjectRoot.map(repositoryRoot(for:)) == projectRoot {
            activeProjectRoot = nil
            activeWorkspace = nil
            activeNoteStore = nil
            activeTodoStore = nil
            activeChromeState = nil
            refreshActiveWindow()
            Task { @MainActor in
                ProjectWindowRegistry.shared.refreshActiveWindow()
            }
        }
    }

    func focus(projectRoot: String, activateWorktree: Bool = true) -> Bool {
        let repositoryRoot = repositoryRoot(for: projectRoot)
        guard let window = windows[repositoryRoot]?.window else {
            windows.removeValue(forKey: repositoryRoot)
            return false
        }

        if let repository = repositories[repositoryRoot]?.repository {
            if activateWorktree, repository.contains(worktreeRoot: projectRoot) {
                _ = repository.activate(
                    worktreeRoot: projectRoot,
                    chromeState: chromeStates[repositoryRoot]?.chromeState
                )
            }
            let workspace = repository.activeWorkspace
            workspaces[repositoryRoot] = WeakWorkspace(workspace)
            activate(
                projectRoot: workspace.projectRoot ?? repositoryRoot,
                workspace: workspace,
                noteStore: noteStores[repositoryRoot]?.noteStore,
                todoStore: todoStores[repositoryRoot]?.todoStore,
                chromeState: chromeStates[repositoryRoot]?.chromeState
            )
        } else if let workspace = workspaces[repositoryRoot]?.workspace {
            activate(
                projectRoot: projectRoot,
                workspace: workspace,
                noteStore: noteStores[repositoryRoot]?.noteStore,
                todoStore: todoStores[repositoryRoot]?.todoStore,
                chromeState: chromeStates[repositoryRoot]?.chromeState
            )
        } else {
            AgentSettings.shared.markProjectOpened(repositoryRoot)
        }
        bringWindowForward(window)
        return true
    }

    @discardableResult
    func select(_ deepLink: CherryDeepLink, projectRoot: String) -> Bool {
        let repositoryRoot = repositoryRoot(for: projectRoot)
        guard CherryDeepLink.projectKey(forProjectRoot: projectRoot) == deepLink.projectKey,
              let chromeState = chromeStates[repositoryRoot]?.chromeState
        else {
            return false
        }

        switch deepLink.kind {
        case .note:
            guard AgentSettings.shared.projectFeatures(for: projectRoot).notesEnabled else {
                return false
            }
            guard let noteID = UUID(uuidString: deepLink.targetID),
                  noteStores[repositoryRoot]?.noteStore?.notes.contains(where: { $0.id == noteID }) == true
            else {
                return false
            }
            chromeState.selectNote(id: noteID)
            return true
        case .todo:
            guard AgentSettings.shared.projectFeatures(for: projectRoot).todosEnabled else {
                return false
            }
            guard let todoID = UUID(uuidString: deepLink.targetID),
                  todoStores[repositoryRoot]?.todoStore?.todos.contains(where: { $0.id == todoID }) == true
            else {
                return false
            }
            chromeState.selectTodo(id: todoID)
            return true
        case .terminal:
            guard let sessionID = UUID(uuidString: deepLink.targetID),
                  focus(projectRoot: projectRoot),
                  let workspace = workspace(for: projectRoot),
                  let session = workspace.sessions.first(where: { $0.id == sessionID })
            else {
                return false
            }
            workspace.select(session)
            chromeState.selectTerminal()
            return true
        }
    }

    func markCurrentActiveProjectOpened() {
        refreshActiveWindow()
        guard let activeProjectRoot else { return }
        AgentSettings.shared.markWorktreeOpened(
            activeProjectRoot,
            repositoryRoot: repositoryRoot(for: activeProjectRoot)
        )
    }

    func activateWindow(
        projectRoot: String?,
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore?,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) {
        guard let projectRoot else { return }
        activate(
            projectRoot: projectRoot,
            workspace: workspace,
            noteStore: noteStore,
            todoStore: todoStore,
            chromeState: chromeState
        )
    }

    func projectRoot(containing sessionID: UUID) -> String? {
        pruneStaleWindows()
        for repository in repositories.values {
            if let root = repository.repository?.root(containing: sessionID) {
                return root
            }
        }
        return workspaces.values.compactMap(\.workspace).first { workspace in
            workspace.sessions.contains { $0.id == sessionID }
        }?.projectRoot
    }

    func isSessionVisible(_ session: TerminalSession) -> Bool {
        pruneStaleWindows()

        for (projectRoot, weakWorkspace) in workspaces {
            guard let workspace = weakWorkspace.workspace,
                  workspace.sessions.contains(where: { $0.id == session.id }),
                  chromeStates[projectRoot]?.chromeState?.isShowingTerminalContent ?? true,
                  let window = windows[projectRoot]?.window
            else {
                continue
            }

            let isVisibleSession = if session.kind == .terminal {
                workspace.visibleTerminalSessionIDs.contains(session.id)
            } else {
                workspace.selectedSessionID == session.id
            }
            guard isVisibleSession else { continue }

            return Self.isTerminalWindowVisible(
                windowIsKey: window.isKeyWindow,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                occlusionState: window.occlusionState
            )
        }

        return false
    }

    static func isTerminalWindowVisible(
        windowIsKey _: Bool,
        isVisible: Bool,
        isMiniaturized: Bool,
        occlusionState: NSWindow.OcclusionState
    ) -> Bool {
        isVisible
            && !isMiniaturized
            && occlusionState.contains(.visible)
    }

    func handleApplicationDidBecomeActive() {
        refreshActiveWindow()
        acknowledgeActiveVisibleSession()
    }

    @discardableResult
    func focusSession(sessionID: UUID, projectRoot requestedProjectRoot: String?) -> Bool {
        let candidates: [(projectRoot: String?, workspace: TerminalWorkspace, chromeState: ProjectWindowChromeState?)] =
            workspacesByProjectRoot().compactMap { candidate in
                if let requestedProjectRoot,
                   candidate.projectRoot != requestedProjectRoot,
                   repositoryRoot(for: candidate.projectRoot) != repositoryRoot(for: requestedProjectRoot) {
                    return nil
                }
                return (
                    projectRoot: candidate.projectRoot,
                    workspace: candidate.workspace,
                    chromeState: chromeState(for: candidate.projectRoot)
                )
            }

        for candidate in candidates {
            guard let session = candidate.workspace.sessions.first(where: { $0.id == sessionID }) else {
                continue
            }

            if let projectRoot = candidate.projectRoot {
                _ = focus(projectRoot: projectRoot)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            candidate.workspace.select(session)
            candidate.chromeState?.selectTerminal()
            session.acknowledgeAttentionAlert()
            return true
        }

        return false
    }

    private func activate(
        projectRoot: String,
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore?,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?,
        recordsOpening: Bool = true
    ) {
        let effectiveRoot = workspace.projectRoot ?? projectRoot
        let windowRoot = repositoryRoot(for: projectRoot)
        activationOrder.removeAll { $0 == windowRoot }
        activationOrder.append(windowRoot)
        activeProjectRoot = effectiveRoot
        activeWorkspace = workspace
        activeNoteStore = noteStore
        activeTodoStore = todoStore
        activeChromeState = chromeState
        if recordsOpening {
            AgentSettings.shared.markWorktreeOpened(
                effectiveRoot,
                repositoryRoot: repositoryRoot(for: projectRoot)
            )
        }

        if NSApplication.shared.isActive,
           chromeState?.isShowingTerminalContent ?? true {
            workspace.clearUnreadNotificationForSelectedSession()
            workspace.acknowledgeAttentionForSelectedSession()
        }
    }

    private func acknowledgeActiveVisibleSession() {
        guard NSApplication.shared.isActive,
              activeChromeState?.isShowingTerminalContent ?? true
        else {
            return
        }

        activeWorkspace?.clearUnreadNotificationForSelectedSession()
        activeWorkspace?.acknowledgeAttentionForSelectedSession()
    }

    func repositoryDidRefresh(_ repository: RepositoryWorkspace) {
        guard let repositoryRoot = repositories.first(where: {
            $0.value.repository === repository
        })?.key else {
            return
        }
        updateWorktreeMappings(repositoryRoot: repositoryRoot, repository: repository)
    }

    func repositoryDidActivate(_ repository: RepositoryWorkspace) {
        guard let repositoryRoot = repositories.first(where: {
            $0.value.repository === repository
        })?.key else {
            return
        }
        let workspace = repository.activeWorkspace
        workspaces[repositoryRoot] = WeakWorkspace(workspace)
        if windows[repositoryRoot]?.window?.isKeyWindow == true {
            activate(
                projectRoot: repository.activeWorktreeRoot,
                workspace: workspace,
                noteStore: noteStores[repositoryRoot]?.noteStore,
                todoStore: todoStores[repositoryRoot]?.todoStore,
                chromeState: chromeStates[repositoryRoot]?.chromeState,
                recordsOpening: false
            )
        }
    }

    func repository(for projectRoot: String) -> RepositoryWorkspace? {
        pruneStaleWindows()
        return repositories[repositoryRoot(for: projectRoot)]?.repository
    }

    private func refreshActiveWindow() {
        pruneStaleWindows()
        guard let projectRoot = projectRoot(for: NSApp.keyWindow) ?? projectRoot(for: NSApp.mainWindow),
              let workspace = workspaces[projectRoot]?.workspace
        else {
            return
        }

        activate(
            projectRoot: projectRoot,
            workspace: workspace,
            noteStore: noteStores[projectRoot]?.noteStore,
            todoStore: todoStores[projectRoot]?.todoStore,
            chromeState: chromeStates[projectRoot]?.chromeState
        )
    }

    private func projectRoot(for window: NSWindow?) -> String? {
        guard let window else { return nil }
        return windows.first { _, weakWindow in
            weakWindow.window === window
        }?.key
    }

    private func repositoryRoot(for projectRoot: String) -> String {
        // A project on another Mac is its key, never a path here.
        if ProjectLocation.isRemoteKey(projectRoot) { return ProjectLocation(key: projectRoot).key }
        let standardizedRoot = URL(
            fileURLWithPath: projectRoot,
            isDirectory: true
        ).standardizedFileURL.path
        let normalizedRoot: String
        if let resolved = standardizedRoot.withCString({ realpath($0, nil) }) {
            normalizedRoot = String(cString: resolved)
            free(resolved)
        } else {
            normalizedRoot = standardizedRoot
        }
        return repositoryRootByWorktreeRoot[normalizedRoot] ?? normalizedRoot
    }

    private func updateWorktreeMappings(
        repositoryRoot: String,
        repository: RepositoryWorkspace
    ) {
        repositoryRootByWorktreeRoot = repositoryRootByWorktreeRoot.filter {
            $0.value != repositoryRoot
        }
        repositoryRootByWorktreeRoot[repositoryRoot] = repositoryRoot
        for worktree in repository.worktrees {
            repositoryRootByWorktreeRoot[worktree.root] = repositoryRoot
        }
    }

    private func pruneStaleWindows() {
        let staleProjectRoots = windows.compactMap { projectRoot, weakWindow in
            weakWindow.window == nil || workspaces[projectRoot]?.workspace == nil ? projectRoot : nil
        }
        for projectRoot in staleProjectRoots {
            repositoryRootByWorktreeRoot = repositoryRootByWorktreeRoot.filter {
                $0.value != projectRoot
            }
            windows.removeValue(forKey: projectRoot)
            workspaces.removeValue(forKey: projectRoot)
            repositories.removeValue(forKey: projectRoot)
            noteStores.removeValue(forKey: projectRoot)
            todoStores.removeValue(forKey: projectRoot)
            chromeStates.removeValue(forKey: projectRoot)
            windowFrameSavers.removeValue(forKey: projectRoot)
            activationOrder.removeAll { $0 == projectRoot }
            if activeProjectRoot.map(repositoryRoot(for:)) == projectRoot {
                activeProjectRoot = nil
                activeWorkspace = nil
                activeNoteStore = nil
                activeTodoStore = nil
                activeChromeState = nil
            }
        }
    }
}

/// Saves a project window's frame (`ProjectWindowFrameStore`) whenever it
/// moves or resizes; a live resize once, when it ends.
@MainActor
private final class ProjectWindowFrameSaver: NSObject {
    private weak var window: NSWindow?
    private let projectRoot: String
    private let store: ProjectWindowFrameStore

    init(window: NSWindow, projectRoot: String, store: ProjectWindowFrameStore) {
        self.window = window
        self.projectRoot = projectRoot
        self.store = store
        super.init()
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
        ] {
            // Removed when the saver goes (selector-based observation).
            NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange(_:)), name: name, object: window)
        }
    }

    @objc private func frameDidChange(_ notification: Notification) {
        guard let window else { return }
        if notification.name == NSWindow.didResizeNotification, window.inLiveResize { return }
        store.save(window, projectRoot: projectRoot)
    }

    func saveNow() {
        guard let window else { return }
        store.save(window, projectRoot: projectRoot)
    }
}

private final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

private final class WeakWorkspace {
    weak var workspace: TerminalWorkspace?

    init(_ workspace: TerminalWorkspace) {
        self.workspace = workspace
    }
}

private final class WeakRepositoryWorkspace {
    weak var repository: RepositoryWorkspace?

    init(_ repository: RepositoryWorkspace) {
        self.repository = repository
    }
}

private final class WeakNoteStore {
    weak var noteStore: ProjectNoteStore?

    init(_ noteStore: ProjectNoteStore) {
        self.noteStore = noteStore
    }
}

private final class WeakTodoStore {
    weak var todoStore: ProjectTodoStore?

    init(_ todoStore: ProjectTodoStore) {
        self.todoStore = todoStore
    }
}

private final class WeakChromeState {
    weak var chromeState: ProjectWindowChromeState?

    init(_ chromeState: ProjectWindowChromeState) {
        self.chromeState = chromeState
    }
}

/// A device a sheet is about (`ProjectWindowChromeState.addProjectDevice`).
struct RemoteDeviceReference: Identifiable, Equatable {
    let id: UUID
}

@MainActor
final class ProjectWindowChromeState: ObservableObject {
    @Published var isSidebarHidden = false
    @Published var isSidebarRevealed = false
    @Published var isCursorOverSidebar = false
    @Published var isSidebarAnimating = false
    @Published var isCommandPalettePresented = false
    @Published var isHostedSessionsPresented = false
    /// The host the Persistent Sessions sheet opens on (a device's, from
    /// the picker), taken by the sheet when it appears.
    @Published var hostedSessionsInitialHost: HostedSessionHost?
    /// Add Mac… (docs/specs/remote-devices.md).
    @Published var isAddDevicePresented = false
    /// Add Project on <Mac>…: the device.
    @Published var addProjectDevice: RemoteDeviceReference?
    @Published var isNewWorktreePresented = false
    @Published var isWorktreeManagerPresented = false
    @Published var worktreeToRename: GitWorktree?
    @Published var isTerminalSearchPresented = false
    @Published var terminalSearchFocusRequest = 0
    @Published var isIconDebugOverlayPresented = false
    @Published var isSidebarPlaygroundPresented = false
    @Published var isCommandPalettePlaygroundPresented = false
    @Published var isProjectTabsPrototypePresented = PrototypeFeatureFlags.isProjectTabsPrototypeEnabled
    @Published var isCommandKeyPressed = false
    @Published var selectedNoteID: UUID?
    @Published var selectedTodoID: UUID?
    @Published var isTodoPanePresented = false
    @Published var selectedTodoTagFilterIDs: Set<String> = []
    @Published var collapsedAgentGroupIDs: Set<UUID> = []
    /// A close waiting for "Close “<name>”?" (`TabCloseAlertPresenterView`).
    @Published var pendingTabClose: TabCloseRequest?
    @Published var pendingAgentGroupCloseSessionID: UUID?
    @Published var pendingAgentGroupCloseAllowsEmptyWorkspace = false
    @Published var focusedIdleCommandName: String?
    @Published var commandPaletteFocusRequest = 0
    /// The window's toast (`ProjectWindowToastOverlay`): observed on its
    /// own, so a toast coming and going does not re-render the window.
    let toasts: ProjectWindowToasts
    /// The tabs a user's close or detach took out of the window that ⌘Z can
    /// bring back (`ClosedTabHistory`), on the toasts' clock.
    let closedTabs: ClosedTabHistory
    // Mirrored from ProjectWorkspaceView's scene-scoped sidebar width so the
    // terminal container can predict its post-animation width without
    // reading the AppKit window directly.
    @Published var dockedSidebarWidth: CGFloat = 320
    // Set explicitly by `toggleSidebar` *before* the withAnimation
    // transaction so the terminal container reads the correct width
    // change in its very first updateNSView pass after the toggle.
    // Inferring this from `isSidebarHidden` was wrong: when the new
    // value is set inside `withAnimation`, SwiftUI can deliver the
    // `isSidebarAnimating = true` change in a render that still has
    // the *old* `isSidebarHidden`, leading to a sign-inverted delta
    // and a pre-fit to the wrong size.
    @Published var pendingPostAnimationDelta: CGFloat = 0

    // Mirrors the `.padding(.leading, includeLeadingPadding ? 5 : 0)` in
    // ContentView's DetailPaneView. The terminal pane has 5pt of leading
    // padding when the sidebar is hidden, and 0pt when it's shown — so a
    // sidebar toggle shifts the pane width by `(sidebarWidth - 5)`, not
    // by the sidebar's full width. Without accounting for this, our
    // pre-fit lands ~5px off and AppKit's next layout pass kicks off a
    // corrective `synchronizeTerminalFrame` (the second flash).
    private static let detailPaneLeadingInsetSwap: CGFloat = 5
    private static let dockedSidebarAnimationStateDuration: Duration = .milliseconds(280)
    private var dockedSidebarAnimationDepth = 0

    /// Test seam for `isCursorActuallyOverLeadingSidebar(width:)`.
    var cursorOverSidebarProbeForTesting: ((CGFloat) -> Bool)?

    /// Test seam for when a docked sidebar animation's state ends: given
    /// the end, runs it when the animation is over. By default it runs
    /// `dockedSidebarAnimationStateDuration` later; tests run it when they
    /// choose, so overlapping animations do not race the clock.
    var dockedAnimationEndSchedulerForTesting: ((@escaping @MainActor () -> Void) -> Void)?

    /// Tests give toasts a clock and announcer of their own, which the
    /// closed tabs share.
    init(toasts: ProjectWindowToasts = ProjectWindowToasts()) {
        self.toasts = toasts
        let closedTabs = ClosedTabHistory(clockOf: toasts)
        self.closedTabs = closedTabs
        closedTabs.chromeState = self
        closedTabs.dismissToast = { [weak toasts] id in toasts?.dismiss(id: id) }
        toasts.hoverDidChange = { [weak closedTabs] id in closedTabs?.setHoveredToast(id) }
    }

    /// Hit-test the real mouse position against the leading sidebar region
    /// of this state's window. The `isCursorOverSidebar` /
    /// `isCursorInsideSidebarRevealRegion` flags are inferred from hover
    /// events, which AppKit does not deliver when the hovered view is
    /// removed under the cursor or the window resigns key — so they can go
    /// stale. Flows that would visibly misbehave on a stale flag (the
    /// docked→floating Cmd+S swap, forced cursor-flag seeding) must verify
    /// against the actual cursor before trusting them.
    func isCursorActuallyOverLeadingSidebar(width: CGFloat) -> Bool {
        if let probe = cursorOverSidebarProbeForTesting {
            return probe(width)
        }
        guard let window = ProjectWindowRegistry.shared.window(for: self) ?? NSApp.keyWindow,
              let contentView = window.contentView
        else {
            return false
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        return contentView.bounds.contains(viewPoint) && viewPoint.x <= width
    }

    func toggleSidebar() {
        if isSidebarHidden {
            if isSidebarRevealed {
                isSidebarHidden.toggle()
            } else {
                runDockedAnimation(deltaWidth: -(dockedSidebarWidth - Self.detailPaneLeadingInsetSwap)) {
                    self.isSidebarHidden.toggle()
                }
            }
        } else if isCursorOverSidebar,
                  isCursorActuallyOverLeadingSidebar(width: dockedSidebarWidth) {
            withAnimation(nil) {
                isSidebarHidden = true
                isSidebarRevealed = true
            }
        } else {
            runDockedAnimation(deltaWidth: dockedSidebarWidth - Self.detailPaneLeadingInsetSwap) {
                self.isSidebarHidden = true
            }
        }
    }

    func presentCommandPalette() {
        isCommandPalettePresented = true
        commandPaletteFocusRequest &+= 1
    }

    func presentNewWorktree() {
        isWorktreeManagerPresented = false
        worktreeToRename = nil
        isNewWorktreePresented = true
    }

    func presentWorktreeManager() {
        isNewWorktreePresented = false
        worktreeToRename = nil
        isWorktreeManagerPresented = true
    }

    func presentRenameWorktree(_ worktree: GitWorktree) {
        isNewWorktreePresented = false
        isWorktreeManagerPresented = false
        DispatchQueue.main.async {
            self.worktreeToRename = worktree
        }
    }

    func presentTerminalSearch() {
        selectTerminal()
        isTerminalSearchPresented = true
        terminalSearchFocusRequest &+= 1
    }

    func dismissTerminalSearch() {
        isTerminalSearchPresented = false
    }

    func toggleIconDebugOverlay() {
        isIconDebugOverlayPresented.toggle()
        if isIconDebugOverlayPresented {
            isSidebarPlaygroundPresented = false
        }
    }

    func toggleSidebarPlayground() {
        isSidebarPlaygroundPresented.toggle()
        if isSidebarPlaygroundPresented {
            isIconDebugOverlayPresented = false
        }
    }

    func toggleCommandPalettePlayground() {
        isCommandPalettePlaygroundPresented.toggle()
        if isCommandPalettePlaygroundPresented, !isCommandPalettePresented {
            presentCommandPalette()
        }
    }

    func toggleProjectTabsPrototype() {
        isProjectTabsPrototypePresented.toggle()
    }

    func selectNote(id: UUID?) {
        selectedNoteID = id
        selectedTodoID = nil
        isTodoPanePresented = false
        focusedIdleCommandName = nil
    }

    func selectTodo(id: UUID?) {
        selectedNoteID = nil
        selectedTodoID = id
        isTodoPanePresented = true
        focusedIdleCommandName = nil
    }

    func selectTerminal() {
        selectedNoteID = nil
        selectedTodoID = nil
        isTodoPanePresented = false
        focusedIdleCommandName = nil
    }

    @discardableResult
    func closeSelectedNoteIfNeeded() -> Bool {
        guard selectedNoteID != nil else { return false }
        selectNote(id: nil)
        return true
    }

    func toggleAgentGroupCollapsed(_ id: UUID) {
        if collapsedAgentGroupIDs.contains(id) {
            collapsedAgentGroupIDs.remove(id)
        } else {
            collapsedAgentGroupIDs.insert(id)
        }
    }

    func requestAgentGroupClose(sessionID: UUID, allowEmptyWorkspace: Bool = false) {
        pendingAgentGroupCloseAllowsEmptyWorkspace = allowEmptyWorkspace
        pendingAgentGroupCloseSessionID = sessionID
    }

    /// Asks "Close “<name>”?" before `request`'s close stops its program
    /// (`SessionCloseCoordinator.close`).
    func requestTabClose(_ request: TabCloseRequest) {
        pendingTabClose = request
    }

    /// A tab close's question is up, unanswered: "Close “<name>”?" or
    /// "Close Agent Group?". Its answer may detach or end the sessions a
    /// quit's question would list, so a quit waits for it
    /// (`ProjectWindowCloseDelegate.windowAskingToClose`).
    var isAskingToCloseTabs: Bool {
        pendingTabClose != nil || pendingAgentGroupCloseSessionID != nil
    }

    func focusIdleCommand(name: String) {
        selectedNoteID = nil
        selectedTodoID = nil
        isTodoPanePresented = false
        focusedIdleCommandName = name
    }

    var isShowingTerminalContent: Bool {
        selectedNoteID == nil && !isTodoPanePresented && focusedIdleCommandName == nil
    }

    // Wraps the docked-sidebar resize animation with a start/end signal so the
    // terminal can apply its resize strategy. The terminal listens to
    // `isSidebarAnimating` via the chrome state and freezes its `fitToSize`
    // calls (and optionally overlays a snapshot) for the animation's duration.
    private func runDockedAnimation(deltaWidth: CGFloat, _ body: @escaping () -> Void) {
        // Both flags must be set *before* `withAnimation` so the
        // terminal sees them in the same render pass as the eventual
        // `isSidebarHidden` change. The delta in particular needs to
        // be authoritative — it tells the container exactly how much
        // the pane is about to grow or shrink.
        pendingPostAnimationDelta = deltaWidth
        dockedSidebarAnimationDepth += 1
        isSidebarAnimating = true
        withAnimation(.snappy(duration: 0.18)) {
            body()
        }
        let end: @MainActor () -> Void = { [weak self] in
            self?.endDockedAnimation()
        }
        if let schedule = dockedAnimationEndSchedulerForTesting {
            schedule(end)
            return
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.dockedSidebarAnimationStateDuration)
            } catch {
                return
            }
            end()
        }
    }

    private func endDockedAnimation() {
        dockedSidebarAnimationDepth = max(0, dockedSidebarAnimationDepth - 1)
        isSidebarAnimating = dockedSidebarAnimationDepth > 0
        if dockedSidebarAnimationDepth == 0 {
            pendingPostAnimationDelta = 0
        }
    }
}

struct ProjectWindowBinder: NSViewRepresentable {
    let projectRoot: String?
    let workspace: TerminalWorkspace
    let repository: RepositoryWorkspace?
    let noteStore: ProjectNoteStore?
    let todoStore: ProjectTodoStore?
    let chromeState: ProjectWindowChromeState?

    func makeNSView(context: Context) -> NSView {
        let view = ProjectWindowBinderView()
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.repository = repository
        view.noteStore = noteStore
        view.todoStore = todoStore
        view.chromeState = chromeState
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProjectWindowBinderView else { return }
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.repository = repository
        view.noteStore = noteStore
        view.todoStore = todoStore
        view.chromeState = chromeState
        view.registerIfPossible()
    }
}

@MainActor
private final class ProjectWindowBinderView: NSView {
    weak var workspace: TerminalWorkspace?
    weak var repository: RepositoryWorkspace?
    weak var noteStore: ProjectNoteStore?
    weak var todoStore: ProjectTodoStore?
    weak var chromeState: ProjectWindowChromeState?
    weak var boundWindow: NSWindow?
    var projectRoot: String?
    private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?
    private var closeDelegate: ProjectWindowCloseDelegate?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerIfPossible()
    }

    func registerIfPossible() {
        guard let window, let workspace else { return }
        let claimed = ProjectWindowRegistry.shared.register(
            window: window,
            projectRoot: projectRoot,
            workspace: workspace,
            repository: repository,
            noteStore: noteStore,
            todoStore: todoStore,
            chromeState: chromeState
        )
        if !claimed {
            // Another window already owns this project. Close this duplicate
            // and bring the existing one forward. It never restored or saved
            // anything, and hosted tabs only detach.
            if let repository {
                repository.closeAllSessions(intent: .duplicateWindowTeardown)
            } else {
                workspace.closeAllSessions(intent: .duplicateWindowTeardown)
            }
            if let projectRoot {
                _ = ProjectWindowRegistry.shared.focus(projectRoot: projectRoot)
            }
            DispatchQueue.main.async { [weak window] in
                window?.close()
            }
            return
        }
        // Only the window that owns the project restores its saved tabs.
        repository?.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
        let shouldInstallObserver = boundWindow !== window
        boundWindow = window
        installCloseDelegate(for: window)
        if shouldInstallObserver {
            installObserver()
        }
    }

    private func installCloseDelegate(for window: NSWindow) {
        if closeDelegate?.window !== window {
            let delegate = ProjectWindowCloseDelegate(window: window)
            delegate.previousDelegate = window.delegate
            closeDelegate = delegate
            window.delegate = delegate
        } else if window.delegate !== closeDelegate {
            closeDelegate?.previousDelegate = window.delegate
            window.delegate = closeDelegate
        }

        closeDelegate?.projectRoot = projectRoot
        closeDelegate?.workspace = workspace
        closeDelegate?.repository = repository
        closeDelegate?.chromeState = chromeState
    }

    private func installObserver() {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
            self.notificationObserver = nil
        }

        guard let window else { return }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.workspace else { return }
                ProjectWindowRegistry.shared.activateWindow(
                    projectRoot: self.projectRoot,
                    workspace: self.repository?.activeWorkspace ?? workspace,
                    noteStore: self.noteStore,
                    todoStore: self.todoStore,
                    chromeState: self.chromeState
                )
            }
        }
    }

    deinit {
        let notificationObserver = notificationObserver
        let boundWindow = boundWindow
        let closeDelegate = closeDelegate
        let projectRoot = projectRoot

        if let boundWindow {
            Task { @MainActor in
                if let notificationObserver {
                    NotificationCenter.default.removeObserver(notificationObserver)
                }
                if boundWindow.delegate === closeDelegate {
                    boundWindow.delegate = closeDelegate?.previousDelegate
                }
                ProjectWindowRegistry.shared.unregister(window: boundWindow, projectRoot: projectRoot)
            }
        } else if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }
}

@MainActor
final class ProjectWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    weak var workspace: TerminalWorkspace?
    weak var repository: RepositoryWorkspace?
    /// The window's chrome: its closed tabs end with it, and Edit › Undo
    /// acts on them.
    weak var chromeState: ProjectWindowChromeState?
    weak var previousDelegate: NSWindowDelegate?
    var projectRoot: String?
    /// The window's own undo manager, for its text views' typing, in place
    /// of the one AppKit would make for the window: once this delegate
    /// answers `windowWillReturnUndoManager`, AppKit asks it every time.
    private lazy var textUndoManager = UndoManager()
    private var isCloseConfirmed = false
    /// Its close question ("Keep N sessions running…?" or "Close window?")
    /// is on screen, unanswered.
    private(set) var isPresentingCloseAlert = false
    private var shouldCloseAfterSheetEnds = false
    private var closeAfterSheetDetachesTask: Task<Void, Never>?
    private var didCloseWorkspace = false
    /// Whether the window's tabs close keeping their local sessions or
    /// ending them, as its confirmation (or the preference) decided.
    private var closeIntent: SessionCloseIntent?
    /// Its sessions question was answered Keep Running.
    private var answeredKeepRunning = false

    /// The window's running sessions (their host session ids) that its
    /// close keeps in the background because the user chose so: Keep
    /// Running in its question, or Settings › Sessions keeping them without
    /// asking. The launch notice does not name them
    /// (`BackgroundSessionsNotice.noteTold`). Tests replace it.
    static var sessionsKeptInBackground: @MainActor ([String]) -> Void = { ids in
        ProjectWindowRegistry.shared.backgroundSessionsNotice?.noteTold(ids)
    }

    /// Asks about the window's running local sessions: a sheet on the
    /// window, answered once. Tests replace it.
    static var askAboutSessions: @MainActor (
        SessionTeardownQuestion,
        NSWindow,
        @escaping @MainActor (SessionTeardownAnswer, LocalSessionsOnQuit?) -> Void
    ) -> Void = { question, window, answer in
        let alert = question.makeAlert()
        // ViewBridge loads lazily; the alert sheet may be NSRemoteView-backed.
        RemoteViewCrashGuard.installIfNeeded()
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                let answered = SessionTeardownQuestion.answer(of: alert, response: response)
                answer(answered.answer, answered.remember)
            }
        }
    }

    /// "Close window?" for `count` busy programs the close stops, when the
    /// sessions question does not apply: a sheet on the window. Tests
    /// replace it.
    static var confirmStoppingProcesses: @MainActor (
        NSWindow,
        Int,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void = { window, count, answer in
        let alert = NSAlert()
        alert.messageText = "Close window?"
        alert.informativeText = count == 1
            ? "This window has a running process. It will be stopped."
            : "This window has \(count) running processes. They will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in answer(response) }
        }
    }

    init(window: NSWindow) {
        self.window = window
    }

    /// The first of `windows` whose close question is on screen, unanswered
    /// (`isPresentingCloseAlert`), or the question of a close of its tabs
    /// (`ProjectWindowChromeState.isAskingToCloseTabs`): a quit waits for
    /// its answer.
    static func windowAskingToClose(among windows: [NSWindow]) -> NSWindow? {
        windows.first { window in
            guard let delegate = window.delegate as? ProjectWindowCloseDelegate else { return false }
            return delegate.isPresentingCloseAlert || delegate.chromeState?.isAskingToCloseTabs == true
        }
    }

    /// One confirmation at most: the question about the window's running
    /// local sessions (Keep Running, End Sessions), which also names the
    /// busy programs the close stops anyway, or else "Close window?" for
    /// ANY running process the close stops (agents, live commands,
    /// terminals executing a foreground program), or nothing. Settings ›
    /// Sessions can keep or end sessions without asking.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCloseConfirmed else { return true }

        guard let workspace else {
            return previousWindowShouldClose(sender)
        }

        let pathDisplayMode = TerminalSettings.shared.sidebarTerminalPathDisplayMode
        let summary = repository?.teardownSummary(.windowClose, pathDisplayMode: pathDisplayMode)
            ?? workspace.teardownSummary(.windowClose, pathDisplayMode: pathDisplayMode)
        let decision = SessionTeardownConfirmation.decide(
            summary,
            preference: workspace.backendPolicy.settings().localSessionsOnQuit,
            mayAsk: true
        )
        switch decision {
        case .none(let endsSessions):
            closeIntent = SessionTeardown.windowClose.intent(endingSessions: endsSessions)
            let shouldClose = previousWindowShouldClose(sender)
            if !shouldClose { closeIntent = nil }
            return shouldClose
        case .confirmStopping(let count, let endsSessions):
            closeIntent = SessionTeardown.windowClose.intent(endingSessions: endsSessions)
            presentCloseAlert(for: sender, runningProcessCount: count)
            return false
        case .askAboutSessions:
            let projectName = repository?.repositoryName
                ?? workspace.projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
            presentSessionsQuestion(
                SessionTeardownQuestion(teardown: .windowClose, summary: summary, projectName: projectName),
                for: sender
            )
            return false
        }
    }

    /// What Edit › Undo and ⌘Z act on: the window's closed tabs
    /// (`ClosedTabUndoManager`) while no text view has the keyboard
    /// (`ClosedTabUndoRouting`), else the window's own undo manager, as
    /// ever, which text views' typing goes to. Never the previous
    /// delegate's: AppKit did not ask it before either.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let closedTabs = chromeState?.closedTabs,
           ClosedTabUndoRouting.actsOnClosedTabs(firstResponder: window.firstResponder) {
            return closedTabs.undoManager
        }
        return textUndoManager
    }

    func windowWillClose(_ notification: Notification) {
        closeAfterSheetDetachesTask?.cancel()
        closeAfterSheetDetachesTask = nil
        if let window = notification.object as? NSWindow {
            closeWorkspaceIfNeeded()
            ProjectWindowRegistry.shared.unregister(window: window, projectRoot: projectRoot)
        }

        previousDelegate?.windowWillClose?(notification)
    }

    func windowDidEndSheet(_ notification: Notification) {
        previousDelegate?.windowDidEndSheet?(notification)

        guard shouldCloseAfterSheetEnds,
              let window,
              let endedWindow = notification.object as? NSWindow,
              endedWindow === window
        else { return }
        scheduleCloseAfterSheetDetaches(from: window)
    }

    private func presentCloseAlert(for window: NSWindow, runningProcessCount: Int) {
        guard !isPresentingCloseAlert else { return }
        isPresentingCloseAlert = true
        Self.confirmStoppingProcesses(window, runningProcessCount) { [weak self, weak window] response in
            guard let self, let window else { return }
            self.finishCloseAlert(response: response, for: window)
        }
    }

    func finishCloseAlert(response: NSApplication.ModalResponse, for window: NSWindow) {
        isPresentingCloseAlert = false
        guard response == .alertFirstButtonReturn else {
            closeIntent = nil
            return
        }

        isCloseConfirmed = true
        closeWorkspaceIfNeeded()
        shouldCloseAfterSheetEnds = true
        scheduleCloseAfterSheetDetaches(from: window)
    }

    private func presentSessionsQuestion(_ question: SessionTeardownQuestion, for window: NSWindow) {
        guard !isPresentingCloseAlert else { return }
        isPresentingCloseAlert = true
        Self.askAboutSessions(question, window) { [weak self, weak window] answer, remember in
            guard let self, let window else { return }
            self.finishSessionsQuestion(answer, remember: remember, for: window)
        }
    }

    /// The sessions question was answered: Keep Running or End Sessions
    /// closes the window with that intent, as a confirmed "Close window?"
    /// does; Cancel leaves it open. "Don't ask again" stores a Keep or End
    /// answer as the preference. The sessions Keep Running leaves in the
    /// background are ones the user knows about (`closeWorkspaceIfNeeded`).
    func finishSessionsQuestion(_ answer: SessionTeardownAnswer, remember: LocalSessionsOnQuit?, for window: NSWindow) {
        isPresentingCloseAlert = false
        if let remember {
            workspace?.backendPolicy.rememberLocalSessionsOnQuit(remember)
        }
        guard let intent = SessionTeardown.windowClose.intent(for: answer) else { return }
        answeredKeepRunning = answer == .keep

        closeIntent = intent
        isCloseConfirmed = true
        closeWorkspaceIfNeeded()
        shouldCloseAfterSheetEnds = true
        scheduleCloseAfterSheetDetaches(from: window)
    }

    /// `NSAlert` calls its completion while the sheet is still being ordered
    /// out. The delegate's `windowDidEndSheet` callback can arrive before the
    /// completion's MainActor task, so using that single callback as the close
    /// trigger loses a race and leaves a zero-session window behind. Wait for
    /// AppKit's authoritative attachment relationship to clear, then close the
    /// parent directly without replaying the original traffic-light action.
    private func scheduleCloseAfterSheetDetaches(from window: NSWindow) {
        closeAfterSheetDetachesTask?.cancel()
        closeAfterSheetDetachesTask = Task { @MainActor [weak self, weak window] in
            while !Task.isCancelled {
                guard let self,
                      let window,
                      self.shouldCloseAfterSheetEnds
                else { return }

                if window.attachedSheet == nil {
                    self.shouldCloseAfterSheetEnds = false
                    self.closeAfterSheetDetachesTask = nil
                    window.close()
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }
        }
    }

    /// Takes a window whose close was decided off screen at once, before
    /// its tabs are torn down (`closeWorkspaceIfNeeded`), which takes a
    /// while: each tab's adapter or program stops and its surface is freed
    /// (about 20 ms a tab). A window whose close question is still going
    /// away (its sheet is attached) is made transparent instead, as
    /// ordering it out under the sheet would leave the sheet to AppKit; it
    /// closes once the sheet detached (`scheduleCloseAfterSheetDetaches`).
    /// Tests replace it.
    static var takeOffScreen: @MainActor (NSWindow) -> Void = { window in
        window.animationBehavior = .none
        if window.attachedSheet == nil {
            window.orderOut(nil)
        } else {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        // Hands it to the window server now, before the teardown holds the
        // main thread.
        CATransaction.flush()
    }

    /// Closes the window's tabs with the intent its confirmation decided,
    /// once the window left the screen (`takeOffScreen`). A window closed
    /// without it (`window.close()`) follows the preference, and keeps
    /// sessions when it would ask. Sessions it keeps because the user chose
    /// so (Keep Running, or the preference keeping them) are ones the user
    /// knows about (`sessionsKeptInBackground`); those kept only because
    /// nothing asked are not. Tabs closed earlier that ⌘Z could still bring
    /// back go with the window: those closed with ⌘W end
    /// (`ClosedTabHistory.endAll`).
    private func closeWorkspaceIfNeeded() {
        guard !didCloseWorkspace else { return }
        didCloseWorkspace = true
        if let window {
            Self.takeOffScreen(window)
        }
        chromeState?.closedTabs.endAll()
        let preference = workspace?.backendPolicy.settings().localSessionsOnQuit
        let intent = closeIntent ?? SessionTeardown.windowClose.intent(endingSessions: preference == .end)
        if intent == .windowClosed, answeredKeepRunning || preference == .keep {
            // Read before the tabs close: a Create under way when the
            // question was asked may have answered since.
            let summary = repository?.teardownSummary(.windowClose, pathDisplayMode: .fullPath)
                ?? workspace?.teardownSummary(.windowClose, pathDisplayMode: .fullPath)
            let kept = summary?.runningSessions.compactMap(\.hostSessionID) ?? []
            if !kept.isEmpty { Self.sessionsKeptInBackground(kept) }
        }
        if let repository {
            // Save the tabs as they are; the teardown itself saves nothing.
            repository.flushPersistentState()
            repository.closeAllSessions(intent: intent)
        } else {
            workspace?.closeAllSessions(intent: intent)
        }
    }

    private func previousWindowShouldClose(_ sender: NSWindow) -> Bool {
        previousDelegate?.windowShouldClose?(sender) ?? true
    }
}

private struct FocusedWorkspaceKey: FocusedValueKey {
    typealias Value = TerminalWorkspace
}

private struct FocusedChromeStateKey: FocusedValueKey {
    typealias Value = ProjectWindowChromeState
}

extension FocusedValues {
    var terminalWorkspace: TerminalWorkspace? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }

    var projectWindowChromeState: ProjectWindowChromeState? {
        get { self[FocusedChromeStateKey.self] }
        set { self[FocusedChromeStateKey.self] = newValue }
    }
}

/// What the app opens at launch (`ProjectWindowRegistry.launchWindowPlan`).
enum LaunchWindowPlan: Equatable {
    /// The saved windows to reopen: each had tabs and has no window yet.
    case reopen([String])
    /// Nothing to reopen and no window open: the default project's window.
    case openDefault
    /// Nothing: the saved windows are open, or another window is.
    case nothing
}

/// A project window's frame, per project, in the app's defaults. Project
/// windows are not restorable, which also turns off SwiftUI's frame
/// autosave: without this, every window would open at the default size.
/// Unlike that autosave (keyed by the order windows opened in), each project
/// gets its own window's frame back, at launch and when it opens later.
struct ProjectWindowFrameStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(projectRoot: String) -> String {
        "window.frame.\(projectRoot)"
    }

    func frameDescriptor(projectRoot: String) -> NSWindow.PersistableFrameDescriptor? {
        defaults.string(forKey: Self.key(projectRoot: projectRoot))
    }

    /// Saves `window`'s frame, unless it is full screen: the frame it goes
    /// back to when it leaves full screen stays saved.
    @MainActor
    func save(_ window: NSWindow, projectRoot: String) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let descriptor = window.frameDescriptor
        guard frameDescriptor(projectRoot: projectRoot) != descriptor else { return }
        defaults.set(descriptor, forKey: Self.key(projectRoot: projectRoot))
    }

    /// Gives `window` the frame saved for `projectRoot` (AppKit fits it to
    /// the screens there are now). False when none was saved.
    @MainActor
    @discardableResult
    func restore(_ window: NSWindow, projectRoot: String) -> Bool {
        guard let descriptor = frameDescriptor(projectRoot: projectRoot) else { return false }
        window.setFrame(from: descriptor)
        return true
    }
}

/// A project window's sidebar width, per project, in the app's defaults.
/// Not scene storage: that ties the window to AppKit's state restoration,
/// which project windows opt out of (`ProjectWindowRegistry.register`).
struct ProjectSidebarWidthStore {
    static let defaultWidth: Double = 320

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(projectRoot: String) -> String {
        "sidebar.width.\(projectRoot)"
    }

    func width(projectRoot: String) -> Double {
        let key = Self.key(projectRoot: projectRoot)
        guard defaults.object(forKey: key) != nil else { return Self.defaultWidth }
        let width = defaults.double(forKey: key)
        return width.isFinite && width > 0 ? width : Self.defaultWidth
    }

    func setWidth(_ width: Double, projectRoot: String) {
        let key = Self.key(projectRoot: projectRoot)
        guard defaults.object(forKey: key) == nil || defaults.double(forKey: key) != width else { return }
        defaults.set(width, forKey: key)
    }
}
