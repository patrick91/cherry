import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cherry

// The pure parts of the Settings window's components (Settings/Design,
// SettingsActions.swift): what a source badge's popover lists and offers,
// the ↺ texts, keycap parts, the row highlight, confirmations and what the
// app is asked. Private defaults and recording closures only: nothing here
// reaches the pasteboard, Finder, a window or the menu bar item.

/// What the closures a test hands a component were called with.
@MainActor
private final class ComponentCallLog {
    var calls: [String] = []
}

private typealias Line = SettingsSourceState.Line

@Test @MainActor func settingsWindowSourceStateOfADefaultValueHasNoBadgeAndNoReset() {
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowComponents"), launchArguments: [:])
    let state = SettingsSourceState.terminal(.fontSize, in: settings)

    #expect(state.source == .cherryDefault)
    #expect(state.badgeText == nil)
    #expect(state.rowReset == nil)
    #expect(state.buttons.isEmpty)
    #expect(state.note == nil)
    #expect(state.lines == [
        Line("Set here", detail: "Not set"),
        Line("Cherry default", value: "14 pt", isInUse: true),
    ])
    #expect(state.accessibilityLabel == "Source: Cherry default. Default: 14 points.")
}

@Test @MainActor func settingsWindowSourceStateSetHereResetsToTheDefaultFromItsPopoverAndItsRow() {
    let defaults = privateDefaults("SettingsWindowComponents")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    settings.fontSize = 16
    let state = SettingsSourceState.terminal(.fontSize, in: settings)

    #expect(state.badgeText == "Set here")
    #expect(state.lines == [
        Line("Set here", value: "16 pt", isInUse: true),
        Line("Cherry default", value: "14 pt"),
    ])
    #expect(state.buttons.map(\.title) == ["Reset to default (14 pt)"])
    #expect(state.rowReset?.title == "Reset to default (14 pt)")
    #expect(state.accessibilityLabel == "Source: Set here. Default: 14 points.")

    // ↺ never asks: it resets at once and removes the stored value.
    state.rowReset?.perform()
    #expect(settings.fontSize == 14)
    #expect(settings.source(of: .fontSize) == .cherryDefault)
    #expect(defaults.object(forKey: "terminal.fontSize") == nil)
}

@Test @MainActor func settingsWindowSourceStateOfALaunchArgumentNamesItAndOffersNothing() {
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowComponents"), launchArguments: [
        "sessions.onQuit": "keep",
        "terminal.fontSize": "20",
    ])

    let onQuit = SettingsSourceState.terminal(.localSessionsOnQuit, in: settings)
    #expect(onQuit.badgeText == "This run only")
    #expect(onQuit.lines == [
        Line("This run only", value: "Keep Running", detail: "-sessions.onQuit", isInUse: true),
        Line("Set here", detail: "Not used while a launch argument sets it"),
        Line("Cherry default", value: "Ask"),
    ])
    #expect(onQuit.note == "A launch argument sets it until Cherry quits, so it can't be changed here.")
    #expect(onQuit.buttons.isEmpty)
    #expect(onQuit.rowReset == nil)
    #expect(!onQuit.source.isEditable)

    // "20" is a string, not a size: the default is in use.
    let fontSize = SettingsSourceState.terminal(.fontSize, in: settings)
    #expect(fontSize.source == .launchArgument(applied: false))
    #expect(fontSize.lines.first == Line(
        "This run only",
        detail: "-terminal.fontSize: not one of its values",
        isInUse: true
    ))
    #expect(fontSize.note == "The launch argument isn't one of its values, so Cherry uses its default until it quits.")
    #expect(fontSize.buttons.isEmpty)
    #expect(fontSize.rowReset == nil)
}

@Test @MainActor func settingsWindowSourceStateOfAStoredKeyFollowsItsDefaultAndLaunchArgument() {
    let defaults = privateDefaults("SettingsWindowComponents")
    let key = "settingsWindow.components.flag"
    let recorder = ComponentCallLog()
    func state(launchArguments: [String: Any] = [:]) -> SettingsSourceState {
        let isOn = (launchArguments[key] ?? defaults.object(forKey: key)) as? Bool ?? true
        return SettingsSourceState.stored(
            key: key,
            defaults: defaults,
            launchArguments: launchArguments,
            value: isOn ? "On" : "Off",
            defaultValue: "On",
            parses: { $0 is Bool },
            isDefault: { ($0 as? Bool) == true },
            reset: { recorder.calls.append("reset") }
        )
    }

    #expect(state().source == .cherryDefault)
    #expect(state().rowReset == nil)

    defaults.set(false, forKey: key)
    let setHere = state()
    #expect(setHere.badgeText == "Set here")
    #expect(setHere.lines.first == Line("Set here", value: "Off", isInUse: true))
    #expect(setHere.rowReset?.title == "Reset to default (On)")
    setHere.rowReset?.perform()
    #expect(recorder.calls == ["reset"])

    let argument = state(launchArguments: [key: false])
    #expect(argument.badgeText == "This run only")
    #expect(argument.lines.first == Line("This run only", value: "Off", detail: "-\(key)", isInUse: true))
    #expect(argument.rowReset == nil)
}

@Test @MainActor func settingsWindowSourceStateOfAProjectValueOffersRevertAndSaveByItsSource() {
    let recorder = ComponentCallLog()
    func state(
        _ source: ProjectValueSource,
        fileValue: String? = "Green",
        thisMacValue: String? = "Blue",
        revertTitle: String? = nil,
        canSave: Bool = true
    ) -> SettingsSourceState {
        var save: (@MainActor () -> Void)?
        if canSave {
            save = { recorder.calls.append("save") }
        }
        return SettingsSourceState.project(
            source: source,
            fileValue: fileValue,
            thisMacValue: thisMacValue,
            defaultValue: "None",
            revertTitle: revertTitle,
            revert: { recorder.calls.append("revert") },
            saveToFile: save
        )
    }

    let overrides = state(.overridesProjectFile)
    #expect(overrides.badgeText == "Overrides cherry.toml")
    #expect(overrides.lines == [
        Line("This Mac", value: "Blue", isInUse: true),
        Line("cherry.toml", value: "Green"),
        Line("Cherry default", value: "None"),
    ])
    #expect(overrides.buttons.map(\.title) == ["Revert to cherry.toml (Green)", "Save to cherry.toml"])
    #expect(overrides.rowReset?.title == "Revert to cherry.toml (Green)")
    #expect(overrides.note == "Save to cherry.toml writes Blue into the file and drops the override.")
    overrides.buttons[1].perform()
    overrides.rowReset?.perform()
    #expect(recorder.calls == ["save", "revert"])

    // A project on another Mac cannot save to its file.
    let elsewhere = state(.overridesProjectFile, canSave: false)
    #expect(elsewhere.buttons.map(\.title) == ["Revert to cherry.toml (Green)"])
    #expect(elsewhere.note == nil)

    // A command's line is too long to name.
    #expect(state(.overridesProjectFile, revertTitle: "Revert Dev server to cherry.toml").rowReset?.title
        == "Revert Dev server to cherry.toml")

    let thisMacOnly = state(.thisMacOnly, fileValue: nil)
    #expect(thisMacOnly.badgeText == "This Mac only")
    #expect(thisMacOnly.lines == [
        Line("This Mac", value: "Blue", isInUse: true),
        Line("cherry.toml", detail: "Says nothing about it"),
        Line("Cherry default", value: "None"),
    ])
    #expect(thisMacOnly.buttons.map(\.title) == ["Save to cherry.toml", "Reset to default (None)"])
    #expect(thisMacOnly.rowReset == nil)
    #expect(thisMacOnly.note == "Save to cherry.toml writes Blue into the file.")

    let projectFile = state(.projectFile, thisMacValue: nil)
    #expect(projectFile.badgeText == "cherry.toml")
    #expect(projectFile.lines == [
        Line("This Mac", detail: "Not set"),
        Line("cherry.toml", value: "Green", isInUse: true),
        Line("Cherry default", value: "None"),
    ])
    #expect(projectFile.buttons.isEmpty)
    #expect(projectFile.rowReset == nil)

    let neither = state(.none, fileValue: nil, thisMacValue: nil)
    #expect(neither.badgeText == nil)
    #expect(neither.lines.last == Line("Cherry default", value: "None", isInUse: true))
    #expect(neither.buttons.isEmpty)
}

@Test @MainActor func settingsWindowSourceStateOfAGhosttyLineOpensAndRevealsItsFileOnly() {
    let recorder = ComponentCallLog()
    let actions = SettingsActions(
        revealInFinder: { urls in recorder.calls.append("reveal " + urls.map(\.path).joined(separator: ",")) },
        openTextFile: { url in recorder.calls.append("open " + url.path) }
    )
    let file = URL(fileURLWithPath: "/Users/someone/.config/ghostty/config")
    let state = SettingsSourceState.ghosttyConfig(
        file: file,
        line: 12,
        value: "Left Option is Alt",
        defaultValue: "Option is Alt",
        homeDirectory: "/Users/someone",
        actions: actions
    )

    #expect(state.badgeText == "Ghostty config")
    #expect(!state.source.isEditable)
    #expect(state.lines == [
        Line("Ghostty config", value: "Left Option is Alt", detail: "~/.config/ghostty/config, line 12", isInUse: true),
        Line("Cherry default", value: "Option is Alt"),
    ])
    #expect(state.note == "Cherry reads this file when it opens. Restart Cherry after you change it.")
    #expect(state.buttons.map(\.title) == ["Edit in Ghostty Config", "Reveal in Finder"])
    // Cherry never writes the user's Ghostty files: no ↺.
    #expect(state.rowReset == nil)
    for button in state.buttons {
        button.perform()
    }
    #expect(recorder.calls == [
        "open /Users/someone/.config/ghostty/config",
        "reveal /Users/someone/.config/ghostty/config",
    ])

    #expect(SettingsSourceState.ghosttyLocation(file: file, line: nil, homeDirectory: "/Users/someone")
        == "~/.config/ghostty/config")
    #expect(SettingsSourceState.ghosttyLocation(
        file: URL(fileURLWithPath: "/etc/ghostty/config"),
        line: 3,
        homeDirectory: "/Users/someone"
    ) == "/etc/ghostty/config, line 3")
}

@Test @MainActor func settingsWindowRowResetShowsOnlyForSetHereAndOverrides() {
    let reset = SettingsAction("Reset to default (Auto)") {}
    let sources: [SettingSource] = [
        .cherryDefault, .setHere, .launchArgument(applied: true), .ghosttyConfig(file: URL(fileURLWithPath: "/c"), line: 1),
        .projectFile, .overridesProjectFile, .thisMacOnly,
    ]
    let offering = sources.filter { SettingsSourceState(source: $0, reset: reset).rowReset != nil }
    #expect(offering == [.setHere, .overridesProjectFile])
    #expect(SettingsSourceState.resetTitle("14 pt") == "Reset to default (14 pt)")
}

@Test func settingsWindowBadgesHaveAStyleForEverySourceButTheDefault() {
    #expect(SettingsDesign.badgeStyle(for: .cherryDefault) == nil)
    let badged: [SettingSource] = [
        .setHere, .launchArgument(applied: true), .ghosttyConfig(file: URL(fileURLWithPath: "/c"), line: nil),
        .projectFile, .overridesProjectFile, .thisMacOnly,
    ]
    for source in badged {
        #expect(SettingsDesign.badgeStyle(for: source) != nil, Comment(rawValue: source.badgeText ?? ""))
    }
    // This run only is an outline, not a fill.
    #expect(badged.filter { SettingsDesign.badgeStyle(for: $0)?.outline != nil } == [.launchArgument(applied: true)])
}

@Test func settingsWindowKeycapsSplitAShortcutIntoItsModifiersAndKey() {
    #expect(SettingsKeycaps.parts(of: "⇧⌘D") == ["⇧", "⌘", "D"])
    #expect(SettingsKeycaps.parts(of: "⌘,") == ["⌘", ","])
    #expect(SettingsKeycaps.parts(of: "⌥⌘↑") == ["⌥", "⌘", "↑"])
    #expect(SettingsKeycaps.parts(of: "⌃⇧Tab") == ["⌃", "⇧", "Tab"])
    #expect(SettingsKeycaps.parts(of: "⇧ ⌘ D") == ["⇧", "⌘", "D"])
    #expect(SettingsKeycaps.parts(of: "F5") == ["F5"])

    #expect(SettingsKeycaps.text(for: ["⇧", "⌘", "D"]) == "⇧ ⌘ D")
    #expect(SettingsKeycaps.spokenName(for: ["⇧", "⌘", "D"]) == "Shift Command D")
    #expect(SettingsKeycaps.spokenName(for: ["⌃", "⌥", "⎋"]) == "Control Option Escape")
    #expect(SettingsKeycaps.accessibilityLabel(chips: [["⌘", "["], ["⌘", "]"]], separator: "/")
        == "Command Left Bracket or Command Right Bracket")
    #expect(SettingsKeycaps.accessibilityLabel(chips: [["⌃", "A"], ["B"]], separator: "›")
        == "Control A, then B")
}

@Test @MainActor func settingsWindowRowHighlightFlashesARowOnceAndOnlyRecently() {
    var now = ContinuousClock.now
    let highlight = SettingsRowHighlight(now: { now })
    #expect(highlight.row == nil)
    #expect(highlight.generation == 0)
    #expect(!highlight.isRecent)

    highlight.flash("terminal.fontSize")
    #expect(highlight.row == "terminal.fontSize")
    #expect(highlight.generation == 1)
    #expect(highlight.showsFlash(for: "terminal.fontSize"))
    #expect(!highlight.showsFlash(for: "terminal.cursorBlink"))

    // A page shown again later (Back) does not flash its row.
    now = now.advanced(by: SettingsRowHighlight.appearanceWindow + .milliseconds(1))
    #expect(!highlight.isRecent)
    #expect(!highlight.showsFlash(for: "terminal.fontSize"))

    // The same row again flashes again.
    highlight.flash("terminal.fontSize")
    #expect(highlight.generation == 2)
    #expect(highlight.showsFlash(for: "terminal.fontSize"))
}

@Test func settingsWindowRowIDsFollowTheConvention() {
    let id: SettingsRowID = "terminal.fontSize"
    #expect(id == SettingsRowID(rawValue: "terminal.fontSize"))
    #expect(id.description == "terminal.fontSize")
    #expect(SettingsRowID.agent("claude", "mcp").rawValue == "agent.claude.mcp")
    #expect(SettingsRowID.project("/Users/someone/code/cherry", "todos").rawValue
        == "project./Users/someone/code/cherry.todos")
    let device = UUID()
    #expect(SettingsRowID.mac(device).rawValue == "mac.\(device.uuidString)")
}

@Test @MainActor func settingsWindowPageResetAsksWithTheChangesThenResets() {
    let recorder = ComponentCallLog()
    let one = SettingsConfirmation.pageReset(
        changes: [SettingsChange(title: "Font size", from: "16 pt", to: "14 pt")],
        mentionsGhosttyConfig: true,
        reset: { recorder.calls.append("reset") }
    )
    #expect(one == SettingsConfirmation(
        title: "Reset 1 setting?",
        message: "Font size 16 pt → 14 pt. Values from your Ghostty config stay.",
        choices: [SettingsConfirmation.Choice("Reset", isDefault: true), .cancel()]
    ))
    #expect(one.choices.last?.role == .cancel)
    #expect(recorder.calls.isEmpty)
    one.choices[0].perform()
    #expect(recorder.calls == ["reset"])

    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowComponents"), launchArguments: [:])
    settings.appearance = .dark
    settings.projectColorDisplayMode = .tinted
    let page = SettingsConfirmation.pageReset(
        changes: settings.changes(in: TerminalSettings.Setting.interfacePage),
        mentionsGhosttyConfig: false
    ) {
        settings.reset(TerminalSettings.Setting.interfacePage)
    }
    #expect(page.title == "Reset 2 settings?")
    #expect(page.message == "Color scheme Dark → Auto · Project colors Tinted → Accent.")
    page.choices[0].perform()
    #expect(settings.changes(in: TerminalSettings.Setting.interfacePage).isEmpty)
    // The texts and roles make a confirmation, not its actions.
    #expect(SettingsConfirmation.Choice("Remove", role: .destructive) { recorder.calls.append("x") }
        == SettingsConfirmation.Choice("Remove", role: .destructive))
    #expect(SettingsConfirmation.Choice("Remove", role: .destructive) != SettingsConfirmation.Choice("Remove"))
}

@Test @MainActor func settingsWindowActionsDoNothingOutsideTheWindowAndCarryATestsOwn() {
    let inert = EnvironmentValues().settingsActions
    #expect(!inert.showPersistentSessions(nil))
    #expect(!inert.canShowPersistentSessions())
    #expect(!inert.showBackgroundSessionsList())
    inert.copy("never on the pasteboard")
    inert.openTextFile(URL(fileURLWithPath: "/nowhere"))
    inert.revealInFinder([])
    inert.openProjectWindow("/nowhere")

    let recorder = ComponentCallLog()
    var values = EnvironmentValues()
    values.settingsActions = SettingsActions(
        copy: { recorder.calls.append("copy \($0)") },
        showPersistentSessions: { host in
            recorder.calls.append("sessions \(host?.id ?? "local")")
            return true
        }
    )
    values.settingsActions.copy("v1")
    #expect(values.settingsActions.showPersistentSessions(nil))
    #expect(recorder.calls == ["copy v1", "sessions local"])
}

@Test @MainActor func settingsWindowMenuBarPanelCannotOpenWhileTheItemIsNotInstalled() {
    #expect(MenuBarStatusItem.shared.statusItem == nil)
    #expect(!MenuBarStatusItem.shared.openPanel())
}

@Test func settingsWindowTextFilesOpenInTheDefaultEditorElseThePlainTextApp() {
    func editor(_ id: String) -> InstalledEditor {
        let known = ExternalEditorCatalog.all.first { $0.id == id }!
        return InstalledEditor(
            editor: known,
            bundleIdentifier: known.bundleIdentifiers[0],
            appURL: URL(fileURLWithPath: "/Applications/\(known.displayName).app")
        )
    }
    let editors = [editor("zed"), editor("vscode")]
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    #expect(SettingsTextFileOpening.application(editors: editors, preferredEditorID: "vscode", plainTextApplication: textEdit)
        == URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
    // Automatic, or an editor that is gone: the first installed one.
    #expect(SettingsTextFileOpening.application(editors: editors, preferredEditorID: "", plainTextApplication: textEdit)
        == URL(fileURLWithPath: "/Applications/Zed.app"))
    #expect(SettingsTextFileOpening.application(editors: editors, preferredEditorID: "nova", plainTextApplication: textEdit)
        == URL(fileURLWithPath: "/Applications/Zed.app"))
    #expect(SettingsTextFileOpening.application(editors: [], preferredEditorID: "zed", plainTextApplication: textEdit)
        == textEdit)
    #expect(SettingsTextFileOpening.application(editors: [], preferredEditorID: "", plainTextApplication: nil) == nil)
}

@Test @MainActor func settingsWindowKeyCaptureTakesAKeyOnlyWhileAPageHandlesIt() throws {
    let capture = SettingsKeyCapture()
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "f",
        charactersIgnoringModifiers: "f",
        isARepeat: false,
        keyCode: 3
    ))
    #expect(!capture.take(event))

    let recorder = ComponentCallLog()
    capture.handler = { event in
        recorder.calls.append(event.charactersIgnoringModifiers ?? "")
        return true
    }
    #expect(capture.take(event))
    #expect(recorder.calls == ["f"])

    capture.handler = nil
    #expect(!capture.take(event))
}

@Test func settingsWindowCherryTileIsTheBrandmarkOnItsRed() {
    #expect(SettingsTileStyle.cherry == SettingsTileStyle(.brandmark, background: "#D9354A"))
    #expect(SettingsTileStyle.cherry.foreground == "#FFFFFF")
    let terminal = SettingsTileStyle(
        .symbol("apple.terminal"),
        background: SettingsDesign.TileColors.terminal,
        foreground: SettingsDesign.TileColors.terminalGlyph
    )
    #expect(terminal.background == "#232326")
    #expect(terminal.foreground == "#4ADE80")
    #expect(SettingsTileStyle(.letters("Cl"), background: SettingsDesign.TileColors.agent) != terminal)
}

@Test @MainActor func settingsWindowSearchFieldTakesNoFocusInAWindowThatIsNotOnScreen() {
    let window = testWindow()
    let field = SettingsSearchTextField()
    window.contentView?.addSubview(field)

    // AppKit's pick of a first responder as the window opens.
    window.makeFirstResponder(field)
    #expect(field.currentEditor() == nil)
    #expect(window.firstResponder !== field)
    // Nor does ⌘F's request take it there.
    field.focus()
    #expect(field.currentEditor() == nil)
    #expect(window.firstResponder !== field)
}
