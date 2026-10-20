import CherryControl
import CherryMCP
import Darwin
import Foundation
import Testing
@testable import Cherry

// The `cherry` CLI on the command line of the agents Cherry starts
// (AgentCLILaunch, AgentApprovals, CodexLaunchFacts, AgentSkillDirectory;
// docs/specs/agent-cli.md): which agents get its flags, their words,
// Approvals', Codex's sandbox rules, the skill's files, and the texts Cherry
// types into a tab. No real CLI runs: the CLIs
// are stand-in scripts, the versions seeded, Codex's home a temporary
// directory, and every context and UserDefaults the test's own.

private let cliSocketPath = "/tmp/cherry-test-501/control.sock"

private func cliTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-cli-launch-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Stand-in `claude`, `codex` and `pi` with seeded versions, a prepared
/// skill directory, and a context whose Approvals and Codex facts the test
/// sets.
@MainActor
private final class CLILaunchHarness {
    let directory: URL
    let claude: URL
    let codex: URL
    let pi: URL
    let plugin: URL
    let versions: AgentCLIVersions
    var approvals: [AgentLaunch.CLI: AgentApprovals] = [:]
    var codexFacts: CodexLaunchFacts?
    var skillReady = true

    init() throws {
        directory = try cliTemporaryDirectory("harness")
        claude = directory.appendingPathComponent("bin/claude")
        codex = directory.appendingPathComponent("bin/codex")
        pi = directory.appendingPathComponent("bin/pi")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for url in [claude, codex, pi] {
            try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
            #expect(chmod(url.path, 0o755) == 0)
        }
        plugin = try #require(AgentSkillDirectory.prepare(
            plugin: directory.appendingPathComponent("agent-skill/cherry-plugin", isDirectory: true), canWrite: true
        ))
        versions = AgentCLIVersions(environment: { ["PATH": "/usr/bin:/bin"] })
        versions.seed([
            claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 303),
            codex.path: AgentCLIVersion(major: 0, minor: 162, patch: 1),
            pi.path: AgentCLIVersion(major: 1, minor: 3, patch: 0),
        ])
    }

    var context: AgentLaunchContext {
        AgentLaunchContext(
            isEnabled: { true },
            versions: versions,
            pluginDirectory: { [unowned self] in skillReady ? plugin : nil },
            controlSocketPath: { cliSocketPath },
            approvals: { [unowned self] in approvals[$0] ?? .configured },
            codexFacts: { [unowned self] in codexFacts }
        )
    }

    func outcome(_ commandLine: String, processID: String = "TAB") -> AgentLaunch.Outcome {
        context.outcome(commandLine: commandLine, processID: processID)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func suffix(_ words: [String]) -> String {
    AgentLaunch.shellSuffix(words)
}

@Test @MainActor func controlToolLaunchCLIClaudeCodeGetsThePluginItsLineAndTheSocketForItsSandbox() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let line = AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: true)
    let settings = try #require(AgentCLILaunch.claudeSandboxSettings(socketPath: cliSocketPath))
    #expect(settings == #"{"sandbox":{"network":{"allowUnixSockets":["/tmp/cherry-test-501/control.sock"]}}}"#)
    #expect(harness.outcome(harness.claude.path) == .appended(suffix([
        "--plugin-dir", harness.plugin.path, "--append-system-prompt", line, "--settings", settings,
    ])))
    // Instructions and settings of its own are kept; the plugin is added.
    #expect(harness.outcome("\(harness.claude.path) --append-system-prompt mine --settings /x.json") == .appended(suffix([
        "--plugin-dir", harness.plugin.path,
    ])))
    // The line reads the same in every shell's single quotes and in TOML.
    #expect(!line.contains("'") && !line.contains("\"") && !line.contains("\\"))
    #expect(line.contains("CHERRY_PROCESS_ID TAB") && line.contains("cherry skill show"))

    // Without the skill's files it starts as it is.
    harness.skillReady = false
    #expect(harness.outcome(harness.claude.path) == .skipped("the cherry skill's files are not ready"))
}

@Test @MainActor func controlToolLaunchCLIPiGetsTheSkillDirectoryAndNoExtension() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let skill = AgentSkillDirectory.skillDirectory(inPlugin: harness.plugin).path
    #expect(FileManager.default.fileExists(atPath: skill + "/SKILL.md"))
    #expect(harness.outcome("\(harness.pi.path) --model x") == .appended(suffix([
        "--skill", skill, "--append-system-prompt", AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: true),
    ])))
    // Pi has no automatic review: Approvals adds nothing.
    harness.approvals[.pi] = .autoReview
    #expect(harness.outcome("\(harness.pi.path) --system-prompt mine") == .appended(suffix(["--skill", skill])))
}

@Test @MainActor func controlToolLaunchCLICodexGetsTheLineUnlessItsConfigSetsInstructions() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let instructions = "developer_instructions=" + AgentLaunch.tomlString(AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: false))

    // Its settings not read yet: nothing (its config may set instructions).
    #expect(harness.outcome(harness.codex.path) == .skipped("nothing to add: the command sets its own instructions"))

    // Whatever its sandbox: one that blocks the socket asks before each
    // cherry command runs outside it.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false)
    #expect(harness.outcome(harness.codex.path) == .appended(suffix(["-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -s workspace-write") == .appended(suffix(["-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -c developer_instructions=mine")
        == .skipped("nothing to add: the command sets its own instructions"))

    // A config with instructions of its own keeps them.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: true, setsDeveloperInstructions: true)
    #expect(harness.outcome(harness.codex.path) == .skipped("nothing to add: the command sets its own instructions"))

    // Auto review: added only where the command sets no approvals of its own.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false)
    harness.approvals[.codex] = .autoReview
    #expect(harness.outcome(harness.codex.path) == .appended(suffix(["--approve-for-me", "-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -a never") == .appended(suffix(["-c", instructions])))

    // Which sandboxes reach the socket (the settings page says so).
    let facts = CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false)
    #expect(facts.launchReachesSockets(words: ["--sandbox", "danger-full-access"]))
    #expect(facts.launchReachesSockets(words: ["-c", "sandbox_mode=\"danger-full-access\""]))
    #expect(facts.launchReachesSockets(words: ["-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true"]))
    #expect(!facts.launchReachesSockets(words: ["-s", "workspace-write"]))
    var reaching = facts
    reaching.sandboxReachesSockets = true
    #expect(reaching.launchReachesSockets(words: []))
    #expect(!reaching.launchReachesSockets(words: ["-p", "work"]))
    #expect(!reaching.launchReachesSockets(words: ["-s", "read-only"]))
}

@Test @MainActor func controlToolLaunchCLIApprovalsGoFirstAndNeverOverACommandsOwnMode() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    harness.approvals[.claudeCode] = .autoReview
    let outcome = harness.outcome(harness.claude.path)
    guard case .appended(let words) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(words.hasPrefix(suffix(["--permission-mode", "auto", "--plugin-dir"])))
    for own in ["--dangerously-skip-permissions", "--permission-mode plan", "--allow-dangerously-skip-permissions"] {
        guard case .appended(let kept) = harness.outcome("\(harness.claude.path) \(own)") else {
            Issue.record("\(own)")
            continue
        }
        #expect(!kept.contains("'--permission-mode' 'auto'"), "\(own)")
    }
    #expect(AgentApprovals.setsOwnApprovals(.codex, words: ["-sread-only"]))
    #expect(AgentApprovals.setsOwnApprovals(.codex, words: ["-c", "approval_policy=\"never\""]))
    #expect(!AgentApprovals.setsOwnApprovals(.codex, words: ["--search", "-m", "o3"]))
    #expect(AgentApprovals.defaultsKey(for: .codex) == "agents.approvals.codex")
    let suite = "CherryTests.ControlToolLaunchCLI.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(AgentApprovals.current(for: .claudeCode, defaults: defaults) == .configured)
    AgentSettingsPage.setApprovals(.autoReview, for: .claudeCode, defaults: defaults)
    #expect(AgentApprovals.current(for: .claudeCode, defaults: defaults) == .autoReview)
    AgentSettingsPage.setApprovals(.configured, for: .claudeCode, defaults: defaults)
    #expect(defaults.object(forKey: AgentApprovals.defaultsKey(for: .claudeCode)) == nil)
}

@Test func controlToolLaunchCLICodexFactsReadItsRulesAndConfig() throws {
    let home = try cliTemporaryDirectory("codex-home")
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(CodexLaunchFacts.read(codexHome: home) == CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false))

    let rules = CodexLaunchFacts.rulesFile(codexHome: home)
    try FileManager.default.createDirectory(at: rules.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# someone else's\nprefix_rule()\n".write(to: rules, atomically: true, encoding: .utf8)
    #expect(!CodexLaunchFacts.read(codexHome: home).rulesInstalled)
    try (CodexLaunchFacts.rulesMarker + "\nprefix_rule()\n").write(to: rules, atomically: true, encoding: .utf8)
    #expect(CodexLaunchFacts.read(codexHome: home).rulesInstalled)

    try """
    model = "o3"
    sandbox_mode = "danger-full-access"   # no sandbox
    developer_instructions = "be brief"
    """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let facts = CodexLaunchFacts.read(codexHome: home)
    #expect(facts.setsDeveloperInstructions && facts.sandboxReachesSockets)

    #expect(CodexLaunchFacts.sandboxReachesSockets("sandbox_mode = 'workspace-write'\n[sandbox_workspace_write]\nnetwork_access = true\n"))
    #expect(!CodexLaunchFacts.sandboxReachesSockets("sandbox_mode = \"workspace-write\"\n"))
    #expect(!CodexLaunchFacts.sandboxReachesSockets("[profiles.x]\nsandbox_mode = \"danger-full-access\"\n"))
    #expect(!CodexLaunchFacts.sandboxReachesSockets("profile = \"x\"\nsandbox_mode = \"danger-full-access\"\n"))
    #expect(!CodexLaunchFacts.setsDeveloperInstructions("model = \"o3\"\n# developer_instructions = \"x\"\n"))
    #expect(CodexLaunchFacts.codexHome(environment: ["CODEX_HOME": "/x/codex"]).path == "/x/codex")
    #expect(CodexLaunchFacts.codexHome(environment: ["CODEX_HOME": "rel"], homeDirectory: home).path == home.appendingPathComponent(".codex").path)
}

@Test func controlToolLaunchCLISkillFilesAreTheSkillCherryPrints() throws {
    let root = try cliTemporaryDirectory("skill")
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("cherry-plugin", isDirectory: true)
    #expect(AgentSkillDirectory.prepare(plugin: plugin, canWrite: false) == nil)
    #expect(AgentSkillDirectory.prepare(plugin: plugin, canWrite: true) == plugin)
    let skill = try String(contentsOf: AgentSkillDirectory.skillDirectory(inPlugin: plugin).appendingPathComponent("SKILL.md"), encoding: .utf8)
    #expect(skill == CherryCLIGuide.skillMarkdown + "\n")
    let manifest = try Data(contentsOf: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
    let object = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    #expect(object["name"] as? String == "cherry")
    // Another copy of the app uses what is there.
    #expect(AgentSkillDirectory.prepare(plugin: plugin, canWrite: false) == plugin)
    // A changed file is written again by the lock holder only.
    try "old".write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
    #expect(AgentSkillDirectory.prepare(plugin: plugin, canWrite: false) == nil)
    #expect(AgentSkillDirectory.prepare(plugin: plugin, canWrite: true) == plugin)
}

@Test @MainActor func controlToolLaunchCLIWorkerTextsNameTheCherryCommands() {
    let kickoff = AgentTaskRegistry.kickoffLine(taskID: "task-1")
    #expect(kickoff.contains("cherry task mine") && kickoff.contains("cherry task report"))
    #expect(!kickoff.contains("CHERRY_MCP_HELPER") && !kickoff.contains("get_my_task"))

    let rules = AgentTaskRegistry.workerRules(allowSubagents: true).joined(separator: "\n")
    for mcp in ["report_result", "report_progress", "spawn_agent", "CHERRY_MCP_HELPER", "awaiting_approval true"] {
        #expect(!rules.contains(mcp), "\(mcp)")
    }
    #expect(rules.contains("cherry task progress --awaiting-approval") && rules.contains("cherry task report <<'EOF'"))

    #expect(AgentTaskRegistry.nudgeLine == "Please run cherry task report with your result.")
    var counts = AgentRunCounts()
    counts.total = 2
    counts.reported = 1
    counts.failed = 1
    let wake = AgentTaskRegistry.wakeLine(runID: "run-1", counts: counts)
    #expect(wake.contains("cherry task wait run-1") && !wake.contains("wait_for_tasks"))
    var waiting = AgentRunCounts()
    waiting.total = 1
    waiting.awaitingApproval = 1
    let approval = AgentTaskRegistry.approvalWakeLine(runID: "run-1", counts: waiting)
    #expect(approval.contains("cherry task wait run-1") && approval.contains("cherry send"))
}

@Test @MainActor func controlToolLaunchCLIATabStartedWithTheCLIKnowsIt() async throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    var policy = SessionBackendPolicy.native
    policy.agentLaunch = harness.context
    let workspace = TerminalWorkspace(
        projectRoot: harness.directory.path, createInitialSession: false, launchBackend: .hostManaged, backendPolicy: policy
    )
    defer { workspace.closeAllSessions() }
    let claude = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: harness.claude.path), projectRoot: harness.directory.path
    )
    #expect(claude.lastAgentLaunchOutcome.map { if case .appended = $0 { true } else { false } } == true)
    #expect(claude.launchStartupCommand?.contains("CHERRY_PROCESS_ID \(claude.id.uuidString)") == true)
    #expect(claude.launchCommand == harness.claude.path)

    let codex = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: harness.codex.path), projectRoot: harness.directory.path
    )
    #expect(codex.lastAgentLaunchOutcome == .skipped("nothing to add: the command sets its own instructions"))
    #expect(codex.launchStartupCommand == nil)
}

@Test @MainActor func controlToolLaunchCLISettingsInterfaceLineSaysWhichAndWhy() {
    func interface(_ cli: AgentLaunch.CLI, _ command: String = "x", connects: Bool = true, skill: Bool = true,
                   approvals: AgentApprovals = .configured, facts: CodexLaunchFacts? = nil) -> AgentSettingsPage.Interface {
        AgentSettingsPage.interface(
            cli: cli, commandLine: command, connectsAtLaunch: connects, skillReady: skill, approvals: approvals, codexFacts: facts
        )
    }
    #expect(interface(.claudeCode).startsWithCLI)
    #expect(interface(.claudeCode).status == "The cherry command")
    #expect(!interface(.claudeCode, skill: false).startsWithCLI)
    #expect(interface(.claudeCode, connects: false).status == "Started as it is")
    #expect(interface(.codex).startsWithCLI)
    #expect(interface(.codex).help.contains("asks you before each cherry command"))
    #expect(interface(.codex, "codex --dangerously-bypass-approvals-and-sandbox").help.contains("lets it reach Cherry's socket"))
    #expect(interface(.codex, approvals: .autoReview).help.contains("reviewer"))
    #expect(interface(.codex, facts: CodexLaunchFacts(rulesInstalled: true, setsDeveloperInstructions: false)).help.contains("rules"))
    #expect(AgentSettingsPage.launchCLI(of: AgentToolDefinition(name: "Codex", command: "codex")) == .codex)
    #expect(AgentSettingsPage.launchCLI(of: AgentToolDefinition(name: "Amp", command: "amp")) == nil)
}
