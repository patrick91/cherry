import CherryControl
import Darwin
import Foundation
import os
import Testing
@testable import Cherry

// Cherry MCP on the command line of the agents Cherry starts on This Mac
// (AgentMCPLaunch, AgentCLIVersions; docs/mcp.md › Setup): which commands
// get the flags, what the flags are, how a CLI's version is read, and what
// a tab's launch runs. No test runs the real claude, codex or pi: the CLIs
// here are stand-in scripts in temporary directories. Every workspace that
// adds flags gets its own AgentMCPLaunchContext, never `.shared`'s versions
// or UserDefaults.standard, and never reads the real ~/.pi; every other
// workspace's policy has none.

private func launchTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-launch-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An executable stand-in at `url` running `script`.
private func writeLaunchStandIn(_ script: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    #expect(chmod(url.path, 0o755) == 0)
}

/// A stand-in CLI that prints `version` for `--version` (adding a line to
/// `runs` each time, when given) and its arguments otherwise.
private func writeVersionStandIn(_ version: String, to url: URL, runs: URL? = nil) throws {
    let counting = runs.map { "echo ran >> \(ShellQuoting.singleQuoted($0.path))\n  " } ?? ""
    try writeLaunchStandIn("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      \(counting)echo \(ShellQuoting.singleQuoted(version))
      exit 0
    fi
    printf '%s\\n' "$@"
    """, to: url)
}

private func lineCount(_ url: URL) -> Int {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
}

/// `executable arguments…`'s exit status and standard output.
private func runLaunchProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path]
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Polls `condition` (on the main actor) until it holds or `timeout` passes.
@MainActor
private func launchEventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private let launchHelperPath = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"

// MARK: - Which commands

@Test func controlToolLaunchDetectsPlainClaudeCodexAndPiCommands() {
    let detected: [(String, AgentMCPLaunch.CLI, String)] = [
        ("claude", .claudeCode, "claude"),
        ("claude --dangerously-skip-permissions", .claudeCode, "claude"),
        ("codex --yolo", .codex, "codex"),
        ("/opt/homebrew/bin/claude", .claudeCode, "/opt/homebrew/bin/claude"),
        ("~/.local/bin/claude --resume", .claudeCode, "~/.local/bin/claude"),
        ("'/Applications/My Tools/codex' --yolo", .codex, "/Applications/My Tools/codex"),
        (#"claude "fix it""#, .claudeCode, "claude"),
        ("claude 'fix it' --model opus", .claudeCode, "claude"),
        ("codex exec x", .codex, "codex"),
        ("codex resume --last", .codex, "codex"),
        ("codex -c model=o3", .codex, "codex"),
        ("  claude\t--verbose  ", .claudeCode, "claude"),
        ("pi", .pi, "pi"),
        ("/opt/homebrew/bin/pi", .pi, "/opt/homebrew/bin/pi"),
        ("~/.bun/bin/pi", .pi, "~/.bun/bin/pi"),
        ("pi --model x", .pi, "pi"),
        (#"pi "fix it""#, .pi, "pi"),
        ("pi -c", .pi, "pi"),
        // Its own extensions load beside Cherry's.
        ("pi -e ./mine.ts", .pi, "pi"),
    ]
    for (line, cli, word) in detected {
        let detection = AgentMCPLaunch.detect(commandLine: line)
        #expect(detection?.cli == cli, "\(line)")
        #expect(detection?.executableWord == word, "\(line)")
    }
}

@Test func controlToolLaunchLeavesEveryOtherCommandAsItIs() {
    let notPlain = [
        "", "npx claude", "FOO=1 claude", "claude && x", "claude | tee log", "claude; x", "claude > log",
        "claude < input", "(claude)", "claude &", "claude -- x", "claude $(echo x)", "claude `echo x`",
        #"claude "$HOME""#, "claude $HOME", "claude *", "claude --model {a,b}", "claude # comment",
        "claude\nrm -rf x", "claude\r", "claude \\\n--mcp-config f", "claude '\n'", "claude 'unterminated", #"claude "unterminated"#, "claude \\",
        "gemini", "/bin/cat", "claude-code", "Claude", "amp", "opencode", "npx pi", "pi-coding-agent",
        "FOO=1 pi", "pi | tee log", "pi -- x", "pi $(cat prompt)",
    ]
    for line in notPlain {
        #expect(AgentMCPLaunch.detection(commandLine: line) == .notPlain, "\(line)")
        #expect(AgentMCPLaunch.detect(commandLine: line) == nil, "\(line)")
    }
    let ownConfiguration: [(String, AgentMCPLaunch.CLI)] = [
        ("claude --mcp-config f", .claudeCode),
        ("claude --mcp-config=f", .claudeCode),
        ("claude --strict-mcp-config", .claudeCode),
        (#"codex -c 'mcp_servers.x.command="y"'"#, .codex),
        ("codex --config mcp_servers.x.command=y", .codex),
        ("codex -cmcp_servers.x.command=y", .codex),
        // Pi without its MCP, or without extensions: nothing would connect
        // the extension's server.
        ("pi --no-mcp", .pi),
        ("pi -ne", .pi),
        ("pi --no-extensions", .pi),
        ("pi --no-extensions=all", .pi),
        ("pi --model x -ne -e builtin:mcp", .pi),
    ]
    for (line, cli) in ownConfiguration {
        #expect(AgentMCPLaunch.detection(commandLine: line) == .ownConfiguration(cli), "\(line)")
        #expect(AgentMCPLaunch.detect(commandLine: line) == nil, "\(line)")
    }
    let subcommands: [(String, AgentMCPLaunch.CLI, String)] = [
        ("claude mcp list", .claudeCode, "mcp"),
        ("claude update", .claudeCode, "update"),
        ("claude --verbose doctor", .claudeCode, "doctor"),
        ("codex login", .codex, "login"),
        ("codex mcp-server", .codex, "mcp-server"),
        ("codex -c model=o3 logout", .codex, "logout"),
        // Claude Code 2.1.299's background-session and maintenance
        // commands: `claude attach <name> --mcp-config …` would read the
        // flags as more of the name.
        ("claude attach build", .claudeCode, "attach"),
        ("claude logs build", .claudeCode, "logs"),
        ("claude stop build", .claudeCode, "stop"),
        ("claude kill build", .claudeCode, "kill"),
        ("claude rm build", .claudeCode, "rm"),
        ("claude respawn --all", .claudeCode, "respawn"),
        ("claude agents", .claudeCode, "agents"),
        ("claude upgrade", .claudeCode, "upgrade"),
        ("claude auto-mode", .claudeCode, "auto-mode"),
        ("claude gateway", .claudeCode, "gateway"),
        ("claude import codex", .claudeCode, "import"),
        ("claude purge .", .claudeCode, "purge"),
        ("claude ultrareview 42", .claudeCode, "ultrareview"),
        // Pi 1.3.0's commands that start no session.
        ("pi mcp list", .pi, "mcp"),
        ("pi install npm:x", .pi, "install"),
        ("pi remove npm:x", .pi, "remove"),
        ("pi uninstall npm:x", .pi, "uninstall"),
        ("pi update", .pi, "update"),
        ("pi list", .pi, "list"),
        ("pi config", .pi, "config"),
        ("pi auth", .pi, "auth"),
        ("pi help", .pi, "help"),
    ]
    for (line, cli, subcommand) in subcommands {
        #expect(AgentMCPLaunch.detection(commandLine: line) == .subcommand(cli, subcommand), "\(line)")
        #expect(AgentMCPLaunch.detect(commandLine: line) == nil, "\(line)")
    }
    // A last option that takes the next word, whatever it is: it would take
    // the first appended word, and the next one would be a prompt.
    let optionsWithoutValue: [(String, AgentMCPLaunch.CLI, String)] = [
        ("claude --model", .claudeCode, "--model"),
        (#"claude "fix it" --permission-mode"#, .claudeCode, "--permission-mode"),
        ("claude -n", .claudeCode, "-n"),
        ("codex -m", .codex, "-m"),
        ("codex --yolo -c", .codex, "-c"),
        ("pi --model", .pi, "--model"),
        ("pi -e", .pi, "-e"),
        ("pi --thinking", .pi, "--thinking"),
        ("pi -c --name", .pi, "--name"),
    ]
    for (line, cli, option) in optionsWithoutValue {
        #expect(AgentMCPLaunch.detection(commandLine: line) == .optionWithoutValue(cli, option), "\(line)")
        #expect(AgentMCPLaunch.detect(commandLine: line) == nil, "\(line)")
        #expect(AgentMCPLaunch.plan(
            commandLine: line, serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [],
            piExtensionPath: "/tmp/cherry-pi-mcp.ts"
        ) == .skipped("its last word, \(option), is an option without its value"), "\(line)")
    }
    // With its value, or an option that takes none, it is a session.
    for line in ["claude --model opus", "claude -r", "claude --debug", "codex -m o3", "pi --model x", "pi -e ./mine.ts", "pi -p", "pi --print"] {
        #expect(AgentMCPLaunch.detect(commandLine: line) != nil, "\(line)")
    }
}

// MARK: - The flags

@Test func controlToolLaunchArgumentsNameTheHelperForClaudeAndCodex() throws {
    let helper = #"/tmp/My Apps/Cherry "Dev".app/Contents/MacOS/CherryMCP"#
    let claude = try #require(AgentMCPLaunch.arguments(
        for: .claudeCode, serverName: "cherry", helperPath: helper, environmentKeys: ["CHERRY_PROCESS_ID"]
    ))
    #expect(claude.count == 2)
    #expect(claude.first == "--mcp-config")
    // Sorted keys, slashes as they are; no environment (Claude Code passes its own).
    #expect(claude.last == #"{"mcpServers":{"cherry":{"args":[],"command":"/tmp/My Apps/Cherry \"Dev\".app/Contents/MacOS/CherryMCP","type":"stdio"}}}"#)
    let json = try #require(claude.last)
    let decoded = try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: [String: Any]]]
    )
    let server = try #require(decoded["mcpServers"]?["cherry"])
    #expect(server["command"] as? String == helper)
    #expect((server["args"] as? [String])?.isEmpty == true)
    #expect(server["type"] as? String == "stdio")
    #expect(Set(server.keys) == ["args", "command", "type"])

    let codex = try #require(AgentMCPLaunch.arguments(
        for: .codex, serverName: "cherry-dev", helperPath: helper,
        environmentKeys: ["CHERRY_PROCESS_ID", "CHERRY_MCP_TOKEN"]
    ))
    #expect(codex == [
        "-c",
        #"mcp_servers.cherry-dev={command="/tmp/My Apps/Cherry \"Dev\".app/Contents/MacOS/CherryMCP",args=["--client-tool-timeout","300"],env_vars=["CHERRY_PROCESS_ID","CHERRY_MCP_TOKEN"],startup_timeout_sec=30,tool_timeout_sec=300}"#,
    ])
    #expect(AgentMCPLaunch.tomlString("a\\b\"c\td") == #""a\\b\"c\u0009d""#)

    // Pi: its extension, which runs the helper the tab names; nothing else
    // goes on the line.
    let piExtension = "/Applications/Cherry.app/Contents/Resources/Cherry_Cherry.bundle/cherry-pi-mcp.ts"
    #expect(AgentMCPLaunch.arguments(
        for: .pi, serverName: "cherry", helperPath: helper, environmentKeys: ["CHERRY_PROCESS_ID"], piExtensionPath: piExtension
    ) == ["-e", piExtension])
    for path in ["/tmp/it's/cherry-pi-mcp.ts", "/tmp/back\\slash/cherry-pi-mcp.ts", "/tmp/new\nline/x.ts", "relative/cherry-pi-mcp.ts", ""] {
        #expect(AgentMCPLaunch.arguments(
            for: .pi, serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: path
        ) == nil, "\(path)")
    }
    #expect(AgentMCPLaunch.arguments(for: .pi, serverName: "cherry", helperPath: launchHelperPath, environmentKeys: []) == nil)
    // The extension runs the helper, so the helper's path is checked too.
    #expect(AgentMCPLaunch.arguments(
        for: .pi, serverName: "cherry", helperPath: "relative/CherryMCP", environmentKeys: [], piExtensionPath: piExtension
    ) == nil)
    #expect(AgentMCPLaunch.plan(
        commandLine: "pi", serverName: "cherry", helperPath: launchHelperPath, environmentKeys: []
    ) == .skipped("no Pi extension next to the app"))
    #expect(AgentMCPLaunch.plan(
        commandLine: "pi", serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: "/tmp/it's.ts"
    ) == .skipped("the server name cherry, CherryMCP's path \(launchHelperPath) or the Pi extension's path /tmp/it's.ts can't go on a command line"))
    #expect(AgentMCPLaunch.plan(
        commandLine: "pi --model x", serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: piExtension
    ) == .flags(cli: .pi, executableWord: "pi", arguments: ["-e", piExtension]))
    #expect(AgentMCPLaunch.plan(
        commandLine: "pi -ne", serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: piExtension
    ) == .skipped("it turns off Pi's MCP or extensions"))
    #expect(AgentMCPLaunch.plan(
        commandLine: "pi | tee x", serverName: "cherry", helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: piExtension
    ) == .skipped("not a plain claude, codex or pi command"))

    // Words that would not read the same in every shell's single quotes,
    // and names a CLI's configuration cannot take, give no flags.
    for cli in AgentMCPLaunch.CLI.allCases {
        for path in ["/tmp/it's/CherryMCP", "/tmp/back\\slash/CherryMCP", "/tmp/new\nline/CherryMCP", "relative/CherryMCP", ""] {
            #expect(AgentMCPLaunch.arguments(for: cli, serverName: "cherry", helperPath: path, environmentKeys: []) == nil, "\(path)")
        }
        for name in ["", "Cherry", "cherry.dev", "cherry+x", "cher ry", "cherry'"] {
            #expect(AgentMCPLaunch.arguments(
                for: cli, serverName: name, helperPath: launchHelperPath, environmentKeys: [], piExtensionPath: "/tmp/cherry-pi-mcp.ts"
            ) == nil, "\(name)")
        }
    }
}

@Test func controlToolLaunchSuffixReadsBackUnchangedInEveryShell() throws {
    let helper = #"/tmp/My Apps/Cherry "Dev".app/Contents/MacOS/CherryMCP"#
    let claude = try #require(AgentMCPLaunch.arguments(for: .claudeCode, serverName: "cherry", helperPath: helper, environmentKeys: []))
    let codex = try #require(AgentMCPLaunch.arguments(
        for: .codex, serverName: "cherry", helperPath: helper,
        environmentKeys: AgentMCPLaunch.environmentKeys(projectRoot: "/p", controlSocketPath: "/s", helperPath: helper)
    ))
    #expect(AgentMCPLaunch.shellSuffix(["a b", "it's"]) == #" 'a b' 'it'\''s'"#)
    var shells: [(String, [String])] = [
        ("/bin/sh", ["-c"]),
        ("/bin/zsh", ["-f", "-c"]),
        ("/bin/bash", ["--noprofile", "--norc", "-c"]),
    ]
    // Fish reads `\'` and `\\` inside single quotes; the words have neither.
    // Not every Mac has fish: then only the POSIX shells run.
    for fish in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"] where FileManager.default.isExecutableFile(atPath: fish) {
        shells.append((fish, ["--no-config", "-c"]))
    }
    let pi = try #require(AgentMCPLaunch.arguments(
        for: .pi, serverName: "cherry", helperPath: helper, environmentKeys: [],
        piExtensionPath: "/tmp/My Apps/Cherry \"Dev\".app/Contents/Resources/Cherry_Cherry.bundle/cherry-pi-mcp.ts"
    ))
    for words in [claude, codex, pi] {
        let suffix = AgentMCPLaunch.shellSuffix(words)
        for (shell, options) in shells {
            let run = try runLaunchProcess(shell, options + ["printf '%s\\n'" + suffix])
            #expect(run.status == 0, "\(shell)")
            #expect(run.output == words.map { $0 + "\n" }.joined(), "\(shell)")
        }
    }
}

@Test func controlToolLaunchEnvironmentKeysAreTheOnesTheLaunchSets() {
    #expect(AgentMCPLaunch.environmentKeys(projectRoot: "/p", controlSocketPath: "/tmp/s.sock", helperPath: "/h") == [
        "CHERRY_PROCESS_ID", "CHERRY_AGENT_ID", "CHERRY_PROJECT_ROOT", "CHERRY_CONTROL_SOCKET", "CHERRY_MCP_HELPER",
    ])
    #expect(AgentMCPLaunch.environmentKeys(projectRoot: nil, controlSocketPath: nil, helperPath: nil)
        == ["CHERRY_PROCESS_ID", "CHERRY_AGENT_ID"])
    #expect(AgentMCPLaunch.environmentKeys(projectRoot: "", controlSocketPath: "", helperPath: "")
        == ["CHERRY_PROCESS_ID", "CHERRY_AGENT_ID"])
}

@Test func controlToolLaunchSwitchIsOnUnlessTurnedOff() throws {
    let suite = "CherryTests.ControlToolLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(AgentMCPLaunch.enabledDefaultsKey == "mcp.connectAgentsAtLaunch")
    #expect(AgentMCPLaunch.isEnabled(defaults))
    defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(!AgentMCPLaunch.isEnabled(defaults))
    defaults.set(true, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(AgentMCPLaunch.isEnabled(defaults))
}

// MARK: - Versions

@Test func controlToolLaunchVersionsParseCompareAndHaveMinimums() {
    #expect(AgentCLIVersion(versionOutput: "2.1.299 (Claude Code)") == AgentCLIVersion(major: 2, minor: 1, patch: 299))
    #expect(AgentCLIVersion(versionOutput: "codex-cli 0.162.1\n") == AgentCLIVersion(major: 0, minor: 162, patch: 1))
    #expect(AgentCLIVersion(versionOutput: "v1.2.3-beta.4") == AgentCLIVersion(major: 1, minor: 2, patch: 3))
    #expect(AgentCLIVersion(versionOutput: "garbage") == nil)
    #expect(AgentCLIVersion(versionOutput: "1.2") == nil)
    #expect(AgentCLIVersion(versionOutput: "") == nil)
    #expect(AgentCLIVersion(major: 2, minor: 1, patch: 299).description == "2.1.299")

    #expect(AgentCLIVersion(major: 1, minor: 9, patch: 0) < AgentCLIVersion(major: 2, minor: 0, patch: 0))
    #expect(AgentCLIVersion(major: 2, minor: 0, patch: 10) > AgentCLIVersion(major: 2, minor: 0, patch: 9))
    #expect(AgentCLIVersion(major: 0, minor: 162, patch: 0) > AgentCLIVersion(major: 0, minor: 99, patch: 99))
    #expect(AgentCLIVersion(major: 10, minor: 0, patch: 0) > AgentCLIVersion(major: 9, minor: 99, patch: 99))

    #expect(AgentMCPLaunch.CLI.claudeCode.minimumVersion == AgentCLIVersion(major: 2, minor: 0, patch: 0))
    #expect(AgentMCPLaunch.CLI.codex.minimumVersion == AgentCLIVersion(major: 0, minor: 162, patch: 0))
    // Pi's is the one Settings' registration has, defined once.
    #expect(AgentMCPLaunch.CLI.pi.minimumVersion == AgentCLIVersion(major: 0, minor: 99, patch: 2))
    #expect(AgentMCPLaunch.CLI.pi.minimumVersion == PiMCPRegistration.minimumVersion)
    #expect(AgentCLIVersion(versionOutput: "1.3.0")! >= AgentMCPLaunch.CLI.pi.minimumVersion)
    #expect(AgentCLIVersion(versionOutput: "0.62.0")! < AgentMCPLaunch.CLI.pi.minimumVersion)
    #expect(MCPHarness.pi.launchCLI == .pi)
    #expect(AgentCLIVersion(versionOutput: "2.1.299 (Claude Code)")! >= AgentMCPLaunch.CLI.claudeCode.minimumVersion)
    #expect(AgentCLIVersion(versionOutput: "codex-cli 0.162.1")! >= AgentMCPLaunch.CLI.codex.minimumVersion)
    #expect(AgentCLIVersion(versionOutput: "codex-cli 0.161.9")! < AgentMCPLaunch.CLI.codex.minimumVersion)
}

@Test func controlToolLaunchProbeAsksTheCLIOnPATHOnceUntilItChanges() async throws {
    let directory = try launchTemporaryDirectory("probe")
    defer { try? FileManager.default.removeItem(at: directory) }
    let bin = directory.appendingPathComponent("bin", isDirectory: true)
    let claude = bin.appendingPathComponent("claude")
    let runs = directory.appendingPathComponent("runs")
    try writeVersionStandIn("2.1.299 (Claude Code)", to: claude, runs: runs)
    let environment = ["PATH": "/nonexistent:\(bin.path):/usr/bin:/bin"]
    let versions = AgentCLIVersions(environment: { environment })

    // Found on PATH, asked once, then known.
    #expect(AgentCLIVersions.executableFile(for: "claude", environment: environment)?.path == claude.path)
    #expect(versions.version(of: "claude", environment: environment) == nil)
    #expect(await versions.probe("claude", environment: environment) == AgentCLIVersion(major: 2, minor: 1, patch: 299))
    #expect(versions.version(of: "claude", environment: environment) == AgentCLIVersion(major: 2, minor: 1, patch: 299))
    #expect(versions.version(of: claude.path) == AgentCLIVersion(major: 2, minor: 1, patch: 299))
    #expect(await versions.probe("claude", environment: environment) == AgentCLIVersion(major: 2, minor: 1, patch: 299))
    #expect(lineCount(runs) == 1)

    // An updated CLI is another file: unknown until it is asked.
    try writeVersionStandIn("2.10.0 (Claude Code)", to: claude, runs: runs)
    #expect(versions.version(of: "claude", environment: environment) == nil)
    #expect(await versions.probe("claude", environment: environment) == AgentCLIVersion(major: 2, minor: 10, patch: 0))
    #expect(lineCount(runs) == 2)

    // Nothing to run: not on PATH, a directory, not executable.
    #expect(await versions.probe("codex", environment: environment) == nil)
    #expect(await versions.probe("claude", environment: ["PATH": "/usr/bin:/bin"]) == nil)
    try FileManager.default.createDirectory(at: bin.appendingPathComponent("codex", isDirectory: true), withIntermediateDirectories: true)
    #expect(AgentCLIVersions.executableFile(for: "codex", environment: environment) == nil)
    try "echo 1.2.3".write(to: directory.appendingPathComponent("plain"), atomically: true, encoding: .utf8)
    #expect(AgentCLIVersions.executableFile(atPath: directory.appendingPathComponent("plain").path) == nil)

    // A CLI that fails, or prints no version, gives none.
    let failing = directory.appendingPathComponent("failing/codex")
    try writeLaunchStandIn("#!/bin/sh\necho 'codex-cli 0.162.1'\nexit 3\n", to: failing)
    #expect(await versions.probe(failing.path, environment: environment) == nil)
    let silent = directory.appendingPathComponent("silent/codex")
    try writeLaunchStandIn("#!/bin/sh\necho 'no version here'\n", to: silent)
    #expect(await versions.probe(silent.path, environment: environment) == nil)

    // A word with a `/` is the file itself; `~` is the home directory.
    #expect(AgentCLIVersions.executableFile(for: "~/definitely-not-here-\(UUID().uuidString)/claude", environment: environment) == nil)
    #expect(AgentCLIVersions.executableFile(for: "relative/claude", environment: environment) == nil)
}

@Test func controlToolLaunchProbeKillsACLIThatDoesNotAnswerInTime() async throws {
    let directory = try launchTemporaryDirectory("slow")
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let claude = directory.appendingPathComponent("bin/claude")
    try writeLaunchStandIn("#!/bin/sh\necho $$ > \(ShellQuoting.singleQuoted(pidFile.path))\nexec /bin/sleep 30\n", to: claude)
    let versions = AgentCLIVersions(environment: { [:] }, timeout: 0.5)

    let started = Date()
    #expect(await versions.probe(claude.path, environment: ["PATH": "/usr/bin:/bin"]) == nil)
    #expect(Date().timeIntervalSince(started) < 5)
    let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    let signalled = kill(pid, 0)
    let error = errno
    #expect(signalled == -1 && error == ESRCH, "the stand-in that did not answer is gone")
    // Not kept: the next launch asks again.
    #expect(versions.version(of: claude.path) == nil)
}

/// `--version`'s standard output and standard error are both read as it
/// writes them (a CLI that fills its error pipe first still answers), and
/// only its standard output gives its version: a version only its standard
/// error names (Pi 0.62.0 without a terminal) is kept apart, never a
/// launch's, so its agents start without the flags.
@Test @MainActor func controlToolLaunchProbeReadsBothStreamsAndTakesTheVersionFromStandardOutputOnly() async throws {
    let directory = try launchTemporaryDirectory("streams")
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = ["PATH": "/usr/bin:/bin"]
    let versions = AgentCLIVersions(environment: { environment }, timeout: 5)
    func standIn(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent("\(name)/claude")
        try writeLaunchStandIn("#!/bin/sh\nif [ \"$1\" = --version ]; then\n\(body)\nexit 0\nfi\nexit 1\n", to: url)
        return url
    }

    // 256 KiB of errors before its version: more than a pipe holds.
    let noisy = try standIn("noisy", "/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\0' x >&2\necho '2.1.299 (Claude Code)'")
    let started = Date()
    #expect(await versions.answer(noisy.path, environment: environment) == .version(AgentCLIVersion(major: 2, minor: 1, patch: 299)))
    #expect(Date().timeIntervalSince(started) < 4)
    let noisyOutput = try #require(AgentCLIVersions.versionOutput(of: noisy.path, environment: environment, timeout: 5))
    #expect(noisyOutput.output == "2.1.299 (Claude Code)\n")
    #expect(noisyOutput.errors.count == 64 * 1_024, "its errors are read to their end, and kept up to the limit")

    // Standard output wins over what its errors say.
    let both = try standIn("both", "echo 0.1.0 >&2\necho '2.1.299 (Claude Code)'")
    #expect(await versions.answer(both.path, environment: environment) == .version(AgentCLIVersion(major: 2, minor: 1, patch: 299)))

    // Only its errors name a version: kept apart, with what its standard
    // output printed; never its version, for Settings or a launch.
    let errorsOnly = try standIn("errors-only", "echo 2.1.299 >&2")
    let named = AgentCLIVersion(major: 2, minor: 1, patch: 299)
    #expect(await versions.answer(errorsOnly.path, environment: environment) == .versionOnErrorOutput(named, output: ""))
    #expect(await versions.probe(errorsOnly.path, environment: environment) == nil)
    #expect(versions.version(of: errorsOnly.path) == nil)
    let context = AgentMCPLaunchContext(isEnabled: { true }, versions: versions, helperPath: launchHelperPath)
    let keys = AgentMCPLaunch.environmentKeys(projectRoot: directory.path, controlSocketPath: nil, helperPath: launchHelperPath)
    #expect(context.outcome(commandLine: errorsOnly.path, serverName: "cherry", environmentKeys: keys)
        == .skipped("claude's version is not known yet"))
    let noisyGetsFlags = if case .appended = context.outcome(commandLine: noisy.path, serverName: "cherry", environmentKeys: keys) {
        true
    } else {
        false
    }
    #expect(noisyGetsFlags, "one whose standard output names its version gets them")
    let garbage = try standIn("garbage", "echo 0.62.0 >&2\necho 'pi dev build'")
    #expect(await versions.answer(garbage.path, environment: environment)
        == .versionOnErrorOutput(AgentCLIVersion(major: 0, minor: 62, patch: 0), output: "pi dev build"))

    // Nothing anywhere, or errors but no version: no version.
    let quiet = try standIn("quiet", "echo 'something went wrong' >&2")
    #expect(await versions.answer(quiet.path, environment: environment) == .noVersion(output: ""))
}

/// Reading both pipes never waits past the CLI: one that keeps writing its
/// errors and never exits is killed with its group at the timeout, and one
/// that exits while a process it started keeps both pipes open (writing to
/// them, or not) answers once it exited.
@Test func controlToolLaunchProbeNeverWaitsOnPipesPastItsCLI() async throws {
    let directory = try launchTemporaryDirectory("pipes")
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = ["PATH": "/usr/bin:/bin"]
    func pid(in file: URL) throws -> pid_t {
        try #require(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    let chattyPID = directory.appendingPathComponent("chatty.pid")
    let chatty = directory.appendingPathComponent("chatty/claude")
    try writeLaunchStandIn("#!/bin/sh\necho $$ > \(ShellQuoting.singleQuoted(chattyPID.path))\nexec /usr/bin/yes >&2\n", to: chatty)
    let started = Date()
    #expect(await AgentCLIVersions(environment: { environment }, timeout: 0.5).answer(chatty.path, environment: environment) == .noAnswer)
    #expect(Date().timeIntervalSince(started) < 4)
    let signalled = kill(try pid(in: chattyPID), 0)
    let error = errno
    #expect(signalled == -1 && error == ESRCH, "the stand-in that never exited is gone")

    let versions = AgentCLIVersions(environment: { environment }, timeout: 5)
    for (name, child) in [
        ("quiet", "exec /bin/sleep 30"),
        ("writing", "while :; do echo working; echo working >&2; /bin/sleep 0.01; done"),
    ] {
        let childPID = directory.appendingPathComponent("\(name).pid")
        let leaving = directory.appendingPathComponent("\(name)/claude")
        try writeLaunchStandIn(
            "#!/bin/sh\n(\(child)) &\necho $! > \(ShellQuoting.singleQuoted(childPID.path))\necho '2.1.299 (Claude Code)'\nexit 0\n",
            to: leaving
        )
        let asked = Date()
        let answer = await versions.answer(leaving.path, environment: environment)
        let took = Date().timeIntervalSince(asked)
        if let child = try? pid(in: childPID) { _ = kill(child, SIGKILL) }
        #expect(answer == .version(AgentCLIVersion(major: 2, minor: 1, patch: 299)), "\(name)")
        #expect(took < 3, "\(name): answered once it exited, not at the timeout")
    }
}

@Test func controlToolLaunchAMissAsksInTheBackgroundOnlyWhenTheInstanceProbes() async throws {
    let directory = try launchTemporaryDirectory("miss")
    defer { try? FileManager.default.removeItem(at: directory) }
    let codex = directory.appendingPathComponent("bin/codex")
    let runs = directory.appendingPathComponent("runs")
    try writeVersionStandIn("codex-cli 0.162.1", to: codex, runs: runs)
    let environment = ["PATH": "\(codex.deletingLastPathComponent().path):/usr/bin:/bin"]

    // A test's instance runs nothing it was not asked to.
    let quiet = AgentCLIVersions(environment: { environment })
    #expect(quiet.version(of: "codex") == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(quiet.version(of: "codex") == nil)
    #expect(lineCount(runs) == 0)

    // The app's asks once, in the background, and a later launch knows.
    let asking = AgentCLIVersions(environment: { environment }, probesOnMiss: true)
    #expect(asking.version(of: "codex") == nil)
    #expect(await launchEventually { asking.version(of: "codex") == AgentCLIVersion(major: 0, minor: 162, patch: 1) })
    #expect(lineCount(runs) == 1)

    // Known versions for tests, by the file as it is.
    let seeded = AgentCLIVersions(environment: { environment })
    seeded.seed([codex.path: AgentCLIVersion(major: 9, minor: 9, patch: 9), "/nonexistent/codex": AgentCLIVersion(major: 1, minor: 0, patch: 0)])
    #expect(seeded.version(of: "codex") == AgentCLIVersion(major: 9, minor: 9, patch: 9))
    #expect(seeded.version(of: "/nonexistent/codex") == nil)
    #expect(lineCount(runs) == 1)
}

// MARK: - A tab's launch

/// A workspace whose agent launches add Cherry MCP through `context`, with
/// stand-in `claude`, `codex` and `pi` CLIs and a stand-in Pi extension.
/// Host-managed: each tab runs its command in a login shell of the test's
/// own.
@MainActor
private final class LaunchHarness {
    let directory: URL
    let claude: URL
    let codex: URL
    let pi: URL
    let piExtension: URL
    let versions: AgentCLIVersions
    let suite = "CherryTests.ControlToolLaunch.\(UUID().uuidString)"
    let defaults: UserDefaults
    var workspaces: [TerminalWorkspace] = []
    var looseTabs: [TerminalSession] = []

    init() throws {
        directory = try launchTemporaryDirectory("tab")
        claude = directory.appendingPathComponent("bin/claude")
        codex = directory.appendingPathComponent("bin/codex")
        try writeVersionStandIn("2.1.299 (Claude Code)", to: claude)
        try writeVersionStandIn("codex-cli 0.162.1", to: codex)
        pi = directory.appendingPathComponent("bin/pi")
        try writeVersionStandIn("1.3.0", to: pi)
        piExtension = directory.appendingPathComponent("Cherry_Cherry.bundle/cherry-pi-mcp.ts")
        try FileManager.default.createDirectory(at: piExtension.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default function cherryMCP(pi) {}\n".write(to: piExtension, atomically: true, encoding: .utf8)
        let path = "\(directory.appendingPathComponent("bin").path):/usr/bin:/bin"
        versions = AgentCLIVersions(environment: { ["PATH": path] })
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    var context: AgentMCPLaunchContext {
        let defaults = defaults
        return AgentMCPLaunchContext(
            isEnabled: { AgentMCPLaunch.isEnabled(defaults) },
            versions: versions,
            helperPath: launchHelperPath,
            piExtensionPath: piExtension.path
        )
    }

    func workspace(agentMCPLaunch: AgentMCPLaunchContext?) -> TerminalWorkspace {
        var policy = SessionBackendPolicy.native
        policy.agentMCPLaunch = agentMCPLaunch
        let workspace = TerminalWorkspace(
            projectRoot: directory.path, createInitialSession: false, launchBackend: .hostManaged, backendPolicy: policy
        )
        workspaces.append(workspace)
        return workspace
    }

    func suffix(_ cli: AgentMCPLaunch.CLI) throws -> String {
        let arguments = try #require(AgentMCPLaunch.arguments(
            for: cli,
            serverName: CherryAppIdentity.current.urlScheme,
            helperPath: launchHelperPath,
            environmentKeys: AgentMCPLaunch.environmentKeys(
                projectRoot: directory.path, controlSocketPath: CherryControlServer.appSocketPath, helperPath: launchHelperPath
            ),
            piExtensionPath: piExtension.path
        ))
        return AgentMCPLaunch.shellSuffix(arguments)
    }

    func cleanUp() {
        for workspace in workspaces { workspace.closeAllSessions() }
        for tab in looseTabs { tab.stop() }
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func controlToolLaunchAnAgentTabGetsTheFlagsOnlyForItsLaunch() async throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let token = SessionLog.observe { entry in seen.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(token) }
    func logged(_ tab: TerminalSession) -> [String] {
        seen.withLock { $0 }.filter { $0.hasPrefix("[mcp] tab \(tab.id.uuidString) ") }
    }
    harness.versions.seed([
        harness.claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 299),
        harness.codex.path: AgentCLIVersion(major: 0, minor: 162, patch: 1),
    ])
    let workspace = harness.workspace(agentMCPLaunch: harness.context)
    let claudeSuffix = try harness.suffix(.claudeCode)
    let codexSuffix = try harness.suffix(.codex)

    let claudeLine = "\(harness.claude.path) --dangerously-skip-permissions"
    let claude = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: harness.claude.path, arguments: "--dangerously-skip-permissions"),
        projectRoot: harness.directory.path
    )
    #expect(claude.launchCommand == claudeLine)
    #expect(claude.launchStartupCommand == claudeLine + claudeSuffix)
    #expect(logged(claude).count == 1)
    #expect(logged(claude).first?.contains("with Cherry MCP: '--mcp-config'") == true)
    #expect(claude.lastAgentMCPLaunchOutcome == .appended(claudeSuffix))

    let codexLine = "\(harness.codex.path) --yolo"
    let codex = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: harness.codex.path, arguments: "--yolo"),
        projectRoot: harness.directory.path
    )
    #expect(codex.launchStartupCommand == codexLine + codexSuffix)
    #expect(codex.launchStartupCommand?.contains("'-c' 'mcp_servers.\(CherryAppIdentity.current.urlScheme)={command=") == true)

    // Never saved: a record keeps the command as configured.
    let record = workspace.makeStateRecord(root: harness.directory.path, collapsedAgentGroupIDs: [])
    #expect(record.sessions.first { $0.id == claude.id }?.launchCommand == claudeLine)
    #expect(record.sessions.first { $0.id == codex.id }?.launchCommand == codexLine)
    #expect(record.sessions.allSatisfy { record in
        !(record.launchCommand ?? "").contains("--mcp-config") && !(record.launchCommand ?? "").contains("mcp_servers")
    })

    // A restart decides again: the switch is read at every launch.
    harness.defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(claude.restart())
    #expect(claude.launchStartupCommand == nil)
    #expect(logged(claude).last?.hasSuffix(": turned off in Settings › Agents & MCP") == true)
    #expect(claude.lastAgentMCPLaunchOutcome == .skipped("turned off in Settings › Agents & MCP"))
    harness.defaults.set(true, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(claude.restart())
    #expect(claude.launchStartupCommand == claudeLine + claudeSuffix)
    #expect(claude.launchCommand == claudeLine)

    // The other tabs of the workspace run their commands as they are.
    let terminal = workspace.addSession()
    #expect(terminal.launchStartupCommand == nil)
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(name: "assistant", command: harness.claude.path),
        projectRoot: harness.directory.path
    )
    #expect(command.kind == .command)
    #expect(command.launchStartupCommand == nil)
    #expect(logged(terminal).isEmpty)
    #expect(logged(command).isEmpty)
    #expect(terminal.lastAgentMCPLaunchOutcome == nil)
    #expect(command.lastAgentMCPLaunchOutcome == nil)
}

@Test @MainActor func controlToolLaunchAgentsStartAsTheirCommandSaysWithoutAKnownVersionOrTheSwitch() async throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let token = SessionLog.observe { entry in seen.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(token) }
    func reason(_ tab: TerminalSession) -> String? {
        seen.withLock { $0 }.last { $0.hasPrefix("[mcp] tab \(tab.id.uuidString) ") }?
            .components(separatedBy: "on its command line: ").last
    }
    let claudeAgent = AgentToolDefinition(name: "Claude", command: harness.claude.path, arguments: "--resume")

    // A version not known yet: no flags, and no CLI is run to find it.
    let cold = harness.workspace(agentMCPLaunch: harness.context)
    let coldTab = cold.addAgentSession(agent: claudeAgent, projectRoot: harness.directory.path)
    #expect(coldTab.launchStartupCommand == nil)
    #expect(reason(coldTab) == "claude's version is not known yet")

    // Too old a CLI.
    harness.versions.seed([harness.codex.path: AgentCLIVersion(major: 0, minor: 161, patch: 9)])
    let oldTab = cold.addAgentSession(
        agent: AgentToolDefinition(name: "Codex", command: harness.codex.path), projectRoot: harness.directory.path
    )
    #expect(oldTab.launchStartupCommand == nil)
    #expect(reason(oldTab) == "codex 0.161.9 is older than 0.162.0")

    harness.versions.seed([harness.claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 299)])
    // A command that names its own MCP configuration, or is not plain.
    let own = cold.addAgentSession(
        agent: AgentToolDefinition(name: "Own", command: harness.claude.path, arguments: "--mcp-config /tmp/mine.json"),
        projectRoot: harness.directory.path
    )
    #expect(own.launchStartupCommand == nil)
    #expect(reason(own) == "it names its own MCP configuration")
    let piped = cold.addAgentSession(
        agent: AgentToolDefinition(name: "Piped", command: harness.claude.path, arguments: "| tee /dev/null"),
        projectRoot: harness.directory.path
    )
    #expect(piped.launchStartupCommand == nil)
    #expect(reason(piped) == "not a plain claude, codex or pi command")

    // The switch off.
    harness.defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    let off = cold.addAgentSession(agent: claudeAgent, projectRoot: harness.directory.path)
    #expect(off.launchStartupCommand == nil)
    #expect(reason(off) == "turned off in Settings › Agents & MCP")
    harness.defaults.removeObject(forKey: AgentMCPLaunch.enabledDefaultsKey)

    // No CherryMCP next to the app.
    var noHelper = harness.context
    noHelper.helperPath = nil
    let helperless = harness.workspace(agentMCPLaunch: noHelper).addAgentSession(agent: claudeAgent, projectRoot: harness.directory.path)
    #expect(helperless.launchStartupCommand == nil)
    #expect(reason(helperless) == "no CherryMCP next to the app")

    // A workspace whose policy has none (every other test's, `.native`):
    // nothing, with the version known too, and nothing logged.
    let plain = harness.workspace(agentMCPLaunch: nil)
    let plainTab = plain.addAgentSession(agent: claudeAgent, projectRoot: harness.directory.path)
    #expect(plainTab.launchStartupCommand == nil)
    #expect(reason(plainTab) == nil)
    #expect(plainTab.lastAgentMCPLaunchOutcome == nil)
    #expect(coldTab.lastAgentMCPLaunchOutcome == .skipped("claude's version is not known yet"))
    #expect(SessionBackendPolicy.native.agentMCPLaunch == nil)

    // And with it, the same agent gets the flags.
    let suffix = try harness.suffix(.claudeCode)
    let hot = cold.addAgentSession(agent: claudeAgent, projectRoot: harness.directory.path)
    #expect(hot.launchStartupCommand == "\(harness.claude.path) --resume" + suffix)
}

/// A saved agent tab that comes back ended (`makeSystemEndedSession`)
/// starts again with the flags of its workspace's policy.
@Test @MainActor func controlToolLaunchARestoredAgentTabRestartsWithTheFlags() async throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    harness.versions.seed([harness.claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 299)])
    let workspace = harness.workspace(agentMCPLaunch: harness.context)
    let line = "\(harness.claude.path) --resume"
    let record = WorkspaceSessionRecord(
        id: UUID(),
        kind: .agent,
        title: "Claude",
        agentName: "Claude",
        launchCommand: line,
        launchWorkingDirectory: harness.directory.path,
        workingDirectory: harness.directory.path,
        projectRoot: harness.directory.path
    )
    let suffix = try harness.suffix(.claudeCode)
    let tab = workspace.makeSystemEndedSession(record: record, ended: .restart)
    harness.looseTabs.append(tab)
    #expect(tab.launchStartupCommand == nil)
    #expect(tab.restart())
    #expect(tab.launchStartupCommand == line + suffix)
    #expect(tab.launchCommand == line)
}

/// A persistent tab on This Mac's host: its Create carries the flags in the
/// command its shell runs, and the tab's record never does.
@Test @MainActor func controlToolLaunchAPersistentTabsCreateCarriesTheFlags() async throws {
    let launch = try LaunchHarness()
    let harness = try PersistentHarness()
    var policy = harness.policy
    policy.agentMCPLaunch = launch.context
    let workspace = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        launch.cleanUp()
    }
    launch.versions.seed([launch.claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 299)])

    let line = "\(launch.claude.path) --resume"
    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: launch.claude.path, arguments: "--resume"),
        projectRoot: harness.project.path
    )
    #expect(agent.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(agent))
    let arguments = try #require(AgentMCPLaunch.arguments(
        for: .claudeCode, serverName: CherryAppIdentity.current.urlScheme, helperPath: launchHelperPath, environmentKeys: []
    ))
    let expected = line + AgentMCPLaunch.shellSuffix(arguments)
    let configuration = try #require(harness.configurations.value.first { $0.processID == agent.id.uuidString })
    #expect(configuration.startupCommand == expected)
    #expect(configuration.agentID == agent.id.uuidString)

    // The spec's shell runs it: through the zsh bootstrap's
    // CHERRY_STARTUP_COMMAND, else in its `exec …` (which one depends on
    // the machine's SHELL).
    let create = try #require(harness.creates().first)
    let argv = try #require(create.json["command"] as? [String])
    let environment = create.json["env"] as? [String: String] ?? [:]
    if let startup = environment["CHERRY_STARTUP_COMMAND"] {
        #expect(startup == expected)
    } else {
        #expect(argv.last?.contains(ShellQuoting.singleQuoted("exec \(expected)")) == true, "\(argv)")
    }
    #expect(environment["CHERRY_AGENT_ID"] == agent.id.uuidString)

    let record = workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    #expect(record.sessions.first { $0.id == agent.id }?.launchCommand == line)
    #expect(agent.launchCommand == line)
}

// MARK: - Pi

/// Pi's outcome, as the app's context decides it: the extension on Pi
/// 0.99.2 or later, else today's line and why.
@Test @MainActor func controlToolLaunchPiGetsTheExtensionOnlyWhenItsVersionAndFileAllow() throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    let context = harness.context
    let keys = AgentMCPLaunch.environmentKeys(projectRoot: harness.directory.path, controlSocketPath: nil, helperPath: launchHelperPath)
    func outcome(_ line: String = "pi", context: AgentMCPLaunchContext? = nil) -> AgentMCPLaunch.Outcome {
        (context ?? harness.context).outcome(commandLine: line, serverName: "cherry", environmentKeys: keys)
    }
    let suffix = " '-e' '\(harness.piExtension.path)'"

    // Not known yet: no flags, and nothing ran to find out.
    #expect(outcome() == .skipped("pi's version is not known yet"))
    for (version, expected) in [
        (AgentCLIVersion(major: 1, minor: 3, patch: 0), AgentMCPLaunch.Outcome.appended(suffix)),
        (AgentCLIVersion(major: 0, minor: 99, patch: 2), .appended(suffix)),
        (AgentCLIVersion(major: 0, minor: 99, patch: 1), .skipped("pi 0.99.1 is older than 0.99.2")),
        (AgentCLIVersion(major: 0, minor: 62, patch: 0), .skipped("pi 0.62.0 is older than 0.99.2")),
    ] {
        harness.versions.seed([harness.pi.path: version])
        #expect(outcome() == expected, "\(version)")
        #expect(outcome(harness.pi.path + " --model x") == expected, "\(version)")
    }
    // The flags are the line's last words: options and prompts may come first.
    harness.versions.seed([harness.pi.path: AgentCLIVersion(major: 1, minor: 3, patch: 0)])
    #expect(outcome(#"pi "fix it""#) == .appended(suffix))
    // Its own MCP or extensions turned off, a subcommand, a line that is not plain.
    #expect(outcome("pi --no-mcp") == .skipped("it turns off Pi's MCP or extensions"))
    #expect(outcome("pi -ne") == .skipped("it turns off Pi's MCP or extensions"))
    #expect(outcome("pi install npm:x") == .skipped("pi install starts no session"))
    #expect(outcome("pi | tee log") == .skipped("not a plain claude, codex or pi command"))

    // No extension, or one gone since (an app moved while it runs).
    var none = context
    none.piExtensionPath = nil
    #expect(outcome(context: none) == .skipped("no Pi extension next to the app"))
    try FileManager.default.removeItem(at: harness.piExtension)
    #expect(outcome() == .skipped("no Pi extension next to the app"))
    try "export default function cherryMCP(pi) {}\n".write(to: harness.piExtension, atomically: true, encoding: .utf8)
    #expect(outcome() == .appended(suffix))

    // The switch off.
    harness.defaults.set(false, forKey: AgentMCPLaunch.enabledDefaultsKey)
    #expect(outcome() == .skipped("turned off in Settings › Agents & MCP"))
}

/// A Pi agent tab gets the extension for its launch only: never in its
/// command or its record.
@Test @MainActor func controlToolLaunchAPiAgentTabGetsTheExtensionOnlyForItsLaunch() async throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    harness.versions.seed([harness.pi.path: AgentCLIVersion(major: 1, minor: 3, patch: 0)])
    let workspace = harness.workspace(agentMCPLaunch: harness.context)
    let suffix = try harness.suffix(.pi)
    #expect(suffix == " '-e' '\(harness.piExtension.path)'")

    let line = "\(harness.pi.path) --model x"
    let tab = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Pi", command: harness.pi.path, arguments: "--model x"),
        projectRoot: harness.directory.path
    )
    #expect(tab.launchCommand == line)
    #expect(tab.launchStartupCommand == line + suffix)
    #expect(tab.lastAgentMCPLaunchOutcome == .appended(suffix))
    let record = workspace.makeStateRecord(root: harness.directory.path, collapsedAgentGroupIDs: [])
    #expect(record.sessions.first { $0.id == tab.id }?.launchCommand == line)
    #expect(record.sessions.allSatisfy { !($0.launchCommand ?? "").contains("-e") })

    // Too old a Pi starts as its command says; a restart decides again.
    harness.versions.seed([harness.pi.path: AgentCLIVersion(major: 0, minor: 62, patch: 0)])
    #expect(tab.restart())
    #expect(tab.launchStartupCommand == nil)
    #expect(tab.lastAgentMCPLaunchOutcome == .skipped("pi 0.62.0 is older than 0.99.2"))
    #expect(tab.launchCommand == line)

    // A context-less workspace decides nothing.
    let plain = harness.workspace(agentMCPLaunch: nil).addAgentSession(
        agent: AgentToolDefinition(name: "Pi", command: harness.pi.path), projectRoot: harness.directory.path
    )
    #expect(plain.launchStartupCommand == nil)
    #expect(plain.lastAgentMCPLaunchOutcome == nil)
}

/// Pi prefers its own mcp.json entry of the server's name to the
/// extension's: the launch logs one that is not this app's, and changes
/// nothing.
@Test @MainActor func controlToolLaunchLogsAPiRegistrationThatPiPrefers() async throws {
    let harness = try LaunchHarness()
    defer { harness.cleanUp() }
    let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    let token = SessionLog.observe { entry in seen.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(token) }
    func notes() -> [String] { seen.withLock { $0 }.filter { $0.hasPrefix("[mcp] Pi's mcp.json") } }
    harness.versions.seed([harness.pi.path: AgentCLIVersion(major: 1, minor: 3, patch: 0)])
    let agentDirectory = harness.directory.appendingPathComponent("pi-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
    var context = harness.context
    context.piAgentDirectory = { agentDirectory }
    let workspace = harness.workspace(agentMCPLaunch: context)
    let pi = AgentToolDefinition(name: "Pi", command: harness.pi.path)
    let name = CherryAppIdentity.current.urlScheme

    // A stale entry: Pi runs it instead of the extension's server.
    let stale = "/nonexistent-\(UUID().uuidString)/CherryMCP"
    try #"{"mcpServers":{"\#(name)":{"command":"\#(stale)","exposure":"deferred"}}}"#
        .write(to: agentDirectory.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    let suffix = try harness.suffix(.pi)
    let tab = workspace.addAgentSession(agent: pi, projectRoot: harness.directory.path)
    #expect(tab.launchStartupCommand == harness.pi.path + suffix)
    #expect(await launchEventually { !notes().isEmpty })
    #expect(notes() == [
        "[mcp] Pi's mcp.json has its own \(name) (it runs \(stale), which isn't there); Pi uses it instead of the launch-time server",
    ])

    // This app's own entry serves the agent as well: nothing to say.
    try #"{"mcpServers":{"\#(name)":{"command":"\#(launchHelperPath)","exposure":"deferred","description":"\#(PiMCPRegistration.serverDescription)"}}}"#
        .write(to: agentDirectory.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    #expect(tab.restart())
    try await Task.sleep(for: .milliseconds(300))
    #expect(notes().count == 1)
    // A Claude Code agent reads nothing of Pi's.
    let claudeTab = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Claude", command: harness.claude.path), projectRoot: harness.directory.path
    )
    #expect(claudeTab.lastAgentMCPLaunchOutcome == .skipped("claude's version is not known yet"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(notes().count == 1)
}

@Test func controlToolLaunchSaysWhichPiRegistrationPiPrefers() {
    func note(_ status: PiMCPRegistration.EntryStatus) -> String? {
        AgentMCPLaunch.piRegistrationNote(status, serverName: "cherry")
    }
    let preferred = "; Pi uses it instead of the launch-time server"
    #expect(note(.notRegistered) == nil)
    #expect(note(.connected(.deferred)) == nil)
    #expect(note(.connected(.direct)) == nil)
    #expect(note(.toolsHidden(exposure: "codemode")) == "Pi's mcp.json has its own cherry (its exposure is codemode)" + preferred)
    #expect(note(.turnedOff) == "Pi's mcp.json has its own cherry (turned off)" + preferred)
    #expect(note(.otherHelper(path: "/old/CherryMCP", runs: true)) == "Pi's mcp.json has its own cherry (it runs /old/CherryMCP)" + preferred)
    #expect(note(.otherHelper(path: "/old/CherryMCP", runs: false))
        == "Pi's mcp.json has its own cherry (it runs /old/CherryMCP, which isn't there)" + preferred)
    #expect(note(.otherArguments(line: "/h --x")) == "Pi's mcp.json has its own cherry (it runs /h --x)" + preferred)
    #expect(note(.unreadable("/p/mcp.json is not a JSON object")) == "Pi's mcp.json could not be read: /p/mcp.json is not a JSON object")
}

/// A persistent Pi tab on This Mac's host: its Create carries the extension
/// in the command its shell runs, and the variables the extension reads.
@Test @MainActor func controlToolLaunchAPersistentPiTabsCreateCarriesTheExtension() async throws {
    let launch = try LaunchHarness()
    let harness = try PersistentHarness(mcpHelperPath: launchHelperPath)
    var policy = harness.policy
    policy.agentMCPLaunch = launch.context
    let workspace = TerminalWorkspace(projectRoot: harness.project.path, createInitialSession: false, backendPolicy: policy)
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        launch.cleanUp()
    }
    launch.versions.seed([launch.pi.path: AgentCLIVersion(major: 1, minor: 3, patch: 0)])

    let agent = workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Pi", command: launch.pi.path), projectRoot: harness.project.path
    )
    #expect(agent.isPersistentLocalSession)
    #expect(await harness.waitUntilAttached(agent))
    let expected = launch.pi.path + AgentMCPLaunch.shellSuffix(["-e", launch.piExtension.path])
    #expect(agent.lastAgentMCPLaunchOutcome == .appended(AgentMCPLaunch.shellSuffix(["-e", launch.piExtension.path])))
    let create = try #require(harness.creates().first)
    let argv = try #require(create.json["command"] as? [String])
    let environment = create.json["env"] as? [String: String] ?? [:]
    if let startup = environment["CHERRY_STARTUP_COMMAND"] {
        #expect(startup == expected)
    } else {
        #expect(argv.last?.contains(ShellQuoting.singleQuoted("exec \(expected)")) == true, "\(argv)")
    }
    // The extension registers the tab's helper under the identity's name.
    #expect(environment["CHERRY_MCP_HELPER"] == launchHelperPath)
    #expect(environment["CHERRY_MCP_SERVER_NAME"] == CherryAppIdentity.current.urlScheme)
    let record = workspace.makeStateRecord(root: harness.project.path, collapsedAgentGroupIDs: [])
    #expect(record.sessions.first { $0.id == agent.id }?.launchCommand == launch.pi.path)
}
