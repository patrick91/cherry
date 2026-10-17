import SwiftUI

/// Settings › Agents & MCP: the agents (each has a page of its own), the
/// presets, monitors, and Cherry's MCP server: whether the agents Cherry
/// starts get it on their command line, Connect Agents to Cherry…, and the
/// commands that connect agent CLIs to it.
struct AgentsSettingsPage: View, SettingsPageContent {
    static let listCaption = "Each agent has its own page: its command and connecting it to Cherry."
    static let wakeLinesHelp = "When an agent that subscribed to other tabs is idle, Cherry types one line into its tab once their events are ready."
    static let connectAtLaunchTitle = "Connect agents Cherry starts"
    static let connectAtLaunchHelp = "Claude Code \(AgentMCPLaunch.CLI.claudeCode.minimumVersion) or later, Codex \(AgentMCPLaunch.CLI.codex.minimumVersion) or later and Pi \(AgentMCPLaunch.CLI.pi.minimumVersion) or later that Cherry starts, here and on your other Macs, get Cherry MCP on their command line. Off: they use what you registered."
    static let connectAgentsTitle = "Connect Agents to Cherry"
    static let connectAgentsHelp = "Shows Claude Code, Codex and Pi on this Mac, whether each has Cherry MCP, and the command that connects it. Nothing runs until you confirm."
    static let otherCLIsTitle = "Connect other agent CLIs"
    static let otherCLIsIntro = "Agents use Cherry's MCP server to see and drive your tabs. Agents you start yourself, and ones Cherry doesn't connect when it starts them, need it registered once with their CLI."
    static let helperHelp = "Inside Cherry's app. Agents run it over stdio."
    static let controlSocketHelp = "Where the MCP helper reaches this copy of Cherry."
    static let otherMacsHelp = "Set up Cherry MCP on each Mac from Macs."

    @ObservedObject private var settings: AgentSettings
    private let navigator: SettingsNavigator
    private let defaults: UserDefaults
    private let registrations: MCPRegistrations

    /// What the editor sheet adds (+ Add Agent, Custom…); nil while it is
    /// closed.
    @State private var editorDraft: AgentToolDefinition?
    @State private var editorError: String?
    @State private var presetError: String?

    init(
        settings: AgentSettings = .shared,
        navigator: SettingsNavigator = .shared,
        defaults: UserDefaults = .standard,
        registrations: MCPRegistrations = .shared
    ) {
        self.settings = settings
        self.navigator = navigator
        self.defaults = defaults
        self.registrations = registrations
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.agents.title) {
            agentsSection
            presetsSection
            if let presetError {
                SettingsCaption(presetError, style: .error)
            }
            AgentsWakeLinesSection(defaults: defaults, search: navigator.search)
            AgentsMCPServerSection(navigator: navigator, registrations: registrations, defaults: defaults)
        }
        .sheet(item: $editorDraft) { draft in
            AgentToolEditor(
                agent: draft,
                canDelete: false,
                errorMessage: editorError,
                onSave: { agent in
                    do {
                        try Self.add(agent, to: settings, navigator: navigator)
                        editorError = nil
                        editorDraft = nil
                    } catch {
                        editorError = error.localizedDescription
                    }
                },
                onDelete: {},
                onCancel: {
                    editorError = nil
                    editorDraft = nil
                }
            )
        }
    }

    private var agentsSection: some View {
        SettingsSection("Agents", caption: Self.listCaption, id: .agentsList) {
            SettingsLinkButton("+ Add Agent") {
                openEditor(AgentToolDefinition(name: "", command: ""))
            }
        } content: {
            let rows = Self.listRows(settings.agents)
            if rows.isEmpty {
                SettingsEmptyState(
                    title: "No agents yet",
                    message: "Add one from a preset to start agents from the sidebar, the Agents menu and the Omni bar.",
                    systemImage: "sparkles"
                ) {
                    Button("Add Agent") {
                        openEditor(AgentToolDefinition(name: "", command: ""))
                    }
                    .settingsButton()
                }
            } else {
                ForEach(rows) { row in
                    SettingsListItem(id: row.id, opens: { navigator.open(row.route) }) {
                        SettingsListLabel(
                            row.name,
                            subtitle: row.commandLine,
                            monospacedSubtitle: true,
                            tile: .agent(letters: row.letters, isOff: row.isOff, size: .medium)
                        ) {
                            AgentTags(tags: row.tags)
                        }
                    }
                }
            }
        }
    }

    private var presetsSection: some View {
        SettingsSection("Presets", id: .agentsPresets) {
            ForEach(Self.presetRows) { preset in
                SettingsListItem {
                    SettingsListLabel(
                        preset.title,
                        subtitle: preset.subtitle,
                        monospacedSubtitle: !preset.isCustom
                    ) {
                        AgentTags(tags: preset.tags)
                    }
                } trailing: {
                    Button("Add") {
                        addPreset(preset)
                    }
                    .settingsButton(.standard, size: .small)
                    .accessibilityLabel(preset.addLabel)
                }
            }
        }
    }

    private func openEditor(_ draft: AgentToolDefinition) {
        editorError = nil
        editorDraft = draft
    }

    /// A preset with a command is added at once; Custom… opens the editor.
    private func addPreset(_ preset: PresetRow) {
        guard !preset.isCustom else {
            openEditor(preset.agent)
            return
        }
        do {
            try Self.add(preset.agent, to: settings, navigator: navigator)
            presetError = nil
        } catch {
            presetError = error.localizedDescription
        }
    }

    // MARK: - Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let wakeLines = wakeLinesEnabled(defaults: context.defaults, launchArguments: context.launchArguments)
        let connectsAtLaunch = connectsAgentsAtLaunch(defaults: context.defaults, launchArguments: context.launchArguments)
        return [
            SettingsSearchRow(
                id: .agentsList,
                route: .page(.agents),
                section: "Agents",
                title: "Agents",
                help: listCaption,
                keywords: ["agent", "claude", "codex", "pi", "gemini", "opencode", "amp", "preset"],
                value: countText(context.agents.agents.count)
            ),
            SettingsSearchRow(
                id: .agentsPresets,
                route: .page(.agents),
                section: "Presets",
                title: "Presets",
                keywords: ["preset", "add agent", "custom"]
                    + AgentConfiguration.presets.map(\.commandLine).filter { !$0.isEmpty }
            ),
            SettingsSearchRow(
                id: .agentsWakeLines,
                route: .page(.agents),
                section: "Monitors",
                title: "Wake idle agents",
                help: wakeLinesHelp,
                keywords: ["wake", "monitor", "subscribe"],
                value: SettingSource.onOff(wakeLines)
            ),
            SettingsSearchRow(
                id: .agentsMCPServer,
                route: .page(.agents),
                section: "MCP server",
                title: "MCP server",
                help: helperHelp,
                keywords: ["helper", "mcp helper", "stdio", "CherryMCP"]
            ),
            SettingsSearchRow(
                id: .agentsConnectAtLaunch,
                route: .page(.agents),
                section: "MCP server",
                title: connectAtLaunchTitle,
                help: connectAtLaunchHelp,
                keywords: ["mcp", "launch", "connect", "mcp-config", "register"],
                value: SettingSource.onOff(connectsAtLaunch)
            ),
            SettingsSearchRow(
                id: .agentsControlSocket,
                route: .page(.agents),
                section: "MCP server",
                title: "Control socket",
                help: controlSocketHelp,
                keywords: ["socket", "instance socket", "listening"]
            ),
            SettingsSearchRow(
                id: .agentsOtherMacs,
                route: .page(.agents),
                section: "MCP server",
                title: "Agents on your other Macs",
                help: otherMacsHelp,
                keywords: ["mac", "remote", "device", "set up cherry mcp"]
            ),
            SettingsSearchRow(
                id: .agentsConnectAgents,
                route: .page(.agents),
                section: "MCP server",
                title: connectAgentsTitle,
                help: connectAgentsHelp,
                keywords: ["connect", "register", "claude", "codex", "pi", "mcp add"]
            ),
            SettingsSearchRow(
                id: .agentsOtherCLIs,
                route: .page(.agents),
                section: "MCP server",
                title: otherCLIsTitle,
                help: otherCLIsIntro,
                // So a search finds the commands while no such agent is in
                // Cherry (an agent's page has its own).
                keywords: [
                    "install", "register", "claude mcp add", "codex mcp add", "pi mcp add",
                    "claude code", "codex", "pi",
                ]
            ),
        ]
    }
}

// MARK: - Lists and presets

extension AgentsSettingsPage {
    /// A tag after an agent's or a preset's name.
    struct Tag: Hashable {
        var text: String
        var style: SettingsTag.Style
    }

    /// An agent's row in the Agents list, which opens its page.
    struct ListRow: Identifiable, Equatable {
        var agentID: String
        var name: String
        /// Its tile's letters ("Cl").
        var letters: String
        /// Its command line; nil when it has none.
        var commandLine: String?
        var tags: [Tag]
        /// Disabled: its tile dimmed and "Off".
        var isOff: Bool

        var id: SettingsRowID { AgentsSettingsPage.rowID(agentID) }
        var route: SettingsRoute { .agent(agentID) }
    }

    /// A preset's row: its command line and tags, and Add. Custom… has no
    /// command; its Add opens the editor.
    struct PresetRow: Identifiable, Equatable {
        var agent: AgentToolDefinition
        var title: String
        var subtitle: String
        var tags: [Tag]
        var isCustom: Bool
        /// Add's VoiceOver label: "Add Claude", "Add a custom agent".
        var addLabel: String

        var id: String { agent.name }
    }

    /// "Skips permission prompts" when its line skips them, "Off" while it
    /// is disabled, and "No command" in orange when it is on without one.
    static func tags(for agent: AgentToolDefinition) -> [Tag] {
        var tags: [Tag] = []
        if agent.skipsPermissionPrompts {
            tags.append(Tag(text: "Skips permission prompts", style: .plain))
        }
        if !agent.enabled {
            tags.append(Tag(text: "Off", style: .plain))
        } else if agent.commandLine.isEmpty {
            tags.append(Tag(text: "No command", style: .warning))
        }
        return tags
    }

    /// The agents in their stored order (the Agents menu's).
    static func listRows(_ agents: [AgentToolDefinition]) -> [ListRow] {
        agents.map { agent in
            ListRow(
                agentID: agent.id,
                name: agent.name,
                letters: SettingsSidebarItems.letters(for: agent),
                commandLine: agent.commandLine.isEmpty ? nil : agent.commandLine,
                tags: tags(for: agent),
                isOff: !agent.enabled
            )
        }
    }

    /// Claude, Codex, Pi, Gemini, OpenCode and Amp with their command
    /// lines, then Custom….
    static var presetRows: [PresetRow] {
        AgentConfiguration.presets.map { preset in
            if preset.commandLine.isEmpty {
                PresetRow(
                    agent: preset,
                    title: "Custom…",
                    subtitle: "Any command line you choose.",
                    tags: [],
                    isCustom: true,
                    addLabel: "Add a custom agent"
                )
            } else {
                PresetRow(
                    agent: preset,
                    title: preset.name,
                    subtitle: preset.commandLine,
                    tags: tags(for: preset),
                    isCustom: false,
                    addLabel: "Add \(preset.name)"
                )
            }
        }
    }

    /// An agent's row in the Agents list: "agents.agent.claude".
    nonisolated static func rowID(_ agentID: String) -> SettingsRowID {
        SettingsRowID(rawValue: "agents.agent.\(agentID)")
    }

    /// "No agents", "1 agent", "4 agents".
    static func countText(_ count: Int) -> String {
        switch count {
        case 0: "No agents"
        case 1: "1 agent"
        default: "\(count) agents"
        }
    }

    /// Adds `agent` after the others under a name no agent has ("Claude
    /// 2": it never replaces one), then tints its row in the list.
    @discardableResult
    static func add(_ agent: AgentToolDefinition, to settings: AgentSettings, navigator: SettingsNavigator) throws -> AgentToolDefinition {
        let added = try settings.addAgent(agent)
        navigator.open(.page(.agents), row: rowID(added.id))
        return added
    }
}

// MARK: - Monitors and the MCP server

extension AgentsSettingsPage {
    /// Whether Cherry types wake lines, as `AgentMonitorRegistry` reads it:
    /// a launch argument first, then the stored value, then the default.
    static func wakeLinesEnabled(defaults: UserDefaults, launchArguments: [String: Any]) -> Bool {
        let key = AgentMonitorRegistry.wakeLinesDefaultsKey
        if let argument = launchArguments[key] {
            return argument as? Bool ?? AgentMonitorRegistry.wakeLinesDefault
        }
        return defaults.object(forKey: key) as? Bool ?? AgentMonitorRegistry.wakeLinesDefault
    }

    /// Wake idle agents' badge: Set here while it is off; ↺ removes the
    /// stored value, so the default applies again. `showDefault` runs just
    /// before the removal, so the switch shows the default at once whether
    /// or not its storage sees a key go.
    static func wakeLinesSource(
        defaults: UserDefaults,
        launchArguments: [String: Any],
        showDefault: @escaping @MainActor () -> Void = {}
    ) -> SettingsSourceState {
        let key = AgentMonitorRegistry.wakeLinesDefaultsKey
        let isOn = wakeLinesEnabled(defaults: defaults, launchArguments: launchArguments)
        return .stored(
            key: key,
            defaults: defaults,
            launchArguments: launchArguments,
            value: SettingSource.onOff(isOn),
            defaultValue: SettingSource.onOff(AgentMonitorRegistry.wakeLinesDefault),
            parses: { $0 as? Bool != nil },
            isDefault: { $0 as? Bool == AgentMonitorRegistry.wakeLinesDefault },
            reset: {
                showDefault()
                defaults.removeObject(forKey: key)
            }
        )
    }

    /// Whether the agents Cherry starts get Cherry MCP on their command
    /// line, as their launches read it (`AgentMCPLaunch.isEnabled`): a
    /// launch argument first, then the stored value, then the default.
    static func connectsAgentsAtLaunch(defaults: UserDefaults, launchArguments: [String: Any]) -> Bool {
        let key = AgentMCPLaunch.enabledDefaultsKey
        if let argument = launchArguments[key] {
            return argument as? Bool ?? AgentMCPLaunch.enabledDefault
        }
        return AgentMCPLaunch.isEnabled(defaults)
    }

    /// Connect agents Cherry starts' badge: Set here while it is off; ↺
    /// removes the stored value, as Wake idle agents' does
    /// (`wakeLinesSource`).
    static func connectAtLaunchSource(
        defaults: UserDefaults,
        launchArguments: [String: Any],
        showDefault: @escaping @MainActor () -> Void = {}
    ) -> SettingsSourceState {
        let key = AgentMCPLaunch.enabledDefaultsKey
        let isOn = connectsAgentsAtLaunch(defaults: defaults, launchArguments: launchArguments)
        return .stored(
            key: key,
            defaults: defaults,
            launchArguments: launchArguments,
            value: SettingSource.onOff(isOn),
            defaultValue: SettingSource.onOff(AgentMCPLaunch.enabledDefault),
            parses: { $0 as? Bool != nil },
            isDefault: { $0 as? Bool == AgentMCPLaunch.enabledDefault },
            reset: {
                showDefault()
                defaults.removeObject(forKey: key)
            }
        )
    }

    /// The Control socket row: the socket this app's server binds, which
    /// its tabs name (`CherryControlServer.appSocketPath`), and whether
    /// its socket file is there. No path while the server does not listen
    /// (another copy of Cherry answers there): never the socket a Cherry
    /// started from a Cherry tab inherited.
    struct ControlSocket: Equatable {
        var path: String?
        var isListening: Bool
    }

    /// The row for `path`, the app's socket unless a test names one.
    static func controlSocket(
        path: String? = CherryControlServer.appSocketPath,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ControlSocket {
        ControlSocket(path: path, isListening: path.map(fileExists) ?? false)
    }

    /// The control socket's status: "Listening" while its socket file is
    /// there, else "Not listening".
    static func socketStatus(exists: Bool) -> (text: String, style: SettingsStatusText.Style, dot: SettingsStatusDot.Tone) {
        exists ? ("Listening", .ok, .green) : ("Not listening", .warning, .orange)
    }

    /// The commands that register Cherry's MCP helper with each CLI, in
    /// the presets' order: Claude Code, Codex, Pi.
    static func otherCLICommands(_ commands: [MCPInstallCommand] = MCPInstallCommandBuilder.commands()) -> [MCPInstallCommand] {
        let order = AgentConfiguration.presets.compactMap {
            AgentToolBrand.detect(name: $0.name, commandLine: $0.commandLine)?.mcpHarness
        }
        return commands.sorted {
            (order.firstIndex(of: $0.harness) ?? order.count) < (order.firstIndex(of: $1.harness) ?? order.count)
        }
    }
}

extension SettingsRowID {
    static let agentsPresets: Self = "agents.presets"
    static let agentsWakeLines: Self = "agents.wakeLines"
    static let agentsConnectAtLaunch: Self = "agents.connectAtLaunch"
    static let agentsControlSocket: Self = "agents.controlSocket"
    static let agentsOtherMacs: Self = "agents.otherMacs"
    static let agentsConnectAgents: Self = "agents.connectAgents"
    static let agentsOtherCLIs: Self = "agents.otherCLIs"
}

// MARK: - Views

/// An agent's or a preset's tags, after its name.
private struct AgentTags: View {
    let tags: [AgentsSettingsPage.Tag]

    var body: some View {
        ForEach(tags, id: \.self) { tag in
            SettingsTag(tag.text, style: tag.style)
        }
    }
}

/// Monitors › Wake idle agents: a switch, Set here while off; read-only,
/// showing what the registry reads, while a launch argument sets it. Only
/// UserDefaults keeps it, which `SettingsSearchContext.liveChanges` doesn't
/// follow, so a change refreshes an open search's rows itself.
private struct AgentsWakeLinesSection: View {
    let defaults: UserDefaults
    let search: SettingsSearchModel
    @AppStorage private var isOn: Bool

    init(defaults: UserDefaults, search: SettingsSearchModel) {
        self.defaults = defaults
        self.search = search
        _isOn = AppStorage(
            wrappedValue: AgentMonitorRegistry.wakeLinesDefault,
            AgentMonitorRegistry.wakeLinesDefaultsKey,
            store: defaults
        )
    }

    var body: some View {
        let launchArguments = SettingSource.launchArguments(for: defaults)
        let source = AgentsSettingsPage.wakeLinesSource(defaults: defaults, launchArguments: launchArguments) {
            isOn = AgentMonitorRegistry.wakeLinesDefault
        }
        let isEditable = source.source.isEditable
        SettingsSection("Monitors") {
            SettingsItem(id: .agentsWakeLines, "Wake idle agents", help: AgentsSettingsPage.wakeLinesHelp, source: source) {
                Toggle(
                    "Wake idle agents",
                    isOn: isEditable
                        ? $isOn
                        : .constant(AgentsSettingsPage.wakeLinesEnabled(defaults: defaults, launchArguments: launchArguments))
                )
                .settingsSwitch()
                .disabled(!isEditable)
            }
        }
        .onChange(of: isOn) { _, _ in
            search.scheduleRowsRefresh()
        }
    }
}

/// MCP server: Connect agents Cherry starts (a switch, as Wake idle
/// agents), the helper agents run, the control socket it reaches this copy
/// of Cherry through, other Macs, Connect Agents to Cherry… (the sheet), and
/// the commands that connect each CLI (collapsed; a search result for it
/// opens it). Pi's registration is the one a Pi agent's page shows
/// (`MCPRegistrations.pi`).
private struct AgentsMCPServerSection: View {
    let navigator: SettingsNavigator
    let registrations: MCPRegistrations
    let defaults: UserDefaults
    @AppStorage private var connectsAtLaunch: Bool

    @State private var socket = AgentsSettingsPage.ControlSocket(path: nil, isListening: false)
    @State private var showsOtherCLIs = false

    init(navigator: SettingsNavigator, registrations: MCPRegistrations, defaults: UserDefaults) {
        self.navigator = navigator
        self.registrations = registrations
        self.defaults = defaults
        _connectsAtLaunch = AppStorage(
            wrappedValue: AgentMCPLaunch.enabledDefault,
            AgentMCPLaunch.enabledDefaultsKey,
            store: defaults
        )
    }

    var body: some View {
        let helperPath = MCPInstallCommandBuilder.helperPath ?? "CherryMCP"
        let status = AgentsSettingsPage.socketStatus(exists: socket.isListening)
        let launchArguments = SettingSource.launchArguments(for: defaults)
        let connectSource = AgentsSettingsPage.connectAtLaunchSource(defaults: defaults, launchArguments: launchArguments) {
            connectsAtLaunch = AgentMCPLaunch.enabledDefault
        }
        let isEditable = connectSource.source.isEditable
        SettingsSection("MCP server", id: .agentsMCPServer) {
            SettingsItem(
                id: .agentsConnectAtLaunch,
                AgentsSettingsPage.connectAtLaunchTitle,
                help: AgentsSettingsPage.connectAtLaunchHelp,
                source: connectSource
            ) {
                Toggle(
                    AgentsSettingsPage.connectAtLaunchTitle,
                    isOn: isEditable
                        ? $connectsAtLaunch
                        : .constant(AgentsSettingsPage.connectsAgentsAtLaunch(defaults: defaults, launchArguments: launchArguments))
                )
                .settingsSwitch()
                .disabled(!isEditable)
            }

            SettingsItem("MCP helper", help: AgentsSettingsPage.helperHelp) {
                SettingsCopyButton(text: helperPath, label: "Copy MCP helper path")
            } detail: {
                AgentsMonospacedPath(path: helperPath)
            }

            SettingsItem(id: .agentsControlSocket, "Control socket", help: AgentsSettingsPage.controlSocketHelp) {
                HStack(spacing: 10) {
                    SettingsStatusText(status.text, style: status.style, dot: status.dot)
                    Button("Refresh") {
                        refreshSocket()
                    }
                    .settingsButton(.standard, size: .small)
                }
            } detail: {
                if let path = socket.path {
                    AgentsMonospacedPath(path: path)
                }
            }

            SettingsItem(id: .agentsOtherMacs, "Agents on your other Macs", help: AgentsSettingsPage.otherMacsHelp) {
                Button("Show Macs") {
                    navigator.open(.page(.macs), row: .macsList)
                }
                .settingsButton(.standard, size: .small)
            }

            SettingsItem(id: .agentsConnectAgents, AgentsSettingsPage.connectAgentsTitle, help: AgentsSettingsPage.connectAgentsHelp) {
                Button("Connect…") {
                    ConnectAgentsPresenter.present(registrations: registrations)
                }
                .settingsButton(.standard, size: .small)
            }

            SettingsDisclosureHeader(AgentsSettingsPage.otherCLIsTitle, isExpanded: $showsOtherCLIs)
                .settingsRow(.agentsOtherCLIs)
                .expandsWhenFlashed(.agentsOtherCLIs, isExpanded: $showsOtherCLIs)
            if showsOtherCLIs {
                SettingsSubItem {
                    AgentsOtherCLIs(piRegistration: registrations.pi)
                }
                .settingsSeparatorAbove(false)
            }
        }
        .onAppear {
            refreshSocket()
        }
        .onChange(of: connectsAtLaunch) { _, _ in
            navigator.search.scheduleRowsRefresh()
        }
    }

    private func refreshSocket() {
        socket = AgentsSettingsPage.controlSocket()
    }
}

/// A path under a row's help: mono, selectable, truncated in the middle.
private struct AgentsMonospacedPath: View {
    let path: String

    var body: some View {
        Text(path)
            .font(SettingsDesign.Fonts.mono)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// The command each CLI registers Cherry's MCP helper with, to copy (Pi's
/// only on a Pi with MCP, `AgentSettingsPage.showsCommand`), and Pi's row
/// (`AgentSettingsPage.piRow`, the one a Pi agent's page shows): Pi's
/// version and what its mcp.json has (read only), and its button, which
/// runs `pi mcp add` only once the user confirms it and only on a Pi with
/// MCP.
private struct AgentsOtherCLIs: View {
    @ObservedObject var piRegistration: PiMCPRegistrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AgentsSettingsPage.otherCLIsIntro)
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(AgentsSettingsPage.otherCLICommands()) { installCommand in
                VStack(alignment: .leading, spacing: 6) {
                    Text(installCommand.harness.productName)
                        .font(SettingsDesign.Fonts.rowTitle)
                    if AgentSettingsPage.showsCommand(for: installCommand.harness, pi: piRegistration.state) {
                        SettingsCodeBlock(text: installCommand.command, copyLabel: "Copy the \(installCommand.harness.productName) command")
                    }
                    if installCommand.harness == .pi {
                        AgentsPiRegistration(model: piRegistration)
                    }
                }
            }
        }
        .task {
            await piRegistration.refresh()
        }
    }
}

private struct AgentsPiRegistration: View {
    @ObservedObject var model: PiMCPRegistrationModel
    @State private var request: AgentConnectionRequest?

    var body: some View {
        // No launch line here (the switch's row above says what launches
        // get), so the switch's value does not matter.
        let row = model.row(connectsAtLaunch: true)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsStatusText(row.status, style: row.style, dot: row.dot)
                AgentConnectionStatus(model: model, row: row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentConnectionActions(model: model, row: row, size: .small) {
                request = AgentConnectionRequest(plans: [$0])
            }
        }
        .agentConnectionConfirmation($request) { plans in
            for plan in plans { await model.perform(plan) }
        }
    }
}
