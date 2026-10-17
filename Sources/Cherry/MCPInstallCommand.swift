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
    /// this user, Codex's, and Pi's with deferred exposure
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
    /// arguments, each word that is not plain (`isPlainWord`) single-quoted,
    /// and the helper (the last word) always quoted; nil names CherryMCP
    /// by its name, for an app whose path is not known.
    func addCommand(serverName: String, helperPath: String?) -> String {
        let arguments = addArguments(serverName: serverName, helperPath: helperPath ?? "CherryMCP").dropLast()
        let helper = helperPath.map(ShellQuoting.singleQuoted) ?? "CherryMCP"
        return ([executableName] + arguments.map(Self.shownWord) + [helper]).joined(separator: " ")
    }

    /// `word` as a copied command shows it: as it is when it is plain,
    /// else single-quoted.
    static func shownWord(_ word: String) -> String {
        isPlainWord(word) ? word : ShellQuoting.singleQuoted(word)
    }

    /// Whether a shell (sh, bash, zsh, fish) reads `word` back unchanged
    /// without quotes: letters, digits and `-_./:=@%+,` only, and no `=`
    /// first (zsh expands `=name` to the path of the command `name`).
    static func isPlainWord(_ word: String) -> Bool {
        !word.isEmpty && !word.hasPrefix("=") && word.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_./:=@%+,".unicodeScalars.contains($0)
        }
    }

    /// The CLI as Cherry starts it with Cherry MCP on its command line
    /// (`AgentMCPLaunch`: Claude Code, Codex and Pi all have one).
    var launchCLI: AgentMCPLaunch.CLI? {
        AgentMCPLaunch.CLI.allCases.first { $0.brand == brand }
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
            command: harness.addCommand(serverName: identity.urlScheme, helperPath: helperPath)
        )
    }
}

/// Running an agent CLI on This Mac for Cherry MCP (Connect Agents to
/// Cherry…, Connect This Agent and an agent's page in Settings › Agents &
/// MCP; `AgentConnections.swift`): where the CLI is, and its own `mcp add`
/// (or Claude Code's `mcp remove`, Codex's `mcp get --json`), in the login
/// shell's environment, where the CLI and what it runs on (node, bun) are
/// found. Each CLI writes its own settings; Cherry never edits them, and
/// runs what writes them only after the user confirmed it.
enum MCPCLIRegistration {
    struct RunOutcome: Equatable, Sendable {
        var status: Int32
        var output: String
    }

    /// Where an executable is, in the environment it runs with.
    typealias Locator = @Sendable (_ executable: String, _ environment: [String: String]) -> URL?
    /// What `<path> --version` gives in an environment; `asksAgain` runs
    /// it even when its answer is known (`AgentCLIVersions.answer`).
    typealias VersionAnswerer = @Sendable (_ path: String, _ environment: [String: String], _ asksAgain: Bool) async -> AgentCLIVersions.VersionAnswer

    /// The app's CLIs: on the environment's PATH, then where installers put
    /// them (`locate`).
    static let appLocator: Locator = { executable, environment in
        locate(
            executable: executable,
            searchPath: environment["PATH"] ?? "",
            homeDirectory: environment["HOME"] ?? NSHomeDirectory()
        )
    }

    /// The app's versions (`AgentCLIVersions.shared`, which keeps them for
    /// this run).
    static let appAnswerer: VersionAnswerer = { path, environment, asksAgain in
        await AgentCLIVersions.shared.answer(path, environment: environment, asksAgain: asksAgain)
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
    /// `fallbackDirectories` (nil: `fallbackDirectories(homeDirectory:)`;
    /// a test names its own, so it never finds a real CLI there).
    static func locate(
        executable: String,
        searchPath: String,
        homeDirectory: String = NSHomeDirectory(),
        fallbackDirectories: [String]? = nil
    ) -> URL? {
        let directories = searchPath.split(separator: ":").map(String.init)
            + (fallbackDirectories ?? Self.fallbackDirectories(homeDirectory: homeDirectory))
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `fallbackDirectories` as a row names them, `~` the home folder:
    /// "~/.local/bin, ~/.claude/local, …, /opt/homebrew/bin or /usr/local/bin".
    static var shownFallbackDirectories: String {
        let directories = fallbackDirectories(homeDirectory: "~")
        guard directories.count > 1 else { return directories.first ?? "" }
        return directories.dropLast().joined(separator: ", ") + " or " + directories[directories.count - 1]
    }

    /// What a row says when `locate` finds no `executable`.
    static func notFoundMessage(executable: String) -> String {
        "\(executable) was not found on the login shell's PATH (nor in \(shownFallbackDirectories))."
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

    /// The environment a CLI runs with for Cherry MCP: the login shell's,
    /// as this run captured it in full (the last run's saved copy keeps
    /// only a few variables, never `PI_CODING_AGENT_DIR`, `CODEX_HOME` or
    /// `CLAUDE_CONFIG_DIR`), else Cherry's own. Blocks while the shell
    /// runs: off the main thread.
    static func loginEnvironment() async -> [String: String] {
        await Task.detached {
            HostedSessionLoginEnvironment.shared.resolve(retryingNow: true)?.environment
                ?? ProcessInfo.processInfo.environment
        }.value
    }

    /// What a run printed, as a row shows it: trimmed, or why it said
    /// nothing when it failed.
    static func shownOutput(_ outcome: RunOutcome, executable: String) -> String? {
        let output = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.isEmpty else { return output }
        return outcome.status == 0 ? nil : "\(executable) exited with status \(outcome.status)."
    }
}

/// Pi's registration of Cherry MCP (Connect Agents to Cherry…, Connect
/// This Agent, a Pi agent's page in Settings › Agents & MCP and that page's
/// Connect other agent CLIs): `pi mcp add <name> --exposure deferred
/// --description <…> -- <CherryMCP>`, run only after the user confirmed it
/// (Pi writes its own `mcp.json`; Cherry never edits it), and a read-only
/// look at Pi's global `mcp.json` to say what Pi has there.
/// Nothing runs `pi mcp` before `pi --version` says the Pi has MCP
/// (`minimumVersion`): an older Pi takes `mcp add …` as prompts for its
/// model. `deferred` exposure gives the model Cherry's tools through Pi's
/// tool search, when it needs them; `direct` sends all of them with every
/// request, and Pi's default, `codemode`, hides them behind a script tool.
/// Pi passes its whole environment to MCP servers, so CherryMCP sees the
/// tab's `CHERRY_PROCESS_ID`.
enum PiMCPRegistration {
    typealias RunOutcome = MCPCLIRegistration.RunOutcome
    typealias Locator = MCPCLIRegistration.Locator
    typealias VersionAnswerer = MCPCLIRegistration.VersionAnswerer

    /// The first Pi Cherry connects: `pi mcp add --description`, Pi's
    /// `mcp_servers` prompt section, and deferred servers that no longer
    /// hold up the first prompt all came in 0.99.2 (MCP itself in 0.99.0).
    static let minimumVersion = AgentCLIVersion(major: 0, minor: 99, patch: 2)

    /// What Pi's `mcp_servers` prompt section says about Cherry's server
    /// (Pi shows at most 250 characters of it), the same in Cherry's Pi
    /// extension: it names the task tools, which Pi's tool search ranks
    /// badly (the extension also declares them directly, `PiMCPExtension`).
    static let serverDescription = "Cherry, the terminal app this Pi runs in: its tabs, agents, waits and ports. Workers: spawn_agent with task, then wait_for_tasks and get_task. Given a Cherry task: get_my_task, then report_result. Load its tools with tool_search."

    /// How Pi gives the model a server's tools (its entry's `exposure`), as
    /// the status reads them.
    enum Exposure: String, Sendable {
        /// Through Pi's tool search, when the model needs them.
        case deferred
        /// All of them with every request.
        case direct
    }

    /// What Pi's `mcp.json` has under the server's name, per `status`.
    enum EntryStatus: Equatable {
        case notRegistered
        /// This app's CherryMCP, with no arguments.
        case connected(Exposure)
        /// This app's CherryMCP with another exposure (`codemode`, the
        /// default when it has none, or `hidden`).
        case toolsHidden(exposure: String)
        /// `"enabled": false`.
        case turnedOff
        /// Another CherryMCP (or anything else); `runs`: it is an
        /// executable file.
        case otherHelper(path: String, runs: Bool)
        /// This app's CherryMCP with arguments, or no command: what it runs.
        case otherArguments(line: String)
        /// Pi's mcp.json could not be read as a JSON object.
        case unreadable(String)
    }

    /// Pi on this Mac, as Settings shows it: whether it is there, its
    /// version, and, on a Pi with MCP, what its `mcp.json` has.
    enum State: Equatable {
        case checking
        case notInstalled
        /// `--version` printed no version Cherry knows on its standard
        /// output, nor an older one on its standard error: what it printed
        /// on its standard output.
        case unknownVersion(path: String, output: String)
        /// `--version` did not run, failed or did not finish in time.
        case noAnswer(path: String)
        /// A Pi older than `minimumVersion` (as its standard output says,
        /// else its standard error: Pi 0.62.0 without a terminal): no `pi
        /// mcp` runs.
        case withoutMCP(AgentCLIVersion)
        case notConnected(AgentCLIVersion)
        case connected(AgentCLIVersion, Exposure)
        case toolsHidden(AgentCLIVersion, String)
        case turnedOff(AgentCLIVersion)
        case otherHelper(AgentCLIVersion, path: String, runs: Bool)
        case otherArguments(AgentCLIVersion, line: String)
        case unreadable(AgentCLIVersion, String)

        /// A Pi with MCP, whose `mcp.json` says `entry`.
        init(version: AgentCLIVersion, entry: EntryStatus) {
            switch entry {
            case .notRegistered: self = .notConnected(version)
            case .connected(let exposure): self = .connected(version, exposure)
            case .toolsHidden(let exposure): self = .toolsHidden(version, exposure)
            case .turnedOff: self = .turnedOff(version)
            case .otherHelper(let path, let runs): self = .otherHelper(version, path: path, runs: runs)
            case .otherArguments(let line): self = .otherArguments(version, line: line)
            case .unreadable(let why): self = .unreadable(version, why)
            }
        }
    }

    /// `pi mcp add`'s arguments: the server, deferred, its description, then
    /// the helper after `--` (Pi passes what follows to it as it is). Pi
    /// replaces a server of the same name, so this also re-registers one.
    static func addArguments(serverName: String, helperPath: String) -> [String] {
        ["mcp", "add", serverName, "--exposure", Exposure.deferred.rawValue, "--description", serverDescription, "--", helperPath]
    }

    /// Pi's global agent directory: `PI_CODING_AGENT_DIR`, else `~/.pi/agent`.
    static func agentDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: expandingHome(configured, homeDirectory: homeDirectory), isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    /// What Pi's `mcp.json` in `agentDirectory` has under `serverName` (or a
    /// name Pi takes for the same server: `-` and `_` alike), compared with
    /// this app's helper: its `enabled`, `command`, `args`, `exposure` and,
    /// when deferred, `description` (its `env` and `timeout` are not). Reads
    /// the file only.
    static func status(serverName: String, helperPath: String, agentDirectory: URL) -> EntryStatus {
        let file = agentDirectory.appendingPathComponent("mcp.json", isDirectory: false)
        guard let data = FileManager.default.contents(atPath: file.path) else { return .notRegistered }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("\(file.path) is not a JSON object")
        }
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        let namespace = serverNamespace(serverName)
        guard let server = (servers[serverName] ?? servers.first { serverNamespace($0.key) == namespace }?.value) as? [String: Any] else {
            return .notRegistered
        }
        if server["enabled"] as? Bool == false { return .turnedOff }
        let arguments = (server["args"] as? [Any] ?? []).map { "\($0)" }
        guard let command = server["command"] as? String else {
            return .otherArguments(line: server["url"] as? String ?? "nothing: it has no command")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded = expandingHome(command, homeDirectory: home)
        guard standardized(expanded) == standardized(helperPath) else {
            return .otherHelper(path: command, runs: FileManager.default.isExecutableFile(atPath: expanded))
        }
        guard arguments.isEmpty else {
            return .otherArguments(line: ([command] + arguments).map(MCPHarness.shownWord).joined(separator: " "))
        }
        switch server["exposure"] as? String ?? "codemode" {
        case Exposure.deferred.rawValue:
            // Pi's prompt lists a deferred server with its description,
            // where the model learns of the task tools: an older Cherry's,
            // or none, leaves them out (and the entry wins over the
            // extension's server, which declares them).
            let description = (server["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard description == serverDescription else {
                let which = description.isEmpty ? "no description" : "another description"
                return .otherArguments(line: "\(MCPHarness.shownWord(command)) with \(which)")
            }
            return .connected(.deferred)
        case Exposure.direct.rawValue: return .connected(.direct)
        case let exposure: return .toolsHidden(exposure: exposure)
        }
    }

    /// A server name as Pi compares it: `-` and `_` are the same.
    private static func serverNamespace(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    /// `path` with a leading `~` or `~/` as `homeDirectory`.
    private static func expandingHome(_ path: String, homeDirectory: URL) -> String {
        path == "~" ? homeDirectory.path
            : path.hasPrefix("~/") ? homeDirectory.path + String(path.dropFirst(1)) : path
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

    /// The app's `pi`: on the environment's PATH, then where installers put
    /// it (`MCPCLIRegistration.locate`).
    static let appLocator: Locator = MCPCLIRegistration.appLocator

    /// The app's versions (`AgentCLIVersions.shared`).
    static let appAnswerer: VersionAnswerer = MCPCLIRegistration.appAnswerer

    /// `pi mcp add` as a confirmed plan runs it (`PiMCPRegistrationModel.perform`),
    /// the only code that runs `pi mcp`:
    /// `pi` as `locate` finds it in `environment` (the login shell's: its
    /// node or bun needs it, and Pi finds its agent directory there), asked
    /// its version first (`answer`), now and not from what is known (a
    /// shim stays the same file while the Pi it runs changes); only a Pi of
    /// `minimumVersion` or later runs `addArguments`, the same file that
    /// answered, in that environment. Otherwise nothing runs, and the
    /// outcome says why (a version only its standard error names, as Pi
    /// 0.62.0's, only to name an older Pi).
    static func register(
        serverName: String,
        helperPath: String,
        environment: [String: String],
        locate: Locator = appLocator,
        answer: VersionAnswerer = appAnswerer
    ) async -> RunOutcome {
        guard let pi = locate("pi", environment) else {
            return RunOutcome(status: -1, output: MCPCLIRegistration.notFoundMessage(executable: "pi"))
        }
        switch await answer(pi.path, environment, true) {
        case .version(let version) where version >= minimumVersion:
            return await MCPCLIRegistration.run(
                executable: pi,
                arguments: addArguments(serverName: serverName, helperPath: helperPath),
                environment: environment
            )
        case .version(let version):
            return RunOutcome(status: -1, output: older(version))
        case .versionOnErrorOutput(let version, _) where version < minimumVersion:
            return RunOutcome(status: -1, output: older(version))
        case .noVersion(let output), .versionOnErrorOutput(_, let output):
            return RunOutcome(
                status: -1,
                output: "\(pi.path) --version printed “\(output)”; Cherry connects only a Pi it knows has MCP (\(minimumVersion) or later)."
            )
        case .noAnswer:
            return RunOutcome(status: -1, output: "\(pi.path) --version did not answer.")
        }
        func older(_ version: AgentCLIVersion) -> String {
            "\(pi.path) is Pi \(version), which has no MCP: update Pi to \(minimumVersion) or later."
        }
    }
}

/// Pi's state, as Connect Agents to Cherry…, Connect This Agent, a Pi
/// agent's page and Agents & MCP's Connect other agent CLIs render it
/// (`AgentSettingsPage.piRow`). `refresh` finds `pi`, asks its version
/// (`--version`, nothing else: never `pi mcp list`, which starts every
/// server), and only on a Pi with MCP reads its settings where `pi` itself
/// reads them: its agent directory as the environment `pi` runs with names
/// it (`PI_CODING_AGENT_DIR`, else `~/.pi/agent`). `perform` runs a plan
/// the user confirmed through the gated `PiMCPRegistration.register`.
@MainActor
final class PiMCPRegistrationModel: ObservableObject, AgentConnectionModel {
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    let serverName: String
    let helperPath: String?
    /// Fixed for tests; nil: from the environment `pi` runs with.
    private let fixedAgentDirectory: URL?
    private let environment: EnvironmentProvider
    private let locate: PiMCPRegistration.Locator
    private let answer: PiMCPRegistration.VersionAnswerer

    @Published private(set) var state: PiMCPRegistration.State = .checking
    /// The `pi` last found.
    @Published private(set) var executable: URL?
    /// The agent directory last read.
    @Published private(set) var agentDirectory: URL?
    @Published private(set) var isRunning = false
    /// What the last run said (Pi's output, or why it failed).
    @Published private(set) var message: String?
    @Published private(set) var lastRunFailed = false
    @Published private(set) var lastRunSucceeded = false

    var harness: MCPHarness { .pi }

    /// `locate` and `answer`: the app's unless a test passes its own (an
    /// injected PATH with no fallback directories, its own versions).
    init(
        serverName: String = CherryAppIdentity.current.urlScheme,
        helperPath: String? = MCPInstallCommandBuilder.helperPath,
        agentDirectory: URL? = nil,
        environment: @escaping EnvironmentProvider = { await PiMCPRegistration.loginEnvironment() },
        locate: @escaping PiMCPRegistration.Locator = PiMCPRegistration.appLocator,
        answer: @escaping PiMCPRegistration.VersionAnswerer = PiMCPRegistration.appAnswerer
    ) {
        self.serverName = serverName
        self.helperPath = helperPath
        self.fixedAgentDirectory = agentDirectory
        self.environment = environment
        self.locate = locate
        self.answer = answer
    }

    /// Finds `pi`, asks its version and, on a Pi with MCP, reads its
    /// mcp.json (never writes it), off the main thread. `asksAgain` (Check
    /// Again) runs `pi --version` even when its answer is known.
    func refresh(asksAgain: Bool = false) async {
        await refresh(environment: await environment(), asksAgain: asksAgain)
    }

    private func refresh(environment: [String: String], asksAgain: Bool = false) async {
        let directory = fixedAgentDirectory ?? PiMCPRegistration.agentDirectory(
            environment: environment,
            homeDirectory: environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
        )
        agentDirectory = directory
        guard let pi = locate("pi", environment) else {
            executable = nil
            state = .notInstalled
            return
        }
        executable = pi
        let version: AgentCLIVersion
        switch await answer(pi.path, environment, asksAgain) {
        case .version(let answered):
            version = answered
        case .versionOnErrorOutput(let named, let output):
            // Named only on its standard error: only to say Update Pi to an
            // older one; never its version, so nothing reads its settings.
            state = named < PiMCPRegistration.minimumVersion
                ? .withoutMCP(named)
                : .unknownVersion(path: pi.path, output: output)
            return
        case .noVersion(let output):
            state = .unknownVersion(path: pi.path, output: output)
            return
        case .noAnswer:
            state = .noAnswer(path: pi.path)
            return
        }
        guard version >= PiMCPRegistration.minimumVersion else {
            state = .withoutMCP(version)
            return
        }
        guard let helperPath else {
            state = .notConnected(version)
            return
        }
        let serverName = serverName
        let entry = await Task.detached {
            PiMCPRegistration.status(serverName: serverName, helperPath: helperPath, agentDirectory: directory)
        }.value
        state = PiMCPRegistration.State(version: version, entry: entry)
    }

    func row(connectsAtLaunch: Bool) -> AgentConnection.Row {
        AgentConnection.row(pi: state, serverName: serverName, connectsAtLaunch: connectsAtLaunch)
    }

    /// Connect, Make Deferred, Re-register and Connect Again all run the
    /// same `pi mcp add` (Pi replaces an entry of the name), with the `pi`
    /// last found. Built whatever the state: `perform` asks its version
    /// again before anything runs.
    func plan(for action: AgentConnection.Action) -> AgentConnection.Plan? {
        guard let executable, let helperPath else { return nil }
        let file = (agentDirectory ?? PiMCPRegistration.agentDirectory()).appendingPathComponent("mcp.json", isDirectory: false)
        return AgentConnection.plan(
            .pi,
            action: action,
            executable: executable,
            serverName: serverName,
            helperPath: helperPath,
            writes: "Pi writes \(file.path).",
            replaces: AgentConnection.replaces(pi: state, serverName: serverName)
        )
    }

    /// Runs a plan the user confirmed: the gated `pi mcp add`
    /// (`PiMCPRegistration.register`) of the plan's `pi`, asked its version
    /// again first, in the environment the state is read with, then a fresh
    /// look.
    func perform(_ plan: AgentConnection.Plan) async {
        guard plan.harness == .pi, let pi = plan.steps.first?.executable, let helperPath, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let environment = await environment()
        let outcome = await PiMCPRegistration.register(
            serverName: serverName, helperPath: helperPath, environment: environment,
            locate: { _, _ in pi }, answer: answer
        )
        lastRunFailed = outcome.status != 0
        lastRunSucceeded = !lastRunFailed
        message = MCPCLIRegistration.shownOutput(outcome, executable: "pi")
        await refresh(environment: environment)
    }
}

/// Claude Code's or Codex's state on This Mac, as Connect Agents to
/// Cherry…, Connect This Agent and an agent's page render it
/// (`AgentConnection.row`). `refresh` finds the CLI, asks its version, and
/// reads what it has: Claude Code's settings file
/// (`ClaudeMCPRegistration.settingsFile`, off the main thread), or `codex
/// mcp get --json` on a Codex that has it; never `claude mcp list`,
/// `claude mcp get` or `codex mcp list`. `perform` runs a plan the user
/// confirmed: Codex's `mcp add` (which replaces), Claude Code's `mcp add`,
/// or its `mcp remove --scope user` then `mcp add`. Pi's is
/// `PiMCPRegistrationModel`.
@MainActor
final class MCPCLIRegistrationModel: ObservableObject, AgentConnectionModel {
    typealias EnvironmentProvider = @Sendable () async -> [String: String]
    /// Runs one step in an environment, killed after a timeout.
    typealias Runner = @Sendable (
        _ step: AgentConnection.Step, _ environment: [String: String], _ timeout: TimeInterval
    ) async -> MCPCLIRegistration.RunOutcome
    /// The contents of a file, nil when there is none.
    typealias FileReader = @Sendable (_ path: String) -> Data?

    let harness: MCPHarness
    let serverName: String
    let helperPath: String?
    private let environment: EnvironmentProvider
    private let locate: MCPCLIRegistration.Locator
    private let answer: MCPCLIRegistration.VersionAnswerer
    private let readFile: FileReader
    private let run: Runner
    /// The latest `refresh`: an older one's answer is dropped.
    private var refreshGeneration = 0

    @Published private(set) var state: AgentConnection.State = .checking
    /// The CLI last found.
    @Published private(set) var executable: URL?
    /// The file the CLI writes its registration to: Claude Code's
    /// `.claude.json` (or its legacy `.config.json`), Codex's `config.toml`.
    @Published private(set) var settingsFile: URL?
    @Published private(set) var isRunning = false
    /// What the last run printed, or why it failed.
    @Published private(set) var message: String?
    @Published private(set) var lastRunFailed = false
    @Published private(set) var lastRunSucceeded = false

    /// `locate`, `answer`, `readFile` and `run`: the app's unless a test
    /// passes its own (an injected PATH with no fallback directories, its
    /// own versions, stand-in CLIs).
    init(
        harness: MCPHarness,
        serverName: String = CherryAppIdentity.current.urlScheme,
        helperPath: String? = MCPInstallCommandBuilder.helperPath,
        environment: @escaping EnvironmentProvider = { await MCPCLIRegistration.loginEnvironment() },
        locate: @escaping MCPCLIRegistration.Locator = MCPCLIRegistration.appLocator,
        answer: @escaping MCPCLIRegistration.VersionAnswerer = MCPCLIRegistration.appAnswerer,
        readFile: @escaping FileReader = { FileManager.default.contents(atPath: $0) },
        run: @escaping Runner = { step, environment, timeout in
            await MCPCLIRegistration.run(executable: step.executable, arguments: step.arguments, environment: environment, timeout: timeout)
        }
    ) {
        precondition(harness != .pi, "Pi's model is PiMCPRegistrationModel: only PiMCPRegistration.register runs pi mcp")
        self.harness = harness
        self.serverName = serverName
        self.helperPath = helperPath
        self.environment = environment
        self.locate = locate
        self.answer = answer
        self.readFile = readFile
        self.run = run
    }

    /// Finds the CLI, asks its version (`asksAgain`: even when its answer
    /// is known) and reads what its settings have.
    func refresh(asksAgain: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let environment = await environment()
        let reading = await read(environment: environment, asksAgain: asksAgain)
        guard generation == refreshGeneration else { return }
        executable = reading.executable
        settingsFile = reading.settingsFile
        state = reading.state
    }

    private struct Reading {
        var state: AgentConnection.State
        var executable: URL?
        var settingsFile: URL?
    }

    private func read(environment: [String: String], asksAgain: Bool) async -> Reading {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let searchPath = environment["PATH"] ?? ""
        var reading = Reading(
            state: .notInstalled,
            settingsFile: harness == .codex ? CodexMCPRegistration.settingsFile(environment: environment, homeDirectory: home) : nil
        )
        guard let executable = locate(harness.executableName, environment) else { return reading }
        reading.executable = executable
        let version: AgentCLIVersion
        switch await answer(executable.path, environment, asksAgain) {
        case .version(let answered):
            version = answered
        case .noVersion(let output), .versionOnErrorOutput(_, let output):
            reading.state = .unknownVersion(path: executable.path, output: output)
            return reading
        case .noAnswer:
            reading.state = .noAnswer(path: executable.path)
            return reading
        }
        switch harness {
        case .claude:
            switch ClaudeMCPRegistration.settingsFile(environment: environment, homeDirectory: home) {
            case .unusable(let why):
                reading.state = .unreadable(version, why)
            case .file(let file):
                reading.settingsFile = file
                guard let helperPath else {
                    reading.state = .notConnected(version)
                    break
                }
                let serverName = serverName
                let readFile = readFile
                let entry = await Task.detached {
                    ClaudeMCPRegistration.status(
                        serverName: serverName, helperPath: helperPath, file: file, data: readFile(file.path), searchPath: searchPath
                    )
                }.value
                reading.state = AgentConnection.State(version: version, entry: entry)
            }
        case .codex:
            guard version >= CodexMCPRegistration.readsSettingsFrom else {
                reading.state = .notChecked(version, "Cherry can't read Codex \(version)'s MCP settings.")
                break
            }
            guard let helperPath else {
                reading.state = .notConnected(version)
                break
            }
            let outcome = await run(
                AgentConnection.Step(executable: executable, arguments: CodexMCPRegistration.getArguments(serverName: serverName)),
                environment,
                CodexMCPRegistration.getTimeout
            )
            reading.state = AgentConnection.State(
                version: version,
                entry: CodexMCPRegistration.status(fromGet: outcome, helperPath: helperPath, searchPath: searchPath)
            )
        case .pi:
            break
        }
        return reading
    }

    func row(connectsAtLaunch: Bool) -> AgentConnection.Row {
        AgentConnection.row(harness, state: state, serverName: serverName, connectsAtLaunch: connectsAtLaunch)
    }

    /// What `action` runs with the CLI last found (`AgentConnection.plan`).
    func plan(for action: AgentConnection.Action) -> AgentConnection.Plan? {
        guard let executable, let helperPath else { return nil }
        let writes = settingsFile.map { "\(harness.productName) writes \($0.path)." }
            ?? "\(harness.productName) writes its own settings."
        return AgentConnection.plan(
            harness,
            action: action,
            executable: executable,
            serverName: serverName,
            helperPath: helperPath,
            writes: writes,
            replaces: AgentConnection.replaces(harness, state: state, serverName: serverName)
        )
    }

    /// Runs a plan the user confirmed, its steps in order in the login
    /// shell's environment, then reads the state again. The last step
    /// decides: what an earlier one printed (Claude Code's `remove` that
    /// found nothing) is shown only when the last one fails.
    func perform(_ plan: AgentConnection.Plan) async {
        guard plan.harness == harness, !plan.steps.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let environment = await environment()
        var earlier: [String] = []
        var outcome = MCPCLIRegistration.RunOutcome(status: 0, output: "")
        for (index, step) in plan.steps.enumerated() {
            if index > 0, let said = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                earlier.append(said)
            }
            outcome = await run(step, environment, 60)
        }
        lastRunFailed = outcome.status != 0
        lastRunSucceeded = !lastRunFailed
        let said = MCPCLIRegistration.shownOutput(outcome, executable: harness.executableName)
        message = lastRunFailed ? (earlier + [said].compactMap { $0 }).joined(separator: "\n") : said
        await refresh()
    }

    /// What Claude Code's settings for one of `projectRoots` (its local
    /// scope) run under the server's name, from the settings file last
    /// read; nil for Codex, or when there is none.
    func localEntry(projectRoots: [String]) async -> String? {
        guard harness == .claude, let file = settingsFile else { return nil }
        let serverName = serverName
        let readFile = readFile
        return await Task.detached {
            ClaudeMCPRegistration.localEntry(projectRoots: projectRoots, serverName: serverName, data: readFile(file.path))
        }.value
    }
}

/// One connection model per agent CLI for the app's life (made when a
/// surface first needs one), so what a run did stays across page switches
/// and sheets, and agents that run the same CLI (two Claude agents) share
/// it. Tests make their own, never `shared`.
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

    func model(for harness: MCPHarness) -> any AgentConnectionModel {
        cliModel(for: harness) ?? pi
    }

    /// Claude Code's, Codex's and Pi's, in the presets' order.
    var models: [any AgentConnectionModel] {
        [claude, codex, pi]
    }

    /// Runs plans the user confirmed, each with its CLI's model, one after
    /// the other.
    func perform(_ plans: [AgentConnection.Plan]) async {
        for plan in plans {
            await model(for: plan.harness).perform(plan)
        }
    }
}
