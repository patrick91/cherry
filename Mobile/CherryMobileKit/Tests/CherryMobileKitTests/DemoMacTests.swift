import Foundation
import Testing
@testable import CherryMobileKit

@Test func theDemoMacListsAnAgentInEveryState() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint)
    let sessions = try await connection.sessions()
    #expect(sessions.count == 5)
    #expect(Set(sessions.map(\.attention)).isSuperset(of: [.approval, .working, .resultReady]))
    #expect(sessions.allSatisfy { $0.macID == DemoMac.endpoint.id })
}

@Test func approvingTheDemoAgentRunsATurnThatEndsWithAResult() async throws {
    let connection = try await DemoMac(turnDuration: .milliseconds(50)).connect(to: DemoMac.endpoint)
    let events = connection.events()
    try await connection.send([.text("1"), .enter], to: "demo-claude")
    #expect(try await connection.sessions().first { $0.id == "demo-claude" }?.attention == .working)
    for await event in events where event == .sessionsChanged {
        if try await connection.sessions().first(where: { $0.id == "demo-claude" })?.attention == .resultReady {
            break
        }
    }
    let screen = try await connection.screen(of: "demo-claude")
    #expect(screen.lines.contains { $0.contains("tests passed") })
}

@Test func aGoneSessionIsAnError() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint)
    await #expect(throws: MacConnectionError.sessionGone("nope")) {
        try await connection.screen(of: "nope")
    }
}

@Test func anAttachedDemoTerminalPaintsTheScreenAndEchoes() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint)
    let terminal = try await connection.attach("demo-zsh", size: TerminalSize(columns: 40, rows: 20))
    var output = terminal.output.makeAsyncIterator()
    let painted = try #require(await output.next())
    #expect(String(decoding: painted, as: UTF8.self).contains("~ ❯"))
    try await terminal.write(Data("ls".utf8))
    let echoed = try #require(await output.next())
    #expect(String(decoding: echoed, as: UTF8.self) == "l")
    await terminal.detach()
}

@Test func quickReplyKeysAreALegacyTerminalsBytes() {
    #expect(MobileKey.enter.bytes == Data([0x0D]))
    #expect(MobileKey.up.bytes == Data("\u{1B}[A".utf8))
    #expect(MobileKey.text("yes").bytes == Data("yes".utf8))
}

@Test func anEndedConnectionEndsItsEvents() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint)
    let events = connection.events()
    try await Task.sleep(for: .milliseconds(20))
    await connection.disconnect()
    var seen: [MacEvent] = []
    for await event in events {
        seen.append(event)
    }
    #expect(seen == [.disconnected(reason: "Disconnected")])
}
