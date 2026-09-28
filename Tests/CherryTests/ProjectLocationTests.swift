import CherryControl
import Foundation
import Testing
@testable import Cherry

// Projects on other Macs are keyed `device:<uuid>:<path>` everywhere a
// project is identified (docs/specs/remote-devices.md).

@MainActor @Test func projectLocationKeysRoundTripAndNeverCollideWithTheSameLocalPath() throws {
    let device = try #require(UUID(uuidString: "6F1C2A34-9B7D-4E21-8C55-0A1B2C3D4E5F"))
    let remote = ProjectLocation.remote(deviceID: device, path: "/Users/me/work/app")
    #expect(remote.key == "device:6f1c2a34-9b7d-4e21-8c55-0a1b2c3d4e5f:/Users/me/work/app")
    #expect(ProjectLocation(key: remote.key) == remote)
    #expect(ProjectLocation(key: remote.key).path == "/Users/me/work/app")
    #expect(ProjectLocation(key: remote.key).deviceID == device)
    #expect(ProjectLocation.isRemoteKey(remote.key))
    #expect(ProjectLocation.launchPath(forKey: remote.key) == "/Users/me/work/app")
    // Trailing and doubled slashes do not make another project.
    #expect(ProjectLocation.remote(deviceID: device, path: "/Users/me//work/app/").key == remote.key)
    #expect(ProjectLocation(key: remote.key.uppercased()).isRemote == false)

    // The same path on This Mac is another project, with another key.
    let local = ProjectLocation(key: "/Users/me/work/app")
    #expect(local == .local(path: "/Users/me/work/app"))
    #expect(local.key == "/Users/me/work/app")
    #expect(!local.isRemote)
    #expect(local.key != remote.key)
    #expect(ProjectLocation.launchPath(forKey: local.key) == local.key)

    // Not remote keys: anything else is a local path, as it always was.
    for key in ["device:", "device:not-a-uuid:/x", "device:\(device.uuidString):relative", "/device:x"] {
        #expect(!ProjectLocation.isRemoteKey(key), "\(key)")
        #expect(ProjectLocation(key: key) == .local(path: key))
    }

    // Everything keyed on a project tells them apart.
    #expect(ProjectNoteStore.projectStorageName(projectRoot: remote.key)
        != ProjectNoteStore.projectStorageName(projectRoot: local.key))
    #expect(CherryDeepLink.projectKey(forProjectRoot: remote.key)
        != CherryDeepLink.projectKey(forProjectRoot: local.key))
    // Another device's project at the same path is another project too.
    let other = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/work/app")
    #expect(CherryDeepLink.projectKey(forProjectRoot: other.key)
        != CherryDeepLink.projectKey(forProjectRoot: remote.key))
}

@Test func aRemoteProjectsDeepLinkKeyDoesNotDependOnTheCurrentDirectory() throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/srv/app").key
    let before = CherryDeepLink.projectKey(forProjectRoot: key)
    let previous = FileManager.default.currentDirectoryPath
    defer { FileManager.default.changeCurrentDirectoryPath(previous) }
    FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory())
    #expect(CherryDeepLink.projectKey(forProjectRoot: key) == before)
    // A link to it resolves back to the same key.
    let link = try CherryDeepLink.parse(CherryDeepLink.noteURL(projectRoot: key, noteID: UUID()))
    #expect(link.projectKey == before)
}

@MainActor
@Test func settingsKeepARemoteProjectsKeyAndNeverTouchItsFilesHere() throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/work/app").key
    // Accepted without looking for the directory on this Mac.
    #expect(AgentSettings.validDirectory(key) == key)
    #expect(AgentSettings.validDirectory(" \(key) ") == key)
    // No cherry.toml of its is read or written here.
    #expect(!CherryProjectFile.exists(projectRoot: key))
    #expect(CherryProjectFile.loadCommands(projectRoot: key).isEmpty)
    #expect(CherryProjectFile.loadFeatureSettings(projectRoot: key) == nil)
    #expect(throws: CherryProjectFile.RemoteProjectFileError.self) {
        try CherryProjectFile.upsertCommand(ProjectCommandDefinition(name: "dev", command: "make"), projectRoot: key)
    }
    #expect(throws: CherryProjectFile.RemoteProjectFileError.self) {
        try CherryProjectFile.writeFeatureSettings(ProjectFeatureSettings(notesEnabled: true, todosEnabled: false), projectRoot: key)
    }
    // A command's directory is resolved against the project's path there.
    #expect(ProjectCommandDefinition(name: "dev", command: "make", workingDirectory: "web")
        .resolvedWorkingDirectory(projectRoot: key) == "/Users/me/work/app/web")
    #expect(ProjectCommandDefinition(name: "dev", command: "make")
        .resolvedWorkingDirectory(projectRoot: key) == "/Users/me/work/app")
    #expect(ProjectCommandDefinition(name: "dev", command: "make", workingDirectory: "~/other")
        .resolvedWorkingDirectory(projectRoot: key) == "~/other")
    // Opening it in an editor does nothing: the folder is not here.
    var opened = false
    ExternalEditorLauncher { _, _ in opened = true }
        .open(projectRoot: key, with: InstalledEditor(
            editor: ExternalEditorCatalog.all[0], bundleIdentifier: "dev.zed.Zed",
            appURL: URL(fileURLWithPath: "/Applications/Zed.app")
        ))
    #expect(!opened)
}

@MainActor
@Test func aWorkspaceOfAProjectOnAnotherMacKeepsItsKeyAndStartsInItsPathThere() {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/work/app").key
    let workspace = TerminalWorkspace(projectRoot: key, createInitialSession: false)
    #expect(workspace.projectRoot == key)
    #expect(workspace.launchRoot == "/Users/me/work/app")
    // A local project: its launch root is its directory, as before.
    let local = TerminalWorkspace(projectRoot: NSTemporaryDirectory(), createInitialSession: false)
    #expect(local.launchRoot == local.projectRoot)
}
