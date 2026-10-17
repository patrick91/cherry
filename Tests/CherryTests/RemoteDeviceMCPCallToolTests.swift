import CherryControl
import Foundation
import Testing
@testable import Cherry

// Cherry MCP for agents on another Mac, run by the app (control protocol 2):
// every boundary case of RemoteDeviceMCPTests.swift again as a callTool,
// with the same expected code. A device's CherryMCP sends one callTool in
// its token's envelope; the app runs the tool layer as that caller, each of
// the tool's requests through the device's choke point, its token checked
// again before each. The typed cases stay in RemoteDeviceMCPTests: older
// helpers on devices still send typed requests.

extension DeviceMCPHarness {
    /// `name` as a CherryMCP sends it: a callTool, in `credentials`'
    /// envelope on a device's listener (`socket`), or bare on This Mac's
    /// socket.
    func callToolResponse(
        _ name: String,
        _ arguments: [String: JSONValue] = [:],
        context: ToolCallContext? = nil,
        to socket: URL? = nil,
        credentials: CherryControlCredentials?
    ) async throws -> CherryControlResponse {
        try await send(.callTool(.init(name: name, arguments: arguments, context: context)), to: socket, credentials: credentials)
    }

    /// `name` run by the app: the tool's result. A request the app refused
    /// as a whole (no result) is thrown as its error.
    func callTool(
        _ name: String,
        _ arguments: [String: JSONValue] = [:],
        context: ToolCallContext? = nil,
        to socket: URL? = nil,
        credentials: CherryControlCredentials?
    ) async throws -> CallToolResult {
        let response = try await callToolResponse(name, arguments, context: context, to: socket, credentials: credentials)
        guard case .callTool(let result)? = response.result else {
            throw response.error ?? CherryControlError(code: "call_failed", message: "Expected a callTool result, got \(response)")
        }
        return result
    }
}

/// The code of a tool's error, nil for a result.
private func remoteToolErrorCode(_ result: CallToolResult) -> String? {
    guard result.isError else { return nil }
    return result.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue
}

/// A tool's result as the control result it carries: its structured
/// content has the result's own (camelCase) keys.
private func remoteToolPayload<Payload: Decodable>(_ type: Payload.Type, _ result: CallToolResult) throws -> Payload {
    guard !result.isError, let structured = result.structured else {
        throw CherryControlError(code: "unexpected_result", message: "Expected \(Payload.self), got \(result.text)")
    }
    return try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(structured))
}

/// The processes a list_processes result lists.
private func remoteToolProcessIDs(_ result: CallToolResult) -> Set<String>? {
    (try? remoteToolPayload(ListProcessesResult.self, result)).map { Set($0.processes.map(\.id)) }
}

/// The top-level field `key` of a result.
private func remoteToolField(_ result: CallToolResult, _ key: String) -> JSONValue? {
    result.structured?.objectValue?[key]
}

/// A tool's arguments, with `extra` added.
private func remoteToolArguments(_ arguments: [String: JSONValue], _ extra: [String: JSONValue]) -> [String: JSONValue] {
    arguments.merging(extra) { _, new in new }
}

// MARK: - The handshake and the boundary

/// The tool requests are refused as requests (no result) to any caller
/// without a valid token of an open tab of the listener's device: before
/// any tool runs, and before the app says what it is.
@Test @MainActor func RemoteDeviceMCPCallToolListenerRefusesCallersWithoutAValidTokenOfAnOpenTab() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let tabID = harness.tab.id.uuidString
    var sent: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { sent.append($0) }
    let toolRequests: [CherryControlRequest] = [.callTool(.init(name: "list_processes")), .appInfo, .listTools(.init())]
    func answers(_ credentials: CherryControlCredentials?, to socket: URL? = nil) async throws -> [String] {
        var codes: [String] = []
        for request in toolRequests {
            let answer = try await harness.send(request, to: socket ?? listener, credentials: credentials)
            codes.append(answer.result == nil ? answer.error?.code ?? "no answer" : "answered")
        }
        return codes
    }
    let refused = Array(repeating: "unauthorized", count: toolRequests.count)
    // No token (no envelope): refused (never identified by its process).
    #expect(try await answers(nil) == refused)
    // A wrong token, another tab's id, another device's token, a tab id that is no UUID.
    #expect(try await answers(.init(token: String(repeating: "0", count: 64), processID: tabID)) == refused)
    let other = try #require(harness.deviceWorkspace.sessions.first { $0.id != harness.tab.id })
    #expect(try await answers(.init(token: harness.credentials.token, processID: other.id.uuidString)) == refused)
    let otherDeviceToken = harness.tokens.token(tabID: harness.tab.id, deviceID: harness.otherDeviceID, generation: "x")
    #expect(try await answers(.init(token: otherDeviceToken, processID: tabID)) == refused)
    #expect(try await answers(.init(token: "x", processID: "not-a-tab")) == refused)
    // A This Mac tab's id with a token made for it: not a device's tab.
    let here = try await harness.startLocalEcho()
    let hereToken = harness.tokens.newGeneration(tabID: here.id, deviceID: harness.deviceID)
    #expect(try await answers(.init(token: hereToken, processID: here.id.uuidString)) == refused)
    #expect(sent.isEmpty, "a refused caller's tool sent no request: \(sent)")
    // The tab's own token: the app says what it is, and the tool reaches
    // its window's processes.
    #expect(try await answers(harness.credentials) == ["answered", "answered", "answered"])
    let info = try await harness.send(.appInfo, to: listener, credentials: harness.credentials)
    guard case .appInfo(let app)? = info.result else {
        Issue.record("Expected appInfo, got \(info)")
        return
    }
    #expect(app.controlProtocol == CherryControl.controlProtocolVersion)
    let listed = try await harness.callTool("list_processes", to: listener, credentials: harness.credentials)
    #expect(!listed.isError, "\(listed.text)")
    #expect(remoteToolProcessIDs(listed) == Set(harness.deviceWorkspace.sessions.map(\.id.uuidString)))
    // Another device's listener refuses this device's token.
    let otherListener = try harness.server.addDeviceListener(deviceID: harness.otherDeviceID)
    #expect(try await answers(harness.credentials, to: otherListener) == refused)
    // Closing the tab revokes its token.
    let valid = harness.credentials
    harness.deviceWorkspace.close(harness.tab, allowEmptyWorkspace: true)
    #expect(try await answers(valid) == refused)
    harness.server.removeDeviceListener(deviceID: harness.deviceID)
    #expect(!FileManager.default.fileExists(atPath: listener.path))
}

/// (a) `..` in a project root never leaves the caller's Mac, as the tool's
/// `project_root` or as the caller's own (its CHERRY_PROJECT_ROOT):
/// refused, and This Mac's live command gets no spawn and no input. A
/// working directory there names no project of its Mac either.
@Test @MainActor func RemoteDeviceMCPCallToolDotDotInAProjectRootIsRefusedAndReachesNoThisMacWindow() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    // It is live: a local caller's tool call reaches it.
    let local = try await harness.callTool("send_process_input", [
        "project_root": .string(harness.localRoot.path), "process_id": .string(echo.id.uuidString),
        "text": .string("local-ok\n"), "wait_ms": .int(300), "line_limit": .int(20),
    ], credentials: nil)
    #expect(!local.isError, "\(local.text)")
    #expect(try await harness.output(of: echo).contains("local-ok"))
    let sessionsBefore = harness.localWorkspace.sessions.map(\.id)
    let escapes = [
        String(repeating: "/..", count: 40) + harness.localRoot.path,
        "/Users/them/work/app/" + String(repeating: "../", count: 40) + harness.localRoot.path.dropFirst(),
        harness.deviceKey + String(repeating: "/..", count: 40) + harness.localRoot.path,
        "/./" + harness.localRoot.path.dropFirst(),
    ]
    let spawn: [String: JSONValue] = ["kind": .string("terminal"), "title": .string("escaped"), "text": .string("spawned-here\n")]
    let input: [String: JSONValue] = ["process_name": .string("Echo"), "text": .string("escaped-input\n")]
    for root in escapes {
        let ways: [([String: JSONValue], ToolCallContext?)] = [(["project_root": .string(root)], nil), ([:], .init(projectRoot: root))]
        for (arguments, context) in ways {
            let spawned = try await harness.callTool(
                "spawn_process", remoteToolArguments(arguments, spawn), context: context,
                to: listener, credentials: harness.credentials
            )
            #expect(remoteToolErrorCode(spawned) == "invalid_project_root", "\(root): \(spawned.text)")
            let typed = try await harness.callTool(
                "send_process_input", remoteToolArguments(arguments, input), context: context,
                to: listener, credentials: harness.credentials
            )
            #expect(remoteToolErrorCode(typed) == "invalid_project_root", "\(root): \(typed.text)")
        }
        // As its working directory: no project of its Mac contains it, so
        // the tool runs in its own window, which has no Echo.
        let fromThere = try await harness.callTool(
            "send_process_input", input, context: .init(workingDirectory: root),
            to: listener, credentials: harness.credentials
        )
        #expect(["terminal_not_found", "process_not_found"].contains(remoteToolErrorCode(fromThere)), "\(root): \(fromThere.text)")
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.localWorkspace.sessions.map(\.id) == sessionsBefore)
    let echoed = try await harness.output(of: echo)
    #expect(echoed.contains("local-ok"))
    #expect(!echoed.contains("escaped-input") && !echoed.contains("spawned-here"))
}

/// (b) A tool call inside a scoped request, as one JSON line: refused (a
/// tool call is never scoped; its project is an argument), and its tool
/// never runs. The app's other tool requests are never scoped either.
@Test @MainActor func RemoteDeviceMCPCallToolInsideAScopedRequestIsRefused() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    _ = try await harness.startLocalEcho()
    let sessionsBefore = harness.localWorkspace.sessions.map(\.id)
    let deviceSessionsBefore = harness.deviceWorkspace.sessions.map(\.id)
    var sent: [CherryControlRequest] = []
    harness.server.toolDispatchWillSendForTesting = { sent.append($0) }
    let call = CherryControlRequest.callTool(.init(name: "spawn_process", arguments: [
        "project_root": .string(harness.localRoot.path), "kind": .string("terminal"), "title": .string("nested"),
    ]))
    for request in [call, .appInfo, .listTools(.init())] {
        let envelope = CherryControlEnvelope(
            cherryAuth: harness.credentials,
            request: .scoped(.init(projectRoot: harness.remotePath, request: request))
        )
        let answer = try await harness.sendLine(String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self), to: listener)
        #expect(answer.error?.code == "invalid_request", "\(request): \(answer)")
        #expect(answer.error?.message.hasPrefix("A tool call is never scoped") == true, "\(request): \(answer)")
        #expect(answer.result == nil)
    }
    // Scoped to This Mac's project: refused too (not open on its Mac).
    let thisMac = CherryControlEnvelope(
        cherryAuth: harness.credentials,
        request: .scoped(.init(projectRoot: harness.localRoot.path, request: call))
    )
    let thisMacAnswer = try await harness.sendLine(String(decoding: try JSONEncoder().encode(thisMac), as: UTF8.self), to: listener)
    #expect(thisMacAnswer.error != nil && thisMacAnswer.result == nil, "\(thisMacAnswer)")
    #expect(sent.isEmpty, "\(sent)")
    #expect(harness.localWorkspace.sessions.map(\.id) == sessionsBefore)
    #expect(harness.deviceWorkspace.sessions.map(\.id) == deviceSessionsBefore)
}

/// (c) A This Mac tab's process id, its window registered where the server
/// looks: not found for a caller on another Mac, for every tool that takes
/// one, the composite ones too, and as the process its session is bound to.
@Test @MainActor func RemoteDeviceMCPCallToolThisMacProcessIDsAreNotFoundForARemoteCaller() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    let id = JSONValue.string(echo.id.uuidString)
    // A local caller in the device window finds it (the window is registered).
    let localView = try await harness.callTool(
        "get_process_status", ["project_root": .string(harness.deviceKey), "process_id": id], credentials: nil
    )
    #expect(!localView.isError, "\(localView.text)")
    let otherDeviceTab = try #require(harness.otherDeviceWorkspace.sessions.first).id.uuidString
    let calls: [(String, [String: JSONValue])] = [
        ("get_process_status", ["process_id": id]),
        ("get_process_output", ["process_id": id]),
        ("send_process_input", ["process_id": id, "text": .string("remote-input\n")]),
        ("restart_process", ["process_id": id]),
        ("close_process", ["process_id": id]),
        ("stop_process", ["process_id": id]),
        ("get_process_ports", ["process_id": id]),
        ("get_process_status", ["process_id": .string(otherDeviceTab)]),
        // The tools the layer makes of several requests.
        ("send_agent_message", ["process_id": id, "message": .string("remote-input"), "wait_for_idle": .bool(false)]),
        ("bind_session_process", ["process_id": id]),
    ]
    let session = ToolCallContext(bindsSession: true)
    for (name, arguments) in calls {
        let result = try await harness.callTool(name, arguments, context: session, to: listener, credentials: harness.credentials)
        #expect(["terminal_not_found", "process_not_found"].contains(remoteToolErrorCode(result)), "\(name) \(arguments): \(result.text)")
        #expect(result.bindProcessID == nil)
    }
    // Its session bound to it: the same.
    let bound = try await harness.callTool(
        "get_process_status", context: .init(boundProcessID: echo.id.uuidString, bindsSession: true),
        to: listener, credentials: harness.credentials
    )
    #expect(["terminal_not_found", "process_not_found"].contains(remoteToolErrorCode(bound)), "\(bound.text)")
    // Claiming to be it: the caller is its token's tab, as Cherry knows it.
    let claimed = try await harness.callTool(
        "get_process_status", context: .init(callerProcessID: echo.id.uuidString),
        to: listener, credentials: harness.credentials
    )
    #expect(try remoteToolPayload(ProcessStatusResult.self, claimed).process.id == harness.tab.id.uuidString, "\(claimed.text)")
    // A link to it resolves to nothing.
    let link = CherryDeepLink(projectRoot: harness.localRoot.path, kind: .terminal, targetID: echo.id.uuidString).absoluteString
    let resolved = try await harness.callTool(
        "resolve_link", ["link": .string(link), "include_output": .bool(true)], to: listener, credentials: harness.credentials
    )
    let result = try remoteToolPayload(ResolveDeepLinkResult.self, resolved)
    #expect(!result.found && result.output == nil && result.process == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(echo.isRunning)
    let echoed = try await harness.output(of: echo)
    #expect(!echoed.contains("remote-input"))
}

/// (d) Another device's key, or a This Mac root, as a project: refused, as
/// the tool's `project_root` or as the caller's own.
@Test @MainActor func RemoteDeviceMCPCallToolAnotherMacsProjectIsRefused() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let before = harness.otherDeviceWorkspace.sessions.map(\.id)
    let otherKey = JSONValue.string(harness.otherDeviceKey)
    for (name, arguments) in [
        ("list_processes", ["project_root": otherKey]),
        ("spawn_process", ["project_root": otherKey, "kind": .string("terminal"), "title": .string("x")]),
        ("open_project", ["project_root": otherKey]),
    ] as [(String, [String: JSONValue])] {
        let result = try await harness.callTool(name, arguments, to: listener, credentials: harness.credentials)
        #expect(remoteToolErrorCode(result) == "outside_caller_mac", "\(name): \(result.text)")
    }
    let claimed = try await harness.callTool(
        "list_processes", context: .init(projectRoot: harness.otherDeviceKey), to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(claimed) == "outside_caller_mac", "\(claimed.text)")
    // This Mac's path is a path on the caller's Mac, which is not open.
    let local = try await harness.callTool(
        "list_processes", ["project_root": .string(harness.localRoot.path)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(local) == "project_unavailable", "\(local.text)")
    let open = try await harness.callTool(
        "open_project", ["project_root": .string(harness.localRoot.path)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(open) == "project_not_found", "\(open.text)")
    // Its own project by path and by key: its window.
    let deviceIDs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    let byPath = try await harness.callTool(
        "list_processes", ["project_root": .string(harness.remotePath)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolProcessIDs(byPath) == deviceIDs, "\(byPath.text)")
    let byKey = try await harness.callTool(
        "list_processes", ["project_root": .string(harness.deviceKey)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolProcessIDs(byKey) == deviceIDs, "\(byKey.text)")
    // A folder inside it: its window too.
    let inside = try await harness.callTool(
        "get_project_status", ["project_root": .string(harness.remotePath + "/Sources")], to: listener, credentials: harness.credentials
    )
    #expect(try remoteToolPayload(ProjectStatusResult.self, inside).projectRoot == harness.deviceKey)
    #expect(harness.otherDeviceWorkspace.sessions.map(\.id) == before)
}

/// (e) Listing tools list only the caller's Mac, whatever project or
/// directory it says it is in, and get_status names no socket of This Mac.
@Test @MainActor func RemoteDeviceMCPCallToolListingsShowOnlyTheCallersMac() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    let deviceIDs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    // Projects: only its Mac's (This Mac's and the other device's are
    // configured and open, and a local caller sees them).
    let listed = try remoteToolPayload(
        ListProjectsResult.self, try await harness.callTool("list_projects", to: listener, credentials: harness.credentials)
    )
    #expect(listed.projects.map(\.root) == [harness.deviceKey])
    #expect(listed.activeProjectRoot == harness.deviceKey)
    let all = try remoteToolPayload(ListProjectsResult.self, try await harness.callTool("list_projects", credentials: nil))
    #expect(all.projects.count == 3 && all.projects.map(\.root).contains(harness.otherDeviceKey))
    #expect(all.projects.contains { !ProjectLocation.isRemoteKey($0.root) })
    // Processes and terminals: its window's only.
    let processes = try await harness.callTool("list_processes", to: listener, credentials: harness.credentials)
    #expect(remoteToolProcessIDs(processes) == deviceIDs, "\(processes.text)")
    #expect(!processes.text.contains(echo.id.uuidString))
    let status = try await harness.callTool("get_status", to: listener, credentials: harness.credentials)
    #expect(remoteToolField(status, "cherryReachable") == .bool(true), "\(status.text)")
    #expect(remoteToolField(status, "terminalCount") == .int(deviceIDs.count), "\(status.text)")
    // The socket a caller on another Mac uses is its own forward there.
    #expect(remoteToolField(status, "socketPath") == nil, "\(status.text)")
    let project = try await harness.callTool("get_project_status", to: listener, credentials: harness.credentials)
    #expect(try remoteToolPayload(ProjectStatusResult.self, project).projectRoot == harness.deviceKey)
    let whoami = try await harness.callTool("whoami", to: listener, credentials: harness.credentials)
    #expect(remoteToolField(whoami, "callerProcessID") == .string(harness.tab.id.uuidString), "\(whoami.text)")
    #expect(remoteToolField(whoami, "activeProjectRoot") == .string(harness.deviceKey))
    #expect(remoteToolField(whoami, "effectiveProjectRoot") == .string(harness.deviceKey))
    // Its project as its environment names it (the path there), and a
    // directory in This Mac's project as its cwd: still its window only.
    for context in [ToolCallContext(projectRoot: harness.remotePath), ToolCallContext(workingDirectory: harness.localRoot.path)] {
        let scoped = try await harness.callTool("list_processes", context: context, to: listener, credentials: harness.credentials)
        #expect(remoteToolProcessIDs(scoped) == deviceIDs, "\(context): \(scoped.text)")
    }
}

/// A device project's second window (#22): its tab's token is accepted,
/// though the project's most recently active window is the first, and its
/// tools, scoped ones too, reach its own window; the first window's tab
/// still reaches its own.
@Test @MainActor func RemoteDeviceMCPCallToolReachesATabOfAProjectsSecondWindow() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let (second, tab) = harness.openAnotherDeviceWindow()
    #expect(ProjectWindowRegistry.shared.workspace(for: harness.deviceKey) === harness.deviceWorkspace)
    let token = harness.tokens.newGeneration(tabID: tab.id, deviceID: harness.deviceID)
    let credentials = CherryControlCredentials(token: token, processID: tab.id.uuidString)
    let secondIDs = Set(second.sessions.map(\.id.uuidString))
    let firstIDs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    let scoped: [String: JSONValue] = ["project_root": .string(harness.remotePath)]

    let unscoped = try await harness.callTool("list_processes", to: listener, credentials: credentials)
    #expect(remoteToolProcessIDs(unscoped) == secondIDs, "\(unscoped.text)")
    let inItsWindow = try await harness.callTool("list_processes", scoped, to: listener, credentials: credentials)
    #expect(remoteToolProcessIDs(inItsWindow) == secondIDs, "\(inItsWindow.text)")
    let asItsProject = try await harness.callTool(
        "list_processes", context: .init(projectRoot: harness.remotePath), to: listener, credentials: credentials
    )
    #expect(remoteToolProcessIDs(asItsProject) == secondIDs, "\(asItsProject.text)")
    let first = try await harness.callTool("list_processes", scoped, to: listener, credentials: harness.credentials)
    #expect(remoteToolProcessIDs(first) == firstIDs, "\(first.text)")
    let whoami = try await harness.callTool("whoami", to: listener, credentials: credentials)
    #expect(remoteToolField(whoami, "callerProcessID") == .string(tab.id.uuidString), "\(whoami.text)")
    #expect(remoteToolField(whoami, "effectiveProjectRoot") == .string(harness.deviceKey))
}

/// Monitors keep to the caller's Mac: a caller on another Mac watches only
/// its Mac's processes, and never sees This Mac's subscriptions (nor This
/// Mac's callers its own). Its subscriber is its own tab, as its token
/// says, whatever it claims to be.
@Test @MainActor func RemoteDeviceMCPCallToolMonitorsReachOnlyTheCallersMac() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let echo = try await harness.startLocalEcho()
    let thisMac = try await harness.callTool(
        "subscribe", ["process_ids": .array([.string(echo.id.uuidString)])], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(thisMac) == "terminal_not_found", "\(thisMac.text)")
    let otherDeviceTab = try #require(harness.otherDeviceWorkspace.sessions.first).id.uuidString
    let otherMac = try await harness.callTool(
        "subscribe", ["process_ids": .array([.string(otherDeviceTab)])], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(otherMac) == "terminal_not_found", "\(otherMac.text)")

    // Its own Mac's tab: watched; the subscriber is the token's tab (a
    // terminal here, so it is only polled), though it claims the watched one.
    let server = try #require(harness.deviceWorkspace.sessions.first { $0.id != harness.tab.id })
    let remote = try await harness.callTool(
        "subscribe", ["process_ids": .array([.string(server.id.uuidString)])],
        context: .init(callerProcessID: server.id.uuidString), to: listener, credentials: harness.credentials
    )
    let remoteSubscription = try remoteToolPayload(SubscribeResult.self, remote)
    #expect(remoteSubscription.subscription.subscriberProcessID == harness.tab.id.uuidString)
    #expect(remoteSubscription.subscription.wake == false)

    // This Mac's subscription is not the remote caller's, and the other
    // way round.
    let local = try await harness.callTool(
        "subscribe", ["project_root": .string(harness.localRoot.path), "process_ids": .array([.string(echo.id.uuidString)])],
        credentials: nil
    )
    let localID = try remoteToolPayload(SubscribeResult.self, local).subscription.subscriptionID
    let remoteID = remoteSubscription.subscription.subscriptionID
    let read = try await harness.callTool(
        "wait_for_events", ["subscription_id": .string(localID), "timeout_ms": .int(0)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(read) == "unknown_subscription", "\(read.text)")
    let removed = try await harness.callTool(
        "unsubscribe", ["subscription_id": .string(localID)], to: listener, credentials: harness.credentials
    )
    #expect(try remoteToolPayload(UnsubscribeResult.self, removed).removed == false)
    let listed = try await harness.callTool("list_subscriptions", to: listener, credentials: harness.credentials)
    #expect(try remoteToolPayload(ListSubscriptionsResult.self, listed).subscriptions.map(\.subscriptionID) == [remoteID])
    let localRead = try await harness.callTool(
        "wait_for_events", ["subscription_id": .string(remoteID), "timeout_ms": .int(0)], credentials: nil
    )
    #expect(remoteToolErrorCode(localRead) == "unknown_subscription", "\(localRead.text)")
    let stillThere = try await harness.callTool(
        "wait_for_events", ["subscription_id": .string(localID), "timeout_ms": .int(0)], credentials: nil
    )
    #expect(!stillThere.isError, "\(stillThere.text)")
}

/// Tasks keep to the caller's Mac: a caller on another Mac hands out tasks
/// in its own window and sees only the tasks and runs its Mac's callers
/// made; This Mac's callers never see those, nor it theirs. Its tab, which
/// has no task, has no assignment.
@Test @MainActor func RemoteDeviceMCPCallToolTasksReachOnlyTheCallersMac() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))

    let remote = try await harness.callTool(
        "spawn_agent", ["name": .string("Worker"), "task": .string("Review there"), "label": .string("there")],
        to: listener, credentials: harness.credentials
    )
    let remoteTaskID = try #require(remoteToolField(remote, "taskID")?.stringValue, "\(remote.text)")
    let remoteWorker = try #require(remoteToolField(remote, "process")?.objectValue?["id"]?.stringValue, "\(remote.text)")
    #expect(harness.deviceWorkspace.session(id: remoteWorker) != nil, "the worker is in the caller's window")
    let local = try await harness.callTool(
        "spawn_agent",
        ["project_root": .string(harness.localRoot.path), "name": .string("Worker"), "task": .string("Review here")],
        credentials: nil
    )
    let localTaskID = try #require(remoteToolField(local, "taskID")?.stringValue, "\(local.text)")
    let localRunID = try #require(remoteToolField(local, "runID")?.stringValue, "\(local.text)")
    let localWorker = try #require(remoteToolField(local, "process")?.objectValue?["id"]?.stringValue, "\(local.text)")

    // The caller on another Mac: its Mac's task only.
    let own = try await harness.callTool("get_task", ["task_id": .string(remoteTaskID)], to: listener, credentials: harness.credentials)
    #expect(try remoteToolPayload(AgentTaskDetail.self, own).brief == "Review there")
    let thisMacTask = try await harness.callTool(
        "get_task", ["task_id": .string(localTaskID)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(thisMacTask) == "unknown_task", "\(thisMacTask.text)")
    let thisMacRun = try await harness.callTool(
        "wait_for_tasks", ["run_id": .string(localRunID), "timeout_ms": .int(0)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(thisMacRun) == "unknown_run", "\(thisMacRun.text)")
    let cancel = try await harness.callTool(
        "cancel_tasks", ["task_ids": .array([.string(localTaskID)]), "close": .bool(true)], to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(cancel) == "unknown_task", "\(cancel.text)")
    let listed = try await harness.callTool("list_tasks", to: listener, credentials: harness.credentials)
    let remoteList = try remoteToolPayload(ListTasksResult.self, listed)
    #expect(remoteList.tasks.map(\.taskID) == [remoteTaskID])
    #expect(remoteList.runs.first?.ownerProcessID == harness.tab.id.uuidString, "its run is its token's tab's")
    // Its tab has no task, whatever it claims to be.
    let assignment = try await harness.callTool("get_my_task", to: listener, credentials: harness.credentials)
    #expect(remoteToolErrorCode(assignment) == "no_assignment", "\(assignment.text)")
    let claimed = try await harness.callTool(
        "get_my_task", context: .init(callerProcessID: remoteWorker), to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(claimed) == "no_assignment", "\(claimed.text)")

    // This Mac's callers: never the other Mac's task.
    let fromThisMac = try await harness.callTool("get_task", ["task_id": .string(remoteTaskID)], credentials: nil)
    #expect(remoteToolErrorCode(fromThisMac) == "unknown_task", "\(fromThisMac.text)")
    let localList = try await harness.callTool("list_tasks", ["project_root": .string(harness.localRoot.path)], credentials: nil)
    #expect(try remoteToolPayload(ListTasksResult.self, localList).tasks.map(\.taskID) == [localTaskID])
    #expect(harness.localWorkspace.session(id: localWorker) != nil, "the other Mac's cancel closed nothing here")
}

// MARK: - Second review: sessions of other hosts, local scans

/// A session of This Mac, or of another SSH host, attached into the
/// device's window (Persistent Sessions): not on the caller's Mac, so it
/// is neither listed nor found by id or name, and its token is refused. A
/// session of the device's own host attached there is its Mac's.
@Test @MainActor func RemoteDeviceMCPCallToolSessionsOfAnotherHostInTheDevicesWindowAreNotItsMacs() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    func attachment(_ host: HostedSessionHost, _ id: String, _ name: String) -> HostedSessionAttachment {
        HostedSessionAttachment(
            host: host, hostID: "host-\(id)", sessionID: id, name: name,
            remoteWorkingDirectory: "/Users/me", executablePath: "/nonexistent/cherry"
        )
    }
    let deviceTabs = Set(harness.deviceWorkspace.sessions.map(\.id.uuidString))
    let thisMac = harness.deviceWorkspace.attachHostedSession(attachment(.local, "here", "Here Shell"), launchShell: false)
    let otherHost = harness.deviceWorkspace.attachHostedSession(
        attachment(try HostedSessionHost.ssh("elsewhere"), "there", "Elsewhere Shell"), launchShell: false
    )
    let ownHost = harness.deviceWorkspace.attachHostedSession(
        attachment(harness.deviceHosting.profile.host, "own", "Own Shell"), launchShell: false
    )
    // The attached This Mac tab is the one the window shows.
    harness.deviceWorkspace.select(thisMac)
    let reachable = deviceTabs.union([ownHost.id.uuidString])

    // Listings: only the device's.
    let processes = try await harness.callTool("list_processes", to: listener, credentials: harness.credentials)
    let listed = try remoteToolPayload(ListProcessesResult.self, processes)
    #expect(Set(listed.processes.map(\.id)) == reachable, "\(processes.text)")
    #expect(listed.selectedProcessID == nil)
    let status = try await harness.callTool("get_status", to: listener, credentials: harness.credentials)
    #expect(remoteToolField(status, "terminalCount") == .int(reachable.count), "\(status.text)")
    #expect(remoteToolField(status, "selectedTerminalID") == nil, "\(status.text)")
    let project = try remoteToolPayload(
        ProjectStatusResult.self, try await harness.callTool("get_project_status", to: listener, credentials: harness.credentials)
    )
    #expect(project.processCounts.total == reachable.count)
    #expect(project.selectedProcessID == nil)
    // The device's own host's session is reachable.
    let own = try await harness.callTool(
        "get_process_status", ["process_id": .string(ownHost.id.uuidString)], to: listener, credentials: harness.credentials
    )
    #expect(!own.isError, "\(own.text)")

    // By id, by name, and every tool that acts on a session: not found.
    let session = ToolCallContext(bindsSession: true)
    for foreign in [thisMac, otherHost] {
        let id = JSONValue.string(foreign.id.uuidString)
        let name = JSONValue.string(foreign.title)
        let calls: [(String, [String: JSONValue])] = [
            ("get_process_status", ["process_id": id]),
            ("get_process_status", ["process_name": name]),
            ("get_process_output", ["process_id": id]),
            ("send_process_input", ["process_id": id, "text": .string("remote-input\n")]),
            ("send_process_input", ["process_name": name, "text": .string("remote-input\n")]),
            ("restart_process", ["process_id": id]),
            ("close_process", ["process_id": id]),
            ("stop_process", ["process_id": id]),
            ("select_process", ["process_id": id]),
            ("wait_for_process_idle", ["process_id": id, "timeout_ms": .int(50)]),
            ("get_process_ports", ["process_id": id]),
            ("wait_for_bound_port", ["process_id": id, "timeout_ms": .int(50)]),
            ("send_agent_message", ["process_id": id, "message": .string("remote-input"), "wait_for_idle": .bool(false)]),
            ("send_agent_message", ["process_name": name, "message": .string("remote-input"), "wait_for_idle": .bool(false)]),
            ("bind_session_process", ["process_id": id]),
        ]
        for (tool, arguments) in calls {
            let result = try await harness.callTool(tool, arguments, context: session, to: listener, credentials: harness.credentials)
            #expect(["terminal_not_found", "process_not_found"].contains(remoteToolErrorCode(result)), "\(tool) \(arguments): \(result.text)")
        }
        let link = CherryDeepLink(projectRoot: harness.deviceKey, kind: .terminal, targetID: foreign.id.uuidString).absoluteString
        let resolved = try await harness.callTool(
            "resolve_link", ["link": .string(link), "include_output": .bool(true)], to: listener, credentials: harness.credentials
        )
        let result = try remoteToolPayload(ResolveDeepLinkResult.self, resolved)
        #expect(!result.found && result.process == nil && result.output == nil, "\(resolved.text)")
        // Its token is refused: it is not a tab of the device.
        let token = harness.tokens.newGeneration(tabID: foreign.id, deviceID: harness.deviceID)
        let asIt = try await harness.callToolResponse(
            "list_processes", to: listener, credentials: .init(token: token, processID: foreign.id.uuidString)
        )
        #expect(asIt.error?.code == "unauthorized" && asIt.result == nil, "\(asIt)")
    }
    #expect(harness.deviceWorkspace.session(withID: thisMac.id) != nil)
    #expect(harness.deviceWorkspace.session(withID: otherHost.id) != nil)
    // This Mac's own callers still see the whole window.
    let local = try await harness.callTool("list_processes", ["project_root": .string(harness.deviceKey)], credentials: nil)
    #expect(remoteToolProcessIDs(local) == reachable.union([thisMac.id.uuidString, otherHost.id.uuidString]), "\(local.text)")
}

/// This Mac's port scan (lsof) never runs for a caller on another Mac, and
/// `include_unattributed` (This Mac's every listener) is refused.
@Test @MainActor func RemoteDeviceMCPCallToolNeverScansThisMacsPorts() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    let tabID = JSONValue.string(harness.tab.id.uuidString)
    let everyListener: [String: JSONValue] = ["include_unattributed": .bool(true)]
    for (name, arguments) in [
        ("services_list", everyListener),
        ("get_process_ports", remoteToolArguments(everyListener, ["process_id": tabID])),
        ("wait_for_bound_port", remoteToolArguments(everyListener, ["port": .int(5432), "timeout_ms": .int(50)])),
        ("wait_for_bound_port", remoteToolArguments(everyListener, ["port": .int(5432), "timeout_ms": .int(50), "probe_http": .bool(true)])),
    ] as [(String, [String: JSONValue])] {
        let result = try await harness.callTool(name, arguments, to: listener, credentials: harness.credentials)
        #expect(remoteToolErrorCode(result) == "unattributed_not_available", "\(name) \(arguments): \(result.text)")
    }
    // Without it: nothing of This Mac's is scanned either.
    let services = try await harness.callTool("services_list", to: listener, credentials: harness.credentials)
    #expect(!services.isError, "\(services.text)")
    #expect(try remoteToolPayload(ServicesResult.self, services).unattributed.isEmpty)
    let wait = try await harness.callTool(
        "wait_for_bound_port", ["port": .int(5432), "timeout_ms": .int(200), "probe_http": .bool(true)],
        to: listener, credentials: harness.credentials
    )
    #expect(remoteToolErrorCode(wait) == "port_wait_timed_out", "\(wait.text)")
    #expect(harness.localServices.calls.isEmpty, "\(harness.localServices.calls)")
    // A local caller's scan still runs.
    _ = try await harness.callTool("services_list", everyListener, credentials: nil)
    #expect(harness.localServices.calls.contains { $0.includeUnattributed })
}

// MARK: - Revocation during a tool call

/// A tool of several requests checks the caller's token again before each:
/// a tab closed, or a program restarted (a new token), after
/// send_agent_message looked its target up is refused the input, so
/// nothing is typed and nothing more is sent.
@Test @MainActor func RemoteDeviceMCPCallToolChecksTheTokenAgainBeforeEachOfItsRequests() async throws {
    let harness = try DeviceMCPHarness()
    defer { harness.stop() }
    let listener = try harness.server.addDeviceListener(deviceID: harness.deviceID)
    try harness.settings.upsertAgent(AgentToolDefinition(name: "Worker", command: "/bin/cat"))
    let spawned = try await harness.callTool("spawn_agent", ["name": .string("Worker")], to: listener, credentials: harness.credentials)
    let targetID = try #require(remoteToolField(spawned, "process")?.objectValue?["id"]?.stringValue, "\(spawned.text)")
    let target = try #require(harness.deviceWorkspace.session(id: targetID))
    func message(_ text: String) -> [String: JSONValue] {
        ["process_id": .string(targetID), "message": .string(text), "wait_for_idle": .bool(false)]
    }
    var sent: [CherryControlRequest] = []
    var revoke: (() -> Void)?
    harness.server.toolDispatchWillSendForTesting = { request in
        sent.append(request)
        // Its target was looked up; the input is next.
        if case .sendProcessInput = request { revoke?() }
    }
    func sentInput() -> Bool {
        sent.contains { if case .sendProcessInput = $0 { true } else { false } }
    }

    // Unrevoked, the message reaches its target's input, which refuses it
    // (its agent could not start on the inert host), never the caller.
    let reached = try await harness.callTool("send_agent_message", message("reached"), to: listener, credentials: harness.credentials)
    #expect(remoteToolErrorCode(reached) == "process_not_accepting_input", "\(reached.text)")
    #expect(sent.count == 2 && sentInput(), "\(sent)")
    let submittedAt = target.lastAgentSubmitAt
    let submittedTurns = target.agentSubmittedTurnCount

    let server = try #require(harness.deviceWorkspace.sessions.first { $0.id != harness.tab.id && $0.id != target.id })
    let serverToken = harness.tokens.newGeneration(tabID: server.id, deviceID: harness.deviceID)
    let callers: [(String, CherryControlCredentials, () -> Void)] = [
        ("closed", harness.credentials, { harness.deviceWorkspace.close(harness.tab, allowEmptyWorkspace: true) }),
        ("restarted", .init(token: serverToken, processID: server.id.uuidString), {
            _ = harness.tokens.newGeneration(tabID: server.id, deviceID: harness.deviceID)
        }),
    ]
    for (what, credentials, revocation) in callers {
        sent = []
        revoke = revocation
        let result = try await harness.callTool("send_agent_message", message("never-typed"), to: listener, credentials: credentials)
        revoke = nil
        #expect(remoteToolErrorCode(result) == "unauthorized", "\(what): \(result.text)")
        let refusal = result.structured?.objectValue?["error"]?.objectValue?["message"]?.stringValue
        #expect(refusal?.hasPrefix("Cherry refused this Cherry MCP token") == true, "\(what): \(result.text)")
        // The lookup, then the input it was refused; no wait after it.
        #expect(sent.count == 2, "\(what): \(sent)")
        if case .getProcessStatus? = sent.first {} else { Issue.record("\(what): \(sent)") }
        #expect(sentInput(), "\(what): \(sent)")
        #expect(target.lastAgentSubmitAt == submittedAt && target.agentSubmittedTurnCount == submittedTurns, "\(what)")
        // Refused from now on, as a request.
        let after = try await harness.callToolResponse("list_processes", to: listener, credentials: credentials)
        #expect(after.error?.code == "unauthorized" && after.result == nil, "\(what): \(after)")
    }
    // Its screen, as This Mac's callers read it.
    let output = try await harness.callTool(
        "get_process_output", ["project_root": .string(harness.deviceKey), "process_id": .string(targetID)], credentials: nil
    )
    #expect(!output.isError && !output.text.contains("never-typed"), "\(output.text)")
}
