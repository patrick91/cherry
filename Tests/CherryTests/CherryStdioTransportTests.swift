import Darwin
import Foundation
import Testing

@testable import CherryMCP

@Suite("Cherry stdio transport")
struct CherryStdioTransportTests {
    @Test func receivesNewlineDelimitedMessages() async throws {
        let inputPipe = try TestPipe()
        let outputPipe = try TestPipe()
        defer {
            inputPipe.close()
            outputPipe.close()
        }

        let transport = CherryStdioTransport(
            inputFileDescriptor: inputPipe.read,
            outputFileDescriptor: outputPipe.write
        )
        try await transport.connect()

        let stream = await transport.receive()
        let receiveTask = Task { () throws -> Data? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try inputPipe.write(#"{"jsonrpc":"2.0"}"#.data(using: .utf8)! + Data([0x0A]))

        let received = try await withTimeout(.seconds(1)) {
            try await receiveTask.value
        }

        #expect(received == #"{"jsonrpc":"2.0"}"#.data(using: .utf8)!)
        await transport.disconnect()
    }

    @Test func appendsNewlineWhenSendingMessages() async throws {
        let inputPipe = try TestPipe()
        let outputPipe = try TestPipe()
        defer {
            inputPipe.close()
            outputPipe.close()
        }

        let transport = CherryStdioTransport(
            inputFileDescriptor: inputPipe.read,
            outputFileDescriptor: outputPipe.write
        )
        try await transport.connect()

        try await transport.send(#"{"id":1}"#.data(using: .utf8)!)

        let sent = try outputPipe.readAvailable(timeoutMilliseconds: 1_000)
        #expect(sent == #"{"id":1}"#.data(using: .utf8)! + Data([0x0A]))
        await transport.disconnect()
    }
}

private struct TestPipe {
    let read: Int32
    let write: Int32

    init() throws {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        read = fds[0]
        write = fds[1]
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(write, baseAddress.advanced(by: offset), data.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    func readAvailable(timeoutMilliseconds: Int32) throws -> Data {
        var descriptor = pollfd(fd: read, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMilliseconds)
        guard ready > 0 else {
            throw TestTimeout.timedOut
        }
        guard descriptor.revents & Int16(POLLIN) != 0 else {
            throw POSIXError(.EIO)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(read, &buffer, buffer.count)
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Data(buffer.prefix(count))
    }

    func close() {
        _ = Darwin.close(read)
        _ = Darwin.close(write)
    }
}

private enum TestTimeout: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestTimeout.timedOut
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
