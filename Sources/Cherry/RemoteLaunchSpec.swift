import CherryControl
import Foundation

/// What Create starts for a tab of another Mac's host (a device,
/// docs/specs/remote-devices.md), in place of `HostedLaunchSpec.prepare`,
/// which describes This Mac: its shell, its staged Ghostty resources and zsh
/// bootstrap, its PATH and HOME, its control socket. None of that exists on
/// the other Mac, so none of it is sent:
///
/// - A terminal's `command` is empty: the host runs the account's own login
///   shell (`$SHELL -l`, from the other Mac's passwd entry). When the device
///   has this Cherry's Ghostty resources (phase 3: the installer puts
///   `Ghostty/` and `terminfo/` next to cherry-host) and its login shell is
///   known, the terminal runs that shell the way `HostedLaunchSpec` runs
///   This Mac's: `/bin/bash --noprofile --norc -c 'exec -l <shell…>'` with
///   Ghostty's zsh, bash or fish integration (OSC 7 directory, titles,
///   prompt marks).
/// - A command or an agent runs `[remoteShell, "-l", "-c", line]`, so its
///   line sees the other Mac's login PATH.
/// - `env` is what describes the terminal and the tab: `TERM`
///   (`xterm-ghostty` with the device's `TERMINFO` and
///   `GHOSTTY_RESOURCES_DIR` when it has the resources, else
///   `xterm-256color`), `COLORTERM`, the tab's identity (`CHERRY_PROCESS_ID`,
///   `CHERRY_AGENT_ID`, `CHERRY_PROJECT_ROOT` as the path there,
///   `INSIDE_CHERRY`, `CHERRY_TERM_PROGRAM`, `TERM_PROGRAM`), Cherry MCP's
///   (`CHERRY_CONTROL_SOCKET` as the socket forwarded there,
///   `CHERRY_MCP_TOKEN`, `CHERRY_MCP_HELPER`, `CHERRY_CONTROL_MACHINE`;
///   phase 4b), the shell
///   integration's variables (paths on the device), the command's own
///   variables (cherry.toml), the locale (`LANG`, `LC_*`), and
///   `SSH_CONNECTION`/`SSH_CLIENT` (`sshEnvironment`). The host adds its own
///   (`CHERRY_SESSION_ID`, `PWD`, `SSH_AUTH_SOCK`, HOME, USER, SHELL, PATH
///   from its account, and `SSH_TTY` naming the session's terminal, which a
///   holder sets whenever `SSH_CONNECTION` is set).
/// - `cwd` is the path on the other Mac, unchecked here.
enum RemoteLaunchSpec {
    static let term = "xterm-256color"
    /// macOS's default login shell, for a device whose shell is not known.
    static let defaultRemoteShell = "/bin/zsh"

    /// This Cherry's Ghostty resources installed on a device, next to its
    /// cherry-host (`<home>/Library/Application Support/cherry-host/bin/<build>/`).
    struct Resources: Equatable, Sendable {
        /// The build directory there (absolute).
        let root: String

        /// GHOSTTY_RESOURCES_DIR there: holds `shell-integration/`.
        var resourcesDirectory: String { "\(root)/\(GhosttyResourceStaging.resourcesName)" }
        /// TERMINFO there: describes `xterm-ghostty`.
        var terminfoDirectory: String { "\(root)/\(GhosttyResourceStaging.terminfoName)" }

        /// The resources of the install a device's `remoteHostPath` names,
        /// under its home.
        static func of(remoteHostPath: String?, homeDirectory: String?) -> Resources? {
            guard let home = homeDirectory?.nilIfEmpty, home.hasPrefix("/"),
                  let directory = RemoteHostInstall.directoryName(ofRemoteHostPath: remoteHostPath)
            else { return nil }
            let trimmed = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
            return Resources(root: "\(trimmed)/\(RemoteHostInstall.rootRelativePath)/\(directory)")
        }
    }

    /// What a launch knows of the device beyond the tab: its login shell
    /// (from the check), its home, and its Ghostty resources.
    struct Device: Equatable, Sendable {
        var shell: String?
        var homeDirectory: String?
        var resources: Resources?
        /// Cherry MCP for its agents (phase 4b): the forwarded control
        /// socket there, the tab's token, the install's CherryMCP.
        var mcp: RemoteMCPLaunch?

        init(shell: String? = nil, homeDirectory: String? = nil, resources: Resources? = nil, mcp: RemoteMCPLaunch? = nil) {
            self.shell = shell
            self.homeDirectory = homeDirectory
            self.resources = resources
            self.mcp = mcp
        }
    }

    /// The variables sshd sets, which say the session is remote: the
    /// program runs on the other Mac while the user sits at this one, as
    /// over `ssh`. Programs that copy check them to copy with OSC 52, which
    /// reaches this Mac's clipboard through the tab's surface, rather than
    /// to the other Mac's pasteboard (Claude Code checks `SSH_CONNECTION`;
    /// Codex and others check one of the three); they also stop opening a
    /// browser there. Neovim on macOS copies with pbcopy regardless (its
    /// user can set `vim.g.clipboard = 'osc52'` when `SSH_TTY` is set).
    /// The addresses are not the real ones (the master's are not known
    /// here, and change with the network), so they name the loopback: the
    /// port 0 says so.
    /// `SSH_TTY` is the holder's (the session's own terminal). Git, gpg and
    /// ssh do not read these; `SSH_AUTH_SOCK` stays the host's agent link.
    static let sshEnvironment: [String: String] = [
        "SSH_CONNECTION": "127.0.0.1 0 127.0.0.1 22",
        "SSH_CLIENT": "127.0.0.1 0 22"
    ]

    /// Variables that name this Mac's files, processes or account: never
    /// sent to another Mac, whatever the tab's environment says.
    static let localOnlyKeys: Set<String> = CherryTabEnvironment.keys.union([
        CherryControl.socketEnvironmentKey,
        CherryControl.mcpTokenEnvironmentKey,
        CherryControl.mcpHelperEnvironmentKey,
        CherryControl.controlMachineEnvironmentKey,
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "SSH_TTY", "PWD", "OLDPWD",
        "TERM", "TERMINFO", "TERMINFO_DIRS", "ZDOTDIR", "XDG_DATA_DIRS", "MANPATH",
        "TERM_PROGRAM_VERSION", "__CF_USER_TEXT_ENCODING", "ENV", "HISTFILE"
    ])

    static func make(
        for configuration: ShellProcessController.Configuration,
        remoteShell: String = defaultRemoteShell,
        device: Device = Device(),
        cursorBlink: Bool = true,
        localeEnvironment: [String: String]
    ) -> HostedLaunchSpec {
        var environment: [String: String] = [:]
        for (key, value) in localeEnvironment where isLocaleKey(key) {
            environment[key] = value
        }
        for (key, value) in configuration.environment where !isLocalOnly(key) {
            environment[key] = value
        }
        environment.merge(sshEnvironment) { _, ssh in ssh }
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
        if let mcp = device.mcp, let processID = configuration.processID?.nilIfEmpty {
            // The forwarded control socket there (never This Mac's path)
            // and the tab's own token.
            environment.merge(mcp.environment(processID: processID)) { _, mcp in mcp }
        }
        let shell = device.shell?.nilIfEmpty ?? remoteShell.nilIfEmpty ?? defaultRemoteShell
        var argv: [String] = if let line = configuration.startupCommand?.nilIfEmpty {
            [shell, "-l", "-c", line]
        } else {
            []
        }
        if let resources = device.resources {
            // Ghostty's own variables, as its termio sets them, with the
            // device's paths.
            environment["TERM"] = ShellProcessController.ghosttyTerm
            environment["TERMINFO"] = resources.terminfoDirectory
            environment["GHOSTTY_RESOURCES_DIR"] = resources.resourcesDirectory
            environment["GHOSTTY_SHELL_FEATURES"] = HostedLaunchContext.ghosttyShellFeatures(cursorBlink: cursorBlink)
            if argv.isEmpty, let loginShell = device.shell?.nilIfEmpty, loginShell.hasPrefix("/") {
                // A terminal: its login shell with Ghostty's integration,
                // started as a login shell as This Mac's are.
                let command = HostedLaunchSpec.ghosttyShellIntegration(
                    command: loginShell,
                    resourcesDirectory: resources.resourcesDirectory,
                    homeDirectory: device.homeDirectory,
                    environment: &environment
                )
                argv = HostedLaunchSpec.argv(
                    command: command,
                    account: HostedLaunchAccount(userName: "remote", homeDirectory: "", shell: loginShell, hushLogin: false)
                )
            }
        } else {
            environment["TERM"] = term
        }
        return HostedLaunchSpec(
            argv: argv,
            environment: environment.filter { HostedLaunchSpec.isValidEnvironmentVariable(name: $0.key, value: $0.value) },
            workingDirectory: configuration.workingDirectory
        )
    }

    /// A hosting's launch spec builder for another Mac: the login
    /// environment (this Mac's) only lends its locale; `device` says what
    /// the device has now (read at each launch: an update may add the
    /// resources).
    static func builder(
        remoteShell: String,
        device: @escaping @MainActor () -> Device = { Device() }
    ) -> PersistentHostSessions.LaunchSpecBuilder {
        { configuration, loginEnvironment in
            make(
                for: configuration,
                remoteShell: remoteShell,
                device: device(),
                cursorBlink: TerminalSettings.shared.cursorBlink,
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
