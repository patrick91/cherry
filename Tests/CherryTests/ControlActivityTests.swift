import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

@MainActor
private final class ControlActivityHarness {
    let defaultsName: String
    let defaults: UserDefaults
    let settings: AgentSettings
    let projectRoot: URL
    let workspace: TerminalWorkspace
    let socketURL: URL
    let server: CherryControlServer

    init() throws {
        defaultsName = "CherryTests.ControlActivity.\(UUID().uuidString)"
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
            agentSettings: settings
        )
    }

    func spawnAgentSession(named name: String) async throws -> TerminalSession {
        let response = try await send(.spawnProcess(.init(kind: "agent", name: name)))
        guard case .spawnProcess(let spawned)? = response.result else {
            Issue.record("Expected spawnProcess result, got \(String(describing: response))")
            throw CherryControlError(code: "spawn_failed", message: "Expected spawnProcess result.")
        }
        return try #require(workspace.session(id: spawned.process.id))
    }

    func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        let socketURL = socketURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try CherryControlClient(socketURL: socketURL).send(request)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        server.stop()
        workspace.sessions.forEach { $0.stop() }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }
}

@MainActor
@Suite(.serialized)
struct ControlActivityTests {
    @Test func processStatusExposesAgentActivityFields() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Claude")
        session.ingestTestingData(Data("""
        ❯ Try "fix lint errors"
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """.utf8))
        try await Task.sleep(for: .milliseconds(150))

        let response = try await harness.send(.getProcessStatus(.init(processID: session.id.uuidString)))
        guard case .getProcessStatus(let status)? = response.result else {
            Issue.record("Expected getProcessStatus result, got \(String(describing: response))")
            return
        }
        #expect(status.process.agentActivityState == "idle")
        #expect(status.process.usesAlternateScreen == false)
        #expect((status.process.contentVersion ?? 0) >= 1)
        #expect(status.process.lastContentChangeAt != nil)
    }

    @Test func processOutputReportsScreenMode() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        harness.server.start()

        let session = try #require(harness.workspace.sessions.first)
        let primaryResponse = try await harness.send(.getProcessOutput(.init(
            processID: session.id.uuidString,
            lineLimit: 20
        )))
        guard case .getProcessOutput(let primary)? = primaryResponse.result else {
            Issue.record("Expected getProcessOutput result, got \(String(describing: primaryResponse))")
            return
        }
        #expect(primary.screen == "primary")
        #expect(primary.contentVersion != nil)

        session.ingestTestingData(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[Hfullscreen".utf8))

        let alternateResponse = try await harness.send(.getProcessOutput(.init(
            processID: session.id.uuidString,
            lineLimit: 20
        )))
        guard case .getProcessOutput(let alternate)? = alternateResponse.result else {
            Issue.record("Expected getProcessOutput result, got \(String(describing: alternateResponse))")
            return
        }
        #expect(alternate.screen == "alternate")
    }

    @Test func controlCapturesHumanLabeledAttentionCheckpoint() async throws {
        let recordingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-control-\(UUID().uuidString)", isDirectory: true)
        let previousRecordingDirectory = ProcessInfo.processInfo.environment[
            TerminalAttentionObservationRecorder.environmentKey
        ]
        setenv(TerminalAttentionObservationRecorder.environmentKey, recordingDirectory.path, 1)
        defer {
            if let previousRecordingDirectory {
                setenv(TerminalAttentionObservationRecorder.environmentKey, previousRecordingDirectory, 1)
            } else {
                unsetenv(TerminalAttentionObservationRecorder.environmentKey)
            }
            try? FileManager.default.removeItem(at: recordingDirectory)
        }

        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Fixture", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Fixture")
        session.ingestTestingData(Data("Choose alpha or beta\n❯ \n".utf8))
        try await Task.sleep(for: .milliseconds(150))

        let response = try await harness.send(.captureAttentionObservation(.init(
            processID: session.id.uuidString,
            label: "waiting_for_input",
            scenarioID: "waiting-for-input",
            checkpoint: "human_verified",
            harnessVersion: "fixture 1.0",
            runID: "control-run"
        )))
        guard case .captureAttentionObservation(let capture)? = response.result else {
            Issue.record("Expected captureAttentionObservation result, got \(String(describing: response))")
            return
        }

        #expect(capture.processID == session.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: capture.outputPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: capture.outputPath))
        #expect(String(decoding: data, as: UTF8.self).contains("\"label\":\"waiting_for_input\""))
        #expect(String(decoding: data, as: UTF8.self).contains("\"runID\":\"control-run\""))
    }

    @Test func waitForProcessIdleReturnsPermissionImmediately() async throws {
        TerminalNotificationCenter.shared.isDeliveryEnabled = false
        defer {
            TerminalNotificationCenter.shared.isDeliveryEnabled = true
        }

        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Claude")
        session.ingestTestingData(Data("\u{1B}]9;Permission required\u{7}".utf8))
        #expect(session.agentActivityState == .permission)

        let startedAt = Date()
        let waitResponse = try await harness.send(.waitForProcessIdle(.init(
            processID: session.id.uuidString,
            quietMilliseconds: 1_000,
            timeoutMilliseconds: 10_000,
            lineLimit: 20
        )))
        guard case .waitForProcessIdle(let waited)? = waitResponse.result else {
            Issue.record("Expected waitForProcessIdle result, got \(String(describing: waitResponse))")
            return
        }

        #expect(waited.reason == .permission)
        #expect(waited.timedOut == false)
        #expect(waited.agentActivityState == "permission")
        #expect(waited.process.agentActivityState == "permission")
        #expect(Date().timeIntervalSince(startedAt) < 5)
    }

    @Test func waitForProcessIdleTimesOutWhileAgentIsWorking() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Claude")
        session.ingestTestingData(Data("✶ Reticulating… (esc to interrupt)\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.agentActivityState == .working)

        let waitResponse = try await harness.send(.waitForProcessIdle(.init(
            processID: session.id.uuidString,
            requireNewOutput: false,
            quietMilliseconds: 100,
            timeoutMilliseconds: 600,
            lineLimit: 20
        )))
        guard case .waitForProcessIdle(let waited)? = waitResponse.result else {
            Issue.record("Expected waitForProcessIdle result, got \(String(describing: waitResponse))")
            return
        }

        #expect(waited.reason == .timedOut)
        #expect(waited.timedOut == true)
        #expect(waited.agentActivityState == "working")
    }

    // Agents with no recognizable composer prompt or working footer (amp, bare REPLs,
    // unrecognized tools) used to stay pinned to "working" forever once they emitted
    // any output. The quiet-window recheck now settles them to idle so the sidebar /
    // menu bar report the truth. See the recheckAgentActivityAfterQuiet fallback.
    @Test func unrecognizedAgentSettlesToIdleAfterQuietWindow() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "customrepl", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "customrepl")
        // Plain output with no prompt glyph, no "esc to interrupt", no title spinner.
        session.ingestTestingData(Data("building module graph...\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.agentActivityState == .working)
        #expect(session.agentActivityEvidenceIsStrong == false)

        // The recheck fires one quiet window (4s) after the last content change; wait
        // past it with margin, then the weak-evidence fallback should mark it idle.
        try await Task.sleep(for: .milliseconds(4_600))
        #expect(session.agentActivityState == .idle)
        #expect(session.agentActivityEvidenceIsStrong == false)
    }

    // The quiet-window fallback must not override a genuinely working agent: Claude's
    // "esc to interrupt" footer persists on screen through the whole turn, so a quiet
    // stretch (slow tool call, no new output) must stay "working".
    @Test func persistentWorkingMarkerSurvivesQuietWindow() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Claude", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Claude")
        session.ingestTestingData(Data("✶ Reticulating… (esc to interrupt)\n".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.agentActivityState == .working)

        // Past the quiet window the marker is still on screen, so it stays working.
        try await Task.sleep(for: .milliseconds(4_600))
        #expect(session.agentActivityState == .working)
    }

    @Test func piSpinnerWorkingMarkerOutranksVisibleComposer() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Pi", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Pi")
        session.noteTestingInput(Data("run the tests\r".utf8))
        session.ingestTestingData(Data("⠏ Working...\n> \n".utf8))
        try await Task.sleep(for: .milliseconds(150))

        #expect(session.agentActivityState == .working)
        #expect(session.agentActivityEvidenceIsStrong == true)
    }

    @Test func piProseMentioningWorkingDoesNotOutrankComposer() async throws {
        let harness = try ControlActivityHarness()
        defer {
            harness.stop()
        }
        try harness.settings.upsertAgent(AgentToolDefinition(name: "Pi", command: "/bin/cat"))
        harness.server.start()

        let session = try await harness.spawnAgentSession(named: "Pi")
        session.ingestTestingData(Data("The service is working...\n> \n".utf8))
        try await Task.sleep(for: .milliseconds(150))

        #expect(session.agentActivityState == .idle)
        #expect(session.agentActivityEvidenceIsStrong == true)
    }

    // Real screen captured live on 2026-07-08: the agent's own FINAL MESSAGE contains
    // the prose "~3–5% while working (0% idle)", which the old bare "working ("
    // substring match treated as a working status marker. With that sentence pinned
    // inside the 32-line tail window of a viewport-height buffer, the session
    // reported "working" forever despite an idle ❯ composer two rows above the
    // footer. Markers must come from status chrome, never transcript prose.
    @Test func agentProseMentioningWorkingDoesNotPinWorkingState() async throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "claude-idle-screen-prose-working-marker",
            withExtension: "txt",
            subdirectory: "Fixtures"
        ))
        let screen = try String(contentsOf: fixtureURL, encoding: .utf8)

        let session = TerminalSession(
            title: "Claude",
            subtitle: "claude --dangerously-skip-permissions",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Claude"
        )
        session.ingestTestingData(Data(screen.utf8))
        try await Task.sleep(for: .milliseconds(150))

        // The empty ❯ composer near the bottom is the truth; the prose upstream
        // must not outrank it.
        #expect(session.agentActivityState == .idle)
    }

    @Test func trimmedRawOutputSuffixSkipsPartialUTF8AndEscapeTails() async throws {
        let continuationTail = Data([0x9F, 0x92, 0x96]) + Data("hello\n".utf8)
        let trimmedContinuation = CherryControlServer.trimmedRawOutputSuffix(continuationTail)
        #expect(trimmedContinuation == Data("hello\n".utf8))
        #expect(String(decoding: trimmedContinuation, as: UTF8.self) == "hello\n")

        let csiTail = Data("38;5;123m".utf8) + Data("\u{1B}[0mok".utf8)
        let trimmedCSI = CherryControlServer.trimmedRawOutputSuffix(csiTail)
        #expect(trimmedCSI == Data("\u{1B}[0mok".utf8))

        let mixedTail = Data([0x80, 0xBF]) + Data("5;10H".utf8) + Data("\nnext line".utf8)
        let trimmedMixed = CherryControlServer.trimmedRawOutputSuffix(mixedTail)
        #expect(trimmedMixed == Data("\nnext line".utf8))

        let cleanText = Data("plain text \u{1B}[1mbold".utf8)
        #expect(CherryControlServer.trimmedRawOutputSuffix(cleanText) == cleanText)

        let parameterOnly = Data("38;5;1".utf8)
        #expect(CherryControlServer.trimmedRawOutputSuffix(parameterOnly) == parameterOnly)
    }
}
