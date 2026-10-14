import Foundation
import GhosttyTerminal
import os
import Testing
@testable import Cherry

private func parsed(_ s: String) -> [String] {
    TerminalSettings.parseUserGhosttyKeyboardConfig(s).map { "\($0.0) = \($0.1)" }
}

@Test func keyboardConfigKeepsShiftEnterAndOptionAsAltFromUserConfig() {
    // The exact lines from a real ghostty config.
    let config = """
    keybind = super+t=new_tab
    keybind = super+enter=toggle_split_zoom
    keybind = shift+enter=text:\\n
    macos-option-as-alt = left
    """
    #expect(parsed(config) == [
        "keybind = shift+enter=text:\\n", // input-producing -> kept
        "macos-option-as-alt = left",     // user's value preserved
        "keybind = shift+tab=csi:Z",      // injected default
    ])
}

@Test func keyboardConfigDropsAppActionKeybinds() {
    let config = """
    keybind = super+t=new_tab
    keybind = cmd+w=close_surface
    keybind = ctrl+a=text:\\x01
    """
    // app actions dropped, text: kept, option-as-alt defaulted on
    #expect(parsed(config) == [
        "keybind = ctrl+a=text:\\x01",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}

@Test func keyboardConfigDefaultsOptionAsAltWhenUnset() {
    #expect(parsed("") == ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
    #expect(parsed("font-size = 14\n# a comment") == ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
}

@Test func keyboardConfigDefaultsShiftTabButUserCanOverride() {
    // Default shift+tab is injected when the user has none.
    #expect(parsed("keybind = ctrl+a=text:\\x01").contains("keybind = shift+tab=csi:Z"))
    // A user's own shift+tab binding wins (we don't inject the default).
    let withUserShiftTab = parsed("keybind = shift+tab=text:custom")
    #expect(withUserShiftTab.contains("keybind = shift+tab=text:custom"))
    #expect(!withUserShiftTab.contains("keybind = shift+tab=csi:Z"))
}

@Test func keyboardConfigIgnoresCommentsAndBlankLines() {
    let config = """
    # keyboard
    keybind = shift+enter=text:\\n

    macos-option-as-alt = right
    """
    #expect(parsed(config) == [
        "keybind = shift+enter=text:\\n",
        "macos-option-as-alt = right",
        "keybind = shift+tab=csi:Z",
    ])
}

@Test func keyboardConfigKeepsCsiAndEscKeybinds() {
    let config = """
    keybind = f1=csi:11~
    keybind = alt+left=esc:b
    keybind = home=scroll_to_top
    """
    #expect(parsed(config) == [
        "keybind = f1=csi:11~",
        "keybind = alt+left=esc:b",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}

@Test func keyboardConfigLaterLinesWinAsInGhostty() {
    // A later binding of the same trigger replaces an earlier one, whatever
    // its action: an app action or `unbind` leaves no input binding.
    #expect(parsed("""
    keybind = shift+enter=text:\\n
    keybind = shift+enter=new_split:right
    keybind = ctrl+a=text:\\x01
    keybind = ctrl+a=unbind
    keybind = alt+left=esc:b
    keybind = opt+left=csi:1;3D
    """) == ["keybind = opt+left=csi:1;3D", "keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
    // `clear` drops every earlier binding; the later option-as-alt line is
    // the one Ghostty and Cherry's host-routed keys use.
    #expect(parsed("""
    keybind = shift+enter=text:\\n
    macos-option-as-alt = false
    keybind = clear
    keybind = ctrl+j=text:\\n
    macos-option-as-alt = left
    """) == [
        "macos-option-as-alt = false",
        "keybind = ctrl+j=text:\\n",
        "macos-option-as-alt = left",
        "keybind = shift+tab=csi:Z",
    ])
}

@Test func keyboardConfigShiftTabDefaultYieldsToAnyBindingOfShiftTab() {
    for line in [
        "keybind = shift+tab=unbind",
        "keybind = shift+tab=previous_tab",
        "keybind = unconsumed:shift+tab=text:x",
        "keybind = performable:shift+Tab=text:x",
        "keybind = tab+shift=csi:Z",
        // A sequence Shift+Tab starts: Cherry's binding, after it, would
        // replace it.
        "keybind = shift+tab>a=text:x",
    ] {
        #expect(!parsed(line).contains("keybind = shift+tab=csi:Z"), "\(line)")
    }
    // A binding that `clear` dropped binds nothing.
    #expect(parsed("keybind = shift+tab=text:x\nkeybind = clear").contains("keybind = shift+tab=csi:Z"))
}

@Test func keyboardConfigTellsTriggersApartAsGhosttyDoes() {
    // Each pair is one trigger to Ghostty (`ghostty_config_trigger` finds
    // no binding of the first after the second): Ghostty 1.1's names, W3C
    // codes, a character's case, modifier aliases and order, flags.
    for (first, second) in [
        ("ctrl+left", "ctrl+arrow_left"),
        ("ctrl+ArrowRight", "ctrl+arrow_right"),
        ("ctrl+A", "ctrl+a"),
        ("kp_enter", "numpad_enter"),
        ("F1", "f1"),
        ("one", "1"),
        ("physical:one", "digit_1"),
        ("ctrl++", "control++"),
        ("ctrl+plus", "ctrl++"),
        ("ctrl+apostrophe", "ctrl+'"),
        ("ctrl+physical:apostrophe", "ctrl+quote"),
        ("ctrl+Digit2", "ctrl+digit_2"),
        ("BackSpace", "backspace"),
        ("Numpad1", "numpad_1"),
        ("ctrl+physical:grave_accent", "ctrl+backquote"),
        ("left_alt", "alt_left"),
        ("cmd+shift+a", "shift+super+a"),
        ("ctrl+tab", "global:ctrl+tab"),
        ("ctrl+É", "ctrl+é"),
    ] {
        #expect(parsed("keybind = \(first)=text:x\nkeybind = \(second)=new_tab") == [
            "keybind = shift+tab=csi:Z", "macos-option-as-alt = true",
        ], "\(first), \(second)")
    }
    // And these are two: a physical key and the character it types, a
    // digit and a digit key, a lock modifier.
    for (first, second) in [("ctrl+key_b", "ctrl+b"), ("physical:one", "1"), ("ctrl+caps_lock+a", "ctrl+a")] {
        #expect(parsed("keybind = \(first)=text:x\nkeybind = \(second)=new_tab").first
            == "keybind = \(first)=text:x", "\(first), \(second)")
    }
}

@Test func keyboardConfigFollowsSequencesAsGhosttysBindingSet() {
    #expect(parsed("""
    keybind = ctrl+a>n=text:x
    keybind = ctrl+a=new_tab
    keybind = ctrl+b=text:y
    keybind = ctrl+b>n=new_tab
    keybind = ctrl+c>n=text:z
    keybind = ctrl+c>m=new_tab
    keybind = ctrl+d=text:w
    keybind = ctrl+d>n=unbind
    keybind = ctrl+e>n=text:v
    keybind = ctrl+e=unbind
    """) == [
        // A binding replaces the leaf its sequence goes through and the
        // sequences its trigger starts; one beside it stays.
        "keybind = ctrl+c>n=text:z",
        // Unbinding a sequence leaves the leaf it went through.
        "keybind = ctrl+d=text:w",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}

@Test func keyboardConfigEmptyValuesRestoreTheDefaults() {
    // `keybind =` restores Ghostty's default bindings, so none of the
    // user's is left, and `macos-option-as-alt =` its default (Cherry's
    // `true`).
    #expect(parsed("""
    keybind = shift+enter=text:\\n
    keybind = shift+tab=text:x
    keybind = ctrl+a=text:a
    keybind = chain=text:b
    macos-option-as-alt = left
    keybind =
    keybind = chain=text:c
    macos-option-as-alt =
    """) == ["keybind = shift+tab=csi:Z", "macos-option-as-alt = true"])
}

@Test func keyboardConfigReadsLinesAsGhosttyDoes() {
    // Quoted values, CRLF line ends, and a chain kept with its binding (but
    // not with one that is not forwarded).
    #expect(parsed("keybind = \"shift+enter=text:\\n\"\r\nmacos-option-as-alt = \"left\"\r\n") == [
        "keybind = shift+enter=text:\\n",
        "macos-option-as-alt = left",
        "keybind = shift+tab=csi:Z",
    ])
    #expect(parsed("""
    keybind = ctrl+a=text:a
    keybind = chain=text:b
    keybind = super+t=new_tab
    keybind = chain=text:c
    keybind = ctrl+==text:d
    """) == [
        "keybind = ctrl+a=text:a",
        "keybind = chain=text:b",
        "keybind = ctrl+==text:d",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])
}

/// A home directory of the test's own, never the real one.
private func temporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("GhosttyConfigHome-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func write(_ text: String, to path: String, in home: URL) throws {
    let file = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

@Test func ghosttyDefaultConfigPathsAreGhosttysInItsOrder() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let appSupport = "/Users/someone/Library/Application Support/com.mitchellh.ghostty"
    for environment in [[:], ["XDG_CONFIG_HOME": ""]] {
        #expect(TerminalSettings.ghosttyDefaultConfigPaths(home: home, environment: environment).map(\.path) == [
            "/Users/someone/.config/ghostty/config",
            "/Users/someone/.config/ghostty/config.ghostty",
            "\(appSupport)/config",
            "\(appSupport)/config.ghostty",
        ])
    }
    #expect(TerminalSettings.ghosttyDefaultConfigPaths(
        home: home, environment: ["XDG_CONFIG_HOME": "/elsewhere/config"]
    ).map(\.path) == [
        "/elsewhere/config/ghostty/config",
        "/elsewhere/config/ghostty/config.ghostty",
        "\(appSupport)/config",
        "\(appSupport)/config.ghostty",
    ])
}

@Test func ghosttyConfigFilesAreAllReadInGhosttysOrder() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let appSupport = "Library/Application Support/com.mitchellh.ghostty"
    // A ~/.config/ghostty/config with no keybinds no longer hides the
    // Application Support file's.
    try write("font-size = 14\n", to: ".config/ghostty/config", in: home)
    try write("keybind = shift+enter=text:\\n\n", to: "\(appSupport)/config", in: home)
    let contents = TerminalSettings.ghosttyConfigFileContents(home: home, environment: [:]).map(\.contents)
    #expect(contents == ["font-size = 14\n", "keybind = shift+enter=text:\\n\n"])
    #expect(TerminalSettings.parseUserGhosttyKeyboardConfig(contents.joined(separator: "\n")).map { "\($0.0) = \($0.1)" } == [
        "keybind = shift+enter=text:\\n",
        "keybind = shift+tab=csi:Z",
        "macos-option-as-alt = true",
    ])

    // All four, in Ghostty's order, a later line overriding an earlier one.
    try write("keybind = shift+enter=text:2\n", to: ".config/ghostty/config.ghostty", in: home)
    try write("\u{FEFF}keybind = shift+enter=text:4\n", to: "\(appSupport)/config.ghostty", in: home)
    let all = TerminalSettings.ghosttyConfigFileContents(home: home, environment: [:]).map(\.contents)
    #expect(all == [
        "font-size = 14\n", "keybind = shift+enter=text:2\n", "keybind = shift+enter=text:\\n\n",
        "keybind = shift+enter=text:4\n",
    ])
    #expect(TerminalSettings.parseUserGhosttyKeyboardConfig(all.joined(separator: "\n")).first.map { "\($0.0) = \($0.1)" }
        == "keybind = shift+enter=text:4")

    // XDG_CONFIG_HOME moves the first two.
    try write("keybind = shift+enter=text:xdg\n", to: "xdg/ghostty/config", in: home)
    let xdg = home.appendingPathComponent("xdg").path
    #expect(TerminalSettings.ghosttyConfigFileContents(home: home, environment: ["XDG_CONFIG_HOME": xdg]).map(\.contents) == [
        "keybind = shift+enter=text:xdg\n", "keybind = shift+enter=text:\\n\n", "keybind = shift+enter=text:4\n",
    ])
}

@Test func ghosttyConfigFilesFollowConfigFileLinesAfterTheDefaultFiles() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let appSupport = "Library/Application Support/com.mitchellh.ghostty"
    try write("""
    config-file = keys/more
    config-file = ?missing
    a = 1
    """, to: ".config/ghostty/config", in: home)
    try write("""
    config-file = "~/home-file"
    config-file = \(home.appendingPathComponent("absolute").path)
    b = 2
    """, to: "\(appSupport)/config", in: home)
    // Relative to the file that names it; names a file of its own, and
    // itself (a cycle, read once).
    try write("config-file = nested\nconfig-file = more\nc = 3\n", to: ".config/ghostty/keys/more", in: home)
    try write("d = 4\n", to: ".config/ghostty/keys/nested", in: home)
    try write("e = 5\n", to: "home-file", in: home)
    try write("f = 6\n", to: "absolute", in: home)
    let values = TerminalSettings.ghosttyConfigFileContents(home: home, environment: [:])
        .flatMap { TerminalSettings.ghosttyConfigLines($0.contents) }
        .filter { $0.key != "config-file" }
        .map { "\($0.key)=\($0.value)" }
    #expect(values == ["a=1", "b=2", "c=3", "e=5", "f=6", "d=4"])

    // An empty config-file empties the list so far.
    try write("config-file =\nb = 2\n", to: "\(appSupport)/config", in: home)
    let cleared = TerminalSettings.ghosttyConfigFileContents(home: home, environment: [:])
        .flatMap { TerminalSettings.ghosttyConfigLines($0.contents) }
        .filter { $0.key != "config-file" }
        .map { "\($0.key)=\($0.value)" }
    #expect(cleared == ["a=1", "b=2"])
}

@Test func ghosttyConfigFilesAreReadAsGhosttyReadsThem() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let ghostty = home.appendingPathComponent(".config/ghostty")
    // A line that is not UTF-8 is left out, not the file (nor the file it
    // names after it).
    try FileManager.default.createDirectory(at: ghostty, withIntermediateDirectories: true)
    var bytes = Data("# caf\u{E9}\nkeybind = ctrl+j=text:j\n".utf8)
    bytes.append(contentsOf: [0x23, 0x20, 0xE9, 0x0A]) // "# é" in Latin-1
    bytes.append(Data("keybind = ctrl+k=text:\u{E9}\nconfig-file = more\n".utf8))
    bytes.append(contentsOf: Array("keybind = ctrl+l=text:".utf8) + [0xE9, 0x0A])
    try bytes.write(to: ghostty.appendingPathComponent("config"))
    try write("keybind = ctrl+m=text:m\n", to: ".config/ghostty/more", in: home)
    // A link that loops (`loop/config` is `config`) is followed once; a
    // FIFO is never read (reading it would wait for a writer).
    try FileManager.default.createSymbolicLink(
        at: ghostty.appendingPathComponent("loop"), withDestinationURL: ghostty
    )
    try write("config-file = loop/more\nconfig-file = loop/loop/more\nconfig-file = ?fifo\n", to: ".config/ghostty/config.ghostty", in: home)
    #expect(mkfifo(ghostty.appendingPathComponent("fifo").path, 0o600) == 0)
    let values = TerminalSettings.ghosttyConfigFileContents(home: home, environment: [:])
        .flatMap { TerminalSettings.ghosttyConfigLines($0.contents) }
        .filter { $0.key == "keybind" }
        .map(\.value)
    #expect(values == ["ctrl+j=text:j", "ctrl+k=text:\u{E9}", "ctrl+m=text:m"])

    // XDG_CONFIG_HOME counts only as an absolute path.
    try write("keybind = ctrl+r=text:r\n", to: "relative/ghostty/config", in: home)
    #expect(TerminalSettings.ghosttyDefaultConfigPaths(home: home, environment: ["XDG_CONFIG_HOME": "relative"])
        == TerminalSettings.ghosttyDefaultConfigPaths(home: home, environment: [:]))
}

@MainActor
@Test func ghosttyConfigLinesGhosttyRejectsAreLeftOut() throws {
    // The embedded Ghostty's verdict: a configuration with any of these
    // lines fails to load as a whole.
    let lines = [
        ("keybind", "shift+enter=text:\\n"),
        ("keybind", "shift+enter = text:\\n"),
        ("keybind", "Shift+Tab=text:x"),
        ("keybind", "Tab+Shift=csi:Z"),
        ("keybind", "tab+shift=csi:Z"),
        ("macos-option-as-alt", "yes"),
        ("macos-option-as-alt", "left"),
        ("keybind", "ctrl+ArrowLeft=text:x"),
    ]
    let rejected = TerminalController.rejectedLines(of: TerminalConfiguration { builder in
        for (key, value) in lines {
            builder.withCustom(key, value)
        }
    })
    #expect(Set(rejected.keys) == [1, 2, 3, 5])
    #expect(rejected[5]?.contains("invalid value") == true)

    // Read from the files, they are left out and logged; the rest, and
    // Cherry's defaults, are the surface's configuration.
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try write("""
    keybind = shift+enter = text:\\n
    keybind = ctrl+j=text:\\n
    keybind = Shift+Tab=text:x
    macos-option-as-alt = yes
    """, to: "Library/Application Support/com.mitchellh.ghostty/config.ghostty", in: home)
    let notices = OSAllocatedUnfairLock<[String]>(initialState: [])
    let token = SessionLog.observe { entry in notices.withLock { $0.append(entry.message) } }
    defer { SessionLog.remove(token) }
    let configuration = TerminalSettings.ghosttyKeyboardConfig(home: home, environment: [:])
    #expect(configuration.surfaceLines.map { "\($0.0) = \($0.1)" } == [
        "keybind = ctrl+j=text:\\n", "keybind = shift+tab=csi:Z", "macos-option-as-alt = true",
    ])
    #expect(configuration.files.map(\.lastPathComponent) == ["config.ghostty"])
    #expect(configuration.lines.map { $0.rejection != nil } == [true, false, true, true])
    #expect(configuration.lines.map(\.isApplied) == [false, true, false, false])
    let logged = notices.withLock { $0 }.filter { $0.contains("Ghostty rejects") }
    #expect(logged.count == 3)
    #expect(logged.first?.contains("keybind = shift+enter = text:\\n") == true)
    #expect(TerminalController.rejectedLines(of: TerminalSettings.ghosttyConfiguration(
        fontSize: 13, cursorBlink: true, minimumContrast: 1
    )).isEmpty)
}
