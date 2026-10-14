import AppKit
import Foundation
import Testing
@testable import Cherry

// Sessions of several windows of one project (#22): each window's tabs
// create their sessions tagged with it (`cherry.window`), and each window
// adopts as orphans only the sessions created for it, the project's primary
// window only untagged ones. Against the fake `cherry control`
// (FakeControlHelper); nothing reaches a real cherry-host or the app's real
// Application Support.

// MARK: - Helpers

private func savedTab(id: UUID = UUID(), title: String, sessionID: String, root: String) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: .terminal,
        title: title,
        titleSource: .system,
        workingDirectory: root,
        projectRoot: root,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
}

/// A session of this app's for tab `tab` of `project`, created for the
/// window `window` (nil: the project's primary), or tagged `windowTag`.
private func session(
    _ id: String,
    tab: UUID,
    project: String,
    window: UUID? = nil,
    windowTag: String? = nil,
    createdAt: Date
) -> HostedSessionInfo {
    var tags = [
        PersistentSessionTag.tab: tab.uuidString,
        PersistentSessionTag.kind: "terminal",
        PersistentSessionTag.project: project
    ]
    if let tag = windowTag ?? window?.uuidString { tags[PersistentSessionTag.window] = tag }
    return HostedSessionInfo(
        id: id, name: "Orphan \(id)", cwd: project, pid: 300, owner: "CherryTests", tags: tags,
        createdAt: UInt64(createdAt.timeIntervalSince1970 * 1_000)
    )
}

/// The window tag of the Create that started tab `tabID`'s session, the
/// last one when it was started more than once (nil inside when it has
/// none); nil when no Create did.
@MainActor
private func windowTag(ofCreateFor tabID: UUID, in harness: PersistentHarness) -> String?? {
    let tags = harness.creates()
        .map { $0.json["tags"] as? [String: String] ?? [:] }
        .last { $0[PersistentSessionTag.tab] == tabID.uuidString }
    return tags.map { $0[PersistentSessionTag.window] }
}

@MainActor
private func repository(
    _ harness: PersistentHarness,
    root: URL,
    windowID: UUID? = nil,
    store: WorkspaceStateStore? = nil
) -> RepositoryWorkspace {
    RepositoryWorkspace(
        projectRoot: root.path,
        windowID: windowID,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
}

// MARK: - Tags

/// A window other than the project's primary tags the sessions its tabs
/// create with its id, its first tab's too; the primary's carry no window
/// tag. A session keeps the tag it was created with; restarted in another
/// window, its tab's new session is that window's.
@Test @MainActor func aSecondWindowsSessionsAreTaggedWithItsWindow() async throws {
    let windowID = UUID()
    var request = PersistentSessionRequest(tabID: UUID(), name: "Shell", kind: .terminal, columns: 80, rows: 24)
    #expect(PersistentLocalSessions.tags(for: request)[PersistentSessionTag.window] == nil)
    request.windowID = windowID
    let tags = PersistentLocalSessions.tags(for: request)
    #expect(tags[PersistentSessionTag.window] == windowID.uuidString)
    #expect(PersistentLocalSessions.windowID(of: HostedSessionInfo(id: "s", name: "x", cwd: "/", tags: tags)) == windowID)
    #expect(PersistentLocalSessions.windowID(of: HostedSessionInfo(id: "s", name: "x", cwd: "/")) == nil)

    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-window-tags")
    let primary = repository(harness, root: root)
    // Opened with an id (File › New Window): its first tab is made as its
    // workspace is, before the workspace has set anything on it.
    let second = repository(harness, root: root, windowID: windowID)
    defer {
        primary.closeAllSessions(intent: .windowClosed)
        second.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
    }
    primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    second.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(primary.workspace.windowID == nil)
    #expect(second.workspace.windowID == windowID)
    let primaryTab = try #require(primary.workspace.sessions.first)
    let firstTab = try #require(second.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(primaryTab))
    #expect(await harness.waitUntilAttached(firstTab))
    #expect(windowTag(ofCreateFor: primaryTab.id, in: harness) == .some(nil))
    #expect(windowTag(ofCreateFor: firstTab.id, in: harness) == windowID.uuidString)

    // The primary's session, detached, is shown in the other window
    // (Background Sessions › Open): its tab, with the same id, then
    // restarted there, creates a session of that window.
    let sessionID = try #require(primaryTab.persistentSession?.sessionID)
    primary.workspace.close(primaryTab, allowEmptyWorkspace: true, intent: .userDetachedTab)
    _ = try await harness.control.list()
    let info = try #require(harness.hosting.sessionInfo(sessionID))
    #expect(PersistentLocalSessions.windowID(of: info) == nil)
    let launch = PersistentSessionLaunch(attachment: try #require(harness.hosting.attachment(for: info)), info: info)
    let shown = try #require(second.showBackgroundSession(launch, hosting: harness.hosting))
    #expect(shown.id == primaryTab.id)
    #expect(await harness.waitUntilAttached(shown))
    #expect(harness.creates().count == 2)
    #expect(second.workspace.restart(shown))
    #expect(await harness.fake.wait { harness.creates().count == 3 })
    #expect(windowTag(ofCreateFor: shown.id, in: harness) == windowID.uuidString)
}

// MARK: - Orphans

/// Two windows of a project after a crash: each adopts only the sessions
/// its own tabs started after its last save (its id's, the primary's
/// untagged ones), the primary while the other window has not opened yet
/// too. A session of a window no file names any more, or with a tag no
/// window id reads, is no window's.
@Test @MainActor func eachWindowAdoptsOnlyTheOrphansItsOwnTabsStarted() async throws {
    let other = UUID()
    let tab = UUID()
    let created = Date(timeIntervalSince1970: 1_700_000_100)
    let primaryCriteria = OrphanedSessionCriteria(owner: "CherryTests", savedState: nil, createdBefore: Date())
    let otherCriteria = OrphanedSessionCriteria(owner: "CherryTests", savedState: nil, createdBefore: Date(), windowID: other)
    let untagged = session("s-1", tab: tab, project: "/repo", createdAt: created)
    let otherWindows = session("s-2", tab: tab, project: "/repo", window: other, createdAt: created)
    let unreadable = session("s-3", tab: tab, project: "/repo", windowTag: "not-a-window", createdAt: created)
    #expect(primaryCriteria.orphanTabID(of: untagged) == tab)
    #expect(primaryCriteria.orphanTabID(of: otherWindows) == nil)
    #expect(otherCriteria.orphanTabID(of: otherWindows) == tab)
    #expect(otherCriteria.orphanTabID(of: untagged) == nil)
    #expect(primaryCriteria.orphanTabID(of: unreadable) == nil)
    #expect(otherCriteria.orphanTabID(of: unreadable) == nil)

    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-window-orphans")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-window-orphans-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let primaryEditor = savedTab(title: "Editor", sessionID: "s-primary-editor", root: root.path)
    let otherEditor = savedTab(title: "Editor", sessionID: "s-other-editor", root: root.path)
    for (windowID, editor) in [(nil, primaryEditor), (other, otherEditor)] as [(UUID?, WorkspaceSessionRecord)] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: repositoryKey(root),
            activeWorktreeRoot: root.path,
            worktrees: [WorktreeStateRecord(root: root.path, sessions: [editor], selectedSessionID: editor.id)],
            savedAt: savedAt,
            windowID: windowID
        ))
    }
    let primaryOrphan = UUID()
    let otherOrphan = UUID()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-primary-editor", name: "Editor", cwd: root.path, pid: 10, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: primaryEditor.id.uuidString]),
        HostedSessionInfo(id: "s-other-editor", name: "Editor", cwd: root.path, pid: 11, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: otherEditor.id.uuidString,
                                 PersistentSessionTag.window: other.uuidString]),
        // Opened in each window after its last save; then the app crashed.
        session("s-primary-orphan", tab: primaryOrphan, project: root.path, createdAt: savedAt.addingTimeInterval(5)),
        session("s-other-orphan", tab: otherOrphan, project: root.path, window: other, createdAt: savedAt.addingTimeInterval(6)),
        // A window nothing reopens, and a tag no id reads.
        session("s-gone-window", tab: UUID(), project: root.path, window: UUID(), createdAt: savedAt.addingTimeInterval(7)),
        session("s-unreadable", tab: UUID(), project: root.path, windowTag: "x", createdAt: savedAt.addingTimeInterval(8))
    ]

    // The primary opens first; the other window is still to open.
    let primary = repository(harness, root: root, store: store)
    defer { primary.closeAllSessions(intent: .windowClosed) }
    primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { primary.workspace.sessions.count == 2 })
    await primary.waitUntilSessionsRestored(before: .now + .seconds(5))
    #expect(primary.workspace.sessions.map(\.id) == [primaryEditor.id, primaryOrphan])

    let second = repository(harness, root: root, windowID: other, store: store)
    defer { second.closeAllSessions(intent: .windowClosed) }
    second.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { second.workspace.sessions.count == 2 })
    await second.waitUntilSessionsRestored(before: .now + .seconds(5))
    #expect(second.workspace.sessions.map(\.id) == [otherEditor.id, otherOrphan])

    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.hosting.owningTab(of: "s-gone-window") == nil)
    #expect(harness.hosting.owningTab(of: "s-unreadable") == nil)
    #expect(primary.workspace.sessions.count == 2)
    #expect(second.workspace.sessions.count == 2)
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

/// At launch, a session the saved tabs of a window still to open name is
/// that window's, though it has no window tag and was created after the
/// primary's last save, to the second (an untagged session can be in
/// another window's file: a command handed over at a close, or one opened
/// there from Background Sessions): the primary's look for orphans leaves
/// it to that window, which brings it back in its own tab.
@Test @MainActor func aSessionAWindowStillToOpenNamesIsNotThePrimarysOrphan() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-window-not-orphan")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-window-not-orphan-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let key = repositoryKey(root)
    let other = UUID()
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(title: "Server", sessionID: "s-server", root: root.path)
    for (windowID, tab) in [(nil, editor), (other, server)] as [(UUID?, WorkspaceSessionRecord)] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: key,
            activeWorktreeRoot: root.path,
            worktrees: [WorktreeStateRecord(root: root.path, sessions: [tab], selectedSessionID: tab.id)],
            savedAt: savedAt,
            windowID: windowID
        ))
    }
    let primaryValue = ProjectWindowValue.primary(key)
    let otherValue = ProjectWindowValue(projectRoot: key, windowID: other)
    store.saveOpenProjectWindows([primaryValue, otherValue], synchronously: true)
    // Untagged, and created in the second of the primary's last save.
    let serverSession = session("s-server", tab: server.id, project: root.path, createdAt: savedAt.addingTimeInterval(0.5))
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-editor", name: "Editor", cwd: root.path, pid: 10, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: editor.id.uuidString]),
        serverSession
    ]
    // By its own file alone, the primary would take it for its orphan.
    let primaryCriteria = OrphanedSessionCriteria(
        owner: "CherryTests", savedState: store.load(repositoryRoot: key), createdBefore: Date()
    )
    #expect(primaryCriteria.orphanTabID(of: serverSession) == server.id)

    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = nil
    registry.scheduleLaunchWindowTurn = { $0() }
    let primary = repository(harness, root: root, store: store)
    let second = repository(harness, root: root, windowID: other, store: store)
    let windows = [testWindow(), testWindow()]
    defer {
        windows.forEach { registry.unregister(window: $0, projectRoot: root.path) }
        primary.closeAllSessions(intent: .windowClosed)
        second.closeAllSessions(intent: .windowClosed)
    }
    registry.configureWorkspacePersistence(store: store)
    let reopened = registry.takeProjectWindowsToReopen()
    #expect(reopened == [primaryValue, otherValue])
    var openLater: (@MainActor () -> Void)?
    registry.openLaunchWindows(reopened, beforeLaterWindows: { openLater = $0 }) { value in
        // As each window's binder does: it claims its key, then restores.
        let (repository, window) = value.isPrimary ? (primary, windows[0]) : (second, windows[1])
        #expect(registry.register(
            window: window, projectRoot: root.path, windowID: value.windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    }

    // The primary restores and looks for orphans; the other window is
    // still to open.
    #expect(registry.pendingLaunchWindows == [otherValue])
    await primary.waitUntilSessionsRestored(before: .now + .seconds(5))
    try await Task.sleep(for: .milliseconds(200))
    #expect(primary.workspace.sessions.map(\.id) == [editor.id])
    #expect(harness.hosting.owningTab(of: "s-server") == nil)

    // It opens and brings the session back in its own tab.
    #expect(await eventually { openLater != nil })
    let openLaterWindows = try #require(openLater)
    openLaterWindows()
    #expect(registry.pendingLaunchWindows.isEmpty)
    #expect(await eventually { second.workspace.sessions.map(\.id) == [server.id] && !second.isRestoringSessions })
    #expect(harness.hosting.owningTab(of: "s-server") === second.workspace.sessions.first)
    #expect(primary.workspace.sessions.map(\.id) == [editor.id])
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

/// A window opened this run (File › New Window) saved nothing before: it
/// looks for no orphans, so sessions detached in the project earlier stay
/// Background Sessions', even one tagged with its id.
@Test @MainActor func aWindowOpenedThisRunLooksForNoOrphans() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-new-window-orphans")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-new-window-orphans-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let windowID = UUID()
    let detached = UUID()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        session("s-detached", tab: detached, project: root.path, createdAt: Date(timeIntervalSince1970: 1_000)),
        session("s-tagged", tab: UUID(), project: root.path, window: windowID, createdAt: Date(timeIntervalSince1970: 2_000))
    ]
    // The project's primary window, had it no saved state either, would
    // adopt it: any time counts.
    let primaryCriteria = OrphanedSessionCriteria(owner: "CherryTests", savedState: nil, createdBefore: Date())
    #expect(primaryCriteria.orphanTabID(of: harness.fake.sessions[0]) == detached)

    let window = repository(harness, root: root, windowID: windowID, store: store)
    defer { window.closeAllSessions(intent: .windowClosed) }
    window.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(!window.isRestoringSessions)
    let first = try #require(window.workspace.sessions.first)
    #expect(await harness.waitUntilAttached(first))
    try await Task.sleep(for: .milliseconds(200))
    // Its one new tab. A look for orphans would have taken the session
    // tagged with its id (no saved state: any time counts).
    #expect(window.workspace.sessions.map(\.id) == [first.id])
    #expect(harness.hosting.owningTab(of: "s-detached") == nil)
    #expect(harness.hosting.owningTab(of: "s-tagged") == nil)

    let model = BackgroundSessionsModel(
        localSessions: harness.hosting,
        registry: ProjectWindowRegistry(),
        prefersPersistentLocalSessions: { true },
        closesTabsOnCleanExit: { true },
        presentAlert: { _, _, _ in Issue.record("Nothing asks in these tests") },
        postNotification: { _ in },
        notifiesProgramState: { _ in false },
        isAppActive: { true }
    )
    defer { model.stop() }
    let listed = try await harness.control.list()
    #expect(Set(model.backgroundSessions(in: listed.sessions, hostID: listed.hostID).map(\.id)) == ["s-detached", "s-tagged"])
}

/// A window other than the project's primary is saved as it claims its
/// project, its first tab with it, so a crash right after File › New
/// Window still reopens it; the primary saves at its first change, as a
/// project's one window did.
@Test @MainActor func aWindowOtherThanThePrimaryIsSavedAsItClaims() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-window-saved-at-claim")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-window-saved-at-claim-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.configureWorkspacePersistence(store: store)
    let windowID = UUID()
    let other = repository(harness, root: root, windowID: windowID, store: store)
    let primary = repository(harness, root: root, store: store)
    let otherWindow = testWindow()
    let primaryWindow = testWindow()
    defer {
        registry.unregister(window: otherWindow, projectRoot: root.path)
        registry.unregister(window: primaryWindow, projectRoot: root.path)
        other.closeAllSessions(intent: .windowClosed)
        primary.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let key = repositoryKey(root)
    let otherValue = ProjectWindowValue(projectRoot: key, windowID: windowID)

    // Nothing is saved before it claims its project.
    store.flush()
    #expect(store.load(repositoryRoot: key, windowID: windowID) == nil)
    // As its binder claims it: registered, then its restore begins.
    #expect(registry.register(
        window: otherWindow, projectRoot: root.path, windowID: windowID,
        workspace: other.workspace, repository: other, todoStore: nil, chromeState: nil
    ))
    other.beginRestoringSavedStateIfNeeded(chromeState: nil)
    store.flush()
    let saved = try #require(store.load(repositoryRoot: key, windowID: windowID))
    #expect(saved.windowID == windowID)
    #expect(saved.worktree(root: root.path)?.sessions.map(\.id) == other.workspace.sessions.map(\.id))
    #expect(store.loadOpenProjectWindows() == [otherValue])

    // The primary: not at its claim.
    #expect(registry.register(
        window: primaryWindow, projectRoot: root.path,
        workspace: primary.workspace, repository: primary, todoStore: nil, chromeState: nil
    ))
    primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    store.flush()
    #expect(store.load(repositoryRoot: key) == nil)
    #expect(Set(store.loadOpenProjectWindows()) == [otherValue, .primary(key)])
    // At its first change, after the usual delay.
    let primaryTab = try #require(primary.workspace.sessions.first)
    primaryTab.rename(to: "Notes")
    #expect(await eventually {
        store.flush()
        return store.load(repositoryRoot: key)?.worktree(root: root.path)?.sessions.map(\.title) == ["Notes"]
    })
}
