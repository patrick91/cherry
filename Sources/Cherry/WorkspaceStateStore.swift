import CherryControl
import Combine
import Darwin
import Foundation

// MARK: - Saved records

/// One project window's tabs. A window saves one `WorktreeStateRecord`, for
/// its folder; a file saved while Cherry had worktree spaces can have one
/// for each worktree the window showed (`workspaceRecord(root:)` folds
/// them). The keys stay as they were, so older builds read the file.
struct RepositoryStateRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    /// Files with another version are not migrated: they are moved aside
    /// (`WorkspaceStateStore`), never written over.
    var version: Int = RepositoryStateRecord.currentVersion
    var repositoryRoot: String
    /// The window's folder (`RepositoryWorkspace.workspaceRoot`).
    var activeWorktreeRoot: String?
    var worktrees: [WorktreeStateRecord]
    var savedAt: Date?
    /// Another window's id (`ProjectWindowValue.windowID`); nil, and left
    /// out, in a primary's file. `load` checks it with `repositoryRoot`.
    var windowID: UUID? = nil

    var hasSessions: Bool {
        worktrees.contains { !$0.sessions.isEmpty }
    }

    func worktree(root: String) -> WorktreeStateRecord? {
        worktrees.first { $0.root == root }
    }

    /// The window's tabs as one record for `root`: the record saved for
    /// that folder (or for `repositoryRoot`) first, then the other records'
    /// tabs with their saved layout, as `WorktreeStateRecord.merging(kept:)`
    /// adds them. Nil when it saved none.
    func workspaceRecord(root: String) -> WorktreeStateRecord? {
        guard !worktrees.isEmpty else { return nil }
        let first = worktrees.firstIndex { $0.root == root }
            ?? worktrees.firstIndex { $0.root == repositoryRoot }
            ?? worktrees.startIndex
        var record = worktrees[first]
        record.root = root
        for (index, other) in worktrees.enumerated() where index != first {
            record = record.merging(kept: other)
        }
        return record
    }
}

/// The tabs of one folder's `TerminalWorkspace`.
struct WorktreeStateRecord: Codable, Equatable, Sendable {
    var root: String
    /// In `TerminalWorkspace.sessions` order.
    var sessions: [WorkspaceSessionRecord]
    var displayItems: [WorkspaceDisplayItemRecord] = []
    var splitGroups: [WorkspaceSplitGroupRecord] = []
    var selectedSessionID: UUID?
    var collapsedAgentGroupIDs: [UUID] = []

    /// Whether a restore may bring back any tab: one bound to a hosted
    /// session, or one whose session's Create had not answered when it was
    /// saved (`launchRequestID`).
    var hasRestorableSessions: Bool {
        sessions.contains(where: \.mayComeBack)
    }

    /// Only the tabs in `sessionIDs`, with the layout, selection and
    /// collapsed groups that refer to them.
    func restricted(to sessionIDs: Set<UUID>) -> WorktreeStateRecord {
        let keptSessions = sessions.filter { sessionIDs.contains($0.id) }
        let keptIDs = Set(keptSessions.map(\.id))
        let keptGroups = splitGroups.compactMap { group -> WorkspaceSplitGroupRecord? in
            let paneIndices = group.paneSessionIDs.indices.filter { keptIDs.contains(group.paneSessionIDs[$0]) }
            guard let firstIndex = paneIndices.first else { return nil }
            let paneIDs = paneIndices.map { group.paneSessionIDs[$0] }
            return WorkspaceSplitGroupRecord(
                id: group.id,
                paneSessionIDs: paneIDs,
                activeSessionID: paneIDs.contains(group.activeSessionID)
                    ? group.activeSessionID
                    : group.paneSessionIDs[firstIndex],
                // A restore balances panes whose weights do not match.
                widthWeights: group.widthWeights.count == group.paneSessionIDs.count
                    ? paneIndices.map { group.widthWeights[$0] }
                    : []
            )
        }
        let keptGroupIDs = Set(keptGroups.map(\.id))
        return WorktreeStateRecord(
            root: root,
            sessions: keptSessions,
            displayItems: displayItems.filter { item in
                switch item.kind {
                case .single: keptIDs.contains(item.id)
                case .split: keptGroupIDs.contains(item.id)
                }
            },
            splitGroups: keptGroups,
            selectedSessionID: selectedSessionID.flatMap { keptIDs.contains($0) ? $0 : nil },
            collapsedAgentGroupIDs: collapsedAgentGroupIDs.filter(keptIDs.contains)
        )
    }

    /// This live record plus `kept`: saved tabs a restore could not bring
    /// back yet. Kept tabs follow the live ones with their saved layout; one
    /// whose id or hosted session is live again is left out. The saved
    /// selection wins over a live tab that cannot come back.
    func merging(kept: WorktreeStateRecord) -> WorktreeStateRecord {
        let liveIDs = Set(sessions.map(\.id))
        let liveBindings = Set(sessions.compactMap(\.hosted?.sessionKey))
        let kept = kept.restricted(to: Set(kept.sessions.lazy.filter { record in
            !liveIDs.contains(record.id)
                && !(record.hosted.map { liveBindings.contains($0.sessionKey) } ?? false)
        }.map(\.id)))
        guard !kept.sessions.isEmpty else { return self }

        let liveGroupIDs = Set(splitGroups.map(\.id))
        let keptGroups = kept.splitGroups.filter { !liveGroupIDs.contains($0.id) }
        let keptGroupIDs = Set(keptGroups.map(\.id))
        let liveSelectionComesBack = sessions.first { $0.id == selectedSessionID }?.isRestorable == true
        var collapsedIDs = collapsedAgentGroupIDs
        collapsedIDs.append(contentsOf: kept.collapsedAgentGroupIDs.filter { !collapsedIDs.contains($0) })
        return WorktreeStateRecord(
            root: root,
            sessions: sessions + kept.sessions,
            displayItems: displayItems + kept.displayItems.filter { item in
                item.kind == .single || keptGroupIDs.contains(item.id)
            },
            splitGroups: splitGroups + keptGroups,
            selectedSessionID: liveSelectionComesBack
                ? selectedSessionID
                : kept.selectedSessionID ?? selectedSessionID,
            collapsedAgentGroupIDs: collapsedIDs
        )
    }
}

/// One tab. Native tabs are saved too (their layout and metadata), but only
/// tabs bound to a hosted session come back after a relaunch.
struct WorkspaceSessionRecord: Codable, Equatable, Sendable {
    var id: UUID
    var kind: TerminalSession.SessionKind
    var title: String
    var titleSource: TerminalSession.TitleSource = .system
    var agentName: String?
    var parentAgentID: UUID?
    var commandName: String?
    var launchCommand: String?
    var launchEnvironment: [String: String] = [:]
    var launchWorkingDirectory: String?
    var workingDirectory: String
    var restartOnExit = false
    var projectRoot: String?
    var hosted: HostedSessionBindingRecord?
    /// The `request_id` (lowercased) of the Create that started, or was
    /// starting, a persistent tab's session. A relaunch adopts the session
    /// the host reports for it, before the binding, so a Create or restart
    /// whose answer (or new binding) was never saved still comes back.
    /// Older builds ignore it.
    var launchRequestID: String?
    /// The host (`HostedSessionHost.id`) a persistent tab's session was
    /// being created on when it was saved without a binding (its Create had
    /// not answered): set for another Mac's host (a device's tab,
    /// docs/specs/remote-devices.md), so a relaunch looks for that session
    /// on its device, never on This Mac. Nil: This Mac (and every record
    /// with a binding, which names its host). Older builds ignore it.
    var hostKey: String?
    /// The tab's session was ended by the system (a restart or log out)
    /// while Cherry was closed: it comes back ended, with Restart and
    /// Close, until it restarts or closes (`SystemEndedSessions`). Such a
    /// record names no session. Older builds ignore it (and drop the tab).
    var systemEnd: SystemSessionEnd?
    /// How the tab's program ended, once its session was known to have
    /// exited ("Session ended (exit N)"): a relaunch that finds the session
    /// gone never takes it for one the system ended while it ran. With
    /// `systemEnd`, the tab comes back showing that exit, and nothing
    /// restarts it by itself (auto-start aside). Older builds ignore it.
    var exitStatus: Int32?
    /// When a tab that was open last saved this record. A record a restore
    /// kept (its host could not be listed) is saved again unchanged, so
    /// this still says when its session was last known to run; nil in
    /// older files, whose `RepositoryStateRecord.savedAt` stands in
    /// (`SystemEndedSessions`). Older builds ignore it.
    var savedAt: Date?
    /// The tab had a bell or notification not seen yet (its unread dot):
    /// the tab comes back unread. Saved only when true.
    var hasUnreadNotification: Bool?

    /// A tab whose program can still be running after Cherry quit.
    var isRestorable: Bool {
        hosted != nil
    }

    /// A restorable tab, one saved while its session's Create had not
    /// answered (the local host may have started that session), or one
    /// whose session the system ended (it comes back ended).
    var mayComeBack: Bool {
        hosted != nil || launchRequestID != nil || systemEnd != nil
    }

    /// A saved tab that may own a session of This Mac (a persistent tab,
    /// which closing ends): bound to a local session
    /// it did not only attach to, or saved while its Create was under way.
    var mayOwnLocalSession: Bool {
        mayOwnSession(on: .local)
    }

    /// A saved tab that may own a session of `host`: bound to one of its
    /// sessions it did not only attach to, or saved while its Create on
    /// that host was under way (`hostKey`, This Mac when nil). A binding to
    /// another Mac's host counts only when it says it owned the session:
    /// bindings saved before `owned` existed were SSH attachments.
    func mayOwnSession(on host: HostedSessionHost) -> Bool {
        guard let binding = hosted else { return creationHostKey == host.id && launchRequestID != nil }
        guard binding.host == host.id else { return false }
        return host == .local ? binding.owned != false : binding.owned == true
    }

    /// The host a record without a binding was being created on
    /// (`hostKey`): This Mac's unless it names another.
    var creationHostKey: String {
        hostKey?.nilIfEmpty ?? HostedSessionHost.local.id
    }

    /// A saved tab that owned a session of another Mac's host (a device's
    /// tab, docs/specs/remote-devices.md), or was creating one there when
    /// it was saved.
    var ownsRemoteSession: Bool {
        guard let binding = hosted else {
            return creationHostKey != HostedSessionHost.local.id && launchRequestID != nil
        }
        return binding.host != HostedSessionHost.local.id && binding.owned == true
    }

    /// Only what finds the session this tab ran (its id, binding and
    /// Create request) and names it: kept in the list of sessions to end
    /// (`SessionsToEndRecord`) without its launch command or environment.
    var identifyingSession: WorkspaceSessionRecord {
        WorkspaceSessionRecord(
            id: id,
            kind: kind,
            title: title,
            workingDirectory: workingDirectory,
            projectRoot: projectRoot,
            hosted: hosted,
            launchRequestID: launchRequestID,
            hostKey: hostKey
        )
    }
}

extension WorkspaceSessionRecord {
    /// Every tab carries its own metadata: a restored tab attached to a
    /// hosted session (`hostedAttachment`) got its kind, agent, command and
    /// launch settings from its record. `restoredRecord` (what a restored
    /// tab was saved with) keeps the directories of a tab attached to
    /// another machine's session, which are not This Mac's. A persistent
    /// local tab saves the session its program runs in.
    @MainActor
    init(session: TerminalSession, restoredRecord: WorkspaceSessionRecord?) {
        let savedDirectories = session.hostedAttachment.map { $0.host != .local } == true ? restoredRecord : nil
        self.init(
            id: session.id,
            kind: session.kind,
            title: session.title,
            titleSource: session.titleSource,
            agentName: session.agentName,
            parentAgentID: session.parentAgentID,
            commandName: session.commandName,
            launchCommand: session.launchCommand,
            launchEnvironment: session.launchEnvironment,
            launchWorkingDirectory: savedDirectories.map(\.launchWorkingDirectory) ?? session.launchWorkingDirectory,
            workingDirectory: savedDirectories?.workingDirectory ?? session.workingDirectory,
            restartOnExit: session.restartOnExit,
            projectRoot: session.projectRoot,
            hosted: session.hostedSessionBinding.map {
                HostedSessionBindingRecord($0, owned: session.isPersistentLocalSession)
            },
            launchRequestID: session.isPersistentLocalSession ? session.persistentLaunchRequestID : nil,
            // A device's tab saved while its Create was under way names the
            // device it was being created on.
            hostKey: session.hostedSessionBinding == nil && session.persistentLaunchRequestID != nil
                ? session.persistentHosting.flatMap { $0.profile.isThisMac ? nil : $0.profile.host.id }
                : nil,
            systemEnd: session.systemSessionEnd,
            exitStatus: session.savedExitStatus,
            hasUnreadNotification: session.hasUnreadNotification ? true : nil
        )
    }
}

/// The hosted session a tab is attached to.
struct HostedSessionBindingRecord: Codable, Hashable, Sendable {
    /// `HostedSessionHost.id`: "local", or "ssh:" and the SSH destination.
    var host: String
    /// The host's identity the tab attached to (`--expected-host-id`).
    var hostID: String
    /// The host-issued session id.
    var sessionID: String
    var remoteWorkingDirectory: String?
    /// True when the tab owned the session (a persistent local tab: its
    /// program ran there, and closing the tab may end it); false when it
    /// was only attached to it (Persistent Sessions → Attach, a session of
    /// an SSH host, another app's, or one another tab owned), so it comes
    /// back only attached. Nil in records saved before this was recorded.
    var owned: Bool?

    /// Identifies the hosted session whatever the tab: the host's identity
    /// and its session id.
    var sessionKey: String {
        "\(hostID)\u{0}\(sessionID)"
    }

    /// Nil for a host id that is not a valid local or SSH host.
    var hostedSessionHost: HostedSessionHost? {
        if host == HostedSessionHost.local.id {
            return .local
        }
        guard host.hasPrefix("ssh:") else { return nil }
        return try? HostedSessionHost.ssh(String(host.dropFirst("ssh:".count)))
    }
}

extension HostedSessionBindingRecord {
    init(_ attachment: HostedSessionAttachment, owned: Bool? = nil) {
        self.init(
            host: attachment.host.id,
            hostID: attachment.hostID,
            sessionID: attachment.sessionID,
            remoteWorkingDirectory: attachment.remoteWorkingDirectory,
            owned: owned
        )
    }
}

struct WorkspaceDisplayItemRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case single
        case split
    }

    var kind: Kind
    /// The tab id of a single item, the split group id of a split.
    var id: UUID
}

extension WorkspaceDisplayItemRecord {
    init(_ item: TerminalDisplayItem) {
        switch item {
        case .single(let sessionID):
            self.init(kind: .single, id: sessionID)
        case .split(let groupID):
            self.init(kind: .split, id: groupID)
        }
    }
}

struct WorkspaceSplitGroupRecord: Codable, Equatable, Sendable {
    var id: UUID
    var paneSessionIDs: [UUID]
    var activeSessionID: UUID
    var widthWeights: [Double]
}

extension WorkspaceSplitGroupRecord {
    init(_ group: TerminalSplitGroup) {
        self.init(
            id: group.id,
            paneSessionIDs: group.paneSessionIDs,
            activeSessionID: group.activeSessionID,
            widthWeights: group.widthWeights
        )
    }
}

/// A project window as `open-windows.json` lists it: its project as
/// `RepositoryWorkspace.repositoryRoot` names it (the standardized folder,
/// or a `device:<uuid>:/path` key) and, for every window but the project's
/// primary one, its own id. The primary window keeps the file and keys a
/// project's one window had before windows had ids (#22).
struct ProjectWindowValue: Codable, Hashable, Sendable {
    var projectRoot: String
    var windowID: UUID?

    static func primary(_ projectRoot: String) -> ProjectWindowValue {
        ProjectWindowValue(projectRoot: projectRoot, windowID: nil)
    }

    var isPrimary: Bool { windowID == nil }
}

/// Project windows open when Cherry last saved them (at quit, or when a
/// window opened or closed).
struct OpenProjectWindowsRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = OpenProjectWindowsRecord.currentVersion
    /// The windows' projects: what builds before #22 read (they reopen each
    /// one's primary window when its file has tabs).
    var projectRoots: [String]
    /// Every window, in the order they were saved in (a primary has no
    /// `windowID`). Nil in a file of a build before #22: its
    /// `projectRoots` are primaries.
    var windows: [ProjectWindowValue]? = nil
}

/// Saved tabs no open tab showed whose sessions of This Mac are still to be
/// ended (a window closed, or a quit, that ended sessions). An entry stays
/// until the host's list shows none of its sessions running, so a session
/// this run could not end before it quit (the host could not be reached)
/// is ended at the next launch
/// (`PersistentLocalSessions.endSessions(ofForgottenTabs:recordedIn:)`).
struct SessionsToEndRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Entries older than this are dropped: after that long, a host that
    /// never answered is not coming back with those sessions.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    struct Entry: Codable, Equatable, Sendable {
        /// `WorkspaceSessionRecord.identifyingSession`.
        var record: WorkspaceSessionRecord
        var forgottenAt: Date
    }

    var version: Int = SessionsToEndRecord.currentVersion
    var entries: [Entry]
}

/// When Cherry quit for a log out, restart or shut down
/// (`CherryAppDelegate.QuitReason.powerOff`), oldest first: the sessions
/// running then ended with the user's processes, so a saved tab whose
/// session is gone after one, saved before it, was ended by the system
/// (`SystemEndedSessions`).
struct SystemQuitsRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// The newest ones kept.
    static let limit = 32

    var version: Int = SystemQuitsRecord.currentVersion
    var quits: [Date]
}

/// Sessions of This Mac this app ended on purpose, oldest first: a tab's
/// close, End Sessions, Background Sessions → End, a clean exit's removal, a restart's previous session, or
/// Persistent Sessions → Terminate or Remove. A saved tab that names one
/// never comes back as ended by the system (`SystemEndedSessions`), even
/// after a restart: a closed window's record still names the sessions
/// ended from Background Sessions, and a window closed or a quit with End
/// Sessions saved its tabs before ending them. Entries never expire: an
/// entry goes only once no saved state file names its session.
struct EndedSessionsRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        /// The local host's identity.
        var hostID: String
        var sessionID: String
        var endedAt: Date
    }

    var version: Int = EndedSessionsRecord.currentVersion
    var entries: [Entry]
    /// The list was lost (its file could not be read) at this time: the
    /// sessions a record saved before it names may have been ended on
    /// purpose, so such a record never comes back as ended by the system.
    var lostBefore: Date?
}

/// Sessions of This Mac whose holders the local host found killed
/// (`HostedSessionList.lostSessionIDs`), as this app saw them: the host
/// reports them only until its daemon restarts, and a window may open
/// later. An entry goes once no saved state file names its session.
struct LostSessionsRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable, Sendable {
        var hostID: String
        var sessionID: String
        var seenAt: Date
    }

    var version: Int = LostSessionsRecord.currentVersion
    var entries: [Entry]
}

/// Sessions of This Mac that had a bell or notification while in the
/// background (no open tab showed them): the tab that shows one next
/// comes up unread (`PersistentLocalSessions.takeUnread`). Entries older
/// than `maximumAge` are dropped.
struct UnreadSessionsRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    struct Entry: Codable, Equatable, Sendable {
        var hostID: String
        var sessionID: String
        var since: Date
    }

    var version: Int = UnreadSessionsRecord.currentVersion
    var entries: [Entry]
}

/// What a project's state file that this version could not use (and moved
/// aside, `WorkspaceStateStore.load`) said, as far as it can be read: when
/// it was last saved, and the tabs, sessions and Create requests it named.
/// Orphaned-session adoption uses it while no usable file replaced it
/// (`OrphanedSessionCriteria`).
struct SetAsideStateSummary: Equatable, Sendable {
    /// Its `savedAt`, else the file's modification time.
    var savedAt: Date?
    var tabIDs: Set<UUID> = []
    var sessionIDs: Set<String> = []
    /// Lowercased.
    var launchIDs: Set<String> = []
}

// MARK: - Store

/// Saves each project window's tabs as JSON under
/// `Application Support/<app>/Workspaces/<sha256(repository root)>.json`
/// (a project's primary window) or `<sha256(root, NUL, window id)>.json`
/// (another window of it), replacing the file atomically, owner-only, with
/// the open windows (`open-windows.json`) and the sessions of forgotten tabs
/// still to end (`sessions-to-end.json`, `SessionsToEndRecord`) beside them.
/// Writes run on one serial queue, so a synchronous save or load sees every
/// earlier write.
///
/// A file that is there but cannot be used (another version, one that does
/// not decode, or another root's or window's) is never written over: it is
/// moved aside first, to `<name>.<v2|unreadable|other-root>-<UTC time>.bak`
/// beside it, so a build of another version can still be pointed at it.
///
/// With an `instanceLock` (the app's store), the store is used only while
/// this copy of the app holds that lock: another copy with the same identity
/// loads nothing and saves nothing (`AppInstanceLock`).
final class WorkspaceStateStore: @unchecked Sendable {
    static let shared = WorkspaceStateStore(directory: WorkspaceStateStore.defaultDirectory(), instanceLock: .shared)

    let directory: URL
    private let instanceLock: AppInstanceLock?
    private let queue = DispatchQueue(label: "Cherry.WorkspaceStateStore", qos: .utility)
    /// Files that could not be moved aside: never written (only on `queue`).
    private var protectedFiles: Set<String> = []

    init(directory: URL, instanceLock: AppInstanceLock? = nil) {
        self.directory = directory
        self.instanceLock = instanceLock
    }

    /// Whether this copy of the app may read and write the saved state.
    var isEnabled: Bool {
        instanceLock?.isHeld ?? true
    }

    static func defaultDirectory(
        applicationSupportName: String = CherryAppIdentity.current.applicationSupportName
    ) -> URL {
        CherryAppIdentity.applicationSupportDirectory(applicationSupportName: applicationSupportName)
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    /// A project window's state file: the primary's (`windowID` nil) is
    /// named by its root, as a project's one window was before windows had
    /// ids; another window's by its root, a NUL and its id, so builds before
    /// #22 never load it but still read it as a state file.
    static func stateFileName(repositoryRoot: String, windowID: UUID? = nil) -> String {
        let key = windowID.map { "\(repositoryRoot)\u{0}\($0.uuidString)" } ?? repositoryRoot
        return CherryAppIdentity.projectFileName(for: key)
    }

    /// A project window's state file (`stateFileName`), not a set-aside
    /// copy or another record.
    private static func isStateFileName(_ name: String) -> Bool {
        name.count == 69 && name.hasSuffix(".json") && name.dropLast(5).allSatisfy({ $0.isHexDigit })
    }

    func stateFileURL(repositoryRoot: String, windowID: UUID? = nil) -> URL {
        directory.appendingPathComponent(
            Self.stateFileName(repositoryRoot: repositoryRoot, windowID: windowID),
            isDirectory: false
        )
    }

    var openProjectWindowsFileURL: URL {
        directory.appendingPathComponent("open-windows.json", isDirectory: false)
    }

    var sessionsToEndFileURL: URL {
        directory.appendingPathComponent("sessions-to-end.json", isDirectory: false)
    }

    var systemQuitsFileURL: URL {
        directory.appendingPathComponent("system-quits.json", isDirectory: false)
    }

    var endedSessionsFileURL: URL {
        directory.appendingPathComponent("ended-sessions.json", isDirectory: false)
    }

    var lostSessionsFileURL: URL {
        directory.appendingPathComponent("lost-sessions.json", isDirectory: false)
    }

    /// The app is quitting (its quit may still wait for sessions to end): a
    /// copy of the app launched meanwhile waits for this one to finish
    /// instead of running without saved tabs (`AppInstanceLock.markQuitting`).
    func noteAppQuitting() {
        instanceLock?.markQuitting()
    }

    /// The tabs a project window saved (`windowID` nil: the project's
    /// primary window). Nil when nothing was saved, when the store is
    /// disabled (another copy of the app holds the instance lock), or when
    /// the file cannot be used: unreadable, another version, or for another
    /// root or window (a hash collision). Such a file is moved aside, never
    /// written over.
    func load(repositoryRoot: String, windowID: UUID? = nil) -> RepositoryStateRecord? {
        guard isEnabled else { return nil }
        let fileURL = stateFileURL(repositoryRoot: repositoryRoot, windowID: windowID)
        return queue.sync { () -> RepositoryStateRecord? in
            guard let state = readVersionedLocked(RepositoryStateRecord.self, from: fileURL) else { return nil }
            guard state.repositoryRoot == repositoryRoot, state.windowID == windowID else {
                setAsideLocked(fileURL, label: "other-root")
                return nil
            }
            return state
        }
    }

    /// Writes the file of the window `state` names (`repositoryRoot`, `windowID`).
    func save(_ state: RepositoryStateRecord) {
        guard isEnabled else { return }
        let fileURL = stateFileURL(repositoryRoot: state.repositoryRoot, windowID: state.windowID)
        queue.async {
            self.writeLocked(state, to: fileURL)
        }
    }

    func saveSynchronously(_ state: RepositoryStateRecord) {
        guard isEnabled else { return }
        let fileURL = stateFileURL(repositoryRoot: state.repositoryRoot, windowID: state.windowID)
        queue.sync {
            writeLocked(state, to: fileURL)
        }
    }

    /// Waits for every save queued so far.
    func flush() {
        queue.sync {}
    }

    func hasSavedTabs(repositoryRoot: String, windowID: UUID? = nil) -> Bool {
        load(repositoryRoot: repositoryRoot, windowID: windowID)?.hasSessions == true
    }

    /// The saved windows in their saved order; a file of a build before
    /// #22 lists primaries only (its `projectRoots`).
    func loadOpenProjectWindows() -> [ProjectWindowValue] {
        guard let record = loadOpenProjectWindowsRecord() else { return [] }
        return record.windows ?? record.projectRoots.map(ProjectWindowValue.primary)
    }

    /// Saves `windows` in their order, with their projects, once each and
    /// sorted, as `projectRoots` for builds before #22.
    func saveOpenProjectWindows(_ windows: [ProjectWindowValue], synchronously: Bool = false) {
        saveOpenProjectWindowsRecord(
            OpenProjectWindowsRecord(projectRoots: Array(Set(windows.map(\.projectRoot))).sorted(), windows: windows),
            synchronously: synchronously
        )
    }

    /// The saved windows' projects as builds before #22 read them (`projectRoots`).
    func loadOpenProjectWindowRoots() -> [String] {
        loadOpenProjectWindowsRecord()?.projectRoots ?? []
    }

    /// Saves each of `projectRoots`' primary window, and `projectRoots` as given.
    func saveOpenProjectWindowRoots(_ projectRoots: [String], synchronously: Bool = false) {
        saveOpenProjectWindowsRecord(
            OpenProjectWindowsRecord(projectRoots: projectRoots, windows: projectRoots.map(ProjectWindowValue.primary)),
            synchronously: synchronously
        )
    }

    private func loadOpenProjectWindowsRecord() -> OpenProjectWindowsRecord? {
        guard isEnabled else { return nil }
        let fileURL = openProjectWindowsFileURL
        return queue.sync {
            readVersionedLocked(OpenProjectWindowsRecord.self, from: fileURL)
        }
    }

    private func saveOpenProjectWindowsRecord(_ record: OpenProjectWindowsRecord, synchronously: Bool) {
        guard isEnabled else { return }
        let fileURL = openProjectWindowsFileURL
        if synchronously {
            queue.sync { writeLocked(record, to: fileURL) }
        } else {
            queue.async { self.writeLocked(record, to: fileURL) }
        }
    }

    /// Windows to reopen at launch, with the tabs each saved: each saved
    /// window (`saved`, else `loadOpenProjectWindows()`) once, in saved
    /// order, whose directory still exists and whose own file has tabs. A
    /// project on another Mac (a `ProjectLocation` key) is never looked for
    /// on this Mac's disk: it is reopened while its device is still known
    /// (`remoteProjectIsKnown`).
    func projectWindowsToReopen(
        _ saved: [ProjectWindowValue]? = nil,
        remoteProjectIsKnown: (String) -> Bool = { _ in false }
    ) -> [(window: ProjectWindowValue, state: RepositoryStateRecord)] {
        var seen = Set<ProjectWindowValue>()
        return (saved ?? loadOpenProjectWindows()).compactMap { window in
            guard seen.insert(window).inserted else { return nil }
            let root = window.projectRoot
            if ProjectLocation.isRemoteKey(root) {
                guard remoteProjectIsKnown(root) else { return nil }
            } else {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { return nil }
            }
            guard let state = load(repositoryRoot: root, windowID: window.windowID), state.hasSessions else { return nil }
            return (window, state)
        }
    }

    /// The projects of the windows to reopen at launch (`projectWindowsToReopen`).
    func projectWindowRootsToReopen(remoteProjectIsKnown: (String) -> Bool = { _ in false }) -> [String] {
        projectWindowsToReopen(remoteProjectIsKnown: remoteProjectIsKnown).map(\.window.projectRoot)
    }

    /// What the state file of a project window (`windowID` nil: its
    /// primary) that this version could not use said: the one still there
    /// (it could not be moved aside), else the newest one moved aside, while
    /// no usable file replaced it. Nil when a usable file is there, when
    /// none was ever set aside, or when the store is disabled.
    func setAsideState(repositoryRoot: String, windowID: UUID? = nil) -> SetAsideStateSummary? {
        guard isEnabled else { return nil }
        let fileURL = stateFileURL(repositoryRoot: repositoryRoot, windowID: windowID)
        let directory = directory
        return queue.sync { () -> SetAsideStateSummary? in
            let manager = FileManager.default
            if manager.fileExists(atPath: fileURL.path) {
                if case .usable(let state) = Self.readFile(RepositoryStateRecord.self, from: fileURL),
                   state.version == RepositoryStateRecord.currentVersion,
                   state.repositoryRoot == repositoryRoot,
                   state.windowID == windowID {
                    return nil
                }
                let modified = (try? manager.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
                return Self.summary(of: fileURL, modified: modified, repositoryRoot: repositoryRoot, windowID: windowID)
            }
            let prefix = fileURL.lastPathComponent + "."
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return nil }
            var newest: (url: URL, modified: Date?)?
            for name in names
            where name.hasPrefix(prefix) && name.hasSuffix(".bak") && !name.hasPrefix(prefix + "other-root-") {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                if newest == nil || (modified ?? .distantPast) > (newest?.modified ?? .distantPast) {
                    newest = (url, modified)
                }
            }
            return newest.flatMap {
                Self.summary(of: $0.url, modified: $0.modified, repositoryRoot: repositoryRoot, windowID: windowID)
            }
        }
    }

    /// Reads what it can of a state file of any version: nil when it names
    /// another repository or another window.
    private static func summary(
        of url: URL,
        modified: Date?,
        repositoryRoot: String,
        windowID: UUID?
    ) -> SetAsideStateSummary? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return SetAsideStateSummary(savedAt: modified) }
        if let root = object["repositoryRoot"] as? String, root != repositoryRoot { return nil }
        if (object["windowID"] as? String).flatMap(UUID.init(uuidString:)) != windowID { return nil }
        let savedAt = (object["savedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        var summary = SetAsideStateSummary(savedAt: savedAt ?? modified)
        let worktrees = (object["worktrees"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for worktree in worktrees {
            for session in (worktree["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                if let id = (session["id"] as? String).flatMap(UUID.init(uuidString:)) {
                    summary.tabIDs.insert(id)
                }
                if let hosted = session["hosted"] as? [String: Any],
                   hosted["host"] as? String == HostedSessionHost.local.id,
                   let sessionID = hosted["sessionID"] as? String {
                    summary.sessionIDs.insert(sessionID)
                }
                if let launch = session["launchRequestID"] as? String, !launch.isEmpty {
                    summary.launchIDs.insert(launch.lowercased())
                }
            }
        }
        return summary
    }

    /// Saved tabs whose sessions are still to be ended (`SessionsToEndRecord`),
    /// oldest first; nothing when the store is disabled.
    func loadSessionsToEnd() -> [WorkspaceSessionRecord] {
        guard isEnabled else { return [] }
        let fileURL = sessionsToEndFileURL
        return queue.sync {
            (readSessionsToEndLocked(fileURL) ?? []).map(\.record)
        }
    }

    /// Adds saved tabs whose sessions are to be ended. Queued ahead of any
    /// later save, so the file names them before the state file stops
    /// naming them.
    func addSessionsToEnd(_ records: [WorkspaceSessionRecord]) {
        guard isEnabled, !records.isEmpty else { return }
        let fileURL = sessionsToEndFileURL
        let now = Date()
        queue.async {
            var entries = self.readSessionsToEndLocked(fileURL) ?? []
            var known = Set(entries.map(\.record.id))
            for record in records where known.insert(record.id).inserted {
                entries.append(SessionsToEndRecord.Entry(record: record.identifyingSession, forgottenAt: now))
            }
            self.writeLocked(SessionsToEndRecord(entries: entries), to: fileURL)
        }
    }

    /// Their sessions are gone: drops these entries (and expired ones).
    func removeSessionsToEnd(ids: Set<UUID>) {
        guard isEnabled, !ids.isEmpty else { return }
        let fileURL = sessionsToEndFileURL
        queue.async {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let entries = (self.readSessionsToEndLocked(fileURL) ?? []).filter { !ids.contains($0.record.id) }
            if entries.isEmpty {
                guard !self.protectedFiles.contains(fileURL.path) else { return }
                unlink(fileURL.path)
            } else {
                self.writeLocked(SessionsToEndRecord(entries: entries), to: fileURL)
            }
        }
    }

    // MARK: What ended sessions (SystemEndedSessions)

    /// Cherry quits for a log out, restart or shut down: written at once,
    /// after the windows' last saves.
    func noteSystemQuit(at date: Date = Date()) {
        guard isEnabled else { return }
        let fileURL = systemQuitsFileURL
        queue.sync {
            var quits = readVersionedLocked(SystemQuitsRecord.self, from: fileURL)?.quits ?? []
            quits.append(date)
            if quits.count > SystemQuitsRecord.limit {
                quits.removeFirst(quits.count - SystemQuitsRecord.limit)
            }
            writeLocked(SystemQuitsRecord(quits: quits), to: fileURL)
        }
    }

    /// When Cherry quit for a log out, restart or shut down, oldest first;
    /// nothing when the store is disabled.
    func loadSystemQuits() -> [Date] {
        guard isEnabled else { return [] }
        let fileURL = systemQuitsFileURL
        return queue.sync {
            readVersionedLocked(SystemQuitsRecord.self, from: fileURL)?.quits ?? []
        }
    }

    /// This app is ending these sessions of This Mac on purpose (the local
    /// host's identity and the session id): queued ahead of any later save.
    /// Entries no saved state file names any more are dropped meanwhile.
    func addEndedSessions(_ sessions: [(hostID: String, sessionID: String)]) {
        guard isEnabled, !sessions.isEmpty else { return }
        let fileURL = endedSessionsFileURL
        let now = Date()
        queue.async {
            var record = self.readEndedSessionsLocked(fileURL)
            let added = Set(sessions.map { Self.key(hostID: $0.hostID, sessionID: $0.sessionID) })
            let named = self.namedLocalSessionsLocked()
            record.entries.removeAll { entry in
                let key = Self.key(hostID: entry.hostID, sessionID: entry.sessionID)
                return added.contains(key) || !named.contains(key)
            }
            var seen = Set<String>()
            for session in sessions where seen.insert(Self.key(hostID: session.hostID, sessionID: session.sessionID)).inserted {
                record.entries.append(EndedSessionsRecord.Entry(hostID: session.hostID, sessionID: session.sessionID, endedAt: now))
            }
            self.writeLocked(record, to: fileURL)
        }
    }

    /// Whether this app ended the session of saved tab `record` on purpose:
    /// its session is among the ended ones (`addEndedSessions`), or the tab
    /// is among the forgotten or closed tabs whose sessions are to be ended
    /// (`SessionsToEndRecord`). Also true when the list of ended sessions
    /// was lost after the record was saved (`savedAt`, else `fallbackSavedAt`;
    /// unknown counts as before): what cannot be checked is not brought
    /// back. False when the store is disabled.
    func wasEndedOnPurpose(_ record: WorkspaceSessionRecord, fallbackSavedAt: Date? = nil) -> Bool {
        guard isEnabled else { return false }
        let endedURL = endedSessionsFileURL
        let toEndURL = sessionsToEndFileURL
        return queue.sync {
            if (readSessionsToEndLocked(toEndURL) ?? []).contains(where: { $0.record.id == record.id }) {
                return true
            }
            let ended = readEndedSessionsLocked(endedURL)
            if let lostBefore = ended.lostBefore, (record.savedAt ?? fallbackSavedAt ?? .distantPast) <= lostBefore {
                return true
            }
            // Any host's: entries are keyed by host identity, so This Mac's
            // and each device's stay apart.
            guard let binding = record.hosted else { return false }
            return ended.entries.contains { $0.hostID == binding.hostID && $0.sessionID == binding.sessionID }
        }
    }

    /// The host `hostID` reported these sessions lost: kept, so a window
    /// opened after its daemon restarted still knows. Entries no saved state
    /// file names any more are dropped meanwhile.
    func addLostSessions(_ sessionIDs: Set<String>, hostID: String) {
        guard isEnabled, !sessionIDs.isEmpty else { return }
        let fileURL = lostSessionsFileURL
        let now = Date()
        queue.async {
            var entries = self.readVersionedLocked(LostSessionsRecord.self, from: fileURL)?.entries ?? []
            let known = Set(entries.map { Self.key(hostID: $0.hostID, sessionID: $0.sessionID) })
            let fresh = sessionIDs.sorted().filter { !known.contains(Self.key(hostID: hostID, sessionID: $0)) }
            guard !fresh.isEmpty else { return }
            let named = self.namedLocalSessionsLocked()
            entries.removeAll { !named.contains(Self.key(hostID: $0.hostID, sessionID: $0.sessionID)) }
            entries += fresh.map { LostSessionsRecord.Entry(hostID: hostID, sessionID: $0, seenAt: now) }
            self.writeLocked(LostSessionsRecord(entries: entries), to: fileURL)
        }
    }

    var unreadSessionsFileURL: URL {
        directory.appendingPathComponent("unread-sessions.json", isDirectory: false)
    }

    /// A session in the background had a bell or notification: kept until a
    /// tab shows it (`takeUnreadSession`).
    func addUnreadSession(hostID: String, sessionID: String) {
        guard isEnabled else { return }
        let fileURL = unreadSessionsFileURL
        let now = Date()
        queue.async {
            var entries = self.readUnreadSessionsLocked(fileURL)
            guard !entries.contains(where: { $0.hostID == hostID && $0.sessionID == sessionID }) else { return }
            entries.append(UnreadSessionsRecord.Entry(hostID: hostID, sessionID: sessionID, since: now))
            self.writeLocked(UnreadSessionsRecord(entries: entries), to: fileURL)
        }
    }

    /// Whether the session was marked unread while in the background; the
    /// mark goes (a tab shows it now).
    func takeUnreadSession(hostID: String, sessionID: String) -> Bool {
        guard isEnabled else { return false }
        let fileURL = unreadSessionsFileURL
        return queue.sync {
            var entries = readUnreadSessionsLocked(fileURL)
            guard let index = entries.firstIndex(where: { $0.hostID == hostID && $0.sessionID == sessionID }) else {
                return false
            }
            entries.remove(at: index)
            writeLocked(UnreadSessionsRecord(entries: entries), to: fileURL)
            return true
        }
    }

    /// The sessions of host `hostID` marked unread (`addUnreadSession`).
    func unreadSessions(hostID: String) -> Set<String> {
        guard isEnabled else { return [] }
        let fileURL = unreadSessionsFileURL
        return queue.sync {
            Set(readUnreadSessionsLocked(fileURL).filter { $0.hostID == hostID }.map(\.sessionID))
        }
    }

    /// Only on `queue`.
    private func readUnreadSessionsLocked(_ fileURL: URL) -> [UnreadSessionsRecord.Entry] {
        let oldest = Date().addingTimeInterval(-UnreadSessionsRecord.maximumAge)
        return (readVersionedLocked(UnreadSessionsRecord.self, from: fileURL)?.entries ?? []).filter { $0.since >= oldest }
    }

    /// Whether a saved tab of any project (open or closed window, or a
    /// set-aside copy of a state file) names this
    /// session of `owner`'s on the local host `hostID`, attached or owned
    /// (`PersistentLocalSessions.record(_:names:hostID:owner:includingAttached:)`):
    /// such a session is kept for that tab's restore, which shows how it
    /// ended. True while the store is disabled (nothing can be checked).
    func savedTabsName(_ info: HostedSessionInfo, hostID: String, owner: String) -> Bool {
        guard isEnabled else { return true }
        return queue.sync {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
            // A set-aside copy (`<state file>.<label>-<time>.bak`), which a
            // build of another version may still restore: any mention of
            // the session, its tab or its Create keeps it.
            let mentions = [info.id, PersistentLocalSessions.tabID(of: info, owner: owner)?.uuidString,
                            PersistentLocalSessions.launchRequestID(of: info)].compactMap { $0?.nilIfEmpty }
            for name in names where name.hasSuffix(".bak") && name.contains(".json.") {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard let data = try? Data(contentsOf: url) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                if mentions.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) { return true }
            }
            for name in names where Self.isStateFileName(name) {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                switch Self.readFile(RepositoryStateRecord.self, from: url) {
                case .missing:
                    continue
                case .unusable:
                    // Cannot tell what it names: keep the session.
                    return true
                case .usable(let state):
                    let named = state.worktrees.contains { worktree in
                        worktree.sessions.contains { record in
                            PersistentLocalSessions.record(record, names: info, hostID: hostID, owner: owner, includingAttached: true)
                        }
                    }
                    if named { return true }
                }
            }
            return false
        }
    }

    /// The sessions of host `hostID` its host reported lost, as recorded.
    func lostSessions(hostID: String) -> Set<String> {
        guard isEnabled else { return [] }
        let fileURL = lostSessionsFileURL
        return queue.sync {
            let entries = readVersionedLocked(LostSessionsRecord.self, from: fileURL)?.entries ?? []
            return Set(entries.filter { $0.hostID == hostID }.map(\.sessionID))
        }
    }

    private static func key(hostID: String, sessionID: String) -> String {
        "\(hostID)\u{0}\(sessionID)"
    }

    /// Every session a saved state file (of this version) names, This
    /// Mac's and devices' (keyed by host identity). Only on `queue`.
    private func namedLocalSessionsLocked() -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var named = Set<String>()
        for name in names where Self.isStateFileName(name) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard case .usable(let state) = Self.readFile(RepositoryStateRecord.self, from: url) else { continue }
            for worktree in state.worktrees {
                for session in worktree.sessions {
                    guard let binding = session.hosted else { continue }
                    named.insert(Self.key(hostID: binding.hostID, sessionID: binding.sessionID))
                }
            }
        }
        return named
    }

    /// The ended sessions. A file this version cannot use is moved aside,
    /// and the list starts again from then (`lostBefore`), written at once so
    /// the loss is not forgotten. Only on `queue`.
    private func readEndedSessionsLocked(_ fileURL: URL) -> EndedSessionsRecord {
        if case .missing = Self.readFile(EndedSessionsRecord.self, from: fileURL) {
            return EndedSessionsRecord(entries: [])
        }
        if let record = readVersionedLocked(EndedSessionsRecord.self, from: fileURL) {
            return record
        }
        let restarted = EndedSessionsRecord(entries: [], lostBefore: Date())
        writeLocked(restarted, to: fileURL)
        return restarted
    }

    /// A record file of this version; one this version cannot use (another
    /// version, or one that does not decode) is moved aside first. Only on
    /// `queue`.
    private func readVersionedLocked<Record: VersionedRecord>(_ type: Record.Type, from fileURL: URL) -> Record? {
        switch Self.readFile(type, from: fileURL) {
        case .missing:
            return nil
        case .unusable(let found):
            setAsideLocked(fileURL, label: found.map { "v\($0)" } ?? "unreadable")
            return nil
        case .usable(let record):
            guard record.version == Record.currentVersion else {
                setAsideLocked(fileURL, label: "v\(record.version)")
                return nil
            }
            return record
        }
    }

    /// The entries that have not expired; a file this version cannot use is
    /// moved aside first. Only on `queue`.
    private func readSessionsToEndLocked(_ fileURL: URL) -> [SessionsToEndRecord.Entry]? {
        guard let record = readVersionedLocked(SessionsToEndRecord.self, from: fileURL) else { return nil }
        let oldest = Date().addingTimeInterval(-SessionsToEndRecord.maximumAge)
        return record.entries.filter { $0.forgottenAt >= oldest }
    }

    private enum FileRead<Value> {
        case missing
        case usable(Value)
        /// There, but unreadable or not decodable; `version` when the file
        /// says which it is.
        case unusable(version: Int?)
    }

    private struct VersionOnly: Decodable {
        let version: Int
    }

    private static func readFile<Value: Decodable>(_ type: Value.Type, from fileURL: URL) -> FileRead<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            var status = stat()
            return lstat(fileURL.path, &status) == 0 ? .unusable(version: nil) : .missing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(type, from: data) { return .usable(value) }
        return .unusable(version: (try? decoder.decode(VersionOnly.self, from: data))?.version)
    }

    /// Set-aside files (`<state file>.<label>-<time>.bak`) older than this
    /// are removed at launch (`pruneSetAsideFiles`), except the newest of
    /// each state file.
    static let setAsideFileAge: TimeInterval = 30 * 24 * 60 * 60

    /// Removes old set-aside files in the background: those older than
    /// `setAsideFileAge`, keeping the newest one of each state file, which
    /// orphan adoption may still read (`setAsideState`) and a build of
    /// another version may still be pointed at.
    func pruneSetAsideFiles(now: Date = Date()) {
        guard isEnabled else { return }
        let directory = directory
        queue.async {
            Self.pruneSetAsideFiles(in: directory, now: now)
        }
    }

    /// `pruneSetAsideFiles`, now; blocking. Returns the names removed.
    @discardableResult
    static func pruneSetAsideFiles(in directory: URL, now: Date = Date()) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var byStateFile: [String: [(name: String, modified: Date)]] = [:]
        for name in names where name.hasSuffix(".bak") {
            guard let dot = name.range(of: ".json.") else { continue }
            let stateFile = String(name[..<dot.upperBound].dropLast())
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
            byStateFile[stateFile, default: []].append((name, modified))
        }
        let cutoff = now.addingTimeInterval(-setAsideFileAge)
        var removed: [String] = []
        for files in byStateFile.values {
            let newestFirst = files.sorted { $0.modified > $1.modified }
            for file in newestFirst.dropFirst() where file.modified < cutoff {
                if (try? manager.removeItem(at: directory.appendingPathComponent(file.name, isDirectory: false))) != nil {
                    removed.append(file.name)
                }
            }
        }
        return removed.sorted()
    }

    /// Moves a file this version cannot use out of the way of the next save,
    /// keeping it beside the original. Only on `queue`.
    private func setAsideLocked(_ fileURL: URL, label: String) {
        do {
            try PrivateFile.setAside(fileURL, label: label)
            protectedFiles.remove(fileURL.path)
        } catch {
            let reason = (error as? POSIXError).map { String(cString: strerror($0.code.rawValue)) } ?? "\(error)"
            fputs("Cherry: \(fileURL.lastPathComponent) cannot be used by this version (\(label)) and could not be moved aside (\(reason)); it will not be written over\n", stderr)
            protectedFiles.insert(fileURL.path)
        }
    }

    /// Only on `queue`.
    private func writeLocked<Value: Encodable>(_ value: Value, to fileURL: URL) {
        guard !protectedFiles.contains(fileURL.path) else {
            fputs("Cherry: not saving \(fileURL.lastPathComponent): a file this version cannot use is still there\n", stderr)
            return
        }
        do {
            try Self.write(value, to: fileURL)
        } catch {
            fputs("Cherry: could not save \(fileURL.lastPathComponent): \(error)\n", stderr)
        }
    }

    /// Writes `value` as JSON, owner-only, replacing the file atomically
    /// (`PrivateFile.write`): readers see the old file or the new one,
    /// never a partial write.
    static func write<Value: Encodable>(_ value: Value, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.write(encoder.encode(value), to: fileURL)
    }
}

/// A saved record file with a version (`WorkspaceStateStore.readVersionedLocked`):
/// a file of another version is moved aside, never migrated.
private protocol VersionedRecord: Decodable {
    var version: Int { get }
    static var currentVersion: Int { get }
}

extension RepositoryStateRecord: VersionedRecord {}
extension OpenProjectWindowsRecord: VersionedRecord {}
extension SessionsToEndRecord: VersionedRecord {}
extension SystemQuitsRecord: VersionedRecord {}
extension EndedSessionsRecord: VersionedRecord {}
extension LostSessionsRecord: VersionedRecord {}
extension UnreadSessionsRecord: VersionedRecord {}

// MARK: - Restore

/// What a restorer brings back for one project window.
@MainActor
struct WorkspaceRestoreRequest {
    let repositoryRoot: String
    /// The records a tab can come back for (bound to a hosted session), in
    /// saved order.
    let records: [WorkspaceSessionRecord]
    /// Build tabs with its factories (`makeRestoredHostedSession`,
    /// `makeRestoredPersistentSession`), but do not add them: the restore
    /// adds them with the saved layout.
    let workspace: TerminalWorkspace
    /// The window's other records (no hosted binding saved: a native tab,
    /// or a local tab whose session's Create had not answered when it was
    /// saved). A restorer may bring one back when the local host has a
    /// session of this app that its saved Create started
    /// (`launchRequestID`) or tagged with its tab id (`cherry.tab`); the
    /// others are dropped, as native tabs are.
    var unboundRecords: [WorkspaceSessionRecord] = []
    /// Cancelled when the workspace is torn down (its window closed, the app
    /// quit) while this restore runs: the restore
    /// then builds no more tabs, and ends those it built that it has not
    /// handed back yet (with the workspace's close intent), so no stale tab
    /// goes on owning a session a new window's restore should bring back.
    var cancellation = WorkspaceRestoreCancellation()
    /// Which records whose session is gone the system ended: they come back
    /// as ended tabs instead of being dropped. Nil: none does (a restore
    /// without saved state behind it, tests).
    var systemEnds: SystemEndedSessions?
    /// Tabs already in `workspace` for some of `records`, shown before the
    /// host answered (`OptimisticRestore`), by record id. The restore
    /// confirms each whose session the host lists as the record's own
    /// (`WorkspaceRestoreResult.confirmedOptimisticRecordIDs`); for the
    /// others it decides as for any record, and the repository withdraws
    /// the tab (replacing it with the tab the restore built, if any).
    var optimisticTabs: [UUID: TerminalSession] = [:]
}

// MARK: - Sessions the system ended

/// How the system, not the user or the program, ended a saved tab's session
/// while Cherry was closed (docs/specs/multiplexer-default.md, "Relaunch").
enum SystemSessionEnd: String, Codable, Equatable, Sendable {
    /// This Mac started again since the tab was saved: a restart, a shut
    /// down, a power loss or a crash.
    case restart
    /// The user logged out since: the system ended their processes.
    case logout
    /// Another Mac's host (a device, docs/specs/remote-devices.md) reported
    /// the session lost: its holder was killed, as a restart or log out of
    /// that Mac does. Only a device's tab ends this way.
    case hostRestart = "hostRestart"

    /// What the ended tab says (`PersistentSessionEndedBar`). `machine`:
    /// the device a `hostRestart` names ("Ended when Studio restarted").
    func message(machine: String? = nil) -> String {
        switch self {
        case .restart: "Ended when the Mac restarted"
        case .logout: "Ended when you logged out"
        case .hostRestart: "Ended when \(machine ?? "the other Mac") restarted"
        }
    }

    var message: String { message() }

    /// The message as a clause: "ended when the Mac restarted" (a task's
    /// reason, after "its session").
    func endedClause(machine: String? = nil) -> String {
        let text = message(machine: machine)
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// The window's toast after its tab count: "3 tabs ended when the Mac
    /// restarted".
    func predicate(machine: String? = nil) -> String {
        " " + endedClause(machine: machine)
    }
}

/// Decides whether the system ended a saved tab's session while Cherry was
/// closed. Such a tab comes back ended, in its place, with its kind, title,
/// agent, command and directory, and Restart starts it again; any other
/// tab whose session is gone is dropped, as before.
///
/// The rule. A saved tab that owned a session of This Mac
/// (`WorkspaceSessionRecord.mayOwnLocalSession`: bound to one, or saved
/// while its Create was under way) whose session a complete list of the
/// same host no longer has, and that this app did not end on purpose
/// (`endedOnPurpose`: `WorkspaceStateStore.wasEndedOnPurpose`, or being
/// ended now), was ended by the system when one of these says so:
/// 1. This Mac booted after the record was last saved by an open tab
///    (`WorkspaceSessionRecord.savedAt`, else the file's `savedAt`; a
///    record kept while its host could not be listed keeps its time):
///    `.restart`. This covers a crash, a power loss and a forced restart,
///    which run no Cherry code.
/// 2. Cherry quit for a log out, restart or shut down after that
///    (`WorkspaceStateStore.noteSystemQuit`): `.logout` (a restart also
///    moved the boot time, rule 1).
/// 3. The host found the session's holder killed rather than ended
///    (`HostedSessionList.lostSessionIDs`: its manifest left behind), now or
///    when this app last saw it report so (`WorkspaceStateStore.lostSessions`),
///    as a log out kills the user's processes while Cherry is not running:
///    `.logout`.
/// Without any of them (a normal relaunch, a session that ended while the
/// Mac ran) the tab is dropped.
///
/// A saved tab that owned a session of another Mac's host (a device's tab,
/// `WorkspaceSessionRecord.ownsRemoteSession`) says nothing about This
/// Mac's boot or quits: only its host's word counts (rule 3: that host
/// reported the session lost, now or earlier). A record whose program had exited before
/// (`exitStatus`) comes back showing that exit instead, or stays dropped
/// where *close on exit* would have closed it (a terminal's exit 0).
@MainActor
struct SystemEndedSessions {
    /// When the state the records come from was saved, for a record that
    /// does not say itself (`WorkspaceSessionRecord.savedAt`, an older
    /// file's); nil when neither says: then only the host's word counts.
    var savedAt: Date?
    /// When This Mac last booted (`currentBootTime()`).
    var bootTime: Date?
    /// When Cherry quit for a log out, restart or shut down.
    var systemQuits: [Date]
    /// Whether this app ended the record's session on purpose.
    var endedOnPurpose: @MainActor (WorkspaceSessionRecord) -> Bool
    /// The sessions of a host (by its identity) that it reported lost
    /// earlier, as this app recorded them (`WorkspaceStateStore.lostSessions`).
    var recordedLostSessions: @MainActor (String) -> Set<String> = { _ in [] }

    /// When `record` was last known to run: when an open tab last saved it.
    func savedAt(of record: WorkspaceSessionRecord) -> Date? {
        record.savedAt ?? savedAt
    }

    /// How the system ended `record`'s session, which `list` (complete, of
    /// the host the record names) does not have; nil when the tab is to be
    /// dropped. A record whose program had exited (`exitStatus`) comes back
    /// showing that exit, not as ended by the system.
    func end(of record: WorkspaceSessionRecord, missingFrom list: HostedSessionList) -> SystemSessionEnd? {
        let remote = record.ownsRemoteSession
        guard record.mayOwnLocalSession || remote, !endedOnPurpose(record) else { return nil }
        let lost = record.hosted.map { binding in
            binding.hostID == list.hostID
                && (list.lostSessionIDs.contains(binding.sessionID)
                    || recordedLostSessions(binding.hostID).contains(binding.sessionID))
        } ?? false
        if remote {
            // This Mac's boot time and quits are not that Mac's: only the
            // device's own word that it lost the session ("Ended when
            // <Mac> restarted").
            return lost ? .hostRestart : nil
        }
        return Self.end(savedAt: savedAt(of: record), bootTime: bootTime, systemQuits: systemQuits, lostByHost: lost)
    }

    /// The rule's evidence (see the type). Saves keep whole seconds, and so
    /// does this comparison.
    nonisolated static func end(
        savedAt: Date?,
        bootTime: Date?,
        systemQuits: [Date],
        lostByHost: Bool
    ) -> SystemSessionEnd? {
        let saved = savedAt.map { $0.timeIntervalSince1970.rounded(.down) }
        if let saved, let bootTime, saved < bootTime.timeIntervalSince1970.rounded(.down) {
            return .restart
        }
        if let saved, systemQuits.contains(where: { $0.timeIntervalSince1970.rounded(.down) >= saved }) {
            return .logout
        }
        return lostByHost ? .logout : nil
    }

    /// When This Mac last booted (`kern.boottime`); nil if it cannot say.
    nonisolated static func currentBootTime() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}

/// See `WorkspaceRestoreRequest.cancellation`.
@MainActor
final class WorkspaceRestoreCancellation {
    private(set) var isCancelled = false
    private var handlers: [@MainActor () -> Void] = []

    nonisolated init() {}

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let handlers = handlers
        self.handlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Runs `handler` once cancelled (now, when it is already).
    func onCancel(_ handler: @escaping @MainActor () -> Void) {
        if isCancelled {
            handler()
        } else {
            handlers.append(handler)
        }
    }
}

/// This app's sessions on This Mac that no saved tab names, which the
/// window of the project they were started in adopts as tabs (their
/// `cherry.project` tag), instead of leaving them running unseen: sessions
/// whose tab was never saved (the app crashed within the save delay after
/// opening it) or whose saved record was lost. A session qualifies when
/// this app variant created it for a tab (`cherry.tab`), no saved record
/// names it (by session, Create request or tab id), no forgotten tab it
/// ran for is still to be ended (`SessionsToEndRecord`), and it was
/// created before this app run began (`createdBefore`: one created during
/// this run belongs to this run's tabs) and after the saved state it would
/// be missing from (`createdSince`, the last save, to the second): a
/// session created before that save and missing from it was left running on
/// purpose (a detached tab). Of a project's windows (#22), each adopts only
/// the sessions created for it (`windowID`, the `cherry.window` tag), the
/// project's primary window only those with no window tag.
///
/// Without a usable state file:
/// - When this version moved one aside (another version's, or one that
///   does not decode: `SetAsideStateSummary`), `createdSince` is when that
///   file was saved, and the sessions it named (its tabs, which this
///   version cannot restore from it) come back whenever they were created.
/// - When there never was one, any time counts: no tab of this project was
///   ever saved, so none can have been closed with its session kept.
struct OrphanedSessionCriteria: Sendable {
    let owner: String
    let createdSince: Date?
    let createdBefore: Date
    let namedTabIDs: Set<UUID>
    let namedSessionIDs: Set<String>
    let namedLaunchIDs: Set<String>
    /// Named by a state file this version moved aside: adopted whenever
    /// they were created.
    let recoveredTabIDs: Set<UUID>
    let recoveredSessionIDs: Set<String>
    let recoveredLaunchIDs: Set<String>
    /// The window whose orphans these are (`ProjectWindowValue.windowID`);
    /// nil for a project's primary window.
    let windowID: UUID?

    init(
        owner: String,
        savedState: RepositoryStateRecord?,
        setAside: SetAsideStateSummary? = nil,
        sessionsToEnd: [WorkspaceSessionRecord] = [],
        createdBefore: Date,
        host: HostedSessionHost = .local,
        windowID: UUID? = nil
    ) {
        self.owner = owner
        self.createdBefore = createdBefore
        self.windowID = windowID
        let records = savedState?.worktrees.flatMap(\.sessions) ?? []
        let recovered = savedState == nil ? setAside : nil
        if let savedState {
            createdSince = savedState.savedAt ?? .distantPast
        } else {
            createdSince = recovered?.savedAt
        }
        // A tab saved ended by the system names no session: one started for
        // it since (a Restart whose binding was never saved) is its own.
        namedTabIDs = Set(records.filter { $0.mayComeBack && $0.systemEnd == nil }.map(\.id))
            .union(sessionsToEnd.map(\.id))
        namedSessionIDs = Set((records + sessionsToEnd).compactMap { record in
            record.hosted.flatMap { $0.host == host.id ? $0.sessionID : nil }
        })
        namedLaunchIDs = Set((records + sessionsToEnd).compactMap { $0.launchRequestID?.lowercased() })
        recoveredTabIDs = recovered?.tabIDs ?? []
        recoveredSessionIDs = recovered?.sessionIDs ?? []
        recoveredLaunchIDs = recovered?.launchIDs ?? []
    }

    /// The tab id `info` was started for, when it is such a session.
    func orphanTabID(of info: HostedSessionInfo) -> UUID? {
        let launchID = PersistentLocalSessions.launchRequestID(of: info)
        guard info.owner == owner,
              let tabID = PersistentLocalSessions.tabID(of: info, owner: owner),
              info.tags[PersistentSessionTag.project]?.isEmpty == false,
              isCreatedForThisWindow(info),
              !namedTabIDs.contains(tabID),
              !namedSessionIDs.contains(info.id),
              !(launchID.map(namedLaunchIDs.contains) ?? false),
              info.createdAt > 0
        else { return nil }
        let created = Date(timeIntervalSince1970: TimeInterval(info.createdAt) / 1_000)
        let recovered = recoveredTabIDs.contains(tabID)
            || recoveredSessionIDs.contains(info.id)
            || (launchID.map(recoveredLaunchIDs.contains) ?? false)
        // Saves keep whole seconds: a session created in the second of the
        // last save counts as missing from it.
        if !recovered, let createdSince,
           created < Date(timeIntervalSince1970: createdSince.timeIntervalSince1970.rounded(.down)) {
            return nil
        }
        return created < createdBefore ? tabID : nil
    }

    /// Whether `info` was created for this window: tagged with its id, or,
    /// for a project's primary window, with no window tag (a tag no id
    /// reads is no window's).
    private func isCreatedForThisWindow(_ info: HostedSessionInfo) -> Bool {
        guard info.tags[PersistentSessionTag.window] != nil else { return windowID == nil }
        return windowID != nil && PersistentLocalSessions.windowID(of: info) == windowID
    }

    /// The project folder `info` was started in, as its tab saw it.
    static func projectRoot(of info: HostedSessionInfo) -> String? {
        info.tags[PersistentSessionTag.project]?.nilIfEmpty
    }

    /// A record for an adopted session of `host` (This Mac by default): the
    /// tab it was started for, with what its tags and the host tell (kind,
    /// agent, command, project, name and directory). What only a saved
    /// record knows (launch command and settings, parent agent, layout) is
    /// not there.
    static func record(
        for info: HostedSessionInfo,
        tabID: UUID,
        hostID: String,
        host: HostedSessionHost = .local
    ) -> WorkspaceSessionRecord {
        let kind = info.tags[PersistentSessionTag.kind].flatMap(TerminalSession.SessionKind.init(rawValue:)) ?? .terminal
        return WorkspaceSessionRecord(
            id: tabID,
            kind: kind,
            title: info.name,
            titleSource: .system,
            agentName: info.tags[PersistentSessionTag.agent]?.nilIfEmpty,
            commandName: info.tags[PersistentSessionTag.command]?.nilIfEmpty,
            workingDirectory: info.cwd,
            projectRoot: projectRoot(of: info),
            hosted: HostedSessionBindingRecord(
                host: host.id, hostID: hostID, sessionID: info.id,
                remoteWorkingDirectory: info.cwd, owned: true
            ),
            launchRequestID: PersistentLocalSessions.launchRequestID(of: info)
        )
    }
}

/// What a restorer brought back for one project window.
@MainActor
struct WorkspaceRestoreResult {
    /// Tabs built for saved records (not added to the workspace).
    var sessions: [TerminalSession] = []
    /// Records that cannot come back now but may later, because the helper or
    /// the host is unavailable, not because their session is gone. They stay
    /// saved, unchanged, for the next launch. Every other record the result
    /// has no tab for is dropped.
    var keptRecordIDs: Set<UUID> = []
    /// Fires (once) when the kept records may come back during this run:
    /// the local host, unreachable during the restore, became reachable, or
    /// a host that still expected holders to register expects none now.
    /// The repository then restores them again. Nil when only a later
    /// launch can bring them back.
    var retryWhenAvailable: AnyPublisher<Void, Never>?
    /// Records whose host had not answered yet when this result was made
    /// (or whose session is being looked for again): `remainder` finishes
    /// them. They stay saved meanwhile, and a command they name is not
    /// started a second time.
    var pendingRecordIDs: Set<UUID> = []
    /// The rest of this restore, for `pendingRecordIDs`: a result like this
    /// one (tabs, kept records, and maybe records still pending with a
    /// remainder of their own).
    var remainder: Task<WorkspaceRestoreResult, Never>?
    /// Records whose tab the restore showed before the host answered
    /// (`WorkspaceRestoreRequest.optimisticTabs`) and that stay as they
    /// are: the host lists their session. Not in `sessions`.
    var confirmedOptimisticRecordIDs: Set<UUID> = []

    /// Restores nothing now and keeps `records` saved.
    static func keeping(_ records: [WorkspaceSessionRecord]) -> WorkspaceRestoreResult {
        WorkspaceRestoreResult(keptRecordIDs: Set(records.map(\.id)))
    }

    /// Ends the tabs of `result`, and of its remainder when that finishes,
    /// as `workspace` ended its other tabs (the window closed or the app
    /// quit while the restore ran).
    static func discard(_ result: WorkspaceRestoreResult, in workspace: TerminalWorkspace) {
        workspace.discardRestoredSessions(result.sessions)
        guard let remainder = result.remainder else { return }
        Task { @MainActor in
            discard(await remainder.value, in: workspace)
        }
    }
}

/// Builds tabs for saved records, keeping each record's id, and names the
/// records to keep for a later launch. The app passes
/// `WorkspaceSessionRestorers.hostedByDefault(localSessions: .shared)`
/// (WorkspaceRestore.swift).
typealias WorkspaceSessionRestorer = @MainActor (WorkspaceRestoreRequest) async -> WorkspaceRestoreResult

@MainActor
enum WorkspaceSessionRestorers {
    /// Restores nothing: every saved tab is dropped.
    static let none: WorkspaceSessionRestorer = { _ in WorkspaceRestoreResult() }
}
