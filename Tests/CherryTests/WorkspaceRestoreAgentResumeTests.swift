import Foundation
import Testing
@testable import Cherry

// Agent tabs whose program the system ended (a restart, a log out, a lost
// holder) resume their CLI's conversation: the one their session's Mac last
// named while the program ran (`cherry host transcript --locate`, whose
// rules Host/crates/cherry-cli/src/transcript/tests.rs tests;
// AgentConversationLocator, AgentConversationResume,
// TerminalSession.conversationToResume). Here a stand-in answers for the
// Mac, and nothing reads the user's ~/.claude or ~/.codex.

private let claudeSession = "6f1c1b7e-2d8a-4c55-9a5e-3f0d2b9c7a11"
private let codexThread = "01a1bd88-2281-7b41-a0cf-d4b49d36a1a4"

private func conversation(_ cli: AgentLaunch.CLI, _ id: String) throws -> AgentConversation {
    try #require(AgentConversation(cli: cli, id: id))
}

/// `cherry host transcript <session> --locate` as a test's Mac answers it:
/// what each session's agent has (`agent`, `session_id`), and every ask.
final class StandInConversations: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (agent: String, id: String?)] = [:]
    private var asked: [(session: String, variables: [String: String])] = []
    private var answering = true

    func answer(_ session: String, agent: String, id: String?) {
        lock.withLock { answers[session] = (agent, id) }
    }

    /// While false it answers as a Mac that cannot be reached (nothing).
    var reachable: Bool {
        get { lock.withLock { answering } }
        set { lock.withLock { answering = newValue } }
    }

    var asks: [(session: String, variables: [String: String])] { lock.withLock { asked } }

    /// Asks at once, and again after 0.2 s at the soonest.
    var locator: AgentConversationLocator {
        AgentConversationLocator(delay: 0.02, interval: 0.2) { [self] session, variables in
            lock.withLock {
                asked.append((session, variables))
                guard answering, let answer = answers[session] else { return nil }
                return try? JSONSerialization.data(withJSONObject: [
                    "agent": answer.agent, "session_id": answer.id ?? NSNull(), "path": NSNull(),
                ])
            }
        }
    }
}

private func agentRecord(
    id: UUID = UUID(),
    title: String,
    command: String,
    sessionID: String,
    conversation: AgentConversation? = nil,
    exitStatus: Int32? = nil,
    workingDirectory: String
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: .agent,
        title: title,
        agentName: command == "codex" ? "Codex" : "Claude",
        launchCommand: command,
        launchWorkingDirectory: workingDirectory,
        workingDirectory: workingDirectory,
        projectRoot: workingDirectory,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true),
        exitStatus: exitStatus,
        agentConversation: conversation?.record
    )
}

private func beforeTheLastBoot() throws -> Date {
    try #require(SystemEndedSessions.currentBootTime()).addingTimeInterval(-3_600)
}

@MainActor
private extension PersistentHarness {
    /// The host reports that `sessionID`'s holder died (`ended_by`), as
    /// PersistentLocalSessionFollowUpTests does.
    func reportLostHolder(of sessionID: String) {
        let end = HostSessionEnd(reason: HostSessionEnd.holderLost, holderLog: "/tmp/cherry-host/host.log")
        var exited: HostedSessionInfo?
        fake.sessions = fake.sessions.map { session in
            guard session.id == sessionID else { return session }
            let info = session.exited(code: 1, signal: nil, end: end)
            exited = info
            return info
        }
        let connection = fake.connections.last(where: { !$0.isClosed })
        connection?.push(.event(.exited(id: sessionID, exitCode: 1, signal: nil, end: end)))
        if let exited { connection?.push(.event(.changed(exited))) }
    }
}

// MARK: - The resume line

@Test func aResumeLineAppendsTheCLIsOwnResumeOnlyToAPlainCommandOfOptions() throws {
    let claude = try conversation(.claudeCode, claudeSession)
    let codex = try conversation(.codex, codexThread)
    func line(_ conversation: AgentConversation, _ commandLine: String) -> String? {
        AgentConversationResume.commandLine(resuming: conversation, from: commandLine)
    }
    #expect(line(claude, "claude") == "claude '--resume' '\(claudeSession)'")
    #expect(line(claude, "claude --model opus --dangerously-skip-permissions")
        == "claude --model opus --dangerously-skip-permissions '--resume' '\(claudeSession)'")
    #expect(line(claude, "/opt/homebrew/bin/claude --effort=high") == "/opt/homebrew/bin/claude --effort=high '--resume' '\(claudeSession)'")
    // Codex takes its options before the subcommand.
    #expect(line(codex, #"codex --yolo -m gpt-5 -c 'model_reasoning_effort="high"'"#)
        == #"codex --yolo -m gpt-5 -c 'model_reasoning_effort="high"' 'resume' '\#(codexThread)'"#)

    // A prompt or another argument would be read again or misread; an
    // option that picks the session itself would fight the resume.
    for commandLine in [
        #"claude "fix the tests""#, "claude --continue", "claude -c", "claude -r", "claude --resume",
        "claude --session-id \(claudeSession)", "claude --fork-session", "claude -p hello", "claude --print",
        "claude --unknown-option value", "FOO=1 claude", "claude --model", "claude | tee log", "claude -- --resume",
    ] {
        #expect(line(claude, commandLine) == nil, "\(commandLine)")
    }
    for commandLine in ["codex resume", "codex resume --last", "codex exec 'do it'", "codex 'do it'", "codex login", "codex -m"] {
        #expect(line(codex, commandLine) == nil, "\(commandLine)")
    }
    // Only its own CLI's command.
    #expect(line(codex, "claude") == nil)
    #expect(line(claude, "codex") == nil)
    #expect(line(claude, "amp") == nil)
    // Ids are UUIDs, and Pi has none Cherry resumes.
    #expect(AgentConversation(cli: .claudeCode, id: "'; rm -rf ~; '") == nil)
    #expect(AgentConversation(cli: .pi, id: claudeSession) == nil)
}

@Test func aTabsConversationIsSavedWithItAndAnUnknownOneLeavesTheRecordReadable() throws {
    let claude = try conversation(.claudeCode, claudeSession)
    let record = agentRecord(title: "Claude", command: "claude", sessionID: "s1", conversation: claude, workingDirectory: "/tmp")
    let decoded = try JSONDecoder().decode(WorkspaceSessionRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
    #expect(AgentConversation(decoded.agentConversation) == claude)
    // Another build's CLI, or a damaged id: the record still reads, and
    // nothing resumes.
    for saved in [AgentConversationRecord(cli: "amp", id: claudeSession), AgentConversationRecord(cli: "codex", id: "x")] {
        var other = record
        other.agentConversation = saved
        let read = try JSONDecoder().decode(WorkspaceSessionRecord.self, from: JSONEncoder().encode(other))
        #expect(read.agentConversation == saved)
        #expect(AgentConversation(read.agentConversation) == nil)
    }
    // A record saved before conversations were.
    var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    older["agentConversation"] = nil
    let read = try JSONDecoder().decode(WorkspaceSessionRecord.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(read.agentConversation == nil)
    #expect(read.id == record.id)
}

// MARK: - Asking the Mac

@Test func theMacsAnswerNamesAConversationOnlyOfTheTabsOwnCLI() throws {
    func found(_ json: String, _ cli: AgentLaunch.CLI) -> AgentConversation? {
        AgentConversationLocator.conversation(in: Data(json.utf8), cli: cli)
    }
    let path = #""path":"/Users/me/.claude/projects/-Users-me-app/\#(claudeSession).jsonl""#
    #expect(found(#"{"agent":"claude","session_id":"\#(claudeSession)",\#(path)}"#, .claudeCode) == (try conversation(.claudeCode, claudeSession)))
    #expect(found(#"{"agent":"codex","session_id":"\#(codexThread)","path":"/x"}"#, .codex) == (try conversation(.codex, codexThread)))
    // Another agent than the tab's, none yet (before its first message), an
    // id that is not one, or nothing readable.
    #expect(found(#"{"agent":"codex","session_id":"\#(codexThread)","path":"/x"}"#, .claudeCode) == nil)
    #expect(found(#"{"agent":"amp","session_id":"T-1"}"#, .claudeCode) == nil)
    #expect(found(#"{"agent":"claude","session_id":null,"path":null}"#, .claudeCode) == nil)
    #expect(found(#"{"agent":"claude","session_id":"'; rm -rf ~; '"}"#, .claudeCode) == nil)
    #expect(found("cherry: no session s1", .claudeCode) == nil)
}

@Test func aTabsOwnFoldersGoWithTheAskAndADevicesScriptAsksItsInstallsCherry() async throws {
    let stand = StandInConversations()
    let locator = stand.locator
    stand.answer("s1", agent: "codex", id: codexThread)
    let environment = [
        "CODEX_HOME": "/Volumes/work/codex", "CLAUDE_CONFIG_DIR": "claude", "PATH": "/usr/bin", "OPENAI_API_KEY": "secret",
    ]
    #expect(await locator.conversation(ofSession: "s1", cli: .codex, environment: environment) == (try conversation(.codex, codexThread)))
    // Only the CLIs' folders, absolute ones: never the rest of the tab's
    // environment.
    #expect(stand.asks.last?.variables == ["CODEX_HOME": "/Volumes/work/codex"])
    stand.reachable = false
    #expect(await locator.conversation(ofSession: "s1", cli: .codex, environment: [:]) == nil)

    // A device's script, run as its `sh -s` would: its `cherry` (here one
    // that says what it was asked) gets the session and the folders.
    let directory = try canonicalTemporaryDirectory("cherry-device-locate")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = directory.appendingPathComponent("cherry")
    try Data("""
    #!/bin/sh
    printf '{"agent":"codex","session_id":"%s","path":null,"args":"%s","home":"%s"}\\n' '\(codexThread)' "$*" "$CODEX_HOME"

    """.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let script = AgentConversationLocator.deviceScript(
        session: "s1'; touch pwned; '", cli: cli.path, variables: ["CODEX_HOME": "/Users/me/it's here"]
    )
    let output = try runShellScript(script, in: directory)
    let answer = try #require(AgentConversationLocator.deviceAnswer(output))
    let object = try #require(JSONSerialization.jsonObject(with: answer) as? [String: Any])
    #expect(object["args"] as? String == "host transcript s1'; touch pwned; ' --locate")
    #expect(object["home"] as? String == "/Users/me/it's here")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
    #expect(AgentConversationLocator.conversation(in: answer, cli: .codex) == (try conversation(.codex, codexThread)))
    // ssh failed, took too long, or the script never ran its cherry.
    let begin = Data((AgentConversationLocator.deviceBegin + "\n").utf8)
    #expect(AgentConversationLocator.deviceAnswer(.init(status: 255, standardOutput: Data(), standardError: "ssh: timed out")) == nil)
    #expect(AgentConversationLocator.deviceAnswer(.init(status: 0, standardOutput: begin, standardError: "", timedOut: true)) == nil)
    #expect(AgentConversationLocator.deviceAnswer(.init(status: 1, standardOutput: begin, standardError: "cherry: no session s1")) == nil)
    #expect(AgentConversationLocator.deviceAnswer(.init(status: 0, standardOutput: Data("{}".utf8), standardError: "")) == nil)
}

/// Runs `script` with `/bin/sh -s` in `directory`, as a device's ssh does.
private func runShellScript(_ script: String, in directory: URL) throws -> RemoteDeviceShell.DataOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    process.currentDirectoryURL = directory
    process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RemoteDeviceShell.DataOutput(status: process.terminationStatus, standardOutput: data, standardError: "")
}

// MARK: - Tabs

@Test @MainActor func agentsTheSystemEndedComeBackWithResumeAndStartInTheirConversation() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-resume-restore")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-resume-restore-store")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let claude = try conversation(.claudeCode, claudeSession)
    let codex = try conversation(.codex, codexThread)
    let lead = agentRecord(title: "Lead", command: "claude", sessionID: "s-lead", conversation: claude, workingDirectory: root.path)
    let helper = agentRecord(title: "Helper", command: "codex", sessionID: "s-helper", conversation: codex, workingDirectory: root.path)
    // Its Mac never named a conversation (no first message).
    let fresh = agentRecord(title: "Fresh", command: "codex", sessionID: "s-fresh", workingDirectory: root.path)
    // It had exited by itself: Restart starts a new conversation.
    let exited = agentRecord(
        title: "Exited", command: "claude", sessionID: "s-exited", conversation: claude, exitStatus: 3,
        workingDirectory: root.path
    )
    // A command Cherry cannot add the CLI's resume to.
    let prompted = agentRecord(
        title: "Prompted", command: #"claude "fix the tests""#, sessionID: "s-prompted", conversation: claude,
        workingDirectory: root.path
    )
    let records = [lead, helper, fresh, exited, prompted]
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: records, selectedSessionID: lead.id)],
        savedAt: try beforeTheLastBoot()
    ))
    harness.fake.pendingHolders = 0
    let stand = StandInConversations()
    var policy = harness.policy
    policy.agentConversations = stand.locator
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: policy,
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
    repository.beginRestoringSavedStateIfNeeded(chromeState: quietChromeState())
    await repository.waitForPendingRestores()
    let workspace = repository.workspace
    let tabs = try records.map { try #require(workspace.session(withID: $0.id)) }
    #expect(tabs.allSatisfy { $0.systemSessionEnd == .restart && !$0.isRunning })
    // Resume what each had last; nothing is asked (no program runs).
    #expect(tabs.map(\.conversationToResume) == [claude, codex, nil, nil, nil])
    #expect(stand.asks.isEmpty)

    // Resume: Claude Code's --resume, Codex's resume; the others anew.
    for tab in tabs {
        #expect(tab.restart())
    }
    #expect(await harness.fake.wait(timeout: 8) { harness.creates().count == tabs.count })
    func startupCommand(_ record: WorkspaceSessionRecord) throws -> String? {
        try #require(harness.configurations.value.first { $0.processID == record.id.uuidString }).startupCommand
    }
    #expect(try startupCommand(lead) == "claude '--resume' '\(claudeSession)'")
    #expect(try startupCommand(helper) == "codex 'resume' '\(codexThread)'")
    #expect(try startupCommand(fresh) == "codex")
    #expect(try startupCommand(exited) == "claude")
    #expect(try startupCommand(prompted) == #"claude "fix the tests""#)
    // Once: a resumed tab keeps its conversation; a new one has none yet.
    #expect(tabs.allSatisfy { $0.conversationToResume == nil })
    #expect(tabs.map(\.agentConversation) == [claude, codex, nil, nil, nil])
}

@Test @MainActor func anAgentAsksItsMacForItsConversationWhileItRunsAndResumesItAfterItsHolderDied() async throws {
    let harness = try PersistentHarness()
    let stand = StandInConversations()
    var policy = harness.policy
    policy.agentConversations = stand.locator
    let workspace = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let keep = workspace.addSession(title: "Keep")
    let tab = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude", arguments: ""), projectRoot: harness.project.path
    )
    let shell = workspace.addSession(title: "Shell")
    #expect(await harness.waitUntilAttached(keep))
    #expect(await harness.waitUntilAttached(tab))
    #expect(await harness.waitUntilAttached(shell))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    // Its session started: asked, with nothing to say yet. A terminal is
    // never asked.
    #expect(await harness.fake.wait { stand.asks.contains { $0.session == sessionID } })
    #expect(stand.asks.allSatisfy { $0.session == sessionID })
    #expect(tab.agentConversation == nil)

    // The first message: asked again (once the asks' interval passed).
    stand.answer(sessionID, agent: "claude", id: claudeSession)
    tab.send(text: "fix the tests\r")
    #expect(await harness.fake.wait { tab.agentConversation?.id == claudeSession })
    #expect(WorkspaceSessionRecord(session: tab, restoredRecord: nil).agentConversation
        == AgentConversationRecord(cli: "claudeCode", id: claudeSession))
    // /clear made another; the turn it reports asks again.
    let cleared = UUID().uuidString.lowercased()
    stand.answer(sessionID, agent: "claude", id: cleared)
    tab.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    #expect(await harness.fake.wait { tab.agentConversation?.id == cleared })
    // An answer of nothing (the Mac could not say) keeps what it had.
    stand.reachable = false
    let asks = stand.asks.count
    tab.applyProgramStatus([ProgramStatus(state: .idle, app: "claude-code")])
    #expect(await harness.fake.wait { stand.asks.count > asks })
    #expect(tab.agentConversation?.id == cleared)

    harness.reportLostHolder(of: sessionID)
    #expect(await harness.fake.wait { !tab.isRunning })
    #expect(tab.hostSessionEnd?.isHolderLost == true)
    #expect(tab.conversationToResume?.id == cleared)
    let launches = harness.configurations.value.count
    #expect(tab.restart())
    #expect(await harness.fake.wait { harness.configurations.value.count == launches + 1 })
    #expect(harness.configurations.value.last?.startupCommand == "claude '--resume' '\(cleared)'")
}
