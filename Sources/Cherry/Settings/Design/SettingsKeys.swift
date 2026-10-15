import AppKit
import SwiftUI

/// A page's first look at the keys typed in the Settings window, before
/// the window's own keys (⌘F, ⌘[ and ⌘], `SettingsKeyMonitor`) and the
/// app's menus: Shortcuts' Record takes the next key press this way, and
/// nothing else sees it. The Settings monitor asks it only for events of
/// the Settings window. A page sets `handler` while it records and clears
/// it when it stops or goes away.
@MainActor
final class SettingsKeyCapture {
    static let shared = SettingsKeyCapture()

    /// Gets each key down first; true takes the key (it goes no further).
    var handler: ((NSEvent) -> Bool)?

    /// Tests make their own.
    init() {}

    /// Whether `handler` took `event`.
    func take(_ event: NSEvent) -> Bool {
        handler?(event) ?? false
    }
}

/// Whether ⌥ is held, for views that show more while it is (Interface's
/// sidebar color check). It follows the flags of this app's key events
/// and lets go when a window resigns key.
@MainActor
final class OptionKeyObserver: ObservableObject {
    @Published private(set) var isOptionDown: Bool

    private nonisolated(unsafe) var flagsMonitor: Any?
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

    init() {
        isOptionDown = NSEvent.modifierFlags.contains(.option)

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.setOptionDown(event.modifierFlags.contains(.option))
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setOptionDown(false)
            }
        }
    }

    /// Publishes only a change: every ⌘ press and every window losing key
    /// would otherwise update the views that read it.
    private func setOptionDown(_ isDown: Bool) {
        guard isOptionDown != isDown else { return }
        isOptionDown = isDown
    }

    deinit {
        MainActor.assumeIsolated {
            if let flagsMonitor {
                NSEvent.removeMonitor(flagsMonitor)
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }
    }
}
