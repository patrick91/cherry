import CherryMCP
import Darwin
import MCP

@main
struct CherryMCPStdioMain {
    static func main() async {
        let toolContext = CherryMCPToolContext.bound(
            callerProcessID: await CherryMCPTools.callerProcessID(processPID: getpid(), parentPID: getppid())
        )
        let server = Server(
            name: "cherry",
            version: "0.1.0",
            title: "Cherry",
            instructions: "Control the visible Cherry terminal app through local-only IPC. Tools do not change Cherry's visible selection unless the tool name starts with select_. Agent creation is parented to the bound caller process when available; unbound sessions create top-level agents unless parent_agent_id is explicit.",
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
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            fputs("[mcp-stdio] failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
