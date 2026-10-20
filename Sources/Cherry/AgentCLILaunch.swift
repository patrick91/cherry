import CherryControl
import Foundation

/// The `cherry` CLI's flags on the command line of the agents Cherry starts
/// (docs/specs/agent-cli.md, Teaching agents and Sandboxes; `AgentLaunch`):
/// the `cherry` skill for that launch and a line saying the agent runs in a
/// Cherry tab, which reaches Cherry with the `cherry` on its PATH
/// (`TabCLIDirectory`).
///
/// - Claude Code: `--plugin-dir <agent-skill>/cherry-plugin`
///   (`AgentSkillDirectory`), `--append-system-prompt <line>`, and
///   `--settings` letting its sandbox, when the user turned it on, reach
///   the app's control socket (`sandbox.network.allowUnixSockets`: array
///   settings merge across Claude Code's scopes, and `--settings` is one,
///   so the user's own list stays).
/// - Pi: `--skill <cherry-plugin>/skills/cherry` and
///   `--append-system-prompt <line>`.
/// - Codex has no flag for a skill: `-c developer_instructions=<line>`, which
///   names `cherry skill show`. A sandbox that cannot reach the socket makes
///   `cherry` fail there unless Cherry's rules file is installed
///   (`CodexLaunchFacts.rulesInstalled`: an allowed `cherry` command runs
///   outside it) or Approvals is Auto review (its reviewer decides on
///   running it outside); otherwise Codex asks the user to.
///
/// Approvals (`AgentApprovals`, Settings › Agents) add to them.
enum AgentCLILaunch {
    /// The line a launch appends to the agent's instructions: no `'`, `"`
    /// or `\`, so it reads the same in every shell's single quotes and as a
    /// TOML basic string.
    static func instructionLine(processID: String?, hasSkill: Bool) -> String {
        let tab = processID.map { "You run in a Cherry tab (CHERRY_PROCESS_ID \($0))." } ?? "You run in a Cherry tab."
        let how = hasSkill
            ? "load the cherry skill, or run cherry skill show, before your first other cherry command."
            : "run cherry skill show for its guide before your first other cherry command."
        return tab + " Cherry is the terminal app around you, and the cherry command on your PATH reaches this tab and the others: " + how
    }

    /// Claude Code's `--settings` JSON that lets its sandbox connect to
    /// `socketPath`.
    static func claudeSandboxSettings(socketPath: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = ["sandbox": ["network": ["allowUnixSockets": [socketPath]]]]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `words` (a command's arguments) already set the agent's
    /// instructions: Claude Code's and Pi's `--system-prompt*` and
    /// `--append-system-prompt*`, Codex's `developer_instructions` or
    /// `model_instructions_file` in a `-c`.
    static func setsOwnInstructions(_ cli: AgentLaunch.CLI, words: [String]) -> Bool {
        switch cli {
        case .claudeCode, .pi:
            words.contains { $0.hasPrefix("--system-prompt") || $0.hasPrefix("--append-system-prompt") }
        case .codex:
            words.contains { $0.contains("developer_instructions") || $0.contains("model_instructions_file") }
        }
    }

    /// The words a CLI launch appends (unquoted), or nil when one of the
    /// paths cannot go on a command line (`AgentLaunch.isLinePath`).
    /// `pluginDirectory` is the app's (`AgentSkillDirectory.current`);
    /// `socketPath` the app's control socket; `addsInstructions` false
    /// leaves the agent's instructions alone.
    static func arguments(
        for cli: AgentLaunch.CLI,
        words: [String],
        pluginDirectory: URL?,
        socketPath: String?,
        processID: String?,
        addsInstructions: Bool
    ) -> [String]? {
        let instructions = addsInstructions && !setsOwnInstructions(cli, words: words)
        switch cli {
        case .claudeCode:
            guard let plugin = pluginDirectory?.path, AgentLaunch.isLinePath(plugin) else { return nil }
            var arguments = ["--plugin-dir", plugin]
            if instructions {
                arguments += ["--append-system-prompt", instructionLine(processID: processID, hasSkill: true)]
            }
            // One `--settings` only: a command with its own keeps it.
            if let socketPath, AgentLaunch.isLinePath(socketPath),
               !words.contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") }),
               let settings = claudeSandboxSettings(socketPath: socketPath) {
                arguments += ["--settings", settings]
            }
            return arguments
        case .pi:
            guard let plugin = pluginDirectory else { return nil }
            let skill = AgentSkillDirectory.skillDirectory(inPlugin: plugin).path
            guard AgentLaunch.isLinePath(skill) else { return nil }
            var arguments = ["--skill", skill]
            if instructions {
                arguments += ["--append-system-prompt", instructionLine(processID: processID, hasSkill: true)]
            }
            return arguments
        case .codex:
            guard instructions else { return [] }
            return codexInstructions(processID: processID)
        }
    }

    /// The words a device agent's launch appends (`RemoteAgentLaunch`):
    /// the line, which names `cherry skill show` (the device has no skill
    /// files), and for Claude Code the sandbox setting for the forwarded
    /// `socketPath`. Nil when the socket's path cannot go on a command line.
    static func deviceArguments(for cli: AgentLaunch.CLI, words: [String], socketPath: String, processID: String?) -> [String]? {
        let instructions = !setsOwnInstructions(cli, words: words)
        switch cli {
        case .claudeCode:
            guard AgentLaunch.isLinePath(socketPath) else { return nil }
            var arguments: [String] = []
            if instructions {
                arguments += ["--append-system-prompt", instructionLine(processID: processID, hasSkill: false)]
            }
            if !words.contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") }),
               let settings = claudeSandboxSettings(socketPath: socketPath) {
                arguments += ["--settings", settings]
            }
            return arguments
        case .pi:
            return instructions ? ["--append-system-prompt", instructionLine(processID: processID, hasSkill: false)] : []
        case .codex:
            return instructions ? codexInstructions(processID: processID) : []
        }
    }

    private static func codexInstructions(processID: String?) -> [String] {
        ["-c", "developer_instructions=" + AgentLaunch.tomlString(instructionLine(processID: processID, hasSkill: false))]
    }
}

/// Settings › Agents › an agent's Approvals, for the agents Cherry
/// starts of one CLI: as the agent is configured, or Auto review (Claude
/// Code `--permission-mode auto`, its classifier deciding each action;
/// Codex `--approve-for-me`, approval requests going to Codex's automatic
/// reviewer with the workspace-write sandbox). It covers everything the
/// agent does in that tab, not only `cherry`, so it is off unless chosen,
/// and never added to a command that sets a mode of its own.
enum AgentApprovals: String, CaseIterable, Sendable {
    case configured
    case autoReview

    /// `agents.approvals.claudeCode`, `agents.approvals.codex`.
    static func defaultsKey(for cli: AgentLaunch.CLI) -> String {
        "agents.approvals.\(cli.rawValue)"
    }

    /// The CLIs that have an automatic review.
    static func isOffered(for cli: AgentLaunch.CLI) -> Bool {
        cli != .pi
    }

    /// The stored choice, as a launch reads it (a string; anything else is
    /// As configured).
    static func current(for cli: AgentLaunch.CLI, defaults: UserDefaults = .standard) -> AgentApprovals {
        guard isOffered(for: cli),
              let raw = defaults.object(forKey: defaultsKey(for: cli)) as? String,
              let value = AgentApprovals(rawValue: raw)
        else { return .configured }
        return value
    }

    var title: String {
        switch self {
        case .configured: "As configured"
        case .autoReview: "Auto review"
        }
    }

    /// What Auto review appends for `cli`.
    static func autoReviewArguments(for cli: AgentLaunch.CLI) -> [String] {
        switch cli {
        case .claudeCode: ["--permission-mode", "auto"]
        case .codex: ["--approve-for-me"]
        case .pi: []
        }
    }

    /// Whether `words` (a command's arguments) set the CLI's approvals
    /// already: Claude Code's `--permission-mode`, `--dangerously-skip-permissions`,
    /// `--allow-dangerously-skip-permissions`, `--permission-prompt-tool`;
    /// Codex's `--approve-for-me`, `-a`/`--ask-for-approval`, `-s`/`--sandbox`,
    /// `--dangerously-bypass-approvals-and-sandbox`, `--full-auto`, `--yolo`,
    /// or a `-c` of `approval_policy`, `approvals_reviewer` or `sandbox_mode`.
    /// From Claude Code 2.1.303's and Codex 0.162.1's `--help`; recheck
    /// after an upgrade.
    static func setsOwnApprovals(_ cli: AgentLaunch.CLI, words: [String]) -> Bool {
        func has(_ option: String) -> Bool {
            words.contains { $0 == option || $0.hasPrefix(option + "=") }
        }
        switch cli {
        case .claudeCode:
            return ["--permission-mode", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                    "--permission-prompt-tool"].contains(where: has)
        case .codex:
            if ["--approve-for-me", "-a", "--ask-for-approval", "-s", "--sandbox",
                "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--yolo"].contains(where: has) {
                return true
            }
            // `-afoo`, `-sread-only`: short options with their value attached.
            if words.contains(where: { ($0.hasPrefix("-a") || $0.hasPrefix("-s")) && !$0.hasPrefix("--") && $0.count > 2 }) {
                return true
            }
            return words.contains { word in
                ["approval_policy", "approvals_reviewer", "sandbox_mode"].contains { word.contains($0) }
            }
        case .pi:
            return false
        }
    }
}

/// What a Codex launch needs to know of Codex's own files, read off the
/// main thread (`CodexLaunchFactsCache`): whether Cherry's rules file is
/// installed, whether the user's `config.toml` sets developer instructions
/// (a launch never replaces them), and whether its sandbox lets a command
/// reach a Unix socket (`sandbox_mode = "danger-full-access"`, or
/// `"workspace-write"` with `[sandbox_workspace_write] network_access =
/// true`; checked with `codex sandbox` on 0.162.1: workspace-write and
/// read-only refuse the connect otherwise).
struct CodexLaunchFacts: Equatable, Sendable {
    var rulesInstalled: Bool
    var setsDeveloperInstructions: Bool
    /// The config's sandbox reaches sockets. False when it selects a
    /// profile (`profile = …`), whose own sandbox is not read.
    var sandboxReachesSockets = false

    /// The sandbox modes, as Codex spells them.
    enum SandboxMode: String {
        case readOnly = "read-only"
        case workspaceWrite = "workspace-write"
        case dangerFullAccess = "danger-full-access"
    }

    /// Whether the sandbox of a launch with these `words` (a command's
    /// arguments) reaches sockets: the command's own choice
    /// (`--dangerously-bypass-approvals-and-sandbox`, `-s`/`--sandbox`,
    /// `-c sandbox_mode=…`, `-c sandbox_workspace_write.network_access=true`)
    /// over the config's; a launch with `-p`/`--profile` reads as one that
    /// does not (its profile is not read).
    func launchReachesSockets(words: [String]) -> Bool {
        if words.contains("--dangerously-bypass-approvals-and-sandbox") { return true }
        var mode: SandboxMode?
        var networkAccess: Bool?
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            func value(_ option: String) -> String? {
                if word == option { return next }
                if word.hasPrefix(option + "=") { return String(word.dropFirst(option.count + 1)) }
                return nil
            }
            if let sandbox = value("--sandbox") ?? value("-s") ?? (word.hasPrefix("-s") && !word.hasPrefix("--") && word.count > 2 ? String(word.dropFirst(2)) : nil) {
                mode = SandboxMode(rawValue: sandbox) ?? .readOnly
            } else if let config = value("--config") ?? value("-c") {
                let (key, raw) = Self.keyValue(config)
                if key == "sandbox_mode" { mode = SandboxMode(rawValue: raw) ?? .readOnly }
                if key == "sandbox_workspace_write.network_access" { networkAccess = raw == "true" }
            } else if value("--profile") != nil || value("-p") != nil {
                return mode == .dangerFullAccess
            }
            index += 1
        }
        // Without a mode of its own the config's decides (a `-c` of
        // network access alone is not read against it).
        switch mode {
        case .dangerFullAccess?: return true
        case .readOnly?: return false
        case .workspaceWrite?: return networkAccess == true
        case nil: return sandboxReachesSockets
        }
    }

    /// `key=value` of a `-c`, the value's TOML quotes removed.
    static func keyValue(_ text: String) -> (key: String, value: String) {
        guard let equals = text.firstIndex(of: "=") else { return (text, "") }
        let key = text[..<equals].trimmingCharacters(in: .whitespaces)
        var value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// Whether a `config.toml` (top-level keys before any table, and its
    /// `[sandbox_workspace_write]` table) lets the sandbox reach sockets.
    static func sandboxReachesSockets(_ config: String) -> Bool {
        var table = ""
        var mode: SandboxMode?
        var networkAccess = false
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") {
                table = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            let (key, rawValue) = keyValue(String(trimmed.split(separator: "#", maxSplits: 1).first ?? ""))
            switch (table, key) {
            case ("", "profile"):
                return false
            case ("", "sandbox_mode"):
                mode = SandboxMode(rawValue: rawValue)
            case ("sandbox_workspace_write", "network_access"):
                networkAccess = rawValue == "true"
            default:
                break
            }
        }
        switch mode {
        case .dangerFullAccess?: return true
        case .workspaceWrite?: return networkAccess
        case .readOnly?, nil: return false
        }
    }

    /// The first line of the rules file Cherry writes (`cherry skill setup`,
    /// Connect): only a file that starts with it is Cherry's.
    static let rulesMarker = CherrySkill.rulesFirstLine

    /// `<codexHome>/rules/cherry.rules`.
    static func rulesFile(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("rules", isDirectory: true).appendingPathComponent("cherry.rules", isDirectory: false)
    }

    /// `CODEX_HOME` from `environment` (absolute), else `~/.codex`.
    static func codexHome(environment: [String: String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let home = environment["CODEX_HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Reads them (blocking; small files only).
    static func read(codexHome: URL) -> CodexLaunchFacts {
        let rules = (try? String(contentsOf: rulesFile(codexHome: codexHome), encoding: .utf8))?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml", isDirectory: false), encoding: .utf8)) ?? ""
        return CodexLaunchFacts(
            rulesInstalled: rules == rulesMarker,
            setsDeveloperInstructions: Self.setsDeveloperInstructions(config),
            sandboxReachesSockets: Self.sandboxReachesSockets(config)
        )
    }

    /// Whether a `config.toml` sets `developer_instructions` or
    /// `model_instructions_file` (anywhere: a profile's counts too).
    static func setsDeveloperInstructions(_ config: String) -> Bool {
        config.split(separator: "\n").contains { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return ["developer_instructions", "model_instructions_file"].contains { key in
                guard trimmed.hasPrefix(key) else { return false }
                return trimmed.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" }).first == "="
            }
        }
    }
}

/// The last reading of `CodexLaunchFacts`, which a launch uses as it is
/// (never waiting) and refreshes in the background for the next one; nil
/// until the first reading finished: a Codex launch then gets no
/// instructions line.
@MainActor
final class CodexLaunchFactsCache {
    static let shared = CodexLaunchFactsCache()

    private(set) var facts: CodexLaunchFacts?
    private var isReading = false
    private let codexHome: @Sendable () -> URL

    init(codexHome: @escaping @Sendable () -> URL = {
        CodexLaunchFacts.codexHome(environment: HostedSessionLoginEnvironment.shared.availableNow()?.environment ?? [:])
    }) {
        self.codexHome = codexHome
    }

    /// The facts as last read, and a new reading started.
    func current() -> CodexLaunchFacts? {
        refresh()
        return facts
    }

    func refresh() {
        guard !isReading else { return }
        isReading = true
        let codexHome = codexHome
        Task.detached(priority: .utility) { [weak self] in
            let facts = CodexLaunchFacts.read(codexHome: codexHome())
            await MainActor.run {
                self?.facts = facts
                self?.isReading = false
            }
        }
    }
}
