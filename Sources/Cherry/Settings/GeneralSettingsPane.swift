import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        SettingsPaneScroll(page: .general) {
            SettingsCard("Interface") {
                SettingsRow("App appearance", subtitle: "Choose whether Cherry follows macOS or uses a fixed appearance.") {
                    Picker("App appearance", selection: $settings.appearance) {
                        ForEach(CherryAppearancePreference.allCases) { appearance in
                            Text(appearance.label)
                                .tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                SettingsDivider()

                SettingsRow("Terminal path labels", subtitle: "Control how project and folder names are shown in the sidebar.") {
                    Picker("Terminal path labels", selection: $settings.sidebarTerminalPathDisplayMode) {
                        ForEach(SidebarTerminalPathDisplayMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }

                SettingsDivider()

                SettingsRow("Project colors", subtitle: "Use project identity colors in the window chrome and sidebar.") {
                    Picker("Project colors", selection: $settings.projectColorDisplayMode) {
                        ForEach(ProjectColorDisplayMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
        }
    }
}
