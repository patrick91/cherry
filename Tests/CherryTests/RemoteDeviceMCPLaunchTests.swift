import CherryControl
import CryptoKit
import Darwin
import Foundation
import os
import Testing
@testable import Cherry

// Cherry MCP on the command line of the agents Cherry starts on another Mac
// (`RemoteAgentMCPLaunch`): the line that asks the CLI's version there, run
// under the real shells with stand-in `claude`, `codex` and `pi` scripts in
// a private HOME (never a real agent CLI), the flags and variables it
// carries, and every launch that keeps today's line exactly.

private let helperPath = "/Users/them/Library/Application Support/cherry-host/bin/b1/CherryMCP"
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
        helper: String? = helperPath,
        piExtension: String? = nil,
        loginPath: String? = "/Users/them/.local/bin:/usr/bin:/bin",
        connects: Bool = true
    ) -> RemoteLaunchSpec.Device {
        RemoteLaunchSpec.Device(
            shell: shell,
            homeDirectory: "/Users/them",
            mcp: RemoteMCPLaunch(
                deviceID: deviceID, socketPath: socketPath, helperPath: helper, cliPath: cliPath,
                piExtensionPath: piExtension, controlMachine: "Laptop", tokens: tokens
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

private var serverName: String { CherryAppIdentity.current.urlScheme }

/// Claude Code's `--mcp-config` value for the device's helper.
private struct ClaudeMCPConfig: Decodable, Equatable {
    struct Server: Decodable, Equatable {
        let type: String
        let command: String
        let args: [String]
    }
    let mcpServers: [String: Server]
}

/// Codex's `-c` value for the device's helper, character for character.
private func codexTable(keys: [String], helper: String = helperPath) -> String {
    "mcp_servers.\(serverName)={command=\"\(helper)\",args=[\"--client-tool-timeout\",\"300\"],"
        + "env_vars=[\(keys.map { "\"\($0)\"" }.joined(separator: ","))],startup_timeout_sec=30,tool_timeout_sec=300}"
}

/// Every Cherry variable a device agent's launch sets, in `env_vars`' order.
private let allKeys = [
    "CHERRY_PROCESS_ID", "CHERRY_AGENT_ID", "CHERRY_PROJECT_ROOT", "CHERRY_CONTROL_SOCKET",
    "CHERRY_CONTROL_MACHINE", "CHERRY_MCP_TOKEN", "CHERRY_MCP_HELPER", "CHERRY_CLI",
]

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

/// The suffix's `--mcp-config` value, decoded.
private func claudeConfig(_ arguments: [String]) throws -> ClaudeMCPConfig {
    let index = try #require(arguments.firstIndex(of: "--mcp-config"))
    let json = try #require(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
    return try JSONDecoder().decode(ClaudeMCPConfig.self, from: Data(json.utf8))
}

@Test func RemoteDeviceMCPLaunchGatedLineRunsUnderTheRealShells() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let agents = home.appendingPathComponent("agents", isDirectory: true)
    try writeStandIn("claude", in: agents)
    try writeStandIn("codex", in: agents)
    let nothing = home.appendingPathComponent("nothing", isDirectory: true)
    try FileManager.default.createDirectory(at: nothing, withIntermediateDirectories: true)
    // The install's CherryMCP, which the line checks for (it never runs).
    let installedHelper = home.appendingPathComponent("cherry-host/bin/b1/CherryMCP")
    try writeStandIn("CherryMCP", in: installedHelper.deletingLastPathComponent())
    let missingHelper = home.appendingPathComponent("cherry-host/bin/b0/CherryMCP").path
    let launch = DeviceAgentLaunch()
    let expectedConfig = ClaudeMCPConfig(mcpServers: [serverName: .init(type: "stdio", command: installedHelper.path, args: [])])
    let testProcessID = getpid()

    for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
        /// `command` launched as an agent there, with the stand-ins (or
        /// nothing) on the device's login PATH.
        func launched(
            _ command: String, path: URL = agents, helper: String? = nil
        ) throws -> (spec: HostedLaunchSpec, run: LaunchRun) {
            let helper = helper ?? installedHelper.path
            let spec = launch.spec(
                launch.configuration(command, workingDirectory: home.path),
                device: launch.device(shell: shell, helper: helper, loginPath: "\(path.path):/usr/bin:/bin")
            )
            #expect(spec.argv.count == 4 && spec.argv[0] == shell && spec.argv[1] == "-l" && spec.argv[2] == "-c", "\(shell)")
            #expect(spec.argv[3].hasPrefix("export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; if [ -x '\(helper)' ] && cherry_v=$("), "\(shell)")
            return (spec, try run(spec, home: home))
        }

        // New enough: the flags, after the line's own words, naming the
        // device's helper.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)")
        let claude = try launched("claude --dangerously-skip-permissions")
        #expect(claude.run.status == 0, "\(shell): \(claude.run.output)")
        #expect(claude.run.arguments.count == 3 && claude.run.arguments.first == "--dangerously-skip-permissions", "\(shell): \(claude.run.output)")
        #expect(claude.run.arguments.dropFirst().first == "--mcp-config", "\(shell): \(claude.run.output)")
        #expect(try claudeConfig(claude.run.arguments) == expectedConfig, "\(shell)")
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
        try setStandIn("claude", in: agents, version: "2.0.0")
        let minimum = try launched("claude")
        #expect(minimum.run.arguments.first == "--mcp-config" && minimum.run.arguments.count == 2, "\(shell): \(minimum.run.output)")

        // Older, or no version: the line exactly, still exec'd.
        try setStandIn("claude", in: agents, version: "1.9.9 (Claude Code)")
        let older = try launched("claude --dangerously-skip-permissions")
        #expect(older.run.status == 0, "\(shell): \(older.run.output)")
        #expect(older.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(older.run.output)")
        #expect(older.run.printedProcessID == older.run.processID, "\(shell): \(older.run.output)")
        try setStandIn("claude", in: agents, version: nil)
        let unknown = try launched("claude --dangerously-skip-permissions")
        #expect(unknown.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(unknown.run.output)")

        // An install without its CherryMCP: the line exactly, though the
        // CLI is new enough, so a registration Set Up made still serves it.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)")
        let noHelper = try launched("claude --dangerously-skip-permissions", helper: missingHelper)
        #expect(noHelper.run.status == 0, "\(shell): \(noHelper.run.output)")
        #expect(noHelper.run.arguments == ["--dangerously-skip-permissions"], "\(shell): \(noHelper.run.output)")
        #expect(noHelper.run.printedProcessID == noHelper.run.processID, "\(shell): \(noHelper.run.output)")

        // A positional prompt keeps its place, before the flags.
        try setStandIn("claude", in: agents, version: "2.1.299 (Claude Code)")
        let prompt = try launched("claude \"fix it\"")
        #expect(prompt.run.arguments.first == "fix it" && prompt.run.arguments.dropFirst().first == "--mcp-config", "\(shell): \(prompt.run.output)")

        // Codex: the inline table, with the variables it passes on.
        try setStandIn("codex", in: agents, version: "codex-cli 0.162.1")
        let codex = try launched("codex --yolo")
        #expect(codex.run.status == 0, "\(shell): \(codex.run.output)")
        #expect(codex.run.arguments == ["--yolo", "-c", codexTable(keys: allKeys, helper: installedHelper.path)], "\(shell): \(codex.run.output)")
        #expect(codex.run.printedProcessID == codex.run.processID, "\(shell): \(codex.run.output)")
        try setStandIn("codex", in: agents, version: "codex-cli 0.161.9")
        let olderCodex = try launched("codex --yolo")
        #expect(olderCodex.run.arguments == ["--yolo"], "\(shell): \(olderCodex.run.output)")

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

/// A Pi agent's line also checks the install's copy of Cherry's Pi
/// extension, which an install made before Cherry had it lacks.
@Test func RemoteDeviceMCPLaunchPiGatedLineRunsUnderTheRealShells() throws {
    let home = try privateHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let agents = home.appendingPathComponent("agents", isDirectory: true)
    try writeStandIn("pi", in: agents)
    let nothing = home.appendingPathComponent("nothing", isDirectory: true)
    try FileManager.default.createDirectory(at: nothing, withIntermediateDirectories: true)
    // The install's CherryMCP and extension, which the line checks for
    // (neither runs here).
    let build = home.appendingPathComponent("cherry-host/bin/b1", isDirectory: true)
    let installedHelper = build.appendingPathComponent("CherryMCP")
    try writeStandIn("CherryMCP", in: build)
    let installedExtension = build.appendingPathComponent("cherry-pi-mcp.ts")
    let launch = DeviceAgentLaunch()
    let testProcessID = getpid()

    for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] where FileManager.default.isExecutableFile(atPath: shell) {
        /// `command` launched as an agent there, with the stand-in (or
        /// nothing) on the device's login PATH.
        func launched(_ command: String, path: URL = agents) throws -> (spec: HostedLaunchSpec, run: LaunchRun) {
            let spec = launch.spec(
                launch.configuration(command, workingDirectory: home.path),
                device: launch.device(
                    shell: shell, helper: installedHelper.path, piExtension: installedExtension.path,
                    loginPath: "\(path.path):/usr/bin:/bin"
                )
            )
            #expect(spec.argv.count == 4 && spec.argv[0] == shell && spec.argv[1] == "-l" && spec.argv[2] == "-c", "\(shell)")
            #expect(spec.argv[3].hasPrefix(
                "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; if [ -x '\(installedHelper.path)' ] && [ -r '\(installedExtension.path)' ] && cherry_v=$('pi' --version"
            ), "\(shell): \(spec.argv[3])")
            #expect(spec.environment["CHERRY_MCP_SERVER_NAME"] == serverName, "\(shell)")
            #expect(spec.environment["CHERRY_MCP_HELPER"] == installedHelper.path, "\(shell)")
            return (spec, try run(spec, home: home))
        }

        // Pi 1.3.0 with both files: the extension, after its own words.
        try "export default function cherryMCP(pi) {}\n".write(to: installedExtension, atomically: true, encoding: .utf8)
        try setStandIn("pi", in: agents, version: "1.3.0")
        let pi = try launched("pi --model x")
        #expect(pi.run.status == 0, "\(shell): \(pi.run.output)")
        #expect(pi.run.arguments == ["--model", "x", "-e", installedExtension.path], "\(shell): \(pi.run.output)")
        // `exec`: the session's program is Pi itself.
        #expect(pi.run.printedProcessID == pi.run.processID, "\(shell): \(pi.run.output)")
        #expect(pi.run.printedParentProcessID == testProcessID, "\(shell): \(pi.run.output)")
        // Its token reached it and is still the tab's current one, never on the line.
        let token = try #require(pi.spec.environment["CHERRY_MCP_TOKEN"])
        #expect(pi.run.token == token, "\(shell)")
        #expect(launch.tokens.isValid(token, tabID: launch.tab, deviceID: launch.deviceID), "\(shell)")
        #expect(!pi.spec.argv.contains { $0.contains(token) }, "\(shell)")
        // The minimum itself.
        try setStandIn("pi", in: agents, version: "0.99.2")
        #expect(try launched("pi").run.arguments == ["-e", installedExtension.path], "\(shell)")

        // An older Pi, or one that prints no version: the line exactly.
        try setStandIn("pi", in: agents, version: "0.62.0")
        let old = try launched("pi --model x")
        #expect(old.run.status == 0, "\(shell): \(old.run.output)")
        #expect(old.run.arguments == ["--model", "x"], "\(shell): \(old.run.output)")
        #expect(old.run.printedProcessID == old.run.processID, "\(shell): \(old.run.output)")
        try setStandIn("pi", in: agents, version: "0.99.1")
        #expect(try launched("pi").run.arguments.isEmpty, "\(shell)")
        try setStandIn("pi", in: agents, version: nil)
        #expect(try launched("pi").run.arguments.isEmpty, "\(shell)")

        // An install without the extension (made before Cherry had it):
        // the line exactly, though Pi is new enough.
        try FileManager.default.removeItem(at: installedExtension)
        try setStandIn("pi", in: agents, version: "1.3.0")
        let noExtension = try launched("pi --model x")
        #expect(noExtension.run.status == 0, "\(shell): \(noExtension.run.output)")
        #expect(noExtension.run.arguments == ["--model", "x"], "\(shell): \(noExtension.run.output)")
        #expect(noExtension.run.printedProcessID == noExtension.run.processID, "\(shell): \(noExtension.run.output)")

        // No pi on the device's PATH: 127, as today's line.
        try "export default function cherryMCP(pi) {}\n".write(to: installedExtension, atomically: true, encoding: .utf8)
        let missing = try launched("pi", path: nothing)
        #expect(missing.run.status == 127, "\(shell): \(missing.run.output)")
        #expect(missing.run.arguments.isEmpty, "\(shell): \(missing.run.output)")
    }

    // Under fish or csh, and without the extension in the device's
    // record (no resources), today's line.
    for shell in ["/opt/homebrew/bin/fish", "/bin/csh"] {
        let device = launch.device(shell: shell, piExtension: "/Users/them/Library/Application Support/cherry-host/bin/b1/cherry-pi-mcp.ts")
        var off = device
        off.connectsAgentsAtLaunch = false
        let configuration = launch.configuration("pi --model x")
        #expect(launch.spec(configuration, device: device).argv == launch.spec(configuration, device: off).argv, "\(shell)")
    }
    #expect(RemoteAgentMCPLaunch.outcome(
        line: "pi", shell: "/bin/zsh", device: launch.device(), environment: ["CHERRY_CONTROL_SOCKET": socketPath], serverName: serverName
    ) == .skipped("the Mac's session host has no Pi extension"))
    let plain = launch.spec(launch.configuration("pi --model x"), device: launch.device())
    #expect(plain.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; pi --model x"])
    // `--no-mcp`, `-ne` and Pi's other commands keep today's line too.
    // So does a last option missing its value, which would take `-e` and
    // make the extension's path a prompt.
    for command in ["pi --no-mcp", "pi -ne", "pi install npm:x", "pi mcp list", "pi --model", "pi -e"] {
        let device = launch.device(piExtension: "/Users/them/Library/Application Support/cherry-host/bin/b1/cherry-pi-mcp.ts")
        #expect(launch.spec(launch.configuration(command), device: device).argv.last?.contains("cherry_v") == false, "\(command)")
    }
}

@Test func RemoteDeviceMCPLaunchVersionCheckReadsVersionsAsAgentCLIVersionDoes() throws {
    let outputs = [
        "2.1.299 (Claude Code)", "2.0.0", "1.99.99", "1.9.9 (Claude Code)", "10.0.0",
        "codex-cli 0.162.1", "codex-cli 0.162.0", "codex-cli 0.161.9", "codex-cli 1.0.0",
        "garbage", "", "2.1", "warning: node 1.2\nclaude 3.0.0", "v2.0.0-beta.1", "0.162.0.4",
        "1.3.0", "0.99.2", "0.99.1", "0.62.0",
    ]
    for cli in AgentMCPLaunch.CLI.allCases {
        let program = RemoteAgentMCPLaunch.versionCheck(minimum: cli.minimumVersion)
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
        #expect(!on.argv.contains { $0.contains("cherry_v") || $0.contains(helperPath) }, comment)
    }

    // Shells whose syntax the check is not written in.
    for shell in ["/opt/homebrew/bin/fish", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/nu"] {
        keepsTodaysLine("claude", device: launch.device(shell: shell), "\(shell)")
        keepsTodaysLine("codex --yolo", device: launch.device(shell: shell), "\(shell)")
    }
    let fish = launch.spec(launch.configuration("claude"), device: launch.device(shell: "/opt/homebrew/bin/fish"))
    #expect(fish.argv.last == "set -gx PATH (string split ':' \"$CHERRY_LOGIN_PATH\"); set -e CHERRY_LOGIN_PATH; claude")
    // No CherryMCP in the install (no resources), or no Cherry MCP at all.
    keepsTodaysLine("claude", device: launch.device(helper: nil), "no helper")
    var withoutMCP = launch.device()
    withoutMCP.mcp = nil
    keepsTodaysLine("claude", device: withoutMCP, "no Cherry MCP")
    let plain = launch.spec(launch.configuration("claude"), device: withoutMCP)
    #expect(plain.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; claude"])
    // A helper path no single quote can carry.
    keepsTodaysLine("claude", device: launch.device(helper: "/Users/o'brien/Library/Application Support/cherry-host/bin/b1/CherryMCP"), "quote")
    keepsTodaysLine("claude", device: launch.device(helper: "/Users/them/b\\1/CherryMCP"), "backslash")
    // A terminal, and a command that runs claude (not an agent).
    keepsTodaysLine(nil, "terminal")
    keepsTodaysLine("claude", agent: false, "command")
    // Not a plain claude or codex command, one with its own MCP
    // configuration, or a subcommand that starts no session.
    for command in [
        "npx claude", "FOO=1 claude", "claude && x", "claude | tee log", "claude -- x", "claude $(cat prompt)",
        "claude --mcp-config f", "claude --strict-mcp-config", "codex -c 'mcp_servers.x.command=\"y\"'",
        "claude mcp list", "claude update", "codex login", "codex mcp-server", "pi", "gemini", "/bin/cat",
    ] {
        keepsTodaysLine(command, "\(command)")
    }

    // A tab without the forwarded socket: CherryMCP there would look for
    // that Mac's own Cherry.
    #expect(RemoteAgentMCPLaunch.outcome(
        line: "claude", shell: "/bin/zsh", device: launch.device(), environment: [:], serverName: serverName
    ) == .skipped("the tab has no forwarded control socket"))
    #expect(RemoteAgentMCPLaunch.outcome(
        line: "claude", shell: "/bin/zsh", device: launch.device(),
        environment: ["CHERRY_CONTROL_SOCKET": "/tmp/cherry-501/Cherry-x/control.sock"], serverName: serverName
    ) == .skipped("the tab has no forwarded control socket"))

    // The switch off is today's line exactly.
    let off = launch.spec(launch.configuration("codex --yolo"), device: launch.device(connects: false))
    #expect(off.argv == ["/bin/zsh", "-l", "-c", "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; codex --yolo"])
    // And `RemoteLaunchSpec.Device`'s default is off.
    #expect(RemoteLaunchSpec.Device().connectsAgentsAtLaunch == false)
}

@Test func RemoteDeviceMCPLaunchNamesTheDevicesHelperAndKeepsTheTokenOffTheLine() throws {
    let launch = DeviceAgentLaunch()
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let observer = SessionLog.observe { entry in seen.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(observer) }
    let claude = launch.spec(launch.configuration("claude --dangerously-skip-permissions"), device: launch.device())
    // The log names the flags, never the agent's own words.
    let logged = seen.withLock { $0 }.filter { $0.hasPrefix("[mcp] device tab \(launch.tab.uuidString) ") }
    #expect(logged.count == 1)
    #expect(logged.first?.hasSuffix("new enough: '--mcp-config' '{\"mcpServers\":{\"\(serverName)\":{\"args\":[],\"command\":\"\(helperPath)\",\"type\":\"stdio\"}}}'") == true)
    #expect(logged.first?.contains("dangerously") == false)
    let line = try #require(claude.argv.last)
    let token = try #require(claude.environment["CHERRY_MCP_TOKEN"])
    #expect(launch.tokens.isValid(token, tabID: launch.tab, deviceID: launch.deviceID))
    // Nothing of This Mac's, and never the token.
    #expect(!line.contains("/Applications/") && !line.contains("/tmp/cherry-") && !line.contains(token))
    let words = AgentMCPLaunch.shellSuffix(try #require(AgentMCPLaunch.arguments(
        for: .claudeCode, serverName: serverName, helperPath: helperPath, environmentKeys: []
    )))
    #expect(line == "export PATH=\"$CHERRY_LOGIN_PATH\"; unset CHERRY_LOGIN_PATH; "
        + RemoteAgentMCPLaunch.gatedLine(
            line: "claude --dangerously-skip-permissions", executableWord: "claude", cli: .claudeCode,
            requiredFiles: [(test: "-x", path: helperPath)], suffix: words
        ))
    #expect(line.contains("then exec claude --dangerously-skip-permissions '--mcp-config' '{\"mcpServers\":{\"\(serverName)\":{\"args\":[],\"command\":\"\(helperPath)\",\"type\":\"stdio\"}}}'; else exec claude --dangerously-skip-permissions; fi"))
    // The environment is the spec's as before: the device's socket and
    // helper, the install's `cherry`.
    #expect(claude.environment["CHERRY_CONTROL_SOCKET"] == socketPath)
    #expect(claude.environment["CHERRY_MCP_HELPER"] == helperPath)
    #expect(claude.environment["CHERRY_CLI"] == cliPath)

    // Codex is told the names of the variables the launch set, the token's
    // among them, and none of their values.
    let codex = launch.spec(launch.configuration("codex --yolo"), device: launch.device())
    let codexLine = try #require(codex.argv.last)
    let codexToken = try #require(codex.environment["CHERRY_MCP_TOKEN"])
    #expect(launch.tokens.isValid(codexToken, tabID: launch.tab, deviceID: launch.deviceID))
    #expect(codexLine.contains("then exec codex --yolo '-c' '\(codexTable(keys: allKeys))'; else exec codex --yolo; fi"))
    #expect(!codexLine.contains(codexToken) && !codexLine.contains(socketPath))
    // Only the ones it set: no project root, no token for a tab id that is
    // not a tab's.
    let noProject = launch.spec(launch.configuration("codex", projectPath: nil), device: launch.device())
    #expect(noProject.argv.last?.contains(codexTable(keys: allKeys.filter { $0 != "CHERRY_PROJECT_ROOT" })) == true)
    let notATab = launch.spec(launch.configuration("codex", processID: "agent-1"), device: launch.device())
    #expect(notATab.environment["CHERRY_MCP_TOKEN"] == nil)
    #expect(notATab.argv.last?.contains(codexTable(keys: allKeys.filter { $0 != "CHERRY_MCP_TOKEN" })) == true)

    // Without the device's login environment the line is the gated one
    // alone (the host's PATH, for the check and the agent alike).
    let unread = launch.spec(launch.configuration("claude"), device: launch.device(loginPath: nil))
    #expect(unread.argv.last?.hasPrefix("if [ -x '\(helperPath)' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && ") == true)
    // A `~/` executable expands in the check as in the line.
    let home = launch.spec(launch.configuration("~/.local/bin/claude"), device: launch.device())
    #expect(home.argv.last?.contains("&& cherry_v=$(~/'.local/bin/claude' --version") == true)
    #expect(home.argv.last?.contains("then exec ~/.local/bin/claude '--mcp-config'") == true)
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
    #expect(plainLaunch.mcp?.helperPath == helperPath)
    let today = RemoteLaunchSpec.make(for: launch.configuration("claude"), device: plainLaunch, localeEnvironment: [:])
    #expect(today.argv == ["/bin/zsh", "-l", "-c", "claude"])

    // A store told to: as its switch says at each launch.
    let toggle = LaunchSwitch()
    let connecting = try store(connectsAgentsAtLaunch: { toggle.isOn }, name: "connecting")
    let studio = try addStudio(to: connecting)
    let on = try #require(connecting.launchDevice(id: studio.id))
    #expect(on.connectsAgentsAtLaunch)
    let gated = RemoteLaunchSpec.make(for: launch.configuration("claude"), device: on, localeEnvironment: [:])
    #expect(gated.argv.last?.hasPrefix("if [ -x '\(helperPath)' ] && cherry_v=$('claude' --version") == true)
    #expect(gated.argv.last?.contains("\"command\":\"\(helperPath)\"") == true)
    toggle.isOn = false
    #expect(connecting.launchDevice(id: studio.id)?.connectsAgentsAtLaunch == false)
}
