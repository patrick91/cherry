import AppKit
import GhosttyTheme
import SwiftUI

// MARK: - Light and dark

/// The two terminal themes Settings › Themes picks: the one used while
/// Cherry is light and the one used while it is dark. Each has a section
/// with its gallery and its Show All Themes… sheet.
enum ThemeAppearance: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    /// The one `colorScheme` shows: its section says "— Active".
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .light ? .light : .dark
    }

    /// Its section's title: "Light Mode".
    var title: String {
        switch self {
        case .light: "Light Mode"
        case .dark: "Dark Mode"
        }
    }

    var setting: TerminalSettings.Setting {
        switch self {
        case .light: .lightTerminalThemeName
        case .dark: .darkTerminalThemeName
        }
    }

    /// The caption under its gallery.
    var caption: String {
        switch self {
        case .light: "Used while Cherry is light."
        case .dark: "Used while Cherry is dark."
        }
    }

    var rowID: SettingsRowID {
        switch self {
        case .light: .themesLight
        case .dark: .themesDark
        }
    }

    /// The gallery's built-in themes after the default, by the catalog's
    /// names (iTerm2 Solarized Light, GitHub Light Default, TokyoNight).
    var builtInThemeNames: [String] {
        switch self {
        case .light: ["Catppuccin Latte", "iTerm2 Solarized Light", "GitHub Light Default"]
        case .dark: ["Dracula", "Catppuccin Mocha", "TokyoNight", "Gruvbox Dark"]
        }
    }
}

@MainActor
extension ThemeAppearance {
    /// The theme name `settings` stores for this appearance.
    func themeName(in settings: TerminalSettings) -> String {
        switch self {
        case .light: settings.lightTerminalThemeName
        case .dark: settings.darkTerminalThemeName
        }
    }

    /// Uses `name` for this appearance. Picking the theme in use again
    /// does nothing: each change makes every surface apply its settings.
    func select(_ name: String, in settings: TerminalSettings) {
        guard themeName(in: settings) != name else { return }
        switch self {
        case .light: settings.lightTerminalThemeName = name
        case .dark: settings.darkTerminalThemeName = name
        }
    }
}

// MARK: - Cards

/// What a theme card shows: a theme's colors as its definition
/// gives them (hex, with or without "#"), and its name. A stored name no
/// theme has gets a card of its own, with ⚠.
struct ThemeCardModel: Equatable, Identifiable, Sendable {
    /// The theme's name, as the setting stores it.
    var name: String
    var background: String
    var foreground: String
    /// Behind the "~/"; nil when the theme sets none.
    var selectionBackground: String?
    var cursor: String
    /// The ANSI colors 0 to 7 the theme sets, in order.
    var palette: [String]
    /// Whether its background reads as dark (`GhosttyThemeDefinition.isDark`).
    var isDark: Bool
    /// False for a stored name no theme has.
    var isKnown: Bool

    var id: String { name }

    init(_ theme: GhosttyThemeDefinition) {
        name = theme.name
        background = theme.background
        foreground = theme.foreground
        selectionBackground = theme.selectionBackground
        cursor = theme.cursorColor ?? theme.foreground
        palette = (0...7).compactMap { theme.palette[$0] }
        isDark = theme.isDark
        isKnown = true
    }

    private init(unknownName name: String) {
        self.name = name
        background = ""
        foreground = ""
        selectionBackground = nil
        cursor = ""
        palette = []
        isDark = false
        isKnown = false
    }

    /// The card of a stored name no theme has.
    static func unknown(_ name: String) -> ThemeCardModel {
        ThemeCardModel(unknownName: name)
    }

    /// Its caption: "Dracula", or "Nord Light (unknown)".
    var title: String {
        isKnown ? name : "\(name) (unknown)"
    }
}

/// Every Ghostty theme's card, made once: the galleries and Show All
/// Themes read them here, never the whole catalog on each update.
enum ThemeCatalogCards {
    /// Sorted by name, ignoring case: Show All Themes…'s order.
    static let all: [ThemeCardModel] = byName.values.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    static let byName: [String: ThemeCardModel] = Dictionary(
        GhosttyThemeCatalog.allThemes.map { ($0.name, ThemeCardModel($0)) },
        uniquingKeysWith: { first, _ in first }
    )

    static func card(named name: String) -> ThemeCardModel? {
        byName[name]
    }
}

// MARK: - Gallery

/// A Themes section's gallery: its default theme, then a few
/// built-in ones. A selected theme in neither group is the first card of
/// Built-in, so the selection always shows; a stored name no theme has is a
/// card with ⚠ there (the terminal then uses the default).
struct ThemeGallery: Equatable, Sendable {
    struct Group: Equatable, Identifiable, Sendable {
        enum Kind: Sendable {
            case standard
            case builtIn
        }

        var kind: Kind
        var cards: [ThemeCardModel]

        var id: Kind { kind }

        /// "Default", "Built-in".
        var title: String {
            switch kind {
            case .standard: "Default"
            case .builtIn: "Built-in"
            }
        }
    }

    var appearance: ThemeAppearance
    var groups: [Group]
    /// The name the selected card has: the stored one, trimmed as the
    /// terminal reads it. Nil when it is empty.
    var selectedName: String?

    /// `defaultName`: the setting's default theme
    /// (`TerminalSettings.defaultValueText`).
    init(appearance: ThemeAppearance, selection: String, defaultName: String) {
        self.appearance = appearance
        let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedName = selected.isEmpty ? nil : selected

        let standard = [ThemeCatalogCards.card(named: defaultName)].compactMap { $0 }
        var builtIn = appearance.builtInThemeNames
            .filter { $0 != defaultName }
            .compactMap(ThemeCatalogCards.card(named:))
        if let selectedName, !(standard + builtIn).contains(where: { $0.name == selectedName }) {
            builtIn.insert(ThemeCatalogCards.card(named: selectedName) ?? .unknown(selectedName), at: 0)
        }
        groups = [Group(kind: .standard, cards: standard), Group(kind: .builtIn, cards: builtIn)]
            .filter { !$0.cards.isEmpty }
    }

    func isSelected(_ card: ThemeCardModel) -> Bool {
        card.name == selectedName
    }

    /// What VoiceOver calls a group: "Dark Mode: built-in themes".
    func accessibilityLabel(of group: Group) -> String {
        switch group.kind {
        case .standard: "\(appearance.title): default theme"
        case .builtIn: "\(appearance.title): built-in themes"
        }
    }
}

// MARK: - Show All Themes

/// Which themes Show All Themes… lists, by their background. It starts at
/// its section's appearance.
enum ThemeBrowserFilter: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case all

    var id: String { rawValue }

    init(_ appearance: ThemeAppearance) {
        self = appearance == .light ? .light : .dark
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .all: "All"
        }
    }

    func includes(_ card: ThemeCardModel) -> Bool {
        switch self {
        case .light: !card.isDark
        case .dark: card.isDark
        case .all: true
        }
    }
}

/// What Show All Themes… lists.
enum ThemeBrowser {
    /// The themes of `cards` that `filter` includes and whose names contain
    /// `query` (case and accents ignored), in their order.
    static func cards(
        matching query: String,
        filter: ThemeBrowserFilter,
        in cards: [ThemeCardModel] = ThemeCatalogCards.all
    ) -> [ThemeCardModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            filter.includes(card)
                && (query.isEmpty || card.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// "482 themes", "1 theme".
    static func countText(_ count: Int) -> String {
        count == 1 ? "1 theme" : "\(count) themes"
    }
}

// MARK: - Views

/// A theme card: a 128 × 76 preview (the background, "Aa" in
/// the text color, "~/" on the selection color, the cursor and the eight
/// ANSI colors) above the name; an accent ring when selected. Equatable on
/// what it shows, so a gallery or the sheet redraws only the cards whose
/// selection changed.
struct ThemeCard: View, Equatable {
    static let previewSize = CGSize(width: 128, height: 76)

    let card: ThemeCardModel
    let isSelected: Bool
    let select: @MainActor () -> Void

    nonisolated static func == (lhs: ThemeCard, rhs: ThemeCard) -> Bool {
        lhs.card == rhs.card && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: select) {
            VStack(spacing: 7) {
                preview
                    .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(SettingsDesign.Colors.fill3, lineWidth: 1)
                    }
                    .padding(4)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                Text(card.title)
                    .font(SettingsDesign.Fonts.help)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: Self.previewSize.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(card.title)
        .accessibilityLabel(card.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        if card.isKnown {
            let background = SettingsDesign.Colors.hex(card.background)
            let foreground = SettingsDesign.Colors.hex(card.foreground)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Aa")
                        .font(.system(size: 19))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("~/")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .padding(4)
                        .background(
                            card.selectionBackground.map(SettingsDesign.Colors.hex) ?? foreground.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SettingsDesign.Colors.hex(card.cursor))
                        .frame(width: 7, height: 17)
                }
                .foregroundStyle(foreground)
                Spacer(minLength: 0)
                HStack(spacing: -3) {
                    ForEach(Array(card.palette.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(SettingsDesign.Colors.hex(color))
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle().strokeBorder(background, lineWidth: 1.5)
                            }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .accessibilityHidden(true)
        } else {
            SettingsDesign.Colors.fill2
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(SettingsDesign.Colors.warningText)
                }
                .accessibilityHidden(true)
        }
    }
}

/// A section's gallery in its card: the groups side by side,
/// a line between them, scrolling sideways when they are wider than the
/// card. A click uses the theme.
struct ThemeGalleryView: View {
    let gallery: ThemeGallery
    let select: @MainActor (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(gallery.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(SettingsDesign.Colors.separator)
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                            .padding(.top, 24)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text(group.title)
                            .font(SettingsDesign.Fonts.groupLabel)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(group.cards) { card in
                                ThemeCard(card: card, isSelected: gallery.isSelected(card)) {
                                    select(card.name)
                                }
                                .equatable()
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(gallery.accessibilityLabel(of: group))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
            .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
            .padding(.bottom, 14)
        }
    }
}

/// Show All Themes… (a sheet): every Ghostty theme as a card, with a
/// search field and Light / Dark / All, starting at its section's
/// appearance. A click uses the theme at once (no preview on hover: that
/// would make every surface apply it); Done closes. The grid is lazy and
/// its cards are made once (`ThemeCatalogCards`), never a menu of every
/// theme.
struct ThemeBrowserSheet: View {
    @ObservedObject var settings: TerminalSettings
    let appearance: ThemeAppearance

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter: ThemeBrowserFilter
    @FocusState private var searchIsFocused: Bool

    init(settings: TerminalSettings, appearance: ThemeAppearance) {
        self.settings = settings
        self.appearance = appearance
        _filter = State(initialValue: ThemeBrowserFilter(appearance))
    }

    var body: some View {
        let cards = ThemeBrowser.cards(matching: query, filter: filter)
        let selection = appearance.themeName(in: settings).trimmingCharacters(in: .whitespacesAndNewlines)
        let isEditable = settings.source(of: appearance.setting).isEditable

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(appearance.setting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Picker("Show", selection: $filter) {
                    ForEach(ThemeBrowserFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)

            ScrollViewReader { proxy in
                ScrollView {
                    if cards.isEmpty {
                        Text("No themes match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                            .font(SettingsDesign.Fonts.help)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: ThemeCard.previewSize.width + 8), spacing: 12, alignment: .top)],
                            spacing: 16
                        ) {
                            ForEach(cards) { card in
                                ThemeCard(card: card, isSelected: card.name == selection) {
                                    appearance.select(card.name, in: settings)
                                }
                                .equatable()
                                .id(card.name)
                            }
                        }
                        .padding(.vertical, 4)
                        .disabled(!isEditable)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Themes")
                    }
                }
                .task {
                    // Opens at the theme in use, once the grid is laid out.
                    try? await Task.sleep(for: SettingsRowHighlight.layoutWait)
                    guard !Task.isCancelled, cards.contains(where: { $0.name == selection }) else { return }
                    proxy.scrollTo(selection, anchor: .center)
                }
            }

            HStack(spacing: 10) {
                Text(ThemeBrowser.countText(cards.count))
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button("Done") {
                    dismiss()
                }
                .settingsButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Fits the Settings window at its smallest (520 pt tall).
        .frame(width: 640, height: 500)
        .onAppear {
            searchIsFocused = true
        }
        .onExitCommand {
            dismiss()
        }
    }
}
