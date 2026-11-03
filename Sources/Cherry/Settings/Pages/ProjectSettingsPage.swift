import AppKit
import CherryControl
import SwiftUI

/// A project's page (the Projects section of the sidebar): its
/// folder, its cherry.toml, Todos and Color with where each comes from
/// (this Mac or cherry.toml), its commands, and Revert to cherry.toml… and
/// Remove Project…. Only This Mac's projects have one; Save to cherry.toml
/// is hidden for a project on another Mac all the same, since its
/// cherry.toml is read-only here.
struct ProjectSettingsPage: View, SettingsPageContent {
    let projectRoot: String
    @ObservedObject private var settings: AgentSettings
    private let homeDirectory: String

    @Environment(\.settingsActions) private var actions
    /// The command the editor sheet shows (an empty one for Add Command…);
    /// nil while it is closed.
    @State private var editingCommand: ProjectCommandDefinition?
    /// The name the edited command is stored under; nil while adding one.
    @State private var editingOriginalName: String?
    @State private var editorError: String?
    @State private var todosError: String?
    @State private var colorError: String?
    @State private var commandsError: String?
    @State private var confirmation: SettingsConfirmation?

    init(projectRoot: String, settings: AgentSettings = .shared, homeDirectory: String = NSHomeDirectory()) {
        self.projectRoot = projectRoot
        self.settings = settings
        self.homeDirectory = homeDirectory
    }

    private var isRemote: Bool {
        ProjectLocation.isRemoteKey(projectRoot)
    }

    var body: some View {
        let project = CherryProject(root: projectRoot)
        SettingsPageScroll(project.name) {
            header(project)
            projectFileSection
            featuresSection
            appearanceSection
            commandsSection
            footer(project)
        }
        .settingsConfirmation($confirmation)
        .sheet(item: $editingCommand) { command in
            editor(command)
        }
    }

    // MARK: Header

    private func header(_ project: CherryProject) -> some View {
        SettingsPageHeader(
            tile: SettingsTile(
                .project(color: settings.projectAppearance(for: projectRoot).color),
                size: .extraLarge
            ),
            title: project.name,
            subtitle: ProjectSwitcherModel.displayPath(projectRoot, home: homeDirectory),
            monospacedSubtitle: true
        ) {
            Button("Open Window") {
                actions.openProjectWindow(projectRoot)
            }
            .settingsButton(.primary)

            if !isRemote {
                Button("Reveal in Finder") {
                    actions.revealInFinder([URL(fileURLWithPath: projectRoot, isDirectory: true)])
                }
                .settingsButton()
            }
        }
    }

    // MARK: Project

    private var projectFileSection: some View {
        let exists = CherryProjectFile.exists(projectRoot: projectRoot)
        return SettingsSection("Project") {
            SettingsItem(
                id: .projectFile(projectRoot),
                "cherry.toml",
                help: ProjectSettingsContent.projectFileHelp(exists: exists)
            ) {
                if exists, !isRemote {
                    Button("Open") {
                        actions.openTextFile(CherryProjectFile.fileURL(projectRoot: projectRoot))
                    }
                    .settingsButton()
                }
            }
        }
    }

    // MARK: Features

    private var featuresSection: some View {
        let source = ProjectSettingsContent.todosState(root: projectRoot, settings: settings) { todosError = $0 }
        return SettingsSection("Features") {
            SettingsItem(
                id: .projectTodos(projectRoot),
                "Todos",
                help: ProjectSettingsContent.todosHelp,
                source: source
            ) {
                Toggle("Todos", isOn: Binding(
                    get: { settings.projectFeatures(for: projectRoot).todosEnabled },
                    set: { enabled in
                        todosError = ProjectSettingsContent.errorMessage {
                            try ProjectSettingsContent.setTodos(enabled, root: projectRoot, settings: settings)
                        }
                    }
                ))
                .settingsSwitch()
            } detail: {
                if let todosError {
                    SettingsNote(todosError, style: .error)
                }
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        let source = ProjectSettingsContent.colorState(root: projectRoot, settings: settings) { colorError = $0 }
        return SettingsSection("Appearance") {
            SettingsItem(
                id: .projectColor(projectRoot),
                "Color",
                help: ProjectSettingsContent.colorHelp,
                source: source
            ) {
                ProjectSettingsContent.ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { settings.projectAppearance(for: projectRoot).color },
                        set: { color in
                            colorError = ProjectSettingsContent.errorMessage {
                                try ProjectSettingsContent.setColor(color, root: projectRoot, settings: settings)
                            }
                        }
                    ),
                    swatches: ProjectSettingsContent.colorSwatches,
                    leading: ProjectSettingsContent.ColorPicker.Leading("None", value: nil)
                )
            } detail: {
                if let colorError {
                    SettingsNote(colorError, style: .error)
                }
            }
        }
    }

    // MARK: Commands

    private var commandsSection: some View {
        let commands = settings.projectCommands(for: projectRoot)
        return Group {
            SettingsSection(
                "Commands",
                caption: commands.isEmpty ? nil : ProjectSettingsContent.commandsCaption,
                id: .projectCommands(projectRoot)
            ) {
                SettingsLinkButton("+ Add Command…", action: addCommand)
            } content: {
                if commands.isEmpty {
                    SettingsEmptyState(
                        title: "No commands yet",
                        message: ProjectSettingsContent.commandsHelp,
                        systemImage: "play.rectangle"
                    ) {
                        Button("Add Command…", action: addCommand)
                            .settingsButton()
                    }
                } else {
                    ForEach(commands) { command in
                        commandItem(command)
                    }
                }
            }
            if let commandsError {
                SettingsNote(commandsError, style: .error)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func commandItem(_ command: ProjectCommandDefinition) -> some View {
        let source = ProjectSettingsContent.commandState(command, root: projectRoot, settings: settings) {
            commandsError = $0
        }
        return SettingsListItem(id: .projectCommand(projectRoot, named: command.name)) {
            HStack(spacing: 10) {
                Image(systemName: command.enabled ? "play.circle.fill" : "pause.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(command.enabled ? Color.accentColor : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                SettingsListLabel(
                    command.name,
                    subtitle: command.commandLine.isEmpty ? nil : command.commandLine,
                    monospacedSubtitle: true
                ) {
                    ForEach(ProjectSettingsContent.commandTags(command), id: \.self) { tag in
                        SettingsTag(tag)
                    }
                    SettingsSourceBadge(state: source, title: command.name)
                    SettingsResetButton(state: source)
                }
            }
        } trailing: {
            Button("Edit…") {
                edit(command)
            }
            .settingsButton(size: .small)

            SettingsMoreMenu("More actions for \(command.name)") {
                Button("Delete…", role: .destructive) {
                    askToDelete(command)
                }
            }
        }
    }

    /// Add Command…: the editor, empty.
    private func addCommand() {
        editorError = nil
        editingOriginalName = nil
        editingCommand = ProjectSettingsContent.newCommand
    }

    private func edit(_ command: ProjectCommandDefinition) {
        editorError = nil
        editingOriginalName = command.name
        editingCommand = command
    }

    /// A command's Delete…: it asks first, as the editor's does.
    private func askToDelete(_ command: ProjectCommandDefinition) {
        let root = projectRoot
        let settings = settings
        confirmation = ProjectCommandEditor.deleteConfirmation(
            commandName: command.name,
            inProjectFile: ProjectCommandEditor.projectFileHasCommand(named: command.name, projectRoot: root)
        ) {
            settings.removeCommand(named: command.name, for: root)
        }
    }

    private func editor(_ command: ProjectCommandDefinition) -> some View {
        ProjectCommandEditor(
            command: command,
            projectRoot: projectRoot,
            storage: settings.commandStorage(named: editingOriginalName ?? command.name, for: projectRoot),
            canDelete: editingOriginalName != nil,
            errorMessage: editorError,
            onSave: { updatedCommand, storage in
                do {
                    try settings.upsertCommand(
                        updatedCommand,
                        for: projectRoot,
                        replacing: editingOriginalName,
                        storage: storage
                    )
                    closeEditor()
                } catch {
                    editorError = error.localizedDescription
                }
            },
            onDelete: {
                settings.removeCommand(named: editingOriginalName ?? command.name, for: projectRoot)
                closeEditor()
            },
            onCancel: closeEditor
        )
    }

    private func closeEditor() {
        editorError = nil
        editingOriginalName = nil
        editingCommand = nil
    }

    // MARK: Footer

    private func footer(_ project: CherryProject) -> some View {
        let changes = ProjectSettingsContent.revertChanges(root: projectRoot, settings: settings)
        return SettingsPageFooter(caption: ProjectSettingsContent.footerCaption) {
            Button("Revert to cherry.toml…") {
                let root = projectRoot
                let settings = settings
                confirmation = ProjectSettingsContent.revertConfirmation(projectName: project.name, changes: changes) {
                    settings.revertProjectToProjectFile(root)
                }
            }
            .settingsButton()
            .disabled(changes.isEmpty)

            Button("Remove Project…", role: .destructive) {
                ProjectRemoval.remove(project, settings: settings)
            }
            .settingsButton(.danger)
        }
    }

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let agents = context.agents
        let commandWords = ["command", "run", "dev server", "auto-start"]
        return SettingsProjectOrdering.listed(agents.projects).flatMap { project in
            let root = project.root
            let route = SettingsRoute.project(root)
            let commands = agents.projectCommands(for: root)
            let rows = [
                SettingsSearchRow(
                    id: .projectTodos(root),
                    route: route,
                    section: "Features",
                    title: "Todos",
                    help: ProjectSettingsContent.todosHelp,
                    keywords: ["todo", "to-do", "tasks"],
                    value: SettingSource.onOff(agents.projectFeatures(for: root).todosEnabled)
                ),
                SettingsSearchRow(
                    id: .projectColor(root),
                    route: route,
                    section: "Appearance",
                    title: "Color",
                    help: ProjectSettingsContent.colorHelp,
                    keywords: ["color", "colour", "tint", "accent", "identity"],
                    value: ProjectSettingsContent.colorName(agents.projectAppearance(for: root).color)
                ),
                SettingsSearchRow(
                    id: .projectCommands(root),
                    route: route,
                    section: "Commands",
                    title: "Commands",
                    help: ProjectSettingsContent.commandsHelp,
                    keywords: commandWords,
                    value: commands.count == 1 ? "1 command" : "\(commands.count) commands"
                ),
            ]
            return rows + commands.map { command in
                SettingsSearchRow(
                    id: .projectCommand(root, named: command.name),
                    route: route,
                    section: "Commands",
                    title: command.name,
                    keywords: commandWords,
                    value: command.commandLine
                )
            }
        }
    }
}

extension SettingsRowID {
    /// A project page's cherry.toml row.
    static func projectFile(_ root: String) -> Self {
        .project(root, "projectFile")
    }

    static func projectTodos(_ root: String) -> Self {
        .project(root, "todos")
    }

    static func projectColor(_ root: String) -> Self {
        .project(root, "color")
    }

    /// The Commands section.
    static func projectCommands(_ root: String) -> Self {
        .project(root, "commands")
    }

    /// One command's row: "project.<root>.command.Dev server".
    static func projectCommand(_ root: String, named name: String) -> Self {
        .project(root, "command.\(name)")
    }
}

// MARK: - Content

/// What a project's page shows and does, apart from its views: its texts,
/// the badges of Todos, Color and each command with their popovers' Revert
/// and Save to cherry.toml, the writes, Revert to cherry.toml…'s question
/// and the commands' tags. A change made here is this Mac's value, except
/// that a value equal to what applies without it (cherry.toml's, else
/// Cherry's default) drops this Mac's value instead of pinning it, so a
/// switch flipped and flipped back leaves no badge.
@MainActor
enum ProjectSettingsContent {
    typealias ColorPicker = SettingsSwatchPicker<ProjectIdentityColor?>

    static let todosHelp = "Adds a to-do list to this project's windows."
    static let colorHelp = "Marks this project's windows and tabs."
    /// The Commands empty state's sentence, also the section's help in
    /// search.
    static let commandsHelp = "Commands run in their own tabs: dev servers, watchers, logs."
    static let commandsCaption = "Add Command… opens the editor empty. Delete… is in each command's menu and asks first."
    static let footerCaption = "Revert drops this Mac's Todos and Color overrides. Commands keep theirs."

    /// The cherry.toml row's help.
    static func projectFileHelp(exists: Bool) -> String {
        exists
            ? "In this folder. Shared with everyone who opens it."
            : "None yet: Cherry creates one when you save a value to it."
    }

    /// What Add Command… opens the editor with: nothing filled in, and on.
    static var newCommand: ProjectCommandDefinition {
        ProjectCommandDefinition(name: "", command: "")
    }

    /// Whether a value can be saved to the project's cherry.toml: not for a
    /// project on another Mac, whose cherry.toml is read-only here.
    static func canSaveToProjectFile(root: String) -> Bool {
        !ProjectLocation.isRemoteKey(root)
    }

    /// The Color row's swatches: the ten project colors, after None.
    static var colorSwatches: [ColorPicker.Swatch] {
        ProjectIdentityColor.allCases.map { color in
            ColorPicker.Swatch(color, name: color.label, color: SettingsDesign.Colors.hex(color.hexRGB))
        }
    }

    // MARK: Todos

    /// The Todos row's badge: Revert goes back to cherry.toml's value (or
    /// off), Save to cherry.toml writes this Mac's into the file. `report`
    /// gets a failed save's message, nil after a revert.
    static func todosState(
        root: String,
        settings: AgentSettings,
        report: @escaping @MainActor (String?) -> Void
    ) -> SettingsSourceState {
        var save: (@MainActor () -> Void)?
        if canSaveToProjectFile(root: root) {
            save = { report(errorMessage { try saveTodosToProjectFile(root: root, settings: settings) }) }
        }
        return .project(
            source: settings.todosSource(for: root),
            fileValue: fileFeatures(root: root, settings: settings).map { SettingSource.onOff($0.todosEnabled) },
            thisMacValue: settings.projectFeatureOverrides(for: root).todosEnabled.map(SettingSource.onOff),
            defaultValue: SettingSource.onOff(ProjectFeatureSettings.disabled.todosEnabled),
            revert: {
                settings.clearLocalProjectFeatureOverrides(for: root)
                report(nil)
            },
            saveToFile: save
        )
    }

    /// The Todos switch: this Mac's value, or none when `enabled` is what
    /// applies without one.
    static func setTodos(_ enabled: Bool, root: String, settings: AgentSettings) throws {
        let withoutThisMac = fileFeatures(root: root, settings: settings)?.todosEnabled
            ?? ProjectFeatureSettings.disabled.todosEnabled
        guard enabled != withoutThisMac else {
            if !settings.projectFeatureOverrides(for: root).isEmpty {
                settings.clearLocalProjectFeatureOverrides(for: root)
            }
            return
        }
        try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: enabled), for: root, storage: .local)
    }

    /// Save to cherry.toml: this Mac's Todos goes into the file, and this
    /// Mac's value goes.
    static func saveTodosToProjectFile(root: String, settings: AgentSettings) throws {
        try settings.setProjectFeatures(settings.projectFeatures(for: root), for: root, storage: .projectFile)
        settings.clearLocalProjectFeatureOverrides(for: root)
    }

    // MARK: Color

    /// The Color row's badge: Revert goes back to cherry.toml's color (or
    /// None), "Revert to cherry.toml (Green)"; Save to cherry.toml writes
    /// this Mac's into the file. `report` gets a failed save's message, nil
    /// after a revert.
    static func colorState(
        root: String,
        settings: AgentSettings,
        report: @escaping @MainActor (String?) -> Void
    ) -> SettingsSourceState {
        var save: (@MainActor () -> Void)?
        if canSaveToProjectFile(root: root) {
            save = { report(errorMessage { try saveColorToProjectFile(root: root, settings: settings) }) }
        }
        return .project(
            source: settings.colorSource(for: root),
            fileValue: fileAppearance(root: root, settings: settings).map { colorName($0.color) },
            thisMacValue: settings.projectAppearanceOverrides(for: root).color.map { colorName($0) },
            defaultValue: colorName(ProjectAppearanceSettings.none.color),
            revert: {
                settings.clearLocalProjectAppearanceOverrides(for: root)
                report(nil)
            },
            saveToFile: save
        )
    }

    /// A swatch (or None): this Mac's color, or none when `color` is what
    /// applies without one.
    static func setColor(_ color: ProjectIdentityColor?, root: String, settings: AgentSettings) throws {
        let withoutThisMac = fileAppearance(root: root, settings: settings)?.color ?? ProjectAppearanceSettings.none.color
        guard color != withoutThisMac else {
            if !settings.projectAppearanceOverrides(for: root).isEmpty {
                settings.clearLocalProjectAppearanceOverrides(for: root)
            }
            return
        }
        try settings.setProjectAppearance(ProjectAppearanceSettings(color: color), for: root, storage: .local)
    }

    /// Save to cherry.toml: this Mac's color goes into the file, and this
    /// Mac's value goes.
    static func saveColorToProjectFile(root: String, settings: AgentSettings) throws {
        try settings.setProjectAppearance(settings.projectAppearance(for: root), for: root, storage: .projectFile)
        settings.clearLocalProjectAppearanceOverrides(for: root)
    }

    // MARK: Commands

    /// The tags after a command's name: "Auto-start", "Restarts",
    /// "Disabled".
    static func commandTags(_ command: ProjectCommandDefinition) -> [String] {
        var tags: [String] = []
        if command.autoStart { tags.append("Auto-start") }
        if command.autoRestart { tags.append("Restarts") }
        if !command.enabled { tags.append("Disabled") }
        return tags
    }

    /// A command's badge (`AgentSettings.commandSource`): cherry.toml, This
    /// Mac only, or Overrides cherry.toml with ↺ "Revert <name> to
    /// cherry.toml", which drops this Mac's copy (`removeLocalCommand`).
    /// Save to cherry.toml writes this Mac's copy into the file. A command
    /// only this Mac has has no reset: that would delete it, and Delete…,
    /// in its row's menu, asks first. `report` gets a failed save's
    /// message, nil after a revert.
    static func commandState(
        _ command: ProjectCommandDefinition,
        root: String,
        settings: AgentSettings,
        report: @escaping @MainActor (String?) -> Void
    ) -> SettingsSourceState {
        let source = settings.commandSource(named: command.name, for: root)
        let isThisMacs = source == .overridesProjectFile || source == .thisMacOnly
        // The checkout's own cherry.toml, where `commandSource` and
        // `projectCommands` read commands (Todos and Color are the
        // project's, through `repositoryRoot`).
        let fileCommand = AgentSettings.validDirectory(root).flatMap { checkoutRoot in
            CherryProjectFile.loadCommands(projectRoot: checkoutRoot).first { $0.normalizedName == command.normalizedName }
        }
        let name = command.name
        var save: (@MainActor () -> Void)?
        if isThisMacs, canSaveToProjectFile(root: root) {
            save = {
                report(errorMessage { try settings.upsertCommand(command, for: root, storage: .projectFile) })
            }
        }
        var state = SettingsSourceState.project(
            source: source,
            fileValue: fileCommand?.commandLine,
            thisMacValue: isThisMacs ? command.commandLine : nil,
            revertTitle: "Revert \(name) to cherry.toml",
            revert: {
                settings.removeLocalCommand(named: name, for: root)
                report(nil)
            },
            saveToFile: save
        )
        if source == .thisMacOnly {
            state.buttons = save.map { [SettingsAction("Save to cherry.toml", perform: $0)] } ?? []
        }
        return state
    }

    // MARK: Revert to cherry.toml…

    /// What Revert to cherry.toml… drops: this Mac's Todos and Color, each
    /// back to cherry.toml's value, else the default. Empty: nothing to
    /// revert, and the button is off.
    static func revertChanges(root: String, settings: AgentSettings) -> [SettingsChange] {
        var changes: [SettingsChange] = []
        if let thisMac = settings.projectFeatureOverrides(for: root).todosEnabled {
            let restored = fileFeatures(root: root, settings: settings)?.todosEnabled
                ?? ProjectFeatureSettings.disabled.todosEnabled
            changes.append(SettingsChange(title: "Todos", from: SettingSource.onOff(thisMac), to: SettingSource.onOff(restored)))
        }
        if let thisMac = settings.projectAppearanceOverrides(for: root).color {
            let restored = fileAppearance(root: root, settings: settings)?.color ?? ProjectAppearanceSettings.none.color
            changes.append(SettingsChange(title: "Color", from: colorName(thisMac), to: colorName(restored)))
        }
        return changes
    }

    /// Revert to cherry.toml…'s question: "Revert “cherry” to cherry.toml?",
    /// what changes ("Todos On → Off · Color Blue → Green."), and that the
    /// commands keep theirs; Revert (the default) and Cancel.
    static func revertConfirmation(
        projectName: String,
        changes: [SettingsChange],
        revert: @escaping @MainActor () -> Void
    ) -> SettingsConfirmation {
        let listed = changes.map(\.text).joined(separator: " · ")
        return SettingsConfirmation(
            title: "Revert “\(projectName)” to cherry.toml?",
            message: (listed.isEmpty ? "" : listed + ". ") + "Commands keep their own overrides.",
            choices: [
                SettingsConfirmation.Choice("Revert", isDefault: true, perform: revert),
                .cancel(),
            ]
        )
    }

    // MARK: Values

    /// A color as rows say it: "Green", "None".
    static func colorName(_ color: ProjectIdentityColor?) -> String {
        color?.label ?? "None"
    }

    /// Runs a write; its error's message, nil when it worked.
    static func errorMessage(_ write: () throws -> Void) -> String? {
        do {
            try write()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// What the project's cherry.toml says of its features; nil when it has
    /// no `[features]`.
    private static func fileFeatures(root: String, settings: AgentSettings) -> ProjectFeatureSettings? {
        settings.repositoryRoot(for: root).flatMap { CherryProjectFile.loadFeatureSettings(projectRoot: $0) }
    }

    /// What the project's cherry.toml says of its appearance; nil when it
    /// has no `[appearance]`.
    private static func fileAppearance(root: String, settings: AgentSettings) -> ProjectAppearanceSettings? {
        settings.repositoryRoot(for: root).flatMap { CherryProjectFile.loadAppearanceSettings(projectRoot: $0) }
    }
}
