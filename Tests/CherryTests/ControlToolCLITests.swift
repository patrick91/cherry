@testable import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// `cherry`'s agent commands (`CherryCLI`, run in the app for a `runCommand`;
// docs/specs/agent-cli.md): each command's words become one catalog tool's
// call, its output JSON or a short human form, and the built Rust `cherry`
// runs them end to end against a private control socket.

private func cliCall(_ arguments: [String], input: CherryCLIInput = .none) -> (tool: String, arguments: [String: JSONValue], fallback: CherryCLIFallback?)? {
    guard case .call(let tool, let arguments, let fallback) = CherryCLI.parse(arguments, input: input).action else { return nil }
    return (tool, arguments, fallback)
}

private func cliUsage(_ arguments: [String], input: CherryCLIInput = .none) -> String? {
    guard case .usage(let message) = CherryCLI.parse(arguments, input: input).action else { return nil }
    return message
}

private func cliPiped(_ text: String) -> CherryCLIInput {
    CherryCLIInput(hasPipedInput: true, read: { text }, readFile: { _ in nil })
}

private let cliTab = "3F2A0B4C-1D2E-4F50-8A6B-7C8D9E0F1A2B"

// MARK: - Commands

/// Every command's tool is in the catalog, and every catalog tool is one
/// command's or reachable with `cherry tool`.
@Test func ControlToolCLIEveryCommandNamesACatalogTool() {
    let catalog = Set(CherryToolCatalog.tools(for: .unknown).map(\.name))
    for command in CherryCLI.commands where command.words != ["tool"] {
        #expect(catalog.contains(command.tool), "\(command.words) names \(command.tool)")
        #expect(command.usage.hasPrefix("cherry " + command.words.joined(separator: " ")), "\(command.usage)")
    }
    let commanded = Set(CherryCLI.commands.map(\.tool))
    let onlyThroughTool = catalog.subtracting(commanded)
    // Tools an agent has no use for as a command of its own.
    #expect(onlyThroughTool == [
        "get_status", "get_process_raw_output", "bind_session_process", "update_todo_comment", "delete_todo_comment",
    ], "\(onlyThroughTool.sorted())")
}

/// Each command, as an agent types it, and the call it makes.
@Test func ControlToolCLICommandsMakeTheirToolsCalls() throws {
    let cases: [([String], String, [String: JSONValue])] = [
        (["ls"], "list_processes", [:]),
        (["ls", "--kind", "agent"], "list_processes", ["kind": .string("agent")]),
        (["show"], "get_process_status", [:]),
        (["show", "Claude"], "get_process_status", ["process_name": .string("Claude")]),
        (["show", cliTab.lowercased()], "get_process_status", ["process_id": .string(cliTab)]),
        (["read", cliTab, "--lines", "40", "--from", "10"], "get_process_output",
         ["process_id": .string(cliTab), "line_limit": .int(40), "start_line": .int(10)]),
        (["read", "--line-limit=5"], "get_process_output", ["line_limit": .int(5)]),
        (["search", "dev", "listening on"], "search_process_output", ["process_name": .string("dev"), "query": .string("listening on")]),
        (["wait", cliTab, "--timeout", "30000"], "wait_for_process_idle", ["process_id": .string(cliTab), "timeout_ms": .int(30_000)]),
        (["send", cliTab, "hello", "--no-wait"], "send_agent_message",
         ["process_id": .string(cliTab), "message": .string("hello"), "wait_for_idle": .bool(false)]),
        (["answer", cliTab, "2"], "answer_prompt", ["process_id": .string(cliTab), "choice": .string("2")]),
        (["spawn", "agent", "claude", "--task", "Fix it", "--label", "Fix", "--phase", "impl", "--run", "run-1", "--allow-subagents"],
         "spawn_agent", ["name": .string("claude"), "task": .string("Fix it"), "label": .string("Fix"), "phase": .string("impl"),
                         "run_id": .string("run-1"), "allow_subagents": .bool(true)]),
        (["spawn", "agent", "claude", "--task", "Add logout", "--project-root", "/Users/me/auth"], "spawn_agent",
         ["name": .string("claude"), "task": .string("Add logout"), "project_root": .string("/Users/me/auth")]),
        (["spawn", "agent", "claude", "--schema", #"{"type":"object"}"#], "spawn_agent",
         ["name": .string("claude"), "result_schema": .object(["type": .string("object")])]),
        (["spawn", "terminal", "npm test"], "spawn_process", ["kind": .string("terminal"), "text": .string("npm test")]),
        (["spawn", "command", "dev"], "spawn_process", ["kind": .string("command"), "name": .string("dev")]),
        (["start", cliTab], "start_process", ["process_id": .string(cliTab)]),
        (["stop"], "stop_process", [:]),
        (["restart", "dev"], "restart_process", ["process_name": .string("dev")]),
        (["close", cliTab, "--policy", "close_sub_agents"], "close_process",
         ["process_id": .string(cliTab), "agent_close_policy": .string("close_sub_agents")]),
        (["rename", cliTab, "Reviewer"], "rename_process", ["process_id": .string(cliTab), "title": .string("Reviewer")]),
        (["select", "dev"], "select_process", ["process_name": .string("dev")]),
        (["task", "mine"], "get_my_task", [:]),
        (["task", "progress", "Plan ready, OK?", "--awaiting-approval"], "report_progress",
         ["message": .string("Plan ready, OK?"), "awaiting_approval": .bool(true)]),
        // A switch before the text takes only true or false as its value.
        (["task", "progress", "--awaiting-approval", "Plan ready, OK?"], "report_progress",
         ["message": .string("Plan ready, OK?"), "awaiting_approval": .bool(true)]),
        (["task", "progress", "--awaiting-approval", "false", "Halfway"], "report_progress",
         ["message": .string("Halfway"), "awaiting_approval": .bool(false)]),
        (["task", "cancel", "--close", "task-1"], "cancel_tasks",
         ["task_ids": .array([.string("task-1")]), "close": .bool(true)]),
        (["task", "get", "task-1"], "get_task", ["task_id": .string("task-1")]),
        (["task", "list", "--run", "run-1", "--state", "reported"], "list_tasks", ["run_id": .string("run-1"), "state": .string("reported")]),
        (["task", "wait", "run-1", "--cursor", "4", "--until", "all"], "wait_for_tasks",
         ["run_id": .string("run-1"), "cursor": .int(4), "until": .string("all")]),
        (["task", "cancel", "task-1", "task-2", "--close"], "cancel_tasks",
         ["task_ids": .array([.string("task-1"), .string("task-2")]), "close": .bool(true)]),
        (["subscribe", cliTab, "--wake", "--events", "done,needs_input"], "subscribe",
         ["process_ids": .array([.string(cliTab)]), "wake": .bool(true), "events": .array([.string("done"), .string("needs_input")])]),
        (["subscribe", "--sub-agents", "--pattern", "error"], "subscribe", ["sub_agents": .bool(true), "output_pattern": .string("error")]),
        (["events", "sub-1", "--cursor", "2", "--timeout", "0"], "wait_for_events",
         ["subscription_id": .string("sub-1"), "cursor": .int(2), "timeout_ms": .int(0)]),
        (["unsubscribe", "sub-1"], "unsubscribe", ["subscription_id": .string("sub-1")]),
        (["subscriptions"], "list_subscriptions", [:]),
        (["ports", "dev"], "get_process_ports", ["process_name": .string("dev")]),
        (["services"], "services_list", [:]),
        (["wait-port", "dev", "--port", "3000", "--probe-http"], "wait_for_bound_port",
         ["process_name": .string("dev"), "port": .int(3_000), "probe_http": .bool(true)]),
        (["todo", "ls"], "list_todos", [:]),
        (["todo", "show", "t1"], "get_todo", ["todo_id": .string("t1")]),
        (["todo", "add", "Ship it", "Details", "--tags", "a,b"], "create_todo",
         ["title": .string("Ship it"), "markdown": .string("Details"), "tags": .array([.string("a"), .string("b")])]),
        (["todo", "edit", "t1", "--status", "done"], "update_todo", ["todo_id": .string("t1"), "status": .string("done")]),
        (["todo", "move", "t1", "doing", "--after", "t0"], "move_todo",
         ["todo_id": .string("t1"), "status": .string("doing"), "after_todo_id": .string("t0")]),
        (["todo", "rm", "t1"], "delete_todo", ["todo_id": .string("t1")]),
        (["todo", "select", "t1"], "select_todo", ["todo_id": .string("t1")]),
        (["todo", "comment", "t1", "Looks good"], "add_todo_comment", ["todo_id": .string("t1"), "markdown": .string("Looks good")]),
        (["todo", "comments", "t1"], "list_todo_comments", ["todo_id": .string("t1")]),
        (["project", "ls"], "list_projects", [:]),
        (["project", "open", "/Users/someone/app"], "open_project", ["project_root": .string("/Users/someone/app")]),
        (["project", "open", "~/app", "--device", "patmini"], "open_project",
         ["project_root": .string("~/app"), "device": .string("patmini")]),
        (["project", "add", "~/code/app", "--device", "patmini", "--create"], "add_project",
         ["path": .string("~/code/app"), "device": .string("patmini"), "create": .bool(true)]),
        (["project", "add", "/Users/someone/app", "--open", "false"], "add_project",
         ["path": .string("/Users/someone/app"), "open": .bool(false)]),
        (["project", "add", "/Users/someone/app", "--no-open"], "add_project",
         ["path": .string("/Users/someone/app"), "open": .bool(false)]),
        (["devices"], "list_devices", [:]),
        (["spawn", "agent", "claude", "--device", "patmini", "--project-root", "~/app"], "spawn_agent",
         ["name": .string("claude"), "device": .string("patmini"), "project_root": .string("~/app")]),
        (["spawn", "terminal", "df -h", "--device", "patmini", "--project-root", "~/app"], "spawn_process",
         ["kind": .string("terminal"), "text": .string("df -h"), "device": .string("patmini"), "project_root": .string("~/app")]),
        (["spawn", "command", "server", "--device", "patmini", "--project-root", "~/app"], "spawn_process",
         ["kind": .string("command"), "name": .string("server"), "device": .string("patmini"), "project_root": .string("~/app")]),
        (["project", "show"], "get_project_status", [:]),
        (["commands", "start"], "start_all_commands", [:]),
        (["commands", "stop"], "stop_all_commands", [:]),
        (["commands", "restart"], "restart_all_commands", [:]),
        (["agents"], "list_agents", [:]),
        (["link", "cherry://project/x"], "resolve_link", ["link": .string("cherry://project/x")]),
        (["whoami"], "whoami", [:]),
        (["tool", "get_process_raw_output", #"{"max_bytes":100}"#], "get_process_raw_output", ["max_bytes": .int(100)]),
        (["tool", "get_status"], "get_status", [:]),
    ]
    for (words, tool, arguments) in cases {
        let call = try #require(cliCall(words), "\(words): \(String(describing: CherryCLI.parse(words).action))")
        #expect(call.tool == tool, "\(words)")
        #expect(call.arguments == arguments, "\(words)")
    }
}

/// `--json` anywhere forces JSON; a command's words are kept for its
/// human output.
@Test func ControlToolCLIJSONFlagAndCommandWords() {
    let invocation = CherryCLI.parse(["task", "--json", "list"])
    #expect(invocation.json)
    #expect(invocation.command == ["task", "list"])
    #expect(!CherryCLI.parse(["ls"]).json)
}

/// `cherry send` to a tab that is not an agent types the text as a line
/// instead (the app refuses `send_agent_message` before sending anything).
@Test func ControlToolCLISendFallsBackToTypingALine() throws {
    let call = try #require(cliCall(["send", "dev", "make test", "--line-limit", "5"]))
    #expect(call.fallback == CherryCLIFallback(tool: "send_process_input", arguments: [
        "process_name": .string("dev"), "text": .string("make test"), "submit": .bool(true), "line_limit": .int(5),
    ]))
}

// MARK: - Standard input

/// Long text on standard input: `-`, or nothing with a pipe; several
/// lines stay one argument.
@Test func ControlToolCLIStandardInputCarriesLongText() throws {
    let message = "Review these:\n1. first\n2. second\n"
    #expect(cliCall(["send", cliTab, "-"], input: cliPiped(message))?.arguments["message"] == .string(message))
    #expect(cliCall(["send", cliTab], input: cliPiped(message))?.arguments["message"] == .string(message))
    #expect(cliCall(["spawn", "agent", "codex", "--task", "-"], input: cliPiped("The brief"))?.arguments["task"] == .string("The brief"))
    #expect(cliCall(["spawn", "agent", "codex", "--schema", "-"], input: cliPiped(#"{"type":"object"}"#))?.arguments["result_schema"]
        == .object(["type": .string("object")]))
    #expect(cliCall(["todo", "comment", "t1"], input: cliPiped("Done"))?.arguments["markdown"] == .string("Done"))
    #expect(cliCall(["tool", "list_processes", "-"], input: cliPiped(#"{"kind":"agent"}"#))?.arguments == ["kind": .string("agent")])
    // No pipe: a missing message is a usage error, never a wait on a terminal.
    #expect(cliUsage(["send", cliTab])?.contains("Missing") == true)
    // A file argument for a schema.
    let files = CherryCLIInput(hasPipedInput: false, read: { nil }, readFile: { $0 == "schema.json" ? "[1]" : nil })
    #expect(cliCall(["spawn", "agent", "claude", "--schema", "schema.json"], input: files)?.arguments["result_schema"] == nil)
    #expect(cliUsage(["spawn", "agent", "claude", "--schema", "schema.json"], input: files)?.contains("JSON object") == true)
    let objectFile = CherryCLIInput(hasPipedInput: false, read: { nil }, readFile: { _ in #"{"type":"object"}"# })
    #expect(cliCall(["spawn", "agent", "claude", "--schema", "schema.json"], input: objectFile)?.arguments["result_schema"]
        == .object(["type": .string("object")]))
}

/// `cherry task report`: a whole report (value, status, summary), or the
/// value with `--status` and `--summary`.
@Test func ControlToolCLITaskReportTakesAReportOrAValue() throws {
    let whole = #"{"value":{"ok":true},"status":"ok","summary":"Done."}"#
    #expect(cliCall(["task", "report"], input: cliPiped(whole))?.arguments == [
        "value": .object(["ok": .bool(true)]), "status": .string("ok"), "summary": .string("Done."),
    ])
    #expect(cliCall(["task", "report", #"{"files":3}"#, "--status", "failed", "--summary", "No tests"])?.arguments == [
        "value": .object(["files": .int(3)]), "status": .string("failed"), "summary": .string("No tests"),
    ])
    // A value that happens to have a "value" key, with flags: it is the value.
    #expect(cliCall(["task", "report", "--summary", "s"], input: cliPiped(#"{"value":1}"#))?.arguments == [
        "value": .object(["value": .int(1)]), "summary": .string("s"),
    ])
    #expect(cliUsage(["task", "report", "not json"])?.contains("not JSON") == true)
    #expect(cliUsage(["task", "report"])?.contains("Missing the report") == true)
}

// MARK: - Keys

@Test func ControlToolCLIKeysAreTheirBytes() throws {
    let call = try #require(cliCall(["keys", cliTab, "down", "down", "enter", "ctrl-c", "esc", "y", "shift-tab"]))
    #expect(call.tool == "send_process_input")
    #expect(call.arguments["submit"] == .bool(false))
    let bytes = try #require(call.arguments["raw_base64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    #expect(bytes == Data("\u{1B}[B\u{1B}[B\r\u{03}\u{1B}y\u{1B}[Z".utf8))
    #expect(CherryCLI.keyBytes("ctrl-a") == Data([0x01]))
    #expect(CherryCLI.keyBytes("CTRL-Z") == Data([0x1A]))
    #expect(CherryCLI.keyBytes("ctrl-[") == Data([0x1B]))
    #expect(CherryCLI.keyBytes("ctrl-1") == nil)
    #expect(CherryCLI.keyBytes("hello") == nil)
    #expect(cliUsage(["keys", cliTab, "hello"])?.contains("cherry send") == true)
    #expect(cliUsage(["keys", cliTab])?.contains("Which keys") == true)
}

// MARK: - Usage

@Test func ControlToolCLIUsageErrorsSayWhatIsWrong() {
    #expect(cliUsage(["bogus"])?.contains("unknown command") == true)
    #expect(cliUsage(["task"])?.contains("cherry task needs one of") == true)
    #expect(cliUsage(["search", "dev"])?.contains("Missing QUERY") == true)
    #expect(cliUsage(["ls", "--colour"])?.contains("Unknown option --colour") == true)
    #expect(cliUsage(["read", "--lines", "many"])?.contains("whole number") == true)
    #expect(cliUsage(["ls", "extra"])?.contains("Unexpected argument") == true)
    #expect(cliUsage(["tool", "list_processes", "[1]"])?.contains("not a JSON object") == true)
    #expect(cliUsage(["skill", "setup", "--agent", "gemini"])?.contains("unknown agent") == true)
    #expect(cliUsage(["skill", "remove", "--force"])?.contains("--force is for cherry skill setup") == true)
    #expect(cliUsage(["skill", "status", "--everything"])?.contains("unknown option") == true)
    #expect(cliUsage(["skill", "setup", "--agent"])?.contains("--agent needs a name") == true)
    guard case .print(let help) = CherryCLI.parse(["help"]).action else {
        Issue.record("help prints")
        return
    }
    #expect(help.contains("cherry send ID") && help.contains("cherry task report"))
    guard case .print(let taskHelp) = CherryCLI.parse(["task", "report", "--help"]).action else {
        Issue.record("--help prints")
        return
    }
    #expect(taskHelp.contains("cherry task report") && !taskHelp.contains("cherry ls"))
}

// MARK: - The guide

@Test func ControlToolCLIGuideAndSkill() throws {
    let guide = CherryCLIGuide.guide
    #expect(guide.utf8.count < 6_500, "\(guide.utf8.count) bytes")
    for fact in [
        "cherry task report", "--awaiting-approval", "cherry answer", "<<'EOF'", "cherry task cancel TASK --close", "never your\nCLI's own subagents",
        "cherry devices", "cherry project add ~/app --device NAME", "--device NAME --project-root", "cherry spawn terminal CMD --device NAME",
    ] {
        #expect(guide.contains(fact), "\(fact)")
    }
    guard case .print(let skill) = CherryCLI.parse(["skill", "show", "--skill-md"]).action else {
        Issue.record("skill show --skill-md prints")
        return
    }
    #expect(skill == CherryCLIGuide.skillMarkdown)
    let lines = skill.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.first == "---")
    let frontmatter = lines.dropFirst().prefix { $0 != "---" }
    #expect(frontmatter.contains("name: cherry"))
    let description = try #require(frontmatter.first { $0.hasPrefix("description: ") })
    // Quoted: a plain YAML scalar may not hold ": ".
    #expect(description.hasPrefix("description: \"") && description.hasSuffix("\""))
    #expect(skill.contains("cherry skill show"))
}

// MARK: - Output

private func cliResult(_ text: String, isError: Bool = false) -> CallToolResult {
    CallToolResult(text: text, isError: isError, structured: nil)
}

@Test func ControlToolCLIOutputIsJSONOffATerminalAndShortOnOne() async {
    let list = #"{"processes":[{"id":"\#(cliTab)","kind":"agent","name":"Claude","state":"live","agent_activity_state":"idle"}]}"#
    let invocation = CherryCLI.parse(["ls"])
    let piped = await CherryCLIRunner.run(invocation, isTerminal: false) { _, _ in cliResult(list) }
    #expect(piped == .init(standardOutput: list + "\n", standardError: "", exitCode: 0))
    let terminal = await CherryCLIRunner.run(invocation, isTerminal: true) { _, _ in cliResult(list) }
    #expect(terminal.standardOutput.hasPrefix("ID"))
    #expect(terminal.standardOutput.contains(cliTab) && terminal.standardOutput.contains("Claude"))
    let forced = await CherryCLIRunner.run(CherryCLI.parse(["ls", "--json"]), isTerminal: true) { _, _ in cliResult(list) }
    #expect(forced.standardOutput == list + "\n")

    let output = #"{"lines":["one","two"],"total_lines":2}"#
    let read = await CherryCLIRunner.run(CherryCLI.parse(["read"]), isTerminal: true) { _, _ in cliResult(output) }
    #expect(read.standardOutput == "one\ntwo\n")
}

@Test func ControlToolCLIToolErrorsExitOneWithTheirCode() async {
    let refused = #"{"error":{"code":"agent_awaiting_permission","message":"Claude asks for permission.","prompt":{"options":[{"label":"Yes","number":1}]}}}"#
    let outcome = await CherryCLIRunner.run(CherryCLI.parse(["send", cliTab, "hi"]), isTerminal: false) { _, _ in
        cliResult(refused, isError: true)
    }
    #expect(outcome.exitCode == 1)
    #expect(outcome.standardOutput.isEmpty)
    #expect(outcome.standardError.hasPrefix("agent_awaiting_permission: Claude asks for permission.\n"))
    #expect(outcome.standardError.contains(#""label":"Yes""#))

    let usage = await CherryCLIRunner.run(CherryCLI.parse(["bogus"]), isTerminal: false) { _, _ in cliResult("{}") }
    #expect(usage.exitCode == 2 && usage.standardError.contains("unknown command"))
}

@Test func ControlToolCLISendToATerminalTypesALine() async {
    let calls = CLICallLog()
    let outcome = await CherryCLIRunner.run(CherryCLI.parse(["send", "dev", "make test"]), isTerminal: false) { tool, arguments in
        await calls.append(tool, arguments)
        if tool == "send_agent_message" {
            return cliResult(#"{"error":{"code":"not_agent_process","message":"dev is a command."}}"#, isError: true)
        }
        return cliResult(#"{"sent_bytes":10}"#)
    }
    #expect(outcome.exitCode == 0 && outcome.standardOutput == "{\"sent_bytes\":10}\n")
    #expect(await calls.tools == ["send_agent_message", "send_process_input"])
}

private actor CLICallLog {
    private(set) var tools: [String] = []
    func append(_ tool: String, _ arguments: [String: JSONValue]) { tools.append(tool) }
}

// MARK: - runCommand

/// `request` answered by `server` as This Mac's caller with no tab.
@MainActor
private func runCommand(_ request: RunCommandRequest, on server: CherryControlServer) async throws -> RunCommandResult {
    let data = try JSONEncoder().encode(CherryControlRequest.runCommand(request))
    let response = await server.handleRequestData(data, peerPID: nil)
    guard case .runCommand(let result)? = response.result else {
        throw CherryControlError(code: "unexpected_response", message: "\(response)")
    }
    return result
}

/// The app parses a command; what only the caller's Mac has (standard
/// input, a file) it asks for, and nothing runs until the command comes
/// back with it.
@MainActor
@Test func ControlToolCLIRunCommandAsksForStandardInputAndFiles() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    var sent: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { sent.append($0) }

    let piped = RunCommandRequest(arguments: ["todo", "add", "Ship it"], standardInputIsPiped: true)
    let asked = try await runCommand(piped, on: harness.server)
    #expect(asked == RunCommandResult(needsStandardInput: true))
    #expect(sent.isEmpty)
    var answered = piped
    answered.standardInput = "The *notes*."
    _ = try await runCommand(answered, on: harness.server)
    // Sent once, with the text (the harness's project has todos off, which
    // the tool then says).
    #expect(sent.count == 1)
    guard case .createTodo(let todo)? = sent.first else {
        Issue.record("Expected createTodo, got \(sent)")
        return
    }
    #expect(todo.title == "Ship it" && todo.markdown == "The *notes*.")

    // A file named for an object parameter.
    let report = RunCommandRequest(arguments: ["task", "report", "--value", "result.json", "--status", "ok"])
    let wantsFile = try await runCommand(report, on: harness.server)
    #expect(wantsFile == RunCommandResult(needsFiles: ["result.json"]))
    var withFile = report
    withFile.files = [.init(path: "result.json", contents: #"{"word":"alpha"}"#)]
    let reported = try await runCommand(withFile, on: harness.server)
    // No task: the tool's own refusal, after the file was read.
    #expect(reported.exitCode == 1)
    #expect(reported.standardError.hasPrefix("no_assignment:"), "\(reported.standardError)")
    var unreadable = report
    unreadable.files = [.init(path: "result.json", contents: nil)]
    let refused = try await runCommand(unreadable, on: harness.server)
    #expect(refused.exitCode == 2 && refused.standardError.contains("neither JSON nor a readable file"), "\(refused.standardError)")

    // Usage, help and the guide need nothing.
    #expect(try await runCommand(.init(arguments: ["bogus"]), on: harness.server).exitCode == 2)
    #expect(try await runCommand(.init(arguments: ["skill", "show"]), on: harness.server).standardOutput == CherryCLIGuide.guide)
}

/// `get_status` names the builds that talk; `cherry skill status` reads
/// the caller's own folders (its HOME, not the app's).
@MainActor
@Test func ControlToolCLIRunCommandStatusAndTheCallersSkill() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    let status = try await runCommand(.init(arguments: ["tool", "get_status"], cliBuild: "dev-1.abc"), on: harness.server)
    #expect(status.exitCode == 0, "\(status.standardError)")
    let payload = try #require(try JSONValue.parse(Data(status.standardOutput.utf8)).objectValue)
    #expect(payload["cli_build"] == .string("dev-1.abc"))
    #expect(payload["app_control_protocol"] == .int(CherryControl.controlProtocolVersion))
    #expect(payload["app_build"]?.stringValue != nil)

    // The skill's files are the caller's: the app asks its `cherry` what
    // is at their paths (never looks at its own disk), and without HOME it
    // cannot place them.
    let home = harness.projectRoot.appendingPathComponent("home", isDirectory: true)
    let skill = try await runCommand(
        .init(arguments: ["skill", "status", "--agent", "claude"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]),
        on: harness.server
    )
    #expect(skill.needsPaths?.contains(home.appendingPathComponent(".claude/skills/cherry").path) == true, "\(skill)")
    #expect(skill.operations == nil && skill.standardOutput.isEmpty)
    let homeless = try await runCommand(.init(arguments: ["skill", "status"]), on: harness.server)
    #expect(homeless.exitCode == 1 && homeless.standardError.hasPrefix("skill_unavailable:"), "\(homeless)")
}

// MARK: - End to end

/// The Rust `cherry` against the app's control server: a multi-line message
/// from standard input to a terminal reaches it as one line, `cherry ls`
/// lists the tab, and the output is the tool's JSON (standard output is a
/// pipe).
@MainActor
@Test func ControlToolCLIBuiltCherryRunsCommandsEndToEnd() async throws {
    let cli = try builtCherryCLI()
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let terminal = harness.workspace.addSession(title: "dev")
    let home = harness.projectRoot.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let environment = [
        CherryControl.socketEnvironmentKey: harness.socketURL.path,
        CherryControl.projectRootEnvironmentKey: harness.projectRoot.path,
        "HOME": home.path,
        "PATH": "/usr/bin:/bin",
    ]

    let listed = try await runCherryCLI(cli, ["ls"], environment: environment)
    #expect(listed.status == 0, "\(listed.error)")
    #expect(listed.output.contains(terminal.id.uuidString), "\(listed.output)")

    var typed: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { typed.append($0) }
    let sent = try await runCherryCLI(cli, ["send", terminal.id.uuidString, "-"], environment: environment, input: "echo one\necho two\n")
    #expect(sent.status == 0, "\(sent.error)")
    #expect(sent.output.contains("sent_bytes"), "\(sent.output)")
    let input = typed.compactMap { request -> String? in
        guard case .scoped(let scoped) = request, case .sendProcessInput(let send) = scoped.request else { return nil }
        return send.text
    }
    #expect(input == ["echo one\necho two\n"])

    let unknown = try await runCherryCLI(cli, ["bogus"], environment: environment)
    #expect(unknown.status == 2 && unknown.error.contains("unknown command"), "\(unknown.error)")

    // The skill, set up, checked and removed on the Mac `cherry` runs on
    // (its HOME, not the app's), through the paths and steps the app asks.
    let skillFolder = home.appendingPathComponent(".claude/skills/cherry")
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let setup = try await runCherryCLI(cli, ["skill", "setup", "--agent", "claude", "--json"], environment: environment)
    #expect(setup.status == 0, "\(setup.output) \(setup.error)")
    #expect(setup.output.contains(#""change":"wrote""#), "\(setup.output)")
    #expect(try String(contentsOf: skillFolder.appendingPathComponent("SKILL.md"), encoding: .utf8) == CherrySkill.markdown + (CherrySkill.markdown.hasSuffix("\n") ? "" : "\n"))
    #expect(FileManager.default.fileExists(atPath: skillFolder.appendingPathComponent(CherrySkill.markerFileName).path))
    let status = try await runCherryCLI(cli, ["skill", "status", "--agent", "claude", "--json"], environment: environment)
    #expect(status.status == 0 && status.output.contains(#""status":"current""#), "\(status.output) \(status.error)")
    let removed = try await runCherryCLI(cli, ["skill", "remove", "--agent", "claude", "--json"], environment: environment)
    #expect(removed.status == 0 && removed.output.contains(#""change":"removed""#), "\(removed.output) \(removed.error)")
    #expect(!FileManager.default.fileExists(atPath: skillFolder.path))
}

/// `cherry devices` at a terminal: each machine, then its projects' paths.
@Test func ControlToolCLIDevicesPrintsEachMachineAndItsProjects() {
    let text = #"{"devices":[{"id":"this-mac","name":"This Mac","os":"macOS","caller":true,"projects":[{"root":"/Users/me/app","path":"/Users/me/app","open":true}]},{"id":"5b0e","name":"patmini","os":"macOS","caller":false,"projects":[]}]}"#
    #expect(CherryCLIRunner.render(text, command: ["devices"]) == """
    This Mac (this-mac): macOS, you are here
      /Users/me/app  (open)
    patmini (5b0e): macOS
    """)
}
