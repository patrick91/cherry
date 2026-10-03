import CherryControl
import Foundation
import Testing
@testable import Cherry

// Settings › MCP's Pi row: the command it shows and runs (only on a
// click, through a runner tests replace), and whether Pi's mcp.json has
// Cherry, read without writing it. No test runs the real pi or reads ~/.pi.

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func SettingsMCPPiCommandAddsCherryWithDirectExposure() throws {
    let identity = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry-dev"], warn: { _ in })
    let pi = try #require(MCPInstallCommandBuilder.commands(identity: identity).first { $0.harness == .pi })
    #expect(pi.command == "pi mcp add cherry-dev --exposure direct -- \(MCPInstallCommandBuilder.helperCommand)")
    #expect(MCPHarness.pi.name == "Pi")
    #expect(PiMCPRegistration.addArguments(serverName: "cherry", helperPath: "/A B/CherryMCP")
        == ["mcp", "add", "cherry", "--exposure", "direct", "--", "/A B/CherryMCP"])
}

@Test func SettingsMCPPiStatusReadsPisSettingsWithoutWritingThem() throws {
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
    #expect(before.count > 0)

    // PI_CODING_AGENT_DIR wins over ~/.pi/agent.
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(PiMCPRegistration.agentDirectory(environment: [:], homeDirectory: home).path == "/Users/someone/.pi/agent")
    #expect(PiMCPRegistration.agentDirectory(environment: ["PI_CODING_AGENT_DIR": "~/pi"], homeDirectory: home).path == "/Users/someone/pi")
}

/// Add runs `pi mcp add` with exactly the shown arguments (a stand-in pi
/// here), then reads the status again.
@Test func SettingsMCPPiAddRunsPiOnlyWhenAskedAndRereadsTheStatus() async throws {
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
    #expect(PiMCPRegistration.locate(searchPath: "/nowhere:\(stub.deletingLastPathComponent().path)", homeDirectory: root.path) == stub)

    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    let model = await PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: helper,
        agentDirectory: agentDirectory,
        environment: { ["PATH": "/usr/bin:/bin"] },
        runner: { name, path, environment in
            await PiMCPRegistration.run(
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
@Test func SettingsMCPPiReadsTheAgentDirectoryOfTheEnvironmentPiRunsWith() async throws {
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
