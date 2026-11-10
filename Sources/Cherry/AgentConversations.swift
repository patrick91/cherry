import CherryControl
import Foundation

/// The conversation an agent tab's CLI keeps on disk, which Restart resumes
/// once the system ended the tab's program (a restart, a log out or a lost
/// holder: `SystemEndedSessions`, `HostSessionEnd.isHolderLost`) instead of
/// starting a new one (`TerminalSession.conversationToResume`). Saved with
/// the tab (`WorkspaceSessionRecord.agentConversation`).
struct AgentConversation: Equatable, Sendable {
    /// Claude Code or Codex.
    let cli: AgentLaunch.CLI
    /// Claude Code's session id or Codex's thread id: a UUID, as the CLI
    /// writes it.
    let id: String

    /// Nil unless `id` is a UUID of Claude Code's or Codex's: what goes on
    /// a command line is never anything else.
    init?(cli: AgentLaunch.CLI, id: String) {
        guard cli != .pi, UUID(uuidString: id) != nil else { return nil }
        self.cli = cli
        self.id = id
    }

    /// The conversation a record names; nil for none, or one this build
    /// cannot resume.
    init?(_ record: AgentConversationRecord?) {
        guard let record, let cli = AgentLaunch.CLI(rawValue: record.cli) else { return nil }
        self.init(cli: cli, id: record.id)
    }

    var record: AgentConversationRecord {
        AgentConversationRecord(cli: cli.rawValue, id: id)
    }
}

/// An `AgentConversation` as a tab's record saves it: two strings, so a
/// record never fails to read over it (another build's CLI, a damaged id).
struct AgentConversationRecord: Codable, Equatable, Sendable {
    /// `AgentLaunch.CLI`'s raw value: `claudeCode` or `codex`.
    var cli: String
    var id: String
}

/// Which conversation an agent tab's CLI has, as the Mac the tab's session
/// runs on says: `cherry host transcript <session> --locate` there
/// (Host/crates/cherry-cli/src/transcript.rs: Claude Code's registry of its
/// processes, the Codex rollout its processes have open, never a subagent's),
/// the lookup Cherry for iPhone shows conversations by. This Mac runs the
/// app's own `cherry`; a device the `cherry` of its install, over its ssh
/// (the master while it is up). Asked while the tab's program runs
/// (`TerminalSession.scheduleAgentConversationCapture`): a tab the system
/// ended resumes the last answer. The CLIs' files are only read, there.
/// Only the app's windows have one (`SessionBackendPolicy.agentConversations`);
/// tests give their own.
struct AgentConversationLocator: Sendable {
    /// Runs `cherry host transcript <session> --locate` where the session
    /// runs, with these variables added, and gives what it printed; nil
    /// when it failed, could not run, or the Mac could not be reached.
    var run: @Sendable (_ session: String, _ variables: [String: String]) async -> Data?
    /// How long after something changed a tab asks (the CLI writes its file
    /// with the first message; `/clear`, `/new` or `/resume` switches it),
    /// and how far apart a tab's asks are.
    var delay: TimeInterval = 3
    var interval: TimeInterval = 5

    init(
        delay: TimeInterval = 3,
        interval: TimeInterval = 5,
        run: @escaping @Sendable (_ session: String, _ variables: [String: String]) async -> Data?
    ) {
        self.delay = delay
        self.interval = interval
        self.run = run
    }

    /// The conversation of the agent of CLI `cli` that session `session`
    /// runs; nil before its first message (there is nothing to resume yet),
    /// for another agent, or when the Mac could not say. `environment`: the
    /// tab's own, whose `CLAUDE_CONFIG_DIR` and `CODEX_HOME` move the CLI's
    /// folders (an agent definition's variables; absolute paths only).
    func conversation(ofSession session: String, cli: AgentLaunch.CLI, environment: [String: String]) async -> AgentConversation? {
        let variables = environment.filter { Self.folderVariables.contains($0.key) && $0.value.hasPrefix("/") }
        guard let answer = await run(session, variables) else { return nil }
        return Self.conversation(in: answer, cli: cli)
    }

    static let folderVariables: Set<String> = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"]

    private struct Located: Decodable {
        var agent: String
        var session_id: String?
    }

    /// The conversation `--locate` printed (`{"agent", "session_id", "path"}`)
    /// when it is of `cli`'s.
    static func conversation(in answer: Data, cli: AgentLaunch.CLI) -> AgentConversation? {
        guard let located = try? JSONDecoder().decode(Located.self, from: answer),
              let id = located.session_id
        else { return nil }
        let agent: AgentLaunch.CLI? = switch located.agent {
        case "claude": .claudeCode
        case "codex": .codex
        default: nil
        }
        guard agent == cli else { return nil }
        return AgentConversation(cli: cli, id: id)
    }

    /// This Mac's: the app's own `cherry`, with its helpers' environment.
    static let thisMac = AgentConversationLocator { session, variables in
        guard let client = try? HostedSessionClient.installed() else { return nil }
        let login = await client.resolvedLoginEnvironment()
        var environment = HostedSessionLoginEnvironment.helperEnvironment(
            base: ProcessInfo.processInfo.environment, login: login?.environment
        )
        environment.merge(variables) { $1 }
        let executable = client.executableURL
        let result = await Task.detached(priority: .utility) {
            CapturedProcess.run(
                executable: executable,
                arguments: ["host", "transcript", session, "--locate"],
                environment: environment,
                input: nil,
                timeout: 10
            )
        }.value
        guard result.launchError == nil, result.exitedNormally, result.status == 0 else { return nil }
        return result.standardOutput
    }

    /// The first line the device's script prints.
    static let deviceBegin = "CHERRY-AGENT-CONVERSATION 1"
    /// The most bytes of a device's answer read.
    static let deviceAnswerLimit = 64 * 1024

    /// A device's: its install's `cherry` (nothing without one of ours),
    /// over its ssh, so a tab asks less often.
    @MainActor static func device(_ hosting: PersistentHostSessions) -> AgentConversationLocator {
        let host = hosting.profile.host
        return AgentConversationLocator(interval: 15) { session, variables in
            let found = await MainActor.run { () -> (destination: String, cli: String)? in
                guard let device = RemoteDeviceStore.shared.device(for: host),
                      let cli = RemoteMCPPaths.cliPath(remoteHostPath: device.remoteHostPath, homeDirectory: device.homeDirectory)
                else { return nil }
                return (device.sshDestination, cli)
            }
            guard let found else { return nil }
            let shell = await RemoteDeviceShell.app(through: found.destination, timeout: 20)
            let output = await shell.runData(Self.deviceScript(session: session, cli: found.cli, variables: variables), on: found.destination)
            return Self.deviceAnswer(output)
        }
    }

    /// The `sh -s` script that asks a device's `cherry`.
    static func deviceScript(session: String, cli: String, variables: [String: String]) -> String {
        var lines = variables.sorted { $0.key < $1.key }.map { "export \($0.key)=\(RemoteDeviceProbe.singleQuoted($0.value))" }
        lines.append("printf '%s\\n' '\(deviceBegin)'")
        lines.append("exec \(RemoteDeviceProbe.shellWord(cli)) host transcript \(RemoteDeviceProbe.singleQuoted(session)) --locate")
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the device's `cherry` printed after the script's first line,
    /// when it answered.
    static func deviceAnswer(_ output: RemoteDeviceShell.DataOutput) -> Data? {
        guard output.status == 0, !output.timedOut else { return nil }
        let text = output.standardOutput.prefix(deviceAnswerLimit + 64)
        guard let marker = text.range(of: Data((deviceBegin + "\n").utf8)) else { return nil }
        let body = text[marker.upperBound...]
        return body.count <= deviceAnswerLimit ? Data(body) : nil
    }
}

/// An agent's command line that resumes its conversation instead of
/// starting one: Claude Code's `--resume <id>` and Codex's `resume <id>`,
/// appended to the tab's command (Codex takes its options before the
/// subcommand), before Cherry's flags (`TerminalSession.commandWithAgentFlags`).
enum AgentConversationResume {
    /// `commandLine` resuming `conversation`; nil unless it is a plain
    /// command of that conversation's CLI (`AgentLaunch.detection`) whose
    /// words are all options and their values: a word that is neither (a
    /// prompt, a subcommand, a value of an option Cherry does not know)
    /// would be read again or misread, and an option that picks the session
    /// itself (Claude Code's `--continue`, `--resume`, `--session-id`,
    /// `--fork-session`, `--print`) would fight the one appended.
    static func commandLine(resuming conversation: AgentConversation, from commandLine: String) -> String? {
        guard case .cli(let cli, _) = AgentLaunch.detection(commandLine: commandLine), cli == conversation.cli,
              let words = AgentLaunch.plainWords(commandLine),
              onlyOptions(Array(words.dropFirst()), of: cli)
        else { return nil }
        switch cli {
        case .claudeCode:
            return commandLine + AgentLaunch.shellSuffix(["--resume", conversation.id])
        case .codex:
            return commandLine + AgentLaunch.shellSuffix(["resume", conversation.id])
        case .pi:
            return nil
        }
    }

    /// Claude Code's options that pick or start a session of their own.
    static let claudeSessionOptions: Set<String> = [
        "-c", "--continue", "-r", "--resume", "--session-id", "--fork-session", "-p", "--print", "--from-pr",
    ]

    /// Whether `arguments` are only options, each value-taking one
    /// (`AgentLaunch.CLI.optionsTakingValue`) followed by its value.
    static func onlyOptions(_ arguments: [String], of cli: AgentLaunch.CLI) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            guard word.hasPrefix("-"), word.count > 1 else { return false }
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            if cli == .claudeCode, claudeSessionOptions.contains(name) { return false }
            if !word.contains("="), cli.optionsTakingValue.contains(word) {
                guard index + 1 < arguments.count else { return false }
                index += 2
            } else {
                index += 1
            }
        }
        return true
    }
}
