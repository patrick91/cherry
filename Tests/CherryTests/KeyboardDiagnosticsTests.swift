// Settings › Terminal's keyboard report (KeyboardDiagnostics.swift).

import Foundation
import Testing
@testable import Cherry

// MARK: - Config files

/// A home directory of the test's own with Ghostty config files in it,
/// never the real one (also SettingsWindowTerminalTests').
struct TemporaryHome {
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
    report.frontTab = KeyboardDiagnostics.Tab(id: UUID(), title: "zsh", project: "cherry")
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

    Front tab: “zsh” in cherry: native tab
      keys: Ghostty's surface encodes them, with Cherry's keybinds
      modes: Ghostty's surface keeps them; Cherry cannot read a native tab's

    """)

    report.configFiles = []
    report.persistentTab = nil
    report.persistentSessionsUnavailable = "Another copy of Cherry is running."
    report.frontTab = nil
    #expect(report.text.contains("Ghostty config files, in Ghostty's order:\n  Cherry reads none of them.\n"))
    #expect(report.text.contains("Persistent sessions: on, but new tabs run natively: Another copy of Cherry is running.\n"))
    #expect(report.text.hasSuffix("Front tab: no project window on This Mac\n"))
    #expect(!report.text.contains("New persistent tab"))
}
