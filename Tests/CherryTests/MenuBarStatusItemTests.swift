import AppKit
import Foundation
import Testing
@testable import Cherry

// Cherry's menu bar item (`MenuBarStatusItem`) is made once the launch's
// windows are open, never before: making it held the first window up.

@Test @MainActor func theMenuBarItemIsMadeOnlyOnceTheLaunchsWindowsAreOpen() async throws {
    let registry = ProjectWindowRegistry()
    registry.windowRevealMaximumWait = .seconds(60)
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    let roots = try (0..<2).map { index -> String in
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-menu-bar-launch-\(index)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }
    defer { roots.forEach { try? FileManager.default.removeItem(atPath: $0) } }
    var windows: [(NSWindow, String)] = []
    defer {
        for (window, root) in windows {
            registry.unregister(window: window, projectRoot: root)
            window.close()
        }
    }
    let workspace = TerminalWorkspace(projectRoot: roots[0], createInitialSession: false)
    var proceed: (@MainActor () -> Void)?
    registry.openLaunchWindows(roots, beforeLaterWindows: { proceed = $0 }) { root in
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append((window, root))
        _ = registry.register(window: window, projectRoot: root, workspace: workspace, noteStore: nil,
                              todoStore: nil, chromeState: nil)
    }
    var installed = 0
    CherryAppDelegate.installMenuBarItemOnceLaunchWindowsOpened(registry: registry) { installed += 1 }
    // The first window showed; the others are not open yet.
    let deadline = ContinuousClock.now + .seconds(5)
    while proceed == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(installed == 0)
    let proceedNow = try #require(proceed)
    proceedNow()
    #expect(turns.count == 1)
    turns.removeFirst()()
    while installed == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(installed == 1)
}

/// The panel goes under the item, centred on it, kept on screen.
@Test func theMenuBarPanelGoesUnderItsItemWithinTheScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1800, height: 1130)
    let button = NSRect(x: 1104, y: 1138.5, width: 32, height: 22)
    let frame = MenuBarPanelPlacement.frame(contentSize: NSSize(width: 300, height: 121), below: button, within: screen)
    #expect(frame == NSRect(x: 970, y: 1013, width: 300, height: 121))
    // Near the screen's right edge it moves left to stay on it.
    let edge = NSRect(x: 1780, y: 1138.5, width: 20, height: 22)
    let kept = MenuBarPanelPlacement.frame(contentSize: NSSize(width: 300, height: 121), below: edge, within: screen)
    #expect(kept.maxX <= screen.maxX - MenuBarPanelPlacement.gap)
    #expect(kept.maxY == (edge.minY - MenuBarPanelPlacement.gap).rounded())
}
