import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared

    var body: some View {
        TabView {
            TerminalSettingsPane(settings: terminalSettings)
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }

            ProjectSettingsPane(settings: agentSettings)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            AgentSettingsPane(settings: agentSettings)
                .tabItem {
                    Label("Agents", systemImage: "sparkles")
                }
        }
        .frame(width: 680, height: 560)
    }
}

private struct ProjectSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var settings: AgentSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Projects")
                        .font(.system(size: 24, weight: .semibold))
                }

                Text("All the projects loaded in Cherry.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }

            Text("\(settings.projects.count) \(settings.projects.count == 1 ? "project" : "projects")")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(settings.projects) { project in
                    Button {
                        openProject(project)
                    } label: {
                        ProjectRow(project: project)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove Project", role: .destructive) {
                            settings.removeProject(project)
                        }
                    }

                    Divider()
                }

                Button {
                    chooseProjectRoot()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        Text("Add project")
                            .font(.system(size: 17))
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                    .frame(height: 46)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let project = settings.addProject(path: url.path) {
            openProject(project)
        }
    }

    private func openProject(_ project: CherryProject) {
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}

private struct ProjectRow: View {
    let project: CherryProject

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(project.root)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(height: 62)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

private struct TerminalSettingsPane: View {
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("App appearance", selection: $settings.appearance) {
                    ForEach(CherryAppearancePreference.allCases) { appearance in
                        Text(appearance.label)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Terminal Theme") {
                GhosttyThemeNameField(
                    title: "Light",
                    name: $settings.lightTerminalThemeName,
                    isKnown: settings.isKnownGhosttyTheme(settings.lightTerminalThemeName)
                )

                GhosttyThemeNameField(
                    title: "Dark",
                    name: $settings.darkTerminalThemeName,
                    isKnown: settings.isKnownGhosttyTheme(settings.darkTerminalThemeName)
                )
            }

            Section("Text") {
                SettingsSlider(
                    title: "Font size",
                    value: $settings.fontSize,
                    range: 10...24,
                    step: 1,
                    suffix: "pt"
                )
            }

            Section("Cursor") {
                Toggle("Blink cursor", isOn: $settings.cursorBlink)
            }

            Section("Color") {
                SettingsSlider(
                    title: "Minimum contrast",
                    value: $settings.minimumContrast,
                    range: 1...2,
                    step: 0.05,
                    suffix: "x"
                )
            }

            HStack {
                Spacer()
                Button("Reset Terminal Appearance") {
                    settings.resetTerminalAppearance()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct GhosttyThemeNameField: View {
    let title: String
    @Binding var name: String
    let isKnown: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            TextField("Ghostty theme name", text: $name)
                .textFieldStyle(.roundedBorder)

            Image(systemName: isKnown ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isKnown ? .green : .orange)
                .frame(width: 22)
        }
    }
}

private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Slider(value: $value, in: range, step: step)

            Text(formattedValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        if step >= 1 {
            "\(Int(value.rounded())) \(suffix)"
        } else {
            "\(value.formatted(.number.precision(.fractionLength(2))))\(suffix)"
        }
    }
}

private struct AgentSettingsPane: View {
    @ObservedObject var settings: AgentSettings

    @State private var editingAgent: AgentToolDefinition?
    @State private var editingSource: AgentToolSource?
    @State private var editingOriginalName: String?
    @State private var agentError: String?
    @State private var selectedProjectRoot: String?

    var body: some View {
        let project = settings.resolvedProject(for: selectedProjectRoot)
        let selectedProject = settings.selectedProject(for: selectedProjectRoot)

        VStack(spacing: 0) {
            Form {
                Section("Project") {
                    HStack {
                        Menu(selectedProject?.name ?? "Choose project") {
                            ForEach(settings.projects) { project in
                                Button(project.name) {
                                    selectedProjectRoot = project.root
                                }
                            }
                        }

                        Spacer()

                        Text(project.configState.message)
                            .foregroundStyle(configMessageColor)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text(project.validProjectRoot ?? "Add a project in Projects settings.")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()

                        if case .untrusted = project.configState {
                            Button("Trust cherry.toml") {
                                settings.trustSharedConfig(for: selectedProjectRoot)
                            }
                        }
                    }
                }

                Section("Agent Tools") {
                    if project.agents.isEmpty {
                        Text("No agents configured for this project.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(project.agents) { agent in
                            AgentToolRow(agent: agent) {
                                editingAgent = agent.definition
                                editingSource = agent.source
                                editingOriginalName = agent.name
                            } onReset: {
                                settings.removeLocalAgent(named: agent.name, for: selectedProjectRoot)
                            }
                        }
                    }

                    HStack {
                        Menu("Add Agent") {
                            ForEach(AgentConfiguration.presets) { preset in
                                Button(preset.name) {
                                    editingAgent = preset
                                    editingSource = .local
                                    editingOriginalName = nil
                                }
                            }
                        }
                        .disabled(project.validProjectRoot == nil)

                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .onAppear {
            if selectedProjectRoot == nil {
                selectedProjectRoot = ProjectWindowRegistry.shared.activeWorkspace?.projectRoot
                    ?? settings.projects.first?.root
            }
        }
        .onChange(of: settings.projects) { _, projects in
            if let selectedProjectRoot, projects.contains(where: { $0.root == selectedProjectRoot }) {
                return
            }
            selectedProjectRoot = projects.first?.root
        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: editingSource == .local,
                errorMessage: agentError,
                onSave: { updatedAgent in
                    do {
                        try settings.upsertLocalAgent(
                            updatedAgent,
                            for: selectedProjectRoot,
                            replacing: editingOriginalName
                        )
                        agentError = nil
                        editingOriginalName = nil
                        editingAgent = nil
                    } catch {
                        agentError = error.localizedDescription
                    }
                },
                onDelete: {
                    settings.removeLocalAgent(named: agent.name, for: selectedProjectRoot)
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                },
                onCancel: {
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                }
            )
        }
    }

    private var configMessageColor: Color {
        switch settings.resolvedProject(for: selectedProjectRoot).configState {
        case .error, .untrusted:
            .orange
        default:
            .secondary
        }
    }

}

private struct AgentToolRow: View {
    let agent: ResolvedAgentTool
    let onEdit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .fontWeight(.medium)
                    if !agent.enabled {
                        Text("Disabled")
                            .foregroundStyle(.secondary)
                    } else if !agent.isLaunchable {
                        Text("Blocked")
                            .foregroundStyle(.orange)
                    }
                }

                Text(agent.commandLine.isEmpty ? "No command" : agent.commandLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(sourceLabel)
                .foregroundStyle(.secondary)

            Button("Edit", action: onEdit)

            if agent.hasLocalOverride {
                Button("Reset", action: onReset)
            } else if agent.source == .local {
                Button("Delete", role: .destructive, action: onReset)
            }
        }
    }

    private var sourceLabel: String {
        switch agent.source {
        case .shared:
            "Shared"
        case .local:
            "Local"
        case .localOverride:
            "Local override"
        }
    }
}

private struct AgentToolEditor: View {
    @State private var draft: AgentToolDefinition

    let canDelete: Bool
    let errorMessage: String?
    let onSave: (AgentToolDefinition) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        agent: AgentToolDefinition,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (AgentToolDefinition) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: agent)
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Edit agent tool")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draft.name)
                TextField("Command", text: $draft.command)
                TextField("Default arguments", text: $draft.arguments)
                Toggle("Enabled", isOn: $draft.enabled)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if canDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
