import AppKit
import Combine
import SwiftUI

enum WorktreeSwipeTuning {
    static let commitDistanceKey = "worktrees.swipeCommitDistance"
    static let settleDurationKey = "worktrees.swipeSettleDuration"
    static let defaultCommitDistance = 64.0
    static let defaultSettleDuration = 0.14
    private static let minimumSettleDuration = 0.05

    static func resolvedSettleDuration(
        configuredDuration: Double,
        currentOffset: CGFloat,
        finalOffset: CGFloat,
        sidebarWidth: CGFloat
    ) -> Double {
        let maximumDuration = max(0.01, configuredDuration)
        let minimumDuration = min(maximumDuration, minimumSettleDuration)
        let remainingDistance = abs(finalOffset - currentOffset)
        let distanceFraction = min(1, remainingDistance / max(sidebarWidth, 1))
        return max(minimumDuration, maximumDuration * Double(distanceFraction))
    }
}

enum WorktreeSwipeCommitDecision {
    private static let velocityProjectionDuration: CGFloat = 0.10

    static func shouldCommit(
        distance: CGFloat,
        velocity: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        let absoluteDistance = abs(distance)
        guard absoluteDistance < threshold else { return true }
        guard velocity != 0,
              distance == 0 || distance * velocity > 0
        else {
            return false
        }

        let projectedDistance = absoluteDistance
            + abs(velocity) * velocityProjectionDuration
        return projectedDistance >= threshold
    }
}

struct WorktreeSwipeReleaseDecision: Equatable {
    let direction: Int
    let shouldCommit: Bool

    static func make(
        distance: CGFloat,
        velocity: CGFloat,
        lastIntentDirection: Int,
        threshold: CGFloat
    ) -> Self {
        let fallbackDirection: Int
        if distance < 0 {
            fallbackDirection = 1
        } else if distance > 0 {
            fallbackDirection = -1
        } else {
            fallbackDirection = velocity < 0 ? 1 : -1
        }
        let direction = lastIntentDirection == 0
            ? fallbackDirection
            : lastIntentDirection
        let offsetSign: CGFloat = direction > 0 ? -1 : 1
        let directionalDistance = max(0, distance * offsetSign)
        let directionalVelocity = max(0, velocity * offsetSign)

        return Self(
            direction: direction,
            shouldCommit: WorktreeSwipeCommitDecision.shouldCommit(
                distance: directionalDistance,
                velocity: directionalVelocity,
                threshold: threshold
            )
        )
    }
}

enum WorktreeSwipeGesturePhase {
    static func shouldScheduleIdleFallback(for phase: NSEvent.Phase) -> Bool {
        phase.isEmpty
    }
}

struct WorktreeSpaceRail: View {
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var swipeState: WorktreeSidebarSwipeState
    let sidebarWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(repository.visibleWorktrees) { worktree in
                            WorktreeSpaceMarker(
                                worktree: worktree,
                                repository: repository,
                                chromeState: chromeState,
                                activeProgress: activeProgress(for: worktree),
                                openManager: chromeState.presentWorktreeManager
                            )
                            .id(worktree.root)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: repository.activeWorktreeRoot) { _, root in
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(root, anchor: .center)
                    }
                }
            }

            Button {
                chromeState.presentNewWorktree()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New Worktree")
            .accessibilityLabel("New Worktree")

            Button {
                chromeState.presentWorktreeManager()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Manage Worktrees")
            .accessibilityLabel("Manage Worktrees")
        }
        .frame(height: 30)
    }

    private func activeProgress(for worktree: GitWorktree) -> CGFloat {
        let currentRoot = swipeState.targetRoot == nil
            ? repository.activeWorktreeRoot
            : swipeState.sourceRoot ?? repository.activeWorktreeRoot
        let isCurrent = worktree.root == currentRoot
        guard let targetRoot = swipeState.targetRoot else {
            return isCurrent ? 1 : 0
        }
        guard targetRoot != currentRoot else {
            return isCurrent ? 1 : 0
        }

        let progress = min(1, max(0, abs(swipeState.offset) / max(sidebarWidth, 1)))
        if isCurrent { return 1 - progress }
        if worktree.root == targetRoot { return progress }
        return 0
    }
}

private struct WorktreeSpaceMarker: View {
    let worktree: GitWorktree
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let activeProgress: CGFloat
    let openManager: () -> Void

    var body: some View {
        let isActive = worktree.root == repository.activeWorktreeRoot
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                _ = repository.activate(
                    worktreeRoot: worktree.root,
                    chromeState: chromeState
                )
            }
        } label: {
            WorktreeRailIndicator(
                workspace: repository.workspaceIfLoaded(for: worktree.root),
                isDirty: repository.dirtyByRoot[worktree.root] == true,
                activeProgress: activeProgress
            )
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            Button("Open") {
                _ = repository.activate(
                    worktreeRoot: worktree.root,
                    chromeState: chromeState
                )
            }

            if !worktree.isMain {
                Button("Hide from Spaces") {
                    repository.hide(worktree, chromeState: chromeState)
                }
            }

            Divider()

            Button("Manage Worktrees...") {
                openManager()
            }
        }
    }

    private var helpText: String {
        var lines = [worktree.displayName, worktree.root]
        if repository.dirtyByRoot[worktree.root] == true {
            lines.append("Modified or untracked files")
        }
        if let lockReason = worktree.lockReason {
            lines.append("Locked: \(lockReason)")
        }
        if worktree.isDetached {
            lines.append("Detached HEAD \(worktree.shortHEAD)")
        }
        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var label = "Worktree \(worktree.displayName)"
        if worktree.root == repository.activeWorktreeRoot {
            label += ", current"
        }
        if repository.dirtyByRoot[worktree.root] == true {
            label += ", modified"
        }
        return label
    }
}

private struct WorktreeRailIndicator: View {
    let workspace: TerminalWorkspace?
    let isDirty: Bool
    let activeProgress: CGFloat

    var body: some View {
        Group {
            if let workspace {
                ObservedWorktreeRailIndicator(
                    workspace: workspace,
                    isDirty: isDirty,
                    activeProgress: activeProgress
                )
            } else {
                WorktreeRailIndicatorShape(
                    activeProgress: activeProgress,
                    isDirty: isDirty,
                    needsAttention: false,
                    hasUnread: false,
                    isWorking: false
                )
            }
        }
    }
}

private struct ObservedWorktreeRailIndicator: View {
    @StateObject private var status: WorktreeAggregateStatus
    let isDirty: Bool
    let activeProgress: CGFloat

    init(workspace: TerminalWorkspace, isDirty: Bool, activeProgress: CGFloat) {
        _status = StateObject(wrappedValue: WorktreeAggregateStatus(workspace: workspace))
        self.isDirty = isDirty
        self.activeProgress = activeProgress
    }

    var body: some View {
        WorktreeRailIndicatorShape(
            activeProgress: activeProgress,
            isDirty: isDirty,
            needsAttention: status.needsAttention,
            hasUnread: status.hasUnread,
            isWorking: status.isWorking
        )
    }
}

private struct WorktreeRailIndicatorShape: View {
    let activeProgress: CGFloat
    let isDirty: Bool
    let needsAttention: Bool
    let hasUnread: Bool
    let isWorking: Bool

    var body: some View {
        Capsule()
            .fill(indicatorColor)
            .frame(width: 6 + 8 * progress, height: 6)
    }

    private var progress: CGFloat {
        min(1, max(0, activeProgress))
    }

    private var indicatorColor: Color {
        if needsAttention { return .orange }
        if hasUnread { return .blue }
        if isWorking { return .green }
        if isDirty { return .yellow }
        return .primary.opacity(0.32 + 0.5 * progress)
    }
}

@MainActor
private final class WorktreeAggregateStatus: ObservableObject {
    @Published private(set) var needsAttention = false
    @Published private(set) var hasUnread = false
    @Published private(set) var isWorking = false

    private weak var workspace: TerminalWorkspace?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionCancellables: Set<AnyCancellable> = []

    init(workspace: TerminalWorkspace) {
        self.workspace = workspace
        workspace.$sessions
            .sink { [weak self] _ in self?.bindSessions() }
            .store(in: &cancellables)
        bindSessions()
    }

    private func bindSessions() {
        sessionCancellables.removeAll()
        guard let workspace else { return }
        for session in workspace.sessions {
            session.$agentActivityState
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &sessionCancellables)
            session.$hasUnreadNotification
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &sessionCancellables)
        }
        refresh()
    }

    private func refresh() {
        let sessions = workspace?.sessions ?? []
        needsAttention = sessions.contains {
            $0.agentActivityState == .permission || $0.agentActivityState == .error
        }
        hasUnread = sessions.contains { $0.hasUnreadNotification }
        isWorking = sessions.contains { $0.agentActivityState.showsWorkingIndicator }
    }
}

struct NewWorktreeSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case newBranch = "New Branch"
        case localBranch = "Local Branch"
        case remoteBranch = "Remote Branch"

        var id: String { rawValue }
    }

    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @Binding var isPresented: Bool

    @State private var mode: Mode = .newBranch
    @State private var branchName = ""
    @State private var startPoint = "HEAD"
    @State private var selectedLocalBranch = ""
    @State private var selectedRemoteBranch = ""
    @State private var remoteLocalName = ""
    @State private var references: [GitBranchReference] = []
    @State private var isLoading = true
    @State private var isFetching = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Worktree")
                    .font(.title2.weight(.semibold))
                Text("Create an isolated checkout for \(repository.repositoryName).")
                    .foregroundStyle(.secondary)
            }

            Picker("Source", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .newBranch:
                    TextField("Branch name", text: $branchName)
                    Picker("Start point", selection: $startPoint) {
                        Text("Active HEAD").tag("HEAD")
                        ForEach(references) { reference in
                            Text(reference.displayName).tag(reference.displayName)
                        }
                    }
                case .localBranch:
                    Picker("Branch", selection: $selectedLocalBranch) {
                        ForEach(availableLocalBranches) { reference in
                            Text(reference.displayName).tag(reference.displayName)
                        }
                    }
                case .remoteBranch:
                    HStack {
                        Picker("Remote branch", selection: $selectedRemoteBranch) {
                            ForEach(availableRemoteBranches) { reference in
                                Text(reference.displayName).tag(reference.displayName)
                            }
                        }
                        Button(isFetching ? "Fetching..." : "Fetch") {
                            fetch()
                        }
                        .disabled(isFetching || isCreating)
                    }
                    TextField("Local branch name", text: $remoteLocalName)
                }
            }
            .disabled(isLoading || isCreating)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(isCreating ? "Creating..." : "Create Worktree") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating || isLoading)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task {
            await loadReferences()
        }
        .onChange(of: mode) { _, _ in
            errorMessage = nil
        }
        .onChange(of: selectedRemoteBranch) { _, value in
            if remoteLocalName.isEmpty {
                remoteLocalName = value.split(separator: "/").dropFirst().joined(separator: "/")
            }
        }
    }

    private var checkedOutBranches: Set<String> {
        Set(repository.worktrees.compactMap(\.branch))
    }

    private var availableLocalBranches: [GitBranchReference] {
        references.filter {
            $0.kind == .local && !checkedOutBranches.contains($0.displayName)
        }
    }

    private var availableRemoteBranches: [GitBranchReference] {
        references.filter { $0.kind == .remote }
    }

    private var requestedBranchName: String {
        switch mode {
        case .newBranch: branchName
        case .localBranch: selectedLocalBranch
        case .remoteBranch: remoteLocalName
        }
    }

    private var canCreate: Bool {
        !requestedBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode != .remoteBranch || !selectedRemoteBranch.isEmpty)
    }

    private func loadReferences() async {
        isLoading = true
        defer { isLoading = false }
        do {
            references = try await repository.branchReferences()
            selectedLocalBranch = availableLocalBranches.first?.displayName ?? ""
            selectedRemoteBranch = availableRemoteBranches.first?.displayName ?? ""
            if startPoint == "HEAD" {
                startPoint = repository.activeWorktree?.branch ?? "HEAD"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetch() {
        guard !isFetching else { return }
        isFetching = true
        errorMessage = nil
        Task {
            defer { isFetching = false }
            do {
                try await repository.fetch()
                references = try await repository.branchReferences()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        let destination = GitWorktreeService.managedWorktreeRoot(
            repositoryName: repository.repositoryName,
            repositoryIdentity: repository.commonDirectory ?? repository.repositoryRoot,
            branchName: requestedBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        Task {
            defer { isCreating = false }
            do {
                let creation: GitWorktreeCreation
                switch mode {
                case .newBranch:
                    let name = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await GitWorktreeService().validateBranchName(
                        name,
                        repositoryRoot: repository.repositoryRoot
                    )
                    creation = .newBranch(
                        name: name,
                        startPoint: startPoint,
                        destination: destination
                    )
                case .localBranch:
                    creation = .localBranch(
                        name: selectedLocalBranch,
                        destination: destination
                    )
                case .remoteBranch:
                    let localName = remoteLocalName.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await GitWorktreeService().validateBranchName(
                        localName,
                        repositoryRoot: repository.repositoryRoot
                    )
                    creation = .remoteBranch(
                        remoteName: selectedRemoteBranch,
                        localName: localName,
                        destination: destination
                    )
                }
                try await repository.create(creation, chromeState: chromeState)
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct RenameWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var repository: RepositoryWorkspace
    let worktree: GitWorktree

    @State private var branchName: String
    @State private var isRenaming = false
    @State private var errorMessage: String?
    @FocusState private var isBranchNameFocused: Bool

    init(repository: RepositoryWorkspace, worktree: GitWorktree) {
        self.repository = repository
        self.worktree = worktree
        _branchName = State(initialValue: worktree.branch ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Worktree")
                    .font(.title2.weight(.semibold))
                Text("Rename its checked-out branch. The checkout folder will stay at \(worktree.root).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Branch name", text: $branchName)
                .focused($isBranchNameFocused)
                .disabled(isRenaming)
                .onSubmit(rename)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRenaming)

                Button(isRenaming ? "Renaming..." : "Rename Worktree") {
                    rename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename || isRenaming)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            isBranchNameFocused = true
        }
    }

    private var requestedName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !requestedName.isEmpty && requestedName != worktree.branch
    }

    private func rename() {
        guard canRename, !isRenaming else { return }
        isRenaming = true
        errorMessage = nil
        Task {
            defer { isRenaming = false }
            do {
                try await repository.rename(worktree, to: requestedName)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct WorktreeManagerSheet: View {
    private enum RemovalRequest: Identifiable {
        case worktree(GitWorktree)
        case all

        var id: String {
            switch self {
            case .worktree(let worktree): "worktree:\(worktree.id)"
            case .all: "all"
            }
        }
    }

    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @Binding var isPresented: Bool

    @State private var removalRequest: RemovalRequest?
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Worktrees")
                    .font(.title2.weight(.semibold))
                Text(managerSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeManagerRow(
                            worktree: worktree,
                            repository: repository,
                            chromeState: chromeState,
                            isPerformingAction: isRemoving,
                            remove: { removalRequest = .worktree(worktree) }
                        )
                        if worktree.id != repository.worktrees.last?.id {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
            }
            .frame(minHeight: 340, idealHeight: 420, maxHeight: 500)

            if let errorMessage {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task { await repository.refresh() }
                } label: {
                    Label(repository.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(repository.isRefreshing || isRemoving)

                if missingWorktreeCount > 0 {
                    Button {
                        prune()
                    } label: {
                        Label(
                            "Prune \(missingWorktreeCount) Missing",
                            systemImage: "trash.slash"
                        )
                    }
                    .disabled(isRemoving)
                }

                Spacer()

                if !linkedWorktrees.isEmpty {
                    Button("Remove All Linked…", role: .destructive) {
                        removalRequest = .all
                    }
                    .disabled(isRemoving)
                    .help("Remove every linked checkout. The primary project checkout and local branches are kept.")
                }

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 700)
        .frame(minHeight: 500, idealHeight: 570, maxHeight: 650)
        .task {
            await repository.refreshDirtyStatus()
        }
        .alert(
            removalAlertTitle,
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            presenting: removalRequest
        ) { request in
            Button("Cancel", role: .cancel) {
                removalRequest = nil
            }
            switch request {
            case .worktree(let worktree):
                Button(removalButtonTitle(for: worktree), role: .destructive) {
                    remove(worktree)
                }
            case .all:
                Button(removeAllButtonTitle, role: .destructive) {
                    removeAllLinkedWorktrees()
                }
            }
        } message: { request in
            switch request {
            case .worktree(let worktree):
                Text(removalMessage(for: worktree))
            case .all:
                Text(removeAllMessage)
            }
        }
    }

    private var linkedWorktrees: [GitWorktree] {
        repository.worktrees.filter { !$0.isMain }
    }

    private var missingWorktreeCount: Int {
        linkedWorktrees.filter(\.isPrunable).count
    }

    private var primaryWorktreeRoot: String {
        repository.worktrees.first(where: \.isMain)?.root ?? repository.repositoryRoot
    }

    private var managerSummary: String {
        let count = linkedWorktrees.count
        let noun = count == 1 ? "linked checkout" : "linked checkouts"
        return "\(count) \(noun) for \(repository.repositoryName). The project checkout stays; linked checkouts and their running processes can be removed."
    }

    private var removalAlertTitle: String {
        switch removalRequest {
        case .worktree(let worktree):
            worktree.isPrunable ? "Prune Missing Worktree?" : "Remove Worktree?"
        case .all:
            "Remove All Linked Worktrees?"
        case nil:
            "Remove Worktree?"
        }
    }

    private func removalButtonTitle(for worktree: GitWorktree) -> String {
        if worktree.isPrunable { return "Prune Entry" }
        if repository.dirtyByRoot[worktree.root] == true || worktree.isLocked {
            return "Remove Anyway"
        }
        return "Remove Worktree"
    }

    private func removalMessage(for worktree: GitWorktree) -> String {
        if worktree.isPrunable {
            return "The checkout at \(worktree.root) is already missing. Cherry will prune its stale Git entry."
        }

        var details: [String] = []
        let processCount = repository.workspaceIfLoaded(for: worktree.root)?
            .sessionsWithRunningProcess().count ?? 0
        if processCount > 0 {
            details.append("stop \(processCount) running process\(processCount == 1 ? "" : "es")")
        }
        if repository.dirtyByRoot[worktree.root] == true {
            details.append("permanently discard modified and untracked files")
        }
        if worktree.isLocked {
            details.append("override its Git lock")
        }

        let consequences = details.isEmpty
            ? "remove the checkout"
            : details.joined(separator: ", ") + ", and remove the checkout"
        return "Cherry will \(consequences) at \(worktree.root). Its branch will be kept."
    }

    private var removeAllButtonTitle: String {
        linkedWorktrees.count == 1
            ? "Remove Linked Worktree"
            : "Remove \(linkedWorktrees.count) Worktrees"
    }

    private var removeAllMessage: String {
        var consequences: [String] = []
        let processCount = linkedWorktrees.reduce(0) { count, worktree in
            count + (repository.workspaceIfLoaded(for: worktree.root)?
                .sessionsWithRunningProcess().count ?? 0)
        }
        let modifiedCount = linkedWorktrees.filter {
            repository.dirtyByRoot[$0.root] == true
        }.count
        let lockedCount = linkedWorktrees.filter(\.isLocked).count

        if processCount > 0 {
            consequences.append("stop \(processCount) running process\(processCount == 1 ? "" : "es")")
        }
        if modifiedCount > 0 {
            consequences.append("permanently discard changes in \(modifiedCount) modified checkout\(modifiedCount == 1 ? "" : "s")")
        }
        if lockedCount > 0 {
            consequences.append("override \(lockedCount) Git lock\(lockedCount == 1 ? "" : "s")")
        }
        if missingWorktreeCount > 0 {
            consequences.append("prune \(missingWorktreeCount) missing entr\(missingWorktreeCount == 1 ? "y" : "ies")")
        }

        let extra = consequences.isEmpty
            ? ""
            : " This will " + consequences.joined(separator: ", ") + "."
        let target = linkedWorktrees.count == 1
            ? "the linked checkout"
            : "all \(linkedWorktrees.count) linked checkouts"
        return "Cherry will remove \(target).\(extra) The project checkout at \(primaryWorktreeRoot) and local branches will be kept."
    }

    private func remove(_ worktree: GitWorktree) {
        isRemoving = true
        errorMessage = nil
        Task {
            defer {
                isRemoving = false
                removalRequest = nil
            }
            do {
                try await repository.remove(worktree, force: true, chromeState: chromeState)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeAllLinkedWorktrees() {
        isRemoving = true
        errorMessage = nil
        Task {
            defer {
                isRemoving = false
                removalRequest = nil
            }
            do {
                try await repository.removeAllLinkedWorktrees(chromeState: chromeState)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prune() {
        isRemoving = true
        errorMessage = nil
        Task {
            defer { isRemoving = false }
            do {
                try await repository.prune()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct WorktreeManagerRow: View {
    private struct Status: Identifiable {
        let title: String
        let color: Color

        var id: String { title }
    }

    let worktree: GitWorktree
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let isPerformingAction: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: worktree.isDetached ? "point.3.connected.trianglepath.dotted" : "rectangle.stack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(worktree.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    ForEach(statuses) { status in
                        Text(status.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(status.color.opacity(0.12), in: Capsule())
                    }
                }
                Text(worktree.root)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktree.root)
            }

            Spacer(minLength: 18)

            if worktree.root == repository.activeWorktreeRoot {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else if !worktree.isPrunable {
                Button("Open") {
                    _ = repository.activate(
                        worktreeRoot: worktree.root,
                        chromeState: chromeState
                    )
                }
                .disabled(isPerformingAction)
                .help("Switch to this checkout")
            }

            if !worktree.isMain {
                Button(worktree.isPrunable ? "Prune" : "Remove", role: .destructive, action: remove)
                    .disabled(isPerformingAction)
                    .help(removalHelp)

                Menu {
                    Button {
                        chromeState.presentRenameWorktree(worktree)
                    } label: {
                        Label("Rename Branch…", systemImage: "pencil")
                    }
                    .disabled(!repository.canRename(worktree))

                    if repository.hiddenWorktreeRoots.contains(worktree.root) {
                        Button {
                            repository.show(worktree)
                        } label: {
                            Label("Show in Sidebar", systemImage: "eye")
                        }
                    } else {
                        Button {
                            repository.hide(worktree, chromeState: chromeState)
                        } label: {
                            Label("Hide from Sidebar", systemImage: "eye.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isPerformingAction)
                .help("Actions for \(worktree.displayName)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var runningProcessCount: Int {
        repository.workspaceIfLoaded(for: worktree.root)?.sessionsWithRunningProcess().count ?? 0
    }

    private var iconColor: Color {
        if worktree.isPrunable { return .red }
        if repository.dirtyByRoot[worktree.root] == true { return .orange }
        if worktree.root == repository.activeWorktreeRoot { return .accentColor }
        return .secondary
    }

    private var statuses: [Status] {
        var result: [Status] = []
        if worktree.isMain { result.append(Status(title: "Primary", color: .gray)) }
        if worktree.isDetached { result.append(Status(title: "Detached", color: .purple)) }
        if repository.hiddenWorktreeRoots.contains(worktree.root) {
            result.append(Status(title: "Hidden", color: .gray))
        }
        if repository.dirtyByRoot[worktree.root] == true {
            result.append(Status(title: "Modified", color: .orange))
        }
        if runningProcessCount > 0 { result.append(Status(title: "Busy", color: .green)) }
        if worktree.isLocked { result.append(Status(title: "Locked", color: .orange)) }
        if worktree.isPrunable { result.append(Status(title: "Missing", color: .red)) }
        return result
    }

    private var removalHelp: String {
        if worktree.isPrunable { return "Prune this missing checkout's stale Git entry." }
        if repository.dirtyByRoot[worktree.root] == true {
            return "Remove this checkout and permanently discard modified and untracked files."
        }
        if worktree.isLocked { return "Remove this checkout and override its Git lock." }
        if runningProcessCount > 0 {
            return "Remove this checkout and stop its running processes."
        }
        return "Remove this checkout and keep its branch."
    }
}

@MainActor
final class WorktreeSidebarSwipeState: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var sourceRoot: String?
    @Published private(set) var targetRoot: String?
    @Published private(set) var direction = 0
    private(set) var isAnimatingProgrammatically = false

    private var programmaticTransitionTask: Task<Void, Never>?

    func update(
        offset: CGFloat,
        sourceRoot: String,
        targetRoot: String,
        direction: Int
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.offset = offset
            self.sourceRoot = self.sourceRoot ?? sourceRoot
            self.targetRoot = targetRoot
            self.direction = direction
        }
    }

    @discardableResult
    func settle(to offset: CGFloat, duration: Double, sidebarWidth: CGFloat) -> Double {
        let resolvedDuration = WorktreeSwipeTuning.resolvedSettleDuration(
            configuredDuration: duration,
            currentOffset: self.offset,
            finalOffset: offset,
            sidebarWidth: sidebarWidth
        )
        withAnimation(.smooth(duration: resolvedDuration)) {
            self.offset = offset
        }
        return resolvedDuration
    }

    @discardableResult
    func animateSwitch(
        sourceRoot: String,
        targetRoot: String,
        direction: Int,
        sidebarWidth: CGFloat,
        duration: Double,
        activation: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard self.targetRoot == nil, direction != 0 else { return false }

        isAnimatingProgrammatically = true
        update(
            offset: 0,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            direction: direction
        )
        // Start the workspace/terminal handoff with the sidebar motion. Waiting
        // until the slide finished made one gesture read as two transitions:
        // first a sidebar swipe, then a delayed terminal replacement.
        let finalOffset = direction > 0 ? -sidebarWidth : sidebarWidth
        let resolvedDuration = settle(
            to: finalOffset,
            duration: duration,
            sidebarWidth: sidebarWidth
        )
        activation()

        let delayMilliseconds = Int64((resolvedDuration * 1_000).rounded(.up)) + 20
        programmaticTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            programmaticTransitionTask = nil
            isAnimatingProgrammatically = false
            clear()
        }
        return true
    }

    func reset() {
        programmaticTransitionTask?.cancel()
        programmaticTransitionTask = nil
        isAnimatingProgrammatically = false
        clear()
    }

    private func clear() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            sourceRoot = nil
            targetRoot = nil
            direction = 0
        }
    }
}

struct WorktreeSidebarSwipeMonitor: NSViewRepresentable {
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var swipeState: WorktreeSidebarSwipeState
    let sidebarWidth: CGFloat

    @AppStorage(WorktreeSwipeTuning.commitDistanceKey)
    private var commitDistance = WorktreeSwipeTuning.defaultCommitDistance
    @AppStorage(WorktreeSwipeTuning.settleDurationKey)
    private var settleDuration = WorktreeSwipeTuning.defaultSettleDuration

    func makeCoordinator() -> Coordinator {
        Coordinator(
            repository: repository,
            chromeState: chromeState,
            swipeState: swipeState,
            sidebarWidth: sidebarWidth,
            commitDistance: commitDistance,
            settleDuration: settleDuration
        )
    }

    func makeNSView(context: Context) -> SwipeTrackingView {
        let view = SwipeTrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SwipeTrackingView, context: Context) {
        context.coordinator.repository = repository
        context.coordinator.chromeState = chromeState
        context.coordinator.swipeState = swipeState
        context.coordinator.sidebarWidth = sidebarWidth
        context.coordinator.commitDistance = commitDistance
        context.coordinator.settleDuration = settleDuration
        nsView.coordinator = context.coordinator
    }

    final class SwipeTrackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.trackingView = self
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator {
        private struct VelocitySample {
            let timestamp: TimeInterval
            let offset: CGFloat
        }

        weak var repository: RepositoryWorkspace?
        weak var chromeState: ProjectWindowChromeState?
        weak var swipeState: WorktreeSidebarSwipeState?
        weak var trackingView: NSView?
        var sidebarWidth: CGFloat
        var commitDistance: Double
        var settleDuration: Double
        private nonisolated(unsafe) var monitor: Any?
        private var settleTask: Task<Void, Never>?
        private var idleSettleTask: Task<Void, Never>?
        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0
        private var velocitySamples: [VelocitySample] = []
        private var lastIntentDirection = 0
        private var lastDisplacementDirection = 0
        private var isHorizontal = false
        private var isSettling = false

        init(
            repository: RepositoryWorkspace,
            chromeState: ProjectWindowChromeState,
            swipeState: WorktreeSidebarSwipeState,
            sidebarWidth: CGFloat,
            commitDistance: Double,
            settleDuration: Double
        ) {
            self.repository = repository
            self.chromeState = chromeState
            self.swipeState = swipeState
            self.sidebarWidth = sidebarWidth
            self.commitDistance = commitDistance
            self.settleDuration = settleDuration
            install()
        }

        deinit {
            settleTask?.cancel()
            idleSettleTask?.cancel()
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return consumed ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let trackingView,
                  let window = trackingView.window,
                  event.window === window,
                  repository?.supportsWorktrees == true,
                  (repository?.visibleWorktrees.count ?? 0) > 1,
                  event.hasPreciseScrollingDeltas
            else {
                abortTransition()
                return false
            }

            let windowPoint = event.locationInWindow
            let localPoint = trackingView.convert(windowPoint, from: nil)
            guard trackingView.bounds.contains(localPoint) else {
                abortTransition()
                return false
            }

            if isSettling {
                return true
            }

            if swipeState?.isAnimatingProgrammatically == true {
                return true
            }

            if event.momentumPhase.contains(.began), isHorizontal {
                finishGesture(with: releaseDecision)
                return true
            }
            if !event.momentumPhase.isEmpty {
                return swipeState?.targetRoot != nil
            }

            if event.phase.contains(.began) {
                idleSettleTask?.cancel()
                idleSettleTask = nil
                resetGesture()
                swipeState?.reset()
                velocitySamples = [VelocitySample(timestamp: event.timestamp, offset: 0)]
            }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            recordVelocitySample(timestamp: event.timestamp)
            if !isHorizontal,
               abs(accumulatedX) > 6,
               abs(accumulatedX) > abs(accumulatedY) * 1.25 {
                isHorizontal = true
            }

            if isHorizontal {
                updateIntentDirection()
                updateInteractiveTransition()
                if WorktreeSwipeGesturePhase.shouldScheduleIdleFallback(for: event.phase) {
                    scheduleIdleSettlement(decision: releaseDecision)
                } else {
                    idleSettleTask?.cancel()
                    idleSettleTask = nil
                }
            }

            if event.phase.contains(.cancelled) {
                let consumed = isHorizontal
                if consumed {
                    settle(commit: false)
                }
                resetGesture()
                return consumed
            }

            if event.phase.contains(.ended) {
                let consumed = isHorizontal
                if consumed {
                    finishGesture(with: releaseDecision)
                } else {
                    resetGesture()
                }
                return consumed
            }
            return isHorizontal
        }

        private var completionThreshold: CGFloat {
            min(max(sidebarWidth, 1), max(1, CGFloat(commitDistance)))
        }

        private var releaseDecision: WorktreeSwipeReleaseDecision {
            WorktreeSwipeReleaseDecision.make(
                distance: accumulatedX,
                velocity: horizontalVelocity,
                lastIntentDirection: lastIntentDirection,
                threshold: completionThreshold
            )
        }

        private var horizontalVelocity: CGFloat {
            guard let first = velocitySamples.first,
                  let last = velocitySamples.last
            else {
                return 0
            }
            let elapsed = last.timestamp - first.timestamp
            guard elapsed >= 0.005 else { return 0 }
            return (last.offset - first.offset) / CGFloat(elapsed)
        }

        private func recordVelocitySample(timestamp: TimeInterval) {
            let sample = VelocitySample(timestamp: timestamp, offset: accumulatedX)
            velocitySamples.append(sample)

            let cutoff = timestamp - 0.10
            while velocitySamples.count > 2,
                  velocitySamples[1].timestamp < cutoff {
                velocitySamples.removeFirst()
            }
        }

        private func updateIntentDirection() {
            guard accumulatedX != 0 else { return }

            let velocity = horizontalVelocity
            if abs(velocity) >= 160 {
                lastIntentDirection = velocity < 0 ? 1 : -1
            }

            let displacementDirection = accumulatedX < 0 ? 1 : -1
            if lastDisplacementDirection != displacementDirection {
                lastIntentDirection = displacementDirection
                lastDisplacementDirection = displacementDirection
            }
        }

        private func updateInteractiveTransition() {
            guard let repository, let swipeState else { return }
            let direction = accumulatedX < 0 ? 1 : -1
            guard let target = repository.adjacentWorktree(offset: direction),
                  repository.prepareWorkspace(worktreeRoot: target.root) != nil
            else {
                return
            }
            let limit = max(sidebarWidth, 1)
            let offset = min(limit, max(-limit, accumulatedX))
            swipeState.update(
                offset: offset,
                sourceRoot: repository.activeWorktreeRoot,
                targetRoot: target.root,
                direction: direction
            )
        }

        private func settle(commit: Bool) {
            guard let swipeState else { return }
            idleSettleTask?.cancel()
            idleSettleTask = nil
            let targetRoot = swipeState.targetRoot
            let direction = swipeState.direction
            let finalOffset: CGFloat
            if commit, targetRoot != nil {
                finalOffset = direction > 0 ? -sidebarWidth : sidebarWidth
            } else {
                finalOffset = 0
            }

            isSettling = true
            let duration = swipeState.settle(
                to: finalOffset,
                duration: settleDuration,
                sidebarWidth: sidebarWidth
            )
            if commit, let targetRoot {
                _ = repository?.activate(
                    worktreeRoot: targetRoot,
                    chromeState: chromeState
                )
            }
            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self, weak swipeState] in
                let delayMilliseconds = Int64((max(0.01, duration) * 1_000).rounded(.up)) + 20
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled, let self else { return }
                swipeState?.reset()
                isSettling = false
                settleTask = nil
            }
        }

        private func finishGesture(with decision: WorktreeSwipeReleaseDecision) {
            let shouldCommit = decision.shouldCommit
                && retargetTransitionIfNeeded(direction: decision.direction)
            resetGesture()
            settle(commit: shouldCommit)
        }

        private func retargetTransitionIfNeeded(direction: Int) -> Bool {
            guard let repository,
                  let swipeState,
                  let target = repository.adjacentWorktree(offset: direction),
                  repository.prepareWorkspace(worktreeRoot: target.root) != nil
            else {
                return false
            }

            if swipeState.direction != direction || swipeState.targetRoot != target.root {
                swipeState.update(
                    offset: swipeState.offset,
                    sourceRoot: swipeState.sourceRoot ?? repository.activeWorktreeRoot,
                    targetRoot: target.root,
                    direction: direction
                )
            }
            return true
        }

        private func scheduleIdleSettlement(decision: WorktreeSwipeReleaseDecision) {
            idleSettleTask?.cancel()
            idleSettleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled,
                      let self,
                      isHorizontal,
                      !isSettling
                else {
                    return
                }
                finishGesture(with: decision)
            }
        }

        private func resetGesture() {
            accumulatedX = 0
            accumulatedY = 0
            velocitySamples.removeAll(keepingCapacity: true)
            lastIntentDirection = 0
            lastDisplacementDirection = 0
            isHorizontal = false
        }

        private func abortTransition() {
            guard swipeState?.isAnimatingProgrammatically != true else { return }
            settleTask?.cancel()
            settleTask = nil
            idleSettleTask?.cancel()
            idleSettleTask = nil
            isSettling = false
            resetGesture()
            swipeState?.reset()
        }
    }
}
