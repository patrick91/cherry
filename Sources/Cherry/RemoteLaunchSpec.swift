import CherryControl
import Foundation

/// What Create starts for a tab of another Mac's host (a device,
/// docs/specs/remote-devices.md), in place of `HostedLaunchSpec.prepare`,
/// which describes This Mac: its shell, its Ghostty resources and zsh
/// bootstrap, its PATH and HOME, its control socket. None of that exists on
/// the other Mac, so none of it is sent:
///
/// - A terminal's `command` is empty: the host runs the account's own login
///   shell (`$SHELL -l`, from the other Mac's passwd entry).
/// - A command or an agent runs `[remoteShell, "-l", "-c", line]`, so its
///   line sees the other Mac's login PATH.
/// - `env` is only what describes the terminal and the tab: `TERM`
///   (`xterm-256color`: the other Mac may have no xterm-ghostty terminfo),
///   `COLORTERM`, the tab's identity (`CHERRY_PROCESS_ID`,
///   `CHERRY_AGENT_ID`, `CHERRY_PROJECT_ROOT` as the path there,
///   `INSIDE_CHERRY`, `CHERRY_TERM_PROGRAM`, `TERM_PROGRAM`), the command's
///   own variables (cherry.toml), and the locale (`LANG`, `LC_*`). The
///   host adds its own (`CHERRY_SESSION_ID`, `PWD`, `SSH_AUTH_SOCK`, and
///   HOME, USER, SHELL, PATH from its account).
/// - `cwd` is the path on the other Mac, unchecked here.
enum RemoteLaunchSpec {
    static let term = "xterm-256color"
    /// macOS's default login shell, for a device whose shell is not known.
    static let defaultRemoteShell = "/bin/zsh"

    /// Variables that name this Mac's files, processes or account: never
    /// sent to another Mac, whatever the tab's environment says.
    static let localOnlyKeys: Set<String> = CherryTabEnvironment.keys.union([
        CherryControl.socketEnvironmentKey,
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "PWD", "OLDPWD",
        "TERM", "TERMINFO", "TERMINFO_DIRS", "ZDOTDIR", "XDG_DATA_DIRS", "MANPATH",
        "TERM_PROGRAM_VERSION", "__CF_USER_TEXT_ENCODING"
    ])

    static func make(
        for configuration: ShellProcessController.Configuration,
        remoteShell: String = defaultRemoteShell,
        localeEnvironment: [String: String]
    ) -> HostedLaunchSpec {
        var environment: [String: String] = [:]
        for (key, value) in localeEnvironment where isLocaleKey(key) {
            environment[key] = value
        }
        for (key, value) in configuration.environment where !isLocalOnly(key) {
            environment[key] = value
        }
        environment["TERM"] = term
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Cherry"
        environment["CHERRY_TERM_PROGRAM"] = "Cherry"
        environment["INSIDE_CHERRY"] = "1"
        if let projectRoot = configuration.projectRoot?.nilIfEmpty {
            environment[CherryControl.projectRootEnvironmentKey] = ProjectLocation.launchPath(forKey: projectRoot)
        }
        if let processID = configuration.processID?.nilIfEmpty {
            environment[CherryControl.processIDEnvironmentKey] = processID
        }
        if let agentID = configuration.agentID?.nilIfEmpty {
            environment[CherryControl.agentIDEnvironmentKey] = agentID
        }
        let argv: [String] = if let line = configuration.startupCommand?.nilIfEmpty {
            [remoteShell.nilIfEmpty ?? defaultRemoteShell, "-l", "-c", line]
        } else {
            []
        }
        return HostedLaunchSpec(
            argv: argv,
            environment: environment.filter { HostedLaunchSpec.isValidEnvironmentVariable(name: $0.key, value: $0.value) },
            workingDirectory: configuration.workingDirectory
        )
    }

    /// A hosting's launch spec builder for another Mac: the login
    /// environment (this Mac's) only lends its locale.
    static func builder(remoteShell: String) -> PersistentHostSessions.LaunchSpecBuilder {
        { configuration, loginEnvironment in
            make(
                for: configuration,
                remoteShell: remoteShell,
                localeEnvironment: (loginEnvironment ?? [:]).merging(
                    ProcessInfo.processInfo.environment.filter { isLocaleKey($0.key) }
                ) { login, _ in login }
            )
        }
    }

    static func isLocaleKey(_ key: String) -> Bool {
        key == "LANG" || key.hasPrefix("LC_")
    }

    private static func isLocalOnly(_ key: String) -> Bool {
        localOnlyKeys.contains(key) || key.hasPrefix("GHOSTTY_") || key.hasPrefix("XPC_") || key.hasPrefix("DYLD_")
    }
}
