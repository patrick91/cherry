import Foundation
import Network
import os

/// What pairing needs from the system: this Mac's name, user, addresses
/// and host keys, and whether Remote Login answers. Tests give their own.
struct MobilePairingEnvironment: Sendable {
    var macName: @Sendable () -> String
    var user: @Sendable () -> String
    var hosts: @Sendable () -> [String]
    var hostKeyFingerprints: @Sendable () -> [String]
    var remoteLoginIsOn: @Sendable () async -> Bool
    /// How long a code works.
    var lifetime: Duration

    static let live = MobilePairingEnvironment(
        macName: { MobilePairingMac.name() },
        user: { NSUserName() },
        hosts: { MobilePairingMac.hosts() },
        hostKeyFingerprints: { MobilePairingMac.hostKeyFingerprints() },
        remoteLoginIsOn: { await sshAnswers() },
        lifetime: .seconds(600)
    )

    /// Whether something listens on this Mac's port 22 (Remote Login),
    /// within a second.
    static func sshAnswers() async -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: 22, using: .tcp)
        let answered = OSAllocatedUnfairLockBox(false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ result: Bool) {
                guard answered.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(false) }
        }
    }
}

/// What an offer says of the Mac a phone pairs with.
struct MobilePairingMacDescription: Equatable, Sendable {
    var name: String
    var user: String
    var hosts: [String]
    var sshPort: Int = 22
    var hostKeyFingerprints: [String]
}

/// The Mac a phone pairs with: this Mac (`thisMac`), or one of the user's
/// other Macs that this Mac reaches over SSH (`RemotePhonePairing.target`),
/// whose code the phone reads here (a version 2 offer).
struct MobilePairingTarget: Sendable {
    enum Problem: Error, Equatable {
        /// This Mac's Remote Login is off.
        case remoteLoginOff
        /// Why the other Mac can't be paired with now.
        case unavailable(String)
    }

    /// The Mac in the sheet's sentences: "this Mac", "patstudio".
    var displayName: String
    var isThisMac: Bool
    /// What the offer says of the Mac, read each time a code is shown.
    var describe: @Sendable () async -> Result<MobilePairingMacDescription, Problem>
    /// Adds a phone's key (its name second), limited to Cherry's gateway:
    /// throws a `PhoneKeyFailure` with the line to add by hand, or another
    /// error.
    var addKey: @Sendable (SSHPublicKeyLine, String) async throws -> Void

    static func thisMac(keys: AuthorizedPhoneKeys = .standard(), environment: MobilePairingEnvironment = .live) -> MobilePairingTarget {
        MobilePairingTarget(
            displayName: "this Mac",
            isThisMac: true,
            describe: {
                guard await environment.remoteLoginIsOn() else { return .failure(.remoteLoginOff) }
                return .success(MobilePairingMacDescription(
                    name: environment.macName(),
                    user: environment.user(),
                    hosts: environment.hosts(),
                    hostKeyFingerprints: environment.hostKeyFingerprints()
                ))
            },
            addKey: { key, name in try keys.add(key, name: name) }
        )
    }
}

/// A flag that one caller claims.
final class OSAllocatedUnfairLockBox: Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>

    init(_ claimed: Bool) {
        lock = OSAllocatedUnfairLock(initialState: claimed)
    }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Pair iPhone…: reads what the offer says of the Mac (checking this Mac's
/// Remote Login, or reaching the other Mac), starts the listener with a new
/// code and shows the offer as a QR code, asks you when a phone sends its
/// key, adds it to the Mac's `~/.ssh/authorized_keys` when you allow it,
/// and stops listening when the code is used, expires or the sheet closes.
@MainActor
final class MobilePairingModel: ObservableObject {
    struct Prompt: Equatable {
        var phone: String
        var fingerprint: String
    }

    enum State: Equatable {
        case starting
        case remoteLoginOff
        case waiting(MobilePairingOffer)
        case asking(Prompt)
        /// Allowed: its key is being added (on another Mac, over SSH).
        case adding(String)
        case paired(String)
        /// What went wrong, and the line to add by hand when the key could
        /// not be.
        case failed(String, line: String?)
        case expired
    }

    @Published private(set) var state: State = .starting

    let target: MobilePairingTarget
    /// How long a code works.
    let lifetime: Duration
    /// This Mac's addresses, where the phone reaches the listener when it
    /// pairs with another Mac.
    let listenerHosts: @Sendable () -> [String]
    /// What the shown code says of the Mac (its user, for the question).
    private(set) var describedMac: MobilePairingMacDescription?
    /// Called once a phone's key is added (the page lists it).
    var onPaired: @MainActor () -> Void = {}

    private var listener: MobilePairingListener?
    private var pending: (request: MobilePairingListener.Request, answer: CheckedContinuation<MobilePairingListener.Answer, Never>)?
    private var expiry: Task<Void, Never>?
    /// Bumped by each start and stop, so a slow start that a newer one
    /// replaced lets its listener go.
    private var generation = 0

    init(
        target: MobilePairingTarget,
        lifetime: Duration = .seconds(600),
        listenerHosts: @escaping @Sendable () -> [String] = { MobilePairingMac.hosts() }
    ) {
        self.target = target
        self.lifetime = lifetime
        self.listenerHosts = listenerHosts
    }

    /// Pairing with this Mac.
    convenience init(keys: AuthorizedPhoneKeys = .standard(), environment: MobilePairingEnvironment = .live) {
        self.init(target: .thisMac(keys: keys, environment: environment), lifetime: environment.lifetime, listenerHosts: environment.hosts)
    }

    /// Starts, unless something did already.
    func startIfNeeded() async {
        guard generation == 0 else { return }
        await start()
    }

    /// Shows a new code, once the Mac is described (Remote Login on, the
    /// other Mac reached).
    func start() async {
        stop()
        let generation = generation
        state = .starting
        let described = await target.describe()
        guard generation == self.generation else { return }
        let mac: MobilePairingMacDescription
        switch described {
        case .success(let found): mac = found
        case .failure(.remoteLoginOff):
            state = .remoteLoginOff
            return
        case .failure(.unavailable(let reason)):
            state = .failed(reason, line: nil)
            return
        }
        describedMac = mac
        let code = MobilePairingOffer.newCode()
        let lifetime = lifetime
        let listener = MobilePairingListener(code: code, macName: mac.name, user: mac.user) { [weak self] request in
            await self?.decide(request) ?? .declined
        }
        do {
            let port = try await listener.start()
            guard generation == self.generation else {
                listener.stop()
                return
            }
            self.listener = listener
            state = .waiting(MobilePairingOffer(
                name: mac.name,
                user: mac.user,
                hosts: mac.hosts,
                sshPort: mac.sshPort,
                hostKeyFingerprints: mac.hostKeyFingerprints,
                pairingPort: port,
                code: code,
                listenerHosts: target.isThisMac ? [] : listenerHosts()
            ))
            expiry = Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                guard !Task.isCancelled else { return }
                self?.expire(generation)
            }
        } catch {
            listener.stop()
            if generation == self.generation {
                state = .failed("Cherry couldn't listen for your iPhone (\(error.localizedDescription)).", line: nil)
            }
        }
    }

    /// Adds the asking phone's key.
    func allow() async {
        guard let (request, answer) = pending else { return }
        pending = nil
        stopListening()
        let generation = generation
        state = .adding(request.name)
        do {
            try await target.addKey(request.key, request.name)
            answer.resume(returning: .added)
            guard generation == self.generation else { return }
            state = .paired(request.name)
            onPaired()
        } catch {
            let failure = error as? any PhoneKeyFailure
            let message = failure?.errorDescription ?? error.localizedDescription
            answer.resume(returning: .failed(message))
            guard generation == self.generation else { return }
            state = .failed(message, line: failure?.line)
        }
    }

    /// Refuses the asking phone, and shows a new code.
    func deny() async {
        pending?.answer.resume(returning: .declined)
        pending = nil
        await start()
    }

    /// Stops listening: the sheet closed.
    func stop() {
        generation += 1
        pending?.answer.resume(returning: .declined)
        pending = nil
        stopListening()
    }

    private func stopListening() {
        expiry?.cancel()
        expiry = nil
        listener?.stop()
        listener = nil
    }

    private func decide(_ request: MobilePairingListener.Request) async -> MobilePairingListener.Answer {
        guard pending == nil, case .waiting = state else { return .declined }
        expiry?.cancel()
        state = .asking(Prompt(phone: request.name, fingerprint: request.key.fingerprint))
        return await withCheckedContinuation { answer in
            pending = (request, answer)
        }
    }

    private func expire(_ generation: Int) {
        guard generation == self.generation, case .waiting = state else { return }
        stopListening()
        state = .expired
    }
}

/// The phones Settings › Devices lists, read from `~/.ssh/authorized_keys`
/// when the page shows and after a pairing.
@MainActor
final class PairedPhonesModel: ObservableObject {
    @Published private(set) var phones: [AuthorizedPhoneKeys.Phone] = []
    let keys: AuthorizedPhoneKeys

    init(keys: AuthorizedPhoneKeys = .standard()) {
        self.keys = keys
    }

    func reload() {
        phones = keys.phones()
    }

    func remove(_ phone: AuthorizedPhoneKeys.Phone) throws {
        defer { reload() }
        try keys.remove(phone)
    }

    /// Limits a phone paired before Cherry limited keys to Cherry's
    /// sessions.
    func limit(_ phone: AuthorizedPhoneKeys.Phone) throws {
        defer { reload() }
        try keys.limit(phone)
    }
}

/// The phones paired with each of the user's other Macs, for their cards in
/// Settings › Devices: read when the page shows and after a change, over a
/// Mac's SSH master only while it is up (the page never connects a Mac).
@MainActor
final class DevicePhonesModel: ObservableObject {
    @Published private(set) var phones: [UUID: [AuthorizedPhoneKeys.Phone]] = [:]
    /// A Mac's phone keys. `connects`: a user's action may log in to it;
    /// else nil while its master is down.
    let keys: @MainActor (RemoteDevice, _ connects: Bool) -> RemotePhoneKeys?
    private var reads: [UUID: Task<Void, Never>] = [:]

    init(keys: @escaping @MainActor (RemoteDevice, _ connects: Bool) -> RemotePhoneKeys? = DevicePhonesModel.appKeys) {
        self.keys = keys
    }

    static func appKeys(_ device: RemoteDevice, connects: Bool) -> RemotePhoneKeys? {
        guard connects || HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination) != nil else { return nil }
        return RemotePhoneKeys(device: device)
    }

    /// Reads the phones of each of `devices` that can be read now, keeping
    /// what was read of the others; forgets Macs no longer there.
    func reload(_ devices: [RemoteDevice]) {
        let ids = Set(devices.map(\.id))
        phones = phones.filter { ids.contains($0.key) }
        for device in devices { reload(device) }
    }

    /// `connects`: after a user's action, which may have logged in.
    func reload(_ device: RemoteDevice, connects: Bool = false) {
        guard let keys = keys(device, connects) else { return }
        let id = device.id
        reads[id]?.cancel()
        reads[id] = Task { [weak self] in
            guard let found = try? await keys.phones(), !Task.isCancelled else { return }
            self?.phones[id] = found
        }
    }

    func remove(_ phone: AuthorizedPhoneKeys.Phone, from device: RemoteDevice) async throws {
        defer { reload(device, connects: true) }
        try await keys(device, true)?.remove(phone)
    }

    /// Limits a phone paired with `device` before Cherry limited keys.
    func limit(_ phone: AuthorizedPhoneKeys.Phone, on device: RemoteDevice) async throws {
        defer { reload(device, connects: true) }
        try await keys(device, true)?.limit(phone)
    }
}
