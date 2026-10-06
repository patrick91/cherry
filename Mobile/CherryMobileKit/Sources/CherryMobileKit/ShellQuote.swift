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

    /// Prints the first executable among `cherryPath` and `candidates`
    /// (exit 0), or exits 127 when there is none.
    static func command(cherryPath: String?, candidates: [String] = candidates) -> String {
        // The candidates are the script's own words (so `$HOME` expands);
        // the endpoint's path is an argument.
        let script = #"for p in "$1" "# + candidates.map { "\"\($0)\"" }.joined(separator: " ")
            + #"; do if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; exit 0; fi; done; exit 127"#
        return ShellQuote.sh(script, arguments: [cherryPath ?? ""])
    }

    static let notFoundStatus = 127
}
