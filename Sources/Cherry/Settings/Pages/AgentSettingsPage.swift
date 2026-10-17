import CherryControl
import SwiftUI

/// An agent's page (the Agents section of the sidebar, a row of Agents &
/// MCP's list): whether it is on, its command and default arguments (saved
/// where it is in the list, so the Agents menu keeps its order), connecting
/// its CLI to Cherry's MCP helper (its CLI's row: what it has, and buttons
/// that run only what the user confirms), and whether it reports its state.
/// Rename…, Duplicate and Delete… are in the toolbar's `···`: a renamed
/// agent's page follows it (`SettingsNavigator.renameAgent`), a deleted
/// one's falls back to Agents & MCP (`SettingsNavigator.reconcile`).
struct AgentSettingsPage: View, SettingsPageContent {
    static let statusReportingCaption = "Agents that don't report fall back to their output going quiet."
    static let runItYourself = "Or run it yourself:"

    let agentID: String
    @ObservedObject private var settings: AgentSettings
    private let navigator: SettingsNavigator
    private let registrations: MCPRegistrations
    /// Where Connect agents Cherry starts is (Agents & MCP › MCP server).
    private let defaults: UserDefaults

    @State private var confirmation: SettingsConfirmation?
    @State private var isRenaming = false
    @State private var newName = ""
    /// Why the last Enabled, Rename… or Duplicate did nothing.
    @State private var actionError: String?
    /// The Command fields' edits not saved yet, and why a field's save was
    /// refused; kept here so Rename… and Duplicate save them first.
    @State private var drafts: [Field: String] = [:]
    @State private var draftErrors: [Field: String] = [:]

    init(
        agentID: String,
        settings: AgentSettings = .shared,
        navigator: SettingsNavigator = .shared,
        registrations: MCPRegistrations = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.agentID = agentID
        self.settings = settings
        self.navigator = navigator
        self.registrations = registrations
        self.defaults = defaults
    }

    private var agent: AgentToolDefinition? {
        settings.agents.first { $0.id == agentID }
    }

    var body: some View {
        if let agent {
            page(agent)
        } else {
            // Gone (deleted, renamed elsewhere): the navigator shows Agents
            // & MCP on the next turn.
            SettingsPageScroll(SettingsPage.agents.title) {}
        }
    }

    private func page(_ agent: AgentToolDefinition) -> some View {
        let header = Self.header(for: agent)
        let reporting = Self.statusReporting(for: agent)
        return SettingsPageScroll(agent.name, accessory: { toolbar(agent) }) {
            SettingsPageHeader(
                tile: Self.tile(for: agent),
                title: agent.name,
                subtitle: header.subtitle,
                monospacedSubtitle: header.isMonospaced
            )
            if let actionError {
                SettingsCaption(actionError, style: .error)
            }

            AgentCommandSection(agent: agent, settings: settings, drafts: $drafts, errors: $draftErrors)

            let connectsAtLaunch = AgentsSettingsPage.connectsAgentsAtLaunch(
                defaults: defaults,
                launchArguments: SettingSource.launchArguments(for: defaults)
            )
            AgentMCPSection(
                agentID: agent.id,
                connection: Self.mcpConnection(for: agent, connectsAtLaunch: connectsAtLaunch),
                connectsAtLaunch: connectsAtLaunch,
                registrations: registrations,
                navigator: navigator
            )

            SettingsSection("Status reporting", caption: Self.statusReportingCaption) {
                SettingsItem(id: .agent(agent.id, Self.statusReportingRow), "Reports its state", help: reporting.help) {
                    SettingsStatusText(reporting.status, style: reporting.style, dot: reporting.dot)
                }
            }

            SettingsPageFooter(caption: "Asks first.") {
                Button("Delete Agent…", role: .destructive) {
                    confirmation = Self.deleteConfirmation(agentName: agent.name, settings: settings)
                }
                .settingsButton(.danger)
            }
        }
        .settingsConfirmation($confirmation)
        .alert(Self.renameTitle(agentName: agent.name), isPresented: $isRenaming) {
            TextField(AgentToolEditor.nameLabel, text: $newName)
            Button("Rename") {
                saveDrafts(of: agent)
                perform { _ = try Self.rename(agent.name, to: newName, in: settings, navigator: navigator) }
            }
            .disabled(Self.renameProblem(newName, for: agent.name, in: settings.agents) != nil)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The toolbar's Enabled switch and `···`.
    private func toolbar(_ agent: AgentToolDefinition) -> some View {
        HStack(spacing: 8) {
            Text(AgentToolEditor.enabledLabel)
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Toggle(
                AgentToolEditor.enabledLabel,
                isOn: Binding(
                    get: { agent.enabled },
                    set: { isOn in perform { try Self.setEnabled(isOn, ofAgentNamed: agent.name, in: settings) } }
                )
            )
            .settingsSwitch()
            .help(AgentToolEditor.enabledHelp)

            SettingsMoreMenu("More actions for \(agent.name)") {
                Button("Rename…") {
                    newName = agent.name
                    isRenaming = true
                }
                Button("Duplicate") {
                    saveDrafts(of: agent)
                    perform { _ = try Self.duplicate(agent.name, in: settings, navigator: navigator) }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    confirmation = Self.deleteConfirmation(agentName: agent.name, settings: settings)
                }
            }
        }
    }

    /// Saves the Command fields' edits before Rename… or Duplicate open
    /// another page (the field keeps the keyboard while the menu and the
    /// alert are up, so nothing saved them): under the agent's name now,
    /// and into the copy. One validation refuses is dropped, as on leaving.
    private func saveDrafts(of agent: AgentToolDefinition) {
        _ = Self.save(drafts, ofAgentNamed: agent.name, in: settings)
        drafts = [:]
        draftErrors = [:]
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let connectsAtLaunch = AgentsSettingsPage.connectsAgentsAtLaunch(
            defaults: context.defaults,
            launchArguments: context.launchArguments
        )
        return context.agents.agents.flatMap { agent in
            let connection = mcpConnection(for: agent, connectsAtLaunch: connectsAtLaunch)
            let reporting = statusReporting(for: agent)
            return [
                SettingsSearchRow(
                    id: .agent(agent.id, Field.command.rowName),
                    route: .agent(agent.id),
                    section: "Command",
                    title: Field.command.title,
                    value: agent.command
                ),
                SettingsSearchRow(
                    id: .agent(agent.id, Field.arguments.rowName),
                    route: .agent(agent.id),
                    section: "Command",
                    title: Field.arguments.title,
                    help: argumentsHelp(for: agent),
                    keywords: argumentsTags(for: agent),
                    value: agent.arguments.isEmpty ? nil : agent.arguments
                ),
                SettingsSearchRow(
                    id: .agent(agent.id, mcpRow),
                    route: .agent(agent.id),
                    section: "Cherry MCP",
                    title: connection.title,
                    help: connection.help,
                    keywords: connection.searchKeywords
                ),
                SettingsSearchRow(
                    id: .agent(agent.id, statusReportingRow),
                    route: .agent(agent.id),
                    section: "Status reporting",
                    title: "Reports its state",
                    help: reporting.help,
                    keywords: ["program status", "state", "needs input"],
                    value: reporting.status
                ),
            ]
        }
    }
}

// MARK: - Editing the agent

extension AgentSettingsPage {
    /// The page's two text fields, saved on Return or when they lose focus.
    enum Field: CaseIterable, Hashable {
        case command
        case arguments

        /// The editor's own label.
        @MainActor var title: String {
            switch self {
            case .command: AgentToolEditor.commandLabel
            case .arguments: AgentToolEditor.argumentsLabel
            }
        }

        /// The editor's own placeholder.
        @MainActor var placeholder: String {
            switch self {
            case .command: AgentToolEditor.commandPlaceholder
            case .arguments: AgentToolEditor.argumentsPlaceholder
            }
        }

        /// Its row's name in its id: "agent.claude.command".
        var rowName: String {
            switch self {
            case .command: "command"
            case .arguments: "arguments"
            }
        }

        func value(of agent: AgentToolDefinition) -> String {
            switch self {
            case .command: agent.command
            case .arguments: agent.arguments
            }
        }
    }

    static let mcpRow = "mcp"
    static let statusReportingRow = "statusReporting"

    /// Saves `text` as the agent's command or default arguments, where the
    /// agent is in the list (`updateAgent`); nothing when it is what the
    /// agent has. Throws why not: a command cannot be empty.
    static func save(_ field: Field, text: String, ofAgentNamed name: String, in settings: AgentSettings) throws {
        let agent = try storedAgent(named: name, in: settings)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != field.value(of: agent) else { return }
        var updated = agent
        switch field {
        case .command: updated.command = text
        case .arguments: updated.arguments = text
        }
        try settings.updateAgent(named: agent.name, with: updated)
    }

    /// Saves each field's edit (`save(_:text:ofAgentNamed:in:)`). Returns
    /// why validation refused one, by field.
    static func save(_ drafts: [Field: String], ofAgentNamed name: String, in settings: AgentSettings) -> [Field: String] {
        var errors: [Field: String] = [:]
        for field in Field.allCases {
            guard let text = drafts[field] else { continue }
            do {
                try save(field, text: text, ofAgentNamed: name, in: settings)
            } catch {
                errors[field] = error.localizedDescription
            }
        }
        return errors
    }

    /// The toolbar's Enabled: off hides the agent from the Agents menu,
    /// the sidebar's + menu and the Omni bar; it keeps its place.
    static func setEnabled(_ isOn: Bool, ofAgentNamed name: String, in settings: AgentSettings) throws {
        var updated = try storedAgent(named: name, in: settings)
        guard updated.enabled != isOn else { return }
        updated.enabled = isOn
        try settings.updateAgent(named: name, with: updated)
    }

    /// Rename…'s alert: "Rename “Claude”".
    static func renameTitle(agentName: String) -> String {
        "Rename “\(agentName)”"
    }

    /// Why Rename… cannot use `newName` (its button is off then): an empty
    /// name, or another agent's. Validation's own texts.
    static func renameProblem(_ newName: String, for agentName: String, in agents: [AgentToolDefinition]) -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return AgentConfigurationError.missingName.localizedDescription }
        let id = AgentToolDefinition.normalizedName(name)
        guard id == AgentToolDefinition.normalizedName(agentName) || !agents.contains(where: { $0.id == id }) else {
            return AgentConfigurationError.duplicateName(name).localizedDescription
        }
        return nil
    }

    /// Renames the agent where it is, and the page shown (its route is its
    /// name's) and the history follow it. Returns the agent as stored.
    @discardableResult
    static func rename(
        _ name: String,
        to newName: String,
        in settings: AgentSettings,
        navigator: SettingsNavigator
    ) throws -> AgentToolDefinition {
        let agent = try storedAgent(named: name, in: settings)
        var renamed = agent
        renamed.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard renamed.name != agent.name else { return agent }
        try settings.updateAgent(named: agent.name, with: renamed)
        let stored = try storedAgent(named: renamed.name, in: settings)
        navigator.renameAgent(from: agent.id, to: stored.id)
        return stored
    }

    /// A copy right after the agent under a free name ("Claude 2"), whose
    /// page then opens.
    @discardableResult
    static func duplicate(_ name: String, in settings: AgentSettings, navigator: SettingsNavigator) throws -> AgentToolDefinition {
        let copy = try settings.duplicateAgent(named: name)
        navigator.open(.agent(copy.id))
        return copy
    }

    /// Delete Agent… and `···` › Delete…: the editor's question, then the
    /// agent goes; its page falls back to Agents & MCP.
    static func deleteConfirmation(agentName: String, settings: AgentSettings) -> SettingsConfirmation {
        AgentToolEditor.deleteConfirmation(agentName: agentName) {
            settings.removeAgent(named: agentName)
        }
    }

    private static func storedAgent(named name: String, in settings: AgentSettings) throws -> AgentToolDefinition {
        let id = AgentToolDefinition.normalizedName(name)
        guard let agent = settings.agents.first(where: { $0.id == id }) else {
            throw AgentConfigurationError.unknownAgent(name)
        }
        return agent
    }
}

// MARK: - What the page shows

extension AgentSettingsPage {
    /// The line under the page header's name.
    struct Header: Equatable {
        var subtitle: String?
        var isMonospaced: Bool
    }

    /// Cherry MCP for the agent's CLI: its row's title and help, and the
    /// command Connect runs, or, for a CLI Cherry has no command for, where
    /// the helper is. The row's state and buttons are its CLI's model's
    /// (`AgentConnection.row`, `piRow`).
    struct MCPConnection: Equatable {
        /// Nil: a CLI with no `mcp add` Cherry knows (Gemini CLI, OpenCode,
        /// Amp, a custom agent).
        var harness: MCPHarness?
        var title: String
        var help: String
        /// What Connect runs, for "Or run it yourself:"; nil without a
        /// harness.
        var command: String?
        var searchKeywords: [String]
    }

    /// Reports its state: whether the CLI tells Cherry its state (program
    /// status), from the docs' table; one that doesn't is followed by its
    /// output going quiet.
    struct StatusReporting: Equatable {
        var status: String
        var help: String
        var style: SettingsStatusText.Style
        var dot: SettingsStatusDot.Tone
    }

    /// The agent's CLI, as its tile letters say it.
    static func brand(of agent: AgentToolDefinition) -> AgentToolBrand? {
        AgentToolBrand.detect(name: agent.name, commandLine: agent.commandLine)
    }

    /// The CLI's product name ("Claude Code"), else the agent's name.
    static func cliName(of agent: AgentToolDefinition) -> String {
        brand(of: agent)?.productName ?? agent.name
    }

    /// The CLI's product name ("Claude Code"), else the agent's command
    /// line in mono; nothing without either.
    static func header(for agent: AgentToolDefinition) -> Header {
        if let brand = brand(of: agent) {
            return Header(subtitle: brand.productName, isMonospaced: false)
        }
        return Header(subtitle: agent.commandLine.isEmpty ? nil : agent.commandLine, isMonospaced: true)
    }

    /// Its letter tile, dimmed while it is off (as the sidebar's).
    static func tile(for agent: AgentToolDefinition) -> SettingsTile {
        .agent(letters: SettingsSidebarItems.letters(for: agent), isOff: !agent.enabled, size: .extraLarge)
    }

    static func argumentsHelp(for agent: AgentToolDefinition) -> String {
        "Every new \(agent.name) tab starts with these."
    }

    /// The tags under Default arguments: "Skips permission prompts" while
    /// its line skips them.
    static func argumentsTags(for agent: AgentToolDefinition) -> [String] {
        agent.skipsPermissionPrompts ? ["Skips permission prompts"] : []
    }

    /// `connectsAtLaunch`: Connect agents Cherry starts is on
    /// (`AgentsSettingsPage.connectsAgentsAtLaunch`). Only an agent whose
    /// own command line Cherry extends (`AgentMCPLaunch.detect`: a plain
    /// `claude`, `codex` or `pi` command naming no MCP configuration) is
    /// started with Cherry MCP.
    static func mcpConnection(
        for agent: AgentToolDefinition,
        identity: CherryAppIdentity = .current,
        connectsAtLaunch: Bool = true
    ) -> MCPConnection {
        guard let harness = brand(of: agent)?.mcpHarness else {
            let name = cliName(of: agent)
            return MCPConnection(
                harness: nil,
                title: "Connect \(name) to Cherry",
                help: "Add Cherry's MCP helper to \(name) as a stdio server.",
                command: nil,
                searchKeywords: ["mcp", "install", "register", "stdio", "helper"]
            )
        }
        let product = harness.productName
        let cli = harness.executableName
        let startsWithMCP = connectsAtLaunch
            && AgentMCPLaunch.detect(commandLine: agent.commandLine)?.cli == harness.launchCLI
        return MCPConnection(
            harness: harness,
            title: "Connect \(product) to Cherry",
            help: mcpHelp(for: harness, connectsAtLaunch: startsWithMCP, serverName: identity.urlScheme),
            command: MCPInstallCommandBuilder.command(for: harness, identity: identity).command,
            searchKeywords: ["mcp", "install", "register", "\(cli) mcp add"]
        )
    }

    /// What Cherry MCP's row says for `harness`'s CLI. The agents Cherry
    /// starts get Cherry MCP on their command line (`AgentMCPLaunch`) while
    /// Connect agents Cherry starts is on and their command is one Cherry
    /// extends (`connectsAtLaunch`), so Connect is for the sessions started
    /// elsewhere; otherwise they use what it registers.
    /// Pi prefers an entry named `serverName` in its settings to the one
    /// Cherry starts it with.
    static func mcpHelp(
        for harness: MCPHarness, connectsAtLaunch: Bool, serverName: String = CherryAppIdentity.current.urlScheme
    ) -> String {
        let product = harness.productName
        let cli = harness.executableName
        guard let launchCLI = harness.launchCLI, connectsAtLaunch else {
            if harness == .pi {
                return "\(product) agents use what Connect adds to \(product)'s settings (deferred: \(product) loads Cherry's tools when it needs them). Needs \(product) \(PiMCPRegistration.minimumVersion) or later."
            }
            return "Lets \(product) see and drive your tabs. Connect runs \(cli) mcp add once you confirm; \(product) keeps it in its own settings."
        }
        if harness == .pi {
            return "Cherry starts \(product) with Cherry MCP (\(launchCLI.minimumVersion) or later). Connect also adds it to \(product)'s settings, for \(cli) you start yourself. A \(serverName) entry in \(product)'s settings takes precedence over it."
        }
        return "Cherry starts \(product) with Cherry MCP (\(launchCLI.minimumVersion) or later). Connect also adds it to \(product)'s settings, for \(cli) you start yourself."
    }

    /// Whether `harness`'s `mcp add` shows to run by hand ("Or run it
    /// yourself:", Agents & MCP's Connect other agent CLIs): Claude Code's
    /// and Codex's always, Pi's only while `pi` says it has MCP
    /// (`PiMCPRegistration.State.hasMCP`), as the Connect sheet shows one
    /// only with a button that registers: a Pi without MCP takes `pi mcp
    /// add …` as prompts for its model.
    static func showsCommand(for harness: MCPHarness, pi state: PiMCPRegistration.State) -> Bool {
        harness != .pi || state.hasMCP
    }

    /// Pi's row, as a Pi agent's page and Agents & MCP's Connect other
    /// agent CLIs show it (`piRow`).
    struct PiRow: Equatable {
        var status: String
        var style: SettingsStatusText.Style
        var dot: SettingsStatusDot.Tone
        /// The line under the row: what the state means.
        var detail: String?
        /// Check Again, Connect, Make Deferred or Re-register; nil: none.
        var button: String?
        /// Whether `button` runs `pi mcp add` once the user confirms it
        /// (`PiMCPRegistrationModel.perform`); else it reads again
        /// (`refresh`).
        var buttonRegisters: Bool
        /// Connect Again, in a `⋯` menu, for a registration that needs
        /// nothing.
        var menuButton: String?
    }

    /// What Pi's row says and offers in `state`, `serverName` the name
    /// Cherry registers. A button that registers runs only on a Pi with MCP;
    /// one without it, or one Cherry can't tell, is only checked again.
    static func piRow(for state: PiMCPRegistration.State, serverName: String) -> PiRow {
        let minimum = PiMCPRegistration.minimumVersion
        func row(
            _ status: String,
            _ look: (SettingsStatusText.Style, SettingsStatusDot.Tone),
            _ detail: String?,
            button: String? = nil,
            registers: Bool = true,
            menu: String? = nil
        ) -> PiRow {
            PiRow(status: status, style: look.0, dot: look.1, detail: detail, button: button, buttonRegisters: registers, menuButton: menu)
        }
        let gray = (SettingsStatusText.Style.neutral, SettingsStatusDot.Tone.gray)
        let orange = (SettingsStatusText.Style.warning, SettingsStatusDot.Tone.orange)
        let green = (SettingsStatusText.Style.ok, SettingsStatusDot.Tone.green)
        let unknown = "Cherry connects only a Pi it knows has MCP (\(minimum) or later)."
        switch state {
        case .checking:
            return row("Checking…", gray, nil)
        case .notInstalled:
            return row(
                "Not installed", gray,
                "pi isn't on your login shell's PATH (nor in \(MCPCLIRegistration.shownFallbackDirectories)).",
                button: "Check Again", registers: false
            )
        case .unknownVersion(let path, let output):
            return row("Unknown Pi", orange, "\(path) --version printed “\(output)”. \(unknown)", button: "Check Again", registers: false)
        case .noAnswer(let path):
            return row("Unknown Pi", orange, "\(path) --version did not answer. \(unknown)", button: "Check Again", registers: false)
        case .withoutMCP(let version):
            return row(
                "Update Pi", orange,
                "Pi \(version) has no MCP. Pi \(minimum) or later uses Cherry's tools; until then Pi agents work without them.",
                button: "Check Again", registers: false
            )
        case .notConnected:
            return row(
                "Not connected", gray,
                "Pi agents Cherry starts get Cherry MCP for their session (nothing saved). Connect adds it to Pi's settings, for pi you start yourself.",
                button: "Connect"
            )
        case .connected(let version, .deferred):
            return row("Connected", green, "Pi \(version) loads Cherry's tools with tool_search when it needs them.", menu: "Connect Again")
        case .connected(_, .direct):
            return row(
                "Connected (direct)", green,
                "Pi sends all of Cherry's tools with every request (about 25 KB). Make Deferred keeps them out until Pi needs them.",
                button: "Make Deferred"
            )
        case .toolsHidden(_, let exposure):
            return row(
                "Tools hidden", orange,
                "Its exposure is \(exposure): only Pi's codemode scripts (or nothing) reach Cherry's tools, and Pi agents Cherry starts use this one too, since Pi prefers its own settings.",
                button: "Make Deferred"
            )
        case .turnedOff:
            return row(
                "Turned off in Pi", orange,
                "Pi's settings turn \(serverName) off, which also turns off the one Cherry gives agents it starts. Connect replaces it with an enabled one.",
                button: "Connect"
            )
        case .otherHelper(_, let path, runs: true):
            return row(
                "Another Cherry", orange,
                "Pi's \(serverName) runs \(path). It still reaches the Cherry its tab runs in; Re-register makes it this copy's.",
                button: "Re-register"
            )
        case .otherHelper(_, let path, runs: false):
            return row(
                "Broken", orange,
                "Pi's \(serverName) runs \(path), which isn't there any more. Pi prefers it to the server Cherry gives agents it starts, so they have no Cherry tools until you re-register.",
                button: "Re-register"
            )
        case .otherArguments(_, let line):
            return row("Differs", orange, "Pi's \(serverName) runs \(line).", button: "Re-register")
        case .unreadable(_, let why):
            return row("Can't read", orange, "Pi's MCP settings could not be read: \(why).", button: "Check Again", registers: false)
        }
    }

    static func statusReporting(for agent: AgentToolDefinition) -> StatusReporting {
        let name = cliName(of: agent)
        switch brand(of: agent)?.programStatusSupport ?? .unknown {
        case .reports(let minimumVersion):
            return StatusReporting(
                status: "Supported",
                help: "\(name) tells Cherry when it needs you, works and finishes, so the sidebar, notifications and MCP waits follow it. Needs \(name) \(minimumVersion) or later.",
                style: .ok,
                dot: .green
            )
        case .doesNotReport:
            return StatusReporting(
                status: "Not supported",
                help: "\(name) doesn't tell Cherry when it needs you, works or finishes.",
                style: .neutral,
                dot: .gray
            )
        case .unknown:
            return StatusReporting(
                status: "Not known",
                help: "Cherry doesn't know whether \(name) tells it when it needs you, works and finishes.",
                style: .neutral,
                dot: .gray
            )
        }
    }
}

// MARK: - Sections

/// Command: the command and default arguments as text fields, saved on
/// Return or when they lose focus (also by leaving the page, and before
/// Rename… or Duplicate), with validation's reason under a field it
/// refused.
private struct AgentCommandSection: View {
    typealias Field = AgentSettingsPage.Field

    let agent: AgentToolDefinition
    let settings: AgentSettings
    /// Edits not saved yet; a field without one shows the agent's value.
    @Binding var drafts: [Field: String]
    @Binding var errors: [Field: String]

    @FocusState private var focused: Field?

    var body: some View {
        SettingsSection("Command") {
            SettingsItem(id: .agent(agent.id, Field.command.rowName), Field.command.title) {
                textField(.command)
            }
            // The tags sit between the title and the help, so the help is
            // this row's detail.
            SettingsItem(id: .agent(agent.id, Field.arguments.rowName), Field.arguments.title) {
                textField(.arguments)
            } detail: {
                let tags = AgentSettingsPage.argumentsTags(for: agent)
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            SettingsTag(tag)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text(AgentSettingsPage.argumentsHelp(for: agent))
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: focused) { previous, _ in
            if let previous {
                commit(previous)
            }
        }
        .onChange(of: agent) { _, _ in
            // Changed elsewhere: a field not being edited shows it.
            for field in Field.allCases where focused != field && errors[field] == nil {
                drafts[field] = nil
            }
        }
        .onDisappear {
            saveOnLeaving()
        }
    }

    private func textField(_ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                field.title,
                text: Binding(
                    get: { drafts[field] ?? field.value(of: agent) },
                    set: { drafts[field] = $0 }
                ),
                prompt: Text(field.placeholder)
            )
            .labelsHidden()
            .settingsTextField(mono: true)
            .focused($focused, equals: field)
            .onSubmit {
                commit(field)
            }
            if let error = errors[field] {
                SettingsNote(error, style: .error)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func commit(_ field: Field) {
        guard let text = drafts[field] else { return }
        do {
            try AgentSettingsPage.save(field, text: text, ofAgentNamed: agent.name, in: settings)
            drafts[field] = nil
            errors[field] = nil
        } catch {
            errors[field] = error.localizedDescription
        }
    }

    /// Leaving the page loses focus too: an edit not saved yet is saved on
    /// the next turn, outside the update that takes the page away. One
    /// validation refuses is dropped.
    private func saveOnLeaving() {
        let pending = drafts
        guard !pending.isEmpty else { return }
        let name = agent.name
        DispatchQueue.main.async { [settings] in
            MainActor.assumeIsolated {
                _ = AgentSettingsPage.save(pending, ofAgentNamed: name, in: settings)
            }
        }
    }
}

/// Cherry MCP: the CLI's row (`AgentConnectionModel`: its state, read each
/// time the page shows, and buttons that open the confirmation; only its
/// Connect runs `mcp add`) and the command to run by hand (Pi's only on a
/// Pi with MCP, `AgentSettingsPage.showsCommand`); for a CLI Cherry has
/// no command for, a link to Agents & MCP's MCP server, which shows the
/// helper's path.
private struct AgentMCPSection: View {
    let agentID: String
    let connection: AgentSettingsPage.MCPConnection
    let connectsAtLaunch: Bool
    let registrations: MCPRegistrations
    let navigator: SettingsNavigator

    @State private var request: AgentConnectionRequest?

    var body: some View {
        let id = SettingsRowID.agent(agentID, AgentSettingsPage.mcpRow)
        SettingsSection("Cherry MCP") {
            if let harness = connection.harness {
                switch harness {
                case .claude: connectionRow(id: id, model: registrations.claude)
                case .codex: connectionRow(id: id, model: registrations.codex)
                case .pi: connectionRow(id: id, model: registrations.pi)
                }
                if let command = connection.command {
                    if harness == .pi {
                        AgentPiRunItYourself(command: command, model: registrations.pi)
                    } else {
                        AgentRunItYourself(command: command)
                    }
                }
            } else {
                SettingsItem(id: id, connection.title, help: connection.help) {
                    Button("Show MCP Server") {
                        navigator.open(.page(.agents), row: .agentsMCPServer)
                    }
                    .settingsButton(.standard, size: .small)
                }
            }
        }
        .agentConnectionConfirmation($request) { await registrations.perform($0) }
    }

    private func connectionRow<Model: AgentConnectionModel>(id: SettingsRowID, model: Model) -> some View {
        AgentConnectionSettingsRow(id: id, connection: connection, model: model, connectsAtLaunch: connectsAtLaunch) {
            request = AgentConnectionRequest(plans: [$0])
        }
    }
}

/// "Or run it yourself:" and the command Connect runs, to copy.
private struct AgentRunItYourself: View {
    let command: String

    var body: some View {
        SettingsSubItem {
            Text(AgentSettingsPage.runItYourself)
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
            SettingsCodeBlock(text: command, copyLabel: "Copy command")
        }
    }
}

/// Pi's "Or run it yourself:", only while its state says it has MCP
/// (`AgentSettingsPage.showsCommand`).
private struct AgentPiRunItYourself: View {
    let command: String
    @ObservedObject var model: PiMCPRegistrationModel

    var body: some View {
        if AgentSettingsPage.showsCommand(for: .pi, pi: model.state) {
            AgentRunItYourself(command: command)
        }
    }
}

/// An agent CLI's Cherry MCP row (`AgentConnection.Row`): its status and
/// buttons, what its state means and what the last run said; read each
/// time the page shows (`--version`, then the CLI's settings, read only).
private struct AgentConnectionSettingsRow<Model: AgentConnectionModel>: View {
    let id: SettingsRowID
    let connection: AgentSettingsPage.MCPConnection
    @ObservedObject var model: Model
    let connectsAtLaunch: Bool
    let confirm: (AgentConnection.Plan) -> Void

    var body: some View {
        let row = model.row(connectsAtLaunch: connectsAtLaunch)
        SettingsItem(id: id, connection.title, help: connection.help) {
            HStack(spacing: 10) {
                SettingsStatusText(row.status, style: row.style, dot: row.dot)
                AgentConnectionActions(model: model, row: row, size: .regular, confirm: confirm)
            }
        } detail: {
            AgentConnectionStatus(model: model, row: row)
                .padding(.top, 4)
        }
        .task {
            await model.refresh(asksAgain: false)
        }
    }
}

/// What a CLI's `mcp add` printed: mono, selectable, orange when it failed.
struct AgentRegistrationOutput: View {
    let text: String
    let failed: Bool

    var body: some View {
        Text(text)
            .font(SettingsDesign.Fonts.mono)
            .foregroundStyle(failed ? AnyShapeStyle(SettingsDesign.Colors.warningText) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .lineLimit(4)
            .padding(.top, 4)
    }
}
