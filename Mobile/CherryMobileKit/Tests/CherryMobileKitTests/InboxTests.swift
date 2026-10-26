import Foundation
import Testing
@testable import CherryMobileKit

private let mac = UUID()

private func session(
    _ id: String,
    _ attention: AgentAttention,
    kind: SessionKind = .agent("claude"),
    minutesAgo: Double? = nil
) -> MobileSession {
    MobileSession(
        id: id, macID: mac, title: id, kind: kind, attention: attention,
        changedAt: minutesAgo.map { Date().addingTimeInterval(-$0 * 60) }
    )
}

@Test func whatNeedsYouComesFirstThenWorkThenTheRest() {
    let sections = Inbox.sections(of: [
        session("shell", .unknown, kind: .terminal),
        session("busy", .working, minutesAgo: 1),
        session("done", .resultReady, minutesAgo: 5),
        session("asks", .approval, minutesAgo: 1),
    ])
    #expect(sections.map(\.section) == [.needsYou, .working, .other])
    #expect(sections[0].sessions.map(\.id) == ["asks", "done"])
}

@Test func resultsThatWaitedLongestComeFirst() {
    let sections = Inbox.sections(of: [
        session("recent", .resultReady, minutesAgo: 1),
        session("old", .resultReady, minutesAgo: 30),
    ])
    #expect(sections[0].sessions.map(\.id) == ["old", "recent"])
}

@Test func otherSessionsAreAgentsThenCommandsThenTerminalsByName() {
    let sections = Inbox.sections(of: [
        session("zsh", .unknown, kind: .terminal),
        session("npm run dev", .unknown, kind: .command),
        session("pi", .idle, kind: .agent("pi")),
        session("bash", .unknown, kind: .terminal),
    ])
    #expect(sections.map(\.section) == [.other])
    #expect(sections[0].sessions.map(\.id) == ["pi", "npm run dev", "bash", "zsh"])
}

@Test func sessionsOfTwoMacsWithOneIDAreTwoKeys() {
    let a = MobileSession(id: "s1", macID: UUID(), title: "a", kind: .terminal)
    let b = MobileSession(id: "s1", macID: UUID(), title: "b", kind: .terminal)
    #expect(a.key != b.key)
}
