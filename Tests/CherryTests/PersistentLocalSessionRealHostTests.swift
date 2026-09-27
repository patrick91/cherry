import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Local tabs as persistent sessions against a real cherry-host, with the real
// `cherry control` helper, attach adapter and launch spec builder. Gated like
// HostedSessionRealHostSharesNativeGhosttyInputAndReconnectsBothScreens:
// CHERRY_TEST_HOST_INTEGRATION=1 and the Rust helpers built first
// (cargo build --manifest-path Host/Cargo.toml --locked --bins). Each test
// runs its own daemon on a private socket with a private HOME, and removes
// every session and holder it made.

private let realHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
private final class RealLocalHost {
    let root: URL
    let home: URL
    let control: HostControl
    /// Another control connection to the same host, which the tabs never
    /// use: checking the host through it refreshes nothing they read.
    let observer: HostControl
    let hosting: PersistentLocalSessions
    let settings: Box
    private var host: RealHostTestDaemon
    private let daemonExecutable: URL
    private let daemonEnvironment: [String: String]
    private let socket: URL
    private var windows: [NSWindow] = []
    private var containers: [GhosttyTerminalContainerView] = []

    final class Box: @unchecked Sendable {
        var value = SessionPersistenceSettings.defaults
    }

    final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// `shellPath`: the shell tabs run (the user's own startup files are
    /// never read: HOME is private).
    init(
        shellPath: String = "/bin/bash",
        configuration: PersistentLocalSessions.Configuration = PersistentLocalSessions.Configuration()
    ) async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let targetDirectories = HostedSessionClient.developmentTargetDirectories(
            environment: ProcessInfo.processInfo.environment, sourceRoot: repository
        )
        let binaries = try #require(
            targetDirectories.map { $0.appendingPathComponent("debug") }.first { directory in
                ["cherry", "cherry-host"].allSatisfy {
                    FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
                }
            },
            "Build the Rust helpers first: cargo build --manifest-path Host/Cargo.toml --locked --bins"
        )
        let cliURL = binaries.appendingPathComponent("cherry")
        // Private (0700, as the CLI requires) and short enough for a socket.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-pl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socket = root.appendingPathComponent("host.sock")
        // The daemon and every helper get the private HOME and socket; no
        // helper may start a daemon (CHERRY_HOST_PATH names nothing), so only
        // the one below serves. Ghostty runs the attach adapters through
        // login(1), which resets HOME but keeps CHERRY_HOST_SOCKET.
        let helperVariables = [
            "HOME": home.path,
            "CHERRY_HOST_SOCKET": socket.path,
            "CHERRY_HOST_PATH": root.appendingPathComponent("no-auto-start").path
        ]
        var daemonEnvironment = HostedSessionLoginEnvironment.helperEnvironment(
            base: ProcessInfo.processInfo.environment, login: helperVariables
        )
        daemonEnvironment["XDG_STATE_HOME"] = nil
        self.daemonEnvironment = daemonEnvironment
        daemonExecutable = binaries.appendingPathComponent("cherry-host")
        host = try RealHostTestDaemon(executable: daemonExecutable, environment: daemonEnvironment, socket: socket)

        func makeControl() throws -> HostControl {
            HostControl(
                host: .local,
                clientProvider: {
                    HostedSessionClient(executableURL: cliURL, loginEnvironment: { _ in .init(environment: helperVariables) })
                },
                hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: "CherryTests.RealLocal.\(UUID().uuidString)"))),
                masters: disabledSSHMasters,
                localHostUnavailableReason: nil
            )
        }
        control = try makeControl()
        observer = try makeControl()
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
                // The real builder, for `shellPath` with no startup files of
                // the user's; Ghostty resources and the zsh bootstrap are
                // written in the test's directory.
                let shell = ShellProcessController.Configuration(
                    shellPath: shellPath,
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
            configuration: configuration
        )
        settings = Box()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: socket.path))
    }

    /// The daemon crashes (SIGKILL) and a new one starts on the same socket
    /// and state: the sessions' holders keep them running and register again.
    func restartDaemon() async throws {
        host.crash()
        do {
            host = try RealHostTestDaemon(executable: daemonExecutable, environment: daemonEnvironment, socket: socket)
        } catch {
            // No daemon to stop them with the rest: the holders go now.
            RealHostTestDaemon.endHolders(of: socket)
            throw error
        }
    }

    /// A log out: the daemon and every holder are killed (the holders with
    /// SIGKILL, leaving their manifests), then a new daemon starts on the
    /// same socket and state, as at the next login.
    func logOut() throws {
        host.stop()
        host = try RealHostTestDaemon(executable: daemonExecutable, environment: daemonEnvironment, socket: socket)
    }

    var policy: SessionBackendPolicy {
        let settings = settings
        return SessionBackendPolicy(settings: { settings.value }, localSessions: hosting)
    }

    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(projectRoot: home.path, createInitialSession: false, backendPolicy: policy)
    }

    /// Shows `session` in a window, so its surface renders.
    func show(_ session: TerminalSession) {
        let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
        window.orderFrontRegardless()
        windows.append(window)
        containers.append(container)
    }

    func waitFor(_ description: String, timeout: TimeInterval = 15, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HostedSessionError.message("Timed out waiting for \(description)")
    }

    func screen(_ session: TerminalSession) -> String {
        session.ghosttyBridge.readNativeScreenText() ?? ""
    }

    func hostSession(_ id: String) async throws -> HostedSessionInfo? {
        try await control.list().sessions.first { $0.id == id }
    }

    /// The session as the host lists it to `observer`.
    func observedSession(_ id: String) async throws -> HostedSessionInfo? {
        try await observer.list().sessions.first { $0.id == id }
    }

    /// Ends every session this host has, then the daemon; kills any holder
    /// left for this test's socket.
    func tearDown() async {
        for container in containers { container.detachActiveSession() }
        for window in windows { window.close() }
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
        observer.disconnect()
        // The daemon, and any holder this test left (a holder is never the
        // daemon's child).
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostTabShowsItsOutputAndReportsTheExactExitStatus() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        // A terminal tab runs in a host session; typing reaches the shell and
        // its output shows in the tab through the attach adapter.
        let terminal = workspace.addSession(title: "Real")
        #expect(terminal.isPersistentLocalSession)
        host.show(terminal)
        try await host.waitFor("the tab to attach to its session") {
            terminal.persistentSession != nil && terminal.state == .live
        }
        let sessionID = try #require(terminal.persistentSession?.sessionID)
        let info = try #require(try await host.hostSession(sessionID))
        #expect(info.owner == "CherryTests")
        #expect(info.tags[PersistentSessionTag.tab] == terminal.id.uuidString)
        #expect(info.tags[PersistentSessionTag.kind] == "terminal")
        // Launched without login(1): the shell is the session leader.
        #expect(info.command.first == "/bin/bash")
        #expect(terminal.hostedProgramProcessID == info.pid.map { Int32(bitPattern: $0) })
        #expect(terminal.childProcessID == nil)
        terminal.send(text: "echo HOSTED_$((20 + 22)) $CHERRY_PROCESS_ID\n")
        try await host.waitFor("the echo to show in the tab") {
            host.screen(terminal).contains("HOSTED_42 \(terminal.id.uuidString)")
        }
        #expect(terminal.isRunning)
        #expect(!terminal.hasRunningProcess())

        // A command's exit status is exact (login(1) would report 0).
        let failing = workspace.addCommandSession(
            command: ProjectCommandDefinition(name: "fails", command: "/bin/sh", arguments: "-c 'exit 3'"),
            projectRoot: host.home.path
        )
        #expect(failing.isPersistentLocalSession)
        try await host.waitFor("the command to exit") { failing.state == .exited(3) }
        #expect(failing.exitCode == 3)
        let failedSession = try #require(failing.persistentSession?.sessionID)
        let failedInfo = try #require(try await host.hostSession(failedSession))
        #expect(failedInfo.state == .exited)
        #expect(failedInfo.exitCode == 3)
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostClosingEndsTheSessionDetachingKeepsItAndRestartKeepsTheTab() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        let anchor = workspace.addSession(title: "Anchor")
        try await host.waitFor("the anchor tab to attach") { anchor.persistentSession != nil && anchor.state == .live }

        // Closing a tab terminates its session and removes it from the host.
        let closed = workspace.addSession(title: "Closed")
        try await host.waitFor("the tab to attach") { closed.persistentSession != nil && closed.state == .live }
        let closedSession = try #require(closed.persistentSession?.sessionID)
        #expect(try await host.hostSession(closedSession)?.isRunning == true)
        workspace.close(closed)
        try await host.waitFor("the closed tab's session to be gone") {
            try await host.hostSession(closedSession) == nil
        }

        // Detaching a tab (⌘D): the session stays.
        let kept = workspace.addSession(title: "Kept")
        try await host.waitFor("the kept tab to attach") { kept.persistentSession != nil && kept.state == .live }
        let keptSession = try #require(kept.persistentSession?.sessionID)
        workspace.close(kept, intent: .userDetachedTab)
        try await Task.sleep(for: .seconds(1))
        let keptInfo = try #require(try await host.hostSession(keptSession))
        #expect(keptInfo.isRunning)
        #expect(keptInfo.tags[PersistentSessionTag.tab] == kept.id.uuidString)

        // Restart keeps the tab (and its CHERRY_PROCESS_ID) and starts a new
        // session; the old one is gone.
        let restarted = workspace.addSession(title: "Restarted")
        host.show(restarted)
        try await host.waitFor("the tab to attach") { restarted.persistentSession != nil && restarted.state == .live }
        let firstSession = try #require(restarted.persistentSession?.sessionID)
        let tabID = restarted.id
        #expect(workspace.restart(restarted))
        try await host.waitFor("the restarted tab to attach to a new session") {
            (restarted.persistentSession.map { $0.sessionID != firstSession } ?? false) && restarted.state == .live
        }
        #expect(restarted.id == tabID)
        let secondSession = try #require(restarted.persistentSession?.sessionID)
        #expect(try await host.hostSession(firstSession) == nil)
        let secondInfo = try #require(try await host.hostSession(secondSession))
        #expect(secondInfo.isRunning)
        #expect(secondInfo.tags[PersistentSessionTag.tab] == tabID.uuidString)
        restarted.send(text: "echo TAB=$CHERRY_PROCESS_ID\n")
        try await host.waitFor("the restarted shell to report its tab id") {
            host.screen(restarted).contains("TAB=\(tabID.uuidString)")
        }
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostZshCommandReportsTheExactExitStatus() async throws {
    // zsh runs a command through Cherry's bootstrap (CHERRY_STARTUP_COMMAND
    // is eval'd, then `exit $?`): its status must reach the host as is.
    let host = try await RealLocalHost(shellPath: "/bin/zsh")
    let workspace = host.workspace()
    do {
        let failing = workspace.addCommandSession(
            command: ProjectCommandDefinition(name: "fails", command: "/bin/sh", arguments: "-c 'exit 5'"),
            projectRoot: host.home.path
        )
        #expect(failing.isPersistentLocalSession)
        try await host.waitFor("the zsh command to exit") { failing.state == .exited(5) }
        #expect(failing.exitCode == 5)
        let sessionID = try #require(failing.persistentSession?.sessionID)
        let info = try #require(try await host.hostSession(sessionID))
        #expect(info.command.last?.contains("/bin/zsh") == true)
        #expect(info.state == .exited)
        #expect(info.exitCode == 5)

        // A terminal's shell reports its own exit status too.
        let terminal = workspace.addSession(title: "zsh")
        host.show(terminal)
        try await host.waitFor("the zsh tab to attach") { terminal.persistentSession != nil && terminal.state == .live }
        terminal.send(text: "echo ZSH_$((40 + 2))\n")
        try await host.waitFor("zsh to run the echo") { host.screen(terminal).contains("ZSH_42") }
        terminal.send(text: "exit 6\n")
        try await host.waitFor("the zsh tab to exit") { terminal.state == .exited(6) }
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostAShellThatExitsCleanlyClosesItsTabAndLeavesNoSession() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        let anchor = workspace.addSession(title: "anchor")
        let terminal = workspace.addSession(title: "bash")
        host.show(terminal)
        try await host.waitFor("the tabs to attach") {
            [anchor, terminal].allSatisfy { $0.persistentSession != nil && $0.state == .live }
        }
        terminal.send(text: "echo BASH_$((40 + 2))\n")
        try await host.waitFor("bash to run the echo") { host.screen(terminal).contains("BASH_42") }
        let sessionID = try #require(terminal.persistentSession?.sessionID)
        // Past the minimum run time: a shell that ends at once keeps its tab.
        let startedAt = try #require(terminal.programStartedAt)
        let remaining = workspace.backendPolicy.cleanExitMinimumRunTime + 0.2 - Date().timeIntervalSince(startedAt)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }

        terminal.send(text: "exit\n")
        try await host.waitFor("the tab to close") { !workspace.sessions.contains { $0 === terminal } }
        #expect(terminal.state == .exited(0))
        #expect(workspace.sessions.map(\.id) == [anchor.id])
        try await host.waitFor("its session to be removed") { try await host.hostSession(sessionID) == nil }
        #expect(anchor.isRunning)
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostAWaitUnderWayGetsTheLastOutputOfATabThatClosedOnExit() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        let anchor = workspace.addSession(title: "anchor")
        let terminal = workspace.addSession(title: "shell")
        host.show(terminal)
        try await host.waitFor("the tabs to attach") {
            [anchor, terminal].allSatisfy { $0.persistentSession != nil && $0.state == .live }
        }
        terminal.send(text: "echo MARKER_$((40 + 2))\n")
        try await host.waitFor("the shell to run the echo") { host.screen(terminal).contains("MARKER_42") }
        // Past the minimum run time: a shell that ends at once keeps its tab.
        let startedAt = try #require(terminal.programStartedAt)
        let remaining = workspace.backendPolicy.cleanExitMinimumRunTime + 0.2 - Date().timeIntervalSince(startedAt)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }

        // An agent waits on the tab while its shell exits: the tab closes,
        // and the wait still returns what it showed last.
        let waiting = Task { @MainActor in
            try await control.send(.waitForProcessIdle(.init(
                processID: terminal.id.uuidString, requireNewOutput: true,
                quietMilliseconds: 10_000, timeoutMilliseconds: 15_000
            )))
        }
        try await Task.sleep(for: .milliseconds(300))
        terminal.send(text: "exit\n")
        try await host.waitFor("the tab to close") { !workspace.sessions.contains { $0 === terminal } }
        let response = try await waiting.value
        guard case .waitForProcessIdle(let idle)? = response.result else {
            throw HostedSessionError.message("Expected waitForProcessIdle, got \(String(describing: response))")
        }
        #expect(idle.reason == .exited)
        #expect(idle.output.lines.contains { $0.contains("MARKER_42") })
        // The tab itself is gone.
        let status = try await control.send(.getProcessStatus(.init(processID: terminal.id.uuidString)))
        #expect(status.error?.code == "terminal_not_found")
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

// MARK: - Feature parity (docs/specs/multiplexer-default.md, "Feature parity")

/// Ends `tab`'s attach adapter as a lost connection would (its tty session
/// is hung up on), leaving its program running in the host. With a long
/// reconnect delay the tab stays without an attached adapter.
@MainActor
private func loseAdapter(of tab: TerminalSession, host: RealLocalHost) async throws {
    let adapter = try #require(tab.ghosttyBridge.nativeSessionLeaderPID(), "the adapter's tty session")
    ShellProcessController.terminateNativeShellSession(anchorPID: adapter)
    try await host.waitFor("the tab to lose its adapter") { tab.readsContentFromHost && !tab.usesNativePTYBackendAdapterAttached }
    #expect(tab.isRunning)
}

private extension TerminalSession {
    /// The surface runs an attach adapter that has settled (not reconnecting).
    @MainActor var usesNativePTYBackendAdapterAttached: Bool {
        usesNativePTYBackend && !readsContentFromHost
    }
}

@MainActor
private func processOutput(_ control: ParityControlServer, _ tab: TerminalSession) async throws -> [String] {
    let response = try await control.send(.getProcessOutput(.init(processID: tab.id.uuidString, lineLimit: 2_000)))
    guard case .getProcessOutput(let output)? = response.result else {
        throw HostedSessionError.message("Expected getProcessOutput, got \(String(describing: response))")
    }
    return output.lines
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostMCPReachesAnUnattachedProgramAndItsDirectoryFollowsCd() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // Once lost, the adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(shellPath: "/bin/zsh", configuration: configuration)
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        let first = host.home.appendingPathComponent("first", isDirectory: true)
        let second = host.home.appendingPathComponent("second dir", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let tab = workspace.addSession(title: "Unattached")
        #expect(tab.isPersistentLocalSession)
        host.show(tab)
        try await host.waitFor("the tab to attach to its session") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackendAdapterAttached
        }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        let info = try #require(try await host.hostSession(sessionID))
        // MCP names the program's pid (never the adapter's).
        #expect(try await control.process(tab).pid == info.pid.map { Int32(bitPattern: $0) })

        // Attached: `cd` moves the tab (Cherry's zsh integration reports
        // OSC 7, which the adapter passes to the surface).
        tab.send(text: "cd first\n")
        try await host.waitFor("the tab to follow cd") { tab.workingDirectory == first.path }

        // Without an attached adapter, MCP input reaches the program through
        // the host, and output is the host's screen.
        try await loseAdapter(of: tab, host: host)
        let sent = try await control.send(.sendProcessInput(.init(
            processID: tab.id.uuidString, text: "echo UNATTACHED_$((6 * 7))\n"
        )))
        guard case .sendProcessInput(let sentResult)? = sent.result else {
            Issue.record("Expected sendProcessInput, got \(String(describing: sent))")
            throw HostedSessionError.message("send_process_input failed")
        }
        #expect(sentResult.sentBytes > 0)
        try await host.waitFor("the output to show in the host's screen") {
            try await processOutput(control, tab).contains { $0.contains("UNATTACHED_42") }
        }
        #expect(tab.readsContentFromHost)
        let status = try await control.process(tab)
        #expect(status.state == "live")
        #expect(status.acceptsInput)

        // `cd` still moves the tab, through the host's reports.
        _ = try await control.send(.sendProcessInput(.init(processID: tab.id.uuidString, text: "cd '../second dir'\n")))
        try await host.waitFor("the tab to follow cd without an adapter") { tab.workingDirectory == second.path }
        // A new tab starts there.
        let next = workspace.addSession(title: "Next")
        try await host.waitFor("the next tab to attach") { next.persistentSession != nil && next.state == .live }
        let nextSessionID = try #require(next.persistentSession?.sessionID)
        let nextInfo = try #require(try await host.hostSession(nextSessionID))
        let resolved = try #require(second.path.withCString { realpath($0, nil) })
        let resolvedSecond = String(cString: resolved)
        free(resolved)
        #expect(nextInfo.cwd == resolvedSecond)
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostReportsBracketedPasteAndClearsItsHistoryOnClearScrollback() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // Once lost, the adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(configuration: configuration)
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        let tab = workspace.addSession(title: "Paste")
        host.show(tab)
        try await host.waitFor("the tab to attach to its session") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackendAdapterAttached
        }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        #expect(try await host.hostSession(sessionID)?.bracketedPaste != nil)

        // A program that turns bracketed paste on, waits, turns it off.
        // (A marker computed by the shell, so the typed line does not show it.)
        tab.send(text: "seq 1 300 | sed 's/^/HISTORY_/'; printf '\\033[?2004h'; echo MODE_$((1+1))ON; read -r a; "
            + "printf '\\033[?2004l'; echo MODE_$((1+1))OFF; read -r b; echo PASTE_$((1+1))DONE\n")
        try await host.waitFor("the program to turn bracketed paste on") {
            try await processOutput(control, tab).contains("MODE_2ON")
        }
        try await host.waitFor("the host to report bracketed paste on") {
            try await host.observedSession(sessionID)?.bracketedPaste == true
        }
        try await host.waitFor("the tab to follow the host's report") { tab.usesBracketedPasteMode }
        #expect(tab.bracketsPaste("one\ntwo\n"))
        tab.send(text: "\n")
        try await host.waitFor("the program to turn bracketed paste off") {
            try await processOutput(control, tab).contains("MODE_2OFF")
        }
        try await host.waitFor("the host to report bracketed paste off") {
            try await host.observedSession(sessionID)?.bracketedPaste == false
        }
        try await host.waitFor("the tab to follow the host's report") { !tab.usesBracketedPasteMode }
        #expect(!tab.bracketsPaste("one\ntwo\n"))

        // Without an adapter, output comes from the host, history first.
        try await loseAdapter(of: tab, host: host)
        try await host.waitFor("the history through the host") {
            try await processOutput(control, tab).contains("HISTORY_1")
        }
        // Clear Scrollback clears the host's copy too: MCP no longer
        // reads it, and neither would the next adapter.
        await tab.clearScrollback()?.value
        let screen = try await host.hosting.screen(of: try #require(tab.persistentSession))
        #expect(!screen.text.contains("HISTORY_1\n"), Comment(rawValue: screen.text))
        #expect(screen.text.contains("MODE_2OFF"), Comment(rawValue: screen.text))
        let lines = try await processOutput(control, tab)
        #expect(!lines.contains("HISTORY_1"), Comment(rawValue: lines.joined(separator: "\n")))
        tab.send(text: "\n")
        try await host.waitFor("the program to go on") {
            try await processOutput(control, tab).contains("PASTE_2DONE")
        }
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostCursorKeysReachAnUnattachedProgramInItsCursorKeyMode() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // Once lost, the adapter stays lost for the test.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(configuration: configuration)
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        let tab = workspace.addSession(title: "Keys")
        host.show(tab)
        try await host.waitFor("the tab to attach to its session") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackendAdapterAttached
        }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        #expect(try await host.hostSession(sessionID)?.applicationCursorKeys == false)

        // A program that turns on application cursor keys (as `less` does)
        // and prints the key it reads, then turns them off and reads again.
        tab.send(text: #"printf '\033[?1h'; IFS= read -rsn3 k; echo "KEY_${k:1}_"; "#
            + #"printf '\033[?1l'; IFS= read -rsn3 k; echo "KEY_${k:1}_""# + "\n")
        try await host.waitFor("the host to report application cursor keys") { tab.usesApplicationCursorKeys }
        #expect(try await host.observedSession(sessionID)?.applicationCursorKeys == true)

        // No adapter takes the keys: the host types Down, sent as a
        // normal-mode `ESC [ B`, in the form the program's mode takes.
        try await loseAdapter(of: tab, host: host)
        let down = try await control.send(.sendProcessInput(.init(
            processID: tab.id.uuidString, rawBase64: Data("\u{1B}[B".utf8).base64EncodedString()
        )))
        #expect(down.error == nil)
        try await host.waitFor("the program to read ESC O B") {
            try await processOutput(control, tab).contains { $0.contains("KEY_OB_") }
        }
        // The mode is off again: `ESC O A` arrives as `ESC [ A`.
        try await host.waitFor("the host to report the mode off") { !tab.usesApplicationCursorKeys }
        let up = try await control.send(.sendProcessInput(.init(
            processID: tab.id.uuidString, rawBase64: Data("\u{1B}OA".utf8).base64EncodedString()
        )))
        #expect(up.error == nil)
        try await host.waitFor("the program to read ESC [ A") {
            try await processOutput(control, tab).contains { $0.contains("KEY_[A_") }
        }
        #expect(try await processOutput(control, tab).contains { $0.contains("KEY_[B_") || $0.contains("KEY_OA_") } == false)
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
@MainActor func PersistentLocalRealHostFindsAHostedServersPortByItsProgramPid() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace, serviceDetector: MacOSServiceDetector())
    do {
        let server = workspace.addCommandSession(
            command: ProjectCommandDefinition(
                name: "web", command: "/usr/bin/python3", arguments: "-u -m http.server 0 --bind 127.0.0.1"
            ),
            projectRoot: host.home.path
        )
        #expect(server.isPersistentLocalSession)
        try await host.waitFor("the server's session") { server.persistentSession != nil && server.programProcessID != nil }
        #expect(server.childProcessID == nil)

        // The listener belongs to the hosted program, which is the host's
        // child: only the pid the host reported finds it.
        let bound = try await control.send(.waitForBoundPort(.init(
            processID: server.id.uuidString, timeoutMilliseconds: 30_000
        )))
        guard case .waitForBoundPort(let result)? = bound.result else {
            Issue.record("Expected waitForBoundPort, got \(String(describing: bound))")
            throw HostedSessionError.message("wait_for_bound_port failed")
        }
        #expect(result.service.processID == server.id.uuidString)
        #expect(result.service.attribution == .processTree)
        #expect(result.service.port > 0)
        // The port the server printed.
        try await host.waitFor("the server to print its port") {
            try await processOutput(control, server).contains { $0.contains("port \(result.service.port)") }
        }
        let ports = try await control.send(.getProcessPorts(.init(processID: server.id.uuidString)))
        guard case .getProcessPorts(let services)? = ports.result else {
            Issue.record("Expected getProcessPorts, got \(String(describing: ports))")
            throw HostedSessionError.message("get_process_ports failed")
        }
        #expect(services.services.map(\.port).contains(result.service.port))
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostNotificationsReachBackgroundAndUnattachedTabsOnce() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(configuration: configuration)
    let workspace = host.workspace()
    do {
        // A background tab: its adapter runs, but no window shows it.
        let tab = workspace.addSession(title: "Background")
        let bells = RealLocalHost.Counter()
        tab.bellHandler = { _ in bells.value += 1 }
        try await host.waitFor("the tab to attach") {
            tab.persistentSession != nil && tab.usesNativePTYBackendAdapterAttached
        }
        // The adapter passes the notification and bell to the surface; the
        // host's copies are not shown again.
        tab.send(text: "printf '\\033]9;Background done\\007'; printf '\\007'\n")
        try await host.waitFor("the background notification") { tab.hasUnreadNotification && bells.value == 1 }
        #expect(tab.lastNotification?.body == "Background done")
        tab.clearUnreadNotification()
        try await Task.sleep(for: .seconds(1))
        #expect(!tab.hasUnreadNotification)
        #expect(bells.value == 1)

        // Without an attached adapter, the host's are shown, with progress.
        try await loseAdapter(of: tab, host: host)
        try await tab.sendControlInput(
            Data("printf '\\033]777;notify;Tests;passed\\007'; printf '\\033]9;4;1;60\\007'; printf '\\007'\n".utf8),
            raw: false
        )
        try await host.waitFor("the host's notification") { tab.hasUnreadNotification && bells.value == 2 }
        #expect(tab.lastNotification == TerminalNotificationRequest(title: "Tests", body: "passed", source: .osc777))
        try await host.waitFor("the host's progress") {
            tab.progressReport == TerminalProgressReport(state: .set, value: 60)
        }
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostReportsTheAdapterAttachedAndEarlyMCPInputArrives() async throws {
    // Only the adapter's own report (its live status) confirms the attach.
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        // MCP input sent as soon as the tab exists waits for its session,
        // goes through the host, and says it arrived.
        let tab = workspace.addSession(title: "Early")
        #expect(tab.isStartingPersistentSession)
        let sent = try await control.send(.sendProcessInput(.init(
            processID: tab.id.uuidString, text: "echo EARLY_$((40 + 2))\n"
        )))
        guard case .sendProcessInput(let sentResult)? = sent.result else {
            Issue.record("Expected sendProcessInput, got \(String(describing: sent))")
            throw HostedSessionError.message("send_process_input failed")
        }
        #expect(sentResult.sentBytes > 0)
        host.show(tab)
        // The adapter reports its attach in its status file (and the host
        // lists it as a client).
        try await host.waitFor("the adapter to report itself attached") { tab.usesNativePTYBackendAdapterAttached }
        #expect(tab.adapterLiveStatus == HostedAdapterLiveStatus())
        let sessionID = try #require(tab.persistentSession?.sessionID)
        #expect(try await host.hostSession(sessionID)?.clients == 1)
        try await host.waitFor("the early input's output") { host.screen(tab).contains("EARLY_42") }
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

// MARK: - Restore (docs/specs/multiplexer-default.md, "Relaunch")

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostTabsComeBackFromTheSavedStateAfterAQuit() async throws {
    let host = try await RealLocalHost()
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStateStore(directory: host.root.appendingPathComponent("Workspaces", isDirectory: true))
    let control = host.control
    let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { host in
        Issue.record("No saved tab names \(host.displayName)")
        return control
    })
    var repositories: [RepositoryWorkspace] = []
    func makeRepository() -> RepositoryWorkspace {
        let repository = RepositoryWorkspace(
            projectRoot: project.path,
            backendPolicy: host.policy,
            stateStore: store,
            sessionRestorer: restorer,
            autoStartCommands: { _ in [] }
        )
        repositories.append(repository)
        return repository
    }
    func tearDown() async {
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await host.tearDown()
    }
    do {
        // A window with a terminal (its default shell) and a command, both
        // persistent sessions that print something.
        let first = makeRepository()
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let workspace = first.activeWorkspace
        let terminal = try #require(workspace.sessions.first)
        #expect(terminal.isPersistentLocalSession)
        host.show(terminal)
        try await host.waitFor("the terminal to attach") { terminal.persistentSession != nil && terminal.state == .live }
        terminal.send(text: "echo TERMINAL_$((6 * 7))\n")
        try await host.waitFor("the terminal's output") { host.screen(terminal).contains("TERMINAL_42") }
        let command = workspace.addCommandSession(
            command: ProjectCommandDefinition(name: "ticker", command: "/bin/sh", arguments: "-c 'echo COMMAND_$((40 + 2)); exec sleep 600'"),
            projectRoot: project.path,
            select: false
        )
        #expect(command.isPersistentLocalSession)
        host.show(command)
        try await host.waitFor("the command's output") { host.screen(command).contains("COMMAND_42") }
        let terminalSession = try #require(terminal.persistentSession?.sessionID)
        let commandSession = try #require(command.persistentSession?.sessionID)

        // Quit: the state is saved first, then the tabs detach; their
        // sessions keep running on the host.
        first.flushPersistentState()
        first.closeAllSessions(intent: .appQuit)
        #expect(workspace.sessions.isEmpty)
        #expect(try await host.hostSession(terminalSession)?.isRunning == true)
        #expect(try await host.hostSession(commandSession)?.isRunning == true)
        let saved = try #require(store.load(repositoryRoot: first.repositoryRoot)?.worktree(root: first.initialWorktreeRoot))
        #expect(saved.sessions.map(\.id) == [terminal.id, command.id])

        // Relaunch: a new window from the same saved state brings both tabs
        // back with their ids, kinds and sessions, showing their screens.
        let second = makeRepository()
        second.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await second.waitForPendingRestores()
        let restored = second.activeWorkspace
        #expect(restored.sessions.map(\.id) == [terminal.id, command.id])
        #expect(restored.sessions.map(\.kind) == [.terminal, .command])
        let restoredTerminal = try #require(restored.session(withID: terminal.id))
        let restoredCommand = try #require(restored.session(withID: command.id))
        #expect(restoredTerminal.isPersistentLocalSession)
        #expect(restoredCommand.isPersistentLocalSession)
        #expect(restoredTerminal.persistentSession?.sessionID == terminalSession)
        #expect(restoredCommand.persistentSession?.sessionID == commandSession)
        #expect(restored.commandSession(named: "ticker") === restoredCommand)
        #expect(restoredCommand.isRunning)
        // The command's screen, read from its host before or after its
        // adapter attached.
        await restoredCommand.refreshContentFromHostIfNeeded()
        if restoredCommand.readsContentFromHost {
            #expect(restoredCommand.snapshot(range: 0..<restoredCommand.lineCount).contains { $0.contains("COMMAND_42") })
        }
        host.show(restoredCommand)
        try await host.waitFor("the restored command's screen") { host.screen(restoredCommand).contains("COMMAND_42") }
        host.show(restoredTerminal)
        try await host.waitFor("the restored terminal's screen") { host.screen(restoredTerminal).contains("TERMINAL_42") }
        restoredTerminal.send(text: "echo AGAIN_$((1 + 1)) $CHERRY_PROCESS_ID\n")
        try await host.waitFor("the restored terminal to take input") {
            host.screen(restoredTerminal).contains("AGAIN_2 \(terminal.id.uuidString)")
        }
        #expect(try await host.control.list().sessions.count == 2)

        // Closing the restored tabs ends their sessions on the host.
        restored.close(restoredCommand)
        restored.close(restoredTerminal, allowEmptyWorkspace: true)
        try await host.waitFor("both sessions to be gone") {
            let sessions = try await host.control.list().sessions.map(\.id)
            return !sessions.contains(terminalSession) && !sessions.contains(commandSession)
        }
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostTabsALogOutEndedComeBackEndedAndRestart() async throws {
    let host = try await RealLocalHost()
    let project = host.home.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStateStore(directory: host.root.appendingPathComponent("Workspaces", isDirectory: true))
    let control = host.control
    let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: host.hosting, control: { host in
        Issue.record("No saved tab names \(host.displayName)")
        return control
    })
    var repositories: [RepositoryWorkspace] = []
    func makeRepository() -> RepositoryWorkspace {
        let repository = RepositoryWorkspace(
            projectRoot: project.path,
            backendPolicy: host.policy,
            stateStore: store,
            sessionRestorer: restorer,
            autoStartCommands: { _ in [] }
        )
        repositories.append(repository)
        return repository
    }
    func tearDown() async {
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await host.tearDown()
    }
    do {
        // A window with its default shell, and a second tab whose session
        // is ended on purpose (Kill, Remove) after the state named it; the
        // app records what it ends.
        host.hosting.endedSessionsStore = store
        let first = makeRepository()
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let workspace = first.activeWorkspace
        let terminal = try #require(workspace.sessions.first)
        let ended = workspace.addSession(title: "Ended")
        try await host.waitFor("both sessions") { terminal.persistentSession != nil && ended.persistentSession != nil }
        let terminalSession = try #require(terminal.persistentSession?.sessionID)
        let endedSession = try #require(ended.persistentSession?.sessionID)
        first.flushPersistentState()
        let savedState = try #require(store.load(repositoryRoot: first.repositoryRoot))
        workspace.close(ended)
        try await host.waitFor("the ended session to go") {
            try await !host.control.list().sessions.contains { $0.id == endedSession }
        }
        // Cherry quits keeping its sessions; the state it saved still names
        // both tabs. Then the user logs out, killing every holder.
        first.closeAllSessions(intent: .appQuit)
        store.saveSynchronously(savedState)
        try host.logOut()
        // Cherry had quit for the log out too (rule 2): the evidence holds
        // for every saved tab, and the one ended on purpose still stays
        // dropped.
        store.noteSystemQuit()

        // The next login: the host reports the killed holder's session lost
        // (not the one ended on purpose), and its tab comes back ended, in
        // place of a new shell.
        try await host.waitFor("the new daemon to list") {
            // The connection to the killed daemon fails first.
            guard let list = try? await host.control.list() else { return false }
            return list.isComplete && list.lostSessionIDs == [terminalSession]
        }
        let second = makeRepository()
        let chromeState = ProjectWindowChromeState(toasts: ProjectWindowToasts(
            schedule: { _, _ in }, announce: { _ in }, voiceOverEnabled: { false }
        ))
        second.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
        await second.waitForPendingRestores()
        let restored = second.activeWorkspace
        #expect(restored.sessions.map(\.id) == [terminal.id])
        #expect(restored.session(withID: ended.id) == nil)
        #expect(store.wasEndedOnPurpose(try #require(savedState.worktree(root: first.initialWorktreeRoot)?.sessions.first { $0.id == ended.id })))
        let back = try #require(restored.session(withID: terminal.id))
        #expect(back.systemSessionEnd == .logout)
        #expect(back.persistentSessionEndedMessage == "Ended when you logged out")
        #expect(chromeState.toasts.current?.title == "1 tab ended when you logged out")

        // Restart: a new session for the same tab, in its directory.
        #expect(restored.restart(back))
        host.show(back)
        try await host.waitFor("the restarted tab to attach") { back.persistentSession != nil && back.state == .live }
        #expect(back.persistentSession?.sessionID != terminalSession)
        #expect(back.systemSessionEnd == nil)
        back.send(text: "echo BACK_$((6 * 7)) $CHERRY_PROCESS_ID\n")
        try await host.waitFor("the restarted tab's output") {
            host.screen(back).contains("BACK_42 \(terminal.id.uuidString)")
        }
    } catch {
        await tearDown()
        throw error
    }
    await tearDown()
}

// MARK: - A daemon restart (docs/specs/multiplexer-default.md, "Host architecture")

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostAdapterRidesOutADaemonRestartWithoutANewSurface() async throws {
    var configuration = PersistentLocalSessions.Configuration()
    // A relaunch would show here: the tab never launches a second adapter.
    configuration.reconnectDelay = (120, 120)
    let host = try await RealLocalHost(configuration: configuration)
    let workspace = host.workspace()
    let control = try ParityControlServer(workspace: workspace)
    do {
        let tab = workspace.addSession(title: "Survivor")
        host.show(tab)
        try await host.waitFor("the tab to attach") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackendAdapterAttached
        }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        let adapter = try #require(tab.ghosttyBridge.nativeSessionLeaderPID())
        let launch = tab.nativeExecLaunch.command
        tab.send(text: "echo BEFORE_$((20 + 22))\n")
        try await host.waitFor("the output before the restart") { host.screen(tab).contains("BEFORE_42") }

        try await host.restartDaemon()
        // The adapter reconnects by itself: same adapter, same surface, the
        // program still runs, and nothing is relaunched.
        try await host.waitFor("the adapter to reconnect by itself", timeout: 40) {
            guard tab.adapterLiveStatus == HostedAdapterLiveStatus() else { return false }
            // The control connection reconnects meanwhile.
            let info = try? await host.hostSession(sessionID)
            return info?.clients == 1
        }
        #expect(tab.ghosttyBridge.nativeSessionLeaderPID() == adapter)
        #expect(tab.nativeExecLaunch.command == launch)
        #expect(tab.isRunning)
        #expect(tab.persistentSession?.sessionID == sessionID)
        tab.send(text: "echo AFTER_$((40 + 2))\n")
        try await host.waitFor("the output after the restart") { host.screen(tab).contains("AFTER_42") }
        #expect(host.screen(tab).contains("BEFORE_42"))
        #expect(try await host.control.list().sessions.map(\.id) == [sessionID])
        // MCP's idle wait reads the recent screen from the host when needed,
        // and finds the program idle.
        let waited = try await control.send(.waitForProcessIdle(.init(
            processID: tab.id.uuidString, requireNewOutput: false, quietMilliseconds: 500, timeoutMilliseconds: 10_000
        )))
        guard case .waitForProcessIdle(let idle)? = waited.result else {
            Issue.record("Expected waitForProcessIdle, got \(String(describing: waited))")
            throw HostedSessionError.message("wait_for_process_idle failed")
        }
        #expect(idle.reason == .idle)
    } catch {
        control.stop()
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    control.stop()
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostReportsModesRequestIDsCompleteListsAndRecentLines() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    do {
        let tab = workspace.addSession(title: "Modes")
        host.show(tab)
        try await host.waitFor("the tab to attach") {
            tab.persistentSession != nil && tab.state == .live && tab.usesNativePTYBackendAdapterAttached
        }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        // The Create that started it, as the tab saved it.
        let listed = try #require(try await host.hostSession(sessionID))
        #expect(listed.requestID == tab.persistentLaunchRequestID)
        #expect(listed.alternateScreen == false)
        #expect(listed.kittyKeyboardFlags == 0)
        #expect(try await host.control.list().pendingHolders == 0)

        // A program that enters the alternate screen and pushes kitty
        // keyboard flags: the host reports both, and the tab takes them
        // from its events alone (nothing lists its control connection
        // meanwhile; the host is checked through another one).
        tab.send(text: "printf '\\033[?1049h\\033[>1u'; echo MODES_ON\n")
        try await host.waitFor("the tab to take the modes from the host's events") {
            tab.usesAlternateScreen && tab.keyboardProtocolFlags == 1
        }
        let on = try #require(try await host.observedSession(sessionID))
        #expect(on.alternateScreen == true && on.kittyKeyboardFlags == 1)
        tab.send(text: "printf '\\033[<u\\033[?1049l'\n")
        try await host.waitFor("the tab to see them gone from the host's events") {
            !tab.usesAlternateScreen && tab.keyboardProtocolFlags == 0
        }
        let off = try #require(try await host.observedSession(sessionID))
        #expect(off.alternateScreen == false && off.kittyKeyboardFlags == 0)

        // Only the last lines of the history, when asked.
        tab.send(text: "for i in 1 2 3 4 5 6; do echo LINE_$i; done\n")
        try await host.waitFor("the lines to print") { host.screen(tab).contains("LINE_6") }
        let recent = try await host.control.screen(sessionID, scrollback: true, maxLines: 3)
        #expect(recent.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 3)
        let whole = try await host.control.screen(sessionID, scrollback: true)
        #expect(whole.text.contains("LINE_1"))
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await host.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosed)
    await host.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func PersistentLocalRealHostDetachedTabIsInTheBackgroundAndEndingItLeavesNothingOnTheHost() async throws {
    let host = try await RealLocalHost()
    let workspace = host.workspace()
    let model = BackgroundSessionsModel(
        localSessions: host.hosting, registry: ProjectWindowRegistry(), presentAlert: { _, _, _ in }
    )
    do {
        let anchor = workspace.addSession(title: "Anchor")
        try await host.waitFor("the anchor tab to attach") { anchor.persistentSession != nil && anchor.state == .live }
        model.refresh()
        #expect(model.sessions.isEmpty)

        // A detached tab (⌘D): its session runs on in the background.
        let kept = workspace.addSession(title: "Kept")
        try await host.waitFor("the kept tab to attach") { kept.persistentSession != nil && kept.state == .live }
        let keptSession = try #require(kept.persistentSession?.sessionID)
        workspace.close(kept, intent: .userDetachedTab)
        try await host.waitFor("the kept session to be in the background") {
            model.refresh()
            return model.sessions.map(\.id) == [keptSession]
        }
        let item = try #require(model.sessions.first)
        #expect(item.title == "Kept")
        #expect(item.isRunning)
        #expect(item.projectRoot != nil)

        // End: the host kills it and removes it; nothing is left of it.
        let ending = try #require(model.end(item))
        #expect(model.sessions.isEmpty)
        await ending.value
        #expect(try await host.hostSession(keptSession) == nil)
        model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(try await host.hostSession(try #require(anchor.persistentSession?.sessionID))?.isRunning == true)
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
