import Foundation

// A device's login PATH (docs/specs/remote-devices.md, "Login PATH on
// devices"). A command or an agent of another Mac runs as
// `[shell, "-l", "-c", line]` (`RemoteLaunchSpec`): a login shell that is not
// interactive, so it never reads ~/.zshrc (or ~/.bashrc, fish's interactive
// config), where many tools put themselves on PATH (bun's ~/.bun/bin, Claude
// Code's ~/.local/bin, nvm, pyenv). This Mac's launches get the variables of
// one captured run of the user's interactive login shell
// (`HostedSessionLoginEnvironment`); a device's are captured the same way,
// there, over its SSH master, and kept in its record.

/// What Cherry read of a device's interactive login-shell environment: only
/// the variables a command or agent there is given (`isSent`), never the rest
/// of what that shell exports (tokens, keys) nor anything of This Mac's.
struct RemoteLoginEnvironment: Codable, Equatable, Sendable {
    /// The shell that was run there (its path).
    var shell: String
    /// When it was read (to the second, as devices.json keeps dates).
    var capturedAt: Date
    var environment: [String: String]

    init(shell: String, capturedAt: Date, environment: [String: String]) {
        self.shell = shell
        self.capturedAt = Date(timeIntervalSince1970: capturedAt.timeIntervalSince1970.rounded(.down))
        self.environment = Self.filtered(environment)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shell = try container.decode(String.self, forKey: .shell)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        // Checked again when read back: devices.json may have been edited.
        environment = Self.filtered(try container.decode([String: String].self, forKey: .environment))
    }

    /// The variables a device's commands and agents get from the capture:
    /// those This Mac keeps of its own (`LoginEnvironmentCache.isPersisted`)
    /// that describe where programs are and how they run there: `PATH`,
    /// `MANPATH`, `TZ` and the `XDG_*` directories. Never the account's own
    /// (`HOME`, `USER`, `SHELL`, `TMPDIR`: the host sets them), its agent
    /// socket (`SSH_AUTH_SOCK` stays the host's agent link), an askpass or
    /// display, the terminfo (the tab's own), nor the locale (This Mac's, as
    /// for every device tab).
    static func isSent(_ key: String) -> Bool {
        guard LoginEnvironmentCache.isPersisted(key), !key.hasPrefix("LC_") else { return false }
        return !notSent.contains(key)
    }

    private static let notSent: Set<String> = [
        "LANG", "LANGUAGE", "SSH_AUTH_SOCK", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY",
        "SHELL", "HOME", "USER", "LOGNAME", "TMPDIR", "TERMINFO", "TERMINFO_DIRS"
    ]

    /// Each value is cut off at this many bytes (dropped beyond it), and
    /// the whole at this many, far inside what a Create may carry.
    static let maxValueBytes = 32 * 1_024
    static let maxTotalBytes = 64 * 1_024

    /// `environment` without what is not sent, nor values too long or not
    /// valid for a Create; PATH first within the total.
    static func filtered(_ environment: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        var total = 0
        let keys = environment.keys.filter(isSent).sorted { lhs, rhs in
            (lhs == "PATH" ? 0 : 1, lhs) < (rhs == "PATH" ? 0 : 1, rhs)
        }
        for key in keys {
            guard let value = environment[key], value.utf8.count <= maxValueBytes,
                  HostedLaunchSpec.isValidEnvironmentVariable(name: key, value: value)
            else { continue }
            let size = key.utf8.count + value.utf8.count
            guard total + size <= maxTotalBytes else { continue }
            total += size
            kept[key] = value
        }
        return kept
    }
}

/// Reads a device's login-shell environment: one `sh -s` script over its
/// ssh (`RemoteDeviceShell`: the master's ControlPath while it is up) runs
/// its login shell as This Mac's capture runs it (`$SHELL -l -i -c`, csh and
/// tcsh `-l` with the command on standard input), printing `env -0` between
/// two markers so anything its startup files print is skipped. Its standard
/// input is closed (/dev/null): nothing there can prompt. A shell that does
/// not finish within `shellTimeout` seconds is killed there. It starts and
/// asks no session host.
enum RemoteLoginEnvironmentCapture {
    static let beginMarker = "CHERRY-LOGIN-ENV 1"
    static let endMarker = "CHERRY-LOGIN-ENV-END"
    static let shellKey = "cherry-login-env-shell"
    static let statusKey = "cherry-login-env-status"
    /// How long the login shell may take there before it is killed.
    static let shellTimeout = 10
    /// How long the whole capture may take here (the login, the shell and
    /// the answer).
    static let timeout: TimeInterval = 25

    enum Outcome: Equatable, Sendable {
        case captured(RemoteLoginEnvironment)
        /// Why not, as a tab's message continues it ("Cherry couldn't read
        /// its shell's PATH (<reason>)").
        case failed(String)
    }

    /// The POSIX script run there. `loginShell`: the device's (its record's
    /// `shell`); else, or when it is not there, `$SHELL` there.
    static func script(loginShell: String?, marker: String, shellTimeout: Int = shellTimeout) -> String {
        let command = HostedSessionLoginEnvironment.command(marker: marker)
        var lines: [String] = []
        if let loginShell = loginShell?.nilIfEmpty, loginShell.hasPrefix("/") {
            lines += [
                "s=\(RemoteDeviceProbe.singleQuoted(loginShell))",
                "[ -x \"$s\" ] || s=",
            ]
        } else {
            lines.append("s=")
        }
        lines += [
            "[ -n \"$s\" ] || s=${SHELL:-/bin/zsh}",
            "printf '%s\\n' '\(beginMarker)'",
            "printf '\(shellKey)=%s\\n' \"$s\"",
            "c=\(RemoteDeviceProbe.singleQuoted(command))",
            // In the background, so the watchdog below can end it. Its
            // standard error is dropped (prompts, job control warnings).
            "case \"${s##*/}\" in",
            "  csh|tcsh) printf '%s\\n' \"$c\" | \"$s\" -l 2>/dev/null & ;;",
            "  *) \"$s\" -l -i -c \"$c\" </dev/null 2>/dev/null & ;;",
            "esac",
            "p=$!",
            "( sleep \(shellTimeout); kill -KILL \"$p\" 2>/dev/null ) </dev/null >/dev/null 2>&1 &",
            "w=$!",
            "wait \"$p\"",
            "r=$?",
            "kill \"$w\" 2>/dev/null",
            "printf '\\n\(statusKey)=%s\\n' \"$r\"",
            "printf '%s\\n' '\(endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs the capture on `destination`.
    static func run(
        on destination: String,
        loginShell: String?,
        shell: RemoteDeviceShell,
        shellTimeout: Int = shellTimeout
    ) async -> Outcome {
        let marker = "__CHERRY_LOGIN_ENVIRONMENT_\(UUID().uuidString)__"
        var shell = shell
        shell.timeout = min(shell.timeout, timeout)
        let script = script(loginShell: loginShell, marker: marker, shellTimeout: shellTimeout)
        let runner = shell
        let output = await RemoteDeviceShell.onOwnThread {
            runner.runSynchronously(script, on: destination)
        }
        return parse(output, marker: marker, now: Date(), shellTimeout: shellTimeout)
    }

    /// What the script printed (and how ssh ended). Whatever the shell's
    /// startup files print around the markers is ignored; so is a session
    /// that ssh had to end (a program they started that kept the output
    /// open) once the environment was printed.
    static func parse(
        _ output: RemoteDeviceShell.DataOutput,
        marker: String,
        now: Date = Date(),
        shellTimeout: Int = shellTimeout
    ) -> Outcome {
        let data = output.standardOutput
        guard let begin = data.range(of: Data((beginMarker + "\n").utf8)) else {
            if output.status == 255 || output.timedOut {
                return .failed(RemoteDeviceSSHFailure.classify(output.standardError, timedOut: output.timedOut).message)
            }
            let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? "the script did not run there (exit \(output.status))" : detail)
        }
        let rest = Data(data[begin.upperBound...])
        let lines = String(decoding: rest, as: UTF8.self).components(separatedBy: "\n")
        let shell = lines.first { $0.hasPrefix(shellKey + "=") }
            .map { String($0.dropFirst(shellKey.count + 1)) }?.nilIfEmpty ?? "the login shell"
        let status = lines.last { $0.hasPrefix(statusKey + "=") }.map { String($0.dropFirst(statusKey.count + 1)) }
        if let environment = HostedSessionLoginEnvironment.parse(rest, marker: marker) {
            let sent = RemoteLoginEnvironment.filtered(environment)
            guard sent["PATH"]?.nilIfEmpty != nil else { return .failed("\(shell) set no PATH") }
            return .captured(RemoteLoginEnvironment(shell: shell, capturedAt: now, environment: sent))
        }
        switch status {
        case "137"?:
            return .failed("\(shell) did not finish within \(shellTimeout) seconds")
        case let status?:
            return .failed("\(shell) printed no environment (exit \(status))")
        case nil:
            return .failed(output.timedOut ? "\(shell) did not answer in time" : "\(shell) printed no environment")
        }
    }
}
