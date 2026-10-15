import SwiftUI

/// Settings › Themes: the terminal's theme while Cherry is light and while
/// it is dark, each a gallery of a few themes with Show All Themes… for
/// the rest, and the minimum contrast.
struct ThemesSettingsPage: View, SettingsPageContent {
    /// What Reset Themes… resets: both themes and the minimum contrast.
    static let resetSettings = TerminalSettings.Setting.themesPage

    @ObservedObject private var settings: TerminalSettings

    @Environment(\.colorScheme) private var colorScheme
    /// The section whose Show All Themes… sheet is open.
    @State private var browsing: ThemeAppearance?

    init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.themes.title) {
            themeSection(.light)
            themeSection(.dark)

            SettingsSection("Readability") {
                SettingsItem(
                    id: .themesMinimumContrast,
                    TerminalSettings.Setting.minimumContrast.title,
                    help: Self.minimumContrastHelp,
                    source: .terminal(.minimumContrast, in: settings)
                ) {
                    SettingsSliderControl(
                        TerminalSettings.Setting.minimumContrast.title,
                        value: $settings.minimumContrast,
                        in: 1...2,
                        step: 0.05,
                        valueText: settings.valueText(.minimumContrast)
                    )
                    .disabled(!settings.source(of: .minimumContrast).isEditable)
                }
            }

            SettingsPageFooter(caption: "Resets both themes and minimum contrast.") {
                SettingsPageResetButton("Reset Themes…", settings: Self.resetSettings, in: settings)
            }
        }
        .sheet(item: $browsing) { appearance in
            ThemeBrowserSheet(settings: settings, appearance: appearance)
        }
    }

    /// "Light Mode" or "Dark Mode": the gallery, "— Active" on the one the
    /// window shows, the theme's badge and ↺, and Show All Themes….
    private func themeSection(_ appearance: ThemeAppearance) -> some View {
        let isEditable = settings.source(of: appearance.setting).isEditable
        return SettingsSection(
            appearance.title,
            note: ThemeAppearance(colorScheme) == appearance ? "— Active" : nil,
            source: .terminal(appearance.setting, in: settings),
            caption: appearance.caption,
            id: appearance.rowID
        ) {
            SettingsLinkButton("Show All Themes…") {
                browsing = appearance
            }
            .help("Opens a searchable list of every Ghostty theme")
            .disabled(!isEditable)
        } content: {
            ThemeGalleryView(
                gallery: ThemeGallery(
                    appearance: appearance,
                    selection: appearance.themeName(in: settings),
                    defaultName: settings.defaultValueText(appearance.setting)
                )
            ) { name in
                appearance.select(name, in: settings)
            }
            // A launch argument sets it: the cards dim, as Interface's
            // Color scheme thumbnails do, and take no click.
            .opacity(isEditable ? 1 : 0.5)
            .disabled(!isEditable)
        }
    }

    private static let minimumContrastHelp =
        "Lightens or darkens text that's too close to its background. At 1× the theme's colors are left as they are."

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let terminal = context.terminal
        let themeWords = ["theme", "colors", "color scheme", "palette", "ghostty"]
        return ThemeAppearance.allCases.map { appearance in
            SettingsSearchRow(
                id: appearance.rowID,
                route: .page(.themes),
                section: appearance.title,
                title: appearance.setting.title,
                help: appearance.caption,
                keywords: themeWords,
                value: terminal.valueText(appearance.setting)
            )
        } + [
            SettingsSearchRow(
                id: .themesMinimumContrast,
                route: .page(.themes),
                section: "Readability",
                title: TerminalSettings.Setting.minimumContrast.title,
                help: minimumContrastHelp,
                keywords: ["contrast", "readability", "accessibility"],
                value: terminal.valueText(.minimumContrast)
            ),
        ]
    }
}

extension SettingsRowID {
    static let themesLight: Self = "themes.light"
    static let themesDark: Self = "themes.dark"
    static let themesMinimumContrast: Self = "themes.minimumContrast"
}
