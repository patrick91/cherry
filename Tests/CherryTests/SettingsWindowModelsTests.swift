import Foundation
import Testing
@testable import Cherry

// What Settings' pages ask of `AgentSettings`: adding, editing and
// duplicating agents without replacing or moving one, their tags and
// brands, and where a project's values come from (this Mac or its
// cherry.toml) with the resets that go back to cherry.toml. Private
// defaults and temporary project folders only.

/// A temporary project folder, removed when the test ends.
private func temporaryProject() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SettingsWindowModels-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func projectFileContents(_ directory: URL) throws -> String {
    try String(contentsOf: directory.appendingPathComponent("cherry.toml"), encoding: .utf8)
}

@Test @MainActor func settingsWindowAddAgentPicksAFreeNameAndNeverReplacesOne() throws {
    let defaults = privateDefaults("SettingsWindowModels")
    let settings = AgentSettings(defaults: defaults)
    let claude = try #require(AgentConfiguration.presets.first { $0.name == "Claude" })

    #expect(settings.availableAgentName(for: " Claude ") == "Claude")
    #expect(try settings.addAgent(claude).name == "Claude")
    var edited = claude
    edited.arguments = "--model opus"
    try settings.updateAgent(named: "Claude", with: edited)

    let second = try settings.addAgent(claude)
    #expect(second.name == "Claude 2")
    #expect(second.arguments == "--dangerously-skip-permissions")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2"])
    // The first one is untouched.
    #expect(settings.agents[0].arguments == "--model opus")
    #expect(settings.availableAgentName(for: "CLAUDE") == "CLAUDE 3")
    #expect(try settings.addAgent(AgentToolDefinition(name: "  claude ", command: " claude ")).name == "claude 3")
    #expect(settings.agents.last == AgentToolDefinition(name: "claude 3", command: "claude"))

    // Invalid agents are refused and nothing changes.
    #expect(throws: AgentConfigurationError.missingCommand(name: "Custom")) {
        try settings.addAgent(AgentToolDefinition(name: "Custom", command: ""))
    }
    #expect(throws: AgentConfigurationError.missingName) {
        try settings.addAgent(AgentToolDefinition(name: " ", command: "pi"))
    }
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2", "claude 3"])
    #expect(AgentSettings(defaults: defaults).agents.map(\.name) == ["Claude", "Claude 2", "claude 3"])
}

@Test @MainActor func settingsWindowUpdateAgentKeepsItsPlace() throws {
    let defaults = privateDefaults("SettingsWindowModels")
    let settings = AgentSettings(defaults: defaults)
    for preset in AgentConfiguration.presets where ["Claude", "Codex", "Pi"].contains(preset.name) {
        try settings.addAgent(preset)
    }

    var codex = try #require(settings.agents.first { $0.name == "Codex" })
    codex.enabled = false
    try settings.updateAgent(named: "codex", with: codex)
    #expect(settings.agents.map(\.name) == ["Claude", "Codex", "Pi"])
    #expect(settings.agents[1].enabled == false)

    codex.name = " Codex CLI "
    try settings.updateAgent(named: "Codex", with: codex)
    #expect(settings.agents.map(\.name) == ["Claude", "Codex CLI", "Pi"])
    #expect(AgentSettings(defaults: defaults).agents.map(\.name) == ["Claude", "Codex CLI", "Pi"])

    // Another agent's name, no command, or an agent that is gone: refused.
    codex.name = "pi"
    #expect(throws: AgentConfigurationError.duplicateName("Pi")) {
        try settings.updateAgent(named: "Codex CLI", with: codex)
    }
    codex.name = "Codex CLI"
    codex.command = ""
    #expect(throws: AgentConfigurationError.missingCommand(name: "Codex CLI")) {
        try settings.updateAgent(named: "Codex CLI", with: codex)
    }
    #expect(throws: AgentConfigurationError.unknownAgent("Gone")) {
        try settings.updateAgent(named: "Gone", with: AgentToolDefinition(name: "Gone", command: "gone"))
    }
    #expect(settings.agents.map(\.name) == ["Claude", "Codex CLI", "Pi"])
    #expect(settings.agents[1].command == "codex")
    #expect(AgentConfigurationError.unknownAgent("Gone").errorDescription == "There is no agent named 'Gone'.")
}

@Test @MainActor func settingsWindowDuplicateAgentInsertsACopyAfterIt() throws {
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowModels"))
    try settings.addAgent(
        AgentToolDefinition(name: "Claude", command: "claude", arguments: "--model opus", enabled: false)
    )
    try settings.addAgent(AgentToolDefinition(name: "Codex", command: "codex"))

    let copy = try settings.duplicateAgent(named: "claude")
    #expect(copy == AgentToolDefinition(name: "Claude 2", command: "claude", arguments: "--model opus", enabled: false))
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 2", "Codex"])
    #expect(try settings.duplicateAgent(named: "Claude").name == "Claude 3")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 3", "Claude 2", "Codex"])
    // A copy of a copy counts on from its number.
    #expect(try settings.duplicateAgent(named: "Claude 2").name == "Claude 4")
    #expect(settings.agents.map(\.name) == ["Claude", "Claude 3", "Claude 2", "Claude 4", "Codex"])
    #expect(settings.availableAgentName(for: "Codex 7") == "Codex 7")
    try settings.addAgent(AgentToolDefinition(name: "Codex 7", command: "codex"))
    #expect(settings.availableAgentName(for: "codex 7") == "codex 8")
    #expect(settings.availableAgentName(for: "Codex") == "Codex 2")
    #expect(throws: AgentConfigurationError.unknownAgent("Gemini")) {
        try settings.duplicateAgent(named: "Gemini")
    }
}

@Test func settingsWindowSkipsPermissionPromptsIsOneOfTheFlagsAsAWord() {
    let presets = Dictionary(uniqueKeysWithValues: AgentConfiguration.presets.map { ($0.name, $0) })
    #expect(presets["Claude"]?.skipsPermissionPrompts == true)
    #expect(presets["Codex"]?.skipsPermissionPrompts == true)
    for name in ["Pi", "Gemini", "OpenCode", "Amp", "Custom"] {
        #expect(presets[name]?.skipsPermissionPrompts == false, Comment(rawValue: name))
    }

    func skips(_ command: String, _ arguments: String = "") -> Bool {
        AgentToolDefinition(name: "Agent", command: command, arguments: arguments).skipsPermissionPrompts
    }
    #expect(skips("codex", "--dangerously-bypass-approvals-and-sandbox"))
    #expect(skips("codex", "--model gpt-5\t--yolo"))
    #expect(skips("claude --dangerously-skip-permissions"))
    #expect(skips("codex", "'--yolo'"))
    #expect(!skips("codex", "--yolo-mode"))
    #expect(!skips("codex", "--no-yolo"))
    #expect(!skips("codex", "x--yolo"))
    #expect(!skips("claude", "--dangerously-skip-permissions-later"))
    // No command, no agent to run.
    #expect(!skips("", "--yolo"))
}

@Test func settingsWindowAgentBrandsNameTheirProductStatusAndMCPCommand() {
    let brands: [AgentToolBrand] = [.claude, .codex, .pi, .gemini, .openCode, .amp]
    #expect(brands.map(\.productName) == ["Claude Code", "Codex", "Pi", "Gemini CLI", "OpenCode", "Amp"])
    #expect(brands.map(\.programStatusSupport) == [
        .reports(minimumVersion: "2.1.295"),
        .doesNotReport,
        .reports(minimumVersion: "1.1.0"),
        .unknown,
        .unknown,
        .doesNotReport,
    ])
}

@Test @MainActor func settingsWindowProjectValueSourcesFollowThisMacAndCherryToml() throws {
    let directory = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.path
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowModels"))
    settings.addProject(path: root)

    #expect(settings.todosSource(for: root) == ProjectValueSource.none)
    #expect(settings.colorSource(for: root) == ProjectValueSource.none)

    // This Mac only.
    try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: true), for: root, storage: .local)
    try settings.setProjectAppearance(ProjectAppearanceSettings.none, for: root, storage: .local)
    #expect(settings.todosSource(for: root) == .thisMacOnly)
    // An explicit None is this Mac's value too.
    #expect(settings.colorSource(for: root) == .thisMacOnly)

    // cherry.toml as well: this Mac's value wins.
    try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: false), for: root, storage: .projectFile)
    try settings.setProjectAppearance(ProjectAppearanceSettings(color: .green), for: root, storage: .projectFile)
    #expect(settings.todosSource(for: root) == .overridesProjectFile)
    #expect(settings.colorSource(for: root) == .overridesProjectFile)
    #expect(settings.projectFeatures(for: root).todosEnabled)
    #expect(settings.projectAppearance(for: root).color == nil)

    // cherry.toml alone.
    settings.clearLocalProjectFeatureOverrides(for: root)
    settings.clearLocalProjectAppearanceOverrides(for: root)
    #expect(settings.todosSource(for: root) == .projectFile)
    #expect(settings.colorSource(for: root) == .projectFile)

    #expect(settings.todosSource(for: directory.appendingPathComponent("gone").path) == ProjectValueSource.none)
}

@Test @MainActor func settingsWindowAFeaturesTableWithoutTodosSetsTodos() throws {
    let directory = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "[features]\nnotes = true\n".write(
        to: directory.appendingPathComponent("cherry.toml"),
        atomically: true,
        encoding: .utf8
    )
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowModels"))

    #expect(settings.todosSource(for: directory.path) == .projectFile)
    #expect(!settings.projectFeatures(for: directory.path).todosEnabled)
    #expect(settings.colorSource(for: directory.path) == ProjectValueSource.none)
}

@Test @MainActor func settingsWindowCommandSourceAndRemovingThisMacsCopy() throws {
    let directory = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.path
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowModels"))
    settings.addProject(path: root)
    let web = ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev")
    try settings.upsertCommand(web, for: root, storage: .projectFile)
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "API", command: "uvicorn", arguments: "main:app"),
        for: root,
        storage: .local
    )

    #expect(settings.commandSource(named: "Web", for: root) == .projectFile)
    #expect(settings.commandSource(named: "api", for: root) == .thisMacOnly)
    #expect(settings.commandSource(named: "Missing", for: root) == ProjectValueSource.none)

    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev -- --host"),
        for: root,
        storage: .local
    )
    #expect(settings.commandSource(named: "web", for: root) == .overridesProjectFile)
    let file = try projectFileContents(directory)

    // Revert: cherry.toml's definition applies again, and the file stays.
    settings.removeLocalCommand(named: "Web", for: root)
    #expect(settings.commandSource(named: "Web", for: root) == .projectFile)
    #expect(settings.projectCommands(for: root).first { $0.name == "Web" } == web)
    #expect(try projectFileContents(directory) == file)

    // This Mac's only copy: the command goes.
    settings.removeLocalCommand(named: "API", for: root)
    #expect(settings.commandSource(named: "API", for: root) == ProjectValueSource.none)
    #expect(settings.projectCommands(for: root).map(\.name) == ["Web"])

    // A command only cherry.toml has stays.
    settings.removeLocalCommand(named: "Web", for: root)
    #expect(settings.projectCommands(for: root) == [web])
    #expect(try projectFileContents(directory) == file)
}

@Test @MainActor func settingsWindowOfferAgainForgetsARemovedFolder() throws {
    let directory = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = privateDefaults("SettingsWindowModels")
    let settings = AgentSettings(defaults: defaults)
    let project = try #require(settings.addProject(path: directory.path))

    settings.removeProject(project)
    #expect(settings.removedProjectRoots == [project.root])
    #expect(AgentSettings(defaults: defaults).removedProjectRoots == [project.root])

    settings.forgetRemovedProjectRoot(project.root)
    #expect(settings.removedProjectRoots.isEmpty)
    // It is offered again, not added.
    #expect(!settings.projects.contains(project))
    let reloaded = AgentSettings(defaults: defaults)
    #expect(reloaded.removedProjectRoots.isEmpty)
    #expect(!reloaded.projects.contains(project))
}

@Test @MainActor func settingsWindowRevertToCherryTomlDropsTodosAndColorButNotCommands() throws {
    let directory = try temporaryProject()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.path
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowModels"))
    settings.addProject(path: root)
    try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: true), for: root, storage: .projectFile)
    try settings.setProjectAppearance(ProjectAppearanceSettings(color: .green), for: root, storage: .projectFile)
    try settings.upsertCommand(ProjectCommandDefinition(name: "Web", command: "npm"), for: root, storage: .projectFile)
    try settings.setProjectFeatures(ProjectFeatureSettings(todosEnabled: false), for: root, storage: .local)
    try settings.setProjectAppearance(ProjectAppearanceSettings(color: .blue), for: root, storage: .local)
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "Web", command: "npm", arguments: "run dev"),
        for: root,
        storage: .local
    )
    let file = try projectFileContents(directory)

    settings.revertProjectToProjectFile(root)

    #expect(settings.todosSource(for: root) == .projectFile)
    #expect(settings.colorSource(for: root) == .projectFile)
    #expect(settings.projectFeatures(for: root).todosEnabled)
    #expect(settings.projectAppearance(for: root).color == .green)
    #expect(settings.commandSource(named: "Web", for: root) == .overridesProjectFile)
    #expect(try projectFileContents(directory) == file)
}
