import CherryControl
import Darwin
import Foundation

// MARK: - Tasks across a relaunch
//
// MCP tasks (`AgentTasks.swift`) outlive a relaunch of Cherry: their workers
// and orchestrators usually do (persistent sessions), so a worker's
// `report_result` and an orchestrator's `wait_for_tasks` must find their
// task and run again afterwards.
//
// The app saves every run and task (`AgentTasksFileRecord`): ids, label,
// phase, brief, result schema, state, result (as stored, capped), progress,
// the worker's and owner's tab ids and sessions, device, timestamps, kickoff
// and nudge bookkeeping, and each run's events with the seqs and cursors
// `wait_for_tasks` uses. The file is `Workspaces/agent-tasks.json` in the
// identity's Application Support, written atomically (a private temporary
// file renamed over it), mode 0600, left out of backups, a second or so
// after the latest change and at quit; only by the copy of the app that
// holds the instance lock (`AppInstanceLock`): a second copy neither reads
// nor writes it. It is read only as this user's own private regular file,
// never through a link.
//
// Read back at launch (`CherryControlServer.configureTaskPersistence`;
// requests wait for it), each open task looks for its worker again: the tab
// with its id, else a tab of its session (`locateWorker`); a run's owner
// likewise (`locateOwner`). A worker whose tab does not come back is
// decided by its session on its host (`AgentTaskHostLookup`): running (a
// closed window's tab, a detached worker) keeps the task waiting; ended,
// or gone from a complete list of its host, settles it (`failed`, or
// `cancelled` for a session Cherry ended on purpose) with the reason (ended
// while Cherry was closed, when the Mac restarted, …). A host Cherry cannot
// ask yet keeps it waiting: another Mac's until it is connected again, This
// Mac's for `restoreDecisionTimeout`. Nothing is typed into a worker or
// owner found again for `restoredLineGrace`, and its idle grace starts
// over. Seqs go on after a gap (`restoredSeqGap`): a cursor inside it named
// events the file lost, and `wait_for_tasks` answers it with
// `cursor_reset`. Settled runs are forgotten a day after they settled, or
// once none of their tabs has been open or running for `goneRunLifetime`.

/// What a restored task's session is now, on its host.
enum AgentTaskSessionStatus: Equatable, Sendable {
    /// Its host lists it running.
    case running
    /// Its host lists it ended (its exit code, when known).
    case exited(Int?)
    /// A complete list of its host lacks it: why, and whether that
    /// cancels its task (Cherry ended it on purpose) instead of failing it.
    case gone(reason: String, cancels: Bool)
    /// Its host cannot be asked now (not connected, still expecting
    /// holders, or not known). `waitsForDevice`: another Mac's, waited for
    /// until it is connected again.
    case unknown(waitsForDevice: Bool)
}

// MARK: - The file

/// `Workspaces/agent-tasks.json`.
struct AgentTasksFileRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var savedAt: Date
    /// The next seq the registry gives out.
    var nextSeq: Int
    var runs: [AgentRunRecord]
    /// In creation order.
    var tasks: [AgentTaskRecord]

    init(version: Int = AgentTasksFileRecord.currentVersion, savedAt: Date, nextSeq: Int, runs: [AgentRunRecord], tasks: [AgentTaskRecord]) {
        self.version = version
        self.savedAt = savedAt
        self.nextSeq = nextSeq
        self.runs = runs
        self.tasks = tasks
    }
}

struct AgentRunRecord: Codable, Equatable, Sendable {
    var id: String
    var device: UUID?
    var ownerID: UUID?
    var ownerWakes: Bool
    var ownerSession: AgentTaskSessionBinding?
    var isImplicit: Bool
    var createdAt: Date
    var taskIDs: [String]
    var events: [AgentTaskEvent]
    var droppedThroughSeq: Int
    var settledSeq: Int?
    var settledAt: Date?
    var wokenSeq: Int
    var ownerReadSeq: Int
    var lastWakeAt: Date?
}

struct AgentTaskRecord: Codable, Equatable, Sendable {
    var id: String
    var runID: String
    var device: UUID?
    var workerID: UUID
    var workerSession: AgentTaskSessionBinding?
    var workerIsPersistent: Bool
    var label: String
    var phase: String?
    var brief: String
    var resultSchema: JSONValue?
    var createdAt: Date
    var state: AgentTaskState
    var startedAt: Date?
    var settledAt: Date?
    var reason: String?
    var result: AgentTaskResult?
    var progress: String?
    var progressAt: Date?
    var settledSeq: Int?
    var needsInputSeq: Int?
    var lastReportAt: Date?
    var fetchedAt: Date?
    var kickoffTypedAt: Date?
    var kickoffUncertain: Bool
    var kickoffDeliveredAt: Date?
    var kickoffAttempts: Int
    var lastKickoffAttemptAt: Date?
    var kickoffEnterPresses: Int
    var nudgedAt: Date?
    var lastNudgeAttemptAt: Date?
}

/// Reads and writes `agent-tasks.json` (see above).
final class AgentTaskStore: @unchecked Sendable {
    static let fileName = "agent-tasks.json"
    static let shared = AgentTaskStore(directory: WorkspaceStateStore.defaultDirectory(), instanceLock: .shared)

    let fileURL: URL
    private let instanceLock: AppInstanceLock?
    private let queue = DispatchQueue(label: "Cherry.AgentTaskStore", qos: .utility)

    /// `instanceLock`: the app's; nil (tests) reads and writes freely.
    init(directory: URL, instanceLock: AppInstanceLock? = nil) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.instanceLock = instanceLock
    }

    /// Whether this copy of the app may read and write the file now: it
    /// holds the instance lock. Never takes or waits for the lock itself.
    var isEnabled: Bool {
        guard let instanceLock else { return true }
        return instanceLock.isResolved && instanceLock.isHeld
    }

    /// `load`, once the instance lock answered: blocks while it waits for
    /// a quitting copy, so call it off the main thread.
    func loadResolvingLock() -> AgentTasksFileRecord? {
        if let instanceLock, !instanceLock.isHeld { return nil }
        return load()
    }

    /// The saved state; nil when there is none, when this copy may not use
    /// it, or when the file is not this user's own private regular file (a
    /// link is never followed). A file this version cannot decode is moved
    /// aside (`<name>.<label>-<time>.bak`), never written over.
    func load() -> AgentTasksFileRecord? {
        guard isEnabled else { return nil }
        let fileURL = fileURL
        return queue.sync { Self.read(fileURL) }
    }

    /// Saves in the background (after any save queued before it).
    func save(_ record: AgentTasksFileRecord) {
        guard isEnabled else { return }
        let fileURL = fileURL
        queue.async { Self.writeLogged(record, to: fileURL) }
    }

    /// Saves now and waits (a quit).
    func saveSynchronously(_ record: AgentTasksFileRecord) {
        guard isEnabled else { return }
        let fileURL = fileURL
        queue.sync { Self.writeLogged(record, to: fileURL) }
    }

    /// Waits for every save queued so far.
    func flush() {
        queue.sync {}
    }

    private static func read(_ fileURL: URL) -> AgentTasksFileRecord? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return nil }
        // This user's own private regular file only, never through a link.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            SessionLog.debug("[task] not reading \(fileURL.lastPathComponent): not this user's private regular file")
            return nil
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return nil }
        // Dates as `Date` encodes them (exact to the bit).
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(AgentTasksFileRecord.self, from: data),
           record.version == AgentTasksFileRecord.currentVersion {
            return record
        }
        struct VersionOnly: Decodable { let version: Int }
        let label = (try? decoder.decode(VersionOnly.self, from: data)).map { "v\($0.version)" } ?? "unreadable"
        setAside(fileURL, label: label)
        return nil
    }

    /// Moves a file this version cannot use out of the way of the next
    /// save, beside it (`WorkspaceStateStore.pruneSetAsideFiles` removes
    /// old ones).
    private static func setAside(_ fileURL: URL, label: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let destination = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).\(label)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).bak"
        )
        if rename(fileURL.path, destination.path) == 0 {
            fputs("Cherry: \(fileURL.lastPathComponent) cannot be used by this version (\(label)); moved it to \(destination.lastPathComponent)\n", stderr)
        }
    }

    private static func writeLogged(_ record: AgentTasksFileRecord, to fileURL: URL) {
        do {
            try write(record, to: fileURL)
        } catch {
            fputs("Cherry: could not save \(fileURL.lastPathComponent): \(error)\n", stderr)
        }
    }

    /// A private temporary file beside the destination, renamed over it:
    /// readers see the old file or the new one, never part of one. The
    /// rename replaces whatever is there (a link included), never what a
    /// link points to.
    static func write(_ record: AgentTasksFileRecord, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? temporary.setResourceValues(values)
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? manager.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }
}

// MARK: - Saving and reading back

extension AgentTaskRegistry {
    /// The app's registry (its control server's), saved at quit.
    nonisolated(unsafe) static weak var app: AgentTaskRegistry?

    /// The saved file is kept under this: the oldest settled runs are left
    /// out beyond it.
    static let maximumFileBytes = 24 << 20

    /// Saves a little later, with whatever else changes meanwhile.
    func scheduleSave() {
        guard store != nil, isRestoreSettled else { return }
        hasUnsavedChanges = true
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.saveTask = nil
            guard self.hasUnsavedChanges, let store = self.store else { return }
            self.hasUnsavedChanges = false
            store.save(self.fileRecord())
        }
    }

    /// Saves now and waits for the file (a quit, tests).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let store, isRestoreSettled else { return }
        hasUnsavedChanges = false
        store.saveSynchronously(fileRecord())
    }

    /// Everything as it stands, for the file. Cherry's lines being typed
    /// now count as typed (a kickoff as maybe typed): never typed twice.
    func fileRecord(now: Date = Date()) -> AgentTasksFileRecord {
        var omitted = Set<String>()
        var total = orderedRuns.reduce(0) { $0 + estimatedBytes(of: $1) }
        for run in orderedRuns where total > Self.maximumFileBytes && !isOpen(run) {
            omitted.insert(run.id)
            total -= estimatedBytes(of: run)
        }
        let kept = orderedRuns.filter { !omitted.contains($0.id) }
        return AgentTasksFileRecord(
            savedAt: now,
            nextSeq: nextSeq,
            runs: kept.map(record(of:)),
            tasks: taskOrder.compactMap { tasks[$0] }.filter { !omitted.contains($0.runID) }.map(record(of:))
        )
    }

    private func estimatedBytes(of run: AgentRun) -> Int {
        var bytes = 512 + run.events.reduce(0) { $0 + 256 + ($1.text?.utf8.count ?? 0) + $1.label.utf8.count }
        for task in tasks(of: run) {
            bytes += 1_024 + task.brief.utf8.count + task.label.utf8.count + (task.progress?.utf8.count ?? 0)
                + (task.result?.summary?.utf8.count ?? 0) + resultBytes(of: task) + schemaBytes(of: task)
        }
        return bytes
    }

    private func resultBytes(of task: AgentTask) -> Int {
        guard let result = task.result else { return 0 }
        if let cached = task.resultBytes, cached.version == result.version { return cached.bytes }
        let bytes = result.value?.encodedByteCount ?? 0
        task.resultBytes = (result.version, bytes)
        return bytes
    }

    private func schemaBytes(of task: AgentTask) -> Int {
        // Linted at most 64 KiB; counted at that when there is one.
        task.resultSchema == nil ? 0 : TaskResultSchema.maximumEncodedBytes
    }

    private func record(of run: AgentRun) -> AgentRunRecord {
        var wokenSeq = run.wokenSeq
        // A wake line being typed may be typed: never typed twice.
        if run.isWaking, let settledSeq = run.settledSeq { wokenSeq = max(wokenSeq, settledSeq) }
        return AgentRunRecord(
            id: run.id,
            device: run.device,
            ownerID: run.ownerID,
            ownerWakes: run.ownerWakes,
            ownerSession: run.ownerSession,
            isImplicit: run.isImplicit,
            createdAt: run.createdAt,
            taskIDs: run.taskIDs,
            events: run.events,
            droppedThroughSeq: run.droppedThroughSeq,
            settledSeq: run.settledSeq,
            settledAt: run.settledAt,
            wokenSeq: wokenSeq,
            ownerReadSeq: run.ownerReadSeq,
            lastWakeAt: run.lastWakeAt
        )
    }

    private func record(of task: AgentTask) -> AgentTaskRecord {
        var typedAt = task.kickoffTypedAt
        var uncertain = task.kickoffUncertain
        var nudgedAt = task.nudgedAt
        switch task.typing {
        case .kickoff?:
            // Being typed: it may be typed, so it is never typed again.
            typedAt = task.lastKickoffAttemptAt ?? Date()
            uncertain = true
        case .nudge?:
            nudgedAt = nudgedAt ?? task.lastNudgeAttemptAt ?? Date()
        case .kickoffPending?, .kickoffEnter?, nil:
            break
        }
        return AgentTaskRecord(
            id: task.id,
            runID: task.runID,
            device: task.device,
            workerID: task.workerID,
            workerSession: task.workerSession,
            workerIsPersistent: task.workerIsPersistent,
            label: task.label,
            phase: task.phase,
            brief: task.brief,
            resultSchema: task.resultSchema,
            createdAt: task.createdAt,
            state: task.state,
            startedAt: task.startedAt,
            settledAt: task.settledAt,
            reason: task.reason,
            result: task.result,
            progress: task.progress,
            progressAt: task.progressAt,
            settledSeq: task.settledSeq,
            needsInputSeq: task.needsInputSeq,
            lastReportAt: task.lastReportAt,
            fetchedAt: task.fetchedAt,
            kickoffTypedAt: typedAt,
            kickoffUncertain: uncertain,
            kickoffDeliveredAt: task.kickoffDeliveredAt,
            kickoffAttempts: task.kickoffAttempts,
            lastKickoffAttemptAt: task.lastKickoffAttemptAt,
            kickoffEnterPresses: task.kickoffEnterPresses,
            nudgedAt: nudgedAt,
            lastNudgeAttemptAt: task.lastNudgeAttemptAt
        )
    }

    /// Reads back the saved state into this (empty) registry: every run and
    /// task as saved, their events and seqs (this run's seqs go on after a
    /// gap). Each open task, and each run whose owner a wake line may go
    /// to, looks for its tab again (`restoredAt`). Settled runs past their
    /// lifetime are left out.
    func restore(from record: AgentTasksFileRecord, now: Date = Date()) {
        guard tasks.isEmpty, runs.isEmpty, record.version == AgentTasksFileRecord.currentVersion else { return }
        var highestSeq = record.nextSeq - 1
        let taskRecords = Dictionary(record.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for saved in record.runs where runs[saved.id] == nil {
            let taskIDs = saved.taskIDs.filter { taskRecords[$0]?.runID == saved.id }
            guard !taskIDs.isEmpty else { continue }
            let run = AgentRun(
                id: saved.id, device: saved.device, ownerID: saved.ownerID, owner: nil,
                isImplicit: saved.isImplicit, ownerWakes: saved.ownerWakes, createdAt: saved.createdAt
            )
            run.ownerSession = saved.ownerSession
            run.taskIDs = taskIDs
            run.events = saved.events.sorted { $0.seq < $1.seq }
            run.droppedThroughSeq = saved.droppedThroughSeq
            run.settledSeq = saved.settledSeq
            run.settledAt = saved.settledAt
            run.wokenSeq = saved.wokenSeq
            run.ownerReadSeq = saved.ownerReadSeq
            run.lastWakeAt = saved.lastWakeAt
            if run.ownerWakes { run.restoredAt = now }
            highestSeq = max(highestSeq, run.events.last?.seq ?? 0, run.settledSeq ?? 0, run.droppedThroughSeq)
            insert(run)
        }
        for saved in record.tasks where tasks[saved.id] == nil && runs[saved.runID]?.taskIDs.contains(saved.id) == true {
            let task = AgentTask(
                id: saved.id, runID: saved.runID, device: saved.device, workerID: saved.workerID,
                worker: nil, workspace: nil, label: saved.label, phase: saved.phase, brief: saved.brief,
                resultSchema: saved.resultSchema, createdAt: saved.createdAt
            )
            task.workerSession = saved.workerSession
            task.workerIsPersistent = saved.workerIsPersistent
            task.hostSessionID = saved.workerSession?.sessionID
            task.state = saved.state
            task.startedAt = saved.startedAt
            task.settledAt = saved.settledAt
            task.reason = saved.reason
            task.result = saved.result
            task.progress = saved.progress
            task.progressAt = saved.progressAt
            task.settledSeq = saved.settledSeq
            task.needsInputSeq = saved.needsInputSeq
            task.lastReportAt = saved.lastReportAt
            task.fetchedAt = saved.fetchedAt
            task.kickoffTypedAt = saved.kickoffTypedAt
            task.kickoffUncertain = saved.kickoffUncertain
            task.kickoffDeliveredAt = saved.kickoffDeliveredAt
            task.kickoffAttempts = saved.kickoffAttempts
            task.lastKickoffAttemptAt = saved.lastKickoffAttemptAt
            task.kickoffEnterPresses = saved.kickoffEnterPresses
            task.nudgedAt = saved.nudgedAt
            task.lastNudgeAttemptAt = saved.lastNudgeAttemptAt
            // Its turn is looked at again from when its tab is found.
            task.turnBaselineAt = nil
            if !task.state.isSettled { task.restoredAt = now }
            highestSeq = max(highestSeq, task.settledSeq ?? 0, task.needsInputSeq ?? 0)
            insertRestored(task)
        }
        for run in orderedRuns {
            run.taskIDs = run.taskIDs.filter { tasks[$0] != nil }
        }
        continueSeqs(afterSaved: highestSeq + 1, restoredAt: now, fileSavedAt: record.savedAt)
        pruneExpiredRuns(now: now)
        publish()
    }

    /// Forgets settled runs that settled more than `settledRunLifetime`
    /// ago. True when it forgot any.
    @discardableResult
    func pruneExpiredRuns(now: Date = Date()) -> Bool {
        var removed = false
        for run in orderedRuns where !isOpen(run) {
            guard let settledAt = run.settledAt, now.timeIntervalSince(settledAt) >= settledRunLifetime else { continue }
            remove(run)
            removed = true
        }
        return removed
    }
}

// MARK: - The app's side

extension CherryControlServer {
    /// The app's: tasks survive a relaunch. Reads the saved file off the
    /// main thread once the instance lock answered (requests wait for it,
    /// `handleRequestData`), then saves every change while this copy holds
    /// the lock. A restored task's session is looked for on `hostings`.
    @MainActor
    func configureTaskPersistence(
        store: AgentTaskStore,
        hostings: PersistentHostingRegistry,
        stateStore: WorkspaceStateStore
    ) {
        tasks.store = store
        tasks.hostingForSession = { binding in AgentTaskHostLookup.hosting(for: binding, in: hostings) }
        tasks.sessionStatus = { binding, hosting, savedAt in
            AgentTaskHostLookup.status(of: binding, hosting: hosting, savedAt: savedAt, stateStore: stateStore)
        }
        tasks.isRestoreSettled = false
        AgentTaskRegistry.app = tasks
        tasks.restoreTask = Task { @MainActor [weak self] in
            let record = await Task.detached(priority: .userInitiated) { store.loadResolvingLock() }.value
            self?.restoreTasks(from: record)
        }
    }

    /// Reads back `record` (nil: nothing was saved, or this copy may not
    /// use it) and starts watching what came back.
    @MainActor
    func restoreTasks(from record: AgentTasksFileRecord?, now: Date = Date()) {
        if let record { tasks.restore(from: record, now: now) }
        tasks.isRestoreSettled = true
        tasks.restoreTask = nil
        startMonitorSamplerIfNeeded()
        startTaskMaintenanceIfNeeded()
    }

    /// Every few minutes while there are runs: forgets settled runs past
    /// their lifetime (`pruneSettledRuns`).
    @MainActor
    func startTaskMaintenanceIfNeeded() {
        guard tasks.pruneTask == nil, !tasks.runs.isEmpty else { return }
        tasks.pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tasks.maintenanceInterval else { break }
                try? await Task.sleep(for: interval)
                guard let self, !self.tasks.runs.isEmpty else { break }
                self.pruneSettledRuns()
            }
            self?.tasks.pruneTask = nil
        }
    }

    /// Forgets settled runs a day after they settled
    /// (`settledRunLifetime`), or once none of their tabs (owner and
    /// workers) has been in an open window or run as a session for
    /// `goneRunLifetime`. Never an open run.
    @MainActor
    func pruneSettledRuns(now: Date = Date()) {
        guard tasks.isRestoreSettled else { return }
        var removed = tasks.pruneExpiredRuns(now: now)
        let workspaces = allOpenWorkspaces()
        for run in tasks.orderedRuns where !tasks.isOpen(run) {
            guard runTabsAreGone(run, in: workspaces) else {
                run.tabsGoneSince = nil
                continue
            }
            let since = run.tabsGoneSince ?? now
            run.tabsGoneSince = since
            if now.timeIntervalSince(since) >= tasks.goneRunLifetime {
                tasks.remove(run)
                removed = true
            }
        }
        if removed { tasks.publish() }
    }

    /// None of the run's tabs (its owner's, its workers') is in an open
    /// window, and none of their sessions runs (or might: a host Cherry
    /// cannot ask now counts as running).
    @MainActor
    private func runTabsAreGone(_ run: AgentRun, in workspaces: [TerminalWorkspace]) -> Bool {
        var ids = Set<UUID>()
        var sessions: [AgentTaskSessionBinding] = []
        if let ownerID = run.ownerID { ids.insert(ownerID) }
        if let session = run.ownerSession { sessions.append(session) }
        for task in tasks.tasks(of: run) {
            ids.insert(task.workerID)
            if let session = task.workerSession { sessions.append(session) }
        }
        if workspaces.contains(where: { $0.sessions.contains { ids.contains($0.id) } }) { return false }
        for binding in sessions {
            switch tasks.sessionStatus(binding, tasks.hostingForSession(binding), tasks.restoredFileSavedAt) {
            case .gone, .exited: continue
            case .running, .unknown: return false
            }
        }
        return true
    }

    /// The task's worker's host, as far as Cherry knows it: the one its tab
    /// ran on, or (after a relaunch) the host its session names.
    @MainActor
    func hosting(of task: AgentTask) -> PersistentLocalSessions? {
        if let hosting = task.hosting { return hosting }
        guard let binding = task.workerSession, let hosting = tasks.hostingForSession(binding) else { return nil }
        task.hosting = hosting
        task.hostSessionID = binding.sessionID
        return hosting
    }

    /// A restored task whose worker's tab has not come back: decided by
    /// its session on its host. Running (a closed window's tab, a detached
    /// worker) keeps it waiting; ended or gone settles it, saying why; a
    /// host Cherry cannot ask yet keeps it waiting (another Mac's until it
    /// is connected, This Mac's for `restoreDecisionTimeout`). Without a
    /// session (a native tab, or one whose session was still being made)
    /// only its tab coming back within `relinkGrace` keeps it.
    @MainActor
    func settleRestoredWorkerIfGone(_ task: AgentTask, restoredAt: Date, now: Date) {
        guard let binding = task.workerSession else {
            guard now.timeIntervalSince(restoredAt) >= tasks.relinkGrace else { return }
            tasks.update(
                task, to: .failed, event: .failed,
                text: "The worker's tab did not come back after Cherry relaunched.",
                reason: task.workerIsPersistent
                    ? "its tab did not come back after Cherry relaunched"
                    : "its tab ran no persistent session, so its program ended when Cherry quit"
            )
            return
        }
        let hosting = hosting(of: task)
        switch tasks.sessionStatus(binding, hosting, tasks.restoredFileSavedAt) {
        case .running:
            return
        case .exited(let code):
            let exit = code.map { " (exit \($0))" } ?? ""
            tasks.update(
                task, to: .failed, event: .failed,
                text: "The worker ended\(exit) before it reported.",
                reason: "it ended\(exit) before it reported"
            )
        case .gone(let reason, let cancels):
            tasks.update(
                task, to: cancels ? .cancelled : .failed, event: cancels ? .cancelled : .failed,
                text: "The worker's session is gone: \(reason).",
                reason: reason
            )
        case .unknown(let waitsForDevice):
            guard !waitsForDevice, now.timeIntervalSince(restoredAt) >= tasks.restoreDecisionTimeout else { return }
            tasks.update(
                task, to: .failed, event: .failed,
                text: "Cherry could not find the worker's session after it relaunched.",
                reason: "Cherry could not find its session after it relaunched"
            )
        }
    }
}

/// How the app looks for a restored task's session: on the hosting of the
/// host it names (This Mac's or a device's), from what that hosting's
/// control already knows. It never connects a host or starts a daemon.
@MainActor
enum AgentTaskHostLookup {
    static func hosting(for binding: AgentTaskSessionBinding, in registry: PersistentHostingRegistry) -> PersistentLocalSessions? {
        let record = HostedSessionBindingRecord(host: binding.host, hostID: binding.hostID ?? "", sessionID: binding.sessionID)
        guard let host = record.hostedSessionHost else { return nil }
        return registry.hosting(for: host)
    }

    /// The session as its host last reported it. Gone only from a complete
    /// list of the same host (connected, listed, no holders still to come):
    /// cancelled when Cherry ended it on purpose; otherwise failed with
    /// what ended it (`SystemEndedSessions`: a restart, a log out, a lost
    /// holder; on another Mac only its host's word), or "while Cherry was
    /// closed".
    static func status(
        of binding: AgentTaskSessionBinding,
        hosting: PersistentLocalSessions?,
        savedAt: Date?,
        stateStore: WorkspaceStateStore
    ) -> AgentTaskSessionStatus {
        let remote = binding.host != HostedSessionHost.local.id
        guard let hosting else { return .unknown(waitsForDevice: remote) }
        // Being ended (or a close of its tab may still be undone): its
        // end decides.
        if hosting.isEnding(binding.sessionID) { return .unknown(waitsForDevice: remote) }
        let control = hosting.control
        let sameHost = binding.hostID == nil || control.hostID == nil || control.hostID == binding.hostID
        if sameHost, let info = hosting.sessionInfo(binding.sessionID) {
            return info.isRunning ? .running : .exited(info.exitCode.map { Int($0) })
        }
        guard control.state == .connected, control.hasListedSessions, !control.expectsHolders,
              let hostID = control.hostID
        else { return .unknown(waitsForDevice: remote) }
        if let expected = binding.hostID, expected != hostID {
            return .gone(reason: "its session's host is not the one it ran on any more", cancels: false)
        }
        let record = WorkspaceSessionRecord(
            id: UUID(), kind: .agent, title: "", workingDirectory: "",
            hosted: HostedSessionBindingRecord(host: binding.host, hostID: hostID, sessionID: binding.sessionID, owned: true),
            savedAt: savedAt
        )
        if stateStore.wasEndedOnPurpose(record) {
            return .gone(reason: "its session was ended in Cherry before it reported", cancels: true)
        }
        let lost = stateStore.lostSessions(hostID: hostID).contains(binding.sessionID)
        if !hosting.profile.isThisMac {
            return .gone(
                reason: lost ? "its session ended when \(hosting.profile.displayName) restarted" : "its session ended while Cherry was closed",
                cancels: false
            )
        }
        if let end = SystemEndedSessions.end(
            savedAt: savedAt, bootTime: SystemEndedSessions.currentBootTime(),
            systemQuits: stateStore.loadSystemQuits(), lostByHost: lost
        ) {
            return .gone(reason: "its session " + AgentTaskRegistry.lowercasedFirst(end.message), cancels: false)
        }
        return .gone(reason: "its session ended while Cherry was closed", cancels: false)
    }
}

extension AgentTaskRegistry {
    /// "Ended when the Mac restarted" → "ended when the Mac restarted".
    nonisolated static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
