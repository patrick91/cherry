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
// `report_result`, which Cherry checks against the task's result schema
// (off the main thread, within a work budget); the worker is always the
// caller's own tab (`verifiedCallerSession`), never a selector. The
// orchestrator waits with `wait_for_tasks`, or ends its turn: once every
// task of its run settled and it is idle, Cherry types one line into its
// tab (counts and the run id only, never a worker's text), as monitors'
// wake lines do.
//
// `report_result` is the signal. A worker that goes idle after its turn
// without reporting is asked once ("Please call report_result with your
// result."); idle again without a report, its task is `no_report`, with its
// screen's last lines as the result. Neither happens while the worker waits
// on a monitor of its own (a wake subscription whose processes still run or
// whose events it has not read). The monitor sampler watches open tasks
// (`sampleTasks`), so tasks reuse its refresh throttle, status and idle
// rules. Everything Cherry types into a tab (wake lines, the nudge, a
// kickoff) goes through one lock per tab (`typeCherryLine`), so two lines
// never mix into one message.
//
// A task follows its worker's tab by id: a tab closed with ⌘W (or detached
// with ⌘D) that comes back (⌘Z, Background Sessions › Open) is the task's
// worker again. While its tab is away the task waits: a closed tab's task is
// cancelled once its session really ends (the close can no longer be
// undone); a detached worker whose session runs stays the task's worker
// (and may report, identified by its program's processes).
//
// The kickoff is checked, not only typed: an agent CLI that shows its
// composer before it takes input (Claude Code while its MCP servers load)
// drops the text or its Enter. Until the worker's turn starts, it asks for
// its task, or the kickoff shows as a sent message, Cherry looks at its
// screen once it is still: the kickoff left in the composer gets its Enter,
// one that is not there is typed again (bounded, `kickoff_retry`). A worker
// that has not read its task is never asked to report; it gets the kickoff
// again.
//
// Records survive a relaunch of Cherry (`AgentTaskPersistence.swift`): the
// app saves tasks and runs, with their events and sequence numbers, to
// `Workspaces/agent-tasks.json` (the instance-lock holder only), and the
// next launch reads them back and finds each worker and orchestrator again
// by its tab id or its session. Each run keeps its own events. Tasks are
// one level deep (a worker cannot hand out tasks), and a caller on another
// Mac reaches only the tasks its Mac's callers made.

/// The hosted session a task's worker (or a run's owner) runs in: what a
/// relaunch of Cherry looks for.
struct AgentTaskSessionBinding: Codable, Equatable, Hashable, Sendable {
    /// `HostedSessionHost.id`: "local", or "ssh:" and the destination (a
    /// device's host).
    var host: String
    /// The host's identity, when known.
    var hostID: String?
    var sessionID: String

    init(host: String, hostID: String?, sessionID: String) {
        self.host = host
        self.hostID = hostID
        self.sessionID = sessionID
    }

    init(_ attachment: HostedSessionAttachment) {
        self.init(host: attachment.host.id, hostID: attachment.hostID, sessionID: attachment.sessionID)
    }

    /// Whether `attachment` names this session.
    func names(_ attachment: HostedSessionAttachment?) -> Bool {
        guard let attachment else { return false }
        return attachment.sessionID == sessionID && attachment.host.id == host
            && (hostID == nil || attachment.hostID == hostID)
    }
}

/// What Cherry is typing into a task's worker now.
enum AgentTaskTyping: Equatable {
    /// The spawn waits for the worker to be ready for its first kickoff:
    /// nothing typed yet.
    case kickoffPending
    case kickoff
    case kickoffEnter
    case nudge
}

/// One task (main actor only).
@MainActor
final class AgentTask {
    let id: String
    let runID: String
    /// The Mac of the caller that made it, nil for This Mac: only callers
    /// of that Mac find it.
    let device: UUID?
    /// The worker's tab. A tab that comes back for the worker's session
    /// under another id becomes the worker (`locateWorker`).
    var workerID: UUID
    /// The worker's tab as last found (`locateWorker` finds a tab that came
    /// back by `workerID`).
    weak var worker: TerminalSession?
    weak var workspace: TerminalWorkspace?
    /// The worker's persistent session and its host, while it runs as one:
    /// what tells a closed tab whose close may still be undone, or a
    /// detached one, from a tab that is gone.
    weak var hosting: PersistentLocalSessions?
    var hostSessionID: String?
    /// The worker's session as last seen (attached or its own): saved, so
    /// a relaunch looks for it.
    var workerSession: AgentTaskSessionBinding?
    /// The worker's program ran in a persistent session it owned (it can
    /// outlive Cherry).
    var workerIsPersistent = false
    /// Since when its tab is in no open window.
    var awaySince: Date?
    let label: String
    let phase: String?
    let brief: String
    let resultSchema: JSONValue?
    let createdAt: Date
    var state: AgentTaskState = .queued
    var startedAt: Date?
    var settledAt: Date?
    var reason: String?
    var result: AgentTaskResult?
    var progress: String?
    var progressAt: Date?
    /// The event that last settled it, and the last that said it needs
    /// the user: `wait_for_tasks` reads them even when the events went.
    var settledSeq: Int?
    var needsInputSeq: Int?
    /// When its last report was recorded, and whether one is being checked.
    var lastReportAt: Date?
    var isCheckingReport = false

    /// Read back from the last run's file and not found again yet: its tab,
    /// or its session on its host, is still looked for.
    var restoredAt: Date?
    /// When its tab was found again after a relaunch: lines Cherry types
    /// into it wait their grace from then.
    var relinkedAt: Date?

    /// The worker asked for its task (`get_my_task`), or reported on it.
    var fetchedAt: Date?
    /// When the latest kickoff was typed; nil before one was (or after one
    /// that sent nothing).
    var kickoffTypedAt: Date?
    /// The latest kickoff failed in a way that may have typed it: never
    /// typed again (its Enter may still be pressed).
    var kickoffUncertain = false
    /// The kickoff was seen sent: the worker's turn started, it asked for
    /// its task, or the kickoff shows as a sent message.
    var kickoffDeliveredAt: Date?
    var kickoffAttempts = 0
    var lastKickoffAttemptAt: Date?
    /// Enter pressed for a kickoff left in the worker's composer.
    var kickoffEnterPresses = 0
    /// The latest kickoff typed or Enter pressed.
    var lastKickoffActionAt: Date?
    /// The worker's submitted turns when the latest kickoff was typed.
    var kickoffTurnCount = 0
    /// Copies of the kickoff on the worker's screen just before the latest
    /// was typed: one more, outside its composer, is the latest sent.
    var kickoffCopiesBefore = 0
    /// What Cherry is typing into the worker now (a kickoff, its Enter, or
    /// the nudge).
    var typing: AgentTaskTyping?
    var isTypingIntoWorker: Bool { typing != nil }
    /// Since when the worker's current turn for the task runs (the
    /// kickoff's, then the nudge's), and its turn count then.
    var turnBaselineAt: Date?
    var turnBaseline = 0
    var nudgedAt: Date?
    var lastNudgeAttemptAt: Date?
    /// The size of its result's value as JSON, for the saved file's budget
    /// (by result version).
    var resultBytes: (version: Int, bytes: Int)?

    init(
        id: String,
        runID: String,
        device: UUID?,
        workerID: UUID,
        worker: TerminalSession?,
        workspace: TerminalWorkspace?,
        label: String,
        phase: String?,
        brief: String,
        resultSchema: JSONValue?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.device = device
        self.workerID = workerID
        self.worker = worker
        self.workspace = workspace
        self.label = label
        self.phase = phase
        self.brief = brief
        self.resultSchema = resultSchema
        self.createdAt = createdAt
    }

    convenience init(
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
        self.init(
            id: id, runID: runID, device: device, workerID: worker.id, worker: worker, workspace: workspace,
            label: label, phase: phase, brief: brief, resultSchema: resultSchema
        )
    }

    var kickoffLine: String { AgentTaskRegistry.kickoffLine(taskID: id) }
}

/// The tasks one orchestrator handed out together (main actor only).
@MainActor
final class AgentRun {
    let id: String
    let device: UUID?
    /// Whose run it is: the orchestrator's tab Cherry confirmed made it,
    /// else the workers' parent agent; nil when neither is known. A tab
    /// that comes back for the owner's session under another id becomes it.
    var ownerID: UUID?
    /// The orchestrator's tab, only when Cherry confirmed it is the caller
    /// that made the run: the wake line goes there, and only to an agent.
    weak var owner: TerminalSession?
    /// The owner was confirmed (the caller) and an agent when the run was
    /// made: the wake line goes to it, or to the tab that comes back for
    /// it after a relaunch.
    let ownerWakes: Bool
    /// The owner's session as last seen: saved, so a relaunch finds it.
    var ownerSession: AgentTaskSessionBinding?
    /// Made for its owner's spawns that named no run.
    let isImplicit: Bool
    let createdAt: Date
    var taskIDs: [String] = []
    /// Its tasks' events, oldest first: at most one of each kind per task
    /// (a newer one replaces it), and at most `maxEventsPerRun`.
    var events: [AgentTaskEvent] = []
    /// The newest event it dropped to stay within `maxEventsPerRun`.
    var droppedThroughSeq = 0
    /// The event at which every task of it settled; nil while one is open.
    var settledSeq: Int?
    var settledAt: Date?
    /// The settle its wake line was typed for (or given up on).
    var wokenSeq = 0
    /// The settle its owner read with `wait_for_tasks` (or caused, with
    /// `cancel_tasks`): no wake line then.
    var ownerReadSeq = 0
    var lastWakeAt: Date?
    var isWaking = false
    /// `wait_for_tasks` calls on it now: no wake line while one runs.
    var activeWaits = 0
    /// Read back from the last run's file, its owner not found again yet.
    var restoredAt: Date?
    /// When its owner's tab was found again after a relaunch.
    var relinkedAt: Date?
    /// Since when none of its tabs is open or running (`pruneSettledRuns`).
    var tabsGoneSince: Date?

    init(
        id: String,
        device: UUID?,
        ownerID: UUID?,
        owner: TerminalSession?,
        isImplicit: Bool,
        ownerWakes: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.device = device
        self.ownerID = ownerID
        self.owner = owner
        self.isImplicit = isImplicit
        self.ownerWakes = ownerWakes ?? (owner?.kind == .agent)
        self.createdAt = createdAt
        if let binding = owner?.hostedSessionBinding { ownerSession = AgentTaskSessionBinding(binding) }
    }

    /// A wake line can be typed into its owner (an agent tab Cherry
    /// confirmed, or the tab that came back for it).
    var wakes: Bool { ownerWakes && (owner.map { $0.kind == .agent } ?? true) }
}

/// One lock per tab for what Cherry types into it (wake lines, the nudge,
/// a kickoff): a line's text, its pause and its Enter go together, so two
/// lines never mix into one message.
@MainActor
final class TabTypingLocks {
    private var holders: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Cherry types into the tab now (or a line waits for it).
    func isBusy(_ id: UUID) -> Bool { holders.contains(id) }

    func acquire(_ id: UUID) async {
        if holders.insert(id).inserted { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    /// Hands the lock to the next line waiting for the tab, if any.
    func release(_ id: UUID) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            holders.remove(id)
            waiters[id] = nil
        }
    }
}

/// The tasks and runs of one control server.
@MainActor
final class AgentTaskRegistry {
    static let maximumTasks = 1_000
    static let maximumBriefCharacters = 64_000
    static let maximumBriefBytes = 256 * 1024
    nonisolated static let maximumResultBytes = 256 * 1024
    /// Kickoffs typed into one worker at most (the first and its retries).
    static let maximumKickoffAttempts = 3
    /// Enter pressed at most for a kickoff left in the worker's composer.
    static let maximumKickoffEnterPresses = 2
    /// What each text keeps, in characters and in UTF-8 bytes (a character
    /// can be many bytes).
    static let summaryBytes = 4 * CherryControl.maximumTaskSummaryCharacters
    static let progressBytes = 4 * CherryControl.maximumTaskProgressCharacters
    static let labelLimit = (characters: 80, bytes: 320)
    static let phaseLimit = (characters: 60, bytes: 240)
    /// A report's or progress message's excerpt in an event.
    static let eventTextLimit = (characters: 120, bytes: 480)
    /// The screen's last lines a `no_report` (or an exit) keeps.
    static let screenTailLines = 40
    static let screenTailCharacters = 4_000
    /// Typed once into a worker that went idle without reporting.
    static let nudgeLine = "Please call report_result with your result."

    let board: AgentTaskBoard
    let typingLocks = TabTypingLocks()
    private(set) var tasks: [String: AgentTask] = [:]
    private(set) var taskOrder: [String] = []
    private(set) var runs: [String: AgentRun] = [:]
    private(set) var runOrder: [String] = []
    private(set) var nextSeq = 1
    /// After a relaunch: the newest seq the saved file had, and the first
    /// one this run gives out (a gap of `restoredSeqGap` between them). A
    /// cursor in between names events the file lost (`cursor_reset`).
    private(set) var restoredThroughSeq: Int?
    private(set) var restoredSeqGapEnd: Int?
    /// Settings › MCP › Wake idle agents (the server's monitors' setting).
    var wakeLinesEnabled: @MainActor () -> Bool = { true }

    // Persistence (`AgentTaskPersistence.swift`): nil saves nothing (tests
    // that do not set one).
    var store: AgentTaskStore?
    /// The hosting a task's session runs on (the app's looks in its
    /// `PersistentHostingRegistry`), and what that session is now
    /// (`AgentTaskHostLookup`; tests set their own). Used for tasks read
    /// back after a relaunch, and to tell when a settled run's tabs are gone.
    var hostingForSession: @MainActor (AgentTaskSessionBinding) -> PersistentLocalSessions? = { _ in nil }
    var sessionStatus: @MainActor (AgentTaskSessionBinding, PersistentLocalSessions?, _ savedAt: Date?) -> AgentTaskSessionStatus = { _, _, _ in
        .unknown(waitsForDevice: false)
    }
    /// The saved file was read (or there was none to read): saves may
    /// replace it from now on.
    var isRestoreSettled = true
    /// Reading the saved file, at launch: requests wait for it.
    var restoreTask: Task<Void, Never>?
    /// When the saved state was read back (nil: nothing was).
    private(set) var restoredAt: Date?
    /// When the file read back was saved.
    private(set) var restoredFileSavedAt: Date?
    var saveTask: Task<Void, Never>?
    var pruneTask: Task<Void, Never>?
    var hasUnsavedChanges = false

    // Tunables (tests shorten them).
    /// At most one progress message is recorded this often.
    var progressInterval: TimeInterval = 5
    /// At most one report is recorded this often (the first at once).
    var reportInterval: TimeInterval = 2
    /// An idle worker whose turn showed no work is taken as done with that
    /// turn this long after it was submitted.
    var idleFallbackInterval: TimeInterval = 30
    var kickoffRetryInterval: TimeInterval = 5
    /// A settled run's wake line is given up after this long.
    var wakeLifetime: TimeInterval = 60 * 60
    /// The events a run keeps (it drops its oldest beyond).
    var maxEventsPerRun = 2_000
    /// How long a worker whose tab is gone, and whose session its host no
    /// longer lists, may come back before its task is cancelled.
    var awayGrace: TimeInterval = 10
    /// A kickoff not seen sent is looked at again this long after it was
    /// typed (or its Enter pressed), once the worker's screen was still for
    /// `kickoffQuietInterval`.
    var kickoffCheckDelay: TimeInterval = 2
    var kickoffQuietInterval: TimeInterval = 1
    /// After a relaunch: how long a worker or owner whose tab has not come
    /// back (and that ran no session Cherry can look for) is waited for, and
    /// how long nothing is typed into one that did.
    var relinkGrace: TimeInterval = 120
    var restoredLineGrace: TimeInterval = 5
    /// After a relaunch: how long a This Mac worker's session that its host
    /// cannot be asked about is waited for (another Mac's waits for it).
    var restoreDecisionTimeout: TimeInterval = 10 * 60
    /// Saves wait this long for more changes.
    var saveDelay: Duration = .seconds(1)
    /// A settled run is forgotten this long after it settled, or this long
    /// after none of its tabs is open or running.
    var settledRunLifetime: TimeInterval = 24 * 60 * 60
    var goneRunLifetime: TimeInterval = 10 * 60
    /// How often settled runs are looked at for pruning.
    var maintenanceInterval: Duration = .seconds(300)
    /// Seqs left unused after a relaunch: a cursor among them names events
    /// the saved file lost.
    static let restoredSeqGap = 1_000

    init(board: AgentTaskBoard) {
        self.board = board
    }

    static func newID(_ prefix: String) -> String {
        prefix + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }

    /// `text` within `characters` characters and `bytes` UTF-8 bytes, cut
    /// at a character with "…"; and whether it was cut.
    nonisolated static func clip(_ text: String, characters: Int, bytes: Int) -> (text: String, clipped: Bool) {
        if text.utf8.count <= bytes, text.count <= characters { return (text, false) }
        let ellipsis = "…"
        var kept = ""
        var keptCharacters = 0
        var keptBytes = 0
        for character in text {
            let size = character.utf8.count
            guard keptCharacters + 1 < characters, keptBytes + size + ellipsis.utf8.count <= bytes else { break }
            kept.append(character)
            keptCharacters += 1
            keptBytes += size
        }
        return (kept + ellipsis, true)
    }

    /// One line, typed into the worker as its first message.
    nonisolated static func kickoffLine(taskID: String) -> String {
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

    // MARK: Changes

    func addRun(device: UUID?, ownerID: UUID?, owner: TerminalSession?, isImplicit: Bool) -> AgentRun {
        let run = AgentRun(id: Self.newID("run"), device: device, ownerID: ownerID, owner: owner, isImplicit: isImplicit)
        insert(run)
        return run
    }

    /// Adds a run made here or read back from the saved file.
    func insert(_ run: AgentRun) {
        runs[run.id] = run
        runOrder.append(run.id)
    }

    /// Adds a task read back from the saved file (its run's ids name it).
    func insertRestored(_ task: AgentTask) {
        tasks[task.id] = task
        taskOrder.append(task.id)
    }

    /// Starts this run's seqs after the saved file's, leaving a gap.
    func continueSeqs(afterSaved savedNextSeq: Int, restoredAt: Date, fileSavedAt: Date) {
        restoredThroughSeq = max(savedNextSeq - 1, 0)
        nextSeq = max(savedNextSeq, 1) + Self.restoredSeqGap
        restoredSeqGapEnd = nextSeq
        self.restoredAt = restoredAt
        restoredFileSavedAt = fileSavedAt
    }

    /// Whether `cursor` is one Cherry can go on from: not past the newest
    /// seq given out, nor in the gap a relaunch left (events the saved file
    /// lost).
    func cursorIsValid(_ cursor: Int) -> Bool {
        if cursor > nextSeq - 1 { return false }
        if let through = restoredThroughSeq, let gapEnd = restoredSeqGapEnd, cursor > through, cursor < gapEnd {
            return false
        }
        return true
    }

    /// Forgets `run` and its tasks.
    func remove(_ run: AgentRun) {
        for id in run.taskIDs { tasks[id] = nil }
        taskOrder.removeAll { tasks[$0] == nil }
        runs[run.id] = nil
        runOrder.removeAll { $0 == run.id }
    }

    func add(_ task: AgentTask, to run: AgentRun) {
        tasks[task.id] = task
        taskOrder.append(task.id)
        run.taskIDs.append(task.id)
        let event = record(.queued, for: task)
        settleCheck(run, seq: event.seq)
        prune()
        publish()
    }

    /// Adds an event to its run: it replaces the task's earlier event of
    /// the same kind (one of each kind per task: a chatty worker's progress
    /// or re-reports never pile up), and the run drops its oldest beyond
    /// `maxEventsPerRun`. Other runs' events are never touched.
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
            text: text.map { Self.clip($0, characters: Self.eventTextLimit.characters, bytes: Self.eventTextLimit.bytes).text },
            version: version
        )
        nextSeq += 1
        scheduleSave()
        guard let run = runs[task.runID] else { return event }
        run.events.removeAll { $0.taskID == task.id && $0.kind == kind }
        run.events.append(event)
        if run.events.count > maxEventsPerRun {
            let overflow = run.events.count - maxEventsPerRun
            run.droppedThroughSeq = max(run.droppedThroughSeq, run.events[overflow - 1].seq)
            run.events.removeFirst(overflow)
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
        if state.isSettled, kind.settles { task.settledSeq = event.seq }
        if state == .needsInput { task.needsInputSeq = event.seq }
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
        scheduleSave()
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
            message: "No Cherry task \(id) this caller can see: it was never made on this caller's Mac, or it settled and was forgotten (a day after it settled, or once its tabs were gone)."
        )
    }

    static func unknownRun(_ id: String) -> CherryControlError {
        CherryControlError(
            code: "unknown_run",
            message: "No Cherry run \(id) this caller can use: it was never made on this caller's Mac, or it settled and was forgotten (a day after it settled, or once its tabs were gone)."
        )
    }

    /// Input that failed in a way that may still have typed it (its
    /// host's answer was lost, or only a first part went): never typed
    /// again, or it would be typed twice.
    nonisolated static func inputMayHaveBeenTyped(_ error: Error) -> Bool {
        guard let error = error as? CherryControlError else { return false }
        return error.code == "input_maybe_delivered" || error.code == "input_partially_delivered"
    }

    /// Types `text` and Enter into `session` as Cherry's own line (a wake
    /// line, the nudge, a kickoff): under the tab's typing lock, so the
    /// text, its pause and its Enter are never mixed with another line.
    @MainActor
    func typeCherryLine(_ text: String, into session: TerminalSession) async throws -> Int {
        await tasks.typingLocks.acquire(session.id)
        defer { tasks.typingLocks.release(session.id) }
        return try await sendControlInput(text: text, rawBase64: nil, submit: true, to: session)
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
        guard brief.utf8.count <= AgentTaskRegistry.maximumBriefBytes, brief.count <= AgentTaskRegistry.maximumBriefCharacters else {
            throw CherryControlError(
                code: "invalid_process_request",
                message: "task is longer than \(AgentTaskRegistry.maximumBriefCharacters) characters or \(AgentTaskRegistry.maximumBriefBytes) bytes: put the details in a file and name it in the brief."
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
        if let caller { adoptRunsOwned(by: caller) }
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
        let phase = request.phase?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return TaskSpawnPlan(
            brief: brief,
            label: AgentTaskRegistry.clip(label, characters: AgentTaskRegistry.labelLimit.characters, bytes: AgentTaskRegistry.labelLimit.bytes).text,
            phase: phase.map { AgentTaskRegistry.clip($0, characters: AgentTaskRegistry.phaseLimit.characters, bytes: AgentTaskRegistry.phaseLimit.bytes).text },
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
        return AgentTaskRegistry.clip(words, characters: 40, bytes: 160).text
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
        if let binding = worker.hostedSessionBinding {
            task.workerSession = AgentTaskSessionBinding(binding)
            task.workerIsPersistent = worker.persistentSession != nil
        } else {
            task.workerIsPersistent = worker.persistentHosting != nil
        }
        tasks.add(task, to: run)
        startMonitorSamplerIfNeeded()
        startTaskMaintenanceIfNeeded()
        return task
    }

    /// What became of a kickoff typed at `typedSince`. Typed is not sent:
    /// the sampler looks for the worker's turn, its `get_my_task` or the
    /// kickoff among its sent messages (`checkKickoff`) before it counts
    /// as delivered.
    @MainActor
    func noteKickoff(_ task: AgentTask, delivered: Bool, error: CherryControlError?, typedSince: Date = Date()) {
        task.kickoffAttempts += 1
        task.lastKickoffAttemptAt = Date()
        task.lastKickoffActionAt = Date()
        task.kickoffEnterPresses = 0
        if delivered {
            task.kickoffTypedAt = typedSince
            task.kickoffUncertain = false
            task.kickoffTurnCount = task.worker?.agentSubmittedTurnCount ?? 0
        } else {
            // Typed again once the worker takes input when nothing of it
            // was typed; never when some of it may have been.
            let nothingSent: Set<String> = [
                "agent_awaiting_permission", "agent_awaiting_input", "process_not_accepting_input", "input_not_delivered",
            ]
            if nothingSent.contains(error?.code ?? "") {
                task.kickoffTypedAt = nil
                task.kickoffUncertain = false
            } else {
                task.kickoffTypedAt = typedSince
                task.kickoffUncertain = true
            }
        }
        tasks.scheduleSave()
        startMonitorSamplerIfNeeded()
    }

    /// The kickoff was seen sent (at `at`): the worker's turn for it runs
    /// from then.
    @MainActor
    func noteKickoffDelivered(_ task: AgentTask, at: Date) {
        guard task.kickoffDeliveredAt == nil else { return }
        task.kickoffDeliveredAt = at
        task.turnBaselineAt = at
        task.turnBaseline = task.kickoffTurnCount
        tasks.scheduleSave()
    }

    /// The worker asked for its task, or reported on it: it has it.
    @MainActor
    private func noteFetched(_ task: AgentTask) {
        let now = Date()
        if task.fetchedAt == nil { task.fetchedAt = now }
        if task.kickoffDeliveredAt == nil {
            // It found its task (by itself, or the kickoff reached it
            // unseen): no kickoff is typed any more.
            if task.kickoffTypedAt == nil { task.kickoffTurnCount = task.worker?.agentSubmittedTurnCount ?? 0 }
            noteKickoffDelivered(task, at: task.kickoffTypedAt ?? now)
        }
        tasks.scheduleSave()
    }

    // MARK: Worker side

    /// The caller's own tab's task; for a worker whose tab is away (its
    /// close may still be undone, or it was detached) while its session
    /// runs, the task whose session's program is an ancestor of the caller.
    @MainActor
    private func callerTask() throws -> AgentTask {
        guard let caller = verifiedCallerSession() else {
            if let away = awayWorkerTaskOfCaller() { return away }
            throw Self.noAssignment(
                "Cherry could not tell which of its tabs this MCP session runs in, so it has no task for it. Run CherryMCP inside the agent's own Cherry tab (as its MCP server, or \"$CHERRY_MCP_HELPER\" --call from its shell)."
            )
        }
        guard let task = tasks.latestTask(forWorker: caller.id) else {
            throw Self.noAssignment("This tab has no Cherry task: only agents spawned with spawn_agent's task have one.")
        }
        return task
    }

    /// A task whose worker's tab is in no open window while its session
    /// runs on its host, when the caller (This Mac's) descends from that
    /// session's program.
    @MainActor
    private func awayWorkerTaskOfCaller() -> AgentTask? {
        guard Self.remoteDevice == nil, callerSessionResolverForTesting == nil, let peerPID = Self.callerPeerPID else { return nil }
        let ancestry = Set(Self.processAncestry(of: peerPID))
        for id in tasks.taskOrder.reversed() {
            guard let task = tasks.tasks[id], task.state != .cancelled, locateWorker(task) == nil,
                  let hosting = hosting(of: task), let sessionID = task.hostSessionID ?? task.workerSession?.sessionID,
                  let pid = hosting.sessionInfo(sessionID)?.pid, ancestry.contains(Int32(bitPattern: pid))
            else { continue }
            return task
        }
        return nil
    }

    @MainActor
    func getMyTask() throws -> GetMyTaskResult {
        let task = try callerTask()
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        noteFetched(task)
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

    /// What checking a report found (`checkReport`).
    enum ReportCheck: Sendable, Equatable {
        case accepted(JSONValue?)
        case tooLarge
        case mismatch([String])
    }

    /// A report's value checked: its size first, then (status ok) its
    /// schema; JSON text of an object or array stands for that value when
    /// it matches (some clients send an argument whose type the tool leaves
    /// open as a string). Pure, and bounded: run off the main thread.
    nonisolated static func checkReport(value: JSONValue?, status: String, schema: JSONValue?) -> ReportCheck {
        if case .string(let text)? = value, text.utf8.count > AgentTaskRegistry.maximumResultBytes { return .tooLarge }
        if let value, value.encodedByteCount > AgentTaskRegistry.maximumResultBytes { return .tooLarge }
        let parsed: JSONValue? = {
            guard case .string(let text)? = value,
                  let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "{" || first == "["
            else { return nil }
            return try? JSONValue.parse(Data(text.utf8))
        }()
        guard status == "ok", let schema else { return .accepted(schema == nil ? (parsed ?? value) : value) }
        let problems = TaskResultSchema.validate(value ?? .null, against: schema)
        if problems.isEmpty { return .accepted(value) }
        if let parsed, TaskResultSchema.validate(parsed, against: schema).isEmpty { return .accepted(parsed) }
        return .mismatch(problems)
    }

    @MainActor
    func reportResult(_ request: ReportResultRequest) async throws -> ReportResultResult {
        let task = try callerTask()
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        let status = (request.status ?? "ok").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "ok" || status == "failed" else {
            throw CherryControlError(code: "invalid_argument", message: "status is ok or failed, not \(request.status ?? "").")
        }
        let now = Date()
        if task.isCheckingReport {
            throw CherryControlError(code: "rate_limited", message: "A report of task \(task.id) is being checked; send the next one after its answer.")
        }
        if let last = task.lastReportAt, now.timeIntervalSince(last) < tasks.reportInterval {
            let wait = Int(((tasks.reportInterval - now.timeIntervalSince(last)) * 1_000).rounded(.up))
            throw CherryControlError(
                code: "rate_limited",
                message: "Task \(task.id) was reported less than \(Int(tasks.reportInterval)) s ago; nothing was recorded. Report again in \(wait) ms."
            )
        }
        // Checked off the main thread: a large value against a large
        // schema must not stall Cherry.
        task.isCheckingReport = true
        let value = request.value
        let schema = task.resultSchema
        let check = await Task.detached(priority: .userInitiated) {
            Self.checkReport(value: value, status: status, schema: schema)
        }.value
        task.isCheckingReport = false
        let checked: JSONValue?
        switch check {
        case .tooLarge:
            throw CherryControlError(
                code: "result_too_large",
                message: "value is larger than \(AgentTaskRegistry.maximumResultBytes) bytes (nothing was recorded): write the details to a file and report its path."
            )
        case .mismatch(let problems):
            throw CherryControlError(
                code: "schema_mismatch",
                message: "value does not match task \(task.id)'s result_schema (nothing was recorded): \(problems.prefix(5).joined(separator: "; ")). Fix it and call report_result again.",
                details: problems
            )
        case .accepted(let accepted):
            checked = accepted
        }
        // Cancelled while it was checked.
        if task.state == .cancelled { throw Self.taskCancelled(task) }
        noteFetched(task)
        let trimmed = request.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let summary = trimmed.map {
            AgentTaskRegistry.clip($0, characters: CherryControl.maximumTaskSummaryCharacters, bytes: AgentTaskRegistry.summaryBytes)
        }
        let version = (task.result?.version ?? 0) + 1
        let result = AgentTaskResult(
            value: checked,
            status: status,
            summary: summary?.text,
            version: version,
            reportedAt: Date(),
            source: "report_result"
        )
        task.lastReportAt = Date()
        let state: AgentTaskState = status == "ok" ? .reported : .failed
        tasks.update(task, to: state, event: state == .reported ? .reported : .failed, text: summary?.text, result: result)
        return ReportResultResult(
            taskID: task.id,
            runID: task.runID,
            version: version,
            state: task.state,
            summaryTruncated: summary?.clipped ?? false
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
        let message = AgentTaskRegistry.clip(
            oneLine, characters: CherryControl.maximumTaskProgressCharacters, bytes: AgentTaskRegistry.progressBytes
        ).text
        noteFetched(task)
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
            adoptRunsOwned(by: caller)
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

    /// The runs a selection reaches: its runs and its tasks' runs.
    @MainActor
    private func involvedRuns(_ selection: (runs: [AgentRun], tasks: [AgentTask])) -> [AgentRun] {
        var result = selection.runs
        for task in selection.tasks {
            if let run = tasks.runs[task.runID], !result.contains(where: { $0 === run }) { result.append(run) }
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
        var after = max(request.cursor ?? 0, 0)
        // A cursor Cherry cannot go on from (it names events a relaunch
        // lost): answered from the first event kept, with the tasks' states.
        let cursorReset = !tasks.cursorIsValid(after)
        if cursorReset { after = 0 }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) / 1_000)
        let runs = involvedRuns(selection)
        for run in runs { run.activeWaits += 1 }
        defer { for run in runs { run.activeWaits -= 1 } }

        while true {
            let selected = selectedTasks(selection)
            let ids = Set(selected.map(\.id))
            let available = runs.flatMap(\.events)
                .filter { $0.seq > after && ids.contains($0.taskID) }
                .sorted { $0.seq < $1.seq }
            let pending = selected.filter { !$0.state.isSettled }
            // A task's own seqs say it settled (or needs the user) after
            // the cursor, even when its event went.
            let changed = selected.contains { task in
                (task.state.isSettled && (task.settledSeq ?? 0) > after)
                    || (task.state == .needsInput && (task.needsInputSeq ?? 0) > after)
            }
            let ready = cursorReset || (until == "all" ? pending.isEmpty : pending.isEmpty || changed)
            if ready || Date() >= deadline {
                let events = Array(available.prefix(maxEvents))
                let latestChange = selected.compactMap { max($0.settledSeq ?? 0, $0.needsInputSeq ?? 0) }.max() ?? 0
                let cursor = events.count == available.count
                    ? max(events.last?.seq ?? after, min(latestChange, tasks.nextSeq - 1), after)
                    : events.last?.seq ?? after
                // The owner read its run's settle: no wake line for it.
                for run in runs where run.ownerID != nil && run.ownerID == callerID {
                    if let settledSeq = run.settledSeq, events.count == available.count, settledSeq > run.ownerReadSeq {
                        run.ownerReadSeq = settledSeq
                        tasks.scheduleSave()
                    }
                }
                return WaitForTasksResult(
                    events: events,
                    completed: selected.filter(\.state.isSettled).map { tasks.info(for: $0) },
                    pending: pending.map { tasks.info(for: $0) },
                    cursor: cursor,
                    timedOut: !ready,
                    moreEvents: available.count - events.count,
                    eventsDropped: runs.contains { $0.droppedThroughSeq > after },
                    runs: runs.map { tasks.info(for: $0) },
                    cursorReset: cursorReset ? true : nil
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
        let caller = request.runID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == nil ? verifiedCallerSession() : nil
        if let caller { adoptRunsOwned(by: caller) }
        if request.runID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil {
            runs = try taskSelection(runID: request.runID, taskIDs: nil, defaultingToCallers: false).runs
        } else if let caller, case let owned = tasks.runs(ownedBy: caller.id, device: device), !owned.isEmpty {
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
            guard request.close == true, let found = locateWorker(task), callerReaches(found.session, in: found.workspace) else { continue }
            do {
                try closeFromControl(found.session, workspace: found.workspace, agentClosePolicy: nil)
                closed.append(task.id)
            } catch {
                SessionLog.debug("[task] \(task.id)'s worker not closed: \(error)")
            }
        }
        // Its owner ended it: it knows the run settled (no wake line).
        if let callerID = verifiedCallerSession()?.id {
            for run in involvedRuns(selection) where run.ownerID == callerID {
                if let settledSeq = run.settledSeq { run.ownerReadSeq = max(run.ownerReadSeq, settledSeq) }
            }
            tasks.scheduleSave()
        }
        return CancelTasksResult(cancelled: cancelled, closed: closed, alreadySettled: alreadySettled)
    }

    // MARK: Sampling

    /// The worker's tab, in an open window: the one the task last saw, one
    /// that came back with its id (⌘Z after ⌘W or ⌘D, Background Sessions ›
    /// Open, a relaunch's restore), or one that came back for its session
    /// under another id (on the task's Mac); that tab becomes the task's
    /// worker. Notes its session while it has one.
    @MainActor
    func locateWorker(_ task: AgentTask) -> (session: TerminalSession, workspace: TerminalWorkspace)? {
        var found: (session: TerminalSession, workspace: TerminalWorkspace)?
        if let worker = task.worker, let workspace = task.workspace, workspace.sessions.contains(where: { $0 === worker }) {
            found = (worker, workspace)
        } else {
            let workspaces = allOpenWorkspaces()
            found = Self.openTab(id: task.workerID, in: workspaces)
                ?? task.workerSession.flatMap { Self.openTab(boundTo: $0, in: workspaces, device: task.device) }
        }
        guard let found else { return nil }
        let (worker, workspace) = found
        if worker.id != task.workerID {
            task.workerID = worker.id
            tasks.publish()
        }
        task.worker = worker
        task.workspace = workspace
        task.awaySince = nil
        if let hosting = worker.persistentHosting, let sessionID = worker.persistentSession?.sessionID {
            task.hosting = hosting
            task.hostSessionID = sessionID
        }
        if let binding = worker.hostedSessionBinding.map(AgentTaskSessionBinding.init), binding != task.workerSession {
            task.workerSession = binding
            task.workerIsPersistent = worker.persistentSession != nil
            tasks.scheduleSave()
        }
        // A tab shown before its host answered is not back yet: the restore
        // may still withdraw it (its session gone).
        if task.restoredAt != nil, !worker.isProvisionalRestore { noteRelinked(task, worker: worker) }
        return (worker, workspace)
    }

    /// A restored task's worker was found again: its turns are counted
    /// again from now (the idle grace starts over), and a kickoff not seen
    /// sent is looked at again on its screen.
    @MainActor
    private func noteRelinked(_ task: AgentTask, worker: TerminalSession) {
        let now = Date()
        task.restoredAt = nil
        task.relinkedAt = now
        if task.kickoffDeliveredAt != nil {
            task.turnBaselineAt = now
            task.turnBaseline = worker.agentSubmittedTurnCount
        } else if task.kickoffTypedAt != nil {
            // Any copy of it outside the composer now was sent.
            task.kickoffTypedAt = now
            task.lastKickoffActionAt = now
            task.kickoffTurnCount = worker.agentSubmittedTurnCount
            task.kickoffCopiesBefore = 0
        }
        tasks.scheduleSave()
    }

    /// The tab `id` in an open window.
    @MainActor
    static func openTab(id: UUID, in workspaces: [TerminalWorkspace]) -> (session: TerminalSession, workspace: TerminalWorkspace)? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == id }) { return (session, workspace) }
        }
        return nil
    }

    /// A tab of `binding`'s session in an open window of `device` (This
    /// Mac's windows for nil): its own tab first, then one attached to it.
    @MainActor
    static func openTab(
        boundTo binding: AgentTaskSessionBinding,
        in workspaces: [TerminalWorkspace],
        device: UUID?
    ) -> (session: TerminalSession, workspace: TerminalWorkspace)? {
        let scoped = workspaces.filter { workspace in
            guard let device else { return workspace.projectRoot.map { ProjectLocation(key: $0).deviceID == nil } ?? true }
            return isOnDevice(workspace.projectRoot, device)
        }
        for owned in [true, false] {
            for workspace in scoped {
                if let session = workspace.sessions.first(where: { binding.names(owned ? $0.persistentSession : $0.hostedAttachment) }) {
                    guard device.map({ isSession(session, in: workspace, onDevice: $0) }) ?? true else { continue }
                    return (session, workspace)
                }
            }
        }
        return nil
    }

    /// The run's owner's tab, in an open window: the one it last saw, or
    /// (only for an owner a wake line goes to) the tab that came back with
    /// its id or for its session, which becomes the owner.
    @MainActor
    func locateOwner(_ run: AgentRun) -> TerminalSession? {
        let workspaces = allOpenWorkspaces()
        var found: TerminalSession?
        if let owner = run.owner, workspaces.contains(where: { $0.sessions.contains { $0 === owner } }) {
            found = owner
        } else if run.ownerWakes {
            let candidate = run.ownerID.flatMap { Self.openTab(id: $0, in: workspaces) }
                ?? run.ownerSession.flatMap { Self.openTab(boundTo: $0, in: workspaces, device: run.device) }
            found = candidate.flatMap { $0.session.kind == .agent ? $0.session : nil }
        }
        // A tab shown before its host answered is not back yet.
        guard let owner = found, !owner.isProvisionalRestore else { return nil }
        if owner.id != run.ownerID {
            run.ownerID = owner.id
            tasks.publish()
        }
        run.owner = owner
        if run.restoredAt != nil {
            run.restoredAt = nil
            run.relinkedAt = Date()
        }
        if let binding = owner.hostedSessionBinding.map(AgentTaskSessionBinding.init), binding != run.ownerSession {
            run.ownerSession = binding
            tasks.scheduleSave()
        }
        return owner
    }

    /// Runs whose owner's session is the caller's while their owner's tab
    /// is not open (it came back under another id after a relaunch): the
    /// caller owns them.
    @MainActor
    func adoptRunsOwned(by caller: TerminalSession) {
        guard let binding = caller.hostedSessionBinding else { return }
        let workspaces = allOpenWorkspaces()
        for run in tasks.orderedRuns where run.ownerID != caller.id && run.ownerSession?.names(binding) == true {
            if let ownerID = run.ownerID, Self.openTab(id: ownerID, in: workspaces) != nil { continue }
            _ = locateOwner(run)
        }
    }

    /// A worker whose tab is in no open window: its task waits while the
    /// tab may come back (a close that can still be undone) or its session
    /// runs on detached; it is cancelled once that session ends with its
    /// close, failed when its program ended by itself, and cancelled at
    /// once for a tab whose program ended with it (a native tab). A task
    /// read back after a relaunch is decided by its session on its host
    /// (`settleRestoredWorkerIfGone`).
    @MainActor
    private func settleIfWorkerGone(_ task: AgentTask, now: Date) {
        if let restoredAt = task.restoredAt {
            settleRestoredWorkerIfGone(task, restoredAt: restoredAt, now: now)
            return
        }
        let awaySince = task.awaySince ?? now
        task.awaySince = awaySince
        if let hosting = task.hosting, let sessionID = task.hostSessionID {
            if hosting.isEndDeferred(sessionID) { return }
            let ending = hosting.isEnding(sessionID)
            if let info = hosting.sessionInfo(sessionID), !ending {
                if info.isRunning { return }
                let exit = info.exitCode.map { " (exit \($0))" } ?? ""
                tasks.update(task, to: .failed, event: .failed, text: "The worker ended\(exit) before it reported.", reason: "it ended\(exit) before it reported")
                return
            }
            // Not listed (yet): the host may be catching up.
            if !ending, now.timeIntervalSince(awaySince) < tasks.awayGrace { return }
        }
        tasks.update(task, to: .cancelled, event: .cancelled, text: "The worker's tab was closed.", reason: "its tab was closed before it reported")
    }

    /// The worker waits on a monitor of its own: a subscription that types
    /// wake lines into it, whose events it has not read or whose processes
    /// still run. It ended its turn to be woken; that is not the end of
    /// its task.
    @MainActor
    func awaitsMonitorWake(_ session: TerminalSession) -> Bool {
        guard monitors.wakeLinesEnabled else { return false }
        let busy: Set<String> = ["working", "running", "needs_input", "permission", "unknown"]
        return monitors.subscriptions.values.contains { subscription in
            guard subscription.wakeRequested, subscription.subscriber === session else { return false }
            if subscription.pending.contains(where: { $0.seq > subscription.ackCursor }) { return true }
            return subscription.watched.contains { !$0.finished && busy.contains(monitorStatus(of: $0)) }
        }
    }

    /// Looks at every open task's worker (the monitor sampler calls it):
    /// its tab closed or its program ended, it waits for the user, its
    /// kickoff is still to be typed or seen sent (`checkKickoff`), or it
    /// went idle after its turn without asking for its task (the kickoff
    /// again) or without reporting (asked once, then `no_report`); then
    /// types the wake line of each run that settled.
    @MainActor
    func sampleTasks() async {
        for task in tasks.openTasks {
            guard !task.state.isSettled else { continue }
            guard let found = locateWorker(task) else {
                settleIfWorkerGone(task, now: Date())
                continue
            }
            let worker = found.session
            let workspace = found.workspace
            // Shown before its host answered (a relaunch): nothing is
            // decided or typed until the restore confirms the tab.
            if worker.isProvisionalRestore { continue }
            let key = ObjectIdentifier(worker)
            let now = Date()
            if monitors.lastRefreshAt[key].map({ now.timeIntervalSince($0) >= monitors.refreshInterval }) ?? true {
                monitors.lastRefreshAt[key] = now
                await refreshForMonitor(worker)
            }
            // A report may have come in meanwhile.
            guard !task.state.isSettled else { continue }
            if let end = worker.systemSessionEnd {
                // It came back ended: the system ended its session while
                // Cherry was closed.
                let reason = "its session " + AgentTaskRegistry.lowercasedFirst(end.message)
                tasks.update(task, to: .failed, event: .failed, text: "The worker's session is gone: \(reason).", reason: reason)
                continue
            }
            let status = monitorStatus(session: worker, workspace: workspace, now: Date())
            switch status {
            case "closed":
                settleIfWorkerGone(task, now: Date())
            case "exited", "disconnected":
                let exit = worker.exitCode.map { " (exit \($0))" } ?? ""
                let crashed = worker.hostSessionEnd?.isHolderLost == true
                tasks.update(
                    task, to: .failed, event: .failed,
                    text: crashed ? "The worker's session host crashed before it reported." : "The worker ended\(exit) before it reported.",
                    result: screenTailResult(of: worker, task: task),
                    reason: crashed ? "its session host crashed before it reported" : "it ended\(exit) before it reported"
                )
            case "needs_input", "permission":
                if task.state != .needsInput {
                    tasks.update(
                        task, to: .needsInput, event: .needsInput,
                        text: status == "permission" ? "It waits for a permission answer." : "It asks the user a question."
                    )
                }
            case "working":
                checkKickoff(task, worker: worker, now: Date())
                if task.kickoffDeliveredAt != nil, task.state != .working {
                    tasks.update(task, to: .working, event: task.state == .needsInput ? .resumed : .started)
                }
            case "idle":
                if task.state == .needsInput {
                    tasks.update(task, to: .working, event: .resumed)
                }
                checkKickoff(task, worker: worker, now: Date())
                checkTurnEnded(task, worker: worker, now: Date())
            default:
                // Cherry cannot tell (an agent it cannot read): only
                // report_result settles the task; its kickoff is still
                // looked after.
                checkKickoff(task, worker: worker, now: Date())
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

    // MARK: The kickoff

    /// The worker's screen as the kickoff check reads it (oldest first),
    /// with enough of its scrollback to count the kickoff's earlier copies.
    @MainActor
    private func kickoffScreen(of worker: TerminalSession, lineLimit: Int = 400) -> [String] {
        terminalOutput(for: worker, startLine: nil, lineLimit: lineLimit).lines
    }

    /// A kickoff is about to be typed into the worker (by the spawn, or
    /// again): notes when, and the copies of it its screen shows now.
    @MainActor
    func beginKickoff(_ task: AgentTask, into worker: TerminalSession) {
        task.typing = .kickoff
        task.lastKickoffAttemptAt = Date()
        task.kickoffCopiesBefore = AgentTaskRegistry.kickoffCopies(taskID: task.id, in: kickoffScreen(of: worker))
    }

    @MainActor
    private func screenKey(of worker: TerminalSession) -> String {
        AgentScreenActivity.agentKey(name: worker.agentName ?? worker.title, commandLine: worker.subtitle)
    }

    /// The worker's screen has not changed for `interval`.
    @MainActor
    private func screenIsStill(_ worker: TerminalSession, for interval: TimeInterval, now: Date) -> Bool {
        let changedAt = worker.lastContentChangeAt ?? worker.startedAt ?? .distantPast
        return now.timeIntervalSince(changedAt) >= interval
    }

    /// Lines Cherry types into a tab found again after a relaunch wait this
    /// long first.
    @MainActor
    private func inRestoredGrace(_ relinkedAt: Date?, now: Date) -> Bool {
        relinkedAt.map { now.timeIntervalSince($0) < tasks.restoredLineGrace } ?? false
    }

    /// The kickoff until it is seen sent. Not typed yet (or typed with
    /// nothing sent): typed once the worker sits at a still composer.
    /// Typed: sent once the worker's turn starts after it, the worker asks
    /// for its task, or the kickoff shows among its sent messages; else,
    /// once the screen is still, left in the composer gets its Enter, and
    /// not on screen at all is typed again (bounded; never one that may
    /// have been typed). An agent whose screen Cherry cannot read keeps
    /// the kickoff as typed.
    @MainActor
    private func checkKickoff(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard task.kickoffDeliveredAt == nil, task.fetchedAt == nil, !task.isTypingIntoWorker else { return }
        guard let typedAt = task.kickoffTypedAt else {
            guard task.kickoffAttempts < AgentTaskRegistry.maximumKickoffAttempts else {
                tasks.update(
                    task, to: .failed, event: .failed,
                    text: "Cherry could not type the kickoff into the worker.",
                    reason: "Cherry could not type its kickoff into the worker"
                )
                return
            }
            typeKickoffIfReady(
                task, worker: worker, now: now,
                retry: task.kickoffAttempts > 0 ? "The kickoff was not typed (the worker took no input then): typing it again." : nil
            )
            return
        }
        let lines = kickoffScreen(of: worker)
        let agent = screenKey(of: worker)
        let placement = AgentTaskRegistry.kickoffPlacement(taskID: task.id, in: lines, agent: agent, copiesBefore: task.kickoffCopiesBefore)
        if placement == .submitted || kickoffTurnStarted(worker, since: typedAt) {
            noteKickoffDelivered(task, at: typedAt)
            return
        }
        let lastAction = task.lastKickoffActionAt ?? typedAt
        guard now.timeIntervalSince(lastAction) >= tasks.kickoffCheckDelay,
              screenIsStill(worker, for: tasks.kickoffQuietInterval, now: now)
        else { return }
        let verdict = AgentScreenActivity.verdict(for: lines, agent: agent)
        switch placement {
        case .submitted:
            break
        case .composer:
            guard verdict == .prompt else { return }
            if task.kickoffEnterPresses < AgentTaskRegistry.maximumKickoffEnterPresses {
                pressKickoffEnter(task, worker: worker, now: now)
            } else if now.timeIntervalSince(lastAction) >= tasks.idleFallbackInterval {
                tasks.update(
                    task, to: .failed, event: .failed,
                    text: "The kickoff stayed unsent in the worker's composer.",
                    reason: "its kickoff stayed unsent in the worker's composer"
                )
            }
        case .absent:
            guard verdict == .prompt else {
                // A screen Cherry cannot read (no composer, no marker): the
                // kickoff counts as typed, as it always did.
                if verdict == .none, !worker.agentActivityEvidenceIsStrong {
                    noteKickoffDelivered(task, at: typedAt)
                }
                return
            }
            if task.kickoffUncertain || task.kickoffAttempts >= AgentTaskRegistry.maximumKickoffAttempts {
                // Never typed twice when some of it may have been; a worker
                // that sits idle without asking for its task did not get it.
                if now.timeIntervalSince(lastAction) >= tasks.idleFallbackInterval {
                    tasks.update(
                        task, to: .failed, event: .failed,
                        text: "The kickoff may not have reached the worker.",
                        reason: "its kickoff may not have reached the worker, which never asked for its task"
                    )
                }
                return
            }
            typeKickoffIfReady(task, worker: worker, now: now, retry: "The kickoff did not reach the worker: typing it again.")
        }
    }

    /// The worker's turn started after `typedAt`: working evidence since,
    /// or it was at work when the kickoff was submitted (its CLI queued it).
    @MainActor
    private func kickoffTurnStarted(_ worker: TerminalSession, since typedAt: Date) -> Bool {
        if let evidence = worker.lastStrongWorkingEvidenceAt, evidence >= typedAt { return true }
        if worker.agentWasWorkingAtLastSubmit, let submittedAt = worker.lastAgentSubmitAt, submittedAt >= typedAt { return true }
        return false
    }

    /// The worker sits at a still composer: it takes input, nobody types
    /// into it, no line of Cherry's goes in, its screen has not changed
    /// for `kickoffQuietInterval` and shows its composer (when Cherry can
    /// read it at all).
    @MainActor
    private func workerTakesKickoff(_ worker: TerminalSession, now: Date) -> Bool {
        guard worker.acceptsControlInput, !worker.humanIsComposing(within: tasks.kickoffQuietInterval),
              !isTypingWakeLine(into: worker), screenIsStill(worker, for: tasks.kickoffQuietInterval, now: now)
        else { return false }
        let verdict = AgentScreenActivity.verdict(for: kickoffScreen(of: worker, lineLimit: 80), agent: screenKey(of: worker))
        return verdict == .prompt || (verdict == .none && !worker.agentActivityEvidenceIsStrong)
    }

    /// Types the kickoff (again) once the worker takes it, at most so
    /// often; `retry` (the event's text) says why for a retry.
    @MainActor
    private func typeKickoffIfReady(_ task: AgentTask, worker: TerminalSession, now: Date, retry: String?) {
        if let last = task.lastKickoffAttemptAt, now.timeIntervalSince(last) < tasks.kickoffRetryInterval { return }
        guard !inRestoredGrace(task.relinkedAt, now: now), workerTakesKickoff(worker, now: now) else { return }
        typeKickoff(task, into: worker, retry: retry)
    }

    @MainActor
    private func typeKickoff(_ task: AgentTask, into worker: TerminalSession, retry: String?) {
        beginKickoff(task, into: worker)
        if let retry {
            tasks.record(.kickoffRetry, for: task, text: retry)
            tasks.publish()
        }
        let typedSince = Date()
        Task { @MainActor [weak self] in
            defer { task.typing = nil }
            guard let self else { return }
            do {
                _ = try await self.typeCherryLine(task.kickoffLine, into: worker)
                self.noteKickoff(task, delivered: true, error: nil, typedSince: typedSince)
            } catch {
                self.noteKickoff(task, delivered: false, error: error as? CherryControlError, typedSince: typedSince)
            }
        }
    }

    /// Presses Enter for a kickoff that sits unsent in the worker's
    /// composer (its CLI dropped the first one), under the tab's typing
    /// lock and never at a permission prompt or question menu.
    @MainActor
    private func pressKickoffEnter(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard !inRestoredGrace(task.relinkedAt, now: now), worker.acceptsControlInput,
              !worker.humanIsComposing(within: tasks.kickoffQuietInterval), !isTypingWakeLine(into: worker)
        else { return }
        task.typing = .kickoffEnter
        task.kickoffEnterPresses += 1
        task.lastKickoffActionAt = now
        tasks.record(.kickoffRetry, for: task, text: "The kickoff sat unsent in the worker's composer: pressed its Enter.")
        tasks.publish()
        Task { @MainActor [weak self] in
            defer {
                task.typing = nil
                task.lastKickoffActionAt = Date()
            }
            guard let self else { return }
            do {
                _ = try await self.typeCherryLine("", into: worker)
            } catch {
                SessionLog.debug("[task] kickoff Enter for \(task.id) not sent: \(error)")
            }
        }
    }

    /// An idle worker whose turn for the task ended: one that never asked
    /// for its task gets the kickoff again (never the report nudge), at
    /// most `maximumKickoffAttempts` kickoffs in all; one that has its
    /// task and did not report is asked once to report; after that turn
    /// too, `no_report`. Never while it waits on a monitor of its own,
    /// while Cherry types into it, or within its grace after a relaunch.
    @MainActor
    private func checkTurnEnded(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard let baselineAt = task.turnBaselineAt, task.kickoffDeliveredAt != nil, !task.isTypingIntoWorker,
              worker.agentSubmittedTurnCount >= task.turnBaseline, !inRestoredGrace(task.relinkedAt, now: now)
        else { return }
        let sawWork = worker.lastStrongWorkingEvidenceAt.map { $0 >= baselineAt } ?? false
        let completedThatTurn = worker.agentTurnState == .completed
            && (worker.lastAgentSubmitAt.map { $0 >= baselineAt } ?? false)
        guard sawWork || completedThatTurn || now.timeIntervalSince(baselineAt) >= tasks.idleFallbackInterval else { return }
        guard !awaitsMonitorWake(worker), !isTypingWakeLine(into: worker) else { return }
        guard task.fetchedAt != nil else {
            kickOffAgain(task, worker: worker, now: now)
            return
        }
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

    /// A worker idle after its kickoff's turn that never asked for its
    /// task: the kickoff again, checked like the first; once the kickoffs
    /// are used up, `failed` with its last lines.
    @MainActor
    private func kickOffAgain(_ task: AgentTask, worker: TerminalSession, now: Date) {
        guard task.kickoffAttempts < AgentTaskRegistry.maximumKickoffAttempts else {
            tasks.update(
                task, to: .failed, event: .failed,
                text: "It went idle without asking for its task, even after \(task.kickoffAttempts) kickoffs.",
                result: screenTailResult(of: worker, task: task),
                reason: "it never called get_my_task, even after \(task.kickoffAttempts) kickoffs; the result is its screen's last lines"
            )
            return
        }
        if let last = task.lastKickoffAttemptAt, now.timeIntervalSince(last) < tasks.kickoffRetryInterval { return }
        guard subscriberTakesWakeLine(worker, now: now) else { return }
        // A new kickoff, checked again until it is seen sent.
        task.kickoffDeliveredAt = nil
        task.turnBaselineAt = nil
        task.kickoffEnterPresses = 0
        let lines = kickoffScreen(of: worker)
        if AgentTaskRegistry.kickoffPlacement(taskID: task.id, in: lines, agent: screenKey(of: worker)) == .composer {
            // Its last one still sits in the composer (taken as sent by
            // mistake): its Enter, not a second copy.
            task.kickoffTypedAt = now
            task.kickoffCopiesBefore = AgentTaskRegistry.kickoffCopies(taskID: task.id, in: lines) - 1
            pressKickoffEnter(task, worker: worker, now: now)
            return
        }
        typeKickoff(task, into: worker, retry: "It went idle without asking for its task: typing the kickoff again.")
    }

    /// Types the nudge (once): a nudge that may have been typed although it
    /// failed counts as typed.
    @MainActor
    private func nudge(_ task: AgentTask, worker: TerminalSession) {
        task.typing = .nudge
        task.lastNudgeAttemptAt = Date()
        let typedSince = Date()
        Task { @MainActor [weak self] in
            defer { task.typing = nil }
            guard let self else { return }
            do {
                _ = try await self.typeCherryLine(AgentTaskRegistry.nudgeLine, into: worker)
            } catch {
                guard Self.inputMayHaveBeenTyped(error) else {
                    SessionLog.debug("[task] nudge for \(task.id) not sent: \(error)")
                    return
                }
            }
            guard !task.state.isSettled else { return }
            task.nudgedAt = Date()
            task.turnBaselineAt = typedSince
            task.turnBaseline = worker.agentSubmittedTurnCount
            self.tasks.record(.nudged, for: task)
            self.tasks.publish()
        }
    }

    /// Cherry types (or is about to type) a line into `session`: a
    /// monitor's or a run's wake line, a nudge or a kickoff.
    @MainActor
    func isTypingWakeLine(into session: TerminalSession) -> Bool {
        tasks.typingLocks.isBusy(session.id)
            || monitors.subscriptions.values.contains { $0.isWaking && $0.subscriber === session }
            || tasks.orderedRuns.contains { $0.isWaking && $0.owner === session }
            || tasks.tasks.values.contains { $0.isTypingIntoWorker && $0.workerID == session.id }
    }

    /// Types the run's wake line into its owner once every task settled,
    /// the owner did not read that yet, and it is idle (the monitors' rule,
    /// `subscriberTakesWakeLine`). An owner whose tab is not open is given
    /// up on, except after a relaunch, while its tab may still come back
    /// (`relinkGrace`); one found again waits `restoredLineGrace` first.
    @MainActor
    func deliverRunWakeIfReady(_ run: AgentRun) {
        guard monitors.wakeLinesEnabled, !run.isWaking, run.activeWaits == 0,
              tasks.awaitsWake(run), let settledSeq = run.settledSeq
        else { return }
        let now = Date()
        if run.settledAt.map({ now.timeIntervalSince($0) > tasks.wakeLifetime }) ?? false {
            run.wokenSeq = settledSeq
            tasks.scheduleSave()
            return
        }
        guard let owner = locateOwner(run) else {
            if let restoredAt = run.restoredAt, now.timeIntervalSince(restoredAt) < tasks.relinkGrace { return }
            // Nobody to wake any more.
            run.wokenSeq = settledSeq
            tasks.scheduleSave()
            return
        }
        if inRestoredGrace(run.relinkedAt, now: now) { return }
        if let last = run.lastWakeAt, now.timeIntervalSince(last) < monitors.wakeMinimumInterval { return }
        // One line at a time into a tab.
        guard !isTypingWakeLine(into: owner), subscriberTakesWakeLine(owner, now: now) else { return }
        let line = AgentTaskRegistry.wakeLine(runID: run.id, counts: tasks.counts(of: run))
        run.isWaking = true
        Task { @MainActor [weak self] in
            defer { run.isWaking = false }
            guard let self else { return }
            do {
                _ = try await self.typeCherryLine(line, into: owner)
                run.wokenSeq = max(run.wokenSeq, settledSeq)
            } catch {
                // Maybe typed: never typed twice.
                if Self.inputMayHaveBeenTyped(error) { run.wokenSeq = max(run.wokenSeq, settledSeq) }
                SessionLog.debug("[task] wake line for \(run.id) not sent: \(error)")
            }
            run.lastWakeAt = Date()
            self.tasks.scheduleSave()
        }
    }
}

// MARK: - Where a kickoff stands

/// Where the kickoff is on the worker's screen.
enum KickoffPlacement: Equatable, Sendable {
    /// On the composer's prompt line: typed, not sent.
    case composer
    /// Above the composer (among the sent messages), or on a screen with
    /// no composer.
    case submitted
    /// Not on screen.
    case absent
}

extension AgentTaskRegistry {
    /// What a kickoff starts with: its task's mark on the worker's screen.
    nonisolated static func kickoffMarker(taskID: String) -> String {
        "You are Cherry task \(taskID)"
    }

    /// Where task `taskID`'s latest kickoff is in `lines` (a screen,
    /// oldest first), when `copiesBefore` copies of it were there before it
    /// was typed: a copy on the composer's prompt line (the last prompt
    /// line on screen, `AgentScreenActivity.isInputPromptLine`, also inside
    /// a framed composer `│ > …`) is unsent; one more copy than before
    /// anywhere else (among the sent messages, or on a screen without a
    /// composer) was sent; otherwise it is not there.
    nonisolated static func kickoffPlacement(taskID: String, in lines: [String], agent: String, copiesBefore: Int = 0) -> KickoffPlacement {
        let marker = kickoffMarker(taskID: taskID)
        let copies = lines.indices.filter { lines[$0].contains(marker) }
        guard let markerLine = copies.last else { return .absent }
        if isComposerPromptLine(lines[markerLine], agent: agent),
           !lines[(markerLine + 1)...].contains(where: { isComposerPromptLine($0, agent: agent) }) {
            return .composer
        }
        return copies.count > copiesBefore ? .submitted : .absent
    }

    /// Copies of task `taskID`'s kickoff in `lines`.
    nonisolated static func kickoffCopies(taskID: String, in lines: [String]) -> Int {
        let marker = kickoffMarker(taskID: taskID)
        return lines.reduce(0) { $0 + ($1.contains(marker) ? 1 : 0) }
    }

    /// A composer's prompt line, framed (`│ > …`) or not.
    nonisolated static func isComposerPromptLine(_ line: String, agent: String) -> Bool {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if let first = trimmed.first, first == "│" || first == "┃" || first == "|" {
            trimmed = trimmed.dropFirst()
        }
        return AgentScreenActivity.isInputPromptLine(String(trimmed), agent: agent)
    }
}
