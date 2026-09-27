import AppKit
import SwiftUI

struct SessionsSettingsPane: View {
    @ObservedObject var settings: TerminalSettings
    @ObservedObject var status: PersistentSessionsStatus
    @ObservedObject var backgroundSessions: BackgroundSessionsSummary
    let endBackgroundSessions: () -> Void

    init(
        settings: TerminalSettings,
        status: PersistentSessionsStatus = .shared,
        backgroundSessions: BackgroundSessionsSummary = BackgroundSessionsModel.shared.summary,
        // On the Settings window, where it was asked (the window it was
        // clicked in is key).
        endBackgroundSessions: @escaping () -> Void = { BackgroundSessionsModel.shared.confirmEndAll(from: NSApp.keyWindow) }
    ) {
        self.settings = settings
        self.status = status
        self.backgroundSessions = backgroundSessions
        self.endBackgroundSessions = endBackgroundSessions
    }

    var body: some View {
        SettingsPaneScroll(page: .sessions) {
            if let reason = status.localSessionsUnavailableReason {
                SettingsCard {
                    SessionsUnavailableRow(reason: reason)
                }
            } else if let failure = status.lastLaunchFailure {
                SettingsCard {
                    SessionsUnavailableRow(
                        title: "A tab is not a persistent session",
                        detail: "\(failure) It runs as a regular terminal; Retry on the tab, or restart it, to try again."
                    )
                }
            }

            SettingsCard("Tabs") {
                SettingsRow(
                    "Close a tab when its shell exits",
                    subtitle: "A terminal tab closes when its shell ends with exit status 0, and the window closes with its last tab. Typing exit after a failed command ends the shell with that command's status, so the tab stays open and shows it. Command and agent tabs stay open."
                ) {
                    Toggle("Close a tab when its shell exits", isOn: $settings.closeTabsOnCleanExit)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if !settings.persistLocalSessions || status.localSessionsUnavailableReason != nil {
                    Text("Without persistent sessions Cherry cannot see a shell's exit status, so a terminal tab closes whenever its shell ends.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
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
                    "When quitting or closing a window",
                    subtitle: "Choose what happens to local sessions that are still running when you quit Cherry or close a project window. \"Don't ask again\" in that dialog sets this too. Sessions keep running if Cherry crashes or is updated. A log out, restart or shut down does not ask about them, but warns about programs still running in them, which the system then ends."
                ) {
                    Picker("When quitting or closing a window", selection: $settings.localSessionsOnQuit) {
                        ForEach(LocalSessionsOnQuit.allCases) { choice in
                            Text(choice.label)
                                .tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }
                // Not tied to the toggle above: tabs restored as persistent
                // sessions still ask while new tabs run natively.
            }

            SettingsCard("Background Sessions") {
                SettingsRow(
                    backgroundSessionsTitle,
                    subtitle: "Sessions of windows or tabs you closed that keep running. Open or end them from Background Sessions in the Cherry menu bar icon."
                ) {
                    if backgroundSessions.count > 0 {
                        Button("End All…", action: endBackgroundSessions)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    "Tell me about background sessions when Cherry opens",
                    subtitle: "When Cherry opens and agents, commands or busy terminals from closed windows or tabs are still running, it says so once. Sessions you kept running when you closed their tab or window are not mentioned."
                ) {
                    Toggle("Tell me about background sessions when Cherry opens", isOn: $settings.noticeBackgroundSessionsAtLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Text("Sessions on SSH hosts always keep running when you close a tab, close a window or quit. Manage them from File › Persistent Sessions.")
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

extension SessionsSettingsPane {
    /// "3 sessions are running in the background", or the ended ones when
    /// none runs.
    var backgroundSessionsTitle: String {
        let running = backgroundSessions.runningCount
        let ended = backgroundSessions.count - running
        if running > 0 {
            return running == 1
                ? "1 session is running in the background"
                : "\(running) sessions are running in the background"
        }
        if ended > 0 {
            return ended == 1
                ? "1 ended session is in the background"
                : "\(ended) ended sessions are in the background"
        }
        return "No sessions are running in the background"
    }
}

private struct SessionsUnavailableRow: View {
    let title: String
    let detail: String

    init(reason: String) {
        title = "Local sessions are unavailable"
        detail = "\(reason) New tabs run as regular terminals until then."
    }

    /// A tab's session could not start (`PersistentSessionsStatus.lastLaunchFailure`).
    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text(detail)
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
