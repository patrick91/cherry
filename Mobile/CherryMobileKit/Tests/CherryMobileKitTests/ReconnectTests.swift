import Foundation
import Testing
@testable import CherryMobileKit

@Test func reconnectWaitsDoubleUpToTheLimit() {
    let policy = ReconnectPolicy.standard
    let waits = (1...8).map { policy.delay(beforeAttempt: $0) }
    #expect(waits == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
    #expect(policy.delay(beforeAttempt: 0) == .seconds(1))
    #expect(policy.delay(beforeAttempt: 10_000) == .seconds(30))
}

@Test func onlyFailuresThatCanClearUpAreTriedAgain() {
    #expect(ReconnectPolicy.retries(after: MacConnectionError.unreachable("timed out")))
    #expect(ReconnectPolicy.retries(after: MacConnectionError.noSessionHost("no cherry-host is running")))
    #expect(ReconnectPolicy.retries(after: MacConnectionError.failed("The Mac refused the exec request.")))
    #expect(ReconnectPolicy.retries(after: CancellationError()))
    #expect(!ReconnectPolicy.retries(after: MacConnectionError.authenticationFailed))
    #expect(!ReconnectPolicy.retries(after: MacConnectionError.hostKeyMismatch(expected: "SHA256:a", presented: "SHA256:b")))
    #expect(!ReconnectPolicy.retries(after: MacConnectionError.cherryNotFound))
    #expect(!ReconnectPolicy.retries(after: MacConnectionError.protocolMismatch("version 3")))
}

@Test func aDroppedDemoConnectionTellsWhyAndDetachesItsTerminals() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint) as! DemoMacConnection
    let events = connection.events()
    let terminal = try await connection.attach("demo-zsh", size: TerminalSize(columns: 40, rows: 20))
    try await connection.ping(timeout: .seconds(1))
    try await Task.sleep(for: .milliseconds(20))
    await connection.drop(reason: "The Mac stopped answering.")
    var seen: [MacEvent] = []
    for await event in events { seen.append(event) }
    #expect(seen == [.disconnected(reason: "The Mac stopped answering.")])
    var output: [Data] = []
    for await data in terminal.output { output.append(data) }
    #expect(output.count == 1)
    await #expect(throws: MacConnectionError.self) { try await connection.ping(timeout: .seconds(1)) }
}
