import Foundation

/// Commands for the Mac's login shell, which may be zsh, bash or fish: each
/// is one simple command of single-quoted words, which they all read the
/// same, and anything with control flow runs in `/bin/sh -c` with its
/// values as arguments, never pasted into the script.
enum ShellQuote {
    /// `value` as one single-quoted word (`'` as `'\''`).
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The words quoted and joined.
    static func command(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    /// `script` run by `/bin/sh` with `arguments` as `$1`, `$2`, ….
    static func sh(_ script: String, arguments: [String] = []) -> String {
        command(["/bin/sh", "-c", script, "cherry-mobile"] + arguments)
    }
}

/// Where `cherry` is on the Mac: the endpoint's own path, else the
/// installed app's in the user's Applications folder, else the system's.
enum CherryLocator {
    static let candidates = [
        #"$HOME/Applications/Cherry.app/Contents/MacOS/cherry"#,
        "/Applications/Cherry.app/Contents/MacOS/cherry",
    ]
    /// Where another Mac's Cherry installs its session host on this one
    /// (Add Mac…, Update Session Host…), for a Mac with no Cherry.app of
    /// its own: a directory per build, named by its build id
    /// (`YYYYMMDDHHMMSS.rev`), so the last in name order is the newest.
    static let deviceInstalls = #"$HOME/Library/Application Support/cherry-host/bin"#

    /// Prints the first executable among `cherryPath` (a leading `~/` is
    /// the Mac's home), `candidates`, and the newest build in
    /// `deviceInstalls` (never one still being copied, `….partial-…`), and
    /// exits 0; or exits 127 when there is none.
    static func command(
        cherryPath: String?,
        candidates: [String] = candidates,
        deviceInstalls: String = deviceInstalls
    ) -> String {
        // The candidates are the script's own words (so `$HOME` expands);
        // the endpoint's path is an argument.
        let script = #"p=$1; case $p in "~/"*) p=$HOME/${p#"~/"} ;; esac; "#
            + #"for p in "$p" "# + candidates.map { "\"\($0)\"" }.joined(separator: " ")
            + #"; do if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; exit 0; fi; done; "#
            + #"newest=; for p in "# + "\"\(deviceInstalls)\"" + #"/[0-9]*/cherry; do "#
            + #"case $p in *.partial-*) continue ;; esac; "#
            + #"if [ -f "$p" ] && [ -x "$p" ]; then newest=$p; fi; done; "#
            + #"if [ -n "$newest" ]; then printf '%s\n' "$newest"; exit 0; fi; exit 127"#
        return ShellQuote.sh(script, arguments: [cherryPath ?? ""])
    }

    static let notFoundStatus = 127
}
