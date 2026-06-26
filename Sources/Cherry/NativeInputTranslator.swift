import Foundation

/// Translates a raw terminal-input byte stream into surface input operations for
/// the native-PTY (EXEC) backend.
///
/// Under EXEC the host has no PTY fd, so programmatic input (MCP/agent `send`,
/// including agents driving other agents through TUIs) must go through the
/// surface. `ghostty_surface_text` filters control bytes, so escape/control
/// sequences (Enter, arrows, Tab, Esc, Ctrl-combos) have to become real key
/// events — ghostty then re-encodes them for the child's *current* mode
/// (normal vs application cursor keys, kitty protocol, …). Printable runs still
/// go through the text path.
enum NativeInputOp: Equatable {
    case text(String)
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

    /// a–z → AppKit virtual keycode, indexed by letter offset (a = 0).
    private static let letterKeycodes: [UInt32] = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    ]

    static func translate(_ data: Data) -> [NativeInputOp] {
        let bytes = [UInt8](data)
        var ops: [NativeInputOp] = []
        var textBytes: [UInt8] = []

        func flush() {
            guard !textBytes.isEmpty else { return }
            ops.append(.text(String(decoding: textBytes, as: UTF8.self)))
            textBytes.removeAll(keepingCapacity: true)
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
            case 0x00: // drop NUL
                i += 1
            case 0x01...0x1A: // Ctrl-A … Ctrl-Z (specials above already handled)
                key(letterKeycodes[Int(b) - 1], control: true)
                i += 1
            default:
                textBytes.append(b)
                i += 1
            }
        }
        flush()
        return ops
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
