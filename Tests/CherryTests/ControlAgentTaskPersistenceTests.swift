import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// MCP tasks across a relaunch (docs/mcp.md › Tasks And Results): the saved
// file (`AgentTaskStore`, `agent-tasks.json`) and what a new registry does
// with it. A relaunch is a second control server whose registry reads the
// first one's file, with its tabs brought back (same ids, as a restore
// does). Stores live in private directories; no test touches the app's.

/// A private directory (0700), removed by the caller.
private func privateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-agent-tasks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

@MainActor
private extension ControlAgentWaitHarness {
    func spawnWorker(
        _ name: String = "Worker",
        command: String = "/bin/cat",
        task brief: String,
        label: String? = nil
    ) async throws -> (session: TerminalSession, task: AgentTaskInfo) {
        try settings.upsertAgent(AgentToolDefinition(name: name, command: command))
        let response = try await send(.spawnProcess(.init(kind: "agent", name: name, task: brief, label: label)))
        guard case .spawnProcess(let spawned)? = response.result, let task = spawned.task else {
            throw CherryControlError(code: "spawn_failed", message: "\(String(describing: response))")
        }
        return (try #require(workspace.session(id: spawned.process.id)), task)
    }

    func waitTasks(_ request: WaitForTasksRequest) async throws -> WaitForTasksResult {
        let response = try await send(.waitForTasks(request))
        guard case .waitForTasks(let result)? = response.result else {
            throw CherryControlError(code: "wait_failed", message: "\(String(describing: response))")
        }
        return result
    }

    func taskDetail(_ id: String) async throws -> AgentTaskDetail {
        let response = try await send(.getTask(.init(taskID: id)))
        guard case .getTask(let detail)? = response.result else {
            throw CherryControlError(code: "get_task_failed", message: "\(String(describing: response))")
        }
        return detail
    }

    func outputText(of session: TerminalSession) async throws -> String {
        let response = try await send(.getProcessOutput(.init(processID: session.id.uuidString, lineLimit: 200)))
        guard case .getProcessOutput(let output)? = response.result else { return "" }
        return output.lines.joined(separator: "\n")
    }

    /// The tab `id` back in this window, as a relaunch's restore brings it.
    func restoreTab(id: UUID, name: String, command: String = "/bin/cat") throws -> TerminalSession {
        let agent = AgentToolDefinition(name: name, command: command)
        try settings.upsertAgent(agent)
        let session = workspace.addAgentSession(id: id, agent: agent, projectRoot: projectRoot.path, select: false)
        #expect(session.id == id)
        return session
    }

    /// Reads back what `store` has, as the app does at launch.
    func relaunch(from store: AgentTaskStore, record: AgentTasksFileRecord? = nil) {
        server.tasks.store = store
        server.restoreTasks(from: record ?? store.load())
    }

    /// Sampling and kickoff checks fast; a restored tab waits `grace`.
    func useFastRestoredSampling(grace: TimeInterval = 0.5) {
        let monitors = server.monitors
        monitors.sampleInterval = .milliseconds(50)
        monitors.settleInterval = 0.3
        monitors.wakeQuietInterval = 0.3
        monitors.wakeMinimumInterval = 0
        monitors.humanTypingInterval = 0
        monitors.refreshInterval = 0
        server.tasks.kickoffCheckDelay = 0.4
        server.tasks.kickoffQuietInterval = 0.5
        server.tasks.kickoffRetryInterval = 0.8
        server.tasks.restoredLineGrace = grace
    }
}

@MainActor
@Suite(.serialized)
struct ControlAgentTaskPersistenceTests {
    /// Everything a task and its run are saved with comes back as it was:
    /// the file decodes to the record it was written from, and a new
    /// registry reads it into the same tasks, results, progress and events,
    /// its seqs going on after a gap.
    @Test func savedTasksReadBackAsTheyWere() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.tasks.store = store
        harness.server.start()
        let lead = try await harness.spawnAgent(named: "Lead")
        harness.server.callerSessionResolverForTesting = { _ in lead }
        let (workerA, taskA) = try await harness.spawnWorker(task: "Brief A", label: "A")
        let (workerB, taskB) = try await harness.spawnWorker(task: "Brief B\nwith two lines", label: "B")
        harness.server.callerSessionResolverForTesting = { _ in workerA }
        let value = try JSONValue.parse(Data(#"{"files":["a.swift"],"count":2}"#.utf8))
        #expect(try await harness.send(.reportResult(.init(value: value, summary: "A done"))).error == nil)
        harness.server.callerSessionResolverForTesting = { _ in workerB }
        #expect(try await harness.send(.getMyTask).error == nil)
        #expect(try await harness.send(.reportProgress(.init(message: "Half way"))).error == nil)

        harness.server.tasks.saveNow()
        let saved = try #require(store.load())
        #expect(saved == harness.server.tasks.fileRecord(now: saved.savedAt))
        #expect(saved.runs.count == 1 && saved.tasks.map(\.id) == [taskA.taskID, taskB.taskID])
        #expect(saved.tasks.first?.workerID == workerA.id)
        #expect(saved.runs.first?.ownerID == lead.id && saved.runs.first?.ownerWakes == true)

        let other = AgentTaskRegistry(board: AgentTaskBoard())
        other.restore(from: saved)
        for id in [taskA.taskID, taskB.taskID] {
            let original = try #require(harness.server.tasks.tasks[id])
            let restored = try #require(other.tasks[id])
            #expect(other.detail(for: restored) == harness.server.tasks.detail(for: original))
            #expect(restored.workerID == original.workerID && restored.fetchedAt == original.fetchedAt)
        }
        let run = try #require(other.runs[taskA.runID])
        #expect(run.events == harness.server.tasks.runs[taskA.runID]?.events)
        #expect(other.info(for: run).counts == harness.server.tasks.info(for: try #require(harness.server.tasks.runs[taskA.runID])).counts)
        #expect(other.nextSeq == saved.nextSeq + AgentTaskRegistry.restoredSeqGap)
        // The sidebar shows the restored workers' tasks.
        #expect(other.board.badges[workerA.id]?.state == .reported)
        #expect(other.board.badges[workerB.id]?.label == "B")
    }

    /// After a relaunch the worker's and orchestrator's tabs come back with
    /// their ids: the task's worker and the run's owner are those tabs
    /// again, and the orchestrator's own runs are its default selection.
    /// A worker's tab bound to the task's session under another id is the
    /// worker too.
    @Test func restoreRelinksWorkerAndOrchestratorByTabID() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let before = try ControlAgentWaitHarness()
        before.server.tasks.store = store
        before.server.start()
        let lead = try await before.spawnAgent(named: "Lead")
        before.server.callerSessionResolverForTesting = { _ in lead }
        let (worker, task) = try await before.spawnWorker(task: "Brief", label: "Relinked")
        let (other, otherTask) = try await before.spawnWorker(task: "Another", label: "By session")
        before.server.tasks.saveNow()
        let leadID = lead.id, workerID = worker.id, otherID = other.id
        before.stop()

        // The other worker ran in a hosted session (as a persistent tab).
        var record = try #require(store.load())
        let binding = AgentTaskSessionBinding(host: HostedSessionHost.local.id, hostID: "host-1", sessionID: "session-other")
        record.tasks = record.tasks.map { saved in
            var saved = saved
            if saved.id == otherTask.taskID { saved.workerSession = binding }
            return saved
        }
        let after = try ControlAgentWaitHarness()
        defer { after.stop() }
        after.server.start()
        after.relaunch(from: store, record: record)
        let restored = try #require(after.server.tasks.tasks[task.taskID])
        #expect(restored.restoredAt != nil && restored.worker == nil)
        #expect(after.server.locateWorker(restored) == nil, "its tab is not back yet")
        #expect(!restored.state.isSettled, "a tab that may come back keeps its task open")

        let workerBack = try after.restoreTab(id: workerID, name: "Worker")
        let leadBack = try after.restoreTab(id: leadID, name: "Lead")
        #expect(after.server.locateWorker(restored)?.session === workerBack)
        #expect(restored.worker === workerBack && restored.restoredAt == nil && restored.relinkedAt != nil)
        let run = try #require(after.server.tasks.runs[task.runID])
        #expect(after.server.locateOwner(run) === leadBack)
        #expect(run.owner === leadBack && run.relinkedAt != nil)

        // Its session's tab, under another id, is the other task's worker.
        let attachment = HostedSessionAttachment(
            host: .local, hostID: "host-1", sessionID: "session-other", name: "Other",
            remoteWorkingDirectory: "/", executablePath: "/nonexistent/cherry"
        )
        let bound = after.workspace.attachHostedSession(attachment, launchShell: false)
        #expect(bound.id != otherID)
        let otherRestored = try #require(after.server.tasks.tasks[otherTask.taskID])
        #expect(after.server.locateWorker(otherRestored)?.session === bound)
        #expect(otherRestored.workerID == bound.id)

        // The orchestrator's runs are its own again; the worker its task's.
        after.server.callerSessionResolverForTesting = { _ in leadBack }
        let waited = try await after.waitTasks(.init(timeoutMilliseconds: 0))
        #expect(waited.runs.map(\.runID) == [task.runID])
        #expect(waited.runs.first?.ownerProcessID == leadID.uuidString)
        after.server.callerSessionResolverForTesting = { _ in workerBack }
        let mine = try await after.send(.getMyTask)
        guard case .getMyTask(let assignment)? = mine.result else {
            Issue.record("Expected getMyTask, got \(mine)")
            return
        }
        #expect(assignment.taskID == task.taskID && assignment.brief == "Brief")
        #expect(after.server.tasks.board.badges[workerID]?.label == "Relinked")
    }

    /// A worker reports after a relaunch, and the orchestrator's
    /// `wait_for_tasks` from the cursor it had before sees it; a cursor
    /// among the seqs a relaunch skipped (events the file lost) is answered
    /// at once with `cursor_reset` and every task's state.
    @Test func workerReportsAfterARelaunchAndTheOrchestratorsWaitSeesIt() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let before = try ControlAgentWaitHarness()
        before.server.tasks.store = store
        before.server.start()
        let lead = try await before.spawnAgent(named: "Lead")
        before.server.callerSessionResolverForTesting = { _ in lead }
        let (workerA, taskA) = try await before.spawnWorker(task: "Brief A", label: "A")
        let (workerB, taskB) = try await before.spawnWorker(task: "Brief B", label: "B")
        before.server.callerSessionResolverForTesting = { _ in workerB }
        #expect(try await before.send(.reportResult(.init(value: .string("b"), summary: "B done"))).error == nil)
        before.server.callerSessionResolverForTesting = { _ in lead }
        let read = try await before.waitTasks(.init(runID: taskA.runID, timeoutMilliseconds: 0))
        #expect(read.completed.map(\.taskID) == [taskB.taskID])
        let cursor = read.cursor
        before.server.tasks.saveNow()
        let savedNextSeq = try #require(store.load()).nextSeq
        let leadID = lead.id, workerID = workerA.id
        before.stop()

        let after = try ControlAgentWaitHarness()
        defer { after.stop() }
        after.server.start()
        after.relaunch(from: store)
        let workerBack = try after.restoreTab(id: workerID, name: "Worker")
        let leadBack = try after.restoreTab(id: leadID, name: "Lead")

        // The worker finds its task, and reports.
        after.server.callerSessionResolverForTesting = { _ in workerBack }
        let mine = try await after.send(.getMyTask)
        guard case .getMyTask(let assignment)? = mine.result else {
            Issue.record("Expected getMyTask, got \(mine)")
            return
        }
        #expect(assignment.taskID == taskA.taskID && assignment.runID == taskA.runID)
        let reported = try await after.send(.reportResult(.init(value: .string("a"), summary: "A done after a relaunch")))
        #expect(reported.error == nil, "\(String(describing: reported.error))")

        // The orchestrator's wait from its old cursor sees it.
        after.server.callerSessionResolverForTesting = { _ in leadBack }
        let waited = try await after.waitTasks(.init(runID: taskA.runID, until: "all", cursor: cursor, timeoutMilliseconds: 5_000))
        #expect(!waited.timedOut && waited.cursorReset == nil)
        let report = try #require(waited.events.first { $0.taskID == taskA.taskID && $0.kind == .reported })
        #expect(report.seq > cursor && report.text == "A done after a relaunch")
        #expect(!waited.events.contains { $0.taskID == taskB.taskID }, "B's events were read before the relaunch")
        #expect(Set(waited.completed.map(\.taskID)) == [taskA.taskID, taskB.taskID] && waited.pending.isEmpty)
        #expect(waited.cursor >= report.seq)
        #expect(try await after.taskDetail(taskA.taskID).result?.summary == "A done after a relaunch")

        // A cursor the file never had.
        let lost = try await after.waitTasks(.init(runID: taskA.runID, cursor: savedNextSeq + 3, timeoutMilliseconds: 5_000))
        #expect(lost.cursorReset == true && !lost.timedOut)
        #expect(lost.events.contains { $0.kind == .queued && $0.taskID == taskB.taskID }, "from the first event kept")
        #expect(Set(lost.completed.map(\.taskID)) == [taskA.taskID, taskB.taskID])
        #expect(after.server.tasks.cursorIsValid(lost.cursor))
    }

    /// A restored task whose worker's tab does not come back is decided by
    /// its session on its host: gone fails it (or cancels it, ended on
    /// purpose), ended fails it with its exit, a native tab's fails once
    /// its tab had its chance, one the system ended (its tab came back
    /// ended) fails saying so; running, or on a Mac Cherry cannot reach,
    /// keeps it waiting. Settled tasks stay as they were, and a device's
    /// task stays its Mac's.
    @Test func missingSessionsFailTheirTasks() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let before = try ControlAgentWaitHarness()
        before.server.tasks.store = store
        before.server.start()
        let lead = try await before.spawnAgent(named: "Lead")
        before.server.callerSessionResolverForTesting = { _ in lead }
        var spawned: [String: (id: String, worker: UUID)] = [:]
        for name in ["gone", "ended", "exited", "native", "running", "device", "systemEnded", "settled"] {
            let (worker, task) = try await before.spawnWorker(task: "Brief \(name)", label: name)
            spawned[name] = (task.taskID, worker.id)
        }
        let settledID = try #require(spawned["settled"]).worker
        let settledWorker = try #require(before.workspace.sessions.first { $0.id == settledID })
        before.server.callerSessionResolverForTesting = { _ in settledWorker }
        #expect(try await before.send(.reportResult(.init(value: .null, summary: "Done before"))).error == nil)
        before.server.tasks.saveNow()
        before.stop()

        let device = UUID()
        var record = try #require(store.load())
        func binding(_ session: String, host: String = HostedSessionHost.local.id) -> AgentTaskSessionBinding {
            AgentTaskSessionBinding(host: host, hostID: "host-1", sessionID: session)
        }
        record.tasks = record.tasks.map { saved in
            var saved = saved
            switch saved.label {
            case "gone": saved.workerSession = binding("s-gone")
            case "ended": saved.workerSession = binding("s-ended")
            case "exited": saved.workerSession = binding("s-exited")
            case "running":
                // Saved after its worker started.
                saved.workerSession = binding("s-running")
                saved.state = .working
                saved.startedAt = saved.startedAt ?? saved.createdAt
            case "device":
                saved.workerSession = binding("s-device", host: "ssh:studio")
                saved.device = device
            case "systemEnded", "settled": saved.workerSession = binding("s-\(saved.label)")
            default: saved.workerSession = nil
            }
            return saved
        }
        // The device's task is in a run of its own (runs keep to a Mac).
        let deviceTaskID = try #require(spawned["device"]).id
        let sharedRun = try #require(record.runs.first)
        var deviceRun = sharedRun
        deviceRun.id = "run-device"
        deviceRun.device = device
        deviceRun.taskIDs = [deviceTaskID]
        deviceRun.events = sharedRun.events.filter { $0.taskID == deviceTaskID }
        record.runs[0].taskIDs.removeAll { $0 == deviceTaskID }
        record.runs.append(deviceRun)
        record.tasks = record.tasks.map { saved in
            var saved = saved
            if saved.id == deviceTaskID { saved.runID = "run-device" }
            return saved
        }
        // Tasks the relaunch cannot decide keep the state they were saved
        // in (the sampler may have seen a worker start before the save).
        let savedStates = Dictionary(uniqueKeysWithValues: record.tasks.map { ($0.id, $0.state) })
        func saved(_ name: String) throws -> AgentTaskState {
            let id = try #require(spawned[name]).id
            return try #require(savedStates[id])
        }
        #expect(try saved("running") == .working)
        #expect(try [AgentTaskState.queued, .working].contains(saved("device")))

        let after = try ControlAgentWaitHarness()
        defer { after.stop() }
        after.server.tasks.relinkGrace = 0
        after.server.tasks.sessionStatus = { binding, _, _ in
            switch binding.sessionID {
            case "s-gone": .gone(reason: "its session ended while Cherry was closed", cancels: false)
            case "s-ended": .gone(reason: "its session was ended in Cherry before it reported", cancels: true)
            case "s-exited": .exited(3)
            case "s-running": .running
            case "s-device": .unknown(waitsForDevice: true)
            default: .unknown(waitsForDevice: false)
            }
        }
        after.server.start()
        after.relaunch(from: store, record: record)
        // The tab whose session the system ended comes back ended.
        let systemEnded = try #require(spawned["systemEnded"])
        let endedRecord = WorkspaceSessionRecord(
            id: systemEnded.worker, kind: .agent, title: "systemEnded", agentName: "Worker", workingDirectory: after.projectRoot.path
        )
        let endedTab = after.workspace.makeSystemEndedSession(record: endedRecord, ended: .restart)
        after.workspace.restoreSessions([endedTab], from: WorktreeStateRecord(root: after.projectRoot.path, sessions: [endedRecord]))
        await after.server.sampleTasks()

        func state(_ name: String) throws -> (AgentTaskState, String?) {
            let id = try #require(spawned[name]).id
            let task = try #require(after.server.tasks.tasks[id])
            return (task.state, task.reason)
        }
        #expect(try state("gone") == (.failed, "its session ended while Cherry was closed"))
        #expect(try state("ended") == (.cancelled, "its session was ended in Cherry before it reported"))
        #expect(try state("exited") == (.failed, "it ended (exit 3) before it reported"))
        #expect(try state("native") == (.failed, "its tab ran no persistent session, so its program ended when Cherry quit"))
        #expect(try state("systemEnded") == (.failed, "its session ended when the Mac restarted"))
        #expect(try state("running").0 == saved("running"), "a session that runs on keeps its task waiting")
        #expect(try state("device").0 == saved("device"), "another Mac's task waits for it to be reachable")
        #expect(try state("settled") == (.reported, nil))
        let settled = try await after.taskDetail(try #require(spawned["settled"]).id)
        #expect(settled.result?.summary == "Done before")

        // The orchestrator reads the failures as events.
        after.server.callerSessionResolverForTesting = { _ in nil }
        let events = try await after.waitTasks(.init(runID: sharedRun.id, timeoutMilliseconds: 0))
        #expect(events.events.contains { $0.taskID == spawned["gone"]?.id && $0.kind == .failed })
        // A device's task keeps to its Mac: This Mac's callers never see it.
        #expect(try await after.send(.getTask(.init(taskID: deviceTaskID))).error?.code == "unknown_task")
        #expect(try after.server.tasks.task(deviceTaskID, device: device)?.state == saved("device"))

        // This Mac's host that cannot be asked is waited for, at most so long.
        after.server.tasks.restoreDecisionTimeout = 0
        after.server.tasks.sessionStatus = { binding, _, _ in
            .unknown(waitsForDevice: binding.host != HostedSessionHost.local.id)
        }
        await after.server.sampleTasks()
        #expect(try state("running") == (.failed, "Cherry could not find its session after it relaunched"))
        #expect(try state("device").0 == saved("device"))
    }

    /// A restored task whose kickoff was never typed gets it once its
    /// worker sits idle at its composer; one already kicked off is never
    /// kicked off again, and is not nudged right away: its idle grace
    /// starts over when its tab comes back.
    @Test func restoredKickoffsAndNudgesWaitTheirTurn() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let before = try ControlAgentWaitHarness()
        before.server.tasks.store = store
        before.server.start()
        let lead = try await before.spawnAgent(named: "Lead")
        before.server.callerSessionResolverForTesting = { _ in lead }
        let (fresh, freshTask) = try await before.spawnWorker(task: "Never kicked off", label: "fresh")
        let (started, startedTask) = try await before.spawnWorker(task: "Kicked off", label: "started")
        before.server.tasks.saveNow()
        let freshID = fresh.id, startedID = started.id
        before.stop()

        var record = try #require(store.load())
        let then = Date().addingTimeInterval(-60)
        record.tasks = record.tasks.map { saved in
            var saved = saved
            if saved.id == freshTask.taskID {
                // Cherry quit before it typed the kickoff.
                saved.kickoffAttempts = 0
                saved.kickoffTypedAt = nil
                saved.kickoffDeliveredAt = nil
                saved.lastKickoffAttemptAt = nil
                saved.fetchedAt = nil
            } else {
                saved.kickoffDeliveredAt = then
                saved.fetchedAt = then
                saved.state = .working
            }
            return saved
        }
        let after = try ControlAgentWaitHarness()
        defer { after.stop() }
        after.useFastRestoredSampling(grace: 1)
        after.server.tasks.idleFallbackInterval = 3
        after.server.start()
        after.relaunch(from: store, record: record)
        let script = try after.fakeAgentScript(thinking: 0.1, working: 0.3)
        let freshBack = try after.restoreTab(id: freshID, name: "Fakeworker", command: script)
        let startedBack = try after.restoreTab(id: startedID, name: "Fakeworker", command: script)
        let restoredAt = Date()

        var freshOutput = ""
        for _ in 0..<100 {
            freshOutput = try await after.outputText(of: freshBack)
            if freshOutput.contains("handled You are Cherry task \(freshTask.taskID)") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(freshOutput.contains("handled You are Cherry task \(freshTask.taskID)"), "\(freshOutput)")
        after.server.callerSessionResolverForTesting = { _ in freshBack }
        #expect(try await after.send(.getMyTask).error == nil)

        // Not nudged within its grace (its turn counts start over).
        try await Task.sleep(for: .seconds(max(0, 2 - Date().timeIntervalSince(restoredAt))))
        let early = try await after.outputText(of: startedBack)
        #expect(!early.contains(AgentTaskRegistry.nudgeLine), "nudged right after the relaunch: \(early)")
        // Then asked once to report, as any idle worker; never kicked off.
        var later = early
        for _ in 0..<100 where !later.contains("handled \(AgentTaskRegistry.nudgeLine)") {
            try await Task.sleep(for: .milliseconds(100))
            later = try await after.outputText(of: startedBack)
        }
        #expect(later.contains("handled \(AgentTaskRegistry.nudgeLine)"), "\(later)")
        #expect(!later.contains("You are Cherry task"), "kicked off again: \(later)")
        #expect(try await after.outputText(of: freshBack).components(separatedBy: "handled You are Cherry task").count - 1 == 1)
        _ = startedTask
    }

    /// Settled runs are forgotten a day after they settled (also when read
    /// back), or once none of their tabs has been open or running for a
    /// while; open runs never are.
    @Test func settledRunsArePruned() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let leadA = try await harness.spawnAgent(named: "LeadA")
        let leadB = try await harness.spawnAgent(named: "LeadB")
        harness.server.callerSessionResolverForTesting = { _ in leadA }
        let (worker, settledTask) = try await harness.spawnWorker(task: "Done soon", label: "done")
        harness.server.callerSessionResolverForTesting = { _ in leadB }
        let (_, openTask) = try await harness.spawnWorker(task: "Still open", label: "open")
        harness.server.callerSessionResolverForTesting = { _ in worker }
        #expect(try await harness.send(.reportResult(.init(value: .null, summary: "ok"))).error == nil)
        let tasks = harness.server.tasks
        #expect(tasks.runs[settledTask.runID] != nil)

        // Its tabs are open: kept; a day after it settled: forgotten.
        harness.server.pruneSettledRuns()
        #expect(tasks.runs[settledTask.runID] != nil)
        let saved = tasks.fileRecord()
        harness.server.pruneSettledRuns(now: Date().addingTimeInterval(25 * 60 * 60))
        #expect(tasks.runs[settledTask.runID] == nil && tasks.tasks[settledTask.taskID] == nil)
        #expect(tasks.runs[openTask.runID] != nil, "an open run is never forgotten")
        #expect(tasks.board.badges[worker.id] == nil)

        // Read back a day later: left out.
        let later = AgentTaskRegistry(board: AgentTaskBoard())
        later.restore(from: saved, now: Date().addingTimeInterval(25 * 60 * 60))
        #expect(later.runs[settledTask.runID] == nil && later.runs[openTask.runID] != nil)

        // Once its tabs are gone (closed, no session running) for a while.
        harness.server.callerSessionResolverForTesting = { _ in leadA }
        let (other, goneTask) = try await harness.spawnWorker(task: "Gone soon", label: "gone")
        harness.server.callerSessionResolverForTesting = { _ in other }
        #expect(try await harness.send(.reportResult(.init(value: .null, summary: "ok"))).error == nil)
        for tab in [other, leadA] {
            #expect(try await harness.send(.closeProcess(.init(processID: tab.id.uuidString))).error == nil)
        }
        harness.server.pruneSettledRuns()
        #expect(tasks.runs[goneTask.runID] != nil && tasks.runs[goneTask.runID]?.tabsGoneSince != nil)
        harness.server.pruneSettledRuns(now: Date().addingTimeInterval(tasks.goneRunLifetime + 1))
        #expect(tasks.runs[goneTask.runID] == nil)
        #expect(tasks.runs[openTask.runID] != nil)
    }

    /// The file is this user's alone (0600, out of backups); one that is
    /// not (readable by others, or a link) is never read, and a save
    /// replaces a link without touching what it points to. A file of
    /// another version is moved aside, never written over.
    @Test func theFileIsPrivateAndNeverReadThroughALink() throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentTaskStore(directory: directory)
        let record = AgentTasksFileRecord(savedAt: Date(), nextSeq: 7, runs: [], tasks: [])
        store.saveSynchronously(record)
        let path = store.fileURL.path
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(store.load() == record)

        chmod(path, 0o644)
        #expect(store.load() == nil, "read a file others can read")
        chmod(path, 0o600)
        #expect(store.load() == record)

        // A link to a file that would read fine: never followed.
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        #expect(rename(path, elsewhere.path) == 0)
        #expect(symlink(elsewhere.path, path) == 0)
        #expect(store.load() == nil, "read through a link")
        let target = try Data(contentsOf: elsewhere)
        let next = AgentTasksFileRecord(savedAt: Date(), nextSeq: 9, runs: [], tasks: [])
        store.saveSynchronously(next)
        #expect(lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG, "the save replaced the link")
        #expect(try Data(contentsOf: elsewhere) == target, "what the link pointed to is untouched")
        #expect(store.load() == next)

        // Another version: moved aside.
        try Data(#"{"version":99,"future":true}"#.utf8).write(to: store.fileURL)
        chmod(path, 0o600)
        #expect(store.load() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("agent-tasks.json.v99-") && $0.hasSuffix(".bak") }, "\(names)")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Only the copy of the app that holds the instance lock reads or
    /// writes the file: a second copy (another holds the lock) neither
    /// reads the holder's file nor writes over it, however its tasks
    /// change; before the lock answered, nothing is read or written.
    @Test func aSecondCopyNeverReadsOrWritesTheFile() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let workspaces = directory.appendingPathComponent("Workspaces", isDirectory: true)
        let holderLock = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
        defer { holderLock.release() }
        #expect(holderLock.isHeld)
        let holder = AgentTaskStore(directory: workspaces, instanceLock: holderLock)
        let record = AgentTasksFileRecord(savedAt: Date(), nextSeq: 42, runs: [], tasks: [])
        holder.saveSynchronously(record)
        #expect(holder.load() == record)
        let before = try Data(contentsOf: holder.fileURL)

        let secondLock = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests", quittingHolderWait: 0)
        let second = AgentTaskStore(directory: workspaces, instanceLock: secondLock)
        #expect(!second.isEnabled, "the lock has not answered yet")
        #expect(second.load() == nil)
        let loaded = await Task.detached { second.loadResolvingLock() }.value
        #expect(loaded == nil)
        #expect(!secondLock.isHeld && !second.isEnabled)

        // The second copy's tasks change and save: nothing is written.
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.tasks.store = second
        harness.server.restoreTasks(from: loaded)
        harness.server.start()
        let lead = try await harness.spawnAgent(named: "Lead")
        harness.server.callerSessionResolverForTesting = { _ in lead }
        _ = try await harness.spawnWorker(task: "Second copy", label: "second")
        harness.server.tasks.saveNow()
        second.save(harness.server.tasks.fileRecord())
        second.flush()
        #expect(try Data(contentsOf: holder.fileURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspaces.path).filter { $0.hasPrefix(".agent-tasks") }.isEmpty)
    }

    /// The app's lookup never asks a host it is not connected to: a
    /// session whose host is unknown, or whose control has not listed, is
    /// waited for (another Mac's until it is reachable).
    @Test func theAppsLookupWaitsForHostsItCannotAsk() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stateStore = WorkspaceStateStore(directory: directory)
        let local = AgentTaskSessionBinding(host: HostedSessionHost.local.id, hostID: "h", sessionID: "s")
        let device = AgentTaskSessionBinding(host: "ssh:studio", hostID: "h", sessionID: "s")
        #expect(AgentTaskHostLookup.status(of: local, hosting: nil, savedAt: nil, stateStore: stateStore) == .unknown(waitsForDevice: false))
        #expect(AgentTaskHostLookup.status(of: device, hosting: nil, savedAt: nil, stateStore: stateStore) == .unknown(waitsForDevice: true))
        let control = HostControl(host: .local, clientProvider: { throw HostedSessionError.unavailable("test") })
        let hosting = PersistentHostSessions(
            control: { control }, installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
        )
        #expect(AgentTaskHostLookup.status(of: local, hosting: hosting, savedAt: nil, stateStore: stateStore) == .unknown(waitsForDevice: false))
        #expect(control.state == .idle, "looked without connecting")
    }
}
