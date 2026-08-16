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
    private var activeProjectRoot: String?
    weak var activeWorkspace: TerminalWorkspace?
    weak var activeNoteStore: ProjectNoteStore?
    weak var activeTodoStore: ProjectTodoStore?
    weak var activeChromeState: ProjectWindowChromeState?

    private init() {}

    var hasRegisteredProjectWindow: Bool {
        pruneStaleWindows()
        return !workspaces.isEmpty
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

    /// Total sessions running a process across all windows — drives the quit
    /// confirmation.
    func runningProcessCount() -> Int {
        allWorkspaces().reduce(0) { $0 + $1.sessionsWithRunningProcess().count }
    }

    /// Tear down every workspace's sessions (killing their processes). Used on
    /// confirmed app quit, where the per-window `windowWillClose` teardown never
    /// runs — otherwise a SIGHUP-ignoring server would outlive Cherry.
    func closeAllWorkspaces() {
        allWorkspaces().forEach { $0.closeAllSessions() }
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
        windows[projectRoot] = WeakWindow(window)
        workspaces[projectRoot] = WeakWorkspace(workspace)
        if let repository {
            repositories[projectRoot] = WeakRepositoryWorkspace(repository)
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
        return true
    }

    func unregister(window: NSWindow, projectRoot: String?) {
        guard let requestedRoot = projectRoot else { return }
        let projectRoot = repositoryRoot(for: requestedRoot)
        guard windows[projectRoot]?.window === window else { return }
        repositoryRootByWorktreeRoot = repositoryRootByWorktreeRoot.filter { $0.value != projectRoot }
        windows.removeValue(forKey: projectRoot)
        workspaces.removeValue(forKey: projectRoot)
        repositories.removeValue(forKey: projectRoot)
        noteStores.removeValue(forKey: projectRoot)
        todoStores.removeValue(forKey: projectRoot)
        chromeStates.removeValue(forKey: projectRoot)
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

@MainActor
final class ProjectWindowChromeState: ObservableObject {
    @Published var isSidebarHidden = false
    @Published var isSidebarRevealed = false
    @Published var isCursorOverSidebar = false
    @Published var isSidebarAnimating = false
    @Published var isCommandPalettePresented = false
    @Published var isNewWorktreePresented = false
    @Published var isWorktreeManagerPresented = false
    @Published var worktreeToRename: GitWorktree?
    @Published var isTerminalSearchPresented = false
    @Published var terminalSearchFocusRequest = 0
    @Published var isIconDebugOverlayPresented = false
    @Published var isSidebarPlaygroundPresented = false
    @Published var isCommandPalettePlaygroundPresented = false
    @Published var isCommandKeyPressed = false
    @Published var selectedNoteID: UUID?
    @Published var selectedTodoID: UUID?
    @Published var isTodoPanePresented = false
    @Published var selectedTodoTagFilterIDs: Set<String> = []
    @Published var collapsedAgentGroupIDs: Set<UUID> = []
    @Published var pendingAgentCloseSessionID: UUID?
    @Published var pendingAgentCloseAllowsEmptyWorkspace = false
    @Published var pendingAgentGroupCloseSessionID: UUID?
    @Published var pendingAgentGroupCloseAllowsEmptyWorkspace = false
    @Published var focusedIdleCommandName: String?
    @Published var commandPaletteFocusRequest = 0
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

    func requestAgentClose(sessionID: UUID, allowEmptyWorkspace: Bool = false) {
        pendingAgentCloseAllowsEmptyWorkspace = allowEmptyWorkspace
        pendingAgentCloseSessionID = sessionID
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
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.dockedSidebarAnimationStateDuration)
            } catch {
                return
            }
            guard let self else { return }
            self.dockedSidebarAnimationDepth = max(0, self.dockedSidebarAnimationDepth - 1)
            self.isSidebarAnimating = self.dockedSidebarAnimationDepth > 0
            if self.dockedSidebarAnimationDepth == 0 {
                self.pendingPostAnimationDelta = 0
            }
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
            // and bring the existing one forward.
            if let repository {
                repository.closeAllSessions()
            } else {
                workspace.closeAllSessions()
            }
            if let projectRoot {
                _ = ProjectWindowRegistry.shared.focus(projectRoot: projectRoot)
            }
            DispatchQueue.main.async { [weak window] in
                window?.close()
            }
            return
        }
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
    weak var previousDelegate: NSWindowDelegate?
    var projectRoot: String?
    private var isCloseConfirmed = false
    private var isPresentingCloseAlert = false
    private var shouldCloseAfterSheetEnds = false
    private var didCloseWorkspace = false

    init(window: NSWindow) {
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCloseConfirmed else { return true }

        guard let workspace else {
            return previousWindowShouldClose(sender)
        }

        // Confirm for ANY running process (agents, live commands, terminals
        // executing a foreground program) — not just agents. (Product intent is to
        // later narrow this back to running agents only.)
        let runningCount = repository?.runningProcessCount()
            ?? workspace.sessionsWithRunningProcess().count
        guard runningCount > 0 else {
            return previousWindowShouldClose(sender)
        }

        presentCloseAlert(for: sender, runningProcessCount: runningCount)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            closeWorkspaceIfNeeded()
            ProjectWindowRegistry.shared.unregister(window: window, projectRoot: projectRoot)
        }

        previousDelegate?.windowWillClose?(notification)
    }

    func windowDidEndSheet(_ notification: Notification) {
        previousDelegate?.windowDidEndSheet?(notification)

        guard shouldCloseAfterSheetEnds,
              let window = notification.object as? NSWindow,
              window === self.window
        else {
            return
        }

        shouldCloseAfterSheetEnds = false
        window.close()
    }

    private func presentCloseAlert(for window: NSWindow, runningProcessCount: Int) {
        guard !isPresentingCloseAlert else { return }
        isPresentingCloseAlert = true

        let alert = NSAlert()
        alert.messageText = "Close window?"
        alert.informativeText = runningProcessCount == 1
            ? "This window has a running process. It will be stopped."
            : "This window has \(runningProcessCount) running processes. They will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            Task { @MainActor in
                guard let self, let window else { return }
                self.finishCloseAlert(response: response, for: window)
            }
        }
    }

    func finishCloseAlert(response: NSApplication.ModalResponse, for window: NSWindow) {
        isPresentingCloseAlert = false
        guard response == .alertFirstButtonReturn else { return }

        isCloseConfirmed = true
        closeWorkspaceIfNeeded()

        // The original traffic-light click already passed through
        // `windowShouldClose`. Do not simulate another click while AppKit is
        // still dismissing the confirmation sheet: that can leave the sheet
        // orphaned over the next key window. Close directly once the sheet has
        // fully detached instead.
        if window.attachedSheet == nil {
            window.close()
        } else {
            shouldCloseAfterSheetEnds = true
        }
    }

    private func closeWorkspaceIfNeeded() {
        guard !didCloseWorkspace else { return }
        didCloseWorkspace = true
        if let repository {
            repository.closeAllSessions()
        } else {
            workspace?.closeAllSessions()
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
