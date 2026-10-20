import Foundation

// MARK: - The MCP tool layer
//
// One MCP tool call, run as its caller: its arguments parsed, its requests
// scoped to the caller's project, the composite tools (whoami,
// bind_session_process, spawn_agent, send_agent_message) made of several
// requests, and the answer encoded as agents read it. The app runs it for
// `callTool`, each request dispatched in-process as the caller; CherryMCP
// runs it over the socket against an app without `appInfo`. Either way it
// sends only typed requests, which every app answers as it answers an older
// CherryMCP.

/// Where the layer sends its requests.
public protocol CherryToolTransport: Sendable {
    /// One control request as the caller (the app: in-process; CherryMCP: over the socket).
    func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse
    /// The socket this caller uses, for get_status: CherryMCP's own; in the app, its server's for
    /// This Mac's callers and nil for a device's (which report their own forward).
    var socketPath: String? { get }
}

/// The socket, with the blocking client run off Swift's cooperative pool (a dispatch queue).
public struct SocketToolTransport: CherryToolTransport {
    public let socketURL: URL
    /// A tab of another Mac's token and id (`CherryControlClient.credentials`).
    public let credentials: CherryControlCredentials?
    /// The Mac Cherry runs on, when the socket is a forward to it.
    public let controlMachine: String?

    public init(
        socketURL: URL = CherryControl.socketURL,
        credentials: CherryControlCredentials? = .fromEnvironment(),
        controlMachine: String? = ProcessInfo.processInfo.environment[CherryControl.controlMachineEnvironmentKey]
    ) {
        self.socketURL = socketURL
        self.credentials = credentials
        self.controlMachine = controlMachine
    }

    public var socketPath: String? { socketURL.path }

    /// A client blocks its thread until Cherry answers (a wait, up to its
    /// timeout): on threads of their own, parallel waits never starve the
    /// cooperative pool the MCP server runs on.
    private static let queue = DispatchQueue(label: "CherryControl.SocketToolTransport", attributes: .concurrent)

    /// `request` on a new connection; `timeout` nil is the client's
    /// default (10 s).
    public func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse {
        let client = CherryControlClient(
            socketURL: socketURL,
            timeout: timeout ?? 10,
            credentials: credentials,
            controlMachine: controlMachine
        )
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try client.send(request) })
            }
        }
    }
}

/// Who calls a tool, as far as the layer needs to know: the defaults a
/// call that names no process, parent or project gets.
public struct CherryToolCaller: Sendable {
    /// The caller's tab (the app: verifiedCallerSession()?.id ?? claim; legacy: env, else ancestry):
    /// whoami's caller, the default parent of an agent it spawns (when that
    /// tab is an agent) and the subscriber of its subscriptions.
    public var processID: String?
    /// The MCP session's bound process, the default process of a tool that
    /// names none (else `processID`).
    public var boundProcessID: String?
    /// False: bind_session_process answers mcp_context_unavailable, and
    /// spawn_agent's `bind_session` binds nothing.
    public var bindsSession: Bool
    /// The caller's CHERRY_PROJECT_ROOT: an explicit project_root wins; then this; then
    /// workingDirectory's project.
    public var projectRoot: String?
    /// The caller's current directory, whose innermost open project scopes a
    /// call that names none.
    public var workingDirectory: String?
    public var profile: ToolClientProfile

    public init(
        processID: String? = nil,
        boundProcessID: String? = nil,
        bindsSession: Bool = false,
        projectRoot: String? = nil,
        workingDirectory: String? = nil,
        profile: ToolClientProfile = .unknown
    ) {
        self.processID = processID
        self.boundProcessID = boundProcessID
        self.bindsSession = bindsSession
        self.projectRoot = projectRoot
        self.workingDirectory = workingDirectory
        self.profile = profile
    }
}

/// Cherry's MCP tools, run over a `CherryToolTransport`: the one place a
/// tool's name and arguments become control requests, and their answers
/// the result an agent reads.
public enum CherryToolLayer {
    /// Runs `name` as `caller`. A tool's error is a result too (`isError`,
    /// `text` `{"error":{…}}`); an unknown name is refused before any request
    /// is sent.
    public static func call(
        name: String,
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> CallToolResult {
        do {
            if name == "get_status" {
                return try await statusResult(caller: caller, transport: transport)
            }
            if name == "whoami" {
                return try await whoamiResult(arguments: arguments, caller: caller, transport: transport)
            }
            if name == "bind_session_process" {
                return try await bindSessionProcessResult(arguments: arguments, caller: caller, transport: transport)
            }
            if name == "spawn_agent" {
                return try await spawnAgentResult(arguments: arguments, caller: caller, transport: transport)
            }
            if name == "send_agent_message" {
                return try await sendAgentMessageResult(arguments: arguments, caller: caller, transport: transport)
            }
            let unscoped = try await controlRequest(name: name, arguments: arguments, caller: caller, transport: transport)
            let request = await scopedRequest(unscoped, arguments: arguments, caller: caller, transport: transport)
            let response = try await transport.send(request, timeout: clientTimeout(for: name, arguments: arguments))
            if let error = response.error {
                return try toolError(error)
            }
            guard let result = response.result else {
                return try toolError(.init(code: "empty_response", message: "Cherry returned no result."))
            }
            return try toolResult(result)
        } catch {
            return errorResult(controlError(error))
        }
    }

    /// `error` as a tool's result, encoded as every tool's error is:
    /// `{"error":{…}}`, snake_case keys in its text, camelCase in its
    /// structured content. CherryMCP's own errors use it too, so a pipe's
    /// errors read as the layer's.
    public static func errorResult(_ error: CherryControlError) -> CallToolResult {
        (try? toolError(error)) ?? CallToolResult(text: error.message, isError: true, structured: nil)
    }

    /// A failure as Cherry's error, as a tool reports it: a
    /// `CherryControlError` as it is, anything else `tool_error`.
    public static func controlError(_ error: any Error) -> CherryControlError {
        error as? CherryControlError ?? CherryControlError(code: "tool_error", message: error.localizedDescription)
    }

    private static func whoamiResult(
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CallToolResult {
        let projectsResponse = try? await transport.send(.listProjects, timeout: nil)
        let activeProjectRoot: String?
        if case .listProjects(let projects)? = projectsResponse?.result {
            activeProjectRoot = projects.activeProjectRoot
        } else {
            activeProjectRoot = nil
        }

        let statusRequest = await scopedRequest(.getProjectStatus, arguments: arguments, caller: caller, transport: transport)
        let statusResponse = try await transport.send(statusRequest, timeout: nil)
        let status: ProjectStatusResult = try unwrap(statusResponse, "whoami") {
            guard case .getProjectStatus(let value) = $0 else { return nil }
            return value
        }

        return try encodedResult(MCPWhoamiPayload(
            callerProcessID: caller.processID,
            activeProjectRoot: activeProjectRoot,
            effectiveProjectRoot: status.projectRoot,
            boundProcessID: caller.boundProcessID,
            selectedProcessID: status.selectedProcessID,
            selectedProcessName: status.selectedProcessName
        ))
    }

    private static func bindSessionProcessResult(
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CallToolResult {
        guard caller.bindsSession else {
            return try toolError(.init(code: "mcp_context_unavailable", message: "This MCP transport did not provide mutable session context."))
        }

        let selector = explicitProcessSelector(in: arguments)
        guard selector.processID != nil || selector.processName != nil else {
            return try toolError(.init(code: "missing_process_selector", message: "Provide process_id or process_name."))
        }

        let request = await scopedRequest(.getProcessStatus(selector), arguments: arguments, caller: caller, transport: transport)
        let response = try await transport.send(request, timeout: nil)
        let status: ProcessStatusResult = try unwrap(response, "bind_session_process") {
            guard case .getProcessStatus(let value) = $0 else { return nil }
            return value
        }

        var result = try encodedResult(MCPBindSessionProcessPayload(
            boundProcessID: status.process.id,
            previousBoundProcessID: caller.boundProcessID,
            process: status.process
        ))
        result.bindProcessID = status.process.id
        return result
    }

    private static func spawnAgentResult(
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CallToolResult {
        let message = stringArgument("message", in: arguments)
        let task = stringArgument("task", in: arguments)
        if task != nil, message != nil {
            return try toolError(.init(
                code: "invalid_argument",
                message: "Pass the brief as task or a first message as message, not both: a task's worker reads its brief with get_my_task."
            ))
        }
        let request = CherryControlRequest.spawnProcess(.init(
            kind: "agent",
            name: try requiredString("name", in: arguments),
            model: stringArgument("model", in: arguments),
            effort: stringArgument("effort", in: arguments),
            title: stringArgument("title", in: arguments),
            workingDirectory: nil,
            text: message,
            rawBase64: nil,
            submit: message == nil ? nil : true,
            parentAgentID: await parentAgentIDArgument(forKind: "agent", in: arguments, caller: caller, transport: transport),
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments),
            task: task,
            label: stringArgument("label", in: arguments),
            phase: stringArgument("phase", in: arguments),
            runID: stringArgument("run_id", in: arguments),
            resultSchema: try schemaArgument("result_schema", in: arguments),
            allowSubagents: boolArgument("allow_subagents", in: arguments)
        ))

        let scoped = await scopedRequest(request, arguments: arguments, caller: caller, transport: transport)
        let response = try await transport.send(scoped, timeout: clientTimeout(for: "spawn_agent", arguments: arguments))
        let spawned: SpawnProcessResult = try unwrap(response, "spawn_agent") {
            guard case .spawnProcess(let value) = $0 else { return nil }
            return value
        }

        let shouldBind = (boolArgument("bind_session", in: arguments) ?? false) && caller.bindsSession
        var result = try encodedResult(MCPSpawnAgentPayload(
            process: spawned.process,
            sentBytes: spawned.sentBytes,
            output: spawned.output,
            boundProcessID: shouldBind ? spawned.process.id : nil,
            previousBoundProcessID: shouldBind ? caller.boundProcessID : nil,
            taskID: spawned.task?.taskID,
            runID: spawned.task?.runID,
            task: spawned.task,
            inputError: spawned.inputError
        ))
        if shouldBind {
            result.bindProcessID = spawned.process.id
        }
        return result
    }

    private static func sendAgentMessageResult(
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CallToolResult {
        let message = try requiredString("message", in: arguments)
        let selector = processSelector(in: arguments, caller: caller)
        let timeout = clientTimeout(for: "send_agent_message", arguments: arguments)

        let statusRequest = await scopedRequest(.getProcessStatus(selector), arguments: arguments, caller: caller, transport: transport)
        let statusResponse = try await transport.send(statusRequest, timeout: timeout)
        let status: ProcessStatusResult = try unwrap(statusResponse, "send_agent_message status lookup") {
            guard case .getProcessStatus(let value) = $0 else { return nil }
            return value
        }
        guard status.process.kind == "agent" else {
            return try toolError(.init(
                code: "not_agent_process",
                message: "send_agent_message requires an agent process; \(status.process.name) is kind \(status.process.kind)."
            ))
        }

        let sendRequest = CherryControlRequest.sendProcessInput(.init(
            processID: status.process.id,
            text: message,
            submit: true
        ))
        let sendResponse = try await transport.send(
            await scopedRequest(sendRequest, arguments: arguments, caller: caller, transport: transport),
            timeout: timeout
        )
        let sent: SendProcessInputResult = try unwrap(sendResponse, "send_agent_message input") {
            guard case .sendProcessInput(let value) = $0 else { return nil }
            return value
        }

        let shouldWait = boolArgument("wait_for_idle", in: arguments) ?? true
        guard shouldWait else {
            return try encodedResult(MCPSendAgentMessagePayload(
                process: status.process,
                sentBytes: sent.sentBytes,
                output: sent.output,
                wait: nil
            ))
        }

        let waitRequest = CherryControlRequest.waitForProcessIdle(.init(
            processID: status.process.id,
            requireNewOutput: true,
            quietMilliseconds: intArgument("quiet_ms", in: arguments),
            timeoutMilliseconds: intArgument("timeout_ms", in: arguments) ?? CherryControl.defaultAgentMessageWaitMilliseconds,
            lineLimit: intArgument("line_limit", in: arguments)
        ))
        let waitResponse = try await transport.send(
            await scopedRequest(waitRequest, arguments: arguments, caller: caller, transport: transport),
            timeout: timeout
        )
        let wait: WaitForProcessIdleResult = try unwrap(waitResponse, "send_agent_message idle wait") {
            guard case .waitForProcessIdle(let value) = $0 else { return nil }
            return value
        }

        return try encodedResult(MCPSendAgentMessagePayload(
            process: wait.process,
            sentBytes: sent.sentBytes,
            output: wait.output,
            wait: wait
        ))
    }

    /// The result `extract` finds in `response`. Throws Cherry's error, or
    /// `unexpected_response` for any other result (`call` returns either
    /// as the tool's error).
    private static func unwrap<T>(
        _ response: CherryControlResponse,
        _ what: String,
        _ extract: (CherryControlResult) -> T?
    ) throws -> T {
        if let error = response.error {
            throw error
        }
        guard let result = response.result, let value = extract(result) else {
            throw CherryControlError(code: "unexpected_response", message: "Cherry returned an unexpected response for \(what).")
        }
        return value
    }

    private static func scopedRequest(
        _ request: CherryControlRequest,
        arguments: [String: JSONValue] = [:],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> CherryControlRequest {
        if case .scoped = request {
            return request
        }
        // The requested root is the target of the open itself, whose window
        // may not exist yet: it is not scoped to the caller's project.
        if case .openProject = request {
            return request
        }

        if let projectRoot = explicitProjectRoot(in: arguments) ?? trimmedProjectRoot(caller.projectRoot) {
            return .scoped(.init(projectRoot: projectRoot, request: request))
        }
        guard let projectRoot = await inferredProjectRootFromWorkingDirectory(caller: caller, transport: transport) else {
            return request
        }
        return .scoped(.init(projectRoot: projectRoot, request: request))
    }

    private static func explicitProjectRoot(in arguments: [String: JSONValue]) -> String? {
        trimmedProjectRoot(stringArgument("project_root", in: arguments))
    }

    private static func trimmedProjectRoot(_ value: String?) -> String? {
        guard let projectRoot = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !projectRoot.isEmpty
        else {
            return nil
        }
        return projectRoot
    }

    /// The innermost open project the caller's current directory is in.
    private static func inferredProjectRootFromWorkingDirectory(
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> String? {
        guard let callerDirectory = caller.workingDirectory?.nilIfEmpty else {
            return nil
        }
        let workingDirectory = CherryControl.standardizedProjectRoot(callerDirectory)
        guard let response = try? await transport.send(.listProjects, timeout: nil),
              case .listProjects(let payload)? = response.result
        else {
            return nil
        }

        return payload.projects
            .map { CherryControl.standardizedProjectRoot($0.root) }
            .filter { CherryControl.path(workingDirectory, isInsideProjectRoot: $0) }
            .max { $0.count < $1.count }
    }

    private static func statusResult(
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CallToolResult {
        let socketPath = transport.socketPath
        let socketExists = socketPath.map { FileManager.default.fileExists(atPath: $0) }

        var terminals: ListTerminalsResult?
        var statusError: CherryControlError?
        do {
            let request = await scopedRequest(.listTerminals, caller: caller, transport: transport)
            let response = try await transport.send(request, timeout: nil)
            if let error = response.error {
                statusError = error
            } else if case .listTerminals(let result)? = response.result {
                terminals = result
            } else {
                statusError = .init(code: "unexpected_status_response", message: "Cherry returned an unexpected status response.")
            }
        } catch let error as CherryControlError {
            statusError = error
        } catch {
            statusError = .init(code: "status_failed", message: error.localizedDescription)
        }
        return try encodedResult(MCPStatusPayload(
            socketPath: socketPath,
            socketExists: socketExists,
            cherryReachable: terminals != nil,
            terminalCount: terminals?.terminals.count,
            selectedTerminalID: terminals?.selectedTerminalID,
            error: statusError
        ))
    }

    private static func controlRequest(
        name: String,
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async throws -> CherryControlRequest {
        switch name {
        case "list_projects":
            return .listProjects
        case "open_project":
            return .openProject(.init(projectRoot: try requiredString("project_root", in: arguments)))
        case "get_project_status":
            return .getProjectStatus
        case "resolve_link":
            return .resolveLink(.init(
                link: try requiredString("link", in: arguments),
                includeOutput: boolArgument("include_output", in: arguments),
                startLine: intArgument("start_line", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "list_processes":
            return .listProcesses(.init(kind: stringArgument("kind", in: arguments)))
        case "get_process_status":
            return .getProcessStatus(processSelector(in: arguments, caller: caller))
        case "get_process_output":
            return .getProcessOutput(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                startLine: intArgument("start_line", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "get_process_raw_output":
            return .getProcessRawOutput(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                maxBytes: intArgument("max_bytes", in: arguments)
            ))
        case "search_process_output":
            return .searchProcessOutput(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "wait_for_process_idle":
            return .waitForProcessIdle(waitForProcessIdleRequest(in: arguments, caller: caller))
        case "subscribe":
            return .subscribe(.init(
                processIDs: try stringArrayArgument("process_ids", in: arguments),
                subAgents: boolArgument("sub_agents", in: arguments),
                events: try stringArrayArgument("events", in: arguments),
                outputPattern: stringArgument("output_pattern", in: arguments),
                subscriberProcessID: caller.processID,
                wake: boolArgument("wake", in: arguments)
            ))
        case "unsubscribe":
            return .unsubscribe(.init(subscriptionID: try requiredString("subscription_id", in: arguments)))
        case "wait_for_events":
            return .waitForEvents(.init(
                subscriptionID: try requiredString("subscription_id", in: arguments),
                cursor: intArgument("cursor", in: arguments),
                timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
                maxEvents: intArgument("max_events", in: arguments)
            ))
        case "list_subscriptions":
            return .listSubscriptions
        case "get_my_task":
            return .getMyTask
        case "report_result":
            return .reportResult(.init(
                value: try jsonArgument("value", in: arguments),
                status: stringArgument("status", in: arguments),
                summary: stringArgument("summary", in: arguments)
            ))
        case "report_progress":
            return .reportProgress(.init(
                message: try requiredString("message", in: arguments),
                awaitingApproval: boolArgument("awaiting_approval", in: arguments)
            ))
        case "wait_for_tasks":
            return .waitForTasks(.init(
                runID: stringArgument("run_id", in: arguments),
                taskIDs: try stringArrayArgument("task_ids", in: arguments),
                until: stringArgument("until", in: arguments),
                cursor: intArgument("cursor", in: arguments),
                timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
                maxEvents: intArgument("max_events", in: arguments)
            ))
        case "get_task":
            return .getTask(.init(taskID: try requiredString("task_id", in: arguments)))
        case "list_tasks":
            return .listTasks(.init(
                runID: stringArgument("run_id", in: arguments),
                state: stringArgument("state", in: arguments)
            ))
        case "cancel_tasks":
            return .cancelTasks(.init(
                runID: stringArgument("run_id", in: arguments),
                taskIDs: try stringArrayArgument("task_ids", in: arguments),
                close: boolArgument("close", in: arguments)
            ))
        case "get_process_ports":
            return .getProcessPorts(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments)
            ))
        case "services_list":
            return .servicesList(.init(
                kind: stringArgument("kind", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments)
            ))
        case "wait_for_bound_port":
            return .waitForBoundPort(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                port: intArgument("port", in: arguments),
                timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
                includeUnattributed: boolArgument("include_unattributed", in: arguments),
                probeHTTP: boolArgument("probe_http", in: arguments),
                path: stringArgument("path", in: arguments)
            ))
        case "spawn_process":
            let kind = try requiredString("kind", in: arguments)
            return .spawnProcess(.init(
                kind: kind,
                name: stringArgument("name", in: arguments),
                model: stringArgument("model", in: arguments),
                effort: stringArgument("effort", in: arguments),
                title: stringArgument("title", in: arguments),
                workingDirectory: stringArgument("working_directory", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                submit: boolArgument("submit", in: arguments),
                parentAgentID: await parentAgentIDArgument(forKind: kind, in: arguments, caller: caller, transport: transport),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "start_process":
            return .startProcess(processLifecycle(in: arguments, caller: caller))
        case "stop_process":
            return .stopProcess(processLifecycle(in: arguments, caller: caller))
        case "restart_process":
            return .restartProcess(processLifecycle(in: arguments, caller: caller))
        case "close_process":
            return .closeProcess(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                agentClosePolicy: try agentClosePolicyArgument("agent_close_policy", in: arguments)
            ))
        case "rename_process":
            return .renameProcess(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                title: stringArgument("title", in: arguments)
            ))
        case "select_process":
            return .selectProcess(processSelector(in: arguments, caller: caller))
        case "send_process_input":
            return .sendProcessInput(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                submit: boolArgument("submit", in: arguments),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "answer_prompt":
            let choice: String
            switch arguments["choice"] {
            case .int(let number)?:
                choice = String(number)
            case .double(let number)? where number == number.rounded() && abs(number) < 1_000:
                choice = String(Int(number))
            default:
                choice = try requiredString("choice", in: arguments)
            }
            return .answerPrompt(.init(
                processID: processIDArgument(in: arguments, caller: caller),
                processName: stringArgument("process_name", in: arguments),
                choice: choice,
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "start_all_commands":
            return .startAllCommands(processBulkCommand(in: arguments))
        case "stop_all_commands":
            return .stopAllCommands(processBulkCommand(in: arguments))
        case "restart_all_commands":
            return .restartAllCommands(processBulkCommand(in: arguments))
        case "list_agents":
            return .listAgents
        case "list_todos":
            return .listTodos
        case "create_todo":
            return .createTodo(.init(
                title: try requiredString("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments) ?? "",
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments)
            ))
        case "get_todo":
            return .getTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo":
            return .updateTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments)
            ))
        case "move_todo":
            return .moveTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                afterTodoID: stringArgument("after_todo_id", in: arguments)
            ))
        case "delete_todo":
            return .deleteTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "select_todo":
            return .selectTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "add_todo_comment":
            return .addTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments),
                author: stringArgument("author", in: arguments),
                terminalID: stringArgument("process_id", in: arguments)
            ))
        case "list_todo_comments":
            return .listTodoComments(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo_comment":
            return .updateTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                commentID: try requiredString("comment_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments)
            ))
        case "delete_todo_comment":
            return .deleteTodoComment(.init(
                todoID: try requiredString("todo_id", in: arguments),
                commentID: try requiredString("comment_id", in: arguments)
            ))
        default:
            throw CherryControlError(code: "unknown_tool", message: "Unknown Cherry tool: \(name)")
        }
    }

    private static func toolResult(_ result: CherryControlResult) throws -> CallToolResult {
        switch result {
        case .listProjects(let payload):
            return try encodedResult(payload)
        case .openProject(let payload):
            return try encodedResult(payload)
        case .getProjectStatus(let payload):
            return try encodedResult(payload)
        case .getPerformanceStatus(let payload):
            return try encodedResult(payload)
        case .resolveLink(let payload):
            return try encodedResult(payload)
        case .listProcesses(let payload):
            return try encodedResult(payload)
        case .getProcessStatus(let payload):
            return try encodedResult(payload)
        case .getProcessOutput(let payload):
            return try encodedResult(payload)
        case .getProcessRawOutput(let payload):
            return try encodedResult(payload)
        case .searchProcessOutput(let payload):
            return try encodedResult(payload)
        case .waitForProcessIdle(let payload):
            return try encodedResult(payload)
        case .subscribe(let payload):
            return try encodedResult(payload)
        case .unsubscribe(let payload):
            return try encodedResult(payload)
        case .waitForEvents(let payload):
            return try encodedResult(payload)
        case .listSubscriptions(let payload):
            return try encodedResult(payload)
        case .getMyTask(let payload):
            return try encodedResult(payload)
        case .reportResult(let payload):
            return try encodedResult(payload)
        case .reportProgress(let payload):
            return try encodedResult(payload)
        case .waitForTasks(let payload):
            return try encodedResult(payload)
        case .getTask(let payload):
            return try encodedResult(payload)
        case .listTasks(let payload):
            return try encodedResult(payload)
        case .cancelTasks(let payload):
            return try encodedResult(payload)
        case .getProcessPorts(let payload):
            return try encodedResult(payload)
        case .servicesList(let payload):
            return try encodedResult(payload)
        case .waitForBoundPort(let payload):
            return try encodedResult(payload)
        case .spawnProcess(let payload):
            return try encodedResult(payload)
        case .startProcess(let payload):
            return try encodedResult(payload)
        case .stopProcess(let payload):
            return try encodedResult(payload)
        case .restartProcess(let payload):
            return try encodedResult(payload)
        case .closeProcess(let payload):
            return try encodedResult(payload)
        case .renameProcess(let payload):
            return try encodedResult(payload)
        case .selectProcess(let payload):
            return try encodedResult(payload)
        case .sendProcessInput(let payload):
            return try encodedResult(payload)
        case .answerPrompt(let payload):
            return try encodedResult(payload)
        case .startAllCommands(let payload):
            return try encodedResult(payload)
        case .stopAllCommands(let payload):
            return try encodedResult(payload)
        case .restartAllCommands(let payload):
            return try encodedResult(payload)
        case .listTerminals(let payload):
            return try encodedResult(payload)
        case .listAgents(let payload):
            return try encodedResult(payload)
        case .listTodos(let payload):
            return try encodedResult(payload)
        case .createTodo(let payload):
            return try encodedResult(payload)
        case .getTodo(let payload):
            return try encodedResult(payload)
        case .updateTodo(let payload):
            return try encodedResult(payload)
        case .moveTodo(let payload):
            return try encodedResult(payload)
        case .deleteTodo(let payload):
            return try encodedResult(payload)
        case .selectTodo(let payload):
            return try encodedResult(payload)
        case .addTodoComment(let payload):
            return try encodedResult(payload)
        case .listTodoComments(let payload):
            return try encodedResult(payload)
        case .updateTodoComment(let payload):
            return try encodedResult(payload)
        case .deleteTodoComment(let payload):
            return try encodedResult(payload)
        case .clearOutput(let payload):
            return try encodedResult(payload)
        case .appInfo(let payload):
            return try encodedResult(payload)
        case .listTools(let payload):
            return try encodedResult(payload)
        case .callTool(let payload):
            // Already a tool's result (the layer never sends callTool).
            return payload
        case .runCommand(let payload):
            return try encodedResult(payload)
        }
    }

    private static func encodedResult<Payload: Codable>(_ payload: Payload) throws -> CallToolResult {
        CallToolResult(
            text: try jsonString(payload),
            isError: false,
            structured: try structuredValue(payload)
        )
    }

    private static func toolError(_ error: CherryControlError) throws -> CallToolResult {
        let payload = ErrorPayload(error: error)
        return CallToolResult(
            text: try jsonString(payload),
            isError: true,
            structured: try structuredValue(payload)
        )
    }

    /// `payload` as JSON, encoded as agents read it (`agentFacingEncoder`)
    /// but with its own (camelCase) keys: MCP's `structuredContent`.
    private static func structuredValue<Payload: Encodable>(_ payload: Payload) throws -> JSONValue {
        if let value = payload as? JSONValue {
            return value
        }
        return try JSONValue.parse(agentFacingEncoder().encode(payload))
    }

    private static func jsonString<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = agentFacingEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// What agents read leaves out the fields the control wire keeps only
    /// for older helpers (`cherryAgentFacingOutput`).
    private static func agentFacingEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[.cherryAgentFacingOutput] = true
        return encoder
    }

    private static func requiredString(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard let value = stringArgument(key, in: arguments), !value.isEmpty else {
            throw CherryControlError(code: "missing_argument", message: "Missing required string argument: \(key)")
        }
        return value
    }

    private static func stringArgument(_ key: String, in arguments: [String: JSONValue]) -> String? {
        arguments[key]?.stringValue
    }

    /// A whole number, also when the client sent it as one with a
    /// fraction of zero (`5000.0`).
    private static func intArgument(_ key: String, in arguments: [String: JSONValue]) -> Int? {
        switch arguments[key] {
        case .int(let value)?:
            return value
        case .double(let value)?:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func boolArgument(_ key: String, in arguments: [String: JSONValue]) -> Bool? {
        guard case .bool(let value)? = arguments[key] else {
            return nil
        }
        return value
    }

    private static func parentAgentIDArgument(
        forKind kind: String,
        in arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> String? {
        let explicitParentAgentID = stringArgument("parent_agent_id", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "agent" else {
            return explicitParentAgentID
        }
        if boolArgument("top_level", in: arguments) == true {
            return CherryControl.topLevelAgentParentID
        }
        if let explicitParentAgentID {
            return explicitParentAgentID
        }
        if let callerProcessID = caller.processID,
           await implicitParentAgentIDIsUsable(callerProcessID, arguments: arguments, caller: caller, transport: transport) {
            return callerProcessID
        }
        return nil
    }

    /// Whether the caller's tab is an agent, which nests the agents it
    /// spawns; any other caller spawns top-level agents.
    private static func implicitParentAgentIDIsUsable(
        _ agentID: String,
        arguments: [String: JSONValue],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> Bool {
        let request = await scopedRequest(
            .getProcessStatus(.init(processID: agentID, processName: nil)),
            arguments: arguments,
            caller: caller,
            transport: transport
        )
        guard let response = try? await transport.send(request, timeout: 2),
              response.error == nil,
              case .getProcessStatus(let status)? = response.result
        else {
            return false
        }
        return status.process.kind == "agent"
    }

    /// The process (tab) among `parentPIDs` (nearest first) that Cherry
    /// runs in the caller's project: the caller of a helper whose
    /// environment names none.
    public static func inferredCallerProcessID(
        parentPIDs: [Int32],
        caller: CherryToolCaller,
        transport: some CherryToolTransport
    ) async -> String? {
        let parentPIDs = parentPIDs.filter { $0 > 0 }
        guard !parentPIDs.isEmpty else {
            return nil
        }
        let request = await scopedRequest(.listProcesses(.init()), caller: caller, transport: transport)
        let response = try? await transport.send(request, timeout: 2)
        guard response?.error == nil,
              case .listProcesses(let result)? = response?.result
        else {
            return nil
        }

        for parentPID in parentPIDs {
            if let process = result.processes.first(where: { $0.pid == parentPID }) {
                return process.id
            }
        }
        return nil
    }

    /// An argument as JSON, whatever its type.
    public static func jsonArgument(_ key: String, in arguments: [String: JSONValue]) throws -> JSONValue? {
        arguments[key]
    }

    /// A JSON Schema argument: an object, or JSON text of one (some
    /// clients send nested objects as strings).
    public static func schemaArgument(_ key: String, in arguments: [String: JSONValue]) throws -> JSONValue? {
        guard let value = try jsonArgument(key, in: arguments) else { return nil }
        if case .null = value { return nil }
        if case .string(let text) = value {
            guard let parsed = try? JSONValue.parse(Data(text.utf8)), parsed.objectValue != nil else {
                throw CherryControlError(code: "invalid_argument", message: "\(key) must be a JSON Schema object.")
            }
            return parsed
        }
        return value
    }

    private static func stringArrayArgument(_ key: String, in arguments: [String: JSONValue]) throws -> [String]? {
        guard let value = arguments[key] else { return nil }
        guard let array = value.arrayValue else {
            throw CherryControlError(code: "invalid_argument", message: "\(key) must be an array of strings.")
        }
        var strings: [String] = []
        for item in array {
            guard let string = item.stringValue else {
                throw CherryControlError(code: "invalid_argument", message: "\(key) must be an array of strings.")
            }
            strings.append(string)
        }
        return strings
    }

    private static func todoStatusArgument(_ key: String, in arguments: [String: JSONValue]) throws -> TodoStatus? {
        guard let value = stringArgument(key, in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        guard let status = TodoStatus(rawValue: value.lowercased()) else {
            throw CherryControlError(code: "invalid_todo_status", message: "Unknown todo status: \(value)")
        }
        return status
    }

    private static func agentClosePolicyArgument(_ key: String, in arguments: [String: JSONValue]) throws -> AgentClosePolicy? {
        guard let value = stringArgument(key, in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        guard let policy = AgentClosePolicy(rawValue: value.lowercased()) else {
            throw CherryControlError(
                code: "invalid_agent_close_policy",
                message: "Unknown agent close policy: \(value)"
            )
        }
        return policy
    }

    private static func explicitProcessSelector(in arguments: [String: JSONValue]) -> ProcessSelectorRequest {
        ProcessSelectorRequest(
            processID: trimmedArgument("process_id", in: arguments),
            processName: stringArgument("process_name", in: arguments)
        )
    }

    private static func processSelector(
        in arguments: [String: JSONValue],
        caller: CherryToolCaller
    ) -> ProcessSelectorRequest {
        let processName = stringArgument("process_name", in: arguments)
        return ProcessSelectorRequest(
            processID: processIDArgument(in: arguments, caller: caller),
            processName: processName
        )
    }

    /// The process a tool acts on: its `process_id`; none when it names a
    /// process by `process_name`; else the session's bound process, else
    /// the caller's own.
    private static func processIDArgument(
        in arguments: [String: JSONValue],
        caller: CherryToolCaller
    ) -> String? {
        if let explicit = trimmedArgument("process_id", in: arguments) {
            return explicit
        }

        if let processName = trimmedArgument("process_name", in: arguments), !processName.isEmpty {
            return nil
        }

        return caller.boundProcessID ?? caller.processID
    }

    private static func trimmedArgument(_ key: String, in arguments: [String: JSONValue]) -> String? {
        stringArgument(key, in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func processLifecycle(
        in arguments: [String: JSONValue],
        caller: CherryToolCaller
    ) -> ProcessLifecycleRequest {
        ProcessLifecycleRequest(
            processID: processIDArgument(in: arguments, caller: caller),
            processName: stringArgument("process_name", in: arguments),
            kind: stringArgument("kind", in: arguments),
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func processBulkCommand(in arguments: [String: JSONValue]) -> ProcessBulkCommandRequest {
        ProcessBulkCommandRequest(waitMilliseconds: intArgument("wait_ms", in: arguments))
    }

    private static func waitForProcessIdleRequest(
        in arguments: [String: JSONValue],
        caller: CherryToolCaller
    ) -> WaitForProcessIdleRequest {
        WaitForProcessIdleRequest(
            processID: processIDArgument(in: arguments, caller: caller),
            processName: stringArgument("process_name", in: arguments),
            sinceOutputVersion: intArgument("since_output_version", in: arguments),
            requireNewOutput: boolArgument("require_new_output", in: arguments),
            quietMilliseconds: intArgument("quiet_ms", in: arguments),
            timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    /// How long the client waits for Cherry's answer to one of a tool's
    /// requests: nil for the client's default (10 s).
    public static func clientTimeout(for name: String, arguments: [String: JSONValue]) -> TimeInterval? {
        switch name {
        case "answer_prompt":
            // The menu read (up to 2 s from a host), the highlight's wait
            // (2 s), then `wait_ms`.
            let waitMilliseconds = min(max(intArgument("wait_ms", in: arguments) ?? 0, 0), 5_000)
            return TimeInterval(waitMilliseconds) / 1_000 + 20
        case "spawn_agent", "spawn_process", "send_process_input":
            // Input waits until it reached the program: a persistent-session
            // tab's session may still be created (Cherry gives up after about
            // 16 s), and an agent's input waits for it to be ready. A new
            // agent's first message waits for its session (up to 8 s), then
            // for the agent (up to 6 s), then for the host to take it, and
            // the output is read from the host (up to 2 s) after `wait_ms`.
            let waitMilliseconds = min(max(intArgument("wait_ms", in: arguments) ?? 0, 0), 5_000)
            // A command first waits (at most 10 s) for a restore under way
            // that may bring back its tab, as start_process does.
            let spawnsCommand = name == "spawn_process"
                && stringArgument("kind", in: arguments)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "command"
            return TimeInterval(waitMilliseconds) / 1_000 + 20 + (spawnsCommand ? 10 : 0)
        case "start_process", "start_all_commands", "restart_all_commands":
            // A restore under way may bring back the command's tab: Cherry
            // waits for it (at most 10 s) before it starts anything, then
            // waits `wait_ms`.
            let waitMilliseconds = min(max(intArgument("wait_ms", in: arguments) ?? 0, 0), 5_000)
            return TimeInterval(waitMilliseconds) / 1_000 + 10 + 10
        case "wait_for_process_idle":
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? CherryControl.defaultWaitMilliseconds, 1), 300_000)
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        case "wait_for_events":
            let timeoutMilliseconds = min(
                max(intArgument("timeout_ms", in: arguments) ?? CherryControl.maximumEventWaitMilliseconds, 0),
                CherryControl.maximumEventWaitMilliseconds
            )
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        case "wait_for_tasks":
            let timeoutMilliseconds = min(
                max(intArgument("timeout_ms", in: arguments) ?? CherryControl.maximumTaskWaitMilliseconds, 0),
                CherryControl.maximumTaskWaitMilliseconds
            )
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        case "send_agent_message":
            // One client for the message and the idle wait: the message
            // needs what send_process_input does (20 s), the wait its
            // timeout.
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? CherryControl.defaultAgentMessageWaitMilliseconds, 1), 300_000)
            return max(TimeInterval(timeoutMilliseconds) / 1_000 + 5, 20)
        case "wait_for_bound_port":
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? 10_000, 1), 60_000)
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        default:
            return nil
        }
    }

    /// How long a client waits for a whole `callTool`, which runs all of a
    /// tool's requests in the app: `clientTimeout`, plus what the
    /// composites' own requests take, and a wait as long as the client's
    /// cap allows.
    public static func callTimeout(for name: String, arguments: [String: JSONValue], profile: ToolClientProfile) -> TimeInterval {
        switch name {
        case "send_agent_message":
            // The message (20 s, as send_process_input) and then the idle
            // wait, plus 5 s.
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? CherryControl.defaultAgentMessageWaitMilliseconds, 1), 300_000)
            return TimeInterval(timeoutMilliseconds) / 1_000 + 25
        case "spawn_agent":
            // An agent's spawn first checks that the caller is an agent (at
            // most 2 s) to nest the new one under it.
            return (clientTimeout(for: name, arguments: arguments) ?? 10) + 5
        case "spawn_process" where spawnsAgent(arguments):
            return (clientTimeout(for: name, arguments: arguments) ?? 10) + 5
        case "wait_for_events", "wait_for_tasks":
            let timeoutMilliseconds = profile.clampedWait(
                intArgument("timeout_ms", in: arguments),
                default: CherryControl.defaultWaitMilliseconds
            )
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        default:
            return clientTimeout(for: name, arguments: arguments) ?? 10
        }
    }

    private static func spawnsAgent(_ arguments: [String: JSONValue]) -> Bool {
        stringArgument("kind", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "agent"
    }
}

private struct ErrorPayload: Codable {
    let error: CherryControlError
}

private struct MCPWhoamiPayload: Codable {
    let callerProcessID: String?
    let activeProjectRoot: String?
    let effectiveProjectRoot: String?
    let boundProcessID: String?
    let selectedProcessID: String?
    let selectedProcessName: String?
}

private struct MCPBindSessionProcessPayload: Codable {
    let boundProcessID: String
    let previousBoundProcessID: String?
    let process: ProcessSummary
}

private struct MCPSpawnAgentPayload: Codable {
    let process: ProcessSummary
    let sentBytes: Int
    let output: TerminalOutputResult?
    let boundProcessID: String?
    let previousBoundProcessID: String?
    /// With `task`: the worker's task and its run.
    let taskID: String?
    let runID: String?
    let task: AgentTaskInfo?
    /// Why the message or kickoff did not arrive (`SpawnProcessResult.inputError`).
    let inputError: CherryControlError?
}

private struct MCPSendAgentMessagePayload: Codable {
    let process: ProcessSummary
    let sentBytes: Int
    let output: TerminalOutputResult?
    let wait: WaitForProcessIdleResult?
}

/// get_status: the socket the caller uses (none when the transport has no
/// socket of its own) and whether Cherry answered on it.
private struct MCPStatusPayload: Codable {
    let socketPath: String?
    let socketExists: Bool?
    let cherryReachable: Bool
    let terminalCount: Int?
    let selectedTerminalID: String?
    let error: CherryControlError?
}
