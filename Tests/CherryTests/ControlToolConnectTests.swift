import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Connecting the agent CLIs on This Mac to Cherry MCP (AgentConnections.swift,
// ConnectAgentsSheet.swift; docs/mcp.md › Setup): where Claude Code keeps
// its registration and what it has, what `codex mcp get --json` says, the
// rows' texts and buttons, Connect All, the confirmation, Connect This
// Agent's lines, and the Omni bar's rows. No test runs the real claude,
// codex or pi, or reads ~/.claude*, ~/.codex or ~/.pi: the CLIs here are
// stand-in scripts on an injected PATH with no fallback directories, in a
// temporary HOME, and every model is the test's own (never `.shared`).

/// A CLI on the environment's PATH only, never in a fallback directory,
/// so a test never finds a real one in /opt/homebrew/bin or /usr/local/bin.
private let pathOnly: MCPCLIRegistration.Locator = { executable, environment in
    MCPCLIRegistration.locate(
        executable: executable,
        searchPath: environment["PATH"] ?? "",
        homeDirectory: environment["HOME"] ?? "/nonexistent",
        fallbackDirectories: []
    )
}

private let connectHelper = "/Applications/Cherry.app/Contents/MacOS/CherryMCP"

/// A temporary directory with a `bin` for stand-in CLIs, a private HOME and
/// a log of every argv the stand-ins ran (`[word]…`, one line a run).
private struct ConnectStandIns {
    let root: URL

    init(_ name: String) throws {
        root = try canonicalTemporaryDirectory("cherry-connect-\(name)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var calls: URL { root.appendingPathComponent("calls.txt") }
    var environment: [String: String] {
        ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path]
    }

    /// `bin/<name>` running `body` after it logs its argv.
    func write(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '[%s]' "$@" >> '\(calls.path)'
        echo >> '\(calls.path)'
        \(body)
        """.write(to: url, atomically: true, encoding: .utf8)
        #expect(chmod(url.path, 0o755) == 0)
    }

    func url(_ name: String) -> URL { bin.appendingPathComponent(name) }

    func recordedCalls() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A stand-in Claude Code: `--version` prints 2.1.299; `mcp add` refuses a
/// name `$HOME/.claude.json` has, as Claude Code does, and otherwise writes
/// the entry it would; `mcp remove --scope user` deletes it, or says there
/// is none.
private let claudeStandIn = #"""
file="$HOME/.claude.json"
if [ "$1" = --version ]; then echo '2.1.299 (Claude Code)'; exit 0; fi
if [ "$1 $2" = "mcp add" ]; then
  if [ -f "$file" ] && grep -q "\"$7\"" "$file"; then echo "MCP server $7 already exists in user config" >&2; exit 1; fi
  printf '{"mcpServers":{"%s":{"type":"stdio","command":"%s","args":[],"env":{}}}}' "$7" "$9" > "$file"
  echo "Added stdio MCP server $7 with command: $9 to user config"
  echo "File modified: $file"
  exit 0
fi
if [ "$1 $2 $3 $4" = "mcp remove --scope user" ]; then
  if [ -f "$file" ] && grep -q "\"$5\"" "$file"; then printf '{"mcpServers":{}}' > "$file"; echo "Removed MCP server $5 from user config"; exit 0; fi
  echo "No MCP server named \"$5\" in user scope" >&2; exit 1
fi
exit 3
"""#

/// A stand-in Codex: `--version` prints `version.txt` (else 0.162.1);
/// `mcp get cherry --json` prints `get.json` when there is one, `get.err`
/// (exit 1) when there is that, else Codex's "No MCP server named";
/// `mcp add` writes the `get.json` that names its helper.
private func codexStandIn(_ standIns: ConnectStandIns) -> String {
    let directory = standIns.root.path
    return """
    if [ "$1" = --version ]; then cat '\(directory)/version.txt' 2>/dev/null || echo 'codex-cli 0.162.1'; exit 0; fi
    if [ "$1 $2 $4" = "mcp get --json" ]; then
      if [ -f '\(directory)/get.json' ]; then cat '\(directory)/get.json'; exit 0; fi
      if [ -f '\(directory)/get.err' ]; then cat '\(directory)/get.err' >&2; exit 1; fi
      echo "Error: No MCP server named '$3' found." >&2; exit 1
    fi
    if [ "$1 $2" = "mcp add" ]; then
      printf '{"name":"%s","enabled":true,"transport":{"type":"stdio","command":"%s","args":[],"env":null}}' "$3" "$5" > '\(directory)/get.json'
      echo "Added global MCP server '$3'."
      exit 0
    fi
    exit 3
    """
}

@MainActor
private func cliModel(_ harness: MCPHarness, _ standIns: ConnectStandIns, helperPath: String? = connectHelper) -> MCPCLIRegistrationModel {
    let environment = standIns.environment
    let versions = AgentCLIVersions(environment: { [:] })
    return MCPCLIRegistrationModel(
        harness: harness,
        serverName: "cherry",
        helperPath: helperPath,
        environment: { environment },
        locate: pathOnly,
        answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
}

// MARK: - Claude Code's settings file

/// `claude mcp add --scope user` writes `.claude.json` in
/// CLAUDE_CONFIG_DIR, else in the home directory; a legacy `.config.json`
/// in the config directory (CLAUDE_CONFIG_DIR, else ~/.claude) wins; a
/// relative CLAUDE_CONFIG_DIR is refused, as Claude Code refuses it.
@Test func controlToolConnectClaudeSettingsFileFollowsClaudeCodesRules() throws {
    let root = try canonicalTemporaryDirectory("cherry-connect-claude-file")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let configured = root.appendingPathComponent("config", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
    func file(_ environment: [String: String]) -> ClaudeMCPRegistration.SettingsFile {
        ClaudeMCPRegistration.settingsFile(environment: environment, homeDirectory: home)
    }

    #expect(file([:]) == .file(home.appendingPathComponent(".claude.json")))
    #expect(file(["CLAUDE_CONFIG_DIR": ""]) == .file(home.appendingPathComponent(".claude.json")))
    #expect(file(["CLAUDE_CONFIG_DIR": configured.path]) == .file(configured.appendingPathComponent(".claude.json")))
    // The legacy file wins, both ways.
    try "{}".write(to: home.appendingPathComponent(".claude/.config.json"), atomically: true, encoding: .utf8)
    #expect(file([:]) == .file(home.appendingPathComponent(".claude/.config.json")))
    #expect(file(["CLAUDE_CONFIG_DIR": configured.path]) == .file(configured.appendingPathComponent(".claude.json")))
    try "{}".write(to: configured.appendingPathComponent(".config.json"), atomically: true, encoding: .utf8)
    #expect(file(["CLAUDE_CONFIG_DIR": configured.path]) == .file(configured.appendingPathComponent(".config.json")))
    // Relative: refused.
    #expect(file(["CLAUDE_CONFIG_DIR": "claude-config"]) == .unusable("CLAUDE_CONFIG_DIR is not an absolute path"))
    #expect(file(["CLAUDE_CONFIG_DIR": "~/claude"]) == .unusable("CLAUDE_CONFIG_DIR is not an absolute path"))
    // Only the file system is asked, by the test's own `fileExists`.
    var asked: [String] = []
    _ = ClaudeMCPRegistration.settingsFile(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/someone")) {
        asked.append($0)
        return false
    }
    #expect(asked == ["/Users/someone/.claude/.config.json"])
}

/// What the file has under the top-level `mcpServers.<name>`: its type,
/// command and arguments (never its environment); and a project's
/// local-scope entry, by project root.
@Test func controlToolConnectClaudeStatusFixtures() throws {
    let root = try canonicalTemporaryDirectory("cherry-connect-claude-status")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(".claude.json")
    func status(_ json: String?) -> AgentConnection.EntryStatus {
        ClaudeMCPRegistration.status(serverName: "cherry", helperPath: connectHelper, file: file, data: json.map { Data($0.utf8) })
    }
    #expect(status(nil) == .notRegistered)
    #expect(status(#"{"numStartups":3}"#) == .notRegistered)
    #expect(status(#"{"mcpServers":{"other":{"command":"x"}}}"#) == .notRegistered)
    #expect(status(#"{"mcpServers":{"cherry":{"type":"stdio","command":"\#(connectHelper)","args":[],"env":{}}}}"#) == .connected)
    // Its environment is Claude Code's business; an entry without a type is
    // a stdio one.
    #expect(status(#"{"mcpServers":{"cherry":{"command":"\#(connectHelper)","env":{"A":"1"}}}}"#) == .connected)
    #expect(status(#"{"mcpServers":{"cherry":{"type":"stdio","command":"/Gone/CherryMCP","args":[]}}}"#)
        == .otherHelper(path: "/Gone/CherryMCP", runs: false))
    let other = root.appendingPathComponent("Other.app/CherryMCP")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: other, atomically: true, encoding: .utf8)
    #expect(chmod(other.path, 0o755) == 0)
    #expect(status(#"{"mcpServers":{"cherry":{"type":"stdio","command":"\#(other.path)","args":[]}}}"#)
        == .otherHelper(path: other.path, runs: true))
    #expect(status(#"{"mcpServers":{"cherry":{"type":"stdio","command":"\#(connectHelper)","args":["--debug","a b"]}}}"#)
        == .otherArguments(line: "\(connectHelper) --debug 'a b'"))
    #expect(status(#"{"mcpServers":{"cherry":{"type":"http","url":"https://example.com/mcp"}}}"#)
        == .otherArguments(line: "https://example.com/mcp"))
    #expect(status("not json") == .unreadable("\(file.path) is not a JSON object"))
    #expect(status("[1]") == .unreadable("\(file.path) is not a JSON object"))
    // A bare command runs when it is on the PATH given.
    #expect(ClaudeMCPRegistration.status(
        serverName: "cherry", helperPath: connectHelper, file: file,
        data: Data(#"{"mcpServers":{"cherry":{"command":"CherryMCP"}}}"#.utf8),
        searchPath: other.deletingLastPathComponent().path
    ) == .otherHelper(path: "CherryMCP", runs: true))

    // The local scope: the project's own entry, by its root.
    let local = Data(#"""
    {"mcpServers":{},"projects":{
      "/Users/someone/work/app":{"mcpServers":{"cherry":{"type":"stdio","command":"/Old/CherryMCP","args":["-v"]}}},
      "/Users/someone/work/other":{"mcpServers":{"something":{"command":"x"}}}
    }}
    """#.utf8)
    #expect(ClaudeMCPRegistration.localEntry(projectRoots: ["/Users/someone/work/app"], serverName: "cherry", data: local)
        == "/Old/CherryMCP -v")
    #expect(ClaudeMCPRegistration.localEntry(projectRoots: ["/Users/someone/work/app/"], serverName: "cherry", data: local)
        == "/Old/CherryMCP -v")
    #expect(ClaudeMCPRegistration.localEntry(
        projectRoots: ["/Users/someone/work/other", "/Users/someone/work/app"], serverName: "cherry", data: local
    ) == "/Old/CherryMCP -v")
    #expect(ClaudeMCPRegistration.localEntry(projectRoots: ["/Users/someone/work/other"], serverName: "cherry", data: local) == nil)
    #expect(ClaudeMCPRegistration.localEntry(projectRoots: ["/Users/someone/work/app"], serverName: "cherry", data: nil) == nil)

    #expect(ClaudeMCPRegistration.removeArguments(serverName: "cherry") == ["mcp", "remove", "--scope", "user", "cherry"])
    #expect(ClaudeMCPRegistration.reRegisterSteps(serverName: "cherry", helperPath: connectHelper) == [
        ["mcp", "remove", "--scope", "user", "cherry"],
        ["mcp", "add", "--transport", "stdio", "--scope", "user", "cherry", "--", connectHelper],
    ])
}

// MARK: - Claude Code, Codex and Pi stand-ins

/// Claude Code's state is a file read: its refresh runs `claude --version`
/// and nothing else (never `mcp list` or `mcp get`); building a plan runs
/// nothing; Connect runs one `mcp add`; Re-register from Broken runs
/// `mcp remove --scope user`, then that `add`, and ends connected.
@Test @MainActor func controlToolConnectClaudeRunsOnlyWhatAConfirmedPlanSays() async throws {
    let standIns = try ConnectStandIns("claude")
    defer { standIns.remove() }
    try standIns.write("claude", claudeStandIn)
    let model = cliModel(.claude, standIns)
    let version = AgentCLIVersion(major: 2, minor: 1, patch: 299)
    #expect(model.state == .checking)

    await model.refresh()
    #expect(model.state == .notConnected(version))
    #expect(model.executable == standIns.url("claude"))
    #expect(model.settingsFile == standIns.home.appendingPathComponent(".claude.json"))
    #expect(standIns.recordedCalls() == ["[--version]"])
    let row = model.row(connectsAtLaunch: true)
    #expect(row.title == "Claude Code 2.1.299")
    #expect(row.primaryAction == .connect)

    // The button only asks: its plan, and nothing more ran.
    let plan = try #require(model.plan(for: .connect))
    #expect(AgentConnection.effect(of: .connect, plan: plan) == .confirm(plan))
    #expect(plan.displayedCommands == [
        "\(standIns.url("claude").path) mcp add --transport stdio --scope user cherry -- '\(connectHelper)'",
    ])
    #expect(plan.writes == "Claude Code writes \(standIns.home.path)/.claude.json.")
    #expect(plan.replaces == nil)
    let sheet = ConnectAgentsModel(
        registrations: MCPRegistrations(claude: model, codex: cliModel(.codex, standIns), pi: piModel(standIns)),
        connectsAtLaunch: { true }
    )
    sheet.confirm(plan)
    #expect(sheet.request?.plans == [plan])
    #expect(AgentConnection.confirmationTitle([plan]) == "Connect Claude Code to Cherry?")
    #expect(standIns.recordedCalls() == ["[--version]"], "nothing runs until the confirmation's Connect")

    await sheet.perform(try #require(sheet.request).plans)
    #expect(standIns.recordedCalls() == [
        "[--version]",
        "[mcp][add][--transport][stdio][--scope][user][cherry][--][\(connectHelper)]",
    ])
    #expect(model.state == .connected(version))
    #expect(model.message?.hasPrefix("Added stdio MCP server cherry with command: \(connectHelper)") == true)
    #expect(model.lastRunSucceeded)
    #expect(model.row(connectsAtLaunch: true).menuActions == [.connectAgain])
    #expect(model.row(connectsAtLaunch: true).primaryAction == nil)

    // A stale registration: Broken, and Re-register removes, then adds.
    try #"{"mcpServers":{"cherry":{"type":"stdio","command":"/nonexistent/CherryMCP","args":[],"env":{}}}}"#
        .write(to: standIns.home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    await model.refresh()
    #expect(model.state == .otherHelper(version, path: "/nonexistent/CherryMCP", runs: false))
    #expect(model.row(connectsAtLaunch: true).status == "Broken")
    let reRegister = try #require(model.plan(for: .reRegister))
    #expect(reRegister.displayedCommands == [
        "\(standIns.url("claude").path) mcp remove --scope user cherry",
        "\(standIns.url("claude").path) mcp add --transport stdio --scope user cherry -- '\(connectHelper)'",
    ])
    #expect(reRegister.replaces == "It replaces Claude Code's current cherry, which runs /nonexistent/CherryMCP.")
    await model.perform(reRegister)
    #expect(standIns.recordedCalls().suffix(2) == [
        "[mcp][remove][--scope][user][cherry]",
        "[mcp][add][--transport][stdio][--scope][user][cherry][--][\(connectHelper)]",
    ])
    #expect(model.state == .connected(version))
    // The remove's words are shown only when the add fails.
    #expect(model.message?.contains("Removed MCP server") == false)

    // Connect Again over a name Claude Code has: remove first, so add works;
    // a failing add shows the remove's words too.
    try FileManager.default.removeItem(at: standIns.home.appendingPathComponent(".claude.json"))
    try standIns.write("claude", #"""
    if [ "$1" = --version ]; then echo '2.1.299 (Claude Code)'; exit 0; fi
    if [ "$2" = remove ]; then echo 'No MCP server named "cherry" in user scope' >&2; exit 1; fi
    echo 'MCP server cherry already exists in local config' >&2; exit 1
    """#)
    await model.perform(try #require(model.plan(for: .connectAgain)))
    #expect(model.lastRunFailed)
    #expect(model.message == "No MCP server named \"cherry\" in user scope\nMCP server cherry already exists in local config")
    #expect(standIns.recordedCalls().allSatisfy { !$0.hasPrefix("[mcp][list]") && !$0.hasPrefix("[mcp][get]") })
}

/// Codex's state is what `codex mcp get --json` prints, on a Codex that has
/// it: connected, turned off, another helper, other arguments, not
/// connected, or what Codex said (a broken config.toml); an older Codex is
/// "Not checked", and only its version is asked. Connect runs one `mcp
/// add`; nothing runs `mcp list`.
@Test @MainActor func controlToolConnectCodexReadsMCPGetAndNothingElse() async throws {
    let standIns = try ConnectStandIns("codex")
    defer { standIns.remove() }
    try standIns.write("codex", codexStandIn(standIns))
    let get = standIns.root.appendingPathComponent("get.json")
    let error = standIns.root.appendingPathComponent("get.err")
    let model = cliModel(.codex, standIns)
    let version = AgentCLIVersion(major: 0, minor: 162, patch: 1)
    func read(_ json: String?) async throws -> AgentConnection.State {
        if let json { try json.write(to: get, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: get) }
        await model.refresh()
        return model.state
    }
    func entry(_ fields: String, enabled: Bool = true) -> String {
        #"{"name":"cherry","enabled":\#(enabled),"disabled_reason":null,"transport":{"type":"stdio",\#(fields),"env":null,"env_vars":[],"cwd":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}"#
    }

    #expect(try await read(nil) == .notConnected(version))
    #expect(standIns.recordedCalls() == ["[--version]", "[mcp][get][cherry][--json]"])
    #expect(model.settingsFile == standIns.home.appendingPathComponent(".codex/config.toml"))
    #expect(try await read(entry(#""command":"\#(connectHelper)","args":[]"#)) == .connected(version))
    #expect(try await read(entry(#""command":"\#(connectHelper)","args":[]"#, enabled: false)) == .turnedOff(version))
    #expect(model.row(connectsAtLaunch: true).status == "Turned off")
    #expect(model.row(connectsAtLaunch: true).detail == "Codex's settings turn cherry off. Connect replaces it with an enabled one.")
    #expect(try await read(entry(#""command":"/Old/CherryMCP","args":[]"#)) == .otherHelper(version, path: "/Old/CherryMCP", runs: false))
    #expect(try await read(entry(#""command":"\#(connectHelper)","args":["--client-tool-timeout","300"]"#))
        == .otherArguments(version, line: "\(connectHelper) --client-tool-timeout 300"))
    #expect(try await read(#"{"name":"cherry","enabled":true,"transport":{"type":"streamable_http","url":"https://x/mcp"}}"#)
        == .otherArguments(version, line: "https://x/mcp"))
    // A warning Codex printed around the JSON is not the JSON.
    #expect(try await read("WARNING: something\n" + entry(#""command":"\#(connectHelper)","args":[]"#)) == .connected(version))
    // A broken config.toml: what Codex said.
    try? FileManager.default.removeItem(at: get)
    try "Error: failed to load bootstrap configuration\nTOML parse error at line 1, column 5\n".write(to: error, atomically: true, encoding: .utf8)
    #expect(try await read(nil) == .unreadable(version, "Error: failed to load bootstrap configuration TOML parse error at line 1, column 5"))
    #expect(model.row(connectsAtLaunch: true).primaryAction == .checkAgain)
    try FileManager.default.removeItem(at: error)

    // Connect: one `mcp add`, which replaces; then read again.
    #expect(try await read(nil) == .notConnected(version))
    let plan = try #require(model.plan(for: .connect))
    #expect(plan.steps.map(\.arguments) == [["mcp", "add", "cherry", "--", connectHelper]])
    await model.perform(plan)
    #expect(model.state == .connected(version))
    #expect(standIns.recordedCalls().filter { $0.hasPrefix("[mcp][add]") } == ["[mcp][add][cherry][--][\(connectHelper)]"])

    // An older Codex: asked its version only, and still offered Connect.
    try "codex-cli 0.150.0\n".write(to: standIns.root.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    let before = standIns.recordedCalls().count
    await model.refresh(asksAgain: true)
    #expect(model.state == .notChecked(AgentCLIVersion(major: 0, minor: 150, patch: 0), "Cherry can't read Codex 0.150.0's MCP settings."))
    #expect(Array(standIns.recordedCalls().dropFirst(before)) == ["[--version]"])
    #expect(model.row(connectsAtLaunch: true).primaryAction == .connect)
    #expect(standIns.recordedCalls().allSatisfy { !$0.hasPrefix("[mcp][list]") })

    // CODEX_HOME names the file Codex writes.
    #expect(CodexMCPRegistration.settingsFile(environment: ["CODEX_HOME": "/x/codex"], homeDirectory: standIns.home).path
        == "/x/codex/config.toml")
    #expect(CodexMCPRegistration.getArguments(serverName: "cherry") == ["mcp", "get", "cherry", "--json"])
    #expect(CodexMCPRegistration.status(fromGet: .init(status: 1, output: "Error: No MCP server named 'cherry' found.\n"), helperPath: connectHelper)
        == .notRegistered)
    #expect(CodexMCPRegistration.status(fromGet: .init(status: -1, output: "codex did not finish in 10 s"), helperPath: connectHelper)
        == .unreadable("codex did not finish in 10 s"))
    #expect(CodexMCPRegistration.status(fromGet: .init(status: 0, output: "not json"), helperPath: connectHelper)
        == .unreadable("codex mcp get printed “not json”"))
}

@MainActor
private func piModel(_ standIns: ConnectStandIns) -> PiMCPRegistrationModel {
    var environment = standIns.environment
    environment["PI_CODING_AGENT_DIR"] = standIns.root.appendingPathComponent("agent").path
    let fixed = environment
    let versions = AgentCLIVersions(environment: { [:] })
    return PiMCPRegistrationModel(
        serverName: "cherry",
        helperPath: connectHelper,
        environment: { fixed },
        locate: pathOnly,
        answer: { await versions.answer($0, environment: $1, asksAgain: $2) }
    )
}

/// Pi through its model in the sheet: a Pi without MCP (0.62.0) is asked
/// its version only by the sheet's refresh, Connect All leaves it out, and
/// a plan run by hand is refused by the gated register; Claude Code and
/// Codex not found are listed at the end.
@Test @MainActor func controlToolConnectAnOldPiInTheSheetRunsNothingButItsVersion() async throws {
    let standIns = try ConnectStandIns("pi-old")
    defer { standIns.remove() }
    try standIns.write("pi", "if [ \"$1\" = --version ]; then echo 0.62.0; fi\nexit 0")
    let registrations = MCPRegistrations(claude: cliModel(.claude, standIns), codex: cliModel(.codex, standIns), pi: piModel(standIns))
    let sheet = ConnectAgentsModel(registrations: registrations, connectsAtLaunch: { true })
    await sheet.refresh()
    #expect(registrations.claude.state == .notInstalled)
    #expect(registrations.codex.state == .notInstalled)
    #expect(registrations.pi.state == .withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0)))
    let rows = sheet.rows
    #expect(rows.map(\.harness) == [.claude, .codex, .pi])
    #expect(rows.map(\.isInstalled) == [false, false, true])
    #expect(ConnectAgentsSheet.notFoundTitle(rows.filter { !$0.isInstalled }) == "Not found: Claude Code, Codex")
    #expect(rows[2].status == "Update Pi")
    #expect(rows[2].launchLine == "Pi agents Cherry starts: this Pi (0.62.0) is older than 0.99.2: they start without Cherry MCP")

    #expect(sheet.connectAllPlans.isEmpty)
    sheet.confirmConnectAll()
    #expect(sheet.request == nil)
    #expect(standIns.recordedCalls() == ["[--version]"])

    // A plan run without its button: the gate asks the version again and
    // refuses.
    await sheet.perform([try #require(registrations.pi.plan(for: .connect))])
    #expect(registrations.pi.lastRunFailed)
    #expect(registrations.pi.message == "\(standIns.url("pi").path) is Pi 0.62.0, which has no MCP: update Pi to 0.99.2 or later.")
    #expect(standIns.recordedCalls() == ["[--version]", "[--version]"])
}

/// Connect All runs one confirmation of every CLI's plan that mends what is
/// missing, gone or turned off, and nothing that is connected or the
/// user's own (another Cherry's helper that runs, other arguments).
@Test @MainActor func controlToolConnectConnectAllPlansOnlyWhatIsMissing() async throws {
    let standIns = try ConnectStandIns("connect-all")
    defer { standIns.remove() }
    try standIns.write("claude", claudeStandIn)
    try standIns.write("codex", codexStandIn(standIns))
    try standIns.write("pi", """
    if [ "$1" = --version ]; then echo 1.3.0; exit 0; fi
    mkdir -p "$PI_CODING_AGENT_DIR"
    printf '{"mcpServers":{"%s":{"command":"%s","exposure":"%s","description":"%s"}}}' "$3" "$9" "$5" "$7" > "$PI_CODING_AGENT_DIR/mcp.json"
    """)
    let agent = standIns.root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    // Pi's is codemode: tools hidden. Codex's is turned off. Claude Code has none.
    try #"{"mcpServers":{"cherry":{"command":"\#(connectHelper)"}}}"#.write(to: agent.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
    try #"{"name":"cherry","enabled":false,"transport":{"type":"stdio","command":"\#(connectHelper)","args":[]}}"#
        .write(to: standIns.root.appendingPathComponent("get.json"), atomically: true, encoding: .utf8)
    let registrations = MCPRegistrations(claude: cliModel(.claude, standIns), codex: cliModel(.codex, standIns), pi: piModel(standIns))
    let sheet = ConnectAgentsModel(registrations: registrations, connectsAtLaunch: { true })
    await sheet.refresh()
    let plans = sheet.connectAllPlans
    #expect(plans.map(\.harness) == [.claude, .codex, .pi])
    #expect(plans.map(\.action) == [.connect, .connect, .makeDeferred])
    #expect(AgentConnection.confirmationTitle(plans) == "Connect Claude Code, Codex and Pi to Cherry?")
    #expect(AgentConnection.confirmationNotes(plans) == [
        "Claude Code writes \(standIns.home.path)/.claude.json.",
        "Codex writes \(standIns.home.path)/.codex/config.toml. It replaces Codex's current cherry, which is turned off.",
        "Pi writes \(agent.path)/mcp.json. It replaces Pi's current cherry, whose exposure is codemode.",
    ])
    sheet.confirmConnectAll()
    #expect(sheet.request?.plans == plans)
    #expect(!standIns.recordedCalls().contains { $0.contains("[add]") }, "nothing runs until the confirmation's Connect")
    await sheet.perform(plans)
    #expect(registrations.claude.state == .connected(AgentCLIVersion(major: 2, minor: 1, patch: 299)))
    #expect(registrations.codex.state == .connected(AgentCLIVersion(major: 0, minor: 162, patch: 1)))
    #expect(registrations.pi.state == .connected(AgentCLIVersion(major: 1, minor: 3, patch: 0), .deferred))
    // All connected: Connect All has nothing left.
    #expect(sheet.connectAllPlans.isEmpty)
    #expect(standIns.recordedCalls().filter { $0.contains("[add]") }.count == 3)
}

// MARK: - Rows, plans and texts

/// Which rows Connect All takes, by state, for every CLI.
@Test @MainActor func controlToolConnectConnectAllSelectsOnlyTheListedStates() {
    let v = AgentCLIVersion(major: 2, minor: 1, patch: 299)
    func joins(_ state: AgentConnection.State) -> Bool {
        AgentConnection.row(.claude, state: state, serverName: "cherry", connectsAtLaunch: true).joinsConnectAll
    }
    func piJoins(_ state: PiMCPRegistration.State) -> Bool {
        AgentConnection.row(pi: state, serverName: "cherry", connectsAtLaunch: true).joinsConnectAll
    }
    #expect(joins(.notConnected(v)))
    #expect(joins(.turnedOff(v)))
    #expect(joins(.otherHelper(v, path: "/x", runs: false)))
    for state: AgentConnection.State in [
        .checking, .notInstalled, .unknownVersion(path: "/x", output: "?"), .noAnswer(path: "/x"), .connected(v),
        .otherHelper(v, path: "/x", runs: true), .otherArguments(v, line: "/x -v"), .unreadable(v, "why"),
        .notChecked(v, "Cherry can't read Codex 2.1.299's MCP settings."),
    ] {
        #expect(!joins(state), "\(state)")
    }
    let p = AgentCLIVersion(major: 1, minor: 3, patch: 0)
    #expect(piJoins(.notConnected(p)))
    #expect(piJoins(.turnedOff(p)))
    #expect(piJoins(.toolsHidden(p, "codemode")))
    #expect(piJoins(.otherHelper(p, path: "/x", runs: false)))
    for state: PiMCPRegistration.State in [
        .checking, .notInstalled, .withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0)), .connected(p, .deferred),
        .connected(p, .direct), .otherHelper(p, path: "/x", runs: true), .otherArguments(p, line: "/x -v"), .unreadable(p, "why"),
    ] {
        #expect(!piJoins(state), "\(state)")
    }

    // Only joining rows with a registering action make plans.
    let rows = [
        AgentConnection.row(.claude, state: .notConnected(v), serverName: "cherry", connectsAtLaunch: true),
        AgentConnection.row(.codex, state: .otherArguments(v, line: "/x -v"), serverName: "cherry", connectsAtLaunch: true),
        AgentConnection.row(pi: .otherHelper(p, path: "/Gone", runs: false), serverName: "cherry", connectsAtLaunch: true),
    ]
    var asked: [String] = []
    _ = AgentConnection.connectAllPlans(rows) { harness, action in
        asked.append("\(harness.rawValue) \(action.title)")
        return nil
    }
    #expect(asked == ["claude Connect", "pi Re-register"])
}

/// Claude Code's and Codex's rows in each state: status, look, the line
/// under it and the buttons.
@Test @MainActor func controlToolConnectRowsSayWhatEachStateMeans() {
    let v = AgentCLIVersion(major: 2, minor: 1, patch: 299)
    func row(_ state: AgentConnection.State, _ harness: MCPHarness = .claude) -> AgentConnection.Row {
        AgentConnection.row(harness, state: state, serverName: "cherry", connectsAtLaunch: true)
    }
    func look(_ state: AgentConnection.State, _ harness: MCPHarness = .claude) -> String {
        let row = row(state, harness)
        return "\(row.status) \(row.style) \(row.dot) \(row.primaryAction?.title ?? "-") \(row.menuActions.map(\.title))"
    }
    #expect(look(.checking) == "Checking… neutral gray - []")
    #expect(row(.checking).detail == nil)
    #expect(row(.checking).title == "Claude Code")
    #expect(look(.notInstalled) == "Not installed neutral gray Check Again []")
    #expect(row(.notInstalled).detail == MCPCLIRegistration.notFoundMessage(executable: "claude"))
    #expect(!row(.notInstalled).isInstalled)
    #expect(look(.unknownVersion(path: "/x/claude", output: "dev")) == "Unknown warning orange Check Again []")
    #expect(row(.unknownVersion(path: "/x/claude", output: "dev")).detail == "/x/claude --version printed “dev”.")
    #expect(row(.noAnswer(path: "/x/claude")).detail == "/x/claude --version did not answer.")
    #expect(look(.notConnected(v)) == "Not connected neutral gray Connect []")
    #expect(row(.notConnected(v)).detail == "Connect adds Cherry MCP to Claude Code's settings, for sessions you start yourself.")
    #expect(row(.notConnected(v)).title == "Claude Code 2.1.299")
    #expect(look(.connected(v)) == "Connected ok green - [\"Connect Again\"]")
    #expect(row(.connected(v)).detail == "Claude Code runs this Cherry's MCP helper.")
    #expect(look(.turnedOff(v), .codex) == "Turned off warning orange Connect []")
    #expect(look(.otherHelper(v, path: "/Other/CherryMCP", runs: true)) == "Another Cherry warning orange Re-register []")
    #expect(row(.otherHelper(v, path: "/Other/CherryMCP", runs: true)).detail
        == "Claude Code's cherry runs /Other/CherryMCP. Re-register makes it this copy's.")
    #expect(look(.otherHelper(v, path: "/Gone/CherryMCP", runs: false)) == "Broken warning orange Re-register []")
    #expect(row(.otherHelper(v, path: "/Gone/CherryMCP", runs: false)).detail
        == "Claude Code's cherry runs /Gone/CherryMCP, which isn't there any more.")
    #expect(look(.otherArguments(v, line: "/x/CherryMCP --debug"), .codex) == "Differs warning orange Re-register []")
    #expect(row(.otherArguments(v, line: "/x/CherryMCP --debug"), .codex).detail == "Codex's cherry runs /x/CherryMCP --debug.")
    #expect(look(.unreadable(v, "why")) == "Can't read warning orange Check Again []")
    #expect(row(.unreadable(v, "CLAUDE_CONFIG_DIR is not an absolute path")).detail == "CLAUDE_CONFIG_DIR is not an absolute path")
    let old = AgentCLIVersion(major: 0, minor: 150, patch: 0)
    #expect(look(.notChecked(old, "Cherry can't read Codex 0.150.0's MCP settings."), .codex) == "Not checked neutral gray Connect []")

    // Pi's row is its page's (`piRow`), with actions for its buttons.
    let pi = AgentConnection.row(pi: .connected(AgentCLIVersion(major: 1, minor: 3, patch: 0), .direct), serverName: "cherry", connectsAtLaunch: true)
    #expect(pi.title == "Pi 1.3.0")
    #expect(pi.status == "Connected (direct)")
    #expect(pi.primaryAction == .makeDeferred)
    #expect(AgentConnection.row(pi: .connected(AgentCLIVersion(major: 1, minor: 3, patch: 0), .deferred), serverName: "cherry", connectsAtLaunch: true)
        .menuActions == [.connectAgain])
    #expect(AgentConnection.row(pi: .notInstalled, serverName: "cherry", connectsAtLaunch: true).primaryAction == .checkAgain)

    // The command a row shows to copy is its registering button's: none for
    // a Pi without MCP (it would take `pi mcp add …` as prompts), nor for a
    // version Cherry can't read.
    #expect(pi.commandAction == .makeDeferred)
    #expect(AgentConnection.row(pi: .connected(AgentCLIVersion(major: 1, minor: 3, patch: 0), .deferred), serverName: "cherry", connectsAtLaunch: true)
        .commandAction == .connectAgain)
    #expect(AgentConnection.row(pi: .withoutMCP(AgentCLIVersion(major: 0, minor: 62, patch: 0)), serverName: "cherry", connectsAtLaunch: true)
        .commandAction == nil)
    #expect(AgentConnection.row(pi: .unknownVersion(path: "/x/pi", output: "?"), serverName: "cherry", connectsAtLaunch: true)
        .commandAction == nil)
    #expect(row(.unknownVersion(path: "/x/claude", output: "?")).commandAction == nil)
    #expect(row(.notInstalled).commandAction == nil)
    #expect(row(.notConnected(v)).commandAction == .connect)
}

/// What the agents Cherry starts get, per switch and version; the hint
/// after a connect; the confirmation's texts and each button's effect.
@Test func controlToolConnectLaunchLinesHintsAndConfirmations() throws {
    #expect(AgentConnection.launchLine(.claude, version: AgentCLIVersion(major: 2, minor: 1, patch: 299), connectsAtLaunch: true, serverName: "cherry")
        == "Claude Code agents Cherry starts: connected at launch (2.0.0 or later)")
    #expect(AgentConnection.launchLine(.claude, version: nil, connectsAtLaunch: true, serverName: "cherry")
        == "Claude Code agents Cherry starts: connected at launch (2.0.0 or later)")
    #expect(AgentConnection.launchLine(.claude, version: AgentCLIVersion(major: 1, minor: 9, patch: 0), connectsAtLaunch: true, serverName: "cherry")
        == "Claude Code agents Cherry starts: this Claude Code (1.9.0) is older than 2.0.0: they use what is registered")
    #expect(AgentConnection.launchLine(.codex, version: AgentCLIVersion(major: 0, minor: 162, patch: 1), connectsAtLaunch: false, serverName: "cherry")
        == "Codex agents Cherry starts: off in Settings")
    #expect(AgentConnection.launchLine(.codex, version: AgentCLIVersion(major: 0, minor: 150, patch: 0), connectsAtLaunch: true, serverName: "cherry")
        == "Codex agents Cherry starts: this Codex (0.150.0) is older than 0.162.0: they use what is registered")
    #expect(AgentConnection.launchLine(.pi, version: AgentCLIVersion(major: 1, minor: 3, patch: 0), connectsAtLaunch: true, serverName: "cherry")
        == "Pi agents Cherry starts: connected at launch (Pi 0.99.2 or later); a cherry entry in Pi's settings takes precedence")
    #expect(AgentConnection.launchLine(.pi, version: nil, connectsAtLaunch: false, serverName: "cherry") == "Pi agents Cherry starts: off in Settings")

    #expect(AgentConnection.restartHint(.claude) == "Sessions already open read their MCP servers when they start: restart them.")
    #expect(AgentConnection.restartHint(.codex) == AgentConnection.restartHint(.claude))
    #expect(AgentConnection.restartHint(.pi)
        == "Pi sessions already open read their MCP servers when they start: type /reload in them, or restart the tab.")

    let claude = URL(fileURLWithPath: "/Users/someone/.local/bin/claude")
    let helper = "/Applications/Cherry Dev.app/Contents/MacOS/CherryMCP"
    let connect = try #require(AgentConnection.plan(
        .claude, action: .connect, executable: claude, serverName: "cherry", helperPath: helper,
        writes: "Claude Code writes /Users/someone/.claude.json.", replaces: nil
    ))
    // The located path is the first word; the helper always quoted.
    #expect(connect.displayedCommands == [
        "/Users/someone/.local/bin/claude mcp add --transport stdio --scope user cherry -- '\(helper)'",
    ])
    #expect(AgentConnection.confirmationTitle([connect]) == "Connect Claude Code to Cherry?")
    #expect(AgentConnection.confirmationLead == "Cherry will run:")
    #expect(AgentConnection.confirmationNotes([connect]) == ["Claude Code writes /Users/someone/.claude.json."])
    let reRegister = try #require(AgentConnection.plan(
        .claude, action: .reRegister, executable: claude, serverName: "cherry", helperPath: helper,
        writes: "Claude Code writes /Users/someone/.claude.json.",
        replaces: AgentConnection.replaces(.claude, state: .otherHelper(AgentCLIVersion(major: 2, minor: 1, patch: 299), path: "/Old/CherryMCP", runs: true), serverName: "cherry")
    ))
    #expect(reRegister.steps.count == 2)
    #expect(AgentConnection.confirmationTitle([reRegister]) == "Re-register Claude Code's Cherry MCP?")
    #expect(AgentConnection.confirmationNotes([reRegister])
        == ["Claude Code writes /Users/someone/.claude.json. It replaces Claude Code's current cherry, which runs /Old/CherryMCP."])
    let codex = try #require(AgentConnection.plan(
        .codex, action: .reRegister, executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), serverName: "cherry",
        helperPath: helper, writes: "Codex writes /Users/someone/.codex/config.toml.", replaces: nil
    ))
    // Codex replaces a table of the name: one add, whatever the button.
    #expect(codex.displayedCommands == ["/opt/homebrew/bin/codex mcp add cherry -- '\(helper)'"])
    #expect(AgentConnection.confirmationTitle([connect, codex]) == "Connect Claude Code and Codex to Cherry?")
    let pi = try #require(AgentConnection.plan(
        .pi, action: .makeDeferred, executable: URL(fileURLWithPath: "/Users/someone/.bun/bin/pi"), serverName: "cherry",
        helperPath: helper, writes: "Pi writes /Users/someone/.pi/agent/mcp.json.",
        replaces: AgentConnection.replaces(pi: .toolsHidden(AgentCLIVersion(major: 1, minor: 3, patch: 0), "codemode"), serverName: "cherry")
    ))
    #expect(pi.displayedCommands == [
        "/Users/someone/.bun/bin/pi mcp add cherry --exposure deferred --description '\(PiMCPRegistration.serverDescription)' -- '\(helper)'",
    ])
    #expect(AgentConnection.confirmationTitle([pi]) == "Make Pi's Cherry MCP deferred?")
    #expect(AgentConnection.confirmationNotes([pi]) == ["Pi writes /Users/someone/.pi/agent/mcp.json. It replaces Pi's current cherry, whose exposure is codemode."])
    #expect(AgentConnection.plan(
        .pi, action: .checkAgain, executable: claude, serverName: "cherry", helperPath: helper, writes: "", replaces: nil
    ) == nil)
    // A path with a space is quoted as a shell would need it.
    #expect(AgentConnection.displayedCommand(
        .init(executable: URL(fileURLWithPath: "/Users/some one/bin/codex"), arguments: ["mcp", "get", "cherry", "--json"]), helperPath: helper
    ) == "'/Users/some one/bin/codex' mcp get cherry --json")

    // Buttons: Check Again reads again; the others only ask about a plan.
    #expect(AgentConnection.effect(of: .checkAgain, plan: connect) == .checkAgain)
    #expect(AgentConnection.effect(of: .connect, plan: connect) == .confirm(connect))
    #expect(AgentConnection.effect(of: .reRegister, plan: nil) == .unavailable)
    #expect(AgentConnection.Action.allCases.filter(\.registers) == [.connect, .connectAgain, .reRegister, .makeDeferred])
}

// MARK: - Connect This Agent

/// Connect This Agent's lines: this launch (with Cherry MCP, or without it
/// and why, and Restart Tab only when a launch now would get it), this
/// project's settings that win (Pi's .pi/mcp.json, Claude Code's local
/// scope only for a launch without Cherry MCP), and a device's tab.
@Test func controlToolConnectThisAgentLines() throws {
    func lines(
        _ harness: MCPHarness,
        launch: AgentMCPLaunch.Outcome?,
        now: AgentMCPLaunch.Outcome? = nil,
        pi: ConnectThisAgent.PiProjectEntry? = nil,
        claude: String? = nil,
        connectedHere: Bool = false,
        place: ConnectThisAgent.Place = .thisMac
    ) -> ConnectThisAgent.Lines {
        ConnectThisAgent.lines(
            harness: harness, place: place, launchOutcome: launch, outcomeNow: now, piProjectEntry: pi,
            claudeLocalLine: claude, connectedHere: connectedHere, serverName: "cherry"
        )
    }
    let appended = AgentMCPLaunch.Outcome.appended(" '--mcp-config' '{}'")
    let skipped = AgentMCPLaunch.Outcome.skipped("claude's version is not known yet")

    let started = lines(.claude, launch: appended, claude: "/Old/CherryMCP")
    #expect(started.launch
        == "This tab started Claude Code with Cherry MCP, for this session: its own registration is for sessions started elsewhere.")
    #expect(!started.offersRestart)
    #expect(started.project == nil, "the launch-time server wins over a local one")
    #expect(lines(.pi, launch: .appended(" '-e' '/x.ts'")).launch
        == "This tab started Pi with Cherry MCP, for this session; a cherry entry in Pi's settings takes precedence over it.")

    let without = lines(.claude, launch: skipped, now: skipped, claude: "/Old/CherryMCP -v")
    #expect(without.launch == "This tab started Claude Code without Cherry MCP: claude's version is not known yet.")
    #expect(!without.offersRestart)
    #expect(without.project
        == "Claude Code's settings for this project define their own cherry (runs /Old/CherryMCP -v), used instead of the user one.")
    #expect(lines(.claude, launch: skipped, now: appended).offersRestart)
    #expect(lines(.claude, launch: skipped, now: nil).offersRestart == false)
    // After a connect from the sheet, Restart Tab for a launch without it.
    #expect(lines(.codex, launch: skipped, now: skipped, connectedHere: true).offersRestart)
    #expect(!lines(.codex, launch: appended, connectedHere: true).offersRestart)
    #expect(!lines(.pi, launch: .skipped("pi 0.62.0 is older than 0.99.2"), connectedHere: true).offersRestart)
    #expect(lines(.codex, launch: skipped, claude: "/x").project == nil)
    // A context-less tab: no launch line.
    #expect(lines(.claude, launch: nil).launch == nil)

    #expect(lines(.pi, launch: nil, pi: .turnedOff).project == "This project's .pi/mcp.json turns cherry off (when Pi trusts this project).")
    #expect(lines(.pi, launch: nil, pi: .exposure("codemode")).project
        == "This project's .pi/mcp.json sets cherry's exposure to codemode (when Pi trusts this project).")
    #expect(lines(.pi, launch: nil, pi: .ownEntry(line: "/x/CherryMCP")).project
        == "This project's .pi/mcp.json defines its own cherry, which runs /x/CherryMCP (when Pi trusts this project).")

    // A device's tab: when it gets Cherry MCP there, and Set Up.
    let device = lines(.pi, launch: appended, now: appended, place: .device(id: UUID(), name: "Mini"))
    #expect(device.device
        == "Pi on Mini gets Cherry MCP at launch when Mini's session host is this build or newer (Update Session Host…), with an sh-family login shell and Pi 0.99.2 or later.")
    #expect(device.offersSetUp)
    #expect(device.launch == nil && device.project == nil && !device.offersRestart)
    #expect(lines(.claude, launch: nil, place: .device(id: UUID(), name: "Mini")).device
        == "Claude Code on Mini gets Cherry MCP at launch when Mini's session host is this build or newer (Update Session Host…), with an sh-family login shell.")

    // Pi's project files: the working directory's first, then the project
    // root's; an entry of another name is not Cherry's.
    let root = try canonicalTemporaryDirectory("cherry-connect-pi-project")
    defer { try? FileManager.default.removeItem(at: root) }
    let sub = root.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sub.appendingPathComponent(".pi"), withIntermediateDirectories: true)
    func project(_ json: String, in directory: URL) throws {
        try json.write(to: directory.appendingPathComponent(".pi/mcp.json"), atomically: true, encoding: .utf8)
    }
    func entry() -> ConnectThisAgent.PiProjectEntry? {
        ConnectThisAgent.piProjectEntry(serverName: "cherry", directories: [sub.path, root.path])
    }
    try project(#"{"mcpServers":{"other":{"enabled":false}}}"#, in: sub)
    try project(#"{"mcpServers":{"cherry":{"enabled":false}}}"#, in: root)
    #expect(entry() == .turnedOff)
    try project(#"{"mcpServers":{"cherry":{"exposure":"codemode"}}}"#, in: sub)
    #expect(entry() == .exposure("codemode"))
    try project(#"{"mcpServers":{"cherry":{"command":"/x/CherryMCP","args":["-v"],"exposure":"deferred"}}}"#, in: sub)
    #expect(entry() == .ownEntry(line: "/x/CherryMCP -v"))
    try project(#"{"mcpServers":{"cherry":{"toolExposure":{"*":"direct"}}}}"#, in: sub)
    #expect(entry() == .turnedOff, "an entry that changes neither falls through to the root's")
    try project(#"{"mcpServers":{}}"#, in: root)
    #expect(entry() == nil)
    // `-` and `_` are the same name to Pi.
    try project(#"{"mcpServers":{"cherry_dev":{"enabled":false}}}"#, in: root)
    #expect(ConnectThisAgent.piProjectEntry(serverName: "cherry-dev", directories: [root.path]) == .turnedOff)
    #expect(ConnectThisAgent.piProjectEntry(serverName: "cherry", directories: [root.appendingPathComponent("none").path]) == nil)
}

/// A tab whose launch skipped Cherry MCP because its CLI's version was not
/// known yet: once it is, a launch now would get it, so Restart Tab is
/// offered, and the restart (Restart Active Tab's path) starts it with
/// Cherry MCP. The agent is a stand-in claude.
@Test @MainActor func controlToolConnectThisAgentOffersRestartOnceALaunchWouldGetCherryMCP() async throws {
    let standIns = try ConnectStandIns("this-agent")
    defer { standIns.remove() }
    try standIns.write("claude", "if [ \"$1\" = --version ]; then echo '2.1.299 (Claude Code)'; fi\nexit 0")
    let claude = standIns.url("claude")
    let path = standIns.environment["PATH"] ?? ""
    let versions = AgentCLIVersions(environment: { ["PATH": path] })
    var policy = SessionBackendPolicy.native
    policy.agentMCPLaunch = AgentMCPLaunchContext(isEnabled: { true }, versions: versions, helperPath: connectHelper)
    let workspace = TerminalWorkspace(
        projectRoot: standIns.root.path, createInitialSession: false, launchBackend: .hostManaged, backendPolicy: policy
    )
    defer { workspace.closeAllSessions() }
    let tab = workspace.addAgentSession(agent: AgentToolDefinition(name: "Claude", command: claude.path), projectRoot: standIns.root.path)
    #expect(ConnectThisAgent.harness(of: tab) == .claude)
    #expect(tab.lastAgentMCPLaunchOutcome == .skipped("claude's version is not known yet"))
    let registrations = MCPRegistrations(claude: cliModel(.claude, standIns), codex: cliModel(.codex, standIns), pi: piModel(standIns))
    let model = ConnectThisAgentModel(harness: .claude, session: tab, workspace: workspace, place: .thisMac, registrations: registrations)
    #expect(model.lines.launch == "This tab started Claude Code without Cherry MCP: claude's version is not known yet.")
    #expect(!model.lines.offersRestart)

    versions.seed([claude.path: AgentCLIVersion(major: 2, minor: 1, patch: 299)])
    #expect(model.lines.offersRestart)
    model.restartTab()
    guard case .appended? = tab.lastAgentMCPLaunchOutcome else {
        Issue.record("expected the restart to get Cherry MCP, got \(String(describing: tab.lastAgentMCPLaunchOutcome))")
        return
    }
    #expect(model.lines.launch?.hasPrefix("This tab started Claude Code with Cherry MCP") == true)
    #expect(!model.lines.offersRestart)

    // A terminal tab, and a Gemini agent, are not this sheet's.
    #expect(ConnectThisAgent.harness(of: workspace.addSession()) == nil)
    #expect(ConnectThisAgent.harness(of: workspace.addAgentSession(
        agent: AgentToolDefinition(name: "Gemini", command: "/usr/bin/true"), projectRoot: standIns.root.path
    )) == nil)
}

// MARK: - The Omni bar

/// The bar offers Connect Agents to Cherry… always, and Connect This Agent
/// to Cherry… (with the product as its detail) only while the window's
/// selected tab is a Claude Code, Codex or Pi agent.
@Test @MainActor func controlToolConnectOmniBarRows() throws {
    var sources = OmniSources()
    let commands = OmniProviders.commands(sources)
    let connect = try #require(commands.first { $0.id == "command:connectAgents" })
    #expect(connect.title == "Connect Agents to Cherry…")
    #expect(connect.symbol == "link")
    #expect(connect.primary == .menu(.connectAgents))
    #expect(Set(["mcp", "claude", "codex", "pi", "register"]).isSubset(of: Set(connect.keywords)))
    #expect(!commands.contains { $0.id == "command:connectThisAgent" })
    #expect(OmniProviders.everything(sources).contains { $0.id == "command:connectAgents" })

    sources.window.selectedAgent = OmniSelectedAgent(harness: .codex, productName: "Codex")
    let thisAgent = try #require(OmniProviders.commands(sources).first { $0.id == "command:connectThisAgent" })
    #expect(thisAgent.title == "Connect This Agent to Cherry…")
    #expect(thisAgent.detail == "Codex")
    #expect(thisAgent.primary == .menu(.connectThisAgent))
}

/// The window's context names the selected tab's agent by its tool
/// (`agentToolKey`): a stand-in Claude agent, and nothing for a terminal.
@Test @MainActor func controlToolConnectOmniBarContextNamesTheSelectedAgent() async throws {
    let root = try canonicalTemporaryDirectory("cherry-connect-omni")
    let repository = RepositoryWorkspace(projectRoot: root.path)
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false, launchBackend: .hostManaged)
    defer {
        repository.closeAllSessions(intent: .windowClosed)
        workspace.closeAllSessions(intent: .windowClosed)
        try? FileManager.default.removeItem(at: root)
    }
    let settings = AgentSettings(defaults: privateDefaults("ControlToolConnectOmni"))
    let window = OmniBarWindow(projectRoot: root.path, repository: repository, workspace: workspace, chromeState: ProjectWindowChromeState())

    let agent = workspace.addAgentSession(agent: AgentToolDefinition(name: "Claude", command: "/bin/cat"), projectRoot: root.path)
    #expect(workspace.selectedSession?.id == agent.id)
    #expect(OmniBarGathering.context(for: window, settings: settings).selectedAgent
        == OmniSelectedAgent(harness: .claude, productName: "Claude Code"))

    let terminal = workspace.addSession()
    #expect(workspace.selectedSession?.id == terminal.id)
    #expect(OmniBarGathering.context(for: window, settings: settings).selectedAgent == nil)
}
