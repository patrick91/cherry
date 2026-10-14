// Temporary keyboard diagnostics; remove once the Shift+Enter/Shift+Tab report is understood.

import Foundation
import Testing
@testable import Cherry
@testable import CherryMCP

private func utf8Bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
private func keyEchoName(_ text: String) -> String { KeyEcho.describe(utf8Bytes(text)).name }

// MARK: - CherryMCP --key-echo

@Test func keyEchoNamesTheEncodingsOfShiftEnterAndShiftTab() {
    #expect(KeyEcho.describe(utf8Bytes("\u{1b}[27;2;13~")) == KeyEcho.Description(
        hex: "1b 5b 32 37 3b 32 3b 31 33 7e",
        escaped: "ESC[27;2;13~",
        name: "Shift+Enter (xterm CSI 27 ~ form)"
    ))
    #expect(keyEchoName("\r") == "Enter (CR)")
    #expect(keyEchoName("\n") == "Ctrl+J (LF)")
    #expect(keyEchoName("\u{1b}\r") == "Alt+Enter (ESC prefix)")
    #expect(keyEchoName("\u{1b}[13;2u") == "Shift+Enter (kitty CSI-u 13;2)")
    #expect(keyEchoName("\u{1b}[Z") == "Shift+Tab (CSI Z)")
    #expect(keyEchoName("\u{1b}[9;2u") == "Shift+Tab (kitty CSI-u 9;2)")
    #expect(keyEchoName("\u{1b}[27;2;9~") == "Shift+Tab (xterm CSI 27 ~ form)")
    #expect(keyEchoName("\t") == "Tab")
}

@Test func keyEchoNamesOtherKeysAndTheTerminalsAnswers() {
    #expect(keyEchoName("\u{1b}") == "Escape")
    #expect(keyEchoName("\u{1b}[27u") == "Escape (kitty CSI-u 27)")
    #expect(keyEchoName("\u{1b}[99;5u") == "Ctrl+C (kitty CSI-u 99;5)")
    #expect(keyEchoName("\u{1b}[13;2:3u") == "Shift+Enter release (kitty CSI-u 13;2:3)")
    #expect(keyEchoName("\u{1b}[?5u") == "kitty keyboard flags = 5 (answer to CSI ? u; in a persistent tab, from the session host)")
    #expect(keyEchoName("\u{1b}[?62;22c") == "device attributes (answer to CSI c)")
    #expect(keyEchoName("\u{1b}[A") == "Up")
    #expect(keyEchoName("\u{1b}OA") == "Up (SS3)")
    #expect(keyEchoName("\u{1b}[1;2A") == "Shift+Up")
    #expect(keyEchoName("\u{1b}[1;3D") == "Alt+Left")
    #expect(keyEchoName("\u{1b}[3~") == "Delete")
    #expect(keyEchoName("\u{1b}[13;5~") == "Ctrl+F3")
    #expect(keyEchoName("\u{1b}[200~") == "Paste start")
    #expect(keyEchoName("\u{1b}b") == "Alt+b (ESC prefix)")
    #expect(keyEchoName("\u{3}") == "Ctrl+C")
    #expect(keyEchoName("\u{7f}") == "Backspace (DEL)")
    #expect(keyEchoName(" ") == "Space")
    #expect(keyEchoName("é") == "é")
    #expect(keyEchoName("\u{1b}[>1;2c") == "unknown CSI ESC[>1;2c")
}

@Test func keyEchoSplitsBytesThatArriveTogetherIntoKeys() {
    #expect(KeyEcho.tokens(utf8Bytes("\u{1b}[Aa\r\u{1b}\u{1b}[B")) == [
        utf8Bytes("\u{1b}[A"), utf8Bytes("a"), utf8Bytes("\r"), utf8Bytes("\u{1b}\u{1b}[B"),
    ])
    // A keybind's text: one press, every key named.
    #expect(keyEchoName("\\\r") == "\\, Enter (CR)")
    #expect(keyEchoName("\u{1b}\u{1b}[B") == "Alt+Down (ESC prefix)")
}

@Test func keyEchoEscapesControlBytes() {
    #expect(KeyEcho.escaped([0x1b, 0x5b, 0x41]) == "ESC[A")
    #expect(KeyEcho.escaped([0x0d, 0x0a, 0x09, 0x00]) == "^M^J^I^@")
    #expect(KeyEcho.escaped([0x7f, 0x20]) == "^?␠")
    #expect(KeyEcho.escaped(utf8Bytes("é")) == "é")
    #expect(KeyEcho.escaped([0xff, 0x41]) == "\\xffA")
    #expect(KeyEcho.hex([0x1b, 0x0d]) == "1b 0d")
}

@Test func keyEchoCommandsAreQCtrlCAndTheDigits() {
    #expect(KeyEcho.command(for: utf8Bytes("q")) == .quit)
    #expect(KeyEcho.command(for: [0x03]) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[99;5u")) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[27;5;99~")) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("1")) == .mode(.legacy))
    #expect(KeyEcho.command(for: utf8Bytes("2")) == .mode(.kitty))
    #expect(KeyEcho.command(for: utf8Bytes("3")) == .mode(.modifyOtherKeys))
    #expect(KeyEcho.command(for: utf8Bytes("4")) == .mode(.claudeCode))
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[52u")) == .mode(.claudeCode))
    // Ghostty reports Caps Lock (64) and Num Lock (128) with every kitty key.
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[99;69u")) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[99;197u")) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[27;69;99~")) == .quit)
    #expect(KeyEcho.command(for: utf8Bytes("\u{1b}[113;65u")) == .quit)
    for other in ["Q", "5", "0", "q\r", "\u{1b}[113;2u", "\u{1b}[113;66u", "\r", "\u{1b}[27;2;13~", "\u{1b}[Z"] {
        #expect(KeyEcho.command(for: utf8Bytes(other)) == nil, "\(other.debugDescription)")
    }
}

@Test func keyEchoModesPopOnlyWhatTheyPushedThenWriteTheirRequestsAndTheFlagsQuery() {
    #expect(KeyEchoMode.legacy.request(popping: false) == "\u{1b}[>4m\u{1b}[?u")
    #expect(KeyEchoMode.legacy.request(popping: true) == "\u{1b}[<u\u{1b}[>4m\u{1b}[?u")
    #expect(KeyEchoMode.kitty.request(popping: false) == "\u{1b}[>4m\u{1b}[>5u\u{1b}[?u")
    #expect(KeyEchoMode.modifyOtherKeys.request(popping: false) == "\u{1b}[>4m\u{1b}[>4;2m\u{1b}[?u")
    #expect(KeyEchoMode.claudeCode.request(popping: true) == "\u{1b}[<u\u{1b}[>4m\u{1b}[>5u\u{1b}[>4;2m\u{1b}[?u")
    #expect(KeyEchoMode.allCases.filter(\.pushesKittyFlags) == [.kitty, .claudeCode])
}

@Test func keyEchoReadsTheKittyFlagsTheTerminalHadBeforeItStarted() {
    let answers = KeyEcho.startupAnswers(utf8Bytes("\u{1b}[?5u\u{1b}[?62;22c"))
    #expect(answers == KeyEcho.StartupAnswers(kittyFlags: 5, deviceAttributes: true))
    #expect(answers.summary == "kitty keyboard flags = 5")
    // Device attributes alone: no kitty keyboard protocol. Early keys are kept.
    let noKitty = KeyEcho.startupAnswers(utf8Bytes("a\u{1b}[?1;2c"))
    #expect(noKitty == KeyEcho.StartupAnswers(kittyFlags: nil, deviceAttributes: true, rest: utf8Bytes("a")))
    #expect(noKitty.summary == "no answer to CSI ? u (no kitty keyboard protocol)")
    // A partial answer is not the device attributes yet.
    let partial = KeyEcho.startupAnswers(utf8Bytes("\u{1b}[?0u\u{1b}[?6"))
    #expect(partial.kittyFlags == 0)
    #expect(!partial.deviceAttributes)
    #expect(KeyEcho.startupAnswers([]).summary == "no answer to CSI ? u or CSI c within 0.5 s")
}

@Test func keyEchoSaysWhereItRuns() {
    #expect(KeyEcho.place(["CHERRY_SESSION_ID": "abc", "INSIDE_CHERRY": "1"]) == "a Cherry persistent session (abc)")
    #expect(KeyEcho.place(["INSIDE_CHERRY": "1"]) == "a native Cherry tab")
    #expect(KeyEcho.place(["CHERRY_SESSION_ID": ""]) == "a terminal outside Cherry")
}

@Test func keyEchoGroupsBytesThatArriveWithinTheWindow() {
    var grouper = KeyEchoGrouper()
    #expect(grouper.add([0x1b], at: 10.000) == nil)
    #expect(grouper.add([0x5b, 0x5a], at: 10.004) == nil)
    #expect(grouper.add([0x61], at: 10.100) == [0x1b, 0x5b, 0x5a])
    #expect(grouper.flush() == [0x61])
    #expect(grouper.flush() == nil)
}

@Test func keyEchoLogLinesAreWhatTheDiagnosticsWindowReads() {
    let text = [
        KeyEchoLogRecord(
            event: "start", time: "t0", mode: "legacy", term: "xterm-ghostty", termProgram: "Ghostty",
            place: "a native Cherry tab", before: "kitty keyboard flags = 0"
        ).jsonLine(),
        KeyEchoLogRecord(event: "mode", time: "t1", mode: "kitty-5", escaped: "ESC[>5u").jsonLine(),
        KeyEchoLogRecord(event: "key", time: "t2", mode: "kitty-5", hex: "1b 5b 5a", escaped: "ESC[Z", name: "Shift+Tab (CSI Z)").jsonLine(),
        "not json\n",
        KeyEchoLogRecord(event: "start", time: "t3", mode: "legacy", place: "a terminal outside Cherry").jsonLine(),
        KeyEchoLogRecord(event: "key", time: "t4", mode: "legacy", hex: "0d", escaped: "^M", name: "Enter (CR)").jsonLine(),
    ].joined()
    // Every run's start stays, between its keys and the earlier run's.
    let log = KeyboardDiagnostics.keyLog(text)
    #expect(log.map(\.time) == ["t0", "t1", "t2", "t3", "t4"])
    #expect(log.map(\.line) == [
        "── run t0 in a native Cherry tab · TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=(unset) · before any change: kitty keyboard flags = 0",
        "── mode kitty-5: wrote ESC[>5u",
        "[kitty-5] Shift+Tab (CSI Z)   ESC[Z   1b 5b 5a",
        "── run t3 in a terminal outside Cherry · TERM=(unset) TERM_PROGRAM=(unset) TERM_PROGRAM_VERSION=(unset) · before any change: not asked",
        "[legacy] Enter (CR)   ^M   0d",
    ])
    #expect(KeyboardDiagnostics.keyLog(text, limit: 2).map(\.time) == ["t3", "t4"])
}

// MARK: - Config files

private struct TemporaryHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(relativePath))
    }

    /// What Cherry reads of this home's Ghostty files now.
    @MainActor
    func reading() -> UserGhosttyKeyboardConfig {
        TerminalSettings.ghosttyKeyboardConfig(home: url, environment: [:])
    }

    /// The window's files, as if Cherry read `atLaunch` at launch.
    @MainActor
    func configFiles(atLaunch: UserGhosttyKeyboardConfig?) -> [KeyboardDiagnostics.ConfigFile] {
        KeyboardDiagnostics.configFiles(
            defaultPaths: TerminalSettings.ghosttyDefaultConfigPaths(home: url, environment: [:]),
            atLaunch: atLaunch,
            now: reading(),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func describe(_ file: KeyboardDiagnostics.ConfigFile) -> [String] {
    file.lines.map { "\($0.text): \($0.state)" }
}

@MainActor
@Test func cherryReadsEveryGhosttyConfigFileAndSaysWhatItAppliesOfEachLine() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    let appSupport = "Library/Application Support/com.mitchellh.ghostty"
    try home.write(".config/ghostty/config", """
    theme = dark
    keybind = super+t=new_tab
    keybind = shift+enter=text:\\n
    """)
    // The Application Support file is read too, after it: its Shift+Enter
    // binding replaces the first file's.
    try home.write("\(appSupport)/config", """
    keybind = shift+enter=text:\\x1b\\r
    keybind = ctrl+e=text:secret\\r
    macos-option-as-alt = yes
    macos-option-as-alt = left
    """)
    let files = home.configFiles(atLaunch: home.reading())
    #expect(files.map(\.path) == TerminalSettings.ghosttyDefaultConfigPaths(home: home.url, environment: [:]).map(\.path))
    #expect(files.map(\.exists) == [true, false, true, false])
    #expect(files.map(\.readByCherry) == [true, false, true, false])
    #expect(files.map(\.readByCherryNext) == [true, false, true, false])
    #expect(!files.contains { $0.isIncluded || $0.changedSinceLaunch })
    #expect(files[0].state == "exists, read by Cherry")
    #expect(files[1].state == "missing")
    #expect(describe(files[0]) == [
        "keybind = super+t=new_tab: not applied",
        "keybind = shift+enter=text:\\n: not applied",
    ])
    #expect(describe(files[2]).count == 4)
    #expect(describe(files[2])[0] == "keybind = shift+enter=text:\\x1b\\r: applied")
    #expect(describe(files[2])[1] == "keybind = ctrl+e=text:***\\r: applied")
    #expect(files[2].lines[2].text == "macos-option-as-alt = yes")
    #expect(files[2].lines[2].state.hasPrefix("left out: Ghostty rejects it ("))
    #expect(!files[2].lines[2].isApplied)
    #expect(describe(files[2])[3] == "macos-option-as-alt = left: applied")
}

@MainActor
@Test func configChangesSinceLaunchApplyOnlyFromCherrysNextLaunch() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    let appSupport = "Library/Application Support/com.mitchellh.ghostty"
    try home.write("\(appSupport)/config", "keybind = shift+enter=text:\\n\n")
    try home.write(".config/ghostty/config.ghostty", "font-size = 13\n")
    let launch = home.reading()

    // Added, changed and removed since launch.
    try home.write(".config/ghostty/config", "theme = dark\n")
    try home.write("\(appSupport)/config", "keybind = shift+enter=text:\\x1b\\r\n")
    try home.delete(".config/ghostty/config.ghostty")
    let files = home.configFiles(atLaunch: launch)
    #expect(files.map(\.readByCherry) == [false, true, true, false])
    #expect(files.map(\.readByCherryNext) == [true, false, true, false])
    #expect(files[0].state == "exists, read by Cherry from its next launch (changed since launch)")
    #expect(files[1].state == "missing, read by Cherry at launch, not from its next launch")
    #expect(files[2].state == "exists, read by Cherry, changed since launch (these lines apply from its next launch)")
    #expect(describe(files[2]) == ["keybind = shift+enter=text:\\x1b\\r: applied"])

    // Without a reading at launch (a test's), none was read then.
    #expect(!home.configFiles(atLaunch: nil).contains { $0.readByCherry })
}

@MainActor
@Test func filesThatConfigFileLinesNameAreListedAfterGhosttysOwn() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(".config/ghostty/config.ghostty", "config-file = keys.conf\nconfig-file = ?missing.conf\n")
    try home.write(".config/ghostty/keys.conf", "keybind = shift+enter=text:\\n\n")
    let files = home.configFiles(atLaunch: home.reading())
    #expect(files.count == 5)
    #expect(files[1].state == "exists, read by Cherry")
    #expect(files[1].lines.isEmpty)
    #expect(files[4].path == home.url.appendingPathComponent(".config/ghostty/keys.conf").path)
    #expect(files[4].state == "exists, named by a config-file line, read by Cherry")
    #expect(describe(files[4]) == ["keybind = shift+enter=text:\\n: applied"])
}

@Test func textKeybindsWordsAreMaskedButTheirEscapesStay() {
    for kept in [
        "keybind = shift+enter=text:\\x1b\\r",
        "keybind = shift+enter=text:\\\\\\n",
        "keybind = ctrl+k=text:\\x1b[13;2u",
        "keybind = ctrl+k=text:ok\\x1bOA",
        "keybind = super+t=new_tab",
        "keybind = shift+tab=csi:Z",
    ] {
        #expect(KeyboardDiagnostics.masked(kept) == kept)
    }
    #expect(KeyboardDiagnostics.masked("keybind = ctrl+e=text:hello world\\n") == "keybind = ctrl+e=text:*** ***\\n")
    #expect(KeyboardDiagnostics.masked("keybind = ctrl+e=text:\\u{1b}secret") == "keybind = ctrl+e=text:\\u{1b}***")
    #expect(KeyboardDiagnostics.masked("keybind = a=text:pässword") == "keybind = a=text:***")
}

// MARK: - Report

@Test func keyTestCommandQuotesTheHelperAndTheLog() {
    #expect(KeyboardDiagnostics.keyTestCommand(
        helper: "/Applications/Cherry.app/Contents/MacOS/CherryMCP",
        log: "/Users/me/Library/Caches/Cherry/Keyboard Diagnostics/key-echo.jsonl"
    ) == "'/Applications/Cherry.app/Contents/MacOS/CherryMCP' --key-echo --log '/Users/me/Library/Caches/Cherry/Keyboard Diagnostics/key-echo.jsonl'")
}

@Test func newTabsGetGhosttysTerm() {
    let native = KeyboardDiagnostics.newTabEnvironment(persistent: false, resources: nil, processEnvironment: ["TERM": "dumb"])
    #expect(native["TERM"] == "xterm-ghostty")
    #expect(native["TERM_PROGRAM"] == "Ghostty")
    // Without staged resources a persistent tab falls back, as Ghostty does.
    let persistent = KeyboardDiagnostics.newTabEnvironment(persistent: true, resources: nil, processEnvironment: ["TERM": "dumb"])
    #expect(persistent["TERM"] == "xterm-256color")
    #expect(persistent["TERM_PROGRAM"] == "Ghostty")
}

@Test func tabLinesSayWhereKeysGoAndWhatTheProgramAskedFor() {
    let id = UUID()
    var tab = KeyboardDiagnostics.Tab(id: id, title: "claude", project: "cherry", isPersistent: true, adapter: HostedAdapterLiveStatus())
    #expect(tab.lines == [
        "“claude” in cherry: persistent session, its adapter is attached",
        "  keys: Ghostty's surface encodes them, with Cherry's keybinds, for the adapter",
        "  modes: the session host reports none now",
    ])
    tab.host = .init(program: "claude", kittyFlags: 5, modifyOtherKeys: true, applicationCursorKeys: nil)
    tab.adapter = HostedAdapterLiveStatus(reconnecting: true)
    tab.inputGoesThroughHost = true
    #expect(tab.lines == [
        "“claude” in cherry: persistent session, its adapter reconnects",
        "  keys: Cherry types them through the session host (HostRoutedKeyEncoder; keybinds do not apply)",
        "  modes claude asked for, as the session host reports them: kitty flags 5, modifyOtherKeys 2, application cursor keys not reported",
    ])
    let native = KeyboardDiagnostics.Tab(id: id, title: "Key Test", project: "cherry", fallbackReason: "The host did not answer.")
    #expect(native.lines.first == "“Key Test” in cherry: native tab, not a persistent session: The host did not answer.")
    #expect(KeyboardDiagnostics.Tab(id: id, title: "zsh", project: "cherry", isRunning: false).lines == ["“zsh” in cherry: not running"])
}

@Test func reportTextHasEverySection() {
    var report = KeyboardDiagnostics.Report()
    report.version = "2026.10.13.1"
    report.build = "20261013120000.abc1234"
    report.macOS = "Version 26.1 (Build 25B78)"
    report.inputSource = "com.apple.keylayout.US"
    report.keyboardLayout = "com.apple.keylayout.US"
    report.persistentSessions = true
    report.lastSessionLaunchFailure = "The session host did not answer."
    report.persistentTab = "TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=1.3.0"
    report.nativeTab = "TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=1.3.0"
    report.homeDirectory = "/Users/me"
    report.configFiles = [
        .init(path: "/Users/me/.config/ghostty/config", exists: true, isIncluded: false, readByCherry: true,
              readByCherryNext: true, lines: [.init(text: "keybind = shift+enter=text:\\n", isApplied: false)]),
        .init(path: "/Users/me/.config/ghostty/config.ghostty", exists: false, isIncluded: false, readByCherry: false,
              readByCherryNext: false, lines: []),
        .init(path: "/Users/me/Library/Application Support/com.mitchellh.ghostty/config", exists: true, isIncluded: false,
              readByCherry: true, readByCherryNext: true, lines: [
                  .init(text: "keybind = shift+enter=text:\\n", isApplied: true),
                  .init(text: "macos-option-as-alt = yes", isApplied: false, rejection: "invalid value"),
              ]),
        .init(path: "/Users/me/.config/ghostty/keys.conf", exists: true, isIncluded: true, readByCherry: true,
              readByCherryNext: true, lines: []),
    ]
    report.appliedKeyboardLines = ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"]
    let keyTest = KeyboardDiagnostics.Tab(id: UUID(), title: "Key Test", project: "cherry")
    report.keyTestTab = keyTest
    report.frontTab = keyTest
    report.keyLog = KeyboardDiagnostics.keyLog(
        KeyEchoLogRecord(event: "start", time: "t0", mode: "legacy", term: "xterm-ghostty", termProgram: "Ghostty",
                         place: "a native Cherry tab", before: "kitty keyboard flags = 0").jsonLine()
            + KeyEchoLogRecord(event: "key", time: "t1", mode: "legacy", hex: "1b 5b 5a", escaped: "ESC[Z", name: "Shift+Tab (CSI Z)").jsonLine()
    )
    #expect(report.text == """
    Cherry keyboard diagnostics
    Cherry 2026.10.13.1 (20261013120000.abc1234)
    macOS Version 26.1 (Build 25B78)
    Input source: com.apple.keylayout.US
    Keyboard layout: com.apple.keylayout.US
    Persistent sessions: on
    Last session that could not start: The session host did not answer.
    New persistent tab: TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=1.3.0
    New native tab: TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=1.3.0

    Ghostty config files, in Ghostty's order:
      ~/.config/ghostty/config: exists, read by Cherry
        keybind = shift+enter=text:\\n   (not applied)
      ~/.config/ghostty/config.ghostty: missing
      ~/Library/Application Support/com.mitchellh.ghostty/config: exists, read by Cherry
        keybind = shift+enter=text:\\n   (applied)
        macos-option-as-alt = yes   (left out: Ghostty rejects it (invalid value))
      ~/.config/ghostty/keys.conf: exists, named by a config-file line, read by Cherry
    Applied to Cherry's terminals (read once, at launch):
      keybind = shift+tab=csi:Z
      macos-option-as-alt = true

    Front tab: the key test tab
    Key test tab: “Key Test” in cherry: native tab
      keys: Ghostty's surface encodes them, with Cherry's keybinds
      modes: Ghostty's surface keeps them; Cherry cannot read a native tab's
    Key test log:
      ── run t0 in a native Cherry tab · TERM=xterm-ghostty TERM_PROGRAM=Ghostty TERM_PROGRAM_VERSION=(unset) · before any change: kitty keyboard flags = 0
      [legacy] Shift+Tab (CSI Z)   ESC[Z   1b 5b 5a

    """)

    report.configFiles = []
    report.persistentTab = nil
    report.persistentSessionsUnavailable = "Another copy of Cherry is running."
    report.frontTab = nil
    report.keyTestTab = nil
    report.keyLog = []
    #expect(report.text.contains("Ghostty config files, in Ghostty's order:\n  Cherry reads none of them.\n"))
    #expect(report.text.contains("Persistent sessions: on, but new tabs run natively: Another copy of Cherry is running.\n"))
    #expect(report.text.contains("Front tab: no project window on This Mac\nKey test tab: none open\nKey test log:\n  No keys yet.\n"))
    #expect(!report.text.contains("New persistent tab"))
}
