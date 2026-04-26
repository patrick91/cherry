import SwiftUI

struct SettingsView: View {
    @StateObject private var terminalSettings = TerminalSettings.shared

    var body: some View {
        TabView {
            TerminalSettingsPane(settings: terminalSettings)
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
        }
        .frame(width: 520, height: 360)
    }
}

private struct TerminalSettingsPane: View {
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("App appearance", selection: $settings.appearance) {
                    ForEach(CherryAppearancePreference.allCases) { appearance in
                        Text(appearance.label)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Terminal Theme") {
                GhosttyThemeNameField(
                    title: "Light",
                    name: $settings.lightTerminalThemeName,
                    isKnown: settings.isKnownGhosttyTheme(settings.lightTerminalThemeName)
                )

                GhosttyThemeNameField(
                    title: "Dark",
                    name: $settings.darkTerminalThemeName,
                    isKnown: settings.isKnownGhosttyTheme(settings.darkTerminalThemeName)
                )
            }

            Section("Text") {
                SettingsSlider(
                    title: "Font size",
                    value: $settings.fontSize,
                    range: 10...24,
                    step: 1,
                    suffix: "pt"
                )
            }

            Section("Cursor") {
                Toggle("Blink cursor", isOn: $settings.cursorBlink)
            }

            Section("Color") {
                SettingsSlider(
                    title: "Minimum contrast",
                    value: $settings.minimumContrast,
                    range: 1...2,
                    step: 0.05,
                    suffix: "x"
                )
            }

            HStack {
                Spacer()
                Button("Reset Terminal Appearance") {
                    settings.resetTerminalAppearance()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct GhosttyThemeNameField: View {
    let title: String
    @Binding var name: String
    let isKnown: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            TextField("Ghostty theme name", text: $name)
                .textFieldStyle(.roundedBorder)

            Image(systemName: isKnown ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isKnown ? .green : .orange)
                .frame(width: 22)
        }
    }
}

private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Slider(value: $value, in: range, step: step)

            Text(formattedValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        if step >= 1 {
            "\(Int(value.rounded())) \(suffix)"
        } else {
            "\(value.formatted(.number.precision(.fractionLength(2))))\(suffix)"
        }
    }
}
