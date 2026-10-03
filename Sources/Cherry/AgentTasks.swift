import CherryControl
import Combine
import Foundation

// MARK: - Tasks
//
// An orchestrating agent hands work to worker agents as tasks (docs/mcp.md,
// Tasks and results): MCP `spawn_agent` with `task` opens an ordinary,
// visible agent tab nested under the orchestrator, records the task in a
// run, and types a one-line kickoff into the worker once it is ready. The
// worker reads its brief with `get_my_task` and answers with
// `report_result`, which Cherry checks against the task's result schema;
// the worker is always the caller's own tab (`verifiedCallerSession`),
// never a selector. The orchestrator waits with `wait_for_tasks`, or ends
// its turn: once every task of its run settled and it is idle, Cherry types
// one line into its tab (counts and the run id only, never a worker's
// text), as monitors' wake lines do.
//
// `report_result` is the signal. A worker that goes idle after its turn
// without reporting is asked once ("Please call report_result with your
// result."); idle again without a report, its task is `no_report`, with its
// screen's last lines as the result. The monitor sampler watches open tasks
// (`sampleTasks`), so tasks reuse its refresh throttle, status and idle
// rules.
//
// Records live in memory, in the control server, each tied to its worker's
// tab and window: a relaunch of Cherry forgets them (a restored worker's
// `get_my_task` answers `no_assignment`). Tasks are one level deep (a
// worker cannot hand out tasks), and a caller on another Mac reaches only
// the tasks its Mac's callers made.

/// One task (main actor only).
@MainActor
final class AgentTask {
    let id: String
    let runID: String
    /// The Mac of the caller that made it, nil for This Mac: only callers
    /// of that Mac find it.
    let device: UUID?
    let workerID: UUID
    weak var worker: TerminalSession?
    weak var workspace: TerminalWorkspace?
    let label: String
    let phase: String?
    let brief: String
    let resultSchema: JSONValue?
    let createdAt = Date()
    var state: AgentTaskState = .queued
    var startedAt: Date?
    var settledAt: Date?
    var reason: String?
    var result: AgentTaskResult?
    var progress: String?
    var progressAt: Date?

    /// The kickoff reached the worker (or it found its task by itself).
    var kickoffDeliveredAt: Date?
    var kickoffAttempts = 0
    var lastKickoffAttemptAt: Date?
    /// The last kickoff did not reach the worker and nothing of it was
    /// typed: it may be typed again.
    var kickoffRetryable = false
    /// Cherry is typing into the worker (a kickoff or the nudge).
    var isTypingIntoWorker = false
    /// Since when the worker's current turn for the task runs (the
    /// kickoff's, then the nudge's), and its turn count then.
    var turnBaselineAt: Date?
    var turnBaseline = 0
    var nudgedAt: Date?
    var lastNudgeAttemptAt: Date?

    init(
        id: String,
        runID: String,
        device: UUID?,
        worker: TerminalSession,
        workspace: TerminalWorkspace,
        label: String,
        phase: String?,
        brief: String,
        resultSchema: JSONValue?
    ) {
        self.id = id
        self.runID = runID
        self.device = device
        self.workerID = worker.id
        self.worker = worker
        self.workspace = workspace
        self.label = label
        self.phase = phase
        self.brief = brief
        self.resultSchema = resultSchema
    }

    var kickoffLine: String { AgentTaskRegistry.kickoffLine(taskID: id) }
}

/// The tasks one orchestrator handed out together (main actor only).
@MainActor
final class AgentRun {
    let id: String
    let device: UUID?
    /// Whose run it is: the orchestrator's tab Cherry confirmed made it,
    /// else the workers' parent agent; nil when neither is known.
    let ownerID: UUID?
    /// The orchestrator's tab, only when Cherry confirmed it is the caller
    /// that made the run: the wake line goes there, and only to an agent.
    weak var owner: TerminalSession?
    /// Made for its owner's spawns that named no run.
    let isImplicit: Bool
    let createdAt = Date()
    var taskIDs: [String] = []
    /// The event at which every task of it settled; nil while one is open.
    var settledSeq: Int?
    var settledAt: Date?
    /// The settle its wake line was typed for (or given up on).
    var wokenSeq = 0
    /// The settle its owner read with `wait_for_tasks`: no wake line then.
    var ownerReadSeq = 0
    var lastWakeAt: Date?
    var isWaking = false
    /// `wait_for_tasks` calls on it now: no wake line while one runs.
    var activeWaits = 0

    init(id: String, device: UUID?, ownerID: UUID?, owner: TerminalSession?, isImplicit: Bool) {
        self.id = id
        self.device = device
        self.ownerID = ownerID
        self.owner = owner
        self.isImplicit = isImplicit
    }

    /// A wake line can be typed into its owner (an agent tab Cherry
    /// confirmed).
    var wakes: Bool { owner?.kind == .agent }
}

/// The tasks and runs of one control server.
@MainActor
final class AgentTaskRegistry {
    static let maximumTasks = 1_000
    static let maximumEvents = 5_000
    static let maximumBriefCharacters = 64_000
    static let maximumResultBytes = 256 * 1024
    static let maximumKickoffAttempts = 3
    /// The screen's last lines a `no_report` (or an exit) keeps.
    static let screenTailLines = 40
    static let screenTailCharacters = 4_000
    /// Typed once into a worker that went idle without reporting.
    static let nudgeLine = "Please call report_result with your result."

    let board: AgentTaskBoard
    private(set) var tasks: [String: AgentTask] = [:]
    private(set) var taskOrder: [String] = []
    private(set) var runs: [String: AgentRun] = [:]
    private(set) var runOrder: [String] = []
    private(set) var events: [AgentTaskEvent] = []
    private(set) var nextSeq = 1
    /// Settings › MCP › Wake idle agents (the server's monitors' setting).
    var wakeLinesEnabled: @MainActor () -> Bool = { true }

    // Tunables (tests shorten them).
    /// At most one progress message is recorded this often.
    var progressInterval: TimeInterval = 5
    /// An idle worker whose turn showed no work is taken as done with that
    /// turn this long after it was submitted.
    var idleFallbackInterval: TimeInterval = 30
    var kickoffRetryInterval: TimeInterval = 5
    /// A settled run's wake line is given up after this long.
    var wakeLifetime: TimeInterval = 60 * 60

    init(board: AgentTaskBoard) {
        self.board = board
    }

    static func newID(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    /// One line, typed into the worker as its first message.
    static func kickoffLine(taskID: String) -> String {
        "You are Cherry task \(taskID): call get_my_task (Cherry MCP) for your brief, do it, then call report_result. "
            + "Without Cherry MCP tools, run \"$CHERRY_MCP_HELPER\" --call get_my_task, then "
            + "\"$CHERRY_MCP_HELPER\" --call report_result '{\"value\":…,\"status\":\"ok\",\"summary\":\"…\"}'."
    }

    /// What `get_my_task` tells every worker.
    static let workerRules = [
        "Do the brief in this tab. Don't hand parts of it to other agents: Cherry tasks are one level deep.",
        "Finish with report_result: value (matching result_schema when there is one), status ok or failed, and a summary of at most \(CherryControl.maximumTaskSummaryCharacters) characters.",
        "If you cannot finish, report status failed with the reason in summary rather than waiting for an answer.",
        "For long work you may call report_progress with a short message (at most one every few seconds is kept).",
        "If you get more instructions in this tab later, report again: the newest report replaces the earlier one.",
        "Without Cherry MCP tools, run \"$CHERRY_MCP_HELPER\" --call get_my_task and \"$CHERRY_MCP_HELPER\" --call report_result '<JSON arguments>' in a shell.",
    ]

    /// The run's wake line: its id and counts, never a worker's text.
    static func wakeLine(runID: String, counts: AgentRunCounts) -> String {
        let parts = [
            (counts.reported, "reported"), (counts.failed, "failed"),
            (counts.noReport, "no report"), (counts.cancelled, "cancelled"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let noun = counts.total == 1 ? "task" : "tasks"
        return "[cherry] Run \(runID): \(counts.total) \(noun) settled (\(parts.joined(separator: ", "))). Call the cherry wait_for_tasks tool with run_id \"\(runID)\" to read them, and get_task for each result."
    }

    // MARK: Lookup

    /// The worker's task (its latest, should it have had several).
    func latestTask(forWorker id: UUID) -> AgentTask? {
        for taskID in taskOrder.reversed() {
            if let task = tasks[taskID], task.workerID == id { return task }
        }
        return nil
    }

    /// The task `id`, when a caller of `device` may see it.
    func task(_ id: String, device: UUID?) -> AgentTask? {
        tasks[id.trimmingCharacters(in: .whitespacesAndNewlines)].flatMap { $0.device == device ? $0 : nil }
    }

    func run(_ id: String, device: UUID?) -> AgentRun? {
        runs[id.trimmingCharacters(in: .whitespacesAndNewlines)].flatMap { $0.device == device ? $0 : nil }
    }

    func tasks(of run: AgentRun) -> [AgentTask] {
        run.taskIDs.compactMap { tasks[$0] }
    }

    var orderedRuns: [AgentRun] {
        runOrder.compactMap { runs[$0] }
    }

    func runs(ownedBy ownerID: UUID, device: UUID?) -> [AgentRun] {
        orderedRuns.filter { $0.ownerID == ownerID && $0.device == device }
    }

    func isOpen(_ run: AgentRun) -> Bool {
        run.taskIDs.isEmpty || tasks(of: run).contains { !$0.state.isSettled }
    }

    /// The owner's run that its spawns without a run id join: its latest
    /// implicit run while a task of it is open, else none (a new one).
    func currentImplicitRun(ownerID: UUID?, device: UUID?) -> AgentRun? {
        guard let ownerID else { return nil }
        return orderedRuns.last { $0.isImplicit && $0.ownerID == ownerID && $0.device == device && isOpen($0) }
    }

    var openTasks: [AgentTask] {
        taskOrder.compactMap { tasks[$0] }.filter { !$0.state.isSettled }
    }

    /// Settled runs whose wake line is still to be typed.
    var runsAwaitingWake: [AgentRun] {
        orderedRuns.filter(awaitsWake)
    }

    func awaitsWake(_ run: AgentRun) -> Bool {
        guard run.wakes, let settledSeq = run.settledSeq else { return false }
        return settledSeq > run.wokenSeq && settledSeq > run.ownerReadSeq
    }

    /// The sampler is needed: a task is open, or a settled run's wake line
    /// is still to be typed.
    var needsSampling: Bool {
        tasks.values.contains { !$0.state.isSettled } || (wakeLinesEnabled() && runs.values.contains(where: awaitsWake))
    }

    /// The first event still kept.
    var firstKeptSeq: Int { events.first?.seq ?? nextSeq }

    // MARK: Changes

    func addRun(device: UUID?, ownerID: UUID?, owner: TerminalSession?, isImplicit: Bool) -> AgentRun {
        let run = AgentRun(id: Self.newID("run"), device: device, ownerID: ownerID, owner: owner, isImplicit: isImplicit)
        runs[run.id] = run
        runOrder.append(run.id)
        return run
    }

    func add(_ task: AgentTask, to run: AgentRun) {
        tasks[task.id] = task
        taskOrder.append(task.id)
        run.taskIDs.append(task.id)
        record(.queued, for: task)
        settleCheck(run, seq: nextSeq - 1)
        prune()
        publish()
    }

    @discardableResult
    func record(_ kind: AgentTaskEventKind, for task: AgentTask, text: String? = nil, version: Int? = nil) -> AgentTaskEvent {
        let event = AgentTaskEvent(
            seq: nextSeq,
            taskID: task.id,
            runID: task.runID,
            processID: task.workerID.uuidString,
            kind: kind,
            state: task.state,
            label: task.label,
            phase: task.phase,
            at: Date(),
            text: text,
            version: version
        )
        nextSeq += 1
        events.append(event)
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
        return event
    }

    /// Moves `task` to `state` and records `kind`.
    func update(
        _ task: AgentTask,
        to state: AgentTaskState,
        event kind: AgentTaskEventKind,
        text: String? = nil,
        result: AgentTaskResult? = nil,
        reason: String? = nil
    ) {
        let now = Date()
        if let result { task.result = result }
        if let reason {
            task.reason = reason
        } else if result?.source == "report_result" {
            task.reason = nil
        }
        if [.working, .needsInput, .reported, .failed].contains(state), task.startedAt == nil { task.startedAt = now }
        task.state = state
        task.settledAt = state.isSettled ? (task.settledAt ?? now) : nil
        if state.isSettled, kind.settles { task.settledAt = now }
        let event = record(kind, for: task, text: text, version: result?.version)
        if let run = runs[task.runID] { settleCheck(run, seq: event.seq) }
        publish()
    }

    /// Notes the event at which every task of `run` settled (or that one
    /// is open again).
    private func settleCheck(_ run: AgentRun, seq: Int) {
        if !isOpen(run) {
            if run.settledSeq == nil {
                run.settledSeq = seq
                run.settledAt = Date()
            }
        } else {
            run.settledSeq = nil
            run.settledAt = nil
        }
    }

    /// Forgets the oldest settled tasks past `maximumTasks`, and runs left
    /// without tasks.
    func prune() {
        guard taskOrder.count > Self.maximumTasks else { return }
        var excess = taskOrder.count - Self.maximumTasks
        var kept: [String] = []
        for id in taskOrder {
            if excess > 0, let task = tasks[id], task.state.isSettled {
                tasks[id] = nil
                excess -= 1
            } else {
                kept.append(id)
            }
        }
        taskOrder = kept
        for run in orderedRuns where run.taskIDs.allSatisfy({ tasks[$0] == nil }) && !run.taskIDs.isEmpty {
            runs[run.id] = nil
        }
        runOrder.removeAll { runs[$0] == nil }
    }

    // MARK: Reports

    func info(for task: AgentTask) -> AgentTaskInfo {
        AgentTaskInfo(
            taskID: task.id,
            runID: task.runID,
            processID: task.workerID.uuidString,
            label: task.label,
            phase: task.phase,
            state: task.state,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            settledAt: task.settledAt,
            progress: task.progress,
            progressAt: task.progressAt,
            resultStatus: task.result?.status,
            resultSummary: task.result?.summary,
            resultVersion: task.result?.version,
            nudged: task.nudgedAt != nil,
            reason: task.reason
        )
    }

    func detail(for task: AgentTask) -> AgentTaskDetail {
        AgentTaskDetail(task: info(for: task), brief: task.brief, resultSchema: task.resultSchema, result: task.result)
    }

    func counts(of run: AgentRun) -> AgentRunCounts {
        AgentRunCounts(states: tasks(of: run).map(\.state))
    }

    func info(for run: AgentRun) -> AgentRunInfo {
        AgentRunInfo(
            runID: run.id,
            ownerProcessID: run.ownerID?.uuidString,
            createdAt: run.createdAt,
            counts: counts(of: run),
            settled: !isOpen(run),
            wake: run.wakes && wakeLinesEnabled()
        )
    }

    // MARK: The sidebar

    /// Hands the sidebar each worker's task state and each owner's open
    /// runs' progress.
    func publish() {
        var badges: [UUID: AgentTaskBadge] = [:]
        for id in taskOrder {
            guard let task = tasks[id] else { continue }
            badges[task.workerID] = AgentTaskBadge(
                state: task.state,
                label: task.label,
                phase: task.phase,
                summary: task.result?.summary ?? task.reason
            )
        }
        var progress: [UUID: AgentRunProgress] = [:]
        for run in orderedRuns {
            guard let ownerID = run.ownerID, isOpen(run), !run.taskIDs.isEmpty else { continue }
            let counts = counts(of: run)
            let current = progress[ownerID] ?? AgentRunProgress(settled: 0, total: 0)
            progress[ownerID] = AgentRunProgress(settled: current.settled + counts.settled, total: current.total + counts.total)
        }
        board.update(badges: badges, runProgress: progress)
    }
}

/// A worker's task as its sidebar row shows it.
struct AgentTaskBadge: Equatable {
    var state: AgentTaskState
    var label: String
    var phase: String?
    /// The result's summary, or why it settled without one.
    var summary: String?
}

/// An orchestrator's open runs: how many of their tasks settled.
struct AgentRunProgress: Equatable {
    var settled: Int
    var total: Int

    var text: String { "\(settled)/\(total)" }
}

/// What the sidebar shows of tasks: the app's control server writes it
/// (tests give their servers their own).
@MainActor
final class AgentTaskBoard: ObservableObject {
    static let shared = AgentTaskBoard()

    /// By worker tab.
    @Published private(set) var badges: [UUID: AgentTaskBadge] = [:]
    /// By orchestrator tab, while one of its runs is open.
    @Published private(set) var runProgress: [UUID: AgentRunProgress] = [:]

    func update(badges: [UUID: AgentTaskBadge], runProgress: [UUID: AgentRunProgress]) {
        if self.badges != badges { self.badges = badges }
        if self.runProgress != runProgress { self.runProgress = runProgress }
    }
}

extension AgentTaskState {
    /// The sidebar's name for it.
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .working: "Working"
        case .needsInput: "Needs you"
        case .reported: "Reported"
        case .noReport: "No report"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    /// The sidebar's glyph for it (an SF Symbol).
    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .working: "ellipsis.circle"
        case .needsInput: "exclamationmark.circle.fill"
        case .reported: "checkmark.circle.fill"
        case .noReport: "questionmark.circle"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }
}

// MARK: - Requests

extension CherryControlServer {
    /// A task's spawn, checked before its worker is made.
    struct TaskSpawnPlan {
        var brief: String
        var label: String
        var phase: String?
        var resultSchema: JSONValue?
        /// The run named by `run_id`; nil for the owner's current run.
        var run: AgentRun?
        var device: UUID?
        var ownerID: UUID?
        var owner: TerminalSession?
    }

    static func noAssignment(_ message: String) -> CherryControlError {
        CherryControlError(code: "no_assignment", message: message)
    }

    @MainActor
    static func taskCancelled(_ task: AgentTask) -> CherryControlError {
        CherryControlError(
            code: "task_cancelled",
            message: "Cherry task \(task.id) was cancelled\(task.reason.map { ": \($0)" } ?? "."). Stop working on it; nothing more is recorded for it."
        )
    }

    static func unknownTask(_ id: String) -> CherryControlError {
        CherryControlError(
            code: "unknown_task",
            message: "No Cherry task \(id) this caller can see: tasks live in Cherry's memory, so a relaunch forgets them."
        )
    }

    static func unknownRun(_ id: String) -> CherryControlError {
        CherryControlError(
            code: "unknown_run",
            message: "No Cherry run \(id) this caller can use: tasks live in Cherry's memory, so a relaunch forgets them."
        )
    }

    /// Checks a spawn's task (nil without one): the brief, that it is not
    /// also given a message, the schema (linted here, before anything is
    /// spawned), the run, and that the caller is not itself a worker.
    @MainActor
    func prepareTaskSpawn(_ request: SpawnProcessRequest, parentAgentID: UUID?, workspace: TerminalWorkspace) throws -> TaskSpawnPlan? {
        guard let rawTask = request.task else {
            if request.label != nil || request.phase != nil || request.runID != nil || request.resultSchema != nil {
                throw CherryControlError(
                    code: "invalid_process_request",
                    message: "label, phase, run_id and result_schema go with task."
                )
            }
            return nil
        }
        let brief = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else {
            throw CherryControlError(code: "invalid_process_request", message: "task is empty: give the worker its brief.")
        }
        guard brief.count <= AgentTaskRegistry.maximumBriefCharacters else {
            throw CherryControlError(
                code: "invalid_process_request",
                message: "task is longer than \(AgentTaskRegistry.maximumBriefCharacters) characters: put the details in a file and name it in the brief."
            )
        }
        guard request.text == nil, request.rawBase64 == nil else {
            throw CherryControlError(
                code: "invalid_process_request",
                message: "Pass the brief as task or a first message as message, not both: a task's worker reads its brief with get_my_task."
            )
        }
        if let schema = request.resultSchema {
            let problems = TaskResultSchema.lint(schema)
            guard problems.isEmpty else {
                throw CherryControlError(
                    code: "invalid_result_schema",
                    message: "Cherry cannot check results against result_schema: \(problems.prefix(3).joined(separator: "; ")). Nothing was spawned.",
                    details: problems
                )
            }
        }
        let device = Self.remoteDevice
        let caller = verifiedCallerSession()
        if let caller, let callerTask = tasks.latestTask(forWorker: caller.id), !callerTask.state.isSettled {
            throw CherryControlError(
                code: "nested_task",
                message: "This agent is the worker of Cherry task \(callerTask.id) and cannot hand out tasks itself: Cherry tasks are one level deep. Do the work, or say in report_result how it should be split."
            )
        }
        let ownerID = caller?.id ?? parentAgentID
        var run: AgentRun?
        if let runID = request.runID?.trimmingCharacters(in: .whitespacesAndNewlines), !runID.isEmpty {
            guard let existing = tasks.run(runID, device: device),
                  existing.ownerID == nil || existing.ownerID == ownerID
            else { throw Self.unknownRun(runID) }
            run = existing
        }
        let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.defaultTaskLabel(brief)
        return TaskSpawnPlan(
            brief: brief,
            label: String(label.prefix(80)),
            phase: request.phase?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(60)) },
            resultSchema: request.resultSchema,
            run: run,
            device: device,
            ownerID: ownerID,
            owner: caller
        )
    }

    /// The first words of the brief's first line.
    nonisolated static func defaultTaskLabel(_ brief: String) -> String {
        let firstLine = brief.split(whereSeparator: \.isNewline).first.map(String.init) ?? brief
        let words = firstLine.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.count > 40 ? String(words.prefix(39)) + "…" : words
    }

    /// Records the task of the worker just spawned for `plan`.
    @MainActor
    func registerTask(_ plan: TaskSpawnPlan, worker: TerminalSession, workspace: TerminalWorkspace) -> AgentTask {
        let run = plan.run
            ?? tasks.currentImplicitRun(ownerID: plan.ownerID, device: plan.device)
            ?? tasks.addRun(device: plan.device, ownerID: plan.ownerID, owner: plan.owner, isImplicit: true)
        let task = AgentTask(
            id: AgentTaskRegistry.newID("task"),
            runID: run.id,
            device: plan.device,
            worker: worker,
            workspace: workspace,
            label: plan.label,
            phase: plan.phase,
            brief: plan.brief,
            resultSchema: plan.resultSchema
        )
        tasks.add(task, to: run)
        startMonitorSamplerIfNeeded()
        return task
    }

    /// What became of a kickoff typed at `typedSince`.
    @MainActor
    func noteKickoff(_ task: AgentTask, delivered: Bool, error: CherryControlError?, typedSince: Date = Date()) {
        task.kickoffAttempts += 1
        task.lastKickoffAttemptAt = Date()
        if delivered, let worker = task.worker {
            task.kickoffDeliveredAt = Date()
            task.kickoffRetryable = false
            task.turnBaselineAt = typedSince
            task.turnBaseline = worker.agentSubmittedTurnCount
        } else {
            // Typed again once the worker takes input, unless some of it
            // may have been typed.
            let nothingSent: Set<String> = [
                "agent_awaiting_permission", "agent_awaiting_input", "process_not_accepting_input", "input_not_delivered",
            ]
            task.kickoffRetryable = nothingSent.contains(error?.code ?? "")
        }
        startMonitorSamplerIfNeeded()
    }

    // MARK: Worker side

    /// The caller's own tab's task.
    @MainActor
    private func callerTask() throws -> AgentTask {
        guard let caller = verifiedCallerSession() else {
            throw Self.noAssignment(
                "Cherry could not tell which of its tabs this MCP session runs in, so it has no task for it. Run CherryMCP inside the agent's own Cherry tab (as its MCP server, or \"$CHERRY_MCP_HELPER\" --call from its shell)."
            )
        }
        guard let task = tasks.latestTask(forWorker: caller.id) else {
            throw Self.noAssignment("This tab has no Cherry task: only agents spawned with spawn_agent's task have one (Cherry forgets tasks when it relaunches).")
        }
        return task
    }

    @MainActor
    func getMyTask() throws -> GetMyTaskResult {
        let task = try callerTask()
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        if task.kickoffDeliveredAt == nil {
            // It found its task by itself: no kickoff is typed any more.
            task.kickoffDeliveredAt = Date()
            task.turnBaselineAt = task.turnBaselineAt ?? Date()
            task.turnBaseline = task.worker?.agentSubmittedTurnCount ?? 0
        }
        if task.state == .queued {
            tasks.update(task, to: .working, event: .started)
        }
        return GetMyTaskResult(
            taskID: task.id,
            runID: task.runID,
            label: task.label,
            phase: task.phase,
            brief: task.brief,
            resultSchema: task.resultSchema,
            rules: AgentTaskRegistry.workerRules,
            state: task.state,
            resultVersion: task.result?.version ?? 0
        )
    }

    @MainActor
    func reportResult(_ request: ReportResultRequest) throws -> ReportResultResult {
        let task = try callerTask()
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        let status = (request.status ?? "ok").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "ok" || status == "failed" else {
            throw CherryControlError(code: "invalid_argument", message: "status is ok or failed, not \(request.status ?? "").")
        }
        var value = request.value
        // Some clients declare an argument without a type a string (Codex):
        // JSON text of an object or array is taken as that value when it
        // matches the schema (or there is none).
        let parsed: JSONValue? = {
            guard case .string(let text)? = request.value,
                  let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "{" || first == "["
            else { return nil }
            return try? JSONValue.parse(Data(text.utf8))
        }()
        if let parsed, task.resultSchema == nil { value = parsed }
        if status == "ok", let schema = task.resultSchema {
            var problems = TaskResultSchema.validate(value ?? .null, against: schema)
            if !problems.isEmpty, let parsed, TaskResultSchema.validate(parsed, against: schema).isEmpty {
                value = parsed
                problems = []
            }
            guard problems.isEmpty else {
                throw CherryControlError(
                    code: "schema_mismatch",
                    message: "value does not match task \(task.id)'s result_schema (nothing was recorded): \(problems.prefix(5).joined(separator: "; ")). Fix it and call report_result again.",
                    details: problems
                )
            }
        }
        if let value, value.encodedByteCount > AgentTaskRegistry.maximumResultBytes {
            throw CherryControlError(
                code: "result_too_large",
                message: "value is larger than \(AgentTaskRegistry.maximumResultBytes) bytes: write the details to a file and report its path."
            )
        }
        let trimmed = request.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let limit = CherryControl.maximumTaskSummaryCharacters
        let summary = trimmed.map { $0.count > limit ? String($0.prefix(limit - 1)) + "…" : $0 }
        let version = (task.result?.version ?? 0) + 1
        let result = AgentTaskResult(
            value: value,
            status: status,
            summary: summary,
            version: version,
            reportedAt: Date(),
            source: "report_result"
        )
        let state: AgentTaskState = status == "ok" ? .reported : .failed
        tasks.update(task, to: state, event: state == .reported ? .reported : .failed, text: summary, result: result)
        return ReportResultResult(
            taskID: task.id,
            runID: task.runID,
            version: version,
            state: task.state,
            summaryTruncated: (trimmed?.count ?? 0) > limit
        )
    }

    @MainActor
    func reportProgress(_ request: ReportProgressRequest) throws -> ReportProgressResult {
        let task = try callerTask()
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        let oneLine = request.message
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else {
            throw CherryControlError(code: "invalid_argument", message: "message is empty.")
        }
        let now = Date()
        if let last = task.progressAt, now.timeIntervalSince(last) < tasks.progressInterval {
            let wait = tasks.progressInterval - now.timeIntervalSince(last)
            return ReportProgressResult(taskID: task.id, recorded: false, retryAfterMilliseconds: Int((wait * 1_000).rounded(.up)))
        }
        let limit = CherryControl.maximumTaskProgressCharacters
        let message = oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine
        task.progress = message
        task.progressAt = now
        if task.state == .queued {
            tasks.update(task, to: .working, event: .started)
        }
        tasks.record(.progress, for: task, text: message)
        tasks.publish()
        return ReportProgressResult(taskID: task.id, recorded: true)
    }

    // MARK: Orchestrator side

    /// The tasks a request names: a run, task ids, or (neither) the
    /// caller's own runs, open ones first.
    @MainActor
    private func taskSelection(runID: String?, taskIDs: [String]?, defaultingToCallers: Bool) throws -> (runs: [AgentRun], tasks: [AgentTask]) {
        let device = Self.remoteDevice
        var selectedRuns: [AgentRun] = []
        var selectedTasks: [AgentTask] = []
        if let runID = runID?.trimmingCharacters(in: .whitespacesAndNewlines), !runID.isEmpty {
            guard let run = tasks.run(runID, device: device) else { throw Self.unknownRun(runID) }
            selectedRuns.append(run)
        }
        for rawID in taskIDs ?? [] {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            guard let task = tasks.task(id, device: device) else { throw Self.unknownTask(id) }
            if !selectedTasks.contains(where: { $0 === task }) { selectedTasks.append(task) }
        }
        if selectedRuns.isEmpty, selectedTasks.isEmpty {
            guard defaultingToCallers, let caller = verifiedCallerSession() else {
                throw CherryControlError(code: "missing_argument", message: "Name the tasks with run_id or task_ids (spawn_agent returns them).")
            }
            let owned = tasks.runs(ownedBy: caller.id, device: device)
            let open = owned.filter { tasks.isOpen($0) }
            selectedRuns = open.isEmpty ? owned.suffix(1) : open
            guard !selectedRuns.isEmpty else {
                throw CherryControlError(code: "missing_argument", message: "This caller has no Cherry runs: name the tasks with run_id or task_ids.")
            }
        }
        return (selectedRuns, selectedTasks)
    }

    @MainActor
    private func selectedTasks(_ selection: (runs: [AgentRun], tasks: [AgentTask])) -> [AgentTask] {
        var result = selection.tasks
        for run in selection.runs {
            for task in tasks.tasks(of: run) where !result.contains(where: { $0 === task }) {
                result.append(task)
            }
        }
        return result
    }

    @MainActor
    func waitForTasks(_ request: WaitForTasksRequest) async throws -> WaitForTasksResult {
        let until = (request.until ?? "any").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard until == "any" || until == "all" else {
            throw CherryControlError(code: "invalid_argument", message: "until is any or all, not \(request.until ?? "").")
        }
        let selection = try taskSelection(runID: request.runID, taskIDs: request.taskIDs, defaultingToCallers: true)
        let callerID = verifiedCallerSession()?.id
        let timeout = min(
            max(request.timeoutMilliseconds ?? CherryControl.maximumTaskWaitMilliseconds, 0),
            CherryControl.maximumTaskWaitMilliseconds
        )
        let maxEvents = min(max(request.maxEvents ?? 100, 1), 500)
        let after = max(request.cursor ?? 0, 0)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) / 1_000)
        var involvedRuns = selection.runs
        for task in selection.tasks {
            if let run = tasks.runs[task.runID], !involvedRuns.contains(where: { $0 === run }) { involvedRuns.append(run) }
        }
        for run in involvedRuns { run.activeWaits += 1 }
        defer { for run in involvedRuns { run.activeWaits -= 1 } }

        while true {
            let selected = selectedTasks(selection)
            let ids = Set(selected.map(\.id))
            let available = tasks.events.filter { $0.seq > after && ids.contains($0.taskID) }
            let pending = selected.filter { !$0.state.isSettled }
            let ready = until == "all"
                ? pending.isEmpty
                : pending.isEmpty || available.contains { $0.kind.settles || $0.kind == .needsInput }
            if ready || Date() >= deadline {
                let events = Array(available.prefix(maxEvents))
                let cursor = events.last?.seq ?? after
                // The owner read its run's settle: no wake line for it.
                for run in involvedRuns where run.ownerID != nil && run.ownerID == callerID {
                    if let settledSeq = run.settledSeq, events.count == available.count {
                        run.ownerReadSeq = max(run.ownerReadSeq, settledSeq)
                    }
                }
                return WaitForTasksResult(
                    events: events,
                    completed: selected.filter(\.state.isSettled).map { tasks.info(for: $0) },
                    pending: pending.map { tasks.info(for: $0) },
                    cursor: cursor,
                    timedOut: !ready,
                    moreEvents: available.count - events.count,
                    eventsDropped: after < tasks.firstKeptSeq - 1,
                    runs: involvedRuns.map { tasks.info(for: $0) }
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func getTask(_ request: GetTaskRequest) throws -> AgentTaskDetail {
        guard let task = tasks.task(request.taskID, device: Self.remoteDevice) else {
            throw Self.unknownTask(request.taskID)
        }
        return tasks.detail(for: task)
    }

    @MainActor
    func listTasks(_ request: ListTasksRequest) throws -> ListTasksResult {
        let device = Self.remoteDevice
        var state: AgentTaskState?
        if let raw = request.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            guard let parsed = AgentTaskState(rawValue: raw) else {
                throw CherryControlError(
                    code: "invalid_argument",
                    message: "Unknown task state \(raw): use \(AgentTaskState.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            state = parsed
        }
        let runs: [AgentRun]
        if request.runID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil {
            runs = try taskSelection(runID: request.runID, taskIDs: nil, defaultingToCallers: false).runs
        } else if let caller = verifiedCallerSession(), case let owned = tasks.runs(ownedBy: caller.id, device: device), !owned.isEmpty {
            runs = owned
        } else {
            runs = tasks.orderedRuns.filter { $0.device == device }
        }
        let listed = runs.flatMap { tasks.tasks(of: $0) }.filter { state == nil || $0.state == state }
        return ListTasksResult(runs: runs.map { tasks.info(for: $0) }, tasks: listed.map { tasks.info(for: $0) })
    }

    @MainActor
    func cancelTasks(_ request: CancelTasksRequest) throws -> CancelTasksResult {
        let selection = try taskSelection(runID: request.runID, taskIDs: request.taskIDs, defaultingToCallers: false)
        var cancelled: [String] = []
        var closed: [String] = []
        var alreadySettled: [String] = []
        for task in selectedTasks(selection) {
            if task.state.isSettled {
                alreadySettled.append(task.id)
            } else {
                tasks.update(task, to: .cancelled, event: .cancelled, text: "Cancelled by the orchestrator.", reason: "cancelled by the orchestrator")
                cancelled.append(task.id)
            }
            guard request.close == true, let worker = task.worker, let workspace = task.workspace,
                  isOpen(worker, in: workspace), callerReaches(worker, in: workspace)
            else { continue }
            do {
                try closeFromControl(worker, workspace: workspace, agentClosePolicy: nil)
                closed.append(task.id)
            } catch {
                SessionLog.debug("[task] \(task.id)'s worker not closed: \(error)")
            }
        }
        return CancelTasksResult(cancelled: cancelled, closed: closed, alreadySettled: alreadySettled)
    }

    // MARK: Sampling

    /// Looks at every open task's worker (the monitor sampler calls it):
    /// its tab closed or its program ended, it waits for the user, it went
    /// idle after its turn without reporting (asked once, then
    /// `no_report`), or its kickoff is still to be typed; then types the
    /// wake line of each run that settled.
    @MainActor
    func sampleTasks() async {
        for task in tasks.openTasks {
            guard !task.state.isSettled else { continue }
            guard let worker = task.worker, let workspace = task.workspace, isOpen(worker, in: workspace) else {
                tasks.update(task, to: .cancelled, event: .cancelled, text: "The worker's tab was closed.", reason: "its tab was closed before it reported")
                continue
            }
            let key = ObjectIdentifier(worker)
            let now = Date()
            if monitors.lastRefreshAt[key].map({ now.timeIntervalSince($0) >= monitors.refreshInterval }) ?? true {
                monitors.lastRefreshAt[key] = now
                await refreshForMonitor(worker)
            }
            // A report may have come in meanwhile.
            guard !task.state.isSettled else { continue }
            let status = monitorStatus(session: worker, workspace: workspace, now: Date())
            switch status {
            case "closed":
                tasks.update(task, to: .cancelled, event: .cancelled, text: "The worker's tab was closed.", reason: "its tab was closed before it reported")
            case "exited", "disconnected":
                let exit = worker.exitCode.map { " (exit \($0))" } ?? ""
                tasks.update(
                    task, to: .failed, event: .failed,
                    text: "The worker ended\(exit) before it reported.",
                    result: screenTailResult(of: worker, task: task),
                    reason: "it ended\(exit) before it reported"
                )
            case "needs_input", "permission":
                if task.state != .needsInput {
                    tasks.update(
                        task, to: .needsInput, event: .needsInput,
                        text: status == "permission" ? "It waits for a permission answer." : "It asks the user a question."
                    )
                }
            case "working":
                if task.kickoffDeliveredAt != nil, task.state != .working {
                    tasks.update(task, to: .working, event: task.state == .needsInput ? .resumed : .started)
                }
            case "idle":
                if task.state == .needsInput {
                    tasks.update(task, to: .working, event: .resumed)
                }
                checkTurnEnded(task, worker: worker, now: Date())
                retryKickoffIfNeeded(task, worker: worker, now: Date())
            default:
                // Cherry cannot tell (an agent it cannot read): only
                // report_result settles the task.
                break
            }
        }
        for run in tasks.runsAwaitingWake {
            deliverRunWakeIfReady(run)
        }
    }

    /// The worker's last lines, as a fallback result.
    @MainActor
    private func screenTailResult(of worker: TerminalSession, task: AgentTask) -> AgentTaskResult {
        var lines = terminalOutput(for: worker, startLine: nil, lineLimit: AgentTaskRegistry.screenTailLines).lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var text = lines.joined(separator: "\n")
        if text.count > AgentTaskRegistry.screenTailCharacters {
            text = String(text.suffix(AgentTaskRegistry.screenTailCharacters))
        }
        return AgentTaskResult(
            value: .string(text),
            status: "no_report",
            summary: nil,
            version: task.result?.version ?? 0,
            reportedAt: Date(),
            source: "screen_tail"
        )
    }

    /// An idle worker whose turn for the task ended without a report: asked
    /// once to report; after that turn too, `no_report`.
    @MainActor
    private func checkTurnEnded(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard let baselineAt = task.turnBaselineAt, task.kickoffDeliveredAt != nil, !task.isTypingIntoWorker,
              worker.agentSubmittedTurnCount >= task.turnBaseline
        else { return }
        let sawWork = worker.lastStrongWorkingEvidenceAt.map { $0 >= baselineAt } ?? false
        let completedThatTurn = worker.agentTurnState == .completed
            && (worker.lastAgentSubmitAt.map { $0 >= baselineAt } ?? false)
        guard sawWork || completedThatTurn || now.timeIntervalSince(baselineAt) >= tasks.idleFallbackInterval else { return }
        if task.nudgedAt == nil {
            if let last = task.lastNudgeAttemptAt, now.timeIntervalSince(last) < monitors.wakeMinimumInterval { return }
            guard subscriberTakesWakeLine(worker, now: now) else { return }
            nudge(task, worker: worker)
        } else {
            tasks.update(
                task, to: .noReport, event: .noReport,
                text: "It went idle again without calling report_result.",
                result: screenTailResult(of: worker, task: task),
                reason: "it went idle without calling report_result, even when asked; the result is its screen's last lines"
            )
        }
    }

    @MainActor
    private func nudge(_ task: AgentTask, worker: TerminalSession) {
        task.isTypingIntoWorker = true
        task.lastNudgeAttemptAt = Date()
        let typedSince = Date()
        Task { @MainActor [weak self] in
            defer { task.isTypingIntoWorker = false }
            guard let self else { return }
            do {
                _ = try await self.sendControlInput(text: AgentTaskRegistry.nudgeLine, rawBase64: nil, submit: true, to: worker)
                guard !task.state.isSettled else { return }
                task.nudgedAt = Date()
                task.turnBaselineAt = typedSince
                task.turnBaseline = worker.agentSubmittedTurnCount
                self.tasks.record(.nudged, for: task)
                self.tasks.publish()
            } catch {
                SessionLog.debug("[task] nudge for \(task.id) not sent: \(error)")
            }
        }
    }

    /// Types the kickoff again into an idle worker it did not reach (it
    /// showed a prompt, say); gives up after `maximumKickoffAttempts`.
    @MainActor
    private func retryKickoffIfNeeded(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard task.kickoffDeliveredAt == nil, !task.isTypingIntoWorker else { return }
        guard task.kickoffRetryable else {
            // Some of it may have been typed (its host's answer was lost):
            // never typed twice. A worker that sits idle without asking
            // for its task did not get it.
            if let last = task.lastKickoffAttemptAt, now.timeIntervalSince(last) >= tasks.idleFallbackInterval {
                tasks.update(
                    task, to: .failed, event: .failed,
                    text: "The kickoff may not have reached the worker.",
                    reason: "its kickoff may not have reached the worker, which never asked for its task"
                )
            }
            return
        }
        guard task.kickoffAttempts < AgentTaskRegistry.maximumKickoffAttempts else {
            tasks.update(
                task, to: .failed, event: .failed,
                text: "Cherry could not type the kickoff into the worker.",
                reason: "Cherry could not type its kickoff into the worker"
            )
            return
        }
        if let last = task.lastKickoffAttemptAt, now.timeIntervalSince(last) < tasks.kickoffRetryInterval { return }
        guard worker.acceptsControlInput, !worker.humanIsComposing(within: monitors.humanTypingInterval) else { return }
        task.isTypingIntoWorker = true
        let typedSince = Date()
        Task { @MainActor [weak self] in
            defer { task.isTypingIntoWorker = false }
            guard let self else { return }
            do {
                _ = try await self.sendControlInput(text: task.kickoffLine, rawBase64: nil, submit: true, to: worker)
                self.noteKickoff(task, delivered: true, error: nil, typedSince: typedSince)
            } catch {
                self.noteKickoff(task, delivered: false, error: error as? CherryControlError, typedSince: typedSince)
            }
        }
    }

    /// A monitor's or a run's wake line is being typed into `session`.
    @MainActor
    func isTypingWakeLine(into session: TerminalSession) -> Bool {
        monitors.subscriptions.values.contains { $0.isWaking && $0.subscriber === session }
            || tasks.orderedRuns.contains { $0.isWaking && $0.owner === session }
    }

    /// Types the run's wake line into its owner once every task settled,
    /// the owner did not read that yet, and it is idle (the monitors' rule,
    /// `subscriberTakesWakeLine`).
    @MainActor
    func deliverRunWakeIfReady(_ run: AgentRun) {
        guard monitors.wakeLinesEnabled, !run.isWaking, run.activeWaits == 0,
              tasks.awaitsWake(run), let owner = run.owner, let settledSeq = run.settledSeq
        else { return }
        let now = Date()
        let ownerIsOpen = allOpenWorkspaces().contains { $0.sessions.contains { $0 === owner } }
        if !ownerIsOpen || (run.settledAt.map { now.timeIntervalSince($0) > tasks.wakeLifetime } ?? false) {
            // Nobody to wake any more.
            run.wokenSeq = settledSeq
            return
        }
        if let last = run.lastWakeAt, now.timeIntervalSince(last) < monitors.wakeMinimumInterval { return }
        // One line at a time into a tab: never while a monitor's is typed.
        guard !isTypingWakeLine(into: owner), subscriberTakesWakeLine(owner, now: now) else { return }
        let line = AgentTaskRegistry.wakeLine(runID: run.id, counts: tasks.counts(of: run))
        run.isWaking = true
        Task { @MainActor [weak self] in
            defer { run.isWaking = false }
            guard let self else { return }
            do {
                _ = try await self.sendControlInput(text: line, rawBase64: nil, submit: true, to: owner)
                run.wokenSeq = max(run.wokenSeq, settledSeq)
            } catch {
                SessionLog.debug("[task] wake line for \(run.id) not sent: \(error)")
            }
            run.lastWakeAt = Date()
        }
    }
}
