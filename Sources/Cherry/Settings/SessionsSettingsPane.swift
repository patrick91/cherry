import SwiftUI

struct SessionsSettingsPane: View {
    @ObservedObject var settings: TerminalSettings
    @ObservedObject var status: PersistentSessionsStatus

    init(settings: TerminalSettings, status: PersistentSessionsStatus = .shared) {
        self.settings = settings
        self.status = status
    }

    var body: some View {
        SettingsPaneScroll(page: .sessions) {
            if let reason = status.localSessionsUnavailableReason {
                SettingsCard {
                    SessionsUnavailableRow(reason: reason)
                }
            }

            SettingsCard("Local Sessions") {
                SettingsRow(
                    "Run local terminals as persistent sessions",
                    subtitle: "Terminal, command, and agent tabs keep running when Cherry quits, crashes, or updates, and come back when it opens again. Applies to new tabs."
                ) {
                    Toggle("Run local terminals as persistent sessions", isOn: $settings.persistLocalSessions)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsRow(
                    "Keep running after closing a tab",
                    subtitle: "Closing a tab leaves its session running. Attach to it again from File › Persistent Sessions."
                ) {
                    Toggle("Keep running after closing a tab", isOn: $settings.keepLocalSessionsAfterTabClose)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .disabled(!settings.persistLocalSessions)

                SettingsDivider()

                SettingsRow(
                    "End sessions when quitting",
                    subtitle: "Quitting Cherry or closing a window ends its local sessions instead of keeping them for next time."
                ) {
                    Toggle("End sessions when quitting", isOn: $settings.endLocalSessionsOnQuit)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .disabled(!settings.persistLocalSessions)
            }

            Text("Sessions on SSH hosts always keep running when you close a tab or quit. Manage them from File › Persistent Sessions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .onAppear {
            // Checks the installation (disk image, helper) now; cheap.
            PersistentLocalSessions.shared.refreshStatus()
        }
    }
}

private struct SessionsUnavailableRow: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 3) {
                Text("Local sessions are unavailable")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text("\(reason) New tabs run as regular terminals until then.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
