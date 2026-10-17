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

@Test func aDigitAloneAnswersTheDemoMenuAsClaudesDo() async throws {
    let connection = try await DemoMac(turnDuration: .seconds(60)).connect(to: DemoMac.endpoint)
    let menu = try #require(ScreenMenu.find(in: try await connection.screen(of: "demo-claude").lines))
    try await connection.send(menu.options[2].keys, to: "demo-claude")
    let session = try await connection.sessions().first { $0.id == "demo-claude" }
    #expect(session?.attention == .resultReady)
    #expect(try await connection.screen(of: "demo-claude").lines.first == "⏺ Stopped. What should I do instead?")
}

@Test func aDigitTypedIntoTheDemoTerminalAnswersItsMenu() async throws {
    let connection = try await DemoMac(turnDuration: .seconds(60)).connect(to: DemoMac.endpoint)
    let terminal = try await connection.attach("demo-claude", size: TerminalSize(columns: 80, rows: 24))
    try await terminal.write(Data("1".utf8))
    #expect(try await connection.sessions().first { $0.id == "demo-claude" }?.attention == .working)
    await terminal.detach()
}

@Test func theDemoTerminalPaintsWhatFitsItsSizeAndRepaintsOnResize() async throws {
    let connection = try await DemoMac().connect(to: DemoMac.endpoint)
    let terminal = try await connection.attach("demo-claude", size: TerminalSize(columns: 20, rows: 5))
    var output = terminal.output.makeAsyncIterator()
    let painted = String(decoding: try #require(await output.next()), as: UTF8.self)
    let lines = painted.replacingOccurrences(of: "\u{1B}[H\u{1B}[2J", with: "").components(separatedBy: "\r\n")
    #expect(lines.count == 5)
    #expect(lines.allSatisfy { $0.count <= 20 })
    try await terminal.resize(TerminalSize(columns: 60, rows: 30))
    let repainted = String(decoding: try #require(await output.next()), as: UTF8.self)
    #expect(repainted.contains("I'll run the key encoder tests"))
    await terminal.detach()
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
