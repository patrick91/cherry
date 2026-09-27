import AppKit
import CherryControl
import Combine
import Darwin
import Foundation
import Testing
@testable import Cherry

// Feature parity for local tabs that run as persistent sessions
// (docs/specs/multiplexer-default.md, "Feature parity"): pids, directory and
// title, bells and notifications, splits, MCP input and output, and program
// state, against the fake `cherry control` (FakeControlHelper) and attach
// adapter (HostedSessionFakeCLI). Nothing reaches a real cherry-host; see
// PersistentLocalSessionRealHostTests for that.

/// `fastConfiguration` with reconnects waiting `reconnect` (long: a lost
/// adapter stays lost for the test). Whether an adapter passes the program's
/// signals through is up to what it reports (`confirmAttached`).
@MainActor
private func parityConfiguration(
    reconnect: TimeInterval = 30,
    attemptsBeforeDisconnected: Int = 5
) -> PersistentLocalSessions.Configuration {
    var configuration = PersistentHarness.fastConfiguration
    configuration.reconnectDelay = (reconnect, reconnect)
    configuration.reconnectAttemptsBeforeDisconnected = attemptsBeforeDisconnected
    configuration.hostScreenReuseInterval = 0
    return configuration
}

@MainActor
private extension PersistentHarness {
    /// Pushes an event on the live control connection.
    func push(_ event: HostSessionEvent) {
        fake.connections.last(where: { !$0.isClosed })?.push(.event(event))
    }

    /// `session`'s latest attach adapter reports its live state, as a real
    /// one does once it attached: from then on (unless it reconnects or
    /// shows a viewport) it passes the program's signals through and the
    /// surface shows its screen.
    func confirmAttached(
        _ session: TerminalSession,
        viewport: Bool = false,
        reconnecting: Bool = false
    ) async throws {
        try await reportAdapter(of: session, viewport: viewport, reconnecting: reconnecting)
        let expected = HostedAdapterLiveStatus(viewport: viewport, reconnecting: reconnecting)
        #expect(await fake.wait { session.adapterLiveStatus == expected })
        #expect(session.readsContentFromHost == !expected.showsWholeScreen)
    }

    /// Writes `session`'s latest adapter's live state to its status file,
    /// once that adapter started.
    func reportAdapter(of session: TerminalSession, viewport: Bool = false, reconnecting: Bool = false) async throws {
        let sessionID = try #require(session.persistentSession?.sessionID)
        let launched = session.nativeExecLaunch.command ?? ""
        #expect(await fake.wait {
            self.attachCalls.contains { call in
                call.contains("attach \(sessionID) ")
                    && HostedSessionFakeCLI.statusFile(of: call).map { launched.contains($0.path) } == true
            }
        })
        let call = try #require(attachCalls.last { $0.contains("attach \(sessionID) ") })
        try HostedSessionFakeCLI.writeStatus(
            HostedSessionFakeCLI.attachedStatus(viewport: viewport, reconnecting: reconnecting),
            to: try statusFile(of: call)
        )
    }

    /// `session`'s attach adapter ends as when it lost the host: its
    /// program runs on, and the tab reconnects after the configured delay.
    func loseAdapter(of session: TerminalSession) async throws {
        let sessionID = try #require(session.persistentSession?.sessionID)
        #expect(await fake.wait { self.attachCalls.contains { $0.contains("attach \(sessionID) ") } })
        let call = try #require(attachCalls.last { $0.contains("attach \(sessionID) ") })
        try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
            .write(to: try statusFile(of: call))
        session.ingestNativeChildExit(exitCode: 1)
        #expect(session.isRunning)
    }

    func info(
        _ session: TerminalSession,
        pid: UInt32 = 42,
        title: String? = nil,
        pwd: String? = nil,
        foreground: HostedSessionForeground? = nil,
        clients: Int = 1
    ) throws -> HostedSessionInfo {
        let sessionID = try #require(session.persistentSession?.sessionID)
        return HostedSessionInfo(
            id: sessionID, name: session.title, cwd: project.path, pid: pid, title: title, pwd: pwd,
            foreground: foreground, clients: clients, owner: "CherryTests",
            tags: [PersistentSessionTag.tab: session.id.uuidString]
        )
    }
}

/// Records what port detection is asked about, and reports one listener
/// per process it can attribute (port 10000 + its root pid).
private final class RecordingServiceDetector: ServiceDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _roots: [Int32?] = []

    var roots: [Int32?] { lock.withLock { _roots } }

    func detectServices(processes: [InspectableProcess], includeUnattributed: Bool) async throws -> [ServiceRecord] {
        lock.withLock { _roots.append(contentsOf: processes.map(\.rootPID)) }
        return processes.compactMap { process in
            guard let root = process.rootPID else { return nil }
            let port = 10_000 + Int(root % 50_000)
            return ServiceRecord(
                processID: process.id, processName: process.name, kind: process.kind, pid: root, port: port,
                host: "127.0.0.1", url: "http://127.0.0.1:\(port)", attribution: .processTree,
                protocolGuess: nil, readiness: .bound, lastSeenAt: Date(),
                commandName: process.commandName, agentName: process.agentName
            )
        }
    }
}

/// A control server (the MCP's) for workspaces with persistent tabs. Also
/// used by PersistentLocalSessionRealHostTests.
@MainActor
final class ParityControlServer {
    let server: CherryControlServer
    let socketURL: URL
    private let suite: String

    init(
        workspace: TerminalWorkspace,
        serviceDetector: (any ServiceDetecting)? = nil
    ) throws {
        suite = "CherryTests.PersistentParity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AgentSettings(defaults: defaults)
        if let projectRoot = workspace.projectRoot { _ = settings.addProject(path: projectRoot) }
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        server = CherryControlServer(
            workspace: workspace, socketURL: socketURL, agentSettings: settings,
            serviceDetector: serviceDetector ?? RecordingServiceDetector()
        )
        server.start()
    }

    /// Routes requests like the app does: by the caller's process ancestry
    /// first (`callerWorkspace`), then to `active`.
    init(active: TerminalWorkspace, others: [TerminalWorkspace]) throws {
        suite = "CherryTests.PersistentParity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AgentSettings(defaults: defaults)
        let workspaces = [active] + others
        for workspace in workspaces {
            if let projectRoot = workspace.projectRoot { _ = settings.addProject(path: projectRoot) }
        }
        socketURL = URL(fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("control.sock")
        server = CherryControlServer(
            workspaceProvider: { active },
            noteStoreProvider: { nil },
            todoStoreProvider: { nil },
            chromeStateProvider: { nil },
            workspaceForProjectRootProvider: { root in workspaces.first { $0.projectRoot == root } },
            noteStoreForProjectRootProvider: { _ in nil },
            todoStoreForProjectRootProvider: { _ in nil },
            chromeStateForProjectRootProvider: { _ in nil },
            openProjectRootsProvider: { workspaces.compactMap(\.projectRoot) },
            socketURL: socketURL,
            agentSettings: settings,
            serviceDetector: RecordingServiceDetector()
        )
        server.start()
    }

    func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        let socketURL = socketURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try CherryControlClient(socketURL: socketURL).send(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func process(_ session: TerminalSession) async throws -> ProcessSummary {
        let response = try await send(.getProcessStatus(.init(processID: session.id.uuidString)))
        guard case .getProcessStatus(let status)? = response.result else {
            throw HostedSessionError.message("Expected getProcessStatus, got \(String(describing: response))")
        }
        return status.process
    }

    func stop() {
        server.stop()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

// MARK: - Program pid

@Test @MainActor func persistentTabsGiveMCPAndPortDetectionTheirProgramsPidButNeverAsTheirOwn() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let detector = RecordingServiceDetector()
    let control = try ParityControlServer(workspace: workspace, serviceDetector: detector)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    let tab = workspace.addSession(title: "Server")
    #expect(await harness.waitUntilAttached(tab))
    // The fake host's program pid; the tab's own process (its attach
    // adapter) is never named as the program.
    #expect(tab.hostedProgramProcessID == 42)
    #expect(tab.programProcessID == 42)
    #expect(tab.childProcessID == nil)

    // The host reports a new pid for the running program.
    harness.push(.changed(try harness.info(tab, pid: 4_242)))
    #expect(await harness.fake.wait { tab.programProcessID == 4_242 })

    // MCP reports it, and port detection is rooted at it.
    #expect(try await control.process(tab).pid == 4_242)
    let ports = try await control.send(.getProcessPorts(.init(processID: tab.id.uuidString)))
    guard case .getProcessPorts(let services)? = ports.result else {
        Issue.record("Expected getProcessPorts, got \(String(describing: ports))")
        return
    }
    #expect(detector.roots == [4_242])
    #expect(services.services.map(\.processID) == [tab.id.uuidString])
    #expect(services.services.map(\.pid) == [4_242])
    let bound = try await control.send(.waitForBoundPort(.init(processID: tab.id.uuidString, timeoutMilliseconds: 1_000)))
    guard case .waitForBoundPort(let boundResult)? = bound.result else {
        Issue.record("Expected waitForBoundPort, got \(String(describing: bound))")
        return
    }
    #expect(boundResult.service.pid == 4_242)
    #expect(boundResult.service.processID == tab.id.uuidString)

    // A tab attached to an SSH host's session never gets that machine's pid.
    let remote = workspace.attachHostedSession(HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-remote", sessionID: "remote-1", name: "Remote",
        remoteWorkingDirectory: "/srv", executablePath: harness.cli.executable.path
    ), launchShell: false)
    #expect(remote.programProcessID == nil)
    #expect(try await control.process(remote).pid == nil)

    // Once the program ended, there is no pid to report.
    let sessionID = try #require(tab.persistentSession?.sessionID)
    harness.exit(sessionID, code: 3)
    #expect(await harness.fake.wait { tab.state == .exited(3) })
    #expect(tab.programProcessID == nil)
    #expect(try await control.process(tab).pid == nil)
}

@Test @MainActor func mcpCallersRunningInAPersistentTabAreRoutedToItsWindow() async throws {
    let harness = try PersistentHarness()
    let callerWindow = harness.workspace()
    let otherRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-parity-other-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    // The frontmost window: unscoped requests go there unless the caller's
    // ancestry names a tab's program.
    let frontmost = TerminalWorkspace(projectRoot: otherRoot.path, createInitialSession: false)
    let control = try ParityControlServer(active: frontmost, others: [callerWindow])
    defer {
        control.stop()
        callerWindow.closeAllSessions(intent: .windowClosed)
        frontmost.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: otherRoot)
    }
    let tab = callerWindow.addSession(title: "Agent shell")
    #expect(await harness.waitUntilAttached(tab))
    // Detaching never signals the program's pid (here, this test's).
    tab.terminateNativeSession = { pid in
        guard pid != getpid() else {
            Issue.record("A detach signalled the program")
            return
        }
        ShellProcessController.terminateNativeShellSession(anchorPID: pid)
    }

    func routedRoot() async throws -> String? {
        let response = try await control.send(.listProcesses(.init()))
        guard case .listProcesses(let listed)? = response.result else {
            Issue.record("Expected listProcesses, got \(String(describing: response))")
            return nil
        }
        return listed.activeProjectRoot
    }
    #expect(try await routedRoot() == frontmost.projectRoot)

    // The caller (this test process, as an MCP server would be) runs inside
    // the tab's program, as far as its ancestry shows.
    harness.push(.changed(try harness.info(tab, pid: UInt32(getpid()))))
    #expect(await harness.fake.wait { tab.programProcessID == getpid() })
    #expect(try await routedRoot() == callerWindow.projectRoot)
}

// MARK: - Directory and title

@Test @MainActor func persistentTabsFollowTheProgramsDirectoryAndTitleWithoutRebuildingTheirAdapter() async throws {
    // The adapter passes OSC 7 and titles through as soon as it attached.
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let first = harness.project.appendingPathComponent("first dir", isDirectory: true)
    let second = harness.project.appendingPathComponent("second", isDirectory: true)
    for directory in [first, second] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let thisMac = try #require(HostedReportedDirectory.thisMacNames().first)
    func fileURI(_ url: URL) -> String {
        "file://\(thisMac)\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)"
    }

    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    try await harness.confirmAttached(tab)
    let launch = tab.nativeExecLaunch
    #expect(tab.nativeSurfaceWorkingDirectory == NSHomeDirectory())

    // Attached: the surface reports these (Ghostty's OSC 7 and title,
    // through the adapter). The host's copies, from the same output, are
    // not applied on top.
    harness.push(.changed(try harness.info(tab, title: "vim notes", pwd: fileURI(second))))
    try await Task.sleep(for: .milliseconds(200))
    #expect(tab.workingDirectory == harness.project.path)
    #expect(tab.title == "Shell 1")
    tab.ingestNativeWorkingDirectory(first.path)
    #expect(tab.workingDirectory == first.path)
    tab.ingestNativeTitle("vim notes")
    #expect(tab.title == "vim notes")

    // The adapter lost the host: the host's reports apply now, decoded.
    try await harness.loseAdapter(of: tab)
    harness.push(.changed(try harness.info(tab, title: "make build", pwd: fileURI(second))))
    #expect(await harness.fake.wait { tab.workingDirectory == second.path && tab.title == "make build" })
    // Another machine's directory (ssh inside the tab) is ignored; a plain
    // path (OSC 9;9, OSC 1337 CurrentDir) is This Mac's.
    harness.push(.changed(try harness.info(tab, title: "make build", pwd: "file://elsewhere.example/tmp")))
    try await Task.sleep(for: .milliseconds(200))
    #expect(tab.workingDirectory == second.path)
    harness.push(.changed(try harness.info(tab, title: "make build", pwd: first.path)))
    #expect(await harness.fake.wait { tab.workingDirectory == first.path })

    // None of this changes what the surface runs: a changed configuration
    // would rebuild it and start a second adapter.
    #expect(tab.nativeExecLaunch.command == launch.command)
    #expect(tab.nativeExecLaunch.environment == launch.environment)
    #expect(tab.nativeSurfaceWorkingDirectory == NSHomeDirectory())
    #expect(harness.attachCalls.count == 1)

    // New tabs and splits start in the tab's directory, in the host.
    let next = workspace.addSession()
    #expect(next.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(next))
    #expect(harness.creates().last?.string("cwd") == first.path)
    workspace.select(tab)
    #expect(workspace.canAddSplitPane(to: tab.id))
    let pane = try #require(workspace.splitDuplicateActiveTerminal())
    #expect(pane.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(pane))
    #expect(harness.creates().last?.string("cwd") == first.path)
    #expect(workspace.splitGroup(containing: tab.id)?.paneSessionIDs == [tab.id, pane.id])
    #expect(harness.creates().count == 3)
}

@Test @MainActor func aRestoredTabTakesTheTitleAndDirectoryItsProgramSetWhileCherryWasClosed() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let subdirectory = harness.project.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "~/project", titleSource: .system,
        workingDirectory: harness.project.path, projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-titled", owned: true)
    )
    harness.fake.sessions = [HostedSessionInfo(
        id: "session-titled", name: "~/project", cwd: harness.project.path, pid: 61,
        title: "htop", pwd: subdirectory.path, owner: "CherryTests"
    )]
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path, worktreeRoot: harness.project.path,
        records: [record], workspace: workspace
    ))
    workspace.restoreSessions(result.sessions, from: WorktreeStateRecord(root: harness.project.path, sessions: [record]))
    let tab = try #require(result.sessions.first)
    #expect(await harness.waitUntilAttached(tab))
    #expect(tab.workingDirectory == subdirectory.path)
    #expect(tab.title == "htop")
    #expect(tab.programProcessID == 61)
}

// MARK: - Bells, notifications and progress

@Test @MainActor func hostNotificationsForATabWhoseAdapterDoesNotShowThemTakeTheNativePathOnce() async throws {
    // The adapter never counts as passing them through here.
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }

    harness.push(.notification(id: sessionID, title: "Build", body: "finished"))
    #expect(await harness.fake.wait { tab.hasUnreadNotification })
    #expect(tab.lastNotification == TerminalNotificationRequest(title: "Build", body: "finished", source: .osc777))
    tab.clearUnreadNotification()
    // The adapter also passes it to the surface: shown once.
    tab.ingestNativeNotification(title: "Build", body: "finished")
    #expect(!tab.hasUnreadNotification)
    // Another one from the surface shows.
    tab.ingestNativeNotification(title: nil, body: "second")
    #expect(tab.hasUnreadNotification)
    tab.clearUnreadNotification()
    // The surface first, then the host's copy: once.
    tab.ingestNativeNotification(title: nil, body: "third")
    #expect(tab.hasUnreadNotification)
    tab.clearUnreadNotification()
    harness.push(.notification(id: sessionID, title: "", body: "third"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(!tab.hasUnreadNotification)

    // Bells ring once too.
    harness.push(.bell(id: sessionID))
    #expect(await harness.fake.wait { bells.value == 1 })
    tab.ingestNativeBell()
    #expect(bells.value == 1)

    // Progress comes only from the host.
    harness.push(.progress(id: sessionID, state: .set, value: 40))
    #expect(await harness.fake.wait { tab.progressReport == TerminalProgressReport(state: .set, value: 40) })
    harness.push(.progress(id: sessionID, state: .remove, value: nil))
    #expect(await harness.fake.wait { tab.progressReport == nil })

    // An agent's notification drives its attention state, as a native one's.
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    let agentSession = try #require(agent.persistentSession?.sessionID)
    harness.push(.notification(id: agentSession, title: "Claude", body: "Claude needs permission to run a tool"))
    #expect(await harness.fake.wait { agent.agentActivityState == .permission })
    #expect(agent.hasUnreadNotification)
}

@Test @MainActor func anAttachedAdapterShowsBellsAndNotificationsAndTheHostTakesOverWhenItIsGone() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    try await harness.confirmAttached(tab)
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }

    // Attached: the surface shows them; the host's copies are dropped.
    harness.push(.notification(id: sessionID, title: "", body: "from the program"))
    harness.push(.bell(id: sessionID))
    try await Task.sleep(for: .milliseconds(200))
    #expect(!tab.hasUnreadNotification)
    #expect(bells.value == 0)
    tab.ingestNativeNotification(title: nil, body: "from the program")
    tab.ingestNativeBell()
    #expect(tab.hasUnreadNotification)
    #expect(bells.value == 1)
    tab.clearUnreadNotification()
    // Progress still comes from the host.
    harness.push(.progress(id: sessionID, state: .indeterminate, value: nil))
    #expect(await harness.fake.wait { tab.progressReport?.state == .indeterminate })

    // Reconnecting: the host's are shown.
    try await harness.loseAdapter(of: tab)
    harness.push(.notification(id: sessionID, title: "Tests", body: "passed while reconnecting"))
    #expect(await harness.fake.wait { tab.hasUnreadNotification })
    #expect(tab.lastNotification?.body == "passed while reconnecting")
    // After the program ended, its progress is gone.
    harness.exit(sessionID, code: 3)
    #expect(await harness.fake.wait { tab.state == .exited(3) })
    #expect(tab.progressReport == nil)
}

@Test @MainActor func signalsFromBeforeATabFollowedItsSessionReachItWhenItDoes() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // Relaunch: the host hands over what the program signalled while no
    // app was connected, right after the first connection subscribed and
    // before any tab follows the session.
    let tabID = UUID()
    let listed = HostedSessionInfo(
        id: "session-kept", name: "Kept", cwd: harness.project.path, pid: 55,
        owner: "CherryTests", tags: [PersistentSessionTag.tab: tabID.uuidString]
    )
    harness.fake.sessions = [listed]
    let listing = try await harness.hosting.list()
    harness.push(.notification(id: "session-kept", title: "Deploy", body: "done while you were away"))
    harness.push(.progress(id: "session-kept", state: .set, value: 10))
    harness.push(.progress(id: "session-kept", state: .set, value: 90))
    try await Task.sleep(for: .milliseconds(200))

    let tab = workspace.attachHostedSession(listing.attachment(listed), info: listed)
    #expect(tab.isPersistentLocalSession)
    #expect(tab.id == tabID)
    #expect(await harness.fake.wait { tab.hasUnreadNotification })
    #expect(tab.lastNotification?.body == "done while you were away")
    #expect(tab.progressReport == TerminalProgressReport(state: .set, value: 90))
}

// MARK: - Splits

@Test @MainActor func persistentTerminalsSplitAndAttachedTabsNeverJoinASplit() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.waitUntilAttached(tab))
    let local = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72)
    harness.fake.sessions.append(local)
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: local)), info: local)
    #expect(!attached.isPersistentLocalSession)
    #expect(attached.hostedAttachment != nil)
    // A session of This Mac starts in the directory it reported.
    #expect(attached.workingDirectory == harness.project.path)
    workspace.select(tab)
    #expect(!workspace.splitActiveTerminal(with: attached))
    #expect(workspace.splitGroup(containing: tab.id) == nil)
    let plain = workspace.addSession(select: false)
    #expect(workspace.splitActiveTerminal(with: plain))
    #expect(workspace.splitGroup(containing: tab.id)?.paneSessionIDs == [tab.id, plain.id])
}

// MARK: - MCP

@Test @MainActor func mcpInputAndOutputReachAPersistentProgramWhoseAdapterIsNotAttached() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    try await harness.loseAdapter(of: tab)
    // The tab shows it is disconnected; its program runs.
    #expect(tab.state == .disconnected)
    let status = try await control.process(tab)
    #expect(status.state == "live")
    #expect(status.acceptsInput)
    #expect(status.pid == 42)

    // Input goes through the host, and says so.
    let sent = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo hosted")))
    guard case .sendProcessInput(let sentResult)? = sent.result else {
        Issue.record("Expected sendProcessInput, got \(String(describing: sent))")
        return
    }
    #expect(sentResult.sentBytes > 0)
    let delivered = try #require(harness.fake.requests("send_input").last)
    #expect(delivered.string("id") == sessionID)
    let data = try #require(delivered.string("data").flatMap { Data(base64Encoded: $0) })
    #expect(String(decoding: data, as: UTF8.self).contains("echo hosted"))

    // The host does not take it: nothing was sent, and the caller learns so.
    harness.fake.respond = { request, _ in
        request.op == "send_input" ? .answer(.error(code: "not_running", message: "session \(sessionID) is not running")) : nil
    }
    let refused = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo lost")))
    #expect(refused.error?.code == "input_not_delivered")
    #expect(refused.result == nil)
    harness.fake.respond = nil

    // Output is the host's screen, with its history.
    harness.fake.screenText = "$ echo hosted\nhosted\n$"
    let output = try await control.send(.getProcessOutput(.init(processID: tab.id.uuidString)))
    guard case .getProcessOutput(let lines)? = output.result else {
        Issue.record("Expected getProcessOutput, got \(String(describing: output))")
        return
    }
    #expect(lines.lines == ["$ echo hosted", "hosted", "$"])
    #expect(lines.screen == "primary")
    let raw = try await control.send(.getProcessRawOutput(.init(processID: tab.id.uuidString)))
    guard case .getProcessRawOutput(let rawResult)? = raw.result else {
        Issue.record("Expected getProcessRawOutput, got \(String(describing: raw))")
        return
    }
    #expect(rawResult.text == "$ echo hosted\nhosted\n$")
    let search = try await control.send(.searchProcessOutput(.init(processID: tab.id.uuidString, query: "hosted")))
    guard case .searchProcessOutput(let matches)? = search.result else {
        Issue.record("Expected searchProcessOutput, got \(String(describing: search))")
        return
    }
    #expect(matches.matches.map(\.lineNumber) == [0, 1])
    harness.fake.screenText = "vim"
    harness.fake.screenIsAlternate = true
    let alternate = try await control.send(.getProcessOutput(.init(processID: tab.id.uuidString)))
    guard case .getProcessOutput(let alternateLines)? = alternate.result else { return }
    #expect(alternateLines.lines == ["vim"])
    #expect(alternateLines.screen == "alternate")
    #expect(harness.fake.requests("screen").allSatisfy { $0.json["scrollback"] as? Bool == true })

    // Waiting for it to go idle follows its program, not the adapter.
    let waited = try await control.send(.waitForProcessIdle(.init(
        processID: tab.id.uuidString, requireNewOutput: false, quietMilliseconds: 0, timeoutMilliseconds: 2_000
    )))
    guard case .waitForProcessIdle(let idle)? = waited.result else {
        Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
        return
    }
    #expect(idle.reason == .idle)
    #expect(idle.output.lines == ["vim"])

    // A program that ended takes no input: nothing is sent, and the caller
    // learns so (it used to hear the byte count).
    harness.exit(sessionID, code: 3)
    #expect(await harness.fake.wait { tab.state == .exited(3) })
    let inputsBefore = harness.fake.requests("send_input").count
    let ended = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo late")))
    #expect(ended.error?.code == "process_not_accepting_input")
    #expect(harness.fake.requests("send_input").count == inputsBefore)
    // So does a tab attached to an SSH session while it is disconnected.
    let remote = workspace.attachHostedSession(HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-remote", sessionID: "remote-1", name: "Remote",
        remoteWorkingDirectory: "/srv", executablePath: harness.cli.executable.path
    ), launchShell: false)
    let disconnected = try await control.send(.sendProcessInput(.init(processID: remote.id.uuidString, text: "ls")))
    #expect(disconnected.error?.code == "process_not_accepting_input")
}

@Test @MainActor func mcpNoLongerFindsATerminalWhoseShellExitedCleanly() async throws {
    let harness = try PersistentHarness()
    harness.cleanExitMinimumRunTime = 0
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    #expect(await harness.waitUntilAttached(anchor))
    func spawn(_ title: String) async throws -> TerminalSession {
        let spawned = try await control.send(.spawnProcess(.init(kind: "terminal", title: title)))
        guard case .spawnProcess(let result)? = spawned.result else {
            throw HostedSessionError.message("Expected spawnProcess, got \(String(describing: spawned))")
        }
        let tab = try #require(workspace.sessions.first { $0.id.uuidString == result.process.id })
        #expect(await harness.waitUntilAttached(tab))
        return tab
    }

    // Its shell exited with status 0: the tab closed, and its id no longer
    // names a process.
    let done = try await spawn("Done")
    harness.exit(try #require(done.persistentSession?.sessionID), code: 0)
    #expect(await harness.fake.wait { !workspace.sessions.contains { $0 === done } })
    let gone = try await control.send(.getProcessStatus(.init(processID: done.id.uuidString)))
    #expect(gone.error?.code == "terminal_not_found")

    // Any other exit keeps the tab, which reports it.
    let failing = try await spawn("Failing")
    harness.exit(try #require(failing.persistentSession?.sessionID), code: 3)
    #expect(await harness.fake.wait { failing.state == .exited(3) })
    #expect(try await control.process(failing).state == "exit 3")
    let waited = try await control.send(.waitForProcessIdle(.init(
        processID: failing.id.uuidString, requireNewOutput: false, quietMilliseconds: 0, timeoutMilliseconds: 2_000
    )))
    guard case .waitForProcessIdle(let idle)? = waited.result else {
        Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
        return
    }
    #expect(idle.reason == .exited)

    // So does stop_process: the program stopped because it was asked to.
    let stopped = try await spawn("Stopped")
    let stop = try await control.send(.stopProcess(.init(processID: stopped.id.uuidString)))
    #expect(stop.error == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(workspace.sessions.contains { $0 === stopped })
    #expect(try await control.process(stopped).state == "exit 0")
}

@Test @MainActor func aSpawnedProcesssFirstInputIsQueuedUntilItsSessionExists() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // The request answers once the input reached the program, which it
    // can only once the session exists.
    async let spawning = control.send(.spawnProcess(.init(kind: "terminal", title: "Queued", text: "make test\n")))
    #expect(await harness.fake.wait { held.isHeld })
    let tab = try #require(workspace.sessions.first { $0.title == "Queued" })
    #expect(tab.isPersistentLocalSession)
    #expect(tab.isStartingPersistentSession)
    #expect(harness.fake.requests("send_input").isEmpty)

    let create = try #require(harness.creates().first)
    let info = HostedSessionInfo(
        id: "session-spawned", name: "Queued", cwd: harness.project.path, pid: 90, owner: "CherryTests",
        tags: create.json["tags"] as? [String: String] ?? [:]
    )
    harness.fake.sessions = [info]
    held.answer(.created(info))
    let spawned = try await spawning
    guard case .spawnProcess(let result)? = spawned.result else {
        Issue.record("Expected spawnProcess, got \(String(describing: spawned))")
        return
    }
    #expect(result.process.id == tab.id.uuidString)
    #expect(result.sentBytes > 0)
    #expect(await harness.waitUntilAttached(tab))
    #expect(harness.fake.requests("send_input").count == 1)
    let delivered = try #require(harness.fake.requests("send_input").first)
    #expect(delivered.string("id") == "session-spawned")
    let data = try #require(delivered.string("data").flatMap { Data(base64Encoded: $0) })
    #expect(String(decoding: data, as: UTF8.self).contains("make test"))
}

@Test @MainActor func inputQueuedWhileASessionIsCreatedSaysWhetherItReachedTheProgram() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        switch request.op {
        case "create": held.hold(request, on: connection)
        // The program ended as soon as it started.
        case "send_input": .answer(.error(code: "not_running", message: "session is not running"))
        default: nil
        }
    }
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }

    // The host refuses the queued input once the session exists: the
    // process is created, and says its first input did not arrive.
    async let spawning = control.send(.spawnProcess(.init(kind: "terminal", title: "Refused", text: "make test\n")))
    #expect(await harness.fake.wait { held.isHeld })
    let tab = try #require(workspace.sessions.first { $0.title == "Refused" })
    // MCP input to the same tab meanwhile waits as well, and learns so.
    async let sending = control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo later")))
    #expect(await harness.fake.wait { tab.isStartingPersistentSession })
    try await Task.sleep(for: .milliseconds(100))
    let create = try #require(harness.creates().first)
    let info = HostedSessionInfo(
        id: "session-refused", name: "Refused", cwd: harness.project.path, pid: 91, owner: "CherryTests",
        tags: create.json["tags"] as? [String: String] ?? [:]
    )
    harness.fake.sessions = [info]
    held.answer(.created(info))
    let spawned = try await spawning
    guard case .spawnProcess(let result)? = spawned.result else {
        Issue.record("Expected spawnProcess, got \(String(describing: spawned))")
        return
    }
    #expect(result.sentBytes == 0)
    let sent = try await sending
    #expect(sent.error?.code == "input_not_delivered")
    #expect(harness.fake.requests("send_input").count == 2)

    // A tab stopped before its session existed sends nothing, and says so.
    let second = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? second.hold(request, on: connection) : nil
    }
    let stopped = workspace.addSession(title: "Stopped", select: false)
    #expect(await harness.fake.wait { second.isHeld })
    async let stopping = control.send(.sendProcessInput(.init(processID: stopped.id.uuidString, text: "echo never")))
    try await Task.sleep(for: .milliseconds(200))
    let inputsBefore = harness.fake.requests("send_input").count
    stopped.stopProgram()
    let refused = try await stopping
    #expect(refused.error?.code == "input_not_delivered")
    #expect(refused.error?.message.contains("nothing was sent") == true)
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.fake.requests("send_input").count == inputsBefore)
}

@Test @MainActor func mcpLifecycleRequestsFollowTheCloseIntentsForPersistentTabs() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let anchor = workspace.addSession(title: "Anchor")
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(anchor))
    #expect(await harness.waitUntilAttached(tab))
    let first = try #require(tab.persistentSession?.sessionID)

    // restart_process ends the session and starts a new one in the same tab.
    let restarted = try await control.send(.restartProcess(.init(processID: tab.id.uuidString)))
    #expect(restarted.error == nil)
    #expect(await harness.fake.wait { tab.persistentSession.map { $0.sessionID != first } ?? false && tab.state == .live })
    #expect(harness.requestIDs("kill").contains(first))
    let second = try #require(tab.persistentSession?.sessionID)

    // stop_process ends the program on its host.
    let stopped = try await control.send(.stopProcess(.init(processID: tab.id.uuidString)))
    #expect(stopped.error == nil)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(second) })
    #expect(!tab.isRunning)
    // It ended because it was asked to: a clean exit, and reported as one.
    let stoppedStatus = try await control.process(tab)
    #expect(stoppedStatus.state == "exit 0")
    #expect(stoppedStatus.exitCode == 0)
    #expect(stoppedStatus.exitedAt != nil)
    #expect(stoppedStatus.pid == nil)

    // start_process starts it again, in a new session.
    let started = try await control.send(.startProcess(.init(processID: tab.id.uuidString)))
    #expect(started.error == nil)
    #expect(await harness.waitUntilAttached(tab))
    let third = try #require(tab.persistentSession?.sessionID)
    #expect(![first, second].contains(third))

    // close_process closes like the tab's close button: its session ends.
    let closed = try await control.send(.closeProcess(.init(processID: tab.id.uuidString)))
    #expect(closed.error == nil)
    #expect(await harness.fake.wait { harness.requestIDs("remove").contains(third) })
    #expect(workspace.sessions.map(\.id) == [anchor.id])
}

// MARK: - Program state

@Test @MainActor func runningAgentsFollowTheHostsProgramStateWhileTheirAdapterReconnects() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Codex", command: "codex"), projectRoot: harness.project.path)
    let other = workspace.addAgentSession(agent: AgentToolDefinition(name: "Amp", command: "amp"), projectRoot: harness.project.path)
    #expect(await harness.waitUntilAttached(agent))
    #expect(await harness.waitUntilAttached(other))
    #expect(Set(workspace.runningAgentSessions.map(\.id)) == [agent.id, other.id])

    // Its adapter lost the host: the agent still runs (and the menu bar,
    // which lists these, keeps it).
    try await harness.loseAdapter(of: agent)
    #expect(agent.state == .disconnected)
    #expect(agent.isProgramRunning)
    #expect(Set(workspace.runningAgentSessions.map(\.id)) == [agent.id, other.id])
    #expect(agent.hasRunningProcess())

    // A list shows the other agent ended (its exit event was missed): it
    // is no longer running.
    let otherSession = try #require(other.persistentSession?.sessionID)
    harness.fake.sessions = harness.fake.sessions.map { $0.id == otherSession ? $0.exited(code: 0, signal: nil) : $0 }
    _ = try await harness.control.list()
    #expect(await harness.fake.wait { !other.isProgramRunning })
    #expect(workspace.runningAgentSessions.map(\.id) == [agent.id])

    // The host reports the agent's exit.
    harness.exit(try #require(agent.persistentSession?.sessionID), code: 0)
    #expect(await harness.fake.wait { !agent.isRunning })
    #expect(workspace.runningAgentSessions.isEmpty)
}

// MARK: - The adapter's live state

@Test @MainActor func anAdapterPassesSignalsThroughOnlyOnceItReportsItselfAttached() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }

    // The adapter runs, but has not reported itself attached (a slow
    // helper, a daemon starting): the host's bells count, the screen comes
    // from the host, and MCP input goes through the host, which says it
    // took it.
    try await Task.sleep(for: .milliseconds(100))
    #expect(tab.adapterLiveStatus == nil)
    #expect(tab.readsContentFromHost)
    harness.push(.bell(id: sessionID))
    #expect(await harness.fake.wait { bells.value == 1 })
    let early = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo early")))
    #expect(early.error == nil)
    #expect(harness.fake.requests("send_input").count == 1)
    let earlyData = try #require(harness.fake.requests("send_input").first?.string("data").flatMap { Data(base64Encoded: $0) })
    #expect(String(decoding: earlyData, as: UTF8.self) == "echo early")

    // The host listing a client (this adapter, or any other) is no report
    // of this adapter's: nothing changes.
    harness.push(.changed(try harness.info(tab, clients: 2)))
    try await Task.sleep(for: .milliseconds(200))
    #expect(tab.readsContentFromHost)

    // Reported attached: at once (no settle time), the surface passes them
    // through and takes MCP input.
    try await harness.confirmAttached(tab)
    harness.push(.bell(id: sessionID))
    try await Task.sleep(for: .milliseconds(200))
    #expect(bells.value == 1)
    let later = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "echo later")))
    #expect(later.error == nil)
    #expect(harness.fake.requests("send_input").count == 1)

    // Every adapter launch reports for itself.
    try await harness.loseAdapter(of: tab)
    #expect(tab.adapterLiveStatus == nil)
    #expect(tab.reconnectHostedSession())
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 && tab.usesNativePTYBackend })
    #expect(tab.readsContentFromHost)
    harness.push(.bell(id: sessionID))
    #expect(await harness.fake.wait { bells.value == 2 })
    try await harness.confirmAttached(tab)
    harness.push(.bell(id: sessionID))
    try await Task.sleep(for: .milliseconds(200))
    #expect(bells.value == 2)

    // An adapter that reports itself attached as it starts (as the CLI does)
    // passes them through from then on.
    try harness.cli.reportAttach()
    let second = workspace.addSession(title: "Second")
    #expect(await harness.waitUntilAttached(second))
    #expect(await harness.fake.wait { second.adapterLiveStatus == HostedAdapterLiveStatus() })
    #expect(!second.readsContentFromHost)
}

@Test @MainActor func anAdapterShowingAViewportLeavesTheScreenToTheHostButPassesSignalsThrough() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shared")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }

    // Another, larger client shares the session: the adapter shows a
    // viewport of its screen. The screen comes from the host; the program's
    // signals and input still pass through the adapter.
    try await harness.confirmAttached(tab, viewport: true)
    harness.fake.screenText = "$ top\nwide output"
    let output = try await control.send(.getProcessOutput(.init(processID: tab.id.uuidString)))
    guard case .getProcessOutput(let lines)? = output.result else {
        Issue.record("Expected getProcessOutput, got \(String(describing: output))")
        return
    }
    #expect(lines.lines == ["$ top", "wide output"])
    harness.push(.bell(id: sessionID))
    try await Task.sleep(for: .milliseconds(200))
    #expect(bells.value == 0)
    let sent = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "q")))
    #expect(sent.error == nil)
    #expect(harness.fake.requests("send_input").isEmpty)

    // The other client left: the surface shows the whole screen again.
    try await harness.confirmAttached(tab)
    #expect(!tab.readsContentFromHost)
}

@Test @MainActor func anAdapterThatReconnectsByItselfKeepsItsSurfaceAndShowsTheBarOnlyWhenItLasts() async throws {
    var configuration = parityConfiguration(reconnect: 0.05)
    configuration.adapterReconnectingNoticeDelay = 1
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    try await harness.confirmAttached(tab)
    let launch = tab.nativeExecLaunch
    let bells = Recorder(0)
    tab.bellHandler = { _ in bells.value += 1 }
    // Every time the tab showed its reconnect bar.
    let bars = Recorder(0)
    let barSubscriptions = [
        tab.$isAdapterReconnecting.sink { if $0 { bars.value += 1 } },
        tab.$state.sink { if $0 == .disconnected { bars.value += 1 } },
    ]
    defer { barSubscriptions.forEach { $0.cancel() } }

    // A short reconnect, over before the notice delay: no bar ever shows.
    try await harness.confirmAttached(tab, reconnecting: true)
    try await harness.confirmAttached(tab)
    try await Task.sleep(for: .milliseconds(1_300))
    #expect(bars.value == 0)
    #expect(tab.state == .live)

    // The daemon restarted under the adapter, which reconnects by itself:
    // the tab keeps its surface and adapter, reads the program's screen and
    // takes its signals from the host, and routes input through the host.
    try await harness.confirmAttached(tab, reconnecting: true)
    #expect(tab.state == .live)
    #expect(!tab.isAdapterReconnecting)
    harness.push(.bell(id: sessionID))
    #expect(await harness.fake.wait { bells.value == 1 })
    tab.send(text: "ls")
    #expect(await harness.fake.wait { harness.fake.requests("send_input").count == 1 })
    let moved = harness.project.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    harness.push(.changed(try harness.info(tab, pwd: moved.path)))
    #expect(await harness.fake.wait { tab.workingDirectory == moved.path })

    // Reconnecting for longer: the tab shows its reconnect bar
    // (disconnected), while its program still counts as running.
    #expect(await harness.fake.wait { tab.state == .disconnected && tab.isAdapterReconnecting })
    #expect(tab.isRunning)
    let status = try await control.process(tab)
    #expect(status.state == "live")
    // Attached again: live, with the same adapter and surface.
    try await harness.confirmAttached(tab)
    #expect(await harness.fake.wait { tab.state == .live && !tab.isAdapterReconnecting })
    #expect(harness.attachCalls.count == 1)
    #expect(tab.nativeExecLaunch.command == launch.command)

    // Only an adapter that gives up and exits is launched again (a new
    // surface), as before.
    try await harness.loseAdapter(of: tab)
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 })
    #expect(tab.nativeExecLaunch.command != launch.command)
}

@Test @MainActor func anAttachedTabSaysItsAdapterReconnectsWhenThatLasts() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let local = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72, clients: 1)
    harness.fake.sessions.append(local)
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: local)), info: local)
    #expect(!attached.isPersistentLocalSession)
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-cli ") } })
    let call = try #require(harness.attachCalls.last { $0.contains("attach session-cli ") })
    let file = try harness.statusFile(of: call)

    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: file)
    #expect(await harness.fake.wait { attached.adapterLiveStatus == HostedAdapterLiveStatus() })
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: file)
    // Reported after the notice delay (2 s for attached tabs).
    #expect(await harness.fake.wait(timeout: 5) { attached.isAdapterReconnecting })
    #expect(attached.isRunning)
    #expect(HostedConnectionBarState(
        isRunning: attached.isRunning, status: attached.hostedAttachmentStatus, removedFromHost: false,
        canClose: true, reconnecting: attached.isAdapterReconnecting
    ).message == "Reconnecting…")
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: file)
    #expect(await harness.fake.wait { !attached.isAdapterReconnecting })
    #expect(harness.attachCalls.filter { $0.contains("attach session-cli ") }.count == 1)
}

@Test @MainActor func anAttachedTabsMCPInputGoesThroughItsHostWhileItsAdapterReconnects() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let local = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72, clients: 1)
    harness.fake.sessions.append(local)
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: local)), info: local)
    #expect(!attached.isPersistentLocalSession)
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-cli ") } })
    let call = try #require(harness.attachCalls.last { $0.contains("attach session-cli ") })
    let file = try harness.statusFile(of: call)
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: file)
    #expect(await harness.fake.wait { attached.adapterLiveStatus == HostedAdapterLiveStatus() })
    func send(_ text: String) async throws -> CherryControlResponse {
        try await control.send(.sendProcessInput(.init(processID: attached.id.uuidString, text: text)))
    }

    // Attached: the adapter takes MCP input (the host is not asked).
    let direct = try await send("pwd")
    #expect(direct.error == nil)
    #expect(harness.fake.requests("send_input").isEmpty)

    // The adapter lost its host and reconnects by itself, discarding what
    // reaches it meanwhile: MCP input goes to the program through the host,
    // at once (before the reconnect notice), and says it arrived.
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(reconnecting: true), to: file)
    #expect(await harness.fake.wait { attached.adapterLiveStatus?.reconnecting == true })
    #expect(attached.state == .live)
    let sent = try await send("ls")
    guard case .sendProcessInput(let result)? = sent.result else {
        Issue.record("Expected sendProcessInput, got \(String(describing: sent))")
        return
    }
    #expect(result.sentBytes > 0)
    let inputs = harness.fake.requests("send_input")
    #expect(inputs.count == 1)
    #expect(inputs.last?.string("id") == "session-cli")
    #expect(inputs.last?.string("data").flatMap { Data(base64Encoded: $0) } == Data("ls".utf8))

    // The host cannot take it either: MCP says it did not arrive.
    harness.fake.respond = { @Sendable request, _ in
        request.op == "send_input" ? .answer(.error(code: "not_running", message: "session is not running")) : nil
    }
    let failed = try await send("ls")
    #expect(failed.error?.code == "input_not_delivered")
    harness.fake.respond = nil

    // Attached again: the adapter takes it again.
    try HostedSessionFakeCLI.writeStatus(HostedSessionFakeCLI.attachedStatus(), to: file)
    #expect(await harness.fake.wait { attached.adapterLiveStatus?.reconnecting == false })
    _ = try await send("pwd")
    #expect(harness.fake.requests("send_input").count == 2)
    #expect(harness.attachCalls.filter { $0.contains("attach session-cli ") }.count == 1)
}

@Test @MainActor func anAttachedTabTakesItsSessionsModesOnlyWhileItsHostKeepsThemCurrent() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    func local(alternate: Bool, flags: UInt32) -> HostedSessionInfo {
        HostedSessionInfo(
            id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72, clients: 1,
            alternateScreen: alternate, kittyKeyboardFlags: flags
        )
    }
    harness.fake.sessions.append(local(alternate: true, flags: 8))
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(
        try #require(harness.hosting.attachment(for: local(alternate: true, flags: 8))), info: local(alternate: true, flags: 8)
    )
    #expect(await harness.fake.wait { harness.attachCalls.contains { $0.contains("attach session-cli ") } })
    #expect(attached.usesAlternateScreen)
    #expect(attached.keyboardProtocolFlags == 8)

    // Its adapter runs; the program leaves the alternate screen and pops
    // its flags: the tab follows the host's report, never the one it was
    // attached with.
    harness.push(.changed(local(alternate: false, flags: 0)))
    #expect(await harness.fake.wait { !attached.usesAlternateScreen && attached.keyboardProtocolFlags == 0 })
    harness.push(.changed(local(alternate: true, flags: 8)))
    #expect(await harness.fake.wait { attached.usesAlternateScreen && attached.keyboardProtocolFlags == 8 })

    // Its host's control connection is down: what it reported last may be
    // stale, so it no longer applies.
    harness.control.disconnect()
    #expect(!attached.usesAlternateScreen)
    #expect(attached.keyboardProtocolFlags == 0)
    #expect(attached.isRunning)
}

@Test @MainActor func anAdapterThatNeverReportsItselfAttachedFailsHoweverLongItRan() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(reconnect: 0.05, attemptsBeforeDisconnected: 1))
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    try await harness.confirmAttached(tab)

    // The daemon hangs: each adapter runs without ever attaching, then
    // gives up. However long one ran, it failed: the second in a row shows
    // the tab disconnected (it used to count as settled after 3 s).
    try await harness.loseAdapter(of: tab)
    #expect(await harness.fake.wait { harness.attachCalls.count == 2 })
    #expect(tab.state == .live)
    try await Task.sleep(for: .milliseconds(3_200))
    #expect(tab.state == .live)
    try await harness.loseAdapter(of: tab)
    #expect(tab.state == .disconnected)
    #expect(await harness.fake.wait { harness.attachCalls.count == 3 })
    // The next one runs without reporting: still disconnected.
    try await Task.sleep(for: .milliseconds(500))
    #expect(tab.state == .disconnected)
    #expect(tab.isRunning)

    // It attached: live again, and its failures start over.
    try await harness.confirmAttached(tab)
    #expect(await harness.fake.wait { tab.state == .live })
    try await harness.loseAdapter(of: tab)
    #expect(tab.state == .live)
    #expect(await harness.fake.wait { harness.attachCalls.count == 4 })
}

@Test @MainActor func anAgentMessageWhoseEnterDoesNotArriveSaysItWasTypedButNotSubmitted() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    try await harness.loseAdapter(of: agent)
    harness.fake.screenText = "> "
    // The text arrives; the Enter sent after it does not.
    // (Runs on the fake host's thread.)
    harness.fake.respond = { @Sendable request, _ in
        guard request.op == "send_input",
              let encoded = request.string("data"),
              Data(base64Encoded: encoded) == Data("\r".utf8)
        else { return nil }
        return .answer(.error(code: "not_running", message: "session is not running"))
    }
    let sent = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello")))
    #expect(sent.error?.code == "input_partially_delivered")
    #expect(sent.error?.message.contains("nothing was sent") == false)
    #expect(harness.fake.requests("send_input").count == 2)
}

/// Counts the fake host's `send_input` requests (on its thread), and fails
/// the `failing`th one.
private final class FailingInputPart: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    let failing: Int

    init(failing: Int) {
        self.failing = failing
    }

    func reply(to request: FakeControlHelper.Request) -> FakeControlHelper.Reply? {
        guard request.op == "send_input" else { return nil }
        let number = lock.withLock { () -> Int in
            seen += 1
            return seen
        }
        guard number == failing else { return nil }
        return .answer(.error(code: "not_running", message: "session is not running"))
    }
}

@Test @MainActor func mcpInputTheHostTookOnlyAFirstPartOfSaysHowMuchWasTyped() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    // No adapter takes input: the host types it.
    try await harness.loseAdapter(of: tab)

    // Longer than two host requests (64 KiB each); the third one fails.
    let part = HostProtocol.maxInputBytes
    let input = Data((0..<(2 * part + 100)).map { UInt8(0x61 + $0 % 26) })
    let failing = FailingInputPart(failing: 3)
    harness.fake.respond = { request, _ in failing.reply(to: request) }
    let sent = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, rawBase64: input.base64EncodedString())))
    let error = try #require(sent.error)
    #expect(error.code == "input_partially_delivered")
    #expect(error.message.contains("Only the first \(2 * part) of \(input.count) bytes"), Comment(rawValue: error.message))
    #expect(error.message.contains("session is not running"), Comment(rawValue: error.message))
    #expect(!error.message.contains("nothing was sent"))
    // Each part was sent once, in order; nothing was sent again.
    let parts = harness.fake.requests("send_input").compactMap { $0.string("data").flatMap { Data(base64Encoded: $0) } }
    #expect(parts.count == 3)
    #expect(parts.reduce(Data(), +) == input)

    // Input the host refuses from its first part: nothing was typed.
    harness.fake.respond = { request, _ in
        request.op == "send_input" ? .answer(.error(code: "not_running", message: "session is not running")) : nil
    }
    let refused = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, rawBase64: input.base64EncodedString())))
    #expect(refused.error?.code == "input_not_delivered")
    #expect(refused.error?.message.contains("nothing was sent") == true)
}

/// Counts the fake host's `send_input` requests (on its thread), and stops
/// the helper on the `failing`th one: that part was sent, but its answer
/// is lost.
private final class LostInputPart: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0
    let failing: Int

    init(failing: Int) {
        self.failing = failing
    }

    func reply(to request: FakeControlHelper.Request) -> FakeControlHelper.Reply? {
        guard request.op == "send_input" else { return nil }
        let number = lock.withLock { () -> Int in
            seen += 1
            return seen
        }
        guard number == failing else { return nil }
        return .exit(stderr: "cherry: connection lost")
    }
}

@Test @MainActor func mcpInputWhosePartsAnswerWasLostDoesNotSayThatPartWasNotSent() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    // No adapter takes input: the host types it.
    try await harness.loseAdapter(of: tab)

    // Three host requests (64 KiB each at most); the connection is lost
    // once the second was sent.
    let part = HostProtocol.maxInputBytes
    let input = Data((0..<(2 * part + 100)).map { UInt8(0x61 + $0 % 26) })
    let lost = LostInputPart(failing: 2)
    harness.fake.respond = { request, _ in lost.reply(to: request) }
    let sent = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, rawBase64: input.base64EncodedString())))
    let error = try #require(sent.error)
    #expect(error.code == "input_partially_delivered")
    #expect(error.message.contains("Only the first \(part) of \(input.count) bytes"), Comment(rawValue: error.message))
    #expect(
        error.message.contains("The \(part) bytes after them were sent, but the host's answer was lost, so they may or may not have been typed"),
        Comment(rawValue: error.message)
    )
    #expect(error.message.contains("the last 100 bytes were not sent"), Comment(rawValue: error.message))
    #expect(!error.message.contains("the rest was not sent"))
    #expect(!error.message.contains("nothing was sent"))
    // The third part was not sent.
    #expect(harness.fake.requests("send_input").count == 2)
}

@Test @MainActor func inputQueuedWhileTheSessionIsCreatedThatArrivesInPartSaysHowMuchWasTyped() async throws {
    let harness = try PersistentHarness()
    let held = FakeHeldRequest()
    let failing = FailingInputPart(failing: 2)
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : failing.reply(to: request)
    }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Queued")
    #expect(await harness.fake.wait { held.isHeld })

    let input = Data(repeating: 0x78, count: HostProtocol.maxInputBytes + 10)
    async let sending: Void = tab.sendControlInput(input, raw: true)
    #expect(await harness.fake.wait { tab.isStartingPersistentSession })
    let info = HostedSessionInfo(id: "session-queued", name: "Queued", cwd: harness.project.path, pid: 88)
    harness.fake.sessions = [info]
    held.answer(.created(info))
    do {
        try await sending
        Issue.record("Expected the input to arrive only in part")
    } catch let error as TerminalSession.ControlInputError {
        guard case .partiallyDelivered(let delivered, let reason, let unconfirmed) = error else {
            Issue.record("Expected partiallyDelivered, got \(error)")
            return
        }
        #expect(delivered == HostProtocol.maxInputBytes)
        #expect(reason.contains("session is not running"), Comment(rawValue: reason))
        // The host refused the part that failed: none of it was typed.
        #expect(unconfirmed == 0)
    }
    #expect(harness.fake.requests("send_input").count == 2)
}

@Test func mcpNamesEachWayInputCanFailToArrive() {
    typealias Failure = TerminalSession.ControlInputError
    let partial = CherryControlServer.inputError(
        for: Failure.partiallyDelivered(deliveredBytes: 65_536, reason: "the host went away"),
        processName: "Worker", totalBytes: 70_000
    )
    #expect(partial.code == "input_partially_delivered")
    #expect(partial.message.hasPrefix("Only the first 65536 of 70000 bytes"))
    #expect(partial.message.contains("the host went away"))
    #expect(partial.message.contains("the rest was not sent"))
    #expect(!partial.message.contains("nothing was sent"))
    // The part that failed was sent but its answer was lost: it may have
    // been typed, and the message does not claim it was not.
    let lost = CherryControlServer.inputError(
        for: Failure.partiallyDelivered(deliveredBytes: 65_536, reason: "connection lost", unconfirmedBytes: 65_536),
        processName: "Worker", totalBytes: 140_000
    )
    #expect(lost.code == "input_partially_delivered")
    #expect(lost.message.hasPrefix("Only the first 65536 of 140000 bytes"), Comment(rawValue: lost.message))
    #expect(lost.message.contains("The 65536 bytes after them were sent, but the host's answer was lost, so they may or may not have been typed"), Comment(rawValue: lost.message))
    #expect(lost.message.contains("the last 8928 bytes were not sent"), Comment(rawValue: lost.message))
    #expect(!lost.message.contains("the rest was not sent"))
    #expect(!lost.message.contains("nothing was sent"))
    // The part that failed was the last one: nothing after it.
    let lostLast = CherryControlServer.inputError(
        for: Failure.partiallyDelivered(deliveredBytes: 65_536, reason: "connection lost", unconfirmedBytes: 4_464),
        processName: "Worker", totalBytes: 70_000
    )
    #expect(lostLast.message.contains("The 4464 bytes after them were sent"), Comment(rawValue: lostLast.message))
    #expect(!lostLast.message.contains("were not sent"), Comment(rawValue: lostLast.message))
    // An agent message's text typed before a later part: counted in.
    let afterText = CherryControlServer.inputError(
        for: Failure.partiallyDelivered(deliveredBytes: 10, reason: "lost"),
        processName: "Claude", totalBytes: 20, alreadySent: 5
    )
    #expect(afterText.message.hasPrefix("Only the first 15 of 25 bytes"))
    let enter = CherryControlServer.inputError(
        for: Failure.notDelivered("session is not running"), processName: "Claude", totalBytes: 1, alreadySent: 5
    )
    #expect(enter.code == "input_partially_delivered")
    #expect(enter.message.contains("The text (5 bytes) was typed"))
    let none = CherryControlServer.inputError(
        for: Failure.notDelivered("session is not running"), processName: "Worker", totalBytes: 3
    )
    #expect(none.code == "input_not_delivered")
    #expect(none.message.contains("nothing was sent"))
    let ended = CherryControlServer.inputError(for: Failure.notAccepting(state: "exited"), processName: "Worker", totalBytes: 3)
    #expect(ended.code == "process_not_accepting_input")
}

// MARK: - Host screen reads

@Test @MainActor func waitingForAReconnectingTabToGoIdleReadsTheHostsScreenOncePerPollInterval() async throws {
    var configuration = parityConfiguration(attemptsBeforeDisconnected: 0)
    configuration.hostScreenPollInterval = 0.5
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    try await harness.loseAdapter(of: tab)
    harness.fake.screenText = "$ make\nbuilding"
    let before = harness.fake.requests("screen").count
    let waited = try await control.send(.waitForProcessIdle(.init(
        processID: tab.id.uuidString, requireNewOutput: false, quietMilliseconds: 1_500, timeoutMilliseconds: 4_000
    )))
    guard case .waitForProcessIdle(let idle)? = waited.result else {
        Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
        return
    }
    #expect(idle.reason == .idle)
    #expect(idle.output.lines == ["$ make", "building"])
    // The loop turns every 50 ms; the whole history is read about once
    // per 0.5 s (it used to be read on almost every turn).
    let reads = harness.fake.requests("screen").count - before
    #expect(reads >= 2)
    #expect(reads <= 6)
}

@Test @MainActor func loopsWatchingAReconnectingTabReadOnlyTheHostsLastLinesAndNeverTakeTheSwitchForOutput() async throws {
    var configuration = parityConfiguration(attemptsBeforeDisconnected: 0)
    configuration.hostScreenPollInterval = 0.2
    configuration.hostScreenRecentLines = 4
    let harness = try PersistentHarness(configuration: configuration)
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Worker")
    #expect(await harness.waitUntilAttached(tab))
    try await harness.loseAdapter(of: tab)
    let history = (1...20).map { "line \($0)" }
    harness.fake.screenText = history.joined(separator: "\n")

    // The whole history, for a caller that needs it.
    await tab.refreshContentFromHostIfNeeded()
    #expect(tab.lineCount == 20)
    let version = tab.outputVersion
    let whole = harness.fake.requests("screen").count

    // A loop that watches the screen asks for the last lines only; the same
    // last lines are no new output, and the history stays.
    await tab.refreshContentFromHostIfNeeded(maximumAge: 0, recentOnly: true)
    let recent = try #require(harness.fake.requests("screen").last)
    #expect(harness.fake.requests("screen").count == whole + 1)
    #expect(recent.json["max_lines"] as? Int == 4)
    #expect(recent.json["scrollback"] as? Bool == true)
    #expect(tab.outputVersion == version)
    #expect(tab.lineCount == 20)

    // New output shows in the last lines: it counts, and the tab's lines
    // are those last lines until a caller needs the history again.
    harness.fake.screenText = (history + ["line 21"]).joined(separator: "\n")
    await tab.refreshContentFromHostIfNeeded(maximumAge: 0, recentOnly: true)
    #expect(tab.outputVersion == version + 1)
    #expect(tab.snapshot(range: 0..<tab.lineCount).last == "line 21")
    await tab.refreshContentFromHostIfNeeded(maximumAge: 0)
    #expect(harness.fake.requests("screen").last?.json["max_lines"] == nil)
    #expect(tab.lineCount == 21)
    #expect(tab.outputVersion == version + 1)

    // Waiting for it to go idle polls the last lines only, then reads the
    // whole history once for its answer.
    let before = harness.fake.requests("screen").count
    let waited = try await control.send(.waitForProcessIdle(.init(
        processID: tab.id.uuidString, requireNewOutput: false, quietMilliseconds: 600, timeoutMilliseconds: 4_000
    )))
    guard case .waitForProcessIdle(let idle)? = waited.result else {
        Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
        return
    }
    #expect(idle.reason == .idle)
    #expect(idle.output.totalLines == 21)
    #expect(idle.output.lines.last == "line 21")
    let reads = harness.fake.requests("screen").dropFirst(before)
    #expect(reads.contains { $0.json["max_lines"] as? Int == 4 })
    #expect(reads.filter { $0.json["max_lines"] == nil }.count <= 2)
}

@Test @MainActor func hostedTabsTakeTheAlternateScreenAndKeyboardFlagsTheirHostReports() async throws {
    let harness = try PersistentHarness(configuration: parityConfiguration(attemptsBeforeDisconnected: 0))
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    try await harness.confirmAttached(agent)
    #expect(!agent.usesAlternateScreen)
    #expect(agent.keyboardProtocolFlags == 0)
    func modes(alternate: Bool?, flags: UInt32?) throws -> HostedSessionInfo {
        let info = try harness.info(agent)
        return HostedSessionInfo(
            id: info.id, name: info.name, cwd: info.cwd, pid: info.pid, clients: 1, owner: info.owner, tags: info.tags,
            alternateScreen: alternate, kittyKeyboardFlags: flags
        )
    }

    // The surface shows the program (its adapter parses the modes for
    // Ghostty, not for Cherry): the host's report is what counts.
    harness.push(.changed(try modes(alternate: true, flags: 31)))
    #expect(await harness.fake.wait { agent.usesAlternateScreen && agent.keyboardProtocolFlags == 31 })
    #expect(agent.isEnhancedKeyboardProtocolActive)
    #expect(try await control.process(agent).usesAlternateScreen == true)
    // MCP input is encoded for those flags (a Tab when every key is an
    // escape code), also while the host takes it.
    try await harness.loseAdapter(of: agent)
    try await agent.sendControlInput(Data([0x09]), raw: false)
    let sent = try #require(harness.fake.requests("send_input").last?.string("data").flatMap { Data(base64Encoded: $0) })
    #expect(sent == Data("\u{1B}[9u".utf8))

    // An older host that does not report them: the screen read decides.
    harness.push(.changed(try modes(alternate: nil, flags: nil)))
    harness.fake.screenIsAlternate = false
    #expect(await harness.fake.wait { agent.keyboardProtocolFlags == 0 })
    await agent.refreshContentFromHostIfNeeded()
    #expect(!agent.usesAlternateScreen)

    // After the program ended, nothing the host reported applies.
    harness.push(.changed(try modes(alternate: true, flags: 1)))
    #expect(await harness.fake.wait { agent.keyboardProtocolFlags == 1 })
    harness.exit(try #require(agent.persistentSession?.sessionID), code: 0)
    #expect(await harness.fake.wait { !agent.isRunning })
    #expect(agent.keyboardProtocolFlags == 0)
    #expect(!agent.isEnhancedKeyboardProtocolActive)

    // A tab attached to a hosted session takes them from its session.
    let local = HostedSessionInfo(
        id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 72, clients: 1,
        alternateScreen: true, kittyKeyboardFlags: 8
    )
    harness.fake.sessions.append(local)
    _ = try await harness.control.list()
    let attached = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: local)), info: local)
    #expect(!attached.isPersistentLocalSession)
    #expect(attached.usesAlternateScreen)
    #expect(attached.keyboardProtocolFlags == 8)
}

// MARK: - Tabs attached to a session of This Mac

@Test @MainActor func tabsAttachedToASessionOfThisMacGetItsPidAndTheOwnersWindowWinsCallerRouting() async throws {
    let harness = try PersistentHarness()
    let ownerWindow = harness.workspace()
    let roots = (0..<2).map { _ in
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-parity-attached-\(UUID().uuidString)", isDirectory: true)
    }
    for root in roots {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let viewerWindow = TerminalWorkspace(projectRoot: roots[0].path, createInitialSession: false, backendPolicy: harness.policy)
    let frontmost = TerminalWorkspace(projectRoot: roots[1].path, createInitialSession: false)
    // The viewer's window comes first in the window order.
    let control = try ParityControlServer(active: frontmost, others: [viewerWindow, ownerWindow])
    defer {
        control.stop()
        viewerWindow.closeAllSessions(intent: .windowClosed)
        ownerWindow.closeAllSessions(intent: .windowClosed)
        frontmost.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
    func neverSignalsThisProcess(_ session: TerminalSession) {
        session.terminateNativeSession = { pid in
            guard pid != getpid() else {
                Issue.record("A detach signalled the program")
                return
            }
            ShellProcessController.terminateNativeShellSession(anchorPID: pid)
        }
    }

    // A session the CLI created: attached, not owned; its program's pid
    // comes from the host's list.
    let cli = HostedSessionInfo(id: "session-cli", name: "CLI", cwd: harness.project.path, pid: 77, clients: 1)
    harness.fake.sessions.append(cli)
    _ = try await harness.control.list()
    let attached = viewerWindow.attachHostedSession(try #require(harness.hosting.attachment(for: cli)), info: cli)
    #expect(!attached.isPersistentLocalSession)
    #expect(attached.hostedAttachment != nil)
    #expect(attached.programProcessID == 77)
    #expect(attached.childProcessID == nil)
    // Detaching forgets it (the tab no longer shows the program).
    attached.stop()
    #expect(attached.programProcessID == nil)

    // A window that views another window's tab's session: MCP callers
    // inside that program go to the window that runs it.
    let owner = ownerWindow.addSession(title: "Agent shell")
    #expect(await harness.waitUntilAttached(owner))
    neverSignalsThisProcess(owner)
    let ownerInfo = try harness.info(owner, pid: UInt32(getpid()))
    harness.fake.sessions = harness.fake.sessions.map { $0.id == ownerInfo.id ? ownerInfo : $0 }
    harness.push(.changed(ownerInfo))
    #expect(await harness.fake.wait { owner.programProcessID == getpid() })
    let view = viewerWindow.attachHostedSession(
        try #require(harness.hosting.attachment(for: ownerInfo)), info: ownerInfo
    )
    neverSignalsThisProcess(view)
    #expect(!view.isPersistentLocalSession)
    #expect(view.programProcessID == getpid())
    let response = try await control.send(.listProcesses(.init()))
    guard case .listProcesses(let listed)? = response.result else {
        Issue.record("Expected listProcesses, got \(String(describing: response))")
        return
    }
    #expect(listed.activeProjectRoot == ownerWindow.projectRoot)

    // Another machine's session never gives a pid.
    let remote = viewerWindow.attachHostedSession(HostedSessionAttachment(
        host: try .ssh("devbox"), hostID: "host-remote", sessionID: "remote-1", name: "Remote",
        remoteWorkingDirectory: "/srv", executablePath: harness.cli.executable.path
    ), info: HostedSessionInfo(id: "remote-1", name: "Remote", cwd: "/srv", pid: 99))
    #expect(remote.programProcessID == nil)
}
