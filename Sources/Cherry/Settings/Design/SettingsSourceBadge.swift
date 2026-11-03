import SwiftUI

/// One button a row offers about its value: a source popover's button, or
/// the row's ↺. Its title names the result ("Reset to default (14 pt)",
/// "Revert to cherry.toml (Green)"). Not `SettingsActions`, which is what
/// Settings asks of the app.
struct SettingsAction {
    var title: String
    var role: ButtonRole?
    var perform: @MainActor () -> Void

    init(_ title: String, role: ButtonRole? = nil, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.role = role
        self.perform = perform
    }
}

/// What a row's source badge, its popover and its ↺ show: where the value
/// comes from, the sources from the top with the
/// one in use marked, the source's buttons, and the ↺, which never asks.
/// Pages build it with a convenience (`terminal`, `stored`, `project`,
/// `ghosttyConfig`, `app`) and hand it to `SettingsItem(source:)`,
/// `SettingsSection(source:)` or `SettingsSourceBadge`.
struct SettingsSourceState {
    /// One source the popover lists.
    struct Line: Equatable {
        /// "Set here", "Cherry default", "Ghostty config", "This run only",
        /// "This Mac", "cherry.toml".
        var source: String
        /// Its value, as the row shows it: "16 pt", "Green".
        var value: String?
        /// More about it: "~/.config/ghostty/config, line 12",
        /// "-terminal.fontSize", "Not used while a launch argument sets it".
        var detail: String?
        /// Whether the row's value comes from it.
        var isInUse: Bool

        init(_ source: String, value: String? = nil, detail: String? = nil, isInUse: Bool = false) {
            self.source = source
            self.value = value
            self.detail = detail
            self.isInUse = isInUse
        }
    }

    var source: SettingSource
    /// The default as the row shows it ("14 pt"), for VoiceOver's label.
    var defaultText: String?
    /// The sources from the top.
    var lines: [Line]
    /// A sentence under the lines.
    var note: String?
    /// The popover's buttons.
    var buttons: [SettingsAction]
    /// What ↺ does; it shows only where the source offers it (Set here,
    /// Overrides cherry.toml: `rowReset`).
    var reset: SettingsAction?

    init(
        source: SettingSource,
        defaultText: String? = nil,
        lines: [Line] = [],
        note: String? = nil,
        buttons: [SettingsAction] = [],
        reset: SettingsAction? = nil
    ) {
        self.source = source
        self.defaultText = defaultText
        self.lines = lines
        self.note = note
        self.buttons = buttons
        self.reset = reset
    }

    /// The badge's words; nil for Cherry's default.
    var badgeText: String? {
        source.badgeText
    }

    /// The row's ↺: only for Set here and Overrides cherry.toml.
    var rowReset: SettingsAction? {
        source.offersRowReset ? reset : nil
    }

    /// "Source: Set here. Default: 14 points."
    var accessibilityLabel: String {
        source.accessibilityLabel(defaultValue: defaultText)
    }
}

// MARK: - Conveniences

extension SettingsSourceState {
    /// An app setting's state: This run only, else Set here,
    /// else Cherry's default. `value` and `defaultValue` as the row shows
    /// them ("16 pt"); `launchArgument` is the argument's name
    /// ("-terminal.fontSize"); `reset` puts the default back and removes the
    /// stored value.
    static func app(
        source: SettingSource,
        value: String,
        defaultValue: String,
        launchArgument: String,
        reset: (@MainActor () -> Void)?
    ) -> SettingsSourceState {
        var lines: [Line] = []
        var note: String?
        var buttons: [SettingsAction] = []
        var resetAction: SettingsAction?
        switch source {
        case .launchArgument(let applied):
            lines.append(Line(
                "This run only",
                value: applied ? value : nil,
                detail: applied ? launchArgument : "\(launchArgument): not one of its values",
                isInUse: true
            ))
            lines.append(Line("Set here", detail: "Not used while a launch argument sets it"))
            lines.append(Line("Cherry default", value: defaultValue))
            note = applied
                ? "A launch argument sets it until Cherry quits, so it can't be changed here."
                : "The launch argument isn't one of its values, so Cherry uses its default until it quits."
        case .setHere:
            lines.append(Line("Set here", value: value, isInUse: true))
            lines.append(Line("Cherry default", value: defaultValue))
            if let reset {
                let action = SettingsAction(resetTitle(defaultValue), perform: reset)
                buttons.append(action)
                resetAction = action
            }
        case .cherryDefault, .ghosttyConfig, .projectFile, .overridesProjectFile, .thisMacOnly:
            // The others are not an app setting's sources (`ghosttyConfig`,
            // `project`): its default is in use.
            lines.append(Line("Set here", detail: "Not set"))
            lines.append(Line("Cherry default", value: defaultValue, isInUse: true))
        }
        return SettingsSourceState(
            source: source,
            defaultText: defaultValue,
            lines: lines,
            note: note,
            buttons: buttons,
            reset: resetAction
        )
    }

    /// The state of one of `settings`' values; ↺ and Reset to default run
    /// `settings.reset([setting])`.
    @MainActor
    static func terminal(_ setting: TerminalSettings.Setting, in settings: TerminalSettings) -> SettingsSourceState {
        app(
            source: settings.source(of: setting),
            value: settings.valueText(setting),
            defaultValue: settings.defaultValueText(setting),
            launchArgument: "-\(setting.rawValue)",
            reset: { settings.reset([setting]) }
        )
    }

    /// The state of a value stored under `key` that no Ghostty config or
    /// project sets (Wake idle agents, pre-release builds), by
    /// `SettingSource.stored`. `reset` puts the default back.
    static func stored(
        key: String,
        defaults: UserDefaults,
        launchArguments: [String: Any],
        value: String,
        defaultValue: String,
        parses: (Any) -> Bool = { _ in true },
        isDefault: (Any) -> Bool,
        reset: @escaping @MainActor () -> Void
    ) -> SettingsSourceState {
        app(
            source: SettingSource.stored(
                key: key,
                defaults: defaults,
                launchArguments: launchArguments,
                parses: parses,
                isDefault: isDefault
            ),
            value: value,
            defaultValue: defaultValue,
            launchArgument: "-\(key)",
            reset: reset
        )
    }

    /// A project value's state: this Mac's value, cherry.toml's
    /// and, when given, Cherry's default. `revert` drops this Mac's value
    /// (Overrides cherry.toml: back to the file's; This Mac only: back to
    /// the default); `saveToFile` writes this Mac's value into cherry.toml
    /// and drops it here (nil where it cannot: a project on another Mac).
    /// `revertTitle` replaces "Revert to cherry.toml (<file value>)" where
    /// the value is too long to name (a command's line).
    static func project(
        source: ProjectValueSource,
        fileValue: String?,
        thisMacValue: String?,
        defaultValue: String? = nil,
        revertTitle: String? = nil,
        revert: @escaping @MainActor () -> Void,
        saveToFile: (@MainActor () -> Void)?
    ) -> SettingsSourceState {
        let thisMac = source == .overridesProjectFile || source == .thisMacOnly
        var lines = [
            Line("This Mac", value: thisMacValue, detail: thisMacValue == nil ? "Not set" : nil, isInUse: thisMac),
            Line(
                "cherry.toml",
                value: fileValue,
                detail: fileValue == nil ? "Says nothing about it" : nil,
                isInUse: source == .projectFile
            ),
        ]
        if let defaultValue {
            lines.append(Line("Cherry default", value: defaultValue, isInUse: source == .none))
        }
        let save = saveToFile.map { SettingsAction("Save to cherry.toml", perform: $0) }
        var note: String?
        if save != nil, let thisMacValue {
            note = source == .overridesProjectFile
                ? "Save to cherry.toml writes \(thisMacValue) into the file and drops the override."
                : "Save to cherry.toml writes \(thisMacValue) into the file."
        }
        switch source {
        case .overridesProjectFile:
            let revertAction = SettingsAction(
                revertTitle ?? fileValue.map { "Revert to cherry.toml (\($0))" } ?? "Revert to cherry.toml",
                perform: revert
            )
            return SettingsSourceState(
                source: SettingSource(source),
                defaultText: defaultValue,
                lines: lines,
                note: note,
                buttons: [revertAction] + (save.map { [$0] } ?? []),
                reset: revertAction
            )
        case .thisMacOnly:
            let resetAction = SettingsAction(defaultValue.map(resetTitle) ?? "Reset to default", perform: revert)
            return SettingsSourceState(
                source: SettingSource(source),
                defaultText: defaultValue,
                lines: lines,
                note: note,
                buttons: (save.map { [$0] } ?? []) + [resetAction]
            )
        case .projectFile, .none:
            return SettingsSourceState(source: SettingSource(source), defaultText: defaultValue, lines: lines)
        }
    }

    /// A value a line of the user's Ghostty config sets:
    /// read-only here. Its buttons open the file (`openTextFile`, never
    /// creating it) and show it in Finder; there is no ↺, since Cherry
    /// never writes the user's Ghostty files.
    static func ghosttyConfig(
        file: URL,
        line: Int?,
        value: String,
        defaultValue: String,
        homeDirectory: String = NSHomeDirectory(),
        actions: SettingsActions
    ) -> SettingsSourceState {
        SettingsSourceState(
            source: .ghosttyConfig(file: file, line: line),
            defaultText: defaultValue,
            lines: [
                Line(
                    "Ghostty config",
                    value: value,
                    detail: ghosttyLocation(file: file, line: line, homeDirectory: homeDirectory),
                    isInUse: true
                ),
                Line("Cherry default", value: defaultValue),
            ],
            note: "Cherry reads this file when it opens. Restart Cherry after you change it.",
            buttons: [
                SettingsAction("Edit in Ghostty Config") { actions.openTextFile(file) },
                SettingsAction("Reveal in Finder") { actions.revealInFinder([file]) },
            ]
        )
    }

    /// Where a Ghostty config line is, as rows say it:
    /// "~/.config/ghostty/config, line 12".
    static func ghosttyLocation(file: URL, line: Int?, homeDirectory: String) -> String {
        let path = ProjectSwitcherModel.displayPath(file.path, home: homeDirectory)
        guard let line else { return path }
        return "\(path), line \(line)"
    }

    /// "Reset to default (14 pt)".
    static func resetTitle(_ defaultValue: String) -> String {
        "Reset to default (\(defaultValue))"
    }
}

// MARK: - Badge, popover and ↺

/// A row's source badge: its words in the source's colors,
/// after the row's title. A click, or Space while it has focus, opens the
/// popover. Cherry's default has no badge: a faint "Default" shows in its
/// place while the row is hovered.
struct SettingsSourceBadge: View {
    let state: SettingsSourceState
    /// The popover's title: the row's.
    var title: String?

    @Environment(\.settingsRowIsHovered) private var rowIsHovered
    @State private var showsPopover = false

    var body: some View {
        if let text = state.badgeText, let style = SettingsDesign.badgeStyle(for: state.source) {
            Button {
                showsPopover.toggle()
            } label: {
                Text(text)
                    .font(SettingsDesign.Fonts.badge)
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(style.fill, in: Capsule())
                    .overlay {
                        if let outline = style.outline {
                            Capsule().strokeBorder(outline, lineWidth: 1)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(state.accessibilityLabel)
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                SettingsSourcePopover(state: state, title: title) { showsPopover = false }
            }
        } else if state.source == .cherryDefault {
            Text("Default")
                .font(SettingsDesign.Fonts.badge)
                .foregroundStyle(.tertiary)
                .opacity(rowIsHovered ? 1 : 0)
                .accessibilityHidden(true)
        }
    }
}

/// A row's ↺: after the badge, for Set here and
/// Overrides cherry.toml. Always in the hierarchy, so VoiceOver finds it;
/// it shows while its row is hovered or it has keyboard focus. Its tooltip
/// and label name the result. It never asks.
struct SettingsResetButton: View {
    let state: SettingsSourceState

    @Environment(\.settingsRowIsHovered) private var rowIsHovered
    @FocusState private var isFocused: Bool

    var body: some View {
        if let reset = state.rowReset {
            let isShown = rowIsHovered || isFocused
            Button {
                reset.perform()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focused($isFocused)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .help(reset.title)
            .accessibilityLabel(reset.title)
        }
    }
}

/// A badge's popover: the row's title, the sources from the top with the
/// one in use marked, a note and the source's buttons.
private struct SettingsSourcePopover: View {
    let state: SettingsSourceState
    let title: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
                    GridRow {
                        Circle()
                            .strokeBorder(line.isInUse ? Color.accentColor : Color.secondary, lineWidth: line.isInUse ? 3 : 1.5)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(line.source)
                            .fontWeight(line.isInUse ? .semibold : .regular)
                            .foregroundStyle(line.isInUse ? .primary : .tertiary)
                        lineText(line)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(line.isInUse ? .isSelected : [])
                }
            }
            .font(SettingsDesign.Fonts.help)
            if let note = state.note {
                Text(note)
                    .font(SettingsDesign.Fonts.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(state.buttons.enumerated()), id: \.offset) { _, action in
                        Button(action.title, role: action.role) {
                            dismiss()
                            action.perform()
                        }
                        .settingsButton(action.role == .destructive ? .danger : .standard, size: .small)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 260, maxWidth: 400, alignment: .leading)
    }

    private func lineText(_ line: SettingsSourceState.Line) -> some View {
        let parts = [line.value, line.detail].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .foregroundStyle(line.isInUse ? .primary : .tertiary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
