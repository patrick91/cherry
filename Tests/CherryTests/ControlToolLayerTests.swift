@testable import Cherry
@testable import CherryControl
import Foundation
import Testing

// The MCP tool layer (`CherryToolLayer`, Sources/CherryControl), which the
// app runs for `callTool` and CherryMCP runs against an app without
// `appInfo`. A recording transport shows which requests a call sends, in
// which order and with which timeouts; its answers show what the agent
// reads. CherryTests' mcp* tests run the same layer through CherryMCP's
// adapter against a real control server.

/// A transport that records what the layer sends and answers each request
/// with `answer`: by default an error, so a call stops at its first
/// request.
private final class ControlToolLayerRecorder: CherryToolTransport, @unchecked Sendable {
    let socketPath: String?
    private let answer: @Sendable (CherryControlRequest) -> CherryControlResponse
    private let lock = NSLock()
    private var sent: [(request: CherryControlRequest, timeout: TimeInterval?)] = []

    init(
        socketPath: String? = nil,
        answer: @escaping @Sendable (CherryControlRequest) -> CherryControlResponse = { _ in
            CherryControlResponse(error: CherryControlError(code: "recorded", message: "Recorded."))
        }
    ) {
        self.socketPath = socketPath
        self.answer = answer
    }

    func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse {
        lock.withLock { sent.append((request, timeout)) }
        return answer(request)
    }

    var requests: [CherryControlRequest] { lock.withLock { sent.map(\.request) } }
    var timeouts: [TimeInterval?] { lock.withLock { sent.map(\.timeout) } }
}

/// The first request `name` sends for a caller that names no project.
private func controlToolLayerRequest(
    _ name: String,
    _ arguments: [String: JSONValue],
    caller: CherryToolCaller = CherryToolCaller()
) async -> CherryControlRequest? {
    let recorder = ControlToolLayerRecorder()
    _ = await CherryToolLayer.call(name: name, arguments: arguments, caller: caller, transport: recorder)
    return recorder.requests.first
}

/// The error a call answers, and whether it sent any request first.
private func controlToolLayerRefusal(
    _ name: String,
    _ arguments: [String: JSONValue],
    caller: CherryToolCaller = CherryToolCaller()
) async -> (code: String?, message: String?, sentRequests: Bool) {
    let recorder = ControlToolLayerRecorder()
    let result = await CherryToolLayer.call(name: name, arguments: arguments, caller: caller, transport: recorder)
    let error = result.isError ? result.structured?.objectValue?["error"]?.objectValue : nil
    return (error?["code"]?.stringValue, error?["message"]?.stringValue, !recorder.requests.isEmpty)
}

private let controlToolLayerAgentID = "11111111-1111-1111-1111-111111111111"
private let controlToolLayerOtherID = "22222222-2222-2222-2222-222222222222"

private func controlToolLayerProcess(id: String = controlToolLayerAgentID, kind: String = "agent", pid: Int32? = nil) -> ProcessSummary {
    ProcessSummary(
        id: id,
        name: "Claude",
        kind: kind,
        state: "live",
        pid: pid,
        workingDirectory: "/work/app",
        commandLine: "claude",
        lineCount: 3,
        selected: true,
        agentName: "Claude",
        commandName: nil,
        agentActivityState: "idle",
        agentTurn: 2
    )
}

// MARK: - Arguments

@Test func controlToolLayerTrimsProcessIDsAndParentsButNotProcessNames() async throws {
    let byID = await controlToolLayerRequest("get_process_status", ["process_id": .string("  A  ")])
    #expect(byID == .getProcessStatus(.init(processID: "A", processName: nil)))
    let byName = await controlToolLayerRequest("get_process_status", ["process_name": .string(" web ")])
    #expect(byName == .getProcessStatus(.init(processID: nil, processName: " web ")))

    // A tool that names no process gets the session's bound process, else
    // the caller's own; one that names it by name gets no id.
    let bound = CherryToolCaller(processID: "P", boundProcessID: "B")
    #expect(await controlToolLayerRequest("get_process_status", [:], caller: bound) == .getProcessStatus(.init(processID: "B", processName: nil)))
    let unbound = CherryToolCaller(processID: "P")
    #expect(await controlToolLayerRequest("get_process_status", [:], caller: unbound) == .getProcessStatus(.init(processID: "P", processName: nil)))
    #expect(await controlToolLayerRequest("get_process_status", [:]) == .getProcessStatus(.init(processID: nil, processName: nil)))
    #expect(await controlToolLayerRequest("get_process_status", ["process_name": .string("web")], caller: bound)
        == .getProcessStatus(.init(processID: nil, processName: "web")))
    // A name of only spaces names nothing.
    #expect(await controlToolLayerRequest("get_process_status", ["process_name": .string("  ")], caller: bound)
        == .getProcessStatus(.init(processID: "B", processName: "  ")))

    // A terminal's parent is passed on as given, trimmed.
    let spawned = await controlToolLayerRequest("spawn_process", ["kind": .string("terminal"), "parent_agent_id": .string(" Q ")])
    guard case .spawnProcess(let spawn)? = spawned else {
        Issue.record("Expected spawnProcess, got \(String(describing: spawned))")
        return
    }
    #expect(spawn.parentAgentID == "Q")

    // A required string that is empty, or not a string, is missing.
    for value in [JSONValue.string(""), .int(5), .null] {
        let refusal = await controlToolLayerRefusal("get_task", ["task_id": value])
        #expect(refusal.code == "missing_argument", "\(value)")
        #expect(refusal.message == "Missing required string argument: task_id")
        #expect(!refusal.sentRequests)
    }
}

@Test func controlToolLayerReadsWholeNumbersAlsoWithAZeroFraction() async {
    let cases: [(JSONValue, Int?)] = [
        (.int(7), 7),
        (.double(5000.0), 5000),
        (.double(1.5), nil),
        (.string("5000"), nil),
        (.bool(true), nil),
    ]
    for (value, expected) in cases {
        let request = await controlToolLayerRequest("wait_for_events", ["subscription_id": .string("s"), "timeout_ms": value])
        guard case .waitForEvents(let wait)? = request else {
            Issue.record("Expected waitForEvents for \(value), got \(String(describing: request))")
            continue
        }
        #expect(wait.timeoutMilliseconds == expected, "\(value)")
    }
}

@Test func controlToolLayerReadsOnlyJSONBooleansAsBooleans() async {
    let cases: [(JSONValue, Bool?)] = [(.bool(true), true), (.bool(false), false), (.string("true"), nil), (.int(1), nil)]
    for (value, expected) in cases {
        let request = await controlToolLayerRequest("search_process_output", ["query": .string("error"), "case_sensitive": value])
        guard case .searchProcessOutput(let search)? = request else {
            Issue.record("Expected searchProcessOutput for \(value), got \(String(describing: request))")
            continue
        }
        #expect(search.caseSensitive == expected, "\(value)")
    }
}

@Test func controlToolLayerRefusesAStringListThatIsNotOneBeforeAnyRequest() async {
    let listed = await controlToolLayerRequest("subscribe", ["process_ids": .array([.string("a"), .string("b")])], caller: CherryToolCaller(processID: "P"))
    guard case .subscribe(let subscribe)? = listed else {
        Issue.record("Expected subscribe, got \(String(describing: listed))")
        return
    }
    #expect(subscribe.processIDs == ["a", "b"])
    #expect(subscribe.events == nil)
    #expect(subscribe.subscriberProcessID == "P")

    for value in [JSONValue.string("a"), .array([.int(1)]), .array([.string("a"), .null]), .null] {
        let refusal = await controlToolLayerRefusal("subscribe", ["process_ids": value])
        #expect(refusal.code == "invalid_argument", "\(value)")
        #expect(refusal.message == "process_ids must be an array of strings.")
        #expect(!refusal.sentRequests)
    }
}

@Test func controlToolLayerReadsTodoStatusesAndClosePoliciesInAnyCase() async {
    let created = await controlToolLayerRequest("create_todo", ["title": .string("Ship"), "status": .string(" Done ")])
    guard case .createTodo(let todo)? = created else {
        Issue.record("Expected createTodo, got \(String(describing: created))")
        return
    }
    #expect(todo.status == .done)
    #expect(todo.markdown == "")
    let unset = await controlToolLayerRequest("create_todo", ["title": .string("Ship"), "status": .string("  ")])
    guard case .createTodo(let unsetTodo)? = unset else {
        Issue.record("Expected createTodo, got \(String(describing: unset))")
        return
    }
    #expect(unsetTodo.status == nil)
    let badStatus = await controlToolLayerRefusal("create_todo", ["title": .string("Ship"), "status": .string("Someday")])
    #expect(badStatus.code == "invalid_todo_status")
    #expect(badStatus.message == "Unknown todo status: Someday")
    #expect(!badStatus.sentRequests)

    let closed = await controlToolLayerRequest("close_process", ["process_id": .string("A"), "agent_close_policy": .string("Close_Sub_Agents")])
    guard case .closeProcess(let close)? = closed else {
        Issue.record("Expected closeProcess, got \(String(describing: closed))")
        return
    }
    #expect(close.agentClosePolicy == .closeSubAgents)
    let badPolicy = await controlToolLayerRefusal("close_process", ["process_id": .string("A"), "agent_close_policy": .string("keep")])
    #expect(badPolicy.code == "invalid_agent_close_policy")
    #expect(badPolicy.message == "Unknown agent close policy: keep")
    #expect(!badPolicy.sentRequests)
}

@Test func controlToolLayerTakesASchemaAsAnObjectOrJSONTextOfOne() async throws {
    let schema = JSONValue.object(["type": .string("object")])
    #expect(try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": .string(#"{"type":"object"}"#)]) == schema)
    #expect(try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": schema]) == schema)
    #expect(try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": .null]) == nil)
    #expect(try CherryToolLayer.schemaArgument("result_schema", in: [:]) == nil)
    for text in ["not json", "[1]", "3"] {
        #expect(throws: CherryControlError.self) {
            try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": .string(text)])
        }
    }
    let refusal = await controlToolLayerRefusal("spawn_agent", ["name": .string("Claude"), "task": .string("Review"), "result_schema": .string("not json")])
    #expect(refusal.code == "invalid_argument")
    #expect(refusal.message == "result_schema must be a JSON Schema object.")
    #expect(!refusal.sentRequests)

    // A value is any JSON, as sent: a string that looks like a data URL is a
    // string (the MCP SDK's Value made it data).
    let value = JSONValue.array([.int(2), .string("data:text/plain;base64,aGk="), .object(["camelCase": .null])])
    #expect(try CherryToolLayer.jsonArgument("value", in: ["value": value]) == value)
    let reported = await controlToolLayerRequest("report_result", ["value": value, "summary": .string("Done")])
    guard case .reportResult(let report)? = reported else {
        Issue.record("Expected reportResult, got \(String(describing: reported))")
        return
    }
    #expect(report.value == value)
    #expect(report.summary == "Done")
}

// MARK: - Timeouts

@Test func controlToolLayerClientTimeoutsAreTodaysNumbers() {
    // PersistentTabLaunchAndSignalTests' numbers.
    #expect(CherryToolLayer.clientTimeout(for: "spawn_agent", arguments: ["wait_ms": .int(1_000)]) == 21)
    #expect(CherryToolLayer.clientTimeout(for: "spawn_process", arguments: [:]) == 20)
    #expect(CherryToolLayer.clientTimeout(for: "spawn_process", arguments: ["kind": .string("terminal")]) == 20)
    #expect(CherryToolLayer.clientTimeout(for: "spawn_process", arguments: ["kind": .string("command"), "wait_ms": .int(1_000)]) == 31)
    #expect(CherryToolLayer.clientTimeout(for: "spawn_process", arguments: ["kind": .string(" Command ")]) == 30)
    #expect(CherryToolLayer.clientTimeout(for: "send_process_input", arguments: ["wait_ms": .int(9_000)]) == 25)
    for tool in ["start_process", "start_all_commands", "restart_all_commands"] {
        #expect(CherryToolLayer.clientTimeout(for: tool, arguments: ["wait_ms": .int(2_000)]) == 22)
    }
    #expect(CherryToolLayer.clientTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(3_000)]) == 20)
    #expect(CherryToolLayer.clientTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(60_000)]) == 65)
    #expect(CherryToolLayer.clientTimeout(for: "wait_for_process_idle", arguments: ["timeout_ms": .int(3_000)]) == 8)
    #expect(CherryToolLayer.clientTimeout(for: "list_processes", arguments: [:]) == nil)

    // The waits' defaults fit a 60 s tool timeout (ControlAgentWaitTests,
    // ControlAgentTaskTests), and wait_for_events and wait_for_tasks never
    // wait longer, whatever they are asked.
    #expect(CherryToolLayer.clientTimeout(for: "wait_for_process_idle", arguments: [:]) == 55)
    #expect(CherryToolLayer.clientTimeout(for: "send_agent_message", arguments: [:]) == 45)
    for tool in ["wait_for_events", "wait_for_tasks"] {
        #expect(CherryToolLayer.clientTimeout(for: tool, arguments: [:]) == 55)
        #expect(CherryToolLayer.clientTimeout(for: tool, arguments: ["timeout_ms": .int(300_000)]) == 55)
        #expect(CherryToolLayer.clientTimeout(for: tool, arguments: ["timeout_ms": .int(1_000)]) == 6)
    }
    #expect(CherryToolLayer.clientTimeout(for: "wait_for_bound_port", arguments: [:]) == 15)
    #expect(CherryToolLayer.clientTimeout(for: "wait_for_bound_port", arguments: ["timeout_ms": .int(90_000)]) == 65)
    // wait_ms is clamped to 5 s, and a whole number with a zero fraction counts.
    #expect(CherryToolLayer.clientTimeout(for: "send_process_input", arguments: ["wait_ms": .double(2_000.0)]) == 22)
    #expect(CherryToolLayer.clientTimeout(for: "start_process", arguments: ["wait_ms": .int(-3)]) == 20)
}

@Test func controlToolLayerCallTimeoutsCoverAWholeToolCall() {
    // send_agent_message: the message (20 s) and then the idle wait, plus 5 s.
    #expect(CherryToolLayer.callTimeout(for: "send_agent_message", arguments: [:], profile: .unknown) == 65)
    #expect(CherryToolLayer.callTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(3_000)], profile: .unknown) == 28)
    #expect(CherryToolLayer.callTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(400_000)], profile: .unknown) == 325)
    // An agent's spawn also checks its caller first.
    #expect(CherryToolLayer.callTimeout(for: "spawn_agent", arguments: ["wait_ms": .int(1_000)], profile: .unknown) == 26)
    #expect(CherryToolLayer.callTimeout(for: "spawn_process", arguments: ["kind": .string(" Agent ")], profile: .unknown) == 25)
    #expect(CherryToolLayer.callTimeout(for: "spawn_process", arguments: ["kind": .string("terminal")], profile: .unknown) == 20)
    #expect(CherryToolLayer.callTimeout(for: "spawn_process", arguments: ["kind": .string("command")], profile: .unknown) == 30)
    // Everything else: one request's timeout, else the client's 10 s.
    #expect(CherryToolLayer.callTimeout(for: "wait_for_process_idle", arguments: ["timeout_ms": .int(3_000)], profile: .unknown) == 8)
    #expect(CherryToolLayer.callTimeout(for: "list_processes", arguments: [:], profile: .unknown) == 10)
    #expect(CherryToolLayer.callTimeout(for: "whoami", arguments: [:], profile: .unknown) == 10)

    // The event and task waits as long as the client's cap allows.
    let profiles = [
        ToolClientProfile.unknown,
        ToolClientProfile(client: ToolClientInfo(name: "claude-code", version: "2.1.299")),
        ToolClientProfile(client: ToolClientInfo(name: "codex-mcp-client"), toolTimeoutMilliseconds: 300_000),
    ]
    for profile in profiles {
        for tool in ["wait_for_events", "wait_for_tasks"] {
            #expect(CherryToolLayer.callTimeout(for: tool, arguments: [:], profile: profile) == 55)
            #expect(CherryToolLayer.callTimeout(for: tool, arguments: ["timeout_ms": .int(1_000)], profile: profile) == 6)
            #expect(CherryToolLayer.callTimeout(for: tool, arguments: ["timeout_ms": .int(-5)], profile: profile) == 5)
            let longest = TimeInterval(profile.clampedWait(300_000, default: CherryControl.defaultWaitMilliseconds)) / 1_000 + 5
            #expect(CherryToolLayer.callTimeout(for: tool, arguments: ["timeout_ms": .int(300_000)], profile: profile) == longest)
        }
    }
    #expect(CherryToolLayer.callTimeout(for: "wait_for_events", arguments: ["timeout_ms": .int(300_000)], profile: .unknown) == 55)
}

// MARK: - Results

@Test func controlToolLayerEncodesResultsAsAgentsReadThem() async throws {
    let process = controlToolLayerProcess()
    let recorder = ControlToolLayerRecorder { request in
        if case .getProcessStatus = request {
            return CherryControlResponse(result: .getProcessStatus(ProcessStatusResult(process: process)))
        }
        return CherryControlResponse(result: .getProjectStatus(ProjectStatusResult(
            projectRoot: "/work/app",
            processCounts: ProcessCounts(total: 1, terminals: 0, agents: 1, commands: 0),
            todoCount: 2,
            features: ProjectFeatureAvailability(todosEnabled: true),
            selectedProcessID: nil,
            selectedProcessName: nil,
            health: "ok"
        )))
    }

    // The text is snake_case with sorted keys; structuredContent keeps the
    // payload's own camelCase keys.
    let status = await CherryToolLayer.call(
        name: "get_process_status",
        arguments: ["process_id": .string(controlToolLayerAgentID)],
        caller: CherryToolCaller(),
        transport: recorder
    )
    #expect(!status.isError)
    #expect(status.text == #"{"process":{"accepts_input":false,"agent_activity_state":"idle","agent_name":"Claude","agent_turn":2,"command_line":"claude","id":"11111111-1111-1111-1111-111111111111","kind":"agent","line_count":3,"name":"Claude","output_version":0,"selected":true,"state":"live","working_directory":"\/work\/app"}}"#)
    #expect(status.structured == (try JSONValue.parse(Data(#"{"process":{"acceptsInput":false,"agentActivityState":"idle","agentName":"Claude","agentTurn":2,"commandLine":"claude","id":"11111111-1111-1111-1111-111111111111","kind":"agent","lineCount":3,"name":"Claude","outputVersion":0,"selected":true,"state":"live","workingDirectory":"/work/app"}}"#.utf8))))
    #expect(status.bindProcessID == nil)
    #expect(status.toolsDigest == nil)

    // The field the wire keeps only for older helpers stays out of both.
    let project = await CherryToolLayer.call(name: "get_project_status", arguments: [:], caller: CherryToolCaller(), transport: recorder)
    #expect(project.text.contains(#""features":{"todos_enabled":true}"#), "\(project.text)")
    #expect(!project.text.contains("notes_enabled"))
    let features = project.structured?.objectValue?["features"]
    #expect(features == .object(["todosEnabled": .bool(true)]))

    // Cherry's error, with its details.
    let refusing = ControlToolLayerRecorder { _ in
        CherryControlResponse(error: CherryControlError(
            code: "schema_mismatch",
            message: "The value does not match the task's result schema.",
            details: ["$.count: expected integer", "$.ok: required"]
        ))
    }
    let mismatch = await CherryToolLayer.call(name: "report_result", arguments: ["value": .object([:])], caller: CherryToolCaller(), transport: refusing)
    #expect(mismatch.isError)
    #expect(mismatch.text == #"{"error":{"code":"schema_mismatch","details":["$.count: expected integer","$.ok: required"],"message":"The value does not match the task's result schema."}}"#)
    #expect(mismatch.structured == .object(["error": .object([
        "code": .string("schema_mismatch"),
        "details": .array([.string("$.count: expected integer"), .string("$.ok: required")]),
        "message": .string("The value does not match the task's result schema."),
    ])]))

    // An answer of another kind is the tool's error too.
    let failing = ControlToolLayerRecorder { _ in CherryControlResponse(result: .listAgents(ListAgentsResult(activeProjectRoot: nil, agents: []))) }
    let unexpected = await CherryToolLayer.call(name: "bind_session_process", arguments: ["process_id": .string("A")], caller: CherryToolCaller(bindsSession: true), transport: failing)
    #expect(unexpected.isError)
    #expect(unexpected.text == #"{"error":{"code":"unexpected_response","message":"Cherry returned an unexpected response for bind_session_process."}}"#)
}

@Test func controlToolLayerRefusesAnUnknownToolBeforeAnyRequest() async {
    // Even a caller whose project is found from its directory (a request of
    // its own) sends nothing.
    let caller = CherryToolCaller(processID: controlToolLayerAgentID, workingDirectory: "/work/app")
    for name in ["activate_worktree", "list_notes", "", "LIST_PROCESSES"] {
        let refusal = await controlToolLayerRefusal(name, ["project_root": .string("/work/app")], caller: caller)
        #expect(refusal.code == "unknown_tool", "\(name)")
        #expect(refusal.message == "Unknown Cherry tool: \(name)")
        #expect(!refusal.sentRequests, "\(name)")
    }
}

@Test func controlToolLayerRefusesATaskAndAMessageTogetherBeforeAnyRequest() async {
    let caller = CherryToolCaller(processID: controlToolLayerAgentID, workingDirectory: "/work/app")
    let refusal = await controlToolLayerRefusal(
        "spawn_agent",
        ["name": .string("Claude"), "task": .string("Review"), "message": .string("hi")],
        caller: caller
    )
    #expect(refusal.code == "invalid_argument")
    #expect(refusal.message == "Pass the brief as task or a first message as message, not both: a task's worker reads its brief with get_my_task.")
    #expect(!refusal.sentRequests)
}

// MARK: - Scope and composites

@Test func controlToolLayerScopesToTheExplicitRootThenTheCallersThenItsDirectorysProject() async {
    let projects = CherryControlResponse(result: .listProjects(ListProjectsResult(
        activeProjectRoot: "/elsewhere",
        projects: [
            ProjectInfo(root: "/work", name: "work", active: false, open: true),
            ProjectInfo(root: "/work/app", name: "app", active: false, open: true),
            ProjectInfo(root: "/elsewhere", name: "elsewhere", active: true, open: true),
        ]
    )))
    let answering = { @Sendable (request: CherryControlRequest) -> CherryControlResponse in
        if case .listProjects = request { return projects }
        return CherryControlResponse(error: CherryControlError(code: "recorded", message: "Recorded."))
    }
    let caller = CherryToolCaller(projectRoot: " /caller ", workingDirectory: "/work/app/Sources")

    // An explicit project_root wins, trimmed.
    let explicit = ControlToolLayerRecorder(answer: answering)
    _ = await CherryToolLayer.call(name: "list_processes", arguments: ["project_root": .string(" /explicit ")], caller: caller, transport: explicit)
    #expect(explicit.requests == [.scoped(.init(projectRoot: "/explicit", request: .listProcesses(.init(kind: nil))))])

    // Then the caller's CHERRY_PROJECT_ROOT, with no request to find it.
    let callers = ControlToolLayerRecorder(answer: answering)
    _ = await CherryToolLayer.call(name: "list_processes", arguments: ["project_root": .string("  ")], caller: caller, transport: callers)
    #expect(callers.requests == [.scoped(.init(projectRoot: "/caller", request: .listProcesses(.init(kind: nil))))])

    // Then the innermost open project its directory is in.
    let inferred = ControlToolLayerRecorder(answer: answering)
    let inside = CherryToolCaller(workingDirectory: "/work/app/Sources")
    _ = await CherryToolLayer.call(name: "list_processes", arguments: [:], caller: inside, transport: inferred)
    #expect(inferred.requests == [.listProjects, .scoped(.init(projectRoot: "/work/app", request: .listProcesses(.init(kind: nil))))])

    // Outside every project: unscoped (the active window's).
    let outside = ControlToolLayerRecorder(answer: answering)
    _ = await CherryToolLayer.call(name: "list_processes", arguments: [:], caller: CherryToolCaller(workingDirectory: "/tmp"), transport: outside)
    #expect(outside.requests == [.listProjects, .listProcesses(.init(kind: nil))])

    // A project's open is never scoped to the caller's project.
    let open = ControlToolLayerRecorder(answer: answering)
    _ = await CherryToolLayer.call(name: "open_project", arguments: ["project_root": .string("/work")], caller: caller, transport: open)
    #expect(open.requests == [.openProject(.init(projectRoot: "/work"))])

    // get_status lists the caller's project's terminals, whatever it asks.
    let status = ControlToolLayerRecorder(answer: answering)
    _ = await CherryToolLayer.call(name: "get_status", arguments: ["project_root": .string("/explicit")], caller: caller, transport: status)
    #expect(status.requests == [.scoped(.init(projectRoot: "/caller", request: .listTerminals))])
}

@Test func controlToolLayerBindsOnlyForACallerWithASession() async {
    let process = controlToolLayerProcess(id: controlToolLayerOtherID)
    let answering = { @Sendable (request: CherryControlRequest) -> CherryControlResponse in
        if case .spawnProcess = request {
            return CherryControlResponse(result: .spawnProcess(SpawnProcessResult(process: process, sentBytes: 0, output: nil)))
        }
        return CherryControlResponse(result: .getProcessStatus(ProcessStatusResult(process: process)))
    }

    // Without a session there is nothing to bind.
    let sessionless = ControlToolLayerRecorder(answer: answering)
    let refused = await CherryToolLayer.call(
        name: "bind_session_process",
        arguments: ["process_id": .string(controlToolLayerOtherID)],
        caller: CherryToolCaller(processID: controlToolLayerAgentID),
        transport: sessionless
    )
    #expect(refused.isError)
    #expect(refused.text.contains("mcp_context_unavailable"))
    #expect(refused.bindProcessID == nil)
    #expect(sessionless.requests.isEmpty)
    // A session must name the process.
    let unnamed = await controlToolLayerRefusal("bind_session_process", [:], caller: CherryToolCaller(bindsSession: true))
    #expect(unnamed.code == "missing_process_selector")
    #expect(!unnamed.sentRequests)

    let session = CherryToolCaller(processID: controlToolLayerAgentID, boundProcessID: controlToolLayerAgentID, bindsSession: true)
    let binding = ControlToolLayerRecorder(answer: answering)
    let bound = await CherryToolLayer.call(name: "bind_session_process", arguments: ["process_id": .string(" \(controlToolLayerOtherID) ")], caller: session, transport: binding)
    #expect(!bound.isError, "\(bound.text)")
    #expect(bound.bindProcessID == controlToolLayerOtherID)
    #expect(binding.requests == [.getProcessStatus(.init(processID: controlToolLayerOtherID, processName: nil))])
    #expect(bound.structured?.objectValue?["boundProcessID"] == .string(controlToolLayerOtherID))
    #expect(bound.structured?.objectValue?["previousBoundProcessID"] == .string(controlToolLayerAgentID))
    #expect(bound.text.hasPrefix(#"{"bound_process_id":"\#(controlToolLayerOtherID)","previous_bound_process_id":"\#(controlToolLayerAgentID)","process":{"#))

    // spawn_agent's bind_session binds only in a session; the parent is
    // given, so nothing checks the caller first.
    for caller in [session, CherryToolCaller(processID: controlToolLayerAgentID)] {
        let spawning = ControlToolLayerRecorder(answer: answering)
        let spawned = await CherryToolLayer.call(
            name: "spawn_agent",
            arguments: ["name": .string("Claude"), "bind_session": .bool(true), "top_level": .bool(true)],
            caller: caller,
            transport: spawning
        )
        #expect(!spawned.isError, "\(spawned.text)")
        #expect(spawning.requests.count == 1)
        guard case .spawnProcess(let request)? = spawning.requests.first else {
            Issue.record("Expected spawnProcess, got \(spawning.requests)")
            continue
        }
        #expect(request.parentAgentID == CherryControl.topLevelAgentParentID)
        #expect(spawning.timeouts == [20])
        let payload = spawned.structured?.objectValue
        if caller.bindsSession {
            #expect(spawned.bindProcessID == controlToolLayerOtherID)
            #expect(payload?["boundProcessID"] == .string(controlToolLayerOtherID))
            #expect(payload?["previousBoundProcessID"] == .string(controlToolLayerAgentID))
        } else {
            #expect(spawned.bindProcessID == nil)
            #expect(payload?["boundProcessID"] == nil)
            #expect(payload?["previousBoundProcessID"] == nil)
        }
    }
}

@Test func controlToolLayerNestsAnAgentUnderACallerThatIsAnAgent() async {
    for callerKind in ["agent", "terminal"] {
        let caller = controlToolLayerProcess(id: controlToolLayerAgentID, kind: callerKind)
        let child = controlToolLayerProcess(id: controlToolLayerOtherID)
        let recorder = ControlToolLayerRecorder { request in
            if case .spawnProcess = request {
                return CherryControlResponse(result: .spawnProcess(SpawnProcessResult(process: child, sentBytes: 0, output: nil)))
            }
            return CherryControlResponse(result: .getProcessStatus(ProcessStatusResult(process: caller)))
        }
        let result = await CherryToolLayer.call(
            name: "spawn_process",
            arguments: ["kind": .string("agent"), "name": .string("Claude")],
            caller: CherryToolCaller(processID: controlToolLayerAgentID, projectRoot: "/work/app"),
            transport: recorder
        )
        #expect(!result.isError, "\(result.text)")
        // The caller's kind is looked up in its project, with a short timeout.
        #expect(recorder.requests.first == .scoped(.init(
            projectRoot: "/work/app",
            request: .getProcessStatus(.init(processID: controlToolLayerAgentID, processName: nil))
        )))
        #expect(recorder.timeouts == [2, 20])
        guard case .scoped(let scoped)? = recorder.requests.last, case .spawnProcess(let spawn) = scoped.request else {
            Issue.record("Expected a scoped spawnProcess, got \(recorder.requests)")
            continue
        }
        #expect(spawn.parentAgentID == (callerKind == "agent" ? controlToolLayerAgentID : nil), "\(callerKind)")
    }
}

/// A spawn whose first input did not arrive says why (input_error, in
/// spawn_agent's payload and spawn_process's result alike); it is absent
/// when the input arrived, and from an app that predates it.
@Test func controlToolLayerSaysWhyASpawnsFirstInputDidNotArrive() async throws {
    let process = controlToolLayerProcess(id: controlToolLayerOtherID)
    let refusal = CherryControlError(
        code: "agent_awaiting_permission",
        message: "Agent 'Claude' is waiting for an answer to a permission prompt; nothing was sent."
    )
    func spawning(_ result: SpawnProcessResult) -> ControlToolLayerRecorder {
        ControlToolLayerRecorder { _ in CherryControlResponse(result: .spawnProcess(result)) }
    }
    let arguments: [String: JSONValue] = ["name": .string("Claude"), "message": .string("hi"), "top_level": .bool(true)]

    let refused = await CherryToolLayer.call(
        name: "spawn_agent", arguments: arguments, caller: CherryToolCaller(),
        transport: spawning(SpawnProcessResult(process: process, sentBytes: 0, output: nil, inputError: refusal))
    )
    #expect(!refused.isError, "the process exists: \(refused.text)")
    #expect(refused.text.contains(#""input_error":{"code":"agent_awaiting_permission","message":"Agent 'Claude' is waiting for an answer to a permission prompt; nothing was sent."}"#), "\(refused.text)")
    #expect(refused.text.contains(#""sent_bytes":0"#))
    #expect(refused.structured?.objectValue?["inputError"]?.objectValue?["code"] == .string("agent_awaiting_permission"))

    let spawnedProcess = await CherryToolLayer.call(
        name: "spawn_process", arguments: ["kind": .string("terminal"), "text": .string("make\n")], caller: CherryToolCaller(),
        transport: spawning(SpawnProcessResult(process: process, sentBytes: 0, output: nil, inputError: refusal))
    )
    #expect(spawnedProcess.text.contains(#""input_error":{"code":"agent_awaiting_permission""#), "\(spawnedProcess.text)")

    let sent = await CherryToolLayer.call(
        name: "spawn_agent", arguments: arguments, caller: CherryToolCaller(),
        transport: spawning(SpawnProcessResult(process: process, sentBytes: 3, output: nil))
    )
    #expect(!sent.isError)
    #expect(!sent.text.contains("input_error"), "\(sent.text)")
    #expect(sent.structured?.objectValue?["inputError"] == nil)

    // On the wire it is optional: an answer without it (an app that
    // predates it) decodes, and one with it round-trips.
    let delivered = try JSONEncoder().encode(SpawnProcessResult(process: process, sentBytes: 3, output: nil))
    #expect(!String(decoding: delivered, as: UTF8.self).contains("inputError"))
    #expect(try JSONDecoder().decode(SpawnProcessResult.self, from: delivered).inputError == nil)
    let failed = try JSONEncoder().encode(SpawnProcessResult(process: process, sentBytes: 0, output: nil, inputError: refusal))
    #expect(try JSONDecoder().decode(SpawnProcessResult.self, from: failed).inputError == refusal)
}

@Test func controlToolLayerSendsAnAgentMessageAsItsThreeRequests() async {
    let agent = controlToolLayerProcess()
    let output = TerminalOutputResult(terminalID: agent.id, startLine: 0, endLineExclusive: 1, totalLines: 1, lines: ["done"])
    let recorder = ControlToolLayerRecorder { request in
        switch request {
        case .getProcessStatus:
            return CherryControlResponse(result: .getProcessStatus(ProcessStatusResult(process: agent)))
        case .sendProcessInput:
            return CherryControlResponse(result: .sendProcessInput(SendProcessInputResult(processID: agent.id, sentBytes: 6, output: nil)))
        default:
            return CherryControlResponse(result: .waitForProcessIdle(WaitForProcessIdleResult(
                process: agent,
                reason: .idle,
                observedNewOutput: true,
                sinceOutputVersion: 0,
                outputVersion: 1,
                lastOutputAt: nil,
                output: output
            )))
        }
    }
    let result = await CherryToolLayer.call(
        name: "send_agent_message",
        arguments: ["message": .string("Review it"), "timeout_ms": .int(3_000)],
        caller: CherryToolCaller(boundProcessID: controlToolLayerAgentID),
        transport: recorder
    )
    #expect(!result.isError, "\(result.text)")
    #expect(recorder.requests == [
        .getProcessStatus(.init(processID: controlToolLayerAgentID, processName: nil)),
        .sendProcessInput(.init(processID: controlToolLayerAgentID, text: "Review it", submit: true)),
        .waitForProcessIdle(.init(processID: controlToolLayerAgentID, requireNewOutput: true, timeoutMilliseconds: 3_000)),
    ])
    #expect(recorder.timeouts == [20, 20, 20])
    #expect(result.structured?.objectValue?["sentBytes"] == .int(6))
    #expect(result.text.contains(#""sent_bytes":6"#))

    // Not an agent: refused after the lookup, nothing typed.
    let terminal = controlToolLayerProcess(kind: "terminal")
    let lookup = ControlToolLayerRecorder { _ in CherryControlResponse(result: .getProcessStatus(ProcessStatusResult(process: terminal))) }
    let refused = await CherryToolLayer.call(name: "send_agent_message", arguments: ["message": .string("hi")], caller: CherryToolCaller(boundProcessID: controlToolLayerAgentID), transport: lookup)
    #expect(refused.isError)
    #expect(refused.text.contains("not_agent_process"))
    #expect(lookup.requests.count == 1)
}

@Test func controlToolLayerWhoamiNamesTheCallerAndItsScope() async {
    let recorder = ControlToolLayerRecorder { request in
        if case .listProjects = request {
            return CherryControlResponse(result: .listProjects(ListProjectsResult(activeProjectRoot: "/elsewhere", projects: [])))
        }
        return CherryControlResponse(result: .getProjectStatus(ProjectStatusResult(
            projectRoot: "/work/app",
            processCounts: ProcessCounts(total: 1, terminals: 0, agents: 1, commands: 0),
            todoCount: nil,
            selectedProcessID: controlToolLayerOtherID,
            selectedProcessName: "Claude",
            health: "ok"
        )))
    }
    let result = await CherryToolLayer.call(
        name: "whoami",
        arguments: [:],
        caller: CherryToolCaller(processID: controlToolLayerAgentID, boundProcessID: controlToolLayerOtherID, projectRoot: "/work/app"),
        transport: recorder
    )
    #expect(recorder.requests == [.listProjects, .scoped(.init(projectRoot: "/work/app", request: .getProjectStatus))])
    #expect(result.text == #"{"active_project_root":"\/elsewhere","bound_process_id":"\#(controlToolLayerOtherID)","caller_process_id":"\#(controlToolLayerAgentID)","effective_project_root":"\/work\/app","selected_process_id":"\#(controlToolLayerOtherID)","selected_process_name":"Claude"}"#)
    #expect(result.structured?.objectValue?["callerProcessID"] == .string(controlToolLayerAgentID))
}

@Test func controlToolLayerStatusNamesTheTransportsSocket() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ControlToolLayer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketPath = directory.appendingPathComponent("control.sock").path
    try Data().write(to: URL(fileURLWithPath: socketPath))

    let reachable = ControlToolLayerRecorder(socketPath: socketPath) { _ in
        CherryControlResponse(result: .listTerminals(ListTerminalsResult(terminals: [], selectedTerminalID: nil)))
    }
    let status = await CherryToolLayer.call(name: "get_status", arguments: [:], caller: CherryToolCaller(), transport: reachable)
    #expect(status.text == #"{"cherry_reachable":true,"socket_exists":true,"socket_path":"\#(socketPath.replacingOccurrences(of: "/", with: #"\/"#))","terminal_count":0}"#)

    // An unreachable Cherry is a status too, not the tool's error.
    let unreachable = ControlToolLayerRecorder(socketPath: directory.appendingPathComponent("gone.sock").path) { _ in
        CherryControlResponse(error: CherryControlError(code: "cherry_unavailable", message: "Could not connect."))
    }
    let down = await CherryToolLayer.call(name: "get_status", arguments: [:], caller: CherryToolCaller(), transport: unreachable)
    #expect(!down.isError)
    #expect(down.structured?.objectValue?["socketExists"] == .bool(false))
    #expect(down.structured?.objectValue?["cherryReachable"] == .bool(false))
    #expect(down.structured?.objectValue?["error"]?.objectValue?["code"] == .string("cherry_unavailable"))

    // A transport without a socket of its own says nothing of one.
    let inProcess = ControlToolLayerRecorder { _ in
        CherryControlResponse(result: .listTerminals(ListTerminalsResult(terminals: [], selectedTerminalID: nil)))
    }
    let own = await CherryToolLayer.call(name: "get_status", arguments: [:], caller: CherryToolCaller(), transport: inProcess)
    #expect(own.text == #"{"cherry_reachable":true,"terminal_count":0}"#)
}

@Test func controlToolLayerInfersTheCallerFromTheNearestAncestorCherryRuns() async {
    let recorder = ControlToolLayerRecorder { _ in
        CherryControlResponse(result: .listProcesses(ListProcessesResult(
            activeProjectRoot: "/work/app",
            processes: [
                controlToolLayerProcess(id: controlToolLayerOtherID, kind: "terminal", pid: 300),
                controlToolLayerProcess(id: controlToolLayerAgentID, pid: 200),
            ],
            selectedProcessID: nil
        )))
    }
    let caller = CherryToolCaller(projectRoot: "/work/app")
    let inferred = await CherryToolLayer.inferredCallerProcessID(parentPIDs: [0, 100, 200, 300], caller: caller, transport: recorder)
    #expect(inferred == controlToolLayerAgentID)
    #expect(recorder.requests == [.scoped(.init(projectRoot: "/work/app", request: .listProcesses(.init(kind: nil))))])
    #expect(recorder.timeouts == [2])

    #expect(await CherryToolLayer.inferredCallerProcessID(parentPIDs: [100], caller: caller, transport: recorder) == nil)
    // No ancestors: nothing to ask.
    let idle = ControlToolLayerRecorder()
    #expect(await CherryToolLayer.inferredCallerProcessID(parentPIDs: [0, -1], caller: caller, transport: idle) == nil)
    #expect(idle.requests.isEmpty)
}

// MARK: - CherryMCP's adapter

@Test func controlToolLayerAdapterTimesOutAsTheLayerReadsItsArguments() throws {
    // A whole number kept as a double counts, as the layer reads it.
    #expect(CherryToolLayer.clientTimeout(for: "send_process_input", arguments: ["wait_ms": .double(2_000.0)]) == 22)
    #expect(CherryToolLayer.clientTimeout(for: "spawn_process", arguments: ["kind": .string(" Command "), "wait_ms": .int(1_000)]) == 31)
    #expect(CherryToolLayer.clientTimeout(for: "wait_for_events", arguments: ["timeout_ms": .double(1.5)]) == 55)
    #expect(try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": .string(#"{"type":"object"}"#)])
        == .object(["type": .string("object")]))
    #expect(throws: CherryControlError.self) {
        try CherryToolLayer.schemaArgument("result_schema", in: ["result_schema": .string("[1]")])
    }
}

// MARK: - The socket

@MainActor
@Test func controlToolLayerRunsOverTheSocketOffTheCooperativePool() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()
    let transport = SocketToolTransport(socketURL: harness.socketURL, credentials: nil, controlMachine: nil)
    #expect(transport.socketPath == harness.socketURL.path)

    let caller = CherryToolCaller(projectRoot: harness.projectRoot.path)
    let projects = await CherryToolLayer.call(name: "list_projects", arguments: [:], caller: caller, transport: transport)
    #expect(!projects.isError, "\(projects.text)")
    let roots = projects.structured?.objectValue?["projects"]?.arrayValue?.compactMap { $0.objectValue?["root"]?.stringValue } ?? []
    #expect(roots.map(CherryControl.standardizedProjectRoot).contains(CherryControl.standardizedProjectRoot(harness.projectRoot.path)), "\(projects.text)")

    let status = await CherryToolLayer.call(name: "get_status", arguments: [:], caller: caller, transport: transport)
    #expect(status.structured?.objectValue?["socketPath"] == .string(harness.socketURL.path))
    #expect(status.structured?.objectValue?["socketExists"] == .bool(true))
    #expect(status.structured?.objectValue?["cherryReachable"] == .bool(true))

    // Several calls at once, each blocking a thread of the transport's own.
    let results = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<16 {
            group.addTask {
                await !CherryToolLayer.call(name: "get_project_status", arguments: [:], caller: caller, transport: transport).isError
            }
        }
        var answered: [Bool] = []
        for await ok in group {
            answered.append(ok)
        }
        return answered
    }
    #expect(results.count == 16)
    #expect(results.allSatisfy { $0 })

    // No app: the client's error.
    let missing = SocketToolTransport(
        socketURL: harness.socketURL.deletingLastPathComponent().appendingPathComponent("missing.sock"),
        credentials: nil,
        controlMachine: nil
    )
    await #expect(throws: CherryControlError.self) {
        _ = try await missing.send(.listProjects, timeout: 1)
    }
    let unavailable = await CherryToolLayer.call(name: "list_projects", arguments: [:], caller: CherryToolCaller(), transport: missing)
    #expect(unavailable.isError)
    #expect(unavailable.structured?.objectValue?["error"]?.objectValue?["code"] == .string("cherry_unavailable"))
}

/// answer_prompt: its choice as an option's number (a JSON number too) or
/// label, sent as one typed request; no choice is refused before anything
/// is sent. The prompt of a refusal comes through in its error.
@Test func controlToolLayerAnswerPromptSendsTheChoice() async throws {
    let id = controlToolLayerAgentID
    #expect(await controlToolLayerRequest("answer_prompt", ["process_id": .string(id), "choice": .string("Yes")])
        == .answerPrompt(.init(processID: id, choice: "Yes")))
    #expect(await controlToolLayerRequest("answer_prompt", ["process_id": .string(id), "choice": .int(2)])
        == .answerPrompt(.init(processID: id, choice: "2")))
    #expect(await controlToolLayerRequest("answer_prompt", ["process_id": .string(id), "choice": .double(3)])
        == .answerPrompt(.init(processID: id, choice: "3")))
    let missing = await controlToolLayerRefusal("answer_prompt", ["process_id": .string(id)])
    #expect(missing.code != nil)
    #expect(!missing.sentRequests)

    let prompt = AgentPromptInfo(kind: "permission", question: "Do you want to proceed?", options: [
        AgentPromptOption(number: 1, label: "Yes", selected: true),
        AgentPromptOption(number: 2, label: "No", selected: false),
    ])
    let recorder = ControlToolLayerRecorder { _ in
        CherryControlResponse(error: CherryControlError(code: "unknown_choice", message: "No such option.", prompt: prompt))
    }
    let result = await CherryToolLayer.call(
        name: "answer_prompt", arguments: ["process_id": .string(id), "choice": .string("maybe")],
        caller: CherryToolCaller(), transport: recorder
    )
    #expect(result.isError)
    let error = try #require(result.structured?.objectValue?["error"]?.objectValue)
    #expect(error["prompt"]?.objectValue?["options"]?.arrayValue?.count == 2)
    #expect(result.text.contains(#""question":"Do you want to proceed?""#))
}
