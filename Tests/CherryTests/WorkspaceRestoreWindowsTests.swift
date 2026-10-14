import AppKit
import Foundation
import Testing
@testable import Cherry

// Restoring two windows of one project at once (#22): each loads only its
// own file, and a session both files name (left by a crash or an older
// build) comes back in one tab, the first window's to restore it, before
// the host answers too. A project's commands run in one tab across its
// windows, and only the window that opened the project auto-starts them.
// Against the fake `cherry control` (FakeControlHelper) and attach adapter
// (HostedSessionFakeCLI).

// MARK: - Helpers

/// A saved tab of `root` whose session is `sessionID`: a terminal, or the
/// tab of `commandName`.
private func savedTab(
    id: UUID = UUID(),
    title: String,
    sessionID: String,
    root: String,
    commandName: String? = nil
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: commandName == nil ? .terminal : .command,
        title: title,
        titleSource: .system,
        commandName: commandName,
        launchCommand: commandName.map { "run-\($0)" },
        launchWorkingDirectory: root,
        workingDirectory: root,
        projectRoot: root,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
}

private func running(_ id: String, _ record: WorkspaceSessionRecord, pid: UInt32) -> HostedSessionInfo {
    HostedSessionInfo(id: id, name: record.title, cwd: record.workingDirectory, pid: pid, owner: "CherryTests",
                      tags: [PersistentSessionTag.tab: record.id.uuidString])
}

private let serverCommand = ProjectCommandDefinition(name: "server", command: "serve", autoStart: true)

/// A registry whose windows show at once and never come forward.
@MainActor
private func quietRegistry() -> ProjectWindowRegistry {
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    registry.windowRevealMaximumWait = nil
    return registry
}

/// Opens `repository`'s window in `registry` as its binder does: it claims
/// its key, then begins its restore; a refused window is closed with its
/// tabs. Its window, which the test keeps (the registry holds it weakly),
/// or nil when it was refused.
@MainActor
private func claim(_ repository: RepositoryWorkspace, in registry: ProjectWindowRegistry) -> NSWindow? {
    let window = testWindow()
    guard registry.register(
        window: window, projectRoot: repository.repositoryRoot, windowID: repository.windowID,
        workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
    ) else {
        repository.closeAllSessions(intent: .duplicateWindowTeardown)
        return nil
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    return window
}

/// The Creates of command tabs the fake host was asked for, by their tags.
@MainActor
private func commandCreates(_ harness: PersistentHarness) -> [[String: String]] {
    harness.creates().compactMap { $0.json["tags"] as? [String: String] }
        .filter { $0[PersistentSessionTag.kind] == "command" }
}

/// A project with a primary window and another, each with its own saved
/// tabs (`sessions[window]`), restoring through `harness`'s fake host,
/// which answers once `gate` opens.
@MainActor
private struct TwoWindows {
    let harness: PersistentHarness
    let root: URL
    let storeDirectory: URL
    let store: WorkspaceStateStore
    let otherID: UUID
    let gate: RestoreGate
    let primary: RepositoryWorkspace
    let other: RepositoryWorkspace

    init(
        _ harness: PersistentHarness,
        primaryTabs: [WorkspaceSessionRecord],
        otherTabs: [WorkspaceSessionRecord],
        root: URL,
        showsSavedTabsBeforeHostAnswers: Bool,
        autoStart: [ProjectCommandDefinition] = []
    ) throws {
        self.harness = harness
        self.root = root
        storeDirectory = try canonicalTemporaryDirectory("cherry-restore-windows-store")
        let store = WorkspaceStateStore(directory: storeDirectory)
        self.store = store
        let otherID = UUID()
        self.otherID = otherID
        for (windowID, tabs) in [(nil, primaryTabs), (otherID, otherTabs)] as [(UUID?, [WorkspaceSessionRecord])] {
            store.saveSynchronously(RepositoryStateRecord(
                repositoryRoot: repositoryKey(root),
                activeWorktreeRoot: root.path,
                worktrees: [WorktreeStateRecord(root: root.path, sessions: tabs, selectedSessionID: tabs.first?.id)],
                savedAt: Date(),
                windowID: windowID
            ))
        }
        let gate = RestoreGate()
        self.gate = gate
        let restorer = harness.restorer
        func window(_ windowID: UUID?) -> RepositoryWorkspace {
            RepositoryWorkspace(
                projectRoot: root.path,
                windowID: windowID,
                backendPolicy: harness.policy,
                stateStore: store,
                sessionRestorer: { request in
                    await gate.wait()
                    return await restorer(request)
                },
                autoStartCommands: { _ in autoStart },
                restoredTabLaunchQueue: RestoredTabLaunchQueue(),
                showsSavedTabsBeforeHostAnswers: showsSavedTabsBeforeHostAnswers
            )
        }
        primary = window(nil)
        other = window(otherID)
    }

    /// Each window's tabs' record ids, primary first.
    var tabs: [[UUID]] { [primary, other].map { $0.workspace.sessions.map(\.id) } }

    /// What each window's file names now, primary first.
    func saved() -> [[UUID]] {
        [primary, other].map { repository in
            repository.flushPersistentState()
            return store.load(repositoryRoot: repository.repositoryRoot, windowID: repository.windowID)?
                .worktree(root: root.path)?.sessions.map(\.id) ?? []
        }
    }

    func cleanUp() {
        gate.open()
        primary.closeAllSessions(intent: .windowClosed)
        other.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}

// MARK: - Restoring at once

/// Two windows of a project restore at once, showing their saved tabs
/// before the host answers (as the launch does): disjoint files give
/// disjoint tabs, and a tab both files name (the same record) is the first
/// window's, provisional and then confirmed; the other never shows it. Each
/// session ends up in exactly one tab, and nothing is created or killed.
@Test @MainActor func twoWindowsOfAProjectRestoringAtOnceGiveEachSessionOneTab() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-at-once")
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(title: "Server", sessionID: "s-server", root: root.path)
    let shared = savedTab(title: "Shared", sessionID: "s-shared", root: root.path)
    harness.fake.sessions = [running("s-editor", editor, pid: 81), running("s-server", server, pid: 82),
                             running("s-shared", shared, pid: 83)]
    let windows = try TwoWindows(
        harness, primaryTabs: [editor, shared], otherTabs: [server, shared], root: root,
        showsSavedTabsBeforeHostAnswers: true
    )
    defer { windows.cleanUp() }

    windows.primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    windows.other.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { windows.gate.waiting == 2 })
    // Before the host answers: the shared tab is the primary's alone.
    #expect(windows.tabs == [[editor.id, shared.id], [server.id]])
    let sharedTab = try #require(windows.primary.workspace.session(withID: shared.id))
    #expect(sharedTab.isProvisionalRestore)
    #expect(harness.hosting.owningTab(of: "s-shared") === sharedTab)
    #expect(windows.other.workspace.sessions.allSatisfy { $0.isProvisionalRestore })

    windows.gate.open()
    await windows.primary.waitForPendingRestores()
    await windows.other.waitForPendingRestores()
    #expect(windows.tabs == [[editor.id, shared.id], [server.id]])
    #expect(windows.primary.workspace.session(withID: shared.id) === sharedTab)
    #expect(!sharedTab.isProvisionalRestore)
    for (sessionID, window) in [("s-editor", windows.primary), ("s-shared", windows.primary), ("s-server", windows.other)] {
        let owner = try #require(harness.hosting.owningTab(of: sessionID))
        #expect(window.contains(sessionID: owner.id))
        #expect([windows.primary, windows.other].filter { $0.contains(sessionID: owner.id) }.count == 1)
    }
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

/// A session both windows' files name comes back in one tab, the window's
/// that restored it first; the other drops the record, so its next save
/// no longer names it, and nothing ends.
@Test @MainActor func aSessionBothWindowsFilesNameComesBackInOneTab() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-shared")
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(title: "Server", sessionID: "s-server", root: root.path)
    let shared = savedTab(title: "Shared", sessionID: "s-shared", root: root.path)
    harness.fake.sessions = [running("s-editor", editor, pid: 81), running("s-server", server, pid: 82),
                             running("s-shared", shared, pid: 83)]
    let windows = try TwoWindows(
        harness, primaryTabs: [editor, shared], otherTabs: [shared, server], root: root,
        showsSavedTabsBeforeHostAnswers: false
    )
    defer { windows.cleanUp() }
    windows.gate.open()

    // The other window restores first this time.
    windows.other.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await windows.other.waitForPendingRestores()
    windows.primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await windows.primary.waitForPendingRestores()
    #expect(windows.tabs == [[editor.id], [shared.id, server.id]])
    let sharedTab = try #require(windows.other.workspace.session(withID: shared.id))
    #expect(harness.hosting.owningTab(of: "s-shared") === sharedTab)
    #expect(windows.saved() == [[editor.id], [shared.id, server.id]])
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - Commands across the project's windows

/// The window that opened the project starts its auto-start commands, once,
/// though it is not the primary; the window opened after it starts none,
/// and finds the opener's tab as the command's.
@Test @MainActor func autoStartRunsOnceForAProjectFromTheWindowThatOpenedIt() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart")
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [], root: root, showsSavedTabsBeforeHostAnswers: false,
        autoStart: [serverCommand]
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()

    // The other window opens the project; its primary opens after it.
    let otherWindow = try #require(claim(windows.other, in: registry))
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    defer {
        registry.unregister(window: otherWindow, projectRoot: root.path)
        registry.unregister(window: primaryWindow, projectRoot: root.path)
    }
    #expect(windows.other.opensProject)
    #expect(!windows.primary.opensProject)

    // Both appear (in either order): only the opener starts the command.
    windows.primary.autoStartInitialCommandsIfNeeded()
    windows.other.autoStartInitialCommandsIfNeeded()
    let tab = try #require(windows.other.workspace.commandSession(named: "server"))
    #expect(await harness.fake.wait { commandCreates(harness).count == 1 && tab.isRunning })
    #expect(windows.primary.workspace.commandSessions.isEmpty)
    #expect(windows.primary.workspace.projectCommandSession(named: "Server") === tab)
    // Once: asking again starts nothing more.
    windows.other.autoStartInitialCommandsIfNeeded()
    windows.primary.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).count == 1)
    #expect(windows.tabs.map { $0.count } == [1, 2])
}

/// At launch the opener's auto-start waits for the project's other launch
/// windows to register, then for the saved tabs they may still restore: a
/// command a window still to open saved is not started beside its saved
/// tab, and starts once that window's restore dropped the tab (its session
/// is gone).
@Test @MainActor func autoStartWaitsForTheProjectsLaunchWindowsAndForWhatTheyMayRestore() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart-launch")
    let savedServer = savedTab(title: "server", sessionID: "s-server", root: root.path, commandName: "server")
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [savedServer], root: root, showsSavedTabsBeforeHostAnswers: false,
        autoStart: [serverCommand]
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    // The other window shows before its restore answers.
    registry.windowRevealMaximumWait = .milliseconds(100)
    registry.scheduleLaunchWindowTurn = { $0() }
    let primary = ProjectWindowValue.primary(root.path)
    let other = ProjectWindowValue(projectRoot: root.path, windowID: windows.otherID)
    var opened: [NSWindow] = []
    defer { opened.forEach { registry.unregister(window: $0, projectRoot: root.path) } }
    var openLater: (@MainActor () -> Void)?
    registry.openLaunchWindows([primary, other], beforeLaterWindows: { openLater = $0 }) { value in
        if let window = claim(value == primary ? windows.primary : windows.other, in: registry) {
            opened.append(window)
        }
    }

    // The primary opened the project; its other window is still to open.
    #expect(registry.pendingLaunchWindows == [other])
    windows.primary.autoStartInitialCommandsIfNeeded()
    #expect(await eventually { openLater != nil })
    #expect(commandCreates(harness).isEmpty)
    #expect(windows.primary.workspace.commandSessions.isEmpty)

    // It registers and begins restoring the command's saved tab; the
    // launch's windows are open, and auto-start waits for that restore.
    var launchWindowsOpened = false
    registry.whenLaunchWindowsOpened { launchWindowsOpened = true }
    let openLaterNow = try #require(openLater)
    openLaterNow()
    #expect(registry.pendingLaunchWindows.isEmpty)
    #expect(!windows.other.opensProject)
    windows.other.autoStartInitialCommandsIfNeeded()
    #expect(await eventually { launchWindowsOpened })
    #expect(windows.primary.workspace.isRestoringCommand(named: "server"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).isEmpty)
    #expect(windows.tabs.allSatisfy { tabs in tabs.allSatisfy { $0 != savedServer.id } })

    // Its session is gone: that window drops the tab, and the opener
    // starts the command, once.
    windows.gate.open()
    await windows.other.waitForPendingRestores()
    #expect(await harness.fake.wait { commandCreates(harness).count == 1 })
    let tab = try #require(windows.primary.workspace.commandSession(named: "server"))
    #expect(windows.other.workspace.commandSessions.isEmpty)
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).count == 1)
    #expect(windows.primary.workspace.commandSessions.map(\.id) == [tab.id])
}

/// A command tab that another window of the project restored ended (its
/// session ended while Cherry was closed) starts again in that window when
/// the opener's auto-start runs, in a new session for the same tab, tagged
/// with that window.
@Test @MainActor func autoStartRestartsAnEndedCommandTabOfAnotherWindow() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart-ended")
    let savedServer = savedTab(title: "server", sessionID: "s-server", root: root.path, commandName: "server")
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-server", name: "server", cwd: root.path, state: .exited, exitCode: 1, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: savedServer.id.uuidString])
    ]
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [savedServer], root: root, showsSavedTabsBeforeHostAnswers: false,
        autoStart: [serverCommand]
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    let otherWindow = try #require(claim(windows.other, in: registry))
    defer {
        registry.unregister(window: primaryWindow, projectRoot: root.path)
        registry.unregister(window: otherWindow, projectRoot: root.path)
    }

    // The opener's auto-start waits for the other window's restore.
    windows.primary.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(commandCreates(harness).isEmpty)
    windows.gate.open()
    await windows.other.waitForPendingRestores()
    let tab = try #require(windows.other.workspace.session(withID: savedServer.id))
    #expect(tab.kind == .command)

    #expect(await harness.fake.wait(timeout: 8) {
        commandCreates(harness).count == 1 && tab.isRunning
            && tab.persistentSession.map { $0.sessionID != "s-server" } == true
    })
    let tags = try #require(commandCreates(harness).first)
    #expect(tags[PersistentSessionTag.tab] == savedServer.id.uuidString)
    #expect(tags[PersistentSessionTag.window] == windows.otherID.uuidString)
    #expect(windows.primary.workspace.commandSessions.isEmpty)
    #expect(windows.other.workspace.commandSessions.map(\.id) == [tab.id])
}

/// The launch shows another window's saved command tab before the host
/// answers (provisional), and the opener's auto-start runs meanwhile: it
/// takes that tab for neither a running command nor a gone one, and waits
/// for that window's restore. The session ended while Cherry was closed:
/// the tab comes back ended and starts again there, once.
@Test @MainActor func autoStartWaitsForAnotherWindowsProvisionalCommandTabAndRestartsItEnded() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart-provisional-ended")
    let savedServer = savedTab(title: "server", sessionID: "s-server", root: root.path, commandName: "server")
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-server", name: "server", cwd: root.path, state: .exited, exitCode: 1, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: savedServer.id.uuidString])
    ]
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [savedServer], root: root, showsSavedTabsBeforeHostAnswers: true,
        autoStart: [serverCommand]
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    let otherWindow = try #require(claim(windows.other, in: registry))
    defer {
        registry.unregister(window: primaryWindow, projectRoot: root.path)
        registry.unregister(window: otherWindow, projectRoot: root.path)
    }
    #expect(await eventually { windows.other.workspace.session(withID: savedServer.id)?.isProvisionalRestore == true })
    let tab = try #require(windows.other.workspace.session(withID: savedServer.id))

    windows.primary.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).isEmpty)
    #expect(windows.primary.workspace.commandSessions.isEmpty)

    windows.gate.open()
    await windows.other.waitForPendingRestores()
    #expect(windows.other.workspace.session(withID: savedServer.id) === tab)
    #expect(await harness.fake.wait(timeout: 8) {
        commandCreates(harness).count == 1 && tab.isRunning
            && tab.persistentSession.map { $0.sessionID != "s-server" } == true
    })
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).count == 1)
    #expect(windows.primary.workspace.commandSessions.isEmpty)
}

/// As above, but the session is gone: that window withdraws its
/// provisional tab, and the opener starts the command, once.
@Test @MainActor func autoStartWaitsForAnotherWindowsProvisionalCommandTabAndStartsItGone() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart-provisional-gone")
    let savedServer = savedTab(title: "server", sessionID: "s-server", root: root.path, commandName: "server")
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [savedServer], root: root, showsSavedTabsBeforeHostAnswers: true,
        autoStart: [serverCommand]
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    let otherWindow = try #require(claim(windows.other, in: registry))
    defer {
        registry.unregister(window: primaryWindow, projectRoot: root.path)
        registry.unregister(window: otherWindow, projectRoot: root.path)
    }
    #expect(await eventually { windows.other.workspace.session(withID: savedServer.id)?.isProvisionalRestore == true })

    windows.primary.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).isEmpty)

    windows.gate.open()
    await windows.other.waitForPendingRestores()
    #expect(windows.other.workspace.session(withID: savedServer.id) == nil)
    #expect(await harness.fake.wait { commandCreates(harness).count == 1 })
    let tab = try #require(windows.primary.workspace.commandSession(named: "server"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(commandCreates(harness).count == 1)
    #expect(windows.primary.workspace.commandSessions.map(\.id) == [tab.id])
    #expect(windows.other.workspace.commandSessions.isEmpty)
}

/// Auto-start asked for before the window claimed its project (its view
/// appeared first) waits for the claim, and runs a turn after it; a window
/// refused its project never starts anything.
@Test @MainActor func nothingAutoStartsBeforeAWindowClaimedItsProject() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-autostart-claim")
    defer { try? FileManager.default.removeItem(at: root) }
    func window() -> RepositoryWorkspace {
        RepositoryWorkspace(
            projectRoot: root.path,
            backendPolicy: harness.policy,
            autoStartCommands: { _ in [serverCommand] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
    }
    let opener = window()
    let refused = window()
    defer {
        opener.closeAllSessions(intent: .windowClosed)
        refused.closeAllSessions(intent: .windowClosed)
    }
    let registry = quietRegistry()

    // It has no saved tabs to wait for, and has not claimed its project.
    opener.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(opener.workspace.commandSessions.isEmpty)
    #expect(commandCreates(harness).isEmpty)

    let openerWindow = try #require(claim(opener, in: registry))
    defer { registry.unregister(window: openerWindow, projectRoot: root.path) }
    // Not inside the claim (a SwiftUI view update), a turn later.
    #expect(opener.workspace.commandSessions.isEmpty)
    #expect(await eventually { opener.workspace.commandSession(named: "server") != nil })
    #expect(await harness.fake.wait { commandCreates(harness).count == 1 })

    // A second window for the same key is refused: before it or after, it
    // starts nothing.
    refused.autoStartInitialCommandsIfNeeded()
    #expect(claim(refused, in: registry) == nil)
    refused.autoStartInitialCommandsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    #expect(refused.workspace.commandSessions.isEmpty)
    #expect(commandCreates(harness).count == 1)
}

/// Starting a command another window of the project runs returns that
/// window's tab: nothing is added or selected here, nor in that window.
/// ⌘Z of a closed tab of that command brings nothing back. Once that
/// window closed, the command starts here.
@Test @MainActor func startingACommandAnotherWindowRunsReturnsThatTab() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-command-start")
    let windows = try TwoWindows(harness, primaryTabs: [], otherTabs: [], root: root, showsSavedTabsBeforeHostAnswers: false)
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    let otherWindow = try #require(claim(windows.other, in: registry))
    defer { registry.unregister(window: otherWindow, projectRoot: root.path) }
    let primary = windows.primary.workspace
    let other = windows.other.workspace
    let tab = primary.addCommandSession(command: serverCommand, projectRoot: root.path, select: false)
    #expect(await harness.fake.wait { commandCreates(harness).count == 1 && tab.isRunning })
    let primarySelection = primary.selectedSessionID
    let otherTabs = other.sessions.map(\.id)
    let otherSelection = other.selectedSessionID

    #expect(other.addCommandSession(command: serverCommand, projectRoot: root.path) === tab)
    #expect(other.projectCommandSession(named: "Server") === tab)
    #expect(other.commandSession(named: "server") == nil)
    #expect(other.sessions.map(\.id) == otherTabs)
    #expect(other.selectedSessionID == otherSelection)
    #expect(primary.selectedSessionID == primarySelection)
    #expect(primary.commandSessions.map(\.id) == [tab.id])
    #expect(commandCreates(harness).count == 1)

    // A closed tab of the command does not come back beside it.
    let closedServer = savedTab(title: "server", sessionID: "s-closed-server", root: root.path, commandName: "server")
    let closed = ClosedTab(
        record: closedServer,
        name: "server",
        binding: HostedSessionAttachment(
            host: .local, hostID: "host-a", sessionID: "s-closed-server", name: "server",
            remoteWorkingDirectory: root.path, executablePath: "/usr/bin/false"
        ),
        ownsSession: true,
        placement: ClosedTabPlacement(sessionIndex: 0, display: nil, wasSelected: false, subAgentIDs: [])
    )
    #expect(other.reopenClosedTab(closed) == nil)
    #expect(other.sessions.map(\.id) == otherTabs)

    // Its window closes: the command is no other window's now.
    registry.unregister(window: primaryWindow, projectRoot: root.path)
    windows.primary.closeAllSessions(intent: .windowClosed)
    let own = other.addCommandSession(command: serverCommand, projectRoot: root.path, select: false)
    #expect(own !== tab)
    #expect(other.commandSession(named: "server") === own)
}

/// A command start (the sidebar's, MCP's) in one window waits for a restore
/// under way in another window of the project that may bring back the
/// command's tab, then gets that tab instead of a second copy.
@Test @MainActor func aCommandStartWaitsForAnotherWindowsRestoreOfIt() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-command-wait")
    let savedServer = savedTab(title: "server", sessionID: "s-server", root: root.path, commandName: "server")
    harness.fake.sessions = [running("s-server", savedServer, pid: 91)]
    let windows = try TwoWindows(
        harness, primaryTabs: [], otherTabs: [savedServer], root: root, showsSavedTabsBeforeHostAnswers: false
    )
    defer { windows.cleanUp() }
    let registry = quietRegistry()
    let primaryWindow = try #require(claim(windows.primary, in: registry))
    let otherWindow = try #require(claim(windows.other, in: registry))
    defer {
        registry.unregister(window: primaryWindow, projectRoot: root.path)
        registry.unregister(window: otherWindow, projectRoot: root.path)
    }
    let primary = windows.primary.workspace

    #expect(primary.isRestoringCommand(named: "Server"))
    #expect(!primary.isRestoringCommand(named: "web"))
    let waited = Recorder(false)
    let start = Task { @MainActor in
        await primary.waitUntilRestored(commandNamed: "server")
        waited.value = true
        return primary.addCommandSession(command: serverCommand, projectRoot: root.path, select: false)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!waited.value)

    windows.gate.open()
    let started = await start.value
    let tab = try #require(windows.other.workspace.session(withID: savedServer.id))
    #expect(started === tab)
    #expect(tab.persistentSession?.sessionID == "s-server")
    #expect(!primary.isRestoringCommand(named: "server"))
    #expect(primary.commandSessions.isEmpty)
    #expect(commandCreates(harness).isEmpty)
}
