import AppKit
import CherryControl
import Darwin
import SwiftUI

/// How the registry tells its windows apart: the project's root as the
/// registry resolves it (a device's key, else its real path: the root of
/// the window's frame keys) and the window's id (`ProjectWindowValue.windowID`,
/// nil for the project's primary window). Ordered by root, the primary
/// first, then by id: the stable order walks over every window list them
/// in (the menu bar, the Omni bar's tabs), which focus does not move.
struct ProjectWindowKey: Hashable, Sendable, Comparable {
    let root: String
    let windowID: UUID?

    static func < (lhs: ProjectWindowKey, rhs: ProjectWindowKey) -> Bool {
        guard lhs.root == rhs.root else { return lhs.root < rhs.root }
        switch (lhs.windowID, rhs.windowID) {
        case (nil, nil), (_?, nil): return false
        case (nil, _?): return true
        case let (left?, right?): return left.uuidString < right.uuidString
        }
    }
}

@MainActor
final class ProjectWindowRegistry {
    static let shared = ProjectWindowRegistry()

    /// A registered project window and what it shows. Weak: its scene
    /// owns them.
    private struct WindowEntry {
        weak var window: NSWindow?
        weak var workspace: TerminalWorkspace?
        weak var repository: RepositoryWorkspace?
        weak var todoStore: ProjectTodoStore?
        weak var chromeState: ProjectWindowChromeState?

        /// The workspace the window shows: its repository's.
        var shownWorkspace: TerminalWorkspace? { repository?.workspace ?? workspace }

        func shows(_ workspace: TerminalWorkspace) -> Bool {
            self.workspace === workspace || repository?.workspace === workspace
        }
    }

    /// The registered project windows. A project can have several
    /// (`ProjectWindowValue`): "the project's window" is its most recently
    /// active one (`windowsMostRecentFirst`), "a tab's window" the one
    /// whose workspace has the tab, and code that holds a window or a
    /// workspace finds its entry by identity.
    private var entries: [ProjectWindowKey: WindowEntry] = [:]
    /// The project windows in the order they were last active, the most
    /// recent last.
    private var activationOrder: [ProjectWindowKey] = []
    /// The window active last (`activate`).
    private var activeKey: ProjectWindowKey?
    weak var activeWorkspace: TerminalWorkspace?
    weak var activeTodoStore: ProjectTodoStore?
    weak var activeChromeState: ProjectWindowChromeState?
    /// Where the open project windows are saved for the next launch. The app
    /// sets it through `configureWorkspacePersistence(store:)`; tests leave it
    /// nil, so nothing is written.
    private(set) var workspaceStateStore: WorkspaceStateStore?
    private var projectWindowsToReopenAtLaunch: [ProjectWindowValue] = []
    /// The launch's windows asked for later (`openLaunchWindows`; the front
    /// one is never pending) that have not registered: saved as open
    /// meanwhile, so a quit before they registered keeps them, their saved
    /// tabs awaiting restore (`sessionRecordsAwaitingRestore`), and a quit
    /// that ends sessions ends their saved tabs' (`launchWindowRecords`).
    /// Each leaves as it registers, the rest once the launch's windows
    /// opened.
    private(set) var pendingLaunchWindows: [ProjectWindowValue] = []
    /// Each reopened window's saved tabs as the launch read them
    /// (`projectWindowsToReopen`), for `pendingLaunchWindows`: a quit
    /// reads no file.
    private var launchWindowRecords: [ProjectWindowValue: [WorkspaceSessionRecord]] = [:]
    /// Each launch window's place in the launch's order
    /// (`openLaunchWindows`): windows that registered without becoming
    /// active rank by it (`windowsMostRecentFirst`).
    private var launchOrder: [ProjectWindowKey: Int] = [:]
    /// Runs once a window came on screen (`whenLaunchWindowShown`).
    private var launchWindowShownWaiters: [ProjectWindowKey: [@MainActor () -> Void]] = [:]
    private var shownLaunchWindows: Set<ProjectWindowKey> = []
    /// Waiting for the launch's windows to have opened (`whenLaunchWindowsOpened`).
    private var launchWindowsOpenedWaiters: [@MainActor () -> Void] = []
    private var isOpeningLaunchWindows = false
    /// Runs `body` on the next main-queue turn (tests run it at once).
    var scheduleLaunchWindowTurn: @MainActor (_ body: @escaping @MainActor () -> Void) -> Void = { body in
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
    /// Where the saved tabs of the launch's windows not open yet run
    /// (`pendingLaunchWindows`): a quit that ends sessions ends theirs.
    /// The app sets This Mac's; tests give their own.
    var launchWindowHosting: PersistentLocalSessions?
    private var lastSavedOpenWindows: [ProjectWindowValue]?
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
    /// Shows a project (nil: the default project): focuses its most
    /// recently active window, or opens its primary one. Background
    /// Sessions → Open reopens a closed window's project. The app sets it
    /// (SwiftUI's `openWindow`); tests give their own.
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
    /// How long a newly registered window whose saved tabs are still being
    /// restored stays off screen waiting for them (`ProjectWindowReveal`);
    /// nil shows it at once.
    var windowRevealMaximumWait: Duration? = ProjectWindowReveal.defaultMaximumWait
    /// Hides the windows the launch opens from the moment AppKit orders them
    /// in, before they register (`LaunchWindowCover`). The app sets it;
    /// tests leave it nil or give their own.
    var launchWindowCover: LaunchWindowCover?
    /// Holds the keys typed into a window kept off screen for its tabs
    /// until it shows (`HiddenWindowKeyHold`). The app sets `.shared`;
    /// tests leave it nil or give their own.
    var hiddenWindowKeyHold: HiddenWindowKeyHold?
    /// Where each project window's frame is saved. The app sets it
    /// (`configureWindowFrames`); tests leave it nil unless they give their
    /// own, so the app's defaults are never written.
    private(set) var windowFrameStore: ProjectWindowFrameStore?
    private var windowFrameSavers: [ProjectWindowKey: ProjectWindowFrameSaver] = [:]
    /// Puts a window that was in full screen back into full screen, then
    /// calls its completion (`WindowFullScreenRestore.enter`). Until then
    /// its size is settling (`TerminalWindowSettling`): the persistent tabs
    /// it shows attach at its full-screen size, not at its frame's first.
    /// Tests give their own, so no test window changes Spaces.
    var enterFullScreen: @MainActor (_ window: NSWindow, _ done: @escaping @MainActor () -> Void) -> Void = { window, done in
        let settled = TerminalWindowSettling.shared.hold(window)
        WindowFullScreenRestore.enter(window) {
            settled()
            done()
        }
    }

    /// Whether a saved window of another Mac's project (a `ProjectLocation`
    /// key) can open: its device is still known (`RemoteDeviceStore`).
    /// None by default; the app points it at its device store at launch
    /// (tests inject their own, never the real devices.json).
    var remoteProjectIsKnown: @MainActor (String) -> Bool = { _ in false }

    /// Where each project window's last activation is recorded, for the
    /// project switcher's Recent section (`ProjectRecencyStore`). The app
    /// sets it at launch; tests leave it nil or give their own.
    var projectRecency: ProjectRecencyStore?

    /// The app uses `shared`; tests make their own.
    init() {}

    /// Project windows open at their project's last frame and save it as
    /// they move or resize (`ProjectWindowFrameStore`).
    func configureWindowFrames(_ store: ProjectWindowFrameStore?) {
        windowFrameStore = store
    }

    /// Reads the windows to reopen, with their saved tabs, before any
    /// window registers (registering saves the list again), then saves
    /// window changes to `store`.
    func configureWorkspacePersistence(store: WorkspaceStateStore) {
        guard workspaceStateStore == nil else { return }
        let reopen = store.projectWindowsToReopen(remoteProjectIsKnown: remoteProjectIsKnown)
        projectWindowsToReopenAtLaunch = reopen.map(\.window)
        launchWindowRecords = Dictionary(uniqueKeysWithValues: reopen.map { ($0.window, $0.state.worktrees.flatMap(\.sessions)) })
        workspaceStateStore = store
    }

    /// Project windows that were open when Cherry last quit and had tabs,
    /// once: a later call returns nothing.
    func takeProjectWindowsToReopen() -> [ProjectWindowValue] {
        defer { projectWindowsToReopenAtLaunch = [] }
        return projectWindowsToReopenAtLaunch
    }

    /// Which project windows the app opens at launch, once (a later call
    /// reopens nothing). AppKit restores no project window (they are not
    /// restorable: `CherryApp`), so they come back from this list alone,
    /// whether the app was quit and opened again or macOS relaunched it
    /// after a restart or log out ("Reopen windows when logging back in").
    /// `hasVisibleWindow`: a key-capable window is on screen already (one
    /// a deep link opened).
    func launchWindowPlan(hasVisibleWindow: Bool) -> LaunchWindowPlan {
        let windows = takeProjectWindowsToReopen().filter { !hasWindow($0) }
        if !windows.isEmpty { return .reopen(windows) }
        if hasRegisteredProjectWindow || hasVisibleWindow { return .nothing }
        return .openDefault
    }

    /// The saved windows to reopen, taken now (`launchWindowPlan`), or nil
    /// when there are none. They open at once at launch, without waiting
    /// for a window a deep link opens meanwhile: that window has no value,
    /// so it registers as its project's primary window when none of the
    /// project's windows is there yet, restoring the primary's saved tabs,
    /// and the plan then skips that primary (`hasWindow`) and still opens
    /// the project's other windows. Only opening the default project's
    /// window waits a moment for such a window.
    func savedWindowsLaunchPlan() -> LaunchWindowPlan? {
        guard projectWindowsToReopenAtLaunch.contains(where: { !hasWindow($0) }) else { return nil }
        return launchWindowPlan(hasVisibleWindow: false)
    }

    /// Opens the launch's saved windows front first: `windows[0]` (the
    /// project most recently active, `LaunchWindowOrder.frontFirst`) now,
    /// the others once it came on screen (at most `windowRevealMaximumWait`
    /// later), drew its selected tab (`LaunchContentFrames`, briefly) and
    /// `beforeLaterWindows` let them: together, on one main-queue turn
    /// (building them in one go costs less than one per turn), behind the
    /// window that is key. So the first window's tabs, surfaces and
    /// adapters are not held up by building the others. Until they
    /// register, the others count as open for the saved window list
    /// (`pendingLaunchWindows`), and windows that never become active rank
    /// by this order (`windowsMostRecentFirst`).
    func openLaunchWindows(
        _ windows: [ProjectWindowValue],
        beforeLaterWindows: (@MainActor (_ proceed: @escaping @MainActor () -> Void) -> Void)? = nil,
        open: @escaping @MainActor (ProjectWindowValue) -> Void
    ) {
        guard let front = windows.first else { return }
        let later = Array(windows.dropFirst())
        launchOrder = [:]
        for (index, window) in windows.enumerated() where launchOrder[key(for: window)] == nil {
            launchOrder[key(for: window)] = index
        }
        pendingLaunchWindows = later
        isOpeningLaunchWindows = true
        launchWindowCover?.expect(1)
        open(front)
        guard !later.isEmpty else {
            whenLaunchWindowShown(front, waitingAtMost: windowRevealMaximumWait ?? .zero) { [weak self] in
                self?.finishOpeningLaunchWindows()
            }
            return
        }
        LaunchContentFrames.startWatching()
        whenLaunchWindowShown(front, waitingAtMost: windowRevealMaximumWait ?? .zero) { [weak self] in
            guard let self else { return }
            // The window's new opacity reaches the screen now, not after the
            // next window is built; and the next waits for this one's
            // selected tab to draw (briefly: its adapter may be slow).
            CATransaction.flush()
            let openLater: @MainActor () -> Void = { [weak self] in
                guard let beforeLaterWindows else {
                    self?.openLaterLaunchWindows(later, open: open)
                    return
                }
                beforeLaterWindows { self?.openLaterLaunchWindows(later, open: open) }
            }
            if let window = entries[key(for: front)]?.window {
                LaunchContentFrames.whenContentShown(in: window, waitingAtMost: Self.launchContentWait, openLater)
            } else {
                openLater()
            }
        }
    }

    /// How long the launch's other windows wait for the first one's
    /// terminal content once it showed (`openLaunchWindows`).
    static let launchContentWait: Duration = .milliseconds(150)

    private func openLaterLaunchWindows(_ windows: [ProjectWindowValue], open: @escaping @MainActor (ProjectWindowValue) -> Void) {
        guard let last = windows.last else { return }
        scheduleLaunchWindowTurn { [weak self] in
            guard let self else { return }
            LaunchContentFrames.stopWatching()
            // Quitting: they stay saved as open, and never open now.
            guard !isTerminating else { return }
            for window in windows {
                // One open already is no longer pending; the others are
                // until they register.
                guard !hasWindow(window) else {
                    pendingLaunchWindows.removeAll { $0 == window }
                    continue
                }
                // A window SwiftUI opens becomes key and comes to the
                // front: the window that was key stays so, in front.
                let key = NSApp?.keyWindow
                launchWindowCover?.expect(1)
                open(window)
                if let key, key.isVisible, NSApp?.keyWindow !== key {
                    key.makeKeyAndOrderFront(nil)
                }
            }
            // The launch's windows are open once the last shows.
            whenLaunchWindowShown(last, waitingAtMost: windowRevealMaximumWait ?? .zero) { [weak self] in
                self?.finishOpeningLaunchWindows()
            }
        }
    }

    /// Runs `body` once the launch's saved windows have all come on screen
    /// (`openLaunchWindows`; each waits at most `windowRevealMaximumWait`),
    /// on the next turn when the launch opens none (or has opened them).
    func whenLaunchWindowsOpened(_ body: @escaping @MainActor () -> Void) {
        guard isOpeningLaunchWindows else {
            scheduleLaunchWindowTurn(body)
            return
        }
        launchWindowsOpenedWaiters.append(body)
    }

    /// Runs `body` now, unless a launch window of `repository`'s project is
    /// still to register (`pendingLaunchWindows`): then once the launch's
    /// windows opened (`whenLaunchWindowsOpened`), when that window is
    /// restoring its saved tabs. The project's auto-start waits for it.
    func whenLaunchWindowsOpened(ofProjectOf repository: RepositoryWorkspace, _ body: @escaping @MainActor () -> Void) {
        let root = repositoryRoot(for: repository.repositoryRoot)
        guard isOpeningLaunchWindows, pendingLaunchWindows.contains(where: { key(for: $0).root == root }) else {
            body()
            return
        }
        launchWindowsOpenedWaiters.append(body)
    }

    private func finishOpeningLaunchWindows() {
        guard isOpeningLaunchWindows else { return }
        isOpeningLaunchWindows = false
        // Windows that never registered are no longer open.
        pendingLaunchWindows.removeAll()
        launchWindowRecords.removeAll()
        saveOpenWindowsIfChanged()
        let waiters = launchWindowsOpenedWaiters
        launchWindowsOpenedWaiters.removeAll()
        waiters.forEach { $0() }
    }

    /// Runs `body` once `window` came on screen (its saved tabs in place,
    /// `ProjectWindowReveal`), or `limit` after it was asked (a window that
    /// never registers). Another window of its project showing is not it.
    func whenLaunchWindowShown(_ window: ProjectWindowValue, waitingAtMost limit: Duration, _ body: @escaping @MainActor () -> Void) {
        let key = key(for: window)
        if shownLaunchWindows.contains(key) {
            body()
            return
        }
        var ran = false
        let once: @MainActor () -> Void = {
            guard !ran else { return }
            ran = true
            body()
        }
        launchWindowShownWaiters[key, default: []].append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit.timeInterval) {
            MainActor.assumeIsolated { once() }
        }
    }

    private func launchWindowDidShow(_ key: ProjectWindowKey) {
        shownLaunchWindows.insert(key)
        let waiters = launchWindowShownWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0() }
    }

    /// The sessions a quit that ends sessions would end, in every project
    /// window (`RepositoryWorkspace.localSessionsEndedByAQuit`): the open
    /// persistent tabs' of every host (`PersistentHostingRegistry`: This
    /// Mac's and each device's; they are recorded by host identity), and
    /// the saved tabs' of This Mac.
    func localSessionsEndedByAQuit() -> [(hostID: String, sessionID: String)] {
        entries.values.compactMap(\.repository).flatMap { $0.localSessionsEndedByAQuit() }
            + pendingLaunchWindowRecords().compactMap { record in
                record.hosted.map { (hostID: $0.hostID, sessionID: $0.sessionID) }
            }
    }

    /// The saved tabs of the launch's windows not open yet
    /// (`pendingLaunchWindows`) that may own a session of
    /// `launchWindowHosting`, as the launch read them
    /// (`launchWindowRecords`): a quit that ends sessions ends theirs too.
    private func pendingLaunchWindowRecords() -> [WorkspaceSessionRecord] {
        guard let hosting = launchWindowHosting else { return [] }
        let host = hosting.profile.host
        return pendingLaunchWindows
            .filter { !ProjectLocation.isRemoteKey($0.projectRoot) && !hasWindow($0) }
            .flatMap { launchWindowRecords[$0] ?? [] }
            .filter { $0.mayOwnSession(on: host) }
    }

    /// Saves every window's tabs and the open windows now, synchronously.
    func flushWorkspacePersistence() {
        pruneStaleWindows()
        entries.values.compactMap(\.repository).forEach { $0.flushPersistentState() }
        saveOpenWindowsIfChanged(synchronously: true)
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
        // Repositories first: they stop saving before their workspaces empty.
        for repository in entries.values.compactMap(\.repository) {
            stoppedNativeProgram = repository.closeSessionsForQuit(intent: intent) || stoppedNativeProgram
        }
        for workspace in allWorkspaces() {
            stoppedNativeProgram = workspace.closeSessionsForQuit(intent: intent) || stoppedNativeProgram
        }
        if intent.endsLocalSessions, let hosting = launchWindowHosting {
            // Windows the launch had not opened yet: their saved tabs'
            // sessions end as an open window's would.
            let records = pendingLaunchWindowRecords()
            if !records.isEmpty { hosting.endSessions(ofForgottenTabs: records, recordedIn: workspaceStateStore) }
        }
        return stoppedNativeProgram
    }

    /// Every window's closed tabs that ⌘Z could still bring back go now,
    /// and those closed with ⌘W end (`ClosedTabHistory.endAll`).
    func endClosedTabsAwaitingUndo() {
        pruneStaleWindows()
        for chromeState in entries.values.compactMap(\.chromeState) {
            chromeState.closedTabs.endAll()
        }
    }

    /// Saves the open windows (and the launch's still to register), the
    /// most recently active first, when which windows they are changed; the
    /// quit's synchronous flush also when only their order did. Focus
    /// moving between windows writes nothing.
    private func saveOpenWindowsIfChanged(synchronously: Bool = false) {
        guard let workspaceStateStore, !isTerminating else { return }
        // The repository's own root: its saved tabs are keyed by it, and a
        // reopened window passes it to `RepositoryWorkspace` again.
        var windows = windowsMostRecentFirst().compactMap { key -> ProjectWindowValue? in
            guard let entry = entries[key], entry.window != nil else { return nil }
            return ProjectWindowValue(projectRoot: entry.repository?.repositoryRoot ?? key.root, windowID: key.windowID)
        }
        windows += pendingLaunchWindows.filter { !windows.contains($0) }
        if let lastSavedOpenWindows,
           synchronously ? windows == lastSavedOpenWindows : Set(windows) == Set(lastSavedOpenWindows) {
            return
        }
        lastSavedOpenWindows = windows
        workspaceStateStore.saveOpenProjectWindows(windows, synchronously: synchronously)
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
        lastSavedOpenWindows = nil
        isTerminating = false
    }

    var hasRegisteredProjectWindow: Bool {
        pruneStaleWindows()
        return !entries.isEmpty
    }

    /// A live project window still owned by the registry. AppKit can retain a
    /// closed SwiftUI `NSWindow` in `NSApp.windows`; callers must not use that
    /// broader list for app-reopen routing because the retained scene's
    /// workspace has already been torn down.
    func firstRegisteredProjectWindow() -> NSWindow? {
        pruneStaleWindows()
        if let activeKey, let window = entries[activeKey]?.window {
            return window
        }
        return windowsMostRecentFirst().lazy.compactMap { self.entries[$0]?.window }.first
    }

    /// Live workspaces across every registered project window, in the
    /// windows' stable order (`ProjectWindowKey`).
    func allWorkspaces() -> [TerminalWorkspace] {
        pruneStaleWindows()
        let ordered = entries.sorted { $0.key < $1.key }.map(\.value)
        let repositoryWorkspaces = ordered.compactMap { $0.repository?.workspace }
        let repositoryWorkspaceIDs = Set(repositoryWorkspaces.map(ObjectIdentifier.init))
        let legacyWorkspaces = ordered.compactMap(\.workspace).filter {
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
        let repositorySummary = entries.values.compactMap(\.repository).reduce(SessionTeardownSummary()) {
            $0 + $1.teardownSummary(.quit, pathDisplayMode: pathDisplayMode)
        }
        // Windows without a repository.
        let others = entries.values.compactMap { entry in
            entry.repository == nil ? entry.workspace : nil
        }
        return others.reduce(repositorySummary) { summary, workspace in
            summary + workspace.teardownSummary(
                .quit,
                place: workspace.projectRoot.map(MenuBarAgentPresentation.projectName(projectRoot:)),
                pathDisplayMode: pathDisplayMode
            )
        }
    }

    /// Live workspaces paired with their project's root (`TerminalWorkspace.projectRoot`),
    /// one pair per window in the windows' stable order: two windows of a
    /// project are two pairs with one root. Used to aggregate agents across
    /// every window (e.g. the menu-bar agent list).
    func workspacesByProjectRoot() -> [(projectRoot: String, workspace: TerminalWorkspace)] {
        pruneStaleWindows()
        return allWorkspaces().compactMap { workspace in
            workspace.projectRoot.map { (projectRoot: $0, workspace: workspace) }
        }
    }

    /// Brings a tab to the foreground: focuses the window whose workspace
    /// has it, selects it and switches that window to the terminal view.
    /// False when no window has it. Used by the menu-bar agent list's
    /// click-to-focus.
    @discardableResult
    func revealSession(id sessionID: UUID) -> Bool {
        guard let key = windowKey(containing: sessionID),
              let entry = entries[key],
              let workspace = entry.shownWorkspace,
              let session = workspace.sessions.first(where: { $0.id == sessionID }),
              focus(key)
        else { return false }
        workspace.select(session)
        entry.chromeState?.selectTerminal()
        return true
    }

    // MARK: Commands across a project's windows

    /// The workspaces of the other open windows of `repository`'s project,
    /// the most recently active first: a project's commands run in one tab
    /// across its windows (`TerminalWorkspace.otherProjectWindows`).
    func otherWorkspaces(ofProjectOf repository: RepositoryWorkspace) -> [TerminalWorkspace] {
        otherEntries(ofProjectOf: repository).compactMap(\.shownWorkspace).filter { !$0.isTornDown }
    }

    /// The repositories of the other open windows of `repository`'s
    /// project, the most recently active first: what the project's
    /// auto-start waits for (`RepositoryWorkspace.commandNamesAutoStartWaitsFor`).
    func otherRepositories(ofProjectOf repository: RepositoryWorkspace) -> [RepositoryWorkspace] {
        otherEntries(ofProjectOf: repository).compactMap(\.repository).filter { !$0.isTearingDown }
    }

    /// Another window of the project applied a restore step: the
    /// auto-starts that waited for its saved tabs may start
    /// (`RepositoryWorkspace.startAutoStartsNoLongerWaiting`).
    func restoreStepApplied(in repository: RepositoryWorkspace) {
        otherRepositories(ofProjectOf: repository).forEach { $0.startAutoStartsNoLongerWaiting() }
    }

    /// The entries of `repository`'s project's windows other than its own,
    /// the most recently active first; none while it is not registered.
    private func otherEntries(ofProjectOf repository: RepositoryWorkspace) -> [WindowEntry] {
        pruneStaleWindows()
        guard let root = entries.first(where: { $0.value.repository === repository })?.key.root else { return [] }
        return windowsMostRecentFirst().compactMap { key in
            guard key.root == root, let entry = entries[key], entry.repository !== repository else { return nil }
            return entry
        }
    }

    // MARK: Background sessions

    /// The repository of every open project window, in the windows' stable
    /// order.
    var allRepositories: [RepositoryWorkspace] {
        pruneStaleWindows()
        return entries.sorted { $0.key < $1.key }.compactMap(\.value.repository)
    }

    /// Saved tabs the open windows may still restore
    /// (`RepositoryWorkspace.savedRecordsAwaitingRestore`), and those of
    /// the launch's windows that have not registered yet
    /// (`pendingLaunchWindows`, as the launch read them): a window still to
    /// open brings its sessions back itself, so they are not in the
    /// background meanwhile.
    func sessionRecordsAwaitingRestore() -> [WorkspaceSessionRecord] {
        allRepositories.flatMap { $0.savedRecordsAwaitingRestore() }
            + pendingLaunchWindows.filter { !hasWindow($0) }.flatMap { launchWindowRecords[$0] ?? [] }
    }

    /// The repository of a window of `projectRoot`'s project once one has
    /// registered (`repository(for:)`), polling, or nil after `timeout`.
    func waitForRepository(projectRoot: String, timeout: Duration = .seconds(10)) async -> RepositoryWorkspace? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let repository = repository(for: projectRoot) { return repository }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return repository(for: projectRoot)
    }

    /// Background Sessions → Open: shows a session of this app that no open
    /// tab shows. Its project (`cherry.project`, a folder) names the
    /// window: the project's most recently active one, or else the
    /// project's primary window is opened, and its restore brings a closed
    /// window's session back with its sibling tabs and layout. Once that
    /// window's restore and look for orphaned
    /// sessions are done, the session's tab is revealed: the one that shows
    /// it now, or else it is adopted into that window
    /// (`RepositoryWorkspace.showBackgroundSession`). A session with no
    /// project, or whose window does not open, goes to the active window.
    func showBackgroundSession(
        _ info: HostedSessionInfo,
        localSessions: PersistentLocalSessions,
        attachedTabs: OpenHostedTabs = .shared,
        restoreWait: Duration = .seconds(10)
    ) async {
        let project = OrphanedSessionCriteria.projectRoot(of: info)
        var repository = project.flatMap { self.repository(for: $0) }
        if repository == nil, let project,
           let root = AgentSettings.shared.repositoryRoot(for: project), let opener = projectWindowOpener {
            opener(root)
            repository = await waitForRepository(projectRoot: root)
        }
        // A device's session shows only in a window of its project there,
        // never in one of This Mac's (docs/specs/remote-devices.md).
        let isDevice = !localSessions.profile.isThisMac
        if repository == nil, !isDevice {
            repository = activeKey.flatMap { self.entries[$0]?.repository } ?? allRepositories.first
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
        _ = focus(workspace: repository.workspace)
        await repository.waitUntilSessionsRestored(before: ContinuousClock.now + restoreWait)

        let hostID = localSessions.control.hostID
        if let shown = localSessions.owningTab(of: info.id)
            ?? hostID.flatMap({ attachedTabs.tab(showingSession: info.id, hostID: $0) }) {
            revealSession(id: shown.id)
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
                hosting: localSessions
              )
        else { return }
        revealSession(id: tab.id)
    }

    /// The workspace of `projectRoot`'s project's most recently active
    /// window, or of its primary one, opened again (`projectWindowOpener`)
    /// when none is open, then given the
    /// time its restore takes: where a toast's Reopen attaches a session
    /// again after its tab closed, perhaps with its window. nil when no
    /// window shows or opens for it.
    func workspaceOpeningWindow(
        projectRoot: String,
        restoreWait: Duration = .seconds(10)
    ) async -> TerminalWorkspace? {
        if let workspace = workspace(for: projectRoot) {
            return workspace
        }
        guard let root = AgentSettings.shared.repositoryRoot(for: projectRoot), let opener = projectWindowOpener else {
            return nil
        }
        opener(root)
        guard let repository = await waitForRepository(projectRoot: root) else { return nil }
        await repository.waitUntilSessionsRestored(before: ContinuousClock.now + restoreWait)
        return repository.workspace
    }

    /// Every root that can be focused through an open project window: each
    /// window's key and its tabs' folder.
    var knownProjectRoots: [String] {
        pruneStaleWindows()
        let repositoryRoots = entries.values.compactMap { $0.repository?.workspaceRoot }
        return Array(Set(repositoryRoots + entries.keys.map(\.root))).sorted()
    }

    /// Each project with an open window, by its key
    /// (`canonicalProjectRoot`), with how many agents of its windows are
    /// working (the Omni bar's project status).
    func openProjectWindowStatuses() -> [String: ProjectSwitcherModel.OpenStatus] {
        pruneStaleWindows()
        var statuses: [String: ProjectSwitcherModel.OpenStatus] = [:]
        for (key, entry) in entries where entry.window != nil {
            var status = statuses[key.root] ?? ProjectSwitcherModel.OpenStatus(workingAgents: 0)
            if let workspace = entry.shownWorkspace {
                status.workingAgents += workspace.agentSessions.filter { $0.agentActivityState == .working }.count
            }
            statuses[key.root] = status
        }
        return statuses
    }

    func canonicalProjectRoot(for projectRoot: String) -> String {
        repositoryRoot(for: projectRoot)
    }

    /// Whether any window of `projectRoot`'s project is open.
    func hasWindow(for projectRoot: String) -> Bool {
        pruneStaleWindows()
        let root = repositoryRoot(for: projectRoot)
        return entries.contains { $0.key.root == root && $0.value.window != nil }
    }

    /// Whether the window `window` names is open (a project's other windows
    /// are not it).
    func hasWindow(_ window: ProjectWindowValue) -> Bool {
        pruneStaleWindows()
        return entries[key(for: window)]?.window != nil
    }

    func projectRoot(forProjectKey projectKey: String) -> String? {
        pruneStaleWindows()
        let normalizedKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var roots = entries.values.compactMap { $0.repository?.workspaceRoot }
        roots.append(contentsOf: entries.keys.map(\.root))
        roots.append(contentsOf: AgentSettings.shared.projects.map(\.root))
        if let activeKey {
            roots.append(activeKey.root)
        }

        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            if CherryDeepLink.projectKey(forProjectRoot: root) == normalizedKey {
                return root
            }
        }
        return nil
    }

    /// The workspace of `projectRoot`'s project's most recently active
    /// window.
    func workspace(for projectRoot: String) -> TerminalWorkspace? {
        mostRecentlyActiveKey(ofProject: projectRoot).flatMap { entries[$0]?.shownWorkspace }
    }

    /// Workspace belonging to the current key window. Menu actions must
    /// resolve their target through this rather than SwiftUI focused values:
    /// `@FocusedValue` only updates while the SwiftUI hierarchy owns focus,
    /// so with the AppKit terminal view as first responder it can keep
    /// pointing at a previously focused window.
    var keyWindowWorkspace: TerminalWorkspace? {
        pruneStaleWindows()
        return key(of: NSApp.keyWindow).flatMap { entries[$0]?.workspace }
    }

    /// Repository belonging to the current key window. Used with
    /// `keyWindowWorkspace` when a menu action needs repository-wide state.
    var keyWindowRepository: RepositoryWorkspace? {
        pruneStaleWindows()
        return key(of: NSApp.keyWindow).flatMap { entries[$0]?.repository }
    }

    /// Chrome state belonging to the current key window. See
    /// `keyWindowWorkspace` for why menu actions resolve through this.
    var keyWindowChromeState: ProjectWindowChromeState? {
        pruneStaleWindows()
        return key(of: NSApp.keyWindow).flatMap { entries[$0]?.chromeState }
    }

    func window(for chromeState: ProjectWindowChromeState) -> NSWindow? {
        pruneStaleWindows()
        return entries.values.first { $0.chromeState === chromeState }?.window
    }

    /// The repository of the window `chromeState` belongs to.
    func repository(for chromeState: ProjectWindowChromeState) -> RepositoryWorkspace? {
        pruneStaleWindows()
        return entries.values.first { $0.chromeState === chromeState }?.repository
    }

    /// The window that shows `workspace`, never another window of its
    /// project.
    func window(for workspace: TerminalWorkspace) -> NSWindow? {
        pruneStaleWindows()
        return key(showing: workspace).flatMap { entries[$0]?.window }
    }

    /// The chrome state of the window that shows `workspace`: where its
    /// tabs' close questions, toasts and ⌘Z belong.
    func chromeState(for workspace: TerminalWorkspace) -> ProjectWindowChromeState? {
        pruneStaleWindows()
        return key(showing: workspace).flatMap { entries[$0]?.chromeState }
    }

    /// A project window on screen (`windowIsOnScreen`) other than `window`
    /// (and the one `chromeState` belongs to), the one active most recently
    /// first: where a toast goes about a tab whose window closed with it.
    /// Its workspace is its repository's.
    func mostRecentlyActiveProjectWindow(
        excluding window: NSWindow?,
        chromeState excludedChromeState: ProjectWindowChromeState?
    ) -> (chromeState: ProjectWindowChromeState, workspace: TerminalWorkspace, repository: RepositoryWorkspace?)? {
        pruneStaleWindows()
        for key in windowsMostRecentFirst() {
            guard let entry = entries[key],
                  let candidate = entry.window, candidate !== window, windowIsOnScreen(candidate),
                  let chromeState = entry.chromeState, chromeState !== excludedChromeState,
                  let workspace = entry.workspace
            else { continue }
            let repository = entry.repository
            return (chromeState, repository?.workspace ?? workspace, repository)
        }
        return nil
    }

    /// The workspace of the frontmost window of a project on This Mac: the
    /// key window's when it is one, else the one active most recently.
    func frontmostLocalWorkspace() -> TerminalWorkspace? {
        pruneStaleWindows()
        if let key = key(of: NSApp.keyWindow), !ProjectLocation.isRemoteKey(key.root),
           let workspace = entries[key]?.shownWorkspace {
            return workspace
        }
        for key in windowsMostRecentFirst() where !ProjectLocation.isRemoteKey(key.root) {
            guard let entry = entries[key], entry.window != nil, let workspace = entry.shownWorkspace else { continue }
            return workspace
        }
        return nil
    }

    /// The to-do store of `projectRoot`'s project's most recently active
    /// window.
    func todoStore(for projectRoot: String) -> ProjectTodoStore? {
        mostRecentlyActiveKey(ofProject: projectRoot).flatMap { entries[$0]?.todoStore }
    }

    /// The chrome state of `projectRoot`'s project's most recently active
    /// window.
    func chromeState(for projectRoot: String) -> ProjectWindowChromeState? {
        mostRecentlyActiveKey(ofProject: projectRoot).flatMap { entries[$0]?.chromeState }
    }

    /// The chrome state of the project window `window`: where a notice
    /// about it shows its toast.
    func chromeState(for window: NSWindow) -> ProjectWindowChromeState? {
        pruneStaleWindows()
        return key(of: window).flatMap { entries[$0]?.chromeState }
    }

    /// Claims `window` for its key: the project of `projectRoot` and its
    /// window `windowID` (nil: the project's primary window). Refused when
    /// another window has that key, and, for an `implicit` window (opened
    /// with no value, or with one whose project did not open: SwiftUI's
    /// own, a URL event, onboarding), while any window of its project is
    /// open: it claims its project's primary only while none of the
    /// project's windows is. The caller then closes it. A window registers
    /// again on every update of its view, which claims nothing new.
    @discardableResult
    func register(
        window: NSWindow,
        projectRoot: String?,
        windowID: UUID? = nil,
        implicit: Bool = false,
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace? = nil,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) -> Bool {
        guard let requestedRoot = projectRoot else { return false }
        pruneStaleWindows()
        let key = ProjectWindowKey(root: repositoryRoot(for: requestedRoot), windowID: windowID)
        let isNewClaim = entries[key]?.window !== window
        if isNewClaim {
            // Another window already owns this key. Refuse to claim the
            // slot so the caller can close this duplicate. SwiftUI's
            // WindowGroup<Value> can spawn an extra default (value=nil)
            // window alongside the persisted one during scene restoration —
            // without this guard, the second registration overwrites the
            // first and both windows fight for the same workspace state.
            if entries[key]?.window != nil { return false }
            if implicit, entries.contains(where: { $0.key.root == key.root && $0.value.window != nil }) {
                return false
            }
        }
        // Cherry saves and reopens its windows, their tabs and frames
        // itself (`ProjectWindowFrameStore`). AppKit's restorable state
        // would only cost typing: while keys arrive it re-encodes and
        // snapshots the window on the main thread (25–135 ms stalls, longer
        // for bigger windows).
        window.isRestorable = false
        if isNewClaim {
            // The window that opens its project starts the project's
            // auto-start commands; another window of it does not.
            repository?.opensProject = !entries.contains { $0.key.root == key.root && $0.key != key && $0.value.window != nil }
            // Newly claimed: it takes the frame this window last had, and a
            // launch window no longer waits to register.
            pendingLaunchWindows.removeAll { self.key(for: $0) == key }
            launchWindowRecords = launchWindowRecords.filter { self.key(for: $0.key) != key }
            let restoresFullScreen = adoptSavedFrame(of: window, key: key)
            let name = URL(fileURLWithPath: key.root).lastPathComponent
            LaunchTimeline.mark("window registered \(name) visible=\(window.isVisible)")
            // A window whose saved tabs are still being restored stays off
            // screen until they are in place (at most a second): it never
            // shows empty first. It registers before AppKit first draws it.
            let coveredAtLaunch = launchWindowCover?.claim(window) ?? false
            let keyHold = hiddenWindowKeyHold ?? launchWindowCover?.keyHold
            let shown: @MainActor () -> Void = { [weak self, weak window] in
                // Before the reveal's layout and the keys held meanwhile.
                if let self, let window { self.focusSelectedTerminal(in: window, key: key) }
                self?.launchWindowDidShow(key)
            }
            if let maximumWait = windowRevealMaximumWait,
               let gate = ProjectWindowReveal.hold(
                   window, until: repository, name: name, alreadyHidden: coveredAtLaunch, holdsAnyway: restoresFullScreen,
                   maximumWait: maximumWait, keyHold: keyHold, onShow: shown
               ) {
                // Shown by the gate; a window that was in full screen once it
                // is again, so it never shows windowed first.
                if restoresFullScreen {
                    enterFullScreen(window, gate.waitAlso(atMost: WindowFullScreenRestore.maximumWait))
                }
            } else {
                if coveredAtLaunch {
                    window.alphaValue = 1
                    window.ignoresMouseEvents = false
                }
                if restoresFullScreen {
                    enterFullScreen(window) {}
                }
                shown()
                keyHold?.release(window)
            }
        }
        // The stores a registration leaves out stay as they were.
        var entry = entries[key] ?? WindowEntry()
        entry.window = window
        entry.workspace = workspace
        entry.repository = repository ?? entry.repository
        entry.todoStore = todoStore ?? entry.todoStore
        entry.chromeState = chromeState ?? entry.chromeState
        entries[key] = entry
        if let repository {
            repository.windowRegistry = self
        }

        if activeWorkspace == nil || window.isKeyWindow || window.isMainWindow {
            activate(
                key: key,
                workspace: workspace,
                todoStore: todoStore,
                chromeState: chromeState
            )
        }
        saveOpenWindowsIfChanged()
        instanceLockNotice?.projectWindowDidRegister(window)
        backgroundSessionsNotice?.projectWindowDidRegister(window)
        return true
    }

    /// A window that comes on screen with its restored tabs takes keys at
    /// once: its selected tab's terminal becomes first responder as it
    /// shows, before the reveal's layout pass and the keys typed while it
    /// was off screen (`HiddenWindowKeyHold`), rather than on a turn after
    /// them (its container's own request, which then finds it done). Only
    /// a key window showing its terminal (not a to-do or the Omni bar), and
    /// only the terminal of that window.
    private func focusSelectedTerminal(in window: NSWindow, key: ProjectWindowKey) {
        guard window.isKeyWindow,
              let entry = entries[key],
              let workspace = entry.workspace,
              entry.chromeState.map({ $0.isShowingTerminalContent && !$0.isOmniBarPresented }) ?? true,
              let bridge = workspace.selectedSession?.loadedGhosttyBridge,
              bridge.terminalView.window === window
        else { return }
        bridge.focus(in: window)
    }

    /// Gives a newly claimed project window the frame saved for it (by its
    /// key: a project's primary window's or another one's), and saves the
    /// frame from then on. True when the window was in full screen when it
    /// was saved and is not now: the caller puts it back.
    @discardableResult
    private func adoptSavedFrame(of window: NSWindow, key: ProjectWindowKey) -> Bool {
        windowFrameSavers.removeValue(forKey: key)
        guard let windowFrameStore else { return false }
        windowFrameStore.restore(window, projectRoot: key.root, windowID: key.windowID)
        let restoresFullScreen = windowFrameStore.isFullScreen(projectRoot: key.root, windowID: key.windowID)
            && !window.styleMask.contains(.fullScreen)
        windowFrameSavers[key] = ProjectWindowFrameSaver(
            window: window,
            projectRoot: key.root,
            windowID: key.windowID,
            store: windowFrameStore,
            isTerminating: { [weak self] in self?.isTerminating ?? false }
        )
        return restoresFullScreen
    }

    /// Forgets `window`, registered for `projectRoot`'s project (by
    /// identity: the project's other windows stay).
    func unregister(window: NSWindow, projectRoot: String?) {
        guard let requestedRoot = projectRoot else { return }
        let root = repositoryRoot(for: requestedRoot)
        guard let key = entries.first(where: { $0.key.root == root && $0.value.window === window })?.key else { return }
        windowFrameSavers[key]?.saveNow()
        let wasActive = forgetWindow(key)
        saveOpenWindowsIfChanged()
        if wasActive {
            refreshActiveWindow()
            Task { @MainActor in
                ProjectWindowRegistry.shared.refreshActiveWindow()
            }
        }
    }

    /// Brings `projectRoot`'s project's most recently active window
    /// forward. False when none of its windows is open.
    func focus(projectRoot: String) -> Bool {
        guard let key = mostRecentlyActiveKey(ofProject: projectRoot) else { return false }
        return focus(key)
    }

    /// Brings the window that shows `workspace` forward, never another
    /// window of its project.
    @discardableResult
    func focus(workspace: TerminalWorkspace) -> Bool {
        pruneStaleWindows()
        guard let key = key(showing: workspace) else { return false }
        return focus(key)
    }

    private func focus(_ key: ProjectWindowKey) -> Bool {
        // A window that closed is forgotten by the next `pruneStaleWindows`.
        guard let entry = entries[key], let window = entry.window else { return false }
        if let workspace = entry.shownWorkspace {
            activate(
                key: key,
                workspace: workspace,
                todoStore: entry.todoStore,
                chromeState: entry.chromeState
            )
        } else {
            AgentSettings.shared.markProjectOpened(key.root)
        }
        bringWindowForward(window)
        return true
    }

    /// Selects what `deepLink` names and brings its window forward: a tab
    /// in the window of `projectRoot`'s project that has it, a to-do in the
    /// project's most recently active window. False, focusing nothing, when
    /// no window of the project can show it.
    @discardableResult
    func select(_ deepLink: CherryDeepLink, projectRoot: String) -> Bool {
        guard CherryDeepLink.projectKey(forProjectRoot: projectRoot) == deepLink.projectKey else {
            return false
        }

        switch deepLink.kind {
        case .todo:
            guard AgentSettings.shared.projectFeatures(for: projectRoot).todosEnabled else {
                return false
            }
            guard let todoID = UUID(uuidString: deepLink.targetID),
                  let key = mostRecentlyActiveKey(ofProject: projectRoot),
                  let chromeState = entries[key]?.chromeState,
                  entries[key]?.todoStore?.todos.contains(where: { $0.id == todoID }) == true,
                  focus(key)
            else {
                return false
            }
            chromeState.selectTodo(id: todoID)
            return true
        case .terminal:
            guard let sessionID = UUID(uuidString: deepLink.targetID),
                  let key = windowKey(containing: sessionID, projectRoot: projectRoot),
                  let chromeState = entries[key]?.chromeState,
                  let workspace = entries[key]?.shownWorkspace,
                  let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  focus(key)
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
        guard let activeKey else { return }
        AgentSettings.shared.markProjectOpened(activeKey.root)
    }

    /// `window` became key: it is its project's most recently active window.
    func activateWindow(
        _ window: NSWindow,
        workspace: TerminalWorkspace,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) {
        guard let key = key(of: window) else { return }
        activate(
            key: key,
            workspace: workspace,
            todoStore: todoStore,
            chromeState: chromeState
        )
    }

    func projectRoot(containing sessionID: UUID) -> String? {
        pruneStaleWindows()
        for repository in entries.values.compactMap(\.repository) where repository.contains(sessionID: sessionID) {
            return repository.workspaceRoot
        }
        return entries.values.compactMap(\.workspace).first { workspace in
            workspace.sessions.contains { $0.id == sessionID }
        }?.projectRoot
    }

    func isSessionVisible(_ session: TerminalSession) -> Bool {
        pruneStaleWindows()

        for entry in entries.values {
            guard let workspace = entry.workspace,
                  workspace.sessions.contains(where: { $0.id == session.id }),
                  entry.chromeState?.isShowingTerminalContent ?? true,
                  let window = entry.window
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

    /// Shows a tab: selects it in the window whose workspace has it (among
    /// `requestedProjectRoot`'s project's windows when one is given) and
    /// brings that window forward. False when no window has it.
    @discardableResult
    func focusSession(sessionID: UUID, projectRoot requestedProjectRoot: String?) -> Bool {
        guard let key = windowKey(containing: sessionID, projectRoot: requestedProjectRoot),
              let entry = entries[key],
              let workspace = entry.shownWorkspace,
              let session = workspace.sessions.first(where: { $0.id == sessionID })
        else { return false }
        let chrome = entry.chromeState
        _ = focus(key)
        workspace.select(session)
        chrome?.selectTerminal()
        session.acknowledgeAgentResult()
        return true
    }

    private func activate(
        key: ProjectWindowKey,
        workspace: TerminalWorkspace,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?,
        recordsOpening: Bool = true
    ) {
        activationOrder.removeAll { $0 == key }
        activationOrder.append(key)
        // Recency and the last opened project are the project's.
        projectRecency?.markOpened(key.root)
        activeKey = key
        activeWorkspace = workspace
        activeTodoStore = todoStore
        activeChromeState = chromeState
        if recordsOpening {
            // On the next turn: a window registers (and activates) from
            // inside a SwiftUI view update, where changing the settings'
            // published values is not allowed.
            let repositoryRoot = key.root
            DispatchQueue.main.async {
                AgentSettings.shared.markProjectOpened(repositoryRoot)
            }
        }

        if NSApplication.shared.isActive,
           chromeState?.isShowingTerminalContent ?? true {
            workspace.clearUnreadNotificationForSelectedSession()
            workspace.acknowledgeAgentResultForSelectedSession()
        }
    }

    private func acknowledgeActiveVisibleSession() {
        guard NSApplication.shared.isActive,
              activeChromeState?.isShowingTerminalContent ?? true
        else {
            return
        }

        activeWorkspace?.clearUnreadNotificationForSelectedSession()
        activeWorkspace?.acknowledgeAgentResultForSelectedSession()
    }

    /// The repository of `projectRoot`'s project's most recently active
    /// window.
    func repository(for projectRoot: String) -> RepositoryWorkspace? {
        mostRecentlyActiveKey(ofProject: projectRoot).flatMap { entries[$0]?.repository }
    }

    private func refreshActiveWindow() {
        pruneStaleWindows()
        guard let key = key(of: NSApp.keyWindow) ?? key(of: NSApp.mainWindow),
              let entry = entries[key],
              let workspace = entry.workspace
        else {
            return
        }

        activate(
            key: key,
            workspace: workspace,
            todoStore: entry.todoStore,
            chromeState: entry.chromeState
        )
    }

    /// The registry's key of `window`, a saved or scene value.
    func key(for window: ProjectWindowValue) -> ProjectWindowKey {
        ProjectWindowKey(root: repositoryRoot(for: window.projectRoot), windowID: window.windowID)
    }

    /// The key `window` is registered under, by identity.
    func key(of window: NSWindow?) -> ProjectWindowKey? {
        guard let window else { return nil }
        return entries.first { _, entry in
            entry.window === window
        }?.key
    }

    /// The key of the window that shows `workspace`, by identity.
    private func key(showing workspace: TerminalWorkspace) -> ProjectWindowKey? {
        entries.first { $0.value.shows(workspace) }?.key
    }

    /// The window whose workspace has the tab `sessionID` (a tab is open in
    /// one window only), among `projectRoot`'s project's windows when one
    /// is given.
    private func windowKey(containing sessionID: UUID, projectRoot: String? = nil) -> ProjectWindowKey? {
        pruneStaleWindows()
        let root = projectRoot.map(repositoryRoot(for:))
        return entries.sorted { $0.key < $1.key }.first { key, entry in
            (root == nil || key.root == root)
                && entry.shownWorkspace?.sessions.contains { $0.id == sessionID } == true
        }?.key
    }

    /// "The project's window": the most recently active registered window
    /// of `projectRoot`'s project.
    private func mostRecentlyActiveKey(ofProject projectRoot: String) -> ProjectWindowKey? {
        pruneStaleWindows()
        let root = repositoryRoot(for: projectRoot)
        return windowsMostRecentFirst().first { $0.root == root }
    }

    /// Every registered window, the most recently active first: the
    /// activation order, then windows never active in the launch's order
    /// (they registered behind the key window), then the rest in their
    /// stable order.
    private func windowsMostRecentFirst() -> [ProjectWindowKey] {
        let activated = activationOrder.reversed().filter { entries[$0] != nil }
        let others = entries.keys.filter { !activationOrder.contains($0) }.sorted { left, right in
            switch (launchOrder[left], launchOrder[right]) {
            case let (leftIndex?, rightIndex?): leftIndex < rightIndex
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): left < right
            }
        }
        return activated + others
    }

    private func repositoryRoot(for projectRoot: String) -> String {
        // A project on another Mac is its key, never a path here.
        if ProjectLocation.isRemoteKey(projectRoot) { return ProjectLocation(key: projectRoot).key }
        return RepositoryWorkspace.resolvedPath(projectRoot)
    }

    private func pruneStaleWindows() {
        let staleKeys = entries.compactMap { key, entry in
            entry.window == nil || entry.workspace == nil ? key : nil
        }
        for key in staleKeys {
            forgetWindow(key)
        }
    }

    /// Forgets the window registered under `key` with its frame saver and
    /// its place in the activation and launch orders. True when it was the
    /// active window, which none is now.
    @discardableResult
    private func forgetWindow(_ key: ProjectWindowKey) -> Bool {
        entries.removeValue(forKey: key)
        windowFrameSavers.removeValue(forKey: key)
        activationOrder.removeAll { $0 == key }
        launchOrder.removeValue(forKey: key)
        guard activeKey == key else { return false }
        activeKey = nil
        activeWorkspace = nil
        activeTodoStore = nil
        activeChromeState = nil
        return true
    }
}

/// Saves a project window's frame (`ProjectWindowFrameStore`) whenever it
/// moves or resizes; a live resize once, when it ends. Whether it is in full
/// screen is saved as it enters and leaves full screen, except while the app
/// quits or the window closes: a window that was in full screen then comes
/// back in full screen.
@MainActor
final class ProjectWindowFrameSaver: NSObject {
    private weak var window: NSWindow?
    private let projectRoot: String
    /// The window's id (`ProjectWindowValue.windowID`); nil for the
    /// project's primary window.
    private let windowID: UUID?
    private let store: ProjectWindowFrameStore
    private let isTerminating: @MainActor () -> Bool
    private var isClosing = false

    init(
        window: NSWindow,
        projectRoot: String,
        windowID: UUID? = nil,
        store: ProjectWindowFrameStore,
        center: NotificationCenter = .default,
        isTerminating: @escaping @MainActor () -> Bool = { false }
    ) {
        self.window = window
        self.projectRoot = projectRoot
        self.windowID = windowID
        self.store = store
        self.isTerminating = isTerminating
        super.init()
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
        ] {
            // Removed when the saver goes (selector-based observation).
            center.addObserver(self, selector: #selector(frameDidChange(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(fullScreenDidChange(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(fullScreenDidChange(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func frameDidChange(_ notification: Notification) {
        guard let window else { return }
        if notification.name == NSWindow.didResizeNotification, window.inLiveResize { return }
        store.save(window, projectRoot: projectRoot, windowID: windowID)
    }

    @objc private func fullScreenDidChange(_ notification: Notification) {
        let entered = notification.name == NSWindow.didEnterFullScreenNotification
        // A window that leaves full screen because it closes, or the app
        // quits, was in full screen for the next launch.
        if !entered, isClosing || isTerminating() { return }
        store.setFullScreen(entered, projectRoot: projectRoot, windowID: windowID)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        isClosing = true
    }

    func saveNow() {
        guard let window else { return }
        store.save(window, projectRoot: projectRoot, windowID: windowID)
    }
}

/// What the Omni bar opened with (⌘P: the root; ⌘O and the title-bar
/// project button: Projects). A new request while it is open moves it
/// there.
struct OmniBarRequest: Equatable {
    var scope: OmniScope?
    var id: Int
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
    /// The Omni bar, shown while set (`OmniBarView`).
    @Published private(set) var omniBar: OmniBarRequest?
    /// Bumped by ⌘K while the Omni bar is open: its action list
    /// (`AppShortcutMonitor`).
    @Published private(set) var omniBarActionsRequest = 0
    @Published var isHostedSessionsPresented = false
    /// The host the Persistent Sessions sheet opens on (a device's, from
    /// the picker), taken by the sheet when it appears.
    @Published var hostedSessionsInitialHost: HostedSessionHost?
    /// Add Mac… (docs/specs/remote-devices.md).
    @Published var isAddDevicePresented = false
    /// Add Project on <Mac>…: the device.
    @Published var addProjectDevice: RemoteDeviceReference?
    @Published var isTerminalSearchPresented = false
    @Published var terminalSearchFocusRequest = 0
    @Published var isSidebarPlaygroundPresented = false
    @Published var isCommandPalettePlaygroundPresented = false
    @Published var isCommandKeyPressed = false
    @Published var selectedTodoID: UUID?
    @Published var isTodoPanePresented = false
    @Published var selectedTodoTagFilterIDs: Set<String> = []
    @Published var collapsedAgentGroupIDs: Set<UUID> = []
    /// A close waiting for "Close “<name>”?" (`TabCloseAlertPresenterView`).
    @Published var pendingTabClose: TabCloseRequest?
    @Published var pendingAgentGroupCloseSessionID: UUID?
    @Published var pendingAgentGroupCloseAllowsEmptyWorkspace = false
    @Published var focusedIdleCommandName: String?
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

    var isOmniBarPresented: Bool { omniBar != nil }

    /// ⌘P: opens the Omni bar at its root, or closes it.
    func toggleOmniBar() {
        if omniBar != nil {
            dismissOmniBar()
        } else {
            presentOmniBar(at: nil)
        }
    }

    /// ⌘O and the title-bar project button: opens the Omni bar on Projects,
    /// or closes it when it opened there.
    func showOmniBarProjects() {
        if let omniBar, omniBar.scope == .projects {
            dismissOmniBar()
        } else {
            presentOmniBar(at: .projects)
        }
    }

    func presentOmniBar(at scope: OmniScope?) {
        omniBar = OmniBarRequest(scope: scope, id: (omniBar?.id ?? 0) &+ 1)
    }

    func dismissOmniBar() {
        omniBar = nil
    }

    /// ⌘K, only while the Omni bar is open: its action list for the
    /// selected row. False when the bar is closed (⌘K is then the
    /// terminal's).
    @discardableResult
    func toggleOmniBarActions() -> Bool {
        guard omniBar != nil else { return false }
        omniBarActionsRequest &+= 1
        return true
    }

    func presentTerminalSearch() {
        selectTerminal()
        isTerminalSearchPresented = true
        terminalSearchFocusRequest &+= 1
    }

    func dismissTerminalSearch() {
        isTerminalSearchPresented = false
    }

    func toggleSidebarPlayground() {
        isSidebarPlaygroundPresented.toggle()
    }

    func toggleCommandPalettePlayground() {
        isCommandPalettePlaygroundPresented.toggle()
        if isCommandPalettePlaygroundPresented, omniBar == nil {
            presentOmniBar(at: nil)
        }
    }

    func selectTodo(id: UUID?) {
        selectedTodoID = id
        isTodoPanePresented = true
        focusedIdleCommandName = nil
    }

    func selectTerminal() {
        selectedTodoID = nil
        isTodoPanePresented = false
        focusedIdleCommandName = nil
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
        selectedTodoID = nil
        isTodoPanePresented = false
        focusedIdleCommandName = name
    }

    var isShowingTerminalContent: Bool {
        !isTodoPanePresented && focusedIdleCommandName == nil
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
    /// Which of the project's windows this is (`ProjectWindowValue.windowID`).
    var windowID: UUID? = nil
    /// Opened with no value, or with one whose project did not open: it
    /// claims its project's primary window only while none of the
    /// project's windows is open (`ProjectWindowRegistry.register`).
    var implicit = false
    let workspace: TerminalWorkspace
    let repository: RepositoryWorkspace?
    let todoStore: ProjectTodoStore?
    let chromeState: ProjectWindowChromeState?

    func makeNSView(context: Context) -> NSView {
        let view = ProjectWindowBinderView()
        view.projectRoot = projectRoot
        view.windowID = windowID
        view.isImplicit = implicit
        view.workspace = workspace
        view.repository = repository
        view.todoStore = todoStore
        view.chromeState = chromeState
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProjectWindowBinderView else { return }
        view.projectRoot = projectRoot
        view.windowID = windowID
        view.isImplicit = implicit
        view.workspace = workspace
        view.repository = repository
        view.todoStore = todoStore
        view.chromeState = chromeState
        view.registerIfPossible()
    }
}

@MainActor
private final class ProjectWindowBinderView: NSView {
    weak var workspace: TerminalWorkspace?
    weak var repository: RepositoryWorkspace?
    weak var todoStore: ProjectTodoStore?
    weak var chromeState: ProjectWindowChromeState?
    weak var boundWindow: NSWindow?
    var projectRoot: String?
    var windowID: UUID?
    var isImplicit = false
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
            windowID: windowID,
            implicit: isImplicit,
            workspace: workspace,
            repository: repository,
            todoStore: todoStore,
            chromeState: chromeState
        )
        if !claimed {
            // Another window already owns this window's key, or this window
            // has no value of its own and its project has a window. Close
            // this duplicate and bring the project's most recently active
            // window forward. It never restored or saved anything, and
            // hosted tabs only detach.
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
        // Only the window that claimed its key restores its saved tabs.
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
                guard let self, let window = self.boundWindow, let workspace = self.workspace else { return }
                ProjectWindowRegistry.shared.activateWindow(
                    window,
                    workspace: self.repository?.workspace ?? workspace,
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
    /// The saved windows to reopen: each had tabs and is not open yet.
    case reopen([ProjectWindowValue])
    /// Nothing to reopen and no window open: the default project's window.
    case openDefault
    /// Nothing: the saved windows are open, or another window is.
    case nothing
}

/// A project window's frame, per window, in the app's defaults. Project
/// windows are not restorable, which also turns off SwiftUI's frame
/// autosave: without this, every window would open at the default size.
/// Unlike that autosave (keyed by the order windows opened in), each project
/// window gets its own frame back, at launch and when it opens later. A
/// project's primary window (`windowID` nil) keeps the keys a project's one
/// window had; another window's add `#<window id>`.
struct ProjectWindowFrameStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(projectRoot: String, windowID: UUID? = nil) -> String {
        "window.frame.\(projectRoot)" + windowSuffix(windowID)
    }

    func frameDescriptor(projectRoot: String, windowID: UUID? = nil) -> NSWindow.PersistableFrameDescriptor? {
        defaults.string(forKey: Self.key(projectRoot: projectRoot, windowID: windowID))
    }

    static func fullScreenKey(projectRoot: String, windowID: UUID? = nil) -> String {
        "window.fullScreen.\(projectRoot)" + windowSuffix(windowID)
    }

    private static func windowSuffix(_ windowID: UUID?) -> String {
        windowID.map { "#\($0.uuidString)" } ?? ""
    }

    /// Whether the window was in full screen when it was last saved: it
    /// comes back in full screen (`WindowFullScreenRestore`), and its saved
    /// frame is the one it had before, which it goes back to when it leaves
    /// full screen.
    func isFullScreen(projectRoot: String, windowID: UUID? = nil) -> Bool {
        defaults.bool(forKey: Self.fullScreenKey(projectRoot: projectRoot, windowID: windowID))
    }

    func setFullScreen(_ fullScreen: Bool, projectRoot: String, windowID: UUID? = nil) {
        let key = Self.fullScreenKey(projectRoot: projectRoot, windowID: windowID)
        guard isFullScreen(projectRoot: projectRoot, windowID: windowID) != fullScreen else { return }
        if fullScreen {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Saves `window`'s frame, unless it is full screen: the frame it goes
    /// back to when it leaves full screen stays saved.
    @MainActor
    func save(_ window: NSWindow, projectRoot: String, windowID: UUID? = nil) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let descriptor = window.frameDescriptor
        guard frameDescriptor(projectRoot: projectRoot, windowID: windowID) != descriptor else { return }
        defaults.set(descriptor, forKey: Self.key(projectRoot: projectRoot, windowID: windowID))
    }

    /// Gives `window` the frame saved for that window of `projectRoot`
    /// (AppKit fits it to the screens there are now). False when none was
    /// saved.
    @MainActor
    @discardableResult
    func restore(_ window: NSWindow, projectRoot: String, windowID: UUID? = nil) -> Bool {
        guard let descriptor = frameDescriptor(projectRoot: projectRoot, windowID: windowID) else { return false }
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
