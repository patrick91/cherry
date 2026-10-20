import CherryControl
import Foundation

// MARK: - Tool requests (control protocol 2)
//
// The app's side of `appInfo`, `listTools` and `callTool`
// (`CherryToolProtocol.swift`). A tool call runs the MCP tool layer
// (`CherryToolLayer`) here, as CherryMCP runs it over the socket for an
// older app: each of its requests is dispatched in-process through the
// `handle` path the caller's own typed request takes. So the device choke
// point (`requireOnRemoteDevice`), `callerSessions`, `callerReaches` and
// every other rule apply to a tool's requests exactly as to typed ones. Its
// defaults come from the caller Cherry verified (`verifiedCallerSession`);
// what the caller says of itself only fills in when Cherry verified none.

extension CherryControlServer {
    /// The longest wait_for_events / wait_for_tasks the client of the tool
    /// call being handled allows (its profile's `waitCapMilliseconds`); nil
    /// for a typed request, which keeps 50 s. A task local: requests
    /// interleave on the main actor, and each sees only its own.
    @TaskLocal static var callerWaitCapMilliseconds: Int?

    /// A wait_for_events or wait_for_tasks timeout, by
    /// `ToolClientProfile.clampedWait`'s rule: `requested`, else the 50 s
    /// default, at least 0 and at most the tool call's cap
    /// (`callerWaitCapMilliseconds`), else `typedMaximum`, a typed request's.
    static func callerWaitMilliseconds(_ requested: Int?, typedMaximum: Int) -> Int {
        ToolClientProfile.clampedWait(
            requested, default: CherryControl.defaultWaitMilliseconds, cap: callerWaitCapMilliseconds ?? typedMaximum
        )
    }

    /// The app that answers this socket: its control protocol, so a helper
    /// knows which requests it may send, and its build (the enclosing
    /// .app's `CFBundleVersion`, "dev" for `swift run`).
    static func appInfo() -> AppInfoResult {
        let executableURL = Bundle.main.executableURL
        let info = CherryAppIdentity.configurationInfo(bundle: .main, executableURL: executableURL)
        return AppInfoResult(
            controlProtocol: CherryControl.controlProtocolVersion,
            build: CherryBuildInfo.build(executableURL: executableURL),
            version: (info["CFBundleShortVersionString"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            bundleIdentifier: (info["CFBundleIdentifier"] as? String)?.nilIfEmpty,
            urlScheme: CherryAppIdentity.current.urlScheme
        )
    }

    /// Whether `request` is one of control protocol 2's or 3's: answered in
    /// `handleRequestData`, never nested in another request.
    static func isToolRequest(_ request: CherryControlRequest) -> Bool {
        switch request {
        case .appInfo, .listTools, .callTool, .runCommand:
            true
        default:
            false
        }
    }

    /// `appInfo` and `listTools`, answered at once: what the app is and
    /// which tools it lists depend on nothing it restores, so an agent's
    /// `tools/list` at launch never waits for the task restore. A caller on
    /// another Mac must still name an open tab of it with its token first,
    /// as for any request. Nil for every other request; `callTool` runs as
    /// its caller once the tasks are restored.
    @MainActor
    func toolRequestAnsweredAtOnce(
        _ request: CherryControlRequest,
        credentials: CherryControlCredentials?,
        origin: CallerOrigin
    ) throws -> CherryControlResponse? {
        guard Self.isToolRequest(request) else { return nil }
        // Tests: an app from before control protocol 2 cannot decode these.
        guard answersToolRequests else {
            throw CherryControlError(
                code: "invalid_request",
                message: "This Cherry does not know tool requests: it predates control protocol 2."
            )
        }
        switch request {
        case .callTool, .runCommand: return nil
        default: break
        }

        if let credentials {
            _ = try remoteCaller(credentials, origin: origin)
        } else if origin != .thisMac {
            throw Self.missingDeviceToken
        }
        switch request {
        case .listTools(let list):
            return .init(result: .listTools(CherryToolCatalog.listResult(for: list.profile ?? .unknown)))
        default:
            return .init(result: .appInfo(Self.appInfo()))
        }
    }

    /// Runs `call` as its caller: the tool layer, each of its requests sent
    /// through `dispatch` (the caller's `handle`), its defaults from the
    /// caller Cherry verified, its waits as long as its client allows.
    @MainActor
    func handleToolCall(
        _ call: CallToolRequest,
        dispatch: @escaping @Sendable @MainActor (CherryControlRequest) async throws -> CherryControlResponse
    ) async -> CallToolResult {
        let context = call.context ?? ToolCallContext()
        let profile = context.profile ?? .unknown
        // The caller's tab as Cherry knows it (its process, or a device's
        // token), else the tab it claims: a claim only supplies defaults, as
        // CherryMCP's environment did. Tasks, wake lines and run ownership
        // never read it (`verifiedCallerSession`).
        let claim = context.callerProcessID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let verified = verifiedCallerSession()?.id.uuidString
        let bindsSession = context.bindsSession ?? false
        // An MCP session bound to nothing yet (its client passed no
        // CHERRY_PROCESS_ID, so there was no claim to bind) is bound to the
        // verified caller, as CherryMCP bound the caller it found at startup
        // before the app identified callers: whoami and bind_session_process
        // report it, and the session keeps it (`bindProcessID`) once a call
        // succeeds; a failed call changes nothing.
        let bindsVerifiedCaller = bindsSession && context.boundProcessID == nil && verified != nil
        let caller = CherryToolCaller(
            processID: verified ?? claim,
            boundProcessID: context.boundProcessID ?? (bindsVerifiedCaller ? verified : nil),
            bindsSession: bindsSession,
            projectRoot: context.projectRoot,
            workingDirectory: context.workingDirectory,
            profile: profile
        )
        // get_status names the socket This Mac's callers use; a caller on
        // another Mac reports its own forward, never a path of This Mac.
        let transport = InProcessToolTransport(socketPath: Self.remoteDevice == nil ? socketURL.path : nil) { request in
            await self.dispatchToolRequest(request, through: dispatch)
        }
        // A client that allows longer tool calls may wait longer (the cap
        // applies to this call's waits only).
        var result = await Self.$callerWaitCapMilliseconds.withValue(profile.waitCapMilliseconds) {
            await CherryToolLayer.call(name: call.name, arguments: call.arguments, caller: caller, transport: transport)
        }
        if bindsVerifiedCaller, result.bindProcessID == nil, !result.isError {
            result.bindProcessID = verified
        }
        result.toolsDigest = toolsDigestOverrideForTesting ?? CherryToolCatalog.digest(for: profile)
        return result
    }

    /// One of a tool call's requests, answered as over the socket: Cherry's
    /// error is an error answer, never thrown.
    @MainActor
    private func dispatchToolRequest(
        _ request: CherryControlRequest,
        through dispatch: @MainActor (CherryControlRequest) async throws -> CherryControlResponse
    ) async -> CherryControlResponse {
        toolDispatchWillSendForTesting?(request)
        // The layer sends typed requests only; a tool call never makes another.
        if Self.isToolRequest(request) {
            return .init(error: CherryControlError(
                code: "invalid_request",
                message: "A tool call sends typed requests only, never appInfo, listTools, callTool or runCommand."
            ))
        }
        do {
            return try await dispatch(request)
        } catch let error as CherryControlError {
            return .init(error: error)
        } catch {
            return .init(error: .init(code: "invalid_request", message: error.localizedDescription))
        }
    }
}

/// The tool layer's transport in the app: each request handled in-process,
/// as its caller (`CherryControlServer.handleToolCall`). The layer's
/// per-request client timeouts do not apply: nothing waits on a socket, and
/// the client's own timeout covers the whole call
/// (`CherryToolLayer.callTimeout`).
private struct InProcessToolTransport: CherryToolTransport {
    let socketPath: String?
    let dispatch: @Sendable @MainActor (CherryControlRequest) async -> CherryControlResponse

    func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse {
        await dispatch(request)
    }
}
