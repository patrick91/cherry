import AppKit
import Testing
@testable import Cherry

/// `TerminalWindowSettling` with its own notification centre and a schedule
/// the test runs by hand: AppKit's full-screen transitions and explicit
/// holds make a window settle until they end, or until `maximumSettling`
/// passed; each change is posted once.
@MainActor
private final class SettlingFixture {
    let center = NotificationCenter()
    var scheduled: [(Duration, @MainActor () -> Void)] = []
    var posted: [Bool] = []
    lazy var settling = TerminalWindowSettling(center: center) { [unowned self] delay, work in
        self.scheduled.append((delay, work))
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    private var observer: NSObjectProtocol?

    init() {
        window.isReleasedWhenClosed = false
        observer = center.addObserver(forName: TerminalWindowSettling.didChangeNotification, object: window, queue: nil) { [unowned self] _ in
            MainActor.assumeIsolated { self.posted.append(self.settling.isSettling(self.window)) }
        }
    }

    func post(_ name: Notification.Name, _ window: NSWindow? = nil) {
        center.post(name: name, object: window ?? self.window)
    }

    /// Runs what was scheduled so far, as if its time had passed.
    func elapse() {
        let due = scheduled
        scheduled.removeAll()
        for (delay, work) in due {
            #expect(delay == TerminalWindowSettling.maximumSettling)
            work()
        }
    }
}

@Test @MainActor func TerminalWindowSettlingFollowsFullScreenTransitions() {
    let fixture = SettlingFixture()
    let settling = fixture.settling
    #expect(!settling.isSettling(fixture.window))
    #expect(!settling.isSettling(nil))
    fixture.post(NSWindow.willEnterFullScreenNotification)
    #expect(settling.isSettling(fixture.window))
    fixture.post(NSWindow.didEnterFullScreenNotification)
    #expect(!settling.isSettling(fixture.window))
    fixture.post(NSWindow.willExitFullScreenNotification)
    #expect(settling.isSettling(fixture.window))
    fixture.post(NSWindow.didExitFullScreenNotification)
    #expect(!settling.isSettling(fixture.window))
    #expect(fixture.posted == [true, false, true, false])
    // Another window's transition is its own.
    let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    fixture.post(NSWindow.willEnterFullScreenNotification, other)
    #expect(settling.isSettling(other) && !settling.isSettling(fixture.window))
    fixture.post(NSWindow.didEnterFullScreenNotification, other)
}

@Test @MainActor func TerminalWindowSettlingEndsATransitionAppKitNeverEnds() {
    let fixture = SettlingFixture()
    let settling = fixture.settling
    // Failed: AppKit tells only the window's delegate.
    fixture.post(NSWindow.willEnterFullScreenNotification)
    #expect(settling.isSettling(fixture.window))
    fixture.elapse()
    #expect(!settling.isSettling(fixture.window))
    // A timeout from an earlier transition leaves a later one alone.
    fixture.post(NSWindow.willExitFullScreenNotification)
    let earlier = fixture.scheduled
    fixture.post(NSWindow.didExitFullScreenNotification)
    fixture.post(NSWindow.willEnterFullScreenNotification)
    for (_, work) in earlier { work() }
    #expect(settling.isSettling(fixture.window))
    fixture.post(NSWindow.didEnterFullScreenNotification)
    #expect(fixture.posted == [true, false, true, false, true, false])
}

@Test @MainActor func TerminalWindowSettlingHoldsAWindowUntilEveryHoldEnded() {
    let fixture = SettlingFixture()
    let settling = fixture.settling
    let first = settling.hold(fixture.window)
    #expect(settling.isSettling(fixture.window))
    // Going into full screen meanwhile, as a window restored in full screen
    // does.
    fixture.post(NSWindow.willEnterFullScreenNotification)
    let second = settling.hold(fixture.window)
    first()
    first()
    #expect(settling.isSettling(fixture.window))
    fixture.post(NSWindow.didEnterFullScreenNotification)
    #expect(settling.isSettling(fixture.window))
    second()
    #expect(!settling.isSettling(fixture.window))
    #expect(fixture.posted == [true, false])
    // One never ended ends on its own.
    _ = settling.hold(fixture.window)
    #expect(settling.isSettling(fixture.window))
    fixture.elapse()
    #expect(!settling.isSettling(fixture.window))
    #expect(fixture.posted == [true, false, true, false])
}
