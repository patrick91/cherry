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
