import CherryControl
@testable import CherryMCP
import Foundation
import MCP
import Testing
@testable import Cherry

// MCP input to an agent never answers a permission prompt. A restored agent
// (Cherry quit or crashed while it asked for permission) is followed through
// its host: one that reports its status (OSC 7501) is blocked by its host's
// records, and MCP reports it waiting for permission rather than idle; for
// one that reports nothing its screen is read from there before any input
// goes. No startup prompt of a restored agent is ever acknowledged. Against
// the fake `cherry control` (FakeControlHelper); nothing reaches a real
// cherry-host.

/// Claude Code's report while it asks to run `rm -rf build`.
private let claudeBashPermissionStatus = [ProgramStatus(
    state: .blocked, kind: .permission, app: "claude-code", message: "approve Bash: rm -rf build"
)]

/// Claude Code asking to run a command.
private let claudeBashPermissionScreen = """
    ● Bash(rm -rf build)
      ⎿  Running…

    ╭───────────────────────────────────────────────────────────────────╮
    │ Bash command                                                      │
    │                                                                   │
    │   rm -rf build                                                    │
    │   Remove the build directory                                      │
    │                                                                   │
    │ Do you want to proceed?                                           │
    │ ❯ 1. Yes                                                          │
    │   2. Yes, and don't ask again for rm commands in /project         │
    │   3. No, and tell Claude what to do differently (esc)             │
    ╰───────────────────────────────────────────────────────────────────╯


    """

/// Claude Code waiting for the next message.
private let claudeComposerScreen = """
    ● Removed the build directory.

    ╭───────────────────────────────────────────────────────────────────╮
    │ >                                                                 │
    ╰───────────────────────────────────────────────────────────────────╯
      ? for shortcuts
    """

@MainActor
private func safetyConfiguration() -> PersistentLocalSessions.Configuration {
    var configuration = PersistentHarness.fastConfiguration
    // A lost adapter stays lost: the tab keeps reading from the host.
    configuration.reconnectDelay = (30, 30)
    configuration.hostScreenReuseInterval = 0
    configuration.hostScreenWait = .milliseconds(500)
    return configuration
}

/// Restores a Claude agent tab whose session the fake host still runs,
/// with its attach adapter left for later (a worktree not shown, or a tab
/// not shown yet). `owned` false restores it only attached (a viewer).
@MainActor
private func restoreAgent(
    _ harness: PersistentHarness,
    into workspace: TerminalWorkspace,
    screen: String,
    programStatus: [ProgramStatus] = [],
    owned: Bool = true
) async throws -> TerminalSession {
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .agent, title: "Claude", agentName: "Claude", launchCommand: "claude",
        workingDirectory: harness.project.path, projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-agent", owned: owned)
    )
    harness.fake.sessions = [HostedSessionInfo(
        id: "session-agent", name: "Claude", cwd: harness.project.path, pid: 61, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: record.id.uuidString,
            PersistentSessionTag.kind: "agent",
            PersistentSessionTag.agent: "Claude"
        ],
        programStatus: programStatus
    )]
    harness.fake.screenText = screen
    let result = await harness.restorer(WorkspaceRestoreRequest(
        repositoryRoot: harness.project.path, worktreeRoot: harness.project.path,
        records: [record], workspace: workspace
    ))
    workspace.restoreSessions(
        result.sessions,
        from: WorktreeStateRecord(root: harness.project.path, sessions: [record]),
        launchingAdapters: false
    )
    let tab = try #require(result.sessions.first)
    #expect(tab.kind == .agent)
    // An attached tab runs nothing until its adapter launches.
    #expect(tab.isRunning == owned)
    #expect(tab.isAwaitingDeferredLaunch)
    #expect(!tab.startedCurrentProgram)
    return tab
}

/// What the fake host was asked to type, in order.
private func typed(_ harness: PersistentHarness) -> [String] {
    harness.fake.requests("send_input").compactMap { request in
        request.string("data").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - A restored agent at a permission prompt

@Test @MainActor func aRestoredAgentThatReportsItWaitsForPermissionIsNeverAnswered() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = try await restoreAgent(
        harness, into: workspace, screen: claudeBashPermissionScreen, programStatus: claudeBashPermissionStatus
    )

    // The orchestrator's view: waiting for permission, not idle.
    let status = try await control.process(agent)
    #expect(status.agentActivityState == "permission")
    #expect(status.programStatus?.message == "approve Bash: rm -rf build")
    let waited = try await control.send(.waitForProcessIdle(.init(
        processID: agent.id.uuidString, requireNewOutput: false, quietMilliseconds: 100, timeoutMilliseconds: 3_000
    )))
    guard case .waitForProcessIdle(let idle)? = waited.result else {
        Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
        return
    }
    #expect(idle.reason == .permission)
    #expect(idle.agentActivityState == "permission")

    // Refused on its report, quoting it; its screen is not needed.
    let screenReads = harness.fake.requests("screen").count
    let message = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, text: "please also run the tests", submit: true
    )))
    #expect(message.error?.code == "agent_awaiting_permission")
    #expect(message.error?.message.contains("approve Bash: rm -rf build") == true)
    #expect(harness.fake.requests("screen").count == screenReads)
    try await Task.sleep(for: .milliseconds(500))
    #expect(typed(harness).isEmpty)
}

@Test @MainActor func mcpInputNeverAnswersTheRestoredAgentsPermissionPrompt() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // An agent that reports nothing: its state is unknown, and only its
    // screen can say it waits for permission.
    let agent = try await restoreAgent(harness, into: workspace, screen: claudeBashPermissionScreen)
    #expect(agent.lastInputOutputVersion == nil)
    #expect(try await control.process(agent).agentActivityState == "unknown")

    // send_agent_message (text, submitted): refused, nothing typed; above
    // all no Enter, which would approve `rm -rf build`.
    let screenReads = harness.fake.requests("screen").count
    let message = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, text: "please also run the tests", submit: true
    )))
    #expect(message.error?.code == "agent_awaiting_permission")
    #expect(message.error?.message.contains("nothing was sent") == true)
    // Its screen was read from the host for this: no surface shows it.
    #expect(harness.fake.requests("screen").count > screenReads)
    // send_process_input with plain text: the same.
    let text = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "y")))
    #expect(text.error?.code == "agent_awaiting_permission")
    // Raw bytes that submit: the same.
    let rawSubmit = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, rawBase64: Data("x".utf8).base64EncodedString(), submit: true
    )))
    #expect(rawSubmit.error?.code == "agent_awaiting_permission")
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(typed(harness).isEmpty)
    #expect(agent.isRunning)

    // Raw keys without submit are the caller's own answer: Esc ("No").
    let answer = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, rawBase64: Data([0x1B]).base64EncodedString()
    )))
    #expect(answer.error == nil)
    #expect(typed(harness) == ["\u{1B}"])

    // The prompt is gone: the next message goes, typed then submitted,
    // with no Enter of Cherry's own before it.
    harness.fake.screenText = claudeComposerScreen
    let later = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, text: "run the tests", submit: true
    )))
    #expect(later.error == nil)
    #expect(typed(harness) == ["\u{1B}", "run the tests", "\r"])
}

@Test @MainActor func sendAgentMessageThroughMCPLeavesTheRestoredAgentsPermissionPromptAlone() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    let previousSocket = getenv(CherryControl.socketEnvironmentKey).map { String(cString: $0) }
    let previousProjectRoot = getenv(CherryControl.projectRootEnvironmentKey).map { String(cString: $0) }
    setenv(CherryControl.socketEnvironmentKey, control.socketURL.path, 1)
    setenv(CherryControl.projectRootEnvironmentKey, harness.project.path, 1)
    defer {
        if let previousSocket { setenv(CherryControl.socketEnvironmentKey, previousSocket, 1) } else { unsetenv(CherryControl.socketEnvironmentKey) }
        if let previousProjectRoot { setenv(CherryControl.projectRootEnvironmentKey, previousProjectRoot, 1) } else { unsetenv(CherryControl.projectRootEnvironmentKey) }
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = try await restoreAgent(
        harness, into: workspace, screen: claudeBashPermissionScreen, programStatus: claudeBashPermissionStatus
    )

    // The original report: wait_for_process_idle, then send_agent_message.
    let idle = await CherryMCPTools.call(
        name: "wait_for_process_idle",
        arguments: ["process_id": .string(agent.id.uuidString), "require_new_output": .bool(false), "timeout_ms": .int(3_000)]
    )
    #expect(idle.isError != true)
    let idleText = idle.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined()
    #expect(idleText.contains("permission"), Comment(rawValue: idleText))

    let sent = await CherryMCPTools.call(
        name: "send_agent_message",
        arguments: ["process_id": .string(agent.id.uuidString), "message": .string("carry on"), "timeout_ms": .int(2_000)]
    )
    #expect(sent.isError == true)
    let sentText = sent.content.compactMap { content -> String? in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined()
    #expect(sentText.contains("agent_awaiting_permission"), Comment(rawValue: sentText))
    try await Task.sleep(for: .milliseconds(1_000))
    #expect(typed(harness).isEmpty)
}

@Test @MainActor func aRestoredAgentsStartupLikePromptIsNeverAcknowledged() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // Words the startup-prompt check looks for ("do you want to
    // proceed"), on a screen that is no permission menu: a restored agent
    // is past its startup, so Cherry presses nothing of its own. The
    // message is what gets typed.
    let agent = try await restoreAgent(
        harness, into: workspace,
        screen: "Earlier I asked: do you want to proceed with the refactor?\nYou said yes.\n\n> "
    )
    let sent = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "go on", submit: true)))
    #expect(sent.error == nil)
    #expect(typed(harness) == ["go on", "\r"])
}

@Test @MainActor func inputWaitsForTheRestoredAgentsScreenAndIsNotSentWithoutIt() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = try await restoreAgent(harness, into: workspace, screen: claudeComposerScreen)
    // The host does not answer Screen: whether the agent waits for
    // permission cannot be known, so nothing is typed, and the caller
    // hears so once the read's wait (`hostScreenWait`) ran out.
    harness.fake.respond = { request, _ in request.op == "screen" ? .silence : nil }
    let started = Date()
    let sent = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello", submit: true)))
    #expect(sent.error?.code == "input_not_delivered")
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(typed(harness).isEmpty)
    // Nor when it fails to read it.
    harness.fake.respond = { request, _ in
        request.op == "screen" ? .answer(.error(code: "request_failed", message: "screen unavailable")) : nil
    }
    let failed = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello", submit: true)))
    #expect(failed.error?.code == "input_not_delivered")
    #expect(typed(harness).isEmpty)
    // The read that never answered gives up (the control's request
    // timeout); a new one is made.
    try await Task.sleep(for: .milliseconds(5_500))

    // It answers again: the input goes.
    harness.fake.respond = nil
    let again = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello", submit: true)))
    #expect(again.error == nil)
    #expect(typed(harness) == ["hello", "\r"])
}

@Test @MainActor func aRestoredAttachedAgentsScreenIsReadThroughItsHostBeforeInput() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // A viewer record comes back attached, its adapter deferred: MCP input
    // goes through its host's control connection, and so does the read.
    let agent = try await restoreAgent(harness, into: workspace, screen: claudeBashPermissionScreen, owned: false)
    #expect(agent.hostedAttachment != nil)
    #expect(!agent.isPersistentLocalSession)
    let sent = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello", submit: true)))
    #expect(sent.error?.code == "agent_awaiting_permission")
    #expect(harness.requestIDs("screen").contains("session-agent"))
    try await Task.sleep(for: .milliseconds(500))
    #expect(typed(harness).isEmpty)

    harness.fake.screenText = claudeComposerScreen
    let later = try await control.send(.sendProcessInput(.init(processID: agent.id.uuidString, text: "hello", submit: true)))
    #expect(later.error == nil)
    #expect(typed(harness) == ["hello", "\r"])
}

// MARK: - A kept agent adopted from File › Persistent Sessions

@Test @MainActor func anAgentAdoptedFromThePersistentSessionsSheetStaysAnAgentAndItsPromptIsGuarded() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // A kept agent (its tab detached) that no tab shows: the sheet adopts it.
    let tabID = UUID()
    let listed = HostedSessionInfo(
        id: "session-kept-agent", name: "Claude", cwd: harness.project.path, pid: 62, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: tabID.uuidString,
            PersistentSessionTag.kind: "agent",
            PersistentSessionTag.agent: "Claude",
            PersistentSessionTag.project: harness.project.path
        ]
    )
    harness.fake.sessions = [listed]
    harness.fake.screenText = claudeBashPermissionScreen
    _ = try await harness.control.list()
    let attachment = try #require(harness.hosting.attachment(for: listed))

    let agent = workspace.attachHostedSession(attachment, info: listed)
    #expect(agent.isPersistentLocalSession)
    #expect(agent.id == tabID)
    #expect(agent.kind == .agent)
    #expect(agent.agentName == "Claude")
    #expect(agent.titleSource == .system)
    #expect(await harness.waitUntilAttached(agent))
    #expect(harness.creates().isEmpty)
    // What the next save writes keeps it an agent.
    let saved = try #require(workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
        .sessions.first { $0.id == tabID })
    #expect(saved.kind == .agent)
    #expect(saved.agentName == "Claude")

    // MCP never answers its permission prompt.
    let sent = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, text: "y", submit: true
    )))
    #expect(sent.error?.code == "agent_awaiting_permission")
    try await Task.sleep(for: .milliseconds(500))
    #expect(typed(harness).isEmpty)
}

@Test @MainActor func aCommandAdoptedFromThePersistentSessionsSheetKeepsItsCommand() async throws {
    let harness = try PersistentHarness(configuration: safetyConfiguration())
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let listed = HostedSessionInfo(
        id: "session-kept-command", name: "dev", cwd: harness.project.path, pid: 63, owner: "CherryTests",
        tags: [
            PersistentSessionTag.tab: UUID().uuidString,
            PersistentSessionTag.kind: "command",
            PersistentSessionTag.command: "dev"
        ]
    )
    harness.fake.sessions = [listed]
    _ = try await harness.control.list()
    let command = workspace.attachHostedSession(try #require(harness.hosting.attachment(for: listed)), info: listed)
    #expect(command.isPersistentLocalSession)
    #expect(command.kind == .command)
    #expect(command.commandName == "dev")
    #expect(workspace.commandSession(named: "dev") === command)
    // No project tag: the tab belongs to the workspace's project.
    #expect(command.projectRoot == workspace.projectRoot)
}

// MARK: - Recognizing permission prompts

@Test func permissionPromptsAreRecognizedAndStartupPromptsAreNot() {
    func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    #expect(AgentPermissionPrompt.isShowing(in: lines(claudeBashPermissionScreen)))
    // Claude Code 2 without the box, an edit.
    #expect(AgentPermissionPrompt.isShowing(in: lines("""
        ────────────────────────────────────────
         Edit file
         src/main.swift
        ────────────────────────────────────────
         Do you want to make this edit to main.swift?
         ❯ 1. Yes
           2. Yes, allow all edits during this session (shift+tab)
           3. No, and tell Claude what to do differently (esc)
        """)))
    // Codex asking to run a command.
    #expect(AgentPermissionPrompt.isShowing(in: lines("""
          Would you like to run the following command?

          $ cargo test

        › 1. Yes, proceed (y)
          2. Yes, and don’t ask again for this command (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """)))
    // Gemini.
    #expect(AgentPermissionPrompt.isShowing(in: lines("""
        Allow execution of: 'rm'?
        ● 1. Yes, allow once
          2. Yes, allow always ...
          3. No, suggest changes (esc)
        """)))
    // Plan approval: Enter starts editing.
    #expect(AgentPermissionPrompt.isShowing(in: lines("""
         Would you like to proceed?
         ❯ 1. Yes, and auto-accept edits
           2. Yes, and manually approve edits
           3. No, keep planning
        """)))

    // Startup and trust prompts (acknowledged for an agent Cherry just
    // started) are no permission prompts.
    #expect(!AgentPermissionPrompt.isShowing(in: lines("""
         Do you trust the files in this folder?

         /project

         ❯ 1. Yes, proceed
           2. No, exit
        """)))
    #expect(!AgentPermissionPrompt.isShowing(in: lines("""
        > You are running Codex in /project

          Since this folder is version controlled, you may wish to allow Codex to work in this folder without asking for approval.

        › 1. Yes, allow Codex to work in this folder without asking for approval
          2. No, ask me to approve edits and commands

          Press enter to continue
        """)))
    // Prose about a prompt, the composer, and a prompt answered long ago
    // (scrolled far above the last lines) are not one either.
    #expect(!AgentPermissionPrompt.isShowing(in: lines(
        "I will ask: \"No, and tell Claude what to do differently\" is the third option.\n> "
    )))
    #expect(!AgentPermissionPrompt.isShowing(in: lines(claudeComposerScreen)))
    #expect(!AgentPermissionPrompt.isShowing(in: lines(claudeBashPermissionScreen) + Array(repeating: "output", count: 40)))
    #expect(!AgentPermissionPrompt.isShowing(in: []))
}
