import CherryControl
import SwiftUI

/// An agent's page (the Agents section of the sidebar, a row of Agents &
/// MCP's list): whether it is on, its command and default arguments (saved
/// where it is in the list, so the Agents menu keeps its order), connecting
/// its CLI to Cherry's MCP helper, and whether it reports its state.
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
        registrations: MCPRegistrations = .shared
    ) {
        self.agentID = agentID
        self.settings = settings
        self.navigator = navigator
        self.registrations = registrations
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

            AgentMCPSection(
                agentID: agent.id,
                connection: Self.mcpConnection(for: agent),
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
        context.agents.agents.flatMap { agent in
            let connection = mcpConnection(for: agent)
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

    /// Cherry MCP for the agent's CLI: Add to <CLI> and the command it
    /// runs, or, for a CLI Cherry has no command for, where the helper is.
    struct MCPConnection: Equatable {
        /// Nil: a CLI with no `mcp add` Cherry knows (Gemini CLI, OpenCode,
        /// Amp, a custom agent).
        var harness: MCPHarness?
        var title: String
        var help: String
        /// "Add to Claude Code"; nil without a harness (Show MCP Server).
        var addTitle: String?
        /// What Add runs, for "Or run it yourself:"; nil without a harness.
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

    static func mcpConnection(for agent: AgentToolDefinition, identity: CherryAppIdentity = .current) -> MCPConnection {
        guard let harness = brand(of: agent)?.mcpHarness else {
            let name = cliName(of: agent)
            return MCPConnection(
                harness: nil,
                title: "Connect \(name) to Cherry",
                help: "Add Cherry's MCP helper to \(name) as a stdio server.",
                addTitle: nil,
                command: nil,
                searchKeywords: ["mcp", "install", "register", "stdio", "helper"]
            )
        }
        let product = harness.productName
        let cli = harness.executableName
        return MCPConnection(
            harness: harness,
            title: "Connect \(product) to Cherry",
            help: "Lets \(product) see and drive your tabs. Runs \(cli) mcp add once; \(product) keeps it in its own settings.",
            addTitle: "Add to \(product)",
            command: MCPInstallCommandBuilder.command(for: harness, identity: identity).command,
            searchKeywords: ["mcp", "install", "register", "\(cli) mcp add"]
        )
    }

    /// Pi's Add: "Add Again" once Pi has Cherry as this app adds it.
    static func piAddTitle(status: PiMCPRegistration.Status) -> String {
        status == .registered ? "Add Again" : "Add to Pi"
    }

    /// Pi's status at its row's control end, as Claude Code's and Codex's
    /// are: gray while reading or not added, green once added, orange when
    /// Pi has another server of that name or its settings can't be read.
    /// The detail says it in full (`PiMCPRegistrationModel.statusText`).
    static func piStatusLook(_ status: PiMCPRegistration.Status, hasChecked: Bool) -> (text: String, style: SettingsStatusText.Style, dot: SettingsStatusDot.Tone) {
        guard hasChecked else { return ("Reading…", .neutral, .gray) }
        switch status {
        case .registered: return ("Added", .ok, .green)
        case .notRegistered: return ("Not added", .neutral, .gray)
        case .differs: return ("Differs", .warning, .orange)
        case .unreadable: return ("Can't read", .warning, .orange)
        }
    }

    /// Claude Code's or Codex's status: gray until Add ran, then green or
    /// orange.
    static func registrationLook(_ status: MCPCLIRegistrationModel.Status) -> (style: SettingsStatusText.Style, dot: SettingsStatusDot.Tone) {
        switch status {
        case .notChecked: (.neutral, .gray)
        case .added: (.ok, .green)
        case .failed: (.warning, .orange)
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

/// Cherry MCP: Add to <CLI> (only a click runs `mcp add`) and the command
/// to run by hand; for a CLI Cherry has no command for, a link to Agents &
/// MCP's MCP server, which shows the helper's path.
private struct AgentMCPSection: View {
    let agentID: String
    let connection: AgentSettingsPage.MCPConnection
    let registrations: MCPRegistrations
    let navigator: SettingsNavigator

    var body: some View {
        let id = SettingsRowID.agent(agentID, AgentSettingsPage.mcpRow)
        SettingsSection("Cherry MCP") {
            if let harness = connection.harness {
                if let model = registrations.cliModel(for: harness) {
                    AgentCLIConnectionRow(id: id, connection: connection, model: model)
                } else {
                    AgentPiConnectionRow(id: id, connection: connection, model: registrations.pi)
                }
                if let command = connection.command {
                    SettingsSubItem {
                        Text(AgentSettingsPage.runItYourself)
                            .font(SettingsDesign.Fonts.help)
                            .foregroundStyle(.secondary)
                        SettingsCodeBlock(text: command, copyLabel: "Copy command")
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
    }
}

/// Add to Claude Code or Add to Codex: "Not checked" until a click runs
/// the CLI's `mcp add`, then what it said.
private struct AgentCLIConnectionRow: View {
    let id: SettingsRowID
    let connection: AgentSettingsPage.MCPConnection
    @ObservedObject var model: MCPCLIRegistrationModel

    var body: some View {
        let look = AgentSettingsPage.registrationLook(model.status)
        SettingsItem(id: id, connection.title, help: connection.help) {
            HStack(spacing: 10) {
                SettingsStatusText(model.statusText, style: look.style, dot: look.dot)
                if model.isRunning {
                    ProgressView().controlSize(.small)
                }
                Button(connection.addTitle ?? "") {
                    Task { await model.register() }
                }
                .settingsButton()
                .disabled(model.isRunning || model.helperPath == nil)
            }
        } detail: {
            if let message = model.message {
                AgentRegistrationOutput(text: message, failed: model.status == .failed)
            }
        }
    }
}

/// Add to Pi (Add Again once Pi has it): whether Pi's mcp.json has Cherry,
/// read only (each time the page shows), and what the last Add said.
private struct AgentPiConnectionRow: View {
    let id: SettingsRowID
    let connection: AgentSettingsPage.MCPConnection
    @ObservedObject var model: PiMCPRegistrationModel

    var body: some View {
        let look = AgentSettingsPage.piStatusLook(model.status, hasChecked: model.hasChecked)
        SettingsItem(id: id, connection.title, help: connection.help) {
            HStack(spacing: 10) {
                SettingsStatusText(look.text, style: look.style, dot: look.dot)
                if model.isRunning {
                    ProgressView().controlSize(.small)
                }
                Button(AgentSettingsPage.piAddTitle(status: model.status)) {
                    Task { await model.register() }
                }
                .settingsButton()
                .disabled(model.isRunning || model.helperPath == nil)
            }
        } detail: {
            PiRegistrationStatus(model: model)
                .padding(.top, 4)
        }
        .task {
            await model.refresh()
        }
    }
}

/// Whether Pi has Cherry, in full, and what the last Add said: under a Pi
/// agent's Cherry MCP row and under Pi's command in Agents & MCP's Connect
/// other agent CLIs.
struct PiRegistrationStatus: View {
    @ObservedObject var model: PiMCPRegistrationModel

    var body: some View {
        let isRegistered = model.status == .registered
        VStack(alignment: .leading, spacing: 0) {
            Label(model.statusText, systemImage: isRegistered ? "checkmark.circle.fill" : "info.circle")
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(isRegistered ? AnyShapeStyle(SettingsDesign.Colors.okText) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                AgentRegistrationOutput(text: message, failed: model.lastRunFailed)
            }
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
