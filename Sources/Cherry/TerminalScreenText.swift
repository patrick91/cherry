import Foundation

/// A terminal screen's text (the surface's `ghostty_surface_read_text`, a
/// host's `Screen`) read at the byte level for a tab's line model. Hashing
/// a `String` and splitting it into lines go through its Characters, which
/// took milliseconds of the main thread for each read of a long scrollback
/// with any non-ASCII text (box drawing, a prompt's symbols); these give
/// the same lines from its UTF-8 bytes.
enum TerminalScreenText {
    /// A hash of the text's UTF-8 bytes, for telling whether a screen read
    /// changed since the last one.
    static func contentHash(of text: String) -> Int {
        var text = text
        return text.withUTF8 { bytes in
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
            return hasher.finalize()
        }
    }

    /// The text's lines: what `text.split(separator: "\n",
    /// omittingEmptySubsequences: false)` gives. That split never splits
    /// after a "\r" ("\r\n" is one Character), so neither does this.
    static func lines(of text: String) -> [String] {
        var text = text
        return text.withUTF8 { bytes in
            var lines: [String] = []
            var start = 0
            for index in bytes.indices where bytes[index] == 0x0A && (index == 0 || bytes[index - 1] != 0x0D) {
                lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
                start = index + 1
            }
            lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self))
            return lines
        }
    }
}
