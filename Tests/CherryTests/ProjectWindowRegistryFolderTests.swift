import AppKit
import Foundation
import Testing
@testable import Cherry

@MainActor
@Test func registryFindsInactiveAddedFolderThroughItsCanonicalRuntimePath() throws {
    let container = FileManager.default.temporaryDirectory
        .appendingPathComponent("CherryRegistryFolders-\(UUID().uuidString)", isDirectory: true)
    let first = container.appendingPathComponent("api", isDirectory: true)
    let second = container.appendingPathComponent("website", isDirectory: true)
    let secondAlias = container.appendingPathComponent("website-alias", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: second)
    let suite = "CherryTests.RegistryFolders.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: container)
    }
    let settings = AgentSettings(defaults: defaults)
    let project = try #require(settings.addProject(path: first.path))
    let repository = RepositoryWorkspace(
        projectRoot: project.root,
        settings: settings,
        createInitialSession: false,
        launchBackend: .hostManaged
    )
    defer { repository.closeAllSessions() }
    let firstWorkspace = repository.activeWorkspace
    let registry = ProjectWindowRegistry(settings: settings)
    let chrome = ProjectWindowChromeState()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
        registry.unregister(window: window, projectRoot: project.root)
        window.close()
    }
    #expect(registry.register(
        window: window,
        projectRoot: project.root,
        workspace: firstWorkspace,
        repository: repository,
        noteStore: nil,
        todoStore: nil,
        chromeState: chrome
    ))

    // Add through a saved path alias after the window is already registered,
    // just as the folder picker and its following settings refresh do.
    let folder = try #require(settings.addFolder(path: secondAlias.path, toProjectRoot: project.root))
    repository.synchronizeFolders()
    registry.repositoryDidRefresh(repository)
    let secondWorkspace = try #require(repository.activateFolder(path: folder.path, chromeState: nil))
    let runtimePath = try #require(secondWorkspace.projectRoot)
    #expect(runtimePath != folder.path)
    #expect(registry.workspace(for: runtimePath) === secondWorkspace)

    _ = try #require(repository.activateFolder(path: project.root, chromeState: nil))
    registry.repositoryDidActivate(repository)
    #expect(repository.activeWorkspace === firstWorkspace)
    #expect(registry.repository(for: runtimePath) === repository)
    #expect(registry.workspace(for: runtimePath) === secondWorkspace)
    #expect(registry.workspace(for: folder.path) === secondWorkspace)
    #expect(registry.chromeState(for: runtimePath) === chrome)
    #expect(registry.hasWindow(for: runtimePath))
    #expect(registry.canonicalProjectRoot(for: runtimePath) == registry.canonicalProjectRoot(for: project.root))
}
