import CherryControl
@testable import CherryMCP
import Darwin
import Foundation
import MCP
import Testing
@testable import Cherry

// Tasks and results (docs/mcp.md): spawn_agent with a task, the worker's
// get_my_task and report_result (its own tab, never a selector), the
// orchestrator's wait_for_tasks, the nudge and no_report fallback, and the
// run's wake line. Agents are `/bin/cat` (screens injected) or fake agent
// scripts; the end-to-end test drives the real CherryMCP `--call`.

@MainActor
private extension ControlAgentWaitHarness {
    /// Shorter sampler and idle intervals.
    func useFastTaskSampling() {
        let monitors = server.monitors
        monitors.sampleInterval = .milliseconds(50)
        monitors.settleInterval = 0.3
        monitors.wakeQuietInterval = 0.3
        monitors.wakeMinimumInterval = 0
        monitors.humanTypingInterval = 0
        monitors.refreshInterval = 0
        server.tasks.idleFallbackInterval = 30
        server.tasks.progressInterval = 0.5
    }

    func spawnTask(
        agent name: String,
        command: String = "/bin/cat",
        task brief: String,
        label: String? = nil,
        phase: String? = nil,
        runID: String? = nil,
        resultSchema: JSONValue? = nil,
        parentAgentID: String? = nil
    ) async throws -> (session: TerminalSession, result: SpawnProcessResult) {
        try settings.upsertAgent(AgentToolDefinition(name: name, command: command))
        let response = try await send(.spawnProcess(.init(
            kind: "agent",
            name: name,
            parentAgentID: parentAgentID,
            task: brief,
            label: label,
            phase: phase,
            runID: runID,
            resultSchema: resultSchema
        )))
        guard case .spawnProcess(let spawned)? = response.result else {
            throw CherryControlError(code: "spawn_failed", message: "Expected spawnProcess result, got \(String(describing: response))")
        }
        return (try #require(workspace.session(id: spawned.process.id)), spawned)
    }

    func output(of session: TerminalSession) async throws -> String {
        let response = try await send(.getProcessOutput(.init(processID: session.id.uuidString, lineLimit: 200)))
        guard case .getProcessOutput(let output)? = response.result else { return "" }
        return output.lines.joined(separator: "\n")
    }

    func task(_ id: String) async throws -> AgentTaskDetail {
        let response = try await send(.getTask(.init(taskID: id)))
        guard case .getTask(let detail)? = response.result else {
            throw CherryControlError(code: "get_task_failed", message: "\(String(describing: response))")
        }
        return detail
    }

    func waitForTasks(_ request: WaitForTasksRequest) async throws -> WaitForTasksResult {
        let response = try await send(.waitForTasks(request))
        guard case .waitForTasks(let result)? = response.result else {
            throw CherryControlError(code: "wait_failed", message: "\(String(describing: response))")
        }
        return result
    }

    func status(of session: TerminalSession) async throws -> ProcessSummary {
        let response = try await send(.getProcessStatus(.init(processID: session.id.uuidString)))
        guard case .getProcessStatus(let status)? = response.result else {
            throw CherryControlError(code: "status_failed", message: "\(String(describing: response))")
        }
        return status.process
    }

    /// Waits until `text` is in `session`'s output.
    func waitForOutput(_ text: String, in session: TerminalSession, seconds: Double = 10) async throws -> String {
        var output = ""
        for _ in 0..<Int(seconds * 10) {
            output = try await self.output(of: session)
            if output.contains(text) { return output }
            try await Task.sleep(for: .milliseconds(100))
        }
        return output
    }
}

private let findingsSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "severity": .object(["enum": .array([.string("low"), .string("high")])]),
        "files": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        "count": .object(["type": .string("integer")]),
    ]),
    "required": .array([.string("severity"), .string("files")]),
    "additionalProperties": .bool(false),
])

private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
}

// MARK: - Schemas

@Test func ControlAgentTaskSchemaSubsetValidatesAndListsEachProblem() throws {
    #expect(TaskResultSchema.lint(findingsSchema).isEmpty)
    #expect(TaskResultSchema.validate(try json(#"{"severity":"low","files":["a.swift"],"count":2.0}"#), against: findingsSchema).isEmpty)

    let problems = TaskResultSchema.validate(
        try json(#"{"severity":"medium","files":["a.swift",3],"count":2.5,"extra":true}"#),
        against: findingsSchema
    )
    #expect(problems.contains { $0.hasPrefix("$.severity: expected one of [\"low\", \"high\"]") }, "\(problems)")
    #expect(problems.contains("$.files[1]: expected string, got integer"), "\(problems)")
    #expect(problems.contains("$.count: expected integer, got number"), "\(problems)")
    #expect(problems.contains("$: property extra is not allowed"), "\(problems)")
    #expect(TaskResultSchema.validate(try json(#"{"files":[]}"#), against: findingsSchema) == ["$: missing required property severity"])
    #expect(TaskResultSchema.validate(.string("x"), against: findingsSchema) == ["$: expected object, got string"])
    // A type list, and a key that is not a plain name.
    let either = try json(#"{"type":["string","null"]}"#)
    #expect(TaskResultSchema.validate(.null, against: either).isEmpty)
    #expect(TaskResultSchema.validate(.int(1), against: either) == ["$: expected string or null, got integer"])
    let odd = try json(#"{"type":"object","properties":{"a b":{"type":"string"}}}"#)
    #expect(TaskResultSchema.validate(try json(#"{"a b":1}"#), against: odd) == [#"$["a b"]: expected string, got integer"#])

    // What Cherry cannot check is refused when the task is made.
    #expect(TaskResultSchema.lint(try json(#"{"type":"object","oneOf":[{}]}"#)).first?.contains("oneOf is not supported") == true)
    #expect(TaskResultSchema.lint(try json(#"{"type":"strng"}"#)) == ["$.type: unknown type strng"])
    #expect(TaskResultSchema.lint(try json(#"{"type":"array","items":[{"type":"string"}]}"#)).first?.contains("a list of schemas is not supported") == true)
    #expect(TaskResultSchema.lint(try json(#"{"enum":[]}"#)) == ["$.enum: a non-empty list of values"])
    #expect(TaskResultSchema.lint(try json(##"{"properties":{"x":{"$ref":"#/y"}}}"##)).first?.hasPrefix("$.properties.x: $ref is not supported") == true)
    #expect(TaskResultSchema.lint(.string("object")).first?.contains("a schema is an object") == true)
    #expect(TaskResultSchema.lint(try json(#"{"description":"ignored","title":"t","type":"object"}"#)).isEmpty)
}

/// A result's own keys stay as written in MCP's snake_case output, and MCP
/// arguments become JSON whatever their type; a schema sent as JSON text
/// is parsed.
@Test func ControlAgentTaskJSONValuesKeepTheirKeysThroughMCP() throws {
    let detail = AgentTaskResult(
        value: try json(#"{"fileName":"a","nested":{"camelCase":[1,2.5,null]}}"#),
        status: "ok", summary: nil, version: 1, reportedAt: Date(timeIntervalSince1970: 0), source: "report_result"
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(detail), as: UTF8.self)
    #expect(text.contains(#""value":{"fileName":"a","nested":{"camelCase":[1,2.5,null]}}"#), "\(text)")
    #expect(text.contains(#""reported_at""#))

    let arguments: [String: Value] = [
        "value": .object(["count": .int(2), "ok": .bool(true), "items": .array([.string("x")])]),
        "result_schema": .string(#"{"type":"object"}"#),
    ]
    #expect(try CherryMCPTools.jsonArgument("value", in: arguments) == json(#"{"count":2,"ok":true,"items":["x"]}"#))
    #expect(try CherryMCPTools.schemaArgument("result_schema", in: arguments) == json(#"{"type":"object"}"#))
    #expect(throws: CherryControlError.self) { try CherryMCPTools.schemaArgument("bad", in: ["bad": .string("not json")]) }
}

@Test func ControlAgentTaskToolsAreAdvertisedAndWaitsFitASixtySecondTimeout() async throws {
    let advertised = Set(CherryMCPTools.all.map(\.name))
    #expect(advertised.isSuperset(of: ["get_my_task", "report_result", "report_progress", "wait_for_tasks", "get_task", "list_tasks", "cancel_tasks"]))
    let wait = try #require(CherryMCPTools.clientTimeout(for: "wait_for_tasks", arguments: [:]))
    #expect(wait <= 55)
    #expect(CherryMCPTools.clientTimeout(for: "wait_for_tasks", arguments: ["timeout_ms": .int(300_000)]) == wait)
    // task and message together are refused before anything is sent.
    let both = await CherryMCPTools.call(name: "spawn_agent", arguments: [
        "name": .string("Claude"), "task": .string("Review"), "message": .string("hi"),
    ])
    #expect(both.isError == true)
    let spawnAgent = try #require(CherryMCPTools.all.first { $0.name == "spawn_agent" })
    let properties = spawnAgent.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
    #expect(Set(properties.keys).isSuperset(of: ["task", "label", "phase", "run_id", "result_schema"]))
}

// MARK: - Spawning

@MainActor
@Suite(.serialized)
struct ControlAgentTaskTests {
    /// spawn_agent with a task: a nested agent tab named after its label,
    /// a task record in the orchestrator's run, the kickoff typed into it,
    /// and the task fields on its process summary.
    @Test func spawnWithATaskTypesTheKickoffAndRecordsTheTask() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let orchestrator = try await harness.spawnAgent(named: "Lead")
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }

        let (worker, spawned) = try await harness.spawnTask(
            agent: "Worker", task: "Review the parser.\nList each finding.", label: "Parser review", phase: "review",
            resultSchema: findingsSchema, parentAgentID: orchestrator.id.uuidString
        )
        let task = try #require(spawned.task)
        #expect(task.taskID.hasPrefix("task-") && task.runID.hasPrefix("run-"))
        #expect(task.label == "Parser review" && task.phase == "review")
        #expect(spawned.sentBytes > 0)
        #expect(worker.parentAgentID == orchestrator.id)
        #expect(worker.title == "Parser review")
        let kickoff = try await harness.waitForOutput("You are Cherry task \(task.taskID): call get_my_task", in: worker)
        #expect(kickoff.contains("You are Cherry task \(task.taskID): call get_my_task (Cherry MCP) for your brief, do it, then call report_result."))
        #expect(kickoff.contains("\"$CHERRY_MCP_HELPER\" --call get_my_task"))
        #expect(!kickoff.contains("Review the parser"), "the brief is read with get_my_task, never typed")

        let summary = try await harness.status(of: worker)
        #expect(summary.taskID == task.taskID)
        #expect(summary.runID == task.runID)
        #expect(summary.taskState == "working" || summary.taskState == "queued")
        #expect(summary.phase == "review" && summary.label == "Parser review")
        #expect(summary.resultSummary == nil)
        #expect(try await harness.status(of: orchestrator).taskID == nil)

        // The next spawn joins the same run; the run's owner is the caller.
        let (_, second) = try await harness.spawnTask(agent: "Worker", task: "Check the lexer", parentAgentID: orchestrator.id.uuidString)
        #expect(second.task?.runID == task.runID)
        #expect(second.task?.label == "Check the lexer")
        let listed = try await harness.send(.listTasks(.init(runID: task.runID)))
        guard case .listTasks(let list)? = listed.result else {
            Issue.record("Expected listTasks, got \(listed)")
            return
        }
        #expect(list.tasks.map(\.taskID).contains(task.taskID) && list.tasks.count == 2)
        #expect(list.runs.first?.ownerProcessID == orchestrator.id.uuidString)
        #expect(list.runs.first?.counts.total == 2)
        // The sidebar's board: each worker's state, the owner's progress.
        #expect(harness.server.tasks.board.badges[worker.id]?.label == "Parser review")
        #expect(harness.server.tasks.board.runProgress[orchestrator.id] == AgentRunProgress(settled: 0, total: 2))
    }

    /// What a task spawn cannot be: a message too, a schema Cherry cannot
    /// check (nothing is spawned), task fields without a task, or a
    /// worker handing out tasks of its own.
    @Test func invalidTaskSpawnsAreRefusedBeforeAnythingIsSpawned() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))
        let before = harness.workspace.sessions.count

        let both = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", text: "hi", task: "Review")))
        #expect(both.error?.code == "invalid_process_request")
        let badSchema = try await harness.send(.spawnProcess(.init(
            kind: "agent", name: "Worker", task: "Review", resultSchema: try json(#"{"type":"object","anyOf":[]}"#)
        )))
        #expect(badSchema.error?.code == "invalid_result_schema")
        #expect(badSchema.error?.details?.first?.contains("anyOf is not supported") == true)
        let noTask = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", label: "x")))
        #expect(noTask.error?.code == "invalid_process_request")
        let terminal = try await harness.send(.spawnProcess(.init(kind: "terminal", task: "Review")))
        #expect(terminal.error?.code == "invalid_process_request")
        let unknownRun = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", task: "Review", runID: "run-nope")))
        #expect(unknownRun.error?.code == "unknown_run")
        #expect(harness.workspace.sessions.count == before)

        // Depth 1: a worker cannot hand out tasks.
        let (worker, _) = try await harness.spawnTask(agent: "Worker", task: "Review")
        harness.server.callerSessionResolverForTesting = { _ in worker }
        let nested = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", task: "Sub-review")))
        #expect(nested.error?.code == "nested_task")
    }

    // MARK: Identity

    /// get_my_task and report_result answer for the caller's own tab only:
    /// another worker's task is untouched, a tab without a task and an
    /// unidentified caller have no assignment, and a cancelled task says
    /// so. A schema mismatch lists each problem and records nothing; a
    /// later report bumps the version.
    @Test func workersReadAndReportOnlyTheirOwnTask() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let orchestrator = try await harness.spawnAgent(named: "Lead")
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let (workerA, spawnedA) = try await harness.spawnTask(agent: "Worker", task: "Brief A", label: "A", resultSchema: findingsSchema)
        let (workerB, spawnedB) = try await harness.spawnTask(agent: "Worker", task: "Brief B", label: "B")
        let taskA = try #require(spawnedA.task?.taskID)
        let taskB = try #require(spawnedB.task?.taskID)

        harness.server.callerSessionResolverForTesting = { _ in workerA }
        let mine = try await harness.send(.getMyTask)
        guard case .getMyTask(let assignment)? = mine.result else {
            Issue.record("Expected getMyTask, got \(mine)")
            return
        }
        #expect(assignment.taskID == taskA && assignment.brief == "Brief A" && assignment.label == "A")
        #expect(assignment.resultSchema == findingsSchema)
        #expect(assignment.state == .working)
        #expect(assignment.rules.contains { $0.contains("report_result") })

        let mismatch = try await harness.send(.reportResult(.init(value: try json(#"{"severity":"medium","files":[1]}"#), summary: "x")))
        #expect(mismatch.error?.code == "schema_mismatch")
        #expect(mismatch.error?.details?.contains("$.files[0]: expected string, got integer") == true, "\(String(describing: mismatch.error))")
        #expect(try await harness.task(taskA).result == nil, "a mismatch records nothing")

        let long = String(repeating: "s", count: 450)
        let reported = try await harness.send(.reportResult(.init(value: try json(#"{"severity":"high","files":["p.swift"]}"#), status: "ok", summary: long)))
        guard case .reportResult(let first)? = reported.result else {
            Issue.record("Expected reportResult, got \(reported)")
            return
        }
        #expect(first.taskID == taskA && first.version == 1 && first.state == .reported && first.summaryTruncated)
        // Re-reports are rate-limited: nothing is recorded too soon after one.
        let tooSoonReport = try await harness.send(.reportResult(.init(value: try json(#"{"severity":"low","files":[]}"#))))
        #expect(tooSoonReport.error?.code == "rate_limited")
        #expect(try await harness.task(taskA).result?.version == 1)
        harness.server.tasks.reportInterval = 0
        let again = try await harness.send(.reportResult(.init(value: try json(#"{"severity":"low","files":[]}"#), summary: "Second look")))
        guard case .reportResult(let second)? = again.result else {
            Issue.record("Expected reportResult, got \(again)")
            return
        }
        #expect(second.version == 2)
        let detailA = try await harness.task(taskA)
        #expect(detailA.result?.value == (try json(#"{"severity":"low","files":[]}"#)))
        // JSON text that matches the schema is taken as the value (a client
        // that sends an untyped argument as a string).
        let asText = try await harness.send(.reportResult(.init(value: .string(#"{"severity":"high","files":["x"]}"#), summary: "Second look")))
        guard case .reportResult(let third)? = asText.result else {
            Issue.record("Expected reportResult, got \(asText)")
            return
        }
        #expect(third.version == 3)
        #expect(try await harness.task(taskA).result?.value == (try json(#"{"severity":"high","files":["x"]}"#)))
        #expect(detailA.result?.summary == "Second look" && detailA.result?.source == "report_result")
        #expect(try await harness.status(of: workerA).resultSummary == "Second look")
        #expect(try await harness.status(of: workerA).taskState == "reported")

        // B's task is untouched by A's reports.
        let detailB = try await harness.task(taskB)
        #expect(detailB.result == nil && !detailB.task.state.isSettled)

        // A tab without a task, and a caller Cherry cannot identify.
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        #expect(try await harness.send(.getMyTask).error?.code == "no_assignment")
        #expect(try await harness.send(.reportResult(.init(value: .null))).error?.code == "no_assignment")
        harness.server.callerSessionResolverForTesting = { _ in nil }
        #expect(try await harness.send(.reportResult(.init(value: .null))).error?.code == "no_assignment")

        // A failed report skips the schema; progress is kept, at most so often.
        harness.server.callerSessionResolverForTesting = { _ in workerB }
        harness.server.tasks.progressInterval = 60
        let progress = try await harness.send(.reportProgress(.init(message: "Half\nway")))
        guard case .reportProgress(let recorded)? = progress.result else {
            Issue.record("Expected reportProgress, got \(progress)")
            return
        }
        #expect(recorded.recorded)
        let tooSoon = try await harness.send(.reportProgress(.init(message: "More")))
        guard case .reportProgress(let dropped)? = tooSoon.result else { return }
        #expect(!dropped.recorded && (dropped.retryAfterMilliseconds ?? 0) > 0)
        #expect(try await harness.task(taskB).task.progress == "Half way")

        // Cancelled: the worker is told to stop.
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let cancelled = try await harness.send(.cancelTasks(.init(taskIDs: [taskB])))
        guard case .cancelTasks(let cancel)? = cancelled.result else {
            Issue.record("Expected cancelTasks, got \(cancelled)")
            return
        }
        #expect(cancel.cancelled == [taskB] && cancel.closed.isEmpty)
        harness.server.callerSessionResolverForTesting = { _ in workerB }
        #expect(try await harness.send(.reportResult(.init(value: .null, status: "failed"))).error?.code == "task_cancelled")
        #expect(try await harness.send(.getMyTask).error?.code == "task_cancelled")
        #expect(harness.workspace.sessions.contains { $0 === workerB }, "cancel without close keeps the tab")
    }

    // MARK: Waiting

    /// wait_for_tasks: a timeout is a normal answer with the pending tasks;
    /// a settle wakes `until: any` at once; the returned cursor reads each
    /// event once; `until: all` waits for every task.
    @Test func waitForTasksHonoursItsCursorAndTimeout() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let orchestrator = try await harness.spawnAgent(named: "Lead")
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let (workerA, spawnedA) = try await harness.spawnTask(agent: "Worker", task: "A")
        let (workerB, spawnedB) = try await harness.spawnTask(agent: "Worker", task: "B")
        let runID = try #require(spawnedA.task?.runID)
        let taskA = try #require(spawnedA.task?.taskID)
        let taskB = try #require(spawnedB.task?.taskID)

        let startedAt = Date()
        let idle = try await harness.waitForTasks(.init(runID: runID, timeoutMilliseconds: 400))
        #expect(idle.timedOut)
        #expect(Date().timeIntervalSince(startedAt) >= 0.35)
        #expect(Set(idle.pending.map(\.taskID)) == [taskA, taskB] && idle.completed.isEmpty)
        #expect(idle.events.filter { $0.kind == .queued }.count == 2)
        #expect(idle.runs.first?.runID == runID)
        let cursor = idle.cursor

        // The orchestrator's own runs are the default selection.
        let defaulted = try await harness.waitForTasks(.init(timeoutMilliseconds: 0))
        #expect(Set(defaulted.pending.map(\.taskID)) == [taskA, taskB])

        harness.server.callerSessionResolverForTesting = { _ in workerA }
        _ = try await harness.send(.reportResult(.init(value: .string("done A"), summary: "A done")))
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let quick = Date()
        let one = try await harness.waitForTasks(.init(runID: runID, cursor: cursor, timeoutMilliseconds: 5_000))
        #expect(!one.timedOut && Date().timeIntervalSince(quick) < 2)
        #expect(one.events.map(\.kind).contains(.reported))
        #expect(one.events.allSatisfy { $0.seq > cursor })
        #expect(one.events.first { $0.kind == .reported }?.text == "A done")
        #expect(one.completed.map(\.taskID) == [taskA] && one.pending.map(\.taskID) == [taskB])

        // Read once: the cursor moves past it.
        let nothing = try await harness.waitForTasks(.init(runID: runID, cursor: one.cursor, timeoutMilliseconds: 300))
        #expect(nothing.timedOut && nothing.events.isEmpty && nothing.cursor == one.cursor)

        // until all: returns once B settles too.
        async let all = harness.waitForTasks(.init(runID: runID, until: "all", cursor: one.cursor, timeoutMilliseconds: 10_000))
        try await Task.sleep(for: .milliseconds(300))
        harness.server.callerSessionResolverForTesting = { _ in workerB }
        _ = try await harness.send(.reportResult(.init(value: .null, status: "failed", summary: "B could not")))
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let everything = try await all
        #expect(!everything.timedOut && everything.pending.isEmpty)
        #expect(Set(everything.completed.map(\.state)) == [.reported, .failed])
        #expect(everything.runs.first?.settled == true)
        #expect(everything.runs.first?.counts.reported == 1 && everything.runs.first?.counts.failed == 1)

        let bad = try await harness.send(.waitForTasks(.init(runID: runID, until: "some")))
        #expect(bad.error?.code == "invalid_argument")
        #expect(try await harness.send(.waitForTasks(.init(runID: "run-nope"))).error?.code == "unknown_run")
        #expect(try await harness.send(.getTask(.init(taskID: "task-nope"))).error?.code == "unknown_task")
    }

    // MARK: Fallback

    /// A worker that read its task and finishes its turn without
    /// report_result is asked once; idle again without a report, its task
    /// is no_report, with its screen's last lines as the result.
    @Test func idleWorkerIsNudgedOnceThenMarkedNoReport() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.1, working: 0.3)
        let (worker, spawned) = try await harness.spawnTask(agent: "Fakeworker", command: script, task: "Say hi")
        let taskID = try #require(spawned.task?.taskID)
        // It read its brief (only a worker that has its task is asked to
        // report).
        harness.server.callerSessionResolverForTesting = { _ in worker }
        #expect(try await harness.send(.getMyTask).error == nil)

        let nudged = try await harness.waitForOutput("handled \(AgentTaskRegistry.nudgeLine)", in: worker, seconds: 15)
        #expect(nudged.contains("handled You are Cherry task \(taskID)"), "the kickoff turn ran first: \(nudged)")
        #expect(nudged.components(separatedBy: "> \(AgentTaskRegistry.nudgeLine)").count - 1 == 1)

        var detail = try await harness.task(taskID)
        for _ in 0..<100 where detail.task.state != .noReport {
            try await Task.sleep(for: .milliseconds(100))
            detail = try await harness.task(taskID)
        }
        #expect(detail.task.state == .noReport)
        #expect(detail.task.nudged)
        #expect(detail.result?.source == "screen_tail" && detail.result?.status == "no_report")
        #expect(detail.result?.value?.stringValue?.contains("handled \(AgentTaskRegistry.nudgeLine)") == true)
        // Asked once only.
        try await Task.sleep(for: .milliseconds(600))
        let output = try await harness.output(of: worker)
        #expect(output.components(separatedBy: "> \(AgentTaskRegistry.nudgeLine)").count - 1 == 1)

        let events = try await harness.waitForTasks(.init(taskIDs: [taskID], timeoutMilliseconds: 0))
        #expect(events.events.map(\.kind).contains(.nudged))
        #expect(!events.events.map(\.kind).contains(.kickoffRetry))
        #expect(events.events.last?.kind == .noReport)
        // A report after all replaces the fallback.
        let late = try await harness.send(.reportResult(.init(value: .string("hi"), summary: "Said hi")))
        guard case .reportResult(let result)? = late.result else {
            Issue.record("Expected reportResult, got \(late)")
            return
        }
        #expect(result.state == .reported && result.version == 1)
    }

    /// A worker whose tab closes before it reported is cancelled; one
    /// whose program ends is failed, with its last lines.
    @Test func closedAndExitedWorkersSettleTheirTasks() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let (closing, spawnedClosing) = try await harness.spawnTask(agent: "Worker", task: "Close me")
        let script = harness.projectRoot.appendingPathComponent("exits.sh")
        try "#!/bin/sh\necho 'last words'\nsleep 0.5\nexit 4\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let (_, spawnedExiting) = try await harness.spawnTask(agent: "Exiter", command: script.path, task: "Exit")

        #expect(try await harness.send(.closeProcess(.init(processID: closing.id.uuidString))).error == nil)
        let ids = [try #require(spawnedClosing.task?.taskID), try #require(spawnedExiting.task?.taskID)]
        let settled = try await harness.waitForTasks(.init(taskIDs: ids, until: "all", timeoutMilliseconds: 10_000))
        #expect(!settled.timedOut)
        let byID = Dictionary(uniqueKeysWithValues: settled.completed.map { ($0.taskID, $0) })
        #expect(byID[ids[0]]?.state == .cancelled)
        #expect(byID[ids[1]]?.state == .failed)
        #expect(byID[ids[1]]?.reason?.contains("exit 4") == true)
        #expect(try await harness.task(ids[1]).result?.value?.stringValue?.contains("last words") == true)
    }

    // MARK: Wake line

    /// Once every task of its run settled and the orchestrator is idle,
    /// Cherry types one line into its tab: the run id and counts only,
    /// never a worker's text, and only once.
    @Test func settledRunWakesItsIdleOrchestratorOnce() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.1, working: 0.3)
        let orchestrator = try await harness.spawnAgent(named: "Fakeagent", command: script)
        try await Task.sleep(for: .milliseconds(600))
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let (workerA, spawnedA) = try await harness.spawnTask(agent: "Worker", task: "A")
        let (workerB, _) = try await harness.spawnTask(agent: "Worker", task: "B")
        let runID = try #require(spawnedA.task?.runID)

        harness.server.callerSessionResolverForTesting = { _ in workerA }
        _ = try await harness.send(.reportResult(.init(value: .string("x"), summary: "SECRET-SUMMARY-A")))
        // One task open: no wake line yet.
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(!(try await harness.output(of: orchestrator)).contains("[cherry] Run"))

        harness.server.callerSessionResolverForTesting = { _ in workerB }
        _ = try await harness.send(.reportResult(.init(value: .null, status: "failed", summary: "SECRET-SUMMARY-B")))
        let woken = try await harness.waitForOutput("handled [cherry] Run \(runID)", in: orchestrator, seconds: 10)
        #expect(woken.contains("[cherry] Run \(runID): 2 tasks settled (1 reported, 1 failed). Call the cherry wait_for_tasks tool with run_id \"\(runID)\" to read them, and get_task for each result."), "\(woken)")
        #expect(!woken.contains("SECRET-SUMMARY"), "the wake line carries no worker text")
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(try await harness.output(of: orchestrator).components(separatedBy: "handled [cherry] Run").count - 1 == 1)
        #expect(harness.server.tasks.board.runProgress[orchestrator.id] == nil, "a settled run shows no progress")
    }

    // MARK: End to end

    /// A fake orchestrator spawns two fake workers through the real
    /// CherryMCP; each reads its brief and reports with `CherryMCP --call`,
    /// identified by its tab's process tree alone; the settled run wakes
    /// the orchestrator, and the results are there to read.
    @Test func fakeOrchestratorRunsTwoWorkersThroughCherryMCP() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = repository.appendingPathComponent(".build/debug/CherryMCP")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "Build CherryMCP first: swift build --build-tests")
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let call = "CHERRY_CONTROL_SOCKET='\(harness.socketURL.path)' '\(helper.path)' --call"

        let worker = harness.projectRoot.appendingPathComponent("fake-worker.sh")
        try """
        #!/bin/sh
        stty -echo 2>/dev/null
        printf '\\342\\235\\257 \\n'
        while IFS= read -r line; do
          case "$line" in
            *"You are Cherry task"*)
              printf '\\342\\234\\266 Working\\342\\200\\246 (esc to interrupt)'
              brief=$(\(call) get_my_task)
              case "$brief" in
                *alpha*) word=alpha ;;
                *) word=beta ;;
              esac
              \(call) report_result "{\\"value\\":{\\"word\\":\\"$word\\"},\\"status\\":\\"ok\\",\\"summary\\":\\"found $word\\"}" >/dev/null
              printf '\\r\\033[2K\\342\\217\\272 reported %s\\n\\n\\342\\235\\257 \\n' "$word"
              ;;
            *) printf '> %s\\n\\n\\342\\235\\257 \\n' "$line" ;;
          esac
        done
        """.write(to: worker, atomically: true, encoding: .utf8)
        chmod(worker.path, 0o755)
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Fakeworker", command: worker.path))

        let orchestratorScript = harness.projectRoot.appendingPathComponent("fake-orchestrator.sh")
        try """
        #!/bin/sh
        stty -echo 2>/dev/null
        printf '\\342\\235\\257 \\n'
        while IFS= read -r line; do
          printf '> %s\\n\\n' "$line"
          case "$line" in
            go)
              printf '\\342\\234\\266 Spawning\\342\\200\\246 (esc to interrupt)'
              \(call) spawn_agent '{"name":"Fakeworker","task":"Find alpha","label":"alpha"}' >/dev/null
              \(call) spawn_agent '{"name":"Fakeworker","task":"Find beta","label":"beta"}' >/dev/null
              printf '\\r\\033[2K\\342\\217\\272 spawned\\n\\n\\342\\235\\257 \\n'
              ;;
            *) printf '\\342\\217\\272 handled %s\\n\\n\\342\\235\\257 \\n' "$line" ;;
          esac
        done
        """.write(to: orchestratorScript, atomically: true, encoding: .utf8)
        chmod(orchestratorScript.path, 0o755)
        let orchestrator = try await harness.spawnAgent(named: "Fakelead", command: orchestratorScript.path)
        try await Task.sleep(for: .milliseconds(600))

        _ = try await harness.send(.sendProcessInput(.init(processID: orchestrator.id.uuidString, text: "go", submit: true)))
        let woken = try await harness.waitForOutput("handled [cherry] Run", in: orchestrator, seconds: 40)
        #expect(woken.contains("2 tasks settled (2 reported)"), "\(woken)")

        let listed = try await harness.send(.listTasks(.init()))
        guard case .listTasks(let list)? = listed.result else {
            Issue.record("Expected listTasks, got \(listed)")
            return
        }
        #expect(list.tasks.count == 2)
        #expect(list.runs.first?.ownerProcessID == orchestrator.id.uuidString)
        let workers = harness.workspace.childAgentSessions(of: orchestrator)
        #expect(workers.count == 2, "the workers are nested under the orchestrator")
        var words: [String] = []
        for info in list.tasks {
            #expect(info.state == .reported)
            let detail = try await harness.task(info.taskID)
            if case .object(let value)? = detail.result?.value, let word = value["word"]?.stringValue {
                words.append(word)
                #expect(detail.result?.summary == "found \(word)")
                #expect(info.label == word)
            }
        }
        #expect(words.sorted() == ["alpha", "beta"])
    }
}

// MARK: - Limits, typing and fallbacks

/// A schema's enum is capped when the task is made, and checking a value
/// is linear (enum values are looked up) and bounded by a work budget.
@Test func ControlAgentTaskSchemaEnumsAreCappedAndChecksStayLinear() throws {
    let tooMany = JSONValue.object(["enum": .array((0..<300).map { .string("v\($0)") })])
    #expect(TaskResultSchema.lint(tooMany) == ["$.enum: at most 256 values (it has 300)"])

    let options = (0..<256).map { JSONValue.string("option-\($0)") }
    let schema = JSONValue.object(["type": .string("array"), "items": .object(["enum": .array(options)])])
    #expect(TaskResultSchema.lint(schema).isEmpty)
    let value = JSONValue.array(Array(repeating: .string("option-255"), count: 20_000))
    let startedAt = Date()
    #expect(TaskResultSchema.validate(value, against: schema).isEmpty)
    #expect(Date().timeIntervalSince(startedAt) < 1.5, "checking 20,000 values against a 256-value enum took \(Date().timeIntervalSince(startedAt)) s")
    // Numbers compare by value in an enum, objects by content.
    let numbers = try json(#"{"enum":[1,{"a":[2,"x"]}]}"#)
    #expect(TaskResultSchema.validate(.double(1.0), against: numbers).isEmpty)
    #expect(TaskResultSchema.validate(try json(#"{"a":[2.0,"x"]}"#), against: numbers).isEmpty)
    #expect(TaskResultSchema.validate(.string("1"), against: numbers).count == 1)

    // Past its budget the check stops and says so.
    let budgeted = TaskResultSchema.validate(value, against: schema, budget: 100)
    #expect(budgeted.last?.contains("too large to check") == true, "\(budgeted)")
}

@MainActor
@Suite(.serialized)
struct ControlAgentTaskLimitTests {
    /// The size cap comes before the schema: an oversized value that also
    /// mismatches is result_too_large, checked without a long stall.
    @Test func oversizedReportIsRefusedBeforeItsSchemaIsChecked() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let options = (0..<256).map { JSONValue.string("option-\($0)") }
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "items": .object(["type": .string("array"), "items": .object(["enum": .array(options)])]),
        ])])
        let (worker, spawned) = try await harness.spawnTask(agent: "Worker", task: "Report big", resultSchema: schema)
        harness.server.callerSessionResolverForTesting = { _ in worker }
        let big = JSONValue.object(["items": .array(Array(repeating: .string("not-an-option-\(String(repeating: "x", count: 20))"), count: 12_000))])
        #expect(big.encodedByteCount > AgentTaskRegistry.maximumResultBytes)
        let startedAt = Date()
        let response = try await harness.send(.reportResult(.init(value: big)))
        #expect(response.error?.code == "result_too_large", "\(String(describing: response.error))")
        #expect(Date().timeIntervalSince(startedAt) < 3)
        #expect(try await harness.task(try #require(spawned.task?.taskID)).result == nil)
    }

    /// Caps count UTF-8 bytes as well as characters: a summary, progress
    /// message, label or phase of characters many bytes long is cut, and a
    /// brief over the byte cap is refused; events keep a short excerpt.
    @Test func textCapsCountBytes() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        // One character of 1 + 100 combining marks: 201 bytes.
        let heavy = "e" + String(repeating: "\u{0301}", count: 100)
        #expect(heavy.count == 1 && heavy.utf8.count == 201)
        let (worker, spawned) = try await harness.spawnTask(
            agent: "Worker", task: "Heavy", label: String(repeating: heavy, count: 70), phase: String(repeating: heavy, count: 50)
        )
        let task = try #require(spawned.task)
        #expect(task.label.utf8.count <= AgentTaskRegistry.labelLimit.bytes && task.label.hasSuffix("…"))
        #expect((task.phase?.utf8.count ?? 0) <= AgentTaskRegistry.phaseLimit.bytes)

        harness.server.callerSessionResolverForTesting = { _ in worker }
        let reported = try await harness.send(.reportResult(.init(value: .null, summary: String(repeating: heavy, count: 390))))
        guard case .reportResult(let result)? = reported.result else {
            Issue.record("Expected reportResult, got \(reported)")
            return
        }
        #expect(result.summaryTruncated)
        let detail = try await harness.task(task.taskID)
        #expect((detail.result?.summary?.utf8.count ?? .max) <= AgentTaskRegistry.summaryBytes)
        harness.server.tasks.progressInterval = 0
        _ = try await harness.send(.reportProgress(.init(message: String(repeating: heavy, count: 190))))
        #expect((try await harness.task(task.taskID).task.progress?.utf8.count ?? .max) <= AgentTaskRegistry.progressBytes)
        let events = try await harness.waitForTasks(.init(taskIDs: [task.taskID], timeoutMilliseconds: 0))
        #expect(events.events.allSatisfy { ($0.text?.utf8.count ?? 0) <= AgentTaskRegistry.eventTextLimit.bytes })

        // 30,000 characters of 11 bytes on average: under the character
        // cap, over the byte cap.
        let wide = String(repeating: "e" + String(repeating: "\u{0301}", count: 10) + " ", count: 15_000)
        #expect(wide.count <= AgentTaskRegistry.maximumBriefCharacters && wide.utf8.count > AgentTaskRegistry.maximumBriefBytes)
        let refused = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", task: wide)))
        #expect(refused.error?.code == "invalid_process_request")
    }

    /// Each run keeps its own events: one run's flood never pushes out
    /// another's; a task's re-reports and progress keep one event each;
    /// and `until: any` sees a task that settled after the cursor even when
    /// its event was dropped.
    @Test func eachRunKeepsItsOwnEventsAndASettleIsSeenAfterItsEventWent() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        harness.server.tasks.maxEventsPerRun = 4
        harness.server.tasks.reportInterval = 0
        let leadA = try await harness.spawnAgent(named: "LeadA")
        let leadB = try await harness.spawnAgent(named: "LeadB")
        harness.server.callerSessionResolverForTesting = { _ in leadA }
        let (workerX, spawnedX) = try await harness.spawnTask(agent: "Worker", task: "X")
        harness.server.callerSessionResolverForTesting = { _ in leadB }
        let (workerY, spawnedY) = try await harness.spawnTask(agent: "Worker", task: "Y")
        let runA = try #require(spawnedX.task?.runID)
        let runB = try #require(spawnedY.task?.runID)
        #expect(runA != runB)
        let cursorB = try await harness.waitForTasks(.init(runID: runB, timeoutMilliseconds: 0)).cursor

        harness.server.callerSessionResolverForTesting = { _ in workerY }
        for summary in ["first", "second", "third"] {
            _ = try await harness.send(.reportResult(.init(value: .null, summary: summary)))
        }
        // Run A floods its own events.
        harness.server.callerSessionResolverForTesting = { _ in leadA }
        for index in 0..<8 {
            _ = try await harness.spawnTask(agent: "Worker", task: "Flood \(index)", runID: runA)
        }
        let readB = try await harness.waitForTasks(.init(runID: runB, cursor: cursorB, timeoutMilliseconds: 0))
        #expect(!readB.eventsDropped)
        #expect(readB.events.filter { $0.kind == .reported }.map(\.text) == ["third"], "re-reports keep one event, the latest")
        #expect(readB.completed.first?.resultVersion == 3)

        // X settles, then run A's flood drops that event.
        let beforeSettle = try await harness.waitForTasks(.init(runID: runA, timeoutMilliseconds: 0)).cursor
        harness.server.callerSessionResolverForTesting = { _ in workerX }
        _ = try await harness.send(.reportResult(.init(value: .null, summary: "X done")))
        harness.server.callerSessionResolverForTesting = { _ in leadA }
        for index in 0..<6 {
            _ = try await harness.spawnTask(agent: "Worker", task: "More \(index)", runID: runA)
        }
        let startedAt = Date()
        let readA = try await harness.waitForTasks(.init(runID: runA, cursor: beforeSettle, timeoutMilliseconds: 5_000))
        #expect(!readA.timedOut && Date().timeIntervalSince(startedAt) < 2)
        #expect(readA.eventsDropped)
        #expect(!readA.events.contains { $0.taskID == spawnedX.task?.taskID && $0.kind == .reported })
        #expect(readA.completed.map(\.taskID) == [spawnedX.task?.taskID])
        // The returned cursor is past that settle: the next wait waits.
        let next = try await harness.waitForTasks(.init(runID: runA, cursor: readA.cursor, timeoutMilliseconds: 300))
        #expect(next.timedOut)
    }

    /// An orchestrator that cancels its own run knows it settled: no wake
    /// line for it.
    @Test func ownerCancellingItsOwnRunGetsNoWakeLine() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.1, working: 0.3)
        let orchestrator = try await harness.spawnAgent(named: "Fakeagent", command: script)
        try await Task.sleep(for: .milliseconds(600))
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let (workerA, spawned) = try await harness.spawnTask(agent: "Worker", task: "A")
        let (workerB, _) = try await harness.spawnTask(agent: "Worker", task: "B")
        let runID = try #require(spawned.task?.runID)

        let cancelled = try await harness.send(.cancelTasks(.init(runID: runID, close: true)))
        guard case .cancelTasks(let result)? = cancelled.result else {
            Issue.record("Expected cancelTasks, got \(cancelled)")
            return
        }
        #expect(result.cancelled.count == 2 && result.closed.count == 2)
        #expect(!harness.workspace.sessions.contains { $0 === workerA || $0 === workerB })
        try await Task.sleep(for: .milliseconds(2_000))
        #expect(!(try await harness.output(of: orchestrator)).contains("[cherry] Run"))
    }

    /// A worker that subscribed to a job of its own and ended its turn
    /// (as the MCP instructions recommend) waits for its wake line: it is
    /// neither nudged nor marked no_report while the job runs; once it no
    /// longer waits on anything, the nudge comes.
    @Test func workerWaitingOnItsOwnMonitorIsNotNudged() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastTaskSampling()
        harness.server.start()
        let job = try #require(harness.workspace.sessions.first, "the harness's terminal stands for a running job")
        let script = try harness.fakeAgentScript(thinking: 0.3, working: 0.4)
        let (worker, spawned) = try await harness.spawnTask(agent: "Fakeworker", command: script, task: "Wait for the job")
        let taskID = try #require(spawned.task?.taskID)
        harness.server.callerSessionResolverForTesting = { _ in worker }
        #expect(try await harness.send(.getMyTask).error == nil)
        let subscribed = try await harness.send(.subscribe(.init(processIDs: [job.id.uuidString])))
        guard case .subscribe(let subscription)? = subscribed.result else {
            Issue.record("Expected subscribe, got \(subscribed)")
            return
        }
        #expect(subscription.subscription.wake)
        _ = try await harness.waitForOutput("handled You are Cherry task \(taskID)", in: worker)
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(!(try await harness.output(of: worker)).contains(AgentTaskRegistry.nudgeLine), "nudged while it waits on its job")
        #expect(try await harness.task(taskID).task.state == .working)

        _ = try await harness.send(.unsubscribe(.init(subscriptionID: subscription.subscription.subscriptionID)))
        let nudged = try await harness.waitForOutput("handled \(AgentTaskRegistry.nudgeLine)", in: worker, seconds: 10)
        #expect(nudged.contains("handled \(AgentTaskRegistry.nudgeLine)"))
    }

    /// Two lines Cherry types into one tab at once (a wake line and a
    /// nudge, say) go one after the other, each with its own Enter: never
    /// mixed into one message.
    @Test func cherryLinesTypedAtOnceIntoOneTabNeverMix() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        // Named as an agent whose Enter Cherry sends after a pause.
        let script = try harness.fakeAgentScript(thinking: 0.05, working: 0.1)
        let agent = try await harness.spawnAgent(named: "Claude", command: script)
        try await Task.sleep(for: .milliseconds(800))
        async let first = harness.server.typeCherryLine("[cherry] LINE-ONE", into: agent)
        async let second = harness.server.typeCherryLine("[cherry] LINE-TWO", into: agent)
        _ = try await (first, second)
        let output = try await harness.waitForOutput("handled [cherry] LINE-TWO", in: agent)
        #expect(output.contains("handled [cherry] LINE-ONE"), "\(output)")
        #expect(!output.contains("LINE-ONE[cherry] LINE-TWO") && !output.contains("LINE-TWO[cherry] LINE-ONE"), "\(output)")
        #expect(!harness.server.tasks.typingLocks.isBusy(agent.id))
    }
}

// MARK: - The kickoff, checked

/// Where a kickoff stands on a worker's screen: on the composer's prompt
/// line it is unsent; one more copy than before it was typed, anywhere
/// else, was sent; otherwise it is not there.
@Test func ControlAgentTaskKickoffPlacementReadsTheComposer() {
    let id = "task-0123456789ab"
    let kickoff = AgentTaskRegistry.kickoffLine(taskID: id)
    let start = String(kickoff.prefix(60))
    func placement(_ lines: [String], agent: String = "claude", before: Int = 0) -> KickoffPlacement {
        AgentTaskRegistry.kickoffPlacement(taskID: id, in: lines, agent: agent, copiesBefore: before)
    }
    // Typed, its Enter lost: on the composer's prompt line, wrapped.
    #expect(placement(["Welcome back", "", "\u{276F} " + start, "  for your brief, do it", "", "? for shortcuts"]) == .composer)
    #expect(placement(["\u{256D}\u{2500}\u{256E}", "\u{2502} > " + start + " \u{2502}", "\u{2570}\u{2500}\u{256F}"]) == .composer)
    // Sent: among the messages, the composer below it.
    #expect(placement(["> " + start, "", "\u{2736} Reticulating\u{2026} (esc to interrupt)", "\u{276F} "]) == .submitted)
    // Dropped: not on screen at all.
    #expect(placement(["Welcome back", "", "\u{276F} "]) == .absent)
    // Typed again: an earlier copy alone is not this one.
    #expect(placement(["> " + start, "\u{23FA} I have no task.", "\u{276F} "], before: 1) == .absent)
    #expect(placement(["> " + start, "\u{23FA} ok", "> " + start, "\u{276F} "], before: 1) == .submitted)
    #expect(placement(["> " + start, "\u{23FA} ok", "\u{276F} " + start], before: 1) == .composer)
    // A screen with no composer at all (an echoing program): sent.
    #expect(placement([start, start], agent: "worker") == .submitted)
    #expect(AgentTaskRegistry.kickoffCopies(taskID: id, in: ["> " + start, "x", "\u{276F} " + start]) == 2)
}

@MainActor
private extension ControlAgentWaitHarness {
    /// Fast sampling, and short kickoff checks; a worker's turn that ends
    /// without its task read waits `wakeQuiet` before its kickoff comes
    /// again, so a test can read the task first.
    func useFastKickoffChecks(wakeQuiet: TimeInterval = 0.3, retryInterval: TimeInterval = 0.8) {
        useFastTaskSampling()
        server.monitors.wakeQuietInterval = wakeQuiet
        server.tasks.kickoffCheckDelay = 0.4
        server.tasks.kickoffQuietInterval = 0.5
        server.tasks.kickoffRetryInterval = retryInterval
    }

    func script(_ name: String, _ body: String) throws -> String {
        let url = projectRoot.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func count(_ text: String, in session: TerminalSession) async throws -> Int {
        try await output(of: session).components(separatedBy: text).count - 1
    }
}

@MainActor
@Suite(.serialized)
struct ControlAgentTaskKickoffTests {
    /// Claude Code shows its composer before it takes input (while its MCP
    /// servers load) and drops what is typed meanwhile: the kickoff that
    /// went nowhere is typed again once the composer is back and still,
    /// and the worker gets it once, sent.
    @Test func kickoffDroppedWhileTheWorkerStartsIsTypedAgainAndSentOnce() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        // Typed again no sooner than 1.5 s after the first: after the
        // startup below is over.
        harness.useFastKickoffChecks(wakeQuiet: 3, retryInterval: 1.5)
        harness.server.start()
        // Named as Claude: Cherry waits for its composer before the first
        // kickoff (a second of quiet screen: about 1 s in), as it does for
        // the real one.
        let script = try harness.script("slow-start.sh", """
        #!/bin/sh
        stty -echo 2>/dev/null
        printf '\\342\\235\\257 \\n'
        # Starting up: whatever is typed now is lost.
        perl -MPOSIX -MTime::HiRes=sleep -e 'for (1..20) { sleep 0.1; POSIX::tcflush(0, POSIX::TCIFLUSH()) }'
        printf '\\342\\235\\257 \\n'
        while IFS= read -r line; do
          printf '> %s\\n\\n\\342\\235\\257 \\n' "$line"
          sleep 0.1
          printf '\\342\\234\\266 Reticulating\\342\\200\\246 (esc to interrupt)'
          sleep 0.3
          printf '\\r\\033[2K\\342\\217\\272 handled %s\\n\\n\\342\\235\\257 \\n' "$line"
        done
        """)
        let (worker, spawned) = try await harness.spawnTask(agent: "Claude", command: script, task: "Start slowly")
        let taskID = try #require(spawned.task?.taskID)
        #expect(spawned.sentBytes > 0, "the first kickoff was typed (and lost)")

        let handled = try await harness.waitForOutput("handled You are Cherry task \(taskID)", in: worker, seconds: 20)
        #expect(handled.contains("handled You are Cherry task \(taskID)"), "the kickoff never reached the worker: \(handled)")
        harness.server.callerSessionResolverForTesting = { _ in worker }
        #expect(try await harness.send(.getMyTask).error == nil)
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(try await harness.count("handled You are Cherry task \(taskID)", in: worker) == 1)
        #expect(try await harness.count("> You are Cherry task \(taskID)", in: worker) == 1, "sent once")
        let task = try #require(harness.server.tasks.tasks[taskID])
        #expect(task.kickoffDeliveredAt != nil)
        #expect(task.kickoffAttempts >= 2, "typed again: \(task.kickoffAttempts)")
        let events = try await harness.waitForTasks(.init(taskIDs: [taskID], timeoutMilliseconds: 0))
        #expect(events.events.contains { $0.kind == .kickoffRetry && $0.text?.contains("did not reach") == true })
        #expect(!events.events.contains { $0.kind == .nudged })
        #expect(!(try await harness.output(of: worker)).contains(AgentTaskRegistry.nudgeLine))
    }

    /// A kickoff whose text reached the composer but whose Enter was lost
    /// gets its Enter (once the composer is still), and is never typed a
    /// second time.
    @Test func kickoffLeftInTheComposerGetsItsEnter() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastKickoffChecks(wakeQuiet: 3)
        harness.server.start()
        // A composer that shows what is typed and loses its first Enter.
        let script = try harness.script("lost-enter.pl", """
        #!/usr/bin/perl
        use strict;
        use warnings;
        $| = 1;
        system("stty raw -echo 2>/dev/null");
        my $composer = "\\xe2\\x9d\\xaf ";
        print $composer;
        my $buffer = "";
        my $lost = 0;
        while (sysread(STDIN, my $byte, 1)) {
          if ($byte eq "\\r" || $byte eq "\\n") {
            if (!$lost) { $lost = 1; next; }
            next if $buffer eq "";
            print "\\r\\n> $buffer\\r\\n\\r\\n";
            select(undef, undef, undef, 0.1);
            print "\\xe2\\x9c\\xb6 Reticulating\\xe2\\x80\\xa6 (esc to interrupt)";
            select(undef, undef, undef, 0.3);
            print "\\r\\033[2K\\xe2\\x8f\\xba handled $buffer\\r\\n\\r\\n$composer";
            $buffer = "";
          } else {
            $buffer .= $byte;
            print $byte;
          }
        }
        """)
        let (worker, spawned) = try await harness.spawnTask(agent: "Claude", command: script, task: "Lose the Enter")
        let taskID = try #require(spawned.task?.taskID)

        let handled = try await harness.waitForOutput("handled You are Cherry task \(taskID)", in: worker, seconds: 20)
        #expect(handled.contains("handled You are Cherry task \(taskID)"), "the kickoff stayed in the composer: \(handled)")
        harness.server.callerSessionResolverForTesting = { _ in worker }
        #expect(try await harness.send(.getMyTask).error == nil)
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(try await harness.count("handled You are Cherry task \(taskID)", in: worker) == 1)
        let task = try #require(harness.server.tasks.tasks[taskID])
        #expect(task.kickoffAttempts == 1, "the text was never typed again")
        #expect(task.kickoffEnterPresses == 1)
        let events = try await harness.waitForTasks(.init(taskIDs: [taskID], timeoutMilliseconds: 0))
        #expect(events.events.contains { $0.kind == .kickoffRetry && $0.text?.contains("Enter") == true })
    }

    /// A worker whose turn ends without asking for its task is never told
    /// to report: it gets the kickoff again, at most three kickoffs in all,
    /// and then its task fails with its last lines.
    @Test func workerThatNeverAsksForItsTaskGetsTheKickoffAgainNeverTheNudge() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastKickoffChecks()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.1, working: 0.3)
        let (worker, spawned) = try await harness.spawnTask(agent: "Claude", command: script, task: "Ignore it")
        let taskID = try #require(spawned.task?.taskID)

        var detail = try await harness.task(taskID)
        for _ in 0..<300 where !detail.task.state.isSettled {
            try await Task.sleep(for: .milliseconds(100))
            detail = try await harness.task(taskID)
        }
        #expect(detail.task.state == .failed)
        #expect(detail.task.reason?.contains("never called get_my_task") == true, "\(String(describing: detail.task.reason))")
        #expect(detail.result?.source == "screen_tail")
        #expect(!detail.task.nudged)
        let output = try await harness.output(of: worker)
        #expect(!output.contains(AgentTaskRegistry.nudgeLine), "nudged a worker that never read its task: \(output)")
        #expect(output.components(separatedBy: "handled You are Cherry task \(taskID)").count - 1 == AgentTaskRegistry.maximumKickoffAttempts)
        let events = try await harness.waitForTasks(.init(taskIDs: [taskID], timeoutMilliseconds: 0))
        #expect(events.events.contains { $0.kind == .kickoffRetry && $0.text?.contains("without asking for its task") == true })
        #expect(!events.events.contains { $0.kind == .nudged })
    }
}
