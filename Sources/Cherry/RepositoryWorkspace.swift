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

    func canRemove(closingRunningProcesses: Bool) -> Bool {
        (closingRunningProcesses || runningProcessCount == 0)
            && !isDirty
            && lockReason == nil
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

    private let service: GitWorktreeService
    private var workspaces: [String: TerminalWorkspace]
    private var autoStartedRoots: Set<String> = []
    private var selectionByRoot: [String: WorktreeSelectionState] = [:]

    init(
        projectRoot: String,
        service: GitWorktreeService = GitWorktreeService()
    ) {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
        let savedRoot = TerminalSettings.shared.worktreeSpacesEnabled
            ? AgentSettings.shared.lastActiveWorktreeRoot(for: root) ?? root
            : root
        let existingRoot = FileManager.default.fileExists(atPath: savedRoot) ? savedRoot : root
        let initialRoot = Self.resolvedPath(existingRoot)
        repositoryRoot = root
        self.service = service
        activeWorktreeRoot = initialRoot

        let initialWorkspace = TerminalWorkspace(projectRoot: initialRoot)
        workspaces = [initialRoot: initialWorkspace]
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
        AgentSettings.shared.markWorktreeOpened(root, repositoryRoot: repositoryRoot)
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

    func removalBlockers(for worktree: GitWorktree) async -> WorktreeRemovalBlockers {
        let runningProcessCount = workspaces[worktree.root]?.sessionsWithRunningProcess().count ?? 0
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
        guard !worktree.isMain,
              let isDirty = dirtyByRoot[worktree.root]
        else {
            return false
        }
        let runningProcessCount = workspaces[worktree.root]?.sessionsWithRunningProcess().count ?? 0
        return WorktreeRemovalBlockers(
            runningProcessCount: runningProcessCount,
            isDirty: isDirty,
            lockReason: worktree.lockReason,
            pruneReason: worktree.pruneReason
        ).canRemove(closingRunningProcesses: worktree.root == activeWorktreeRoot)
    }

    func remove(
        _ worktree: GitWorktree,
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
        let blockers = await removalBlockers(for: worktree)
        guard blockers.canRemove(closingRunningProcesses: isCurrent) else {
            throw GitWorktreeCommandError(
                arguments: ["worktree", "remove", worktree.root],
                exitCode: 1,
                standardError: Self.removalBlockerMessage(
                    blockers,
                    closingRunningProcesses: isCurrent
                )
            )
        }

        let wasActive = isCurrent
        let fallback = visibleWorktrees.first { $0.root != worktree.root }
            ?? worktrees.first { $0.root != worktree.root }
        try await service.remove(worktreeRoot: worktree.root, repositoryRoot: repositoryRoot)
        workspaces.removeValue(forKey: worktree.root)?.closeAllSessions()
        loadedWorktreeRoots.remove(worktree.root)
        hiddenWorktreeRoots.remove(worktree.root)
        selectionByRoot.removeValue(forKey: worktree.root)
        if wasActive, let fallback {
            _ = activate(worktreeRoot: fallback.root, chromeState: chromeState)
        }
        await refresh()
    }

    func prune() async throws {
        try await service.prune(repositoryRoot: repositoryRoot)
        await refresh()
    }

    func closeAllSessions() {
        workspaces.values.forEach { $0.closeAllSessions() }
    }

    func runningProcessCount() -> Int {
        workspaces.values.reduce(0) { $0 + $1.sessionsWithRunningProcess().count }
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
        let workspace = TerminalWorkspace(projectRoot: root, createInitialSession: false)
        workspaces[root] = workspace
        loadedWorktreeRoots.insert(root)
        ProjectWindowRegistry.shared.repositoryDidRefresh(self)
        return workspace
    }

    private func autoStartCommandsIfNeeded(workspace: TerminalWorkspace, root: String) {
        guard autoStartedRoots.insert(root).inserted else { return }
        for command in AgentSettings.shared.launchableProjectCommands(for: root) where command.autoStart {
            workspace.addCommandSession(command: command, projectRoot: root, select: false)
        }
    }

    private func persistHiddenWorktrees() {
        AgentSettings.shared.setHiddenWorktreeRoots(hiddenWorktreeRoots, for: repositoryRoot)
    }

    private func standardized(_ root: String) -> String {
        Self.resolvedPath(root)
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
        chromeState.selectedNoteID = selectedNoteID
        chromeState.selectedTodoID = selectedTodoID
        chromeState.isTodoPanePresented = isTodoPanePresented
        chromeState.selectedTodoTagFilterIDs = selectedTodoTagFilterIDs
        chromeState.collapsedAgentGroupIDs = collapsedAgentGroupIDs
        chromeState.focusedIdleCommandName = focusedIdleCommandName
    }
}
