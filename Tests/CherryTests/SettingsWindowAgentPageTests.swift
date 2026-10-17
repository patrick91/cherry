import CherryControl
import Combine
import Foundation
import Testing
@testable import Cherry

// Settings › an agent's page (AgentSettingsPage.swift): Cherry MCP for each
// CLI, status reporting, the header and tags, saving the command fields
// and Enabled where the agent is, Rename… (the page follows it),
// Duplicate, Delete… (it asks, then the page falls back) and the page's
// search rows. Private defaults, hand-built navigators and registrations;
// no CLI runs.

private func preset(_ name: String) throws -> AgentToolDefinition {
    try #require(AgentConfiguration.presets.first { $0.name == name })
}

@MainActor
private func agentSettings(_ agents: [AgentToolDefinition]) throws -> AgentSettings {
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowAgentPage"))
    for agent in agents {
        try settings.addAgent(agent)
    }
    return settings
}

@Test @MainActor func settingsWindowAgentPageConnectsEachCLIToCherryItsOwnWay() throws {
    let identity = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry-dev"], warn: { _ in })
    let helper = MCPInstallCommandBuilder.helperCommand
    typealias Connection = AgentSettingsPage.MCPConnection

    // Claude Code and Codex agents Cherry starts get Cherry MCP on their
    // command line: Connect is for the sessions started elsewhere. The
    // row's state and buttons are its CLI's model's (`AgentConnection.row`).
    #expect(AgentSettingsPage.mcpConnection(for: try preset("Claude"), identity: identity) == Connection(
        harness: .claude,
        title: "Connect Claude Code to Cherry",
        help: "Cherry starts Claude Code with Cherry MCP (2.0.0 or later). Connect also adds it to Claude Code's settings, for claude you start yourself.",
        command: "claude mcp add --transport stdio --scope user cherry-dev -- \(helper)",
        searchKeywords: ["mcp", "install", "register", "claude mcp add"]
    ))
    #expect(AgentSettingsPage.mcpConnection(for: try preset("Codex"), identity: identity) == Connection(
        harness: .codex,
        title: "Connect Codex to Cherry",
        help: "Cherry starts Codex with Cherry MCP (0.162.0 or later). Connect also adds it to Codex's settings, for codex you start yourself.",
        command: "codex mcp add cherry-dev -- \(helper)",
        searchKeywords: ["mcp", "install", "register", "codex mcp add"]
    ))
    // Pi agents Cherry starts get Cherry MCP through Cherry's extension;
    // Connect is for pi started elsewhere, and an entry of the name in Pi's
    // settings wins. Its buttons follow its state (`piRow`).
    let piHelp = "Pi agents use what Connect adds to Pi's settings (deferred: Pi loads Cherry's tools when it needs them). Needs Pi 0.99.2 or later."
    let pi = AgentSettingsPage.mcpConnection(for: try preset("Pi"), identity: identity)
    #expect(pi.harness == .pi)
    #expect(pi.title == "Connect Pi to Cherry")
    #expect(pi.help == "Cherry starts Pi with Cherry MCP (0.99.2 or later). Connect also adds it to Pi's settings, for pi you start yourself. A cherry-dev entry in Pi's settings takes precedence over it.")
    #expect(pi.command == "pi mcp add cherry-dev --exposure deferred --description '\(PiMCPRegistration.serverDescription)' -- \(helper)")
    #expect(AgentSettingsPage.mcpHelp(for: .pi, connectsAtLaunch: true, serverName: "cherry")
        == "Cherry starts Pi with Cherry MCP (0.99.2 or later). Connect also adds it to Pi's settings, for pi you start yourself. A cherry entry in Pi's settings takes precedence over it.")
    #expect(AgentSettingsPage.mcpHelp(for: .pi, connectsAtLaunch: false) == piHelp)
    // A Pi agent whose command turns off Pi's MCP uses what Connect adds.
    #expect(AgentSettingsPage.mcpConnection(
        for: AgentToolDefinition(name: "Pi", command: "pi", arguments: "--no-mcp"), identity: identity
    ).help == piHelp)

    // With Connect agents Cherry starts off, every agent uses what Connect
    // registers; the commands stay.
    let claudeOff = AgentSettingsPage.mcpConnection(for: try preset("Claude"), identity: identity, connectsAtLaunch: false)
    #expect(claudeOff.help == "Lets Claude Code see and drive your tabs. Connect runs claude mcp add once you confirm; Claude Code keeps it in its own settings.")
    #expect(claudeOff.command == "claude mcp add --transport stdio --scope user cherry-dev -- \(helper)")
    #expect(AgentSettingsPage.mcpConnection(for: try preset("Codex"), identity: identity, connectsAtLaunch: false).help
        == "Lets Codex see and drive your tabs. Connect runs codex mcp add once you confirm; Codex keeps it in its own settings.")
    #expect(AgentSettingsPage.mcpConnection(for: try preset("Pi"), identity: identity, connectsAtLaunch: false).help == piHelp)

    // A Claude Code or Codex agent whose command Cherry doesn't extend (its
    // own MCP configuration, not a plain claude command) uses what Connect
    // registers too, whatever the switch says.
    for agent in [
        AgentToolDefinition(name: "Claude", command: "claude", arguments: "--mcp-config team.json"),
        AgentToolDefinition(name: "Claude via npx", command: "npx", arguments: "@anthropic-ai/claude-code"),
        AgentToolDefinition(name: "Codex", command: "codex", arguments: "-c 'mcp_servers.x={command=\"y\"}'"),
    ] {
        let connection = AgentSettingsPage.mcpConnection(for: agent, identity: identity)
        #expect(connection.help.hasPrefix("Lets \(connection.harness?.productName ?? "?") see and drive your tabs."), "\(agent.commandLine)")
    }
    #expect(AgentSettingsPage.mcpConnection(
        for: AgentToolDefinition(name: "Opus", command: "/opt/homebrew/bin/claude", arguments: "--model opus"), identity: identity
    ).help.hasPrefix("Cherry starts Claude Code with Cherry MCP"))

    // A CLI Cherry has no command for: where the helper is, and no Connect.
    for name in ["Gemini", "OpenCode", "Amp"] {
        let connection = AgentSettingsPage.mcpConnection(for: try preset(name), identity: identity)
        #expect(connection.harness == nil, "\(name)")
        #expect(connection.command == nil, "\(name)")
    }
    let gemini = AgentSettingsPage.mcpConnection(for: try preset("Gemini"), identity: identity)
    #expect(gemini.title == "Connect Gemini CLI to Cherry")
    #expect(gemini.help == "Add Cherry's MCP helper to Gemini CLI as a stdio server.")
    let custom = AgentSettingsPage.mcpConnection(for: AgentToolDefinition(name: "Reviewer", command: "review-bot"), identity: identity)
    #expect(custom.harness == nil)
    #expect(custom.title == "Connect Reviewer to Cherry")
    #expect(custom.help == "Add Cherry's MCP helper to Reviewer as a stdio server.")
}

/// Pi's row in each state: its status at the row's end, the line under it,
/// and its button (Check Again reads again; Connect, Make Deferred and
/// Re-register run `pi mcp add`, offered only on a Pi with MCP).
@Test @MainActor func settingsWindowAgentPagePiRowSaysWhatEachStateMeans() {
    let v = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    func row(_ state: PiMCPRegistration.State) -> AgentSettingsPage.PiRow {
        AgentSettingsPage.piRow(for: state, serverName: "cherry")
    }
    func look(_ state: PiMCPRegistration.State) -> String {
        let row = row(state)
        return "\(row.status) \(row.style) \(row.dot) \(row.button ?? "-") \(row.buttonRegisters) \(row.menuButton ?? "-")"
    }
    let unknown = "Cherry connects only a Pi it knows has MCP (0.99.2 or later)."

    #expect(look(.checking) == "Checking… neutral gray - true -")
    #expect(row(.checking).detail == nil)
    #expect(look(.notInstalled) == "Not installed neutral gray Check Again false -")
    // Every directory the lookup searches, from its own list.
    #expect(row(.notInstalled).detail
        == "pi isn't on your login shell's PATH (nor in ~/.local/bin, ~/.claude/local, ~/.bun/bin, /opt/homebrew/bin or /usr/local/bin).")
    for directory in MCPCLIRegistration.fallbackDirectories(homeDirectory: "~") {
        #expect(row(.notInstalled).detail?.contains(directory) == true, "\(directory)")
    }
    #expect(look(.unknownVersion(path: "/x/pi", output: "garbage")) == "Unknown Pi warning orange Check Again false -")
    #expect(row(.unknownVersion(path: "/x/pi", output: "garbage")).detail == "/x/pi --version printed “garbage”. \(unknown)")
    #expect(look(.noAnswer(path: "/x/pi")) == "Unknown Pi warning orange Check Again false -")
    #expect(row(.noAnswer(path: "/x/pi")).detail == "/x/pi --version did not answer. \(unknown)")
    #expect(look(.withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0))) == "Update Pi warning orange Check Again false -")
    #expect(row(.withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0))).detail
        == "Pi 0.62.0 has no MCP. Pi 0.99.2 or later uses Cherry's tools; until then Pi agents work without them.")
    #expect(look(.notConnected(v)) == "Not connected neutral gray Connect true -")
    #expect(row(.notConnected(v)).detail
        == "Pi agents Cherry starts get Cherry MCP for their session (nothing saved). Connect adds it to Pi's settings, for pi you start yourself.")
    // Deferred needs nothing: Connect Again only in the ⋯ menu.
    #expect(look(.connected(v, .deferred)) == "Connected ok green - true Connect Again")
    #expect(row(.connected(v, .deferred)).detail == "Pi 1.3.0 loads Cherry's tools with tool_search when it needs them.")
    // Direct works and is the user's choice: Make Deferred is an offer.
    #expect(look(.connected(v, .direct)) == "Connected (direct) ok green Make Deferred true -")
    #expect(row(.connected(v, .direct)).detail
        == "Pi sends all of Cherry's tools with every request (about 25 KB). Make Deferred keeps them out until Pi needs them.")
    #expect(look(.toolsHidden(v, "codemode")) == "Tools hidden warning orange Make Deferred true -")
    #expect(row(.toolsHidden(v, "codemode")).detail
        == "Its exposure is codemode: only Pi's codemode scripts (or nothing) reach Cherry's tools, and Pi agents Cherry starts use this one too, since Pi prefers its own settings.")
    #expect(look(.turnedOff(v)) == "Turned off in Pi warning orange Connect true -")
    #expect(row(.turnedOff(v)).detail
        == "Pi's settings turn cherry off, which also turns off the one Cherry gives agents it starts. Connect replaces it with an enabled one.")
    #expect(look(.otherHelper(v, path: "/Other/CherryMCP", runs: true)) == "Another Cherry warning orange Re-register true -")
    #expect(row(.otherHelper(v, path: "/Other/CherryMCP", runs: true)).detail
        == "Pi's cherry runs /Other/CherryMCP. It still reaches the Cherry its tab runs in; Re-register makes it this copy's.")
    #expect(look(.otherHelper(v, path: "/Gone/CherryMCP", runs: false)) == "Broken warning orange Re-register true -")
    #expect(row(.otherHelper(v, path: "/Gone/CherryMCP", runs: false)).detail
        == "Pi's cherry runs /Gone/CherryMCP, which isn't there any more. Pi prefers it to the server Cherry gives agents it starts, so they have no Cherry tools until you re-register.")
    #expect(look(.otherArguments(v, line: "/x/CherryMCP --debug")) == "Differs warning orange Re-register true -")
    #expect(row(.otherArguments(v, line: "/x/CherryMCP --debug")).detail == "Pi's cherry runs /x/CherryMCP --debug.")
    #expect(look(.unreadable(v, "bad JSON")) == "Can't read warning orange Check Again false -")
    #expect(row(.unreadable(v, "bad JSON")).detail == "Pi's MCP settings could not be read: bad JSON.")
}

/// "Or run it yourself:" and Connect other agent CLIs show `pi mcp add …`
/// only for a Pi that said it has MCP, as the Connect sheet does: an older
/// Pi would take the words as prompts for its model. Claude Code's and
/// Codex's always show.
@Test @MainActor func settingsWindowAgentPageShowsPisCommandOnlyOnAPiWithMCP() {
    let v = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    let hidden: [PiMCPRegistration.State] = [
        .checking, .notInstalled, .unknownVersion(path: "/x/pi", output: "garbage"), .noAnswer(path: "/x/pi"),
        .withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0)),
    ]
    let shown: [PiMCPRegistration.State] = [
        .notConnected(v), .connected(v, .deferred), .connected(v, .direct), .toolsHidden(v, "codemode"), .turnedOff(v),
        .otherHelper(v, path: "/x/CherryMCP", runs: true), .otherArguments(v, line: "/x/CherryMCP --debug"), .unreadable(v, "bad JSON"),
    ]
    for state in hidden {
        #expect(!AgentSettingsPage.showsCommand(for: .pi, pi: state), "\(state)")
        #expect(AgentConnection.row(pi: state, serverName: "cherry", connectsAtLaunch: true).commandAction == nil, "\(state)")
        for harness in [MCPHarness.claude, .codex] {
            #expect(AgentSettingsPage.showsCommand(for: harness, pi: state), "\(harness) \(state)")
        }
    }
    for state in shown {
        #expect(AgentSettingsPage.showsCommand(for: .pi, pi: state), "\(state)")
    }
    // The minimum itself has MCP.
    #expect(AgentSettingsPage.showsCommand(for: .pi, pi: .notConnected(PiMCPRegistration.minimumVersion)))
}

/// Two agents of one CLI (Claude and Claude 2) use one registration model,
/// so what Connect did shows on both pages and stays when a page goes.
@Test @MainActor func settingsWindowAgentPagesOfOneCLIShareItsRegistration() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Claude"), try preset("Codex")])
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2", "Codex"])
    let registrations = MCPRegistrations(
        claude: MCPCLIRegistrationModel(harness: .claude, helperPath: nil, environment: { [:] }, locate: { _, _ in nil }),
        codex: MCPCLIRegistrationModel(harness: .codex, helperPath: nil, environment: { [:] }, locate: { _, _ in nil }),
        pi: PiMCPRegistrationModel(
            helperPath: nil, agentDirectory: URL(fileURLWithPath: "/nowhere"), environment: { [:] }, locate: { _, _ in nil }
        )
    )
    let models = settings.agents.map { agent in
        AgentSettingsPage.mcpConnection(for: agent).harness.flatMap(registrations.cliModel(for:))
    }
    #expect(models[0] === registrations.claude)
    #expect(models[1] === registrations.claude)
    #expect(models[2] === registrations.codex)
}

@Test @MainActor func settingsWindowAgentPageSaysWhetherTheAgentReportsItsState() throws {
    let claude = AgentSettingsPage.statusReporting(for: try preset("Claude"))
    #expect(claude == AgentSettingsPage.StatusReporting(
        status: "Supported",
        help: "Claude Code tells Cherry when it needs you, works and finishes, so the sidebar, notifications and MCP waits follow it. Needs Claude Code 2.1.295 or later.",
        style: .ok,
        dot: .green
    ))
    let pi = AgentSettingsPage.statusReporting(for: try preset("Pi"))
    #expect(pi.status == "Supported")
    #expect(pi.help.hasSuffix("Needs Pi 1.1.0 or later."))

    for name in ["Codex", "Amp"] {
        let reporting = AgentSettingsPage.statusReporting(for: try preset(name))
        #expect(reporting.status == "Not supported", "\(name)")
        #expect(reporting.style == .neutral, "\(name)")
    }
    #expect(AgentSettingsPage.statusReporting(for: try preset("Codex")).help
        == "Codex doesn't tell Cherry when it needs you, works or finishes.")

    for name in ["Gemini", "OpenCode"] {
        #expect(AgentSettingsPage.statusReporting(for: try preset(name)).status == "Not known", "\(name)")
    }
    #expect(AgentSettingsPage.statusReporting(for: try preset("Gemini")).help
        == "Cherry doesn't know whether Gemini CLI tells it when it needs you, works and finishes.")
    let custom = AgentSettingsPage.statusReporting(for: AgentToolDefinition(name: "Reviewer", command: "review-bot"))
    #expect(custom.status == "Not known")
    #expect(custom.help == "Cherry doesn't know whether Reviewer tells it when it needs you, works and finishes.")
    #expect(AgentSettingsPage.statusReportingCaption == "Agents that don't report fall back to their output going quiet.")
}

@Test @MainActor func settingsWindowAgentPageHeaderTileAndTags() throws {
    let claude = try preset("Claude")
    #expect(AgentSettingsPage.header(for: claude) == AgentSettingsPage.Header(subtitle: "Claude Code", isMonospaced: false))
    #expect(AgentSettingsPage.header(for: try preset("Gemini")).subtitle == "Gemini CLI")
    // A custom agent: its command line, in mono; nothing without one.
    let custom = AgentToolDefinition(name: "Reviewer", command: "review-bot", arguments: "--fast")
    #expect(AgentSettingsPage.header(for: custom) == AgentSettingsPage.Header(subtitle: "review-bot --fast", isMonospaced: true))
    #expect(AgentSettingsPage.header(for: AgentToolDefinition(name: "Empty", command: "")).subtitle == nil)

    let tile = AgentSettingsPage.tile(for: claude)
    #expect(tile.glyph == .letters("Cl"))
    #expect(tile.size == .extraLarge)
    #expect(AgentSettingsPage.tile(for: custom).glyph == .letters("Re"))

    #expect(AgentSettingsPage.argumentsTags(for: claude) == ["Skips permission prompts"])
    #expect(AgentSettingsPage.argumentsTags(for: try preset("Codex")) == ["Skips permission prompts"])
    #expect(AgentSettingsPage.argumentsTags(for: try preset("Pi")).isEmpty)
    #expect(AgentSettingsPage.argumentsHelp(for: claude) == "Every new Claude tab starts with these.")

    #expect(AgentSettingsPage.Field.command.title == "Command")
    #expect(AgentSettingsPage.Field.arguments.title == "Default arguments")
    #expect(AgentSettingsPage.Field.command.placeholder == "claude")
    #expect(AgentSettingsPage.Field.arguments.placeholder == "--model opus")
}

/// The command fields and Enabled save where the agent is in the list (the
/// Agents menu's order), trimmed; the same text again writes nothing; an
/// empty command is refused with validation's reason.
@Test @MainActor func settingsWindowAgentPageSavesItsFieldsWhereTheAgentIs() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Codex"), try preset("Pi")])

    try AgentSettingsPage.save(.command, text: "  codex-beta ", ofAgentNamed: "Codex", in: settings)
    try AgentSettingsPage.save(.arguments, text: "--model opus", ofAgentNamed: "Claude", in: settings)
    #expect(settings.agents.map(\.name) == ["Claude", "Codex", "Pi"])
    #expect(settings.agents[1].command == "codex-beta")
    #expect(settings.agents[0].arguments == "--model opus")

    let changes = Recorder(0)
    let watch = settings.objectWillChange.sink { changes.value += 1 }
    try AgentSettingsPage.save(.arguments, text: " --model opus ", ofAgentNamed: "Claude", in: settings)
    try AgentSettingsPage.setEnabled(true, ofAgentNamed: "Claude", in: settings)
    #expect(changes.value == 0, "nothing changed, nothing written")
    watch.cancel()

    #expect(throws: AgentConfigurationError.missingCommand(name: "Claude")) {
        try AgentSettingsPage.save(.command, text: "   ", ofAgentNamed: "Claude", in: settings)
    }
    #expect(settings.agents[0].command == "claude")
    #expect(AgentConfigurationError.missingCommand(name: "Claude").localizedDescription == "Agent 'Claude' is missing a command.")
    // Default arguments may be empty.
    try AgentSettingsPage.save(.arguments, text: "", ofAgentNamed: "Claude", in: settings)
    #expect(settings.agents[0].arguments == "")
    #expect(throws: AgentConfigurationError.unknownAgent("Gone")) {
        try AgentSettingsPage.save(.command, text: "gone", ofAgentNamed: "Gone", in: settings)
    }

    // Off keeps its place in the list.
    try AgentSettingsPage.setEnabled(false, ofAgentNamed: "Claude", in: settings)
    #expect(settings.agents.map(\.name) == ["Claude", "Codex", "Pi"])
    #expect(!settings.agents[0].enabled)
    #expect(settings.agents[1].enabled)
}

/// Rename… and Duplicate save the fields' edits first (the field keeps
/// the keyboard while the menu and the alert are up): under the agent's
/// name before the rename, into the original before the copy. One
/// validation refuses is reported and left out.
@Test @MainActor func settingsWindowAgentPageSavesItsEditsBeforeRenameOrDuplicate() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Codex")])
    let navigator = SettingsNavigator(initial: .agent("claude"))

    var errors = AgentSettingsPage.save([.command: "claude-beta", .arguments: "--model opus"], ofAgentNamed: "Claude", in: settings)
    #expect(errors.isEmpty)
    try AgentSettingsPage.rename("Claude", to: "Claude Work", in: settings, navigator: navigator)
    #expect(settings.agents[0].name == "Claude Work")
    #expect(settings.agents[0].command == "claude-beta")
    #expect(settings.agents[0].arguments == "--model opus")

    errors = AgentSettingsPage.save([.command: " ", .arguments: "--verbose"], ofAgentNamed: "Claude Work", in: settings)
    #expect(errors == [.command: AgentConfigurationError.missingCommand(name: "Claude Work").localizedDescription])
    let copy = try AgentSettingsPage.duplicate("Claude Work", in: settings, navigator: navigator)
    #expect(copy.command == "claude-beta")
    #expect(copy.arguments == "--verbose")
    #expect(settings.agents[0].arguments == "--verbose")
}

/// Rename… renames the agent where it is, and the page shown and the
/// history follow its new id; an empty or taken name is refused.
@Test @MainActor func settingsWindowAgentPageRenameRePointsTheRoute() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Codex")])
    let navigator = SettingsNavigator(initial: .page(.agents))
    navigator.open(.agent("claude"))

    #expect(AgentSettingsPage.renameTitle(agentName: "Claude") == "Rename “Claude”")
    #expect(AgentSettingsPage.renameProblem("  ", for: "Claude", in: settings.agents) == "Agent names cannot be empty.")
    #expect(AgentSettingsPage.renameProblem("codex", for: "Claude", in: settings.agents) == "Duplicate agent name: codex.")
    #expect(AgentSettingsPage.renameProblem("claude", for: "Claude", in: settings.agents) == nil)
    #expect(AgentSettingsPage.renameProblem("Claude Work", for: "Claude", in: settings.agents) == nil)

    let renamed = try AgentSettingsPage.rename("Claude", to: " Claude Work ", in: settings, navigator: navigator)
    #expect(renamed.name == "Claude Work")
    #expect(settings.agents.map(\.name) == ["Claude Work", "Codex"])
    #expect(settings.agents[0].command == "claude")
    #expect(navigator.route == .agent("claude work"))
    #expect(navigator.backHistory == [.page(.agents)])
    // The window's reconcile, a turn later, keeps the page.
    navigator.reconcile(agentIDs: Set(settings.agents.map(\.id)), projectRoots: [])
    #expect(navigator.route == .agent("claude work"))

    // A taken name changes nothing.
    #expect(throws: AgentConfigurationError.duplicateName("Codex")) {
        try AgentSettingsPage.rename("Claude Work", to: "Codex", in: settings, navigator: navigator)
    }
    #expect(throws: AgentConfigurationError.missingName) {
        try AgentSettingsPage.rename("Claude Work", to: " ", in: settings, navigator: navigator)
    }
    #expect(settings.agents.map(\.name) == ["Claude Work", "Codex"])
    #expect(navigator.route == .agent("claude work"))
    // The same name is no rename.
    #expect(try AgentSettingsPage.rename("Claude Work", to: "Claude Work", in: settings, navigator: navigator).name == "Claude Work")
    #expect(navigator.backHistory == [.page(.agents)])
}

/// Duplicate adds a copy right after the agent under a free name and opens
/// the copy's page.
@Test @MainActor func settingsWindowAgentPageDuplicateOpensTheCopysPage() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Codex")])
    let navigator = SettingsNavigator(initial: .agent("claude"))

    let copy = try AgentSettingsPage.duplicate("Claude", in: settings, navigator: navigator)
    #expect(copy.name == "Claude 2")
    #expect(copy.commandLine == "claude --dangerously-skip-permissions")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2", "Codex"])
    #expect(navigator.route == .agent("claude 2"))
    #expect(navigator.backHistory == [.agent("claude")])

    // Again: "Claude 3", after the first.
    #expect(try AgentSettingsPage.duplicate("Claude", in: settings, navigator: navigator).name == "Claude 3")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 3", "Claude 2", "Codex"])
}

/// Delete Agent… asks first (nothing goes before the answer); Delete
/// removes it, and the page falls back to Agents & MCP.
@Test @MainActor func settingsWindowAgentPageDeleteAsksThenFallsBack() throws {
    let settings = try agentSettings([try preset("Claude"), try preset("Codex")])
    let navigator = SettingsNavigator(initial: .page(.agents))
    navigator.open(.agent("claude"))

    let confirmation = AgentSettingsPage.deleteConfirmation(agentName: "Claude", settings: settings)
    #expect(confirmation.title == "Delete the agent “Claude”?")
    #expect(confirmation.message == "Its command and default arguments are deleted. Tabs it started keep running.")
    #expect(confirmation.choices.map(\.title) == ["Delete", "Cancel"])
    #expect(confirmation.choices.first?.role == .destructive)
    #expect(confirmation.choices.last?.role == .cancel)
    #expect(settings.agents.count == 2, "asking deletes nothing")

    confirmation.choices[1].perform()
    #expect(settings.agents.count == 2)
    confirmation.choices[0].perform()
    #expect(settings.agents.map(\.name) == ["Codex"])

    navigator.reconcile(agentIDs: Set(settings.agents.map(\.id)), projectRoots: [])
    #expect(navigator.route == .page(.agents))
    #expect(!navigator.backHistory.contains(.agent("claude")))
}

@Test @MainActor func settingsWindowAgentPageSearchRowsFindEachAgentsCommandAndMCP() throws {
    let defaults = privateDefaults("SettingsWindowAgentPageSearch")
    let settings = AgentSettings(defaults: defaults)
    try settings.addAgent(try preset("Claude"))
    try settings.addAgent(AgentToolDefinition(name: "Reviewer", command: "review-bot"))
    let context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: settings,
        defaults: defaults
    )

    let rows = AgentSettingsPage.searchRows(in: context)
    #expect(rows.map(\.id) == [
        .agent("claude", "command"), .agent("claude", "arguments"), .agent("claude", "mcp"), .agent("claude", "statusReporting"),
        .agent("reviewer", "command"), .agent("reviewer", "arguments"), .agent("reviewer", "mcp"), .agent("reviewer", "statusReporting"),
    ])
    #expect(rows.allSatisfy { if case .agent = $0.route { true } else { false } })
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    #expect(byID[.agent("claude", "command")]?.detail == "Command · claude")
    #expect(byID[.agent("claude", "arguments")]?.value == "--dangerously-skip-permissions")
    #expect(byID[.agent("claude", "arguments")]?.help == "Every new Claude tab starts with these.")
    #expect(byID[.agent("reviewer", "arguments")]?.value == nil)
    #expect(byID[.agent("claude", "mcp")]?.title == "Connect Claude Code to Cherry")
    #expect(byID[.agent("claude", "mcp")]?.section == "Cherry MCP")
    #expect(byID[.agent("claude", "mcp")]?.help?.hasPrefix("Cherry starts Claude Code with Cherry MCP") == true)
    #expect(byID[.agent("claude", "statusReporting")]?.detail == "Status reporting · Supported")
    #expect(byID[.agent("reviewer", "statusReporting")]?.value == "Not known")

    // Through the index: under the agents' group.
    let index = SettingsSearchIndex.rows(in: context)
    func agentResults(_ query: String) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: index).first { $0.kind == .agents }?.results.map(\.id) ?? []
    }
    #expect(agentResults("claude mcp add").contains(.agent("claude", "mcp")))
    #expect(agentResults("register").contains(.agent("claude", "mcp")))
    #expect(agentResults("register").contains(.agent("reviewer", "mcp")))
    #expect(agentResults("skips permission").contains(.agent("claude", "arguments")))
    #expect(agentResults("review-bot").contains(.agent("reviewer", "command")))
    #expect(Set(index.map(\.id)).count == index.count)

    // Connect agents Cherry starts off (Agents & MCP), stored or for this
    // run: the row says Add connects it.
    defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    func claudeHelp(_ context: SettingsSearchContext) -> String? {
        AgentSettingsPage.searchRows(in: context).first { $0.id == .agent("claude", "mcp") }?.help
    }
    #expect(claudeHelp(context)?.hasPrefix("Lets Claude Code see and drive your tabs.") == true)
    defaults.removeObject(forKey: AgentMCPLaunch.enabledDefaultsKey)
    let launchedOff = SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: settings,
        defaults: defaults,
        launchArguments: [AgentMCPLaunch.enabledDefaultsKey: false]
    )
    #expect(claudeHelp(launchedOff)?.hasPrefix("Lets Claude Code see and drive your tabs.") == true)
    #expect(claudeHelp(context)?.hasPrefix("Cherry starts Claude Code") == true)
}
