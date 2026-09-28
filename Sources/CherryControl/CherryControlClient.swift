import Darwin
import Foundation

public struct CherryControlClient: Sendable {
    public let socketURL: URL
    public let timeout: TimeInterval
    /// A tab of another Mac's token and id, sent with every request
    /// (`CherryControlEnvelope`); nil for This Mac's callers, which the app
    /// identifies by their process.
    public let credentials: CherryControlCredentials?
    /// The Mac Cherry runs on, when this caller reaches it through a
    /// forward (for "Cherry on <Mac> is not reachable").
    public let controlMachine: String?

    public init(
        socketURL: URL = CherryControl.socketURL,
        timeout: TimeInterval = 10,
        credentials: CherryControlCredentials? = CherryControlCredentials.fromEnvironment(),
        controlMachine: String? = ProcessInfo.processInfo.environment[CherryControl.controlMachineEnvironmentKey]
    ) {
        self.socketURL = socketURL
        self.timeout = max(timeout, 0.1)
        self.credentials = credentials
        self.controlMachine = controlMachine?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyString
    }

    /// "Cherry on <Mac> is not reachable": the forward of its control
    /// socket to this Mac is down (Cherry quit, the Mac slept or went
    /// offline, the SSH connection is being made again).
    private func unreachable(_ detail: String) -> CherryControlError {
        let machine = controlMachine ?? "the other Mac"
        return CherryControlError(
            code: "cherry_unreachable",
            message: "Cherry on \(machine) is not reachable (\(detail)). Its connection to this Mac comes back when Cherry there reconnects."
        )
    }

    public func send(_ request: CherryControlRequest) throws -> CherryControlResponse {
        do {
            return try sendOnce(request)
        } catch let error as CherryControlError where credentials != nil {
            switch error.code {
            case "cherry_unavailable": throw unreachable("its control socket \(socketURL.path) did not answer")
            case "empty_response", "read_failed", "write_failed": throw unreachable("the connection closed without an answer")
            default: throw error
            }
        }
    }

    private func sendOnce(_ request: CherryControlRequest) throws -> CherryControlResponse {
        let encoder = JSONEncoder()
        let body: Data = if let credentials {
            try encoder.encode(CherryControlEnvelope(cherryAuth: credentials, request: request))
        } else {
            try encoder.encode(request)
        }
        let payload = body + Data([0x0A])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CherryControlError(code: "socket_failed", message: "Failed to create local socket.")
        }
        setCloseOnExec(fileDescriptor: fd)
        // A server that refused the request before reading it (and closed)
        // makes the write fail with EPIPE, never SIGPIPE; its answer is
        // still read.
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        defer {
            close(fd)
        }

        try configureTimeouts(fileDescriptor: fd)
        try connect(fileDescriptor: fd)
        try writeAll(payload, to: fd)
        _ = shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response.last == 0x0A {
                    break
                }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw CherryControlError(code: "request_timed_out", message: "Timed out waiting for Cherry response.")
            } else {
                throw CherryControlError(code: "read_failed", message: "Failed to read Cherry response.")
            }
        }

        guard !response.isEmpty else {
            throw CherryControlError(code: "empty_response", message: "Cherry closed the control connection without a response.")
        }

        if response.last == 0x0A {
            response.removeLast()
        }

        return try JSONDecoder().decode(CherryControlResponse.self, from: response)
    }

    private func configureTimeouts(fileDescriptor fd: Int32) throws {
        let wholeSeconds = Int(timeout.rounded(.towardZero))
        let microseconds = Int((timeout - Double(wholeSeconds)) * 1_000_000)
        var value = timeval(tv_sec: wholeSeconds, tv_usec: Int32(microseconds))
        let length = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, length) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, length) == 0
        else {
            throw CherryControlError(code: "socket_failed", message: "Failed to configure Cherry control socket timeout.")
        }
    }

    private func connect(fileDescriptor fd: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            throw CherryControlError(code: "socket_path_too_long", message: "Cherry control socket path is too long: \(path)")
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { pathPointer in
                let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                strncpy(rawPointer, pathPointer, maximumPathLength)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, length)
            }
        }

        guard result == 0 else {
            throw CherryControlError(
                code: "cherry_unavailable",
                message: "Could not connect to Cherry at \(path). Make sure the Cherry app is running."
            )
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EPIPE {
                    // The server answered and closed early: read its answer.
                    return
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw CherryControlError(code: "request_timed_out", message: "Timed out writing Cherry control request.")
                } else {
                    throw CherryControlError(code: "write_failed", message: "Failed to write Cherry control request.")
                }
            }
        }
    }

    private func setCloseOnExec(fileDescriptor fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }
}

private extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
