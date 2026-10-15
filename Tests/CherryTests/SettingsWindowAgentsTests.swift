import Foundation
import Testing
@testable import Cherry

// Settings › Agents & MCP (AgentsSettingsPage.swift) and the agent editor
// (AgentToolEditor.swift): the list's rows and tags, the presets and their
// Add (a free name, never replacing an agent), Wake idle agents' source,
// the MCP server's rows and the commands for other agent CLIs, and the
// page's search rows. Private defaults and hand-built navigators only.

private func preset(_ name: String) throws -> AgentToolDefinition {
    try #require(AgentConfiguration.presets.first { $0.name == name })
}

@Test @MainActor func settingsWindowAgentsListShowsEachAgentWithItsLettersAndTags() throws {
    var gemini = try preset("Gemini")
    gemini.enabled = false
    let agents = [
        try preset("Claude"),
        try preset("Codex"),
        try preset("Pi"),
        gemini,
        AgentToolDefinition(name: "Mine", command: "my-agent", arguments: "--fast"),
    ]

    let rows = AgentsSettingsPage.listRows(agents)

    #expect(rows.map(\.name) == ["Claude", "Codex", "Pi", "Gemini", "Mine"])
    #expect(rows.map(\.letters) == ["Cl", "Cx", "Pi", "Ge", "Mi"])
    #expect(rows.map(\.commandLine) == [
        "claude --dangerously-skip-permissions", "codex --yolo", "pi", "gemini", "my-agent --fast",
    ])
    #expect(rows.map(\.isOff) == [false, false, false, true, false])
    #expect(rows.map(\.tags) == [
        [AgentsSettingsPage.Tag(text: "Skips permission prompts", style: .plain)],
        [AgentsSettingsPage.Tag(text: "Skips permission prompts", style: .plain)],
        [],
        [AgentsSettingsPage.Tag(text: "Off", style: .plain)],
        [],
    ])
    // Each row opens its agent's page and is tinted by its own id.
    #expect(rows[0].route == .agent("claude"))
    #expect(rows[0].id == "agents.agent.claude")
    #expect(Set(rows.map(\.id)).count == rows.count)

    // "No command" (orange) only for an agent that is on and has none;
    // "Off" says enough for one that is off.
    let empty = AgentToolDefinition(name: "Empty", command: "  ")
    #expect(AgentsSettingsPage.tags(for: empty) == [AgentsSettingsPage.Tag(text: "No command", style: .warning)])
    #expect(AgentsSettingsPage.listRows([empty]).first?.commandLine == nil)
    var emptyAndOff = empty
    emptyAndOff.enabled = false
    #expect(AgentsSettingsPage.tags(for: emptyAndOff) == [AgentsSettingsPage.Tag(text: "Off", style: .plain)])
    var skippingAndOff = try preset("Codex")
    skippingAndOff.enabled = false
    #expect(AgentsSettingsPage.tags(for: skippingAndOff).map(\.text) == ["Skips permission prompts", "Off"])

    #expect(AgentsSettingsPage.countText(0) == "No agents")
    #expect(AgentsSettingsPage.countText(1) == "1 agent")
    #expect(AgentsSettingsPage.countText(4) == "4 agents")
}

@Test @MainActor func settingsWindowAgentsPresetsShowTheirCommandLinesThenCustom() {
    let rows = AgentsSettingsPage.presetRows

    #expect(rows.map(\.title) == ["Claude", "Codex", "Pi", "Gemini", "OpenCode", "Amp", "Custom…"])
    #expect(rows.map(\.subtitle) == [
        "claude --dangerously-skip-permissions", "codex --yolo", "pi", "gemini", "opencode", "amp",
        "Any command line you choose.",
    ])
    #expect(rows.map(\.isCustom) == [false, false, false, false, false, false, true])
    #expect(rows.map { $0.tags.map(\.text) } == [
        ["Skips permission prompts"], ["Skips permission prompts"], [], [], [], [], [],
    ])
    #expect(rows.map(\.addLabel) == [
        "Add Claude", "Add Codex", "Add Pi", "Add Gemini", "Add OpenCode", "Add Amp", "Add a custom agent",
    ])
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test @MainActor func settingsWindowAgentsPresetAddedTwiceIsClaude2AndItsRowIsTinted() throws {
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowAgents"))
    let navigator = SettingsNavigator(initial: .page(.agents))
    let claude = try preset("Claude")

    let first = try AgentsSettingsPage.add(claude, to: settings, navigator: navigator)
    #expect(first.name == "Claude")
    #expect(navigator.highlight.row == "agents.agent.claude")
    var edited = first
    edited.arguments = "--model opus"
    try settings.updateAgent(named: "Claude", with: edited)

    let second = try AgentsSettingsPage.add(claude, to: settings, navigator: navigator)
    #expect(second.name == "Claude 2")
    #expect(second.arguments == "--dangerously-skip-permissions")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2"])
    // The user's Claude is left as it was.
    #expect(settings.agents[0].arguments == "--model opus")
    #expect(navigator.highlight.row == AgentsSettingsPage.rowID("claude 2"))
    // The page stays where it is: Add only tints the new row.
    #expect(navigator.route == .page(.agents))
    #expect(!navigator.canGoBack)

    // Custom… and an empty editor are refused by validation: nothing is
    // added and nothing is tinted.
    let generation = navigator.highlight.generation
    #expect(throws: AgentConfigurationError.missingCommand(name: "Custom")) {
        try AgentsSettingsPage.add(try preset("Custom"), to: settings, navigator: navigator)
    }
    #expect(throws: AgentConfigurationError.missingName) {
        try AgentsSettingsPage.add(AgentToolDefinition(name: "", command: ""), to: settings, navigator: navigator)
    }
    #expect(settings.agents.count == 2)
    #expect(navigator.highlight.generation == generation)
}

@Test @MainActor func settingsWindowAgentsWakeLinesAreSetHereOnlyWhileOff() throws {
    let key = AgentMonitorRegistry.wakeLinesDefaultsKey
    let defaults = privateDefaults("SettingsWindowAgents")
    let registry = AgentMonitorRegistry(defaults: defaults)
    #expect(AgentMonitorRegistry.wakeLinesDefault)

    // Nothing stored: on, Cherry's default.
    var state = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [:])
    #expect(state.source == .cherryDefault)
    #expect(AgentsSettingsPage.wakeLinesEnabled(defaults: defaults, launchArguments: [:]))
    #expect(registry.wakeLinesEnabled)

    // Off is Set here, and ↺ removes the stored value.
    defaults.set(false, forKey: key)
    state = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [:])
    #expect(state.source == .setHere)
    #expect(state.source.isEditable)
    #expect(!AgentsSettingsPage.wakeLinesEnabled(defaults: defaults, launchArguments: [:]))
    #expect(!registry.wakeLinesEnabled)
    let reset = try #require(state.rowReset)
    #expect(reset.title == "Reset to default (On)")
    reset.perform()
    #expect(defaults.object(forKey: key) == nil)
    #expect(registry.wakeLinesEnabled)

    // The switch is shown the default first; the key still goes, even when
    // showing it writes the default (the switch's own storage does).
    defaults.set(false, forKey: key)
    var shown: [Any?] = []
    state = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [:]) {
        shown.append(defaults.object(forKey: key))
        defaults.set(AgentMonitorRegistry.wakeLinesDefault, forKey: key)
    }
    try #require(state.rowReset).perform()
    #expect(shown.count == 1)
    #expect(shown.first.flatMap { $0 as? Bool } == false)
    #expect(defaults.object(forKey: key) == nil)
    #expect(registry.wakeLinesEnabled)

    // On, stored, is the default: no badge.
    defaults.set(true, forKey: key)
    #expect(AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [:]).source == .cherryDefault)

    // A launch argument makes it This run only, and read-only.
    state = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [key: false])
    #expect(state.source == .launchArgument(applied: true))
    #expect(!state.source.isEditable)
    #expect(!AgentsSettingsPage.wakeLinesEnabled(defaults: defaults, launchArguments: [key: false]))
    // "-mcp.monitorWakeLines NO" is a string, which the registry does not
    // read as a value: the default is in use.
    state = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: [key: "NO"])
    #expect(state.source == .launchArgument(applied: false))
    #expect(AgentsSettingsPage.wakeLinesEnabled(defaults: defaults, launchArguments: [key: "NO"]))
}

@Test @MainActor func settingsWindowAgentEditorSaysAddOrEditAndAsksBeforeDeleting() {
    #expect(AgentToolEditor.title(canDelete: false) == "Add Agent")
    #expect(AgentToolEditor.title(canDelete: true) == "Edit Agent")
    #expect(AgentToolEditor.nameLabel == "Name")
    #expect(AgentToolEditor.commandLabel == "Command")
    #expect(AgentToolEditor.commandPlaceholder == "claude")
    #expect(AgentToolEditor.argumentsLabel == "Default arguments")
    #expect(AgentToolEditor.argumentsPlaceholder == "--model opus")
    #expect(AgentToolEditor.enabledLabel == "Enabled")
    #expect(AgentToolEditor.enabledHelp == "Off hides it from the Agents menu, the sidebar's + menu and the Omni bar.")

    var deletes = 0
    let confirmation = AgentToolEditor.deleteConfirmation(agentName: "Claude") { deletes += 1 }
    #expect(confirmation == SettingsConfirmation(
        title: "Delete the agent “Claude”?",
        message: "Its command and default arguments are deleted. Tabs it started keep running.",
        choices: [SettingsConfirmation.Choice("Delete", role: .destructive), .cancel()]
    ))
    // Cancel does nothing; Delete deletes once.
    confirmation.choices[1].perform()
    #expect(deletes == 0)
    confirmation.choices[0].perform()
    #expect(deletes == 1)
}

@Test @MainActor func settingsWindowAgentsMCPServerListsEachCLIsCommandInThePresetsOrder() {
    let listening = AgentsSettingsPage.socketStatus(exists: true)
    #expect(listening.text == "Listening")
    #expect(listening.style == .ok)
    #expect(listening.dot == .green)
    let notListening = AgentsSettingsPage.socketStatus(exists: false)
    #expect(notListening.text == "Not listening")
    #expect(notListening.style == .warning)
    #expect(notListening.dot == .orange)

    let builder = MCPInstallCommandBuilder.commands()
    let commands = AgentsSettingsPage.otherCLICommands(builder)
    #expect(commands.map(\.harness) == [.claude, .codex, .pi])
    #expect(commands.map { $0.harness.productName } == ["Claude Code", "Codex", "Pi"])
    // The commands are the builder's, whose own order stays.
    #expect(Set(commands.map(\.command)) == Set(builder.map(\.command)))
    #expect(builder.map(\.harness) == [.codex, .claude, .pi])
}

@Test @MainActor func settingsWindowAgentsSearchFindsTheCLICommandsMonitorsAndSocket() throws {
    let defaults = privateDefaults("SettingsWindowAgents")
    defaults.set(false, forKey: AgentMonitorRegistry.wakeLinesDefaultsKey)
    let agents = AgentSettings(defaults: defaults)
    let context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: agents,
        defaults: defaults
    )

    func results(_ query: String) -> [SettingsSearchResult] {
        SettingsSearchIndex.groups(for: query, in: SettingsSearchIndex.rows(in: context))
            .first { $0.kind == .page(.agents) }?.results ?? []
    }

    // With no agent in Cherry, the commands are still found.
    for query in ["claude mcp add", "codex mcp add", "pi mcp add", "install", "register"] {
        #expect(results(query).map(\.row.id).contains(.agentsOtherCLIs), "\(query)")
    }
    let wake = try #require(results("wake").first { $0.row.id == .agentsWakeLines })
    #expect(wake.row.value == "Off")
    #expect(wake.row.detail == "Monitors · Off")
    #expect(results("socket").map(\.row.id).contains(.agentsControlSocket))
    #expect(results("instance socket").map(\.row.id).contains(.agentsControlSocket))
    #expect(results("yolo").map(\.row.id) == [.agentsPresets])
    #expect(results("other macs").map(\.row.id).contains(.agentsOtherMacs))
    #expect(results("stdio").map(\.row.id).contains(.agentsMCPServer))

    func listValue() -> String? {
        AgentsSettingsPage.searchRows(in: context).first { $0.id == .agentsList }?.value
    }
    #expect(listValue() == "No agents")
    try agents.addAgent(try preset("Claude"))
    try agents.addAgent(try preset("Pi"))
    #expect(listValue() == "2 agents")
    // Every row is on this page and its ids are its own.
    let rows = AgentsSettingsPage.searchRows(in: context)
    #expect(rows.allSatisfy { $0.route == .page(.agents) })
    #expect(Set(rows.map(\.id)).count == rows.count)
}
