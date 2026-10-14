import Foundation
import Logging
import MCP

extension CherryMCPTools {
    /// The `result` of a `tools/list` response, encoded once: the tools never
    /// change while the helper runs (the server says `listChanged: false`).
    static let encodedListResult: Data? = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(ListTools.Result(tools: all))
    }()

    /// The response to `message` when it is a `tools/list` request, as the
    /// server would encode it; nil for any other message.
    public static func listResponse(answering message: Data) -> Data? {
        // Most messages never name the method: they skip the decode.
        guard message.range(of: Data(ListTools.name.utf8)) != nil,
              let request = try? JSONDecoder().decode(ListToolsRequest.self, from: message),
              request.jsonrpc == "2.0",
              request.method == ListTools.name,
              let result = encodedListResult
        else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let id = try? encoder.encode(request.id) else { return nil }

        var response = Data(#"{"id":"#.utf8)
        response.append(id)
        response.append(contentsOf: #","jsonrpc":"2.0","result":"#.utf8)
        response.append(result)
        response.append(UInt8(ascii: "}"))
        return response
    }
}

/// The fields of a request that `listResponse(answering:)` checks. Parameters
/// the SDK would refuse send the request on to the server, which answers it.
private struct ListToolsRequest: Decodable {
    let jsonrpc: String
    let id: ID
    let method: String
    let params: ListTools.Parameters?
}

/// Answers `tools/list` requests itself, from `CherryMCPTools.listResponse`,
/// and hands every other message to the server. The SDK's handler re-decodes
/// each result into `Value`, matching a regex against every string in it:
/// 13–23 ms for Cherry's tools on every list. The server's own `ListTools`
/// handler still answers what this passes on (a batch, an escaped method).
public actor CherryMCPToolListTransport: Transport {
    public nonisolated let logger: Logger

    private let base: any Transport
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var forwarding: Task<Void, Never>?

    public init(base: any Transport, logger: Logger? = nil) {
        self.base = base
        self.logger = logger ?? Logger(
            label: "cherry.mcp.transport.tool-list",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard forwarding == nil else { return }

        try await base.connect()
        let incoming = await base.receive()
        forwarding = Task { [base, continuation] in
            do {
                for try await message in incoming {
                    if let response = CherryMCPTools.listResponse(answering: message) {
                        // As the server does, a response that cannot be written is dropped.
                        try? await base.send(response)
                    } else {
                        continuation.yield(message)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func disconnect() async {
        await base.disconnect()
        forwarding?.cancel()
        forwarding = nil
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        try await base.send(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messages
    }
}
