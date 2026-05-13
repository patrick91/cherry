import CherryControl
import Darwin
import Foundation

final class CherryControlServer: @unchecked Sendable {
    private weak var workspace: TerminalWorkspace?
    private weak var noteStore: ProjectNoteStore?
    private weak var todoStore: ProjectTodoStore?
    private weak var chromeState: ProjectWindowChromeState?
    private let workspaceProvider: @MainActor () -> TerminalWorkspace?
    private let noteStoreProvider: @MainActor () -> ProjectNoteStore?
    private let todoStoreProvider: @MainActor () -> ProjectTodoStore?
    private let chromeStateProvider: @MainActor () -> ProjectWindowChromeState?
    private let workspaceForProjectRootProvider: @MainActor (String) -> TerminalWorkspace?
    private let noteStoreForProjectRootProvider: @MainActor (String) -> ProjectNoteStore?
    private let todoStoreForProjectRootProvider: @MainActor (String) -> ProjectTodoStore?
    private let chromeStateForProjectRootProvider: @MainActor (String) -> ProjectWindowChromeState?
    private let openProjectRootsProvider: @MainActor () -> [String]
    private let agentSettings: AgentSettings
    private let serviceDetector: any ServiceDetecting
    private let socketURL: URL
    private let queue = DispatchQueue(label: "Cherry.ControlServer", qos: .userInitiated)
    private var listenFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    @MainActor
    init(
        workspace: TerminalWorkspace,
        noteStore: ProjectNoteStore? = nil,
        todoStore: ProjectTodoStore? = nil,
        chromeState: ProjectWindowChromeState? = nil,
        socketURL: URL = CherryControl.socketURL,
        agentSettings: AgentSettings = .shared,
        serviceDetector: any ServiceDetecting = MacOSServiceDetector()
    ) {
        self.workspace = workspace
        self.noteStore = noteStore
        self.todoStore = todoStore
        self.chromeState = chromeState
        self.workspaceProvider = { workspace }
        self.noteStoreProvider = { noteStore }
        self.todoStoreProvider = { todoStore }
        self.chromeStateProvider = { chromeState }
        self.workspaceForProjectRootProvider = { projectRoot in
            workspace.projectRoot == projectRoot ? workspace : nil
        }
        self.noteStoreForProjectRootProvider = { projectRoot in
            noteStore?.projectRoot == projectRoot ? noteStore : nil
        }
        self.todoStoreForProjectRootProvider = { projectRoot in
            todoStore?.projectRoot == projectRoot ? todoStore : nil
        }
        self.chromeStateForProjectRootProvider = { projectRoot in
            workspace.projectRoot == projectRoot ? chromeState : nil
        }
        self.openProjectRootsProvider = {
            workspace.projectRoot.map { [$0] } ?? []
        }
        self.agentSettings = agentSettings
        self.serviceDetector = serviceDetector
        self.socketURL = socketURL
    }

    @MainActor
    init(
        workspaceProvider: @escaping @MainActor () -> TerminalWorkspace?,
        noteStoreProvider: @escaping @MainActor () -> ProjectNoteStore? = {
            ProjectWindowRegistry.shared.activeNoteStore
        },
        todoStoreProvider: @escaping @MainActor () -> ProjectTodoStore? = {
            ProjectWindowRegistry.shared.activeTodoStore
        },
        chromeStateProvider: @escaping @MainActor () -> ProjectWindowChromeState? = {
            ProjectWindowRegistry.shared.activeChromeState
        },
        workspaceForProjectRootProvider: @escaping @MainActor (String) -> TerminalWorkspace? = {
            ProjectWindowRegistry.shared.workspace(for: $0)
        },
        noteStoreForProjectRootProvider: @escaping @MainActor (String) -> ProjectNoteStore? = {
            ProjectWindowRegistry.shared.noteStore(for: $0)
        },
        todoStoreForProjectRootProvider: @escaping @MainActor (String) -> ProjectTodoStore? = {
            ProjectWindowRegistry.shared.todoStore(for: $0)
        },
        chromeStateForProjectRootProvider: @escaping @MainActor (String) -> ProjectWindowChromeState? = {
            ProjectWindowRegistry.shared.chromeState(for: $0)
        },
        openProjectRootsProvider: @escaping @MainActor () -> [String] = {
            ProjectWindowRegistry.shared.projectRoots
        },
        socketURL: URL = CherryControl.socketURL,
        agentSettings: AgentSettings = .shared,
        serviceDetector: any ServiceDetecting = MacOSServiceDetector()
    ) {
        self.workspace = nil
        self.noteStore = nil
        self.todoStore = nil
        self.chromeState = nil
        self.workspaceProvider = workspaceProvider
        self.noteStoreProvider = noteStoreProvider
        self.todoStoreProvider = todoStoreProvider
        self.chromeStateProvider = chromeStateProvider
        self.workspaceForProjectRootProvider = workspaceForProjectRootProvider
        self.noteStoreForProjectRootProvider = noteStoreForProjectRootProvider
        self.todoStoreForProjectRootProvider = todoStoreForProjectRootProvider
        self.chromeStateForProjectRootProvider = chromeStateForProjectRootProvider
        self.openProjectRootsProvider = openProjectRootsProvider
        self.agentSettings = agentSettings
        self.serviceDetector = serviceDetector
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    func start() {
        guard acceptSource == nil else { return }

        do {
            try prepareSocketDirectory()
            try bindAndListen()
        } catch {
            fputs("[control] failed to start: \(error.localizedDescription)\n", stderr)
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFileDescriptor >= 0 {
            close(listenFileDescriptor)
            listenFileDescriptor = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func prepareSocketDirectory() throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        chmod(directoryURL.path, S_IRWXU)
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func bindAndListen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Self.setCloseOnExec(fileDescriptor: fd)

        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            close(fd)
            throw CherryControlError(code: "socket_path_too_long", message: "Control socket path is too long.")
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { pathPointer in
                let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                strncpy(rawPointer, pathPointer, maximumPathLength)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, length)
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        chmod(path, S_IRUSR | S_IWUSR)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        listenFileDescriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    private nonisolated func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFileDescriptor, nil, nil)
            if clientFD >= 0 {
                Self.setCloseOnExec(fileDescriptor: clientFD)
                Self.configureBlocking(fileDescriptor: clientFD)
                handleConnection(fileDescriptor: clientFD)
                continue
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private nonisolated func handleConnection(fileDescriptor clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                close(clientFD)
                return
            }

            let requestData: Data
            do {
                requestData = try Self.readRequest(fileDescriptor: clientFD)
            } catch {
                Self.writeResponse(.init(error: Self.controlError(from: error)), to: clientFD)
                close(clientFD)
                return
            }

            Task { @MainActor [weak self] in
                let response: CherryControlResponse
                if let self {
                    response = await self.handleRequestData(requestData)
                } else {
                    response = .init(error: .init(code: "server_unavailable", message: "Cherry control server is unavailable."))
                }

                Self.writeResponse(response, to: clientFD)
                close(clientFD)
            }
        }
    }

    @MainActor
    private func handleRequestData(_ data: Data) async -> CherryControlResponse {
        do {
            let request = try JSONDecoder().decode(CherryControlRequest.self, from: data)
            return try await handle(request)
        } catch let error as CherryControlError {
            return .init(error: error)
        } catch {
            return .init(error: .init(code: "invalid_request", message: error.localizedDescription))
        }
    }

    @MainActor
    private func handle(_ request: CherryControlRequest) async throws -> CherryControlResponse {
        if case .scoped(let scopedRequest) = request {
            let workspace = try scopedWorkspace(projectRoot: scopedRequest.projectRoot)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        }

        guard let workspace = workspace ?? workspaceProvider() else {
            throw CherryControlError(code: "workspace_unavailable", message: "Cherry workspace is unavailable.")
        }

        return try await handleUnscoped(request, workspace: workspace, isProjectScoped: false)
    }

    @MainActor
    private func handleUnscoped(
        _ request: CherryControlRequest,
        workspace: TerminalWorkspace,
        isProjectScoped: Bool
    ) async throws -> CherryControlResponse {
        if !isProjectScoped {
            try rejectAmbiguousUnscopedProjectMutation(request)
        }

        switch request {
        case .scoped(let scopedRequest):
            let workspace = try scopedWorkspace(projectRoot: scopedRequest.projectRoot)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        case .listProjects:
            return .init(result: .listProjects(listProjects(workspace: workspace)))
        case .getProjectStatus:
            return .init(result: .getProjectStatus(projectStatus(workspace: workspace)))
        case .resolveLink(let request):
            return .init(result: .resolveLink(try resolveDeepLink(request, fallbackWorkspace: workspace)))
        case .listProcesses(let request):
            return .init(result: .listProcesses(try listProcesses(workspace: workspace, kind: request.kind)))
        case .getProcessStatus(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .getProcessStatus(.init(process: processInfo(for: session, workspace: workspace))))
        case .getProcessOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .getProcessOutput(terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)))
        case .getProcessRawOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .getProcessRawOutput(rawOutput(for: session, maxBytes: request.maxBytes)))
        case .searchProcessOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .searchProcessOutput(searchOutput(
                for: session,
                query: request.query,
                caseSensitive: request.caseSensitive,
                maxMatches: request.maxMatches
            )))
        case .getProcessPorts(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .getProcessPorts(try servicesResult(
                workspace: workspace,
                sessions: [session],
                includeUnattributed: request.includeUnattributed ?? false
            )))
        case .servicesList(let request):
            let kind = try processKind(from: request.kind)
            let sessions = workspace.sessions.filter { session in
                guard let kind else { return true }
                return session.kind == kind
            }
            return .init(result: .servicesList(try servicesResult(
                workspace: workspace,
                sessions: sessions,
                includeUnattributed: request.includeUnattributed ?? false
            )))
        case .waitForBoundPort(let request):
            let service = try await waitForBoundPort(request, workspace: workspace)
            return .init(result: .waitForBoundPort(.init(service: service)))
        case .spawnProcess(let request):
            let (session, sentBytes) = try spawnProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .spawnProcess(.init(
                process: processInfo(for: session, workspace: workspace),
                sentBytes: sentBytes,
                output: output
            )))
        case .startProcess(let request):
            let session = try startProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .startProcess(.init(process: processInfo(for: session, workspace: workspace), output: output)))
        case .stopProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            stopProcess(session)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .stopProcess(.init(process: processInfo(for: session, workspace: workspace), output: output)))
        case .restartProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            restartProcess(session)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .restartProcess(.init(process: processInfo(for: session, workspace: workspace), output: output)))
        case .closeProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            guard workspace.sessions.count > 1 else {
                throw CherryControlError(code: "last_process", message: "Cherry cannot close the last remaining process.")
            }
            workspace.close(session)
            return .init(result: .closeProcess(.init(processID: session.id.uuidString, closed: true)))
        case .renameProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            session.rename(to: request.title)
            return .init(result: .renameProcess(.init(process: processInfo(for: session, workspace: workspace))))
        case .sendProcessInput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            let payload = try inputPayload(text: request.text, rawBase64: request.rawBase64)
            session.send(data: payload)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .sendProcessInput(.init(processID: session.id.uuidString, sentBytes: payload.count, output: output)))
        case .startAllCommands(let request):
            _ = try startAllCommands(workspace: workspace)
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .startAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .stopAllCommands(let request):
            workspace.commandSessions.forEach { $0.stopManagedCommand() }
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .stopAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .restartAllCommands(let request):
            try restartAllCommands(workspace: workspace)
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .restartAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .listTerminals:
            return .init(result: .listTerminals(listTerminals(workspace: workspace)))
        case .listAgents:
            return .init(result: .listAgents(listAgents(workspace: workspace)))
        case .listNotes:
            let noteStore = try activeNoteStore(for: workspace)
            return .init(result: .listNotes(listNotes(noteStore: noteStore)))
        case .listTodos:
            let todoStore = try activeTodoStore(for: workspace)
            return .init(result: .listTodos(listTodos(todoStore: todoStore)))
        case .createTerminal(let request):
            let session = workspace.addSession(
                title: request.title,
                workingDirectory: request.workingDirectory,
                command: request.command,
                select: false
            )
            return .init(result: .createTerminal(summary(for: session, workspace: workspace)))
        case .runAgent(let request):
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let agent = try findAgent(named: request.agentName)
            guard agent.isLaunchable else {
                throw CherryControlError(code: "agent_not_launchable", message: "Agent '\(agent.name)' is not launchable.")
            }
            let session = workspace.addAgentSession(
                agent: agent.definition,
                projectRoot: projectRoot,
                title: request.title,
                select: request.select ?? false
            )
            if request.select ?? false {
                chromeState(for: workspace)?.selectTerminal()
            }
            let payload = try runAgentInputPayload(
                text: request.text,
                rawBase64: request.rawBase64,
                submit: request.submit
            )
            if let payload, !payload.isEmpty {
                session.send(data: payload)
            }
            let waitMilliseconds = min(max(request.waitMilliseconds ?? 0, 0), 5_000)
            let lineLimit = min(max(request.lineLimit ?? 200, 1), 2_000)
            if waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
            }
            let output = waitMilliseconds > 0 ? terminalOutput(for: session, startLine: nil, lineLimit: lineLimit) : nil
            return .init(result: .runAgent(.init(
                terminalID: session.id.uuidString,
                link: link(for: session, workspace: workspace),
                title: session.title,
                state: session.state.label,
                kind: session.kind.rawValue,
                agentName: session.agentName,
                summary: session.summary,
                projectRoot: projectRoot,
                sentBytes: payload?.count ?? 0,
                output: output
            )))
        case .createNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let note = try noteStore.create(title: request.title, markdown: request.markdown)
            if request.open ?? false {
                select(note: note, workspace: workspace)
            }
            let selected = chromeState(for: workspace)?.selectedNoteID == note.id
            return .init(result: .createNote(.init(note: note, link: link(for: note), selected: selected)))
        case .getNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let note = try noteStore.note(id: try noteID(from: request.noteID))
            let selected = chromeState(for: workspace)?.selectedNoteID == note.id
            return .init(result: .getNote(.init(note: note, link: link(for: note), selected: selected)))
        case .updateNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let note = try noteStore.update(
                id: try noteID(from: request.noteID),
                title: request.title,
                markdown: request.markdown
            )
            if request.open ?? false {
                select(note: note, workspace: workspace)
            }
            return .init(result: .updateNote(.init(
                note: note,
                link: link(for: note),
                selected: chromeState(for: workspace)?.selectedNoteID == note.id
            )))
        case .appendNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let existing = try noteStore.note(id: try noteID(from: request.noteID))
            let separator = existing.markdown.isEmpty || request.markdown.isEmpty ? "" : "\n"
            let note = try noteStore.update(id: existing.id, title: nil, markdown: existing.markdown + separator + request.markdown)
            return .init(result: .appendNote(.init(
                note: note,
                link: link(for: note),
                selected: chromeState(for: workspace)?.selectedNoteID == note.id
            )))
        case .renameNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let note = try noteStore.update(id: try noteID(from: request.noteID), title: request.title, markdown: nil)
            return .init(result: .renameNote(.init(
                note: note,
                link: link(for: note),
                selected: chromeState(for: workspace)?.selectedNoteID == note.id
            )))
        case .searchNotes(let request):
            let noteStore = try activeNoteStore(for: workspace)
            return .init(result: .searchNotes(searchNotes(noteStore: noteStore, request: request)))
        case .deleteNote(let request):
            let id = try noteID(from: request.noteID)
            let noteStore = try activeNoteStore(for: workspace)
            try noteStore.delete(id: id)
            if chromeState(for: workspace)?.selectedNoteID == id {
                chromeState(for: workspace)?.selectNote(id: nil)
            }
            return .init(result: .deleteNote(.init(noteID: id.uuidString, deleted: true)))
        case .selectNote(let request):
            let noteStore = try activeNoteStore(for: workspace)
            let note = try noteStore.note(id: try noteID(from: request.noteID))
            select(note: note, workspace: workspace)
            return .init(result: .selectNote(.init(noteID: note.id.uuidString, selected: true)))
        case .createTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.create(
                title: request.title,
                markdown: request.markdown,
                status: request.status ?? .backlog,
                tags: request.tags ?? []
            )
            if request.open ?? false {
                select(todo: todo, workspace: workspace)
            }
            return .init(result: .createTodo(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .getTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.todo(id: try todoID(from: request.todoID))
            return .init(result: .getTodo(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .updateTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.update(
                id: try todoID(from: request.todoID),
                title: request.title,
                markdown: request.markdown,
                status: request.status,
                tags: request.tags
            )
            if request.open ?? false {
                select(todo: todo, workspace: workspace)
            }
            return .init(result: .updateTodo(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .moveTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let afterTodoID = try request.afterTodoID.map { try todoID(from: $0) }
            let todo = try todoStore.move(
                id: try todoID(from: request.todoID),
                status: request.status,
                afterTodoID: afterTodoID
            )
            if request.open ?? false {
                select(todo: todo, workspace: workspace)
            }
            return .init(result: .moveTodo(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .deleteTodo(let request):
            let id = try todoID(from: request.todoID)
            let todoStore = try activeTodoStore(for: workspace)
            try todoStore.delete(id: id)
            if chromeState(for: workspace)?.selectedTodoID == id {
                chromeState(for: workspace)?.selectTodo(id: nil)
            }
            return .init(result: .deleteTodo(.init(todoID: id.uuidString, deleted: true)))
        case .selectTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.todo(id: try todoID(from: request.todoID))
            select(todo: todo, workspace: workspace)
            return .init(result: .selectTodo(.init(todoID: todo.id.uuidString, selected: true)))
        case .addTodoComment(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let author = try todoCommentAuthor(from: request, workspace: workspace)
            let todo = try todoStore.addComment(
                id: try todoID(from: request.todoID),
                markdown: request.markdown,
                authorLabel: author.label,
                authorTerminalID: author.terminalID,
                authorAgentName: author.agentName
            )
            if request.open ?? false {
                select(todo: todo, workspace: workspace)
            }
            return .init(result: .addTodoComment(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .listTodoComments(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.todo(id: try todoID(from: request.todoID))
            return .init(result: .listTodoComments(.init(todoID: todo.id.uuidString, comments: todo.comments)))
        case .updateTodoComment(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.updateComment(
                todoID: try todoID(from: request.todoID),
                commentID: try commentID(from: request.commentID),
                markdown: request.markdown
            )
            return .init(result: .updateTodoComment(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .deleteTodoComment(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.deleteComment(
                todoID: try todoID(from: request.todoID),
                commentID: try commentID(from: request.commentID)
            )
            return .init(result: .deleteTodoComment(.init(
                todo: todo,
                link: link(for: todo),
                selected: chromeState(for: workspace)?.selectedTodoID == todo.id
            )))
        case .renameTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            session.rename(to: request.title)
            return .init(result: .renameTerminal(summary(for: session, workspace: workspace)))
        case .selectTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            workspace.select(session)
            chromeState(for: workspace)?.selectTerminal()
            return .init(result: .selectTerminal(.init(terminalID: session.id.uuidString, selected: true)))
        case .sendInput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            let payload = try inputPayload(from: request)
            session.send(data: payload)
            let waitMilliseconds = min(max(request.waitMilliseconds ?? 0, 0), 5_000)
            let lineLimit = min(max(request.lineLimit ?? 200, 1), 2_000)
            if waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
            }
            let output = waitMilliseconds > 0 ? terminalOutput(for: session, startLine: nil, lineLimit: lineLimit) : nil
            return .init(result: .sendInput(.init(terminalID: session.id.uuidString, sentBytes: payload.count, output: output)))
        case .getTerminalOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .getTerminalOutput(terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)))
        case .getTerminalRawOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .getTerminalRawOutput(rawOutput(for: session, maxBytes: request.maxBytes)))
        case .searchOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            return .init(result: .searchOutput(searchOutput(for: session, request: request)))
        case .clearOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            session.clearScrollback()
            return .init(result: .clearOutput(.init(terminalID: session.id.uuidString, cleared: true)))
        case .restartTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            session.restart()
            return .init(result: .restartTerminal(summary(for: session, workspace: workspace)))
        case .closeTerminal(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            guard workspace.sessions.count > 1 else {
                throw CherryControlError(code: "last_terminal", message: "Cherry cannot close the last remaining terminal.")
            }
            workspace.close(session)
            return .init(result: .closeTerminal(.init(terminalID: session.id.uuidString, closed: true)))
        }
    }

    @MainActor
    private func resolveDeepLink(
        _ request: ResolveDeepLinkRequest,
        fallbackWorkspace workspace: TerminalWorkspace
    ) throws -> ResolveDeepLinkResult {
        let deepLink = try CherryDeepLink.parse(request.link)
        let projectRoot = projectRoot(forProjectKey: deepLink.projectKey, fallbackWorkspace: workspace)
        let normalizedLink = deepLink.absoluteString

        guard let projectRoot else {
            return ResolveDeepLinkResult(
                link: normalizedLink,
                projectKey: deepLink.projectKey,
                kind: deepLink.kind,
                targetID: deepLink.targetID,
                found: false,
                projectRoot: nil
            )
        }

        switch deepLink.kind {
        case .note:
            try requireNotesEnabled(projectRoot: projectRoot)
            let noteID = try noteID(from: deepLink.targetID)
            guard let note = try? noteStore(forProjectRoot: projectRoot, fallbackWorkspace: workspace).note(id: noteID) else {
                return missingDeepLinkResult(deepLink, projectRoot: projectRoot, link: normalizedLink)
            }
            return ResolveDeepLinkResult(
                link: normalizedLink,
                projectKey: deepLink.projectKey,
                kind: deepLink.kind,
                targetID: deepLink.targetID,
                found: true,
                projectRoot: projectRoot,
                note: note,
                noteLink: link(for: note)
            )
        case .todo:
            try requireTodosEnabled(projectRoot: projectRoot)
            let todoID = try todoID(from: deepLink.targetID)
            guard let todo = try? todoStore(forProjectRoot: projectRoot, fallbackWorkspace: workspace).todo(id: todoID) else {
                return missingDeepLinkResult(deepLink, projectRoot: projectRoot, link: normalizedLink)
            }
            return ResolveDeepLinkResult(
                link: normalizedLink,
                projectKey: deepLink.projectKey,
                kind: deepLink.kind,
                targetID: deepLink.targetID,
                found: true,
                projectRoot: projectRoot,
                todo: todo,
                todoLink: link(for: todo)
            )
        case .terminal:
            guard let terminalID = UUID(uuidString: deepLink.targetID),
                  let linkedWorkspace = workspaceForProjectRoot(projectRoot, fallbackWorkspace: workspace),
                  let session = linkedWorkspace.session(id: terminalID.uuidString)
            else {
                return missingDeepLinkResult(deepLink, projectRoot: projectRoot, link: normalizedLink)
            }
            let output = request.includeOutput == true
                ? terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)
                : nil
            return ResolveDeepLinkResult(
                link: normalizedLink,
                projectKey: deepLink.projectKey,
                kind: deepLink.kind,
                targetID: deepLink.targetID,
                found: true,
                projectRoot: projectRoot,
                process: processInfo(for: session, workspace: linkedWorkspace),
                output: output
            )
        }
    }

    private func missingDeepLinkResult(
        _ deepLink: CherryDeepLink,
        projectRoot: String?,
        link: String
    ) -> ResolveDeepLinkResult {
        ResolveDeepLinkResult(
            link: link,
            projectKey: deepLink.projectKey,
            kind: deepLink.kind,
            targetID: deepLink.targetID,
            found: false,
            projectRoot: projectRoot
        )
    }

    @MainActor
    private func projectRoot(forProjectKey projectKey: String, fallbackWorkspace workspace: TerminalWorkspace) -> String? {
        if let projectRoot = workspace.projectRoot,
           CherryDeepLink.projectKey(forProjectRoot: projectRoot) == projectKey {
            return projectRoot
        }
        if let projectRoot = ProjectWindowRegistry.shared.projectRoot(forProjectKey: projectKey) {
            return projectRoot
        }
        return agentSettings.projects
            .map(\.root)
            .first { CherryDeepLink.projectKey(forProjectRoot: $0) == projectKey }
    }

    @MainActor
    private func workspaceForProjectRoot(_ projectRoot: String, fallbackWorkspace workspace: TerminalWorkspace) -> TerminalWorkspace? {
        if workspace.projectRoot == projectRoot {
            return workspace
        }
        return ProjectWindowRegistry.shared.workspace(for: projectRoot)
    }

    @MainActor
    private func noteStore(forProjectRoot projectRoot: String, fallbackWorkspace workspace: TerminalWorkspace) -> ProjectNoteStore {
        if workspace.projectRoot == projectRoot,
           let store = noteStore ?? noteStoreProvider(),
           store.projectRoot == projectRoot {
            return store
        }
        if let store = ProjectWindowRegistry.shared.noteStore(for: projectRoot) {
            return store
        }
        return ProjectNoteStore(projectRoot: projectRoot)
    }

    @MainActor
    private func todoStore(forProjectRoot projectRoot: String, fallbackWorkspace workspace: TerminalWorkspace) -> ProjectTodoStore {
        if workspace.projectRoot == projectRoot,
           let store = todoStore ?? todoStoreProvider(),
           store.projectRoot == projectRoot {
            return store
        }
        if let store = ProjectWindowRegistry.shared.todoStore(for: projectRoot) {
            return store
        }
        return ProjectTodoStore(projectRoot: projectRoot)
    }

    @MainActor
    private func listTerminals(workspace: TerminalWorkspace) -> ListTerminalsResult {
        ListTerminalsResult(
            terminals: workspace.sessions.map { session in
                TerminalInfo(
                    id: session.id.uuidString,
                    title: session.title,
                    state: session.state.label,
                    selected: workspace.selectedSessionID == session.id,
                    workingDirectory: session.workingDirectory,
                    lineCount: session.lineCount,
                    link: link(for: session, workspace: workspace),
                    kind: session.kind.rawValue,
                    agentName: session.agentName,
                    summary: session.summary
                )
            },
            selectedTerminalID: workspace.selectedSessionID?.uuidString
        )
    }

    @MainActor
    private func listAgents(workspace: TerminalWorkspace) -> ListAgentsResult {
        ListAgentsResult(
            activeProjectRoot: workspace.projectRoot,
            agents: agentSettings.resolvedAgents.map { agent in
                let normalizedName = agent.definition.normalizedName
                let activeSessionCount = workspace.agentSessions.filter {
                    $0.agentName.map { AgentToolDefinition.normalizedName($0) } == normalizedName
                }.count

                return AgentInfo(
                    id: agent.id,
                    name: agent.name,
                    command: agent.definition.command,
                    arguments: agent.definition.arguments,
                    commandLine: agent.commandLine,
                    enabled: agent.enabled,
                    launchable: agent.isLaunchable,
                    activeSessionCount: activeSessionCount
                )
            }
        )
    }

    @MainActor
    private func listProjects(workspace: TerminalWorkspace) -> ListProjectsResult {
        let activeRoot = workspace.projectRoot
        var roots = agentSettings.projects.map(\.root)
        if let activeRoot, !roots.contains(activeRoot) {
            roots.insert(activeRoot, at: 0)
        }

        return ListProjectsResult(
            activeProjectRoot: activeRoot,
            projects: roots.map { root in
                ProjectInfo(
                    root: root,
                    name: URL(fileURLWithPath: root, isDirectory: true).lastPathComponent,
                    active: root == activeRoot,
                    open: root == activeRoot,
                    features: projectFeatureAvailability(for: root)
                )
            }
        )
    }

    @MainActor
    private func projectStatus(workspace: TerminalWorkspace) -> ProjectStatusResult {
        let selectedSession = workspace.selectedSession
        let noteStore = try? activeNoteStore(for: workspace)
        let todoStore = try? activeTodoStore(for: workspace)
        let features = projectFeatureAvailability(for: workspace.projectRoot)
        return ProjectStatusResult(
            projectRoot: workspace.projectRoot,
            processCounts: .init(
                total: workspace.sessions.count,
                terminals: workspace.terminalSessions.count,
                agents: workspace.agentSessions.count,
                commands: workspace.commandSessions.count
            ),
            noteCount: noteStore?.notes.count,
            todoCount: todoStore?.todos.count,
            features: features,
            selectedProcessID: selectedSession?.id.uuidString,
            selectedProcessName: selectedSession.map(processName),
            health: workspace.projectRoot == nil ? "no_project" : "ok"
        )
    }

    @MainActor
    private func listProcesses(workspace: TerminalWorkspace, kind requestedKind: String?) throws -> ListProcessesResult {
        let kind = try processKind(from: requestedKind)
        let sessions = workspace.sessions.filter { session in
            guard let kind else { return true }
            return session.kind == kind
        }
        return ListProcessesResult(
            activeProjectRoot: workspace.projectRoot,
            processes: sessions.map { processInfo(for: $0, workspace: workspace) },
            selectedProcessID: workspace.selectedSessionID?.uuidString
        )
    }

    @MainActor
    private func processInfo(for session: TerminalSession, workspace: TerminalWorkspace) -> ProcessSummary {
        ProcessSummary(
            id: session.id.uuidString,
            link: link(for: session, workspace: workspace),
            name: processName(for: session),
            kind: session.kind.rawValue,
            state: session.state.label,
            pid: session.childProcessID,
            startedAt: session.startedAt,
            exitedAt: session.exitedAt,
            lastOutputAt: session.lastOutputAt,
            acceptsInput: session.acceptsInput,
            exitCode: session.exitCode,
            restartPolicy: session.restartPolicy,
            workingDirectory: session.workingDirectory,
            commandLine: session.kind == .terminal ? nil : session.subtitle,
            lineCount: session.lineCount,
            summary: session.summary,
            selected: workspace.selectedSessionID == session.id,
            agentName: session.agentName,
            commandName: session.commandName
        )
    }

    @MainActor
    private func processName(for session: TerminalSession) -> String {
        session.commandName?.nilIfEmpty ?? session.agentName?.nilIfEmpty ?? session.title
    }

    @MainActor
    private func resolveProcess(
        workspace: TerminalWorkspace,
        processID: String?,
        processName: String?
    ) throws -> TerminalSession {
        if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty {
            return try findSession(workspace: workspace, terminalID: processID)
        }

        guard let requestedName = processName?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedName.isEmpty else {
            throw CherryControlError(code: "missing_process_selector", message: "Provide process_id or process_name.")
        }

        let normalizedName = AgentToolDefinition.normalizedName(requestedName)
        let matches = workspace.sessions.filter { session in
            self.processName(for: session).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
                || session.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
        guard let session = matches.first else {
            throw CherryControlError(code: "process_not_found", message: "No Cherry process exists with name \(requestedName).")
        }
        guard matches.count == 1 else {
            throw CherryControlError(code: "ambiguous_process_name", message: "Multiple Cherry processes match name \(requestedName); use process_id.")
        }
        return session
    }

    @MainActor
    private func spawnProcess(_ request: SpawnProcessRequest, workspace: TerminalWorkspace) throws -> (TerminalSession, Int) {
        let kind = try requiredProcessKind(from: request.kind)
        let session: TerminalSession
        switch kind {
        case .terminal:
            guard request.name == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Terminal processes do not use name; pass title instead.")
            }
            session = workspace.addSession(title: request.title, workingDirectory: request.workingDirectory, select: false)
        case .agent:
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let agent = try findAgent(named: request.name ?? "")
            guard agent.isLaunchable else {
                throw CherryControlError(code: "agent_not_launchable", message: "Agent '\(agent.name)' is not launchable.")
            }
            session = workspace.addAgentSession(agent: agent.definition, projectRoot: projectRoot, title: request.title, select: false)
        case .command:
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let command = try findProjectCommand(named: request.name ?? "", projectRoot: projectRoot)
            session = workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
        }

        let payload = try optionalInputPayload(text: request.text, rawBase64: request.rawBase64)
        if let payload, !payload.isEmpty {
            session.send(data: payload)
        }
        return (session, payload?.count ?? 0)
    }

    @MainActor
    private func startProcess(_ request: ProcessLifecycleRequest, workspace: TerminalWorkspace) throws -> TerminalSession {
        if let session = try? resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName) {
            switch session.state {
            case .launching, .live:
                return session
            case .exited, .failed:
                if session.kind == .command {
                    session.restartManagedCommandIfNeeded()
                } else {
                    session.restart()
                }
                return session
            }
        }

        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        let kind = try processKind(from: request.kind)
        switch kind {
        case .agent:
            let agent = try findAgent(named: request.processName ?? "")
            guard agent.isLaunchable else {
                throw CherryControlError(code: "agent_not_launchable", message: "Agent '\(agent.name)' is not launchable.")
            }
            return workspace.addAgentSession(agent: agent.definition, projectRoot: projectRoot, select: false)
        case .command, nil:
            let command = try findProjectCommand(named: request.processName ?? "", projectRoot: projectRoot)
            return workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
        case .terminal:
            throw CherryControlError(code: "process_not_found", message: "No stopped terminal process matched the requested selector.")
        }
    }

    @MainActor
    private func servicesResult(
        workspace: TerminalWorkspace,
        sessions: [TerminalSession],
        includeUnattributed: Bool
    ) throws -> ServicesResult {
        let records = try detectedServices(
            workspace: workspace,
            sessions: sessions,
            includeUnattributed: includeUnattributed
        )
        return ServicesResult(
            activeProjectRoot: workspace.projectRoot,
            services: records.filter { $0.attribution == .processTree },
            unattributed: records.filter { $0.attribution == .unattributed }
        )
    }

    @MainActor
    private func detectedServices(
        workspace: TerminalWorkspace,
        sessions: [TerminalSession],
        includeUnattributed: Bool
    ) throws -> [ServiceRecord] {
        let inspectable = sessions.map { session in
            InspectableProcess(
                id: session.id.uuidString,
                name: processName(for: session),
                kind: session.kind.rawValue,
                rootPID: session.childProcessID,
                commandName: session.commandName,
                agentName: session.agentName
            )
        }
        return try serviceDetector.detectServices(processes: inspectable, includeUnattributed: includeUnattributed)
    }

    @MainActor
    private func waitForBoundPort(_ request: WaitForBoundPortRequest, workspace: TerminalWorkspace) async throws -> ServiceRecord {
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(request.timeoutMilliseconds ?? 10_000, 1), 60_000)) / 1_000)
        let includeUnattributed = request.includeUnattributed ?? false
        let sessions: [TerminalSession]
        if request.processID != nil || request.processName != nil {
            sessions = [try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)]
        } else {
            sessions = workspace.sessions
        }

        var lastCandidates: [ServiceRecord] = []
        repeat {
            let candidates = try detectedServices(
                workspace: workspace,
                sessions: sessions,
                includeUnattributed: includeUnattributed
            )
            .filter { service in
                request.port.map { $0 == service.port } ?? true
            }

            if candidates.count > 1 {
                throw CherryControlError(
                    code: "ambiguous_service",
                    message: "Multiple services match the requested filters; retry with process_id, process_name, or port.",
                    serviceCandidates: candidates
                )
            }

            if var service = candidates.first {
                if request.probeHTTP ?? false {
                    service.readiness = await httpReadiness(for: service, path: request.path)
                    if service.readiness == .httpOK {
                        return service
                    }
                } else {
                    return service
                }
                lastCandidates = [service]
            } else {
                lastCandidates = []
            }

            try? await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline

        throw CherryControlError(
            code: "port_wait_timed_out",
            message: "Timed out waiting for a matching bound port.",
            serviceCandidates: lastCandidates.isEmpty ? nil : lastCandidates
        )
    }

    private func httpReadiness(for service: ServiceRecord, path requestedPath: String?) async -> ServiceReadiness {
        let path = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "/"
        guard var components = URLComponents(string: service.url) else {
            return .httpFailed
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = components.url else {
            return .httpFailed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if response is HTTPURLResponse {
                return .httpOK
            }
            return .httpFailed
        } catch {
            return .httpFailed
        }
    }

    @MainActor
    private func stopProcess(_ session: TerminalSession) {
        if session.kind == .command {
            session.stopManagedCommand()
        } else {
            session.stop()
        }
    }

    @MainActor
    private func restartProcess(_ session: TerminalSession) {
        if session.kind == .command {
            session.restart()
        } else {
            session.restart()
        }
    }

    @MainActor
    private func startAllCommands(workspace: TerminalWorkspace) throws -> [TerminalSession] {
        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        return agentSettings.launchableProjectCommands(for: projectRoot).map {
            workspace.addCommandSession(command: $0, projectRoot: projectRoot, select: false)
        }
    }

    @MainActor
    private func restartAllCommands(workspace: TerminalWorkspace) throws {
        let sessions = try startAllCommands(workspace: workspace)
        for session in sessions {
            session.restart()
        }
    }

    @MainActor
    private func findProjectCommand(named requestedName: String, projectRoot: String) throws -> ProjectCommandDefinition {
        let normalizedName = AgentToolDefinition.normalizedName(requestedName)
        guard !normalizedName.isEmpty else {
            throw CherryControlError(code: "missing_process_name", message: "Provide a configured project command name.")
        }
        guard let command = agentSettings.launchableProjectCommands(for: projectRoot).first(where: { $0.normalizedName == normalizedName }) else {
            throw CherryControlError(code: "command_not_found", message: "No launchable Cherry project command is configured with name \(requestedName).")
        }
        return command
    }

    private func processKind(from rawValue: String?) throws -> TerminalSession.SessionKind? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }
        return try requiredProcessKind(from: rawValue)
    }

    private func requiredProcessKind(from rawValue: String) throws -> TerminalSession.SessionKind {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = TerminalSession.SessionKind(rawValue: normalized) else {
            throw CherryControlError(code: "invalid_process_kind", message: "Unknown process kind: \(rawValue)")
        }
        return kind
    }

    @MainActor
    private func rejectAmbiguousUnscopedProjectMutation(_ request: CherryControlRequest) throws {
        guard requestRequiresProjectScope(request) else { return }
        let openRoots = Set(openProjectRootsProvider().map(standardizedProjectRoot))
        guard openRoots.count > 1 else { return }

        throw CherryControlError(
            code: "project_scope_required",
            message: "This Cherry tool mutates project-scoped data, but multiple Cherry projects are open and the request did not include a project scope. Relaunch the agent in an updated Cherry terminal or pass a scoped Cherry control request."
        )
    }

    private func requestRequiresProjectScope(_ request: CherryControlRequest) -> Bool {
        switch request {
        case .createNote,
             .updateNote,
             .appendNote,
             .renameNote,
             .deleteNote,
             .createTodo,
             .updateTodo,
             .moveTodo,
             .deleteTodo,
             .addTodoComment,
             .updateTodoComment,
             .deleteTodoComment:
            true
        default:
            false
        }
    }

    @MainActor
    private func listNotes(noteStore: ProjectNoteStore) -> ListNotesResult {
        ListNotesResult(
            activeProjectRoot: noteStore.projectRoot,
            notes: noteStore.notes.map(noteInfo),
            selectedNoteID: chromeState(forProjectRoot: noteStore.projectRoot)?.selectedNoteID?.uuidString
        )
    }

    private func noteInfo(_ note: ProjectNote) -> NoteInfo {
        NoteInfo(
            id: note.id.uuidString,
            link: link(for: note),
            projectRoot: note.projectRoot,
            title: note.title,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        )
    }

    @MainActor
    private func searchNotes(noteStore: ProjectNoteStore, request: SearchNotesRequest) -> SearchNotesResult {
        let query = request.query
        let caseSensitive = request.caseSensitive ?? false
        let maxMatches = min(max(request.maxMatches ?? 50, 1), 500)
        guard !query.isEmpty else {
            return SearchNotesResult(activeProjectRoot: noteStore.projectRoot, matches: [])
        }

        var matches: [NoteSearchMatch] = []
        for note in noteStore.notes {
            if textMatches(note.title, query: query, caseSensitive: caseSensitive) {
                matches.append(.init(noteID: note.id.uuidString, title: note.title, lineNumber: nil, text: note.title))
                if matches.count >= maxMatches { break }
            }

            let lines = note.markdown.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where textMatches(line, query: query, caseSensitive: caseSensitive) {
                matches.append(.init(noteID: note.id.uuidString, title: note.title, lineNumber: index, text: line))
                if matches.count >= maxMatches { break }
            }

            if matches.count >= maxMatches { break }
        }

        return SearchNotesResult(activeProjectRoot: noteStore.projectRoot, matches: matches)
    }

    @MainActor
    private func listTodos(todoStore: ProjectTodoStore) -> ListTodosResult {
        ListTodosResult(
            activeProjectRoot: todoStore.projectRoot,
            todos: todoStore.todos.map(todoInfo),
            selectedTodoID: chromeState(forProjectRoot: todoStore.projectRoot)?.selectedTodoID?.uuidString
        )
    }

    private func todoInfo(_ todo: ProjectTodo) -> TodoInfo {
        TodoInfo(
            id: todo.id.uuidString,
            link: link(for: todo),
            projectRoot: todo.projectRoot,
            title: todo.title,
            status: todo.status,
            position: todo.position,
            tags: todo.tags,
            commentCount: todo.comments.count,
            createdAt: todo.createdAt,
            updatedAt: todo.updatedAt
        )
    }

    @MainActor
    private func findAgent(named requestedName: String) throws -> ResolvedAgentTool {
        let normalizedName = AgentToolDefinition.normalizedName(requestedName)
        guard let agent = agentSettings.resolvedAgents.first(where: { $0.definition.normalizedName == normalizedName }) else {
            throw CherryControlError(code: "agent_not_found", message: "No Cherry agent is configured with name \(requestedName).")
        }
        return agent
    }

    @MainActor
    private func findSession(workspace: TerminalWorkspace, terminalID: String) throws -> TerminalSession {
        guard let session = workspace.session(id: terminalID) else {
            throw CherryControlError(code: "terminal_not_found", message: "No Cherry terminal exists with id \(terminalID).")
        }
        return session
    }

    @MainActor
    private func scopedWorkspace(projectRoot rawProjectRoot: String) throws -> TerminalWorkspace {
        let projectRoot = standardizedProjectRoot(rawProjectRoot)
        if let workspace, workspace.projectRoot.map(standardizedProjectRoot) == projectRoot {
            return workspace
        }
        if let activeWorkspace = workspaceProvider(),
           activeWorkspace.projectRoot.map(standardizedProjectRoot) == projectRoot {
            return activeWorkspace
        }
        if let registeredWorkspace = workspaceForProjectRootProvider(rawProjectRoot)
            ?? workspaceForProjectRootProvider(projectRoot) {
            return registeredWorkspace
        }
        if let containingProjectRoot = containingOpenProjectRoot(for: projectRoot),
           let registeredWorkspace = workspaceForProjectRootProvider(containingProjectRoot) {
            return registeredWorkspace
        }

        throw CherryControlError(
            code: "project_unavailable",
            message: "Cherry project is not open for scoped request: \(rawProjectRoot)."
        )
    }

    @MainActor
    private func containingOpenProjectRoot(for path: String) -> String? {
        openProjectRootsProvider()
            .map(standardizedProjectRoot)
            .filter { contains(path: path, inProjectRoot: $0) }
            .max { $0.count < $1.count }
    }

    private func contains(path: String, inProjectRoot projectRoot: String) -> Bool {
        path == projectRoot || path.hasPrefix(projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/")
    }

    private func standardizedProjectRoot(_ projectRoot: String) -> String {
        URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.path
    }

    @MainActor
    private func activeNoteStore(for workspace: TerminalWorkspace) throws -> ProjectNoteStore {
        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        try requireNotesEnabled(projectRoot: projectRoot)
        if let store = noteStore, store.projectRoot == projectRoot {
            return store
        }
        if let store = noteStoreForProjectRootProvider(projectRoot) {
            return store
        }
        if let store = noteStoreProvider(), store.projectRoot == projectRoot {
            return store
        }

        throw CherryControlError(code: "notes_unavailable", message: "Cherry notes are unavailable for the requested project.")
    }

    @MainActor
    private func activeTodoStore(for workspace: TerminalWorkspace) throws -> ProjectTodoStore {
        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        try requireTodosEnabled(projectRoot: projectRoot)
        if let store = todoStore, store.projectRoot == projectRoot {
            return store
        }
        if let store = todoStoreForProjectRootProvider(projectRoot) {
            return store
        }
        if let store = todoStoreProvider(), store.projectRoot == projectRoot {
            return store
        }

        throw CherryControlError(code: "todos_unavailable", message: "Cherry todos are unavailable for the requested project.")
    }

    @MainActor
    private func projectFeatureAvailability(for projectRoot: String?) -> ProjectFeatureAvailability {
        let features = agentSettings.projectFeatures(for: projectRoot)
        return ProjectFeatureAvailability(
            notesEnabled: features.notesEnabled,
            todosEnabled: features.todosEnabled
        )
    }

    @MainActor
    private func requireNotesEnabled(projectRoot: String) throws {
        guard agentSettings.projectFeatures(for: projectRoot).notesEnabled else {
            throw CherryControlError(
                code: "feature_disabled",
                message: "Cherry notes are disabled for this project. Enable Notes in project settings before using note tools."
            )
        }
    }

    @MainActor
    private func requireTodosEnabled(projectRoot: String) throws {
        guard agentSettings.projectFeatures(for: projectRoot).todosEnabled else {
            throw CherryControlError(
                code: "feature_disabled",
                message: "Cherry todos are disabled for this project. Enable Todos in project settings before using todo tools."
            )
        }
    }

    @MainActor
    private func chromeState(forProjectRoot projectRoot: String) -> ProjectWindowChromeState? {
        if let state = chromeStateForProjectRootProvider(projectRoot) {
            return state
        }
        if let workspace, workspace.projectRoot == projectRoot {
            return chromeState ?? chromeStateProvider()
        }
        if let activeWorkspace = workspaceProvider(), activeWorkspace.projectRoot == projectRoot {
            return chromeStateProvider()
        }
        return nil
    }

    @MainActor
    private func chromeState(for workspace: TerminalWorkspace) -> ProjectWindowChromeState? {
        guard let projectRoot = workspace.projectRoot else {
            return nil
        }
        return chromeState(forProjectRoot: projectRoot)
    }

    @MainActor
    private func select(note: ProjectNote, workspace: TerminalWorkspace) {
        chromeState(for: workspace)?.selectNote(id: note.id)
    }

    @MainActor
    private func select(todo: ProjectTodo, workspace: TerminalWorkspace) {
        chromeState(for: workspace)?.selectTodo(id: todo.id)
    }

    private func noteID(from value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw CherryControlError(code: "invalid_note_id", message: "Note id is not a valid UUID: \(value)")
        }
        return id
    }

    private func todoID(from value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw CherryControlError(code: "invalid_todo_id", message: "Todo id is not a valid UUID: \(value)")
        }
        return id
    }

    private func commentID(from value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw CherryControlError(code: "invalid_todo_comment_id", message: "Todo comment id is not a valid UUID: \(value)")
        }
        return id
    }

    @MainActor
    private func todoCommentAuthor(
        from request: AddTodoCommentRequest,
        workspace: TerminalWorkspace
    ) throws -> (label: String, terminalID: String?, agentName: String?) {
        if let terminalID = request.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            let session = try findSession(workspace: workspace, terminalID: terminalID)
            guard session.kind == .agent else {
                throw CherryControlError(code: "invalid_comment_author_terminal", message: "terminal_id must refer to an agent terminal.")
            }
            let label = session.agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? session.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Agent"
            return (label, session.id.uuidString, session.agentName)
        }

        let label = request.author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "MCP"
        return (label, nil, nil)
    }

    private func link(for note: ProjectNote) -> String {
        CherryDeepLink.noteURL(projectRoot: note.projectRoot, noteID: note.id)
    }

    private func link(for todo: ProjectTodo) -> String {
        CherryDeepLink.todoURL(projectRoot: todo.projectRoot, todoID: todo.id)
    }

    @MainActor
    private func link(for session: TerminalSession, workspace: TerminalWorkspace) -> String? {
        guard let projectRoot = workspace.projectRoot else { return nil }
        return CherryDeepLink.terminalURL(projectRoot: projectRoot, terminalID: session.id)
    }

    @MainActor
    private func link(for session: TerminalSession) -> String? {
        guard let projectRoot = ProjectWindowRegistry.shared.projectRoot(containing: session.id) else { return nil }
        return CherryDeepLink.terminalURL(projectRoot: projectRoot, terminalID: session.id)
    }

    @MainActor
    private func summary(for session: TerminalSession, workspace: TerminalWorkspace) -> TerminalSummaryResult {
        TerminalSummaryResult(
            terminalID: session.id.uuidString,
            link: link(for: session, workspace: workspace),
            title: session.title,
            state: session.state.label,
            kind: session.kind.rawValue,
            agentName: session.agentName,
            summary: session.summary
        )
    }

    private func inputPayload(from request: SendInputRequest) throws -> Data {
        try inputPayload(text: request.text, rawBase64: request.rawBase64)
    }

    private func inputPayload(text: String?, rawBase64: String?) throws -> Data {
        switch (text, rawBase64) {
        case let (text?, nil):
            return Data(text.utf8)
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            return data
        default:
            throw CherryControlError(code: "invalid_input", message: "Provide exactly one of text or raw_base64.")
        }
    }

    @MainActor
    private func lifecycleOutput(
        for session: TerminalSession,
        waitMilliseconds requestedWaitMilliseconds: Int?,
        lineLimit: Int?
    ) async throws -> TerminalOutputResult? {
        let waitMilliseconds = min(max(requestedWaitMilliseconds ?? 0, 0), 5_000)
        guard waitMilliseconds > 0 else { return nil }
        try? await Task.sleep(for: .milliseconds(waitMilliseconds))
        return terminalOutput(for: session, startLine: nil, lineLimit: lineLimit)
    }

    private func optionalInputPayload(text: String?, rawBase64: String?) throws -> Data? {
        switch (text, rawBase64) {
        case let (text?, nil):
            return Data(text.utf8)
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            return data
        case (nil, nil):
            return nil
        case (_?, _?):
            throw CherryControlError(code: "invalid_input", message: "Provide at most one of text or raw_base64.")
        }
    }

    private func runAgentInputPayload(text: String?, rawBase64: String?, submit: Bool?) throws -> Data? {
        guard var payload = try optionalInputPayload(text: text, rawBase64: rawBase64) else {
            return nil
        }
        if submit != false, payload.last != 0x0d, payload.last != 0x0a {
            payload.append(0x0d)
        }
        return payload
    }

    @MainActor
    private func terminalOutput(for session: TerminalSession, startLine requestedStartLine: Int?, lineLimit requestedLineLimit: Int?) -> TerminalOutputResult {
        let totalLines = session.lineCount
        let lineLimit = min(max(requestedLineLimit ?? 200, 1), 2_000)
        let startLine = requestedStartLine.map { min(max($0, 0), totalLines) } ?? max(0, totalLines - lineLimit)
        let endLine = min(totalLines, startLine + lineLimit)
        let lines = startLine < endLine ? session.snapshot(range: startLine..<endLine) : []
        return TerminalOutputResult(
            terminalID: session.id.uuidString,
            startLine: startLine,
            endLineExclusive: endLine,
            totalLines: totalLines,
            lines: lines
        )
    }

    @MainActor
    private func rawOutput(for session: TerminalSession, maxBytes requestedMaxBytes: Int?) -> TerminalRawOutputResult {
        let maxBytes = min(max(requestedMaxBytes ?? 65_536, 1), 1_048_576)
        let snapshot = session.rawOutput(maxBytes: maxBytes)
        return TerminalRawOutputResult(
            terminalID: session.id.uuidString,
            text: String(decoding: snapshot.data, as: UTF8.self),
            byteCount: snapshot.data.count,
            truncated: snapshot.truncated
        )
    }

    @MainActor
    private func searchOutput(for session: TerminalSession, request: SearchOutputRequest) -> SearchOutputResult {
        searchOutput(
            for: session,
            query: request.query,
            caseSensitive: request.caseSensitive,
            maxMatches: request.maxMatches
        )
    }

    @MainActor
    private func searchOutput(
        for session: TerminalSession,
        query: String,
        caseSensitive requestedCaseSensitive: Bool?,
        maxMatches requestedMaxMatches: Int?
    ) -> SearchOutputResult {
        let caseSensitive = requestedCaseSensitive ?? false
        let maxMatches = min(max(requestedMaxMatches ?? 50, 1), 500)
        guard !query.isEmpty else {
            return SearchOutputResult(terminalID: session.id.uuidString, matches: [])
        }

        var matches: [SearchOutputMatch] = []
        let lines = session.snapshot(range: 0..<session.lineCount)
        for (index, line) in lines.enumerated() {
            if textMatches(line, query: query, caseSensitive: caseSensitive) {
                matches.append(.init(lineNumber: index, text: line))
                if matches.count >= maxMatches {
                    break
                }
            }
        }

        return SearchOutputResult(terminalID: session.id.uuidString, matches: matches)
    }

    private func textMatches(_ text: String, query: String, caseSensitive: Bool) -> Bool {
        caseSensitive
            ? text.contains(query)
            : text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private nonisolated static func readRequest(fileDescriptor fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.last == 0x0A {
                    data.removeLast()
                    return data
                }
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private nonisolated static func configureBlocking(fileDescriptor fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    private nonisolated static func setCloseOnExec(fileDescriptor fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    private nonisolated static func writeResponse(_ response: CherryControlResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private nonisolated static func controlError(from error: Error) -> CherryControlError {
        if let error = error as? CherryControlError {
            return error
        }
        return CherryControlError(code: "control_error", message: error.localizedDescription)
    }
}
