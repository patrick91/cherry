import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

// Helpers the test files share. This file declares no tests of its own, so
// Scripts/test-session-suites never takes it for a session suite.

// MARK: - Waiting

/// Waits (polling every `interval`, on the caller's actor: on the main actor
/// the main loop turns meanwhile) until `condition` holds; false after
/// `timeout`.
func eventually(
    isolation: isolated (any Actor)? = #isolation,
    timeout: TimeInterval = 5,
    interval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}

/// Waits until `predicate` holds; throws, naming `description`, after
/// `timeout`.
@MainActor
func poll(_ description: String, timeout: TimeInterval = 15, _ predicate: @MainActor () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw HostedSessionError.message("Timed out waiting for \(description)")
}

/// Holds restores (or anything else that waits on it) until the test opens
/// it; once open, it holds nothing.
@MainActor
final class RestoreGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    /// How many waits it held.
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

// MARK: - Files and processes

/// A new directory `<prefix>-<UUID>` in the temporary directory, by its real
/// path (/private/var/…, not /var/…).
func canonicalTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let resolved = try #require(url.path.withCString { realpath($0, nil) })
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

/// `RepositoryWorkspace.repositoryRoot` for a directory: standardized, so a
/// temporary directory loses its /private prefix. Its tabs' folder
/// (`workspaceRoot`) stays a real path.
func repositoryKey(_ root: URL) -> String {
    URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL.path
}

/// UserDefaults of a new suite `<prefix>-<UUID>`, empty: never the app's.
func privateDefaults(_ prefix: String) -> UserDefaults {
    let name = "\(prefix)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - Windows

/// A project window that never comes on screen.
@MainActor
func testWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
}

/// A clock the test moves, and the checks toasts and closed tabs scheduled
/// on it.
@MainActor
final class ManualClock {
    let start = Date(timeIntervalSince1970: 1_000)
    private(set) var now: Date
    private var scheduled: [(at: Date, work: @MainActor () -> Void)] = []

    init() { now = start }

    var schedule: ProjectWindowToasts.Scheduler {
        { [unowned self] delay, work in scheduled.append((now.addingTimeInterval(delay), work)) }
    }

    /// Moves the clock on by `seconds`, running what falls due, in order.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let next = scheduled.enumerated().filter({ $0.element.at <= now }).min(by: { $0.element.at < $1.element.at }) {
            scheduled.remove(at: next.offset)
            next.element.work()
        }
    }
}

/// A project window's chrome whose toasts keep time on `clock` (never going
/// by themselves without one), announce into `announced` and reach no
/// VoiceOver.
@MainActor
func quietChromeState(
    clock: ManualClock? = nil,
    announced: Recorder<[String]> = Recorder([])
) -> ProjectWindowChromeState {
    let schedule: ProjectWindowToasts.Scheduler
    if let clock {
        schedule = clock.schedule
    } else {
        schedule = { _, _ in }
    }
    return ProjectWindowChromeState(toasts: ProjectWindowToasts(
        now: { clock?.now ?? Date() },
        schedule: schedule,
        announce: { announced.value.append($0) },
        voiceOverEnabled: { false }
    ))
}

/// The name the sidebar shows for `session`.
@MainActor
func sidebarName(of session: TerminalSession) -> String {
    SidebarSessionLabel.label(for: session, pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode).title
}
