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
/// Sessions list shows it. Little here changes while its program runs on
/// by itself (an agent's spinner title is left out; only whether it is at
/// work, `isWorking`, and a shell's title at each command count), so the
/// list publishes only when a session comes, goes, ends, or changes what it
/// runs.
struct BackgroundSession: Equatable, Identifiable, Sendable {
    /// The host's session id.
    let id: String
    let hostID: String
    /// The command's or agent's name, or the session's.
    let title: String
    /// Its own name, as the Omni bar lists it
    /// (`SessionDisplayTitle.background`): an agent's task title, a shell's
    /// command, title or directory. A shell's follows the title its shell
    /// sets (at each command), an agent's does not follow its spinner.
    var displayTitle = ""
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
    /// Its holder died (`HostSessionEnd.holderLost`): `exitStatus` says
    /// nothing about its program.
    var hostCrashed = false
    /// Clients attached to it (a terminal outside Cherry).
    let clients: Int
    let createdAt: Date?
    /// The device it runs on (its name); nil for This Mac.
    var machine: String? = nil
    /// Its program says it is at work: its program status reports
    /// `working` (OSC 7501, set by `BackgroundSessionsModel.refresh`).
    /// Unlike `isAtWork`, never for an agent that merely runs.
    var isWorking = false

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
            displayTitle: SessionDisplayTitle.background(info, kind: kind, home: nil),
            kind: kind,
            agentKey: kind == .agent ? info.tags[PersistentSessionTag.agent]?.nilIfEmpty : nil,
            commandName: kind == .command ? info.tags[PersistentSessionTag.command]?.nilIfEmpty : nil,
            projectRoot: projectRoot,
            projectName: projectName(projectRoot: projectRoot),
            foregroundName: info.isBusy ? info.foreground?.name.nilIfEmpty : nil,
            isBusy: info.isBusy,
            exitStatus: info.isRunning ? nil : PersistentLocalSessions.exitStatus(of: info),
            hostCrashed: !info.isRunning && info.end?.isHolderLost == true,
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

    /// What a list of background sessions names it: its own name
    /// (`BackgroundSession.displayTitle`: an agent's task title, a shell's
    /// command or directory), as the Omni bar does; its title (a tool's
    /// name) only when it has none.
    static func rowTitle(of session: BackgroundSession) -> String {
        session.displayTitle.nilIfEmpty ?? session.title
    }

    /// The project shown beside a row's title, unless the title already
    /// says it ("cross-auth  cross-auth").
    static func detail(of session: BackgroundSession) -> String? {
        let project = session.projectName
        let title = rowTitle(of: session)
        return project.caseInsensitiveCompare(title) == .orderedSame ? nil : project.nilIfEmpty
    }

    static func projectName(projectRoot: String?) -> String {
        projectRoot.map(MenuBarAgentPresentation.projectName(projectRoot:)) ?? "No project"
    }

    /// "exit N" once ended, "attached" while a client shows it, what a busy
    /// terminal runs, "running" for a command or agent, else "idle".
    static func statusText(of session: BackgroundSession) -> String {
        if session.hostCrashed { return "host crashed" }
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
/// A device whose own sessions Background Sessions lists (phase 3): its
/// hosting (`RemoteDeviceStore`), with the name its section shows.
struct BackgroundDeviceHosting {
    let id: UUID
    let name: String
    let hosting: PersistentHostSessions
}

@MainActor
final class BackgroundSessionsModel: ObservableObject {
    static let shared = BackgroundSessionsModel(
        localSessions: .shared,
        registry: .shared,
        removeStaleResources: { GhosttyResourceStager.shared.removeStaleCopies(inUse: $0) },
        deviceHostings: { RemoteDeviceStore.shared.backgroundHostings() }
    )

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
    /// The device these sessions are on (a section of This Mac's model);
    /// nil for This Mac's own model.
    private(set) var device: (id: UUID, name: String)?
    /// Each device's own model, in the devices' order: the panel's sections
    /// (docs/specs/remote-devices.md, phase 3). Only This Mac's model has
    /// them.
    @Published private(set) var devices: [BackgroundSessionsModel] = []
    /// The devices whose sessions are listed (This Mac's model; nil for a
    /// device's).
    private let deviceHostings: (@MainActor () -> [BackgroundDeviceHosting])?
    private var deviceSubscriptions: [UUID: AnyCancellable] = [:]
    private weak var parent: BackgroundSessionsModel?
    /// A device's model shows what a look that starts nothing found
    /// (`peeks`) while the menu bar panel is open and its control is not
    /// connected.
    private(set) var isPanelOpen = false
    /// Looks at devices without starting or replacing their daemons.
    private let peeks: RemoteDevicePeeks
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
    /// Sessions in the list that had a bell or notification since they went
    /// to the background (the panel marks them; the tab that shows one next
    /// comes up unread, `PersistentLocalSessions.takeUnread`).
    @Published private(set) var unreadSessionIDs: Set<String> = []
    /// When each session's notification was last posted
    /// (`notificationInterval`), and when the latest ones of all sessions
    /// were (`notificationLimit` per minute).
    private var lastNotification: [String: Date] = [:]
    private var recentNotifications: [Date] = []
    /// The host whose saved unread marks were read into `unreadSessionIDs`.
    private var unreadLoadedForHost: String?
    /// How long the list has shown each ended session while the app was
    /// active and the Mac awake (`endedSessionGrace`), and when it last
    /// counted.
    private var endedShownFor: [String: TimeInterval] = [:]
    private var lastEndedCount: Date?
    /// Whether the app is active (in front): only then does an ended
    /// session's time in the list count.
    private let isAppActive: @MainActor () -> Bool
    /// A gap between two refreshes longer than this (the Mac slept, the app
    /// was suspended) does not count.
    static let endedCountMaximumGap: TimeInterval = 5
    private let postNotification: @MainActor (BackgroundSessionNotificationContent) -> Void
    /// Removes the staged Ghostty resources no session uses any more, given
    /// the copies running sessions name (`cherry.resources`;
    /// `GhosttyResourceStager.removeStaleCopies`): once per run, from the
    /// first complete live list. Nil (tests) removes nothing.
    private let removeStaleResources: (@MainActor (Set<String>) -> Void)?
    private var removedStaleResources = false
    private let now: @MainActor () -> Date
    /// An ended session in the list that no saved tab names is removed once
    /// the list has shown it this long while the app was active and awake
    /// (`removeExpiredEndedSessions`).
    let endedSessionGrace: TimeInterval
    /// A session's notifications (OSC 9, 777, 99) are posted at most this
    /// often; one within it only marks the session unread.
    static let notificationInterval: TimeInterval = 10
    /// At most this many background notifications a minute, of all
    /// sessions together.
    static let notificationLimit = 6
    static let defaultEndedSessionGrace: TimeInterval = 10 * 60

    /// The app uses `shared`; tests inject the local sessions, the windows,
    /// the attached tabs, the settings and the End All confirmation.
    init(
        localSessions: PersistentLocalSessions,
        registry: ProjectWindowRegistry,
        attachedTabs: OpenHostedTabs = .shared,
        prefersPersistentLocalSessions: @escaping @MainActor () -> Bool = { TerminalSettings.shared.persistLocalSessions },
        closesTabsOnCleanExit: @escaping @MainActor () -> Bool = { TerminalSettings.shared.closeTabsOnCleanExit },
        presentAlert: @escaping AlertPresenter = BackgroundSessionsModel.presentOnProjectWindow,
        postNotification: @escaping @MainActor (BackgroundSessionNotificationContent) -> Void = {
            TerminalNotificationCenter.shared.postBackgroundSession($0)
        },
        endedSessionGrace: TimeInterval = BackgroundSessionsModel.defaultEndedSessionGrace,
        now: @escaping @MainActor () -> Date = { Date() },
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false },
        removeStaleResources: (@MainActor (Set<String>) -> Void)? = nil,
        deviceHostings: (@MainActor () -> [BackgroundDeviceHosting])? = nil,
        device: (id: UUID, name: String)? = nil,
        peeks: RemoteDevicePeeks = .shared
    ) {
        self.peeks = peeks
        self.device = device
        self.deviceHostings = deviceHostings
        self.isAppActive = isAppActive
        self.removeStaleResources = removeStaleResources
        self.localSessions = localSessions
        self.registry = registry
        self.attachedTabs = attachedTabs
        self.prefersPersistentLocalSessions = prefersPersistentLocalSessions
        self.closesTabsOnCleanExit = closesTabsOnCleanExit
        self.presentAlert = presentAlert
        self.postNotification = postNotification
        self.endedSessionGrace = endedSessionGrace
        self.now = now
    }

    /// Whether these are a device's sessions (a section of This Mac's).
    var isDevice: Bool { device != nil }

    /// The device model whose host is `hostID`.
    private func device(ofHostID hostID: String) -> BackgroundSessionsModel? {
        devices.first { ($0.localSessions.control.hostID ?? $0.knownHostID) == hostID }
    }

    /// Every background session listed, This Mac's then each device's.
    var allSessions: [BackgroundSession] {
        sessions + devices.flatMap(\.sessions)
    }

    /// The model (This Mac's or a device's) that lists `id`.
    func model(listing id: String) -> BackgroundSessionsModel? {
        if sessions.contains(where: { $0.id == id }) { return self }
        return devices.first { $0.sessions.contains { $0.id == id } }
    }

    /// Starts following the host (the app: once launched, after the local
    /// host's warm-up, so the instance lock is known). Nothing connects.
    /// This Mac's model refreshes the devices' too.
    func start() {
        guard timer == nil else { return }
        if isDevice {
            startFollowingHost()
            refresh()
            return
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        startFollowingHost()
        refresh()
    }

    /// The host's signals and list events.
    private func startFollowingHost() {
        // Bells and notifications of sessions no tab follows.
        localSessions.backgroundSignalHandler = { [weak self] info, signal in
            self?.backgroundSessionDidSignal(info, signal) ?? false
        }
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
        if isDevice {
            // A device's list follows its connection (it lists only while
            // connected): refreshed as that changes.
            connectionSubscription = localSessions.control.$state
                .removeDuplicates()
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
        }
    }

    private var connectionSubscription: AnyCancellable?

    /// Stops following the host and lets the connection go (tests).
    func stop() {
        timer?.invalidate()
        timer = nil
        eventSubscription = nil
        connectionSubscription = nil
        localSessions.backgroundSignalHandler = nil
        sessions = []
        summary.update([])
        lease?.release()
        lease = nil
        for device in devices { device.stop() }
        devices = []
        deviceSubscriptions.removeAll()
    }

    /// Follows the devices `deviceHostings` names now: a model for each
    /// new one (started), none for one removed (stopped).
    private func syncDevices() {
        guard let deviceHostings else { return }
        let current = deviceHostings()
        var models: [BackgroundSessionsModel] = []
        for entry in current {
            if let existing = devices.first(where: { $0.device?.id == entry.id && $0.localSessions === entry.hosting }) {
                if existing.device?.name != entry.name { existing.device = (entry.id, entry.name) }
                models.append(existing)
                continue
            }
            let model = BackgroundSessionsModel(
                localSessions: entry.hosting,
                registry: registry,
                attachedTabs: attachedTabs,
                prefersPersistentLocalSessions: { false },
                closesTabsOnCleanExit: closesTabsOnCleanExit,
                presentAlert: presentAlert,
                postNotification: postNotification,
                endedSessionGrace: endedSessionGrace,
                now: now,
                isAppActive: isAppActive,
                device: (entry.id, entry.name),
                peeks: peeks
            )
            model.parent = self
            model.start()
            deviceSubscriptions[entry.id] = model.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            models.append(model)
        }
        for removed in devices where !models.contains(where: { $0 === removed }) {
            removed.stop()
            if let id = removed.device?.id, !models.contains(where: { $0.device?.id == id }) {
                deviceSubscriptions.removeValue(forKey: id)
            }
        }
        if models.map(ObjectIdentifier.init) != devices.map(ObjectIdentifier.init) { devices = models }
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
        var listed: [BackgroundSession]
        var infos: [HostedSessionInfo] = []
        // Whether `listed` is what the host has now (unread marks of
        // sessions it no longer has go only then).
        var isLive = true
        if isDevice, control.state != .connected {
            // A device is listed while its control is connected, or while
            // the panel is open from a look that started nothing there.
            if isPanelOpen, let peeked = peeks.list(for: localSessions.profile.host) {
                knownHostID = peeked.hostID
                infos = peeked.sessions
                listed = backgroundSessions(in: infos, hostID: peeked.hostID)
            } else {
                listed = []
                isLive = false
            }
        } else {
            infos = control.sessions
            listed = knownHostID.map { backgroundSessions(in: infos, hostID: $0) } ?? []
        }
        listed = markingWorkingAgents(listed, from: infos)
        listed = removeCleanlyEndedTerminals(listed)
        listed = removeExpiredEndedSessions(listed)
        removeStaleResourcesOnce()
        if listed != sessions { sessions = listed }
        loadSavedUnreadMarks()
        // Kept while a device is not listed (a disconnect), so they are
        // there again when it is.
        if isLive {
            let unread = unreadSessionIDs.filter { id in listed.contains { $0.id == id } }
            if unread != unreadSessionIDs { unreadSessionIDs = unread }
        }
        if !isDevice {
            syncDevices()
            for device in devices { device.refresh() }
        }
        updateSummary()
        updateLease()
    }

    /// Sets `isWorking` of the running sessions of `listed` from their
    /// programs' status in `infos` (OSC 7501: the root record says
    /// `working`).
    private func markingWorkingAgents(_ listed: [BackgroundSession], from infos: [HostedSessionInfo]) -> [BackgroundSession] {
        let working = Set(infos.filter { $0.programStatus.root?.state == .working }.map(\.id))
        return listed.map { session in
            guard session.isRunning else { return session }
            var session = session
            session.isWorking = working.contains(session.id)
            return session
        }
    }

    /// The counts the app shows: This Mac's and every device's.
    private func updateSummary() {
        if let parent {
            summary.update(sessions)
            parent.summary.update(parent.allSessions)
        } else {
            summary.update(allSessions)
        }
    }

    /// Once per run, from a live list that expects no more holders (a host
    /// that cannot be reached removes nothing): the staged resources no
    /// running session names are removed, whoever owns the session. While
    /// a running session of this app names no copy (it predates the tag),
    /// nothing is removed: which copy it reads cannot be told.
    private func removeStaleResourcesOnce() {
        let control = localSessions.control
        guard !removedStaleResources, let removeStaleResources,
              localSessions.instanceUnavailableReason == nil,
              control.state == .connected, control.hostID != nil, !control.expectsHolders
        else { return }
        removedStaleResources = true
        let running = control.sessions.filter(\.isRunning)
        guard !running.contains(where: { $0.owner == localSessions.owner && $0.tags[PersistentSessionTag.resources] == nil })
        else { return }
        removeStaleResources(Set(running.compactMap { $0.tags[PersistentSessionTag.resources]?.nilIfEmpty }))
    }

    /// Removes the ended sessions of `listed` the list has shown for
    /// `endedSessionGrace`, counting only while the app is active and the
    /// Mac awake (refreshes more than `endedCountMaximumGap` apart do not
    /// count), that no state file names (`WorkspaceStateStore.savedTabsName`,
    /// set-aside files included: a closed window's tab keeps its session,
    /// whose restore shows how it ended). Never one marked unread (its bell
    /// or notification was not seen) or one whose host crashed (the crash is
    /// worth seeing). Only from a live list, and only with the app's store
    /// to check (`endedSessionsStore`). The removal is recorded as an end on
    /// purpose, like End's. Returns the others.
    private func removeExpiredEndedSessions(_ listed: [BackgroundSession]) -> [BackgroundSession] {
        let now = now()
        let ended = Set(listed.filter { !$0.isRunning }.map(\.id))
        endedShownFor = endedShownFor.filter { ended.contains($0.key) }
        let elapsed = lastEndedCount.map { now.timeIntervalSince($0) } ?? 0
        lastEndedCount = now
        let counts = elapsed > 0 && elapsed <= Self.endedCountMaximumGap && isAppActive()
        for id in ended {
            endedShownFor[id, default: 0] += counts ? elapsed : 0
        }
        let control = localSessions.control
        guard !ended.isEmpty, control.state == .connected, let hostID = control.hostID,
              let store = localSessions.endedSessionsStore
        else { return listed }
        var removed = Set<String>()
        for item in listed where ended.contains(item.id) && !item.hostCrashed && !unreadSessionIDs.contains(item.id) {
            let id = item.id
            guard let shown = endedShownFor[id], shown >= endedSessionGrace else { continue }
            guard let info = control.sessions.first(where: { $0.id == id }), !info.isRunning,
                  let attachment = localSessions.attachment(for: info), attachment.hostID == hostID
            else { continue }
            if store.savedTabsName(info, hostID: hostID, owner: localSessions.owner) {
                // Checked again after another grace period.
                endedShownFor[id] = 0
                continue
            }
            localSessions.end(attachment)
            removed.insert(id)
        }
        return listed.filter { !removed.contains($0.id) }
    }

    /// The unread marks saved for this host's sessions (a bell or
    /// notification while they were in the background, in an earlier run
    /// too: `WorkspaceStateStore.unreadSessions`), read once per host.
    private func loadSavedUnreadMarks() {
        guard let hostID = knownHostID, unreadLoadedForHost != hostID,
              let store = localSessions.endedSessionsStore
        else { return }
        unreadLoadedForHost = hostID
        let saved = store.unreadSessions(hostID: hostID).filter { id in sessions.contains { $0.id == id } }
        if !saved.isSubset(of: unreadSessionIDs) { unreadSessionIDs.formUnion(saved) }
    }

    /// A bell or notification of `info`'s session, which no tab follows
    /// (`PersistentLocalSessions.backgroundSignalHandler`): when it is in
    /// the background, it is marked unread and posted as the app's
    /// notification, naming the session and its project; clicking it opens
    /// the session (`open(sessionID:)`). A bell is posted once until the
    /// session is opened (a session marked unread already posts none); a
    /// notification at most every `notificationInterval` per session; and
    /// at most `notificationLimit` a minute of all sessions together. The
    /// others only mark the session unread. False when it is not in the
    /// background (a tab may still follow it).
    func backgroundSessionDidSignal(_ info: HostedSessionInfo, _ signal: PersistentHostSignal) -> Bool {
        let control = localSessions.control
        guard let hostID = control.hostID ?? knownHostID,
              let item = backgroundSessions(in: [info], hostID: hostID).first
        else { return false }
        if case .progress = signal { return true }
        let wasUnread = unreadSessionIDs.contains(info.id)
        localSessions.noteUnread(hostID: hostID, sessionID: info.id)
        unreadSessionIDs.insert(info.id)
        let now = now()
        switch signal {
        case .bell:
            guard !wasUnread else { return true }
        case .notification:
            if let last = lastNotification[info.id], now.timeIntervalSince(last) < Self.notificationInterval {
                return true
            }
        case .progress:
            return true
        }
        recentNotifications.removeAll { now.timeIntervalSince($0) >= 60 }
        guard recentNotifications.count < Self.notificationLimit else { return true }
        recentNotifications.append(now)
        lastNotification[info.id] = now
        postNotification(BackgroundSessionNotificationContent(session: item, signal: signal, machine: device?.name))
        return true
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
        let machine = device?.name
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
        .map { session in
            var session = session
            session.machine = machine
            return session
        }
    }

    /// How the Persistent Sessions sheet marks a session of This Mac: this
    /// app's own ones only.
    func ownershipLabel(for info: HostedSessionInfo, hostID: String) -> String? {
        if let device = device(ofHostID: hostID) {
            return device.ownershipLabel(for: info, hostID: hostID)
        }
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
        if let device = device(ofHostID: hostID) {
            return device.isEnding(info, hostID: hostID)
        }
        return info.owner == localSessions.owner
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
        for device in devices { device.devicePanelDidAppear() }
        let control = localSessions.control
        guard control.state != .connected, mayConnect else { return }
        Task { @MainActor [weak self] in
            _ = try? await control.list()
            self?.refresh()
        }
    }

    /// The panel opened: a device whose control is not connected is looked
    /// at once with `peeks` (never starting or replacing its daemon;
    /// throttled, and never after a refused login until a wake, a network
    /// change or Reconnect); what it found shows while the panel is open.
    /// Nothing connects its control.
    private func devicePanelDidAppear() {
        isPanelOpen = true
        let control = localSessions.control
        guard isDevice, control.state != .connected, control.state != .connecting,
              localSessions.instanceUnavailableReason == nil,
              RemoteDevicePeeks.refreshesOnOpen(control.state)
        else { return }
        let peeks = peeks
        Task { @MainActor [weak self] in
            await peeks.refresh(control)
            self?.refresh()
            self?.parent?.refresh()
        }
    }

    /// The panel closed: devices not connected are no longer shown.
    func panelDidDisappear() {
        for device in devices { device.isPanelOpen = false }
        refresh()
    }

    /// The host's sessions as this list shows them: over the connection,
    /// or (a device's, while the panel is open) from a look.
    private var currentSessions: [HostedSessionInfo] {
        let control = localSessions.control
        if isDevice, control.state != .connected, isPanelOpen,
           let peeked = peeks.list(for: localSessions.profile.host) {
            return peeked.sessions
        }
        return control.sessions
    }

    /// Whether the list may connect to the local host (which starts one
    /// when none runs): only in the copy that owns this Mac's sessions, and
    /// only once this run reached the host, when local tabs run in it, or
    /// while it lists sessions. A device's list never connects by itself.
    private var mayConnect: Bool {
        !isDevice && localSessions.instanceUnavailableReason == nil
            && (localSessions.connectionGeneration > 0 || prefersPersistentLocalSessions() || !sessions.isEmpty)
    }

    private func updateLease() {
        // A device's list never keeps its connection up.
        let needed = !sessions.isEmpty && !isDevice
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
        guard let info = currentSessions.first(where: { $0.id == item.id }) else { return nil }
        let registry = registry
        let localSessions = localSessions
        let attachedTabs = attachedTabs
        return Task { @MainActor [weak self] in
            await registry.showBackgroundSession(info, localSessions: localSessions, attachedTabs: attachedTabs)
            self?.refresh()
        }
    }

    /// A background session's notification was clicked: shows the session
    /// as Open does, listing the host first when the connection does not
    /// know it (the notification may predate this run). Nothing for a
    /// session that is gone or not this app's.
    /// A notification of the session `sessionID` of host `hostID` was
    /// clicked: This Mac's or a device's model shows it.
    @discardableResult
    func open(sessionID: String, hostID: String?) -> Task<Void, Never> {
        if let hostID, let device = device(ofHostID: hostID) {
            return device.open(sessionID: sessionID)
        }
        if let device = devices.first(where: { $0.sessions.contains { $0.id == sessionID } }) {
            return device.open(sessionID: sessionID)
        }
        return open(sessionID: sessionID)
    }

    @discardableResult
    func open(sessionID: String) -> Task<Void, Never> {
        let registry = registry
        let localSessions = localSessions
        let attachedTabs = attachedTabs
        let mayConnect = mayConnect
        return Task { @MainActor [weak self] in
            var info = localSessions.sessionInfo(sessionID)
            if info == nil, mayConnect {
                info = try? await localSessions.control.list().sessions.first { $0.id == sessionID }
            }
            guard let info, info.owner == localSessions.owner else { return }
            await registry.showBackgroundSession(info, localSessions: localSessions, attachedTabs: attachedTabs)
            self?.refresh()
        }
    }

    @discardableResult
    func end(_ item: BackgroundSession) -> Task<Void, Never>? {
        end(sessionID: item.id)
    }

    /// Background Sessions › Clear Ended: removes every ended session in the
    /// list at once (nothing runs in them, so nothing is asked). Recorded as
    /// ended on purpose, like End: a closed window's saved tab that names
    /// one is dropped at its restore, never brought back as ended by the
    /// system.
    func clearEnded() {
        refresh()
        endAll(allSessions.filter { !$0.isRunning }.map(\.id))
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
              let info = currentSessions.first(where: { $0.id == sessionID }),
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

    /// Ends those of `ids` that are still in the background, on This Mac
    /// or a device.
    func endAll(_ ids: [String]) {
        for id in ids { (model(listing: id) ?? self).end(sessionID: id) }
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
        let all = allSessions
        let listed = ids.map { ids in all.filter { ids.contains($0.id) } } ?? all
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

/// Settings › Projects › Remove Project: a project removed from the library
/// whose sessions run in the background (no open tab shows them) offers to
/// end them first, since no window of it opens again by itself to show
/// them. "Keep Running" removes the project and leaves them in Background
/// Sessions.
@MainActor
enum ProjectRemoval {
    /// Shows the question and reports which button answered it.
    typealias AlertPresenter = @MainActor (
        NSAlert,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void

    /// The background sessions of the project at `root`: those whose
    /// project (`cherry.project`, a worktree) belongs to it rather than to
    /// another of `projectRoots` (the registered projects, `root` among
    /// them): a worktree the settings know goes to its repository
    /// (`repositoryRoot`, asked before the project is removed), else the
    /// longest registered root that contains it wins, so a project nested
    /// inside another keeps its own sessions.
    static func backgroundSessions(
        ofProject root: String,
        in sessions: [BackgroundSession],
        projectRoots: [String],
        repositoryRoot: (String) -> String?
    ) -> [BackgroundSession] {
        let registered = Set(projectRoots + [root])
        return sessions.filter { session in
            guard let projectRoot = session.projectRoot else { return false }
            return owningProject(of: projectRoot, among: registered, repositoryRoot: repositoryRoot) == root
        }
    }

    /// The registered project a worktree belongs to.
    static func owningProject(
        of projectRoot: String,
        among registered: Set<String>,
        repositoryRoot: (String) -> String?
    ) -> String? {
        if let repository = repositoryRoot(projectRoot), registered.contains(repository) { return repository }
        return registered
            .filter { projectRoot == $0 || projectRoot.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    /// Removes `project` from `settings`, first asking whether to end its
    /// background sessions when it has any: End Sessions ends them, Keep
    /// Running keeps them, Cancel removes nothing.
    static func remove(
        _ project: CherryProject,
        settings: AgentSettings,
        background: BackgroundSessionsModel = .shared,
        present: AlertPresenter = ProjectRemoval.presentOnKeyWindow
    ) {
        background.refresh()
        let listed = backgroundSessions(
            ofProject: project.root, in: background.sessions, projectRoots: settings.projects.map(\.root)
        ) { settings.repositoryRoot(for: $0) }
        guard !listed.isEmpty else {
            settings.removeProject(project)
            return
        }
        let ids = listed.map(\.id)
        let alert = makeAlert(
            projectName: project.name,
            running: listed.filter(\.isRunning).count,
            ended: listed.filter { !$0.isRunning }.count
        )
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn:
                settings.removeProject(project)
                background.endAll(ids)
            case .alertSecondButtonReturn:
                settings.removeProject(project)
            default:
                break
            }
        }
    }

    /// "End the N background sessions of <project>?" with End Sessions,
    /// Keep Running and Cancel.
    static func makeAlert(projectName: String, running: Int, ended: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = running + ended
        alert.messageText = count == 1
            ? "End the background session of “\(projectName)”?"
            : "End the \(count) background sessions of “\(projectName)”?"
        let state: String
        if running == 0 {
            state = count == 1 ? "Its program already ended." : "Their programs already ended."
        } else if ended == 0 {
            state = count == 1 ? "Its program is still running." : "Their programs are still running."
        } else {
            state = "\(running) of them \(running == 1 ? "is" : "are") still running."
        }
        alert.informativeText = state
            + " Removing the project does not stop them; Keep Running leaves them in Background Sessions."
        alert.addButton(withTitle: "End Sessions").hasDestructiveAction = true
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// A sheet on the Settings window it was asked from, else app-modal.
    static let presentOnKeyWindow: AlertPresenter = { alert, answer in
        if let window = BackgroundSessionsModel.endAllParent(askedFrom: NSApp.keyWindow) {
            RemoteViewCrashGuard.installIfNeeded()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response) }
            }
        } else {
            answer(alert.runModal())
        }
    }
}
