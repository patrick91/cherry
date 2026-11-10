import Foundation
import Testing
@testable import Cherry

// Agent tabs whose program the system ended (a restart, a log out, a lost
// holder) resume their CLI's conversation: Claude Code's session, read from
// its registry while it runs, and Codex's latest thread of the tab, found in
// its rollouts (AgentConversations, AgentConversationResume,
// TerminalSession.conversationToResume). The CLIs' folders are temporary
// ones here, never the user's ~/.claude or ~/.codex.

private let claudeSession = "6f1c1b7e-2d8a-4c55-9a5e-3f0d2b9c7a11"
private let codexThread = "01a1bd88-2281-7b41-a0cf-d4b49d36a1a4"

private func conversation(_ cli: AgentLaunch.CLI, _ id: String) throws -> AgentConversation {
    try #require(AgentConversation(cli: cli, id: id))
}

/// A temporary home for both CLIs' folders.
private func agentFolders(_ prefix: String) throws -> (root: URL, conversations: AgentConversations) {
    let root = try canonicalTemporaryDirectory(prefix)
    return (root, AgentConversations(
        claudeConfigDirectory: root.appendingPathComponent("claude", isDirectory: true),
        codexHome: root.appendingPathComponent("codex", isDirectory: true)
    ))
}

/// What Claude Code writes for a running session: `sessions/<pid>.json`.
func registerClaudeSession(
    _ session: String, pid: Int32, startedAt: Date = Date(), in conversations: AgentConversations
) throws {
    let folder = conversations.claudeConfigDirectory.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let object: [String: Any] = [
        "pid": Int(pid), "sessionId": session, "cwd": "/Users/me/app",
        "startedAt": Int(startedAt.timeIntervalSince1970 * 1000), "kind": "interactive", "status": "idle",
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("\(pid).json"))
}

/// A Claude Code conversation: `projects/<folder>/<session>.jsonl`.
func writeClaudeTranscript(_ session: String, contents: String = #"{"type":"user"}"# + "\n", in conversations: AgentConversations) throws {
    let folder = conversations.claudeConfigDirectory
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent("-Users-me-app", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: folder.appendingPathComponent("\(session).jsonl"))
}

/// A Codex rollout as Codex 0.166 writes one: its metadata, a turn's start,
/// developer messages (Cherry's instructions line naming `tab` among them,
/// or in `role`'s message), then the user's first message.
func writeCodexRollout(
    thread: String,
    source: Any = "cli",
    tab: UUID?,
    role: String = "developer",
    modified: Date,
    created: Date? = nil,
    in conversations: AgentConversations
) throws {
    let folder = conversations.codexHome.appendingPathComponent("sessions/2026/11/09", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func message(_ role: String, _ text: String) -> [String: Any] {
        ["type": "response_item", "payload": [
            "type": "message", "role": role, "content": [["type": "input_text", "text": text]],
        ] as [String: Any]]
    }
    // The line Cherry gives a Codex it starts (`-c developer_instructions`).
    let line = tab.map { AgentCLILaunch.instructionLine(processID: $0.uuidString, hasSkill: false) } ?? "No tab here."
    let items: [[String: Any]] = [
        ["type": "session_meta", "payload": [
            "id": thread, "source": source, "cwd": "/Users/me/app", "originator": "codex-tui",
            "base_instructions": ["text": String(repeating: "Codex's own instructions. ", count: 400)],
        ] as [String: Any]],
        ["type": "event_msg", "payload": ["type": "task_started"]],
        message("developer", "<permissions instructions>"),
        message(role, line),
        message("user", "Fix the tests"),
    ]
    let text = try items.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        .joined(separator: "\n") + "\n"
    let url = folder.appendingPathComponent("rollout-2026-11-09T10-00-00-\(thread).jsonl")
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.creationDate: created ?? modified, .modificationDate: modified], ofItemAtPath: url.path
    )
}

/// A child process that stands in for an agent's program.
func standInProgram() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
}

private func agentRecord(
    id: UUID = UUID(),
    title: String,
    command: String,
    sessionID: String,
    conversation: AgentConversation? = nil,
    exitStatus: Int32? = nil,
    startedAt: Date? = nil,
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
        agentConversation: conversation?.record,
        agentStartedAt: startedAt
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

// MARK: - What the CLIs keep

@Test func claudeCodesRegistryNamesTheSessionOfTheClaudeUnderATabsProgram() throws {
    let (root, conversations) = try agentFolders("cherry-resume-claude-registry")
    defer { try? FileManager.default.removeItem(at: root) }
    let program = try standInProgram()
    defer {
        program.terminate()
        program.waitUntilExit()
    }
    let pid = program.processIdentifier
    func session(under root: Int32) -> String? {
        conversations.claudeSession(runningUnder: root, processes: ShellProcessController.enumerateProcesses())
    }
    #expect(session(under: pid) == nil)

    try registerClaudeSession(claudeSession, pid: pid, in: conversations)
    #expect(session(under: pid) == claudeSession)
    // Under the tab's program: an alias or wrapper starts it as a child.
    #expect(session(under: getpid()) == claudeSession)

    // A file an earlier process with this pid left (started before it).
    try registerClaudeSession(claudeSession, pid: pid, startedAt: Date().addingTimeInterval(-600), in: conversations)
    #expect(session(under: pid) == nil)
    // Another process's file, or no session id in it.
    let file = conversations.claudeConfigDirectory.appendingPathComponent("sessions/\(pid).json")
    try JSONSerialization.data(withJSONObject: ["pid": Int(pid) + 1, "sessionId": claudeSession, "startedAt": Int(Date().timeIntervalSince1970 * 1000)])
        .write(to: file)
    #expect(session(under: pid) == nil)
    try registerClaudeSession("not-a-session", pid: pid, in: conversations)
    #expect(session(under: pid) == nil)
    // A link is not followed.
    let elsewhere = root.appendingPathComponent("elsewhere.json")
    try registerClaudeSession(claudeSession, pid: pid, in: conversations)
    try FileManager.default.moveItem(at: file, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    #expect(session(under: pid) == nil)
}

@Test func claudeCodeHasAConversationOnlyWhileItsTranscriptHasSomethingInIt() throws {
    let (root, conversations) = try agentFolders("cherry-resume-claude-transcripts")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(!conversations.claudeHasConversation(claudeSession))
    try writeClaudeTranscript(claudeSession, in: conversations)
    #expect(conversations.claudeHasConversation(claudeSession))
    let empty = UUID().uuidString.lowercased()
    try writeClaudeTranscript(empty, contents: "", in: conversations)
    #expect(!conversations.claudeHasConversation(empty))
    #expect(!conversations.claudeHasConversation(UUID().uuidString.lowercased()))
    #expect(!conversations.claudeHasConversation("../\(claudeSession)"))
}

@Test func codexsThreadOfATabIsTheNewestRolloutWhoseDeveloperMessageNamesIt() throws {
    let (root, conversations) = try agentFolders("cherry-resume-codex-rollouts")
    defer { try? FileManager.default.removeItem(at: root) }
    let tab = UUID()
    let now = Date()
    let older = UUID().uuidString.lowercased()
    try writeCodexRollout(thread: older, tab: tab, modified: now.addingTimeInterval(-3_600), in: conversations)
    #expect(conversations.codexThread(launchedInTab: tab, now: now) == older)
    // A /new in the tab: a newer thread with the line again.
    try writeCodexRollout(thread: codexThread, tab: tab, modified: now.addingTimeInterval(-60), in: conversations)
    #expect(conversations.codexThread(launchedInTab: tab, now: now) == codexThread)
    // Newer ones that do not count: a subagent's (Codex's reviewer quotes its
    // parent's messages), the line in a user's message, another tab's.
    try writeCodexRollout(
        thread: UUID().uuidString.lowercased(), source: ["subagent": ["other": "guardian"]], tab: tab, modified: now,
        in: conversations
    )
    try writeCodexRollout(thread: UUID().uuidString.lowercased(), tab: tab, role: "user", modified: now, in: conversations)
    try writeCodexRollout(thread: UUID().uuidString.lowercased(), tab: UUID(), modified: now, in: conversations)
    #expect(conversations.codexThread(launchedInTab: tab, now: now) == codexThread)
    // None names this tab; and one older than the look-back is not looked at.
    #expect(conversations.codexThread(launchedInTab: UUID(), now: now) == nil)
    let stale = UUID()
    try writeCodexRollout(
        thread: UUID().uuidString.lowercased(), tab: stale,
        modified: now.addingTimeInterval(-AgentConversations.codexThreadsLookBack - 60), in: conversations
    )
    #expect(conversations.codexThread(launchedInTab: stale, now: now) == nil)
    // A thread made before the tab's agent last started is an earlier
    // launch's (or the one that start resumed), not this launch's.
    let restarted = UUID()
    try writeCodexRollout(
        thread: UUID().uuidString.lowercased(), tab: restarted, modified: now, created: now.addingTimeInterval(-7_200),
        in: conversations
    )
    #expect(conversations.codexThread(launchedInTab: restarted, createdSince: now.addingTimeInterval(-600), now: now) == nil)
    #expect(conversations.codexThread(launchedInTab: restarted, now: now) != nil)
    let newer = UUID().uuidString.lowercased()
    try writeCodexRollout(thread: newer, tab: restarted, modified: now, created: now.addingTimeInterval(-300), in: conversations)
    #expect(conversations.codexThread(launchedInTab: restarted, createdSince: now.addingTimeInterval(-600), now: now) == newer)
}

@Test func aTabsOwnVariablesMoveTheCLIsFolders() {
    let base = AgentConversations(
        claudeConfigDirectory: URL(fileURLWithPath: "/Users/me/.claude"), codexHome: URL(fileURLWithPath: "/Users/me/.codex")
    )
    let moved = base.applying(environment: ["CLAUDE_CONFIG_DIR": "/Volumes/work/claude", "CODEX_HOME": "/Volumes/work/codex"])
    #expect(moved.claudeConfigDirectory.path == "/Volumes/work/claude")
    #expect(moved.codexHome.path == "/Volumes/work/codex")
    // Only absolute paths.
    let relative = base.applying(environment: ["CLAUDE_CONFIG_DIR": "claude", "CODEX_HOME": "~/codex"])
    #expect(relative.claudeConfigDirectory.path == "/Users/me/.claude")
    #expect(relative.codexHome.path == "/Users/me/.codex")
}

// MARK: - Tabs

@Test @MainActor func agentsTheSystemEndedComeBackWithResumeAndStartInTheirConversation() async throws {
    let harness = try PersistentHarness()
    let root = try canonicalTemporaryDirectory("cherry-resume-restore")
    let storeDirectory = try canonicalTemporaryDirectory("cherry-resume-restore-store")
    let (agentRoot, conversations) = try agentFolders("cherry-resume-restore-agents")
    let store = WorkspaceStateStore(directory: storeDirectory)
    let claude = try conversation(.claudeCode, claudeSession)
    // Claude Code still has this one's conversation...
    let lead = agentRecord(title: "Lead", command: "claude", sessionID: "s-lead", conversation: claude, workingDirectory: root.path)
    try writeClaudeTranscript(claudeSession, in: conversations)
    // ...not this one's.
    let gone = agentRecord(
        title: "Gone", command: "claude", sessionID: "s-gone",
        conversation: try conversation(.claudeCode, UUID().uuidString.lowercased()), workingDirectory: root.path
    )
    // Codex's rollouts name its tab.
    let helper = agentRecord(title: "Helper", command: "codex", sessionID: "s-helper", workingDirectory: root.path)
    try writeCodexRollout(thread: codexThread, tab: helper.id, modified: Date(), in: conversations)
    // A Codex tab whose last start resumed a thread (made before it): that
    // thread again. One restarted afresh without Cherry's line: an earlier
    // launch's thread is not its.
    let startedAt = Date().addingTimeInterval(-600)
    let resumedThread = UUID().uuidString.lowercased()
    let codexResumed = agentRecord(
        title: "Resumed", command: "codex", sessionID: "s-codex-resumed",
        conversation: try conversation(.codex, resumedThread), startedAt: startedAt, workingDirectory: root.path
    )
    try writeCodexRollout(
        thread: resumedThread, tab: codexResumed.id, modified: Date(), created: startedAt.addingTimeInterval(-7_200),
        in: conversations
    )
    let codexFresh = agentRecord(
        title: "Fresh", command: "codex", sessionID: "s-codex-fresh", startedAt: startedAt, workingDirectory: root.path
    )
    try writeCodexRollout(
        thread: UUID().uuidString.lowercased(), tab: codexFresh.id, modified: startedAt,
        created: startedAt.addingTimeInterval(-7_200), in: conversations
    )
    // It had exited by itself: Restart starts a new conversation.
    let exited = agentRecord(
        title: "Exited", command: "claude", sessionID: "s-exited", conversation: claude, exitStatus: 3,
        workingDirectory: root.path
    )
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(
            root: root.path, sessions: [lead, gone, helper, codexResumed, codexFresh, exited], selectedSessionID: lead.id
        )],
        savedAt: try beforeTheLastBoot()
    ))
    harness.fake.pendingHolders = 0
    var policy = harness.policy
    policy.agentConversations = conversations
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
        [root, storeDirectory, agentRoot].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    repository.beginRestoringSavedStateIfNeeded(chromeState: quietChromeState())
    await repository.waitForPendingRestores()
    let workspace = repository.workspace
    let leadTab = try #require(workspace.session(withID: lead.id))
    let goneTab = try #require(workspace.session(withID: gone.id))
    let helperTab = try #require(workspace.session(withID: helper.id))
    let exitedTab = try #require(workspace.session(withID: exited.id))
    let resumedTab = try #require(workspace.session(withID: codexResumed.id))
    let freshTab = try #require(workspace.session(withID: codexFresh.id))
    let tabs = [leadTab, goneTab, helperTab, resumedTab, freshTab, exitedTab]
    #expect(tabs.allSatisfy { $0.systemSessionEnd == .restart && !$0.isRunning })
    #expect(!exitedTab.isLookingForConversationToResume)
    #expect(await harness.fake.wait { !tabs.contains(where: \.isLookingForConversationToResume) })
    #expect(leadTab.conversationToResume == claude)
    #expect(helperTab.conversationToResume == (try conversation(.codex, codexThread)))
    #expect(resumedTab.conversationToResume == (try conversation(.codex, resumedThread)))
    #expect(goneTab.conversationToResume == nil)
    #expect(freshTab.conversationToResume == nil)
    #expect(exitedTab.conversationToResume == nil)

    // Saved with the thread found, so a relaunch before Resume still has it.
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repository.repositoryRoot)?.worktree(root: root.path))
    #expect(saved.sessions.first { $0.id == helper.id }?.agentConversation == AgentConversationRecord(cli: "codex", id: codexThread))
    #expect(saved.sessions.first { $0.id == lead.id }?.agentConversation == claude.record)

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
    #expect(try startupCommand(codexResumed) == "codex 'resume' '\(resumedThread)'")
    #expect(try startupCommand(gone) == "claude")
    #expect(try startupCommand(codexFresh) == "codex")
    #expect(try startupCommand(exited) == "claude")
    // Once: a resumed tab keeps its conversation; a new one has none yet.
    #expect(tabs.allSatisfy { $0.conversationToResume == nil })
    // Only a Codex tab keeps when it started (its threads are looked for
    // from then).
    #expect([helperTab, resumedTab, freshTab].allSatisfy { ($0.agentProgramStartedAt ?? .distantPast) > startedAt })
    #expect([leadTab, goneTab, exitedTab].allSatisfy { $0.agentProgramStartedAt == nil })
    #expect(leadTab.agentConversation == claude)
    #expect(goneTab.agentConversation == nil)
    #expect(exitedTab.agentConversation == nil)
}

@Test @MainActor func aClaudeAgentWhoseHolderDiedResumesTheSessionItHadLast() async throws {
    let harness = try PersistentHarness()
    let (agentRoot, conversations) = try agentFolders("cherry-resume-holder-lost")
    var policy = harness.policy
    policy.agentConversations = conversations
    let workspace = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
    let program = try standInProgram()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        program.terminate()
        program.waitUntilExit()
        try? FileManager.default.removeItem(at: agentRoot)
    }
    let keep = workspace.addSession(title: "Keep")
    let tab = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: "claude", arguments: ""), projectRoot: harness.project.path
    )
    #expect(await harness.waitUntilAttached(keep))
    #expect(await harness.waitUntilAttached(tab))
    let sessionID = try #require(tab.persistentSession?.sessionID)
    // Its program, as the host reports it: the stand-in.
    let info = try #require(harness.fake.sessions.first { $0.id == sessionID })
    let running = HostedSessionInfo(
        id: info.id, name: info.name, cwd: info.cwd, command: info.command, pid: UInt32(program.processIdentifier),
        owner: info.owner, tags: info.tags, createdAt: info.createdAt
    )
    harness.fake.sessions = harness.fake.sessions.map { $0.id == sessionID ? running : $0 }
    harness.fake.connections.last(where: { !$0.isClosed })?.push(.event(.changed(running)))
    #expect(await harness.fake.wait { tab.programProcessID == program.processIdentifier })

    // A turn starts: Cherry reads which session it belongs to.
    try registerClaudeSession(claudeSession, pid: program.processIdentifier, in: conversations)
    tab.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    #expect(await harness.fake.wait { tab.agentConversation?.id == claudeSession })
    #expect(WorkspaceSessionRecord(session: tab, restoredRecord: nil).agentConversation
        == AgentConversationRecord(cli: "claudeCode", id: claudeSession))
    // /clear made another; the next report, or a quit, reads it.
    let cleared = UUID().uuidString.lowercased()
    try registerClaudeSession(cleared, pid: program.processIdentifier, in: conversations)
    tab.applyProgramStatus([ProgramStatus(state: .idle, app: "claude-code")])
    #expect(await harness.fake.wait { tab.agentConversation?.id == cleared })
    let resumed = UUID().uuidString.lowercased()
    try registerClaudeSession(resumed, pid: program.processIdentifier, in: conversations)
    tab.captureAgentConversationNow(processes: ShellProcessController.enumerateProcesses())
    #expect(tab.agentConversation?.id == resumed)
    try writeClaudeTranscript(resumed, in: conversations)

    harness.reportLostHolder(of: sessionID)
    #expect(await harness.fake.wait { !tab.isRunning })
    #expect(tab.hostSessionEnd?.isHolderLost == true)
    #expect(await harness.fake.wait { tab.conversationToResume?.id == resumed })
    let launches = harness.configurations.value.count
    #expect(tab.restart())
    #expect(await harness.fake.wait { harness.configurations.value.count == launches + 1 })
    #expect(harness.configurations.value.last?.startupCommand == "claude '--resume' '\(resumed)'")
}
