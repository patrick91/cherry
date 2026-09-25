import Foundation
import Testing
@testable import Cherry

private func terminationFixture() -> FakeControlHelper {
    FakeControlHelper(sessions: [hostedSession("session-a", name: "Target"), hostedSession("session-b", name: "Unrelated")])
}

@MainActor
private func terminationController(
    _ fake: FakeControlHelper,
    store: HostedSessionHostStore,
    terminationTimeout: TimeInterval = 5
) -> (HostedSessionsController, HostControlRegistry) {
    let registry = makeFakeHostControlRegistry(fake, hostStore: store)
    return (HostedSessionsController(controls: registry, hostStore: store, terminationTimeout: terminationTimeout), registry)
}

/// "exit": the host reports the exit as events. "removed": another client
/// removed the exited session. "polled": a host without events, whose list
/// is polled.
@Test(arguments: ["exit", "removed", "polled"])
@MainActor func HostedSessionTerminationWaitsForItsSessionWithoutRetryingKill(behavior: String) async throws {
    let fake = terminationFixture()
    switch behavior {
    case "removed":
        fake.killEndsSession = false
        fake.respond = { [weak fake] request, connection in
            guard request.op == "kill", let fake else { return nil }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                fake.sessions.removeAll { $0.id == "session-a" }
                connection.push(.event(.removed(id: "session-a")))
            }
            return nil
        }
    case "polled":
        fake.supportsSubscribe = false
        fake.killEndsSession = false
        fake.respond = { [weak fake] request, _ in
            guard request.op == "kill", let fake else { return nil }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                fake.sessions = fake.sessions.map { $0.id == "session-a" ? $0.exited(code: 129, signal: 1) : $0 }
            }
            return nil
        }
    default:
        break
    }
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, registry) = terminationController(fake, store: store)
    defer { registry.disconnectAll() }
    let host = try HostedSessionHost.ssh("devbox")
    await controller.refresh(host)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })

    await controller.terminate(target, on: host)

    #expect(controller.error == nil)
    #expect(!controller.isBusy)
    #expect(controller.hostID == "host-a")
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning != true)
    #expect(controller.sessions.first { $0.id == "session-b" }?.isRunning == true)
    #expect(fake.requests("kill").map { $0.string("id") } == ["session-a"])
    if behavior == "polled" {
        #expect(fake.requests("list").count >= 3)
    }
}

/// "local": This Mac is never pinned, so the other host connects. "ssh": the
/// control refuses the untrusted host, whose missing session must not read
/// as "gone".
@Test(arguments: ["local", "ssh"])
@MainActor func HostedSessionTerminationRejectsReplacementHostIdentity(hostKind: String) async throws {
    let fake = terminationFixture()
    fake.killEndsSession = false
    // After the kill, the connection drops and another host answers.
    fake.respond = { [weak fake] request, connection in
        guard request.op == "kill", let fake else { return nil }
        fake.hostID = "host-b"
        fake.sessions = [hostedSession("session-a", state: .exited, exitCode: 0)]
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { connection.exit() }
        return nil
    }
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, registry) = terminationController(fake, store: store)
    defer { registry.disconnectAll() }
    let host = hostKind == "ssh" ? try store.add("devbox") : .local
    await controller.refresh(host)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let launches = fake.launches.count

    await controller.terminate(target, on: host)

    #expect(controller.error?.contains("identity changed") == true)
    #expect(!controller.isBusy)
    #expect(controller.hostID == nil)
    #expect(controller.loadedHost == nil)
    // The other host's list never replaces this one's.
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning == true)
    #expect(fake.requests("kill").count == 1)
    // One reconnect found the other host; nothing polled it afterwards.
    #expect(fake.launches.count == launches + 1)
    if hostKind == "ssh" {
        #expect(store.trustedHostID(for: host) == "host-a")
    }
}

@Test @MainActor func HostedSessionTerminationBoundsExitWaitAndReleasesBusyState() async throws {
    let fake = terminationFixture()
    fake.killEndsSession = false
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, registry) = terminationController(fake, store: store, terminationTimeout: 0.35)
    defer { registry.disconnectAll() }
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let started = Date()

    await controller.terminate(target, on: .local)

    #expect(Date().timeIntervalSince(started) < 3)
    #expect(controller.error?.contains("not confirmed") == true)
    #expect(!controller.isBusy)
    #expect(controller.sessions.first { $0.id == "session-a" }?.isRunning == true)
    #expect(fake.requests("kill").count == 1)
}

@Test @MainActor func HostedSessionTerminationCancellationReleasesBusyState() async throws {
    let fake = terminationFixture()
    fake.killEndsSession = false
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, registry) = terminationController(fake, store: store)
    defer { registry.disconnectAll() }
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let operation = Task { await controller.terminate(target, on: .local) }
    #expect(await fake.wait { fake.requests("kill").count == 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.isBusy)
    operation.cancel()
    await operation.value

    #expect(!controller.isBusy)
    #expect(controller.error == nil)
    #expect(fake.requests("kill").count == 1)
}

/// "drop": the connection is lost after the kill and cannot be reopened
/// (the helper's own interruption text must not become the answer).
/// "silent": the host never reports the exit.
@Test(arguments: ["drop", "silent"])
@MainActor func HostedSessionTerminationWaitFailureDoesNotClaimTheSessionSurvived(behavior: String) async throws {
    let fake = terminationFixture()
    fake.killEndsSession = false
    if behavior == "drop" {
        let interruption = "cherry: interrupted by signal 15; the host session was not terminated"
        fake.respond = { [weak fake] request, connection in
            guard request.op == "kill", let fake else { return nil }
            fake.launchFailure = interruption
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { connection.exit(stderr: interruption + "\n") }
            return nil
        }
    }
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let (controller, registry) = terminationController(fake, store: store, terminationTimeout: 0.5)
    defer { registry.disconnectAll() }
    await controller.refresh(.local)
    let target = try #require(controller.sessions.first { $0.id == "session-a" })
    let started = Date()

    await controller.terminate(target, on: .local)

    #expect(Date().timeIntervalSince(started) < 4)
    // The host accepted the kill; a lost connection or a missing report
    // must not surface as "was not terminated".
    #expect(controller.error?.contains("Termination was requested") == true)
    #expect(controller.error?.contains("not terminated") == false)
    #expect(!controller.isBusy)
    #expect(controller.hostID == "host-a")
    #expect(fake.requests("kill").count == 1)
}
