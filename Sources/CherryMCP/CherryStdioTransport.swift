import Darwin
import Foundation
import Logging
import MCP

public actor CherryStdioTransport: Transport {
    public nonisolated let logger: Logger

    private let inputFileDescriptor: Int32
    private let outputFileDescriptor: Int32
    private let readQueue = DispatchQueue(label: "CherryMCP.StdioTransport.read")
    private let readState: CherryStdioReadState
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var isConnected = false
    private var readSource: DispatchSourceRead?

    public init(
        inputFileDescriptor: Int32 = STDIN_FILENO,
        outputFileDescriptor: Int32 = STDOUT_FILENO,
        logger: Logger? = nil
    ) {
        let resolvedLogger = logger ?? Logger(
            label: "cherry.mcp.transport.stdio",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Swift.Error> { continuation = $0 }

        self.inputFileDescriptor = inputFileDescriptor
        self.outputFileDescriptor = outputFileDescriptor
        self.logger = resolvedLogger
        messageStream = stream
        messageContinuation = continuation
        readState = CherryStdioReadState(
            inputFileDescriptor: inputFileDescriptor,
            continuation: continuation,
            logger: resolvedLogger
        )
    }

    public func connect() async throws {
        guard !isConnected else { return }

        try setNonBlocking(fileDescriptor: inputFileDescriptor)

        let source = DispatchSource.makeReadSource(fileDescriptor: inputFileDescriptor, queue: readQueue)
        source.setEventHandler { [readState, weak source] in
            if readState.readAvailableData() {
                source?.cancel()
            }
        }
        source.setCancelHandler { [readState] in
            readState.finish()
        }

        readSource = source
        isConnected = true
        source.resume()
        logger.debug("Transport connected successfully")
    }

    public func disconnect() async {
        guard isConnected else { return }

        isConnected = false
        readSource?.cancel()
        readSource = nil
        readState.finish()
        logger.debug("Transport disconnected")
    }

    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw transportError()
        }

        var message = data
        message.append(UInt8(ascii: "\n"))

        try message.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < message.count {
                let written = Darwin.write(
                    outputFileDescriptor,
                    baseAddress.advanced(by: offset),
                    message.count - offset
                )

                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw transportError()
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private func setNonBlocking(fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw transportError()
        }

        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw transportError()
        }
    }
}

private final class CherryStdioReadState: @unchecked Sendable {
    private let inputFileDescriptor: Int32
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let logger: Logger
    private let finishLock = NSLock()

    private var pendingData = Data()
    private var didFinish = false

    init(
        inputFileDescriptor: Int32,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        logger: Logger
    ) {
        self.inputFileDescriptor = inputFileDescriptor
        self.continuation = continuation
        self.logger = logger
    }

    func readAvailableData() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while !isFinished {
            let count = Darwin.read(inputFileDescriptor, &buffer, buffer.count)

            if count > 0 {
                append(buffer: buffer, count: count)
            } else if count == 0 {
                logger.notice("EOF received")
                finish()
                return true
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                finish(throwing: transportError())
                return true
            }
        }

        return true
    }

    func finish(throwing error: Swift.Error? = nil) {
        finishLock.lock()
        guard !didFinish else {
            finishLock.unlock()
            return
        }
        didFinish = true
        finishLock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private var isFinished: Bool {
        finishLock.lock()
        defer { finishLock.unlock() }
        return didFinish
    }

    private func append(buffer: [UInt8], count: Int) {
        pendingData.append(contentsOf: buffer.prefix(count))

        while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let messageData = pendingData[..<newlineIndex]
            pendingData = pendingData[pendingData.index(after: newlineIndex)...]

            if !messageData.isEmpty {
                continuation.yield(Data(messageData))
            }
        }
    }
}

private func transportError() -> MCPError {
    MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
}
