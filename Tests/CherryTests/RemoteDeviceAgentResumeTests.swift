import CherryControl
import Foundation
import Testing
@testable import Cherry

// A device's agent tabs resume their conversations as This Mac's do
// (WorkspaceRestoreAgentResumeTests), with the CLIs' files read on that Mac
// by `sh -s` scripts (DeviceAgentConversations). Here the scripts run in
// This Mac's /bin/sh with a temporary HOME standing in for the device's,
// never the user's ~/.claude or ~/.codex. And a device's open tab whose
// session its host reports lost (that Mac restarted) says so ("Ended when
// Studio restarted") instead of showing an exit.

/// What a lock keeps (the scripts run off the main actor).
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Runs a device's script as its `sh -s` would, here, with `home` as HOME.
private func runAsDevice(_ script: String, home: URL, environment: [String: String] = [:]) -> RemoteDeviceShell.DataOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        return RemoteDeviceShell.DataOutput(status: 255, standardOutput: Data(), standardError: "\(error)")
    }
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RemoteDeviceShell.DataOutput(
        status: process.terminationStatus, standardOutput: data, standardError: String(decoding: message, as: UTF8.self)
    )
}

/// A device whose HOME is `home`: its scripts run here. While `reachable`
/// says no, it answers as ssh does for a Mac that cannot be reached.
private func device(
    home: URL,
    environment: [String: String] = [:],
    reachable: Locked<Bool> = Locked(true),
    scripts: Locked<[String]> = Locked([])
) -> DeviceAgentConversations {
    DeviceAgentConversations(machine: "Studio") { script in
        scripts.value.append(script)
        guard reachable.value else {
            return RemoteDeviceShell.DataOutput(
                status: 255, standardOutput: Data(), standardError: "ssh: connect to host studio port 22: Connection timed out"
            )
        }
        return runAsDevice(script, home: home, environment: environment)
    }
}

/// The device's folders, as `AgentConversations` names them (the helpers
/// that write the CLIs' files take one).
private func folders(of home: URL) -> AgentConversations {
    AgentConversations(
        claudeConfigDirectory: home.appendingPathComponent(".claude", isDirectory: true),
        codexHome: home.appendingPathComponent(".codex", isDirectory: true)
    )
}

/// A program that runs another under it: `/bin/sh` waiting on a `sleep`.
private func programWithAChild() async throws -> (parent: Process, child: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "/bin/sleep 60; :"]
    try process.run()
    let parent = process.processIdentifier
    for _ in 0..<100 {
        if let child = ShellProcessController.enumerateProcesses().first(where: { $0.parentPID == parent })?.pid {
            return (process, child)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    process.terminate()
    throw HostedSessionError.message("the stand-in's child did not start")
}

private func found<Value>(_ answer: DeviceAgentConversations.Answer<Value>) -> Value? {
    if case .answered(let value) = answer { return value }
    return nil
}

private func isUnreachable<Value>(_ answer: DeviceAgentConversations.Answer<Value>) -> Bool {
    if case .unreachable = answer { return true }
    return false
}

// MARK: - The scripts

@Test func RemoteDeviceAgentResumeReadsClaudeCodesRegistryThereByThisMacsRules() async throws {
    let home = try canonicalTemporaryDirectory("cherry-device-claude")
    let (program, child) = try await programWithAChild()
    defer {
        program.terminate()
        program.waitUntilExit()
        try? FileManager.default.removeItem(at: home)
    }
    let mac = folders(of: home)
    let studio = device(home: home)
    let root = program.processIdentifier
    let session = UUID().uuidString.lowercased()

    // Nothing registered.
    #expect(found(await studio.claudeSession(runningUnder: root)) == .some(nil))
    // Claude Code runs under the tab's program: its file names the session.
    try registerClaudeSession(session, pid: child, in: mac)
    #expect(found(await studio.claudeSession(runningUnder: root)) == session)
    // A file whose pid is not its name's, or written before its process
    // started (an earlier process with the same pid), is not that one's.
    let sessions = mac.claudeConfigDirectory.appendingPathComponent("sessions", isDirectory: true)
    try Data(#"{"pid":1,"sessionId":"\#(UUID().uuidString)","startedAt":\#(Int(Date().timeIntervalSince1970 * 1000))}"#.utf8)
        .write(to: sessions.appendingPathComponent("\(root).json"))
    #expect(found(await studio.claudeSession(runningUnder: root)) == session)
    try registerClaudeSession(session, pid: child, startedAt: Date().addingTimeInterval(-3_600), in: mac)
    #expect(found(await studio.claudeSession(runningUnder: root)) == .some(nil))
    // A link is not read.
    let elsewhere = home.appendingPathComponent("elsewhere.json")
    try Data(#"{"pid":\#(child),"sessionId":"\#(session)","startedAt":\#(Int(Date().timeIntervalSince1970 * 1000))}"#.utf8)
        .write(to: elsewhere)
    try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(child).json"))
    try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("\(child).json"), withDestinationURL: elsewhere)
    #expect(found(await studio.claudeSession(runningUnder: root)) == .some(nil))
    try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(child).json"))

    // That Mac's CLAUDE_CONFIG_DIR moves the folder, and so does the tab's own.
    let moved = home.appendingPathComponent("config", isDirectory: true)
    let movedFolders = AgentConversations(claudeConfigDirectory: moved, codexHome: mac.codexHome)
    try registerClaudeSession(session, pid: child, in: movedFolders)
    #expect(found(await device(home: home, environment: ["CLAUDE_CONFIG_DIR": moved.path]).claudeSession(runningUnder: root)) == session)
    #expect(found(await studio.applying(environment: ["CLAUDE_CONFIG_DIR": moved.path]).claudeSession(runningUnder: root)) == session)
    #expect(found(await studio.claudeSession(runningUnder: root)) == .some(nil))

    // Its conversation, while its transcript has something in it.
    #expect(found(await studio.claudeHasConversation(session)) == false)
    try writeClaudeTranscript(session, contents: "", in: mac)
    #expect(found(await studio.claudeHasConversation(session)) == false)
    try writeClaudeTranscript(session, in: mac)
    #expect(found(await studio.claudeHasConversation(session)) == true)
    #expect(found(await studio.claudeHasConversation("not-a-uuid")) == false)
}

@Test func RemoteDeviceAgentResumeFindsCodexsThreadThereByTheTabsLine() async throws {
    let home = try canonicalTemporaryDirectory("cherry-device-codex")
    defer { try? FileManager.default.removeItem(at: home) }
    let mac = folders(of: home)
    let studio = device(home: home)
    let tab = UUID()
    let older = UUID().uuidString.lowercased()
    let newer = UUID().uuidString.lowercased()
    #expect(found(await studio.codexThread(launchedInTab: tab)) == .some(nil))
    try writeCodexRollout(thread: older, tab: tab, modified: Date().addingTimeInterval(-600), in: mac)
    try writeCodexRollout(thread: newer, tab: tab, modified: Date().addingTimeInterval(-60), in: mac)
    // Newer still: a subagent's (it quotes its parent's line), a user's
    // message quoting it, and another tab's.
    try writeCodexRollout(thread: UUID().uuidString.lowercased(), source: ["subagent": "review"], tab: tab, modified: Date(), in: mac)
    try writeCodexRollout(thread: UUID().uuidString.lowercased(), tab: tab, role: "user", modified: Date(), in: mac)
    try writeCodexRollout(thread: UUID().uuidString.lowercased(), tab: UUID(), modified: Date(), in: mac)
    #expect(found(await studio.codexThread(launchedInTab: tab)) == newer)
    // Made before the tab's agent last started: not that launch's.
    #expect(found(await studio.codexThread(launchedInTab: tab, createdSince: Date().addingTimeInterval(-30))) == .some(nil))
    // CODEX_HOME there moves it.
    let moved = home.appendingPathComponent("codex-home", isDirectory: true)
    let movedThread = UUID().uuidString.lowercased()
    try writeCodexRollout(
        thread: movedThread, tab: tab, modified: Date(),
        in: AgentConversations(claudeConfigDirectory: mac.claudeConfigDirectory, codexHome: moved)
    )
    #expect(found(await device(home: home, environment: ["CODEX_HOME": moved.path]).codexThread(launchedInTab: tab)) == movedThread)
    #expect(found(await studio.applying(environment: ["CODEX_HOME": moved.path]).codexThread(launchedInTab: tab)) == movedThread)
}

@Test func RemoteDeviceAgentResumeTakesTheDevicesClockAndTellsAnUnreachableMacFromNothingFound() async throws {
    let tab = UUID()
    let marker = AgentConversations.codexTabMarker(tab)
    let thread = UUID().uuidString.lowercased()
    let line = AgentCLILaunch.instructionLine(processID: tab.uuidString, hasSkill: false)
    let lines = [
        #"{"type":"session_meta","payload":{"id":"\#(thread)","source":"cli"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"\#(line)"}]}}"#,
    ].joined(separator: "\n") + "\n"
    // That Mac's clock is an hour behind This Mac's. The tab's agent
    // started a minute ago (This Mac's time) and the thread 30 s ago
    // (that Mac's): it is the launch's.
    let answeredAt = Date()
    let deviceNow = answeredAt.timeIntervalSince1970 - 3_600
    func body(created: TimeInterval) -> Data {
        Data("""
        codex \(Int(deviceNow - 10)) \(Int(created)) \(Data(lines.utf8).base64EncodedString())
        now \(Int(deviceNow))

        """.utf8)
    }
    let launch = answeredAt.addingTimeInterval(-60)
    #expect(DeviceAgentConversations.codexThread(in: body(created: deviceNow - 30), marker: marker, createdSince: launch, answeredAt: answeredAt) == thread)
    // A thread made 5 minutes ago there is an earlier launch's.
    #expect(DeviceAgentConversations.codexThread(in: body(created: deviceNow - 300), marker: marker, createdSince: launch, answeredAt: answeredAt) == nil)

    // ps(1)'s elapsed times.
    #expect(DeviceAgentConversations.elapsedSeconds("05:12") == 312)
    #expect(DeviceAgentConversations.elapsedSeconds("01:02:03") == 3_723)
    #expect(DeviceAgentConversations.elapsedSeconds("03-02:20:53") == 267_653)
    #expect(DeviceAgentConversations.elapsedSeconds("soon") == nil)
    #expect(DeviceAgentConversations.elapsedSeconds("1:2:3:4") == nil)

    // A Mac that cannot be asked, or one Cherry no longer knows, is not a
    // Mac without the conversation; a script that ran and found nothing is.
    let home = try canonicalTemporaryDirectory("cherry-device-unreachable")
    defer { try? FileManager.default.removeItem(at: home) }
    let reachable = Locked(false)
    let studio = device(home: home, reachable: reachable)
    #expect(isUnreachable(await studio.claudeHasConversation(thread)))
    #expect(isUnreachable(await studio.codexThread(launchedInTab: tab)))
    #expect(isUnreachable(await DeviceAgentConversations(machine: "Gone") { _ in nil }.claudeSession(runningUnder: 1)))
    let timedOut = DeviceAgentConversations(machine: "Slow") { _ in
        RemoteDeviceShell.DataOutput(status: 1, standardOutput: Data(), standardError: "", timedOut: true)
    }
    #expect(isUnreachable(await timedOut.claudeHasConversation(thread)))
    reachable.value = true
    #expect(found(await studio.claudeHasConversation(thread)) == false)
    #expect(DeviceAgentConversations.body(of: RemoteDeviceShell.DataOutput(status: 127, standardOutput: Data(), standardError: "sh: not found")) == Data())
}

// MARK: - A device's tabs

/// A device's hosting on a fake control (`OfflineHarness`'s, in
/// RemoteDeviceTests): the tabs' Mac is "Studio".
@MainActor
private final class DeviceHarness {
    let fake = FakeControlHelper()
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let hosting: PersistentHostSessions
    let store: WorkspaceStateStore
    let directory: URL
    let home: URL
    let host: HostedSessionHost
    let reachable = Locked(true)
    let scripts = Locked<[String]>([])
    let projectKey = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    private let suite: String

    init() throws {
        directory = try canonicalTemporaryDirectory("cherry-device-resume-store")
        home = try canonicalTemporaryDirectory("cherry-device-resume-home")
        store = WorkspaceStateStore(directory: directory)
        host = try HostedSessionHost.ssh("studio")
        cli = try HostedSessionFakeCLI()
        let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
        self.suite = suite
        let executable = cli.executable
        control = HostControl(
            host: host,
            clientProvider: { HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: [:]) }) },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.terminationTimeout = .seconds(2)
        configuration.reconnectDelay = (0.05, 0.2)
        configuration.adapterExitHostReportWait = 0.2
        let control = control
        hosting = PersistentHostSessions.remote(
            profile: .remote(host: host, displayName: "Studio"),
            installationID: UUID(),
            remoteShell: "/bin/zsh",
            control: { control },
            installationUnavailableReason: { nil },
            status: PersistentSessionsStatus(),
            instanceLock: nil,
            terminalColors: { nil },
            configuration: configuration
        )
        hosting.endedSessionsStore = store
    }

    var conversations: DeviceAgentConversations {
        device(home: home, reachable: reachable, scripts: scripts)
    }

    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(
            projectRoot: projectKey, createInitialSession: false,
            backendPolicy: .remote(hosting, settings: { .native }, hostReconnects: nil, agentConversations: conversations)
        )
    }

    func waitUntilAttached(_ session: TerminalSession) async -> Bool {
        await fake.wait { session.persistentSession != nil && session.state == .live }
    }

    /// The host reports `pid` as the program of `tab`'s session.
    func reportProgram(of tab: TerminalSession, pid: Int32) async throws -> Bool {
        let sessionID = try #require(tab.persistentSession?.sessionID)
        let info = try #require(fake.sessions.first { $0.id == sessionID })
        let running = HostedSessionInfo(
            id: info.id, name: info.name, cwd: info.cwd, command: info.command, pid: UInt32(pid),
            owner: info.owner, tags: info.tags, createdAt: info.createdAt
        )
        fake.sessions = fake.sessions.map { $0.id == sessionID ? running : $0 }
        fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(running)))
        return await fake.wait { tab.remoteProgramProcessID == pid }
    }

    /// The command lines of `tab`'s Creates, as its shell there runs them.
    func lines(of tab: TerminalSession) -> [String] {
        fake.requests("create")
            .filter { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.tab] == tab.id.uuidString }
            .compactMap { ($0.json["command"] as? [String])?.last }
    }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: home)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func RemoteDeviceAgentResumeAnOpenTabOfAMacThatRestartedSaysSoAndItsAgentsResume() async throws {
    let harness = try DeviceHarness()
    let workspace = harness.workspace()
    let program = try standInProgram()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        program.terminate()
        program.waitUntilExit()
    }
    let mac = folders(of: harness.home)
    let claude = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude", arguments: ""), projectRoot: harness.projectKey
    )
    let codex = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "codex", arguments: ""), projectRoot: harness.projectKey
    )
    let shell = workspace.addSession(title: "Shell")
    let other = workspace.addSession(title: "Other")
    for tab in [claude, codex, shell, other] {
        #expect(await harness.waitUntilAttached(tab))
    }
    #expect(claude.remoteMachineName == "Studio")

    // Claude Code there reports a turn: Cherry reads its session there,
    // under the program the host reports (never a pid of This Mac's).
    #expect(try await harness.reportProgram(of: claude, pid: program.processIdentifier))
    let session = UUID().uuidString.lowercased()
    try registerClaudeSession(session, pid: program.processIdentifier, in: mac)
    claude.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    #expect(await harness.fake.wait { claude.agentConversation?.id == session })
    #expect(WorkspaceSessionRecord(session: claude, restoredRecord: nil).agentConversation
        == AgentConversationRecord(cli: "claudeCode", id: session))
    // A report while that read waits, or within the reads' interval, reads
    // no more (each is a script over ssh).
    let reads = harness.scripts.value.count
    claude.applyProgramStatus([ProgramStatus(state: .idle, app: "claude-code")])
    try await Task.sleep(for: .milliseconds(1_500))
    #expect(harness.scripts.value.count == reads)
    try writeClaudeTranscript(session, in: mac)
    // Codex there started with Cherry's line naming its tab.
    let thread = UUID().uuidString.lowercased()
    try writeCodexRollout(thread: thread, tab: codex.id, modified: Date(), in: mac)

    // Studio restarts: its daemon starts again, finds the holders of all
    // but one of these sessions killed, and lists none of them.
    let ids = try [claude, codex, shell, other].map { try #require($0.persistentSession?.sessionID) }
    harness.fake.sessions = harness.fake.sessions.filter { !ids.contains($0.id) }
    harness.fake.lostSessionIDs = Set(ids.dropLast())
    harness.fake.dropAll()
    #expect(await harness.fake.wait { harness.control.state != .connected })
    harness.control.reconnectNow()
    #expect(await harness.fake.wait(timeout: 10) { [claude, codex, shell, other].allSatisfy { !$0.isRunning } })

    // The lost ones say Studio restarted, as tabs restored after it do, and
    // name no session; the one it did not report lost ended as before.
    for tab in [claude, codex, shell] {
        #expect(tab.systemSessionEnd == SystemSessionEnd.hostRestart)
        #expect(tab.persistentSessionEndedMessage == "Ended when Studio restarted")
        #expect(tab.persistentSession == nil)
        let record = WorkspaceSessionRecord(session: tab, restoredRecord: nil)
        #expect(record.systemEnd == SystemSessionEnd.hostRestart)
        #expect(record.hosted == nil && record.exitStatus == nil)
    }
    #expect(other.systemSessionEnd == nil)
    #expect(other.state == .exited(1))
    // The agents' conversations are still there: Resume.
    #expect(await harness.fake.wait { claude.conversationToResume?.id == session && codex.conversationToResume?.id == thread })
    #expect(shell.conversationToResume == nil)
    #expect(WorkspaceSessionRecord(session: codex, restoredRecord: nil).agentConversation
        == AgentConversationRecord(cli: "codex", id: thread))

    // Resume starts each there in its conversation.
    #expect(harness.lines(of: claude) == ["claude"])
    #expect(claude.restart())
    #expect(codex.restart())
    #expect(await harness.fake.wait { harness.lines(of: claude).count == 2 && harness.lines(of: codex).count == 2 })
    #expect(harness.lines(of: claude).last == "claude '--resume' '\(session)'")
    #expect(harness.lines(of: codex).last == "codex 'resume' '\(thread)'")
    #expect(claude.systemSessionEnd == nil && claude.conversationToResume == nil)
}

@Test @MainActor func RemoteDeviceAgentResumeARestoredTabAsksItsMacOnceItAnswers() async throws {
    let harness = try DeviceHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let mac = folders(of: harness.home)
    let session = UUID().uuidString.lowercased()
    try writeClaudeTranscript(session, in: mac)
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .agent, title: "Claude", agentName: "Claude", launchCommand: "claude",
        launchWorkingDirectory: "/Users/me/app", workingDirectory: "/Users/me/app", projectRoot: harness.projectKey,
        systemEnd: .hostRestart,
        agentConversation: AgentConversationRecord(cli: "claudeCode", id: session)
    )
    // Saved ended: it comes back while Studio cannot be reached.
    harness.reachable.value = false
    let tab = workspace.makeSystemEndedSession(record: record, ended: .hostRestart)
    #expect(tab.persistentSessionEndedMessage == "Ended when Studio restarted")
    #expect(await harness.fake.wait { !harness.scripts.value.isEmpty })
    #expect(tab.isLookingForConversationToResume)
    #expect(tab.conversationToResume == nil)
    // Studio answers: it is asked again, and still has the conversation.
    harness.reachable.value = true
    _ = try await harness.control.list()
    #expect(await harness.fake.wait { tab.conversationToResume?.id == session })
    #expect(!tab.isLookingForConversationToResume)
    #expect(harness.scripts.value.count == 2)
}
