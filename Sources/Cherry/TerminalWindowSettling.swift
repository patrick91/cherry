import AppKit

/// Windows whose size is changing on its way to the one they settle at: a
/// window going into or out of full screen (between AppKit's `will` and
/// `did` notifications), and one that comes back into full screen at
/// launch (`ProjectWindowRegistry.enterFullScreen`, from its registration
/// until it is there). A persistent tab shown in such a window tells its
/// attach adapter to hold its resizes (`HostedAttachmentSizeFile.hold`), so
/// its session is resized once, to the size the window settles at, not to
/// each size its views pass through; an inline program such as Claude Code
/// redraws for every size, leaving blank or repeated rows. A tab learns
/// that a window settled from `didChangeNotification`.
@MainActor
final class TerminalWindowSettling {
    static let shared = TerminalWindowSettling()

    /// Posted with the window as the object when it starts or stops
    /// settling.
    static let didChangeNotification = Notification.Name("CherryTerminalWindowSettlingDidChange")

    /// The longest a window counts as settling for one reason, should the
    /// end never come (AppKit tells only the window's delegate when a
    /// full-screen transition fails). A tab's adapter stops holding after
    /// the same time by itself (`settle::SIZE_FILE_WAIT`).
    static let maximumSettling: Duration = .seconds(3)

    private struct Entry {
        weak var window: NSWindow?
        /// Holds that have not ended (`hold`), and whether AppKit's
        /// full-screen transition runs.
        var holds = 0
        var transition = false
        /// Names the transition, so that its own timeout ends it, not a
        /// later one's.
        var transitionGeneration = 0
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var transitions = 0
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    private let schedule: (Duration, @escaping @MainActor () -> Void) -> Void

    /// `center` is where AppKit's full-screen notifications are observed
    /// and changes posted; tests give their own, and their own `schedule`.
    init(
        center: NotificationCenter = .default,
        schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> Void = { delay, work in
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                work()
            }
        }
    ) {
        self.center = center
        self.schedule = schedule
        let transitions: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true),
            (NSWindow.willExitFullScreenNotification, true),
            (NSWindow.didEnterFullScreenNotification, false),
            (NSWindow.didExitFullScreenNotification, false),
        ]
        for (name, starts) in transitions {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.setTransition(starts, of: window) }
            })
        }
    }

    isolated deinit {
        observers.forEach(center.removeObserver)
    }

    /// Whether `window`'s size is changing now.
    func isSettling(_ window: NSWindow?) -> Bool {
        guard let window, let entry = entries[ObjectIdentifier(window)], entry.window === window else { return false }
        return entry.holds > 0 || entry.transition
    }

    /// Counts `window` as settling until the returned closure runs (once;
    /// later calls do nothing), or `maximumSettling` passed.
    func hold(_ window: NSWindow) -> @MainActor () -> Void {
        let wasSettling = isSettling(window)
        var entry = currentEntry(for: window)
        entry.holds += 1
        entries[ObjectIdentifier(window)] = entry
        if !wasSettling { post(window) }
        var ended = false
        let end: @MainActor () -> Void = { [weak self, weak window] in
            guard !ended else { return }
            ended = true
            guard let self, let window else { return }
            self.endHold(of: window)
        }
        schedule(Self.maximumSettling) { end() }
        return end
    }

    private func endHold(of window: NSWindow) {
        guard var entry = entries[ObjectIdentifier(window)], entry.window === window, entry.holds > 0 else { return }
        entry.holds -= 1
        store(entry, for: window)
    }

    private func setTransition(_ starts: Bool, of window: NSWindow) {
        var entry = currentEntry(for: window)
        guard entry.transition != starts else { return }
        entry.transition = starts
        transitions += 1
        entry.transitionGeneration = transitions
        let generation = transitions
        store(entry, for: window)
        guard starts else { return }
        schedule(Self.maximumSettling) { [weak self, weak window] in
            guard let self, let window,
                  let entry = self.entries[ObjectIdentifier(window)], entry.window === window,
                  entry.transitionGeneration == generation
            else { return }
            self.setTransition(false, of: window)
        }
    }

    /// The window's entry, a new one when it has none (or the one it has
    /// belonged to a window since gone, whose address it reuses).
    private func currentEntry(for window: NSWindow) -> Entry {
        if let entry = entries[ObjectIdentifier(window)], entry.window === window { return entry }
        return Entry(window: window)
    }

    /// Keeps `entry`, dropping it once nothing holds the window, and posts
    /// when the window started or stopped settling.
    private func store(_ entry: Entry, for window: NSWindow) {
        let wasSettling = isSettling(window)
        let key = ObjectIdentifier(window)
        if entry.holds == 0, !entry.transition {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
        entries = entries.filter { $0.value.window != nil }
        if isSettling(window) != wasSettling { post(window) }
    }

    private func post(_ window: NSWindow) {
        center.post(name: Self.didChangeNotification, object: window)
    }
}
