import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class CherryMCPHTTPServer: @unchecked Sendable {
    static let host = "127.0.0.1"
    static let port = 61234
    static let endpoint = "/mcp"
    static let url = "http://\(host):\(port)\(endpoint)"

    private var app: CherryMCPHTTPApp?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }

        let app = CherryMCPHTTPApp(
            configuration: .init(host: Self.host, port: Self.port, endpoint: Self.endpoint),
            serverFactory: { _, _ in
                let server = Server(
                    name: "cherry",
                    version: "0.1.0",
                    title: "Cherry",
                    instructions: "Control the visible Cherry terminal app through local-only IPC. Tools do not change Cherry's visible selection unless the tool name starts with select_.",
                    capabilities: .init(tools: .init(listChanged: false))
                )

                await server.withMethodHandler(ListTools.self) { _ in
                    ListTools.Result(tools: CherryMCPTools.all)
                }

                await server.withMethodHandler(CallTool.self) { params in
                    await CherryMCPTools.call(name: params.name, arguments: params.arguments ?? [:])
                }

                return server
            }
        )
        self.app = app
        task = Task.detached(priority: .utility) {
            do {
                try await app.start()
            } catch {
                fputs("[mcp-http] failed to start: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    func stop() {
        guard let app else { return }
        task?.cancel()
        task = nil
        self.app = nil
        Task {
            await app.stop()
        }
    }
}

actor CherryMCPHTTPApp {
    /// Configuration for the HTTP application.
    struct Configuration: Sendable {
        /// The host address to bind to.
        var host: String

        /// The port to bind to.
        var port: Int

        /// The MCP endpoint path.
        var endpoint: String

        /// Session timeout in seconds.
        var sessionTimeout: TimeInterval

        /// SSE retry interval in milliseconds for priming events.
        var retryInterval: Int?

        init(
            host: String = "127.0.0.1",
            port: Int = 3000,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
        }
    }

    /// Factory function to create MCP Server instances for each session.
    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]

    nonisolated let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    // MARK: - Init

    /// Creates a new HTTP application.
    ///
    /// - Parameters:
    ///   - configuration: Application configuration.
    ///   - validationPipeline: Custom validation pipeline passed to each transport.
    ///     If `nil`, transports use their sensible defaults.
    ///   - serverFactory: Factory function to create Server instances for each session.
    ///   - logger: Optional logger instance.
    init(
        configuration: Configuration = Configuration(),
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
        self.logger = logger ?? Logger(
            label: "mcp.http.app",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
    }

    /// Convenience initializer with individual parameters.
    init(
        host: String = "127.0.0.1",
        port: Int = 3000,
        endpoint: String = "/mcp",
        serverFactory: @escaping ServerFactory,
        logger: Logger? = nil
    ) {
        self.init(
            configuration: Configuration(host: host, port: port, endpoint: endpoint),
            serverFactory: serverFactory,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    /// Starts the HTTP application.
    ///
    /// This starts the NIO HTTP server and begins accepting connections.
    /// The call blocks until the server is shut down via ``stop()``.
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CherryMCPHTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        logger.info(
            "Starting MCP HTTP application",
            metadata: [
                "host": "\(configuration.host)",
                "port": "\(configuration.port)",
                "endpoint": "\(configuration.endpoint)",
            ]
        )

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel

        Task { await sessionCleanupLoop() }

        try await channel.closeFuture.get()
    }

    /// Stops the HTTP application gracefully, closing all sessions.
    func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        logger.info("MCP HTTP application stopped")
    }

    // MARK: - Request Routing

    var endpoint: String { configuration.endpoint }

    /// Routes an incoming HTTP request to the appropriate session transport.
    ///
    /// - Requests with a valid `Mcp-Session-Id` are forwarded to the matching transport.
    /// - POST requests with an `initialize` body create a new session.
    /// - All other requests without a session return an error.
    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
            let body = request.body,
            let kind = CherryJSONRPCMessageKind(data: body),
            kind.isInitializeRequest
        {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: configuration.retryInterval,
            logger: logger
        )

        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            // If transport returned an error, clean up
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
        logger.info("Closed session", metadata: ["sessionID": "\(sessionID)"])
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(60))

            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout
            }

            for (sessionID, _) in expired {
                logger.info("Session expired", metadata: ["sessionID": "\(sessionID)"])
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` types, delegating all logic to the `HTTPApp`.
private final class CherryMCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: CherryMCPHTTPApp

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?

    init(app: CherryMCPHTTPApp) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    // MARK: - Request Processing

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await app.endpoint

        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await app.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    // MARK: - NIO ↔ HTTPRequest/HTTPResponse Conversion

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        // Combine multiple header values per RFC 7230
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        // Write response head
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            // Await the SSE stream directly — no Task needed since we're already in one
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — close connection
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

private enum CherryJSONRPCMessageKind {
    case request(id: String, method: String)
    case notification(method: String)
    case response(id: String)

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = Self.extractID(from: json)
        if let method = json["method"] as? String {
            if let id {
                self = .request(id: id, method: method)
            } else {
                self = .notification(method: method)
            }
        } else if json["result"] != nil || json["error"] != nil {
            guard let id else { return nil }
            self = .response(id: id)
        } else {
            return nil
        }
    }

    var isInitializeRequest: Bool {
        if case .request(_, let method) = self {
            return method == "initialize"
        }
        return false
    }

    private static func extractID(from json: [String: Any]) -> String? {
        if let stringID = json["id"] as? String {
            return stringID
        }
        if let intID = json["id"] as? Int {
            return String(intID)
        }
        return nil
    }
}
