import AppKit
import Combine
import Foundation

// Settings › Macs (docs/specs/remote-devices.md): each device, how it
// stands (connected, offline, needs attention, an update available), its
// name, its windows' colour and its projects, with Reconnect, Update
// Session Host… and Remove…; and the saved SSH hosts no
// Mac uses. The page's views are in Settings/Pages/MacsSettingsPage.swift.

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

    /// A folder of its Projects: one added with Add Project on <Mac>…, or
    /// one the project picker leaves out (Show Again adds it back).
    struct Project: Equatable, Identifiable {
        /// Its path there.
        var path: String
        /// "~/code/api-server": from its home folder there.
        var displayPath: String
        var isHidden: Bool

        var id: String { (isHidden ? "hidden:" : "added:") + path }
    }

    let id: UUID
    let name: String
    let destination: String
    /// Its SSH destination as a host; nil when that is not a valid one.
    let host: HostedSessionHost?
    let status: Status
    /// Update Session Host… (or Reinstall) is offered: its install is older
    /// than this Cherry's, speaks another protocol, or is gone.
    let updateAvailable: Bool
    let updateTitle: String
    let offersReconnect: Bool
    let offersTrustNewIdentity: Bool
    /// Its projects open (Open Home Folder, Add Project on <Mac>…) only
    /// while it answers as itself.
    let allowsOpening: Bool
    /// The colour chosen for its windows; nil: automatic.
    let color: RemoteDeviceColor?
    /// The chosen colour, else the one its id picks.
    let effectiveColor: RemoteDeviceColor
    /// Its home folder there, as the check found it.
    let homeDirectory: String?
    /// Folders added with Add Project on <Mac>…, and those the picker
    /// leaves out, as `devices.json` keeps them.
    let addedProjects: [String]
    let hiddenProjects: [String]
    /// The project key of its home folder (Open Home Folder); nil while
    /// its home is unknown.
    let homeProjectKey: String?

    init(device: RemoteDevice, state: RemoteDeviceConnectionState, bundledBuild: String?) {
        id = device.id
        name = device.name
        color = device.color
        effectiveColor = device.effectiveColor
        destination = device.sshDestination
        host = device.host
        homeDirectory = device.homeDirectory
        addedProjects = device.addedProjects
        hiddenProjects = device.hiddenProjects
        homeProjectKey = device.homeDirectory.map(device.projectKey(path:))
        let menuDevice = TitlebarProjectMenuModel.Device(device: device, state: state, sessions: [], bundledBuild: bundledBuild)
        updateAvailable = menuDevice.offersHostUpdate
        updateTitle = menuDevice.hostUpdateTitle
        offersReconnect = state.offersReconnect
        offersTrustNewIdentity = state.offersTrustNewIdentity
        allowsOpening = state.allowsOpening
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
    /// " · Update available" when there is one and `includingUpdate`
    /// (Settings › Macs shows an update as a tag after the name).
    func statusText(now: Date = Date(), includingUpdate: Bool = true) -> String {
        var text: String = switch status {
        case .connected(let count): count == 1 ? "Connected · 1 session" : "Connected · \(count) sessions"
        case .connecting: "Connecting…"
        case .notConnected(let lastSeen):
            lastSeen.map { "Not connected · last seen \(RemoteDeviceConnectionState.relative($0, now: now))" } ?? "Not checked yet"
        case .offline: "Offline"
        case .needsAttention: "Needs attention"
        }
        if includingUpdate, updateAvailable { text += " · Update available" }
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

    /// Its projects: the added ones, then the hidden ones, each in the
    /// order they were added or hidden.
    var projects: [Project] {
        addedProjects.map { project($0, isHidden: false) } + hiddenProjects.map { project($0, isHidden: true) }
    }

    private func project(_ path: String, isHidden: Bool) -> Project {
        Project(path: path, displayPath: ProjectSwitcherModel.displayPath(path, home: homeDirectory), isHidden: isHidden)
    }
}

/// A saved SSH host no Mac uses (Settings › Macs › SSH hosts): its sessions
/// open from File › Persistent Sessions; Forget… drops it.
struct RemoteDeviceSettingsSSHHost: Equatable, Identifiable {
    let host: HostedSessionHost
    /// Cherry pinned the identity its session host first answered with.
    let isTrusted: Bool

    var id: String { host.id }
    var destination: String { host.displayName }
}

/// The rows, kept current from the device store, each device's control
/// connection (its state and its sessions) and the saved SSH hosts. It
/// never connects: it shows what the connections know. Every change goes
/// through its own store, and its alerts and sheets get that store.
@MainActor
final class RemoteDeviceSettingsModel: ObservableObject {
    /// What Remove…, Trust New Identity… and Update Session Host… show,
    /// each given the model's store: the app's alerts and sheets. Tests
    /// record them.
    struct Presenters {
        var confirmRemove: @MainActor (UUID, RemoteDeviceStore) -> Void = { id, store in
            RemoteDeviceAlerts.confirmRemove(id, store: store)
        }
        var confirmTrustNewIdentity: @MainActor (UUID, RemoteDeviceStore) -> Void = { id, store in
            RemoteDeviceAlerts.confirmTrustNewIdentity(of: id, store: store)
        }
        var updateSessionHost: @MainActor (UUID, RemoteDeviceStore) -> Void = { id, store in
            RemoteDeviceUpdatePresenter.present(deviceID: id, store: store)
        }
    }

    @Published private(set) var rows: [RemoteDeviceSettingsRow] = []
    /// Saved SSH hosts no device uses, in the order they were saved.
    @Published private(set) var sshHostsNotAdded: [RemoteDeviceSettingsSSHHost] = []

    /// The devices it lists: Add Mac… and Add Project on <Mac>… add to it.
    let store: RemoteDeviceStore
    private let hostStore: HostedSessionHostStore
    private let control: @MainActor (HostedSessionHost) -> HostControl
    private let bundledBuild: @MainActor () -> String?
    private let presenters: Presenters
    private var subscriptions: [AnyCancellable] = []
    private var controlSubscriptions: [HostedSessionHost: AnyCancellable] = [:]

    init(
        store: RemoteDeviceStore = .shared,
        hostStore: HostedSessionHostStore = .shared,
        control: @escaping @MainActor (HostedSessionHost) -> HostControl = { HostControlRegistry.shared.control(for: $0) },
        bundledBuild: @escaping @MainActor () -> String? = { RemoteHostHelpers.cachedAppBuild },
        presenters: Presenters = Presenters()
    ) {
        self.store = store
        self.hostStore = hostStore
        self.control = control
        self.bundledBuild = bundledBuild
        self.presenters = presenters
        // Each publishes before it changes: read on the next turn.
        subscriptions.append(store.$devices.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        })
        subscriptions.append(hostStore.$hosts.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        })
        subscriptions.append(hostStore.$trustedHostIDs.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        })
        update()
    }

    func update() {
        var seen = Set<HostedSessionHost>()
        let rows = store.devices.map { device in
            guard let host = device.host else {
                return RemoteDeviceSettingsRow(
                    device: device, state: .offline(reason: "Its SSH destination is not valid."), bundledBuild: bundledBuild()
                )
            }
            seen.insert(host)
            let control = control(host)
            if controlSubscriptions[host] == nil {
                // Its state, and how many sessions it has ("Connected · 3
                // sessions"), which changes while the state does not.
                controlSubscriptions[host] = control.$state.removeDuplicates().dropFirst().map { _ in () }
                    .merge(with: control.$sessions.map(\.count).removeDuplicates().dropFirst().map { _ in () })
                    .sink { [weak self] in
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
        let sshHosts = Self.sshHostsNotAdded(hosts: hostStore.hosts, devices: store.devices) {
            hostStore.trustedHostID(for: $0) != nil
        }
        // Only a change re-renders the page.
        if rows != self.rows { self.rows = rows }
        if sshHosts != sshHostsNotAdded { sshHostsNotAdded = sshHosts }
    }

    /// The saved SSH hosts no device uses (a device's destination is a
    /// saved host too), with whether each has a trusted identity.
    static func sshHostsNotAdded(
        hosts: [HostedSessionHost],
        devices: [RemoteDevice],
        isTrusted: (HostedSessionHost) -> Bool = { _ in false }
    ) -> [RemoteDeviceSettingsSSHHost] {
        let devicesHosts = Set(devices.compactMap(\.host))
        return hosts
            .filter { !devicesHosts.contains($0) }
            .map { RemoteDeviceSettingsSSHHost(host: $0, isTrusted: isTrusted($0)) }
    }

    var canModify: Bool { store.canModify }

    /// Its windows' colour (nil: automatic).
    func setColor(_ color: RemoteDeviceColor?, for id: UUID) {
        store.setColor(color, for: id)
        update()
    }

    /// Its name field: the name, trimmed. False, changing nothing, for an
    /// empty name, a device that is gone, or while another copy of Cherry
    /// keeps the devices.
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.canModify, store.device(id: id) != nil else { return false }
        store.rename(id, to: trimmed)
        update()
        return store.device(id: id)?.name == trimmed
    }

    /// Remove… of an added project: the picker leaves it out, and its row
    /// says Hidden.
    func hideProject(path: String, on id: UUID) {
        store.hideProject(path: path, on: id)
        update()
    }

    /// Show Again: the hidden folder is one of its added projects again.
    func showProjectAgain(path: String, on id: UUID) {
        store.addProject(path: path, to: id)
        update()
    }

    /// Forget… of a saved SSH host: the host and its trusted identity go;
    /// its sessions keep running there. Like the Persistent Sessions
    /// sheet's Forget Host, any copy of Cherry may.
    func forget(_ host: HostedSessionHost) {
        hostStore.remove(host)
        update()
    }

    /// Reconnect: connects its control again (now, when it waits to).
    func reconnect(_ id: UUID) {
        guard let host = store.device(id: id)?.host else { return }
        control(host).reconnectAsked()
    }

    func confirmRemove(_ id: UUID) {
        presenters.confirmRemove(id, store)
    }

    func trustNewIdentity(_ id: UUID) {
        presenters.confirmTrustNewIdentity(id, store)
    }

    func updateSessionHost(_ id: UUID) {
        presenters.updateSessionHost(id, store)
    }
}
