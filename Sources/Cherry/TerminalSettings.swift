import GhosttyTerminal
import GhosttyTheme
import SwiftUI

enum CherryAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func toggled(
        from appearance: CherryAppearancePreference,
        currentColorScheme: ColorScheme
    ) -> CherryAppearancePreference {
        switch appearance {
        case .system:
            currentColorScheme == .dark ? .light : .dark
        case .light:
            .dark
        case .dark:
            .light
        }
    }
}

enum SidebarTerminalPathDisplayMode: String, CaseIterable, Identifiable {
    case repoFocused
    case smartInitials
    case fullPath

    var id: String { rawValue }

    var label: String {
        switch self {
        case .repoFocused: "Repo focused"
        case .smartInitials: "Smart initials"
        case .fullPath: "Full path"
        }
    }
}

enum ProjectColorDisplayMode: String, CaseIterable, Identifiable {
    case off
    case accent
    case tinted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .accent: "Accent"
        case .tinted: "Tinted"
        }
    }
}

extension Notification.Name {
    static let terminalSettingsDidChange = Notification.Name("Cherry.terminalSettingsDidChange")
}

struct TerminalThemeColors: Equatable {
    let background: String
    let foreground: String
    let selectionBackground: String?
    let palette: [Int: String]
}

@MainActor
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    @Published var fontSize: Double {
        didSet { save(fontSize, forKey: Keys.fontSize) }
    }

    @Published var cursorBlink: Bool {
        didSet { save(cursorBlink, forKey: Keys.cursorBlink) }
    }

    @Published var minimumContrast: Double {
        didSet { save(minimumContrast, forKey: Keys.minimumContrast) }
    }

    @Published var sidebarBackgroundDepth: Double {
        didSet {
            save(sidebarBackgroundDepth, forKey: Keys.sidebarBackgroundDepth, notifyTerminal: false)
        }
    }

    @Published var sidebarTerminalPathDisplayMode: SidebarTerminalPathDisplayMode {
        didSet {
            save(sidebarTerminalPathDisplayMode.rawValue, forKey: Keys.sidebarTerminalPathDisplayMode, notifyTerminal: false)
        }
    }

    @Published var projectColorDisplayMode: ProjectColorDisplayMode {
        didSet {
            save(projectColorDisplayMode.rawValue, forKey: Keys.projectColorDisplayMode, notifyTerminal: false)
        }
    }

    @Published var appearance: CherryAppearancePreference {
        didSet { save(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var lightTerminalThemeName: String {
        didSet { save(lightTerminalThemeName, forKey: Keys.lightTerminalThemeName) }
    }

    @Published var darkTerminalThemeName: String {
        didSet { save(darkTerminalThemeName, forKey: Keys.darkTerminalThemeName) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Defaults.fontSize
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? Defaults.cursorBlink
        minimumContrast = defaults.object(forKey: Keys.minimumContrast) as? Double ?? Defaults.minimumContrast
        sidebarBackgroundDepth = defaults.object(forKey: Keys.sidebarBackgroundDepth) as? Double
            ?? Defaults.sidebarBackgroundDepth
        sidebarTerminalPathDisplayMode = (defaults.object(forKey: Keys.sidebarTerminalPathDisplayMode) as? String)
            .flatMap(SidebarTerminalPathDisplayMode.init(rawValue:)) ?? Defaults.sidebarTerminalPathDisplayMode
        projectColorDisplayMode = (defaults.object(forKey: Keys.projectColorDisplayMode) as? String)
            .flatMap(ProjectColorDisplayMode.init(rawValue:)) ?? Defaults.projectColorDisplayMode
        appearance = (defaults.object(forKey: Keys.appearance) as? String)
            .flatMap(CherryAppearancePreference.init(rawValue:)) ?? Defaults.appearance
        lightTerminalThemeName = defaults.object(forKey: Keys.lightTerminalThemeName) as? String
            ?? Defaults.lightTerminalThemeName
        darkTerminalThemeName = defaults.object(forKey: Keys.darkTerminalThemeName) as? String
            ?? Defaults.darkTerminalThemeName
    }

    func resetTerminalAppearance() {
        fontSize = Defaults.fontSize
        cursorBlink = Defaults.cursorBlink
        minimumContrast = Defaults.minimumContrast
        sidebarBackgroundDepth = Defaults.sidebarBackgroundDepth
        sidebarTerminalPathDisplayMode = Defaults.sidebarTerminalPathDisplayMode
        projectColorDisplayMode = Defaults.projectColorDisplayMode
        lightTerminalThemeName = Defaults.lightTerminalThemeName
        darkTerminalThemeName = Defaults.darkTerminalThemeName
    }

    func toggleLightDarkAppearance(currentColorScheme: ColorScheme) {
        appearance = CherryAppearancePreference.toggled(
            from: appearance,
            currentColorScheme: currentColorScheme
        )
    }

    func ghosttyConfiguration() -> TerminalConfiguration {
        Self.ghosttyConfiguration(
            fontSize: fontSize,
            cursorBlink: cursorBlink,
            minimumContrast: minimumContrast
        )
    }

    static func ghosttyConfiguration(
        fontSize: Double,
        cursorBlink: Bool,
        minimumContrast: Double
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily("Menlo")
            builder.withFontSize(Float(fontSize))
            builder.withCursorStyle(.bar)
            builder.withCursorStyleBlink(cursorBlink)
            builder.withMinimumContrast(minimumContrast)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(14)
            builder.withCustom("scrollback-limit", "\(Defaults.ghosttyScrollbackLimitBytes)")
        }
    }

    func ghosttyTheme() -> TerminalTheme {
        TerminalTheme(
            light: terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
                .toTerminalConfiguration(),
            dark: terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
                .toTerminalConfiguration()
        )
    }

    func ghosttyThemeColors(for colorScheme: ColorScheme) -> TerminalThemeColors {
        let theme = switch colorScheme {
        case .light:
            terminalTheme(named: lightTerminalThemeName, fallback: Defaults.lightTerminalThemeName)
        case .dark:
            terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
        @unknown default:
            terminalTheme(named: darkTerminalThemeName, fallback: Defaults.darkTerminalThemeName)
        }

        return TerminalThemeColors(
            background: theme.background,
            foreground: theme.foreground,
            selectionBackground: theme.selectionBackground,
            palette: theme.palette
        )
    }

    func isKnownGhosttyTheme(_ name: String) -> Bool {
        GhosttyThemeCatalog.theme(named: name.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func save(_ value: Double, forKey key: String, notifyTerminal: Bool = true) {
        defaults.set(value, forKey: key)
        if notifyTerminal {
            notifyChanged()
        }
    }

    private func save(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChanged()
    }

    private func save(_ value: String, forKey key: String, notifyTerminal: Bool = true) {
        defaults.set(value, forKey: key)
        if notifyTerminal {
            notifyChanged()
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .terminalSettingsDidChange, object: self)
    }

    private enum Defaults {
        static let fontSize = 14.0
        static let cursorBlink = true
        static let minimumContrast = 1.15
        static let ghosttyScrollbackLimitBytes = 4_000_000
        static let sidebarBackgroundDepth = 0.08
        static let sidebarTerminalPathDisplayMode = SidebarTerminalPathDisplayMode.repoFocused
        static let projectColorDisplayMode = ProjectColorDisplayMode.accent
        static let appearance = CherryAppearancePreference.system
        static let lightTerminalThemeName = "Alabaster"
        static let darkTerminalThemeName = "Afterglow"
    }

    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let cursorBlink = "terminal.cursorBlink"
        static let minimumContrast = "terminal.minimumContrast"
        static let sidebarBackgroundDepth = "sidebar.backgroundDepth"
        static let sidebarTerminalPathDisplayMode = "sidebar.terminalPathDisplayMode"
        static let projectColorDisplayMode = "sidebar.projectColorDisplayMode"
        static let appearance = "appearance.theme"
        static let lightTerminalThemeName = "terminal.theme.light"
        static let darkTerminalThemeName = "terminal.theme.dark"
    }

    private func terminalTheme(named name: String, fallback: String) -> GhosttyThemeDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return GhosttyThemeCatalog.theme(named: trimmedName)
            ?? GhosttyThemeCatalog.theme(named: fallback)
            ?? .afterglow
    }
}
