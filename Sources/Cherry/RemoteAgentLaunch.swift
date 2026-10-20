import CherryControl
import Foundation

/// The `cherry` CLI's flags on the command line of the agents Cherry starts
/// on another Mac (a device, docs/specs/remote-devices.md), as
/// `AgentLaunch` gives This Mac's agents theirs. The install's `cherry` is
/// first on the line's PATH (`CHERRY_LOGIN_PATH`) and reaches this Mac's
/// Cherry through the forwarded socket with the tab's token, so the agent
/// is only told about it: there is no skill on that Mac, so the line says
/// to run `cherry skill show` (`AgentCLILaunch.instructionLine`).
///
/// - Claude Code: `--append-system-prompt <line>` and `--settings` letting
///   its sandbox reach the forwarded socket.
/// - Pi: `--append-system-prompt <line>`.
/// - Codex: `-c developer_instructions=<line>`, only while its
///   `config.toml` there sets no instructions of its own (the line checks).
///
/// Cherry keeps no device's CLI versions, so an agent's line asks its CLI
/// there, each time it starts, and only a CLI at least the minimum
/// (`AgentLaunch.CLI.minimumVersion`) gets the flags:
///
///     if [ -x '<cli>' ] && cherry_v=$('claude' --version 2>/dev/null </dev/null) && printf '%s\n' "$cherry_v" | /usr/bin/awk '…'; then exec <line> <flags>; else exec <line>; fi
///
/// An install without its `cherry`, an older CLI, or one
/// whose version cannot be read, runs the line as it always did, and a
/// missing CLI still exits 127 (`remoteProgramNotFoundMessage`). Both
/// branches `exec`, so the session's program is the agent itself, as with a
/// plain `zsh -l -c 'claude'`: its ports scan (`remoteProgramProcessID`),
/// its signals and foreground job. Only for login shells whose syntax this
/// is (sh-family: fish, csh and tcsh run today's line), and only while the
/// app's device store connects agents
/// (`RemoteLaunchSpec.Device.connectsAgentsAtLaunch`, Settings › Agents ›
/// Connect agents Cherry starts; a test's store never does).
enum RemoteAgentLaunch {
    /// What a device agent's launch runs.
    enum Outcome: Equatable {
        /// The line, gated on its CLI's version, and the flags it adds
        /// (`AgentLaunch.shellSuffix`).
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
        environment: [String: String]
    ) -> Outcome {
        guard device.connectsAgentsAtLaunch else { return .skipped("Connect agents Cherry starts is off") }
        guard let mcp = device.mcp, let cliPath = mcp.cliPath?.nilIfEmpty else {
            return .skipped("the Mac's session host has no cherry command")
        }
        // Without the forwarded socket `cherry` there would look for the
        // Cherry of that Mac, not this one.
        guard environment[CherryControl.socketEnvironmentKey] == mcp.socketPath else {
            return .skipped("the tab has no forwarded control socket")
        }
        guard RemoteLaunchSpec.isShFamily(shell) else {
            return .skipped("its login shell \(shell) is not one the version check is written for")
        }
        let detection = AgentLaunch.detection(commandLine: line)
        guard case .cli(let cli, let executableWord) = detection else {
            return .skipped(AgentLaunch.skipReason(detection) ?? "not a plain claude, codex or pi command")
        }
        let words = Array((AgentLaunch.plainWords(line) ?? []).dropFirst())
        guard let arguments = AgentCLILaunch.deviceArguments(
            for: cli, words: words, socketPath: mcp.socketPath,
            processID: environment[CherryControl.processIDEnvironmentKey]
        ), !arguments.isEmpty else {
            return .skipped("nothing to add: the command sets its own instructions")
        }
        let suffix = AgentLaunch.shellSuffix(arguments)
        var checks = ["[ -x \(ShellQuoting.singleQuoted(cliPath)) ]"]
        if cli == .codex { checks.append(codexSetsNoInstructions) }
        return .gated(
            gatedLine(line: line, executableWord: executableWord, cli: cli, checks: checks, suffix: suffix),
            suffix: suffix
        )
    }

    /// A test that `config.toml` (in `CODEX_HOME`, else `~/.codex`) sets
    /// neither `developer_instructions` nor `model_instructions_file`, as
    /// `CodexLaunchFacts.setsDeveloperInstructions` reads This Mac's.
    static let codexSetsNoInstructions =
        "! /usr/bin/grep -qsE '^[[:space:]]*(developer_instructions|model_instructions_file)[[:space:]]*=' \"${CODEX_HOME:-$HOME/.codex}/config.toml\""

    /// `line` with `suffix` (`AgentLaunch.shellSuffix`, its last words)
    /// when every one of `checks` (shell tests: the install's `cherry`,
    /// Codex's config) holds and `executableWord --version`
    /// prints a version of `cli` at least its minimum, else `line` alone;
    /// both `exec`. `line` is a plain command (`AgentLaunch.detect`), so
    /// `exec` runs the same command.
    static func gatedLine(line: String, executableWord: String, cli: AgentLaunch.CLI, checks: [String], suffix: String) -> String {
        let check = ShellQuoting.singleQuoted(versionCheck(minimum: cli.minimumVersion))
        return "if \(checks.joined(separator: " && "))"
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
}
