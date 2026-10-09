import AppKit
import GhosttyTheme
import SwiftUI

struct TerminalSettingsPane: View {
    @ObservedObject var settings: TerminalSettings
    @StateObject private var optionKey = OptionKeyObserver()

    var body: some View {
        SettingsPaneScroll(page: .terminal) {
            SettingsCard("Themes") {
                GhosttyThemePicker(
                    title: "Light",
                    selection: $settings.lightTerminalThemeName
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                GhosttyThemePicker(
                    title: "Dark",
                    selection: $settings.darkTerminalThemeName
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }

            SettingsCard("Text") {
                SettingsSlider(
                    title: "Font size",
                    value: $settings.fontSize,
                    range: 10...24,
                    step: 1,
                    suffix: "pt"
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                SettingsRow("Blink cursor", subtitle: "Animate the block cursor while the terminal is focused.") {
                    Toggle("Blink cursor", isOn: $settings.cursorBlink)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Attention Study") {
                SettingsRow(
                    "Collect agent observations",
                    subtitle: "Save deduplicated terminal-grid checkpoints locally, including terminal colors. Manual screen tags remain available when collection is off. Restart Cherry after enabling. Terminal text may contain sensitive data."
                ) {
                    Toggle("Collect agent observations", isOn: $settings.attentionStudyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsRow(
                    "Collect attention samples",
                    subtitle: "Every 30 seconds and on each state change, save each agent tab's screen tail, the attention model's inputs and verdict, and when you typed, submitted, focused or closed it (never what you typed). Stored privately in Application Support, at most 200 MB, oldest days removed first. Scripts/attention-autolabel turns them into training data."
                ) {
                    Toggle("Collect attention samples", isOn: $settings.attentionSamplesEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsRow(
                    "Local recordings",
                    subtitle: "Stored privately in Application Support. Older sessions are trimmed to 500 MB when collection starts."
                ) {
                    Button("Show in Finder") {
                        revealAttentionStudyRecordings()
                    }
                    .settingsGlassButtonStyle()
                }
            }

            SettingsCard("Color") {
                SettingsSlider(
                    title: "Minimum contrast",
                    value: $settings.minimumContrast,
                    range: 1...2,
                    step: 0.05,
                    suffix: "x"
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                SettingsSlider(
                    title: "Sidebar contrast",
                    value: $settings.sidebarBackgroundDepth,
                    range: 0...0.24,
                    step: 0.01,
                    suffix: "%",
                    displayScale: 100
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                if optionKey.isOptionDown {
                    SettingsDivider()

                    SidebarThemeDebugPanel(settings: settings)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                }
            }

            SettingsCard("Reset") {
                SettingsRow("Terminal appearance", subtitle: "Restore default themes, font size, contrast, cursor, and sidebar display.") {
                    Button("Reset") {
                        settings.resetTerminalAppearance()
                    }
                    .settingsGlassButtonStyle()
                }
            }
        }
    }

    private func revealAttentionStudyRecordings() {
        let directoryURL = TerminalAttentionStudy.recordingsDirectoryURL()
        try? TerminalAttentionStudy.prepareDirectoryIfNeeded(directoryURL)
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }
}

private struct SidebarThemeDebugPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: TerminalSettings

    private var sample: SidebarThemeSample {
        SidebarThemeSample(
            themeColors: settings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: settings.sidebarBackgroundDepth
        )
    }

    var body: some View {
        let sample = sample

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SidebarColorDebugSwatch(title: "Terminal", color: sample.background)
                SidebarColorDebugSwatch(title: "Sidebar", color: sample.sidebarBackground)

                if let selectionBackground = sample.selectionBackground {
                    SidebarColorDebugSwatch(title: "Selection", color: selectionBackground)
                }
            }

            Text("Luma delta \(luminanceDelta(for: sample))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func luminanceDelta(for sample: SidebarThemeSample) -> String {
        let delta = abs(sample.background.relativeLuminance - sample.sidebarBackground.relativeLuminance)
        return Double(delta).formatted(.number.precision(.fractionLength(3)))
    }
}

private struct SidebarColorDebugSwatch: View {
    let title: String
    let color: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Text(color.hexRGBString)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: 120, alignment: .leading)
    }
}

private struct GhosttyThemePicker: View {
    let title: String
    @Binding var selection: String

    private var selectedTheme: GhosttyThemeDefinition? {
        Self.themesByName[selection]
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            GhosttyThemePopUp(
                accessibilityLabel: "\(title) Ghostty theme",
                themeNames: Self.themeNames,
                selection: $selection
            )

            if let selectedTheme {
                GhosttyThemeSwatch(theme: selectedTheme)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private static let themeNames = GhosttyThemeCatalog.allThemes.map(\.name).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    private static let themesByName = Dictionary(
        GhosttyThemeCatalog.allThemes.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// The theme menu as an `NSPopUpButton` whose items are made once. A SwiftUI
/// menu `Picker` rebuilds its menu, resolving every item's text and
/// accessibility label, on each update of its window: with all of Ghostty's
/// themes in each of two pickers that took the main thread most of a second
/// on macOS 26 whenever the Settings window updated, as when Cherry came back
/// to the front. An update here only selects an item.
private struct GhosttyThemePopUp: NSViewRepresentable {
    let accessibilityLabel: String
    let themeNames: [String]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(accessibilityLabel)
        button.cell?.setAccessibilityLabel(accessibilityLabel)

        let menu = NSMenu()
        // Stands for a selection that names no known theme.
        let placeholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        placeholder.isHidden = true
        menu.addItem(placeholder)
        for (offset, name) in themeNames.enumerated() {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = name
            menu.addItem(item)
            context.coordinator.itemIndexByName[name] = offset + 1
        }
        button.menu = menu
        return button
    }

    /// The width SwiftUI's menu picker had; the button's own would fit the
    /// longest theme name. Long names are truncated in the button only.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: 238, height: button.intrinsicContentSize.height)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        guard let placeholder = button.item(at: 0) else { return }

        if let index = context.coordinator.itemIndexByName[selection] {
            if !placeholder.isHidden { placeholder.isHidden = true }
            if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        } else {
            let title = selection.isEmpty ? "Select a theme" : "\(selection) (unknown)"
            if placeholder.title != title { placeholder.title = title }
            if placeholder.isHidden { placeholder.isHidden = false }
            if button.indexOfSelectedItem != 0 { button.selectItem(at: 0) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        var itemIndexByName: [String: Int] = [:]

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func choose(_ sender: NSPopUpButton) {
            guard let name = sender.selectedItem?.representedObject as? String,
                  name != selection.wrappedValue
            else { return }
            selection.wrappedValue = name
        }
    }
}

private struct GhosttyThemeSwatch: View {
    let theme: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 4) {
            swatch(theme.background)
            swatch(theme.foreground)
            swatch(theme.selectionBackground ?? theme.palette[4] ?? theme.foreground)
        }
        .frame(width: 42, alignment: .trailing)
        .help(theme.name)
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(nsColor: NSColor(hexRGB: hex) ?? .clear))
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
