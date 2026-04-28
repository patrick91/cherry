import AppKit
import SwiftUI

@MainActor
final class ProjectWindowRegistry {
    static let shared = ProjectWindowRegistry()

    private var windows: [String: WeakWindow] = [:]
    weak var activeWorkspace: TerminalWorkspace?

    private init() {}

    func register(window: NSWindow, projectRoot: String?, workspace: TerminalWorkspace) {
        activeWorkspace = workspace
        guard let projectRoot else { return }
        windows[projectRoot] = WeakWindow(window)
    }

    func unregister(window: NSWindow, projectRoot: String?) {
        guard let projectRoot, windows[projectRoot]?.window === window else { return }
        windows.removeValue(forKey: projectRoot)
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
}

private final class WeakWindow {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

final class ProjectWindowChromeState: ObservableObject {
    @Published var isSidebarHidden = false
    @Published var isSidebarRevealed = false
    @Published var isCursorOverSidebar = false

    func toggleSidebar() {
        if isSidebarHidden {
            if isSidebarRevealed {
                isSidebarHidden.toggle()
            } else {
                withAnimation(.snappy(duration: 0.18)) {
                    isSidebarHidden.toggle()
                }
            }
        } else if isCursorOverSidebar {
            withAnimation(nil) {
                isSidebarHidden = true
                isSidebarRevealed = true
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                isSidebarHidden = true
            }
        }
    }
}

struct ProjectWindowBinder: NSViewRepresentable {
    let projectRoot: String?
    let workspace: TerminalWorkspace

    func makeNSView(context: Context) -> NSView {
        let view = ProjectWindowBinderView()
        view.projectRoot = projectRoot
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ProjectWindowBinderView else { return }
        view.projectRoot = projectRoot
        view.workspace = workspace
        view.registerIfPossible()
    }
}

@MainActor
private final class ProjectWindowBinderView: NSView {
    weak var workspace: TerminalWorkspace?
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
        ProjectWindowRegistry.shared.register(window: window, projectRoot: projectRoot, workspace: workspace)
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
