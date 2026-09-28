import AppKit
import Combine
import Foundation
import Network

/// Brings back tabs attached to an SSH host's sessions whose attach adapter
/// gave up (docs/specs/multiplexer-default.md, "SSH tabs"). An adapter
/// reconnects by itself for a while (`cherry attach`'s reconnect window,
/// 30 s of awake time); once it ends disconnected, or could not attach (the
/// host was unreachable), the tab waits here for its host
/// (`TerminalSession.isWaitingForHost`) instead of staying disconnected.
///
/// Tabs wait per host. Each host is probed through its `HostControl` (one
/// list over one connection, however many of its tabs wait), with the
/// backoff local persistent tabs use (`PersistentLocalSessions.Configuration
/// .reconnectDelay`: 0.25 s doubling to 8 s), and at once when the Mac wakes
/// or the network becomes available (NWPathMonitor), or on Retry Now. Once
/// the host answers, each tab whose session it lists relaunches its adapter;
/// the backoff starts over only once one of them attached. A probe that
/// SSH could not sign in for (a refused key or password, or a host key it
/// refused) stops the timer until the next wake, network change or Retry
/// Now. A tab stops
/// waiting, with the reason on its bar, when connecting again cannot help:
/// another identity answers, the host speaks a protocol this app cannot use,
/// or it no longer has the session (an adapter that said so, with
/// `"reconnectable": false`, never waits). Closing, stopping or reconnecting
/// a tab ends its wait.
@MainActor
final class HostedReconnects: ObservableObject {
    static let shared = HostedReconnects()

    struct Configuration {
        /// Before the first probe after a tab starts waiting, doubling after
        /// each until a tab of the host attaches.
        var delay: (initial: TimeInterval, maximum: TimeInterval) =
            PersistentLocalSessions.Configuration().reconnectDelay
    }

    /// How many tabs wait for each host (by `HostedSessionHost.id`), for the
    /// window's bar ("3 tabs waiting for devbox").
    @Published private(set) var waitingCounts: [String: Int] = [:]
    /// Hosts whose probing stopped because SSH could not sign in, or refused
    /// the host's key, with why: probing again on a timer would repeat the
    /// failed login (which can get the address blocked). A wake, a network
    /// change or Retry Now probes once more.
    @Published private(set) var pausedReasons: [String: String] = [:]

    private final class WeakTab {
        weak var tab: TerminalSession?
        init(_ tab: TerminalSession) { self.tab = tab }
    }

    private final class Group {
        let host: HostedSessionHost
        var tabs: [ObjectIdentifier: WeakTab] = [:]
        /// Probes since a tab of this host last attached: the backoff.
        var attempts = 0
        var timer: Task<Void, Never>?
        var probe: Task<Void, Never>?
        /// A trigger came while a probe ran: probe again once it answers.
        var probeAgain = false
        /// Why probing stopped until a trigger (`pausedReasons`).
        var paused: String?

        init(host: HostedSessionHost) {
            self.host = host
        }

        var liveTabs: [TerminalSession] { tabs.values.compactMap(\.tab) }
    }

    let configuration: Configuration
    private let control: @MainActor (HostedSessionHost) -> HostControl
    private let controls: @MainActor () -> [HostControl]
    private let monitorsSystem: Bool
    private var groups: [String: Group] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    /// How many probes each host got (tests).
    private(set) var probeCounts: [String: Int] = [:]

    /// `monitorsSystem`: follow the Mac's wake and network changes (off in
    /// tests, which call `systemDidWake` and `networkBecameAvailable`).
    init(
        configuration: Configuration = Configuration(),
        control: @escaping @MainActor (HostedSessionHost) -> HostControl = { HostControlRegistry.shared.control(for: $0) },
        controls: @escaping @MainActor () -> [HostControl] = { HostControlRegistry.shared.all },
        monitorsSystem: Bool = true
    ) {
        self.configuration = configuration
        self.control = control
        self.controls = controls
        self.monitorsSystem = monitorsSystem
    }

    isolated deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pathMonitor?.cancel()
        for group in groups.values {
            group.timer?.cancel()
            group.probe?.cancel()
        }
    }

    // MARK: Tabs

    /// `tab`'s adapter ended in a way connecting again may resolve: wait for
    /// its host, then relaunch it.
    func wait(_ tab: TerminalSession) {
        guard let host = tab.hostedAttachment?.host else { return }
        startMonitoringSystem()
        let group = groups[host.id] ?? Group(host: host)
        groups[host.id] = group
        group.tabs[ObjectIdentifier(tab)] = WeakTab(tab)
        tab.setWaitingForHost(true)
        publishCounts()
        if group.timer == nil, group.probe == nil, group.paused == nil {
            schedule(group)
        }
    }

    /// `tab` no longer waits: it was stopped, closed or reconnected.
    func stopWaiting(_ tab: TerminalSession) {
        guard let host = tab.hostedAttachment?.host, let group = groups[host.id],
              group.tabs.removeValue(forKey: ObjectIdentifier(tab)) != nil
        else { return }
        tab.setWaitingForHost(false)
        settle(group)
    }

    /// A tab of this host attached again: its host answers, so the next
    /// wait starts over from the shortest delay.
    func tabAttached(_ tab: TerminalSession) {
        guard let host = tab.hostedAttachment?.host else { return }
        groups[host.id]?.attempts = 0
    }

    /// Tabs waiting for `host` (nil: any host), for Retry Now and tests.
    func waitingTabs(for host: HostedSessionHost? = nil) -> [TerminalSession] {
        groups.values
            .filter { host == nil || $0.host == host }
            .flatMap(\.liveTabs)
    }

    // MARK: Triggers

    /// Retry Now, from a tab's bar: probe `host` (nil: every host) at once
    /// and start the backoff over.
    func retryNow(_ host: HostedSessionHost? = nil) {
        for group in groups.values where host == nil || group.host == host {
            guard !group.liveTabs.isEmpty else { continue }
            group.paused = nil
            group.attempts = 0
            group.timer?.cancel()
            group.timer = nil
            probe(group)
        }
    }

    /// The Mac woke from sleep: every waiting tab's host may answer now, and
    /// control connections waiting to reconnect (a restore that waits for
    /// its host) try at once.
    func systemDidWake() {
        retryNow()
        for control in controls() { control.reconnectNow() }
    }

    /// A network path became available (NWPathMonitor reported satisfied
    /// after it was not).
    func networkBecameAvailable() {
        retryNow()
        for control in controls() { control.reconnectNow() }
    }

    private func startMonitoringSystem() {
        guard monitorsSystem, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(satisfied: satisfied) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "cherry.hosted-reconnects.path"))
        pathMonitor = monitor
    }

    /// NWPathMonitor's latest report: nil before the first, which is the
    /// state when it started rather than a change.
    private var networkSatisfied: Bool?

    private func pathChanged(satisfied: Bool) {
        defer { networkSatisfied = satisfied }
        guard satisfied, networkSatisfied == false else { return }
        networkBecameAvailable()
    }

    // MARK: Probing

    private func delay(after attempts: Int) -> TimeInterval {
        min(configuration.delay.initial * pow(2, Double(attempts)), configuration.delay.maximum)
    }

    private func schedule(_ group: Group) {
        group.timer?.cancel()
        let delay = delay(after: group.attempts)
        group.timer = Task { [weak self, weak group] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let group else { return }
            group.timer = nil
            probe(group)
        }
    }

    /// Lists the host once for all of its waiting tabs.
    private func probe(_ group: Group) {
        guard group.probe == nil else {
            group.probeAgain = true
            return
        }
        guard !group.liveTabs.isEmpty else { return }
        group.attempts += 1
        probeCounts[group.host.id, default: 0] += 1
        let control = control(group.host)
        group.probe = Task { [weak self, weak group] in
            let result: Result<HostedSessionList, Error>
            do {
                result = .success(try await control.list())
            } catch {
                result = .failure(error)
            }
            guard let self, let group else { return }
            group.probe = nil
            finish(group, with: result)
        }
    }

    private func finish(_ group: Group, with result: Result<HostedSessionList, Error>) {
        switch result {
        case .success(let list):
            for tab in group.liveTabs {
                guard let attachment = tab.hostedAttachment else { continue }
                if attachment.hostID != list.hostID {
                    giveUp(tab, in: group, because: "Another host answers for \(group.host.displayName) (identity \(list.hostID), not \(attachment.hostID)); reconnect to the intended host.")
                } else if !list.sessions.contains(where: { $0.id == attachment.sessionID }), !list.awaitsHolders {
                    giveUp(tab, in: group, because: "\(group.host.displayName) no longer has this session.")
                } else if list.sessions.contains(where: { $0.id == attachment.sessionID }) {
                    group.tabs[ObjectIdentifier(tab)] = nil
                    tab.setWaitingForHost(false)
                    tab.reconnectHostedSession()
                }
                // Listed later by a host whose holders still register: wait.
            }
        case .failure(let error):
            let hosted = error as? HostedSessionError
            let reason = hosted?.errorDescription ?? error.localizedDescription
            if hosted?.isIdentityMismatch == true || hosted?.isVersionMismatch == true {
                for tab in group.liveTabs { giveUp(tab, in: group, because: reason) }
            } else if hosted?.isAuthenticationFailure == true {
                group.paused = reason
            }
        }
        if group.probeAgain {
            group.probeAgain = false
            probe(group)
        }
        settle(group)
    }

    private func giveUp(_ tab: TerminalSession, in group: Group, because reason: String) {
        group.tabs[ObjectIdentifier(tab)] = nil
        tab.stopWaitingForHost(because: reason)
    }

    /// Schedules the next probe while tabs still wait; forgets a host none
    /// waits for (keeping its backoff until one of its tabs attaches).
    private func settle(_ group: Group) {
        group.tabs = group.tabs.filter { $0.value.tab != nil }
        if group.tabs.isEmpty {
            group.timer?.cancel()
            group.timer = nil
            group.paused = nil
        } else if group.timer == nil, group.probe == nil, group.paused == nil {
            schedule(group)
        }
        publishCounts()
    }

    private func publishCounts() {
        let counts = groups.compactMapValues { group -> Int? in
            let count = group.liveTabs.count
            return count > 0 ? count : nil
        }
        if counts != waitingCounts { waitingCounts = counts }
        let paused = groups.compactMapValues { group in group.liveTabs.isEmpty ? nil : group.paused }
        if paused != pausedReasons { pausedReasons = paused }
    }

    /// "1 tab waiting for devbox", "3 tabs waiting for devbox".
    static func waitingText(count: Int, host: HostedSessionHost) -> String {
        "\(count) \(count == 1 ? "tab" : "tabs") waiting for \(host.displayName)"
    }
}
