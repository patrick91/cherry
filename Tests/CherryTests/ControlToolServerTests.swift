@testable import Cherry
import CherryControl
import Foundation
import Testing

// The control socket's tool requests (control protocol 2): appInfo and
// listTools, answered at once, and callTool, which runs the MCP tool layer
// in the app as its caller. The parity tests run the same tool twice
// against one server and its tabs: the layer over typed requests, as
// CherryMCP runs it for an app without appInfo, and as a callTool.

/// One request over `socketURL`, as a CherryMCP of This Mac sends it.
private func controlToolSend(_ request: CherryControlRequest, socketURL: URL) async throws -> CherryControlResponse {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result {
                try CherryControlClient(socketURL: socketURL, timeout: 70, credentials: nil, controlMachine: nil).send(request)
            })
        }
    }
}

/// `name` run by the app (`callTool`).
private func controlToolCall(
    _ name: String,
    _ arguments: [String: JSONValue] = [:],
    context: ToolCallContext? = nil,
    socketURL: URL
) async throws -> CallToolResult {
    let response = try await controlToolSend(.callTool(.init(name: name, arguments: arguments, context: context)), socketURL: socketURL)
    guard case .callTool(let result)? = response.result else {
        throw CherryControlError(code: "call_failed", message: "Expected a callTool result, got \(String(describing: response))")
    }
    return result
}

/// `name` run by the layer over typed requests, as CherryMCP runs it
/// against an app without appInfo.
private func controlToolOverTypedRequests(
    _ name: String,
    _ arguments: [String: JSONValue] = [:],
    caller: CherryToolCaller,
    socketURL: URL
) async -> CallToolResult {
    await CherryToolLayer.call(
        name: name,
        arguments: arguments,
        caller: caller,
        transport: SocketToolTransport(socketURL: socketURL, credentials: nil, controlMachine: nil)
    )
}

private func controlToolErrorCode(_ result: CallToolResult) -> String? {
    guard result.isError else { return nil }
    return result.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue
}

/// The top-level fields of a result: what agents can rely on finding.
private func controlToolFields(_ result: CallToolResult) -> Set<String> {
    Set(result.structured?.objectValue?.keys.map { $0 } ?? [])
}

/// The id of the process a result describes (`process.id`).
private func controlToolProcessID(_ result: CallToolResult) -> String? {
    result.structured?.objectValue?["process"]?.objectValue?["id"]?.stringValue
}

private let controlToolClaudeProfile = ToolClientProfile(client: ToolClientInfo(name: "claude-code", version: "2.1.299"))

// MARK: - The wire

@Test func controlToolServerRequestsAndResultsUseTheWiresJSON() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    #expect(try json(CherryControlRequest.appInfo) == #"{"appInfo":{}}"#)
    #expect(try json(CherryControlRequest.listTools(.init(profile: controlToolClaudeProfile)))
        == #"{"listTools":{"_0":{"profile":{"client":{"name":"claude-code","version":"2.1.299"}}}}}"#)
    #expect(try json(CherryControlRequest.callTool(.init(name: "list_processes", arguments: ["kind": .string("agent")], context: .init(bindsSession: true))))
        == #"{"callTool":{"_0":{"arguments":{"kind":"agent"},"context":{"bindsSession":true},"name":"list_processes"}}}"#)

    let decoder = JSONDecoder()
    #expect(try decoder.decode(CherryControlRequest.self, from: Data(#"{"appInfo":{}}"#.utf8)) == .appInfo)
    let list = try decoder.decode(
        CherryControlRequest.self,
        from: Data(#"{"listTools":{"_0":{"profile":{"client":{"name":"claude-code","version":"2.1.299"},"toolTimeoutMilliseconds":null}}}}"#.utf8)
    )
    #expect(list == .listTools(.init(profile: controlToolClaudeProfile)))
    let call = try decoder.decode(CherryControlRequest.self, from: Data(#"{"callTool":{"_0":{"name":"whoami"}}}"#.utf8))
    #expect(call == .callTool(.init(name: "whoami")))

    let answer = CherryControlResponse(result: .callTool(.init(text: "{}", isError: false, structured: .object([:]), toolsDigest: "3f2a")))
    #expect(try json(answer) == #"{"result":{"callTool":{"_0":{"isError":false,"structured":{},"text":"{}","toolsDigest":"3f2a"}}}}"#)
    #expect(try decoder.decode(CherryControlResponse.self, from: encoder.encode(answer)) == answer)
}

// MARK: - appInfo and listTools

@MainActor
@Test func controlToolServerAnswersAppInfoWithItsProtocolAndBuild() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()

    let response = try await controlToolSend(.appInfo, socketURL: harness.socketURL)
    guard case .appInfo(let info)? = response.result else {
        Issue.record("Expected an appInfo result, got \(String(describing: response))")
        return
    }
    #expect(info.controlProtocol == 3)
    #expect(info.controlProtocol == CherryControl.controlProtocolVersion)
    #expect(info.urlScheme == CherryAppIdentity.current.urlScheme)
    #expect(info.build == CherryBuildInfo.build(executableURL: Bundle.main.executableURL))
    #expect(!info.build.isEmpty)
}

@MainActor
@Test func controlToolServerListsTheCatalogsToolsForTheClient() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()

    let claude = try await controlToolSend(.listTools(.init(profile: controlToolClaudeProfile)), socketURL: harness.socketURL)
    guard case .listTools(let listed)? = claude.result else {
        Issue.record("Expected a listTools result, got \(String(describing: claude))")
        return
    }
    #expect(listed == CherryToolCatalog.listResult(for: controlToolClaudeProfile))
    #expect(listed.digest == CherryToolCatalog.digest(for: controlToolClaudeProfile))
    #expect(listed.digest == CherryToolCatalog.digest(of: listed.tools))
    #expect(listed.instructions == CherryToolCatalog.instructions)
    #expect(Set(listed.tools.map(\.name)) == CherryToolCatalog.names)

    // A client that names none gets the unknown client's list.
    let unnamed = try await controlToolSend(.listTools(.init()), socketURL: harness.socketURL)
    guard case .listTools(let unknown)? = unnamed.result else {
        Issue.record("Expected a listTools result, got \(String(describing: unnamed))")
        return
    }
    #expect(unknown == CherryToolCatalog.listResult(for: .unknown))
}

/// The digest every callTool carries is cached per profile: each profile
/// still gets its own list's digest however many clients came (the cache
/// starts over past its limit), and a client named at great length is
/// hashed each time instead of kept.
@Test func controlToolServerCachedDigestsAreEachProfilesOwn() {
    var profiles: [ToolClientProfile] = [
        .unknown,
        controlToolClaudeProfile,
        ToolClientProfile(client: ToolClientInfo(name: String(repeating: "x", count: 300), version: "1.0")),
    ]
    profiles += (0..<40).map {
        ToolClientProfile(client: ToolClientInfo(name: "client-\($0)", version: "1.0"), toolTimeoutMilliseconds: $0 * 1_000)
    }
    for _ in 0..<2 {
        for profile in profiles {
            let expected = CherryToolCatalog.digest(of: CherryToolCatalog.tools(for: profile))
            #expect(CherryToolCatalog.digest(for: profile) == expected, "\(profile)")
            #expect(CherryToolCatalog.listResult(for: profile).digest == expected, "\(profile)")
        }
    }
}

/// An agent's tools/list at launch is answered while the last run's tasks
/// are still read back; a typed request and a callTool wait for them.
@MainActor
@Test func controlToolServerDescribesItselfBeforeTheTaskRestoreFinishes() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()
    let socketURL = harness.socketURL
    let restore = Task { @MainActor in
        _ = try? await Task.sleep(for: .seconds(60))
    }
    harness.server.tasks.restoreTask = restore
    defer {
        restore.cancel()
        harness.server.tasks.restoreTask = nil
    }

    let start = ContinuousClock.now
    let info = try await controlToolSend(.appInfo, socketURL: socketURL)
    let list = try await controlToolSend(.listTools(.init()), socketURL: socketURL)
    #expect(ContinuousClock.now - start < .seconds(20))
    guard case .appInfo? = info.result, case .listTools? = list.result else {
        Issue.record("Expected appInfo and listTools results, got \(info) and \(list)")
        return
    }

    let typed = Task.detached { () async throws -> ContinuousClock.Instant in
        _ = try await controlToolSend(.listProjects, socketURL: socketURL)
        return ContinuousClock.now
    }
    let call = Task.detached { () async throws -> ContinuousClock.Instant in
        _ = try await controlToolCall("list_projects", socketURL: socketURL)
        return ContinuousClock.now
    }
    try await Task.sleep(for: .milliseconds(500))
    let released = ContinuousClock.now
    restore.cancel()
    #expect(try await typed.value >= released)
    #expect(try await call.value >= released)
}

/// Every callTool says which list its client should have now: the
/// catalog's digest for its profile (or a test's, as when the app's tools
/// changed under a running client).
@MainActor
@Test func controlToolServerAnswersEachCallWithTheClientsToolsDigest() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()

    let claude = try await controlToolCall("list_projects", context: .init(profile: controlToolClaudeProfile), socketURL: harness.socketURL)
    #expect(!claude.isError, "\(claude.text)")
    #expect(claude.toolsDigest == CherryToolCatalog.digest(for: controlToolClaudeProfile))
    let unnamed = try await controlToolCall("list_projects", socketURL: harness.socketURL)
    #expect(unnamed.toolsDigest == CherryToolCatalog.digest(for: .unknown))
    // A tool's error is answered the same way.
    let unknownTool = try await controlToolCall("no_such_tool", socketURL: harness.socketURL)
    #expect(unknownTool.toolsDigest == CherryToolCatalog.digest(for: .unknown))

    harness.server.toolsDigestOverrideForTesting = "0123456789abcdef"
    let changed = try await controlToolCall("list_projects", context: .init(profile: controlToolClaudeProfile), socketURL: harness.socketURL)
    #expect(changed.toolsDigest == "0123456789abcdef")
}

/// A server standing in for an app from before control protocol 2 refuses
/// the three requests as that app does, and still answers typed ones.
@MainActor
@Test func controlToolServerWithoutToolRequestsRefusesThemLikeAnOlderApp() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.answersToolRequests = false
    harness.server.start()

    for request in [CherryControlRequest.appInfo, .listTools(.init()), .callTool(.init(name: "list_projects"))] {
        let response = try await controlToolSend(request, socketURL: harness.socketURL)
        #expect(response.result == nil)
        #expect(response.error?.code == "invalid_request", "\(request)")
    }
    let projects = try await controlToolSend(.listProjects, socketURL: harness.socketURL)
    guard case .listProjects? = projects.result else {
        Issue.record("Expected a listProjects result, got \(projects)")
        return
    }
}

// MARK: - Parity with the layer over typed requests

/// The reads agents make most give the same text, byte for byte, whether
/// CherryMCP runs the layer over typed requests or the app runs it.
@MainActor
@Test func controlToolServerReadsMatchTheLayerOverTypedRequests() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    let root = harness.projectRoot.path
    try harness.settings.upsertCommand(ProjectCommandDefinition(name: "Echo", command: "/bin/cat"), for: root)
    harness.server.start()
    let started = try await harness.send(.startProcess(.init(processName: "Echo", kind: "command")))
    guard case .startProcess(let echo)? = started.result else {
        Issue.record("Expected a startProcess result, got \(String(describing: started))")
        return
    }
    _ = try await harness.send(.sendProcessInput(.init(processName: "Echo", text: "parity\n", waitMilliseconds: 250, lineLimit: 20)))
    _ = try await harness.send(.createTodo(.init(title: "Parity", markdown: "Both ways.")))

    let caller = CherryToolCaller(processID: echo.process.id, projectRoot: root)
    let context = ToolCallContext(callerProcessID: echo.process.id, projectRoot: root, interface: "mcp")
    let reads = [
        "get_status", "list_projects", "get_project_status", "list_processes", "get_process_status",
        "get_process_output", "list_agents", "list_todos", "whoami",
    ]
    for name in reads {
        let typed = await controlToolOverTypedRequests(name, caller: caller, socketURL: harness.socketURL)
        let app = try await controlToolCall(name, context: context, socketURL: harness.socketURL)
        #expect(!app.isError, "\(name): \(app.text)")
        #expect(app.text == typed.text, "\(name)")
        #expect(app.structured == typed.structured, "\(name)")
        #expect(app.isError == typed.isError, "\(name)")
    }

    // get_status names the server's own socket.
    let status = try await controlToolCall("get_status", socketURL: harness.socketURL)
    #expect(status.structured?.objectValue?["socketPath"] == .string(harness.socketURL.path))
    #expect(status.structured?.objectValue?["cherryReachable"] == .bool(true))
}

/// Writes, waits, composite tools and errors give the layer's shape: the
/// same fields (each spawn makes a tab of its own), the same binding, the
/// same error codes.
@MainActor
@Test func controlToolServerWritesWaitsAndErrorsHaveTheLayersShape() async throws {
    let harness = try ControlAgentWaitHarness()
    defer {
        harness.stop()
    }
    let root = harness.projectRoot.path
    let socketURL = harness.socketURL
    harness.server.start()
    let helper = try await harness.spawnAgent(named: "Helper")
    try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))
    try harness.settings.upsertCommand(ProjectCommandDefinition(name: "Echo", command: "/bin/cat"), for: root)
    let started = try await harness.send(.startProcess(.init(processName: "Echo", kind: "command")))
    guard case .startProcess(let echo)? = started.result else {
        Issue.record("Expected a startProcess result, got \(String(describing: started))")
        return
    }

    func both(
        _ name: String,
        _ arguments: [String: JSONValue],
        bindsSession: Bool = false
    ) async throws -> (typed: CallToolResult, app: CallToolResult) {
        let typed = await controlToolOverTypedRequests(
            name,
            arguments,
            caller: CherryToolCaller(bindsSession: bindsSession, projectRoot: root),
            socketURL: socketURL
        )
        let app = try await controlToolCall(name, arguments, context: .init(bindsSession: bindsSession, projectRoot: root), socketURL: socketURL)
        return (typed, app)
    }
    func expectSameShape(_ name: String, _ arguments: [String: JSONValue], bindsSession: Bool = false) async throws -> (typed: CallToolResult, app: CallToolResult) {
        let results = try await both(name, arguments, bindsSession: bindsSession)
        #expect(!results.app.isError, "\(name): \(results.app.text)")
        #expect(results.app.isError == results.typed.isError, "\(name): \(results.typed.text)")
        #expect(controlToolFields(results.app) == controlToolFields(results.typed), "\(name)")
        return results
    }

    let terminals = try await expectSameShape("spawn_process", ["kind": .string("terminal")])
    for result in [terminals.typed, terminals.app] {
        #expect(result.structured?.objectValue?["process"]?.objectValue?["kind"] == .string("terminal"))
    }
    #expect(controlToolProcessID(terminals.typed) != controlToolProcessID(terminals.app))

    let input = try await expectSameShape("send_process_input", ["process_name": .string("Echo"), "text": .string("ping\n")])
    #expect(input.app.structured?.objectValue?["sentBytes"] == .int(5))
    #expect(input.app.structured?.objectValue?["sentBytes"] == input.typed.structured?.objectValue?["sentBytes"])

    let idle = try await expectSameShape("wait_for_process_idle", ["process_name": .string("Echo"), "quiet_ms": .int(100), "timeout_ms": .int(300)])
    #expect(idle.app.structured?.objectValue?["reason"] != nil)

    // Binding: only for a caller that keeps a session, and then the same
    // process either way.
    let bound = try await both("bind_session_process", ["process_id": .string(echo.process.id)], bindsSession: true)
    #expect(bound.app.text == bound.typed.text)
    #expect(bound.app.bindProcessID == echo.process.id)
    #expect(bound.typed.bindProcessID == echo.process.id)
    let unbound = try await both("bind_session_process", ["process_id": .string(echo.process.id)])
    #expect(controlToolErrorCode(unbound.app) == "mcp_context_unavailable")
    #expect(controlToolErrorCode(unbound.typed) == "mcp_context_unavailable")
    #expect(unbound.app.bindProcessID == nil)

    let tasks = try await expectSameShape("spawn_agent", ["name": .string("Worker"), "task": .string("Review the parser."), "label": .string("Review")])
    for result in [tasks.typed, tasks.app] {
        #expect(result.structured?.objectValue?["taskID"]?.stringValue?.hasPrefix("task-") == true, "\(result.text)")
        #expect(result.structured?.objectValue?["runID"]?.stringValue?.hasPrefix("run-") == true, "\(result.text)")
    }

    let message = try await expectSameShape("send_agent_message", [
        "process_id": .string(helper.id.uuidString), "message": .string("hello"),
        "quiet_ms": .int(200), "timeout_ms": .int(3_000),
    ])
    #expect(message.app.structured?.objectValue?["wait"] != nil)
    #expect(controlToolProcessID(message.app) == helper.id.uuidString)

    let subscriptions = try await expectSameShape("subscribe", ["process_ids": .array([.string(helper.id.uuidString)])])
    for result in [subscriptions.typed, subscriptions.app] {
        let id = try #require(result.structured?.objectValue?["subscription"]?.objectValue?["subscriptionID"]?.stringValue, "\(result.text)")
        let typedEvents = await controlToolOverTypedRequests(
            "wait_for_events",
            ["subscription_id": .string(id), "timeout_ms": .int(0)],
            caller: CherryToolCaller(projectRoot: root),
            socketURL: socketURL
        )
        let appEvents = try await controlToolCall(
            "wait_for_events",
            ["subscription_id": .string(id), "timeout_ms": .int(0)],
            context: .init(projectRoot: root),
            socketURL: socketURL
        )
        #expect(!appEvents.isError, "\(appEvents.text)")
        #expect(controlToolFields(appEvents) == controlToolFields(typedEvents))
    }

    // Errors: the same codes, before or after a request.
    let noTask = try await both("get_my_task", [:])
    #expect(controlToolErrorCode(noTask.app) == "no_assignment")
    #expect(controlToolErrorCode(noTask.typed) == "no_assignment")
    var sent: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { sent.append($0) }
    let unknown = try await both("no_such_tool", ["process_id": .string(helper.id.uuidString)])
    #expect(controlToolErrorCode(unknown.app) == "unknown_tool")
    #expect(unknown.app.text == unknown.typed.text)
    #expect(sent.isEmpty, "an unknown tool sends no request")
    let missing = try await both("get_task", [:])
    #expect(controlToolErrorCode(missing.app) == "missing_argument")
    #expect(missing.app.text == missing.typed.text)
    #expect(sent.isEmpty, "a missing argument is refused before any request")
}

// MARK: - The caller

/// A callTool's defaults come from the caller Cherry verified: its own tab
/// is the process a tool names by default and the parent of the agents it
/// spawns, whatever it claims. Only when Cherry verified none does the
/// claim fill in, as CherryMCP's environment did.
@MainActor
@Test func controlToolServerDefaultsComeFromTheVerifiedCaller() async throws {
    let harness = try ControlAgentWaitHarness()
    defer {
        harness.stop()
    }
    let root = harness.projectRoot.path
    let socketURL = harness.socketURL
    harness.server.start()
    try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))
    let lead = try await harness.spawnAgent(named: "Lead")
    let other = try await harness.spawnAgent(named: "Other")
    harness.server.callerSessionResolverForTesting = { _ in lead }

    let status = try await controlToolCall("get_process_status", context: .init(projectRoot: root), socketURL: socketURL)
    #expect(controlToolProcessID(status) == lead.id.uuidString, "\(status.text)")

    let spawned = try await controlToolCall("spawn_agent", ["name": .string("Worker")], context: .init(projectRoot: root), socketURL: socketURL)
    let child = try #require(controlToolProcessID(spawned).flatMap { harness.workspace.session(id: $0) }, "\(spawned.text)")
    #expect(child.parentAgentID == lead.id)

    // A claim naming another tab loses to the verified caller.
    let claimingOther = ToolCallContext(callerProcessID: other.id.uuidString, projectRoot: root)
    let whoami = try await controlToolCall("whoami", context: claimingOther, socketURL: socketURL)
    #expect(whoami.structured?.objectValue?["callerProcessID"] == .string(lead.id.uuidString), "\(whoami.text)")
    let claimedStatus = try await controlToolCall("get_process_status", context: claimingOther, socketURL: socketURL)
    #expect(controlToolProcessID(claimedStatus) == lead.id.uuidString)

    // No verified caller: the claim, as today.
    harness.server.callerSessionResolverForTesting = { _ in nil }
    let claimed = try await controlToolCall("whoami", context: claimingOther, socketURL: socketURL)
    #expect(claimed.structured?.objectValue?["callerProcessID"] == .string(other.id.uuidString), "\(claimed.text)")
    let otherStatus = try await controlToolCall("get_process_status", context: claimingOther, socketURL: socketURL)
    #expect(controlToolProcessID(otherStatus) == other.id.uuidString)
    let nested = try await controlToolCall("spawn_agent", ["name": .string("Worker")], context: claimingOther, socketURL: socketURL)
    let otherChild = try #require(controlToolProcessID(nested).flatMap { harness.workspace.session(id: $0) }, "\(nested.text)")
    #expect(otherChild.parentAgentID == other.id)
    // A claim of only spaces is none.
    let blank = try await controlToolCall("whoami", context: .init(callerProcessID: "  ", projectRoot: root), socketURL: socketURL)
    #expect(blank.structured?.objectValue?["callerProcessID"] == nil, "\(blank.text)")
}

/// A tool call is never scoped (its project is an argument), and its
/// requests never include another tool request.
@MainActor
@Test func controlToolServerRefusesToolRequestsInsideAScopedOne() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    harness.server.start()
    var sent: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { sent.append($0) }

    let nested: [CherryControlRequest] = [.callTool(.init(name: "list_projects")), .appInfo, .listTools(.init())]
    for request in nested {
        let scoped = CherryControlRequest.scoped(.init(projectRoot: harness.projectRoot.path, request: request))
        let response = try await controlToolSend(scoped, socketURL: harness.socketURL)
        #expect(response.result == nil)
        #expect(response.error?.code == "invalid_request", "\(request)")
        #expect(response.error?.message == "A tool call is never scoped: pass project_root in its arguments.")
    }
    #expect(sent.isEmpty)
}

/// A device's listener checks the caller's token before it says anything
/// about the app, and refuses a request without one.
@MainActor
@Test func controlToolServerChecksADevicesTokenBeforeDescribingItself() async throws {
    let harness = try ControlServerHarness()
    defer {
        harness.stop()
    }
    let device = UUID()
    let requests: [CherryControlRequest] = [.appInfo, .listTools(.init()), .callTool(.init(name: "list_projects"))]
    for request in requests {
        let bare = await harness.server.handleRequestData(try JSONEncoder().encode(request), peerPID: nil, origin: .device(device))
        #expect(bare.error?.code == "unauthorized", "\(request)")
        #expect(bare.result == nil)

        let envelope = CherryControlEnvelope(
            cherryAuth: CherryControlCredentials(token: "not-a-token", processID: UUID().uuidString),
            request: request
        )
        let data = try JSONEncoder().encode(envelope)
        let forged = await harness.server.handleRequestData(data, peerPID: nil, origin: .device(device))
        #expect(forged.error?.code == "unauthorized", "\(request)")
        #expect(forged.result == nil)
        // On This Mac's socket a token names a device's tab too.
        let local = await harness.server.handleRequestData(data, peerPID: nil, origin: .thisMac)
        #expect(local.error?.code == "unauthorized", "\(request)")
    }
}

// MARK: - Wait caps

/// The waits accept as long as a tool call's client allows
/// (`callerWaitCapMilliseconds`, its profile's cap) and 50 s for a typed
/// request; the default stays 50 s either way.
@MainActor
@Test func controlToolServerClampsWaitsToTheCallersCap() async throws {
    #expect(CherryControlServer.callerWaitCapMilliseconds == nil)
    #expect(CherryControlServer.callerWaitMilliseconds(100_000, typedMaximum: 50_000) == 50_000)
    #expect(CherryControlServer.callerWaitMilliseconds(nil, typedMaximum: 50_000) == 50_000)
    #expect(CherryControlServer.callerWaitMilliseconds(-1, typedMaximum: 50_000) == 0)
    CherryControlServer.$callerWaitCapMilliseconds.withValue(120_000) {
        #expect(CherryControlServer.callerWaitMilliseconds(100_000, typedMaximum: 50_000) == 100_000)
        #expect(CherryControlServer.callerWaitMilliseconds(200_000, typedMaximum: 50_000) == 120_000)
        #expect(CherryControlServer.callerWaitMilliseconds(nil, typedMaximum: 50_000) == 50_000)
        // The profile's rule.
        let profile = ToolClientProfile.unknown
        #expect(CherryControlServer.callerWaitMilliseconds(nil, typedMaximum: 50_000)
            == min(profile.clampedWait(nil, default: CherryControl.defaultWaitMilliseconds), 120_000))
    }

    let harness = try ControlAgentWaitHarness()
    defer {
        harness.stop()
    }
    harness.server.start()
    let socketURL = harness.socketURL

    // A tool call's requests run under its client's cap.
    var caps: [Int?] = []
    harness.server.toolDispatchWillSendForTesting = { _ in caps.append(CherryControlServer.callerWaitCapMilliseconds) }
    _ = try await controlToolCall("list_projects", context: .init(profile: controlToolClaudeProfile), socketURL: socketURL)
    _ = try await controlToolCall("list_projects", socketURL: socketURL)
    #expect(caps == [controlToolClaudeProfile.waitCapMilliseconds, ToolClientProfile.unknown.waitCapMilliseconds])
    harness.server.toolDispatchWillSendForTesting = nil

    // wait_for_events and wait_for_tasks wait no longer than the cap: a
    // 300 ms one ends a 10 s wait early.
    let worker = try await harness.spawnAgent(named: "Watched")
    let subscribed = try await harness.send(.subscribe(.init(processIDs: [worker.id.uuidString])))
    guard case .subscribe(let subscription)? = subscribed.result else {
        Issue.record("Expected a subscribe result, got \(String(describing: subscribed))")
        return
    }
    _ = try await harness.send(.waitForEvents(.init(subscriptionID: subscription.subscription.subscriptionID, timeoutMilliseconds: 0)))
    let eventsStart = ContinuousClock.now
    let events = try await CherryControlServer.$callerWaitCapMilliseconds.withValue(300) {
        try await harness.server.waitForEvents(.init(subscriptionID: subscription.subscription.subscriptionID, timeoutMilliseconds: 10_000))
    }
    #expect(ContinuousClock.now - eventsStart < .seconds(5))
    #expect(events.timedOut)

    try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))
    let spawned = try await harness.send(.spawnProcess(.init(kind: "agent", name: "Worker", task: "Review")))
    guard case .spawnProcess(let task)? = spawned.result, let runID = task.task?.runID else {
        Issue.record("Expected a task's spawnProcess result, got \(String(describing: spawned))")
        return
    }
    let tasksStart = ContinuousClock.now
    let waited = try await CherryControlServer.$callerWaitCapMilliseconds.withValue(300) {
        try await harness.server.waitForTasks(.init(runID: runID, until: "all", timeoutMilliseconds: 10_000))
    }
    #expect(ContinuousClock.now - tasksStart < .seconds(5))
    #expect(waited.timedOut)
}
