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

// MARK: - Abandoned files

/// Once the launch's windows opened, the saved tabs of This Mac's windows
/// other than primaries that the launch did not read as open and that were
/// written before it (a crash between a close's save and its removal, a run
/// of an older build) are removed, with their frames. Never before (their
/// windows load on the store's queue), and never a listed window's, one
/// written since, a primary's, a device project's or one this version
/// cannot use.
@Test @MainActor func abandonedFilesOfOtherWindowsAreRemovedOnceTheLaunchsWindowsOpened() async throws {
    let root = try canonicalTemporaryDirectory("cherry-abandoned-windows")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-abandoned-windows-store")
    let suite = "CherryTests.AbandonedWindowFrames.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
        defaults.removePersistentDomain(forName: suite)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let key = repositoryKey(root)
    let device = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let listed = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let abandoned = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let unusable = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let deviceWindow = ProjectWindowValue(projectRoot: device, windowID: UUID())
    let newer = ProjectWindowValue(projectRoot: key, windowID: UUID())
    func fileURL(_ window: ProjectWindowValue) -> URL {
        store.stateFileURL(repositoryRoot: window.projectRoot, windowID: window.windowID)
    }
    // The last run's files, from an hour before this launch.
    let saved: [ProjectWindowValue] = [.primary(key), listed, abandoned, unusable, deviceWindow]
    for (index, window) in saved.enumerated() {
        var record = state(window.projectRoot, windowID: window.windowID, sessions: [boundRecord(sessionID: "s-\(index)")])
        if window == unusable { record.version = RepositoryStateRecord.currentVersion + 1 }
        try WorkspaceStateStore.write(record, to: fileURL(window))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: fileURL(window).path)
    }
    for window in [listed, abandoned] {
        let windowID = try #require(window.windowID)
        defaults.set("0 0 640 400 0 0 1440 900 ", forKey: ProjectWindowFrameStore.key(projectRoot: root.path, windowID: windowID))
        frames.setFullScreen(true, projectRoot: root.path, windowID: windowID)
    }
    // The list it read names the primary and one other window.
    store.saveOpenProjectWindows([listed, .primary(key)], synchronously: true)

    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = .seconds(60)
    registry.configureWindowFrames(frames)
    registry.configureWorkspacePersistence(store: store)
    // A window opened since (File › New Window) saved as it claimed.
    store.saveSynchronously(state(key, windowID: newer.windowID, sessions: [boundRecord(sessionID: "s-newer")]))
    let reopened = registry.takeProjectWindowsToReopen()
    #expect(reopened == [listed, .primary(key)])

    registry.openLaunchWindows([listed]) { _ in }
    registry.removeAbandonedWindowStatesOnceLaunchWindowsOpened()
    try await Task.sleep(for: .milliseconds(200))
    store.flush()
    #expect(FileManager.default.fileExists(atPath: fileURL(abandoned).path))

    // The launch's window registers and shows: the launch's windows opened.
    windows.open(listed)
    #expect(await eventually {
        defaults.object(forKey: ProjectWindowFrameStore.fullScreenKey(projectRoot: root.path, windowID: abandoned.windowID)) == nil
    })
    #expect(!FileManager.default.fileExists(atPath: fileURL(abandoned).path))
    #expect(frames.frameDescriptor(projectRoot: root.path, windowID: abandoned.windowID) == nil)
    for window in [ProjectWindowValue.primary(key), listed, unusable, deviceWindow, newer] {
        #expect(FileManager.default.fileExists(atPath: fileURL(window).path), "\(window)")
    }
    #expect(frames.frameDescriptor(projectRoot: root.path, windowID: listed.windowID) != nil)
    #expect(frames.isFullScreen(projectRoot: root.path, windowID: listed.windowID))

    // Once per run.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: fileURL(newer).path)
    registry.removeAbandonedWindowStatesOnceLaunchWindowsOpened()
    try await Task.sleep(for: .milliseconds(200))
    store.flush()
    #expect(FileManager.default.fileExists(atPath: fileURL(newer).path))
}

/// The launch's saved windows that cannot open (their folder is missing:
/// an unmounted volume) or that never register while it opens them stay
/// saved as open, with their tabs: they reopen at a later launch, and that
/// launch's sweep never takes their files for abandoned.
@Test @MainActor func launchWindowsThatCannotOpenStaySavedAsOpenAndAreNeverSwept() async throws {
    let root = try canonicalTemporaryDirectory("cherry-carried-windows")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-carried-windows-store")
    let volume = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-unmounted-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let key = repositoryKey(root)
    let missing = volume.appendingPathComponent("app").path
    let primary = ProjectWindowValue.primary(key)
    let neverRegistered = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let missingPrimary = ProjectWindowValue.primary(missing)
    let missingOther = ProjectWindowValue(projectRoot: missing, windowID: UUID())
    let saved = [primary, neverRegistered, missingPrimary, missingOther]
    func fileURL(_ window: ProjectWindowValue) -> URL {
        store.stateFileURL(repositoryRoot: window.projectRoot, windowID: window.windowID)
    }
    for (index, window) in saved.enumerated() {
        try WorkspaceStateStore.write(
            state(window.projectRoot, windowID: window.windowID, sessions: [boundRecord(sessionID: "s-\(index)")]),
            to: fileURL(window)
        )
    }
    store.saveOpenProjectWindows(saved, synchronously: true)

    // This launch: the missing folder's windows cannot open, and the
    // project's other window never registers.
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = .milliseconds(50)
    registry.scheduleLaunchWindowTurn = { $0() }
    registry.configureWorkspacePersistence(store: store)
    #expect(registry.takeProjectWindowsToReopen() == [primary, neverRegistered])
    registry.openLaunchWindows([primary, neverRegistered]) { window in
        if window == primary { windows.open(window) }
    }
    var opened = false
    registry.whenLaunchWindowsOpened { opened = true }
    #expect(await eventually { opened })
    #expect(registry.pendingLaunchWindows.isEmpty)
    // (The registered window is saved as the registry resolves its root:
    // the test registers it with no repository.)
    let carried = [neverRegistered, missingPrimary, missingOther]
    store.flush()
    #expect(store.loadOpenProjectWindows().count == saved.count)
    #expect(Set(store.loadOpenProjectWindows()).isSuperset(of: carried))
    // The missing folder's windows are the project's windows still, for
    // its primary that the user opens once the folder is back.
    let reopened = windows.open(missingPrimary)
    #expect(!registry.isLastWindowOfProject(reopened.window))
    store.flush()
    #expect(store.loadOpenProjectWindows().count == saved.count)
    #expect(Set(store.loadOpenProjectWindows()).isSuperset(of: carried))

    // The next launch reads them as open: its sweep keeps their files.
    for window in saved {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: fileURL(window).path
        )
    }
    let next = ProjectWindowRegistry()
    next.abandonedWindowStatesSweepDelay = .zero
    next.configureWorkspacePersistence(store: store)
    next.removeAbandonedWindowStatesOnceLaunchWindowsOpened()
    try await Task.sleep(for: .milliseconds(300))
    store.flush()
    for window in saved {
        #expect(FileManager.default.fileExists(atPath: fileURL(window).path), "\(window)")
    }
}

/// With no open window list it can use (none, unreadable, of another
/// version), the launch takes no window's file for abandoned. A window no
/// list names whose project has no listed window and whose primary file
/// has no tabs (its last close could not move them) becomes the primary's,
/// with its frame; an older one of the project is then removed.
@Test @MainActor func theSweepTakesNothingWithoutAListAndGivesAProjectWithoutTabsItsAbandonedWindow() async throws {
    let root = try canonicalTemporaryDirectory("cherry-sweep-list")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-sweep-list-store")
    let suite = "CherryTests.SweepList.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
        defaults.removePersistentDomain(forName: suite)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let key = repositoryKey(root)
    let newest = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let older = ProjectWindowValue(projectRoot: key, windowID: UUID())
    let newestTab = boundRecord(sessionID: "s-newest")
    func fileURL(_ window: ProjectWindowValue) -> URL {
        store.stateFileURL(repositoryRoot: window.projectRoot, windowID: window.windowID)
    }
    try WorkspaceStateStore.write(state(key, sessions: []), to: fileURL(.primary(key)))
    try WorkspaceStateStore.write(state(key, windowID: newest.windowID, sessions: [newestTab]), to: fileURL(newest))
    try WorkspaceStateStore.write(state(key, windowID: older.windowID, sessions: [boundRecord(sessionID: "s-older")]), to: fileURL(older))
    for (window, age) in [(ProjectWindowValue.primary(key), 3_600.0), (newest, 3_600), (older, 7_200)] {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: fileURL(window).path
        )
    }
    let newestFrame = "360 200 900 560 0 0 1440 900 "
    defaults.set(newestFrame, forKey: ProjectWindowFrameStore.key(projectRoot: root.path, windowID: newest.windowID))
    func sweep() async throws {
        let registry = ProjectWindowRegistry()
        registry.abandonedWindowStatesSweepDelay = .zero
        registry.configureWindowFrames(frames)
        registry.configureWorkspacePersistence(store: store)
        registry.removeAbandonedWindowStatesOnceLaunchWindowsOpened()
        try await Task.sleep(for: .milliseconds(300))
        store.flush()
    }

    // A list this version cannot use (set aside), then none at all.
    try Data("{ not json".utf8).write(to: store.openProjectWindowsFileURL)
    try await sweep()
    #expect(!FileManager.default.fileExists(atPath: store.openProjectWindowsFileURL.path))
    try await sweep()
    for window in [newest, older] {
        #expect(FileManager.default.fileExists(atPath: fileURL(window).path))
    }

    // A list naming no window of the project.
    store.saveOpenProjectWindows([], synchronously: true)
    try await sweep()
    #expect(!FileManager.default.fileExists(atPath: fileURL(newest).path))
    #expect(!FileManager.default.fileExists(atPath: fileURL(older).path))
    let moved = try #require(store.load(repositoryRoot: key))
    #expect(moved.windowID == nil)
    #expect(moved.worktrees.flatMap(\.sessions).map(\.id) == [newestTab.id])
    #expect(defaults.string(forKey: ProjectWindowFrameStore.key(projectRoot: root.path)) == newestFrame)
    #expect(frames.frameDescriptor(projectRoot: root.path, windowID: newest.windowID) == nil)
}

/// A project whose only launch window is still to register (not its
/// primary) counts as open: showing the project (Open Project, `open_project`,
/// a link) brings that window forward once it came on screen, instead of
/// opening the primary beside it, and a window opened with no value (a URL
/// event's) does not claim the primary meanwhile.
@Test @MainActor func aProjectWhoseLaunchWindowIsStillToOpenIsShownThereNotInANewPrimary() async throws {
    let root = try canonicalTemporaryDirectory("cherry-pending-project")
    let elsewhere = try canonicalTemporaryDirectory("cherry-pending-project-front")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = nil
    registry.scheduleLaunchWindowTurn = { $0() }
    let front = ProjectWindowValue.primary(elsewhere.path)
    let pending = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    var openLater: (@MainActor () -> Void)?
    var pendingWindow: NSWindow?
    registry.openLaunchWindows([front, pending], beforeLaterWindows: { openLater = $0 }) { value in
        let opened = windows.open(value)
        if value == pending { pendingWindow = opened.window }
    }
    #expect(await eventually { openLater != nil })
    #expect(registry.pendingLaunchWindows == [pending])
    #expect(!registry.hasWindow(for: root.path))

    #expect(registry.focus(projectRoot: root.path))
    #expect(!windows.open(.primary(root.path), implicit: true).claimed)
    #expect(windows.focused.isEmpty)

    let openLaterNow = try #require(openLater)
    openLaterNow()
    let window = try #require(pendingWindow)
    #expect(registry.hasWindow(pending))
    #expect(await eventually { windows.focused.last === window })
    // Registered now: the project opens there, as any open project does.
    #expect(registry.focus(projectRoot: root.path))
}

/// A second copy of the app (its store disabled: another copy holds the
/// instance lock) leaves the holder's saved frames as they are when its
/// windows close: its project's last window, not the primary, moves no
/// frame or full screen to the primary's keys.
@Test @MainActor func aSecondCopysClosedWindowsLeaveTheHoldersFramesAlone() throws {
    let directory = try canonicalTemporaryDirectory("cherry-second-copy-close")
    let root = try canonicalTemporaryDirectory("cherry-second-copy-close-project")
    let suite = "CherryTests.SecondCopyClose.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
    let lockURL = directory.appendingPathComponent("instance.lock")
    let holder = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
    #expect(holder.isHeld)
    defer { holder.release() }
    let lock = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces"), instanceLock: lock)
    #expect(!store.isEnabled)
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let holderFrame = "120 140 800 500 0 0 1440 900 "
    defaults.set(holderFrame, forKey: ProjectWindowFrameStore.key(projectRoot: root.path))
    frames.setFullScreen(true, projectRoot: root.path)

    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = nil
    registry.enterFullScreen = { _, done in done() }
    registry.configureWindowFrames(frames)
    registry.setWorkspaceStateStoreForTesting(store)
    let windowID = UUID()
    let repository = RepositoryWorkspace(projectRoot: root.path, windowID: windowID)
    defer { repository.closeAllSessions(intent: .windowClosed) }
    let window = makeResizableWindow(NSRect(x: 360, y: 200, width: 900, height: 560))
    #expect(registry.register(
        window: window, projectRoot: root.path, windowID: windowID, workspace: repository.workspace,
        repository: repository, todoStore: nil, chromeState: nil
    ))
    #expect(registry.closedWindowState(
        of: ProjectWindowKey(root: root.path, windowID: windowID), repository: repository
    ) == .leftAsSaved)
    registry.windowDidClose(window, projectRoot: root.path, repository: repository)
    #expect(defaults.string(forKey: ProjectWindowFrameStore.key(projectRoot: root.path)) == holderFrame)
    #expect(frames.isFullScreen(projectRoot: root.path))
}

// MARK: - The registry

/// The session the fake host lists for a saved tab.
private func listed(_ record: WorkspaceSessionRecord) -> HostedSessionInfo {
    HostedSessionInfo(
        id: record.hosted?.sessionID ?? "", name: record.title, cwd: record.workingDirectory, pid: 5,
        owner: "CherryTests", tags: [PersistentSessionTag.tab: record.id.uuidString]
    )
}

/// The windows a test registers, each with a workspace that runs nothing
/// (the registry holds them weakly, as their scenes do).
@MainActor
private final class TestWindows {
    let registry: ProjectWindowRegistry
    private(set) var windows: [(window: NSWindow, value: ProjectWindowValue, workspace: TerminalWorkspace)] = []
    /// The windows `focus` brought forward, in order.
    private(set) var focused: [NSWindow] = []

    init(_ registry: ProjectWindowRegistry = ProjectWindowRegistry()) {
        self.registry = registry
        registry.bringWindowForward = { [unowned self] in focused.append($0) }
    }

    /// Registers a new window for `value`, as its binder does.
    @discardableResult
    func open(
        _ value: ProjectWindowValue,
        implicit: Bool = false,
        window: NSWindow = testWindow(),
        workspace: TerminalWorkspace? = nil,
        todoStore: ProjectTodoStore? = nil,
        chromeState: ProjectWindowChromeState? = nil
    ) -> (claimed: Bool, window: NSWindow, workspace: TerminalWorkspace) {
        let workspace = workspace ?? TerminalWorkspace(projectRoot: value.projectRoot, createInitialSession: false)
        windows.append((window, value, workspace))
        let claimed = register(window, value, implicit: implicit, workspace: workspace, todoStore: todoStore, chromeState: chromeState)
        return (claimed, window, workspace)
    }

    /// Registers `window` again (every update of its view does).
    @discardableResult
    func register(
        _ window: NSWindow,
        _ value: ProjectWindowValue,
        implicit: Bool = false,
        workspace: TerminalWorkspace,
        todoStore: ProjectTodoStore? = nil,
        chromeState: ProjectWindowChromeState? = nil
    ) -> Bool {
        registry.register(
            window: window, projectRoot: value.projectRoot, windowID: value.windowID, implicit: implicit,
            workspace: workspace, todoStore: todoStore, chromeState: chromeState
        )
    }

    func close(_ window: NSWindow) {
        guard let index = windows.firstIndex(where: { $0.window === window }) else { return }
        let closing = windows.remove(at: index)
        registry.unregister(window: window, projectRoot: closing.value.projectRoot)
        closing.workspace.closeAllSessions(intent: .windowClosed)
        window.close()
    }

    func closeAll() {
        windows.map(\.window).forEach(close)
    }
}

@Test @MainActor func twoWindowsOfOneProjectRegisterApartAndComeBackAtTheirOwnFrames() throws {
    let suite = "CherryTests.TwoWindowFrames.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let root = try canonicalTemporaryDirectory("cherry-two-window-frames")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-two-window-frames-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let primary = ProjectWindowValue.primary(root.path)
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    let saved = [NSRect(x: 120, y: 140, width: 800, height: 500), NSRect(x: 360, y: 200, width: 900, height: 560)]

    // The last run: the project's primary window and another one, each
    // moved and resized.
    let lastRun = TestWindows()
    defer { lastRun.closeAll() }
    lastRun.registry.configureWindowFrames(frames)
    lastRun.registry.setWorkspaceStateStoreForTesting(store)
    let first = lastRun.open(primary, window: makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200)))
    let second = lastRun.open(other, window: makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200)))
    #expect(first.claimed && second.claimed)
    // Each is its own window: neither took the other's place.
    #expect(lastRun.registry.hasWindow(primary))
    #expect(lastRun.registry.hasWindow(other))
    #expect(!lastRun.registry.hasWindow(ProjectWindowValue(projectRoot: root.path, windowID: UUID())))
    #expect(lastRun.registry.hasWindow(for: root.path))
    #expect(lastRun.registry.allWorkspaces().count == 2)
    #expect(lastRun.registry.key(of: second.window) == ProjectWindowKey(root: root.path, windowID: other.windowID))
    // Registering again claims nothing new; another window never takes
    // either's key.
    #expect(lastRun.register(second.window, other, workspace: second.workspace))
    #expect(!lastRun.open(other).claimed)
    #expect(!lastRun.open(primary).claimed)
    for (window, frame) in zip([first.window, second.window], saved) {
        window.setFrame(frame, display: false)
    }
    #expect(frames.frameDescriptor(projectRoot: root.path) == first.window.frameDescriptor)
    #expect(frames.frameDescriptor(projectRoot: root.path, windowID: other.windowID) == second.window.frameDescriptor)
    // Both are saved as open, the one active last first.
    store.flush()
    #expect(store.loadOpenProjectWindows() == [primary, other])
    // Closing one leaves the other.
    lastRun.close(second.window)
    #expect(lastRun.registry.hasWindow(primary))
    #expect(!lastRun.registry.hasWindow(other))
    store.flush()
    #expect(store.loadOpenProjectWindows() == [primary])
    lastRun.close(first.window)

    // The next run opens them the other way round: each at its own frame.
    let nextRun = TestWindows()
    defer { nextRun.closeAll() }
    nextRun.registry.configureWindowFrames(frames)
    let reopenedOther = nextRun.open(other, window: makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200)))
    #expect(reopenedOther.claimed)
    #expect(reopenedOther.window.frame == saved[1])
    let reopenedPrimary = nextRun.open(primary, window: makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200)))
    #expect(reopenedPrimary.claimed)
    #expect(reopenedPrimary.window.frame == saved[0])
}

/// A window opened with no value (SwiftUI's own, a URL event, onboarding)
/// claims its project's primary window only while none of the project's
/// windows is open; a window opened for a value claims its own key while
/// it is free.
@Test @MainActor func aWindowOpenedWithNoProjectClaimsOneOnlyWhileNoneOfItsWindowsIsOpen() throws {
    let root = try canonicalTemporaryDirectory("cherry-implicit-window")
    let elsewhere = try canonicalTemporaryDirectory("cherry-implicit-window-elsewhere")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let windows = TestWindows()
    defer { windows.closeAll() }
    let primary = ProjectWindowValue.primary(root.path)
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())

    // None of the project's windows is open: it claims the primary.
    let implicit = windows.open(primary, implicit: true)
    #expect(implicit.claimed)
    #expect(windows.registry.hasWindow(primary))
    // Now another such window is refused (its binder closes it).
    #expect(!windows.open(primary, implicit: true).claimed)
    // A window opened for another window of the project claims it.
    let explicit = windows.open(other)
    #expect(explicit.claimed)
    // The first keeps its key as its view updates.
    #expect(windows.register(implicit.window, primary, implicit: true, workspace: implicit.workspace))

    // Its primary closed; the project's other window is open: a window with
    // no value does not take the free primary, a window opened for it does.
    windows.close(implicit.window)
    #expect(!windows.open(primary, implicit: true).claimed)
    #expect(!windows.registry.hasWindow(primary))
    #expect(windows.open(primary).claimed)
    #expect(windows.registry.hasWindow(primary))
    // Another project's windows are not this one's.
    #expect(windows.open(.primary(elsewhere.path), implicit: true).claimed)
    #expect(windows.registry.hasWindow(other))
}

/// The launch reopens every saved window of a project: the most recently
/// active project first, its window active last first; the others stay
/// pending (open for the saved list) until each registers, and one window
/// showing does not end the wait for another of its project.
@Test @MainActor func theLaunchReopensEveryWindowOfAProjectItsMostRecentlyActiveFirst() async throws {
    let app = try canonicalTemporaryDirectory("cherry-launch-app")
    let lib = try canonicalTemporaryDirectory("cherry-launch-lib")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-launch-windows-store")
    defer {
        for directory in [app, lib, storeDirectory] { try? FileManager.default.removeItem(at: directory) }
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let appOther = ProjectWindowValue(projectRoot: app.path, windowID: UUID())
    // The last run's windows, the one active last first: the lib's, then
    // the app's other window and its primary.
    let saved: [ProjectWindowValue] = [.primary(lib.path), appOther, .primary(app.path)]
    for (index, window) in saved.enumerated() {
        store.saveSynchronously(state(window.projectRoot, windowID: window.windowID, sessions: [boundRecord(sessionID: "s-\(index)")]))
    }
    store.saveOpenProjectWindows(saved, synchronously: true)

    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = .seconds(60)
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    registry.configureWorkspacePersistence(store: store)
    #expect(registry.savedWindowsLaunchPlan() == .reopen(saved))

    // The app was the project active last (`ProjectRecencyStore`): its
    // first window in saved order, its most recently active, opens first.
    let lastOpened = [lib.path: Date(timeIntervalSince1970: 10), app.path: Date(timeIntervalSince1970: 20)]
    let ordered = LaunchWindowOrder.frontFirst(saved) { lastOpened[$0.projectRoot] }
    #expect(ordered == [appOther, .primary(lib.path), .primary(app.path)])
    var opened: [ProjectWindowValue] = []
    var proceed: (@MainActor () -> Void)?
    registry.openLaunchWindows(ordered, beforeLaterWindows: { proceed = $0 }) { value in
        opened.append(value)
        // The front window registers as it is built; the test registers
        // the others itself, later.
        if value == ordered[0] { windows.open(value) }
    }
    var allOpened = false
    registry.whenLaunchWindowsOpened { allOpened = true }
    #expect(opened == [appOther])
    #expect(registry.pendingLaunchWindows == [.primary(lib.path), .primary(app.path)])
    registry.flushWorkspacePersistence()
    #expect(store.loadOpenProjectWindows() == ordered)

    // The app's other window showed; its primary has not.
    var shown: [ProjectWindowValue] = []
    for value in ordered {
        registry.whenLaunchWindowShown(value, waitingAtMost: .seconds(60)) { shown.append(value) }
    }
    #expect(shown == [appOther])
    #expect(await eventually { proceed != nil })
    let proceedNow = try #require(proceed)
    proceedNow()
    #expect(turns.count == 1)
    turns.removeFirst()()
    #expect(opened == ordered)
    // Opened, not registered yet: still pending.
    #expect(registry.pendingLaunchWindows == [.primary(lib.path), .primary(app.path)])
    #expect(!allOpened)
    windows.open(.primary(lib.path))
    #expect(registry.pendingLaunchWindows == [.primary(app.path)])
    #expect(shown == [appOther, .primary(lib.path)])
    windows.open(.primary(app.path))
    #expect(registry.pendingLaunchWindows.isEmpty)
    #expect(shown == [appOther, .primary(lib.path), .primary(app.path)])
    #expect(await eventually { allOpened })
    // Nothing is left to reopen.
    #expect(registry.savedWindowsLaunchPlan() == nil)
}

/// A quit (one that ends sessions) before a project's later launch window
/// registered ends the sessions of that window's own file, as the launch
/// read it: the quit reads no file, and never the primary's, whose window
/// is open.
@Test @MainActor func aQuitBeforeAProjectsLaterWindowOpenedEndsTheSessionsOfItsOwnFile() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let root = try canonicalTemporaryDirectory("cherry-launch-quit-window")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-launch-quit-window-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    let primaryTab = boundRecord(title: "Primary", sessionID: "s-primary")
    let otherTab = boundRecord(title: "Other", sessionID: "s-other")
    store.saveSynchronously(state(root.path, sessions: [primaryTab]))
    store.saveSynchronously(state(root.path, windowID: other.windowID, sessions: [otherTab]))
    store.saveOpenProjectWindows([.primary(root.path), other], synchronously: true)
    harness.fake.sessions = [listed(primaryTab), listed(otherTab)]

    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = .seconds(60)
    registry.launchWindowHosting = harness.hosting
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    registry.configureWorkspacePersistence(store: store)
    let reopened = registry.takeProjectWindowsToReopen()
    #expect(reopened == [.primary(root.path), other])
    // Read at launch: the quit reads no file.
    try FileManager.default.removeItem(at: store.stateFileURL(repositoryRoot: root.path, windowID: other.windowID))

    var proceed: (@MainActor () -> Void)?
    registry.openLaunchWindows(reopened, beforeLaterWindows: { proceed = $0 }) { value in
        // Only the project's primary window registers before the quit.
        if value.isPrimary { windows.open(value) }
    }
    #expect(await eventually { proceed != nil })
    #expect(registry.pendingLaunchWindows == [other])
    #expect(registry.localSessionsEndedByAQuit().map(\.sessionID) == ["s-other"])
    registry.tearDownForQuit(intent: .appQuitEndingSessions)
    #expect(await harness.fake.wait { harness.requestIDs("kill").contains("s-other") })
    #expect(!harness.requestIDs("kill").contains("s-primary"))
    // It never opens now, and stays saved as open.
    let proceedNow = try #require(proceed)
    proceedNow()
    turns.forEach { $0() }
    #expect(registry.pendingLaunchWindows == [other])
    store.flush()
    #expect(store.loadOpenProjectWindows() == [.primary(root.path), other])
}

/// "The project's window" (`focus(projectRoot:)`, `repository(for:)` and
/// the other lookups by root) is its most recently active window; windows
/// a launch reopened that were never active rank by the launch's order.
@Test @MainActor func aProjectsWindowIsItsMostRecentlyActiveOne() async throws {
    let root = try canonicalTemporaryDirectory("cherry-most-recent-window")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-most-recent-window-store")
    let todoDirectory = try canonicalTemporaryDirectory("cherry-most-recent-window-todos")
    let elsewhere = try canonicalTemporaryDirectory("cherry-most-recent-window-elsewhere")
    defer {
        for directory in [root, storeDirectory, todoDirectory, elsewhere] { try? FileManager.default.removeItem(at: directory) }
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    // Two windows of the project, each restoring one saved tab that
    // launches nothing.
    let restorer = RecordingRestorer()
    let repositories = [ProjectWindowValue.primary(root.path), other].enumerated().map { index, value in
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: repositoryKey(root),
            activeWorktreeRoot: root.path,
            worktrees: [WorktreeStateRecord(root: root.path, sessions: [boundRecord(sessionID: "s-\(index)")])],
            windowID: value.windowID
        ))
        return RepositoryWorkspace(
            projectRoot: root.path, windowID: value.windowID, stateStore: store,
            sessionRestorer: restorer.restorer, autoStartCommands: { _ in [] }
        )
    }
    let chromes = [quietChromeState(), quietChromeState()]
    let todoStores = [
        ProjectTodoStore(projectRoot: root.path, storageDirectory: todoDirectory),
        ProjectTodoStore(projectRoot: root.path, storageDirectory: todoDirectory),
    ]
    let windows = TestWindows()
    defer {
        windows.closeAll()
        repositories.forEach { $0.closeAllSessions(intent: .windowClosed) }
    }
    let registry = windows.registry
    var opened: [NSWindow] = []
    for (index, value) in [ProjectWindowValue.primary(root.path), other].enumerated() {
        let window = testWindow()
        opened.append(window)
        #expect(registry.register(
            window: window, projectRoot: value.projectRoot, windowID: value.windowID,
            workspace: repositories[index].workspace, repository: repositories[index],
            todoStore: todoStores[index], chromeState: chromes[index]
        ))
        repositories[index].beginRestoringSavedStateIfNeeded(chromeState: chromes[index])
        await repositories[index].waitForPendingRestores()
    }
    defer { opened.forEach { registry.unregister(window: $0, projectRoot: root.path) } }

    // The primary registered first and was active; the other never was.
    func expectProjectWindow(_ index: Int, _ comment: Comment) {
        #expect(registry.repository(for: root.path) === repositories[index], comment)
        #expect(registry.workspace(for: root.path) === repositories[index].workspace, comment)
        #expect(registry.chromeState(for: root.path) === chromes[index], comment)
        #expect(registry.todoStore(for: root.path) === todoStores[index], comment)
        // However its folder is spelled.
        #expect(registry.repository(for: repositoryKey(root)) === repositories[index], comment)
        #expect(registry.focus(projectRoot: root.path), comment)
        #expect(windows.focused.last === opened[index], comment)
    }
    expectProjectWindow(0, "the primary, active last")
    // The other window becomes key.
    registry.activateWindow(opened[1], workspace: repositories[1].workspace, todoStore: todoStores[1], chromeState: chromes[1])
    expectProjectWindow(1, "the other window, now active last")
    // It closes: the primary is the project's window again.
    registry.unregister(window: opened[1], projectRoot: root.path)
    expectProjectWindow(0, "the window left")
    registry.unregister(window: opened[0], projectRoot: root.path)
    #expect(!registry.focus(projectRoot: root.path))
    #expect(registry.repository(for: root.path) == nil)

    // A launch reopens the project's windows behind the window that is
    // active (another project's): never active, they rank by the
    // launch's order, the one active last before the quit first, though
    // the primary comes first in their stable order.
    let launch = TestWindows()
    defer { launch.closeAll() }
    launch.registry.windowRevealMaximumWait = .seconds(60)
    launch.registry.scheduleLaunchWindowTurn = { $0() }
    let active = launch.open(.primary(elsewhere.path))
    #expect(active.claimed)
    let launchChromes = [other: quietChromeState(), .primary(root.path): quietChromeState()]
    launch.registry.openLaunchWindows([other, .primary(root.path)]) { value in
        launch.open(value, chromeState: launchChromes[value])
    }
    #expect(await eventually { launch.windows.count == 3 })
    #expect(launch.registry.chromeState(for: root.path) === launchChromes[other])
    #expect(launch.registry.focus(projectRoot: root.path))
    #expect(launch.focused.last === launch.windows.first { $0.value == other }?.window)
    // Once it is active, by activation: the primary when it becomes key.
    let primaryWindow = try #require(launch.windows.first { $0.value == .primary(root.path) })
    launch.registry.activateWindow(
        primaryWindow.window, workspace: primaryWindow.workspace, todoStore: nil, chromeState: launchChromes[.primary(root.path)]
    )
    #expect(launch.registry.chromeState(for: root.path) === launchChromes[.primary(root.path)])
}

/// "A tab's window" (notifications, the menu bar, the Omni bar's tabs,
/// terminal links) is the window whose workspace has the tab, whichever of
/// the project's windows was active last; a to-do link goes to the
/// project's most recently active window.
@Test @MainActor func aTabsWindowIsTheOneThatHasIt() throws {
    let root = try canonicalTemporaryDirectory("cherry-tab-window")
    let elsewhere = try canonicalTemporaryDirectory("cherry-tab-window-elsewhere")
    let todoDirectory = try canonicalTemporaryDirectory("cherry-tab-window-todos")
    defer {
        for directory in [root, elsewhere, todoDirectory] { try? FileManager.default.removeItem(at: directory) }
    }
    // To-dos are on for the project.
    try Data("[features]\ntodos = true\n".utf8).write(to: root.appendingPathComponent("cherry.toml"))
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    let chromes = [quietChromeState(), quietChromeState()]
    // One store the project's windows share, as they do (one per project).
    let todos = ProjectTodoStore(projectRoot: root.path, storageDirectory: todoDirectory)
    let first = windows.open(.primary(root.path), todoStore: todos, chromeState: chromes[0])
    let second = windows.open(other, todoStore: todos, chromeState: chromes[1])
    let firstTab = first.workspace.attachHostedSession(localAttachment(sessionID: "s-1"), launchShell: false)
    let secondTab = second.workspace.attachHostedSession(localAttachment(sessionID: "s-2"), launchShell: false)
    _ = first.workspace.attachHostedSession(localAttachment(sessionID: "s-3"), launchShell: false)
    // The primary is the project's most recently active window.
    #expect(registry.chromeState(for: root.path) === chromes[0])

    // A notification's click, the Omni bar's tab row.
    let todo = try todos.create(title: "Ship it", markdown: "")
    chromes[1].selectTodo(id: todo.id)
    #expect(registry.focusSession(sessionID: secondTab.id, projectRoot: nil))
    #expect(windows.focused.last === second.window)
    #expect(second.workspace.selectedSessionID == secondTab.id)
    #expect(chromes[1].isShowingTerminalContent)
    // Narrowed to another project, it is not found.
    #expect(!registry.focusSession(sessionID: secondTab.id, projectRoot: elsewhere.path))
    #expect(registry.focusSession(sessionID: secondTab.id, projectRoot: root.path))

    // The menu bar's row, a toast's Reopen.
    #expect(registry.revealSession(id: firstTab.id))
    #expect(windows.focused.last === first.window)
    #expect(first.workspace.selectedSessionID == firstTab.id)
    #expect(!registry.revealSession(id: UUID()))
    #expect(windows.focused.last === first.window)

    // A terminal link selects its tab in the window that has it, though the
    // primary was active last.
    let terminalLink = CherryDeepLink(projectRoot: root.path, kind: .terminal, targetID: secondTab.id.uuidString)
    #expect(registry.select(terminalLink, projectRoot: root.path))
    #expect(windows.focused.last === second.window)
    // A to-do link: the project's most recently active window, now the
    // other one.
    chromes[1].selectTerminal()
    let todoLink = CherryDeepLink(projectRoot: root.path, kind: .todo, targetID: todo.id.uuidString)
    #expect(registry.select(todoLink, projectRoot: root.path))
    #expect(windows.focused.last === second.window)
    #expect(chromes[1].selectedTodoID == todo.id)
    #expect(chromes[0].selectedTodoID == nil)
    // A tab or to-do no window has selects nothing and focuses nothing.
    let focusCount = windows.focused.count
    #expect(!registry.select(CherryDeepLink(projectRoot: root.path, kind: .terminal, targetID: UUID().uuidString), projectRoot: root.path))
    #expect(!registry.select(CherryDeepLink(projectRoot: root.path, kind: .todo, targetID: UUID().uuidString), projectRoot: root.path))
    #expect(windows.focused.count == focusCount)
}

/// Code that holds a window or a workspace (menu actions, the Omni bar's
/// close, a toast) finds that window and its chrome by identity, never
/// another window of its project.
@Test @MainActor func lookupsByWindowFindThatWindowNotAnotherOfItsProject() throws {
    let root = try canonicalTemporaryDirectory("cherry-window-identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    let other = ProjectWindowValue(projectRoot: root.path, windowID: UUID())
    let chromes = [quietChromeState(), quietChromeState()]
    let first = windows.open(.primary(root.path), chromeState: chromes[0])
    let second = windows.open(other, chromeState: chromes[1])
    // The primary is the project's most recently active window.
    #expect(registry.chromeState(for: root.path) === chromes[0])

    #expect(registry.key(of: second.window) == ProjectWindowKey(root: root.path, windowID: other.windowID))
    #expect(registry.chromeState(for: second.window) === chromes[1])
    #expect(registry.chromeState(for: second.workspace) === chromes[1])
    #expect(registry.window(for: second.workspace) === second.window)
    #expect(registry.window(for: chromes[1]) === second.window)
    #expect(registry.focus(workspace: second.workspace))
    #expect(windows.focused.last === second.window)
    // Focusing it made it the project's window.
    #expect(registry.chromeState(for: root.path) === chromes[1])
    // A window that becomes key, by identity.
    registry.activateWindow(first.window, workspace: first.workspace, todoStore: nil, chromeState: chromes[0])
    #expect(registry.chromeState(for: root.path) === chromes[0])
    #expect(registry.chromeState(for: first.workspace) === chromes[0])

    // A workspace or window no window registered: none.
    let stray = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    #expect(registry.window(for: stray) == nil)
    #expect(registry.chromeState(for: stray) == nil)
    #expect(!registry.focus(workspace: stray))
    #expect(registry.key(of: testWindow()) == nil)
    // Unregistering goes by identity: the other window stays.
    registry.unregister(window: second.window, projectRoot: "/elsewhere")
    #expect(registry.window(for: second.workspace) === second.window)
    windows.close(first.window)
    #expect(registry.chromeState(for: second.window) === chromes[1])
    #expect(registry.chromeState(for: root.path) === chromes[1])
}

// MARK: - File › New Window

/// File › New Window (⌘N, the menu, the Omni bar) opens another window of
/// the project of the window it is chosen in: a fresh id, and the project
/// as that window names it (`repositoryRoot`, here the link it was opened
/// through), whichever project window was active last. Chosen with no
/// project window key, it opens one of the project window active last;
/// with none open, the default project's window. The window it opens
/// restores nothing, looks for no orphans and starts no auto-start command:
/// one new terminal tab in the project's folder, saved as it claims its
/// key. A window of a device Cherry no longer knows opens none, nor does a
/// quitting app.
@Test @MainActor func newWindowOpensAnotherWindowOfTheKeyWindowsProjectWithOneNewTerminal() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-new-window")
    let elsewhere = try canonicalTemporaryDirectory("cherry-new-window-elsewhere")
    let links = try canonicalTemporaryDirectory("cherry-new-window-links")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-new-window-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let link = links.appendingPathComponent("app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.configureWorkspacePersistence(store: store)
    var opened: [ProjectWindowValue] = []
    var defaultWindowsOpened = 0
    registry.newProjectWindowOpener = { opened.append($0) }
    registry.projectWindowOpener = { projectRoot in
        #expect(projectRoot == nil)
        defaultWindowsOpened += 1
    }
    var restored: [String] = []
    var autoStarted: [String] = []
    func repository(_ projectRoot: String, windowID: UUID? = nil, name: String) -> RepositoryWorkspace {
        RepositoryWorkspace(
            projectRoot: projectRoot,
            windowID: windowID,
            backendPolicy: harness.policy,
            stateStore: store,
            sessionRestorer: { request in
                restored.append(name)
                return await harness.restorer(request)
            },
            autoStartCommands: { _ in
                autoStarted.append(name)
                return []
            },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
    }
    var registered: [(window: NSWindow, repository: RepositoryWorkspace)] = []
    func claim(_ repository: RepositoryWorkspace, window: NSWindow = testWindow()) -> NSWindow {
        #expect(registry.register(
            window: window, projectRoot: repository.repositoryRoot, windowID: repository.windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        registered.append((window, repository))
        // Its view asks for auto-start as it appears; its binder claims it.
        repository.autoStartInitialCommandsIfNeeded()
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        return window
    }
    defer {
        for (window, repository) in registered {
            registry.unregister(window: window, projectRoot: repository.repositoryRoot)
            repository.closeAllSessions(intent: .windowClosed)
        }
        harness.cleanUp()
        for directory in [root, elsewhere, links, storeDirectory] { try? FileManager.default.removeItem(at: directory) }
    }

    // No project window is open: the default project's window, as a Dock
    // click opens it.
    #expect(registry.canOpenAnotherWindow(from: nil))
    #expect(registry.openAnotherWindow(from: nil))
    #expect(defaultWindowsOpened == 1)
    #expect(opened.isEmpty)

    // The project's window (it opened the project: its auto-start ran),
    // then another project's, active last.
    let primary = repository(link.path, name: "primary")
    let primaryWindow = claim(primary)
    let other = repository(elsewhere.path, name: "elsewhere")
    let otherWindow = claim(other)
    registry.activateWindow(otherWindow, workspace: other.workspace, todoStore: nil, chromeState: nil)
    #expect(await eventually { Set(autoStarted) == ["primary", "elsewhere"] })

    // Chosen in the project's window: another window of its project, a
    // fresh id each time.
    #expect(registry.canOpenAnotherWindow(from: primaryWindow))
    #expect(registry.openAnotherWindow(from: primaryWindow))
    #expect(registry.openAnotherWindow(from: primaryWindow))
    #expect(opened.map(\.projectRoot) == [primary.repositoryRoot, primary.repositoryRoot])
    #expect(primary.repositoryRoot == repositoryKey(link))
    #expect(opened.allSatisfy { $0.windowID != nil })
    #expect(opened[0].windowID != opened[1].windowID)
    // Chosen with no project window key (Settings, no window at all): the
    // project window active last.
    #expect(registry.openAnotherWindow(from: testWindow()))
    #expect(registry.openAnotherWindow(from: nil))
    #expect(opened.dropFirst(2).map(\.projectRoot) == [other.repositoryRoot, other.repositoryRoot])
    #expect(defaultWindowsOpened == 1)

    // The window its scene builds for the first value: the scene resolves
    // the value's project to itself, so the window keeps its id. A session
    // tagged with its id is no tab's of it: it looks for none.
    let value = opened[0]
    let windowID = try #require(value.windowID)
    #expect(AgentSettings.shared.projectRoot(for: value.projectRoot) == value.projectRoot)
    harness.fake.sessions = [HostedSessionInfo(
        id: "s-tagged", name: "Orphan", cwd: root.path, pid: 300, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: UUID().uuidString,
            PersistentSessionTag.kind: "terminal",
            PersistentSessionTag.project: root.path,
            PersistentSessionTag.window: windowID.uuidString,
        ],
        createdAt: 1_000_000
    )]
    let window = repository(value.projectRoot, windowID: windowID, name: "new")
    _ = claim(window)
    #expect(!window.opensProject)
    #expect(!window.isAwaitingInitialRestore)
    #expect(!window.isRestoringSessions)
    // One new terminal tab, in the project's folder.
    let tab = try #require(window.workspace.sessions.first)
    #expect(window.workspace.sessions.count == 1)
    #expect(tab.kind == .terminal)
    #expect(tab.workingDirectory == root.path)
    #expect(await harness.waitUntilAttached(tab))
    // Saved as it claimed: its own file, and the open window list.
    store.flush()
    let saved = try #require(store.load(repositoryRoot: primary.repositoryRoot, windowID: windowID))
    #expect(saved.worktree(root: root.path)?.sessions.map(\.id) == [tab.id])
    #expect(store.loadOpenProjectWindows().contains(value))
    // Nothing restored, adopted or auto-started.
    try await Task.sleep(for: .milliseconds(200))
    #expect(!restored.contains("new"))
    #expect(harness.hosting.owningTab(of: "s-tagged") == nil)
    #expect(window.workspace.sessions.map(\.id) == [tab.id])
    #expect(!autoStarted.contains("new"))

    // A window of a device Cherry no longer knows opens none.
    let unknownKey = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let unknown = RepositoryWorkspace(
        projectRoot: unknownKey,
        backendPolicy: .remote(
            RemoteDeviceStore.unavailableHosting(for: unknownKey, reason: "Not among your devices.", instanceLock: nil),
            settings: { .native }, hostReconnects: nil
        ),
        sessionRestorer: RemoteDeviceStore.keepingRestorer,
        autoStartCommands: { _ in [] }
    )
    let unknownWindow = claim(unknown)
    let openedBefore = opened.count
    #expect(!unknown.allowsAnotherWindow)
    #expect(!registry.canOpenAnotherWindow(from: unknownWindow))
    #expect(!registry.openAnotherWindow(from: unknownWindow))
    #expect(opened.count == openedBefore)

    // Nor does a quitting app.
    registry.prepareForTermination()
    #expect(!registry.canOpenAnotherWindow(from: primaryWindow))
    #expect(!registry.openAnotherWindow(from: primaryWindow))
    #expect(opened.count == openedBefore)
    registry.cancelTermination()
}

/// A window File › New Window opens comes one step down and to the right
/// of the window it came from, at its size, and windowed: from a window in
/// full screen, at the frame that window goes back to. Its frame is saved
/// under its own key as it opens; the window it came from never moves.
@Test @MainActor func aNewWindowCascadesFromTheWindowItCameFrom() throws {
    let suite = "CherryTests.NewWindowCascade.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = try canonicalTemporaryDirectory("cherry-new-window-cascade")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let frames = ProjectWindowFrameStore(defaults: defaults)
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.configureWindowFrames(frames)
    var enteredFullScreen = 0
    registry.enterFullScreen = { _, done in
        enteredFullScreen += 1
        done()
    }
    var opened: [ProjectWindowValue] = []
    registry.newProjectWindowOpener = { opened.append($0) }
    let repository = RepositoryWorkspace(projectRoot: root.path)
    defer { repository.closeAllSessions(intent: .windowClosed) }
    let sourceFrame = NSRect(x: 220, y: 240, width: 720, height: 460)
    let source = makeResizableWindow(sourceFrame)
    #expect(registry.register(
        window: source, projectRoot: root.path, workspace: repository.workspace, repository: repository,
        todoStore: nil, chromeState: nil
    ))
    defer { registry.unregister(window: source, projectRoot: root.path) }

    /// Opens a window for the value the last New Window asked for, as its
    /// scene does.
    func openNewWindow() throws -> (window: NSWindow, value: ProjectWindowValue) {
        let value = try #require(opened.last)
        let window = makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200))
        #expect(windows.open(value, window: window).claimed)
        return (window, value)
    }
    func expectCascaded(_ window: NSWindow, from frame: NSRect, _ comment: Comment) {
        #expect(window.frame.size == frame.size, comment)
        #expect(window.frame.minX > frame.minX && window.frame.minX < frame.minX + 64, comment)
        #expect(window.frame.maxY < frame.maxY && window.frame.maxY > frame.maxY - 64, comment)
    }

    #expect(registry.openAnotherWindow(from: source))
    let first = try openNewWindow()
    expectCascaded(first.window, from: sourceFrame, "from a window")
    #expect(source.frame == sourceFrame)
    #expect(frames.frameDescriptor(projectRoot: root.path, windowID: first.value.windowID) == first.window.frameDescriptor)
    #expect(!frames.isFullScreen(projectRoot: root.path, windowID: first.value.windowID))

    // The window it came from is in full screen: its frame is the screen's,
    // and the frame it goes back to is the one saved.
    let windowed = NSRect(x: 160, y: 180, width: 640, height: 420)
    let restore = makeResizableWindow(windowed)
    defaults.set(restore.frameDescriptor, forKey: ProjectWindowFrameStore.key(projectRoot: root.path))
    restore.close()
    frames.setFullScreen(true, projectRoot: root.path)
    #expect(registry.openAnotherWindow(from: source))
    let second = try openNewWindow()
    expectCascaded(second.window, from: windowed, "from a window in full screen")
    #expect(!second.window.styleMask.contains(.fullScreen))
    #expect(!frames.isFullScreen(projectRoot: root.path, windowID: second.value.windowID))
    #expect(enteredFullScreen == 0)
    #expect(source.frame == sourceFrame)
}

/// A window whose sheet parent the test sets (AppKit sets one only for a
/// sheet it shows).
@MainActor
private final class SheetWindow: NSWindow {
    weak var parentForTesting: NSWindow?
    override var sheetParent: NSWindow? { parentForTesting }
}

/// File › New Window chosen in a sheet opens another window of the
/// sheet's window's project, though another project's window was active
/// last; chosen while the launch waits for the instance lock with no
/// window open, it opens nothing (the launch opens the windows itself),
/// as a Dock click does not.
@Test @MainActor func newWindowFromASheetUsesItsWindowAndOpensNothingWhileTheLaunchWaitsForTheLock() throws {
    let root = try canonicalTemporaryDirectory("cherry-new-window-sheet")
    let elsewhere = try canonicalTemporaryDirectory("cherry-new-window-sheet-elsewhere")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    var opened: [ProjectWindowValue] = []
    var defaultWindowsOpened = 0
    registry.newProjectWindowOpener = { opened.append($0) }
    registry.projectWindowOpener = { _ in defaultWindowsOpened += 1 }

    // The launch still waits for the instance lock: nothing opens, and
    // nothing beeps.
    let awaitsLock = Recorder(true)
    registry.launchAwaitsInstanceLock = { awaitsLock.value }
    #expect(!registry.canOpenAnotherWindow(from: nil))
    #expect(registry.openAnotherWindow(from: testWindow()))
    #expect(defaultWindowsOpened == 0)
    awaitsLock.value = false
    #expect(registry.openAnotherWindow(from: nil))
    #expect(defaultWindowsOpened == 1)

    let project = RepositoryWorkspace(projectRoot: root.path)
    let other = RepositoryWorkspace(projectRoot: elsewhere.path)
    defer { [project, other].forEach { $0.closeAllSessions(intent: .windowClosed) } }
    let projectWindow = testWindow()
    let otherWindow = testWindow()
    for (window, repository) in [(projectWindow, project), (otherWindow, other)] {
        #expect(registry.register(
            window: window, projectRoot: repository.repositoryRoot, workspace: repository.workspace,
            repository: repository, todoStore: nil, chromeState: nil
        ))
    }
    defer {
        registry.unregister(window: projectWindow, projectRoot: project.repositoryRoot)
        registry.unregister(window: otherWindow, projectRoot: other.repositoryRoot)
    }
    registry.activateWindow(otherWindow, workspace: other.workspace, todoStore: nil, chromeState: nil)
    let sheet = SheetWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    sheet.isReleasedWhenClosed = false
    let alert = SheetWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    alert.isReleasedWhenClosed = false
    sheet.parentForTesting = projectWindow
    alert.parentForTesting = sheet

    #expect(registry.canOpenAnotherWindow(from: alert))
    #expect(registry.openAnotherWindow(from: sheet))
    #expect(registry.openAnotherWindow(from: alert))
    #expect(opened.map(\.projectRoot) == [project.repositoryRoot, project.repositoryRoot])
    // A window that is no project window's sheet: the one active last.
    #expect(registry.openAnotherWindow(from: SheetWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)))
    #expect(opened.last?.projectRoot == other.repositoryRoot)
    #expect(defaultWindowsOpened == 1)
}

/// A window File › New Window opens is transparent from AppKit's first
/// placement until it registers (`LaunchWindowCover.expect(1)`), and the
/// keys typed into it meanwhile go to it once it shows; another window
/// placed meanwhile is not covered.
@Test @MainActor func aNewWindowIsCoveredUntilItRegistersAndGetsTheKeysTypedMeanwhile() throws {
    let root = try canonicalTemporaryDirectory("cherry-new-window-cover")
    defer { try? FileManager.default.removeItem(at: root) }
    let center = NotificationCenter()
    var posted: [NSEvent] = []
    let hold = HiddenWindowKeyHold(installsMonitor: false) { posted += $0 }
    let cover = LaunchWindowCover(fallbackWait: .seconds(60), center: center, keyHold: hold) { window in
        window.identifier?.rawValue.hasPrefix("project") ?? false
    }
    let windows = TestWindows()
    defer { windows.closeAll() }
    let registry = windows.registry
    registry.windowRevealMaximumWait = nil
    registry.launchWindowCover = cover
    var opened: [ProjectWindowValue] = []
    registry.newProjectWindowOpener = { opened.append($0) }
    let repository = RepositoryWorkspace(projectRoot: root.path)
    defer { repository.closeAllSessions(intent: .windowClosed) }
    let source = testWindow()
    #expect(registry.register(
        window: source, projectRoot: root.path, workspace: repository.workspace, repository: repository,
        todoStore: nil, chromeState: nil
    ))
    defer { registry.unregister(window: source, projectRoot: root.path) }
    func projectWindow(_ number: Int) -> NSWindow {
        // Not deferred: its keys name its window number.
        let window = makeResizableWindow(NSRect(x: 0, y: 0, width: 320, height: 200))
        window.identifier = NSUserInterfaceItemIdentifier("project-AppWindow-\(number)")
        return window
    }

    #expect(registry.openAnotherWindow(from: source))
    let value = try #require(opened.last)
    // SwiftUI places the window before it orders it in, and long before
    // its view registers it.
    let window = projectWindow(2)
    center.post(name: NSWindow.didMoveNotification, object: window)
    #expect(window.alphaValue == 0)
    #expect(window.ignoresMouseEvents)
    #expect(hold.isHolding(window))
    let typed = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
    ))
    #expect(hold.take(typed))
    // One window was expected.
    let extra = projectWindow(3)
    defer { extra.close() }
    center.post(name: NSWindow.didMoveNotification, object: extra)
    #expect(extra.alphaValue == 1)
    #expect(posted.isEmpty)

    // It registers: its registration takes it over and shows it, with the
    // keys typed meanwhile.
    #expect(windows.open(value, window: window).claimed)
    #expect(!cover.isCovering(window))
    #expect(window.alphaValue == 1)
    #expect(!window.ignoresMouseEvents)
    #expect(!hold.isHolding(window))
    #expect(posted == [typed])
}
