import CherryControl
import CryptoKit
import Darwin
import Foundation
import os
import Testing
@testable import Cherry

// The `cherry` CLI's flags on the command line of the agents Cherry starts
// on another Mac (`RemoteAgentLaunch`): the line that asks the CLI's
// version there, run under the real shells with stand-in `claude`, `codex`
// and `pi` scripts in a private HOME (never a real agent CLI), the flags
// and variables it carries, and every launch that keeps today's line
// exactly.

private let cliPath = "/Users/them/Library/Application Support/cherry-host/bin/b1/cherry"
private let socketPath = "/var/folders/8s/f8v56gzs3232x21hn7nngwmc0000gn/T/cherry-mcp-0123456789abcdef/control.sock"

/// One device tab's launches: its ids, its tokens, and the device as the
/// app's store describes it.
private struct DeviceAgentLaunch {
    let deviceID = UUID()
    let tab = UUID()
    let tokens = RemoteMCPTokens(key: SymmetricKey(size: .bits256))

    func device(
        shell: String = "/bin/zsh",
        cli: String? = cliPath,
        loginPath: String? = "/Users/them/.local/bin:/usr/bin:/bin",
        connects: Bool = true
    ) -> RemoteLaunchSpec.Device {
        RemoteLaunchSpec.Device(
            shell: shell,
            homeDirectory: "/Users/them",
            mcp: RemoteMCPLaunch(
                deviceID: deviceID, socketPath: socketPath, cliPath: cli,
                controlMachine: "Laptop", tokens: tokens
            ),
            loginEnvironment: loginPath.map { ["PATH": $0] },
            connectsAgentsAtLaunch: connects
        )
    }

    func configuration(
        _ command: String?,
        agent: Bool = true,
        processID: String? = nil,
        projectPath: String? = "/Users/them/app",
        workingDirectory: String = "/Users/them/app"
    ) -> ShellProcessController.Configuration {
        let processID = processID ?? tab.uuidString
        return ShellProcessController.Configuration(
            shellPath: "/bin/zsh",
            workingDirectory: workingDirectory,
            projectRoot: projectPath.map { ProjectLocation.remote(deviceID: deviceID, path: $0).key },
            processID: processID,
            agentID: agent ? processID : nil,
            // This Mac's own values, which never travel.
            environment: [
                "CHERRY_MCP_HELPER": "/Applications/Cherry.app/Contents/MacOS/CherryMCP",
                "CHERRY_CLI": "/Applications/Cherry.app/Contents/MacOS/cherry",
                "CHERRY_CONTROL_SOCKET": "/tmp/cherry-501/Cherry-x/control.sock",
            ],
            term: ShellProcessController.ghosttyTerm,
            initialSize: TerminalViewportSize(columns: 80, rows: 24),
            startupCommand: command
        )
    }

    func spec(_ configuration: ShellProcessController.Configuration, device: RemoteLaunchSpec.Device) -> HostedLaunchSpec {
        RemoteLaunchSpec.make(for: configuration, device: device, localeEnvironment: [:])
    }
}

/// The line a device agent is told (it names the tab; no skill files there).
private func instructions(_ launch: DeviceAgentLaunch) -> String {
    AgentCLILaunch.instructionLine(processID: launch.tab.uuidString, hasSkill: false)
}

/// Claude Code's sandbox setting for the forwarded socket.
private let claudeSettings = #"{"sandbox":{"network":{"allowUnixSockets":["\#(socketPath)"]}}}"#

private func privateHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-mcp-launch-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return home
}

/// A stand-in agent CLI in `directory`: `--version` prints `<name>.version`
/// (nothing when there is none); otherwise it prints its pid, its parent's,
/// each argument and the token it was given, and exits with `<name>.exit`.
private func writeStandIn(_ name: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = """
    #!/bin/sh
    here=$(dirname "$0"); name=$(basename "$0")
    if [ "$1" = --version ]; then cat "$here/$name.version" 2>/dev/null; exit 0; fi
    printf 'pid=%s\\n' "$$"
    printf 'ppid=%s\\n' "$PPID"
    for word in "$@"; do printf 'arg=%s\\n' "$word"; done
    printf 'token=%s\\n' "${CHERRY_MCP_TOKEN-unset}"
    exit "$(cat "$here/$name.exit" 2>/dev/null || echo 0)"

    """
    let url = directory.appendingPathComponent(name)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// What the stand-in reports for `--version` (nil: nothing), and its exit status.
private func setStandIn(_ name: String, in directory: URL, version: String?, exitStatus: Int32 = 0) throws {
    let versionFile = directory.appendingPathComponent("\(name).version")
    try? FileManager.default.removeItem(at: versionFile)
    if let version { try (version + "\n").write(to: versionFile, atomically: true, encoding: .utf8) }
    try "\(exitStatus)\n".write(to: directory.appendingPathComponent("\(name).exit"), atomically: true, encoding: .utf8)
}

/// What a launch printed and how it ended.
private struct LaunchRun {
    var status: Int32
    var output: String
    /// The pid of the process the test started: the spec's shell.
    var processID: Int32

    private func values(_ prefix: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    var arguments: [String] { values("arg=") }
    var printedProcessID: Int32? { values("pid=").first.flatMap { Int32($0) } }
    var printedParentProcessID: Int32? { values("ppid=").first.flatMap { Int32($0) } }
    var token: String? { values("token=").first }
}

/// Runs `spec.argv` as the host would, with the spec's environment plus
/// what the host adds: a private HOME (and ZDOTDIR), so no developer's
/// startup file runs, and the host's PATH (the line sets the device's from
/// `CHERRY_LOGIN_PATH` after the startup files, which on a nix-darwin Mac
/// set PATH from scratch). Standard input is closed.
private func run(_ spec: HostedLaunchSpec, home: URL, timeout: TimeInterval = 20) throws -> LaunchRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: spec.argv[0])
    process.arguments = Array(spec.argv.dropFirst())
    process.environment = spec.environment.merging([
        "HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin", "USER": NSUserName(),
    ]) { _, host in host }
    process.currentDirectoryURL = home
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    try process.run()
    let processID = process.processIdentifier
    let box = PipeOutputBox()
    let group = DispatchGroup()
    RemoteDeviceShell.readToEnd(stdout.fileHandleForReading, into: box, group: group)
    if group.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = group.wait(timeout: .now() + 5)
    }
    process.waitUntilExit()
    return LaunchRun(status: process.terminationStatus, output: String(decoding: box.data, as: UTF8.self), processID: processID)
}

@Test func RemoteDeviceMCPLaunchGatedLineRunsUnderTheRealShells() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let agents = home.appendingPathComponent("agents", isDirectory: true)
    try writeStandIn("claude", in: agents)
    try writeStandIn("codex", in: agents)
    try writeStandIn("pi", in: agents)
    let nothing = home.appendingPathComponent("nothing", isDirectory: true)
    try FileManager.default.createDirectory(at: nothing, withIntermediateDirectories: true)
    // The install's `cherry`, which the line checks for (it does not run
    // here).
    let build = home.appendingPathComponent("cherry-host/bin/b1", isDirectory: true)
    let installedCLI = build.appendingPathComponent("cherry")
    try writeStandIn("cherry", in: build)
    let missingCLI = home.appendingPathComponent("cherry-host/bin/b0/cherry").path
    let launch = DeviceAgentLaunch()
    let line = instructions(launch)
    let testProcessID = getpid()

    for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
        /// `command` launched as an agent there, with the stand-ins (or
        /// nothing) on the device's login PATH.
        func launched(
            _ command: String, path: URL = agents, cli: String? = nil
        ) throws -> (spec: HostedLaunchSpec, run: LaunchRun) {
            let cli = cli ?? installedCLI.path
            let spec = launch.spec(
                launch.configuration(command, workingDirectory: home.path),
                device: launch.device(shell: shell, cli: cli, loginPath: "\(path.path):/usr/bin:/bin")
            )
            #expect(spec.argv.count == 4 && spec.argv[0] == shell && spec.argv[1] == "-l" && spec.argv[2] == "-c", "\(shell)")
            #expect(spec.argv[3].hasPrefix(
                "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; if [ -x '\(cli)' ] && "
            ), "\(shell)")
            return (spec, try run(spec, home: home))
        }

        // New enough: the flags, after the line's own words.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)")
        let claude = try launched("claude --dangerously-skip-permissions")
        #expect(claude.run.status == 0, "\(shell): \(claude.run.output)")
        #expect(claude.run.arguments == [
            "--dangerously-skip-permissions", "--append-system-prompt", line, "--settings", claudeSettings,
        ], "\(shell): \(claude.run.output)")
        // The shell was replaced by the agent (`exec`): the session's
        // program is the agent itself.
        #expect(claude.run.printedProcessID == claude.run.processID, "\(shell): \(claude.run.output)")
        #expect(claude.run.printedParentProcessID == testProcessID, "\(shell): \(claude.run.output)")
        // Its token reached it, and is still the tab's current one: the
        // launch made one generation, not two.
        let token = try #require(claude.spec.environment["CHERRY_MCP_TOKEN"])
        #expect(claude.run.token == token, "\(shell)")
        #expect(launch.tokens.isValid(token, tabID: launch.tab, deviceID: launch.deviceID), "\(shell)")
        #expect(!claude.spec.argv.contains { $0.contains(token) }, "\(shell)")

        // The minimum itself.
        try setStandIn("claude", in: agents, version: "2.1.0")
        #expect(try launched("claude").run.arguments.first == "--append-system-prompt", "\(shell)")

        // Older, or no version: the line exactly, still exec'd.
        try setStandIn("claude", in: agents, version: "2.0.9 (Claude Code)")
        let older = try launched("claude --dangerously-skip-permissions")
        #expect(older.run.status == 0, "\(shell): \(older.run.output)")
        #expect(older.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(older.run.output)")
        #expect(older.run.printedProcessID == older.run.processID, "\(shell): \(older.run.output)")
        try setStandIn("claude", in: agents, version: nil)
        let unknown = try launched("claude --dangerously-skip-permissions")
        #expect(unknown.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(unknown.run.output)")

        // An install without its `cherry`: the line exactly, though the
        // CLI is new enough.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)")
        let noCLI = try launched("claude --dangerously-skip-permissions", cli: missingCLI)
        #expect(noCLI.run.status == 0, "\(shell): \(noCLI.run.output)")
        #expect(noCLI.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(noCLI.run.output)")

        // A positional prompt keeps its place, before the flags.
        let prompt = try launched("claude \"fix it\"")
        #expect(prompt.run.arguments.first == "fix it" && prompt.run.arguments.dropFirst().first == "--append-system-prompt", "\(shell): \(prompt.run.output)")

        // Codex: its developer instructions, while its config there sets none.
        try setStandIn("codex", in: agents, version: "codex-cli 0.162.1")
        let codex = try launched("codex --yolo")
        #expect(codex.run.status == 0, "\(shell): \(codex.run.output)")
        #expect(codex.run.arguments == ["--yolo", "-c", "developer_instructions=" + AgentLaunch.tomlString(line)], "\(shell): \(codex.run.output)")
        #expect(codex.run.printedProcessID == codex.run.processID, "\(shell): \(codex.run.output)")
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "model = \"o3\"\n  developer_instructions = \"be brief\"\n".write(
            to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        #expect(try launched("codex --yolo").run.arguments == ["--yolo"], "\(shell)")
        try "model = \"o3\"\n# developer_instructions = \"x\"\n".write(
            to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        #expect(try launched("codex").run.arguments == ["-c", "developer_instructions=" + AgentLaunch.tomlString(line)], "\(shell)")
        try FileManager.default.removeItem(at: codexHome)
        try setStandIn("codex", in: agents, version: "codex-cli 0.161.9")
        #expect(try launched("codex --yolo").run.arguments == ["--yolo"], "\(shell)")

        // Pi: the line.
        try setStandIn("pi", in: agents, version: "1.3.0")
        #expect(try launched("pi --model x").run.arguments == ["--model", "x", "--append-system-prompt", line], "\(shell)")
        try setStandIn("pi", in: agents, version: "0.99.1")
        #expect(try launched("pi").run.arguments.isEmpty, "\(shell)")

        // The agent's exit status passes through, either way.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)", exitStatus: 7)
        #expect(try launched("claude").run.status == 7, "\(shell)")
        try setStandIn("claude", in: agents, version: "1.0.0", exitStatus: 5)
        #expect(try launched("claude").run.status == 5, "\(shell)")

        // No such CLI on the device's PATH: 127, as today's line.
        let missing = try launched("claude", path: nothing)
        #expect(missing.run.status == 127, "\(shell): \(missing.run.output)")
        #expect(missing.run.arguments.isEmpty, "\(shell): \(missing.run.output)")
    }
}

@Test func RemoteDeviceMCPLaunchVersionCheckReadsVersionsAsAgentCLIVersionDoes() throws {
    let outputs = [
        "2.1.299 (Claude Code)", "2.1.0", "2.0.9", "1.9.9 (Claude Code)", "10.0.0",
        "codex-cli 0.162.1", "codex-cli 0.162.0", "codex-cli 0.161.9", "codex-cli 1.0.0",
        "garbage", "", "2.1", "warning: node 1.2\nclaude 3.0.0", "v2.1.0-beta.1", "0.162.0.4",
        "1.3.0", "0.99.2", "0.99.1", "0.62.0",
    ]
    for cli in AgentLaunch.CLI.allCases {
        let program = RemoteAgentLaunch.versionCheck(minimum: cli.minimumVersion)
        for output in outputs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
            process.arguments = [program]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data((output + "\n").utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let expected = AgentCLIVersion(versionOutput: output).map { $0 >= cli.minimumVersion } ?? false
            #expect((process.terminationStatus == 0) == expected, "\(cli) \(output.debugDescription)")
        }
    }
}

@Test func RemoteDeviceMCPLaunchKeepsTodaysLineForEveryOtherLaunch() {
    let launch = DeviceAgentLaunch()
    /// The spec with the switch on is the spec with it off: the same argv,
    /// and the same environment (but the token, new for each launch).
    func keepsTodaysLine(
        _ command: String?,
        agent: Bool = true,
        device: RemoteLaunchSpec.Device? = nil,
        _ comment: Comment
    ) {
        let device = device ?? launch.device()
        var off = device
        off.connectsAgentsAtLaunch = false
        let configuration = launch.configuration(command, agent: agent)
        let on = launch.spec(configuration, device: device)
        let today = launch.spec(configuration, device: off)
        #expect(on.argv == today.argv, comment)
        #expect(on.environment.filter { $0.key != "CHERRY_MCP_TOKEN" } == today.environment.filter { $0.key != "CHERRY_MCP_TOKEN" }, comment)
        #expect(!on.argv.contains { $0.contains("cherry_v") || $0.contains(cliPath) }, comment)
    }

    // Shells whose syntax the check is not written in.
    for shell in ["/opt/homebrew/bin/fish", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/nu"] {
        keepsTodaysLine("claude", device: launch.device(shell: shell), "\(shell)")
        keepsTodaysLine("codex --yolo", device: launch.device(shell: shell), "\(shell)")
    }
    let fish = launch.spec(launch.configuration("claude"), device: launch.device(shell: "/opt/homebrew/bin/fish"))
    #expect(fish.argv.last == "set -gx PATH (string split ':' \"$CHERRY_LOGIN_PATH\"); set -e CHERRY_LOGIN_PATH; claude")
    // No `cherry` in the install (no resources), or no forwarded socket
    // at all.
    keepsTodaysLine("claude", device: launch.device(cli: nil), "no cherry")
    var withoutMCP = launch.device()
    withoutMCP.mcp = nil
    keepsTodaysLine("claude", device: withoutMCP, "no forward")
    let plain = launch.spec(launch.configuration("claude"), device: withoutMCP)
    #expect(plain.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; claude"])
    // A terminal, and a command that runs claude (not an agent).
    keepsTodaysLine(nil, "terminal")
    keepsTodaysLine("claude", agent: false, "command")
    // Not a plain claude, codex or pi command, a subcommand that starts no
    // session, a last option missing its value, or one that sets its own
    // instructions (Codex and Pi then have nothing to add).
    for command in [
        "npx claude", "FOO=1 claude", "claude && x", "claude | tee log", "claude -- x", "claude $(cat prompt)",
        "claude mcp list", "claude update", "codex login", "codex mcp-server", "gemini", "/bin/cat",
        "pi install npm:x", "pi --model", "codex -c developer_instructions=mine", "pi --system-prompt mine",
    ] {
        keepsTodaysLine(command, "\(command)")
    }

    // A tab without the forwarded socket: `cherry` there would look for
    // that Mac's own Cherry.
    #expect(RemoteAgentLaunch.outcome(
        line: "claude", shell: "/bin/zsh", device: launch.device(), environment: [:]
    ) == .skipped("the tab has no forwarded control socket"))
    #expect(RemoteAgentLaunch.outcome(
        line: "claude", shell: "/bin/zsh", device: launch.device(),
        environment: ["CHERRY_CONTROL_SOCKET": "/tmp/cherry-501/Cherry-x/control.sock"]
    ) == .skipped("the tab has no forwarded control socket"))

    // The switch off is today's line exactly.
    let off = launch.spec(launch.configuration("codex --yolo"), device: launch.device(connects: false))
    #expect(off.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; codex --yolo"])
    // And `RemoteLaunchSpec.Device`'s default is off.
    #expect(RemoteLaunchSpec.Device().connectsAgentsAtLaunch == false)
}

@Test func RemoteDeviceMCPLaunchNamesTheDevicesSocketAndKeepsTheTokenOffTheLine() throws {
    let launch = DeviceAgentLaunch()
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let observer = SessionLog.observe { entry in seen.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(observer) }
    let claude = launch.spec(launch.configuration("claude --dangerously-skip-permissions"), device: launch.device())
    let words = AgentLaunch.shellSuffix(["--append-system-prompt", instructions(launch), "--settings", claudeSettings])
    // The log names the flags, never the agent's own words.
    let logged = seen.withLock { $0 }.filter { $0.hasPrefix("[agent] device tab \(launch.tab.uuidString) ") }
    #expect(logged.count == 1)
    #expect(logged.first?.hasSuffix("new enough:" + words) == true)
    #expect(logged.first?.contains("dangerously") == false)
    let line = try #require(claude.argv.last)
    let token = try #require(claude.environment["CHERRY_MCP_TOKEN"])
    #expect(launch.tokens.isValid(token, tabID: launch.tab, deviceID: launch.deviceID))
    // Nothing of This Mac's, and never the token.
    #expect(!line.contains("/Applications/") && !line.contains("/tmp/cherry-") && !line.contains(token))
    #expect(line == "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; "
        + RemoteAgentLaunch.gatedLine(
            line: "claude --dangerously-skip-permissions", executableWord: "claude", cli: .claudeCode,
            checks: ["[ -x \(ShellQuoting.singleQuoted(cliPath)) ]"],
            suffix: words
        ))
    #expect(line.contains("then exec claude --dangerously-skip-permissions\(words); else exec claude --dangerously-skip-permissions; fi"))
    // The environment is the spec's as before: the device's socket, the
    // install's `cherry`.
    #expect(claude.environment["CHERRY_CONTROL_SOCKET"] == socketPath)
    #expect(claude.environment["CHERRY_MCP_HELPER"] == nil)
    #expect(claude.environment["CHERRY_CLI"] == cliPath)

    // Codex's line checks its config there first.
    let codex = launch.spec(launch.configuration("codex --yolo"), device: launch.device())
    let codexLine = try #require(codex.argv.last)
    #expect(codexLine.contains(RemoteAgentLaunch.codexSetsNoInstructions))
    #expect(!codexLine.contains(try #require(codex.environment["CHERRY_MCP_TOKEN"])) && !codexLine.contains(socketPath))

    // Without the device's login environment the line is the gated one
    // alone (the host's PATH, for the check and the agent alike).
    let unread = launch.spec(launch.configuration("claude"), device: launch.device(loginPath: nil))
    #expect(unread.argv.last?.hasPrefix("if [ -x '\(cliPath)' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && ") == true)
    // A `~/` executable expands in the check as in the line.
    let home = launch.spec(launch.configuration("~/.local/bin/claude"), device: launch.device())
    #expect(home.argv.last?.contains("&& cherry_v=$(~/'.local/bin/claude' --version") == true)
    #expect(home.argv.last?.contains("then exec ~/.local/bin/claude '--append-system-prompt'") == true)
}

/// A switch the store asks at each launch.
@MainActor
private final class LaunchSwitch {
    var isOn = true
}
@Test @MainActor func RemoteDeviceMCPLaunchDeviceStoreConnectsAgentsOnlyWhenToldTo() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ch-mcplaunch-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "CherryTests.RemoteMCPLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let installation = UUID()
    func store(connectsAgentsAtLaunch: (@MainActor () -> Bool)? = nil, name: String) throws -> RemoteDeviceStore {
        let fileURL = directory.appendingPathComponent("\(name).json")
        let registry = PersistentHostingRegistry(
            local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())
        )
        if let connectsAgentsAtLaunch {
            return RemoteDeviceStore(
                fileURL: fileURL, hostStore: HostedSessionHostStore(defaults: defaults),
                installationID: { installation }, registry: registry, remoteHostPaths: HostedRemoteHostPaths(),
                connectsAgentsAtLaunch: connectsAgentsAtLaunch
            )
        }
        return RemoteDeviceStore(
            fileURL: fileURL, hostStore: HostedSessionHostStore(defaults: defaults),
            installationID: { installation }, registry: registry, remoteHostPaths: HostedRemoteHostPaths()
        )
    }
    func addStudio(to store: RemoteDeviceStore) throws -> RemoteDevice {
        try store.add(
            name: "Studio", sshDestination: "studio-\(UUID().uuidString.prefix(6))",
            remoteHostPath: "~/Library/Application Support/cherry-host/bin/b1/cherry-host",
            homeDirectory: "/Users/them", installedBuild: "b1", shell: "/bin/zsh", installedResources: true,
            userTemporaryDirectory: "/var/folders/8s/f8v56gzs3232x21hn7nngwmc0000gn/T/"
        )
    }
    let launch = DeviceAgentLaunch()

    // A test's store, as every other device test builds it: never.
    let plain = try store(name: "plain")
    let device = try addStudio(to: plain)
    let plainLaunch = try #require(plain.launchDevice(id: device.id))
    #expect(plainLaunch.connectsAgentsAtLaunch == false)
    #expect(plainLaunch.mcp?.cliPath == cliPath)
    let today = RemoteLaunchSpec.make(for: launch.configuration("claude"), device: plainLaunch, localeEnvironment: [:])
    #expect(today.argv == ["/bin/zsh", "-l", "-c", "claude"])

    // A store told to: as its switch says at each launch.
    let toggle = LaunchSwitch()
    let connecting = try store(connectsAgentsAtLaunch: { toggle.isOn }, name: "connecting")
    let studio = try addStudio(to: connecting)
    let on = try #require(connecting.launchDevice(id: studio.id))
    #expect(on.connectsAgentsAtLaunch)
    let gated = RemoteLaunchSpec.make(for: launch.configuration("claude"), device: on, localeEnvironment: [:])
    #expect(gated.argv.last?.hasPrefix("if [ -x '\(cliPath)' ] && cherry_v=$('claude' --version") == true)
    #expect(gated.argv.last?.contains("'--append-system-prompt'") == true)
    toggle.isOn = false
    #expect(connecting.launchDevice(id: studio.id)?.connectsAgentsAtLaunch == false)
}
