import SwiftUI

/// A row's id: where search, a link or `SettingsNavigator.open(_:row:)`
/// scrolls to and what it tints. Convention: `<page>.<name>`
/// ("terminal.fontSize"), `agent.<id>.<name>`, `project.<root>.<name>`,
/// `mac.<uuid>`. Ids that cross pages are defined once, in
/// SettingsNavigation.swift; each page defines its others.
struct SettingsRowID: Hashable, RawRepresentable, ExpressibleByStringLiteral, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }

    var description: String {
        rawValue
    }

    /// A row of an agent's page: "agent.claude.mcp" (the agent's
    /// `AgentToolDefinition.id`).
    static func agent(_ agentID: String, _ name: String) -> SettingsRowID {
        SettingsRowID(rawValue: "agent.\(agentID).\(name)")
    }

    /// A row of a project's page: "project.<root>.todos".
    static func project(_ root: String, _ name: String) -> SettingsRowID {
        SettingsRowID(rawValue: "project.\(root).\(name)")
    }

    /// A Mac's card on Macs: "mac.<uuid>".
    static func mac(_ deviceID: UUID) -> SettingsRowID {
        SettingsRowID(rawValue: "mac.\(deviceID.uuidString)")
    }
}

/// The row a search result or a link opened, which its page scrolls to the
/// middle and tints for a moment (`.settingsRow`, `SettingsPageScroll`).
/// Its own object, so a highlight re-renders the rows and not the sidebar
/// or the search results. The navigator flashes it from actions only.
@MainActor
final class SettingsRowHighlight: ObservableObject {
    /// How long after a flash a row that appears still shows it: the page
    /// a result opens is built on the next turn or two. A page shown again
    /// later (Back) does not flash.
    static let appearanceWindow: Duration = .seconds(1)
    /// The tint holds this long, then fades over `fadeDuration`.
    static let hold: Duration = .milliseconds(300)
    /// With Reduce Motion the page jumps to the row and the tint holds
    /// longer before it fades.
    static let reducedMotionHold: Duration = .seconds(1)
    static let fadeDuration = 1.5
    /// How long a page waits before it scrolls: one that just appeared is
    /// laid out first.
    static let layoutWait: Duration = .milliseconds(30)

    @Published private(set) var row: SettingsRowID?
    /// Bumped by every flash, also of the same row again.
    @Published private(set) var generation = 0

    private var flashedAt: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant

    /// `now`: tests pass their own clock.
    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Tints `row` and scrolls its page to it.
    func flash(_ row: SettingsRowID) {
        flashedAt = now()
        self.row = row
        generation += 1
    }

    /// Whether the latest flash is recent enough for a row that appears
    /// now to show it.
    var isRecent: Bool {
        guard let flashedAt else { return false }
        return now() - flashedAt < Self.appearanceWindow
    }

    /// Whether the row `id`, appearing now, shows the latest flash.
    func showsFlash(for id: SettingsRowID) -> Bool {
        row == id && isRecent
    }
}

extension EnvironmentValues {
    /// The Settings window's row highlight (`SettingsNavigator.highlight`).
    /// Nil outside the window's shell: rows then never tint.
    var settingsRowHighlight: SettingsRowHighlight? {
        get { self[SettingsRowHighlightKey.self] }
        set { self[SettingsRowHighlightKey.self] = newValue }
    }

    /// Whether the pointer is over the row around a view
    /// (`settingsHoverScope()`): the row's ↺ and "Default" show then.
    var settingsRowIsHovered: Bool {
        get { self[SettingsRowIsHoveredKey.self] }
        set { self[SettingsRowIsHoveredKey.self] = newValue }
    }
}

/// Spelled out rather than `@Entry`: that macro's plugin ships only with
/// Xcode (see `RemoteDeviceStoreKey`).
private struct SettingsRowHighlightKey: EnvironmentKey {
    static let defaultValue: SettingsRowHighlight? = nil
}

private struct SettingsRowIsHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension ContainerValues {
    /// Whether a card draws a separator above this child; never above its
    /// first, nor above a group label (`SettingsGroupLabel`).
    var settingsSeparatorAbove: Bool {
        get { self[SettingsSeparatorAboveKey.self] }
        set { self[SettingsSeparatorAboveKey.self] = newValue }
    }
}

private struct SettingsSeparatorAboveKey: ContainerValueKey {
    static let defaultValue = true
}

extension View {
    /// Makes this a row search and links can open: its id for
    /// scrolling, and the accent tint that fades out after a flash of it.
    /// Nil does nothing.
    func settingsRow(_ id: SettingsRowID?) -> some View {
        modifier(SettingsRowModifier(id: id))
    }

    /// Follows the pointer over this row, so its badge's "Default" and its
    /// ↺ show while it is hovered (`settingsRowIsHovered`).
    func settingsHoverScope() -> some View {
        modifier(SettingsHoverScope())
    }

    /// Whether the card this is in draws a separator above it.
    func settingsSeparatorAbove(_ shows: Bool) -> some View {
        containerValue(\.settingsSeparatorAbove, shows)
    }
}

private struct SettingsRowModifier: ViewModifier {
    let id: SettingsRowID?

    @Environment(\.settingsRowHighlight) private var highlight

    func body(content: Content) -> some View {
        if let id {
            content
                .background {
                    if let highlight {
                        SettingsRowTint(id: id, highlight: highlight)
                    }
                }
                .id(id)
        } else {
            content
        }
    }
}

/// The tint of a flashed row: the accent at about 15 %, which holds a
/// moment and fades over 1.5 s; with Reduce Motion it holds 1 s first.
private struct SettingsRowTint: View {
    let id: SettingsRowID
    @ObservedObject var highlight: SettingsRowHighlight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashes = 0
    @State private var opacity = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: SettingsDesign.Metrics.highlightRadius, style: .continuous)
            .fill(SettingsDesign.Colors.highlight)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                if highlight.showsFlash(for: id) { flashes += 1 }
            }
            .onChange(of: highlight.generation) { _, _ in
                if highlight.row == id { flashes += 1 }
            }
            .task(id: flashes) {
                guard flashes > 0 else { return }
                opacity = 1
                try? await Task.sleep(for: reduceMotion ? SettingsRowHighlight.reducedMotionHold : SettingsRowHighlight.hold)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: SettingsRowHighlight.fadeDuration)) {
                    opacity = 0
                }
            }
    }
}

private struct SettingsHoverScope: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .environment(\.settingsRowIsHovered, isHovered)
    }
}

// MARK: - Page

/// A Settings page: its toolbar title, the
/// accessory at the toolbar's trailing end (an agent's Enabled switch),
/// the 640 pt column, and scrolling to a flashed row. Every page's body is
/// one: `SettingsPageScroll("Terminal") { … }` or
/// `SettingsPageScroll("Claude", accessory: { … }) { … }`.
struct SettingsPageScroll<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let hasAccessory: Bool
    let content: Content

    @Environment(\.settingsRowHighlight) private var highlight

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        hasAccessory = true
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsDesign.Metrics.columnSpacing) {
                    content
                }
                .frame(maxWidth: SettingsDesign.Metrics.columnWidth, alignment: .topLeading)
                .padding(.horizontal, SettingsDesign.Metrics.pageHorizontalPadding)
                .padding(.top, SettingsDesign.Metrics.pageTopPadding)
                .padding(.bottom, SettingsDesign.Metrics.pageBottomPadding)
                .frame(maxWidth: .infinity)
            }
            .background {
                if let highlight {
                    SettingsHighlightScroller(highlight: highlight, proxy: proxy)
                }
            }
        }
        .background(SettingsDesign.Colors.window)
        .navigationTitle(title)
        .toolbar {
            if hasAccessory {
                ToolbarItem(placement: .primaryAction) {
                    accessory
                }
            }
        }
    }
}

extension SettingsPageScroll where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        hasAccessory = false
        self.content = content()
    }
}

/// Scrolls its page to a flashed row, to the middle of the view: on each
/// flash, and when the page appears just after one (a result opened it).
/// Animated unless Reduce Motion is on.
private struct SettingsHighlightScroller: View {
    @ObservedObject var highlight: SettingsRowHighlight
    let proxy: ScrollViewProxy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .task(id: highlight.generation) {
                guard let row = highlight.row, highlight.isRecent else { return }
                try? await Task.sleep(for: SettingsRowHighlight.layoutWait)
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    proxy.scrollTo(row, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(row, anchor: .center)
                    }
                }
            }
    }
}

// MARK: - Sections and cards

/// A section: its title above a borderless
/// card, then a caption. The header can carry a muted note ("— Active"),
/// the value's source badge and ↺, and a trailing link
/// (`SettingsLinkButton`: "+ Add Mac…", "Show All Themes…"); `intro` is a
/// caption above the card. The card draws separators between its rows.
/// No title: a card alone.
struct SettingsSection<Trailing: View, Content: View>: View {
    let title: String?
    let note: String?
    let source: SettingsSourceState?
    let intro: String?
    let caption: String?
    let id: SettingsRowID?
    let trailing: Trailing
    let content: Content

    init(
        _ title: String? = nil,
        note: String? = nil,
        source: SettingsSourceState? = nil,
        intro: String? = nil,
        caption: String? = nil,
        id: SettingsRowID? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.note = note
        self.source = source
        self.intro = intro
        self.caption = caption
        self.id = id
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsDesign.Metrics.columnSpacing) {
            if let title {
                SettingsSectionHeader(title, note: note, source: source) {
                    trailing
                }
            }
            if let intro {
                SettingsCaption(intro)
            }
            SettingsCardBody {
                content
            }
            if let caption {
                SettingsCaption(caption)
            }
        }
        .settingsRow(id)
    }
}

/// A section's title above its card or cards: a muted note ("— Active"),
/// the value's source badge and ↺, and a trailing link. A
/// `SettingsSection` has one above its card; Macs' "Your Macs" heads one
/// card per Mac.
struct SettingsSectionHeader<Trailing: View>: View {
    let title: String
    let note: String?
    let source: SettingsSourceState?
    let trailing: Trailing

    init(
        _ title: String,
        note: String? = nil,
        source: SettingsSourceState? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.note = note
        self.source = source
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(SettingsDesign.Fonts.sectionHeader)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(SettingsDesign.Fonts.rowTitle)
                    .foregroundStyle(.tertiary)
            }
            if let source {
                SettingsSourceBadge(state: source, title: title)
                SettingsResetButton(state: source)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .settingsHoverScope()
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(
        _ title: String? = nil,
        note: String? = nil,
        source: SettingsSourceState? = nil,
        intro: String? = nil,
        caption: String? = nil,
        id: SettingsRowID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            note: note,
            source: source,
            intro: intro,
            caption: caption,
            id: id,
            trailing: { EmptyView() },
            content: content
        )
    }
}

/// A card's surface: rows on the card color with a hairline
/// around it, and a separator between rows, inset like the rows' text.
private struct SettingsCardBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsDesign.Metrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                let firstID = subviews.first?.id
                ForEach(subviews) { subview in
                    if subview.id != firstID, subview.containerValues.settingsSeparatorAbove {
                        SettingsSeparator()
                    }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsDesign.Colors.card, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(SettingsDesign.Colors.cardBorder, lineWidth: 1)
        }
    }
}

/// The line between two rows of a card.
private struct SettingsSeparator: View {
    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        Rectangle()
            .fill(SettingsDesign.Colors.separator)
            .frame(height: max(pixelLength, 0.5))
            .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
            .accessibilityHidden(true)
    }
}

/// A short caption under or above a card; `.warning` in orange, `.error`
/// in red (why a change was refused).
struct SettingsCaption: View {
    enum Style {
        case plain
        case warning
        case error
    }

    let text: String
    var style: Style = .plain

    init(_ text: String, style: Style = .plain) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(SettingsDesign.Fonts.help)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    private var color: AnyShapeStyle {
        switch style {
        case .plain: AnyShapeStyle(.secondary)
        case .warning: AnyShapeStyle(SettingsDesign.Colors.warningText)
        case .error: AnyShapeStyle(SettingsDesign.Colors.dangerText)
        }
    }
}

/// A colored note under a row's help or in a card, selectable: `.warning`
/// in orange (a line left out, a file changed since Cherry opened),
/// `.error` in red (why a save or a check failed).
struct SettingsNote: View {
    enum Style {
        case warning
        case error
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(SettingsDesign.Fonts.help)
            .foregroundStyle(style == .warning ? SettingsDesign.Colors.warningText : SettingsDesign.Colors.dangerText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Rows

/// A setting's row: its title with the source badge and ↺
/// after it, help under it (one or two short sentences), anything else
/// under the help (`detail`: a tag, an orange note, Edit in Ghostty
/// Config), and the control at the trailing end. A row with an `id` can be
/// opened and flashed (`.settingsRow`).
struct SettingsItem<Control: View, Detail: View>: View {
    let id: SettingsRowID?
    let title: String
    let help: String?
    let source: SettingsSourceState?
    let control: Control
    let detail: Detail

    init(
        id: SettingsRowID? = nil,
        _ title: String,
        help: String? = nil,
        source: SettingsSourceState? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder detail: () -> Detail
    ) {
        self.id = id
        self.title = title
        self.help = help
        self.source = source
        self.control = control()
        self.detail = detail()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(SettingsDesign.Fonts.rowTitle)
                    if let source {
                        SettingsSourceBadge(state: source, title: title)
                        SettingsResetButton(state: source)
                    }
                }
                if let help {
                    Text(help)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, SettingsDesign.Metrics.rowVerticalPadding)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .frame(minHeight: SettingsDesign.Metrics.rowMinHeight)
        .settingsHoverScope()
        .settingsRow(id)
    }
}

extension SettingsItem where Detail == EmptyView {
    init(
        id: SettingsRowID? = nil,
        _ title: String,
        help: String? = nil,
        source: SettingsSourceState? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.init(id: id, title, help: help, source: source, control: control, detail: { EmptyView() })
    }
}

/// A row of a list in a card: its label (`SettingsListLabel`)
/// and trailing buttons. With `opens`, the label and a chevron are one
/// button that opens the item's page (an agent, a project), so the label
/// holds no buttons of its own; the trailing buttons stay apart.
struct SettingsListItem<Label: View, Trailing: View>: View {
    let id: SettingsRowID?
    let opens: (@MainActor () -> Void)?
    let label: Label
    let trailing: Trailing

    init(
        id: SettingsRowID? = nil,
        opens: (@MainActor () -> Void)? = nil,
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.id = id
        self.opens = opens
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let opens {
                Button(action: opens) {
                    HStack(spacing: 10) {
                        label
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing
        }
        .padding(.vertical, SettingsDesign.Metrics.listItemVerticalPadding)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .frame(minHeight: SettingsDesign.Metrics.rowMinHeight)
        .settingsHoverScope()
        .settingsRow(id)
    }
}

extension SettingsListItem where Trailing == EmptyView {
    init(id: SettingsRowID? = nil, opens: (@MainActor () -> Void)? = nil, @ViewBuilder label: () -> Label) {
        self.init(id: id, opens: opens, label: label, trailing: { EmptyView() })
    }
}

/// A list row's label: an optional tile, the title with anything after it
/// (tags, a badge), and a second line (a path or a command in mono,
/// truncated in the middle).
struct SettingsListLabel<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let monospacedSubtitle: Bool
    let tile: SettingsTile?
    let accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        monospacedSubtitle: Bool = false,
        tile: SettingsTile? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.monospacedSubtitle = monospacedSubtitle
        self.tile = tile
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let tile {
                tile
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(SettingsDesign.Fonts.rowTitle)
                        .lineLimit(1)
                    accessory
                }
                if let subtitle {
                    Text(subtitle)
                        .font(monospacedSubtitle ? SettingsDesign.Fonts.mono : SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

extension SettingsListLabel where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, monospacedSubtitle: Bool = false, tile: SettingsTile? = nil) {
        self.init(title, subtitle: subtitle, monospacedSubtitle: monospacedSubtitle, tile: tile, accessory: { EmptyView() })
    }
}

/// The chevron of a row that opens a page.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Free content in a card, between its rows: the ⌥ color
/// check, a command to copy.
struct SettingsSubItem<Content: View>: View {
    let id: SettingsRowID?
    let content: Content

    init(id: SettingsRowID? = nil, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .settingsRow(id)
    }
}

/// A disclosure's row in a card: a chevron that turns as it opens, and
/// its title. The whole row toggles it, animated unless Reduce Motion is
/// on; VoiceOver reads it as Expanded or Collapsed. What it shows goes
/// after it, while `isExpanded`.
struct SettingsDisclosureHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isExpanded: Binding<Bool>) {
        self.title = title
        _isExpanded = isExpanded
    }

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(title)
                    .font(SettingsDesign.Fonts.rowTitle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, SettingsDesign.Metrics.rowVerticalPadding)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .frame(minHeight: SettingsDesign.Metrics.rowMinHeight)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

extension View {
    /// Opens a disclosure when a search result or a link flashes `row`
    /// (on the flash, or as the page appears just after one), so what it
    /// found shows.
    func expandsWhenFlashed(_ row: SettingsRowID, isExpanded: Binding<Bool>) -> some View {
        modifier(SettingsExpandsWhenFlashed(row: row, isExpanded: isExpanded))
    }
}

private struct SettingsExpandsWhenFlashed: ViewModifier {
    let row: SettingsRowID
    @Binding var isExpanded: Bool

    @Environment(\.settingsRowHighlight) private var highlight

    func body(content: Content) -> some View {
        content.background {
            if let highlight {
                SettingsFlashExpander(row: row, highlight: highlight, isExpanded: $isExpanded)
            }
        }
    }
}

private struct SettingsFlashExpander: View {
    let row: SettingsRowID
    @ObservedObject var highlight: SettingsRowHighlight
    @Binding var isExpanded: Bool

    var body: some View {
        Color.clear
            .onAppear {
                if highlight.showsFlash(for: row) { isExpanded = true }
            }
            .onChange(of: highlight.generation) { _, _ in
                if highlight.row == row { isExpanded = true }
            }
    }
}

/// A small label inside a card, above the rows it names:
/// "Projects", "Lines left out". No separator above it.
struct SettingsGroupLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(SettingsDesign.Fonts.groupLabel)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
            .settingsSeparatorAbove(false)
    }
}

// MARK: - Footer

/// The bottom of a page: a caption at the leading end and the
/// page's buttons (Reset…, Delete Agent…) at the trailing end.
struct SettingsPageFooter<Buttons: View>: View {
    let caption: String?
    let buttons: Buttons

    init(caption: String? = nil, @ViewBuilder buttons: () -> Buttons) {
        self.caption = caption
        self.buttons = buttons()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let caption {
                Text(caption)
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            buttons
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
    }
}

/// A page's Reset…: off while nothing on the page is Set here;
/// it asks first, listing the changes (`SettingsPageReset.confirmation`),
/// with Reset and Cancel.
struct SettingsPageResetButton: View {
    let title: String
    let changes: [SettingsChange]
    let mentionsGhosttyConfig: Bool
    let reset: @MainActor () -> Void

    @State private var confirmation: SettingsConfirmation?

    init(
        _ title: String,
        changes: [SettingsChange],
        mentionsGhosttyConfig: Bool = false,
        reset: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.changes = changes
        self.mentionsGhosttyConfig = mentionsGhosttyConfig
        self.reset = reset
    }

    /// Resets the page's `settings` of `terminal` ("Reset Interface…" with
    /// `TerminalSettings.Setting.interfacePage`).
    init(
        _ title: String,
        settings: [TerminalSettings.Setting],
        in terminal: TerminalSettings,
        mentionsGhosttyConfig: Bool = false
    ) {
        self.init(title, changes: terminal.changes(in: settings), mentionsGhosttyConfig: mentionsGhosttyConfig) {
            terminal.reset(settings)
        }
    }

    var body: some View {
        Button(title) {
            confirmation = .pageReset(changes: changes, mentionsGhosttyConfig: mentionsGhosttyConfig, reset: reset)
        }
        .settingsButton()
        .disabled(changes.isEmpty)
        .settingsConfirmation($confirmation)
    }
}
