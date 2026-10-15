import CherryControl
import Foundation
import Testing
@testable import Cherry

// A project's page in Settings (ProjectSettingsPage.swift) and the command
// editor (ProjectCommandEditor.swift): where Todos, Color and each command
// come from (this Mac or the project's cherry.toml), their popovers'
// Revert and Save to cherry.toml, a value equal to what applies without
// this Mac's dropping this Mac's, Revert to cherry.toml…, the
// cherry.toml row, Add Command…, Delete…'s question, and what search
// finds. Private defaults and temporary project folders only.

/// A temporary project folder named "cherry"; remove its parent when the
/// test ends.
private func temporaryProject() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SettingsWindowProjectPage-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("cherry", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeProject(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
}

private func writeProjectFile(_ contents: String, in directory: URL) throws {
    try contents.write(to: directory.appendingPathComponent("cherry.toml"), atomically: true, encoding: .utf8)
}

private func projectFileContents(_ directory: URL) throws -> String {
    try String(contentsOf: directory.appendingPathComponent("cherry.toml"), encoding: .utf8)
}

/// What a badge's popover reports: the messages of failed saves, nil
/// after a revert or a save that worked.
@MainActor
private final class Reports {
    var messages: [String?] = []

    func record(_ message: String?) {
        messages.append(message)
    }
}

@Test @MainActor func projectPageTodosBadgeSaysWhereItsValueComesFrom() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    let reports = Reports()
    func state() -> SettingsSourceState {
        ProjectSettingsContent.todosState(root: root, settings: settings, report: reports.record)
    }

    // Neither sets it: no badge, Cherry's default in use.
    var source = state()
    #expect(source.badgeText == nil)
    #expect(source.lines == [
        .init("This Mac", detail: "Not set"),
        .init("cherry.toml", detail: "Says nothing about it"),
        .init("Cherry default", value: "Off", isInUse: true),
    ])

    // This Mac only: Save to cherry.toml or back to the default; no ↺.
    try ProjectSettingsContent.setTodos(true, root: root, settings: settings)
    source = state()
    #expect(source.badgeText == "This Mac only")
    #expect(source.buttons.map(\.title) == ["Save to cherry.toml", "Reset to default (Off)"])
    #expect(source.rowReset == nil)

    // cherry.toml turns it off: this Mac's On overrides it, and ↺ goes back.
    try writeProjectFile("[features]\ntodos = false\n", in: directory)
    source = state()
    #expect(source.badgeText == "Overrides cherry.toml")
    #expect(source.lines.prefix(2) == [
        .init("This Mac", value: "On", isInUse: true),
        .init("cherry.toml", value: "Off"),
    ])
    #expect(source.buttons.map(\.title) == ["Revert to cherry.toml (Off)", "Save to cherry.toml"])
    #expect(source.rowReset?.title == "Revert to cherry.toml (Off)")
    source.rowReset?.perform()
    #expect(settings.todosSource(for: root) == .projectFile)
    #expect(!settings.projectFeatures(for: root).todosEnabled)
    #expect(reports.messages == [nil])

    // cherry.toml alone: its badge, nothing to revert or save.
    source = state()
    #expect(source.badgeText == "cherry.toml")
    #expect(source.buttons.isEmpty)
    #expect(source.rowReset == nil)
}

@Test @MainActor func projectPageColorRevertsToCherryTomlsColorAndSavesThisMacsIntoTheFile() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try writeProjectFile("[appearance]\ncolor = \"green\"\n", in: directory)
    let reports = Reports()
    func state() -> SettingsSourceState {
        ProjectSettingsContent.colorState(root: root, settings: settings, report: reports.record)
    }
    #expect(state().badgeText == "cherry.toml")

    try ProjectSettingsContent.setColor(.blue, root: root, settings: settings)
    let source = state()
    #expect(source.badgeText == "Overrides cherry.toml")
    #expect(source.rowReset?.title == "Revert to cherry.toml (Green)")
    #expect(source.lines == [
        .init("This Mac", value: "Blue", isInUse: true),
        .init("cherry.toml", value: "Green"),
        .init("Cherry default", value: "None"),
    ])
    #expect(source.note == "Save to cherry.toml writes Blue into the file and drops the override.")

    let save = try #require(source.buttons.first { $0.title == "Save to cherry.toml" })
    save.perform()
    #expect(settings.colorSource(for: root) == .projectFile)
    #expect(settings.projectAppearance(for: root).color == .blue)
    #expect(try projectFileContents(directory).contains("color = \"blue\""))
    #expect(reports.messages == [nil])

    // Revert of a color only this Mac has goes back to None.
    try FileManager.default.removeItem(at: directory.appendingPathComponent("cherry.toml"))
    try ProjectSettingsContent.setColor(.pink, root: root, settings: settings)
    let thisMacOnly = state()
    #expect(thisMacOnly.badgeText == "This Mac only")
    #expect(thisMacOnly.buttons.map(\.title) == ["Save to cherry.toml", "Reset to default (None)"])
    thisMacOnly.buttons.last?.perform()
    #expect(settings.colorSource(for: root) == ProjectValueSource.none)
    #expect(settings.projectAppearance(for: root).color == nil)
}

@Test @MainActor func projectPageSaveToCherryTomlThatFailsReportsWhyAndKeepsThisMacsValue() throws {
    let directory = try temporaryProject()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        removeProject(directory)
    }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try ProjectSettingsContent.setTodos(true, root: root, settings: settings)
    try ProjectSettingsContent.setColor(.teal, root: root, settings: settings)
    // A folder Cherry cannot write in: cherry.toml cannot be made.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let reports = Reports()

    let todos = ProjectSettingsContent.todosState(root: root, settings: settings, report: reports.record)
    try #require(todos.buttons.first { $0.title == "Save to cherry.toml" }).perform()
    let color = ProjectSettingsContent.colorState(root: root, settings: settings, report: reports.record)
    try #require(color.buttons.first { $0.title == "Save to cherry.toml" }).perform()

    #expect(reports.messages.count == 2)
    #expect(reports.messages.allSatisfy { $0?.isEmpty == false })
    #expect(settings.todosSource(for: root) == .thisMacOnly)
    #expect(settings.projectFeatures(for: root).todosEnabled)
    #expect(settings.colorSource(for: root) == .thisMacOnly)
    #expect(settings.projectAppearance(for: root).color == .teal)
    #expect(!CherryProjectFile.exists(projectRoot: root))
}

@Test @MainActor func projectPageHidesSaveToCherryTomlForAProjectOnAnotherMac() throws {
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = ProjectLocation.remote(deviceID: UUID(), path: "/Users/someone/code/api").key
    #expect(!ProjectSettingsContent.canSaveToProjectFile(root: root))
    #expect(ProjectSettingsContent.canSaveToProjectFile(root: "/Users/someone/code/api"))

    try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: true), for: root, storage: .local)
    try settings.setProjectAppearance(ProjectAppearanceSettings(color: .teal), for: root, storage: .local)
    try settings.upsertCommand(ProjectCommandDefinition(name: "Logs", command: "tail"), for: root, storage: .local)

    let todos = ProjectSettingsContent.todosState(root: root, settings: settings) { _ in }
    #expect(todos.badgeText == "This Mac only")
    #expect(todos.buttons.map(\.title) == ["Reset to default (Off)"])
    #expect(todos.note == nil)
    let color = ProjectSettingsContent.colorState(root: root, settings: settings) { _ in }
    #expect(color.buttons.map(\.title) == ["Reset to default (None)"])
    let logs = try #require(settings.projectCommands(for: root).first)
    let command = ProjectSettingsContent.commandState(logs, root: root, settings: settings) { _ in }
    #expect(command.badgeText == "This Mac only")
    #expect(command.buttons.isEmpty)
    // Its cherry.toml is never written from here, so Delete… says nothing of it.
    #expect(!ProjectCommandEditor.projectFileHasCommand(named: "Logs", projectRoot: root))
}

@Test @MainActor func projectPageValueEqualToWhatAppliesWithoutThisMacsDropsThisMacs() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try writeProjectFile("[features]\ntodos = true\n\n[appearance]\ncolor = \"green\"\n", in: directory)

    // Flipped and flipped back: nothing pins cherry.toml's own value.
    try ProjectSettingsContent.setTodos(false, root: root, settings: settings)
    #expect(settings.todosSource(for: root) == .overridesProjectFile)
    #expect(!settings.projectFeatures(for: root).todosEnabled)
    try ProjectSettingsContent.setTodos(true, root: root, settings: settings)
    #expect(settings.todosSource(for: root) == .projectFile)
    #expect(settings.projectFeatureOverrides(for: root).isEmpty)
    #expect(settings.projectFeatures(for: root).todosEnabled)

    try ProjectSettingsContent.setColor(.blue, root: root, settings: settings)
    #expect(settings.colorSource(for: root) == .overridesProjectFile)
    try ProjectSettingsContent.setColor(.green, root: root, settings: settings)
    #expect(settings.colorSource(for: root) == .projectFile)
    #expect(settings.projectAppearanceOverrides(for: root).isEmpty)
    // None is a value of its own here: it overrides cherry.toml's green.
    try ProjectSettingsContent.setColor(nil, root: root, settings: settings)
    #expect(settings.colorSource(for: root) == .overridesProjectFile)
    #expect(settings.projectAppearance(for: root).color == nil)

    // Without a cherry.toml, Cherry's default is what applies without it.
    let other = try temporaryProject()
    defer { removeProject(other) }
    let otherRoot = try #require(settings.addProject(path: other.path)).root
    try ProjectSettingsContent.setTodos(true, root: otherRoot, settings: settings)
    #expect(settings.todosSource(for: otherRoot) == .thisMacOnly)
    try ProjectSettingsContent.setTodos(false, root: otherRoot, settings: settings)
    #expect(settings.todosSource(for: otherRoot) == ProjectValueSource.none)
    try ProjectSettingsContent.setColor(.red, root: otherRoot, settings: settings)
    #expect(settings.colorSource(for: otherRoot) == .thisMacOnly)
    try ProjectSettingsContent.setColor(nil, root: otherRoot, settings: settings)
    #expect(settings.colorSource(for: otherRoot) == ProjectValueSource.none)
    #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("cherry.toml").path))
}

@Test @MainActor func projectPageCommandBadgesRevertAndSaveThisMacsCopy() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    let web = ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev")
    try settings.upsertCommand(web, for: root, storage: .projectFile)
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app"),
        for: root,
        storage: .local
    )
    let reports = Reports()
    func state(_ name: String) throws -> SettingsSourceState {
        let command = try #require(settings.projectCommands(for: root).first { $0.name == name })
        return ProjectSettingsContent.commandState(command, root: root, settings: settings, report: reports.record)
    }

    let fileOnly = try state("Web")
    #expect(fileOnly.badgeText == "cherry.toml")
    #expect(fileOnly.buttons.isEmpty)
    #expect(fileOnly.rowReset == nil)

    // This Mac only: no reset, which would delete it without asking.
    let thisMacOnly = try state("API")
    #expect(thisMacOnly.badgeText == "This Mac only")
    #expect(thisMacOnly.buttons.map(\.title) == ["Save to cherry.toml"])
    #expect(thisMacOnly.rowReset == nil)

    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev -- --host"),
        for: root,
        storage: .local
    )
    let contents = try projectFileContents(directory)
    let override = try state("Web")
    #expect(override.badgeText == "Overrides cherry.toml")
    #expect(override.lines == [
        .init("This Mac", value: "npm run dev -- --host", isInUse: true),
        .init("cherry.toml", value: "npm run dev"),
    ])
    #expect(override.rowReset?.title == "Revert Web to cherry.toml")
    #expect(override.buttons.map(\.title) == ["Revert Web to cherry.toml", "Save to cherry.toml"])
    override.rowReset?.perform()
    #expect(settings.commandSource(named: "Web", for: root) == .projectFile)
    #expect(settings.projectCommands(for: root).first { $0.name == "Web" } == web)
    #expect(try projectFileContents(directory) == contents)

    // Save to cherry.toml: the file gets this Mac's copy, which goes here.
    try #require(try state("API").buttons.first).perform()
    #expect(settings.commandSource(named: "API", for: root) == .projectFile)
    #expect(try projectFileContents(directory).contains("name = \"API\""))
    #expect(reports.messages == [nil, nil])
}

@Test @MainActor func projectPageCommandTagsSayHowItRuns() {
    #expect(ProjectSettingsContent.commandTags(ProjectCommandDefinition(name: "Web", command: "npm")).isEmpty)
    let all = ProjectCommandDefinition(name: "Web", command: "npm", autoStart: true, autoRestart: true, enabled: false)
    #expect(ProjectSettingsContent.commandTags(all) == ["Auto-start", "Restarts", "Disabled"])
}

@Test @MainActor func projectPageRevertToCherryTomlAsksFirstAndKeepsTheCommands() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try writeProjectFile("[features]\ntodos = true\n", in: directory)
    try settings.upsertCommand(ProjectCommandDefinition(name: "Web", command: "npm"), for: root, storage: .projectFile)
    #expect(ProjectSettingsContent.revertChanges(root: root, settings: settings).isEmpty)

    try ProjectSettingsContent.setTodos(false, root: root, settings: settings)
    try ProjectSettingsContent.setColor(.blue, root: root, settings: settings)
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Web", command: "npm", arguments: "start"),
        for: root,
        storage: .local
    )
    let changes = ProjectSettingsContent.revertChanges(root: root, settings: settings)
    #expect(changes == [
        SettingsChange(title: "Todos", from: "Off", to: "On"),
        SettingsChange(title: "Color", from: "Blue", to: "None"),
    ])

    let question = ProjectSettingsContent.revertConfirmation(projectName: "cherry", changes: changes) {
        settings.revertProjectToProjectFile(root)
    }
    #expect(question == SettingsConfirmation(
        title: "Revert “cherry” to cherry.toml?",
        message: "Todos Off → On · Color Blue → None. Commands keep their own overrides.",
        choices: [SettingsConfirmation.Choice("Revert", isDefault: true), .cancel()]
    ))
    #expect(ProjectSettingsContent.footerCaption == "Revert drops this Mac's Todos and Color overrides. Commands keep theirs.")

    question.choices[0].perform()
    #expect(ProjectSettingsContent.revertChanges(root: root, settings: settings).isEmpty)
    #expect(settings.todosSource(for: root) == .projectFile)
    #expect(settings.colorSource(for: root) == ProjectValueSource.none)
    #expect(settings.commandSource(named: "Web", for: root) == .overridesProjectFile)
}

@Test @MainActor func projectPageCherryTomlRowSaysWhetherTheFolderHasOne() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root

    #expect(!CherryProjectFile.exists(projectRoot: root))
    #expect(ProjectSettingsContent.projectFileHelp(exists: false)
        == "None yet: Cherry creates one when you save a value to it.")

    // Saving a value to it makes one.
    try ProjectSettingsContent.setTodos(true, root: root, settings: settings)
    try ProjectSettingsContent.saveTodosToProjectFile(root: root, settings: settings)
    #expect(CherryProjectFile.exists(projectRoot: root))
    #expect(ProjectSettingsContent.projectFileHelp(exists: true) == "In this folder. Shared with everyone who opens it.")
    #expect(settings.todosSource(for: root) == .projectFile)
}

@Test @MainActor func addCommandOpensTheEditorEmptyAndTheEditorSaysWhereItSaves() {
    let command = ProjectSettingsContent.newCommand
    #expect(command.name.isEmpty)
    #expect(command.commandLine.isEmpty)
    #expect(command.workingDirectory.isEmpty)
    #expect(command.environment.isEmpty)
    #expect(command.enabled)
    #expect(!command.autoStart)
    #expect(!command.autoRestart)

    #expect(ProjectCommandEditor.title(canDelete: false) == "Add Command")
    #expect(ProjectCommandEditor.title(canDelete: true) == "Edit Command")
    #expect(ProjectCommandEditor.enabledLabel == "Enabled")
    #expect(ProjectCommandEditor.projectFileOption == "Save to cherry.toml")
    #expect(ProjectCommandEditor.projectFileOptionSubtitle(fileExists: true) == "Shared with everyone who opens this folder")
    #expect(ProjectCommandEditor.projectFileOptionSubtitle(fileExists: false) == "No cherry.toml yet: Cherry creates one")
    #expect(ProjectCommandEditor.thisMacOption == "This Mac only")
    #expect(ProjectCommandEditor.thisMacOptionSubtitle == "Kept by Cherry on this Mac")
}

@Test @MainActor func deletingACommandAsksAndSaysWhenItLeavesCherryToml() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Dev server", command: "npm", arguments: "run dev"),
        for: root,
        storage: .projectFile
    )
    try settings.upsertCommand(ProjectCommandDefinition(name: "Logs", command: "tail"), for: root, storage: .local)

    #expect(ProjectCommandEditor.projectFileHasCommand(named: "dev server", projectRoot: root))
    #expect(!ProjectCommandEditor.projectFileHasCommand(named: "Logs", projectRoot: root))

    let inFile = ProjectCommandEditor.deleteConfirmation(commandName: "Dev server", inProjectFile: true) {
        settings.removeCommand(named: "Dev server", for: root)
    }
    #expect(inFile == SettingsConfirmation(
        title: "Delete the command “Dev server”?",
        message: "It's removed from cherry.toml.",
        choices: [SettingsConfirmation.Choice("Delete", role: .destructive), .cancel()]
    ))
    let thisMacOnly = ProjectCommandEditor.deleteConfirmation(commandName: "Logs", inProjectFile: false) {}
    #expect(thisMacOnly.title == "Delete the command “Logs”?")
    #expect(thisMacOnly.message == nil)

    // Cancel deletes nothing; Delete removes it from cherry.toml too.
    inFile.choices[1].perform()
    #expect(settings.projectCommands(for: root).map(\.name) == ["Dev server", "Logs"])
    inFile.choices[0].perform()
    #expect(settings.projectCommands(for: root).map(\.name) == ["Logs"])
    #expect(!ProjectCommandEditor.projectFileHasCommand(named: "Dev server", projectRoot: root))
}

@Test @MainActor func searchFindsAProjectsCommandByItsName() throws {
    let directory = try temporaryProject()
    defer { removeProject(directory) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjectPage"))
    let root = try #require(settings.addProject(path: directory.path)).root
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Host tests", command: "cargo", arguments: "test"),
        for: root,
        storage: .local
    )
    try ProjectSettingsContent.setTodos(true, root: root, settings: settings)
    let context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: privateDefaults("SettingsWindowProjectPage")),
        agents: settings,
        defaults: privateDefaults("SettingsWindowProjectPage")
    )
    let rows = SettingsSearchIndex.rows(in: context)
    func projectResults(_ query: String) -> [SettingsSearchRow] {
        SettingsSearchIndex.groups(for: query, in: rows).first { $0.kind == .projects }?.results.map(\.row) ?? []
    }

    let command = try #require(projectResults("host tests").first)
    #expect(command.id == .projectCommand(root, named: "Host tests"))
    #expect(command.route == .project(root))
    #expect(command.section == "Commands")
    #expect(command.value == "cargo test")
    #expect(projectResults("dev server").contains { $0.id == .projectCommands(root) })
    #expect(projectResults("to-do").map(\.id) == [.projectTodos(root)])

    let pageRows = ProjectSettingsPage.searchRows(in: context).filter { $0.route == .project(root) }
    #expect(pageRows.map(\.id) == [
        .projectTodos(root),
        .projectColor(root),
        .projectCommands(root),
        .projectCommand(root, named: "Host tests"),
    ])
    #expect(pageRows.map(\.value) == ["On", "None", "1 command", "cargo test"])
}
