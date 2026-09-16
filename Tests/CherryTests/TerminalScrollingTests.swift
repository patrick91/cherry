import AppKit
import Testing
@testable import Cherry
@testable import GhosttyTerminal

@MainActor
struct TerminalScrollingTests {
    @Test func appKitInputDoesNotRequestRedundantHostRenderPasses() async throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // No surface: there is no terminal state change that needs a render.
        // Exercise the AppKit entry points without posting system input events.
        view.core.isAttached = { true }
        var hostRenderPasses = 0
        view.core.onPostRender = { hostRenderPasses += 1 }
        let release = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "j",
            charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
        ))
        let motion = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        for _ in 0..<120 {
            view.keyUp(with: release)
            view.mouseMoved(with: motion)
            view.scrollWheel(with: SmallScrollEvent())
            await Task.yield()
        }
        // Drain the main queue after all input handlers have returned.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(hostRenderPasses == 0)
    }

    @Test func movingScrollbackViewportDoesNotRefitTerminalGrid() async throws {
        let session = TerminalSession(
            title: "Scroll regression", subtitle: "No shell",
            tint: .systemBlue, launchShell: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let container = GhosttyTerminalContainerView(frame: window.contentView!.bounds)
        window.contentView = container
        window.orderFrontRegardless()
        defer {
            container.detachActiveSession()
            session.releaseGhosttyBridge()
            session.stop()
            window.close()
        }
        container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
        container.layoutSubtreeIfNeeded()
        let bridge = session.ghosttyBridge
        let view = bridge.terminalView
        _ = try #require(view.core.surface)
        let metrics = try #require(bridge.gridMetrics)
        let rows = UInt64(metrics.rows)
        bridge.terminalDidUpdateScrollbar(.init(total: rows + 200, offset: 200, length: rows))
        container.synchronizeScrollState()
        let initialSize = view.frame.size
        let initialOrigin = view.frame.origin
        let originalMetricsUpdate = view.core.onMetricsUpdate
        var metricsUpdates = 0
        view.core.onMetricsUpdate = {
            metricsUpdates += 1
            originalMetricsUpdate?()
        }
        defer { view.core.onMetricsUpdate = originalMetricsUpdate }

        for row in stride(from: 199, through: 80, by: -1) {
            bridge.terminalDidUpdateScrollbar(.init(total: rows + 200, offset: UInt64(row), length: rows))
            container.synchronizeScrollState()
        }
        #expect(view.frame.origin != initialOrigin)
        #expect(view.frame.size == initialSize)
        #expect(metricsUpdates == 0)

        // A real resize must still update the surface and PTY geometry.
        container.setFrameSize(NSSize(width: 800, height: 500))
        container.synchronizeScrollState(forceTerminalFrame: true)
        #expect(view.frame.size == NSSize(width: 800, height: 500))
        #expect(metricsUpdates > 0)
    }
}

private final class SmallScrollEvent: NSEvent {
    override var hasPreciseScrollingDeltas: Bool { true }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { 0.1 }
    override var momentumPhase: NSEvent.Phase { [] }
}
