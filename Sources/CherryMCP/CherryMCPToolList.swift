import CherryControl
import Foundation
import Logging
import MCP

extension CherryMCPTools {
    /// The `result` of a `tools/list` response with this helper's own tools
    /// for a client it knows nothing of, encoded once. The catalog's
    /// encoding is the bytes the SDK's server encodes for `all`.
    static let encodedListResult: Data? = try? CherryToolCatalog.encodedListResult(
        CherryToolCatalog.tools(for: .unknown)
    )

    /// The response to `message` when it is a `tools/list` request, as the
    /// server would encode it for `encodedListResult`; nil for any other
    /// message.
    public static func listResponse(answering message: Data) -> Data? {
        guard let id = listRequestID(in: message), let result = encodedListResult else {
            return nil
        }
        return listResponse(id: id, result: result)
    }

    /// The id of `message` when it is a `tools/list` request whose
    /// parameters the SDK would accept; nil for any other message.
    static func listRequestID(in message: Data) -> ID? {
        // Most messages never name the method: they skip the decode.
        guard message.range(of: Data(ListTools.name.utf8)) != nil,
              let request = try? JSONDecoder().decode(ListToolsRequest.self, from: message),
              request.jsonrpc == "2.0",
              request.method == ListTools.name
        else {
            return nil
        }
        return request.id
    }

    /// The response to the `tools/list` request `id` whose `result` is
    /// `result` (`CherryToolCatalog.encodedListResult`), as the server
    /// encodes one.
    static func listResponse(id: ID, result: Data) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encodedID = try? encoder.encode(id) else { return nil }

        var response = Data(#"{"id":"#.utf8)
        response.append(encodedID)
        response.append(contentsOf: #","jsonrpc":"2.0","result":"#.utf8)
        response.append(result)
        response.append(UInt8(ascii: "}"))
        return response
    }

    /// The client `message` names when it is an `initialize` request; nil
    /// for any other message.
    static func initializeClient(in message: Data) -> ToolClientInfo? {
        guard message.range(of: Data(Initialize.name.utf8)) != nil,
              let request = try? JSONDecoder().decode(InitializeRequest.self, from: message),
              request.jsonrpc == "2.0",
              request.method == Initialize.name,
              let client = request.params?.clientInfo
        else {
            return nil
        }
        return ToolClientInfo(name: client.name, version: client.version?.nilIfEmpty)
    }

    /// `message` as the SDK decodes it when it is an `initialize` request
    /// whose `capabilities.experimental` is not an object of strings: without
    /// them. MCP gives each experimental capability an object (Codex 0.162
    /// sends `{"codex/auth-change":{}}`), the SDK decodes them as strings
    /// and would refuse the whole request (-32603), so the client could
    /// never connect. The server reads no experimental capability. Any
    /// other message is returned as it is.
    static func initializeTheSDKDecodes(_ message: Data) -> Data {
        guard message.range(of: Data(Initialize.name.utf8)) != nil,
              message.range(of: Data("experimental".utf8)) != nil,
              case .object(var request)? = try? JSONValue.parse(message),
              request["method"] == .string(Initialize.name),
              case .object(var parameters)? = request["params"],
              case .object(var capabilities)? = parameters["capabilities"],
              let experimental = capabilities["experimental"],
              !Self.isObjectOfStrings(experimental)
        else {
            return message
        }
        capabilities["experimental"] = nil
        parameters["capabilities"] = .object(capabilities)
        request["params"] = .object(parameters)
        return (try? JSONEncoder().encode(JSONValue.object(request))) ?? message
    }

    private static func isObjectOfStrings(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            return true
        case .object(let members):
            return members.values.allSatisfy { if case .string = $0 { true } else { false } }
        default:
            return false
        }
    }

    /// The arguments of `message` when it is a `tools/call` request one of
    /// whose arguments the SDK takes for data (a string that looks like a
    /// data URL, which reaches the server's handler re-encoded as base64);
    /// nil for any other message.
    static func callArgumentsTheSDKChanges(in message: Data) -> CherryMCPCallArguments? {
        // Most messages hold no data URL: they skip the decode.
        guard message.range(of: Data(#""data:"#.utf8)) != nil,
              message.range(of: Data(CallTool.name.utf8)) != nil,
              let sdk = try? JSONDecoder().decode(ToolsCallRequest<CallTool.Parameters>.self, from: message),
              sdk.jsonrpc == "2.0", sdk.method == CallTool.name,
              let decoded = sdk.params.arguments, decoded.values.contains(where: holdsData),
              let written = try? JSONDecoder().decode(ToolsCallRequest<WrittenCallParameters>.self, from: message),
              let arguments = written.params.arguments
        else {
            return nil
        }
        return CherryMCPCallArguments(name: sdk.params.name, decoded: decoded, written: arguments)
    }

    /// Whether the SDK decoded part of `value` as data.
    static func holdsData(_ value: Value) -> Bool {
        switch value {
        case .data:
            true
        case .array(let values):
            values.contains(where: holdsData)
        case .object(let members):
            members.values.contains(where: holdsData)
        default:
            false
        }
    }
}

/// A `tools/call`'s arguments as the client wrote them and as the SDK hands
/// them to the server's handler, for a call whose arguments the SDK changed
/// (`callArgumentsTheSDKChanges(in:)`): the handler gets only the second.
public struct CherryMCPCallArguments: Sendable {
    let name: String
    let decoded: [String: Value]
    let written: [String: JSONValue]
}

/// The fields of a `tools/call` request that
/// `callArgumentsTheSDKChanges(in:)` reads.
private struct ToolsCallRequest<Parameters: Decodable>: Decodable {
    let jsonrpc: String
    let method: String
    let params: Parameters
}

/// A `tools/call`'s arguments as JSON.
private struct WrittenCallParameters: Decodable {
    let arguments: [String: JSONValue]?
}

/// The fields of a request that `listRequestID(in:)` checks. Parameters
/// the SDK would refuse send the request on to the server, which answers it.
private struct ListToolsRequest: Decodable {
    let jsonrpc: String
    let id: ID
    let method: String
    let params: ListTools.Parameters?
}

/// The fields of an `initialize` request that name its client.
private struct InitializeRequest: Decodable {
    struct Parameters: Decodable {
        let clientInfo: Client?
    }

    struct Client: Decodable {
        let name: String
        let version: String?
    }

    let jsonrpc: String
    let method: String
    let params: Parameters?
}

/// Answers `tools/list` requests itself, with the result `list` encodes,
/// and hands every other message to the server: an `initialize` as the SDK
/// can decode it (`initializeTheSDKDecodes`), and a `tools/call` whose
/// arguments the SDK changes after `callArguments` got them as written. The SDK's handler
/// re-decodes each result into `Value`, matching a regex against every
/// string in it: 13–23 ms for Cherry's tools on every list. `list` runs in
/// a task of its own (it may ask the app), so the messages behind a
/// `tools/list` reach the server without waiting for it. The client an
/// `initialize` request names is noted (`clientInfo`) before any later
/// message is read, so a `tools/list` sent right behind it is answered for
/// that client. The server's own `ListTools` handler still answers what this
/// passes on (a batch, an escaped method), and a list `list` cannot encode.
public actor CherryMCPToolListTransport: Transport {
    public nonisolated let logger: Logger

    private let base: any Transport
    private let list: @Sendable () async -> Data?
    private let clientInfo: @Sendable (ToolClientInfo) async -> Void
    private let callArguments: @Sendable (CherryMCPCallArguments) async -> Void
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var forwarding: Task<Void, Never>?

    /// `list` gives the `result` of a `tools/list` response
    /// (`CherryToolCatalog.encodedListResult`); `clientInfo` gets the client
    /// of the `initialize` request; `callArguments` the arguments of a
    /// `tools/call` the SDK changes, before the server gets it.
    public init(
        base: any Transport,
        logger: Logger? = nil,
        list: @escaping @Sendable () async -> Data?,
        clientInfo: @escaping @Sendable (ToolClientInfo) async -> Void = { _ in },
        callArguments: @escaping @Sendable (CherryMCPCallArguments) async -> Void = { _ in }
    ) {
        self.base = base
        self.list = list
        self.clientInfo = clientInfo
        self.callArguments = callArguments
        self.logger = logger ?? Logger(
            label: "cherry.mcp.transport.tool-list",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Lists `session`'s tools (`CherryMCPSession.toolList`) for the client
    /// it notes, and keeps the arguments its calls were written with.
    public init(base: any Transport, session: CherryMCPSession, logger: Logger? = nil) {
        self.init(
            base: base,
            logger: logger,
            list: { try? CherryToolCatalog.encodedListResult(await session.toolList()) },
            clientInfo: { await session.noteClient($0) },
            callArguments: { await session.noteCallArguments($0) }
        )
    }

    public func connect() async throws {
        guard forwarding == nil else { return }

        try await base.connect()
        let incoming = await base.receive()
        forwarding = Task { [base, list, clientInfo, callArguments, continuation] in
            do {
                for try await received in incoming {
                    let message = CherryMCPTools.initializeTheSDKDecodes(received)
                    if let id = CherryMCPTools.listRequestID(in: message) {
                        Task {
                            guard let result = await list(),
                                  let response = CherryMCPTools.listResponse(id: id, result: result)
                            else {
                                continuation.yield(message)
                                return
                            }
                            // As the server does, a response that cannot be written is dropped.
                            try? await base.send(response)
                        }
                        continue
                    }
                    if let client = CherryMCPTools.initializeClient(in: message) {
                        await clientInfo(client)
                    }
                    if let arguments = CherryMCPTools.callArgumentsTheSDKChanges(in: message) {
                        await callArguments(arguments)
                    }
                    continuation.yield(message)
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
