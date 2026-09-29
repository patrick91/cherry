import AppKit
import Foundation
import Testing
@testable import Cherry

// The order in which a restored window comes on screen
// (`ProjectWindowRevealGate`): hidden until its content is ready, at most
// its wait.

@MainActor
private final class ManualSchedule {
    private(set) var pending: [(delay: Duration, body: @MainActor () -> Void)] = []

    var schedule: ProjectWindowRevealGate.Schedule {
        { [self] delay, body in pending.append((delay, body)) }
    }

    /// Runs the scheduled bodies whose delay is at most `delay`.
    func run(upTo delay: Duration) {
        let due = pending.filter { $0.delay <= delay }
        pending.removeAll { $0.delay <= delay }
        due.forEach { $0.body() }
    }
}

@MainActor
private final class Visibility {
    var hidden = 0
    var shown: [ProjectWindowRevealGate.Outcome] = []
}

@MainActor
private func makeGate(_ schedule: ManualSchedule, _ visibility: Visibility, wait: Duration = .seconds(1)) -> ProjectWindowRevealGate {
    ProjectWindowRevealGate(
        maximumWait: wait,
        hide: { visibility.hidden += 1 },
        show: { visibility.shown.append($0) },
        schedule: schedule.schedule
    )
}

@Test @MainActor func aWaitingWindowShowsOnTheTurnAfterItsContentIsReady() {
    let schedule = ManualSchedule()
    let visibility = Visibility()
    let gate = makeGate(schedule, visibility)
    gate.begin()
    #expect(visibility.hidden == 1)
    #expect(gate.isHidden)
    #expect(visibility.shown.isEmpty)

    gate.contentIsReady()
    // Not in the same turn: SwiftUI lays the restored tabs out first.
    #expect(visibility.shown.isEmpty)
    schedule.run(upTo: .zero)
    #expect(visibility.shown == [.contentReady])
    #expect(gate.outcome == .contentReady)
    #expect(!gate.isHidden)

    // The wait running out later changes nothing.
    schedule.run(upTo: .seconds(1))
    gate.contentIsReady()
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown == [.contentReady])
}

@Test @MainActor func aWaitingWindowShowsWhenItsWaitRunsOut() {
    let schedule = ManualSchedule()
    let visibility = Visibility()
    let gate = makeGate(schedule, visibility, wait: .milliseconds(800))
    gate.begin()
    schedule.run(upTo: .zero)
    #expect(visibility.shown.isEmpty)
    schedule.run(upTo: .milliseconds(800))
    #expect(visibility.shown == [.timedOut])
    #expect(!gate.isHidden)

    // Its content coming later shows it no second time.
    gate.contentIsReady()
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown == [.timedOut])
}

@Test @MainActor func aGateHidesOnceAndShowsNothingItNeverHid() {
    let schedule = ManualSchedule()
    let visibility = Visibility()
    let gate = makeGate(schedule, visibility)
    // Content ready before the wait began: nothing hidden, nothing to show.
    gate.contentIsReady()
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown.isEmpty)

    let other = makeGate(schedule, visibility)
    other.begin()
    other.begin()
    #expect(visibility.hidden == 1)
    #expect(schedule.pending.count == 1)
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown == [.timedOut])
}

// MARK: - Windows the launch opens

@MainActor
private func makeCoverTestWindow(identifier: String = "project-AppWindow-1") -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier(identifier)
    return window
}

@MainActor
private func makeCover(_ schedule: ManualSchedule, center: NotificationCenter) -> LaunchWindowCover {
    LaunchWindowCover(fallbackWait: .seconds(1), center: center, schedule: schedule.schedule) { window in
        window.identifier?.rawValue.hasPrefix("project") ?? false
    }
}

/// A window the launch opens is transparent from its first placement (before
/// AppKit orders it in and long before it registers) until its registration
/// takes it over; only as many windows as expected, and never one taken
/// over already.
@Test @MainActor func launchWindowsAreCoveredFromTheirFirstPlacementUntilTheyRegister() {
    let schedule = ManualSchedule()
    let center = NotificationCenter()
    let cover = makeCover(schedule, center: center)
    let first = makeCoverTestWindow()
    let other = makeCoverTestWindow(identifier: "com_apple_SwiftUI_Settings_window")
    let second = makeCoverTestWindow(identifier: "project-AppWindow-2")
    let extra = makeCoverTestWindow(identifier: "project-AppWindow-3")
    defer { [first, other, second, extra].forEach { $0.close() } }

    // Nothing expected: nothing covered.
    center.post(name: NSWindow.didMoveNotification, object: first)
    #expect(first.alphaValue == 1)

    cover.expect(2)
    center.post(name: NSWindow.didMoveNotification, object: other)
    #expect(other.alphaValue == 1)
    center.post(name: NSWindow.didMoveNotification, object: first)
    #expect(first.alphaValue == 0)
    #expect(first.ignoresMouseEvents)
    #expect(cover.isCovering(first))
    center.post(name: NSWindow.didBecomeKeyNotification, object: second)
    #expect(second.alphaValue == 0)
    // Two were expected.
    center.post(name: NSWindow.didMoveNotification, object: extra)
    #expect(extra.alphaValue == 1)

    // Registration takes it over, still transparent (its reveal waits for
    // its tabs); a later key change never covers it again.
    #expect(cover.claim(first))
    #expect(!cover.isCovering(first))
    #expect(first.alphaValue == 0)
    cover.expect(1)
    center.post(name: NSWindow.didBecomeKeyNotification, object: first)
    #expect(!cover.isCovering(first))
    #expect(!cover.claim(extra))
}

/// A covered window that never registers (a duplicate, a window without a
/// project) shows after the fallback wait; one taken over is left to its
/// registration.
@Test @MainActor func aCoveredWindowThatNeverRegistersShowsAfterTheWait() {
    let schedule = ManualSchedule()
    let center = NotificationCenter()
    let cover = makeCover(schedule, center: center)
    let orphan = makeCoverTestWindow()
    let claimed = makeCoverTestWindow(identifier: "project-AppWindow-2")
    defer { [orphan, claimed].forEach { $0.close() } }
    cover.expect(2)
    center.post(name: NSWindow.didMoveNotification, object: orphan)
    center.post(name: NSWindow.didMoveNotification, object: claimed)
    #expect(cover.claim(claimed))
    schedule.run(upTo: .seconds(1))
    #expect(orphan.alphaValue == 1)
    #expect(!orphan.ignoresMouseEvents)
    #expect(claimed.alphaValue == 0)

    // Windows that never came stop being expected after the wait.
    let late = makeCoverTestWindow(identifier: "project-AppWindow-3")
    defer { late.close() }
    cover.expect(1)
    schedule.run(upTo: .seconds(1))
    center.post(name: NSWindow.didMoveNotification, object: late)
    #expect(late.alphaValue == 1)
}

/// A window the launch covered registers with nothing to restore: it shows
/// on the next turn, once laid out.
@Test @MainActor func aCoveredWindowWithNothingToRestoreShowsOnceItRegisters() async throws {
    let registry = ProjectWindowRegistry()
    let center = NotificationCenter()
    let schedule = ManualSchedule()
    let cover = makeCover(schedule, center: center)
    registry.launchWindowCover = cover
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-cover-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let window = makeCoverTestWindow()
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    defer {
        registry.unregister(window: window, projectRoot: root.path)
        window.close()
        try? FileManager.default.removeItem(at: root)
    }
    cover.expect(1)
    center.post(name: NSWindow.didMoveNotification, object: window)
    #expect(window.alphaValue == 0)
    #expect(registry.register(
        window: window,
        projectRoot: root.path,
        workspace: workspace,
        noteStore: nil,
        todoStore: nil,
        chromeState: nil
    ))
    #expect(!cover.isCovering(window))
    #expect(window.alphaValue == 0)
    let deadline = ContinuousClock.now + .seconds(5)
    while window.alphaValue == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.alphaValue == 1)
    #expect(!window.ignoresMouseEvents)
}
