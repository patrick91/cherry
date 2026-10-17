import CherryControl
import Foundation

/// Cherry MCP on the command line of the agents Cherry starts
/// (docs/mcp.md › Setup): an agent tab whose command is a plain `claude`,
/// `codex` or `pi` command gets Cherry's stdio server for that run, so
/// nothing has to be registered for it. Claude Code takes `--mcp-config
/// <json>`, Codex `-c mcp_servers.<name>={…}`, and Pi `-e` with Cherry's Pi
/// extension (`PiMCPExtension`), which registers the tab's
/// `CHERRY_MCP_HELPER` for that session; none writes the agent's
/// configuration. The server is named after the identity's scheme, as a
/// registration is (`MCPInstallCommandBuilder`), so for that run it shadows
/// a Claude Code or Codex one: the agent sees one `cherry` server. Pi
/// prefers an entry of that name in its `mcp.json` to the extension's (the
/// launch logs one that differs, `piRegistrationNote`). Settings › Agents &
/// MCP › Connect agents Cherry starts turns it off; then agents use what
/// was registered.
///
/// The flags go only on a launch's command (`TerminalSession.launchStartupCommand`),
/// never on the saved `launchCommand`, and only when the CLI's version is
/// known to take them (`AgentCLIVersions`). Otherwise the tab starts as it
/// always did. A shell alias or function named `claude`, `codex` or `pi`
/// gets the flags too, while the version was read from the executable on
/// PATH.
enum AgentMCPLaunch {
    /// Settings › Agents & MCP › MCP server › Connect agents Cherry starts.
    static let enabledDefaultsKey = "mcp.connectAgentsAtLaunch"
    /// Whether it is on while nothing is stored.
    static let enabledDefault = true

    /// Whether it is on. Only a Boolean counts, as for Cherry's other
    /// switches: a launch argument turns it off as a property list
    /// (`-mcp.connectAgentsAtLaunch '<false/>'`), while `NO` is a string and
    /// leaves the default.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? enabledDefault
    }

    /// An agent CLI that takes an MCP server for one run.
    enum CLI: String, CaseIterable, Sendable {
        case claudeCode
        case codex
        case pi

        /// The oldest version Cherry passes its flag to: Claude Code's
        /// inline `--mcp-config` JSON (checked with 2.1.299), Codex's
        /// inline `-c` table (checked with 0.162.1), and the Pi whose
        /// extensions register MCP servers with a description and a
        /// timeout (`PiMCPRegistration.minimumVersion`, read from 1.3.0's
        /// source).
        var minimumVersion: AgentCLIVersion {
            switch self {
            case .claudeCode: AgentCLIVersion(major: 2, minor: 0, patch: 0)
            case .codex: AgentCLIVersion(major: 0, minor: 162, patch: 0)
            case .pi: PiMCPRegistration.minimumVersion
            }
        }

        var brand: AgentToolBrand {
            switch self {
            case .claudeCode: .claude
            case .codex: .codex
            case .pi: .pi
            }
        }

        /// The executable's name: `claude`, `codex`, `pi`.
        var executableName: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            case .pi: "pi"
            }
        }

        /// Its subcommands that start no agent session (`claude mcp list`,
        /// `claude attach <name>`, `codex login`, `pi install`): they take
        /// no session flags, and Claude Code's would refuse `--mcp-config`
        /// or read it as more of their arguments. Checked against `--help`
        /// of Claude Code 2.1.299 and Codex 0.162.1, and Pi 1.3.0's argument
        /// parser (Pi takes them only as its first word: any word here is
        /// stricter); recheck after an upgrade.
        var subcommandsWithoutSession: Set<String> {
            switch self {
            case .claudeCode:
                [
                    "mcp", "config", "doctor", "update", "upgrade", "install", "plugin", "plugins",
                    "setup-token", "migrate-installer", "auth", "help", "agents", "attach", "logs",
                    "stop", "kill", "rm", "respawn", "auto-mode", "gateway", "import", "purge",
                    "ultrareview",
                ]
            case .codex:
                [
                    "login", "logout", "mcp", "mcp-server", "app-server", "completion", "sandbox",
                    "debug", "apply", "cloud", "features", "help",
                ]
            case .pi:
                ["install", "remove", "uninstall", "update", "list", "config", "auth", "mcp", "help"]
            }
        }

        /// Its options that take the next word as their value whatever it
        /// is. A line ending in one would give it the first appended word,
        /// and the next (the JSON, the table, the extension's path) would
        /// be a prompt: Claude Code's and Pi's parsers take it as one and
        /// start a turn with it. From Claude Code 2.1.299's and Codex
        /// 0.162.1's `--help` (their `<value>` options) and Pi 1.3.0's
        /// argument parser; recheck after an upgrade.
        var optionsTakingValue: Set<String> {
            switch self {
            case .claudeCode:
                [
                    "--add-dir", "--agent", "--agents", "--allowedTools", "--allowed-tools",
                    "--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--betas",
                    "--debug-file", "--disallowedTools", "--disallowed-tools", "--effort", "--environment",
                    "--fallback-model", "--file", "--input-format", "--json-schema", "--max-budget-usd",
                    "--max-turns", "--model", "-n", "--name", "--output-format", "--permission-mode",
                    "--permission-prompt-tool", "--permission-prompts", "--plugin-dir", "--plugin-url",
                    "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings",
                    "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot", "--tools",
                ]
            case .codex:
                [
                    "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-i",
                    "--image", "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox",
                    "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
                ]
            case .pi:
                [
                    "--provider", "--model", "--api-key", "--system-prompt", "--append-system-prompt", "--name",
                    "-n", "--session", "--session-id", "--fork", "--session-dir", "--models", "--tools", "-t",
                    "--exclude-tools", "-xt", "--thinking", "--export", "--extension", "-e", "--skill",
                    "--prompt-template", "--theme",
                ]
            }
        }
    }

    /// What a command line runs, as far as Cherry MCP's flags go.
    enum Detection: Equatable {
        /// A plain command of `cli`; `executableWord` is its first word,
        /// unquoted (`claude`, `/opt/homebrew/bin/claude`, `~/.local/bin/claude`).
        case cli(CLI, executableWord: String)
        /// Not one simple command of literal words (a pipe, list,
        /// redirection, expansion, glob, comment, assignment, newline or
        /// `--`), or not claude, codex or pi.
        case notPlain
        /// A subcommand that starts no session (`claude mcp`, `codex login`,
        /// `pi install`).
        case subcommand(CLI, String)
        /// It names its own MCP configuration (`--mcp-config`,
        /// `--strict-mcp-config`, `-c mcp_servers…`), or turns off Pi's MCP
        /// or extensions (`--no-mcp`, `--no-extensions`, `-ne`).
        case ownConfiguration(CLI)
        /// Its last word is an option that takes a value
        /// (`CLI.optionsTakingValue`): the appended words would be its value
        /// and a prompt.
        case optionWithoutValue(CLI, String)
    }

    /// The CLI when `commandLine` is a plain command whose first word's
    /// basename is claude, codex or pi and that names no MCP configuration
    /// of its own; nil otherwise.
    static func detect(commandLine: String) -> (cli: CLI, executableWord: String)? {
        guard case .cli(let cli, let executableWord) = detection(commandLine: commandLine) else { return nil }
        return (cli, executableWord)
    }

    static func detection(commandLine: String) -> Detection {
        guard let words = plainWords(commandLine), let first = words.first,
              // `FOO=1 claude`: the shell would run claude with FOO set.
              first.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) == nil,
              // What follows `--` is not options: the flags would be operands.
              !words.contains("--"),
              let cli = CLI.allCases.first(where: { $0.executableName == (first as NSString).lastPathComponent })
        else { return .notPlain }
        let arguments = words.dropFirst()
        switch cli {
        case .claudeCode:
            let ownOptions = ["--mcp-config", "--strict-mcp-config"]
            if arguments.contains(where: { word in ownOptions.contains { word == $0 || word.hasPrefix($0 + "=") } }) {
                return .ownConfiguration(cli)
            }
        case .codex:
            // `-c mcp_servers…`, `--config mcp_servers…`, `-cmcp_servers…`.
            if arguments.contains(where: { $0.contains("mcp_servers") }) {
                return .ownConfiguration(cli)
            }
        case .pi:
            // Without its MCP, nothing connects the extension's server; `-ne`
            // still loads an explicit `-e`, but not the built-in MCP.
            let ownOptions = ["--no-mcp", "--no-extensions"]
            if arguments.contains(where: { word in
                word == "-ne" || ownOptions.contains { word == $0 || word.hasPrefix($0 + "=") }
            }) {
                return .ownConfiguration(cli)
            }
        }
        // Any word that is not an option, not only the first: an option's
        // value comes first in `codex -c model=x login`.
        if let subcommand = arguments.first(where: { !$0.hasPrefix("-") && cli.subcommandsWithoutSession.contains($0) }) {
            return .subcommand(cli, subcommand)
        }
        if let last = arguments.last, cli.optionsTakingValue.contains(last) {
            return .optionWithoutValue(cli, last)
        }
        return .cli(cli, executableWord: first)
    }

    /// What a launch of `commandLine` appends to run `helperPath` as the
    /// stdio server `serverName`, whatever its CLI's version, or why
    /// nothing: the command is a plain claude, codex or pi command
    /// (`detection`) and the words can go on its line (`arguments`); a Pi
    /// needs Cherry's Pi extension (`piExtensionPath`), which runs the
    /// helper. This Mac's launches (`AgentMCPLaunchContext`) and a device's
    /// (`RemoteAgentMCPLaunch`) add their own conditions around it.
    static func plan(
        commandLine: String, serverName: String, helperPath: String, environmentKeys: [String], piExtensionPath: String? = nil
    ) -> Plan {
        let cli: CLI
        let executableWord: String
        switch detection(commandLine: commandLine) {
        case .notPlain:
            return .skipped("not a plain claude, codex or pi command")
        case .ownConfiguration(let cli):
            return .skipped(cli == .pi ? "it turns off Pi's MCP or extensions" : "it names its own MCP configuration")
        case .subcommand(let cli, let subcommand):
            return .skipped("\(cli.executableName) \(subcommand) starts no session")
        case .optionWithoutValue(_, let option):
            return .skipped("its last word, \(option), is an option without its value")
        case .cli(let detected, let word):
            cli = detected
            executableWord = word
        }
        if cli == .pi, piExtensionPath == nil { return .skipped("no Pi extension next to the app") }
        guard let arguments = arguments(
            for: cli, serverName: serverName, helperPath: helperPath, environmentKeys: environmentKeys,
            piExtensionPath: piExtensionPath
        ) else {
            if cli == .pi, let piExtensionPath {
                return .skipped(
                    "the server name \(serverName), CherryMCP's path \(helperPath) or the Pi extension's path \(piExtensionPath) can't go on a command line"
                )
            }
            return .skipped("the server name \(serverName) or CherryMCP's path \(helperPath) can't go on a command line")
        }
        return .flags(cli: cli, executableWord: executableWord, arguments: arguments)
    }

    /// What `plan` found.
    enum Plan: Equatable {
        /// The command runs `cli` (`executableWord`, as `Detection.cli`),
        /// and `arguments` are the words to append.
        case flags(cli: CLI, executableWord: String, arguments: [String])
        case skipped(String)
    }

    /// The words of `commandLine` as a POSIX shell reads them, quotes
    /// removed, when it is one simple command whose words are all literal;
    /// nil when it has an unquoted `| & ; < > ( )`, `* ? [ ] { }` or comment,
    /// a `$` or backtick outside single quotes (an expansion), a control
    /// character other than a tab (a newline makes two commands), or an
    /// unterminated quote. So the words read here are the words the shell
    /// passes, and words appended after them stay arguments of the command.
    static func plainWords(_ commandLine: String) -> [String]? {
        enum Quote { case none, single, double }
        let scalars = Array(commandLine.unicodeScalars)
        // Escaped ones too: a backslash before a newline joins two lines
        // into one command whose words are not the ones read here.
        guard !scalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7f }) else { return nil }
        var words: [String] = []
        var word = String.UnicodeScalarView()
        var inWord = false
        var quote = Quote.none
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch quote {
            case .single:
                if scalar == "'" { quote = .none } else { word.append(scalar) }
            case .double:
                switch scalar {
                case "\"":
                    quote = .none
                case "$", "`":
                    return nil
                case "\\":
                    // Inside double quotes a backslash escapes only these.
                    guard index + 1 < scalars.count else { return nil }
                    let next = scalars[index + 1]
                    if "$`\"\\".unicodeScalars.contains(next) {
                        word.append(next)
                        index += 1
                    } else {
                        word.append(scalar)
                    }
                default:
                    word.append(scalar)
                }
            case .none:
                switch scalar {
                case " ", "\t":
                    if inWord {
                        words.append(String(word))
                        word = String.UnicodeScalarView()
                        inWord = false
                    }
                    index += 1
                    continue
                case "'":
                    quote = .single
                case "\"":
                    quote = .double
                case "\\":
                    guard index + 1 < scalars.count else { return nil }
                    word.append(scalars[index + 1])
                    index += 1
                case "|", "&", ";", "<", ">", "(", ")", "$", "`", "*", "?", "[", "]", "{", "}":
                    return nil
                case "#" where !inWord:
                    return nil
                default:
                    word.append(scalar)
                }
                inWord = true
            }
            index += 1
        }
        guard quote == .none else { return nil }
        if inWord { words.append(String(word)) }
        return words
    }

    /// Codex's limit for one Cherry tool call, and what CherryMCP is told
    /// it is (`--client-tool-timeout`), so that its waits may last up to it
    /// less a margin (docs/mcp.md › Client Timeouts).
    static let codexToolTimeoutSeconds = 300
    /// How long Codex waits for CherryMCP to start.
    static let codexStartupTimeoutSeconds = 30

    /// The words to append (unquoted) for `cli` to run `helperPath` as the
    /// stdio server `serverName`:
    /// - Claude Code: `--mcp-config` and the JSON
    ///   `{"mcpServers":{"<name>":{"args":[],"command":"<helper>","type":"stdio"}}}`
    ///   (sorted keys, slashes unescaped). Claude Code passes its
    ///   environment to stdio servers, so the JSON names none.
    /// - Codex: `-c` and the inline table
    ///   `mcp_servers.<name>={command=…,args=[…],env_vars=[…],startup_timeout_sec=30,tool_timeout_sec=300}`,
    ///   which replaces a registered `[mcp_servers.<name>]` whole. Codex
    ///   starts MCP servers with only a few variables of its own
    ///   environment: `environmentKeys` are the Cherry variables it passes
    ///   on (only names: no value, so never a token, goes on the line).
    /// - Pi: `-e` and Cherry's Pi extension (`piExtensionPath`,
    ///   `PiMCPExtension`), which registers the tab's `CHERRY_MCP_HELPER` as
    ///   `CHERRY_MCP_SERVER_NAME` for the session: Pi passes its whole
    ///   environment to MCP servers, so neither goes on the line.
    ///
    /// Nil when the name is not `^[a-z0-9_-]+$`, or the helper's path (or
    /// a Pi's extension's) is missing, not absolute or has a `'`, `\` or
    /// control character: the words are then single-quoted (`shellSuffix`)
    /// the same way in sh, zsh, bash and fish, which a This Mac tab without
    /// the zsh bootstrap may run them in. The helper is checked for Pi too,
    /// since the extension runs it.
    static func arguments(
        for cli: CLI, serverName: String, helperPath: String, environmentKeys: [String], piExtensionPath: String? = nil
    ) -> [String]? {
        guard serverName.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil,
              isLinePath(helperPath)
        else { return nil }
        switch cli {
        case .claudeCode:
            struct Server: Encodable {
                let type = "stdio"
                let command: String
                let args: [String] = []
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(["mcpServers": [serverName: Server(command: helperPath)]]),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            return ["--mcp-config", json]
        case .codex:
            let arguments = ["--client-tool-timeout", String(codexToolTimeoutSeconds)]
            let table = [
                "command=\(tomlString(helperPath))",
                "args=[\(arguments.map(tomlString).joined(separator: ","))]",
                "env_vars=[\(environmentKeys.map(tomlString).joined(separator: ","))]",
                "startup_timeout_sec=\(codexStartupTimeoutSeconds)",
                "tool_timeout_sec=\(codexToolTimeoutSeconds)",
            ]
            return ["-c", "mcp_servers.\(serverName)={\(table.joined(separator: ","))}"]
        case .pi:
            guard let piExtensionPath, isLinePath(piExtensionPath) else { return nil }
            return ["-e", piExtensionPath]
        }
    }

    /// Whether `path` reads the same in every shell's single quotes: an
    /// absolute path with no `'`, `\` or control character.
    private static func isLinePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("'") && !path.contains("\\")
            && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    /// `text` as a TOML basic string.
    static func tomlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7f:
                escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// `words` appended to a command line: each one single-quoted after a
    /// space (" '<w1>' '<w2>'"). They must be the line's last words: Claude
    /// Code's `--mcp-config` takes every word after it.
    static func shellSuffix(_ words: [String]) -> String {
        words.map { " " + ShellQuoting.singleQuoted($0) }.joined()
    }

    /// The Cherry variables a This Mac agent's launch sets, which Codex
    /// passes on to Cherry MCP (`env_vars`): the tab's and agent's ids, the
    /// project root when the tab has one, the app's control socket when it
    /// listens (`CherryControlServer.appSocketPath`), and the helper.
    static func environmentKeys(projectRoot: String?, controlSocketPath: String?, helperPath: String?) -> [String] {
        var keys = [CherryControl.processIDEnvironmentKey, CherryControl.agentIDEnvironmentKey]
        if projectRoot?.isEmpty == false { keys.append(CherryControl.projectRootEnvironmentKey) }
        if controlSocketPath?.isEmpty == false { keys.append(CherryControl.socketEnvironmentKey) }
        if helperPath?.isEmpty == false { keys.append(CherryControl.mcpHelperEnvironmentKey) }
        return keys
    }

    /// What an agent's launch appends, or why it appends nothing.
    enum Outcome: Equatable {
        /// The flags, as `shellSuffix` writes them.
        case appended(String)
        case skipped(String)
    }

    /// What a Pi launch's log says of what Pi's `mcp.json` has under the
    /// server's name (`PiMCPRegistration.status`): Pi uses an entry of its
    /// own instead of the server the extension registers, so one that is
    /// not this app's CherryMCP leaves the agent without Cherry's tools (or
    /// with another Cherry's). Nil when it has none, or this app's (deferred
    /// or direct), which serves the agent as well.
    static func piRegistrationNote(_ status: PiMCPRegistration.EntryStatus, serverName: String) -> String? {
        let what: String
        switch status {
        case .notRegistered, .connected:
            return nil
        case .unreadable(let why):
            return "Pi's mcp.json could not be read: \(why)"
        case .toolsHidden(let exposure):
            what = "its exposure is \(exposure)"
        case .turnedOff:
            what = "turned off"
        case .otherHelper(let path, let runs):
            what = runs ? "it runs \(path)" : "it runs \(path), which isn't there"
        case .otherArguments(let line):
            what = "it runs \(line)"
        }
        return "Pi's mcp.json has its own \(serverName) (\(what)); Pi uses it instead of the launch-time server"
    }
}

/// What a workspace's agent launches use for Cherry MCP on their command
/// line (`SessionBackendPolicy.agentMCPLaunch`). Only the app's This Mac
/// windows have one (`.userSettings`): nil (tests, `.native`, a device's
/// window) means no flags and no version probe, so no test runs a real
/// `claude`, `codex` or `pi` and no test's command changes.
@MainActor
struct AgentMCPLaunchContext {
    /// Settings › Agents & MCP › Connect agents Cherry starts. The app's:
    /// `AgentMCPLaunch.isEnabled(.standard)`.
    var isEnabled: @MainActor () -> Bool
    /// The CLIs' versions. The app's: `.shared`; tests build their own.
    var versions: AgentCLIVersions
    /// The CherryMCP the flags run. The app's: its own,
    /// `ShellProcessController.appMCPHelperPath`.
    var helperPath: String?
    /// Cherry's Pi extension, which a Pi agent gets with `-e`. The app's:
    /// the bundle's (`PiMCPExtension.bundledPath`); nil: Pi agents start
    /// without Cherry MCP.
    var piExtensionPath: String? = nil
    /// Pi's agent directory, whose `mcp.json` a Pi launch reads (off the
    /// main thread) to log an entry that Pi prefers to the extension's
    /// server (`AgentMCPLaunch.piRegistrationNote`). The app's: the login
    /// environment's `PI_CODING_AGENT_DIR` as known now, never waited for,
    /// else `~/.pi/agent`; nil (tests) reads nothing.
    var piAgentDirectory: (@Sendable () -> URL)? = nil

    /// The app's This Mac windows'.
    static let app = AgentMCPLaunchContext(
        isEnabled: { AgentMCPLaunch.isEnabled() },
        versions: .shared,
        helperPath: ShellProcessController.appMCPHelperPath,
        piExtensionPath: PiMCPExtension.bundledPath,
        piAgentDirectory: {
            PiMCPRegistration.agentDirectory(environment: HostedSessionLoginEnvironment.shared.availableNow()?.environment ?? [:])
        }
    )

    /// What an agent's launch of `commandLine` appends for Cherry MCP named
    /// `serverName`, or why nothing: every rule of `AgentMCPLaunch` holds,
    /// a Pi's extension is still there (an app moved while it runs has
    /// none), and the CLI's version is known (never waited for: an unknown
    /// one is asked in the background for a later launch) and at least its
    /// minimum.
    func outcome(commandLine: String, serverName: String, environmentKeys: [String]) -> AgentMCPLaunch.Outcome {
        guard isEnabled() else { return .skipped("turned off in Settings › Agents & MCP") }
        guard let helperPath else { return .skipped("no CherryMCP next to the app") }
        let cli: AgentMCPLaunch.CLI
        let executableWord: String
        let arguments: [String]
        switch AgentMCPLaunch.plan(
            commandLine: commandLine, serverName: serverName, helperPath: helperPath, environmentKeys: environmentKeys,
            piExtensionPath: piExtensionPath.flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil }
        ) {
        case .skipped(let reason):
            return .skipped(reason)
        case .flags(let planned, let word, let words):
            (cli, executableWord, arguments) = (planned, word, words)
        }
        guard let version = versions.version(of: executableWord) else {
            return .skipped("\(cli.executableName)'s version is not known yet")
        }
        guard version >= cli.minimumVersion else {
            return .skipped("\(cli.executableName) \(version) is older than \(cli.minimumVersion)")
        }
        return .appended(AgentMCPLaunch.shellSuffix(arguments))
    }

    /// Asks the versions of the CLIs of `agents` that would get Cherry MCP,
    /// while it is on and the app has its CherryMCP: the app's windows do
    /// as the first one opens, so the run's agents find them.
    func warmUp(agents: [AgentToolDefinition]) {
        guard isEnabled(), helperPath != nil else { return }
        versions.warmUp(agents: agents)
    }
}
