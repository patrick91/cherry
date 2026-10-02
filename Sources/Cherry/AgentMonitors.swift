import CherryControl
import Foundation

// MARK: - Monitors
//
// An agent subscribes (MCP `subscribe`) to events of other processes:
// done, needs_input, permission, error, exited, closed, output_match. A
// sampler on the main actor looks at every watched process while any
// subscription exists, numbers each subscription's events, and keeps them
// until `wait_for_events` reads them. When the subscriber is an agent tab
// Cherry confirmed is the caller, Cherry types one wake line into it once
// events are ready and the subscriber is idle: no MCP client shows the
// model a server's notifications, and typed input is what every agent
// CLI takes. The line names only the subscription and event counts, never
// a watched process's text. Subscriptions live in memory: a relaunch of
// Cherry ends them (`unknown_subscription`), and callers subscribe again.

/// A subscription's state (main actor only).
@MainActor
final class MonitorSubscription {
    let id: String
    let createdAt: Date
    /// The device of the caller on another Mac that made it, nil for This
    /// Mac: only that caller's requests find it.
    let device: UUID?
    let subscriberID: String?
    weak var subscriber: TerminalSession?
    let subAgents: Bool
    let events: Set<MonitorEventType>
    let orderedEvents: [MonitorEventType]
    let outputPattern: String?
    let wakeRequested: Bool
    let wakeUnavailableReason: String?
    var watched: [WatchedProcess] = []
    var pending: [MonitorEvent] = []
    var nextSeq = 1
    var ackCursor = 0
    var droppedEvents = 0
    var lastWokenSeq = 0
    var lastWakeAt: Date?
    var isWaking = false
    var activeWaits = 0
    var lastReadAt: Date

    init(
        id: String,
        device: UUID?,
        subscriber: TerminalSession?,
        subAgents: Bool,
        events: [MonitorEventType],
        outputPattern: String?,
        wakeRequested: Bool,
        wakeUnavailableReason: String?
    ) {
        self.id = id
        self.createdAt = Date()
        self.device = device
        self.subscriberID = subscriber?.id.uuidString
        self.subscriber = subscriber
        self.subAgents = subAgents
        self.orderedEvents = events
        self.events = Set(events)
        self.outputPattern = outputPattern
        self.wakeRequested = wakeRequested
        self.wakeUnavailableReason = wakeUnavailableReason
        self.lastReadAt = createdAt
    }

    func isWatching(_ session: TerminalSession) -> Bool {
        watched.contains { $0.session === session || $0.id == session.id.uuidString }
    }
}

@MainActor
final class WatchedProcess {
    let id: String
    weak var session: TerminalSession?
    weak var workspace: TerminalWorkspace?
    var name: String
    let kind: String
    /// The status the last sample saw; nil before the first.
    var lastStatus: String?
    var finished = false
    var lastMatchContentVersion = -1
    var recentMatches: [Int] = []
    var recentMatchSet: Set<Int> = []

    init(session: TerminalSession, workspace: TerminalWorkspace, name: String) {
        self.id = session.id.uuidString
        self.session = session
        self.workspace = workspace
        self.name = name
        self.kind = session.kind.rawValue
    }

    /// Whether `key` is new, remembering the last 512.
    func noteMatch(_ key: Int) -> Bool {
        guard recentMatchSet.insert(key).inserted else { return false }
        recentMatches.append(key)
        if recentMatches.count > 512 {
            recentMatchSet.remove(recentMatches.removeFirst())
        }
        return true
    }
}

/// The monitors of one control server.
@MainActor
final class AgentMonitorRegistry {
    /// Settings › MCP › Wake idle agents (default on).
    nonisolated static let wakeLinesDefaultsKey = "mcp.monitorWakeLines"
    static let maximumSubscriptionsPerCaller = 32
    static let maximumWatchedProcesses = 64
    static let maximumPendingEvents = 200
    static let unreadSubscriptionLifetime: TimeInterval = 60 * 60

    let defaults: UserDefaults
    var subscriptions: [String: MonitorSubscription] = [:]
    var order: [String] = []
    var samplerTask: Task<Void, Never>?

    // Tunables (tests shorten them).
    var sampleInterval: Duration = .milliseconds(250)
    /// How long an agent's screen must be still before idle counts as done.
    var settleInterval: TimeInterval = 1.5
    /// How long the subscriber's screen must be still before a wake line.
    var wakeQuietInterval: TimeInterval = 2
    /// At most one wake line per subscription this often.
    var wakeMinimumInterval: TimeInterval = 5
    /// No wake line while someone typed into the subscriber this recently.
    var humanTypingInterval: TimeInterval = 10
    /// A watched tab's screen is re-read (from its host or headless
    /// surface) at most this often; samples in between use what it holds.
    var refreshInterval: TimeInterval = 1
    var lastRefreshAt: [ObjectIdentifier: Date] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var wakeLinesEnabled: Bool {
        defaults.object(forKey: Self.wakeLinesDefaultsKey) as? Bool ?? true
    }

    func add(_ subscription: MonitorSubscription) {
        subscriptions[subscription.id] = subscription
        order.append(subscription.id)
    }

    func remove(_ id: String) {
        subscriptions[id] = nil
        order.removeAll { $0 == id }
    }

    var ordered: [MonitorSubscription] {
        order.compactMap { subscriptions[$0] }
    }

    func stopSampler() {
        samplerTask?.cancel()
        samplerTask = nil
    }

    /// Appends an event, dropping the oldest unread ones past the cap.
    func append(
        _ type: MonitorEventType,
        to subscription: MonitorSubscription,
        process: WatchedProcess,
        session: TerminalSession?,
        exitCode: Int32? = nil,
        matchedLine: String? = nil,
        initial: Bool
    ) {
        guard subscription.events.contains(type) else { return }
        let event = MonitorEvent(
            seq: subscription.nextSeq,
            type: type,
            processID: process.id,
            processName: process.name,
            kind: process.kind,
            at: Date(),
            agentTurn: session.flatMap { $0.kind == .agent ? $0.agentSubmittedTurnCount : nil },
            exitCode: exitCode,
            matchedLine: matchedLine.map { String($0.prefix(300)) },
            initial: initial
        )
        subscription.nextSeq += 1
        subscription.pending.append(event)
        if subscription.pending.count > Self.maximumPendingEvents {
            let overflow = subscription.pending.count - Self.maximumPendingEvents
            subscription.pending.removeFirst(overflow)
            subscription.droppedEvents += overflow
        }
    }

    func acknowledge(_ subscription: MonitorSubscription, upTo cursor: Int) {
        guard cursor > subscription.ackCursor else { return }
        subscription.ackCursor = min(cursor, subscription.nextSeq - 1)
        subscription.pending.removeAll { $0.seq <= subscription.ackCursor }
    }

    /// The wake line: the subscription and event counts only, never text a
    /// watched process controls (its name, title or output).
    static func wakeLine(for subscription: MonitorSubscription, unread: [MonitorEvent]) -> String {
        var counts: [MonitorEventType: Int] = [:]
        for event in unread { counts[event.type, default: 0] += 1 }
        let parts = MonitorEventType.allCases.compactMap { type in
            counts[type].map { "\($0) \(type.rawValue)" }
        }
        let noun = unread.count == 1 ? "event" : "events"
        return "[cherry] Monitor \(subscription.id): \(unread.count) \(noun) ready (\(parts.joined(separator: ", "))). Call the cherry wait_for_events tool with subscription_id \"\(subscription.id)\" to read them."
    }
}

extension CherryControlServer {
    // MARK: Requests

    @MainActor
    func subscribe(_ request: SubscribeRequest, workspace: TerminalWorkspace) async throws -> SubscribeResult {
        let device = Self.remoteDevice
        var events = try request.events.map { names in
            try names.map { name -> MonitorEventType in
                guard let type = MonitorEventType(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    throw CherryControlError(
                        code: "invalid_argument",
                        message: "Unknown event type \(name): use \(MonitorEventType.allCases.map(\.rawValue).joined(separator: ", "))."
                    )
                }
                return type
            }
        } ?? MonitorEventType.defaults
        let pattern = request.outputPattern?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let outputPattern = (pattern?.isEmpty ?? true) ? nil : pattern
        if outputPattern != nil, !events.contains(.outputMatch) { events.append(.outputMatch) }
        if events.contains(.outputMatch), outputPattern == nil {
            throw CherryControlError(code: "invalid_argument", message: "output_match events need output_pattern.")
        }
        var seen = Set<MonitorEventType>()
        events = events.filter { seen.insert($0).inserted }

        // The subscriber is the caller's own tab, as Cherry knows it: a
        // declared one must be the caller (a wake line types into it).
        let verified = verifiedCallerSession()
        let declared = request.subscriberProcessID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var subscriber: TerminalSession?
        var wakeUnavailableReason: String?
        if let declared, !declared.isEmpty {
            if let verified, verified.id.uuidString.lowercased() == declared {
                subscriber = verified
            } else {
                wakeUnavailableReason = "Cherry could not confirm that this MCP session runs in process \(declared), so it will not type into it; poll with wait_for_events."
            }
        } else if let verified {
            subscriber = verified
        } else {
            wakeUnavailableReason = "This MCP session does not run in a Cherry agent tab Cherry can identify; poll with wait_for_events."
        }
        if subscriber != nil, subscriber?.kind != .agent {
            wakeUnavailableReason = "The subscriber is not an agent tab; poll with wait_for_events."
        }
        if request.wake == false {
            wakeUnavailableReason = "wake is false; poll with wait_for_events."
        }
        let wakeRequested = wakeUnavailableReason == nil && subscriber?.kind == .agent

        let callerKey = subscriber?.id.uuidString
        let existing = monitors.ordered.filter { $0.device == device && $0.subscriberID == callerKey }
        guard existing.count < AgentMonitorRegistry.maximumSubscriptionsPerCaller else {
            throw CherryControlError(
                code: "too_many_subscriptions",
                message: "This caller has \(existing.count) subscriptions; unsubscribe from some first."
            )
        }

        var targets: [(TerminalSession, TerminalWorkspace)] = []
        for rawID in request.processIDs ?? [] {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let resolved = try findSessionWithWorkspace(workspace: workspace, terminalID: id)
            guard !targets.contains(where: { $0.0 === resolved.session }) else { continue }
            targets.append(resolved)
        }
        let subAgents = request.subAgents ?? false
        if subAgents {
            guard let subscriber else {
                throw CherryControlError(
                    code: "subscriber_unknown",
                    message: "sub_agents needs the caller's own agent tab, which Cherry could not identify for this MCP session. Pass process_ids instead."
                )
            }
            for (child, childWorkspace) in subAgentSessions(of: subscriber, device: device)
            where !targets.contains(where: { $0.0 === child }) {
                targets.append((child, childWorkspace))
            }
        }
        guard !targets.isEmpty || subAgents else {
            throw CherryControlError(code: "missing_argument", message: "Name the processes to watch with process_ids, or pass sub_agents: true.")
        }
        guard targets.count <= AgentMonitorRegistry.maximumWatchedProcesses else {
            throw CherryControlError(
                code: "too_many_processes",
                message: "A subscription watches at most \(AgentMonitorRegistry.maximumWatchedProcesses) processes."
            )
        }

        let subscription = MonitorSubscription(
            id: "mon-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16),
            device: device,
            subscriber: subscriber,
            subAgents: subAgents,
            events: events,
            outputPattern: outputPattern,
            wakeRequested: wakeRequested,
            wakeUnavailableReason: wakeUnavailableReason
        )
        for (session, sessionWorkspace) in targets {
            let watched = WatchedProcess(session: session, workspace: sessionWorkspace, name: processName(for: session))
            subscription.watched.append(watched)
            await refreshForMonitor(session)
            evaluate(watched, in: subscription, now: Date())
        }
        monitors.add(subscription)
        startMonitorSamplerIfNeeded()
        return SubscribeResult(
            subscription: info(for: subscription),
            watching: subscription.watched.map { status(of: $0) }
        )
    }

    @MainActor
    func unsubscribe(_ request: UnsubscribeRequest) -> UnsubscribeResult {
        guard let subscription = try? callerSubscription(request.subscriptionID) else {
            return UnsubscribeResult(subscriptionID: request.subscriptionID, removed: false)
        }
        monitors.remove(subscription.id)
        return UnsubscribeResult(subscriptionID: subscription.id, removed: true)
    }

    @MainActor
    func listSubscriptions() -> ListSubscriptionsResult {
        let device = Self.remoteDevice
        let caller = verifiedCallerSession()?.id.uuidString
        return ListSubscriptionsResult(subscriptions: monitors.ordered
            .filter { $0.device == device && $0.subscriberID == caller }
            .map { info(for: $0) })
    }

    @MainActor
    func waitForEvents(_ request: WaitForEventsRequest) async throws -> WaitForEventsResult {
        let subscription = try callerSubscription(request.subscriptionID)
        subscription.lastReadAt = Date()
        if let cursor = request.cursor {
            monitors.acknowledge(subscription, upTo: cursor)
        }
        let after = max(request.cursor ?? subscription.ackCursor, subscription.ackCursor)
        let timeout = min(
            max(request.timeoutMilliseconds ?? CherryControl.maximumEventWaitMilliseconds, 0),
            CherryControl.maximumEventWaitMilliseconds
        )
        let maxEvents = min(max(request.maxEvents ?? 50, 1), 200)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout) / 1_000)
        subscription.activeWaits += 1
        defer { subscription.activeWaits -= 1 }

        while true {
            guard monitors.subscriptions[subscription.id] === subscription else {
                throw Self.unknownSubscription(subscription.id)
            }
            let available = subscription.pending.filter { $0.seq > after }
            if !available.isEmpty || Date() >= deadline {
                let events = Array(available.prefix(maxEvents))
                let cursor = events.last?.seq ?? after
                if request.cursor == nil {
                    // No cursor: each event is read once (what this call
                    // returns is acknowledged now).
                    monitors.acknowledge(subscription, upTo: cursor)
                }
                subscription.lastReadAt = Date()
                return WaitForEventsResult(
                    subscriptionID: subscription.id,
                    events: events,
                    cursor: cursor,
                    timedOut: events.isEmpty,
                    droppedEvents: subscription.droppedEvents,
                    moreEvents: available.count - events.count,
                    watching: subscription.watched.map { status(of: $0) }
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Identity and scope

    /// The caller's own tab: the token's tab for a caller on another Mac;
    /// for This Mac's, the tab whose program is an ancestor of the
    /// connecting process (its CherryMCP). Nil when none is.
    @MainActor
    func verifiedCallerSession() -> TerminalSession? {
        let workspaces = allOpenWorkspaces()
        if Self.remoteDevice != nil {
            guard let id = Self.remoteCallerSessionID else { return nil }
            return workspaces.lazy.compactMap { $0.sessions.first { $0.id == id } }.first
        }
        if let resolver = callerSessionResolverForTesting {
            return resolver(Self.callerPeerPID)
        }
        guard let peerPID = Self.callerPeerPID else { return nil }
        let ancestry = Set(Self.processAncestry(of: peerPID))
        for attached in [false, true] {
            for workspace in workspaces {
                for session in workspace.sessions where (session.hostedAttachment != nil) == attached {
                    if let pid = session.programProcessID, ancestry.contains(pid) {
                        return session
                    }
                }
            }
        }
        return nil
    }

    @MainActor
    func allOpenWorkspaces() -> [TerminalWorkspace] {
        var result: [TerminalWorkspace] = []
        for candidate in [workspaceForMonitors()].compactMap({ $0 })
            + ProjectWindowRegistry.shared.workspacesByProjectRoot().map(\.1)
        where !result.contains(where: { $0 === candidate }) {
            result.append(candidate)
        }
        return result
    }

    /// The subscription `id`, when this caller may use it: made from the
    /// same Mac (`remoteDevice`), and by the same tab when the caller has
    /// one.
    @MainActor
    func callerSubscription(_ id: String) throws -> MonitorSubscription {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let subscription = monitors.subscriptions[trimmed], subscription.device == Self.remoteDevice else {
            throw Self.unknownSubscription(trimmed)
        }
        if let subscriberID = subscription.subscriberID, Self.remoteDevice != nil,
           Self.remoteCallerSessionID?.uuidString != subscriberID {
            throw Self.unknownSubscription(trimmed)
        }
        return subscription
    }

    static func unknownSubscription(_ id: String) -> CherryControlError {
        CherryControlError(
            code: "unknown_subscription",
            message: "No monitor subscription \(id): it was removed (unsubscribe, its subscriber's tab closed, or it went unread for an hour) or Cherry relaunched. Subscribe again."
        )
    }

    /// The subscriber's sub-agents the caller may reach.
    @MainActor
    func subAgentSessions(of subscriber: TerminalSession, device: UUID?) -> [(TerminalSession, TerminalWorkspace)] {
        guard let workspace = allOpenWorkspaces().first(where: { $0.sessions.contains { $0 === subscriber } }) else { return [] }
        return workspace.descendantAgentSessions(of: subscriber)
            .filter { child in device.map { Self.isSession(child, in: workspace, onDevice: $0) } ?? true }
            .map { ($0, workspace) }
    }

    // MARK: Sampling

    @MainActor
    func startMonitorSamplerIfNeeded() {
        guard monitors.samplerTask == nil, !monitors.subscriptions.isEmpty else { return }
        monitors.samplerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.monitors.subscriptions.isEmpty else { break }
                await self.sampleMonitors()
                let interval = self.monitors.sampleInterval
                try? await Task.sleep(for: interval)
            }
            self?.monitors.samplerTask = nil
        }
    }

    @MainActor
    func sampleMonitors() async {
        let now = Date()
        if monitors.lastRefreshAt.count > 256 { monitors.lastRefreshAt.removeAll() }
        var refreshed = Set<ObjectIdentifier>()
        for subscription in monitors.ordered {
            guard monitors.subscriptions[subscription.id] === subscription else { continue }
            if subscription.subscriberID != nil {
                guard let subscriber = subscription.subscriber,
                      allOpenWorkspaces().contains(where: { $0.sessions.contains { $0 === subscriber } })
                else {
                    // Its subscriber's tab closed: nobody reads it.
                    monitors.remove(subscription.id)
                    continue
                }
                if subscription.subAgents {
                    for (child, workspace) in subAgentSessions(of: subscriber, device: subscription.device)
                    where !subscription.isWatching(child)
                        && subscription.watched.count < AgentMonitorRegistry.maximumWatchedProcesses {
                        subscription.watched.append(WatchedProcess(session: child, workspace: workspace, name: processName(for: child)))
                    }
                }
            } else if now.timeIntervalSince(subscription.lastReadAt) > AgentMonitorRegistry.unreadSubscriptionLifetime,
                      subscription.activeWaits == 0 {
                monitors.remove(subscription.id)
                continue
            }
            for watched in subscription.watched where !watched.finished {
                if let session = watched.session, refreshed.insert(ObjectIdentifier(session)).inserted {
                    let key = ObjectIdentifier(session)
                    if monitors.lastRefreshAt[key].map({ now.timeIntervalSince($0) >= monitors.refreshInterval }) ?? true {
                        monitors.lastRefreshAt[key] = now
                        await refreshForMonitor(session)
                    }
                }
                evaluate(watched, in: subscription, now: Date())
            }
            deliverWakeIfReady(subscription)
        }
    }

    /// Reads the process's screen as an idle wait does: from its host when
    /// its lines come from there, and from a headless surface.
    @MainActor
    func refreshForMonitor(_ session: TerminalSession) async {
        await session.refreshContentFromHostIfNeeded(maximumAge: session.hostContentPollInterval, recentOnly: true)
        _ = session.lineCount
    }

    /// The watched process's status now (`MonitorProcessStatus.status`).
    @MainActor
    func monitorStatus(of watched: WatchedProcess, now: Date = Date()) -> String {
        guard let session = watched.session, let workspace = watched.workspace, isOpen(session, in: workspace) else {
            return "closed"
        }
        switch session.state {
        case .exited, .failed:
            return "exited"
        case .disconnected where !(session.isPersistentLocalSession && session.isRunning):
            return "disconnected"
        case .disconnected, .launching, .live:
            break
        }
        guard session.kind == .agent else { return "running" }
        let reported = reportedAgentActivityState(of: session) ?? "unknown"
        switch reported {
        case "idle":
            let quietSince = session.lastContentChangeAt ?? session.startedAt ?? now
            let settled = now.timeIntervalSince(quietSince) >= monitors.settleInterval
            return settled && Self.agentTurnMayHaveEnded(session, now: now) ? "idle" : "working"
        default:
            return reported
        }
    }

    @MainActor
    func status(of watched: WatchedProcess) -> MonitorProcessStatus {
        let session = watched.session
        if let session { watched.name = processName(for: session) }
        return MonitorProcessStatus(
            processID: watched.id,
            name: watched.name,
            kind: watched.kind,
            status: monitorStatus(of: watched),
            state: session?.programStateLabel ?? "closed",
            agentTurn: session.flatMap { $0.kind == .agent ? $0.agentSubmittedTurnCount : nil },
            exitCode: session?.exitCode
        )
    }

    /// Compares the process's status with the last sample's and records
    /// the events the change means; the first sample records the state it
    /// finds (`initial`).
    @MainActor
    func evaluate(_ watched: WatchedProcess, in subscription: MonitorSubscription, now: Date) {
        let current = monitorStatus(of: watched, now: now)
        let previous = watched.lastStatus
        let initial = previous == nil
        watched.lastStatus = current
        let session = watched.session
        if let session { watched.name = processName(for: session) }

        if current != previous {
            switch current {
            case "closed":
                // A tab that closed because its program ended (a terminal
                // whose shell exited 0) reports the exit first.
                if previous != "exited", let session, session.state.hasEnded {
                    monitors.append(.exited, to: subscription, process: watched, session: session, exitCode: session.exitCode, initial: initial)
                }
                monitors.append(.closed, to: subscription, process: watched, session: session, initial: initial)
                watched.finished = true
            case "exited":
                monitors.append(.exited, to: subscription, process: watched, session: session, exitCode: session?.exitCode, initial: initial)
            case "idle":
                // A finished turn: after work, or (first sample) an agent
                // whose last turn completed. An agent never given a turn
                // is not done with anything.
                if !initial || session?.agentTurnState == .completed {
                    monitors.append(.done, to: subscription, process: watched, session: session, initial: initial)
                }
            case "needs_input":
                monitors.append(.needsInput, to: subscription, process: watched, session: session, initial: initial)
            case "permission":
                monitors.append(.permission, to: subscription, process: watched, session: session, initial: initial)
            case "error":
                monitors.append(.error, to: subscription, process: watched, session: session, initial: initial)
            default:
                break
            }
        }

        if let pattern = subscription.outputPattern, let session, current != "closed",
           session.contentVersion != watched.lastMatchContentVersion {
            let firstScan = watched.lastMatchContentVersion < 0
            watched.lastMatchContentVersion = session.contentVersion
            let output = terminalOutput(for: session, startLine: nil, lineLimit: 200)
            for (offset, line) in output.lines.enumerated() where line.lowercased().contains(pattern) {
                var hasher = Hasher()
                hasher.combine(output.startLine + offset)
                hasher.combine(line)
                // Lines already on screen when the watch began are the
                // past: only new ones are events.
                guard watched.noteMatch(hasher.finalize()), !firstScan else { continue }
                monitors.append(.outputMatch, to: subscription, process: watched, session: session, matchedLine: line, initial: false)
            }
        }
    }

    // MARK: Wake lines

    /// Types the wake line into the subscriber when events it was not woken
    /// for are unread and it is idle: at its composer, its screen still,
    /// nobody typing into it, not in a `wait_for_events` call, and not
    /// asking for a permission or an answer (MCP input refuses those
    /// screens anyway).
    @MainActor
    func deliverWakeIfReady(_ subscription: MonitorSubscription) {
        guard subscription.wakeRequested, monitors.wakeLinesEnabled,
              !subscription.isWaking, subscription.activeWaits == 0,
              let subscriber = subscription.subscriber
        else { return }
        let unread = subscription.pending.filter { $0.seq > subscription.ackCursor }
        guard let newest = unread.last, newest.seq > subscription.lastWokenSeq else { return }
        let now = Date()
        if let lastWakeAt = subscription.lastWakeAt,
           now.timeIntervalSince(lastWakeAt) < monitors.wakeMinimumInterval {
            return
        }
        guard subscriberTakesWakeLine(subscriber, now: now) else { return }
        let line = AgentMonitorRegistry.wakeLine(for: subscription, unread: unread)
        subscription.isWaking = true
        Task { @MainActor [weak self] in
            defer { subscription.isWaking = false }
            guard let self else { return }
            do {
                _ = try await self.sendControlInput(text: line, rawBase64: nil, submit: true, to: subscriber)
                subscription.lastWokenSeq = newest.seq
            } catch {
                SessionLog.debug("[monitor] wake line for \(subscription.id) not sent: \(error)")
            }
            subscription.lastWakeAt = Date()
        }
    }

    @MainActor
    func subscriberTakesWakeLine(_ subscriber: TerminalSession, now: Date) -> Bool {
        guard subscriber.kind == .agent, subscriber.isRunning, subscriber.acceptsControlInput,
              reportedAgentActivityState(of: subscriber) == AgentActivityState.idle.rawValue,
              Self.agentTurnMayHaveEnded(subscriber, now: now),
              !subscriber.humanIsComposing(within: monitors.humanTypingInterval)
        else { return false }
        let quietSince = subscriber.lastContentChangeAt ?? subscriber.startedAt ?? now
        return now.timeIntervalSince(quietSince) >= monitors.wakeQuietInterval
    }

    @MainActor
    func info(for subscription: MonitorSubscription) -> SubscriptionInfo {
        let reason = subscription.wakeUnavailableReason
            ?? (monitors.wakeLinesEnabled ? nil : "Wake lines are turned off in Cherry's Settings › MCP; poll with wait_for_events.")
        return SubscriptionInfo(
            subscriptionID: subscription.id,
            subscriberProcessID: subscription.subscriberID,
            processIDs: subscription.watched.map(\.id),
            subAgents: subscription.subAgents,
            events: subscription.orderedEvents,
            outputPattern: subscription.outputPattern,
            wake: subscription.wakeRequested && monitors.wakeLinesEnabled,
            wakeUnavailableReason: reason,
            createdAt: subscription.createdAt,
            cursor: subscription.ackCursor,
            pendingEvents: subscription.pending.filter { $0.seq > subscription.ackCursor }.count
        )
    }
}

extension TerminalSession.SessionState {
    /// The program ended (`exit N`) or its launch failed.
    var hasEnded: Bool {
        switch self {
        case .exited, .failed: true
        case .launching, .live, .disconnected: false
        }
    }
}
