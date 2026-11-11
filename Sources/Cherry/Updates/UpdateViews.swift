import SwiftUI

/// The app menu's Check for Updates… or, with an update staged, Restart to
/// Update. Nothing unless this copy updates itself.
struct UpdateMenuItems: View {
    @ObservedObject var status: AppUpdateStatus

    var body: some View {
        if status.isEnabled {
            if case .ready(let version, _, _) = status.phase {
                Button("Restart to Update") {
                    AppUpdater.shared.restartToUpdate()
                }
                .help("Install Cherry \(version) and reopen; persistent sessions keep running")
                .disabled(status.isRestarting)
            } else {
                Button("Check for Updates…") {
                    AppUpdater.shared.checkForUpdates()
                }
                .disabled(!status.canCheckForUpdates || status.isReplacedOnDisk)
            }
        }
    }
}

/// The sidebar footer's Restart to Update (or Update Available) capsule;
/// nothing while no update waits. `insets` apply only while it shows. An
/// update Cherry staged can be dismissed there (its × while hovered, or its
/// menu): that discards it, so Check for Updates… looks again and Sparkle's
/// window shows what it finds.
struct SidebarUpdatePill: View {
    @ObservedObject var status: AppUpdateStatus
    var insets = EdgeInsets()
    @State private var isHovering = false

    var body: some View {
        switch status.phase {
        case .idle:
            EmptyView()
        case .ready(let version, let channel, _):
            pill(
                title: status.isRestarting ? "Restarting…" : "Restart to Update",
                version: version,
                channel: channel,
                help: "Cherry \(version) is ready. Restart now to install it (persistent sessions keep running); otherwise it installs when Cherry quits.",
                action: { AppUpdater.shared.restartToUpdate() },
                dismiss: Self.offersDismiss(status) ? { AppUpdater.shared.discardDownloadedUpdate() } : nil
            )
            .disabled(status.isRestarting)
        case .available(let version, let channel):
            pill(
                title: "Update Available",
                version: version,
                channel: channel,
                help: "Cherry \(version) is available.",
                action: { AppUpdater.shared.checkForUpdates() }
            )
        }
    }

    /// Only an update Cherry staged is dismissed (`AppUpdateStatus.offersDiscard`),
    /// and not while Cherry restarts to install it.
    static func offersDismiss(_ status: AppUpdateStatus) -> Bool {
        status.offersDiscard && !status.isRestarting
    }

    static let dismissTitle = "Discard Downloaded Update"
    static let dismissHelp = "Discard Downloaded Update: it no longer installs, and Check for Updates… looks for the newest build again."

    private func pill(
        title: String,
        version: String,
        channel: String?,
        help: String,
        action: @escaping () -> Void,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(channel == "prerelease" ? "\(version) pre-release" : version)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityActions {
                if let dismiss {
                    Button(Self.dismissTitle, action: dismiss)
                }
            }

            if let dismiss, isHovering {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Self.dismissHelp)
                .accessibilityLabel(Self.dismissTitle)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, dismiss != nil && isHovering ? 4 : 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(isHovering ? 0.12 : 0.07), in: Capsule())
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let dismiss {
                Button(title, action: action)
                Button(Self.dismissTitle, action: dismiss)
            }
        }
        .padding(insets)
    }
}

/// The menu bar panel's Restart to Update, above Settings…, while an
/// update is staged. `label` draws it like the panel's other actions.
struct MenuBarUpdateRow<Label: View>: View {
    @ObservedObject var status: AppUpdateStatus
    let label: (_ title: String) -> Label

    init(status: AppUpdateStatus, @ViewBuilder label: @escaping (_ title: String) -> Label) {
        self.status = status
        self.label = label
    }

    private var showsRow: Bool {
        guard status.isEnabled, !status.isRestarting, case .ready = status.phase else { return false }
        return true
    }

    var body: some View {
        if showsRow {
            Button {
                // After the panel's click: the confirmation may go on a window.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppUpdater.shared.restartToUpdate() }
                }
            } label: {
                label("Restart to Update")
            }
            .buttonStyle(.plain)
        }
    }
}
