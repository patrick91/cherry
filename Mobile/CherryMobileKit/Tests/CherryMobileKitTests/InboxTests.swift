import Foundation
import Testing
@testable import CherryMobileKit

private let mac = UUID()

private func session(
    _ id: String,
    _ attention: AgentAttention = .unknown,
    kind: SessionKind = .agent("claude"),
    in project: String? = nil,
    directory: String? = nil,
    macID: UUID = mac
) -> MobileSession {
    MobileSession(id: id, macID: macID, title: id, directory: directory, project: project, kind: kind, attention: attention)
}

@Test func sessionsAreGroupedByTheirMacsProject() throws {
    let other = UUID()
    let projects = Inbox.projects(of: [
        session("fix", .working, in: "/Users/me/github/me/cherry", directory: "/Users/me/github/me/cherry/Host"),
        session("zsh", kind: .terminal, directory: "/Users/me/github/me/cherry"),
        session("review", .working, in: "/Users/me/github/me/cherry", macID: other),
        session("home", kind: .terminal, directory: "/Users/me"),
    ])
    #expect(projects.map(\.name) == ["cherry", "cherry", "Home"])
    let here = try #require(projects.first { $0.macID == mac && $0.name == "cherry" })
    #expect(here.root == "~/github/me/cherry")
    #expect(here.parent == "~/github/me")
    #expect(here.agents.map(\.id) == ["fix"])
    #expect(here.others.map(\.id) == ["zsh"])
    #expect(projects.last?.root == "~")
    #expect(session("x", directory: "/Users/me/github/me/cherry/Host").projectName == "Host")
    #expect(session("x", in: "/Users/me", directory: "/tmp").projectName == "Home")
}

@Test func projectsThatNeedYouComeFirstThenWorkThenQuietOnesByName() {
    let projects = Inbox.projects(of: [
        session("idle", .idle, in: "~/a-quiet"),
        session("dev", kind: .command, in: "~/b-quiet"),
        session("works", .working, in: "~/c-working"),
        session("done", .resultReady, in: "~/d-result"),
        session("asks", .question, in: "~/e-question"),
        session("approve", .approval, in: "~/f-approval"),
        session("works too", .working, in: "~/b-working"),
    ])
    #expect(projects.map(\.name) == ["f-approval", "e-question", "d-result", "b-working", "c-working", "a-quiet", "b-quiet"])
    #expect(projects.map(\.isQuiet) == [false, false, false, false, false, true, true])
}

@Test func aProjectsAgentsComeByWhatTheyNeedAndItsCommandsBeforeItsTerminals() throws {
    let project = try #require(Inbox.projects(of: [
        session("b idle", .idle, in: "~/app"),
        session("working", .working, in: "~/app"),
        session("a idle", .idle, in: "~/app"),
        session("approve", .approval, in: "~/app"),
        session("zsh", kind: .terminal, in: "~/app"),
        session("npm run dev", kind: .command, in: "~/app"),
    ]).first)
    #expect(project.agents.map(\.id) == ["approve", "working", "a idle", "b idle"])
    #expect(project.others.map(\.id) == ["npm run dev", "zsh"])
}

@Test func aFilterKeepsOnlyItsAgents() {
    let sessions = [
        session("approve", .approval, in: "~/app"),
        session("done", .resultReady, in: "~/notes"),
        session("works", .working, in: "~/app"),
        session("zsh", kind: .terminal, in: "~/app"),
    ]
    #expect(Inbox.projects(of: sessions, filter: .needsYou).map { $0.agents.map(\.id) } == [["approve"], ["done"]])
    #expect(Inbox.projects(of: sessions, filter: .working).flatMap(\.others).isEmpty)
    #expect(Inbox.count(.needsYou, in: sessions) == 2)
    #expect(Inbox.count(.working, in: sessions) == 1)
    #expect(Inbox.count(.all, in: sessions) == 4)
}

@Test func anEndedAgentIsQuiet() {
    var ended = session("ended", .approval, in: "~/app")
    ended.isRunning = false
    #expect(Inbox.projects(of: [ended]).first?.isQuiet == true)
}

@Test func anAgentsTaskIsItsTitleUnlessThatIsItsTool() {
    var agent = session("Fix the key encoder tests")
    #expect(agent.task == "Fix the key encoder tests")
    #expect(agent.agentDisplayName == "Claude")
    agent.title = "Claude Code"
    #expect(agent.task == nil)
    #expect(session("x", kind: .agent("amp")).agentDisplayName == "Amp")
}

@Test func theProjectComesFromCherrysTagAndADeviceKeyIsItsPath() {
    func info(_ tags: [String: String]) -> HostWireSession {
        HostWireSession(id: "s", name: "fix", cwd: "/Users/me/app/Sources", tags: tags.merging(["cherry.kind": "agent"]) { a, _ in a })
    }
    #expect(SessionMapping.session(info(["cherry.project": "/Users/me/app"]), macID: mac).project == "/Users/me/app")
    #expect(SessionMapping.session(info(["cherry.project": "device:6F1C2D3E-0000-4000-8000-000000000001:/Users/me/app"]), macID: mac).project == "/Users/me/app")
    #expect(SessionMapping.session(info([:]), macID: mac).project == nil)
}

@Test func sessionsOfTwoMacsWithOneIDAreTwoKeys() {
    let a = MobileSession(id: "s1", macID: UUID(), title: "a", kind: .terminal)
    let b = MobileSession(id: "s1", macID: UUID(), title: "b", kind: .terminal)
    #expect(a.key != b.key)
}
