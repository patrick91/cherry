import CherryControl
import CherryMCP
import Darwin
import Foundation
import MCP

@main
struct CherryMCPStdioMain {
    static let version = "0.1.0"

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--version" {
            print("{\"name\":\"CherryMCP\",\"version\":\"\(version)\"}")
            exit(0)
        }
        if arguments.first == "--call" {
            await callOnce(Array(arguments.dropFirst()))
        }

        let toolContext = CherryMCPToolContext.bound(
            callerProcessID: await CherryMCPTools.callerProcessID(processPID: getpid(), parentPID: getppid())
        )
        let server = Server(
            name: "cherry",
            version: version,
            title: "Cherry",
            instructions: "Control the visible Cherry terminal app through local-only IPC. Tools do not change Cherry's visible selection unless the tool name starts with select_. Agent creation is parented to the bound caller process when available; unbound sessions create top-level agents unless parent_agent_id is explicit. Orchestration notes: an agent with agent_activity_state=working can legitimately stay working for many minutes (e.g. running subagents) — prefer wait_for_process_idle with a generous timeout_ms over nudging it; a message sent to a working agent is queued by the agent CLI and fires after the current turn, and it is NOT recalled if your tool call times out or is interrupted. Process IDs remain valid across project-window switches.",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: CherryMCPTools.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await CherryMCPTools.call(
                name: params.name,
                arguments: params.arguments ?? [:],
                context: toolContext
            )
        }

        do {
            try await server.start(transport: CherryStdioTransport())
            await server.waitUntilCompleted()
        } catch {
            fputs("[mcp-stdio] failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// `CherryMCP --call NAME [JSON-ARGUMENTS]`: one tool call, its result
    /// on standard output; exit 1 when it is an error. For checks (Set Up
    /// Cherry MCP, tests) without an MCP client.
    static func callOnce(_ arguments: [String]) async -> Never {
        guard let name = arguments.first else {
            fputs("usage: CherryMCP --call NAME [JSON-ARGUMENTS]\n", stderr)
            exit(2)
        }
        var toolArguments: [String: Value] = [:]
        if arguments.count > 1 {
            guard let decoded = try? JSONDecoder().decode([String: Value].self, from: Data(arguments[1].utf8)) else {
                fputs("CherryMCP: the arguments are not a JSON object\n", stderr)
                exit(2)
            }
            toolArguments = decoded
        }
        let context = CherryMCPToolContext.bound(
            callerProcessID: await CherryMCPTools.callerProcessID(processPID: getpid(), parentPID: getppid())
        )
        let result = await CherryMCPTools.call(name: name, arguments: toolArguments, context: context)
        for content in result.content {
            if case .text(let text, _, _) = content { print(text) }
        }
        exit(result.isError == true ? 1 : 0)
    }
}
