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
// built first. The daemon runs on a private socket with a private HOME, and
// every session and holder it made is removed.

private let realHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
private final class PrivateLocalHost {
    let root: URL
    let home: URL
    let control: HostControl
    let hosting: PersistentLocalSessions
    private let host: Process
    private let socket: URL

    init() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binaries = try #require(
            HostedSessionClient.developmentTargetDirectories(
                environment: ProcessInfo.processInfo.environment, sourceRoot: repository
            ).map { $0.appendingPathComponent("debug") }.first { directory in
                ["cherry", "cherry-host"].allSatisfy {
                    FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
                }
            },
            "Build the Rust helpers first: cargo build --manifest-path Host/Cargo.toml --locked --bins"
        )
        let cliURL = binaries.appendingPathComponent("cherry")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-ai-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socket = root.appendingPathComponent("host.sock")
        // Only the daemon below serves: no helper may start one.
        let helperVariables = [
            "HOME": home.path,
            "CHERRY_HOST_SOCKET": socket.path,
            "CHERRY_HOST_PATH": root.appendingPathComponent("no-auto-start").path
        ]
        var daemonEnvironment = HostedSessionLoginEnvironment.helperEnvironment(
            base: ProcessInfo.processInfo.environment, login: helperVariables
        )
        daemonEnvironment["XDG_STATE_HOME"] = nil
        host = Process()
        host.executableURL = binaries.appendingPathComponent("cherry-host")
        host.arguments = ["serve"]
        host.environment = daemonEnvironment
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.standardError
        try host.run()

        control = HostControl(
            host: .local,
            clientProvider: {
                HostedSessionClient(executableURL: cliURL, loginEnvironment: { _ in .init(environment: helperVariables) })
            },
            hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: "CherryTests.AgentInput.\(UUID().uuidString)"))),
            masters: disabledSSHMasters,
            localHostUnavailableReason: nil
        )
        let control = control
        let home = home
        let stager = GhosttyResourceStager(
            source: { GhosttyResourceStaging.bundledSource() },
            baseDirectory: root.appendingPathComponent("GhosttyResources", isDirectory: true)
        )
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["HOME"] = home.path
        let sessionEnvironment = processEnvironment
        hosting = PersistentLocalSessions(
            owner: "CherryTests",
            control: { control },
            installationUnavailableReason: { nil },
            launchSpec: { configuration, loginEnvironment in
                let shell = ShellProcessController.Configuration(
                    shellPath: "/bin/bash",
                    workingDirectory: configuration.workingDirectory,
                    projectRoot: configuration.projectRoot,
                    processID: configuration.processID,
                    agentID: configuration.agentID,
                    environment: configuration.environment,
                    term: configuration.term,
                    initialSize: configuration.initialSize,
                    startupCommand: configuration.startupCommand
                )
                return await HostedLaunchSpec.prepare(
                    for: shell,
                    loginEnvironment: loginEnvironment,
                    cursorBlink: false,
                    processEnvironment: sessionEnvironment,
                    executableDirectory: nil,
                    homeDirectory: home,
                    stager: stager
                )
            },
            status: PersistentSessionsStatus(),
            configuration: PersistentLocalSessions.Configuration()
        )
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: socket.path))
    }

    var policy: SessionBackendPolicy {
        SessionBackendPolicy(settings: { .defaults }, localSessions: hosting)
    }

    func waitFor(_ description: String, timeout: TimeInterval = 15, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HostedSessionError.message("Timed out waiting for \(description)")
    }

    /// Ends every session this host has, then the daemon, and any holder
    /// left for this socket.
    func tearDown() async {
        if let sessions = try? await control.list().sessions {
            for session in sessions where session.isRunning {
                try? await control.terminate(session.id)
            }
            for session in sessions {
                _ = try? await control.waitForSession(session.id, timeout: .seconds(10)) { $0.map { !$0.isRunning } ?? true }
                try? await control.remove(session.id)
            }
        }
        control.disconnect()
        if host.isRunning { host.terminate() }
        host.waitUntilExit()
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", "hold --socket \(socket.path)"]
        try? pkill.run()
        pkill.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(.enabled(if: realHostEnabled))
@MainActor func AgentInputRealHostRestoredAgentsPermissionPromptIsNeverAnswered() async throws {
    let host = try await PrivateLocalHost()
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let received = host.root.appendingPathComponent("received.log")
    // A stand-in for Claude Code at a Bash permission prompt: it logs every
    // byte it reads, in hex.
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

        // Relaunch: the tab comes back (its adapter left for later, as in a
        // worktree not shown), following the same session.
        let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { _ in host.control })
        let result = await restorer(WorkspaceRestoreRequest(
            repositoryRoot: project.path, worktreeRoot: project.path, records: record.sessions, workspace: second
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
        let status = try await server.process(restored)
        #expect(status.agentActivityState == "permission")
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
