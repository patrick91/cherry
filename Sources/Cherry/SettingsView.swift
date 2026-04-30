import AppKit
import GhosttyTheme
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

            CommandSettingsPane(settings: agentSettings)
                .tabItem {
                    Label("Commands", systemImage: "play.rectangle")
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
                GhosttyThemePicker(
                    title: "Light",
                    selection: $settings.lightTerminalThemeName
                )

                GhosttyThemePicker(
                    title: "Dark",
                    selection: $settings.darkTerminalThemeName
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

private struct GhosttyThemePicker: View {
    let title: String
    @Binding var selection: String

    private var selectedTheme: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: selection)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Picker("Ghostty theme", selection: $selection) {
                if selectedTheme == nil {
                    Text(selection.isEmpty ? "Select a theme" : "\(selection) (unknown)")
                        .tag(selection)
                }

                ForEach(Self.themes) { theme in
                    Text(theme.name)
                        .tag(theme.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let selectedTheme {
                GhosttyThemeSwatch(theme: selectedTheme)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private static let themes = GhosttyThemeCatalog.allThemes.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

private struct GhosttyThemeSwatch: View {
    let theme: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 4) {
            swatch(theme.background)
            swatch(theme.foreground)
            swatch(theme.selectionBackground ?? theme.palette[4] ?? theme.foreground)
        }
        .frame(width: 42, alignment: .trailing)
        .help(theme.name)
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(nsColor: NSColor(hexRGB: hex) ?? .clear))
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
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
    @State private var editingOriginalName: String?
    @State private var agentError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Agent Tools") {
                    if settings.resolvedAgents.isEmpty {
                        Text("No agents configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.resolvedAgents) { agent in
                            AgentToolRow(agent: agent) {
                                editingAgent = agent.definition
                                editingOriginalName = agent.name
                            } onReset: {
                                settings.removeAgent(named: agent.name)
                            }
                        }
                    }

                    HStack {
                        Menu("Add Agent") {
                            ForEach(AgentConfiguration.presets) { preset in
                                Button(preset.name) {
                                    editingAgent = preset
                                    editingOriginalName = nil
                                }
                            }
                        }

                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: editingOriginalName != nil,
                errorMessage: agentError,
                onSave: { updatedAgent in
                    do {
                        try settings.upsertAgent(
                            updatedAgent,
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
                    settings.removeAgent(named: agent.name)
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
}

private struct CommandSettingsPane: View {
    @ObservedObject var settings: AgentSettings

    @State private var selectedProjectRoot = ""
    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Project") {
                    if settings.projects.isEmpty {
                        Text("Add a project before configuring commands.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $selectedProjectRoot) {
                            ForEach(settings.projects) { project in
                                Text(project.name)
                                    .tag(project.root)
                            }
                        }
                    }
                }

                Section("Commands") {
                    if selectedProjectRoot.isEmpty || settings.projectCommands(for: selectedProjectRoot).isEmpty {
                        Text(settings.projects.isEmpty ? "No projects configured." : "No commands configured for this project.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.projectCommands(for: selectedProjectRoot)) { command in
                            ProjectCommandRow(command: command) {
                                editingCommand = command
                                editingOriginalName = command.name
                            } onDelete: {
                                settings.removeCommand(named: command.name, for: selectedProjectRoot)
                            }
                        }
                    }

                    HStack {
                        Button("Add Command") {
                            editingCommand = ProjectCommandDefinition(name: "Dev server", command: "npm", arguments: "run dev")
                            editingOriginalName = nil
                        }
                        .disabled(selectedProjectRoot.isEmpty)

                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .onAppear {
            if selectedProjectRoot.isEmpty {
                selectedProjectRoot = settings.projects.first?.root ?? ""
            }
        }
        .onChange(of: settings.projects) { _, projects in
            guard !projects.contains(where: { $0.root == selectedProjectRoot }) else { return }
            selectedProjectRoot = projects.first?.root ?? ""
        }
        .sheet(item: $editingCommand) { command in
            ProjectCommandEditor(
                command: command,
                projectRoot: selectedProjectRoot,
                canDelete: editingOriginalName != nil,
                errorMessage: commandError,
                onSave: { updatedCommand, storage in
                    do {
                        try settings.upsertCommand(
                            updatedCommand,
                            for: selectedProjectRoot,
                            replacing: editingOriginalName,
                            storage: storage
                        )
                        commandError = nil
                        editingOriginalName = nil
                        editingCommand = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                },
                onDelete: {
                    settings.removeCommand(named: command.name, for: selectedProjectRoot)
                    commandError = nil
                    editingOriginalName = nil
                    editingCommand = nil
                },
                onCancel: {
                    commandError = nil
                    editingOriginalName = nil
                    editingCommand = nil
                }
            )
        }
    }
}

private struct ProjectCommandRow: View {
    let command: ProjectCommandDefinition
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.name)
                    .foregroundStyle(command.enabled ? .primary : .secondary)

                Text(command.commandLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Edit", action: onEdit)
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

struct ProjectCommandEditor: View {
    @State private var draft: ProjectCommandDraft

    let projectRoot: String
    let canDelete: Bool
    let errorMessage: String?
    let onSave: (ProjectCommandDefinition, ProjectCommandStorage) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        command: ProjectCommandDefinition,
        projectRoot: String,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (ProjectCommandDefinition, ProjectCommandStorage) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: ProjectCommandDraft(command: command, projectRoot: projectRoot))
        self.projectRoot = projectRoot
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(canDelete ? "Edit command" : "Add command")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command name")
                        .foregroundStyle(.secondary)
                    TextField("e.g., Vite, Queue, Logs", text: $draft.name)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .foregroundStyle(.secondary)
                    TextField("e.g., npm run dev", text: $draft.commandLine)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Working directory")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField(projectRoot, text: $draft.workingDirectory)

                        Button("Browse") {
                            chooseWorkingDirectory()
                        }
                    }

                    Text("Leave empty to use project root")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Toggle("Auto-start when project starts", isOn: $draft.autoStart)
                Toggle("Auto-restart if command exits", isOn: $draft.autoRestart)
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Where to save this command")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ProjectCommandStorageOption(
                    title: "Save to cherry.toml",
                    subtitle: CherryProjectFile.exists(projectRoot: projectRoot)
                        ? "Share this command through the project config"
                        : "No cherry.toml found — Cherry will create one",
                    isSelected: draft.storage == .projectFile
                ) {
                    draft.storage = .projectFile
                }

                ProjectCommandStorageOption(
                    title: "Store locally only",
                    subtitle: "Keep this command just for yourself on this machine",
                    isSelected: draft.storage == .local
                ) {
                    draft.storage = .local
                }
            }

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
                    onSave(draft.definition, draft.storage)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !draft.workingDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: draft.workingDirectory).expandingTildeInPath)
        } else if !projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = url.path
    }
}

private struct ProjectCommandStorageOption: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "smallcircle.filled.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 18, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProjectCommandDraft {
    var name: String
    var commandLine: String
    var workingDirectory: String
    var autoStart: Bool
    var autoRestart: Bool
    var enabled: Bool
    var storage: ProjectCommandStorage

    init(command: ProjectCommandDefinition, projectRoot: String) {
        name = command.name
        commandLine = command.commandLine
        workingDirectory = command.workingDirectory.isEmpty ? "" : command.workingDirectory
        autoStart = command.autoStart
        autoRestart = command.autoRestart
        enabled = command.enabled
        storage = .local
        if name.isEmpty, commandLine.isEmpty, workingDirectory.isEmpty {
            self.workingDirectory = ""
        }
    }

    var definition: ProjectCommandDefinition {
        let parts = Self.splitCommandLine(commandLine)
        return ProjectCommandDefinition(
            name: name,
            command: parts.command,
            arguments: parts.arguments,
            workingDirectory: workingDirectory,
            autoStart: autoStart,
            autoRestart: autoRestart,
            enabled: enabled
        )
    }

    private static func splitCommandLine(_ commandLine: String) -> (command: String, arguments: String) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return (trimmed, "")
        }

        let command = String(trimmed[..<separator])
        let arguments = String(trimmed[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, arguments)
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
            Button("Delete", role: .destructive, action: onReset)
        }
    }

    private var sourceLabel: String {
        switch agent.source {
        case .global:
            "Global"
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
