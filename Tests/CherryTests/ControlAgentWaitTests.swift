import CherryControl
@testable import CherryMCP
import Darwin
import Foundation
import MCP
import Testing
@testable import Cherry

/// A control server on a private socket with one host-managed workspace,
/// for the agent wait tests: agents run `/bin/cat` (screens are injected
/// with `ingestTestingData`) or a fake agent script.
@MainActor
final class ControlAgentWaitHarness {
    let defaultsName: String
    let defaults: UserDefaults
    let settings: AgentSettings
    let projectRoot: URL
    let workspace: TerminalWorkspace
    let socketURL: URL
    let server: CherryControlServer

    init() throws {
        defaultsName = "CherryTests.ControlAgentWait.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let socketDirectory = URL(
            fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        socketURL = socketDirectory.appendingPathComponent("control.sock")
        settings = AgentSettings(defaults: defaults)
        _ = settings.addProject(path: projectRoot.path)
        workspace = TerminalWorkspace(projectRoot: projectRoot.path, launchBackend: .hostManaged)
        server = CherryControlServer(
            workspace: workspace,
            socketURL: socketURL,
            agentSettings: settings,
            monitorDefaults: defaults,
            taskBoard: AgentTaskBoard()
        )
    }

    func spawnAgent(named name: String, command: String = "/bin/cat") async throws -> TerminalSession {
        try settings.upsertAgent(AgentToolDefinition(name: name, command: command))
        let response = try await send(.spawnProcess(.init(kind: "agent", name: name)))
        guard case .spawnProcess(let spawned)? = response.result else {
            throw CherryControlError(code: "spawn_failed", message: "Expected spawnProcess result, got \(String(describing: response))")
        }
        return try #require(workspace.session(id: spawned.process.id))
    }

    /// A fake agent CLI that reports its status as Claude Code does
    /// (OSC 7501): `idle` at its composer; for each submitted line it
    /// echoes it into the transcript with the composer still visible,
    /// thinks for `thinking` seconds before it reports `working` (as a CLI
    /// takes a moment to start a turn), works for `working` seconds, then
    /// answers and reports `done`.
    func fakeAgentScript(thinking: Double, working: Double) throws -> String {
        let script = projectRoot.appendingPathComponent("fake-agent.sh")
        let body = """
        #!/bin/sh
        stty -echo 2>/dev/null
        printf '\\342\\235\\257 \\n\\033]7501;state=idle:app=fake\\033\\\\'
        while IFS= read -r line; do
          printf '> %s\\n\\n\\342\\235\\257 \\n' "$line"
          sleep \(thinking)
          printf '\\033]7501;state=working:app=fake\\033\\\\\\342\\234\\266 Reticulating\\342\\200\\246'
          sleep \(working)
          printf '\\r\\033[2K\\342\\217\\272 handled %s\\n\\n\\342\\235\\257 \\n\\033]7501;state=done:app=fake\\033\\\\' "$line"
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script.path
    }

    func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        let socketURL = socketURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try CherryControlClient(socketURL: socketURL, timeout: 70).send(request)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func wait(_ session: TerminalSession, quietMilliseconds: Int = 1_000, timeoutMilliseconds: Int = 10_000) async throws -> WaitForProcessIdleResult {
        let response = try await send(.waitForProcessIdle(.init(
            processID: session.id.uuidString,
            quietMilliseconds: quietMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds,
            lineLimit: 40
        )))
        guard case .waitForProcessIdle(let waited)? = response.result else {
            throw CherryControlError(code: "wait_failed", message: "Expected waitForProcessIdle result, got \(String(describing: response))")
        }
        return waited
    }

    /// The agent sends an OSC 7501 program status report with `body`.
    func report(_ body: String, on session: TerminalSession) {
        session.ingestTestingData(Data("\u{1B}]7501;\(body)\u{1B}\\".utf8))
    }

    func stop() {
        server.stop()
        workspace.sessions.forEach { $0.stop() }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

/// Claude Code's AskUserQuestion menu: a question to the user, not a
/// permission prompt.
let claudeQuestionScreen = """
⏺ I need one decision before I continue.

────────────────────────────────────────────────
 ☐ Approach

Which storage backend should I use?

❯ 1. SQLite
     Embedded, no server
  2. Postgres
     Needs a running server
  3. Type something.
────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

@MainActor
@Suite(.serialized)
struct ControlAgentWaitTests {
    /// The race: a message submitted to an idle agent leaves its composer
    /// on screen until the agent's first working frame. The wait must not
    /// take that composer for the end of the turn.
    @Test func waitAfterMessageDoesNotReturnBeforeTheTurnStarted() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 1.8, working: 1.2)
        let session = try await harness.spawnAgent(named: "Fakeagent", command: script)
        try await Task.sleep(for: .milliseconds(800))

        let sent = try await harness.send(.sendProcessInput(.init(
            processID: session.id.uuidString, text: "hello", submit: true
        )))
        #expect(sent.error == nil)
        let waited = try await harness.wait(session, quietMilliseconds: 1_000, timeoutMilliseconds: 15_000)

        #expect(waited.reason == .idle)
        #expect(waited.turnStarted == true)
        #expect(waited.agentTurn == 1)
        #expect(waited.output.lines.joined(separator: "\n").contains("handled hello"), "the wait returned before the turn ran: \(waited.output.lines)")
    }

    /// A question to the user (Claude's AskUserQuestion) ends a wait with
    /// its own reason, not as an idle agent whose turn is done.
    @Test func waitReturnsNeedsInputForAQuestionMenu() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let session = try await harness.spawnAgent(named: "Claude")
        harness.report("state=working:app=claude-code", on: session)
        try await Task.sleep(for: .milliseconds(150))
        session.ingestTestingData(Data("\u{1B}[2J\u{1B}[H".utf8) + Data(claudeQuestionScreen.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        harness.report("state=blocked:app=claude-code:kind=question:msg=V2hpY2ggc3RvcmFnZSBiYWNrZW5kPw==", on: session)

        let startedAt = Date()
        let waited = try await harness.wait(session, quietMilliseconds: 500, timeoutMilliseconds: 8_000)
        #expect(waited.reason.rawValue == "needs_input")
        #expect(waited.agentActivityState == "needs_input")
        #expect(Date().timeIntervalSince(startedAt) < 5)
    }

    /// Typing a message into a question menu answers it (Enter picks the
    /// highlighted option): MCP refuses, as at a permission prompt, when
    /// the agent reports it is blocked on a question, and quotes it.
    @Test func messageIsNotTypedIntoAQuestionTheAgentReports() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let session = try await harness.spawnAgent(named: "Claude")
        harness.report("state=blocked:app=claude-code:kind=question:msg=V2hpY2ggc3RvcmFnZSBiYWNrZW5kPw==", on: session)

        let response = try await harness.send(.sendProcessInput(.init(
            processID: session.id.uuidString, text: "use sqlite", submit: true
        )))
        #expect(response.error?.code == "agent_awaiting_input")
        #expect(response.error?.message.contains("Which storage backend?") == true)
    }

    /// An agent that reports nothing: its screen is read for the menu.
    @Test func messageIsNotTypedIntoAQuestionMenu() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let session = try await harness.spawnAgent(named: "Claude")
        session.ingestTestingData(Data(claudeQuestionScreen.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        try await Task.sleep(for: .milliseconds(150))

        let response = try await harness.send(.sendProcessInput(.init(
            processID: session.id.uuidString, text: "use sqlite", submit: true
        )))
        #expect(response.error?.code == "agent_awaiting_input")
    }

    /// A tab closed while a wait runs ends the wait at once, as closed.
    @Test func waitEndsWhenTheProcessIsClosed() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let session = try await harness.spawnAgent(named: "Claude")
        harness.report("state=working:app=claude-code", on: session)
        try await Task.sleep(for: .milliseconds(150))

        let processID = session.id.uuidString
        let startedAt = Date()
        async let waited = harness.wait(session, quietMilliseconds: 500, timeoutMilliseconds: 12_000)
        try await Task.sleep(for: .milliseconds(400))
        let closed = try await harness.send(.closeProcess(.init(processID: processID)))
        #expect(closed.error == nil)
        let result = try await waited
        #expect(result.reason.rawValue == "closed")
        #expect(Date().timeIntervalSince(startedAt) < 5)
    }

    /// Codex gives an MCP tool call 60 s by default: a wait with the
    /// default timeout must answer well before that.
    @Test func defaultWaitsFitInASixtySecondToolTimeout() throws {
        let wait = try #require(CherryMCPTools.clientTimeout(for: "wait_for_process_idle", arguments: [:]))
        #expect(wait <= 55)
        let message = try #require(CherryMCPTools.clientTimeout(for: "send_agent_message", arguments: [:]))
        #expect(message <= 55)
        let events = try #require(CherryMCPTools.clientTimeout(for: "wait_for_events", arguments: [:]))
        #expect(events <= 55)
        // wait_for_events never waits longer, whatever it is asked.
        #expect(CherryMCPTools.clientTimeout(for: "wait_for_events", arguments: ["timeout_ms": .int(300_000)]) == events)
        let advertised = Set(CherryMCPTools.all.map(\.name))
        #expect(advertised.isSuperset(of: ["subscribe", "unsubscribe", "wait_for_events", "list_subscriptions"]))
    }
}
