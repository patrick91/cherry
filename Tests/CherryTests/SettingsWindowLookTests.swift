import Foundation
import SwiftUI
import Testing
@testable import Cherry

// Settings › Interface and Settings › Themes (Pages/InterfaceSettingsPage.swift,
// ThemesSettingsPage.swift, ThemeGallery.swift): the theme galleries, Show
// All Themes…'s filter and search, theme cards, the two pages' Reset… and
// their search rows. Private defaults only: nothing here reads the app's
// defaults or this run's launch arguments.

/// What `TerminalSettings` shows for a contrast ratio, in this locale.
private func ratioText(_ ratio: Double) -> String {
    "\(ratio.formatted(.number.precision(.fractionLength(2))))×"
}

/// The `.terminalSettingsDidChange` posts of one settings object.
private final class TerminalChangeCount: @unchecked Sendable {
    var value = 0
}

@MainActor
private func lookSettings(_ defaults: UserDefaults = privateDefaults("SettingsWindowLook")) -> TerminalSettings {
    TerminalSettings(defaults: defaults, launchArguments: [:])
}

private func cardNames(_ group: ThemeGallery.Group?) -> [String] {
    group?.cards.map(\.name) ?? []
}

// MARK: - Galleries

@Test @MainActor func settingsWindowLookCuratedThemesAreAllInGhosttysCatalog() throws {
    for appearance in ThemeAppearance.allCases {
        let settings = lookSettings()
        let names = [settings.defaultValueText(appearance.setting)] + appearance.builtInThemeNames
        for name in names {
            let card = try #require(ThemeCatalogCards.card(named: name), Comment(rawValue: name))
            // The terminal finds it too: its colors are the card's, not the
            // default's it falls back to for a name the catalog lacks.
            appearance.select(name, in: settings)
            let colors = settings.ghosttyThemeColors(for: appearance == .light ? .light : .dark)
            #expect(colors.background == card.background, Comment(rawValue: name))
            #expect(colors.foreground == card.foreground, Comment(rawValue: name))
            #expect(colors.selectionBackground == card.selectionBackground, Comment(rawValue: name))
            // A light gallery offers light themes, a dark one dark themes.
            #expect(card.isDark == (appearance == .dark), Comment(rawValue: name))
        }
    }
    #expect(ThemeAppearance.light.builtInThemeNames == ["Catppuccin Latte", "iTerm2 Solarized Light", "GitHub Light Default"])
    #expect(ThemeAppearance.dark.builtInThemeNames == ["Dracula", "Catppuccin Mocha", "TokyoNight", "Gruvbox Dark"])
}

@Test @MainActor func settingsWindowLookGalleriesShowTheDefaultThenTheBuiltInThemes() {
    let settings = lookSettings()
    for appearance in ThemeAppearance.allCases {
        let gallery = ThemeGallery(
            appearance: appearance,
            selection: appearance.themeName(in: settings),
            defaultName: settings.defaultValueText(appearance.setting)
        )
        #expect(gallery.groups.map(\.title) == ["Default", "Built-in"])
        #expect(cardNames(gallery.groups.last) == appearance.builtInThemeNames)
        // The default is selected, and nothing was added.
        #expect(gallery.selectedName == settings.defaultValueText(appearance.setting))
        #expect(gallery.groups.first.map { $0.cards.map(gallery.isSelected) } == [true])
        #expect(gallery.groups.last?.cards.contains(where: gallery.isSelected) == false)
    }

    let dark = ThemeGallery(appearance: .dark, selection: "Afterglow", defaultName: "Afterglow")
    #expect(cardNames(dark.groups.first) == ["Afterglow"])
    #expect(dark.accessibilityLabel(of: dark.groups[0]) == "Dark Mode: default theme")
    #expect(dark.accessibilityLabel(of: dark.groups[1]) == "Dark Mode: built-in themes")

    // A built-in theme is selected where it is.
    let dracula = ThemeGallery(appearance: .dark, selection: "Dracula", defaultName: "Afterglow")
    #expect(cardNames(dracula.groups.last) == ThemeAppearance.dark.builtInThemeNames)
    #expect(dracula.groups.last?.cards.filter(dracula.isSelected).map(\.name) == ["Dracula"])
    #expect(dracula.groups.first?.cards.contains(where: dracula.isSelected) == false)
}

@Test func settingsWindowLookASelectedThemeOutsideTheGalleryIsBuiltInsFirstCard() {
    let nord = ThemeGallery(appearance: .dark, selection: "Nord", defaultName: "Afterglow")
    #expect(cardNames(nord.groups.last) == ["Nord"] + ThemeAppearance.dark.builtInThemeNames)
    let first = nord.groups.last?.cards.first
    #expect(first?.isKnown == true)
    #expect(first.map(nord.isSelected) == true)

    // The other appearance's built-in themes are outside this one's.
    let latte = ThemeGallery(appearance: .dark, selection: "Catppuccin Latte", defaultName: "Afterglow")
    #expect(cardNames(latte.groups.last).first == "Catppuccin Latte")

    // The terminal reads the name trimmed; so does the gallery.
    let spaced = ThemeGallery(appearance: .dark, selection: " Dracula\n", defaultName: "Afterglow")
    #expect(spaced.selectedName == "Dracula")
    #expect(cardNames(spaced.groups.last) == ThemeAppearance.dark.builtInThemeNames)
}

@Test func settingsWindowLookAnUnknownThemeNameIsAWarningCard() throws {
    let gallery = ThemeGallery(appearance: .light, selection: "Not A Theme", defaultName: "Alabaster")
    let card = try #require(gallery.groups.last?.cards.first)
    #expect(!card.isKnown)
    #expect(card.name == "Not A Theme")
    #expect(card.title == "Not A Theme (unknown)")
    #expect(gallery.isSelected(card))
    #expect(cardNames(gallery.groups.last) == ["Not A Theme"] + ThemeAppearance.light.builtInThemeNames)
    #expect(ThemeCatalogCards.card(named: "Not A Theme") == nil)

    // No name selects nothing and adds no card.
    let empty = ThemeGallery(appearance: .light, selection: "  ", defaultName: "Alabaster")
    #expect(empty.selectedName == nil)
    #expect(cardNames(empty.groups.last) == ThemeAppearance.light.builtInThemeNames)
    #expect(!empty.groups.flatMap(\.cards).contains(where: empty.isSelected))
}

@Test func settingsWindowLookCardColorsComeFromTheThemesDefinition() throws {
    // Dracula's definition in the GhosttyTheme catalog.
    let dracula = try #require(ThemeCatalogCards.card(named: "Dracula"))
    #expect(dracula.title == "Dracula")
    #expect(dracula.isKnown)
    #expect(dracula.isDark)
    #expect(dracula.background == "282a36")
    #expect(dracula.foreground == "f8f8f2")
    #expect(dracula.selectionBackground == "44475a")
    #expect(dracula.cursor == "f8f8f2")
    // ANSI 0 to 7, in order: the bright colors are not on the card.
    #expect(dracula.palette == ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2"])

    let alabaster = try #require(ThemeCatalogCards.card(named: "Alabaster"))
    #expect(!alabaster.isDark)
    #expect(alabaster.palette.count == 8)
}

@Test @MainActor func settingsWindowLookThemeCardsCompareWhatTheyShow() throws {
    let dracula = try #require(ThemeCatalogCards.card(named: "Dracula"))
    let nord = try #require(ThemeCatalogCards.card(named: "Nord"))
    // The click is left out: a card redraws only when its theme or its
    // selection changes.
    #expect(ThemeCard(card: dracula, isSelected: true) {} == ThemeCard(card: dracula, isSelected: true) {})
    #expect(ThemeCard(card: dracula, isSelected: true) {} != ThemeCard(card: dracula, isSelected: false) {})
    #expect(ThemeCard(card: dracula, isSelected: false) {} != ThemeCard(card: nord, isSelected: false) {})
}

@Test @MainActor func settingsWindowLookSelectingAThemeStoresItAndPicksTheSameOneOnlyOnce() {
    let defaults = privateDefaults("SettingsWindowLook")
    let settings = lookSettings(defaults)
    let posts = TerminalChangeCount()
    let observer = NotificationCenter.default.addObserver(
        forName: .terminalSettingsDidChange,
        object: settings,
        queue: nil
    ) { _ in posts.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    ThemeAppearance.dark.select("Dracula", in: settings)
    #expect(settings.darkTerminalThemeName == "Dracula")
    #expect(defaults.string(forKey: "terminal.theme.dark") == "Dracula")
    #expect(settings.source(of: .darkTerminalThemeName) == .setHere)
    #expect(settings.lightTerminalThemeName == "Alabaster")
    #expect(posts.value == 1)

    // The theme in use again: the surfaces are left alone.
    ThemeAppearance.dark.select("Dracula", in: settings)
    #expect(posts.value == 1)

    ThemeAppearance.light.select("Catppuccin Latte", in: settings)
    #expect(ThemeAppearance.light.themeName(in: settings) == "Catppuccin Latte")
    #expect(posts.value == 2)
}

@Test func settingsWindowLookTheActiveSectionFollowsTheWindowsColorScheme() {
    #expect(ThemeAppearance(.light) == .light)
    #expect(ThemeAppearance(.dark) == .dark)
    #expect(ThemeAppearance.light.title == "Light Mode")
    #expect(ThemeAppearance.dark.caption == "Used while Cherry is dark.")
    #expect(ThemeAppearance.light.rowID == .themesLight)
    #expect(ThemeAppearance.dark.setting == .darkTerminalThemeName)
}

// MARK: - Show All Themes

@Test func settingsWindowLookShowAllThemesStartsAtItsSectionsAppearance() {
    #expect(ThemeBrowserFilter(.light) == .light)
    #expect(ThemeBrowserFilter(.dark) == .dark)
    #expect(ThemeBrowserFilter.allCases.map(\.title) == ["Light", "Dark", "All"])
}

@Test func settingsWindowLookShowAllThemesFiltersByBackgroundAndSearchesNames() {
    let all = ThemeBrowser.cards(matching: "", filter: .all)
    let light = ThemeBrowser.cards(matching: "", filter: .light)
    let dark = ThemeBrowser.cards(matching: "", filter: .dark)

    // Every theme once, by name, each light or dark.
    #expect(all == ThemeCatalogCards.all)
    #expect(all.count > 100)
    #expect(Set(all.map(\.name)).count == all.count)
    #expect(zip(all, all.dropFirst()).allSatisfy {
        $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedDescending
    })
    #expect(light.count + dark.count == all.count)
    #expect(light.allSatisfy { !$0.isDark })
    #expect(dark.allSatisfy { $0.isDark })

    // "drac" finds Dracula; case and accents are ignored.
    let found = ThemeBrowser.cards(matching: "drac", filter: .dark)
    #expect(found.contains { $0.name == "Dracula" })
    #expect(found.allSatisfy { $0.name.localizedCaseInsensitiveContains("drac") })
    #expect(ThemeBrowser.cards(matching: " DRÀC ", filter: .dark).map(\.name) == found.map(\.name))
    #expect(ThemeBrowser.cards(matching: "drac", filter: .all).contains { $0.name == "Dracula" })
    // Dracula is dark: the light filter leaves it out.
    #expect(!ThemeBrowser.cards(matching: "drac", filter: .light).contains { $0.name == "Dracula" })
    #expect(ThemeBrowser.cards(matching: "solarized light", filter: .light).map(\.name).contains("iTerm2 Solarized Light"))
    #expect(ThemeBrowser.cards(matching: "no theme is called this", filter: .all).isEmpty)

    #expect(ThemeBrowser.countText(1) == "1 theme")
    #expect(ThemeBrowser.countText(482) == "482 themes")
}

// MARK: - Page resets

@Test @MainActor func settingsWindowLookResetInterfaceListsAndResetsOnlyItsFourSettings() throws {
    let defaults = privateDefaults("SettingsWindowLook")
    let settings = lookSettings(defaults)
    settings.appearance = .dark
    settings.sidebarTerminalPathDisplayMode = .fullPath
    settings.projectColorDisplayMode = .tinted
    settings.sidebarBackgroundDepth = 0.12
    settings.darkTerminalThemeName = "Dracula"
    settings.minimumContrast = 1.5
    settings.fontSize = 16

    #expect(InterfaceSettingsPage.resetSettings == [
        .appearance, .sidebarTerminalPathDisplayMode, .projectColorDisplayMode, .sidebarBackgroundDepth,
    ])
    let changes = settings.changes(in: InterfaceSettingsPage.resetSettings)
    #expect(changes.map(\.title) == ["Color scheme", "Paths in the sidebar", "Project colors", "Sidebar contrast"])

    let confirmation = SettingsConfirmation.pageReset(changes: changes, mentionsGhosttyConfig: false) {
        settings.reset(InterfaceSettingsPage.resetSettings)
    }
    #expect(confirmation.title == "Reset 4 settings?")
    #expect(confirmation.message == "Color scheme Dark → Auto · Paths in the sidebar Full path → Repo focused · "
        + "Project colors Tinted → Accent · Sidebar contrast 12 % → 8 %.")
    #expect(confirmation.choices.map(\.title) == ["Reset", "Cancel"])
    try #require(confirmation.choices.first).perform()

    #expect(settings.appearance == .system)
    #expect(settings.sidebarTerminalPathDisplayMode == .repoFocused)
    #expect(settings.projectColorDisplayMode == .accent)
    #expect(settings.valueText(.sidebarBackgroundDepth) == "8 %")
    for setting in InterfaceSettingsPage.resetSettings {
        #expect(defaults.object(forKey: setting.rawValue) == nil, Comment(rawValue: setting.rawValue))
    }
    #expect(settings.changes(in: InterfaceSettingsPage.resetSettings).isEmpty)
    // The themes, the contrast and the font stay.
    #expect(settings.darkTerminalThemeName == "Dracula")
    #expect(settings.minimumContrast == 1.5)
    #expect(settings.fontSize == 16)
    #expect(settings.changes(in: ThemesSettingsPage.resetSettings).count == 2)
}

@Test @MainActor func settingsWindowLookResetThemesListsAndResetsBothThemesAndMinimumContrast() throws {
    let defaults = privateDefaults("SettingsWindowLook")
    let settings = lookSettings(defaults)
    settings.lightTerminalThemeName = "Catppuccin Latte"
    settings.darkTerminalThemeName = "Dracula"
    settings.minimumContrast = 1.5
    settings.appearance = .light
    settings.sidebarBackgroundDepth = 0.12

    #expect(ThemesSettingsPage.resetSettings == [.lightTerminalThemeName, .darkTerminalThemeName, .minimumContrast])
    let changes = settings.changes(in: ThemesSettingsPage.resetSettings)
    let confirmation = SettingsConfirmation.pageReset(changes: changes, mentionsGhosttyConfig: false) {
        settings.reset(ThemesSettingsPage.resetSettings)
    }
    #expect(confirmation.title == "Reset 3 settings?")
    #expect(confirmation.message == "Light Mode theme Catppuccin Latte → Alabaster · Dark Mode theme Dracula → Afterglow · "
        + "Minimum contrast \(ratioText(1.5)) → \(ratioText(1.15)).")
    try #require(confirmation.choices.first).perform()

    #expect(settings.lightTerminalThemeName == "Alabaster")
    #expect(settings.darkTerminalThemeName == "Afterglow")
    #expect(settings.isDefault(.minimumContrast))
    for setting in ThemesSettingsPage.resetSettings {
        #expect(defaults.object(forKey: setting.rawValue) == nil, Comment(rawValue: setting.rawValue))
    }
    // Interface's settings stay.
    #expect(settings.appearance == .light)
    #expect(settings.valueText(.sidebarBackgroundDepth) == "12 %")
    #expect(settings.changes(in: InterfaceSettingsPage.resetSettings).map(\.title) == ["Color scheme", "Sidebar contrast"])

    // Nothing left to reset: Reset Themes… is off.
    #expect(settings.changes(in: ThemesSettingsPage.resetSettings).isEmpty)
}

@Test @MainActor func settingsWindowLookPageResetsLeaveWhatALaunchArgumentSets() {
    let defaults = privateDefaults("SettingsWindowLook")
    defaults.set("tinted", forKey: TerminalSettings.Setting.projectColorDisplayMode.rawValue)
    defaults.set("Catppuccin Latte", forKey: TerminalSettings.Setting.lightTerminalThemeName.rawValue)
    let settings = TerminalSettings(defaults: defaults, launchArguments: [
        TerminalSettings.Setting.appearance.rawValue: "dark",
        TerminalSettings.Setting.darkTerminalThemeName.rawValue: "Dracula",
    ])

    // Read-only rows: the page disables their controls.
    #expect(!settings.source(of: .appearance).isEditable)
    #expect(!settings.source(of: .darkTerminalThemeName).isEditable)
    #expect(settings.source(of: .projectColorDisplayMode).isEditable)
    // The gallery shows the theme the argument sets.
    let gallery = ThemeGallery(
        appearance: .dark,
        selection: ThemeAppearance.dark.themeName(in: settings),
        defaultName: settings.defaultValueText(.darkTerminalThemeName)
    )
    #expect(gallery.selectedName == "Dracula")

    // Reset… lists and resets only what is Set here.
    #expect(settings.changes(in: InterfaceSettingsPage.resetSettings).map(\.title) == ["Project colors"])
    #expect(settings.changes(in: ThemesSettingsPage.resetSettings).map(\.title) == ["Light Mode theme"])
    settings.reset(InterfaceSettingsPage.resetSettings)
    settings.reset(ThemesSettingsPage.resetSettings)
    #expect(settings.appearance == .dark)
    #expect(settings.darkTerminalThemeName == "Dracula")
    #expect(settings.projectColorDisplayMode == .accent)
    #expect(settings.lightTerminalThemeName == "Alabaster")
}

// MARK: - Search

@MainActor
private func lookSearchContext(_ settings: TerminalSettings, defaults: UserDefaults) -> SettingsSearchContext {
    SettingsSearchContext(
        terminal: settings,
        agents: AgentSettings(defaults: defaults),
        defaults: defaults,
        homeDirectory: "/Users/someone"
    )
}

@Test @MainActor func settingsWindowLookSearchRowsShowTheValuesInUse() {
    let defaults = privateDefaults("SettingsWindowLook")
    let settings = lookSettings(defaults)
    let context = lookSearchContext(settings, defaults: defaults)

    let interface = InterfaceSettingsPage.searchRows(in: context)
    #expect(interface.map(\.id) == [.interfaceColorScheme, .interfacePaths, .interfaceProjectColors, .interfaceSidebarContrast])
    #expect(interface.map(\.value) == ["Auto", "Repo focused", "Accent", "8 %"])
    #expect(interface.allSatisfy { $0.route == .page(.interface) })

    let themes = ThemesSettingsPage.searchRows(in: context)
    #expect(themes.map(\.id) == [.themesLight, .themesDark, .themesMinimumContrast])
    #expect(themes.map(\.section) == ["Light Mode", "Dark Mode", "Readability"])
    #expect(themes.map(\.value) == ["Alabaster", "Afterglow", ratioText(1.15)])
    #expect(themes.allSatisfy { $0.route == .page(.themes) })

    settings.darkTerminalThemeName = "Dracula"
    settings.projectColorDisplayMode = .tinted
    #expect(ThemesSettingsPage.searchRows(in: context)[1].value == "Dracula")
    #expect(InterfaceSettingsPage.searchRows(in: context)[2].value == "Tinted")
}

@Test @MainActor func settingsWindowLookSearchFindsColorSchemeThemesAndBothContrasts() throws {
    let defaults = privateDefaults("SettingsWindowLook")
    let settings = lookSettings(defaults)
    let rows = SettingsSearchIndex.rows(in: lookSearchContext(settings, defaults: defaults))
    func results(_ query: String, on page: SettingsPage) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: rows)
            .first { $0.kind == .page(page) }?
            .results.map(\.id) ?? []
    }

    // "dark mode": Interface › Color scheme, by its words.
    #expect(results("dark mode", on: .interface).contains(.interfaceColorScheme))
    // "afterglow": Themes › Dark Mode, by its value.
    let afterglow = try #require(
        SettingsSearchIndex.groups(for: "afterglow", in: rows).first { $0.kind == .page(.themes) }
    )
    #expect(afterglow.results.map(\.id) == [.themesDark])
    #expect(afterglow.results.first?.row.detail == "Dark Mode · Afterglow")
    // "contrast": a row on each page.
    #expect(results("contrast", on: .interface).contains(.interfaceSidebarContrast))
    #expect(results("contrast", on: .themes).contains(.themesMinimumContrast))
}
