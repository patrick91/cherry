import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// A device's login PATH (docs/specs/remote-devices.md, "Login PATH on
// devices"): its interactive login shell's PATH, read there and given to its
// commands and agents, whose `[shell, -l, -c, line]` would otherwise miss
// what ~/.zshrc puts on PATH. No ssh runs: the parser takes made-up output,
// the script runs in a local sh with a private HOME, and the device's
// hosting talks to the in-process fake `cherry control`.

private let marker = "__CHERRY_LOGIN_ENVIRONMENT_TEST__"

/// What the capture script prints there, around what the shell printed.
private func scriptOutput(_ shellOutput: Data, shell: String = "/bin/zsh", status: Int = 0) -> Data {
    var data = Data("\(RemoteLoginEnvironmentCapture.beginMarker)\n\(RemoteLoginEnvironmentCapture.shellKey)=\(shell)\n".utf8)
    data.append(shellOutput)
    data.append(Data("\n\(RemoteLoginEnvironmentCapture.statusKey)=\(status)\n\(RemoteLoginEnvironmentCapture.endMarker)\n".utf8))
    return data
}

private func environmentBlock(_ entries: [String]) -> Data {
    var data = Data(marker.utf8)
    for entry in entries {
        data.append(Data(entry.utf8))
        data.append(0)
    }
    data.append(Data(marker.utf8))
    return data
}

private func output(_ data: Data, status: Int32 = 0, standardError: String = "", timedOut: Bool = false) -> RemoteDeviceShell.DataOutput {
    RemoteDeviceShell.DataOutput(status: status, standardOutput: data, standardError: standardError, timedOut: timedOut)
}

// MARK: - Parsing

@Test func RemoteDeviceLoginPathParsesTheEnvironmentBetweenMarkersThroughNoise() throws {
    var shellOutput = Data("Welcome to Studio!\n\u{1B}]7;file://studio/Users/me\u{07}oh-my-zsh: up to date\n".utf8)
    // Half a marker in what an rc file prints is not one.
    shellOutput.append(Data("__CHERRY_LOGIN_ENVI".utf8))
    shellOutput.append(environmentBlock([
        "PATH=/Users/me/.bun/bin:/Users/me/.local/bin:/usr/bin:/bin",
        "MANPATH=/opt/homebrew/share/man:",
        "TZ=Europe/Rome",
        "XDG_CONFIG_HOME=/Users/me/.config",
        "HOME=/Users/me", "SHELL=/bin/zsh", "USER=me", "TMPDIR=/var/folders/x/T/",
        "SSH_AUTH_SOCK=/Users/me/agent.sock", "LANG=it_IT.UTF-8", "LC_ALL=it_IT.UTF-8",
        "OPENAI_API_KEY=sk-secret", "GITHUB_TOKEN=ghp_secret",
        "CHERRY_PROCESS_ID=from-a-tab", "TERM=xterm-256color", "PWD=/Users/me",
        "MULTILINE=one\ntwo",
    ]))
    shellOutput.append(Data("\nbye from .zlogout\n".utf8))
    let now = Date(timeIntervalSince1970: 1_800_000_000.75)
    let outcome = RemoteLoginEnvironmentCapture.parse(output(scriptOutput(shellOutput)), marker: marker, now: now)
    guard case .captured(let environment) = outcome else {
        Issue.record("not captured: \(outcome)")
        return
    }
    // Only what a device's commands and agents are given: never a secret,
    // the account's own variables, its agent socket or its locale.
    #expect(environment.environment == [
        "PATH": "/Users/me/.bun/bin:/Users/me/.local/bin:/usr/bin:/bin",
        "MANPATH": "/opt/homebrew/share/man:",
        "TZ": "Europe/Rome",
        "XDG_CONFIG_HOME": "/Users/me/.config",
    ])
    #expect(environment.shell == "/bin/zsh")
    #expect(environment.capturedAt == Date(timeIntervalSince1970: 1_800_000_000))

    // Printed although ssh had to be ended (an rc file's program kept the
    // output open): still read.
    let ended = RemoteLoginEnvironmentCapture.parse(
        output(scriptOutput(environmentBlock(["PATH=/a:/b"])), status: 255, timedOut: true), marker: marker, now: now
    )
    #expect(ended == .captured(RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: now, environment: ["PATH": "/a:/b"])))
}

@Test func RemoteDeviceLoginPathSaysWhyItCouldNotReadIt() {
    // ssh itself failed: its reason.
    let refused = RemoteLoginEnvironmentCapture.parse(
        output(Data(), status: 255, standardError: "studio: Permission denied (publickey).\n"), marker: marker
    )
    #expect(refused == .failed("SSH could not log in (studio: Permission denied (publickey).)."))
    // The shell was killed after the time allowed.
    #expect(RemoteLoginEnvironmentCapture.parse(output(scriptOutput(Data("loading…".utf8), status: 137)), marker: marker)
        == .failed("/bin/zsh did not finish within 10 seconds"))
    #expect(RemoteLoginEnvironmentCapture.parse(
        output(scriptOutput(Data(), status: 137)), marker: marker, shellTimeout: 2
    ) == .failed("/bin/zsh did not finish within 2 seconds"))
    // It ended without printing (an rc file that execs tmux, which has no
    // terminal there).
    #expect(RemoteLoginEnvironmentCapture.parse(
        output(scriptOutput(Data("open terminal failed: not a terminal\n".utf8), shell: "/opt/homebrew/bin/fish", status: 1)),
        marker: marker
    ) == .failed("/opt/homebrew/bin/fish printed no environment (exit 1)"))
    // An environment without PATH is no use.
    #expect(RemoteLoginEnvironmentCapture.parse(output(scriptOutput(environmentBlock(["HOME=/Users/me"]))), marker: marker)
        == .failed("/bin/zsh set no PATH"))
    // The script never ran (its sh failed).
    #expect(RemoteLoginEnvironmentCapture.parse(output(Data(), status: 2, standardError: "sh: bad\n"), marker: marker)
        == .failed("sh: bad"))
}

@Test func RemoteDeviceLoginPathKeepsOnlyWhatItSendsAndWithinLimits() throws {
    let long = String(repeating: "x", count: RemoteLoginEnvironment.maxValueBytes + 1)
    let filtered = RemoteLoginEnvironment.filtered([
        "PATH": "/a", "XDG_DATA_HOME": long, "TZ": "UTC", "HOME": "/h", "LC_CTYPE": "C", "DISPLAY": ":0"
    ])
    #expect(filtered == ["PATH": "/a", "TZ": "UTC"])
    for key in ["PATH", "MANPATH", "TZ", "XDG_CONFIG_HOME"] { #expect(RemoteLoginEnvironment.isSent(key), "\(key)") }
    for key in ["HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "SSH_ASKPASS", "DISPLAY", "LANG", "LC_ALL",
                "TERMINFO", "TERMINFO_DIRS", "GITHUB_TOKEN", "CHERRY_CONTROL_SOCKET"] {
        #expect(!RemoteLoginEnvironment.isSent(key), "\(key)")
    }
    // devices.json read back: checked again; one without PATH is dropped.
    let id = UUID()
    let json = #"""
    {"id":"\#(id.uuidString)","name":"Studio","sshDestination":"studio",
     "loginEnvironment":{"shell":"/bin/zsh","capturedAt":"2026-10-04T10:00:00Z",
       "environment":{"PATH":"/Users/me/.bun/bin:/usr/bin","GITHUB_TOKEN":"ghp_x"}}}
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let device = try decoder.decode(RemoteDevice.self, from: Data(json.utf8))
    #expect(device.loginEnvironment?.environment == ["PATH": "/Users/me/.bun/bin:/usr/bin"])
    #expect(device.launchDevice.loginEnvironment == ["PATH": "/Users/me/.bun/bin:/usr/bin"])
    let noPath = json.replacingOccurrences(of: #""PATH":"/Users/me/.bun/bin:/usr/bin","#, with: "")
    #expect(try decoder.decode(RemoteDevice.self, from: Data(noPath.utf8)).loginEnvironment == nil)
    // An older devices.json has none.
    let old = #"{"id":"\#(id.uuidString)","name":"Mini","sshDestination":"mini"}"#
    #expect(try decoder.decode(RemoteDevice.self, from: Data(old.utf8)).loginEnvironment == nil)
}

// MARK: - The script, run by a local sh

/// Runs `script` with `/bin/sh -s` (standard input a pipe, as from ssh) in
/// a session of its own without a controlling terminal, as sshd runs it,
/// with `environment` only; killed after `timeout` seconds.
private func runLocally(_ script: String, environment: [String: String], timeout: TimeInterval = 30) throws -> RemoteDeviceShell.DataOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
        "-e",
        #"use POSIX (); my $pid = fork(); die "fork\n" unless defined $pid; if ($pid == 0) { POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "exec\n"; } $SIG{TERM} = sub { kill "TERM", $pid }; waitpid($pid, 0); exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));"#,
        "/bin/sh", "-s",
    ]
    process.environment = environment
    let input = Pipe()
    let stdout = Pipe()
    process.standardInput = input
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    let box = PipeOutputBox()
    let group = DispatchGroup()
    RemoteDeviceShell.readToEnd(stdout.fileHandleForReading, into: box, group: group)
    input.fileHandleForWriting.write(Data(script.utf8))
    try input.fileHandleForWriting.close()
    var timedOut = false
    if group.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        process.terminate()
        _ = group.wait(timeout: .now() + 5)
    }
    process.waitUntilExit()
    return RemoteDeviceShell.DataOutput(status: process.terminationStatus, standardOutput: box.data, standardError: "", timedOut: timedOut)
}

private func privateHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-login-path-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return home
}

@Test func RemoteDeviceLoginPathScriptReadsWhatAnInteractiveRcFileAddsAndNothingPrompts() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let tools = home.appendingPathComponent("rc-tools").path
    // Noise, a prompt that would wait for input (standard input is closed),
    // a secret, and the tool folder only an interactive shell adds.
    try """
    echo "Welcome to the other Mac"
    printf 'Update oh-my-zsh? [Y/n] '; read answer
    export SECRET_TOKEN=do-not-send
    export PATH="$HOME/rc-tools:$PATH"
    """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let environment = ["HOME": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName()]
    let marker = "__CHERRY_LOGIN_ENVIRONMENT_\(UUID().uuidString)__"
    let script = RemoteLoginEnvironmentCapture.script(loginShell: nil, marker: marker)
    // The marker is never whole in the script (a shell echoing its command
    // line shows no marker).
    #expect(!script.contains(marker))
    let outcome = RemoteLoginEnvironmentCapture.parse(try runLocally(script, environment: environment), marker: marker)
    guard case .captured(let captured) = outcome else {
        Issue.record("not captured: \(outcome)")
        return
    }
    #expect(captured.shell == "/bin/zsh")
    #expect(captured.environment["PATH"]?.split(separator: ":").first.map(String.init) == tools)
    #expect(captured.environment["SECRET_TOKEN"] == nil && captured.environment["HOME"] == nil)

    // The device's recorded shell is used when it is there; one that is not
    // falls back to $SHELL there.
    let named = RemoteLoginEnvironmentCapture.parse(
        try runLocally(RemoteLoginEnvironmentCapture.script(loginShell: "/bin/bash", marker: marker), environment: environment),
        marker: marker
    )
    if case .captured(let bash) = named { #expect(bash.shell == "/bin/bash") } else { Issue.record("bash: \(named)") }
    let missing = RemoteLoginEnvironmentCapture.parse(
        try runLocally(RemoteLoginEnvironmentCapture.script(loginShell: "/nonexistent/zsh", marker: marker), environment: environment),
        marker: marker
    )
    if case .captured(let fallback) = missing { #expect(fallback.shell == "/bin/zsh") } else { Issue.record("fallback: \(missing)") }
}

@Test func RemoteDeviceLoginPathScriptGivesUpOnAShellThatHangs() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try "exec /bin/sleep 20\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let marker = "__CHERRY_LOGIN_ENVIRONMENT_\(UUID().uuidString)__"
    let started = Date()
    let result = try runLocally(
        RemoteLoginEnvironmentCapture.script(loginShell: "/bin/zsh", marker: marker, shellTimeout: 1),
        environment: ["HOME": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
        timeout: 15
    )
    #expect(!result.timedOut)
    #expect(Date().timeIntervalSince(started) < 10)
    #expect(RemoteLoginEnvironmentCapture.parse(result, marker: marker, shellTimeout: 1)
        == .failed("/bin/zsh did not finish within 1 seconds"))
}

// MARK: - Launches

private func configuration(_ line: String? = nil, environment: [String: String] = [:]) -> ShellProcessController.Configuration {
    ShellProcessController.Configuration(
        shellPath: "/bin/zsh",
        workingDirectory: "/Users/me/app",
        projectRoot: ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key,
        processID: UUID().uuidString,
        environment: environment,
        term: ShellProcessController.ghosttyTerm,
        initialSize: TerminalViewportSize(columns: 80, rows: 24),
        startupCommand: line
    )
}

@Test func RemoteDeviceLoginPathReachesCommandsAndAgentsButNotTerminals() {
    let login = ["PATH": "/Users/me/.bun/bin:/usr/bin:/bin", "TZ": "Europe/Rome", "XDG_CONFIG_HOME": "/Users/me/.config"]
    let device = RemoteLaunchSpec.Device(shell: "/bin/zsh", homeDirectory: "/Users/me", loginEnvironment: login)
    // This Mac's PATH, wherever it comes from, never.
    let thisMac = ["PATH": "/Users/local/bin:/usr/bin", "LANG": "en_GB.UTF-8"]
    let agent = RemoteLaunchSpec.make(
        for: configuration("codex", environment: ["PATH": "/local/bin", "PORT": "3000", "TZ": "UTC"]),
        device: device, localeEnvironment: thisMac
    )
    // The line sets PATH once the login shell's startup files ran (a
    // system zshenv may set it from scratch).
    #expect(agent.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; codex"])
    #expect(agent.environment["CHERRY_LOGIN_PATH"] == "/Users/me/.bun/bin:/usr/bin:/bin")
    #expect(agent.environment["PATH"] == nil)
    #expect(agent.environment["XDG_CONFIG_HOME"] == "/Users/me/.config")
    // The tab's own variables come after (a cherry.toml TZ), never its PATH.
    #expect(agent.environment["TZ"] == "UTC")
    #expect(agent.environment["PORT"] == "3000")
    #expect(agent.environment["LANG"] == "en_GB.UTF-8")
    #expect(agent.loginPathProblem == nil)
    // Anything else a caller passes as the device's is not sent.
    let leaky = RemoteLaunchSpec.Device(loginEnvironment: ["PATH": "/p", "HOME": "/Users/me", "SSH_AUTH_SOCK": "/s"])
    let leakySpec = RemoteLaunchSpec.make(for: configuration("make"), device: leaky, localeEnvironment: [:])
    #expect(leakySpec.environment["CHERRY_LOGIN_PATH"] == "/p")
    #expect(leakySpec.environment["HOME"] == nil && leakySpec.environment["SSH_AUTH_SOCK"] == nil)
    // Nor a CHERRY_LOGIN_PATH of the tab's own (This Mac's).
    let local = RemoteLaunchSpec.make(
        for: configuration("make", environment: ["CHERRY_LOGIN_PATH": "/local/bin"]), localeEnvironment: [:]
    )
    #expect(local.environment["CHERRY_LOGIN_PATH"] == nil)
    // Each shell in its own syntax; one whose syntax is not known gets PATH
    // in its environment.
    let fish = RemoteLaunchSpec.make(
        for: configuration("claude"), device: .init(shell: "/opt/homebrew/bin/fish", loginEnvironment: login), localeEnvironment: [:]
    )
    #expect(fish.argv.last == "set -gx PATH (string split ':' \"$CHERRY_LOGIN_PATH\"); set -e CHERRY_LOGIN_PATH; claude")
    let tcsh = RemoteLaunchSpec.make(
        for: configuration("claude"), device: .init(shell: "/bin/tcsh", loginEnvironment: login), localeEnvironment: [:]
    )
    #expect(tcsh.argv.last == "setenv PATH \"$CHERRY_LOGIN_PATH\"; unsetenv CHERRY_LOGIN_PATH; claude")
    let nu = RemoteLaunchSpec.make(
        for: configuration("claude"), device: .init(shell: "/opt/homebrew/bin/nu", loginEnvironment: login), localeEnvironment: [:]
    )
    #expect(nu.argv == ["/opt/homebrew/bin/nu", "-l", "-c", "claude"])
    #expect(nu.environment["PATH"] == "/Users/me/.bun/bin:/usr/bin:/bin" && nu.environment["CHERRY_LOGIN_PATH"] == nil)

    // A terminal's login shell reads its startup files itself.
    let terminal = RemoteLaunchSpec.make(for: configuration(), device: device, localeEnvironment: thisMac)
    #expect(terminal.argv.isEmpty)
    for key in ["PATH", "CHERRY_LOGIN_PATH", "TZ", "XDG_CONFIG_HOME"] { #expect(terminal.environment[key] == nil, "\(key)") }
    #expect(terminal.loginPathProblem == nil)

    // Not read: today's launch (the host's PATH), with why.
    let unread = RemoteLaunchSpec.make(
        for: configuration("codex"), device: .init(shell: "/bin/zsh", loginEnvironmentProblem: "/bin/zsh did not finish within 10 seconds"),
        localeEnvironment: thisMac
    )
    #expect(unread.argv == ["/bin/zsh", "-l", "-c", "codex"])
    #expect(unread.environment["PATH"] == nil && unread.environment["CHERRY_LOGIN_PATH"] == nil)
    #expect(unread.loginPathProblem == "/bin/zsh did not finish within 10 seconds")
    #expect(RemoteLaunchSpec.make(for: configuration("codex"), localeEnvironment: [:]).loginPathProblem
        == RemoteLaunchSpec.loginEnvironmentNotReadYet)
}

/// Runs `arguments` with `environment` only and standard input closed,
/// killed after `timeout` seconds; what it printed.
private func runShell(_ arguments: [String], environment: [String: String], timeout: TimeInterval = 20) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    try process.run()
    let box = PipeOutputBox()
    let group = DispatchGroup()
    RemoteDeviceShell.readToEnd(stdout.fileHandleForReading, into: box, group: group)
    if group.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = group.wait(timeout: .now() + 5)
    }
    process.waitUntilExit()
    return String(decoding: box.data, as: UTF8.self)
}

@Test func RemoteDeviceLoginPathLineSetsPathAfterStartupFilesThatResetIt() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let tools = home.appendingPathComponent("rc-tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let tool = tools.appendingPathComponent("rc-tool")
    try "#!/bin/sh\nprintf 'rc-tool ran, CHERRY_LOGIN_PATH=%s\\n' \"${CHERRY_LOGIN_PATH-unset}\"\n".write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    // Startup files that set PATH from scratch, as nix-darwin's /etc/zshenv
    // does (this Mac's own system files run too).
    let reset = "PATH=/usr/bin:/bin; export PATH\n"
    for file in [".zshenv", ".bash_profile", ".profile"] {
        try reset.write(to: home.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    try "setenv PATH /usr/bin:/bin\n".write(to: home.appendingPathComponent(".tcshrc"), atomically: true, encoding: .utf8)
    let environment = [
        "HOME": home.path, "PATH": "/usr/bin:/bin", "USER": NSUserName(),
        RemoteLaunchSpec.loginPathVariable: "\(tools.path):/usr/bin:/bin",
    ]
    var shells: [(path: String, login: Bool)] = [("/bin/zsh", true), ("/bin/bash", true), ("/bin/sh", true), ("/bin/ksh", true), ("/bin/dash", true)]
    // csh and tcsh take -l only as their sole flag.
    shells.append(("/bin/tcsh", false))
    for (shell, login) in shells where FileManager.default.isExecutableFile(atPath: shell) {
        // Without it, the tool is not found.
        let plain = try runShell([shell] + (login ? ["-l"] : []) + ["-c", "rc-tool"], environment: environment)
        #expect(!plain.contains("rc-tool ran"), "\(shell): \(plain)")
        let line = try #require(RemoteLaunchSpec.lineSettingLoginPath("rc-tool", shell: shell))
        let output = try runShell([shell] + (login ? ["-l"] : []) + ["-c", line], environment: environment)
        // Found, and the variable is gone before the program runs.
        #expect(output.contains("rc-tool ran, CHERRY_LOGIN_PATH=unset"), "\(shell): \(output)")
    }
}

@Test func RemoteDeviceLoginPathNamesTheProgramOfACommandLine() {
    #expect(TerminalSession.programName(ofCommandLine: "codex --model o3") == "codex")
    #expect(TerminalSession.programName(ofCommandLine: "FOO=1 BAR=2 exec /Users/me/.bun/bin/pi -c") == "pi")
    #expect(TerminalSession.programName(ofCommandLine: "env -i HOME=/x 'claude' --resume") == "claude")
    #expect(TerminalSession.programName(ofCommandLine: "  ") == nil)
    #expect(TerminalSession.programName(ofCommandLine: nil) == nil)
}

// MARK: - The device store and its tabs

/// A device store whose device's hosting talks to the fake `cherry
/// control`, and whose login environment reads are `capture`.
@MainActor
private final class LoginPathHarness {
    let fake = FakeControlHelper()
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let store: RemoteDeviceStore
    let directory: URL
    private let suite: String
    private(set) var captures = 0
    var capture: @MainActor () async -> RemoteLoginEnvironmentCapture.Outcome

    init(
        canWrite: @escaping @MainActor () -> Bool = { true },
        capture: @escaping @MainActor () async -> RemoteLoginEnvironmentCapture.Outcome
    ) throws {
        self.capture = capture
        cli = try HostedSessionFakeCLI()
        suite = "CherryTests.RemoteLoginPath.\(UUID().uuidString)"
        let hostStore = HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let executable = cli.executable
        let control = HostControl(
            host: try HostedSessionHost.ssh("studio"),
            clientProvider: {
                HostedSessionClient(
                    executableURL: executable,
                    // This Mac's login environment: its PATH never reaches
                    // the device.
                    loginEnvironment: { _ in .init(environment: ["PATH": "/this/mac/bin:/usr/bin", "LANG": "en_GB.UTF-8"]) }
                )
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        self.control = control
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-login-path-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.terminationTimeout = .seconds(3)
        configuration.restartExitTimeout = .seconds(3)
        configuration.reconnectDelay = (0.05, 0.2)
        configuration.lostCreateChecks = [.milliseconds(200)]
        let hostingConfiguration = configuration
        weak var weakSelf: LoginPathHarness?
        store = RemoteDeviceStore(
            fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
            canWrite: canWrite,
            hostStore: hostStore,
            installationID: { UUID() },
            registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
            remoteHostPaths: HostedRemoteHostPaths(),
            makeHosting: { profile, installation in
                PersistentHostSessions.remote(
                    profile: profile, installationID: installation, remoteShell: "/bin/bash",
                    control: { control }, installationUnavailableReason: { nil },
                    status: PersistentSessionsStatus(), instanceLock: nil, terminalColors: { nil },
                    configuration: hostingConfiguration
                )
            },
            captureLoginEnvironment: { _ in
                guard let harness = weakSelf else { return .failed("gone") }
                harness.captures += 1
                return await harness.capture()
            }
        )
        weakSelf = self
    }

    func workspace(for device: RemoteDevice) -> TerminalWorkspace {
        TerminalWorkspace(
            projectRoot: device.projectKey(path: "/Users/me/work/app"),
            createInitialSession: false,
            backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: store.hosting(for: device.id))
        )
    }

    func create(of tab: TerminalSession) -> FakeControlHelper.Request? {
        fake.requests("create").first { ($0.json["tags"] as? [String: String])?[PersistentSessionTag.tab] == tab.id.uuidString }
    }

    /// Reports that the host's session ended.
    func exit(_ sessionID: String, code: UInt32) {
        var exited: HostedSessionInfo?
        fake.sessions = fake.sessions.map { session in
            guard session.id == sessionID else { return session }
            let info = session.exited(code: code, signal: nil)
            exited = info
            return info
        }
        guard let connection = fake.connections.last(where: { !$0.isClosed }) else { return }
        connection.push(.event(.exited(id: sessionID, exitCode: code, signal: nil)))
        if let exited { connection.push(.event(.changed(exited))) }
    }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private extension TerminalSession {
    func hasExited(_ status: Int32) -> Bool {
        if case .exited(status) = state { return true }
        return false
    }
}

private func environment(_ request: FakeControlHelper.Request?) -> [String: String] {
    request?.json["env"] as? [String: String] ?? [:]
}

private let bunPath = "/Users/me/.bun/bin:/Users/me/.local/bin:/usr/bin:/bin"

@Test @MainActor func RemoteDeviceLoginPathIsReadWhenItsControlConnectsAndGivenToItsAgents() async throws {
    let harness = try LoginPathHarness {
        // A read that takes a moment: the first agent waits for it.
        try? await Task.sleep(for: .milliseconds(300))
        return .captured(RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: Date(), environment: ["PATH": bunPath]))
    }
    defer { harness.cleanUp() }
    let device = try harness.store.add(name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me", shell: "/bin/zsh")
    #expect(device.loginEnvironment == nil)
    let workspace = harness.workspace(for: device)
    defer { workspace.closeAllSessions(intent: .windowClosed) }

    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Codex", command: "codex"), projectRoot: device.projectKey(path: "/Users/me/work/app"))
    #expect(await harness.fake.wait { agent.persistentSession != nil })
    let create = try #require(harness.create(of: agent))
    let argv = try #require(create.json["command"] as? [String])
    #expect(Array(argv.prefix(3)) == ["/bin/zsh", "-l", "-c"])
    #expect(argv.last?.contains("codex") == true)
    // The device's PATH, never This Mac's, set by the line once the login
    // shell's startup files ran.
    #expect(environment(create)["CHERRY_LOGIN_PATH"] == bunPath)
    #expect(environment(create)["PATH"] == nil)
    #expect(argv.last?.hasPrefix("export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; ") == true)
    #expect(agent.persistentLoginPathProblem == nil)
    // Kept with the device.
    #expect(harness.store.device(id: device.id)?.loginEnvironment?.environment == ["PATH": bunPath])
    #expect(harness.store.loginEnvironmentProblem(of: device.id) == nil)
    let saved = try Data(contentsOf: harness.store.fileURL)
    #expect(String(decoding: saved, as: UTF8.self).contains(".bun"))

    // A command too; a terminal's login shell reads its own startup files.
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "server", command: "bun", arguments: "run dev", environment: ["PATH": "/local/bin"]),
        projectRoot: device.projectKey(path: "/Users/me/work/app")
    )
    let terminal = workspace.addSession(title: "Shell")
    #expect(await harness.fake.wait { command.persistentSession != nil && terminal.persistentSession != nil })
    #expect(environment(harness.create(of: command))["CHERRY_LOGIN_PATH"] == bunPath)
    #expect(environment(harness.create(of: terminal))["PATH"] == nil)
    #expect(environment(harness.create(of: terminal))["CHERRY_LOGIN_PATH"] == nil)
    #expect(harness.create(of: terminal)?.json["command"] as? [String] == [])
    // Read once: the connection, not each launch, reads it (and at most
    // every so often).
    #expect(harness.captures == 1)
    #expect(harness.store.refreshLoginEnvironment(of: device.id) == nil)
    #expect(harness.captures == 1)
    // An exit 127 now: the program, or something it runs, is not there.
    let agentSession = try #require(agent.persistentSession?.sessionID)
    harness.exit(agentSession, code: 127)
    #expect(await harness.fake.wait { agent.hasExited(127) })
    #expect(agent.remoteProgramNotFoundMessage == "Exit 127: codex, or a command it runs, was not found on Studio")
}

@Test @MainActor func RemoteDeviceLoginPathThatCannotBeReadFallsBackAndSaysSoWhenACommandIsNotFound() async throws {
    let reason = "/bin/zsh did not finish within 10 seconds"
    let harness = try LoginPathHarness { .failed(reason) }
    defer { harness.cleanUp() }
    let device = try harness.store.add(name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me", shell: "/bin/zsh")
    let workspace = harness.workspace(for: device)
    defer { workspace.closeAllSessions(intent: .windowClosed) }

    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Codex", command: "codex"), projectRoot: device.projectKey(path: "/Users/me/work/app"))
    #expect(await harness.fake.wait { agent.persistentSession != nil })
    // Today's launch: the host's PATH (its account's), never This Mac's.
    #expect(environment(harness.create(of: agent))["PATH"] == nil)
    #expect(environment(harness.create(of: agent))["CHERRY_LOGIN_PATH"] == nil)
    #expect(harness.create(of: agent)?.json["command"] as? [String] == ["/bin/zsh", "-l", "-c", "codex"])
    #expect(harness.store.loginEnvironmentProblem(of: device.id) == reason)
    #expect(harness.store.device(id: device.id)?.loginEnvironment == nil)
    #expect(agent.persistentLoginPathProblem == reason)

    let agentSession = try #require(agent.persistentSession?.sessionID)
    harness.exit(agentSession, code: 127)
    #expect(await harness.fake.wait { agent.hasExited(127) })
    let message = "codex is not on Studio's login PATH; Cherry couldn't read its shell's PATH (\(reason))"
    #expect(agent.remoteProgramNotFoundMessage == message)
    #expect(agent.persistentSessionEndedMessage == message)

    // A command the same way.
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "pi", command: "pi", arguments: ""), projectRoot: device.projectKey(path: "/Users/me/work/app")
    )
    #expect(await harness.fake.wait { command.persistentSession != nil })
    harness.exit(try #require(command.persistentSession?.sessionID), code: 127)
    #expect(await harness.fake.wait { command.hasExited(127) })
    #expect(command.remoteProgramNotFoundMessage == "pi is not on Studio's login PATH; Cherry couldn't read its shell's PATH (\(reason))")
    // Another exit says nothing of PATH.
    let other = workspace.addAgentSession(agent: AgentToolDefinition(name: "Claude", command: "claude"), projectRoot: device.projectKey(path: "/Users/me/work/app"))
    #expect(await harness.fake.wait { other.persistentSession != nil })
    harness.exit(try #require(other.persistentSession?.sessionID), code: 1)
    #expect(await harness.fake.wait { other.hasExited(1) })
    #expect(other.remoteProgramNotFoundMessage == nil)
    // A failed read was not retried by each launch (the next connection
    // after a while, or a check, reads it again).
    #expect(harness.captures == 1)

    // Read later: the last read wins and later launches get it.
    harness.capture = { .captured(RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: Date(), environment: ["PATH": bunPath])) }
    await harness.store.refreshLoginEnvironment(of: device.id, force: true)?.value
    #expect(harness.store.loginEnvironmentProblem(of: device.id) == nil)
    agent.restart()
    #expect(await harness.fake.wait { agent.isRunning && environment(harness.fake.requests("create").last)["CHERRY_LOGIN_PATH"] == bunPath })
    #expect(agent.persistentLoginPathProblem == nil)
    // A failure afterwards keeps the last one read.
    harness.capture = { .failed("ssh: connect to host studio port 22: Connection timed out") }
    await harness.store.refreshLoginEnvironment(of: device.id, force: true)?.value
    #expect(harness.store.device(id: device.id)?.loginEnvironment?.environment["PATH"] == bunPath)
    #expect(harness.store.launchDevice(id: device.id)?.loginEnvironmentProblem == nil)
}

@Test @MainActor func RemoteDeviceLoginPathIsReadOnlyByTheCopyThatKeepsTheDevices() async throws {
    var canWrite = true
    let harness = try LoginPathHarness(canWrite: { canWrite }) {
        .captured(RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: Date(), environment: ["PATH": bunPath]))
    }
    defer { harness.cleanUp() }
    let device = try harness.store.add(name: "Studio", sshDestination: "studio")
    canWrite = false
    #expect(harness.store.refreshLoginEnvironment(of: device.id, force: true) == nil)
    #expect(harness.captures == 0)
    canWrite = true
    await harness.store.refreshLoginEnvironment(of: device.id)?.value
    #expect(harness.captures == 1)
    // Add Mac… gives the one its check read: not read again on connecting.
    let added = try harness.store.add(
        name: "Mini", sshDestination: "mini",
        loginEnvironment: RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: Date(), environment: ["PATH": "/m/bin"])
    )
    #expect(added.loginEnvironment?.environment == ["PATH": "/m/bin"])
    #expect(harness.store.refreshLoginEnvironment(of: added.id) == nil)
    #expect(harness.store.launchDevice(id: added.id)?.loginEnvironment == ["PATH": "/m/bin"])
}

@Test func RemoteDeviceLoginPathShowsInAddMacsChecklist() {
    let result = RemoteDeviceProbeResult(uname: "Darwin arm64", macOSVersion: "26.0", computerName: "Studio", shell: "/bin/zsh")
    let read = RemoteDeviceChecklist(
        result: result, destination: "studio",
        loginEnvironment: .captured(RemoteLoginEnvironment(shell: "/bin/zsh", capturedAt: Date(), environment: ["PATH": "/a:/b:/c"]))
    )
    let item = read.items.first { $0.id == "path" }
    #expect(item?.status == .ok)
    #expect(item?.detail?.contains("/bin/zsh") == true && item?.detail?.contains("3 folders") == true)
    let failed = RemoteDeviceChecklist(result: result, destination: "studio", loginEnvironment: .failed("/bin/zsh printed no environment (exit 1)"))
    let warning = failed.items.first { $0.id == "path" }
    #expect(warning?.status == .warning)
    #expect(warning?.detail?.contains("couldn't read its shell's PATH (/bin/zsh printed no environment (exit 1))") == true)
    #expect(failed.canAdd)
    // Not read: no line.
    #expect(RemoteDeviceChecklist(result: result, destination: "studio").items.allSatisfy { $0.id != "path" })
}
