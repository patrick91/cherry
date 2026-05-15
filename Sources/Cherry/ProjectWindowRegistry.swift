import AppKit
import CherryControl
import SwiftUI

@MainActor
final class ProjectWindowRegistry {
    static let shared = ProjectWindowRegistry()

    private var windows: [String: WeakWindow] = [:]
    private var workspaces: [String: WeakWorkspace] = [:]
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

    var projectRoots: [String] {
        pruneStaleWindows()
        return Array(workspaces.keys)
    }

    func hasWindow(for projectRoot: String) -> Bool {
        pruneStaleWindows()
        return windows[projectRoot]?.window != nil
    }

    func projectRoot(forProjectKey projectKey: String) -> String? {
        pruneStaleWindows()
        let normalizedKey = projectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var roots = Array(workspaces.keys)
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
        return workspaces[projectRoot]?.workspace
    }

    func noteStore(for projectRoot: String) -> ProjectNoteStore? {
        pruneStaleWindows()
        return noteStores[projectRoot]?.noteStore
    }

    func todoStore(for projectRoot: String) -> ProjectTodoStore? {
        pruneStaleWindows()
        return todoStores[projectRoot]?.todoStore
    }

    func chromeState(for projectRoot: String) -> ProjectWindowChromeState? {
        pruneStaleWindows()
        return chromeStates[projectRoot]?.chromeState
    }

    @discardableResult
    func register(
        window: NSWindow,
        projectRoot: String?,
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore?,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) -> Bool {
        guard let projectRoot else { return false }
        pruneStaleWindows()
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
        guard let projectRoot, windows[projectRoot]?.window === window else { return }
        windows.removeValue(forKey: projectRoot)
        workspaces.removeValue(forKey: projectRoot)
        noteStores.removeValue(forKey: projectRoot)
        todoStores.removeValue(forKey: projectRoot)
        chromeStates.removeValue(forKey: projectRoot)
        if activeProjectRoot == projectRoot {
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

    func focus(projectRoot: String) -> Bool {
        guard let window = windows[projectRoot]?.window else {
            windows.removeValue(forKey: projectRoot)
            return false
        }

        if let workspace = workspaces[projectRoot]?.workspace {
            activate(
                projectRoot: projectRoot,
                workspace: workspace,
                noteStore: noteStores[projectRoot]?.noteStore,
                todoStore: todoStores[projectRoot]?.todoStore,
                chromeState: chromeStates[projectRoot]?.chromeState
            )
        } else {
            AgentSettings.shared.markProjectOpened(projectRoot)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @discardableResult
    func select(_ deepLink: CherryDeepLink, projectRoot: String) -> Bool {
        guard CherryDeepLink.projectKey(forProjectRoot: projectRoot) == deepLink.projectKey,
              let chromeState = chromeStates[projectRoot]?.chromeState
        else {
            return false
        }

        switch deepLink.kind {
        case .note:
            guard AgentSettings.shared.projectFeatures(for: projectRoot).notesEnabled else {
                return false
            }
            guard let noteID = UUID(uuidString: deepLink.targetID),
                  noteStores[projectRoot]?.noteStore?.notes.contains(where: { $0.id == noteID }) == true
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
                  todoStores[projectRoot]?.todoStore?.todos.contains(where: { $0.id == todoID }) == true
            else {
                return false
            }
            chromeState.selectTodo(id: todoID)
            return true
        case .terminal:
            guard let sessionID = UUID(uuidString: deepLink.targetID),
                  let workspace = workspaces[projectRoot]?.workspace,
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
        AgentSettings.shared.markProjectOpened(activeProjectRoot)
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
        var staleProjectRoots: [String] = []
        defer {
            for projectRoot in staleProjectRoots {
                windows.removeValue(forKey: projectRoot)
                workspaces.removeValue(forKey: projectRoot)
                noteStores.removeValue(forKey: projectRoot)
                todoStores.removeValue(forKey: projectRoot)
                chromeStates.removeValue(forKey: projectRoot)
                if activeProjectRoot == projectRoot {
                    activeProjectRoot = nil
                    activeWorkspace = nil
                    activeNoteStore = nil
                    activeTodoStore = nil
                    activeChromeState = nil
                }
            }
        }

        for (projectRoot, workspace) in workspaces {
            guard let workspace = workspace.workspace else {
                staleProjectRoots.append(projectRoot)
                continue
            }
            if workspace.sessions.contains(where: { $0.id == sessionID }) {
                return projectRoot
            }
        }

        return nil
    }

    func isSessionActive(_ session: TerminalSession) -> Bool {
        guard NSApplication.shared.isActive,
              let activeWorkspace,
              activeWorkspace.sessions.contains(where: { $0.id == session.id })
        else {
            return false
        }

        guard activeWorkspace.selectedSessionID == session.id else {
            return false
        }

        return activeChromeState?.isShowingTerminalContent ?? true
    }

    func handleApplicationDidBecomeActive() {
        refreshActiveWindow()
        clearUnreadNotificationForActiveVisibleSession()
    }

    @discardableResult
    func focusSession(sessionID: UUID, projectRoot requestedProjectRoot: String?) -> Bool {
        let candidates: [(projectRoot: String?, workspace: TerminalWorkspace, chromeState: ProjectWindowChromeState?)]
        if let requestedProjectRoot, let workspace = workspaces[requestedProjectRoot]?.workspace {
            candidates = [(requestedProjectRoot, workspace, chromeStates[requestedProjectRoot]?.chromeState)]
        } else {
            candidates = workspaces.compactMap { projectRoot, weakWorkspace in
                weakWorkspace.workspace.map { (projectRoot, $0, chromeStates[projectRoot]?.chromeState) }
            }
        }

        for candidate in candidates {
            guard let session = candidate.workspace.sessions.first(where: { $0.id == sessionID }) else {
                continue
            }

            candidate.workspace.select(session)
            candidate.chromeState?.selectTerminal()
            if let projectRoot = candidate.projectRoot {
                activate(
                    projectRoot: projectRoot,
                    workspace: candidate.workspace,
                    noteStore: noteStores[projectRoot]?.noteStore,
                    todoStore: todoStores[projectRoot]?.todoStore,
                    chromeState: candidate.chromeState
                )
                _ = focus(projectRoot: projectRoot)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            return true
        }

        return false
    }

    private func activate(
        projectRoot: String,
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore?,
        todoStore: ProjectTodoStore?,
        chromeState: ProjectWindowChromeState?
    ) {
        activeProjectRoot = projectRoot
        activeWorkspace = workspace
        activeNoteStore = noteStore
        activeTodoStore = todoStore
        activeChromeState = chromeState
        AgentSettings.shared.markProjectOpened(projectRoot)

        if NSApplication.shared.isActive,
           chromeState?.isShowingTerminalContent ?? true {
            workspace.clearUnreadNotificationForSelectedSession()
        }
    }

    private func clearUnreadNotificationForActiveVisibleSession() {
        guard NSApplication.shared.isActive,
              activeChromeState?.isShowingTerminalContent ?? true
        else {
            return
        }

        activeWorkspace?.clearUnreadNotificationForSelectedSession()
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

    private func pruneStaleWindows() {
        let staleProjectRoots = windows.compactMap { projectRoot, weakWindow in
            weakWindow.window == nil || workspaces[projectRoot]?.workspace == nil ? projectRoot : nil
        }
        for projectRoot in staleProjectRoots {
            windows.removeValue(forKey: projectRoot)
            workspaces.removeValue(forKey: projectRoot)
            noteStores.removeValue(forKey: projectRoot)
            todoStores.removeValue(forKey: projectRoot)
            chromeStates.removeValue(forKey: projectRoot)
            if activeProjectRoot == projectRoot {
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
    @Published var isIconDebugOverlayPresented = false
    @Published var isCommandKeyPressed = false
    @Published var selectedNoteID: UUID?
    @Published var selectedTodoID: UUID?
    @Published var isTodoPanePresented = false
    @Published var selectedTodoTagFilterIDs: Set<String> = []
    @Published var collapsedAgentGroupIDs: Set<UUID> = []
    @Published var pendingAgentGroupCloseSessionID: UUID?
    @Published var focusedIdleCommandName: String?
    @Published var commandPaletteFocusRequest = 0
    // Mirrored from ContentView's @AppStorage("sidebar.width") so the
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

    func toggleSidebar() {
        if isSidebarHidden {
            if isSidebarRevealed {
                isSidebarHidden.toggle()
            } else {
                runDockedAnimation(deltaWidth: -(dockedSidebarWidth - Self.detailPaneLeadingInsetSwap)) {
                    self.isSidebarHidden.toggle()
                }
            }
        } else if isCursorOverSidebar {
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

    func toggleIconDebugOverlay() {
        isIconDebugOverlayPresented.toggle()
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

    func toggleAgentGroupCollapsed(_ id: UUID) {
        if collapsedAgentGroupIDs.contains(id) {
            collapsedAgentGroupIDs.remove(id)
        } else {
            collapsedAgentGroupIDs.insert(id)
        }
    }

    func requestAgentGroupClose(sessionID: UUID) {
        pendingAgentGroupCloseSessionID = sessionID
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
        isSidebarAnimating = true
        withAnimation(.snappy(duration: 0.18)) {
            body()
        } completion: { [weak self] in
            self?.isSidebarAnimating = false
            self?.pendingPostAnimationDelta = 0
        }
    }
}

struct ProjectWindowBinder: NSViewRepresentable {
    let projectRoot: String?
    let workspace: TerminalWorkspace
    let noteStore: ProjectNoteStore?
    let todoStore: ProjectTodoStore?
    let chromeState: ProjectWindowChromeState?

    func makeNSView(context: Context) -> NSView {
        let view = ProjectWindowBinderView()
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.noteStore = noteStore
        view.todoStore = todoStore
        view.chromeState = chromeState
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProjectWindowBinderView else { return }
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.noteStore = noteStore
        view.todoStore = todoStore
        view.chromeState = chromeState
        view.registerIfPossible()
    }
}

@MainActor
private final class ProjectWindowBinderView: NSView {
    weak var workspace: TerminalWorkspace?
    weak var noteStore: ProjectNoteStore?
    weak var todoStore: ProjectTodoStore?
    weak var chromeState: ProjectWindowChromeState?
    weak var boundWindow: NSWindow?
    var projectRoot: String?
    private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?

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
            noteStore: noteStore,
            todoStore: todoStore,
            chromeState: chromeState
        )
        if !claimed {
            // Another window already owns this project. Close this duplicate
            // and bring the existing one forward.
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
        if shouldInstallObserver {
            installObserver()
        }
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
                    workspace: workspace,
                    noteStore: self.noteStore,
                    todoStore: self.todoStore,
                    chromeState: self.chromeState
                )
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        if let boundWindow {
            let projectRoot = projectRoot
            Task { @MainActor in
                ProjectWindowRegistry.shared.unregister(window: boundWindow, projectRoot: projectRoot)
            }
        }
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
