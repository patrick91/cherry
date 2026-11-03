import CryptoKit
import Foundation

/// `cherry` first on a device terminal's PATH (docs/specs/remote-devices.md,
/// "The `cherry` command there"), as Cherry's zsh bootstrap puts it first on
/// This Mac's: its install's directory (`CHERRY_BIN_DIR` there), prepended
/// once the login shell's startup files ran, since they may set PATH from
/// scratch (path_helper, nix-darwin's /etc/zshenv) and a `cherry` of the
/// other Mac's own (an older Cherry.app's) may come first.
///
/// A terminal there runs its login shell with Ghostty's integration from the
/// install (`RemoteLaunchSpec`); a small file per shell goes in front of
/// Ghostty's: zsh's `.zshenv` (ZDOTDIR), bash's ENV file, fish's
/// `vendor_conf.d`. Each runs Ghostty's as before and adds the directory at
/// the first prompt (zsh, fish) or once Ghostty's has read the startup files
/// (bash). The launch writes the files there itself, so every install has
/// them, older ones included: `<cherry-host>/shell/<digest>/`, beside the
/// installs' `bin/`, named by their contents (one with other contents is
/// another directory) and written atomically. When they cannot be written,
/// the terminal starts with Ghostty's alone, as before. Apple's /bin/bash,
/// which Ghostty does not integrate, and other shells get nothing.
enum RemoteShellBootstrap {
    /// Where the files go, relative to the cherry-host directory.
    static let directoryName = "shell"
    /// The install's directory, which the files put first on PATH.
    static let binDirectoryKey = TabCLIDirectory.environmentKey
    /// Ghostty's ZDOTDIR or ENV file, which Cherry's file runs first.
    static let ghosttyZDOTDIRKey = "CHERRY_GHOSTTY_ZDOTDIR"
    static let ghosttyBashEnvironmentKey = "CHERRY_GHOSTTY_BASH_ENV"
    /// The directory fish's file takes back out of XDG_DATA_DIRS.
    static let fishDataDirectoryKey = "CHERRY_SHELL_XDG_DIR"

    enum Shell: CaseIterable, Sendable {
        case zsh, bash, fish

        /// The file's path in the directory.
        var path: String {
            switch self {
            case .zsh: "zsh/.zshenv"
            case .bash: "bash/cherry.bash"
            case .fish: "fish/vendor_conf.d/cherry-bin-path.fish"
            }
        }

        var contents: String {
            switch self {
            case .zsh: RemoteShellBootstrap.zshenv
            case .bash: RemoteShellBootstrap.bashEnvironment
            case .fish: RemoteShellBootstrap.fishConfiguration
            }
        }
    }

    /// The directory's name: the digest of every file, so a change makes a
    /// new one and a launch never reads a file of other contents.
    static let digest: String = {
        var hasher = SHA256()
        for shell in Shell.allCases {
            hasher.update(data: Data("\(shell.path)\0\(shell.contents)\0".utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// The files' directory for the install at `installRoot`
    /// (`<cherry-host>/bin/<build>`): `<cherry-host>/shell/<digest>`.
    static func directory(installRoot: String) -> String {
        let cherryHost = ((installRoot as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return "\(cherryHost)/\(directoryName)/\(digest)"
    }

    /// The launch of a terminal running `command` (Ghostty's integration
    /// already set up in `environment`) with `installRoot` first on PATH:
    /// the shell layer's command line, which writes the shell's file if it
    /// is not there and points the shell at it, then runs `command` as
    /// `HostedLaunchSpec.argv` does. Nil for a shell it does not know, or
    /// one Ghostty's integration was not set up for.
    static func launchLine(
        command: String,
        loginShell: String,
        installRoot: String,
        environment: inout [String: String]
    ) -> String? {
        let shell: Shell
        let pointAtFile: String
        let directory = directory(installRoot: installRoot)
        switch URL(fileURLWithPath: loginShell).lastPathComponent {
        case "zsh" where environment["ZDOTDIR"] != nil:
            shell = .zsh
            pointAtFile = "export \(ghosttyZDOTDIRKey)=\"$ZDOTDIR\" ZDOTDIR=\"$d/zsh\""
        case "bash" where environment["ENV"] != nil:
            shell = .bash
            pointAtFile = "export \(ghosttyBashEnvironmentKey)=\"$ENV\" ENV=\"$d/\(Shell.bash.path)\""
        case "fish" where environment["XDG_DATA_DIRS"] != nil:
            shell = .fish
            pointAtFile = "export XDG_DATA_DIRS=\"$d:$XDG_DATA_DIRS\" \(fishDataDirectoryKey)=\"$d\""
        default:
            return nil
        }
        environment[binDirectoryKey] = installRoot
        let folder = (shell.path as NSString).deletingLastPathComponent
        let write = [
            "/bin/mkdir -p \"$d/\(folder)\"",
            "t=$(/usr/bin/mktemp \"$d/\(folder)/.cherry.XXXXXX\")",
            "printf '%s' \(ShellQuoting.singleQuoted(shell.contents)) > \"$t\"",
            "/bin/mv -f \"$t\" \"$f\"",
        ].joined(separator: " && ")
        return [
            "d=\(ShellQuoting.singleQuoted(directory)); f=\"$d/\(shell.path)\"",
            "if [ -f \"$f\" ] || { \(write); } 2>/dev/null; then \(pointAtFile); fi",
            "exec -l \(command)",
        ].joined(separator: "; ")
    }

    // MARK: - The files

    static let zshenv = """
    # Written by Cherry for its terminals on this Mac. Do not edit.
    # Ghostty's zsh integration first: it puts ZDOTDIR back, reads the
    # user's .zshenv and loads itself. Then, at the first prompt, once every
    # startup file ran, `cherry` first on PATH.
    ZDOTDIR="${CHERRY_GHOSTTY_ZDOTDIR-}"
    builtin unset CHERRY_GHOSTTY_ZDOTDIR
    if [[ -n "$ZDOTDIR" && -r "$ZDOTDIR/.zshenv" ]]; then
      builtin source "$ZDOTDIR/.zshenv"
    else
      if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
        builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
        builtin unset GHOSTTY_ZSH_ZDOTDIR
      else
        builtin unset ZDOTDIR
      fi
      [[ ! -r "${ZDOTDIR-$HOME}/.zshenv" ]] || builtin source "${ZDOTDIR-$HOME}/.zshenv"
    fi
    if [[ -o interactive && -n "${CHERRY_BIN_DIR-}" ]]; then
      _cherry_bin_path() {
        path=("$CHERRY_BIN_DIR" ${path:#${(b)CHERRY_BIN_DIR}})
        precmd_functions=(${precmd_functions:#_cherry_bin_path})
        builtin unfunction _cherry_bin_path
      }
      typeset -ga precmd_functions
      precmd_functions+=(_cherry_bin_path)
    fi

    """

    static let bashEnvironment = """
    # Written by Cherry for its terminals on this Mac. Do not edit.
    # Ghostty's bash integration first (it reads the startup files), then
    # `cherry` first on PATH.
    if [ -n "${CHERRY_GHOSTTY_BASH_ENV-}" ]; then
      ENV="$CHERRY_GHOSTTY_BASH_ENV"
      unset CHERRY_GHOSTTY_BASH_ENV
      [ -r "$ENV" ] && . "$ENV"
    fi
    if [ -n "${CHERRY_BIN_DIR-}" ]; then
      __cherry_path=":$PATH:"
      __cherry_path="${__cherry_path//:"$CHERRY_BIN_DIR":/:}"
      __cherry_path="${__cherry_path#:}"
      __cherry_path="${__cherry_path%:}"
      export PATH="$CHERRY_BIN_DIR${__cherry_path:+:$__cherry_path}"
      unset __cherry_path
    fi

    """

    static let fishConfiguration = """
    # Written by Cherry for its terminals on this Mac. Do not edit.
    # Out of XDG_DATA_DIRS again; then, at the first prompt, once every
    # startup file ran, `cherry` first on PATH.
    if set -q CHERRY_SHELL_XDG_DIR
        set -l __cherry_dirs (string match --invert -- $CHERRY_SHELL_XDG_DIR (string split : -- "$XDG_DATA_DIRS"))
        if set -q __cherry_dirs[1]
            set --global --export XDG_DATA_DIRS (string join : -- $__cherry_dirs)
        else
            set --erase XDG_DATA_DIRS
        end
        set --erase CHERRY_SHELL_XDG_DIR
    end
    if status is-interactive; and set -q CHERRY_BIN_DIR
        function __cherry_bin_path --on-event fish_prompt
            functions --erase __cherry_bin_path
            set --global --export PATH $CHERRY_BIN_DIR (string match --invert -- $CHERRY_BIN_DIR $PATH)
        end
    end

    """
}
