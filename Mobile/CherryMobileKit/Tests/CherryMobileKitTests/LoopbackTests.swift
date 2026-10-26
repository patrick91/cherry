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

        // Listed, with its agent state from the (stand-in) MCP helper.
        let sessions = try await connection.sessions()
        let listed = try #require(sessions.first { $0.id == session })
        #expect(listed.kind == .agent("claude"))
        #expect(listed.title == "Fix the tests")
        #expect(listed.attention == .approval)
        #expect(listed.detail == "Fix the tests")
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
