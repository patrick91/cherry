import AppKit
import Combine
import Foundation
import Testing
@testable import Cherry

// Restoring saved tabs through each host's control plane
// (docs/specs/multiplexer-default.md, "Relaunch"): the restore matrix
// (running, ended, missing, unreachable, adopted by tag, another app's,
// duplicated), staggered attach, agent trees and auto-start, against the
// fake `cherry control` (FakeControlHelper) and attach adapter
// (HostedSessionFakeCLI). See PersistentLocalSessionRealHostTests for the
// end-to-end restore against a real cherry-host.

private func localRecord(
    id: UUID = UUID(),
    kind: TerminalSession.SessionKind = .terminal,
    title: String,
    sessionID: String?,
    hostID: String = "host-a",
    owned: Bool? = true,
    agentName: String? = nil,
    parentAgentID: UUID? = nil,
    commandName: String? = nil,
    restartOnExit: Bool = false,
    workingDirectory: String
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: kind,
        title: title,
        titleSource: .system,
        agentName: agentName,
        parentAgentID: parentAgentID,
        commandName: commandName,
        launchCommand: commandName.map { "run-\($0)" } ?? agentName?.lowercased(),
        launchEnvironment: commandName == nil ? [:] : ["PORT": "8000"],
        launchWorkingDirectory: workingDirectory,
        workingDirectory: workingDirectory,
        restartOnExit: restartOnExit,
        projectRoot: workingDirectory,
        hosted: sessionID.map {
            HostedSessionBindingRecord(host: "local", hostID: hostID, sessionID: $0, owned: owned)
        }
    )
}

private func sshRecord(
    id: UUID = UUID(),
    kind: TerminalSession.SessionKind = .terminal,
    title: String,
    sessionID: String,
    hostID: String = "host-ssh",
    agentName: String? = nil,
    commandName: String? = nil
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: kind,
        title: title,
        titleSource: .system,
        agentName: agentName,
        commandName: commandName,
        launchCommand: commandName.map { "run-\($0)" },
        workingDirectory: NSHomeDirectory(),
        projectRoot: "/project",
        hosted: HostedSessionBindingRecord(host: "ssh:devbox", hostID: hostID, sessionID: sessionID, owned: false)
    )
}

@MainActor
private extension PersistentHarness {
    func push(_ event: HostSessionEvent) {
        fake.connections.last(where: { !$0.isClosed })?.push(.event(event))
    }

    func restore(
        _ records: [WorkspaceSessionRecord],
        unbound: [WorkspaceSessionRecord] = [],
        into workspace: TerminalWorkspace,
        control: (@MainActor (HostedSessionHost) -> HostControl)? = nil,
        systemEnds: SystemEndedSessions? = nil
    ) async -> WorkspaceRestoreResult {
        let restorer = control.map { WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting, control: $0) } ?? restorer
        return await restorer(WorkspaceRestoreRequest(
            repositoryRoot: project.path,
            worktreeRoot: project.path,
            records: records,
            workspace: workspace,
            unboundRecords: unbound,
            systemEnds: systemEnds
        ))
    }

    func attached(_ sessionID: String) -> Bool {
        attachCalls.contains { $0.contains("attach \(sessionID) ") }
    }

    /// A control connection to the SSH host `devbox`, answered by `fake`,
    /// whose adapters are this harness's fake CLI.
    func sshControl(_ fake: FakeControlHelper, hostStore: HostedSessionHostStore) throws -> HostControl {
        let executable = cli.executable
        return HostControl(
            host: try .ssh("devbox"),
            clientProvider: {
                HostedSessionClient(
                    executableURL: executable,
                    loginEnvironment: { _ in .init(environment: ["SSH_AUTH_SOCK": "/login/agent.sock"]) }
                )
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
    }
}

private func canonicalDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

// MARK: - This Mac

@Test @MainActor func restoringThisMacsSessionsFollowsTheMatrixAndAttachesLater() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    // Its own launch queue: other tests' restored tabs never mix in.
    let queue = RestoredTabLaunchQueue()
    workspace.restoredTabLaunchQueue = queue
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let running = localRecord(kind: .command, title: "server", sessionID: "s-running", commandName: "server", workingDirectory: project)
    let ended = localRecord(title: "Build", sessionID: "s-ended", workingDirectory: project)
    let missing = localRecord(title: "Gone", sessionID: "s-missing", workingDirectory: project)
    // Its binding names a session that is gone, but the host has one this
    // app started for the tab (a restart whose new binding was never saved).
    let restarted = localRecord(kind: .agent, title: "Claude", sessionID: "s-old", agentName: "Claude", workingDirectory: project)
    // Saved before its session's Create answered: no binding at all.
    let unbound = localRecord(title: "Fresh", sessionID: nil, workingDirectory: project)
    let nativeTab = localRecord(title: "Native", sessionID: nil, workingDirectory: project)
    // Owned by the saved tab, but another app variant created the session:
    // it comes back only attached, with its saved kind.
    let foreign = localRecord(kind: .agent, title: "Theirs", sessionID: "s-foreign", agentName: "Codex", workingDirectory: project)
    let foreignUnbound = localRecord(title: "Not ours", sessionID: nil, workingDirectory: project)
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-running", name: "server", cwd: project, pid: 61, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: running.id.uuidString]),
        HostedSessionInfo(id: "s-ended", name: "Build", cwd: project, state: .exited, exitCode: 3, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: ended.id.uuidString]),
        HostedSessionInfo(id: "s-restarted", name: "Claude", cwd: project, pid: 62, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: restarted.id.uuidString], createdAt: 2),
        HostedSessionInfo(id: "s-restarted-before", name: "Claude", cwd: project, state: .exited, exitCode: 0,
                          owner: "CherryTests", tags: [PersistentSessionTag.tab: restarted.id.uuidString], createdAt: 1),
        HostedSessionInfo(id: "s-unbound", name: "Fresh", cwd: project, pid: 63, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: unbound.id.uuidString]),
        HostedSessionInfo(id: "s-foreign", name: "Theirs", cwd: project, pid: 64, owner: "Cherry Sessions",
                          tags: [PersistentSessionTag.tab: foreign.id.uuidString]),
        HostedSessionInfo(id: "s-foreign-unbound", name: "Not ours", cwd: project, pid: 65, owner: "Cherry Sessions",
                          tags: [PersistentSessionTag.tab: foreignUnbound.id.uuidString])
    ]
    harness.fake.screenText = "make: *** [all] Error 3"

    let result = await harness.restore(
        [running, ended, missing, restarted, foreign],
        unbound: [unbound, nativeTab, foreignUnbound],
        into: workspace
    )
    #expect(result.keptRecordIDs.isEmpty)
    #expect(result.retryWhenAvailable == nil)
    #expect(result.sessions.map(\.id) == [running.id, ended.id, restarted.id, foreign.id, unbound.id])
    let tabs = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0) })
    let server = try #require(tabs[running.id])
    let build = try #require(tabs[ended.id])
    let claude = try #require(tabs[restarted.id])
    let theirs = try #require(tabs[foreign.id])
    let fresh = try #require(tabs[unbound.id])

    // Running: a persistent tab of its saved kind that follows its program
    // through the host at once; its adapter waits for the restore to add it.
    #expect(server.isPersistentLocalSession)
    #expect(server.kind == .command)
    #expect(server.commandName == "server")
    #expect(server.persistentSession?.sessionID == "s-running")
    #expect(server.isAwaitingDeferredLaunch)
    #expect(server.isRunning)
    #expect(server.state == .live)
    #expect(server.hostedProgramProcessID == 61)
    #expect(harness.hosting.boundTab(for: "s-running") === server)
    // Adopted by tag: the running session, not the ended one before it.
    #expect(claude.isPersistentLocalSession)
    #expect(claude.kind == .agent)
    #expect(claude.persistentSession?.sessionID == "s-restarted")
    #expect(fresh.isPersistentLocalSession)
    #expect(fresh.persistentSession?.sessionID == "s-unbound")
    // Another app's session: attached, with the saved metadata.
    #expect(!theirs.isPersistentLocalSession)
    #expect(theirs.hostedAttachment?.sessionID == "s-foreign")
    #expect(theirs.kind == .agent)
    #expect(theirs.agentName == "Codex")
    #expect(theirs.isAwaitingDeferredLaunch)
    #expect(theirs.state == .launching)
    // Its program's pid counts only while its adapter runs.
    #expect(theirs.hostedProgramProcessID == nil)
    // Ended: no adapter, its exit and final screen.
    #expect(build.state == .exited(3))
    #expect(build.persistentSessionEndedMessage == "Session ended (exit 3)")
    #expect(!build.isAwaitingDeferredLaunch)
    #expect(await harness.fake.wait { build.snapshot(range: 0..<build.lineCount).contains("make: *** [all] Error 3") })
    #expect(build.snapshot(range: 0..<build.lineCount).last == "[shell exited with status 3]")
    #expect(harness.attachCalls.isEmpty)
    #expect(harness.creates().isEmpty)

    // Before any adapter runs, the host's events reach the tabs.
    let bells = Recorder(0)
    server.bellHandler = { _ in bells.value += 1 }
    theirs.bellHandler = { _ in bells.value += 1 }
    harness.push(.changed(HostedSessionInfo(
        id: "s-running", name: "server", cwd: project, pid: 61, title: "npm run dev", owner: "CherryTests",
        tags: [PersistentSessionTag.tab: running.id.uuidString]
    )))
    harness.push(.bell(id: "s-running"))
    harness.push(.bell(id: "s-foreign"))
    #expect(await harness.fake.wait { bells.value == 2 && server.title == "npm run dev" })
    harness.exit("s-unbound", code: 7)
    #expect(await harness.fake.wait { fresh.state == .exited(7) })
    #expect(!fresh.isAwaitingDeferredLaunch)
    #expect(await harness.fake.wait { harness.requestIDs("screen").contains("s-unbound") })
    // MCP input to an attached tab whose adapter waits for its turn goes
    // through the host (SendInput), and does not launch the adapter.
    #expect(theirs.acceptsControlInput)
    #expect(!theirs.acceptsInput)
    try await theirs.sendControlInput(Data("status\r".utf8), raw: true)
    #expect(harness.requestIDs("send_input") == ["s-foreign"])
    #expect(theirs.isAwaitingDeferredLaunch)
    #expect(harness.attachCalls.isEmpty)

    // Added with the saved layout, the tabs attach (the selection first).
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: project,
        sessions: [running, ended, missing, restarted, foreign, unbound],
        selectedSessionID: restarted.id
    ))
    #expect(workspace.sessions.map(\.id) == [running.id, ended.id, restarted.id, foreign.id, unbound.id])
    #expect(workspace.selectedSessionID == restarted.id)
    #expect(queue.pendingTabs.map(\.id) == [restarted.id, running.id, foreign.id])
    #expect(harness.attachCalls.isEmpty)
    #expect(await harness.fake.wait {
        harness.attached("s-running") && harness.attached("s-restarted") && harness.attached("s-foreign")
    })
    #expect(theirs.hostedProgramProcessID == 64)
    #expect(!harness.attached("s-ended"))
    #expect(!harness.attached("s-unbound"))
    #expect(workspace.sessions.allSatisfy { session in !session.isAwaitingDeferredLaunch })
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)

    // Closing the ended tab removes its session; nothing else was ended.
    workspace.close(build)
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-ended"] })
}

@Test @MainActor func aSavedTerminalWhoseShellExitedCleanlyWhileCherryWasClosedIsNotRestoredAndItsSessionIsRemoved() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let clean = localRecord(title: "Done", sessionID: "s-clean", workingDirectory: project)
    let failed = localRecord(title: "Failed", sessionID: "s-failed", workingDirectory: project)
    let agent = localRecord(kind: .agent, title: "Claude", sessionID: "s-agent", agentName: "Claude", workingDirectory: project)
    let command = localRecord(kind: .command, title: "build", sessionID: "s-command", commandName: "build", workingDirectory: project)
    // Another app variant's terminal: only attached, never this app's to end.
    let foreign = localRecord(title: "Theirs", sessionID: "s-foreign", workingDirectory: project)
    func ended(_ id: String, _ record: WorkspaceSessionRecord, code: UInt32, owner: String = "CherryTests") -> HostedSessionInfo {
        HostedSessionInfo(id: id, name: record.title, cwd: project, state: .exited, exitCode: code, owner: owner,
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    harness.fake.sessions = [
        ended("s-clean", clean, code: 0),
        ended("s-failed", failed, code: 3),
        ended("s-agent", agent, code: 0),
        ended("s-command", command, code: 0),
        ended("s-foreign", foreign, code: 0, owner: "Cherry Sessions")
    ]
    let records = [clean, failed, agent, command, foreign]

    // Its tab would have closed while Cherry ran: it does not come back
    // (no tab, and its record is not kept), and its session is removed.
    let result = await harness.restore(records, into: workspace)
    #expect(result.keptRecordIDs.isEmpty)
    #expect(result.pendingRecordIDs.isEmpty)
    #expect(result.sessions.map(\.id) == [failed.id, agent.id, command.id, foreign.id])
    #expect(await harness.fake.wait { harness.requestIDs("remove") == ["s-clean"] })
    #expect(harness.requestIDs("kill").isEmpty)
    // Everything else ended comes back showing how it ended.
    let tabs = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0) })
    #expect(tabs[failed.id]?.persistentSessionEndedMessage == "Session ended (exit 3)")
    #expect(tabs[agent.id]?.persistentSessionEndedMessage == "Session ended (exit 0)")
    #expect(tabs[command.id]?.isPersistentLocalSession == true)
    #expect(tabs[command.id]?.state == .exited(0))
    #expect(tabs[foreign.id]?.hostedAttachment?.sessionID == "s-foreign")
    #expect(tabs[foreign.id]?.hostedAttachmentStatus == .exited(code: 0, signal: nil))
    // Opened to show their exit: they stay once added.
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(root: project, sessions: records))
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.map(\.id) == [failed.id, agent.id, command.id, foreign.id])
    #expect(harness.requestIDs("remove") == ["s-clean"])

    // With Settings › Sessions keeping such tabs, it comes back as before.
    harness.settings.value.closeTabsOnCleanExit = false
    let keeping = harness.workspace()
    keeping.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer { keeping.closeAllSessions(intent: .windowClosed) }
    let kept = localRecord(title: "Kept", sessionID: "s-kept", workingDirectory: project)
    harness.fake.sessions.append(ended("s-kept", kept, code: 0))
    let keptResult = await harness.restore([kept], into: keeping)
    #expect(keptResult.sessions.map(\.id) == [kept.id])
    #expect(keptResult.sessions.first?.persistentSessionEndedMessage == "Session ended (exit 0)")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!harness.requestIDs("remove").contains("s-kept"))
}

@Test @MainActor func aRestoredTabShownBeforeItsTurnAttachesAtOnce() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let queue = RestoredTabLaunchQueue()
    workspace.restoredTabLaunchQueue = queue
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let records = (0..<6).map { index in
        localRecord(title: "Tab \(index)", sessionID: "s-\(index)", workingDirectory: project)
    }
    harness.fake.sessions = records.enumerated().map { index, record in
        HostedSessionInfo(id: "s-\(index)", name: record.title, cwd: project, pid: UInt32(70 + index), owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    let result = await harness.restore(records, into: workspace)
    #expect(result.sessions.count == 6)
    // Showing a tab (its surface) attaches it, ahead of the queue.
    let shownEarly = try #require(result.sessions.last)
    _ = shownEarly.ghosttyBridge
    #expect(!shownEarly.isAwaitingDeferredLaunch)
    #expect(shownEarly.usesNativePTYBackend)
    #expect(await harness.fake.wait { harness.attached("s-5") })
    #expect(harness.attachCalls.count == 1)

    // The saved selection (a split's pane) and the split's other pane go
    // first; the others follow a few per turn, never all at once.
    let splitID = UUID()
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: project,
        sessions: records,
        displayItems: [
            WorkspaceDisplayItemRecord(kind: .single, id: records[0].id),
            WorkspaceDisplayItemRecord(kind: .split, id: splitID)
        ] + records[1...2].map { WorkspaceDisplayItemRecord(kind: .single, id: $0.id) },
        splitGroups: [WorkspaceSplitGroupRecord(
            id: splitID, paneSessionIDs: [records[3].id, records[4].id],
            activeSessionID: records[4].id, widthWeights: [0.5, 0.5]
        )],
        selectedSessionID: records[4].id
    ))
    #expect(harness.attachCalls.count == 1)
    #expect(queue.pendingTabs.map(\.id) == [3, 4, 0, 1, 2].map { records[$0].id })
    #expect(await harness.fake.wait { harness.attachCalls.count == 6 })
    #expect(queue.pendingTabs.isEmpty)
}

@Test @MainActor func restoredAgentTreesPutParentsFirstAndKeepGroupsLayoutAndSelection() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-tree")
    let storeDirectory = try canonicalDirectory("cherry-restore-tree-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let parent = localRecord(kind: .agent, title: "Lead", sessionID: "s-parent", agentName: "Claude", workingDirectory: root.path)
    let child = localRecord(
        kind: .agent, title: "Helper", sessionID: "s-child", agentName: "Codex", parentAgentID: parent.id,
        workingDirectory: root.path
    )
    let orphan = localRecord(
        kind: .agent, title: "Orphan", sessionID: "s-orphan", agentName: "Codex", parentAgentID: UUID(),
        workingDirectory: root.path
    )
    let left = localRecord(title: "Left", sessionID: "s-left", workingDirectory: root.path)
    let right = localRecord(title: "Right", sessionID: "s-right", workingDirectory: root.path)
    harness.fake.sessions = [parent, child, orphan, left, right].map { record in
        HostedSessionInfo(id: record.hosted!.sessionID, name: record.title, cwd: root.path, pid: 80, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    let splitID = UUID()
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(
            root: root.path,
            // A child saved before its parent (moved in the sidebar).
            sessions: [child, left, parent, orphan, right],
            displayItems: [WorkspaceDisplayItemRecord(kind: .split, id: splitID)],
            splitGroups: [WorkspaceSplitGroupRecord(
                id: splitID, paneSessionIDs: [left.id, right.id], activeSessionID: left.id, widthWeights: [0.3, 0.7]
            )],
            selectedSessionID: right.id,
            collapsedAgentGroupIDs: [parent.id]
        )]
    ))
    let chromeState = ProjectWindowChromeState()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] }
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace

    #expect(workspace.sessions.map(\.id) == [left.id, parent.id, child.id, orphan.id, right.id])
    let tree = workspace.agentSessionTreeSnapshot()
    #expect(tree.roots.map(\.id) == [parent.id, orphan.id])
    #expect(tree.children(of: try #require(workspace.session(withID: parent.id))).map(\.id) == [child.id])
    #expect(chromeState.collapsedAgentGroupIDs == [parent.id])
    #expect(workspace.terminalSplitGroups.map(\.paneSessionIDs) == [[left.id, right.id]])
    #expect(abs((workspace.terminalSplitGroups.first?.widthWeights.first ?? 0) - 0.3) < 0.0001)
    #expect(workspace.terminalDisplayItems == [.split(splitID)])
    #expect(workspace.selectedSessionID == right.id)
    #expect(workspace.sessions.allSatisfy { $0.isPersistentLocalSession })
    #expect(harness.creates().isEmpty)
    #expect(await harness.fake.wait(timeout: 5) { harness.attachCalls.count == 5 })
}

// MARK: - Duplicates

@Test @MainActor func aHostSessionComesBackInOneTabAcrossWindowsAndWorktrees() async throws {
    let harness = try PersistentHarness()
    let windowA = harness.workspace()
    let windowB = harness.workspace()
    let windowC = harness.workspace()
    defer {
        [windowA, windowB, windowC].forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    let project = harness.project.path
    let owner = localRecord(title: "Server", sessionID: "s-shared", workingDirectory: project)
    harness.fake.sessions = [HostedSessionInfo(
        id: "s-shared", name: "Server", cwd: project, pid: 90, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: owner.id.uuidString]
    )]
    // Two records of one worktree naming one session: one tab.
    var copy = owner
    copy.id = UUID()
    let first = await harness.restore([owner, copy], into: windowA)
    #expect(first.sessions.map(\.id) == [owner.id])
    windowA.restoreSessions(first.sessions, from: WorktreeStateRecord(root: project, sessions: [owner, copy]))
    // Another window (or worktree) saved the same tab, or another owner
    // record for it: never a second tab owning the session.
    #expect(await harness.restore([owner], into: windowB).sessions.isEmpty)
    var otherOwner = owner
    otherOwner.id = UUID()
    #expect(await harness.restore([otherOwner], into: windowB).sessions.isEmpty)
    // Adopting by tag never takes a session a tab owns either.
    var unboundCopy = owner
    unboundCopy.hosted = nil
    #expect(await harness.restore([], unbound: [unboundCopy], into: windowB).sessions.isEmpty)
    // A tab that was only attached to it (a viewer) comes back attached.
    let viewer = localRecord(title: "Viewer", sessionID: "s-shared", owned: false, workingDirectory: project)
    let viewers = await harness.restore([viewer], into: windowC).sessions
    #expect(viewers.map(\.id) == [viewer.id])
    #expect(viewers.first?.hostedAttachment?.sessionID == "s-shared")
    windowC.restoreSessions(viewers, from: WorktreeStateRecord(root: project, sessions: [viewer]))
    // ...and never twice with its tab id.
    #expect(await harness.restore([viewer], into: harness.workspace()).sessions.isEmpty)
    #expect(harness.hosting.owningTab(of: "s-shared")?.id == owner.id)
}

// MARK: - Unreachable local host

@Test @MainActor func tabsKeptWhileThisMacsHostIsUnreachableComeBackWhenItIsUp() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-retry")
    let storeDirectory = try canonicalDirectory("cherry-restore-retry-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = localRecord(title: "Editor", sessionID: "s-editor", workingDirectory: root.path)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: root.path)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [editor, server], selectedSessionID: editor.id)]
    ))
    harness.fake.launchFailure = "cherry-host did not start"
    let command = ProjectCommandDefinition(name: "server", command: "serve", autoStart: true)
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [command] }
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    repository.autoStartInitialCommandsIfNeeded()
    let workspace = repository.activeWorkspace

    // Nothing could come back: the window opens its default shell, the
    // records stay saved, and the kept command does not start a second copy.
    #expect(workspace.sessions.map(\.title) == ["Shell 1"])
    #expect(workspace.commandSessions.isEmpty)
    let shell = try #require(workspace.sessions.first)
    // The failed list told the host is down: the default shell runs
    // natively at once instead of waiting for a Create that cannot work.
    #expect(!shell.isPersistentLocalSession)
    #expect(harness.status.localSessionsUnavailableReason != nil)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.map(\.id) == [shell.id, editor.id, server.id])

    // The host comes up (a new tab, the sheet or a warm-up reached it):
    // the kept tabs come back after the tabs opened meanwhile (as they were
    // saved), the selection stays, and the command is not started twice.
    harness.fake.launchFailure = nil
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-editor", name: "Editor", cwd: root.path, pid: 91, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: editor.id.uuidString]),
        HostedSessionInfo(id: "s-server", name: "server", cwd: root.path, pid: 92, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: server.id.uuidString])
    ]
    workspace.select(shell)
    _ = try await harness.control.connect()
    #expect(await harness.fake.wait { workspace.sessions.count == 3 })
    await repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.id) == [shell.id, editor.id, server.id])
    #expect(workspace.terminalDisplayItems == [.single(shell.id), .single(editor.id)])
    #expect(workspace.selectedSessionID == shell.id)
    #expect(workspace.commandSessions.map(\.id) == [server.id])
    #expect(workspace.session(withID: server.id)?.isRunning == true)
    #expect(await harness.fake.wait { harness.attached("s-editor") && harness.attached("s-server") })
    try await Task.sleep(for: .milliseconds(200))
    // Nothing was started for the tabs that came back.
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
    repository.flushPersistentState()
    let restored = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(restored.sessions.map(\.id) == [shell.id, editor.id, server.id])
    #expect(restored.sessions.first { $0.id == server.id }?.hosted?.sessionID == "s-server")
}

// MARK: - Auto-start

@Test @MainActor func autoStartNeverDuplicatesARestoredCommandAndRestartsEndedOnesByTheirPolicy() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-autostart-hosted")
    let storeDirectory = try canonicalDirectory("cherry-restore-autostart-hosted-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    // Running while Cherry was closed; an auto-start command.
    let web = localRecord(kind: .command, title: "web", sessionID: "s-web", commandName: "web", workingDirectory: root.path)
    // Ended while Cherry was closed, and restarts when it exits.
    let worker = localRecord(
        kind: .command, title: "worker", sessionID: "s-worker", commandName: "worker", restartOnExit: true,
        workingDirectory: root.path
    )
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-web", name: "web", cwd: root.path, pid: 93, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: web.id.uuidString]),
        HostedSessionInfo(id: "s-worker", name: "worker", cwd: root.path, state: .exited, exitCode: 1, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: worker.id.uuidString])
    ]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [web, worker])]
    ))
    let commands = [
        ProjectCommandDefinition(name: "web", command: "serve", autoStart: true),
        ProjectCommandDefinition(name: "worker", command: "work", autoRestart: true)
    ]
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in commands.filter(\.autoStart) }
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.autoStartInitialCommandsIfNeeded()
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    let webTab = try #require(workspace.session(withID: web.id))
    let workerTab = try #require(workspace.session(withID: worker.id))

    // Auto-start found the running command's restored tab: nothing new,
    // nothing ended, its program kept.
    #expect(workspace.commandSessions.map(\.id) == [web.id, worker.id])
    #expect(webTab.isRunning)
    #expect(webTab.persistentSession?.sessionID == "s-web")
    // The ended one restarts by its policy, in the same tab and a new
    // session; the ended session is removed.
    // (The new binding arrives with the Create answer, after the request.)
    #expect(await harness.fake.wait(timeout: 8) {
        harness.creates().count == 1 && workerTab.isRunning
            && workerTab.persistentSession.map { $0.sessionID != "s-worker" } == true
    })
    #expect(harness.creates().first.flatMap { $0.json["tags"] as? [String: String] }?[PersistentSessionTag.tab] == worker.id.uuidString)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains("s-worker") })
    #expect(!harness.requestIDs("kill").contains("s-web"))
    #expect(workspace.commandSessions.count == 2)
}

// MARK: - SSH hosts

@Test @MainActor func restoringAnSSHHostsSessionsAttachesThemWithTheirMetadataOrKeepsThem() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let remote = FakeControlHelper()
    remote.hostID = "host-ssh"
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    let control = try harness.sshControl(remote, hostStore: hostStore)
    let devbox = try HostedSessionHost.ssh("devbox")
    // The fake adapter answers as the SSH host.
    try harness.cli.write("host-id", "host-ssh")
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        control.disconnect()
        harness.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let tail = sshRecord(kind: .command, title: "tail", sessionID: "r-tail", commandName: "tail")
    let agent = sshRecord(kind: .agent, title: "Claude", sessionID: "r-agent", agentName: "Claude")
    let ending = sshRecord(title: "Ending", sessionID: "r-ending")
    let ended = sshRecord(title: "Done", sessionID: "r-done")
    let missing = sshRecord(title: "Gone", sessionID: "r-gone")
    let otherHost = sshRecord(title: "Reinstalled", sessionID: "r-tail", hostID: "host-old")
    remote.sessions = [
        hostedSession("r-tail", name: "tail"),
        hostedSession("r-agent", name: "Claude"),
        hostedSession("r-ending", name: "Ending"),
        hostedSession("r-done", name: "Done", state: .exited, pid: nil, exitCode: 2)
    ]
    remote.screenText = "all done"
    let result = await harness.restore(
        [tail, agent, ending, ended, missing, otherHost], into: workspace, control: { _ in control }
    )
    #expect(result.keptRecordIDs.isEmpty)
    #expect(result.sessions.map(\.id) == [tail.id, agent.id, ending.id, ended.id])
    // No local record: This Mac's host was never asked.
    #expect(harness.fake.launches.isEmpty)
    let tabs = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0) })
    let tailTab = try #require(tabs[tail.id])
    let agentTab = try #require(tabs[agent.id])
    let endingTab = try #require(tabs[ending.id])
    let doneTab = try #require(tabs[ended.id])
    #expect(tailTab.hostedAttachment?.host == devbox)
    #expect(tailTab.hostedAttachment?.hostID == "host-ssh")
    #expect(tailTab.hostedAttachment?.executablePath == harness.cli.executable.path)
    #expect(tailTab.hostedAttachment?.environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    #expect(tailTab.kind == .command)
    #expect(tailTab.commandName == "tail")
    #expect(agentTab.kind == .agent)
    #expect(agentTab.agentName == "Claude")
    #expect(tailTab.isAwaitingDeferredLaunch)
    #expect(tailTab.hostedProgramProcessID == nil)
    // Ended: "Session ended (exit 2)" with Remove from Host and Close Tab,
    // its final screen, and no adapter.
    #expect(doneTab.state == .exited(2))
    #expect(doneTab.hostedAttachmentStatus == .exited(code: 2, signal: nil))
    #expect(HostedConnectionBarState(
        isRunning: doneTab.isRunning, status: doneTab.hostedAttachmentStatus, removedFromHost: false, canClose: true
    ) == HostedConnectionBarState(isRunning: false, status: .exited(code: 2, signal: nil), removedFromHost: false, canClose: true))
    #expect(doneTab.hostedAttachmentStatus?.summary == "Session ended (exit 2)")
    #expect(await harness.fake.wait { doneTab.snapshot(range: 0..<doneTab.lineCount).contains("all done") })

    // Before its adapter attaches, a tab hears its session's events.
    let bells = Recorder(0)
    agentTab.bellHandler = { _ in bells.value += 1 }
    let events = try #require(remote.connections.last { !$0.isClosed })
    events.push(.event(.bell(id: "r-agent")))
    events.push(.event(.exited(id: "r-ending", exitCode: 130, signal: 2)))
    #expect(await harness.fake.wait { bells.value == 1 && endingTab.state == .exited(130) })
    #expect(endingTab.hostedAttachmentStatus?.summary == "Session ended (signal 2)")
    #expect(!endingTab.isAwaitingDeferredLaunch)

    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: harness.project.path, sessions: [tail, agent, ending, ended]
    ))
    #expect(await harness.fake.wait { harness.attached("r-tail") && harness.attached("r-agent") })
    #expect(harness.attachCalls.allSatisfy { $0.contains("--host devbox") })
    #expect(!harness.attached("r-ending"))
    #expect(!harness.attached("r-done"))
    #expect(tailTab.state == .live)

    // Unreachable, or answering as another host: the records stay saved.
    control.disconnect()
    remote.launchFailure = "ssh: Could not resolve hostname devbox"
    let unreachable = await harness.restore([missing], into: harness.workspace(), control: { _ in control })
    #expect(unreachable.sessions.isEmpty)
    #expect(unreachable.keptRecordIDs == [missing.id])
    #expect(unreachable.retryWhenAvailable == nil)
    remote.launchFailure = nil
    remote.hostID = "host-impostor"
    let impostor = await harness.restore([missing], into: harness.workspace(), control: { _ in control })
    #expect(impostor.sessions.isEmpty)
    #expect(impostor.keptRecordIDs == [missing.id])
}

// MARK: - Slow and restarted hosts

/// Holds restores until the test opens it.
@MainActor
private final class RestorerGate {
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

private func repositoryKey(_ root: URL) -> String {
    URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
}

@Test @MainActor func aSlowSSHHostNeverHoldsUpThisMacsTabs() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-slow-host")
    let storeDirectory = try canonicalDirectory("cherry-restore-slow-host-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let remote = FakeControlHelper()
    remote.hostID = "host-ssh"
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    let control = try harness.sshControl(remote, hostStore: hostStore)
    try harness.cli.write("host-id", "host-ssh")
    // The SSH host does not answer its first list until the test says so.
    let held = FakeHeldRequest()
    let holdNext = FakeCountdown(1)
    remote.respond = { @Sendable request, connection in
        guard request.op == "list", holdNext.take() else { return nil }
        return held.hold(request, on: connection)
    }
    let logs = sshRecord(title: "Logs", sessionID: "r-logs")
    let editor = localRecord(title: "Editor", sessionID: "s-editor", workingDirectory: root.path)
    remote.sessions = [hostedSession("r-logs", name: "Logs")]
    harness.fake.sessions = [HostedSessionInfo(
        id: "s-editor", name: "Editor", cwd: root.path, pid: 95, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: editor.id.uuidString]
    )]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [logs, editor], selectedSessionID: logs.id)]
    ))
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: WorkspaceSessionRestorers.hostedByDefault(
            localSessions: harness.hosting, control: { _ in control }, initialWait: .milliseconds(200)
        ),
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        held.answer(.sessions(HostedSessionList(hostID: "host-ssh", sessions: [])))
        repository.closeAllSessions(intent: .windowClosed)
        control.disconnect()
        harness.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    let workspace = repository.activeWorkspace

    // This Mac's tab comes back while the SSH host has not answered.
    #expect(await harness.fake.wait { workspace.sessions.map(\.id) == [editor.id] })
    #expect(held.isHeld)
    #expect(workspace.selectedSessionID == editor.id)
    #expect(await harness.fake.wait { harness.attached("s-editor") })
    // The tab still being restored stays saved meanwhile.
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)?.sessions.map(\.id)
        == [editor.id, logs.id])

    // The SSH host answers: its tab comes after the others and takes the
    // saved selection, which nobody changed meanwhile.
    held.answer(.sessions(HostedSessionList(hostID: "host-ssh", sessions: remote.sessions)))
    #expect(await harness.fake.wait { workspace.sessions.count == 2 })
    await repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.id) == [editor.id, logs.id])
    #expect(workspace.terminalDisplayItems == [.single(editor.id), .single(logs.id)])
    #expect(workspace.selectedSessionID == logs.id)
    #expect(workspace.session(withID: logs.id)?.hostedAttachment?.hostID == "host-ssh")
    #expect(await harness.fake.wait { harness.attached("r-logs") })
    #expect(!workspace.sessions.contains { $0.title == "Shell 1" })
}

@Test @MainActor func aWindowWhoseTabsAreAllOnAnUnreachableHostAutoStartsAndOpensItsShellWhenItGivesUp() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-unreachable-ssh")
    let storeDirectory = try canonicalDirectory("cherry-restore-unreachable-ssh-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let remote = FakeControlHelper()
    remote.hostID = "host-ssh"
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    let control = try harness.sshControl(remote, hostStore: hostStore)
    let held = FakeHeldRequest()
    remote.respond = { @Sendable request, connection in
        request.op == "list" ? held.hold(request, on: connection) : nil
    }
    let logs = sshRecord(title: "Logs", sessionID: "r-logs")
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [logs], selectedSessionID: logs.id)]
    ))
    let web = ProjectCommandDefinition(name: "web", command: "serve", autoStart: true)
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: WorkspaceSessionRestorers.hostedByDefault(
            localSessions: harness.hosting, control: { _ in control }, initialWait: .milliseconds(200)
        ),
        autoStartCommands: { _ in [web] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        control.disconnect()
        harness.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    repository.autoStartInitialCommandsIfNeeded()
    let workspace = repository.activeWorkspace

    // Auto-start does not wait for the SSH host; the default shell does,
    // since the tabs may still come back.
    #expect(await harness.fake.wait { workspace.commandSessions.map(\.commandName) == ["web"] })
    #expect(held.isHeld)
    #expect(workspace.sessions.map(\.kind) == [.command])

    // The SSH host cannot be reached after all: its tab stays saved for the
    // next launch, and the window opens its default shell.
    remote.dropAll(stderr: "ssh: connect to host devbox port 22: Operation timed out")
    await repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.title) == ["Shell 1", "web"])
    #expect(workspace.selectedSession?.title == "Shell 1")
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.last == logs)
}

@Test @MainActor func aSessionMissingFromTheFirstListIsLookedForAgainBeforeItsTabIsDropped() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.disappearanceConfirmationDelay = .seconds(1)
    let harness = try PersistentHarness(configuration: configuration)
    let root = try canonicalDirectory("cherry-restore-late-holder")
    let storeDirectory = try canonicalDirectory("cherry-restore-late-holder-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = localRecord(title: "Editor", sessionID: "s-editor", workingDirectory: root.path)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: root.path)
    let gone = localRecord(title: "Gone", sessionID: "s-gone", workingDirectory: root.path)
    func info(_ record: WorkspaceSessionRecord, pid: UInt32) -> HostedSessionInfo {
        HostedSessionInfo(id: record.hosted!.sessionID, name: record.title, cwd: root.path, pid: pid, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    // A daemon that just restarted: the server's holder has not registered
    // again yet.
    harness.fake.sessions = [info(editor, pid: 96)]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [editor, server, gone])]
    ))
    let command = ProjectCommandDefinition(name: "server", command: "serve", autoStart: true)
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [command] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    repository.autoStartInitialCommandsIfNeeded()
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { workspace.sessions.map(\.id) == [editor.id] })
    // The command's tab may still come back: auto-start and MCP or sidebar
    // starts wait for it rather than start a second server.
    #expect(workspace.isRestoringCommand(named: "Server"))
    #expect(workspace.commandSessions.isEmpty)

    // Its holder registers; the second look finds it.
    harness.fake.sessions = [info(editor, pid: 96), info(server, pid: 97)]
    await repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.id) == [editor.id, server.id])
    #expect(workspace.commandSessions.first?.persistentSession?.sessionID == "s-server")
    #expect(!workspace.isRestoringCommand(named: "server"))
    #expect(harness.creates().isEmpty)
    // A session missing from both lists is gone: its tab is dropped.
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)?.sessions.map(\.id)
        == [editor.id, server.id])
}

// MARK: - Commands started while a restore runs

@Test @MainActor func aCommandStartedWhileItsTabIsBeingRestoredGetsThatTab() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-start-pending")
    let storeDirectory = try canonicalDirectory("cherry-restore-start-pending-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: root.path)
    let worker = localRecord(kind: .command, title: "worker", sessionID: "s-worker", commandName: "worker", workingDirectory: root.path)
    harness.fake.sessions = [server, worker].map { record in
        HostedSessionInfo(id: record.hosted!.sessionID, name: record.title, cwd: root.path, pid: 98, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [server, worker])]
    ))
    let gate = RestorerGate()
    let restorer = harness.restorer
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: { request in
            await gate.wait()
            return await restorer(request)
        },
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        gate.open()
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { gate.waiting == 1 })
    let workspace = repository.activeWorkspace
    #expect(workspace.isRestoringCommand(named: "server"))
    #expect(workspace.isRestoringCommand(named: nil))

    // A start (sidebar, MCP spawn_process or start_process) waits for the
    // restore, then gets the restored tab.
    let serverDefinition = ProjectCommandDefinition(name: "server", command: "serve")
    let start = Task { @MainActor in
        await workspace.waitUntilRestored(commandNamed: "server")
        return workspace.addCommandSession(command: serverDefinition, projectRoot: root.path, select: false)
    }
    // One that did not wait (it gave up waiting): a second worker starts.
    let secondWorker = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "worker", command: "work"), projectRoot: root.path, select: false
    )
    #expect(await harness.waitUntilAttached(secondWorker))
    try await Task.sleep(for: .milliseconds(50))
    #expect(workspace.commandSessions.map(\.id) == [secondWorker.id])

    gate.open()
    let started = await start.value
    await repository.waitForPendingRestores()
    #expect(started.id == server.id)
    #expect(started.persistentSession?.sessionID == "s-server")
    #expect(harness.creates().count == 1)
    // The restored worker meets the one started meanwhile, whose program
    // runs: the new one keeps the command, and the restored one is set
    // aside, its program never ended and its record still saved.
    #expect(workspace.commandSessions.map(\.id) == [server.id, secondWorker.id])
    #expect(workspace.session(withID: worker.id) == nil)
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.hosting.owningTab(of: "s-worker") == nil)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(Set(saved.sessions.map(\.id)) == [server.id, secondWorker.id, worker.id])
    #expect(saved.sessions.first { $0.id == worker.id }?.hosted?.sessionID == "s-worker")
}

@Test @MainActor func aRestoredCommandWhoseProgramRunsReplacesACommandTabWhoseProgramDoesNot() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    // A second copy started while the restore ran, and failed (its port
    // was taken by the copy the restored tab follows).
    let failed = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "web", command: "serve"), projectRoot: project, select: true
    )
    #expect(await harness.waitUntilAttached(failed))
    let failedSession = try #require(failed.persistentSession?.sessionID)
    harness.exit(failedSession, code: 1)
    #expect(await harness.fake.wait { !failed.isRunning })

    let web = localRecord(kind: .command, title: "web", sessionID: "s-web", commandName: "web", workingDirectory: project)
    harness.fake.sessions.append(HostedSessionInfo(
        id: "s-web", name: "web", cwd: project, pid: 99, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: web.id.uuidString]
    ))
    let result = await harness.restore([web], into: workspace)
    let setAside = workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(root: project, sessions: [web]))
    #expect(setAside.isEmpty)
    #expect(workspace.commandSessions.map(\.id) == [web.id])
    #expect(workspace.session(withID: failed.id) == nil)
    #expect(workspace.selectedSessionID == web.id)
    // The failed tab's ended session goes, as when a user closes it; the
    // restored program runs on.
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(failedSession) })
    #expect(!harness.requestIDs("kill").contains("s-web"))
}

// MARK: - Host availability

@Test @MainActor func keptTabsRetryWhenTheHostCameUpBeforeAnyoneListenedAndSlowlyOnALiveConnection() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.restoreRetryDelay = 0.3
    let harness = try PersistentHarness(configuration: configuration)
    defer { harness.cleanUp() }
    var subscriptions: [AnyCancellable] = []

    // The list fails: the host is down.
    harness.fake.launchFailure = "cherry-host did not start"
    let generation = harness.hosting.connectionGeneration
    await #expect(throws: (any Error).self) { _ = try await harness.hosting.list() }
    // It comes up before the restore listens: the retry still fires.
    harness.fake.launchFailure = nil
    _ = try await harness.control.connect()
    let cameUp = Recorder(false)
    subscriptions.append(harness.hosting.hostAvailability(after: generation).sink { cameUp.value = true })
    #expect(await harness.fake.wait { cameUp.value })

    // A list that failed on a connection that stays up is retried only
    // after `restoreRetryDelay`, never in a tight loop.
    let live = harness.hosting.connectionGeneration
    let subscribedAt = Date()
    let retriedAt = Recorder<Date?>(nil)
    subscriptions.append(harness.hosting.hostAvailability(after: live).sink { retriedAt.value = Date() })
    #expect(retriedAt.value == nil)
    #expect(await harness.fake.wait { retriedAt.value != nil })
    #expect((retriedAt.value?.timeIntervalSince(subscribedAt) ?? 0) >= 0.25)
    subscriptions.removeAll()
}

// MARK: - Worktrees

private func runGit(_ arguments: [String]) throws {
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

@Test @MainActor func onlyTheShownWorktreeAttachesItsTabsAndRemovingOneStillRestoringAsksFirst() async throws {
    let harness = try PersistentHarness()
    let container = try canonicalDirectory("cherry-restore-worktree-attach")
    let root = container.appendingPathComponent("repo", isDirectory: true)
    let feature = container.appendingPathComponent("feature", isDirectory: true)
    let other = container.appendingPathComponent("other", isDirectory: true)
    let storeDirectory = container.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["-C", root.path, "init", "-b", "main"])
    try runGit(["-C", root.path, "-c", "user.name=Cherry Tests", "-c", "user.email=cherry@example.invalid",
                "commit", "--allow-empty", "-m", "Initial"])
    try runGit(["-C", root.path, "worktree", "add", "-b", "feature", feature.path])
    try runGit(["-C", root.path, "worktree", "add", "-b", "other", other.path])
    let settings = TerminalSettings.shared
    let previousWorktreeSpacesEnabled = settings.worktreeSpacesEnabled
    settings.worktreeSpacesEnabled = true

    let store = WorkspaceStateStore(directory: storeDirectory)
    let main = localRecord(title: "Main", sessionID: "s-main", workingDirectory: root.path)
    let featureTab = localRecord(title: "Feature", sessionID: "s-feature", workingDirectory: feature.path)
    let otherTab = localRecord(kind: .command, title: "server", sessionID: "s-other", commandName: "server", workingDirectory: other.path)
    harness.fake.sessions = [main, featureTab, otherTab].map { record in
        HostedSessionInfo(id: record.hosted!.sessionID, name: record.title, cwd: record.workingDirectory, pid: 100,
                          owner: "CherryTests", tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [
            WorktreeStateRecord(root: root.path, sessions: [main]),
            WorktreeStateRecord(root: feature.path, sessions: [featureTab]),
            WorktreeStateRecord(root: other.path, sessions: [otherTab])
        ]
    ))
    let gate = RestorerGate()
    let restorer = harness.restorer
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: { request in
            if request.worktreeRoot == other.path { await gate.wait() }
            return await restorer(request)
        },
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        gate.open()
        repository.closeAllSessions(intent: .windowClosed)
        settings.worktreeSpacesEnabled = previousWorktreeSpacesEnabled
        harness.cleanUp()
        try? FileManager.default.removeItem(at: container)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    #expect(await harness.fake.wait { harness.attached("s-main") })

    // Discovery restores the other worktrees; a worktree not shown gets its
    // tabs back (following their programs) but builds no surface yet.
    await repository.refresh()
    #expect(await harness.fake.wait { repository.workspaceIfLoaded(for: feature.path)?.sessions.count == 1 })
    let restoredFeature = try #require(repository.workspaceIfLoaded(for: feature.path)?.sessions.first)
    try await Task.sleep(for: .milliseconds(200))
    #expect(restoredFeature.isAwaitingDeferredLaunch)
    #expect(restoredFeature.isRunning)
    #expect(!harness.attached("s-feature"))
    // Shown: its tabs attach.
    repository.activate(worktreeRoot: feature.path, chromeState: nil)
    #expect(await harness.fake.wait { harness.attached("s-feature") })

    // A worktree whose restore still runs: its tabs count as running, so a
    // removal that did not confirm them is refused, and nothing is ended.
    #expect(gate.waiting == 1)
    let otherWorktree = try #require(repository.worktrees.first { $0.root == other.path })
    #expect(await repository.removalBlockers(for: otherWorktree).runningProcessCount == 1)
    await #expect(throws: GitWorktreeCommandError.self) {
        try await repository.remove(otherWorktree, chromeState: nil)
    }
    #expect(repository.workspaceIfLoaded(for: other.path) != nil)
    #expect(harness.fake.requests("kill").isEmpty)
    gate.open()
    await repository.waitForPendingRestores()
    #expect(repository.workspaceIfLoaded(for: other.path)?.commandSessions.map(\.id) == [otherTab.id])
}

@Test @MainActor func aRetryThatFiresAsItIsSubscribedCanKeepAndRetryAgain() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-retry-at-once")
    let storeDirectory = try canonicalDirectory("cherry-restore-retry-at-once-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: root.path)
    harness.fake.sessions = [HostedSessionInfo(
        id: "s-server", name: "server", cwd: root.path, pid: 101, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: server.id.uuidString]
    )]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [server])]
    ))
    // The first restore keeps the tab and its host is up already (the
    // retry fires as it is subscribed); the retry keeps it again, until
    // the host comes up once more.
    let calls = Recorder(0)
    let secondTrigger = PassthroughSubject<Void, Never>()
    let restorer = harness.restorer
    let command = ProjectCommandDefinition(name: "server", command: "serve", autoStart: true)
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: { request in
            calls.value += 1
            switch calls.value {
            case 1: return WorkspaceRestoreResult(
                keptRecordIDs: Set(request.records.map(\.id)), retryWhenAvailable: Just(()).eraseToAnyPublisher()
            )
            case 2: return WorkspaceRestoreResult(
                keptRecordIDs: Set(request.records.map(\.id)), retryWhenAvailable: secondTrigger.first().eraseToAnyPublisher()
            )
            default: return await restorer(request)
            }
        },
        autoStartCommands: { _ in [command] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    repository.autoStartInitialCommandsIfNeeded()
    let workspace = repository.activeWorkspace
    #expect(await harness.fake.wait { calls.value == 2 })
    await repository.waitForPendingRestores()
    // Kept twice: the command waits for its tab, nothing started for it
    // (only the window's default shell).
    let createdKinds = { harness.creates().compactMap { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.kind] } }
    #expect(workspace.commandSessions.isEmpty)
    #expect(createdKinds() == ["terminal"])

    secondTrigger.send()
    #expect(await harness.fake.wait { calls.value == 3 })
    await repository.waitForPendingRestores()
    #expect(workspace.commandSessions.map(\.id) == [server.id])
    #expect(workspace.commandSessions.first?.persistentSession?.sessionID == "s-server")
    #expect(createdKinds() == ["terminal"])
}

// MARK: - Holders a restarted daemon still expects

@Test @MainActor func aRestartedDaemonIsListedUntilItsHoldersRegisteredBeforeMissingTabsAreDropped() async throws {
    var configuration = PersistentHarness.fastConfiguration
    // Never waited for: this host reports the holders it still expects.
    configuration.disappearanceConfirmationDelay = .seconds(30)
    configuration.pendingHoldersPollInterval = .milliseconds(50)
    configuration.pendingHoldersWait = .seconds(5)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let editor = localRecord(title: "Editor", sessionID: "s-editor", workingDirectory: project)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: project)
    let gone = localRecord(title: "Gone", sessionID: "s-gone", workingDirectory: project)
    func info(_ record: WorkspaceSessionRecord, pid: UInt32) -> HostedSessionInfo {
        HostedSessionInfo(id: record.hosted!.sessionID, name: record.title, cwd: project, pid: pid, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: record.id.uuidString])
    }
    // Only the editor's holder registered again so far.
    harness.fake.sessions = [info(editor, pid: 96)]
    harness.fake.pendingHolders = 1

    let started = ContinuousClock.now
    let result = await harness.restore([editor, server, gone], into: workspace)
    #expect(result.sessions.map(\.id) == [editor.id])
    #expect(result.pendingRecordIDs == [server.id, gone.id])
    #expect(result.keptRecordIDs.isEmpty)
    let remainder = try #require(result.remainder)
    #expect(await harness.fake.wait { harness.fake.requests("list").count >= 3 })

    // The server's holder registers; nothing else is expected.
    harness.fake.sessions = [info(editor, pid: 96), info(server, pid: 97)]
    harness.fake.pendingHolders = 0
    let rest = await remainder.value
    #expect(rest.sessions.map(\.id) == [server.id])
    #expect(rest.sessions.first?.persistentSession?.sessionID == "s-server")
    // A session missing from the complete list is gone: its tab is dropped
    // (nothing says the system ended it).
    #expect(rest.keptRecordIDs.isEmpty)
    #expect(rest.pendingRecordIDs.isEmpty)
    #expect(ContinuousClock.now - started < .seconds(10))
    WorkspaceRestoreResult.discard(result, in: workspace)
}

@Test @MainActor func aCompleteListDropsMissingTabsAtOnceAndHoldersThatNeverCameBackKeepThem() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.disappearanceConfirmationDelay = .seconds(30)
    configuration.pendingHoldersPollInterval = .milliseconds(20)
    configuration.pendingHoldersWait = .milliseconds(300)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let gone = localRecord(title: "Gone", sessionID: "s-gone", workingDirectory: project)
    var fresh = localRecord(title: "Fresh", sessionID: nil, workingDirectory: project)
    fresh.launchRequestID = UUID().uuidString.lowercased()

    // Complete: no second look. Nothing says the system ended these
    // sessions (a normal relaunch: no `systemEnds`), so they are dropped;
    // see aLogOutOrALostHolderBringsTabsBackOnlyOnceNothingMoreIsComing.
    harness.fake.pendingHolders = 0
    let complete = await harness.restore([gone], unbound: [fresh], into: workspace)
    #expect(complete.sessions.isEmpty)
    #expect(complete.pendingRecordIDs.isEmpty)
    #expect(complete.remainder == nil)
    #expect(complete.keptRecordIDs.isEmpty)

    // Holders still expected when the wait runs out: kept for the next
    // launch (a tab whose Create was under way too), not dropped, and
    // restored again during this run once the host expects none.
    harness.fake.pendingHolders = 2
    let incomplete = await harness.restore([gone], unbound: [fresh], into: workspace)
    #expect(incomplete.pendingRecordIDs == [gone.id, fresh.id])
    let remainder = try #require(incomplete.remainder)
    let rest = await remainder.value
    #expect(rest.sessions.isEmpty)
    #expect(rest.keptRecordIDs == [gone.id, fresh.id])
    let retry = try #require(rest.retryWhenAvailable)
    let fired = Recorder(0)
    let subscription = retry.sink { fired.value += 1 }
    defer { subscription.cancel() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(fired.value == 0)
    harness.fake.pendingHolders = 0
    #expect(await harness.fake.wait { fired.value == 1 })
}

@Test @MainActor func autoStartWaitsForCommandsWhoseHoldersARestartedDaemonStillExpectsUntilItExpectsNone() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.disappearanceConfirmationDelay = .seconds(30)
    configuration.pendingHoldersPollInterval = .milliseconds(20)
    configuration.pendingHoldersWait = .milliseconds(300)
    let harness = try PersistentHarness(configuration: configuration)
    let root = try canonicalDirectory("cherry-restore-holders-retry")
    let storeDirectory = try canonicalDirectory("cherry-restore-holders-retry-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let server = localRecord(kind: .command, title: "server", sessionID: "s-server", commandName: "server", workingDirectory: root.path)
    let worker = localRecord(kind: .command, title: "worker", sessionID: "s-worker", commandName: "worker", workingDirectory: root.path)
    // Saved while its Create was under way.
    var fresh = localRecord(title: "Fresh", sessionID: nil, workingDirectory: root.path)
    fresh.launchRequestID = UUID().uuidString.lowercased()
    // The daemon restarted; no holder registered again yet, and the host
    // still expects them after the restore's wait.
    harness.fake.pendingHolders = 3
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [server, worker, fresh])]
    ))
    let commands = ["server", "worker"].map { ProjectCommandDefinition(name: $0, command: "serve-\($0)", autoStart: true) }
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in commands },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    repository.autoStartInitialCommandsIfNeeded()
    let workspace = repository.activeWorkspace
    await repository.waitForPendingRestores()
    let createdKinds = { harness.creates().compactMap { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.kind] } }
    // Kept: auto-start waits for the tabs instead of starting a second copy
    // of either command beside the one that may still run.
    try await Task.sleep(for: .milliseconds(300))
    #expect(workspace.commandSessions.isEmpty)
    #expect(!createdKinds().contains("command"))

    #expect(!workspace.sessions.contains { $0.id == fresh.id })

    // The server's and the fresh tab's holders register; the worker's is
    // gone, so the host expects none: those two tabs come back owning their
    // sessions, and only the worker starts again.
    harness.fake.sessions = [
        HostedSessionInfo(
            id: "s-server", name: "server", cwd: root.path, pid: 101, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: server.id.uuidString]
        ),
        HostedSessionInfo(id: "s-fresh", name: "Fresh", cwd: root.path, pid: 102, owner: "CherryTests", requestID: fresh.launchRequestID),
    ]
    harness.fake.pendingHolders = 0
    #expect(await harness.fake.wait { workspace.commandSessions.count == 2 })
    await repository.waitForPendingRestores()
    let restored = try #require(workspace.commandSessions.first { $0.id == server.id })
    #expect(restored.persistentSession?.sessionID == "s-server")
    let adopted = try #require(workspace.sessions.first { $0.id == fresh.id })
    #expect(adopted.persistentSession?.sessionID == "s-fresh")
    #expect(workspace.commandSessions.contains { $0.commandName == "worker" && $0.id != worker.id })
    #expect(createdKinds().filter { $0 == "command" }.count == 1)
}

// MARK: - Sessions found by their Create's request id

@Test @MainActor func restoringAdoptsTheSessionASavedCreateStartedBeforeItsBindingOrTag() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let newer = UUID().uuidString.lowercased()
    let lost = UUID().uuidString.lowercased()
    // A restart whose new binding was never saved: the old session ended,
    // and the one its saved Create started runs (without a tab tag).
    var restarted = localRecord(title: "Claude", sessionID: "s-old", workingDirectory: project)
    restarted.launchRequestID = newer
    // Saved before its Create answered.
    var unbound = localRecord(title: "Fresh", sessionID: nil, workingDirectory: project)
    unbound.launchRequestID = lost
    // Another app's session with the same request id is never adopted.
    var foreign = localRecord(title: "Theirs", sessionID: nil, workingDirectory: project)
    foreign.launchRequestID = UUID().uuidString.lowercased()
    harness.fake.pendingHolders = 0
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-old", name: "Claude", cwd: project, state: .exited, exitCode: 0, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: restarted.id.uuidString], requestID: UUID().uuidString.lowercased()),
        HostedSessionInfo(id: "s-new", name: "Claude", cwd: project, pid: 71, owner: "CherryTests", requestID: newer),
        HostedSessionInfo(id: "s-lost", name: "Fresh", cwd: project, pid: 72, owner: "CherryTests", requestID: lost),
        HostedSessionInfo(id: "s-theirs", name: "Theirs", cwd: project, pid: 73, owner: "Cherry Sessions",
                          requestID: foreign.launchRequestID),
    ]
    let result = await harness.restore([restarted], unbound: [unbound, foreign], into: workspace)
    #expect(result.sessions.map(\.id) == [restarted.id, unbound.id])
    let claude = try #require(result.sessions.first)
    #expect(claude.isPersistentLocalSession)
    #expect(claude.persistentSession?.sessionID == "s-new")
    #expect(claude.persistentLaunchRequestID == newer)
    let adopted = try #require(result.sessions.last)
    #expect(adopted.isPersistentLocalSession)
    #expect(adopted.persistentSession?.sessionID == "s-lost")
    // Saved again with both.
    let saved = WorkspaceSessionRecord(session: adopted, restoredRecord: unbound)
    #expect(saved.hosted?.sessionID == "s-lost")
    #expect(saved.launchRequestID == lost)
    // A host that does not report request ids: the `cherry.launch` tag.
    let tagged = HostedSessionInfo(
        id: "s", name: "n", cwd: "/", owner: "CherryTests", tags: [PersistentSessionTag.launch: newer.uppercased()]
    )
    #expect(PersistentLocalSessions.launchRequestID(of: tagged) == newer)
    #expect(PersistentLocalSessions.isLaunched(tagged, byRequest: newer, owner: "CherryTests"))
    #expect(!PersistentLocalSessions.isLaunched(tagged, byRequest: newer, owner: "Cherry"))
    WorkspaceRestoreResult.discard(result, in: workspace)
}

@Test @MainActor func aTabSavedWhileItsCreateWasUnderWayComesBackEvenAsItsWorktreesOnlyTab() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-request-id")
    let storeDirectory = try canonicalDirectory("cherry-restore-request-id-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    // A tab whose Create has not answered saves the request id it sent.
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let creating = TerminalWorkspace(projectRoot: root.path, createInitialSession: false, backendPolicy: harness.policy)
    let tab = creating.addSession(title: "Fresh")
    #expect(await harness.fake.wait { held.isHeld })
    let requestID = try #require(harness.creates().first?.string("request_id"))
    #expect(tab.persistentLaunchRequestID == requestID)
    let record = WorkspaceSessionRecord(session: tab, restoredRecord: nil)
    #expect(record.hosted == nil)
    #expect(record.launchRequestID == requestID)
    #expect(record.mayComeBack)
    // The host started it; Cherry quit (detaching it) before that record
    // was saved again, so the saved one has no binding.
    let lost = HostedSessionInfo(id: "s-lost", name: "Fresh", cwd: root.path, pid: 81, owner: "CherryTests", requestID: requestID)
    harness.fake.respond = nil
    harness.fake.sessions = [lost]
    harness.fake.pendingHolders = 0
    held.answer(.created(lost))
    #expect(await harness.waitUntilAttached(tab))
    #expect(tab.persistentLaunchRequestID == requestID)
    creating.closeAllSessions(intent: .appQuit)
    #expect(harness.fake.requests("kill").isEmpty)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [record], selectedSessionID: record.id)]
    ))

    // Relaunch: the worktree has no bound tab, yet the host is asked, and
    // the tab comes back owning that session instead of a new shell.
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
    #expect(await harness.fake.wait { workspace.sessions.map(\.id) == [record.id] })
    let restored = try #require(workspace.sessions.first)
    #expect(restored.isPersistentLocalSession)
    #expect(restored.persistentSession?.sessionID == "s-lost")
    #expect(harness.creates().count == 1)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path)?.sessions.first)
    #expect(saved.hosted?.sessionID == "s-lost")
    #expect(saved.launchRequestID == requestID)
}

// MARK: - Sessions the system ended

/// A chrome state whose toasts never go by themselves and reach no VoiceOver.
@MainActor
private func quietChromeState() -> ProjectWindowChromeState {
    ProjectWindowChromeState(toasts: ProjectWindowToasts(
        schedule: { _, _ in }, announce: { _ in }, voiceOverEnabled: { false }
    ))
}

/// Before This Mac's last boot: a state saved then was saved before a restart.
private func beforeTheLastBoot() throws -> Date {
    try #require(SystemEndedSessions.currentBootTime()).addingTimeInterval(-3_600)
}

@Test @MainActor func theSystemEndRuleTakesARestartALogOutOrALostHolderAndNothingElse() {
    let boot = Date(timeIntervalSince1970: 1_800_000_000.6)
    func end(savedAt: Date?, quits: [Date] = [], lost: Bool = false) -> SystemSessionEnd? {
        SystemEndedSessions.end(savedAt: savedAt, bootTime: boot, systemQuits: quits, lostByHost: lost)
    }
    // Saved before this boot: the Mac restarted (or shut down, crashed,
    // lost power) since, whatever else says so.
    #expect(end(savedAt: boot.addingTimeInterval(-60)) == .restart)
    #expect(end(savedAt: boot.addingTimeInterval(-60), quits: [boot.addingTimeInterval(-30)], lost: true) == .restart)
    // Saves keep whole seconds: one in the boot's second is not before it.
    #expect(end(savedAt: Date(timeIntervalSince1970: 1_800_000_000)) == nil)
    // Saved since: a quit for a log out after the save, even in its second.
    let saved = boot.addingTimeInterval(600)
    #expect(end(savedAt: saved, quits: [saved.addingTimeInterval(120)]) == .logout)
    #expect(end(savedAt: Date(timeIntervalSince1970: saved.timeIntervalSince1970.rounded(.down)),
                quits: [saved.addingTimeInterval(0.2)]) == .logout)
    // A quit before the save says nothing about the sessions it saved.
    #expect(end(savedAt: saved, quits: [saved.addingTimeInterval(-120)]) == nil)
    // The host found the holder killed.
    #expect(end(savedAt: saved, lost: true) == .logout)
    #expect(end(savedAt: nil, lost: true) == .logout)
    // Nothing says so: a normal relaunch, or a state that does not say when
    // it was saved.
    #expect(end(savedAt: saved) == nil)
    #expect(end(savedAt: nil, quits: [saved]) == nil)
    #expect(SystemEndedSessions.end(savedAt: saved, bootTime: nil, systemQuits: [], lostByHost: false) == nil)
    #expect(SystemEndedSessions.currentBootTime().map { $0 <= Date() } == true)
}

@Test @MainActor func aRebootBringsTabsBackEndedInTheirPlacesWithoutAShellAndRestartStartsEachKind() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-reboot")
    let storeDirectory = try canonicalDirectory("cherry-restore-reboot-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let elsewhere = try canonicalDirectory("cherry-restore-reboot-cwd")
    let left = localRecord(title: "Left", sessionID: "s-left", workingDirectory: elsewhere.path)
    let right = localRecord(title: "Right", sessionID: "s-right", workingDirectory: root.path)
    let lead = localRecord(kind: .agent, title: "Lead", sessionID: "s-lead", agentName: "Claude", workingDirectory: root.path)
    let helper = localRecord(
        kind: .agent, title: "Helper", sessionID: "s-helper", agentName: "Codex", parentAgentID: lead.id,
        workingDirectory: root.path
    )
    let web = localRecord(kind: .command, title: "web", sessionID: "s-web", commandName: "web", workingDirectory: root.path)
    // Still running: a session the restart did not end (another boot's
    // holder cannot be, but the rule is per tab).
    let live = localRecord(title: "Live", sessionID: "s-live", workingDirectory: root.path)
    harness.fake.sessions = [
        HostedSessionInfo(id: "s-live", name: "Live", cwd: root.path, pid: 70, owner: "CherryTests",
                          tags: [PersistentSessionTag.tab: live.id.uuidString])
    ]
    harness.fake.pendingHolders = 0
    let splitID = UUID()
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(
            root: root.path,
            sessions: [lead, left, helper, web, right, live],
            displayItems: [WorkspaceDisplayItemRecord(kind: .split, id: splitID), WorkspaceDisplayItemRecord(kind: .single, id: live.id)],
            splitGroups: [WorkspaceSplitGroupRecord(
                id: splitID, paneSessionIDs: [left.id, right.id], activeSessionID: right.id, widthWeights: [0.4, 0.6]
            )],
            selectedSessionID: right.id,
            collapsedAgentGroupIDs: [lead.id]
        )],
        savedAt: try beforeTheLastBoot()
    ))
    let chromeState = quietChromeState()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        [root, storeDirectory, elsewhere].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace

    // Every tab back in its place (no default shell), the split, the agent
    // tree and the selection too.
    #expect(workspace.sessions.map(\.id) == [lead.id, left.id, helper.id, web.id, right.id, live.id])
    #expect(workspace.terminalSplitGroups.map(\.paneSessionIDs) == [[left.id, right.id]])
    #expect(workspace.terminalDisplayItems == [.split(splitID), .single(live.id)])
    #expect(workspace.selectedSessionID == right.id)
    #expect(chromeState.collapsedAgentGroupIDs == [lead.id])
    let tree = workspace.agentSessionTreeSnapshot()
    #expect(tree.children(of: try #require(workspace.session(withID: lead.id))).map(\.id) == [helper.id])
    let ended = [lead, left, helper, web, right].map { workspace.session(withID: $0.id) }
    for (tab, record) in zip(ended, [lead, left, helper, web, right]) {
        let tab = try #require(tab)
        #expect(tab.systemSessionEnd == .restart)
        #expect(!tab.isRunning)
        #expect(tab.persistentSession == nil)
        #expect(tab.isPersistentLocalSession)
        #expect(tab.kind == record.kind)
        #expect(tab.title == record.title)
        #expect(tab.agentName == record.agentName)
        #expect(tab.commandName == record.commandName)
        #expect(tab.workingDirectory == record.workingDirectory)
        #expect(tab.persistentSessionEndedMessage == "Ended when the Mac restarted")
    }
    let liveTab = try #require(workspace.session(withID: live.id))
    #expect(liveTab.systemSessionEnd == nil)
    #expect(liveTab.persistentSession?.sessionID == "s-live")
    #expect(harness.creates().isEmpty)

    // One toast for the window.
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "5 tabs ended when the Mac restarted")
    #expect(toast.actions.map(\.title) == ["Restart All"])
    #expect(toast.isUnprompted)

    // Saved as ended, naming no session, until they start again.
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.map(\.id) == [lead.id, left.id, helper.id, web.id, right.id, live.id])
    #expect(saved.sessions.map(\.systemEnd) == [.restart, .restart, .restart, .restart, .restart, nil])
    #expect(saved.sessions.prefix(5).allSatisfy { $0.hosted == nil && $0.launchRequestID == nil && $0.mayComeBack })
    #expect(saved.splitGroups.map(\.paneSessionIDs) == [[left.id, right.id]])

    // Restart All: each starts again, fresh, in a new session where it
    // was, as what it was.
    chromeState.toasts.performAction(of: toast.id)
    #expect(await harness.fake.wait(timeout: 8) { harness.creates().count == 5 })
    func create(_ record: WorkspaceSessionRecord) throws -> FakeControlHelper.Request {
        try #require(harness.creates().first { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.tab] == record.id.uuidString })
    }
    func configuration(_ record: WorkspaceSessionRecord) throws -> ShellProcessController.Configuration {
        try #require(harness.configurations.value.first { $0.processID == record.id.uuidString })
    }
    #expect(try create(left).string("cwd") == elsewhere.path)
    #expect(try create(right).string("cwd") == root.path)
    #expect((try create(left).json["tags"] as? [String: String])?[PersistentSessionTag.kind] == "terminal")
    #expect(try configuration(left).startupCommand == nil)
    #expect((try create(lead).json["tags"] as? [String: String])?[PersistentSessionTag.agent] == "Claude")
    #expect(try configuration(lead).startupCommand == "claude")
    #expect(try configuration(helper).startupCommand == "codex")
    #expect(try configuration(helper).agentID == helper.id.uuidString)
    #expect((try create(web).json["tags"] as? [String: String])?[PersistentSessionTag.command] == "web")
    #expect(try configuration(web).startupCommand == "run-web")
    #expect(try configuration(web).environment["PORT"] == "8000")
    for record in [lead, left, helper, web, right] {
        let tab = try #require(workspace.session(withID: record.id))
        #expect(await harness.fake.wait { tab.persistentSession != nil && tab.isRunning })
        #expect(tab.systemSessionEnd == nil)
        #expect(tab.persistentSessionEndedMessage == nil)
    }
    #expect(workspace.sessions.count == 6)
    // What a log out would record as ended while *on quit* is End Sessions.
    #expect(Set(repository.localSessionsEndedByAQuit().map(\.sessionID))
        == Set(workspace.sessions.compactMap { $0.persistentSession?.sessionID }))
    #expect(repository.localSessionsEndedByAQuit().count == 6)
    // Saved as the running tabs they are now.
    repository.flushPersistentState()
    let resaved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(resaved.sessions.allSatisfy { $0.systemEnd == nil && $0.hosted != nil })
}

@Test @MainActor func aNormalRelaunchStillDropsATabWhoseSessionIsGoneAndOpensTheShell() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-no-reboot")
    let storeDirectory = try canonicalDirectory("cherry-restore-no-reboot-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let gone = localRecord(title: "Gone", sessionID: "s-gone", workingDirectory: root.path)
    harness.fake.pendingHolders = 0
    // Saved in this boot; the only quit for a log out came before it.
    let savedAt = Date()
    store.noteSystemQuit(at: savedAt.addingTimeInterval(-600))
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [gone], selectedSessionID: gone.id)],
        savedAt: savedAt
    ))
    let chromeState = quietChromeState()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    // Dropped, as before; the window opens its default shell instead.
    #expect(workspace.session(withID: gone.id) == nil)
    #expect(workspace.sessions.count == 1)
    #expect(workspace.sessions.first?.systemSessionEnd == nil)
    #expect(chromeState.toasts.current == nil)
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(!saved.sessions.contains { $0.id == gone.id })
}

@Test @MainActor func tabsWhoseSessionsWereEndedOnPurposeStayDroppedAfterAReboot() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-reboot-purpose")
    let storeDirectory = try canonicalDirectory("cherry-restore-reboot-purpose-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let project = root.path
    // Ended through this app (a close, End Sessions, Background Sessions).
    let endedHere = localRecord(title: "Ended here", sessionID: "s-ended", workingDirectory: project)
    // Persistent Sessions → Terminate or Remove.
    let terminated = localRecord(title: "Terminated", sessionID: "s-terminated", workingDirectory: project)
    // Closed (⌘W) or forgotten with its worktree: a session still to end.
    let closed = localRecord(title: "Closed", sessionID: "s-closed", workingDirectory: project)
    // Only attached to a session it did not own, or never a session at all.
    let attached = localRecord(title: "Attached", sessionID: "s-attached", owned: false, workingDirectory: project)
    let native = localRecord(title: "Native", sessionID: nil, workingDirectory: project)
    // A tab saved while its Create was under way owned what it made.
    var creating = localRecord(title: "Creating", sessionID: nil, workingDirectory: project)
    creating.launchRequestID = UUID().uuidString.lowercased()
    // And one the system ended.
    let lost = localRecord(title: "Lost", sessionID: "s-lost", workingDirectory: project)
    // Saved (as a window close or quit with End Sessions saves) before
    // their sessions were ended.
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: project,
        worktrees: [WorktreeStateRecord(root: project, sessions: [endedHere, terminated, closed, attached, native, creating, lost])],
        savedAt: try beforeTheLastBoot()
    ))

    // `end` records what it ends.
    harness.hosting.endedSessionsStore = store
    harness.fake.sessions = [HostedSessionInfo(id: "s-ended", name: "Ended here", cwd: project, pid: 71, owner: "CherryTests")]
    harness.fake.pendingHolders = 0
    _ = try await harness.hosting.list()
    await harness.hosting.end(HostedSessionAttachment(
        host: .local, hostID: "host-a", sessionID: "s-ended", name: "Ended here",
        remoteWorkingDirectory: project, executablePath: harness.cli.executable.path
    )).value
    #expect(harness.fake.sessions.isEmpty)
    harness.hosting.noteEndedOnPurpose(hostID: "host-a", sessionID: "s-terminated")
    store.addSessionsToEnd([closed])
    store.flush()
    #expect(store.wasEndedOnPurpose(endedHere))
    #expect(store.wasEndedOnPurpose(terminated))
    #expect(store.wasEndedOnPurpose(closed))
    #expect(!store.wasEndedOnPurpose(lost))
    // A session of the same id on another host identity is another session.
    #expect(!store.wasEndedOnPurpose(localRecord(title: "Other", sessionID: "s-ended", hostID: "host-b", workingDirectory: project)))

    let repository = RepositoryWorkspace(
        projectRoot: project,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    #expect(workspace.sessions.map(\.id) == [creating.id, lost.id])
    #expect(workspace.sessions.allSatisfy { $0.systemSessionEnd == .restart })
}

@Test @MainActor func aLogOutOrALostHolderBringsTabsBackOnlyOnceNothingMoreIsComing() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.disappearanceConfirmationDelay = .milliseconds(200)
    configuration.pendingHoldersPollInterval = .milliseconds(20)
    configuration.pendingHoldersWait = .milliseconds(300)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let killed = localRecord(title: "Killed", sessionID: "s-killed", workingDirectory: project)
    let gone = localRecord(title: "Gone", sessionID: "s-gone", workingDirectory: project)
    let elsewhere = localRecord(title: "Elsewhere", sessionID: "s-elsewhere", hostID: "host-b", workingDirectory: project)
    let justNow = Date()
    func evidence(quits: [Date] = []) -> SystemEndedSessions {
        SystemEndedSessions(savedAt: justNow, bootTime: justNow.addingTimeInterval(-3_600), systemQuits: quits, endedOnPurpose: { _ in false })
    }
    // The host found the killed one's holder gone (a log out while Cherry
    // was not running): it comes back; the other one is dropped, and so is
    // one saved on a host that now has another identity.
    harness.fake.lostSessionIDs = ["s-killed"]
    harness.fake.pendingHolders = 0
    let lostHolder = await harness.restore([killed, gone, elsewhere], into: workspace, systemEnds: evidence())
    #expect(lostHolder.sessions.map(\.id) == [killed.id])
    #expect(lostHolder.sessions.first?.systemSessionEnd == .logout)
    #expect(lostHolder.sessions.first?.persistentSessionEndedMessage == "Ended when you logged out")
    #expect(lostHolder.keptRecordIDs.isEmpty)
    #expect(lostHolder.remainder == nil)
    WorkspaceRestoreResult.discard(lostHolder, in: workspace)

    // Cherry quit for a log out after the save: every missing one comes back.
    harness.fake.lostSessionIDs = []
    let loggedOut = await harness.restore([killed, gone], into: workspace, systemEnds: evidence(quits: [justNow.addingTimeInterval(5)]))
    #expect(loggedOut.sessions.map(\.id) == [killed.id, gone.id])
    #expect(loggedOut.sessions.allSatisfy { $0.systemSessionEnd == .logout })
    WorkspaceRestoreResult.discard(loggedOut, in: workspace)

    // Without evidence (a normal relaunch) they are dropped.
    let normal = await harness.restore([killed, gone], into: workspace, systemEnds: evidence())
    #expect(normal.sessions.isEmpty)
    #expect(normal.keptRecordIDs.isEmpty)

    // A host that does not report pending holders: only after its second
    // look, as a dropped tab would be.
    harness.fake.pendingHolders = nil
    let older = await harness.restore([gone], into: workspace, systemEnds: evidence(quits: [justNow.addingTimeInterval(5)]))
    #expect(older.sessions.isEmpty)
    #expect(older.pendingRecordIDs == [gone.id])
    let olderRest = try await #require(older.remainder).value
    #expect(olderRest.sessions.map(\.id) == [gone.id])
    #expect(olderRest.sessions.first?.systemSessionEnd == .logout)
    WorkspaceRestoreResult.discard(olderRest, in: workspace)

    // Holders still expected when the wait runs out: kept, not ended.
    harness.fake.pendingHolders = 2
    let waiting = await harness.restore([gone], into: workspace, systemEnds: evidence(quits: [justNow.addingTimeInterval(5)]))
    let waitingRest = try await #require(waiting.remainder).value
    #expect(waitingRest.sessions.isEmpty)
    #expect(waitingRest.keptRecordIDs == [gone.id])
}

@Test @MainActor func tabsSavedEndedComeBackEndedWithoutAskingOrAToastAndCommandsStartByTheirRules() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-saved-ended")
    let storeDirectory = try canonicalDirectory("cherry-restore-saved-ended-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    var shell = localRecord(title: "Shell", sessionID: nil, workingDirectory: root.path)
    shell.systemEnd = .logout
    // Ended by the reboot now: an auto-start command, and one that restarts
    // when it exits.
    let web = localRecord(kind: .command, title: "web", sessionID: "s-web", commandName: "web", workingDirectory: root.path)
    let worker = localRecord(
        kind: .command, title: "worker", sessionID: "s-worker", commandName: "worker", restartOnExit: true,
        workingDirectory: root.path
    )
    harness.fake.pendingHolders = 0
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [shell, web, worker], selectedSessionID: shell.id)],
        savedAt: try beforeTheLastBoot()
    ))
    let chromeState = quietChromeState()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [ProjectCommandDefinition(name: "web", command: "serve", autoStart: true)] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.autoStartInitialCommandsIfNeeded()
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    #expect(workspace.sessions.map(\.id) == [shell.id, web.id, worker.id])
    let shellTab = try #require(workspace.session(withID: shell.id))
    #expect(shellTab.systemSessionEnd == .logout)
    #expect(workspace.selectedSessionID == shell.id)
    // No toast: the tab saved ended was told about before, and the newly
    // ended commands start by themselves (auto-start, auto-restart).
    #expect(chromeState.toasts.current == nil)
    // Auto-start starts its command in its tab; the other restarts by its
    // policy. Each in a new session for the same tab; nothing is opened.
    #expect(await harness.fake.wait(timeout: 8) {
        harness.creates().count == 2
            && workspace.session(withID: web.id)?.persistentSession != nil
            && workspace.session(withID: worker.id)?.persistentSession != nil
    })
    let tabs = Set(harness.creates().compactMap { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.tab] })
    #expect(tabs == [web.id.uuidString, worker.id.uuidString])
    #expect(workspace.sessions.count == 3)
    #expect(shellTab.systemSessionEnd == .logout)
    #expect(!shellTab.isRunning)
    // Restart All has nothing to start.
    repository.restartSystemEndedTabs()
    #expect(harness.creates().count == 2)

    // Closing an ended tab ends nothing and cannot be undone: it has no
    // session to come back to.
    #expect(workspace.closedTab(for: shellTab, name: "Shell") == nil)
    workspace.close(shellTab)
    #expect(workspace.session(withID: shell.id) == nil)
    #expect(harness.fake.requests("kill").isEmpty)
}

@Test @MainActor func exitedSessionsComeBackShowingTheirExitAndNeverRestartByThemselves() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-reboot-exited")
    let storeDirectory = try canonicalDirectory("cherry-restore-reboot-exited-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    // A persistent tab saves its program's exit once its host reports it.
    let probe = harness.workspace()
    let tab = probe.addSession(title: "Probe")
    #expect(await harness.waitUntilAttached(tab))
    #expect(WorkspaceSessionRecord(session: tab, restoredRecord: nil).exitStatus == nil)
    let probeSession = try #require(tab.persistentSession?.sessionID)
    harness.exit(probeSession, code: 3)
    #expect(await harness.fake.wait { tab.state == .exited(3) })
    #expect(WorkspaceSessionRecord(session: tab, restoredRecord: nil).exitStatus == 3)
    probe.closeAllSessions(intent: .windowClosed)
    harness.fake.sessions = []
    let createsBefore = harness.creates().count
    func creates() -> [FakeControlHelper.Request] { Array(harness.creates().dropFirst(createsBefore)) }

    var failed = localRecord(title: "Failed", sessionID: "s-failed", workingDirectory: root.path)
    failed.exitStatus = 2
    var clean = localRecord(title: "Clean", sessionID: "s-clean", workingDirectory: root.path)
    clean.exitStatus = 0
    // Auto-restart gave up on it before the restart.
    var paused = localRecord(
        kind: .command, title: "worker", sessionID: "s-worker", commandName: "worker", restartOnExit: true,
        workingDirectory: root.path
    )
    paused.exitStatus = 1
    let live = localRecord(title: "Live", sessionID: "s-live", workingDirectory: root.path)
    harness.fake.pendingHolders = 0
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [failed, clean, paused, live])],
        savedAt: try beforeTheLastBoot()
    ))
    let chromeState = quietChromeState()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: harness.policy,
        stateStore: store,
        sessionRestorer: harness.restorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()
    let workspace = repository.activeWorkspace
    // The clean exit would have closed its tab: dropped.
    #expect(workspace.sessions.map(\.id) == [failed.id, paused.id, live.id])
    let failedTab = try #require(workspace.session(withID: failed.id))
    #expect(failedTab.persistentSessionEndedMessage == "Session ended (exit 2)")
    #expect(failedTab.state == .exited(2))
    let pausedTab = try #require(workspace.session(withID: paused.id))
    #expect(pausedTab.persistentSessionEndedMessage == "Session ended (exit 1)")
    #expect(try #require(workspace.session(withID: live.id)).persistentSessionEndedMessage == "Ended when the Mac restarted")
    // Only the one that ran counts, and Restart All starts only it.
    let toast = try #require(chromeState.toasts.current)
    #expect(toast.title == "1 tab ended when the Mac restarted")
    try await Task.sleep(for: .milliseconds(700))
    #expect(creates().isEmpty)
    chromeState.toasts.performAction(of: toast.id)
    #expect(await harness.fake.wait { creates().count == 1 })
    #expect((creates().first?.json["tags"] as? [String: String])?[PersistentSessionTag.tab] == live.id.uuidString)
    try await Task.sleep(for: .milliseconds(500))
    #expect(creates().count == 1)
    #expect(!pausedTab.isRunning)
    // Saved with their exits, and they come back so again.
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.first { $0.id == failed.id }?.exitStatus == 2)
    #expect(saved.sessions.first { $0.id == failed.id }?.systemEnd == .restart)
    #expect(saved.sessions.first { $0.id == paused.id }?.exitStatus == 1)
    repository.closeAllSessions(intent: .windowClosed)
    let again = harness.workspace()
    defer { again.closeAllSessions(intent: .windowClosed) }
    let back = await harness.restore([], unbound: saved.sessions.filter { $0.systemEnd != nil }, into: again)
    #expect(back.sessions.map { $0.persistentSessionEndedMessage } == ["Session ended (exit 2)", "Session ended (exit 1)"])
    WorkspaceRestoreResult.discard(back, in: again)
}

@Test @MainActor func aRecordKeptWhileTheHostWasUnreachableKeepsItsEvidenceWhenSavedAgain() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-reboot-kept")
    let storeDirectory = try canonicalDirectory("cherry-restore-reboot-kept-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let shell = localRecord(title: "Shell", sessionID: "s-shell", workingDirectory: root.path)
    let beforeBoot = try beforeTheLastBoot()
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [shell])],
        savedAt: beforeBoot
    ))
    func open() -> RepositoryWorkspace {
        RepositoryWorkspace(
            projectRoot: root.path,
            backendPolicy: harness.policy,
            stateStore: store,
            sessionRestorer: harness.restorer,
            autoStartCommands: { _ in [] },
            restoredTabLaunchQueue: RestoredTabLaunchQueue()
        )
    }
    // The first launch after the restart cannot list the host: the record is
    // kept, and saved again now with the window's other tabs.
    harness.installationProblem.value = "No helper"
    let first = open()
    first.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await first.waitForPendingRestores()
    #expect(first.activeWorkspace.session(withID: shell.id) == nil)
    first.flushPersistentState()
    let resaved = try #require(store.load(repositoryRoot: first.repositoryRoot))
    #expect((resaved.savedAt ?? .distantPast) > beforeBoot)
    let kept = try #require(resaved.worktree(root: root.path)?.sessions.first { $0.id == shell.id })
    // (Saves keep whole seconds.)
    #expect(kept.savedAt?.timeIntervalSince1970 == beforeBoot.timeIntervalSince1970.rounded(.down))
    first.closeAllSessions(intent: .windowClosed)

    // The next launch lists it: the session is gone, and it was last seen
    // before the restart.
    harness.installationProblem.value = nil
    harness.fake.pendingHolders = 0
    let second = open()
    defer { second.closeAllSessions(intent: .windowClosed) }
    second.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await second.waitForPendingRestores()
    #expect(second.activeWorkspace.session(withID: shell.id)?.systemSessionEnd == .restart)
}

@Test @MainActor func aTabSavedEndedTakesTheSessionARestartStartedForItBeforeItsBindingWasSaved() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    workspace.restoredTabLaunchQueue = RestoredTabLaunchQueue()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    var shell = localRecord(title: "Shell", sessionID: nil, workingDirectory: project)
    shell.systemEnd = .restart
    var other = localRecord(title: "Other", sessionID: nil, workingDirectory: project)
    other.systemEnd = .logout
    // Restart created this one; Cherry ended before it saved the binding.
    harness.fake.sessions = [HostedSessionInfo(
        id: "s-restarted", name: "Shell", cwd: project, pid: 90, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: shell.id.uuidString, PersistentSessionTag.project: project]
    )]
    harness.fake.pendingHolders = 0
    let result = await harness.restore([], unbound: [shell, other], into: workspace)
    let restarted = try #require(result.sessions.first { $0.id == shell.id })
    #expect(restarted.systemSessionEnd == nil)
    #expect(restarted.persistentSession?.sessionID == "s-restarted")
    #expect(result.sessions.first { $0.id == other.id }?.systemSessionEnd == .logout)
    WorkspaceRestoreResult.discard(result, in: workspace)

    // Orphan adoption takes it too: a tab saved ended names no session.
    let saved = RepositoryStateRecord(
        repositoryRoot: project, activeWorktreeRoot: project,
        worktrees: [WorktreeStateRecord(root: project, sessions: [shell])],
        savedAt: Date(timeIntervalSince1970: 1_000)
    )
    let criteria = OrphanedSessionCriteria(owner: "CherryTests", savedState: saved, createdBefore: Date())
    let info = HostedSessionInfo(
        id: "s-restarted", name: "Shell", cwd: project, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: shell.id.uuidString, PersistentSessionTag.project: project],
        createdAt: UInt64(Date().addingTimeInterval(-5).timeIntervalSince1970 * 1_000)
    )
    #expect(criteria.orphanTabID(of: info) == shell.id)
}

@Test @MainActor func lostSessionsTheHostReportedStillCountOnceItsDaemonRestarted() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalDirectory("cherry-restore-lost-recorded")
    let storeDirectory = try canonicalDirectory("cherry-restore-lost-recorded-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    defer {
        harness.cleanUp()
        [root, storeDirectory].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    harness.hosting.endedSessionsStore = store
    let shell = localRecord(title: "Shell", sessionID: "s-killed", workingDirectory: root.path)
    // Saved in this boot, with no quit for a log out after it.
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [shell])],
        savedAt: Date()
    ))
    // A list this run took (another window's restore, Background Sessions)
    // saw the host report the holder killed; the app records it.
    harness.fake.pendingHolders = 0
    harness.fake.lostSessionIDs = ["s-killed"]
    _ = try await harness.hosting.completeList()
    store.flush()
    #expect(store.lostSessions(hostID: "host-a") == ["s-killed"])
    // The daemon restarted since and forgot it; the window opens now.
    harness.fake.lostSessionIDs = []
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
    #expect(repository.activeWorkspace.session(withID: shell.id)?.systemSessionEnd == .logout)
}
