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
        GhosttyThemeCatalog.theme(named: selection)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Picker("Ghostty theme", selection: $selection) {
                if selectedTheme == nil {
                    Text(selection.isEmpty ? "Select a theme" : "\(selection) (unknown)")
                        .tag(selection)
                }

                ForEach(Self.themes) { theme in
                    Text(theme.name)
                        .tag(theme.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let selectedTheme {
                GhosttyThemeSwatch(theme: selectedTheme)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private static let themes = GhosttyThemeCatalog.allThemes.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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
