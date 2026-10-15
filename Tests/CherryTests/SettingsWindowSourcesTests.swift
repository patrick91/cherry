import Combine
import Foundation
import Testing
@testable import Cherry

// Where a setting's value comes from, and resetting it (Settings):
// `TerminalSettings.source(of:)`, `valueText`, `changes(in:)`, `reset(_:)`,
// `SettingSource` and `SettingsPageReset`. Private defaults and launch
// arguments only: nothing here reads this run's arguments or the app's
// defaults.

/// The `.terminalSettingsDidChange` posts of one settings object.
private final class TerminalChangeCount: @unchecked Sendable {
    var value = 0
}

@MainActor
private func observeTerminalChanges(of settings: TerminalSettings) -> (TerminalChangeCount, NSObjectProtocol) {
    let count = TerminalChangeCount()
    let observer = NotificationCenter.default.addObserver(
        forName: .terminalSettingsDidChange,
        object: settings,
        queue: nil
    ) { _ in count.value += 1 }
    return (count, observer)
}

/// What `TerminalSettings` shows for a contrast ratio, in this locale.
private func ratioText(_ ratio: Double) -> String {
    "\(ratio.formatted(.number.precision(.fractionLength(2))))×"
}

@Test @MainActor func settingsWindowSourceIsSetHereOnlyForAStoredValueThatIsNotTheDefault() {
    let defaults = privateDefaults("SettingsWindowSources")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    for setting in TerminalSettings.Setting.allCases {
        #expect(settings.source(of: setting) == .cherryDefault, Comment(rawValue: setting.rawValue))
        #expect(settings.isDefault(setting), Comment(rawValue: setting.rawValue))
    }
    #expect(settings.changes(in: TerminalSettings.Setting.allCases).isEmpty)

    settings.fontSize = 16
    settings.localSessionsOnQuit = .keep
    settings.terminalBell = .silent
    #expect(settings.source(of: .fontSize) == .setHere)
    #expect(settings.source(of: .localSessionsOnQuit) == .setHere)
    #expect(settings.source(of: .terminalBell) == .setHere)
    #expect(settings.source(of: .cursorBlink) == .cherryDefault)

    // Back at the default, it is stored but shows no badge.
    settings.fontSize = 14
    #expect(defaults.object(forKey: "terminal.fontSize") as? Double == 14)
    #expect(settings.source(of: .fontSize) == .cherryDefault)

    // A value stored by an earlier run.
    defaults.set(18.0, forKey: "terminal.fontSize")
    defaults.set("dark", forKey: "appearance.theme")
    let reloaded = TerminalSettings(defaults: defaults, launchArguments: [:])
    #expect(reloaded.fontSize == 18)
    #expect(reloaded.source(of: .fontSize) == .setHere)
    #expect(reloaded.source(of: .appearance) == .setHere)
    #expect(reloaded.terminalBell == .silent)

    // A stored value that is none of the setting's values reads as the default.
    defaults.set("sometimes", forKey: "sessions.onQuit")
    defaults.set("loud", forKey: "terminal.bell")
    let invalid = TerminalSettings(defaults: defaults, launchArguments: [:])
    #expect(invalid.localSessionsOnQuit == .ask)
    #expect(invalid.source(of: .localSessionsOnQuit) == .cherryDefault)
    #expect(invalid.terminalBell == .beep)
    #expect(invalid.source(of: .terminalBell) == .cherryDefault)
}

@Test @MainActor func settingsWindowALaunchArgumentIsThisRunOnlyAndHidesTheStoredValue() {
    let defaults = privateDefaults("SettingsWindowSources")
    defaults.set("end", forKey: "sessions.onQuit")
    defaults.set(18.0, forKey: "terminal.fontSize")
    defaults.set(true, forKey: "sessions.persistLocal")
    defaults.set(false, forKey: "sessions.closeTabOnExit")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [
        // `-sessions.onQuit keep`
        "sessions.onQuit": "keep",
        // `-terminal.fontSize 20` is the string "20", no Double: the
        // default is in use, not the stored 18.
        "terminal.fontSize": "20",
        // `-sessions.persistLocal '<false/>'`
        "sessions.persistLocal": false,
        // `-sessions.closeTabOnExit NO` is a string too.
        "sessions.closeTabOnExit": "NO",
    ])

    #expect(settings.localSessionsOnQuit == .keep)
    #expect(settings.source(of: .localSessionsOnQuit) == .launchArgument(applied: true))
    #expect(settings.fontSize == 14)
    #expect(settings.source(of: .fontSize) == .launchArgument(applied: false))
    #expect(!settings.persistLocalSessions)
    #expect(settings.source(of: .persistLocalSessions) == .launchArgument(applied: true))
    #expect(settings.closeTabsOnCleanExit)
    #expect(settings.source(of: .closeTabsOnCleanExit) == .launchArgument(applied: false))
    #expect(!settings.source(of: .localSessionsOnQuit).isEditable)
    #expect(settings.source(of: .localSessionsOnQuit).badgeText == "This run only")

    // A page's reset neither lists nor changes them.
    #expect(settings.changes(in: TerminalSettings.Setting.sessionsPage + [.fontSize]).isEmpty)
    settings.reset(TerminalSettings.Setting.sessionsPage + [.fontSize])
    #expect(settings.localSessionsOnQuit == .keep)
    #expect(defaults.object(forKey: "sessions.onQuit") as? String == "end")
    #expect(defaults.object(forKey: "terminal.fontSize") as? Double == 18)
    #expect(settings.source(of: .localSessionsOnQuit) == .launchArgument(applied: true))

    // Only `.standard` sees this run's arguments.
    #expect(SettingSource.launchArguments(for: defaults).isEmpty)
}

@Test @MainActor func settingsWindowSlidersCountAsTheirDefaultWithinHalfAStep() {
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowSources"), launchArguments: [:])

    // What a slider from 1 in steps of 0.05 can store for 1.15.
    settings.minimumContrast = 1.1500000000000001
    #expect(settings.minimumContrast != 1.15)
    #expect(settings.isDefault(.minimumContrast))
    #expect(settings.source(of: .minimumContrast) == .cherryDefault)
    #expect(settings.valueText(.minimumContrast) == ratioText(1.15))
    settings.minimumContrast = 1.2
    #expect(settings.source(of: .minimumContrast) == .setHere)

    settings.sidebarBackgroundDepth = 0.01 * 8
    #expect(settings.source(of: .sidebarBackgroundDepth) == .cherryDefault)
    settings.sidebarBackgroundDepth = 0.09
    #expect(settings.source(of: .sidebarBackgroundDepth) == .setHere)

    settings.fontSize = 14.000000000000002
    #expect(settings.source(of: .fontSize) == .cherryDefault)
    settings.fontSize = 15
    #expect(settings.source(of: .fontSize) == .setHere)
}

@Test @MainActor func settingsWindowValueTextsAreWhatTheRowsShow() {
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowSources"), launchArguments: [:])
    let texts: [TerminalSettings.Setting: String] = [
        .appearance: "Auto",
        .sidebarTerminalPathDisplayMode: "Repo focused",
        .projectColorDisplayMode: "Accent",
        .sidebarBackgroundDepth: "8 %",
        .lightTerminalThemeName: "Alabaster",
        .darkTerminalThemeName: "Afterglow",
        .minimumContrast: ratioText(1.15),
        .fontSize: "14 pt",
        .cursorBlink: "On",
        .notifyWhenBackgroundProgramNeedsInput: "On",
        .notifyWhenBackgroundProgramFinishes: "Off",
        .noticeBackgroundSessionsAtLaunch: "On",
        .terminalBell: "Beep",
        .persistLocalSessions: "On",
        .localSessionsOnQuit: "Ask",
        .closeTabsOnCleanExit: "On",
        .defaultEditorID: "Automatic",
    ]
    #expect(Set(texts.keys) == Set(TerminalSettings.Setting.allCases))
    for (setting, text) in texts {
        #expect(settings.valueText(setting) == text, Comment(rawValue: setting.rawValue))
        #expect(settings.defaultValueText(setting) == text, Comment(rawValue: setting.rawValue))
    }

    settings.appearance = .dark
    settings.sidebarBackgroundDepth = 0.12
    settings.minimumContrast = 1.5
    settings.fontSize = 16
    settings.cursorBlink = false
    settings.terminalBell = .silent
    settings.localSessionsOnQuit = .keep
    settings.defaultEditorID = "zed"
    #expect(settings.valueText(.appearance) == "Dark")
    #expect(settings.valueText(.sidebarBackgroundDepth) == "12 %")
    #expect(settings.valueText(.minimumContrast) == ratioText(1.5))
    #expect(settings.valueText(.fontSize) == "16 pt")
    #expect(settings.valueText(.cursorBlink) == "Off")
    #expect(settings.valueText(.terminalBell) == "Silent")
    #expect(settings.valueText(.localSessionsOnQuit) == "Keep Running")
    #expect(settings.valueText(.defaultEditorID) == "Zed")
    #expect(settings.defaultValueText(.fontSize) == "14 pt")
    settings.defaultEditorID = "an-editor-cherry-does-not-know"
    #expect(settings.valueText(.defaultEditorID) == "an-editor-cherry-does-not-know")

    #expect(CherryAppearancePreference.allCases.map(\.label) == ["Auto", "Light", "Dark"])
    #expect(TerminalBell.allCases.map(\.label) == ["Beep", "Silent"])
    #expect(TerminalSettings.shownTabScrollbackBytes == 4_000_000)
}

@Test @MainActor func settingsWindowPagesListTheirSettingsOnce() {
    typealias Setting = TerminalSettings.Setting
    let pages = [Setting.interfacePage, Setting.themesPage, Setting.terminalPage, Setting.notificationsPage]
    let paged = pages.flatMap { $0 }
    #expect(Set(paged).count == paged.count)
    #expect(Set(paged).isDisjoint(with: Setting.sessionsPage))
    #expect(Set(paged + Setting.sessionsPage + [.defaultEditorID]) == Set(Setting.allCases))
    #expect(Set(Setting.allCases.map(\.rawValue)).count == Setting.allCases.count)
    #expect(Setting.allCases.filter(\.affectsTerminal) == [
        .appearance, .lightTerminalThemeName, .darkTerminalThemeName, .minimumContrast, .fontSize, .cursorBlink,
    ])
    #expect(Setting.interfacePage.map(\.title) == [
        "Color scheme", "Paths in the sidebar", "Project colors", "Sidebar contrast",
    ])
    #expect(Setting.notificationsPage.map(\.title) == [
        "Notify me when a background program needs me",
        "Notify me when a background program finishes",
        "Tell me about background sessions when Cherry opens",
        "Bell",
    ])
}

@Test @MainActor func settingsWindowTheBellIsStoredWithoutRebuildingTheTerminal() {
    let defaults = privateDefaults("SettingsWindowSources")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    #expect(settings.terminalBell == .beep)
    let revision = settings.terminalAppearanceRevision
    let (posts, observer) = observeTerminalChanges(of: settings)
    defer { NotificationCenter.default.removeObserver(observer) }

    settings.terminalBell = .silent
    #expect(defaults.object(forKey: "terminal.bell") as? String == "silent")
    #expect(TerminalSettings(defaults: defaults, launchArguments: [:]).terminalBell == .silent)
    #expect(posts.value == 0)
    #expect(settings.terminalAppearanceRevision == revision)
}

@Test @MainActor func settingsWindowResetRemovesTheKeysAndTellsTheTerminalOnce() {
    let defaults = privateDefaults("SettingsWindowSources")
    let settings = TerminalSettings(defaults: defaults, launchArguments: [:])
    settings.fontSize = 16
    settings.cursorBlink = false
    settings.darkTerminalThemeName = "Dracula"
    settings.minimumContrast = 1.5
    settings.sidebarBackgroundDepth = 0.12
    settings.projectColorDisplayMode = .tinted
    settings.notifyWhenBackgroundProgramFinishes = true
    settings.terminalBell = .silent

    let (posts, observer) = observeTerminalChanges(of: settings)
    defer { NotificationCenter.default.removeObserver(observer) }
    var published = 0
    let subscription = settings.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }
    var revision = settings.terminalAppearanceRevision

    // Nothing on Interface reaches the terminal (its color scheme is the
    // default already).
    settings.reset(TerminalSettings.Setting.interfacePage)
    #expect(posts.value == 0)
    #expect(settings.terminalAppearanceRevision == revision)
    #expect(published == 2)
    #expect(settings.projectColorDisplayMode == .accent)
    #expect(settings.sidebarBackgroundDepth == 0.08)
    for setting in TerminalSettings.Setting.interfacePage {
        #expect(defaults.object(forKey: setting.rawValue) == nil, Comment(rawValue: setting.rawValue))
    }
    #expect(settings.fontSize == 16)

    // Notifications: none either.
    settings.reset(TerminalSettings.Setting.notificationsPage)
    #expect(posts.value == 0)
    #expect(!settings.notifyWhenBackgroundProgramFinishes)
    #expect(settings.terminalBell == .beep)
    #expect(defaults.object(forKey: "terminal.bell") == nil)
    #expect(defaults.object(forKey: "sessions.background.notifyFinished") == nil)

    // Themes and Terminal: four values, one change for the surfaces.
    settings.reset(TerminalSettings.Setting.themesPage + TerminalSettings.Setting.terminalPage)
    #expect(posts.value == 1)
    #expect(settings.terminalAppearanceRevision == revision &+ 1)
    #expect(settings.fontSize == 14)
    #expect(settings.cursorBlink)
    #expect(settings.darkTerminalThemeName == "Afterglow")
    #expect(settings.minimumContrast == 1.15)
    for setting in TerminalSettings.Setting.themesPage + TerminalSettings.Setting.terminalPage {
        #expect(defaults.object(forKey: setting.rawValue) == nil, Comment(rawValue: setting.rawValue))
        #expect(settings.source(of: setting) == .cherryDefault, Comment(rawValue: setting.rawValue))
    }

    // Values already at their default: the keys go, nothing is told.
    revision = settings.terminalAppearanceRevision
    settings.fontSize = 14
    #expect(posts.value == 2)
    settings.reset(TerminalSettings.Setting.terminalPage)
    #expect(posts.value == 2)
    #expect(settings.terminalAppearanceRevision == revision &+ 1)
    #expect(defaults.object(forKey: "terminal.fontSize") == nil)

    // A change after a reset is told and stored as before.
    settings.fontSize = 18
    #expect(posts.value == 3)
    #expect(defaults.object(forKey: "terminal.fontSize") as? Double == 18)
}

@Test @MainActor func settingsWindowChangesListAPagesSetHereValues() {
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowSources"), launchArguments: [:])
    settings.fontSize = 16
    settings.darkTerminalThemeName = "Dracula"
    settings.projectColorDisplayMode = .tinted
    settings.appearance = .system

    #expect(settings.changes(in: TerminalSettings.Setting.interfacePage) == [
        SettingsChange(title: "Project colors", from: "Tinted", to: "Accent"),
    ])
    #expect(settings.changes(in: TerminalSettings.Setting.themesPage) == [
        SettingsChange(title: "Dark Mode theme", from: "Dracula", to: "Afterglow"),
    ])
    #expect(settings.changes(in: TerminalSettings.Setting.terminalPage) == [
        SettingsChange(title: "Font size", from: "16 pt", to: "14 pt"),
    ])
    #expect(settings.changes(in: TerminalSettings.Setting.notificationsPage).isEmpty)
    #expect(SettingsChange(title: "Font size", from: "16 pt", to: "14 pt").text == "Font size 16 pt → 14 pt")
}

@Test @MainActor func settingsWindowPageResetAsksWithTheChanges() {
    let fontSize = SettingsChange(title: "Font size", from: "16 pt", to: "14 pt")
    let one = SettingsPageReset.confirmation(for: [fontSize], mentionsGhosttyConfig: false)
    #expect(one.title == "Reset 1 setting?")
    #expect(one.message == "Font size 16 pt → 14 pt.")
    let onTerminal = SettingsPageReset.confirmation(for: [fontSize], mentionsGhosttyConfig: true)
    #expect(onTerminal.message == "Font size 16 pt → 14 pt. Values from your Ghostty config stay.")

    let three = SettingsPageReset.confirmation(for: [
        fontSize,
        SettingsChange(title: "Dark Mode theme", from: "Dracula", to: "Afterglow"),
        SettingsChange(title: "Project colors", from: "Tinted", to: "Accent"),
    ], mentionsGhosttyConfig: false)
    #expect(three.title == "Reset 3 settings?")
    #expect(three.message
        == "Font size 16 pt → 14 pt · Dark Mode theme Dracula → Afterglow · Project colors Tinted → Accent.")

    // An example, from the settings.
    let settings = TerminalSettings(defaults: privateDefaults("SettingsWindowSources"), launchArguments: [:])
    settings.appearance = .dark
    settings.projectColorDisplayMode = .tinted
    let interface = SettingsPageReset.confirmation(
        for: settings.changes(in: TerminalSettings.Setting.interfacePage),
        mentionsGhosttyConfig: true
    )
    #expect(interface.title == "Reset 2 settings?")
    #expect(interface.message
        == "Color scheme Dark → Auto · Project colors Tinted → Accent. Values from your Ghostty config stay.")
}

@Test func settingsWindowStoredSourceOfAnyKey() {
    let defaults = privateDefaults("SettingsWindowSources")
    let key = "mcp.monitorWakeLines"
    func source(_ launchArguments: [String: Any] = [:]) -> SettingSource {
        SettingSource.stored(
            key: key,
            defaults: defaults,
            launchArguments: launchArguments,
            parses: { $0 is Bool },
            isDefault: { $0 as? Bool == true }
        )
    }

    #expect(source() == .cherryDefault)
    defaults.set(true, forKey: key)
    #expect(source() == .cherryDefault)
    defaults.set(false, forKey: key)
    #expect(source() == .setHere)
    defaults.set("NO", forKey: key)
    #expect(source() == .cherryDefault)
    #expect(source([key: false]) == .launchArgument(applied: true))
    #expect(source([key: true]) == .launchArgument(applied: true))
    #expect(source([key: "NO"]) == .launchArgument(applied: false))

    // Without `parses`, every stored value counts.
    defaults.set(true, forKey: "updates.prereleases")
    #expect(SettingSource.stored(
        key: "updates.prereleases",
        defaults: defaults,
        launchArguments: [:],
        isDefault: { $0 as? Bool == false }
    ) == .setHere)
}

@Test func settingsWindowBadgesSayWhereAValueComesFrom() {
    let config = URL(fileURLWithPath: "/Users/someone/.config/ghostty/config")
    let sources: [SettingSource] = [
        .cherryDefault, .setHere, .launchArgument(applied: true), .ghosttyConfig(file: config, line: 12),
        .projectFile, .overridesProjectFile, .thisMacOnly,
    ]
    #expect(sources.map(\.badgeText) == [
        nil, "Set here", "This run only", "Ghostty config", "cherry.toml", "Overrides cherry.toml", "This Mac only",
    ])
    #expect(sources.map(\.isEditable) == [true, true, false, false, true, true, true])
    #expect(sources.map(\.offersRowReset) == [false, true, false, false, false, true, false])
    #expect(SettingSource.launchArgument(applied: false).badgeText == "This run only")

    #expect(SettingSource.setHere.accessibilityLabel(defaultValue: "14 pt") == "Source: Set here. Default: 14 points.")
    #expect(SettingSource.cherryDefault.accessibilityLabel(defaultValue: nil) == "Source: Cherry default.")
    #expect(SettingSource.setHere.accessibilityLabel(defaultValue: "8 %") == "Source: Set here. Default: 8 percent.")
    #expect(SettingSource.setHere.accessibilityLabel(defaultValue: "1.15×") == "Source: Set here. Default: 1.15 times.")
    #expect(SettingSource.overridesProjectFile.accessibilityLabel(defaultValue: "Green")
        == "Source: Overrides cherry.toml. Default: Green.")

    #expect(SettingSource(ProjectValueSource.none) == .cherryDefault)
    #expect(SettingSource(ProjectValueSource.projectFile) == .projectFile)
    #expect(SettingSource(ProjectValueSource.overridesProjectFile) == .overridesProjectFile)
    #expect(SettingSource(ProjectValueSource.thisMacOnly) == .thisMacOnly)
}
