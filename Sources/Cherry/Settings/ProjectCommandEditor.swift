import CherryControl
import AppKit
import SwiftUI

/// The sheet that adds a project's command (Settings' Add Command…, the
/// project window's) or edits one: its name, command line, working
/// directory, environment, whether it is on and starts and restarts by
/// itself, and where it is saved (the project's cherry.toml or this Mac).
/// Delete… (only while editing) asks first, wherever the sheet is. Saving
/// and deleting are the caller's (`onSave`, `onDelete`); `errorMessage`
/// says why a save failed.
struct ProjectCommandEditor: View {
    static let enabledLabel = "Enabled"
    static let enabledHelp = "Off hides it from the project's windows and never starts it."
    static let projectFileOption = "Save to cherry.toml"
    static let thisMacOption = "This Mac only"
    static let thisMacOptionSubtitle = "Kept by Cherry on this Mac"

    @State private var draft: ProjectCommandDraft
    @State private var confirmation: SettingsConfirmation?
    /// The name the command is stored under, which Delete… names.
    private let storedName: String

    let projectRoot: String
    let canDelete: Bool
    let errorMessage: String?
    let onSave: (ProjectCommandDefinition, ProjectSettingStorage) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        command: ProjectCommandDefinition,
        projectRoot: String,
        storage: ProjectSettingStorage = .local,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (ProjectCommandDefinition, ProjectSettingStorage) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: ProjectCommandDraft(
            command: command,
            projectRoot: projectRoot,
            // A device project's commands are saved on this Mac only.
            storage: ProjectLocation.isRemoteKey(projectRoot) ? .local : storage
        ))
        storedName = command.name
        self.projectRoot = projectRoot
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    /// "Add Command" while adding (no Delete…), else "Edit Command".
    static func title(canDelete: Bool) -> String {
        canDelete ? "Edit Command" : "Add Command"
    }

    /// Save to cherry.toml's line under it.
    static func projectFileOptionSubtitle(fileExists: Bool) -> String {
        fileExists ? "Shared with everyone who opens this folder" : "No cherry.toml yet: Cherry creates one"
    }

    /// What Delete… asks first (Settings' row menu asks the same): the
    /// command's definition goes, from cherry.toml too when the file has it
    /// (`AgentSettings.removeCommand`).
    static func deleteConfirmation(
        commandName: String,
        inProjectFile: Bool,
        delete: @escaping @MainActor () -> Void
    ) -> SettingsConfirmation {
        SettingsConfirmation(
            title: "Delete the command “\(commandName)”?",
            message: inProjectFile ? "It's removed from cherry.toml." : nil,
            choices: [
                SettingsConfirmation.Choice("Delete", role: .destructive, perform: delete),
                .cancel(),
            ]
        )
    }

    /// Whether deleting the command named `name` removes it from the
    /// project's cherry.toml too: never for a project on another Mac, whose
    /// cherry.toml is read-only here.
    @MainActor
    static func projectFileHasCommand(named name: String, projectRoot: String) -> Bool {
        guard !ProjectLocation.isRemoteKey(projectRoot), let root = AgentSettings.validDirectory(projectRoot) else {
            return false
        }
        let normalizedName = AgentToolDefinition.normalizedName(name)
        return CherryProjectFile.loadCommands(projectRoot: root).contains { $0.normalizedName == normalizedName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(Self.title(canDelete: canDelete))
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

                    if let extraction = pendingEnvironmentExtraction {
                        HStack(spacing: 8) {
                            Text(environmentSuggestionText(for: extraction))
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Button("Move to Environment Variables") {
                                draft.commandLine = extraction.commandLine
                                draft.mergeEnvironment(extraction.environment)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Working directory")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("e.g., ., web, packages/api", text: $draft.workingDirectory)

                        // Not for a folder on another Mac.
                        if !ProjectLocation.isRemoteKey(projectRoot) {
                            Button("Browse") {
                                chooseWorkingDirectory()
                            }
                        }
                    }

                    Text("Leave empty to use project root. Relative paths resolve from the project root.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                environmentSection

                VStack(alignment: .leading, spacing: 8) {
                    Text("Behavior")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(Self.enabledLabel, isOn: $draft.enabled)
                        Text(Self.enabledHelp)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Auto-start when project starts", isOn: $draft.autoStart)
                    Toggle("Auto-restart if command exits", isOn: $draft.autoRestart)
                }
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Where to save this command")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                if ProjectLocation.isRemoteKey(projectRoot) {
                    // A device's cherry.toml is read there, never written
                    // from here (docs/specs/remote-devices.md, phase 3).
                    Text(CherryProjectFile.remoteReadOnlyNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProjectCommandStorageOption(
                        title: Self.projectFileOption,
                        subtitle: Self.projectFileOptionSubtitle(
                            fileExists: CherryProjectFile.exists(projectRoot: projectRoot)
                        ),
                        isSelected: draft.storage == .projectFile
                    ) {
                        draft.storage = .projectFile
                    }
                }

                ProjectCommandStorageOption(
                    title: Self.thisMacOption,
                    subtitle: Self.thisMacOptionSubtitle,
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
                    Button("Delete…", role: .destructive) {
                        confirmation = Self.deleteConfirmation(
                            commandName: storedName,
                            inProjectFile: Self.projectFileHasCommand(named: storedName, projectRoot: projectRoot),
                            delete: onDelete
                        )
                    }
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft.definition, draft.storage)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .settingsConfirmation($confirmation)
    }

    private func chooseWorkingDirectory() {
        let directoryURL: URL? = if !draft.workingDirectory.isEmpty {
            URL(
                fileURLWithPath: draft.definition.resolvedWorkingDirectory(projectRoot: projectRoot),
                isDirectory: true
            )
        } else if !projectRoot.isEmpty {
            URL(fileURLWithPath: projectRoot, isDirectory: true)
        } else {
            nil
        }

        guard let url = NSOpenPanel.chooseFolder(prompt: "Choose", directoryURL: directoryURL) else { return }
        draft.workingDirectory = ProjectCommandDefinition.portableWorkingDirectory(url.path, projectRoot: projectRoot)
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment variables")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    draft.addEnvironmentRow()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            if !draft.environmentRows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Color.clear
                            .frame(width: 24)
                    }

                    ForEach($draft.environmentRows) { $row in
                        GridRow {
                            TextField("NAME", text: $row.name)
                                .textFieldStyle(.roundedBorder)
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                draft.removeEnvironmentRow(id: row.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove variable")
                        }
                    }
                }
            }
        }
    }

    private var pendingEnvironmentExtraction: ProjectCommandEnvironmentExtraction? {
        ProjectCommandEnvironmentExtraction.extractLeadingAssignments(from: draft.commandLine)
    }

    private func environmentSuggestionText(for extraction: ProjectCommandEnvironmentExtraction) -> String {
        let names = extraction.environment.keys.sorted().joined(separator: ", ")
        return extraction.environment.count == 1
            ? "\(names) looks like an environment variable."
            : "\(names) look like environment variables."
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
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
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
    var environmentRows: [ProjectCommandEnvironmentVariableDraft]
    var autoStart: Bool
    var autoRestart: Bool
    var enabled: Bool
    var storage: ProjectSettingStorage
    let projectRoot: String

    init(command: ProjectCommandDefinition, projectRoot: String, storage: ProjectSettingStorage) {
        name = command.name
        commandLine = command.commandLine
        workingDirectory = ProjectCommandDefinition.portableWorkingDirectory(
            command.workingDirectory,
            projectRoot: projectRoot
        )
        environmentRows = command.environment
            .keys
            .sorted()
            .compactMap { name in
                command.environment[name].map {
                    ProjectCommandEnvironmentVariableDraft(name: name, value: $0)
                }
            }
        autoStart = command.autoStart
        autoRestart = command.autoRestart
        enabled = command.enabled
        self.storage = storage
        self.projectRoot = projectRoot
    }

    var definition: ProjectCommandDefinition {
        let parts = Self.splitCommandLine(commandLine)
        return ProjectCommandDefinition(
            name: name,
            command: parts.command,
            arguments: parts.arguments,
            workingDirectory: ProjectCommandDefinition.portableWorkingDirectory(
                workingDirectory,
                projectRoot: projectRoot
            ),
            environment: environment,
            autoStart: autoStart,
            autoRestart: autoRestart,
            enabled: enabled
        )
    }

    private var environment: [String: String] {
        var environment: [String: String] = [:]
        for row in environmentRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ProjectCommandEnvironmentExtraction.isValidEnvironmentName(name) else { continue }
            environment[name] = row.value
        }
        return environment
    }

    mutating func addEnvironmentRow() {
        environmentRows.append(ProjectCommandEnvironmentVariableDraft(name: "", value: ""))
    }

    mutating func removeEnvironmentRow(id: UUID) {
        environmentRows.removeAll { $0.id == id }
    }

    mutating func mergeEnvironment(_ nextEnvironment: [String: String]) {
        for name in nextEnvironment.keys.sorted() {
            guard let value = nextEnvironment[name] else { continue }
            if let index = environmentRows.firstIndex(where: { $0.name == name }) {
                environmentRows[index].value = value
            } else {
                environmentRows.append(ProjectCommandEnvironmentVariableDraft(name: name, value: value))
            }
        }
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

private struct ProjectCommandEnvironmentVariableDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}
