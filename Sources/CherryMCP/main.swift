import CherryControl
import Foundation
import MCP

private let client = CherryControlClient()

let server = Server(
    name: "cherry",
    version: "0.1.0",
    title: "Cherry",
    instructions: "Control the visible Cherry terminal app through local-only IPC.",
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
            "Create a project-scoped Markdown note in Cherry. Opens the note for review by default.",
            properties: [
                "title": string("Note title."),
                "markdown": string("Markdown content."),
                "open": boolean("Whether Cherry should open the note after creating it. Defaults to true.")
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
            "Update a Cherry Markdown note title and/or content.",
            properties: [
                "note_id": string("Cherry note UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown content."),
                "open": boolean("Whether Cherry should open the note after updating it. Defaults to false.")
            ],
            required: ["note_id"]
        ),
        tool(
            "delete_note",
            "Delete a Cherry Markdown note.",
            properties: ["note_id": string("Cherry note UUID.")],
            required: ["note_id"]
        ),
        tool(
            "select_note",
            "Open an existing Cherry Markdown note for review/editing.",
            properties: ["note_id": string("Cherry note UUID.")],
            required: ["note_id"]
        ),
        tool(
            "create_todo",
            "Create a project-scoped Cherry todo. Opens the todo pane by default.",
            properties: [
                "title": string("Todo title."),
                "markdown": string("Optional Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "open": boolean("Whether Cherry should open the todo after creating it. Defaults to true.")
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
            "Update a Cherry todo title, Markdown details, and/or status.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "open": boolean("Whether Cherry should open the todo after updating it. Defaults to false.")
            ],
            required: ["todo_id"]
        ),
        tool(
            "move_todo",
            "Move a Cherry todo to another status and/or position. If status changes and after_todo_id is omitted, the todo is appended to the target status.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "status": string("Optional target status: backlog, ready, doing, blocked, or done."),
                "after_todo_id": string("Optional todo UUID in the target status to place this todo after."),
                "open": boolean("Whether Cherry should open the todo after moving it. Defaults to false.")
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
            "Open an existing Cherry todo in the todo pane.",
            properties: ["todo_id": string("Cherry todo UUID.")],
            required: ["todo_id"]
        ),
        tool(
            "add_todo_comment",
            "Append a comment to a Cherry todo. Pass terminal_id for agent attribution when commenting from a Cherry agent session.",
            properties: [
                "todo_id": string("Cherry todo UUID."),
                "markdown": string("Comment Markdown."),
                "author": string("Optional author label used when terminal_id is not provided."),
                "terminal_id": string("Optional Cherry agent terminal UUID for attribution."),
                "open": boolean("Whether Cherry should open the todo after adding the comment. Defaults to false.")
            ],
            required: ["todo_id", "markdown"]
        ),
        tool(
            "create_terminal",
            "Create and select a new visible Cherry terminal tab.",
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
            "Select a visible Cherry terminal tab.",
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

    private static func controlRequest(name: String, arguments: [String: Value]) throws -> CherryControlRequest {
        switch name {
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
                open: boolArgument("open", in: arguments)
            ))
        case "get_note":
            return .getNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "update_note":
            return .updateNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                open: boolArgument("open", in: arguments)
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
                open: boolArgument("open", in: arguments)
            ))
        case "get_todo":
            return .getTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo":
            return .updateTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                open: boolArgument("open", in: arguments)
            ))
        case "move_todo":
            return .moveTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                afterTodoID: stringArgument("after_todo_id", in: arguments),
                open: boolArgument("open", in: arguments)
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
                open: boolArgument("open", in: arguments)
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
}

private struct ErrorPayload: Codable {
    let error: CherryControlError
}
