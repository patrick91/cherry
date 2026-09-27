import Combine
import Darwin
import Foundation

struct WorktreeRemovalBlockers: Equatable {
    let runningProcessCount: Int
    let isDirty: Bool
    let lockReason: String?
    let pruneReason: String?

    var canRemove: Bool {
        canRemove(closingRunningProcesses: false)
    }

    func canRemove(
        closingRunningProcesses: Bool,
        force: Bool = false
    ) -> Bool {
        (closingRunningProcesses || runningProcessCount == 0)
            && (force || (!isDirty && lockReason == nil))
            && pruneReason == nil
    }
}

@MainActor
final class RepositoryWorkspace: ObservableObject {
    @Published private(set) var worktrees: [GitWorktree]
    @Published private(set) var activeWorktreeRoot: String
    @Published private(set) var commonDirectory: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var discoveryError: String?
    @Published private(set) var dirtyByRoot: [String: Bool] = [:]
    @Published private(set) var loadedWorktreeRoots: Set<String>
    @Published private(set) var hiddenWorktreeRoots: Set<String>

    let repositoryRoot: String
    /// The worktree the window opened on; its commands auto-start from the
    /// window once its saved tabs are restored.
    let initialWorktreeRoot: String

    private let service: GitWorktreeService
    private let backendPolicy: SessionBackendPolicy
    private let stateStore: WorkspaceStateStore?
    private let sessionRestorer: WorkspaceSessionRestorer
    private let autoStartCommands: @MainActor (String) -> [ProjectCommandDefinition]
    private var workspaces: [String: TerminalWorkspace]
    private var resolvedPathsByInput: [String: String]
    private var autoStartedRoots: Set<String> = []
    private var selectionByRoot: [String: WorktreeSelectionState] = [:]
    private var pendingAutoStartTask: Task<Void, Never>?
    private var activeRootPersistenceTask: Task<Void, Never>?

    // Workspace persistence. Nothing is saved before the window claimed its
    // project (`beginRestoringSavedStateIfNeeded`), so a duplicate window
    // never writes, and nothing is saved once a teardown intent closed it.
    /// Saved worktrees whose tabs are not restored yet. Saves carry them
    /// over unchanged, so an unfinished or skipped restore loses nothing.
    private var pendingWorktreeRecords: [String: WorktreeStateRecord]
    /// Saved tabs a restore has not brought back or dropped yet, by root:
    /// kept for a later launch (their helper or host was unavailable), still
    /// being restored (`inFlightRecordIDs`), or set aside (a command tab
    /// opened meanwhile runs that command). Saves merge them into the live
    /// worktree, so none of them is forgotten.
    private var keptWorktreeRecords: [String: WorktreeStateRecord] = [:]
    /// Kept records whose host had not answered when the restore added the
    /// others: the restore's remainder brings them back, keeps or drops
    /// them. By root.
    private var inFlightRecordIDs: [String: Set<UUID>] = [:]
    /// Kept records of restored command tabs that a tab opened meanwhile
    /// runs the command of (`TerminalWorkspace.restoreSessions`): saved for
    /// the next launch, not restored again during this run. By root.
    private var setAsideRecordIDs: [String: Set<UUID>] = [:]
    private var restoreTasks: [String: Task<Void, Never>] = [:]
    /// The records the restore task of a root asks for.
    private var restoreTaskRecordIDs: [String: Set<UUID>] = [:]
    /// Restores' remainders (hosts that answered late), by root.
    private var restoreRemainders: [String: [UUID: Task<Void, Never>]] = [:]
    /// The selection a workspace had when its restore added its first tabs,
    /// while more are in flight: a later tab that is the saved selection is
    /// selected only while that has not changed.
    private var selectionsAwaitingRestore: [String: SelectionMark] = [:]
    private let restoredTabLaunchQueue: RestoredTabLaunchQueue
    private var restoreWaiters: [String: [@MainActor () -> Void]] = [:]
    /// Kept records that come back when their host becomes reachable during
    /// this run (`WorkspaceRestoreResult.retryWhenAvailable`), by root.
    private var restoreRetries: [String: AnyCancellable] = [:]
    /// Auto-start commands not started because a kept record (its host was
    /// unreachable) may bring back their tab; they start once it has come
    /// back, by root.
    private var autoStartsWaitingForRetry: [String: [ProjectCommandDefinition]] = [:]
    private var didBeginRestore = false
    private(set) var isTearingDown = false
    /// Every restore request made, by root: cancelled when the window tears
    /// down or the worktree is forgotten, so a restore still under way
    /// builds no more tabs and ends those it has not handed back.
    private var restoreCancellations: [String: [WorkspaceRestoreCancellation]] = [:]
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
    private var systemEndedTabs: [WeakSession] = []
    /// Worktrees whose orphaned sessions were looked for (once per run).
    private var orphanScannedRoots: Set<String> = []
    /// Saved tabs forgotten with their worktree during this run, whose
    /// sessions are being ended: never adopted.
    private var forgottenRecordIDs: Set<UUID> = []
    private var orphanScanTask: Task<Void, Never>?
    private var orphanScanRetry: AnyCancellable?
    /// When the first window of this app run opened: sessions created
    /// since belong to this run's tabs, never to a tab whose record was lost.
    private static let appRunStartedAt = Date()
    private var persistenceSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var chromeStateSubscription: AnyCancellable?
    private weak var chromeState: ProjectWindowChromeState?
    /// The registry this repository's window registered with
    /// (`ProjectWindowRegistry.register`): it names that window.
    weak var windowRegistry: ProjectWindowRegistry?
    private var pendingStateSaveTask: Task<Void, Never>?

    /// The app passes `.userSettings`, `.shared` and
    /// `WorkspaceSessionRestorers.hostedByDefault(localSessions: .shared)`;
    /// tests get native tabs and no persistence unless they opt in.
    init(
        projectRoot: String,
        service: GitWorktreeService = GitWorktreeService(),
        backendPolicy: SessionBackendPolicy = .native,
        stateStore: WorkspaceStateStore? = nil,
        sessionRestorer: @escaping WorkspaceSessionRestorer = WorkspaceSessionRestorers.none,
        autoStartCommands: @escaping @MainActor (String) -> [ProjectCommandDefinition] = { root in
            AgentSettings.shared.launchableProjectCommands(for: root).filter(\.autoStart)
        },
        restoredTabLaunchQueue: RestoredTabLaunchQueue = .shared
    ) {
        let runStartedAt = Self.appRunStartedAt
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
        let savedRoot = TerminalSettings.shared.worktreeSpacesEnabled
            ? AgentSettings.shared.lastActiveWorktreeRoot(for: root) ?? root
            : root
        let existingRoot = FileManager.default.fileExists(atPath: savedRoot) ? savedRoot : root
        let initialRoot = Self.resolvedPath(existingRoot)
        repositoryRoot = root
        initialWorktreeRoot = initialRoot
        self.service = service
        self.backendPolicy = backendPolicy
        self.stateStore = stateStore
        self.sessionRestorer = sessionRestorer
        self.autoStartCommands = autoStartCommands
        self.restoredTabLaunchQueue = restoredTabLaunchQueue
        activeWorktreeRoot = initialRoot

        // Only tabs bound to a hosted session can come back, and, when local
        // tabs run in the host, tabs saved while their session's Create had
        // not answered; a worktree with none restores nothing, and its
        // native tabs are dropped.
        let mayAdoptUnbound = backendPolicy.localSessions != nil
        let savedState = stateStore?.load(repositoryRoot: root)
        var pendingRecords: [String: WorktreeStateRecord] = [:]
        for record in savedState?.worktrees ?? []
        where (mayAdoptUnbound
            ? record.hasRestorableSessions
            : record.sessions.contains { $0.isRestorable || $0.systemEnd != nil })
            && pendingRecords[record.root] == nil {
            // Each record says when an open tab last saved it, so saving it
            // again unchanged (kept for later) keeps that.
            var record = record
            record.sessions = record.sessions.map { session in
                var session = session
                session.savedAt = session.savedAt ?? savedState?.savedAt
                return session
            }
            pendingRecords[record.root] = record
        }
        pendingWorktreeRecords = pendingRecords
        if let stateStore, stateStore.isEnabled, let localSessions = backendPolicy.localSessions {
            let sessionsToEnd = stateStore.loadSessionsToEnd()
            orphanCriteria = OrphanedSessionCriteria(
                owner: localSessions.owner,
                savedState: savedState,
                // A file this version moved aside still says when it was
                // saved and which tabs it had.
                setAside: savedState == nil ? stateStore.setAsideState(repositoryRoot: root) : nil,
                sessionsToEnd: sessionsToEnd,
                createdBefore: runStartedAt
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

        let initialWorkspace = TerminalWorkspace(
            projectRoot: initialRoot,
            createInitialSession: pendingRecords[initialRoot] == nil,
            backendPolicy: backendPolicy
        )
        initialWorkspace.restoredTabLaunchQueue = restoredTabLaunchQueue
        workspaces = [initialRoot: initialWorkspace]
        var initialResolvedPaths = [root: initialRoot]
        initialResolvedPaths[initialRoot] = initialRoot
        resolvedPathsByInput = initialResolvedPaths
        loadedWorktreeRoots = [initialRoot]
        hiddenWorktreeRoots = Set(
            AgentSettings.shared.hiddenWorktreeRoots(for: root).map(Self.resolvedPath)
        )
        worktrees = [GitWorktree(
            root: initialRoot,
            head: "",
            branch: nil,
            isMain: true,
            isBare: false,
            isDetached: false,
            lockReason: nil,
            pruneReason: nil
        )]
        closeTabsAfterCleanExit(in: initialWorkspace)
        observePersistentState(of: initialWorkspace)
    }

    var activeWorkspace: TerminalWorkspace {
        workspace(for: activeWorktreeRoot)
    }

    var visibleWorktrees: [GitWorktree] {
        worktrees.filter { worktree in
            worktree.isMain
                || worktree.root == activeWorktreeRoot
                || !hiddenWorktreeRoots.contains(worktree.root)
        }
    }

    var activeWorktree: GitWorktree? {
        worktrees.first { $0.root == activeWorktreeRoot }
    }

    var repositoryName: String {
        URL(fileURLWithPath: repositoryRoot, isDirectory: true).lastPathComponent
    }

    var supportsWorktrees: Bool {
        TerminalSettings.shared.worktreeSpacesEnabled && commonDirectory != nil
    }

    func workspaceIfLoaded(for root: String) -> TerminalWorkspace? {
        workspaces[standardized(root)]
    }

    func allLoadedWorkspaces() -> [TerminalWorkspace] {
        worktrees.compactMap { workspaces[$0.root] }
    }

    func contains(worktreeRoot: String) -> Bool {
        let root = standardized(worktreeRoot)
        return worktrees.contains { $0.root == root }
    }

    func refresh() async {
        guard TerminalSettings.shared.worktreeSpacesEnabled else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await service.discover(projectRoot: repositoryRoot)
            commonDirectory = snapshot.commonDirectory
            worktrees = snapshot.worktrees
            for worktree in snapshot.worktrees {
                resolvedPathsByInput[worktree.root] = worktree.root
            }
            discoveryError = nil
            hiddenWorktreeRoots.formIntersection(Set(snapshot.worktrees.map(\.root)))
            persistHiddenWorktrees()
            AgentSettings.shared.registerWorktreeRoots(
                snapshot.worktrees.map(\.root),
                repositoryRoot: repositoryRoot
            )
            if !snapshot.worktrees.contains(where: { $0.root == activeWorktreeRoot }) {
                let fallback = snapshot.worktrees.first?.root ?? repositoryRoot
                activate(worktreeRoot: fallback, chromeState: nil)
            }
            restorePendingWorktrees(droppingUndiscovered: true)
            // Worktrees discovered now may have sessions no saved tab names.
            scanForOrphanedSessions()
            AgentSettings.shared.markWorktreeOpened(
                activeWorktreeRoot,
                repositoryRoot: repositoryRoot
            )
            ProjectWindowRegistry.shared.repositoryDidRefresh(self)
            await refreshDirtyStatus()
        } catch {
            discoveryError = error.localizedDescription
            commonDirectory = nil
        }
    }

    func refreshDirtyStatus() async {
        guard supportsWorktrees else { return }
        let roots = worktrees.filter { !$0.isBare && !$0.isPrunable }.map(\.root)
        // Keep the probes in one background task. A task group here can crash in
        // Swift's TaskGroup::offer when several Git processes complete together.
        dirtyByRoot = await service.dirtyStatuses(worktreeRoots: roots)
    }

    func disableWorktreeSpaces(chromeState: ProjectWindowChromeState?) {
        discoveryError = nil
        guard activeWorktreeRoot != repositoryRoot else { return }
        _ = activate(worktreeRoot: repositoryRoot, chromeState: chromeState)
    }

    @discardableResult
    func activate(
        worktreeRoot requestedRoot: String,
        chromeState: ProjectWindowChromeState?
    ) -> TerminalWorkspace? {
        let root = standardized(requestedRoot)
        guard worktrees.contains(where: { $0.root == root }) || root == repositoryRoot else {
            return nil
        }
        guard root != activeWorktreeRoot else {
            return workspaces[root]
        }

        if let chromeState {
            selectionByRoot[activeWorktreeRoot] = WorktreeSelectionState(chromeState: chromeState)
        }
        let nextWorkspace = workspace(for: root)
        activeWorktreeRoot = root
        restoreSavedWorktreeIfNeeded(root: root)
        // Restored tabs of a worktree not shown attach once it is.
        nextWorkspace.launchRestoredAdapters()
        scheduleActiveRootPersistence(root: root)
        if let chromeState {
            (selectionByRoot[root] ?? .terminal).apply(to: chromeState)
        }
        autoStartCommandsIfNeeded(workspace: nextWorkspace, root: root)
        ProjectWindowRegistry.shared.repositoryDidActivate(self)
        return nextWorkspace
    }

    func activateAdjacent(offset: Int, chromeState: ProjectWindowChromeState?) {
        guard let worktree = adjacentWorktree(offset: offset) else { return }
        _ = activate(worktreeRoot: worktree.root, chromeState: chromeState)
    }

    func adjacentWorktree(offset: Int) -> GitWorktree? {
        let visible = visibleWorktrees
        guard offset != 0,
              visible.count > 1,
              let currentIndex = visible.firstIndex(where: { $0.root == activeWorktreeRoot })
        else {
            return nil
        }
        let nextIndex = (currentIndex + offset + visible.count) % visible.count
        return visible[nextIndex]
    }

    @discardableResult
    func prepareWorkspace(worktreeRoot requestedRoot: String) -> TerminalWorkspace? {
        let root = standardized(requestedRoot)
        guard worktrees.contains(where: { $0.root == root }) else { return nil }
        return workspace(for: root)
    }

    func hide(_ worktree: GitWorktree, chromeState: ProjectWindowChromeState?) {
        guard !worktree.isMain else { return }
        if worktree.root == activeWorktreeRoot {
            let fallback = visibleWorktrees.first { $0.root != worktree.root }
            if let fallback {
                _ = activate(worktreeRoot: fallback.root, chromeState: chromeState)
            }
        }
        hiddenWorktreeRoots.insert(worktree.root)
        persistHiddenWorktrees()
    }

    func show(_ worktree: GitWorktree) {
        hiddenWorktreeRoots.remove(worktree.root)
        persistHiddenWorktrees()
    }

    func branchReferences() async throws -> [GitBranchReference] {
        try await service.branchReferences(repositoryRoot: repositoryRoot)
    }

    func fetch() async throws {
        try await service.fetch(repositoryRoot: repositoryRoot)
        await refresh()
    }

    func create(
        _ creation: GitWorktreeCreation,
        chromeState: ProjectWindowChromeState?
    ) async throws {
        try await service.create(creation, repositoryRoot: repositoryRoot)
        await refresh()
        _ = activate(worktreeRoot: creation.destination, chromeState: chromeState)
    }

    func canRename(_ worktree: GitWorktree) -> Bool {
        !worktree.isMain
            && !worktree.isBare
            && !worktree.isDetached
            && !worktree.isLocked
            && !worktree.isPrunable
            && worktree.branch != nil
    }

    func rename(_ worktree: GitWorktree, to requestedName: String) async throws {
        guard canRename(worktree), let currentName = worktree.branch else {
            throw GitWorktreeCommandError(
                arguments: ["branch", "-m", requestedName],
                exitCode: 1,
                standardError: "Cherry can only rename linked worktrees on local branches."
            )
        }
        let newName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newName != currentName else { return }
        try await service.validateBranchName(newName, repositoryRoot: repositoryRoot)
        try await service.renameBranch(worktreeRoot: worktree.root, newName: newName)
        await refresh()
    }

    func removalBlockers(for worktree: GitWorktree) async -> WorktreeRemovalBlockers {
        // Removing the worktree ends its persistent tabs' sessions too, so
        // their running commands, agents and busy terminals count, and so do
        // the saved tabs of this Mac's sessions that are not tabs (yet):
        // those a restore is still bringing back, those kept while the host
        // could not be reached, and those set aside. A removal ends them
        // too (`forgetWorktree`).
        let runningProcessCount = (workspaces[worktree.root]?
            .sessionsWithRunningProcess(endingWith: .worktreeRemoved).count ?? 0)
            + savedRecordsNotOpen(root: worktree.root).filter(\.mayOwnLocalSession).count
        let isDirty: Bool
        do {
            isDirty = try await service.isDirty(worktreeRoot: worktree.root)
        } catch {
            isDirty = true
        }
        return WorktreeRemovalBlockers(
            runningProcessCount: runningProcessCount,
            isDirty: isDirty,
            lockReason: worktree.lockReason,
            pruneReason: worktree.pruneReason
        )
    }

    func canRemove(_ worktree: GitWorktree) -> Bool {
        !worktree.isMain
    }

    func remove(
        _ worktree: GitWorktree,
        force: Bool = false,
        chromeState: ProjectWindowChromeState?
    ) async throws {
        guard !worktree.isMain else {
            throw GitWorktreeCommandError(
                arguments: ["worktree", "remove", worktree.root],
                exitCode: 1,
                standardError: "The primary checkout cannot be removed from Cherry."
            )
        }
        let isCurrent = activeWorktreeRoot == worktree.root
        if worktree.isPrunable {
            guard force else {
                throw GitWorktreeCommandError(
                    arguments: ["worktree", "prune"],
                    exitCode: 1,
                    standardError: "The checkout is already missing. Prune its stale Git entry instead."
                )
            }
        } else {
            let blockers = await removalBlockers(for: worktree)
            let closesRunningProcesses = isCurrent || force
            guard blockers.canRemove(
                closingRunningProcesses: closesRunningProcesses,
                force: force
            ) else {
                throw GitWorktreeCommandError(
                    arguments: ["worktree", "remove", worktree.root],
                    exitCode: 1,
                    standardError: Self.removalBlockerMessage(
                        blockers,
                        closingRunningProcesses: closesRunningProcesses
                    )
                )
            }
        }

        let wasActive = isCurrent
        let fallback = visibleWorktrees.first { $0.root != worktree.root }
            ?? worktrees.first { $0.root != worktree.root }
        let gitRoot = worktrees.first(where: \.isMain)?.root ?? repositoryRoot
        if worktree.isPrunable {
            try await service.prune(repositoryRoot: gitRoot)
        } else {
            try await service.remove(
                worktreeRoot: worktree.root,
                repositoryRoot: gitRoot,
                force: force
            )
        }
        forgetWorktree(worktree)
        if wasActive, let fallback {
            _ = activate(worktreeRoot: fallback.root, chromeState: chromeState)
        }
        await refresh()
    }

    func removeAllLinkedWorktrees(
        chromeState: ProjectWindowChromeState?
    ) async throws {
        let targets = worktrees.filter { !$0.isMain }
        guard !targets.isEmpty else { return }
        let gitRoot = worktrees.first(where: \.isMain)?.root ?? repositoryRoot

        if targets.contains(where: { $0.root == activeWorktreeRoot }) {
            _ = activate(worktreeRoot: gitRoot, chromeState: chromeState)
        }

        var failures: [String] = []
        for worktree in targets where !worktree.isPrunable {
            do {
                try await service.remove(
                    worktreeRoot: worktree.root,
                    repositoryRoot: gitRoot,
                    force: true
                )
                forgetWorktree(worktree)
            } catch {
                failures.append("\(worktree.displayName): \(error.localizedDescription)")
            }
        }

        let staleWorktrees = targets.filter(\.isPrunable)
        if !staleWorktrees.isEmpty {
            do {
                try await service.prune(repositoryRoot: gitRoot)
                staleWorktrees.forEach(forgetWorktree)
            } catch {
                failures.append("Missing entries: \(error.localizedDescription)")
            }
        }

        await refresh()
        guard failures.isEmpty else {
            throw GitWorktreeCommandError(
                arguments: ["worktree", "remove", "--force", "--force"],
                exitCode: 1,
                standardError: "Some linked worktrees could not be removed:\n" + failures.joined(separator: "\n")
            )
        }
    }

    func prune() async throws {
        try await service.prune(repositoryRoot: repositoryRoot)
        await refresh()
    }

    /// Closes every worktree's tabs. A teardown intent (window closed, app
    /// quit, duplicate window) stops workspace persistence first, so the file
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
            stoppedNativeProgram = workspace.closeSessionsForQuit(intent: intent) || stoppedNativeProgram
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
            restoreTasks.values.forEach { $0.cancel() }
            restoreWaiters.removeAll()
            restoreRetries.removeAll()
            autoStartsWaitingForRetry.removeAll()
            orphanScanTask?.cancel()
            orphanScanTask = nil
            orphanScanRetry = nil
        }
        workspaces.values.forEach(close)
        if intent.tearsDownWorkspace {
            // After the workspaces closed: restores under way end the tabs
            // they built with the same intent, and build no more.
            let cancellations = restoreCancellations.values.flatMap { $0 }
            restoreCancellations.removeAll()
            cancellations.forEach { $0.cancel() }
        }
    }

    /// What closing every worktree's tabs for `teardown` would do
    /// (`TerminalWorkspace.teardownSummary`), over the workspaces
    /// `closeAllSessions` closes. A quit names each session's project; a
    /// window close names its worktree when more than one of the window's
    /// worktrees has tabs.
    func teardownSummary(
        _ teardown: SessionTeardown,
        pathDisplayMode: SidebarTerminalPathDisplayMode
    ) -> SessionTeardownSummary {
        let withTabs = workspaces.filter { !$0.value.sessions.isEmpty }
        let order = worktrees.map(\.root)
        let roots = withTabs.keys.sorted { lhs, rhs in
            (order.firstIndex(of: lhs) ?? order.count, lhs) < (order.firstIndex(of: rhs) ?? order.count, rhs)
        }
        var summary = roots.reduce(SessionTeardownSummary()) { summary, root in
            guard let workspace = withTabs[root] else { return summary }
            let worktreeName = worktrees.first { $0.root == root }?.displayName
                ?? URL(fileURLWithPath: root).lastPathComponent
            let place: String? = switch teardown {
            case .quit: repositoryName
            case .windowClose: withTabs.count > 1 ? worktreeName : nil
            }
            return summary + workspace.teardownSummary(teardown, place: place, pathDisplayMode: pathDisplayMode)
        }
        summary.savedSessionsNotOpen = savedRecordsWhoseSessionsEndWithTheWindow().count
        return summary
    }

    func root(containing sessionID: UUID) -> String? {
        workspaces.first { _, workspace in
            workspace.sessions.contains { $0.id == sessionID }
        }?.key
    }

    private func workspace(for root: String) -> TerminalWorkspace {
        if let existing = workspaces[root] {
            return existing
        }
        // Worktree spaces start empty: eagerly spawning a shell here builds a
        // ghostty surface synchronously (~350ms+ measured), which lands on the
        // first tick of a swipe gesture via `prepareWorkspace`. The user opens
        // terminals explicitly; loaded workspaces then stay in memory.
        let workspace = TerminalWorkspace(
            projectRoot: root,
            createInitialSession: false,
            backendPolicy: backendPolicy
        )
        workspace.restoredTabLaunchQueue = restoredTabLaunchQueue
        workspaces[root] = workspace
        loadedWorktreeRoots.insert(root)
        closeTabsAfterCleanExit(in: workspace)
        observePersistentState(of: workspace)
        return workspace
    }

    /// A terminal tab whose shell exited cleanly closes as ⌘W closes it: on
    /// the window's last tab, the window closes too. The window is the one
    /// this repository's chrome state belongs to (the window that claimed
    /// the project, in the registry it registered with), never another
    /// window of the same project.
    private func closeTabsAfterCleanExit(in workspace: TerminalWorkspace) {
        workspace.closeTabAfterCleanExit = { [weak self] workspace, session in
            guard let self, !self.isTearingDown else { return }
            let chromeState = self.chromeState
            SessionCloseCoordinator.closeTabAfterCleanExit(
                session,
                in: workspace,
                repository: self,
                chromeState: chromeState,
                window: chromeState.flatMap { self.windowRegistry?.window(for: $0) }
            )
        }
    }

    /// Starts the initial worktree's auto-start commands once its saved tabs
    /// are restored, skipping commands a restored tab already runs.
    func autoStartInitialCommandsIfNeeded() {
        let root = initialWorktreeRoot
        guard autoStartedRoots.insert(root).inserted else { return }
        whenRestored(root: root) { [weak self] in
            guard let self, let workspace = self.workspaces[root] else { return }
            self.startAutoStartCommands(in: workspace, root: workspace.projectRoot ?? root, worktreeRoot: root)
        }
    }

    private func autoStartCommandsIfNeeded(workspace: TerminalWorkspace, root: String) {
        guard !autoStartedRoots.contains(root) else { return }
        pendingAutoStartTask?.cancel()
        // Process/session construction is main-actor work. Wait briefly for rapid
        // workspace navigation to settle so passing over a workspace does not
        // launch all of its commands on the switching path.
        pendingAutoStartTask = Task { @MainActor [weak self, weak workspace] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self,
                  let workspace,
                  !Task.isCancelled,
                  self.activeWorktreeRoot == root,
                  self.workspaces[root] === workspace,
                  self.autoStartedRoots.insert(root).inserted
            else {
                return
            }
            self.pendingAutoStartTask = nil
            self.whenRestored(root: root) { [weak self, weak workspace] in
                guard let self, let workspace, self.workspaces[root] === workspace else { return }
                self.startAutoStartCommands(in: workspace, root: root)
            }
        }
    }

    /// `addCommandSession` returns the existing tab for a command that is
    /// already open, restored ones included, so nothing starts twice. A
    /// restored command tab whose session ended while Cherry was closed
    /// starts again: auto-start commands run when their window opens. A
    /// command whose saved tab is still being restored (its host answers
    /// late), or was kept because its host could not be reached, waits for
    /// that tab to come back during this run (`startAutoStartsNoLongerWaiting`)
    /// instead of starting a second copy beside the one that may still run.
    /// `worktreeRoot`: the worktree's key when `root` (its project root)
    /// is spelled differently.
    private func startAutoStartCommands(
        in workspace: TerminalWorkspace,
        root: String,
        worktreeRoot: String? = nil,
        commands: [ProjectCommandDefinition]? = nil
    ) {
        guard !isTearingDown else { return }
        let key = worktreeRoot ?? root
        let waitingNames = commandNamesAutoStartWaitsFor(root: key)
        for command in commands ?? autoStartCommands(root) {
            if waitingNames.contains(AgentToolDefinition.normalizedName(command.name)),
               workspace.commandSession(named: command.name) == nil {
                autoStartsWaitingForRetry[key, default: []].append(command)
                continue
            }
            let session = workspace.addCommandSession(command: command, projectRoot: root, select: false)
            if session.kind == .command, session.hostedAttachment == nil, !session.isRunning {
                session.restartManagedCommandIfNeeded()
            }
        }
    }

    private func scheduleActiveRootPersistence(root: String) {
        activeRootPersistenceTask?.cancel()
        activeRootPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  !Task.isCancelled,
                  self.activeWorktreeRoot == root
            else {
                return
            }
            AgentSettings.shared.markWorktreeOpened(root, repositoryRoot: self.repositoryRoot)
            self.activeRootPersistenceTask = nil
        }
    }

    private func persistHiddenWorktrees() {
        AgentSettings.shared.setHiddenWorktreeRoots(hiddenWorktreeRoots, for: repositoryRoot)
    }

    private func forgetWorktree(_ worktree: GitWorktree) {
        if let workspace = workspaces.removeValue(forKey: worktree.root) {
            persistenceSubscriptions.removeValue(forKey: ObjectIdentifier(workspace))
            workspace.setCommandNamesBeingRestored([])
            workspace.closeAllSessions(intent: .worktreeRemoved)
        }
        restoreTasks.removeValue(forKey: worktree.root)?.cancel()
        restoreTaskRecordIDs.removeValue(forKey: worktree.root)
        // Its saved tabs that are not tabs (not restored yet, kept while the
        // host was unreachable, set aside) end like its tabs did, instead of
        // running on with no record.
        forgetSavedRecords(root: worktree.root)
        selectionsAwaitingRestore.removeValue(forKey: worktree.root)
        autoStartsWaitingForRetry.removeValue(forKey: worktree.root)
        loadedWorktreeRoots.remove(worktree.root)
        hiddenWorktreeRoots.remove(worktree.root)
        selectionByRoot.removeValue(forKey: worktree.root)
        autoStartedRoots.remove(worktree.root)
        scheduleStateSave()
    }

    // MARK: Workspace persistence

    /// Called once the window owns this project (never for a duplicate
    /// window): restores saved tabs and starts saving. `chromeState` supplies
    /// the active worktree's collapsed agent groups.
    func beginRestoringSavedStateIfNeeded(chromeState: ProjectWindowChromeState?) {
        if let chromeState, self.chromeState !== chromeState {
            self.chromeState = chromeState
            chromeStateSubscription = stateStore == nil ? nil : chromeState.$collapsedAgentGroupIDs
                .dropFirst()
                .sink { [weak self] _ in self?.scheduleStateSave() }
        }
        guard !didBeginRestore, !isTearingDown else { return }
        didBeginRestore = true
        restorePendingWorktrees(droppingUndiscovered: false)
        scanForOrphanedSessions()
        // Sessions of tabs forgotten with their worktree that an earlier
        // run could not end before it quit (once per run).
        if let stateStore, let localSessions = backendPolicy.localSessions {
            localSessions.resumeEndingSessions(recordedIn: stateStore)
        }
    }

    /// Saved tabs of `root` that are not open tabs: not restored yet, still
    /// being restored, kept for later or set aside.
    private func savedRecordsNotOpen(root: String) -> [WorkspaceSessionRecord] {
        var seen = Set<UUID>()
        return ((pendingWorktreeRecords[root]?.sessions ?? []) + (keptWorktreeRecords[root]?.sessions ?? []))
            .filter { seen.insert($0.id).inserted }
    }

    /// Saved tabs of this window that a restore may still bring back: not
    /// restored yet, still being restored, or kept while their host could
    /// not be listed. Their sessions are not in the background
    /// (`BackgroundSessions`). Set-aside tabs are not among them: their
    /// sessions run unseen until the next launch.
    func savedRecordsAwaitingRestore() -> [WorkspaceSessionRecord] {
        guard !isTearingDown else { return [] }
        let roots = Set(pendingWorktreeRecords.keys).union(keptWorktreeRecords.keys)
        return roots.sorted().flatMap { root in
            let setAside = setAsideRecordIDs[root] ?? []
            return savedRecordsNotOpen(root: root).filter { !setAside.contains($0.id) }
        }
    }

    /// Whether a restore (or a late host's part of one) or a look for
    /// orphaned sessions is under way.
    var isRestoringSessions: Bool {
        !restoreTasks.isEmpty || !restoreRemainders.isEmpty || orphanScanTask != nil
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
    /// Sessions → Open) in `worktreeRoot`'s workspace, or else the active
    /// one, and selects its tab:
    /// - the tab of this window that owns it already (its window's restore
    ///   brought it back);
    /// - a session this window may own (`canAdopt`) becomes its tab, with
    ///   the kind, agent, command and tab id its tags name, the way an
    ///   orphaned session is adopted: when a tab of that workspace runs the
    ///   same command, it is set aside (saved, still running) and that
    ///   command's tab is shown instead;
    /// - any other session (another client shows it) is attached.
    @discardableResult
    func showBackgroundSession(
        _ launch: PersistentSessionLaunch,
        worktreeRoot: String?,
        hosting: PersistentLocalSessions
    ) -> TerminalSession? {
        guard !isTearingDown else { return nil }
        let info = launch.info
        if let owner = hosting.owningTab(of: info.id), let root = root(containing: owner.id),
           let workspace = workspaces[root] {
            workspace.select(owner)
            return owner
        }
        let workspace = worktreeRoot.flatMap { prepareWorkspace(worktreeRoot: $0) } ?? activeWorkspace
        guard !workspace.isTornDown,
              let root = workspaces.first(where: { $0.value === workspace })?.key
        else { return nil }
        guard hosting.canAdopt(info) else {
            return workspace.attachHostedSession(launch.attachment, info: info)
        }
        let tabID = PersistentLocalSessions.tabID(of: info, owner: hosting.owner).flatMap { id in
            hosting.hasOpenTab(withID: id) || OpenHostedTabs.shared.hasOpenTab(withID: id)
                || workspace.session(withID: id) != nil ? nil : id
        } ?? UUID()
        let record = OrphanedSessionCriteria.record(for: info, tabID: tabID, hostID: launch.attachment.hostID)
        let tab = workspace.makeRestoredPersistentSession(launch, record: record, hosting: hosting, deferringLaunch: true)
        applyRestoreStep(
            root: root,
            asked: [],
            result: WorkspaceRestoreResult(sessions: [tab]),
            layout: WorktreeStateRecord(root: root, sessions: [record]),
            workspace: workspace,
            step: .orphans
        )
        let shown = workspace.session(withID: tab.id).flatMap { $0 === tab ? $0 : nil }
            ?? record.commandName.flatMap { workspace.commandSession(named: $0) }
        if let shown { workspace.select(shown) }
        return shown
    }

    /// Forgets `root`'s saved tabs that are not open (its worktree was
    /// removed or no longer exists), ending the sessions of This Mac they
    /// own, and stops the restores still under way for it. Those tabs are
    /// recorded as sessions to end (`SessionsToEndRecord`) before the next
    /// save drops them, so a session this run cannot end (the host stays
    /// unreachable, the app quits first) is ended at the next launch.
    private func forgetSavedRecords(root: String) {
        let forgotten = savedRecordsNotOpen(root: root)
        forgottenRecordIDs.formUnion(forgotten.map(\.id))
        restoreCancellations.removeValue(forKey: root)?.forEach { $0.cancel() }
        dropPendingWorktreeRecord(root: root)
        keptWorktreeRecords.removeValue(forKey: root)
        inFlightRecordIDs.removeValue(forKey: root)
        setAsideRecordIDs.removeValue(forKey: root)
        restoreRetries.removeValue(forKey: root)
        if !forgotten.isEmpty {
            backendPolicy.localSessions?.endSessions(ofForgottenTabs: forgotten, recordedIn: stateStore)
        }
    }

    /// A window close or quit that ends sessions (End Sessions, or
    /// Settings › Sessions) also ends the sessions of this window's saved
    /// tabs that no open tab shows: still being restored, kept while their
    /// host was unavailable, set aside, or in worktrees not restored yet.
    /// Only sessions this app created for those tabs, as when their
    /// worktree is removed; they are recorded as sessions to end, so what
    /// this run cannot end (it quits first) is ended at the next launch.
    /// The saved tabs themselves stay: the next restore drops them once
    /// their sessions are gone.
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
        let open = workspaces.values.flatMap(\.sessions).compactMap { tab -> (hostID: String, sessionID: String)? in
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
        guard backendPolicy.localSessions != nil, backendPolicy.hostedLocalTabsFollowSettings else { return [] }
        let roots = Set(pendingWorktreeRecords.keys).union(keptWorktreeRecords.keys)
        return roots.sorted().flatMap(savedRecordsNotOpen(root:)).filter(\.mayOwnLocalSession)
    }

    // MARK: Orphaned sessions

    /// The worktrees this window knows now.
    private var knownWorktreeRoots: Set<String> {
        Set(worktrees.map(\.root)).union([activeWorktreeRoot, initialWorktreeRoot])
    }

    /// Looks, once per worktree, for this app's sessions no saved tab names
    /// (`OrphanedSessionCriteria`: a tab whose record was never saved
    /// because the app crashed right after opening it, or whose record was
    /// lost) and adopts them as tabs of the worktree they were started in,
    /// after the tabs open there. Only when local tabs run as persistent
    /// sessions and this copy of the app owns them; when the host cannot be
    /// listed, again once it can.
    private func scanForOrphanedSessions() {
        guard didBeginRestore, !isTearingDown, orphanScanTask == nil, orphanScanRetry == nil,
              let criteria = orphanCriteria,
              let localSessions = backendPolicy.localSessions,
              backendPolicy.prefersPersistentLocalSessions,
              localSessions.installationProblem() == nil
        else { return }
        let roots = knownWorktreeRoots.subtracting(orphanScannedRoots)
        guard !roots.isEmpty else { return }
        let generation = localSessions.connectionGeneration
        orphanScanTask = Task { @MainActor [weak self] in
            let list = try? await localSessions.completeList()
            guard let self, !Task.isCancelled, !isTearingDown else { return }
            orphanScanTask = nil
            guard let list else {
                orphanScanRetry = localSessions.hostAvailability(after: generation)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] in
                        MainActor.assumeIsolated {
                            self?.orphanScanRetry = nil
                            self?.scanForOrphanedSessions()
                        }
                    }
                return
            }
            adoptOrphanedSessions(in: list, roots: roots, criteria: criteria, localSessions: localSessions)
            if list.awaitsHolders {
                // A restarted daemon lists a session only once its holder
                // registered: look again once none is expected.
                orphanScanRetry = localSessions.control.holdersRegistered()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] in
                        MainActor.assumeIsolated {
                            self?.orphanScanRetry = nil
                            self?.scanForOrphanedSessions()
                        }
                    }
                return
            }
            // Worktrees discovered while it listed.
            scanForOrphanedSessions()
        }
    }

    private func adoptOrphanedSessions(
        in list: HostedSessionList,
        roots: Set<String>,
        criteria: OrphanedSessionCriteria,
        localSessions: PersistentLocalSessions
    ) {
        // Scanned for good only from a list that is complete.
        if !list.awaitsHolders { orphanScannedRoots.formUnion(roots) }
        // A worktree removed while the host was listed is not brought back.
        let roots = roots.intersection(knownWorktreeRoots)
        var found: [String: [(info: HostedSessionInfo, record: WorkspaceSessionRecord)]] = [:]
        for info in list.sessions {
            guard let tabID = criteria.orphanTabID(of: info),
                  !forgottenRecordIDs.contains(tabID),
                  localSessions.owningTab(of: info.id) == nil,
                  !localSessions.isEnding(info.id),
                  !localSessions.isScheduledToEnd(info, hostID: list.hostID),
                  !localSessions.hasOpenTab(withID: tabID),
                  !OpenHostedTabs.shared.hasOpenTab(withID: tabID),
                  let project = OrphanedSessionCriteria.projectRoot(of: info),
                  let root = Self.worktreeRoot(forProjectRoot: project, among: roots)
            else { continue }
            found[root, default: []].append((info, OrphanedSessionCriteria.record(for: info, tabID: tabID, hostID: list.hostID)))
        }
        let listing = localSessions.listing(of: list)
        if backendPolicy.settings().closeTabsOnCleanExit {
            // A terminal whose shell exited with status 0 would have closed
            // its tab: its ended session is removed instead of adopted.
            for (root, orphans) in found {
                let ended = orphans.filter { $0.record.kind == .terminal && PersistentLocalSessions.endedCleanly($0.info) }
                guard !ended.isEmpty else { continue }
                ended.forEach { localSessions.end(listing.attachment($0.info)) }
                let others = orphans.filter { orphan in !ended.contains { $0.info.id == orphan.info.id } }
                found[root] = others.isEmpty ? nil : others
            }
        }
        for root in found.keys.sorted() {
            guard let orphans = found[root] else { continue }
            let workspace = workspace(for: root)
            guard !workspace.isTornDown else { continue }
            let tabs = orphans.map { orphan in
                workspace.makeRestoredPersistentSession(
                    PersistentSessionLaunch(attachment: listing.attachment(orphan.info), info: orphan.info),
                    record: orphan.record,
                    hosting: localSessions,
                    deferringLaunch: true
                )
            }
            fputs("Cherry: \(tabs.count) session(s) of this app that no saved tab named came back as tabs of \(root)\n", stderr)
            applyRestoreStep(
                root: root,
                asked: [],
                result: WorkspaceRestoreResult(sessions: tabs),
                layout: WorktreeStateRecord(root: root, sessions: orphans.map(\.record)),
                workspace: workspace,
                step: .orphans
            )
        }
    }

    /// The worktree among `roots` a tab's project root names.
    private static func worktreeRoot(forProjectRoot project: String, among roots: Set<String>) -> String? {
        let standardized = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.path
        for candidate in [project, standardized, resolvedPath(standardized)] where roots.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// Waits for every restore that has started, their remainders included.
    func waitForPendingRestores() async {
        while true {
            if let task = restoreTasks.values.first {
                await task.value
            } else if let task = restoreRemainders.values.lazy.flatMap(\.values).first {
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

    /// The saved form of every worktree: restored or live workspaces with the
    /// tabs their restore kept for later, plus saved worktrees whose restore
    /// has not finished, unchanged.
    func makeStateRecord() -> RepositoryStateRecord {
        let now = Date()
        var records = pendingWorktreeRecords
        for (root, workspace) in workspaces
        where records[root] == nil && !workspace.isTornDown && !workspace.sessions.isEmpty {
            var record = workspace.makeStateRecord(
                root: root,
                collapsedAgentGroupIDs: collapsedAgentGroupIDs(for: root)
            )
            // Open tabs: saved now. Kept ones below keep their time.
            record.sessions = record.sessions.map { session in
                var session = session
                session.savedAt = now
                return session
            }
            records[root] = record
        }
        for (root, kept) in keptWorktreeRecords where pendingWorktreeRecords[root] == nil {
            records[root] = records[root]?.merging(kept: kept) ?? kept
        }
        return RepositoryStateRecord(
            repositoryRoot: repositoryRoot,
            activeWorktreeRoot: activeWorktreeRoot,
            worktrees: records.keys.sorted().compactMap { records[$0] },
            savedAt: now
        )
    }

    private static let stateSaveDelay: Duration = .milliseconds(500)

    private var canSaveState: Bool {
        stateStore != nil
            && didBeginRestore
            && !isTearingDown
            && !workspaces.values.contains(where: \.isTornDown)
    }

    private func observePersistentState(of workspace: TerminalWorkspace) {
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
        persistenceSubscriptions[ObjectIdentifier(workspace)] = AnyCancellable {
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

    private func collapsedAgentGroupIDs(for root: String) -> Set<UUID> {
        if root == activeWorktreeRoot, let chromeState {
            return chromeState.collapsedAgentGroupIDs
        }
        return selectionByRoot[root]?.collapsedAgentGroupIDs ?? []
    }

    /// Restores the saved worktrees the window knows: the active one, and
    /// every discovered one. After a discovery, the saved tabs of a worktree
    /// that no longer exists are forgotten, and the sessions of This Mac
    /// they own are ended (as removing it in Cherry would have).
    private func restorePendingWorktrees(droppingUndiscovered: Bool) {
        guard didBeginRestore, !isTearingDown else { return }
        let knownRoots = Set(worktrees.map(\.root)).union([activeWorktreeRoot])
        for root in pendingWorktreeRecords.keys.sorted() where knownRoots.contains(root) {
            restoreSavedWorktreeIfNeeded(root: root)
        }
        if droppingUndiscovered {
            let vanished = Set(pendingWorktreeRecords.keys).union(keptWorktreeRecords.keys).subtracting(knownRoots)
            for root in vanished.sorted() where restoreTasks[root] == nil {
                forgetSavedRecords(root: root)
            }
            inFlightRecordIDs = inFlightRecordIDs.filter { knownRoots.contains($0.key) || restoreTasks[$0.key] != nil }
            setAsideRecordIDs = setAsideRecordIDs.filter { knownRoots.contains($0.key) || restoreTasks[$0.key] != nil }
            restoreRetries = restoreRetries.filter { knownRoots.contains($0.key) || restoreTasks[$0.key] != nil }
        }
    }

    private func restoreSavedWorktreeIfNeeded(root: String) {
        guard didBeginRestore,
              !isTearingDown,
              restoreTasks[root] == nil,
              let record = pendingWorktreeRecords[root]
        else {
            return
        }
        let workspace = workspace(for: root)
        // A local tab saved before its session's Create answered has no
        // binding; the local host may still run its session (tagged with
        // its tab id). Only asked when local tabs run as sessions.
        let mayAdoptUnbound = backendPolicy.localSessions != nil && backendPolicy.prefersPersistentLocalSessions
        // Tabs saved ended by the system come back ended whatever the
        // settings.
        let request = WorkspaceRestoreRequest(
            repositoryRoot: repositoryRoot,
            worktreeRoot: root,
            records: record.sessions.filter(\.isRestorable),
            workspace: workspace,
            unboundRecords: record.sessions.filter { !$0.isRestorable && (mayAdoptUnbound || $0.systemEnd != nil) },
            systemEnds: systemEnds
        )
        let asked = Set((request.records + request.unboundRecords).map(\.id))
        let restorer = sessionRestorer
        restoreCancellations[root, default: []].append(request.cancellation)
        restoreTaskRecordIDs[root] = asked
        restoreTasks[root] = Task { @MainActor [weak self] in
            let result = await restorer(request)
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.finishRestoring(root: root, record: record, asked: asked, workspace: workspace, result: result)
        }
        updateCommandsBeingRestored(root: root)
    }

    private func finishRestoring(
        root: String,
        record: WorktreeStateRecord,
        asked: Set<UUID>,
        workspace: TerminalWorkspace,
        result: WorkspaceRestoreResult
    ) {
        restoreTasks[root] = nil
        restoreTaskRecordIDs[root] = nil
        guard !isTearingDown, workspaces[root] === workspace else {
            // The window closed, the app quit or the worktree was removed
            // meanwhile: end these tabs the way that close ended the others.
            WorkspaceRestoreResult.discard(result, in: workspace)
            return
        }
        pendingWorktreeRecords[root] = nil
        // Every record asked for stays saved until the restore answers for it.
        keptWorktreeRecords[root] = record.restricted(to: asked)
        applyRestoreStep(root: root, asked: asked, result: result, layout: record, workspace: workspace, step: .initial)
    }

    private enum RestoreStep: Equatable {
        /// The restore that opens a worktree's workspace.
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

    /// Adds what one restore step brought back to `workspace`, with the
    /// saved `layout`, and updates the records still kept: those the step
    /// brought back or dropped go, those it kept or set aside stay, and
    /// those still pending stay in flight until its remainder answers.
    private func applyRestoreStep(
        root: String,
        asked: Set<UUID>,
        result: WorkspaceRestoreResult,
        layout: WorktreeStateRecord,
        workspace: TerminalWorkspace,
        step: RestoreStep
    ) {
        let selectingSavedTab: Bool = switch step {
        case .initial: true
        // Tabs that come late take the saved selection only while nobody
        // changed the selection since the first ones came.
        case .remainder: selectionsAwaitingRestore[root].map { $0.selection == workspace.selectedSessionID } ?? false
        case .retry, .orphans: false
        }
        // What a late part of this step is: a retry's stays a retry.
        let laterStep: RestoreStep = step == .retry ? .retry : .remainder
        let setAside = workspace.restoreSessions(
            result.sessions,
            from: layout,
            selectingSavedTab: selectingSavedTab,
            addingAfterOpenTabs: step != .initial,
            launchingAdapters: root == activeWorktreeRoot
        )
        let pending = result.pendingRecordIDs.intersection(asked)
        updateKeptRecords(
            root: root,
            asked: asked,
            kept: result.keptRecordIDs.intersection(asked).union(setAside).subtracting(pending),
            pending: pending,
            setAside: setAside
        )
        if step == .orphans, !setAside.isEmpty {
            // An adopted command whose command a tab runs already: saved,
            // set aside, so its session does not run on with no record.
            let aside = layout.restricted(to: setAside)
            keptWorktreeRecords[root] = keptWorktreeRecords[root]?.merging(kept: aside) ?? aside
            setAsideRecordIDs[root, default: []].formUnion(setAside)
        }
        if step == .retry || step == .orphans {
            // Only the restore that opened the workspace applies the saved
            // selection and the default shell.
        } else if inFlightRecordIDs[root] == nil {
            selectionsAwaitingRestore[root] = nil
            // The window's default shell, once nothing more is coming. After
            // a remainder, auto-start may have added commands meanwhile.
            if root == initialWorktreeRoot {
                switch step {
                case .initial: workspace.addInitialSessionIfEmpty()
                case .remainder: workspace.addInitialSessionIfEmpty(ignoringCommands: true)
                case .retry, .orphans: break
                }
            }
        } else {
            selectionsAwaitingRestore[root] = SelectionMark(selection: workspace.selectedSessionID)
        }
        applyCollapsedAgentGroupIDs(layout.collapsedAgentGroupIDs, root: root, workspace: workspace)
        if let remainder = result.remainder, !pending.isEmpty {
            awaitRemainder(remainder, root: root, asked: pending, layout: layout, workspace: workspace, step: laterStep)
        }
        if restoreRetries[root] == nil, let trigger = result.retryWhenAvailable, !recordIDsToRetry(root: root).isEmpty {
            retryKeptRecords(root: root, when: trigger)
        }
        updateCommandsBeingRestored(root: root)
        startAutoStartsNoLongerWaiting(root: root, workspace: workspace)
        // Adopted sessions never finish a restore: those waiting for the
        // worktree's saved tabs go on waiting.
        if step == .initial || (step != .orphans && restoreTasks[root] == nil) {
            runRestoreWaiters(root: root)
        }
        // Tabs whose sessions the system ended, found now (not saved ended),
        // once auto-start (the waiters above) started its commands again.
        let savedEnded = Set(layout.sessions.filter { $0.systemEnd != nil }.map(\.id))
        announceSystemEndedTabs(result.sessions.filter { tab in
            !savedEnded.contains(tab.id) && workspace.session(withID: tab.id) === tab
        }, root: root)
        scheduleStateSave()
    }

    /// Says in the window's toast that `tabs` came back ended because the
    /// system ended their sessions ("3 tabs ended when the Mac restarted",
    /// with Restart All), with those an earlier step of this run brought
    /// back still ended. Once per run for each tab: tabs saved ended come
    /// back without a toast.
    /// Not a tab that starts again by itself: one auto-start started (or
    /// will, when its worktree is shown), a command that restarts when it
    /// exits, or one whose program had exited before (it shows that exit,
    /// and Restart All leaves it).
    private func announceSystemEndedTabs(_ candidates: [TerminalSession], root: String) {
        var autoStarted: Set<String>?
        let tabs = candidates.filter { tab in
            guard tab.systemSessionEnd != nil, !tab.isRunning, tab.savedExitStatus == nil else { return false }
            guard tab.kind == .command else { return true }
            guard !tab.restartOnExit, let name = tab.commandName else { return !tab.restartOnExit }
            let names = autoStarted ?? Set(autoStartCommands(root).map { AgentToolDefinition.normalizedName($0.name) })
            autoStarted = names
            return !names.contains(AgentToolDefinition.normalizedName(name))
        }
        guard !tabs.isEmpty, let chromeState else { return }
        systemEndedTabs = systemEndedTabs.filter { $0.session?.systemSessionEnd != nil && $0.session?.isRunning == false }
            + tabs.map(WeakSession.init)
        let ended = systemEndedTabs.compactMap(\.session)
        guard let end = ended.first?.systemSessionEnd else { return }
        chromeState.toasts.show(ProjectWindowToast.systemEndedTabs(count: ended.count, end: end) { [weak self] in
            self?.restartSystemEndedTabs()
        })
    }

    /// Restart All: starts again every tab of this window whose session the
    /// system ended that its toast named and that is still ended.
    func restartSystemEndedTabs() {
        guard !isTearingDown else { return }
        for tab in systemEndedTabs.compactMap(\.session)
        where tab.systemSessionEnd != nil && !tab.isRunning && tab.savedExitStatus == nil {
            guard let root = root(containing: tab.id), let workspace = workspaces[root],
                  workspace.session(withID: tab.id) === tab
            else { continue }
            workspace.restart(tab)
        }
        systemEndedTabs.removeAll()
    }

    /// `keptWorktreeRecords[root]` after a restore step that asked for
    /// `asked`: of those, the ones it kept (or set aside) and the ones still
    /// pending stay; the others (restored or dropped) go.
    private func updateKeptRecords(root: String, asked: Set<UUID>, kept: Set<UUID>, pending: Set<UUID>, setAside: Set<UUID>) {
        guard let current = keptWorktreeRecords[root] else { return }
        let answered = asked.subtracting(pending)
        let remaining = Set(current.sessions.map(\.id)).subtracting(answered.subtracting(kept))
        keptWorktreeRecords[root] = remaining.isEmpty ? nil : current.restricted(to: remaining)
        let inFlight = (inFlightRecordIDs[root] ?? []).subtracting(asked).union(pending).intersection(remaining)
        inFlightRecordIDs[root] = inFlight.isEmpty ? nil : inFlight
        let aside = (setAsideRecordIDs[root] ?? []).union(setAside).intersection(remaining)
        setAsideRecordIDs[root] = aside.isEmpty ? nil : aside
    }

    /// Adds what a restore's remainder brings back once it answers.
    private func awaitRemainder(
        _ remainder: Task<WorkspaceRestoreResult, Never>,
        root: String,
        asked: Set<UUID>,
        layout: WorktreeStateRecord,
        workspace: TerminalWorkspace,
        step: RestoreStep
    ) {
        let token = UUID()
        restoreRemainders[root, default: [:]][token] = Task { @MainActor [weak self] in
            let result = await remainder.value
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.restoreRemainders[root]?[token] = nil
            if self.restoreRemainders[root]?.isEmpty == true {
                self.restoreRemainders[root] = nil
            }
            guard !self.isTearingDown, self.workspaces[root] === workspace, !workspace.isTornDown else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.applyRestoreStep(root: root, asked: asked, result: result, layout: layout, workspace: workspace, step: step)
        }
    }

    /// Kept records a retry asks for: not in flight, not set aside. A kept
    /// record without a binding is one whose Create was under way when it
    /// was saved, kept while a restarted host still expected holders.
    private func recordIDsToRetry(root: String) -> Set<UUID> {
        let excluded = (inFlightRecordIDs[root] ?? []).union(setAsideRecordIDs[root] ?? [])
        return Set((keptWorktreeRecords[root]?.sessions ?? [])
            .filter { $0.mayComeBack && !excluded.contains($0.id) }
            .map(\.id))
    }

    /// Restores `root`'s kept records again once `trigger` fires (their host
    /// became reachable), into the workspace as it is then: the tabs come
    /// back with their saved layout, after the tabs opened meanwhile, and
    /// the selection stays. Auto-start commands that waited for them start
    /// afterwards.
    private func retryKeptRecords(root: String, when trigger: AnyPublisher<Void, Never>?) {
        guard let trigger else {
            restoreRetries[root] = nil
            return
        }
        // The trigger may fire while this subscribes (the host came up
        // already): the retry then runs on the next turn, once this
        // subscription is stored and can be replaced by the retry's own.
        restoreRetries[root] = trigger
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.restoreKeptRecords(root: root) }
            }
    }

    private func restoreKeptRecords(root: String) {
        restoreRetries[root] = nil
        let retried = recordIDsToRetry(root: root)
        guard !isTearingDown,
              restoreTasks[root] == nil,
              let kept = keptWorktreeRecords[root],
              let workspace = workspaces[root],
              !workspace.isTornDown
        else { return }
        guard !retried.isEmpty else {
            startAutoStartsNoLongerWaiting(root: root, workspace: workspace)
            return
        }
        let layout = kept
        let retriedRecords = kept.sessions.filter { retried.contains($0.id) }
        let request = WorkspaceRestoreRequest(
            repositoryRoot: repositoryRoot,
            worktreeRoot: root,
            records: retriedRecords.filter(\.isRestorable),
            workspace: workspace,
            unboundRecords: retriedRecords.filter { !$0.isRestorable },
            systemEnds: systemEnds
        )
        let restorer = sessionRestorer
        restoreCancellations[root, default: []].append(request.cancellation)
        restoreTaskRecordIDs[root] = retried
        restoreTasks[root] = Task { @MainActor [weak self] in
            let result = await restorer(request)
            guard let self else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.restoreTasks[root] = nil
            self.restoreTaskRecordIDs[root] = nil
            guard !self.isTearingDown, self.workspaces[root] === workspace, !workspace.isTornDown else {
                WorkspaceRestoreResult.discard(result, in: workspace)
                return
            }
            self.applyRestoreStep(root: root, asked: retried, result: result, layout: layout, workspace: workspace, step: .retry)
        }
        updateCommandsBeingRestored(root: root)
    }

    /// Saved records a restore under way (its task, or a remainder) may
    /// still bring back for `root`.
    private func recordsBeingRestored(root: String) -> [WorkspaceSessionRecord] {
        var ids = inFlightRecordIDs[root] ?? []
        if restoreTasks[root] != nil {
            ids.formUnion(restoreTaskRecordIDs[root] ?? [])
        }
        guard !ids.isEmpty else { return [] }
        var seen = Set<UUID>()
        return ((pendingWorktreeRecords[root]?.sessions ?? []) + (keptWorktreeRecords[root]?.sessions ?? []))
            .filter { ids.contains($0.id) && seen.insert($0.id).inserted }
    }

    private static func commandNames(of records: [WorkspaceSessionRecord]) -> Set<String> {
        Set(records.filter { $0.kind == .command }.compactMap { $0.commandName.map(AgentToolDefinition.normalizedName) })
    }

    /// Tells `root`'s workspace which commands a restore under way may bring
    /// back, so sidebar and MCP starts of them wait for it
    /// (`TerminalWorkspace.waitUntilRestored(commandNamed:)`).
    private func updateCommandsBeingRestored(root: String) {
        workspaces[root]?.setCommandNamesBeingRestored(Self.commandNames(of: recordsBeingRestored(root: root)))
    }

    /// Commands auto-start leaves to a saved tab that may still come back:
    /// one being restored, or kept while a retry waits for its host.
    private func commandNamesAutoStartWaitsFor(root: String) -> Set<String> {
        var names = Self.commandNames(of: recordsBeingRestored(root: root))
        if restoreRetries[root] != nil {
            let retried = recordIDsToRetry(root: root)
            names.formUnion(Self.commandNames(of: (keptWorktreeRecords[root]?.sessions ?? []).filter { retried.contains($0.id) }))
        }
        return names
    }

    /// Starts the auto-start commands that waited for saved tabs which have
    /// now come back, or will not during this run.
    private func startAutoStartsNoLongerWaiting(root: String, workspace: TerminalWorkspace) {
        guard let waiting = autoStartsWaitingForRetry[root], !waiting.isEmpty else { return }
        let names = commandNamesAutoStartWaitsFor(root: root)
        let ready = waiting.filter { !names.contains(AgentToolDefinition.normalizedName($0.name)) }
        guard !ready.isEmpty else { return }
        let stillWaiting = waiting.filter { names.contains(AgentToolDefinition.normalizedName($0.name)) }
        autoStartsWaitingForRetry[root] = stillWaiting.isEmpty ? nil : stillWaiting
        startAutoStartCommands(in: workspace, root: workspace.projectRoot ?? root, worktreeRoot: root, commands: ready)
    }

    private func applyCollapsedAgentGroupIDs(
        _ savedIDs: [UUID],
        root: String,
        workspace: TerminalWorkspace
    ) {
        let collapsedIDs = Set(savedIDs).intersection(workspace.sessions.map(\.id))
        guard !collapsedIDs.isEmpty else { return }
        if root == activeWorktreeRoot, let chromeState {
            chromeState.collapsedAgentGroupIDs.formUnion(collapsedIDs)
        } else {
            var selection = selectionByRoot[root] ?? .terminal
            selection.collapsedAgentGroupIDs.formUnion(collapsedIDs)
            selectionByRoot[root] = selection
        }
    }

    /// Runs `action` once `root`'s saved tabs are restored (now, when it has
    /// none pending).
    private func whenRestored(root: String, perform action: @escaping @MainActor () -> Void) {
        guard pendingWorktreeRecords[root] != nil || restoreTasks[root] != nil else {
            action()
            return
        }
        restoreWaiters[root, default: []].append(action)
    }

    private func dropPendingWorktreeRecord(root: String) {
        pendingWorktreeRecords[root] = nil
        if restoreTasks[root] == nil {
            runRestoreWaiters(root: root)
        }
    }

    private func runRestoreWaiters(root: String) {
        let waiters = restoreWaiters.removeValue(forKey: root) ?? []
        waiters.forEach { $0() }
    }

    private func standardized(_ root: String) -> String {
        let standardized = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .path
        if let resolved = resolvedPathsByInput[standardized] {
            return resolved
        }
        if worktrees.contains(where: { $0.root == standardized }) {
            resolvedPathsByInput[standardized] = standardized
            return standardized
        }
        let resolved = Self.resolvedPath(standardized)
        resolvedPathsByInput[standardized] = resolved
        return resolved
    }

    private static func resolvedPath(_ root: String) -> String {
        let standardized = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .path
        guard let resolved = standardized.withCString({ realpath($0, nil) }) else {
            return standardized
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func removalBlockerMessage(
        _ blockers: WorktreeRemovalBlockers,
        closingRunningProcesses: Bool
    ) -> String {
        var reasons: [String] = []
        if blockers.runningProcessCount > 0, !closingRunningProcesses {
            reasons.append("\(blockers.runningProcessCount) foreground process\(blockers.runningProcessCount == 1 ? " is" : "es are") still running")
        }
        if blockers.isDirty {
            reasons.append("the worktree has modified or untracked files")
        }
        if let lockReason = blockers.lockReason {
            reasons.append("the worktree is locked: \(lockReason)")
        }
        if let pruneReason = blockers.pruneReason {
            reasons.append("the worktree is prunable: \(pruneReason)")
        }
        return "Cherry cannot remove this worktree because " + reasons.joined(separator: ", ") + "."
    }
}

/// A tab held without keeping it open.
@MainActor
private final class WeakSession {
    weak var session: TerminalSession?
    init(_ session: TerminalSession) { self.session = session }
}

/// A workspace's selection at one moment (nil: none).
private struct SelectionMark {
    let selection: UUID?
}

@MainActor
private struct WorktreeSelectionState {
    var selectedNoteID: UUID?
    var selectedTodoID: UUID?
    var isTodoPanePresented: Bool
    var selectedTodoTagFilterIDs: Set<String>
    var collapsedAgentGroupIDs: Set<UUID>
    var focusedIdleCommandName: String?

    static let terminal = WorktreeSelectionState(
        selectedNoteID: nil,
        selectedTodoID: nil,
        isTodoPanePresented: false,
        selectedTodoTagFilterIDs: [],
        collapsedAgentGroupIDs: [],
        focusedIdleCommandName: nil
    )

    init(chromeState: ProjectWindowChromeState) {
        selectedNoteID = chromeState.selectedNoteID
        selectedTodoID = chromeState.selectedTodoID
        isTodoPanePresented = chromeState.isTodoPanePresented
        selectedTodoTagFilterIDs = chromeState.selectedTodoTagFilterIDs
        collapsedAgentGroupIDs = chromeState.collapsedAgentGroupIDs
        focusedIdleCommandName = chromeState.focusedIdleCommandName
    }

    init(
        selectedNoteID: UUID?,
        selectedTodoID: UUID?,
        isTodoPanePresented: Bool,
        selectedTodoTagFilterIDs: Set<String>,
        collapsedAgentGroupIDs: Set<UUID>,
        focusedIdleCommandName: String?
    ) {
        self.selectedNoteID = selectedNoteID
        self.selectedTodoID = selectedTodoID
        self.isTodoPanePresented = isTodoPanePresented
        self.selectedTodoTagFilterIDs = selectedTodoTagFilterIDs
        self.collapsedAgentGroupIDs = collapsedAgentGroupIDs
        self.focusedIdleCommandName = focusedIdleCommandName
    }

    func apply(to chromeState: ProjectWindowChromeState) {
        if chromeState.selectedNoteID != selectedNoteID {
            chromeState.selectedNoteID = selectedNoteID
        }
        if chromeState.selectedTodoID != selectedTodoID {
            chromeState.selectedTodoID = selectedTodoID
        }
        if chromeState.isTodoPanePresented != isTodoPanePresented {
            chromeState.isTodoPanePresented = isTodoPanePresented
        }
        if chromeState.selectedTodoTagFilterIDs != selectedTodoTagFilterIDs {
            chromeState.selectedTodoTagFilterIDs = selectedTodoTagFilterIDs
        }
        if chromeState.collapsedAgentGroupIDs != collapsedAgentGroupIDs {
            chromeState.collapsedAgentGroupIDs = collapsedAgentGroupIDs
        }
        if chromeState.focusedIdleCommandName != focusedIdleCommandName {
            chromeState.focusedIdleCommandName = focusedIdleCommandName
        }
    }
}
