import CherryControl
import Combine
import Darwin
import Foundation

/// A project window's model: its folder's tabs (`workspace`), which it
/// saves and restores, and for a project on another Mac what that Mac says
/// about it.
@MainActor
final class RepositoryWorkspace: ObservableObject {
    /// The project, as the window registry and the saved state name it.
    let repositoryRoot: String
    /// Which of the project's windows this is (`ProjectWindowValue.windowID`):
    /// nil for its primary window. Each window loads and saves only its own
    /// file (`WorkspaceStateStore.stateFileName(repositoryRoot:windowID:)`).
    let windowID: UUID?
    /// The project's folder as its tabs name it: `repositoryRoot` with its
    /// links resolved (a device's project: its key).
    let workspaceRoot: String
    /// The window's tabs.
    let workspace: TerminalWorkspace

    private let backendPolicy: SessionBackendPolicy
    private let stateStore: WorkspaceStateStore?
    private let sessionRestorer: WorkspaceSessionRestorer
    private let autoStartCommands: @MainActor (String) -> [ProjectCommandDefinition]
    /// The grid this window gives its terminals (`TerminalWindowGrid`).
    private let windowGrid = TerminalWindowGrid()
    private var didAutoStart = false
    /// Auto-start was asked for before the window claimed its project: it
    /// runs once it has (`beginRestoringSavedStateIfNeeded`).
    private var autoStartAwaitsClaim = false
    /// Whether this window starts the project's auto-start commands: the
    /// one that opened the project (no other window of it was registered
    /// when it claimed it: `ProjectWindowRegistry.register` sets it). True
    /// for a window no registry claimed (tests).
    var opensProject = true

    // Workspace persistence. Nothing is saved before the window claimed its
    // project (`beginRestoringSavedStateIfNeeded`), so a duplicate window
    // never writes, and nothing is saved once a teardown intent closed it.
    /// Saved tabs not restored yet. Saves carry them over unchanged, so an
    /// unfinished or skipped restore loses nothing.
    private var pendingRecord: WorktreeStateRecord?
    /// Saved tabs a restore has not brought back or dropped yet: kept for a
    /// later launch (their helper or host was unavailable), still being
    /// restored (`inFlightRecordIDs`), or set aside (a command tab opened
    /// meanwhile runs that command). Saves merge them into the live
    /// workspace, so none of them is forgotten.
    private var keptRecord: WorktreeStateRecord?
    /// Kept records whose host had not answered when the restore added the
    /// others: the restore's remainder brings them back, keeps or drops
    /// them.
    private var inFlightRecordIDs: Set<UUID> = []
    /// Kept records of restored command tabs that a tab opened meanwhile
    /// runs the command of (`TerminalWorkspace.restoreSessions`): saved for
    /// the next launch, not restored again during this run.
    private var setAsideRecordIDs: Set<UUID> = []
    private var restoreTask: Task<Void, Never>?
    /// The records the restore task asks for.
    private var restoreTaskRecordIDs: Set<UUID> = []
    /// Restores' remainders (hosts that answered late).
    private var restoreRemainders: [UUID: Task<Void, Never>] = [:]
    /// The selection the workspace had when its restore added its first
    /// tabs, while more are in flight: a later tab that is the saved
    /// selection is selected only while that has not changed.
    private var selectionAwaitingRestore: SelectionMark?
    private let restoredTabLaunchQueue: RestoredTabLaunchQueue
    private var restoreWaiters: [@MainActor () -> Void] = []
    /// Kept records that come back when their host becomes reachable during
    /// this run (`WorkspaceRestoreResult.retryWhenAvailable`).
    private var restoreRetry: AnyCancellable?
    /// Auto-start commands not started because a saved tab of the project
    /// (in this window or another, still being restored or kept while its
    /// host was unreachable) may bring back their tab; they start once it
    /// has come back.
    private var autoStartsWaitingForRetry: [ProjectCommandDefinition] = []
    private var didBeginRestore = false
    private(set) var isTearingDown = false
    /// Every restore request made: cancelled when the window tears down, so
    /// a restore still under way builds no more tabs and ends those it has
    /// not handed back.
    private var restoreCancellations: [WorkspaceRestoreCancellation] = []
    /// Which of this app's sessions no saved tab names (`OrphanedSessionCriteria`),
    /// from the state loaded when the window opened; nil when this window
    /// saves nothing or runs no local sessions.
    private let orphanCriteria: OrphanedSessionCriteria?
    /// Which saved tabs whose sessions are gone the system ended (a restart
    /// or log out while Cherry was closed), from the state loaded when the
    /// window opened: they come back ended. Nil when this window saves
    /// nothing or runs no local sessions.
    private let systemEnds: SystemEndedSessions?
    /// Tabs this window's restores brought back ended by the system during
    /// this run, which its toast names and Restart All starts
    /// (`announceSystemEndedTabs`).
    private var systemEndedTabs: [WeakReference<TerminalSession>] = []
    /// Whether orphaned sessions were looked for (once per run).
    private var didScanForOrphans = false
    private var orphanScanTask: Task<Void, Never>?
    private var orphanScanRetry: AnyCancellable?
    /// When the first window of this app run opened: sessions created
    /// since belong to this run's tabs, never to a tab whose record was lost.
    private static let appRunStartedAt = Date()
    private var persistenceSubscription: AnyCancellable?
    /// A device's window keeps its host's control connection up while it
    /// has tabs (`updateRemoteLease`): its tabs follow their programs, and
    /// an offline Mac is retried (backoff, wake, network changes).
    private var remoteLease: HostControlLease?
    private var remoteLeaseSubscription: AnyCancellable?
    /// Saved tabs of a device's window a restore kept because the device
    /// could not be reached: they come back once it answers.
    @Published private(set) var remoteTabsWaitingCount = 0
    /// Whether the restore that opens the window has not brought its saved
    /// tabs back yet: the window stays off screen until it has
    /// (`ProjectWindowReveal`), and says it is restoring them if it has to
    /// show first (`WindowRestoringBar`). False for a window with nothing
    /// to restore.
    @Published private(set) var isAwaitingInitialRestore: Bool
    private var initialRestoreWaiters: [@MainActor () -> Void] = []
    /// Whether the saved persistent tabs are shown at once, before This
    /// Mac's host answers (`OptimisticRestore`). The app's windows do;
    /// tests opt in.
    let showsSavedTabsBeforeHostAnswers: Bool
    /// Tabs shown before the host answered, by record id, until the restore
    /// confirms or withdraws each (`reconcileOptimisticTabs`).
    private var optimisticTabs: [UUID: TerminalSession] = [:]
    /// The selection once those tabs were shown: the restore's answer
    /// selects the saved tab only while nobody changed it since.
    private var optimisticSelection: SelectionMark?
    private var chromeStateSubscription: AnyCancellable?
    private weak var chromeState: ProjectWindowChromeState?
    /// Agent groups a restore collapsed while the window had given no
    /// chrome state (tests): saved with the tabs.
    private var collapsedAgentGroupIDsWithoutChrome: Set<UUID> = []
    /// The registry this repository's window registered with
    /// (`ProjectWindowRegistry.register`): it names that window.
    weak var windowRegistry: ProjectWindowRegistry?
    private var pendingStateSaveTask: Task<Void, Never>?

    /// The app passes `.userSettings`, `.shared` and
    /// `WorkspaceSessionRestorers.hostedByDefault(localSessions: .shared)`;
    /// tests get native tabs and no persistence unless they opt in.
    init(
        projectRoot: String,
        windowID: UUID? = nil,
        backendPolicy: SessionBackendPolicy = .native,
        stateStore: WorkspaceStateStore? = nil,
        sessionRestorer: @escaping WorkspaceSessionRestorer = WorkspaceSessionRestorers.none,
        autoStartCommands: @escaping @MainActor (String) -> [ProjectCommandDefinition] = { root in
            // A device's project reads its cherry.toml through that Mac's
            // `project-info` (`RemoteProjectFiles`, docs/specs/remote-devices.md).
            AgentSettings.shared.launchableProjectCommands(for: root).filter(\.autoStart)
        },
        restoredTabLaunchQueue: RestoredTabLaunchQueue = .shared,
        remoteProject: RemoteProjectAccess? = nil,
        remoteProjectFiles: RemoteProjectFiles? = nil,
        showsSavedTabsBeforeHostAnswers: Bool = false
    ) {
        self.showsSavedTabsBeforeHostAnswers = showsSavedTabsBeforeHostAnswers
        let runStartedAt = Self.appRunStartedAt
        // A project on another Mac (docs/specs/remote-devices.md) keeps its
        // key: no directory here.
        let location = ProjectLocation(key: projectRoot)
        let root: String
        let folder: String
        if location.isRemote {
            root = location.key
            folder = root
        } else {
            root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
            folder = Self.resolvedPath(root)
        }
        isRemote = location.isRemote
        repositoryRoot = root
        self.windowID = windowID
        workspaceRoot = folder
        self.remoteProject = location.isRemote ? remoteProject : nil
        self.remoteProjectFiles = remoteProjectFiles ?? (location.isRemote && remoteProject != nil ? .shared : nil)
        remoteProjectLoaded = !(location.isRemote && remoteProject != nil)
        self.backendPolicy = backendPolicy
        self.stateStore = stateStore
        self.sessionRestorer = sessionRestorer
        self.autoStartCommands = autoStartCommands
        self.restoredTabLaunchQueue = restoredTabLaunchQueue

        // Only tabs bound to a hosted session can come back, and, when local
        // tabs run in the host, tabs saved while their session's Create had
        // not answered; a window with none restores nothing, and its native
        // tabs are dropped. A file saved while Cherry had worktree spaces
        // can name several folders: their tabs all come back here.
        let mayAdoptUnbound = backendPolicy.localSessions != nil
        let savedState = stateStore?.load(repositoryRoot: root, windowID: windowID)
        if var record = savedState?.workspaceRecord(root: folder),
           mayAdoptUnbound
               ? record.hasRestorableSessions
               : record.sessions.contains(where: { $0.isRestorable || $0.systemEnd != nil }) {
            // Each record says when an open tab last saved it, so saving it
            // again unchanged (kept for later) keeps that.
            record.sessions = record.sessions.map { session in
                var session = session
                session.savedAt = session.savedAt ?? savedState?.savedAt
                return session
            }
            pendingRecord = record
        }
        isAwaitingInitialRestore = pendingRecord != nil
        if let stateStore, stateStore.isEnabled, let localSessions = backendPolicy.localSessions {
            let sessionsToEnd = stateStore.loadSessionsToEnd()
            // A file this version moved aside still says when it was saved
            // and which tabs it had.
            let setAside = savedState == nil ? stateStore.setAsideState(repositoryRoot: root, windowID: windowID) : nil
            orphanCriteria = windowID != nil && savedState == nil && setAside == nil
                // A window other than the project's primary that saved
                // nothing was opened this run (File › New Window): no
                // session was created for it before, so none is its orphan.
                ? nil
                : OrphanedSessionCriteria(
                    owner: localSessions.owner,
                    savedState: savedState,
                    setAside: setAside,
                    sessionsToEnd: sessionsToEnd,
                    createdBefore: runStartedAt,
                    host: localSessions.profile.host,
                    windowID: windowID
                )
            // As the window opened: ending them (`resumeEndingSessions`)
            // takes them out of the store once their sessions are gone.
            let toEndAtOpen = Set(sessionsToEnd.map(\.id))
            systemEnds = SystemEndedSessions(
                savedAt: savedState?.savedAt,
                bootTime: SystemEndedSessions.currentBootTime(),
                systemQuits: stateStore.loadSystemQuits(),
                endedOnPurpose: { record in
                    if toEndAtOpen.contains(record.id) { return true }
                    if let sessionID = record.hosted?.sessionID, localSessions.isEnding(sessionID) { return true }
                    return stateStore.wasEndedOnPurpose(record, fallbackSavedAt: savedState?.savedAt)
                },
                recordedLostSessions: { stateStore.lostSessions(hostID: $0) }
            )
        } else {
            orphanCriteria = nil
            systemEnds = nil
        }

        let workspace = TerminalWorkspace(
            projectRoot: folder,
            createInitialSession: pendingRecord == nil,
            backendPolicy: backendPolicy,
            windowID: windowID
        )
        workspace.restoredTabLaunchQueue = restoredTabLaunchQueue
        workspace.windowGrid = windowGrid
        self.workspace = workspace
        if !location.isRemote {
            // Its tabs name the folder with its links resolved: they use
            // the project's settings.
            AgentSettings.shared.registerProjectFolder(folder, projectRoot: root)
        }
        closeTabsAfterCleanExit()
        observePersistentState()
        observeRemoteTabs()
        if let hosting = remoteHosting {
            // A wake or a network change reconnects the device at once
            // (its restore may be waiting for it with no tab open yet).
            backendPolicy.hostReconnects?.startMonitoringSystem()
            // In use while this window is open, tabs or not.
            hosting.beginUse()
            usesRemoteHosting = true
        }
    }

    /// A device's window: follows whether it has tabs (`updateRemoteLease`).
    private func observeRemoteTabs() {
        guard isRemote else { return }
        remoteLeaseSubscription = workspace.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                // `$sessions` fires before the change.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.updateRemoteLease() }
                }
            }
    }

    /// Holds the device's control connection while this window has tabs
    /// (and is not torn down), releasing it otherwise.
    func updateRemoteLease() {
        guard let hosting = remoteHosting else { return }
        let hasTabs = !isTearingDown && !workspace.isTornDown && !workspace.sessions.isEmpty
        if hasTabs, remoteLease == nil {
            remoteLease = hosting.control.retain()
            // Wakes and network changes reconnect it at once.
            backendPolicy.hostReconnects?.startMonitoringSystem()
        } else if !hasTabs, let lease = remoteLease {
            lease.release()
            remoteLease = nil
        }
    }

    var repositoryName: String {
        let path = ProjectLocation.launchPath(forKey: repositoryRoot)
        return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    /// A project on another Mac (docs/specs/remote-devices.md): its tabs run
    /// there; its cherry.toml is read there (`remoteProject`), never on this
    /// Mac's disk.
    let isRemote: Bool

    /// How a device's window reaches that Mac for `project-info` (phase 3);
    /// nil for This Mac's projects, and for a device window without it (an
    /// unknown device: no commands).
    let remoteProject: RemoteProjectAccess?
    /// Where a device project's cherry.toml goes once read.
    private let remoteProjectFiles: RemoteProjectFiles?
    /// Whether the device project's `project-info` answered (or failed)
    /// once: its auto-start commands wait for it. True for This Mac's.
    @Published private(set) var remoteProjectLoaded: Bool
    /// What stands in the way of the device project's cherry.toml (an older
    /// session host there, a cherry.toml too large).
    @Published private(set) var remoteProjectNote: String?
    private var remoteProjectWaiters: [@MainActor () -> Void] = []

    /// The device's hosting when this is another Mac's project.
    /// Nil for a device Cherry no longer knows (its stand-in hosting holds
    /// no connection).
    var remoteHosting: PersistentHostSessions? {
        deviceHosting.flatMap { $0.profile.isKnownDevice ? $0 : nil }
    }

    /// A device window's hosting, known device or not (its bar says why
    /// its tabs wait).
    var deviceHosting: PersistentHostSessions? {
        guard isRemote, let hosting = backendPolicy.localSessions, !hosting.profile.isThisMac else { return nil }
        return hosting
    }

    /// Whether this window told its device's hosting it uses it.
    private var usesRemoteHosting = false

    /// Reads what a device's project is there (its cherry.toml); a project
    /// of This Mac has nothing to read.
    func refresh() async {
        guard isRemote else { return }
        await refreshRemoteProject()
    }

    /// A device's project (docs/specs/remote-devices.md, phase 3): one
    /// `cherry-host project-info` there says whether the folder exists and
    /// what its cherry.toml says. Auto-start commands wait for the first
    /// answer (`whenRemoteProjectLoaded`).
    private func refreshRemoteProject() async {
        guard let access = remoteProject, !isTearingDown else {
            finishRemoteProjectLoad()
            return
        }
        let rootPath = access.path(forKey: repositoryRoot)
        do {
            let report: RemoteProjectInfoReport
            do {
                report = try await access.projectInfo(paths: [rootPath])
            } catch RemoteProjectError.unreachable(let reason) {
                // Offline now: read it once the device's control connects,
                // and keep auto-start waiting for that answer.
                remoteProjectNote = "\(access.deviceName) could not be reached (\(reason)); its commands show once it is."
                refreshRemoteProjectOnConnection()
                return
            }
            // It answered: auto-start may run (with what it said, or none).
            defer { finishRemoteProjectLoad() }
            guard let info = report.project(at: rootPath) else {
                throw RemoteProjectError.invalid("\(access.deviceName) did not describe \(rootPath).")
            }
            remoteProjectFiles?.record(info, for: repositoryRoot)
            var notes: [String] = []
            if !info.isDirectory {
                notes.append("\(rootPath) is not a folder on \(access.deviceName).")
            }
            if let problem = info.cherryTomlProblem { notes.append("\(problem) on \(access.deviceName); its commands are not read.") }
            remoteProjectNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        } catch {
            remoteProjectNote = error.localizedDescription
        }
    }

    private var remoteProjectRetry: AnyCancellable?

    /// Refreshes the device's project once its control connects (a window
    /// that opened while it was offline).
    private func refreshRemoteProjectOnConnection() {
        guard remoteProjectRetry == nil, let hosting = deviceHosting else { return }
        remoteProjectRetry = hosting.control.$state
            .dropFirst()
            .filter { $0 == .connected }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.remoteProjectRetry = nil
                    guard let self, !self.isTearingDown else { return }
                    Task { await self.refresh() }
                }
            }
    }

    private func finishRemoteProjectLoad() {
        guard !remoteProjectLoaded else { return }
        remoteProjectLoaded = true
        let waiters = remoteProjectWaiters
        remoteProjectWaiters.removeAll()
        waiters.forEach { $0() }
    }

    /// Runs `action` once a device project's `project-info` answered (at
    /// once for This Mac's).
    private func whenRemoteProjectLoaded(perform action: @escaping @MainActor () -> Void) {
        guard !remoteProjectLoaded else {
            action()
            return
        }
        remoteProjectWaiters.append(action)
    }

    /// Closes the window's tabs. A teardown intent (window closed, app quit,
    /// duplicate window) stops workspace persistence first, so the file
    /// keeps the tabs saved before it.
    func closeAllSessions(intent: SessionCloseIntent = .windowClosed) {
        closeAllSessions(intent: intent) { $0.closeAllSessions(intent: intent) }
    }

    /// A confirmed quit's teardown (`ProjectWindowRegistry.tearDownForQuit`):
    /// as `closeAllSessions`, but tabs that only detach are left to the
    /// app's exit (`TerminalWorkspace.closeSessionsForQuit`). Returns whether
    /// a native tab's busy program was stopped.
    func closeSessionsForQuit(intent: SessionCloseIntent) -> Bool {
        var stoppedNativeProgram = false
        closeAllSessions(intent: intent) { workspace in
            stoppedNativeProgram = workspace.closeSessionsForQuit(intent: intent)
        }
        return stoppedNativeProgram
    }

    private func closeAllSessions(intent: SessionCloseIntent, closing close: (TerminalWorkspace) -> Void) {
        if intent.isAppQuit {
            // A copy of the app launched while this quit waits for sessions
            // to end waits for this one instead of running without its
            // saved tabs.
            stateStore?.noteAppQuitting()
        }
        if intent.endsLocalSessions {
            endSavedSessionsNotOpen()
        }
        if intent.tearsDownWorkspace {
            isTearingDown = true
            pendingStateSaveTask?.cancel()
            pendingStateSaveTask = nil
            restoreTask?.cancel()
            restoreWaiters.removeAll()
            restoreRetry = nil
            remoteProjectRetry = nil
            remoteProjectWaiters.removeAll()
            autoStartsWaitingForRetry.removeAll()
            orphanScanTask?.cancel()
            orphanScanTask = nil
            orphanScanRetry = nil
            settleInitialRestore()
        }
        close(workspace)
        if intent.tearsDownWorkspace {
            remoteLeaseSubscription = nil
            remoteLease?.release()
            remoteLease = nil
            if usesRemoteHosting {
                usesRemoteHosting = false
                remoteHosting?.endUse()
            }
            // After the workspace closed: restores under way end the tabs
            // they built with the same intent, and build no more.
            let cancellations = restoreCancellations
            restoreCancellations.removeAll()
            cancellations.forEach { $0.cancel() }
        }
    }

    /// What closing the window's tabs for `teardown` would do
    /// (`TerminalWorkspace.teardownSummary`). A quit names each session's
    /// project.
    func teardownSummary(
        _ teardown: SessionTeardown,
        pathDisplayMode: SidebarTerminalPathDisplayMode
    ) -> SessionTeardownSummary {
        var summary = SessionTeardownSummary()
        if !workspace.sessions.isEmpty {
            let place: String? = switch teardown {
            case .quit: repositoryName
            case .windowClose: nil
            }
            summary = summary + workspace.teardownSummary(teardown, place: place, pathDisplayMode: pathDisplayMode)
        }
        summary.savedSessionsNotOpen = savedRecordsWhoseSessionsEndWithTheWindow().count
        return summary
    }

    /// Whether one of the window's tabs is the tab `sessionID`.
    func contains(sessionID: UUID) -> Bool {
        workspace.sessions.contains { $0.id == sessionID }
    }

    /// A terminal tab whose shell exited cleanly closes as ⌘W closes it: on
    /// the window's last tab, the window closes too. The window is the one
    /// this repository's chrome state belongs to (the window that claimed
    /// the project, in the registry it registered with), never another
    /// window of the same project.
    private func closeTabsAfterCleanExit() {
        workspace.closeTabAfterCleanExit = { [weak self] workspace, session in
            guard let self, !self.isTearingDown else { return }
            SessionCloseCoordinator.closeTabAfterCleanExit(
                session,
                in: workspace,
                window: self.chromeState.flatMap { self.windowRegistry?.window(for: $0) }
            )
        }
    }

    /// Starts the project's auto-start commands once its saved tabs are
    /// restored, skipping commands a restored tab already runs. Nothing
    /// starts before the window claimed its project (a refused window never
    /// starts any), and only in the window that opened it (`opensProject`):
    /// a project's commands run once across its windows.
    func autoStartInitialCommandsIfNeeded() {
        guard !didAutoStart else { return }
        guard didBeginRestore else {
            autoStartAwaitsClaim = true
            return
        }
        didAutoStart = true
        guard opensProject else { return }
        whenRestored { [weak self] in
            guard let self else { return }
            let start: @MainActor () -> Void = { [weak self] in
                // A device's commands are known once its cherry.toml was read.
                self?.whenRemoteProjectLoaded { [weak self] in
                    self?.startAutoStartCommands()
                }
            }
            // At launch, once the project's other launch windows registered
            // and began restoring: at once when none of them is still to
            // open.
            if let windowRegistry {
                windowRegistry.whenLaunchWindowsOpened(ofProjectOf: self, start)
            } else {
                start()
            }
        }
    }

    /// `addCommandSession` returns the existing tab for a command that is
    /// already open, restored ones included, in any window of the project,
    /// so nothing starts twice. A restored command tab whose session ended
    /// while Cherry was closed starts again, in whichever window it came
    /// back: auto-start commands run when their project opens. A command
    /// whose saved tab is still being restored in any window of the project
    /// (its host answers late), or was kept because its host could not be
    /// reached, waits for that tab to come back during this run
    /// (`startAutoStartsNoLongerWaiting`) instead of starting a second copy
    /// beside the one that may still run. So does one whose tab is shown
    /// before its host answered (`TerminalSession.isProvisionalRestore`,
    /// another launch window's, or one of this window's a second look
    /// decides): that tab may come back ended, or not at all.
    private func startAutoStartCommands(_ commands: [ProjectCommandDefinition]? = nil) {
        guard !isTearingDown else { return }
        let root = workspace.projectRoot ?? workspaceRoot
        let waitingNames = commandNamesAutoStartWaitsFor()
        for command in commands ?? autoStartCommands(root) {
            if waitingNames.contains(AgentToolDefinition.normalizedName(command.name)),
               workspace.projectCommandSession(named: command.name)?.isProvisionalRestore ?? true {
                autoStartsWaitingForRetry.append(command)
                continue
            }
            let session = workspace.addCommandSession(command: command, projectRoot: root, select: false)
            if session.kind == .command, session.hostedAttachment == nil, !session.isRunning {
                session.restartManagedCommandIfNeeded()
            }
        }
    }

    // MARK: Workspace persistence

    /// Called once the window owns this project (never for a duplicate
    /// window): restores saved tabs and starts saving. `chromeState` supplies
    /// the collapsed agent groups.
    func beginRestoringSavedStateIfNeeded(chromeState: ProjectWindowChromeState?) {
        if let chromeState, self.chromeState !== chromeState {
            self.chromeState = chromeState
            chromeStateSubscription = stateStore == nil ? nil : chromeState.$collapsedAgentGroupIDs
                .dropFirst()
                .sink { [weak self] _ in self?.scheduleStateSave() }
        }
        guard !didBeginRestore, !isTearingDown else { return }
        didBeginRestore = true
        // A project's commands run in one tab across its windows.
        workspace.otherProjectWindows = { [weak self] in
            self.flatMap { $0.windowRegistry?.otherWorkspaces(ofProjectOf: $0) } ?? []
        }
        restoreSavedTabsIfNeeded()
        scanForOrphanedSessions()
        // Sessions of saved tabs that an earlier run could not end before
        // it quit (once per run).
        if let stateStore, let localSessions = backendPolicy.localSessions {
            localSessions.resumeEndingSessions(recordedIn: stateStore)
        }
        if windowID != nil, pendingRecord == nil {
            // A window other than the project's primary, with nothing to
            // restore, is saved at once (the registry saved it as open), so
            // a crash before its first change still reopens it. The
            // primary saves at its first change, as a project's one window
            // did.
            saveStateSoon()
        }
        if autoStartAwaitsClaim {
            autoStartAwaitsClaim = false
            // On the next turn: the window claims its project from inside
            // a SwiftUI view update, where adding tabs is not allowed.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.autoStartInitialCommandsIfNeeded() }
            }
        }
    }

    /// Saved tabs that are not open tabs: not restored yet, still being
    /// restored, kept for later or set aside.
    private func savedRecordsNotOpen() -> [WorkspaceSessionRecord] {
        var seen = Set<UUID>()
        return ((pendingRecord?.sessions ?? []) + (keptRecord?.sessions ?? []))
            .filter { seen.insert($0.id).inserted }
    }

    /// Saved tabs of this window that a restore may still bring back: not
    /// restored yet, still being restored, or kept while their host could
    /// not be listed. Their sessions are not in the background
    /// (`BackgroundSessions`). Set-aside tabs are not among them: their
    /// sessions run unseen until the next launch.
    func savedRecordsAwaitingRestore() -> [WorkspaceSessionRecord] {
        guard !isTearingDown else { return [] }
        return savedRecordsNotOpen().filter { !setAsideRecordIDs.contains($0.id) }
    }

    /// Whether a restore (or a late host's part of one) or a look for
    /// orphaned sessions is under way.
    var isRestoringSessions: Bool {
        restoreTask != nil || !restoreRemainders.isEmpty || orphanScanTask != nil
    }

    /// Waits until no restore or look for orphaned sessions is under way, or
    /// until `deadline`: what a window brings back by itself is not taken for
    /// a session in the background.
    func waitUntilSessionsRestored(before deadline: ContinuousClock.Instant) async {
        while isRestoringSessions, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Shows a session of this app that no open tab shows (Background
    /// Sessions → Open) in the window, and selects its tab:
    /// - the tab of this window that owns it already (its window's restore
    ///   brought it back);
    /// - a session this window may own (`canAdopt`) becomes its tab, with
    ///   the kind, agent, command and tab id its tags name, the way an
    ///   orphaned session is adopted: when a tab of the window runs the
    ///   same command, it is set aside (saved, still running) and that
    ///   command's tab is shown instead;
    /// - any other session (another client shows it) is attached.
    @discardableResult
    func showBackgroundSession(
        _ launch: PersistentSessionLaunch,
        hosting: PersistentLocalSessions
    ) -> TerminalSession? {
        guard !isTearingDown, !workspace.isTornDown else { return nil }
        let info = launch.info
        if let owner = hosting.owningTab(of: info.id), contains(sessionID: owner.id) {
            workspace.select(owner)
            return owner
        }
        guard hosting.canAdopt(info) else {
            return workspace.attachHostedSession(launch.attachment, info: info)
        }
        let tabID = PersistentLocalSessions.tabID(of: info, owner: hosting.owner).flatMap { id in
            hosting.hasOpenTab(withID: id) || OpenHostedTabs.shared.hasOpenTab(withID: id)
                || workspace.session(withID: id) != nil ? nil : id
        } ?? UUID()
        let record = OrphanedSessionCriteria.record(
            for: info, tabID: tabID, hostID: launch.attachment.hostID, host: launch.attachment.host
        )
        let tab = workspace.makeRestoredPersistentSession(launch, record: record, hosting: hosting, deferringLaunch: true)
        applyRestoreStep(
            asked: [],
            result: WorkspaceRestoreResult(sessions: [tab]),
            layout: WorktreeStateRecord(root: workspaceRoot, sessions: [record]),
            step: .orphans
        )
        let shown = workspace.session(withID: tab.id).flatMap { $0 === tab ? $0 : nil }
            ?? record.commandName.flatMap { workspace.commandSession(named: $0) }
        if let shown { workspace.select(shown) }
        return shown
    }

    /// A window close or quit that ends sessions (End Sessions, or
    /// Settings › Sessions) also ends the sessions of this window's saved
    /// tabs that no open tab shows: still being restored, kept while their
    /// host was unavailable, set aside, or not restored yet. Only sessions
    /// this app created for those tabs; they are recorded as sessions to
    /// end, so what this run cannot end (it quits first) is ended at the
    /// next launch. The saved tabs themselves stay: the next restore drops
    /// them once their sessions are gone.
    private func endSavedSessionsNotOpen() {
        let records = savedRecordsWhoseSessionsEndWithTheWindow()
        guard let localSessions = backendPolicy.localSessions, !records.isEmpty else { return }
        localSessions.endSessions(ofForgottenTabs: records, recordedIn: stateStore)
    }

    /// The sessions of This Mac a quit that ends sessions ends in this
    /// window (End Sessions, *on quit* = End Sessions): its persistent tabs'
    /// and those of its saved tabs no open tab shows. A log out, restart or
    /// shut down records them as ended on purpose while *on quit* is End
    /// Sessions (`CherryAppDelegate.recordSystemQuit`), so their tabs do
    /// not come back, as after ⌘Q.
    func localSessionsEndedByAQuit() -> [(hostID: String, sessionID: String)] {
        guard !isTearingDown else { return [] }
        // Open persistent tabs of any host (a device's too): recorded by
        // host identity, so This Mac's and each device's stay apart.
        let open = workspace.sessions.compactMap { tab -> (hostID: String, sessionID: String)? in
            guard tab.isPersistentLocalSession, let binding = tab.persistentSession else { return nil }
            return (binding.hostID, binding.sessionID)
        }
        let saved = savedRecordsWhoseSessionsEndWithTheWindow().compactMap { record in
            record.hosted.map { (hostID: $0.hostID, sessionID: $0.sessionID) }
        }
        return open + saved
    }

    /// The saved tabs no open tab shows that may own a session of This Mac
    /// (`endSavedSessionsNotOpen`).
    private func savedRecordsWhoseSessionsEndWithTheWindow() -> [WorkspaceSessionRecord] {
        guard let hosting = backendPolicy.localSessions else { return [] }
        let host = hosting.profile.host
        return savedRecordsNotOpen().filter { $0.mayOwnSession(on: host) }
    }

    // MARK: Orphaned sessions

    /// Looks once for this app's sessions no saved tab names
    /// (`OrphanedSessionCriteria`: a tab whose record was never saved
    /// because the app crashed right after opening it, or whose record was
    /// lost) that were started in this project, and adopts them as tabs
    /// after the tabs open. Only when local tabs run as persistent sessions
    /// and this copy of the app owns them; when the host cannot be listed,
    /// again once it can.
    private func scanForOrphanedSessions() {
        guard didBeginRestore, !isTearingDown, !didScanForOrphans, orphanScanTask == nil, orphanScanRetry == nil,
              let criteria = orphanCriteria,
              let localSessions = backendPolicy.localSessions,
              // Only This Mac's: the criteria compare sessions' creation
              // times with this Mac's clock, which says nothing of another
              // Mac's. A device window lists its unshown sessions under
              // Not open here instead.
              localSessions.profile.isThisMac,
              backendPolicy.prefersPersistentLocalSessions,
              localSessions.installationProblem() == nil
        else { return }
        let generation = localSessions.connectionGeneration
        orphanScanTask = Task { @MainActor [weak self] in
            let list = try? await localSessions.completeList()
            guard let self, !Task.isCancelled, !isTearingDown else { return }
            orphanScanTask = nil
            guard let list else {
                retryOrphanScan(when: localSessions.hostAvailability(after: generation))
                return
            }
            adoptOrphanedSessions(in: list, criteria: criteria, localSessions: localSessions)
            if list.awaitsHolders {
                // A restarted daemon lists a session only once its holder
                // registered: look again once none is expected.
                retryOrphanScan(when: localSessions.control.holdersRegistered())
            }
        }
    }

    /// Scans for orphaned sessions again once `trigger` fires.
    private func retryOrphanScan(when trigger: AnyPublisher<Void, Never>) {
        orphanScanRetry = trigger
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.orphanScanRetry = nil
                    self?.scanForOrphanedSessions()
                }
            }
    }

    private func adoptOrphanedSessions(
        in list: HostedSessionList,
        criteria: OrphanedSessionCriteria,
        localSessions: PersistentLocalSessions
    ) {
        // Scanned for good only from a list that is complete.
        if !list.awaitsHolders { didScanForOrphans = true }
        // A saved tab of another window names it (one of the launch's
        // windows still to open, or one restoring): that window brings it
        // back, whatever its window tag says. The criteria read only this
        // window's file.
        lazy var awaitingRestore = windowRegistry?.sessionRecordsAwaitingRestore() ?? []
        var orphans: [(info: HostedSessionInfo, record: WorkspaceSessionRecord)] = []
        for info in list.sessions {
            guard let tabID = criteria.orphanTabID(of: info),
                  localSessions.owningTab(of: info.id) == nil,
                  !awaitingRestore.contains(where: { record in
                      PersistentLocalSessions.record(
                          record, names: info, hostID: list.hostID, owner: localSessions.owner,
                          host: localSessions.profile.host, includingAttached: true
                      )
                  }),
                  !localSessions.isEnding(info.id),
                  !localSessions.isScheduledToEnd(info, hostID: list.hostID),
                  !localSessions.hasOpenTab(withID: tabID),
                  !OpenHostedTabs.shared.hasOpenTab(withID: tabID),
                  let project = OrphanedSessionCriteria.projectRoot(of: info),
                  names(project)
            else { continue }
            orphans.append((info, OrphanedSessionCriteria.record(
                for: info, tabID: tabID, hostID: list.hostID, host: localSessions.profile.host
            )))
        }
        let listing = localSessions.listing(of: list)
        if backendPolicy.settings().closeTabsOnCleanExit {
            // A terminal whose shell exited with status 0 would have closed
            // its tab: its ended session is removed instead of adopted.
            let ended = orphans.filter { $0.record.kind == .terminal && PersistentLocalSessions.endedCleanly($0.info) }
            ended.forEach { localSessions.end(listing.attachment($0.info)) }
            orphans.removeAll { orphan in ended.contains { $0.info.id == orphan.info.id } }
        }
        guard !orphans.isEmpty, !workspace.isTornDown else { return }
        let tabs = orphans.map { orphan in
            workspace.makeRestoredPersistentSession(
                PersistentSessionLaunch(attachment: listing.attachment(orphan.info), info: orphan.info),
                record: orphan.record,
                hosting: localSessions,
                deferringLaunch: true
            )
        }
        fputs("Cherry: \(tabs.count) session(s) of this app that no saved tab named came back as tabs of \(workspaceRoot)\n", stderr)
        applyRestoreStep(
            asked: [],
            result: WorkspaceRestoreResult(sessions: tabs),
            layout: WorktreeStateRecord(root: workspaceRoot, sessions: orphans.map(\.record)),
            step: .orphans
        )
    }

    /// Whether a tab's project root names this window's folder.
    private func names(_ project: String) -> Bool {
        // A device's session names its project by key.
        if ProjectLocation.isRemoteKey(project) {
            return ProjectLocation(key: project).key == workspaceRoot
        }
        let standardized = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.path
        return [project, standardized, Self.resolvedPath(standardized)].contains(workspaceRoot)
    }

    /// Waits for every restore that has started, their remainders included.
    func waitForPendingRestores() async {
        while true {
            if let task = restoreTask {
                await task.value
            } else if let task = restoreRemainders.values.first {
                await task.value
            } else {
                return
            }
        }
    }

    /// Saves now, synchronously. Quit and window close call it before their
    /// teardown, which saves nothing.
    func flushPersistentState() {
        pendingStateSaveTask?.cancel()
        pendingStateSaveTask = nil
        saveState(synchronously: true)
    }

    /// The saved form of the window's tabs: the live workspace with the
    /// tabs its restore kept for later, or the saved tabs unchanged while
    /// their restore has not finished.
    func makeStateRecord() -> RepositoryStateRecord {
        let now = Date()
        var record = pendingRecord
        if record == nil, !workspace.isTornDown, !workspace.sessions.isEmpty {
            var live = workspace.makeStateRecord(
                root: workspaceRoot,
                collapsedAgentGroupIDs: chromeState?.collapsedAgentGroupIDs ?? collapsedAgentGroupIDsWithoutChrome
            )
            // Open tabs: saved now. Kept ones below keep their time.
            live.sessions = live.sessions.map { session in
                var session = session
                session.savedAt = now
                return session
            }
            record = live
        }
        if pendingRecord == nil, let keptRecord {
            record = record?.merging(kept: keptRecord) ?? keptRecord
        }
        return RepositoryStateRecord(
            repositoryRoot: repositoryRoot,
            activeWorktreeRoot: workspaceRoot,
            worktrees: record.map { [$0] } ?? [],
            savedAt: now,
            windowID: windowID
        )
    }

    private static let stateSaveDelay: Duration = .milliseconds(500)

    private var canSaveState: Bool {
        stateStore != nil
            && didBeginRestore
            && !isTearingDown
            && !workspace.isTornDown
    }

    private func observePersistentState() {
        guard stateStore != nil else { return }
        // A new persistent tab is saved at once, not after the usual delay:
        // its session is being created now, and a record saved later would
        // be missing if the app ended in between.
        let addedTabs = workspace.$sessions.dropFirst()
            .compactMap { [weak workspace] sessions -> Void? in
                guard let workspace else { return nil }
                let open = Set(workspace.sessions.map(\.id))
                return sessions.contains { !open.contains($0.id) && $0.isPersistentLocalSession } ? () : nil
            }
            .sink { [weak self, weak workspace] in
                guard let self, let workspace, !workspace.isTornDown else { return }
                // `$sessions` fires before the change: save on the next turn.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.saveStateSoon() }
                }
            }
        let changes: [AnyPublisher<Void, Never>] = [
            workspace.$sessions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$terminalDisplayItems.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$terminalSplitGroups.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.$selectedSessionID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            workspace.persistentStateChanges.eraseToAnyPublisher()
        ]
        let debounced = Publishers.MergeMany(changes)
            .sink { [weak self, weak workspace] in
                guard let self, let workspace, !workspace.isTornDown else { return }
                self.scheduleStateSave()
            }
        persistenceSubscription = AnyCancellable {
            addedTabs.cancel()
            debounced.cancel()
        }
    }

    /// Saves now (written in the background) instead of after the delay.
    private func saveStateSoon() {
        guard canSaveState else { return }
        pendingStateSaveTask?.cancel()
        pendingStateSaveTask = nil
        saveState(synchronously: false)
    }

    private func scheduleStateSave() {
        guard canSaveState else { return }
        pendingStateSaveTask?.cancel()
        pendingStateSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stateSaveDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingStateSaveTask = nil
            self.saveState(synchronously: false)
        }
    }

    private func saveState(synchronously: Bool) {
        guard canSaveState, let stateStore else { return }
        let state = makeStateRecord()
        if synchronously {
            stateStore.saveSynchronously(state)
        } else {
            stateStore.save(state)
        }
    }

    private func restoreSavedTabsIfNeeded() {
        guard didBeginRestore,
              !isTearingDown,
              restoreTask == nil,
              let record = pendingRecord
        else {
            return
        }
        let workspace = workspace
        // A local tab saved before its session's Create answered has no
        // binding; the local host may still run its session (tagged with
        // its tab id). Only asked when local tabs run as sessions.
        let mayAdoptUnbound = backendPolicy.localSessions != nil && backendPolicy.prefersPersistentLocalSessions
        // Tabs saved ended by the system come back ended whatever the
        // settings.
        let request = WorkspaceRestoreRequest(
            repositoryRoot: repositoryRoot,
            records: record.sessions.filter(\.isRestorable),
            workspace: workspace,
            unboundRecords: record.sessions.filter { !$0.isRestorable && (mayAdoptUnbound || $0.systemEnd != nil) },
            systemEnds: systemEnds
        )
        let asked = Set((request.records + request.unboundRecords).map(\.id))
        let restorer = sessionRestorer
        restoreCancellations.append(request.cancellation)
        restoreTaskRecordIDs = asked
        let name = URL(fileURLWithPath: workspaceRoot).lastPathComponent
        LaunchTimeline.mark("restore began \(name) records=\(asked.count)")
        let showsBeforeHostAnswers = showsSavedTabsBeforeHostAnswers
        restoreTask = Task { @MainActor [weak self] in
            var request = request
            if showsBeforeHostAnswers, let self, !request.cancellation.isCancelled {
                // On this turn, not in the SwiftUI update that registered
                // the window.
                request.optimisticTabs = self.showOptimisticTabs(record: record, records: request.records)
            }
            let result = await restorer(request)
            LaunchTimeline.mark("restore answered \(name) tabs=\(result.sessions.count) pending=\(result.pendingRecordIDs.count)")
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.finishRestoring(record: record, asked: asked, result: result)
        }
        updateCommandsBeingRestored()
    }

    private func finishRestoring(
        record: WorktreeStateRecord,
        asked: Set<UUID>,
        result: WorkspaceRestoreResult
    ) {
        restoreTask = nil
        restoreTaskRecordIDs = []
        // Whatever happens next, the window waits for nothing more.
        defer { settleInitialRestore() }
        guard !isTearingDown else {
            // The window closed or the app quit meanwhile: end these tabs
            // the way that close ended the others.
            WorkspaceRestoreResult.discard(result, in: workspace)
            return
        }
        pendingRecord = nil
        // Every record asked for stays saved until the restore answers for it.
        keptRecord = record.restricted(to: asked)
        applyRestoreStep(asked: asked, result: result, layout: record, step: .initial)
    }

    /// Shows, before This Mac's host answers, the saved persistent tabs
    /// whose sessions probably still run (`OptimisticRestore`), with the
    /// saved layout and selection: the window comes on screen with them,
    /// and the selected one's adapter starts attaching at once. The restore
    /// then confirms each tab (the host lists its session as the record's)
    /// or withdraws it (`reconcileOptimisticTabs`).
    private func showOptimisticTabs(
        record: WorktreeStateRecord,
        records: [WorkspaceSessionRecord]
    ) -> [UUID: TerminalSession] {
        guard !isTearingDown,
              let localSessions = backendPolicy.localSessions, let systemEnds,
              localSessions.profile.isThisMac, localSessions.installationProblem() == nil
        else { return [:] }
        let environment = HostedSessionLoginEnvironment.shared.availableNow()?.environment
        var built: [TerminalSession] = []
        for saved in OptimisticRestore.records(records, localSessions: localSessions, systemEnds: systemEnds) {
            guard let binding = saved.hosted,
                  let attachment = localSessions.attachmentWithoutListing(
                      binding, name: saved.title, loginEnvironment: environment
                  )
            else { continue }
            let tab = workspace.makeRestoredPersistentSession(
                PersistentSessionLaunch(
                    attachment: attachment,
                    info: OptimisticRestore.assumedInfo(of: saved, binding: binding, owner: localSessions.owner)
                ),
                record: saved,
                hosting: localSessions,
                deferringLaunch: true,
                provisional: true
            )
            built.append(tab)
        }
        guard !built.isEmpty else { return [:] }
        workspace.restoreSessions(built, from: record, selectingSavedTab: true, addingAfterOpenTabs: false)
        let shown = built.filter { tab in tab.isProvisionalRestore && workspace.sessions.contains { $0 === tab } }
        guard !shown.isEmpty else { return [:] }
        optimisticSelection = SelectionMark(selection: workspace.selectedSessionID)
        let name = URL(fileURLWithPath: workspaceRoot).lastPathComponent
        LaunchTimeline.mark("restore shown before the host answered \(name) tabs=\(shown.count)")
        // The window shows once its saved selection is among them (else it
        // waits for the answer, as before).
        if record.selectedSessionID.map({ id in shown.contains { $0.id == id } }) ?? true {
            settleInitialRestore()
        }
        let tabs = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        optimisticTabs = tabs
        workspace.awaitsRestoreDecision = { [weak self] id in self?.optimisticTabs[id] != nil }
        return tabs
    }

    /// What a restore step decided for the tabs shown before the host
    /// answered, by record id: only tabs still provisional are the
    /// restore's (one the user restarted, or closed, meanwhile is theirs;
    /// one ⌘Z brought back is provisional again). Those it confirmed stay;
    /// those still pending stay until their remainder answers; the step's
    /// own tab for a record (an ended tab, or another session's) takes the
    /// provisional tab's place; any other provisional tab is withdrawn (a
    /// record kept for later stays saved, a dropped one goes). Their
    /// sessions are left as they are. Returns the tabs to add with the
    /// saved layout: for the step that opens the workspace, the kept tabs
    /// of the saved records too (taken out and laid out again with the
    /// others, in the saved order, splits and selection); for a later
    /// step, a replacement goes in its provisional tab's place instead.
    /// Also whether the step may select the saved tab (nobody changed the
    /// selection since they were shown; nil when none was shown).
    private func reconcileOptimisticTabs(
        asked: Set<UUID>,
        result: WorkspaceRestoreResult,
        layout: WorktreeStateRecord,
        step: RestoreStep
    ) -> (tabs: [TerminalSession], selectsSavedTab: Bool?) {
        guard !optimisticTabs.isEmpty else { return (result.sessions, nil) }
        var shown = optimisticTabs
        let pending = result.pendingRecordIDs.intersection(asked)
        let decided = Set(shown.keys).intersection(asked).subtracting(pending)
        var remaining = result.sessions
        var withdrawn: [TerminalSession] = []
        // Before anything is withdrawn (which moves the selection).
        let selectsSavedTab = optimisticSelection.map { $0.selection == workspace.selectedSessionID }
        for id in decided.sorted(by: { $0.uuidString < $1.uuidString }) {
            shown.removeValue(forKey: id)
            guard !result.confirmedOptimisticRecordIDs.contains(id),
                  let tab = workspace.session(withID: id), tab.isProvisionalRestore
            else { continue }
            if step != .initial, let index = remaining.firstIndex(where: { $0.id == id }),
               workspace.replaceRestoredTab(tab, with: remaining[index]) {
                remaining.remove(at: index)
            } else {
                withdrawn.append(tab)
            }
        }
        if !withdrawn.isEmpty {
            workspace.withdrawRestoredTabs(withdrawn)
        }
        optimisticTabs = shown
        if shown.isEmpty { optimisticSelection = nil }
        guard step == .initial else { return (remaining, selectsSavedTab) }
        // Laid out again with the step's tabs: every open tab of a saved
        // record (shown early, confirmed or pending, restarted, or brought
        // back), in the saved order.
        let savedIDs = Set(layout.sessions.map(\.id))
        let incoming = Set(remaining.map(\.id))
        let kept = workspace.sessions.filter { savedIDs.contains($0.id) && !incoming.contains($0.id) }
        workspace.takeOutForLayout(kept)
        return (kept + remaining, selectsSavedTab)
    }

    /// Runs `body` once the restore that opens the window has put its tabs,
    /// layout and selection in place (or the window was torn down first):
    /// at once when there is nothing to wait for. Hosts that did not answer
    /// within the restore's initial wait come back later, into the window
    /// already shown.
    func whenInitialRestoreSettles(_ body: @escaping @MainActor () -> Void) {
        guard isAwaitingInitialRestore else {
            body()
            return
        }
        initialRestoreWaiters.append(body)
    }

    private func settleInitialRestore() {
        guard isAwaitingInitialRestore else { return }
        isAwaitingInitialRestore = false
        let waiters = initialRestoreWaiters
        initialRestoreWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private enum RestoreStep: Equatable {
        /// The restore that opens the workspace.
        case initial
        /// Hosts of that restore that answered late.
        case remainder
        /// Kept records restored again when their host came up, and the
        /// hosts of that retry that answered late.
        case retry
        /// Sessions of this app that no saved tab named, adopted as tabs
        /// (`scanForOrphanedSessions`).
        case orphans
    }

    /// Adds what one restore step brought back to the workspace, with the
    /// saved `layout`, and updates the records still kept: those the step
    /// brought back or dropped go, those it kept or set aside stay, and
    /// those still pending stay in flight until its remainder answers.
    private func applyRestoreStep(
        asked: Set<UUID>,
        result: WorkspaceRestoreResult,
        layout: WorktreeStateRecord,
        step: RestoreStep
    ) {
        let selectingSavedTab: Bool = switch step {
        case .initial: true
        // Tabs that come late take the saved selection only while nobody
        // changed the selection since the first ones came.
        case .remainder: selectionAwaitingRestore.map { $0.selection == workspace.selectedSessionID } ?? false
        case .retry, .orphans: false
        }
        // What a late part of this step is: a retry's stays a retry.
        let laterStep: RestoreStep = step == .retry ? .retry : .remainder
        let reconciled = reconcileOptimisticTabs(asked: asked, result: result, layout: layout, step: step)
        let setAside = workspace.restoreSessions(
            reconciled.tabs,
            from: layout,
            selectingSavedTab: reconciled.selectsSavedTab ?? selectingSavedTab,
            addingAfterOpenTabs: step != .initial
        )
        let pending = result.pendingRecordIDs.intersection(asked)
        updateKeptRecords(
            asked: asked,
            kept: result.keptRecordIDs.intersection(asked).union(setAside).subtracting(pending),
            pending: pending,
            setAside: setAside
        )
        if step == .orphans, !setAside.isEmpty {
            // An adopted command whose command a tab runs already: saved,
            // set aside, so its session does not run on with no record.
            let aside = layout.restricted(to: setAside)
            keptRecord = keptRecord?.merging(kept: aside) ?? aside
            setAsideRecordIDs.formUnion(setAside)
        }
        if step == .retry || step == .orphans {
            // Only the restore that opened the workspace applies the saved
            // selection and the default shell.
        } else if inFlightRecordIDs.isEmpty {
            selectionAwaitingRestore = nil
            // The window's default shell, once nothing more is coming. After
            // a remainder, auto-start may have added commands meanwhile.
            // A device's window whose saved tabs wait for the device to
            // answer opens no new tab there meanwhile (it could not start
            // either): they come back once it answers.
            let waitsForDevice = isRemote && !(keptRecord?.sessions.isEmpty ?? true)
            if !waitsForDevice {
                switch step {
                case .initial: workspace.addInitialSessionIfEmpty()
                case .remainder: workspace.addInitialSessionIfEmpty(ignoringCommands: true)
                case .retry, .orphans: break
                }
            }
        } else {
            selectionAwaitingRestore = SelectionMark(selection: workspace.selectedSessionID)
        }
        applyCollapsedAgentGroupIDs(layout.collapsedAgentGroupIDs)
        if let remainder = result.remainder, !pending.isEmpty {
            awaitRemainder(remainder, asked: pending, layout: layout, step: laterStep)
        }
        if restoreRetry == nil, let trigger = result.retryWhenAvailable, !recordIDsToRetry().isEmpty {
            retryKeptRecords(when: trigger)
        }
        updateCommandsBeingRestored()
        autoStartsMayNoLongerWait()
        // Adopted sessions never finish a restore: those waiting for the
        // window's saved tabs go on waiting.
        if step == .initial || (step != .orphans && restoreTask == nil) {
            runRestoreWaiters()
        }
        // Tabs whose sessions the system ended, found now (not saved ended),
        // once auto-start (the waiters above) started its commands again.
        let savedEnded = Set(layout.sessions.filter { $0.systemEnd != nil }.map(\.id))
        announceSystemEndedTabs(result.sessions.filter { tab in
            !savedEnded.contains(tab.id) && workspace.session(withID: tab.id) === tab
        })
        scheduleStateSave()
    }

    /// Says in the window's toast that `tabs` came back ended because the
    /// system ended their sessions ("3 tabs ended when the Mac restarted",
    /// with Restart All), with those an earlier step of this run brought
    /// back still ended. Once per run for each tab: tabs saved ended come
    /// back without a toast.
    /// Not a tab that starts again by itself: one auto-start started (or
    /// will), a command that restarts when it exits, or one whose program
    /// had exited before (it shows that exit, and Restart All leaves it).
    private func announceSystemEndedTabs(_ candidates: [TerminalSession]) {
        var autoStarted: Set<String>?
        let tabs = candidates.filter { tab in
            guard tab.systemSessionEnd != nil, !tab.isRunning, tab.savedExitStatus == nil else { return false }
            guard tab.kind == .command else { return true }
            guard !tab.restartOnExit, let name = tab.commandName else { return !tab.restartOnExit }
            let names = autoStarted ?? Set(autoStartCommands(workspaceRoot).map { AgentToolDefinition.normalizedName($0.name) })
            autoStarted = names
            return !names.contains(AgentToolDefinition.normalizedName(name))
        }
        guard !tabs.isEmpty, let chromeState else { return }
        systemEndedTabs = systemEndedTabs.filter { $0.object?.systemSessionEnd != nil && $0.object?.isRunning == false }
            + tabs.map { WeakReference($0) }
        let ended = systemEndedTabs.compactMap(\.object)
        guard let end = ended.first?.systemSessionEnd else { return }
        let machine = ended.first?.persistentHosting.flatMap { $0.profile.isThisMac ? nil : $0.profile.displayName }
        chromeState.toasts.show(ProjectWindowToast.systemEndedTabs(count: ended.count, end: end, machine: machine) { [weak self] in
            self?.restartSystemEndedTabs()
        })
    }

    /// Restart All: starts again every tab of this window whose session the
    /// system ended that its toast named and that is still ended.
    func restartSystemEndedTabs() {
        guard !isTearingDown else { return }
        for tab in systemEndedTabs.compactMap(\.object)
        where tab.systemSessionEnd != nil && !tab.isRunning && tab.savedExitStatus == nil {
            guard workspace.session(withID: tab.id) === tab else { continue }
            workspace.restart(tab)
        }
        systemEndedTabs.removeAll()
    }

    /// `keptRecord` after a restore step that asked for `asked`: of those,
    /// the ones it kept (or set aside) and the ones still pending stay; the
    /// others (restored or dropped) go.
    private func updateKeptRecords(asked: Set<UUID>, kept: Set<UUID>, pending: Set<UUID>, setAside: Set<UUID>) {
        guard let current = keptRecord else { return }
        let answered = asked.subtracting(pending)
        let remaining = Set(current.sessions.map(\.id)).subtracting(answered.subtracting(kept))
        keptRecord = remaining.isEmpty ? nil : current.restricted(to: remaining)
        inFlightRecordIDs = inFlightRecordIDs.subtracting(asked).union(pending).intersection(remaining)
        setAsideRecordIDs = setAsideRecordIDs.union(setAside).intersection(remaining)
        if isRemote {
            let waiting = keptRecord?.sessions.count ?? 0
            if remoteTabsWaitingCount != waiting { remoteTabsWaitingCount = waiting }
        }
    }

    /// Adds what a restore's remainder brings back once it answers.
    private func awaitRemainder(
        _ remainder: Task<WorkspaceRestoreResult, Never>,
        asked: Set<UUID>,
        layout: WorktreeStateRecord,
        step: RestoreStep
    ) {
        let token = UUID()
        let workspace = workspace
        restoreRemainders[token] = Task { @MainActor [weak self] in
            let result = await remainder.value
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.restoreRemainders[token] = nil
            guard !self.isTearingDown, !workspace.isTornDown else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.applyRestoreStep(asked: asked, result: result, layout: layout, step: step)
        }
    }

    /// Kept records a retry asks for: not in flight, not set aside. A kept
    /// record without a binding is one whose Create was under way when it
    /// was saved, kept while a restarted host still expected holders.
    private func recordIDsToRetry() -> Set<UUID> {
        let excluded = inFlightRecordIDs.union(setAsideRecordIDs)
        return Set((keptRecord?.sessions ?? [])
            .filter { $0.mayComeBack && !excluded.contains($0.id) }
            .map(\.id))
    }

    /// Restores the kept records again once `trigger` fires (their host
    /// became reachable), into the workspace as it is then: the tabs come
    /// back with their saved layout, after the tabs opened meanwhile, and
    /// the selection stays. Auto-start commands that waited for them start
    /// afterwards.
    private func retryKeptRecords(when trigger: AnyPublisher<Void, Never>?) {
        guard let trigger else {
            restoreRetry = nil
            return
        }
        // The trigger may fire while this subscribes (the host came up
        // already): the retry then runs on the next turn, once this
        // subscription is stored and can be replaced by the retry's own.
        restoreRetry = trigger
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.restoreKeptRecords() }
            }
    }

    private func restoreKeptRecords() {
        restoreRetry = nil
        let retried = recordIDsToRetry()
        guard !isTearingDown,
              restoreTask == nil,
              let kept = keptRecord,
              !workspace.isTornDown
        else { return }
        guard !retried.isEmpty else {
            autoStartsMayNoLongerWait()
            return
        }
        let workspace = workspace
        let layout = kept
        let retriedRecords = kept.sessions.filter { retried.contains($0.id) }
        let request = WorkspaceRestoreRequest(
            repositoryRoot: repositoryRoot,
            records: retriedRecords.filter(\.isRestorable),
            workspace: workspace,
            unboundRecords: retriedRecords.filter { !$0.isRestorable },
            systemEnds: systemEnds
        )
        let restorer = sessionRestorer
        restoreCancellations.append(request.cancellation)
        restoreTaskRecordIDs = retried
        restoreTask = Task { @MainActor [weak self] in
            let result = await restorer(request)
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.restoreTask = nil
            self.restoreTaskRecordIDs = []
            guard !self.isTearingDown, !workspace.isTornDown else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.applyRestoreStep(asked: retried, result: result, layout: layout, step: .retry)
        }
        updateCommandsBeingRestored()
    }

    /// Saved records a restore under way (its task, or a remainder) may
    /// still bring back.
    private func recordsBeingRestored() -> [WorkspaceSessionRecord] {
        var ids = inFlightRecordIDs
        if restoreTask != nil {
            ids.formUnion(restoreTaskRecordIDs)
        }
        guard !ids.isEmpty else { return [] }
        return savedRecordsNotOpen().filter { ids.contains($0.id) }
    }

    private static func commandNames(of records: [WorkspaceSessionRecord]) -> Set<String> {
        Set(records.filter { $0.kind == .command }.compactMap { $0.commandName.map(AgentToolDefinition.normalizedName) })
    }

    /// Tells the workspace which commands a restore under way may bring
    /// back, so sidebar and MCP starts of them wait for it
    /// (`TerminalWorkspace.waitUntilRestored(commandNamed:)`).
    private func updateCommandsBeingRestored() {
        workspace.setCommandNamesBeingRestored(Self.commandNames(of: recordsBeingRestored()))
    }

    /// Commands auto-start leaves to a saved tab that may still come back
    /// in any window of the project (`commandNamesAutoStartWaitsForHere`).
    private func commandNamesAutoStartWaitsFor() -> Set<String> {
        var names = commandNamesAutoStartWaitsForHere()
        for other in windowRegistry?.otherRepositories(ofProjectOf: self) ?? [] {
            names.formUnion(other.commandNamesAutoStartWaitsForHere())
        }
        return names
    }

    /// Commands whose saved tab in this window may still come back: one
    /// being restored, or kept while a retry waits for its host.
    func commandNamesAutoStartWaitsForHere() -> Set<String> {
        var names = Self.commandNames(of: recordsBeingRestored())
        if restoreRetry != nil {
            let retried = recordIDsToRetry()
            names.formUnion(Self.commandNames(of: (keptRecord?.sessions ?? []).filter { retried.contains($0.id) }))
        }
        return names
    }

    /// A restore step answered here: auto-starts that waited for this
    /// window's saved tabs may start, its own and those of the window that
    /// opened the project (`ProjectWindowRegistry.restoreStepApplied`).
    private func autoStartsMayNoLongerWait() {
        startAutoStartsNoLongerWaiting()
        windowRegistry?.restoreStepApplied(in: self)
    }

    /// Starts the auto-start commands that waited for saved tabs which have
    /// now come back, or will not during this run, in any window of the
    /// project.
    func startAutoStartsNoLongerWaiting() {
        guard !autoStartsWaitingForRetry.isEmpty else { return }
        let names = commandNamesAutoStartWaitsFor()
        let ready = autoStartsWaitingForRetry.filter { !names.contains(AgentToolDefinition.normalizedName($0.name)) }
        guard !ready.isEmpty else { return }
        autoStartsWaitingForRetry.removeAll { !names.contains(AgentToolDefinition.normalizedName($0.name)) }
        startAutoStartCommands(ready)
    }

    private func applyCollapsedAgentGroupIDs(_ savedIDs: [UUID]) {
        let collapsedIDs = Set(savedIDs).intersection(workspace.sessions.map(\.id))
        guard !collapsedIDs.isEmpty else { return }
        if let chromeState {
            chromeState.collapsedAgentGroupIDs.formUnion(collapsedIDs)
        } else {
            collapsedAgentGroupIDsWithoutChrome.formUnion(collapsedIDs)
        }
    }

    /// Runs `action` once the saved tabs are restored (now, when none are
    /// pending).
    private func whenRestored(perform action: @escaping @MainActor () -> Void) {
        guard pendingRecord != nil || restoreTask != nil else {
            action()
            return
        }
        restoreWaiters.append(action)
    }

    private func runRestoreWaiters() {
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0() }
    }

    /// `root` standardized, with its links resolved when it exists.
    static func resolvedPath(_ root: String) -> String {
        let standardized = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .path
        guard let resolved = standardized.withCString({ realpath($0, nil) }) else {
            return standardized
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A workspace's selection at one moment (nil: none).
private struct SelectionMark {
    let selection: UUID?
}
