import CherryControl
import Darwin
import Foundation

/// One running copy of each app identity owns this Mac's persistent sessions
/// and saved tabs (docs/specs/multiplexer-default.md, "Scoping"). Sessions
/// are owned by `owner` = the app identity, and the saved state lives under
/// `Application Support/<identity>/`, so two copies with the same identity
/// (Cherry.app and `swift run Cherry`, or `open -n`) would both adopt the
/// same sessions, end each other's programs and overwrite each other's state
/// file. The first copy takes an exclusive lock on
/// `Application Support/<identity>/instance.lock` (`flock`, released by the
/// kernel when the process exits, even after a crash) and keeps it for its
/// whole run. A copy that cannot take it neither restores, saves nor ends
/// persistent sessions, and runs its tabs natively; it does not try again
/// during its run (its windows opened without the saved state, so saving
/// them later would overwrite the other copy's).
///
/// A copy launched while the holder is quitting (it marked the lock file,
/// `markQuitting()`, and may still wait several seconds for its sessions
/// to end) waits for it, up to `quittingHolderWait`, instead of running
/// its whole run without saved tabs. A file system without `flock`
/// support leaves the lock unenforced: the copy goes on as if it held it
/// (as before the lock existed), and says so on standard error.
final class AppInstanceLock: @unchecked Sendable {
    enum State: Equatable, Sendable {
        /// This process holds the lock.
        case held
        /// The file system does not support the lock (the reason): this copy
        /// goes on as if it held it, since it cannot tell.
        case unenforced(String)
        /// Another process holds it; its pid when it wrote one.
        case heldElsewhere(pid: pid_t?)
        /// The lock file could not be opened or locked (the reason).
        case unavailable(String)
    }

    /// `flock(2)`; tests pass their own.
    typealias LockCall = @Sendable (_ descriptor: Int32, _ operation: Int32) -> Int32

    static let shared = AppInstanceLock(
        fileURL: defaultFileURL(),
        applicationSupportName: CherryAppIdentity.current.applicationSupportName
    )

    /// The third line of the lock file while its holder quits.
    static let quittingMarker = "quitting"

    let fileURL: URL
    let applicationSupportName: String
    /// How long a copy waits for a holder that is quitting: its quit waits
    /// at most about 10 s (the reply deadline) for its sessions to end.
    let quittingHolderWait: TimeInterval
    private let lockCall: LockCall
    private let lock = NSLock()
    private var resolved: State?
    private var descriptor: Int32 = -1
    /// Whether the lock has been taken or given up on: read without `lock`,
    /// which a wait for a quitting holder keeps (`isResolved`).
    private let resolvedFlag = NSLock()
    private var resolvedStorage = false

    init(
        fileURL: URL,
        applicationSupportName: String,
        quittingHolderWait: TimeInterval = 12,
        lockCall: @escaping LockCall = AppInstanceLock.systemLock
    ) {
        self.fileURL = fileURL
        self.applicationSupportName = applicationSupportName
        self.quittingHolderWait = quittingHolderWait
        self.lockCall = lockCall
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    static func defaultFileURL(
        applicationSupportName: String = CherryAppIdentity.current.applicationSupportName
    ) -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportName, isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
    }

    /// Takes the lock on first use, and answers the same for the rest of the
    /// run.
    var state: State {
        resolve(onWaiting: nil)
    }

    /// Whether `state` answers at once: the lock was taken or given up on.
    /// Never waits.
    var isResolved: Bool {
        resolvedFlag.withLock { resolvedStorage }
    }

    /// Takes the lock (`state`) on a background thread, so a copy launched
    /// while the holder quits never blocks the main thread for the wait
    /// (`quittingHolderWait`). `onWaiting` is called once, on some thread,
    /// when it starts waiting for such a holder (the app shows "Waiting for
    /// the previous Cherry to finish quitting…", `InstanceLockLaunchWait`).
    func resolveInBackground(onWaiting: (@Sendable () -> Void)? = nil) async -> State {
        if isResolved { return state }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.resolve(onWaiting: onWaiting))
            }
        }
    }

    private func resolve(onWaiting: (@Sendable () -> Void)?) -> State {
        lock.withLock {
            if let resolved { return resolved }
            let state = acquireLocked(onWaiting: onWaiting)
            resolved = state
            resolvedFlag.withLock { resolvedStorage = true }
            return state
        }
    }

    /// Whether this copy owns the persistent sessions and saved tabs: it
    /// holds the lock, or the file system cannot enforce it.
    var isHeld: Bool {
        switch state {
        case .held, .unenforced: true
        case .heldElsewhere, .unavailable: false
        }
    }

    /// Why this copy does not use persistent sessions and saved tabs, as a
    /// full sentence for Settings › Sessions; nil while it holds the lock.
    var unavailableReason: String? {
        switch state {
        case .held, .unenforced:
            return nil
        case .heldElsewhere(let pid):
            let process = pid.map { " (process \($0))" } ?? ""
            return "Another copy of \(applicationSupportName)\(process) is running with the same app data "
                + "(Application Support/\(applicationSupportName)). That copy keeps this Mac's persistent "
                + "sessions and saved tabs, so this copy does not restore, save or end them. Quit this copy, "
                + "or build it with its own CherryApplicationSupportName."
        case .unavailable(let reason):
            return "Cherry could not make sure it is the only copy using this app data: \(reason) "
                + "Persistent sessions and saved tabs are off in this copy."
        }
    }

    /// The app is quitting (its quit may still wait for sessions to end): a
    /// copy launched meanwhile waits for the lock instead of giving up at
    /// once. Nothing when this copy does not hold the lock.
    func markQuitting() {
        // Not resolved yet (a background wait may hold `lock`): this copy
        // holds nothing to mark, and must not wait for it here.
        guard isResolved else { return }
        lock.withLock {
            guard descriptor >= 0 else { return }
            writeOwner(to: descriptor, quitting: true)
        }
    }

    /// Releases the lock (tests; the app keeps it until it exits).
    func release() {
        lock.withLock {
            if descriptor >= 0 {
                close(descriptor)
                descriptor = -1
            }
            resolved = nil
            resolvedFlag.withLock { resolvedStorage = false }
        }
    }

    private func acquireLocked(onWaiting: (@Sendable () -> Void)?) -> State {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .unavailable("\(directory.path) could not be created (\(error.localizedDescription)).")
        }
        let fd = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            return .unavailable("\(fileURL.path) could not be opened (\(String(cString: strerror(errno)))).")
        }
        let waitDeadline = Date().addingTimeInterval(quittingHolderWait)
        var onWaiting = onWaiting
        while lockCall(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK {
                // A holder that is quitting lets go within seconds.
                let owner = Self.owner(in: fd)
                if owner.quitting, Date() < waitDeadline, owner.pid.map(Self.isAlive) ?? true {
                    onWaiting?()
                    onWaiting = nil
                    usleep(50_000)
                    continue
                }
                close(fd)
                return .heldElsewhere(pid: owner.pid)
            }
            close(fd)
            let reason = "\(fileURL.path) could not be locked (\(String(cString: strerror(code))))."
            if Self.meansLockUnsupported(code) {
                // A home on a file system without flock (some network
                // volumes): the lock cannot say whether another copy runs,
                // so this one goes on as copies did before the lock.
                fputs("Cherry: \(reason) Going on without making sure this is the only copy of \(applicationSupportName).\n", stderr)
                return .unenforced(reason)
            }
            return .unavailable(reason)
        }
        descriptor = fd
        writeOwner(to: fd, quitting: false)
        return .held
    }

    /// Who holds it, for the other copy's explanation and wait.
    private func writeOwner(to fd: Int32, quitting: Bool) {
        var text = "\(getpid())\n\(ProcessInfo.processInfo.arguments.first ?? "")\n"
        if quitting { text += Self.quittingMarker + "\n" }
        let contents = Array(text.utf8)
        // Written over the old text, then cut to length: a copy reading it
        // meanwhile never finds it empty.
        _ = contents.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        _ = ftruncate(fd, off_t(contents.count))
    }

    @Sendable
    static func systemLock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
        flock(descriptor, operation)
    }

    /// Errors that say the file system has no `flock`, rather than that it
    /// failed: the lock is then not enforced.
    static func meansLockUnsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOLCK
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func owner(in fd: Int32) -> (pid: pid_t?, quitting: Bool) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return (nil, false) }
        let lines = String(decoding: buffer[..<count], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let pid = lines.first.flatMap { pid_t($0) }.flatMap { $0 > 0 ? $0 : nil }
        let quitting = lines.count > 2 && lines[2] == Substring(quittingMarker)
        return (pid, quitting)
    }
}

/// Launch waits for the instance lock (`AppInstanceLock`) off the main
/// thread: a copy launched while the previous one quits (and still ends its
/// sessions) says "Waiting for the previous Cherry to finish quitting…"
/// until that copy lets go, and only then reaches the local host, lists
/// background sessions and opens its windows, which all need to know
/// whether it holds the lock.
@MainActor
enum InstanceLockLaunchWait {
    /// Shows and hides the waiting message.
    struct Presenter: Sendable {
        let show: @MainActor @Sendable (String) -> Void
        let hide: @MainActor @Sendable () -> Void
    }

    static func message(applicationName: String) -> String {
        "Waiting for the previous \(applicationName) to finish quitting…"
    }

    /// Runs `launch` once `lock` is resolved: at once when it already is,
    /// else after taking it in the background, with the message shown while
    /// it waits for a quitting holder.
    @discardableResult
    static func run(
        lock: AppInstanceLock,
        presenter: Presenter = .app,
        then launch: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        if lock.isResolved {
            launch()
            return nil
        }
        @MainActor final class Progress {
            var resolved = false
            var shown = false
        }
        let progress = Progress()
        let name = lock.applicationSupportName
        return Task { @MainActor in
            _ = await lock.resolveInBackground(onWaiting: {
                Task { @MainActor in
                    guard !progress.resolved else { return }
                    progress.shown = true
                    presenter.show(message(applicationName: name))
                }
            })
            progress.resolved = true
            if progress.shown { presenter.hide() }
            launch()
        }
    }
}
