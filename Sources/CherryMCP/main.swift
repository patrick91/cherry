import CherryControl
import Foundation
import MCP

private let client = CherryControlClient()

let server = Server(
    name: "cherry",
    version: "0.1.0",
    title: "Cherry",
    instructions: "Control the visible Cherry terminal app through local-only IPC. Tools do not change Cherry's visible selection unless the tool name starts with select_.",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: CherryMCPTools.all)
}

await server.withMethodHandler(CallTool.self) { params in
    await CherryMCPTools.call(name: params.name, arguments: params.arguments ?? [:])
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
await server.stop()

private enum CherryMCPTools {
    static let all: [Tool] = [
        tool(
            "get_status",
            "Check Cherry MCP helper and app control socket status without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "list_projects",
            "List saved/open Cherry projects and the active project without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "get_project_status",
            "Return active project root, process counts, note/todo counts, selected process, and health without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "list_processes",
            "List terminal, agent, and command processes in the active project without changing the Cherry UI.",
            properties: ["kind": string("Optional process kind filter: terminal, agent, or command.")]
        ),
        tool(
            "get_process_status",
            "Read detailed status for one process by process_id or process_name without changing the Cherry UI.",
            properties: processSelectorProperties(),
            required: []
        ),
        tool(
            "get_process_output",
            "Read rendered output for one process by process_id or process_name.",
            properties: processSelectorProperties([
                "start_line": integer("Optional zero-based start line."),
                "line_limit": integer("Maximum rendered lines. Max 2000.")
            ])
        ),
        tool(
            "get_process_raw_output",
            "Read recent raw output for one process by process_id or process_name, including control sequences.",
            properties: processSelectorProperties([
                "max_bytes": integer("Maximum bytes. Max 1048576.")
            ])
        ),
        tool(
            "search_process_output",
            "Search rendered process output for matching lines.",
            properties: processSelectorProperties([
                "query": string("Text to search for."),
                "case_sensitive": boolean("Whether matching is case-sensitive."),
                "max_matches": integer("Maximum matches. Max 500.")
            ]),
            required: ["query"]
        ),
        tool(
            "get_process_ports",
            "Return localhost TCP services associated with one Cherry process. Unattributed listeners are hidden unless include_unattributed is true.",
            properties: processSelectorProperties([
                "include_unattributed": boolean("Whether to include localhost listeners not attributed to the selected Cherry process. Defaults to false.")
            ])
        ),
        tool(
            "services_list",
            "List localhost TCP services for active Cherry processes without changing the Cherry UI. Unattributed listeners are hidden unless include_unattributed is true.",
            properties: [
                "kind": string("Optional process kind filter: terminal, agent, or command."),
                "include_unattributed": boolean("Whether to include localhost listeners not attributed to Cherry processes. Defaults to false.")
            ]
        ),
        tool(
            "wait_for_bound_port",
            "Wait for one matching localhost TCP service. Returns ambiguous_service if multiple services match; narrow with process_id, process_name, or port. HTTP probing only happens when probe_http is true.",
            properties: processSelectorProperties([
                "port": integer("Optional TCP port to wait for."),
                "timeout_ms": integer("Maximum wait in milliseconds. Defaults to 10000, max 60000."),
                "include_unattributed": boolean("Whether to include unattributed localhost listeners. Defaults to false."),
                "probe_http": boolean("Whether to require a successful HTTP GET before returning. Defaults to false."),
                "path": string("HTTP path to probe when probe_http is true. Defaults to /."),
            ])
        ),
        tool(
            "spawn_process",
            "Create a terminal, configured agent, or trusted project command process without selecting it. For agent/command, name must match configured Cherry settings.",
            properties: [
                "kind": string("Process kind: terminal, agent, or command."),
                "name": string("Configured agent or command name. Not used for terminal."),
                "title": string("Optional custom title."),
                "working_directory": string("Optional terminal working directory."),
                "text": string("Optional text to send exactly as provided after launch."),
                "raw_base64": string("Optional raw bytes to send after launch, base64-encoded."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["kind"]
        ),
        tool(
            "start_process",
            "Start an existing stopped process, or start a configured command/agent by process_name and kind, without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "stop_process",
            "Stop one process by process_id or process_name without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "restart_process",
            "Restart one process by process_id or process_name without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "close_process",
            "Close one process by process_id or process_name without selecting another UI pane.",
            properties: processSelectorProperties()
        ),
        tool(
            "rename_process",
            "Rename one process by process_id or process_name without selecting it. Empty title clears explicit title.",
            properties: processSelectorProperties(["title": string("New title. Empty clears the explicit title.")])
        ),
        tool(
            "send_process_input",
            "Send terminal text or raw bytes to an existing process by process_id or process_name.",
            properties: processSelectorProperties([
                "text": string("Text to send exactly as provided."),
                "raw_base64": string("Raw bytes to send, base64-encoded."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ])
        ),
        tool(
            "start_all_commands",
            "Start all trusted configured project commands without selecting them.",
            properties: bulkCommandProperties()
        ),
        tool(
            "stop_all_commands",
            "Stop project command processes only; does not stop ad hoc terminals or agents.",
            properties: bulkCommandProperties()
        ),
        tool(
            "restart_all_commands",
            "Restart all trusted configured project commands without selecting them.",
            properties: bulkCommandProperties()
        ),
        tool(
            "list_terminals",
            "List visible Cherry terminals.",
            properties: [:]
        ),
        tool(
            "list_agents",
            "List configured Cherry agents available to the active project.",
            properties: [:]
        ),
        tool(
            "list_notes",
            "List Cherry notes for the active project.",
            properties: [:]
        ),
        tool(
            "list_todos",
            "List Cherry todos for the active project.",
            properties: [:]
        ),
        tool(
            "create_note",
            "Create a project-scoped Markdown note in Cherry without opening or selecting it.",
            properties: [
                "title": string("Note title."),
                "markdown": string("Markdown content.")
            ],
            required: ["title", "markdown"]
        ),
        tool(
            "get_note",
            "Read a Cherry Markdown note.",
            properties: ["note_id": string("Cherry note UUID.")],
            required: ["note_id"]
        ),
        tool(
            "update_note",
            "Update a Cherry Markdown note title and/or content without opening or selecting it.",
            properties: [
                "note_id": string("Cherry note UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown content.")
            ],
            required: ["note_id"]
        ),
        tool(
            "append_note",
            "Append Markdown to a Cherry note without opening or selecting it.",
            properties: [
                "note_id": string("Cherry note UUID."),
                "markdown": string("Markdown content to append.")
            ],
            required: ["note_id", "markdown"]
        ),
        tool(
            "rename_note",
            "Rename a Cherry note without opening or selecting it.",
            properties: [
                "note_id": string("Cherry note UUID."),
                "title": string("Replacement note title.")
            ],
            required: ["note_id", "title"]
        ),
        tool(
            "search_notes",
            "Search Cherry note titles and Markdown for the active project without changing the Cherry UI.",
            properties: [
                "query": string("Text to search for."),
                "case_sensitive": boolean("Whether matching is case-sensitive."),
                "max_matches": integer("Maximum matches. Max 500.")
            ],
            required: ["query"]
        ),
        tool(
            "delete_note",
            "Delete a Cherry Markdown note.",
            properties: ["note_id": string("Cherry note UUID.")],
            required: ["note_id"]
        ),
        tool(
            "select_note",
            "Explicitly open an existing Cherry Markdown note for review/editing. Use only when the user asks to switch the Cherry UI.",
            properties: ["note_id": string("Cherry note UUID.")],
            required: ["note_id"]
        ),
        tool(
            "create_todo",
            "Create a project-scoped Cherry todo without opening or selecting it.",
            properties: [
                "title": string("Todo title."),
                "markdown": string("Optional Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "tags": stringArray("Optional todo tag names.")
            ],
            required: ["title"]
        ),
        tool(
            "get_todo",
            "Read a Cherry todo, including comments.",
            properties: ["todo_id": string("Cherry todo UUID.")],
            required: ["todo_id"]
        ),
        tool(
            "update_todo",
            "Update a Cherry todo title, Markdown details, and/or status without opening or selecting it.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "tags": stringArray("Optional replacement todo tag names. Empty array clears tags.")
            ],
            required: ["todo_id"]
        ),
        tool(
            "move_todo",
            "Move a Cherry todo to another status and/or position without opening or selecting it. If status changes and after_todo_id is omitted, the todo is appended to the target status.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "status": string("Optional target status: backlog, ready, doing, blocked, or done."),
                "after_todo_id": string("Optional todo UUID in the target status to place this todo after.")
            ],
            required: ["todo_id"]
        ),
        tool(
            "delete_todo",
            "Delete a Cherry todo.",
            properties: ["todo_id": string("Cherry todo UUID.")],
            required: ["todo_id"]
        ),
        tool(
            "select_todo",
            "Explicitly open an existing Cherry todo in the todo pane. Use only when the user asks to switch the Cherry UI.",
            properties: ["todo_id": string("Cherry todo UUID.")],
            required: ["todo_id"]
        ),
        tool(
            "add_todo_comment",
            "Append a comment to a Cherry todo without opening or selecting it. Pass terminal_id for agent attribution when commenting from a Cherry agent session.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "markdown": string("Comment Markdown."),
                "author": string("Optional author label used when terminal_id is not provided."),
                "terminal_id": string("Optional Cherry agent terminal UUID for attribution.")
            ],
            required: ["todo_id", "markdown"]
        ),
        tool(
            "list_todo_comments",
            "List comments for a Cherry todo without opening or selecting it.",
            properties: ["todo_id": string("Cherry todo UUID.")],
            required: ["todo_id"]
        ),
        tool(
            "update_todo_comment",
            "Update a Cherry todo comment without opening or selecting it.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "comment_id": string("Cherry todo comment UUID."),
                "markdown": string("Replacement comment Markdown.")
            ],
            required: ["todo_id", "comment_id", "markdown"]
        ),
        tool(
            "delete_todo_comment",
            "Delete a Cherry todo comment without opening or selecting it.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "comment_id": string("Cherry todo comment UUID.")
            ],
            required: ["todo_id", "comment_id"]
        ),
        tool(
            "create_terminal",
            "Create a new visible Cherry terminal tab without selecting it.",
            properties: [
                "title": string("Optional terminal title."),
                "working_directory": string("Optional working directory."),
                "command": string("Optional command to run after launch.")
            ]
        ),
        tool(
            "run_agent",
            "Create a new configured Cherry agent session in the active project without selecting it. Always creates a new terminal; never use this to send input to an existing terminal.",
            properties: [
                "agent_name": string("Configured Cherry agent name."),
                "title": string("Optional custom session title."),
                "text": string("Optional text to send exactly as provided after launch."),
                "raw_base64": string("Optional raw bytes to send after launch, base64-encoded."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["agent_name"]
        ),
        tool(
            "rename_terminal",
            "Rename a Cherry terminal. Pass an empty title to return to Cherry's automatic title.",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "title": string("New title. Empty clears the explicit title.")
            ],
            required: ["terminal_id"]
        ),
        tool(
            "press_enter",
            "Press Enter in a running Cherry terminal. Use this to submit prompts or forms in existing TUIs; it sends carriage return (0x0d), not line feed (0x0a).",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["terminal_id"]
        ),
        tool(
            "select_terminal",
            "Explicitly select a visible Cherry terminal tab. Use only when the user asks to switch the Cherry UI.",
            properties: ["terminal_id": string("Cherry terminal UUID.")],
            required: ["terminal_id"]
        ),
        tool(
            "send_input",
            "Send terminal text or raw bytes to a running Cherry terminal. Use this for existing terminals; use press_enter for Enter in TUIs.",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "text": string("Text to send exactly as provided."),
                "raw_base64": string("Raw bytes to send, base64-encoded. For Enter in TUIs, prefer press_enter or send carriage return as DQ==, not line feed Cg==."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["terminal_id"]
        ),
        tool(
            "get_terminal_output",
            "Read rendered Cherry terminal output.",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "start_line": integer("Optional zero-based start line."),
                "line_limit": integer("Maximum rendered lines. Max 2000.")
            ],
            required: ["terminal_id"]
        ),
        tool(
            "get_terminal_raw_output",
            "Read recent raw Cherry terminal output, including control sequences.",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "max_bytes": integer("Maximum bytes. Max 1048576.")
            ],
            required: ["terminal_id"]
        ),
        tool(
            "search_output",
            "Search rendered Cherry terminal output for matching lines.",
            properties: [
                "terminal_id": string("Cherry terminal UUID."),
                "query": string("Text to search for."),
                "case_sensitive": boolean("Whether matching is case-sensitive."),
                "max_matches": integer("Maximum matches. Max 500.")
            ],
            required: ["terminal_id", "query"]
        ),
        tool(
            "clear_output",
            "Clear Cherry's saved output for a terminal without touching the PTY.",
            properties: ["terminal_id": string("Cherry terminal UUID.")],
            required: ["terminal_id"]
        ),
        tool(
            "restart_terminal",
            "Restart a Cherry terminal shell.",
            properties: ["terminal_id": string("Cherry terminal UUID.")],
            required: ["terminal_id"]
        ),
        tool(
            "close_terminal",
            "Close a Cherry terminal tab.",
            properties: ["terminal_id": string("Cherry terminal UUID.")],
            required: ["terminal_id"]
        )
    ]

    static func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            if name == "get_status" {
                return try statusResult()
            }
            let request = try controlRequest(name: name, arguments: arguments)
            let response = try client.send(request)
            if let error = response.error {
                return try toolError(error)
            }
            guard let result = response.result else {
                return try toolError(.init(code: "empty_response", message: "Cherry returned no result."))
            }
            return try toolResult(result)
        } catch let error as CherryControlError {
            return (try? toolError(error)) ?? .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            let controlError = CherryControlError(code: "tool_error", message: error.localizedDescription)
            return (try? toolError(controlError)) ?? .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func statusResult() throws -> CallTool.Result {
        let socketURL = CherryControl.socketURL
        let socketExists = FileManager.default.fileExists(atPath: socketURL.path)

        do {
            let response = try client.send(.listTerminals)
            if let error = response.error {
                return try encodedResult(MCPStatusPayload(
                    socketPath: socketURL.path,
                    socketExists: socketExists,
                    cherryReachable: false,
                    terminalCount: nil,
                    selectedTerminalID: nil,
                    error: error
                ))
            }
            guard case .listTerminals(let terminals)? = response.result else {
                return try encodedResult(MCPStatusPayload(
                    socketPath: socketURL.path,
                    socketExists: socketExists,
                    cherryReachable: false,
                    terminalCount: nil,
                    selectedTerminalID: nil,
                    error: .init(code: "unexpected_status_response", message: "Cherry returned an unexpected status response.")
                ))
            }
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: true,
                terminalCount: terminals.terminals.count,
                selectedTerminalID: terminals.selectedTerminalID,
                error: nil
            ))
        } catch let error as CherryControlError {
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: false,
                terminalCount: nil,
                selectedTerminalID: nil,
                error: error
            ))
        } catch {
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: false,
                terminalCount: nil,
                selectedTerminalID: nil,
                error: .init(code: "status_failed", message: error.localizedDescription)
            ))
        }
    }

    private static func controlRequest(name: String, arguments: [String: Value]) throws -> CherryControlRequest {
        switch name {
        case "list_projects":
            return .listProjects
        case "get_project_status":
            return .getProjectStatus
        case "list_processes":
            return .listProcesses(.init(kind: stringArgument("kind", in: arguments)))
        case "get_process_status":
            return .getProcessStatus(processSelector(in: arguments))
        case "get_process_output":
            return .getProcessOutput(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                startLine: intArgument("start_line", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "get_process_raw_output":
            return .getProcessRawOutput(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                maxBytes: intArgument("max_bytes", in: arguments)
            ))
        case "search_process_output":
            return .searchProcessOutput(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "get_process_ports":
            return .getProcessPorts(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments)
            ))
        case "services_list":
            return .servicesList(.init(
                kind: stringArgument("kind", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments)
            ))
        case "wait_for_bound_port":
            return .waitForBoundPort(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                port: intArgument("port", in: arguments),
                timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments),
                probeHTTP: boolArgument("probe_http", in: arguments),
                path: stringArgument("path", in: arguments)
            ))
        case "spawn_process":
            return .spawnProcess(.init(
                kind: try requiredString("kind", in: arguments),
                name: stringArgument("name", in: arguments),
                title: stringArgument("title", in: arguments),
                workingDirectory: stringArgument("working_directory", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "start_process":
            return .startProcess(processLifecycle(in: arguments))
        case "stop_process":
            return .stopProcess(processLifecycle(in: arguments))
        case "restart_process":
            return .restartProcess(processLifecycle(in: arguments))
        case "close_process":
            return .closeProcess(processSelector(in: arguments))
        case "rename_process":
            return .renameProcess(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                title: stringArgument("title", in: arguments)
            ))
        case "send_process_input":
            return .sendProcessInput(.init(
                processID: stringArgument("process_id", in: arguments),
                processName: stringArgument("process_name", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "start_all_commands":
            return .startAllCommands(processBulkCommand(in: arguments))
        case "stop_all_commands":
            return .stopAllCommands(processBulkCommand(in: arguments))
        case "restart_all_commands":
            return .restartAllCommands(processBulkCommand(in: arguments))
        case "list_terminals":
            return .listTerminals
        case "list_agents":
            return .listAgents
        case "list_notes":
            return .listNotes
        case "list_todos":
            return .listTodos
        case "create_note":
            return .createNote(.init(
                title: try requiredString("title", in: arguments),
                markdown: try requiredString("markdown", in: arguments),
                open: false
            ))
        case "get_note":
            return .getNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "update_note":
            return .updateNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                open: false
            ))
        case "append_note":
            return .appendNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments)
            ))
        case "rename_note":
            return .renameNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                title: try requiredString("title", in: arguments)
            ))
        case "search_notes":
            return .searchNotes(.init(
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "delete_note":
            return .deleteNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "select_note":
            return .selectNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "create_todo":
            return .createTodo(.init(
                title: try requiredString("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments) ?? "",
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments),
                open: false
            ))
        case "get_todo":
            return .getTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo":
            return .updateTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments),
                open: false
            ))
        case "move_todo":
            return .moveTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                afterTodoID: stringArgument("after_todo_id", in: arguments),
                open: false
            ))
        case "delete_todo":
            return .deleteTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "select_todo":
            return .selectTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "add_todo_comment":
            return .addTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments),
                author: stringArgument("author", in: arguments),
                terminalID: stringArgument("terminal_id", in: arguments),
                open: false
            ))
        case "list_todo_comments":
            return .listTodoComments(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo_comment":
            return .updateTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                commentID: try requiredString("comment_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments)
            ))
        case "delete_todo_comment":
            return .deleteTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                commentID: try requiredString("comment_id", in: arguments)
            ))
        case "create_terminal":
            return .createTerminal(.init(
                title: stringArgument("title", in: arguments),
                workingDirectory: stringArgument("working_directory", in: arguments),
                command: stringArgument("command", in: arguments)
            ))
        case "run_agent":
            return .runAgent(.init(
                agentName: try requiredString("agent_name", in: arguments),
                title: stringArgument("title", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments),
                select: false
            ))
        case "rename_terminal":
            return .renameTerminal(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                title: stringArgument("title", in: arguments)
            ))
        case "press_enter":
            return .sendInput(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                text: nil,
                rawBase64: "DQ==",
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "select_terminal":
            return .selectTerminal(.init(terminalID: try requiredString("terminal_id", in: arguments)))
        case "send_input":
            return .sendInput(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "get_terminal_output":
            return .getTerminalOutput(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                startLine: intArgument("start_line", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "get_terminal_raw_output":
            return .getTerminalRawOutput(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                maxBytes: intArgument("max_bytes", in: arguments)
            ))
        case "search_output":
            return .searchOutput(.init(
                terminalID: try requiredString("terminal_id", in: arguments),
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "clear_output":
            return .clearOutput(.init(terminalID: try requiredString("terminal_id", in: arguments)))
        case "restart_terminal":
            return .restartTerminal(.init(terminalID: try requiredString("terminal_id", in: arguments)))
        case "close_terminal":
            return .closeTerminal(.init(terminalID: try requiredString("terminal_id", in: arguments)))
        default:
            throw CherryControlError(code: "unknown_tool", message: "Unknown Cherry MCP tool: \(name)")
        }
    }

    private static func toolResult(_ result: CherryControlResult) throws -> CallTool.Result {
        switch result {
        case .listProjects(let payload):
            return try encodedResult(payload)
        case .getProjectStatus(let payload):
            return try encodedResult(payload)
        case .listProcesses(let payload):
            return try encodedResult(payload)
        case .getProcessStatus(let payload):
            return try encodedResult(payload)
        case .getProcessOutput(let payload):
            return try encodedResult(payload)
        case .getProcessRawOutput(let payload):
            return try encodedResult(payload)
        case .searchProcessOutput(let payload):
            return try encodedResult(payload)
        case .getProcessPorts(let payload):
            return try encodedResult(payload)
        case .servicesList(let payload):
            return try encodedResult(payload)
        case .waitForBoundPort(let payload):
            return try encodedResult(payload)
        case .spawnProcess(let payload):
            return try encodedResult(payload)
        case .startProcess(let payload):
            return try encodedResult(payload)
        case .stopProcess(let payload):
            return try encodedResult(payload)
        case .restartProcess(let payload):
            return try encodedResult(payload)
        case .closeProcess(let payload):
            return try encodedResult(payload)
        case .renameProcess(let payload):
            return try encodedResult(payload)
        case .sendProcessInput(let payload):
            return try encodedResult(payload)
        case .startAllCommands(let payload):
            return try encodedResult(payload)
        case .stopAllCommands(let payload):
            return try encodedResult(payload)
        case .restartAllCommands(let payload):
            return try encodedResult(payload)
        case .listTerminals(let payload):
            return try encodedResult(payload)
        case .listAgents(let payload):
            return try encodedResult(payload)
        case .listNotes(let payload):
            return try encodedResult(payload)
        case .listTodos(let payload):
            return try encodedResult(payload)
        case .createTerminal(let payload):
            return try encodedResult(payload)
        case .runAgent(let payload):
            return try encodedResult(payload)
        case .createNote(let payload):
            return try encodedResult(payload)
        case .getNote(let payload):
            return try encodedResult(payload)
        case .updateNote(let payload):
            return try encodedResult(payload)
        case .appendNote(let payload):
            return try encodedResult(payload)
        case .renameNote(let payload):
            return try encodedResult(payload)
        case .searchNotes(let payload):
            return try encodedResult(payload)
        case .deleteNote(let payload):
            return try encodedResult(payload)
        case .selectNote(let payload):
            return try encodedResult(payload)
        case .createTodo(let payload):
            return try encodedResult(payload)
        case .getTodo(let payload):
            return try encodedResult(payload)
        case .updateTodo(let payload):
            return try encodedResult(payload)
        case .moveTodo(let payload):
            return try encodedResult(payload)
        case .deleteTodo(let payload):
            return try encodedResult(payload)
        case .selectTodo(let payload):
            return try encodedResult(payload)
        case .addTodoComment(let payload):
            return try encodedResult(payload)
        case .listTodoComments(let payload):
            return try encodedResult(payload)
        case .updateTodoComment(let payload):
            return try encodedResult(payload)
        case .deleteTodoComment(let payload):
            return try encodedResult(payload)
        case .renameTerminal(let payload):
            return try encodedResult(payload)
        case .selectTerminal(let payload):
            return try encodedResult(payload)
        case .sendInput(let payload):
            return try encodedResult(payload)
        case .getTerminalOutput(let payload):
            return try encodedResult(payload)
        case .getTerminalRawOutput(let payload):
            return try encodedResult(payload)
        case .searchOutput(let payload):
            return try encodedResult(payload)
        case .clearOutput(let payload):
            return try encodedResult(payload)
        case .restartTerminal(let payload):
            return try encodedResult(payload)
        case .closeTerminal(let payload):
            return try encodedResult(payload)
        }
    }

    private static func encodedResult<Payload: Codable>(_ payload: Payload) throws -> CallTool.Result {
        let json = try jsonString(payload)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try Value(payload)),
            isError: false
        )
    }

    private static func toolError(_ error: CherryControlError) throws -> CallTool.Result {
        let payload = ErrorPayload(error: error)
        let json = try jsonString(payload)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try Value(payload)),
            isError: true
        )
    }

    private static func jsonString<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func requiredString(_ key: String, in arguments: [String: Value]) throws -> String {
        guard let value = stringArgument(key, in: arguments), !value.isEmpty else {
            throw CherryControlError(code: "missing_argument", message: "Missing required string argument: \(key)")
        }
        return value
    }

    private static func stringArgument(_ key: String, in arguments: [String: Value]) -> String? {
        arguments[key]?.stringValue
    }

    private static func intArgument(_ key: String, in arguments: [String: Value]) -> Int? {
        arguments[key]?.intValue
    }

    private static func boolArgument(_ key: String, in arguments: [String: Value]) -> Bool? {
        arguments[key]?.boolValue
    }

    private static func stringArrayArgument(_ key: String, in arguments: [String: Value]) throws -> [String]? {
        guard let value = arguments[key] else { return nil }
        guard let array = value.arrayValue else {
            throw CherryControlError(code: "invalid_argument", message: "\(key) must be an array of strings.")
        }
        var strings: [String] = []
        for item in array {
            guard let string = item.stringValue else {
                throw CherryControlError(code: "invalid_argument", message: "\(key) must be an array of strings.")
            }
            strings.append(string)
        }
        return strings
    }

    private static func todoStatusArgument(_ key: String, in arguments: [String: Value]) throws -> TodoStatus? {
        guard let value = stringArgument(key, in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        guard let status = TodoStatus(rawValue: value.lowercased()) else {
            throw CherryControlError(code: "invalid_todo_status", message: "Unknown todo status: \(value)")
        }
        return status
    }

    private static func processSelector(in arguments: [String: Value]) -> ProcessSelectorRequest {
        ProcessSelectorRequest(
            processID: stringArgument("process_id", in: arguments),
            processName: stringArgument("process_name", in: arguments)
        )
    }

    private static func processLifecycle(in arguments: [String: Value]) -> ProcessLifecycleRequest {
        ProcessLifecycleRequest(
            processID: stringArgument("process_id", in: arguments),
            processName: stringArgument("process_name", in: arguments),
            kind: stringArgument("kind", in: arguments),
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func processBulkCommand(in arguments: [String: Value]) -> ProcessBulkCommandRequest {
        ProcessBulkCommandRequest(
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Value], required: [String] = []) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(Value.string))
            ])
        )
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")])
        ])
    }

    private static func processSelectorProperties(_ extra: [String: Value] = [:]) -> [String: Value] {
        var properties: [String: Value] = [
            "process_id": string("Stable Cherry process UUID. Preferred when known."),
            "process_name": string("Process name/title when process_id is not known.")
        ]
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }

    private static func lifecycleProperties() -> [String: Value] {
        [
            "kind": string("Optional process kind for starting by name: agent or command."),
            "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
            "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
        ]
    }

    private static func bulkCommandProperties() -> [String: Value] {
        [
            "wait_ms": integer("Optional wait before returning process list. Max 5000."),
            "line_limit": integer("Reserved output line limit for lifecycle symmetry.")
        ]
    }
}

private struct ErrorPayload: Codable {
    let error: CherryControlError
}

private struct MCPStatusPayload: Codable {
    let socketPath: String
    let socketExists: Bool
    let cherryReachable: Bool
    let terminalCount: Int?
    let selectedTerminalID: String?
    let error: CherryControlError?
}
