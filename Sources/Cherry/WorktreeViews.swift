import AppKit
import Combine
import SwiftUI

enum WorktreeSwipeTuning {
    static let commitDistanceKey = "worktrees.swipeCommitDistance"
    static let settleDurationKey = "worktrees.swipeSettleDuration"
    static let defaultCommitDistance = 64.0
    static let defaultSettleDuration = 0.20
    static let commitDistanceRange = 28.0...100.0
    static let settleDurationRange = 0.12...0.32
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

    @AppStorage(WorktreeSwipeTuning.commitDistanceKey)
    private var swipeCommitDistance = WorktreeSwipeTuning.defaultCommitDistance
    @AppStorage(WorktreeSwipeTuning.settleDurationKey)
    private var swipeSettleDuration = WorktreeSwipeTuning.defaultSettleDuration

    @State private var isNewWorktreePresented = false
    @State private var isManagerPresented = false
    @State private var isSwipeTuningPresented = false

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
                                openManager: { isManagerPresented = true }
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
                isNewWorktreePresented = true
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
                isManagerPresented = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Manage Worktrees")
            .accessibilityLabel("Manage Worktrees")

            Button {
                isSwipeTuningPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Tune Worktree Swipe")
            .accessibilityLabel("Tune Worktree Swipe")
            .popover(isPresented: $isSwipeTuningPresented) {
                WorktreeSwipeTuningPanel(
                    commitDistance: $swipeCommitDistance,
                    settleDuration: $swipeSettleDuration
                )
            }
        }
        .frame(height: 30)
        .sheet(isPresented: $isNewWorktreePresented) {
            NewWorktreeSheet(
                repository: repository,
                chromeState: chromeState,
                isPresented: $isNewWorktreePresented
            )
        }
        .sheet(isPresented: $isManagerPresented) {
            WorktreeManagerSheet(
                repository: repository,
                chromeState: chromeState,
                isPresented: $isManagerPresented
            )
        }
    }

    private func activeProgress(for worktree: GitWorktree) -> CGFloat {
        let isCurrent = worktree.root == repository.activeWorktreeRoot
        guard let targetRoot = swipeState.targetRoot else {
            return isCurrent ? 1 : 0
        }
        guard targetRoot != repository.activeWorktreeRoot else {
            return isCurrent ? 1 : 0
        }

        let progress = min(1, max(0, abs(swipeState.offset) / max(sidebarWidth, 1)))
        if isCurrent { return 1 - progress }
        if worktree.root == targetRoot { return progress }
        return 0
    }
}

private struct WorktreeSwipeTuningPanel: View {
    @Binding var commitDistance: Double
    @Binding var settleDuration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Swipe Tuning")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button("Reset") {
                    commitDistance = WorktreeSwipeTuning.defaultCommitDistance
                    settleDuration = WorktreeSwipeTuning.defaultSettleDuration
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }

            tuningRow(
                "Trigger",
                value: $commitDistance,
                range: WorktreeSwipeTuning.commitDistanceRange,
                step: 4,
                formattedValue: "\(Int(commitDistance.rounded())) pt"
            )

            tuningRow(
                "Settle",
                value: $settleDuration,
                range: WorktreeSwipeTuning.settleDurationRange,
                step: 0.02,
                formattedValue: "\(Int((settleDuration * 1_000).rounded())) ms"
            )

            Text("Lower trigger distances switch sooner. Fast flicks also project their velocity forward.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }

    private func tuningRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formattedValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                Text(formattedValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
        }
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

struct WorktreeManagerSheet: View {
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @Binding var isPresented: Bool

    @State private var removalCandidate: GitWorktree?
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worktrees")
                    .font(.title2.weight(.semibold))
                Text("Manage isolated checkouts for \(repository.repositoryName).")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeManagerRow(
                            worktree: worktree,
                            repository: repository,
                            chromeState: chromeState,
                            remove: { removalCandidate = worktree }
                        )
                        if worktree.id != repository.worktrees.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(height: 340)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Refresh") {
                    Task { await repository.refresh() }
                }
                .disabled(repository.isRefreshing || isRemoving)

                if repository.worktrees.contains(where: \.isPrunable) {
                    Button("Prune Stale Entries") {
                        prune()
                    }
                    .disabled(isRemoving)
                }

                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 650)
        .alert(
            "Remove Worktree?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            presenting: removalCandidate
        ) { worktree in
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
            Button("Remove Worktree", role: .destructive) {
                remove(worktree)
            }
        } message: { worktree in
            Text("Cherry will remove the checkout at \(worktree.root). The branch will be kept.")
        }
    }

    private func remove(_ worktree: GitWorktree) {
        isRemoving = true
        errorMessage = nil
        Task {
            defer {
                isRemoving = false
                removalCandidate = nil
            }
            do {
                try await repository.remove(worktree, chromeState: chromeState)
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
    let worktree: GitWorktree
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: worktree.isDetached ? "point.3.connected.trianglepath.dotted" : "rectangle.stack")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    ForEach(statusLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(worktree.root)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if repository.hiddenWorktreeRoots.contains(worktree.root) {
                Button("Show") {
                    repository.show(worktree)
                }
            } else if !worktree.isMain {
                Button("Hide") {
                    repository.hide(worktree, chromeState: chromeState)
                }
            }

            Button(worktree.root == repository.activeWorktreeRoot ? "Current" : "Open") {
                _ = repository.activate(
                    worktreeRoot: worktree.root,
                    chromeState: chromeState
                )
            }
            .disabled(worktree.root == repository.activeWorktreeRoot || worktree.isPrunable)

            Button("Remove", role: .destructive, action: remove)
                .disabled(!canRemove)
                .help(removalHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var runningProcessCount: Int {
        repository.workspaceIfLoaded(for: worktree.root)?.sessionsWithRunningProcess().count ?? 0
    }

    private var canRemove: Bool {
        !worktree.isMain
            && !worktree.isLocked
            && !worktree.isPrunable
            && repository.dirtyByRoot[worktree.root] == false
            && runningProcessCount == 0
    }

    private var statusLabels: [String] {
        var result: [String] = []
        if worktree.isMain { result.append("Primary") }
        if worktree.root == repository.activeWorktreeRoot { result.append("Current") }
        if worktree.isDetached { result.append("Detached") }
        if repository.loadedWorktreeRoots.contains(worktree.root) { result.append("Loaded") }
        if repository.hiddenWorktreeRoots.contains(worktree.root) { result.append("Hidden") }
        if repository.dirtyByRoot[worktree.root] == true { result.append("Modified") }
        if runningProcessCount > 0 { result.append("Busy") }
        if worktree.isLocked { result.append("Locked") }
        if worktree.isPrunable { result.append("Missing") }
        return result
    }

    private var removalHelp: String {
        if worktree.isMain { return "The primary checkout cannot be removed." }
        if worktree.isLocked { return "Unlock this worktree in Git before removing it." }
        if worktree.isPrunable { return "Prune the stale Git entry instead." }
        if repository.dirtyByRoot[worktree.root] == true { return "Clean modified and untracked files before removing it." }
        if repository.dirtyByRoot[worktree.root] == nil { return "Cherry is still checking this worktree." }
        if runningProcessCount > 0 { return "Stop foreground processes before removing it." }
        return "Remove the checkout and keep its branch."
    }
}

@MainActor
final class WorktreeSidebarSwipeState: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var targetRoot: String?
    @Published private(set) var direction = 0
    private(set) var isAnimatingProgrammatically = false

    private var programmaticTransitionTask: Task<Void, Never>?

    func update(offset: CGFloat, targetRoot: String, direction: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.offset = offset
            self.targetRoot = targetRoot
            self.direction = direction
        }
    }

    func settle(to offset: CGFloat, duration: Double) {
        withAnimation(.smooth(duration: max(0.01, duration))) {
            self.offset = offset
        }
    }

    @discardableResult
    func animateSwitch(
        targetRoot: String,
        direction: Int,
        sidebarWidth: CGFloat,
        duration: Double,
        activation: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard self.targetRoot == nil, direction != 0 else { return false }

        isAnimatingProgrammatically = true
        update(offset: 0, targetRoot: targetRoot, direction: direction)
        let finalOffset = direction > 0 ? -sidebarWidth : sidebarWidth
        settle(to: finalOffset, duration: duration)

        let delayMilliseconds = Int64((max(0.01, duration) * 1_000).rounded(.up)) + 20
        programmaticTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            activation()
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
            let duration = settleDuration
            swipeState.settle(to: finalOffset, duration: duration)
            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self, weak swipeState] in
                let delayMilliseconds = Int64((max(0.01, duration) * 1_000).rounded(.up)) + 20
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled, let self else { return }
                if commit, let targetRoot {
                    _ = repository?.activate(
                        worktreeRoot: targetRoot,
                        chromeState: chromeState
                    )
                }
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
