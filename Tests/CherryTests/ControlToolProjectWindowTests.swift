import AppKit
import Foundation
import Testing
@testable import Cherry

// An agent's `cherry project open` (open_project without `focus`) never
// takes the keyboard: the project's window opens behind the user's
// (`ProjectWindowRegistry.openInBackground`, then `keepWindowBehind` as it
// registers), and a window that is open stays where it is.

@MainActor
private func controlToolProjectWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

@Test @MainActor func anAgentOpensAProjectsWindowBehindTheUsersAndLeavesAnOpenOneWhereItIs() throws {
    let root = try canonicalTemporaryDirectory("cherry-background-open")
    let other = try canonicalTemporaryDirectory("cherry-background-open-other")
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false, launchBackend: .hostManaged)
    let otherWorkspace = TerminalWorkspace(projectRoot: other.path, createInitialSession: false, launchBackend: .hostManaged)
    let window = controlToolProjectWindow()
    let otherWindow = controlToolProjectWindow()
    let registry = ProjectWindowRegistry()
    var broughtForward: [NSWindow] = []
    var keptBehind: [NSWindow] = []
    registry.bringWindowForward = { broughtForward.append($0) }
    registry.keepWindowBehind = { window, _ in keptBehind.append(window) }
    defer {
        registry.unregister(window: window, projectRoot: root.path)
        registry.unregister(window: otherWindow, projectRoot: other.path)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: other)
    }

    // No window of the project: it opens, and goes behind as it registers.
    var opens = 0
    #expect(registry.openInBackground(projectRoot: root.path) { opens += 1 })
    #expect(opens == 1)
    #expect(registry.register(window: window, projectRoot: root.path, workspace: workspace, todoStore: nil, chromeState: nil))
    #expect(keptBehind == [window])

    // Open: nothing opens and nothing comes forward.
    #expect(!registry.openInBackground(projectRoot: root.path) { opens += 1 })
    #expect(opens == 1)
    #expect(broughtForward.isEmpty)
    // The user's own open brings it forward as before.
    #expect(registry.focus(projectRoot: root.path))
    #expect(broughtForward == [window])

    // The user asked to see a project an agent is opening: its window
    // comes forward as usual once it registers.
    #expect(registry.openInBackground(projectRoot: other.path) {})
    registry.cancelBackgroundOpening(projectRoot: other.path)
    #expect(registry.register(window: otherWindow, projectRoot: other.path, workspace: otherWorkspace, todoStore: nil, chromeState: nil))
    #expect(keptBehind == [window])
}
