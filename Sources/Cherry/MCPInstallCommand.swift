import CherryControl
import Foundation

enum MCPHarness: String, CaseIterable, Identifiable {
    case codex
    case claude
    case pi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude"
        case .pi:
            "Pi"
        }
    }
}

struct MCPInstallCommand: Identifiable, Equatable {
    let harness: MCPHarness
    let command: String

    var id: MCPHarness { harness }
}

enum MCPInstallCommandBuilder {
    /// This app's CherryMCP, next to its executable.
    static var helperPath: String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("CherryMCP", isDirectory: false)
            .path
    }

    static var helperCommand: String {
        guard let helperPath else {
            return "CherryMCP"
        }
        return shellQuoted(helperPath)
    }

    static func commands(identity: CherryAppIdentity = .current) -> [MCPInstallCommand] {
        return [
            MCPInstallCommand(
                harness: .codex,
                command: "codex mcp add \(identity.urlScheme) -- \(helperCommand)"
            ),
            MCPInstallCommand(
                harness: .claude,
                command: "claude mcp add --transport stdio --scope user \(identity.urlScheme) -- \(helperCommand)"
            ),
            MCPInstallCommand(
                // `PiMCPRegistration.addArguments`, as a shell runs them.
                harness: .pi,
                command: "pi mcp add \(identity.urlScheme) --exposure direct -- \(helperCommand)"
            ),
        ]
    }

    static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Pi's registration of Cherry MCP (Settings › MCP): `pi mcp add <name>
/// --exposure direct -- <CherryMCP>`, run only when the user clicks Add
/// (Pi writes its own `mcp.json`; Cherry never edits it), and a read-only
/// look at Pi's global `mcp.json` to say whether it is there. `direct`
/// exposure gives the model Cherry's tools themselves (Pi's default,
/// `codemode`, hides them behind a script tool). Pi passes its whole
/// environment to MCP servers, so CherryMCP sees the tab's
/// `CHERRY_PROCESS_ID`.
enum PiMCPRegistration {
    /// Where `pi mcp add` writes, per `status`.
    enum Status: Equatable {
        /// This app's CherryMCP with direct exposure.
        case registered
        /// The name is registered, but not as this app adds it: what differs.
        case differs(String)
        case notRegistered
        /// Pi's mcp.json could not be read as JSON.
        case unreadable(String)
    }

    static func addArguments(serverName: String, helperPath: String) -> [String] {
        ["mcp", "add", serverName, "--exposure", "direct", "--", helperPath]
    }

    /// Pi's global agent directory: `PI_CODING_AGENT_DIR`, else `~/.pi/agent`.
    static func agentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = configured == "~" ? homeDirectory.path
                : configured.hasPrefix("~/") ? homeDirectory.path + String(configured.dropFirst(1)) : configured
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    /// Whether Pi's `mcp.json` in `agentDirectory` registers `serverName`
    /// as this app would. Reads the file only.
    static func status(serverName: String, helperPath: String, agentDirectory: URL) -> Status {
        let file = agentDirectory.appendingPathComponent("mcp.json", isDirectory: false)
        guard let data = FileManager.default.contents(atPath: file.path) else { return .notRegistered }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("\(file.path) is not a JSON object")
        }
        guard let server = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else {
            return .notRegistered
        }
        let command = server["command"] as? String
        let arguments = server["args"] as? [String] ?? []
        guard let command, standardized(command) == standardized(helperPath), arguments.isEmpty else {
            return .differs("it runs \(([command ?? "?"] + arguments).joined(separator: " "))")
        }
        let exposure = server["exposure"] as? String ?? "codemode"
        guard exposure == "direct" else {
            return .differs("its exposure is \(exposure), so Pi hides Cherry's tools behind a script tool")
        }
        return .registered
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Where `pi` is: on `searchPath`, else where Bun, Homebrew and npm
    /// put it.
    static func locate(searchPath: String, homeDirectory: String = NSHomeDirectory()) -> URL? {
        let directories = searchPath.split(separator: ":").map(String.init)
            + ["\(homeDirectory)/.bun/bin", "\(homeDirectory)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("pi")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    struct RunOutcome: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    /// Runs `executable` with `arguments` and `environment`, its output
    /// kept; killed after `timeout`.
    static func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 60) async -> RunOutcome {
        await Task.detached {
            runBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
    }

    private static func runBlocking(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> RunOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return RunOutcome(status: -1, output: error.localizedDescription)
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
            return RunOutcome(status: -1, output: "pi did not finish in \(Int(timeout)) s")
        }
        return RunOutcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `pi mcp add` as Settings › MCP runs it: `pi` from the login shell's
    /// PATH, in the login environment (its node or bun needs it).
    static func register(serverName: String, helperPath: String) async -> RunOutcome {
        let environment = await Task.detached {
            HostedSessionLoginEnvironment.shared.resolve()?.environment ?? ProcessInfo.processInfo.environment
        }.value
        guard let pi = locate(searchPath: environment["PATH"] ?? "") else {
            return RunOutcome(status: -1, output: "pi was not found on the login shell's PATH (nor in ~/.bun/bin, ~/.local/bin, /opt/homebrew/bin or /usr/local/bin).")
        }
        return await run(executable: pi, arguments: addArguments(serverName: serverName, helperPath: helperPath), environment: environment)
    }
}

/// The Pi row's state in Settings › MCP.
@MainActor
final class PiMCPRegistrationModel: ObservableObject {
    typealias Runner = @Sendable (_ serverName: String, _ helperPath: String) async -> PiMCPRegistration.RunOutcome

    let serverName: String
    let helperPath: String?
    let agentDirectory: URL
    private let runner: Runner

    @Published private(set) var status: PiMCPRegistration.Status = .notRegistered
    @Published private(set) var isRunning = false
    /// What the last Add said (Pi's output, or why it failed).
    @Published private(set) var message: String?
    @Published private(set) var lastRunFailed = false

    init(
        serverName: String = CherryAppIdentity.current.urlScheme,
        helperPath: String? = MCPInstallCommandBuilder.helperPath,
        agentDirectory: URL = PiMCPRegistration.agentDirectory(),
        runner: @escaping Runner = { await PiMCPRegistration.register(serverName: $0, helperPath: $1) }
    ) {
        self.serverName = serverName
        self.helperPath = helperPath
        self.agentDirectory = agentDirectory
        self.runner = runner
        refresh()
    }

    func refresh() {
        guard let helperPath else {
            status = .notRegistered
            return
        }
        status = PiMCPRegistration.status(serverName: serverName, helperPath: helperPath, agentDirectory: agentDirectory)
    }

    /// Runs `pi mcp add` (only ever from the user's click).
    func register() async {
        guard let helperPath, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let outcome = await runner(serverName, helperPath)
        lastRunFailed = outcome.status != 0
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        message = output.isEmpty ? (lastRunFailed ? "pi exited with status \(outcome.status)." : nil) : output
        refresh()
    }

    var statusText: String {
        switch status {
        case .registered: "Registered with Pi (direct exposure)."
        case .differs(let what): "Pi has a \(serverName) server, but \(what)."
        case .notRegistered: "Not registered with Pi."
        case .unreadable(let why): "Pi's MCP settings could not be read: \(why)."
        }
    }
}
