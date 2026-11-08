import CherryMobileKit
import Foundation
import Network
import Observation
import os
import UIKit

/// The app's state: one connection per Mac, their sessions merged into one
/// inbox, and each Mac's status.
///
/// Connections come back by themselves (docs/specs/ios-app.md, Reconnects):
/// a dropped one, or a connect that failed for a reason that can clear up,
/// is tried again with growing waits while the app is in front and the
/// network is up; in the background every connection closes after a short
/// grace, and coming back, or a network change, checks and reconnects them
/// all at once. A Mac's sessions stay listed while it reconnects.
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
        /// Lost, or not reachable now: the app tries again by itself. The
        /// reason is the last attempt's.
        case reconnecting(String)
        /// Refused for a reason only the user can change.
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        var isReconnecting: Bool {
            if case .reconnecting = self { return true }
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

    /// A Mac to pair with: one whose code the iPhone's camera opened, or
    /// none yet (the Macs screen's Pair a Mac, which scans first).
    struct PairingRequest: Identifiable {
        let id = UUID()
        var offer: PairingOffer?
    }

    var pairing: PairingRequest?
    private var connections: [UUID: any MacConnection] = [:]

    struct KeyUnavailable: Error, Equatable {
        var reason: String
    }

    let launch: LaunchOptions

    /// How long connections stay open once the app is in the background,
    /// so a quick look at another app reconnects nothing.
    static let backgroundGrace: Duration = .seconds(20)
    /// How long a connection has to answer when the app comes back or the
    /// network changes.
    static let checkTimeout: Duration = .seconds(3)

    @ObservationIgnored private let store: MacStore
    @ObservationIgnored private let demo: any MacConnector
    @ObservationIgnored private let ssh: any MacConnector
    @ObservationIgnored private let identity: any DeviceIdentity
    @ObservationIgnored private var awaitingTrust: [UUID: any MacConnection] = [:]
    @ObservationIgnored private var eventTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessionsByMac: [UUID: [MobileSession]] = [:]
    @ObservationIgnored private var started = false
    /// Each Mac's connect generation: a connect whose generation moved on
    /// while it waited (another connect, a disconnect) drops what it got.
    @ObservationIgnored private var generations: [UUID: Int] = [:]
    @ObservationIgnored private var retries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var networkIsUp = true
    @ObservationIgnored private var interfaces: [String]?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var backgroundClose: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let log = Logger(subsystem: "dev.patrick.cherry.mobile", category: "Connections")

    init(
        launch: LaunchOptions,
        store: MacStore = MacStore(),
        demo: (any MacConnector)? = nil,
        identity: any DeviceIdentity = KeychainDeviceIdentity()
    ) {
        self.launch = launch
        self.store = store
        self.demo = demo ?? DemoMac(turnDuration: launch.demoTurnDuration, dropsAfter: launch.demoDropsAfter, longConversation: launch.demoLongConversation, incremental: launch.demoIncremental)
        self.identity = identity
        ssh = SSHMacConnector(identity: identity)
        macs = Self.macs(from: store, demoOnly: launch.demoOnly)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        loadDeviceKey()
        watchNetwork()
        if let offer = launch.pairing.flatMap(PairingOffer.init(url:)) {
            pairing = PairingRequest(offer: offer)
        }
        await withTaskGroup(of: Void.self) { group in
            for mac in macs {
                group.addTask { await self.connect(mac.id) }
            }
        }
    }

    /// Lists every connected Mac again, and tries the others again now.
    func refresh() async {
        let connected = macs.filter { connections[$0.id] != nil }.map(\.id)
        let others = macs.filter {
            guard connections[$0.id] == nil else { return false }
            switch $0.status {
            case .connecting, .awaitingTrust: return false
            default: return true
            }
        }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in connected {
                group.addTask { await self.list(id) }
            }
            for id in others {
                group.addTask { await self.connect(id) }
            }
        }
    }

    /// The app came to the front: connections closed in the background come
    /// back, and the ones still open must answer.
    func didBecomeActive() async {
        guard started, !isActive else { return }
        isActive = true
        backgroundClose?.cancel()
        backgroundClose = nil
        endBackgroundTask()
        log.info("active: checking connections")
        await checkConnections()
    }

    /// The app went to the background: its connections close after
    /// `backgroundGrace`, before iOS suspends it, so no Mac keeps an
    /// attachment (and the grid it set) for a phone that is gone.
    func didEnterBackground() {
        guard started, isActive else { return }
        isActive = false
        cancelRetries()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Close connections") { [weak self] in
            MainActor.assumeIsolated {
                self?.closeForBackground()
            }
        }
        backgroundClose = Task { [weak self] in
            try? await Task.sleep(for: Self.backgroundGrace)
            guard !Task.isCancelled else { return }
            self?.closeForBackground()
        }
    }

    func connect(_ macID: UUID) async {
        await connect(macID, retrying: false)
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

    /// Sends this device's key to the Mac of `offer` and waits for it to
    /// allow it (`reached` hears the address that answered), then adds the
    /// Mac, or updates it when it was added before, and connects.
    func pair(with offer: PairingOffer, reached: @escaping @Sendable (String) async -> Void) async throws -> MacEndpoint {
        let key = try identity.publicKey()
        var endpoint = try await MacPairing.pair(offer, publicKey: key, deviceName: UIDevice.current.name, reached: reached)
        if let existing = macs.first(where: {
            !$0.isDemo && $0.endpoint.user == endpoint.user && ($0.endpoint.host == endpoint.host || $0.endpoint.name == endpoint.name)
        }) {
            endpoint.id = existing.id
            endpoint.cherryPath = existing.endpoint.cherryPath
        }
        await save(endpoint)
        return endpoint
    }

    func remove(_ macID: UUID) async {
        guard let mac = mac(macID), !mac.isDemo else { return }
        cancelRetry(macID)
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
            cancelRetry(DemoMac.endpoint.id)
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

    func transcript(of key: SessionKey, after cursor: String?, limit: Int) async throws -> AgentTranscript {
        guard let connection = connections[key.macID] else {
            throw MacConnectionError.unreachable("not connected")
        }
        return try await connection.transcript(of: key.sessionID, after: cursor, limit: limit)
    }

    func send(_ keys: [MobileKey], to key: SessionKey) async throws {
        guard let connection = connections[key.macID] else {
            throw MacConnectionError.unreachable("not connected")
        }
        try await connection.send(keys, to: key.sessionID)
        screenRevisions[key, default: 0] += 1
    }

    /// Types `text` into the session and submits it, its Enter sent on its
    /// own (`MacConnection.submit`).
    func submit(_ text: String, to key: SessionKey) async throws {
        guard let connection = connections[key.macID] else {
            throw MacConnectionError.unreachable("not connected")
        }
        try await connection.submit(text, to: key.sessionID)
        screenRevisions[key, default: 0] += 1
    }

    /// Waits until the Mac listed its sessions once, at most `limit`.
    func waitUntilListed(_ macID: UUID, limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        while sessionsByMac[macID] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Connecting

    private static func macs(from store: MacStore, demoOnly: Bool) -> [Mac] {
        let demo = Mac(endpoint: DemoMac.endpoint, status: .idle, isDemo: true)
        if demoOnly { return [demo] }
        let saved = store.endpoints.map { Mac(endpoint: $0, status: .idle, isDemo: false) }
        return (store.showsDemoMac ? [demo] : []) + saved
    }

    /// Connects to the Mac, replacing any connection it has. `retrying` is
    /// the app's own try: it keeps the try count and a reconnecting status.
    private func connect(_ macID: UUID, retrying: Bool) async {
        guard let mac = mac(macID) else { return }
        cancelRetry(macID)
        if !retrying { attempts[macID] = 0 }
        await disconnect(macID, keepingSessions: true)
        let generation = generations[macID, default: 0]
        if !(retrying && mac.status.isReconnecting) {
            setStatus(.connecting, of: macID)
        }
        do {
            let connector = mac.isDemo ? demo : ssh
            let connection = try await connector.connect(to: mac.endpoint)
            guard generations[macID, default: 0] == generation, self.mac(macID) != nil else {
                await connection.disconnect()
                return
            }
            let presented = connection.endpoint.hostKeyFingerprint
            // A Mac paired with its code accepted only a host key the code
            // listed: it is pinned without asking.
            if mac.endpoint.hostKeyFingerprint == nil, let presented,
               mac.endpoint.pairedHostKeyFingerprints?.contains(presented) == true,
               var endpoint = self.mac(macID)?.endpoint {
                endpoint.hostKeyFingerprint = presented
                endpoint.expectedHostID = connection.endpoint.expectedHostID
                update(endpoint)
                await adopt(connection, for: macID)
                return
            }
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
            guard generations[macID, default: 0] == generation else { return }
            couldNotConnect(macID, error)
        }
    }

    /// A connect failed: tried again later when that can help, else the
    /// Mac waits for the user.
    private func couldNotConnect(_ macID: UUID, _ error: any Error) {
        let reason = error.localizedDescription
        if ReconnectPolicy.retries(after: error) {
            log.info("\(self.name(macID), privacy: .public) unreachable: \(reason, privacy: .public)")
            setStatus(.reconnecting(reason), of: macID)
            scheduleRetry(macID)
        } else {
            log.info("\(self.name(macID), privacy: .public) refused: \(reason, privacy: .public)")
            sessionsByMac[macID] = nil
            mergeSessions()
            setStatus(.failed(reason), of: macID)
        }
    }

    private func adopt(_ connection: any MacConnection, for macID: UUID) async {
        connections[macID] = connection
        attempts[macID] = 0
        setStatus(.connected, of: macID)
        log.info("\(self.name(macID), privacy: .public) connected")
        let events = connection.events()
        let id = ObjectIdentifier(connection)
        eventTasks[macID] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, from: macID, connection: id)
            }
        }
        await list(macID)
        // Views showing this Mac's sessions read them again from the new
        // connection.
        for session in sessionsByMac[macID] ?? [] {
            screenRevisions[session.key, default: 0] += 1
        }
    }

    private func handle(_ event: MacEvent, from macID: UUID, connection: ObjectIdentifier) async {
        guard let current = connections[macID], ObjectIdentifier(current) == connection else { return }
        switch event {
        case .sessionsChanged, .exited:
            await list(macID)
        case .screenChanged(let sessionID):
            screenRevisions[SessionKey(macID: macID, sessionID: sessionID), default: 0] += 1
        case .disconnected(let reason):
            log.info("\(self.name(macID), privacy: .public) lost: \(reason, privacy: .public)")
            eventTasks.removeValue(forKey: macID)
            connections[macID] = nil
            attempts[macID] = 0
            // Its control channel ended; the SSH connection under it, and
            // any terminal on it, close too.
            Task { await current.disconnect() }
            setStatus(.reconnecting(reason), of: macID)
            scheduleRetry(macID)
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
            guard connections[macID] === connection else { return }
            await disconnect(macID, keepingSessions: true)
            couldNotConnect(macID, error)
        }
    }

    /// Ends the Mac's connection. Its sessions stay listed when it is to
    /// come back (`keepingSessions`).
    private func disconnect(_ macID: UUID, keepingSessions: Bool = false) async {
        generations[macID, default: 0] += 1
        eventTasks.removeValue(forKey: macID)?.cancel()
        if !keepingSessions {
            sessionsByMac[macID] = nil
            mergeSessions()
        }
        if let connection = awaitingTrust.removeValue(forKey: macID) {
            await connection.disconnect()
        }
        if let connection = connections.removeValue(forKey: macID) {
            await connection.disconnect()
        }
    }

    // MARK: - Reconnecting

    /// Tries the Mac again after the policy's wait, while the app is in
    /// front and the network is up (else `checkConnections` does, once they
    /// are).
    private func scheduleRetry(_ macID: UUID) {
        guard isActive, networkIsUp, retries[macID] == nil else { return }
        let attempt = attempts[macID, default: 0] + 1
        attempts[macID] = attempt
        let delay = ReconnectPolicy.standard.delay(beforeAttempt: attempt)
        log.info("\(self.name(macID), privacy: .public) retry \(attempt) in \(String(describing: delay), privacy: .public)")
        retries[macID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retries[macID] = nil
            await self.connect(macID, retrying: true)
        }
    }

    private func cancelRetry(_ macID: UUID) {
        retries.removeValue(forKey: macID)?.cancel()
    }

    private func cancelRetries() {
        for task in retries.values { task.cancel() }
        retries.removeAll()
    }

    /// Back in front, or on another network: every open connection must
    /// answer within `checkTimeout` (one that does not ends, and is tried
    /// again), and every Mac waiting to reconnect tries now.
    private func checkConnections() async {
        guard isActive, networkIsUp else { return }
        let timeout = Self.checkTimeout
        await withTaskGroup(of: Void.self) { group in
            for mac in macs {
                if let connection = connections[mac.id] {
                    group.addTask { try? await connection.ping(timeout: timeout) }
                } else if mac.status.isReconnecting || mac.status == .idle {
                    attempts[mac.id] = 0
                    group.addTask { await self.connect(mac.id, retrying: true) }
                }
            }
        }
    }

    private func closeForBackground() {
        backgroundClose?.cancel()
        backgroundClose = nil
        guard !isActive else {
            endBackgroundTask()
            return
        }
        let open = macs.filter { connections[$0.id] != nil || $0.status == .connecting || $0.status.isReconnecting }
        log.info("background: closing \(open.count) connection(s)")
        for mac in open {
            setStatus(.reconnecting("Cherry was in the background."), of: mac.id)
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for mac in open {
                    group.addTask { await self.disconnect(mac.id, keepingSessions: true) }
                }
            }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Follows the network: while it is down nothing is tried; once it is
    /// back, or the interfaces change (Wi-Fi to cellular, another Wi-Fi),
    /// the connections are checked.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            let names = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                await self?.networkChanged(isUp: isUp, interfaces: names)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.patrick.cherry.mobile.network"))
        pathMonitor = monitor
    }

    private func networkChanged(isUp: Bool, interfaces names: [String]) async {
        let wasUp = networkIsUp
        let previous = interfaces
        networkIsUp = isUp
        interfaces = names
        // The first update is the network as it is at launch.
        guard previous != nil else { return }
        guard isUp else {
            if wasUp { log.info("network down") }
            cancelRetries()
            return
        }
        guard !wasUp || names != previous else { return }
        log.info("network changed: \(names.joined(separator: ","), privacy: .public)")
        await checkConnections()
    }

    // MARK: - Private

    private func mergeSessions() {
        sessions = macs.flatMap { sessionsByMac[$0.id] ?? [] }
    }

    private func setStatus(_ status: MacStatus, of macID: UUID) {
        guard let index = macs.firstIndex(where: { $0.id == macID }) else { return }
        macs[index].status = status
    }

    private func name(_ macID: UUID) -> String {
        mac(macID)?.endpoint.name ?? macID.uuidString
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
