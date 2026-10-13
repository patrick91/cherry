import Darwin

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
}

extension CherryControl {
    /// `[pid, ppid, …]` up the process tree, via sysctl: at most `maxDepth`
    /// parents, ending below launchd. The app finds a caller's tab from its
    /// peer's ancestry; CherryMCP finds its own tab from its own.
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
