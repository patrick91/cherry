import CherryControl
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
        workspace = TerminalWorkspace(projectRoot: projectRoot.path)
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
