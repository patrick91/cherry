import AppKit

/// Tells the user once, when Cherry opens, that programs of this app are
/// still at work in the background (`BackgroundSessions`): they belong to
/// windows or tabs closed earlier, and nothing on screen shows them.
///
/// It checks once the launch's windows opened and restored their tabs (and
/// looked for orphaned sessions), from a complete list of the local host,
/// and only when this run reached the host already: it never starts one.
/// It names only sessions at work (`BackgroundSession.isAtWork`: an agent, a
/// command, or a terminal whose host reports a job in its foreground; an
/// idle shell stays in the menu bar's list) that it has not told about
/// (`noteTold`). Told about are the sessions the user kept on purpose: a
/// detached tab's (⌘D, Detach), a window's closed with Keep Running or
/// while Settings › Sessions keeps them. So are those a notice named once
/// it was dismissed, ran out its time or was acted on. Sessions that went to the background without a
/// choice (orphans, a Create that answered after its tab closed, a command
/// a restore set aside, a window closed without its question) are named.
/// It is a toast in the first project window, as a closed tab's is
/// (`ProjectWindowToasts`): Reopen, End…, and dismiss. Nobody asked for it,
/// so it is an unprompted toast: its time runs only while its window is key
/// in the active app, and it takes turns with a closed tab's toast rather
/// than replacing one or being replaced. Off in Settings › Sessions
/// (`sessions.backgroundNoticeAtLaunch`).
@MainActor
final class BackgroundSessionsNotice {
    struct Content: Equatable, Sendable {
        let title: String
        let message: String
        /// The background sessions at work it names.
        let sessionIDs: [String]
    }

    enum Phase: Equatable {
        /// The launch's windows have not opened yet.
        case idle
        /// Waiting for their restores, then listing the host.
        case checking
        /// Needed, and waiting for a project window that can show it.
        case waitingForWindow(Content)
        /// Its toast went to a project window (on screen, or waiting there
        /// for a closed tab's toast to go).
        case shown(Content)
        /// Nothing to tell, off in Settings, or this run cannot ask the host.
        case notNeeded
    }

    /// The sessions told about (UserDefaults, [String]), kept to those the
    /// host still lists.
    static let toldIDsKey = "sessions.backgroundNoticeToldIDs"
    /// The most told ids kept, newest last.
    static let toldIDsLimit = 512

    private(set) var phase: Phase = .idle
    private let model: BackgroundSessionsModel
    private let registry: ProjectWindowRegistry
    private let isEnabled: @MainActor () -> Bool
    private let defaults: UserDefaults
    private let canPresent: @MainActor (NSWindow) -> Bool
    private let settleDelay: Duration
    private let restoreWait: Duration
    private let retryDelay: TimeInterval
    private let retries: Int
    /// Looks at devices without starting their daemons.
    private let peeks: RemoteDevicePeeks

    /// - Parameters:
    ///   - isEnabled: Settings › Sessions' "Tell me about background
    ///     sessions when Cherry opens".
    ///   - defaults: where the sessions told about are kept.
    ///   - canPresent: whether a window can show it now (on screen).
    ///   - settleDelay: how long after the launch's windows were asked to
    ///     open it starts waiting for them.
    ///   - restoreWait: how long, at most, it waits for them to open and
    ///     restore their tabs.
    init(
        model: BackgroundSessionsModel,
        registry: ProjectWindowRegistry,
        isEnabled: @escaping @MainActor () -> Bool = { TerminalSettings.shared.noticeBackgroundSessionsAtLaunch },
        defaults: UserDefaults = .standard,
        canPresent: @escaping @MainActor (NSWindow) -> Bool = InstanceLockNotice.isOnScreen,
        settleDelay: Duration = .seconds(2),
        restoreWait: Duration = .seconds(20),
        retryDelay: TimeInterval = 0.5,
        retries: Int = 20,
        peeks: RemoteDevicePeeks = .shared
    ) {
        self.peeks = peeks
        self.model = model
        self.registry = registry
        self.isEnabled = isEnabled
        self.defaults = defaults
        self.canPresent = canPresent
        self.settleDelay = settleDelay
        self.restoreWait = restoreWait
        self.retryDelay = retryDelay
        self.retries = retries
    }

    /// The app's notice, for `BackgroundSessionsModel.shared`, shown on
    /// `registry`'s project windows.
    static func app(registry: ProjectWindowRegistry) -> BackgroundSessionsNotice {
        BackgroundSessionsNotice(model: .shared, registry: registry)
    }

    /// The launch asked for its windows (`projectRoots`: the ones it
    /// reopens): once they have opened and restored their tabs, it checks,
    /// once per run.
    func launchWindowsOpened(expecting projectRoots: [String] = []) {
        guard phase == .idle else { return }
        phase = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            let content = await self.check(expecting: projectRoots)
            self.checked(content)
        }
    }

    /// A project window registered: one registering while the notice waits
    /// for a window may show it. A window registers from its SwiftUI view's
    /// update, so the toast (SwiftUI state) goes up on the next turn of the
    /// main queue; its phase keeps it to once.
    func projectWindowDidRegister(_ window: NSWindow) {
        guard case .waitingForWindow(let content) = phase else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                self?.presentIfPossible(content, preferring: window, retriesLeft: 0)
            }
        }
    }

    /// What to say, if anything: the background sessions at work of a
    /// complete list that it has not told about.
    private func check(expecting projectRoots: [String]) async -> Content? {
        try? await Task.sleep(for: settleDelay)
        let deadline = ContinuousClock.now + restoreWait
        while projectRoots.contains(where: { !registry.hasWindow(for: $0) }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for repository in registry.allRepositories {
            await repository.waitUntilSessionsRestored(before: deadline)
        }
        guard isEnabled() else { return nil }
        var background: [BackgroundSession] = []
        var listedIDs = Set<String>()
        var everyHostAnswered = true
        hostingBySession = [:]
        let localSessions = model.localSessions
        if localSessions.instanceUnavailableReason == nil, localSessions.connectionGeneration > 0,
           let list = try? await localSessions.completeList(), !list.awaitsHolders {
            listedIDs.formUnion(list.sessions.map(\.id))
            let found = model.backgroundSessions(in: list.sessions, hostID: list.hostID)
            for session in found { hostingBySession[session.id] = localSessions }
            background += found
        } else {
            everyHostAnswered = false
        }
        // Each device this run reached that answers now (phase 3): over its
        // connection when connected, else by a look that never starts or
        // replaces its daemon (`RemoteDevicePeeks`).
        model.refresh()
        for device in model.devices {
            let hosting = device.localSessions
            guard hosting.instanceUnavailableReason == nil, hosting.connectionGeneration > 0,
                  let list = await deviceList(hosting), !list.awaitsHolders
            else {
                everyHostAnswered = false
                continue
            }
            listedIDs.formUnion(list.sessions.map(\.id))
            let found = device.backgroundSessions(in: list.sessions, hostID: list.hostID)
            for session in found { hostingBySession[session.id] = hosting }
            background += found
        }
        let told = toldIDs()
        // Told ids of a host that did not answer stay told.
        let stillListed = everyHostAnswered ? told.filter(listedIDs.contains) : told
        if stillListed != told { defaults.set(stillListed, forKey: Self.toldIDsKey) }
        let untold = background.filter { $0.isAtWork && !stillListed.contains($0.id) }
        return untold.isEmpty ? nil : Self.content(for: untold)
    }

    /// Which hosting each session the notice named runs on (This Mac's or
    /// a device's), for Reopen.
    private var hostingBySession: [String: PersistentHostSessions] = [:]
    /// How long a device may take to answer the notice's list.
    private let deviceListTimeout: Duration = .seconds(10)

    /// A device's sessions: what its connection knows when connected, else
    /// a look that starts nothing (nil: none runs, or no answer in time).
    private func deviceList(_ hosting: PersistentHostSessions) async -> HostedSessionList? {
        let control = hosting.control
        if control.state == .connected, let hostID = control.hostID {
            return HostedSessionList(hostID: hostID, sessions: control.sessions, pendingHolders: control.expectsHolders ? 1 : 0)
        }
        let peeks = peeks
        let peek = await Self.within(deviceListTimeout) { await peeks.refresh(control) }
        if case .listed(let list)?? = peek { return list }
        return nil
    }

    /// `work`'s answer, or nil when it takes longer than `timeout`.
    private static func within<T: Sendable>(_ timeout: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        let once = ResumeOnceBox<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in once.resume(continuation, with: await work()) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(continuation, with: nil)
            }
        }
    }

    private func checked(_ content: Content?) {
        guard phase == .checking else { return }
        guard let content else {
            phase = .notNeeded
            return
        }
        phase = .waitingForWindow(content)
        presentIfPossible(content, preferring: nil, retriesLeft: retries)
    }

    private func presentIfPossible(_ content: Content, preferring preferred: NSWindow?, retriesLeft: Int) {
        guard phase == .waitingForWindow(content) else { return }
        guard let (window, chromeState) = toastTarget(preferring: preferred) else {
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
        phase = .shown(content)
        chromeState.toasts.show(toast(for: content, on: window))
    }

    /// The project window that shows the toast, and its chrome: `preferred`
    /// (one that just registered), else the first project window, when it
    /// is on screen.
    private func toastTarget(preferring preferred: NSWindow?) -> (NSWindow, ProjectWindowChromeState)? {
        for window in [preferred, registry.firstRegisteredProjectWindow()].compactMap({ $0 }) where canPresent(window) {
            if let chromeState = registry.chromeState(for: window) { return (window, chromeState) }
        }
        return nil
    }

    /// The toast that names `content`'s sessions in `window`: Reopen brings
    /// them back, End… asks to end them, and once it is gone (dismissed,
    /// its time run out while its window was key in the active app, or
    /// acted on) they count as told about, as Keep Running did.
    func toast(for content: Content, on window: NSWindow) -> ProjectWindowToast {
        let ids = content.sessionIDs
        return ProjectWindowToast(
            title: content.title,
            message: content.message,
            actions: [
                ProjectWindowToast.Action(title: "Reopen") { [weak self] in
                    self?.reopen(ids)
                },
                ProjectWindowToast.Action(title: "End…") { [weak self, weak window] in
                    self?.model.confirmEndAll(from: window, limitedTo: ids)
                },
            ],
            length: .long,
            isUnprompted: true,
            onDismiss: { [weak self] in
                self?.noteTold(ids)
            }
        )
    }

    /// Reopen: shows each of the sessions in a tab, one after the other,
    /// the way a closed tab's toast brings its sessions back
    /// (`SessionCloseCoordinator.reopen`, as Background Sessions → Open:
    /// each in its own project's window, opened again when it is closed).
    @discardableResult
    func reopen(_ ids: [String]) -> Task<Void, Never> {
        let model = model
        let registry = registry
        return Task { @MainActor in
            for id in ids {
                await SessionCloseCoordinator.reopen(
                    .backgroundSession(id: id), hosting: self.hostingBySession[id] ?? model.localSessions, into: nil,
                    chromeState: nil, registry: registry
                )
            }
            model.refresh()
        }
    }

    /// The user knows these sessions keep running in the background: they
    /// kept them (a tab or window closed keeping its sessions), or a notice
    /// named them. Later launches do not name them.
    func noteTold(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var told = toldIDs().filter { !ids.contains($0) }
        told.append(contentsOf: ids)
        if told.count > Self.toldIDsLimit {
            told.removeFirst(told.count - Self.toldIDsLimit)
        }
        defaults.set(told, forKey: Self.toldIDsKey)
    }

    func toldIDs() -> [String] {
        defaults.stringArray(forKey: Self.toldIDsKey) ?? []
    }

    /// "3 sessions are still running in the background", the projects they
    /// belong to (two by name, then how many more), and where to find them.
    static func content(for sessions: [BackgroundSession]) -> Content {
        let single = sessions.count == 1
        var projects: [String] = []
        for session in sessions where session.projectRoot != nil {
            // A device's project names its Mac.
            let name = session.machine.map { "\(session.projectName) on \($0)" } ?? session.projectName
            if !projects.contains(name) { projects.append(name) }
        }
        let named: String? = switch projects.count {
        case 0: nil
        case 1: projects[0]
        case 2: "\(projects[0]) and \(projects[1])"
        default: "\(projects[0]), \(projects[1]) and \(projects.count - 2) more"
        }
        let from = single ? "From a tab or window you closed" : "From tabs or windows you closed"
        let whereTo = single
            ? ClosedTabNotice.backgroundSessionsMessage
            : ClosedTabNotice.backgroundSessionsMessagePlural
        return Content(
            title: single
                ? "1 session is still running in the background"
                : "\(sessions.count) sessions are still running in the background",
            message: from + (named.map { " (\($0))" } ?? "") + ". " + whereTo,
            sessionIDs: sessions.map(\.id)
        )
    }
}

/// Resumes a continuation once, whichever answer comes first.
@MainActor
private final class ResumeOnceBox<T: Sendable> {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<T?, Never>, with value: T?) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
