import Foundation
import Testing
@testable import Cherry

private struct HostedTerminationFixture {
    let directory: URL
    let client: HostedSessionClient

    init(behavior: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-termination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("cherry")
        let path = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        cd \(path) || exit 90
        printf '%s\\n' "$*" >> calls
        case " $* " in
          *" kill session-a "*) : > killed; exit 0 ;;
          *" list --json "*) ;;
          *) exit 91 ;;
        esac
        count=0
        if [ -f killed ]; then
          if [ -f polls ]; then read -r count < polls; fi
          count=$((count + 1))
          printf '%s\\n' "$count" > polls
        fi
        state=running
        identity=host-a
        if [ "$count" -ge 3 ] && [ '\(behavior)' = exit ]; then state=exited; fi
        if [ "$count" -gt 0 ] && [ '\(behavior)' = identity ]; then identity=host-b; state=exited; fi
        target="{\\"id\\":\\"session-a\\",\\"name\\":\\"Target\\",\\"cwd\\":\\"/remote\\",\\"command\\":[\\"/bin/sh\\"],\\"cols\\":80,\\"rows\\":24,\\"state\\":\\"$state\\",\\"attached\\":false},"
        if [ "$count" -ge 3 ] && [ '\(behavior)' = removed ]; then target=; fi
        printf '{"host_id":"%s","sessions":[%s{"id":"session-b","name":"Unrelated","cwd":"/remote","command":["/bin/sh"],"cols":80,"rows":24,"state":"running","attached":false}]}\\n' "$identity" "$target"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = HostedSessionClient(executableURL: executable, timeout: 2)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    var calls: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

@Test(arguments: ["exit", "removed"])
@MainActor func HostedSessionTerminationWaitsForItsSessionWithoutRetryingKill(behavior: String) async throws {
    let fixture = try HostedTerminationFixture(behavior: behavior)
    defer { fixture.cleanUp() }
    let controller = HostedSessionsController(clientProvider: { fixture.client })
    let host = try HostedSessionHost.ssh("devbox")
    await controller.refresh(host)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })

    await controller.terminate(target, on: host)

    #expect(controller.error == nil)
    #expect(!controller.isBusy)
    #expect(controller.hostID == "host-a")
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning != true)
    #expect(controller.sessions.first { $0.id == "session-b" }?.isRunning == true)
    #expect(fixture.calls.filter { $0.contains(" kill ") } == ["--host devbox --expected-host-id host-a kill session-a"])
    let polls = fixture.calls.filter { $0.contains("--expected-host-id") && $0.hasSuffix("list --json") }
    #expect(polls.count >= 3)
    #expect(polls.allSatisfy { $0 == "--host devbox --expected-host-id host-a list --json" })
}

@Test @MainActor func HostedSessionTerminationRejectsReplacementHostIdentity() async throws {
    let fixture = try HostedTerminationFixture(behavior: "identity")
    defer { fixture.cleanUp() }
    let controller = HostedSessionsController(clientProvider: { fixture.client })
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })

    await controller.terminate(target, on: .local)

    #expect(controller.error?.contains("identity changed") == true)
    #expect(!controller.isBusy)
    #expect(controller.hostID == nil)
    #expect(controller.loadedHost == nil)
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning == true)
    #expect(fixture.calls.filter { $0.contains(" kill ") }.count == 1)
}

@Test @MainActor func HostedSessionTerminationBoundsExitWaitAndReleasesBusyState() async throws {
    let fixture = try HostedTerminationFixture(behavior: "running")
    defer { fixture.cleanUp() }
    let controller = HostedSessionsController(clientProvider: { fixture.client }, terminationTimeout: 0.35)
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let started = Date()

    await controller.terminate(target, on: .local)

    #expect(Date().timeIntervalSince(started) < 3)
    #expect(controller.error?.contains("not confirmed") == true)
    #expect(!controller.isBusy)
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning == true)
    #expect(fixture.calls.filter { $0.contains(" kill ") }.count == 1)
}

@Test @MainActor func HostedSessionTerminationCancellationReleasesBusyState() async throws {
    let fixture = try HostedTerminationFixture(behavior: "running")
    defer { fixture.cleanUp() }
    let controller = HostedSessionsController(clientProvider: { fixture.client })
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let operation = Task { await controller.terminate(target, on: .local) }
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("polls").path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.isBusy)
    operation.cancel()
    await operation.value

    #expect(!controller.isBusy)
    #expect(controller.error == nil)
    #expect(fixture.calls.filter { $0.contains(" kill ") }.count == 1)
}
