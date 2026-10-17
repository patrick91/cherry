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
        monitors.outputQuietInterval = 1
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

    /// A fake agent CLI that reports no status (as Amp or Codex): for each
    /// submitted line it echoes it, counts up on screen every 0.1 s for
    /// `working` seconds (60 s for a line that starts with `slow`), then
    /// answers at its composer; an empty line (Return on an empty composer)
    /// draws nothing, as theirs does. One process that forks nothing per
    /// tick, so a loaded machine does not pause its output.
    func silentAgentScript(working: Double) throws -> String {
        let script = projectRoot.appendingPathComponent("silent-agent.pl")
        let body = """
        #!/usr/bin/perl
        use strict;
        use warnings;
        $| = 1;
        system("stty -echo 2>/dev/null");
        print "\\xe2\\x9d\\xaf \\n";
        while (my $line = <STDIN>) {
          chomp $line;
          next if $line eq "";
          print "> $line\\n\\n";
          my $ticks = $line =~ /^slow/ ? 600 : \(Int(working * 10));
          for my $i (1 .. $ticks) {
            print "\\r\\xe2\\x9c\\xb6 Working $i";
            select(undef, undef, undef, 0.1);
          }
          print "\\r\\033[2K\\xe2\\x8f\\xba handled $line\\n\\n\\xe2\\x9d\\xaf \\n";
        }
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script.path
    }

    /// Reads `id`'s events (each once) until `done` holds of what was read,
    /// at most `seconds`; returns what was read.
    func events(_ id: String, seconds: Double = 30, until done: ([MonitorEvent]) -> Bool) async throws -> [MonitorEvent] {
        var read: [MonitorEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            read += try await events(id, timeoutMilliseconds: 200).events
            if done(read) { return read }
        }
        Issue.record("Not seen in \(seconds) s; read \(read)")
        return read
    }

    /// Reads `id`'s events until its first watched process's status is
    /// `status`, at most `seconds`; returns the events read meanwhile.
    func events(_ id: String, untilStatus status: String, seconds: Double = 30) async throws -> [MonitorEvent] {
        var read: [MonitorEvent] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let result = try await events(id, timeoutMilliseconds: 100)
            read += result.events
            if result.watching.first?.status == status { return read }
        }
        Issue.record("Status never \(status) in \(seconds) s; read \(read)")
        return read
    }

    /// Waits until `session`'s output contains `text`, at most `seconds`.
    func waitForOutput(_ text: String, of session: TerminalSession, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await output(of: session).contains(text) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(text) not seen in \(seconds) s: \(try await output(of: session))")
    }

    /// Spawns `name` (`/bin/cat`) as a Cherry task's worker; returns its
    /// tab and task id once its kickoff is on screen.
    func spawnTaskWorker(named name: String, task brief: String) async throws -> (session: TerminalSession, taskID: String) {
        try settings.upsertAgent(AgentToolDefinition(name: name, command: "/bin/cat"))
        let response = try await send(.spawnProcess(.init(kind: "agent", name: name, task: brief)))
        guard case .spawnProcess(let spawned)? = response.result, let taskID = spawned.task?.taskID else {
            throw CherryControlError(code: "spawn_failed", message: "Expected a task spawn, got \(String(describing: response))")
        }
        let session = try #require(workspace.session(id: spawned.process.id))
        for _ in 0..<100 {
            if try await output(of: session).contains("You are Cherry task \(taskID)") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return (session, taskID)
    }

    /// An agent tab attached to `sessionID` of a host (as File › Persistent
    /// Sessions attaches one), shown in this workspace with its attach
    /// adapter launched: here `command`, which the host-managed tab runs as
    /// its program. `control` (a `FakeControlHelper`'s, whose identity is
    /// `host-a`) stands in for its host, so nothing reaches a daemon.
    func attachedAgent(named name: String, command: String, sessionID: String, control: HostControl) -> TerminalSession {
        let record = WorkspaceSessionRecord(
            id: UUID(), kind: .agent, title: name, agentName: name, launchCommand: command,
            workingDirectory: projectRoot.path, projectRoot: projectRoot.path
        )
        let session = TerminalSession(
            id: record.id, title: name, subtitle: "", tint: .systemOrange,
            workingDirectory: projectRoot.path, projectRoot: projectRoot.path, launchShell: false,
            kind: .agent, agentName: name, launchCommand: command, launchBackend: .hostManaged,
            hostedAttachment: HostedSessionAttachment(
                host: .local, hostID: "host-a", sessionID: sessionID, name: name,
                remoteWorkingDirectory: projectRoot.path, executablePath: "/nonexistent/cherry"
            )
        )
        session.attachedHostControlProvider = { _ in control }
        workspace.restoreSessions(
            [session], from: WorktreeStateRecord(root: projectRoot.path, sessions: [record]), launchingAdapters: false
        )
        #expect(session.reconnectHostedSession(), "its adapter launches")
        return session
    }

    func reportResult(_ summary: String, from worker: TerminalSession) async throws {
        let resolver = server.callerSessionResolverForTesting
        server.callerSessionResolverForTesting = { _ in worker }
        defer { server.callerSessionResolverForTesting = resolver }
        let response = try await send(.reportResult(.init(value: .string(summary), status: "ok", summary: summary)))
        guard case .reportResult? = response.result else {
            throw CherryControlError(code: "report_failed", message: "Expected reportResult, got \(String(describing: response))")
        }
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
        harness.report("state=working:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(150))

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        #expect(subscribed.watching.first?.status == "working")
        #expect(subscribed.subscription.wake == false)
        let id = subscribed.subscription.subscriptionID

        let none = try await harness.events(id, timeoutMilliseconds: 300)
        #expect(none.events.isEmpty && none.timedOut)

        // Its last frame, then its report (as Claude Code sends them).
        harness.screen("⏺ Done.\n\n❯ \n", on: worker)
        try await Task.sleep(for: .milliseconds(100))
        harness.report("state=done:app=claude-code", on: worker)
        let waited = try await harness.events(id)
        #expect(waited.events.map(\.type) == [.done])
        #expect(waited.events.first?.processID == worker.id.uuidString)
        #expect(waited.events.first?.initial == false)
        #expect(waited.events.first?.basis == nil, "the agent reported it")
        #expect(waited.watching.first?.status == "idle")
        #expect(waited.watching.first?.taskID == nil)

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
        harness.report("state=working:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(150))
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        harness.screen(claudeQuestionScreen, on: worker)
        harness.report("state=blocked:app=claude-code:kind=question", on: worker)
        let question = try await harness.events(id)
        #expect(question.events.map(\.type) == [.needsInput])

        // "approve Bash: rm -rf build"
        harness.report("state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiBybSAtcmYgYnVpbGQ=", on: worker)
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
    /// answers a background shell's result) reports `working` again: its
    /// `agent_turn` grows, its turn is active while it works, `done` fires
    /// again when that turn ends, and `wait_for_process_idle` waits for it.
    @Test func turnTheAgentResumesByItselfIsDoneAgain() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.report("state=idle:app=claude-code", on: worker)
        let sent = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "rebuild the index", submit: true)))
        #expect(sent.error == nil)
        harness.report("state=working:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(200))
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        harness.report("state=done:app=claude-code", on: worker)
        let first = try await harness.events(id)
        #expect(first.events.map(\.type) == [.done])
        #expect(first.events.first?.agentTurn == 1)
        #expect(try await harness.status(of: worker).agentTurnState == "completed")

        harness.report("state=working:app=claude-code:msg=UmVhZGluZyB0aGUgc2hlbGwncyBvdXRwdXQ=", on: worker)
        let resumed = try await harness.status(of: worker)
        #expect(resumed.agentTurn == 2)
        #expect(resumed.agentTurnState == "active")
        #expect(resumed.agentActivityState == "working")
        #expect(resumed.programStatus?.message == "Reading the shell's output")
        let busy = try await harness.events(id, timeoutMilliseconds: 0)
        #expect(busy.events.isEmpty)
        #expect(busy.watching.first?.status == "working")

        harness.report("state=done:app=claude-code", on: worker)
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
        harness.report("state=working:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(150))
        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        let id = subscribed.subscription.subscriptionID
        #expect(subscribed.subscription.cursor == 0)

        harness.report("state=blocked:app=claude-code:kind=question", on: worker)
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
        harness.report("state=working:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(800))

        let subscribed = try await harness.subscribe(.init(
            processIDs: [worker.id.uuidString], subscriberProcessID: orchestrator.id.uuidString
        ))
        #expect(subscribed.subscription.wake == true)
        #expect(subscribed.subscription.subscriberProcessID == orchestrator.id.uuidString)
        let id = subscribed.subscription.subscriptionID

        // The orchestrator is busy: no wake line yet.
        harness.report("state=working:app=fake", on: orchestrator)
        harness.screen("⏺ Done.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!(try await harness.output(of: orchestrator)).contains("[cherry] Monitor"))

        // Idle again: one line, with counts only.
        harness.report("state=done:app=fake", on: orchestrator)
        var typed = ""
        for _ in 0..<60 {
            typed = try await harness.output(of: orchestrator)
            if typed.contains("handled [cherry] Monitor") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(typed.contains("[cherry] Monitor \(id): 1 event ready (1 done). Call the cherry wait_for_events tool with subscription_id \"\(id)\" to read them."))
        #expect(!typed.contains("Done."), "the wake line carries no worker text")
        // The wake line is a turn submitted to the subscriber, after the
        // turn it reported working on.
        #expect(orchestrator.agentSubmittedTurnCount == 1)
        #expect(orchestrator.agentTurnCount == 2)

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
        harness.report("state=working:app=codex", on: childSession)
        try await Task.sleep(for: .milliseconds(300))
        harness.screen(claudeQuestionScreen, on: childSession)
        harness.report("state=blocked:app=codex:kind=question", on: childSession)
        let events = try await harness.events(subscribed.subscription.subscriptionID)
        #expect(events.events.map(\.type) == [.needsInput])
        #expect(events.events.first?.processID == child.process.id)
    }

    // MARK: Agents that report no status

    /// An agent that reports nothing (Amp, Codex) stays `unknown`; its
    /// submitted turn is `done` once its output went quiet after it (the
    /// event says so), once per turn. Never given a turn, it is done with
    /// nothing, however still its screen.
    @Test func silentAgentIsDoneOnceItsOutputWentQuietAfterItsTurn() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.monitors.outputQuietInterval = 1.2
        harness.server.start()
        let script = try harness.silentAgentScript(working: 3)
        let worker = try await harness.spawnAgent(named: "Fakesilent", command: script)
        try await harness.waitForOutput("\u{276F}", of: worker)

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        #expect(subscribed.watching.first?.status == "unknown")
        let id = subscribed.subscription.subscriptionID
        let untouched = try await harness.events(id, timeoutMilliseconds: 2_000)
        #expect(untouched.events.isEmpty, "an agent never given a turn is not done")

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "hello", submit: true)))
        try await harness.waitForOutput("Working", of: worker)
        let busy = try await harness.events(id, timeoutMilliseconds: 1_000)
        #expect(busy.events.isEmpty, "done while its screen still changes: \(busy.events)")
        #expect(busy.watching.first?.status == "unknown")

        let waited = try await harness.events(id, timeoutMilliseconds: 30_000)
        #expect(waited.events.map(\.type) == [.done])
        #expect(waited.events.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(waited.events.first?.agentTurn == 1)
        #expect(waited.events.first?.initial == false)
        #expect(waited.watching.first?.status == "unknown", "its status stays what it reports: nothing")
        #expect(try await harness.output(of: worker).contains("handled hello"), "done before its turn ended")
        #expect(try await harness.status(of: worker).agentActivityState == "unknown")

        // Once per turn; the next turn is done again.
        let again = try await harness.events(id, timeoutMilliseconds: 2_000)
        #expect(again.events.isEmpty)
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "more", submit: true)))
        let second = try await harness.events(id, timeoutMilliseconds: 30_000)
        #expect(second.events.map(\.type) == [.done])
        #expect(second.events.first?.agentTurn == 2)
        #expect(second.events.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(try await harness.output(of: worker).contains("handled more"))
    }

    /// One already quiet after its turn when the subscription is made is
    /// reported at once, as an agent whose last turn completed is.
    @Test func silentAgentQuietAfterItsTurnIsDoneAtOnceWhenSubscribing() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let script = try harness.silentAgentScript(working: 0.3)
        let worker = try await harness.spawnAgent(named: "Fakesilent", command: script)
        try await harness.waitForOutput("\u{276F}", of: worker)
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "hi", submit: true)))
        try await harness.waitForOutput("handled hi", of: worker)
        // Read once more after its last write, so the subscription's first
        // look finds nothing new; then still for longer than the quiet
        // interval (1 s).
        try await Task.sleep(for: .milliseconds(300))
        _ = try await harness.output(of: worker)
        try await Task.sleep(for: .milliseconds(2_000))

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString]))
        #expect(subscribed.watching.first?.status == "unknown")
        let events = try await harness.events(subscribed.subscription.subscriptionID, timeoutMilliseconds: 500)
        #expect(events.events.map(\.type) == [.done])
        #expect(events.events.first?.initial == true)
        #expect(events.events.first?.agentTurn == 1)
        #expect(events.events.first?.basis == MonitorEvent.outputQuietBasis)
    }

    /// A turn the program's restart cut short is not done: what it
    /// submitted went to the program that ended. The next turn, submitted
    /// to the new program, is.
    @Test func silentAgentRestartedMidTurnIsNotDoneWithTheTurnTheRestartEnded() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let script = try harness.silentAgentScript(working: 1)
        let worker = try await harness.spawnAgent(named: "Fakesilent", command: script)
        try await harness.waitForOutput("\u{276F}", of: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], events: ["done"], wake: false))
            .subscription.subscriptionID

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "slow work", submit: true)))
        try await harness.waitForOutput("Working", of: worker)
        #expect(worker.restart())
        try await harness.waitForOutput("\u{276F}", of: worker)
        let afterRestart = try await harness.events(id, timeoutMilliseconds: 4_000)
        #expect(afterRestart.events.isEmpty, "the restart's quiet composer is no end of the turn: \(afterRestart.events)")

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "again", submit: true)))
        let done = try await harness.events(id, timeoutMilliseconds: 30_000)
        #expect(done.events.map(\.type) == [.done])
        #expect(done.events.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(done.events.first?.agentTurn == 2)
        #expect(try await harness.output(of: worker).contains("handled again"))
    }

    /// An Enter that draws nothing after a turn's last change (Return on an
    /// empty composer, still a submit) holds back no `done`: the screen
    /// changed after the first turn submitted since the last one. The next
    /// turn is done again.
    @Test func silentAgentsReturnThatDrawsNothingHoldsBackNoDone() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        // Nothing is quiet long enough until the Return was typed.
        harness.server.monitors.outputQuietInterval = 100
        harness.server.start()
        let script = try harness.silentAgentScript(working: 0.5)
        let worker = try await harness.spawnAgent(named: "Fakesilent", command: script)
        try await harness.waitForOutput("\u{276F}", of: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], events: ["done"], wake: false))
            .subscription.subscriptionID

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "hello", submit: true)))
        try await harness.waitForOutput("handled hello", of: worker)
        // Its last change seen (samples read it every 50 ms), then a Return.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await harness.server.typeCherryLine("", into: worker)
        try await Task.sleep(for: .milliseconds(300))
        #expect(worker.agentSubmittedTurnCount == 2)
        let submittedAt = try #require(worker.lastAgentSubmitAt)
        #expect(try #require(worker.lastContentChangeAt) < submittedAt, "the Return drew nothing")
        #expect(try await harness.events(id, timeoutMilliseconds: 0).events.isEmpty)

        harness.server.monitors.outputQuietInterval = 1
        let done = try await harness.events(id, timeoutMilliseconds: 10_000)
        #expect(done.events.map(\.type) == [.done])
        #expect(done.events.first?.basis == MonitorEvent.outputQuietBasis)

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "more", submit: true)))
        let next = try await harness.events(id, timeoutMilliseconds: 10_000)
        #expect(next.events.map(\.type) == [.done])
        #expect(try await harness.output(of: worker).contains("handled more"), "done before its turn ended")
    }

    /// A silent agent attached from its host: a reconnect relaunches its
    /// attach adapter, not its program, so the turn submitted before it
    /// still ends with a quiet `done`. The stand-in adapter goes on with
    /// that turn after the reconnect, as the program does.
    @Test func silentAttachedAgentsTurnAcrossAReconnectIsStillDone() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let underWay = harness.projectRoot.appendingPathComponent("turn-under-way")
        let script = harness.projectRoot.appendingPathComponent("attached-silent-agent.pl")
        try """
        #!/usr/bin/perl
        use strict;
        use warnings;
        $| = 1;
        system("stty -echo 2>/dev/null");
        if (-e "\(underWay.path)") {
          for my $i (1 .. 10) {
            print "\\r\\xe2\\x9c\\xb6 Working $i";
            select(undef, undef, undef, 0.1);
          }
          print "\\r\\033[2K\\xe2\\x8f\\xba handled it\\n\\n";
        }
        print "\\xe2\\x9d\\xaf \\n";
        while (my $line = <STDIN>) {
          chomp $line;
          next if $line eq "";
          open(my $mark, ">", "\(underWay.path)");
          close($mark);
          print "> $line\\n\\n";
          for my $i (1 .. 600) {
            print "\\r\\xe2\\x9c\\xb6 Working $i";
            select(undef, undef, undef, 0.1);
          }
        }
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let isolated = try makeIsolatedHostedSessionHostStore()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suite) }
        let control = makeFakeHostControl(
            FakeControlHelper(sessions: [hostedSession("session-silent-attached", pid: nil)]), hostStore: isolated.store
        )
        defer { control.shutdown() }
        let attached = harness.attachedAgent(named: "Fakesilent", command: script.path, sessionID: "session-silent-attached", control: control)
        #expect(!attached.startedCurrentProgram)
        try await harness.waitForOutput("\u{276F}", of: attached)
        let id = try await harness.subscribe(.init(processIDs: [attached.id.uuidString], events: ["done"], wake: false))
            .subscription.subscriptionID

        _ = try await harness.send(.sendProcessInput(.init(processID: attached.id.uuidString, text: "slow work", submit: true)))
        try await harness.waitForOutput("Working", of: attached)
        #expect(attached.reconnectHostedSession(takeover: true))
        let submittedAt = try #require(attached.lastAgentSubmitAt)
        #expect(try #require(attached.programStartedAt) > submittedAt, "the reconnect's launch came after the submit")

        let done = try await harness.events(id, timeoutMilliseconds: 30_000)
        #expect(done.events.map(\.type) == [.done])
        #expect(done.events.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(done.events.first?.agentTurn == 1)
        #expect(try await harness.output(of: attached).contains("handled it"), "done before its turn ended")
    }

    /// An agent that reports its status is done only when it says so: a
    /// still screen while it reports `working` is not the end of its turn.
    @Test func reportingAgentIsNeverDoneByItsOutputGoingQuiet() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let worker = try await harness.spawnAgent(named: "Claude")
        harness.report("state=idle:app=claude-code", on: worker)
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "think hard", submit: true)))
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString])).subscription.subscriptionID

        let still = try await harness.events(id, timeoutMilliseconds: 1_500)
        #expect(still.events.isEmpty, "done while it reports working: \(still.events)")
        #expect(still.watching.first?.status == "working")

        harness.report("state=done:app=claude-code", on: worker)
        let done = try await harness.events(id)
        #expect(done.events.map(\.type) == [.done])
        #expect(done.events.first?.basis == nil)
    }

    // MARK: Task workers

    /// A watched worker of a Cherry task shows its task. Its task's settle
    /// is a `done` of its own, with the task and no `basis`; the end of the
    /// turn it reported in is another `done`, without them, as any turn's
    /// is; a re-report adds nothing.
    @Test func taskWorkersSettleIsADoneApartFromItsTurnsEnd() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)

        let subscribed = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false))
        #expect(subscribed.watching.first?.taskID == taskID)
        #expect(["queued", "working"].contains(subscribed.watching.first?.taskState ?? ""))
        let id = subscribed.subscription.subscriptionID
        let before = try await harness.events(id, untilStatus: "working")
        #expect(before.isEmpty, "\(before)")

        try await harness.reportResult("Two findings", from: worker)
        let settled = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(settled.map(\.type) == [.done], "\(settled)")
        #expect(settled.first?.taskState == "reported")
        #expect(settled.first?.basis == nil)
        #expect(settled.first?.initial == false)

        // The turn ends (as Claude Code reports it after report_result).
        harness.screen("⏺ Reported.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        // (A screen change seen only after the report can make the turn
        // look done twice: an extra done is harmless, a lost one is not.)
        let turnEnd = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(!turnEnd.isEmpty && turnEnd.allSatisfy { $0.type == .done && $0.basis == nil }, "\(turnEnd)")
        #expect(turnEnd.allSatisfy { $0.taskID == nil && $0.taskState == nil })

        // It reports again: no other settle.
        try await harness.reportResult("Three findings", from: worker)
        let after = try await harness.events(id, timeoutMilliseconds: 1_200)
        #expect(!after.events.contains { $0.taskID != nil }, "\(after.events)")
        #expect(after.watching.first?.status == "idle")
        #expect(after.watching.first?.taskState == "reported")
    }

    /// A worker that reports no status: its turn's quiet `done` and its
    /// task's settle are each told, whichever comes first. A settle neither
    /// stands for the turn nor holds its quiet done back.
    @Test func silentTaskWorkersQuietDoneAndSettleAreEachTold() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let (quiet, quietTask) = try await harness.spawnTaskWorker(named: "Quietworker", task: "Look around")
        let id = try await harness.subscribe(.init(processIDs: [quiet.id.uuidString], wake: false)).subscription.subscriptionID

        let inferred = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(inferred.map(\.type) == [.done], "\(inferred)")
        #expect(inferred.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(inferred.first?.taskID == nil, "its task is still open")

        try await harness.reportResult("Looked", from: quiet)
        let settled = try await harness.events(id) { $0.contains { $0.taskID == quietTask } }
        #expect(settled.map(\.type) == [.done], "\(settled)")
        #expect(settled.first?.taskState == "reported")
        #expect(settled.first?.basis == nil)
        #expect(try await harness.events(id, timeoutMilliseconds: 1_500).events.isEmpty)

        // Reported before its screen went still (a quiet interval longer
        // than the report takes): the settle, then the quiet done of the
        // turn it reported in.
        harness.server.monitors.outputQuietInterval = 10
        let (prompt, promptTask) = try await harness.spawnTaskWorker(named: "Promptworker", task: "Answer at once")
        let second = try await harness.subscribe(.init(processIDs: [prompt.id.uuidString], wake: false)).subscription.subscriptionID
        try await harness.reportResult("Answered", from: prompt)
        let first = try await harness.events(second) { $0.contains { $0.taskID == promptTask } }
        #expect(first.map(\.type) == [.done], "\(first)")
        #expect(first.first?.basis == nil)
        harness.server.monitors.outputQuietInterval = 0.3
        let later = try await harness.events(second) { $0.contains { $0.type == .done } }
        #expect(later.map(\.type) == [.done], "\(later)")
        #expect(later.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(later.first?.taskID == nil)
    }

    /// A worker that reports no status whose output went quiet in the look
    /// that first sees its task settled: two `done`s, the turn's (with its
    /// `basis`) and the settle's (with the task), and nothing more. A
    /// subscription evaluated by hand, so the two fall in one look.
    @Test func silentWorkersQuietDoneAndSettleInOneLookAreTwoDones() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Quietworker", task: "Look around")
        let workspace = try #require(harness.server.allOpenWorkspaces().first { $0.sessions.contains { $0 === worker } })
        let subscription = MonitorSubscription(
            id: "mon-by-hand", device: nil, subscriber: nil, subAgents: false, events: [.done],
            outputPattern: nil, wakeRequested: false, wakeUnavailableReason: nil
        )
        let watched = WatchedProcess(session: worker, workspace: workspace, name: "Quietworker")
        subscription.watched = [watched]
        harness.server.monitors.outputQuietInterval = 100
        harness.server.evaluate(watched, in: subscription, now: Date())
        #expect(subscription.pending.isEmpty)

        try await harness.reportResult("Looked", from: worker)
        harness.server.monitors.outputQuietInterval = 0.3
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !harness.server.outputWentQuiet(worker, now: Date()) {
            _ = try await harness.output(of: worker)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(harness.server.outputWentQuiet(worker, now: Date()), "both in this look")
        harness.server.evaluate(watched, in: subscription, now: Date())
        #expect(subscription.pending.map(\.type) == [.done, .done], "\(subscription.pending)")
        let turn = subscription.pending.first { $0.basis != nil }
        #expect(turn?.basis == MonitorEvent.outputQuietBasis)
        #expect(turn?.taskID == nil && turn?.taskState == nil)
        let settle = subscription.pending.first { $0.taskID != nil }
        #expect(settle?.taskID == taskID)
        #expect(settle?.taskState == "reported")
        #expect(settle?.basis == nil)
        harness.server.evaluate(watched, in: subscription, now: Date())
        #expect(subscription.pending.count == 2, "one each: \(subscription.pending)")
    }

    /// A worker that reports like Claude Code gets a message while it
    /// works (Claude Code queues it), reports its result, and runs the
    /// queued turn: the settle is one `done` with the task, and each turn's
    /// end, the queued one's too, is a `done` without it.
    @Test func taskWorkersQueuedTurnAfterItsReportEndsWithADoneOfItsOwn() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false)).subscription.subscriptionID
        var read = try await harness.events(id, untilStatus: "working")

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "also check the lexer", submit: true)))
        try await harness.reportResult("Two findings", from: worker)
        read += try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        // Its turn ends; the queued one starts.
        harness.screen("⏺ Reported.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        read += try await harness.events(id) { $0.contains { $0.type == .done && $0.taskID == nil } }
        harness.report("state=working:app=claude-code", on: worker)
        read += try await harness.events(id, untilStatus: "working")

        harness.screen("⏺ The lexer is fine.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        let queuedEnd = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(!queuedEnd.isEmpty && queuedEnd.allSatisfy { $0.type == .done && $0.taskID == nil }, "\(queuedEnd)")
        read += queuedEnd
        #expect(read.compactMap(\.taskID) == [taskID], "one done carries the task: \(read)")
        #expect(read.first { $0.taskID == taskID }?.taskState == "reported")
        #expect(read.filter { $0.type == .done && $0.taskID == nil }.count >= 2, "\(read)")
    }

    /// The same worker reporting its result in the queued turn: the turn
    /// before ends with a `done`, the settle is one with the task, and the
    /// end of the turn it reported in is a `done` of its own.
    @Test func taskWorkersReportInAQueuedTurnIsItsSettlesDone() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        // Idle before it asked for its task: no second kickoff meanwhile.
        harness.server.tasks.kickoffRetryInterval = 600
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false)).subscription.subscriptionID
        var read = try await harness.events(id, untilStatus: "working")

        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "and report the lexer too", submit: true)))
        harness.screen("⏺ Looked at the parser.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        let firstEnd = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(firstEnd.allSatisfy { $0.type == .done && $0.taskID == nil }, "\(firstEnd)")
        read += firstEnd
        harness.report("state=working:app=claude-code", on: worker)
        read += try await harness.events(id, untilStatus: "working")

        try await harness.reportResult("Parser and lexer", from: worker)
        let settle = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(settle.allSatisfy { $0.type == .done }, "\(settle)")
        #expect(settle.last?.taskState == "reported")
        read += settle
        // The turn it reported in ends.
        harness.screen("⏺ Reported.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        let end = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(!end.isEmpty && end.allSatisfy { $0.type == .done && $0.taskID == nil }, "\(end)")
        read += end
        #expect(read.compactMap(\.taskID) == [taskID], "one done carries the task: \(read)")
    }

    /// Cherry's own Enter press after a kickoff (an extra CR, a submit
    /// though the agent starts no turn for it) neither loses nor holds back
    /// a `done` of a worker that reports its status: the settle, its turn's
    /// end and the next message's turn are each told.
    @Test func kickoffEnterPressLosesNoDoneOfAReportingWorker() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        _ = try await harness.server.typeCherryLine("", into: worker)
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false)).subscription.subscriptionID
        var read = try await harness.events(id, untilStatus: "working")

        try await harness.reportResult("Two findings", from: worker)
        read += try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        harness.screen("⏺ Reported.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        read += try await harness.events(id) { $0.contains { $0.type == .done && $0.taskID == nil } }

        // The next message's turn.
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "and the lexer?", submit: true)))
        harness.report("state=working:app=claude-code", on: worker)
        read += try await harness.events(id, untilStatus: "working")
        let before = read.filter { $0.type == .done && $0.taskID == nil }.count
        harness.screen("⏺ The lexer is fine.\n\n❯ \n", on: worker)
        harness.report("state=done:app=claude-code", on: worker)
        read += try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(read.filter { $0.type == .done && $0.taskID == nil }.count > before, "\(read)")
        #expect(read.compactMap(\.taskID) == [taskID], "one done carries the task: \(read)")
    }

    /// The same Enter press into a worker that reports no status: its
    /// quiet `done`, its settle and the next message's quiet `done` are
    /// each told.
    @Test func kickoffEnterPressLosesNoDoneOfASilentWorker() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Quietworker", task: "Look around")
        _ = try await harness.server.typeCherryLine("", into: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false)).subscription.subscriptionID
        func quietDones(_ events: [MonitorEvent]) -> Int {
            events.filter { $0.type == .done && $0.basis == MonitorEvent.outputQuietBasis }.count
        }

        var read = try await harness.events(id) { quietDones($0) >= 1 }
        try await harness.reportResult("Looked", from: worker)
        read += try await harness.events(id) { $0.contains { $0.taskID == taskID } }

        // The next message's turn.
        let before = quietDones(read)
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "and the lexer?", submit: true)))
        read += try await harness.events(id) { quietDones($0) >= 1 }
        #expect(quietDones(read) > before, "\(read)")
        #expect(read.compactMap(\.taskID) == [taskID], "one done carries the task: \(read)")
        #expect(read.filter { $0.basis != nil }.allSatisfy { $0.taskID == nil })
    }

    /// A worker whose program ends before it reported: its `exited`, then
    /// its task's settle (`failed`), still a `done` of its own.
    @Test func workersExitAndItsTasksSettleAreEachTold() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], events: ["done", "exited"], wake: false))
            .subscription.subscriptionID
        _ = try await harness.events(id, untilStatus: "working")

        // End of input: cat ends.
        let eof = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, rawBase64: Data([4]).base64EncodedString())))
        #expect(eof.error == nil)
        let read = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(read.map(\.type) == [.exited, .done], "\(read)")
        #expect(read.last?.taskID == taskID)
        #expect(read.last?.taskState == "failed")
        #expect(read.last?.basis == nil)
    }

    /// A worker that reports no status gets a message while it works and
    /// reports its result before the queued turn ran: the settle is one
    /// `done` with the task, and the queued turn still ends with a quiet
    /// one.
    @Test func silentTaskWorkersQueuedTurnAfterItsReportEndsWithAQuietDone() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.monitors.outputQuietInterval = 1.5
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Quietworker", task: "Look around")
        // It works: its screen changes every 100 ms (lines added, so the
        // kickoff stays on it).
        let working = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                tick += 1
                worker.ingestTestingData(Data("\u{2736} Working \(tick)\r\n".utf8))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { working.cancel() }
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false)).subscription.subscriptionID
        _ = try await harness.send(.sendProcessInput(.init(processID: worker.id.uuidString, text: "also check the lexer", submit: true)))
        try await harness.reportResult("Looked", from: worker)
        var read = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(read.map(\.type) == [.done], "\(read)")
        #expect(read.first?.basis == nil)

        // The queued turn runs a moment longer, then its screen goes still.
        try await Task.sleep(for: .milliseconds(500))
        working.cancel()
        let quiet = try await harness.events(id) { $0.contains { $0.type == .done } }
        #expect(quiet.map(\.type) == [.done], "\(quiet)")
        #expect(quiet.first?.basis == MonitorEvent.outputQuietBasis)
        #expect(quiet.first?.taskID == nil)
        read += quiet
        #expect(read.compactMap(\.taskID) == [taskID], "one done carries the task: \(read)")
    }

    /// An owner that cancels its worker's task with `cancel_tasks` knows:
    /// its own monitor gets no `done` for it, another subscriber does, and
    /// the cancel is no end of the worker's turn, which still ends with a
    /// `done` for both.
    @Test func ownersCancelIsNoDoneForItsOwnMonitorNorTheWorkersTurn() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let owner = try await harness.spawnAgent(named: "Owner")
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)
        harness.server.callerSessionResolverForTesting = { _ in owner }
        let mine = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false))
        harness.server.callerSessionResolverForTesting = nil
        let others = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], wake: false))
        #expect(mine.subscription.subscriberProcessID == owner.id.uuidString)
        #expect(others.subscription.subscriberProcessID == nil)
        let mineID = mine.subscription.subscriptionID
        let othersID = others.subscription.subscriptionID
        _ = try await harness.events(mineID, untilStatus: "working")
        _ = try await harness.events(othersID, untilStatus: "working")

        harness.server.callerSessionResolverForTesting = { _ in owner }
        let cancelled = try await harness.send(.cancelTasks(.init(taskIDs: [taskID])))
        harness.server.callerSessionResolverForTesting = nil
        guard case .cancelTasks(let cancel)? = cancelled.result else {
            Issue.record("Expected cancelTasks, got \(String(describing: cancelled))")
            return
        }
        #expect(cancel.cancelled == [taskID])
        let told = try await harness.events(othersID) { $0.contains { $0.taskID == taskID } }
        #expect(told.map(\.type) == [.done], "\(told)")
        #expect(told.first?.taskState == "cancelled")
        let own = try await harness.events(mineID, timeoutMilliseconds: 1_000)
        #expect(own.events.isEmpty, "its own cancel: \(own.events)")
        #expect(own.watching.first?.taskState == "cancelled")

        harness.screen("⏺ Stopped.\n\n❯ \n", on: worker)
        try await Task.sleep(for: .milliseconds(100))
        harness.report("state=done:app=claude-code", on: worker)
        // (A screen change seen only after the report can make the turn
        // look done twice: an extra done is harmless, a lost one is not.)
        let mineEnd = try await harness.events(mineID) { $0.contains { $0.type == .done } }
        let othersEnd = try await harness.events(othersID) { $0.contains { $0.type == .done } }
        #expect(!mineEnd.isEmpty && mineEnd.allSatisfy { $0.type == .done && $0.taskID == nil }, "\(mineEnd)")
        #expect(!othersEnd.isEmpty && othersEnd.allSatisfy { $0.type == .done && $0.taskID == nil }, "\(othersEnd)")
    }

    /// A worker whose tab closes while its task is open, watched for `done`
    /// but not `closed`: its task's settle (cancelled once its tab is gone)
    /// is still a `done`, and then the watch ends.
    @Test func workerClosedWithItsTaskOpenIsStillToldItsTasksSettle() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], events: ["done"], wake: false))
            .subscription.subscriptionID
        _ = try await harness.events(id, untilStatus: "working")

        #expect(try await harness.send(.closeProcess(.init(processID: worker.id.uuidString))).error == nil)
        let settled = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(settled.map(\.type) == [.done], "\(settled)")
        #expect(settled.first?.taskState == "cancelled")
        let after = try await harness.events(id, timeoutMilliseconds: 1_000)
        #expect(after.events.isEmpty)
        #expect(after.watching.first?.status == "closed")
        #expect(after.watching.first?.taskState == "cancelled")
        let subscription = try #require(harness.server.monitors.subscriptions[id])
        #expect(subscription.watched.first?.finished == true, "no longer looked at")
    }

    /// A worker whose session comes back in a tab under another id (⌘D,
    /// then shown again): its task follows it there (`locateWorker`), and
    /// the watch of its first tab, watched for `done` but not `closed`, is
    /// still told the settle it reports from the new one.
    @Test func workerBackUnderAnotherTabIDIsStillToldItsTasksSettle() async throws {
        let harness = try ControlAgentWaitHarness()
        defer { harness.stop() }
        harness.useFastMonitors()
        harness.server.tasks.reportInterval = 0
        harness.server.start()
        let (worker, taskID) = try await harness.spawnTaskWorker(named: "Worker", task: "Review the parser")
        defer { worker.stop() }
        harness.report("state=working:app=claude-code", on: worker)
        let id = try await harness.subscribe(.init(processIDs: [worker.id.uuidString], events: ["done"], wake: false))
            .subscription.subscriptionID
        #expect(try await harness.events(id, untilStatus: "working").isEmpty)
        let task = try #require(harness.server.tasks.tasks[taskID])
        // Its tab ran the task's session (as a persistent tab's does).
        task.workerSession = AgentTaskSessionBinding(host: HostedSessionHost.local.id, hostID: "host-a", sessionID: "session-worker-back")

        // Detached, and shown again under another id, in one turn.
        let isolated = try makeIsolatedHostedSessionHostStore()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suite) }
        let control = makeFakeHostControl(
            FakeControlHelper(sessions: [hostedSession("session-worker-back", pid: nil)]), hostStore: isolated.store
        )
        defer { control.shutdown() }
        harness.workspace.takeOutForLayout([worker])
        let back = harness.attachedAgent(named: "Worker", command: "/bin/cat", sessionID: "session-worker-back", control: control)
        #expect(back.id != worker.id)
        for _ in 0..<100 where task.workerID != back.id {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(task.workerID == back.id, "its task followed it")
        let gone = try await harness.events(id, untilStatus: "closed")
        #expect(gone.isEmpty, "\(gone)")

        try await harness.reportResult("Two findings", from: back)
        let settled = try await harness.events(id) { $0.contains { $0.taskID == taskID } }
        #expect(settled.map(\.type) == [.done], "\(settled)")
        #expect(settled.first?.taskState == "reported")
        let after = try await harness.events(id, timeoutMilliseconds: 500)
        #expect(after.events.isEmpty)
        #expect(after.watching.first?.taskID == taskID)
        #expect(harness.server.monitors.subscriptions[id]?.watched.first?.finished == true, "no longer looked at")
    }
}
