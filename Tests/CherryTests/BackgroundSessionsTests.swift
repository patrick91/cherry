import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Background sessions (docs/specs/multiplexer-default.md): this app's own
// local sessions that no open tab shows, listed in the menu bar extra, ended
// from there, the Cherry menu or Settings › Sessions, and named once by a
// launch notice. Against the fake `cherry control` (FakeControlHelper) and
// test registries: nothing reaches a real cherry-host, a window on screen, or
// the app's real settings.

// MARK: - Helpers

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// A project window that never comes on screen.
@MainActor
private func testWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Waits (polling the main loop) until `condition` holds; false after
/// `timeout`.
@MainActor
private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A session this app (CherryTests) started for a tab. `createdAt` nil: the
/// host did not say when, so no orphan scan adopts it. `foreground`: the job
/// its shell runs in its foreground (a busy terminal).
private func ownSession(
    _ id: String,
    tab: UUID = UUID(),
    project: String?,
    name: String = "Session",
    kind: String = "terminal",
    agent: String? = nil,
    command: String? = nil,
    owner: String? = "CherryTests",
    clients: Int = 0,
    createdAt: Date? = nil,
    foreground: String? = nil
) -> HostedSessionInfo {
    var tags = [PersistentSessionTag.tab: tab.uuidString, PersistentSessionTag.kind: kind]
    if let project { tags[PersistentSessionTag.project] = project }
    if let agent { tags[PersistentSessionTag.agent] = agent }
    if let command { tags[PersistentSessionTag.command] = command }
    return HostedSessionInfo(
        id: id, name: name, cwd: project ?? "/", pid: 300,
        foreground: foreground.map { HostedSessionForeground(pid: 99, name: $0) },
        clients: clients, owner: owner, tags: tags,
        createdAt: createdAt.map { UInt64($0.timeIntervalSince1970 * 1_000) } ?? 0
    )
}

/// A saved tab that owned a session of the fake local host.
private func savedTab(
    id: UUID = UUID(),
    kind: TerminalSession.SessionKind = .terminal,
    title: String,
    sessionID: String,
    commandName: String? = nil,
    root: String
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: kind,
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

/// The session the host lists for a saved tab.
private func session(of record: WorkspaceSessionRecord, root: String) -> HostedSessionInfo {
    ownSession(
        record.hosted!.sessionID, tab: record.id, project: root, name: record.title,
        kind: record.kind.rawValue, command: record.commandName
    )
}

/// The key a repository's saved tabs are stored under.
private func repositoryKey(_ root: URL) -> String {
    URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
}

/// The same directory, however it is spelled (`/var` or `/private/var`).
private func resolved(_ path: String?) -> String? {
    path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}

private func saveState(_ records: [WorkspaceSessionRecord], root: URL, in store: WorkspaceStateStore) {
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: records, selectedSessionID: records.first?.id)]
    ))
}

/// The End All confirmations the model asked, the windows they were asked
/// from, and their answers.
@MainActor
private final class Confirmations {
    private(set) var alerts: [NSAlert] = []
    private(set) var askedFrom: [NSWindow?] = []
    private var answers: [@MainActor (NSApplication.ModalResponse) -> Void] = []

    var presenter: BackgroundSessionsModel.AlertPresenter {
        { [unowned self] alert, window, answer in
            alerts.append(alert)
            askedFrom.append(window)
            answers.append(answer)
        }
    }

    func answer(_ response: NSApplication.ModalResponse) {
        guard !answers.isEmpty else { return }
        answers.removeFirst()(response)
    }
}

@MainActor
private func makeModel(
    _ harness: PersistentHarness,
    registry: ProjectWindowRegistry = ProjectWindowRegistry(),
    confirmations: Confirmations = Confirmations(),
    prefersPersistentLocalSessions: @escaping @MainActor () -> Bool = { true },
    closesTabsOnCleanExit: @escaping @MainActor () -> Bool = { true },
    postNotification: @escaping @MainActor (BackgroundSessionNotificationContent) -> Void = { _ in },
    endedSessionGrace: TimeInterval = BackgroundSessionsModel.defaultEndedSessionGrace,
    now: @escaping @MainActor () -> Date = { Date() },
    isAppActive: @escaping @MainActor () -> Bool = { true },
    removeStaleResources: (@MainActor (Set<String>) -> Void)? = nil
) -> BackgroundSessionsModel {
    BackgroundSessionsModel(
        localSessions: harness.hosting,
        registry: registry,
        prefersPersistentLocalSessions: prefersPersistentLocalSessions,
        closesTabsOnCleanExit: closesTabsOnCleanExit,
        presentAlert: confirmations.presenter,
        postNotification: postNotification,
        endedSessionGrace: endedSessionGrace,
        now: now,
        isAppActive: isAppActive,
        removeStaleResources: removeStaleResources
    )
}

/// Suspends restores until the test opens it.
@MainActor
private final class RestoreGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// A project window for `root` whose restore uses the harness's host
/// (behind `gate`, when given), registered with `registry` (with
/// `chromeState`, for its toasts).
@MainActor
private func openProject(
    _ root: URL,
    store: WorkspaceStateStore,
    harness: PersistentHarness,
    registry: ProjectWindowRegistry,
    window: NSWindow,
    gate: RestoreGate? = nil,
    chromeState: ProjectWindowChromeState? = nil
) -> RepositoryWorkspace {
    let restorer = harness.restorer
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: { request in
            await gate?.wait()
            return await restorer(request)
        },
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    _ = registry.register(
        window: window, projectRoot: root.path, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    )
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    return repository
}

// MARK: - Which sessions are in the background

@Test @MainActor func backgroundSessionsAreThisAppsSessionsThatNoOpenTabShows() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let model = makeModel(harness)
    defer {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    // A tab that owns its session.
    let owned = workspace.addSession(title: "Owned")
    #expect(await harness.waitUntilAttached(owned))
    let ownedSession = try #require(owned.persistentSession?.sessionID)
    // A tab whose Create has not been answered yet.
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let creating = workspace.addSession(title: "Creating")
    #expect(await harness.fake.wait { held.isHeld })
    harness.fake.respond = nil
    let launchID = try #require(creating.persistentLaunchRequestID)

    harness.fake.sessions += [
        // Another client shows it: a tab here only attaches to it.
        ownSession("s-attached", project: project, clients: 1),
        // Started for an open tab (a restart's old session, say).
        ownSession("s-tagged", tab: owned.id, project: project),
        // Started by the Create still under way.
        HostedSessionInfo(
            id: "s-creating", name: "Creating", cwd: project, pid: 5, owner: "CherryTests",
            tags: [PersistentSessionTag.launch: launchID], requestID: launchID
        ),
        // Being ended.
        ownSession("s-ending", project: project),
        // The CLI's (no owner) and another app's.
        HostedSessionInfo(id: "s-cli", name: "cli", cwd: project, pid: 6),
        ownSession("s-other-app", project: project, owner: "Cherry Sessions"),
        // Its tab closed and kept it: in the background.
        ownSession("s-background", project: project, name: "Build")
    ]
    let list = try await harness.control.list()
    let watched = try #require(list.sessions.first { $0.id == "s-attached" })
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: watched)), info: watched)
    #expect(attached.hostedAttachment?.sessionID == "s-attached")
    harness.fake.killEndsSession = false
    let ending = try #require(harness.hosting.sessionInfo("s-ending"))
    harness.hosting.end(try #require(harness.hosting.attachment(for: ending)))
    #expect(harness.hosting.isEnding("s-ending"))

    model.refresh()
    #expect(model.sessions.map(\.id) == ["s-background"])
    #expect(model.summary.count == 1)
    #expect(model.summary.runningCount == 1)
    let background = try #require(model.sessions.first)
    #expect(background.title == "Build")
    #expect(background.kind == .terminal)
    #expect(background.projectName == harness.project.lastPathComponent)
    #expect(background.hostID == "host-a")
    #expect(background.isRunning)

    // How the Persistent Sessions sheet marks this app's sessions.
    func label(_ id: String) throws -> String? {
        model.ownershipLabel(for: try #require(harness.hosting.sessionInfo(id)), hostID: "host-a")
    }
    #expect(try label(ownedSession) == "In a tab")
    #expect(try label("s-attached") == "In a tab")
    #expect(try label("s-creating") == "In a tab")
    #expect(try label("s-background") == "In the background")
    // One being ended cannot be attached there, and says so.
    #expect(try label("s-ending") == "Ending")
    #expect(try label("s-cli") == nil)
    #expect(try label("s-other-app") == nil)

    // The Create answers: its tab owns the session.
    held.answer(.created(HostedSessionInfo(
        id: "s-creating", name: "Creating", cwd: project, pid: 5, owner: "CherryTests",
        tags: [PersistentSessionTag.launch: launchID], requestID: launchID
    )))
    #expect(await harness.waitUntilAttached(creating))
    #expect(harness.hosting.owningTab(of: "s-creating") === creating)

    // The session of a forgotten saved tab (its worktree was removed) that
    // is about to be ended is left out too.
    harness.fake.killEndsSession = true
    let background2 = try #require(harness.hosting.sessionInfo("s-background"))
    let forgotten = savedTab(title: "Build", sessionID: "s-background", root: project)
    harness.hosting.endSessions(ofForgottenTabs: [forgotten])
    #expect(harness.hosting.isScheduledToEnd(background2, hostID: "host-a"))
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains("s-background") })
}

@Test @MainActor func aDetachedTabBecomesABackgroundSessionAndAClosedOneNever() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let model = makeModel(harness)
    defer {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let closed = workspace.addSession(title: "Closed")
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(closed))
    let closedSession = try #require(closed.persistentSession?.sessionID)

    // Closing a tab ends its session: never in the background.
    workspace.close(closed)
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(closedSession) })
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.isEmpty)

    // Detaching a tab: its session is in the background.
    let kept = workspace.addSession(title: "Kept")
    #expect(await harness.waitUntilAttached(kept))
    let keptSession = try #require(kept.persistentSession?.sessionID)
    workspace.close(kept, intent: .userDetachedTab)
    #expect(workspace.session(withID: kept.id) == nil)
    model.refresh()
    #expect(model.sessions.map(\.id) == [keptSession])
    let item = try #require(model.sessions.first)
    #expect(item.title == "Kept")
    #expect(item.kind == .terminal)
    #expect(item.projectName == harness.project.lastPathComponent)
    #expect(BackgroundSessionPresentation.statusText(of: item) == "idle")
    #expect(harness.requestIDs("kill") == [closedSession])
}

@Test @MainActor func closingAWindowMovesItsSessionsToBackgroundSessionsWithTheirProject() async throws {
    let harness = try PersistentHarness()
    let model = makeModel(harness)
    let kept = harness.workspace()
    let ended = harness.workspace()
    defer {
        model.stop()
        harness.cleanUp()
    }
    let shell = kept.addSession(title: "Shell")
    let server = kept.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"), projectRoot: harness.project.path
    )
    let other = ended.addSession(title: "Other")
    for tab in [shell, server, other] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let otherSession = try #require(other.persistentSession?.sessionID)
    let keptSessions = Set([shell, server].compactMap { $0.persistentSession?.sessionID })
    #expect(keptSessions.count == 2)
    model.refresh()
    #expect(model.sessions.isEmpty)

    // Keep Running (or nothing asked): the window's sessions keep running,
    // in the background until the project opens again.
    kept.closeAllSessions(intent: .windowClosed)
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == keptSessions)
    #expect(model.sessions.allSatisfy { $0.projectName == harness.project.lastPathComponent })
    let command = try #require(model.sessions.first { $0.kind == .command })
    #expect(command.title == "server")
    #expect(command.commandName == "server")
    #expect(BackgroundSessionPresentation.statusText(of: command) == "running")

    // End Sessions: none goes to the background.
    ended.closeAllSessions(intent: .windowClosedEndingSessions)
    model.refresh()
    #expect(!model.sessions.contains { $0.id == otherSession })
    #expect(model.sessions.count == 2)
}

@Test @MainActor func sessionsAwaitingARestoreAreNotBackgroundButSetAsideOnesAre() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-background-restore")
    let storeDirectory = try temporaryDirectory("cherry-background-restore-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(kind: .command, title: "server", sessionID: "s-server", commandName: "server", root: root.path)
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [session(of: editor, root: root.path), session(of: server, root: root.path),
                             ownSession("s-scratch", project: root.path, name: "Scratch")]
    saveState([editor, server], root: root, in: store)
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    let gate = RestoreGate()
    let repository = openProject(root, store: store, harness: harness, registry: registry, window: window, gate: gate)
    let model = makeModel(harness, registry: registry)
    defer {
        gate.open()
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    #expect(await eventually { gate.waiting == 1 })
    _ = try await harness.control.list()
    model.refresh()
    // The window may still restore its saved tabs: only the session no
    // saved tab names is in the background.
    #expect(repository.isRestoringSessions)
    #expect(model.sessions.map(\.id) == ["s-scratch"])

    // A copy of the server started meanwhile runs: the restored server tab
    // is set aside, its session still running and its record saved.
    let workspace = repository.activeWorkspace
    let started = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"), projectRoot: root.path, select: false
    )
    #expect(await harness.waitUntilAttached(started))
    gate.open()
    await repository.waitForPendingRestores()
    #expect(workspace.session(withID: editor.id)?.persistentSession?.sessionID == "s-editor")
    #expect(workspace.session(withID: server.id) == nil)
    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-scratch", "s-server"])

    // Opening it shows the tab that runs the command; it stays set aside.
    let info = try #require(harness.hosting.sessionInfo("s-server"))
    let shown = repository.showBackgroundSession(
        PersistentSessionLaunch(attachment: try #require(harness.hosting.attachment(for: info)), info: info),
        worktreeRoot: root.path,
        hosting: harness.hosting
    )
    #expect(shown === started)
    #expect(workspace.selectedSessionID == started.id)
    #expect(workspace.commandSessions.map(\.id) == [started.id])
    #expect(harness.fake.requests("kill").isEmpty)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.contains { $0.id == server.id })
}

// MARK: - Ending them

@Test @MainActor func endingABackgroundSessionKillsThenRemovesItAndAnEndedOneIsOnlyRemoved() async throws {
    var configuration = PersistentHarness.fastConfiguration
    // Longer than this, a tab's close stops waiting for the exit; a
    // background session's End waits for as long as it retries.
    configuration.terminationTimeout = .milliseconds(200)
    let harness = try PersistentHarness(configuration: configuration)
    let model = makeModel(harness)
    defer {
        model.stop()
        harness.cleanUp()
    }
    let project = harness.project.path
    harness.fake.sessions = [
        ownSession("s-running", project: project, name: "Server"),
        ownSession("s-done", project: project, name: "Done").exited(code: 2, signal: nil),
        ownSession("s-slow", project: project, name: "Slow")
    ]
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.count == 3)
    let done = try #require(model.sessions.first { $0.id == "s-done" })
    #expect(!done.isRunning)
    #expect(BackgroundSessionPresentation.statusText(of: done) == "exit 2")
    #expect(model.summary.runningCount == 2)

    let ending = try #require(model.end(sessionID: "s-running"))
    // Out of the list at once.
    #expect(!model.sessions.contains { $0.id == "s-running" })
    await ending.value
    #expect(harness.fake.requests.filter { ["kill", "remove"].contains($0.op) }.map { "\($0.op) \($0.string("id") ?? "")" }
        == ["kill s-running", "remove s-running"])

    // An ended one is only removed.
    await model.end(sessionID: "s-done")?.value
    #expect(harness.requestIDs("kill") == ["s-running"])
    #expect(harness.requestIDs("remove") == ["s-running", "s-done"])

    // A program slower to exit than a tab's close waits is still removed.
    harness.fake.killEndsSession = false
    let slow = try #require(model.end(sessionID: "s-slow"))
    try await Task.sleep(for: .milliseconds(600))
    #expect(!harness.requestIDs("remove").contains("s-slow"))
    harness.exit("s-slow", code: 143)
    await slow.value
    #expect(harness.requestIDs("remove").last == "s-slow")

    // Nothing is left to list, or to end again.
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(model.summary.count == 0)
    #expect(model.end(sessionID: "s-running") == nil)
}

@Test @MainActor func endAllEndsOnlyTheSessionsStillInTheBackgroundWhenConfirmed() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let confirmations = Confirmations()
    let model = makeModel(harness, confirmations: confirmations)
    defer {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let reopenedTab = UUID()
    harness.fake.sessions = [
        ownSession("s-a", tab: reopenedTab, project: project, name: "A"),
        ownSession("s-b", project: project, name: "B", kind: "command", command: "worker")
    ]
    _ = try await harness.control.list()

    // Cancel ends nothing.
    model.confirmEndAll()
    let alert = try #require(confirmations.alerts.first)
    #expect(alert.messageText == "End 2 background sessions?")
    #expect(alert.informativeText == "1 of them is running a program. "
        + "Their programs stop now, and they do not come back when their projects open again.")
    // Asked from the Cherry menu: no window of its own.
    #expect(confirmations.askedFrom.count == 1)
    #expect(confirmations.askedFrom.first! == nil)
    confirmations.answer(.alertSecondButtonReturn)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("kill").isEmpty)

    // Confirmed after one was opened in a tab meanwhile: only the other ends.
    // Asked from Settings: on that window.
    let settingsWindow = testWindow()
    model.confirmEndAll(from: settingsWindow)
    #expect(confirmations.alerts.count == 2)
    #expect(confirmations.askedFrom.last! === settingsWindow)
    let info = try #require(harness.hosting.sessionInfo("s-a"))
    let tab = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: info)), info: info)
    #expect(tab.isPersistentLocalSession)
    #expect(tab.id == reopenedTab)
    confirmations.answer(.alertFirstButtonReturn)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-b"] })
    #expect(harness.requestIDs("kill") == ["s-b"])

    // Nothing in the background: nothing to confirm.
    _ = try await harness.control.list()
    model.confirmEndAll()
    #expect(confirmations.alerts.count == 2)
}

@Test @MainActor func theEndAllConfirmationCountsSessionsAndGoesOnAProjectWindow() {
    let one = BackgroundSessionsModel.makeEndAllAlert(running: 1, busy: 1, ended: 0)
    #expect(one.messageText == "End 1 background session?")
    #expect(one.informativeText == "Its program stops now, and it does not come back when its project opens again.")
    #expect(one.buttons.map(\.title) == ["End Sessions", "Cancel"])
    #expect(one.buttons[0].hasDestructiveAction)
    #expect(one.alertStyle == .warning)
    let three = BackgroundSessionsModel.makeEndAllAlert(running: 3, busy: 0, ended: 0)
    #expect(three.messageText == "End 3 background sessions?")
    #expect(three.informativeText == "Their programs stop now, and they do not come back when their projects open again.")
    #expect(BackgroundSessionsModel.makeEndAllAlert(running: 3, busy: 2, ended: 0).informativeText
        .hasPrefix("2 of them are running a program. "))

    // Sessions that ended are only removed: nothing is said to stop.
    let endedOne = BackgroundSessionsModel.makeEndAllAlert(running: 0, busy: 0, ended: 1)
    #expect(endedOne.messageText == "Remove 1 ended background session?")
    #expect(endedOne.informativeText
        == "Its program already ended; its final screen is discarded, and it does not come back when its project opens again.")
    #expect(endedOne.buttons.map(\.title) == ["Remove Sessions", "Cancel"])
    #expect(endedOne.buttons[0].hasDestructiveAction)
    let endedTwo = BackgroundSessionsModel.makeEndAllAlert(running: 0, busy: 0, ended: 2)
    #expect(endedTwo.messageText == "Remove 2 ended background sessions?")
    #expect(endedTwo.informativeText.hasPrefix("Their programs already ended; their final screens are discarded"))
    let mixed = BackgroundSessionsModel.makeEndAllAlert(running: 2, busy: 1, ended: 1)
    #expect(mixed.messageText == "End 3 background sessions?")
    #expect(mixed.informativeText == "2 of them still run and stop now, the 1 that ended is removed, "
        + "and they do not come back when their projects open again.")
    #expect(BackgroundSessionsModel.makeEndAllAlert(running: 1, busy: 0, ended: 2).informativeText
        .hasPrefix("1 of them still runs and stops now, the 2 that ended are removed"))

    // Where it goes: as the quit confirmation, a project window, never the
    // menu bar panel it was asked from; on Settings when asked there.
    let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
    let project = testWindow()
    #expect(BackgroundSessionsModel.endAllParent(askedFrom: nil) == nil)
    #expect(BackgroundSessionsModel.endAllParent(askedFrom: panel) == nil)
    // A window the user does not see (closed, or never shown) is no parent.
    #expect(BackgroundSessionsModel.endAllParent(askedFrom: project) == nil)
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: panel, keyWindowIsProjectWindow: false, activeProjectWindow: project
    ) === project)
    #expect(CherryAppDelegate.quitConfirmationParent(
        keyWindow: panel, keyWindowIsProjectWindow: false, activeProjectWindow: nil
    ) == nil)
}

@Test @MainActor func aCopyWithoutTheInstanceLockListsAndEndsNothing() async throws {
    let directory = try temporaryDirectory("cherry-background-lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appendingPathComponent("instance.lock")
    let holder = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
    #expect(holder.isHeld)
    defer { holder.release() }
    let other = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")

    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let control = harness.control
    let hosting = PersistentLocalSessions(
        owner: "CherryTests",
        control: { control },
        installationUnavailableReason: { nil },
        status: PersistentSessionsStatus(),
        instanceLock: other,
        configuration: PersistentHarness.fastConfiguration
    )
    let confirmations = Confirmations()
    let model = BackgroundSessionsModel(
        localSessions: hosting, registry: ProjectWindowRegistry(), presentAlert: confirmations.presenter
    )
    defer { model.stop() }
    harness.fake.sessions = [ownSession("s-background", project: harness.project.path)]
    _ = try await harness.control.list()
    let launches = harness.fake.launches.count

    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(model.end(sessionID: "s-background") == nil)
    model.confirmEndAll()
    #expect(confirmations.alerts.isEmpty)
    #expect(model.ownershipLabel(for: harness.fake.sessions[0], hostID: "host-a") == "This app")
    // It does not connect to list either.
    control.disconnect()
    model.panelDidAppear()
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.launches.count == launches)
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - The connection

@Test @MainActor func theModelHoldsTheHostConnectionOnlyWhileItListsSessions() async throws {
    var controlConfiguration = HostControl.Configuration.fastTests
    controlConfiguration.idleDisconnectDelay = .milliseconds(300)
    let harness = try PersistentHarness(controlConfiguration: controlConfiguration)
    let model = makeModel(harness)
    defer {
        model.stop()
        harness.cleanUp()
    }
    harness.fake.sessions = [ownSession("s-background", project: harness.project.path)]
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.count == 1)
    // Held while it lists a session, so the list stays current.
    try await Task.sleep(for: .milliseconds(900))
    #expect(harness.control.state == .connected)
    #expect(harness.fake.launches.count == 1)

    // None left: the unused connection closes.
    harness.fake.sessions = []
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(await harness.fake.wait(timeout: 3) { harness.control.state != .connected })

    // Opening the panel lists the host once and holds nothing: with no
    // session to list, the connection closes again, whether or not the
    // panel ever tells it closed.
    model.panelDidAppear()
    #expect(await harness.fake.wait { harness.control.state == .connected })
    #expect(await harness.fake.wait(timeout: 3) { harness.control.state != .connected })
    #expect(model.sessions.isEmpty)
}

@Test @MainActor func theModelNeverStartsAHostItHasNotReached() async throws {
    let harness = try PersistentHarness()
    let persistsLocal = Recorder(false)
    let model = makeModel(harness, prefersPersistentLocalSessions: { persistsLocal.value })
    defer {
        model.stop()
        harness.cleanUp()
    }
    // Following the host, and opening the panel, while local tabs run
    // natively and this run never reached the host: nothing connects.
    model.start()
    model.panelDidAppear()
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.launches.isEmpty)
    #expect(harness.hosting.connectionGeneration == 0)
    #expect(model.sessions.isEmpty)

    // Local tabs run in the host: opening the panel lists it.
    persistsLocal.value = true
    harness.fake.sessions = [ownSession("s-background", project: harness.project.path)]
    model.panelDidAppear()
    #expect(await harness.fake.wait { !harness.fake.requests("list").isEmpty })
    #expect(await eventually { model.sessions.map(\.id) == ["s-background"] })
    #expect(harness.fake.launches.count == 1)

    // Added by the host: listed from its event, before the next tick.
    let connection = try #require(harness.fake.connections.last)
    let added = ownSession("s-added", project: harness.project.path, createdAt: Date())
    harness.fake.sessions.append(added)
    connection.push(.event(.added(added)))
    #expect(await eventually(timeout: 0.5) { model.sessions.count == 2 })
}

// MARK: - How they look

@Test func backgroundRowsShowTitleProjectAndStatusWithoutTitleChurn() {
    let project = "/Users/tester/code/cherry"
    func row(_ info: HostedSessionInfo) -> BackgroundSession {
        BackgroundSessionPresentation.session(info, hostID: "host-a")
    }
    let command = row(ownSession("c", project: project, name: "npm", kind: "command", command: "web"))
    #expect(command.title == "web")
    #expect(command.kind == .command)
    #expect(command.commandName == "web")
    #expect(command.projectName == "cherry")
    #expect(BackgroundSessionPresentation.statusText(of: command) == "running")
    #expect(BackgroundSessionPresentation.tone(of: command) == .active)

    let agent = row(ownSession("a", project: project, name: "claude --resume", kind: "agent", agent: "Claude"))
    #expect(agent.title == "Claude")
    #expect(agent.agentKey == "Claude")
    #expect(row(ownSession("a2", project: project, name: "Codex", kind: "agent")).title == "Codex")

    let idle = row(ownSession("t", project: project, name: "zsh"))
    #expect(idle.title == "zsh")
    #expect(BackgroundSessionPresentation.statusText(of: idle) == "idle")
    #expect(BackgroundSessionPresentation.tone(of: idle) == .idle)
    #expect(row(ownSession("t2", project: project, name: "")).title == "t2")

    let busy = row(HostedSessionInfo(
        id: "b", name: "zsh", cwd: project, pid: 10, foreground: HostedSessionForeground(pid: 11, name: "npm"),
        owner: "CherryTests", tags: [PersistentSessionTag.project: project]
    ))
    #expect(busy.isBusy)
    #expect(BackgroundSessionPresentation.statusText(of: busy) == "npm")
    #expect(BackgroundSessionPresentation.tone(of: busy) == .active)

    let attached = row(ownSession("w", project: project, clients: 1))
    #expect(BackgroundSessionPresentation.statusText(of: attached) == "attached")

    let ended = row(ownSession("e", project: project).exited(code: 3, signal: nil))
    #expect(ended.exitStatus == 3)
    #expect(!ended.isRunning)
    #expect(BackgroundSessionPresentation.statusText(of: ended) == "exit 3")
    #expect(BackgroundSessionPresentation.tone(of: ended) == .ended)
    #expect(row(ownSession("k", project: project).exited(code: 129, signal: 1)).exitStatus == 129)
    #expect(row(ownSession("n", project: nil)).projectName == "No project")

    // An agent's spinner title (OSC 2) changes many times a second; the row
    // does not.
    func spinning(_ title: String) -> HostedSessionInfo {
        HostedSessionInfo(
            id: "s", name: "claude", cwd: project, pid: 10, title: title, owner: "CherryTests",
            tags: [PersistentSessionTag.kind: "agent", PersistentSessionTag.agent: "Claude", PersistentSessionTag.project: project]
        )
    }
    #expect(row(spinning("⠋ Thinking")) == row(spinning("⠙ Thinking")))

    // By project, running first, newest first.
    let early = Date(timeIntervalSince1970: 1_000)
    let late = Date(timeIntervalSince1970: 2_000)
    let sorted = BackgroundSessions.classify(
        [
            ownSession("z-old", project: "/p/zeta", createdAt: early),
            ownSession("a-ended", project: "/p/alpha", createdAt: late).exited(code: 0, signal: nil),
            ownSession("a-old", project: "/p/alpha", createdAt: early),
            ownSession("a-new", project: "/p/alpha", createdAt: late),
            ownSession("other", project: "/p/alpha", owner: "Someone"),
            ownSession("shown", project: "/p/alpha"),
            ownSession("ending", project: "/p/alpha")
        ],
        hostID: "host-a",
        owner: "CherryTests",
        isShown: { $0.id == "shown" },
        isEnding: { $0.id == "ending" },
        awaitingRestore: []
    )
    #expect(sorted.map(\.id) == ["a-new", "a-old", "a-ended", "z-old"])
}

// MARK: - Opening them

@Test @MainActor func openingABackgroundSessionAdoptsItWithItsKindAndTabID() async throws {
    let harness = try PersistentHarness()
    let project = harness.project.path
    let repository = RepositoryWorkspace(
        projectRoot: project,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    let model = makeModel(harness)
    defer {
        model.stop()
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let workspace = repository.activeWorkspace
    // The window's default shell.
    #expect(await harness.fake.wait { harness.creates().count == 1 })
    let agentTab = UUID()
    harness.fake.sessions += [
        ownSession("s-agent", tab: agentTab, project: project, name: "claude", kind: "agent", agent: "Claude"),
        ownSession("s-watched", project: project, name: "Watched", clients: 1)
    ]
    let list = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-agent", "s-watched"])

    func show(_ id: String) throws -> TerminalSession? {
        let info = try #require(list.sessions.first { $0.id == id })
        return repository.showBackgroundSession(
            PersistentSessionLaunch(attachment: try #require(harness.hosting.attachment(for: info)), info: info),
            worktreeRoot: project,
            hosting: harness.hosting
        )
    }
    // Adopted as the tab it was started for: an agent again, owning it.
    let tab = try #require(try show("s-agent"))
    #expect(tab.id == agentTab)
    #expect(tab.kind == .agent)
    #expect(tab.agentName == "Claude")
    #expect(tab.isPersistentLocalSession)
    #expect(tab.hostedAttachment == nil)
    #expect(harness.hosting.owningTab(of: "s-agent") === tab)
    #expect(workspace.selectedSessionID == agentTab)
    #expect(harness.creates().count == 1)
    // Shown again: the same tab.
    #expect(try show("s-agent") === tab)
    #expect(workspace.sessions.filter { $0.id == agentTab }.count == 1)

    // Another client shows this one: only attached.
    let watched = try #require(try show("s-watched"))
    #expect(watched.hostedAttachment?.sessionID == "s-watched")
    #expect(!watched.isPersistentLocalSession)
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func openingASessionOfAClosedWindowReopensItsProjectAndRevealsTheRestoredTab() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-background-open")
    let storeDirectory = try temporaryDirectory("cherry-background-open-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let logs = savedTab(title: "Logs", sessionID: "s-logs", root: root.path)
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [session(of: editor, root: root.path), session(of: logs, root: root.path)]
    saveState([editor, logs], root: root, in: store)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    var opened: [String?] = []
    var reopened: RepositoryWorkspace?
    // As the app's `openWindow`: the window registers a moment later.
    registry.projectWindowOpener = { projectRoot in
        opened.append(projectRoot)
        guard let projectRoot else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                reopened = openProject(
                    URL(fileURLWithPath: projectRoot), store: store, harness: harness, registry: registry, window: window
                )
            }
        }
    }
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        reopened?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    _ = try await harness.control.list()
    model.refresh()
    // No window shows the project: both of its sessions are in the background.
    #expect(Set(model.sessions.map(\.id)) == ["s-editor", "s-logs"])

    let item = try #require(model.sessions.first { $0.id == "s-logs" })
    await model.open(item)?.value
    #expect(opened.map(resolved) == [resolved(root.path)])
    let repository = try #require(reopened)
    let workspace = repository.activeWorkspace
    // The window's own restore brought back its tabs; the one asked for is shown.
    #expect(workspace.sessions.map(\.id) == [editor.id, logs.id])
    #expect(workspace.selectedSessionID == logs.id)
    #expect(harness.hosting.owningTab(of: "s-logs")?.id == logs.id)
    #expect(harness.creates().isEmpty)
    model.refresh()
    #expect(model.sessions.isEmpty)
}

@Test @MainActor func endingASessionOfAClosedWindowDropsItsTabWhenTheWindowReopens() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-background-end")
    let storeDirectory = try temporaryDirectory("cherry-background-end-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let logs = savedTab(title: "Logs", sessionID: "s-logs", root: root.path)
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [session(of: editor, root: root.path), session(of: logs, root: root.path)]
    saveState([editor, logs], root: root, in: store)
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    var reopened: RepositoryWorkspace?
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        reopened?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    _ = try await harness.control.list()
    model.refresh()
    await model.end(sessionID: "s-logs")?.value
    #expect(harness.requestIDs("remove") == ["s-logs"])
    // The closed window's saved tabs are not rewritten.
    #expect(store.load(repositoryRoot: repositoryKey(root))?.worktree(root: root.path)?.sessions.map(\.id) == [editor.id, logs.id])

    // The window opens again: its restore finds the session gone and drops
    // its tab, with no "Session ended" tab in its place.
    let repository = openProject(root, store: store, harness: harness, registry: registry, window: window)
    reopened = repository
    await repository.waitForPendingRestores()
    #expect(repository.activeWorkspace.sessions.map(\.id) == [editor.id])
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)?.sessions.map(\.id) == [editor.id])
}

@Test @MainActor func reopeningAWindowWhileItsSessionIsBeingEndedBringsNoTabBackForIt() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.terminationTimeout = .milliseconds(200)
    let harness = try PersistentHarness(configuration: configuration)
    let root = try temporaryDirectory("cherry-background-reopen-ending")
    let storeDirectory = try temporaryDirectory("cherry-background-reopen-ending-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let logs = savedTab(title: "Logs", sessionID: "s-logs", root: root.path)
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [session(of: editor, root: root.path), session(of: logs, root: root.path)]
    saveState([editor, logs], root: root, in: store)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    var reopened: RepositoryWorkspace?
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        reopened?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    _ = try await harness.control.list()
    model.refresh()
    // End: its program is slow to exit (the host's kill escalation), so the
    // ending is still under way ...
    harness.fake.killEndsSession = false
    let ending = try #require(model.end(sessionID: "s-logs"))
    #expect(harness.hosting.isEnding("s-logs"))
    // ... when the project's window opens again: its restore takes the
    // session for gone, as it will be, and builds no tab for it.
    let repository = openProject(root, store: store, harness: harness, registry: registry, window: window)
    reopened = repository
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    #expect(workspace.sessions.map(\.id) == [editor.id])
    #expect(harness.hosting.owningTab(of: "s-logs") == nil)

    harness.exit("s-logs", code: 143)
    await ending.value
    #expect(harness.requestIDs("remove") == ["s-logs"])
    #expect(workspace.sessions.map(\.id) == [editor.id])
    #expect(!workspace.sessions.contains { $0.persistentSessionEndedMessage != nil })
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)?.sessions.map(\.id) == [editor.id])
}

@Test @MainActor func openNeverAdoptsASessionThatIsBeingEnded() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.terminationTimeout = .milliseconds(200)
    let harness = try PersistentHarness(configuration: configuration)
    let project = harness.project.path
    let repository = RepositoryWorkspace(
        projectRoot: project,
        backendPolicy: harness.policy,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: project)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(registry.register(
        window: window, projectRoot: project, workspace: repository.activeWorkspace, repository: repository,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { harness.creates().count == 1 })
    let tabs = workspace.sessions.map(\.id)
    harness.fake.sessions += [ownSession("s-kept", project: project, name: "Kept")]
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.map(\.id) == ["s-kept"])
    let info = try #require(harness.hosting.sessionInfo("s-kept"))
    #expect(harness.hosting.canAdopt(info))

    // Ended meanwhile (End All, or a window's restore removing it) while
    // the Open waited: nothing adopts it, and no tab outlives it.
    harness.fake.killEndsSession = false
    let ending = try #require(model.end(sessionID: "s-kept"))
    #expect(!harness.hosting.canAdopt(info))
    await registry.showBackgroundSession(info, localSessions: harness.hosting, restoreWait: .milliseconds(100))
    #expect(workspace.sessions.map(\.id) == tabs)
    #expect(harness.hosting.owningTab(of: "s-kept") == nil)
    harness.exit("s-kept", code: 143)
    await ending.value
    #expect(harness.requestIDs("remove") == ["s-kept"])
    #expect(workspace.sessions.map(\.id) == tabs)
}

@Test @MainActor func aBackgroundTerminalWhoseShellExitedCleanlyIsRemovedNotListed() async throws {
    let harness = try PersistentHarness()
    let closesTabs = Recorder(true)
    let model = makeModel(harness, closesTabsOnCleanExit: { closesTabs.value })
    defer {
        model.stop()
        harness.cleanUp()
    }
    let project = harness.project.path
    harness.fake.sessions = [
        ownSession("s-clean", project: project, name: "zsh").exited(code: 0, signal: nil),
        ownSession("s-failed", project: project, name: "zsh").exited(code: 3, signal: nil),
        ownSession("s-command", project: project, name: "npm", kind: "command", command: "web").exited(code: 0, signal: nil),
        ownSession("s-agent", project: project, name: "claude", kind: "agent", agent: "Claude").exited(code: 0, signal: nil),
        ownSession("s-running", project: project, name: "zsh")
    ]
    // Its tab would have closed (and its window's restore removes it): the
    // list removes it rather than offering to show it.
    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-failed", "s-command", "s-agent", "s-running"])
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-clean"] })
    #expect(harness.requestIDs("kill").isEmpty)

    // Not while Settings › Sessions keeps such tabs: it is listed as "exit 0".
    harness.fake.sessions.append(ownSession("s-kept", project: project, name: "zsh").exited(code: 0, signal: nil))
    closesTabs.value = false
    _ = try await harness.control.list()
    model.refresh()
    let kept = try #require(model.sessions.first { $0.id == "s-kept" })
    #expect(BackgroundSessionPresentation.statusText(of: kept) == "exit 0")
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.requestIDs("remove") == ["s-clean"])
}

@Test func theInlineEndConfirmationIgnoresTheSecondClickOfADoubleClick() {
    let shown = Date(timeIntervalSince1970: 1_000)
    #expect(!BackgroundSessionPresentation.acceptsConfirmation(shownAt: shown, now: shown))
    #expect(!BackgroundSessionPresentation.acceptsConfirmation(shownAt: shown, now: shown.addingTimeInterval(0.2)))
    #expect(BackgroundSessionPresentation.acceptsConfirmation(
        shownAt: shown, now: shown.addingTimeInterval(BackgroundSessionPresentation.confirmationDelay)
    ))
    #expect(BackgroundSessionPresentation.acceptsConfirmation(shownAt: shown, now: shown.addingTimeInterval(2)))
}

// MARK: - The launch notice

/// Where a notice keeps the sessions it told about; removed by `cleanUp`.
private final class NoticeDefaults {
    let suite = "CherryTests.BackgroundNotice.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

/// A project window's chrome whose toasts never go by themselves and reach
/// no VoiceOver.
@MainActor
private func quietChromeState() -> ProjectWindowChromeState {
    ProjectWindowChromeState(toasts: ProjectWindowToasts(
        schedule: { _, _ in }, announce: { _ in }, voiceOverEnabled: { false }
    ))
}

/// Registers `window` with `registry` as the project window of `root`, with
/// `chromeState` and a workspace that runs nothing, which the caller keeps
/// (the registry holds it weakly).
@MainActor
private func registerWindow(
    _ window: NSWindow,
    root: String,
    chromeState: ProjectWindowChromeState,
    in registry: ProjectWindowRegistry
) -> TerminalWorkspace {
    let workspace = TerminalWorkspace(projectRoot: root, createInitialSession: false)
    #expect(registry.register(
        window: window, projectRoot: root, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    return workspace
}

@MainActor
private func makeNotice(
    model: BackgroundSessionsModel,
    registry: ProjectWindowRegistry,
    defaults: UserDefaults,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    canPresent: @escaping @MainActor (NSWindow) -> Bool = { _ in true }
) -> BackgroundSessionsNotice {
    BackgroundSessionsNotice(
        model: model,
        registry: registry,
        isEnabled: isEnabled,
        defaults: defaults,
        canPresent: canPresent,
        settleDelay: .zero,
        restoreWait: .seconds(10),
        retryDelay: 0.05,
        retries: 2
    )
}

private extension BackgroundSessionsNotice {
    /// What its toast named, once shown.
    var shownContent: Content? {
        if case .shown(let content) = phase { return content }
        return nil
    }
}

private let backgroundSessionsLine = "Open or end it from Background Sessions in the Cherry menu bar icon."
private let backgroundSessionsLinePlural = "Open or end them from Background Sessions in the Cherry menu bar icon."

@Test @MainActor func theLaunchNoticeWaitsForRestoresAndShowsItsToastOnce() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-background-notice")
    let storeDirectory = try temporaryDirectory("cherry-background-notice-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let noticeDefaults = try NoticeDefaults()
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        session(of: editor, root: root.path),
        ownSession("s-closed", project: root.path, name: "Scratch", foreground: "make"),
        ownSession("s-ended", project: root.path, name: "Done").exited(code: 1, signal: nil)
    ]
    saveState([editor], root: root, in: store)
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    let chromeState = quietChromeState()
    let gate = RestoreGate()
    let canPresent = Recorder(false)
    let model = makeModel(harness, registry: registry)
    let notice = makeNotice(
        model: model, registry: registry, defaults: noticeDefaults.defaults, canPresent: { _ in canPresent.value }
    )
    var repository: RepositoryWorkspace?
    defer {
        gate.open()
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        repository?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    // The launch asked for the window, which has not opened yet.
    notice.launchWindowsOpened(expecting: [root.path])
    #expect(notice.phase == .checking)
    try await Task.sleep(for: .milliseconds(100))
    repository = openProject(
        root, store: store, harness: harness, registry: registry, window: window, gate: gate, chromeState: chromeState
    )
    #expect(await eventually { gate.waiting == 1 })
    // Its restore is under way: nothing is said yet.
    try await Task.sleep(for: .milliseconds(200))
    #expect(notice.phase == .checking)
    #expect(chromeState.toasts.current == nil)

    gate.open()
    // No window can show it yet: it waits for one.
    #expect(await eventually {
        if case .waitingForWindow = notice.phase { return true }
        return false
    })
    #expect(chromeState.toasts.current == nil)
    canPresent.value = true
    // A window registers from its view's update (again and again): the
    // toast, SwiftUI state, goes up on the next turn, once.
    notice.projectWindowDidRegister(window)
    notice.projectWindowDidRegister(window)
    #expect(chromeState.toasts.current == nil)
    #expect(await eventually { notice.shownContent != nil })
    let shownToastID = try #require(chromeState.toasts.current?.id)
    try await Task.sleep(for: .milliseconds(50))
    #expect(chromeState.toasts.current?.id == shownToastID)
    // Only the session at work no tab shows: not the restored one, not the
    // ended one.
    let content = try #require(notice.shownContent)
    #expect(content.sessionIDs == ["s-closed"])
    // A toast in that window, asking nothing: no alert sheet.
    #expect(window.attachedSheet == nil)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "1 session is still running in the background")
    #expect(toast.message == "From a tab or window you closed (\(root.lastPathComponent)). \(backgroundSessionsLine)")
    #expect(toast.actions.map(\.title) == ["Reopen", "End…"])
    #expect(toast.length == .long)
    #expect(toast.isUnprompted)
    #expect(notice.toldIDs().isEmpty)

    // Dismissed (or its time ran out): told, so it is not named again, at
    // this launch or the next.
    chromeState.toasts.dismiss(id: toast.id)
    #expect(notice.toldIDs() == ["s-closed"])
    notice.launchWindowsOpened(expecting: [root.path])
    #expect(notice.shownContent == content)
    let nextLaunch = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    nextLaunch.launchWindowsOpened()
    #expect(await eventually { nextLaunch.phase == .notNeeded })
    #expect(chromeState.toasts.current == nil)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func theLaunchNoticeForgetsSessionsTheHostNoLongerListsAndItsEndEndsOnlyThoseItNamed() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    let chromeState = quietChromeState()
    let windowWorkspace = registerWindow(window, root: harness.project.path, chromeState: chromeState, in: registry)
    let confirmations = Confirmations()
    let model = makeModel(harness, registry: registry, confirmations: confirmations)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: harness.project.path)
        windowWorkspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    let project = harness.project.path
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        ownSession("s-told", project: project, name: "server", kind: "command", command: "server"),
        ownSession("s-new", project: project, name: "worker", kind: "command", command: "worker"),
        ownSession("s-other", project: "/elsewhere/posthog", name: "claude", kind: "agent", agent: "Claude"),
        ownSession("s-idle", project: project, name: "Shell")
    ]
    _ = try await harness.control.list()
    // Told about at an earlier launch: "s-told", and one the host no longer has.
    noticeDefaults.defaults.set(["s-gone", "s-told"], forKey: BackgroundSessionsNotice.toldIDsKey)
    let notice = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    notice.launchWindowsOpened()
    #expect(await eventually { notice.shownContent != nil })
    #expect(noticeDefaults.defaults.stringArray(forKey: BackgroundSessionsNotice.toldIDsKey) == ["s-told"])
    let content = try #require(notice.shownContent)
    #expect(Set(content.sessionIDs) == ["s-new", "s-other"])
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "2 sessions are still running in the background")
    #expect(toast.message?.hasPrefix("From tabs or windows you closed (") == true)
    #expect(toast.message?.hasSuffix(backgroundSessionsLinePlural) == true)

    // End…: the End Background Sessions confirmation on this window, for the
    // sessions it named only (not the told one, not the idle shell).
    chromeState.toasts.performAction(of: toast.id, at: 1)
    #expect(chromeState.toasts.current == nil)
    #expect(Set(notice.toldIDs()) == ["s-told", "s-new", "s-other"])
    let alert = try #require(confirmations.alerts.first)
    #expect(alert.messageText == "End 2 background sessions?")
    #expect(confirmations.askedFrom.first! === window)
    confirmations.answer(.alertFirstButtonReturn)
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")) == ["s-new", "s-other"] })
    try await Task.sleep(for: .milliseconds(100))
    #expect(Set(harness.requestIDs("kill")) == ["s-new", "s-other"])
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-told", "s-idle"])
}

@Test @MainActor func theLaunchNoticeNamesOnlySessionsAtWorkNeverAnIdleShell() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    let chromeState = quietChromeState()
    let windowWorkspace = registerWindow(window, root: harness.project.path, chromeState: chromeState, in: registry)
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: harness.project.path)
        windowWorkspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    let project = harness.project.path
    harness.fake.pendingHolders = 0
    // An idle shell whose tab was closed: not worth a word at launch. It
    // stays in the menu bar's Background sessions list.
    harness.fake.sessions = [ownSession("s-idle", project: project, name: "Shell 3")]
    _ = try await harness.control.list()
    let idleOnly = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    idleOnly.launchWindowsOpened()
    #expect(await eventually { idleOnly.phase == .notNeeded })
    #expect(chromeState.toasts.current == nil)
    model.refresh()
    #expect(model.sessions.map(\.id) == ["s-idle"])
    #expect(idleOnly.toldIDs().isEmpty)

    // With a command at work beside it: only the command is named.
    harness.fake.sessions.append(ownSession("s-command", project: project, name: "server", kind: "command", command: "server"))
    _ = try await harness.control.list()
    let withCommand = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    withCommand.launchWindowsOpened()
    #expect(await eventually { withCommand.shownContent != nil })
    #expect(withCommand.shownContent?.sessionIDs == ["s-command"])
    #expect(chromeState.toasts.current?.title == "1 session is still running in the background")
}

@Test @MainActor func theLaunchNoticeWaitsForAClosedTabsToastAndComesBackAfterOneShownOverIt() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let window = testWindow()
    let chromeState = quietChromeState()
    let windowWorkspace = registerWindow(window, root: harness.project.path, chromeState: chromeState, in: registry)
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: harness.project.path)
        windowWorkspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        ownSession("s-command", project: harness.project.path, name: "server", kind: "command", command: "server")
    ]
    _ = try await harness.control.list()
    let reopened = Recorder(0)
    func closedTabToast(_ name: String) -> ProjectWindowToast {
        ProjectWindowToast(
            name: name, predicate: " is running in the background", message: backgroundSessionsLine,
            action: .init(title: "Reopen") { reopened.value += 1 }
        )
    }

    // The user closed a tab at work while the launch's check ran: its toast
    // (and its Reopen) stays, and the notice waits for it to go.
    let closed = closedTabToast("Claude")
    chromeState.toasts.show(closed)
    let notice = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    notice.launchWindowsOpened()
    #expect(await eventually { notice.shownContent != nil })
    #expect(chromeState.toasts.current?.id == closed.id)
    chromeState.toasts.performAction(of: closed.id)
    #expect(reopened.value == 1)
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "1 session is still running in the background")
    #expect(notice.toldIDs().isEmpty)

    // Another tab closed while the notice shows: its toast goes over the
    // notice, which is set aside, not told, and comes back once it goes.
    let second = closedTabToast("worker")
    chromeState.toasts.show(second)
    #expect(chromeState.toasts.current?.id == second.id)
    #expect(notice.toldIDs().isEmpty)
    chromeState.toasts.dismiss(id: second.id)
    #expect(chromeState.toasts.current?.id == toast.id)
    chromeState.toasts.dismiss(id: toast.id)
    #expect(notice.toldIDs() == ["s-command"])
    #expect(chromeState.toasts.current == nil)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func theLaunchNoticesReopenBringsEachSessionBackInItsOwnProjectWindow() async throws {
    let harness = try PersistentHarness()
    let rootA = try temporaryDirectory("cherry-background-notice-a")
    let rootB = try temporaryDirectory("cherry-background-notice-b")
    let storeDirectory = try temporaryDirectory("cherry-background-notice-reopen-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let windowA = testWindow()
    let windowB = testWindow()
    let chromeState = quietChromeState()
    var opened: [String?] = []
    var repositoryB: RepositoryWorkspace?
    // As the app's `openWindow`: the window registers a moment later.
    registry.projectWindowOpener = { projectRoot in
        opened.append(projectRoot)
        guard let projectRoot else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                repositoryB = openProject(
                    URL(fileURLWithPath: projectRoot), store: store, harness: harness, registry: registry,
                    window: windowB, chromeState: quietChromeState()
                )
            }
        }
    }
    let serverTab = UUID()
    let agentTab = UUID()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        ownSession("s-server", tab: serverTab, project: rootA.path, name: "server", kind: "command", command: "server"),
        ownSession("s-agent", tab: agentTab, project: rootB.path, name: "claude", kind: "agent", agent: "Claude")
    ]
    let model = makeModel(harness, registry: registry)
    let repositoryA = openProject(
        rootA, store: store, harness: harness, registry: registry, window: windowA, chromeState: chromeState
    )
    let notice = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    defer {
        model.stop()
        registry.unregister(window: windowA, projectRoot: rootA.path)
        registry.unregister(window: windowB, projectRoot: rootB.path)
        repositoryA.closeAllSessions(intent: .windowClosed)
        repositoryB?.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    _ = try await harness.control.list()
    notice.launchWindowsOpened(expecting: [rootA.path])
    #expect(await eventually { notice.shownContent != nil })
    #expect(Set(try #require(notice.shownContent).sessionIDs) == ["s-server", "s-agent"])
    let toast = try #require(chromeState.toasts.current)
    #expect(opened.isEmpty)

    // Reopen: each session comes back as the tab it was started for, in its
    // own project's window (B's opens again), and they count as told.
    chromeState.toasts.performAction(of: toast.id, at: 0)
    #expect(chromeState.toasts.current == nil)
    #expect(Set(notice.toldIDs()) == ["s-server", "s-agent"])
    #expect(await eventually {
        harness.hosting.owningTab(of: "s-server") != nil && harness.hosting.owningTab(of: "s-agent") != nil
    })
    #expect(opened.map(resolved) == [resolved(rootB.path)])
    let server = try #require(harness.hosting.owningTab(of: "s-server"))
    #expect(server.id == serverTab)
    #expect(server.kind == .command)
    #expect(repositoryA.activeWorkspace.sessions.contains { $0 === server })
    let agent = try #require(harness.hosting.owningTab(of: "s-agent"))
    #expect(agent.id == agentTab)
    #expect(agent.kind == .agent)
    #expect(try #require(repositoryB).activeWorkspace.sessions.contains { $0 === agent })
    model.refresh()
    #expect(model.sessions.isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func sessionsKeptByDetachingTheirTabsAreNotNamedButAnOrphanAtWorkIs() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let model = makeModel(harness, registry: registry)
    let notice = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    // As the app's policy tells the app's notice.
    var policy = harness.policy
    policy.sessionDetached = { notice.noteTold([$0]) }
    let workspace = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
    let window = testWindow()
    let chromeState = quietChromeState()
    #expect(registry.register(
        window: window, projectRoot: harness.project.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: chromeState
    ))
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: harness.project.path)
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    harness.fake.pendingHolders = 0
    let anchor = workspace.addSession(title: "Anchor")
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "npm", arguments: "run dev"),
        projectRoot: harness.project.path
    )
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    let shell = workspace.addSession(title: "Shell 3")
    for tab in [anchor, command, agent, shell] {
        #expect(await harness.waitUntilAttached(tab))
    }
    let kept = try [command, agent, shell].map { try #require($0.persistentSession?.sessionID) }

    // Detached by the user (the sidebar's Detach, a close question's
    // Detach Instead, ⌘D): kept on purpose, so told about.
    SessionCloseCoordinator.detach(command, in: workspace, chromeState: chromeState, registry: registry)
    SessionCloseCoordinator.close(agent, in: workspace, chromeState: chromeState, registry: registry)
    let request = try #require(chromeState.pendingTabClose)
    SessionCloseCoordinator.answerTabClose(.detach, to: request, chromeState: chromeState)
    workspace.select(shell)
    SessionCloseCoordinator.detachSelectedTabOrWindow(
        workspace: workspace, repository: nil, chromeState: chromeState, window: window, registry: registry
    )
    #expect(workspace.sessions.map(\.id) == [anchor.id])
    #expect(notice.toldIDs() == kept)
    chromeState.toasts.dismiss()

    // A session that went to the background without a choice (an orphan).
    harness.fake.sessions.append(
        ownSession("s-orphan", project: harness.project.path, name: "worker", kind: "command", command: "worker")
    )
    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == Set(kept + ["s-orphan"]))
    notice.launchWindowsOpened()
    #expect(await eventually { notice.shownContent != nil })
    #expect(notice.shownContent?.sessionIDs == ["s-orphan"])
    #expect(chromeState.toasts.current?.title == "1 session is still running in the background")
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func sessionsKeptByClosingTheirWindowOnPurposeAreNotNamedButOnesKeptWithoutAChoiceAre() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let model = makeModel(harness, registry: registry)
    let notice = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    let sessionsKeptInBackground = ProjectWindowCloseDelegate.sessionsKeptInBackground
    let askAboutSessions = ProjectWindowCloseDelegate.askAboutSessions
    let pendingAnswer = Recorder<(@MainActor (SessionTeardownAnswer, LocalSessionsOnQuit?) -> Void)?>(nil)
    ProjectWindowCloseDelegate.sessionsKeptInBackground = { notice.noteTold($0) }
    ProjectWindowCloseDelegate.askAboutSessions = { _, _, answer in pendingAnswer.value = answer }
    let elsewhere = try temporaryDirectory("cherry-background-notice-window")
    let noticeWindow = testWindow()
    let chromeState = quietChromeState()
    let windowWorkspace = registerWindow(noticeWindow, root: elsewhere.path, chromeState: chromeState, in: registry)
    var workspaces: [TerminalWorkspace] = []
    defer {
        ProjectWindowCloseDelegate.sessionsKeptInBackground = sessionsKeptInBackground
        ProjectWindowCloseDelegate.askAboutSessions = askAboutSessions
        model.stop()
        registry.unregister(window: noticeWindow, projectRoot: elsewhere.path)
        windowWorkspace.closeAllSessions(intent: .windowClosed)
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
        noticeDefaults.cleanUp()
        try? FileManager.default.removeItem(at: elsewhere)
    }
    harness.fake.pendingHolders = 0
    /// A window of the harness's project with a command at work, and its
    /// close delegate.
    func openWindow(_ name: String, shell: Bool = false) async throws -> (NSWindow, ProjectWindowCloseDelegate, [String]) {
        let workspace = harness.workspace()
        workspaces.append(workspace)
        var tabs = [workspace.addCommandSession(
            command: ProjectCommandDefinition(name: name, command: name), projectRoot: harness.project.path
        )]
        if shell { tabs.append(workspace.addSession(title: "Shell")) }
        for tab in tabs {
            #expect(await harness.waitUntilAttached(tab))
        }
        let window = testWindow()
        let delegate = ProjectWindowCloseDelegate(window: window)
        delegate.workspace = workspace
        return (window, delegate, try tabs.map { try #require($0.persistentSession?.sessionID) })
    }
    func closeWithoutConfirmation(_ window: NSWindow, _ delegate: ProjectWindowCloseDelegate) {
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    // Keep Running, answered.
    harness.settings.value.localSessionsOnQuit = .ask
    let (answered, answeredDelegate, answeredSessions) = try await openWindow("server", shell: true)
    #expect(!answeredDelegate.windowShouldClose(answered))
    let answer = try #require(pendingAnswer.value)
    answer(.keep, nil)
    #expect(Set(notice.toldIDs()) == Set(answeredSessions))

    // Settings › Sessions keeps them without asking.
    harness.settings.value.localSessionsOnQuit = .keep
    let (preferred, preferredDelegate, preferredSessions) = try await openWindow("worker")
    #expect(preferredDelegate.windowShouldClose(preferred))
    closeWithoutConfirmation(preferred, preferredDelegate)
    #expect(Set(notice.toldIDs()) == Set(answeredSessions + preferredSessions))

    // Closed without its question while it would ask: kept, but nobody chose.
    harness.settings.value.localSessionsOnQuit = .ask
    let (unasked, unaskedDelegate, unaskedSessions) = try await openWindow("watcher")
    closeWithoutConfirmation(unasked, unaskedDelegate)
    #expect(Set(notice.toldIDs()) == Set(answeredSessions + preferredSessions))

    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == Set(answeredSessions + preferredSessions + unaskedSessions))
    notice.launchWindowsOpened()
    #expect(await eventually { notice.shownContent != nil })
    #expect(notice.shownContent?.sessionIDs == unaskedSessions)
    #expect(chromeState.toasts.current?.title == "1 session is still running in the background")
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func theLaunchNoticeIsOffInSettingsWithoutTheLockAndNeverStartsAHost() async throws {
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    let registry = ProjectWindowRegistry()
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        ownSession("s-background", project: harness.project.path, name: "server", kind: "command", command: "server")
    ]

    // This run never reached the host: it is not started to find out.
    let unreached = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults)
    unreached.launchWindowsOpened()
    #expect(await eventually { unreached.phase == .notNeeded })
    #expect(harness.fake.launches.isEmpty)

    // Off in Settings › Sessions.
    _ = try await harness.control.list()
    let lists = harness.fake.requests("list").count
    let off = makeNotice(model: model, registry: registry, defaults: noticeDefaults.defaults, isEnabled: { false })
    off.launchWindowsOpened()
    #expect(await eventually { off.phase == .notNeeded })
    #expect(harness.fake.requests("list").count == lists)

    // Another copy holds the instance lock.
    let directory = try temporaryDirectory("cherry-background-notice-lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appendingPathComponent("instance.lock")
    let holder = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
    #expect(holder.isHeld)
    defer { holder.release() }
    let control = harness.control
    let secondCopy = BackgroundSessionsModel(
        localSessions: PersistentLocalSessions(
            owner: "CherryTests", control: { control }, installationUnavailableReason: { nil },
            status: PersistentSessionsStatus(),
            instanceLock: AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests"),
            configuration: PersistentHarness.fastConfiguration
        ),
        registry: registry,
        presentAlert: { _, _, _ in }
    )
    let locked = makeNotice(model: secondCopy, registry: registry, defaults: noticeDefaults.defaults)
    locked.launchWindowsOpened()
    #expect(await eventually { locked.phase == .notNeeded })
}

@Test @MainActor func theLaunchNoticeCopyCountsSessionsAndNamesProjects() throws {
    func item(_ id: String, _ project: String?) -> BackgroundSession {
        BackgroundSessionPresentation.session(
            ownSession(id, project: project, kind: "command", command: "server"), hostID: "host-a"
        )
    }
    let one = BackgroundSessionsNotice.content(for: [item("a", "/p/cherry")])
    #expect(one.title == "1 session is still running in the background")
    #expect(one.message == "From a tab or window you closed (cherry). \(backgroundSessionsLine)")
    #expect(one.sessionIDs == ["a"])

    let two = BackgroundSessionsNotice.content(for: [item("a", "/p/cherry"), item("b", "/p/cherry")])
    #expect(two.title == "2 sessions are still running in the background")
    #expect(two.message == "From tabs or windows you closed (cherry). \(backgroundSessionsLinePlural)")
    #expect(BackgroundSessionsNotice.content(for: [item("a", "/p/cherry"), item("b", "/p/posthog")]).message
        .hasPrefix("From tabs or windows you closed (cherry and posthog). "))
    let many = BackgroundSessionsNotice.content(for: [
        item("a", "/p/cherry"), item("b", "/p/posthog"), item("c", "/p/uv"), item("d", "/p/uv")
    ])
    #expect(many.title == "4 sessions are still running in the background")
    #expect(many.message.hasPrefix("From tabs or windows you closed (cherry, posthog and 1 more). "))
    // Without a project, none is named.
    #expect(BackgroundSessionsNotice.content(for: [item("a", nil)]).message
        == "From a tab or window you closed. \(backgroundSessionsLine)")

    // Its toast: Reopen, End… and dismiss, for twice a closed tab's time.
    let harness = try PersistentHarness()
    let noticeDefaults = try NoticeDefaults()
    defer {
        harness.cleanUp()
        noticeDefaults.cleanUp()
    }
    let notice = makeNotice(model: makeModel(harness), registry: ProjectWindowRegistry(), defaults: noticeDefaults.defaults)
    let toast = notice.toast(for: two, on: testWindow())
    #expect(toast.title == two.title)
    #expect(toast.name.isEmpty)
    #expect(toast.message == two.message)
    #expect(toast.announcement == "\(two.title). \(two.message)")
    #expect(toast.actions.map(\.title) == ["Reopen", "End…"])
    #expect(toast.length == .long)
    #expect(toast.isUnprompted)
    #expect(toast.onDismiss != nil)
}

@Test @MainActor func theSessionsANoticeWasToldAboutAreKeptNewestLastAndBounded() throws {
    let noticeDefaults = try NoticeDefaults()
    defer { noticeDefaults.cleanUp() }
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let notice = makeNotice(
        model: makeModel(harness), registry: ProjectWindowRegistry(), defaults: noticeDefaults.defaults
    )
    notice.noteTold([])
    #expect(notice.toldIDs().isEmpty)
    notice.noteTold(["a", "b"])
    notice.noteTold(["a", "c"])
    #expect(notice.toldIDs() == ["b", "a", "c"])
    // Kept where the next launch reads them.
    #expect(noticeDefaults.defaults.stringArray(forKey: BackgroundSessionsNotice.toldIDsKey) == ["b", "a", "c"])
    let nextLaunch = makeNotice(
        model: makeModel(harness), registry: ProjectWindowRegistry(), defaults: noticeDefaults.defaults
    )
    #expect(nextLaunch.toldIDs() == ["b", "a", "c"])
    notice.noteTold((0..<BackgroundSessionsNotice.toldIDsLimit).map { "s-\($0)" })
    #expect(notice.toldIDs().count == BackgroundSessionsNotice.toldIDsLimit)
    #expect(notice.toldIDs().first == "s-0")
}


// MARK: - Bells and notifications of background sessions

@Test @MainActor func aBackgroundSessionsBellsAndNotificationsArePostedNamingItAndMarkedUnread() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let store = WorkspaceStateStore(directory: try temporaryDirectory("cherry-background-unread"))
    harness.hosting.endedSessionsStore = store
    let clock = Recorder(Date())
    let posted = Recorder<[BackgroundSessionNotificationContent]>([])
    let model = makeModel(harness, postNotification: { posted.value.append($0) }, now: { clock.value })
    model.start()
    defer {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: store.directory)
    }
    let project = harness.project.path
    // A tab that follows its own session: its signals are its own.
    let shown = workspace.addSession(title: "Shown")
    #expect(await harness.waitUntilAttached(shown))
    let shownID = try #require(shown.persistentSession?.sessionID)
    harness.fake.sessions += [
        ownSession("s-agent", project: project, name: "claude", kind: "agent", agent: "Claude"),
        ownSession("s-shell", project: project, name: "zsh")
    ]
    _ = try await harness.control.list()
    model.refresh()
    #expect(Set(model.sessions.map(\.id)) == ["s-agent", "s-shell"])
    func push(_ event: HostSessionEvent) {
        harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(event))
    }

    push(.notification(id: "s-agent", title: "Claude", body: "Waiting for your input"))
    #expect(await harness.fake.wait { posted.value.count == 1 })
    let first = try #require(posted.value.first)
    #expect(first.sessionID == "s-agent")
    #expect(first.title == "Claude")
    #expect(first.subtitle == "\(BackgroundSessionPresentation.projectName(projectRoot: project)) · in the background")
    #expect(first.body == "Claude: Waiting for your input")
    // With its host's identity: This Mac's or a device's (phase 3).
    #expect(first.userInfo == [
        BackgroundSessionNotificationContent.sessionIDKey: "s-agent",
        BackgroundSessionNotificationContent.hostIDKey: "host-a",
    ])
    #expect(model.unreadSessionIDs == ["s-agent"])
    #expect(store.unreadSessions(hostID: "host-a") == ["s-agent"])

    // A bell: posted once, then never again until the session is opened
    // (it only stays unread), however long it keeps ringing.
    push(.bell(id: "s-shell"))
    #expect(await harness.fake.wait { posted.value.count == 2 })
    #expect(posted.value.last?.body == "Terminal bell")
    push(.bell(id: "s-shell"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(posted.value.count == 2)
    clock.value = clock.value.addingTimeInterval(3_600)
    push(.bell(id: "s-shell"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(posted.value.count == 2)
    #expect(model.unreadSessionIDs == ["s-agent", "s-shell"])

    // The shown tab's bell is the tab's, not a background notification.
    let bells = Recorder(0)
    shown.bellHandler = { _ in bells.value += 1 }
    push(.bell(id: shownID))
    #expect(await harness.fake.wait { bells.value == 1 })
    #expect(posted.value.count == 2)

    // The tab that shows it next comes up unread, and the mark goes.
    let info = try #require(harness.hosting.sessionInfo("s-agent"))
    let tab = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: info)), info: info)
    #expect(tab.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(tab))
    #expect(tab.persistentSession?.sessionID == "s-agent")
    #expect(tab.hasUnreadNotification)
    #expect(store.unreadSessions(hostID: "host-a") == ["s-shell"])
}

@Test @MainActor func aSignalNoTabTookIsPostedOnceItsSessionIsInTheBackground() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.pendingSignalLifetime = 0.3
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    let posted = Recorder<[BackgroundSessionNotificationContent]>([])
    let model = makeModel(harness, postNotification: { posted.value.append($0) })
    model.start()
    defer {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    // Its tab is open but does not follow it yet (as while its Create
    // answer or its window's restore is still to come): kept for that tab.
    let tab = workspace.addSession(title: "Build")
    #expect(await harness.waitUntilAttached(tab))
    harness.fake.sessions.append(ownSession("s-later", tab: tab.id, project: project, name: "Later"))
    _ = try await harness.control.list()
    harness.fake.connections.last(where: { !$0.isClosed })?
        .push(.event(.notification(id: "s-later", title: "", body: "Done")))
    try await Task.sleep(for: .milliseconds(100))
    #expect(posted.value.isEmpty)
    // That tab closed meanwhile: once the wait is over, it is posted.
    workspace.closeAllSessions(intent: .windowClosed)
    #expect(await harness.fake.wait { posted.value.count == 1 })
    #expect(posted.value.first?.body == "Done")
    try await Task.sleep(for: .milliseconds(500))
    #expect(posted.value.count == 1)
}

@Test @MainActor func clickingABackgroundSessionsNotificationOpensItAsOpenDoes() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-background-click")
    let storeDirectory = try temporaryDirectory("cherry-background-click-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    harness.fake.pendingHolders = 0
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let window = testWindow()
    let repository = openProject(root, store: store, harness: harness, registry: registry, window: window)
    let model = makeModel(harness, registry: registry)
    defer {
        model.stop()
        registry.unregister(window: window, projectRoot: root.path)
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    await repository.waitUntilSessionsRestored(before: ContinuousClock.now + .seconds(5))
    let agentTab = UUID()
    harness.fake.sessions.append(
        ownSession("s-agent", tab: agentTab, project: root.path, name: "claude", kind: "agent", agent: "Claude")
    )
    _ = try await harness.control.list()
    TerminalNotificationCenter.shared.handleResponse(
        userInfo: [BackgroundSessionNotificationContent.sessionIDKey: "s-agent"],
        backgroundSessions: model
    )
    #expect(await harness.fake.wait { harness.hosting.owningTab(of: "s-agent") != nil })
    let tab = try #require(harness.hosting.owningTab(of: "s-agent"))
    #expect(tab.id == agentTab)
    #expect(tab.kind == .agent)
    #expect(repository.activeWorkspace.selectedSessionID == agentTab)
}

// MARK: - Removing ended sessions

@Test @MainActor func endedBackgroundSessionsNoSavedTabNamesAreRemovedAfterTheGracePeriod() async throws {
    let harness = try PersistentHarness()
    let directory = try temporaryDirectory("cherry-background-gc")
    let store = WorkspaceStateStore(directory: directory)
    harness.hosting.endedSessionsStore = store
    let clock = Recorder(Date())
    let active = Recorder(true)
    let model = makeModel(harness, endedSessionGrace: 10, now: { clock.value }, isAppActive: { active.value })
    defer {
        model.stop()
        harness.cleanUp()
        try? FileManager.default.removeItem(at: directory)
    }
    /// Refreshes once a second (as the app's timer does) for `seconds`.
    func pass(_ seconds: Int) {
        for _ in 0..<seconds {
            clock.value = clock.value.addingTimeInterval(1)
            model.refresh()
        }
    }
    let project = harness.project.path
    // A closed window's saved tab names one of them: its restore shows how
    // it ended ("Session ended (exit 3)"), so it stays. Another is named
    // only by a set-aside copy of a state file, which keeps it too.
    let saved = savedTab(title: "Kept", sessionID: "s-named", root: project)
    saveState([saved], root: harness.project, in: store)
    try Data(#"{"version":2,"sessions":[{"hosted":{"sessionID":"s-set-aside"}}]}"#.utf8)
        .write(to: directory.appendingPathComponent("\(String(repeating: "c", count: 64)).json.v2-20260101T000000Z.bak"))
    harness.fake.sessions = [
        ownSession("s-orphan", project: project, name: "Gone").exited(code: 2, signal: nil),
        ownSession("s-named", tab: saved.id, project: project, name: "Kept").exited(code: 3, signal: nil),
        ownSession("s-set-aside", project: project, name: "Old").exited(code: 4, signal: nil),
        HostedSessionInfo(
            id: "s-crashed", name: "Crashed", cwd: project, state: .exited, exitCode: 1, owner: "CherryTests",
            tags: [PersistentSessionTag.kind: "terminal", PersistentSessionTag.project: project],
            endedBy: HostSessionEnd.holderLost
        ),
        ownSession("s-unread", project: project, name: "Rang").exited(code: 5, signal: nil),
        ownSession("s-running", project: project, name: "Server")
    ]
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.sessions.count == 6)
    // Its bell was not seen: it stays.
    #expect(model.backgroundSessionDidSignal(try #require(harness.hosting.sessionInfo("s-unread")), .bell))

    // Time while the app is in the background, and a sleep of the Mac,
    // do not count.
    active.value = false
    pass(20)
    active.value = true
    clock.value = clock.value.addingTimeInterval(3_600)
    model.refresh()
    pass(9)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.requestIDs("remove").isEmpty)

    pass(2)
    #expect(Set(model.sessions.map(\.id)) == ["s-named", "s-set-aside", "s-crashed", "s-unread", "s-running"])
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-orphan"] })
    #expect(harness.requestIDs("kill").isEmpty)
    // The named one is checked again only after another grace period.
    saveState([], root: harness.project, in: store)
    pass(5)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.requestIDs("remove") == ["s-orphan"])
    pass(6)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-orphan", "s-named"] })
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.requestIDs("remove") == ["s-orphan", "s-named"])
}

@Test @MainActor func clearEndedRemovesEveryEndedBackgroundSessionAndNoRunningOne() async throws {
    let harness = try PersistentHarness()
    let model = makeModel(harness)
    defer {
        model.stop()
        harness.cleanUp()
    }
    let project = harness.project.path
    harness.fake.sessions = [
        ownSession("s-a", project: project, name: "A").exited(code: 2, signal: nil),
        ownSession("s-b", project: project, name: "B", kind: "command", command: "web").exited(code: 1, signal: nil),
        ownSession("s-running", project: project, name: "Server")
    ]
    _ = try await harness.control.list()
    model.refresh()
    model.clearEnded()
    #expect(model.sessions.map(\.id) == ["s-running"])
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")) == ["s-a", "s-b"] })
    #expect(harness.requestIDs("kill").isEmpty)
}

@Test @MainActor func theStagedResourcesAnyRunningSessionNamesAreKept() async throws {
    let harness = try PersistentHarness()
    let calls = Recorder<[Set<String>]>([])
    let model = makeModel(harness, removeStaleResources: { calls.value.append($0) })
    defer {
        model.stop()
        harness.cleanUp()
    }
    let project = harness.project.path
    func tagged(_ info: HostedSessionInfo, _ copy: String) -> HostedSessionInfo {
        var tags = info.tags
        tags[PersistentSessionTag.resources] = copy
        return HostedSessionInfo(
            id: info.id, name: info.name, cwd: info.cwd, state: info.state, pid: info.pid,
            exitCode: info.exitCode, owner: info.owner, tags: tags
        )
    }
    // An untagged running session of this app (from before the tag): which
    // copy it reads cannot be told, so nothing is removed.
    harness.fake.sessions = [
        tagged(ownSession("s-new", project: project), "copy-a"),
        ownSession("s-old", project: project)
    ]
    model.refresh()
    #expect(calls.value.isEmpty)
    _ = try await harness.control.list()
    model.refresh()
    #expect(calls.value.isEmpty)

    // Every running session of this app is tagged: every copy any running
    // session names (another owner's too) is kept; an ended one's is not.
    let second = makeModel(harness, removeStaleResources: { calls.value.append($0) })
    defer { second.stop() }
    harness.fake.sessions = [
        tagged(ownSession("s-new", project: project), "copy-a"),
        tagged(ownSession("s-other", project: project, owner: "Someone else"), "copy-b"),
        tagged(ownSession("s-ended", project: project), "copy-c").exited(code: 1, signal: nil),
        ownSession("s-cli", project: project, owner: nil)
    ]
    _ = try await harness.control.list()
    second.refresh()
    second.refresh()
    #expect(calls.value == [["copy-a", "copy-b"]])
}

@Test @MainActor func theStagedResourcesAreLeftAloneWhileTheHostCannotBeListed() async throws {
    let harness = try PersistentHarness()
    let calls = Recorder<[Set<String>]>([])
    let model = makeModel(harness, removeStaleResources: { calls.value.append($0) })
    defer {
        model.stop()
        harness.cleanUp()
    }
    model.refresh()
    #expect(calls.value.isEmpty)
    // A restarted daemon that still expects holders: not complete yet.
    harness.fake.pendingHolders = 2
    _ = try? await harness.control.list()
    model.refresh()
    #expect(calls.value.isEmpty)
}

// MARK: - Removing a project

@Test @MainActor func removingAProjectOffersToEndItsBackgroundSessions() async throws {
    let harness = try PersistentHarness()
    let model = makeModel(harness)
    let suite = "CherryTests.ProjectRemoval.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AgentSettings(defaults: defaults)
    defer {
        model.stop()
        harness.cleanUp()
        defaults.removePersistentDomain(forName: suite)
    }
    let project = try #require(settings.addProject(path: harness.project.path))
    let other = try temporaryDirectory("cherry-other-project")
    defer { try? FileManager.default.removeItem(at: other) }
    harness.fake.sessions = [
        ownSession("s-mine", project: project.root, name: "Server"),
        ownSession("s-ended", project: project.root, name: "Old").exited(code: 1, signal: nil),
        ownSession("s-other", project: other.path, name: "Elsewhere")
    ]
    _ = try await harness.control.list()
    let asked = Recorder<[NSAlert]>([])
    let answers = Recorder<[@MainActor (NSApplication.ModalResponse) -> Void]>([])
    let present: ProjectRemoval.AlertPresenter = { alert, answer in
        asked.value.append(alert)
        answers.value.append(answer)
    }

    // Cancel: nothing changes.
    ProjectRemoval.remove(project, settings: settings, background: model, present: present)
    let alert = try #require(asked.value.first)
    #expect(alert.messageText == "End the 2 background sessions of “\(project.name)”?")
    #expect(alert.buttons.map(\.title) == ["End Sessions", "Keep Running", "Cancel"])
    answers.value[0](.alertThirdButtonReturn)
    #expect(settings.projects.contains { $0.root == project.root })
    #expect(harness.fake.requests("kill").isEmpty)

    // Keep Running: removed, the sessions stay.
    ProjectRemoval.remove(project, settings: settings, background: model, present: present)
    answers.value[1](.alertSecondButtonReturn)
    #expect(!settings.projects.contains { $0.root == project.root })
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("kill").isEmpty)

    // End Sessions: its sessions end, never another project's.
    _ = settings.addProject(path: project.root)
    ProjectRemoval.remove(project, settings: settings, background: model, present: present)
    answers.value[2](.alertFirstButtonReturn)
    #expect(!settings.projects.contains { $0.root == project.root })
    #expect(await harness.fake.wait { Set(harness.requestIDs("remove")) == ["s-mine", "s-ended"] })
    #expect(harness.requestIDs("kill") == ["s-mine"])

    // A project with no background session is removed without asking.
    let quiet = try #require(settings.addProject(path: other.path))
    harness.fake.sessions.removeAll { $0.id == "s-other" }
    _ = try await harness.control.list()
    ProjectRemoval.remove(quiet, settings: settings, background: model, present: present)
    #expect(asked.value.count == 3)
    #expect(!settings.projects.contains { $0.root == quiet.root })
}

@Test func aBackgroundSessionWhoseHolderDiedSaysTheHostCrashed() {
    let info = HostedSessionInfo(
        id: "s", name: "zsh", cwd: "/", state: .exited, exitCode: 1, owner: "CherryTests",
        endedBy: HostSessionEnd.holderLost, holderLog: "/tmp/host.log"
    )
    let session = BackgroundSessionPresentation.session(info, hostID: "host-a")
    #expect(session.hostCrashed)
    #expect(BackgroundSessionPresentation.statusText(of: session) == "host crashed")
    #expect(info.statusText == "Host crashed")
    #expect(info.end?.message == "The session host crashed (see /tmp/host.log)")
}

@Test @MainActor func aRemovedProjectsSessionsLeaveOutThoseOfAProjectNestedInIt() {
    func item(_ id: String, _ project: String?) -> BackgroundSession {
        BackgroundSessionPresentation.session(
            ownSession(id, project: project), hostID: "host-a"
        )
    }
    let sessions = [
        item("outer", "/work/app"),
        item("outer-sub", "/work/app/docs"),
        item("nested", "/work/app/packages/lib"),
        item("nested-sub", "/work/app/packages/lib/src"),
        item("worktree", "/worktrees/app-feature"),
        item("sibling", "/work/application"),
        item("none", nil)
    ]
    let roots = ["/work/app", "/work/app/packages/lib"]
    let worktrees = ["/worktrees/app-feature": "/work/app"]
    let outer = ProjectRemoval.backgroundSessions(
        ofProject: "/work/app", in: sessions, projectRoots: roots, repositoryRoot: { worktrees[$0] ?? $0 }
    )
    #expect(outer.map(\.id) == ["outer", "outer-sub", "worktree"])
    let nested = ProjectRemoval.backgroundSessions(
        ofProject: "/work/app/packages/lib", in: sessions, projectRoots: roots, repositoryRoot: { worktrees[$0] ?? $0 }
    )
    #expect(nested.map(\.id) == ["nested", "nested-sub"])
}


@Test @MainActor func backgroundNotificationsAreRateLimitedPerSessionAndOverall() async throws {
    let harness = try PersistentHarness()
    let clock = Recorder(Date())
    let posted = Recorder<[BackgroundSessionNotificationContent]>([])
    let model = makeModel(harness, postNotification: { posted.value.append($0) }, now: { clock.value })
    defer {
        model.stop()
        harness.cleanUp()
    }
    let project = harness.project.path
    harness.fake.sessions = (0..<10).map { ownSession("s-\($0)", project: project, name: "Agent \($0)", kind: "agent", agent: "Claude") }
    _ = try await harness.control.list()
    model.refresh()
    func notify(_ id: String) throws {
        _ = model.backgroundSessionDidSignal(
            try #require(harness.hosting.sessionInfo(id)), .notification(title: "", body: "tick")
        )
    }
    // One session sending OSC 9 in a loop: one notification per interval.
    for _ in 0..<5 { try notify("s-0") }
    #expect(posted.value.count == 1)
    clock.value = clock.value.addingTimeInterval(BackgroundSessionsModel.notificationInterval + 1)
    try notify("s-0")
    #expect(posted.value.count == 2)
    // Many sessions at once: at most `notificationLimit` a minute.
    for index in 1..<10 { try notify("s-\(index)") }
    #expect(posted.value.count == BackgroundSessionsModel.notificationLimit)
    #expect(model.unreadSessionIDs.count == 10)
    clock.value = clock.value.addingTimeInterval(61)
    try notify("s-9")
    #expect(posted.value.count == BackgroundSessionsModel.notificationLimit + 1)
}

@Test @MainActor func unreadMarksOfAnEarlierRunComeBackInTheList() async throws {
    let harness = try PersistentHarness()
    let directory = try temporaryDirectory("cherry-background-unread-launch")
    let store = WorkspaceStateStore(directory: directory)
    harness.hosting.endedSessionsStore = store
    let model = makeModel(harness)
    defer {
        model.stop()
        harness.cleanUp()
        try? FileManager.default.removeItem(at: directory)
    }
    let project = harness.project.path
    store.addUnreadSession(hostID: "host-a", sessionID: "s-rang")
    store.addUnreadSession(hostID: "host-a", sessionID: "s-gone")
    store.addUnreadSession(hostID: "host-b", sessionID: "s-quiet")
    harness.fake.sessions = [
        ownSession("s-rang", project: project, name: "Rang"),
        ownSession("s-quiet", project: project, name: "Quiet")
    ]
    _ = try await harness.control.list()
    model.refresh()
    #expect(model.unreadSessionIDs == ["s-rang"])
}
