import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// Follow-ups for local tabs that run as persistent sessions
// (docs/specs/multiplexer-default.md): names that reach the host, the
// Persistent Sessions sheet's rows, sessions whose holder died, unread
// marks that survive a tab's restore, and the turn of a restored agent.
// Against the fake `cherry control` (FakeControlHelper) and attach adapter
// (HostedSessionFakeCLI); nothing reaches a real cherry-host.

@MainActor
private extension PersistentHarness {
    /// Pushes an event on the live control connection.
    func push(_ event: HostSessionEvent) {
        fake.connections.last(where: { !$0.isClosed })?.push(.event(event))
    }

    /// The names the app sent the host for `sessionID` (`Update`), in order.
    func updatedNames(of sessionID: String) -> [String] {
        fake.requests("update").filter { $0.string("id") == sessionID }.compactMap { $0.string("name") }
    }

    /// The host reports that `sessionID`'s holder died (`ended_by`).
    func loseHolder(of sessionID: String, log: String? = "/tmp/cherry-host/host.log") {
        let end = HostSessionEnd(reason: HostSessionEnd.holderLost, holderLog: log)
        var exited: HostedSessionInfo?
        fake.sessions = fake.sessions.map { session in
            guard session.id == sessionID else { return session }
            let info = session.exited(code: 1, signal: nil, end: end)
            exited = info
            return info
        }
        push(.exited(id: sessionID, exitCode: 1, signal: nil, end: end))
        if let exited { push(.changed(exited)) }
    }
}

/// A session of this app's (`CherryTests`) for an agent tab `tab`.
private func agentSession(_ id: String, tab: UUID, project: String) -> HostedSessionInfo {
    HostedSessionInfo(
        id: id, name: "claude", cwd: project, pid: 64, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: tab.uuidString,
            PersistentSessionTag.kind: "agent",
            PersistentSessionTag.agent: "Claude",
            PersistentSessionTag.project: project
        ]
    )
}

// MARK: - Names

@Test @MainActor func renamingAPersistentTabRenamesItsHostSession() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell 1")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    #expect(harness.updatedNames(of: sessionID).isEmpty)

    tab.rename(to: "  Deploy  ")
    #expect(await harness.fake.wait { harness.updatedNames(of: sessionID) == ["Deploy"] })
    // The same name again sends nothing.
    tab.rename(to: "Deploy")
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.updatedNames(of: sessionID) == ["Deploy"])

    // Clearing it names the session as the tab is named again.
    tab.rename(to: "")
    #expect(tab.titleSource != .explicit)
    #expect(await harness.fake.wait { harness.updatedNames(of: sessionID) == ["Deploy", tab.title] })
    #expect(harness.updatedNames(of: sessionID).last != "Deploy")
}

@Test @MainActor func anAgentsTaskTitleNamesItsHostSessionOnceItSettles() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: "codex", arguments: ""),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(agent))
    let sessionID = try #require(agent.persistentSession?.sessionID)
    let project = harness.project.lastPathComponent

    agent.ingestNativeTitle("⠹ Review PR #4676 | \(project)")
    agent.ingestNativeTitle("⠋ Fix the failing test | \(project)")
    #expect(agent.title == "Fix the failing test")
    #expect(agent.titleSource == .automatic)
    // Only once it settled, and only the latest.
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.updatedNames(of: sessionID).isEmpty)
    #expect(await harness.fake.wait(timeout: 3) { harness.updatedNames(of: sessionID) == ["Fix the failing test"] })

    // A name the user gave wins over the agent's.
    agent.rename(to: "Reviewer")
    agent.ingestNativeTitle("⠙ Something else | \(project)")
    try await Task.sleep(for: .seconds(TerminalSession.hostSessionNameDelay + 0.3))
    #expect(harness.updatedNames(of: sessionID) == ["Fix the failing test", "Reviewer"])
}

@Test @MainActor func theHostNameIsCutToTheHostsLimit() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    tab.rename(to: String(repeating: "é", count: 300))
    #expect(await harness.fake.wait { harness.updatedNames(of: sessionID).count == 1 })
    let sent = try #require(harness.updatedNames(of: sessionID).first)
    #expect(sent.utf8.count <= PersistentLocalSessions.maxSessionNameBytes)
    #expect(sent.count == 128)
    // The same long name again (a rename, or the tab following its session
    // again) sends nothing: the tab knows the host has the cut name.
    tab.rename(to: String(repeating: "é", count: 300))
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.updatedNames(of: sessionID).count == 1)

    // A restored tab with that long name, whose session the host lists
    // with the cut name, sends nothing when it follows it.
    let long = String(repeating: "é", count: 300)
    let info = HostedSessionInfo(
        id: "s-long", name: sent, cwd: harness.project.path, pid: 70, owner: "CherryTests",
        tags: [PersistentSessionTag.kind: "terminal"]
    )
    harness.fake.sessions.append(info)
    _ = try await harness.control.list()
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: long, titleSource: .explicit, workingDirectory: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "s-long", owned: true)
    )
    let restored = workspace.makeRestoredPersistentSession(
        PersistentSessionLaunch(attachment: try #require(harness.hosting.attachment(for: info)), info: info),
        record: record,
        hosting: harness.hosting
    )
    defer { restored.stop(keepingSession: true) }
    #expect(await harness.fake.wait { restored.persistentSession?.sessionID == "s-long" && restored.state == .live })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.updatedNames(of: "s-long").isEmpty)
}

// MARK: - Persistent Sessions sheet

@Test @MainActor func thePersistentSessionsSheetDescribesSessionsAndFindsTheTabThatShowsOne() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let projectName = BackgroundSessionPresentation.projectName(projectRoot: project)
    let agent = agentSession("s-agent", tab: UUID(), project: project)
    let busy = HostedSessionInfo(
        id: "s-busy", name: "Shell 1", cwd: project, pid: 10, title: "~/src",
        foreground: HostedSessionForeground(pid: 11, name: "cargo"), owner: "CherryTests",
        tags: [PersistentSessionTag.kind: "terminal", PersistentSessionTag.project: project]
    )
    let titled = HostedSessionInfo(
        id: "s-titled", name: "claude", cwd: project, pid: 12, title: "Fix the tests",
        owner: "CherryTests", tags: agent.tags
    )
    let command = HostedSessionInfo(
        id: "s-command", name: "web", cwd: project, state: .exited, exitCode: 1, title: "npm",
        owner: "CherryTests",
        tags: [PersistentSessionTag.kind: "command", PersistentSessionTag.command: "web", PersistentSessionTag.project: project]
    )
    let cli = HostedSessionInfo(id: "s-cli", name: "", cwd: "/srv", pid: 13)

    #expect(HostedSessionRowPresentation.detail(of: agent) == "Agent: Claude · \(projectName)")
    #expect(HostedSessionRowPresentation.detail(of: busy) == "Terminal · \(projectName) · cargo")
    #expect(HostedSessionRowPresentation.detail(of: titled) == "Agent: Claude · \(projectName) · Fix the tests")
    // An ended session's last title says nothing of what it does now.
    #expect(HostedSessionRowPresentation.detail(of: command) == "Command: web · \(projectName)")
    // Not this app's: where it runs.
    #expect(HostedSessionRowPresentation.detail(of: cli) == "/srv")

    // A session an open tab owns: Show Tab finds that tab, in any window.
    let tab = workspace.addSession(title: "Build")
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    let info = try #require(harness.hosting.sessionInfo(sessionID))
    #expect(HostedSessionRowPresentation.tabShowing(
        info, host: .local, hostID: "host-a", localSessions: harness.hosting, attachedTabs: OpenHostedTabs()
    ) === tab)
    // Another host's session of the same id is not this tab's.
    #expect(HostedSessionRowPresentation.tabShowing(
        info, host: .local, hostID: "host-b", localSessions: harness.hosting, attachedTabs: OpenHostedTabs()
    ) == nil)
    // A session no tab shows: Attach.
    #expect(HostedSessionRowPresentation.tabShowing(
        cli, host: .local, hostID: "host-a", localSessions: harness.hosting, attachedTabs: OpenHostedTabs()
    ) == nil)
}

// MARK: - A holder that died

@Test func theHostsReportOfAHolderThatDiedIsDecoded() throws {
    let event = try JSONDecoder().decode(HostSessionEvent.self, from: Data(#"""
        {"kind":"exited","id":"s1","exit_code":1,"signal":null,"ended_by":"holder_lost","holder_log":"/tmp/h/host.log"}
        """#.utf8))
    #expect(event == .exited(
        id: "s1", exitCode: 1, signal: nil,
        end: HostSessionEnd(reason: "holder_lost", holderLog: "/tmp/h/host.log")
    ))
    // An ordinary exit carries none.
    let plain = try JSONDecoder().decode(HostSessionEvent.self, from: Data(#"{"kind":"exited","id":"s1","exit_code":3}"#.utf8))
    #expect(plain == .exited(id: "s1", exitCode: 3, signal: nil))
    // Round trip.
    let encoded = try JSONEncoder().encode(event)
    #expect(try JSONDecoder().decode(HostSessionEvent.self, from: encoded) == event)

    let info = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(#"""
        {"id":"s1","name":"zsh","cwd":"/","command":[],"cols":80,"rows":24,"state":"exited","pid":null,
         "exit_code":1,"exit_signal":null,"attached":false,"clients":0,"tags":{},"created_at":0,
         "ended_by":"holder_lost","holder_log":"/tmp/h/host.log"}
        """#.utf8))
    #expect(info.end?.isHolderLost == true)
    #expect(info.end?.message == "The session host crashed (see /tmp/h/host.log)")
    #expect(try JSONDecoder().decode(HostedSessionInfo.self, from: JSONEncoder().encode(info)) == info)
}

@Test @MainActor func aTabWhoseHolderDiedSaysTheHostCrashedInsteadOfItsExitStatus() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let keep = workspace.addSession(title: "Keep")
    let tab = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(keep))
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)

    harness.loseHolder(of: sessionID)
    #expect(await harness.fake.wait { !tab.isRunning })
    #expect(tab.hostSessionEnd?.isHolderLost == true)
    #expect(tab.persistentSessionEndedMessage == "The session host crashed (see /tmp/cherry-host/host.log)")
    #expect(tab.state == .exited(1))
    // Restart starts it again, and the crash is forgotten.
    #expect(tab.restart())
    #expect(tab.hostSessionEnd == nil)
}

@Test @MainActor func aCommandWhoseHolderDiedIsNotRestartedByItself() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(
            name: "server", command: "npm", arguments: "run dev", environment: [:], autoRestart: true
        ),
        projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(command))
    let sessionID = try #require(command.persistentSession?.sessionID)
    #expect(harness.creates().count == 1)

    harness.loseHolder(of: sessionID, log: nil)
    #expect(await harness.fake.wait { !command.isRunning })
    #expect(command.hostSessionEnd?.message == "The session host crashed")
    // An ordinary exit restarts it within a second or two; this does not.
    try await Task.sleep(for: .seconds(3))
    #expect(harness.creates().count == 1)
    #expect(!command.isRunning)
}

// MARK: - Unread marks

@Test @MainActor func aTabsUnreadMarkIsSavedAndComesBackWithIt() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession(title: "Build")
    let quiet = workspace.addSession(title: "Quiet")
    #expect(await harness.waitUntilAttached(tab))
    #expect(await harness.waitUntilAttached(quiet))
    tab.markUnread()

    let state = workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    let record = try #require(state.sessions.first { $0.id == tab.id })
    #expect(record.hasUnreadNotification == true)
    #expect(state.sessions.first { $0.id == quiet.id }?.hasUnreadNotification == nil)
    let decoded = try JSONDecoder().decode(WorkspaceSessionRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded.hasUnreadNotification == true)

    // Brought back from the record: unread.
    let tabSessionID = try #require(tab.persistentSession?.sessionID)
    let info = try #require(harness.hosting.sessionInfo(tabSessionID))
    let launch = PersistentSessionLaunch(attachment: try #require(harness.hosting.attachment(for: info)), info: info)
    workspace.closeAllSessions(intent: .windowClosed)
    let other = harness.workspace()
    defer { other.closeAllSessions(intent: .windowClosed) }
    let restored = other.makeRestoredPersistentSession(launch, record: decoded, hosting: harness.hosting, launchShell: false)
    #expect(restored.hasUnreadNotification)
    let ended = other.makeSystemEndedSession(record: decoded, ended: .restart)
    #expect(ended.hasUnreadNotification)
}

// MARK: - A restored agent's turn

@Test @MainActor func aRestoredAgentThatShowsItIsAtWorkIsInAnActiveTurn() async throws {
    let harness = try PersistentHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let project = harness.project.path
    let projectName = harness.project.lastPathComponent
    harness.fake.sessions.append(agentSession("s-agent", tab: UUID(), project: project))
    _ = try await harness.control.list()
    let info = try #require(harness.hosting.sessionInfo("s-agent"))
    let adopted = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: info)), info: info)
    #expect(adopted.isPersistentLocalSession)
    #expect(adopted.kind == .agent)
    #expect(await harness.waitUntilAttached(adopted))
    #expect(!adopted.startedCurrentProgram)
    #expect(adopted.agentTurnState == .notStarted)

    // Its spinner says a turn submitted before the tab followed it runs:
    // its end is a finished turn.
    adopted.ingestNativeTitle("⠋ Fix the failing test | \(projectName)")
    #expect(adopted.agentActivityState == .working)
    #expect(adopted.agentTurnState == .active)

    // An agent the tab started waits for a submitted turn, as before.
    let started = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude", arguments: ""),
        projectRoot: project
    )
    #expect(await harness.waitUntilAttached(started))
    #expect(started.startedCurrentProgram)
    started.ingestNativeTitle("⠋ Starting up | \(projectName)")
    #expect(started.agentTurnState == .notStarted)
}
