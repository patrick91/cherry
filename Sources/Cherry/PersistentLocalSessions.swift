import CherryControl
import Combine
import Foundation

/// What a local tab asks the host to start for its program.
struct PersistentSessionRequest: Equatable, Sendable {
    var tabID: UUID
    var name: String
    var kind: TerminalSession.SessionKind
    var agentName: String?
    var commandName: String?
    var projectRoot: String?
    var columns: Int
    var rows: Int
    /// The Create's `request_id`, chosen by the tab before it asks (and
    /// saved with it), so a relaunch can find the session a Create whose
    /// answer was lost started (`HostedSessionInfo.requestID`).
    var requestID = UUID()
}

/// A session the local host runs for a tab, and how the tab's attach
/// adapter reaches it.
struct PersistentSessionLaunch: Equatable, Sendable {
    /// `cherry attach` for the session: the helper and login environment of
    /// the control connection that created or listed it.
    let attachment: HostedSessionAttachment
    /// The session as the host described it then.
    let info: HostedSessionInfo
}

/// Where a tab's program stands, as the local host last reported it.
enum PersistentProgramState: Equatable {
    case running(HostedSessionInfo)
    /// The program ended with this status (128 + N after signal N).
    case exited(Int32)
    /// The host has no such session any more, or another host answers now.
    case gone
    /// Not known: the control connection is not up.
    case unknown
}

/// What a program reported through its host that a tab shows as it shows
/// the same report from its own surface: a bell, a desktop notification
/// (OSC 9, 777 or 99) or progress (OSC 9;4).
enum PersistentHostSignal: Equatable, Sendable {
    case bell
    /// `title` is empty when the program gave none.
    case notification(title: String, body: String)
    /// `value` is a percentage, nil when the program gave none.
    case progress(HostProgressState, value: Int?)
}

/// The latest progress a program reported (OSC 9;4), as its host saw it.
struct TerminalProgressReport: Equatable, Sendable {
    let state: HostProgressState
    /// 0...100, nil when the program gave none.
    let value: Int?
}

/// Whether input queued for a persistent tab (MCP's, while its session is
/// being created) reached the program: resolved once, when the host took
/// it, the native shell the tab fell back to got it, or it was dropped.
@MainActor
final class PersistentInputDelivery {
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var isResolved: Bool { result != nil }

    /// Only the first result counts.
    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    /// Returns once resolved; throws its error.
    func value() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
        }
    }
}

/// The host session tags Cherry sets on the sessions its tabs run in, so a
/// lost state file can still be reconciled and the Persistent Sessions sheet
/// can tell them apart. Keys stay within the host's limits.
enum PersistentSessionTag {
    static let tab = "cherry.tab"
    static let kind = "cherry.kind"
    static let agent = "cherry.agent"
    static let command = "cherry.command"
    static let project = "cherry.project"
    /// The Create request (lowercased UUID) that started the session: finds
    /// a session whose Create answer was lost, and nothing else.
    static let launch = "cherry.launch"
    /// The staged Ghostty resources copy the session reads
    /// (`HostedLaunchSpec.resourcesCopy`), kept while any session names it.
    static let resources = "cherry.resources"
    /// Each value is cut to this many bytes, far inside the host's 16 KiB.
    static let maxValueBytes = 1_024
}

/// Runs Cherry's local terminal, command and agent tabs as persistent
/// sessions in the local cherry-host (docs/specs/multiplexer-default.md):
/// creates their sessions through the local host's `HostControl`, follows
/// their programs (exit, pid, busy, title, directory, bells, notifications,
/// progress) through its events, ends them for close intents that
/// terminate, and decides when new tabs fall back to the native backend.
/// Each tab's screen still comes through its attach adapter (`cherry attach
/// … --detach-key none --status-file`) as the Ghostty EXEC command; while
/// no adapter is attached, input goes through `SendInput` and the screen is
/// read with `Screen`.
///
/// Nothing here blocks the main actor: the helper, the daemon and the login
/// environment are reached through `HostControl`'s helper process.
@MainActor
final class PersistentLocalSessions {
    /// Builds a tab's Create argv, environment and working directory from
    /// its launch configuration and the captured login environment.
    typealias LaunchSpecBuilder = @MainActor (
        _ configuration: ShellProcessController.Configuration,
        _ loginEnvironment: [String: String]?
    ) async -> HostedLaunchSpec

    struct Configuration: Sendable {
        /// Ending a session: Kill, then Remove once the host reports its
        /// exit. A program still running after this is left to the host's
        /// own kill escalation (and stays listed until removed).
        var terminationTimeout: Duration = .seconds(10)
        /// A restart waits this long for the previous program to exit before
        /// it creates the new session, so a server it ran has released its
        /// port.
        var restartExitTimeout: Duration = .seconds(5)
        /// After the host failed to start a tab's session, new tabs run
        /// natively this long before it is tried again.
        var unavailableRetryInterval: TimeInterval = 30
        /// How long the installation check (disk image, helper) is reused.
        var installationCheckInterval: TimeInterval = 10
        /// Backoff between attach adapter launches while a tab reconnects.
        var reconnectDelay: (initial: TimeInterval, maximum: TimeInterval) = (0.25, 8)
        /// Failed reconnects in a row before the tab shows it is disconnected
        /// (it keeps trying at the maximum delay).
        /// An adapter that reports itself attached (its status file) resets
        /// the count; how long one runs does not.
        var reconnectAttemptsBeforeDisconnected = 5
        /// A tab whose session the host has not started after this long
        /// (the helper, the daemon or the login environment hangs) runs its
        /// program natively; a session created later is ended. Once for
        /// each Create of this app still waiting ahead of it
        /// (`creationDeadline`). Longer than
        /// the host's own wait for a new holder (`LAUNCH_TIMEOUT` in
        /// cherry-host, 10 s), so a holder that fails to start is reported
        /// by the host's rejection, with its reason, before this runs out.
        var creationTimeout: TimeInterval = 14
        /// Create is sent again (same request ID and spec) this many times
        /// after its answer was lost, beyond `HostControl.create`'s own retry.
        var lostCreateRetries = 2
        /// When the answer to Create never came, the host is listed after
        /// each of these delays to end a session it may have made anyway.
        var lostCreateChecks: [Duration] = [.seconds(2), .seconds(12), .seconds(30)]
        /// A running session missing from the list of a host that does not
        /// report pending holders (an older host) is listed again after
        /// this long before its tab takes it as gone: a restarted daemon
        /// lists a session only once its holder registered again. A restore
        /// looks for a saved tab's missing session again after it too,
        /// before it drops the tab.
        var disappearanceConfirmationDelay: Duration = .seconds(2)
        /// A host that reports holders it still expects after a restart is
        /// listed again this often until it expects none, for at most
        /// `pendingHoldersWait`, before a session missing from its list is
        /// taken as gone (a restore then keeps the saved tab instead).
        var pendingHoldersPollInterval: Duration = .milliseconds(250)
        var pendingHoldersWait: Duration = .seconds(10)
        /// When a restore's list failed on a connection that stayed up, the
        /// kept tabs are restored again after this long
        /// (`hostAvailability(after:)`).
        var restoreRetryDelay: TimeInterval = 10
        /// An attach adapter that has reported itself reconnecting (its
        /// host restarted) for this long shows the tab's reconnect bar.
        var adapterReconnectingNoticeDelay: TimeInterval = 2
        /// Bells and notifications for a session no tab follows yet (its
        /// Create answer or its tab's restore is still to come) are kept
        /// this long, at most `pendingSignalLimit` of them, for the tab that
        /// then follows it. The host keeps those it had while no app was
        /// connected about as long.
        var pendingSignalLifetime: TimeInterval = 30
        var pendingSignalLimit = 64
        /// A tab's screen read from its host is reused for this long.
        var hostScreenReuseInterval: TimeInterval = 0.25
        /// Loops that watch a tab's screen (MCP idle waits, agent input
        /// readiness, render signals) read it from the host at most this
        /// often, and only its last `hostScreenRecentLines` lines.
        var hostScreenPollInterval: TimeInterval = 1
        /// How much of a tab's screen (its last lines, history included)
        /// those loops read from the host: more than a screen holds, and
        /// as much as agent activity detection looks at.
        var hostScreenRecentLines = 600
        /// MCP input sent while a tab's session is created waits this long
        /// at most to reach the program (the end of a previous session,
        /// then `creationTimeout`, after which the tab runs natively and
        /// takes it); then it is dropped and reported undelivered.
        var queuedInputTimeout: TimeInterval = 22
        /// How long a read of a tab's lines waits for the host's screen; the
        /// tab's last lines are used meanwhile.
        var hostScreenWait: Duration = .seconds(2)
        /// Ending a session: a Kill (or Remove) that got no definite answer
        /// (the host could not be reached, or did not answer, say while it
        /// restarts) is sent again after these delays, doubling, until this
        /// window has passed. Only the host's word that the session is gone
        /// (or another host answering) stops it sooner.
        var endRetryDelay: (initial: Duration, maximum: Duration) = (.milliseconds(250), .seconds(4))
        var endRetryWindow: Duration = .seconds(60)
        /// Sessions of saved tabs that will never come back (their worktree
        /// was removed) are looked for this long while the host cannot be
        /// listed (or still lists them). Those still running then are left
        /// to the next launch, which looks for them again when the tabs
        /// were recorded in a store (`SessionsToEndRecord`); the Persistent
        /// Sessions sheet shows them meanwhile.
        var forgottenTabsWindow: Duration = .seconds(300)
    }

    static let shared = PersistentLocalSessions(instanceLock: .shared)

    /// The host keeps a session name to this many bytes (Update's limit).
    static let maxSessionNameBytes = 256

    /// Who creates the sessions: this app variant (Cherry, Cherry Sessions,
    /// CherryDev), which also names its saved workspace state. Restore
    /// adopts only sessions its own state names.
    nonisolated static var appOwner: String { CherryAppIdentity.current.applicationSupportName }

    let owner: String
    let configuration: Configuration
    /// Where the sessions this app ends on purpose are recorded
    /// (`WorkspaceStateStore.addEndedSessions`), so a saved tab that names
    /// one never comes back as ended by the system; also where sessions in
    /// the background that had a bell or notification are marked unread
    /// (`noteUnread`), and what Background Sessions checks before it removes
    /// an ended session (`WorkspaceStateStore.savedTabsName`). The app sets
    /// its store at launch; nil records nothing (tests).
    var endedSessionsStore: WorkspaceStateStore?
    /// Lost sessions recorded in `endedSessionsStore` during this run (host
    /// identity + NUL + session id).
    private var recordedLostSessions: Set<String> = []
    private let makeControl: @MainActor () -> HostControl
    private var controlStorage: HostControl?
    private let installationUnavailableReason: @MainActor () -> String?
    /// The app's: only the copy of the app that holds it creates, adopts,
    /// restores or ends sessions (`AppInstanceLock`).
    private let instanceLock: AppInstanceLock?
    private let launchSpec: LaunchSpecBuilder
    private let status: PersistentSessionsStatus

    private var installationCheck: (reason: String?, checkedAt: Date)?
    private var launchFailure: (reason: String, retryAt: Date)?

    private final class WeakTab {
        weak var session: TerminalSession?
        init(_ session: TerminalSession) { self.session = session }
    }

    /// A session whose tab a user closed (⌘W) while that close can still be
    /// undone (`deferEnd`), and how it ends once it cannot.
    private struct DeferredEnd {
        /// The tab as saved, recorded as a session to end (`SessionsToEndRecord`).
        let record: WorkspaceSessionRecord
        let store: WorkspaceStateStore?
        /// The tab's usual end (`SessionBackendPolicy.terminateHostedSession`).
        let end: @MainActor () -> Void
    }

    /// Tabs by the host session their program runs in, while it runs: they
    /// follow its events.
    private var boundTabs: [String: WeakTab] = [:]
    /// Every open tab built to run as a persistent session (even one that
    /// then fell back to the native backend), until it closes. The owner of
    /// a session is the open one that names it (`owningTab(of:)`).
    private var openTabs: [ObjectIdentifier: WeakTab] = [:]
    private var creatingCount = 0

    /// How long a tab waits for the session it is about to create
    /// (`creationTimeout`) when this app already waits for `creatingCount`
    /// others: the daemon starts one holder at a time, so each Create
    /// ahead may take its own `creationTimeout` first.
    var creationDeadline: TimeInterval {
        configuration.creationTimeout * Double(creatingCount + 1)
    }
    /// Sessions being ended, by session id.
    private var endings: [String: Task<Void, Never>] = [:]
    /// Sessions whose end waits for their tab's close to be undone or not
    /// (`deferEnd`), by session id.
    private var deferredEnds: [String: DeferredEnd] = [:]
    /// Searches for the sessions of forgotten saved tabs under way
    /// (`endSessions(ofForgottenTabs:)`): they keep the connection up.
    private var forgottenTabSearches = 0
    /// The saved tabs each of those searches ends the sessions of, until it
    /// ends (`isScheduledToEnd`).
    private var forgottenTabTargets: [UUID: [WorkspaceSessionRecord]] = [:]
    /// Stores whose sessions to end an earlier run left were taken up in
    /// this run (`resumeEndingSessions(recordedIn:)`).
    private var resumedSessionsToEnd: Set<ObjectIdentifier> = []
    /// Input sent through the control connection, one chain per session so
    /// it arrives in order.
    private var inputChains: [String: (task: Task<Void, Error>, generation: Int)] = [:]
    /// Bells and notifications for sessions no tab follows yet, oldest
    /// first (`Configuration.pendingSignalLifetime`).
    private var pendingSignals: [(sessionID: String, signal: PersistentHostSignal, receivedAt: Date)] = []
    /// Whether a check for pending signals no tab took is scheduled.
    private var pendingSignalExpiryScheduled = false
    /// Takes a bell or notification of a session of this app that no tab
    /// follows, and says whether it did: a session in the background has
    /// it posted as the app's notification and marked unread
    /// (`BackgroundSessionsModel.backgroundSessionDidSignal`). One it does
    /// not take is kept for a tab that follows the session soon (its Create
    /// answer or its window's restore is still to come) and offered again
    /// once that wait is over (`pendingSignalLifetime`). Nil drops them then.
    var backgroundSignalHandler: (@MainActor (HostedSessionInfo, PersistentHostSignal) -> Bool)?
    private var lease: HostControlLease?
    private var eventSubscription: AnyCancellable?
    /// What a new session's terminal reports of its colours and appearance
    /// (`HostCreateRequest.colors`).
    private let terminalColors: @MainActor () -> HostTerminalColors?

    /// The app's terminal theme for the appearance it shows now, as a tab's
    /// surface draws it.
    static func appTerminalColors() -> HostTerminalColors? {
        TerminalSettings.shared.hostTerminalColors(for: GhosttySessionBridge.resolvedColorScheme())
    }

    init(
        owner: String = PersistentLocalSessions.appOwner,
        control: @escaping @MainActor () -> HostControl = { HostControlRegistry.shared.control(for: .local) },
        installationUnavailableReason: @escaping @MainActor () -> String? = PersistentLocalSessions.localInstallationUnavailableReason,
        launchSpec: @escaping LaunchSpecBuilder = PersistentLocalSessions.preparedLaunchSpec,
        status: PersistentSessionsStatus = .shared,
        instanceLock: AppInstanceLock? = nil,
        terminalColors: @escaping @MainActor () -> HostTerminalColors? = PersistentLocalSessions.appTerminalColors,
        configuration: Configuration = Configuration()
    ) {
        self.owner = owner
        self.terminalColors = terminalColors
        makeControl = control
        self.installationUnavailableReason = installationUnavailableReason
        self.launchSpec = launchSpec
        self.status = status
        self.instanceLock = instanceLock
        self.configuration = configuration
    }

    /// Why this copy of the app must leave this Mac's sessions alone:
    /// another copy with the same identity runs (`AppInstanceLock`).
    var instanceUnavailableReason: String? {
        instanceLock?.unavailableReason
    }

    /// The local host's control plane (created on first use). Its events are
    /// followed from then on: the bells and notifications a host kept while
    /// no app was connected come right after the first connection (a
    /// restore's list) subscribes, before any tab follows its session.
    var control: HostControl {
        if let controlStorage { return controlStorage }
        let control = makeControl()
        controlStorage = control
        observeEvents()
        return control
    }

    // MARK: Availability

    /// This app cannot run local sessions: a disk image or App Translocation
    /// copy, or no `cherry` helper. Cheap (file checks only).
    static func localInstallationUnavailableReason() -> String? {
        if let reason = HostedSessionInstallation.localHostUnavailableReason() { return reason }
        do {
            _ = try HostedSessionClient.installed()
            return nil
        } catch {
            return (error as? HostedSessionError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Runs this app's own launch spec preparation (staged Ghostty resources,
    /// the zsh bootstrap, the account) off the main actor.
    static let preparedLaunchSpec: LaunchSpecBuilder = { configuration, loginEnvironment in
        await HostedLaunchSpec.prepare(
            for: configuration,
            loginEnvironment: loginEnvironment,
            cursorBlink: TerminalSettings.shared.cursorBlink
        )
    }

    /// Connects to the local host in the background (starting the helper,
    /// capturing the login environment and starting the daemon when needed),
    /// so the first tab's session does not wait for all of that. Nothing is
    /// held: an unused connection closes by itself.
    func warmUp() {
        guard canHostNewTabs() else { return }
        let control = control
        Task { @MainActor in
            _ = try? await control.connect()
        }
    }

    /// How many times the control connection to the local host has come up
    /// so far; `hostAvailability(after:)` compares against it.
    var connectionGeneration: Int { control.connectionCount }

    /// Fires once when the local host can probably be listed again after a
    /// list failed that started at `generation` (`connectionGeneration`
    /// then): saved tabs a restore kept because the host could not be
    /// reached can come back.
    ///
    /// - A connection that came up since then (a new tab, the Persistent
    ///   Sessions sheet or a warm-up reached the host): at once, even when
    ///   it came up before anyone subscribed.
    /// - The connection that was up when the list failed (a request error on
    ///   a live connection): after `restoreRetryDelay`, while it stays up,
    ///   so a host that keeps failing is asked again only that often.
    /// - Otherwise: the next time the connection comes up.
    func hostAvailability(after generation: Int) -> AnyPublisher<Void, Never> {
        let control = control
        let retryDelay = configuration.restoreRetryDelay
        return control.$state
            .map { state -> AnyPublisher<Void, Never> in
                guard state == .connected else { return Empty().eraseToAnyPublisher() }
                // `connectionCount` grows before `state` turns `.connected`.
                if control.connectionCount > generation {
                    return Just(()).eraseToAnyPublisher()
                }
                return Just(())
                    .delay(for: .seconds(retryDelay), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .first()
            .eraseToAnyPublisher()
    }

    /// Why this app cannot run local sessions at all (another copy of the
    /// app owns them, a disk image copy, no helper), checked now; nil when
    /// it can. A restore then keeps its saved tabs without asking the host.
    func installationProblem() -> String? {
        if let reason = instanceUnavailableReason {
            publish(reason)
            return reason
        }
        let reason = installationUnavailableReason()
        installationCheck = (reason, Date())
        return reason
    }

    /// Whether a new local tab can run as a persistent session now. When it
    /// cannot, Settings › Sessions says why and the tab runs natively.
    func canHostNewTabs() -> Bool {
        unavailableReasonForNewTabs() == nil
    }

    /// Checks again now (Settings › Sessions on appear) and publishes why
    /// local sessions are unavailable, or nil.
    @discardableResult
    func refreshStatus() -> String? {
        unavailableReasonForNewTabs(checkingInstallation: true)
    }

    private func unavailableReasonForNewTabs(checkingInstallation: Bool = false) -> String? {
        if let reason = instanceUnavailableReason {
            publish(reason)
            return reason
        }
        let now = Date()
        if checkingInstallation
            || installationCheck.map({ now.timeIntervalSince($0.checkedAt) >= configuration.installationCheckInterval }) ?? true {
            installationCheck = (installationUnavailableReason(), now)
        }
        var reason = installationCheck?.reason
        if reason == nil, let failure = launchFailure {
            if failure.retryAt > now {
                reason = failure.reason
            } else {
                launchFailure = nil
            }
        }
        publish(reason)
        return reason
    }

    /// A tab's session could not be started. When the host itself could not
    /// be reached or did not answer (`meansHostUnavailable`), new tabs run
    /// natively for a while (`unavailableRetryInterval`) and Settings ›
    /// Sessions says why. A rejection of that one request (say, a directory
    /// the host cannot use) affects only its tab.
    ///
    /// Either way Settings › Sessions shows the latest failure
    /// (`PersistentSessionsStatus.lastLaunchFailure`) until a session
    /// starts again.
    func noteLaunchFailure(_ error: Error) {
        let failure = Self.launchFailureReason(error)
        if status.lastLaunchFailure != failure {
            status.lastLaunchFailure = failure
        }
        guard Self.meansHostUnavailable(error) else { return }
        let reason = "The local session host could not start a session: \(Self.errorMessage(error))"
        launchFailure = (reason, Date().addingTimeInterval(configuration.unavailableRetryInterval))
        publish(instanceUnavailableReason ?? installationCheck?.reason ?? reason)
    }

    /// Why a tab's session could not start, as its fallback bar and
    /// Settings › Sessions say it: the host's own message for a rejection
    /// (the session limit, a holder that failed to start, a daemon whose
    /// executable was removed), else what went wrong reaching it.
    nonisolated static func launchFailureReason(_ error: Error) -> String {
        errorMessage(error)
    }

    private nonisolated static func errorMessage(_ error: Error) -> String {
        (error as? HostedSessionError)?.errorDescription ?? error.localizedDescription
    }

    /// Whether a failed Create says the local host cannot run sessions now:
    /// no connection (`.unavailable`) or no answer (`.transport`, after the
    /// retries). A host's rejection, an identity problem or a request the app
    /// refused concerns that request only.
    static func meansHostUnavailable(_ error: Error) -> Bool {
        guard let error = error as? HostedSessionError else { return true }
        switch error {
        case .unavailable, .transport:
            return true
        case .message, .rejected, .identityMismatch:
            return false
        }
    }

    private func noteLaunchSucceeded() {
        if status.lastLaunchFailure != nil {
            status.lastLaunchFailure = nil
        }
        guard launchFailure != nil else { return }
        launchFailure = nil
        publish(instanceUnavailableReason ?? installationCheck?.reason)
    }

    private func publish(_ reason: String?) {
        if status.localSessionsUnavailableReason != reason {
            status.localSessionsUnavailableReason = reason
        }
    }

    // MARK: Sessions

    /// Starts a session for a tab: its launch spec (built for `launch`, with
    /// the control connection's login environment), this app as owner, and
    /// the tab's tags. When the answer is lost, the same request (same
    /// request ID and spec, so the host makes at most one session) is sent
    /// again: once by `HostControl.create`, then `lostCreateRetries` times.
    /// If it still gets no answer, the host is listed later to end a session
    /// the request may have started (`endSessionOfLostCreate`).
    func create(
        _ request: PersistentSessionRequest,
        configuration launch: ShellProcessController.Configuration
    ) async throws -> PersistentSessionLaunch {
        if let reason = instanceUnavailableReason { throw HostedSessionError.unavailable(reason) }
        creatingCount += 1
        updateLease()
        defer {
            creatingCount -= 1
            updateLease()
        }
        let control = control
        try await control.connect()
        guard let hostID = control.hostID, let executable = control.executableURL else {
            throw HostedSessionError.unavailable("The connection to the local session host was lost.")
        }
        let loginEnvironment = control.loginEnvironment?.environment
        let spec = await launchSpec(launch, loginEnvironment)
        let requestID = request.requestID
        let createRequest = HostCreateRequest(
            requestID: requestID,
            name: Self.truncated(request.name, toBytes: Self.maxSessionNameBytes),
            cwd: spec.workingDirectory,
            command: spec.argv,
            environment: spec.environment,
            cols: min(max(request.columns, 2), 500),
            rows: min(max(request.rows, 1), 200),
            owner: owner,
            tags: Self.tags(for: request, requestID: requestID, resourcesCopy: spec.resourcesCopy),
            // A program that asks sees the colours of the terminal it is
            // shown in, as in a native tab.
            colors: terminalColors()
        )
        var retries = 0
        var answerWasLost = false
        let info: HostedSessionInfo
        while true {
            do {
                info = try await control.create(createRequest, expectedHostID: hostID)
                break
            } catch {
                let lost = (error as? HostedSessionError)?.isTransportFailure == true
                answerWasLost = answerWasLost || lost
                guard lost, retries < configuration.lostCreateRetries else {
                    // Once an answer was lost, the host may have started the
                    // session, whatever the last attempt said.
                    if answerWasLost { endSessionOfLostCreate(requestID, hostID: hostID) }
                    throw error
                }
                retries += 1
                try? await Task.sleep(for: .milliseconds(250 * (1 << retries)))
            }
        }
        noteLaunchSucceeded()
        return PersistentSessionLaunch(
            attachment: HostedSessionAttachment(
                host: .local,
                hostID: hostID,
                sessionID: info.id,
                name: info.name,
                remoteWorkingDirectory: info.cwd,
                executablePath: executable.path,
                environment: loginEnvironment ?? [:]
            ),
            info: info
        )
    }

    /// The host's sessions now (connecting when needed), and how a tab's
    /// adapter reaches each of them. A host that answers can run new tabs
    /// again (`noteLaunchFailure` said otherwise).
    func list() async throws -> (list: HostedSessionList, attachment: (HostedSessionInfo) -> HostedSessionAttachment) {
        let list = try await control.list()
        noteLaunchSucceeded()
        return listing(of: list)
    }

    /// `list` (taken through `control`) with how a tab's adapter reaches
    /// each of its sessions.
    func listing(
        of list: HostedSessionList
    ) -> (list: HostedSessionList, attachment: (HostedSessionInfo) -> HostedSessionAttachment) {
        noteLostSessions(in: list)
        let control = control
        let executablePath = control.executableURL?.path ?? ""
        let environment = control.loginEnvironment?.environment ?? [:]
        return (list, { info in
            HostedSessionAttachment(
                host: .local,
                hostID: list.hostID,
                sessionID: info.id,
                name: info.name,
                remoteWorkingDirectory: info.cwd,
                executablePath: executablePath,
                environment: environment
            )
        })
    }

    /// The adapter details for an existing session of this host, when the
    /// control connection knows the helper (after it connected once).
    func attachment(for info: HostedSessionInfo) -> HostedSessionAttachment? {
        let control = control
        guard let hostID = control.hostID, let executable = control.executableURL else { return nil }
        return HostedSessionAttachment(
            host: .local,
            hostID: hostID,
            sessionID: info.id,
            name: info.name,
            remoteWorkingDirectory: info.cwd,
            executablePath: executable.path,
            environment: control.loginEnvironment?.environment ?? [:]
        )
    }

    /// A Create whose answer never came may still have started a session,
    /// which no tab will ever show: once the host can be listed, end any
    /// session this request started (by its `cherry.launch` tag) that no tab
    /// owns. Listed again later, because a holder that was still starting may
    /// only appear then.
    private func endSessionOfLostCreate(_ requestID: UUID, hostID: String) {
        let launchTag = requestID.uuidString.lowercased()
        let checks = configuration.lostCreateChecks
        let control = control
        Task { @MainActor [weak self] in
            for delay in checks {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                guard let list = try? await control.list(), list.hostID == hostID else { continue }
                for info in list.sessions
                where Self.isLaunched(info, byRequest: launchTag, owner: self.owner)
                    && self.owningTab(of: info.id) == nil
                    && self.endings[info.id] == nil {
                    self.end(HostedSessionAttachment(
                        host: .local,
                        hostID: hostID,
                        sessionID: info.id,
                        name: info.name,
                        remoteWorkingDirectory: info.cwd,
                        executablePath: control.executableURL?.path ?? "",
                        environment: [:]
                    ))
                }
            }
        }
    }

    /// Ends the sessions of saved tabs that will never come back: their
    /// worktree was removed (or no longer exists) while they were kept,
    /// set aside or not restored yet, so no tab is left to end them. Only
    /// sessions this app created for a tab that owned them count: a record's
    /// own binding (`owned`), the session its saved Create started
    /// (`launchRequestID`), or one tagged with its tab id; records that were
    /// only attached, and sessions an open tab owns, are left alone. Until
    /// the host can be listed (completely, after a daemon restart) and lists
    /// none of them running, it is asked again, keeping the connection up,
    /// for `forgottenTabsWindow`.
    ///
    /// With a `store`, the tabs are recorded there first
    /// (`SessionsToEndRecord`, queued ahead of the save that stops naming
    /// them) and dropped once none of their sessions is left, so what this
    /// run could not end before it quit is ended at the next launch
    /// (`resumeEndingSessions(recordedIn:)`).
    func endSessions(ofForgottenTabs records: [WorkspaceSessionRecord], recordedIn store: WorkspaceStateStore? = nil) {
        guard instanceUnavailableReason == nil else { return }
        let targets = records.filter(\.mayOwnLocalSession)
        guard !targets.isEmpty else { return }
        store?.addSessionsToEnd(targets)
        searchAndEndSessions(ofForgottenTabs: targets, recordedIn: store)
    }

    /// Ends the sessions of forgotten tabs an earlier run recorded in
    /// `store` and could not end before it quit (`endSessions(ofForgottenTabs:recordedIn:)`).
    /// Once per store and run, when a project window opens; nothing when
    /// none is recorded.
    func resumeEndingSessions(recordedIn store: WorkspaceStateStore) {
        guard instanceUnavailableReason == nil,
              resumedSessionsToEnd.insert(ObjectIdentifier(store)).inserted
        else { return }
        let records = store.loadSessionsToEnd().filter(\.mayOwnLocalSession)
        guard !records.isEmpty else { return }
        searchAndEndSessions(ofForgottenTabs: records, recordedIn: store)
    }

    private func searchAndEndSessions(ofForgottenTabs targets: [WorkspaceSessionRecord], recordedIn store: WorkspaceStateStore?) {
        // This copy cannot reach the local host at all (a disk image copy,
        // no helper): a copy that can will end them.
        guard installationProblem() == nil else { return }
        forgottenTabSearches += 1
        let search = UUID()
        forgottenTabTargets[search] = targets
        updateLease()
        let deadline = ContinuousClock.now + configuration.forgottenTabsWindow
        let ids = Set(targets.map(\.id))
        Task { @MainActor [weak self] in
            var delay: Duration = .milliseconds(500)
            while ContinuousClock.now < deadline {
                guard let self else { return }
                if let list = try? await completeList() {
                    let endings = endListedSessions(ofForgottenTabs: targets, in: list)
                    if endings.isEmpty, !list.awaitsHolders {
                        // None of them is left.
                        store?.removeSessionsToEnd(ids: ids)
                        break
                    }
                    // Listed again after these: an ending that gave up (the
                    // host did not answer) is tried again.
                    for ending in endings { await ending.value }
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(15))
            }
            guard let self else { return }
            forgottenTabSearches -= 1
            forgottenTabTargets[search] = nil
            updateLease()
        }
    }

    /// Ends the listed sessions `records` name that no open tab owns, and
    /// returns their endings (those under way already included).
    private func endListedSessions(ofForgottenTabs records: [WorkspaceSessionRecord], in list: HostedSessionList) -> [Task<Void, Never>] {
        let listing = listing(of: list)
        var endings: [Task<Void, Never>] = []
        for info in list.sessions where info.owner == owner && owningTab(of: info.id) == nil {
            let named = records.contains { Self.record($0, names: info, hostID: list.hostID, owner: owner) }
            if named { endings.append(end(listing.attachment(info))) }
        }
        return endings
    }

    /// Whether a search for the sessions of forgotten saved tabs under way
    /// will end this session (`endSessions(ofForgottenTabs:)`): the
    /// Background Sessions list leaves it out meanwhile.
    func isScheduledToEnd(_ info: HostedSessionInfo, hostID: String) -> Bool {
        guard info.owner == owner, owningTab(of: info.id) == nil else { return false }
        return forgottenTabTargets.values.contains { records in
            records.contains { Self.record($0, names: info, hostID: hostID, owner: owner) }
        }
    }

    /// Whether a saved tab names this session of `owner`'s on the local
    /// host `hostID`: its binding when it owned the session (`owned`), or
    /// any binding with `includingAttached`; the session its saved Create
    /// started (`launchRequestID`); or one tagged with its tab id.
    nonisolated static func record(
        _ record: WorkspaceSessionRecord,
        names info: HostedSessionInfo,
        hostID: String,
        owner: String,
        includingAttached: Bool = false
    ) -> Bool {
        if let binding = record.hosted, binding.host == HostedSessionHost.local.id,
           includingAttached || binding.owned == true,
           binding.hostID == hostID, binding.sessionID == info.id {
            return true
        }
        if let requestID = record.launchRequestID, isLaunched(info, byRequest: requestID, owner: owner) {
            return true
        }
        return tabID(of: info, owner: owner) == record.id
    }

    // MARK: Tabs and their sessions

    /// Records an open tab built to run as a persistent session.
    func register(_ tab: TerminalSession) {
        openTabs = openTabs.filter { $0.value.session != nil }
        openTabs[ObjectIdentifier(tab)] = WeakTab(tab)
    }

    /// The tab closed: it no longer owns the session it names, which another
    /// tab (Persistent Sessions → Attach) or a restore may then own.
    func unregister(_ tab: TerminalSession) {
        openTabs[ObjectIdentifier(tab)] = nil
    }

    /// The open tab that owns this session: its program runs there (or ran:
    /// the tab shows its final screen), and closing or restarting that tab
    /// may end the session. At most one tab owns a session; any other tab
    /// showing it is only attached (`hostedAttachment`), and closing that
    /// tab only disconnects.
    func owningTab(of sessionID: String) -> TerminalSession? {
        openTabs.values.lazy.compactMap(\.session).first { tab in
            tab.isPersistentLocalSession && tab.persistentSession?.sessionID == sessionID
        }
    }

    /// Whether an open tab built to run as a persistent session has this id.
    func hasOpenTab(withID id: UUID) -> Bool {
        openTabs.values.contains { $0.session?.id == id }
    }

    /// Whether an open tab, in any window, shows this session of the local
    /// host `hostID` or is about to: the tab that owns it, a tab attached to
    /// it (`attachedTabs`), the tab it was started for (`cherry.tab`), or a
    /// tab whose Create or restart started it and has not answered yet (its
    /// `persistentLaunchRequestID`). Anything else of this app's is in the
    /// background (`BackgroundSessions`).
    func isShownByOpenTab(_ info: HostedSessionInfo, hostID: String, attachedTabs: OpenHostedTabs = .shared) -> Bool {
        if owningTab(of: info.id) != nil || attachedTabs.showsSession(hostID: hostID, sessionID: info.id) {
            return true
        }
        if let tabID = Self.tabID(of: info, owner: owner),
           hasOpenTab(withID: tabID) || attachedTabs.hasOpenTab(withID: tabID) {
            return true
        }
        guard info.owner == owner, let launchID = Self.launchRequestID(of: info) else { return false }
        return openTabs.values.contains { $0.session?.persistentLaunchRequestID == launchID }
    }

    /// Whether a tab of this app may own `info`'s session (Persistent
    /// Sessions → Attach): this app variant created it, no client is
    /// attached to it (another terminal or app may be showing it), no open
    /// tab owns it, and it is not being ended, now or once its tab's close
    /// can no longer be undone (a tab would outlive it). Anything else is
    /// attached without owning it.
    func canAdopt(_ info: HostedSessionInfo) -> Bool {
        instanceUnavailableReason == nil && info.owner == owner && info.clients == 0 && owningTab(of: info.id) == nil
            && !isEnding(info.id)
    }

    /// Follows the session for `session`: its exit, pid and removal. Only
    /// its owner follows a session; another tab is never bound in its place.
    func bind(_ session: TerminalSession, to sessionID: String) {
        if let bound = boundTabs[sessionID]?.session, bound !== session {
            SessionLog.notice("session \(sessionID) already belongs to tab \(bound.id.uuidString); tab \(session.id.uuidString) does not follow it")
            return
        }
        boundTabs[sessionID] = WeakTab(session)
        updateLease()
        // What the program signalled before its tab followed it (while no
        // app ran, or before its Create answer arrived).
        dropExpiredPendingSignals()
        let pending = pendingSignals.filter { $0.sessionID == sessionID }
        guard !pending.isEmpty else { return }
        pendingSignals.removeAll { $0.sessionID == sessionID }
        for entry in pending {
            session.persistentHostDidSignal(entry.signal)
        }
    }

    func unbind(sessionID: String) {
        guard boundTabs.removeValue(forKey: sessionID) != nil else { return }
        updateLease()
    }

    /// Stops following the session for `session`, unless another tab does.
    func unbind(_ session: TerminalSession, from sessionID: String) {
        guard let bound = boundTabs[sessionID], bound.session == nil || bound.session === session else { return }
        unbind(sessionID: sessionID)
    }

    /// The tab that runs its program in this session, if one is open.
    func boundTab(for sessionID: String) -> TerminalSession? {
        boundTabs[sessionID]?.session
    }

    /// The session as the host last reported it.
    func sessionInfo(_ sessionID: String) -> HostedSessionInfo? {
        control.sessions.first { $0.id == sessionID }
    }

    /// The program's state after the host's list lacked its session while it
    /// ran, so a session whose holder registers late with a restarted
    /// daemon is not taken for gone: from a list that is complete (the host
    /// is listed until it expects no more holders, at most
    /// `pendingHoldersWait`), or, from a host that does not report pending
    /// holders, from a fresh list after `disappearanceConfirmationDelay`.
    /// `.unknown` when the host cannot be listed, or still expects holders.
    func confirmedProgramState(of binding: HostedSessionAttachment) async -> PersistentProgramState {
        guard var list = try? await control.list() else { return .unknown }
        if list.pendingHolders == nil {
            try? await Task.sleep(for: configuration.disappearanceConfirmationDelay)
            guard let later = try? await control.list() else { return .unknown }
            list = later
        } else if list.awaitsHolders {
            guard let later = try? await completeList(after: list) else { return .unknown }
            list = later
        }
        guard list.hostID == binding.hostID else { return .gone }
        guard let info = list.sessions.first(where: { $0.id == binding.sessionID }) else {
            return list.awaitsHolders ? .unknown : .gone
        }
        return info.isRunning ? .running(info) : .exited(Self.exitStatus(of: info))
    }

    /// The host's list once a daemon that just restarted expects no more
    /// holders (`HostControl.listUntilHoldersRegistered`), within
    /// `pendingHoldersWait`: check `isComplete`.
    func completeList(after first: HostedSessionList? = nil) async throws -> HostedSessionList {
        let list = try await control.listUntilHoldersRegistered(
            after: first,
            timeout: configuration.pendingHoldersWait,
            pollInterval: configuration.pendingHoldersPollInterval
        )
        noteLostSessions(in: list)
        return list
    }

    /// Records the sessions the host reports lost (`lostSessionIDs`: their
    /// holders were killed) in `endedSessionsStore`, the first time this run
    /// sees them: the host forgets them when its daemon restarts, and a
    /// window that opens later still needs them (`SystemEndedSessions`).
    private func noteLostSessions(in list: HostedSessionList) {
        let fresh = list.lostSessionIDs.filter { !recordedLostSessions.contains("\(list.hostID)\u{0}\($0)") }
        guard let store = endedSessionsStore, !fresh.isEmpty else { return }
        recordedLostSessions.formUnion(fresh.map { "\(list.hostID)\u{0}\($0)" })
        store.addLostSessions(fresh, hostID: list.hostID)
    }

    func programState(of binding: HostedSessionAttachment) -> PersistentProgramState {
        let control = control
        let connected = control.state == .connected
        if connected, let hostID = control.hostID, hostID != binding.hostID { return .gone }
        if let info = control.sessions.first(where: { $0.id == binding.sessionID }) {
            // An exit is final even in a list that is not current.
            guard info.isRunning else { return .exited(Self.exitStatus(of: info)) }
            return connected ? .running(info) : .unknown
        }
        return connected ? .gone : .unknown
    }

    /// Ends a tab's session: Kill, then Remove once the host reports the
    /// exit, within `timeout` (default `terminationTimeout`). A Kill or
    /// Remove without a definite answer is sent again within
    /// `endRetryWindow`. Ending a session twice returns the first ending.
    /// Quit waits for these. Nothing is ended by a copy of the app that does
    /// not own this Mac's sessions (`AppInstanceLock`).
    @discardableResult
    func end(_ binding: HostedSessionAttachment, waitingForExitUpTo timeout: Duration? = nil) -> Task<Void, Never> {
        unbind(sessionID: binding.sessionID)
        if let ending = endings[binding.sessionID] { return ending }
        guard instanceUnavailableReason == nil else { return Task {} }
        noteEndedOnPurpose(hostID: binding.hostID, sessionID: binding.sessionID)
        let timeout = timeout ?? configuration.terminationTimeout
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await terminateAndRemove(binding, timeout: timeout)
            endings[binding.sessionID] = nil
            updateLease()
        }
        endings[binding.sessionID] = task
        // Ended before its undo window ran out: it waits no more.
        if let deferred = deferredEnds.removeValue(forKey: binding.sessionID) {
            forgetRecord(of: deferred, sessionID: binding.sessionID)
        }
        updateLease()
        return task
    }

    var hasPendingEnds: Bool { !endings.isEmpty }

    /// A bell or notification of this session reached no tab (it is in
    /// the background): recorded in `endedSessionsStore` (the app's store),
    /// so the tab that shows it next comes up unread (`takeUnread`).
    func noteUnread(hostID: String, sessionID: String) {
        endedSessionsStore?.addUnreadSession(hostID: hostID, sessionID: sessionID)
    }

    /// Whether the session had a bell or notification while in the
    /// background (`noteUnread`); the mark goes.
    func takeUnread(_ binding: HostedSessionAttachment) -> Bool {
        endedSessionsStore?.takeUnreadSession(hostID: binding.hostID, sessionID: binding.sessionID) ?? false
    }

    /// This app ends this session of This Mac on purpose (`end`, or
    /// Persistent Sessions → Terminate or Remove): recorded in
    /// `endedSessionsStore`.
    func noteEndedOnPurpose(hostID: String, sessionID: String) {
        endedSessionsStore?.addEndedSessions([(hostID: hostID, sessionID: sessionID)])
    }

    /// Whether the session is being ended, or will be once its tab's close
    /// can no longer be undone (`deferEnd`).
    func isEnding(_ sessionID: String) -> Bool {
        endings[sessionID] != nil || deferredEnds[sessionID] != nil
    }

    // MARK: Ends that wait for an undo

    /// A user closed the tab of `sessionID` (⌘W), and may still undo that
    /// (`ClosedTabHistory`): the session runs on until `endDeferred` ends it
    /// with `end` (the tab's usual end), once the undo window ran out, its
    /// window closed or Cherry quits, or `resumeDeferred` gives it back to
    /// the tab that comes back. Meanwhile it counts as being ended
    /// (`isEnding`): Background Sessions, the launch notice, orphan adoption
    /// and Persistent Sessions → Attach leave it alone. The connection to
    /// the host stays up. The tab is first recorded in `store` as a session
    /// to end (`SessionsToEndRecord`), so a launch after Cherry exited
    /// before ending it ends it (`resumeEndingSessions(recordedIn:)`).
    func deferEnd(
        ofSession sessionID: String,
        record: WorkspaceSessionRecord,
        recordedIn store: WorkspaceStateStore?,
        end: @escaping @MainActor () -> Void
    ) {
        guard instanceUnavailableReason == nil, endings[sessionID] == nil else {
            end()
            return
        }
        store?.addSessionsToEnd([record])
        deferredEnds[sessionID] = DeferredEnd(record: record, store: store, end: end)
        updateLease()
    }

    /// Whether some session's end waits for an undo: a quit ends them first.
    var hasDeferredEnds: Bool { !deferredEnds.isEmpty }

    /// Ends a session whose end waited for an undo, now; nothing when it no
    /// longer waits. Its record leaves the store once the host no longer
    /// lists it (else the next launch ends it).
    func endDeferred(_ sessionID: String) {
        guard let deferred = deferredEnds.removeValue(forKey: sessionID) else { return }
        deferred.end()
        updateLease()
        forgetRecord(of: deferred, sessionID: sessionID)
    }

    /// Ends every session whose end waits for an undo (a quit).
    func endAllDeferred() {
        for sessionID in deferredEnds.keys.sorted() {
            endDeferred(sessionID)
        }
    }

    /// Its tab's close was undone: the session is not ended, and leaves the
    /// sessions to end. False when its end did not wait (any more).
    @discardableResult
    func resumeDeferred(_ sessionID: String) -> Bool {
        guard let deferred = deferredEnds.removeValue(forKey: sessionID) else { return false }
        deferred.store?.removeSessionsToEnd(ids: [deferred.record.id])
        updateLease()
        return true
    }

    /// Drops `deferred`'s record from its store once the session's ending is
    /// over, when the host no longer lists it.
    private func forgetRecord(of deferred: DeferredEnd, sessionID: String) {
        guard let store = deferred.store else { return }
        let ending = endings[sessionID]
        let tabID = deferred.record.id
        Task { @MainActor [weak self] in
            await ending?.value
            guard let self, sessionInfo(sessionID) == nil else { return }
            store.removeSessionsToEnd(ids: [tabID])
        }
    }

    /// Waits until every session being ended is gone, or `timeout` passed.
    /// True when none is left.
    @discardableResult
    func waitForPendingEnds(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !endings.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return endings.isEmpty
    }

    /// What to do after a Kill or Remove failed.
    private enum EndStep {
        /// The host says the session is gone, or another host answers:
        /// nothing is left to end.
        case gone
        /// No definite answer (unreachable, no answer, the host refused for
        /// now): send it again later.
        case retry
        /// Nothing more can be done from here.
        case stop
    }

    private static func endStep(after error: Error) -> EndStep {
        guard let error = error as? HostedSessionError else { return .stop }
        switch error {
        case .rejected(let code, _) where code == HostProtocol.ErrorCode.unknownSession:
            return .gone
        case .identityMismatch:
            return .gone
        case .transport, .unavailable, .rejected:
            return .retry
        case .message:
            return .stop
        }
    }

    private func terminateAndRemove(_ binding: HostedSessionAttachment, timeout: Duration) async {
        let control = control
        let id = binding.sessionID
        let deadline = ContinuousClock.now + configuration.endRetryWindow
        var delay = configuration.endRetryDelay.initial
        /// Waits before the next attempt; false once the window has passed.
        func backOff() async -> Bool {
            guard ContinuousClock.now + delay < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, configuration.endRetryDelay.maximum)
            return !Task.isCancelled
        }
        // Kill, until the host took it (or says the session is gone). A
        // Kill of a session that exited meanwhile is answered Ok too.
        while control.sessions.first(where: { $0.id == id })?.isRunning != false {
            do {
                try await control.terminate(id, expectedHostID: binding.hostID)
                let exited = (try? await control.waitForSession(id, timeout: timeout) { info in
                    info.map { !$0.isRunning } ?? true
                }) ?? false
                // Still running: the host's own kill escalation goes on, and
                // the session stays listed (ended) until removed.
                guard exited else { return }
                break
            } catch {
                switch Self.endStep(after: error) {
                case .gone:
                    return
                case .stop:
                    SessionLog.error("could not end session \(id): \(error.localizedDescription)")
                    return
                case .retry:
                    guard await backOff() else {
                        SessionLog.error("gave up ending session \(id) (\(error.localizedDescription)); it may still run")
                        return
                    }
                }
            }
        }
        // Remove the ended session (and its retained history).
        while true {
            do {
                try await control.remove(id, expectedHostID: binding.hostID)
                return
            } catch {
                guard Self.endStep(after: error) == .retry, await backOff() else { return }
            }
        }
    }

    /// Types into a session through the control connection (its tab's
    /// adapter is not attached), in order with earlier input. The task ends
    /// once the host took the input into the session's queue, or throws
    /// when it did not (the session ended, the host is unreachable, another
    /// host answers):
    /// - `HostInputPartiallyDelivered`: input longer than one request
    ///   (64 KiB) went in parts, and one after the first failed. Its first
    ///   `deliveredBytes` bytes were typed, and none after the part that
    ///   failed (that part too may have been, when its `failure` is
    ///   `.transport`): resending all of it would type those bytes twice.
    /// - `HostedSessionError.transport` (the first part's answer was
    ///   lost): the host may have typed that part.
    /// - Any other error: none of it was typed.
    @discardableResult
    func sendInput(_ data: Data, to binding: HostedSessionAttachment) -> Task<Void, Error> {
        guard !data.isEmpty else { return Task {} }
        let id = binding.sessionID
        let previous = inputChains[id]
        let generation = (previous?.generation ?? 0) + 1
        let control = control
        let task = Task { @MainActor [weak self] in
            // In order: after the earlier input, whether or not it arrived.
            _ = await previous?.task.result
            var failure: Error?
            do {
                try await control.sendInput(id, data, expectedHostID: binding.hostID)
            } catch {
                failure = error
            }
            if let self, inputChains[id]?.generation == generation {
                inputChains[id] = nil
                updateLease()
            }
            if let failure { throw failure }
        }
        inputChains[id] = (task, generation)
        updateLease()
        return task
    }

    /// The session's screen as its host has it, with the retained history
    /// first: what a tab shows while no attach adapter does. `maxLines`:
    /// only its last this many lines.
    func screen(of binding: HostedSessionAttachment, maxLines: Int? = nil) async throws -> HostScreenText {
        try await control.screen(binding.sessionID, scrollback: true, maxLines: maxLines, expectedHostID: binding.hostID)
    }

    /// Names the session on its host as its tab is named (an explicit
    /// rename, or the task title an agent's tab shows), so `cherry list`,
    /// Background Sessions and the Persistent Sessions sheet show that name
    /// rather than the one it was created with. Cut to the host's limit
    /// (`maxSessionNameBytes`). A failure is only logged: the next rename
    /// or bind sends it again.
    @discardableResult
    func rename(_ binding: HostedSessionAttachment, to name: String) -> Task<Void, Never> {
        let name = Self.truncated(name, toBytes: Self.maxSessionNameBytes)
        let control = control
        return Task { @MainActor in
            do {
                try await control.update(binding.sessionID, name: name, expectedHostID: binding.hostID)
            } catch {
                SessionLog.error("could not rename session \(binding.sessionID): \(Self.errorMessage(error))")
            }
        }
    }

    /// Clears the history above the session's screen on its host (Clear
    /// Scrollback, MCP `clear_output`): reads of its screen (`screen(of:)`)
    /// and an adapter that attaches no longer bring it back.
    func clearHistory(of binding: HostedSessionAttachment) async throws {
        try await control.clearHistory(binding.sessionID, expectedHostID: binding.hostID)
    }

    // MARK: Events

    private func updateLease() {
        boundTabs = boundTabs.filter { $0.value.session != nil }
        let needed = creatingCount > 0 || !boundTabs.isEmpty || !endings.isEmpty || !deferredEnds.isEmpty
            || !inputChains.isEmpty || forgottenTabSearches > 0
        if needed, lease == nil {
            observeEvents()
            lease = control.retain()
        } else if !needed, let lease {
            lease.release()
            self.lease = nil
        }
    }

    private func observeEvents() {
        guard eventSubscription == nil else { return }
        // HostControl publishes on the main actor.
        eventSubscription = control.events.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: HostSessionEvent) {
        switch event {
        case .exited(let id, let exitCode, _, let end):
            boundTab(for: id)?.persistentProgramDidExit(
                sessionID: id, status: Int32(clamping: exitCode), end: end ?? sessionInfo(id)?.end
            )
        case .added(let info), .changed(let info):
            guard let tab = boundTab(for: info.id) else { return }
            if info.isRunning {
                tab.persistentSessionDidChange(info)
            } else {
                tab.persistentProgramDidExit(sessionID: info.id, status: Self.exitStatus(of: info), end: info.end)
            }
        case .removed(let id):
            // A running session is removed only after it exited, which the
            // tab would have heard first: this is most likely a list taken
            // before its holder registered again, so the tab checks again.
            boundTab(for: id)?.persistentSessionMayHaveDisappeared(sessionID: id)
        case .resync:
            // Events may have been missed: take the list as it is now.
            for (id, weakTab) in boundTabs {
                guard let tab = weakTab.session else { continue }
                if let info = sessionInfo(id) {
                    if info.isRunning {
                        tab.persistentSessionDidChange(info)
                    } else {
                        tab.persistentProgramDidExit(sessionID: id, status: Self.exitStatus(of: info), end: info.end)
                    }
                } else if control.state == .connected {
                    tab.persistentSessionMayHaveDisappeared(sessionID: id)
                }
            }
        case .bell(let id):
            deliver(.bell, toSession: id)
        case .notification(let id, let title, let body):
            deliver(.notification(title: title, body: body), toSession: id)
        case .progress(let id, let state, let value):
            deliver(.progress(state, value: value), toSession: id)
        }
    }

    /// A bell, notification or progress report for the tab following the
    /// session, which shows it unless its attach adapter passes the same to
    /// its surface (`TerminalSession.persistentHostDidSignal`). A bell or
    /// notification of a session in the background is posted as the app's
    /// notification (`backgroundSignalHandler`). Otherwise kept a while for
    /// the tab that follows the session next, and offered to the handler
    /// again once no tab took it.
    private func deliver(_ signal: PersistentHostSignal, toSession sessionID: String) {
        if let tab = boundTab(for: sessionID) {
            tab.persistentHostDidSignal(signal)
            return
        }
        dropExpiredPendingSignals()
        if case .progress = signal {
            // Only the latest progress matters.
            pendingSignals.removeAll { entry in
                guard entry.sessionID == sessionID, case .progress = entry.signal else { return false }
                return true
            }
        } else if offerToBackground(signal, ofSession: sessionID) {
            return
        }
        pendingSignals.append((sessionID, signal, Date()))
        if pendingSignals.count > configuration.pendingSignalLimit {
            pendingSignals.removeFirst(pendingSignals.count - configuration.pendingSignalLimit)
        }
        schedulePendingSignalExpiry()
    }

    /// Hands a bell or notification of this app's session to
    /// `backgroundSignalHandler`; true when it took it.
    private func offerToBackground(_ signal: PersistentHostSignal, ofSession sessionID: String) -> Bool {
        guard let backgroundSignalHandler, let info = sessionInfo(sessionID), info.owner == owner else { return false }
        return backgroundSignalHandler(info, signal)
    }

    /// Once the oldest pending signal's wait is over, those no tab took are
    /// offered to the background handler, then dropped.
    private func schedulePendingSignalExpiry() {
        guard !pendingSignalExpiryScheduled, let oldest = pendingSignals.first?.receivedAt else { return }
        pendingSignalExpiryScheduled = true
        let delay = max(0, oldest.addingTimeInterval(configuration.pendingSignalLifetime).timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSignalExpiryScheduled = false
                self.dropExpiredPendingSignals()
                self.schedulePendingSignalExpiry()
            }
        }
    }

    /// Drops the pending signals whose wait is over, offering the bells and
    /// notifications among them to the background handler first (at most
    /// one of each kind per session: the tab would have shown them once).
    private func dropExpiredPendingSignals() {
        let oldest = Date().addingTimeInterval(-configuration.pendingSignalLifetime)
        let expired = pendingSignals.filter { $0.receivedAt < oldest }
        guard !expired.isEmpty else { return }
        pendingSignals.removeAll { $0.receivedAt < oldest }
        var offered = Set<String>()
        for entry in expired {
            let key: String
            switch entry.signal {
            case .progress: continue
            case .bell: key = "\(entry.sessionID)\u{0}bell"
            case .notification(let title, let body): key = "\(entry.sessionID)\u{0}\(title)\u{0}\(body)"
            }
            guard offered.insert(key).inserted else { continue }
            _ = offerToBackground(entry.signal, ofSession: entry.sessionID)
        }
    }

    // MARK: Helpers

    /// The status a tab reports for an exited session: its exit code, which
    /// the host sets to 128 + N after signal N.
    nonisolated static func exitStatus(of info: HostedSessionInfo) -> Int32 {
        if let exitCode = info.exitCode { return Int32(clamping: exitCode) }
        if let signal = info.exitSignal { return 128 + signal }
        return 0
    }

    /// Whether the session's program exited by itself with status 0 (not
    /// a signal, and not an exit whose status is unknown).
    static func endedCleanly(_ info: HostedSessionInfo) -> Bool {
        !info.isRunning && info.exitCode == 0 && info.exitSignal == nil
    }

    static func tags(for request: PersistentSessionRequest, requestID: UUID, resourcesCopy: String? = nil) -> [String: String] {
        var tags = [
            PersistentSessionTag.tab: request.tabID.uuidString,
            PersistentSessionTag.kind: request.kind.rawValue,
            PersistentSessionTag.launch: requestID.uuidString.lowercased()
        ]
        if let agentName = request.agentName?.nilIfEmpty { tags[PersistentSessionTag.agent] = agentName }
        if let commandName = request.commandName?.nilIfEmpty { tags[PersistentSessionTag.command] = commandName }
        if let projectRoot = request.projectRoot?.nilIfEmpty { tags[PersistentSessionTag.project] = projectRoot }
        if let resourcesCopy = resourcesCopy?.nilIfEmpty { tags[PersistentSessionTag.resources] = resourcesCopy }
        return tags.mapValues { truncated($0, toBytes: PersistentSessionTag.maxValueBytes) }
    }

    /// The tab id a session of this app's was started for, from its tags.
    nonisolated static func tabID(of info: HostedSessionInfo, owner: String = PersistentLocalSessions.appOwner) -> UUID? {
        guard info.owner == owner else { return nil }
        return info.tags[PersistentSessionTag.tab].flatMap(UUID.init(uuidString:))
    }

    /// The `request_id` of the Create that started the session (lowercased):
    /// as the host reports it, or from the `cherry.launch` tag this app
    /// sets (for a host that does not report it).
    nonisolated static func launchRequestID(of info: HostedSessionInfo) -> String? {
        (info.requestID?.nilIfEmpty ?? info.tags[PersistentSessionTag.launch]?.nilIfEmpty)?.lowercased()
    }

    /// Whether this app variant started the session with a Create of
    /// `requestID`.
    nonisolated static func isLaunched(_ info: HostedSessionInfo, byRequest requestID: String, owner: String) -> Bool {
        info.owner == owner && launchRequestID(of: info) == requestID.lowercased()
    }

    /// `text` cut to at most `limit` UTF-8 bytes, on a character boundary.
    static func truncated(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= limit else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}
