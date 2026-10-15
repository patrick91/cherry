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

    /// The agent CLI this is: its product name, and the agents that run it.
    var brand: AgentToolBrand {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .pi: .pi
        }
    }

    /// The CLI's own name: "Claude Code", "Codex", "Pi".
    var productName: String {
        brand.productName
    }

    /// The CLI's executable: `claude`, `codex`, `pi`.
    var executableName: String {
        rawValue
    }

    /// The arguments of the CLI's `mcp add` that register `helperPath` as
    /// the stdio server `serverName`: Claude Code's for every project of
    /// this user, Codex's, and Pi's with direct exposure
    /// (`PiMCPRegistration.addArguments`). Add only: a name the CLI already
    /// has is the CLI's to refuse (Claude Code does) or replace (Pi does).
    func addArguments(serverName: String, helperPath: String) -> [String] {
        switch self {
        case .claude:
            ["mcp", "add", "--transport", "stdio", "--scope", "user", serverName, "--", helperPath]
        case .codex:
            ["mcp", "add", serverName, "--", helperPath]
        case .pi:
            PiMCPRegistration.addArguments(serverName: serverName, helperPath: helperPath)
        }
    }

    /// `mcp add` as a shell runs it, to copy: the executable and its
    /// arguments, with `helperCommand` (the helper's path, quoted).
    func addCommand(serverName: String, helperCommand: String) -> String {
        ([executableName] + addArguments(serverName: serverName, helperPath: helperCommand)).joined(separator: " ")
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
        return ShellQuoting.singleQuoted(helperPath)
    }

    /// Codex's, Claude Code's and Pi's commands, in that order; Settings
    /// orders them where it lists them.
    static func commands(identity: CherryAppIdentity = .current) -> [MCPInstallCommand] {
        [MCPHarness.codex, .claude, .pi].map { command(for: $0, identity: identity) }
    }

    /// The command that registers this app's helper with `harness`'s CLI,
    /// as an agent's page shows it under "Or run it yourself:".
    static func command(for harness: MCPHarness, identity: CherryAppIdentity = .current) -> MCPInstallCommand {
        MCPInstallCommand(
            harness: harness,
            command: harness.addCommand(serverName: identity.urlScheme, helperCommand: helperCommand)
        )
    }
}

/// Registering Cherry MCP with an agent CLI on This Mac (an agent's page in
/// Settings › Agents & MCP: Add to Claude Code, Add to Codex, Add to Pi):
/// the CLI's own `mcp add`, run only when the user clicks (each CLI writes
/// its own settings; Cherry never edits them), in the login shell's
/// environment, where the CLI and what it runs on (node, bun) are found.
enum MCPCLIRegistration {
    struct RunOutcome: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    /// Where a CLI's installers put it, for a login shell whose PATH lacks
    /// it: the places Set Up Cherry MCP looks on another Mac too.
    static func fallbackDirectories(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.claude/local",
            "\(homeDirectory)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    /// Where `executable` is: on `searchPath`, else in
    /// `fallbackDirectories`.
    static func locate(executable: String, searchPath: String, homeDirectory: String = NSHomeDirectory()) -> URL? {
        let directories = searchPath.split(separator: ":").map(String.init)
            + fallbackDirectories(homeDirectory: homeDirectory)
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// What Add says when `locate` finds no `executable`.
    static func notFoundMessage(executable: String) -> String {
        "\(executable) was not found on the login shell's PATH (nor in ~/.local/bin, ~/.claude/local, ~/.bun/bin, /opt/homebrew/bin or /usr/local/bin)."
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
            return RunOutcome(status: -1, output: "\(executable.lastPathComponent) did not finish in \(Int(timeout)) s")
        }
        return RunOutcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The environment a CLI's `mcp add` runs with from Settings: the
    /// login shell's, as this run captured it in full (the last run's saved
    /// copy keeps only a few variables, never `PI_CODING_AGENT_DIR`), else
    /// Cherry's own. Blocks while the shell runs: off the main thread.
    static func loginEnvironment() async -> [String: String] {
        await Task.detached {
            HostedSessionLoginEnvironment.shared.resolve(retryingNow: true)?.environment
                ?? ProcessInfo.processInfo.environment
        }.value
    }

    /// `<cli> mcp add` as Settings runs it: the CLI from `environment`'s
    /// PATH (the login shell's), in that environment.
    static func register(_ harness: MCPHarness, serverName: String, helperPath: String, environment: [String: String]) async -> RunOutcome {
        guard let executable = locate(
            executable: harness.executableName,
            searchPath: environment["PATH"] ?? "",
            homeDirectory: environment["HOME"] ?? NSHomeDirectory()
        ) else {
            return RunOutcome(status: -1, output: notFoundMessage(executable: harness.executableName))
        }
        return await run(
            executable: executable,
            arguments: harness.addArguments(serverName: serverName, helperPath: helperPath),
            environment: environment
        )
    }
}

/// Pi's registration of Cherry MCP (a Pi agent's page in Settings › Agents
/// & MCP, and that page's Connect other agent CLIs): `pi mcp add <name>
/// --exposure direct -- <CherryMCP>`, run only when the user clicks Add
/// (Pi writes its own `mcp.json`; Cherry never edits it), and a read-only
/// look at Pi's global `mcp.json` to say whether it is there. `direct`
/// exposure gives the model Cherry's tools themselves (Pi's default,
/// `codemode`, hides them behind a script tool). Pi passes its whole
/// environment to MCP servers, so CherryMCP sees the tab's
/// `CHERRY_PROCESS_ID`.
enum PiMCPRegistration {
    typealias RunOutcome = MCPCLIRegistration.RunOutcome

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

    /// The environment `pi` runs with from Settings
    /// (`MCPCLIRegistration.loginEnvironment`): the login shell's, which is
    /// where a `PI_CODING_AGENT_DIR` is set.
    static func loginEnvironment() async -> [String: String] {
        await MCPCLIRegistration.loginEnvironment()
    }

    /// `pi mcp add` as Settings runs it: `pi` from `environment`'s PATH
    /// (the login shell's: its node or bun needs it), in that environment,
    /// which is also where Pi finds its agent directory.
    static func register(serverName: String, helperPath: String, environment: [String: String]) async -> RunOutcome {
        await MCPCLIRegistration.register(.pi, serverName: serverName, helperPath: helperPath, environment: environment)
    }
}

/// Pi's state on a Pi agent's page (and in Agents & MCP's Connect other
/// agent CLIs). Pi's settings are read where `pi` itself reads them: its
/// agent directory as the environment `pi` runs with names it
/// (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`).
@MainActor
final class PiMCPRegistrationModel: ObservableObject {
    typealias Runner = @Sendable (_ serverName: String, _ helperPath: String, _ environment: [String: String]) async -> PiMCPRegistration.RunOutcome
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    let serverName: String
    let helperPath: String?
    /// Fixed for tests; nil: from the environment `pi` runs with.
    private let fixedAgentDirectory: URL?
    private let environment: EnvironmentProvider
    private let runner: Runner

    @Published private(set) var status: PiMCPRegistration.Status = .notRegistered
    /// Pi's settings were read at least once.
    @Published private(set) var hasChecked = false
    /// The agent directory last read.
    @Published private(set) var agentDirectory: URL?
    @Published private(set) var isRunning = false
    /// What the last Add said (Pi's output, or why it failed).
    @Published private(set) var message: String?
    @Published private(set) var lastRunFailed = false

    init(
        serverName: String = CherryAppIdentity.current.urlScheme,
        helperPath: String? = MCPInstallCommandBuilder.helperPath,
        agentDirectory: URL? = nil,
        environment: @escaping EnvironmentProvider = { await PiMCPRegistration.loginEnvironment() },
        runner: @escaping Runner = { await PiMCPRegistration.register(serverName: $0, helperPath: $1, environment: $2) }
    ) {
        self.serverName = serverName
        self.helperPath = helperPath
        self.fixedAgentDirectory = agentDirectory
        self.environment = environment
        self.runner = runner
    }

    /// Reads Pi's mcp.json (never writes it), off the main thread.
    func refresh() async {
        await refresh(environment: await environment())
    }

    private func refresh(environment: [String: String]) async {
        let directory = fixedAgentDirectory ?? PiMCPRegistration.agentDirectory(
            environment: environment,
            homeDirectory: environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
        )
        agentDirectory = directory
        guard let helperPath else {
            status = .notRegistered
            hasChecked = true
            return
        }
        let serverName = serverName
        status = await Task.detached {
            PiMCPRegistration.status(serverName: serverName, helperPath: helperPath, agentDirectory: directory)
        }.value
        hasChecked = true
    }

    /// Runs `pi mcp add` (only ever from the user's click), in the
    /// environment its status is read with.
    func register() async {
        guard let helperPath, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let environment = await environment()
        let outcome = await runner(serverName, helperPath, environment)
        lastRunFailed = outcome.status != 0
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        message = output.isEmpty ? (lastRunFailed ? "pi exited with status \(outcome.status)." : nil) : output
        await refresh(environment: environment)
    }

    var statusText: String {
        guard hasChecked else { return "Reading Pi's MCP settings…" }
        switch status {
        case .registered: return "Registered with Pi (direct exposure)."
        case .differs(let what): return "Pi has a \(serverName) server, but \(what)."
        case .notRegistered: return "Not registered with Pi."
        case .unreadable(let why): return "Pi's MCP settings could not be read: \(why)."
        }
    }
}

/// Add to Claude Code or Add to Codex on an agent's page: what the last
/// Add did. Nothing is read before it (Cherry reads neither CLI's
/// settings, and `claude mcp list` would start every server to check it),
/// so it is "Not checked" until a click runs `mcp add`, then "Added" or
/// "Failed" with the CLI's output (Claude Code's "already exists"
/// included). Pi's is `PiMCPRegistrationModel`, which reads Pi's settings.
@MainActor
final class MCPCLIRegistrationModel: ObservableObject {
    enum Status: Equatable {
        case notChecked
        case added
        case failed
    }

    typealias Runner = @Sendable (_ serverName: String, _ helperPath: String, _ environment: [String: String]) async -> MCPCLIRegistration.RunOutcome
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    let harness: MCPHarness
    let serverName: String
    let helperPath: String?
    private let environment: EnvironmentProvider
    private let runner: Runner

    @Published private(set) var status: Status = .notChecked
    @Published private(set) var isRunning = false
    /// What the last Add printed, or why it failed.
    @Published private(set) var message: String?

    /// `runner`: nil runs the CLI (`MCPCLIRegistration.register`); tests
    /// pass a stand-in.
    init(
        harness: MCPHarness,
        serverName: String = CherryAppIdentity.current.urlScheme,
        helperPath: String? = MCPInstallCommandBuilder.helperPath,
        environment: @escaping EnvironmentProvider = { await MCPCLIRegistration.loginEnvironment() },
        runner: Runner? = nil
    ) {
        self.harness = harness
        self.serverName = serverName
        self.helperPath = helperPath
        self.environment = environment
        self.runner = runner ?? { serverName, helperPath, environment in
            await MCPCLIRegistration.register(harness, serverName: serverName, helperPath: helperPath, environment: environment)
        }
    }

    /// Runs `<cli> mcp add` (only ever from the user's click) in the login
    /// shell's environment.
    func register() async {
        guard let helperPath, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let outcome = await runner(serverName, helperPath, await environment())
        let failed = outcome.status != 0
        status = failed ? .failed : .added
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        message = output.isEmpty ? (failed ? "\(harness.executableName) exited with status \(outcome.status)." : nil) : output
    }

    var statusText: String {
        switch status {
        case .notChecked: "Not checked"
        case .added: "Added"
        case .failed: "Failed"
        }
    }
}

/// One registration model per agent CLI for the app's life (made when an
/// agent's page first needs one), so what Add did stays across page
/// switches and window closes, and agents that run the same CLI (two
/// Claude agents) share it. Tests make their own, never `shared`.
@MainActor
final class MCPRegistrations {
    static let shared = MCPRegistrations()

    let claude: MCPCLIRegistrationModel
    let codex: MCPCLIRegistrationModel
    let pi: PiMCPRegistrationModel

    init(
        claude: MCPCLIRegistrationModel = MCPCLIRegistrationModel(harness: .claude),
        codex: MCPCLIRegistrationModel = MCPCLIRegistrationModel(harness: .codex),
        pi: PiMCPRegistrationModel = PiMCPRegistrationModel()
    ) {
        self.claude = claude
        self.codex = codex
        self.pi = pi
    }

    /// Claude Code's or Codex's; nil for Pi, whose model is `pi`.
    func cliModel(for harness: MCPHarness) -> MCPCLIRegistrationModel? {
        switch harness {
        case .claude: claude
        case .codex: codex
        case .pi: nil
        }
    }
}
