import CherryControl
import Foundation
import Testing
@testable import Cherry

@MainActor
private extension ControlAgentWaitHarness {
    /// Shorter monitor intervals for tests.
    func useFastMonitors() {
        let monitors = server.monitors
        monitors.sampleInterval = .milliseconds(50)
        monitors.settleInterval = 0.3
        monitors.wakeQuietInterval = 0.3
        monitors.wakeMinimumInterval = 0
        monitors.humanTypingInterval = 0
        monitors.refreshInterval = 0
    }

    func subscribe(_ request: SubscribeRequest) async throws -> SubscribeResult {
        let response = try await send(.subscribe(request))
        guard case .subscribe(let result)? = response.result else {
            throw CherryControlError(code: "subscribe_failed", message: "Expected subscribe result, got \(String(describing: response))")
        }
        return result
    }

    func events(_ id: String, cursor: Int? = nil, timeoutMilliseconds: Int = 8_000) async throws -> WaitForEventsResult {
        let response = try await send(.waitForEvents(.init(subscriptionID: id, cursor: cursor, timeoutMilliseconds: timeoutMilliseconds)))
        guard case .waitForEvents(let result)? = response.result else {
            throw CherryControlError(code: "wait_failed", message: "Expected waitForEvents result, got \(String(describing: response))")
        }
        return result
    }

    func output(of session: TerminalSession) async throws -> String {
        let response = try await send(.getProcessOutput(.init(processID: session.id.uuidString, lineLimit: 200)))
        guard case .getProcessOutput(let output)? = response.result else { return "" }
        return output.lines.joined(separator: "\n")
    }

    func screen(_ text: String, on session: TerminalSession) {
        session.ingestTestingData(Data("\u{1B}[2J\u{1B}[H".utf8) + Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    /// A whole frame on the alternate screen (Claude Code's), so no earlier
    /// frame stays above it.
    func alternateScreen(_ lines: [String], on session: TerminalSession) {
        session.ingestTestingData(Data(("\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\r\n")).utf8))
    }

    func status(of session: TerminalSession) async throws -> ProcessSummary {
        let response = try await send(.getProcessStatus(.init(processID: session.id.uuidString)))
        guard case .getProcessStatus(let status)? = response.result else {
            throw CherryControlError(code: "status_failed", message: "Expected getProcessStatus result, got \(String(describing: response))")
        }
        return status.process
    }
}

@MainActor
@Suite(.serialized)
struct ControlAgentMonitorTests {
    @Test func doneEventWhenAWatchedAgentFinishesItsTurn() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.screen("✶ Reticulating… (esc to interrupt)\n", on: worker)
        try await Task.sleep(for: .milliseconds(150))

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        #expect(subscribed.watching.first?.status == "working")
        #expect(subscribed.subscription.wake == false)
        let id = subscribed.subscription.subscriptionID

        let none = try await harness.events(id, timeoutMilliseconds: 300)
        #expect(none.events.isEmpty && none.timedOut)

        harness.screen("⏺ Done.\n\n❯ \n", on: worker)
        let waited = try await harness.events(id)
        #expect(waited.events.map(\.type) == [.done])
        #expect(waited.events.first?.processID == worker.id.uuidString)
        #expect(waited.events.first?.initial == false)
        #expect(waited.watching.first?.status == "idle")

        // Read once: the next call has nothing new.
        let again = try await harness.events(id, timeoutMilliseconds: 200)
        #expect(again.events.isEmpty)
    }

    @Test func needsInputPermissionAndClosedEvents() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.screen("✶ Reticulating… (esc to interrupt)\n", on: worker)
        try await Task.sleep(for: .milliseconds(150))
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        harness.screen(claudeQuestionScreen, on: worker)
        let question = try await harness.events(id)
        #expect(question.events.map(\.type) == [.needsInput])

        harness.screen("""
        Bash command
          rm -rf build
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and don't ask again for rm commands
          3. No, and tell Claude what to do differently (esc)
        """, on: worker)
        let permission = try await harness.events(id)
        #expect(permission.events.map(\.type) == [.permission])

        let closed = try await harness.send(.closeProcess(.init(processID: worker.id.uuidString)))
        #expect(closed.error == nil)
        let gone = try await harness.events(id)
        #expect(gone.events.map(\.type) == [.closed])
        #expect(gone.watching.first?.status == "closed")
    }

    @Test func exitedEventCarriesTheExitCode() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let script = harness.projectRoot.appendingPathComponent("exits.sh")
        try "#!/bin/sh\nsleep 1\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let worker = try await harness.spawnAgent(named: "Exiter", command: script.path)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        let exited = try await harness.events(id)
        #expect(exited.events.map(\.type) == [.exited])
        #expect(exited.events.first?.exitCode == 3)
    }

    /// An agent whose turn ended before the subscription is reported done
    /// at once, so a caller that subscribes after spawning misses nothing;
    /// its event carries the turn the message started.
    @Test func turnThatEndedBeforeSubscribingIsReportedAtOnce() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.2, working: 0.4)
        let worker = try await harness.spawnAgent(named: "Fakeagent", command: script)
        try await Task.sleep(for: .milliseconds(600))
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "hi", submit: true)))
        let waited = try await harness.wait(worker, quietMilliseconds: 300, timeoutMilliseconds: 10_000)
        #expect(waited.reason == .idle)
        #expect(waited.agentTurn == 1)
        #expect(waited.turnStarted == true)
        try await Task.sleep(for: .milliseconds(400))

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        let events = try await harness.events(subscribed.subscription.subscriptionID, timeoutMilliseconds: 500)
        #expect(events.events.map(\.type) == [.done])
        #expect(events.events.first?.initial == true)
        #expect(events.events.first?.agentTurn == 1)
    }

    /// An agent that goes back to work by itself after its turn ended (it
    /// answers a background shell's result) starts a turn MCP sees: its
    /// `agent_turn` grows, its turn is active while it works, `done` fires
    /// again when that turn ends, and `wait_for_process_idle` waits for it.
    @Test func turnTheAgentResumesByItselfIsDoneAgain() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        let sent = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "rebuild the index", submit: true)))
        #expect(sent.error == nil)
        try await Task.sleep(for: .milliseconds(300))
        harness.alternateScreen(AgentScreenActivityTests.claudeStaleWorkingFrame, on: worker)
        try await Task.sleep(for: .milliseconds(200))
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        harness.alternateScreen(AgentScreenActivityTests.claudeFinishedTurn, on: worker)
        let first = try await harness.events(id)
        #expect(first.events.map(\.type) == [.done])
        #expect(first.events.first?.agentTurn == 1)
        #expect(try await harness.status(of: worker).agentTurnState == "completed")

        for frame in 0..<8 {
            harness.alternateScreen(AgentScreenActivityTests.claudeResumedFrame(frame), on: worker)
            try await Task.sleep(for: .milliseconds(250))
        }
        let resumed = try await harness.status(of: worker)
        #expect(resumed.agentTurn == 2)
        #expect(resumed.agentTurnState == "active")
        #expect(resumed.agentActivityState == "working")
        let busy = try await harness.events(id, timeoutMilliseconds: 0)
        #expect(busy.events.isEmpty)
        #expect(busy.watching.first?.status == "working")

        harness.alternateScreen(AgentScreenActivityTests.claudeResumedTurnFinished, on: worker)
        let second = try await harness.events(id)
        #expect(second.events.map(\.type) == [.done])
        #expect(second.events.first?.agentTurn == 2)
        let waited = try await harness.wait(worker, quietMilliseconds: 300)
        #expect(waited.reason == .idle)
        #expect(waited.agentTurn == 2)
        #expect(try await harness.status(of: worker).agentTurnState == "completed")
    }

    @Test func explicitCursorRereadsUntilAcknowledged() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.screen("✶ Reticulating… (esc to interrupt)\n", on: worker)
        try await Task.sleep(for: .milliseconds(150))
        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        let id = subscribed.subscription.subscriptionID
        #expect(subscribed.subscription.cursor == 0)

        harness.screen(claudeQuestionScreen, on: worker)
        let first = try await harness.events(id, cursor: 0)
        #expect(first.events.count == 1)
        // The same cursor again: the event was not acknowledged.
        let replay = try await harness.events(id, cursor: 0, timeoutMilliseconds: 200)
        #expect(replay.events.map(\.seq) == first.events.map(\.seq))
        // The returned cursor acknowledges it.
        let after = try await harness.events(id, cursor: first.cursor, timeoutMilliseconds: 200)
        #expect(after.events.isEmpty)
    }

    @Test func outputMatchReportsOnlyNewLines() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let command = try #require(harness.workspace.sessions.first)
        command.ingestTestingData(Data("old error line\r\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        let id = try await harness.subscribe(.init(
            processIDs: [command.id.uuidString], events: ["output_match"], outputPattern: "ERROR"
        )).subscription.subscriptionID
        try await Task.sleep(for: .milliseconds(200))

        command.ingestTestingData(Data("compiling\r\nerror: boom\r\n".utf8))
        let matched = try await harness.events(id)
        #expect(matched.events.map(\.type) == [.outputMatch])
        #expect(matched.events.first?.matchedLine == "error: boom")
    }

    @Test func unknownEventTypeAndEmptySubscriptionAreRefused() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        let unknown = try await harness.send(.subscribe(.init(processIDs: [worker.id.uuidString], events: ["finished"])))
        #expect(unknown.error?.code == "invalid_argument")
        let empty = try await harness.send(.subscribe(.init()))
        #expect(empty.error?.code == "missing_argument")
        let missing = try await harness.send(.subscribe(.init(processIDs: [UUID().uuidString])))
        #expect(missing.error?.code == "terminal_not_found")
        let noSubscription = try await harness.send(.waitForEvents(.init(subscriptionID: "mon-nope", timeoutMilliseconds: 0)))
        #expect(noSubscription.error?.code == "unknown_subscription")
    }

    /// The subscriber's tab gets one line naming the subscription and the
    /// counts once its agent is idle, never while it works.
    @Test func wakeLineIsTypedIntoTheIdleSubscriberOnly() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let script = try harness.fakeAgentScript(thinking: 0.1, working: 0.3)
        let orchestrator = try await harness.spawnAgent(named: "Fakeagent", command: script)
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        harness.screen("✶ Reticulating… (esc to interrupt)\n", on: worker)
        try await Task.sleep(for: .milliseconds(800))

        let subscribed = try await harness.subscribe(.init(
            processIDs: [worker.id.uuidString], subscriberProcessID: orchestrator.id.uuidString
        ))
        #expect(subscribed.subscription.wake == true)
        #expect(subscribed.subscription.subscriberProcessID == orchestrator.id.uuidString)
        let id = subscribed.subscription.subscriptionID

        // The orchestrator is busy: no wake line yet.
        orchestrator.ingestTestingData(Data("\r\n✶ Thinking… (esc to interrupt)".utf8))
        harness.screen("⏺ Done.\n\n❯ \n", on: worker)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!(try await harness.output(of: orchestrator)).contains("[cherry] Monitor"))

        // Idle again: one line, with counts only.
        orchestrator.ingestTestingData(Data("\r\u{1B}[2K\r\n❯ \r\n".utf8))
        var typed = ""
        for _ in 0..<60 {
            typed = try await harness.output(of: orchestrator)
            if typed.contains("handled [cherry] Monitor") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(typed.contains("[cherry] Monitor \(id): 1 event ready (1 done). Call the cherry wait_for_events tool with subscription_id \"\(id)\" to read them."))
        #expect(!typed.contains("Done."), "the wake line carries no worker text")
        // The wake line is a turn submitted to the subscriber.
        #expect(orchestrator.agentSubmittedTurnCount == 1)
        #expect(orchestrator.agentTurnCount == 1)

        // Not woken again for the same events.
        try await Task.sleep(for: .milliseconds(1_000))
        let count = try await harness.output(of: orchestrator).components(separatedBy: "handled [cherry] Monitor").count - 1
        #expect(count == 1)
        let events = try await harness.events(id, timeoutMilliseconds: 0)
        #expect(events.events.map(\.type) == [.done])
    }

    @Test func wakeLineSettingOffAndUnconfirmedSubscriberOnlyPoll() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let orchestrator = try await harness.spawnAgent(named: "Claude")
        let worker = try await harness.spawnAgent(named: "Codex")

        // A subscriber Cherry cannot confirm is the caller gets no wake line.
        harness.server.callerSessionResolverForTesting = { _ in nil }
        let unconfirmed = try await harness.subscribe(.init(
            processIDs: [worker.id.uuidString], subscriberProcessID: orchestrator.id.uuidString
        ))
        #expect(unconfirmed.subscription.wake == false)
        #expect(unconfirmed.subscription.subscriberProcessID == nil)
        #expect(unconfirmed.subscription.wakeUnavailableReason?.contains("could not confirm") == true)

        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        harness.defaults.set(false, forKey: AgentMonitorRegistry.wakeLinesDefaultsKey)
        let off = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        #expect(off.subscription.wake == false)
        #expect(off.subscription.wakeUnavailableReason?.contains("Settings") == true)

        // Closing the subscriber's tab ends its subscriptions.
        let closed = try await harness.send(.closeProcess(.init(processID: orchestrator.id.uuidString)))
        #expect(closed.error == nil)
        try await Task.sleep(for: .milliseconds(300))
        let gone = try await harness.send(.waitForEvents(.init(subscriptionID: off.subscription.subscriptionID, timeoutMilliseconds: 0)))
        #expect(gone.error?.code == "unknown_subscription")
    }

    @Test func subAgentsAreWatchedIncludingLaterOnes() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let orchestrator = try await harness.spawnAgent(named: "Claude")
        harness.server.callerSessionResolverForTesting = { _ in orchestrator }
        let subscribed = try await harness.subscribe(.init(subAgents: true, wake: false))
        #expect(subscribed.watching.isEmpty)

        try harness.settings.upsertAgent(AgentToolDefinition(name: "Codex", command: "/bin/cat"))
        let spawned = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Codex", parentAgentID: orchestrator.id.uuidString)))
        guard case .spawnProcess(let child)? = spawned.result else {
            Issue.record("spawn failed: \(spawned)")
            return
        }
        let childSession = try #require(harness.workspace.session(id: child.process.id))
        childSession.ingestTestingData(Data("✶ Working… (esc to interrupt)".utf8))
        try await Task.sleep(for: .milliseconds(300))
        harness.screen(claudeQuestionScreen, on: childSession)
        let events = try await harness.events(subscribed.subscription.subscriptionID)
        #expect(events.events.map(\.type) == [.needsInput])
        #expect(events.events.first?.processID == child.process.id)
    }
}
