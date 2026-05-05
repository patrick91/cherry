import AppKit
import SwiftUI

@MainActor
final class ProjectWindowRegistry {
    static let shared = ProjectWindowRegistry()

    private var windows: [String: WeakWindow] = [:]
    private var workspaces: [String: WeakWorkspace] = [:]
    private var chromeStates: [String: WeakChromeState] = [:]
    weak var activeWorkspace: TerminalWorkspace?
    weak var activeNoteStore: ProjectNoteStore?
    weak var activeChromeState: ProjectWindowChromeState?

    private init() {}

    func register(
        window: NSWindow,
        projectRoot: String?,
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore?,
        chromeState: ProjectWindowChromeState?
    ) {
        activeWorkspace = workspace
        activeNoteStore = noteStore
        activeChromeState = chromeState
        guard let projectRoot else { return }
        windows[projectRoot] = WeakWindow(window)
        workspaces[projectRoot] = WeakWorkspace(workspace)
        if let chromeState {
            chromeStates[projectRoot] = WeakChromeState(chromeState)
        }
    }

    func unregister(window: NSWindow, projectRoot: String?) {
        guard let projectRoot, windows[projectRoot]?.window === window else { return }
        windows.removeValue(forKey: projectRoot)
        workspaces.removeValue(forKey: projectRoot)
        chromeStates.removeValue(forKey: projectRoot)
    }

    func focus(projectRoot: String) -> Bool {
        guard let window = windows[projectRoot]?.window else {
            windows.removeValue(forKey: projectRoot)
            return false
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func projectRoot(containing sessionID: UUID) -> String? {
        var staleProjectRoots: [String] = []
        defer {
            for projectRoot in staleProjectRoots {
                windows.removeValue(forKey: projectRoot)
                workspaces.removeValue(forKey: projectRoot)
                chromeStates.removeValue(forKey: projectRoot)
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

        return activeWorkspace.selectedSessionID == session.id
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
            activeWorkspace = candidate.workspace
            candidate.chromeState?.selectNote(id: nil)
            activeChromeState = candidate.chromeState
            if let projectRoot = candidate.projectRoot {
                _ = focus(projectRoot: projectRoot)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            return true
        }

        return false
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
    @Published var isCommandKeyPressed = false
    @Published var selectedNoteID: UUID?
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

    func selectNote(id: UUID?) {
        selectedNoteID = id
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
    let chromeState: ProjectWindowChromeState?

    func makeNSView(context: Context) -> NSView {
        let view = ProjectWindowBinderView()
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.noteStore = noteStore
        view.chromeState = chromeState
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProjectWindowBinderView else { return }
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.noteStore = noteStore
        view.chromeState = chromeState
        view.registerIfPossible()
    }
}

@MainActor
private final class ProjectWindowBinderView: NSView {
    weak var workspace: TerminalWorkspace?
    weak var noteStore: ProjectNoteStore?
    weak var chromeState: ProjectWindowChromeState?
    weak var boundWindow: NSWindow?
    var projectRoot: String?
    private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerIfPossible()
        installObserver()
    }

    func registerIfPossible() {
        guard let window, let workspace else { return }
        boundWindow = window
        ProjectWindowRegistry.shared.register(
            window: window,
            projectRoot: projectRoot,
            workspace: workspace,
            noteStore: noteStore,
            chromeState: chromeState
        )
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
                ProjectWindowRegistry.shared.activeWorkspace = workspace
                ProjectWindowRegistry.shared.activeNoteStore = self.noteStore
                ProjectWindowRegistry.shared.activeChromeState = self.chromeState
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
