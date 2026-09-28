import Foundation
import Testing
@testable import Cherry

// `HostControl.shutdown()`: final, for a teardown that must leave nothing
// running (a test's fake Mac, whose connection attempt under way could
// otherwise start a daemon there after the teardown stopped it), and
// `startsHost` (`cherry control --no-start`).

private final class GatedLauncher: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entered = false
    private var _finished = 0
    var entered: Bool { lock.withLock { _entered } }
    var finished: Int { lock.withLock { _finished } }

    func launcher(_ fake: FakeControlHelper) -> HostControlLauncher {
        { [self] launch in
            lock.withLock { _entered = true }
            gate.wait()
            let channel = try fake.launcher(launch)
            return HostControlChannel(input: channel.input, output: channel.output) { [self] in
                lock.withLock { _finished += 1 }
                channel.finish()
            }
        }
    }
}

@Test @MainActor func HostControlShutdownStopsAnAttemptUnderWayAndNeverConnectsAgain() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    let gated = GatedLauncher()
    let control = HostControl(
        host: .local,
        clientProvider: {
            HostedSessionClient(executableURL: URL(fileURLWithPath: "/fake/bin/cherry"), loginEnvironment: { _ in .init(environment: [:]) })
        },
        hostStore: store,
        masters: disabledSSHMasters,
        launcher: gated.launcher(fake),
        localHostUnavailableReason: nil,
        configuration: .fastTests
    )
    // An attempt is launching its helper when the control shuts down.
    let attempt = Task { @MainActor in try await control.connect() }
    while !gated.entered { try await Task.sleep(for: .milliseconds(5)) }
    control.shutdown()
    gated.gate.signal()
    await #expect(throws: HostedSessionError.self) { _ = try await attempt.value }
    // Its helper was stopped before it said anything to the host.
    #expect(gated.finished == 1)
    #expect(fake.requests.isEmpty)
    #expect(control.state != .connected)
    // Nothing connects again: a request, a lease.
    await #expect(throws: HostedSessionError.self) { _ = try await control.list() }
    let lease = control.retain()
    try await Task.sleep(for: .milliseconds(100))
    lease.release()
    #expect(fake.launches.count == 1)
    #expect(control.isShutDown)
}

@Test @MainActor func HostControlThatStartsNoHostRunsControlWithNoStart() async throws {
    let (store, defaults, suite) = try makeIsolatedHostedSessionHostStore()
    defer { defaults.removePersistentDomain(forName: suite) }
    let fake = FakeControlHelper()
    var configuration = HostControl.Configuration.fastTests
    configuration.startsHost = false
    let looking = makeFakeHostControl(fake, hostStore: store, configuration: configuration)
    defer { looking.disconnect() }
    try await looking.connect()
    #expect(fake.launches.last?.arguments.suffix(2) == ["control", "--no-start"])
    let starting = makeFakeHostControl(fake, hostStore: store)
    defer { starting.disconnect() }
    try await starting.connect()
    #expect(fake.launches.last?.arguments.last == "control")
}
