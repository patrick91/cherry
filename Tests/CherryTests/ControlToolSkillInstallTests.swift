@testable import Cherry
import CherryControl
@testable import CherryMCP
import Foundation
import Testing

// The `cherry` skill on disk (`CherrySkillInstaller`, `cherry skill
// setup|status|remove`; docs/specs/agent-cli.md, Teaching agents): every
// status, setup and remove, links and other people's files left alone, the
// Codex rules file. Everything runs in a temporary home with an injected
// environment and PATH: never the real ~/.claude, ~/.agents or ~/.codex.

private final class SkillHome {
    let root: URL
    var variables: [String: String] = [:]
    var onPath: Set<String> = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-skill-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var home: URL { root.appendingPathComponent("home") }

    func folder(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func installer(project: URL? = nil, markdown: String = CherrySkill.markdown, rules: String = CherrySkill.rulesText) -> CherrySkillInstaller {
        let found = onPath
        return CherrySkillInstaller(
            environment: CherrySkillEnvironment(home: home, variables: variables, projectRoot: project) { found.contains($0) },
            skillMarkdown: markdown,
            rulesText: rules
        )
    }

    func text(_ path: String) -> String? {
        FileManager.default.contents(atPath: home.appendingPathComponent(path).path).map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private func status(_ items: [CherrySkillItem], _ target: CherrySkillTarget) -> CherrySkillStatus? {
    items.first { $0.target == target }?.status
}

private func change(_ changes: [CherrySkillChange], _ target: CherrySkillTarget) -> CherrySkillChangeKind? {
    changes.first { $0.target == target }?.change
}

private extension CherrySkillChange {
    var target: CherrySkillTarget { item.target }
}

// MARK: - Status and setup

/// Nothing found: every target is unsupported and setup writes nothing.
@Test func ControlToolSkillNoAgentsFoundWritesNothing() throws {
    let home = try SkillHome()
    let installer = home.installer()
    #expect(installer.items().allSatisfy { $0.status == .unsupported })
    let changes = installer.setup()
    #expect(changes.allSatisfy { $0.change == .skipped })
    #expect(!FileManager.default.fileExists(atPath: home.home.appendingPathComponent(".claude").path))
    #expect(!FileManager.default.fileExists(atPath: home.home.appendingPathComponent(".agents").path))
}

/// An agent found by its folder or on PATH gets its skill, with the
/// marker; setup again changes nothing.
@Test func ControlToolSkillSetupWritesTheSkillAndItsMarkerOnce() throws {
    let home = try SkillHome()
    try home.folder(".claude")
    home.onPath = ["pi"]
    let installer = home.installer()
    #expect(status(installer.items(), .claudeSkill) == .missing)
    #expect(status(installer.items(), .agentsSkill) == .missing)
    #expect(status(installer.items(), .codexRules) == .unsupported)

    let dry = installer.setup(dryRun: true)
    #expect(change(dry, .claudeSkill) == .wouldWrite)
    #expect(home.text(".claude/skills/cherry/SKILL.md") == nil)

    let changes = installer.setup()
    #expect(change(changes, .claudeSkill) == .wrote)
    #expect(change(changes, .agentsSkill) == .wrote)
    #expect(change(changes, .codexRules) == .skipped)
    let skill = try #require(home.text(".claude/skills/cherry/SKILL.md"))
    #expect(skill == CherrySkill.markdown + "\n")
    #expect(home.text(".agents/skills/cherry/SKILL.md") == skill)
    let marker = try #require(home.text(".claude/skills/cherry/.cherry-skill"))
    #expect(marker.contains("\"by\":\"Cherry\"") && marker.contains(sha256Hex(skill)))
    #expect(home.items(installer).filter { $0.status == .current }.map(\.target) == [.claudeSkill, .agentsSkill])
    #expect(installer.items().first { $0.target == .agentsSkill }?.agents == [.pi])

    #expect(installer.setup().filter { $0.change != .skipped }.allSatisfy { $0.change == .unchanged })
}

/// Another build's skill is outdated and setup replaces it.
@Test func ControlToolSkillAnOlderSkillIsReplaced() throws {
    let home = try SkillHome()
    try home.folder(".claude")
    _ = home.installer(markdown: "---\nname: cherry\n---\nolder\n").setup()
    let installer = home.installer()
    #expect(status(installer.items(), .claudeSkill) == .outdated)
    #expect(change(installer.setup(), .claudeSkill) == .replaced)
    #expect(status(installer.items(), .claudeSkill) == .current)
}

/// A `cherry` skill Cherry didn't write, or one edited since, is the
/// user's: setup leaves it unless --force, remove always.
@Test func ControlToolSkillSomeoneElsesSkillIsLeftAlone() throws {
    let home = try SkillHome()
    try home.folder(".claude")
    try home.write(".claude/skills/cherry/SKILL.md", "---\nname: cherry\n---\nmine\n")
    let installer = home.installer()
    #expect(status(installer.items(), .claudeSkill) == .foreign)
    #expect(change(installer.setup(), .claudeSkill) == .skipped)
    #expect(home.text(".claude/skills/cherry/SKILL.md") == "---\nname: cherry\n---\nmine\n")
    #expect(change(installer.remove(), .claudeSkill) == .skipped)
    #expect(home.text(".claude/skills/cherry/SKILL.md") != nil)

    #expect(change(installer.setup(force: true), .claudeSkill) == .replaced)
    #expect(status(installer.items(), .claudeSkill) == .current)

    // Edited by hand after Cherry wrote it: the user's now.
    try home.write(".claude/skills/cherry/SKILL.md", CherrySkill.markdown + "\nmy note\n")
    let edited = installer.items().first { $0.target == .claudeSkill }
    #expect(edited?.status == .foreign)
    #expect(edited?.detail == "changed since Cherry wrote it")
}

/// A link at the skill's folder or its file is never followed: unreadable,
/// and setup fails without writing through it.
@Test func ControlToolSkillLinksAreRefused() throws {
    let home = try SkillHome()
    try home.folder(".claude/skills")
    let elsewhere = home.root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: home.home.appendingPathComponent(".claude/skills/cherry"),
        withDestinationURL: elsewhere
    )
    let installer = home.installer()
    #expect(status(installer.items(), .claudeSkill) == .unreadable)
    #expect(change(installer.setup(force: true), .claudeSkill) == .failed)
    #expect((try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)).isEmpty)

    try home.folder(".codex/rules")
    try FileManager.default.createSymbolicLink(
        at: home.home.appendingPathComponent(".codex/rules/cherry.rules"),
        withDestinationURL: elsewhere.appendingPathComponent("rules")
    )
    #expect(status(installer.items(), .codexRules) == .unreadable)
    #expect(change(installer.setup(force: true), .codexRules) == .failed)
    #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("rules").path))
}

/// Overrides: CLAUDE_CONFIG_DIR and CODEX_HOME move the files; a relative
/// one is unreadable.
@Test func ControlToolSkillFollowsTheAgentsFolderVariables() throws {
    let home = try SkillHome()
    let claude = home.root.appendingPathComponent("claude-config")
    let codex = home.root.appendingPathComponent("codex-home")
    home.variables = ["CLAUDE_CONFIG_DIR": claude.path, "CODEX_HOME": codex.path]
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let changes = home.installer().setup()
    #expect(change(changes, .claudeSkill) == .wrote)
    #expect(change(changes, .codexRules) == .wrote)
    #expect(FileManager.default.fileExists(atPath: claude.appendingPathComponent("skills/cherry/SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: codex.appendingPathComponent("rules/cherry.rules").path))

    home.variables = ["CLAUDE_CONFIG_DIR": "relative/claude"]
    home.onPath = ["claude"]
    let item = home.installer().items(for: [.claude]).first { $0.target == .claudeSkill }
    #expect(item?.status == .unreadable)
    #expect(item?.detail == "CLAUDE_CONFIG_DIR is not an absolute path")
}

/// --project writes into the repository's .claude, .agents and .codex.
@Test func ControlToolSkillProjectWritesIntoTheRepository() throws {
    let home = try SkillHome()
    let repository = home.root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let nested = repository.appendingPathComponent("Sources/App")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect(CherrySkillEnvironment.projectRoot(from: nested).path == repository.standardizedFileURL.path)

    let changes = home.installer(project: repository).setup(agents: [.claude, .codex])
    #expect(changes.allSatisfy { $0.change == .wrote })
    for path in [".claude/skills/cherry/SKILL.md", ".agents/skills/cherry/SKILL.md", ".codex/rules/cherry.rules"] {
        #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path), "\(path)")
    }
    #expect(!FileManager.default.fileExists(atPath: home.home.appendingPathComponent(".claude").path))
}

// MARK: - The Codex rules file

@Test func ControlToolSkillCodexRulesAreCherrysOwn() throws {
    let rules = CherrySkill.rulesText
    #expect(rules.hasPrefix(CherrySkill.rulesFirstLine + "\n"))
    #expect(CherrySkill.rulesFirstLine == "# Written by Cherry: cherry's agent commands run outside Codex's sandbox; cherry host is forbidden.")
    #expect(rules.contains("decision = \"allow\"") && rules.contains("decision = \"forbidden\""))
    // Every agent command's first word, but the host's start/restart and
    // skill (its setup writes agent settings).
    let words = Set(CherryCLI.commandWords).subtracting(["start", "restart", "skill"])
    #expect(Set(CherrySkill.allowedWords) == words)
    #expect(Set(CherrySkill.forbiddenWords).isDisjoint(with: CherrySkill.allowedWords))
    #expect(CherrySkill.forbiddenWords.first == "host")

    let home = try SkillHome()
    home.onPath = ["codex"]
    try home.write(".codex/rules/cherry.rules", "prefix_rule(pattern = [\"cherry\"], decision = \"allow\")\n")
    let installer = home.installer()
    #expect(status(installer.items(), .codexRules) == .foreign)
    #expect(change(installer.setup(), .codexRules) == .skipped)
    #expect(change(installer.setup(force: true), .codexRules) == .replaced)
    #expect(home.text(".codex/rules/cherry.rules") == rules)
    _ = home.installer(rules: CherrySkill.rulesFirstLine + "\nolder\n").setup(force: true)
    #expect(status(installer.items(), .codexRules) == .outdated)
}

// MARK: - Remove

/// Remove takes Cherry's files only, leaves other skills and files beside
/// its own, and keeps the shared skill while an agent not named reads it.
@Test func ControlToolSkillRemoveTakesOnlyCherrysFiles() throws {
    let home = try SkillHome()
    try home.folder(".claude")
    home.onPath = ["codex", "pi"]
    let installer = home.installer()
    _ = installer.setup()
    try home.write(".claude/skills/other/SKILL.md", "---\nname: other\n---\n")
    try home.write(".agents/skills/cherry/notes.txt", "mine")

    let codexOnly = installer.remove(agents: [.codex])
    #expect(change(codexOnly, .agentsSkill) == .skipped)
    #expect(codexOnly.first { $0.target == .agentsSkill }?.detail == "still read by Pi")
    #expect(change(codexOnly, .codexRules) == .removed)
    #expect(home.text(".codex/rules/cherry.rules") == nil)

    #expect(installer.remove(dryRun: true).allSatisfy { $0.change == .wouldRemove || $0.change == .unchanged })
    let all = installer.remove()
    #expect(change(all, .claudeSkill) == .removed)
    #expect(change(all, .agentsSkill) == .removed)
    #expect(change(all, .codexRules) == .unchanged)
    #expect(!FileManager.default.fileExists(atPath: home.home.appendingPathComponent(".claude/skills/cherry").path))
    #expect(home.text(".claude/skills/other/SKILL.md") != nil)
    // Its folder stays for the file that isn't Cherry's.
    #expect(home.text(".agents/skills/cherry/notes.txt") == "mine")
    #expect(home.text(".agents/skills/cherry/SKILL.md") == nil)
}

// MARK: - The command

@Test func ControlToolSkillCommandParsesAndPrints() async throws {
    guard case .skill(let request) = CherryCLI.parse(["skill", "setup", "--agent", "codex", "--agent", "pi", "--dry-run", "--project"]).action else {
        Issue.record("skill setup parses")
        return
    }
    #expect(request == CherrySkillRequest(operation: .setup, agents: [.codex, .pi], dryRun: true, project: true))
    guard case .skill(let status) = CherryCLI.parse(["skill", "status"]).action else {
        Issue.record("skill status parses")
        return
    }
    #expect(status.agents == nil)

    let home = try SkillHome()
    try home.folder(".claude")
    let installer = home.installer()
    func run(_ words: [String], terminal: Bool) async -> CherryCLIRunner.Outcome {
        await CherryCLIRunner.run(CherryCLI.parse(words), isTerminal: terminal, skillInstaller: { _ in installer }) { _, _ in
            CallToolResult(text: "{}", isError: false, structured: nil)
        }
    }
    let table = await run(["skill", "status"], terminal: true)
    #expect(table.exitCode == 0)
    #expect(table.standardOutput.hasPrefix("WHAT"))
    #expect(table.standardOutput.contains("Claude Code") && table.standardOutput.contains("missing"))

    let setup = await run(["skill", "setup", "--json"], terminal: true)
    #expect(setup.exitCode == 0)
    let payload = try JSONValue.parse(Data(setup.standardOutput.utf8))
    #expect(payload.objectValue?["dry_run"] == .bool(false))
    let changes = payload.objectValue?["changes"]?.arrayValue ?? []
    #expect(changes.contains { $0.objectValue?["change"]?.stringValue == "wrote" })

    let json = await run(["skill", "status"], terminal: false)
    let items = try JSONValue.parse(Data(json.standardOutput.utf8)).objectValue?["items"]?.arrayValue ?? []
    #expect(items.contains { $0.objectValue?["target"]?.stringValue == "claude_skill" && $0.objectValue?["status"]?.stringValue == "current" })
}

// MARK: - Connect

/// Connect's model reads nothing without an installer (tests'; `shared`
/// has the account's), and with one shows the files before writing them;
/// only `perform` (the confirmation's Install) writes.
@MainActor
@Test func ControlToolSkillConnectShowsTheFilesThenWritesThem() async throws {
    let inert = CherrySkillsModel()
    await inert.refresh()
    #expect(inert.items.isEmpty)
    #expect(inert.plan(for: CherrySkillTarget.allCases) == nil)

    let home = try SkillHome()
    try home.folder(".claude")
    home.onPath = ["codex"]
    let installer = home.installer()
    let model = CherrySkillsModel { installer }
    await model.refresh()
    #expect(model.items(for: .claude).map(\.target) == [.claudeSkill])
    #expect(model.items(for: .codex).map(\.target) == [.agentsSkill, .codexRules])
    #expect(model.items(for: .pi).first?.status == .missing)
    #expect(CherrySkillConnection.action(for: model.items(for: .claude)[0]) == "Install")

    model.confirm([.claudeSkill, .codexRules])
    let plan = try #require(model.request)
    #expect(plan.targets == [.claudeSkill, .codexRules])
    #expect(plan.files.map(\.path) == [
        home.home.appendingPathComponent(".claude/skills/cherry/SKILL.md").path,
        home.home.appendingPathComponent(".claude/skills/cherry/.cherry-skill").path,
        home.home.appendingPathComponent(".codex/rules/cherry.rules").path,
    ])
    #expect(plan.files.last?.contents == CherrySkill.rulesText)
    // Confirming wrote nothing yet.
    #expect(home.text(".claude/skills/cherry/SKILL.md") == nil)

    model.request = nil
    await model.perform(plan)
    #expect(!model.lastRunFailed)
    #expect(model.items(for: .claude).first?.status == .current)
    #expect(model.items(for: .codex).first { $0.target == .codexRules }?.status == .current)
    // Only the plan's targets: the shared skill is still to install.
    #expect(model.items(for: .codex).first { $0.target == .agentsSkill }?.status == .missing)
    #expect(model.plan(for: [.claudeSkill]) == nil)

    #expect(CherrySkillConnection.agent(for: .openCode) == .opencode)
    #expect(CherrySkillConnection.agent(for: .gemini) == nil)
}

private extension SkillHome {
    func items(_ installer: CherrySkillInstaller) -> [CherrySkillItem] {
        installer.items().filter { $0.status != .unsupported }
    }
}
