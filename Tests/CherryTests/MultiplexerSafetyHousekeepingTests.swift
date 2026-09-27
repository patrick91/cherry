import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Launch and housekeeping follow-ups (docs/specs/multiplexer-default.md):
// a copy launched while the previous one quits waits for the instance lock
// (`AppInstanceLock`) off the main thread and says so; old set-aside state
// files and staged Ghostty resources no session uses are removed. Only
// temporary directories are touched.

private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func setModified(_ url: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@MainActor
private final class WaitMessages {
    var shown: [String] = []
    var hidden = 0

    var presenter: InstanceLockLaunchWait.Presenter {
        InstanceLockLaunchWait.Presenter(
            show: { [weak self] in self?.shown.append($0) },
            hide: { [weak self] in self?.hidden += 1 }
        )
    }
}

@Test @MainActor func aCopyLaunchedWhileThePreviousOneQuitsWaitsOffTheMainThreadAndSaysSo() async throws {
    let directory = try temporaryDirectory("cherry-instance-wait")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    let first = AppInstanceLock(fileURL: url, applicationSupportName: "Cherry")
    #expect(first.isHeld)
    first.markQuitting()

    let next = AppInstanceLock(fileURL: url, applicationSupportName: "Cherry", quittingHolderWait: 10)
    #expect(!next.isResolved)
    let messages = WaitMessages()
    let launched = Recorder(false)
    let started = Date()
    let waiting = try #require(InstanceLockLaunchWait.run(lock: next, presenter: messages.presenter) {
        launched.value = true
    })
    // The main thread goes on meanwhile: this test's own awaits run on it.
    var turns = 0
    while messages.shown.isEmpty, Date().timeIntervalSince(started) < 5 {
        turns += 1
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(turns > 0)
    #expect(messages.shown == ["Waiting for the previous Cherry to finish quitting…"])
    #expect(!launched.value)
    #expect(!next.isResolved)

    // The previous copy exits: the lock is this one's, and launch goes on.
    first.release()
    await waiting.value
    #expect(launched.value)
    #expect(messages.hidden == 1)
    #expect(next.isResolved)
    #expect(next.isHeld)
    next.release()

    // A lock taken at once shows nothing, and launch goes on at once.
    let quick = AppInstanceLock(fileURL: url, applicationSupportName: "Cherry")
    let quickMessages = WaitMessages()
    let quickLaunch = Recorder(false)
    if let task = InstanceLockLaunchWait.run(lock: quick, presenter: quickMessages.presenter, then: { quickLaunch.value = true }) {
        await task.value
    }
    #expect(quickLaunch.value)
    #expect(quickMessages.shown.isEmpty)
    #expect(quickMessages.hidden == 0)
    // Resolved already: at once, without a task.
    #expect(InstanceLockLaunchWait.run(lock: quick, presenter: quickMessages.presenter, then: {}) == nil)
    quick.release()
}

@Test func oldSetAsideStateFilesArePrunedKeepingTheNewestOfEach() throws {
    let directory = try temporaryDirectory("cherry-bak-prune")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let old = now.addingTimeInterval(-WorkspaceStateStore.setAsideFileAge - 60)
    let hash = String(repeating: "a", count: 64)
    let files: [(String, Date)] = [
        ("\(hash).json.v2-20250101T000000Z.bak", old.addingTimeInterval(-100)),
        ("\(hash).json.unreadable-20250102T000000Z.bak", old),
        ("\(hash).json.v2-20250601T000000Z.bak", now.addingTimeInterval(-60)),
        ("ended-sessions.json.unreadable-20250101T000000Z.bak", old),
        ("\(hash).json", old),
        ("notes.bak", old)
    ]
    for (name, date) in files {
        let url = directory.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try setModified(url, to: date)
    }
    let removed = WorkspaceStateStore.pruneSetAsideFiles(in: directory, now: now)
    #expect(removed == [
        "\(hash).json.unreadable-20250102T000000Z.bak",
        "\(hash).json.v2-20250101T000000Z.bak"
    ])
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    // The newest of each state file stays, however old; the state files
    // themselves and other files are never touched.
    #expect(left == [
        "\(hash).json.v2-20250601T000000Z.bak",
        "ended-sessions.json.unreadable-20250101T000000Z.bak",
        "\(hash).json",
        "notes.bak"
    ])
}

@Test func stagedResourcesNoRunningSessionNamesAreRemovedOnlyAfterALongMargin() throws {
    let base = try temporaryDirectory("cherry-staged-prune")
    defer { try? FileManager.default.removeItem(at: base) }
    let now = Date()
    let day: TimeInterval = 24 * 60 * 60
    func copy(_ seed: Character, usedDaysAgo days: Double) throws -> String {
        let name = String(repeating: seed, count: 32)
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("terminfo"), withIntermediateDirectories: true)
        try setModified(url, to: now.addingTimeInterval(-days * day))
        return name
    }
    let current = try copy("a", usedDaysAgo: 90)
    let unused = try copy("b", usedDaysAgo: 45)
    let recent = try copy("c", usedDaysAgo: 20)
    // Staged (and last marked) long ago, before its session's Create, and
    // still read by that running session: its tag keeps it.
    let named = try copy("d", usedDaysAgo: 60)
    try FileManager.default.createDirectory(at: base.appendingPathComponent(".staging-x"), withIntermediateDirectories: true)

    let stale = GhosttyResourceStaging.staleCopies(in: base, current: current, inUse: [named], now: now)
    #expect(stale.map(\.lastPathComponent) == [unused])
    GhosttyResourceStaging.removeStaleCopies(in: base, current: current, inUse: [named], now: now)
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: base.path)).filter { !$0.hasPrefix(".") }
    #expect(left == [current, recent, named])
    // Using a copy marks it used now.
    GhosttyResourceStaging.noteUse(of: GhosttyStagedResources(rootDirectory: base.appendingPathComponent(named).path))
    #expect(GhosttyResourceStaging.staleCopies(in: base, current: current, inUse: [], now: now).isEmpty)
}

@Test @MainActor func aSessionIsTaggedWithTheResourcesCopyItReads() {
    let hash = String(repeating: "e", count: 32)
    let staged = GhosttyStagedResources(rootDirectory: "/Users/me/Library/Application Support/Cherry/GhosttyResources/\(hash)")
    let configuration = ShellProcessController.Configuration(
        shellPath: "/bin/zsh", workingDirectory: "/tmp", processID: UUID().uuidString,
        term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 80, rows: 24)
    )
    func spec(_ resources: GhosttyStagedResources?) -> HostedLaunchSpec {
        HostedLaunchSpec.make(for: configuration, context: HostedLaunchContext(
            processEnvironment: ["HOME": "/Users/me", "PATH": "/usr/bin:/bin"], loginEnvironment: nil, account: nil,
            launchedFromDesktop: false, ghosttyResources: resources, zshBootstrap: nil, executableDirectory: nil,
            terminalProgramVersion: nil, shellFeatures: ""
        ))
    }
    #expect(spec(staged).resourcesCopy == hash)
    #expect(spec(nil).resourcesCopy == nil)
    let request = PersistentSessionRequest(
        tabID: UUID(), name: "Shell", kind: .terminal, agentName: nil, commandName: nil, projectRoot: nil, columns: 80, rows: 24
    )
    #expect(PersistentLocalSessions.tags(for: request, requestID: request.requestID, resourcesCopy: hash)[PersistentSessionTag.resources] == hash)
    #expect(PersistentLocalSessions.tags(for: request, requestID: request.requestID)[PersistentSessionTag.resources] == nil)
}

@Test @MainActor func theLaunchTouchesTheLockOnlyAfterItsBackgroundWaitAndQuitAndReopenDoNotWait() async throws {
    let directory = try temporaryDirectory("cherry-instance-launch-order")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("instance.lock")
    let previous = AppInstanceLock(fileURL: url, applicationSupportName: "Cherry")
    #expect(previous.isHeld)
    previous.markQuitting()

    let lock = AppInstanceLock(fileURL: url, applicationSupportName: "Cherry", quittingHolderWait: 10)
    let workspaces = directory.appendingPathComponent("Workspaces", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
    // An old set-aside file, which pruning removes once the lock is held.
    let hash = String(repeating: "b", count: 64)
    for (name, age) in [("\(hash).json.v2-1.bak", 90.0), ("\(hash).json.v2-2.bak", 60.0)] {
        let file = workspaces.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        try setModified(file, to: Date().addingTimeInterval(-age * 24 * 60 * 60))
    }
    let store = WorkspaceStateStore(directory: workspaces, instanceLock: lock)
    let messages = WaitMessages()
    let steps = Recorder<[String]>([])
    let waiting = try #require(CherryAppDelegate.finishLaunchingAfterInstanceLock(
        lock: lock, store: store, presenter: messages.presenter
    ) {
        steps.value.append("launch")
    })
    // Waiting: the main thread runs, and what a Dock click or ⌘Q does
    // meanwhile never asks the lock.
    let deadline = Date().addingTimeInterval(5)
    while messages.shown.isEmpty, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!messages.shown.isEmpty)
    #expect(steps.value.isEmpty)
    #expect(!lock.isResolved)
    #expect(CherryAppDelegate.reopenAction(lockResolved: lock.isResolved, hasProjectWindow: false) == .waitForLaunch)
    #expect(CherryAppDelegate.quitsAtOnce(lockResolved: lock.isResolved))
    let marking = Date()
    lock.markQuitting()
    #expect(Date().timeIntervalSince(marking) < 0.2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspaces.path).count == 2)

    previous.release()
    await waiting.value
    #expect(steps.value == ["launch"])
    #expect(lock.isHeld)
    store.flush()
    // Pruned after the wait, the newest set-aside file kept.
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspaces.path) == ["\(hash).json.v2-2.bak"])
    #expect(CherryAppDelegate.reopenAction(lockResolved: lock.isResolved, hasProjectWindow: false) == .openDefaultWindow)
    #expect(CherryAppDelegate.reopenAction(lockResolved: lock.isResolved, hasProjectWindow: true) == .focusProjectWindow)
    #expect(!CherryAppDelegate.quitsAtOnce(lockResolved: lock.isResolved))
    lock.release()
}
