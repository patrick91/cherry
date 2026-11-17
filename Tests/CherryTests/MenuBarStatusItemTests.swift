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
    registry.openLaunchWindows(roots.map(ProjectWindowValue.primary), beforeLaterWindows: { proceed = $0 }) { value in
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append((window, value.projectRoot))
        _ = registry.register(window: window, projectRoot: value.projectRoot, windowID: value.windowID,
                              workspace: workspace, todoStore: nil, chromeState: nil)
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

// While agents work, the glyph's shimmer is Core Animation's: three plates,
// each with a repeating opacity animation the render server plays. A frame
// used to be an image set on the item about 13 times a second, each one a
// re-measure and a snapshot of the item for every menu bar.
@Test @MainActor func theWorkingGlyphIsThreePlatesTheRenderServerAnimates() throws {
    let layer = MenuBarStatusLabel.workingLayer(dark: true, flipped: false)
    #expect(layer.bounds.size == MenuBarStatusLabel.glyphSize)
    let plates = try #require(layer.sublayers as? [CAShapeLayer])
    #expect(plates.count == 3)
    for plate in plates {
        #expect(plate.path != nil)
        // A snapshot (another display's menu bar) shows the resting glyph.
        #expect(abs(Double(plate.opacity) - MenuBarShimmer.baseAlpha) < 0.001)
        let pulse = try #require(plate.animation(forKey: "pulse") as? CAKeyframeAnimation)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.repeatCount == .infinity)
        #expect(abs(pulse.duration - MenuBarShimmer.duration) < 0.001)
    }
    #expect(MenuBarStatusLabel.placeholderIcon.size == MenuBarStatusLabel.glyphSize)
}

@Test @MainActor func thePlatesPulseOneAfterAnotherBetweenBaseAndPeak() {
    let samples = 60
    let top = MenuBarStatusLabel.pulseOpacities(plate: 0, samples: samples)
    let middle = MenuBarStatusLabel.pulseOpacities(plate: 1, samples: samples)
    #expect(top.count == samples + 1)
    #expect(abs(Double(top[0]) - MenuBarShimmer.baseAlpha) < 0.001)
    #expect(abs(Double(top.max() ?? 0) - MenuBarShimmer.peakAlpha) < 0.01)
    #expect(abs(Double(top.min() ?? 0) - MenuBarShimmer.baseAlpha) < 0.001)
    // The middle plate is the top one, a stagger later.
    let lag = Int((MenuBarShimmer.layerStagger * Double(samples)).rounded())
    for step in lag...samples {
        #expect(abs(middle[step] - top[step - lag]) < 0.001)
    }
}
