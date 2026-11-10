import Foundation
import Testing
@testable import Cherry

// Program status (OSC 7501): the reports Cherry's own parser reads, the
// records a native tab keeps, and what the host's records decode to.

@Test func programStatusReportsParseAsClaudeCodeSendsThem() throws {
    let blocked = try #require(ProgramStatusReport(
        osc: "state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiB0b3VjaCB6ei1wcm9iZS50eHQ="
    ))
    #expect(blocked == ProgramStatusReport(
        state: .blocked, kind: .permission, app: "claude-code", message: "approve Bash: touch zz-probe.txt"
    ))
    let working = try #require(ProgramStatusReport(osc: "id=build/test:state=working:progress=40:title=VGVzdHM="))
    #expect(working.id == "build/test")
    #expect(working.progress == 40)
    #expect(working.title == "Tests")
    // A clear has no state.
    #expect(ProgramStatusReport(osc: "state=clear")?.state == nil)
    // Unknown keys are ignored; a repeated key keeps its last value.
    #expect(ProgramStatusReport(osc: "state=idle:future=1:state=done")?.state == .done)
    // kind and progress only where they mean something.
    #expect(ProgramStatusReport(osc: "state=done:kind=question:progress=50") == ProgramStatusReport(state: .done))
    #expect(ProgramStatusReport(osc: "state=working:progress=101")?.progress == nil)
}

@Test func programStatusReportsThatBreakTheRulesAreDroppedWhole() {
    for body in [
        "?",
        "",
        "app=claude-code",
        "state=sparkle",
        "state=working:msg=not base64!",
        // Decoded text with a control character (ESC).
        "state=working:msg=G1szMW0=",
        "state=working:id=a//b",
        "state=working:id=" + String(repeating: "a", count: 33),
        "state=working:app=" + String(repeating: "a", count: 33),
        "state=working:msg=" + String(repeating: "A", count: 4_100),
    ] {
        #expect(ProgramStatusReport(osc: body) == nil, "\(body.prefix(40))")
    }
}

@Test func programStatusRecordsFollowTheSpecificationsRules() {
    var records = ProgramStatusRecords()
    let changed1 = records.apply(ProgramStatusReport(state: .working, message: "Writing notes.txt"))
    #expect(changed1)
    // A report replaces its record whole.
    let changed2 = records.apply(ProgramStatusReport(state: .working))
    #expect(changed2)
    #expect(records.records.root?.message == "")
    let changed3 = records.apply(ProgramStatusReport(state: .working))
    #expect(!changed3)
    for id in ["build", "build/test", "builder"] {
        records.apply(ProgramStatusReport(state: .working, id: id))
    }
    // A clear takes the record and its children, not a sibling that shares
    // its prefix.
    let changed4 = records.apply(ProgramStatusReport(state: nil, id: "build"))
    #expect(changed4)
    #expect(records.records.map(\.id) == ["", "builder"])
    // The program ends: only what the user has not seen stays.
    records.apply(ProgramStatusReport(state: .done, id: "lint"))
    records.apply(ProgramStatusReport(state: .error, id: "deploy"))
    let changed5 = records.endProgram()
    #expect(changed5)
    #expect(records.records.map(\.id) == ["lint", "deploy"])
    records.removeAll()
    // At most `maxRecords`: the one updated longest ago makes room.
    for n in 0...ProgramStatusRecords.maxRecords {
        records.apply(ProgramStatusReport(state: .working, id: "r\(n)"))
    }
    #expect(records.records.count == ProgramStatusRecords.maxRecords)
    #expect(records.records.first?.id == "r1")
    // A clear without an id takes them all.
    let changed7 = records.apply(ProgramStatusReport(state: nil))
    #expect(changed7)
    #expect(records.records.isEmpty)
}

@Test func programStatusTextLosesInvisibleFormatting() {
    var records = ProgramStatusRecords()
    records.apply(ProgramStatusReport(state: .done, title: "a\u{202E}b\u{200B}c", message: "👨\u{200D}👩 \u{2066}x\u{2069}"))
    #expect(records.records.root?.title == "abc")
    #expect(records.records.root?.message == "👨\u{200D}👩 x")
}

@Test func theHostsRecordsDecodeAndAnUnknownStateIsKept() throws {
    let json = """
    {"id":"s","name":"","cwd":"/","command":[],"cols":80,"rows":24,"state":"running",
     "program_status":[{"state":"blocked","kind":"question","app":"pi","message":"Which one?"},
                       {"id":"x/y","state":"sparkle","kind":"telepathy","progress":3}]}
    """
    let info = try JSONDecoder().decode(HostedSessionInfo.self, from: Data(json.utf8))
    #expect(info.programStatus.root == ProgramStatus(state: .blocked, kind: .question, app: "pi", message: "Which one?"))
    #expect(info.programStatus.last == ProgramStatus(id: "x/y", state: .unknown, kind: .unknown, progress: 3))
    // Left out when there are none, as the host writes it.
    let none = try JSONDecoder().decode(
        HostedSessionInfo.self,
        from: Data(#"{"id":"s","name":"","cwd":"/","command":[],"cols":80,"rows":24,"state":"running"}"#.utf8)
    )
    #expect(none.programStatus.isEmpty)
    #expect(!String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("program_status"))
}

@Test func anAgentsStateIsItsRootRecords() {
    #expect(AgentActivityState(nil) == .unknown)
    #expect(AgentActivityState(ProgramStatus(state: .idle)) == .idle)
    #expect(AgentActivityState(ProgramStatus(state: .done)) == .idle)
    #expect(AgentActivityState(ProgramStatus(state: .working)) == .working)
    #expect(AgentActivityState(ProgramStatus(state: .blocked, kind: .permission)) == .permission)
    #expect(AgentActivityState(ProgramStatus(state: .blocked, kind: .question)) == .needsInput)
    #expect(AgentActivityState(ProgramStatus(state: .blocked, kind: .auth)) == .needsInput)
    #expect(AgentActivityState(ProgramStatus(state: .blocked)) == .needsInput)
    #expect(AgentActivityState(ProgramStatus(state: .error)) == .error)
}

/// The records a restored or attached tab finds are not news: no unseen
/// result and no notification for them; a turn that ends later is.
@MainActor
@Test func recordsATabFindsAreNotNewsButATurnThatEndsLaterIs() {
    var notified: [ProgramStatus.State] = []
    let session = TerminalSession(
        title: "Claude",
        subtitle: "claude",
        tint: .systemPurple,
        launchShell: false,
        kind: .agent,
        agentName: "Claude",
        programStatusNotificationHandler: { status, _ in notified.append(status.state) }
    )
    defer { session.stop() }
    session.applyProgramStatus([ProgramStatus(state: .done, app: "claude-code")])
    #expect(session.agentActivityState == .idle)
    #expect(session.agentTurnState == .completed)
    #expect(!session.hasUnseenAgentResult)
    #expect(notified.isEmpty)

    session.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    session.applyProgramStatus([ProgramStatus(state: .blocked, kind: .permission, app: "claude-code")])
    #expect(notified == [.blocked])
    session.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
    session.applyProgramStatus([ProgramStatus(state: .done, app: "claude-code")])
    #expect(session.hasUnseenAgentResult)
    // At most one notification per tab every 2 s.
    #expect(notified == [.blocked])
}

@Test func workersNotificationsAllowWhatTheirSettingSays() {
    let blocked = ProgramStatus(state: .blocked, kind: .permission)
    let done = ProgramStatus(state: .done)
    let error = ProgramStatus(state: .error)
    #expect(WorkerNotifications.allCases.map(\.label) == ["Never", "When they need you", "Always"])
    #expect([blocked, done, error].map(WorkerNotifications.never.allows) == [false, false, false])
    #expect([blocked, done, error].map(WorkerNotifications.needsYou.allows) == [true, false, false])
    #expect([blocked, done, error].map(WorkerNotifications.always.allows) == [true, true, true])
    #expect(WorkerNotifications.allCases.filter(\.allowsTerminalNotifications) == [.always])
}

/// A worker (an agent tab nested under the agent that runs it) posts a
/// program status notification only as Settings › Notifications › Workers
/// says, read at each report; one it keeps to itself leaves the 2 s limit
/// alone, and its row is marked either way. Once its orchestrator is gone
/// (top-level again) it notifies as any tab.
@MainActor
@Test func aWorkersProgramStatusNotifiesOnlyAsTheWorkersSettingSays() {
    func worker(
        _ setting: @escaping @MainActor () -> WorkerNotifications,
        notified: @escaping @MainActor (ProgramStatus.State) -> Void
    ) -> TerminalSession {
        let session = TerminalSession(
            title: "Worker",
            subtitle: "claude",
            tint: .systemPurple,
            launchShell: false,
            kind: .agent,
            agentName: "Claude",
            parentAgentID: UUID(),
            programStatusNotificationHandler: { status, _ in notified(status.state) },
            workerNotifications: setting
        )
        // The first report is not news.
        session.applyProgramStatus([ProgramStatus(state: .idle, app: "claude-code")])
        return session
    }
    func turn(_ session: TerminalSession, ending end: ProgramStatus) {
        session.applyProgramStatus([ProgramStatus(state: .working, app: "claude-code")])
        session.applyProgramStatus([end])
    }
    let ends = [
        ProgramStatus(state: .done, app: "claude-code"),
        ProgramStatus(state: .error, app: "claude-code"),
        ProgramStatus(state: .blocked, kind: .permission, app: "claude-code"),
    ]

    var setting = WorkerNotifications.never
    var never: [ProgramStatus.State] = []
    let quiet = worker({ setting }) { never.append($0) }
    defer { quiet.stop() }
    #expect(quiet.isWorker)
    for end in ends { turn(quiet, ending: end) }
    #expect(never.isEmpty)
    #expect(quiet.hasUnseenAgentResult)

    var needsYou: [ProgramStatus.State] = []
    let asking = worker({ .needsYou }) { needsYou.append($0) }
    defer { asking.stop() }
    for end in ends { turn(asking, ending: end) }
    // The done and the error it kept to itself left room for the question.
    #expect(needsYou == [.blocked])

    var always: [ProgramStatus.State] = []
    let loud = worker({ .always }) { always.append($0) }
    defer { loud.stop() }
    for end in ends { turn(loud, ending: end) }
    // As any tab: one every 2 s.
    #expect(always == [.done])

    // The setting is read at each report.
    setting = .always
    turn(quiet, ending: ProgramStatus(state: .done, app: "claude-code"))
    #expect(never == [.done])

    // Top-level again: as any tab, whatever the setting.
    var promoted: [ProgramStatus.State] = []
    let orphan = worker({ .never }) { promoted.append($0) }
    defer { orphan.stop() }
    orphan.setParentAgentID(nil)
    #expect(!orphan.isWorker)
    turn(orphan, ending: ProgramStatus(state: .done, app: "claude-code"))
    #expect(promoted == [.done])
}

/// A worker's own notifications (OSC 9/777) mark its row and go out only
/// with Workers set to Always.
@MainActor
@Test func aWorkersOwnNotificationsGoOutOnlyWhenWorkersAlwaysNotify() {
    TerminalNotificationCenter.shared.isDeliveryEnabled = false
    defer { TerminalNotificationCenter.shared.isDeliveryEnabled = true }
    for setting in WorkerNotifications.allCases {
        let session = TerminalSession(
            title: "Worker",
            subtitle: "codex",
            tint: .systemPurple,
            launchShell: false,
            kind: .agent,
            agentName: "Codex",
            parentAgentID: UUID(),
            workerNotifications: { setting }
        )
        defer { session.stop() }
        session.ingestTestingData(Data("\u{1B}]777;notify;Codex;Approval required\u{7}".utf8))
        #expect(session.hasUnreadNotification == (setting == .always), Comment(rawValue: setting.rawValue))
    }
}
