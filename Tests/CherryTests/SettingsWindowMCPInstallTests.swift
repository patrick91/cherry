import CherryControl
import Foundation
import Testing
@testable import Cherry

// Connecting agent CLIs to Cherry MCP from Settings (an agent's page in
// Agents & MCP, and its Connect other agent CLIs): the commands shown and
// run (only on a click, through runners tests replace), where each CLI is
// looked for, and whether Pi's mcp.json has Cherry, read without writing
// it. No test runs the real claude, codex or pi, or reads ~/.claude.json,
// ~/.codex or ~/.pi: the CLIs here are stand-in scripts.

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An executable stand-in at `url` running `script`.
private func writeStandIn(_ script: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    chmod(url.path, 0o755)
}

@Test func settingsWindowMCPPiCommandAddsCherryWithDirectExposure() throws {
    let identity = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry-dev"], warn: { _ in })
    let pi = try #require(MCPInstallCommandBuilder.commands(identity: identity).first { $0.harness == .pi })
    #expect(pi.command == "pi mcp add cherry-dev --exposure direct -- \(MCPInstallCommandBuilder.helperCommand)")
    #expect(MCPHarness.pi.name == "Pi")
    #expect(PiMCPRegistration.addArguments(serverName: "cherry", helperPath: "/A B/CherryMCP")
        == ["mcp", "add", "cherry", "--exposure", "direct", "--", "/A B/CherryMCP"])
}

@Test func settingsWindowMCPPiStatusReadsPisSettingsWithoutWritingThem() throws {
    let agentDirectory = try temporaryDirectory("pi-agent")
    defer { try? FileManager.default.removeItem(at: agentDirectory) }
    let file = agentDirectory.appendingPathComponent("mcp.json")
    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    func status() -> PiMCPRegistration.Status {
        PiMCPRegistration.status(serverName: "cherry", helperPath: helper, agentDirectory: agentDirectory)
    }

    #expect(status() == .notRegistered)
    try #"{"mcpServers":{"other":{"command":"x"}}}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(status() == .notRegistered)
    try #"{"mcpServers":{"cherry":{"command":"/Applications/Cherry.app/Contents/MacOS/CherryMCP","exposure":"direct"}}}"#
        .write(to: file, atomically: true, encoding: .utf8)
    #expect(status() == .registered)
    let before = try Data(contentsOf: file)
    #expect(status() == .registered)
    #expect(try Data(contentsOf: file) == before, "reading leaves Pi's mcp.json as it was")
    // Pi's default exposure hides the tools behind its script tool.
    try #"{"mcpServers":{"cherry":{"command":"/Applications/Cherry.app/Contents/MacOS/CherryMCP"}}}"#
        .write(to: file, atomically: true, encoding: .utf8)
    guard case .differs(let why) = status() else {
        Issue.record("Expected differs, got \(status())")
        return
    }
    #expect(why.contains("codemode"))
    try #"{"mcpServers":{"cherry":{"command":"/old/CherryMCP","exposure":"direct"}}}"#.write(to: file, atomically: true, encoding: .utf8)
    guard case .differs(let other) = status() else {
        Issue.record("Expected differs, got \(status())")
        return
    }
    #expect(other.contains("/old/CherryMCP"))
    try "not json".write(to: file, atomically: true, encoding: .utf8)
    guard case .unreadable = status() else {
        Issue.record("Expected unreadable, got \(status())")
        return
    }

    // PI_CODING_AGENT_DIR wins over ~/.pi/agent.
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(PiMCPRegistration.agentDirectory(environment: [:], homeDirectory: home).path == "/Users/someone/.pi/agent")
    #expect(PiMCPRegistration.agentDirectory(environment: ["PI_CODING_AGENT_DIR": "~/pi"], homeDirectory: home).path == "/Users/someone/pi")
}

/// Add runs `pi mcp add` with exactly the shown arguments (a stand-in pi
/// here), then reads the status again.
@Test func settingsWindowMCPPiAddRunsPiOnlyWhenAskedAndRereadsTheStatus() async throws {
    let root = try temporaryDirectory("pi-add")
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDirectory = root.appendingPathComponent("agent", isDirectory: true)
    let log = root.appendingPathComponent("pi.log")
    // The stand-in writes Pi's mcp.json as `pi mcp add` would.
    let stub = root.appendingPathComponent("bin/pi")
    try FileManager.default.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(log.path)'
    mkdir -p '\(agentDirectory.path)'
    printf '{"mcpServers":{"%s":{"command":"%s","exposure":"%s"}}}' "$3" "$7" "$5" > '\(agentDirectory.path)/mcp.json'
    echo "Added global MCP server \\"$3\\""
    """.write(to: stub, atomically: true, encoding: .utf8)
    chmod(stub.path, 0o755)
    #expect(MCPCLIRegistration.locate(executable: "pi", searchPath: "/nowhere:\(stub.deletingLastPathComponent().path)", homeDirectory: root.path) == stub)

    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    let model = await PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: helper,
        agentDirectory: agentDirectory,
        environment: { ["PATH": "/usr/bin:/bin"] },
        runner: { name, path, environment in
            await MCPCLIRegistration.run(
                executable: stub,
                arguments: PiMCPRegistration.addArguments(serverName: name, helperPath: path),
                environment: environment
            )
        }
    )
    await model.refresh()
    #expect(await model.status == .notRegistered)
    #expect(!FileManager.default.fileExists(atPath: log.path), "nothing runs before the click")
    await model.register()
    #expect(try String(contentsOf: log, encoding: .utf8) == "mcp add cherry --exposure direct -- \(helper)\n")
    #expect(await model.status == .registered)
    #expect(await model.message == "Added global MCP server \"cherry\"")
    #expect(await !model.lastRunFailed)

    // A failing pi says why.
    let failing = await PiMCPRegistrationModel(
        serverName: "cherry", helperPath: helper, agentDirectory: root.appendingPathComponent("none"),
        environment: { [:] },
        runner: { _, _, _ in PiMCPRegistration.RunOutcome(status: 1, output: "boom\n") }
    )
    await failing.register()
    #expect(await failing.lastRunFailed)
    #expect(await failing.message == "boom")
}

/// Pi's settings are read where `pi` reads them: the agent directory the
/// environment `pi` runs with names (its login shell's
/// PI_CODING_AGENT_DIR), not Cherry's own environment; and `pi` runs in
/// that same environment.
@Test func settingsWindowMCPPiReadsTheAgentDirectoryOfTheEnvironmentPiRunsWith() async throws {
    let root = try temporaryDirectory("pi-env")
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("custom-agent", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    try #"{"mcpServers":{"cherry":{"command":"/Applications/Cherry.app/Contents/MacOS/CherryMCP","exposure":"direct"}}}"#
        .write(to: custom.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    let login = ["PATH": "/usr/bin:/bin", "HOME": home.path, "PI_CODING_AGENT_DIR": custom.path]
    let ran = Recorder<[String: String]?>(nil)
    let model = await PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: helper,
        environment: { login },
        runner: { _, _, environment in
            ran.value = environment
            return PiMCPRegistration.RunOutcome(status: 0, output: "")
        }
    )
    #expect(await model.statusText == "Reading Pi's MCP settings…")
    await model.refresh()
    #expect(await model.agentDirectory?.path == custom.path)
    #expect(await model.status == .registered)
    // Without the variable: that environment's HOME, not Cherry's.
    let plain = await PiMCPRegistrationModel(serverName: "cherry", helperPath: helper, environment: { ["HOME": home.path] })
    await plain.refresh()
    #expect(await plain.agentDirectory?.path == home.appendingPathComponent(".pi/agent").path)
    #expect(await plain.status == .notRegistered)
    await model.register()
    #expect(ran.value?["PI_CODING_AGENT_DIR"] == custom.path)
}

// MARK: - Claude Code and Codex

/// Each CLI's Add runs exactly the arguments of the command its page
/// shows to copy (the helper quoted there), in the order the install
/// commands keep (Codex, Claude Code, Pi).
@Test func settingsWindowMCPEachCLIsAddRunsTheCommandItsPageShows() {
    let helper = "/A B/CherryMCP"
    #expect(MCPHarness.claude.addArguments(serverName: "cherry", helperPath: helper)
        == ["mcp", "add", "--transport", "stdio", "--scope", "user", "cherry", "--", helper])
    #expect(MCPHarness.codex.addArguments(serverName: "cherry", helperPath: helper)
        == ["mcp", "add", "cherry", "--", helper])
    #expect(MCPHarness.pi.addArguments(serverName: "cherry", helperPath: helper)
        == PiMCPRegistration.addArguments(serverName: "cherry", helperPath: helper))
    #expect(MCPHarness.allCases.map(\.executableName) == ["codex", "claude", "pi"])
    #expect(MCPHarness.allCases.map(\.productName) == ["Codex", "Claude Code", "Pi"])
    #expect(MCPHarness.allCases.allSatisfy { $0.brand.mcpHarness == $0 })

    let identity = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry-dev"], warn: { _ in })
    let quoted = MCPInstallCommandBuilder.helperCommand
    #expect(MCPInstallCommandBuilder.command(for: .claude, identity: identity).command
        == "claude mcp add --transport stdio --scope user cherry-dev -- \(quoted)")
    #expect(MCPInstallCommandBuilder.command(for: .codex, identity: identity).command
        == "codex mcp add cherry-dev -- \(quoted)")
    for harness in MCPHarness.allCases {
        let shown = MCPInstallCommandBuilder.command(for: harness, identity: identity)
        #expect(shown.command == ([harness.executableName] + harness.addArguments(serverName: "cherry-dev", helperPath: quoted))
            .joined(separator: " "))
        #expect(MCPInstallCommandBuilder.commands(identity: identity).contains(shown))
    }
    #expect(MCPInstallCommandBuilder.commands(identity: identity).map(\.harness) == [.codex, .claude, .pi])
}

/// A CLI is looked for on the login shell's PATH first, then where its
/// installers put it: ~/.claude/local is Claude Code's own.
@Test func settingsWindowMCPLocateFindsClaudeInClaudeLocalOfATemporaryHome() throws {
    let home = try temporaryDirectory("mcp-home")
    defer { try? FileManager.default.removeItem(at: home) }
    let standIn = "#!/bin/sh\nexit 0\n"
    let claudeLocal = home.appendingPathComponent(".claude/local/claude")
    try writeStandIn(standIn, to: claudeLocal)

    #expect(MCPCLIRegistration.locate(executable: "claude", searchPath: "/nowhere", homeDirectory: home.path)?.path
        == claudeLocal.path)
    // ~/.local/bin comes before it, and the PATH before both.
    let localBin = home.appendingPathComponent(".local/bin/claude")
    try writeStandIn(standIn, to: localBin)
    #expect(MCPCLIRegistration.locate(executable: "claude", searchPath: "/nowhere", homeDirectory: home.path)?.path
        == localBin.path)
    let onPath = home.appendingPathComponent("bin/claude")
    try writeStandIn(standIn, to: onPath)
    #expect(MCPCLIRegistration.locate(
        executable: "claude",
        searchPath: "/nowhere:\(onPath.deletingLastPathComponent().path)",
        homeDirectory: home.path
    )?.path == onPath.path)
    // A file that does not run is not the CLI.
    let notExecutable = home.appendingPathComponent("plain/claude")
    try FileManager.default.createDirectory(at: notExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try standIn.write(to: notExecutable, atomically: true, encoding: .utf8)
    #expect(MCPCLIRegistration.locate(
        executable: "claude",
        searchPath: notExecutable.deletingLastPathComponent().path,
        homeDirectory: home.path
    )?.path == localBin.path)
    // A name no Mac has.
    #expect(MCPCLIRegistration.locate(
        executable: "cherry-test-missing-\(UUID().uuidString.prefix(8))",
        searchPath: "/nowhere",
        homeDirectory: home.path
    ) == nil)

    #expect(MCPCLIRegistration.fallbackDirectories(homeDirectory: "/Users/someone") == [
        "/Users/someone/.local/bin", "/Users/someone/.claude/local", "/Users/someone/.bun/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ])
    #expect(MCPCLIRegistration.notFoundMessage(executable: "claude")
        == "claude was not found on the login shell's PATH (nor in ~/.local/bin, ~/.claude/local, ~/.bun/bin, /opt/homebrew/bin or /usr/local/bin).")
}

/// Add to Claude Code runs `claude mcp add` (a stand-in claude here) with
/// exactly the shown arguments, only when asked, and says what it printed.
@Test func settingsWindowMCPClaudeAddRunsClaudeOnlyWhenAskedWithTheShownArguments() async throws {
    let root = try temporaryDirectory("claude-add")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("claude.log")
    let stub = root.appendingPathComponent("bin/claude")
    try writeStandIn("""
    #!/bin/sh
    printf '%s\\n' "$*" >> '\(log.path)'
    echo "Added stdio MCP server $7 with command: $9 to user config"
    """, to: stub)

    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    let environments = Recorder<[[String: String]]>([])
    let model = await MCPCLIRegistrationModel(
        harness: .claude,
        serverName: "cherry",
        helperPath: helper,
        environment: { ["PATH": "/usr/bin:/bin", "HOME": root.path] },
        runner: { name, path, environment in
            environments.value.append(environment)
            return await MCPCLIRegistration.run(
                executable: stub,
                arguments: MCPHarness.claude.addArguments(serverName: name, helperPath: path),
                environment: environment
            )
        }
    )
    #expect(await model.status == .notChecked)
    #expect(await model.statusText == "Not checked")
    #expect(await model.message == nil)
    #expect(!FileManager.default.fileExists(atPath: log.path), "nothing runs before the click")
    #expect(environments.value.isEmpty, "nor is the login environment read")

    await model.register()
    #expect(try String(contentsOf: log, encoding: .utf8) == "mcp add --transport stdio --scope user cherry -- \(helper)\n")
    #expect(environments.value == [["PATH": "/usr/bin:/bin", "HOME": root.path]])
    #expect(await model.status == .added)
    #expect(await model.statusText == "Added")
    #expect(await model.message == "Added stdio MCP server cherry with command: \(helper) to user config")
    #expect(await !model.isRunning)
}

/// Add to Codex finds `codex` on the login shell's PATH and runs it in
/// that environment (a stand-in codex, which the lookup must find first).
@Test func settingsWindowMCPCodexAddRunsCodexFromTheLoginShellsPath() async throws {
    let root = try temporaryDirectory("codex-add")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("codex.log")
    let stub = root.appendingPathComponent("bin/codex")
    try writeStandIn("""
    #!/bin/sh
    printf '%s|%s\\n' "$*" "$SETTINGS_TEST_LOGIN" >> '\(log.path)'
    echo "Added global MCP server '$3'."
    """, to: stub)
    let login = ["PATH": stub.deletingLastPathComponent().path, "HOME": root.path, "SETTINGS_TEST_LOGIN": "login shell"]
    // The real codex is never reached: the stand-in is what Add runs.
    let found = try #require(MCPCLIRegistration.locate(executable: "codex", searchPath: login["PATH"]!, homeDirectory: root.path))
    try #require(found.path == stub.path)

    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    let model = await MCPCLIRegistrationModel(harness: .codex, serverName: "cherry", helperPath: helper, environment: { login })
    await model.register()
    #expect(try String(contentsOf: log, encoding: .utf8) == "mcp add cherry -- \(helper)|login shell\n")
    #expect(await model.status == .added)
    #expect(await model.message == "Added global MCP server 'cherry'.")
}

/// A refused Add is "Failed" with what the CLI said (Claude Code's "already
/// exists" included: Add never removes a server first), or its status when
/// it said nothing; without a helper nothing runs.
@Test func settingsWindowMCPCLIAddThatFailsSaysWhy() async throws {
    let failing = await MCPCLIRegistrationModel(
        harness: .claude,
        serverName: "cherry",
        helperPath: "/Applications/Cherry.app/Contents/MacOS/CherryMCP",
        environment: { [:] },
        runner: { _, _, _ in MCPCLIRegistration.RunOutcome(status: 1, output: "MCP server cherry already exists in user config\n") }
    )
    await failing.register()
    #expect(await failing.status == .failed)
    #expect(await failing.statusText == "Failed")
    #expect(await failing.message == "MCP server cherry already exists in user config")

    let silent = await MCPCLIRegistrationModel(
        harness: .codex,
        serverName: "cherry",
        helperPath: "/Applications/Cherry.app/Contents/MacOS/CherryMCP",
        environment: { [:] },
        runner: { _, _, _ in MCPCLIRegistration.RunOutcome(status: 2, output: " \n") }
    )
    await silent.register()
    #expect(await silent.status == .failed)
    #expect(await silent.message == "codex exited with status 2.")

    let ran = Recorder(0)
    let noHelper = await MCPCLIRegistrationModel(
        harness: .claude,
        serverName: "cherry",
        helperPath: nil,
        environment: { [:] },
        runner: { _, _, _ in
            ran.value += 1
            return MCPCLIRegistration.RunOutcome(status: 0, output: "")
        }
    )
    await noHelper.register()
    #expect(ran.value == 0)
    #expect(await noHelper.status == .notChecked)
}

/// One model per CLI, whichever page asks for it: what Add did stays when
/// the page goes, and two agents of one CLI share it.
@Test @MainActor func settingsWindowMCPRegistrationsKeepOneModelPerCLI() {
    let registrations = MCPRegistrations(
        claude: MCPCLIRegistrationModel(harness: .claude, helperPath: nil, environment: { [:] }),
        codex: MCPCLIRegistrationModel(harness: .codex, helperPath: nil, environment: { [:] }),
        pi: PiMCPRegistrationModel(helperPath: nil, agentDirectory: URL(fileURLWithPath: "/nowhere"), environment: { [:] })
    )
    #expect(registrations.cliModel(for: .claude) === registrations.claude)
    #expect(registrations.cliModel(for: .codex) === registrations.codex)
    #expect(registrations.cliModel(for: .claude) === registrations.cliModel(for: .claude))
    #expect(registrations.cliModel(for: .claude) !== registrations.cliModel(for: .codex))
    #expect(registrations.cliModel(for: .pi) == nil)
    #expect(registrations.claude.harness == .claude)
    #expect(registrations.codex.harness == .codex)
}
