import AppKit
import SwiftUI

/// The Settings window's look: metrics, fonts and colors, light and dark.
/// Every page and component reads them here.
enum SettingsDesign {
    enum Metrics {
        /// The content column's width at most.
        static let columnWidth: CGFloat = 640
        static let pageHorizontalPadding: CGFloat = 28
        static let pageTopPadding: CGFloat = 6
        static let pageBottomPadding: CGFloat = 44
        /// Between a page's sections, cards and captions.
        static let columnSpacing: CGFloat = 8
        static let cardRadius: CGFloat = 14
        static let rowVerticalPadding: CGFloat = 11
        static let rowHorizontalPadding: CGFloat = 14
        static let rowMinHeight: CGFloat = 46
        static let listItemVerticalPadding: CGFloat = 9
        /// The tint of a row search or a link opened.
        static let highlightRadius: CGFloat = 10
    }

    enum Fonts {
        static let rowTitle = Font.system(size: 14)
        /// A row's help, a caption under a card, a status.
        static let help = Font.system(size: 12.5)
        static let sectionHeader = Font.system(size: 14, weight: .semibold)
        static let badge = Font.system(size: 10.5, weight: .semibold)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let groupLabel = Font.system(size: 12)
        static let heroTitle = Font.system(size: 15, weight: .semibold)
        static let pageHeaderTitle = Font.system(size: 24, weight: .bold)
        static let pageHeaderSubtitle = Font.system(size: 13.5)
        /// A page header's subtitle, or a value in it, in mono: a path, a
        /// command line, a version.
        static let pageHeaderMono = Font.system(size: 13, design: .monospaced)
        static let tag = Font.system(size: 11, weight: .medium)
        static let keycap = Font.system(size: 13, weight: .medium)
        static let link = Font.system(size: 13, weight: .medium)
        /// A slider's value, a read-only value.
        static let value = Font.system(size: 13)
    }

    enum Colors {
        /// Behind the page's column.
        static let window = adaptive(light: 0xF5F5F7, dark: 0x141416)
        static let card = adaptive(light: 0xFFFFFF, dark: 0x1F1F22)
        static let cardBorder = adaptive(light: 0x000000, lightAlpha: 0.06, dark: 0xFFFFFF, darkAlpha: 0.05)
        static let separator = adaptive(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.075)
        /// The three fills: a hover, a control's background (a chip, a
        /// tag, the search capsule), a pressed or selected one.
        static let fill = adaptive(light: 0x000000, lightAlpha: 0.045, dark: 0xFFFFFF, darkAlpha: 0.06)
        static let fill2 = adaptive(light: 0x000000, lightAlpha: 0.075, dark: 0xFFFFFF, darkAlpha: 0.095)
        static let fill3 = adaptive(light: 0x000000, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.15)
        /// A highlighted row: the accent color at about 15 %.
        static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.controlAccentColor.withAlphaComponent(isDark(appearance) ? 0.24 : 0.15)
        })
        static let warningText = adaptive(light: 0x955000, dark: 0xFFB454)
        static let warningFill = adaptive(light: 0xFF9500, lightAlpha: 0.15, dark: 0xFF9F0A, darkAlpha: 0.14)
        static let okText = adaptive(light: 0x1C7733, dark: 0x62D480)
        static let dangerText = adaptive(light: 0xC1271A, dark: 0xFF7B70)
        static let dotGreen = adaptive(light: 0x28C840, dark: 0x30D158)
        static let dotYellow = adaptive(light: 0xF5B400, dark: 0xF5B400)
        static let dotOrange = adaptive(light: 0xFF9500, dark: 0xFF9F0A)
        static let dotRed = adaptive(light: 0xFF453A, dark: 0xFF453A)
        static let dotGray = adaptive(light: 0x8E8E93, dark: 0x76767E)

        /// A color for light and dark appearances, from sRGB hex values.
        static func adaptive(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                isDark(appearance) ? rgb(dark, alpha: darkAlpha) : rgb(light, alpha: lightAlpha)
            })
        }

        /// A tile's or a swatch's color from "#RRGGBB"; gray when it does
        /// not read as one.
        static func hex(_ hexRGB: String) -> Color {
            Color(nsColor: NSColor(hexRGB: hexRGB) ?? .systemGray)
        }

        private static func isDark(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private static func rgb(_ value: UInt32, alpha: Double) -> NSColor {
            NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    /// The tiles' colors ("#RRGGBB"), by what they stand for: the
    /// sidebar's pages, Cherry's brandmark, agents and projects.
    enum TileColors {
        static let cherry = "#D9354A"
        static let interface = "#6366F1"
        static let themes = "#EC4899"
        static let terminal = "#232326"
        /// The Terminal tile's glyph, on its near-black tile.
        static let terminalGlyph = "#4ADE80"
        static let shortcuts = "#8E8E93"
        static let notifications = "#F97316"
        static let macs = "#0A84FF"
        static let agents = "#A855F7"
        static let projects = "#D98E04"
        static let updates = "#22A55B"
        /// Every agent's letter tile.
        static let agent = "#55555C"
        /// A project without a color of its own.
        static let projectWithoutColor = "#7C7C84"
    }

    /// How a source badge looks: its fill, its text and, for
    /// This run only, an outline instead of a fill. The words carry the
    /// meaning; color never does alone.
    struct BadgeStyle {
        var fill: Color
        var text: Color
        var outline: Color?
    }

    /// The badge of `source`; nil for Cherry's default, which has none.
    static func badgeStyle(for source: SettingSource) -> BadgeStyle? {
        switch source {
        case .cherryDefault:
            nil
        case .setHere:
            BadgeStyle(fill: Badges.setHereFill, text: Badges.setHereText)
        case .ghosttyConfig:
            BadgeStyle(fill: Badges.ghosttyFill, text: Badges.ghosttyText)
        case .projectFile:
            BadgeStyle(fill: Badges.projectFileFill, text: Badges.projectFileText)
        case .overridesProjectFile:
            BadgeStyle(fill: Badges.overridesFill, text: Badges.overridesText)
        case .thisMacOnly:
            BadgeStyle(fill: Badges.thisMacFill, text: Badges.thisMacText)
        case .launchArgument:
            BadgeStyle(fill: .clear, text: Badges.thisMacText, outline: Badges.launchArgumentOutline)
        }
    }

    private enum Badges {
        static let setHereFill = Colors.adaptive(light: 0x007AFF, lightAlpha: 0.12, dark: 0x0A84FF, darkAlpha: 0.22)
        static let setHereText = Colors.adaptive(light: 0x0052B0, dark: 0x9CCBFF)
        static let ghosttyFill = Colors.adaptive(light: 0x8C46DC, lightAlpha: 0.12, dark: 0xAF6EFF, darkAlpha: 0.22)
        static let ghosttyText = Colors.adaptive(light: 0x6529AD, dark: 0xD2B0FF)
        static let projectFileFill = Colors.adaptive(light: 0x30AA50, lightAlpha: 0.15, dark: 0x30D158, darkAlpha: 0.18)
        static let projectFileText = Colors.adaptive(light: 0x1A642D, dark: 0x8FE3A6)
        static let overridesFill = Colors.adaptive(light: 0xFF9500, lightAlpha: 0.19, dark: 0xFF9F0A, darkAlpha: 0.22)
        static let overridesText = Colors.adaptive(light: 0x834300, dark: 0xFFC680)
        static let thisMacFill = Colors.adaptive(light: 0x787880, lightAlpha: 0.14, dark: 0x9696A0, darkAlpha: 0.2)
        static let thisMacText = Colors.adaptive(light: 0x46464D, dark: 0xD0D0D6)
        static let launchArgumentOutline = Colors.adaptive(light: 0x76767E, dark: 0x8C8C94)
    }
}

// MARK: - Buttons

/// What a Settings button does: a row's action, the page's
/// main action (at most one per page) or a destructive one, which asks
/// first.
enum SettingsButtonKind {
    /// A glass button.
    case standard
    /// A prominent glass button: Add Project…, Add Mac…, Restart to Update.
    case primary
    /// A glass button in red text; give the button `role: .destructive`.
    case danger
}

enum SettingsButtonSize {
    case regular
    /// Under a row's control and in lists: Edit in Ghostty Config, Open.
    case small
}

extension View {
    /// The Settings look for a button: standard, primary or danger, regular
    /// or small.
    func settingsButton(_ kind: SettingsButtonKind = .standard, size: SettingsButtonSize = .regular) -> some View {
        modifier(SettingsButtonModifier(kind: kind, size: size))
    }
}

// MARK: - Controls

extension View {
    /// A menu picker in a row: a pop-up showing its value; its label
    /// hidden, since the row has the title.
    func settingsMenuPicker() -> some View {
        pickerStyle(.menu).labelsHidden().fixedSize()
    }

    /// An on/off control on a page (pages use switches, sheets
    /// checkboxes); its label hidden.
    func settingsSwitch() -> some View {
        toggleStyle(.switch).labelsHidden()
    }

    /// A text field in a row: a command, a Mac's name.
    func settingsTextField(mono: Bool = false) -> some View {
        textFieldStyle(.roundedBorder)
            .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
            .frame(minWidth: 200, maxWidth: 320)
    }
}

private struct SettingsButtonModifier: ViewModifier {
    let kind: SettingsButtonKind
    let size: SettingsButtonSize

    func body(content: Content) -> some View {
        styled(content)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(size == .small ? .small : .regular)
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        switch kind {
        case .standard:
            content.buttonStyle(.glass)
        case .primary:
            content.buttonStyle(.glassProminent)
        case .danger:
            content.buttonStyle(.glass).foregroundStyle(SettingsDesign.Colors.dangerText)
        }
    }
}
