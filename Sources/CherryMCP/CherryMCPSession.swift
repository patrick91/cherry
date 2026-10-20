import CherryControl
import Darwin
import Foundation

/// How one `cherry` command reaches the app's tools (`CherryMCP cli`): the
/// tab it runs for, and the app it asks. Against an app of control protocol
/// 2 or later it is a pipe: each call is one `callTool` the app runs as its
/// caller. Against an older app (one that cannot decode `appInfo`) it runs
/// the tool layer itself over typed requests (legacy).
///
/// The environment it was made with is the only one it reads (`main` passes
/// the process's; tests their own).
public actor CherryMCPSession {
    /// How the session reaches the app's tools.
    enum Mode: Equatable, Sendable {
        /// Not asked yet, or the last request did not reach the app.
        case unknown
        /// The app runs the tools (`appInfo` said protocol 2 or later).
        case pipe(AppInfoResult)
        /// The app predates `appInfo`: this helper runs the tools over
        /// typed requests until `until`, then asks again.
        case legacy(until: Date)
    }

    /// How long an app that cannot decode `appInfo` is taken for one: an
    /// update may replace it while the agent runs.
    static let legacyLifetime: TimeInterval = 60
    /// `appInfo` and `listTools` before a client's `tools/list`, which the
    /// app answers at once (before its task restore): a slower answer gets
    /// the helper's own list.
    static let listTimeout: TimeInterval = 2
    /// `appInfo` before a call: a typed request's default, since the app
    /// answers on its main thread, which a launch can keep busy.
    static let callInfoTimeout: TimeInterval = 10

    let transport: SocketToolTransport
    let environment: [String: String]
    /// The tab the environment names (CHERRY_PROCESS_ID, CHERRY_AGENT_ID):
    /// a claim, which only supplies defaults the app could not verify.
    let claim: String?
    /// The caller's CHERRY_PROJECT_ROOT.
    let projectRoot: String?
    /// The caller's current directory, whose innermost open project scopes
    /// a call that names none.
    let workingDirectory: String?
    /// False when nothing keeps a binding (a single call made without
    /// one): `bind_session_process` then has nothing to bind.
    let bindsSession: Bool
    /// Whether a legacy session whose environment names no tab finds it
    /// from its process ancestry, as CherryMCP did at startup before the app
    /// identified its callers.
    let infersCaller: Bool
    /// This helper's build (`CherryBuildInfo`), for `get_status`.
    public nonisolated let helperBuild: String

    /// The process this session is bound to (`bind_session_process`),
    /// first the claim.
    private(set) var boundProcessID: String?
    private(set) var mode: Mode = .unknown
    /// The caller a legacy session found from its ancestry: looked for once.
    private var inferredCaller: String??

    /// A session of `CherryMCP` itself (`cli`): its caller and project from
    /// `environment`, its build (and its app's socket, when `environment`
    /// names none) from where the helper is.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: String? = FileManager.default.currentDirectoryPath,
        helperExecutableURL: URL? = Bundle.main.executableURL
    ) {
        let claim = CherryMCPTools.environmentProcessID(in: environment)
        self.init(
            environment: environment,
            claim: claim,
            boundProcessID: claim,
            bindsSession: true,
            infersCaller: true,
            workingDirectory: workingDirectory,
            helperExecutableURL: helperExecutableURL
        )
    }

    /// A session for one call whose maker already knows its caller and
    /// binding (`CherryMCPTools.call` with a context).
    init(
        environment: [String: String],
        claim: String?,
        boundProcessID: String?,
        bindsSession: Bool,
        infersCaller: Bool,
        workingDirectory: String?,
        helperExecutableURL: URL? = Bundle.main.executableURL
    ) {
        self.environment = environment
        transport = SocketToolTransport(
            socketURL: CherryControl.socketURL(environment: environment, executableURL: helperExecutableURL),
            credentials: .fromEnvironment(environment),
            controlMachine: environment[CherryControl.controlMachineEnvironmentKey]
        )
        self.claim = claim
        self.boundProcessID = boundProcessID
        projectRoot = environment[CherryControl.projectRootEnvironmentKey]
        self.workingDirectory = workingDirectory
        self.bindsSession = bindsSession
        self.infersCaller = infersCaller
        helperBuild = CherryBuildInfo.build(executableURL: helperExecutableURL)
    }

    // MARK: The caller

    /// What Cherry knows of the caller: nothing of a client, so its waits
    /// keep to the default limit.
    public var profile: ToolClientProfile {
        ToolClientProfile(client: nil, toolTimeoutMilliseconds: nil)
    }

    // MARK: Which app answers

    /// Asks the app what it is (`appInfo`) unless the session knows: pipe
    /// for control protocol 2 or later, legacy for an app that cannot
    /// decode the request (`invalid_request`). Any other failure (no app
    /// listens, the forward is down, a token it refuses) is returned for the
    /// call to report, and leaves the mode unknown: it never makes the
    /// session legacy.
    private func settleMode(timeout: TimeInterval) async -> CherryControlError? {
        switch mode {
        case .pipe:
            return nil
        case .legacy(let until) where until > Date():
            return nil
        default:
            break
        }
        do {
            let response = try await transport.send(.appInfo, timeout: timeout)
            if let error = response.error {
                guard error.code == "invalid_request" else {
                    mode = .unknown
                    return error
                }
                mode = .legacy(until: Date().addingTimeInterval(Self.legacyLifetime))
                return nil
            }
            guard case .appInfo(let info)? = response.result else {
                mode = .unknown
                return CherryControlError(code: "unexpected_response", message: "Cherry returned an unexpected response for appInfo.")
            }
            mode = info.controlProtocol >= 2 ? .pipe(info) : .legacy(until: Date().addingTimeInterval(Self.legacyLifetime))
            return nil
        } catch {
            mode = .unknown
            return CherryToolLayer.controlError(error)
        }
    }

    // MARK: Calls

    /// Runs one tool: the app runs it (pipe), else this helper over typed
    /// requests (legacy). `get_status` always runs here, since it reports
    /// this helper's socket. `interface` says which interface made the call
    /// ("cli").
    public func call(name: String, arguments: [String: JSONValue], interface: String = "cli") async -> CallToolResult {
        if name == "get_status" {
            return await statusResult()
        }
        if let error = await settleMode(timeout: Self.callInfoTimeout) {
            // No app answered: the call is answered as before the app ran
            // the tools. The layer refuses what it can tell itself (a tool
            // in no list, a missing argument), and its first request reports
            // `error`. The session stays unknown, so the next call asks again.
            let failed = FailedToolTransport(error: error, socketPath: transport.socketPath)
            return await CherryToolLayer.call(name: name, arguments: arguments, caller: layerCaller(processID: claim), transport: failed)
        }
        guard case .pipe = mode else {
            return await legacyCall(name: name, arguments: arguments)
        }

        // Every name goes to the app, which answers unknown_tool itself: a
        // newer app may have tools this helper does not know.
        let profile = profile
        let request = CherryControlRequest.callTool(.init(name: name, arguments: arguments, context: callContext(interface: interface)))
        let response: CherryControlResponse
        do {
            response = try await transport.send(request, timeout: CherryToolLayer.callTimeout(for: name, arguments: arguments, profile: profile))
        } catch {
            // Not answered: the next call asks the app again (it may have
            // quit or been replaced). The call is never sent twice.
            mode = .unknown
            return CherryToolLayer.errorResult(CherryToolLayer.controlError(error))
        }
        if let error = response.error {
            guard error.code == "invalid_request" else {
                return CherryToolLayer.errorResult(error)
            }
            // An app that cannot decode callTool was replaced by an older
            // one since `appInfo`: the call runs here. An app that still
            // says protocol 2 refused this one request, which is the
            // tool's error.
            mode = .unknown
            if await settleMode(timeout: Self.callInfoTimeout) == nil, case .legacy = mode {
                return await legacyCall(name: name, arguments: arguments)
            }
            return CherryToolLayer.errorResult(error)
        }
        guard case .callTool(let result)? = response.result else {
            return CherryToolLayer.errorResult(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for callTool."))
        }
        if let bindProcessID = result.bindProcessID {
            boundProcessID = bindProcessID
        }
        return result
    }

    /// What a `callTool` says of its caller: the claim and the binding, the
    /// caller's project and directory, and its profile.
    func callContext(interface: String) -> ToolCallContext {
        ToolCallContext(
            callerProcessID: claim,
            boundProcessID: boundProcessID,
            bindsSession: bindsSession,
            projectRoot: projectRoot,
            workingDirectory: workingDirectory,
            profile: profile,
            interface: interface
        )
    }

    /// The tool layer run here, over typed requests, for an app that
    /// predates `appInfo`. It refuses a name it does not know before it
    /// sends anything, so such a name never looks for the caller either.
    private func legacyCall(name: String, arguments: [String: JSONValue]) async -> CallToolResult {
        let caller = CherryToolCatalog.names.contains(name) ? await legacyCaller() : layerCaller(processID: claim)
        let result = await CherryToolLayer.call(name: name, arguments: arguments, caller: caller, transport: transport)
        if let bindProcessID = result.bindProcessID {
            boundProcessID = bindProcessID
        }
        return result
    }

    /// The layer's caller in legacy mode: the claim, else (looked for once)
    /// the tab whose program this helper descends from, which also becomes
    /// the bound process when nothing was bound.
    private func legacyCaller() async -> CherryToolCaller {
        var caller = layerCaller(processID: claim)
        guard claim == nil, infersCaller else {
            return caller
        }
        if inferredCaller == nil {
            let ancestors = Array(CherryControl.processAncestry(of: getpid(), maxDepth: 12).dropFirst())
            let found = await CherryToolLayer.inferredCallerProcessID(parentPIDs: ancestors, caller: caller, transport: transport)
            inferredCaller = .some(found)
            if boundProcessID == nil {
                boundProcessID = found
            }
        }
        caller.processID = inferredCaller ?? nil
        caller.boundProcessID = boundProcessID
        return caller
    }

    private func layerCaller(processID: String?) -> CherryToolCaller {
        CherryToolCaller(
            processID: processID,
            boundProcessID: boundProcessID,
            bindsSession: bindsSession,
            projectRoot: projectRoot,
            workingDirectory: workingDirectory,
            profile: profile
        )
    }

    // MARK: get_status

    /// get_status: the layer's report of this helper's socket, plus which
    /// builds talk and how (`helper_build`; `app_build`,
    /// `app_control_protocol` and `mode` "pipe" once the app answered
    /// `appInfo`, `mode` "legacy" for an app that predates it; no mode
    /// while no app answers). It asks the app again: an update may have
    /// replaced it since the session last asked.
    private func statusResult() async -> CallToolResult {
        mode = .unknown
        _ = await settleMode(timeout: Self.callInfoTimeout)
        let status = await CherryToolLayer.call(name: "get_status", arguments: [:], caller: layerCaller(processID: claim), transport: transport)
        var fields: [String: JSONValue] = ["helper_build": .string(helperBuild)]
        switch mode {
        case .pipe(let info):
            fields["app_build"] = .string(info.build)
            fields["app_control_protocol"] = .int(info.controlProtocol)
            fields["mode"] = .string("pipe")
        case .legacy:
            fields["mode"] = .string("legacy")
        case .unknown:
            break
        }
        return Self.adding(fields, to: status)
    }

    /// `result` with `fields` (snake_case names) added to its payload: in
    /// its text as named, in its structured content in camelCase, as the
    /// layer encodes both.
    static func adding(_ fields: [String: JSONValue], to result: CallToolResult) -> CallToolResult {
        guard case .object(var text)? = try? JSONValue.parse(Data(result.text.utf8)),
              case .object(var structured)? = result.structured
        else {
            return result
        }
        for (name, value) in fields {
            text[name] = value
            structured[camelCase(name)] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(text)) else {
            return result
        }
        return CallToolResult(
            text: String(decoding: data, as: UTF8.self),
            isError: result.isError,
            structured: .object(structured),
            bindProcessID: result.bindProcessID,
            toolsDigest: result.toolsDigest
        )
    }

    private static func camelCase(_ name: String) -> String {
        let words = name.split(separator: "_")
        return words.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }
}

/// A transport whose every request fails with `error`: what the socket did
/// when the session asked which app answers.
private struct FailedToolTransport: CherryToolTransport {
    let error: CherryControlError
    let socketPath: String?

    func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse {
        throw error
    }
}
