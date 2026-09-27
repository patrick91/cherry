import AppKit
import Combine
import Foundation

// Background sessions (docs/specs/multiplexer-default.md): this app's own
// sessions on the local host that no open tab shows. They come from closed
// project windows whose sessions were kept, detached tabs (⌘D, Detach),
// command tabs a restore set aside, Creates that
// answered after a detaching close, and orphans of projects whose window is
// not open. The menu bar extra lists them (Open, End), the Cherry menu and
// Settings › Sessions end them all, and a launch notice says once that those
// at work run on when the user did not choose to keep them
// (`BackgroundSessionsNotice`).

/// A session of this app that no open tab shows, as the Background
/// Sessions list shows it. Nothing here changes while its program runs on
/// by itself (an agent's spinner title is left out), so the list publishes
/// only when a session comes, goes, ends, or changes what it runs.
struct BackgroundSession: Equatable, Identifiable, Sendable {
    /// The host's session id.
    let id: String
    let hostID: String
    /// The command's or agent's name, or the session's.
    let title: String
    let kind: TerminalSession.SessionKind
    /// The agent (`cherry.agent`), for its logo.
    let agentKey: String?
    let commandName: String?
    /// The worktree its tab ran in (`cherry.project`).
    let projectRoot: String?
    let projectName: String
    /// What a busy terminal runs in its foreground.
    let foregroundName: String?
    let isBusy: Bool
    /// The status its program ended with (128 + N after signal N); nil
    /// while it runs.
    let exitStatus: Int32?
    /// Clients attached to it (a terminal outside Cherry).
    let clients: Int
    let createdAt: Date?

    var isRunning: Bool { exitStatus == nil }

    /// Its program is at work, as a closed tab's toast counts it
    /// (`ClosedTabNotice.programIsAtWork`): a command or an agent that
    /// runs, or a terminal whose host reports a job in its shell's
    /// foreground. An idle shell is not.
    var isAtWork: Bool {
        isRunning && (kind != .terminal || isBusy)
    }
}

/// How a background session is named and described; pure, for tests.
enum BackgroundSessionPresentation {
    /// The status dot: a program at work, an idle one, or none once ended.
    enum Tone: Equatable {
        case active
        case idle
        case ended
    }

    static func session(_ info: HostedSessionInfo, hostID: String) -> BackgroundSession {
        let kind = info.tags[PersistentSessionTag.kind].flatMap(TerminalSession.SessionKind.init(rawValue:)) ?? .terminal
        let projectRoot = OrphanedSessionCriteria.projectRoot(of: info)
        return BackgroundSession(
            id: info.id,
            hostID: hostID,
            title: title(of: info, kind: kind),
            kind: kind,
            agentKey: kind == .agent ? info.tags[PersistentSessionTag.agent]?.nilIfEmpty : nil,
            commandName: kind == .command ? info.tags[PersistentSessionTag.command]?.nilIfEmpty : nil,
            projectRoot: projectRoot,
            projectName: projectName(projectRoot: projectRoot),
            foregroundName: info.isBusy ? info.foreground?.name.nilIfEmpty : nil,
            isBusy: info.isBusy,
            exitStatus: info.isRunning ? nil : PersistentLocalSessions.exitStatus(of: info),
            clients: info.clients,
            createdAt: info.createdDate
        )
    }

    /// A command by its name, an agent by its name (else the session's), a
    /// terminal by the session's name. Never a title the program set.
    static func title(of info: HostedSessionInfo, kind: TerminalSession.SessionKind) -> String {
        let tagged: String? = switch kind {
        case .command: info.tags[PersistentSessionTag.command]?.nilIfEmpty
        case .agent: info.tags[PersistentSessionTag.agent]?.nilIfEmpty
        case .terminal: nil
        }
        return tagged ?? info.displayName
    }

    static func projectName(projectRoot: String?) -> String {
        projectRoot.map(MenuBarAgentPresentation.projectName(projectRoot:)) ?? "No project"
    }

    /// "exit N" once ended, "attached" while a client shows it, what a busy
    /// terminal runs, "running" for a command or agent, else "idle".
    static func statusText(of session: BackgroundSession) -> String {
        if let status = session.exitStatus { return "exit \(status)" }
        if session.clients > 0 { return "attached" }
        switch session.kind {
        case .terminal:
            return session.isBusy ? session.foregroundName ?? "running" : "idle"
        case .command, .agent:
            return "running"
        }
    }

    static func tone(of session: BackgroundSession) -> Tone {
        guard session.isRunning else { return .ended }
        return session.isAtWork ? .active : .idle
    }

    /// How long a row's inline "End Session" ignores clicks after it
    /// replaced End in the same spot: the second click of a double click.
    static let confirmationDelay: TimeInterval = 0.45

    /// Whether a click on "End Session", shown at `shownAt`, confirms.
    static func acceptsConfirmation(shownAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(shownAt) >= confirmationDelay
    }
}

enum BackgroundSessions {
    /// This app's sessions in `sessions` (of the local host `hostID`) that
    /// are in the background: `owner`'s, not shown by an open tab
    /// (`isShown`), not being ended (`isEnding`), and not named by a saved
    /// tab an open window may still restore (`awaitingRestore`). Running
    /// and ended ones, by project, running first, newest first.
    static func classify(
        _ sessions: [HostedSessionInfo],
        hostID: String,
        owner: String,
        isShown: (HostedSessionInfo) -> Bool,
        isEnding: (HostedSessionInfo) -> Bool,
        awaitingRestore: [WorkspaceSessionRecord]
    ) -> [BackgroundSession] {
        sessions
            .filter { info in
                info.owner == owner
                    && !isShown(info)
                    && !isEnding(info)
                    && !awaitingRestore.contains { record in
                        PersistentLocalSessions.record(record, names: info, hostID: hostID, owner: owner, includingAttached: true)
                    }
            }
            .map { BackgroundSessionPresentation.session($0, hostID: hostID) }
            .sorted { lhs, rhs in
                let byProject = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
                if byProject != .orderedSame { return byProject == .orderedAscending }
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                let lhsCreated = lhs.createdAt ?? .distantPast
                let rhsCreated = rhs.createdAt ?? .distantPast
                if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
                return lhs.id < rhs.id
            }
    }
}

/// How many sessions are in the background: all the app itself observes
/// (the Cherry menu's End Background Sessions…), so changes to the list do
/// not re-evaluate the app's body and menus.
@MainActor
final class BackgroundSessionsSummary: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var runningCount = 0

    func update(_ sessions: [BackgroundSession]) {
        let running = sessions.filter(\.isRunning).count
        if count != sessions.count { count = sessions.count }
        if runningCount != running { runningCount = running }
    }
}

/// The Background Sessions list, kept current from the local host's
/// control connection, and what can be done with it: Open, End, End All.
///
/// Only this copy of the app lists or ends anything (`AppInstanceLock`),
/// and only its own identity's sessions: never ownerless ones (`cherry
/// new`, the Persistent Sessions sheet's Create) or another identity's.
/// It never starts a session host just to list: it reads the sessions the
/// control connection last knew, and connects only once this run reached
/// the host, local tabs run in it, or it lists sessions already. While it
/// lists any, it keeps the connection up (the list would go stale once an
/// unused connection closes); opening the panel lists the host once.
///
/// A terminal whose shell exited with status 0 would have closed its tab
/// (Settings › Sessions › Close a tab when its shell exits): as a window's
/// restore does, the list removes its session instead of showing it.
///
/// It refreshes every second (reading only what is in memory: the host's
/// last list, the open tabs, the windows' saved tabs) and on the host's
/// added, removed, exited and resync events, and publishes only when the
/// list changed.
@MainActor
final class BackgroundSessionsModel: ObservableObject {
    static let shared = BackgroundSessionsModel(localSessions: .shared, registry: .shared)

    /// Shows the End All confirmation, on the window it was asked from
    /// (nil: the menu bar panel or the Cherry menu), and reports which
    /// button answered it.
    typealias AlertPresenter = @MainActor (
        NSAlert,
        NSWindow?,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void

    @Published private(set) var sessions: [BackgroundSession] = []
    let summary = BackgroundSessionsSummary()
    let localSessions: PersistentLocalSessions
    private let registry: ProjectWindowRegistry
    private let attachedTabs: OpenHostedTabs
    private let prefersPersistentLocalSessions: @MainActor () -> Bool
    private let closesTabsOnCleanExit: @MainActor () -> Bool
    private let presentAlert: AlertPresenter
    private var timer: Timer?
    private var eventSubscription: AnyCancellable?
    private var isRefreshScheduled = false
    private var lease: HostControlLease?
    /// The identity of the host the list is from: the control forgets it
    /// while it is not connected.
    private var knownHostID: String?
    /// Sessions End was asked for that wait for the connection before their
    /// ending starts: out of the list at once.
    private var endsRequested: Set<String> = []

    /// The app uses `shared`; tests inject the local sessions, the windows,
    /// the attached tabs, the settings and the End All confirmation.
    init(
        localSessions: PersistentLocalSessions,
        registry: ProjectWindowRegistry,
        attachedTabs: OpenHostedTabs = .shared,
        prefersPersistentLocalSessions: @escaping @MainActor () -> Bool = { TerminalSettings.shared.persistLocalSessions },
        closesTabsOnCleanExit: @escaping @MainActor () -> Bool = { TerminalSettings.shared.closeTabsOnCleanExit },
        presentAlert: @escaping AlertPresenter = BackgroundSessionsModel.presentOnProjectWindow
    ) {
        self.localSessions = localSessions
        self.registry = registry
        self.attachedTabs = attachedTabs
        self.prefersPersistentLocalSessions = prefersPersistentLocalSessions
        self.closesTabsOnCleanExit = closesTabsOnCleanExit
        self.presentAlert = presentAlert
    }

    /// Starts following the host (the app: once launched, after the local
    /// host's warm-up, so the instance lock is known). Nothing connects.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // HostControl publishes on the main actor. Title, directory and
        // foreground changes wait for the next tick.
        eventSubscription = localSessions.control.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                switch event {
                case .added, .removed, .exited, .resync:
                    self?.scheduleRefresh()
                case .changed, .bell, .notification, .progress:
                    break
                }
            }
        }
        refresh()
    }

    /// Stops following the host and lets the connection go (tests).
    func stop() {
        timer?.invalidate()
        timer = nil
        eventSubscription = nil
        sessions = []
        summary.update([])
        lease?.release()
        lease = nil
    }

    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRefreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Lists the background sessions again from what the control
    /// connection knows; publishes only a change. Terminals whose shell
    /// exited with status 0 are removed rather than listed
    /// (`removeCleanlyEndedTerminals`).
    func refresh() {
        let control = localSessions.control
        if let hostID = control.hostID { knownHostID = hostID }
        var listed = knownHostID.map { backgroundSessions(in: control.sessions, hostID: $0) } ?? []
        listed = removeCleanlyEndedTerminals(listed)
        if listed != sessions { sessions = listed }
        summary.update(listed)
        updateLease()
    }

    /// Ends (removes: nothing runs) the terminals of `listed` whose shell
    /// exited with status 0, while Settings › Sessions closes such tabs: an
    /// open tab would have closed, and its window's restore removes them
    /// too, so Open could only reopen a window that deletes them. Only from
    /// a live list, so no host is started for it. Returns the others.
    private func removeCleanlyEndedTerminals(_ listed: [BackgroundSession]) -> [BackgroundSession] {
        let control = localSessions.control
        guard control.state == .connected, let hostID = control.hostID,
              listed.contains(where: { $0.kind == .terminal && $0.exitStatus == 0 }),
              closesTabsOnCleanExit()
        else { return listed }
        let removed = Set(control.sessions.compactMap { info -> String? in
            guard PersistentLocalSessions.endedCleanly(info),
                  listed.contains(where: { $0.id == info.id && $0.kind == .terminal }),
                  let attachment = localSessions.attachment(for: info), attachment.hostID == hostID
            else { return nil }
            localSessions.end(attachment)
            return info.id
        })
        return listed.filter { !removed.contains($0.id) }
    }

    /// Which of `sessions` (of the local host `hostID`) are in the
    /// background now (`BackgroundSessions.classify`); none for a copy of
    /// the app that does not own this Mac's sessions.
    func backgroundSessions(in sessions: [HostedSessionInfo], hostID: String) -> [BackgroundSession] {
        let localSessions = localSessions
        guard localSessions.instanceUnavailableReason == nil,
              sessions.contains(where: { $0.owner == localSessions.owner })
        else { return [] }
        let attachedTabs = attachedTabs
        let endsRequested = endsRequested
        return BackgroundSessions.classify(
            sessions,
            hostID: hostID,
            owner: localSessions.owner,
            isShown: { localSessions.isShownByOpenTab($0, hostID: hostID, attachedTabs: attachedTabs) },
            isEnding: { info in
                endsRequested.contains(info.id)
                    || localSessions.isEnding(info.id)
                    || localSessions.isScheduledToEnd(info, hostID: hostID)
            },
            awaitingRestore: registry.sessionRecordsAwaitingRestore()
        )
    }

    /// How the Persistent Sessions sheet marks a session of This Mac: this
    /// app's own ones only.
    func ownershipLabel(for info: HostedSessionInfo, hostID: String) -> String? {
        guard info.owner == localSessions.owner else { return nil }
        if isEnding(info, hostID: hostID) { return "Ending" }
        if localSessions.isShownByOpenTab(info, hostID: hostID, attachedTabs: attachedTabs) { return "In a tab" }
        return backgroundSessions(in: [info], hostID: hostID).isEmpty ? "This app" : "In the background"
    }

    /// Whether this app is ending its session `info` (of the local host
    /// `hostID`): its tab closed, and the end may still wait for ⌘Z to no
    /// longer bring the tab back (`PersistentLocalSessions.deferEnd`), or
    /// End was asked for it. The Persistent Sessions sheet does not attach
    /// it: a tab attached to it would not own it, and would lose it to the
    /// end, or keep it running unowned once ⌘Z brought its own tab back.
    func isEnding(_ info: HostedSessionInfo, hostID: String) -> Bool {
        info.owner == localSessions.owner
            && (endsRequested.contains(info.id) || localSessions.isEnding(info.id)
                || localSessions.isScheduledToEnd(info, hostID: hostID))
    }

    // MARK: Panel

    /// The menu bar panel opened: the list is refreshed, and the host
    /// listed once when the connection is down and may be made. Nothing
    /// holds the connection for the panel: it stays up while the list has
    /// sessions, and an unused one closes by itself.
    func panelDidAppear() {
        refresh()
        let control = localSessions.control
        guard control.state != .connected, mayConnect else { return }
        Task { @MainActor [weak self] in
            _ = try? await control.list()
            self?.refresh()
        }
    }

    /// Whether the list may connect to the local host (which starts one
    /// when none runs): only in the copy that owns this Mac's sessions, and
    /// only once this run reached the host, when local tabs run in it, or
    /// while it lists sessions.
    private var mayConnect: Bool {
        localSessions.instanceUnavailableReason == nil
            && (localSessions.connectionGeneration > 0 || prefersPersistentLocalSessions() || !sessions.isEmpty)
    }

    private func updateLease() {
        let needed = !sessions.isEmpty
        if needed, lease == nil {
            lease = localSessions.control.retain()
        } else if !needed, let lease {
            lease.release()
            self.lease = nil
        }
    }

    // MARK: Actions

    /// Shows the session in a tab (`ProjectWindowRegistry.showBackgroundSession`).
    @discardableResult
    func open(_ item: BackgroundSession) -> Task<Void, Never>? {
        guard let info = localSessions.control.sessions.first(where: { $0.id == item.id }) else { return nil }
        let registry = registry
        let localSessions = localSessions
        let attachedTabs = attachedTabs
        return Task { @MainActor [weak self] in
            await registry.showBackgroundSession(info, localSessions: localSessions, attachedTabs: attachedTabs)
            self?.refresh()
        }
    }

    @discardableResult
    func end(_ item: BackgroundSession) -> Task<Void, Never>? {
        end(sessionID: item.id)
    }

    /// Ends the session when it is still in the background: Kill, wait for
    /// its exit, then Remove (an ended one is only removed), retried for
    /// `endRetryWindow` (`PersistentLocalSessions.end`). It leaves the list
    /// at once. A closed window's saved tab for it is not rewritten: that
    /// window's restore drops it, since the host no longer lists it.
    @discardableResult
    func end(sessionID: String) -> Task<Void, Never>? {
        let control = localSessions.control
        guard let hostID = control.hostID ?? knownHostID,
              let info = control.sessions.first(where: { $0.id == sessionID }),
              !backgroundSessions(in: [info], hostID: hostID).isEmpty
        else { return nil }
        let timeout = localSessions.configuration.endRetryWindow
        if let attachment = localSessions.attachment(for: info), control.hostID == hostID {
            let ending = localSessions.end(attachment, waitingForExitUpTo: timeout)
            refresh()
            return ending
        }
        endsRequested.insert(sessionID)
        refresh()
        let localSessions = localSessions
        return Task { @MainActor [weak self] in
            _ = try? await control.connect()
            let current = localSessions.sessionInfo(sessionID) ?? info
            let ending = control.hostID == hostID
                ? localSessions.attachment(for: current).map { localSessions.end($0, waitingForExitUpTo: timeout) }
                : nil
            self?.endsRequested.remove(sessionID)
            self?.refresh()
            await ending?.value
        }
    }

    /// Ends those of `ids` that are still in the background.
    func endAll(_ ids: [String]) {
        for id in ids { end(sessionID: id) }
    }

    /// Cherry › End Background Sessions…, Settings › Sessions and the
    /// panel's End All…: asks first, on `window` when it was asked from one
    /// the user sees (Settings, a project window), else on a project window
    /// (never the menu bar panel) or app-modal, then ends the sessions
    /// listed when it asked that are still in the background (one opened
    /// meanwhile is left alone). `ids`: only those of them (the launch
    /// notice's End…).
    func confirmEndAll(from window: NSWindow? = nil, limitedTo ids: [String]? = nil) {
        refresh()
        let listed = ids.map { ids in sessions.filter { ids.contains($0.id) } } ?? sessions
        guard !listed.isEmpty else { return }
        let alert = Self.makeEndAllAlert(
            running: listed.filter(\.isRunning).count,
            busy: listed.filter(\.isAtWork).count,
            ended: listed.filter { !$0.isRunning }.count
        )
        let ids = listed.map(\.id)
        presentAlert(alert, window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.endAll(ids)
        }
    }

    /// "End N background sessions?" for `running` sessions (`busy` of them
    /// running a program) and `ended` ones, which are only removed; "Remove
    /// N ended background sessions?" when none runs.
    static func makeEndAllAlert(running: Int, busy: Int, ended: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = running + ended
        let gone = count == 1
            ? "it does not come back when its project opens again."
            : "they do not come back when their projects open again."
        if running == 0 {
            alert.messageText = count == 1
                ? "Remove 1 ended background session?"
                : "Remove \(count) ended background sessions?"
            let discarded = count == 1
                ? "Its program already ended; its final screen is discarded, and "
                : "Their programs already ended; their final screens are discarded, and "
            alert.informativeText = discarded + gone
            alert.addButton(withTitle: "Remove Sessions").hasDestructiveAction = true
        } else {
            alert.messageText = count == 1 ? "End 1 background session?" : "End \(count) background sessions?"
            let stopping: String
            if count == 1 {
                stopping = "Its program stops now, and "
            } else if ended == 0 {
                stopping = (busy > 0 ? "\(busy) of them \(busy == 1 ? "is" : "are") running a program. " : "")
                    + "Their programs stop now, and "
            } else {
                stopping = "\(running) of them \(running == 1 ? "still runs and stops" : "still run and stop") now, "
                    + "the \(ended) that ended \(ended == 1 ? "is" : "are") removed, and "
            }
            alert.informativeText = stopping + gone
            alert.addButton(withTitle: "End Sessions").hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// A sheet on the window the confirmation was asked from, when the user
    /// sees it and it is no panel (Settings), else on the project window
    /// the quit confirmation would use
    /// (`CherryAppDelegate.visibleProjectWindowForQuitConfirmation`): never
    /// the menu bar panel, which closes as soon as it loses focus. With no
    /// project window open, an app-modal alert.
    static let presentOnProjectWindow: AlertPresenter = { alert, askedFrom, answer in
        if let window = endAllParent(askedFrom: askedFrom) ?? CherryAppDelegate.visibleProjectWindowForQuitConfirmation() {
            // ViewBridge loads lazily; the alert sheet may be NSRemoteView-backed.
            RemoteViewCrashGuard.installIfNeeded()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal())
        }
    }

    /// The window End All was asked from, when the confirmation can go on
    /// it: one the user sees that is no panel (the menu bar extra's window
    /// closes as soon as it loses focus).
    static func endAllParent(askedFrom window: NSWindow?) -> NSWindow? {
        guard let window, window.isVisible, !(window is NSPanel) else { return nil }
        return window
    }
}
