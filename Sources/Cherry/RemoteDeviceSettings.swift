import AppKit
import Combine
import SwiftUI

// Settings › Sessions › Other Macs (docs/specs/remote-devices.md): each
// device, how it stands (connected, offline, needs attention, an update
// available), with Reconnect, Update Session Host… and Remove.

/// One device's row; pure, for tests.
struct RemoteDeviceSettingsRow: Equatable, Identifiable {
    enum Status: Equatable {
        case connected(sessionCount: Int)
        case connecting
        /// Not reached during this run.
        case notConnected(lastSeen: Date?)
        case offline(String)
        /// Its login was refused, another identity or protocol answered, or
        /// its session host is gone: something to do before it works.
        case needsAttention(String)
    }

    let id: UUID
    let name: String
    let destination: String
    let status: Status
    /// Update Session Host… (or Reinstall) is offered: its install is older
    /// than this Cherry's, speaks another protocol, or is gone.
    let updateAvailable: Bool
    let updateTitle: String
    let offersReconnect: Bool
    let offersTrustNewIdentity: Bool

    init(device: RemoteDevice, state: RemoteDeviceConnectionState, bundledBuild: String?) {
        id = device.id
        name = device.name
        destination = device.sshDestination
        let menuDevice = TitlebarProjectMenuModel.Device(device: device, state: state, sessions: [], bundledBuild: bundledBuild)
        updateAvailable = menuDevice.offersHostUpdate
        updateTitle = menuDevice.hostUpdateTitle
        offersReconnect = state.offersReconnect
        offersTrustNewIdentity = state.offersTrustNewIdentity
        switch state {
        case .connected(let count): status = .connected(sessionCount: count)
        case .connecting: status = .connecting
        case .unknown(let lastSeen): status = .notConnected(lastSeen: lastSeen)
        case .reachable, .notRunning: status = .notConnected(lastSeen: device.lastSeen)
        case .offline(let reason): status = .offline(reason)
        case .identityChanged, .loginRefused, .incompatible, .hostMissing: status = .needsAttention(state.detail)
        }
    }

    /// "Connected · 2 sessions", "Offline", "Needs attention", with
    /// "Update available" when there is one.
    func statusText(now: Date = Date()) -> String {
        var text: String = switch status {
        case .connected(let count): count == 1 ? "Connected · 1 session" : "Connected · \(count) sessions"
        case .connecting: "Connecting…"
        case .notConnected(let lastSeen):
            lastSeen.map { "Not connected · last seen \(RemoteDeviceConnectionState.relative($0, now: now))" } ?? "Not checked yet"
        case .offline: "Offline"
        case .needsAttention: "Needs attention"
        }
        if updateAvailable { text += " · Update available" }
        return text
    }

    /// What is wrong, under the status (offline or needing attention).
    var detail: String? {
        switch status {
        case .offline(let reason): reason
        case .needsAttention(let reason): reason
        default: nil
        }
    }

    var dot: RemoteDeviceConnectionState.Dot {
        switch status {
        case .connected: .green
        case .connecting: .yellow
        case .needsAttention: .red
        case .notConnected, .offline: .gray
        }
    }
}

/// The rows, kept current from the device store and each device's control
/// connection. It never connects: it shows what the connections know.
@MainActor
final class RemoteDeviceSettingsModel: ObservableObject {
    @Published private(set) var rows: [RemoteDeviceSettingsRow] = []

    private let store: RemoteDeviceStore
    private let control: @MainActor (HostedSessionHost) -> HostControl
    private let bundledBuild: @MainActor () -> String?
    private var subscriptions: [AnyCancellable] = []
    private var controlSubscriptions: [HostedSessionHost: AnyCancellable] = [:]

    init(
        store: RemoteDeviceStore = .shared,
        control: @escaping @MainActor (HostedSessionHost) -> HostControl = { HostControlRegistry.shared.control(for: $0) },
        bundledBuild: @escaping @MainActor () -> String? = { RemoteHostHelpers.cachedAppBuild }
    ) {
        self.store = store
        self.control = control
        self.bundledBuild = bundledBuild
        subscriptions.append(store.$devices.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        })
        update()
    }

    func update() {
        var seen = Set<HostedSessionHost>()
        rows = store.devices.map { device in
            guard let host = device.host else {
                return RemoteDeviceSettingsRow(
                    device: device, state: .offline(reason: "Its SSH destination is not valid."), bundledBuild: bundledBuild()
                )
            }
            seen.insert(host)
            let control = control(host)
            if controlSubscriptions[host] == nil {
                controlSubscriptions[host] = control.$state.removeDuplicates().dropFirst().sink { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
                }
            }
            return RemoteDeviceSettingsRow(
                device: device,
                state: RemoteDeviceConnectionState(
                    control: control.state, sessionCount: control.sessions.count, lastSeen: device.lastSeen
                ),
                bundledBuild: bundledBuild()
            )
        }
        controlSubscriptions = controlSubscriptions.filter { seen.contains($0.key) }
    }

    var canModify: Bool { store.canModify }

    /// Reconnect: connects its control again (now, when it waits to).
    func reconnect(_ id: UUID) {
        guard let host = store.device(id: id)?.host else { return }
        RemoteDevicePeeks.shared.retry(host)
        let control = control(host)
        if case .waitingToReconnect = control.state {
            control.reconnectNow()
        } else {
            Task { _ = try? await control.connect(retryingLoginEnvironment: true) }
        }
    }
}

/// Settings › Sessions › Other Macs.
struct RemoteDevicesSettingsSection: View {
    @ObservedObject var model: RemoteDeviceSettingsModel

    var body: some View {
        if !model.rows.isEmpty {
            SettingsCard("Other Macs") {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsDivider() }
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(color(row.dot))
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.name).font(.system(size: 14, weight: .medium))
                            Text("\(row.destination) · \(row.statusText())")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if row.offersTrustNewIdentity {
                                Button("Trust New Identity…") {
                                    RemoteDeviceAlerts.confirmTrustNewIdentity(of: row.id, store: .shared)
                                }
                            } else if row.offersReconnect {
                                Button("Reconnect") { model.reconnect(row.id) }
                            }
                            if row.updateAvailable {
                                Button(row.updateTitle) { RemoteDeviceUpdatePresenter.present(deviceID: row.id) }
                                    .disabled(!model.canModify)
                            }
                            Button("Set Up Cherry MCP…") { RemoteMCPSetupPresenter.present(deviceID: row.id) }
                            Button("Remove…") { RemoteDeviceAlerts.confirmRemove(row.id, store: .shared) }
                                .disabled(!model.canModify)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func color(_ dot: RemoteDeviceConnectionState.Dot) -> Color {
        switch dot {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .gray: .gray
        }
    }
}
