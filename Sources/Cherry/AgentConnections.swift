import CherryControl
import Foundation

// Connecting the agent CLIs on This Mac to Cherry MCP: Connect Agents to
// Cherry…, Connect This Agent to Cherry… and the Cherry MCP rows of
// Settings › Agents & MCP. What each CLI has is read with nothing that
// starts MCP servers or writes settings: Claude Code's settings file,
// `codex mcp get --json`, and Pi's `--version` and mcp.json; never `claude
// mcp list`, `claude mcp get` (which starts the server and rewrites the
// file), `codex mcp list` or `pi mcp list`. A CLI's `mcp add` (and Claude
// Code's `mcp remove` before a re-register) runs only after the user
// confirms the exact commands (`ConnectAgentsConfirmation`).

/// What an agent CLI has of Cherry MCP and what connecting it runs: the
/// states, plans and texts every surface shares.
enum AgentConnection {
    /// What a Claude Code or Codex registration has under the server's
    /// name, compared with this app's helper.
    enum EntryStatus: Equatable, Sendable {
        case notRegistered
        /// This app's CherryMCP as a stdio server, with no arguments.
        case connected
        /// Codex's `enabled = false`.
        case turnedOff
        /// Another CherryMCP (or anything else); `runs`: it is an
        /// executable file.
        case otherHelper(path: String, runs: Bool)
        /// This app's CherryMCP with arguments, or no stdio command: what
        /// it runs.
        case otherArguments(line: String)
        /// The settings could not be read: why.
        case unreadable(String)
    }

    /// Claude Code or Codex on This Mac, as its row shows it: whether it is
    /// there, its version, and what its settings have. Pi's is
    /// `PiMCPRegistration.State`.
    enum State: Equatable {
        case checking
        case notInstalled
        /// `--version` printed no version Cherry knows: what it printed.
        case unknownVersion(path: String, output: String)
        /// `--version` did not run, failed or did not finish in time.
        case noAnswer(path: String)
        case notConnected(AgentCLIVersion)
        case connected(AgentCLIVersion)
        case turnedOff(AgentCLIVersion)
        case otherHelper(AgentCLIVersion, path: String, runs: Bool)
        case otherArguments(AgentCLIVersion, line: String)
        case unreadable(AgentCLIVersion, String)
        /// A CLI whose settings Cherry can't read (a Codex before
        /// `CodexMCPRegistration.readsSettingsFrom`): what the row says.
        case notChecked(AgentCLIVersion, String)

        /// A CLI of `version` whose settings say `entry`.
        init(version: AgentCLIVersion, entry: EntryStatus) {
            switch entry {
            case .notRegistered: self = .notConnected(version)
            case .connected: self = .connected(version)
            case .turnedOff: self = .turnedOff(version)
            case .otherHelper(let path, let runs): self = .otherHelper(version, path: path, runs: runs)
            case .otherArguments(let line): self = .otherArguments(version, line: line)
            case .unreadable(let why): self = .unreadable(version, why)
            }
        }

        /// The CLI's version, when it printed one.
        var version: AgentCLIVersion? {
            switch self {
            case .checking, .notInstalled, .unknownVersion, .noAnswer:
                nil
            case .notConnected(let version), .connected(let version), .turnedOff(let version),
                 .otherHelper(let version, _, _), .otherArguments(let version, _), .unreadable(let version, _),
                 .notChecked(let version, _):
                version
            }
        }
    }

    /// A row's buttons; every one but Check Again runs a plan once the
    /// user confirms it.
    enum Action: String, CaseIterable, Hashable, Sendable {
        case checkAgain = "Check Again"
        case connect = "Connect"
        case connectAgain = "Connect Again"
        case reRegister = "Re-register"
        case makeDeferred = "Make Deferred"

        var title: String { rawValue }

        /// Whether it runs the CLI's `mcp add` (after the confirmation);
        /// Check Again only reads again.
        var registers: Bool { self != .checkAgain }
    }

    /// One command a plan runs: an executable and its arguments, with no
    /// shell between Cherry and the CLI.
    struct Step: Equatable, Sendable {
        var executable: URL
        var arguments: [String]
    }

    /// What connecting one CLI runs, as the confirmation shows it before
    /// anything runs.
    struct Plan: Equatable, Identifiable, Sendable {
        var harness: MCPHarness
        var action: Action
        var steps: [Step]
        /// Each step as a shell would run it: the located executable's path
        /// first, words quoted as `MCPHarness.addCommand` quotes them.
        var displayedCommands: [String]
        /// "Claude Code writes ~/.claude.json." (its path in full).
        var writes: String
        /// What it replaces, when the CLI has an entry of the name.
        var replaces: String?

        var id: MCPHarness { harness }
    }

    /// A CLI's row, as Connect Agents to Cherry…, Connect This Agent and the
    /// agent's page show it.
    struct Row: Equatable {
        var harness: MCPHarness
        /// The product and its version: "Claude Code 2.1.299".
        var title: String
        var status: String
        var style: SettingsStatusText.Style
        var dot: SettingsStatusDot.Tone
        /// The line under it: what the state means.
        var detail: String?
        var primaryAction: Action?
        /// In a `⋯` menu: Connect Again, for a registration that needs
        /// nothing.
        var menuActions: [Action] = []
        /// Whether Connect All runs its primary action (`connectAllPlans`).
        var joinsConnectAll = false
        /// What the agents Cherry starts get (`launchLine`).
        var launchLine: String
        /// False while the CLI is not found: the sheet lists it at its end.
        var isInstalled = true

        /// The action whose command the row shows to copy: its button's, or
        /// its menu's; nil while it has none that registers (a CLI not
        /// found, a version Cherry can't read, a Pi without MCP, which
        /// would take `pi mcp add …` as prompts for its model).
        var commandAction: Action? {
            ([primaryAction].compactMap { $0 } + menuActions).first(where: \.registers)
        }
    }

    /// `harness`'s row in `state`, `serverName` the name Cherry registers.
    @MainActor
    static func row(_ harness: MCPHarness, state: State, serverName: String, connectsAtLaunch: Bool) -> Row {
        let product = harness.productName
        let gray = (SettingsStatusText.Style.neutral, SettingsStatusDot.Tone.gray)
        let orange = (SettingsStatusText.Style.warning, SettingsStatusDot.Tone.orange)
        let green = (SettingsStatusText.Style.ok, SettingsStatusDot.Tone.green)
        func row(
            _ status: String,
            _ look: (SettingsStatusText.Style, SettingsStatusDot.Tone),
            _ detail: String?,
            _ action: Action? = nil,
            menu: [Action] = [],
            joinsConnectAll: Bool = false
        ) -> Row {
            Row(
                harness: harness,
                title: state.version.map { "\(product) \($0)" } ?? product,
                status: status,
                style: look.0,
                dot: look.1,
                detail: detail,
                primaryAction: action,
                menuActions: menu,
                joinsConnectAll: joinsConnectAll,
                launchLine: launchLine(harness, version: state.version, connectsAtLaunch: connectsAtLaunch, serverName: serverName),
                isInstalled: state != .notInstalled
            )
        }
        switch state {
        case .checking:
            return row("Checking…", gray, nil)
        case .notInstalled:
            return row("Not installed", gray, MCPCLIRegistration.notFoundMessage(executable: harness.executableName), .checkAgain)
        case .unknownVersion(let path, let output):
            return row("Unknown", orange, "\(path) --version printed “\(output)”.", .checkAgain)
        case .noAnswer(let path):
            return row("Unknown", orange, "\(path) --version did not answer.", .checkAgain)
        case .notConnected:
            return row(
                "Not connected", gray,
                "Connect adds Cherry MCP to \(product)'s settings, for sessions you start yourself.",
                .connect, joinsConnectAll: true
            )
        case .connected:
            return row("Connected", green, "\(product) runs this Cherry's MCP helper.", menu: [.connectAgain])
        case .turnedOff:
            return row(
                "Turned off", orange,
                "\(product)'s settings turn \(serverName) off. Connect replaces it with an enabled one.",
                .connect, joinsConnectAll: true
            )
        case .otherHelper(_, let path, runs: true):
            return row("Another Cherry", orange, "\(product)'s \(serverName) runs \(path). Re-register makes it this copy's.", .reRegister)
        case .otherHelper(_, let path, runs: false):
            return row(
                "Broken", orange, "\(product)'s \(serverName) runs \(path), which isn't there any more.",
                .reRegister, joinsConnectAll: true
            )
        case .otherArguments(_, let line):
            return row("Differs", orange, "\(product)'s \(serverName) runs \(line).", .reRegister)
        case .unreadable(_, let why):
            return row("Can't read", orange, why, .checkAgain)
        case .notChecked(_, let detail):
            return row("Not checked", gray, detail, .connect)
        }
    }

    /// Pi's row in `state`: its texts and buttons are a Pi agent's page's
    /// (`AgentSettingsPage.piRow`).
    @MainActor
    static func row(pi state: PiMCPRegistration.State, serverName: String, connectsAtLaunch: Bool) -> Row {
        let pi = AgentSettingsPage.piRow(for: state, serverName: serverName)
        let joinsConnectAll = switch state {
        case .notConnected, .turnedOff, .toolsHidden, .otherHelper(_, _, runs: false): true
        default: false
        }
        return Row(
            harness: .pi,
            title: state.version.map { "Pi \($0)" } ?? "Pi",
            status: pi.status,
            style: pi.style,
            dot: pi.dot,
            detail: pi.detail,
            primaryAction: pi.button.flatMap(Action.init(rawValue:)),
            menuActions: pi.menuButton.flatMap(Action.init(rawValue:)).map { [$0] } ?? [],
            joinsConnectAll: joinsConnectAll,
            launchLine: launchLine(.pi, version: state.version, connectsAtLaunch: connectsAtLaunch, serverName: serverName),
            isInstalled: state != .notInstalled
        )
    }

    /// What the agents Cherry starts of `harness` get: Cherry MCP on their
    /// command line (`AgentMCPLaunch`) while Connect agents Cherry starts
    /// is on and the CLI (`version`, when known) is new enough.
    static func launchLine(_ harness: MCPHarness, version: AgentCLIVersion?, connectsAtLaunch: Bool, serverName: String) -> String {
        let product = harness.productName
        let agents = "\(product) agents Cherry starts"
        guard let cli = harness.launchCLI else { return "\(agents): they use what is registered" }
        guard connectsAtLaunch else { return "\(agents): off in Settings" }
        let minimum = cli.minimumVersion
        if let version, version < minimum {
            return harness == .pi
                ? "\(agents): this Pi (\(version)) is older than \(minimum): they start without Cherry MCP"
                : "\(agents): this \(product) (\(version)) is older than \(minimum): they use what is registered"
        }
        return harness == .pi
            ? "\(agents): connected at launch (Pi \(minimum) or later); a \(serverName) entry in Pi's settings takes precedence"
            : "\(agents): connected at launch (\(minimum) or later)"
    }

    /// What follows a connect that worked: sessions read their MCP servers
    /// as they start.
    static func restartHint(_ harness: MCPHarness) -> String {
        harness == .pi
            ? "Pi sessions already open read their MCP servers when they start: type /reload in them, or restart the tab."
            : "Sessions already open read their MCP servers when they start: restart them."
    }

    // MARK: Plans

    /// What `action` runs for `harness`'s CLI at `executable`: one `mcp
    /// add` (Codex and Pi replace an entry of the name), or for Claude
    /// Code's Re-register and Connect Again `mcp remove --scope user`
    /// first (its `add` refuses a name it has). Nil for Check Again.
    static func plan(
        _ harness: MCPHarness,
        action: Action,
        executable: URL,
        serverName: String,
        helperPath: String,
        writes: String,
        replaces: String?
    ) -> Plan? {
        guard action.registers else { return nil }
        let arguments = harness == .claude && action != .connect
            ? ClaudeMCPRegistration.reRegisterSteps(serverName: serverName, helperPath: helperPath)
            : [harness.addArguments(serverName: serverName, helperPath: helperPath)]
        let steps = arguments.map { Step(executable: executable, arguments: $0) }
        return Plan(
            harness: harness,
            action: action,
            steps: steps,
            displayedCommands: steps.map { displayedCommand($0, helperPath: helperPath) },
            writes: writes,
            replaces: replaces
        )
    }

    /// `step` as a shell would run it, to read and copy: each word that is
    /// not plain single-quoted, and the helper always.
    static func displayedCommand(_ step: Step, helperPath: String) -> String {
        ([MCPHarness.shownWord(step.executable.path)] + step.arguments.map {
            $0 == helperPath ? ShellQuoting.singleQuoted($0) : MCPHarness.shownWord($0)
        }).joined(separator: " ")
    }

    /// What a Claude Code or Codex plan replaces in `state`.
    static func replaces(_ harness: MCPHarness, state: State, serverName: String) -> String? {
        let current = "It replaces \(harness.productName)'s current \(serverName)"
        switch state {
        case .connected: return "\(current), which runs this Cherry's MCP helper."
        case .turnedOff: return "\(current), which is turned off."
        case .otherHelper(_, let path, _): return "\(current), which runs \(path)."
        case .otherArguments(_, let line): return "\(current), which runs \(line)."
        case .notChecked: return "If \(harness.productName) has a \(serverName) already, it replaces it."
        default: return nil
        }
    }

    /// What a Pi plan replaces in `state`.
    static func replaces(pi state: PiMCPRegistration.State, serverName: String) -> String? {
        let current = "It replaces Pi's current \(serverName)"
        switch state {
        case .connected(_, .deferred): return "\(current), which runs this Cherry's MCP helper."
        case .connected(_, .direct): return "\(current), which runs this Cherry's MCP helper with direct exposure."
        case .toolsHidden(_, let exposure): return "\(current), whose exposure is \(exposure)."
        case .turnedOff: return "\(current), which is turned off."
        case .otherHelper(_, let path, _): return "\(current), which runs \(path)."
        case .otherArguments(_, let line): return "\(current), which runs \(line)."
        default: return nil
        }
    }

    /// Connect All's plans: each row whose state Connect All mends
    /// (`Row.joinsConnectAll`: not connected, turned off, tools hidden, a
    /// helper that is gone), with its primary action. Never a connected one
    /// (direct included), another Cherry's that runs, or one that differs:
    /// those are the user's choices, each with its own button.
    static func connectAllPlans(_ rows: [Row], plan: (MCPHarness, Action) -> Plan?) -> [Plan] {
        rows.compactMap { row in
            guard row.joinsConnectAll, let action = row.primaryAction else { return nil }
            return plan(row.harness, action)
        }
    }

    // MARK: The confirmation

    /// "Connect Claude Code to Cherry?", "Re-register Pi's Cherry MCP?", or
    /// for Connect All "Connect Claude Code and Pi to Cherry?".
    static func confirmationTitle(_ plans: [Plan]) -> String {
        guard plans.count == 1, let plan = plans.first else {
            return "Connect \(listed(plans.map(\.harness.productName))) to Cherry?"
        }
        let product = plan.harness.productName
        switch plan.action {
        case .checkAgain, .connect: return "Connect \(product) to Cherry?"
        case .connectAgain: return "Connect \(product) to Cherry again?"
        case .reRegister: return "Re-register \(product)'s Cherry MCP?"
        case .makeDeferred: return "Make \(product)'s Cherry MCP deferred?"
        }
    }

    static let confirmationLead = "Cherry will run:"

    /// What each plan writes and replaces, under the commands.
    static func confirmationNotes(_ plans: [Plan]) -> [String] {
        plans.map { ([$0.writes] + [$0.replaces].compactMap { $0 }).joined(separator: " ") }
    }

    /// "A", "A and B", "A, B and C".
    private static func listed(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What a row's button does: reads again, or asks the user about a plan
    /// (never runs it: only the confirmation's Connect does).
    enum ButtonEffect: Equatable {
        case checkAgain
        case confirm(Plan)
        /// No plan: no CLI found, or no CherryMCP next to the app.
        case unavailable
    }

    static func effect(of action: Action, plan: Plan?) -> ButtonEffect {
        guard action.registers else { return .checkAgain }
        return plan.map(ButtonEffect.confirm) ?? .unavailable
    }

    // MARK: Reading an entry

    /// What a Claude Code entry (`mcpServers.<name>`) or a Codex
    /// `transport` has, compared with this app's helper: its `type`,
    /// `command` and `args` (never its environment). A command without a
    /// `/` runs when it is on `searchPath`.
    static func entryStatus(_ server: [String: Any], helperPath: String, searchPath: String) -> EntryStatus {
        if let type = server["type"] as? String, type != "stdio" {
            return .otherArguments(line: server["url"] as? String ?? "a \(type) server")
        }
        guard let command = (server["command"] as? String)?.nilIfEmpty else {
            return .otherArguments(line: server["url"] as? String ?? "nothing: it has no command")
        }
        guard standardized(command) == standardized(helperPath) else {
            return .otherHelper(path: command, runs: runs(command, searchPath: searchPath))
        }
        let arguments = (server["args"] as? [Any] ?? []).map { "\($0)" }
        guard arguments.isEmpty else { return .otherArguments(line: shownLine(server) ?? command) }
        return .connected
    }

    /// What an entry runs, as a shell would: its command and arguments, or
    /// its URL.
    static func shownLine(_ server: [String: Any]) -> String? {
        guard let command = (server["command"] as? String)?.nilIfEmpty else { return server["url"] as? String }
        let arguments = (server["args"] as? [Any] ?? []).map { "\($0)" }
        return ([command] + arguments).map(MCPHarness.shownWord).joined(separator: " ")
    }

    /// Whether `command` runs: an executable file, looked for on
    /// `searchPath` when it names no directory.
    static func runs(_ command: String, searchPath: String) -> Bool {
        guard !command.contains("/") else { return FileManager.default.isExecutableFile(atPath: command) }
        return searchPath.split(separator: ":").contains { directory in
            directory.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: "\(directory)/\(command)")
        }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Claude Code's registration of Cherry MCP for every project of this
/// user (`claude mcp add --scope user`), read from the file Claude Code
/// keeps it in (checked with 2.1.299). Nothing here runs `claude`: `claude
/// mcp list` and `claude mcp get` start the servers they show, and `get`
/// rewrites that file.
enum ClaudeMCPRegistration {
    /// Where Claude Code keeps its user-scope servers.
    enum SettingsFile: Equatable {
        case file(URL)
        /// One Claude Code itself refuses: why.
        case unusable(String)
    }

    /// The file `claude mcp add --scope user` writes: `.config.json` in
    /// Claude Code's config directory (`CLAUDE_CONFIG_DIR`, else
    /// `~/.claude`) when that legacy file exists; else `.claude.json` in
    /// `CLAUDE_CONFIG_DIR` when it is set, else in the home directory.
    /// `environment` is the login shell's; a relative `CLAUDE_CONFIG_DIR`
    /// is refused, as Claude Code refuses it.
    static func settingsFile(
        environment: [String: String],
        homeDirectory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> SettingsFile {
        let configured = environment["CLAUDE_CONFIG_DIR"]?.nilIfEmpty
        if let configured, !configured.hasPrefix("/") {
            return .unusable("CLAUDE_CONFIG_DIR is not an absolute path")
        }
        let configuredDirectory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let legacy = (configuredDirectory ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true))
            .appendingPathComponent(".config.json", isDirectory: false)
        if fileExists(legacy.path) { return .file(legacy) }
        return .file((configuredDirectory ?? homeDirectory).appendingPathComponent(".claude.json", isDirectory: false))
    }

    /// What `data` (the settings file at `file`; nil: there is none) has
    /// under the top-level `mcpServers.<serverName>`.
    static func status(serverName: String, helperPath: String, file: URL, data: Data?, searchPath: String = "") -> AgentConnection.EntryStatus {
        guard let data else { return .notRegistered }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("\(file.path) is not a JSON object")
        }
        guard let server = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] else {
            return .notRegistered
        }
        return AgentConnection.entryStatus(server, helperPath: helperPath, searchPath: searchPath)
    }

    /// What the local-scope entry (`claude mcp add --scope local`, kept
    /// under `projects["<directory>"].mcpServers`) of the first of
    /// `projectRoots` that has one runs under `serverName`; nil when none
    /// has one. Claude Code uses it instead of the user one in that project.
    static func localEntry(projectRoots: [String], serverName: String, data: Data?) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return nil }
        for projectRoot in projectRoots {
            let standardized = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
            let project = projects[projectRoot]
                ?? projects.first { URL(fileURLWithPath: $0.key).standardizedFileURL.path == standardized }?.value
            if let server = ((project as? [String: Any])?["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] {
                return AgentConnection.shownLine(server) ?? "nothing: it has no command"
            }
        }
        return nil
    }

    static func addArguments(serverName: String, helperPath: String) -> [String] {
        MCPHarness.claude.addArguments(serverName: serverName, helperPath: helperPath)
    }

    /// Always `--scope user`: without it a name in two scopes is refused.
    static func removeArguments(serverName: String) -> [String] {
        ["mcp", "remove", "--scope", "user", serverName]
    }

    /// Re-register and Connect Again: `claude mcp add` refuses a name it
    /// has, so its `remove` goes first (one that finds none fails, and
    /// counts only when the `add` fails too).
    static func reRegisterSteps(serverName: String, helperPath: String) -> [[String]] {
        [removeArguments(serverName: serverName), addArguments(serverName: serverName, helperPath: helperPath)]
    }
}

/// Codex's registration of Cherry MCP, as `codex mcp get <name> --json`
/// prints it (checked with 0.162.1: it starts no server and writes no
/// settings). Cherry never parses config.toml (profiles and project
/// settings would be missed) and never runs `codex mcp list`.
enum CodexMCPRegistration {
    /// The first Codex Cherry asks with `mcp get --json`; an older one is
    /// "Not checked" (Connect is still offered).
    static let readsSettingsFrom = AgentCLIVersion(major: 0, minor: 162, patch: 0)
    /// How long `codex mcp get` may take.
    static let getTimeout: TimeInterval = 10

    static func getArguments(serverName: String) -> [String] {
        ["mcp", "get", serverName, "--json"]
    }

    /// `codex mcp add` replaces a table of the same name whole.
    static func addArguments(serverName: String, helperPath: String) -> [String] {
        MCPHarness.codex.addArguments(serverName: serverName, helperPath: helperPath)
    }

    /// The file Codex writes: `config.toml` in `CODEX_HOME` (the login
    /// shell's), else `~/.codex`.
    static func settingsFile(environment: [String: String], homeDirectory: URL) -> URL {
        let directory = environment["CODEX_HOME"]?.nilIfEmpty.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        return directory.appendingPathComponent("config.toml", isDirectory: false)
    }

    /// What `codex mcp get --json` said: its `enabled` and `transport`
    /// (`type`, `command`, `args`) on exit 0; not registered when it names
    /// no such server; otherwise what Codex said, its first 300 characters.
    static func status(fromGet outcome: MCPCLIRegistration.RunOutcome, helperPath: String, searchPath: String = "") -> AgentConnection.EntryStatus {
        let said = shown(outcome.output)
        guard outcome.status == 0 else {
            if outcome.status == 1, outcome.output.contains("No MCP server named") { return .notRegistered }
            return .unreadable(said.nilIfEmpty ?? "codex mcp get exited with status \(outcome.status)")
        }
        guard let entry = jsonObject(in: outcome.output) else {
            return .unreadable("codex mcp get printed “\(said)”")
        }
        if entry["enabled"] as? Bool == false { return .turnedOff }
        return AgentConnection.entryStatus(entry["transport"] as? [String: Any] ?? [:], helperPath: helperPath, searchPath: searchPath)
    }

    /// The JSON object in `output`: all of it, else from its first `{` to
    /// its last `}` (a warning Codex printed on standard error around it).
    private static func jsonObject(in output: String) -> [String: Any]? {
        func object(_ text: Substring) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        if let whole = object(output[...]) { return whole }
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return object(output[start...end])
    }

    /// `output`'s lines joined with spaces, at most 300 characters.
    private static func shown(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(line.prefix(300))
    }
}

/// A CLI's connection model (Claude Code's and Codex's
/// `MCPCLIRegistrationModel`, Pi's `PiMCPRegistrationModel`), as every
/// surface renders it: its row, the plan of each button, and the run of a
/// plan the user confirmed.
@MainActor
protocol AgentConnectionModel: ObservableObject {
    var harness: MCPHarness { get }
    var serverName: String { get }
    var helperPath: String? { get }
    var isRunning: Bool { get }
    /// What the last run printed, or why it failed.
    var message: String? { get }
    var lastRunFailed: Bool { get }
    /// The last run worked: its row shows the restart hint.
    var lastRunSucceeded: Bool { get }

    func row(connectsAtLaunch: Bool) -> AgentConnection.Row
    /// What `action` would run; nil for Check Again, or while the CLI is not
    /// found or the app has no CherryMCP. Builds it only: nothing runs.
    func plan(for action: AgentConnection.Action) -> AgentConnection.Plan?
    /// Reads the CLI's state again (`asksAgain`: its `--version` too).
    func refresh(asksAgain: Bool) async
    /// Runs `plan`: only the confirmation's Connect calls it.
    func perform(_ plan: AgentConnection.Plan) async
}

extension PiMCPRegistration.State {
    /// Pi's version, when it printed one.
    var version: AgentCLIVersion? {
        switch self {
        case .checking, .notInstalled, .unknownVersion, .noAnswer:
            nil
        case .withoutMCP(let version), .notConnected(let version), .connected(let version, _), .toolsHidden(let version, _),
             .turnedOff(let version), .otherHelper(let version, _, _), .otherArguments(let version, _), .unreadable(let version, _):
            version
        }
    }

    /// Whether `pi` said it has MCP (`PiMCPRegistration.minimumVersion` or
    /// later); false too while Cherry can't tell, or has not looked yet.
    var hasMCP: Bool {
        version.map { $0 >= PiMCPRegistration.minimumVersion } ?? false
    }
}
