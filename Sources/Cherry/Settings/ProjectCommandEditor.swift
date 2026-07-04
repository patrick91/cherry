import AppKit
import SwiftUI

struct ProjectCommandRow: View {
    let command: ProjectCommandDefinition
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.enabled ? "play.circle.fill" : "pause.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(command.enabled ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(command.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(command.enabled ? .primary : .secondary)

                    if !command.enabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(command.commandLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Edit", action: onEdit)
                .settingsGlassButtonStyle()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
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
        storage: ProjectCommandStorage = .local,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (ProjectCommandDefinition, ProjectCommandStorage) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: ProjectCommandDraft(
            command: command,
            projectRoot: projectRoot,
            storage: storage
        ))
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

                        Button("Browse") {
                            chooseWorkingDirectory()
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
            panel.directoryURL = URL(
                fileURLWithPath: draft.definition.resolvedWorkingDirectory(projectRoot: projectRoot),
                isDirectory: true
            )
        } else if !projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
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
    var storage: ProjectCommandStorage
    let projectRoot: String

    init(command: ProjectCommandDefinition, projectRoot: String, storage: ProjectCommandStorage) {
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
