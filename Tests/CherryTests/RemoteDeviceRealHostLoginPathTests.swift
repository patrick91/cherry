import CherryControl
import Foundation
import Testing
@testable import Cherry

// A device's login PATH end to end (docs/specs/remote-devices.md, "Login
// PATH on devices") against a fake remote Mac (Scripts/fake-remote-mac)
// whose login shell is zsh (its `shell` switch) and whose ~/.zshrc alone
// puts a tool on PATH, as bun, Claude Code and pi put themselves there: a
// login shell that is not interactive (`zsh -l -c`, what a command or agent
// runs) does not find it. The app reads that Mac's interactive PATH through
// the shim and gives it to the device's commands and agents. Gated like the
// other real-host suites (CHERRY_TEST_HOST_INTEGRATION=1, Scripts/build-host
// debug); no real ssh runs.

private let loginPathRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
private func loginPathStore(for mac: FakeRemoteMac, directory: URL) -> RemoteDeviceStore {
    RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: mac.hostStore,
        installationID: { mac.installationID },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: HostedRemoteHostPaths(),
        makeHosting: { profile, installation in
            let control = mac.makeControl()
            return PersistentHostSessions.remote(
                profile: profile, installationID: installation,
                control: { control }, installationUnavailableReason: { nil },
                status: PersistentSessionsStatus(), instanceLock: nil, terminalColors: { nil },
                configuration: FakeRemoteMac.fastConfiguration
            )
        },
        // Read over the fake Mac's ssh shim, as the app reads it over the
        // device's master.
        captureLoginEnvironment: { device in
            await RemoteLoginEnvironmentCapture.run(on: device.sshDestination, loginShell: device.shell, shell: mac.shell)
        }
    )
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test(.enabled(if: loginPathRealHostEnabled))
@MainActor func RemoteDeviceRealHostLoginPathLetsAgentsAndCommandsFindToolsOnlyTheRcFileAdds() async throws {
    let mac = try FakeRemoteMac(name: "rcpath")
    let directory = try temporaryDirectory("cherry-rd-path")
    let fallbackDirectory = try temporaryDirectory("cherry-rd-path-fallback")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: fallbackDirectory)
    }
    var workspaces: [TerminalWorkspace] = []
    do {
        // Its login shell is zsh; `rc-agent` is on PATH only for its
        // interactive shells, which also print a banner.
        try "/bin/zsh".write(to: mac.hostDirectory.appendingPathComponent("shell"), atomically: true, encoding: .utf8)
        let tools = mac.home.appendingPathComponent("rc-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = tools.appendingPathComponent("rc-agent")
        try "#!/bin/sh\nprintf 'rc-agent ran:%s\\n' \"$*\"\nexec /bin/sleep 300\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let zshrc = mac.home.appendingPathComponent(".zshrc")
        try "echo 'Welcome to rcpath'\nexport PATH=\"$HOME/rc-tools:$PATH\"\n".write(to: zshrc, atomically: true, encoding: .utf8)

        // As on the user's Mac: `zsh -lc` does not find it, `zsh -ic` does.
        let login = await mac.shell.run("/bin/zsh -lc 'command -v rc-agent' </dev/null || echo not-found\n", on: "rcpath")
        #expect(login.standardOutput.contains("not-found"), "\(login)")
        let interactive = await mac.shell.run("/bin/zsh -ic 'command -v rc-agent' </dev/null 2>/dev/null\n", on: "rcpath")
        #expect(interactive.standardOutput.contains(tool.path), "\(interactive)")

        // Read there as the app reads it: the shell from $SHELL there, the
        // banner skipped, only what is sent kept.
        let outcome = await RemoteLoginEnvironmentCapture.run(on: "rcpath", loginShell: nil, shell: mac.shell)
        guard case .captured(let captured) = outcome else {
            throw HostedSessionError.message("the login environment was not read: \(outcome)")
        }
        #expect(captured.shell == "/bin/zsh")
        #expect(captured.environment["PATH"]?.split(separator: ":").contains(Substring(tools.path)) == true)
        #expect(captured.environment["HOME"] == nil && captured.environment["SHELL"] == nil)
        // A `sh -s` script, never a master or a terminal.
        #expect(mac.calls.contains { $0.contains("BatchMode=yes") && $0.hasSuffix("-- rcpath sh -s") })

        // The device's tabs: its first agent waits for the read its control
        // connection starts, then runs the tool through `zsh -l -c`.
        let store = loginPathStore(for: mac, directory: directory)
        let device = try store.add(name: "Studio", sshDestination: "rcpath", homeDirectory: mac.home.path, shell: "/bin/zsh")
        let hosting = try #require(store.hosting(for: device.id))
        let key = device.projectKey(path: mac.projectPath)
        let workspace = TerminalWorkspace(
            projectRoot: key, createInitialSession: false,
            backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
        )
        workspaces.append(workspace)
        let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "RC", command: "rc-agent"), projectRoot: key)
        let command = workspace.addCommandSession(
            command: ProjectCommandDefinition(name: "rc", command: "rc-agent", arguments: "--serve"), projectRoot: key
        )
        try await mac.waitFor("the agent's and the command's sessions") {
            agent.persistentSession != nil && command.persistentSession != nil
        }
        let their = mac.makeTheirControl()
        for (tab, expected) in [(agent, "rc-agent ran:"), (command, "rc-agent ran:--serve")] {
            let binding = try #require(tab.persistentSession)
            let info = try #require(try await mac.sessions(their).first { $0.id == binding.sessionID })
            #expect(Array(info.command.prefix(3)) == ["/bin/zsh", "-l", "-c"])
            do {
                try await mac.waitFor("\(expected) on the screen there") {
                    (try? await hosting.screen(of: binding).text.contains(expected)) == true
                }
            } catch {
                let screen = (try? await hosting.screen(of: binding).text) ?? "?"
                Issue.record("state=\(tab.state) command=\(info.command) screen=\(screen)")
                throw error
            }
            #expect(tab.isRunning)
            #expect(tab.persistentLoginPathProblem == nil)
        }
        // Kept with the device (devices.json), PATH only.
        let saved = try #require(store.device(id: device.id)?.loginEnvironment)
        #expect(saved.environment["PATH"]?.split(separator: ":").contains(Substring(tools.path)) == true)
        #expect(saved.environment.keys.allSatisfy(RemoteLoginEnvironment.isSent))
        #expect(saved.environment["HOME"] == nil)
        // A terminal still runs its login shell (which reads .zshrc itself).
        let terminal = workspace.addSession(title: "Shell")
        try await mac.waitFor("the terminal's session") { terminal.persistentSession != nil }
        let terminalInfo = try #require(try await mac.sessions(their).first { $0.id == terminal.persistentSession?.sessionID })
        #expect(terminalInfo.command.isEmpty || !terminalInfo.command.contains("-c"))
        workspace.closeAllSessions(intent: .windowClosedEndingSessions)
        try await mac.waitFor("the device's sessions ended") {
            try await mac.sessions(their).allSatisfy { !$0.isRunning }
        }

        // A Mac whose shell cannot be read (its .zshrc exits at once):
        // today's launch, the host's PATH, and the tab says why the tool
        // was not found.
        try "exit 3\n".write(to: zshrc, atomically: true, encoding: .utf8)
        let fallbackStore = loginPathStore(for: mac, directory: fallbackDirectory)
        let unread = try fallbackStore.add(name: "Studio", sshDestination: "rcpath", homeDirectory: mac.home.path, shell: "/bin/zsh")
        let fallbackHosting = try #require(fallbackStore.hosting(for: unread.id))
        let fallbackKey = unread.projectKey(path: mac.projectPath)
        let fallback = TerminalWorkspace(
            projectRoot: fallbackKey, createInitialSession: false,
            backendPolicy: .remote(fallbackHosting, settings: { .defaults }, hostReconnects: nil)
        )
        workspaces.append(fallback)
        let lost = fallback.addAgentSession(agent: AgentToolDefinition(name: "RC", command: "rc-agent"), projectRoot: fallbackKey)
        try await mac.waitFor("the agent's exit") {
            if case .exited(127) = lost.state { return true }
            return false
        }
        let reason = "/bin/zsh printed no environment (exit 3)"
        #expect(fallbackStore.loginEnvironmentProblem(of: unread.id) == reason)
        #expect(fallbackStore.device(id: unread.id)?.loginEnvironment == nil)
        #expect(lost.persistentLoginPathProblem == reason)
        let message = "rc-agent is not on Studio's login PATH; Cherry couldn't read its shell's PATH (\(reason))"
        #expect(lost.remoteProgramNotFoundMessage == message)
        #expect(lost.persistentSessionEndedMessage == message)
        if let binding = lost.persistentSession {
            let screen = (try? await fallbackHosting.screen(of: binding).text) ?? ""
            #expect(screen.contains("command not found: rc-agent"), "\(screen)")
        }
        fallback.closeAllSessions(intent: .windowClosedEndingSessions)
    } catch {
        for workspace in workspaces { workspace.closeAllSessions(intent: .windowClosed) }
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}

// Over a real SSH connection when Scripts/test-remote-mac-loopback runs it
// (CHERRY_TEST_LOOPBACK_SSH and CHERRY_TEST_LOOPBACK_HOME: its private sshd,
// whose sessions have no terminal, and the private home it gives the
// login), else through the fake Mac: the read runs zsh's interactive startup
// files with standard input closed, and the line a device's agent runs finds
// the tool with the PATH it read, after zsh's startup files ran.
@Test(.enabled(if: loginPathRealHostEnabled))
@MainActor func RemoteDeviceRealHostLoginPathIsReadOverSSHWithoutATerminal() async throws {
    let environment = ProcessInfo.processInfo.environment
    let loopbackSSH = environment["CHERRY_TEST_LOOPBACK_SSH"]?.nilIfEmpty
    let mac: FakeRemoteMac? = loopbackSSH == nil ? try FakeRemoteMac(name: "pathssh", host: "none", startsDaemon: false) : nil
    let destination: String
    let home: URL
    let shell: RemoteDeviceShell
    if let loopbackSSH, let loopbackHome = environment["CHERRY_TEST_LOOPBACK_HOME"]?.nilIfEmpty {
        destination = environment["CHERRY_TEST_LOOPBACK_DESTINATION"]?.nilIfEmpty ?? "loopback"
        home = URL(fileURLWithPath: loopbackHome, isDirectory: true)
        shell = RemoteDeviceShell(
            sshExecutable: loopbackSSH,
            environment: [
                "PATH": URL(fileURLWithPath: loopbackSSH).deletingLastPathComponent().path + ":/usr/bin:/bin",
                "HOME": FileManager.default.temporaryDirectory.path,
            ],
            timeout: 30
        )
    } else {
        let mac = try #require(mac)
        destination = "pathssh"
        home = mac.home
        shell = mac.shell
    }
    let tools = home.appendingPathComponent("login-path-tools", isDirectory: true)
    let zshrc = home.appendingPathComponent(".zshrc")
    defer {
        try? FileManager.default.removeItem(at: tools)
        try? FileManager.default.removeItem(at: zshrc)
    }
    do {
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = tools.appendingPathComponent("path-tool")
        try "#!/bin/sh\necho path-tool-found\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        // Noise, and a question nobody answers (standard input is closed).
        try """
        echo "Last login: never"
        printf 'Update now? [y/N] '; read reply
        export PATH="$HOME/login-path-tools:$PATH"
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        let outcome = await RemoteLoginEnvironmentCapture.run(on: destination, loginShell: "/bin/zsh", shell: shell)
        guard case .captured(let captured) = outcome else {
            throw HostedSessionError.message("the login environment was not read over \(destination): \(outcome)")
        }
        let path = try #require(captured.environment["PATH"])
        #expect(path.split(separator: ":").first.map(String.init) == tools.path)
        #expect(captured.shell == "/bin/zsh")

        // What a device's agent runs there: `zsh -l -c <line>` with the
        // PATH it read in CHERRY_LOGIN_PATH.
        let line = try #require(RemoteLaunchSpec.lineSettingLoginPath("path-tool", shell: "/bin/zsh"))
        let script = "CHERRY_LOGIN_PATH=\(RemoteDeviceProbe.singleQuoted(path)) /bin/zsh -l -c \(RemoteDeviceProbe.singleQuoted(line)) </dev/null\n"
        let ran = await shell.run(script, on: destination)
        #expect(ran.standardOutput.contains("path-tool-found"), "\(ran)")
        let without = await shell.run("/bin/zsh -l -c path-tool </dev/null 2>&1 || true\n", on: destination)
        #expect(!without.standardOutput.contains("path-tool-found"), "\(without)")
    } catch {
        await mac?.tearDown()
        throw error
    }
    await mac?.tearDown()
}
