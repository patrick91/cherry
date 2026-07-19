import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var settings: TerminalSettings
    @ObservedObject private var editorDiscovery = ExternalEditorDiscovery.shared

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

                SettingsDivider()

                SettingsRow("Worktree spaces", subtitle: "Group Git worktrees into swipeable spaces in one project window.") {
                    Toggle("Worktree spaces", isOn: $settings.worktreeSpacesEnabled)
                        .labelsHidden()
                }
            }

            SettingsCard("External Editor") {
                SettingsRow("Default editor", subtitle: "Used by the ⌘P “Open in …” command.") {
                    if editorDiscovery.installedEditors.isEmpty {
                        Text("No editors found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Default editor", selection: defaultEditorSelection) {
                            Text("Automatic (\(editorDiscovery.installedEditors[0].displayName))")
                                .tag("")
                            ForEach(editorDiscovery.installedEditors) { editor in
                                Text(editor.displayName)
                                    .tag(editor.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }
                }
            }
        }
        .onAppear {
            editorDiscovery.refresh()
        }
    }

    /// Normalizes a stale preference (editor uninstalled since it was chosen)
    /// back to Automatic instead of leaving the picker blank.
    private var defaultEditorSelection: Binding<String> {
        Binding(
            get: {
                editorDiscovery.installedEditors.contains { $0.id == settings.defaultEditorID }
                    ? settings.defaultEditorID
                    : ""
            },
            set: { settings.defaultEditorID = $0 }
        )
    }
}
