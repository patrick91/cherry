import CherryControl
import CherryMCP
import Darwin
import Foundation
import Testing
@testable import Cherry

// The `cherry` CLI on the command line of the agents Cherry starts
// (AgentCLILaunch, AgentApprovals, CodexLaunchFacts, AgentSkillDirectory;
// docs/specs/agent-cli.md): which agents get it instead of Cherry MCP, its
// words, Approvals', Codex's sandbox rules, the skill's files, and the
// texts Cherry types into a tab started with it. No real CLI runs: the CLIs
// are stand-in scripts, the versions seeded, Codex's home a temporary
// directory, and every context and UserDefaults the test's own.

private let cliHelperPath = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
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
    var approvals: [AgentMCPLaunch.CLI: AgentApprovals] = [:]
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

    var context: AgentMCPLaunchContext {
        AgentMCPLaunchContext(
            isEnabled: { true },
            versions: versions,
            helperPath: cliHelperPath,
            piExtensionPath: nil,
            cliPluginDirectory: { [unowned self] in skillReady ? plugin : nil },
            controlSocketPath: { cliSocketPath },
            approvals: { [unowned self] in approvals[$0] ?? .configured },
            codexFacts: { [unowned self] in codexFacts }
        )
    }

    func outcome(_ commandLine: String, processID: String = "TAB") -> AgentMCPLaunch.Outcome {
        context.outcome(commandLine: commandLine, serverName: "cherry", environmentKeys: [], processID: processID)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func suffix(_ words: [String]) -> String {
    AgentMCPLaunch.shellSuffix(words)
}

@Test @MainActor func controlToolLaunchCLIClaudeCodeGetsThePluginItsLineAndTheSocketForItsSandbox() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let line = AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: true)
    let settings = try #require(AgentCLILaunch.claudeSandboxSettings(socketPath: cliSocketPath))
    #expect(settings == #"{"sandbox":{"network":{"allowUnixSockets":["/tmp/cherry-test-501/control.sock"]}}}"#)
    #expect(harness.outcome(harness.claude.path) == .cli(suffix([
        "--plugin-dir", harness.plugin.path, "--append-system-prompt", line, "--settings", settings,
    ])))
    // Instructions and settings of its own are kept; the plugin is added.
    #expect(harness.outcome("\(harness.claude.path) --append-system-prompt mine --settings /x.json") == .cli(suffix([
        "--plugin-dir", harness.plugin.path,
    ])))
    // The line reads the same in every shell's single quotes and in TOML.
    #expect(!line.contains("'") && !line.contains("\"") && !line.contains("\\"))
    #expect(line.contains("CHERRY_PROCESS_ID TAB") && line.contains("cherry skill show"))

    // Without the skill's files it gets Cherry MCP, as before.
    harness.skillReady = false
    guard case .appended(let mcp) = harness.outcome(harness.claude.path) else {
        Issue.record("no Cherry MCP without the skill")
        return
    }
    #expect(mcp.contains("'--mcp-config'"))
    #expect(harness.context.cliInterfaceReason(commandLine: harness.claude.path) == "the cherry skill's files are not ready")
}

@Test @MainActor func controlToolLaunchCLIPiGetsTheSkillDirectoryAndNoExtension() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let skill = AgentSkillDirectory.skillDirectory(inPlugin: harness.plugin).path
    #expect(FileManager.default.fileExists(atPath: skill + "/SKILL.md"))
    #expect(harness.outcome("\(harness.pi.path) --model x") == .cli(suffix([
        "--skill", skill, "--append-system-prompt", AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: true),
    ])))
    // Pi has no automatic review: Approvals adds nothing.
    harness.approvals[.pi] = .autoReview
    #expect(harness.outcome("\(harness.pi.path) --system-prompt mine") == .cli(suffix(["--skill", skill])))
}

@Test @MainActor func controlToolLaunchCLICodexGetsItOnlyWhenItCanRunCherry() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    let instructions = "developer_instructions=" + AgentMCPLaunch.tomlString(AgentCLILaunch.instructionLine(processID: "TAB", hasSkill: false))
    func isMCP(_ outcome: AgentMCPLaunch.Outcome) -> Bool {
        if case .appended(let words) = outcome { return words.contains("mcp_servers.cherry=") }
        return false
    }

    // Its settings not read yet: Cherry MCP, unless the command itself
    // turns the sandbox off (then without instructions: its config may set
    // its own).
    #expect(isMCP(harness.outcome(harness.codex.path)))
    #expect(harness.outcome("\(harness.codex.path) --dangerously-bypass-approvals-and-sandbox") == .cli(""))
    #expect(harness.outcome("\(harness.codex.path) -s danger-full-access") == .cli(""))

    // A sandbox that blocks the socket, no rules, As configured.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false)
    #expect(isMCP(harness.outcome(harness.codex.path)))
    #expect(harness.context.cliInterfaceReason(commandLine: harness.codex.path)?.contains("can't reach Cherry's socket") == true)
    #expect(harness.outcome("\(harness.codex.path) --sandbox danger-full-access") == .cli(suffix(["-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -c sandbox_mode=\"danger-full-access\"") == .cli(suffix(["-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -s workspace-write -c sandbox_workspace_write.network_access=true")
        == .cli(suffix(["-c", instructions])))
    #expect(isMCP(harness.outcome("\(harness.codex.path) -s workspace-write")))

    // A config whose sandbox reaches sockets; a profile is not read.
    harness.codexFacts?.sandboxReachesSockets = true
    #expect(harness.outcome(harness.codex.path) == .cli(suffix(["-c", instructions])))
    #expect(isMCP(harness.outcome("\(harness.codex.path) -p work")))
    #expect(isMCP(harness.outcome("\(harness.codex.path) -s read-only")))

    // Cherry's rules: allowed cherry commands run outside the sandbox.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: true, setsDeveloperInstructions: true)
    #expect(harness.outcome(harness.codex.path) == .cli(""))

    // Auto review: the reviewer decides; added only where the command sets
    // no approvals of its own.
    harness.codexFacts = CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false)
    harness.approvals[.codex] = .autoReview
    #expect(harness.outcome(harness.codex.path) == .cli(suffix(["--approve-for-me", "-c", instructions])))
    #expect(harness.outcome("\(harness.codex.path) -a never") == .cli(suffix(["-c", instructions])))
}

@Test @MainActor func controlToolLaunchCLIApprovalsGoFirstAndNeverOverACommandsOwnMode() throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    harness.approvals[.claudeCode] = .autoReview
    let outcome = harness.outcome(harness.claude.path)
    guard case .cli(let words) = outcome else {
        Issue.record("\(outcome)")
        return
    }
    #expect(words.hasPrefix(suffix(["--permission-mode", "auto", "--plugin-dir"])))
    for own in ["--dangerously-skip-permissions", "--permission-mode plan", "--allow-dangerously-skip-permissions"] {
        guard case .cli(let kept) = harness.outcome("\(harness.claude.path) \(own)") else {
            Issue.record("\(own)")
            continue
        }
        #expect(!kept.contains("'--permission-mode' 'auto'"), "\(own)")
    }
    // With Cherry MCP too, before `--mcp-config` (it takes every word after it).
    harness.skillReady = false
    guard case .appended(let mcp) = harness.outcome(harness.claude.path) else {
        Issue.record("no Cherry MCP")
        return
    }
    #expect(mcp.hasPrefix(suffix(["--permission-mode", "auto", "--mcp-config"])))

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
    let kickoff = AgentTaskRegistry.kickoffLine(taskID: "task-1", usesCLI: true)
    #expect(kickoff.contains("cherry task mine") && kickoff.contains("cherry task report"))
    #expect(!kickoff.contains("CHERRY_MCP_HELPER") && !kickoff.contains("get_my_task"))
    #expect(AgentTaskRegistry.kickoffLine(taskID: "task-1") == AgentTaskRegistry.kickoffLine(taskID: "task-1", usesCLI: false))

    let rules = AgentTaskRegistry.workerRules(allowSubagents: true, usesCLI: true).joined(separator: "\n")
    for mcp in ["report_result", "report_progress", "spawn_agent", "CHERRY_MCP_HELPER", "awaiting_approval true"] {
        #expect(!rules.contains(mcp), "\(mcp)")
    }
    #expect(rules.contains("cherry task progress --awaiting-approval") && rules.contains("cherry task report <<'EOF'"))
    #expect(AgentTaskRegistry.workerRules(allowSubagents: false) == AgentTaskRegistry.workerRules(allowSubagents: false, usesCLI: false))

    #expect(AgentTaskRegistry.nudgeLine(usesCLI: true) == "Please run cherry task report with your result.")
    #expect(AgentTaskRegistry.nudgeLine(usesCLI: false) == AgentTaskRegistry.nudgeLine)
    var counts = AgentRunCounts()
    counts.total = 2
    counts.reported = 1
    counts.failed = 1
    let wake = AgentTaskRegistry.wakeLine(runID: "run-1", counts: counts, usesCLI: true)
    #expect(wake.contains("cherry task wait run-1") && !wake.contains("wait_for_tasks"))
    var waiting = AgentRunCounts()
    waiting.total = 1
    waiting.awaitingApproval = 1
    let approval = AgentTaskRegistry.approvalWakeLine(runID: "run-1", counts: waiting, usesCLI: true)
    #expect(approval.contains("cherry task wait run-1") && approval.contains("cherry send"))
}

@Test @MainActor func controlToolLaunchCLIATabStartedWithTheCLIKnowsIt() async throws {
    let harness = try CLILaunchHarness()
    defer { harness.cleanUp() }
    var policy = SessionBackendPolicy.native
    policy.agentMCPLaunch = harness.context
    let workspace = TerminalWorkspace(
        projectRoot: harness.directory.path, createInitialSession: false, launchBackend: .hostManaged, backendPolicy: policy
    )
    defer { workspace.closeAllSessions() }
    let claude = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: harness.claude.path), projectRoot: harness.directory.path
    )
    #expect(claude.launchUsesCherryCLI)
    #expect(claude.lastAgentLaunchNotCLIReason == nil)
    #expect(claude.launchStartupCommand?.contains("CHERRY_PROCESS_ID \(claude.id.uuidString)") == true)
    #expect(claude.launchCommand == harness.claude.path)

    let codex = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: harness.codex.path), projectRoot: harness.directory.path
    )
    #expect(!codex.launchUsesCherryCLI)
    #expect(codex.lastAgentLaunchNotCLIReason == "Codex's settings are not read yet")
}

@Test @MainActor func controlToolLaunchCLISettingsInterfaceLineSaysWhichAndWhy() {
    func interface(_ cli: AgentMCPLaunch.CLI, _ command: String = "x", connects: Bool = true, skill: Bool = true,
                   approvals: AgentApprovals = .configured, facts: CodexLaunchFacts? = nil) -> AgentSettingsPage.Interface {
        AgentSettingsPage.interface(
            cli: cli, commandLine: command, connectsAtLaunch: connects, skillReady: skill, approvals: approvals, codexFacts: facts
        )
    }
    #expect(interface(.claudeCode).usesCLI)
    #expect(interface(.claudeCode).status == "The cherry command")
    #expect(!interface(.claudeCode, skill: false).usesCLI)
    #expect(interface(.claudeCode, connects: false).status == "Not connected at launch")
    #expect(!interface(.codex).usesCLI)
    #expect(interface(.codex).help.contains("aren't read yet"))
    #expect(interface(.codex, "codex --dangerously-bypass-approvals-and-sandbox").usesCLI)
    #expect(interface(.codex, approvals: .autoReview).usesCLI)
    #expect(interface(.codex, facts: CodexLaunchFacts(rulesInstalled: true, setsDeveloperInstructions: false)).usesCLI)
    let blocked = interface(.codex, facts: CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: false))
    #expect(!blocked.usesCLI && blocked.help.contains("can't reach Cherry's socket"))
    #expect(AgentSettingsPage.launchCLI(of: AgentToolDefinition(name: "Codex", command: "codex")) == .codex)
    #expect(AgentSettingsPage.launchCLI(of: AgentToolDefinition(name: "Amp", command: "amp")) == nil)
}
