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
/// nothing while no update waits. `insets` apply only while it shows.
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
                action: { AppUpdater.shared.restartToUpdate() }
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

    private func pill(
        title: String,
        version: String,
        channel: String?,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovering ? 0.12 : 0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(title)
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
