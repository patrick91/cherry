import CherryControl
import Darwin
import Foundation
import MCP
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

    /// What the tool-list transport answers for a provider's tools is what
    /// the server's own handler answers for the same tools
    /// (`CherryMCPSession.serve` gives both the session's list).
    @Test func toolListResponseIsTheServersResponse() async throws {
        let inputPipe = try TestPipe()
        let outputPipe = try TestPipe()
        defer {
            inputPipe.close()
            outputPipe.close()
        }

        let provider: @Sendable () async -> [CherryToolDefinition] = { CherryToolCatalog.tools(for: .unknown) }
        let server = Server(name: "cherry", version: "test", capabilities: .init(tools: .init(listChanged: true)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: await provider().map(CherryMCPTools.sdkTool))
        }
        try await server.start(transport: CherryStdioTransport(
            inputFileDescriptor: inputPipe.read,
            outputFileDescriptor: outputPipe.write
        ))

        for request in [
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":"list/1","method":"tools/list","params":{"cursor":"next"}}"#,
        ] {
            try inputPipe.write(Data(request.utf8) + Data([0x0A]))
            let fromServer = try outputPipe.readLine(timeoutMilliseconds: 5_000)
            let id = try #require(CherryMCPTools.listRequestID(in: Data(request.utf8)))
            let answered = try #require(CherryMCPTools.listResponse(id: id, result: CherryToolCatalog.encodedListResult(await provider())))
            #expect(try JSONDecoder().decode(Value.self, from: answered) == JSONDecoder().decode(Value.self, from: fromServer))
            let cached = try #require(CherryMCPTools.listResponse(answering: Data(request.utf8)))
            #expect(cached == answered)
        }
        await server.stop()
    }

    @Test func toolListTransportAnswersToolsListAndPassesOtherMessagesOn() async throws {
        let inputPipe = try TestPipe()
        let outputPipe = try TestPipe()
        defer {
            inputPipe.close()
            outputPipe.close()
        }

        let transport = CherryMCPToolListTransport(
            base: CherryStdioTransport(
                inputFileDescriptor: inputPipe.read,
                outputFileDescriptor: outputPipe.write
            ),
            list: { CherryMCPTools.encodedListResult }
        )
        try await transport.connect()

        let stream = await transport.receive()
        let receiveTask = Task { () throws -> [Data] in
            var received: [Data] = []
            for try await message in stream {
                received.append(message)
                if received.count == 4 { break }
            }
            return received
        }

        let passedOn = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_process_input","arguments":{"text":"tools/list"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":"not parameters"}"#,
            #"[{"jsonrpc":"2.0","id":4,"method":"tools/list"}]"#,
        ]
        let messages = [passedOn[0], passedOn[1], #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#, passedOn[2], passedOn[3]]
        try inputPipe.write(Data(messages.joined(separator: "\n").utf8) + Data([0x0A]))

        let response = try JSONDecoder().decode(Value.self, from: outputPipe.readLine(timeoutMilliseconds: 5_000))
        #expect(response.objectValue?["id"] == .string("a"))
        #expect(response.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == CherryMCPTools.all.count)

        let received = try await withTimeout(.seconds(5)) {
            try await receiveTask.value
        }
        #expect(received == passedOn.map { Data($0.utf8) })
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

    /// Reads until a newline and returns the line without it.
    func readLine(timeoutMilliseconds: Int32) throws -> Data {
        var line = Data()
        while true {
            let chunk = try readAvailable(timeoutMilliseconds: timeoutMilliseconds)
            guard !chunk.isEmpty else {
                throw POSIXError(.EPIPE)
            }
            line.append(chunk)
            if let newline = line.firstIndex(of: 0x0A) {
                return line[..<newline]
            }
        }
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
