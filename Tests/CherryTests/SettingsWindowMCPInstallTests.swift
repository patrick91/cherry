import CherryControl
import Foundation
import Testing
@testable import Cherry

// Connecting agent CLIs to Cherry MCP from Settings (an agent's page in
// Agents & MCP, and its Connect other agent CLIs): the commands shown and
// run (only a confirmed plan, `perform`), where each CLI is looked for,
// Pi's version gate (no `pi mcp` on a Pi without MCP), and what Pi's
// mcp.json has, read without writing it. No test runs the real claude,
// codex or pi, or reads ~/.claude.json, ~/.codex or ~/.pi: the CLIs here
// are stand-in scripts, found on an injected PATH with no fallback
// directories. ControlToolConnectTests covers the sheets.

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

// MARK: - Pi

/// `pi` on the environment's PATH only, never in a fallback directory, so
/// a test never finds a real `pi` in /opt/homebrew/bin or /usr/local/bin.
private let pathOnlyLocator: PiMCPRegistration.Locator = { executable, environment in
    MCPCLIRegistration.locate(
        executable: executable,
        searchPath: environment["PATH"] ?? "",
        homeDirectory: environment["HOME"] ?? "/nonexistent",
        fallbackDirectories: []
    )
}

/// A stand-in `pi` in a temporary directory with a private HOME and agent
/// directory: `--version` runs `versionCommand`; any other argv is
/// appended to `calls` (`[word]…`, one line a run), as an old Pi would take
/// the words as prompts, then `mcp add` runs `onAdd`.
private struct PiStandIn {
    let root: URL

    init(_ name: String) throws {
        root = try temporaryDirectory(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    var pi: URL { bin.appendingPathComponent("pi") }
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var agentDirectory: URL { root.appendingPathComponent("agent", isDirectory: true) }
    var calls: URL { root.appendingPathComponent("calls.txt") }
    var environment: [String: String] {
        ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "PI_CODING_AGENT_DIR": agentDirectory.path]
    }

    func write(versionCommand: String, onAdd: String = "") throws {
        try writeStandIn("""
        #!/bin/sh
        if [ "$1" = --version ]; then \(versionCommand); fi
        printf '[%s]' "$@" >> '\(calls.path)'
        echo >> '\(calls.path)'
        if [ "$1 $2" = "mcp add" ]; then
        \(onAdd)
        fi
        exit 0
        """, to: pi)
    }

    /// Writes what `pi mcp add` writes from its argv (name, exposure,
    /// description, the helper after `--`).
    static let addsAsPiDoes = """
    mkdir -p "$PI_CODING_AGENT_DIR"
    printf '{"mcpServers":{"%s":{"command":"%s","exposure":"%s","description":"%s"}}}' "$3" "$9" "$5" "$7" > "$PI_CODING_AGENT_DIR/mcp.json"
    echo "Added global MCP server \\"$3\\" in $PI_CODING_AGENT_DIR/mcp.json."
    """

    /// Each run that was not `--version`; nil when there was none.
    func recordedCalls() -> [String]? {
        (try? String(contentsOf: calls, encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let piHelper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"

/// `pi mcp add`'s argv as the stand-in logs it.
private func loggedAdd(_ name: String, helper: String = piHelper) -> String {
    PiMCPRegistration.addArguments(serverName: name, helperPath: helper).map { "[\($0)]" }.joined()
}

@MainActor
private func piModel(_ standIn: PiStandIn, versions: AgentCLIVersions, helperPath: String? = piHelper) -> PiMCPRegistrationModel {
    let environment = standIn.environment
    return PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: helperPath,
        environment: { environment },
        locate: pathOnlyLocator,
        answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
}

@Test func settingsWindowMCPPiCommandAddsCherryWithDeferredExposure() throws {
    let identity = CherryAppIdentity(infoDictionary: ["CherryURLScheme": "cherry-dev"], warn: { _ in })
    let pi = try #require(MCPInstallCommandBuilder.commands(identity: identity).first { $0.harness == .pi })
    let description = PiMCPRegistration.serverDescription
    #expect(pi.command == "pi mcp add cherry-dev --exposure deferred --description '\(description)' -- \(MCPInstallCommandBuilder.helperCommand)")
    #expect(MCPHarness.pi.addCommand(serverName: "cherry", helperPath: "/Applications/Cherry.app/Contents/MacOS/CherryMCP")
        == "pi mcp add cherry --exposure deferred --description 'Cherry, the terminal app this Pi runs in: its tabs, agents, Cherry tasks (get_my_task, report_result), waits and ports. Load its tools with tool_search.' -- '/Applications/Cherry.app/Contents/MacOS/CherryMCP'")
    #expect(MCPHarness.pi.name == "Pi")
    #expect(PiMCPRegistration.addArguments(serverName: "cherry", helperPath: "/A B/CherryMCP")
        == ["mcp", "add", "cherry", "--exposure", "deferred", "--description", description, "--", "/A B/CherryMCP"])
    // One line in Pi's prompt (at most 250 characters), single-quotable as
    // it is.
    #expect(description.count <= 250)
    #expect(!description.contains("'"))
    #expect(PiMCPRegistration.minimumVersion == AgentCLIVersion(major: 0, minor: 99, patch: 2))
    // Claude Code, Codex and Pi are started with Cherry MCP on their
    // command line (Pi through Cherry's extension).
    #expect(MCPHarness.claude.launchCLI == .claudeCode)
    #expect(MCPHarness.codex.launchCLI == .codex)
    #expect(MCPHarness.pi.launchCLI == .pi)
    // Words are quoted only when a shell would not read them back as they
    // are; the helper always.
    #expect(MCPHarness.shownWord("--exposure") == "--exposure")
    #expect(MCPHarness.shownWord("a b") == "'a b'")
    #expect(MCPHarness.shownWord("") == "''")
    #expect(MCPHarness.shownWord("it's") == "'it'\\''s'")
    // zsh expands a word that starts with `=` to a command's path.
    #expect(MCPHarness.shownWord("=cherry") == "'=cherry'")
    #expect(MCPHarness.shownWord("a=b") == "a=b")
    #expect(MCPHarness.codex.addCommand(serverName: "cherry", helperPath: nil) == "codex mcp add cherry -- CherryMCP")
}

/// What Pi's mcp.json has, read without writing it: its `enabled`,
/// `command`, `args` and `exposure` only.
@Test func settingsWindowMCPPiEntryStatusFixtures() throws {
    let agentDirectory = try temporaryDirectory("pi-agent")
    defer { try? FileManager.default.removeItem(at: agentDirectory) }
    let file = agentDirectory.appendingPathComponent("mcp.json")
    func status(_ json: String?) throws -> PiMCPRegistration.EntryStatus {
        if let json {
            try json.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        return PiMCPRegistration.status(serverName: "cherry", helperPath: piHelper, agentDirectory: agentDirectory)
    }
    func entry(_ fields: String) -> String {
        #"{"mcpServers":{"cherry":{"#+fields+#"}}}"#
    }
    let command = #""command":"/Applications/Cherry.app/Contents/MacOS/CherryMCP""#

    #expect(try status(nil) == .notRegistered)
    #expect(try status(#"{"mcpServers":{"other":{"command":"x"}}}"#) == .notRegistered)
    #expect(try status(#"{"autoEnableCodemode":true}"#) == .notRegistered)
    #expect(try status(entry(command + #","exposure":"deferred""#)) == .connected(.deferred))
    let before = try Data(contentsOf: file)
    #expect(try status(nil) == .notRegistered)
    try before.write(to: file)
    #expect(PiMCPRegistration.status(serverName: "cherry", helperPath: piHelper, agentDirectory: agentDirectory) == .connected(.deferred))
    #expect(try Data(contentsOf: file) == before, "reading leaves Pi's mcp.json as it was")
    #expect(try status(entry(command + #","exposure":"direct""#)) == .connected(.direct))
    // No exposure is Pi's default, codemode; codemode and hidden keep the
    // tools from the model too.
    #expect(try status(entry(command)) == .toolsHidden(exposure: "codemode"))
    #expect(try status(entry(command + #","exposure":"codemode""#)) == .toolsHidden(exposure: "codemode"))
    #expect(try status(entry(command + #","exposure":"hidden""#)) == .toolsHidden(exposure: "hidden"))
    // Turned off comes before anything else.
    #expect(try status(entry(#""command":"/old/CherryMCP","enabled":false"#)) == .turnedOff)
    #expect(try status(entry(command + #","exposure":"deferred","enabled":true"#)) == .connected(.deferred))
    // Another helper: one that is gone, and one that runs.
    #expect(try status(entry(#""command":"/nonexistent/CherryMCP","exposure":"deferred""#))
        == .otherHelper(path: "/nonexistent/CherryMCP", runs: false))
    let other = agentDirectory.appendingPathComponent("Other.app/CherryMCP")
    try writeStandIn("#!/bin/sh\nexit 0\n", to: other)
    #expect(try status(entry(#""command":""#+other.path+#"","exposure":"deferred""#)) == .otherHelper(path: other.path, runs: true))
    // This helper with arguments, or no command at all.
    #expect(try status(entry(command + #","args":["--debug","a b"],"exposure":"deferred""#))
        == .otherArguments(line: "/Applications/Cherry.app/Contents/MacOS/CherryMCP --debug 'a b'"))
    #expect(try status(entry(#""url":"https://example.com/mcp""#)) == .otherArguments(line: "https://example.com/mcp"))
    // Its description, environment and timeout are Pi's business.
    #expect(try status(entry(command + #","exposure":"deferred","description":"something else","env":{"A":"1"},"timeout":60,"args":[]"#))
        == .connected(.deferred))
    // A name Pi takes for the same server (`-` and `_` alike).
    #expect(PiMCPRegistration.status(serverName: "cherry_dev", helperPath: piHelper, agentDirectory: agentDirectory) == .notRegistered)
    try #"{"mcpServers":{"cherry-dev":{"command":"/x/CherryMCP","enabled":false}}}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(PiMCPRegistration.status(serverName: "cherry_dev", helperPath: piHelper, agentDirectory: agentDirectory) == .turnedOff)
    // Not JSON, or not an object.
    guard case .unreadable(let why) = try status("not json") else {
        Issue.record("Expected unreadable")
        return
    }
    #expect(why == "\(file.path) is not a JSON object")
    guard case .unreadable = try status("[1, 2]") else {
        Issue.record("Expected unreadable")
        return
    }
    // A command under `~` is this user's home.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    try entry(#""command":"~/Applications/Cherry.app/Contents/MacOS/CherryMCP","exposure":"deferred""#)
        .write(to: file, atomically: true, encoding: .utf8)
    #expect(PiMCPRegistration.status(serverName: "cherry", helperPath: "\(home)/Applications/Cherry.app/Contents/MacOS/CherryMCP", agentDirectory: agentDirectory)
        == .connected(.deferred))

    // PI_CODING_AGENT_DIR wins over ~/.pi/agent.
    let someone = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    #expect(PiMCPRegistration.agentDirectory(environment: [:], homeDirectory: someone).path == "/Users/someone/.pi/agent")
    #expect(PiMCPRegistration.agentDirectory(environment: ["PI_CODING_AGENT_DIR": "~/pi"], homeDirectory: someone).path == "/Users/someone/pi")

    // The model's state from the version and the entry.
    let version = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    #expect(PiMCPRegistration.State(version: version, entry: .notRegistered) == .notConnected(version))
    #expect(PiMCPRegistration.State(version: version, entry: .connected(.direct)) == .connected(version, .direct))
    #expect(PiMCPRegistration.State(version: version, entry: .toolsHidden(exposure: "hidden")) == .toolsHidden(version, "hidden"))
    #expect(PiMCPRegistration.State(version: version, entry: .turnedOff) == .turnedOff(version))
    #expect(PiMCPRegistration.State(version: version, entry: .otherHelper(path: "/x", runs: true)) == .otherHelper(version, path: "/x", runs: true))
    #expect(PiMCPRegistration.State(version: version, entry: .otherArguments(line: "/x -v")) == .otherArguments(version, line: "/x -v"))
    #expect(PiMCPRegistration.State(version: version, entry: .unreadable("why")) == .unreadable(version, "why"))
}

/// A Pi without MCP (0.62.0 here) takes `pi mcp add …` as prompts for its
/// model: it is asked its version, and nothing else, by the model's
/// refresh, a Connect plan's run and the gated register; so is a Pi whose
/// version Cherry can't read, or that does not answer.
@Test @MainActor func settingsWindowMCPPiOldPiIsNeverAskedAnythingButItsVersion() async throws {
    let standIn = try PiStandIn("pi-old")
    defer { standIn.remove() }
    try standIn.write(versionCommand: "echo 0.62.0; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    let versions = AgentCLIVersions(environment: { [:] })
    let model = piModel(standIn, versions: versions)
    let old = AgentCLIVersion(major: 0, minor: 62, patch: 0)
    #expect(model.state == .checking)

    await model.refresh()
    #expect(model.state == .withoutMCP(old))
    #expect(standIn.recordedCalls() == nil)
    #expect(model.agentDirectory?.path == standIn.agentDirectory.path)

    // Its plan names the pi found; its run asks the version again and is
    // refused.
    let plan = try #require(model.plan(for: .connect))
    #expect(plan.steps.map(\.executable) == [standIn.pi])
    #expect(standIn.recordedCalls() == nil, "building a plan runs nothing")
    await model.perform(plan)
    let refusal = "\(standIn.pi.path) is Pi 0.62.0, which has no MCP: update Pi to 0.99.2 or later."
    #expect(model.lastRunFailed)
    #expect(!model.lastRunSucceeded)
    #expect(model.message == refusal)
    #expect(model.state == .withoutMCP(old))
    #expect(standIn.recordedCalls() == nil)

    let gated = await PiMCPRegistration.register(
        serverName: "cherry", helperPath: piHelper, environment: standIn.environment,
        locate: pathOnlyLocator, answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
    #expect(gated == .init(status: -1, output: refusal))
    #expect(standIn.recordedCalls() == nil)

    // A version Cherry can't read: what it printed (its lines joined, at
    // most 200 characters), and still nothing else.
    #expect(AgentCLIVersions.shownOutput("  pi\n\n  dev build \n") == "pi dev build")
    #expect(AgentCLIVersions.shownOutput(String(repeating: "x", count: 300)).count == 200)
    try standIn.write(versionCommand: "echo garbage; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    await model.refresh()
    #expect(model.state == .unknownVersion(path: standIn.pi.path, output: "garbage"))
    await model.perform(try #require(model.plan(for: .connect)))
    #expect(model.message == "\(standIn.pi.path) --version printed “garbage”; Cherry connects only a Pi it knows has MCP (0.99.2 or later).")
    #expect(standIn.recordedCalls() == nil)

    // One that does not answer in time.
    try standIn.write(versionCommand: "exec /bin/sleep 30", onAdd: PiStandIn.addsAsPiDoes)
    let slow = piModel(standIn, versions: AgentCLIVersions(environment: { [:] }, timeout: 0.5))
    await slow.refresh()
    #expect(slow.state == .noAnswer(path: standIn.pi.path))
    await slow.perform(try #require(slow.plan(for: .connect)))
    #expect(slow.lastRunFailed)
    #expect(slow.message == "\(standIn.pi.path) --version did not answer.")
    #expect(standIn.recordedCalls() == nil)
    #expect(!FileManager.default.fileExists(atPath: standIn.agentDirectory.path), "nothing wrote Pi's settings")
}

/// Pi 0.62.0 prints its version on standard error when its input is not a
/// terminal. A version only standard error names says Update Pi for an
/// older Pi, and nothing more: no `pi mcp` runs, nor anything but
/// `--version`, and no command to run by hand shows. One that names a Pi
/// with MCP there stays unknown, and runs nothing either.
@Test @MainActor func settingsWindowMCPPiVersionOnStandardErrorOnlyNamesAnOlderPi() async throws {
    let standIn = try PiStandIn("pi-stderr")
    defer { standIn.remove() }
    try standIn.write(versionCommand: "echo 0.62.0 >&2; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    let versions = AgentCLIVersions(environment: { [:] })
    let model = piModel(standIn, versions: versions)
    let old = AgentCLIVersion(major: 0, minor: 62, patch: 0)

    await model.refresh()
    #expect(model.state == .withoutMCP(old))
    #expect(AgentSettingsPage.piRow(for: model.state, serverName: "cherry").status == "Update Pi")
    #expect(!AgentSettingsPage.showsCommand(for: .pi, pi: model.state))
    #expect(AgentConnection.row(pi: model.state, serverName: "cherry", connectsAtLaunch: true).commandAction == nil)
    // Never its version: a launch knows none.
    #expect(versions.version(of: standIn.pi.path) == nil)
    await model.perform(try #require(model.plan(for: .connect)))
    #expect(model.lastRunFailed)
    #expect(model.message == "\(standIn.pi.path) is Pi 0.62.0, which has no MCP: update Pi to 0.99.2 or later.")
    #expect(model.state == .withoutMCP(old))
    let gated = await PiMCPRegistration.register(
        serverName: "cherry", helperPath: piHelper, environment: standIn.environment,
        locate: pathOnlyLocator, answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
    #expect(gated.status == -1)
    #expect(standIn.recordedCalls() == nil, "pi ran nothing but --version")

    // A Pi with MCP that names itself only there: still unknown.
    try standIn.write(versionCommand: "echo 1.3.0 >&2; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    await model.refresh(asksAgain: true)
    #expect(model.state == .unknownVersion(path: standIn.pi.path, output: ""))
    #expect(AgentSettingsPage.piRow(for: model.state, serverName: "cherry").status == "Unknown Pi")
    #expect(!AgentSettingsPage.showsCommand(for: .pi, pi: model.state))
    await model.perform(try #require(model.plan(for: .connect)))
    #expect(model.lastRunFailed)
    #expect(model.message == "\(standIn.pi.path) --version printed “”; Cherry connects only a Pi it knows has MCP (0.99.2 or later).")
    #expect(model.state == .unknownVersion(path: standIn.pi.path, output: ""))
    #expect(standIn.recordedCalls() == nil, "pi ran nothing but --version")
    #expect(!FileManager.default.fileExists(atPath: standIn.agentDirectory.path), "nothing wrote Pi's settings")
}

/// A shim (Volta, mise, asdf) stays the same file while the Pi it runs
/// changes: Connect asks its version again right before `pi mcp`, so a Pi
/// that went back to one without MCP is never given it, and Check Again
/// sees a Pi updated behind the same file.
@Test @MainActor func settingsWindowMCPPiConnectAsksAShimsVersionAgain() async throws {
    let standIn = try PiStandIn("pi-shim")
    defer { standIn.remove() }
    let shown = standIn.root.appendingPathComponent("version.txt")
    try "1.3.0\n".write(to: shown, atomically: true, encoding: .utf8)
    try standIn.write(versionCommand: "cat '\(shown.path)'; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    let model = piModel(standIn, versions: AgentCLIVersions(environment: { [:] }))
    let new = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    let old = AgentCLIVersion(major: 0, minor: 62, patch: 0)
    await model.refresh()
    #expect(model.state == .notConnected(new))

    // The shim now runs 0.62.0; the shim itself is unchanged.
    try "0.62.0\n".write(to: shown, atomically: true, encoding: .utf8)
    await model.refresh()
    #expect(model.state == .notConnected(new), "a page that shows again reads what is known")
    await model.perform(try #require(model.plan(for: .connect)))
    #expect(model.message == "\(standIn.pi.path) is Pi 0.62.0, which has no MCP: update Pi to 0.99.2 or later.")
    #expect(model.state == .withoutMCP(old))
    #expect(standIn.recordedCalls() == nil)

    // Updated again: Check Again sees it.
    try "1.3.0\n".write(to: shown, atomically: true, encoding: .utf8)
    await model.refresh()
    #expect(model.state == .withoutMCP(old))
    await model.refresh(asksAgain: true)
    #expect(model.state == .notConnected(new))
    #expect(standIn.recordedCalls() == nil)
}

/// Connect on a Pi with MCP runs exactly `addArguments` once, with the pi
/// that answered, and nothing before its plan runs; the state is read
/// again.
@Test @MainActor func settingsWindowMCPPi13ConnectRunsTheExactArgvOnce() async throws {
    let standIn = try PiStandIn("pi-13")
    defer { standIn.remove() }
    try standIn.write(versionCommand: "echo 1.3.0; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    let model = piModel(standIn, versions: AgentCLIVersions(environment: { [:] }))
    let version = AgentCLIVersion(major: 1, minor: 3, patch: 0)

    await model.refresh()
    #expect(model.state == .notConnected(version))
    #expect(standIn.recordedCalls() == nil, "nothing but --version runs before the click")

    let plan = try #require(model.plan(for: .connect))
    #expect(plan.displayedCommands == [
        "\(standIn.pi.path) mcp add cherry --exposure deferred --description '\(PiMCPRegistration.serverDescription)' -- '\(piHelper)'",
    ])
    #expect(plan.writes == "Pi writes \(standIn.agentDirectory.path)/mcp.json.")
    #expect(plan.replaces == nil)
    #expect(standIn.recordedCalls() == nil, "nor while the confirmation shows the plan")
    await model.perform(plan)
    #expect(standIn.recordedCalls() == [
        "[mcp][add][cherry][--exposure][deferred][--description][\(PiMCPRegistration.serverDescription)][--][\(piHelper)]",
    ])
    #expect(model.state == .connected(version, .deferred))
    #expect(model.message == "Added global MCP server \"cherry\" in \(standIn.agentDirectory.path)/mcp.json.")
    #expect(!model.lastRunFailed)
    #expect(model.lastRunSucceeded)
    #expect(!model.isRunning)
}

/// A refused Connect is shown as Pi said it, and never run again another
/// way.
@Test @MainActor func settingsWindowMCPPiAFailingAddIsNotRetried() async throws {
    let standIn = try PiStandIn("pi-fails")
    defer { standIn.remove() }
    try standIn.write(versionCommand: "echo 1.3.0; exit 0", onAdd: "echo 'Unknown option --description.' >&2; exit 1")
    let model = piModel(standIn, versions: AgentCLIVersions(environment: { [:] }))
    await model.refresh()
    await model.perform(try #require(model.plan(for: .connect)))
    #expect(model.lastRunFailed)
    #expect(model.message == "Unknown option --description.")
    #expect(standIn.recordedCalls() == [loggedAdd("cherry")])
    #expect(model.state == .notConnected(AgentCLIVersion(major: 1, minor: 3, patch: 0)))
}

/// Re-register over an entry whose helper is gone runs the same command,
/// which Pi replaces the entry with.
@Test @MainActor func settingsWindowMCPPiReRegisterReplacesABrokenEntry() async throws {
    let standIn = try PiStandIn("pi-broken")
    defer { standIn.remove() }
    try standIn.write(versionCommand: "echo 'pi 1.3.0'; exit 0", onAdd: PiStandIn.addsAsPiDoes)
    try FileManager.default.createDirectory(at: standIn.agentDirectory, withIntermediateDirectories: true)
    try #"{"mcpServers":{"cherry":{"command":"/nonexistent/CherryMCP","exposure":"deferred"}}}"#
        .write(to: standIn.agentDirectory.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    let model = piModel(standIn, versions: AgentCLIVersions(environment: { [:] }))
    let version = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    await model.refresh()
    #expect(model.state == .otherHelper(version, path: "/nonexistent/CherryMCP", runs: false))
    let plan = try #require(model.plan(for: .reRegister))
    #expect(plan.replaces == "It replaces Pi's current cherry, which runs /nonexistent/CherryMCP.")
    await model.perform(plan)
    #expect(standIn.recordedCalls() == [loggedAdd("cherry")])
    #expect(model.state == .connected(version, .deferred))
}

/// No pi on the injected PATH, and no fallback directories: not
/// installed, no plan, and the gated register says so without running
/// anything.
@Test @MainActor func settingsWindowMCPPiNotInstalledLooksNowhereReal() async throws {
    let home = try temporaryDirectory("pi-none")
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
    let model = PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: piHelper,
        environment: { environment },
        locate: pathOnlyLocator,
        answer: { _, _, _ in
            Issue.record("no pi is asked its version")
            return .noAnswer
        }
    )
    await model.refresh()
    #expect(model.state == .notInstalled)
    #expect(model.executable == nil)
    #expect(model.plan(for: .connect) == nil)
    let gated = await PiMCPRegistration.register(
        serverName: "cherry", helperPath: piHelper, environment: environment, locate: pathOnlyLocator,
        answer: { _, _, _ in .noAnswer }
    )
    #expect(gated == .init(status: -1, output: MCPCLIRegistration.notFoundMessage(executable: "pi")))
    #expect(model.state == .notInstalled)
}

/// Pi's settings are read where `pi` reads them: the agent directory the
/// environment `pi` runs with names (its login shell's
/// PI_CODING_AGENT_DIR), not Cherry's own environment; and `pi` runs in
/// that same environment.
@Test @MainActor func settingsWindowMCPPiReadsTheAgentDirectoryOfTheEnvironmentPiRunsWith() async throws {
    let standIn = try PiStandIn("pi-env")
    defer { standIn.remove() }
    let seen = standIn.root.appendingPathComponent("seen-agent-dir")
    try standIn.write(
        versionCommand: "echo 1.3.0; exit 0",
        onAdd: "printf '%s' \"$PI_CODING_AGENT_DIR\" > '\(seen.path)'\n" + PiStandIn.addsAsPiDoes
    )
    try FileManager.default.createDirectory(at: standIn.agentDirectory, withIntermediateDirectories: true)
    try #"{"mcpServers":{"cherry":{"command":"/Applications/Cherry.app/Contents/MacOS/CherryMCP","exposure":"deferred"}}}"#
        .write(to: standIn.agentDirectory.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    let versions = AgentCLIVersions(environment: { [:] })
    let model = piModel(standIn, versions: versions)
    await model.refresh()
    #expect(model.agentDirectory?.path == standIn.agentDirectory.path)
    #expect(model.state == .connected(AgentCLIVersion(major: 1, minor: 3, patch: 0), .deferred))
    // Without the variable: that environment's HOME, not Cherry's.
    var withoutDirectory = standIn.environment
    withoutDirectory["PI_CODING_AGENT_DIR"] = nil
    let fixedEnvironment = withoutDirectory
    let plain = PiMCPRegistrationModel(
        serverName: "cherry", helperPath: piHelper, environment: { fixedEnvironment },
        locate: pathOnlyLocator, answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
    await plain.refresh()
    #expect(plain.agentDirectory?.path == standIn.home.appendingPathComponent(".pi/agent").path)
    #expect(plain.state == .notConnected(AgentCLIVersion(major: 1, minor: 3, patch: 0)))
    await model.perform(try #require(model.plan(for: .connectAgain)))
    #expect(try String(contentsOf: seen, encoding: .utf8) == standIn.agentDirectory.path)
}

// MARK: - Claude Code and Codex

/// Each CLI's Add runs exactly the arguments of the command its page
/// shows to copy (the helper quoted there, and Pi's description), in the
/// order the install commands keep (Codex, Claude Code, Pi).
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
    #expect(MCPInstallCommandBuilder.command(for: .pi, identity: identity).command
        == "pi mcp add cherry-dev --exposure deferred --description '\(PiMCPRegistration.serverDescription)' -- \(quoted)")
    for harness in MCPHarness.allCases {
        let shown = MCPInstallCommandBuilder.command(for: harness, identity: identity)
        let words = harness.addArguments(serverName: "cherry-dev", helperPath: quoted).map {
            $0 == quoted ? $0 : MCPHarness.shownWord($0)
        }
        #expect(shown.command == ([harness.executableName] + words).joined(separator: " "))
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
    // A test's own fallback directories replace the installers' places.
    #expect(MCPCLIRegistration.locate(executable: "claude", searchPath: "/nowhere", homeDirectory: home.path, fallbackDirectories: []) == nil)
    #expect(MCPCLIRegistration.locate(
        executable: "claude", searchPath: "/nowhere", homeDirectory: "/nonexistent",
        fallbackDirectories: [claudeLocal.deletingLastPathComponent().path]
    )?.path == claudeLocal.path)

    #expect(MCPCLIRegistration.fallbackDirectories(homeDirectory: "/Users/someone") == [
        "/Users/someone/.local/bin", "/Users/someone/.claude/local", "/Users/someone/.bun/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ])
    #expect(MCPCLIRegistration.notFoundMessage(executable: "claude")
        == "claude was not found on the login shell's PATH (nor in ~/.local/bin, ~/.claude/local, ~/.bun/bin, /opt/homebrew/bin or /usr/local/bin).")
}

/// Codex's Connect finds `codex` on the login shell's PATH and runs its
/// plan in that environment (a stand-in codex, which the lookup must find
/// first), only when the plan runs; a Codex too old for `mcp get --json` is
/// "Not checked" and is asked nothing but its version.
@Test @MainActor func settingsWindowMCPCodexConnectRunsCodexFromTheLoginShellsPath() async throws {
    let root = try temporaryDirectory("codex-add")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("codex.log")
    let stub = root.appendingPathComponent("bin/codex")
    try writeStandIn("""
    #!/bin/sh
    if [ "$1" = --version ]; then echo 'codex-cli 0.150.0'; exit 0; fi
    printf '%s|%s\\n' "$*" "$SETTINGS_TEST_LOGIN" >> '\(log.path)'
    echo "Added global MCP server '$3'."
    """, to: stub)
    let login = ["PATH": stub.deletingLastPathComponent().path, "HOME": root.path, "SETTINGS_TEST_LOGIN": "login shell"]
    let helper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"
    let versions = AgentCLIVersions(environment: { [:] })
    let model = MCPCLIRegistrationModel(
        harness: .codex, serverName: "cherry", helperPath: helper, environment: { login },
        locate: pathOnlyLocator, answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
    await model.refresh()
    #expect(model.executable?.path == stub.path)
    #expect(model.state == .notChecked(AgentCLIVersion(major: 0, minor: 150, patch: 0), "Cherry can't read Codex 0.150.0's MCP settings."))
    #expect(!FileManager.default.fileExists(atPath: log.path), "nothing but --version runs before the plan")
    let plan = try #require(model.plan(for: .connect))
    #expect(plan.displayedCommands == ["\(stub.path) mcp add cherry -- '\(helper)'"])
    #expect(plan.writes == "Codex writes \(root.path)/.codex/config.toml.")
    #expect(plan.replaces == "If Codex has a cherry already, it replaces it.")
    await model.perform(plan)
    #expect(try String(contentsOf: log, encoding: .utf8) == "mcp add cherry -- \(helper)|login shell\n")
    #expect(!model.lastRunFailed)
    #expect(model.message == "Added global MCP server 'cherry'.")
}

/// A refused run is shown as the CLI said it (or its status when it said
/// nothing); without a helper there is no plan, so nothing runs.
@Test @MainActor func settingsWindowMCPCLIConnectThatFailsSaysWhy() async throws {
    let root = try temporaryDirectory("cli-fails")
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("bin/codex")
    try writeStandIn("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 0.150.0'; exit 0; fi\nexit 2\n", to: codex)
    let environment = ["PATH": codex.deletingLastPathComponent().path, "HOME": root.path]
    let versions = AgentCLIVersions(environment: { [:] })
    func model(helperPath: String?, run: MCPCLIRegistrationModel.Runner? = nil) -> MCPCLIRegistrationModel {
        MCPCLIRegistrationModel(
            harness: .codex, serverName: "cherry", helperPath: helperPath, environment: { environment },
            locate: pathOnlyLocator, answer: { await versions.answer($0, environment: $1, asksAgain: $2) },
            run: run ?? { step, environment, timeout in
                await MCPCLIRegistration.run(executable: step.executable, arguments: step.arguments, environment: environment, timeout: timeout)
            }
        )
    }
    let silent = model(helperPath: piHelper)
    await silent.refresh()
    await silent.perform(try #require(silent.plan(for: .connect)))
    #expect(silent.lastRunFailed)
    #expect(silent.message == "codex exited with status 2.")
    #expect(silent.row(connectsAtLaunch: true).status == "Not checked")

    let saying = model(helperPath: piHelper) { _, _, _ in .init(status: 1, output: "Error: config.toml is read-only\n") }
    await saying.refresh()
    await saying.perform(try #require(saying.plan(for: .connect)))
    #expect(saying.message == "Error: config.toml is read-only")

    let noHelper = model(helperPath: nil)
    await noHelper.refresh()
    #expect(noHelper.plan(for: .connect) == nil)
    #expect(noHelper.state == .notChecked(AgentCLIVersion(major: 0, minor: 150, patch: 0), "Cherry can't read Codex 0.150.0's MCP settings."))
}

/// One model per CLI, whichever page asks for it: what a run did stays when
/// the page goes, and two agents of one CLI share it.
@Test @MainActor func settingsWindowMCPRegistrationsKeepOneModelPerCLI() {
    let registrations = MCPRegistrations(
        claude: MCPCLIRegistrationModel(harness: .claude, helperPath: nil, environment: { [:] }, locate: { _, _ in nil }),
        codex: MCPCLIRegistrationModel(harness: .codex, helperPath: nil, environment: { [:] }, locate: { _, _ in nil }),
        pi: PiMCPRegistrationModel(
            helperPath: nil, agentDirectory: URL(fileURLWithPath: "/nowhere"), environment: { [:] }, locate: { _, _ in nil }
        )
    )
    #expect(registrations.cliModel(for: .claude) === registrations.claude)
    #expect(registrations.cliModel(for: .codex) === registrations.codex)
    #expect(registrations.cliModel(for: .claude) === registrations.cliModel(for: .claude))
    #expect(registrations.cliModel(for: .claude) !== registrations.cliModel(for: .codex))
    #expect(registrations.cliModel(for: .pi) == nil)
    #expect(registrations.claude.harness == .claude)
    #expect(registrations.codex.harness == .codex)
    #expect(registrations.model(for: .pi) === registrations.pi)
    #expect(registrations.model(for: .claude) === registrations.claude)
    #expect(registrations.models.map(\.harness) == [.claude, .codex, .pi])
}
