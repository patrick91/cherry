import AppKit
import Foundation
import Testing
@testable import Cherry

// Local tabs run as persistent sessions (docs/specs/multiplexer-default.md),
// here against the in-process fake `cherry control` (FakeControlHelper) and
// the fake attach adapter (HostedSessionFakeCLI). Nothing reaches a real
// cherry-host; see PersistentLocalSessionRealHostTests for that.

final class Recorder<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A workspace policy that runs new local tabs through a fake local host.
/// Also used by PersistentLocalSessionParityTests.
@MainActor
final class PersistentHarness {
    let fake: FakeControlHelper
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let hosting: PersistentLocalSessions
    let status = PersistentSessionsStatus()
    let settings = Recorder(SessionPersistenceSettings.defaults)
    let configurations = Recorder<[ShellProcessController.Configuration]>([])
    let installationProblem = Recorder<String?>(nil)
    /// The policy's `cleanExitMinimumRunTime`, for workspaces made after
    /// it is set.
    var cleanExitMinimumRunTime: TimeInterval = 1
    let project: URL
    private let suite: String

    init(
        configuration: PersistentLocalSessions.Configuration = PersistentHarness.fastConfiguration,
        controlConfiguration: HostControl.Configuration = .fastTests
    ) throws {
        fake = FakeControlHelper()
        cli = try HostedSessionFakeCLI()
        suite = "CherryTests.PersistentLocal.\(UUID().uuidString)"
        let hostStore = HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let executable = cli.executable
        control = HostControl(
            host: .local,
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
            configuration: controlConfiguration
        )
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-persistent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let control = control
        let configurations = configurations
        let installationProblem = installationProblem
        hosting = PersistentLocalSessions(
            owner: "CherryTests",
            control: { control },
            installationUnavailableReason: { installationProblem.value },
            launchSpec: { configuration, loginEnvironment in
                configurations.value.append(configuration)
                return HostedLaunchSpec.make(for: configuration, context: HostedLaunchContext(
                    processEnvironment: ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"],
                    loginEnvironment: loginEnvironment,
                    account: nil,
                    launchedFromDesktop: false,
                    ghosttyResources: nil,
                    zshBootstrap: nil,
                    executableDirectory: nil,
                    terminalProgramVersion: nil,
                    shellFeatures: ""
                ))
            },
            status: status,
            configuration: configuration
        )
    }

    static let fastConfiguration: PersistentLocalSessions.Configuration = {
        var configuration = PersistentLocalSessions.Configuration()
        configuration.terminationTimeout = .seconds(3)
        configuration.restartExitTimeout = .seconds(3)
        configuration.reconnectDelay = (0.05, 0.2)
        configuration.disappearanceConfirmationDelay = .milliseconds(400)
        configuration.lostCreateChecks = [.milliseconds(200), .milliseconds(800)]
        return configuration
    }()

    var policy: SessionBackendPolicy {
        let settings = settings
        return SessionBackendPolicy(
            settings: { settings.value },
            localSessions: hosting,
            cleanExitMinimumRunTime: cleanExitMinimumRunTime
        )
    }

    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(projectRoot: project.path, createInitialSession: false, backendPolicy: policy)
    }

    /// The app's restorer for this fake local host; no record here names
    /// an SSH host.
    var restorer: WorkspaceSessionRestorer {
        let control = control
        return WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting, control: { host in
            Issue.record("Only tabs of SSH hosts list \(host.displayName)")
            return control
        })
    }

    var attachCalls: [String] { cli.calls.filter { $0.contains(" attach ") } }

    func creates() -> [FakeControlHelper.Request] { fake.requests("create") }

    func requestIDs(_ op: String) -> [String] { fake.requests(op).compactMap { $0.string("id") } }

    /// Waits for `session` to run in a host session with an adapter.
    func waitUntilAttached(_ session: TerminalSession, timeout: TimeInterval = 5) async -> Bool {
        await fake.wait(timeout: timeout) {
            session.persistentSession != nil && session.usesNativePTYBackend && session.state == .live
        }
    }

    /// Reports that the host's session ended.
    func exit(_ sessionID: String, code: UInt32, signal: Int32? = nil) {
        var exited: HostedSessionInfo?
        fake.sessions = fake.sessions.map { session in
            guard session.id == sessionID else { return session }
            let info = session.exited(code: code, signal: signal)
            exited = info
            return info
        }
        guard let connection = fake.connections.last(where: { !$0.isClosed }) else { return }
        connection.push(.event(.exited(id: sessionID, exitCode: code, signal: signal)))
        if let exited { connection.push(.event(.changed(exited))) }
    }

    func statusFile(of call: String) throws -> URL {
        let parts = call.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1])
    }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        try? FileManager.default.removeItem(at: project)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private func json(_ request: FakeControlHelper.Request, _ key: String) -> [String: String] {
    request.json[key] as? [String: String] ?? [:]
}

// MARK: - Creating

@Test @MainActor func persistentTabsCreateTheirSessionWithTheTabsIdentityAndLaunchSpec() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // The tab exists at once; its session is created in the background.
    let terminal = workspace.addSession(title: "Build")
    #expect(terminal.isPersistentLocalSession)
    #expect(terminal.state == .launching)
    #expect(terminal.isRunning)
    #expect(!terminal.usesNativePTYBackend)
    #expect(terminal.hostedAttachment == nil)
    #expect(await harness.waitUntilAttached(terminal))

    let create = try #require(harness.creates().first)
    #expect(create.string("owner") == "CherryTests")
    #expect(create.string("name") == "Build")
    #expect(create.string("cwd") == harness.project.path)
    #expect(json(create, "tags") == [
        PersistentSessionTag.tab: terminal.id.uuidString,
        PersistentSessionTag.kind: "terminal",
        PersistentSessionTag.project: harness.project.path,
        PersistentSessionTag.launch: try #require(create.string("request_id")).lowercased()
    ])
    let environment = json(create, "env")
    #expect(environment["CHERRY_PROCESS_ID"] == terminal.id.uuidString)
    #expect(environment["CHERRY_AGENT_ID"] == nil)
    #expect(environment["PWD"] == harness.project.path)
    #expect(environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    let configuration = try #require(harness.configurations.value.first)
    #expect(configuration.processID == terminal.id.uuidString)
    #expect(configuration.workingDirectory == harness.project.path)
    #expect(create.json["command"] as? [String] == HostedLaunchSpec.make(for: configuration, context: HostedLaunchContext(
        processEnvironment: ["HOME": "/Users/tester", "PATH": "/usr/bin:/bin"], loginEnvironment: nil, account: nil,
        launchedFromDesktop: false, ghosttyResources: nil, zshBootstrap: nil, executableDirectory: nil,
        terminalProgramVersion: nil, shellFeatures: ""
    )).argv)

    // Bound to the created session; its pid is the program's, for MCP
    // caller routing and port detection.
    let sessionID = try #require(terminal.persistentSession?.sessionID)
    #expect(sessionID == "session-\(create.string("request_id") ?? "")")
    #expect(terminal.persistentSession?.host == .local)
    #expect(terminal.persistentSession?.hostID == "host-a")
    #expect(terminal.hostedProgramProcessID == 42)
    #expect(terminal.programProcessID == 42)
    // Never the tab's own process: stop() signals only what it owns.
    #expect(terminal.childProcessID == nil)
    #expect(terminal.restartActionTitle == "Restart")
    #expect(terminal.closeActionTitle == "Close")
    #expect(terminal.canRestart)
    #expect(workspace.canAddSplitPane(to: terminal.id))
    #expect(SessionCloseBackend(terminal) == .hostedLocal)

    // The surface runs the attach adapter for that session.
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let attach = try #require(harness.attachCalls.first)
    #expect(attach.hasPrefix("--expected-host-id host-a attach \(sessionID) --detach-key none --client-id \(terminal.id.uuidString) --status-file "))

    // Agents and commands keep their kind, name and launch settings.
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude", arguments: "--resume"),
        projectRoot: harness.project.path
    )
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(
            name: "server", command: "npm", arguments: "run dev",
            environment: ["PORT": "8000"], autoRestart: true
        ),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    #expect(await harness.waitUntilAttached(command))
    #expect(agent.kind == .agent)
    #expect(agent.agentName == "Claude")
    #expect(command.kind == .command)
    #expect(command.commandName == "server")
    #expect(command.restartPolicy == "auto_restart")
    let creates = harness.creates()
    #expect(creates.count == 3)
    let agentCreate = try #require(creates.first { json($0, "tags")[PersistentSessionTag.tab] == agent.id.uuidString })
    #expect(json(agentCreate, "tags")[PersistentSessionTag.kind] == "agent")
    #expect(json(agentCreate, "tags")[PersistentSessionTag.agent] == "Claude")
    #expect(json(agentCreate, "env")["CHERRY_AGENT_ID"] == agent.id.uuidString)
    let commandCreate = try #require(creates.first { json($0, "tags")[PersistentSessionTag.tab] == command.id.uuidString })
    #expect(json(commandCreate, "tags")[PersistentSessionTag.command] == "server")
    #expect(json(commandCreate, "env")["PORT"] == "8000")
    let agentConfiguration = try #require(harness.configurations.value.first { $0.processID == agent.id.uuidString })
    #expect(agentConfiguration.agentID == agent.id.uuidString)
    #expect(agentConfiguration.startupCommand == "claude --resume")
    let commandConfiguration = try #require(harness.configurations.value.first { $0.processID == command.id.uuidString })
    #expect(commandConfiguration.startupCommand == "npm run dev")
    #expect(commandConfiguration.environment == ["PORT": "8000"])

    // The binding is saved with the tab, with its real metadata.
    let record = workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    let saved = try #require(record.sessions.first { $0.id == command.id })
    #expect(saved.kind == .command)
    #expect(saved.commandName == "server")
    #expect(saved.hosted?.host == "local")
    #expect(saved.hosted?.sessionID == command.persistentSession?.sessionID)
    #expect(saved.isRestorable)
}

@Test @MainActor func inputSentWhileTheSessionIsCreatedArrivesOnceItIs() async throws {
    // Deterministic under load: every step waits for what it needs (the
    // Create held, the tab attached, both inputs sent) for up to 60 s, far
    // beyond what any of them takes. Neither deadline that runs while the
    // Create is held can pass first: the request's timeout (it would make
    // the tab retry) and the tab's creation deadline (it would run the
    // program natively) are both 120 s here.
    let patience: TimeInterval = 60
    var controlConfiguration = HostControl.Configuration.fastTests
    controlConfiguration.requestTimeout = .seconds(120)
    var configuration = PersistentHarness.fastConfiguration
    configuration.creationTimeout = 120
    let harness = try PersistentHarness(configuration: configuration, controlConfiguration: controlConfiguration)
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let session = workspace.addSession(command: "echo queued")
    #expect(session.acceptsInput)
    session.send(text: "second\n")
    try #require(await harness.fake.wait(timeout: patience) { held.isHeld })
    // Queued until the session exists.
    #expect(harness.fake.requests("send_input").isEmpty)
    #expect(session.isStartingPersistentSession)

    let request = try #require(harness.creates().first)
    let info = HostedSessionInfo(id: "session-held", name: "Shell 1", cwd: harness.project.path, pid: 77)
    harness.fake.sessions = [info]
    held.answer(.created(info))
    try #require(await harness.waitUntilAttached(session, timeout: patience))
    #expect(session.hostedProgramProcessID == 77)
    try #require(await harness.fake.wait(timeout: patience) { harness.fake.requests("send_input").count >= 2 })
    let inputs = harness.fake.requests("send_input").map { request in
        (request.string("id"), request.string("data").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) })
    }
    #expect(inputs.map(\.0) == ["session-held", "session-held"])
    #expect(inputs.map(\.1) == ["echo queued\n", "second\n"])
    #expect(json(request, "tags")[PersistentSessionTag.tab] == session.id.uuidString)
}

// MARK: - Program exit, restart and auto-restart

@Test @MainActor func aHostExitEndsTheProgramLikeANativeExitAndAutoRestartsCommandsInTheSameTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // An agent's exit status decides idle or error.
    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Codex", command: "codex"), projectRoot: harness.project.path)
    #expect(await harness.waitUntilAttached(agent))
    let agentSession = try #require(agent.persistentSession?.sessionID)
    harness.exit(agentSession, code: 3)
    #expect(await harness.fake.wait { agent.state == .exited(3) })
    #expect(!agent.isRunning)
    #expect(agent.exitCode == 3)
    #expect(agent.agentActivityState == .error)
    #expect(agent.hostedProgramProcessID == nil)
    // The adapter reports the same exit as it ends: nothing changes.
    agent.ingestNativeChildExit(exitCode: 0)
    #expect(agent.state == .exited(3))

    // A command set to auto-restart starts again in a new host session, in
    // the same tab (same id, CHERRY_PROCESS_ID and tags), and the ended one
    // is removed from the host.
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "worker", command: "./worker", autoRestart: true),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let firstSession = try #require(command.persistentSession?.sessionID)
    harness.exit(firstSession, code: 1)
    #expect(await harness.fake.wait { command.state == .exited(1) })
    #expect(await harness.fake.wait(timeout: 8) {
        command.persistentSession.map { $0.sessionID != firstSession } ?? false && command.state == .live
    })
    #expect(harness.requestIDs("remove").contains(firstSession))
    #expect(!harness.requestIDs("kill").contains(firstSession))
    let commandCreates = harness.creates().filter { json($0, "tags")[PersistentSessionTag.tab] == command.id.uuidString }
    #expect(commandCreates.count == 2)
    #expect(Set(commandCreates.map { json($0, "env")["CHERRY_PROCESS_ID"] }) == [command.id.uuidString])
}

@Test @MainActor func restartEndsTheSessionThenCreatesANewOneForTheSameTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let session = workspace.addSession()
    #expect(await harness.waitUntilAttached(session))
    let first = try #require(session.persistentSession?.sessionID)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    #expect(workspace.restart(session))
    #expect(session.state == .launching)
    // The previous program is killed and removed before the new one starts.
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(first) })
    #expect(await harness.waitUntilAttached(session))
    let second = try #require(session.persistentSession?.sessionID)
    #expect(second != first)
    #expect(harness.requestIDs("kill") == [first])
    let ops = harness.fake.requests.map(\.op).filter { ["kill", "remove", "create"].contains($0) }
    #expect(ops == ["create", "kill", "remove", "create"])
    let tabs = harness.creates().map { json($0, "tags")[PersistentSessionTag.tab] }
    #expect(tabs == [session.id.uuidString, session.id.uuidString])
    #expect(harness.configurations.value.map(\.processID) == [session.id.uuidString, session.id.uuidString])
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 })
    #expect(harness.attachCalls.last?.contains("attach \(second) ") == true)
}

// MARK: - Adapter and program liveness

@Test @MainActor func anAdapterThatEndsWhileTheProgramRunsReconnectsWithoutAnExit() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.reconnectAttemptsBeforeDisconnected = 2
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let session = workspace.addSession()
    #expect(await harness.waitUntilAttached(session))
    let sessionID = try #require(session.persistentSession?.sessionID)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })

    // The daemon went away under the adapter: the program still runs.
    try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
        .write(to: try harness.statusFile(of: harness.attachCalls[0]))
    session.ingestNativeChildExit(exitCode: 1)
    #expect(session.isRunning)
    #expect(session.state == .live)
    #expect(session.exitCode == nil)
    // Input meanwhile goes through the host's control connection.
    session.send(text: "ls\n")
    #expect(await harness.fake.wait { harness.fake.requests("send_input").count == 1 })
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 })
    #expect(harness.attachCalls[1].contains("attach \(sessionID) "))
    #expect(session.state == .live)

    // Failing again and again shows it is disconnected, while it keeps trying.
    for attempt in 2...3 {
        try Data(#"{"outcome":"failed","exit_code":null,"signal":null,"message":"host unreachable"}"#.utf8)
            .write(to: try harness.statusFile(of: harness.attachCalls[attempt - 1]))
        session.ingestNativeChildExit(exitCode: 1)
        #expect(await harness.fake.wait { harness.attachCalls.count == attempt + 1 })
    }
    #expect(session.state == .disconnected)
    #expect(session.isRunning)
    #expect(session.acceptsInput)

    // The adapter's outcome says the program ended: that is the exit.
    try Data(#"{"outcome":"exited","exit_code":5,"signal":null,"message":null}"#.utf8)
        .write(to: try harness.statusFile(of: harness.attachCalls[3]))
    session.ingestNativeChildExit(exitCode: 0)
    #expect(session.state == .exited(5))
    #expect(!session.isRunning)
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.attachCalls.count == 4)
    // Every launch attached as the tab, so the host replaced the previous
    // launch's attachment instead of keeping a stale client.
    #expect(harness.attachCalls.map(HostedSessionFakeCLI.clientID(of:)) == Array(
        repeating: session.id.uuidString, count: 4
    ))
    // Each launch started after the previous adapter was gone (its surface
    // is freed first): two adapters of one tab would drop each other in
    // turn, each reconnecting when the host drops it.
    #expect(harness.cli.clientOverlaps.isEmpty)
}

@Test @MainActor func persistentTerminalsAreBusyWhileTheHostReportsAForegroundJob() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let terminal = workspace.addSession()
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(terminal))
    #expect(await harness.waitUntilAttached(command))
    let terminalSession = try #require(terminal.persistentSession?.sessionID)
    // An idle shell is its session's foreground job.
    #expect(!terminal.hasRunningProcess())
    #expect(command.hasRunningProcess())

    let busy = HostedSessionInfo(
        id: terminalSession, name: "Shell 1", cwd: harness.project.path, pid: 42,
        foreground: HostedSessionForeground(pid: 99, name: "sleep")
    )
    harness.fake.connections.last?.push(.event(.changed(busy)))
    #expect(await harness.fake.wait { terminal.hasRunningProcess() })

    // What quitting, closing the window or removing the worktree would end:
    // a quit or window close keeping sessions ends none of them.
    #expect(workspace.sessionsWithRunningProcess(endingWith: .appQuit).isEmpty)
    #expect(workspace.sessionsWithRunningProcess(endingWith: .windowClosed).isEmpty)
    #expect(workspace.persistentSessionsEnded(by: .appQuit).isEmpty)
    #expect(Set(workspace.sessionsWithRunningProcess(endingWith: .worktreeRemoved).map(\.id)) == [terminal.id, command.id])
    #expect(Set(workspace.sessionsWithRunningProcess(endingWith: .appQuitEndingSessions).map(\.id)) == [terminal.id, command.id])
    #expect(workspace.persistentSessionsEnded(by: .appQuitEndingSessions).count == 2)
    #expect(workspace.sessionsWithRunningProcess(endingWith: .duplicateWindowTeardown).isEmpty)

    // What the quit or window-close question says: both run, both busy.
    for teardown in [SessionTeardown.quit, .windowClose] {
        let summary = workspace.teardownSummary(teardown, place: "cherry", pathDisplayMode: .repoFocused)
        #expect(Set(summary.runningSessions.map(\.id)) == [terminal.id, command.id])
        #expect(summary.runningSessions.allSatisfy { $0.isBusy && $0.place == "cherry" })
        #expect(Set(summary.runningSessions.compactMap(\.hostSessionID))
            == Set([terminal, command].compactMap { $0.persistentSession?.sessionID }))
        #expect(summary.persistentTabCount == 2)
        #expect(summary.stoppedWhenKeeping == 0)
        #expect(summary.stoppedWhenEnding == 2)
    }
}

// MARK: - Close intents

@Test @MainActor func closingAPersistentTabEndsItsSessionAndDetachingKeepsIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    func openTab() async throws -> (TerminalSession, String) {
        let session = workspace.addSession()
        #expect(await harness.waitUntilAttached(session))
        return (session, try #require(session.persistentSession?.sessionID))
    }
    let (anchor, _) = try await openTab()

    // Closing a tab ends its session: Kill, then Remove once it exited.
    let (closed, closedSession) = try await openTab()
    workspace.close(closed)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(closedSession) })
    #expect(harness.requestIDs("kill") == [closedSession])
    await harness.hosting.waitForPendingEnds(timeout: .seconds(2))
    #expect(!harness.hosting.hasPendingEnds)

    // So does MCP `close_process`, which asks nothing.
    let (mcpClosed, mcpClosedSession) = try await openTab()
    workspace.close(mcpClosed, intent: .mcpClose)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(mcpClosedSession) })
    #expect(harness.requestIDs("kill") == [closedSession, mcpClosedSession])

    // Detaching a tab (⌘D): it only detaches.
    let (kept, keptSession) = try await openTab()
    workspace.close(kept, intent: .userDetachedTab)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!harness.requestIDs("kill").contains(keptSession))
    #expect(harness.fake.sessions.contains { $0.id == keptSession && $0.isRunning })

    // ... but a tab whose program already ended leaves nothing to keep.
    let (ended, endedSession) = try await openTab()
    harness.exit(endedSession, code: 2)
    #expect(await harness.fake.wait { ended.state == .exited(2) })
    workspace.close(ended, intent: .userDetachedTab)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(endedSession) })
    #expect(!harness.requestIDs("kill").contains(endedSession))

    // Removing a worktree always ends its sessions.
    let worktree = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: harness.policy)
    let removedTab = worktree.addSession()
    #expect(await harness.waitUntilAttached(removedTab))
    let removedSession = try #require(removedTab.persistentSession?.sessionID)
    worktree.closeAllSessions(intent: .worktreeRemoved)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(removedSession) })

    // A window closing or the app quitting keeps them, unless its answer
    // (or Settings › Sessions) ends them; a discarded duplicate window never
    // does. The preference itself changes no close action.
    harness.settings.value.localSessionsOnQuit = .end
    for (intent, ends) in [
        (SessionCloseIntent.windowClosed, false),
        (.appQuit, false),
        (.duplicateWindowTeardown, false),
        (.windowClosedEndingSessions, true),
        (.appQuitEndingSessions, true)
    ] {
        let window = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: harness.policy)
        let tab = window.addSession()
        #expect(await harness.waitUntilAttached(tab))
        let sessionID = try #require(tab.persistentSession?.sessionID)
        window.closeAllSessions(intent: intent)
        await harness.hosting.waitForPendingEnds(timeout: .seconds(3))
        let label = Comment(rawValue: "\(intent)")
        #expect(harness.requestIDs("kill").contains(sessionID) == ends, label)
        #expect(harness.requestIDs("remove").contains(sessionID) == ends, label)
        #expect(!tab.isRunning, label)
    }
    #expect(anchor.isRunning)
}

@Test @MainActor func stoppingAPersistentProgramEndsItsSession() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"),
        projectRoot: harness.project.path
    )
    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Amp", command: "amp"), projectRoot: harness.project.path)
    #expect(await harness.waitUntilAttached(command))
    #expect(await harness.waitUntilAttached(agent))
    let commandSession = try #require(command.persistentSession?.sessionID)
    let agentSession = try #require(agent.persistentSession?.sessionID)

    command.stopManagedCommand()
    #expect(command.state == .exited(0))
    #expect(command.persistentSession == nil)
    agent.stopProgram()
    #expect(!agent.isRunning)
    #expect(await harness.fake.wait {
        Set(harness.requestIDs("remove")).isSuperset(of: [commandSession, agentSession])
    })
    #expect(Set(harness.requestIDs("kill")) == [commandSession, agentSession])

    // Starting the command again creates a new session in the same tab.
    command.restartManagedCommandIfNeeded()
    #expect(await harness.waitUntilAttached(command))
    #expect(command.persistentSession?.sessionID != commandSession)
}

// MARK: - Fallback

@Test @MainActor func tabsRunNativelyWhenTheLocalHostCannotRunThem() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }

    // A disk image copy (or no helper): new tabs are native, and Settings
    // says why.
    harness.installationProblem.value = "Move Cherry to Applications first."
    let workspace = harness.workspace()
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let native = workspace.addSession()
    #expect(!native.isPersistentLocalSession)
    #expect(native.state == .live)
    #expect(harness.status.localSessionsUnavailableReason == "Move Cherry to Applications first.")
    #expect(harness.fake.launches.isEmpty)
    #expect(harness.hosting.refreshStatus() == "Move Cherry to Applications first.")

    // The setting turned off: native too, whatever the host.
    harness.installationProblem.value = nil
    harness.settings.value.persistLocalSessions = false
    #expect(!workspace.addSession().isPersistentLocalSession)
    harness.settings.value.persistLocalSessions = true

    // The host cannot start the session: that tab runs its program
    // natively, input included, and so do new tabs for a while.
    #expect(harness.hosting.refreshStatus() == nil)
    harness.fake.launchFailure = "cherry-host could not start"
    let fallback = workspace.addSession()
    #expect(fallback.isPersistentLocalSession)
    fallback.send(text: "echo fallback\n")
    #expect(await harness.fake.wait { !fallback.isPersistentLocalSession })
    #expect(fallback.state == .live)
    #expect(fallback.isRunning)
    #expect(fallback.persistentSession == nil)
    let reason = try #require(harness.status.localSessionsUnavailableReason)
    #expect(reason.contains("cherry-host could not start"))
    let next = workspace.addSession()
    #expect(!next.isPersistentLocalSession)
    #expect(harness.creates().isEmpty)
}

// MARK: - Adopting and restoring sessions

@Test @MainActor func aSessionAttachedFromTheSheetBecomesAPersistentTabUnlessAnotherTabRunsIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let other = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        other.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tabID = UUID()
    let listed = HostedSessionInfo(
        id: "session-kept", name: "Kept", cwd: harness.project.path, pid: 55,
        owner: "CherryTests", tags: [PersistentSessionTag.tab: tabID.uuidString]
    )
    harness.fake.sessions = [listed]
    _ = try await harness.control.list()
    let attachment = try #require(harness.hosting.attachment(for: listed))

    let adopted = workspace.attachHostedSession(attachment, info: listed)
    #expect(adopted.isPersistentLocalSession)
    #expect(adopted.hostedAttachment == nil)
    // A tab this app started keeps its tab id (its CHERRY_PROCESS_ID).
    #expect(adopted.id == tabID)
    #expect(adopted.title == "Kept")
    #expect(await harness.waitUntilAttached(adopted))
    #expect(harness.creates().isEmpty)
    #expect(adopted.persistentSession?.sessionID == "session-kept")
    #expect(adopted.hostedProgramProcessID == 55)
    // Attaching it again selects the same tab.
    #expect(workspace.attachHostedSession(attachment, info: listed) === adopted)

    // Another window attaches the same session without owning it: closing
    // that tab only disconnects.
    let viewer = other.attachHostedSession(attachment, info: listed)
    #expect(!viewer.isPersistentLocalSession)
    #expect(viewer.hostedAttachment == attachment)
    viewer.stop()
}

@Test @MainActor func restoringBringsBackPersistentTabsWithTheirKindAndDropsMissingSessions() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let running = WorkspaceSessionRecord(
        id: UUID(), kind: .command, title: "server", commandName: "server", launchCommand: "npm start",
        launchEnvironment: ["PORT": "3000"], workingDirectory: harness.project.path, restartOnExit: false,
        projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-running", owned: true)
    )
    // Saved before bindings recorded ownership: the session was started
    // for this tab (its cherry.tab tag), so the tab owns it.
    let ended = WorkspaceSessionRecord(
        id: UUID(), kind: .agent, title: "Claude", agentName: "Claude", launchCommand: "claude",
        workingDirectory: harness.project.path, projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-ended")
    )
    let missing = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Gone", workingDirectory: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-missing")
    )
    let otherHost = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Wiped", workingDirectory: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-old", sessionID: "session-running")
    )
    harness.fake.sessions = [
        HostedSessionInfo(id: "session-running", name: "server", cwd: harness.project.path, pid: 61, owner: "CherryTests"),
        HostedSessionInfo(
            id: "session-ended", name: "Claude", cwd: harness.project.path, state: .exited, exitCode: 2,
            owner: "CherryTests", tags: [PersistentSessionTag.tab: ended.id.uuidString]
        )
    ]
    let restorer = harness.restorer
    let result = await restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path,
        worktreeRoot: harness.project.path,
        records: [running, ended, missing, otherHost],
        workspace: workspace
    ))
    #expect(result.keptRecordIDs.isEmpty)
    #expect(result.sessions.map(\.id) == [running.id, ended.id])
    let command = try #require(result.sessions.first)
    let agent = try #require(result.sessions.last)
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(
        root: harness.project.path, sessions: [running, ended]
    ))
    #expect(command.isPersistentLocalSession)
    #expect(command.kind == .command)
    #expect(command.commandName == "server")
    #expect(workspace.commandSession(named: "server") === command)
    #expect(await harness.waitUntilAttached(command))
    #expect(command.hostedProgramProcessID == 61)
    #expect(agent.kind == .agent)
    // Ended while Cherry was closed: shown ended at once, with no adapter;
    // its final screen comes from the host.
    #expect(agent.state == .exited(2))
    #expect(agent.agentActivityState == .error)
    #expect(agent.persistentSessionEndedMessage == "Session ended (exit 2)")
    #expect(!agent.isAwaitingDeferredLaunch)
    #expect(harness.creates().isEmpty)
    #expect(await harness.fake.wait { agent.snapshot(range: 0..<agent.lineCount).contains("fake screen") })
    #expect(harness.requestIDs("screen") == ["session-ended"])
    #expect(!harness.attachCalls.contains { $0.contains("attach session-ended ") })

    // Restarting the ended agent starts it again with its saved command.
    #expect(workspace.restart(agent))
    #expect(await harness.waitUntilAttached(agent))
    #expect(harness.configurations.value.last?.startupCommand == "claude")
    #expect(harness.configurations.value.last?.processID == ended.id.uuidString)
    #expect(harness.requestIDs("remove").contains("session-ended"))

    // Without the helper nothing can come back yet: every record is kept.
    harness.installationProblem.value = "The cherry session client is missing."
    let kept = await restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path,
        worktreeRoot: harness.project.path,
        records: [running],
        workspace: workspace
    ))
    #expect(kept.sessions.isEmpty)
    #expect(kept.keptRecordIDs == [running.id])
}

// MARK: - Owning a session

@Test @MainActor func sessionsOfOtherAppsOrShownElsewhereAreOnlyAttachedAndClosingThemNeverEndsThem() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let other = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        other.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // Another app variant's tab, a `cherry new` session, and one of this
    // app's that a client (another terminal) shows.
    let otherApp = HostedSessionInfo(
        id: "session-other-app", name: "Theirs", cwd: harness.project.path, pid: 71,
        owner: "Cherry Sessions", tags: [PersistentSessionTag.tab: UUID().uuidString]
    )
    let fromCLI = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72)
    let shownElsewhere = HostedSessionInfo(
        id: "session-shown", name: "Shown", cwd: harness.project.path, pid: 73, clients: 1,
        owner: "CherryTests", tags: [PersistentSessionTag.tab: UUID().uuidString]
    )
    harness.fake.sessions = [otherApp, fromCLI, shownElsewhere]
    _ = try await harness.control.list()

    for info in [otherApp, fromCLI, shownElsewhere] {
        let label = Comment(rawValue: info.id)
        let attachment = try #require(harness.hosting.attachment(for: info))
        #expect(!harness.hosting.canAdopt(info), label)
        let tab = workspace.attachHostedSession(attachment, info: info)
        #expect(!tab.isPersistentLocalSession, label)
        #expect(tab.hostedAttachment == attachment, label)
        #expect(harness.hosting.owningTab(of: info.id) == nil, label)
        #expect(WorkspaceSessionRecord(session: tab, restoredRecord: nil).hosted?.owned == false, label)
        // The Sessions settings end a closed tab's session; this one is
        // not the tab's to end, so closing it only disconnects.
        workspace.close(tab)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
    #expect(harness.creates().isEmpty)

    // A session a tab owns stays that tab's after its program ended (the
    // tab shows its final screen): another window only attaches to it,
    // with a tab id of its own.
    let owner = other.addSession(title: "Owner")
    #expect(await harness.waitUntilAttached(owner))
    let endedSession = try #require(owner.persistentSession?.sessionID)
    harness.exit(endedSession, code: 1)
    #expect(await harness.fake.wait { owner.state == .exited(1) })
    #expect(harness.hosting.owningTab(of: endedSession) === owner)
    let endedInfo = try #require(harness.hosting.sessionInfo(endedSession))
    #expect(endedInfo.tags[PersistentSessionTag.tab] == owner.id.uuidString)
    let viewer = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: endedInfo)), info: endedInfo)
    #expect(!viewer.isPersistentLocalSession)
    #expect(viewer.id != owner.id)
    workspace.close(viewer)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!harness.requestIDs("remove").contains(endedSession))

    // Once a tab detached, keeping its session running, the session is
    // this app's to own again: attached from the sheet, it comes back as
    // that tab (same id, so its CHERRY_PROCESS_ID still names it).
    let closing = other.addSession(title: "Kept")
    #expect(await harness.waitUntilAttached(closing))
    let keptSession = try #require(closing.persistentSession?.sessionID)
    let closedID = closing.id
    other.close(closing, intent: .userDetachedTab)
    #expect(harness.hosting.owningTab(of: keptSession) == nil)
    #expect(!harness.hosting.hasOpenTab(withID: closedID))
    let keptInfo = try #require(harness.fake.sessions.first { $0.id == keptSession })
    let adopted = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: keptInfo)), info: keptInfo)
    #expect(adopted.isPersistentLocalSession)
    #expect(adopted.id == closedID)
    #expect(harness.hosting.owningTab(of: keptSession) === adopted)
    #expect(!harness.requestIDs("kill").contains(keptSession))
}

@Test @MainActor func restoringOwnsOnlySessionsTheTabOwnedAndNoOpenTabOwns() async throws {
    let harness = try PersistentHarness()
    let windowA = harness.workspace()
    let windowB = harness.workspace()
    var workspaces = [windowA, windowB]
    defer {
        workspaces.forEach { $0.closeAllSessions(intent: .windowClosed) }
        harness.cleanUp()
    }
    // Window A's tab runs a session; window B attaches to it from the sheet.
    let owner = windowA.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(owner))
    let sessionID = try #require(owner.persistentSession?.sessionID)
    let info = try #require(harness.hosting.sessionInfo(sessionID))
    let viewer = windowB.attachHostedSession(try #require(harness.hosting.attachment(for: info)), info: info)
    #expect(!viewer.isPersistentLocalSession)
    let savedA = windowA.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    let savedB = windowB.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    #expect(savedA.sessions.map(\.hosted?.owned) == [true])
    #expect(savedB.sessions.map(\.hosted?.owned) == [false])

    // Quit: the session keeps running. Relaunch, window B restoring first.
    windowA.closeAllSessions(intent: .appQuit)
    windowB.closeAllSessions(intent: .appQuit)
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.hosting.owningTab(of: sessionID) == nil)
    let restorer = harness.restorer
    func restore(_ record: WorktreeStateRecord, into workspace: TerminalWorkspace) async -> [TerminalSession] {
        workspaces.append(workspace)
        let result = await restorer(WorkspaceRestoreRequest(
            repositoryRoot: harness.project.path,
            worktreeRoot: harness.project.path,
            records: record.sessions.filter(\.isRestorable),
            workspace: workspace
        ))
        workspace.restoreSessions(result.sessions, from: record)
        return result.sessions
    }
    let relaunchedB = harness.workspace()
    let restoredViewer = try #require(await restore(savedB, into: relaunchedB).first)
    #expect(!restoredViewer.isPersistentLocalSession)
    #expect(restoredViewer.hostedAttachment?.sessionID == sessionID)
    #expect(restoredViewer.id == viewer.id)
    let relaunchedA = harness.workspace()
    let restoredOwner = try #require(await restore(savedA, into: relaunchedA).first)
    #expect(restoredOwner.isPersistentLocalSession)
    #expect(restoredOwner.id == owner.id)
    #expect(harness.hosting.owningTab(of: sessionID) === restoredOwner)
    #expect(await harness.waitUntilAttached(restoredOwner))

    // A record from before ownership was saved comes back owning the
    // session only if it was started for that tab.
    let legacyViewer = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Old viewer", workingDirectory: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID)
    )
    let legacy = try #require(await restore(
        WorktreeStateRecord(root: harness.project.path, sessions: [legacyViewer]), into: harness.workspace()
    ).first)
    #expect(!legacy.isPersistentLocalSession)
    // An owner record for a session another window's tab owns (or that tab
    // itself, duplicated) never makes a second owner, nor a second tab.
    var otherOwner = savedA.sessions[0]
    otherOwner.id = UUID()
    #expect(await restore(
        WorktreeStateRecord(root: harness.project.path, sessions: [otherOwner]), into: harness.workspace()
    ).isEmpty)
    #expect(await restore(savedA, into: harness.workspace()).isEmpty)
    #expect(harness.hosting.owningTab(of: sessionID) === restoredOwner)

    // Closing the attached tabs never ends the session; its owner still
    // follows the program.
    for workspace in workspaces where workspace !== relaunchedA {
        workspace.closeAllSessions(intent: .userClosedTab)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)
    harness.exit(sessionID, code: 4)
    #expect(await harness.fake.wait { restoredOwner.state == .exited(4) })
}

// MARK: - A session missing from the host's list

@Test @MainActor func aSessionBrieflyMissingFromTheHostsListKeepsItsTab() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve", autoRestart: true),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let sessionID = try #require(command.persistentSession?.sessionID)
    let listed = harness.fake.sessions

    // The daemon restarted and listed before the session's holder had
    // registered again: HostControl reports the session removed.
    harness.fake.sessions = listed.filter { $0.id != sessionID }
    let connections = harness.fake.connections.count
    harness.fake.dropAll()
    #expect(await harness.fake.wait {
        harness.fake.connections.count > connections
            && harness.control.state == .connected
            && !harness.control.sessions.contains { $0.id == sessionID }
    })
    harness.fake.sessions = listed
    try await Task.sleep(for: .milliseconds(900))
    #expect(command.isRunning)
    #expect(command.state == .live)
    #expect(command.persistentSession?.sessionID == sessionID)
    #expect(harness.hosting.boundTab(for: sessionID) === command)
    #expect(harness.creates().count == 1)
    #expect(harness.fake.requests("kill").isEmpty)
    #expect(harness.fake.requests("remove").isEmpty)

    // Missing again when checked: the program is gone with its session, and
    // the command starts again in a new one.
    harness.fake.sessions = listed.filter { $0.id != sessionID }
    harness.fake.dropAll()
    #expect(await harness.fake.wait(timeout: 10) {
        command.persistentSession.map { $0.sessionID != sessionID } ?? false && command.state == .live
    })
    #expect(harness.creates().count == 2)
}

@Test @MainActor func aSessionARestartedDaemonStillExpectsKeepsItsTabAndOneMissingFromACompleteListIsGone() async throws {
    var configuration = PersistentHarness.fastConfiguration
    // Never waited for: this host says which lists are complete.
    configuration.disappearanceConfirmationDelay = .seconds(30)
    configuration.pendingHoldersPollInterval = .milliseconds(50)
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    harness.fake.pendingHolders = 0
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve", autoRestart: true),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let sessionID = try #require(command.persistentSession?.sessionID)
    let listed = harness.fake.sessions

    // The daemon restarted, and the session's holder has not registered
    // again: the list says a holder is still expected. The tab keeps it.
    harness.fake.sessions = listed.filter { $0.id != sessionID }
    harness.fake.pendingHolders = 1
    let connections = harness.fake.connections.count
    harness.fake.dropAll()
    #expect(await harness.fake.wait {
        harness.fake.connections.count > connections && harness.control.state == .connected
            && harness.fake.requests("list").count >= 3
    })
    #expect(harness.control.sessions.contains { $0.id == sessionID })
    harness.fake.sessions = listed
    harness.fake.pendingHolders = 0
    try await Task.sleep(for: .milliseconds(300))
    #expect(command.isRunning)
    #expect(command.state == .live)
    #expect(command.persistentSession?.sessionID == sessionID)
    #expect(harness.creates().count == 1)

    // Missing from a complete list: gone at once (no fixed wait), and the
    // command starts again in a new session.
    harness.fake.sessions = listed.filter { $0.id != sessionID }
    harness.fake.dropAll()
    #expect(await harness.fake.wait(timeout: 10) {
        command.persistentSession.map { $0.sessionID != sessionID } ?? false && command.state == .live
    })
    #expect(harness.creates().count == 2)
}

// MARK: - Detaching never signals the program

@Test @MainActor func detachingAPersistentTabNeverSignalsItsProgram() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    let programPID: pid_t = 42 // what the fake host reports for its sessions
    let signalled = Recorder<[pid_t]>([])
    func open(_ workspace: TerminalWorkspace) async throws -> (TerminalSession, String) {
        let tab = workspace.addSession()
        #expect(await harness.waitUntilAttached(tab))
        #expect(tab.hostedProgramProcessID == programPID)
        #expect(tab.childProcessID == nil)
        tab.terminateNativeSession = { pid in
            signalled.value.append(pid)
            // Only the tab's own attach adapter may be hung up on.
            guard pid != programPID else { return }
            ShellProcessController.terminateNativeShellSession(anchorPID: pid)
        }
        return (tab, try #require(tab.persistentSession?.sessionID))
    }

    var detached: [String] = []
    for intent in [SessionCloseIntent.userDetachedTab, .windowClosed, .appQuit, .duplicateWindowTeardown] {
        let workspace = harness.workspace()
        let (_, sessionID) = try await open(workspace)
        workspace.closeAllSessions(intent: intent)
        detached.append(sessionID)
    }
    // A stop (detach) and a restart (the old session ends through its host).
    let workspace = harness.workspace()
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let (stopped, stoppedSession) = try await open(workspace)
    stopped.stop()
    detached.append(stoppedSession)
    let (restarted, _) = try await open(workspace)
    #expect(workspace.restart(restarted))
    #expect(await harness.fake.wait { harness.creates().count == 7 })

    // A detach hangs up on the tab's own adapter (when its tty is known
    // yet), never on its program.
    #expect(!signalled.value.contains(programPID))
    let detachedRunning = harness.fake.sessions.filter { detached.contains($0.id) && $0.isRunning }
    #expect(detachedRunning.count == detached.count)
    #expect(Set(harness.requestIDs("kill")).isDisjoint(with: detached))
}

// MARK: - Quit

@Test @MainActor func quittingThatEndsSessionsWaitsForThemWithinItsBound() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.terminationTimeout = .seconds(1)
    let harness = try PersistentHarness(configuration: configuration)
    defer { harness.cleanUp() }

    // End Sessions (or Settings › Sessions ending them).
    let window = harness.workspace()
    let tab = window.addSession()
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    #expect(window.persistentSessionsEnded(by: .appQuitEndingSessions).map(\.id) == [tab.id])
    window.closeAllSessions(intent: .appQuitEndingSessions)
    #expect(harness.hosting.hasPendingEnds)
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(3)))
    #expect(harness.requestIDs("kill") == [sessionID])
    #expect(harness.requestIDs("remove") == [sessionID])

    // A host that never confirms the exit: quitting waits no longer than
    // its bound, and the ending gives up without removing the session.
    harness.fake.killEndsSession = false
    let stuckWindow = harness.workspace()
    let stuck = stuckWindow.addSession()
    #expect(await harness.waitUntilAttached(stuck))
    let stuckSession = try #require(stuck.persistentSession?.sessionID)
    stuckWindow.closeAllSessions(intent: .appQuitEndingSessions)
    let started = ContinuousClock.now
    #expect(await !harness.hosting.waitForPendingEnds(timeout: .milliseconds(300)))
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(await harness.hosting.waitForPendingEnds(timeout: .seconds(3)))
    #expect(harness.requestIDs("kill").contains(stuckSession))
    #expect(!harness.requestIDs("remove").contains(stuckSession))
}

// MARK: - Starting a command whose adapter reconnects

@Test @MainActor func startingACommandWhoseAdapterReconnectsNeverEndsItsProgram() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.reconnectAttemptsBeforeDisconnected = 0
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "serve"),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let sessionID = try #require(command.persistentSession?.sessionID)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })

    // The adapter lost the host; the tab shows it is disconnected while a
    // new adapter settles.
    try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
        .write(to: try harness.statusFile(of: harness.attachCalls[0]))
    command.ingestNativeChildExit(exitCode: 1)
    #expect(command.state == .disconnected)
    #expect(command.isRunning)
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 })
    #expect(command.state == .disconnected)

    // Start (sidebar, idle command view) reconnects now; it never starts the
    // command again, which would end the running program.
    command.restartManagedCommandIfNeeded()
    #expect(await harness.fake.wait { harness.attachCalls.count == 3 })
    // Reconnect Now works in that window too.
    #expect(command.reconnectHostedSession())
    #expect(await harness.fake.wait { harness.attachCalls.count == 4 })
    #expect(harness.attachCalls.allSatisfy { $0.contains("attach \(sessionID) ") })
    #expect(command.persistentSession?.sessionID == sessionID)
    #expect(command.isRunning)
    #expect(harness.creates().count == 1)
    #expect(harness.fake.requests("kill").isEmpty)
}

// MARK: - Create failures

@Test @MainActor func aCreateTheHostRejectsFallsBackOnlyItsTabAndMissingDirectoriesAreReplaced() async throws {
    let harness = try PersistentHarness()
    let rejectNext = Recorder(true)
    harness.fake.respond = { request, _ in
        guard request.op == "create", rejectNext.value else { return nil }
        rejectNext.value = false
        return .answer(.error(code: "request_failed", message: "working directory /gone does not exist on the host"))
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // That tab runs natively; new tabs still run in the host.
    let rejected = workspace.addSession()
    #expect(await harness.fake.wait { !rejected.isPersistentLocalSession })
    #expect(rejected.isRunning)
    #expect(harness.status.localSessionsUnavailableReason == nil)
    let next = workspace.addSession()
    #expect(next.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(next))

    // A tab whose directory was deleted restarts where it started.
    let subdirectory = harness.project.appendingPathComponent("gone", isDirectory: true)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    next.ingestNativeWorkingDirectory(subdirectory.path)
    #expect(next.workingDirectory == subdirectory.path)
    try FileManager.default.removeItem(at: subdirectory)
    #expect(workspace.restart(next))
    #expect(await harness.fake.wait { harness.creates().count == 3 && next.state == .live })
    #expect(harness.creates().last?.string("cwd") == harness.project.path)
    #expect(next.isPersistentLocalSession)
}

@Test @MainActor func aCreateWhoseAnswerIsLostIsSentAgainAndASessionItStartedIsNeverLeftBehind() async throws {
    let harness = try PersistentHarness()
    let fake = harness.fake
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // The host starts the session, but the answer is lost with the
    // connection: the same request, sent again, returns that session.
    let answered = Recorder(0)
    fake.respond = { request, connection in
        guard request.op == "create" else { return nil }
        answered.value += 1
        guard answered.value == 1 else { return nil }
        _ = fake.defaultReply(to: request, on: connection)
        return .exit(stderr: "connection lost")
    }
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab, timeout: 10))
    #expect(tab.isPersistentLocalSession)
    let requests = harness.creates()
    #expect(requests.count == 2)
    #expect(Set(requests.compactMap { $0.string("request_id") }).count == 1)
    #expect(fake.sessions.filter { $0.tags[PersistentSessionTag.tab] == tab.id.uuidString }.count == 1)

    // No answer ever comes: the tab runs natively, and the session the
    // host started for it anyway is ended once the host can be listed.
    fake.respond = { request, connection in
        guard request.op == "create" else { return nil }
        _ = fake.defaultReply(to: request, on: connection)
        return .exit(stderr: "connection lost")
    }
    let lost = workspace.addSession()
    #expect(await harness.fake.wait(timeout: 10) { !lost.isPersistentLocalSession })
    #expect(lost.isRunning)
    let lostRequests = harness.creates().filter { json($0, "tags")[PersistentSessionTag.tab] == lost.id.uuidString }
    #expect(lostRequests.count == 2 * (1 + harness.hosting.configuration.lostCreateRetries))
    let requestIDs = Set(lostRequests.compactMap { $0.string("request_id") })
    #expect(requestIDs.count == 1)
    let lostSession = "session-\(requestIDs.first ?? "")"
    fake.respond = nil
    #expect(await harness.fake.wait(timeout: 5) { harness.requestIDs("remove").contains(lostSession) })
    #expect(harness.requestIDs("kill").contains(lostSession))
    #expect(harness.status.localSessionsUnavailableReason != nil)
    #expect(tab.isRunning)
    #expect(!harness.requestIDs("kill").contains(tab.persistentSession?.sessionID ?? ""))

    // The answer is lost, then the host cannot even be reached for the
    // next attempt: the session it may have started is still ended once it
    // can be reached again.
    fake.respond = { request, connection in
        guard request.op == "create" else { return nil }
        _ = fake.defaultReply(to: request, on: connection)
        fake.launchFailure = "cherry-host is restarting"
        return .exit(stderr: "connection lost")
    }
    let unreachable = TerminalSession(
        title: "Unreachable", subtitle: "", tint: .white, workingDirectory: harness.project.path,
        projectRoot: harness.project.path, persistentHosting: harness.hosting
    )
    defer { unreachable.stop() }
    #expect(await harness.fake.wait(timeout: 10) { !unreachable.isPersistentLocalSession })
    let unreachableRequests = harness.creates().filter {
        json($0, "tags")[PersistentSessionTag.tab] == unreachable.id.uuidString
    }
    #expect(unreachableRequests.count == 1)
    let unreachableSession = "session-\(unreachableRequests.first?.string("request_id") ?? "")"
    #expect(fake.sessions.contains { $0.id == unreachableSession })
    fake.respond = nil
    fake.launchFailure = nil
    #expect(await harness.fake.wait(timeout: 5) { harness.requestIDs("remove").contains(unreachableSession) })
}

@Test @MainActor func aTabWhoseSessionTheHostDoesNotStartInTimeRunsNativelyAndALateSessionIsEnded() async throws {
    var configuration = PersistentHarness.fastConfiguration
    configuration.creationTimeout = 0.3
    let harness = try PersistentHarness(configuration: configuration)
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let tab = workspace.addSession()
    tab.send(text: "echo late\n")
    #expect(await harness.fake.wait { held.isHeld })
    #expect(await harness.fake.wait(timeout: 3) { !tab.isPersistentLocalSession })
    #expect(tab.state == .live)
    #expect(tab.isRunning)
    #expect(harness.status.localSessionsUnavailableReason?.contains("did not start a session") == true)

    // The session arrives after all: no tab shows it, so it is ended.
    let info = HostedSessionInfo(id: "session-late", name: "Shell 1", cwd: harness.project.path, pid: 88, owner: "CherryTests")
    harness.fake.sessions = [info]
    held.answer(.created(info))
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains("session-late") })
    #expect(harness.requestIDs("kill") == ["session-late"])
    #expect(harness.fake.requests("send_input").isEmpty)
    // The host did answer: new tabs run in it again.
    #expect(harness.status.localSessionsUnavailableReason == nil)
}

@Test @MainActor func warmingUpConnectsToTheLocalHostBeforeAnyTab() async throws {
    let harness = try PersistentHarness()
    defer { harness.cleanUp() }
    harness.installationProblem.value = "Move Cherry to Applications first."
    harness.hosting.warmUp()
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.launches.isEmpty)
    harness.installationProblem.value = nil
    #expect(harness.hosting.refreshStatus() == nil)
    harness.hosting.warmUp()
    #expect(await harness.fake.wait { harness.control.state == .connected })
    #expect(harness.fake.launches.count == 1)
    #expect(harness.creates().isEmpty)
}

// MARK: - Auto-start

@Test @MainActor func autoStartStartsARestoredCommandWhoseSessionEndedWhileCherryWasClosed() async throws {
    let harness = try PersistentHarness()
    func canonicalDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let resolved = try #require(url.path.withCString { realpath($0, nil) })
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
    let root = try canonicalDirectory("cherry-persistent-autostart")
    let storeDirectory = try canonicalDirectory("cherry-persistent-autostart-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let command = ProjectCommandDefinition(name: "server", command: "serve", autoStart: true)
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .command, title: "server", commandName: "server", launchCommand: "serve",
        workingDirectory: root.path, projectRoot: root.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-ended", owned: true)
    )
    harness.fake.sessions = [HostedSessionInfo(
        id: "session-ended", name: "server", cwd: root.path, state: .exited, exitCode: 1, owner: "CherryTests"
    )]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path,
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [record])]
    ))
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
    let workspace = repository.activeWorkspace
    let tab = try #require(workspace.session(withID: record.id))
    #expect(tab.isPersistentLocalSession)
    #expect(await harness.fake.wait { tab.state == .exited(1) })

    // The command starts again in the same tab, in a new session; the one
    // that ended is removed.
    repository.autoStartInitialCommandsIfNeeded()
    #expect(await harness.fake.wait(timeout: 5) { harness.creates().count == 1 && tab.state == .live })
    #expect(tab.persistentSession?.sessionID != "session-ended")
    #expect(json(try #require(harness.creates().first), "tags")[PersistentSessionTag.tab] == record.id.uuidString)
    #expect(harness.requestIDs("remove").contains("session-ended"))
    #expect(workspace.commandSessions.map(\.id) == [record.id])
}
