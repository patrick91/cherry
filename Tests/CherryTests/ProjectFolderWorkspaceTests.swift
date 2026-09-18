import Foundation
import Darwin
import Testing
@testable import Cherry

@MainActor
@Test func projectFolderSwitchKeepsSessionsAndProjectTools() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = directory.appendingPathComponent("api")
    let second = directory.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let suite = "cherry.folder-workspace.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    let settings = AgentSettings(defaults: defaults)
    let project = try #require(settings.addProject(path: first.path))
    let folder = try #require(settings.addFolder(path: second.path, toProjectRoot: project.root))
    let repository = RepositoryWorkspace(projectRoot: project.root, settings: settings, createInitialSession: false, launchBackend: .hostManaged)
    defer { repository.closeAllSessions() }
    let firstWorkspace = repository.activeWorkspace
    let shell = firstWorkspace.addSession(title: "API shell")
    let chrome = ProjectWindowChromeState()
    let noteID = UUID()
    chrome.selectNote(id: noteID)
    let secondWorkspace = try #require(repository.activateFolder(path: folder.path, chromeState: chrome))
    #expect(secondWorkspace !== firstWorkspace)
    #expect(secondWorkspace.sessions.isEmpty)
    #expect(chrome.selectedNoteID == noteID)
    #expect(repository.allLoadedWorkspaces().count == 2)
    let returned = try #require(repository.activateFolder(path: project.root, chromeState: chrome, clearSelection: true))
    #expect(returned === firstWorkspace)
    #expect(returned.sessions.first === shell)
    #expect(returned.selectedSession == nil)
    #expect(chrome.selectedNoteID == nil)
    returned.select(shell)
    #expect(returned.selectedSession === shell)
    #expect(!SessionCloseCoordinator.shouldCloseWindow(for: returned, repository: repository))
    SessionCloseCoordinator.close(shell, in: returned, chromeState: chrome, allowEmptyWorkspace: true)
    #expect(returned.sessions.isEmpty)
    #expect(repository.folders.count == 2)
}

@MainActor
@Test func missingProjectFolderStartsWithoutFallbackShellAndCanRelocate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let old = directory.appendingPathComponent("old")
    let replacement = directory.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    let suite = "cherry.folder-relocation.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    let settings = AgentSettings(defaults: defaults)
    let project = try #require(settings.addProject(path: old.path))
    try FileManager.default.removeItem(at: old)
    let missing = RepositoryWorkspace(projectRoot: project.root, settings: settings, launchBackend: .hostManaged)
    defer { missing.closeAllSessions() }
    #expect(missing.activeWorkspace.sessions.isEmpty)
    #expect(!missing.folders[0].isAvailable)
    #expect(settings.relocateFolder(id: project.folders[0].id, path: replacement.path, inProjectRoot: project.root))
    missing.synchronizeFolders()
    #expect(missing.folders[0].id == project.folders[0].id)
    let updated = RepositoryWorkspace(projectRoot: project.root, settings: settings, createInitialSession: false, launchBackend: .hostManaged)
    #expect(updated.activeWorkspace.projectRoot == canonicalFolderTestPath(replacement))
    #expect(updated.repositoryRoot == project.root)
}

@MainActor
@Test func sameNamedCommandRunsStayInTheirOwningFolder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = directory.appendingPathComponent("api")
    let second = directory.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = TerminalWorkspace(projectRoot: first.path, createInitialSession: false, launchBackend: .hostManaged)
    let b = TerminalWorkspace(projectRoot: second.path, createInitialSession: false, launchBackend: .hostManaged)
    defer { a.closeAllSessions(); b.closeAllSessions() }
    let definition = ProjectCommandDefinition(name: "dev", command: "/bin/cat")
    let runA = a.addCommandSession(command: definition, projectRoot: first.path)
    let runB = b.addCommandSession(command: definition, projectRoot: second.path)
    #expect(runA.id != runB.id)
    #expect(runA.workingDirectory == first.path)
    #expect(runB.workingDirectory == second.path)
    #expect(a.addCommandSession(command: definition, projectRoot: first.path) === runA)
    #expect(a.unifiedDisplayItems.count == 1)
    #expect(b.unifiedDisplayItems.count == 1)
}

@MainActor
@Test func restoringSecondFolderDoesNotAliasTheFirstWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    let unrelated = directory.appendingPathComponent("old-worktree")
    for url in [first, second, unrelated] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let suite = "cherry.folder-restore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    let settings = AgentSettings(defaults: defaults)
    let project = try #require(settings.addProject(path: first.path))
    let secondFolder = try #require(settings.addFolder(path: second.path, toProjectRoot: project.root))
    settings.markWorktreeOpened(secondFolder.path, repositoryRoot: project.root)
    let restored = RepositoryWorkspace(projectRoot: project.root, settings: settings, createInitialSession: false, launchBackend: .hostManaged)
    #expect(restored.activeWorkspace.projectRoot == canonicalFolderTestPath(second))
    #expect(restored.workspaceIfLoaded(for: project.root) !== restored.activeWorkspace)
    #expect(restored.workspaceIfLoaded(for: project.root)?.projectRoot == canonicalFolderTestPath(first))
    #expect(restored.adjacentWorktree(offset: 1)?.root == canonicalFolderTestPath(first))
    settings.markWorktreeOpened(unrelated.path, repositoryRoot: project.root)
    let safeRestore = RepositoryWorkspace(projectRoot: project.root, settings: settings, createInitialSession: false, launchBackend: .hostManaged)
    #expect(safeRestore.activeWorkspace.projectRoot == canonicalFolderTestPath(first))
    #expect(safeRestore.allLoadedWorkspaces().count == 2)
}

@MainActor
@Test func closingFinalSplitGroupLeavesFolderEmpty() throws {
    let workspace = TerminalWorkspace(createInitialSession: false, launchBackend: .hostManaged)
    defer { workspace.closeAllSessions() }
    let first = workspace.addSession()
    let second = workspace.addSession(select: false)
    workspace.updateTerminalDetailWidth(1_200)
    workspace.select(first)
    #expect(workspace.splitActiveTerminal(with: second))
    let group = try #require(workspace.splitGroup(containing: first.id))
    #expect(workspace.canCloseSplitGroup(id: group.id))
    workspace.closeSplitGroup(id: group.id)
    #expect(workspace.sessions.isEmpty)
    #expect(workspace.selectedSession == nil)
    #expect(workspace.unifiedDisplayItems.isEmpty)
}

private func canonicalFolderTestPath(_ url: URL) -> String {
    guard let path = realpath(url.path, nil) else { return url.path }
    defer { free(path) }
    return String(cString: path)
}
