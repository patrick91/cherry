import AppKit
import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// The restored agent at a permission prompt (AgentInputSafetyTests) against a
// real cherry-host: a program in a real hosted session shows a Claude-style
// permission prompt, Cherry "quits" (its tabs detach) and a new window
// restores the tab, and MCP input must not reach the program. Gated like the
// other real-host tests: CHERRY_TEST_HOST_INTEGRATION=1 and the Rust helpers
// built first. The daemon (RealLocalHost) runs on a private socket with a
// private HOME, and every session and holder it made is removed.

private let realHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@Test(.enabled(if: realHostEnabled))
@MainActor func AgentInputRealHostRestoredAgentsPermissionPromptIsNeverAnswered() async throws {
    let host = try await RealLocalHost()
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let received = host.root.appendingPathComponent("received.log")
    // A stand-in for Claude Code at a Bash permission prompt, which it also
    // reports (OSC 7501, "approve Bash: rm -rf build", as Claude Code
    // 2.1.295 does): it logs every byte it reads, in hex.
    let script = host.root.appendingPathComponent("claude")
    try """
        #!/bin/bash
        printf '● Bash(rm -rf build)\\n\\n'
        printf '╭──────────────────────────────────────────────╮\\n'
        printf '│ Bash command                                 │\\n'
        printf '│   rm -rf build                               │\\n'
        printf '│ Do you want to proceed?                      │\\n'
        printf '│ ❯ 1. Yes                                     │\\n'
        printf "│   2. Yes, and don't ask again for rm commands│\\n"
        printf '│   3. No, and tell Claude what to do differently (esc) │\\n'
        printf '╰──────────────────────────────────────────────╯\\n'
        printf '\\033]7501;state=blocked:app=claude-code:kind=permission:msg=YXBwcm92ZSBCYXNoOiBybSAtcmYgYnVpbGQ=\\033\\\\'
        stty raw -echo
        exec /usr/bin/perl -e 'use IO::Handle; open(my $log, ">>", $ARGV[0]) or die; $log->autoflush(1); my $c; while (sysread(STDIN, $c, 1)) { printf $log "%02x ", ord($c); }' '\(received.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try Data().write(to: received)
    let agentTool = AgentToolDefinition(name: "Claude", command: script.path)

    let first = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, backendPolicy: host.policy)
    let second = TerminalWorkspace(projectRoot: project.path, createInitialSession: false, backendPolicy: host.policy)
    var control: ParityControlServer?
    func tearDown() async {
        control?.stop()
        first.closeAllSessions(intent: .windowClosed)
        second.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
    }
    do {
        let agent = first.addAgentSession(agent: agentTool, projectRoot: project.path)
        try await host.waitFor("the agent's session") { agent.persistentSession != nil && agent.isRunning }
        let sessionID = try #require(agent.persistentSession?.sessionID)
        try await host.waitFor("the permission prompt") {
            (try? await host.control.screen(sessionID, scrollback: true))?.text.contains("what to do differently") == true
        }

        // Cherry quits: the tab is saved, then detaches; the agent keeps
        // waiting for its answer on the host.
        let record = first.makeStateRecord(root: project.path, collapsedAgentGroupIDs: [])
        first.closeAllSessions(intent: .appQuit)
        #expect(try await host.control.list().sessions.first { $0.id == sessionID }?.isRunning == true)

        // Relaunch: the tab comes back (its adapter left for later, as for
        // a tab not shown yet), following the same session.
        let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { _ in host.control })
        let result = await restorer(WorkspaceRestoreRequest(
            repositoryRoot: project.path, records: record.sessions, workspace: second
        ))
        second.restoreSessions(result.sessions, from: record, launchingAdapters: false)
        let restored = try #require(second.session(withID: agent.id))
        #expect(restored.kind == .agent)
        #expect(restored.persistentSession?.sessionID == sessionID)
        #expect(!restored.startedCurrentProgram)

        // The orchestrator: the agent waits for permission, and a message
        // is refused with nothing typed (above all no Enter).
        let server = try ParityControlServer(workspace: second)
        control = server
        // Its host kept what it reported.
        let status = try await server.process(restored)
        #expect(status.agentActivityState == "permission")
        #expect(status.programStatus?.message == "approve Bash: rm -rf build")
        let sent = try await server.send(.sendProcessInput(.init(
            processID: restored.id.uuidString, text: "also run the tests", submit: true
        )))
        #expect(sent.error?.code == "agent_awaiting_permission")
        try await Task.sleep(for: .milliseconds(1_500))
        #expect((try? String(contentsOf: received, encoding: .utf8)) == "")

        // Keys sent on purpose (Esc: "No") reach it.
        let answered = try await server.send(.sendProcessInput(.init(
            processID: restored.id.uuidString, rawBase64: Data([0x1B]).base64EncodedString()
        )))
        #expect(answered.error == nil)
        try await host.waitFor("the agent to read the Esc") {
            (try? String(contentsOf: received, encoding: .utf8)) == "1b "
        }
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}
