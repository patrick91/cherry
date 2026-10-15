import SwiftUI

/// What a tile shows: a glyph on a color. The sidebar's
/// pages, agents and projects each have one; so do page headers and status
/// headers.
struct SettingsTileStyle: Equatable, Sendable {
    enum Glyph: Equatable, Sendable {
        /// An SF Symbol: "sidebar.left", "folder.fill".
        case symbol(String)
        /// Up to two letters: an agent's "Cl".
        case letters(String)
        /// Cherry's brandmark (the menu bar item's glyph), white.
        case brandmark
    }

    var glyph: Glyph
    /// "#RRGGBB".
    var background: String
    /// "#RRGGBB": white, unless the tile says otherwise (Terminal's green).
    var foreground: String

    init(_ glyph: Glyph, background: String, foreground: String = "#FFFFFF") {
        self.glyph = glyph
        self.background = background
        self.foreground = foreground
    }

    /// Cherry's brandmark on its red: the Sessions status item and page,
    /// the Updates page.
    static let cherry = SettingsTileStyle(.brandmark, background: SettingsDesign.TileColors.cherry)

    /// An agent's: its letters ("Cl") on the agents' gray.
    static func agent(letters: String) -> SettingsTileStyle {
        SettingsTileStyle(.letters(letters), background: SettingsDesign.TileColors.agent)
    }

    /// A project's: a folder on its color, gray without one.
    static func project(color: ProjectIdentityColor?) -> SettingsTileStyle {
        SettingsTileStyle(.symbol("folder.fill"), background: color?.hexRGB ?? SettingsDesign.TileColors.projectWithoutColor)
    }
}

/// A tile: a glyph on a rounded square of color, 20, 30, 40 or 64 pt, lit
/// from the top as System Settings' icons are. Decorative: VoiceOver reads
/// the row's title instead.
struct SettingsTile: View {
    enum Size {
        /// The sidebar's rows, every one the same size, as System Settings'.
        case small
        /// List rows.
        case medium
        /// Status headers (`SettingsHero`).
        case large
        /// Page headers (`SettingsPageHeader`).
        case extraLarge

        var side: CGFloat {
            switch self {
            case .small: 20
            case .medium: 30
            case .large: 40
            case .extraLarge: 64
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .small: 5
            case .medium: 7.5
            case .large: 10
            case .extraLarge: 16
            }
        }

        /// A symbol's or the brandmark's size.
        var glyph: CGFloat {
            switch self {
            case .small: 14.5
            case .medium: 19
            case .large: 25
            case .extraLarge: 38
            }
        }

        var letters: CGFloat {
            switch self {
            case .small: 9.5
            case .medium: 12
            case .large: 15
            case .extraLarge: 24
            }
        }
    }

    /// How much lighter a tile is at its top edge than at its bottom.
    static let topLightening = 0.2

    let glyph: SettingsTileStyle.Glyph
    let color: Color
    let glyphColor: Color
    let size: Size

    init(_ style: SettingsTileStyle, size: Size = .small) {
        self.init(
            style.glyph,
            color: SettingsDesign.Colors.hex(style.background),
            glyphColor: SettingsDesign.Colors.hex(style.foreground),
            size: size
        )
    }

    /// An agent's tile, dimmed while it is off, as the sidebar's: Agents &
    /// MCP's list and the agent's page header.
    static func agent(letters: String, isOff: Bool, size: Size) -> SettingsTile {
        let opacity = isOff ? SettingsSidebarItems.offOpacity : 1
        let style = SettingsTileStyle.agent(letters: letters)
        return SettingsTile(
            style.glyph,
            color: SettingsDesign.Colors.hex(style.background).opacity(opacity),
            glyphColor: Color.white.opacity(opacity),
            size: size
        )
    }

    /// A tile of any color: a Mac's, which differs in light and dark.
    init(_ glyph: SettingsTileStyle.Glyph, color: Color, glyphColor: Color = .white, size: Size = .small) {
        self.glyph = glyph
        self.color = color
        self.glyphColor = glyphColor
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [color.mix(with: .white, by: Self.topLightening), color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
            }
            .overlay {
                glyphView
            }
            .frame(width: size.side, height: size.side)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size.glyph * 0.85, weight: .semibold))
                .foregroundStyle(glyphColor)
        case .letters(let letters):
            Text(letters)
                .font(.system(size: size.letters, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(glyphColor)
                .lineLimit(1)
        case .brandmark:
            Image(nsImage: MenuBarStatusLabel.icon(for: .none, dark: true, shimmerFrame: 0))
                .resizable()
                .scaledToFit()
                .frame(width: size.glyph * 0.8, height: size.glyph * 0.8)
        }
    }
}

/// A status header at the top of a card: a large tile, the
/// title (with a tag after it), a status line, and buttons at the
/// trailing end. The session host, each Mac, an update.
struct SettingsHero<TitleAccessory: View, Subtitle: View, Actions: View>: View {
    let tile: SettingsTile
    let title: String
    let titleAccessory: TitleAccessory
    let subtitle: Subtitle
    let actions: Actions

    init(
        tile: SettingsTile,
        title: String,
        @ViewBuilder titleAccessory: () -> TitleAccessory,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.tile = tile
        self.title = title
        self.titleAccessory = titleAccessory()
        self.subtitle = subtitle()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(SettingsDesign.Fonts.heroTitle)
                        .accessibilityAddTraits(.isHeader)
                    titleAccessory
                }
                subtitle
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                actions
            }
        }
        .padding(14)
    }
}

extension SettingsHero where TitleAccessory == EmptyView {
    init(
        tile: SettingsTile,
        title: String,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(tile: tile, title: title, titleAccessory: { EmptyView() }, subtitle: subtitle, actions: actions)
    }
}

extension SettingsHero where TitleAccessory == EmptyView, Subtitle == Text {
    init(tile: SettingsTile, title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.init(tile: tile, title: title, titleAccessory: { EmptyView() }, subtitle: { Text(subtitle) }, actions: actions)
    }
}

/// The big centered header of a detail page: an extra large
/// tile, the name, a line under it (a path in mono, a version) and the
/// page's buttons: an agent, a project, Updates.
struct SettingsPageHeader<Actions: View>: View {
    let tile: SettingsTile
    let title: String
    let subtitle: Text?
    let actions: Actions
    private let hasActions: Bool

    init(
        tile: SettingsTile,
        title: String,
        subtitle: String? = nil,
        monospacedSubtitle: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            tile: tile,
            title: title,
            styledSubtitle: subtitle.map { Text($0).font(monospacedSubtitle ? SettingsDesign.Fonts.pageHeaderMono : nil) },
            actions: actions
        )
    }

    /// `styledSubtitle`: a line with fonts of its own in places (Updates'
    /// version and build in mono); the rest in the subtitle's font.
    init(tile: SettingsTile, title: String, styledSubtitle: Text?, @ViewBuilder actions: () -> Actions) {
        self.tile = tile
        self.title = title
        subtitle = styledSubtitle
        self.actions = actions()
        hasActions = Actions.self != EmptyView.self
    }

    var body: some View {
        VStack(spacing: 4) {
            tile
            Text(title)
                .font(SettingsDesign.Fonts.pageHeaderTitle)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(SettingsDesign.Fonts.pageHeaderSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if hasActions {
                HStack(spacing: 8) {
                    actions
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

extension SettingsPageHeader where Actions == EmptyView {
    init(tile: SettingsTile, title: String, subtitle: String? = nil, monospacedSubtitle: Bool = false) {
        self.init(tile: tile, title: title, subtitle: subtitle, monospacedSubtitle: monospacedSubtitle) {
            EmptyView()
        }
    }
}
