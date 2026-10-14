import AppKit
import Foundation
import Testing
@testable import Cherry

// Restoring two windows of one project at once (#22): each loads only its
// own file, and a session both files name (left by a crash or an older
// build) comes back in one tab, the first window's to restore it, before
// the host answers too. Against the fake `cherry control`
// (FakeControlHelper) and attach adapter (HostedSessionFakeCLI).

// MARK: - Helpers

private func savedTab(id: UUID = UUID(), title: String, sessionID: String, root: String) -> WorkspaceSessionRecord {
    WorkspaceSessionRecord(
        id: id,
        kind: .terminal,
        title: title,
        titleSource: .system,
        launchWorkingDirectory: root,
        workingDirectory: root,
        projectRoot: root,
        hosted: HostedSessionBindingRecord(host: "local", hostID: "host-a", sessionID: sessionID, owned: true)
    )
}

private func running(_ id: String, _ record: WorkspaceSessionRecord, pid: UInt32) -> HostedSessionInfo {
    HostedSessionInfo(id: id, name: record.title, cwd: record.workingDirectory, pid: pid, owner: "CherryTests",
                      tags: [PersistentSessionTag.tab: record.id.uuidString])
}

/// A project with a primary window and another, each with its own saved
/// tabs (`sessions[window]`), restoring through `harness`'s fake host,
/// which answers once `gate` opens.
@MainActor
private struct TwoWindows {
    let harness: PersistentHarness
    let root: URL
    let storeDirectory: URL
    let store: WorkspaceStateStore
    let otherID: UUID
    let gate: RestoreGate
    let primary: RepositoryWorkspace
    let other: RepositoryWorkspace

    init(
        _ harness: PersistentHarness,
        primaryTabs: [WorkspaceSessionRecord],
        otherTabs: [WorkspaceSessionRecord],
        root: URL,
        showsSavedTabsBeforeHostAnswers: Bool
    ) throws {
        self.harness = harness
        self.root = root
        storeDirectory = try canonicalTemporaryDirectory("cherry-restore-windows-store")
        let store = WorkspaceStateStore(directory: storeDirectory)
        self.store = store
        let otherID = UUID()
        self.otherID = otherID
        for (windowID, tabs) in [(nil, primaryTabs), (otherID, otherTabs)] as [(UUID?, [WorkspaceSessionRecord])] {
            store.saveSynchronously(RepositoryStateRecord(
                repositoryRoot: repositoryKey(root),
                activeWorktreeRoot: root.path,
                worktrees: [WorktreeStateRecord(root: root.path, sessions: tabs, selectedSessionID: tabs.first?.id)],
                savedAt: Date(),
                windowID: windowID
            ))
        }
        let gate = RestoreGate()
        self.gate = gate
        let restorer = harness.restorer
        func window(_ windowID: UUID?) -> RepositoryWorkspace {
            RepositoryWorkspace(
                projectRoot: root.path,
                windowID: windowID,
                backendPolicy: harness.policy,
                stateStore: store,
                sessionRestorer: { request in
                    await gate.wait()
                    return await restorer(request)
                },
                autoStartCommands: { _ in [] },
                restoredTabLaunchQueue: RestoredTabLaunchQueue(),
                showsSavedTabsBeforeHostAnswers: showsSavedTabsBeforeHostAnswers
            )
        }
        primary = window(nil)
        other = window(otherID)
    }

    /// Each window's tabs' record ids, primary first.
    var tabs: [[UUID]] { [primary, other].map { $0.workspace.sessions.map(\.id) } }

    /// What each window's file names now, primary first.
    func saved() -> [[UUID]] {
        [primary, other].map { repository in
            repository.flushPersistentState()
            return store.load(repositoryRoot: repository.repositoryRoot, windowID: repository.windowID)?
                .worktree(root: root.path)?.sessions.map(\.id) ?? []
        }
    }

    func cleanUp() {
        gate.open()
        primary.closeAllSessions(intent: .windowClosed)
        other.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDirectory)
    }
}

// MARK: - Restoring at once

/// Two windows of a project restore at once, showing their saved tabs
/// before the host answers (as the launch does): disjoint files give
/// disjoint tabs, and a tab both files name (the same record) is the first
/// window's, provisional and then confirmed; the other never shows it. Each
/// session ends up in exactly one tab, and nothing is created or killed.
@Test @MainActor func twoWindowsOfAProjectRestoringAtOnceGiveEachSessionOneTab() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-at-once")
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(title: "Server", sessionID: "s-server", root: root.path)
    let shared = savedTab(title: "Shared", sessionID: "s-shared", root: root.path)
    harness.fake.sessions = [running("s-editor", editor, pid: 81), running("s-server", server, pid: 82),
                             running("s-shared", shared, pid: 83)]
    let windows = try TwoWindows(
        harness, primaryTabs: [editor, shared], otherTabs: [server, shared], root: root,
        showsSavedTabsBeforeHostAnswers: true
    )
    defer { windows.cleanUp() }

    windows.primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    windows.other.beginRestoringSavedStateIfNeeded(chromeState: nil)
    #expect(await harness.fake.wait { windows.gate.waiting == 2 })
    // Before the host answers: the shared tab is the primary's alone.
    #expect(windows.tabs == [[editor.id, shared.id], [server.id]])
    let sharedTab = try #require(windows.primary.workspace.session(withID: shared.id))
    #expect(sharedTab.isProvisionalRestore)
    #expect(harness.hosting.owningTab(of: "s-shared") === sharedTab)
    #expect(windows.other.workspace.sessions.allSatisfy { $0.isProvisionalRestore })

    windows.gate.open()
    await windows.primary.waitForPendingRestores()
    await windows.other.waitForPendingRestores()
    #expect(windows.tabs == [[editor.id, shared.id], [server.id]])
    #expect(windows.primary.workspace.session(withID: shared.id) === sharedTab)
    #expect(!sharedTab.isProvisionalRestore)
    for (sessionID, window) in [("s-editor", windows.primary), ("s-shared", windows.primary), ("s-server", windows.other)] {
        let owner = try #require(harness.hosting.owningTab(of: sessionID))
        #expect(window.contains(sessionID: owner.id))
        #expect([windows.primary, windows.other].filter { $0.contains(sessionID: owner.id) }.count == 1)
    }
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}

/// A session both windows' files name comes back in one tab, the window's
/// that restored it first; the other drops the record, so its next save
/// no longer names it, and nothing ends.
@Test @MainActor func aSessionBothWindowsFilesNameComesBackInOneTab() async throws {
    let harness = try PersistentHarness()
    harness.fake.pendingHolders = 0
    let root = try canonicalTemporaryDirectory("cherry-restore-windows-shared")
    let editor = savedTab(title: "Editor", sessionID: "s-editor", root: root.path)
    let server = savedTab(title: "Server", sessionID: "s-server", root: root.path)
    let shared = savedTab(title: "Shared", sessionID: "s-shared", root: root.path)
    harness.fake.sessions = [running("s-editor", editor, pid: 81), running("s-server", server, pid: 82),
                             running("s-shared", shared, pid: 83)]
    let windows = try TwoWindows(
        harness, primaryTabs: [editor, shared], otherTabs: [shared, server], root: root,
        showsSavedTabsBeforeHostAnswers: false
    )
    defer { windows.cleanUp() }
    windows.gate.open()

    // The other window restores first this time.
    windows.other.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await windows.other.waitForPendingRestores()
    windows.primary.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await windows.primary.waitForPendingRestores()
    #expect(windows.tabs == [[editor.id], [shared.id, server.id]])
    let sharedTab = try #require(windows.other.workspace.session(withID: shared.id))
    #expect(harness.hosting.owningTab(of: "s-shared") === sharedTab)
    #expect(windows.saved() == [[editor.id], [shared.id, server.id]])
    #expect(harness.creates().isEmpty)
    #expect(harness.fake.requests("kill").isEmpty)
}
