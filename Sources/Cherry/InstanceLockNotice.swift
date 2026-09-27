import AppKit

/// Tells the user, once per run, that this copy of the app leaves this Mac's
/// persistent sessions and saved tabs alone because another copy with the
/// same identity holds the instance lock (`AppInstanceLock`). Without it,
/// the only sign would be tabs that do not come back and Settings ›
/// Sessions' explanation.
///
/// The notice is an alert sheet on the first project window that registers
/// (`ProjectWindowRegistry`): only that window waits for its OK, and launch
/// goes on. Whether it is needed is found out off the main thread (taking
/// the lock may wait for a copy that is quitting). When no project window
/// can show it by then (none is on screen yet, or it closed), it is tried
/// again shortly, and then on the next window that registers.
@MainActor
final class InstanceLockNotice {
    struct Content: Equatable, Sendable {
        let title: String
        let message: String
    }

    enum Phase: Equatable {
        /// Nothing asked yet: the first project window starts the check.
        case idle
        /// Finding out whether this copy holds the lock.
        case checking
        /// Needed, and waiting for a project window that can show it.
        case waitingForWindow(Content)
        case shown
        /// This copy holds the lock (or the file system cannot enforce it).
        case notNeeded
    }

    /// What to say for `reason` (`AppInstanceLock.unavailableReason`); nil
    /// when this copy holds the lock.
    nonisolated static func content(reason: String?) -> Content? {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return Content(
            title: "Persistent sessions are off in this copy",
            message: reason + " New tabs in this copy run as ordinary tabs: their programs end when it quits."
        )
    }

    private(set) var phase: Phase = .idle
    private let reason: @Sendable () -> String?
    private let fallbackWindow: @MainActor () -> NSWindow?
    private let canPresent: @MainActor (NSWindow) -> Bool
    private let present: @MainActor (Content, NSWindow) -> Void
    private let retryDelay: TimeInterval
    private let retries: Int

    /// - Parameters:
    ///   - reason: why this copy does not use the sessions (nil when it
    ///     does); called once, off the main thread.
    ///   - fallbackWindow: another project window, for when the one that
    ///     registered cannot show the notice by then.
    ///   - canPresent: whether a window can show it now (on screen).
    ///   - present: shows it on a window.
    init(
        reason: @escaping @Sendable () -> String?,
        fallbackWindow: @escaping @MainActor () -> NSWindow? = { nil },
        canPresent: @escaping @MainActor (NSWindow) -> Bool = InstanceLockNotice.isOnScreen,
        present: @escaping @MainActor (Content, NSWindow) -> Void = InstanceLockNotice.presentSheet,
        retryDelay: TimeInterval = 0.5,
        retries: Int = 20
    ) {
        self.reason = reason
        self.fallbackWindow = fallbackWindow
        self.canPresent = canPresent
        self.present = present
        self.retryDelay = retryDelay
        self.retries = retries
    }

    /// The app's notice, for this copy's `AppInstanceLock.shared`, shown on
    /// `registry`'s project windows.
    static func app(registry: ProjectWindowRegistry) -> InstanceLockNotice {
        InstanceLockNotice(
            reason: { AppInstanceLock.shared.unavailableReason },
            fallbackWindow: { [weak registry] in registry?.firstRegisteredProjectWindow() }
        )
    }

    /// A project window registered. The first one starts the check; any
    /// one registering while the notice waits for a window may show it.
    func projectWindowDidRegister(_ window: NSWindow) {
        switch phase {
        case .idle:
            phase = .checking
            let reason = reason
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak window] in
                let content = Self.content(reason: reason())
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.checked(content, window: window)
                    }
                }
            }
        case .waitingForWindow(let content):
            presentIfPossible(content, preferring: window, retriesLeft: 0)
        case .checking, .shown, .notNeeded:
            break
        }
    }

    private func checked(_ content: Content?, window: NSWindow?) {
        guard phase == .checking else { return }
        guard let content else {
            phase = .notNeeded
            return
        }
        phase = .waitingForWindow(content)
        presentIfPossible(content, preferring: window, retriesLeft: retries)
    }

    private func presentIfPossible(_ content: Content, preferring preferred: NSWindow?, retriesLeft: Int) {
        guard phase == .waitingForWindow(content) else { return }
        let window = [preferred, fallbackWindow()].compactMap { $0 }.first(where: canPresent)
        guard let window else {
            // Not on screen yet: try again shortly, then leave it to the
            // next window that registers.
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak preferred] in
                MainActor.assumeIsolated {
                    self?.presentIfPossible(content, preferring: preferred, retriesLeft: retriesLeft - 1)
                }
            }
            return
        }
        phase = .shown
        present(content, window)
    }

    static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized
    }

    /// An informational alert sheet with an OK button: it holds up only its
    /// window, and a sheet already there (AppKit queues them) first.
    static func presentSheet(_ content: Content, on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

extension InstanceLockLaunchWait.Presenter {
    /// A small window in the middle of the screen with a spinner and the
    /// message, while a copy launched during the previous one's quit waits.
    static var app: InstanceLockLaunchWait.Presenter {
        @MainActor final class Holder {
            var window: NSWindow?
        }
        let holder = Holder()
        return InstanceLockLaunchWait.Presenter(
            show: { message in
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                let label = NSTextField(labelWithString: message)
                label.font = .systemFont(ofSize: 13)
                let stack = NSStackView(views: [spinner, label])
                stack.orientation = .horizontal
                stack.spacing = 10
                stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.title = "Cherry"
                window.contentView = stack
                window.center()
                window.makeKeyAndOrderFront(nil)
                holder.window = window
            },
            hide: {
                holder.window?.orderOut(nil)
                holder.window = nil
            }
        )
    }
}
