import AppKit
import CryptoKit
import Darwin
import Foundation

/// One app-managed OpenSSH master connection per SSH destination, which the
/// control helper and the attach adapters share through `cherry
/// --ssh-control-path`. Each opens a channel on it instead of its own SSH
/// connection (and authentication).
///
/// A master runs in BatchMode: when it cannot authenticate without a prompt it
/// fails, and helpers and adapters fall back to their own ssh (an adapter can
/// then still prompt in its tab). A master runs while something needs it:
/// a lease (a control connection, via `acquire`) or an adapter launch that
/// got its control path (`controlPath(forLaunch:destination:)`). When the
/// last one ends it is stopped after `idleStopDelay`. A master that was up
/// and dies while needed is restarted with backoff. One that fails before it
/// is up (it could not connect, or not log in without a prompt) is not: each
/// attempt would be another failed login on the server. A new lease, or
/// `retry` once a helper connected on its own, starts it again. The restart
/// delay doubles (up to its maximum) each time a master dies within
/// `stableUptime` of coming up, so one that logs in and is dropped again
/// and again is not restarted every second. Masters of an app that crashed
/// are stopped by the next launch: `sweepAbandonedMasters()` runs when the
/// app starts using this manager (and when the app calls it at launch).
///
/// Thread-safe. Blocking work (spawning, `ssh -O`) runs off the caller's
/// thread.
final class HostSSHMasterManager: @unchecked Sendable {
    /// The app's manager. Creating it sweeps what crashed runs left
    /// (`sweepAbandonedMasters`): every control connection uses it.
    static let shared: HostSSHMasterManager = {
        sweepAbandonedMasters()
        return HostSSHMasterManager()
    }()

    struct Configuration: Sendable {
        /// The private directory for control sockets, or nil when masters are
        /// disabled. Called once.
        var directory: @Sendable () -> URL? = { HostSSHMasterManager.defaultDirectory() }
        /// The ssh to run, given the environment it runs with.
        var sshExecutable: @Sendable ([String: String]) -> String = { HostSSHMasterManager.sshExecutable(in: $0) }
        /// How long `waitUntilUp` waits by default for a starting master.
        var startTimeout: TimeInterval = 20
        var healthCheckInterval: TimeInterval = 30
        var idleStopDelay: TimeInterval = 10
        var restartDelay: (initial: TimeInterval, maximum: TimeInterval) = (1, 60)
        /// How often a starting master's socket is looked for.
        var pollInterval: TimeInterval = 0.05
        /// For `ssh -O check` and `ssh -O exit`.
        var commandTimeout: TimeInterval = 5
        /// A master that dies after being up at least this long is restarted
        /// after the initial delay again; one that dies sooner waits twice
        /// as long as the previous restart did.
        var stableUptime: TimeInterval = 60
        /// Attach adapter launches that share one master at most. sshd
        /// allows 10 sessions per connection by default (`MaxSessions`), and
        /// the control helper and one-off commands (list, kill) need one
        /// each.
        ///
        /// Over the cap: `controlPath(forLaunch:)` returns nil and registers
        /// nothing, so that adapter runs its own ssh (its own connection
        /// and login, which may prompt in its tab, as without a master) for
        /// as long as it runs, reconnects included: `cherry attach`
        /// reconnects with the arguments it was launched with. Launches
        /// are counted, not tabs: every launch of a tab's adapter (a
        /// relaunch after its reconnect window, a Reconnect) is registered
        /// afresh, so one that starts while a slot is free shares the
        /// master again. Nothing moves a running adapter onto the master
        /// when a slot frees. `cherry` also connects directly when a
        /// master refuses a session anyway (a server with a lower
        /// `MaxSessions`).
        var maxChannelsPerMaster = 8
    }

    enum Phase: Equatable, Sendable {
        case stopped
        case starting
        case up
        case waitingToRestart
        case stopping
    }

    struct Status: Equatable, Sendable {
        var phase: Phase
        var controlPath: String?
        /// Why the last master exited, from its standard error.
        var lastError: String?
        var leases: Int
        var launches: Int
        /// Failed starts, and deaths soon after coming up, since the master
        /// was last up for `stableUptime`: the restart backoff's exponent.
        var failures: Int = 0
    }

    /// Guarded by the manager's lock.
    private final class Master: @unchecked Sendable {
        let destination: String
        let controlPath: String
        var environment: [String: String] = [:]
        var leases: Set<UUID> = []
        var launches: Set<String> = []
        var phase: Phase = .stopped
        /// The running ssh; nil once it exited (it is never signalled then).
        var process: HostSignallableProcess?
        /// Increases with each start, so callbacks of an earlier master
        /// change nothing.
        var generation = 0
        var failures = 0
        /// When it last came up.
        var upSince: Date?
        var lastError: String?
        var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]
        var idleStop: DispatchWorkItem?
        var restart: DispatchWorkItem?

        init(destination: String, controlPath: String) {
            self.destination = destination
            self.controlPath = controlPath
        }

        var isNeeded: Bool { !leases.isEmpty || !launches.isEmpty }
    }

    let configuration: Configuration
    private let lock = NSLock()
    private var masters: [String: Master] = [:]
    private var resolvedDirectory: URL??
    /// Set by `stopAll`: no master starts again.
    private var isShutDown = false
    private var terminationObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "cherry.ssh-master", qos: .utility, attributes: .concurrent)

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: Users

    /// Keeps the destination's master running until the lease is released
    /// (or deallocated), starting it when needed. `environment` is what ssh
    /// runs with: the helper environment with the login shell's variables.
    func acquire(_ destination: String, environment: [String: String]) -> HostSSHMasterLease {
        let id = UUID()
        let start: (Master, Int)? = lock.withLock {
            guard let master = masterLocked(for: destination) else { return nil }
            master.environment = environment
            master.leases.insert(id)
            master.idleStop?.cancel()
            master.idleStop = nil
            return beginStartLocked(master)
        }
        if let start { launch(start.0, generation: start.1) }
        return HostSSHMasterLease { [weak self] in self?.release(id, destination: destination) }
    }

    /// The control path while the destination's master is up, else nil.
    /// Whoever starts a process with it must also keep the master running.
    func controlPathIfUp(for destination: String) -> String? {
        lock.withLock {
            guard let master = masters[destination], master.phase == .up else { return nil }
            return master.controlPath
        }
    }

    /// For an attach adapter launch (named by `launch`): the control path
    /// while the master is up and has room for it (`maxChannelsPerMaster`
    /// launches), and the launch then keeps it running until `endLaunch`.
    /// Nil otherwise, and the adapter uses its own ssh. Asking
    /// again for the same launch is harmless. `isLive` says whether the
    /// launch still runs; it is checked under the manager's lock, so a launch
    /// that ended (and whose `endLaunch` already ran) is never kept again.
    func controlPath(forLaunch launch: String, destination: String, isLive: () -> Bool = { true }) -> String? {
        lock.withLock {
            guard let master = masters[destination], master.phase == .up, isLive() else { return nil }
            // Full: this launch connects on its own.
            guard master.launches.contains(launch) || master.launches.count < configuration.maxChannelsPerMaster else {
                return nil
            }
            master.launches.insert(launch)
            master.idleStop?.cancel()
            master.idleStop = nil
            return master.controlPath
        }
    }

    /// Starts the destination's master again when it failed to start and is
    /// still needed. For a caller that just connected on its own: logging in
    /// without a prompt works now.
    func retry(_ destination: String, environment: [String: String]) {
        let start: (Master, Int)? = lock.withLock {
            guard let master = masters[destination], master.phase == .stopped else { return nil }
            master.environment = environment
            return beginStartLocked(master)
        }
        if let start { launch(start.0, generation: start.1) }
    }

    /// The launch no longer needs a master.
    func endLaunch(_ launch: String) {
        lock.withLock {
            for master in masters.values where master.launches.remove(launch) != nil {
                scheduleIdleStopLocked(master)
            }
        }
    }

    /// The control path once the master is up; nil when it fails, is not
    /// starting, or does not come up within `timeout`.
    func waitUntilUp(_ destination: String, timeout: TimeInterval? = nil) async -> String? {
        let id = UUID()
        let timeout = timeout ?? configuration.startTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let immediate: String?? = lock.withLock {
                guard let master = masters[destination] else { return .some(nil) }
                switch master.phase {
                case .up: return .some(master.controlPath)
                case .starting:
                    master.waiters[id] = continuation
                    return .none
                case .stopped, .waitingToRestart, .stopping: return .some(nil)
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resumeWaiter(id, destination: destination, with: nil)
            }
        }
    }

    func status(of destination: String) -> Status? {
        lock.withLock {
            masters[destination].map {
                Status(
                    phase: $0.phase, controlPath: $0.controlPath, lastError: $0.lastError,
                    leases: $0.leases.count, launches: $0.launches.count, failures: $0.failures
                )
            }
        }
    }

    /// Stops every master now and for good (the app is quitting). Returns
    /// at once.
    func stopAll() {
        let stopping: [(Master, HostSignallableProcess?)] = lock.withLock {
            isShutDown = true
            return masters.values.compactMap { master in
                master.idleStop?.cancel()
                master.restart?.cancel()
                guard master.phase != .stopped else { return nil }
                master.phase = .stopping
                resumeWaitersLocked(master, with: nil)
                return (master, master.process)
            }
        }
        for (master, process) in stopping {
            // Signalled only while it has not exited: never a reused pid.
            process?.signal(SIGTERM)
            try? FileManager.default.removeItem(atPath: master.controlPath)
        }
    }

    // MARK: Lifecycle

    private func release(_ lease: UUID, destination: String) {
        lock.withLock {
            guard let master = masters[destination], master.leases.remove(lease) != nil else { return }
            scheduleIdleStopLocked(master)
        }
    }

    private func masterLocked(for destination: String) -> Master? {
        if let master = masters[destination] { return master }
        guard let directory = directoryLocked(),
              let path = Self.controlPath(in: directory, destination: destination)
        else { return nil }
        let master = Master(destination: destination, controlPath: path)
        masters[destination] = master
        return master
    }

    private func directoryLocked() -> URL? {
        if let resolvedDirectory { return resolvedDirectory }
        let directory = configuration.directory()
        resolvedDirectory = .some(directory)
        if directory != nil, self === Self.shared {
            // A master outlives the app unless stopped: quit stops them all.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.stopAll() }
        }
        return directory
    }

    private static let sweepOnce = HostControlFlag()

    /// Stops the masters that app runs which are no longer running left
    /// behind (a crash, a kill), and removes their socket directories, in
    /// the background. They run in a session of their own with ServerAlive,
    /// so they would otherwise stay logged in to their servers for good.
    /// Runs once per app run; the app calls it at launch, and the shared
    /// manager calls it when it is first used, whether or not any master is
    /// ever needed.
    static func sweepAbandonedMasters() {
        guard !sweepOnce.value else { return }
        sweepOnce.set()
        let parents = candidateParentDirectories
        DispatchQueue.global(qos: .utility).async {
            for parent in parents { removeAbandonedDirectories(in: parent) }
        }
    }

    /// Moves a stopped master to starting; the caller then calls `launch`.
    private func beginStartLocked(_ master: Master) -> (Master, Int)? {
        guard !isShutDown, master.phase == .stopped, master.isNeeded else { return nil }
        master.restart?.cancel()
        master.restart = nil
        master.phase = .starting
        master.generation += 1
        return (master, master.generation)
    }

    private func launch(_ master: Master, generation: Int) {
        queue.async { [self] in
            let (environment, destination, controlPath) = lock.withLock {
                (master.environment, master.destination, master.controlPath)
            }
            // A socket left by a master that was killed would make ssh refuse
            // to listen. The directory is this app run's own.
            try? FileManager.default.removeItem(atPath: controlPath)
            let ssh = configuration.sshExecutable(environment)
            let process: HostSpawnedProcess
            do {
                process = try HostSpawnedProcess.spawn(
                    executable: ssh,
                    arguments: Self.masterArguments(destination: destination, controlPath: controlPath),
                    environment: environment,
                    errors: true
                )
            } catch {
                exited(master, generation: generation, status: -1, errors: error.localizedDescription)
                return
            }
            let errors = HostProcessErrorTail(limit: 4_096)
            errors.drain(process.errors)
            let child = HostSignallableProcess(pid: process.pid)
            let isCurrent = lock.withLock { () -> Bool in
                guard master.generation == generation, master.phase == .starting else { return false }
                master.process = child
                return true
            }
            guard isCurrent else {
                // Stopped before it started (nothing has reaped it yet).
                child.signal(SIGTERM)
                child.startReaping(name: "cherry.ssh-master.reaper")
                return
            }
            child.startReaping(name: "cherry.ssh-master.reaper") { [weak self] status in
                errors.waitForEnd(timeout: 0.5)
                self?.exited(master, generation: generation, status: status, errors: errors.text)
            }
            pollUntilUp(master, generation: generation, startedAt: Date())
        }
    }

    /// ssh creates the socket once it has authenticated; `-O check` then
    /// confirms the master answers on it.
    private func pollUntilUp(_ master: Master, generation: Int, startedAt: Date) {
        let (controlPath, destination, environment, isStarting) = lock.withLock {
            (master.controlPath, master.destination, master.environment,
             master.generation == generation && master.phase == .starting)
        }
        guard isStarting else { return }
        var status = stat()
        if lstat(controlPath, &status) == 0, check(destination: destination, controlPath: controlPath, environment: environment) {
            let delivered: Bool = lock.withLock {
                guard master.generation == generation, master.phase == .starting else { return false }
                master.phase = .up
                // `failures` is reset only once it stayed up (`exited`).
                master.upSince = Date()
                master.lastError = nil
                resumeWaitersLocked(master, with: master.controlPath)
                if !master.isNeeded { scheduleIdleStopLocked(master) }
                return true
            }
            if delivered { scheduleHealthCheck(master, generation: generation) }
            return
        }
        // A master that takes longer than the start timeout (a slow network)
        // may still come up; later adapters then use it.
        let slow = Date().timeIntervalSince(startedAt) > configuration.startTimeout
        let interval = slow ? max(configuration.pollInterval, 1) : configuration.pollInterval
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollUntilUp(master, generation: generation, startedAt: startedAt)
        }
    }

    private func scheduleHealthCheck(_ master: Master, generation: Int) {
        queue.asyncAfter(deadline: .now() + configuration.healthCheckInterval) { [weak self] in
            guard let self else { return }
            let (controlPath, destination, environment, isUp) = lock.withLock {
                (master.controlPath, master.destination, master.environment,
                 master.generation == generation && master.phase == .up)
            }
            guard isUp else { return }
            if check(destination: destination, controlPath: controlPath, environment: environment) {
                scheduleHealthCheck(master, generation: generation)
                return
            }
            // It no longer answers: stop it, and its exit restarts it if
            // needed. Decided after the check (which takes up to
            // `commandTimeout`): only the same master, still up, and only
            // while it has not exited (the usual reason a check fails).
            let unresponsive: HostSignallableProcess? = lock.withLock {
                guard master.generation == generation, master.phase == .up, let process = master.process else { return nil }
                master.lastError = "The SSH master connection stopped answering."
                return process
            }
            unresponsive?.signal(SIGTERM)
        }
    }

    private func exited(_ master: Master, generation: Int, status: Int32, errors: String) {
        let isCurrent = lock.withLock { master.generation == generation }
        // Its socket, unless a newer master of the destination owns it now.
        guard isCurrent else { return }
        try? FileManager.default.removeItem(atPath: master.controlPath)
        let restart: (Master, Int)? = lock.withLock {
            guard master.generation == generation else { return nil }
            master.process = nil
            let previous = master.phase
            // A master that stayed up a while starts the backoff over; one
            // that died soon after logging in doubles it.
            let stayedUp = master.upSince.map { Date().timeIntervalSince($0) >= configuration.stableUptime } == true
            if previous != .stopping {
                master.failures = stayedUp ? 1 : master.failures + 1
                if !errors.isEmpty { master.lastError = errors }
            } else if stayedUp {
                master.failures = 0
            }
            master.upSince = nil
            resumeWaitersLocked(master, with: nil)
            master.phase = .stopped
            guard master.isNeeded else { return nil }
            if previous == .stopping { return beginStartLocked(master) }
            // Never up: it could not connect or log in, and trying on a timer
            // would only add failed logins (which the server may count).
            guard previous == .up else { return nil }
            master.phase = .waitingToRestart
            let delay = min(
                configuration.restartDelay.initial * pow(2, Double(max(master.failures, 1) - 1)),
                configuration.restartDelay.maximum
            )
            let work = DispatchWorkItem { [weak self] in self?.restartIfNeeded(master, after: generation) }
            master.restart = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
            return nil
        }
        if let restart { launch(restart.0, generation: restart.1) }
    }

    private func restartIfNeeded(_ master: Master, after generation: Int) {
        let start: (Master, Int)? = lock.withLock {
            guard master.generation == generation, master.phase == .waitingToRestart else { return nil }
            master.phase = .stopped
            return beginStartLocked(master)
        }
        if let start { launch(start.0, generation: start.1) }
    }

    private func scheduleIdleStopLocked(_ master: Master) {
        guard !master.isNeeded, master.idleStop == nil else { return }
        switch master.phase {
        case .stopped, .stopping:
            return
        case .waitingToRestart:
            master.restart?.cancel()
            master.restart = nil
            master.phase = .stopped
            return
        case .starting, .up:
            break
        }
        let work = DispatchWorkItem { [weak self] in self?.stopIfIdle(master) }
        master.idleStop = work
        queue.asyncAfter(deadline: .now() + configuration.idleStopDelay, execute: work)
    }

    private func stopIfIdle(_ master: Master) {
        let stop: (process: HostSignallableProcess?, wasUp: Bool, environment: [String: String])? = lock.withLock {
            master.idleStop = nil
            guard !master.isNeeded, master.phase == .starting || master.phase == .up else { return nil }
            let wasUp = master.phase == .up
            master.phase = .stopping
            resumeWaitersLocked(master, with: nil)
            return (master.process, wasUp, master.environment)
        }
        guard let stop else { return }
        if stop.wasUp {
            _ = HostSpawnedProcess.run(
                executable: configuration.sshExecutable(stop.environment),
                arguments: Self.commandArguments("exit", destination: master.destination, controlPath: master.controlPath),
                environment: stop.environment,
                timeout: configuration.commandTimeout
            )
        }
        // Signals reach it only while it has not exited.
        stop.process?.escalateTermination(grace: stop.wasUp ? 1 : 0.01)
    }

    private func check(destination: String, controlPath: String, environment: [String: String]) -> Bool {
        HostSpawnedProcess.run(
            executable: configuration.sshExecutable(environment),
            arguments: Self.commandArguments("check", destination: destination, controlPath: controlPath),
            environment: environment,
            timeout: configuration.commandTimeout
        ).exitCode == 0
    }

    private func resumeWaiter(_ id: UUID, destination: String, with value: String?) {
        let continuation = lock.withLock { masters[destination]?.waiters.removeValue(forKey: id) }
        continuation?.resume(returning: value)
    }

    private func resumeWaitersLocked(_ master: Master, with value: String?) {
        let waiters = master.waiters.values
        master.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }

    // MARK: Commands and paths

    /// ssh expands `%` tokens in ControlPath.
    static func controlPathOption(_ path: String) -> String {
        "ControlPath=" + path.replacingOccurrences(of: "%", with: "%%")
    }

    static func masterArguments(destination: String, controlPath: String) -> [String] {
        [
            "-M", "-N", "-T",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", controlPathOption(controlPath),
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ClearAllForwardings=yes",
            "-o", "RemoteCommand=none",
            "-o", "PermitLocalCommand=no",
            "-o", "BatchMode=yes",
            "--", destination
        ]
    }

    /// `ssh -O <command>` against the master's socket.
    static func commandArguments(_ command: String, destination: String, controlPath: String) -> [String] {
        ["-o", controlPathOption(controlPath), "-o", "BatchMode=yes", "-O", command, "--", destination]
    }

    /// ssh binds the socket at `<path>.<16 random characters>` before
    /// renaming it, and a Unix socket path holds at most 103 bytes.
    static let maximumControlPathBytes = 103 - 17

    /// A short, fixed name per destination. Nil when the path would be too
    /// long for a socket or holds characters ssh's option parser splits on.
    static func controlPath(in directory: URL, destination: String) -> String? {
        let digest = SHA256.hash(data: Data(destination.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let path = directory.path + "/" + name
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        guard path.utf8.count <= maximumControlPathBytes,
              path.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return path
    }

    static let directoryPrefix = "cherry-ssh-"

    /// Where socket directories may be: the temporary directory, else `/tmp`.
    static var candidateParentDirectories: [URL] {
        [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp", isDirectory: true)]
    }

    /// `$TMPDIR/cherry-ssh-<pid>`, private to this app run; `/tmp` when the
    /// temporary directory's path is too long for a socket. Directories of
    /// app runs that ended are cleaned up first (`sweepAbandonedMasters`),
    /// stopping masters a crashed app left running.
    static func defaultDirectory() -> URL? {
        let name = "\(directoryPrefix)\(getpid())"
        sweepAbandonedMasters()
        for parent in candidateParentDirectories {
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            guard controlPath(in: directory, destination: "") != nil, makePrivateDirectory(directory) else { continue }
            return directory
        }
        return nil
    }

    /// Creates `directory` with mode 0700, or accepts an existing one only
    /// when it is a real directory this user owns that nobody else can use.
    static func makePrivateDirectory(_ directory: URL) -> Bool {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { return false }
        var status = stat()
        guard lstat(directory.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFDIR && status.st_uid == geteuid() && status.st_mode & 0o077 == 0
    }

    /// Stops masters left by app runs that are no longer running, and
    /// removes their directories. A master's destination is not needed:
    /// `ssh -O exit` only talks to the socket.
    static func removeAbandonedDirectories(
        in parent: URL,
        currentPID: pid_t = getpid(),
        isRunning: (pid_t) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM },
        stopMaster: (String) -> Void = { socket in
            _ = HostSpawnedProcess.run(
                executable: "/usr/bin/ssh",
                arguments: commandArguments("exit", destination: "cherry-ssh-master", controlPath: socket),
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2
            )
        }
    ) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(directoryPrefix) {
            guard let pid = pid_t(name.dropFirst(directoryPrefix.count)), pid > 0, pid != currentPID,
                  !isRunning(pid)
            else { continue }
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid()
            else { continue }
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let socket = directory.appendingPathComponent(entry).path
                var entryStatus = stat()
                if lstat(socket, &entryStatus) == 0, entryStatus.st_mode & S_IFMT == S_IFSOCK {
                    stopMaster(socket)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The ssh on the login shell's PATH (as the CLI's ssh would be), else
    /// the system's.
    static func sshExecutable(in environment: [String: String]) -> String {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = "\(directory)/ssh"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/ssh"
    }
}

/// Keeps an SSH master running while held. Releasing twice is harmless.
final class HostSSHMasterLease: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { release() }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onRelease = nil }
            return onRelease
        }
        action?()
    }
}
