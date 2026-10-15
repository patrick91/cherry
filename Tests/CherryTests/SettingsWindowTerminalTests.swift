import Combine
import Foundation
import Testing
@testable import Cherry

// Settings › Terminal (TerminalSettingsPage.swift, GhosttyConfigSettings.swift):
// what it says of the user's Ghostty config (the Option key, the key
// bindings, the files and the lines left out), Copy Report's report, its
// page reset and its search rows. Readings come from a temporary home
// (`TemporaryHome`), never the real one; nothing here reads
// `TerminalSettings.nativeUserKeyboardConfigReading` or the app's Sources.

private let configPath = ".config/ghostty/config"
private let appSupportPath = "Library/Application Support/com.mitchellh.ghostty/config"

// MARK: - Option key

@MainActor
@Test func settingsWindowTerminalOptionKeyIsCherrysDefaultWithoutALine() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "keybind = ctrl+a=text:a\n")
    let reading = home.reading()

    let optionKey = GhosttyConfigSettings.optionKey(launch: reading, now: reading)
    #expect(optionKey.value == .both)
    #expect(optionKey.value.settingsLabel == "Option is Alt")
    #expect(optionKey.line == nil)
    #expect(optionKey.leftOut == nil)
    #expect(optionKey.file == nil)
    #expect(!optionKey.changedSinceLaunch)
    #expect(optionKey.help(homeDirectory: home.url.path) == GhosttyConfigSettings.optionKeyHelp)
    #expect(optionKey.leftOutNote == nil)
    #expect(optionKey.searchValue == "Option is Alt")
    #expect(optionKey.accessibilityValue == "Option is Alt")
    // No reading (tests, before Cherry read the files): the same.
    #expect(GhosttyConfigSettings.optionKey(launch: nil, now: nil).value == .both)
}

@MainActor
@Test func settingsWindowTerminalOptionKeyNamesTheLineThatSetsIt() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "macos-option-as-alt = right\n")
    try home.write(appSupportPath, "# keys\n\nmacos-option-as-alt = left\n")
    let reading = home.reading()

    let optionKey = GhosttyConfigSettings.optionKey(launch: reading, now: reading)
    #expect(optionKey.value == .left)
    #expect(optionKey.value.settingsLabel == "Left Option is Alt")
    #expect(optionKey.line?.line == 3)
    #expect(optionKey.file == home.url.appendingPathComponent(appSupportPath))
    #expect(optionKey.help(homeDirectory: home.url.path) == """
    Set by your Ghostty config: ~/Library/Application Support/com.mitchellh.ghostty/config, line 3.
    \(GhosttyConfigSettings.optionKeyHelp)
    """)
    #expect(optionKey.searchValue == "set by your Ghostty config")
    #expect(optionKey.accessibilityValue == "Left Option is Alt, set by your Ghostty config")
    #expect(GhosttyConfigSettings.optionKeyChoices.map(\.settingsLabel) == [
        "Option is Alt", "Option types characters", "Left Option is Alt", "Right Option is Alt",
    ])
    // An empty value goes back to Cherry's default.
    try home.write(appSupportPath, "macos-option-as-alt = left\nmacos-option-as-alt =\n")
    #expect(GhosttyConfigSettings.optionKey(launch: home.reading(), now: nil).line == nil)
}

@MainActor
@Test func settingsWindowTerminalOptionKeySaysWhenGhosttyRejectsItsLine() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    // The line before the rejected one is used.
    try home.write(configPath, "macos-option-as-alt = left\nmacos-option-as-alt = yes\n")
    let rejected = GhosttyConfigSettings.optionKey(launch: home.reading(), now: nil)
    #expect(rejected.value == .left)
    #expect(rejected.line?.line == 1)
    #expect(rejected.leftOut?.line == 2)
    let note = try #require(rejected.leftOutNote)
    #expect(note.hasPrefix("Your Ghostty config's line is left out: "))
    #expect(note.contains("invalid value"))
    #expect(!note.contains("macos-option-as-alt"))

    // Alone, Cherry's default is used, and Edit opens its file.
    try home.write(configPath, "macos-option-as-alt = yes\n")
    let alone = GhosttyConfigSettings.optionKey(launch: home.reading(), now: nil)
    #expect(alone.value == .both)
    #expect(alone.line == nil)
    #expect(alone.file == home.url.appendingPathComponent(configPath))
    #expect(alone.leftOutNote != nil)
    #expect(alone.help(homeDirectory: home.url.path) == GhosttyConfigSettings.optionKeyHelp)
}

@MainActor
@Test func settingsWindowTerminalOptionKeySaysWhenItsLinesChangedSinceLaunch() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "macos-option-as-alt = left\n")
    let launch = home.reading()

    // A line moved down is the same line.
    try home.write(configPath, "\n# moved\nmacos-option-as-alt = left\n")
    #expect(!GhosttyConfigSettings.optionKey(launch: launch, now: home.reading()).changedSinceLaunch)

    // Another value: the row still shows what Cherry uses until it quits.
    try home.write(configPath, "macos-option-as-alt = right\n")
    let changed = GhosttyConfigSettings.optionKey(launch: launch, now: home.reading())
    #expect(changed.changedSinceLaunch)
    #expect(changed.value == .left)

    // Removed, or added where there was none.
    try home.delete(configPath)
    #expect(GhosttyConfigSettings.optionKey(launch: launch, now: home.reading()).changedSinceLaunch)
    try home.write(appSupportPath, "macos-option-as-alt = false\n")
    #expect(GhosttyConfigSettings.optionKey(launch: UserGhosttyKeyboardConfig(), now: home.reading()).changedSinceLaunch)
}

// MARK: - Key bindings

@MainActor
@Test func settingsWindowTerminalCountsTheBindingsCherryAppliesLeavesAndLeavesOut() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, """
    keybind = shift+enter=text:\\n
    keybind = shift+enter=text:\\x1b\\r
    keybind = chain=text:x
    keybind = super+t=new_tab
    keybind = shift+enter = text:\\n
    keybind = ctrl+j=text:\\n
    """)
    try home.write(appSupportPath, "keybind = clear\nkeybind =\nkeybind = ctrl+k=text:k\nmacos-option-as-alt = left\n")
    let reading = home.reading()

    // `clear`, an empty value and `chain=` lines are not bindings of their
    // own, and option-as-alt is not one.
    #expect(GhosttyConfigSettings.bindingLines(reading).map(\.value) == [
        "shift+enter=text:\\n", "shift+enter=text:\\x1b\\r", "super+t=new_tab", "shift+enter = text:\\n",
        "ctrl+j=text:\\n", "ctrl+k=text:k",
    ])
    // `clear` drops every binding of the first file.
    let counts = GhosttyConfigSettings.bindingCounts(reading)
    #expect(counts == GhosttyConfigSettings.BindingCounts(applied: 1, notApplied: 4, leftOut: 1))
    #expect(counts.text == "1 applied · 4 not applied · 1 left out")
    #expect(GhosttyConfigSettings.bindingCounts(nil).text == "None")
    #expect(GhosttyConfigSettings.BindingCounts(applied: 2, notApplied: 1, leftOut: 1).text == "2 applied · 1 not applied · 1 left out")
}

@MainActor
@Test func settingsWindowTerminalBindingsBadgeNamesTheirFilesAndOnlyOpensOne() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    var opened: [URL] = []
    var revealed: [[URL]] = []
    let actions = SettingsActions(revealInFinder: { revealed.append($0) }, openTextFile: { opened.append($0) })
    #expect(GhosttyConfigSettings.bindingsSource(home.reading(), homeDirectory: home.url.path, actions: actions) == nil)

    try home.write(configPath, "keybind = ctrl+a=text:a\nkeybind = ctrl+b=text:b\n")
    let one = try #require(GhosttyConfigSettings.bindingsSource(home.reading(), homeDirectory: home.url.path, actions: actions))
    #expect(one.badgeText == "Ghostty config")
    #expect(one.accessibilityLabel == "Source: Ghostty config.")
    #expect(one.rowReset == nil)
    #expect(one.lines == [SettingsSourceState.Line("Ghostty config", value: "2 bindings", detail: "~/\(configPath)", isInUse: true)])
    #expect(one.buttons.map(\.title) == ["Edit in Ghostty Config", "Reveal in Finder"])
    one.buttons[0].perform()
    #expect(opened == [home.url.appendingPathComponent(configPath)])

    try home.write(appSupportPath, "keybind = ctrl+c=text:c\n")
    let two = try #require(GhosttyConfigSettings.bindingsSource(home.reading(), homeDirectory: home.url.path, actions: actions))
    #expect(two.lines.map(\.value) == ["2 bindings", "1 binding"])
    #expect(two.buttons.map(\.title) == ["Reveal in Finder"])
    two.buttons[0].perform()
    #expect(revealed == [[home.url.appendingPathComponent(configPath), home.url.appendingPathComponent(appSupportPath)]])
}

// MARK: - Files and lines left out

@MainActor
@Test func settingsWindowTerminalFilesAreReadMissingOrChanged() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "font-size = 13\nconfig-file = keys.conf\n")
    try home.write(".config/ghostty/keys.conf", "keybind = ctrl+a=text:a\n")
    try home.write(appSupportPath, "keybind = ctrl+b=text:b\n")
    let launch = home.reading()
    let defaultPaths = TerminalSettings.ghosttyDefaultConfigPaths(home: home.url, environment: [:])
    func files() -> [GhosttyConfigSettings.File] {
        GhosttyConfigSettings.files(
            defaultPaths: defaultPaths,
            launch: launch,
            now: home.reading(),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    let read = files()
    #expect(read.map(\.url) == defaultPaths + [home.url.appendingPathComponent(".config/ghostty/keys.conf")])
    #expect(read.map(\.state) == [.read, .missing, .read, .missing, .read])
    #expect(read.map(\.state.text) == ["Read", "Missing", "Read", "Missing", "Read"])
    #expect(read.map(\.exists) == [true, false, true, false, true])
    #expect(read.map(\.includedByText) == [nil, nil, nil, nil, "Named by config-file in config, line 2"])

    // Changed lines, a file added and one removed since launch: each
    // applies from Cherry's next launch. A change to a line Cherry does
    // not read is no change.
    try home.write(configPath, "font-size = 14\nconfig-file = keys.conf\n")
    try home.write(".config/ghostty/config.ghostty", "keybind = ctrl+c=text:c\n")
    try home.write(appSupportPath, "keybind = ctrl+b=text:B\n")
    try home.delete(".config/ghostty/keys.conf")
    let changed = files()
    #expect(changed.map(\.state) == [.read, .changed, .changed, .missing, .changed])
    #expect(changed.map(\.exists) == [true, true, true, false, false])
    // The file the launch read keeps its config-file line.
    #expect(changed[4].includedByText == "Named by config-file in config, line 2")
}

@MainActor
@Test func settingsWindowTerminalListsTheLinesGhosttyRejects() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "keybind = ctrl+a=text:a\n")
    #expect(GhosttyConfigSettings.linesLeftOut(home.reading()).isEmpty)
    #expect(GhosttyConfigSettings.linesLeftOut(nil).isEmpty)

    try home.write(".config/ghostty/keys.conf", "\n\nkeybind = shift+enter = text:\\n\nmacos-option-as-alt = yes\n")
    try home.write(configPath, "config-file = keys.conf\nkeybind = ctrl+a=text:a\n")
    let lines = GhosttyConfigSettings.linesLeftOut(home.reading())
    #expect(lines.map(\.location) == ["keys.conf, line 3", "keys.conf, line 4"])
    #expect(lines.map(\.text) == ["keybind = shift+enter = text:\\n", "macos-option-as-alt = yes"])
    #expect(lines.allSatisfy { $0.reason.hasPrefix("Ghostty: ") })
    #expect(lines[1].reason.contains("invalid value"))
    #expect(Set(lines.map(\.id)).count == 2)

    // Ghostty's diagnostic loses the key it starts with.
    let line = UserGhosttyKeyboardConfig.Line(
        file: home.url, line: 1, key: "keybind", value: "x", rejection: " keybind: invalid value "
    )
    #expect(GhosttyConfigSettings.rejectionReason(of: line) == "invalid value")
}

@MainActor
@Test func settingsWindowTerminalPageModelReadsTheFilesOnlyWhenItRefreshes() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "macos-option-as-alt = left\nkeybind = ctrl+a=text:a\n")
    var reads = 0
    let model = GhosttyConfigPageModel(
        launchReading: home.reading(),
        defaultPaths: TerminalSettings.ghosttyDefaultConfigPaths(home: home.url, environment: [:]),
        read: {
            reads += 1
            return home.reading()
        },
        fileExists: { FileManager.default.fileExists(atPath: $0) }
    )
    // Made from the launch reading alone.
    #expect(reads == 0)
    #expect(model.files.isEmpty)
    #expect(model.optionKey.value == .left)
    #expect(model.bindingCounts.text == "1 applied · 0 not applied · 0 left out")

    model.refresh()
    #expect(reads == 1)
    #expect(model.files.map(\.state) == [.read, .missing, .missing, .missing])
    #expect(!model.optionKey.changedSinceLaunch)

    try home.write(configPath, "macos-option-as-alt = right\nkeybind = ctrl+a=text:a\n")
    model.refresh()
    #expect(model.files.first?.state == .changed)
    #expect(model.optionKey.changedSinceLaunch)
    // What the terminals use stays the launch's.
    #expect(model.optionKey.value == .left)

    // Reading files that say the same publishes nothing.
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }
    model.refresh()
    #expect(reads == 3)
    #expect(published == 0)
}

@MainActor
@Test func settingsWindowTerminalShowInShortcutsOpensItsTerminalKeyBindings() {
    let navigator = SettingsNavigator(initial: .page(.terminal))
    TerminalSettingsPage.showKeyBindingsInShortcuts(navigator)
    #expect(navigator.route == .page(.shortcuts))
    #expect(navigator.highlight.row == .shortcutsTerminalKeyBindings)
    #expect(navigator.canGoBack)
}

// MARK: - Report

@MainActor
private func reportSources(home: TemporaryHome, persistent: Bool, resourcesAsked: @escaping @MainActor () -> Void) -> GhosttyConfigReport.Sources {
    GhosttyConfigReport.Sources(
        info: ["CFBundleShortVersionString": "2026.10.14.5", "CFBundleVersion": "20261014120000.cdb92d6"],
        macOS: "Version 26.1 (Build 25B78)",
        inputSource: "com.apple.keylayout.ABC",
        keyboardLayout: "com.apple.keylayout.ABC",
        persistentSessions: persistent,
        persistentSessionsUnavailable: nil,
        lastSessionLaunchFailure: nil,
        home: home.url,
        environment: [:],
        launchReading: home.reading(),
        read: { home.reading() },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        appliedKeyboardLines: [("keybind", "ctrl+e=text:secret\\r"), ("macos-option-as-alt", "true")],
        stagedResources: {
            resourcesAsked()
            return nil
        },
        frontTab: { KeyboardDiagnostics.Tab(id: UUID(), title: "claude", project: "cherry") }
    )
}

@MainActor
@Test func settingsWindowTerminalReportHasNoKeyTestAndMasksWhatTextBindingsType() async throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "keybind = ctrl+e=text:secret\\r\nmacos-option-as-alt = yes\n")
    var asked = 0

    let report = await GhosttyConfigReport.build(from: reportSources(home: home, persistent: false) { asked += 1 })
    let text = report.text
    #expect(!report.includesKeyTest)
    #expect(text.hasPrefix("Cherry keyboard diagnostics\nCherry 2026.10.14.5 (20261014120000.cdb92d6)\nmacOS Version 26.1 (Build 25B78)\n"))
    #expect(text.contains("Persistent sessions: off\n"))
    #expect(text.contains("New native tab: TERM=xterm-ghostty"))
    #expect(!text.contains("New persistent tab"))
    #expect(text.contains("  ~/.config/ghostty/config: exists, read by Cherry\n"))
    #expect(text.contains("    keybind = ctrl+e=text:***\\r   (applied)\n"))
    #expect(text.contains("    macos-option-as-alt = yes   (left out: Ghostty rejects it ("))
    #expect(text.contains("Applied to Cherry's terminals (read once, at launch):\n  keybind = ctrl+e=text:***\\r\n"))
    #expect(!text.contains("secret"))
    #expect(text.hasSuffix("Front tab: “claude” in cherry: native tab\n"
        + "  keys: Ghostty's surface encodes them, with Cherry's keybinds\n"
        + "  modes: Ghostty's surface keeps them; Cherry cannot read a native tab's\n"))
    #expect(!text.contains("Key test"))
    // The staged resources are asked for only for a persistent tab's TERM.
    #expect(asked == 0)

    let persistent = await GhosttyConfigReport.build(from: reportSources(home: home, persistent: true) { asked += 1 })
    #expect(asked == 1)
    #expect(persistent.text.contains("Persistent sessions: on\n"))
    #expect(persistent.text.contains("New persistent tab: TERM="))
}

// MARK: - Page reset and search

@MainActor
@Test func settingsWindowTerminalResetListsAndResetsOnlyFontSizeAndBlinkCursor() {
    let defaults = privateDefaults("SettingsWindowTerminalReset")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    settings.fontSize = 16
    settings.cursorBlink = false
    settings.darkTerminalThemeName = "Dracula"

    #expect(settings.changes(in: TerminalSettings.Setting.terminalPage).map(\.text) == [
        "Font size 16 pt → 14 pt", "Blink cursor Off → On",
    ])
    #expect(SettingsPageReset.confirmation(
        for: settings.changes(in: TerminalSettings.Setting.terminalPage),
        mentionsGhosttyConfig: true
    ).message == "Font size 16 pt → 14 pt · Blink cursor Off → On. Values from your Ghostty config stay.")
    settings.reset(TerminalSettings.Setting.terminalPage)
    #expect(settings.fontSize == 14)
    #expect(settings.cursorBlink)
    #expect(defaults.object(forKey: TerminalSettings.Setting.fontSize.rawValue) == nil)
    #expect(settings.darkTerminalThemeName == "Dracula")
    #expect(settings.changes(in: TerminalSettings.Setting.terminalPage).isEmpty)
}

@MainActor
private func terminalSearchContext(_ name: String, ghostty: UserGhosttyKeyboardConfig?) -> SettingsSearchContext {
    let defaults = privateDefaults(name)
    return SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: AgentSettings(defaults: defaults),
        ghostty: ghostty,
        defaults: defaults
    )
}

@MainActor
@Test func settingsWindowTerminalSearchFindsTheGhosttyRows() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(configPath, "macos-option-as-alt = left\nkeybind = ctrl+a=text:a\n")
    let rows = SettingsSearchIndex.rows(in: terminalSearchContext("SettingsWindowTerminalSearch", ghostty: home.reading()))

    let terminal = try #require(SettingsSearchIndex.groups(for: "ghostty", in: rows).first { $0.kind == .page(.terminal) })
    let found = terminal.results.map(\.id).filter { $0.rawValue.hasPrefix("terminal.") }
    #expect(Set(found) == [.terminalGhosttyConfig, .terminalKeyBindings, .terminalOptionKey])
    // Their titles say Ghostty; the Option key's second line does.
    #expect(found.last == .terminalOptionKey)
    let optionKey = try #require(rows.first { $0.id == .terminalOptionKey })
    #expect(optionKey.detail == "Keyboard · set by your Ghostty config")
    // Its value, and Ghostty's name for it, find it too.
    #expect(SettingsSearchIndex.groups(for: "left option", in: rows).flatMap(\.results).map(\.id).contains(.terminalOptionKey))
    #expect(SettingsSearchIndex.groups(for: "macos-option", in: rows).flatMap(\.results).map(\.id) == [.terminalOptionKey])
    #expect(rows.first { $0.id == .terminalScrollback }?.detail == "Scrollback · 4 MB")
    #expect(SettingsSearchIndex.groups(for: "report", in: rows).flatMap(\.results).map(\.id).contains(.terminalGhosttyConfig))

    // Without a reading, Cherry's default.
    let none = SettingsSearchIndex.rows(in: terminalSearchContext("SettingsWindowTerminalSearchNone", ghostty: nil))
    #expect(none.first { $0.id == .terminalOptionKey }?.detail == "Keyboard · Option is Alt")
}
