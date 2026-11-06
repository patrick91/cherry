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

/// Pair iPhone…: checks Remote Login, starts the listener with a new code
/// and shows the offer as a QR code, asks you when a phone sends its key,
/// adds it to `~/.ssh/authorized_keys` when you allow it, and stops
/// listening when the code is used, expires or the sheet closes.
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
        case paired(String)
        /// What went wrong, and the line to add by hand when the key could
        /// not be.
        case failed(String, line: String?)
        case expired
    }

    @Published private(set) var state: State = .starting

    let keys: AuthorizedPhoneKeys
    let environment: MobilePairingEnvironment
    /// Called once a phone's key is added (the page lists it).
    var onPaired: @MainActor () -> Void = {}

    private var listener: MobilePairingListener?
    private var pending: (request: MobilePairingListener.Request, answer: CheckedContinuation<MobilePairingListener.Answer, Never>)?
    private var expiry: Task<Void, Never>?
    /// Bumped by each start and stop, so a slow start that a newer one
    /// replaced lets its listener go.
    private var generation = 0

    init(keys: AuthorizedPhoneKeys = .standard(), environment: MobilePairingEnvironment = .live) {
        self.keys = keys
        self.environment = environment
    }

    /// Starts, unless something did already.
    func startIfNeeded() async {
        guard generation == 0 else { return }
        await start()
    }

    /// Shows a new code, after checking Remote Login.
    func start() async {
        stop()
        let generation = generation
        state = .starting
        guard await environment.remoteLoginIsOn() else {
            if generation == self.generation { state = .remoteLoginOff }
            return
        }
        let code = MobilePairingOffer.newCode()
        let environment = environment
        let listener = MobilePairingListener(code: code, macName: environment.macName(), user: environment.user()) { [weak self] request in
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
                name: environment.macName(),
                user: environment.user(),
                hosts: environment.hosts(),
                hostKeyFingerprints: environment.hostKeyFingerprints(),
                pairingPort: port,
                code: code
            ))
            expiry = Task { [weak self] in
                try? await Task.sleep(for: environment.lifetime)
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
    func allow() {
        guard let (request, answer) = pending else { return }
        pending = nil
        stopListening()
        do {
            try keys.add(request.key, name: request.name)
            state = .paired(request.name)
            answer.resume(returning: .added)
            onPaired()
        } catch {
            let failure = error as? AuthorizedPhoneKeys.Failure
            let message = failure?.errorDescription ?? error.localizedDescription
            state = .failed(message, line: failure?.line)
            answer.resume(returning: .failed(message))
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
