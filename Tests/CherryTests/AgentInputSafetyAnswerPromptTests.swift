import CherryControl
import Foundation
import Testing
@testable import Cherry

// An agent's permission or question menu, read off its screen
// (`AgentPromptMenu`): its options come with the refusal of input into it,
// with get_process_status, and answer_prompt picks one, moving the
// highlight with arrow keys and pressing Enter only once the screen shows
// the option highlighted. Against the fake `cherry control`
// (FakeControlHelper); nothing reaches a real cherry-host.

private func screenLines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

/// Claude Code asking to run a command, the highlight on option `selected`.
private func claudeBashPermission(selected: Int = 1) -> String {
    let options = [
        "1. Yes",
        "2. Yes, and don't ask again for rm commands in /project",
        "3. No, and tell Claude what to do differently (esc)",
    ]
    let rows = options.enumerated().map { index, option in
        "│ \(index + 1 == selected ? "❯" : " ") \(option)".padding(toLength: 68, withPad: " ", startingAt: 0) + "│"
    }
    return """
        ● Bash(rm -rf build)
          ⎿  Running…

        ╭───────────────────────────────────────────────────────────────────╮
        │ Bash command                                                      │
        │                                                                   │
        │   rm -rf build                                                    │
        │                                                                   │
        │ Do you want to proceed?                                           │
        \(rows.joined(separator: "\n"))
        ╰───────────────────────────────────────────────────────────────────╯

        """
}

private let claudeComposer = """
    ● Removed the build directory.

    ╭───────────────────────────────────────────────────────────────────╮
    │ >                                                                 │
    ╰───────────────────────────────────────────────────────────────────╯
      ? for shortcuts
    """

// MARK: - Reading menus

@Test func answerPromptMenusAreReadWithTheirOptionsAndHighlight() throws {
    let claude = try #require(AgentPromptMenu.read(from: screenLines(claudeBashPermission(selected: 2))))
    #expect(claude.kind == "permission")
    #expect(claude.question == "Do you want to proceed?")
    #expect(claude.options.map(\.number) == [1, 2, 3])
    #expect(claude.options.map(\.label) == [
        "Yes", "Yes, and don't ask again for rm commands in /project", "No, and tell Claude what to do differently (esc)",
    ])
    #expect(claude.options.map(\.selected) == [false, true, false])

    let codex = try #require(AgentPromptMenu.read(from: screenLines("""
        • I'll clean the build directory first.

          Would you like to run the following command?

          $ rm -rf build

        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for this command (p)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
        """)))
    #expect(codex.kind == "permission")
    #expect(codex.question == "Would you like to run the following command?")
    #expect(codex.options.first?.label == "Yes, proceed (y)")
    #expect(codex.options.first?.selected == true)

    // Claude Code's AskUserQuestion: descriptions under the options, and
    // the last option past a separator.
    let question = try #require(AgentPromptMenu.read(from: [
        "⏺ I need one decision before I continue.",
        "",
        "────────────────────────────────────────────────",
        " ☐ Storage",
        "",
        "Which storage backend should I use?",
        "",
        "  1. SQLite",
        "     Embedded, no server",
        "❯ 2. Postgres",
        "     Needs a running server",
        "  3. Type something.",
        "────────────────────────────────────────────────",
        "  4. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]))
    #expect(question.kind == "question")
    #expect(question.question == "Which storage backend should I use?")
    #expect(question.options.map(\.label) == ["SQLite", "Postgres", "Type something.", "Chat about this"])
    #expect(question.options.map(\.detail) == ["Embedded, no server", "Needs a running server", nil, nil])
    #expect(question.options.map(\.selected) == [false, true, false, false])

    // Codex's picker: the description beside the label.
    let picker = try #require(AgentPromptMenu.read(from: [
        "  Question 1/1",
        "  Which test runner should the new suite use?",
        "",
        "› 1. Swift Testing  Matches the rest of the package",
        "  2. XCTest         Works with the older CI image",
        "  3. None of the above  Optionally, add details in notes (tab)",
        "",
        "  tab to add notes | enter to submit answer | esc to interrupt",
    ]))
    #expect(picker.options.map(\.label) == ["Swift Testing", "XCTest", "None of the above"])
    #expect(picker.options[1].detail == "Works with the older CI image")

    // No menu: a composer, a numbered answer, nothing.
    #expect(AgentPromptMenu.read(from: screenLines(claudeComposer)) == nil)
    #expect(AgentPromptMenu.read(from: ["Steps:", "1. Build", "2. Test", "> "]) == nil)
    #expect(AgentPromptMenu.read(from: []) == nil)
}

@Test func answerPromptChoicesMatchANumberOrALabel() throws {
    let prompt = try #require(AgentPromptMenu.read(from: screenLines(claudeBashPermission())))
    func number(_ choice: String) -> Int? {
        if case .option(let option) = AgentPromptMenu.match(choice, in: prompt) { return option.number }
        return nil
    }
    #expect(number("2") == 2)
    #expect(number(" 3. ") == 3)
    #expect(number("4") == nil)
    // The whole label first: "Yes" is option 1, not ambiguous with 2.
    #expect(number("yes") == 1)
    #expect(number("No, and tell Claude what to do differently") == 3)
    #expect(number("yes, and don’t ask") == 2)
    #expect(number("don't ask again") == 2)
    #expect(number("no") == 3)
    #expect(AgentPromptMenu.match("ye", in: prompt) == .ambiguous([prompt.options[0], prompt.options[1]]))
    #expect(AgentPromptMenu.match("maybe", in: prompt) == .none)
    #expect(AgentPromptMenu.match("  ", in: prompt) == .none)
}

// MARK: - Through the control server

@MainActor
private func answerPromptConfiguration() -> PersistentLocalSessions.Configuration {
    var configuration = PersistentHarness.fastConfiguration
    configuration.reconnectDelay = (30, 30)
    configuration.hostScreenReuseInterval = 0
    configuration.hostScreenWait = .milliseconds(500)
    return configuration
}

/// A restored Claude agent tab whose adapter waits: its screen and input go
/// through the fake host.
@MainActor
private func restoreAnsweringAgent(
    _ harness: PersistentHarness,
    into workspace: TerminalWorkspace,
    screen: String,
    programStatus: [ProgramStatus] = []
) async throws -> TerminalSession {
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .agent, title: "Claude", agentName: "Claude", launchCommand: "claude",
        workingDirectory: harness.project.path, projectRoot: harness.project.path,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "session-agent", owned: true)
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
        repositoryRoot: harness.project.path,
        records: [record], workspace: workspace
    ))
    workspace.restoreSessions(
        result.sessions,
        from: WorktreeStateRecord(root: harness.project.path, sessions: [record]),
        launchingAdapters: false
    )
    return try #require(result.sessions.first)
}

private func typedInput(_ harness: PersistentHarness) -> [String] {
    harness.fake.requests("send_input").compactMap { request in
        request.string("data").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}

/// The fake agent's menu follows the arrow keys it is sent.
private func moveHighlightOnArrows(_ harness: PersistentHarness, from start: Int) {
    let fake = harness.fake
    let selected = LockedValue(start)
    fake.respond = { request, _ in
        guard request.op == "send_input",
              let data = request.string("data").flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if text == "\u{1B}[B" { selected.update { min($0 + 1, 3) } }
        if text == "\u{1B}[A" { selected.update { max($0 - 1, 1) } }
        if text == "\r" {
            fake.screenText = claudeComposer
        } else {
            fake.screenText = claudeBashPermission(selected: selected.value)
        }
        return nil
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (Value) -> Value) { lock.withLock { stored = change(stored) } }
}

@Test @MainActor func answerPromptRefusedInputCarriesTheMenuAndAnswerPromptPicksAnOption() async throws {
    let harness = try PersistentHarness(configuration: answerPromptConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    // An agent that reports nothing: only its screen says it asks.
    let agent = try await restoreAnsweringAgent(harness, into: workspace, screen: claudeBashPermission())

    let refused = try await control.send(.sendProcessInput(.init(
        processID: agent.id.uuidString, text: "carry on", submit: true
    )))
    #expect(refused.error?.code == "agent_awaiting_permission")
    #expect(refused.error?.message.contains("answer_prompt") == true)
    let prompt = try #require(refused.error?.prompt)
    #expect(prompt.kind == "permission")
    #expect(prompt.options.count == 3)
    #expect(prompt.options.first?.selected == true)

    // An option no label names, and one several do: nothing is typed.
    let unknown = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "maybe")))
    #expect(unknown.error?.code == "unknown_choice")
    #expect(unknown.error?.prompt?.options.count == 3)
    let ambiguous = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "ye")))
    #expect(ambiguous.error?.code == "ambiguous_choice")
    #expect(typedInput(harness).isEmpty)

    // "Yes, and don't ask again": one Down, then, once the screen shows
    // it highlighted, Enter.
    moveHighlightOnArrows(harness, from: 1)
    let answered = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "don't ask again")))
    guard case .answerPrompt(let result)? = answered.result else {
        Issue.record("Expected answerPrompt, got \(String(describing: answered))")
        return
    }
    #expect(result.answered.number == 2)
    #expect(result.prompt.question == "Do you want to proceed?")
    #expect(typedInput(harness) == ["\u{1B}[B", "\r"])
    #expect(result.sentBytes == 4)

    // The menu is gone: nothing to answer.
    let again = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "1")))
    #expect(again.error?.code == "no_prompt")
    #expect(typedInput(harness) == ["\u{1B}[B", "\r"])
}

@Test @MainActor func answerPromptPressesNoEnterWhenTheHighlightDoesNotMove() async throws {
    let harness = try PersistentHarness(configuration: answerPromptConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let agent = try await restoreAnsweringAgent(harness, into: workspace, screen: claudeBashPermission(selected: 3))
    // The highlighted option itself: Enter only.
    let fake = harness.fake
    fake.respond = { request, _ in
        if request.op == "send_input" { fake.screenText = claudeComposer }
        return nil
    }
    let answered = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "3")))
    #expect(answered.error == nil)
    #expect(typedInput(harness) == ["\r"])

    // A menu that ignores the arrows: Enter would pick the wrong option.
    fake.respond = nil
    fake.screenText = claudeBashPermission(selected: 3)
    let stuck = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "Yes")))
    #expect(stuck.error?.code == "prompt_not_answered")
    #expect(typedInput(harness) == ["\r", "\u{1B}[A", "\u{1B}[A"])
}

@Test @MainActor func answerPromptFollowsAnAgentThatReportsItsStatus() async throws {
    let harness = try PersistentHarness(configuration: answerPromptConfiguration())
    let workspace = harness.workspace()
    let control = try ParityControlServer(workspace: workspace)
    defer {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let blocked = [ProgramStatus(state: .blocked, kind: .permission, app: "claude-code", message: "approve Bash: rm -rf build")]
    let agent = try await restoreAnsweringAgent(
        harness, into: workspace, screen: claudeBashPermission(), programStatus: blocked
    )
    #expect(try await control.process(agent).agentActivityState == "permission")
    // Its status reads the menu off the host's screen.
    let status = try await control.send(.getProcessStatus(.init(processID: agent.id.uuidString)))
    guard case .getProcessStatus(let shown)? = status.result else {
        Issue.record("Expected getProcessStatus, got \(String(describing: status))")
        return
    }
    #expect(shown.prompt?.kind == "permission")
    #expect(shown.prompt?.options.count == 3)
    moveHighlightOnArrows(harness, from: 1)
    let answered = try await control.send(.answerPrompt(.init(processID: agent.id.uuidString, choice: "No")))
    guard case .answerPrompt(let result)? = answered.result else {
        Issue.record("Expected answerPrompt, got \(String(describing: answered))")
        return
    }
    #expect(result.answered.number == 3)
    #expect(typedInput(harness) == ["\u{1B}[B", "\u{1B}[B", "\r"])
}
