import AppKit
import SwiftUI

struct ProjectSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var settings: AgentSettings

    var body: some View {
        SettingsPaneScroll(page: .projects) {
            SettingsCard("Library") {
                SettingsRow(
                    "\(settings.projects.count) \(settings.projects.count == 1 ? "project" : "projects")",
                    subtitle: "Projects can keep local overrides or share commands and feature flags through cherry.toml."
                ) {
                    Button {
                        chooseProjectRoot()
                    } label: {
                        Label("Add Project", systemImage: "plus")
                    }
                    .settingsProminentGlassButtonStyle()
                }

                if settings.projects.isEmpty {
                    SettingsDivider()
                    SettingsEmptyState(
                        title: "No projects yet",
                        message: "Add a folder to configure project features, commands, and identity colors.",
                        systemImage: "folder.badge.plus"
                    )
                }
            }

            if !settings.projects.isEmpty {
                SettingsCard {
                    ForEach(Array(settings.projects.enumerated()), id: \.element.id) { index, project in
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

                        if index < settings.projects.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
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
        settings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}

struct ProjectDetailSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    let project: CherryProject
    @ObservedObject var settings: AgentSettings

    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    private var commands: [ProjectCommandDefinition] {
        settings.projectCommands(for: project.root)
    }

    var body: some View {
        SettingsPaneScroll(
            title: project.name,
            subtitle: project.root,
            systemImage: "folder.fill"
        ) {
            SettingsCard("Project") {
                SettingsRow("Location", subtitle: project.root) {
                    HStack(spacing: 8) {
                        Button("Open") {
                            openProject()
                        }
                        .settingsProminentGlassButtonStyle()

                        Button("Remove", role: .destructive) {
                            settings.removeProject(project)
                        }
                        .settingsGlassButtonStyle()
                    }
                }
            }

            SettingsCard("Features") {
                ProjectFeatureControls(settings: settings, project: project)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }

            SettingsCard("Browser") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Allow MCP JavaScript",
                        isOn: Binding(
                            get: { settings.isBrowserJavaScriptEnabled(for: project.root) },
                            set: { settings.setBrowserJavaScriptEnabled($0, for: project.root) }
                        )
                    )
                    .toggleStyle(.checkbox)

                    Text("Lets agents run page-world JavaScript in this project's signed-in browser. This trust setting stays local and is never written to cherry.toml.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }

            SettingsCard("Appearance") {
                ProjectAppearanceControls(settings: settings, project: project)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }

            SettingsCard("Commands") {
                if commands.isEmpty {
                    SettingsEmptyState(
                        title: "No commands yet",
                        message: "Create trusted commands for repeatable local workflows.",
                        systemImage: "play.rectangle"
                    )
                } else {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        ProjectCommandRow(command: command) {
                            editingCommand = command
                            editingOriginalName = command.name
                        } onDelete: {
                            settings.removeCommand(named: command.name, for: project.root)
                        }

                        if index < commands.count - 1 {
                            SettingsDivider()
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Add command", subtitle: "Add a reusable command for this project.") {
                    Button {
                        editingCommand = ProjectCommandDefinition(name: "Dev server", command: "npm", arguments: "run dev")
                        editingOriginalName = nil
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .settingsGlassButtonStyle()
                }
            }
        }
        .sheet(item: $editingCommand) { command in
            ProjectCommandEditor(
                command: command,
                projectRoot: project.root,
                storage: settings.commandStorage(named: editingOriginalName ?? command.name, for: project.root),
                canDelete: editingOriginalName != nil,
                errorMessage: commandError,
                onSave: { updatedCommand, storage in
                    do {
                        try settings.upsertCommand(
                            updatedCommand,
                            for: project.root,
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
                    settings.removeCommand(named: command.name, for: project.root)
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

    private func openProject() {
        settings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}

private struct ProjectRow: View {
    let project: CherryProject

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(
                systemImage: "folder.fill",
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(project.root)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private struct ProjectFeatureControls: View {
    @ObservedObject var settings: AgentSettings
    let project: CherryProject

    @State private var errorMessage: String?

    private var features: ProjectFeatureSettings {
        settings.projectFeatures(for: project.root)
    }

    private var hasLocalOverrides: Bool {
        !settings.projectFeatureOverrides(for: project.root).isEmpty
    }

    private var sourceCaption: String? {
        ProjectStorageSource(
            hasLocalOverrides: hasLocalOverrides,
            projectFileConfigures: settings.projectFileConfiguresFeatures(for: project.root)
        ).caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Notes", isOn: featureBinding(\.notesEnabled))
                Toggle("Todos", isOn: featureBinding(\.todosEnabled))

                Spacer()

                if let sourceCaption {
                    Text(sourceCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProjectStorageMenu(
                    hasLocalOverrides: hasLocalOverrides,
                    onSaveToProjectFile: saveToProjectFile,
                    onRevert: { settings.clearLocalProjectFeatureOverrides(for: project.root) }
                )
            }
            .toggleStyle(.checkbox)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func featureBinding(_ keyPath: WritableKeyPath<ProjectFeatureSettings, Bool>) -> Binding<Bool> {
        Binding {
            features[keyPath: keyPath]
        } set: { newValue in
            var next = features
            next[keyPath: keyPath] = newValue
            do {
                try settings.setProjectFeatures(next, for: project.root, storage: .local)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveToProjectFile() {
        do {
            try settings.setProjectFeatures(features, for: project.root, storage: .projectFile)
            settings.clearLocalProjectFeatureOverrides(for: project.root)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProjectAppearanceControls: View {
    @ObservedObject var settings: AgentSettings
    let project: CherryProject

    @State private var errorMessage: String?

    private var appearance: ProjectAppearanceSettings {
        settings.projectAppearance(for: project.root)
    }

    private var hasLocalOverrides: Bool {
        !settings.projectAppearanceOverrides(for: project.root).isEmpty
    }

    private var sourceCaption: String? {
        ProjectStorageSource(
            hasLocalOverrides: hasLocalOverrides,
            projectFileConfigures: settings.projectFileConfiguresAppearance(for: project.root)
        ).caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Color", selection: colorBinding) {
                    Label("None", systemImage: "slash.circle")
                        .tag(Optional<ProjectIdentityColor>.none)

                    ForEach(ProjectIdentityColor.allCases) { color in
                        ProjectColorPickerLabel(color: color)
                            .tag(Optional(color))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()

                if let sourceCaption {
                    Text(sourceCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProjectStorageMenu(
                    hasLocalOverrides: hasLocalOverrides,
                    onSaveToProjectFile: saveToProjectFile,
                    onRevert: { settings.clearLocalProjectAppearanceOverrides(for: project.root) }
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var colorBinding: Binding<ProjectIdentityColor?> {
        Binding {
            appearance.color
        } set: { newColor in
            do {
                try settings.setProjectAppearance(
                    ProjectAppearanceSettings(color: newColor),
                    for: project.root,
                    storage: .local
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveToProjectFile() {
        do {
            try settings.setProjectAppearance(appearance, for: project.root, storage: .projectFile)
            settings.clearLocalProjectAppearanceOverrides(for: project.root)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProjectStorageSource {
    let hasLocalOverrides: Bool
    let projectFileConfigures: Bool

    var caption: String? {
        switch (hasLocalOverrides, projectFileConfigures) {
        case (true, true): "Overriding cherry.toml"
        case (true, false): "Saved locally"
        case (false, true): "From cherry.toml"
        case (false, false): nil
        }
    }
}

private struct ProjectStorageMenu: View {
    let hasLocalOverrides: Bool
    let onSaveToProjectFile: () -> Void
    let onRevert: () -> Void

    var body: some View {
        Menu {
            Button("Save to cherry.toml", action: onSaveToProjectFile)
            Button("Revert to cherry.toml", action: onRevert)
                .disabled(!hasLocalOverrides)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .settingsGlassButtonStyle()
        .fixedSize()
    }
}

private struct ProjectColorPickerLabel: View {
    let color: ProjectIdentityColor

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: NSColor(hexRGB: color.hexRGB) ?? .controlAccentColor))
                .frame(width: 10, height: 10)
            Text(color.label)
        }
    }
}
