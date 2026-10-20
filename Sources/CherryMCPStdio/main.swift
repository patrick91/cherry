import CherryControl
import CherryMCP
import Darwin
import Foundation

@main
struct CherryMCPStdioMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--version" {
            print(CherryMCPTools.versionJSON(build: CherryBuildInfo.build(executableURL: Bundle.main.executableURL)))
            exit(0)
        }
        if arguments.first == "cli" {
            await runCLI(Array(arguments.dropFirst()))
        }
        // Temporary keyboard diagnostics; remove once the Shift+Enter/Shift+Tab report is understood.
        if arguments.first == "--key-echo" {
            KeyEcho.run(arguments: Array(arguments.dropFirst()))
        }
        fputs("usage: CherryMCP cli ARGS… (run cherry --help), or CherryMCP --version\n", stderr)
        exit(2)
    }

    /// `CherryMCP cli ARGS…`: one `cherry` agent command (`CherryCLI`; the
    /// Rust `cherry` hands its non-host commands here). Exit 0, 1 on the
    /// tool's error, 2 on a usage error.
    static func runCLI(_ arguments: [String]) async -> Never {
        let invocation = CherryCLI.parse(arguments, input: .standard)
        let session = CherryMCPSession()
        let outcome = await CherryCLIRunner.run(invocation, isTerminal: isatty(STDOUT_FILENO) != 0) { name, arguments in
            await session.call(name: name, arguments: arguments, interface: "cli")
        }
        FileHandle.standardOutput.write(Data(outcome.standardOutput.utf8))
        FileHandle.standardError.write(Data(outcome.standardError.utf8))
        exit(outcome.exitCode)
    }
}
