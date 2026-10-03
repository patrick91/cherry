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

// MARK: - Windows that were in full screen

/// A window going back into full screen (`waitAlso`) shows only once it is
/// there, though its content was ready first: never windowed, then full
/// screen. The outcome is still its content's.
@Test @MainActor func aWindowGoingBackIntoFullScreenShowsOnlyOnceItIsThere() {
    let schedule = ManualSchedule()
    let visibility = Visibility()
    let gate = makeGate(schedule, visibility)
    gate.begin()
    let entered = gate.waitAlso(atMost: .seconds(3))
    #expect(gate.otherWaits == 1)
    gate.contentIsReady()
    schedule.run(upTo: .zero)
    #expect(visibility.shown.isEmpty)
    #expect(gate.isHidden)
    // The content's wait running out changes nothing either.
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown.isEmpty)

    entered()
    #expect(visibility.shown == [.contentReady])
    #expect(!gate.isHidden)
    // Once.
    entered()
    schedule.run(upTo: .seconds(3))
    #expect(visibility.shown == [.contentReady])
    #expect(gate.otherWaits == 0)
}

/// A window that never gets back into full screen (AppKit refused) shows
/// once that wait runs out, as its content's wait said; and a wait added
/// after the window showed holds nothing.
@Test @MainActor func aWindowThatNeverGetsBackIntoFullScreenShowsWhenThatWaitRunsOut() {
    let schedule = ManualSchedule()
    let visibility = Visibility()
    let gate = makeGate(schedule, visibility, wait: .seconds(1))
    gate.begin()
    _ = gate.waitAlso(atMost: .seconds(3))
    schedule.run(upTo: .seconds(1))
    #expect(visibility.shown.isEmpty)
    schedule.run(upTo: .seconds(3))
    #expect(visibility.shown == [.timedOut])

    let late = gate.waitAlso(atMost: .seconds(3))
    #expect(gate.otherWaits == 0)
    late()
    #expect(visibility.shown == [.timedOut])
}

@MainActor
private func makeFullScreenTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.collectionBehavior.insert(.fullScreenPrimary)
    return window
}

/// Whether a project's window is in full screen is saved as it enters and
/// leaves full screen, with its frame; leaving because it closes or because
/// the app quits keeps it saved, so the window comes back in full screen.
@Test @MainActor func aWindowsFullScreenStateIsSavedAsItEntersAndLeavesFullScreen() throws {
    let suite = "CherryTests.FullScreen.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ProjectWindowFrameStore(defaults: defaults)
    let center = NotificationCenter()
    let window = makeFullScreenTestWindow()
    defer { window.close() }
    var terminating = false
    let saver = ProjectWindowFrameSaver(
        window: window, projectRoot: "/p", store: store, center: center, isTerminating: { terminating }
    )
    #expect(!store.isFullScreen(projectRoot: "/p"))
    center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    #expect(store.isFullScreen(projectRoot: "/p"))
    #expect(defaults.bool(forKey: ProjectWindowFrameStore.fullScreenKey(projectRoot: "/p")))
    // Another window's changes are not this one's.
    center.post(name: NSWindow.didExitFullScreenNotification, object: makeFullScreenTestWindow())
    #expect(store.isFullScreen(projectRoot: "/p"))
    center.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(!store.isFullScreen(projectRoot: "/p"))
    #expect(defaults.object(forKey: ProjectWindowFrameStore.fullScreenKey(projectRoot: "/p")) == nil)

    // The app quits from full screen.
    center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    terminating = true
    center.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(store.isFullScreen(projectRoot: "/p"))
    // The window closes from full screen.
    terminating = false
    center.post(name: NSWindow.willCloseNotification, object: window)
    center.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(store.isFullScreen(projectRoot: "/p"))
    withExtendedLifetime(saver) {}
}

/// A window whose project's window was in full screen registers: it takes
/// its saved (windowed) frame first, which it goes back to when it leaves
/// full screen, then goes into full screen, and stays transparent until it
/// is there. A window saved windowed is never taken into full screen.
@Test @MainActor func aWindowSavedInFullScreenTakesItsFrameThenFullScreenBeforeItShows() async throws {
    let suite = "CherryTests.FullScreenRestore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let frames = ProjectWindowFrameStore(defaults: defaults)
    // Canonical (no /var symlink): the registry keys a window by it.
    let created = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-fullscreen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    let root = URL(fileURLWithPath: try #require(created.path.withCString { pointer -> String? in
        guard let resolved = realpath(pointer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let other = root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    let saved = NSRect(x: 120, y: 140, width: 800, height: 500)
    let lastRun = makeFullScreenTestWindow()
    lastRun.setFrame(saved, display: false)
    frames.save(lastRun, projectRoot: root.path)
    frames.setFullScreen(true, projectRoot: root.path)
    lastRun.close()

    let registry = ProjectWindowRegistry()
    registry.configureWindowFrames(frames)
    var entering: [(window: NSWindow, frame: NSRect, done: @MainActor () -> Void)] = []
    registry.enterFullScreen = { window, done in entering.append((window, window.frame, done)) }
    let window = makeFullScreenTestWindow()
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    let windowed = makeFullScreenTestWindow()
    let otherWorkspace = TerminalWorkspace(projectRoot: other.path, createInitialSession: false)
    defer {
        registry.unregister(window: window, projectRoot: root.path)
        registry.unregister(window: windowed, projectRoot: other.path)
        window.close()
        windowed.close()
    }
    #expect(registry.register(
        window: window, projectRoot: root.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    #expect(entering.count == 1)
    #expect(entering.first?.window === window)
    #expect(entering.first?.frame == saved)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents)
    // Nothing to restore, but it waits for full screen, past its content's
    // wait.
    try await Task.sleep(for: .milliseconds(1200))
    #expect(window.alphaValue == 0)
    entering.first?.done()
    let deadline = ContinuousClock.now + .seconds(5)
    while window.alphaValue == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.alphaValue == 1)
    #expect(!window.ignoresMouseEvents)
    // Registering again (every view update does) does not go again.
    #expect(registry.register(
        window: window, projectRoot: root.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    #expect(entering.count == 1)

    #expect(registry.register(
        window: windowed, projectRoot: other.path, workspace: otherWorkspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    #expect(entering.count == 1)
    #expect(windowed.alphaValue == 1)
}

/// Going back into full screen waits for the window to be on screen
/// (AppKit takes only a window on screen into full screen) and ends once it
/// is in full screen, or after its wait, once.
@Test @MainActor func goingBackIntoFullScreenEndsOnceWhenThereOrAfterItsWait() {
    let center = NotificationCenter()
    let schedule = ManualSchedule()
    let window = makeFullScreenTestWindow()
    defer { window.close() }
    var toggles = 0
    var ended = 0
    WindowFullScreenRestore.enter(
        window, center: center, schedule: schedule.schedule, toggle: { _ in toggles += 1 }, done: { ended += 1 }
    )
    // Not on screen: nothing yet.
    center.post(name: NSWindow.didUpdateNotification, object: window)
    #expect(toggles == 0)
    #expect(ended == 0)
    center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    #expect(ended == 1)
    center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    schedule.run(upTo: WindowFullScreenRestore.maximumWait)
    #expect(ended == 1)

    WindowFullScreenRestore.enter(
        window, center: center, schedule: schedule.schedule, toggle: { _ in toggles += 1 }, done: { ended += 1 }
    )
    schedule.run(upTo: WindowFullScreenRestore.maximumWait)
    #expect(ended == 2)
    #expect(toggles == 0)

    // A window that cannot go full screen ends at once.
    let fixed = makeCoverTestWindow()
    defer { fixed.close() }
    WindowFullScreenRestore.enter(
        fixed, center: center, schedule: schedule.schedule, toggle: { _ in toggles += 1 }, done: { ended += 1 }
    )
    #expect(ended == 3)
}

// MARK: - Keys typed before a terminal shows

@MainActor
private func key(_ characters: String, keyCode: UInt16, in window: NSWindow?, up: Bool = false,
                 modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: up ? .keyUp : .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: window?.windowNumber ?? 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

/// Keys typed into a window kept off screen for its tabs (AppKit makes it
/// key while it is transparent) are held, and posted back in order once it
/// shows; Command shortcuts and other windows' keys are not.
@Test @MainActor func keysTypedIntoAWindowOffScreenAreHeldUntilItShowsInOrder() throws {
    var posted: [NSEvent] = []
    let hold = HiddenWindowKeyHold(installsMonitor: false) { posted += $0 }
    let window = makeCoverTestWindow()
    let other = makeCoverTestWindow(identifier: "project-AppWindow-2")
    defer { [window, other].forEach { $0.close() } }
    let typed = [try key("l", keyCode: 37, in: window), try key("l", keyCode: 37, in: window, up: true),
                 try key("s", keyCode: 1, in: window)]
    // Not held before the window is.
    #expect(!hold.take(typed[0]))

    hold.hold(window)
    #expect(hold.isHolding(window))
    for event in typed { #expect(hold.take(event)) }
    #expect(!hold.take(try key("w", keyCode: 13, in: window, modifiers: .command)))
    #expect(!hold.take(try key("x", keyCode: 7, in: other)))
    #expect(posted.isEmpty)

    hold.release(window)
    #expect(!hold.isHolding(window))
    #expect(posted == typed)
    // Shown: its keys go through.
    #expect(!hold.take(try key("y", keyCode: 16, in: window)))
    hold.release(window)
    #expect(posted == typed)
}

/// While the launch's first window is not on screen, keys typed with no
/// window key are held for it; they go first when it shows, then its own,
/// in the order typed. Without a window, they go after the hold's limit.
@Test @MainActor func keysTypedBeforeTheLaunchsFirstWindowGoWithIt() async throws {
    var posted: [NSEvent] = []
    let hold = HiddenWindowKeyHold(installsMonitor: false) { posted += $0 }
    let window = makeCoverTestWindow()
    defer { window.close() }
    hold.holdWindowlessKeys(atMost: .seconds(60))
    let early = try key("e", keyCode: 14, in: nil)
    #expect(hold.take(early))
    hold.hold(window)
    let later = try key("c", keyCode: 8, in: window)
    #expect(hold.take(later))
    hold.release(window)
    #expect(posted == [early, later])
    // The launch's hold ended with the first window.
    #expect(!hold.isHoldingWindowlessKeys)
    #expect(!hold.take(try key("h", keyCode: 4, in: nil)))

    let other = HiddenWindowKeyHold(installsMonitor: false) { posted += $0 }
    posted = []
    other.holdWindowlessKeys(atMost: .milliseconds(50))
    let lone = try key("o", keyCode: 31, in: nil)
    #expect(other.take(lone))
    let deadline = ContinuousClock.now + .seconds(5)
    while posted.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(posted == [lone])
    #expect(!other.isHoldingWindowlessKeys)
}

/// A window the reveal keeps off screen holds its keys from the moment it
/// hides, and posts them once it shows, after its `onShow` (which gives
/// its terminal the keys).
@Test @MainActor func aWindowsRevealHoldsItsKeysUntilItShows() async throws {
    var posted: [NSEvent] = []
    var order: [String] = []
    let hold = HiddenWindowKeyHold(installsMonitor: false) { events in
        order.append("posted")
        posted += events
    }
    let window = makeCoverTestWindow()
    defer { window.close() }
    let gate = try #require(ProjectWindowReveal.hold(
        window, until: nil, name: "test", alreadyHidden: true, maximumWait: .seconds(60), keyHold: hold
    ) { order.append("shown") })
    #expect(hold.isHolding(window))
    let typed = try key("k", keyCode: 40, in: window)
    #expect(hold.take(typed))
    let deadline = ContinuousClock.now + .seconds(5)
    while gate.outcome == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(gate.outcome == .contentReady)
    #expect(window.alphaValue == 1)
    #expect(order == ["shown", "posted"])
    #expect(posted == [typed])
    #expect(!hold.isHolding(window))
}
