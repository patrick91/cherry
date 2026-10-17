import Darwin
import Foundation

/// Descriptor and Unix-domain socket helpers the control socket's two
/// ends share: the app (`CherryControlServer`) and its callers
/// (`CherryControlClient`, CherryMCP).
public enum UnixIO {
    /// No program this process starts inherits `fd`.
    public static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    /// A write to a peer that went away fails with EPIPE, never SIGPIPE.
    public static func setNoSigPipe(_ fd: Int32) {
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Calls `body` with `path` as a Unix-domain socket address (for
    /// `bind` or `connect`) and its length. Nil, without calling `body`,
    /// when the path does not fit in `sun_path`.
    public static func withSocketAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else { return nil }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { pathPointer in
                let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                strncpy(rawPointer, pathPointer, maximumPathLength)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result: T = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                body(socketAddress, length)
            }
        }
        return result
    }

    // MARK: Whose socket it is
    //
    // Rust's rules (`cherry_protocol::verify_private_dir`,
    // `verify_socket_path`, `verify_peer`): a socket is trusted only in a
    // directory of this user's that no one else may enter, and only while
    // the process behind it is this user's. Another account can create a
    // predictable /tmp path first and answer this user's agents from it.

    /// `socket_not_private`, with why.
    public static func socketNotPrivate(_ reason: String) -> CherryControlError {
        CherryControlError(code: "socket_not_private", message: "Cherry's control socket is not private to this user: \(reason).")
    }

    /// Why a directory `lstat` described as `status` cannot hold a socket
    /// this user trusts, nil when it can: a real directory (not a link),
    /// owned by `userID`, with none of `forbiddenModeBits` set (0o077: no
    /// one else may enter it, as a socket's own directory must be).
    public static func directoryProblem(
        _ path: String,
        status: stat,
        forbiddenModeBits: mode_t = 0o077,
        userID: uid_t = geteuid()
    ) -> String? {
        guard status.st_mode & S_IFMT == S_IFDIR else { return "\(path) is not a real directory" }
        guard status.st_uid == userID else {
            return "\(path) is owned by uid \(status.st_uid), not this user; another account may have created it. Remove it or set \(CherryControl.socketEnvironmentKey) to a private path"
        }
        guard status.st_mode & forbiddenModeBits == 0 else {
            let mode = String(status.st_mode & 0o777, radix: 8)
            return forbiddenModeBits & 0o044 != 0
                ? "\(path) must be private (mode 0700, not \(mode))"
                : "\(path) must not be writable by other accounts (mode \(mode))"
        }
        return nil
    }

    /// `path` exists, is not a link, is this user's and is closed to
    /// everyone else (`directoryProblem`). Throws `POSIXError(.ENOENT)` when
    /// it, or a directory above it, does not exist (nothing listens there),
    /// else `socket_not_private`.
    public static func verifyPrivateDirectory(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            let error = errno
            if error == ENOENT || error == ENOTDIR { throw POSIXError(.ENOENT) }
            throw socketNotPrivate("\(path) cannot be looked at (\(String(cString: strerror(error))))")
        }
        if let problem = directoryProblem(path, status: status) { throw socketNotPrivate(problem) }
    }

    /// When `path` exists, it is a socket this user owns; else
    /// `socket_not_private`. Links are followed: a forward from another Mac
    /// can be a link inside a private directory (only this user can put one
    /// there).
    public static func verifySocket(_ path: String) throws {
        var status = stat()
        guard stat(path, &status) == 0 else {
            let error = errno
            if error == ENOENT || error == ENOTDIR { return }
            throw socketNotPrivate("\(path) cannot be looked at (\(String(cString: strerror(error))))")
        }
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == geteuid() else {
            throw socketNotPrivate("\(path) is not a socket owned by this user")
        }
    }

    /// The effective uid of the process on the other end of a connected
    /// Unix-domain socket, as it was when it connected; nil when it cannot
    /// be read.
    public static func peerUserID(fileDescriptor fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// When process `pid` started, as a token another process with the same
    /// pid (once it was reused) never has: `seconds.microseconds`, exactly
    /// `cherry_protocol::start_identity`'s format. A process of another
    /// user, which `proc_pidinfo` does not describe (root's: a native tab's
    /// login(1)), is read with sysctl, which gives the same start. Nil when
    /// there is no such process.
    public static func processStartIdentity(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return startIdentity(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec))
        }
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &process, &length, nil, 0) == 0, length > 0,
              process.kp_proc.p_pid == pid
        else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        return startIdentity(seconds: Int64(start.tv_sec), microseconds: Int64(start.tv_usec))
    }

    private static func startIdentity(seconds: Int64, microseconds: Int64) -> String {
        "\(seconds)." + String(format: "%06lld", microseconds)
    }

    /// Whether a server accepts connections at `path` now. A listener costs
    /// up to `timeout`, the time it gets to answer, and so does a stale
    /// socket file (its server gone): a listener whose backlog is full
    /// refuses a connection as a stale file does (ECONNREFUSED), so a
    /// refusal is tried again until `timeout` (a busy server accepts the
    /// connections queued meanwhile; a stale file refuses every time).
    ///
    /// The probe sends an empty line (an invalid request to every Cherry,
    /// with no effect) and stays until the answer or `timeout`: a peer that
    /// is gone before the server accepts its connection leaves that
    /// connection without SO_NOSIGPIPE (the kernel refuses the option), and
    /// a Cherry before MSG_NOSIGNAL would get SIGPIPE answering it.
    public static func hasListener(atPath path: String, timeout: Double = 0.2) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1_000_000_000)
        while true {
            switch probeListener(atPath: path, deadline: deadline) {
            case .listening:
                return true
            case .absent:
                return false
            case .refused:
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                usleep(UInt32(min(20_000, (deadline - now) / 1_000)))
            }
        }
    }

    private enum ListenerProbe {
        case listening
        case absent
        /// ECONNREFUSED: no server, or one whose backlog is full.
        case refused
    }

    private static func probeListener(atPath path: String, deadline: UInt64) -> ListenerProbe {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .absent }
        defer { close(fd) }
        setCloseOnExec(fd)
        setNoSigPipe(fd)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        func remainingMilliseconds() -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= deadline ? 0 : Int32((deadline - now) / 1_000_000)
        }

        guard let result = withSocketAddress(path: path, { Darwin.connect(fd, $0, $1) }) else { return .absent }
        if result != 0 {
            if errno == ECONNREFUSED { return .refused }
            guard errno == EINPROGRESS || errno == EAGAIN else { return .absent }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            // A listener that does not complete the connection counts as one.
            guard poll(&poller, 1, remainingMilliseconds()) > 0 else { return .listening }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return .absent }
            if error == ECONNREFUSED { return .refused }
            guard error == 0 else { return .absent }
        }

        // Any answer, or the server closing, means it accepted.
        var newline: UInt8 = 0x0A
        _ = send(fd, &newline, 1, MSG_NOSIGNAL)
        _ = shutdown(fd, SHUT_WR)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&poller, 1, remainingMilliseconds()) < 0, errno == EINTR {}
        return .listening
    }

    /// A file as the file system knows it, whatever its name: a server
    /// removes the socket it bound only while its path is still that file
    /// (never another server's that took the path since).
    public struct FileIdentity: Equatable, Sendable {
        public let device: dev_t
        public let inode: ino_t

        /// The file at `path` itself (a link is not followed); nil when
        /// there is none.
        public init?(path: String) {
            var status = stat()
            guard lstat(path, &status) == 0 else { return nil }
            device = status.st_dev
            inode = status.st_ino
        }
    }

    /// Removes `path` only while it is still the file `identity` names.
    public static func removeFile(atPath path: String, ifStill identity: FileIdentity) {
        guard FileIdentity(path: path) == identity else { return }
        unlink(path)
    }
}

extension CherryControl {
    /// `[pid, ppid, …]` up the process tree, via sysctl: at most `maxDepth`
    /// parents, ending below launchd. The app pins a caller's peer's when it
    /// connects (`CallerProcessChain`) and finds its tab from it; a legacy
    /// CherryMCP (against an app without `appInfo`) finds its own tab from
    /// its own.
    public static func processAncestry(of pid: Int32, maxDepth: Int = 20) -> [Int32] {
        var result: [Int32] = [pid]
        var seen: Set<Int32> = [pid]
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentProcessID(of: current), parent > 1, !seen.contains(parent) else { break }
            result.append(parent)
            seen.insert(parent)
            current = parent
        }
        return result
    }

    private static func parentProcessID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
