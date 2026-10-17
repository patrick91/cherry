import CherryControl
import Foundation
import MCP

/// An MCP session's caller and the process it is bound to
/// (`bind_session_process`), for the session's whole life.
public final class CherryMCPToolContext: @unchecked Sendable {
    public let callerProcessID: String?
    private let lock = NSLock()
    private var storedBoundProcessID: String?

    public var boundProcessID: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedBoundProcessID
    }

    private init(callerProcessID: String?) {
        self.callerProcessID = callerProcessID
        self.storedBoundProcessID = callerProcessID
    }

    public static func bound(callerProcessID: String? = nil) -> CherryMCPToolContext {
        CherryMCPToolContext(callerProcessID: callerProcessID)
    }

    @discardableResult
    public func bindProcessID(_ processID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let previous = storedBoundProcessID
        storedBoundProcessID = processID
        return previous
    }
}

/// CherryMCP's side of the tools: the MCP SDK's types around a
/// `CherryMCPSession`, which pipes each call to the app (`callTool`), or runs
/// `CherryToolLayer` (Sources/CherryControl) itself over the socket for an
/// app that predates `appInfo`.
public enum CherryMCPTools {
    /// The catalog's tools for a client CherryMCP knows nothing of, as the
    /// MCP SDK's `Tool`.
    public static let all: [Tool] = CherryToolCatalog.tools(for: .unknown).map(sdkTool)

    /// Runs `name` with the helper's caller: the session's `context`, else
    /// (no MCP session) the environment's tab. The project is the
    /// environment's CHERRY_PROJECT_ROOT, else the current directory's. A
    /// session of its own, made from the environment as it is now, sends
    /// the call: the app runs it, or this helper does for an older app.
    public static func call(
        name: String,
        arguments: [String: Value],
        context: CherryMCPToolContext? = nil
    ) async -> CallTool.Result {
        let environment = ProcessInfo.processInfo.environment
        let session = CherryMCPSession(
            environment: environment,
            claim: context?.callerProcessID ?? (context == nil ? environmentProcessID(in: environment) : nil),
            boundProcessID: context?.boundProcessID,
            bindsSession: context != nil,
            // The context's caller is what the session's maker found.
            infersCaller: false,
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        let result = await session.call(name: name, arguments: jsonArguments(arguments))
        if let bindProcessID = result.bindProcessID {
            context?.bindProcessID(bindProcessID)
        }
        return sdkResult(result)
    }

    /// The SDK's arguments as JSON. A `Value` decoded from JSON always
    /// converts: a string the SDK read as a data URL is a string again, a
    /// base64 data URL of the same bytes and type (not always the text the
    /// client sent: an MCP session passes such a call's arguments as
    /// written, `CherryMCPSession.callArguments`). Only a number JSON
    /// cannot carry (NaN, an infinity) would not, and is left out.
    static func jsonArguments(_ arguments: [String: Value]) -> [String: JSONValue] {
        arguments.compactMapValues { try? JSONValue.parse(JSONEncoder().encode($0)) }
    }

    /// A tool's result as the SDK's: its text, and its structured content.
    static func sdkResult(_ result: CallToolResult) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: result.text, annotations: nil, _meta: nil)],
            structuredContent: result.structured.flatMap(sdkValue),
            isError: result.isError
        )
    }

    private static func sdkValue(_ value: JSONValue) -> Value? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    /// The tab the process's environment names: CHERRY_PROCESS_ID, else
    /// CHERRY_AGENT_ID, when it is a UUID.
    public static func environmentProcessID() -> String? {
        environmentProcessID(in: ProcessInfo.processInfo.environment)
    }

    /// The tab `environment` names (CHERRY_PROCESS_ID, else
    /// CHERRY_AGENT_ID), when it is a UUID: a claim, never identity.
    static func environmentProcessID(in environment: [String: String]) -> String? {
        let value = environment[CherryControl.processIDEnvironmentKey]
            ?? environment[CherryControl.agentIDEnvironmentKey]
        guard let processID = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !processID.isEmpty,
            UUID(uuidString: processID) != nil
        else {
            return nil
        }
        return processID
    }

    /// The process (tab) whose program `processPID` descends from: the
    /// environment's, else the nearest of its (at most 12) ancestors that
    /// is a process of the project.
    public static func callerProcessID(processPID: Int32) async -> String? {
        if let processID = environmentProcessID() {
            return processID
        }
        let ancestors = Array(CherryControl.processAncestry(of: processPID, maxDepth: 12).dropFirst())
        return await inferredCallerProcessID(parentPIDs: ancestors)
    }

    public static func inferredCallerProcessID(parentPIDs: [Int32]) async -> String? {
        await CherryToolLayer.inferredCallerProcessID(
            parentPIDs: parentPIDs,
            caller: CherryToolCaller(
                processID: environmentProcessID(),
                projectRoot: ProcessInfo.processInfo.environment[CherryControl.projectRootEnvironmentKey],
                workingDirectory: FileManager.default.currentDirectoryPath
            ),
            transport: SocketToolTransport()
        )
    }

    /// An argument as JSON, whatever its type.
    static func jsonArgument(_ key: String, in arguments: [String: Value]) throws -> JSONValue? {
        guard let value = arguments[key] else { return nil }
        let json: JSONValue
        do {
            json = try JSONValue.parse(JSONEncoder().encode(value))
        } catch {
            throw CherryControlError(code: "invalid_argument", message: "\(key) is not JSON: \(error.localizedDescription)")
        }
        return try CherryToolLayer.jsonArgument(key, in: [key: json])
    }

    /// A JSON Schema argument: an object, or JSON text of one (some
    /// clients send nested objects as strings).
    static func schemaArgument(_ key: String, in arguments: [String: Value]) throws -> JSONValue? {
        guard let value = try jsonArgument(key, in: arguments) else { return nil }
        return try CherryToolLayer.schemaArgument(key, in: [key: value])
    }

    /// How long the MCP client waits for Cherry's answer to a tool call:
    /// nil for the client's default (10 s).
    static func clientTimeout(for toolName: String, arguments: [String: Value]) -> TimeInterval? {
        CherryToolLayer.clientTimeout(for: toolName, arguments: jsonArguments(arguments))
    }

    /// `CherryMCP --version`: this helper's build, as its control protocol
    /// and its MCP server's version (sorted keys).
    public static func versionJSON(build: String) -> String {
        JSONValue.object([
            "build": .string(build),
            "controlProtocol": .int(CherryControl.controlProtocolVersion),
            "name": .string("CherryMCP"),
            "version": .string(build),
        ]).compactJSON
    }

    /// `definition` as the SDK's `Tool`: its schema as `Value`, its
    /// annotations (when it has any) as `Tool.Annotations`.
    static func sdkTool(_ definition: CherryToolDefinition) -> Tool {
        let inputSchema = (try? JSONEncoder().encode(definition.inputSchema))
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
        return Tool(
            name: definition.name,
            description: definition.description,
            inputSchema: inputSchema ?? .object([:]),
            annotations: definition.annotations.map {
                Tool.Annotations(
                    readOnlyHint: $0.readOnlyHint,
                    destructiveHint: $0.destructiveHint,
                    idempotentHint: $0.idempotentHint,
                    openWorldHint: $0.openWorldHint
                )
            } ?? Tool.Annotations()
        )
    }
}
