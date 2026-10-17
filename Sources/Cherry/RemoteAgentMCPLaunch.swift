import CherryControl
import Foundation

/// Cherry MCP on the command line of the agents Cherry starts on another
/// Mac (a device, docs/specs/remote-devices.md), as `AgentMCPLaunch` gives
/// This Mac's agents theirs. Cherry keeps no device's CLI versions, so an
/// agent's line asks its CLI there, each time it starts, and only a CLI at
/// least the minimum (`AgentMCPLaunch.CLI.minimumVersion`) gets the flags:
///
///     if [ -x '<helper>' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && printf '%s\n' "$cherry_v" | /usr/bin/awk '…'; then exec <line> <flags>; else exec <line>; fi
///
/// A Pi's line also checks that the install has Cherry's Pi extension
/// (`[ -r '<build>/cherry-pi-mcp.ts' ]`, after the helper's check): one
/// made before Cherry had it has none. An install without its CherryMCP
/// (or a Pi's extension), an older CLI, or one whose version cannot be
/// read, runs the line as it always did, and a missing CLI still exits 127
/// (`remoteProgramNotFoundMessage`). Both branches `exec`, so the session's
/// program is the agent itself, as with a plain `zsh -l -c 'claude'`: its
/// ports scan (`remoteProgramProcessID`), its signals and foreground job.
///
/// The flags name the device's own CherryMCP (`RemoteMCPLaunch.helperPath`)
/// or Pi extension (`piExtensionPath`) and the identity's server name,
/// never anything of This Mac's. The token never goes on the line: Claude
/// Code and Pi pass their environment to stdio servers, and Codex is given
/// only the names of the variables to pass on (`env_vars`). Only for login shells whose syntax this is (sh-family:
/// fish, csh and tcsh run today's line), and only while the app's device
/// store connects agents (`RemoteLaunchSpec.Device.connectsAgentsAtLaunch`,
/// Settings › Agents & MCP › Connect agents Cherry starts; a test's store
/// never does).
enum RemoteAgentMCPLaunch {
    /// What a device agent's launch runs.
    enum Outcome: Equatable {
        /// The line, gated on its CLI's version, and the flags it adds
        /// (`AgentMCPLaunch.shellSuffix`).
        case gated(String, suffix: String)
        /// The line as it is, and why.
        case skipped(String)
    }

    /// The shell variable the line keeps the CLI's version in.
    static let versionVariable = "cherry_v"

    /// What an agent's `line` runs under the device's login `shell`, with
    /// `environment` the spec's (its Cherry variables already set):
    /// `gatedLine` when every condition holds, else why not.
    static func outcome(
        line: String,
        shell: String,
        device: RemoteLaunchSpec.Device,
        environment: [String: String],
        serverName: String
    ) -> Outcome {
        guard device.connectsAgentsAtLaunch else { return .skipped("Connect agents Cherry starts is off") }
        guard let mcp = device.mcp, let helperPath = mcp.helperPath?.nilIfEmpty else {
            return .skipped("the Mac's session host has no CherryMCP")
        }
        // Without the forwarded socket CherryMCP there would look for the
        // Cherry of that Mac, not this one.
        guard environment[CherryControl.socketEnvironmentKey] == mcp.socketPath else {
            return .skipped("the tab has no forwarded control socket")
        }
        guard RemoteLaunchSpec.isShFamily(shell) else {
            return .skipped("its login shell \(shell) is not one the version check is written for")
        }
        let piExtensionPath = mcp.piExtensionPath?.nilIfEmpty
        if case .cli(.pi, _) = AgentMCPLaunch.detection(commandLine: line), piExtensionPath == nil {
            return .skipped("the Mac's session host has no Pi extension")
        }
        switch AgentMCPLaunch.plan(
            commandLine: line, serverName: serverName, helperPath: helperPath, environmentKeys: environmentKeys(in: environment),
            piExtensionPath: piExtensionPath
        ) {
        case .skipped(let reason):
            return .skipped(reason)
        case .flags(let cli, let executableWord, let arguments):
            let suffix = AgentMCPLaunch.shellSuffix(arguments)
            var requiredFiles = [(test: "-x", path: helperPath)]
            if cli == .pi, let piExtensionPath { requiredFiles.append((test: "-r", path: piExtensionPath)) }
            return .gated(
                gatedLine(line: line, executableWord: executableWord, cli: cli, requiredFiles: requiredFiles, suffix: suffix),
                suffix: suffix
            )
        }
    }

    /// `line` with `suffix` (`AgentMCPLaunch.shellSuffix`, its last words)
    /// when the install has the files the suffix needs (`requiredFiles`,
    /// each a `test` operator and a path: `-x` its CherryMCP, and `-r` a
    /// Pi's extension) and `executableWord --version` prints a version of
    /// `cli` at least its minimum, else `line` alone; both `exec`. Without
    /// them the line stays today's, so a registration made by Set Up Cherry
    /// MCP, whose launcher finds another CherryMCP, is not shadowed by a
    /// server that cannot start. `line` is a plain command
    /// (`AgentMCPLaunch.detect`), so `exec` runs the same command.
    static func gatedLine(
        line: String, executableWord: String, cli: AgentMCPLaunch.CLI, requiredFiles: [(test: String, path: String)], suffix: String
    ) -> String {
        let check = ShellQuoting.singleQuoted(versionCheck(minimum: cli.minimumVersion))
        let files = requiredFiles.map { "[ \($0.test) \(ShellQuoting.singleQuoted($0.path)) ]" }.joined(separator: " && ")
        return "if \(files)"
            + " && \(versionVariable)=$(\(quotedWord(executableWord)) --version 2>/dev/null </dev/null)"
            + " && printf '%s\\n' \"$\(versionVariable)\" | /usr/bin/awk \(check);"
            + " then exec \(line)\(suffix); else exec \(line); fi"
    }

    /// An awk program that exits 0 when the first `<major>.<minor>.<patch>`
    /// of its input is at least `minimum`, else 1 (none at all too): what
    /// `AgentCLIVersion(versionOutput:)` reads, compared as it compares.
    static func versionCheck(minimum: AgentCLIVersion) -> String {
        let (major, minor, patch) = (minimum.major, minimum.minor, minimum.patch)
        return "BEGIN { s = 1 } !f && match($0, /[0-9]+\\.[0-9]+\\.[0-9]+/) {"
            + " f = 1; split(substr($0, RSTART, RLENGTH), v, \".\"); a = v[1] + 0; b = v[2] + 0; c = v[3] + 0;"
            + " s = (a > \(major) || (a == \(major) && (b > \(minor) || (b == \(minor) && c >= \(patch))))) ? 0 : 1"
            + " } END { exit s }"
    }

    /// The executable word as the line's shell reads it back: single-quoted,
    /// with a leading `~/` left unquoted so it expands as the line's own
    /// word does.
    static func quotedWord(_ word: String) -> String {
        if word.hasPrefix("~/") { return "~/" + ShellQuoting.singleQuoted(String(word.dropFirst(2))) }
        return ShellQuoting.singleQuoted(word)
    }

    /// The Cherry variables Codex may pass on to CherryMCP (`env_vars`), in
    /// this order: the tab's and agent's ids, the project root, and Cherry
    /// MCP's own (`RemoteMCPLaunch.environment`: the forwarded socket, This
    /// Mac's name, the token, the helper, the command-line tool).
    static let environmentKeyOrder = [
        CherryControl.processIDEnvironmentKey,
        CherryControl.agentIDEnvironmentKey,
        CherryControl.projectRootEnvironmentKey,
        CherryControl.socketEnvironmentKey,
        CherryControl.controlMachineEnvironmentKey,
        CherryControl.mcpTokenEnvironmentKey,
        CherryControl.mcpHelperEnvironmentKey,
        CherryControl.cliEnvironmentKey,
    ]

    /// Those of them `environment` sets. Taken from the environment the
    /// spec already holds, never from a second
    /// `RemoteMCPLaunch.environment(processID:)`: each call makes the tab a
    /// new token generation, and the token already in the spec would stop
    /// working.
    static func environmentKeys(in environment: [String: String]) -> [String] {
        environmentKeyOrder.filter { key in
            environment[key].map { HostedLaunchSpec.isValidEnvironmentVariable(name: key, value: $0) } ?? false
        }
    }
}
