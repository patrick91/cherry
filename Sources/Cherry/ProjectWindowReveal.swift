import AppKit
import SwiftUI

/// A restored project window comes on screen with its tabs, not empty: from
/// the moment it registers (before AppKit first draws it) until its
/// repository's first restore has put the saved tabs, layout and selection
/// in place (`RepositoryWorkspace.whenInitialRestoreSettles`), the window is
/// transparent and lets clicks through. A slow or unreachable host never
/// leaves the user without a window: after `maximumWait` it shows anyway,
/// saying it is restoring its tabs (`WindowRestoringBar`) until they come.
///
/// The order is the gate's (`ProjectWindowRevealGate`); this type applies it
/// to an `NSWindow`.
@MainActor
enum ProjectWindowReveal {
    /// How long a window waits for its saved tabs before it shows anyway.
    /// The restore's own wait for its hosts (`hostedByDefault`'s
    /// `initialWait`) is longer: a host that answers late fills the window
    /// already shown.
    static let defaultMaximumWait: Duration = .milliseconds(1000)

    /// Keeps `window` off screen until `repository`'s first restore settled,
    /// at most `maximumWait`. Nothing when there is nothing to restore,
    /// unless the launch hid it already (`alreadyHidden`,
    /// `LaunchWindowCover`): it then shows on the next turn, once SwiftUI
    /// has laid it out.
    @discardableResult
    static func hold(
        _ window: NSWindow,
        until repository: RepositoryWorkspace?,
        name: String,
        alreadyHidden: Bool = false,
        maximumWait: Duration = defaultMaximumWait
    ) -> ProjectWindowRevealGate? {
        let awaitsRestore = repository?.isAwaitingInitialRestore ?? false
        guard awaitsRestore || alreadyHidden else { return nil }
        let previousIgnoresMouseEvents = alreadyHidden ? false : window.ignoresMouseEvents
        let gate = ProjectWindowRevealGate(
            maximumWait: maximumWait,
            hide: { [weak window] in
                window?.alphaValue = 0
                window?.ignoresMouseEvents = true
            },
            show: { [weak window] outcome in
                guard let window else { return }
                window.alphaValue = 1
                window.ignoresMouseEvents = previousIgnoresMouseEvents
                LaunchTimeline.mark("window shown \(name) (\(outcome))")
            }
        )
        gate.begin()
        if let repository, awaitsRestore {
            repository.whenInitialRestoreSettles { [weak gate] in gate?.contentIsReady() }
        } else {
            gate.contentIsReady()
        }
        return gate
    }
}

/// The windows the launch opens for its saved projects stay transparent
/// from the moment AppKit first orders them in, before SwiftUI has built
/// their content, laid it out and registered them (a window it built can
/// reach the screen, empty and at the default size, a few frames before
/// that): `expect` says how many are coming; each one that then becomes key
/// or main is hidden, until its registration hands it to
/// `ProjectWindowReveal` (`claim`). One that never registers shows after
/// `fallbackWait`; windows beyond those expected, or later than
/// `fallbackWait`, are left alone.
@MainActor
final class LaunchWindowCover {
    private final class Covered {
        weak var window: NSWindow?
        let ignoresMouseEvents: Bool
        init(_ window: NSWindow) {
            self.window = window
            ignoresMouseEvents = window.ignoresMouseEvents
        }
    }

    let fallbackWait: Duration
    /// Whether a window is one of the project windows expected (the app: a
    /// window of its project scene).
    let isCandidate: @MainActor (NSWindow) -> Bool
    private let schedule: ProjectWindowRevealGate.Schedule
    private let center: NotificationCenter
    private var expected = 0
    private var expectation = 0
    private var covered: [ObjectIdentifier: Covered] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Windows handed over already (`claim`), never covered again.
    private var claimed: [WeakWindowReference] = []

    init(
        fallbackWait: Duration = ProjectWindowReveal.defaultMaximumWait,
        center: NotificationCenter = .default,
        schedule: @escaping ProjectWindowRevealGate.Schedule = ProjectWindowRevealGate.mainQueueSchedule,
        isCandidate: @escaping @MainActor (NSWindow) -> Bool
    ) {
        self.fallbackWait = fallbackWait
        self.center = center
        self.schedule = schedule
        self.isCandidate = isCandidate
    }

    /// `count` project windows are about to open (the launch's saved ones).
    func expect(_ count: Int) {
        guard count > 0 else { return }
        expected += count
        expectation += 1
        let current = expectation
        if observers.isEmpty {
            // The first of these a window posts: SwiftUI places a window it
            // creates (didMove, didUpdate) before ordering it in; key and
            // main come once it is on screen.
            let names: [Notification.Name] = [
                NSWindow.didMoveNotification, NSWindow.didUpdateNotification, NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { self?.windowAppeared(window) }
                })
            }
        }
        // Windows that never came stop being expected.
        schedule(fallbackWait) { [weak self] in
            guard let self, self.expectation == current else { return }
            self.expected = 0
            self.stopObserving()
        }
    }

    /// Whether `window` is still waiting to be claimed.
    func isCovering(_ window: NSWindow) -> Bool {
        covered[ObjectIdentifier(window)] != nil
    }

    /// Hides `window` if it is one of the windows expected (AppKit ordered it
    /// in and made it key or main).
    func windowAppeared(_ window: NSWindow) {
        guard expected > 0, covered[ObjectIdentifier(window)] == nil,
              !claimed.contains(where: { $0.window === window }), isCandidate(window)
        else { return }
        expected -= 1
        if expected == 0 { stopObserving() }
        let entry = Covered(window)
        covered[ObjectIdentifier(window)] = entry
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        LaunchTimeline.mark("window covered \(window.identifier?.rawValue ?? "?")")
        schedule(fallbackWait) { [weak self, weak window] in
            guard let self, let window, self.covered.removeValue(forKey: ObjectIdentifier(window)) === entry else { return }
            window.alphaValue = 1
            window.ignoresMouseEvents = entry.ignoresMouseEvents
        }
    }

    /// The registry takes `window` over: true when this hid it (it is still
    /// transparent, and its reveal is the registry's now).
    func claim(_ window: NSWindow) -> Bool {
        claimed.removeAll { $0.window == nil }
        if !claimed.contains(where: { $0.window === window }) {
            claimed.append(WeakWindowReference(window))
        }
        return covered.removeValue(forKey: ObjectIdentifier(window)) != nil
    }

    private func stopObserving() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}

/// The order in which a window waiting for its content comes on screen:
/// `begin` hides it; it shows once, either a turn after its content is ready
/// (`contentIsReady`: SwiftUI has laid the restored tabs out by then) or
/// when `maximumWait` has passed, whichever comes first. Later calls do
/// nothing.
@MainActor
final class ProjectWindowRevealGate {
    enum Outcome: Equatable, CustomStringConvertible {
        /// The restored tabs were in place first.
        case contentReady
        /// The wait ran out first; the window says it is still restoring.
        case timedOut

        var description: String {
            switch self {
            case .contentReady: "content ready"
            case .timedOut: "timed out"
            }
        }
    }

    /// Runs `body` after `delay` on the main actor.
    typealias Schedule = @MainActor (_ delay: Duration, _ body: @escaping @MainActor () -> Void) -> Void

    static let mainQueueSchedule: Schedule = { delay, body in
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { body() }
        }
    }

    let maximumWait: Duration
    private let hide: @MainActor () -> Void
    private let show: @MainActor (Outcome) -> Void
    private let schedule: Schedule
    private(set) var isHidden = false
    /// How the window came on screen; nil while it waits (or before `begin`).
    private(set) var outcome: Outcome?
    private var isContentReady = false

    init(
        maximumWait: Duration,
        hide: @escaping @MainActor () -> Void,
        show: @escaping @MainActor (Outcome) -> Void,
        schedule: @escaping Schedule = ProjectWindowRevealGate.mainQueueSchedule
    ) {
        self.maximumWait = maximumWait
        self.hide = hide
        self.show = show
        self.schedule = schedule
    }

    /// Hides the window and starts the wait (once).
    func begin() {
        guard !isHidden, outcome == nil else { return }
        isHidden = true
        hide()
        // The gate lives as long as the wait: the window's own reference is
        // weak, and a gate nobody holds still shows its window.
        schedule(maximumWait) { self.finish(.timedOut) }
    }

    /// The restored tabs are in place: the window shows on the next turn,
    /// once SwiftUI has drawn them.
    func contentIsReady() {
        guard !isContentReady, outcome == nil else { return }
        isContentReady = true
        guard isHidden else { return }
        schedule(.zero) { self.finish(.contentReady) }
    }

    private func finish(_ result: Outcome) {
        guard outcome == nil, isHidden else { return }
        outcome = result
        isHidden = false
        show(result)
    }
}

/// "Restoring tabs…" at the bottom of a window that came on screen before
/// its saved tabs were back (`ProjectWindowReveal`'s wait ran out): the
/// window looks like itself, sidebar and all, rather than empty.
struct WindowRestoringBar: View {
    @ObservedObject var repository: RepositoryWorkspace

    var body: some View {
        if repository.isAwaitingInitialRestore {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Restoring tabs…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .projectWindowToastObstacle()
            .transition(.opacity)
        }
    }
}

private final class WeakWindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}
