import CherryControl
import CryptoKit
import Darwin
import Dispatch
import Foundation
import GhosttyKit
import GhosttyTerminal

/// What `cherry-host`'s Create needs to start a local hosted session that
/// behaves like the native Ghostty EXEC launch of the same tab
/// (`ShellProcessController.nativeExecLaunch` run by libghostty).
///
/// The host clears its sessions' environment, so `environment` is complete:
/// Cherry's own environment as Ghostty passes it on, Ghostty's additions,
/// then Cherry's launch environment. Only two things differ on purpose:
/// Ghostty's resources (terminfo and shell integration) come from a stable
/// copy outside the app bundle, because a session outlives the bundle's path,
/// and nothing describes a Ghostty surface or the terminal Cherry itself was
/// started from.
///
/// Build one per launch (`prepare(for:…)`) and keep it: a Create retry must
/// resend the same spec, because the host's `request_id` fingerprint covers
/// the environment, and preparing again re-reads the login environment, the
/// account and the zsh bootstrap.
struct HostedLaunchSpec: Equatable, Sendable {
    /// Create's `command`: `/bin/bash --noprofile --norc -c 'exec -l <shell
    /// command>'`, the layer Ghostty runs inside its login(1) wrapper on
    /// macOS, without the wrapper. The user's shell is still a login shell
    /// (`exec -l`, argv0 `-zsh`), and it is the session leader, so the host
    /// reports its exact exit status and its foreground job.
    ///
    /// Why not login(1) as in a native tab: `/usr/bin/login` exits 0 whatever
    /// the shell's status, which would hide every command's and agent's exit
    /// code (auto-restart backoff, agent idle/error). What it did besides
    /// starting the shell does not apply or is carried explicitly: HOME,
    /// USER, LOGNAME, SHELL and PATH are in `environment`; there is no utmp
    /// entry, no "Last login" banner and so no `~/.hushlogin` check.
    let argv: [String]
    /// Create's `env`: the session's whole environment. The host adds its
    /// own `CHERRY_SESSION_ID`, sets `PWD` (to `workingDirectory` whenever
    /// that path is valid, as here), and adds its inherited variables and
    /// SSH agent link where this map has none (no TMPDIR or SSH_AUTH_SOCK).
    let environment: [String: String]
    /// Create's `cwd`, as the tab asked for it (not canonicalised); `PWD` is
    /// the same path. The host rejects a directory that does not exist.
    let workingDirectory: String

    /// The staged Ghostty resources copy the session reads (its content
    /// hash, `GhosttyStagedResources`): the `cherry.resources` tag, which
    /// keeps that copy from being removed while the session runs.
    var resourcesCopy: String? {
        guard let directory = environment["GHOSTTY_RESOURCES_DIR"]?.nilIfEmpty else { return nil }
        let name = URL(fileURLWithPath: directory).deletingLastPathComponent().lastPathComponent
        return GhosttyResourceStaging.isCopyName(name) ? name : nil
    }

    /// The shell layer between the host and the user's login shell.
    static let launchShell = "/bin/bash"
    /// Native tabs' login(1) wrapper, which hosted sessions leave out.
    static let loginProgram = "/usr/bin/login"
    /// The TERM a session gets when no staged terminfo describes
    /// `xterm-ghostty`, as Ghostty itself does without its resources.
    static let fallbackTerm = "xterm-256color"

    /// The launch for `configuration` (the tab's
    /// `ShellProcessController.Configuration`). Pure: `context` carries
    /// everything read from the system.
    static func make(
        for configuration: ShellProcessController.Configuration,
        context: HostedLaunchContext
    ) -> HostedLaunchSpec {
        let resources = context.ghosttyResources
        var environment = baseEnvironment(context: context)

        // Ghostty's termio Exec.Subprocess.init, in its order.
        if let resources {
            environment["GHOSTTY_RESOURCES_DIR"] = resources.resourcesDirectory
            environment["TERM"] = configuration.term
            environment["COLORTERM"] = "truecolor"
            // Ghostty derives it as `<resources>/../terminfo`; the staged copy
            // keeps the two directories siblings.
            environment["TERMINFO"] = resources.terminfoDirectory
        } else {
            environment["TERM"] = fallbackTerm
            environment["COLORTERM"] = "truecolor"
        }
        if let binDirectory = context.executableDirectory, !binDirectory.isEmpty {
            environment["GHOSTTY_BIN_DIR"] = binDirectory
            let path = environment["PATH"] ?? ""
            if !path.split(separator: ":").contains(Substring(binDirectory)) {
                environment["PATH"] = appendingPathList(path, binDirectory)
            }
        }
        if let resources {
            environment["XDG_DATA_DIRS"] = appendingPathList(
                environment["XDG_DATA_DIRS"] ?? defaultXDGDataDirectories,
                "\(resources.resourcesDirectory)/.."
            )
            // Ghostty always adds the separator, so an unset MANPATH still
            // searches the system's manual pages.
            environment["MANPATH"] = "\(environment["MANPATH"] ?? ""):\(resources.resourcesDirectory)/../man"
        }
        environment["TERM_PROGRAM"] = "ghostty"
        if let version = context.terminalProgramVersion, !version.isEmpty {
            environment["TERM_PROGRAM_VERSION"] = version
        }
        environment["VTE_VERSION"] = nil
        if !context.shellFeatures.isEmpty {
            environment["GHOSTTY_SHELL_FEATURES"] = context.shellFeatures
        }

        let isZsh = URL(fileURLWithPath: configuration.shellPath).lastPathComponent == "zsh"
        let cherry = ShellProcessController.nativeExecLaunch(
            for: configuration,
            shellIntegration: isZsh ? context.zshBootstrap : nil,
            inheritedEnvironment: context.processEnvironment,
            terminfoDirectories: resources?.terminfoDirectory
        )
        let command = if let resources {
            ghosttyShellIntegration(
                command: cherry.command,
                resourcesDirectory: resources.resourcesDirectory,
                homeDirectory: context.processEnvironment["HOME"] ?? context.account?.homeDirectory,
                environment: &environment
            )
        } else {
            cherry.command
        }

        // Cherry's environment overrides everything, as Ghostty's env_override.
        environment.merge(cherry.environment) { _, cherry in cherry }
        if resources == nil, environment["TERM"] == ShellProcessController.ghosttyTerm {
            environment["TERM"] = fallbackTerm
        }
        environment["PWD"] = configuration.workingDirectory

        return HostedLaunchSpec(
            argv: argv(command: command, account: context.account),
            // One unusable variable (a cherry.toml key with `=`, say) must not
            // fail the whole Create.
            environment: environment.filter { isValidEnvironmentVariable(name: $0.key, value: $0.value) },
            workingDirectory: configuration.workingDirectory
        )
    }

    /// The launch for `configuration` from this app now: a context prepared
    /// for its shell, then `make`. The defaults are this process's; tests
    /// replace them.
    static func prepare(
        for configuration: ShellProcessController.Configuration,
        loginEnvironment: [String: String]?,
        cursorBlink: Bool,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        executableDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        parentProcessID: pid_t = getppid(),
        stager: GhosttyResourceStager = .shared
    ) async -> HostedLaunchSpec {
        let context = await HostedLaunchContext.prepare(
            for: configuration,
            loginEnvironment: loginEnvironment,
            cursorBlink: cursorBlink,
            processEnvironment: processEnvironment,
            executableDirectory: executableDirectory,
            homeDirectory: homeDirectory,
            parentProcessID: parentProcessID,
            stager: stager
        )
        return make(for: configuration, context: context)
    }

    /// What the host accepts in Create's `env` (and what execve can carry):
    /// a non-empty name without `=` or NUL, and a value without NUL. The
    /// host must accept every variable that passes; `make` drops the rest.
    static func isValidEnvironmentVariable(name: String, value: String) -> Bool {
        !name.isEmpty && !name.contains("=") && !name.contains("\0") && !value.contains("\0")
    }

    /// Ghostty's execCommand on macOS without its login(1) wrapper (see
    /// `argv`): bash, whose `exec -l` splits the command as Ghostty's does
    /// and makes it a login shell that replaces bash. Without an account
    /// Ghostty lets `/bin/sh` split the command, and so does this.
    static func argv(command: String, account: HostedLaunchAccount?) -> [String] {
        guard let account, !account.userName.isEmpty else {
            return ["/bin/sh", "-c", command]
        }
        return [launchShell, "--noprofile", "--norc", "-c", "exec -l \(command)"]
    }

    /// The launch command inside the shell layer: the last argument without
    /// its `exec -l ` prefix, or the `/bin/sh -c` command.
    var shellCommand: String? {
        guard let last = argv.last else { return nil }
        let prefix = "exec -l "
        return argv.first == Self.launchShell && last.hasPrefix(prefix) ? String(last.dropFirst(prefix.count)) : last
    }

    // MARK: - Environment

    private static let defaultXDGDataDirectories = "/usr/local/share:/usr/share"
    private static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Ghostty's own last resort when no locale is configured.
    private static let defaultLanguage = "en_US.UTF-8"

    /// Cherry's environment as a native tab inherits it, minus what describes
    /// another terminal, surface or tab, plus the account variables the host
    /// would otherwise take from whoever started it.
    static func baseEnvironment(context: HostedLaunchContext) -> [String: String] {
        let process = context.processEnvironment
        var environment = process.filter { !isInheritedTerminalState($0.key) }
        // Ghostty's embedded defaultTermioEnv: an app run from Xcode keeps
        // Xcode's loader variables to itself.
        if process["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
            for key in xcodeLaunchKeys { environment[key] = nil }
        }
        // Launched from the desktop, libghostty set LANGUAGE (the preferred
        // languages) for Cherry's own translations; its children, and so
        // native tabs, never get it.
        if context.launchedFromDesktop {
            environment["LANGUAGE"] = nil
        }
        // Cherry started from a Cherry agent tab carries that tab's bootstrap
        // ZDOTDIR; nativeExecLaunch treats that as "no original ZDOTDIR".
        if let bootstrap = process["CHERRY_BOOTSTRAP_ZDOTDIR"], process["ZDOTDIR"] == bootstrap {
            environment["ZDOTDIR"] = nil
        }

        let account = context.account
        environment["HOME"] = nonEmpty(process["HOME"]) ?? nonEmpty(account?.homeDirectory)
        environment["USER"] = nonEmpty(process["USER"]) ?? nonEmpty(account?.userName)
        environment["LOGNAME"] = nonEmpty(process["LOGNAME"]) ?? nonEmpty(account?.userName)
        environment["SHELL"] = nonEmpty(process["SHELL"]) ?? nonEmpty(account?.shell)
        environment["PATH"] = nonEmpty(process["PATH"]) ?? defaultPath
        environment["LANG"] = nonEmpty(process["LANG"]) ?? nonEmpty(context.loginEnvironment?["LANG"]) ?? defaultLanguage
        // The agent the user's own shell startup chose (1Password, Secretive,
        // gpg), else launchd's. Without one the host's agent link applies.
        environment["SSH_AUTH_SOCK"] = nonEmpty(context.loginEnvironment?["SSH_AUTH_SOCK"])
            ?? nonEmpty(process["SSH_AUTH_SOCK"])
        return environment
    }

    /// Variables of Cherry's own environment that describe the terminal, tab
    /// or Ghostty surface Cherry was started from (or one it created), never
    /// the user. Ghostty and Cherry set their own values where a session has
    /// one.
    static func isInheritedTerminalState(_ key: String) -> Bool {
        inheritedTerminalKeys.contains(key) || key.hasPrefix("GHOSTTY_") || key.hasPrefix("XPC_")
    }

    private static let inheritedTerminalKeys = CherryTabEnvironment.keys.union([
        // The shell or terminal that started Cherry.
        "PWD", "OLDPWD", "SHLVL", "_", "LINES", "COLUMNS",
        "TERM", "TERMINFO", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "VTE_VERSION",
        "TERM_SESSION_ID", "ITERM_SESSION_ID", "KITTY_WINDOW_ID", "KITTY_PID", "WEZTERM_PANE",
        "ALACRITTY_WINDOW_ID", "WINDOWID", "TMUX", "TMUX_PANE", "STY",
        // Cherry is a colour terminal (the forkpty launch drops it too).
        "NO_COLOR",
        // Set explicitly from the login environment.
        "SSH_AUTH_SOCK"
    ])

    /// What Ghostty removes when Cherry runs from Xcode (it also drops
    /// XPC_SERVICE_NAME, which every hosted launch drops).
    private static let xcodeLaunchKeys = [
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS", "__XPC_DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SECURITYSESSIONID"
    ]

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Ghostty's appendEnv: `value` alone when the list is empty.
    private static func appendingPathList(_ list: String, _ value: String) -> String {
        list.isEmpty ? value : "\(list):\(value)"
    }

    /// Ghostty's prependEnv: `value` alone when the list is empty.
    private static func prependingPathList(_ list: String, _ value: String) -> String {
        list.isEmpty ? value : "\(value):\(list)"
    }

    // MARK: - Ghostty shell integration

    /// Ghostty's automatic shell integration (termio/shell_integration.zig,
    /// `detect` mode) applied to a command `nativeExecLaunch` produced.
    /// Returns the command to run and updates `environment` the way Ghostty
    /// does before Cherry's own variables override it. For zsh with Cherry's
    /// bootstrap only GHOSTTY_ZSH_ZDOTDIR survives; bash (except Apple's
    /// /bin/bash), fish, elvish and nushell get Ghostty's OSC 7/133 hooks, as
    /// in a native tab.
    ///
    /// Ghostty only looks at the first word and at flags before any `-c`, so
    /// splitting on whitespace matches its parser for these commands; a
    /// command it does not rewrite is returned unchanged, quotes included.
    static func ghosttyShellIntegration(
        command: String,
        resourcesDirectory: String,
        homeDirectory: String?,
        environment: inout [String: String]
    ) -> String {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = words.first else { return command }
        let arguments = Array(words.dropFirst())
        let integrationDirectory = "\(resourcesDirectory)/shell-integration"

        func isShortFlagWithCommand(_ argument: String) -> Bool {
            argument.count > 1 && argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.contains("c")
        }

        func setUpXDGDataDirectories() {
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integrationDirectory
            environment["XDG_DATA_DIRS"] = prependingPathList(
                environment["XDG_DATA_DIRS"] ?? defaultXDGDataDirectories,
                integrationDirectory
            )
        }

        switch URL(fileURLWithPath: executable).lastPathComponent {
        case "bash":
            // Apple's bash 3.2 ignores ENV in POSIX mode.
            guard executable != "/bin/bash" else { return command }
            var rewritten = [executable, "--posix"]
            var inject = "1"
            var rcFile: String?
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--posix" || isShortFlagWithCommand(argument) {
                    return command
                } else if argument == "--norc" {
                    inject += " --norc"
                } else if argument == "--noprofile" {
                    inject += " --noprofile"
                } else if argument == "--rcfile" || argument == "--init-file" {
                    index += 1
                    rcFile = index < arguments.count ? arguments[index] : nil
                } else if argument == "-" || argument == "--" {
                    rewritten += arguments[index...]
                    break
                } else {
                    rewritten.append(argument)
                }
                index += 1
            }
            if let previous = environment["ENV"] {
                environment["GHOSTTY_BASH_ENV"] = previous
            }
            environment["ENV"] = "\(integrationDirectory)/bash/ghostty.bash"
            environment["GHOSTTY_BASH_INJECT"] = inject
            if let rcFile { environment["GHOSTTY_BASH_RCFILE"] = rcFile }
            // POSIX mode would otherwise default HISTFILE to ~/.sh_history.
            if environment["HISTFILE"] == nil, let homeDirectory, !homeDirectory.isEmpty {
                environment["HISTFILE"] = "\(homeDirectory)/.bash_history"
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            return rewritten.joined(separator: " ")
        case "zsh":
            if let previous = environment["ZDOTDIR"] {
                environment["GHOSTTY_ZSH_ZDOTDIR"] = previous
            }
            environment["ZDOTDIR"] = "\(integrationDirectory)/zsh"
            return command
        case "fish", "elvish":
            setUpXDGDataDirectories()
            return command
        case "nu":
            setUpXDGDataDirectories()
            var rewritten = [executable, "--execute 'use ghostty *'"]
            for (index, argument) in arguments.enumerated() {
                if argument == "--command" || argument == "--lsp" || isShortFlagWithCommand(argument) {
                    return command
                } else if argument == "-" || argument == "--" {
                    rewritten += arguments[index...]
                    break
                }
                rewritten.append(argument)
            }
            return rewritten.joined(separator: " ")
        default:
            return command
        }
    }
}

extension ShellProcessController {
    /// The TERM Cherry advertises, described by Ghostty's bundled terminfo.
    static let ghosttyTerm = "xterm-ghostty"
}

/// Variables that identify one Cherry tab or hosted session and carry its
/// shell-integration plumbing. They never describe the user: when Cherry
/// runs inside a Cherry tab, nothing may pass them on from its own
/// environment as if they described a new session. `HostedLaunchSpec` and
/// `HostedSessionLoginEnvironment` both drop exactly these.
enum CherryTabEnvironment {
    static let keys: Set<String> = [
        CherryControl.projectRootEnvironmentKey, CherryControl.processIDEnvironmentKey,
        CherryControl.agentIDEnvironmentKey, "CHERRY_SESSION_ID", "CHERRY_BOOTSTRAP_ZDOTDIR",
        "CHERRY_ORIGINAL_ZDOTDIR", "CHERRY_STARTUP_COMMAND", "CHERRY_EMIT_OSC133",
        "CHERRY_TERM_PROGRAM", "INSIDE_CHERRY"
    ]
}

/// The account a session runs as, from the passwd database.
struct HostedLaunchAccount: Equatable, Sendable {
    var userName: String
    var homeDirectory: String
    var shell: String
    /// `~/.hushlogin` exists. Ghostty checks it itself and passes `-q` to
    /// login(1) for native tabs; hosted sessions run no login(1), so they
    /// print no banner either way.
    var hushLogin: Bool

    /// The current user's passwd entry, or nil when there is none (Ghostty
    /// then runs the command without the login wrapper, and a hosted
    /// session through `/bin/sh`).
    static func current(fileManager: FileManager = .default) -> HostedLaunchAccount? {
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var capacity = suggested > 0 ? max(Int(suggested), 1024) : 16384
        while capacity <= 1 << 20 {
            var buffer = [CChar](repeating: 0, count: capacity)
            // The entry's strings live in `buffer`: copy them out inside.
            let lookup: (status: Int32, entry: (name: String, home: String, shell: String)?) =
                buffer.withUnsafeMutableBufferPointer { buffer in
                    var record = passwd()
                    var result: UnsafeMutablePointer<passwd>?
                    let status = getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result)
                    guard status == 0, result != nil else { return (status, nil) }
                    return (status, (
                        name: record.pw_name.map { String(cString: $0) } ?? "",
                        home: record.pw_dir.map { String(cString: $0) } ?? "",
                        shell: record.pw_shell.map { String(cString: $0) } ?? ""
                    ))
                }
            if lookup.status == ERANGE {
                capacity *= 2
                continue
            }
            guard let entry = lookup.entry, !entry.name.isEmpty else { return nil }
            return HostedLaunchAccount(
                userName: entry.name,
                homeDirectory: entry.home,
                shell: entry.shell,
                hushLogin: !entry.home.isEmpty && fileManager.fileExists(atPath: "\(entry.home)/.hushlogin")
            )
        }
        return nil
    }
}

/// Everything `HostedLaunchSpec.make` reads from outside the tab's
/// configuration. `prepare` gathers it for this app; tests build it directly.
struct HostedLaunchContext: Equatable, Sendable {
    /// Cherry's own environment, which native tabs inherit through Ghostty.
    var processEnvironment: [String: String]
    /// The captured login-shell environment (`HostedSessionLoginEnvironment`),
    /// used for SSH_AUTH_SOCK and as a LANG fallback. Nil when not captured.
    var loginEnvironment: [String: String]?
    /// Nil: `/bin/sh` runs the command (see `HostedLaunchSpec.argv`).
    var account: HostedLaunchAccount?
    /// Ghostty's launchedFromDesktop for Cherry's process: its children
    /// then never inherit LANGUAGE.
    var launchedFromDesktop: Bool
    /// Nil when staging failed: the session then gets TERM=xterm-256color
    /// and no Ghostty shell integration rather than paths into the bundle.
    var ghosttyResources: GhosttyStagedResources?
    /// Cherry's zsh bootstrap, used when the configuration's shell is zsh.
    /// `prepare(for:)` writes it only for a zsh configuration, so a context
    /// belongs to the configuration it was prepared for.
    var zshBootstrap: ShellIntegrationBootstrap?
    /// Cherry.app/Contents/MacOS: Ghostty's GHOSTTY_BIN_DIR, appended to
    /// PATH so the bundled `cherry` and `CherryMCP` are found, as in a
    /// native tab. It is the running app's path, not a staged copy.
    var executableDirectory: String?
    /// TERM_PROGRAM_VERSION: the embedded Ghostty's version.
    var terminalProgramVersion: String?
    /// GHOSTTY_SHELL_FEATURES, as Ghostty derives it from its configuration.
    var shellFeatures: String

    /// Ghostty's defaults as Cherry configures it: cursor, path and title on;
    /// sudo, ssh-env and ssh-terminfo off. The cursor feature follows the
    /// cursor blink setting.
    static func ghosttyShellFeatures(cursorBlink: Bool) -> String {
        "cursor:\(cursorBlink ? "blink" : "steady"),path,title"
    }

    /// The version string of the Ghostty library Cherry embeds, as native
    /// tabs see it in TERM_PROGRAM_VERSION.
    static let embeddedGhosttyVersion: String? = {
        let info = ghostty_info()
        guard let version = info.version, info.version_len > 0 else { return nil }
        let bytes = UnsafeRawBufferPointer(start: version, count: Int(info.version_len))
        return String(decoding: bytes, as: UTF8.self)
    }()

    /// Ghostty's launchedFromDesktop() as the embedded library evaluates it
    /// on macOS: started by launchd (Finder, Dock, `open`), or marked as an
    /// app launch.
    static func isLaunchedFromDesktop(processEnvironment: [String: String], parentProcessID: pid_t) -> Bool {
        processEnvironment["GHOSTTY_MAC_LAUNCH_SOURCE"] == "app" || parentProcessID == 1
    }

    /// The context for launching `configuration` from this app right now.
    /// Stages Ghostty's resources (once per process), rewrites the zsh
    /// bootstrap as every native launch of that shell does, and reads the
    /// account, all on the stager's queue, never on the caller's thread.
    /// Resource staging failure is not fatal: see `ghosttyResources`.
    static func prepare(
        for configuration: ShellProcessController.Configuration,
        loginEnvironment: [String: String]?,
        cursorBlink: Bool,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        executableDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        parentProcessID: pid_t = getppid(),
        stager: GhosttyResourceStager = .shared
    ) async -> HostedLaunchContext {
        let shellPath = configuration.shellPath
        let resources = try? await stager.resolve()
        let (bootstrap, account) = await stager.perform {
            (
                try? ShellIntegrationBootstrap.prepare(shellPath: shellPath, homeDirectory: homeDirectory),
                HostedLaunchAccount.current()
            )
        }
        return HostedLaunchContext(
            processEnvironment: processEnvironment,
            loginEnvironment: loginEnvironment,
            account: account,
            launchedFromDesktop: isLaunchedFromDesktop(
                processEnvironment: processEnvironment,
                parentProcessID: parentProcessID
            ),
            ghosttyResources: resources,
            zshBootstrap: bootstrap,
            executableDirectory: executableDirectory,
            terminalProgramVersion: embeddedGhosttyVersion,
            shellFeatures: ghosttyShellFeatures(cursorBlink: cursorBlink)
        )
    }
}

// MARK: - Ghostty resources

/// A copy of Ghostty's runtime resources at
/// `Application Support/<app>/GhosttyResources/<content hash>/`. Its path
/// changes only when the resources' contents do, so a session started by one
/// build keeps working after the app is moved, updated or deleted.
struct GhosttyStagedResources: Equatable, Sendable {
    /// `…/GhosttyResources/<content hash>`.
    let rootDirectory: String

    /// GHOSTTY_RESOURCES_DIR: holds `shell-integration/`.
    var resourcesDirectory: String { "\(rootDirectory)/\(GhosttyResourceStaging.resourcesName)" }
    /// TERMINFO and the head of TERMINFO_DIRS.
    var terminfoDirectory: String { "\(rootDirectory)/\(GhosttyResourceStaging.terminfoName)" }
    var shellIntegrationDirectory: String { "\(resourcesDirectory)/shell-integration" }
}

enum GhosttyResourceStagingError: Error, Equatable, CustomStringConvertible {
    case resourcesMissing
    case unsupportedFile(String)

    var description: String {
        switch self {
        case .resourcesMissing: "The app bundle has no Ghostty resources to stage."
        case let .unsupportedFile(path): "Ghostty resource \(path) is not a file, directory or symbolic link."
        }
    }
}

/// Copies Ghostty's resource directories out of the app bundle into a
/// content-addressed directory. A new copy is assembled beside the
/// destination and renamed into place, so a present destination is always
/// complete; a damaged one is repaired file by file, also by renames, and
/// never taken away from the sessions using it. Blocking file I/O: use
/// `GhosttyResourceStager` from app code.
enum GhosttyResourceStaging {
    static let resourcesName = "Ghostty"
    static let terminfoName = "terminfo"
    /// Assemblies and replacement files, named in the base directory.
    static let stagingPrefix = ".staging-"
    /// Whatever a repair moved out of the way before deleting it.
    static let stalePrefix = ".stale-"
    /// Leftovers of an interrupted stage older than this are removed.
    static let leftoverAge: TimeInterval = 60 * 60
    private static let formatVersion = "cherry-ghostty-resources-1"

    struct Source: Equatable, Sendable {
        /// Ghostty's resources directory (`…/Ghostty`, with shell-integration).
        let resourcesDirectory: URL
        /// Ghostty's compiled terminfo directory.
        let terminfoDirectory: URL
    }

    /// One entry of the resources, read into memory (they are small, about
    /// 80 KB), in the order a copy creates them: each directory before its
    /// contents.
    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case directory
            case file(contents: Data, executable: Bool)
            case symbolicLink(target: String)
        }

        /// Relative to the staged root: `Ghostty/…` or `terminfo/…`.
        let path: String
        let kind: Kind
    }

    /// The directories `GhosttyRuntimeResources` resolves in the app bundle
    /// (or SwiftPM's resource bundle when unbundled).
    static func bundledSource() -> Source? {
        guard let resources = GhosttyRuntimeResources.directoryURL,
              let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL
        else { return nil }
        return Source(resourcesDirectory: resources, terminfoDirectory: terminfo)
    }

    static func defaultBaseDirectory(
        applicationSupportName: String = CherryAppIdentity.current.applicationSupportName,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportName, isDirectory: true)
            .appendingPathComponent("GhosttyResources", isDirectory: true)
    }

    /// Stages `source` under `baseDirectory` and returns the copy. A present
    /// copy (one this or another process staged first) only has missing or
    /// changed entries replaced; entries the resources do not have, such as
    /// a terminfo entry `tic` compiled into TERMINFO, are left alone.
    static func stage(
        _ source: Source,
        into baseDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> GhosttyStagedResources {
        // Read once: the hash and every file written come from this snapshot,
        // so a directory holds its hash's contents even when the bundle is
        // updated meanwhile.
        let entries = try snapshot(source)
        let destination = baseDirectory.appendingPathComponent(contentHash(of: entries), isDirectory: true)
        let staged = GhosttyStagedResources(rootDirectory: destination.path)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { removeLeftovers(in: baseDirectory, fileManager: fileManager) }

        if !isDirectory(destination.path) {
            moveAside(destination.path, ifDirectory: false, in: baseDirectory, fileManager: fileManager)
            let temporary = temporaryURL(in: baseDirectory)
            defer { try? fileManager.removeItem(at: temporary) }
            try create(Entry(path: "", kind: .directory), at: temporary.path)
            for entry in entries {
                try create(entry, at: temporary.appendingPathComponent(entry.path).path)
            }
            if rename(temporary.path, destination.path) == 0 { return staged }
            let error = errno
            // Another process staged the same contents first: check its copy
            // like any present one.
            guard error == EEXIST || error == ENOTEMPTY else { throw posixError(error) }
        }
        try repair(destination, to: entries, in: baseDirectory, fileManager: fileManager)
        return staged
    }

    /// Ghostty's resources as `stage` copies them.
    static func snapshot(_ source: Source) throws -> [Entry] {
        var entries: [Entry] = []
        try readTree(at: source.resourcesDirectory.resolvingSymlinksInPath().path, relativePath: resourcesName, into: &entries)
        try readTree(at: source.terminfoDirectory.resolvingSymlinksInPath().path, relativePath: terminfoName, into: &entries)
        return entries
    }

    /// A hex SHA-256 prefix over both trees: every path, entry type,
    /// executable bit, file contents and link target. Identical resources
    /// always stage to the same directory.
    static func contentHash(resourcesDirectory: URL, terminfoDirectory: URL) throws -> String {
        contentHash(of: try snapshot(Source(resourcesDirectory: resourcesDirectory, terminfoDirectory: terminfoDirectory)))
    }

    static func contentHash(of entries: [Entry]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(formatVersion)\0".utf8))
        for entry in entries {
            let (kind, extra): (String, Data) = switch entry.kind {
            case .directory: ("d", Data())
            case let .file(contents, executable): (executable ? "x" : "f", contents)
            case let .symbolicLink(target): ("l", Data(target.utf8))
            }
            hasher.update(data: Data("\(kind)\0\(entry.path)\0".utf8))
            var length = UInt64(extra.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: extra)
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func readTree(at path: String, relativePath: String, into entries: inout [Entry]) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw GhosttyResourceStagingError.resourcesMissing
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            entries.append(Entry(path: relativePath, kind: .directory))
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for name in names {
                try readTree(at: "\(path)/\(name)", relativePath: "\(relativePath)/\(name)", into: &entries)
            }
        case S_IFREG:
            let contents = try Data(contentsOf: URL(fileURLWithPath: path), options: .uncached)
            entries.append(Entry(path: relativePath, kind: .file(contents: contents, executable: status.st_mode & 0o111 != 0)))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            entries.append(Entry(path: relativePath, kind: .symbolicLink(target: target)))
        default:
            throw GhosttyResourceStagingError.unsupportedFile(relativePath)
        }
    }

    /// Replaces each entry of `root` that differs from `entries`. A file or
    /// link is written aside and renamed over the old one, so a session
    /// reading it sees either version, never neither; only an entry of the
    /// wrong kind is removed first. Concurrent repairs write the same bytes.
    private static func repair(
        _ root: URL,
        to entries: [Entry],
        in baseDirectory: URL,
        fileManager: FileManager
    ) throws {
        for entry in entries {
            let path = root.appendingPathComponent(entry.path).path
            guard !matches(entry, at: path) else { continue }
            if entry.kind == .directory {
                moveAside(path, ifDirectory: false, in: baseDirectory, fileManager: fileManager)
                if mkdir(path, 0o755) != 0 {
                    let error = errno
                    guard error == EEXIST && isDirectory(path) else { throw posixError(error) }
                }
                continue
            }
            let replacement = temporaryURL(in: baseDirectory).path
            try create(entry, at: replacement)
            // rename(2) replaces a file or link, never a directory.
            moveAside(path, ifDirectory: true, in: baseDirectory, fileManager: fileManager)
            if rename(replacement, path) != 0 {
                let error = errno
                unlink(replacement)
                throw posixError(error)
            }
        }
    }

    private static func matches(_ entry: Entry, at path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        switch entry.kind {
        case .directory:
            return status.st_mode & S_IFMT == S_IFDIR
        case let .file(contents, executable):
            guard status.st_mode & S_IFMT == S_IFREG,
                  (status.st_mode & 0o111 != 0) == executable,
                  status.st_size == off_t(contents.count)
            else { return false }
            return (try? Data(contentsOf: URL(fileURLWithPath: path), options: .uncached)) == contents
        case let .symbolicLink(target):
            return status.st_mode & S_IFMT == S_IFLNK
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == target
        }
    }

    /// Creates `entry` at `path`, which must not exist.
    private static func create(_ entry: Entry, at path: String) throws {
        switch entry.kind {
        case .directory:
            guard mkdir(path, 0o755) == 0 else { throw posixError(errno) }
        case let .file(contents, executable):
            try contents.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            guard chmod(path, executable ? 0o755 : 0o644) == 0 else { throw posixError(errno) }
        case let .symbolicLink(target):
            guard symlink(target, path) == 0 else { throw posixError(errno) }
        }
    }

    /// Renames what is at `path` out of the way, then deletes it, when it is
    /// a directory (`ifDirectory`) or when it is anything else. The kind is
    /// checked right before the rename, so the entry a concurrent repair
    /// just made is left alone.
    private static func moveAside(
        _ path: String,
        ifDirectory: Bool,
        in baseDirectory: URL,
        fileManager: FileManager
    ) {
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT == S_IFDIR) == ifDirectory else { return }
        let stale = baseDirectory.appendingPathComponent(stalePrefix + UUID().uuidString)
        if rename(path, stale.path) == 0 {
            try? fileManager.removeItem(at: stale)
        }
    }

    private static func temporaryURL(in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Copies other than the current one that no running session names are
    /// kept this long after their last use at least (`staleCopies`): a
    /// generous margin for sessions the list does not show yet.
    static let staleCopyAge: TimeInterval = 30 * 24 * 60 * 60

    /// Whether `name` is a copy's directory name (its content hash).
    static func isCopyName(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy(\.isHexDigit)
    }

    /// Marks `staged` as used now (its modification time).
    static func noteUse(of staged: GhosttyStagedResources) {
        utimes(staged.rootDirectory, nil)
    }

    /// The copies in `baseDirectory` no session uses any more: not
    /// `current`, not named by a running session (`inUse`: the
    /// `cherry.resources` tags of every running session the host lists,
    /// whoever owns it) and last used (`noteUse`) more than `staleCopyAge`
    /// ago. A copy's sessions read it for their whole life (TERMINFO, shell
    /// integration). The caller asks only with a complete live list in
    /// which every running session of this app is tagged.
    static func staleCopies(
        in baseDirectory: URL,
        current: String?,
        inUse: Set<String>,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: baseDirectory.path) else { return [] }
        let cutoff = now.addingTimeInterval(-staleCopyAge)
        return names.sorted().compactMap { name in
            guard name != current, !inUse.contains(name), !name.hasPrefix("."), isCopyName(name) else { return nil }
            let url = baseDirectory.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(url.path),
                  let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff
            else { return nil }
            return url
        }
    }

    /// Removes `staleCopies`, each moved aside first so no half-deleted copy
    /// is ever at a copy's path.
    static func removeStaleCopies(
        in baseDirectory: URL,
        current: String?,
        inUse: Set<String>,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        for url in staleCopies(in: baseDirectory, current: current, inUse: inUse, now: now, fileManager: fileManager) {
            moveAside(url.path, ifDirectory: true, in: baseDirectory, fileManager: fileManager)
        }
    }

    /// Best effort, on every stage: assemblies, replacement files and moved
    /// entries an interrupted stage left.
    private static func removeLeftovers(in baseDirectory: URL, fileManager: FileManager) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: baseDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-leftoverAge)
        for name in names where name.hasPrefix(stagingPrefix) || name.hasPrefix(stalePrefix) {
            let url = baseDirectory.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Stages the bundled Ghostty resources at most once per process, on its own
/// serial queue. A failure is retried by the next call.
final class GhosttyResourceStager: @unchecked Sendable {
    static let shared = GhosttyResourceStager(
        source: { GhosttyResourceStaging.bundledSource() },
        baseDirectory: GhosttyResourceStaging.defaultBaseDirectory()
    )

    private let queue = DispatchQueue(label: "Cherry.GhosttyResourceStager", qos: .userInitiated)
    private let source: @Sendable () -> GhosttyResourceStaging.Source?
    private let baseDirectory: URL
    /// Only touched on `queue`.
    private var staged: GhosttyStagedResources?

    init(source: @escaping @Sendable () -> GhosttyResourceStaging.Source?, baseDirectory: URL) {
        self.source = source
        self.baseDirectory = baseDirectory
    }

    func resolve() async throws -> GhosttyStagedResources {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.resolveOnQueue() }) }
        }
    }

    /// Runs other launch preparation (file writes, passwd) on the stager's
    /// queue, after any staging already requested.
    func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Removes the staged copies no session uses any more
    /// (`GhosttyResourceStaging.staleCopies`), in the background: `inUse`
    /// are the copies the running sessions name. Leaves everything alone
    /// before this process staged its own copy.
    func removeStaleCopies(inUse: Set<String>) {
        let baseDirectory = baseDirectory
        queue.async {
            guard let staged = self.staged else { return }
            GhosttyResourceStaging.removeStaleCopies(
                in: baseDirectory,
                current: URL(fileURLWithPath: staged.rootDirectory).lastPathComponent,
                inUse: inUse
            )
        }
    }

    private func resolveOnQueue() throws -> GhosttyStagedResources {
        // Checked in full once per process; a copy deleted while the app
        // runs is staged again. Each use marks the copy used
        // (`removeStaleCopies`).
        if let staged,
           FileManager.default.fileExists(atPath: staged.resourcesDirectory),
           FileManager.default.fileExists(atPath: staged.terminfoDirectory) {
            GhosttyResourceStaging.noteUse(of: staged)
            return staged
        }
        guard let source = source() else { throw GhosttyResourceStagingError.resourcesMissing }
        let result = try GhosttyResourceStaging.stage(source, into: baseDirectory)
        GhosttyResourceStaging.noteUse(of: result)
        staged = result
        return result
    }
}
