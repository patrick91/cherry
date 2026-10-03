import Combine
import Foundation

// Restoring saved tabs through each host's control plane
// (docs/specs/multiplexer-default.md, "Relaunch" and "Scoping").

// MARK: - Restorer

extension WorkspaceSessionRestorers {
    /// The app's restorer. Every saved record names a session of a host:
    /// that host's `HostControl` lists its sessions (This Mac through
    /// `localSessions`, an SSH host through `control(for:)`), and each record
    /// comes back as follows.
    ///
    /// - Matched by its binding (host identity and session id). When the
    ///   host no longer lists that session, a session of This Mac that this
    ///   app created and tagged with the record's tab id (`cherry.tab`) is
    ///   taken instead (a restart or Create whose binding was never saved).
    ///   The worktree's records without a binding may be matched by that tag
    ///   too (`WorkspaceRestoreRequest.unboundRecords`).
    /// - A session of This Mac that this app created, for a tab that owned it
    ///   (`restoresOwning`), comes back as that persistent tab
    ///   (`makeRestoredPersistentSession`); any other session comes back
    ///   attached (`makeRestoredHostedSession`), with the record's kind,
    ///   agent, command, project, title and directory either way.
    /// - Running: the tab follows the program through its host at once, and
    ///   its attach adapter launches later (`RestoredTabLaunchQueue`).
    ///   Ended: the tab shows "Session ended (exit N)" and the final screen;
    ///   no adapter runs.
    /// - Matched first by the saved Create's request id
    ///   (`WorkspaceSessionRecord.launchRequestID`, a session of This Mac
    ///   this app created), so a Create or restart whose answer or new
    ///   binding was never saved still comes back.
    /// - Missing on a host that answered: a daemon that just restarted lists
    ///   a session only once its holder registered again. While its list
    ///   says holders are still expected (`pendingHolders`), it is listed
    ///   again until none is (at most `pendingHoldersWait`), then the
    ///   record is dropped; if holders are still expected then, it is kept,
    ///   and restored again once the host expects none
    ///   (`HostControl.holdersRegistered()`, the result's
    ///   `retryWhenAvailable`), or at the next launch. A complete list drops
    ///   it at once. A host that does not report pending holders is listed
    ///   once more after `disappearanceConfirmationDelay`. A record the
    ///   system ended (`WorkspaceRestoreRequest.systemEnds`: a restart or log
    ///   out while Cherry was closed) comes back as an ended tab instead of
    ///   being dropped (`makeSystemEndedSession`), and so does a record
    ///   saved as one (`WorkspaceSessionRecord.systemEnd`), with nothing to
    ///   ask its host.
    /// - Host unreachable (or This Mac cannot run sessions): the record stays
    ///   saved for the next launch, and is restored once the host comes up
    ///   during this run (`WorkspaceRestoreResult.retryWhenAvailable`; an SSH
    ///   host's control connection is leased until then:
    ///   `HostControl.availability()`). A host that answers with another
    ///   identity is not waited for.
    ///
    /// Hosts are listed at the same time. The result has what the hosts
    /// that answered within `initialWait` brought back; the others (and the
    /// second look for missing sessions) finish in its `remainder`, so one
    /// slow or unreachable host never holds up the other tabs.
    ///
    /// A session is owned by at most one tab: a record that would own a
    /// session another open tab (any window or worktree) owns, or that a
    /// record before it in this restore took, is dropped, as is a record
    /// whose tab id is open already. A record that was only attached comes
    /// back attached, even when another tab shows the session.
    ///
    /// Once the request is cancelled (`WorkspaceRestoreRequest.cancellation`)
    /// or its workspace torn down, no more tabs are built: the records not
    /// answered yet are kept, and the tabs built but not handed back yet are
    /// ended with the workspace's close intent.
    static func hostedByDefault(
        localSessions: PersistentLocalSessions,
        control: @escaping @MainActor (HostedSessionHost) -> HostControl = { HostControlRegistry.shared.control(for: $0) },
        initialWait: Duration = .milliseconds(1500)
    ) -> WorkspaceSessionRestorer {
        { request in
            await ControlPlaneRestore(request: request, localSessions: localSessions, control: control)
                .run(initialWait: initialWait)
        }
    }

    /// Whether a saved local tab comes back owning its session (a persistent
    /// tab whose close may end it) rather than only attached to it: it owned
    /// the session when saved (in a record from before that was saved: the
    /// session was started for that very tab), and this app variant created
    /// the session.
    static func restoresOwning(
        _ record: WorkspaceSessionRecord,
        binding: HostedSessionBindingRecord,
        info: HostedSessionInfo,
        owner: String
    ) -> Bool {
        guard info.owner == owner else { return false }
        return binding.owned ?? (PersistentLocalSessions.tabID(of: info, owner: owner) == record.id)
    }
}

/// One restore request's work: the records grouped by host, the hosts listed
/// at the same time, each once (and again for sessions it did not list).
@MainActor
private final class ControlPlaneRestore {
    let request: WorkspaceRestoreRequest
    let localSessions: PersistentLocalSessions
    let control: @MainActor (HostedSessionHost) -> HostControl
    /// Sessions (host identity + NUL + id) a tab of this restore took.
    private var claimed: Set<String> = []
    private let progress = RestoreProgress()
    /// Tabs this restore built that no result it returned carries yet.
    private var undelivered: [ObjectIdentifier: TerminalSession] = [:]
    /// Tabs ended because the restore was cancelled before handing them back.
    private var discarded: Set<ObjectIdentifier> = []

    init(
        request: WorkspaceRestoreRequest,
        localSessions: PersistentLocalSessions,
        control: @escaping @MainActor (HostedSessionHost) -> HostControl
    ) {
        self.request = request
        self.localSessions = localSessions
        self.control = control
        request.cancellation.onCancel { [weak self] in self?.discardUndelivered() }
    }

    /// The window closed, the app quit or the worktree was removed.
    private var isStopped: Bool {
        request.cancellation.isCancelled || request.workspace.isTornDown
    }

    private func built(_ tab: TerminalSession) -> TerminalSession {
        undelivered[ObjectIdentifier(tab)] = tab
        return tab
    }

    /// Ends the tabs built for a workspace that is gone, before anyone took
    /// them: as tabs of a closed workspace, they must not go on owning their
    /// sessions (a new window's restore of the same records needs them).
    private func discardUndelivered() {
        let tabs = Array(undelivered.values)
        undelivered.removeAll()
        guard !tabs.isEmpty else { return }
        discarded.formUnion(tabs.map(ObjectIdentifier.init))
        request.workspace.discardRestoredSessions(tabs)
    }

    func run(initialWait: Duration) async -> WorkspaceRestoreResult {
        var localRecords: [WorkspaceSessionRecord] = []
        var remoteGroups: [(host: HostedSessionHost, records: [WorkspaceSessionRecord])] = []
        // Tabs saved ended by the system come back ended again.
        let systemEnded = (request.records + request.unboundRecords).filter { $0.systemEnd != nil }
        for record in request.records where record.systemEnd == nil {
            // A record for a host that is not valid can never come back.
            guard let host = record.hosted?.hostedSessionHost else { continue }
            // The host whose persistent tabs this window runs (This Mac's,
            // or a device's in its window) restores them as its own.
            if host == localSessions.profile.host {
                localRecords.append(record)
            } else if let index = remoteGroups.firstIndex(where: { $0.host == host }) {
                remoteGroups[index].records.append(record)
            } else {
                remoteGroups.append((host, [record]))
            }
        }
        // Only records whose Create went to this window's host
        // (`WorkspaceSessionRecord.hostKey`) name a session to look for.
        let unbound = request.unboundRecords.filter {
            $0.hosted == nil && $0.systemEnd == nil && $0.creationHostKey == localSessions.profile.host.id
        }
        var parts: [RestorePart] = []
        if !systemEnded.isEmpty {
            parts.append(start(Self.ids(systemEnded)) { [self] in await restoreSystemEnded(systemEnded) })
        }
        if !localRecords.isEmpty || !unbound.isEmpty {
            parts.append(start(Self.ids(localRecords + unbound)) { [self] in
                await restoreLocal(localRecords, unbound: unbound, lookingAgain: true)
            })
        }
        for group in remoteGroups {
            let control = control(group.host)
            parts.append(start(Self.ids(group.records)) { [self] in
                await restoreRemote(group.records, on: group.host, control: control, lookingAgain: true)
            })
        }
        return await collect(parts, waitingAtMost: initialWait)
    }

    /// A tab with this id is open already (another window restored the same
    /// record): it never comes back twice.
    private func isOpen(_ id: UUID) -> Bool {
        localSessions.hasOpenTab(withID: id, besides: optimisticTab(for: id))
            || OpenHostedTabs.shared.hasOpenTab(withID: id)
    }

    /// The tab shown for `recordID` before the host answered, while it is
    /// in the workspace and still provisional
    /// (`WorkspaceRestoreRequest.optimisticTabs`): by id, so a tab ⌘Z
    /// brought back counts too. One the user restarted meanwhile is theirs:
    /// an open tab like any other.
    private func optimisticTab(for recordID: UUID) -> TerminalSession? {
        guard request.optimisticTabs[recordID] != nil,
              let tab = request.workspace.session(withID: recordID),
              tab.isProvisionalRestore
        else { return nil }
        return tab
    }

    /// Whether an open tab owns `sessionID`, other than the one shown for
    /// `recordID` before the host answered.
    private func isOwnedByAnotherTab(_ sessionID: String, than recordID: UUID) -> Bool {
        guard let owner = localSessions.owningTab(of: sessionID) else { return false }
        return owner !== optimisticTab(for: recordID)
    }

    private static func key(hostID: String, sessionID: String) -> String {
        "\(hostID)\u{0}\(sessionID)"
    }

    private static func ids(_ records: [WorkspaceSessionRecord]) -> Set<UUID> {
        Set(records.map(\.id))
    }

    // MARK: Parts

    /// Starts one host's work now; `collect` gathers what it brings back.
    private func start(_ recordIDs: Set<UUID>, _ work: @escaping @MainActor () async -> WorkspaceRestoreResult) -> RestorePart {
        let part = RestorePart(recordIDs: recordIDs)
        let progress = progress
        Task { @MainActor in
            part.result = await work()
            progress.notify()
        }
        return part
    }

    /// What `parts` brought back once every one of them answered, or when
    /// `limit` has passed (nil: as soon as one of them answered). The
    /// others, and the remainders of those that answered, finish in the
    /// result's own remainder.
    private func collect(_ parts: [RestorePart], waitingAtMost limit: Duration?) async -> WorkspaceRestoreResult {
        let deadline = limit.map { ContinuousClock.now + $0 }
        let timer = deadline.map { deadline in
            Task { @MainActor [progress] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                progress.notify()
            }
        }
        defer { timer?.cancel() }
        while true {
            let answered = parts.filter { $0.result != nil }.count
            if answered == parts.count { break }
            if let deadline {
                if ContinuousClock.now >= deadline { break }
            } else if answered > 0 {
                break
            }
            await progress.wait()
        }

        if isStopped { discardUndelivered() }
        var result = WorkspaceRestoreResult()
        var waiting = parts.filter { $0.result == nil }
        for part in parts {
            guard let answer = part.result else { continue }
            // Tabs ended because the restore was cancelled: their records
            // stay saved, as for a host that did not answer.
            let ended = answer.sessions.filter { discarded.contains(ObjectIdentifier($0)) }
            let handed = answer.sessions.filter { !discarded.contains(ObjectIdentifier($0)) }
            for tab in handed { undelivered[ObjectIdentifier(tab)] = nil }
            result.sessions += handed
            result.keptRecordIDs.formUnion(ended.map(\.id))
            result.keptRecordIDs.formUnion(answer.keptRecordIDs)
            result.confirmedOptimisticRecordIDs.formUnion(answer.confirmedOptimisticRecordIDs)
            result.retryWhenAvailable = Self.either(result.retryWhenAvailable, answer.retryWhenAvailable)
            if let remainder = answer.remainder, !answer.pendingRecordIDs.isEmpty {
                waiting.append(start(answer.pendingRecordIDs) { await remainder.value })
            }
        }
        if !waiting.isEmpty {
            result.pendingRecordIDs = waiting.reduce(into: Set<UUID>()) { $0.formUnion($1.recordIDs) }
            result.remainder = Task { @MainActor [self] in
                await collect(waiting, waitingAtMost: nil)
            }
        }
        return result
    }

    private static func either(
        _ lhs: AnyPublisher<Void, Never>?,
        _ rhs: AnyPublisher<Void, Never>?
    ) -> AnyPublisher<Void, Never>? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs.merge(with: rhs).first().eraseToAnyPublisher()
    }

    /// Looks again, after `disappearanceConfirmationDelay`, for the sessions
    /// of `records` that a host that does not report pending holders (an
    /// older host) did not list.
    private func lookingAgain(
        for records: [WorkspaceSessionRecord],
        _ work: @escaping @MainActor ([WorkspaceSessionRecord]) async -> WorkspaceRestoreResult
    ) -> (pending: Set<UUID>, remainder: Task<WorkspaceRestoreResult, Never>?) {
        guard !records.isEmpty else { return ([], nil) }
        let delay = localSessions.configuration.disappearanceConfirmationDelay
        return (Self.ids(records), Task { @MainActor in
            try? await Task.sleep(for: delay)
            return await work(records)
        })
    }

    /// Looks again for the sessions of `records` that a daemon that just
    /// restarted did not list while it still expected holders (`list`):
    /// once it lists with none pending (at most `pendingHoldersWait`).
    /// `work` gets that list, or nil when the host could not be listed.
    private func lookingAgainOnceHoldersRegistered(
        for records: [WorkspaceSessionRecord],
        after list: HostedSessionList,
        on control: HostControl,
        _ work: @escaping @MainActor (HostedSessionList?) async -> WorkspaceRestoreResult
    ) -> (pending: Set<UUID>, remainder: Task<WorkspaceRestoreResult, Never>?) {
        guard !records.isEmpty else { return ([], nil) }
        let configuration = localSessions.configuration
        return (Self.ids(records), Task { @MainActor in
            let later = try? await control.listUntilHoldersRegistered(
                after: list,
                timeout: configuration.pendingHoldersWait,
                pollInterval: configuration.pendingHoldersPollInterval
            )
            return await work(later)
        })
    }

    // MARK: Ended by the system

    /// Tabs saved ended by the system (`WorkspaceSessionRecord.systemEnd`):
    /// they come back ended, as they were, unless This Mac's host has a
    /// session this app started for the tab (`cherry.tab`) since: a Restart
    /// whose new binding was never saved (the app ended first). That one
    /// comes back as the tab's own. When the host cannot be listed, the tab
    /// comes back ended.
    private func restoreSystemEnded(_ records: [WorkspaceSessionRecord]) async -> WorkspaceRestoreResult {
        guard !isStopped else { return .keeping(records) }
        var listing: LocalListing?
        if localSessions.installationProblem() == nil {
            listing = try? await localSessions.list()
        }
        guard !isStopped else { return .keeping(records) }
        var result = WorkspaceRestoreResult()
        for record in records where !isOpen(record.id) {
            if let listing, let started = taggedSession(for: record.id, in: listing.list) {
                if let tab = restoreLocalSession(started, for: record, owning: true, listing: listing) {
                    result.sessions.append(tab)
                }
                continue
            }
            guard let end = record.systemEnd else { continue }
            result.sessions.append(built(request.workspace.makeSystemEndedSession(record: record, ended: end)))
        }
        return result
    }

    /// The records of `dropped`, whose sessions `list` (of This Mac, not
    /// waiting for holders) does not have, that the system ended
    /// (`WorkspaceRestoreRequest.systemEnds`), as ended tabs; the others
    /// are dropped.
    private func systemEndedTabs(of dropped: [WorkspaceSessionRecord], missingFrom list: HostedSessionList) -> [TerminalSession] {
        guard let systemEnds = request.systemEnds, !isStopped else { return [] }
        let closesCleanExits = request.workspace.backendPolicy.settings().closeTabsOnCleanExit
        return dropped.compactMap { record in
            guard let end = systemEnds.end(of: record, missingFrom: list) else { return nil }
            // A terminal whose shell had exited with status 0 would have
            // closed its tab: it stays dropped.
            if record.kind == .terminal, record.exitStatus == 0, closesCleanExits { return nil }
            return built(request.workspace.makeSystemEndedSession(record: record, ended: end))
        }
    }

    // MARK: This Mac

    private typealias LocalListing = (list: HostedSessionList, attachment: (HostedSessionInfo) -> HostedSessionAttachment)

    /// `lookingAgain`: records whose session the host did not list are
    /// looked for once more later (the result's remainder): once a daemon
    /// that just restarted expects no more holders, or, for a host that
    /// does not report them, after `disappearanceConfirmationDelay`.
    /// Otherwise (a complete list, or the second look) they are dropped,
    /// unless the host still expected holders when the wait for them ran
    /// out: then they are kept, and restored again once it expects none
    /// (`retryWhenAvailable`) or at the next launch. `given`: a list taken
    /// already.
    private func restoreLocal(
        _ records: [WorkspaceSessionRecord],
        unbound: [WorkspaceSessionRecord],
        lookingAgain: Bool,
        listing given: LocalListing? = nil
    ) async -> WorkspaceRestoreResult {
        // Records saved while their Create was under way may name a session
        // the host started: kept like bound ones while it cannot be asked.
        // Other unbound records were never restorable and are dropped as
        // native tabs are.
        let unboundMayComeBack = unbound.filter { $0.launchRequestID != nil }
        // Neither this app nor the host can run sessions now: keep every
        // record for the next launch.
        guard localSessions.installationProblem() == nil else { return .keeping(records + unboundMayComeBack) }
        guard !isStopped else { return .keeping(records + unboundMayComeBack) }
        let generation = localSessions.connectionGeneration
        let listing: LocalListing
        if let given {
            listing = given
        } else {
            do {
                listing = try await localSessions.list()
            } catch {
                // The sessions may still run: keep every record, and bring them
                // back once the host answers during this run. New tabs (the
                // default shell first) do not wait for a host that is down.
                localSessions.noteLaunchFailure(error)
                let kept = records + unboundMayComeBack
                var result = WorkspaceRestoreResult.keeping(kept)
                if !kept.isEmpty {
                    // Another Mac's host is kept trying (leased until it
                    // answers, at once on a wake or network change, and not
                    // after a refused SSH login until then), as SSH hosts'
                    // restores are; This Mac's comes up with its next use.
                    result.retryWhenAvailable = localSessions.profile.isThisMac
                        ? localSessions.hostAvailability(after: generation)
                        : localSessions.control.availability()
                }
                return result
            }
        }
        // The window closed (or the worktree went) while the host answered.
        guard !isStopped else { return .keeping(records + unboundMayComeBack) }
        var result = WorkspaceRestoreResult()
        var missing: [WorkspaceSessionRecord] = []
        var unmatched: [WorkspaceSessionRecord] = []
        let list = listing.list
        for record in records {
            // One shown before the host answered that the user closed
            // meanwhile: their close decided.
            if request.optimisticTabs[record.id] != nil, optimisticTab(for: record.id) == nil { continue }
            guard !isOpen(record.id), let binding = record.hosted else { continue }
            var info: HostedSessionInfo?
            var owns = false
            if let launched = launchedSession(for: record, in: list) {
                // The session its latest Create started: newer than a
                // binding saved before a restart whose answer was lost.
                info = launched
                owns = true
            } else if binding.hostID == list.hostID,
                      let listed = list.sessions.first(where: { $0.id == binding.sessionID }),
                      !claimed.contains(Self.key(hostID: list.hostID, sessionID: listed.id)),
                      !isBeingEnded(listed, hostID: list.hostID) {
                info = listed
                owns = WorkspaceSessionRestorers.restoresOwning(record, binding: binding, info: listed, owner: localSessions.owner)
            } else if let tagged = taggedSession(for: record.id, in: list) {
                info = tagged
                owns = true
            }
            guard let info else {
                // Not listed by the host it was saved on: looked for again
                // (a restarted daemon may not list it yet). A host with
                // another identity (its state was reset) never will. One
                // listed but being ended is gone already: dropped.
                if binding.hostID == list.hostID, !list.sessions.contains(where: { $0.id == binding.sessionID }) {
                    missing.append(record)
                }
                continue
            }
            if let shown = optimisticTab(for: record.id), owns,
               shown.persistentSession?.sessionID == info.id, shown.persistentSession?.hostID == list.hostID {
                // Shown already for this very session: it stays, and takes
                // what the host reports (or is dropped as any would be).
                claimed.insert(Self.key(hostID: list.hostID, sessionID: info.id))
                if closesAsCleanExit(record, info: info) {
                    localSessions.end(listing.attachment(info))
                } else {
                    shown.confirmProvisionalRestore(info)
                    result.confirmedOptimisticRecordIDs.insert(record.id)
                }
                continue
            }
            if let tab = restoreLocalSession(info, for: record, owning: owns, listing: listing) {
                result.sessions.append(tab)
            }
        }
        for record in unbound where !isOpen(record.id) {
            guard let found = launchedSession(for: record, in: list) ?? taggedSession(for: record.id, in: list) else {
                unmatched.append(record)
                continue
            }
            if let tab = restoreLocalSession(found, for: record, owning: true, listing: listing) {
                result.sessions.append(tab)
            }
        }
        // Only a tab whose Create was under way names a session to wait for.
        unmatched = unmatched.filter { $0.launchRequestID != nil }
        // Those dropped now whose sessions the system ended come back ended:
        // missing ones once no second look is due (this list is complete,
        // or it is the second look), unmatched ones unless holders are
        // still expected.
        let dropsMissing = !list.awaitsHolders && !(lookingAgain && list.pendingHolders == nil)
        result.sessions += systemEndedTabs(
            of: (dropsMissing ? missing : []) + (list.awaitsHolders ? [] : unmatched),
            missingFrom: list
        )
        if lookingAgain {
            if list.awaitsHolders {
                let control = localSessions.control
                (result.pendingRecordIDs, result.remainder) = lookingAgainOnceHoldersRegistered(
                    for: missing + unmatched, after: list, on: control
                ) { [self] later in
                    await restoreLocal(
                        missing, unbound: unmatched, lookingAgain: false,
                        listing: later.map { localSessions.listing(of: $0) }
                    )
                }
            } else if list.pendingHolders == nil {
                (result.pendingRecordIDs, result.remainder) = self.lookingAgain(for: missing) { [self] records in
                    await restoreLocal(records, unbound: [], lookingAgain: false)
                }
            }
        } else if list.awaitsHolders, !(missing + unmatched).isEmpty {
            // Holders were still expected when the wait ran out: these
            // sessions may still come back, during this run too, once the
            // host expects no more holders.
            result.keptRecordIDs.formUnion(Self.ids(missing + unmatched))
            result.retryWhenAvailable = localSessions.control.holdersRegistered()
        }
        return result
    }

    private func restoreLocalSession(
        _ info: HostedSessionInfo,
        for record: WorkspaceSessionRecord,
        owning: Bool,
        listing: LocalListing
    ) -> TerminalSession? {
        if owning, localSessions.owningTab(of: info.id) != nil {
            // Another open tab owns it: never a second owner.
            return nil
        }
        claimed.insert(Self.key(hostID: listing.list.hostID, sessionID: info.id))
        let attachment = listing.attachment(info)
        if owning, closesAsCleanExit(record, info: info) {
            // A terminal whose shell exited with status 0 while Cherry was
            // closed would have closed its tab: it is not brought back (the
            // record is dropped), and its ended session is removed.
            localSessions.end(attachment)
            return nil
        }
        if owning {
            return built(request.workspace.makeRestoredPersistentSession(
                PersistentSessionLaunch(attachment: attachment, info: info),
                record: record,
                hosting: localSessions,
                deferringLaunch: true
            ))
        }
        return built(request.workspace.makeRestoredHostedSession(
            attachment,
            record: record,
            info: info,
            deferringLaunch: true,
            following: localSessions.control
        ))
    }

    /// A terminal whose shell exited with status 0 while Cherry was closed
    /// would have closed its tab (*close on exit*).
    private func closesAsCleanExit(_ record: WorkspaceSessionRecord, info: HostedSessionInfo) -> Bool {
        record.kind == .terminal && PersistentLocalSessions.endedCleanly(info)
            && request.workspace.backendPolicy.settings().closeTabsOnCleanExit
    }

    /// Whether this app is ending the session (Background Sessions → End,
    /// a close that ended it, a removed worktree's tabs): a tab restored for
    /// it would outlive it, so it counts as gone.
    private func isBeingEnded(_ info: HostedSessionInfo, hostID: String) -> Bool {
        localSessions.isEnding(info.id) || localSessions.isScheduledToEnd(info, hostID: hostID)
    }

    /// The session the record's saved Create started (`launchRequestID`),
    /// when this app created it and nothing shows it as its own yet.
    private func launchedSession(for record: WorkspaceSessionRecord, in list: HostedSessionList) -> HostedSessionInfo? {
        guard let requestID = record.launchRequestID else { return nil }
        return list.sessions.first { info in
            PersistentLocalSessions.isLaunched(info, byRequest: requestID, owner: localSessions.owner)
                && !claimed.contains(Self.key(hostID: list.hostID, sessionID: info.id))
                && !isOwnedByAnotherTab(info.id, than: record.id)
                && !isBeingEnded(info, hostID: list.hostID)
        }
    }

    /// The session this app created for tab `tabID` (its `cherry.tab` tag)
    /// that nothing shows as its own yet: a running one before an ended
    /// one, then the newest.
    private func taggedSession(for tabID: UUID, in list: HostedSessionList) -> HostedSessionInfo? {
        list.sessions
            .filter { info in
                PersistentLocalSessions.tabID(of: info, owner: localSessions.owner) == tabID
                    && !claimed.contains(Self.key(hostID: list.hostID, sessionID: info.id))
                    && !isOwnedByAnotherTab(info.id, than: tabID)
                    && !isBeingEnded(info, hostID: list.hostID)
            }
            .max { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return !lhs.isRunning }
                return lhs.createdAt < rhs.createdAt
            }
    }

    // MARK: SSH hosts

    /// As `restoreLocal`, for an SSH host's attached tabs. `given`: a list
    /// taken already.
    private func restoreRemote(
        _ records: [WorkspaceSessionRecord],
        on host: HostedSessionHost,
        control: HostControl,
        lookingAgain: Bool,
        list given: HostedSessionList? = nil
    ) async -> WorkspaceRestoreResult {
        // Unreachable, or answering with an identity other than the trusted
        // one: the sessions may still run there.
        let listed: HostedSessionList?
        var failure: Error?
        if let given {
            listed = given
        } else {
            do {
                listed = try await control.list()
            } catch {
                listed = nil
                failure = error
            }
        }
        guard let list = listed, let executable = control.executableURL, !isStopped else {
            var result = WorkspaceRestoreResult.keeping(records)
            // Unreachable: restored again once the host answers during this
            // run (its control connection is leased until then, so it keeps
            // trying, with backoff and at once on a wake or a network
            // change; after a refused SSH login only then). Another identity
            // is not the host they ran on, and a protocol this app cannot
            // use does not change by itself.
            let hosted = failure as? HostedSessionError
            let never = hosted?.isIdentityMismatch == true || hosted?.isVersionMismatch == true
            if listed == nil, !isStopped, !records.isEmpty, !never {
                result.retryWhenAvailable = control.availability()
            }
            return result
        }
        // Adapters for this host use the control connection's helper and
        // login environment (its SSH agent).
        let environment = control.loginEnvironment?.environment ?? [:]
        var result = WorkspaceRestoreResult()
        var missing: [WorkspaceSessionRecord] = []
        for record in records {
            guard !isOpen(record.id), let binding = record.hosted, binding.hostID == list.hostID else { continue }
            guard let info = list.sessions.first(where: { $0.id == binding.sessionID }) else {
                missing.append(record)
                continue
            }
            guard claimed.insert(Self.key(hostID: list.hostID, sessionID: info.id)).inserted else { continue }
            let attachment = HostedSessionAttachment(
                host: host,
                hostID: list.hostID,
                sessionID: info.id,
                name: info.name,
                remoteWorkingDirectory: info.cwd,
                executablePath: executable.path,
                environment: environment
            )
            result.sessions.append(built(request.workspace.makeRestoredHostedSession(
                attachment,
                record: record,
                info: info,
                deferringLaunch: true,
                following: control
            )))
        }
        if lookingAgain {
            if list.awaitsHolders {
                (result.pendingRecordIDs, result.remainder) = lookingAgainOnceHoldersRegistered(
                    for: missing, after: list, on: control
                ) { [self] later in
                    guard let later else { return .keeping(missing) }
                    return await restoreRemote(missing, on: host, control: control, lookingAgain: false, list: later)
                }
            } else if list.pendingHolders == nil {
                (result.pendingRecordIDs, result.remainder) = self.lookingAgain(for: missing) { [self] records in
                    await restoreRemote(records, on: host, control: control, lookingAgain: false)
                }
            }
        } else if list.awaitsHolders, !missing.isEmpty {
            result.keptRecordIDs.formUnion(Self.ids(missing))
            result.retryWhenAvailable = control.holdersRegistered()
        }
        return result
    }
}

/// One host's share of a restore: its records, and what it brought back
/// once it answered.
@MainActor
private final class RestorePart {
    let recordIDs: Set<UUID>
    var result: WorkspaceRestoreResult?

    init(recordIDs: Set<UUID>) {
        self.recordIDs = recordIDs
    }
}

/// Wakes a restore waiting for its parts whenever one of them answered (or
/// its deadline passed).
@MainActor
private final class RestoreProgress {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func notify() {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Showing saved tabs before the host answers

/// A launch shows a window's saved persistent tabs of This Mac at once,
/// built from the saved state, and starts the selected one's adapter
/// (`cherry attach` connects to the host by itself), instead of waiting for
/// the host's list (`RepositoryWorkspace.showsSavedTabsBeforeHostAnswers`).
/// Such a tab is provisional (`TerminalSession.isProvisionalRestore`) until
/// the restore, once the host answered, confirms it (the host lists its
/// session as the record's) or withdraws it and applies the usual rules
/// (`WorkspaceSessionRestorers.hostedByDefault`): an ended tab when the
/// system ended the session (`SystemEndedSessions`), the session a lost
/// Create started, a record kept while the host cannot be reached, or
/// nothing.
@MainActor
enum OptimisticRestore {
    /// The records shown before the host answers: tabs that owned a session
    /// of This Mac (`owned`) that no open tab owns or shows and that this
    /// app is not ending, that were not saved ended, and whose session
    /// nothing says the system ended (no boot or system quit since they
    /// were saved, not reported lost). A record saved without its binding
    /// (its Create had not answered) waits for the host.
    static func records(
        _ records: [WorkspaceSessionRecord],
        localSessions: PersistentLocalSessions,
        systemEnds: SystemEndedSessions
    ) -> [WorkspaceSessionRecord] {
        var sessionIDs = Set<String>()
        return records.filter { record in
            guard let binding = record.hosted,
                  binding.owned == true,
                  binding.hostedSessionHost == localSessions.profile.host,
                  record.systemEnd == nil,
                  record.exitStatus == nil,
                  sessionIDs.insert(binding.sessionID).inserted,
                  !localSessions.hasOpenTab(withID: record.id),
                  !OpenHostedTabs.shared.hasOpenTab(withID: record.id),
                  localSessions.owningTab(of: binding.sessionID) == nil,
                  !OpenHostedTabs.shared.showsSession(hostID: binding.hostID, sessionID: binding.sessionID),
                  !localSessions.isEnding(binding.sessionID),
                  !systemEnds.endedOnPurpose(record),
                  !systemEnds.recordedLostSessions(binding.hostID).contains(binding.sessionID)
            else { return false }
            return SystemEndedSessions.end(
                savedAt: systemEnds.savedAt(of: record),
                bootTime: systemEnds.bootTime,
                systemQuits: systemEnds.systemQuits,
                lostByHost: false
            ) == nil
        }
    }

    /// What the tab assumes of its session until the host answers: running,
    /// where and as it was saved, started by the saved Create.
    static func assumedInfo(
        of record: WorkspaceSessionRecord,
        binding: HostedSessionBindingRecord,
        owner: String
    ) -> HostedSessionInfo {
        var tags = [PersistentSessionTag.tab: record.id.uuidString]
        if let launch = record.launchRequestID { tags[PersistentSessionTag.launch] = launch }
        return HostedSessionInfo(
            id: binding.sessionID,
            name: record.title,
            cwd: binding.remoteWorkingDirectory ?? record.workingDirectory,
            state: .running,
            owner: owner,
            tags: tags,
            requestID: record.launchRequestID
        )
    }
}

// MARK: - Open attached tabs

/// Every open tab attached to a hosted session (`hostedAttachment`), in any
/// window: a restore never brings back a tab id that is open already.
/// Persistent tabs are tracked by `PersistentLocalSessions`.
@MainActor
final class OpenHostedTabs {
    static let shared = OpenHostedTabs()

    private final class WeakTab {
        weak var session: TerminalSession?
        init(_ session: TerminalSession) { self.session = session }
    }

    private var tabs: [ObjectIdentifier: WeakTab] = [:]

    func register(_ tab: TerminalSession) {
        tabs = tabs.filter { $0.value.session != nil }
        tabs[ObjectIdentifier(tab)] = WeakTab(tab)
    }

    func unregister(_ tab: TerminalSession) {
        tabs[ObjectIdentifier(tab)] = nil
    }

    func hasOpenTab(withID id: UUID) -> Bool {
        tabs.values.contains { $0.session?.id == id }
    }

    /// The open tab attached to this session of the host `hostID`.
    func tab(showingSession sessionID: String, hostID: String) -> TerminalSession? {
        tabs.values.lazy.compactMap(\.session).first { tab in
            tab.hostedAttachment?.hostID == hostID && tab.hostedAttachment?.sessionID == sessionID
        }
    }

    func showsSession(hostID: String, sessionID: String) -> Bool {
        tab(showingSession: sessionID, hostID: hostID) != nil
    }
}

// MARK: - Staggered attach

/// Launches restored tabs' attach adapters `batchSize` per main run loop turn,
/// so a launch that restores many tabs never builds every surface at once.
/// The pause between turns is `interval`, or as long as the last turn took
/// when that was longer (each launch builds a surface on the main actor), so
/// the main thread stays free at least half the time. The tabs each window
/// shows go first; showing any tab launches its adapter at once
/// (`TerminalSession.ghosttyBridge`). Until its adapter runs, a tab follows
/// its program through its host.
///
/// A tab no window shows attaches at the size its window gives its
/// terminals (`TerminalSession.detachedSurfaceSize`), which its surface then
/// keeps until shown, so it waits for that window's grid to settle first, as
/// a new window's first tab's Create does (`TerminalWindowGridWait`, the
/// tab's `windowGridSource`; none for a workspace that does not wait): a
/// window a tiling manager re-tiles just after it opens would otherwise give
/// it the grid it had before, and showing the tab would resize its program.
/// Its wait starts when the queue first looks at it outside a hold
/// (`holdBackgroundTabs`), and every tab waiting then is looked at, so the
/// tabs of one window launch together once its grid settled (or the wait
/// gave up), one per turn as usual; the shown tabs never wait.
///
/// Workspaces use `.shared` unless given their own
/// (`TerminalWorkspace.restoredTabLaunchQueue`, tests).
@MainActor
final class RestoredTabLaunchQueue {
    static let shared = RestoredTabLaunchQueue()

    /// Adapters launched per turn (each builds a surface on the main actor).
    var batchSize = 1
    /// The shortest pause between turns.
    var interval: TimeInterval = 0.05

    private final class WeakTab {
        weak var session: TerminalSession?
        /// A background tab's wait for its window's grid, from the first
        /// look at it outside a hold.
        var windowGridWaiting: TerminalWindowGridWait.Waiting?
        init(_ session: TerminalSession) { self.session = session }
    }

    private var shown: [WeakTab] = []
    private var background: [WeakTab] = []
    private var isScheduled = false
    /// When a background tab waiting for its window's grid is looked at
    /// again (set by `next`).
    private var nextWindowGridLook: ContinuousClock.Instant?
    /// While the launch opens its windows, tabs no window shows wait
    /// (`holdBackgroundTabs`): their adapters would only compete with the
    /// windows and the host connection for the main thread.
    private(set) var isHoldingBackgroundTabs = false
    private var backgroundHoldGeneration = 0

    init() {}

    /// Tabs still waiting, shown ones first.
    var pendingTabs: [TerminalSession] {
        (shown + background).compactMap(\.session).filter(\.isAwaitingDeferredLaunch)
    }

    /// Queues `tabs`; those whose ids are in `shownFirst` go before every
    /// background tab (of any window). A tab queued already moves to where
    /// this call puts it.
    func enqueue(_ tabs: [TerminalSession], shownFirst: Set<UUID>) {
        guard !tabs.isEmpty else { return }
        let queued = Set(tabs.map(ObjectIdentifier.init))
        let isRequeued: (WeakTab) -> Bool = { entry in
            entry.session.map { queued.contains(ObjectIdentifier($0)) } ?? true
        }
        shown.removeAll(where: isRequeued)
        background.removeAll(where: isRequeued)
        for tab in tabs {
            if shownFirst.contains(tab.id) {
                shown.append(WeakTab(tab))
            } else {
                background.append(WeakTab(tab))
            }
        }
        schedule(after: shown.isEmpty ? interval : 0)
    }

    /// Holds the tabs no window shows until `releaseBackgroundTabs`, or
    /// `limit` from now, whichever comes first.
    func holdBackgroundTabs(atMost limit: TimeInterval) {
        isHoldingBackgroundTabs = true
        backgroundHoldGeneration += 1
        let generation = backgroundHoldGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.backgroundHoldGeneration == generation else { return }
                self.releaseBackgroundTabs()
            }
        }
    }

    func releaseBackgroundTabs() {
        guard isHoldingBackgroundTabs else { return }
        isHoldingBackgroundTabs = false
        backgroundHoldGeneration += 1
        if !shown.isEmpty || !background.isEmpty { schedule(after: interval) }
    }

    /// Launches every waiting adapter now, without waiting for any window's
    /// grid (tests).
    func drain() {
        while let tab = next(waitingForWindowGrids: false) {
            tab.launchDeferredAdapterIfNeeded()
        }
    }

    private func schedule(after delay: TimeInterval) {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.runBatch() }
        }
    }

    private func runBatch() {
        isScheduled = false
        let started = ContinuousClock.now
        var launched = 0
        while launched < max(1, batchSize), let tab = next() {
            if tab.launchDeferredAdapterIfNeeded() {
                launched += 1
                LaunchTimeline.mark("adapter launched \(tab.title)")
            }
        }
        if !shown.isEmpty || (!background.isEmpty && !isHoldingBackgroundTabs) {
            let now = ContinuousClock.now
            let delay: Duration
            if launched == 0, let look = nextWindowGridLook {
                // Only tabs waiting for their window's grid: look again then.
                delay = max(look - now, .zero)
            } else {
                delay = max(now - started, .seconds(interval))
            }
            schedule(after: Self.seconds(delay))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The next tab to launch: a shown one, else a background one whose
    /// window's grid settled or that waited as long as it may (closed or
    /// launched ones are skipped). Background tabs still waiting keep their
    /// place; `nextWindowGridLook` says when to look at them again.
    private func next(waitingForWindowGrids: Bool = true) -> TerminalSession? {
        nextWindowGridLook = nil
        while !shown.isEmpty {
            let entry = shown.removeFirst()
            if let tab = entry.session, tab.isAwaitingDeferredLaunch {
                return tab
            }
        }
        guard !isHoldingBackgroundTabs else { return nil }
        let now = ContinuousClock.now
        var index = 0
        while index < background.count {
            let entry = background[index]
            guard let tab = entry.session, tab.isAwaitingDeferredLaunch else {
                background.remove(at: index)
                continue
            }
            if waitingForWindowGrids, let look = windowGridLook(entry, tab, now: now) {
                nextWindowGridLook = min(nextWindowGridLook ?? look, look)
                index += 1
                continue
            }
            background.remove(at: index)
            return tab
        }
        return nil
    }

    /// When to look again at `tab`, a background tab, while its window's
    /// grid has not settled (`TerminalWindowGridWait`); nil once it may
    /// launch.
    private func windowGridLook(_ entry: WeakTab, _ tab: TerminalSession, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let source = tab.windowGridSource else { return nil }
        var waiting = entry.windowGridWaiting ?? TerminalWindowGridWait.Waiting(source.wait, startedAt: now)
        let decision = waiting.decide(source.observe(), now: now)
        entry.windowGridWaiting = waiting
        let waited = (now - waiting.startedAt).components
        let milliseconds = waited.seconds * 1_000 + waited.attoseconds / 1_000_000_000_000_000
        switch decision {
        case .wait(let until):
            return waiting.nextLook(waitingUntil: until, now: now)
        case .take:
            if milliseconds > 0 {
                SessionLog.debug(
                    "tab \(tab.id.uuidString) attaches in the background at its window's grid after \(milliseconds) ms"
                )
            }
            return nil
        case .giveUp:
            SessionLog.notice(
                "tab \(tab.id.uuidString) attaches in the background: its window's terminal grid did not settle within \(milliseconds) ms"
            )
            return nil
        }
    }
}
