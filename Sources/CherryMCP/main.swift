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
while true {
    try await Task.sleep(for: .seconds(3_600))
}

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
        case .createTerminal(let payload):
            return try encodedResult(payload)
        case .runAgent(let payload):
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
