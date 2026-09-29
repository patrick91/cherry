import Combine
import Foundation

/// Looks at devices' sessions for what only shows them (Background
/// Sessions, the Omni bar, the launch notice), never starting or
/// replacing a daemon on another Mac (`HostControl.listWithoutStarting`,
/// `cherry list --no-start`); only the user acting on that Mac (opening one
/// of its projects, Reconnect, Add Mac… or Update Session Host…) may.
///
/// Looks are throttled per device: after a failure (offline, refused) the
/// device is not looked at again for `retryInterval`, and after a refused
/// login, another identity or another protocol not until a wake, a network
/// change, or Reconnect/Retry (`systemChanged`, `retry`). A device that
/// answered is looked at again at most every `answeredInterval`.
@MainActor
final class RemoteDevicePeeks: ObservableObject {
    static let shared = RemoteDevicePeeks()

    struct Entry: Equatable {
        var result: HostSessionPeek
        var at: Date
    }

    typealias Peek = @MainActor (HostControl) async -> HostSessionPeek

    /// The last look at each device, by host id.
    @Published private(set) var entries: [String: Entry] = [:]
    /// Devices not looked at again until a wake, a network change or Retry.
    private(set) var blocked: Set<String> = []
    private var inFlight: [String: Task<HostSessionPeek, Never>] = [:]
    private let peek: Peek
    private let now: @MainActor () -> Date
    let retryInterval: TimeInterval
    let answeredInterval: TimeInterval
    /// How many looks ran, by host id (tests).
    private(set) var peekCounts: [String: Int] = [:]

    /// Follows wakes and network changes (which unblock devices) once one
    /// is blocked.
    private let startMonitoring: @MainActor () -> Void

    init(
        peek: @escaping Peek = { await $0.listWithoutStarting() },
        now: @escaping @MainActor () -> Date = { Date() },
        retryInterval: TimeInterval = 60,
        answeredInterval: TimeInterval = 5,
        startMonitoring: @escaping @MainActor () -> Void = { HostedReconnects.shared.startMonitoringSystem() }
    ) {
        self.startMonitoring = startMonitoring
        self.peek = peek
        self.now = now
        self.retryInterval = retryInterval
        self.answeredInterval = answeredInterval
    }

    /// Whether a look at `host` may run now.
    func mayPeek(_ host: HostedSessionHost) -> Bool {
        guard host.sshDestination != nil, !blocked.contains(host.id), inFlight[host.id] == nil else { return false }
        guard let entry = entries[host.id] else { return true }
        let age = now().timeIntervalSince(entry.at)
        if case .failed = entry.result { return age >= retryInterval }
        return age >= answeredInterval
    }

    /// Looks at `control`'s host unless throttled; returns the latest
    /// result (the one before, when throttled).
    @discardableResult
    func refresh(_ control: HostControl) async -> HostSessionPeek? {
        let host = control.host
        if let running = inFlight[host.id] { return await running.value }
        guard mayPeek(host) else { return entries[host.id]?.result }
        peekCounts[host.id, default: 0] += 1
        let peek = peek
        let task = Task { @MainActor in await peek(control) }
        inFlight[host.id] = task
        let result = await task.value
        inFlight[host.id] = nil
        entries[host.id] = Entry(result: result, at: now())
        if case .failed(let error) = result,
           error.isAuthenticationFailure || error.isIdentityMismatch || error.isVersionMismatch {
            blocked.insert(host.id)
            startMonitoring()
        }
        return result
    }

    /// The sessions the last look listed, when it listed any.
    func list(for host: HostedSessionHost) -> HostedSessionList? {
        if case .listed(let list)? = entries[host.id]?.result { return list }
        return nil
    }

    func result(for host: HostedSessionHost) -> HostSessionPeek? {
        entries[host.id]?.result
    }

    /// A wake or a network change: every device may be looked at again.
    func systemChanged() {
        blocked.removeAll()
        entries = entries.filter { if case .failed = $0.value.result { return false } else { return true } }
    }

    /// Whether a list that opens (the Omni bar, Background Sessions) lists
    /// a host again: not one whose SSH login was refused (that waits for a
    /// wake, a network change or Reconnect: another login on every open can
    /// get the address blocked), nor one another identity or protocol
    /// answers (nothing changes by asking again).
    nonisolated static func refreshesOnOpen(_ state: HostControl.ConnectionState) -> Bool {
        switch state {
        case .idle, .connected:
            return true
        case .connecting:
            return false
        case .waitingToReconnect(let error), .failed(let error):
            return !error.isAuthenticationFailure && !error.isIdentityMismatch && !error.isVersionMismatch
        }
    }

    /// Reconnect or Retry on `host`: it may be looked at again now.
    func retry(_ host: HostedSessionHost) {
        blocked.remove(host.id)
        entries[host.id] = nil
    }
}
