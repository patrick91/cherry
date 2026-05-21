import CherryControl
import Foundation
import MCP

private func cherryMCPClient() -> CherryControlClient {
    CherryControlClient()
}

private func cherryMCPClient(timeout: TimeInterval?) -> CherryControlClient {
    CherryControlClient(timeout: timeout ?? 10)
}

final class CherryMCPToolContext: @unchecked Sendable {
    let sessionID: String?
    private let lock = NSLock()
    private var storedDefaultParentAgentID: String?
    private var storedBoundProcessID: String?

    var defaultParentAgentID: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedDefaultParentAgentID
    }

    var boundProcessID: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedBoundProcessID
    }

    private init(sessionID: String?, defaultParentAgentID: String?) {
        self.sessionID = sessionID
        self.storedDefaultParentAgentID = defaultParentAgentID
    }

    static func bound(sessionID: String? = nil, defaultParentAgentID: String?) -> CherryMCPToolContext {
        CherryMCPToolContext(sessionID: sessionID, defaultParentAgentID: defaultParentAgentID)
    }

    @discardableResult
    func bindProcessID(_ processID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let previous = storedBoundProcessID
        storedBoundProcessID = processID
        return previous
    }
}

enum CherryMCPTools {
    static let all: [Tool] = [
        tool(
            "get_status",
            "Check Cherry MCP helper and app control socket status without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "list_projects",
            "List saved/open Cherry projects and the active project without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "get_project_status",
            "Return active project root, process counts, note/todo counts, selected process, and health without changing the Cherry UI.",
            properties: [:]
        ),
        tool(
            "whoami",
            "Show how Cherry identified this MCP session, effective project scope, selected process, and bound process without changing the Cherry UI.",
            properties: projectScopedProperties()
        ),
        tool(
            "resolve_link",
            "Resolve a cherry://project/... link for a note, todo, or live terminal without changing the Cherry UI.",
            properties: [
                "link": string("Cherry deep link to resolve."),
                "include_output": boolean("For terminal links, include rendered output. Defaults to false."),
                "start_line": integer("Optional zero-based terminal output start line when include_output is true."),
                "line_limit": integer("Maximum rendered terminal output lines when include_output is true. Max 2000.")
            ],
            required: ["link"]
        ),
        tool(
            "list_processes",
            "List terminal, agent, and command processes in the active project without changing the Cherry UI.",
            properties: ["kind": string("Optional process kind filter: terminal, agent, or command.")]
        ),
        tool(
            "get_process_status",
            "Read detailed status for one process by process_id or process_name without changing the Cherry UI.",
            properties: processSelectorProperties(),
            required: []
        ),
        tool(
            "get_process_output",
            "Read rendered output for one process by process_id or process_name.",
            properties: processSelectorProperties([
                "start_line": integer("Optional zero-based start line."),
                "line_limit": integer("Maximum rendered lines. Max 2000.")
            ])
        ),
        tool(
            "get_process_raw_output",
            "Read recent raw output for one process by process_id or process_name, including control sequences.",
            properties: processSelectorProperties([
                "max_bytes": integer("Maximum bytes. Max 1048576.")
            ])
        ),
        tool(
            "search_process_output",
            "Search rendered process output for matching lines.",
            properties: processSelectorProperties([
                "query": string("Text to search for."),
                "case_sensitive": boolean("Whether matching is case-sensitive."),
                "max_matches": integer("Maximum matches. Max 500.")
            ]),
            required: ["query"]
        ),
        tool(
            "wait_for_process_idle",
            "Wait until a process has produced output since the selected baseline and then gone quiet. Prefer this over fixed sleeps after sending input.",
            properties: idleWaitProperties()
        ),
        tool(
            "get_process_ports",
            "Return localhost TCP services associated with one Cherry process. Unattributed listeners are hidden unless include_unattributed is true.",
            properties: processSelectorProperties([
                "include_unattributed": boolean("Whether to include localhost listeners not attributed to the selected Cherry process. Defaults to false.")
            ])
        ),
        tool(
            "services_list",
            "List localhost TCP services for active Cherry processes without changing the Cherry UI. Unattributed listeners are hidden unless include_unattributed is true.",
            properties: [
                "kind": string("Optional process kind filter: terminal, agent, or command."),
                "include_unattributed": boolean("Whether to include localhost listeners not attributed to Cherry processes. Defaults to false.")
            ]
        ),
        tool(
            "wait_for_bound_port",
            "Wait for one matching localhost TCP service. Returns ambiguous_service if multiple services match; narrow with process_id, process_name, or port. HTTP probing only happens when probe_http is true.",
            properties: processSelectorProperties([
                "port": integer("Optional TCP port to wait for."),
                "timeout_ms": integer("Maximum wait in milliseconds. Defaults to 10000, max 60000."),
                "include_unattributed": boolean("Whether to include unattributed localhost listeners. Defaults to false."),
                "probe_http": boolean("Whether to require a successful HTTP GET before returning. Defaults to false."),
                "path": string("HTTP path to probe when probe_http is true. Defaults to /."),
            ])
        ),
        tool(
            "spawn_process",
            "Create a terminal, configured agent, or trusted project command process without selecting it. For agent/command, name must match configured Cherry settings.",
            properties: [
                "kind": string("Process kind: terminal, agent, or command."),
                "name": string("Configured agent or command name. Not used for terminal."),
                "title": string("Optional custom title."),
                "working_directory": string("Optional terminal working directory."),
                "text": string("Optional text to type after launch. CR/LF is encoded as the session's Enter key; use raw_base64 for exact bytes."),
                "raw_base64": string("Optional exact raw bytes to send after launch, base64-encoded."),
                "submit": boolean("For agent processes, whether to submit the input with Enter. Plain text defaults to true; raw bytes default to false."),
                "parent_agent_id": string("For kind=agent, optional parent Cherry agent UUID. Defaults to the current Cherry agent when available, then the selected or latest root agent."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["kind"]
        ),
        tool(
            "spawn_agent",
            "Create a configured Cherry agent process without selecting it. This is the agent-specific wrapper around spawn_process.",
            properties: [
                "name": string("Configured agent name."),
                "title": string("Optional custom title."),
                "message": string("Optional first message to submit after launch. A final Enter is added automatically when omitted."),
                "parent_agent_id": string("Optional parent Cherry agent UUID. Defaults to the current Cherry agent when available, then the selected or latest root agent."),
                "bind_session": boolean("Whether to bind this MCP HTTP session to the spawned agent so later agent tools can omit process_id. Defaults to false; enable only for a single-agent conversation."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ],
            required: ["name"]
        ),
        tool(
            "start_process",
            "Start an existing stopped process, or start a configured command/agent by process_name and kind, without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "stop_process",
            "Stop one process by process_id or process_name without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "restart_process",
            "Restart one process by process_id or process_name without selecting it.",
            properties: processSelectorProperties(lifecycleProperties())
        ),
        tool(
            "close_process",
            "Close one process by process_id or process_name without selecting another UI pane. Parent agents with sub-agents require agent_close_policy.",
            properties: processSelectorProperties([
                "agent_close_policy": string("For parent agents with sub-agents: reject, close_sub_agents, or promote_sub_agents. Defaults to reject.")
            ])
        ),
        tool(
            "rename_process",
            "Rename one process by process_id or process_name without selecting it. Empty title clears explicit title.",
            properties: processSelectorProperties(["title": string("New title. Empty clears the explicit title.")])
        ),
        tool(
            "select_process",
            "Explicitly select one Cherry process in the UI by process_id or process_name.",
            properties: processSelectorProperties()
        ),
        tool(
            "send_process_input",
            "Send terminal text or raw bytes to an existing process by process_id or process_name.",
            properties: processSelectorProperties([
                "text": string("Text to type. CR/LF is encoded as the session's Enter key; use raw_base64 for exact bytes."),
                "raw_base64": string("Exact raw bytes to send, base64-encoded."),
                "submit": boolean("For agent processes, whether to submit the input with Enter. Plain text defaults to true; raw bytes default to false."),
                "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
                "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
            ])
        ),
        tool(
            "send_agent_message",
            "Send a human-style message to a Cherry agent process and optionally wait for the agent to go idle.",
            properties: processSelectorProperties([
                "message": string("Message to submit to the agent. A final Enter is added automatically when omitted."),
                "wait_for_idle": boolean("Whether to wait for new output and a quiet period after sending. Defaults to true."),
                "quiet_ms": integer("Required quiet period in milliseconds when wait_for_idle is true. Defaults to 1000."),
                "timeout_ms": integer("Maximum wait in milliseconds when wait_for_idle is true. Defaults to 60000, max 300000."),
                "line_limit": integer("Rendered output line limit in the response. Max 2000.")
            ]),
            required: ["message"]
        ),
        tool(
            "start_all_commands",
            "Start all trusted configured project commands without selecting them.",
            properties: bulkCommandProperties()
        ),
        tool(
            "stop_all_commands",
            "Stop project command processes only; does not stop ad hoc terminals or agents.",
            properties: bulkCommandProperties()
        ),
        tool(
            "restart_all_commands",
            "Restart all trusted configured project commands without selecting them.",
            properties: bulkCommandProperties()
        ),
        tool(
            "list_agents",
            "List configured Cherry agents available to the active project.",
            properties: [:]
        ),
        tool(
            "list_notes",
            "List Cherry notes for the current or specified project. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties()
        ),
        tool(
            "list_todos",
            "List Cherry todos for the current or specified project. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties()
        ),
        tool(
            "create_note",
            "Create a project-scoped Markdown note in Cherry without opening or selecting it. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties([
                "title": string("Note title."),
                "markdown": string("Markdown content.")
            ]),
            required: ["title", "markdown"]
        ),
        tool(
            "get_note",
            "Read a Cherry Markdown note. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties(["note_id": string("Cherry note UUID.")]),
            required: ["note_id"]
        ),
        tool(
            "update_note",
            "Update a Cherry Markdown note title and/or content without opening or selecting it. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties([
                "note_id": string("Cherry note UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown content.")
            ]),
            required: ["note_id"]
        ),
        tool(
            "append_note",
            "Append Markdown to a Cherry note without opening or selecting it. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties([
                "note_id": string("Cherry note UUID."),
                "markdown": string("Markdown content to append.")
            ]),
            required: ["note_id", "markdown"]
        ),
        tool(
            "rename_note",
            "Rename a Cherry note without opening or selecting it. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties([
                "note_id": string("Cherry note UUID."),
                "title": string("Replacement note title.")
            ]),
            required: ["note_id", "title"]
        ),
        tool(
            "search_notes",
            "Search Cherry note titles and Markdown for the current or specified project without changing the Cherry UI. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties([
                "query": string("Text to search for."),
                "case_sensitive": boolean("Whether matching is case-sensitive."),
                "max_matches": integer("Maximum matches. Max 500.")
            ]),
            required: ["query"]
        ),
        tool(
            "delete_note",
            "Delete a Cherry Markdown note. Requires Notes to be enabled for the project.",
            properties: projectScopedProperties(["note_id": string("Cherry note UUID.")]),
            required: ["note_id"]
        ),
        tool(
            "select_note",
            "Explicitly open an existing Cherry Markdown note for review/editing. Requires Notes to be enabled for the project. Use only when the user asks to switch the Cherry UI.",
            properties: projectScopedProperties(["note_id": string("Cherry note UUID.")]),
            required: ["note_id"]
        ),
        tool(
            "create_todo",
            "Create a project-scoped Cherry todo without opening or selecting it. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties([
                "title": string("Todo title."),
                "markdown": string("Optional Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "tags": stringArray("Optional todo tag names.")
            ]),
            required: ["title"]
        ),
        tool(
            "get_todo",
            "Read a Cherry todo, including comments. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties(["todo_id": string("Cherry todo UUID.")]),
            required: ["todo_id"]
        ),
        tool(
            "update_todo",
            "Update a Cherry todo title, Markdown details, and/or status without opening or selecting it. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties([
                "todo_id": string("Cherry todo UUID."),
                "title": string("Optional replacement title."),
                "markdown": string("Optional replacement Markdown details."),
                "status": string("Optional status: backlog, ready, doing, blocked, or done."),
                "tags": stringArray("Optional replacement todo tag names. Empty array clears tags.")
            ]),
            required: ["todo_id"]
        ),
        tool(
            "move_todo",
            "Move a Cherry todo to another status and/or position without opening or selecting it. Requires Todos to be enabled for the project. If status changes and after_todo_id is omitted, the todo is appended to the target status.",
            properties: projectScopedProperties([
                "todo_id": string("Cherry todo UUID."),
                "status": string("Optional target status: backlog, ready, doing, blocked, or done."),
                "after_todo_id": string("Optional todo UUID in the target status to place this todo after.")
            ]),
            required: ["todo_id"]
        ),
        tool(
            "delete_todo",
            "Delete a Cherry todo. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties(["todo_id": string("Cherry todo UUID.")]),
            required: ["todo_id"]
        ),
        tool(
            "select_todo",
            "Explicitly open an existing Cherry todo in the todo pane. Requires Todos to be enabled for the project. Use only when the user asks to switch the Cherry UI.",
            properties: projectScopedProperties(["todo_id": string("Cherry todo UUID.")]),
            required: ["todo_id"]
        ),
        tool(
            "add_todo_comment",
            "Append a comment to a Cherry todo without opening or selecting it. Requires Todos to be enabled for the project. Pass process_id for agent attribution when commenting from a Cherry agent session.",
            properties: projectScopedProperties([
                "todo_id": string("Cherry todo UUID."),
                "markdown": string("Comment Markdown."),
                "author": string("Optional author label used when process_id is not provided."),
                "process_id": string("Optional Cherry process UUID for attribution.")
            ]),
            required: ["todo_id", "markdown"]
        ),
        tool(
            "list_todo_comments",
            "List comments for a Cherry todo without opening or selecting it. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties(["todo_id": string("Cherry todo UUID.")]),
            required: ["todo_id"]
        ),
        tool(
            "update_todo_comment",
            "Update a Cherry todo comment without opening or selecting it. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties([
                "todo_id": string("Cherry todo UUID."),
                "comment_id": string("Cherry todo comment UUID."),
                "markdown": string("Replacement comment Markdown.")
            ]),
            required: ["todo_id", "comment_id", "markdown"]
        ),
        tool(
            "delete_todo_comment",
            "Delete a Cherry todo comment without opening or selecting it. Requires Todos to be enabled for the project.",
            properties: projectScopedProperties([
                "todo_id": string("Cherry todo UUID."),
                "comment_id": string("Cherry todo comment UUID.")
            ]),
            required: ["todo_id", "comment_id"]
        ),
        tool(
            "bind_session_process",
            "Bind this MCP HTTP session to one Cherry process so later process tools can omit process_id. Does not change the Cherry UI.",
            properties: processSelectorProperties()
        )
    ]

    static func call(
        name: String,
        arguments: [String: Value],
        context: CherryMCPToolContext? = nil
    ) async -> CallTool.Result {
        do {
            if name == "get_status" {
                return try statusResult()
            }
            if name == "whoami" {
                return try await whoamiResult(arguments: arguments, context: context)
            }
            if name == "bind_session_process" {
                return try await bindSessionProcessResult(arguments: arguments, context: context)
            }
            if name == "spawn_agent" {
                return try await spawnAgentResult(arguments: arguments, context: context)
            }
            if name == "send_agent_message" {
                return try await sendAgentMessageResult(arguments: arguments, context: context)
            }
            let request = scopedRequest(try controlRequest(name: name, arguments: arguments, context: context), arguments: arguments)
            let response = try cherryMCPClient(timeout: clientTimeout(for: name, arguments: arguments)).send(request)
            if let error = response.error {
                return try toolError(error)
            }
            guard let result = response.result else {
                return try toolError(.init(code: "empty_response", message: "Cherry returned no result."))
            }
            return try toolResult(result)
        } catch let error as CherryControlError {
            return (try? toolError(error)) ?? .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            let controlError = CherryControlError(code: "tool_error", message: error.localizedDescription)
            return (try? toolError(controlError)) ?? .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func whoamiResult(
        arguments: [String: Value],
        context: CherryMCPToolContext?
    ) async throws -> CallTool.Result {
        let projectsResponse = try? cherryMCPClient().send(.listProjects)
        let activeProjectRoot: String?
        if case .listProjects(let projects)? = projectsResponse?.result {
            activeProjectRoot = projects.activeProjectRoot
        } else {
            activeProjectRoot = nil
        }

        let statusResponse = try cherryMCPClient().send(scopedRequest(.getProjectStatus, arguments: arguments))
        if let error = statusResponse.error {
            return try toolError(error)
        }
        guard case .getProjectStatus(let status)? = statusResponse.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for whoami."))
        }

        return try encodedResult(MCPWhoamiPayload(
            mcpSessionID: context?.sessionID,
            activeProjectRoot: activeProjectRoot,
            effectiveProjectRoot: status.projectRoot,
            boundProcessID: context?.boundProcessID,
            defaultParentAgentID: context?.defaultParentAgentID,
            selectedProcessID: status.selectedProcessID,
            selectedProcessName: status.selectedProcessName
        ))
    }

    private static func bindSessionProcessResult(
        arguments: [String: Value],
        context: CherryMCPToolContext?
    ) async throws -> CallTool.Result {
        guard let context else {
            return try toolError(.init(code: "mcp_context_unavailable", message: "This MCP transport did not provide mutable session context."))
        }

        let selector = explicitProcessSelector(in: arguments)
        guard selector.processID != nil || selector.processName != nil else {
            return try toolError(.init(code: "missing_process_selector", message: "Provide process_id or process_name."))
        }

        let response = try cherryMCPClient().send(scopedRequest(.getProcessStatus(selector), arguments: arguments))
        if let error = response.error {
            return try toolError(error)
        }
        guard case .getProcessStatus(let status)? = response.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for bind_session_process."))
        }

        let previous = context.bindProcessID(status.process.id)
        return try encodedResult(MCPBindSessionProcessPayload(
            mcpSessionID: context.sessionID,
            boundProcessID: status.process.id,
            previousBoundProcessID: previous,
            process: status.process
        ))
    }

    private static func spawnAgentResult(
        arguments: [String: Value],
        context: CherryMCPToolContext?
    ) async throws -> CallTool.Result {
        let message = stringArgument("message", in: arguments)
        let request = CherryControlRequest.spawnProcess(.init(
            kind: "agent",
            name: try requiredString("name", in: arguments),
            title: stringArgument("title", in: arguments),
            workingDirectory: nil,
            text: message,
            rawBase64: nil,
            submit: message == nil ? nil : true,
            parentAgentID: parentAgentIDArgument(forKind: "agent", in: arguments, context: context),
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        ))

        let response = try cherryMCPClient(timeout: clientTimeout(for: "spawn_agent", arguments: arguments))
            .send(scopedRequest(request, arguments: arguments))
        if let error = response.error {
            return try toolError(error)
        }
        guard case .spawnProcess(let spawned)? = response.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for spawn_agent."))
        }

        let shouldBind = boolArgument("bind_session", in: arguments) ?? false
        let previousBoundProcessID = shouldBind ? context?.bindProcessID(spawned.process.id) : nil
        return try encodedResult(MCPSpawnAgentPayload(
            process: spawned.process,
            sentBytes: spawned.sentBytes,
            output: spawned.output,
            boundProcessID: shouldBind ? context?.boundProcessID : nil,
            previousBoundProcessID: previousBoundProcessID
        ))
    }

    private static func sendAgentMessageResult(
        arguments: [String: Value],
        context: CherryMCPToolContext?
    ) async throws -> CallTool.Result {
        let message = try requiredString("message", in: arguments)
        let selector = processSelector(in: arguments, context: context)
        let client = cherryMCPClient(timeout: clientTimeout(for: "send_agent_message", arguments: arguments))

        let statusResponse = try client.send(scopedRequest(.getProcessStatus(selector), arguments: arguments))
        if let error = statusResponse.error {
            return try toolError(error)
        }
        guard case .getProcessStatus(let status)? = statusResponse.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for send_agent_message status lookup."))
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
        let sendResponse = try client.send(scopedRequest(sendRequest, arguments: arguments))
        if let error = sendResponse.error {
            return try toolError(error)
        }
        guard case .sendProcessInput(let sent)? = sendResponse.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for send_agent_message input."))
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
            timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        ))
        let waitResponse = try client.send(scopedRequest(waitRequest, arguments: arguments))
        if let error = waitResponse.error {
            return try toolError(error)
        }
        guard case .waitForProcessIdle(let wait)? = waitResponse.result else {
            return try toolError(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for send_agent_message idle wait."))
        }

        return try encodedResult(MCPSendAgentMessagePayload(
            process: wait.process,
            sentBytes: sent.sentBytes,
            output: wait.output,
            wait: wait
        ))
    }

    @MainActor
    static func defaultParentAgentIDForHTTPSession() -> String? {
        guard let workspace = ProjectWindowRegistry.shared.activeWorkspace else {
            return nil
        }

        if ProjectWindowRegistry.shared.activeChromeState?.isShowingTerminalContent ?? true,
           let selectedSession = workspace.selectedSession,
           selectedSession.kind == .agent {
            return selectedSession.id.uuidString
        }

        return workspace.rootAgentSessions.last?.id.uuidString
    }

    private static func scopedRequest(_ request: CherryControlRequest, arguments: [String: Value] = [:]) -> CherryControlRequest {
        if case .scoped = request {
            return request
        }

        guard let projectRoot = explicitProjectRoot(in: arguments)
            ?? environmentProjectRoot()
            ?? inferredProjectRootFromWorkingDirectory()
        else {
            return request
        }

        return .scoped(.init(projectRoot: projectRoot, request: request))
    }

    private static func explicitProjectRoot(in arguments: [String: Value]) -> String? {
        trimmedProjectRoot(stringArgument("project_root", in: arguments))
    }

    private static func environmentProjectRoot() -> String? {
        trimmedProjectRoot(ProcessInfo.processInfo.environment[CherryControl.projectRootEnvironmentKey])
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

    private static func inferredProjectRootFromWorkingDirectory() -> String? {
        let workingDirectory = standardizedPath(FileManager.default.currentDirectoryPath)
        guard let response = try? cherryMCPClient().send(.listProjects),
              case .listProjects(let payload)? = response.result
        else {
            return nil
        }

        return payload.projects
            .map(\.root)
            .map(standardizedPath)
            .filter { contains(path: workingDirectory, inProjectRoot: $0) }
            .max { $0.count < $1.count }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func contains(path: String, inProjectRoot projectRoot: String) -> Bool {
        path == projectRoot || path.hasPrefix(projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/")
    }

    private static func statusResult() throws -> CallTool.Result {
        let socketURL = CherryControl.socketURL
        let socketExists = FileManager.default.fileExists(atPath: socketURL.path)

        do {
            let response = try cherryMCPClient().send(scopedRequest(.listTerminals))
            if let error = response.error {
                return try encodedResult(MCPStatusPayload(
                    socketPath: socketURL.path,
                    socketExists: socketExists,
                    cherryReachable: false,
                    terminalCount: nil,
                    selectedTerminalID: nil,
                    error: error
                ))
            }
            guard case .listTerminals(let terminals)? = response.result else {
                return try encodedResult(MCPStatusPayload(
                    socketPath: socketURL.path,
                    socketExists: socketExists,
                    cherryReachable: false,
                    terminalCount: nil,
                    selectedTerminalID: nil,
                    error: .init(code: "unexpected_status_response", message: "Cherry returned an unexpected status response.")
                ))
            }
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: true,
                terminalCount: terminals.terminals.count,
                selectedTerminalID: terminals.selectedTerminalID,
                error: nil
            ))
        } catch let error as CherryControlError {
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: false,
                terminalCount: nil,
                selectedTerminalID: nil,
                error: error
            ))
        } catch {
            return try encodedResult(MCPStatusPayload(
                socketPath: socketURL.path,
                socketExists: socketExists,
                cherryReachable: false,
                terminalCount: nil,
                selectedTerminalID: nil,
                error: .init(code: "status_failed", message: error.localizedDescription)
            ))
        }
    }

    private static func controlRequest(
        name: String,
        arguments: [String: Value],
        context: CherryMCPToolContext? = nil
    ) throws -> CherryControlRequest {
        switch name {
        case "list_projects":
            return .listProjects
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
            return .getProcessStatus(processSelector(in: arguments, context: context))
        case "get_process_output":
            return .getProcessOutput(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                startLine: intArgument("start_line", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "get_process_raw_output":
            return .getProcessRawOutput(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                maxBytes: intArgument("max_bytes", in: arguments)
            ))
        case "search_process_output":
            return .searchProcessOutput(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "wait_for_process_idle":
            return .waitForProcessIdle(waitForProcessIdleRequest(in: arguments, context: context))
        case "get_process_ports":
            return .getProcessPorts(.init(
                processID: processIDArgument(in: arguments, context: context),
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
                processID: processIDArgument(in: arguments, context: context),
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
                title: stringArgument("title", in: arguments),
                workingDirectory: stringArgument("working_directory", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                submit: boolArgument("submit", in: arguments),
                parentAgentID: parentAgentIDArgument(forKind: kind, in: arguments, context: context),
                waitMilliseconds: intArgument("wait_ms", in: arguments),
                lineLimit: intArgument("line_limit", in: arguments)
            ))
        case "start_process":
            return .startProcess(processLifecycle(in: arguments, context: context))
        case "stop_process":
            return .stopProcess(processLifecycle(in: arguments, context: context))
        case "restart_process":
            return .restartProcess(processLifecycle(in: arguments, context: context))
        case "close_process":
            return .closeProcess(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                agentClosePolicy: try agentClosePolicyArgument("agent_close_policy", in: arguments)
            ))
        case "rename_process":
            return .renameProcess(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                title: stringArgument("title", in: arguments)
            ))
        case "select_process":
            return .selectProcess(processSelector(in: arguments, context: context))
        case "send_process_input":
            return .sendProcessInput(.init(
                processID: processIDArgument(in: arguments, context: context),
                processName: stringArgument("process_name", in: arguments),
                text: stringArgument("text", in: arguments),
                rawBase64: stringArgument("raw_base64", in: arguments),
                submit: boolArgument("submit", in: arguments),
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
        case "list_notes":
            return .listNotes
        case "list_todos":
            return .listTodos
        case "create_note":
            return .createNote(.init(
                title: try requiredString("title", in: arguments),
                markdown: try requiredString("markdown", in: arguments),
                open: false
            ))
        case "get_note":
            return .getNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "update_note":
            return .updateNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                open: false
            ))
        case "append_note":
            return .appendNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                markdown: try requiredString("markdown", in: arguments)
            ))
        case "rename_note":
            return .renameNote(.init(
                noteID: try requiredString("note_id", in: arguments),
                title: try requiredString("title", in: arguments)
            ))
        case "search_notes":
            return .searchNotes(.init(
                query: try requiredString("query", in: arguments),
                caseSensitive: boolArgument("case_sensitive", in: arguments),
                maxMatches: intArgument("max_matches", in: arguments)
            ))
        case "delete_note":
            return .deleteNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "select_note":
            return .selectNote(.init(noteID: try requiredString("note_id", in: arguments)))
        case "create_todo":
            return .createTodo(.init(
                title: try requiredString("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments) ?? "",
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments),
                open: false
            ))
        case "get_todo":
            return .getTodo(.init(todoID: try requiredString("todo_id", in: arguments)))
        case "update_todo":
            return .updateTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                title: stringArgument("title", in: arguments),
                markdown: stringArgument("markdown", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                tags: try stringArrayArgument("tags", in: arguments),
                open: false
            ))
        case "move_todo":
            return .moveTodo(.init(
                todoID: try requiredString("todo_id", in: arguments),
                status: try todoStatusArgument("status", in: arguments),
                afterTodoID: stringArgument("after_todo_id", in: arguments),
                open: false
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
                terminalID: stringArgument("process_id", in: arguments),
                open: false
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
            throw CherryControlError(code: "unknown_tool", message: "Unknown Cherry MCP tool: \(name)")
        }
    }

    private static func toolResult(_ result: CherryControlResult) throws -> CallTool.Result {
        switch result {
        case .listProjects(let payload):
            return try encodedResult(payload)
        case .openProject(let payload):
            return try encodedResult(payload)
        case .getProjectStatus(let payload):
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
        case .listNotes(let payload):
            return try encodedResult(payload)
        case .listTodos(let payload):
            return try encodedResult(payload)
        case .createTerminal(let payload):
            return try encodedResult(payload)
        case .runAgent(let payload):
            return try encodedResult(payload)
        case .createNote(let payload):
            return try encodedResult(payload)
        case .getNote(let payload):
            return try encodedResult(payload)
        case .updateNote(let payload):
            return try encodedResult(payload)
        case .appendNote(let payload):
            return try encodedResult(payload)
        case .renameNote(let payload):
            return try encodedResult(payload)
        case .searchNotes(let payload):
            return try encodedResult(payload)
        case .deleteNote(let payload):
            return try encodedResult(payload)
        case .selectNote(let payload):
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
        case .renameTerminal(let payload):
            return try encodedResult(payload)
        case .selectTerminal(let payload):
            return try encodedResult(payload)
        case .sendInput(let payload):
            return try encodedResult(payload)
        case .getTerminalOutput(let payload):
            return try encodedResult(payload)
        case .getTerminalRawOutput(let payload):
            return try encodedResult(payload)
        case .searchOutput(let payload):
            return try encodedResult(payload)
        case .clearOutput(let payload):
            return try encodedResult(payload)
        case .restartTerminal(let payload):
            return try encodedResult(payload)
        case .closeTerminal(let payload):
            return try encodedResult(payload)
        }
    }

    private static func encodedResult<Payload: Codable>(_ payload: Payload) throws -> CallTool.Result {
        let json = try jsonString(payload)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try Value(payload)),
            isError: false
        )
    }

    private static func toolError(_ error: CherryControlError) throws -> CallTool.Result {
        let payload = ErrorPayload(error: error)
        let json = try jsonString(payload)
        return CallTool.Result(
            content: [.text(text: json, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try Value(payload)),
            isError: true
        )
    }

    private static func jsonString<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func requiredString(_ key: String, in arguments: [String: Value]) throws -> String {
        guard let value = stringArgument(key, in: arguments), !value.isEmpty else {
            throw CherryControlError(code: "missing_argument", message: "Missing required string argument: \(key)")
        }
        return value
    }

    private static func stringArgument(_ key: String, in arguments: [String: Value]) -> String? {
        arguments[key]?.stringValue
    }

    private static func intArgument(_ key: String, in arguments: [String: Value]) -> Int? {
        arguments[key]?.intValue
    }

    private static func boolArgument(_ key: String, in arguments: [String: Value]) -> Bool? {
        arguments[key]?.boolValue
    }

    private static func parentAgentIDArgument(
        forKind kind: String,
        in arguments: [String: Value],
        context: CherryMCPToolContext?
    ) -> String? {
        let explicitParentAgentID = stringArgument("parent_agent_id", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "agent" else {
            return explicitParentAgentID
        }
        if boolArgument("top_level", in: arguments) == true {
            return CherryControl.topLevelAgentParentID
        }
        if let context {
            return explicitParentAgentID ?? context.defaultParentAgentID ?? CherryControl.selectedAgentParentID
        }
        if let environmentAgentID = environmentAgentID() {
            return explicitParentAgentID ?? environmentAgentID
        }
        return explicitParentAgentID ?? CherryControl.selectedAgentParentID
    }

    private static func environmentAgentID() -> String? {
        guard let agentID = ProcessInfo.processInfo.environment[CherryControl.agentIDEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !agentID.isEmpty,
            UUID(uuidString: agentID) != nil
        else {
            return nil
        }
        return agentID
    }

    private static func stringArrayArgument(_ key: String, in arguments: [String: Value]) throws -> [String]? {
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

    private static func todoStatusArgument(_ key: String, in arguments: [String: Value]) throws -> TodoStatus? {
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

    private static func agentClosePolicyArgument(_ key: String, in arguments: [String: Value]) throws -> AgentClosePolicy? {
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

    private static func explicitProcessSelector(in arguments: [String: Value]) -> ProcessSelectorRequest {
        ProcessSelectorRequest(
            processID: trimmedArgument("process_id", in: arguments),
            processName: stringArgument("process_name", in: arguments)
        )
    }

    private static func processSelector(
        in arguments: [String: Value],
        context: CherryMCPToolContext?
    ) -> ProcessSelectorRequest {
        let processName = stringArgument("process_name", in: arguments)
        return ProcessSelectorRequest(
            processID: processIDArgument(in: arguments, context: context),
            processName: processName
        )
    }

    private static func processIDArgument(
        in arguments: [String: Value],
        context: CherryMCPToolContext?
    ) -> String? {
        if let explicit = trimmedArgument("process_id", in: arguments) {
            return explicit
        }

        if let processName = trimmedArgument("process_name", in: arguments), !processName.isEmpty {
            return nil
        }

        return context?.boundProcessID
    }

    private static func trimmedArgument(_ key: String, in arguments: [String: Value]) -> String? {
        stringArgument(key, in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func processLifecycle(
        in arguments: [String: Value],
        context: CherryMCPToolContext?
    ) -> ProcessLifecycleRequest {
        ProcessLifecycleRequest(
            processID: processIDArgument(in: arguments, context: context),
            processName: stringArgument("process_name", in: arguments),
            kind: stringArgument("kind", in: arguments),
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func processBulkCommand(in arguments: [String: Value]) -> ProcessBulkCommandRequest {
        ProcessBulkCommandRequest(
            waitMilliseconds: intArgument("wait_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func waitForProcessIdleRequest(
        in arguments: [String: Value],
        context: CherryMCPToolContext?
    ) -> WaitForProcessIdleRequest {
        WaitForProcessIdleRequest(
            processID: processIDArgument(in: arguments, context: context),
            processName: stringArgument("process_name", in: arguments),
            sinceOutputVersion: intArgument("since_output_version", in: arguments),
            requireNewOutput: boolArgument("require_new_output", in: arguments),
            quietMilliseconds: intArgument("quiet_ms", in: arguments),
            timeoutMilliseconds: intArgument("timeout_ms", in: arguments),
            lineLimit: intArgument("line_limit", in: arguments)
        )
    }

    private static func clientTimeout(for toolName: String, arguments: [String: Value]) -> TimeInterval? {
        switch toolName {
        case "spawn_agent":
            let waitMilliseconds = min(max(intArgument("wait_ms", in: arguments) ?? 0, 0), 5_000)
            return TimeInterval(waitMilliseconds) / 1_000 + 12
        case "wait_for_process_idle", "send_agent_message":
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? 60_000, 1), 300_000)
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        case "wait_for_bound_port":
            let timeoutMilliseconds = min(max(intArgument("timeout_ms", in: arguments) ?? 10_000, 1), 60_000)
            return TimeInterval(timeoutMilliseconds) / 1_000 + 5
        default:
            return nil
        }
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Value], required: [String] = []) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(Value.string))
            ])
        )
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")])
        ])
    }

    private static func processSelectorProperties(_ extra: [String: Value] = [:]) -> [String: Value] {
        var properties: [String: Value] = [
            "process_id": string("Stable Cherry process UUID. Preferred when known. Defaults to the bound MCP session process when process_name is also omitted."),
            "process_name": string("Process name/title when process_id is not known.")
        ]
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }

    private static func idleWaitProperties() -> [String: Value] {
        processSelectorProperties([
            "since_output_version": integer("Optional output version baseline. Defaults to the process baseline recorded before the last input, then current output version."),
            "require_new_output": boolean("Whether at least one new output version is required before idle can pass. Defaults to true."),
            "quiet_ms": integer("Required quiet period in milliseconds. Defaults to 1000."),
            "timeout_ms": integer("Maximum wait in milliseconds. Defaults to 60000, max 300000."),
            "line_limit": integer("Rendered output line limit in the response. Max 2000.")
        ])
    }

    private static func projectScopedProperties(_ extra: [String: Value] = [:]) -> [String: Value] {
        var properties: [String: Value] = [
            "project_root": string("Optional Cherry project root. Defaults to CHERRY_PROJECT_ROOT or the MCP helper's current working directory when it is inside an open Cherry project.")
        ]
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }

    private static func lifecycleProperties() -> [String: Value] {
        [
            "kind": string("Optional process kind for starting by name: agent or command."),
            "wait_ms": integer("Optional wait before returning rendered output. Max 5000."),
            "line_limit": integer("Rendered output line limit when wait_ms is set. Max 2000.")
        ]
    }

    private static func bulkCommandProperties() -> [String: Value] {
        [
            "wait_ms": integer("Optional wait before returning process list. Max 5000."),
            "line_limit": integer("Reserved output line limit for lifecycle symmetry.")
        ]
    }
}

private struct ErrorPayload: Codable {
    let error: CherryControlError
}

private struct MCPWhoamiPayload: Codable {
    let mcpSessionID: String?
    let activeProjectRoot: String?
    let effectiveProjectRoot: String?
    let boundProcessID: String?
    let defaultParentAgentID: String?
    let selectedProcessID: String?
    let selectedProcessName: String?
}

private struct MCPBindSessionProcessPayload: Codable {
    let mcpSessionID: String?
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
}

private struct MCPSendAgentMessagePayload: Codable {
    let process: ProcessSummary
    let sentBytes: Int
    let output: TerminalOutputResult?
    let wait: WaitForProcessIdleResult?
}

private struct MCPStatusPayload: Codable {
    let socketPath: String
    let socketExists: Bool
    let cherryReachable: Bool
    let terminalCount: Int?
    let selectedTerminalID: String?
    let error: CherryControlError?
}
