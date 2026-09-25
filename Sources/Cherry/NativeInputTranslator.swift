import Foundation

/// Translates a raw terminal-input byte stream into surface input operations for
/// the native-PTY (EXEC) backend.
///
/// Under EXEC the host has no PTY fd, so programmatic input (MCP/agent `send`,
/// including agents driving other agents through TUIs) must go through the
/// surface, which offers three ways in:
///
/// - Keys (`ghostty_surface_key`): Ghostty encodes them for the child's
///   *current* modes (normal vs application cursor keys, the kitty keyboard
///   protocol, …). Enter, Tab, Backspace, Escape and the escape sequences of
///   arrows, Home/End, Page Up/Down, Delete and Shift-Tab go this way.
/// - Text (`ghostty_surface_text`): Ghostty pastes it, bracketed when the
///   program turned bracketed paste on. Printable runs of text input go this
///   way, so an agent's message arrives as one paste rather than as typed
///   keys its TUI could take as shortcuts.
/// - Bytes (Ghostty's `text:` binding action): written to the PTY as they
///   are, neither encoded as keys nor pasted. Control characters (Ctrl-A …
///   Ctrl-Z, Ctrl-@, Ctrl-\ … Ctrl-_) go this way, and so do every
///   printable byte of raw input (`raw_base64`) and its Alt keys (`ESC x`):
///   what a legacy terminal sends for those keys, which programs that use
///   the kitty keyboard protocol read as the same keys (nvim, crossterm,
///   Ink). A synthesized key cannot carry them: the surface's key API gives
///   Ghostty no text and no unshifted code point, so its kitty encoder drops
///   a Ctrl-letter and its legacy encoder types no printable key.
///
/// Raw input is otherwise re-encoded like text input: CR and LF are Enter,
/// BS and DEL Backspace, a lone ESC (or one before a control character)
/// Escape, and the arrow and navigation sequences their keys.
enum NativeInputOp: Equatable {
    case text(String)
    case bytes(Data)
    case key(keycode: UInt32, shift: Bool, control: Bool, option: Bool)
}

enum NativeInputTranslator {
    /// AppKit virtual keycodes (`kVK_*`). ghostty maps these to its internal Key
    /// enum, so they're the stable contract for synthesized keys on macOS.
    private enum KC {
        static let returnKey: UInt32 = 36
        static let tab: UInt32 = 48
        static let delete: UInt32 = 51 // Backspace
        static let escape: UInt32 = 53
        static let forwardDelete: UInt32 = 117
        static let home: UInt32 = 115
        static let end: UInt32 = 119
        static let pageUp: UInt32 = 116
        static let pageDown: UInt32 = 121
        static let left: UInt32 = 123
        static let right: UInt32 = 124
        static let down: UInt32 = 125
        static let up: UInt32 = 126
    }

    /// `raw`: the input is raw bytes (`raw_base64`, `sendRaw`), whose
    /// printable bytes reach the program as they are instead of as a paste.
    static func translate(_ data: Data, raw: Bool = false) -> [NativeInputOp] {
        let bytes = [UInt8](data)
        var ops: [NativeInputOp] = []
        // The run being collected: pasted text, or bytes for the PTY.
        var runBytes: [UInt8] = []
        var runIsText = false

        func flush() {
            guard !runBytes.isEmpty else { return }
            ops.append(runIsText
                ? .text(String(decoding: runBytes, as: UTF8.self))
                : .bytes(Data(runBytes)))
            runBytes.removeAll(keepingCapacity: true)
        }
        func append(_ byte: UInt8, asText: Bool) {
            if asText != runIsText {
                flush()
                runIsText = asText
            }
            runBytes.append(byte)
        }
        func key(_ keycode: UInt32, shift: Bool = false, control: Bool = false, option: Bool = false) {
            flush()
            ops.append(.key(keycode: keycode, shift: shift, control: control, option: option))
        }

        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            switch b {
            case 0x1B: // ESC — start of a CSI/SS3 sequence, or a lone Escape
                if let (op, length) = parseEscape(bytes, from: i) {
                    flush()
                    ops.append(op)
                    i += length
                } else if let length = completeSequenceLength(bytes, from: i) {
                    // A whole sequence that is no key above (a kitty `CSI u`
                    // key, bracketed paste markers): the program gets it as
                    // it is, not an Escape key and its tail as text.
                    for byte in bytes[i..<(i + length)] {
                        append(byte, asText: false)
                    }
                    i += length
                } else if raw, i + 1 < n, isAltKeyByte(bytes[i + 1]) {
                    // Alt and a key (`ESC x`), as a legacy terminal sends
                    // it: the key's bytes follow in the same run. An Escape
                    // key would reach a program using the kitty keyboard
                    // protocol as Escape (`CSI 27 u`), then x.
                    append(b, asText: false)
                    i += 1
                } else {
                    key(KC.escape)
                    i += 1
                }
            case 0x0D: // CR -> Return (collapse CRLF into one submit)
                key(KC.returnKey)
                if i + 1 < n, bytes[i + 1] == 0x0A { i += 1 }
                i += 1
            case 0x0A: // LF -> Return
                key(KC.returnKey)
                i += 1
            case 0x09: // Tab
                key(KC.tab)
                i += 1
            case 0x08, 0x7F: // BS / DEL -> Backspace
                key(KC.delete)
                i += 1
            case 0x00...0x1F: // Ctrl-@, Ctrl-A … Ctrl-Z, Ctrl-\ … Ctrl-_ (specials above already handled)
                append(b, asText: false)
                i += 1
            default:
                append(b, asText: !raw)
                i += 1
            }
        }
        flush()
        return ops
    }

    /// A byte that, after ESC in raw input, makes the pair an Alt key rather
    /// than Escape and a key: printable ASCII, or the start of a UTF-8
    /// character. A control character or DEL after ESC stays two keys
    /// (Escape, then Enter, Tab, Backspace, … as Ghostty encodes them).
    private static func isAltKeyByte(_ byte: UInt8) -> Bool {
        (0x20...0x7E).contains(byte) || byte >= 0x80
    }

    /// Ghostty's `text:` binding action that writes `bytes` to the PTY. Its
    /// value is a Zig string literal, whose `\xNN` escape stands for a code
    /// point rather than a byte: ASCII control characters and the backslash
    /// go escaped, everything else as it is. A Swift string carries only
    /// UTF-8, so an invalid sequence becomes U+FFFD.
    static func textBindingAction(for bytes: Data) -> String {
        var action = "text:"
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x5C:
                action += "\\\\"
            case 0x00...0x1F, 0x7F:
                action += String(format: "\\x%02x", scalar.value)
            default:
                action.unicodeScalars.append(scalar)
            }
        }
        return action
    }

    /// The length of the complete CSI (`ESC [`, parameter and intermediate
    /// bytes, a final byte) or SS3 (`ESC O` and a final byte) sequence at
    /// `start` (`bytes[start] == 0x1B`); nil when there is none.
    private static func completeSequenceLength(_ bytes: [UInt8], from start: Int) -> Int? {
        let n = bytes.count
        guard start + 2 < n else { return nil }
        switch bytes[start + 1] {
        case 0x5B: // '['
            var j = start + 2
            while j < n, (0x20...0x3F).contains(bytes[j]) { j += 1 }
            guard j < n, (0x40...0x7E).contains(bytes[j]) else { return nil }
            return j - start + 1
        case 0x4F: // 'O'
            return (0x40...0x7E).contains(bytes[start + 2]) ? 3 : nil
        default:
            return nil
        }
    }

    /// Parses a CSI (`ESC [`) or SS3 (`ESC O`) sequence beginning at `start`
    /// (`bytes[start] == 0x1B`). Returns the key op and the full sequence length,
    /// or nil for a lone/unrecognized/incomplete ESC (the caller emits Escape).
    private static func parseEscape(_ bytes: [UInt8], from start: Int) -> (NativeInputOp, Int)? {
        let n = bytes.count
        guard start + 1 < n else { return nil }
        let intro = bytes[start + 1]
        guard intro == 0x5B || intro == 0x4F else { return nil } // '[' or 'O'

        // Collect numeric params (';'-separated) up to the final byte.
        var params: [Int] = []
        var current: Int?
        var j = start + 2
        while j < n {
            let c = bytes[j]
            if c >= 0x30, c <= 0x39 {
                current = (current ?? 0) * 10 + Int(c - 0x30)
                j += 1
            } else if c == 0x3B { // ';'
                params.append(current ?? 0)
                current = nil
                j += 1
            } else {
                break
            }
        }
        if let current { params.append(current) }
        guard j < n else { return nil } // incomplete sequence
        let final = bytes[j]
        let length = j - start + 1

        // xterm modifier: second param is (bitfield + 1); bits 1=shift 2=alt 4=ctrl.
        let modBits = params.count >= 2 ? max(0, params[1] - 1) : 0
        let shift = modBits & 1 != 0
        let option = modBits & 2 != 0
        let control = modBits & 4 != 0
        func arrow(_ keycode: UInt32) -> (NativeInputOp, Int) {
            (.key(keycode: keycode, shift: shift, control: control, option: option), length)
        }

        switch final {
        case 0x41: return arrow(KC.up)
        case 0x42: return arrow(KC.down)
        case 0x43: return arrow(KC.right)
        case 0x44: return arrow(KC.left)
        case 0x48: return arrow(KC.home)
        case 0x46: return arrow(KC.end)
        case 0x5A: return (.key(keycode: KC.tab, shift: true, control: false, option: false), length) // CSI Z = Shift-Tab
        case 0x7E: // CSI <n> ~
            let keycode: UInt32?
            switch params.first ?? 0 {
            case 1, 7: keycode = KC.home
            case 3: keycode = KC.forwardDelete
            case 4, 8: keycode = KC.end
            case 5: keycode = KC.pageUp
            case 6: keycode = KC.pageDown
            default: keycode = nil
            }
            guard let keycode else { return nil }
            return (.key(keycode: keycode, shift: shift, control: control, option: option), length)
        default:
            return nil
        }
    }
}
