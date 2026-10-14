import AppKit
import CherryControl
import CryptoKit
import Foundation
import Testing
@testable import Cherry

// Several windows of one project (#22): what each saves, and under which
// names. The project's primary window keeps the names its one window had.

// MARK: - Helpers

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func boundRecord(id: UUID = UUID(), title: String = "Shell", sessionID: String) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: .terminal,
        title: title,
        titleSource: .explicit,
        workingDirectory: "/project",
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
}

private func state(
    _ root: String,
    windowID: UUID? = nil,
    sessions: [WorkspaceSessionRecord]
) -> RepositoryStateRecord {
    RepositoryStateRecord(
        repositoryRoot: root,
        activeWorktreeRoot: root,
        worktrees: [WorktreeStateRecord(root: root, sessions: sessions)],
        savedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowID: windowID
    )
}

private func localAttachment(sessionID: String) -> HostedSessionAttachment {
    HostedSessionAttachment(
        host: .local,
        hostID: "host-a",
        sessionID: sessionID,
        name: "Hosted",
        remoteWorkingDirectory: "/remote",
        executablePath: "/nonexistent/cherry"
    )
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// Restores hosted records as tabs that launch nothing, noting what it was
/// asked for.
@MainActor
private final class RecordingRestorer {
    private(set) var requestedRecordIDs: [[UUID]] = []

    var restorer: WorkspaceSessionRestorer {
        { [self] request in
            requestedRecordIDs.append(request.records.map(\.id))
            return WorkspaceRestoreResult(sessions: request.records.compactMap { record in
                guard let binding = record.hosted else { return nil }
                return request.workspace.makeRestoredHostedSession(
                    localAttachment(sessionID: binding.sessionID),
                    record: record,
                    launchShell: false
                )
            })
        }
    }
}

@MainActor
private func makeResizableWindow(_ frame: NSRect) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.setFrame(frame, display: false)
    return window
}

// MARK: - Names

@Test func aProjectsPrimaryWindowKeepsTheFileAndFrameKeysItsOneWindowHad() throws {
    let directory = try canonicalTemporaryDirectory("cherry-primary-window")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)

    // The state file is named by the root alone, as before windows had ids.
    #expect(WorkspaceStateStore.stateFileName(repositoryRoot: "/repo") == "\(sha256Hex("/repo")).json")
    #expect(WorkspaceStateStore.stateFileName(repositoryRoot: "/repo", windowID: nil)
        == WorkspaceStateStore.stateFileName(repositoryRoot: "/repo"))
    #expect(store.stateFileURL(repositoryRoot: "/repo", windowID: nil) == store.stateFileURL(repositoryRoot: "/repo"))

    // Its record has no `windowID`, so a build before #22 reads the same
    // file, and that build's file is the primary's.
    let saved = state("/repo", sessions: [boundRecord(sessionID: "s-1")])
    store.saveSynchronously(saved)
    #expect(try jsonObject(at: store.stateFileURL(repositoryRoot: "/repo"))["windowID"] == nil)
    #expect(store.load(repositoryRoot: "/repo") == saved)
    #expect(store.load(repositoryRoot: "/repo", windowID: nil)?.windowID == nil)
    #expect(store.hasSavedTabs(repositoryRoot: "/repo"))

    // Its frame keys too.
    #expect(ProjectWindowFrameStore.key(projectRoot: "/repo") == "window.frame./repo")
    #expect(ProjectWindowFrameStore.key(projectRoot: "/repo", windowID: nil) == "window.frame./repo")
    #expect(ProjectWindowFrameStore.fullScreenKey(projectRoot: "/repo") == "window.fullScreen./repo")
    #expect(ProjectWindowFrameStore.fullScreenKey(projectRoot: "/repo", windowID: nil) == "window.fullScreen./repo")

    // The scene's value of a primary window has no id.
    let primary = ProjectWindowValue.primary("/repo")
    #expect(primary.isPrimary)
    #expect(primary.windowID == nil)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(primary)) as? [String: String]
    #expect(encoded == ["projectRoot": "/repo"])
}

@Test func anotherWindowsSavedTabsHaveTheirOwnFileThatSavedTabsNameReads() throws {
    let directory = try canonicalTemporaryDirectory("cherry-other-window")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let windowID = UUID()

    // Named by the root, a NUL and the id: a state file's name (64 hex
    // characters), so builds before #22 read it as one but never load it.
    let name = WorkspaceStateStore.stateFileName(repositoryRoot: "/repo", windowID: windowID)
    #expect(name == "\(sha256Hex("/repo\u{0}\(windowID.uuidString)")).json")
    #expect(name.count == 69)
    #expect(name.dropLast(5).allSatisfy { $0.isHexDigit })
    #expect(name != WorkspaceStateStore.stateFileName(repositoryRoot: "/repo"))
    #expect(name != WorkspaceStateStore.stateFileName(repositoryRoot: "/repo", windowID: UUID()))
    #expect(store.stateFileURL(repositoryRoot: "/repo", windowID: windowID).lastPathComponent == name)

    let shell = boundRecord(sessionID: "s-1")
    let info = HostedSessionInfo(id: "s-1", name: "Shell", cwd: "/repo", owner: "CherryTests")
    let other = HostedSessionInfo(id: "s-2", name: "Shell", cwd: "/repo", owner: "CherryTests")
    #expect(!store.savedTabsName(info, hostID: "host-a", owner: "CherryTests"))

    // Saved under its own name, with its id; the primary's file is not
    // written.
    store.saveSynchronously(state("/repo", windowID: windowID, sessions: [shell]))
    let fileURL = store.stateFileURL(repositoryRoot: "/repo", windowID: windowID)
    #expect(try jsonObject(at: fileURL)["windowID"] as? String == windowID.uuidString)
    #expect(!FileManager.default.fileExists(atPath: store.stateFileURL(repositoryRoot: "/repo").path))

    // Its sessions stay named, so they are not removed as ended.
    #expect(store.savedTabsName(info, hostID: "host-a", owner: "CherryTests"))
    #expect(!store.savedTabsName(other, hostID: "host-a", owner: "CherryTests"))

    // An ended session it names keeps its entry while another is added
    // (entries no state file names go then).
    store.addEndedSessions([(hostID: "host-a", sessionID: "s-1"), (hostID: "host-a", sessionID: "unnamed")])
    store.addEndedSessions([(hostID: "host-a", sessionID: "latest")])
    store.flush()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let ended = try decoder.decode(EndedSessionsRecord.self, from: Data(contentsOf: store.endedSessionsFileURL))
    #expect(ended.entries.map(\.sessionID) == ["s-1", "latest"])
    #expect(store.wasEndedOnPurpose(shell))
}

@Test func aWindowLoadsOnlyItsOwnSavedTabs() throws {
    let directory = try canonicalTemporaryDirectory("cherry-own-tabs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let first = UUID()
    let second = UUID()
    let saved = state("/repo", windowID: first, sessions: [boundRecord(sessionID: "s-1")])
    store.saveSynchronously(saved)

    // Only another window's file exists: the primary has nothing saved,
    // and neither has a third window.
    #expect(store.load(repositoryRoot: "/repo") == nil)
    #expect(!store.hasSavedTabs(repositoryRoot: "/repo"))
    #expect(store.load(repositoryRoot: "/repo", windowID: second) == nil)
    #expect(store.load(repositoryRoot: "/repo", windowID: first) == saved)
    #expect(store.hasSavedTabs(repositoryRoot: "/repo", windowID: first))
    #expect(store.setAsideState(repositoryRoot: "/repo", windowID: first) == nil)

    func setAsideNames(of fileURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(fileURL.lastPathComponent + ".") && $0.hasSuffix(".bak") }
    }

    // A file whose `windowID` is not the window's is another window's:
    // what it names is not this window's, and it is set aside as another
    // root's would be, never written over.
    let firstURL = store.stateFileURL(repositoryRoot: "/repo", windowID: first)
    try WorkspaceStateStore.write(state("/repo", windowID: second, sessions: [boundRecord(sessionID: "s-2")]), to: firstURL)
    #expect(store.setAsideState(repositoryRoot: "/repo", windowID: first) == nil)
    #expect(store.load(repositoryRoot: "/repo", windowID: first) == nil)
    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    #expect(try setAsideNames(of: firstURL).count == 1)
    #expect(try setAsideNames(of: firstURL).allSatisfy { $0.hasPrefix(firstURL.lastPathComponent + ".other-root-") })

    // So is a window's record in the primary's file.
    let primaryURL = store.stateFileURL(repositoryRoot: "/repo")
    try WorkspaceStateStore.write(saved, to: primaryURL)
    #expect(store.load(repositoryRoot: "/repo") == nil)
    #expect(try setAsideNames(of: primaryURL).allSatisfy { $0.hasPrefix(primaryURL.lastPathComponent + ".other-root-") })
    #expect(try setAsideNames(of: primaryURL).count == 1)

    // A window's file of another version is that window's set-aside state,
    // not the primary's.
    var future = state("/repo", windowID: second, sessions: [boundRecord(sessionID: "s-3")])
    future.version = RepositoryStateRecord.currentVersion + 1
    let secondURL = store.stateFileURL(repositoryRoot: "/repo", windowID: second)
    try WorkspaceStateStore.write(future, to: secondURL)
    #expect(store.setAsideState(repositoryRoot: "/repo", windowID: second)?.sessionIDs == ["s-3"])
    #expect(store.setAsideState(repositoryRoot: "/repo", windowID: first) == nil)
    #expect(store.load(repositoryRoot: "/repo", windowID: second) == nil)
    #expect(store.setAsideState(repositoryRoot: "/repo", windowID: second)?.sessionIDs == ["s-3"])
}

// MARK: - The open window list

@Test func theOpenWindowListKeepsProjectRootsForOlderBuilds() throws {
    let directory = try canonicalTemporaryDirectory("cherry-open-window-values")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))
    let app = directory.appendingPathComponent("app", isDirectory: true).path
    let lib = directory.appendingPathComponent("lib", isDirectory: true).path
    for root in [app, lib] {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    let libWindow = ProjectWindowValue(projectRoot: lib, windowID: UUID())
    let appWindow = ProjectWindowValue(projectRoot: app, windowID: UUID())
    let windows = [libWindow, .primary(app), .primary(lib), appWindow]
    #expect(store.loadOpenProjectWindows().isEmpty)

    // Version 1 still, with `projectRoots` (each project once, sorted) for
    // builds before #22 and `windows` in the order given, a primary with no
    // `windowID`.
    store.saveOpenProjectWindows(windows, synchronously: true)
    let object = try jsonObject(at: store.openProjectWindowsFileURL)
    #expect(object["version"] as? Int == 1)
    #expect(object["projectRoots"] as? [String] == [app, lib])
    let listed = try #require(object["windows"] as? [[String: String]])
    #expect(listed == [
        ["projectRoot": lib, "windowID": try #require(libWindow.windowID).uuidString],
        ["projectRoot": app],
        ["projectRoot": lib],
        ["projectRoot": app, "windowID": try #require(appWindow.windowID).uuidString],
    ])
    #expect(store.loadOpenProjectWindows() == windows)
    #expect(store.loadOpenProjectWindowRoots() == [app, lib])

    // Each window reopens only when its own file has tabs, with that file's
    // record: the lib project's primary and the app's other window saved
    // none, though another window of their project did.
    let libTabs = state(lib, windowID: libWindow.windowID, sessions: [boundRecord(sessionID: "s-lib")])
    let appTabs = state(app, sessions: [boundRecord(sessionID: "s-app")])
    store.saveSynchronously(libTabs)
    store.saveSynchronously(appTabs)
    store.saveSynchronously(state(lib, sessions: []))
    let reopened = store.projectWindowsToReopen()
    #expect(reopened.map(\.window) == [libWindow, .primary(app)])
    #expect(reopened.map(\.state) == [libTabs, appTabs])
    #expect(store.projectWindowRootsToReopen() == [lib, app])
    // Each window once; a given list is used as given.
    #expect(store.projectWindowsToReopen([.primary(app), .primary(app), appWindow]).map(\.window) == [.primary(app)])

    // A file of a build before #22 lists primaries only.
    try Data(#"{"version": 1, "projectRoots": ["\#(lib)", "\#(app)"]}"#.utf8).write(to: store.openProjectWindowsFileURL)
    #expect(store.loadOpenProjectWindows() == [.primary(lib), .primary(app)])
    #expect(store.loadOpenProjectWindowRoots() == [lib, app])
    #expect(store.projectWindowsToReopen().map(\.window) == [.primary(app)])

    // The roots' form saves each one's primary, its roots as given.
    store.saveOpenProjectWindowRoots([lib, app, lib], synchronously: true)
    #expect(store.loadOpenProjectWindowRoots() == [lib, app, lib])
    #expect(store.loadOpenProjectWindows() == [.primary(lib), .primary(app), .primary(lib)])
}

// MARK: - Frames

@Test @MainActor func eachWindowsFrameAndFullScreenAreSavedUnderItsOwnKey() throws {
    let suite = "CherryTests.WindowFramesByWindow.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let windowID = UUID()
    #expect(ProjectWindowFrameStore.key(projectRoot: "/p", windowID: windowID) == "window.frame./p#\(windowID.uuidString)")
    #expect(ProjectWindowFrameStore.fullScreenKey(projectRoot: "/p", windowID: windowID)
        == "window.fullScreen./p#\(windowID.uuidString)")

    // Each window's frame is saved as it moves, under its own key.
    let primaryFrame = NSRect(x: 120, y: 140, width: 800, height: 500)
    let otherFrame = NSRect(x: 360, y: 200, width: 900, height: 560)
    let primary = makeResizableWindow(primaryFrame)
    let other = makeResizableWindow(otherFrame)
    defer {
        primary.close()
        other.close()
    }
    let center = NotificationCenter()
    let primarySaver = ProjectWindowFrameSaver(window: primary, projectRoot: "/p", store: frames, center: center)
    let otherSaver = ProjectWindowFrameSaver(window: other, projectRoot: "/p", windowID: windowID, store: frames, center: center)
    center.post(name: NSWindow.didMoveNotification, object: primary)
    center.post(name: NSWindow.didMoveNotification, object: other)
    #expect(frames.frameDescriptor(projectRoot: "/p") == primary.frameDescriptor)
    #expect(frames.frameDescriptor(projectRoot: "/p", windowID: windowID) == other.frameDescriptor)
    #expect(frames.frameDescriptor(projectRoot: "/p", windowID: UUID()) == nil)

    // And each comes back at its own.
    let reopened = makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200))
    defer { reopened.close() }
    #expect(frames.restore(reopened, projectRoot: "/p", windowID: windowID))
    #expect(reopened.frame == otherFrame)
    #expect(frames.restore(reopened, projectRoot: "/p"))
    #expect(reopened.frame == primaryFrame)
    #expect(!frames.restore(reopened, projectRoot: "/p", windowID: UUID()))

    // Full screen too: the other window's is not the primary's.
    center.post(name: NSWindow.didEnterFullScreenNotification, object: other)
    #expect(frames.isFullScreen(projectRoot: "/p", windowID: windowID))
    #expect(defaults.bool(forKey: ProjectWindowFrameStore.fullScreenKey(projectRoot: "/p", windowID: windowID)))
    #expect(!frames.isFullScreen(projectRoot: "/p"))
    center.post(name: NSWindow.didEnterFullScreenNotification, object: primary)
    center.post(name: NSWindow.didExitFullScreenNotification, object: other)
    #expect(frames.isFullScreen(projectRoot: "/p"))
    #expect(!frames.isFullScreen(projectRoot: "/p", windowID: windowID))
    #expect(defaults.object(forKey: ProjectWindowFrameStore.fullScreenKey(projectRoot: "/p", windowID: windowID)) == nil)
    withExtendedLifetime((primarySaver, otherSaver)) {}
}

// MARK: - Saving

@Test @MainActor func twoWindowsOfOneProjectSaveTheirTabsApart() async throws {
    let root = try canonicalTemporaryDirectory("cherry-two-windows")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-two-windows-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let key = repositoryKey(root)
    let windowID = UUID()
    let savedPrimary = boundRecord(title: "Primary", sessionID: "s-primary")
    let savedOther = boundRecord(title: "Other", sessionID: "s-other")
    for (id, record) in [(nil, savedPrimary), (windowID, savedOther)] as [(UUID?, WorkspaceSessionRecord)] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: key,
            activeWorktreeRoot: root.path,
            worktrees: [WorktreeStateRecord(root: root.path, sessions: [record])],
            windowID: id
        ))
    }
    let primaryRestorer = RecordingRestorer()
    let otherRestorer = RecordingRestorer()
    let primary = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: primaryRestorer.restorer,
        autoStartCommands: { _ in [] }
    )
    let other = RepositoryWorkspace(
        projectRoot: root.path,
        windowID: windowID,
        stateStore: store,
        sessionRestorer: otherRestorer.restorer,
        autoStartCommands: { _ in [] }
    )
    defer {
        primary.closeAllSessions(intent: .windowClosed)
        other.closeAllSessions(intent: .windowClosed)
    }
    #expect(primary.windowID == nil)
    #expect(other.windowID == windowID)

    // Each restores only the tabs of its own file.
    for repository in [primary, other] {
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await repository.waitForPendingRestores()
    }
    #expect(primaryRestorer.requestedRecordIDs == [[savedPrimary.id]])
    #expect(otherRestorer.requestedRecordIDs == [[savedOther.id]])
    #expect(primary.workspace.sessions.map(\.id) == [savedPrimary.id])
    #expect(other.workspace.sessions.map(\.id) == [savedOther.id])

    // And saves its tabs there, the other window's file untouched.
    let primaryTab = primary.workspace.attachHostedSession(localAttachment(sessionID: "s-primary-2"), launchShell: false)
    primary.flushPersistentState()
    store.flush()
    #expect(store.load(repositoryRoot: key)?.worktree(root: root.path)?.sessions.map(\.id) == [savedPrimary.id, primaryTab.id])
    #expect(store.load(repositoryRoot: key, windowID: windowID)?.worktree(root: root.path)?.sessions.map(\.id) == [savedOther.id])

    let otherTab = other.workspace.attachHostedSession(localAttachment(sessionID: "s-other-2"), launchShell: false)
    other.flushPersistentState()
    store.flush()
    let otherState = try #require(store.load(repositoryRoot: key, windowID: windowID))
    #expect(otherState.windowID == windowID)
    #expect(otherState.worktree(root: root.path)?.sessions.map(\.id) == [savedOther.id, otherTab.id])
    #expect(other.makeStateRecord().windowID == windowID)
    let primaryState = try #require(store.load(repositoryRoot: key))
    #expect(primaryState.windowID == nil)
    #expect(primaryState.worktree(root: root.path)?.sessions.map(\.id) == [savedPrimary.id, primaryTab.id])
}
