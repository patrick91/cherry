import CherryMobileKit
import Foundation
import Observation

/// The app's state: one connection per Mac, their sessions merged into one
/// inbox, and each Mac's status.
@MainActor
@Observable
final class AppModel {
    enum MacStatus: Equatable {
        case idle
        case connecting
        case connected
        /// A first connect: the Mac presented this host key, and the app
        /// waits for the user to trust it before using the connection.
        case awaitingTrust(fingerprint: String)
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    struct Mac: Identifiable, Equatable {
        var endpoint: MacEndpoint
        var status: MacStatus
        var isDemo: Bool

        var id: UUID { endpoint.id }
    }

    private(set) var macs: [Mac] = []
    /// Every connected Mac's sessions.
    private(set) var sessions: [MobileSession] = []
    /// Bumped when a session's screen changes, so a view showing it reloads.
    private(set) var screenRevisions: [SessionKey: Int] = [:]
    /// This device's public key, or why there is none.
    private(set) var deviceKey: Result<String, KeyUnavailable>?

    struct KeyUnavailable: Error, Equatable {
        var reason: String
    }

    let launch: LaunchOptions

    @ObservationIgnored private let store: MacStore
    @ObservationIgnored private let demo: any MacConnector
    @ObservationIgnored private let ssh: any MacConnector
    @ObservationIgnored private let identity: any DeviceIdentity
    @ObservationIgnored private var connections: [UUID: any MacConnection] = [:]
    @ObservationIgnored private var awaitingTrust: [UUID: any MacConnection] = [:]
    @ObservationIgnored private var eventTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessionsByMac: [UUID: [MobileSession]] = [:]
    @ObservationIgnored private var started = false

    init(
        launch: LaunchOptions,
        store: MacStore = MacStore(),
        demo: any MacConnector = DemoMac(),
        identity: any DeviceIdentity = KeychainDeviceIdentity()
    ) {
        self.launch = launch
        self.store = store
        self.demo = demo
        self.identity = identity
        ssh = SSHMacConnector(identity: identity)
        macs = Self.macs(from: store, demoOnly: launch.demoOnly)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        loadDeviceKey()
        await withTaskGroup(of: Void.self) { group in
            for mac in macs {
                group.addTask { await self.connect(mac.id) }
            }
        }
    }

    /// Lists every connected Mac again, and tries the others again.
    func refresh() async {
        let connected = macs.filter { connections[$0.id] != nil }.map(\.id)
        let others = macs.filter { connections[$0.id] == nil && $0.status != .connecting }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in connected {
                group.addTask { await self.list(id) }
            }
            for id in others {
                group.addTask { await self.connect(id) }
            }
        }
    }

    func connect(_ macID: UUID) async {
        guard let mac = mac(macID) else { return }
        await disconnect(macID)
        setStatus(.connecting, of: macID)
        do {
            let connector = mac.isDemo ? demo : ssh
            let connection = try await connector.connect(to: mac.endpoint)
            guard self.mac(macID) != nil else {
                await connection.disconnect()
                return
            }
            let presented = connection.endpoint.hostKeyFingerprint
            if mac.endpoint.hostKeyFingerprint == nil, let presented, !mac.isDemo {
                awaitingTrust[macID] = connection
                setStatus(.awaitingTrust(fingerprint: presented), of: macID)
                return
            }
            // A Mac trusted before its session host's identity was known
            // pins it now (`--expected-host-id` from the next connect on).
            if !mac.isDemo, mac.endpoint.expectedHostID == nil,
               let hostID = connection.endpoint.expectedHostID,
               var endpoint = self.mac(macID)?.endpoint {
                endpoint.expectedHostID = hostID
                update(endpoint)
            }
            await adopt(connection, for: macID)
        } catch {
            setStatus(.failed(error.localizedDescription), of: macID)
        }
    }

    /// Pins the host key the Mac presented on its first connect, and uses
    /// the connection.
    func trustHostKey(of macID: UUID) async {
        guard let connection = awaitingTrust.removeValue(forKey: macID),
              var endpoint = mac(macID)?.endpoint
        else { return }
        endpoint.hostKeyFingerprint = connection.endpoint.hostKeyFingerprint
        endpoint.expectedHostID = connection.endpoint.expectedHostID
        update(endpoint)
        await adopt(connection, for: macID)
    }

    func rejectHostKey(of macID: UUID) async {
        if let connection = awaitingTrust.removeValue(forKey: macID) {
            await connection.disconnect()
        }
        setStatus(.failed("Not trusted: its host key was not accepted."), of: macID)
    }

    // MARK: - Macs

    /// Adds or changes a Mac, then connects to it again. A changed host or
    /// port forgets the pinned host key and session host identity.
    func save(_ endpoint: MacEndpoint) async {
        var endpoint = endpoint
        if let old = mac(endpoint.id)?.endpoint, old.host != endpoint.host || old.port != endpoint.port {
            endpoint.hostKeyFingerprint = nil
            endpoint.expectedHostID = nil
        }
        if mac(endpoint.id) == nil {
            macs.append(Mac(endpoint: endpoint, status: .idle, isDemo: false))
        }
        update(endpoint)
        await connect(endpoint.id)
    }

    func remove(_ macID: UUID) async {
        guard let mac = mac(macID), !mac.isDemo else { return }
        await disconnect(macID)
        macs.removeAll { $0.id == macID }
        store.endpoints.removeAll { $0.id == macID }
    }

    var showsDemoMac: Bool {
        macs.contains(where: \.isDemo)
    }

    func setShowsDemoMac(_ shows: Bool) async {
        guard shows != showsDemoMac else { return }
        store.showsDemoMac = shows
        if shows {
            macs.insert(Mac(endpoint: DemoMac.endpoint, status: .idle, isDemo: true), at: 0)
            await connect(DemoMac.endpoint.id)
        } else {
            await disconnect(DemoMac.endpoint.id)
            macs.removeAll(where: \.isDemo)
        }
    }

    // MARK: - Sessions

    func mac(_ id: UUID) -> Mac? {
        macs.first { $0.id == id }
    }

    func session(_ key: SessionKey) -> MobileSession? {
        sessions.first { $0.key == key }
    }

    func connection(for macID: UUID) -> (any MacConnection)? {
        connections[macID]
    }

    func screen(of key: SessionKey) async throws -> ScreenSnapshot {
        guard let connection = connections[key.macID] else {
            throw MacConnectionError.unreachable("not connected")
        }
        return try await connection.screen(of: key.sessionID)
    }

    func send(_ keys: [MobileKey], to key: SessionKey) async throws {
        guard let connection = connections[key.macID] else {
            throw MacConnectionError.unreachable("not connected")
        }
        try await connection.send(keys, to: key.sessionID)
        screenRevisions[key, default: 0] += 1
    }

    /// Waits until the Mac listed its sessions once, at most `limit`.
    func waitUntilListed(_ macID: UUID, limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        while sessionsByMac[macID] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Private

    private static func macs(from store: MacStore, demoOnly: Bool) -> [Mac] {
        let demo = Mac(endpoint: DemoMac.endpoint, status: .idle, isDemo: true)
        if demoOnly { return [demo] }
        let saved = store.endpoints.map { Mac(endpoint: $0, status: .idle, isDemo: false) }
        return (store.showsDemoMac ? [demo] : []) + saved
    }

    private func adopt(_ connection: any MacConnection, for macID: UUID) async {
        connections[macID] = connection
        setStatus(.connected, of: macID)
        let events = connection.events()
        eventTasks[macID] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: macID)
            }
        }
        await list(macID)
    }

    private func handle(_ event: MacEvent, from macID: UUID) async {
        switch event {
        case .sessionsChanged, .exited:
            await list(macID)
        case .screenChanged(let sessionID):
            screenRevisions[SessionKey(macID: macID, sessionID: sessionID), default: 0] += 1
        case .disconnected(let reason):
            connections[macID] = nil
            sessionsByMac[macID] = nil
            mergeSessions()
            setStatus(.failed(reason), of: macID)
        }
    }

    private func list(_ macID: UUID) async {
        guard let connection = connections[macID] else { return }
        do {
            let listed = try await connection.sessions()
            guard connections[macID] === connection else { return }
            sessionsByMac[macID] = listed
            mergeSessions()
        } catch {
            setStatus(.failed(error.localizedDescription), of: macID)
        }
    }

    private func disconnect(_ macID: UUID) async {
        eventTasks.removeValue(forKey: macID)?.cancel()
        sessionsByMac[macID] = nil
        mergeSessions()
        if let connection = awaitingTrust.removeValue(forKey: macID) {
            await connection.disconnect()
        }
        if let connection = connections.removeValue(forKey: macID) {
            await connection.disconnect()
        }
    }

    private func mergeSessions() {
        sessions = macs.flatMap { sessionsByMac[$0.id] ?? [] }
    }

    private func setStatus(_ status: MacStatus, of macID: UUID) {
        guard let index = macs.firstIndex(where: { $0.id == macID }) else { return }
        macs[index].status = status
    }

    private func update(_ endpoint: MacEndpoint) {
        if let index = macs.firstIndex(where: { $0.id == endpoint.id }) {
            macs[index].endpoint = endpoint
        }
        guard endpoint.id != DemoMac.endpoint.id else { return }
        var saved = store.endpoints
        if let index = saved.firstIndex(where: { $0.id == endpoint.id }) {
            saved[index] = endpoint
        } else {
            saved.append(endpoint)
        }
        store.endpoints = saved
    }

    private func loadDeviceKey() {
        do {
            deviceKey = .success(try identity.publicKey())
        } catch {
            deviceKey = .failure(KeyUnavailable(reason: error.localizedDescription))
        }
    }
}
