import CherryControl
import Foundation
import Testing
@testable import Cherry

// A device's agent tabs resume their conversations as This Mac's do
// (WorkspaceRestoreAgentResumeTests): the one that Mac's `cherry host
// transcript --locate` last named (AgentConversationLocator.device, whose
// script WorkspaceRestoreAgentResumeTests runs; a stand-in answers here). And
// a device's open tab whose session its host reports lost (that Mac
// restarted) says so ("Ended when Studio restarted") instead of showing an
// exit.

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
    let host: HostedSessionHost
    let conversations = StandInConversations()
    let projectKey = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    private let suite: String

    init() throws {
        directory = try canonicalTemporaryDirectory("cherry-device-resume-store")
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

    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(
            projectRoot: projectKey, createInitialSession: false,
            backendPolicy: .remote(hosting, settings: { .native }, hostReconnects: nil, agentConversations: conversations.locator)
        )
    }

    func waitUntilAttached(_ session: TerminalSession) async -> Bool {
        await fake.wait { session.persistentSession != nil && session.state == .live }
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
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func RemoteDeviceAgentResumeAnOpenTabOfAMacThatRestartedSaysSoAndItsAgentsResume() async throws {
    let harness = try DeviceHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
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

    // Studio names each agent's conversation: Claude Code's as it reports
    // a turn, Codex's after its first message.
    let session = UUID().uuidString.lowercased()
    let thread = UUID().uuidString.lowercased()
    let claudeID = try #require(claude.persistentSession?.sessionID)
    let codexID = try #require(codex.persistentSession?.sessionID)
    harness.conversations.answer(claudeID, agent: "claude", id: session)
    harness.conversations.answer(codexID, agent: "codex", id: thread)
    claude.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    codex.send(text: "fix the tests\r")
    #expect(await harness.fake.wait { claude.agentConversation?.id == session && codex.agentConversation?.id == thread })
    #expect(Set(harness.conversations.asks.map(\.session)) == [claudeID, codexID])

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
    // The agents resume what Studio last named, without asking it again.
    #expect(claude.conversationToResume?.id == session && codex.conversationToResume?.id == thread)
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

@Test @MainActor func RemoteDeviceAgentResumeARestoredTabResumesWhileItsMacCannotBeReached() async throws {
    let harness = try DeviceHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    harness.conversations.reachable = false
    let session = UUID().uuidString.lowercased()
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .agent, title: "Claude", agentName: "Claude", launchCommand: "claude",
        launchWorkingDirectory: "/Users/me/app", workingDirectory: "/Users/me/app", projectRoot: harness.projectKey,
        systemEnd: .hostRestart,
        agentConversation: AgentConversationRecord(cli: "claudeCode", id: session)
    )
    let tab = workspace.makeSystemEndedSession(record: record, ended: .hostRestart)
    #expect(tab.persistentSessionEndedMessage == "Ended when Studio restarted")
    #expect(tab.conversationToResume?.id == session)
    #expect(harness.conversations.asks.isEmpty)
}
