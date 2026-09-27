import AppKit
import SwiftUI

// A short notice at the bottom of a project window that asks nothing and
// takes no focus: what just happened, and the actions that take it back or
// deal with it (a closed tab, with Undo; tabs detached or closed while their
// programs run on: `ClosedTabNotice`; sessions still at work in the
// background when Cherry opens: `BackgroundSessionsNotice`). Each window has
// one (`ProjectWindowChromeState.toasts`); a new toast replaces the one
// shown, except that an unprompted one (the launch's notice) takes turns
// with the others.

struct ProjectWindowToast: Identifiable {
    struct Action {
        let title: String
        /// The key that does the same, shown beside the title ("⌘Z").
        var shortcut: String?
        let perform: @MainActor () -> Void

        init(title: String, shortcut: String? = nil, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.shortcut = shortcut
            self.perform = perform
        }
    }

    /// How long it stays on screen (`ProjectWindowToasts.lifetime(of:voiceOverEnabled:)`).
    enum Length: Equatable, Sendable {
        /// What a close just did: a line to read, an action at most.
        case standard
        /// More to read and two actions to choose from (the launch's
        /// `BackgroundSessionsNotice`).
        case long
    }

    /// The symbol a closed tab's toast shows.
    static let closedSymbolName = "xmark.circle.fill"

    let id = UUID()
    /// Its title is `name` then `predicate` ("Claude", " is running in the
    /// background"): only the name is cut short when it does not fit.
    let name: String
    let predicate: String
    let message: String?
    /// Its buttons, in order. With more than one they sit under its text.
    let actions: [Action]
    let length: Length
    /// Whether it comes up without the user doing anything (the launch's
    /// `BackgroundSessionsNotice`), rather than after what they just did:
    /// its time runs only while its window is key in the active app, it
    /// waits for the toast shown to go, and a toast shown over it sets it
    /// aside until that one goes (`ProjectWindowToasts.show`).
    let isUnprompted: Bool
    /// Its time also stops while its window is not key in the active app,
    /// as an unprompted toast's does: a toast whose action undoes what the
    /// user did, which may be undone as long as it is up
    /// (`ClosedTabHistory`).
    let pausesWhileUnattended: Bool
    /// The SF Symbol beside its text.
    let symbolName: String
    /// Runs once when it leaves the screen by its dismiss button, by its
    /// time running out or by one of its actions (before the action); not
    /// when another toast replaces it or its window closes.
    let onDismiss: (@MainActor () -> Void)?

    init(
        name: String,
        predicate: String,
        message: String? = nil,
        actions: [Action],
        length: Length = .standard,
        isUnprompted: Bool = false,
        pausesWhileUnattended: Bool = false,
        symbolName: String = "play.circle.fill",
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.name = name
        self.predicate = predicate
        self.message = message
        self.actions = actions
        self.length = length
        self.isUnprompted = isUnprompted
        self.pausesWhileUnattended = isUnprompted || pausesWhileUnattended
        self.symbolName = symbolName
        self.onDismiss = onDismiss
    }

    init(
        name: String,
        predicate: String,
        message: String? = nil,
        action: Action? = nil,
        pausesWhileUnattended: Bool = false,
        symbolName: String = "play.circle.fill"
    ) {
        self.init(
            name: name, predicate: predicate, message: message, actions: action.map { [$0] } ?? [],
            pausesWhileUnattended: pausesWhileUnattended, symbolName: symbolName
        )
    }

    init(
        title: String,
        message: String? = nil,
        actions: [Action],
        length: Length = .standard,
        isUnprompted: Bool = false,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.init(
            name: "", predicate: title, message: message, actions: actions, length: length,
            isUnprompted: isUnprompted, onDismiss: onDismiss
        )
    }

    init(title: String, message: String? = nil, action: Action? = nil) {
        self.init(name: "", predicate: title, message: message, action: action)
    }

    var title: String { name + predicate }

    /// Its first action (a closed tab's Undo, a detached one's Reopen).
    var action: Action? { actions.first }

    /// What VoiceOver announces when it appears.
    var announcement: String {
        [title, message].compactMap { $0?.nilIfEmpty }.joined(separator: ". ")
    }
}

/// When a toast dismisses itself: once it has been on screen for
/// `lifetime`, not counting the time the pointer rested on it (nor, for an
/// unprompted toast or one that pauses while unattended, the time its window
/// was not key in the active app, or it waited its turn). A pointer that
/// leaves leaves it at least `graceAfterHover`, to finish reading. A closed
/// tab's undo window keeps the same time (`ClosedTabHistory`). Pure, for
/// tests.
struct ToastLifetime: Equatable {
    static let graceAfterHover: TimeInterval = 2

    /// Time left on screen, as of `runningSince` (or while paused).
    private(set) var remaining: TimeInterval
    /// When it last started counting down; nil while paused (the pointer
    /// rests on it, or an unprompted toast is not seen).
    private(set) var runningSince: Date?

    init(lifetime: TimeInterval, shownAt: Date) {
        remaining = lifetime
        runningSince = shownAt
    }

    /// When it dismisses itself; nil while paused.
    var deadline: Date? {
        runningSince.map { $0.addingTimeInterval(remaining) }
    }

    var isPaused: Bool { runningSince == nil }

    func isExpired(at now: Date) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    /// The pointer entered it (or it stopped being seen).
    mutating func pause(at now: Date) {
        guard let runningSince else { return }
        remaining = max(0, remaining - now.timeIntervalSince(runningSince))
        self.runningSince = nil
    }

    /// The pointer left it (or it is seen again).
    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        remaining = max(remaining, Self.graceAfterHover)
        runningSince = now
    }
}

/// A project window's toast (`ProjectWindowToastOverlay` shows it). Its own
/// object, not a published property of the chrome state, so a toast coming
/// and going does not re-render the window.
@MainActor
final class ProjectWindowToasts: ObservableObject {
    /// Runs `work` after a delay in seconds.
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// How long a toast stays on screen.
    static let lifetime: TimeInterval = 6
    /// How long a `.long` toast stays: twice as long, for twice as much to
    /// read and a choice to make.
    static let longLifetime: TimeInterval = 12
    /// How long it stays while VoiceOver runs: time to move the VoiceOver
    /// cursor from the terminal to it, which does not stop its time as the
    /// pointer does.
    static let voiceOverLifetime: TimeInterval = 30
    /// How long a `.long` toast stays while VoiceOver runs.
    static let longVoiceOverLifetime: TimeInterval = 60
    /// How often a paused toast looks whether the pointer still rests on it
    /// (`pointerProbe`), or whether its window is key again (`attentionProbe`).
    static let hoverRecheckInterval: TimeInterval = 1

    @Published private(set) var current: ProjectWindowToast?
    private var timing: ToastLifetime?
    /// An unprompted toast waiting for its turn (`show`), with the time it
    /// has left.
    private var waiting: (toast: ProjectWindowToast, timing: ToastLifetime)?
    /// Whether the pointer rests on the toast shown (`setHovering`).
    private var isHovered = false
    /// Whether the toast shown's window is key in the active app
    /// (`setAttended`); only the time of a toast that pauses while
    /// unattended depends on it.
    private var isAttended = true
    /// Only the latest scheduled check may act: one scheduled for a
    /// replaced toast, or before a pause or resume, does nothing.
    private var checkGeneration = 0
    /// Whether the pointer is over toast `id` (its view sets it). AppKit
    /// does not always say the pointer left (the window stopped being key,
    /// a sheet came up), so a paused toast asks this every
    /// `hoverRecheckInterval`; without one it counts as left.
    private var pointerProbe: (id: UUID, isOver: @MainActor () -> Bool)?
    /// Whether toast `id`'s window is key in the active app (its view sets
    /// it). A paused toast asks this every `hoverRecheckInterval` too, and
    /// an unprompted one asks it again before its time runs out, in case
    /// AppKit's notice did not reach it; without one it counts as seen.
    private var attentionProbe: (id: UUID, isAttended: @MainActor () -> Bool)?
    /// Told which toast the pointer rests on (nil: none), whenever that
    /// changes: the window's closed tabs stop their time while it rests on
    /// theirs (`ClosedTabHistory.setHoveredToast`).
    var hoverDidChange: (@MainActor (UUID?) -> Void)?
    /// The clock, scheduler and VoiceOver check, which the window's closed
    /// tabs share (`ClosedTabHistory(clockOf:)`).
    let now: @MainActor () -> Date
    let schedule: Scheduler
    private let announce: @MainActor (String) -> Void
    let voiceOverEnabled: @MainActor () -> Bool

    /// The app uses the defaults; tests inject a clock, a scheduler, what
    /// announces and whether VoiceOver runs.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        schedule: @escaping Scheduler = ProjectWindowToasts.scheduleOnMainQueue,
        announce: @escaping @MainActor (String) -> Void = ProjectWindowToasts.announceToAssistiveTechnologies,
        voiceOverEnabled: @escaping @MainActor () -> Bool = ProjectWindowToasts.isVoiceOverEnabled
    ) {
        self.now = now
        self.schedule = schedule
        self.announce = announce
        self.voiceOverEnabled = voiceOverEnabled
    }

    /// Shows `toast` in place of any other (whose `onDismiss` does not
    /// run), and announces it. An unprompted toast (`isUnprompted`) takes
    /// turns instead: it waits while a prompted one shows, and a prompted
    /// one shown over it sets it aside; either way it comes up, with the
    /// time it had left, once that one goes.
    func show(_ toast: ProjectWindowToast) {
        let lifetime = ToastLifetime(
            lifetime: Self.lifetime(of: toast.length, voiceOverEnabled: voiceOverEnabled()),
            shownAt: now()
        )
        if toast.isUnprompted, let current, !current.isUnprompted {
            waiting = (toast, Self.paused(lifetime, at: now()))
            return
        }
        if let current, current.isUnprompted, !toast.isUnprompted, let timing {
            waiting = (current, Self.paused(timing, at: now()))
        }
        present(toast, timing: lifetime)
    }

    /// Dismisses the toast shown (only if it is `id`, when given), and runs
    /// its `onDismiss`; then an unprompted toast waiting for its turn comes up.
    func dismiss(id: UUID? = nil) {
        guard let current, id == nil || current.id == id else { return }
        self.current = nil
        timing = nil
        checkGeneration += 1
        isHovered = false
        hoverDidChange?(nil)
        current.onDismiss?()
        if self.current == nil, let waiting {
            self.waiting = nil
            present(waiting.toast, timing: waiting.timing)
        }
    }

    private func present(_ toast: ProjectWindowToast, timing: ToastLifetime) {
        current = toast
        self.timing = timing
        isHovered = false
        // Until its view says otherwise.
        isAttended = true
        announce(toast.announcement)
        updateTiming()
    }

    private static func paused(_ timing: ToastLifetime, at now: Date) -> ToastLifetime {
        var timing = timing
        timing.pause(at: now)
        return timing
    }

    /// Its action button at `index`: dismisses it, then acts.
    func performAction(of id: UUID, at index: Int = 0) {
        guard let toast = current, toast.id == id, toast.actions.indices.contains(index) else { return }
        dismiss()
        toast.actions[index].perform()
    }

    /// The pointer entered or left toast `id`: its time stops while it rests there.
    func setHovering(_ hovering: Bool, id: UUID) {
        guard current?.id == id else { return }
        isHovered = hovering
        updateTiming()
    }

    /// Toast `id`'s window became key in the active app, or stopped being
    /// (the user went to another window or app): the time of a toast that
    /// pauses while unattended stops while nobody sees it.
    func setAttended(_ attended: Bool, id: UUID) {
        guard current?.id == id else { return }
        isAttended = attended
        updateTiming()
    }

    /// Toast `id`'s view tells where the pointer is (`pointerProbe`).
    func setPointerProbe(for id: UUID, _ isOver: @escaping @MainActor () -> Bool) {
        pointerProbe = (id, isOver)
    }

    /// Toast `id`'s view tells whether its window is key in the active app
    /// (`attentionProbe`).
    func setAttentionProbe(for id: UUID, _ isAttended: @escaping @MainActor () -> Bool) {
        attentionProbe = (id, isAttended)
    }

    /// Runs the shown toast's time, or stops it while the pointer rests on
    /// it or, for a toast that pauses while unattended, while its window is
    /// not key in the active app; then schedules the next check.
    private func updateTiming() {
        hoverDidChange?(isHovered ? current?.id : nil)
        guard var timing, let current else { return }
        if isHovered || (current.pausesWhileUnattended && !isAttended) {
            timing.pause(at: now())
        } else {
            timing.resume(at: now())
        }
        self.timing = timing
        scheduleCheck()
    }

    /// What toast `id`'s view says of its window now (`attentionProbe`);
    /// nil without one.
    private func probedAttention(of id: UUID) -> Bool? {
        guard let attentionProbe, attentionProbe.id == id else { return nil }
        return attentionProbe.isAttended()
    }

    /// The next check: when its time runs out, or, while paused, when it
    /// looks whether the pointer still rests on it and whether its window is
    /// key again.
    private func scheduleCheck() {
        guard let timing, let id = current?.id else { return }
        checkGeneration += 1
        let generation = checkGeneration
        let delay = timing.deadline.map { max(0, $0.timeIntervalSince(now())) } ?? Self.hoverRecheckInterval
        schedule(delay) { [weak self] in
            guard let self, self.checkGeneration == generation, self.current?.id == id else { return }
            self.check()
        }
    }

    private func check() {
        guard let timing, let current else { return }
        let id = current.id
        if timing.isPaused {
            // The pointer left, or the window became key again, without
            // AppKit saying so.
            let probe = pointerProbe?.id == id ? pointerProbe?.isOver : nil
            isHovered = probe?() == true
            isAttended = probedAttention(of: id) ?? isAttended
            updateTiming()
        } else if timing.isExpired(at: now()) {
            if current.pausesWhileUnattended, probedAttention(of: id) == false {
                // Its window stopped being key without AppKit saying so:
                // it goes once it has been seen.
                isAttended = false
                updateTiming()
            } else {
                dismiss()
            }
        } else {
            // A clock that ran late.
            scheduleCheck()
        }
    }

    static let scheduleOnMainQueue: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Asks VoiceOver to read `text` out, as a toast takes no focus.
    static let announceToAssistiveTechnologies: @MainActor (String) -> Void = { text in
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// How long a toast of `length` stays: longer while VoiceOver runs.
    static func lifetime(of length: ProjectWindowToast.Length = .standard, voiceOverEnabled: Bool) -> TimeInterval {
        switch length {
        case .standard: voiceOverEnabled ? voiceOverLifetime : lifetime
        case .long: voiceOverEnabled ? longVoiceOverLifetime : longLifetime
        }
    }

    static let isVoiceOverEnabled: @MainActor () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled
    }
}

/// The floating bars at the bottom of a terminal pane
/// (`CommandExitStatusBar`, `PersistentSessionReconnectBar`,
/// `PersistentSessionEndedBar`): the window's toast rises above them, so it
/// never hides their buttons.
struct ProjectWindowToastObstacles: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Keeps the project window's toast clear of this view.
    func projectWindowToastObstacle() -> some View {
        anchorPreference(key: ProjectWindowToastObstacles.self, value: .bounds) { [$0] }
    }
}

/// Where a project window shows its toast: centered at the bottom of its
/// detail pane, where a pane's bottom bars sit, or above them when one
/// shows; over the terminal, which keeps the keyboard. It slides up and
/// fades in (it only fades with Reduce Motion), and only the toast takes
/// clicks.
struct ProjectWindowToastOverlay: View {
    /// The bottom bars' distance from the pane's bottom edge.
    static let bottomInset: CGFloat = 14
    static let spacingAboveBars: CGFloat = 8
    static let horizontalInset: CGFloat = 16
    static let maxWidth: CGFloat = 460

    @ObservedObject var toasts: ProjectWindowToasts
    /// The window's closed tabs, whose undo window stops while the window is
    /// not key in the active app (`ClosedTabHistory.setAttended`).
    var closedTabs: ClosedTabHistory?
    /// The pane's bottom bars (`ProjectWindowToastObstacles`).
    var obstacles: [Anchor<CGRect>] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let bottom = Self.bottomInset(above: obstacles.map { proxy[$0] }, in: proxy.size)
            ZStack(alignment: .bottom) {
                if let toast = toasts.current {
                    ProjectWindowToastView(toast: toast, toasts: toasts)
                        .frame(maxWidth: Self.maxWidth)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, bottom)
            .animation(reduceMotion ? .easeInOut(duration: 0.18) : .snappy(duration: 0.26), value: toasts.current?.id)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: bottom)
        }
        .background {
            if let closedTabs {
                ClosedTabAttentionProbe(closedTabs: closedTabs)
            }
        }
    }

    /// How far above the bottom of a pane of `size` the toast sits: where
    /// the bottom bars do, or `spacingAboveBars` above the highest one of
    /// `bars` (frames in the pane) under its column. Pure, for tests.
    static func bottomInset(above bars: [CGRect], in size: CGSize) -> CGFloat {
        let width = min(maxWidth, max(0, size.width - 2 * horizontalInset))
        let left = (size.width - width) / 2
        let right = left + width
        let tops = bars.filter { $0.maxX > left && $0.minX < right && !$0.isEmpty }.map(\.minY)
        guard let top = tops.min() else { return bottomInset }
        return max(bottomInset, size.height - top + spacingAboveBars)
    }
}

private struct ProjectWindowToastView: View {
    let toast: ProjectWindowToast
    let toasts: ProjectWindowToasts
    @State private var isDismissHovered = false

    /// One action sits beside the text; more go in a row under it, so the
    /// text keeps the toast's width.
    private var actionsBelow: Bool { toast.actions.count > 1 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: toast.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if !toast.name.isEmpty {
                            Text(verbatim: toast.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // What happened stays readable; only the name is cut
                        // short. A title without one may wrap.
                        Text(verbatim: toast.predicate)
                            .lineLimit(toast.name.isEmpty ? 2 : 1)
                            .layoutPriority(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: toast.title))

                    if let message = toast.message {
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !actionsBelow {
                    actionButtons
                }

                dismissButton
            }

            if actionsBelow {
                HStack(spacing: 8) {
                    actionButtons
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)
        .background(ToastPointerProbe(toasts: toasts, id: toast.id))
        .background(ToastAttentionProbe(toasts: toasts, id: toast.id))
        .onHover { hovering in
            toasts.setHovering(hovering, id: toast.id)
        }
        // Its title, message and buttons are read as they are; its
        // appearance was announced.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(Array(toast.actions.enumerated()), id: \.offset) { index, action in
            Button {
                toasts.performAction(of: toast.id, at: index)
            } label: {
                HStack(spacing: 4) {
                    Text(action.title)
                    if let shortcut = action.shortcut {
                        Text(verbatim: shortcut)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .controlSize(.small)
            .focusable(false)
            .accessibilityLabel(Text(action.title))
            .help(action.shortcut.map { "\(action.title) (\($0))" } ?? action.title)
        }
    }

    private var dismissButton: some View {
        Button {
            toasts.dismiss(id: toast.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isDismissHovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isDismissHovered ? 0.1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isDismissHovered = $0 }
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

/// Tells the toast's model whether the pointer is over the toast, from
/// where the pointer is now rather than from hover events
/// (`ProjectWindowToasts.pointerProbe`); once the view is gone, it is not.
/// Takes no clicks.
private struct ToastPointerProbe: NSViewRepresentable {
    let toasts: ProjectWindowToasts
    let id: UUID

    final class ProbeView: NSView {
        var containsPointer: Bool {
            guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.contains(point)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        toasts.setPointerProbe(for: id) { [weak view] in view?.containsPointer == true }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}
}

/// Tells the toast's model whether its window is key in the active app
/// (`ProjectWindowToasts.setAttended`, `attentionProbe`): when the toast
/// comes into its window, and whenever the window or the app gains or loses
/// that. Once the view is gone, it is not. Takes no clicks.
private struct ToastAttentionProbe: NSViewRepresentable {
    let toasts: ProjectWindowToasts
    let id: UUID

    func makeNSView(context: Context) -> WindowAttentionProbeView {
        let view = WindowAttentionProbeView()
        let id = id
        view.onChange = { [weak toasts] attended in toasts?.setAttended(attended, id: id) }
        toasts.setAttentionProbe(for: id) { [weak view] in view?.isAttended == true }
        return view
    }

    func updateNSView(_ view: WindowAttentionProbeView, context: Context) {}
}

/// Tells a window's closed tabs whether the window is key in the active app
/// (`ClosedTabHistory.setAttended`), for as long as the window shows its
/// toast overlay, whether or not a toast is up. Takes no clicks.
private struct ClosedTabAttentionProbe: NSViewRepresentable {
    let closedTabs: ClosedTabHistory

    func makeNSView(context: Context) -> WindowAttentionProbeView {
        let view = WindowAttentionProbeView()
        view.onChange = { [weak closedTabs] attended in closedTabs?.setAttended(attended) }
        return view
    }

    func updateNSView(_ view: WindowAttentionProbeView, context: Context) {
        view.onChange = { [weak closedTabs] attended in closedTabs?.setAttended(attended) }
    }
}

/// Reports whether its window is key in the active app: when it comes into
/// the window, and whenever the window or the app gains or loses that.
private final class WindowAttentionProbeView: NSView {
    var onChange: (@MainActor (Bool) -> Void)?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    var isAttended: Bool {
        guard let window else { return false }
        return window.isKeyWindow && NSApp.isActive
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let changes: [(Notification.Name, AnyObject)] = [
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp),
            (NSApplication.didResignActiveNotification, NSApp),
        ]
        observers = changes.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    private func report() {
        onChange?(isAttended)
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
