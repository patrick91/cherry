import CherryControl
import Foundation

/// A caller and the process it is bound to (`bind_session_process`), for
/// the calls made with it.
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

/// CherryMCP's side of the tools: a `CherryMCPSession`, which pipes each
/// call to the app (`callTool`), or runs `CherryToolLayer`
/// (Sources/CherryControl) itself over the socket for an app that predates
/// `appInfo`.
public enum CherryMCPTools {
    /// Runs `name` with the helper's caller: `context`'s, else the
    /// environment's tab. The project is the environment's
    /// CHERRY_PROJECT_ROOT, else the current directory's. A session of its
    /// own, made from the environment as it is now, sends the call: the app
    /// runs it, or this helper does for an older app.
    public static func call(
        name: String,
        arguments: [String: JSONValue],
        context: CherryMCPToolContext? = nil
    ) async -> CallToolResult {
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
        let result = await session.call(name: name, arguments: arguments)
        if let bindProcessID = result.bindProcessID {
            context?.bindProcessID(bindProcessID)
        }
        return result
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

    /// How long a caller waits for Cherry's answer to a tool call: nil for
    /// the default (10 s).
    static func clientTimeout(for toolName: String, arguments: [String: JSONValue]) -> TimeInterval? {
        CherryToolLayer.clientTimeout(for: toolName, arguments: arguments)
    }

    /// `CherryMCP --version`: this helper's build and control protocol
    /// (sorted keys).
    public static func versionJSON(build: String) -> String {
        JSONValue.object([
            "build": .string(build),
            "controlProtocol": .int(CherryControl.controlProtocolVersion),
            "name": .string("CherryMCP"),
            "version": .string(build),
        ]).compactJSON
    }
}
