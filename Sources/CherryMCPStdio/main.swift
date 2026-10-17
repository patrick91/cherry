import CherryControl
import CherryMCP
import Darwin
import Foundation
import MCP

@main
struct CherryMCPStdioMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--version" {
            print(CherryMCPTools.versionJSON(build: CherryBuildInfo.build(executableURL: Bundle.main.executableURL)))
            exit(0)
        }
        if arguments.first == "--call" {
            await callOnce(Array(arguments.dropFirst()))
        }
        // Temporary keyboard diagnostics; remove once the Shift+Enter/Shift+Tab report is understood.
        if arguments.first == "--key-echo" {
            KeyEcho.run(arguments: Array(arguments.dropFirst()))
        }

        // The app identifies the caller by its process when a call arrives,
        // so nothing is asked of it before the client is.
        let session = CherryMCPSession(arguments: arguments)
        do {
            let server = try await session.serve(on: CherryStdioTransport())
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
        var toolArguments: [String: JSONValue] = [:]
        if arguments.count > 1 {
            guard let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: Data(arguments[1].utf8)) else {
                fputs("CherryMCP: the arguments are not a JSON object; pass one valid JSON object in single quotes, for example: CherryMCP --call \(name) '{\"status\":\"ok\"}'\n", stderr)
                exit(2)
            }
            toolArguments = decoded
        }
        let result = await CherryMCPSession().call(name: name, arguments: toolArguments, interface: "call")
        print(result.text)
        exit(result.isError ? 1 : 0)
    }
}
