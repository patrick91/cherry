import Foundation
import Testing
@testable import Cherry

// A persistent tab's program reports its status (OSC 7501) as Claude Code
// does: it asks whether the terminal reads reports (`OSC 7501 ; ?`) and
// reports only once that is answered. The holder answers, keeps the
// records and sends them with the session, and the tab's state follows
// them; its surface never answers too. Gated like the other real-host
// suites: CHERRY_TEST_HOST_INTEGRATION=1 and the Rust helpers built
// (Scripts/build-host debug).

private let programStatusRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: programStatusRealHostEnabled))
@MainActor func PersistentLocalRealHostTabFollowsWhatItsProgramReports() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let go = host.root.appendingPathComponent("go")
    let reply = host.root.appendingPathComponent("reply")
    // "approve Bash: ls" and "Writing notes.txt", base64.
    let script = host.root.appendingPathComponent("reports.sh")
    try """
    stty raw -echo
    printf '\\033]7501;?\\033\\\\'
    dd bs=1 count=10 2>/dev/null > '\(reply.path)'
    printf 'ASKED\\r\\n\\033]7501;state=idle:app=fake\\033\\\\'
    while [ ! -e '\(go.path)1' ]; do sleep 0.05; done
    printf '\\033]7501;state=working:app=fake:msg=V3JpdGluZyBub3Rlcy50eHQ=\\033\\\\'
    while [ ! -e '\(go.path)2' ]; do sleep 0.05; done
    printf '\\033]7501;state=blocked:app=fake:kind=permission:msg=YXBwcm92ZSBCYXNoOiBscw==\\033\\\\'
    while [ ! -e '\(go.path)3' ]; do sleep 0.05; done
    printf '\\033]7501;state=done:app=fake\\033\\\\'
    exec sleep 600
    """.write(to: script, atomically: true, encoding: .utf8)
    let tab = workspace.addSession(title: "Status", command: "exec /bin/sh '\(script.path)'")
    do {
        #expect(tab.isPersistentLocalSession)
        host.show(tab)
        try await host.waitFor("the tab to attach to its session") {
            tab.persistentSession != nil && tab.state == .live && !tab.readsContentFromHost
        }
        try await host.waitFor("the program to ask") { host.screen(tab).contains("ASKED") }
        // Answered once, by the holder, with the same body.
        #expect(try Data(contentsOf: reply) == Data("\u{1B}]7501;?\u{1B}\\".utf8))
        try await host.waitFor("its idle report") { tab.agentActivityState == .idle }
        #expect(tab.programStatus == [ProgramStatus(state: .idle, app: "fake")])
        #expect(!host.screen(tab).contains("7501"))

        FileManager.default.createFile(atPath: go.path + "1", contents: nil)
        try await host.waitFor("working") { tab.agentActivityState == .working }
        #expect(tab.programStatus.root?.message == "Writing notes.txt")
        #expect(tab.agentTurnState == .active)

        FileManager.default.createFile(atPath: go.path + "2", contents: nil)
        try await host.waitFor("the permission it waits for") { tab.agentActivityState == .permission }
        #expect(tab.programStatus.root?.message == "approve Bash: ls")
        let sessionID = try #require(tab.persistentSession?.sessionID)
        #expect(try await host.hostSession(sessionID)?.programStatus.root?.kind == .permission)

        FileManager.default.createFile(atPath: go.path + "3", contents: nil)
        try await host.waitFor("done") { tab.agentTurnState == .completed }
        #expect(tab.agentActivityState == .idle)
        #expect(tab.hasUnseenAgentResult)
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

/// A detached tab's program reports on with no client attached: the host
/// still sends its records as they change, and Background Sessions marks
/// the session and posts the wait.
@Test(.enabled(if: programStatusRealHostEnabled))
@MainActor func PersistentLocalRealHostBackgroundSessionFollowsWhatItsProgramReports() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let posted = Recorder<[BackgroundSessionNotificationContent]>([])
    let model = BackgroundSessionsModel(
        localSessions: host.hosting,
        registry: ProjectWindowRegistry(),
        prefersPersistentLocalSessions: { true },
        closesTabsOnCleanExit: { true },
        presentAlert: { _, _, _ in },
        postNotification: { posted.value.append($0) },
        notifiesProgramState: { $0 == .blocked }
    )
    let go = host.root.appendingPathComponent("go")
    let script = host.root.appendingPathComponent("reports.sh")
    try """
    stty raw -echo
    printf '\\033]7501;?\\033\\\\'
    dd bs=1 count=10 2>/dev/null > /dev/null
    printf 'ASKED\\r\\n\\033]7501;state=working:app=fake\\033\\\\'
    while [ ! -e '\(go.path)1' ]; do sleep 0.05; done
    printf '\\033]7501;state=blocked:app=fake:kind=permission:msg=YXBwcm92ZSBCYXNoOiBscw==\\033\\\\'
    while [ ! -e '\(go.path)2' ]; do sleep 0.05; done
    printf '\\033]7501;state=done:app=fake\\033\\\\'
    exec sleep 600
    """.write(to: script, atomically: true, encoding: .utf8)
    let anchor = workspace.addSession(title: "Anchor")
    let tab = workspace.addSession(title: "Status", command: "exec /bin/sh '\(script.path)'")
    do {
        host.show(tab)
        try await host.waitFor("the tab to attach") { tab.persistentSession != nil && tab.state == .live }
        try await host.waitFor("its working report") { tab.agentActivityState == .working }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        // Detached (⌘D): in the background, at work, nothing news yet.
        workspace.close(tab, intent: .userDetachedTab)
        model.start()
        try await host.waitFor("the session in the background") {
            model.sessions.first { $0.id == sessionID }?.programState == .working
        }
        #expect(model.unreadSessionIDs.isEmpty)
        #expect(posted.value.isEmpty)

        FileManager.default.createFile(atPath: go.path + "1", contents: nil)
        try await host.waitFor("the wait to be posted") { posted.value.count == 1 }
        #expect(posted.value.first?.sessionID == sessionID)
        #expect(posted.value.first?.body == "approve Bash: ls")
        #expect(model.unreadSessionIDs == [sessionID])
        try await host.waitFor("its row to say so") {
            model.sessions.first { $0.id == sessionID }?.programState == .blocked
        }

        FileManager.default.createFile(atPath: go.path + "2", contents: nil)
        try await host.waitFor("done") { model.sessions.first { $0.id == sessionID }?.programState == .done }
        #expect(posted.value.count == 1)
        _ = anchor
    } catch {
        model.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    model.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}
