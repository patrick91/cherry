import CherryControl
import SwiftUI

/// An agent's page (the Agents section of the sidebar, a row of Agents'
/// list): whether it is on, its command and default arguments (saved where
/// it is in the list, so the Agents menu keeps its order), the `cherry`
/// skill for its CLI (installed only once the user confirms), how Cherry
/// starts it, and whether it reports its state. Rename…, Duplicate and
/// Delete… are in the toolbar's `···`: a renamed agent's page follows it
/// (`SettingsNavigator.renameAgent`), a deleted one's falls back to Agents
/// (`SettingsNavigator.reconcile`).
struct AgentSettingsPage: View, SettingsPageContent {
    static let statusReportingCaption = "Agents that don't report fall back to their output going quiet."

    let agentID: String
    @ObservedObject private var settings: AgentSettings
    private let navigator: SettingsNavigator
    private let skills: CherrySkillsModel
    /// Where Connect agents Cherry starts is (Agents).
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
        skills: CherrySkillsModel = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.agentID = agentID
        self.settings = settings
        self.navigator = navigator
        self.skills = skills
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
            // on the next turn.
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

            if let skillAgent = CherrySkillConnection.agent(for: Self.brand(of: agent)) {
                AgentSkillSection(agent: skillAgent, skills: skills)
            }

            let connectsAtLaunch = AgentsSettingsPage.connectsAgentsAtLaunch(
                defaults: defaults,
                launchArguments: SettingSource.launchArguments(for: defaults)
            )
            if let cli = Self.launchCLI(of: agent) {
                AgentLaunchSection(
                    agentID: agent.id, commandLine: agent.commandLine, cli: cli,
                    connectsAtLaunch: connectsAtLaunch, defaults: defaults
                )
            }

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
            ] + launchSearchRows(for: agent, connectsAtLaunch: connectsAtLaunch, defaults: context.defaults) + [
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
    /// agent goes; its page falls back to Agents.
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

    static func statusReporting(for agent: AgentToolDefinition) -> StatusReporting {
        let name = cliName(of: agent)
        switch brand(of: agent)?.programStatusSupport ?? .unknown {
        case .reports(let minimumVersion):
            return StatusReporting(
                status: "Supported",
                help: "\(name) tells Cherry when it needs you, works and finishes, so the sidebar, notifications and cherry wait follow it. Needs \(name) \(minimumVersion) or later.",
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

/// The `cherry` skill (and Codex's rules file) for this agent's CLI, read
/// each time the page shows; Install and Update open the confirmation, and
/// only its Install writes (`CherrySkillsModel`).
private struct AgentSkillSection: View {
    let agent: CherrySkillAgent
    @ObservedObject var skills: CherrySkillsModel

    var body: some View {
        if !skills.items(for: agent).isEmpty {
            SettingsSection("Cherry skill", caption: AgentSettingsPage.skillCaption) {
                SettingsSubItem {
                    CherrySkillRows(model: skills, agent: agent)
                }
            }
        }
        Color.clear.frame(height: 0)
            .task { await skills.refresh() }
    }
}

extension AgentSettingsPage {
    static let skillCaption = "Teaches the agent the cherry command, for sessions you start yourself too."
}

/// What an install printed: mono, selectable, orange when it failed.
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

// MARK: - Starting the agent

extension AgentSettingsPage {
    static let interfaceRow = "interface"
    static let approvalsRow = "approvals"
    static let approvalsHelp = "Auto review lets Claude Code's classifier, or Codex's automatic reviewer, decide "
        + "what the agent may do instead of asking you. It covers everything the agent does in the tabs Cherry "
        + "starts, not only cherry, and a command that sets its own mode keeps it."

    /// The CLI Cherry starts with flags of its own (`AgentLaunch.CLI`),
    /// nil for any other agent.
    static func launchCLI(of agent: AgentToolDefinition) -> AgentLaunch.CLI? {
        guard let brand = brand(of: agent) else { return nil }
        return AgentLaunch.CLI.allCases.first { $0.brand == brand }
    }

    /// The Interface line: what Cherry starts the agent with, and what that
    /// needs, from cached state only (`AgentSkillDirectory.current`,
    /// `CodexLaunchFactsCache`'s last reading).
    struct Interface: Equatable {
        var status: String
        var help: String
        var startsWithCLI: Bool
    }

    static func interface(
        cli: AgentLaunch.CLI,
        commandLine: String,
        connectsAtLaunch: Bool,
        skillReady: Bool,
        approvals: AgentApprovals,
        codexFacts: CodexLaunchFacts?
    ) -> Interface {
        guard connectsAtLaunch else {
            return Interface(
                status: "Started as it is",
                help: "Connect agents Cherry starts is off in Agents: Cherry adds nothing to its command line. The cherry command is still on its PATH.",
                startsWithCLI: false
            )
        }
        func viaCLI(_ help: String) -> Interface {
            Interface(status: "The cherry command", help: help, startsWithCLI: true)
        }
        switch cli {
        case .claudeCode, .pi:
            guard skillReady else {
                return Interface(
                    status: "Started as it is",
                    help: "The cherry skill's files aren't ready, so Cherry adds nothing to its command line. The cherry command is still on its PATH.",
                    startsWithCLI: false
                )
            }
            return viaCLI("Cherry gives it the cherry skill and a line about its tab, in each tab it starts.")
        case .codex:
            let lead = "Cherry tells it, in each tab it starts, that the cherry command reaches Cherry."
            if approvals == .autoReview {
                return viaCLI(lead + " Where its sandbox blocks Cherry's socket, a cherry command runs once Codex's reviewer lets it outside.")
            }
            let words = Array((AgentLaunch.plainWords(commandLine) ?? []).dropFirst())
            let facts = codexFacts ?? CodexLaunchFacts(rulesInstalled: false, setsDeveloperInstructions: true)
            if facts.rulesInstalled { return viaCLI(lead + " Cherry's rules for Codex run cherry outside its sandbox.") }
            if facts.launchReachesSockets(words: words) { return viaCLI(lead + " Its sandbox lets it reach Cherry's socket.") }
            return viaCLI(lead + " Its sandbox blocks Cherry's socket, so Codex asks you before each cherry command runs outside it: install Cherry's rules for Codex, or choose Auto review, to skip that.")
        }
    }

    static func launchSearchRows(
        for agent: AgentToolDefinition, connectsAtLaunch: Bool, defaults: UserDefaults
    ) -> [SettingsSearchRow] {
        guard let cli = launchCLI(of: agent) else { return [] }
        let approvals = AgentApprovals.current(for: cli, defaults: defaults)
        let interface = interface(
            cli: cli,
            commandLine: agent.commandLine,
            connectsAtLaunch: connectsAtLaunch,
            skillReady: AgentSkillDirectory.current != nil,
            approvals: approvals,
            codexFacts: CodexLaunchFactsCache.shared.facts
        )
        var rows = [
            SettingsSearchRow(
                id: .agent(agent.id, interfaceRow),
                route: .agent(agent.id),
                section: "Starting \(cli.brand.productName)",
                title: "Interface",
                help: interface.help,
                keywords: ["cherry command", "cli", "skill", "sandbox"],
                value: interface.status
            ),
        ]
        if AgentApprovals.isOffered(for: cli) {
            rows.append(SettingsSearchRow(
                id: .agent(agent.id, approvalsRow),
                route: .agent(agent.id),
                section: "Starting \(cli.brand.productName)",
                title: "Approvals",
                help: approvalsHelp,
                keywords: ["auto review", "auto mode", "permission mode", "approve for me", "permissions"],
                value: approvals.title
            ))
        }
        return rows
    }

    /// Stores Approvals for `cli` (As configured removes the value).
    static func setApprovals(_ value: AgentApprovals, for cli: AgentLaunch.CLI, defaults: UserDefaults) {
        if value == .configured {
            defaults.removeObject(forKey: AgentApprovals.defaultsKey(for: cli))
        } else {
            defaults.set(value.rawValue, forKey: AgentApprovals.defaultsKey(for: cli))
        }
    }
}

/// How the agents Cherry starts of `cli` reach Cherry (Interface), and
/// their Approvals (`AgentApprovals`, stored per CLI in `defaults`).
private struct AgentLaunchSection: View {
    let agentID: String
    let commandLine: String
    let cli: AgentLaunch.CLI
    let connectsAtLaunch: Bool
    let defaults: UserDefaults

    @State private var approvals: AgentApprovals?
    @State private var codexFacts: CodexLaunchFacts?

    var body: some View {
        let approvals = approvals ?? AgentApprovals.current(for: cli, defaults: defaults)
        let interface = AgentSettingsPage.interface(
            cli: cli,
            commandLine: commandLine,
            connectsAtLaunch: connectsAtLaunch,
            skillReady: AgentSkillDirectory.current != nil,
            approvals: approvals,
            codexFacts: codexFacts ?? CodexLaunchFactsCache.shared.facts
        )
        SettingsSection("Starting \(cli.brand.productName)") {
            SettingsItem(id: .agent(agentID, AgentSettingsPage.interfaceRow), "Interface", help: interface.help) {
                SettingsStatusText(interface.status, style: interface.startsWithCLI ? .ok : .neutral, dot: interface.startsWithCLI ? .green : .gray)
            }
            if AgentApprovals.isOffered(for: cli) {
                SettingsItem(id: .agent(agentID, AgentSettingsPage.approvalsRow), "Approvals", help: AgentSettingsPage.approvalsHelp) {
                    Picker("Approvals", selection: Binding(
                        get: { approvals },
                        set: { value in
                            self.approvals = value
                            AgentSettingsPage.setApprovals(value, for: cli, defaults: defaults)
                        }
                    )) {
                        ForEach(AgentApprovals.allCases, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .settingsMenuPicker()
                }
            }
        }
        .task {
            guard cli == .codex else { return }
            // Codex's files are read off the main thread: show the reading
            // once it is in.
            CodexLaunchFactsCache.shared.refresh()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let facts = CodexLaunchFactsCache.shared.facts {
                    codexFacts = facts
                    break
                }
            }
        }
    }
}
