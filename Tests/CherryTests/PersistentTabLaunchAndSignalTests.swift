import AppKit
import CherryControl
import Foundation
import MCP
import Testing
@testable import Cherry
@testable import CherryMCP

// Persistent tabs (docs/specs/multiplexer-default.md) while their session is
// created or restarted, after their host restarted, and for MCP input whose
// encoding depends on the program's key modes. Against the fake `cherry
// control` (FakeControlHelper) and attach adapter (HostedSessionFakeCLI);
// nothing reaches a real cherry-host.

@MainActor
private func launchConfiguration(reconnect: TimeInterval = 30) -> PersistentLocalSessions.Configuration {
    var configuration = PersistentHarness.fastConfiguration
    configuration.reconnectDelay = (reconnect, reconnect)
    configuration.hostScreenReuseInterval = 0
    return configuration
}

/// Writes `session`'s latest attach adapter's live state to its status
/// file, once that adapter started, and waits until the tab took it.
@MainActor
private func reportAttached(
    _ session: TerminalSession,
    in harness: PersistentHarness,
    reconnecting: Bool = false
) async throws {
    let sessionID = try #require(session.hostedSessionBinding?.sessionID)
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach \(sessionID) ") } })
    let call = try #require(harness.attachCalls.last { $0.contains("attach \(sessionID) ") })
    try HostedSessionFakeCLI.writeStatus(
        HostedSessionFakeCLI.attachedStatus(reconnecting: reconnecting),
        to: try harness.statusFile(of: call)
    )
    #expect(await harness.fake.wait { session.adapterLiveStatus?.reconnecting == reconnecting })
}

/// What the fake host was asked to type into `sessionID`, in order.
private func typed(_ harness: PersistentHarness, into sessionID: String? = nil) -> [String] {
    harness.fake.requests("send_input").compactMap { request in
        guard sessionID == nil || request.string("id") == sessionID else { return nil }
        return request.string("data").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Restores a terminal tab whose session the fake host runs, its adapter
/// left for later (a worktree not shown).
@MainActor
private func restoreTerminal(
    _ harness: PersistentHarness,
    into workspace: TerminalWorkspace,
    sessionID: String = "session-restored"
) async throws -> TerminalSession {
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: harness.project.path,
        projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
    harness.fake.sessions.append(HostedSessionInfo(
        id: sessionID, name: "Shell", cwd: harness.project.path, pid: 64, owner: "CherryTests",
        tags: [PersistentSessionTag.tab: record.id.uuidString]
    ))
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path, worktreeRoot: harness.project.path,
        records: [record], workspace: workspace
    ))
    workspace.restoreSessions(
        result.sessions, from: WorktreeStateRecord(root: harness.project.path, sessions: [record]),
        launchingAdapters: false
    )
    let tab = try #require(result.sessions.first)
    #expect(tab.isAwaitingDeferredLaunch)
    return tab
}

// MARK: - Keys typed while the session is created or restarted

@Test @MainActor func keysTypedWhileANewTabsSessionIsCreatedReachItsProgramInOrder() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(tab.state == .launching)
    // Shown now: an in-memory surface, which runs no process.
    #expect(!tab.ghosttyBridge.isNativePTYBacked)
    #expect(await harness.fake.wait { held.isHeld })

    // What that surface's Ghostty encodes goes to the tab's input writer
    // (GhosttySessionProxy); the key monitor sends paste and arrows itself.
    tab.hostInputWriter.write(Data("git".utf8))
    tab.send(data: Data("\u{1B}[D".utf8))
    tab.hostInputWriter.write(Data(" status\r".utf8))
    #expect(harness.fake.requests("send_input").isEmpty)

    let info = HostedSessionInfo(id: "session-new", name: "Shell", cwd: harness.project.path, pid: 81)
    harness.fake.sessions = [info]
    held.answer(.created(info))
    #expect(await harness.waitUntilAttached(tab))
    #expect(await harness.fake.wait { typed(harness).joined() == "git\u{1B}[D status\r" })
    #expect(typed(harness) == ["git", "\u{1B}[D", " status\r"])
    #expect(tab.ghosttyBridge.isNativePTYBacked)
}

@Test @MainActor func keysQueuedWhileASessionIsCreatedAreBounded() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.fake.wait { held.isHeld })
    let limit = TerminalSession.maxQueuedKeyboardInputBytes
    let first = Data(repeating: UInt8(ascii: "a"), count: limit - 10)
    tab.hostInputWriter.write(first)
    // More than fits: dropped, whole.
    tab.hostInputWriter.write(Data(repeating: UInt8(ascii: "b"), count: 20))
    tab.hostInputWriter.write(Data("0123456789".utf8))

    let info = HostedSessionInfo(id: "session-bounded", name: "Shell", cwd: harness.project.path, pid: 81)
    harness.fake.sessions = [info]
    held.answer(.created(info))
    #expect(await harness.waitUntilAttached(tab))
    let expected = String(decoding: first, as: UTF8.self) + "0123456789"
    #expect(await harness.fake.wait { typed(harness).joined().count >= expected.count })
    #expect(typed(harness).joined() == expected)
}

@Test @MainActor func keysTypedWhileATabRestartsReachTheNewProgramNotTheEndedAdapter() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    #expect(tab.ghosttyBridge.isNativePTYBacked)
    let first = try #require(tab.persistentSession?.sessionID)

    // The next Create waits for the test.
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    #expect(workspace.restart(tab))
    // The ended adapter's surface no longer takes the keys: an in-memory
    // one does, and they are queued.
    #expect(!tab.ghosttyBridge.isNativePTYBacked)
    tab.hostInputWriter.write(Data("npm run dev\r".utf8))
    #expect(await harness.fake.wait { held.isHeld })

    let info = HostedSessionInfo(id: "session-second", name: "Server", cwd: harness.project.path, pid: 82)
    harness.fake.sessions.append(info)
    held.answer(.created(info))
    #expect(await harness.waitUntilAttached(tab))
    #expect(tab.persistentSession?.sessionID == "session-second")
    #expect(await harness.fake.wait { typed(harness, into: "session-second") == ["npm run dev\r"] })
    #expect(typed(harness, into: first).isEmpty)
    // The new adapter runs in an EXEC surface again.
    #expect(tab.ghosttyBridge.isNativePTYBacked)
}

// MARK: - Restart while the previous program exits

@Test @MainActor func aTabStoppedWhileItsRestartWaitsForTheOldProgramStartsNothing() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let server = workspace.addSession(title: "Server")
    let other = workspace.addSession(title: "Other")
    #expect(await harness.waitUntilAttached(server))
    #expect(await harness.waitUntilAttached(other))
    #expect(harness.creates().count == 2)

    // The program takes its time to exit (up to the restart's 3 s wait).
    harness.fake.killEndsSession = false
    #expect(workspace.restart(server))
    try await Task.sleep(for: .milliseconds(300))
    // Stopped (MCP stop_process) while the restart waits.
    let stopped = try await control.send(.stopProcess(.init(processID: server.id.uuidString)))
    #expect(stopped.error == nil)
    try await Task.sleep(for: .milliseconds(3_500))
    #expect(harness.creates().count == 2)
    #expect(!server.isRunning)

    // Closed while the restart waits: nothing starts either.
    #expect(workspace.restart(other))
    try await Task.sleep(for: .milliseconds(300))
    workspace.close(other, intent: .userClosedTab)
    try await Task.sleep(for: .milliseconds(3_500))
    #expect(harness.creates().count == 2)
}

@Test @MainActor func restartingTwiceWhileTheOldProgramExitsStartsItOnce() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let server = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(server))
    #expect(harness.creates().count == 1)

    harness.fake.killEndsSession = false
    #expect(workspace.restart(server))
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.restart(server))
    try await Task.sleep(for: .milliseconds(4_500))
    #expect(await harness.waitUntilAttached(server))
    // One new session: the first restart stood down for the second.
    #expect(harness.creates().count == 2)
    let running = harness.fake.sessions.filter { $0.isRunning }.map(\.id)
    #expect(server.persistentSession.map { running.contains($0.sessionID) } == true)
}

@Test @MainActor func aQuitThatEndsSessionsWaitsForTheSessionOfATabWhoseCreateWasUnderWayToBeEnded() async throws {
    let harness = try PersistentHarness()
    // Settings › Sessions › End sessions when quitting.
    harness.settings.value.endLocalSessionsOnQuit = true
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let closing = workspace.addSession(title: "Closing")
    #expect(await harness.fake.wait { held.isHeld })
    // Quit tears the tab down while its Create is under way.
    workspace.close(closing, allowEmptyWorkspace: true, intent: .appQuit)
    #expect(workspace.sessions.isEmpty)
    let settled = Recorder(false)
    Task { @MainActor in
        await TerminalSession.waitForPersistentLaunches(upTo: .seconds(8))
        settled.value = true
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!settled.value)

    // The Create answers: nothing shows that session, and the quit ends
    // sessions, so it is ended, and only then does the wait finish.
    let request = try #require(harness.creates().first)
    let info = HostedSessionInfo(
        id: "session-late", name: "Closing", cwd: harness.project.path, pid: 83,
        tags: request.json["tags"] as? [String: String] ?? [:]
    )
    harness.fake.sessions.append(info)
    held.answer(.created(info))
    #expect(await harness.fake.wait(timeout: 8) { settled.value })
    #expect(harness.fake.requests("kill").contains { $0.string("id") == "session-late" })
}

@Test @MainActor func aQuitThatKeepsSessionsKeepsTheSessionATabsCreateMakesAfterwardForItsSavedRecord() async throws {
    // The default: quitting keeps local sessions running.
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    let next = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        next.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Server")
    #expect(await harness.fake.wait { held.isHeld })
    // Quit saves the tabs first (its Create's request id, no session yet),
    // then tears them down.
    let saved = workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    let record = try #require(saved.sessions.first)
    #expect(record.hosted == nil)
    let requestID = try #require(record.launchRequestID)
    workspace.close(tab, allowEmptyWorkspace: true, intent: .appQuit)
    #expect(workspace.sessions.isEmpty)

    // Nothing to end: the quit does not wait for that Create.
    let started = ContinuousClock.now
    await TerminalSession.waitForPersistentLaunches(upTo: .seconds(8))
    #expect(ContinuousClock.now - started < .seconds(1))

    // The Create answers after the tab closed: its session runs on.
    let request = try #require(harness.creates().first)
    #expect(request.string("request_id")?.lowercased() == requestID)
    let info = HostedSessionInfo(
        id: "session-late", name: "Server", cwd: harness.project.path, pid: 84, owner: "CherryTests",
        tags: request.json["tags"] as? [String: String] ?? [:]
    )
    harness.fake.sessions.append(info)
    held.answer(.created(info))
    try await Task.sleep(for: .milliseconds(500))
    #expect(!harness.fake.requests("kill").contains { $0.string("id") == "session-late" })
    #expect(!harness.fake.requests("remove").contains { $0.string("id") == "session-late" })

    // The next launch's restore finds it by the saved record's request id.
    let restored = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path, worktreeRoot: harness.project.path,
        records: [], workspace: next, unboundRecords: saved.sessions
    ))
    let back = try #require(restored.sessions.first)
    #expect(back.id == tab.id)
    next.restoreSessions(restored.sessions, from: saved, launchingAdapters: false)
    #expect(await harness.fake.wait { back.hostedSessionBinding?.sessionID == "session-late" })
}

// MARK: - Bells and notifications the host kept while its daemon was down

@Test @MainActor func signalsTheHostKeptWhileItsDaemonWasDownShowOnceAfterTheAdapterReattached() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Agent")
    #expect(await harness.waitUntilAttached(tab))
    try await reportAttached(tab, in: harness)
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }
    func push(_ event: HostSessionEvent) {
        harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(event))
    }

    // The adapter passes signals through: the host's copy is not shown.
    push(.notification(id: sessionID, title: "Build", body: "live"))
    push(.bell(id: sessionID))
    try await Task.sleep(for: .milliseconds(300))
    #expect(!tab.hasUnreadNotification)
    #expect(bells.value == 0)

    // The daemon goes away. The adapter reconnects (restarting it) and
    // attaches again before the app's control connection comes back.
    harness.fake.launchFailure = "daemon down"
    harness.fake.dropAll()
    #expect(await harness.fake.wait { harness.control.state != .connected })
    try await reportAttached(tab, in: harness, reconnecting: true)
    try await reportAttached(tab, in: harness)
    // The surface showed one signal after it attached again.
    tab.ingestNativeNotification(title: nil, body: "after the adapter came back")
    #expect(tab.hasUnreadNotification)
    tab.clearUnreadNotification()

    // The app's control connection comes back and gets what the host kept:
    // a notification and a bell from while the daemon was down (the
    // adapter never showed them), and the one the surface already showed.
    harness.fake.launchFailure = nil
    #expect(await harness.fake.wait(timeout: 10) { harness.control.state == .connected })
    push(.notification(id: sessionID, title: "Claude", body: "Claude needs your permission to use Bash"))
    push(.bell(id: sessionID))
    #expect(await harness.fake.wait { tab.hasUnreadNotification && bells.value == 1 })
    #expect(tab.lastNotification?.body == "Claude needs your permission to use Bash")
    tab.clearUnreadNotification()
    push(.notification(id: sessionID, title: "", body: "after the adapter came back"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(!tab.hasUnreadNotification)
    #expect(bells.value == 1)
}

// MARK: - MCP input whose encoding depends on the program's key modes

@Test @MainActor func cursorKeysForARestoredTabGoThroughItsAdapterWhichEncodesThemForTheProgramsModes() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await restoreTerminal(harness, into: workspace)

    // Plain text goes through the host at once; the adapter still waits.
    let text = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "git diff\n")))
    #expect(text.error == nil)
    #expect(typed(harness) == ["git diff\r"])
    #expect(tab.isAwaitingDeferredLaunch)

    // Down arrow (less, with application cursor keys on, wants `ESC O B`,
    // which the host cannot know): the adapter is launched, and once it
    // attached the surface's Ghostty types it for the program's modes.
    async let down = control.send(.sendProcessInput(.init(
        processID: tab.id.uuidString, rawBase64: Data("\u{1B}[B".utf8).base64EncodedString()
    )))
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-restored ") } })
    try await reportAttached(tab, in: harness)
    let sent = try await down
    #expect(sent.error == nil)
    #expect(typed(harness) == ["git diff\r"])
    #expect(!tab.isAwaitingDeferredLaunch)
}

/// Makes the fake attach adapter turn on application cursor keys (DECCKM,
/// `ESC [ ? 1 h`, as `less` and `vim` do) as it attaches, just before it
/// prints "Attached <id>": a surface that shows that line has the mode on.
private func fakeAdapterTurnsOnApplicationCursorKeys(_ harness: PersistentHarness) throws {
    let script = harness.cli.executable
    let original = try String(contentsOf: script, encoding: .utf8)
    let attached = #"printf 'Attached %s\r\n' "$id""#
    try #require(original.contains(attached))
    let changed = original.replacingOccurrences(of: attached, with: #"printf '\033[?1hAttached %s\r\n' "$id""#)
    // In place, so the script keeps its mode.
    try Data(changed.utf8).write(to: script)
}

@Test @MainActor func aDownArrowSentThroughMCPReachesAProgramWithApplicationCursorKeysAsSS3() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await restoreTerminal(harness, into: workspace)
    // The program (`less`, run by `git diff`) turned on application cursor
    // keys; the host does not report that mode.
    try fakeAdapterTurnsOnApplicationCursorKeys(harness)

    // The caller sends Down as a normal-mode `ESC [ B`.
    async let down = control.send(.sendProcessInput(.init(
        processID: tab.id.uuidString, rawBase64: Data("\u{1B}[B".utf8).base64EncodedString()
    )))
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-restored ") } })
    #expect(await harness.fake.wait {
        tab.ghosttyBridge.readNativeScreenText()?.contains("Attached session-restored") == true
    })
    try await reportAttached(tab, in: harness)
    let sent = try await down
    #expect(sent.error == nil)
    // The adapter's terminal echoes what reaches it (ESC as "^["): the
    // program got `ESC O B`, the key in the mode it set.
    #expect(await harness.fake.wait { tab.ghosttyBridge.readNativeScreenText()?.contains("^[OB") == true })
    let screen = tab.ghosttyBridge.readNativeScreenText() ?? ""
    #expect(!screen.contains("^[[B"), Comment(rawValue: screen))
    #expect(typed(harness).isEmpty)
}

@Test @MainActor func cursorKeysGoThroughTheHostAsSentWhenNoAdapterAttachesInTime() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await restoreTerminal(harness, into: workspace)
    tab.modeDependentInputAdapterWait = 0.3
    let sent = try await control.send(.sendProcessInput(.init(
        processID: tab.id.uuidString, rawBase64: Data("\u{1B}OA".utf8).base64EncodedString()
    )))
    #expect(sent.error == nil)
    #expect(typed(harness) == ["\u{1B}OA"])
}

@Test @MainActor func cursorKeysGoThroughTheHostInTheModeItReportsWithoutWaitingForAnAdapter() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await restoreTerminal(harness, into: workspace)
    func report(applicationCursorKeys: Bool, kittyFlags: UInt32 = 0) {
        harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(HostedSessionInfo(
            id: "session-restored", name: "Shell", cwd: harness.project.path, pid: 64, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: tab.id.uuidString], alternateScreen: applicationCursorKeys,
            kittyKeyboardFlags: kittyFlags, applicationCursorKeys: applicationCursorKeys
        ))))
    }
    func send(_ bytes: String) async throws -> CherryControlResponse {
        try await control.send(.sendProcessInput(.init(
            processID: tab.id.uuidString, rawBase64: Data(bytes.utf8).base64EncodedString()
        )))
    }
    // Waiting for an adapter would hold the call up for this long.
    tab.modeDependentInputAdapterWait = 60

    // `less` (run by `git diff`) turned on application cursor keys, and
    // this host reports it: Down, sent as a normal-mode `ESC [ B`, is typed
    // as `ESC O B` by the host at once; no adapter is launched for it.
    report(applicationCursorKeys: true)
    #expect(await harness.fake.wait { tab.usesApplicationCursorKeys })
    let started = ContinuousClock.now
    let down = try await send("\u{1B}[B")
    #expect(down.error == nil)
    #expect(ContinuousClock.now - started < .seconds(30))
    #expect(typed(harness) == ["\u{1B}OB"])
    #expect(tab.isAwaitingDeferredLaunch)
    #expect(harness.attachCalls.isEmpty)
    // Home and End too; modified arrows and other keys are left alone.
    _ = try await send("j\u{1B}[H\u{1B}[1;5A\u{1B}[F")
    #expect(typed(harness).last == "j\u{1B}OH\u{1B}[1;5A\u{1B}OF")

    // Back at the shell's prompt, the mode is off: `ESC O A` is `ESC [ A`.
    report(applicationCursorKeys: false)
    #expect(await harness.fake.wait { !tab.usesApplicationCursorKeys })
    let up = try await send("\u{1B}OA")
    #expect(up.error == nil)
    #expect(typed(harness).last == "\u{1B}[A")

    // Under the kitty keyboard protocol, cursor keys are CSI whatever
    // DECCKM says.
    report(applicationCursorKeys: true, kittyFlags: 1)
    #expect(await harness.fake.wait { tab.keyboardProtocolFlags == 1 })
    #expect(!tab.usesApplicationCursorKeys)
    _ = try await send("\u{1B}OB")
    #expect(typed(harness).last == "\u{1B}[B")
    #expect(tab.isAwaitingDeferredLaunch)
}

@Test func cursorKeysAreEncodedForTheProgramsCursorKeyMode() {
    func encoded(_ text: String, application: Bool) -> String {
        String(decoding: TerminalInputNormalizer.encodingCursorKeys(Data(text.utf8), applicationCursorKeys: application), as: UTF8.self)
    }
    #expect(encoded("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D\u{1B}[H\u{1B}[F", application: true)
        == "\u{1B}OA\u{1B}OB\u{1B}OC\u{1B}OD\u{1B}OH\u{1B}OF")
    #expect(encoded("\u{1B}OA\u{1B}OF", application: false) == "\u{1B}[A\u{1B}[F")
    #expect(encoded("\u{1B}[A", application: false) == "\u{1B}[A")
    // Modified keys, other sequences, lone ESC and text are kept.
    #expect(encoded("\u{1B}[1;5A\u{1B}[5~\u{1B}OP ls\r\u{1B}", application: true) == "\u{1B}[1;5A\u{1B}[5~\u{1B}OP ls\r\u{1B}")
    #expect(encoded("\u{1B}\u{1B}[B", application: true) == "\u{1B}\u{1B}OB")
}

@Test func cursorModeKeysAreRecognized() {
    #expect(TerminalSession.containsCursorModeKeys(Data("\u{1B}[A".utf8)))
    #expect(TerminalSession.containsCursorModeKeys(Data("x\u{1B}OB".utf8)))
    #expect(TerminalSession.containsCursorModeKeys(Data("\u{1B}[H".utf8)))
    #expect(TerminalSession.containsCursorModeKeys(Data("\u{1B}OF".utf8)))
    // Modified arrows are the same in either mode; other keys too.
    #expect(!TerminalSession.containsCursorModeKeys(Data("\u{1B}[1;5A".utf8)))
    #expect(!TerminalSession.containsCursorModeKeys(Data("\u{1B}[5~".utf8)))
    #expect(!TerminalSession.containsCursorModeKeys(Data("ls -la\r".utf8)))
    #expect(!TerminalSession.containsCursorModeKeys(Data([0x1B])))
}

// MARK: - Kitty keyboard flags and the surface

@Test @MainActor func mcpTabForAnAttachedAdapterReachesTheSurfaceAsATabNotAsKittyEscapeText() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    try await reportAttached(tab, in: harness)
    let sessionID = try #require(tab.persistentSession?.sessionID)
    // The program asks for every key as an escape code (kitty flag 8).
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(HostedSessionInfo(
        id: sessionID, name: "Shell", cwd: harness.project.path, pid: 42, clients: 1,
        alternateScreen: false, kittyKeyboardFlags: 8
    ))))
    #expect(await harness.fake.wait { tab.keyboardProtocolFlags == 8 })
    // The fake adapter's terminal echoes what it is typed.
    #expect(await harness.fake.wait { tab.ghosttyBridge.readNativeScreenText()?.contains("Attached \(sessionID)") == true })

    try await tab.sendControlInput(Data("x\ty".utf8), raw: false)
    try await tab.sendControlInput(Data([0x09]), raw: false)
    try await tab.sendControlInput(Data("z".utf8), raw: false)
    #expect(await harness.fake.wait { tab.ghosttyBridge.readNativeScreenText()?.contains("z") == true })
    let screen = tab.ghosttyBridge.readNativeScreenText() ?? ""
    // Ghostty got a Tab key (it encodes for the program's flags itself),
    // never Escape followed by the text "[9u".
    #expect(!screen.contains("[9u"), Comment(rawValue: screen))
    #expect(!screen.contains("^["), Comment(rawValue: screen))
    #expect(harness.fake.requests("send_input").isEmpty)
}

// MARK: - Line counts of tabs read from their host

@Test @MainActor func aRestoredTabsLineCountIsTheOneItsOutputNumbers() async throws {
    let harness = try PersistentHarness(configuration: launchConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = try await restoreTerminal(harness, into: workspace)
    harness.fake.screenText = (1...400).map { "line \($0)" }.joined(separator: "\n")
    let output = try await control.send(.getProcessOutput(.init(processID: tab.id.uuidString, lineLimit: 10)))
    guard case .getProcessOutput(let lines)? = output.result else {
        Issue.record("Expected getProcessOutput, got \(String(describing: output))")
        return
    }
    #expect(lines.totalLines == 400)
    #expect(lines.lines.last == "line 400")
    let status = try await control.process(tab)
    #expect(status.lineCount == 400)
    let listed = try await control.send(.listProcesses(.init()))
    guard case .listProcesses(let processes)? = listed.result else {
        Issue.record("Expected listProcesses, got \(String(describing: listed))")
        return
    }
    #expect(processes.processes.first { $0.id == tab.id.uuidString }?.lineCount == 400)
}

// MARK: - MCP client timeouts

@Test func mcpClientTimeoutsCoverPersistentSessionCreationAndRestoreWaits() {
    // A new agent's first message: its session (8 s), the agent (6 s), the
    // host's answers and the output read, after wait_ms.
    #expect(CherryMCPTools.clientTimeout(for: "spawn_agent", arguments: ["wait_ms": .int(1_000)]) == 21)
    #expect(CherryMCPTools.clientTimeout(for: "spawn_process", arguments: [:]) == 20)
    #expect(CherryMCPTools.clientTimeout(for: "spawn_process", arguments: ["kind": .string("terminal")]) == 20)
    // A command first waits (at most 10 s) for a restore under way, then as
    // a terminal: its session, the host taking its input, the output read.
    #expect(CherryMCPTools.clientTimeout(
        for: "spawn_process", arguments: ["kind": .string("command"), "wait_ms": .int(1_000)]
    ) == 31)
    #expect(CherryMCPTools.clientTimeout(for: "spawn_process", arguments: ["kind": .string(" Command ")]) == 30)
    #expect(CherryMCPTools.clientTimeout(for: "send_process_input", arguments: ["wait_ms": .int(9_000)]) == 25)
    // Starting commands waits (at most 10 s) for a restore under way.
    for tool in ["start_process", "start_all_commands", "restart_all_commands"] {
        #expect(CherryMCPTools.clientTimeout(for: tool, arguments: ["wait_ms": .int(2_000)]) == 22)
    }
    // send_agent_message sends like send_process_input, then waits.
    #expect(CherryMCPTools.clientTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(3_000)]) == 20)
    #expect(CherryMCPTools.clientTimeout(for: "send_agent_message", arguments: ["timeout_ms": .int(60_000)]) == 65)
    #expect(CherryMCPTools.clientTimeout(for: "wait_for_process_idle", arguments: ["timeout_ms": .int(3_000)]) == 8)
    #expect(CherryMCPTools.clientTimeout(for: "list_processes", arguments: [:]) == nil)
}
