import AppKit
import CherryControl
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// MARK: - Helpers

private func makeCanonicalTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
        throw CocoaError(.fileNoSuchFile)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private func hostedRecord(
    id: UUID = UUID(),
    title: String,
    titleSource: TerminalSession.TitleSource = .explicit,
    host: String = "local",
    hostID: String = "host-a",
    sessionID: String,
    kind: TerminalSession.SessionKind = .terminal,
    commandName: String? = nil
) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: kind,
        title: title,
        titleSource: titleSource,
        commandName: commandName,
        launchCommand: commandName.map { "run-\($0)" },
        launchEnvironment: commandName == nil ? [:] : ["PORT": "8000"],
        launchWorkingDirectory: "/project",
        workingDirectory: "/project",
        restartOnExit: commandName != nil,
        projectRoot: "/project",
        hosted: HostedSessionBindingRecord(
            host: host,
            hostID: hostID,
            sessionID: sessionID,
            remoteWorkingDirectory: "/remote/\(sessionID)"
        )
    )
}

private func nativeRecord(id: UUID = UUID(), title: String, kind: TerminalSession.SessionKind = .terminal) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(id: id, kind: kind, title: title, workingDirectory: "/project")
}

private func localAttachment(sessionID: String, name: String = "Hosted") -> HostedSessionAttachment {
    HostedSessionAttachment(
        host: .local,
        hostID: "host-a",
        sessionID: sessionID,
        name: name,
        remoteWorkingDirectory: "/remote",
        executablePath: "/nonexistent/cherry"
    )
}

private func remoteAttachment(sessionID: String) throws -> HostedSessionAttachment {
    HostedSessionAttachment(
        host: try .ssh("devbox"),
        hostID: "host-b",
        sessionID: sessionID,
        name: "Remote",
        remoteWorkingDirectory: "/remote",
        executablePath: "/nonexistent/cherry"
    )
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Suspends a restore until the test opens it.
@MainActor
private final class RestoreGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

/// Restores hosted records as tabs that launch nothing.
@MainActor
private final class FakeHostedRestorer {
    private(set) var requestedRecordIDs: [[UUID]] = []
    var gate: RestoreGate?
    /// Every session is gone: every record is dropped.
    var restoresNothing = false
    /// The helper is unavailable: every record is kept for later.
    var keepsEverything = false

    var restorer: WorkspaceSessionRestorer {
        { [self] request in
            requestedRecordIDs.append(request.records.map(\.id))
            if let gate {
                await gate.wait()
            }
            if keepsEverything {
                return .keeping(request.records)
            }
            guard !restoresNothing else { return WorkspaceRestoreResult() }
            return WorkspaceRestoreResult(sessions: request.records.compactMap { record in
                guard let binding = record.hosted, let host = binding.hostedSessionHost else { return nil }
                let attachment = HostedSessionAttachment(
                    host: host,
                    hostID: binding.hostID,
                    sessionID: binding.sessionID,
                    name: record.title,
                    remoteWorkingDirectory: binding.remoteWorkingDirectory ?? "~",
                    executablePath: "/nonexistent/cherry"
                )
                return request.workspace.makeRestoredHostedSession(attachment, record: record, launchShell: false)
            })
        }
    }
}

/// A backend policy whose local hosted tabs follow their close intents,
/// recording each hosted session it terminates.
@MainActor
private final class RecordingBackendPolicy {
    var settings = SessionPersistenceSettings.defaults
    private(set) var terminated: [(sessionID: String, intent: SessionCloseIntent)] = []

    var policy: SessionBackendPolicy {
        SessionBackendPolicy(
            settings: { [self] in settings },
            hostedLocalTabsFollowSettings: true,
            terminateHostedSession: { [self] session, intent in
                terminated.append((session.hostedAttachment?.sessionID ?? "native", intent))
            }
        )
    }
}

private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitWorktreeCommandError(
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardError: String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

@MainActor
private func makeTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

/// Saves one worktree of hosted tabs for `root` and returns a repository
/// that restores them with `restorer`.
@MainActor
private func makeRestoringRepository(
    root: URL,
    records: [WorkspaceSessionRecord],
    store: WorkspaceStateStore,
    restorer: FakeHostedRestorer,
    backendPolicy: SessionBackendPolicy = .native
) -> RepositoryWorkspace {
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: records)]
    ))
    return RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: backendPolicy,
        stateStore: store,
        sessionRestorer: restorer.restorer,
        autoStartCommands: { _ in [] }
    )
}

/// `RepositoryWorkspace.repositoryRoot` for a directory: standardized, so a
/// temporary directory loses its /private prefix. Worktree roots stay real
/// paths.
private func repositoryKey(_ url: URL) -> String {
    URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL.path
}

@MainActor
private func waitForSavedState(
    in store: WorkspaceStateStore,
    repositoryRoot: String,
    timeout: TimeInterval = 3,
    _ condition: (RepositoryStateRecord) -> Bool
) async -> RepositoryStateRecord? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        store.flush()
        if let state = store.load(repositoryRoot: repositoryRoot), condition(state) {
            return state
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

private func savedSessionIDs(_ state: RepositoryStateRecord?, root: String) -> [UUID] {
    state?.worktree(root: root)?.sessions.map(\.id) ?? []
}

// MARK: - Store

@Test func workspaceStateStoreRoundTripsRepositoryState() throws {
    let directory = try makeCanonicalTemporaryDirectory("cherry-workspace-store")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let splitID = UUID()
    let first = hostedRecord(title: "Editor", sessionID: "s-1")
    let second = hostedRecord(title: "Server", host: "ssh:devbox", hostID: "host-b", sessionID: "s-2", kind: .command, commandName: "server")
    var agent = nativeRecord(title: "Claude", kind: .agent)
    agent.agentName = "Claude"
    agent.parentAgentID = UUID()
    let state = RepositoryStateRecord(
        repositoryRoot: "/repo",
        activeWorktreeRoot: "/repo/feature",
        worktrees: [
            WorktreeStateRecord(
                root: "/repo",
                sessions: [first, second, agent],
                displayItems: [
                    WorkspaceDisplayItemRecord(kind: .split, id: splitID),
                    WorkspaceDisplayItemRecord(kind: .single, id: second.id)
                ],
                splitGroups: [WorkspaceSplitGroupRecord(
                    id: splitID,
                    paneSessionIDs: [first.id, second.id],
                    activeSessionID: second.id,
                    widthWeights: [0.25, 0.75]
                )],
                selectedSessionID: second.id,
                collapsedAgentGroupIDs: [agent.id]
            ),
            WorktreeStateRecord(root: "/repo/feature", sessions: [])
        ],
        savedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    store.saveSynchronously(state)

    let digest = SHA256.hash(data: Data("/repo".utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(store.stateFileURL(repositoryRoot: "/repo").lastPathComponent == "\(digest).json")
    #expect(store.load(repositoryRoot: "/repo") == state)
    #expect(store.load(repositoryRoot: "/other") == nil)
    #expect(store.hasSavedTabs(repositoryRoot: "/repo"))
    #expect(second.hosted?.hostedSessionHost == (try HostedSessionHost.ssh("devbox")))
    #expect(first.hosted?.hostedSessionHost == .local)
    #expect(HostedSessionBindingRecord(host: "ssh:-oProxyCommand=x", hostID: "h", sessionID: "s").hostedSessionHost == nil)

    // Another version is ignored, as is a file that does not decode.
    var future = state
    future.version = RepositoryStateRecord.currentVersion + 1
    try WorkspaceStateStore.write(future, to: store.stateFileURL(repositoryRoot: "/repo"))
    #expect(store.load(repositoryRoot: "/repo") == nil)
    try Data("{not json".utf8).write(to: store.stateFileURL(repositoryRoot: "/repo"))
    #expect(store.load(repositoryRoot: "/repo") == nil)
    #expect(!store.hasSavedTabs(repositoryRoot: "/repo"))

    #expect(WorkspaceStateStore.defaultDirectory(applicationSupportName: "Cherry Sessions").path.hasSuffix(
        "Library/Application Support/Cherry Sessions/Workspaces"
    ))
}

@Test func workspaceStateStoreReplacesFilesAtomicallyAndPrivately() throws {
    let directory = try makeCanonicalTemporaryDirectory("cherry-workspace-atomic")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))
    let old = RepositoryStateRecord(
        repositoryRoot: "/repo",
        activeWorktreeRoot: "/repo",
        worktrees: [WorktreeStateRecord(root: "/repo", sessions: [nativeRecord(title: "Old")])]
    )
    let new = RepositoryStateRecord(
        repositoryRoot: "/repo",
        activeWorktreeRoot: "/repo",
        worktrees: [WorktreeStateRecord(root: "/repo", sessions: [nativeRecord(title: "New")])]
    )
    store.saveSynchronously(old)
    let fileURL = store.stateFileURL(repositoryRoot: "/repo")
    let linkURL = directory.appendingPathComponent("old-state.json")
    #expect(link(fileURL.path, linkURL.path) == 0)

    store.save(new)
    store.flush()

    // The save replaced the directory entry; it never rewrote the old file.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let linked = try decoder.decode(RepositoryStateRecord.self, from: Data(contentsOf: linkURL))
    #expect(linked.worktrees.first?.sessions.first?.title == "Old")
    #expect(store.load(repositoryRoot: "/repo")?.worktrees.first?.sessions.first?.title == "New")

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        .filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
}

@Test func theStoreRecordsSystemQuitsAndSessionsEndedOnPurposeAndTabsTheSystemEnded() throws {
    let directory = try makeCanonicalTemporaryDirectory("cherry-system-ends")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))

    // Quits for a log out, restart or shut down: the newest ones.
    #expect(store.loadSystemQuits().isEmpty)
    let first = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<(SystemQuitsRecord.limit + 3) {
        store.noteSystemQuit(at: first.addingTimeInterval(TimeInterval(index)))
    }
    let quits = store.loadSystemQuits()
    #expect(quits.count == SystemQuitsRecord.limit)
    #expect(quits.first == first.addingTimeInterval(3))
    #expect(quits.last == first.addingTimeInterval(TimeInterval(SystemQuitsRecord.limit + 2)))

    // Sessions ended on purpose, by host identity and session id.
    let bound = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/repo",
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: "s1", owned: true)
    )
    #expect(!store.wasEndedOnPurpose(bound))
    store.addEndedSessions([(hostID: "host-a", sessionID: "s1"), (hostID: "host-a", sessionID: "s1")])
    store.flush()
    #expect(store.wasEndedOnPurpose(bound))
    var elsewhere = bound
    elsewhere.hosted?.hostID = "host-b"
    #expect(!store.wasEndedOnPurpose(elsewhere))
    // A tab whose session is still to be ended counts too.
    let closing = WorkspaceSessionRecord(id: UUID(), kind: .terminal, title: "Closing", workingDirectory: "/repo")
    store.addSessionsToEnd([closing])
    store.flush()
    #expect(store.wasEndedOnPurpose(closing))
    // Never expires: an entry stays while a saved state names its
    // session, and goes once none does.
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: "/closed", activeWorktreeRoot: "/closed",
        worktrees: [WorktreeStateRecord(root: "/closed", sessions: [bound])],
        savedAt: Date(timeIntervalSince1970: 1_000)
    ))
    for index in 0..<3 {
        store.addEndedSessions([(hostID: "host-a", sessionID: "n\(index)")])
    }
    store.flush()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var ended = try decoder.decode(EndedSessionsRecord.self, from: Data(contentsOf: store.endedSessionsFileURL))
    // s1 (named by /closed) and the latest; unnamed older ones went.
    #expect(ended.entries.map(\.sessionID) == ["s1", "n2"])
    #expect(store.wasEndedOnPurpose(bound))
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: "/closed", activeWorktreeRoot: "/closed", worktrees: []
    ))
    store.addEndedSessions([(hostID: "host-a", sessionID: "n3")])
    store.flush()
    ended = try decoder.decode(EndedSessionsRecord.self, from: Data(contentsOf: store.endedSessionsFileURL))
    #expect(ended.entries.map(\.sessionID) == ["n3"])

    // A list that cannot be read fails safe: records saved before it was
    // lost count as ended on purpose; those saved after are checked again.
    try Data("{not json".utf8).write(to: store.endedSessionsFileURL)
    var before = bound
    before.savedAt = Date().addingTimeInterval(-60)
    var after = bound
    after.hosted?.sessionID = "s-after"
    after.savedAt = Date().addingTimeInterval(60)
    #expect(store.wasEndedOnPurpose(before))
    #expect(!store.wasEndedOnPurpose(after))
    // The loss is kept once the unreadable file was moved aside.
    #expect(store.wasEndedOnPurpose(before))
    #expect(try decoder.decode(EndedSessionsRecord.self, from: Data(contentsOf: store.endedSessionsFileURL)).lostBefore != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).contains { $0.hasPrefix("ended-sessions.json.unreadable-") })

    // Sessions the host reported lost are kept while a saved state names
    // them, whatever happens to the host.
    #expect(store.lostSessions(hostID: "host-a").isEmpty)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: "/closed", activeWorktreeRoot: "/closed",
        worktrees: [WorktreeStateRecord(root: "/closed", sessions: [bound])]
    ))
    store.addLostSessions(["s1", "s-gone"], hostID: "host-a")
    store.flush()
    #expect(store.lostSessions(hostID: "host-a") == ["s1", "s-gone"])
    #expect(store.lostSessions(hostID: "host-b").isEmpty)
    store.addLostSessions(["s-new"], hostID: "host-a")
    store.flush()
    #expect(store.lostSessions(hostID: "host-a") == ["s1", "s-new"])

    // A tab the system ended is saved as such, naming no session, and may
    // come back; an older build's record has none.
    var endedTab = WorkspaceSessionRecord(id: UUID(), kind: .agent, title: "Lead", agentName: "Claude", workingDirectory: "/repo")
    #expect(!endedTab.mayComeBack)
    endedTab.systemEnd = .restart
    #expect(endedTab.mayComeBack)
    #expect(!endedTab.mayOwnLocalSession)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: "/repo", activeWorktreeRoot: "/repo",
        worktrees: [WorktreeStateRecord(root: "/repo", sessions: [endedTab])]
    ))
    let loaded = try #require(store.load(repositoryRoot: "/repo")?.worktrees.first?.sessions.first)
    #expect(loaded.systemEnd == .restart)
    #expect(store.hasSavedTabs(repositoryRoot: "/repo"))
    #expect(store.load(repositoryRoot: "/repo")?.worktrees.first?.hasRestorableSessions == true)
    let older = try decoder.decode(WorkspaceSessionRecord.self, from: Data(#"{"id":"\#(UUID().uuidString)","kind":"terminal","title":"T","titleSource":"system","launchEnvironment":{},"workingDirectory":"/","restartOnExit":false}"#.utf8))
    #expect(older.systemEnd == nil)
    #expect(SystemSessionEnd.restart.message == "Ended when the Mac restarted")
    #expect(SystemSessionEnd.logout.message == "Ended when you logged out")
}

@Test func openProjectWindowListRoundTripsAndReopensOnlyWindowsWithTabs() throws {
    let directory = try makeCanonicalTemporaryDirectory("cherry-open-windows")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))
    let withTabs = directory.appendingPathComponent("with-tabs", isDirectory: true)
    let withoutState = directory.appendingPathComponent("without-state", isDirectory: true)
    let missing = directory.appendingPathComponent("missing", isDirectory: true)
    try FileManager.default.createDirectory(at: withTabs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: withoutState, withIntermediateDirectories: true)
    for root in [withTabs.path, missing.path] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: root,
            activeWorktreeRoot: root,
            worktrees: [WorktreeStateRecord(root: root, sessions: [nativeRecord(title: "Shell 1")])]
        ))
    }

    #expect(store.loadOpenProjectWindowRoots().isEmpty)
    let saved = [withTabs.path, withoutState.path, missing.path, withTabs.path]
    store.saveOpenProjectWindowRoots(saved, synchronously: true)
    #expect(store.loadOpenProjectWindowRoots() == saved)
    #expect(store.projectWindowRootsToReopen() == [withTabs.path])
}

@Test func keptTabsMergeIntoTheLiveWorktreeWithoutDuplicates() {
    let editor = hostedRecord(title: "Editor", sessionID: "s-editor")
    let logs = hostedRecord(title: "Logs", sessionID: "s-logs")
    let native = nativeRecord(title: "Shell 2")
    let server = hostedRecord(title: "Server", sessionID: "s-server")
    let splitID = UUID()
    let saved = WorktreeStateRecord(
        root: "/repo",
        sessions: [editor, logs, native, server],
        displayItems: [
            WorkspaceDisplayItemRecord(kind: .split, id: splitID),
            WorkspaceDisplayItemRecord(kind: .single, id: native.id),
            WorkspaceDisplayItemRecord(kind: .single, id: server.id)
        ],
        splitGroups: [WorkspaceSplitGroupRecord(
            id: splitID,
            paneSessionIDs: [editor.id, native.id, logs.id],
            activeSessionID: editor.id,
            widthWeights: [0.2, 0.3, 0.5]
        )],
        selectedSessionID: logs.id,
        collapsedAgentGroupIDs: [server.id, native.id]
    )

    // The editor came back; the logs and server tabs are kept for later.
    let kept = saved.restricted(to: [logs.id, server.id])
    #expect(kept.sessions == [logs, server])
    #expect(kept.splitGroups == [WorkspaceSplitGroupRecord(
        id: splitID,
        paneSessionIDs: [logs.id],
        activeSessionID: logs.id,
        widthWeights: [0.5]
    )])
    #expect(kept.displayItems == [
        WorkspaceDisplayItemRecord(kind: .split, id: splitID),
        WorkspaceDisplayItemRecord(kind: .single, id: server.id)
    ])
    #expect(kept.selectedSessionID == logs.id)
    #expect(kept.collapsedAgentGroupIDs == [server.id])

    let shell = nativeRecord(title: "Shell 1")
    let live = WorktreeStateRecord(
        root: "/repo",
        sessions: [shell, editor],
        displayItems: [
            WorkspaceDisplayItemRecord(kind: .single, id: shell.id),
            WorkspaceDisplayItemRecord(kind: .single, id: editor.id)
        ],
        selectedSessionID: shell.id
    )
    let merged = live.merging(kept: kept)
    #expect(merged.sessions == [shell, editor, logs, server])
    #expect(merged.displayItems == live.displayItems + kept.displayItems)
    #expect(merged.splitGroups == kept.splitGroups)
    // A native selection cannot come back; the saved one can.
    #expect(merged.selectedSessionID == logs.id)
    #expect(merged.collapsedAgentGroupIDs == [server.id])

    var liveOnEditor = live
    liveOnEditor.selectedSessionID = editor.id
    #expect(liveOnEditor.merging(kept: kept).selectedSessionID == editor.id)

    // A tab attached to a kept session again, or with a kept id, replaces
    // the kept record.
    var reattached = hostedRecord(title: "Logs again", sessionID: "s-logs")
    reattached.id = UUID()
    let liveWithLogs = WorktreeStateRecord(root: "/repo", sessions: [reattached, server])
    let mergedWithLogs = liveWithLogs.merging(kept: kept)
    #expect(mergedWithLogs.sessions == [reattached, server])
    #expect(mergedWithLogs.splitGroups.isEmpty)
    #expect(mergedWithLogs.displayItems.isEmpty)
}

@Test @MainActor func controlPlaneRestorerKeepsTabsItCannotReachAndDropsInvalidHosts() async throws {
    let fake = FakeControlHelper()
    fake.launchFailure = "The cherry helper is missing."
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let workspace = TerminalWorkspace(createInitialSession: false)
    let local = hostedRecord(title: "Editor", sessionID: "s-1")
    let remote = hostedRecord(title: "Logs", host: "ssh:devbox", hostID: "host-b", sessionID: "s-2")
    let invalidHost = hostedRecord(title: "Bad", host: "ssh:-oProxyCommand=x", sessionID: "s-3")
    let request = WorkspaceRestoreRequest(
        repositoryRoot: "/repo",
        worktreeRoot: "/repo",
        records: [local, remote, invalidHost],
        workspace: workspace
    )
    // This app cannot run local sessions (no helper), and the SSH host's
    // helper cannot start: nothing comes back, every valid record stays.
    let localSessions = PersistentLocalSessions(
        owner: "CherryTests",
        control: { makeFakeHostControl(fake, hostStore: hostStore) },
        installationUnavailableReason: { "The cherry helper is missing." },
        status: PersistentSessionsStatus()
    )
    let restorer = WorkspaceSessionRestorers.hostedByDefault(localSessions: localSessions, control: { host in
        makeFakeHostControl(fake, host: host, hostStore: hostStore)
    })
    let result = await restorer(request)
    #expect(result.sessions.isEmpty)
    #expect(result.keptRecordIDs == [local.id, remote.id])
    // Only a later launch can bring back the local tab: this app cannot
    // run sessions at all, so nothing to wait for during this run.
    #expect(result.retryWhenAvailable == nil)
    // The local host was never asked; the SSH host once.
    #expect(fake.launches.count == 1)
    #expect(fake.launches.first?.arguments.contains("devbox") == true)

    let none = await WorkspaceSessionRestorers.none(request)
    #expect(none.sessions.isEmpty)
    #expect(none.keptRecordIDs.isEmpty)
    #expect(workspace.sessions.isEmpty)
}

// MARK: - Identity and close intents

@Test @MainActor func terminalWorkspaceKeepsInjectedTabIDs() throws {
    let workspace = TerminalWorkspace(createInitialSession: false)
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let attachedID = UUID()
    let attached = workspace.attachHostedSession(localAttachment(sessionID: "s-1"), id: attachedID, launchShell: false)
    #expect(attached.id == attachedID)
    // Attaching the same hosted session again reuses the tab and its id.
    #expect(workspace.attachHostedSession(localAttachment(sessionID: "s-1"), launchShell: false) === attached)

    let record = hostedRecord(title: "Renamed Editor", titleSource: .explicit, sessionID: "s-2")
    let restored = workspace.makeRestoredHostedSession(localAttachment(sessionID: "s-2"), record: record, launchShell: false)
    #expect(restored.id == record.id)
    #expect(restored.title == "Renamed Editor")
    #expect(!workspace.sessions.contains { $0 === restored })
    restored.stop()

    let standalone = TerminalSession(id: attachedID, title: "Plain", subtitle: "", tint: .white, launchShell: false)
    #expect(standalone.id == attachedID)

    let changes = Counter()
    let subscription = workspace.persistentStateChanges.sink { changes.value += 1 }
    defer { subscription.cancel() }
    attached.rename(to: "Editor 2")
    attached.rename(to: nil)
    #expect(changes.value == 2)
}

@Test @MainActor func addingATabWithAnOpenIDGivesItAFreshID() {
    let workspace = TerminalWorkspace(createInitialSession: false, launchBackend: .hostManaged)
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let id = UUID()
    let first = workspace.attachHostedSession(localAttachment(sessionID: "s-1"), id: id, launchShell: false)
    let second = workspace.attachHostedSession(localAttachment(sessionID: "s-2"), id: id, launchShell: false)
    let shell = workspace.addSession(id: id, title: "Shell", select: false)
    #expect(first.id == id)
    #expect(second.id != id)
    #expect(shell.id != id)
    #expect(Set(workspace.sessions.map(\.id)).count == 3)
}

@Test @MainActor func restoredTabsKeepTheirSavedMetadataUntilClosed() throws {
    let workspace = TerminalWorkspace(createInitialSession: false)
    defer { workspace.closeAllSessions(intent: .windowClosed) }
    let editor = hostedRecord(title: "Editor", sessionID: "s-editor")
    let server = hostedRecord(title: "server", sessionID: "s-server", kind: .command, commandName: "server")
    let restored = [editor, server].map { record in
        workspace.makeRestoredHostedSession(
            localAttachment(sessionID: record.hosted?.sessionID ?? ""),
            record: record,
            launchShell: false
        )
    }
    workspace.restoreSessions(restored, from: WorktreeStateRecord(root: "/project", sessions: [editor, server]))
    #expect(workspace.sessions.map(\.id) == [editor.id, server.id])

    // A move is one change, and the moved tab keeps what it was saved as.
    var publishedOrders: [[UUID]] = []
    let subscription = workspace.$sessions.dropFirst().sink { publishedOrders.append($0.map(\.id)) }
    defer { subscription.cancel() }
    workspace.moveSession(id: server.id, to: 0)
    #expect(publishedOrders == [[server.id, editor.id]])
    #expect(workspace.restoredSession(forCommandNamed: "server")?.id == server.id)
    let saved = workspace.makeStateRecord(root: "/project", collapsedAgentGroupIDs: [])
    let savedServer = try #require(saved.sessions.first)
    #expect(savedServer.id == server.id)
    #expect(savedServer.kind == .command)
    #expect(savedServer.commandName == "server")

    // Closing the tab forgets it.
    workspace.close(try #require(workspace.session(withID: server.id)))
    #expect(workspace.restoredSessionRecords[server.id] == nil)
    #expect(workspace.restoredSessionRecords[editor.id] == editor)
}

@Test func sessionClosePolicyMatchesTodayAndTheSpecTable() {
    // Native tabs stop and remote (attached) tabs detach, whatever the
    // intent; local persistent tabs follow their intent, unless a policy
    // turns that off, when they detach too.
    #expect(SessionClosePolicy.hostedLocalTabsFollowSettings)
    for intent in SessionCloseIntent.allCases {
        #expect(SessionClosePolicy.closeAction(for: .native, intent: intent) == .stop)
        #expect(SessionClosePolicy.closeAction(for: .hostedRemote, intent: intent) == .detach)
        #expect(SessionClosePolicy.closeAction(for: .hostedLocal, intent: intent)
            == SessionClosePolicy.hostedLocalAction(for: intent))
        #expect(SessionClosePolicy.closeAction(
            for: .hostedLocal, intent: intent, hostedLocalTabsFollowSettings: false
        ) == .detach)
        #expect(SessionClosePolicy.closeAction(
            for: .native, intent: intent, hostedLocalTabsFollowSettings: false
        ) == .stop)
    }

    // The spec's local hosted column. A tab close ends its session and a
    // detach keeps it; a window close or quit carries its answer (or the
    // quit preference) in its intent.
    func local(_ intent: SessionCloseIntent) -> SessionCloseAction {
        SessionClosePolicy.closeAction(for: .hostedLocal, intent: intent, hostedLocalTabsFollowSettings: true)
    }
    #expect(local(.userClosedTab) == .terminate)
    #expect(local(.userDetachedTab) == .detach)
    #expect(local(.mcpClose) == .terminate)
    #expect(local(.windowClosed) == .detach)
    #expect(local(.appQuit) == .detach)
    #expect(local(.windowClosedEndingSessions) == .terminate)
    #expect(local(.appQuitEndingSessions) == .terminate)
    #expect(local(.duplicateWindowTeardown) == .detach)
    #expect(local(.worktreeRemoved) == .terminate)
    #expect(local(.restart) == .terminate)
    #expect(local(.programExited) == .terminate)

    #expect(Set(SessionCloseIntent.allCases.filter(\.tearsDownWorkspace))
        == [.windowClosed, .windowClosedEndingSessions, .appQuit, .appQuitEndingSessions, .duplicateWindowTeardown])
    #expect(Set(SessionCloseIntent.allCases.filter(\.isAppQuit)) == [.appQuit, .appQuitEndingSessions])
    #expect(SessionTeardown.windowClose.intent(endingSessions: false) == .windowClosed)
    #expect(SessionTeardown.windowClose.intent(endingSessions: true) == .windowClosedEndingSessions)
    #expect(SessionTeardown.quit.intent(endingSessions: false) == .appQuit)
    #expect(SessionTeardown.quit.intent(endingSessions: true) == .appQuitEndingSessions)
}

@Test @MainActor func closePathsNameTheirIntentAndApplyTheCloseAction() throws {
    let terminatedBox = Box<[(String, SessionCloseIntent)]>([])
    let settingsBox = Box(SessionPersistenceSettings.defaults)
    let policy = SessionBackendPolicy(
        settings: { settingsBox.value },
        hostedLocalTabsFollowSettings: true,
        terminateHostedSession: { session, intent in
            terminatedBox.value.append((session.hostedAttachment?.sessionID ?? "native", intent))
        }
    )
    var terminated: [(String, SessionCloseIntent)] { terminatedBox.value }
    let workspace = TerminalWorkspace(createInitialSession: false, backendPolicy: policy)
    let first = workspace.attachHostedSession(localAttachment(sessionID: "local-1"), launchShell: false)
    let second = workspace.attachHostedSession(localAttachment(sessionID: "local-2"), launchShell: false)
    let remote = workspace.attachHostedSession(try remoteAttachment(sessionID: "remote-1"), launchShell: false)
    _ = workspace.attachHostedSession(localAttachment(sessionID: "local-3"), launchShell: false)

    #expect(SessionCloseBackend(first) == .hostedLocal)
    #expect(SessionCloseBackend(remote) == .hostedRemote)
    #expect(SessionCloseBackend(TerminalSession(title: "Plain", subtitle: "", tint: .white, launchShell: false)) == .native)

    workspace.close(first)
    #expect(terminated.map(\.0) == ["local-1"])
    #expect(terminated.map(\.1) == [.userClosedTab])

    workspace.close(remote, intent: .mcpClose)
    #expect(terminated.count == 1)

    // A tab attached to a session it does not own only disconnects, even
    // when detached.
    workspace.close(second, intent: .userDetachedTab)
    #expect(terminated.count == 1)

    // Quitting keeps local sessions unless its answer (or the setting)
    // ends them, which its intent says.
    settingsBox.value.localSessionsOnQuit = .end
    workspace.closeAllSessions(intent: .appQuit)
    #expect(terminated.count == 1)
    #expect(workspace.isTornDown)
    #expect(workspace.sessions.isEmpty)

    let quitting = TerminalWorkspace(createInitialSession: false, backendPolicy: policy)
    _ = quitting.attachHostedSession(localAttachment(sessionID: "local-4"), launchShell: false)
    quitting.closeAllSessions(intent: .appQuitEndingSessions)
    #expect(terminated.map(\.0) == ["local-1", "local-4"])
    #expect(terminated.last?.1 == .appQuitEndingSessions)
    #expect(quitting.isTornDown)

    // A workspace with the default policy never terminates anything.
    let native = TerminalWorkspace(createInitialSession: false)
    _ = native.attachHostedSession(localAttachment(sessionID: "local-5"), launchShell: false)
    native.closeAllSessions(intent: .worktreeRemoved)
    #expect(!native.isTornDown)
    #expect(terminated.count == 2)

    // A tab closing because its shell exited ends its session.
    let exiting = TerminalWorkspace(createInitialSession: false, backendPolicy: policy)
    _ = exiting.attachHostedSession(localAttachment(sessionID: "local-6"), launchShell: false)
    let exited = exiting.attachHostedSession(localAttachment(sessionID: "local-7"), launchShell: false)
    exiting.close(exited, intent: .programExited)
    #expect(terminated.map(\.0) == ["local-1", "local-4", "local-7"])
    #expect(terminated.last?.1 == .programExited)
    #expect(exiting.sessions.count == 1)
    #expect(!exiting.isTornDown)
}

// MARK: - Settings

@Test @MainActor func sessionSettingsPersistWithoutRebuildingTheTerminal() throws {
    let suite = "CherryTests.SessionSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = TerminalSettings(defaults: defaults)
    #expect(settings.persistLocalSessions)
    #expect(settings.localSessionsOnQuit == .ask)
    #expect(settings.closeTabsOnCleanExit)
    #expect(settings.sessionPersistenceSettings == .defaults)
    #expect(!SessionPersistenceSettings.native.closeTabsOnCleanExit)

    let revision = settings.terminalAppearanceRevision
    let notifications = Counter()
    let observer = NotificationCenter.default.addObserver(
        forName: .terminalSettingsDidChange,
        object: settings,
        queue: nil
    ) { _ in notifications.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    settings.persistLocalSessions = false
    settings.localSessionsOnQuit = .end
    settings.closeTabsOnCleanExit = false

    #expect(settings.terminalAppearanceRevision == revision)
    #expect(notifications.value == 0)
    #expect(defaults.object(forKey: "sessions.persistLocal") as? Bool == false)
    #expect(defaults.object(forKey: "sessions.onQuit") as? String == "end")
    #expect(defaults.object(forKey: "sessions.closeTabOnExit") as? Bool == false)

    // Not part of the terminal appearance.
    settings.resetTerminalAppearance()
    #expect(!settings.persistLocalSessions)
    #expect(settings.localSessionsOnQuit == .end)
    #expect(!settings.closeTabsOnCleanExit)

    let reloaded = TerminalSettings(defaults: defaults)
    #expect(reloaded.sessionPersistenceSettings == SessionPersistenceSettings(
        persistLocalSessions: false,
        localSessionsOnQuit: .end,
        closeTabsOnCleanExit: false
    ))
    // A string key, as a launch argument sets it (`-sessions.onQuit keep`);
    // anything else asks.
    defaults.set("keep", forKey: "sessions.onQuit")
    #expect(TerminalSettings(defaults: defaults).localSessionsOnQuit == .keep)
    defaults.set("sometimes", forKey: "sessions.onQuit")
    #expect(TerminalSettings(defaults: defaults).localSessionsOnQuit == .ask)
    #expect(LocalSessionsOnQuit.allCases.map(\.label) == ["Ask", "Keep Running", "End Sessions"])
    #expect(!SessionBackendPolicy(settings: { reloaded.sessionPersistenceSettings }).prefersPersistentLocalSessions)
    #expect(!SessionBackendPolicy.native.prefersPersistentLocalSessions)
    #expect(SettingsPage.filtered(by: "quitting") == [.sessions])
    // Close a tab when its shell exits.
    for query in ["exit", "shell", "close"] {
        #expect(SettingsPage.filtered(by: query) == [.sessions], Comment(rawValue: query))
    }
    #expect(SettingsPage.sessions.title == "Sessions")
}

// MARK: - Restore

@Test @MainActor func repositoryRestoresHostedRecordsWithTheirIDsAndLayout() async throws {
    let root = try makeCanonicalTemporaryDirectory("cherry-restore")
    let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-restore-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = hostedRecord(title: "Editor", sessionID: "s-editor")
    let logs = hostedRecord(title: "Logs", host: "ssh:devbox", hostID: "host-b", sessionID: "s-logs")
    let native = nativeRecord(title: "Shell 2")
    let server = hostedRecord(title: "server", titleSource: .system, sessionID: "s-server", kind: .command, commandName: "server")
    let agent = hostedRecord(title: "Claude", sessionID: "s-agent", kind: .agent)
    let nativeAgent = nativeRecord(title: "Codex", kind: .agent)
    let splitID = UUID()
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(
            root: root.path,
            sessions: [editor, logs, native, server, agent, nativeAgent],
            displayItems: [
                WorkspaceDisplayItemRecord(kind: .split, id: splitID),
                WorkspaceDisplayItemRecord(kind: .single, id: server.id)
            ],
            splitGroups: [WorkspaceSplitGroupRecord(
                id: splitID,
                paneSessionIDs: [editor.id, native.id, logs.id],
                activeSessionID: native.id,
                widthWeights: [0.5, 0.25, 0.25]
            )],
            selectedSessionID: logs.id,
            collapsedAgentGroupIDs: [agent.id, nativeAgent.id]
        )]
    ))

    let fake = FakeHostedRestorer()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: fake.restorer,
        autoStartCommands: { _ in [] }
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    let workspace = repository.activeWorkspace
    // A saved hosted tab replaces the default shell.
    #expect(workspace.sessions.isEmpty)
    #expect(fake.requestedRecordIDs.isEmpty)

    let chromeState = ProjectWindowChromeState()
    repository.beginRestoringSavedStateIfNeeded(chromeState: chromeState)
    await repository.waitForPendingRestores()

    // Only hosted records reach the restorer; native ones are dropped.
    #expect(fake.requestedRecordIDs == [[editor.id, logs.id, server.id, agent.id]])
    #expect(workspace.sessions.map(\.id) == [editor.id, logs.id, server.id, agent.id])
    #expect(workspace.sessions.map(\.title) == ["Editor", "Logs", "server", "Claude"])
    #expect(workspace.sessions.first { $0.id == server.id }?.titleSource == .system)
    #expect(workspace.terminalSplitGroups.count == 1)
    let group = try #require(workspace.terminalSplitGroups.first)
    #expect(group.id == splitID)
    #expect(group.paneSessionIDs == [editor.id, logs.id])
    // Selecting the saved tab makes it its split's active pane.
    #expect(group.activeSessionID == logs.id)
    #expect(abs(group.widthWeights[0] - 2.0 / 3.0) < 0.0001)
    // Restored attached tabs keep their kind: the command and the agent
    // are no terminal display items.
    #expect(workspace.terminalDisplayItems == [.split(splitID)])
    #expect(workspace.sessions.first { $0.id == server.id }?.kind == .command)
    #expect(workspace.commandSession(named: "server")?.id == server.id)
    #expect(workspace.sessions.first { $0.id == agent.id }?.kind == .agent)
    #expect(workspace.selectedSessionID == logs.id)
    #expect(chromeState.collapsedAgentGroupIDs == [agent.id])

    // Saving again keeps their metadata.
    repository.flushPersistentState()
    let saved = try #require(store.load(repositoryRoot: repositoryKey(root))?.worktree(root: root.path))
    #expect(saved.sessions.map(\.id) == [editor.id, logs.id, server.id, agent.id])
    let savedServer = try #require(saved.sessions.first { $0.id == server.id })
    #expect(savedServer.kind == .command)
    #expect(savedServer.commandName == "server")
    #expect(savedServer.launchCommand == "run-server")
    #expect(savedServer.launchEnvironment == ["PORT": "8000"])
    #expect(savedServer.restartOnExit)
    // Restored attached (this restorer attaches), so saved as not owning
    // the session; otherwise the same binding.
    var attachedBinding = server.hosted
    attachedBinding?.owned = false
    #expect(savedServer.hosted == attachedBinding)
    #expect(saved.sessions.first { $0.id == agent.id }?.kind == .agent)
    #expect(saved.selectedSessionID == logs.id)
    #expect(saved.collapsedAgentGroupIDs == [agent.id])
    #expect(saved.splitGroups.map(\.paneSessionIDs) == [[editor.id, logs.id]])

    // A second restore of the same hosted session is dropped.
    let duplicate = workspace.makeRestoredHostedSession(
        localAttachment(sessionID: "s-editor"),
        record: hostedRecord(title: "Again", sessionID: "s-editor"),
        launchShell: false
    )
    workspace.restoreSessions([duplicate], from: WorktreeStateRecord(root: root.path, sessions: []))
    #expect(workspace.sessions.count == 4)
}

@Test @MainActor func repositoryOpensTheDefaultShellWhenNothingIsRestored() async throws {
    let root = try makeCanonicalTemporaryDirectory("cherry-restore-empty")
    let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-restore-empty-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [
            nativeRecord(title: "Shell 1"),
            hostedRecord(title: "Gone", sessionID: "s-gone")
        ])]
    ))
    let fake = FakeHostedRestorer()
    fake.restoresNothing = true
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: fake.restorer,
        autoStartCommands: { _ in [] }
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    #expect(repository.activeWorkspace.sessions.isEmpty)

    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()

    #expect(fake.requestedRecordIDs.count == 1)
    #expect(repository.activeWorkspace.sessions.map(\.title) == ["Shell 1"])
    #expect(repository.activeWorkspace.sessions.first?.hostedAttachment == nil)
    #expect(repository.activeWorkspace.selectedSessionID == repository.activeWorkspace.sessions.first?.id)

    // Only native tabs saved: nothing can come back, so the window opens its
    // default shell at once and the restorer is never asked.
    let nativeOnlyRoot = try makeCanonicalTemporaryDirectory("cherry-restore-native")
    defer { try? FileManager.default.removeItem(at: nativeOnlyRoot) }
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(nativeOnlyRoot),
        activeWorktreeRoot: nativeOnlyRoot.path,
        worktrees: [WorktreeStateRecord(root: nativeOnlyRoot.path, sessions: [nativeRecord(title: "Shell 1")])]
    ))
    let nativeFake = FakeHostedRestorer()
    let nativeRepository = RepositoryWorkspace(
        projectRoot: nativeOnlyRoot.path,
        stateStore: store,
        sessionRestorer: nativeFake.restorer,
        autoStartCommands: { _ in [] }
    )
    defer { nativeRepository.closeAllSessions(intent: .windowClosed) }
    #expect(nativeRepository.activeWorkspace.sessions.count == 1)
    nativeRepository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await nativeRepository.waitForPendingRestores()
    #expect(nativeFake.requestedRecordIDs.isEmpty)
    #expect(nativeRepository.activeWorkspace.sessions.count == 1)
}

@Test @MainActor func autoStartWaitsForTheRestoreAndSkipsRestoredCommands() async throws {
    let root = try makeCanonicalTemporaryDirectory("cherry-restore-autostart")
    let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-restore-autostart-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let server = hostedRecord(title: "Server", titleSource: .system, sessionID: "s-server", kind: .command, commandName: "Server")
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [server])]
    ))
    let gate = RestoreGate()
    let fake = FakeHostedRestorer()
    fake.gate = gate
    let autoStartRequestsBox = Box<[String]>([])
    var autoStartRequests: [String] { autoStartRequestsBox.value }
    let command = ProjectCommandDefinition(name: "server", command: "sleep 30", autoStart: true)
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: fake.restorer,
        autoStartCommands: { root in
            autoStartRequestsBox.value.append(root)
            return [command]
        }
    )
    defer {
        gate.open()
        repository.closeAllSessions(intent: .windowClosed)
    }
    let workspace = repository.activeWorkspace

    // The window appears before it claimed its project: nothing starts.
    repository.autoStartInitialCommandsIfNeeded()
    #expect(autoStartRequests.isEmpty)

    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    for _ in 0..<100 where !gate.isWaiting {
        await Task.yield()
    }
    #expect(gate.isWaiting)
    repository.autoStartInitialCommandsIfNeeded()
    #expect(autoStartRequests.isEmpty)
    #expect(workspace.sessions.isEmpty)

    gate.open()
    await repository.waitForPendingRestores()

    // Auto-start ran once, after the restore, and found the restored tab
    // (a command tab again).
    #expect(autoStartRequests.count == 1)
    #expect(workspace.sessions.map(\.id) == [server.id])
    #expect(workspace.commandSessions.map(\.id) == [server.id])
    #expect(workspace.addCommandSession(command: command, projectRoot: root.path, select: false).id == server.id)
    #expect(workspace.sessions.count == 1)
}

@Test @MainActor func repositoryKeepsSavedTabsItCannotRestoreYet() async throws {
    let root = try makeCanonicalTemporaryDirectory("cherry-restore-kept")
    let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-restore-kept-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let editor = hostedRecord(title: "Editor", sessionID: "s-editor")
    let logs = hostedRecord(title: "Logs", sessionID: "s-logs")
    let splitID = UUID()
    let savedWorktree = WorktreeStateRecord(
        root: root.path,
        sessions: [editor, nativeRecord(title: "Shell 2"), logs],
        displayItems: [WorkspaceDisplayItemRecord(kind: .split, id: splitID)],
        splitGroups: [WorkspaceSplitGroupRecord(
            id: splitID,
            paneSessionIDs: [editor.id, logs.id],
            activeSessionID: editor.id,
            widthWeights: [0.25, 0.75]
        )],
        selectedSessionID: logs.id
    )
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [savedWorktree]
    ))

    // The helper is unavailable: nothing comes back, the window opens its
    // default shell, and the hosted tabs stay saved with their layout.
    let unavailable = FakeHostedRestorer()
    unavailable.keepsEverything = true
    let first = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: unavailable.restorer,
        autoStartCommands: { _ in [] }
    )
    first.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await first.waitForPendingRestores()
    #expect(unavailable.requestedRecordIDs == [[editor.id, logs.id]])
    let shell = try #require(first.activeWorkspace.sessions.first)
    #expect(first.activeWorkspace.sessions.map(\.title) == ["Shell 1"])
    first.flushPersistentState()
    let kept = try #require(store.load(repositoryRoot: repositoryKey(root))?.worktree(root: root.path))
    #expect(kept.sessions.map(\.id) == [shell.id, editor.id, logs.id])
    #expect(Array(kept.sessions.dropFirst()) == [editor, logs])
    #expect(kept.splitGroups == savedWorktree.splitGroups)
    #expect(kept.selectedSessionID == logs.id)
    first.closeAllSessions(intent: .windowClosed)

    // The next launch can attach: the tabs come back as they were.
    let available = FakeHostedRestorer()
    let second = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: available.restorer,
        autoStartCommands: { _ in [] }
    )
    defer { second.closeAllSessions(intent: .windowClosed) }
    second.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await second.waitForPendingRestores()
    #expect(available.requestedRecordIDs == [[editor.id, logs.id]])
    #expect(second.activeWorkspace.sessions.map(\.id) == [editor.id, logs.id])
    #expect(second.activeWorkspace.terminalSplitGroups.map(\.id) == [splitID])
    #expect(second.activeWorkspace.selectedSessionID == logs.id)
}

@Test @MainActor func restoreFinishingAfterTheWindowClosedEndsTabsWithThatIntent() async throws {
    // Cherry quits while the restore runs; the tab it then builds ends as
    // the quit ends tabs: its session ends when the quit ends sessions (End
    // Sessions), and is kept, as its saved record, when it keeps them.
    for (intent, ends) in [(SessionCloseIntent.appQuitEndingSessions, true), (.appQuit, false)] {
        let label = Comment(rawValue: "\(intent)")
        let root = try makeCanonicalTemporaryDirectory("cherry-restore-abandoned")
        let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-restore-abandoned-store")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        let store = WorkspaceStateStore(directory: storeDirectory)
        let editor = hostedRecord(title: "Editor", sessionID: "s-editor")
        let recorder = RecordingBackendPolicy()
        let gate = RestoreGate()
        let fake = FakeHostedRestorer()
        fake.gate = gate
        let repository = makeRestoringRepository(
            root: root,
            records: [editor],
            store: store,
            restorer: fake,
            backendPolicy: recorder.policy
        )
        defer { gate.open() }
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        for _ in 0..<100 where !gate.isWaiting {
            await Task.yield()
        }
        #expect(gate.isWaiting, label)

        repository.closeAllSessions(intent: intent)
        gate.open()
        await repository.waitForPendingRestores()
        #expect(repository.activeWorkspace.sessions.isEmpty, label)
        #expect(repository.activeWorkspace.closeAllIntent == intent, label)
        #expect(recorder.terminated.map(\.sessionID) == (ends ? ["s-editor"] : []), label)
        #expect(recorder.terminated.map(\.intent) == (ends ? [intent] : []), label)
        store.flush()
        #expect(savedSessionIDs(store.load(repositoryRoot: repositoryKey(root)), root: root.path) == [editor.id], label)
    }
}

@Test @MainActor func worktreesRestoreOnDiscoveryAndRemovalEndsTheirTabs() async throws {
    let container = try makeCanonicalTemporaryDirectory("cherry-restore-worktrees")
    defer { try? FileManager.default.removeItem(at: container) }
    let root = container.appendingPathComponent("repo", isDirectory: true)
    let feature = container.appendingPathComponent("feature", isDirectory: true)
    let gone = container.appendingPathComponent("gone", isDirectory: true)
    let storeDirectory = container.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["-C", root.path, "init", "-b", "main"])
    try runGit(["-C", root.path, "-c", "user.name=Cherry Tests", "-c", "user.email=cherry@example.invalid",
                "commit", "--allow-empty", "-m", "Initial"])
    try runGit(["-C", root.path, "worktree", "add", "-b", "feature", feature.path])
    let settings = TerminalSettings.shared
    let previousWorktreeSpacesEnabled = settings.worktreeSpacesEnabled
    settings.worktreeSpacesEnabled = true
    defer { settings.worktreeSpacesEnabled = previousWorktreeSpacesEnabled }

    let store = WorkspaceStateStore(directory: storeDirectory)
    let main = hostedRecord(title: "Main", sessionID: "s-main")
    let featureTab = hostedRecord(title: "Feature", sessionID: "s-feature")
    let goneTab = hostedRecord(title: "Gone", sessionID: "s-gone")
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [
            WorktreeStateRecord(root: root.path, sessions: [main]),
            WorktreeStateRecord(root: feature.path, sessions: [featureTab]),
            WorktreeStateRecord(root: gone.path, sessions: [goneTab])
        ]
    ))
    let recorder = RecordingBackendPolicy()
    let fake = FakeHostedRestorer()
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        backendPolicy: recorder.policy,
        stateStore: store,
        sessionRestorer: fake.restorer,
        autoStartCommands: { _ in [] }
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }

    // At first the window knows only its own worktree.
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    #expect(fake.requestedRecordIDs == [[main.id]])
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repositoryKey(root))?.worktrees.map(\.root) == [feature.path, gone.path, root.path])

    // Discovery restores the linked worktree and forgets the missing one.
    await repository.refresh()
    await repository.waitForPendingRestores()
    #expect(fake.requestedRecordIDs == [[main.id], [featureTab.id]])
    let featureWorkspace = try #require(repository.workspaceIfLoaded(for: feature.path))
    #expect(featureWorkspace.sessions.map(\.id) == [featureTab.id])
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repositoryKey(root))?.worktrees.map(\.root) == [feature.path, root.path])

    // Removing the worktree ends its tabs as a worktree removal.
    let featureWorktree = try #require(repository.worktrees.first { $0.root == feature.path })
    try await repository.remove(featureWorktree, force: true, chromeState: nil)
    #expect(recorder.terminated.map(\.sessionID) == ["s-feature"])
    #expect(recorder.terminated.map(\.intent) == [.worktreeRemoved])
    repository.flushPersistentState()
    #expect(store.load(repositoryRoot: repositoryKey(root))?.worktrees.map(\.root) == [root.path])
}

// MARK: - Saving

@Test @MainActor func repositoryNeverSavesBeforeClaimingItsWindowOrDuringTeardown() async throws {
    let root = try makeCanonicalTemporaryDirectory("cherry-save-teardown")
    let storeDirectory = try makeCanonicalTemporaryDirectory("cherry-save-teardown-store")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
    let store = WorkspaceStateStore(directory: storeDirectory)
    let saved = hostedRecord(title: "Saved", sessionID: "s-saved")
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: repositoryKey(root),
        activeWorktreeRoot: root.path,
        worktrees: [WorktreeStateRecord(root: root.path, sessions: [saved])]
    ))
    let repository = RepositoryWorkspace(
        projectRoot: root.path,
        stateStore: store,
        sessionRestorer: FakeHostedRestorer().restorer,
        autoStartCommands: { _ in [] }
    )
    let workspace = repository.activeWorkspace

    // Until the window claims the project (a duplicate never does), nothing
    // is written, not even a flush.
    let early = workspace.attachHostedSession(localAttachment(sessionID: "s-early"), launchShell: false)
    repository.flushPersistentState()
    #expect(savedSessionIDs(store.load(repositoryRoot: repositoryKey(root)), root: root.path) == [saved.id])

    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    #expect(workspace.sessions.map(\.id) == [saved.id, early.id])
    let afterRestore = await waitForSavedState(in: store, repositoryRoot: repositoryKey(root)) {
        savedSessionIDs($0, root: root.path) == [saved.id, early.id]
    }
    #expect(afterRestore != nil)

    // A rename is saved on its own, debounced.
    early.rename(to: "Renamed")
    let renamed = await waitForSavedState(in: store, repositoryRoot: repositoryKey(root)) {
        $0.worktree(root: root.path)?.sessions.last?.title == "Renamed"
    }
    #expect(renamed != nil)

    // A change right before a window teardown is not flushed, and the
    // teardown never writes the emptied workspace.
    let late = workspace.attachHostedSession(localAttachment(sessionID: "s-late"), launchShell: false)
    repository.closeAllSessions(intent: .windowClosed)
    #expect(repository.isTearingDown)
    #expect(workspace.sessions.isEmpty)
    try await Task.sleep(for: .milliseconds(800))
    repository.flushPersistentState()
    store.flush()
    let final = store.load(repositoryRoot: repositoryKey(root))
    #expect(savedSessionIDs(final, root: root.path) == [saved.id, early.id])
    #expect(!savedSessionIDs(final, root: root.path).contains(late.id))
}


/// The MCP test registers a window with the shared registry; the others use
/// their own registry. Run them one at a time all the same.
@Suite(.serialized)
@MainActor
struct WorkspaceRegistryPersistenceTests {
    @Test func confirmedQuitSavesWhatChangedWhileTheAlertWasUp() async throws {
        let container = try makeCanonicalTemporaryDirectory("cherry-quit-flush")
        defer { try? FileManager.default.removeItem(at: container) }
        let rootA = container.appendingPathComponent("a", isDirectory: true)
        let rootB = container.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let store = WorkspaceStateStore(directory: container.appendingPathComponent("store", isDirectory: true))
        let savedA = hostedRecord(title: "A", sessionID: "s-a")
        let savedB = hostedRecord(title: "B", sessionID: "s-b")
        let repositoryA = makeRestoringRepository(root: rootA, records: [savedA], store: store, restorer: FakeHostedRestorer())
        let repositoryB = makeRestoringRepository(root: rootB, records: [savedB], store: store, restorer: FakeHostedRestorer())
        let registry = ProjectWindowRegistry()
        registry.setWorkspaceStateStoreForTesting(store)
        let windowA = makeTestWindow()
        let windowB = makeTestWindow()
        defer {
            registry.cancelTermination()
            registry.unregister(window: windowA, projectRoot: rootA.path)
            registry.unregister(window: windowB, projectRoot: rootB.path)
            repositoryA.closeAllSessions(intent: .windowClosed)
            repositoryB.closeAllSessions(intent: .windowClosed)
            windowA.close()
            windowB.close()
        }
        for (window, root, repository) in [(windowA, rootA, repositoryA), (windowB, rootB, repositoryB)] {
            #expect(registry.register(
                window: window,
                projectRoot: root.path,
                workspace: repository.activeWorkspace,
                repository: repository,
                noteStore: nil,
                todoStore: nil,
                chromeState: nil
            ))
            repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
            await repository.waitForPendingRestores()
        }
        let bothWindows = [repositoryKey(rootA), repositoryKey(rootB)].sorted()

        // Quit asks first; the save before the alert freezes nothing.
        let early = repositoryA.activeWorkspace.attachHostedSession(localAttachment(sessionID: "s-early"), launchShell: false)
        registry.flushWorkspacePersistence()
        #expect(savedSessionIDs(store.load(repositoryRoot: repositoryKey(rootA)), root: rootA.path) == [savedA.id, early.id])
        #expect(store.loadOpenProjectWindowRoots() == bothWindows)

        // While the alert is up, window B closes (as its close delegate
        // does) and window A opens a tab.
        repositoryB.flushPersistentState()
        repositoryB.closeAllSessions(intent: .windowClosed)
        registry.unregister(window: windowB, projectRoot: rootB.path)
        store.flush()
        #expect(store.loadOpenProjectWindowRoots() == [repositoryKey(rootA)])
        let late = repositoryA.activeWorkspace.attachHostedSession(localAttachment(sessionID: "s-late"), launchShell: false)

        // Quit confirmed: the change still inside the save debounce is saved
        // before every tab closes, and nothing is saved after.
        registry.tearDownForQuit()
        #expect(repositoryA.isTearingDown)
        #expect(repositoryA.activeWorkspace.sessions.isEmpty)
        #expect(repositoryA.activeWorkspace.closeAllIntent == .appQuit)
        try await Task.sleep(for: .milliseconds(800))
        store.flush()
        #expect(savedSessionIDs(store.load(repositoryRoot: repositoryKey(rootA)), root: rootA.path)
            == [savedA.id, early.id, late.id])
        #expect(savedSessionIDs(store.load(repositoryRoot: repositoryKey(rootB)), root: rootB.path) == [savedB.id])

        // Windows closing while the app terminates stay in the list.
        registry.unregister(window: windowA, projectRoot: rootA.path)
        store.flush()
        #expect(store.loadOpenProjectWindowRoots() == [repositoryKey(rootA)])

        // A cancelled quit saves window changes again.
        registry.cancelTermination()
        #expect(registry.register(
            window: windowA,
            projectRoot: rootA.path,
            workspace: repositoryA.activeWorkspace,
            repository: repositoryA,
            noteStore: nil,
            todoStore: nil,
            chromeState: nil
        ))
        registry.unregister(window: windowA, projectRoot: rootA.path)
        store.flush()
        #expect(store.loadOpenProjectWindowRoots().isEmpty)
    }

    @Test func savedWindowsReopenOnceAndSkipOpenOnes() throws {
        let directory = try makeCanonicalTemporaryDirectory("cherry-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))
        let projects = ["open", "closed", "empty"].map { directory.appendingPathComponent($0, isDirectory: true) }
        for project in projects {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        for project in projects.prefix(2) {
            store.saveSynchronously(RepositoryStateRecord(
                repositoryRoot: project.path,
                activeWorktreeRoot: project.path,
                worktrees: [WorktreeStateRecord(root: project.path, sessions: [nativeRecord(title: "Shell 1")])]
            ))
        }
        store.saveOpenProjectWindowRoots(projects.map(\.path), synchronously: true)

        let registry = ProjectWindowRegistry()
        registry.configureWorkspacePersistence(store: store)
        #expect(registry.workspaceStateStore === store)
        // SwiftUI restored the first window already.
        let window = makeTestWindow()
        let workspace = TerminalWorkspace(projectRoot: projects[0].path, createInitialSession: false)
        defer {
            registry.unregister(window: window, projectRoot: projects[0].path)
            window.close()
        }
        #expect(registry.register(
            window: window,
            projectRoot: projects[0].path,
            workspace: workspace,
            noteStore: nil,
            todoStore: nil,
            chromeState: nil
        ))

        // The project without saved tabs does not come back.
        #expect(registry.launchWindowPlan(hasVisibleWindow: true) == .reopen([projects[1].path]))
        // Once: the open window is all there is to show now.
        #expect(registry.launchWindowPlan(hasVisibleWindow: true) == .nothing)
        #expect(registry.takeProjectWindowRootsToReopen().isEmpty)
    }

    /// Project windows are not restorable by AppKit, so relaunching the app
    /// (quit and open, or macOS reopening it after a restart) brings them
    /// back from the app's own list alone: a new run reads what the last one
    /// saved as its windows closed at quit.
    @Test func windowsOpenAtQuitReopenAtTheNextLaunchWithoutAppKit() throws {
        let directory = try makeCanonicalTemporaryDirectory("cherry-relaunch-windows")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))
        let projects = ["a", "b"].map { directory.appendingPathComponent($0, isDirectory: true) }
        for project in projects {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            store.saveSynchronously(RepositoryStateRecord(
                repositoryRoot: project.path,
                activeWorktreeRoot: project.path,
                worktrees: [WorktreeStateRecord(root: project.path, sessions: [nativeRecord(title: "Shell 1")])]
            ))
        }

        // The last run: both windows open, then the app quits.
        let lastRun = ProjectWindowRegistry()
        lastRun.setWorkspaceStateStoreForTesting(store)
        var windows: [NSWindow] = []
        // The registry holds its workspaces weakly, as their windows do.
        var workspaces: [TerminalWorkspace] = []
        for project in projects {
            let window = makeTestWindow()
            windows.append(window)
            let workspace = TerminalWorkspace(projectRoot: project.path, createInitialSession: false)
            workspaces.append(workspace)
            #expect(window.isRestorable)
            #expect(lastRun.register(
                window: window,
                projectRoot: project.path,
                workspace: workspace,
                noteStore: nil,
                todoStore: nil,
                chromeState: nil
            ))
            // AppKit neither saves nor restores it.
            #expect(!window.isRestorable)
        }
        lastRun.prepareForTermination()
        for (window, project) in zip(windows, projects) {
            lastRun.unregister(window: window, projectRoot: project.path)
            window.close()
        }
        store.flush()
        workspaces.removeAll()

        // The next run, however the app was launched: no window was restored.
        let nextRun = ProjectWindowRegistry()
        nextRun.configureWorkspacePersistence(store: store)
        #expect(nextRun.launchWindowPlan(hasVisibleWindow: false) == .reopen(projects.map(\.path)))
    }

    @Test func launchOpensTheDefaultWindowOnlyWhenNothingElseOpens() throws {
        let directory = try makeCanonicalTemporaryDirectory("cherry-default-window")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStateStore(directory: directory.appendingPathComponent("Workspaces", isDirectory: true))

        // Nothing saved, nothing open.
        let registry = ProjectWindowRegistry()
        registry.configureWorkspacePersistence(store: store)
        #expect(registry.launchWindowPlan(hasVisibleWindow: false) == .openDefault)
        // A deep link opened a window before the plan ran.
        #expect(registry.launchWindowPlan(hasVisibleWindow: true) == .nothing)
        let project = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let window = makeTestWindow()
        let workspace = TerminalWorkspace(projectRoot: project.path, createInitialSession: false)
        defer {
            registry.unregister(window: window, projectRoot: project.path)
            window.close()
        }
        #expect(registry.register(
            window: window,
            projectRoot: project.path,
            workspace: workspace,
            noteStore: nil,
            todoStore: nil,
            chromeState: nil
        ))
        #expect(registry.launchWindowPlan(hasVisibleWindow: false) == .nothing)
    }

    /// A second copy of the app (another holds the instance lock) reopens
    /// none of the first copy's windows: it opens the default one.
    @Test func aSecondCopyOpensOnlyTheDefaultWindow() throws {
        let directory = try makeCanonicalTemporaryDirectory("cherry-second-copy-windows")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let owner = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
        defer { owner.release() }
        let other = AppInstanceLock(fileURL: lockURL, applicationSupportName: "CherryTests")
        let storeDirectory = directory.appendingPathComponent("Workspaces", isDirectory: true)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let ownerStore = WorkspaceStateStore(directory: storeDirectory, instanceLock: owner)
        ownerStore.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: project.path,
            activeWorktreeRoot: project.path,
            worktrees: [WorktreeStateRecord(root: project.path, sessions: [nativeRecord(title: "Shell 1")])]
        ))
        ownerStore.saveOpenProjectWindowRoots([project.path], synchronously: true)

        let registry = ProjectWindowRegistry()
        registry.configureWorkspacePersistence(store: WorkspaceStateStore(directory: storeDirectory, instanceLock: other))
        #expect(registry.launchWindowPlan(hasVisibleWindow: false) == .openDefault)
    }

    @Test func sidebarWidthIsSavedPerProject() throws {
        let suite = "CherryTests.SidebarWidth.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectSidebarWidthStore(defaults: defaults)

        #expect(store.width(projectRoot: "/a") == ProjectSidebarWidthStore.defaultWidth)
        store.setWidth(412, projectRoot: "/a")
        store.setWidth(280, projectRoot: "/b.with.dots")
        #expect(store.width(projectRoot: "/a") == 412)
        #expect(store.width(projectRoot: "/b.with.dots") == 280)
        #expect(ProjectSidebarWidthStore(defaults: defaults).width(projectRoot: "/a") == 412)
        #expect(store.width(projectRoot: "/c") == ProjectSidebarWidthStore.defaultWidth)
        defaults.set(-1.0, forKey: ProjectSidebarWidthStore.key(projectRoot: "/c"))
        #expect(store.width(projectRoot: "/c") == ProjectSidebarWidthStore.defaultWidth)
    }

    /// Not restorable, a project window gets no frame autosave from SwiftUI
    /// either: each project's window comes back at its own last frame,
    /// whatever order the windows open in.
    @Test func eachProjectWindowOpensAtItsOwnLastFrame() throws {
        let suite = "CherryTests.WindowFrames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frames = ProjectWindowFrameStore(defaults: defaults)
        let directory = try makeCanonicalTemporaryDirectory("cherry-window-frames")
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = try ["a", "b", "c"].map { name in
            let project = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            return project.path
        }
        let saved = [
            NSRect(x: 120, y: 140, width: 800, height: 500),
            NSRect(x: 360, y: 200, width: 900, height: 560),
        ]
        // Resizable, as project windows are: AppKit restores only the
        // origin of a window that is not.
        func makeWindow() -> NSWindow {
            let window = makeTestWindow()
            window.styleMask.insert(.resizable)
            return window
        }
        func register(_ window: NSWindow, _ root: String, in registry: ProjectWindowRegistry, _ workspace: TerminalWorkspace) -> Bool {
            registry.register(
                window: window,
                projectRoot: root,
                workspace: workspace,
                noteStore: nil,
                todoStore: nil,
                chromeState: nil
            )
        }

        // The last run: each window is moved and resized, then closed.
        let lastRun = ProjectWindowRegistry()
        lastRun.configureWindowFrames(frames)
        for (root, frame) in zip(roots, saved) {
            let window = makeWindow()
            let workspace = TerminalWorkspace(projectRoot: root, createInitialSession: false)
            #expect(register(window, root, in: lastRun, workspace))
            window.setFrame(frame, display: false)
            // Saved as it changed, not only when the window closes.
            #expect(frames.frameDescriptor(projectRoot: root) == window.frameDescriptor)
            // Registering again (every view update does) keeps its frame.
            #expect(register(window, root, in: lastRun, workspace))
            #expect(window.frame == frame)
            lastRun.unregister(window: window, projectRoot: root)
            window.close()
        }

        // The next run opens them the other way round.
        let nextRun = ProjectWindowRegistry()
        nextRun.configureWindowFrames(frames)
        var workspaces: [TerminalWorkspace] = []
        var windows: [(NSWindow, String)] = []
        defer {
            for (window, root) in windows {
                nextRun.unregister(window: window, projectRoot: root)
                window.close()
            }
        }
        for (root, frame) in zip(roots, saved).reversed() {
            let window = makeWindow()
            windows.append((window, root))
            let workspace = TerminalWorkspace(projectRoot: root, createInitialSession: false)
            workspaces.append(workspace)
            #expect(register(window, root, in: nextRun, workspace))
            #expect(window.frame == frame)
        }
        // A project whose window never saved a frame keeps the window's own.
        let window = makeWindow()
        windows.append((window, roots[2]))
        let original = window.frame
        let workspace = TerminalWorkspace(projectRoot: roots[2], createInitialSession: false)
        workspaces.append(workspace)
        #expect(register(window, roots[2], in: nextRun, workspace))
        #expect(window.frame == original)
        #expect(frames.frameDescriptor(projectRoot: roots[2]) == nil)
    }

    @Test func controlServerClosesAndRestartsProcessesInTheirOwningWindow() async throws {
        let defaultsName = "CherryTests.OwningWindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let settings = AgentSettings(defaults: defaults)
        let container = try makeCanonicalTemporaryDirectory("cherry-mcp-owning-window")
        let rootA = container.appendingPathComponent("a", isDirectory: true)
        let rootB = container.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        _ = settings.addProject(path: rootA.path)
        _ = settings.addProject(path: rootB.path)
        let socketDirectory = URL(
            fileURLWithPath: "/tmp/cherry-control-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = socketDirectory.appendingPathComponent("control.sock")

        // Every window's policy records its own decisions.
        let recorderA = RecordingBackendPolicy()
        let recorderB = RecordingBackendPolicy()
        let workspaceA = TerminalWorkspace(
            projectRoot: rootA.path,
            createInitialSession: false,
            launchBackend: .hostManaged,
            backendPolicy: recorderA.policy
        )
        _ = workspaceA.attachHostedSession(localAttachment(sessionID: "a-1"), launchShell: false)
        _ = workspaceA.attachHostedSession(localAttachment(sessionID: "a-2"), launchShell: false)
        let workspaceB = TerminalWorkspace(
            projectRoot: rootB.path,
            createInitialSession: false,
            launchBackend: .hostManaged,
            backendPolicy: recorderB.policy
        )
        let hostedB = workspaceB.attachHostedSession(localAttachment(sessionID: "b-1"), launchShell: false)
        let shellB = workspaceB.addSession(title: "Shell B", select: false)
        let windowB = makeTestWindow()
        let registry = ProjectWindowRegistry.shared
        let server = CherryControlServer(workspace: workspaceA, socketURL: socketURL, agentSettings: settings)
        defer {
            server.stop()
            registry.unregister(window: windowB, projectRoot: rootB.path)
            windowB.close()
            workspaceA.closeAllSessions(intent: .windowClosed)
            workspaceB.closeAllSessions(intent: .windowClosed)
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        #expect(registry.register(
            window: windowB,
            projectRoot: rootB.path,
            workspace: workspaceB,
            noteStore: nil,
            todoStore: nil,
            chromeState: nil
        ))
        server.start()

        func send(_ request: CherryControlRequest) async throws -> CherryControlResponse {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try CherryControlClient(socketURL: socketURL).send(request))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        // From window A, close window B's hosted tab: B closes it, as an MCP close.
        let closed = try await send(.closeProcess(.init(processID: hostedB.id.uuidString)))
        guard case .closeProcess(let closeResult)? = closed.result else {
            Issue.record("Expected closeProcess result, got \(String(describing: closed))")
            return
        }
        #expect(closeResult.closed)
        #expect(workspaceB.sessions.map(\.id) == [shellB.id])
        #expect(workspaceA.sessions.count == 2)
        #expect(recorderB.terminated.map(\.sessionID) == ["b-1"])
        #expect(recorderB.terminated.map(\.intent) == [.mcpClose])
        #expect(recorderA.terminated.isEmpty)

        // Restarting window B's shell from window A restarts it in B.
        let restarted = try await send(.restartProcess(.init(processID: shellB.id.uuidString)))
        guard case .restartProcess(let restartResult)? = restarted.result else {
            Issue.record("Expected restartProcess result, got \(String(describing: restarted))")
            return
        }
        #expect(restartResult.process.id == shellB.id.uuidString)
        #expect(workspaceB.sessions.map(\.id) == [shellB.id])
        #expect(workspaceA.sessions.count == 2)
        #expect(recorderA.terminated.isEmpty)
    }
}
