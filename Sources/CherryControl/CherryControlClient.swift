import Darwin
import Foundation

public struct CherryControlClient: Sendable {
    public let socketURL: URL

    public init(socketURL: URL = CherryControl.socketURL) {
        self.socketURL = socketURL
    }

    public func send(_ request: CherryControlRequest) throws -> CherryControlResponse {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(request) + Data([0x0A])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CherryControlError(code: "socket_failed", message: "Failed to create local socket.")
        }
        defer {
            close(fd)
        }

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
                } else {
                    throw CherryControlError(code: "write_failed", message: "Failed to write Cherry control request.")
                }
            }
        }
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
