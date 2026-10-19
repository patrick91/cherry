import Foundation
import Testing
@testable import Cherry

// Settings › Agents & MCP (AgentsSettingsPage.swift) and the agent editor
// (AgentToolEditor.swift): the list's rows and tags, the presets and their
// Add (a free name, never replacing an agent), Wake idle agents' and
// Connect agents Cherry starts' sources, the MCP server's rows and the
// commands for other agent CLIs, and the page's search rows. Private
// defaults, injected socket paths and hand-built navigators only.

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

/// Connect agents Cherry starts: on by default, as the launches read it
/// (`AgentMCPLaunch.isEnabled`); Set here while off, ↺ removes the stored
/// value; a launch argument makes it read-only.
@Test @MainActor func settingsWindowAgentsConnectAgentsCherryStartsIsSetHereOnlyWhileOff() throws {
    let key = AgentMCPLaunch.enabledDefaultsKey
    #expect(key == "mcp.connectAgentsAtLaunch")
    let defaults = privateDefaults("SettingsWindowAgentsConnect")
    #expect(AgentsSettingsPage.connectAtLaunchTitle == "Connect agents Cherry starts")
    #expect(AgentsSettingsPage.connectAtLaunchHelp
        == "Claude Code 2.0.0 or later, Codex 0.162.0 or later and Pi 0.99.2 or later that Cherry starts, here and on your other Macs, get Cherry MCP on their command line, or on this Mac the cherry command and its skill (each agent's page says which). Off: they use what you registered.")
    #expect(AgentsSettingsPage.otherCLIsIntro
        == "Agents use Cherry's MCP server to see and drive your tabs. Agents you start yourself, and ones Cherry doesn't connect when it starts them, need it registered once with their CLI.")

    // Nothing stored: on, Cherry's default.
    var state = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [:])
    #expect(state.source == .cherryDefault)
    #expect(AgentsSettingsPage.connectsAgentsAtLaunch(defaults: defaults, launchArguments: [:]))
    #expect(AgentMCPLaunch.isEnabled(defaults))

    // Off is Set here, and what launches read; ↺ removes the stored value.
    defaults.set(false, forKey: key)
    state = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [:])
    #expect(state.source == .setHere)
    #expect(state.source.isEditable)
    #expect(!AgentsSettingsPage.connectsAgentsAtLaunch(defaults: defaults, launchArguments: [:]))
    #expect(!AgentMCPLaunch.isEnabled(defaults))
    var shown = 0
    state = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [:]) { shown += 1 }
    let reset = try #require(state.rowReset)
    #expect(reset.title == "Reset to default (On)")
    reset.perform()
    #expect(shown == 1)
    #expect(defaults.object(forKey: key) == nil)
    #expect(AgentMCPLaunch.isEnabled(defaults))

    // On, stored, is the default: no badge.
    defaults.set(true, forKey: key)
    #expect(AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [:]).source == .cherryDefault)

    // A launch argument makes it This run only, and read-only; one that is
    // no Bool leaves the default in use.
    state = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [key: false])
    #expect(state.source == .launchArgument(applied: true))
    #expect(!state.source.isEditable)
    #expect(!AgentsSettingsPage.connectsAgentsAtLaunch(defaults: defaults, launchArguments: [key: false]))
    state = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: [key: "NO"])
    #expect(state.source == .launchArgument(applied: false))
    #expect(AgentsSettingsPage.connectsAgentsAtLaunch(defaults: defaults, launchArguments: [key: "NO"]))
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

    // The socket the app's server binds (`appSocketPath`), never the one
    // `CherryControl.socketURL` derives, which in a Cherry started from a
    // Cherry tab is that tab's app's: none in tests.
    #expect(CherryControlServer.appSocketPath == nil)
    #expect(AgentsSettingsPage.controlSocket() == AgentsSettingsPage.ControlSocket(path: nil, isListening: false))
    let socket = "/tmp/cherry-test/Cherry-0123/control.sock"
    var looked: [String] = []
    #expect(AgentsSettingsPage.controlSocket(path: socket, fileExists: { looked.append($0); return true })
        == AgentsSettingsPage.ControlSocket(path: socket, isListening: true))
    #expect(looked == [socket])
    #expect(AgentsSettingsPage.controlSocket(path: socket, fileExists: { _ in false })
        == AgentsSettingsPage.ControlSocket(path: socket, isListening: false))
    // The server did not listen there: no path, whatever is on disk.
    #expect(AgentsSettingsPage.controlSocket(path: nil, fileExists: { _ in true })
        == AgentsSettingsPage.ControlSocket(path: nil, isListening: false))

    let builder = MCPInstallCommandBuilder.commands()
    let commands = AgentsSettingsPage.otherCLICommands(builder)
    #expect(commands.map(\.harness) == [.claude, .codex, .pi])
    #expect(commands.map { $0.harness.productName } == ["Claude Code", "Codex", "Pi"])
    // The commands are the builder's, whose own order stays; Pi's with its
    // description, quoted.
    #expect(Set(commands.map(\.command)) == Set(builder.map(\.command)))
    #expect(commands.last?.command.hasPrefix("pi mcp add cherry --exposure deferred --description 'Cherry, the terminal app this Pi runs in:") == true)
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
    // Connect Agents to Cherry…: its own row in MCP server, whose button
    // opens the sheet (nothing runs until its confirmation).
    #expect(SettingsRowID.agentsConnectAgents.rawValue == "agents.connectAgents")
    #expect(AgentsSettingsPage.connectAgentsTitle == "Connect Agents to Cherry")
    #expect(AgentsSettingsPage.connectAgentsHelp
        == "Shows Claude Code, Codex and Pi on this Mac, whether each has Cherry MCP, and the command that connects it. Nothing runs until you confirm.")
    for query in ["connect agents to cherry", "mcp add", "register", "claude", "codex", "pi"] {
        #expect(results(query).map(\.row.id).contains(.agentsConnectAgents), "\(query)")
    }
    let connectAgents = try #require(results("connect agents to cherry").first { $0.row.id == .agentsConnectAgents })
    #expect(connectAgents.row.title == "Connect Agents to Cherry")
    #expect(connectAgents.row.detail == "MCP server")
    let wake = try #require(results("wake").first { $0.row.id == .agentsWakeLines })
    #expect(wake.row.value == "Off")
    #expect(wake.row.detail == "Monitors · Off")
    #expect(results("socket").map(\.row.id).contains(.agentsControlSocket))
    #expect(results("instance socket").map(\.row.id).contains(.agentsControlSocket))
    // Codex's preset line first; word starts in Connect agents Cherry
    // starts' help ("your", "line", "Off") match it too, below.
    #expect(results("yolo").map(\.row.id) == [.agentsPresets, .agentsConnectAtLaunch])
    #expect(results("other macs").map(\.row.id).contains(.agentsOtherMacs))
    #expect(results("stdio").map(\.row.id).contains(.agentsMCPServer))
    for query in ["mcp-config", "connect agents", "launch"] {
        #expect(results(query).map(\.row.id).contains(.agentsConnectAtLaunch), "\(query)")
    }
    let connect = try #require(results("mcp-config").first { $0.row.id == .agentsConnectAtLaunch })
    #expect(connect.row.title == "Connect agents Cherry starts")
    #expect(connect.row.detail == "MCP server · On")
    defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(AgentsSettingsPage.searchRows(in: context).first { $0.id == .agentsConnectAtLaunch }?.value == "Off")

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
