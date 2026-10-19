import CherryControl
@testable import CherryMCP
import Darwin
import Foundation
import Testing

// `cherry`'s agent commands (`CherryCLI`, `CherryMCP cli`;
// docs/specs/agent-cli.md): each command's words become one catalog tool's
// call, its output JSON or a short human form, and the built helper runs
// one end to end against a private control socket.

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
    #expect(cliUsage(["skill", "setup"])?.contains("not available yet") == true)
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
    for fact in ["cherry task report", "--awaiting-approval", "cherry answer", "<<'EOF'", "cherry task cancel TASK --close", "never your\nCLI's own subagents"] {
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

// MARK: - End to end

/// A control socket that answers `appInfo` and records each `callTool`,
/// answering it with `answer`.
private final class CLITestApp: @unchecked Sendable {
    let directory: URL
    let socketURL: URL
    private let listener: Int32
    private let answer: @Sendable (CallToolRequest) -> CallToolResult
    private let lock = NSLock()
    private var received: [CallToolRequest] = []
    private var isStopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(answer: @escaping @Sendable (CallToolRequest) -> CallToolResult) throws {
        self.answer = answer
        directory = URL(fileURLWithPath: "/tmp/cherry-cli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(chmod(directory.path, 0o700) == 0)
        socketURL = directory.appendingPathComponent("control.sock")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        let bound = UnixIO.withSocketAddress(path: socketURL.path) { Darwin.bind(listener, $0, $1) }
        try #require(bound == 0 && listen(listener, 16) == 0)
        Thread.detachNewThread { [self] in serve() }
    }

    var calls: [CallToolRequest] {
        lock.withLock { received }
    }

    func stop() {
        lock.withLock { isStopped = true }
        finished.wait()
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve() {
        while !lock.withLock({ isStopped }) {
            var poll = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 50) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            UnixIO.setNoSigPipe(connection)
            respond(on: connection)
            Darwin.close(connection)
        }
        Darwin.close(listener)
        finished.signal()
    }

    private func respond(on connection: Int32) {
        var line = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while line.last != 0x0A {
            let count = Darwin.read(connection, &bytes, bytes.count)
            guard count > 0 else { break }
            line.append(contentsOf: bytes.prefix(count))
        }
        guard let request = try? CherryControlEnvelope.decode(line.filter { $0 != 0x0A }).request else { return }
        let response: CherryControlResponse
        switch request {
        case .appInfo:
            response = .init(result: .appInfo(AppInfoResult(
                controlProtocol: 2, build: "20261019120000.abcdef0", version: "2026.10.19.1", bundleIdentifier: "dev.patrick.cherry", urlScheme: "cherry"
            )))
        case .callTool(let call):
            lock.withLock { received.append(call) }
            response = .init(result: .callTool(answer(call)))
        default:
            response = .init(error: .init(code: "unexpected", message: "\(request)"))
        }
        guard let encoded = try? JSONEncoder().encode(response) else { return }
        let reply = encoded + Data([0x0A])
        _ = reply.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, reply.count) }
    }
}

/// The built helper's `cli`: a multi-line message from standard input to a
/// tab that is a command reaches the app as one `send_agent_message`, then,
/// refused, as one `send_process_input` line; the app's answer is printed
/// as JSON (standard output is a pipe), interface "cli".
@Test func ControlToolCLIBuiltHelperRunsACommandEndToEnd() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = repository.appendingPathComponent(".build/debug/CherryMCP")
    try #require(FileManager.default.isExecutableFile(atPath: helper.path), "Build CherryMCP first: swift build --build-tests")
    let app = try CLITestApp { call in
        call.name == "send_agent_message"
            ? CallToolResult(text: #"{"error":{"code":"not_agent_process","message":"dev is a command."}}"#, isError: true, structured: nil)
            : CallToolResult(text: #"{"sent_bytes":12}"#, isError: false, structured: nil)
    }
    defer { app.stop() }
    let home = app.directory.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let tab = UUID().uuidString

    let message = "line one\nline two\n"
    let run = try await Task.detached { () -> (Int32, String, String) in
        let process = Process()
        process.executableURL = helper
        process.arguments = ["cli", "send", "dev", "-"]
        process.environment = [
            CherryControl.socketEnvironmentKey: app.socketURL.path,
            CherryControl.processIDEnvironmentKey: tab,
            "HOME": home.path,
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(message.utf8))
        try input.fileHandleForWriting.close()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }.value
    #expect(run.0 == 0, "\(run.1) \(run.2)")
    #expect(run.1 == #"{"sent_bytes":12}"# + "\n")
    let calls = app.calls
    #expect(calls.map(\.name) == ["send_agent_message", "send_process_input"])
    #expect(calls.first?.arguments == ["process_name": .string("dev"), "message": .string(message)])
    #expect(calls.last?.arguments == ["process_name": .string("dev"), "text": .string(message), "submit": .bool(true)])
    #expect(calls.allSatisfy { $0.context?.interface == "cli" && $0.context?.callerProcessID == tab })
}
