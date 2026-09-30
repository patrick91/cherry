import AppKit
import Foundation
import Testing
@testable import Cherry

// A launch shows a window's saved persistent tabs before This Mac's host
// answers (`OptimisticRestore`, `RepositoryWorkspace.showsSavedTabsBeforeHostAnswers`),
// then the restore confirms or withdraws each with the usual rules, against
// the fake `cherry control` (FakeControlHelper) and attach adapter
// (HostedSessionFakeCLI).

private func savedTab(
    id: UUID = UUID(),
    kind: TerminalSession.SessionKind = .terminal,
    title: String,
    sessionID: String?,
    owned: Bool? = true,
    commandName: String? = nil,
    restartOnExit: Bool = false,
    exitStatus: Int32? = nil,
    workingDirectory: String
) -> WorkspaceSessionRecord {
    var record = WorkspaceSessionRecord(
        id: id,
        kind: kind,
        title: title,
        titleSource: .system,
        commandName: commandName,
        launchCommand: commandName.map { "run-\($0)" },
        launchWorkingDirectory: workingDirectory,
        workingDirectory: workingDirectory,
        restartOnExit: restartOnExit,
        projectRoot: workingDirectory,
        hosted: sessionID.map { HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: $0, owned: owned) }
    )
    record.exitStatus = exitStatus
    return record
}

private func running(_ id: String, _ record: WorkspaceSessionRecord, pid: UInt32, title: String? = nil) -> HostedSessionInfo {
    HostedSessionInfo(id: id, name: record.title, cwd: record.workingDirectory, pid: pid, title: title, owner: "CherryTests",
                      tags: [PersistentSessionTag.tab: record.id.uuidString])
}

private func exited(_ id: String, _ record: WorkspaceSessionRecord, code: UInt32) -> HostedSessionInfo {
    HostedSessionInfo(id: id, name: record.title, cwd: record.workingDirectory, state: .exited, exitCode: code,
                      owner: "CherryTests", tags: [PersistentSessionTag.tab: record.id.uuidString])
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// Holds a restore until opened: the host "has not answered" meanwhile.
@MainActor
private final class HostAnswerGate {
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
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

/// A project window whose saved tabs come back through `harness`'s fake
/// host, showing them before it answers (as the app's windows do).
@MainActor
private struct OptimisticWindow {
    let harness: PersistentHarness
    let root: URL
    let storeDirectory: URL
    let store: WorkspaceStateStore
    let gate = HostAnswerGate()
    let queue = RestoredTabLaunchQueue()
    let repository: RepositoryWorkspace

    init(
        _ harness: PersistentHarness,
        root: URL,
        sessions: [WorkspaceSessionRecord],
        selected: UUID?,
        savedAt: Date? = Date(),
        showsSavedTabsBeforeHostAnswers: Bool = true
    ) throws {
        self.harness = harness
        self.root = root
        storeDirectory = try temporaryDirectory("cherry-optimistic-store")
        store = WorkspaceStateStore(directory: storeDirectory)
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
            activeWorktreeRoot: root.path,
            worktrees: [WorktreeStateRecord(root: root.path, sessions: sessions, selectedSessionID: selected)],
            savedAt: savedAt
        ))
        let gate = gate
        let restorer = harness.restorer
        repository = RepositoryWorkspace(
            projectRoot: root.path,
            backendPolicy: harness.policy,
            stateStore: store,
            sessionRestorer: { request in
                await gate.wait()
                return await restorer(request)
            },
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: queue,
            showsSavedTabsBeforeHostAnswers: showsSavedTabsBeforeHostAnswers
        )
    }

    var workspace: TerminalWorkspace { repository.activeWorkspace }

    /// Begins the restore and waits until it asks the (held) host.
    func begin() async {
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        _ = await harness.fake.wait { gate.waiting == 1 }
    }

    func answer() async {
        gate.open()
        await repository.waitForPendingRestores()
    }

    func saved() throws -> WorktreeStateRecord? {
        repository.flushPersistentState()
        return store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)
    }

    func cleanUp() {
        gate.open()
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}

// MARK: - Shown before the host answers

@Test @MainActor func savedTabsShowBeforeTheHostAnswersAndStayTheSameTabsOnceItConfirmsThem() async throws {
    let harness2 = try PersistentHarness()
    harness2.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-shown")
    let root = rootURL.path
    let editorID = UUID()
    let serverID = UUID()
    let editor = savedTab(id: editorID, title: "Editor", sessionID: "s-editor", workingDirectory: root)
    let server = savedTab(id: serverID, kind: .command, title: "server", sessionID: "s-server", commandName: "server",
                          workingDirectory: root)
    harness2.fake.sessions = [running("s-editor", editor, pid: 81, title: "vim"), running("s-server", server, pid: 82)]
    let restored = try OptimisticWindow(harness2, root: rootURL, sessions: [editor, server], selected: serverID)
    defer { restored.cleanUp() }
    let registry = ProjectWindowRegistry()
    registry.windowRevealMaximumWait = .seconds(60)
    let nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
                            backing: .buffered, defer: false)
    nsWindow.isReleasedWhenClosed = false
    defer {
        registry.unregister(window: nsWindow, projectRoot: restored.root.path)
        nsWindow.close()
    }
    #expect(registry.register(
        window: nsWindow, projectRoot: restored.root.path, workspace: restored.workspace,
        repository: restored.repository, noteStore: nil, todoStore: nil, chromeState: nil
    ))
    #expect(nsWindow.alphaValue == 0)

    await restored.begin()
    let workspace = restored.workspace
    // The host has not answered: the tabs are there, in their saved order,
    // with the saved selection, and the window shows them.
    #expect(workspace.sessions.map(\.id) == [editorID, serverID])
    #expect(workspace.selectedSessionID == serverID)
    #expect(!restored.repository.isAwaitingInitialRestore)
    #expect(await harness2.fake.wait { nsWindow.alphaValue == 1 })
    let editorTab = try #require(workspace.session(withID: editorID))
    let serverTab = try #require(workspace.session(withID: serverID))
    #expect(editorTab.isProvisionalRestore && serverTab.isProvisionalRestore)
    #expect(editorTab.isPersistentLocalSession)
    #expect(editorTab.persistentSession?.sessionID == "s-editor")
    #expect(serverTab.kind == .command)
    #expect(serverTab.commandName == "server")
    #expect(serverTab.isRunning)
    #expect(harness2.hosting.owningTab(of: "s-server") === serverTab)
    // Its adapter attaches without waiting for the host's list.
    #expect(await harness2.fake.wait { harness2.attachCalls.contains { $0.contains("attach s-server ") } })

    await restored.answer()
    // The same tabs, confirmed, with what the host reports.
    #expect(workspace.sessions.count == 2)
    #expect(workspace.session(withID: editorID) === editorTab)
    #expect(workspace.session(withID: serverID) === serverTab)
    #expect(!editorTab.isProvisionalRestore && !serverTab.isProvisionalRestore)
    #expect(editorTab.hostedProgramProcessID == 81)
    #expect(serverTab.hostedProgramProcessID == 82)
    #expect(workspace.selectedSessionID == serverID)
    #expect(harness2.creates().isEmpty)
    #expect(harness2.fake.requests("kill").isEmpty)
    #expect(try restored.saved()?.sessions.map { $0.hosted?.sessionID } == ["s-editor", "s-server"])
}

/// What the host's answer makes of each tab shown before it: running ones
/// stay; one that ended while Cherry was closed shows its exit and neither
/// closes nor restarts by itself; a terminal whose shell exited cleanly
/// goes (its session removed); a restart's session the saved binding
/// missed takes its tab's place; a session whose holder the host lost
/// comes back ended by the system; one simply gone is dropped. Nothing is
/// killed or created.
@Test @MainActor func theHostsAnswerConfirmsReplacesEndsOrDropsEachTabShownBeforeIt() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-matrix")
    let root = rootURL.path
    let live = savedTab(title: "Live", sessionID: "s-live", workingDirectory: root)
    let failed = savedTab(kind: .command, title: "build", sessionID: "s-build", commandName: "build", restartOnExit: true,
                          workingDirectory: root)
    let clean = savedTab(title: "Done", sessionID: "s-done", workingDirectory: root)
    let restarted = savedTab(title: "Restarted", sessionID: "s-old", workingDirectory: root)
    let lost = savedTab(title: "Lost", sessionID: "s-lost", workingDirectory: root)
    let gone = savedTab(title: "Gone", sessionID: "s-gone", workingDirectory: root)
    harness.fake.sessions = [
        running("s-live", live, pid: 71),
        exited("s-build", failed, code: 2),
        exited("s-done", clean, code: 0),
        running("s-new", restarted, pid: 73)
    ]
    harness.fake.lostSessionIDs = ["s-lost"]
    let records = [live, failed, clean, restarted, lost, gone]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: records, selected: restarted.id)
    defer { window.cleanUp() }
    let workspace = window.workspace

    await window.begin()
    #expect(workspace.sessions.map(\.id) == records.map(\.id))
    #expect(workspace.sessions.allSatisfy { $0.isProvisionalRestore })
    let shown = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0) })
    // What the host says of their ends waits for the restore.
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.exited(id: "s-done", exitCode: 0, signal: nil)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(workspace.session(withID: clean.id)?.isRunning == true)

    await window.answer()
    #expect(workspace.sessions.map(\.id) == [live.id, failed.id, restarted.id, lost.id])
    let liveTab = try #require(workspace.session(withID: live.id))
    #expect(liveTab === shown[live.id])
    #expect(liveTab.isRunning && liveTab.hostedProgramProcessID == 71)
    // Ended while Cherry was closed: the same tab, showing its exit.
    let buildTab = try #require(workspace.session(withID: failed.id))
    #expect(buildTab === shown[failed.id])
    #expect(buildTab.state == .exited(2))
    #expect(!buildTab.isRunning)
    // The restart's session, in a tab of its own with the saved identity,
    // still selected.
    let restartedTab = try #require(workspace.session(withID: restarted.id))
    #expect(restartedTab !== shown[restarted.id])
    #expect(restartedTab.persistentSession?.sessionID == "s-new")
    #expect(!restartedTab.isProvisionalRestore)
    #expect(workspace.selectedSessionID == restarted.id)
    // Its holder killed while no Cherry ran: ended by the system.
    let lostTab = try #require(workspace.session(withID: lost.id))
    #expect(lostTab !== shown[lost.id])
    #expect(lostTab.systemSessionEnd == .logout)
    #expect(!lostTab.isRunning)
    // The clean exit's session is removed; nothing ran again or was killed.
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-done"] })
    try await Task.sleep(for: .milliseconds(300))
    #expect(workspace.session(withID: failed.id)?.state == .exited(2))
    #expect(harness.creates().isEmpty)
    #expect(harness.requestIDs("kill").isEmpty)
    // The records of what came back are saved; the dropped ones are gone.
    let saved = try #require(try window.saved())
    #expect(saved.sessions.map(\.id) == [live.id, failed.id, restarted.id, lost.id])
    #expect(saved.sessions.first { $0.id == restarted.id }?.hosted?.sessionID == "s-new")
}

/// A session missing from a host that does not say whether holders are
/// still to come is looked for again: its tab stays shown meanwhile, and
/// goes once the second look misses it too.
@Test @MainActor func aTabShownForASessionMissingFromTheFirstListStaysUntilTheSecondLook() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = nil
    let rootURL = try temporaryDirectory("cherry-optimistic-second-look")
    let root = rootURL.path
    let live = savedTab(title: "Live", sessionID: "s-live", workingDirectory: root)
    let late = savedTab(title: "Late", sessionID: "s-late", workingDirectory: root)
    harness.fake.sessions = [running("s-live", live, pid: 1)]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [live, late], selected: live.id)
    defer { window.cleanUp() }
    let workspace = window.workspace
    await window.begin()
    let lateTab = try #require(workspace.session(withID: late.id))
    window.gate.open()
    // The first list answered without it: still shown, still provisional.
    #expect(await harness.fake.wait { workspace.session(withID: live.id)?.isProvisionalRestore == false })
    #expect(workspace.session(withID: late.id) === lateTab)
    #expect(lateTab.isProvisionalRestore)
    await window.repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.id) == [live.id])
    #expect(harness.requestIDs("kill").isEmpty)
    #expect(harness.creates().isEmpty)
}

/// Saved before This Mac last booted: nothing shows before the host
/// answers, and the tabs come back ended by the restart, as before.
@Test @MainActor func tabsSavedBeforeARestartWaitForTheHostAndComeBackEnded() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-reboot")
    let root = rootURL.path
    let shell = savedTab(title: "Shell", sessionID: "s-shell", workingDirectory: root)
    let boot = try #require(SystemEndedSessions.currentBootTime())
    let window = try OptimisticWindow(
        harness, root: rootURL, sessions: [shell], selected: shell.id, savedAt: boot.addingTimeInterval(-3_600)
    )
    defer { window.cleanUp() }
    await window.begin()
    #expect(window.workspace.sessions.isEmpty)
    #expect(window.repository.isAwaitingInitialRestore)
    await window.answer()
    let tab = try #require(window.workspace.session(withID: shell.id))
    #expect(tab.systemSessionEnd == .restart)
    #expect(!tab.isRunning)
}

/// A host that cannot be reached: the tabs shown go, their records stay
/// saved, and they come back once it answers.
@Test @MainActor func tabsShownBeforeAnUnreachableHostAnswersGoAndComeBackWhenItIsUp() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-unreachable")
    let root = rootURL.path
    let editor = savedTab(title: "Editor", sessionID: "s-editor", workingDirectory: root)
    harness.fake.launchFailure = "cherry-host did not start"
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [editor], selected: editor.id)
    defer { window.cleanUp() }
    let workspace = window.workspace
    await window.begin()
    let shown = try #require(workspace.session(withID: editor.id))
    #expect(shown.isProvisionalRestore)

    await window.answer()
    #expect(workspace.session(withID: editor.id) == nil)
    // The window's default shell meanwhile; the record stays saved.
    #expect(workspace.sessions.map(\.title) == ["Shell 1"])
    #expect(try window.saved()?.sessions.map(\.id).contains(editor.id) == true)

    harness.fake.launchFailure = nil
    harness.fake.sessions = [running("s-editor", editor, pid: 91)]
    _ = try await harness.control.connect()
    #expect(await harness.fake.wait { workspace.session(withID: editor.id) != nil })
    await window.repository.waitForPendingRestores()
    let back = try #require(workspace.session(withID: editor.id))
    #expect(back.persistentSession?.sessionID == "s-editor")
    #expect(!back.isProvisionalRestore)
    #expect(harness.creates().isEmpty)
    #expect(harness.requestIDs("kill").isEmpty)
}

/// A tab the user closes before the host answered stays closed.
@Test @MainActor func aTabClosedBeforeTheHostAnswersDoesNotComeBack() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-closed")
    let root = rootURL.path
    let keep = savedTab(title: "Keep", sessionID: "s-keep", workingDirectory: root)
    let close = savedTab(title: "Close", sessionID: "s-close", workingDirectory: root)
    harness.fake.sessions = [running("s-keep", keep, pid: 1), running("s-close", close, pid: 2)]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [keep, close], selected: keep.id)
    defer { window.cleanUp() }
    let workspace = window.workspace
    await window.begin()
    let closing = try #require(workspace.session(withID: close.id))
    workspace.close(closing, intent: .userDetachedTab)
    #expect(workspace.session(withID: close.id) == nil)

    await window.answer()
    #expect(workspace.sessions.map(\.id) == [keep.id])
    #expect(workspace.session(withID: keep.id)?.isProvisionalRestore == false)
    #expect(harness.requestIDs("kill").isEmpty)
}

/// Without the window's opt-in (tests, a device's windows) nothing shows
/// before the host answers.
@Test @MainActor func windowsThatDoNotOptInWaitForTheHostAsBefore() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-off")
    let root = rootURL.path
    let editor = savedTab(title: "Editor", sessionID: "s-editor", workingDirectory: root)
    harness.fake.sessions = [running("s-editor", editor, pid: 91)]
    let window = try OptimisticWindow(
        harness, root: rootURL, sessions: [editor], selected: editor.id, showsSavedTabsBeforeHostAnswers: false
    )
    defer { window.cleanUp() }
    await window.begin()
    #expect(window.workspace.sessions.isEmpty)
    #expect(window.repository.isAwaitingInitialRestore)
    await window.answer()
    #expect(window.workspace.sessions.map(\.id) == [editor.id])
}

// MARK: - Which tabs show before the host answers

@Test @MainActor func onlyTabsWhoseSessionsProbablyStillRunShowBeforeTheHostAnswers() throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let root = harness.project.path
    let boot = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = savedTab(title: "Fresh", sessionID: "s-fresh", workingDirectory: root)
    let attached = savedTab(title: "Attached", sessionID: "s-attached", owned: false, workingDirectory: root)
    let olderRecord = savedTab(title: "Older", sessionID: "s-older", owned: nil, workingDirectory: root)
    let unbound = savedTab(title: "Creating", sessionID: nil, workingDirectory: root)
    let savedEnded = savedTab(title: "Exited", sessionID: "s-exited", exitStatus: 3, workingDirectory: root)
    var systemEnded = savedTab(title: "Rebooted", sessionID: "s-rebooted", workingDirectory: root)
    systemEnded.systemEnd = .restart
    var beforeBoot = savedTab(title: "Before boot", sessionID: "s-before", workingDirectory: root)
    beforeBoot.savedAt = boot.addingTimeInterval(-60)
    var beforeLogout = savedTab(title: "Before log out", sessionID: "s-logout", workingDirectory: root)
    beforeLogout.savedAt = boot.addingTimeInterval(60)
    let endedOnPurpose = savedTab(title: "Ended", sessionID: "s-ended", workingDirectory: root)
    let lost = savedTab(title: "Lost", sessionID: "s-lost", workingDirectory: root)
    var ssh = savedTab(title: "Devbox", sessionID: "s-ssh", workingDirectory: root)
    ssh.hosted = HostedSessionBindingRecord(host: "ssh:devbox", hostID: "host-ssh", sessionID: "s-ssh", owned: true)
    let duplicate = savedTab(title: "Same session", sessionID: "s-fresh", workingDirectory: root)

    let systemEnds = SystemEndedSessions(
        savedAt: boot.addingTimeInterval(600),
        bootTime: boot,
        systemQuits: [boot.addingTimeInterval(120)],
        endedOnPurpose: { $0.id == endedOnPurpose.id },
        recordedLostSessions: { hostID in hostID == "host-a" ? ["s-lost"] : [] }
    )
    let records = [fresh, attached, olderRecord, unbound, savedEnded, systemEnded, beforeBoot, beforeLogout,
                   endedOnPurpose, lost, ssh, duplicate]
    #expect(OptimisticRestore.records(records, localSessions: harness.hosting, systemEnds: systemEnds).map(\.id)
        == [fresh.id])

    // A session another open tab owns already is left to the restore.
    let workspace = harness.workspace()
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let freshBinding = try #require(fresh.hosted)
    let info = OptimisticRestore.assumedInfo(of: fresh, binding: freshBinding, owner: harness.hosting.owner)
    #expect(info.id == "s-fresh" && info.isRunning && info.owner == "CherryTests")
    #expect(PersistentLocalSessions.tabID(of: info, owner: "CherryTests") == fresh.id)
    let attachment = try #require(harness.hosting.attachmentWithoutListing(
        freshBinding, name: fresh.title, loginEnvironment: ["LANG": "en_GB.UTF-8"]
    ))
    #expect(attachment.executablePath == harness.cli.executable.path)
    #expect(attachment.environment == ["LANG": "en_GB.UTF-8"])
    let owner = workspace.makeRestoredPersistentSession(
        PersistentSessionLaunch(attachment: attachment, info: info), record: fresh, hosting: harness.hosting,
        deferringLaunch: true, provisional: true
    )
    #expect(owner.isProvisionalRestore)
    #expect(OptimisticRestore.records([fresh], localSessions: harness.hosting, systemEnds: systemEnds).isEmpty)
    owner.stop(keepingSession: true)
    owner.persistentTabDidClose()
}

/// What the host says of a provisional tab's program waits for the
/// restore: an exit it held is applied once the host lists the session as
/// running (it happened live), and one listed ended reports nothing.
@Test @MainActor func aProvisionalTabHoldsItsExitUntilTheRestoreDecides() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let root = harness.project.path
    func provisional(_ record: WorkspaceSessionRecord) throws -> TerminalSession {
        let binding = try #require(record.hosted)
        let attachment = try #require(harness.hosting.attachmentWithoutListing(binding, name: record.title, loginEnvironment: nil))
        return workspace.makeRestoredPersistentSession(
            PersistentSessionLaunch(
                attachment: attachment,
                info: OptimisticRestore.assumedInfo(of: record, binding: binding, owner: harness.hosting.owner)
            ),
            record: record, hosting: harness.hosting, deferringLaunch: true, provisional: true
        )
    }
    let exits = Recorder<[UUID]>([])
    let liveRecord = savedTab(kind: .command, title: "web", sessionID: "s-web", commandName: "web", restartOnExit: true,
                              workingDirectory: root)
    let web = try provisional(liveRecord)
    web.programDidExit = { tab in exits.value.append(tab.id) }
    web.persistentProgramDidExit(sessionID: "s-web", status: 1)
    #expect(web.isRunning)
    web.confirmProvisionalRestore(running("s-web", liveRecord, pid: 5))
    #expect(!web.isProvisionalRestore)
    #expect(web.state == .exited(1))

    let endedRecord = savedTab(title: "Shell", sessionID: "s-shell", workingDirectory: root)
    let shell = try provisional(endedRecord)
    shell.programDidExit = { tab in exits.value.append(tab.id) }
    shell.confirmProvisionalRestore(exited("s-shell", endedRecord, code: 0))
    #expect(shell.state == .exited(0))
    // Only the live exit was reported.
    #expect(exits.value == [web.id])
}

// MARK: - Launch windows

@Test @MainActor func theMostRecentlyActiveProjectOpensFirst() {
    let dates: [String: Date] = ["/b": Date(timeIntervalSince1970: 20), "/c": Date(timeIntervalSince1970: 30)]
    #expect(LaunchWindowOrder.frontFirst(["/a", "/b", "/c"]) { dates[$0] } == ["/c", "/a", "/b"])
    #expect(LaunchWindowOrder.frontFirst(["/a", "/b"]) { _ in nil } == ["/a", "/b"])
    #expect(LaunchWindowOrder.frontFirst([]) { dates[$0] } == [])
}

/// The first window opens alone; the others once it is on screen (and the
/// launch's gate let them), together on one turn; until they open they
/// count as open for the saved window list, so a quit meanwhile keeps them.
@Test @MainActor func theLaunchOpensItsFirstWindowAloneAndTheOthersOnceItShows() async throws {
    let registry = ProjectWindowRegistry()
    registry.windowRevealMaximumWait = .seconds(60)
    let storeDirectory = try temporaryDirectory("cherry-launch-windows-store")
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    let store = WorkspaceStateStore(directory: storeDirectory)
    registry.setWorkspaceStateStoreForTesting(store)
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    var opened: [String] = []
    var gateAsked = 0
    var proceed: (@MainActor () -> Void)?
    let roots = try (0..<3).map { try temporaryDirectory("cherry-launch-window-\($0)").path }
    defer { roots.forEach { try? FileManager.default.removeItem(atPath: $0) } }
    var windows: [NSWindow] = []
    defer {
        for (window, root) in zip(windows, opened) {
            registry.unregister(window: window, projectRoot: root)
            window.close()
        }
    }
    let workspace = TerminalWorkspace(projectRoot: roots[0], createInitialSession: false)
    registry.openLaunchWindows(roots, beforeLaterWindows: { gateAsked += 1; proceed = $0 }) { root in
        opened.append(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        _ = registry.register(window: window, projectRoot: root, workspace: workspace, noteStore: nil,
                              todoStore: nil, chromeState: nil)
    }
    var allOpened = false
    registry.whenLaunchWindowsOpened { allOpened = true }
    // The first window has nothing to restore: it shows at once, and the
    // launch then asks its gate before building the others.
    #expect(opened == [roots[0]])
    #expect(registry.pendingLaunchWindowRoots == [roots[1], roots[2]])
    registry.flushWorkspacePersistence()
    #expect(store.loadOpenProjectWindowRoots() == roots.sorted())
    #expect(await eventually { gateAsked == 1 })
    #expect(opened == [roots[0]])
    let proceedNow = try #require(proceed)
    proceedNow()
    // Together, on the next turn.
    #expect(turns.count == 1)
    #expect(opened == [roots[0]])
    turns.removeFirst()()
    #expect(opened == roots)
    #expect(registry.pendingLaunchWindowRoots.isEmpty)
    #expect(await eventually { allOpened })
}

@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

// MARK: - Restored adapters during the launch

@Test @MainActor func tabsNoWindowShowsWaitWhileTheLaunchHoldsThem() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let queue = RestoredTabLaunchQueue()
    queue.interval = 0.01
    workspace.restoredTabLaunchQueue = queue
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let root = harness.project.path
    let shown = savedTab(title: "Shown", sessionID: "s-shown", workingDirectory: root)
    let hidden = savedTab(title: "Hidden", sessionID: "s-hidden", workingDirectory: root)
    harness.fake.sessions = [running("s-shown", shown, pid: 1), running("s-hidden", hidden, pid: 2)]
    queue.holdBackgroundTabs(atMost: 60)
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: root, worktreeRoot: root, records: [shown, hidden], workspace: workspace
    ))
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: root, sessions: [shown, hidden], selectedSessionID: shown.id
    ))
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach s-shown ") } })
    try await Task.sleep(for: .milliseconds(150))
    #expect(!harness.attachCalls.contains { $0.contains("attach s-hidden ") })
    #expect(queue.pendingTabs.map(\.id) == [hidden.id])
    queue.releaseBackgroundTabs()
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach s-hidden ") } })
}

// MARK: - The last run's login environment

@Test func theLastRunsLoginEnvironmentIsKeptForThisUserAndThisBootOnly() throws {
    let directory = try temporaryDirectory("cherry-login-environment")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(LoginEnvironmentCache.fileName)
    let boot = Date(timeIntervalSince1970: 1_800_000_000)
    let writable = Recorder(true)
    let cache = LoginEnvironmentCache(fileURL: file, shellPath: "/bin/zsh", canWrite: { writable.value }, bootTime: { boot })
    #expect(cache.load() == nil)

    let capture = HostedSessionLoginEnvironment.Capture(environment: ["SSH_AUTH_SOCK": "/agent.sock", "LANG": "en_GB.UTF-8"])
    cache.save(capture, now: boot.addingTimeInterval(10))
    let loaded = try #require(cache.load())
    #expect(loaded.environment == capture.environment)
    #expect(loaded.fromUserShell && loaded.isFromLastRun)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    // Another shell's, or one saved before This Mac booted, is not used.
    #expect(LoginEnvironmentCache(fileURL: file, shellPath: "/bin/bash", canWrite: { true }, bootTime: { boot }).load() == nil)
    cache.save(capture, now: boot.addingTimeInterval(-10))
    #expect(cache.load() == nil)
    // Only a capture of the user's own shell is saved, and only by the copy
    // that may write (the instance lock's holder); never the last run's.
    try? FileManager.default.removeItem(at: file)
    cache.save(.init(environment: ["PATH": "/usr/bin"], fromUserShell: false), now: boot.addingTimeInterval(10))
    #expect(cache.load() == nil)
    writable.value = false
    cache.save(capture, now: boot.addingTimeInterval(10))
    #expect(cache.load() == nil)
    writable.value = true
    cache.save(loaded, now: boot.addingTimeInterval(10))
    #expect(cache.load() == nil)
}

/// With the last run's capture, resolving never waits for the shell: it
/// answers that capture while the shell runs in the background, then this
/// run's (saved for the next launch, and handed to whoever got the old one).
@Test func theLoginEnvironmentAnswersTheLastRunsCaptureWhileItCapturesAgain() async throws {
    let directory = try temporaryDirectory("cherry-login-environment-resolve")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = LoginEnvironmentCache(
        fileURL: directory.appendingPathComponent(LoginEnvironmentCache.fileName),
        shellPath: "/bin/zsh", canWrite: { true }, bootTime: { nil }
    )
    cache.save(.init(environment: ["SSH_AUTH_SOCK": "/old.sock"]))
    let shellMayFinish = DispatchSemaphore(value: 0)
    let captures = Recorder(0)
    let resolver = HostedSessionLoginEnvironment(capture: {
        captures.value += 1
        shellMayFinish.wait()
        return .init(environment: ["SSH_AUTH_SOCK": "/new.sock"])
    })
    resolver.lastRunCache = cache
    #expect(resolver.availableNow() == nil)
    let first = try #require(resolver.resolve())
    #expect(first.environment == ["SSH_AUTH_SOCK": "/old.sock"])
    #expect(first.isFromLastRun)
    #expect(resolver.availableNow()?.environment == ["SSH_AUTH_SOCK": "/old.sock"])
    let refreshed = Recorder<[String: String]?>(nil)
    resolver.onRefresh { refreshed.value = $0.environment }
    #expect(resolver.resolve()?.environment == ["SSH_AUTH_SOCK": "/old.sock"])
    shellMayFinish.signal()
    let deadline = Date().addingTimeInterval(5)
    while refreshed.value == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(refreshed.value == ["SSH_AUTH_SOCK": "/new.sock"])
    #expect(resolver.resolve()?.environment == ["SSH_AUTH_SOCK": "/new.sock"])
    #expect(resolver.resolve()?.isFromLastRun == false)
    #expect(cache.load()?.environment == ["SSH_AUTH_SOCK": "/new.sock"])
    #expect(captures.value == 1)
}

// MARK: - Review fixes

@MainActor
private func quietChrome() -> ProjectWindowChromeState {
    ProjectWindowChromeState(toasts: ProjectWindowToasts(
        now: { Date() }, schedule: { _, _ in }, announce: { _ in }, voiceOverEnabled: { false }
    ))
}

/// Restart (menu, MCP) of a provisional tab before the host answered: the
/// tab is the user's now; the restore leaves it and its record alone.
@Test @MainActor func aProvisionalTabRestartedBeforeTheHostAnswersStays() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    harness.fake.killEndsSession = false
    let rootURL = try temporaryDirectory("cherry-optimistic-restart")
    let root = rootURL.path
    let keep = savedTab(title: "Keep", sessionID: "s-keep", workingDirectory: root)
    let redo = savedTab(title: "Redo", sessionID: "s-redo", workingDirectory: root)
    harness.fake.sessions = [running("s-keep", keep, pid: 1), running("s-redo", redo, pid: 2)]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [keep, redo], selected: keep.id)
    defer { window.cleanUp() }
    let workspace = window.workspace
    await window.begin()
    let tab = try #require(workspace.session(withID: redo.id))
    #expect(workspace.restart(tab))
    #expect(!tab.isProvisionalRestore)
    #expect(await harness.fake.wait { !harness.requestIDs("kill").isEmpty })
    await window.answer()
    #expect(workspace.sessions.contains { $0 === tab })
    #expect(workspace.sessions.map(\.id) == [keep.id, redo.id])
    #expect(await harness.fake.wait { harness.creates().count == 1 && tab.persistentSession?.sessionID != "s-redo" })
    #expect(workspace.sessions.contains { $0 === tab })
    #expect(try window.saved()?.sessions.map(\.id) == [keep.id, redo.id])
}

/// Holds the fake host's answers to `list` (the app's control connection
/// lists as it connects, apart from the restore) until `release()`: the
/// host has really not answered meanwhile, so `hasListedSessions` is false.
private final class HeldHostLists: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = true
    private var held: [(request: FakeControlHelper.Request, connection: FakeControlHelper.Connection)] = []

    func install(on fake: FakeControlHelper) {
        fake.respond = { [self] request, connection in
            guard request.op == "list" else { return nil }
            return lock.withLock {
                guard holding else { return nil }
                held.append((request, connection))
                return .silence
            }
        }
    }

    /// Answers the lists held so far, and every later one, as the fake would.
    func release(_ fake: FakeControlHelper) {
        let pending = lock.withLock {
            holding = false
            defer { held.removeAll() }
            return held
        }
        for (request, connection) in pending {
            if case .answer(let message) = fake.defaultReply(to: request, on: connection) {
                connection.push(message, req: request.req)
            }
        }
    }
}

/// ⌘W then ⌘Z on a provisional tab before the host answered brings it back
/// (still provisional, confirmed once the host answers); nothing is ended.
@Test @MainActor func undoingTheCloseOfAProvisionalTabBeforeTheHostAnswersBringsItBack() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    // Not the restore alone: no list of the host's is answered until the
    // restore's is (else ⌘Z finds the session listed and brings the tab
    // back confirmed, as the next test does).
    let lists = HeldHostLists()
    lists.install(on: harness.fake)
    let rootURL = try temporaryDirectory("cherry-optimistic-undo")
    let root = rootURL.path
    let keep = savedTab(title: "Keep", sessionID: "s-keep", workingDirectory: root)
    let close = savedTab(title: "Close", sessionID: "s-close", workingDirectory: root)
    harness.fake.sessions = [running("s-keep", keep, pid: 1), running("s-close", close, pid: 2)]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [keep, close], selected: keep.id)
    defer {
        lists.release(harness.fake)
        window.cleanUp()
    }
    let workspace = window.workspace
    await window.begin()
    let closing = try #require(workspace.session(withID: close.id))
    let chrome = quietChrome()
    SessionCloseCoordinator.closeTab(closing, in: workspace, chromeState: chrome)
    #expect(workspace.session(withID: close.id) == nil)
    #expect(!harness.control.hasListedSessions)
    #expect(chrome.closedTabs.undoLatest())
    let back = try #require(workspace.session(withID: close.id))
    #expect(back.isProvisionalRestore)
    #expect(back.persistentSession?.sessionID == "s-close")
    lists.release(harness.fake)
    await window.answer()
    #expect(workspace.sessions.map(\.id) == [keep.id, close.id])
    #expect(workspace.session(withID: close.id) === back)
    #expect(back.isProvisionalRestore == false)
    #expect(back.hostedProgramProcessID == 2)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.requestIDs("kill").isEmpty)
    #expect(harness.requestIDs("remove").isEmpty)
    #expect(workspace.session(withID: close.id) === back)
}

/// The same ⌘Z once the host listed its sessions but before the restore
/// took its answer: the tab comes back as the host lists it (the user's,
/// not provisional), and the restore leaves it and its session alone.
@Test @MainActor func undoingTheCloseOfAProvisionalTabAfterTheHostListedButBeforeTheRestoreAnsweredKeepsIt() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-undo-listed")
    let root = rootURL.path
    let keep = savedTab(title: "Keep", sessionID: "s-keep", workingDirectory: root)
    let close = savedTab(title: "Close", sessionID: "s-close", workingDirectory: root)
    harness.fake.sessions = [running("s-keep", keep, pid: 1), running("s-close", close, pid: 2)]
    let window = try OptimisticWindow(harness, root: rootURL, sessions: [keep, close], selected: keep.id)
    defer { window.cleanUp() }
    let workspace = window.workspace
    await window.begin()
    let closing = try #require(workspace.session(withID: close.id))
    let chrome = quietChrome()
    SessionCloseCoordinator.closeTab(closing, in: workspace, chromeState: chrome)
    #expect(workspace.session(withID: close.id) == nil)
    _ = try await harness.control.list()
    #expect(harness.control.hasListedSessions)
    #expect(chrome.closedTabs.undoLatest())
    let back = try #require(workspace.session(withID: close.id))
    #expect(!back.isProvisionalRestore)
    #expect(back.persistentSession?.sessionID == "s-close")
    #expect(back.hostedProgramProcessID == 2)
    await window.answer()
    #expect(workspace.sessions.map(\.id) == [keep.id, close.id])
    #expect(workspace.session(withID: close.id) === back)
    #expect(back.hostedProgramProcessID == 2)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.requestIDs("kill").isEmpty)
    #expect(harness.requestIDs("remove").isEmpty)
    #expect(workspace.session(withID: close.id) === back)
}

/// A window mixing tabs shown early and tabs that wait for the host (one
/// saved ended, a split with both kinds) comes back in its saved order and
/// layout, and saves them so.
@Test(arguments: [true, false]) @MainActor func mixedTabsKeepTheirSavedOrderAndSplits(optimistic: Bool) async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let rootURL = try temporaryDirectory("cherry-optimistic-layout")
    let root = rootURL.path
    let a = savedTab(title: "A", sessionID: "s-a", workingDirectory: root)
    let b = savedTab(title: "B", sessionID: "s-b", exitStatus: 1, workingDirectory: root)
    let c = savedTab(title: "C", sessionID: "s-c", workingDirectory: root)
    let d = savedTab(title: "D", sessionID: "s-d", workingDirectory: root)
    harness.fake.sessions = [running("s-a", a, pid: 1), exited("s-b", b, code: 1), running("s-c", c, pid: 3),
                             running("s-d", d, pid: 4)]
    let group = UUID()
    let storeDirectory = try temporaryDirectory("cherry-optimistic-layout-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root,
        worktrees: [WorktreeStateRecord(
            root: root, sessions: [a, b, c, d],
            displayItems: [.init(kind: .single, id: a.id), .init(kind: .split, id: group)],
            splitGroups: [.init(id: group, paneSessionIDs: [b.id, c.id], activeSessionID: c.id, widthWeights: [0.3, 0.7])],
            selectedSessionID: c.id
        )],
        savedAt: Date()
    ))
    let repository = RepositoryWorkspace(
        projectRoot: root, backendPolicy: harness.policy, stateStore: store, sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] }, restoredTabLaunchQueue: RestoredTabLaunchQueue(),
        showsSavedTabsBeforeHostAnswers: optimistic
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    #expect(workspace.sessions.map(\.id) == [a.id, b.id, c.id, d.id])
    #expect(workspace.terminalSplitGroups.map(\.paneSessionIDs) == [[b.id, c.id]])
    #expect(workspace.terminalDisplayItems == [.single(a.id), .split(group), .single(d.id)])
    #expect(workspace.selectedSessionID == c.id)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root))
    #expect(saved.sessions.map(\.id) == [a.id, b.id, c.id, d.id])
    #expect(saved.splitGroups.map(\.paneSessionIDs) == [[b.id, c.id]])
}

/// A quit while the launch's later windows are still to open: they never
/// open, and a quit that ends sessions ends theirs too.
@Test @MainActor func aQuitBeforeTheLaterLaunchWindowsOpenedCountsTheirSessions() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let registry = ProjectWindowRegistry()
    registry.windowRevealMaximumWait = .seconds(60)
    let storeDirectory = try temporaryDirectory("cherry-launch-quit-store")
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    let store = WorkspaceStateStore(directory: storeDirectory)
    registry.setWorkspaceStateStoreForTesting(store)
    registry.launchWindowHosting = harness.hosting
    var turns: [@MainActor () -> Void] = []
    registry.scheduleLaunchWindowTurn = { turns.append($0) }
    let roots = try (0..<2).map { try temporaryDirectory("cherry-launch-quit-\($0)").path }
    defer { roots.forEach { try? FileManager.default.removeItem(atPath: $0) } }
    let later = savedTab(title: "Later", sessionID: "s-later", workingDirectory: roots[1])
    let native = savedTab(title: "Native", sessionID: nil, workingDirectory: roots[1])
    harness.fake.sessions = [running("s-later", later, pid: 5)]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: roots[1], activeWorktreeRoot: roots[1],
        worktrees: [WorktreeStateRecord(root: roots[1], sessions: [later, native])]
    ))
    var opened: [String] = []
    var windows: [NSWindow] = []
    defer {
        for (window, root) in zip(windows, opened) {
            registry.unregister(window: window, projectRoot: root)
            window.close()
        }
    }
    let workspace = TerminalWorkspace(projectRoot: roots[0], createInitialSession: false)
    var proceed: (@MainActor () -> Void)?
    registry.openLaunchWindows(roots, beforeLaterWindows: { proceed = $0 }) { root in
        opened.append(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        _ = registry.register(window: window, projectRoot: root, workspace: workspace, noteStore: nil,
                              todoStore: nil, chromeState: nil)
    }
    #expect(await eventually { proceed != nil })
    #expect(registry.localSessionsEndedByAQuit().map(\.sessionID) == ["s-later"])
    registry.tearDownForQuit(intent: .appQuitEndingSessions)
    #expect(await harness.fake.wait { harness.requestIDs("kill").contains("s-later") })
    let proceedNow = try #require(proceed)
    proceedNow()
    turns.forEach { $0() }
    #expect(opened == [roots[0]])
}

/// Only the variables Cherry uses are kept, out of backups, and a file that
/// is not this user's own private file is not read.
@Test func theCachedLoginEnvironmentKeepsOnlyWhatCherryUsesPrivately() throws {
    let directory = try temporaryDirectory("cherry-login-environment-private")
    defer { try? FileManager.default.removeItem(at: directory) }
    var file = directory.appendingPathComponent(LoginEnvironmentCache.fileName)
    let cache = LoginEnvironmentCache(
        fileURL: file, shellPath: "/bin/zsh", canWrite: { true }, bootTime: { nil },
        processSSHAuthSock: { "/launchd/agent" }, systemQuits: { [] }
    )
    cache.save(.init(environment: [
        "PATH": "/opt/bin:/usr/bin", "LANG": "en_GB.UTF-8", "LC_CTYPE": "UTF-8", "SSH_AUTH_SOCK": "/agent.sock",
        "SHELL": "/bin/zsh", "GITHUB_TOKEN": "secret", "AWS_SECRET_ACCESS_KEY": "secret", "OP_SESSION": "secret"
    ]))
    let loaded = try #require(cache.load())
    #expect(loaded.environment == [
        "PATH": "/opt/bin:/usr/bin", "LANG": "en_GB.UTF-8", "LC_CTYPE": "UTF-8", "SSH_AUTH_SOCK": "/agent.sock",
        "SHELL": "/bin/zsh"
    ])
    #expect(try String(contentsOf: file, encoding: .utf8).contains("secret") == false)
    #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    // Readable by others: not used.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(cache.load() == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(cache.load() != nil)
    // A symbolic link in its place: not followed.
    let elsewhere = directory.appendingPathComponent("elsewhere.json")
    try FileManager.default.moveItem(at: file, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    #expect(cache.load() == nil)
    file.removeAllCachedResourceValues()
}

/// Another login session (launchd's agent socket changed), or a log out
/// since the save: the cache is not used. SSH masters never get its agent.
@Test func theCachedLoginEnvironmentIsForThisLoginSessionOnly() throws {
    let directory = try temporaryDirectory("cherry-login-environment-session")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(LoginEnvironmentCache.fileName)
    let launchdAgent = Recorder<String?>("/private/tmp/launchd-1/Listeners")
    let quits = Recorder<[Date]?>([])
    let cache = LoginEnvironmentCache(
        fileURL: file, shellPath: "/bin/zsh", canWrite: { true }, bootTime: { nil },
        processSSHAuthSock: { launchdAgent.value }, systemQuits: { quits.value }
    )
    let savedAt = Date()
    cache.save(.init(environment: ["SSH_AUTH_SOCK": "/1password/agent.sock", "PATH": "/usr/bin"]), now: savedAt)
    #expect(cache.load() != nil)
    launchdAgent.value = "/private/tmp/launchd-2/Listeners"
    #expect(cache.load() == nil)
    launchdAgent.value = "/private/tmp/launchd-1/Listeners"
    quits.value = [savedAt.addingTimeInterval(-60)]
    #expect(cache.load() != nil)
    quits.value = [savedAt.addingTimeInterval(60)]
    #expect(cache.load() == nil)
    // Unknown (the instance lock not taken yet): not used.
    quits.value = nil
    #expect(cache.load() == nil)

    let lastRun = HostedSessionLoginEnvironment.Capture(
        environment: ["SSH_AUTH_SOCK": "/1password/agent.sock", "PATH": "/opt/bin"], isFromLastRun: true
    )
    let base = ["SSH_AUTH_SOCK": "/launchd/agent", "PATH": "/usr/bin", "HOME": "/Users/me"]
    let masters = HostControl.sshMasterEnvironment(base: base, login: lastRun)
    #expect(masters["SSH_AUTH_SOCK"] == "/launchd/agent")
    #expect(masters["PATH"] == "/opt/bin")
    var fresh = lastRun
    fresh.isFromLastRun = false
    #expect(HostControl.sshMasterEnvironment(base: base, login: fresh)["SSH_AUTH_SOCK"] == "/1password/agent.sock")
}

@Test func launchContentChecksAreThrottledPerSurface() {
    var check = LaunchContentCheck(interval: 0.05)
    let start = Date(timeIntervalSince1970: 1_000)
    let first = check.isDue(at: start)
    let tooSoon = check.isDue(at: start.addingTimeInterval(0.01))
    let later = check.isDue(at: start.addingTimeInterval(0.06))
    #expect(first && !tooSoon && later)
}
