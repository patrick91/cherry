import Combine
import Darwin
import Foundation
import Testing
@testable import Cherry

// The safety rules of hosted-by-default tabs (docs/specs/multiplexer-default.md):
// one copy of the app owns this Mac's sessions and saved tabs, a state file
// this version cannot use is never written over, the sessions of saved tabs
// a worktree removal forgets are ended, sessions no saved tab names are
// adopted, a closed window's restore leaves no stale owners, and ending a
// session survives a host that does not answer. Against the fake `cherry
// control` (FakeControlHelper); nothing reaches a real cherry-host or the
// app's real Application Support.

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// A value the fake's thread reads while the test sets it.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
    }
}

private func record(
    id: UUID = UUID(),
    kind: TerminalSession.SessionKind = .terminal,
    title: String,
    sessionID: String?,
    owned: Bool? = true,
    launchRequestID: String? = nil,
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
        hosted: sessionID.map { HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: $0, owned: owned) },
        launchRequestID: launchRequestID
    )
}

private func session(
    _ id: String,
    tab: UUID,
    project: String,
    owner: String = "CherryTests",
    kind: String = "terminal",
    command: String? = nil,
    createdAt: Date,
    requestID: String? = nil
) -> HostedSessionInfo {
    var tags = [
        PersistentSessionTag.tab: tab.uuidString,
        PersistentSessionTag.kind: kind,
        PersistentSessionTag.project: project
    ]
    if let command { tags[PersistentSessionTag.command] = command }
    return HostedSessionInfo(
        id: id, name: "Orphan \(id)", cwd: project, pid: 300, owner: owner, tags: tags,
        createdAt: UInt64(createdAt.timeIntervalSince1970 * 1_000), requestID: requestID
    )
}

@MainActor
private func restore(
    _ harness: PersistentHarness,
    _ records: [WorkspaceSessionRecord],
    unbound: [WorkspaceSessionRecord] = [],
    into workspace: TerminalWorkspace
) async -> WorkspaceRestoreResult {
    await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path,
        worktreeRoot: harness.project.path,
        records: records,
        workspace: workspace,
        unboundRecords: unbound
    ))
}

// MARK: - One copy of the app

@Test func anInstanceLockIsHeldByOneCopyAtATimeAndExplainsWhoHasIt() throws {
    let directory = try temporaryDirectory("cherry-instance-lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Test App", isDirectory: true).appendingPathComponent("instance.lock")
    let first = AppInstanceLock(fileURL: url, applicationSupportName: "Test App")
    #expect(first.state == .held)
    #expect(first.isHeld)
    #expect(first.unavailableReason == nil)
    // The file says who holds it.
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(contents.hasPrefix("\(getpid())\n"))

    // A second copy (another open file description, as another process
    // would have) cannot take it, and says why.
    let second = AppInstanceLock(fileURL: url, applicationSupportName: "Test App")
    #expect(second.state == .heldElsewhere(pid: getpid()))
    #expect(!second.isHeld)
    let reason = try #require(second.unavailableReason)
    #expect(reason.contains("Another copy of Test App (process \(getpid()))"))
    #expect(reason.contains("Application Support/Test App"))
    // The answer stays the same for the rest of its run.
    first.release()
    #expect(!second.isHeld)
    // A copy started once the first one is gone takes it.
    let third = AppInstanceLock(fileURL: url, applicationSupportName: "Test App")
    #expect(third.isHeld, "\(third.state)")
    third.release()

    // A lock file that cannot be made: never assumed held.
    let blocked = directory.appendingPathComponent("file")
    try Data().write(to: blocked)
    let unusable = AppInstanceLock(fileURL: blocked.appendingPathComponent("instance.lock"), applicationSupportName: "X")
    guard case .unavailable = unusable.state else {
        Issue.record("expected unavailable, got \(unusable.state)")
        return
    }
    #expect(unusable.unavailableReason != nil)
}

@Test @MainActor func aSecondCopyWithTheSameIdentityLeavesSessionsAndSavedTabsAlone() async throws {
    let directory = try temporaryDirectory("cherry-second-copy")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appendingPathComponent("instance.lock")
    let owner = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
    #expect(owner.isHeld)
    defer { owner.release() }
    let other = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")

    // Its state store neither loads nor saves: the other copy's file stays.
    let storeDirectory = directory.appendingPathComponent("Workspaces", isDirectory: true)
    let saved = RepositoryStateRecord(
        repositoryRoot: "/repo", activeWorktreeRoot: "/repo",
        worktrees: [WorktreeStateRecord(root: "/repo", sessions: [record(title: "Editor", sessionID: "s-1", root: "/repo")])]
    )
    WorkspaceStateStore(directory: storeDirectory, instanceLock: owner).saveSynchronously(saved)
    WorkspaceStateStore(directory: storeDirectory, instanceLock: owner).saveOpenProjectWindowRoots(["/repo"], synchronously: true)
    let second = WorkspaceStateStore(directory: storeDirectory, instanceLock: other)
    #expect(!second.isEnabled)
    #expect(second.load(repositoryRoot: "/repo") == nil)
    #expect(second.loadOpenProjectWindowRoots().isEmpty)
    second.saveSynchronously(RepositoryStateRecord(repositoryRoot: "/repo", activeWorktreeRoot: "/repo", worktrees: []))
    second.saveOpenProjectWindowRoots([], synchronously: true)
    let untouched = WorkspaceStateStore(directory: storeDirectory)
    #expect(untouched.load(repositoryRoot: "/repo") == saved)
    #expect(untouched.loadOpenProjectWindowRoots() == ["/repo"])

    // Its local sessions: new tabs run natively and Settings › Sessions says
    // why; nothing is created, adopted, restored or ended.
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let status = PersistentSessionsStatus()
    let control = harness.control
    let hosting = PersistentLocalSessions(
        owner: "CherryTests",
        control: { control },
        installationUnavailableReason: { nil },
        status: status,
        instanceLock: other,
        configuration: PersistentHarness.fastConfiguration
    )
    #expect(!hosting.canHostNewTabs())
    #expect(status.localSessionsUnavailableReason?.contains("Another copy of CherryTests") == true)
    #expect(hosting.installationProblem() != nil)
    let running = HostedSessionInfo(id: "s-1", name: "Editor", cwd: "/repo", pid: 7, owner: "CherryTests")
    #expect(!hosting.canAdopt(running))
    await #expect(throws: HostedSessionError.self) {
        _ = try await hosting.create(
            PersistentSessionRequest(tabID: UUID(), name: "x", kind: .terminal, columns: 80, rows: 24),
            configuration: ShellProcessController.Configuration(
                shellPath: "/bin/zsh", workingDirectory: "/tmp", term: "xterm-ghostty",
                initialSize: TerminalViewportSize(columns: 80, rows: 24)
            )
        )
    }
    harness.fake.sessions = [running]
    let workspace = TerminalWorkspace(
        projectRoot: "/repo", createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .defaults }, localSessions: hosting)
    )
    let result = await WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting)(WorkspaceRestoreRequest(
        repositoryRoot: "/repo", worktreeRoot: "/repo",
        records: saved.worktrees[0].sessions, workspace: workspace
    ))
    #expect(result.sessions.isEmpty)
    #expect(result.keptRecordIDs == Set(saved.worktrees[0].sessions.map(\.id)))
    await hosting.end(HostedSessionAttachment(
        host: .local, hostID: "host-a", sessionID: "s-1", name: "Editor", remoteWorkingDirectory: "/repo",
        executablePath: "/nonexistent"
    )).value
    hosting.endSessions(ofForgottenTabs: saved.worktrees[0].sessions)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("list").isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.creates().isEmpty)
}

// MARK: - State files of another version

@Test func aStateFileThisVersionCannotUseIsMovedAsideNotWrittenOver() throws {
    let directory = try temporaryDirectory("cherry-state-aside")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let fileURL = store.stateFileURL(repositoryRoot: "/repo")
    let future = Data(#"{"version": 2, "repositoryRoot": "/repo", "worktrees": [{"root": "/repo", "sessions": [{"kind": "notebook"}]}]}"#.utf8)
    try future.write(to: fileURL)

    // Another version: nothing restored, and the file is kept beside.
    #expect(store.load(repositoryRoot: "/repo") == nil)
    func setAside() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".bak") }.sorted()
    }
    let moved = try setAside()
    #expect(moved.count == 1)
    #expect(moved.first?.hasPrefix(fileURL.lastPathComponent + ".v2-") == true)
    #expect(try Data(contentsOf: directory.appendingPathComponent(try #require(moved.first))) == future)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))

    // The next save writes a new file; the moved one is left alone.
    let state = RepositoryStateRecord(
        repositoryRoot: "/repo", activeWorktreeRoot: "/repo",
        worktrees: [WorktreeStateRecord(root: "/repo", sessions: [record(title: "Shell", sessionID: "s-1", root: "/repo")])]
    )
    store.saveSynchronously(state)
    #expect(store.load(repositoryRoot: "/repo") == state)
    #expect(try Data(contentsOf: directory.appendingPathComponent(try #require(moved.first))) == future)

    // A file that does not decode at all, and a version-1 file this build
    // cannot read (a newer build's kind of tab): the same.
    try Data("{not json".utf8).write(to: fileURL)
    #expect(store.load(repositoryRoot: "/repo") == nil)
    #expect(try setAside().contains { $0.hasPrefix(fileURL.lastPathComponent + ".unreadable-") })
    try Data(#"{"version": 1, "repositoryRoot": "/repo", "worktrees": [{"root": "/repo", "sessions": [{"kind": "notebook"}]}]}"#.utf8)
        .write(to: fileURL)
    #expect(store.load(repositoryRoot: "/repo") == nil)
    #expect(try setAside().filter { $0.hasPrefix(fileURL.lastPathComponent + ".v1-") }.count == 1)
    #expect(try setAside().count == 3)

    // The list of open windows too.
    let windows = store.openProjectWindowsFileURL
    try Data(#"{"version": 9, "projectRoots": ["/repo"]}"#.utf8).write(to: windows)
    #expect(store.loadOpenProjectWindowRoots().isEmpty)
    #expect(try setAside().contains { $0.hasPrefix("open-windows.json.v9-") })
    store.saveOpenProjectWindowRoots(["/repo"], synchronously: true)
    #expect(store.loadOpenProjectWindowRoots() == ["/repo"])
    // A missing file is simply nothing saved.
    #expect(store.load(repositoryRoot: "/other") == nil)
    #expect(try setAside().count == 4)
}

// MARK: - Restores

@Test @MainActor func tabsSavedWhileTheirCreateWasUnderWayAreKeptWhileTheHostIsUnreachable() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let creating = record(title: "Fresh", sessionID: nil, launchRequestID: UUID().uuidString.lowercased(), root: harness.project.path)
    let native = record(title: "Native", sessionID: nil, root: harness.project.path)

    // The host cannot be reached: the record of a Create under way stays,
    // and comes back once the host is up; a native tab's does not.
    harness.fake.launchFailure = "cherry-host is restarting"
    let result = await restore(harness, [], unbound: [creating, native], into: workspace)
    #expect(result.sessions.isEmpty)
    #expect(result.keptRecordIDs == [creating.id])
    #expect(result.retryWhenAvailable != nil)

    // This copy cannot run sessions at all: kept too.
    harness.fake.launchFailure = nil
    harness.installationProblem.value = "Cherry is running from a disk image."
    let disabled = await restore(harness, [], unbound: [creating, native], into: workspace)
    #expect(disabled.keptRecordIDs == [creating.id])
}

@Test @MainActor func aClosedWindowsRestoreLeavesNoTabOwningTheSessionsItWasBringingBack() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let root = harness.project.path
    let editor = record(title: "Editor", sessionID: "s-editor", root: root)
    let server = record(title: "Server", sessionID: "s-server", root: root)
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-editor", name: "Editor", cwd: root, pid: 81, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: editor.id.uuidString]),
        HostedSessionInfo(id: "s-server", name: "Server", cwd: root, pid: 82, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: server.id.uuidString])
    ]
    harness.fake.pendingHolders = 0

    // The window closes while the host has not answered its list.
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "list" && !held.isHeld ? held.hold(request, on: connection) : nil
    }
    let closing = harness.workspace()
    var request = WorkspaceRestoreRequest(repositoryRoot: root, worktreeRoot: root, records: [editor, server], workspace: closing)
    let cancellation = WorkspaceRestoreCancellation()
    request.cancellation = cancellation
    let restorer = harness.restorer
    let restoring = Task { await restorer(request) }
    #expect(await harness.fake.wait { held.isHeld })
    closing.closeAllSessions(intent: .windowClosed)
    cancellation.cancel()
    harness.fake.respond = nil
    held.answer(.sessions(HostedSessionList(hostID: "host-a", sessions: harness.fake.sessions, pendingHolders: 0)))
    let stale = await restoring.value
    #expect(stale.sessions.isEmpty)
    #expect(stale.keptRecordIDs == [editor.id, server.id])
    #expect(harness.hosting.owningTab(of: "s-editor") == nil)

    // Tabs built before the close, not handed back yet (a slow SSH host
    // holds up the result), are ended with the close's intent: no stale
    // owner is left for the reopened window to trip over.
    let ssh = FakeControlHelper()
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let sshControl = HostControl(
        host: try .ssh("devbox"),
        clientProvider: { HostedSessionClient(executableURL: URL(fileURLWithPath: "/fake/bin/cherry"), loginEnvironment: { _ in .init(environment: [:]) }) },
        hostStore: store, masters: disabledSSHMasters, launcher: ssh.launcher, localHostUnavailableReason: nil,
        configuration: .fastTests
    )
    defer { sshControl.disconnect() }
    let sshHeld = FakeHeldRequest()
    ssh.respond = { request, connection in request.op == "list" ? sshHeld.hold(request, on: connection) : nil }
    let remote = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Remote", workingDirectory: NSHomeDirectory(),
        hosted: HostedSessionBindingRecord(host: "ssh:devbox", hostID: "host-a", sessionID: "r-1", owned: false)
    )
    let closingAgain = harness.workspace()
    var slowRequest = WorkspaceRestoreRequest(repositoryRoot: root, worktreeRoot: root, records: [editor, remote], workspace: closingAgain)
    let slowCancellation = WorkspaceRestoreCancellation()
    slowRequest.cancellation = slowCancellation
    let slowRestorer = WorkspaceSessionRestorers.hostedByDefault(
        localSessions: harness.hosting, control: { _ in sshControl }, initialWait: .seconds(30)
    )
    let slow = Task { await slowRestorer(slowRequest) }
    #expect(await harness.fake.wait { harness.hosting.owningTab(of: "s-editor") != nil && sshHeld.isHeld })
    closingAgain.closeAllSessions(intent: .windowClosed)
    slowCancellation.cancel()
    #expect(harness.hosting.owningTab(of: "s-editor") == nil)
    sshHeld.answer(.sessions(HostedSessionList(hostID: "host-a", sessions: [])))
    let slowResult = await slow.value
    #expect(slowResult.sessions.isEmpty)
    #expect(slowResult.keptRecordIDs.contains(editor.id))
    // A window close keeps sessions: nothing was ended.
    #expect(harness.fake.requests("kill").isEmpty)

    // The reopened window's restore owns them again.
    let reopened = harness.workspace()
    defer { reopened.closeAllSessions(intent: .windowClosed) }
    let again = await restore(harness, [editor, server], into: reopened)
    #expect(Set(again.sessions.map(\.id)) == [editor.id, server.id])
    #expect(again.sessions.allSatisfy { $0.isPersistentLocalSession })
    reopened.restoreSessions(again.sessions, from: WorktreeStateRecord(root: root, sessions: [editor, server]))
}

// MARK: - Ending sessions

@Test @MainActor func endingASessionSendsTheKillAgainWhenItsAnswerIsLost() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // The workspace keeps a tab of its own.
    let anchor = workspace.addSession()
    #expect(await harness.waitUntilAttached(anchor))
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)

    // The first Kill is lost with the connection (the daemon restarts);
    // the next one reaches it, and the ended session is removed.
    let lost = FakeCountdown(1)
    harness.fake.respond = { request, _ in
        request.op == "kill" && lost.take() ? .exit(stderr: "cherry: connection lost") : nil
    }
    workspace.close(tab)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(sessionID) })
    #expect(harness.requestIDs("kill") == [sessionID, sessionID])
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(2)))

    // The host says the session is gone: nothing more is sent.
    let gone = workspace.addSession()
    #expect(await harness.waitUntilAttached(gone))
    let goneID = try #require(gone.persistentSession?.sessionID)
    harness.fake.respond = { request, _ in
        request.op == "kill" ? .answer(.error(code: "unknown_session", message: "no session \(goneID)")) : nil
    }
    workspace.close(gone)
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(2)))
    #expect(harness.requestIDs("kill").filter { $0 == goneID }.count == 1)
    #expect(!harness.requestIDs("remove").contains(goneID))
}

// MARK: - Worktrees

@MainActor
private final class WorktreeFixture {
    let harness: PersistentHarness
    let container: URL
    let root: URL
    let feature: URL
    let other: URL
    let store: WorkspaceStateStore
    private let previousWorktreeSpaces: Bool

    init() throws {
        harness = try PersistentHarness()
        container = try temporaryDirectory("cherry-forgotten")
        root = container.appendingPathComponent("repo", isDirectory: true)
        feature = container.appendingPathComponent("feature", isDirectory: true)
        other = container.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["-C", root.path, "init", "-b", "main"])
        try git(["-C", root.path, "-c", "user.name=Cherry Tests", "-c", "user.email=cherry@example.invalid",
                 "commit", "--allow-empty", "-m", "Initial"])
        try git(["-C", root.path, "worktree", "add", "-b", "feature", feature.path])
        try git(["-C", root.path, "worktree", "add", "-b", "other", other.path])
        store = WorkspaceStateStore(directory: container.appendingPathComponent("store", isDirectory: true))
        previousWorktreeSpaces = TerminalSettings.shared.worktreeSpacesEnabled
        TerminalSettings.shared.worktreeSpacesEnabled = true
    }

    var repositoryKey: String {
        URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
    }

    func cleanUp() {
        TerminalSettings.shared.worktreeSpacesEnabled = previousWorktreeSpaces
        harness.cleanUp()
        try? FileManager.default.removeItem(at: container)
    }
}

@Test @MainActor func removingAWorktreeEndsTheSessionsOfItsSavedTabsThatAreNotTabs() async throws {
    let fixture = try WorktreeFixture()
    let harness = fixture.harness
    defer { fixture.cleanUp() }
    let launch = UUID().uuidString.lowercased()
    let kept = record(title: "Web", sessionID: "s-web", root: fixture.feature.path)
    let creating = record(title: "Fresh", sessionID: nil, launchRequestID: launch, root: fixture.feature.path)
    let viewer = record(title: "Viewer", sessionID: "s-viewer", owned: false, root: fixture.feature.path)
    let vanishing = record(title: "Other", sessionID: "s-other", root: fixture.other.path)
    let main = record(title: "Main", sessionID: nil, root: fixture.root.path)
    fixture.store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: fixture.repositoryKey,
        activeWorktreeRoot: fixture.root.path,
        worktrees: [
            WorktreeStateRecord(root: fixture.root.path, sessions: [main]),
            WorktreeStateRecord(root: fixture.feature.path, sessions: [kept, creating, viewer]),
            WorktreeStateRecord(root: fixture.other.path, sessions: [vanishing])
        ]
    ))
    // The local host is down while the window opens: every saved tab is
    // kept for when it comes back.
    harness.fake.launchFailure = "cherry-host is restarting"
    let repository = RepositoryWorkspace(
        projectRoot: fixture.root.path,
        backendPolicy: harness.policy,
        stateStore: fixture.store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.refresh()
    await repository.waitForPendingRestores()
    let featureWorktree = try #require(repository.worktrees.first { $0.root == fixture.feature.path })
    #expect(repository.workspaceIfLoaded(for: fixture.feature.path)?.sessions.isEmpty == true)

    // Its kept tabs that own sessions of This Mac count as running, so the
    // removal asks first (the viewer only watched another's session).
    #expect(await repository.removalBlockers(for: featureWorktree).runningProcessCount == 2)
    await #expect(throws: GitWorktreeCommandError.self) {
        try await repository.remove(featureWorktree, chromeState: nil)
    }
    try await repository.remove(featureWorktree, force: true, chromeState: nil)

    // The other worktree disappears outside Cherry: its saved tab goes the
    // same way at the next discovery.
    try git(["-C", fixture.root.path, "worktree", "remove", "--force", fixture.other.path])
    await repository.refresh()

    // They are recorded, so a run that quits before it can end them leaves
    // them to the next launch.
    fixture.store.flush()
    #expect(Set(fixture.store.loadSessionsToEnd().map(\.id)) == [kept.id, creating.id, vanishing.id])

    // Once the host is back, their sessions are ended: the bound one, the
    // one its saved Create started, and the other worktree's; never the
    // session the viewer watched (this app's, tagged with the viewer's own
    // id: only its record says it did not own it), nor anything their tabs
    // did not own.
    harness.fake.launchFailure = nil
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-web", name: "Web", cwd: fixture.feature.path, pid: 11, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: kept.id.uuidString]),
        HostedSessionInfo(id: "s-launched", name: "Fresh", cwd: fixture.feature.path, pid: 12, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: creating.id.uuidString], requestID: launch),
        HostedSessionInfo(id: "s-viewer", name: "Viewer", cwd: fixture.feature.path, pid: 13, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: viewer.id.uuidString]),
        HostedSessionInfo(id: "s-other", name: "Other", cwd: fixture.other.path, pid: 14, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: vanishing.id.uuidString]),
        HostedSessionInfo(id: "s-unrelated", name: "Unrelated", cwd: "/tmp", pid: 15, owner: "CherryTests")
    ]
    _ = try await harness.control.connect()
    #expect(await harness.fake.wait(timeout: 10) {
        Set(harness.requestIDs("remove")).isSuperset(of: ["s-web", "s-launched", "s-other"])
    })
    #expect(Set(harness.requestIDs("kill")) == ["s-web", "s-launched", "s-other"])
    // None of them is left: nothing is recorded any more.
    #expect(await harness.fake.wait {
        fixture.store.flush()
        return fixture.store.loadSessionsToEnd().isEmpty
    })
    #expect(!FileManager.default.fileExists(atPath: fixture.store.sessionsToEndFileURL.path))
    #expect(!harness.requestIDs("kill").contains("s-viewer"))
    // Nothing of them is saved any more, and nothing restores them.
    repository.flushPersistentState()
    let saved = try #require(fixture.store.load(repositoryRoot: fixture.repositoryKey))
    #expect(saved.worktree(root: fixture.feature.path) == nil)
    #expect(saved.worktree(root: fixture.other.path) == nil)
    #expect(repository.workspaceIfLoaded(for: fixture.feature.path) == nil)
}

// MARK: - Sessions no saved tab names

@Test @MainActor func sessionsOfThisAppThatNoSavedTabNamesComeBackAsTabsOfTheirWorktree() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-orphans")
    let storeDirectory = try temporaryDirectory("cherry-orphans-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let editor = record(title: "Editor", sessionID: "s-editor", root: root.path)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [editor], selectedSessionID: editor.id)],
        savedAt: savedAt
    ))
    let orphan = UUID()
    let orphanCommand = UUID()
    let closedOnPurpose = UUID()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-editor", name: "Editor", cwd: root.path, pid: 10, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: editor.id.uuidString]),
        // Opened after the last save, and the app crashed before the next.
        session("s-orphan", tab: orphan, project: root.path, createdAt: savedAt.addingTimeInterval(0.4)),
        session("s-orphan-server", tab: orphanCommand, project: root.path, kind: "command", command: "server",
                createdAt: savedAt.addingTimeInterval(30)),
        // Created before the last save, which did not name it: its tab was
        // closed on purpose ("Keep running after closing a tab").
        session("s-closed", tab: closedOnPurpose, project: root.path, createdAt: savedAt.addingTimeInterval(-60)),
        // Another project's, another app's, and one whose creation time is
        // unknown.
        session("s-elsewhere", tab: UUID(), project: "/somewhere/else", createdAt: savedAt.addingTimeInterval(10)),
        session("s-other-app", tab: UUID(), project: root.path, owner: "Cherry Sessions", createdAt: savedAt.addingTimeInterval(10)),
        HostedSessionInfo(id: "s-unknown", name: "x", cwd: root.path, pid: 9, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: UUID().uuidString, PersistentSessionTag.project: root.path])
    ]
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { workspace.sessions.count == 3 })
    await repository.waitForPendingRestores()
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [editor.id, orphan, orphanCommand])
    #expect(workspace.selectedSessionID == editor.id)
    let adopted = try #require(workspace.session(withID: orphan))
    #expect(adopted.isPersistentLocalSession)
    #expect(adopted.persistentSession?.sessionID == "s-orphan")
    #expect(adopted.title == "Orphan s-orphan")
    let server = try #require(workspace.session(withID: orphanCommand))
    #expect(server.kind == .command)
    #expect(server.commandName == "server")
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
    // Saved from now on like any tab.
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.map(\.id) == [editor.id, orphan, orphanCommand])
    #expect(saved.sessions.first { $0.id == orphan }?.hosted?.sessionID == "s-orphan")

    // A project with no saved state at all adopts its sessions whenever
    // they were created (before this run).
    let fresh = try temporaryDirectory("cherry-orphans-fresh")
    defer { try? FileManager.default.removeItem(at: fresh) }
    let lost = UUID()
    harness.fake.sessions.append(session("s-lost", tab: lost, project: fresh.path, createdAt: Date(timeIntervalSince1970: 1_000)))
    let freshRepository = RepositoryWorkspace(
        projectRoot: fresh.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { freshRepository.closeAllSessions(intent: .windowClosed) }
    freshRepository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    let freshWorkspace = freshRepository.activeWorkspace
    #expect(await harness.fake.wait { freshWorkspace.session(withID: lost) != nil })
    // After its default shell, which it opened at once.
    #expect(freshWorkspace.sessions.map(\.id).last == lost)
    #expect(freshWorkspace.sessions.first?.title == "Shell 1")
}

@Test @MainActor func aNewPersistentTabIsSavedAtOnce() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-save-at-once")
    let storeDirectory = try temporaryDirectory("cherry-save-at-once-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    // The new tab's Create is held (the window's default shell is answered):
    // the tab is saved, with the request it sent, before any answer.
    let held = FakeHeldRequest()
    let heldTab = LockedValue<String?>(nil)
    harness.fake.respond = { request, connection in
        guard request.op == "create",
              let tab = (request.json["tags"] as? [String: String])?[PersistentSessionTag.tab],
              tab == heldTab.value
        else { return nil }
        return held.hold(request, on: connection)
    }
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    let shell = try #require(repository.activeWorkspace.sessions.first)
    #expect(await harness.waitUntilAttached(shell))
    // Its Create goes out on a later turn: named before then.
    let tab = repository.activeWorkspace.addSession(title: "Fresh")
    heldTab.value = tab.id.uuidString
    #expect(tab.isPersistentLocalSession)
    #expect(await harness.fake.wait { held.isHeld })
    // Well within the usual save delay (500 ms), and while its Create has
    // not answered.
    try await Task.sleep(for: .milliseconds(100))
    store.flush()
    #expect(held.isHeld)
    #expect(tab.persistentSession == nil)
    let saved = store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: repository.activeWorktreeRoot)?.sessions
    let fresh = try #require(saved?.first { $0.id == tab.id })
    #expect(fresh.launchRequestID == tab.persistentLaunchRequestID)
    #expect(fresh.launchRequestID != nil)
    let create = try #require(harness.creates().first {
        ($0.json["tags"] as? [String: String])?[PersistentSessionTag.tab] == tab.id.uuidString
    })
    #expect(fresh.launchRequestID == create.string("request_id")?.lowercased())
}

// MARK: - Review follow-ups

@Test func aCopyLaunchedWhileTheHolderQuitsWaitsForItAndNoFlockDoesNotTurnPersistenceOff() throws {
    let directory = try temporaryDirectory("cherry-instance-quit")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    let first = AppInstanceLock(fileURL: url, applicationSupportName: "Test App")
    #expect(first.isHeld)

    // A holder that is not quitting: another copy gives up at once.
    var started = Date()
    let busy = AppInstanceLock(fileURL: url, applicationSupportName: "Test App", quittingHolderWait: 5)
    #expect(busy.state == .heldElsewhere(pid: getpid()))
    #expect(Date().timeIntervalSince(started) < 1)

    // One that is quitting (its quit waits for sessions to end): the next
    // copy waits for it to let go, and holds the lock afterwards.
    first.markQuitting()
    #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("\n\(AppInstanceLock.quittingMarker)\n"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { first.release() }
    let next = AppInstanceLock(fileURL: url, applicationSupportName: "Test App", quittingHolderWait: 5)
    #expect(next.isHeld, "\(next.state)")
    #expect(try !String(contentsOf: url, encoding: .utf8).contains(AppInstanceLock.quittingMarker))

    // A quit that takes longer than the wait: given up then.
    next.markQuitting()
    started = Date()
    let impatient = AppInstanceLock(fileURL: url, applicationSupportName: "Test App", quittingHolderWait: 0.3)
    #expect(impatient.state == .heldElsewhere(pid: getpid()))
    #expect(Date().timeIntervalSince(started) >= 0.25)
    next.release()

    // A file system without flock: the lock is not enforced, and this copy
    // goes on with persistent sessions and saved tabs.
    let unsupported = AppInstanceLock(
        fileURL: directory.appendingPathComponent("nfs/instance.lock"), applicationSupportName: "Test App",
        lockCall: { _, _ in errno = ENOTSUP; return -1 }
    )
    guard case .unenforced(let warning) = unsupported.state else {
        Issue.record("expected unenforced, got \(unsupported.state)")
        return
    }
    #expect(warning.contains("could not be locked"))
    #expect(unsupported.isHeld)
    #expect(unsupported.unavailableReason == nil)
    #expect(WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces"), instanceLock: unsupported).isEnabled)
    #expect(AppInstanceLock.meansLockUnsupported(ENOLCK))
    // Any other failure still turns them off.
    let failing = AppInstanceLock(
        fileURL: directory.appendingPathComponent("io/instance.lock"), applicationSupportName: "Test App",
        lockCall: { _, _ in errno = EIO; return -1 }
    )
    guard case .unavailable = failing.state else {
        Issue.record("expected unavailable, got \(failing.state)")
        return
    }
    #expect(!failing.isHeld)
}

@Test @MainActor func quittingMarksTheInstanceLockForACopyLaunchedMeanwhile() throws {
    let directory = try temporaryDirectory("cherry-instance-quit-mark")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = AppInstanceLock(fileURL: directory.appendingPathComponent("instance.lock"), applicationSupportName: "CherryTests")
    #expect(lock.isHeld)
    defer { lock.release() }
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces"), instanceLock: lock)
    let repository = RepositoryWorkspace(projectRoot: directory.path, stateStore: store, autoStartCommands: { _ in [] })
    repository.closeAllSessions(intent: .windowClosed)
    #expect(try !String(contentsOf: lock.fileURL, encoding: .utf8).contains(AppInstanceLock.quittingMarker))
    let quitting = RepositoryWorkspace(projectRoot: directory.path, stateStore: store, autoStartCommands: { _ in [] })
    quitting.closeAllSessions(intent: .appQuit)
    #expect(try String(contentsOf: lock.fileURL, encoding: .utf8).contains(AppInstanceLock.quittingMarker))
}

@Test @MainActor func theSessionsOfForgottenTabsThisRunCouldNotEndAreEndedAtTheNextLaunch() async throws {
    let storeDirectory = try temporaryDirectory("cherry-sessions-to-end")
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    let store = WorkspaceStateStore(directory: storeDirectory)
    var configuration = PersistentHarness.fastConfiguration
    configuration.forgottenTabsWindow = .milliseconds(600)
    let first = try PersistentHarness(configuration: configuration)
    defer { first.cleanUp() }
    let root = first.project.path
    let launch = UUID().uuidString.lowercased()
    var web = record(title: "Web", sessionID: "s-web", root: root)
    web.launchEnvironment = ["TOKEN": "secret"]
    let creating = record(title: "Fresh", sessionID: nil, launchRequestID: launch, root: root)
    let viewer = record(title: "Viewer", sessionID: "s-viewer", owned: false, root: root)
    let native = record(title: "Native", sessionID: nil, root: root)

    // The host cannot be reached for the rest of this run (it quits first).
    first.fake.launchFailure = "cherry-host is restarting"
    first.hosting.endSessions(ofForgottenTabs: [web, creating, viewer, native], recordedIn: store)
    store.flush()
    // Recorded: only the tabs that may own a session, without their launch
    // settings.
    let recorded = store.loadSessionsToEnd()
    #expect(Set(recorded.map(\.id)) == [web.id, creating.id])
    #expect(recorded.allSatisfy { $0.launchEnvironment.isEmpty && $0.launchCommand == nil })
    #expect(recorded.first { $0.id == web.id }?.hosted == web.hosted)
    #expect(recorded.first { $0.id == creating.id }?.launchRequestID == launch)
    // Its search gives up after its window; the record stays.
    try await Task.sleep(for: .milliseconds(900))
    store.flush()
    #expect(store.loadSessionsToEnd().count == 2)
    #expect(first.fake.requests("kill").isEmpty)

    // The next launch: the host is up and still runs them. The first window
    // that opens ends them.
    let next = try PersistentHarness()
    defer { next.cleanUp() }
    next.fake.pendingHolders = 0
    next.fake.sessions = [
        HostedSessionInfo(id: "s-web", name: "Web", cwd: root, pid: 21, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: web.id.uuidString]),
        HostedSessionInfo(id: "s-launched", name: "Fresh", cwd: root, pid: 22, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: creating.id.uuidString], requestID: launch),
        HostedSessionInfo(id: "s-viewer", name: "Viewer", cwd: root, pid: 23, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: viewer.id.uuidString]),
        HostedSessionInfo(id: "s-unrelated", name: "Unrelated", cwd: root, pid: 24, owner: "CherryTests")
    ]
    let repository = RepositoryWorkspace(
        projectRoot: next.project.path,
        backendPolicy: next.policy,
        stateStore: store,
        sessionRestorer: next.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await next.fake.wait(timeout: 10) {
        Set(next.requestIDs("remove")).isSuperset(of: ["s-web", "s-launched"])
    })
    #expect(Set(next.requestIDs("kill")) == ["s-web", "s-launched"])
    // Once none of them is left, nothing is recorded any more.
    #expect(await next.fake.wait {
        store.flush()
        return store.loadSessionsToEnd().isEmpty
    })
    #expect(!FileManager.default.fileExists(atPath: store.sessionsToEndFileURL.path))
    // Taken up once per run: another window does not look again.
    let lists = next.fake.requests("list").count
    next.hosting.resumeEndingSessions(recordedIn: store)
    try await Task.sleep(for: .milliseconds(100))
    #expect(next.fake.requests("list").count == lists)
}

@Test @MainActor func aStateFileMovedAsideStillKeepsSessionsClosedOnPurposeFromComingBack() async throws {
    let harness = try PersistentHarness()
    let root = try temporaryDirectory("cherry-orphans-aside")
    let storeDirectory = try temporaryDirectory("cherry-orphans-aside-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let repositoryRoot = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    let otherVersionsTab = UUID()
    let otherVersionsLaunch = UUID().uuidString.lowercased()
    // Written by another version, with a kind of tab this one cannot read.
    let fileURL = store.stateFileURL(repositoryRoot: repositoryRoot)
    try Data("""
    {"version": 2, "repositoryRoot": "\(repositoryRoot)", "savedAt": "2023-11-14T22:13:20Z",
     "worktrees": [{"root": "\(root.path)", "sessions": [
       {"id": "\(otherVersionsTab.uuidString)", "kind": "notebook",
        "hosted": {"host": "local", "hostID": "host-a", "sessionID": "s-kept"}},
       {"id": "\(UUID().uuidString)", "kind": "notebook", "launchRequestID": "\(otherVersionsLaunch.uppercased())"},
       "not a tab"
     ]}]}
    """.utf8).write(to: fileURL)

    let closedOnPurpose = UUID()
    let crashed = UUID()
    let launchedTab = UUID()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        // Its tabs: they come back, whenever they were created.
        session("s-kept", tab: otherVersionsTab, project: root.path, createdAt: savedAt.addingTimeInterval(-3_600)),
        session("s-launched", tab: launchedTab, project: root.path, createdAt: savedAt.addingTimeInterval(-7_200),
                requestID: otherVersionsLaunch),
        // Created before it was saved, and not in it: left running on purpose.
        session("s-closed", tab: closedOnPurpose, project: root.path, createdAt: savedAt.addingTimeInterval(-60)),
        // Created after it was saved: its tab was never saved.
        session("s-crashed", tab: crashed, project: root.path, createdAt: savedAt.addingTimeInterval(5))
    ]
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    // Moved aside, not written over.
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).contains {
        $0.hasPrefix(fileURL.lastPathComponent + ".v2-")
    })
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { Set(workspace.sessions.map(\.id)).isSuperset(of: [otherVersionsTab, launchedTab, crashed]) })
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.session(withID: closedOnPurpose) == nil)
    #expect(harness.hosting.owningTab(of: "s-closed") == nil)
    #expect(harness.fake.requests("kill").isEmpty)

    // Once a file of this version is saved, the moved one no longer counts.
    repository.flushPersistentState()
    #expect(store.setAsideState(repositoryRoot: repositoryRoot) == nil)
}

@Test func whatAStateFileThisVersionCannotUseSaidDecidesWhichSessionsComeBack() throws {
    let directory = try temporaryDirectory("cherry-set-aside-summary")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    // Nothing was ever saved or set aside.
    #expect(store.setAsideState(repositoryRoot: "/repo") == nil)

    // A file that does not decode says only when it was written.
    let fileURL = store.stateFileURL(repositoryRoot: "/repo")
    try Data("{not json".utf8).write(to: fileURL)
    let written = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: fileURL.path)
    #expect(store.load(repositoryRoot: "/repo") == nil)
    let unreadable = try #require(store.setAsideState(repositoryRoot: "/repo"))
    #expect(unreadable.savedAt == written)
    #expect(unreadable.tabIDs.isEmpty)

    let tab = UUID()
    let criteria = OrphanedSessionCriteria(
        owner: "CherryTests", savedState: nil, setAside: unreadable, createdBefore: Date()
    )
    #expect(criteria.orphanTabID(of: session("a", tab: tab, project: "/repo", createdAt: written.addingTimeInterval(-10))) == nil)
    #expect(criteria.orphanTabID(of: session("b", tab: tab, project: "/repo", createdAt: written.addingTimeInterval(10))) == tab)

    // Sessions still to be ended are never adopted, whatever else holds.
    let forgotten = record(id: tab, title: "Gone", sessionID: "c", root: "/repo")
    let ending = OrphanedSessionCriteria(
        owner: "CherryTests", savedState: nil, sessionsToEnd: [forgotten], createdBefore: Date()
    )
    #expect(ending.orphanTabID(of: session("c", tab: UUID(), project: "/repo", createdAt: written)) == nil)
    #expect(ending.orphanTabID(of: session("d", tab: tab, project: "/repo", createdAt: written)) == nil)
    #expect(ending.orphanTabID(of: session("e", tab: UUID(), project: "/repo", createdAt: written)) != nil)

    // Another repository's file (a hash collision) says nothing.
    let other = store.stateFileURL(repositoryRoot: "/elsewhere")
    try Data(#"{"version": 2, "repositoryRoot": "/not-elsewhere", "worktrees": []}"#.utf8).write(to: other)
    #expect(store.load(repositoryRoot: "/elsewhere") == nil)
    #expect(store.setAsideState(repositoryRoot: "/elsewhere") == nil)
}

@Test @MainActor func endingASessionGoesOnWhileTheHostCannotBeReachedAndGivesUpAfterItsWindow() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.endRetryDelay = (.milliseconds(50), .milliseconds(100))
    configuration.endRetryWindow = .seconds(1)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession()
    #expect(await harness.waitUntilAttached(anchor))
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)

    // The helper cannot start (the host is being upgraded): the Kill cannot
    // be sent, and is tried again until it can.
    harness.fake.launchFailure = "cherry-host is being upgraded"
    harness.fake.dropAll()
    workspace.close(tab)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.hosting.isEnding(sessionID))
    #expect(!harness.requestIDs("kill").contains(sessionID))
    harness.fake.launchFailure = nil
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(sessionID) })
    #expect(harness.requestIDs("kill").contains(sessionID))
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(2)))

    // Unreachable past the window: the ending gives up (a quit waiting for
    // it is not held up), having sent nothing.
    let stuck = workspace.addSession()
    #expect(await harness.waitUntilAttached(stuck))
    let stuckID = try #require(stuck.persistentSession?.sessionID)
    harness.fake.launchFailure = "cherry-host is being upgraded"
    harness.fake.dropAll()
    let closedAt = ContinuousClock.now
    workspace.close(stuck)
    #expect(harness.hosting.isEnding(stuckID))
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(4)))
    #expect(ContinuousClock.now - closedAt < .seconds(3))
    #expect(!harness.requestIDs("kill").contains(stuckID))
}

@Test @MainActor func closingAWindowOrRemovingAWorktreeWhileItsRestoreWaitsLeavesNoTabOwningItsSessions() async throws {
    let fixture = try WorktreeFixture()
    let harness = fixture.harness
    defer { fixture.cleanUp() }
    // An SSH host that answers only when the test says: a restore waits for
    // it before it hands back the local tabs it built.
    let ssh = FakeControlHelper()
    let (hostStore, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let sshControl = HostControl(
        host: try .ssh("devbox"),
        clientProvider: { HostedSessionClient(executableURL: URL(fileURLWithPath: "/fake/bin/cherry"), loginEnvironment: { _ in .init(environment: [:]) }) },
        hostStore: hostStore, masters: disabledSSHMasters, launcher: ssh.launcher, localHostUnavailableReason: nil,
        configuration: .fastTests
    )
    defer { sshControl.disconnect() }
    let sshHeld = FakeHeldRequest()
    ssh.respond = { request, connection in request.op == "list" ? sshHeld.hold(request, on: connection) : nil }
    let restorer = WorkspaceSessionRestorers.hostedByDefault(
        localSessions: harness.hosting, control: { _ in sshControl }, initialWait: .seconds(30)
    )
    func remote(_ sessionID: String) -> WorkspaceSessionRecord {
        WorkspaceSessionRecord(
            id: UUID(), kind: .terminal, title: "Remote", workingDirectory: NSHomeDirectory(),
            hosted: HostedSessionBindingRecord(host: "ssh:devbox", hostID: "host-a", sessionID: sessionID, owned: false)
        )
    }
    func makeRepository() -> RepositoryWorkspace {
        RepositoryWorkspace(
            projectRoot: fixture.root.path,
            backendPolicy: harness.policy,
            stateStore: fixture.store,
            sessionRestorer: restorer,
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
    }
    let editor = record(title: "Editor", sessionID: "s-editor", root: fixture.root.path)
    let web = record(title: "Web", sessionID: "s-web", root: fixture.feature.path)
    fixture.store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: fixture.repositoryKey,
        activeWorktreeRoot: fixture.root.path,
        worktrees: [
            WorktreeStateRecord(root: fixture.root.path, sessions: [editor, remote("r-main")]),
            WorktreeStateRecord(root: fixture.feature.path, sessions: [web, remote("r-feature")])
        ]
    ))
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-editor", name: "Editor", cwd: fixture.root.path, pid: 31, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: editor.id.uuidString]),
        HostedSessionInfo(id: "s-web", name: "Web", cwd: fixture.feature.path, pid: 32, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: web.id.uuidString])
    ]

    // The window closes while its restore waits for the SSH host, holding
    // the local tab it built: that tab is ended with the close (which keeps
    // the session) at once, not when the SSH host answers.
    let closing = makeRepository()
    closing.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { harness.hosting.owningTab(of: "s-editor") != nil && sshHeld.isHeld })
    closing.closeAllSessions(intent: .windowClosed)
    #expect(harness.hosting.owningTab(of: "s-editor") == nil)

    // The reopened window's restore owns it again (it too waits for the
    // SSH host, which answers both restores' list at once); the stale
    // restore, answered then, changes nothing.
    ssh.respond = nil
    let reopened = makeRepository()
    defer { reopened.closeAllSessions(intent: .windowClosed) }
    reopened.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { harness.hosting.owningTab(of: "s-editor") != nil })
    sshHeld.answer(.sessions(HostedSessionList(hostID: "host-a", sessions: [])))
    await reopened.waitForPendingRestores()
    let editorTab = try #require(reopened.activeWorkspace.session(withID: editor.id))
    #expect(editorTab.isPersistentLocalSession)
    #expect(harness.hosting.owningTab(of: "s-editor") === editorTab)
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.hosting.owningTab(of: "s-editor") === editorTab)
    #expect(harness.fake.requests("kill").isEmpty)

    // The feature worktree is removed while its restore waits for the SSH
    // host: the tab it built is ended with the removal (its session too)
    // at once.
    ssh.respond = { request, connection in request.op == "list" ? sshHeld.hold(request, on: connection) : nil }
    await reopened.refresh()
    #expect(await harness.fake.wait { harness.hosting.owningTab(of: "s-web") != nil && sshHeld.isHeld })
    let feature = try #require(reopened.worktrees.first { $0.root == fixture.feature.path })
    try await reopened.remove(feature, force: true, chromeState: nil)
    #expect(harness.hosting.owningTab(of: "s-web") == nil)
    // Well before the SSH list could time out (5 s).
    #expect(await harness.fake.wait(timeout: 2) { harness.requestIDs("kill").contains("s-web") })
    sshHeld.answer(.sessions(HostedSessionList(hostID: "host-a", sessions: [])))
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains("s-web") })
    #expect(!harness.requestIDs("kill").contains("s-editor"))
    #expect(reopened.workspaceIfLoaded(for: fixture.feature.path) == nil)
}
