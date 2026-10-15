import SwiftUI

// MARK: - Pickers

/// A row of color swatches, with an optional text button
/// before them ("Automatic", "None"): a Mac's color, a project's. The
/// selected one has an accent ring; VoiceOver reads each by its name.
struct SettingsSwatchPicker<Value: Hashable>: View {
    struct Swatch {
        var value: Value
        /// The color's name: its label and tooltip.
        var name: String
        var color: Color

        init(_ value: Value, name: String, color: Color) {
            self.value = value
            self.name = name
            self.color = color
        }
    }

    /// The text button before the swatches.
    struct Leading {
        var title: String
        var value: Value

        init(_ title: String, value: Value) {
            self.title = title
            self.value = value
        }
    }

    let label: String
    @Binding var selection: Value
    let swatches: [Swatch]
    let leading: Leading?

    /// `label`: what VoiceOver calls the group ("Color").
    init(_ label: String, selection: Binding<Value>, swatches: [Swatch], leading: Leading? = nil) {
        self.label = label
        _selection = selection
        self.swatches = swatches
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 0) {
            if let leading {
                let isSelected = selection == leading.value
                Button(leading.title) {
                    selection = leading.value
                }
                .settingsButton(.standard, size: .small)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .padding(.trailing, 8)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                let isSelected = selection == swatch.value
                Button {
                    selection = swatch.value
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 20, height: 20)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if isSelected {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A picker of thumbnails with captions: Interface's Color
/// scheme. Its title sits above the thumbnails, with the source badge and
/// ↺; the page draws each thumbnail.
struct SettingsVisualPicker<Value: Hashable, Thumbnail: View>: View {
    struct Option {
        var value: Value
        var caption: String

        init(_ value: Value, caption: String) {
            self.value = value
            self.caption = caption
        }
    }

    static var thumbnailSize: CGSize { CGSize(width: 92, height: 62) }

    let id: SettingsRowID?
    let title: String
    @Binding var selection: Value
    let options: [Option]
    let source: SettingsSourceState?
    let thumbnail: (Value) -> Thumbnail

    init(
        id: SettingsRowID? = nil,
        _ title: String,
        selection: Binding<Value>,
        options: [Option],
        source: SettingsSourceState? = nil,
        @ViewBuilder thumbnail: @escaping (Value) -> Thumbnail
    ) {
        self.id = id
        self.title = title
        _selection = selection
        self.options = options
        self.source = source
        self.thumbnail = thumbnail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(SettingsDesign.Fonts.groupLabel)
                    .foregroundStyle(.secondary)
                if let source {
                    SettingsSourceBadge(state: source, title: title)
                    SettingsResetButton(state: source)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    item(option)
                }
            }
            // A value a launch argument or the Ghostty config sets: the
            // thumbnails take no clicks, the badge still opens.
            .disabled(source.map { !$0.source.isEditable } ?? false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
        .padding(.bottom, 14)
        .settingsHoverScope()
        .settingsRow(id)
    }

    private func item(_ option: Option) -> some View {
        let isSelected = option.value == selection
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button {
            selection = option.value
        } label: {
            VStack(spacing: 7) {
                thumbnail(option.value)
                    .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(SettingsDesign.Colors.fill3, lineWidth: 1)
                    }
                    .padding(4)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                Text(option.caption)
                    .font(SettingsDesign.Fonts.help)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A slider with its value after it: "16 pt",
/// "1.15×", "8 %". `valueText` is what the row shows
/// (`TerminalSettings.valueText`).
struct SettingsSliderControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, valueText: String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(label)
                .accessibilityValue(valueText)
            Text(valueText)
                .font(SettingsDesign.Fonts.value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 220, maxWidth: 300)
    }
}

// MARK: - Keys

/// Keycap chips: one chip per shortcut, its parts spaced
/// ("⇧ ⌘ D"). Several chips: alternatives with "/" between them (⌘[ / ⌘]),
/// or a sequence with "›". Its texts are pure functions, usable off the
/// main actor.
struct SettingsKeycaps: View {
    let chips: [[String]]
    let separator: String

    /// One shortcut: ["⇧", "⌘", "D"].
    init(parts: [String]) {
        self.init(chips: [parts])
    }

    init(chips: [[String]], separator: String = "/") {
        self.chips = chips
        self.separator = separator
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, parts in
                if index > 0 {
                    Text(separator)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                }
                Text(Self.text(for: parts))
                    .font(SettingsDesign.Fonts.keycap)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(SettingsDesign.Colors.fill2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(chips: chips, separator: separator))
    }

    /// A chip's text: "⇧ ⌘ D".
    nonisolated static func text(for parts: [String]) -> String {
        parts.joined(separator: " ")
    }

    /// The parts of a shortcut as menus write it: "⇧⌘D" is ["⇧", "⌘",
    /// "D"]: each modifier glyph, then the key.
    nonisolated static func parts(of display: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(display.trimmingCharacters(in: .whitespaces))
        while let first = rest.first, modifierNames[String(first)] != nil {
            parts.append(String(first))
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        if !rest.isEmpty {
            parts.append(String(rest))
        }
        return parts
    }

    /// What VoiceOver reads for one shortcut: "Shift Command D".
    nonisolated static func spokenName(for parts: [String]) -> String {
        parts.map { modifierNames[$0] ?? keyNames[$0] ?? $0 }.joined(separator: " ")
    }

    /// "Command Left Bracket or Command Right Bracket"; a sequence reads
    /// "…, then …".
    nonisolated static func accessibilityLabel(chips: [[String]], separator: String) -> String {
        chips.map(spokenName).joined(separator: separator == "/" ? " or " : ", then ")
    }

    /// The modifier glyphs, in the order menus write them.
    private nonisolated static let modifierNames = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]

    private nonisolated static let keyNames = [
        "↩": "Return", "⏎": "Return", "⌫": "Delete", "⌦": "Forward Delete", "⎋": "Escape", "⇥": "Tab",
        "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow", "⇞": "Page Up",
        "⇟": "Page Down", "↖": "Home", "↘": "End", "␣": "Space", ",": "Comma", ".": "Period", "/": "Slash",
        "\\": "Backslash", ";": "Semicolon", "'": "Quote", "`": "Backtick", "[": "Left Bracket",
        "]": "Right Bracket", "-": "Minus", "=": "Equals",
    ]
}

// MARK: - Copying

/// A copy icon button: it copies `text` (`SettingsActions.copy`), or
/// runs its own copy, and shows a checkmark for 1.5 s.
struct SettingsCopyButton: View {
    static let checkmarkDuration: Duration = .milliseconds(1500)

    let label: String
    private let copy: @MainActor (SettingsActions) -> Void

    @Environment(\.settingsActions) private var actions
    @State private var copies = 0
    @State private var showsCheckmark = false

    /// `label`: its tooltip and VoiceOver label ("Copy command").
    init(text: String, label: String = "Copy") {
        self.label = label
        copy = { actions in actions.copy(text) }
    }

    /// Copies with `copy` (the session host's socket path, which its
    /// diagnostics copy).
    init(label: String, copy: @escaping @MainActor () -> Void) {
        self.label = label
        self.copy = { _ in copy() }
    }

    var body: some View {
        Button {
            copy(actions)
            copies += 1
        } label: {
            Image(systemName: showsCheckmark ? "checkmark" : "doc.on.doc")
                .frame(width: 14)
        }
        .settingsButton(.standard, size: .small)
        .help(label)
        .accessibilityLabel(showsCheckmark ? "Copied" : label)
        .task(id: copies) {
            guard copies > 0 else { return }
            showsCheckmark = true
            try? await Task.sleep(for: Self.checkmarkDuration)
            guard !Task.isCancelled else { return }
            showsCheckmark = false
        }
    }
}

/// A value to read and copy: a path, a socket, a destination; in mono by
/// default, truncated in the middle, selectable.
struct SettingsCopyableValue: View {
    let text: String
    let mono: Bool
    let copyLabel: String

    init(text: String, mono: Bool = true, copyLabel: String = "Copy") {
        self.text = text
        self.mono = mono
        self.copyLabel = copyLabel
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(mono ? SettingsDesign.Fonts.mono : SettingsDesign.Fonts.value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            SettingsCopyButton(text: text, label: copyLabel)
        }
    }
}

/// A command to read and copy: in mono, wrapping, with the
/// copy button at its top.
struct SettingsCodeBlock: View {
    let text: String
    let copyLabel: String

    init(text: String, copyLabel: String = "Copy command") {
        self.text = text
        self.copyLabel = copyLabel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(SettingsDesign.Fonts.mono)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsCopyButton(text: text, label: copyLabel)
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(SettingsDesign.Colors.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Buttons

/// An icon-only button: Reveal in Finder's folder. Its
/// label is its tooltip and what VoiceOver reads.
struct SettingsIconButton: View {
    let label: String
    let systemImage: String
    let size: SettingsButtonSize
    /// What VoiceOver says when the tooltip alone does not tell rows apart
    /// ("Reveal ~/.config/ghostty/config in Finder"); nil: `label`.
    let accessibilityLabel: String?
    let action: @MainActor () -> Void

    init(
        _ label: String,
        systemImage: String,
        size: SettingsButtonSize = .small,
        accessibilityLabel: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 14)
        }
        .settingsButton(.standard, size: size)
        .help(label)
        .accessibilityLabel(accessibilityLabel ?? label)
    }
}

/// A `···` button holding a row's other actions: "More actions for Mac
/// mini".
struct SettingsMoreMenu<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .settingsButton(.standard, size: .small)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// An accent text button: a section's "+ Add Mac…", "Show All
/// Themes…", "Open Persistent Sessions…".
struct SettingsLinkButton: View {
    let title: String
    let action: @MainActor () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(SettingsDesign.Fonts.link)
            .foregroundStyle(Color.accentColor)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Status

/// A message at the top of a page: a warning (orange, with
/// its icon) or information, its message selectable, and its buttons.
struct SettingsBanner<Buttons: View>: View {
    enum Style {
        case warning
        case info
    }

    let style: Style
    let title: String
    let message: String?
    let buttons: Buttons

    init(_ style: Style, title: String, message: String? = nil, @ViewBuilder buttons: () -> Buttons) {
        self.style = style
        self.title = title
        self.message = message
        self.buttons = buttons()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsDesign.Metrics.cardRadius, style: .continuous)
        HStack(spacing: 12) {
            if style == .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SettingsDesign.Colors.warningText)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if let message {
                    Text(message)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                buttons
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(style == .warning ? SettingsDesign.Colors.warningFill : SettingsDesign.Colors.card, in: shape)
        .overlay {
            if style == .info {
                shape.strokeBorder(SettingsDesign.Colors.cardBorder, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension SettingsBanner where Buttons == EmptyView {
    init(_ style: Style, title: String, message: String? = nil) {
        self.init(style, title: title, message: message) {
            EmptyView()
        }
    }
}

/// A status dot: green running, yellow checking or
/// restarting, orange unavailable, red failed, gray off.
struct SettingsStatusDot: View {
    enum Tone {
        case green
        case yellow
        case orange
        case red
        case gray
    }

    let tone: Tone

    init(_ tone: Tone) {
        self.tone = tone
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .green: SettingsDesign.Colors.dotGreen
        case .yellow: SettingsDesign.Colors.dotYellow
        case .orange: SettingsDesign.Colors.dotOrange
        case .red: SettingsDesign.Colors.dotRed
        case .gray: SettingsDesign.Colors.dotGray
        }
    }
}

/// A short status, with a dot before it: "Listening" in green,
/// "Not listening" in orange, "Not checked" in secondary text.
struct SettingsStatusText: View {
    enum Style {
        case ok
        case warning
        case neutral
    }

    let text: String
    let style: Style
    let dot: SettingsStatusDot.Tone?

    init(_ text: String, style: Style = .neutral, dot: SettingsStatusDot.Tone? = nil) {
        self.text = text
        self.style = style
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                SettingsStatusDot(dot)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(SettingsDesign.Fonts.help)
        .foregroundStyle(foreground)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .ok: AnyShapeStyle(SettingsDesign.Colors.okText)
        case .warning: AnyShapeStyle(SettingsDesign.Colors.warningText)
        case .neutral: AnyShapeStyle(.secondary)
        }
    }
}

/// A tag after a title: "Skips permission prompts", "Off",
/// "Update available"; `.warning` in orange ("No command").
struct SettingsTag: View {
    enum Style {
        case plain
        case warning
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .plain) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(SettingsDesign.Fonts.tag)
            .lineLimit(1)
            .foregroundStyle(style == .warning ? AnyShapeStyle(SettingsDesign.Colors.warningText) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(
                style == .warning ? SettingsDesign.Colors.warningFill : SettingsDesign.Colors.fill2,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .fixedSize()
    }
}

/// A list's empty state: its symbol, title, one sentence and,
/// below, the add button.
struct SettingsEmptyState<Action: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let action: Action
    private let hasAction: Bool

    init(title: String, message: String, systemImage: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.action = action()
        hasAction = Action.self != EmptyView.self
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if hasAction {
                action
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

extension SettingsEmptyState where Action == EmptyView {
    /// No button: search's no results, a read-only copy's Macs.
    init(title: String, message: String, systemImage: String) {
        self.init(title: title, message: message, systemImage: systemImage) {
            EmptyView()
        }
    }
}
