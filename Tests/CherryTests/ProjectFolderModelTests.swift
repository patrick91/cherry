import Darwin
import Foundation
import Testing
@testable import Cherry

@Suite("Project folder model", .serialized)
@MainActor
struct ProjectFolderModelTests {
    @Test func legacyProjectsMigrateWithoutDroppingUnavailableFoldersOrSettings() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let available = try fixture.directory("available")
        let missing = fixture.container.appendingPathComponent("disconnected", isDirectory: true)
        let missingWorktree = fixture.container.appendingPathComponent("missing-worktree", isDirectory: true)
        let legacy = try JSONSerialization.data(withJSONObject: [["root": available.path], ["root": missing.path]])
        fixture.defaults.set(legacy, forKey: "projects.items")
        fixture.defaults.set(missing.path, forKey: "projects.lastOpenedRoot")
        let command = ProjectCommandDefinition(name: "Server", command: "run-server")
        fixture.defaults.set(try JSONEncoder().encode([missing.path: [command]]), forKey: "commands.byProject")
        fixture.defaults.set(
            try JSONEncoder().encode([missing.path: ProjectFeatureOverrides(notesEnabled: true, todosEnabled: true)]),
            forKey: "features.byProject"
        )
        fixture.defaults.set(
            try JSONEncoder().encode([missing.path: ProjectAppearanceOverrides(color: .pink)]),
            forKey: "appearance.byProject"
        )
        fixture.defaults.set(try JSONEncoder().encode([missing.path: [missingWorktree.path]]), forKey: "worktrees.hiddenByProject")
        fixture.defaults.set(try JSONEncoder().encode([missing.path: missingWorktree.path]), forKey: "worktrees.lastActiveByProject")

        let settings = AgentSettings(defaults: fixture.defaults)
        #expect(settings.projects.map(\.root) == [available.path, missing.path])
        #expect(settings.projects.map { $0.folders.map(\.path) } == [[available.path], [missing.path]])
        #expect(settings.projects[0].folders[0].isAvailable)
        #expect(!settings.projects[1].folders[0].isAvailable)
        #expect(settings.selectedProject(for: missing.path)?.id == settings.projects[1].id)
        #expect(settings.projectRoot(for: nil) == missing.path)
        #expect(settings.commandsByProject[missing.path] == [command])
        #expect(settings.projectCommands(for: missing.path) == [command])
        #expect(settings.launchableProjectCommands(for: missing.path).isEmpty)
        #expect(settings.resolvedProject(for: missing.path).validProjectRoot == nil)
        #expect(settings.projectFeatures(for: missing.path) == .init(notesEnabled: true, todosEnabled: true))
        #expect(settings.projectAppearance(for: missing.path).color == .pink)
        #expect(settings.hiddenWorktreesByProject[missing.path] == [missingWorktree.path])
        #expect(settings.lastActiveWorktreeByProject[missing.path] == missingWorktree.path)

        let decodedAgain = try JSONDecoder().decode([CherryProject].self, from: legacy)
        #expect(decodedAgain == settings.projects)
        let stored = try #require(fixture.defaults.data(forKey: "projects.items"))
        let envelope = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(envelope["version"] as? Int == 2)
        let reloaded = AgentSettings(defaults: fixture.defaults)
        #expect(reloaded.projects == settings.projects)
        #expect(reloaded.commandsByProject == settings.commandsByProject)
        #expect(reloaded.featureOverridesByProject == settings.featureOverridesByProject)
        #expect(reloaded.appearanceOverridesByProject == settings.appearanceOverridesByProject)
    }

    @Test func orderedFoldersAndProjectNamesPersistWithStableIDs() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("first/service")
        let second = try fixture.directory("second/service")
        let third = try fixture.directory("third")
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: first.path))
        let added = try #require(settings.addFolder(path: second.path, toProjectRoot: project.root))
        let last = try #require(settings.addFolder(path: third.path, toProjectRoot: project.root))
        #expect(settings.renameProject("  My product  ", for: second.path))
        #expect(!settings.renameProject(" \n ", for: project.root))

        let reloaded = AgentSettings(defaults: fixture.defaults)
        let saved = try #require(reloaded.project(for: second.path))
        #expect(saved.id == project.id)
        #expect(saved.root == first.path)
        #expect(saved.name == "My product")
        #expect(saved.folders.map(\.path) == [first.path, second.path, third.path])
        #expect(saved.folders.map(\.id) == [project.folders[0].id, added.id, last.id])
        #expect(saved.folders.map(\.name) == ["service", "service", "third"])
        #expect(reloaded.selectedProject(for: third.path)?.id == project.id)
    }

    @Test func repeatedAdditionsReturnExistingRecordsAndRejectInvalidNewFolders() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        let other = try fixture.directory("other")
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: first.path))
        let folder = try #require(settings.addFolder(path: second.path, toProjectRoot: first.path))
        let otherProject = try #require(settings.addProject(path: other.path))

        #expect(settings.addProject(path: first.path + "/.")?.id == project.id)
        #expect(settings.addProject(path: second.path)?.id == project.id)
        #expect(settings.addFolder(path: second.path + "/.", toProjectRoot: first.path)?.id == folder.id)
        #expect(settings.addFolder(path: first.path, toProjectRoot: first.path)?.id == project.folders[0].id)
        #expect(settings.addFolder(path: second.path, toProjectRoot: otherProject.root) == nil)
        #expect(settings.addProject(path: fixture.container.appendingPathComponent("missing").path) == nil)
        #expect(settings.addFolder(path: fixture.container.appendingPathComponent("missing").path, toProjectRoot: first.path) == nil)
        #expect(settings.projects.count == 2)
        #expect(settings.projects[0].folders.count == 2)

        try FileManager.default.removeItem(at: first)
        #expect(settings.addProject(path: first.path)?.id == project.id)
        #expect(!settings.projects[0].folders[0].isAvailable)
    }

    @Test func foldersHaveIndependentCommandsAndShareProjectFeaturesAndAppearance() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        let worktree = try fixture.directory("second-worktree")
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: first.path))
        _ = try #require(settings.addFolder(path: second.path, toProjectRoot: first.path))
        try settings.upsertCommand(.init(name: "First local", command: "first"), for: first.path)
        try settings.upsertCommand(.init(name: "Second local", command: "second"), for: second.path)
        try CherryProjectFile.upsertCommand(.init(name: "First shared", command: "shared-first"), projectRoot: first.path)
        try CherryProjectFile.upsertCommand(.init(name: "Second shared", command: "shared-second"), projectRoot: second.path)
        try CherryProjectFile.writeFeatureSettings(.init(notesEnabled: true, todosEnabled: false), projectRoot: first.path)
        try CherryProjectFile.writeFeatureSettings(.init(notesEnabled: false, todosEnabled: true), projectRoot: second.path)
        try CherryProjectFile.writeAppearanceSettings(.init(color: .teal), projectRoot: first.path)
        try CherryProjectFile.writeAppearanceSettings(.init(color: .pink), projectRoot: second.path)

        #expect(settings.projectCommands(for: first.path).map(\.name).sorted() == ["First local", "First shared"])
        #expect(settings.projectCommands(for: second.path).map(\.name).sorted() == ["Second local", "Second shared"])
        #expect(settings.projectFeatures(for: second.path) == .init(notesEnabled: true, todosEnabled: false))
        #expect(settings.projectAppearance(for: second.path).color == .teal)
        try settings.setProjectFeatures(.init(notesEnabled: true, todosEnabled: true), for: second.path, storage: .local)
        try settings.setProjectAppearance(.init(color: .blue), for: second.path, storage: .local)
        #expect(settings.featureOverridesByProject.keys.sorted() == [project.root])
        #expect(settings.appearanceOverridesByProject.keys.sorted() == [project.root])
        #expect(settings.projectFeatures(for: first.path) == .init(notesEnabled: true, todosEnabled: true))
        #expect(settings.projectAppearance(for: first.path).color == .blue)

        settings.registerWorktreeRoots([second.path, worktree.path], repositoryRoot: second.path)
        #expect(settings.selectedProject(for: worktree.path)?.id == project.id)
        #expect(settings.repositoryRoot(for: worktree.path) == project.root)
        #expect(settings.projectCommands(for: worktree.path).map(\.name) == ["Second local"])
    }

    @Test func movingThePrimaryFolderPreservesProjectIdentityAndLegacySettingsAliases() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.directory("original")
        let moved = fixture.container.appendingPathComponent("moved", isDirectory: true)
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: original.path))
        try settings.upsertCommand(.init(name: "Server", command: "serve"), for: original.path)
        try settings.setProjectFeatures(.init(notesEnabled: true, todosEnabled: true), for: original.path, storage: .local)
        try settings.setProjectAppearance(.init(color: .blue), for: original.path, storage: .local)
        try CherryProjectFile.writeFeatureSettings(.init(notesEnabled: true, todosEnabled: false), projectRoot: original.path)
        settings.markProjectOpened(original.path)
        #expect(settings.renameProject("Product", for: original.path))
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(settings.relocateFolder(id: project.folders[0].id, path: moved.path, inProjectRoot: original.path))
        let reloaded = AgentSettings(defaults: fixture.defaults)
        let relocated = try #require(reloaded.project(for: moved.path))
        #expect(relocated.id == project.id)
        #expect(relocated.name == "Product")
        #expect(relocated.root == original.path)
        #expect(relocated.folders[0].id == project.folders[0].id)
        #expect(relocated.folders[0].path == moved.path)
        #expect(reloaded.repositoryRoot(for: moved.path) == original.path)
        #expect(reloaded.repositoryRoot(for: original.path) == original.path)
        #expect(reloaded.projectCommands(for: moved.path).map(\.name) == ["Server"])
        #expect(reloaded.launchableProjectCommands(for: original.path).map(\.name) == ["Server"])
        #expect(reloaded.resolvedProject(for: original.path).validProjectRoot == moved.path)
        #expect(reloaded.commandsByProject.keys.sorted() == [original.path])
        #expect(reloaded.projectFeatures(for: moved.path) == .init(notesEnabled: true, todosEnabled: true))
        #expect(reloaded.projectAppearance(for: moved.path).color == .blue)
        #expect(reloaded.projectFileConfiguresFeatures(for: moved.path))
        #expect(reloaded.lastOpenedProjectRoot == original.path)
    }

    @Test func relocatingAddedFoldersCarriesCommandsAndCannotOverwriteAnotherFolder() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        let moved = try fixture.directory("moved")
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: first.path))
        let folder = try #require(settings.addFolder(path: second.path, toProjectRoot: project.root))
        try settings.upsertCommand(.init(name: "Second", command: "second"), for: second.path)
        #expect(!settings.relocateFolder(id: folder.id, path: first.path, inProjectRoot: project.root))
        #expect(!settings.relocateFolder(id: folder.id, path: fixture.container.appendingPathComponent("missing").path, inProjectRoot: project.root))
        #expect(settings.relocateFolder(id: folder.id, path: moved.path, inProjectRoot: project.root))
        #expect(settings.projects[0].folders.map(\.id) == [project.folders[0].id, folder.id])
        #expect(settings.projectCommands(for: moved.path).map(\.name) == ["Second"])
        #expect(settings.projectCommands(for: first.path).isEmpty)
        #expect(AgentSettings(defaults: fixture.defaults).project(for: moved.path)?.folders[1].id == folder.id)
        try FileManager.default.removeItem(at: moved)
        #expect(settings.projectCommands(for: moved.path).map(\.name) == ["Second"])
        #expect(settings.resolvedProject(for: moved.path).validProjectRoot == nil)
        #expect(settings.launchableProjectCommands(for: moved.path).isEmpty)
    }

    @Test func explicitlyAddedWorktreeFoldersKeepIndependentCommandDefinitions() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("main")
        let linked = try fixture.directory("linked-worktree")
        let discovered = try fixture.directory("discovered-worktree")
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: first.path))
        _ = try #require(settings.addFolder(path: linked.path, toProjectRoot: project.root))
        settings.registerWorktreeRoots([first.path, linked.path, discovered.path], repositoryRoot: first.path)
        try settings.upsertCommand(.init(name: "Server", command: "main-server"), for: first.path)
        try settings.upsertCommand(.init(name: "Server", command: "linked-server"), for: linked.path)

        #expect(settings.projectCommands(for: first.path).map(\.command) == ["main-server"])
        #expect(settings.projectCommands(for: linked.path).map(\.command) == ["linked-server"])
        #expect(settings.projectCommands(for: discovered.path).map(\.command) == ["main-server"])
        #expect(settings.commandsByProject.keys.sorted() == [first.path, linked.path].sorted())
        #expect(settings.commandStorage(named: "Server", for: linked.path) == .local)
        settings.removeCommand(named: "Server", for: linked.path)
        #expect(settings.projectCommands(for: linked.path).isEmpty)
        #expect(settings.projectCommands(for: first.path).map(\.command) == ["main-server"])
    }

    @Test func canonicalRuntimePathsResolveSavedAliasesWithoutChangingTheirIdentity() throws {
        let fixture = try ProjectFolderFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.directory("main")
        let second = try fixture.directory("second")
        let firstAlias = fixture.container.appendingPathComponent("main-alias", isDirectory: true)
        let secondAlias = fixture.container.appendingPathComponent("second-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: first)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: second)
        let firstRuntimePath = try fixture.resolvedPath(first)
        let secondRuntimePath = try fixture.resolvedPath(second)
        let settings = AgentSettings(defaults: fixture.defaults)
        let project = try #require(settings.addProject(path: firstAlias.path))
        let folder = try #require(settings.addFolder(path: secondAlias.path, toProjectRoot: project.root))
        settings.registerWorktreeRoots([firstRuntimePath, secondRuntimePath], repositoryRoot: firstRuntimePath)
        try settings.upsertCommand(.init(name: "Server", command: "main-server"), for: firstRuntimePath)
        try settings.upsertCommand(.init(name: "Server", command: "second-server"), for: secondRuntimePath)
        try settings.setProjectFeatures(.init(notesEnabled: true, todosEnabled: true), for: secondRuntimePath, storage: .local)

        #expect(settings.project(for: firstRuntimePath)?.id == project.id)
        #expect(settings.project(for: secondRuntimePath)?.id == project.id)
        #expect(settings.repositoryRoot(for: secondRuntimePath) == firstAlias.path)
        #expect(settings.projectCommands(for: firstRuntimePath).map(\.command) == ["main-server"])
        #expect(settings.projectCommands(for: secondRuntimePath).map(\.command) == ["second-server"])
        #expect(settings.projectFeatures(for: secondRuntimePath) == .init(notesEnabled: true, todosEnabled: true))
        #expect(settings.commandsByProject.keys.sorted() == [firstAlias.path, secondAlias.path].sorted())
        #expect(settings.addProject(path: firstRuntimePath)?.id == project.id)
        #expect(settings.addFolder(path: secondRuntimePath, toProjectRoot: firstRuntimePath)?.id == folder.id)
        #expect(!settings.relocateFolder(id: folder.id, path: firstRuntimePath, inProjectRoot: firstRuntimePath))
        #expect(settings.relocateFolder(id: folder.id, path: secondRuntimePath, inProjectRoot: firstRuntimePath))
        #expect(settings.projects[0].root == firstAlias.path)
        #expect(settings.projects[0].folders[1].path == secondAlias.path)
        #expect(settings.projects[0].folders.count == 2)
    }
}

@MainActor
private struct ProjectFolderFixture {
    let defaultsName = "CherryTests.ProjectFolders.\(UUID().uuidString)"
    let defaults: UserDefaults
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryProjectFolders-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws -> URL {
        let directory = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func resolvedPath(_ url: URL) throws -> String {
        let resolved = try #require(url.path.withCString { realpath($0, nil) })
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: container)
    }
}
