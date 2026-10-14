import AppKit
import Foundation
import Testing
@testable import Cherry

// Background sessions, the launch notice and the menu bar with several
// windows of one project (#22): what each window shows, and what the launch
// waits for. Against the fake `cherry control` (FakeControlHelper) and test
// registries: nothing reaches a real cherry-host or comes on screen.

// MARK: - Helpers

@MainActor
private func makeModel(
    _ harness: PersistentHarness,
    registry: ProjectWindowRegistry,
    endedSessionGrace: TimeInterval = BackgroundSessionsModel.defaultEndedSessionGrace,
    now: @escaping @MainActor () -> Date = { Date() }
) -> BackgroundSessionsModel {
    BackgroundSessionsModel(
        localSessions: harness.hosting,
        registry: registry,
        prefersPersistentLocalSessions: { true },
        closesTabsOnCleanExit: { true },
        presentAlert: { _, _, _ in Issue.record("Nothing asks in these tests") },
        postNotification: { _ in },
        notifiesProgramState: { _ in false },
        endedSessionGrace: endedSessionGrace,
        now: now,
        isAppActive: { true }
    )
}

/// Registers `window` with `registry` as the window `value` names, showing
/// `workspace`.
@MainActor
private func register(
    _ window: NSWindow,
    _ value: ProjectWindowValue,
    workspace: TerminalWorkspace,
    in registry: ProjectWindowRegistry
) {
    #expect(registry.register(
        window: window, projectRoot: value.projectRoot, windowID: value.windowID,
        workspace: workspace, todoStore: nil, chromeState: quietChromeState()
    ))
}

// MARK: - The launch notice

/// The launch notice waits for every window the launch reopens, each by
/// itself: another window of its project having opened is not it.
@Test @MainActor func theLaunchNoticeWaitsForEveryWindowItExpects() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    let model = makeModel(harness, registry: registry)
    let defaults = privateDefaults("cherry-background-windows-notice")
    let notice = BackgroundSessionsNotice(
        model: model,
        registry: registry,
        isEnabled: { true },
        defaults: defaults,
        canPresent: { _ in true },
        settleDelay: .zero,
        restoreWait: .seconds(10),
        retryDelay: 0.05,
        retries: 2
    )
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let windows = [testWindow(), testWindow()]
    let workspaces = [harness.workspace(), harness.workspace()]
    defer {
        model.stop()
        registry.unregister(window: windows[0], projectRoot: project)
        registry.unregister(window: windows[1], projectRoot: project)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    harness.fake.pendingHolders = 0

    // The launch asked for the project's primary window and another one.
    notice.launchWindowsOpened(expecting: [.primary(project), other])
    register(windows[0], .primary(project), workspace: workspaces[0], in: registry)
    // The primary is open; the other is not: it waits.
    try await Task.sleep(for: .milliseconds(300))
    #expect(notice.phase == .checking)
    register(windows[1], other, workspace: workspaces[1], in: registry)
    #expect(await eventually { notice.phase != .checking })
}

// MARK: - The menu bar

/// The menu bar lists a project's agents in one group, whichever of its
/// windows each runs in (each window's in turn), and a row shows its agent
/// in the window that has it.
@Test @MainActor func theMenuBarListsAProjectsAgentsInOneGroupAcrossItsWindows() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    var focused: [NSWindow] = []
    registry.bringWindowForward = { focused.append($0) }
    let background = makeModel(harness, registry: registry)
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let windows = [testWindow(), testWindow()]
    let workspaces = [harness.workspace(), harness.workspace()]
    defer {
        background.stop()
        registry.unregister(window: windows[0], projectRoot: project)
        registry.unregister(window: windows[1], projectRoot: project)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    register(windows[0], .primary(project), workspace: workspaces[0], in: registry)
    register(windows[1], other, workspace: workspaces[1], in: registry)
    let agents = [
        workspaces[1].addAgentSession(
            agent: AgentToolDefinition(name: "Codex", command: "/bin/cat"), projectRoot: project, select: false
        ),
        workspaces[0].addAgentSession(
            agent: AgentToolDefinition(name: "Claude", command: "/bin/cat"), projectRoot: project, select: false
        ),
    ]
    for agent in agents {
        #expect(await harness.waitUntilAttached(agent))
    }

    let model = MenuBarAgentsModel(registry: registry, background: background)
    #expect(model.groups.count == 1)
    let group = try #require(model.groups.first)
    #expect(group.projectName == harness.project.lastPathComponent)
    // The primary window's agents first, then the other window's.
    #expect(group.items.map(\.id) == [agents[1].id, agents[0].id])

    // Its row shows the other window's agent there, though the primary was
    // active last.
    let row = try #require(group.items.first { $0.id == agents[0].id })
    model.reveal(row)
    #expect(focused.count == 1)
    #expect(focused.last === windows[1])
    #expect(workspaces[1].selectedSessionID == agents[0].id)
}

// MARK: - Which sessions are in the background

/// A session a tab of a project's second window shows is not in the
/// background; detached from it, it is.
@Test @MainActor func aSessionShownInASecondWindowIsNotInTheBackground() async throws {
    let harness = try PersistentHarness()
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let model = makeModel(harness, registry: registry)
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let windows = [testWindow(), testWindow()]
    let workspaces = [
        harness.workspace(),
        TerminalWorkspace(projectRoot: project, createInitialSession: false, backendPolicy: harness.policy, windowID: other.windowID)
    ]
    defer {
        model.stop()
        registry.unregister(window: windows[0], projectRoot: project)
        registry.unregister(window: windows[1], projectRoot: project)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    register(windows[0], .primary(project), workspace: workspaces[0], in: registry)
    register(windows[1], other, workspace: workspaces[1], in: registry)
    let tab = workspaces[1].addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    _ = try await harness.control.list()
    model.refresh()
    #expect(!model.sessions.contains { $0.id == sessionID })

    workspaces[1].close(tab, allowEmptyWorkspace: true, intent: .userDetachedTab)
    #expect(await eventually {
        model.refresh()
        return model.sessions.map(\.id) == [sessionID]
    })
}

/// During a launch, the saved tabs of a window still to open (pending) are
/// awaiting restore: their sessions are not in the background until the
/// launch gives up on that window.
@Test @MainActor func aPendingLaunchWindowsSessionsAreNotInTheBackground() async throws {
    let harness = try PersistentHarness()
    let storeDirectory = try canonicalTemporaryDirectory("cherry-background-pending-window")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = .milliseconds(300)
    let model = makeModel(harness, registry: registry)
    let project = harness.project.path
    let other = ProjectWindowValue(projectRoot: project, windowID: UUID())
    let window = testWindow()
    let workspace = harness.workspace()
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: project)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    func savedTab(_ title: String, sessionID: String) -> WorkspaceSessionRecord {
        WorkspaceSessionRecord(
            id: UUID(), kind: .terminal, title: title, titleSource: .system, workingDirectory: project,
            projectRoot: project,
            hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
        )
    }
    let primaryTab = savedTab("Primary", sessionID: "s-primary")
    let otherTab = savedTab("Other", sessionID: "s-other")
    for (value, tab) in [(ProjectWindowValue.primary(project), primaryTab), (other, otherTab)] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: project, activeWorktreeRoot: project,
            worktrees: [WorktreeStateRecord(root: project, sessions: [tab])], windowID: value.windowID
        ))
    }
    store.saveOpenProjectWindows([.primary(project), other], synchronously: true)
    harness.fake.sessions = [primaryTab, otherTab].map { tab in
        HostedSessionInfo(
            id: tab.hosted?.sessionID ?? "", name: tab.title, cwd: project, pid: 5, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: tab.id.uuidString, PersistentSessionTag.project: project]
        )
    }
    _ = try await harness.control.list()

    registry.configureWorkspacePersistence(store: store)
    let reopened = registry.takeProjectWindowsToReopen()
    #expect(reopened == [.primary(project), other])
    // Only the front window opens; the other stays pending.
    registry.openLaunchWindows(reopened) { value in
        if value.isPrimary { register(window, value, workspace: workspace, in: registry) }
    }
    #expect(registry.pendingLaunchWindows == [other])
    model.refresh()
    #expect(!model.sessions.contains { $0.id == "s-other" })
    // The launch gave up on it: no window will bring it back.
    #expect(await eventually { registry.pendingLaunchWindows.isEmpty })
    model.refresh()
    #expect(model.sessions.contains { $0.id == "s-other" })
}

// MARK: - Closing one of a project's windows

/// A window closed while another of its project stays open forgets its
/// saved tabs: the sessions its close kept running are in the background,
/// and Open shows each in the project's window still open, as its own tab.
@Test @MainActor func sessionsKeptByClosingOneOfTwoWindowsAreListedAndOpenIntoTheOther() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-background-closed-window")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-background-closed-window-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = nil
    registry.setWorkspaceStateStoreForTesting(store)
    let model = makeModel(harness, registry: registry)
    let repositories = [nil, UUID()].map { windowID in
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
    let windows = [testWindow(), testWindow()]
    defer {
        model.stop()
        for (window, repository) in zip(windows, repositories) {
            registry.unregister(window: window, projectRoot: root.path)
            repository.closeAllSessions(intent: .windowClosed)
        }
        store.flush()
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    for (window, repository) in zip(windows, repositories) {
        #expect(registry.register(
            window: window, projectRoot: root.path, windowID: repository.windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    }
    let tab = try #require(repositories[1].workspace.sessions.first)
    #expect(await harness.waitUntilAttached(try #require(repositories[0].workspace.sessions.first)))
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    model.refresh()
    #expect(model.sessions.isEmpty)

    // The second window closes (nothing asked: it keeps its session).
    let delegate = ProjectWindowCloseDelegate(window: windows[1])
    delegate.projectRoot = root.path
    delegate.workspace = repositories[1].workspace
    delegate.repository = repositories[1]
    delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: windows[1]))
    let listed = try await harness.control.list()
    let info = try #require(listed.sessions.first { $0.id == sessionID })
    #expect(info.isRunning)
    store.flush()
    #expect(!store.savedTabsName(info, hostID: listed.hostID, owner: harness.hosting.owner))
    #expect(await eventually {
        model.refresh()
        return model.sessions.map(\.id) == [sessionID]
    })

    let row = try #require(model.sessions.first)
    await model.open(row)?.value
    #expect(repositories[0].workspace.session(withID: tab.id) != nil)
    #expect(harness.hosting.owningTab(of: sessionID)?.id == tab.id)
    model.refresh()
    #expect(model.sessions.isEmpty)
}

/// An ended session that another window's saved tabs name (that window is
/// not open now) is kept for its restore, which shows how it ended, as one
/// a project's primary window names is; once that window forgot its tabs
/// (closed while its project stayed open), it goes after the grace period
/// like any other.
@Test @MainActor func endedSessionsOfAnotherWindowsSavedTabsAreNotRemoved() async throws {
    let harness = try PersistentHarness()
    let storeDirectory = try canonicalTemporaryDirectory("cherry-background-other-window-ended")
    let store = WorkspaceStateStore(directory: storeDirectory)
    harness.hosting.endedSessionsStore = store
    let clock = Recorder(Date())
    let model = makeModel(harness, registry: ProjectWindowRegistry(), endedSessionGrace: 10, now: { clock.value })
    defer {
        model.stop()
        harness.cleanUp()
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    /// Refreshes once a second (as the app's timer does) for `seconds`.
    func pass(_ seconds: Int) {
        for _ in 0..<seconds {
            clock.value = clock.value.addingTimeInterval(1)
            model.refresh()
        }
    }
    let project = harness.project.path
    let windowID = UUID()
    let named = UUID()
    let record = WorkspaceSessionRecord(
        id: named, kind: .terminal, title: "Kept", titleSource: .system, workingDirectory: project, projectRoot: project,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "s-named", owned: true)
    )
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: project, activeWorktreeRoot: project,
        worktrees: [WorktreeStateRecord(root: project, sessions: [record])], windowID: windowID
    ))
    func ended(_ id: String, tab: UUID) -> HostedSessionInfo {
        HostedSessionInfo(
            id: id, name: id, cwd: project, pid: 300, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: tab.uuidString, PersistentSessionTag.kind: "terminal",
                   PersistentSessionTag.project: project]
        ).exited(code: 3, signal: nil)
    }
    harness.fake.sessions = [ended("s-named", tab: named), ended("s-unnamed", tab: UUID())]
    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-named", "s-unnamed"])

    pass(11)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-unnamed"] })
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.requestIDs("remove") == ["s-unnamed"])

    // That window forgot its tabs.
    store.forgetWindowState(repositoryRoot: project, windowID: windowID)
    store.flush()
    pass(11)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-unnamed", "s-named"] })
}
