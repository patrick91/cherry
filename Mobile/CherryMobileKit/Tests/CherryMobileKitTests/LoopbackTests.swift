import Foundation
import Testing
@testable import CherryMobileKit

/// The SSH transport against a private sshd and a private cherry-host on
/// this Mac's loopback, which `Mobile/Scripts/test-loopback` sets up (and
/// only then runs these). Never another Mac, never the user's daemon.
private enum Loopback {
    static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["CHERRY_TEST_MOBILE_LOOPBACK"] == "1"

    static func value(_ name: String) throws -> String {
        try #require(environment["CHERRY_TEST_MOBILE_\(name)"], "Mobile/Scripts/test-loopback sets CHERRY_TEST_MOBILE_\(name)")
    }

    /// An endpoint for the private sshd, pinned to the private host.
    static func endpoint(hostKey: String? = nil, hostID: String? = nil) throws -> MacEndpoint {
        let pinnedHost = try hostID ?? value("HOST_ID")
        return MacEndpoint(
            name: "Loopback",
            host: "127.0.0.1",
            port: Int(try value("PORT"))!,
            user: try value("USER"),
            cherryPath: try value("CHERRY"),
            hostKeyFingerprint: hostKey,
            expectedHostID: pinnedHost
        )
    }

    /// An identity the sshd takes: its line written into the private
    /// authorized_keys.
    static func authorizedIdentity() throws -> InMemoryDeviceIdentity {
        let identity = InMemoryDeviceIdentity()
        try (try identity.publicKey() + "\n").write(toFile: try value("AUTHORIZED_KEYS"), atomically: true, encoding: .utf8)
        return identity
    }
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(
    _ timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}

@Suite(.serialized, .enabled(if: Loopback.isEnabled))
struct LoopbackTests {
    @Test func aConnectionListsReadsTypesAndAttachesOverRealSSH() async throws {
        let identity = try Loopback.authorizedIdentity()
        let session = try Loopback.value("SESSION")
        let connection = try await SSHMacConnector(identity: identity).connect(to: try Loopback.endpoint())

        // The host key is reported to pin; the host is the private one.
        #expect(connection.endpoint.hostKeyFingerprint == (try Loopback.value("HOST_FINGERPRINT")))
        #expect(connection.endpoint.expectedHostID == (try Loopback.value("HOST_ID")))

        // Listed, with what its program reported to the host (OSC 7501):
        // the session host alone says so, no Cherry app involved.
        let sessions = try await connection.sessions()
        let listed = try #require(sessions.first { $0.id == session })
        #expect(listed.kind == .agent("claude"))
        #expect(listed.title == "Fix the tests")
        #expect(listed.attention == .approval)
        #expect(listed.detail == "Approve Bash: npm test")
        #expect(listed.changedAt == nil)
        #expect(listed.isRunning)

        // Typed through the host: the program shows it.
        let events = connection.events()
        try await connection.send([.text("hello mobile"), .enter], to: session)
        #expect(try await eventually {
            try await connection.screen(of: session).lines.contains { $0.contains("hello mobile") }
        })
        await #expect(throws: MacConnectionError.sessionGone("no-such-session")) {
            try await connection.screen(of: "no-such-session")
        }

        // Approved: its new status comes with the host's events, and the
        // connection notes since when.
        try await connection.send([.text("approve"), .enter], to: session)
        #expect(try await eventually {
            let listed = try await connection.sessions().first { $0.id == session }
            return listed?.attention == .resultReady && listed?.detail == "Tests pass" && listed?.changedAt != nil
        })

        // A terminal: the host paints it, and what is typed echoes.
        let terminal = try await connection.attach(session, size: TerminalSize(columns: 80, rows: 24))
        let received = OutputCollector()
        let reader = Task {
            for await chunk in terminal.output { await received.append(chunk) }
        }
        #expect(try await eventually { await received.text.contains("hello mobile") })
        try await terminal.write(Data("typed on the phone\r".utf8))
        #expect(try await eventually { await received.text.contains("typed on the phone") })
        try await terminal.resize(TerminalSize(columns: 60, rows: 20))
        #expect(try await eventually {
            try await connection.sessions().first { $0.id == session }?.size == TerminalSize(columns: 60, rows: 20)
        })
        await terminal.detach()
        _ = await reader.value
        // The session runs on after its terminal detached.
        #expect(try await connection.sessions().first { $0.id == session }?.isRunning == true)

        await connection.disconnect()
        var heard: [MacEvent] = []
        for await event in events { heard.append(event) }
        #expect(heard.last == .disconnected(reason: "Disconnected"))
        await #expect(throws: MacConnectionError.self) { try await connection.sessions() }
    }

    /// A network gone quiet: the Mac's `cherry host control` is stopped
    /// (SIGSTOP), so the connection stays open and nothing answers.
    @Test func aMacThatStopsAnsweringIsDisconnected() async throws {
        let identity = try Loopback.authorizedIdentity()
        let connection = try await SSHMacConnector(identity: identity).connect(to: try Loopback.endpoint())
        let events = connection.events()
        let terminal = try await connection.attach(try Loopback.value("SESSION"), size: TerminalSize(columns: 80, rows: 24))
        try await connection.ping(timeout: .seconds(5))

        // This connection's control process: it names the private host's
        // id, and is the newest (an earlier test's may still be exiting).
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-n", "-f", "host control --no-start --expected-host-id \(try Loopback.value("HOST_ID"))"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try pgrep.run()
        pgrep.waitUntilExit()
        let pid = try #require(pid_t(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }

        await #expect(throws: MacConnectionError.self) { try await connection.ping(timeout: .seconds(1)) }
        var heard: [MacEvent] = []
        for await event in events { heard.append(event) }
        #expect(heard.last == .disconnected(reason: "The Mac stopped answering."))
        // The whole SSH connection closed, so the terminal detached too.
        for await _ in terminal.output {}
        await #expect(throws: MacConnectionError.self) { try await connection.sessions() }
    }

    /// `cherry host transcript` over SSH: the session's program stands in
    /// for Claude Code, with its record (`~/.claude/sessions/<pid>.json`)
    /// and transcript under the private HOME.
    @Test func anAgentsConversationIsReadFromItsSessionOnTheMac() async throws {
        let identity = try Loopback.authorizedIdentity()
        let session = try Loopback.value("SESSION")
        let pid = try #require(Int32(try Loopback.value("PROGRAM_PID")))
        let claude = URL(fileURLWithPath: try Loopback.value("HOME")).appendingPathComponent(".claude")
        defer { try? FileManager.default.removeItem(at: claude) }

        // When the program started, as Claude Code records it.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "etime=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let elapsed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
            .compactMap { Double($0) }
            .reduce(0) { $0 * 60 + $1 }
        let startedAt = Int((Date().timeIntervalSince1970 - elapsed) * 1000)
        let sessions = claude.appendingPathComponent("sessions")
        let project = claude.appendingPathComponent("projects/-")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"pid":\#(pid),"sessionId":"loopback","cwd":"/","startedAt":\#(startedAt)}"#
            .write(to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try """
        {"type":"user","uuid":"u1","message":{"content":"Run the tests"}}
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}

        """.write(to: project.appendingPathComponent("loopback.jsonl"), atomically: true, encoding: .utf8)

        let connection = try await SSHMacConnector(identity: identity).connect(to: try Loopback.endpoint())
        var conversation = Conversation()
        conversation.apply(try await connection.transcript(of: session, after: nil, limit: 50))
        #expect(conversation.agent == "claude")
        #expect(conversation.sessionID == "loopback")
        #expect(conversation.entries.map(\.kind) == [.user, .tool])
        #expect(conversation.entries.last?.status == .running)

        // What comes after: the tool's result.
        let handle = try FileHandle(forWritingTo: project.appendingPathComponent("loopback.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#.utf8 + [0x0A]))
        try handle.close()
        let next = try await connection.transcript(of: session, after: conversation.cursor, limit: 50)
        #expect(!next.reset)
        conversation.apply(next)
        #expect(conversation.entries.last?.status == .ok)
        #expect(conversation.entries.last?.result == "ok")

        // Without the record, the session runs no agent Cherry can read.
        try FileManager.default.removeItem(at: sessions)
        await #expect(throws: MacConnectionError.noConversation) {
            _ = try await connection.transcript(of: session, after: nil, limit: 50)
        }
        await connection.disconnect()
    }

    @Test func aChangedHostKeyIsRefused() async throws {
        let identity = try Loopback.authorizedIdentity()
        let pinned = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        await #expect(throws: MacConnectionError.hostKeyMismatch(
            expected: pinned,
            presented: try Loopback.value("HOST_FINGERPRINT")
        )) {
            _ = try await SSHMacConnector(identity: identity).connect(to: try Loopback.endpoint(hostKey: pinned))
        }
        // The pinned key itself connects.
        let connection = try await SSHMacConnector(identity: identity)
            .connect(to: try Loopback.endpoint(hostKey: try Loopback.value("HOST_FINGERPRINT")))
        await connection.disconnect()
    }

    @Test func aKeyTheMacDoesNotKnowIsRefused() async throws {
        _ = try Loopback.authorizedIdentity()
        await #expect(throws: MacConnectionError.authenticationFailed) {
            _ = try await SSHMacConnector(identity: InMemoryDeviceIdentity()).connect(to: try Loopback.endpoint())
        }
    }

    @Test func anotherHostIdentityIsRefused() async throws {
        let identity = try Loopback.authorizedIdentity()
        do {
            _ = try await SSHMacConnector(identity: identity)
                .connect(to: try Loopback.endpoint(hostID: "00000000-0000-0000-0000-000000000000"))
            Issue.record("connected to a host of another identity")
        } catch let error as MacConnectionError {
            guard case .failed = error else {
                Issue.record("expected a refusal, got \(error)")
                return
            }
        }
    }

    @Test func aMissingCherryIsCherryNotFound() async throws {
        let identity = try Loopback.authorizedIdentity()
        var endpoint = try Loopback.endpoint()
        endpoint.cherryPath = "/nonexistent/cherry"
        // The private HOME has no Applications folder; /Applications may
        // have a Cherry.app, which the search would then find.
        guard !FileManager.default.fileExists(atPath: "/Applications/Cherry.app/Contents/MacOS/cherry") else { return }
        await #expect(throws: MacConnectionError.cherryNotFound) {
            _ = try await SSHMacConnector(identity: identity).connect(to: endpoint)
        }
    }
}

private actor OutputCollector {
    private var bytes = Data()
    func append(_ data: Data) { bytes.append(data) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}
