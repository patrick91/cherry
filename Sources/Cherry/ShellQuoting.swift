import Foundation

/// Quoting for POSIX shells (and Ghostty's shell-style command splitter).
enum ShellQuoting {
    /// `text` as one single-quoted word: each `'` in it is written `'\''`,
    /// so the shell reads it back unchanged (an empty text is `''`).
    nonisolated static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
