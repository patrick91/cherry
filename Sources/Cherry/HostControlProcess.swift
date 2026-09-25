import Darwin
import Foundation

/// A helper process the session control plane starts: `cherry control`, an
/// SSH master, or a short `ssh -O` command. It runs in a session of its own,
/// so it never shares the terminal Cherry may have been started from (and an
/// interactive prompt can never block on it), and it inherits only the pipes
/// asked for: every other descriptor is closed.
struct HostSpawnedProcess: Sendable {
    let pid: pid_t
    /// The app's end of the child's standard input, or -1 (then /dev/null).
    /// Writing after the child closed it fails with EPIPE, never SIGPIPE.
    let input: Int32
    /// The app's end of the child's standard output, or -1 (then /dev/null).
    let output: Int32
    /// The app's end of the child's standard error, or -1 (then /dev/null).
    let errors: Int32

    struct SpawnError: Error, LocalizedError {
        let executable: String
        let code: Int32

        var errorDescription: String? {
            "Could not start \(executable): \(String(cString: strerror(code)))."
        }
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String = NSHomeDirectory(),
        input wantsInput: Bool = false,
        output wantsOutput: Bool = false,
        errors wantsErrors: Bool = false
    ) throws -> HostSpawnedProcess {
        var parentEnds: [Int32] = []
        var childEnds: [Int32] = []
        func makePipe(childReads: Bool) throws -> (parent: Int32, child: Int32) {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw SpawnError(executable: executable, code: errno) }
            for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            let ends = childReads ? (parent: descriptors[1], child: descriptors[0]) : (parent: descriptors[0], child: descriptors[1])
            parentEnds.append(ends.parent)
            childEnds.append(ends.child)
            return ends
        }
        func closeAll(_ descriptors: [Int32]) { descriptors.forEach { close($0) } }

        var input: (parent: Int32, child: Int32)?
        var output: (parent: Int32, child: Int32)?
        var errors: (parent: Int32, child: Int32)?
        do {
            if wantsInput {
                input = try makePipe(childReads: true)
                _ = fcntl(input!.parent, F_SETNOSIGPIPE, 1)
            }
            if wantsOutput { output = try makePipe(childReads: false) }
            if wantsErrors { errors = try makePipe(childReads: false) }
        } catch {
            closeAll(parentEnds + childEnds)
            throw error
        }
        defer { closeAll(childEnds) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (descriptor, pipe, flags) in [
            (Int32(0), input, O_RDONLY), (Int32(1), output, O_WRONLY), (Int32(2), errors, O_WRONLY)
        ] {
            if let pipe {
                posix_spawn_file_actions_adddup2(&actions, pipe.child, descriptor)
            } else {
                posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", flags, 0)
            }
        }
        posix_spawn_file_actions_addchdir(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        ))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0, pid > 1 else {
            closeAll(parentEnds)
            throw SpawnError(executable: executable, code: result == 0 ? EINVAL : result)
        }
        return HostSpawnedProcess(
            pid: pid, input: input?.parent ?? -1, output: output?.parent ?? -1, errors: errors?.parent ?? -1
        )
    }

    /// Blocks until the process exits; returns its wait status.
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        return status
    }

    /// The exit code of a normal exit, else nil (signalled or not waited).
    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        // WIFEXITED / WEXITSTATUS, which Swift does not import.
        status != -1 && status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }

    /// Blocks until the process has exited, without reaping it: until it is
    /// reaped (`waitForExit`), it stays a zombie and its pid cannot be
    /// reused.
    static func waitUntilExited(_ pid: pid_t) {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 {
            guard errno == EINTR else { return }
        }
    }

    /// Runs a short command to completion: its exit code (nil when it was
    /// signalled, could not start, or outlived `timeout` and was killed) and
    /// the start of its standard error.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> (exitCode: Int32?, errors: String) {
        guard let process = try? spawn(
            executable: executable, arguments: arguments, environment: environment, errors: true
        ) else { return (nil, "") }
        defer { close(process.errors) }
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        reading: while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: process.errors, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1_000) + 1)
            if ready < 0, errno != EINTR { break }
            guard ready > 0 else { continue }
            let count = read(process.errors, &buffer, buffer.count)
            switch count {
            case 0: break reading
            case ..<0: if errno != EINTR && errno != EAGAIN { break reading }
            default: if collected.count < 16_384 { collected.append(contentsOf: buffer[..<count]) }
            }
        }
        let errors = String(decoding: collected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var status: Int32 = 0
        while true {
            let result = waitpid(process.pid, &status, WNOHANG)
            if result == process.pid { return (exitCode(fromWaitStatus: status), errors) }
            if result == -1, errno != EINTR { return (nil, errors) }
            guard Date() < deadline else {
                _ = kill(-process.pid, SIGKILL)
                _ = kill(process.pid, SIGKILL)
                _ = waitForExit(process.pid)
                return (nil, errors)
            }
            usleep(5_000)
        }
    }
}

/// A spawned child the app signals and reaps. A signal is sent only while
/// the child is not reaped yet: the reaper takes the child's exit without
/// reaping it, marks it exited under the same lock `signal` checks, and
/// only then reaps it. So a signal never reaches a process that reused the
/// pid of a child that exited.
final class HostSignallableProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var exited = false
    private var isReaping = false

    init(pid: pid_t) {
        self.pid = pid
    }

    /// Whether the child exited (and is reaped or about to be).
    var hasExited: Bool { lock.withLock { exited } }

    /// Sends `signal` to the child (and to its process group, which it
    /// leads, with `group`) unless it exited. True when sent.
    @discardableResult
    func signal(_ signal: Int32, group: Bool = false) -> Bool {
        lock.withLock {
            guard !exited else { return false }
            if group { _ = kill(-pid, signal) }
            return kill(pid, signal) == 0
        }
    }

    /// Reaps the child on a thread of its own once it exits, then calls
    /// `onExit` with its wait status there. Once only.
    func startReaping(name: String = "cherry.host-process.reaper", onExit: @escaping @Sendable (Int32) -> Void = { _ in }) {
        let first = lock.withLock { () -> Bool in
            defer { isReaping = true }
            return !isReaping
        }
        guard first else { return }
        let pid = pid
        let thread = Thread { [self] in
            HostSpawnedProcess.waitUntilExited(pid)
            lock.withLock { exited = true }
            onExit(HostSpawnedProcess.waitForExit(pid))
        }
        thread.name = name
        thread.start()
    }

    /// Asks the child to stop: SIGTERM after `grace`, then SIGKILL to its
    /// whole process group after another `grace`, unless it exited first.
    /// Returns at once; the waits happen on a background queue.
    func escalateTermination(grace: TimeInterval = 1) {
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + grace) { [self] in
            guard signal(SIGTERM) else { return }
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                signal(SIGKILL, group: true)
            }
        }
    }
}

/// The last bytes a helper wrote to standard error, for error messages.
final class HostProcessErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var finished = false
    private let finishedSignal = DispatchSemaphore(value: 0)
    private let limit: Int

    init(limit: Int = 16_384) {
        self.limit = limit
    }

    /// Reads `descriptor` to its end on a background thread, then closes it.
    func drain(_ descriptor: Int32) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                lock.withLock {
                    bytes.append(contentsOf: buffer[..<count])
                    if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
                }
            }
            close(descriptor)
            lock.withLock { finished = true }
            finishedSignal.signal()
        }
        thread.name = "cherry.host-control.stderr"
        thread.start()
    }

    /// Waits up to `timeout` for the end of the stream (a helper that is
    /// exiting writes its reason just before).
    func waitForEnd(timeout: TimeInterval) {
        guard !lock.withLock({ finished }) else { return }
        if finishedSignal.wait(timeout: .now() + timeout) == .success { finishedSignal.signal() }
    }

    /// Non-empty lines, trimmed; the most useful message is usually last.
    var text: String {
        let text = lock.withLock { String(decoding: bytes, as: UTF8.self) }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(8)
            .joined(separator: "\n")
    }
}
