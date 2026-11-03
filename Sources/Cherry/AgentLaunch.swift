import CherryControl
import Foundation

/// What Cherry puts on the command line of the agents it starts
/// (docs/cli.md › Agents Cherry Starts): an agent tab whose command is a
/// plain `claude`, `codex` or `pi` command gets the `cherry` skill for that
/// launch and a line saying it runs in a Cherry tab (`AgentCLILaunch`), and
/// reaches Cherry with the `cherry` on its PATH (`TabCLIDirectory`). None
/// writes the agent's configuration. Settings › Agents › Connect agents
/// Cherry starts turns it off.
///
/// The flags go only on a launch's command (`TerminalSession.launchStartupCommand`),
/// never on the saved `launchCommand`, and only when the CLI's version is
/// known to take them (`AgentCLIVersions`). Otherwise the tab starts as it
/// always did. A shell alias or function named `claude`, `codex` or `pi`
/// gets the flags too, while the version was read from the executable on
/// PATH.
enum AgentLaunch {
    /// Settings › Agents › Connect agents Cherry starts (the key Cherry MCP's
    /// switch had, so a choice made then stays).
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

    /// An agent CLI Cherry starts with its flags.
    enum CLI: String, CaseIterable, Sendable {
        case claudeCode
        case codex
        case pi

        /// The oldest version Cherry passes its flags to: Claude Code's
        /// `--plugin-dir` and `--append-system-prompt` (checked with
        /// 2.1.303), Codex's `-c developer_instructions` and
        /// `--approve-for-me` (checked with 0.162.1), and Pi's `--skill` and
        /// `--append-system-prompt` (older than 0.99.2, the first Pi Cherry
        /// checked).
        var minimumVersion: AgentCLIVersion {
            switch self {
            case .claudeCode: AgentCLIVersion(major: 2, minor: 1, patch: 0)
            case .codex: AgentCLIVersion(major: 0, minor: 162, patch: 0)
            case .pi: AgentCLIVersion(major: 0, minor: 99, patch: 2)
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
        /// no session flags, and Claude Code's would refuse `--plugin-dir`
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
        /// and the next (a path, the instructions line) would
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

    /// What a command line runs, as far as Cherry's flags go.
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
        /// Its last word is an option that takes a value
        /// (`CLI.optionsTakingValue`): the appended words would be its value
        /// and a prompt.
        case optionWithoutValue(CLI, String)
    }

    /// The CLI when `commandLine` is a plain command whose first word's
    /// basename is claude, codex or pi; nil otherwise.
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

    /// Why a launch of a command `detection` describes appends nothing;
    /// nil for a plain command of a CLI (`Detection.cli`).
    static func skipReason(_ detection: Detection) -> String? {
        switch detection {
        case .cli:
            nil
        case .notPlain:
            "not a plain claude, codex or pi command"
        case .subcommand(let cli, let subcommand):
            "\(cli.executableName) \(subcommand) starts no session"
        case .optionWithoutValue(_, let option):
            "its last word, \(option), is an option without its value"
        }
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

    /// Whether `path` reads the same in every shell's single quotes: an
    /// absolute path with no `'`, `\` or control character.
    static func isLinePath(_ path: String) -> Bool {
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
    /// space (" '<w1>' '<w2>'").
    static func shellSuffix(_ words: [String]) -> String {
        words.map { " " + ShellQuoting.singleQuoted($0) }.joined()
    }

    /// What an agent's launch appends, or why it appends nothing.
    enum Outcome: Equatable {
        /// The `cherry` CLI's flags (`AgentCLILaunch`, and Approvals'), as
        /// `shellSuffix` writes them.
        case appended(String)
        case skipped(String)
    }
}

/// What a workspace's agent launches put on their command line to reach
/// Cherry (`SessionBackendPolicy.agentLaunch`): the `cherry` CLI's flags
/// (`AgentCLILaunch`), with Approvals' (`AgentApprovals`). Only the app's
/// This Mac windows have one (`.userSettings`): nil (tests, `.native`, a
/// device's window) means no flags and no version probe, so no test runs a
/// real `claude`, `codex` or `pi` and no test's command changes.
@MainActor
struct AgentLaunchContext {
    /// Settings › Agents › Connect agents Cherry starts. The app's:
    /// `AgentLaunch.isEnabled(.standard)`.
    var isEnabled: @MainActor () -> Bool
    /// The CLIs' versions. The app's: `.shared`; tests build their own.
    var versions: AgentCLIVersions
    /// The `cherry` skill's plugin directory (`AgentSkillDirectory.current`).
    /// A nil answer: Claude Code and Pi agents start without flags.
    var pluginDirectory: @MainActor () -> URL? = { nil }
    /// The app's control socket, which Claude Code's sandbox may reach
    /// (`CherryControlServer.appSocketPath`).
    var controlSocketPath: @MainActor () -> String? = { nil }
    /// Settings › Agents › Approvals, per CLI. The app's:
    /// `AgentApprovals.current(for:)`.
    var approvals: @MainActor (AgentLaunch.CLI) -> AgentApprovals = { _ in .configured }
    /// What Codex's files say (`CodexLaunchFactsCache`); nil while not
    /// read yet: a Codex agent then gets no instructions line (its config
    /// may set its own).
    var codexFacts: @MainActor () -> CodexLaunchFacts? = { nil }

    /// The app's This Mac windows'.
    static let app = AgentLaunchContext(
        isEnabled: { AgentLaunch.isEnabled() },
        versions: .shared,
        pluginDirectory: { AgentSkillDirectory.current },
        controlSocketPath: { CherryControlServer.appSocketPath },
        approvals: { AgentApprovals.current(for: $0) },
        codexFacts: { CodexLaunchFactsCache.shared.current() }
    )

    /// What an agent's launch of `commandLine` appends, or why nothing:
    /// a plain claude, codex or pi command (`AgentLaunch.detection`) whose
    /// CLI's version is known (never waited for: an unknown one is asked in
    /// the background for a later launch) and at least its minimum.
    /// Approvals' words come first. `processID` is the tab's, which the
    /// instructions line names.
    func outcome(commandLine: String, processID: String? = nil) -> AgentLaunch.Outcome {
        guard isEnabled() else { return .skipped("turned off in Settings › Agents") }
        let detection = AgentLaunch.detection(commandLine: commandLine)
        guard case .cli(let cli, let executableWord) = detection else {
            return .skipped(AgentLaunch.skipReason(detection) ?? "not a plain claude, codex or pi command")
        }
        let words = Array((AgentLaunch.plainWords(commandLine) ?? []).dropFirst())
        guard let arguments = AgentCLILaunch.arguments(
            for: cli,
            words: words,
            pluginDirectory: pluginDirectory(),
            socketPath: controlSocketPath(),
            processID: processID,
            // A Codex whose config sets its own instructions keeps them.
            addsInstructions: cli != .codex || codexFacts().map { !$0.setsDeveloperInstructions } ?? false
        ) else {
            return .skipped("the cherry skill's files are not ready")
        }
        guard let version = versions.version(of: executableWord) else {
            return .skipped("\(cli.executableName)'s version is not known yet")
        }
        guard version >= cli.minimumVersion else {
            return .skipped("\(cli.executableName) \(version) is older than \(cli.minimumVersion)")
        }
        let approvalWords = approvals(cli) == .autoReview && !AgentApprovals.setsOwnApprovals(cli, words: words)
            ? AgentApprovals.autoReviewArguments(for: cli) : []
        let all = approvalWords + arguments
        guard !all.isEmpty else { return .skipped("nothing to add: the command sets its own instructions") }
        return .appended(AgentLaunch.shellSuffix(all))
    }

    /// Asks the versions of the CLIs of `agents` while it is on (the app's
    /// windows do as the first one opens, so the run's agents find them),
    /// and reads Codex's files.
    func warmUp(agents: [AgentToolDefinition]) {
        guard isEnabled() else { return }
        versions.warmUp(agents: agents)
        _ = codexFacts()
    }
}
