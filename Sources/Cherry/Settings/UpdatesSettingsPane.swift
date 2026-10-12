import AppKit
import SwiftUI

/// Settings › Updates: this build's version, what the updater does now,
/// and Sparkle's automatic checks and downloads, which live in the app's
/// own defaults (`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`), and
/// Cherry's `updates.prereleases`.
struct UpdatesSettingsPane: View {
    @ObservedObject var status: AppUpdateStatus

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        SettingsPaneScroll(page: .updates) {
            SettingsCard("Cherry") {
                SettingsRow("Version") {
                    CopyableValue(value: shortVersion)
                }

                SettingsDivider()

                SettingsRow("Build") {
                    CopyableValue(value: buildVersion)
                }

                SettingsDivider()

                if let reason = status.enablement.reason {
                    Text(reason.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                } else {
                    SettingsRow(statusLine, subtitle: statusDetail) {
                        statusButtons
                    }

                    if let error = status.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                    }
                }
            }

            SettingsCard("Automatic Updates") {
                SettingsRow("Check for updates automatically") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { status.automaticallyChecks },
                        set: { AppUpdater.shared.setAutomaticallyChecks($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsDivider()

                SettingsRow(
                    "Download and install updates automatically",
                    subtitle: "Downloads in the background. The update installs when Cherry quits, or at once with Restart to Update; persistent sessions keep running."
                ) {
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { status.automaticallyDownloads },
                        set: { AppUpdater.shared.setAutomaticallyDownloads($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!status.automaticallyChecks)
                }

                SettingsDivider()

                SettingsRow(
                    "Get pre-release builds",
                    subtitle: "Every change to Cherry's main branch, once its tests pass. Turning this off never goes back to an older build: this Mac stays on its pre-release until a newer stable release ships. An update already downloaded, or downloading, still installs unless you discard it, and Check Now can show one already found until Cherry restarts."
                ) {
                    Toggle("Get pre-release builds", isOn: Binding(
                        get: { status.prereleases },
                        set: { AppUpdater.shared.setPrereleases($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                if let version = downloadedPrereleaseWhileOff {
                    SettingsRow("Cherry \(version) (pre-release) is downloaded and installs when Cherry quits.") {
                        Button("Discard It") {
                            AppUpdater.shared.discardDownloadedUpdate()
                        }
                        .disabled(status.isRestarting)
                    }
                }
            }
            .disabled(!status.isEnabled)
        }
    }

    /// "Up to date · checked 5 minutes ago", "Cherry … is ready", …
    private var statusLine: String {
        if status.isRestarting { return "Restarting…" }
        switch status.phase {
        case .ready(let version, let channel, _):
            return "Cherry \(version)\(channel == "prerelease" ? " (pre-release)" : "") is ready"
        case .available(let version, _):
            return "Cherry \(version) is available"
        case .idle:
            if status.isReplacedOnDisk { return "Another build of Cherry was installed" }
            if status.lastError != nil { return "Last check failed" }
            guard let lastCheck = status.lastCheck else { return "Not checked yet" }
            return "Up to date · checked \(lastCheck.formatted(.relative(presentation: .named)))"
        }
    }

    private var statusDetail: String? {
        guard !status.isRestarting else { return nil }
        switch status.phase {
        case .ready(_, _, throughSparkle: false):
            return "Restart to install it now; otherwise it installs when Cherry quits. Persistent sessions keep running."
        case .ready(_, _, throughSparkle: true):
            return "Restart to Update shows it, to install it now or skip it; otherwise it installs when Cherry quits. Persistent sessions keep running."
        case .idle where status.isReplacedOnDisk:
            return "Quit and reopen Cherry to use it. Until then this copy installs no update."
        default:
            return nil
        }
    }

    @ViewBuilder
    private var statusButtons: some View {
        HStack(spacing: 8) {
            switch status.phase {
            case .ready:
                if status.offersDiscard {
                    Button("Discard Downloaded Update") {
                        AppUpdater.shared.discardDownloadedUpdate()
                    }
                    .settingsGlassButtonStyle()
                    .disabled(status.isRestarting)
                }
                Button("Restart to Update") {
                    AppUpdater.shared.restartToUpdate()
                }
                .settingsProminentGlassButtonStyle()
                .disabled(status.isRestarting)
            case .available:
                Button("Install…") {
                    AppUpdater.shared.checkForUpdates()
                }
                .settingsProminentGlassButtonStyle()
                .disabled(!status.canCheckForUpdates)
                checkNowButton
            case .idle:
                checkNowButton
            }
        }
    }

    private var checkNowButton: some View {
        Button("Check Now") {
            AppUpdater.shared.checkForUpdates()
        }
        .settingsGlassButtonStyle()
        .disabled(!status.canCheckForUpdates || status.isReplacedOnDisk)
    }

    /// The pre-release Cherry staged, while Get pre-release builds is off.
    private var downloadedPrereleaseWhileOff: String? {
        guard !status.prereleases, status.offersDiscard, case .ready(let version, "prerelease", _) = status.phase else { return nil }
        return version
    }
}

/// A value with a Copy button.
private struct CopyableValue: View {
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .settingsGlassButtonStyle()
        }
    }
}
