// Temporary keyboard diagnostics; remove once the Shift+Enter/Shift+Tab report is understood.
//
// `CherryMCP --key-echo [--log PATH]`: shows, one line per key, the bytes a
// terminal sends for each key pressed, in the keyboard mode it asks the
// terminal for (keys 1-4, as Claude Code does with mode 4). Help ›
// Keyboard Diagnostics… opens a tab running it and reads its log.

import Darwin
import Foundation

/// What `--key-echo` asks the terminal for (keys 1-4).
enum KeyEchoMode: Int, CaseIterable, Sendable {
    case legacy = 1
    /// Kitty keyboard flags 5 (disambiguate, report alternate keys), as Claude Code pushes them.
    case kitty = 2
    /// xterm's modifyOtherKeys at level 2.
    case modifyOtherKeys = 3
    /// Both, as Claude Code asks a terminal it takes for Ghostty.
    case claudeCode = 4

    /// Pops the kitty flags a mode pushed: written only when this program
    /// pushed some, so the flags the terminal had before stay as they were.
    static let popKittyFlags = "\u{1b}[<u"
    /// Turns modifyOtherKeys off. It has no stack: this also turns off
    /// what the terminal had before.
    static let modifyOtherKeysOff = "\u{1b}[>4m"
    /// Asks the terminal for its kitty flags: it answers `CSI ? flags u`.
    static let kittyFlagsQuery = "\u{1b}[?u"
    /// Asks for the primary device attributes, which every terminal
    /// answers: after the flags query at start, an answer to this alone
    /// means a terminal without the kitty keyboard protocol.
    static let deviceAttributesQuery = "\u{1b}[c"

    /// The log's name of the mode.
    var id: String {
        switch self {
        case .legacy: "legacy"
        case .kitty: "kitty-5"
        case .modifyOtherKeys: "modify-other-keys-2"
        case .claudeCode: "kitty-5+modify-other-keys-2"
        }
    }

    var label: String {
        switch self {
        case .legacy: "1 legacy (pushes nothing, CSI > 4 m)"
        case .kitty: "2 kitty flags 5 (CSI > 5 u)"
        case .modifyOtherKeys: "3 modifyOtherKeys 2 (CSI > 4 ; 2 m)"
        case .claudeCode: "4 kitty flags 5 + modifyOtherKeys 2, as Claude Code"
        }
    }

    var pushesKittyFlags: Bool {
        self == .kitty || self == .claudeCode
    }

    /// What switching to this mode writes: a pop of the kitty flags this
    /// program pushed (`popping`), modifyOtherKeys off, the mode's own
    /// requests, then the kitty flags query.
    func request(popping: Bool) -> String {
        let enable = switch self {
        case .legacy: ""
        case .kitty: "\u{1b}[>5u"
        case .modifyOtherKeys: "\u{1b}[>4;2m"
        case .claudeCode: "\u{1b}[>5u\u{1b}[>4;2m"
        }
        return (popping ? Self.popKittyFlags : "") + Self.modifyOtherKeysOff + enable + Self.kittyFlagsQuery
    }
}

/// One line of the `--log` file (JSON Lines). `event` is `start` (with the
/// terminal variables the program got, where it runs, and the terminal's
/// kitty flags before it changed anything, in `before`), `mode` (what was
/// written to switch modes, in `escaped`) or `key`.
struct KeyEchoLogRecord: Codable, Equatable, Sendable {
    var event: String
    var time: String
    var mode: String
    var hex: String? = nil
    var escaped: String? = nil
    var name: String? = nil
    var term: String? = nil
    var termProgram: String? = nil
    var termProgramVersion: String? = nil
    var place: String? = nil
    var before: String? = nil

    enum CodingKeys: String, CodingKey {
        case event, time, mode, hex, escaped, name, term, place, before
        case termProgram = "term_program"
        case termProgramVersion = "term_program_version"
    }

    func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Bytes that arrive within `window` of each other are one key press.
struct KeyEchoGrouper: Sendable {
    static let window: TimeInterval = 0.015

    private(set) var pending: [UInt8] = []
    private var lastArrival: TimeInterval = 0

    /// Adds bytes read at `time`; returns the previous key press when these
    /// came after the window closed.
    mutating func add(_ bytes: [UInt8], at time: TimeInterval) -> [UInt8]? {
        var finished: [UInt8]?
        if !pending.isEmpty, time - lastArrival > Self.window {
            finished = pending
            pending = []
        }
        pending += bytes
        lastArrival = time
        return finished
    }

    /// The key press waiting, once nothing more came within the window.
    mutating func flush() -> [UInt8]? {
        defer { pending = [] }
        return pending.isEmpty ? nil : pending
    }
}

public enum KeyEcho {
    enum Command: Equatable {
        case quit
        case mode(KeyEchoMode)
    }

    struct Description: Equatable {
        var hex: String
        var escaped: String
        var name: String
    }

    static func describe(_ bytes: [UInt8]) -> Description {
        Description(
            hex: hex(bytes),
            escaped: escaped(bytes),
            name: tokens(bytes).map { name(of: $0) }.joined(separator: ", ")
        )
    }

    /// What the terminal answered to the start's queries
    /// (`KeyEchoMode.kittyFlagsQuery`, then `deviceAttributesQuery`).
    struct StartupAnswers: Equatable {
        /// The kitty flags the terminal had before this program changed
        /// anything; nil when it did not answer.
        var kittyFlags: Int?
        var deviceAttributes = false
        /// Anything else that came meanwhile: keys pressed early.
        var rest: [UInt8] = []

        /// The log's `before`.
        var summary: String {
            if let kittyFlags { return "kitty keyboard flags = \(kittyFlags)" }
            return deviceAttributes
                ? "no answer to CSI ? u (no kitty keyboard protocol)"
                : "no answer to CSI ? u or CSI c within 0.5 s"
        }
    }

    static func startupAnswers(_ bytes: [UInt8]) -> StartupAnswers {
        var answers = StartupAnswers()
        for token in tokens(bytes) {
            guard token.count > 2, token[0] == 0x1b, token[1] == 0x5b, let csi = CSI(token), csi.prefix == "?" else {
                answers.rest += token
                continue
            }
            switch csi.final {
            case "u" where answers.kittyFlags == nil: answers.kittyFlags = csi.value(0, default: 0)
            case "c": answers.deviceAttributes = true
            default: answers.rest += token
            }
        }
        return answers
    }

    /// Where the program runs, from the variables Cherry gives its tabs:
    /// a persistent session's host sets `CHERRY_SESSION_ID`.
    static func place(_ environment: [String: String]) -> String {
        if let session = environment["CHERRY_SESSION_ID"], !session.isEmpty {
            return "a Cherry persistent session (\(session))"
        }
        return environment["INSIDE_CHERRY"] == "1" ? "a native Cherry tab" : "a terminal outside Cherry"
    }

    /// q, or Ctrl+C in any encoding, quits; 1-4 switch modes.
    static func command(for bytes: [UInt8]) -> Command? {
        let tokens = tokens(bytes)
        guard tokens.count == 1, let (code, modifiers) = keyCode(of: tokens[0]) else { return nil }
        if modifiers == 0, code == 0x71 { return .quit }
        if modifiers == 4, code == 0x63 { return .quit }
        if modifiers == 0, let mode = KeyEchoMode(rawValue: code - 0x30) { return .mode(mode) }
        return nil
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// ESC for 0x1b, ^X for other control bytes, ␠ for a space.
    static func escaped(_ bytes: [UInt8]) -> String {
        var result = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x1b: result += "ESC"
            case 0x00..<0x20: result += "^" + String(UnicodeScalar(byte + 0x40))
            case 0x20: result += "␠"
            case 0x7f: result += "^?"
            case 0x21..<0x7f: result += String(UnicodeScalar(byte))
            default:
                let length = utf8Length(bytes, at: index)
                if length > 1, let text = String(bytes: bytes[index..<index + length], encoding: .utf8) {
                    result += text
                    index += length
                    continue
                }
                result += String(format: "\\x%02x", byte)
            }
            index += 1
        }
        return result
    }

    /// Splits bytes into keys: escape sequences, ESC-prefixed (Alt) keys,
    /// control bytes and characters.
    static func tokens(_ bytes: [UInt8]) -> [[UInt8]] {
        var tokens: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            let end = tokenEnd(bytes, from: index)
            tokens.append(Array(bytes[index..<end]))
            index = end
        }
        return tokens
    }

    private static func tokenEnd(_ bytes: [UInt8], from start: Int) -> Int {
        let byte = bytes[start]
        if byte == 0x1b {
            guard start + 1 < bytes.count else { return start + 1 }
            switch bytes[start + 1] {
            case 0x5b: // CSI: parameters and intermediates, then a final byte.
                var end = start + 2
                while end < bytes.count, (0x20...0x3f).contains(bytes[end]) { end += 1 }
                return end < bytes.count && (0x40...0x7e).contains(bytes[end]) ? end + 1 : end
            case 0x4f where start + 2 < bytes.count: // SS3
                return start + 3
            default: // Alt: ESC and the next key.
                return tokenEnd(bytes, from: start + 1)
            }
        }
        return byte < 0x80 ? start + 1 : min(bytes.count, start + max(1, utf8Length(bytes, at: start)))
    }

    private static func utf8Length(_ bytes: [UInt8], at index: Int) -> Int {
        let lead = bytes[index]
        let length = switch lead {
        case 0xc0..<0xe0: 2
        case 0xe0..<0xf0: 3
        case 0xf0..<0xf8: 4
        default: 1
        }
        guard index + length <= bytes.count,
              bytes[index + 1..<index + length].allSatisfy({ $0 & 0xc0 == 0x80 })
        else { return 1 }
        return length
    }

    /// The key's name, with how it was encoded when that matters:
    /// "Shift+Enter (xterm CSI 27 ~ form)", "Shift+Tab (CSI Z)", "Enter (CR)".
    static func name(of token: [UInt8]) -> String {
        let (key, encoding) = key(of: token)
        return encoding.map { "\(key) (\($0))" } ?? key
    }

    private static func key(of token: [UInt8]) -> (String, String?) {
        guard let first = token.first else { return ("nothing", nil) }
        if first == 0x1b {
            guard token.count > 1 else { return ("Escape", nil) }
            if token[1] == 0x5b { return csiKey(token) }
            if token[1] == 0x4f, token.count == 3 { return ss3Key(token[2]) }
            let (inner, _) = key(of: Array(token.dropFirst()))
            return ("Alt+" + inner, "ESC prefix")
        }
        if token.count == 1 { return controlOrASCIIKey(first) }
        if let text = String(bytes: token, encoding: .utf8) { return (text, nil) }
        return ("invalid UTF-8", nil)
    }

    private static func controlOrASCIIKey(_ byte: UInt8) -> (String, String?) {
        switch byte {
        case 0x0d: ("Enter", "CR")
        case 0x0a: ("Ctrl+J", "LF")
        case 0x09: ("Tab", nil)
        case 0x7f: ("Backspace", "DEL")
        case 0x08: ("Ctrl+H", "BS")
        case 0x00: ("Ctrl+Space", "NUL")
        case 0x01...0x1a: ("Ctrl+" + String(UnicodeScalar(byte + 0x40)), nil)
        case 0x1c: ("Ctrl+\\", nil)
        case 0x1d: ("Ctrl+]", nil)
        case 0x1e: ("Ctrl+^", nil)
        case 0x1f: ("Ctrl+_", nil)
        case 0x20: ("Space", nil)
        case 0x21..<0x7f: (String(UnicodeScalar(byte)), nil)
        default: ("invalid UTF-8", nil)
        }
    }

    private static func ss3Key(_ final: UInt8) -> (String, String?) {
        let names: [UInt8: String] = [
            0x41: "Up", 0x42: "Down", 0x43: "Right", 0x44: "Left", 0x48: "Home", 0x46: "End",
            0x50: "F1", 0x51: "F2", 0x52: "F3", 0x53: "F4", 0x4d: "Keypad Enter",
        ]
        return (names[final] ?? "SS3 " + String(UnicodeScalar(final)), "SS3")
    }

    /// `CSI [prefix] params final`, its parameters as numbers (subparameters
    /// after `:`).
    private struct CSI {
        var prefix: Character?
        var parameters: [[Int]]
        var final: Character
        var body: String

        init?(_ token: [UInt8]) {
            guard token.count >= 3, let last = token.last, (0x40...0x7e).contains(last) else { return nil }
            var body = String(decoding: token[2..<token.count - 1], as: UTF8.self)
            self.body = body
            final = Character(UnicodeScalar(last))
            if let first = body.first, "?<>=".contains(first) {
                prefix = first
                body.removeFirst()
            }
            parameters = body.isEmpty ? [] : body.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            }
        }

        func value(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < parameters.count, let value = parameters[index].first, value > 0 else { return fallback }
            return value
        }
    }

    private static func csiKey(_ token: [UInt8]) -> (String, String?) {
        guard let csi = CSI(token) else { return ("incomplete escape sequence", nil) }
        switch (csi.prefix, csi.final) {
        case ("?", "u"):
            return ("kitty keyboard flags = \(csi.value(0, default: 0))", "answer to CSI ? u; in a persistent tab, from the session host")
        case ("?", "c"):
            return ("device attributes", "answer to CSI c")
        case (nil, "u"):
            var key = modifierNames(csi.value(1)) + keyName(csi.value(0))
            if let event = csi.parameters.count > 1 ? csi.parameters[1].dropFirst().first : nil {
                key += event == 3 ? " release" : event == 2 ? " repeat" : ""
            }
            return (key, "kitty CSI-u \(csi.body)")
        case (nil, "~") where csi.value(0) == 27 && csi.parameters.count >= 3:
            // The form modifyOtherKeys uses, which Ghostty also types for some
            // keys (Shift+Enter) without it.
            return (modifierNames(csi.value(1)) + keyName(csi.value(2)), "xterm CSI 27 ~ form")
        case (nil, "~"):
            let key = functionKeys[csi.value(0)] ?? "key \(csi.value(0))"
            return (modifierNames(csi.value(1)) + key, nil)
        case (nil, "Z"):
            return (modifierNames(max(csi.value(1), 2)) + "Tab", "CSI Z")
        case (nil, "I"):
            return ("Focus in", nil)
        case (nil, "O"):
            return ("Focus out", nil)
        case (nil, let final) where cursorKeys[final] != nil:
            return (modifierNames(csi.value(1)) + cursorKeys[final]!, nil)
        default:
            return ("unknown CSI \(escaped(token))", nil)
        }
    }

    private static let cursorKeys: [Character: String] = [
        "A": "Up", "B": "Down", "C": "Right", "D": "Left", "H": "Home", "F": "End",
        "P": "F1", "Q": "F2", "R": "F3", "S": "F4", "E": "Keypad 5",
    ]

    private static let functionKeys: [Int: String] = [
        1: "Home", 2: "Insert", 3: "Delete", 4: "End", 5: "Page Up", 6: "Page Down", 7: "Home", 8: "End",
        11: "F1", 12: "F2", 13: "F3", 14: "F4", 15: "F5", 17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10",
        23: "F11", 24: "F12", 200: "Paste start", 201: "Paste end",
    ]

    /// "Ctrl+Alt+Shift+" for the xterm/kitty modifier parameter (1 + bits).
    private static func modifierNames(_ parameter: Int) -> String {
        let bits = max(parameter - 1, 0)
        let names: [(Int, String)] = [
            (4, "Ctrl"), (2, "Alt"), (1, "Shift"), (8, "Super"), (16, "Hyper"), (32, "Meta"),
            (64, "CapsLock"), (128, "NumLock"),
        ]
        return names.filter { bits & $0.0 != 0 }.map { $0.1 + "+" }.joined()
    }

    /// A key's Unicode code point as kitty and modifyOtherKeys send it.
    private static func keyName(_ code: Int) -> String {
        switch code {
        case 13: return "Enter"
        case 9: return "Tab"
        case 27: return "Escape"
        case 127, 8: return "Backspace"
        case 32: return "Space"
        case 57414: return "Keypad Enter"
        default:
            guard (33..<57344).contains(code), let scalar = UnicodeScalar(code) else { return "key \(code)" }
            return String(Character(scalar)).uppercased()
        }
    }

    /// Caps Lock and Num Lock, which Ghostty reports with every kitty key.
    private static let lockModifiers = 64 | 128

    /// The key's code point and modifier bits, without the locks, for the
    /// commands: a plain character, a control byte, a kitty CSI-u or a
    /// CSI 27 ~ key.
    private static func keyCode(of token: [UInt8]) -> (Int, Int)? {
        if token.count == 1 {
            let byte = Int(token[0])
            if (0x01...0x1a).contains(byte), byte != 0x09, byte != 0x0a, byte != 0x0d, byte != 0x08 {
                return (byte + 0x60, 4)
            }
            return (0x20..<0x7f).contains(byte) ? (byte, 0) : nil
        }
        guard token.first == 0x1b, token.count > 2, token[1] == 0x5b, let csi = CSI(token), csi.prefix == nil else { return nil }
        let modifiers = (csi.value(1) - 1) & ~lockModifiers
        if csi.final == "u" { return (csi.value(0), modifiers) }
        if csi.final == "~", csi.value(0) == 27, csi.parameters.count >= 3 { return (csi.value(2), modifiers) }
        return nil
    }

    // MARK: - Running

    /// `--key-echo [--log PATH]`. Never returns.
    public static func run(arguments: [String]) -> Never {
        var logPath: String?
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--log", let path = remaining.popFirst() {
                logPath = path
            } else {
                fputs("usage: CherryMCP --key-echo [--log PATH]\n", stderr)
                exit(2)
            }
        }
        guard isatty(STDIN_FILENO) == 1 else {
            fputs("CherryMCP --key-echo: standard input is not a terminal\n", stderr)
            exit(2)
        }
        var session = KeyEchoSession(logPath: logPath)
        session.run()
    }
}

// The terminal's settings before raw mode, restored on every exit,
// including from a signal handler, and whether the current mode pushed
// kitty flags, which the restore then pops.
nonisolated(unsafe) private var keyEchoSavedTerminal = termios()
nonisolated(unsafe) private var keyEchoRestoresTerminal = false
nonisolated(unsafe) private var keyEchoPushedKittyFlags = false
private let keyEchoResetBytes = Array(KeyEchoMode.modifyOtherKeysOff.utf8)
private let keyEchoPopAndResetBytes = Array((KeyEchoMode.popKittyFlags + KeyEchoMode.modifyOtherKeysOff).utf8)

private func keyEchoRestoreTerminal() {
    guard keyEchoRestoresTerminal else { return }
    let bytes = keyEchoPushedKittyFlags ? keyEchoPopAndResetBytes : keyEchoResetBytes
    bytes.withUnsafeBufferPointer { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &keyEchoSavedTerminal)
}

private func keyEchoSignalHandler(_ signal: Int32) {
    keyEchoRestoreTerminal()
    _exit(128 + signal)
}

private struct KeyEchoSession {
    /// How long the start waits for the answers to its queries.
    static let startupAnswerWait: TimeInterval = 0.5

    var mode = KeyEchoMode.legacy
    var grouper = KeyEchoGrouper()
    let logDescriptor: Int32
    let logError: Int32
    let logPath: String?
    let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(logPath: String?) {
        self.logPath = logPath
        logDescriptor = logPath.map { open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600) } ?? -1
        logError = errno
    }

    mutating func run() -> Never {
        guard tcgetattr(STDIN_FILENO, &keyEchoSavedTerminal) == 0 else {
            fputs("CherryMCP --key-echo: cannot read the terminal's settings\n", stderr)
            exit(1)
        }
        signal(SIGPIPE, SIG_IGN)
        // Initialized before any handler reads them.
        _ = keyEchoResetBytes.count + keyEchoPopAndResetBytes.count
        for number in [SIGINT, SIGTERM, SIGHUP] { signal(number, keyEchoSignalHandler) }
        var raw = keyEchoSavedTerminal
        cfmakeraw(&raw)
        keyEchoRestoresTerminal = true
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { finish(status: 1) }

        // The terminal's kitty flags before anything changes them (another
        // program may have left some pushed).
        write(KeyEchoMode.kittyFlagsQuery + KeyEchoMode.deviceAttributesQuery)
        let answers = KeyEcho.startupAnswers(readStartupAnswers())

        let environment = ProcessInfo.processInfo.environment
        let terminal = ["TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"]
            .map { "\($0)=\(environment[$0] ?? "(unset)")" }.joined(separator: " ")
        let place = KeyEcho.place(environment)
        output("Cherry key echo (temporary keyboard diagnostics)")
        output("Running in \(place)")
        if environment["CHERRY_SESSION_ID"]?.isEmpty == false {
            output("Cherry's session host, not Ghostty's surface, answers the queries (CSI ? u, CSI c).")
        }
        output(terminal)
        output("Before any change: \(answers.summary)" + ((answers.kittyFlags ?? 0) > 0 ? " (pushed by an earlier program; mode 1 keeps them)" : ""))
        if let logPath { output(logDescriptor >= 0 ? "Log: \(logPath)" : "Cannot write the log \(logPath): \(String(cString: strerror(logError)))") }
        output("Press keys to see what the terminal sends: Enter, Shift+Enter, Shift+Tab, Option+Enter, Ctrl+J.")
        output("No default keybind changes Escape, Ctrl+Enter or Option+A: they show whether a mode reached the terminal.")
        output("Modes: " + KeyEchoMode.allCases.map(\.label).joined(separator: " · ") + " · q or Ctrl+C quits")
        log(KeyEchoLogRecord(
            event: "start", time: now(), mode: mode.id,
            term: environment["TERM"], termProgram: environment["TERM_PROGRAM"],
            termProgramVersion: environment["TERM_PROGRAM_VERSION"],
            place: place, before: answers.summary
        ))
        switchMode(to: .legacy)
        if !answers.rest.isEmpty { handle(answers.rest) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, grouper.pending.isEmpty ? -1 : Int32(KeyEchoGrouper.window * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if let press = grouper.flush() { handle(press) }
                continue
            }
            if descriptor.revents & Int16(POLLIN) == 0 { break } // POLLHUP, POLLERR: the terminal went away.
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }
            if let press = grouper.add(Array(buffer[0..<count]), at: ProcessInfo.processInfo.systemUptime) {
                handle(press)
            }
        }
        finish(status: 0)
    }

    /// What came until the device attributes answer (every terminal
    /// answers it, after the kitty flags when it has the protocol), at most
    /// `startupAnswerWait`.
    private func readStartupAnswers() -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.startupAnswerWait
        while !KeyEcho.startupAnswers(bytes).deviceAttributes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { break }
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }
            bytes += buffer[0..<count]
        }
        return bytes
    }

    private mutating func handle(_ press: [UInt8]) {
        switch KeyEcho.command(for: press) {
        case .quit:
            output("Bye.")
            finish(status: 0)
        case .mode(let next):
            switchMode(to: next)
        case nil:
            let description = KeyEcho.describe(press)
            output("[\(mode.id)] \(description.name)   \(description.escaped)   \(description.hex)")
            log(KeyEchoLogRecord(
                event: "key", time: now(), mode: mode.id,
                hex: description.hex, escaped: description.escaped, name: description.name
            ))
        }
    }

    private mutating func switchMode(to next: KeyEchoMode) {
        mode = next
        let request = next.request(popping: keyEchoPushedKittyFlags)
        write(request)
        keyEchoPushedKittyFlags = next.pushesKittyFlags
        output("── mode \(next.label) · wrote \(KeyEcho.escaped(Array(request.utf8))) ──")
        log(KeyEchoLogRecord(event: "mode", time: now(), mode: next.id, escaped: KeyEcho.escaped(Array(request.utf8))))
    }

    private func now() -> String {
        timeFormatter.string(from: Date())
    }

    private func output(_ line: String) {
        write(line + "\r\n")
    }

    private func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBufferPointer { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR || errno == EAGAIN { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }

    private func log(_ record: KeyEchoLogRecord) {
        guard logDescriptor >= 0 else { return }
        let line = Array(record.jsonLine().utf8)
        _ = line.withUnsafeBufferPointer { Darwin.write(logDescriptor, $0.baseAddress, $0.count) }
    }

    private func finish(status: Int32) -> Never {
        keyEchoRestoreTerminal()
        exit(status)
    }
}
