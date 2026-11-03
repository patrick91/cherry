import AppKit
import SwiftUI

/// Settings › Terminal: text, the keyboard and key bindings Cherry reads
/// from the user's Ghostty config, scrollback and the Ghostty config's
/// files. The Ghostty rows are read-only: Cherry never writes those files,
/// and reads them again (`GhosttyConfigPageModel.refresh`) only from the
/// page's `.task` and when Cherry comes to the front.
struct TerminalSettingsPage: View, SettingsPageContent {
    @ObservedObject private var settings: TerminalSettings
    @StateObject private var ghostty: GhosttyConfigPageModel
    private let navigator: SettingsNavigator
    /// For paths shown with "~".
    private let homeDirectory: String

    @Environment(\.settingsActions) private var actions
    @State private var isCopyingReport = false

    init(settings: TerminalSettings = .shared, navigator: SettingsNavigator = .shared, homeDirectory: String = NSHomeDirectory()) {
        _settings = ObservedObject(wrappedValue: settings)
        _ghostty = StateObject(wrappedValue: GhosttyConfigPageModel.app())
        self.navigator = navigator
        self.homeDirectory = homeDirectory
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.terminal.title) {
            textSection
            keyboardSection
            scrollbackSection
            ghosttyConfigSection
            SettingsPageFooter(caption: "Resets this page only. Values from your Ghostty config stay.") {
                SettingsPageResetButton(
                    "Reset Terminal…",
                    settings: TerminalSettings.Setting.terminalPage,
                    in: settings,
                    mentionsGhosttyConfig: true
                )
            }
        }
        .task { ghostty.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ghostty.refresh()
        }
    }

    // MARK: Text

    private var textSection: some View {
        SettingsSection("Text") {
            let fontSize = SettingsSourceState.terminal(.fontSize, in: settings)
            SettingsItem(id: .terminalFontSize, TerminalSettings.Setting.fontSize.title, source: fontSize) {
                SettingsSliderControl(
                    "Font size",
                    value: $settings.fontSize,
                    in: 10...24,
                    step: 1,
                    valueText: settings.valueText(.fontSize)
                )
                .disabled(!fontSize.source.isEditable)
            }

            let cursorBlink = SettingsSourceState.terminal(.cursorBlink, in: settings)
            SettingsItem(
                id: .terminalCursorBlink,
                TerminalSettings.Setting.cursorBlink.title,
                help: Self.cursorBlinkHelp,
                source: cursorBlink
            ) {
                Toggle(TerminalSettings.Setting.cursorBlink.title, isOn: $settings.cursorBlink)
                    .settingsSwitch()
                    .disabled(!cursorBlink.source.isEditable)
            }
        }
    }

    // MARK: Keyboard

    private var keyboardSection: some View {
        SettingsSection("Keyboard") {
            optionKeyRow
            keyBindingsRow
        }
    }

    private var optionKeyRow: some View {
        let optionKey = ghostty.optionKey
        let source = optionKey.line.map { line in
            SettingsSourceState.ghosttyConfig(
                file: line.file,
                line: line.line,
                value: optionKey.value.settingsLabel,
                defaultValue: HostRoutedKeyEncoder.OptionAsAlt.both.settingsLabel,
                actions: actions
            )
        }
        return SettingsItem(
            id: .terminalOptionKey,
            "Option key",
            help: optionKey.help(homeDirectory: homeDirectory),
            source: source
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Option key", selection: .constant(optionKey.value)) {
                    ForEach(GhosttyConfigSettings.optionKeyChoices, id: \.self) { choice in
                        Text(choice.settingsLabel).tag(choice)
                    }
                }
                .settingsMenuPicker()
                .disabled(true)
                .accessibilityValue(optionKey.accessibilityValue)

                if let file = optionKey.file {
                    Button("Edit in Ghostty Config") {
                        actions.openTextFile(file)
                    }
                    .settingsButton(size: .small)
                }
            }
        } detail: {
            if let note = optionKey.leftOutNote {
                SettingsNote(note, style: .warning)
            }
            if optionKey.changedSinceLaunch {
                SettingsNote(GhosttyConfigSettings.changedSinceLaunchNote, style: .warning)
            }
        }
    }

    private var keyBindingsRow: some View {
        SettingsItem(
            id: .terminalKeyBindings,
            "Key bindings from Ghostty",
            help: Self.keyBindingsHelp,
            source: GhosttyConfigSettings.bindingsSource(
                ghostty.launchReading,
                homeDirectory: homeDirectory,
                actions: actions
            )
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                SettingsStatusText(ghostty.bindingCounts.text)
                Button("Show in Shortcuts") {
                    Self.showKeyBindingsInShortcuts(navigator)
                }
                .settingsButton(size: .small)
            }
        }
    }

    /// Show in Shortcuts: Shortcuts at its terminal key bindings, flashed.
    static func showKeyBindingsInShortcuts(_ navigator: SettingsNavigator) {
        navigator.open(.page(.shortcuts), row: .shortcutsTerminalKeyBindings)
    }

    // MARK: Scrollback

    private var scrollbackSection: some View {
        SettingsSection("Scrollback") {
            SettingsItem(id: .terminalScrollback, "In a shown tab", help: Self.scrollbackHelp) {
                SettingsStatusText(GhosttyConfigSettings.shownTabScrollbackText)
            }
        }
    }

    // MARK: Ghostty config

    private var ghosttyConfigSection: some View {
        SettingsSection("Ghostty config", intro: Self.ghosttyConfigIntro, id: .terminalGhosttyConfig) {
            ForEach(ghostty.files) { file in
                fileRow(file)
            }

            let linesLeftOut = ghostty.linesLeftOut
            if !linesLeftOut.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsGroupLabel("Lines left out")
                    Text("Ghostty rejects these lines, so Cherry skips them. The rest of the file still applies.")
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsDesign.Metrics.rowHorizontalPadding)
                }
                .settingsSeparatorAbove(false)

                ForEach(Array(linesLeftOut.enumerated()), id: \.element.id) { index, line in
                    leftOutRow(line)
                        .settingsSeparatorAbove(index > 0)
                }
            }

            SettingsItem("Report", help: Self.reportHelp) {
                Button("Copy Report") {
                    copyReport()
                }
                .settingsButton()
                .disabled(isCopyingReport)
            }
        }
    }

    private func fileRow(_ file: GhosttyConfigSettings.File) -> some View {
        let path = ProjectSwitcherModel.displayPath(file.url.path, home: homeDirectory)
        return SettingsListItem {
            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(SettingsDesign.Fonts.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let includedBy = file.includedByText {
                    Text(includedBy)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                }
                if file.state == .changed {
                    SettingsNote(GhosttyConfigSettings.changedSinceLaunchNote, style: .warning)
                }
            }
        } trailing: {
            if file.exists {
                Button("Open") {
                    actions.openTextFile(file.url)
                }
                .settingsButton(size: .small)
                .accessibilityLabel("Open \(path)")
                SettingsIconButton("Reveal in Finder", systemImage: "folder", accessibilityLabel: "Reveal \(path) in Finder") {
                    actions.revealInFinder([file.url])
                }
            }
            fileStatus(file.state)
        }
    }

    @ViewBuilder
    private func fileStatus(_ state: GhosttyConfigSettings.File.State) -> some View {
        switch state {
        case .read: SettingsStatusText(state.text, style: .ok, dot: .green)
        case .missing: SettingsStatusText(state.text, dot: .gray)
        case .changed: SettingsStatusText(state.text, style: .warning, dot: .yellow)
        }
    }

    private func leftOutRow(_ line: GhosttyConfigSettings.LeftOutLine) -> some View {
        SettingsListItem {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.location)
                    .font(SettingsDesign.Fonts.mono)
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(SettingsDesign.Fonts.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsNote(line.reason, style: .warning)
            }
        } trailing: {
            Button("Edit in Ghostty Config") {
                actions.openTextFile(line.line.file)
            }
            .settingsButton(size: .small)
        }
    }

    /// Copies the report (`GhosttyConfigReport`), built now: it reads the
    /// files and asks for the staged Ghostty resources.
    private func copyReport() {
        isCopyingReport = true
        Task {
            let report = await GhosttyConfigReport.build(from: .app())
            actions.copy(report.text)
            isCopyingReport = false
        }
    }

    // MARK: Texts

    static let cursorBlinkHelp = "Blink the cursor while the terminal has focus."
    static let keyBindingsHelp = "Cherry's terminals use the text:, csi:, esc: and ignore bindings in your Ghostty config. App actions stay Cherry's."
    static let scrollbackHelp = "What a tab keeps while it's on screen."
    static let ghosttyConfigIntro = "Cherry reads these files when it opens, in Ghostty's order. Restart Cherry after you change them."
    static let reportHelp = "Copies the files and what happened to each line, for a bug report. Text that text: bindings type is masked."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let terminal = context.terminal
        let optionKey = GhosttyConfigSettings.optionKey(launch: context.ghostty, now: nil)
        return [
            SettingsSearchRow(
                id: .terminalFontSize,
                route: .page(.terminal),
                section: "Text",
                title: TerminalSettings.Setting.fontSize.title,
                keywords: ["font", "typeface", "monospace", "text size", "zoom"],
                value: terminal.valueText(.fontSize)
            ),
            SettingsSearchRow(
                id: .terminalCursorBlink,
                route: .page(.terminal),
                section: "Text",
                title: TerminalSettings.Setting.cursorBlink.title,
                help: cursorBlinkHelp,
                keywords: ["cursor", "caret"],
                value: terminal.valueText(.cursorBlink)
            ),
            SettingsSearchRow(
                id: .terminalOptionKey,
                route: .page(.terminal),
                section: "Keyboard",
                title: "Option key",
                help: GhosttyConfigSettings.optionKeyHelp,
                keywords: ["alt", "meta", "esc", "keyboard layout", "compose", "international", "ghostty", "macos-option-as-alt"]
                    + (optionKey.line == nil ? [] : [optionKey.value.settingsLabel]),
                value: optionKey.searchValue
            ),
            SettingsSearchRow(
                id: .terminalKeyBindings,
                route: .page(.terminal),
                section: "Keyboard",
                title: "Key bindings from Ghostty",
                help: keyBindingsHelp,
                keywords: ["keybind", "ghostty"]
            ),
            SettingsSearchRow(
                id: .terminalScrollback,
                route: .page(.terminal),
                section: "Scrollback",
                title: "In a shown tab",
                help: scrollbackHelp,
                keywords: ["history", "buffer", "lines"],
                value: GhosttyConfigSettings.shownTabScrollbackText
            ),
            SettingsSearchRow(
                id: .terminalGhosttyConfig,
                route: .page(.terminal),
                section: "Ghostty config",
                title: "Ghostty config",
                help: ghosttyConfigIntro,
                keywords: ["ghostty", "config", "keybind", "diagnostics", "keyboard", "report", "lines left out"]
            ),
        ]
    }
}

extension SettingsRowID {
    static let terminalFontSize: Self = "terminal.fontSize"
    static let terminalCursorBlink: Self = "terminal.cursorBlink"
    static let terminalOptionKey: Self = "terminal.optionKey"
    static let terminalScrollback: Self = "terminal.scrollback"
}
