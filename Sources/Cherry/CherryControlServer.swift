import CherryControl
import Darwin
import Foundation

private let mcpControlDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_MCP"] == "1"

private func mcpControlDebugLog(_ message: @autoclosure () -> String) {
    guard mcpControlDebugEnabled else { return }
    fputs("[mcp-control] \(message())\n", stderr)
}

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
    private let openProjectProvider: @MainActor (String) -> Void
    private let agentSettings: AgentSettings
    private let serviceDetector: any ServiceDetecting
    /// Services of tabs of other Macs (docs/specs/remote-devices.md, phase 4a).
    private let remoteServiceDetector: any RemoteServiceDetecting
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
        serviceDetector: any ServiceDetecting = MacOSServiceDetector(),
        remoteServiceDetector: (any RemoteServiceDetecting)? = nil,
        monitorDefaults: UserDefaults = .standard,
        taskBoard: AgentTaskBoard? = nil
    ) {
        self.monitors = AgentMonitorRegistry(defaults: monitorDefaults)
        self.tasks = AgentTaskRegistry(board: taskBoard ?? .shared)
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
        self.openProjectProvider = { _ in }
        self.agentSettings = agentSettings
        self.serviceDetector = serviceDetector
        self.remoteServiceDetector = remoteServiceDetector ?? DeviceServiceDetector()
        self.socketURL = socketURL
        tasks.wakeLinesEnabled = { [monitors] in monitors.wakeLinesEnabled }
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
            ProjectWindowRegistry.shared.knownProjectRoots
        },
        openProjectProvider: @escaping @MainActor (String) -> Void = { _ in },
        socketURL: URL = CherryControl.socketURL,
        agentSettings: AgentSettings = .shared,
        serviceDetector: any ServiceDetecting = MacOSServiceDetector(),
        remoteServiceDetector: (any RemoteServiceDetecting)? = nil,
        monitorDefaults: UserDefaults = .standard,
        taskBoard: AgentTaskBoard? = nil
    ) {
        self.monitors = AgentMonitorRegistry(defaults: monitorDefaults)
        self.tasks = AgentTaskRegistry(board: taskBoard ?? .shared)
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
        self.openProjectProvider = openProjectProvider
        self.agentSettings = agentSettings
        self.serviceDetector = serviceDetector
        self.remoteServiceDetector = remoteServiceDetector ?? DeviceServiceDetector()
        self.socketURL = socketURL
        tasks.wakeLinesEnabled = { [monitors] in monitors.wakeLinesEnabled }
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

    /// The window an unscoped request falls back to.
    @MainActor
    func workspaceForMonitors() -> TerminalWorkspace? {
        workspace ?? workspaceProvider()
    }

    func stop() {
        Task { @MainActor [monitors] in monitors.stopSampler() }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFileDescriptor >= 0 {
            close(listenFileDescriptor)
            listenFileDescriptor = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
        for deviceID in listenerLock.withLock({ Array(deviceListeners.keys) }) {
            removeDeviceListener(deviceID: deviceID)
        }
    }

    // MARK: Listeners for other Macs (docs/specs/remote-devices.md, phase 4b)

    /// Where a caller comes from: This Mac's socket (identified by its
    /// process), or the listener a device's forward reaches (identified by
    /// its tab's token, required).
    enum CallerOrigin: Equatable, Sendable {
        case thisMac
        case device(UUID)
    }

    /// Checks the tokens of callers on other Macs (the app's).
    var mcpTokens: RemoteMCPTokens = .shared

    private struct DeviceListener {
        var url: URL
        var source: DispatchSourceRead
    }

    private let listenerLock = NSLock()
    private var deviceListeners: [UUID: DeviceListener] = [:]
    /// Connections each device's listener serves now (`RequestLimits.maxConnections`).
    private var deviceConnections: [UUID: Int] = [:]

    /// What one connection may send and how many may be served at once.
    struct RequestLimits: Sendable {
        /// The longest request line; a longer one is refused
        /// (`request_too_large`) before it is decoded.
        var maxBytes: Int
        /// The whole request must arrive within this long
        /// (`request_timeout`), however slowly its bytes come; nil: only
        /// each read's timeout.
        var deadline: TimeInterval?
        /// Connections served at once; the next is refused at once
        /// (`too_many_connections`). Nil: no limit.
        var maxConnections: Int?

        /// A device's listener: whatever reaches it came from another Mac.
        static let device = RequestLimits(maxBytes: 8 << 20, deadline: 15, maxConnections: 16)
        /// This Mac's socket (0600, this account's processes): a generous
        /// cap only (pasted input and notes can be large).
        static let thisMac = RequestLimits(maxBytes: 64 << 20, deadline: nil, maxConnections: nil)
    }

    nonisolated static func limits(for origin: CallerOrigin) -> RequestLimits {
        origin == .thisMac ? .thisMac : .device
    }

    /// Takes one of the device's connection slots; false when all are in use.
    private nonisolated func acquireConnectionSlot(for origin: CallerOrigin) -> Bool {
        guard case .device(let deviceID) = origin, let maximum = Self.limits(for: origin).maxConnections else { return true }
        return listenerLock.withLock {
            let current = deviceConnections[deviceID, default: 0]
            guard current < maximum else { return false }
            deviceConnections[deviceID] = current + 1
            return true
        }
    }

    private nonisolated func releaseConnectionSlot(for origin: CallerOrigin) {
        guard case .device(let deviceID) = origin, Self.limits(for: origin).maxConnections != nil else { return }
        listenerLock.withLock {
            let remaining = deviceConnections[deviceID, default: 1] - 1
            deviceConnections[deviceID] = remaining > 0 ? remaining : nil
        }
    }

    /// The local socket a device's reverse forward reaches: next to the
    /// control socket, in its private directory.
    func deviceListenerURL(deviceID: UUID) -> URL {
        socketURL.deletingLastPathComponent()
            .appendingPathComponent("mcp-\(RemoteMCPPaths.shortName(deviceID: deviceID)).sock", isDirectory: false)
    }

    /// Listens for callers of `deviceID` (its CherryMCPs, through the
    /// forward): every request must carry a valid token of an open tab of
    /// that device. Returns the socket (the one there already, if any).
    @discardableResult
    func addDeviceListener(deviceID: UUID) throws -> URL {
        if let existing = listenerLock.withLock({ deviceListeners[deviceID] }) { return existing.url }
        try prepareSocketDirectory(removingSocket: false)
        let url = deviceListenerURL(deviceID: deviceID)
        try? FileManager.default.removeItem(at: url)
        let fd = try Self.bindListeningSocket(path: url.path)
        let source = makeAcceptSource(fileDescriptor: fd, origin: .device(deviceID))
        listenerLock.withLock { deviceListeners[deviceID] = DeviceListener(url: url, source: source) }
        source.resume()
        return url
    }

    /// Stops listening for `deviceID`'s callers and removes its socket.
    func removeDeviceListener(deviceID: UUID) {
        guard let listener = listenerLock.withLock({ deviceListeners.removeValue(forKey: deviceID) }) else { return }
        listener.source.cancel()
        try? FileManager.default.removeItem(at: listener.url)
    }

    private func prepareSocketDirectory(removingSocket: Bool = true) throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        chmod(directoryURL.path, S_IRWXU)
        if removingSocket { try? FileManager.default.removeItem(at: socketURL) }
    }

    private func bindAndListen() throws {
        let fd = try Self.bindListeningSocket(path: socketURL.path)
        listenFileDescriptor = fd
        let source = makeAcceptSource(fileDescriptor: fd, origin: .thisMac, closesOnCancel: false)
        source.setCancelHandler {
            close(fd)
        }
        acceptSource = source
        source.resume()
    }

    /// A listening Unix socket at `path` (mode 0600, non-blocking).
    private nonisolated static func bindListeningSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        setCloseOnExec(fileDescriptor: fd)

        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
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
        return fd
    }

    private func makeAcceptSource(fileDescriptor fd: Int32, origin: CallerOrigin, closesOnCancel: Bool = true) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections(on: fd, origin: origin)
        }
        if closesOnCancel {
            source.setCancelHandler {
                close(fd)
            }
        }
        return source
    }

    private nonisolated func acceptAvailableConnections(on listenFileDescriptor: Int32, origin: CallerOrigin) {
        while true {
            let clientFD = accept(listenFileDescriptor, nil, nil)
            if clientFD >= 0 {
                Self.setCloseOnExec(fileDescriptor: clientFD)
                Self.configureBlocking(fileDescriptor: clientFD)
                // A client that went away (a device's ssh, whose other end
                // closed) makes a write fail with EPIPE, never SIGPIPE.
                var noSigpipe: Int32 = 1
                _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                // A silent client must not pin a pool thread forever (enough of
                // them starves EVERY later connection), and a client that stops
                // reading must not block response writes indefinitely.
                Self.configureSocketTimeouts(fileDescriptor: clientFD, seconds: 10)
                guard acquireConnectionSlot(for: origin) else {
                    // Every slot of this device's listener is in use.
                    DispatchQueue.global(qos: .utility).async {
                        Self.writeResponse(.init(error: .init(
                            code: "too_many_connections",
                            message: "Cherry is already serving as many requests from this Mac as it will at once. Try again shortly."
                        )), to: clientFD)
                        close(clientFD)
                    }
                    continue
                }
                handleConnection(fileDescriptor: clientFD, origin: origin)
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

    private nonisolated func handleConnection(fileDescriptor clientFD: Int32, origin: CallerOrigin) {
        // The connection's slot is given back once it is closed, whichever
        // way it ends.
        let finish: @Sendable () -> Void = { [weak self] in
            close(clientFD)
            self?.releaseConnectionSlot(for: origin)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                close(clientFD)
                return
            }

            // Peer PID of the connecting process (e.g. an agent's MCP server), used
            // to route unscoped requests to the caller's own workspace when the
            // agent CLI stripped CHERRY_PROJECT_ROOT from the MCP env. Never
            // for a device's listener: its peer is This Mac's ssh, and its
            // callers are another Mac's processes.
            let peerPID = origin == .thisMac ? Self.peerProcessID(fileDescriptor: clientFD) : nil

            let requestData: Data
            do {
                requestData = try Self.readRequest(fileDescriptor: clientFD, limits: Self.limits(for: origin))
            } catch {
                Self.writeResponse(.init(error: Self.controlError(from: error)), to: clientFD)
                finish()
                return
            }

            Task { @MainActor [weak self] in
                let response: CherryControlResponse
                if let self {
                    response = await self.handleRequestData(requestData, peerPID: peerPID, origin: origin)
                } else {
                    response = .init(error: .init(code: "server_unavailable", message: "Cherry control server is unavailable."))
                }

                // Write back off the main actor: a client that stopped reading
                // must never be able to block the main thread on a full socket
                // buffer.
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.writeResponse(response, to: clientFD)
                    finish()
                }
            }
        }
    }

    @MainActor
    func handleRequestData(_ data: Data, peerPID: Int32?, origin: CallerOrigin = .thisMac) async -> CherryControlResponse {
        do {
            let (credentials, request) = try CherryControlEnvelope.decode(data)
            if let credentials {
                let caller = try remoteCaller(credentials, origin: origin)
                // Everything this request reaches is checked against the
                // caller's device (`requireOnRemoteDevice`, the one choke
                // point), however it was mapped.
                return try await Self.$remoteDevice.withValue(caller.deviceID) {
                    try await Self.$remoteCallerSessionID.withValue(caller.session.id) {
                        try await handle(request, remoteCaller: caller)
                    }
                }
            }
            guard origin == .thisMac else {
                throw CherryControlError(
                    code: "unauthorized",
                    message: "This request came from another Mac without a Cherry MCP token. Run CherryMCP in a Cherry tab of that Mac."
                )
            }
            return try await Self.$callerPeerPID.withValue(peerPID) {
                try await handle(request, peerPID: peerPID)
            }
        } catch let error as CherryControlError {
            return .init(error: error)
        } catch {
            return .init(error: .init(code: "invalid_request", message: error.localizedDescription))
        }
    }

    @MainActor
    private func handle(_ request: CherryControlRequest, peerPID: Int32?) async throws -> CherryControlResponse {
        if case .scoped(let scopedRequest) = request {
            let workspace = try scopedWorkspace(projectRoot: scopedRequest.projectRoot)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        }

        // An unscoped request: prefer the caller's OWN workspace, resolved from the
        // connecting process's ancestry, so an MCP whose agent CLI stripped
        // CHERRY_PROJECT_ROOT still routes to its own project window instead of the
        // frontmost one. Fall back to the active workspace.
        if let callerWorkspace = callerWorkspace(peerPID: peerPID) {
            return try await handleUnscoped(request, workspace: callerWorkspace, isProjectScoped: true)
        }

        guard let workspace = workspace ?? workspaceProvider() else {
            throw CherryControlError(code: "workspace_unavailable", message: "Cherry workspace is unavailable.")
        }

        return try await handleUnscoped(request, workspace: workspace, isProjectScoped: false)
    }

    /// A caller on another Mac, as its token identifies it: its tab, that
    /// tab's window, and the device.
    struct RemoteCaller {
        var deviceID: UUID
        var session: TerminalSession
        var workspace: TerminalWorkspace
    }

    /// The open tab of a device `credentials` name, when its token is that
    /// tab's. Through a device's listener the device is the listener's; on
    /// This Mac's socket (never used by CherryMCP there) it is the tab's.
    @MainActor
    private func remoteCaller(_ credentials: CherryControlCredentials, origin: CallerOrigin) throws -> RemoteCaller {
        let refused = CherryControlError(
            code: "unauthorized",
            message: "Cherry refused this Cherry MCP token: it does not belong to an open tab of this Mac's Cherry (the tab was closed, or it was started by another copy of Cherry)."
        )
        guard let tabID = UUID(uuidString: credentials.processID) else { throw refused }
        let workspaces = openProjectRootsProvider().compactMap { workspaceForProjectRootProvider($0) }
            + [workspace, workspaceProvider()].compactMap { $0 }
        for candidate in workspaces {
            guard let session = candidate.sessions.first(where: { $0.id == tabID }),
                  let key = candidate.projectRoot,
                  let deviceID = ProjectLocation(key: key).deviceID
            else { continue }
            if case .device(let listenerDevice) = origin, listenerDevice != deviceID { throw refused }
            // Only a tab whose program runs on that device carries its
            // token (never one attached from This Mac or another host).
            guard Self.isSession(session, in: candidate, onDevice: deviceID) else { throw refused }
            guard mcpTokens.isValid(credentials.token, tabID: tabID, deviceID: deviceID) else { throw refused }
            return RemoteCaller(deviceID: deviceID, session: session, workspace: candidate)
        }
        throw refused
    }

    /// The device of the caller on another Mac whose request is being
    /// handled, nil for This Mac's callers. A task local: requests
    /// interleave on the main actor, and each sees only its own.
    @TaskLocal static var remoteDevice: UUID?

    /// The tab of the caller on another Mac whose request is being handled
    /// (its token's), nil for This Mac's callers.
    @TaskLocal static var remoteCallerSessionID: UUID?

    /// The peer process of the This Mac caller whose request is being
    /// handled (its CherryMCP), for `verifiedCallerSession`.
    @TaskLocal static var callerPeerPID: Int32?

    /// Monitors (`subscribe`, `wait_for_events`, wake lines).
    let monitors: AgentMonitorRegistry

    /// Tasks (`spawn_agent` with `task`, `report_result`, `wait_for_tasks`):
    /// in memory, each tied to its worker's tab and window.
    let tasks: AgentTaskRegistry

    /// Tests: the caller's own tab, in place of the peer's process ancestry.
    @MainActor var callerSessionResolverForTesting: ((Int32?) -> TerminalSession?)?

    static func refusedOutsideDevice(_ what: String) -> CherryControlError {
        CherryControlError(
            code: "outside_caller_mac",
            message: "A caller on another Mac can only reach its own Mac's projects and processes: \(what) is not one of them."
        )
    }

    /// The one choke point for a caller on another Mac (`remoteDevice`):
    /// a workspace it reaches must be a project on that Mac
    /// (`ProjectLocation.remote(deviceID:)`). Every request goes through
    /// `handleUnscoped`, which checks its workspace here after all mapping;
    /// sessions found by id, links and listings check theirs too.
    @MainActor
    private func requireOnRemoteDevice(_ workspace: TerminalWorkspace) throws {
        guard let device = Self.remoteDevice else { return }
        guard Self.isOnDevice(workspace.projectRoot, device) else {
            throw Self.refusedOutsideDevice("that window")
        }
    }

    /// Whether `key` is a project on `device`.
    nonisolated static func isOnDevice(_ key: String?, _ device: UUID) -> Bool {
        guard let key else { return false }
        return ProjectLocation(key: key).deviceID == device
    }

    /// Whether `session`, a tab of `workspace`, runs on `device`: the
    /// window is a project of that device, and the tab's program runs on
    /// the window's own hosting (the device's, `SessionBackendPolicy.remote`)
    /// or is a session of that hosting's host attached from Persistent
    /// Sessions. A This Mac session or another SSH host's attached into
    /// the device's window is not on the device, nor is any native tab.
    @MainActor
    static func isSession(_ session: TerminalSession, in workspace: TerminalWorkspace, onDevice device: UUID) -> Bool {
        guard isOnDevice(workspace.projectRoot, device),
              let hosting = workspace.backendPolicy.localSessions,
              !hosting.profile.isThisMac, !hosting.profile.allowsNativeFallback
        else { return false }
        if let attachment = session.hostedAttachment {
            return attachment.host == hosting.profile.host
        }
        return session.persistentHosting === hosting
    }

    /// Whether the caller may see and act on `session` of `workspace`:
    /// always for This Mac's callers; for a caller on another Mac, only a
    /// session on that Mac (`isSession(_:in:onDevice:)`).
    @MainActor
    func callerReaches(_ session: TerminalSession, in workspace: TerminalWorkspace) -> Bool {
        guard let device = Self.remoteDevice else { return true }
        return Self.isSession(session, in: workspace, onDevice: device)
    }

    /// The tabs of `workspace` the caller may see (`callerReaches`): every
    /// listing, name lookup, count and scan goes through this.
    @MainActor
    func callerSessions(_ workspace: TerminalWorkspace) -> [TerminalSession] {
        guard Self.remoteDevice != nil else { return workspace.sessions }
        return workspace.sessions.filter { callerReaches($0, in: workspace) }
    }

    /// The selected tab, when the caller may see it.
    @MainActor
    private func callerSelectedSession(_ workspace: TerminalWorkspace) -> TerminalSession? {
        workspace.selectedSession.flatMap { callerReaches($0, in: workspace) ? $0 : nil }
    }

    /// `childAgentCount` of the tabs the caller may see.
    @MainActor
    private func callerChildAgentCount(of session: TerminalSession, in workspace: TerminalWorkspace) -> Int {
        guard Self.remoteDevice != nil else { return workspace.childAgentCount(of: session) }
        return workspace.childAgentSessions(of: session).filter { callerReaches($0, in: workspace) }.count
    }

    /// A request of a caller on another Mac: scoped as a local agent in the
    /// same window would be, but only ever on that Mac. Its unscoped
    /// requests go to its tab's window; a project root it names is a path
    /// on its Mac, or a `device:` key of that Mac, matched by location
    /// (never resolved as a path here).
    @MainActor
    private func handle(_ request: CherryControlRequest, remoteCaller caller: RemoteCaller) async throws -> CherryControlResponse {
        switch request {
        case .scoped(let scopedRequest):
            let workspace = try remoteWorkspace(projectRoot: scopedRequest.projectRoot, deviceID: caller.deviceID)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        case .openProject(let open):
            return .init(result: .openProject(try openRemoteProject(open, caller: caller)))
        default:
            return try await handleUnscoped(request, workspace: caller.workspace, isProjectScoped: true)
        }
    }

    /// The key a caller on `deviceID` names: a path there (absolute, no `.`
    /// or `..`), or a `device:` key of that same device.
    nonisolated static func remoteProjectLocation(_ root: String, deviceID: UUID) throws -> ProjectLocation {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let location: ProjectLocation
        if trimmed.hasPrefix(ProjectLocation.remoteKeyPrefix) {
            location = ProjectLocation(key: trimmed)
            guard case .remote(let keyDevice, _) = location else {
                throw CherryControlError(code: "project_unavailable", message: "Not a project key: \(root).")
            }
            guard keyDevice == deviceID else { throw refusedOutsideDevice("\(root)") }
            // The raw key's path, before normalisation keeps `..`.
            let rawPath = String(trimmed.drop { $0 != "/" })
            guard !ProjectLocation.hasDotComponents(rawPath) else {
                throw CherryControlError(code: "invalid_project_root", message: "A project root may not contain . or .. components.")
            }
        } else {
            guard trimmed.hasPrefix("/") else {
                throw CherryControlError(code: "invalid_project_root", message: "A project root must be an absolute path on this Mac: \(root).")
            }
            location = .remote(deviceID: deviceID, path: trimmed)
        }
        guard !ProjectLocation.hasDotComponents(location.path), !ProjectLocation.hasDotComponents(trimmed) else {
            throw CherryControlError(code: "invalid_project_root", message: "A project root may not contain . or .. components.")
        }
        return location
    }

    /// The open window of the device's project at `projectRoot` (or the
    /// project containing it, a worktree's window first), matched by
    /// location: the same device and the path, never through
    /// `standardizedProjectRoot`.
    @MainActor
    private func remoteWorkspace(projectRoot: String, deviceID: UUID) throws -> TerminalWorkspace {
        let location = try Self.remoteProjectLocation(projectRoot, deviceID: deviceID)
        let path = location.path
        let workspaces = (openProjectRootsProvider().compactMap { workspaceForProjectRootProvider($0) }
            + [workspace, workspaceProvider()].compactMap { $0 })
            .filter { Self.isOnDevice($0.projectRoot, deviceID) }
        if let exact = workspaces.first(where: { $0.projectRoot.map { ProjectLocation(key: $0).path } == path }) {
            return exact
        }
        let containing = workspaces
            .compactMap { candidate -> (TerminalWorkspace, String)? in
                guard let root = candidate.projectRoot.map({ ProjectLocation(key: $0).path }),
                      path.hasPrefix(root == "/" ? "/" : root + "/")
                else { return nil }
                return (candidate, root)
            }
            .max { $0.1.count < $1.1.count }
        guard let containing else {
            throw CherryControlError(code: "project_unavailable", message: "Cherry project is not open for scoped request: \(projectRoot).")
        }
        return containing.0
    }

    /// Open Project for a caller on another Mac: only a project of its Mac
    /// that Cherry knows, matched by its key exactly.
    @MainActor
    private func openRemoteProject(_ request: OpenProjectRequest, caller: RemoteCaller) throws -> OpenProjectResult {
        let key = try Self.remoteProjectLocation(request.projectRoot, deviceID: caller.deviceID).key
        let known = agentSettings.projects.map(\.root) + openProjectRootsProvider() + [caller.workspace.projectRoot].compactMap { $0 }
        guard known.contains(key) else {
            throw CherryControlError(code: "project_not_found", message: "Cherry project is not configured: \(request.projectRoot).")
        }
        let alreadyOpen = openProjectRootsProvider().contains(key)
        openProjectProvider(key)
        return OpenProjectResult(projectRoot: key, alreadyOpen: alreadyOpen)
    }

    /// The workspace whose session process tree contains the connecting peer (the
    /// agent's MCP server), found by walking the peer's process ancestry and
    /// matching against each open workspace's session PIDs. nil if no match.
    @MainActor
    private func callerWorkspace(peerPID: Int32?) -> TerminalWorkspace? {
        guard let peerPID else { return nil }
        let ancestry = Set(Self.processAncestry(of: peerPID))
        guard !ancestry.isEmpty else { return nil }
        let workspaces = openProjectRootsProvider().compactMap { workspaceForProjectRootProvider($0) }
        // The tab that runs the caller's program first: a tab attached to
        // the same session of This Mac (another window's view of it)
        // routes only when no window runs it. A persistent tab's program
        // pid comes from This Mac's host; a tab attached to another
        // machine's session has none.
        for attached in [false, true] {
            for workspace in workspaces {
                for session in workspace.sessions where (session.hostedAttachment != nil) == attached {
                    if let pid = session.programProcessID, ancestry.contains(pid) {
                        return workspace
                    }
                }
            }
        }
        return nil
    }

    /// `[pid, ppid, …]` up the process tree, via sysctl.
    nonisolated static func processAncestry(of pid: Int32, maxDepth: Int = 20) -> [Int32] {
        var result: [Int32] = [pid]
        var seen: Set<Int32> = [pid]
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentProcessID(of: current), parent > 1, !seen.contains(parent) else { break }
            result.append(parent)
            seen.insert(parent)
            current = parent
        }
        return result
    }

    private nonisolated static func parentProcessID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// PID of the process on the other end of a connected unix-domain socket.
    private nonisolated static func peerProcessID(fileDescriptor fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        return result == 0 && pid > 0 ? pid : nil
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
        if Self.remoteDevice != nil {
            try requireOnRemoteDevice(workspace)
            // A scoped request inside a scoped one would name a project
            // without the caller's mapping.
            if case .scoped = request {
                throw CherryControlError(code: "invalid_request", message: "A scoped request may not contain another one.")
            }
            if case .openProject = request {
                throw CherryControlError(code: "invalid_request", message: "Open a project with an unscoped request.")
            }
        }

        switch request {
        case .scoped(let scopedRequest):
            let workspace = try scopedWorkspace(projectRoot: scopedRequest.projectRoot)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        case .listProjects:
            return .init(result: .listProjects(listProjects(workspace: workspace)))
        case .openProject(let request):
            return .init(result: .openProject(try openProject(request, fallbackWorkspace: workspace)))
        case .getProjectStatus:
            return .init(result: .getProjectStatus(projectStatus(workspace: workspace)))
        case .getPerformanceStatus:
            return .init(result: .getPerformanceStatus(performanceStatus(workspace: workspace)))
        case .resolveLink(let request):
            return .init(result: .resolveLink(try resolveDeepLink(request, fallbackWorkspace: workspace)))
        case .listProcesses(let request):
            return .init(result: .listProcesses(try listProcesses(workspace: workspace, kind: request.kind)))
        case .getProcessStatus(let request):
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            // A targeted status query is expected to be current. Process lists
            // deliberately use the cached count, but this path can afford one
            // throttled native-surface refresh.
            await session.refreshContentFromHostIfNeeded()
            _ = session.lineCount
            return .init(result: .getProcessStatus(.init(process: processInfo(for: session, workspace: sessionWorkspace))))
        case .getProcessOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .getProcessOutput(terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)))
        case .getProcessRawOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .getProcessRawOutput(rawOutput(for: session, maxBytes: request.maxBytes)))
        case .searchProcessOutput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .searchProcessOutput(searchOutput(
                for: session,
                query: request.query,
                caseSensitive: request.caseSensitive,
                maxMatches: request.maxMatches
            )))
        case .waitForProcessIdle(let request):
            let result = try await waitForProcessIdle(request, workspace: workspace)
            return .init(result: .waitForProcessIdle(result))
        case .subscribe(let request):
            return .init(result: .subscribe(try await subscribe(request, workspace: workspace)))
        case .unsubscribe(let request):
            return .init(result: .unsubscribe(unsubscribe(request)))
        case .waitForEvents(let request):
            return .init(result: .waitForEvents(try await waitForEvents(request)))
        case .listSubscriptions:
            return .init(result: .listSubscriptions(listSubscriptions()))
        case .getMyTask:
            return .init(result: .getMyTask(try getMyTask()))
        case .reportResult(let request):
            return .init(result: .reportResult(try await reportResult(request)))
        case .reportProgress(let request):
            return .init(result: .reportProgress(try reportProgress(request)))
        case .waitForTasks(let request):
            return .init(result: .waitForTasks(try await waitForTasks(request)))
        case .getTask(let request):
            return .init(result: .getTask(try getTask(request)))
        case .listTasks(let request):
            return .init(result: .listTasks(try listTasks(request)))
        case .cancelTasks(let request):
            return .init(result: .cancelTasks(try cancelTasks(request)))
        case .getProcessPorts(let request):
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .getProcessPorts(try await servicesResult(
                workspace: sessionWorkspace,
                sessions: [session],
                includeUnattributed: request.includeUnattributed ?? false
            )))
        case .servicesList(let request):
            let kind = try processKind(from: request.kind)
            let sessions = callerSessions(workspace).filter { session in
                guard let kind else { return true }
                return session.kind == kind
            }
            return .init(result: .servicesList(try await servicesResult(
                workspace: workspace,
                sessions: sessions,
                includeUnattributed: request.includeUnattributed ?? false
            )))
        case .waitForBoundPort(let request):
            let service = try await waitForBoundPort(request, workspace: workspace)
            return .init(result: .waitForBoundPort(.init(service: service)))
        case .spawnProcess(let request):
            let (session, sentBytes) = try await spawnProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .spawnProcess(.init(
                process: processInfo(for: session, workspace: workspace),
                sentBytes: sentBytes,
                output: output,
                task: tasks.latestTask(forWorker: session.id)
                    .flatMap { $0.device == Self.remoteDevice ? tasks.info(for: $0) : nil }
            )))
        case .startProcess(let request):
            let session = try await startProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .startProcess(.init(process: processInfo(for: session, workspace: workspace), output: output)))
        case .stopProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            stopProcess(session)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .stopProcess(.init(process: processInfo(for: session, workspace: workspace), output: output)))
        case .restartProcess(let request):
            // Restart and close act on the window that owns the process, which
            // an id can name from any window.
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            try restartProcess(session, in: sessionWorkspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .restartProcess(.init(process: processInfo(for: session, workspace: sessionWorkspace), output: output)))
        case .closeProcess(let request):
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            try closeFromControl(session, workspace: sessionWorkspace, agentClosePolicy: request.agentClosePolicy)
            return .init(result: .closeProcess(.init(processID: session.id.uuidString, closed: true)))
        case .renameProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            session.rename(to: request.title)
            return .init(result: .renameProcess(.init(process: processInfo(for: session, workspace: workspace))))
        case .selectProcess(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            workspace.select(session)
            chromeState(for: workspace)?.selectTerminal()
            return .init(result: .selectProcess(.init(process: processInfo(for: session, workspace: workspace))))
        case .sendProcessInput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            let sentBytes = try await sendControlInput(
                text: request.text,
                rawBase64: request.rawBase64,
                submit: request.submit,
                to: session
            )
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .sendProcessInput(.init(processID: session.id.uuidString, sentBytes: sentBytes, output: output)))
        case .captureAttentionObservation(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            guard let label = TerminalAttentionLabel(rawValue: request.label) else {
                throw CherryControlError(
                    code: "invalid_attention_label",
                    message: "Unknown terminal attention label: \(request.label)"
                )
            }
            let capture: (id: UUID, outputURL: URL)
            do {
                capture = try session.captureAttentionObservation(
                    label: label,
                    scenarioID: request.scenarioID,
                    checkpoint: request.checkpoint,
                    harnessVersion: request.harnessVersion,
                    runID: request.runID
                )
            } catch TerminalAttentionRecordingError.disabled {
                throw CherryControlError(
                    code: "attention_recording_disabled",
                    message: TerminalAttentionRecordingError.disabled.localizedDescription
                )
            }
            return .init(result: .captureAttentionObservation(.init(
                processID: session.id.uuidString,
                observationID: capture.id.uuidString,
                outputPath: capture.outputURL.path
            )))
        case .startAllCommands(let request):
            _ = try await startAllCommands(workspace: workspace)
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .startAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .stopAllCommands(let request):
            workspace.commandSessions.filter { callerReaches($0, in: workspace) }.forEach { $0.stopManagedCommand() }
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .stopAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .restartAllCommands(let request):
            try await restartAllCommands(workspace: workspace)
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
            let resolvedAgent = try findAgent(named: request.agentName)
            guard resolvedAgent.isLaunchable else {
                throw CherryControlError(code: "agent_not_launchable", message: "Agent '\(resolvedAgent.name)' is not launchable.")
            }
            let agent = try agentDefinition(resolvedAgent.definition, overridingModel: request.model)
            let session = workspace.addAgentSession(
                agent: agent,
                projectRoot: projectRoot,
                title: request.title,
                parentAgentID: try parentAgentID(from: request.parentAgentID, workspace: workspace),
                select: request.select ?? false
            )
            if request.select ?? false {
                chromeState(for: workspace)?.selectTerminal()
            }
            let initialInput = try runAgentInitialInput(
                text: request.text,
                rawBase64: request.rawBase64,
                submit: request.submit,
                keyboardProtocolFlags: session.keyboardProtocolFlags
            )
            let sentBytes: Int
            if let initialInput, !initialInput.isEmpty {
                await waitForAgentInitialInputReadiness(session: session, agent: agent)
                // The agent exists either way: sentBytes says whether its
                // first input reached it.
                sentBytes = (try? await sendInitialAgentInput(initialInput, to: session, agent: agent)) ?? 0
            } else {
                sentBytes = 0
            }
            let waitMilliseconds = min(max(request.waitMilliseconds ?? 0, 0), 5_000)
            let lineLimit = min(max(request.lineLimit ?? 200, 1), 2_000)
            if waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
                await session.refreshContentFromHostIfNeeded()
            }
            let output = waitMilliseconds > 0 ? terminalOutput(for: session, startLine: nil, lineLimit: lineLimit) : nil
            return .init(result: .runAgent(.init(
                terminalID: session.id.uuidString,
                link: link(for: session, workspace: workspace),
                title: session.title,
                state: session.state.label,
                kind: session.kind.rawValue,
                agentName: session.agentName,
                summary: nil,
                parentAgentID: session.parentAgentID?.uuidString,
                childAgentCount: callerChildAgentCount(of: session, in: workspace),
                projectRoot: projectRoot,
                sentBytes: sentBytes,
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
            let (session, sessionWorkspace) = try findSessionWithWorkspace(workspace: workspace, terminalID: request.terminalID)
            session.rename(to: request.title)
            return .init(result: .renameTerminal(summary(for: session, workspace: sessionWorkspace)))
        case .selectTerminal(let request):
            let (session, sessionWorkspace) = try findSessionWithWorkspace(workspace: workspace, terminalID: request.terminalID)
            sessionWorkspace.select(session)
            chromeState(for: sessionWorkspace)?.selectTerminal()
            return .init(result: .selectTerminal(.init(terminalID: session.id.uuidString, selected: true)))
        case .sendInput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            let input = try terminalInputPayload(from: request, for: session)
            if session.kind == .agent {
                try await refuseInputIntoPermissionPrompt(of: session, keysOnly: input.isRaw)
            }
            try await sendTerminalInput(input, to: session)
            let waitMilliseconds = min(max(request.waitMilliseconds ?? 0, 0), 5_000)
            let lineLimit = min(max(request.lineLimit ?? 200, 1), 2_000)
            if waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
                await session.refreshContentFromHostIfNeeded()
            }
            let output = waitMilliseconds > 0 ? terminalOutput(for: session, startLine: nil, lineLimit: lineLimit) : nil
            return .init(result: .sendInput(.init(terminalID: session.id.uuidString, sentBytes: input.payload.count, output: output)))
        case .getTerminalOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .getTerminalOutput(terminalOutput(for: session, startLine: request.startLine, lineLimit: request.lineLimit)))
        case .getTerminalRawOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .getTerminalRawOutput(rawOutput(for: session, maxBytes: request.maxBytes)))
        case .searchOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            await session.refreshContentFromHostIfNeeded()
            return .init(result: .searchOutput(searchOutput(for: session, request: request)))
        case .clearOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            // A persistent tab's host clears its copy before this answers,
            // so the output read next no longer has it; or says why not.
            let kept = await session.clearScrollback()?.value ?? nil
            return .init(result: .clearOutput(.init(
                terminalID: session.id.uuidString, cleared: kept == nil, hostKeptHistory: kept
            )))
        case .restartTerminal(let request):
            let (session, sessionWorkspace) = try findSessionWithWorkspace(workspace: workspace, terminalID: request.terminalID)
            try restartProcess(session, in: sessionWorkspace)
            return .init(result: .restartTerminal(summary(for: session, workspace: sessionWorkspace)))
        case .closeTerminal(let request):
            let (session, sessionWorkspace) = try findSessionWithWorkspace(workspace: workspace, terminalID: request.terminalID)
            try closeFromControl(session, workspace: sessionWorkspace, agentClosePolicy: request.agentClosePolicy)
            return .init(result: .closeTerminal(.init(terminalID: session.id.uuidString, closed: true)))
        }
    }

    @MainActor
    private func resolveDeepLink(
        _ request: ResolveDeepLinkRequest,
        fallbackWorkspace workspace: TerminalWorkspace
    ) throws -> ResolveDeepLinkResult {
        let deepLink = try CherryDeepLink.parse(request.link)
        var projectRoot = projectRoot(forProjectKey: deepLink.projectKey, fallbackWorkspace: workspace)
        let normalizedLink = deepLink.absoluteString
        // A caller on another Mac resolves only its Mac's links.
        if let device = Self.remoteDevice, !Self.isOnDevice(projectRoot, device) {
            projectRoot = nil
        }

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
            guard let terminalID = UUID(uuidString: deepLink.targetID) else {
                return missingDeepLinkResult(deepLink, projectRoot: projectRoot, link: normalizedLink)
            }
            // The terminal UUID is the authoritative key: fall back to searching
            // every open window so a link keeps resolving even when the project
            // key → workspace mapping misses.
            let linked = workspaceForProjectRoot(projectRoot, fallbackWorkspace: workspace)
                .flatMap { linkedWorkspace in
                    linkedWorkspace.session(id: terminalID.uuidString)
                        .flatMap { callerReaches($0, in: linkedWorkspace) ? ($0, linkedWorkspace) : nil }
                }
            guard let (session, sessionWorkspace) = linked
                ?? (try? findSessionWithWorkspace(workspace: workspace, terminalID: terminalID.uuidString))
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
                process: processInfo(for: session, workspace: sessionWorkspace),
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
            terminals: callerSessions(workspace).map { session in
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
                    summary: nil,
                    parentAgentID: session.parentAgentID?.uuidString,
                    childAgentCount: callerChildAgentCount(of: session, in: workspace)
                )
            },
            selectedTerminalID: callerSelectedSession(workspace)?.id.uuidString
        )
    }

    @MainActor
    private func listAgents(workspace: TerminalWorkspace) -> ListAgentsResult {
        ListAgentsResult(
            activeProjectRoot: workspace.projectRoot,
            agents: agentSettings.resolvedAgents.map { agent in
                let normalizedName = agent.definition.normalizedName
                let activeSessionCount = workspace.agentSessions.filter { callerReaches($0, in: workspace) }.filter {
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
        let activeRepositoryRoot = agentSettings.repositoryRoot(for: activeRoot)
        var roots = agentSettings.projects.map(\.root)
        if let device = Self.remoteDevice {
            // A caller on another Mac: its Mac's projects only (configured
            // or open).
            roots = (roots + openProjectRootsProvider()).filter { Self.isOnDevice($0, device) }
            var seen = Set<String>()
            roots = roots.filter { seen.insert($0).inserted }
        }
        if let activeRepositoryRoot, !roots.contains(activeRepositoryRoot) {
            roots.insert(activeRepositoryRoot, at: 0)
        }
        let openRoots = Set(openProjectRootsProvider().map(standardizedProjectRoot))
        var seenRepositoryRoots = Set<String>()

        return ListProjectsResult(
            activeProjectRoot: activeRoot,
            projects: roots.compactMap { requestedRoot in
                let root = agentSettings.repositoryRoot(for: requestedRoot) ?? requestedRoot
                let standardizedRoot = standardizedProjectRoot(root)
                guard seenRepositoryRoots.insert(standardizedRoot).inserted else { return nil }
                let repository = ProjectWindowRegistry.shared.repository(for: root)
                let worktrees = repository?.supportsWorktrees == true ? repository?.worktrees.map { worktree in
                    WorktreeInfo(
                        root: worktree.root,
                        branch: worktree.branch,
                        head: worktree.head,
                        main: worktree.isMain,
                        detached: worktree.isDetached,
                        locked: worktree.lockReason != nil,
                        hidden: repository?.hiddenWorktreeRoots.contains(worktree.root) ?? false,
                        loaded: repository?.loadedWorktreeRoots.contains(worktree.root) ?? false,
                        active: repository?.activeWorktreeRoot == worktree.root
                    )
                } ?? [] : []
                let isOpen = openRoots.contains(standardizedRoot)
                    || worktrees.contains { openRoots.contains(standardizedProjectRoot($0.root)) }
                let activeWorktreeRoot = repository?.supportsWorktrees == true
                    ? repository?.activeWorktreeRoot
                    : nil
                return ProjectInfo(
                    root: root,
                    name: URL(fileURLWithPath: root, isDirectory: true).lastPathComponent,
                    active: standardizedRoot == activeRepositoryRoot.map(standardizedProjectRoot),
                    open: isOpen,
                    features: projectFeatureAvailability(for: root),
                    worktrees: worktrees,
                    activeWorktreeRoot: activeWorktreeRoot
                )
            }
        )
    }

    @MainActor
    private func openProject(
        _ request: OpenProjectRequest,
        fallbackWorkspace workspace: TerminalWorkspace
    ) throws -> OpenProjectResult {
        if Self.remoteDevice != nil { throw Self.refusedOutsideDevice("that project") }
        let requestedRoot = standardizedProjectRoot(request.projectRoot)
        let candidateRoots = agentSettings.projects.map(\.root)
            + openProjectRootsProvider()
            + ProjectWindowRegistry.shared.knownProjectRoots
            + [workspace.projectRoot].compactMap { $0 }
        guard let projectRoot = candidateRoots.first(where: { standardizedProjectRoot($0) == requestedRoot }) else {
            throw CherryControlError(
                code: "project_not_found",
                message: "Cherry project is not configured: \(request.projectRoot)."
            )
        }

        let openRoots = Set(openProjectRootsProvider().map(standardizedProjectRoot))
        let alreadyOpen = openRoots.contains(standardizedProjectRoot(projectRoot))
        openProjectProvider(projectRoot)

        return OpenProjectResult(projectRoot: projectRoot, alreadyOpen: alreadyOpen)
    }

    @MainActor
    private func projectStatus(workspace: TerminalWorkspace) -> ProjectStatusResult {
        let selectedSession = callerSelectedSession(workspace)
        let noteStore = try? activeNoteStore(for: workspace)
        let todoStore = try? activeTodoStore(for: workspace)
        let features = projectFeatureAvailability(for: workspace.projectRoot)
        return ProjectStatusResult(
            projectRoot: workspace.projectRoot,
            processCounts: processCounts(workspace: workspace),
            noteCount: noteStore?.notes.count,
            todoCount: todoStore?.todos.count,
            features: features,
            selectedProcessID: selectedSession?.id.uuidString,
            selectedProcessName: selectedSession.map(processName),
            health: workspace.projectRoot == nil ? "no_project" : "ok"
        )
    }

    @MainActor
    private func performanceStatus(workspace: TerminalWorkspace) -> PerformanceStatusResult {
        let counters = TerminalPerformanceMonitor.snapshot()
        return PerformanceStatusResult(
            activeProjectRoot: workspace.projectRoot,
            processCounts: processCounts(workspace: workspace),
            selectedProcessID: callerSelectedSession(workspace)?.id.uuidString,
            ghosttyLiveBridgeCount: GhosttySessionBridge.liveBridgeCount,
            ghosttyInstalledOutputObserverCount: GhosttySessionBridge.installedOutputObserverCount,
            rawOutputObserverCount: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputObserverCount },
            rawOutputRetainedBytes: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputRetainedByteCount },
            rawOutputRetainedChunkCount: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputRetainedChunkCount },
            terminalPerfEnabled: TerminalPerformanceMonitor.isEnabled,
            terminalPerfCounters: TerminalPerformanceCounters(
                ptyChunks: counters.ptyChunks,
                ptyBytes: counters.ptyBytes,
                ghosttyFeedChunks: counters.ghosttyFeedChunks,
                ghosttyFeedBytes: counters.ghosttyFeedBytes,
                processorBacklogDropCount: counters.processorBacklogDropCount,
                processorBacklogDroppedBytes: counters.processorBacklogDroppedBytes,
                backgroundOutputThrottleCount: counters.backgroundOutputThrottleCount,
                processorChanges: counters.processorChanges,
                representableUpdates: counters.representableUpdates,
                containerConfigures: counters.containerConfigures,
                bridgeAttaches: counters.bridgeAttaches,
                reusedBridgeAttaches: counters.reusedBridgeAttaches,
                fitToSizeCalls: counters.fitToSizeCalls,
                settingsApplies: counters.settingsApplies,
                settingsReconfigures: counters.settingsReconfigures,
                renderTicks: counters.renderTicks
            )
        )
    }

    @MainActor
    private func processCounts(workspace: TerminalWorkspace) -> ProcessCounts {
        guard Self.remoteDevice != nil else {
            return ProcessCounts(
                total: workspace.sessions.count,
                terminals: workspace.terminalSessions.count,
                agents: workspace.agentSessions.count,
                commands: workspace.commandSessions.count
            )
        }
        let reachable = callerSessions(workspace)
        return ProcessCounts(
            total: reachable.count,
            terminals: workspace.terminalSessions.filter { callerReaches($0, in: workspace) }.count,
            agents: workspace.agentSessions.filter { callerReaches($0, in: workspace) }.count,
            commands: workspace.commandSessions.filter { callerReaches($0, in: workspace) }.count
        )
    }

    @MainActor
    private func listProcesses(workspace: TerminalWorkspace, kind requestedKind: String?) throws -> ListProcessesResult {
        let kind = try processKind(from: requestedKind)
        let sessions = callerSessions(workspace).filter { session in
            guard let kind else { return true }
            return session.kind == kind
        }
        return ListProcessesResult(
            activeProjectRoot: workspace.projectRoot,
            processes: sessions.map { processInfo(for: $0, workspace: workspace) },
            selectedProcessID: callerSelectedSession(workspace)?.id.uuidString
        )
    }

    @MainActor
    private func processInfo(for session: TerminalSession, workspace: TerminalWorkspace) -> ProcessSummary {
        // The worker's task, when it has one the caller may see (made from
        // the caller's Mac).
        let task = tasks.latestTask(forWorker: session.id).flatMap { $0.device == Self.remoteDevice ? $0 : nil }
        return ProcessSummary(
            id: session.id.uuidString,
            link: link(for: session, workspace: workspace),
            name: processName(for: session),
            kind: session.kind.rawValue,
            state: session.programStateLabel,
            pid: session.programProcessID,
            startedAt: session.startedAt,
            exitedAt: session.exitedAt,
            lastOutputAt: session.lastOutputAt,
            acceptsInput: session.acceptsControlInput,
            exitCode: session.exitCode,
            restartPolicy: session.restartPolicy,
            workingDirectory: session.workingDirectory,
            commandLine: session.kind == .terminal ? nil : session.subtitle,
            // Cheap, non-refreshing line count: process listings are polled
            // frequently, and `lineCount` would re-read the surface + run agent
            // hooks per session, saturating the main actor (list_processes timeouts).
            lineCount: session.listingLineCount,
            outputVersion: session.outputVersion,
            summary: nil,
            selected: workspace.selectedSessionID == session.id,
            agentName: session.agentName,
            commandName: session.commandName,
            parentAgentID: session.parentAgentID?.uuidString,
            childAgentCount: callerChildAgentCount(of: session, in: workspace),
            agentActivityState: reportedAgentActivityState(of: session),
            usesAlternateScreen: session.usesAlternateScreen,
            lastContentChangeAt: session.lastContentChangeAt,
            contentVersion: session.contentVersion,
            failureMessage: session.state.failureMessage,
            agentTurn: session.kind == .agent ? session.agentTurnCount : nil,
            agentTurnState: session.kind == .agent ? session.agentTurnState.rawValue : nil,
            taskID: task?.id,
            taskState: task?.state.rawValue,
            runID: task?.runID,
            phase: task?.phase,
            label: task?.label,
            resultSummary: task?.result?.summary
        )
    }

    /// An agent's activity state as MCP reports it: `permission` also
    /// while its screen shows a permission prompt the tab heard no
    /// notification for (a restored agent: the notification came before
    /// Cherry quit), so it is never reported idle while it waits for one.
    /// `needs_input` while its screen shows a question menu
    /// (`AgentQuestionPrompt`): the turn waits on the user's answer.
    @MainActor
    func reportedAgentActivityState(of session: TerminalSession) -> String? {
        guard session.kind == .agent else { return nil }
        if session.isRunning, session.agentActivityState != .error, session.agentActivityState != .permission {
            // The recognizers the app's own state uses
            // (`TerminalSession.applyAgentAnswerMenu`), read now.
            switch AgentScreenActivity.answerMenu(in: session.cachedScreenTailLines) {
            case .permission?: return AgentActivityState.permission.rawValue
            case .question?: return AgentActivityState.needsInput.rawValue
            case nil: break
            }
        }
        return session.agentActivityState.rawValue
    }

    /// How long after a message an agent that never looked busy may be
    /// taken as done: a CLI shows its composer until its first working
    /// frame, and one Cherry cannot read never shows one.
    static let agentTurnStartGrace: TimeInterval = 4

    /// Whether the agent's latest submitted turn showed it started: it was
    /// at work when the message was sent (the CLI queued it behind that
    /// turn), or showed working evidence since. Nil when Cherry saw no turn
    /// submitted, or cannot read the agent's CLI (its screen showed no
    /// composer, marker or spinner before the message): its output going
    /// quiet is all there is.
    @MainActor
    static func agentTurnStarted(_ session: TerminalSession) -> Bool? {
        guard session.kind == .agent, let submittedAt = session.lastAgentSubmitAt,
              session.agentWasReadableAtLastSubmit
        else { return nil }
        if session.agentWasWorkingAtLastSubmit { return true }
        if let evidence = session.lastStrongWorkingEvidenceAt, evidence >= submittedAt { return true }
        return false
    }

    /// Whether an idle-looking agent may be taken as done with its latest
    /// turn: the turn started, or the start grace passed without it.
    @MainActor
    static func agentTurnMayHaveEnded(_ session: TerminalSession, now: Date) -> Bool {
        guard agentTurnStarted(session) == false, let submittedAt = session.lastAgentSubmitAt else { return true }
        return now.timeIntervalSince(submittedAt) >= agentTurnStartGrace
    }

    /// Whether `session` is still a tab of an open window (a wait or a
    /// monitor ends for a closed one).
    @MainActor
    func isOpen(_ session: TerminalSession, in workspace: TerminalWorkspace) -> Bool {
        if workspace.sessions.contains(where: { $0 === session }) { return true }
        return ProjectWindowRegistry.shared.workspacesByProjectRoot().contains { _, other in
            other.sessions.contains { $0 === session }
        }
    }

    @MainActor
    func processName(for session: TerminalSession) -> String {
        session.commandName?.nilIfEmpty ?? session.agentName?.nilIfEmpty ?? session.title
    }

    @MainActor
    private func resolveProcess(
        workspace: TerminalWorkspace,
        processID: String?,
        processName: String?
    ) throws -> TerminalSession {
        try resolveProcessWithWorkspace(workspace: workspace, processID: processID, processName: processName).session
    }

    @MainActor
    func resolveProcessWithWorkspace(
        workspace: TerminalWorkspace,
        processID: String?,
        processName: String?
    ) throws -> (session: TerminalSession, workspace: TerminalWorkspace) {
        if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty {
            let resolved = try findSessionWithWorkspace(workspace: workspace, terminalID: processID)
            let session = resolved.session
            mcpControlDebugLog("resolved process selector=id:\(processID) session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(self.processName(for: session))")
            return resolved
        }

        guard let requestedName = processName?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedName.isEmpty else {
            throw CherryControlError(code: "missing_process_selector", message: "Provide process_id or process_name.")
        }

        let normalizedName = AgentToolDefinition.normalizedName(requestedName)
        let matches = callerSessions(workspace).filter { session in
            self.processName(for: session).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
                || session.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }
        guard let session = matches.first else {
            throw CherryControlError(code: "process_not_found", message: "No Cherry process exists with name \(requestedName).")
        }
        guard matches.count == 1 else {
            throw CherryControlError(code: "ambiguous_process_name", message: "Multiple Cherry processes match name \(requestedName); use process_id.")
        }
        mcpControlDebugLog("resolved process selector=name:\(requestedName) session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(self.processName(for: session))")
        return (session, workspace)
    }

    @MainActor
    private func spawnProcess(_ request: SpawnProcessRequest, workspace: TerminalWorkspace) async throws -> (TerminalSession, Int) {
        let kind = try requiredProcessKind(from: request.kind)
        let session: TerminalSession
        let agent: AgentToolDefinition?
        // A task's worker (`spawn_agent` with `task`): its kickoff line is
        // the agent's first input.
        var task: AgentTask?
        if kind != .agent, request.task != nil {
            throw CherryControlError(code: "invalid_process_request", message: "Only agent processes take a task.")
        }
        switch kind {
        case .terminal:
            guard request.name == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Terminal processes do not use name; pass title instead.")
            }
            guard request.model == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Model overrides are only valid for agent processes.")
            }
            session = workspace.addSession(title: request.title, workingDirectory: request.workingDirectory, select: false)
            agent = nil
        case .agent:
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let resolvedAgent = try findAgent(named: request.name ?? "")
            guard resolvedAgent.isLaunchable else {
                throw CherryControlError(code: "agent_not_launchable", message: "Agent '\(resolvedAgent.name)' is not launchable.")
            }
            let agentDefinition = try agentDefinition(resolvedAgent.definition, overridingModel: request.model)
            let parentID = try parentAgentID(from: request.parentAgentID, workspace: workspace)
            // Checked (its schema too) before anything is spawned.
            let taskPlan = try prepareTaskSpawn(request, parentAgentID: parentID, workspace: workspace)
            session = workspace.addAgentSession(
                agent: agentDefinition,
                projectRoot: projectRoot,
                title: request.title ?? taskPlan?.label,
                parentAgentID: parentID,
                select: false
            )
            if let taskPlan {
                task = registerTask(taskPlan, worker: session, workspace: workspace)
            }
            agent = agentDefinition
        case .command:
            guard request.model == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Model overrides are only valid for agent processes.")
            }
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let command = try findProjectCommand(named: request.name ?? "", projectRoot: projectRoot)
            // A restore under way may bring back this command's tab: use it
            // rather than start a second copy.
            await workspace.waitUntilRestored(commandNamed: command.name)
            session = workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
            agent = nil
        }

        mcpControlDebugLog("spawned process session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(processName(for: session)) parent=\(session.parentAgentID?.uuidString ?? "nil") submit=\(String(describing: request.submit))")

        let text = task?.kickoffLine ?? request.text
        let submit = task != nil ? true : request.submit
        if (text != nil || request.rawBase64 != nil || submit == true), let agent {
            await waitForAgentInitialInputReadiness(session: session, agent: agent)
        }

        let sentBytes: Int
        if session.kind == .agent, let agent {
            let input = try agentInputPayload(
                text: text,
                rawBase64: request.rawBase64,
                submit: submit,
                keyboardProtocolFlags: session.keyboardProtocolFlags
            )
            var inputError: CherryControlError?
            let typedSince = Date()
            if let input, !input.isEmpty {
                // A task's kickoff goes under the tab's typing lock, as
                // every line Cherry types (`typeCherryLine`).
                let typingLock = task != nil ? tasks.typingLocks : nil
                await typingLock?.acquire(session.id)
                // The process exists either way: sentBytes says whether its
                // first input reached it.
                do {
                    sentBytes = try await sendInitialAgentInput(input, to: session, agent: agent)
                } catch {
                    mcpControlDebugLog("agent initial input not delivered session=\(session.id.uuidString): \(error)")
                    inputError = error as? CherryControlError
                    sentBytes = 0
                }
                typingLock?.release(session.id)
            } else {
                sentBytes = 0
            }
            if let task {
                noteKickoff(task, delivered: sentBytes > 0, error: inputError, typedSince: typedSince)
            }
        } else {
            let input = try optionalTerminalInputPayload(text: request.text, rawBase64: request.rawBase64, for: session)
            if let input, !input.payload.isEmpty {
                do {
                    try await sendTerminalInput(input, to: session)
                    sentBytes = input.payload.count
                } catch {
                    mcpControlDebugLog("initial input not delivered session=\(session.id.uuidString): \(error)")
                    sentBytes = 0
                }
            } else {
                sentBytes = 0
            }
        }
        return (session, sentBytes)
    }

    private func agentDefinition(
        _ agent: AgentToolDefinition,
        overridingModel requestedModel: String?
    ) throws -> AgentToolDefinition {
        guard let requestedModel else { return agent }

        let model = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw CherryControlError(code: "invalid_model", message: "Model override cannot be empty.")
        }

        let brand = AgentToolBrand.detect(name: nil, commandLine: agent.commandLine)
            ?? AgentToolBrand.detect(name: agent.name)
        guard let brand, brand.modelFlag != nil else {
            throw CherryControlError(
                code: "unsupported_model_override",
                message: "Agent '\(agent.name)' does not support per-launch model overrides."
            )
        }
        return agent.overridingModel(model, for: brand)
    }

    @MainActor
    private func startProcess(_ request: ProcessLifecycleRequest, workspace: TerminalWorkspace) async throws -> TerminalSession {
        // A restore under way may bring back the named command's tab: wait
        // for it instead of starting a second copy.
        if let name = request.processName, workspace.isRestoringCommand(named: name),
           (try? resolveProcess(workspace: workspace, processID: request.processID, processName: name)) == nil {
            await workspace.waitUntilRestored(commandNamed: name)
        }
        if let session = try? resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName) {
            try rejectEndedHostedSession(session)
            switch session.state {
            case .launching, .live:
                return session
            case .disconnected:
                session.reconnectHostedSession()
                return session
            case .exited, .failed:
                if session.hostedAttachment != nil {
                    // A failed attach; an ended session was rejected above.
                    session.reconnectHostedSession()
                } else if session.kind == .command {
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
    ) async throws -> ServicesResult {
        let records = try await detectedServices(
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
        includeUnattributed: Bool,
        forwardingRemotePorts: Bool = false
    ) async throws -> [ServiceRecord] {
        func inspectable(_ session: TerminalSession, rootPID: Int32?) -> InspectableProcess {
            InspectableProcess(
                id: session.id.uuidString,
                name: processName(for: session),
                kind: session.kind.rawValue,
                rootPID: rootPID,
                commandName: session.commandName,
                agentName: session.agentName
            )
        }
        // A caller on another Mac never runs This Mac's scan (lsof): not
        // of every listener (`include_unattributed`), nor of its tabs.
        let remoteCaller = Self.remoteDevice != nil
        if remoteCaller, includeUnattributed { throw Self.unattributedNotAvailable }
        // Tabs of other Macs: their Mac says which ports their programs
        // listen on, and the ports are forwarded here (never a local pid).
        let onOtherMacs = sessions.filter { $0.persistentHosting?.profile.isThisMac == false }
        let local = remoteCaller ? [] : sessions.filter { $0.persistentHosting?.profile.isThisMac != false }
        let remote: [RemoteInspectableProcess] = onOtherMacs.compactMap { session in
            guard let hosting = session.persistentHosting, let pid = session.remoteProgramProcessID else { return nil }
            return RemoteInspectableProcess(
                process: inspectable(session, rootPID: nil),
                tabID: session.id,
                host: hosting.profile.host,
                machine: hosting.profile.displayName,
                remotePID: pid
            )
        }
        var records: [ServiceRecord] = []
        if !local.isEmpty || includeUnattributed {
            records = try await serviceDetector.detectServices(
                processes: local.map { inspectable($0, rootPID: $0.programProcessID) },
                includeUnattributed: includeUnattributed
            )
        }
        if !remote.isEmpty {
            do {
                records += try await remoteServiceDetector.detectServices(processes: remote, forwarding: forwardingRemotePorts)
            } catch where !local.isEmpty || includeUnattributed {
                // This Mac's services are still worth reporting.
                SessionLog.error("services of tabs of other Macs: \(error.localizedDescription)")
            }
        }
        return records
    }

    static let unattributedNotAvailable = CherryControlError(
        code: "unattributed_not_available",
        message: "include_unattributed lists every listening port of the Mac Cherry runs on, which a caller on another Mac cannot see. Leave it off: the ports of this Mac's own processes are listed without it."
    )

    @MainActor
    private func waitForBoundPort(_ request: WaitForBoundPortRequest, workspace: TerminalWorkspace) async throws -> ServiceRecord {
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(request.timeoutMilliseconds ?? 10_000, 1), 60_000)) / 1_000)
        let includeUnattributed = request.includeUnattributed ?? false
        if Self.remoteDevice != nil, includeUnattributed { throw Self.unattributedNotAvailable }
        let sessions: [TerminalSession]
        if request.processID != nil || request.processName != nil {
            sessions = [try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)]
        } else {
            sessions = callerSessions(workspace)
        }

        var lastCandidates: [ServiceRecord] = []
        repeat {
            // Probing a service of another Mac over HTTP needs it here:
            // only then is its port forwarded.
            let candidates = try await detectedServices(
                workspace: workspace,
                sessions: sessions,
                includeUnattributed: includeUnattributed,
                forwardingRemotePorts: request.probeHTTP ?? false
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

    @MainActor
    private func waitForProcessIdle(
        _ request: WaitForProcessIdleRequest,
        workspace: TerminalWorkspace
    ) async throws -> WaitForProcessIdleResult {
        let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
        let timeoutMilliseconds = min(max(request.timeoutMilliseconds ?? CherryControl.defaultWaitMilliseconds, 1), 300_000)
        let quietMilliseconds = min(max(request.quietMilliseconds ?? 1_000, 0), timeoutMilliseconds)
        let requireNewOutput = request.requireNewOutput ?? true
        let sinceOutputVersion = request.sinceOutputVersion
            ?? session.lastInputOutputVersion
            ?? session.outputVersion
        // Headless native surfaces do not necessarily emit render callbacks, so
        // pull their text before and during the wait. `lineCount` is the
        // throttled data-layer refresh point for a single selected process
        // (the host's screen, for a persistent tab whose surface does not
        // show its program now).
        await session.refreshContentFromHostIfNeeded()
        _ = session.lineCount
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
        let startedAt = Date()
        var observedNewOutput = ProcessIdleDetector.observedNewOutput(
            currentOutputVersion: session.outputVersion,
            sinceOutputVersion: sinceOutputVersion
        )

        func result(reason: ProcessIdleWaitReason) async -> WaitForProcessIdleResult {
            // The loop read only the host's last lines: the output (and its
            // line numbers) comes from the whole history.
            await session.refreshContentFromHostIfNeeded()
            let output = terminalOutput(for: session, startLine: nil, lineLimit: request.lineLimit)
            return WaitForProcessIdleResult(
                process: processInfo(for: session, workspace: sessionWorkspace),
                reason: reason,
                observedNewOutput: observedNewOutput,
                sinceOutputVersion: sinceOutputVersion,
                outputVersion: session.outputVersion,
                lastOutputAt: session.lastOutputAt,
                agentActivityState: reportedAgentActivityState(of: session),
                output: output,
                agentTurn: session.kind == .agent ? session.agentTurnCount : nil,
                turnStarted: Self.agentTurnStarted(session)
            )
        }

        while true {
            // A program that ended reports its exit even when its tab then
            // closed (a terminal whose shell exited 0): only a tab closed
            // while its program ran is `closed`.
            if !session.state.hasEnded, !isOpen(session, in: sessionWorkspace) {
                return await result(reason: .closed)
            }
            // Polls every 50 ms; the host's screen (its last lines only) is
            // read at most once per `hostContentPollInterval`.
            await session.refreshContentFromHostIfNeeded(maximumAge: session.hostContentPollInterval, recentOnly: true)
            _ = session.lineCount
            observedNewOutput = observedNewOutput || ProcessIdleDetector.observedNewOutput(
                currentOutputVersion: session.outputVersion,
                sinceOutputVersion: sinceOutputVersion
            )

            switch session.state {
            case .exited, .failed:
                return await result(reason: .exited)
            case .disconnected where session.isPersistentLocalSession && session.isRunning:
                // Only the attach adapter reconnects: the program runs, and
                // its screen comes from the host meanwhile.
                break
            case .disconnected:
                return await result(reason: .disconnected)
            case .launching, .live:
                break
            }

            let now = Date()
            if session.kind == .agent, session.isRunning, session.agentActivityState != .error,
               AgentPermissionPrompt.isShowing(in: session.cachedScreenTailLines) {
                // Its screen asks for permission (a restored agent's state
                // never heard the notification that said so).
                return await result(reason: .permission)
            }
            if session.kind == .agent, session.isRunning, session.agentActivityState != .error,
               session.agentActivityState != .permission,
               AgentQuestionPrompt.isShowing(in: session.cachedScreenTailLines) {
                // It asks the user a question: its turn cannot end before
                // someone answers.
                return await result(reason: .needsInput)
            }
            if session.kind == .agent, session.agentActivityState != .unknown {
                let quietInterval = TimeInterval(quietMilliseconds) / 1_000
                let contentQuietSince = session.lastContentChangeAt ?? startedAt
                let contentIsQuiet = (!requireNewOutput || observedNewOutput)
                    && now.timeIntervalSince(contentQuietSince) >= quietInterval

                switch session.agentActivityState {
                case .permission:
                    return await result(reason: .permission)
                case .needsInput:
                    return await result(reason: .needsInput)
                case .error:
                    return await result(reason: .agentError)
                case .idle:
                    // The composer shows before a just-submitted turn's
                    // first working frame: idle counts once the turn
                    // started, or after the start grace.
                    if contentIsQuiet, Self.agentTurnMayHaveEnded(session, now: now) {
                        return await result(reason: .idle)
                    }
                case .working, .unknown:
                    // Agents without recognizable prompt/working UI never reach
                    // .idle on their own; fall back to the content-quiet window
                    // unless a provider-specific working signal is active.
                    if !session.agentActivityEvidenceIsStrong, contentIsQuiet,
                       Self.agentTurnMayHaveEnded(session, now: now) {
                        return await result(reason: .idle)
                    }
                }
            } else if let commandFinishedAt = session.lastNativeCommandFinishedAt,
                      commandFinishedAt >= startedAt,
                      !requireNewOutput || observedNewOutput {
                // Native OSC 133: a command boundary is a precise "back at prompt"
                // signal for plain scripts/commands — no quiet-period guessing.
                return await result(reason: .idle)
            } else if ProcessIdleDetector.isQuiet(
                now: now,
                lastOutputAt: session.lastOutputAt,
                startedAt: startedAt,
                quietMilliseconds: quietMilliseconds,
                requireNewOutput: requireNewOutput,
                observedNewOutput: observedNewOutput
            ) {
                return await result(reason: .idle)
            }

            if now >= deadline {
                return await result(reason: .timedOut)
            }

            let remainingMilliseconds = max(1, Int(deadline.timeIntervalSince(now) * 1_000))
            try? await Task.sleep(for: .milliseconds(min(50, remainingMilliseconds)))
        }
    }

    /// Where an HTTP probe of `service` goes: its URL here. A service of
    /// another Mac is probed only through its forward (`forwardedFrom`):
    /// without one its `url` is the address there, which here would be
    /// This Mac's own localhost.
    static func probeURL(for service: ServiceRecord, path requestedPath: String?) -> URL? {
        if service.machine != nil, service.forwardedFrom == nil { return nil }
        let path = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "/"
        guard var components = URLComponents(string: service.url) else { return nil }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    private func httpReadiness(for service: ServiceRecord, path requestedPath: String?) async -> ServiceReadiness {
        guard let url = Self.probeURL(for: service, path: requestedPath) else {
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
        // A tab attached from Persistent Sessions is a terminal: stopping it
        // ends only the local attach client, so it reports `disconnected`
        // and its program keeps running. A persistent local tab's session
        // ends on its host, as a native tab's process does.
        if session.kind == .command {
            session.stopManagedCommand()
        } else {
            session.stopProgram()
        }
    }

    /// A hosted session that ended on its host cannot be started again; a
    /// silent no-op would leave the caller waiting on an exited process.
    @MainActor
    private func rejectEndedHostedSession(_ session: TerminalSession) throws {
        guard session.hostedAttachment != nil, session.hostedSessionEnded else { return }
        throw CherryControlError(
            code: "hosted_session_ended",
            message: "Persistent session '\(session.title)' ended on its host and cannot be restarted. Create a new session instead."
        )
    }

    @MainActor
    func closeFromControl(
        _ session: TerminalSession,
        workspace: TerminalWorkspace,
        agentClosePolicy: AgentClosePolicy?
    ) throws {
        let descendants = workspace.descendantAgentSessions(of: session)
        // A caller on another Mac closes or re-parents only its Mac's tabs.
        guard descendants.allSatisfy({ callerReaches($0, in: workspace) }) else {
            throw Self.refusedOutsideDevice("one of that agent's sub-agents")
        }
        guard !descendants.isEmpty else {
            guard workspace.sessions.count > 1 else {
                throw CherryControlError(code: "last_process", message: "Cherry cannot close the last remaining process.")
            }
            workspace.close(session, intent: .mcpClose)
            return
        }

        switch agentClosePolicy ?? .reject {
        case .reject:
            throw CherryControlError(
                code: "agent_has_sub_agents",
                message: "Agent '\(session.title)' has sub-agents. Pass agent_close_policy as close_sub_agents or promote_sub_agents."
            )
        case .closeSubAgents:
            guard workspace.sessions.count > descendants.count + 1 else {
                throw CherryControlError(code: "last_process", message: "Cherry cannot close the last remaining process.")
            }
            workspace.closeAgentGroup(session, intent: .mcpClose)
        case .promoteSubAgents:
            workspace.closeAgentPromotingChildren(session, intent: .mcpClose)
        }
    }

    @MainActor
    private func restartProcess(_ session: TerminalSession, in workspace: TerminalWorkspace) throws {
        // Restarting a hosted tab reconnects its attach client. A connected
        // tab may learn that its session ended only when restart() stops the
        // adapter and reads the outcome it wrote.
        try rejectEndedHostedSession(session)
        if !workspace.restart(session) {
            try rejectEndedHostedSession(session)
        }
    }

    @MainActor
    private func parentAgentID(from rawValue: String?, workspace: TerminalWorkspace) throws -> UUID? {
        mcpControlDebugLog("parentAgentID(from:) raw=\(rawValue ?? "nil")")
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        let normalizedValue = rawValue.lowercased()
        if normalizedValue == CherryControl.topLevelAgentParentID
            || normalizedValue == "root"
            || normalizedValue == "none" {
            return nil
        }
        if normalizedValue == CherryControl.selectedAgentParentID
            || normalizedValue == "current" {
            let parentID = selectedAgentParentID(workspace: workspace)
            mcpControlDebugLog("resolved parent_agent_id=\(rawValue) parent=\(parentID?.uuidString ?? "nil")")
            return parentID
        }
        guard let parentID = UUID(uuidString: rawValue) else {
            throw CherryControlError(code: "invalid_parent_agent_id", message: "parent_agent_id must be a Cherry agent UUID.")
        }
        guard let parent = callerSessions(workspace).first(where: { $0.id == parentID }) else {
            throw CherryControlError(code: "parent_agent_not_found", message: "No Cherry agent exists with parent_agent_id \(rawValue).")
        }
        guard parent.kind == .agent else {
            throw CherryControlError(code: "parent_agent_not_agent", message: "parent_agent_id must refer to an agent session.")
        }
        mcpControlDebugLog("resolved parent_agent_id=\(rawValue) parent=\(parentID.uuidString)")
        return parentID
    }

    @MainActor
    private func selectedAgentParentID(workspace: TerminalWorkspace) -> UUID? {
        if let chromeState = chromeState(for: workspace),
           chromeState.isShowingTerminalContent,
           let selectedSession = callerSelectedSession(workspace),
           selectedSession.kind == .agent {
            return selectedSession.id
        }

        if chromeState(for: workspace) == nil,
           let selectedSession = callerSelectedSession(workspace),
           selectedSession.kind == .agent {
            return selectedSession.id
        }

        return workspace.rootAgentSessions.last { callerReaches($0, in: workspace) }?.id
    }

    @MainActor
    private func startAllCommands(workspace: TerminalWorkspace) async throws -> [TerminalSession] {
        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        // Restored command tabs first: none of their commands starts twice.
        await workspace.waitUntilRestored(commandNamed: nil)
        return agentSettings.launchableProjectCommands(for: projectRoot).map {
            workspace.addCommandSession(command: $0, projectRoot: projectRoot, select: false)
        }
    }

    @MainActor
    private func restartAllCommands(workspace: TerminalWorkspace) async throws {
        let sessions = try await startAllCommands(workspace: workspace)
        for session in sessions where callerReaches(session, in: workspace) {
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
        try findSessionWithWorkspace(workspace: workspace, terminalID: terminalID).session
    }

    // Terminal UUIDs are globally unique, but a request's scope only selects the
    // DEFAULT workspace. Orchestrators hold on to process IDs across window
    // switches, so ID lookups must search every open project window before
    // failing — otherwise agents in a background window become unreachable the
    // moment the user focuses a different project.
    @MainActor
    func findSessionWithWorkspace(
        workspace: TerminalWorkspace,
        terminalID: String
    ) throws -> (session: TerminalSession, workspace: TerminalWorkspace) {
        // A caller on another Mac finds only its Mac's sessions.
        // Only sessions running on its Mac (`isSession(_:in:onDevice:)`):
        // never a This Mac or other host's session attached into its
        // Mac's window.
        let device = Self.remoteDevice
        if let session = workspace.session(id: terminalID),
           device.map({ Self.isSession(session, in: workspace, onDevice: $0) }) ?? true {
            return (session, workspace)
        }
        for (_, openWorkspace) in ProjectWindowRegistry.shared.workspacesByProjectRoot()
        where openWorkspace !== workspace && (device.map { Self.isOnDevice(openWorkspace.projectRoot, $0) } ?? true) {
            if let session = openWorkspace.session(id: terminalID),
               device.map({ Self.isSession(session, in: openWorkspace, onDevice: $0) }) ?? true {
                return (session, openWorkspace)
            }
        }
        throw CherryControlError(code: "terminal_not_found", message: "No Cherry terminal exists with id \(terminalID).")
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
            summary: nil,
            parentAgentID: session.parentAgentID?.uuidString,
            childAgentCount: callerChildAgentCount(of: session, in: workspace)
        )
    }

    private struct TerminalControlInput {
        let payload: Data
        let isRaw: Bool
    }

    @MainActor
    private func terminalInputPayload(from request: SendInputRequest, for session: TerminalSession) throws -> TerminalControlInput {
        try terminalInputPayload(text: request.text, rawBase64: request.rawBase64, for: session)
    }

    @MainActor
    private func terminalInputPayload(text: String?, rawBase64: String?, for session: TerminalSession) throws -> TerminalControlInput {
        switch (text, rawBase64) {
        case let (text?, nil):
            return .init(
                payload: TerminalInputEncoder.terminalTextData(
                    text,
                    keyboardProtocolFlags: session.keyboardProtocolFlags
                ),
                isRaw: false
            )
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            return .init(payload: data, isRaw: true)
        default:
            throw CherryControlError(code: "invalid_input", message: "Provide exactly one of text or raw_base64.")
        }
    }

    @MainActor
    private func optionalTerminalInputPayload(text: String?, rawBase64: String?, for session: TerminalSession) throws -> TerminalControlInput? {
        switch (text, rawBase64) {
        case let (text?, nil):
            return .init(
                payload: TerminalInputEncoder.terminalTextData(
                    text,
                    keyboardProtocolFlags: session.keyboardProtocolFlags
                ),
                isRaw: false
            )
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            return .init(payload: data, isRaw: true)
        case (nil, nil):
            return nil
        case (_?, _?):
            throw CherryControlError(code: "invalid_input", message: "Provide at most one of text or raw_base64.")
        }
    }

    /// Sends input and says whether it reached the program: throws, having
    /// sent nothing, when the process takes no input (it ended, or an
    /// attached session is disconnected) or its host did not take it. Input
    /// for a persistent tab whose session is being created is queued, and
    /// counts as sent.
    @MainActor
    private func sendTerminalInput(_ input: TerminalControlInput, to session: TerminalSession) async throws {
        try await deliver(input.payload, raw: input.isRaw, to: session)
    }

    /// `alreadySent`: bytes of the same input delivered before this part
    /// (an agent message whose Enter is sent after its text). When this
    /// part fails, the error then says the text was typed but not
    /// submitted (`input_partially_delivered`) instead of "nothing was sent".
    /// Input the host typed only a first part of (longer than one host
    /// request, 64 KiB, and a later request failed) is
    /// `input_partially_delivered` too, with the bytes that were typed.
    @MainActor
    private func deliver(_ data: Data, raw: Bool, to session: TerminalSession, alreadySent: Int = 0) async throws {
        do {
            try await session.sendControlInput(data, raw: raw)
        } catch let error as TerminalSession.ControlInputError {
            throw Self.inputError(
                for: error, processName: processName(for: session), totalBytes: data.count, alreadySent: alreadySent
            )
        }
    }

    /// The MCP error for input `sendControlInput` did not (all) deliver.
    /// `totalBytes`: what this part sent; `alreadySent`: bytes of the same
    /// input delivered before it (an agent message's text, before its Enter).
    static func inputError(
        for error: TerminalSession.ControlInputError,
        processName name: String,
        totalBytes: Int,
        alreadySent: Int = 0
    ) -> CherryControlError {
        switch error {
        case .partiallyDelivered(let deliveredBytes, let reason, let unconfirmedBytes):
            let delivered = alreadySent + deliveredBytes
            let total = alreadySent + totalBytes
            let advice = "Check its output before sending what is missing: "
                + "sending all of it again would type the first \(delivered) bytes twice."
            guard unconfirmedBytes > 0 else {
                return CherryControlError(
                    code: "input_partially_delivered",
                    message: "Only the first \(delivered) of \(total) bytes of the input reached the program of process '\(name)'; "
                        + "the rest was not sent: \(reason). " + advice
                )
            }
            // The part that failed was sent, but its answer was lost.
            let rest = total - delivered - unconfirmedBytes
            return CherryControlError(
                code: "input_partially_delivered",
                message: "Only the first \(delivered) of \(total) bytes of the input are known to have reached the program of process '\(name)': \(reason). "
                    + "The \(unconfirmedBytes) bytes after them were sent, but the host's answer was lost, so they may or may not have been typed"
                    + (rest > 0 ? "; the last \(rest) bytes were not sent. " : ". ")
                    + advice
            )
        case .notAccepting(let state) where alreadySent > 0:
            return typedButNotSubmitted(processName: name, alreadySent: alreadySent, reason: "it is \(state) and takes no input")
        case .notDelivered(let reason) where alreadySent > 0:
            return typedButNotSubmitted(processName: name, alreadySent: alreadySent, reason: reason)
        case .notAccepting(let state):
            return CherryControlError(
                code: "process_not_accepting_input",
                message: "Process '\(name)' is \(state) and takes no input; nothing was sent."
            )
        case .notDelivered(let reason):
            return CherryControlError(
                code: "input_not_delivered",
                message: "Input for process '\(name)' did not reach its program; nothing was sent: \(reason)"
            )
        case .maybeDelivered(let reason):
            let what = alreadySent > 0
                ? "The text (\(alreadySent) bytes) was typed into process '\(name)'; the Enter that submits it was sent"
                : "Input for process '\(name)' (\(totalBytes) bytes"
                    + (totalBytes > HostProtocol.maxInputBytes ? ", of which only the first \(HostProtocol.maxInputBytes) were sent" : "")
                    + ") was sent"
            return CherryControlError(
                code: "input_maybe_delivered",
                message: what + ", but its host's answer was lost, so it may or may not have reached the program: \(reason). "
                    + "Check its output before sending it again."
            )
        }
    }

    private static func typedButNotSubmitted(processName name: String, alreadySent: Int, reason: String) -> CherryControlError {
        CherryControlError(
            code: "input_partially_delivered",
            message: "The text (\(alreadySent) bytes) was typed into process '\(name)', but the Enter that submits it did not reach its program: \(reason)"
        )
    }

    @MainActor
    func sendControlInput(
        text: String?,
        rawBase64: String?,
        submit: Bool?,
        to session: TerminalSession
    ) async throws -> Int {
        mcpControlDebugLog("send input session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(processName(for: session)) textBytes=\(text?.utf8.count ?? 0) raw=\(rawBase64 != nil) submit=\(String(describing: submit))")
        if session.kind == .agent {
            await waitForAgentSubmittedInputReadinessIfNeeded(to: session)
            try await refuseInputIntoPermissionPrompt(
                of: session,
                keysOnly: rawBase64 != nil && submit != true
            )
            let input = try agentInputPayload(
                text: text,
                rawBase64: rawBase64,
                submit: submit,
                keyboardProtocolFlags: session.keyboardProtocolFlags
            )
            guard let input, !input.isEmpty else { return 0 }
            return try await sendAgentInput(
                input,
                to: session,
                shouldDeferSubmit: shouldDeferSubmittedInput(for: session),
                source: "message"
            )
        }

        let input = try terminalInputPayload(text: text, rawBase64: rawBase64, for: session)
        try await sendTerminalInput(input, to: session)
        return input.payload.count
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
        await session.refreshContentFromHostIfNeeded()
        return terminalOutput(for: session, startLine: nil, lineLimit: lineLimit)
    }

    private struct AgentInitialInput {
        let payload: Data
        let submit: Bool

        var isEmpty: Bool {
            payload.isEmpty && !submit
        }
    }

    @MainActor
    private func sendInitialAgentInput(
        _ input: AgentInitialInput,
        to session: TerminalSession,
        agent: AgentToolDefinition
    ) async throws -> Int {
        try await refuseInputIntoPermissionPrompt(of: session, keysOnly: false)
        return try await sendAgentInput(
            input,
            to: session,
            shouldDeferSubmit: shouldDeferInitialInput(for: agent),
            source: "initial"
        )
    }

    @MainActor
    private func sendAgentInput(
        _ input: AgentInitialInput,
        to session: TerminalSession,
        shouldDeferSubmit: Bool,
        source: String
    ) async throws -> Int {
        if shouldDeferSubmit, input.submit {
            if !input.payload.isEmpty {
                mcpControlDebugLog("agent \(source) input type session=\(session.id.uuidString) bytes=\(input.payload.count)")
                try await deliver(input.payload, raw: false, to: session)
                try? await Task.sleep(for: .milliseconds(150))
            }
            let enterSequence = TerminalInputEncoder.enterSequence(
                keyboardProtocolFlags: session.keyboardProtocolFlags
            )
            mcpControlDebugLog("agent \(source) input submit session=\(session.id.uuidString) bytes=\(enterSequence.count)")
            try await deliver(enterSequence, raw: false, to: session, alreadySent: input.payload.count)
            return input.payload.count + enterSequence.count
        }

        var payload = input.payload
        if input.submit {
            payload.append(TerminalInputEncoder.enterSequence(
                keyboardProtocolFlags: session.keyboardProtocolFlags
            ))
        }
        guard !payload.isEmpty else { return 0 }
        mcpControlDebugLog("agent \(source) input combined session=\(session.id.uuidString) bytes=\(payload.count) submit=\(input.submit)")
        try await deliver(payload, raw: false, to: session)
        return payload.count
    }

    @MainActor
    private func waitForAgentInitialInputReadiness(
        session: TerminalSession,
        agent: AgentToolDefinition
    ) async {
        guard shouldDeferInitialInput(for: agent) else { return }
        await waitForDeferredAgentInputReadiness(session: session)
    }

    /// The first input to an agent this tab just started waits until the
    /// agent is ready (and gets past its startup prompt). An agent the tab
    /// only follows (restored after a relaunch, adopted, or attached) has
    /// been running for a while: its screen is checked before the input
    /// goes (`refuseInputIntoPermissionPrompt`), and no prompt of it is
    /// ever acknowledged.
    @MainActor
    private func waitForAgentSubmittedInputReadinessIfNeeded(to session: TerminalSession) async {
        guard session.lastInputOutputVersion == nil else { return }
        guard session.startedCurrentProgram else { return }
        guard shouldDeferSubmittedInput(for: session) else { return }
        await waitForDeferredAgentInputReadiness(session: session)
    }

    /// MCP input never answers an agent's permission prompt: Enter (or a
    /// letter such as `y`) typed into one approves the pending command. The
    /// agent's screen is read as it is now (from its host when no surface
    /// shows it, as for a restored agent whose adapter waits), and input
    /// is refused, with nothing sent, while it shows a permission prompt.
    /// Raw keys sent without submit (`keysOnly`) are the caller's own
    /// answer and go through. When the screen cannot be read (its host
    /// does not answer), nothing is sent either.
    @MainActor
    private func refuseInputIntoPermissionPrompt(of session: TerminalSession, keysOnly: Bool) async throws {
        // A tab that takes no input says so when the input is sent.
        guard session.acceptsControlInput else { return }
        let name = processName(for: session)
        guard let lines = await session.programScreenLinesForInput() else {
            throw CherryControlError(
                code: "input_not_delivered",
                message: "Input for agent '\(name)' was not sent: its screen could not be read from its host, so Cherry cannot tell whether it is waiting for a permission answer. Nothing was sent."
            )
        }
        guard !keysOnly else { return }
        if AgentPermissionPrompt.isShowing(in: lines) {
            mcpControlDebugLog("agent input refused at permission prompt session=\(session.id.uuidString)")
            throw CherryControlError(
                code: "agent_awaiting_permission",
                message: "Agent '\(name)' is waiting for an answer to a permission prompt; nothing was sent, so the prompt was not answered. Let the user answer it in Cherry, or send the answering keys deliberately with raw_base64 (without submit)."
            )
        }
        if AgentQuestionPrompt.isShowing(in: lines) {
            // Enter picks the highlighted option of a question menu.
            mcpControlDebugLog("agent input refused at question menu session=\(session.id.uuidString)")
            throw CherryControlError(
                code: "agent_awaiting_input",
                message: "Agent '\(name)' is asking the user a question with a choice menu; nothing was sent, since Enter would pick the highlighted option. Read the question with get_process_output, then let the user answer it, or answer deliberately with raw_base64 keys (without submit), such as the option's digit."
            )
        }
    }

    @MainActor
    private func waitForDeferredAgentInputReadiness(session: TerminalSession) async {
        var startedAt = Date()
        // A session being created holds the wait no longer than this.
        let creationDeadline = startedAt.addingTimeInterval(30)
        let maximumWait: TimeInterval = 6
        let quietInterval: TimeInterval = 0.75
        let noOutputFallback: TimeInterval = 2.5
        let maximumStartupAcknowledgements = 2
        var acknowledgedStartupPromptCount = 0
        var awaitingOutputAfterAcknowledgementVersion: Int?
        var startupPromptSearchStartLine = 0

        while true {
            switch session.state {
            case .disconnected where session.isPersistentLocalSession && session.isRunning:
                // The agent runs; only its attach adapter reconnects.
                break
            case .exited, .failed, .disconnected:
                return
            case .launching, .live:
                break
            }
            if session.isStartingPersistentSession, Date() < creationDeadline {
                // Its host session is still being created (bounded by the
                // tab's creation deadline): the agent has not started, and
                // input sent now is queued until it has.
                startedAt = Date()
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            await session.refreshContentFromHostIfNeeded(maximumAge: session.hostContentPollInterval, recentOnly: true)

            if let outputVersion = awaitingOutputAfterAcknowledgementVersion,
               session.outputVersion > outputVersion {
                awaitingOutputAfterAcknowledgementVersion = nil
            }

            let now = Date()
            let elapsed = now.timeIntervalSince(startedAt)
            if let lastOutputAt = session.lastOutputAt {
                if now.timeIntervalSince(lastOutputAt) >= quietInterval,
                   awaitingOutputAfterAcknowledgementVersion == nil {
                    if acknowledgedStartupPromptCount < maximumStartupAcknowledgements,
                       shouldAcknowledgeAgentStartupPrompt(in: session, startLine: startupPromptSearchStartLine) {
                        acknowledgedStartupPromptCount += 1
                        awaitingOutputAfterAcknowledgementVersion = session.outputVersion
                        startupPromptSearchStartLine = session.lineCount
                        let enterSequence = TerminalInputEncoder.enterSequence(
                            keyboardProtocolFlags: session.keyboardProtocolFlags
                        )
                        mcpControlDebugLog("agent startup prompt acknowledged session=\(session.id.uuidString) bytes=\(enterSequence.count)")
                        // As MCP's other input: through the host while the
                        // attach adapter is not known to be attached.
                        try? await session.sendControlInput(enterSequence, raw: false)
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    return
                }
            } else if elapsed >= noOutputFallback {
                return
            }

            if elapsed >= maximumWait {
                return
            }

            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Only an agent this tab just started can be at its startup prompt;
    /// one it follows may be at a permission prompt that reads alike ("Do
    /// you want to proceed?"), and Enter would approve it. Never a screen
    /// that shows a permission menu either.
    @MainActor
    private func shouldAcknowledgeAgentStartupPrompt(in session: TerminalSession, startLine requestedStartLine: Int) -> Bool {
        guard session.startedCurrentProgram else { return false }
        let lineCount = session.lineCount
        guard lineCount > 0 else { return false }
        let startLine = max(min(max(requestedStartLine, 0), lineCount), lineCount - 20)
        guard startLine < lineCount else { return false }
        let lines = session.snapshot(range: startLine..<lineCount)
        guard !AgentPermissionPrompt.isShowing(in: session.snapshot(range: max(0, lineCount - 60)..<lineCount)) else {
            return false
        }
        return isAgentStartupConfirmationPrompt(lines.joined(separator: "\n"))
    }

    private func isAgentStartupConfirmationPrompt(_ output: String) -> Bool {
        let compactOutput = output
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        let directPhrases = [
            "do you trust",
            "do you want to trust",
            "do you want to continue",
            "do you want to proceed",
            "do you want to run",
            "press enter to continue",
            "press return to continue",
            "trust the files in this folder",
            "trust this folder",
            "trust this directory",
        ]
        if directPhrases.contains(where: { compactOutput.contains($0) }) {
            return true
        }

        return compactOutput.contains("yes, proceed")
            && compactOutput.contains("no")
            && (
                compactOutput.contains("trust")
                    || compactOutput.contains("folder")
                    || compactOutput.contains("directory")
            )
    }

    private func shouldDeferInitialInput(for agent: AgentToolDefinition) -> Bool {
        shouldDeferAgentInput(agentName: agent.name, command: agent.command)
    }

    @MainActor
    private func shouldDeferSubmittedInput(for session: TerminalSession) -> Bool {
        shouldDeferAgentInput(agentName: session.agentName, command: session.subtitle)
    }

    private func shouldDeferAgentInput(agentName: String?, command: String) -> Bool {
        let knownInteractiveAgents: Set<String> = [
            "amp",
            "claude",
            "codex",
            "gemini",
            "opencode",
            "pi",
        ]
        if let agentName, knownInteractiveAgents.contains(AgentToolDefinition.normalizedName(agentName)) {
            return true
        }

        let commandName = URL(fileURLWithPath: firstCommandToken(command))
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return knownInteractiveAgents.contains(commandName)
    }

    private func firstCommandToken(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }

        if first == "\"" || first == "'" {
            let remainder = trimmed.dropFirst()
            if let endIndex = remainder.firstIndex(of: first) {
                return String(remainder[..<endIndex])
            }
            return String(remainder)
        }

        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private func agentInputPayload(
        text: String?,
        rawBase64: String?,
        submit: Bool?,
        keyboardProtocolFlags: Int
    ) throws -> AgentInitialInput? {
        let payload: Data
        let isTextInput: Bool
        switch (text, rawBase64) {
        case let (text?, nil):
            payload = TerminalInputEncoder.terminalTextData(
                text,
                keyboardProtocolFlags: keyboardProtocolFlags
            )
            isTextInput = true
        case let (nil, rawBase64?):
            guard let data = Data(base64Encoded: rawBase64) else {
                throw CherryControlError(code: "invalid_base64", message: "raw_base64 is not valid base64.")
            }
            payload = data
            isTextInput = false
        case (nil, nil):
            return nil
        case (_?, _?):
            throw CherryControlError(code: "invalid_input", message: "Provide at most one of text or raw_base64.")
        }

        let wantsSubmit = submit ?? isTextInput
        let shouldSubmit = wantsSubmit && payload.last != 0x0d && payload.last != 0x0a
        return AgentInitialInput(payload: payload, submit: shouldSubmit)
    }

    private func runAgentInitialInput(
        text: String?,
        rawBase64: String?,
        submit: Bool?,
        keyboardProtocolFlags: Int
    ) throws -> AgentInitialInput? {
        try agentInputPayload(
            text: text,
            rawBase64: rawBase64,
            submit: submit,
            keyboardProtocolFlags: keyboardProtocolFlags
        )
    }

    @MainActor
    func terminalOutput(for session: TerminalSession, startLine requestedStartLine: Int?, lineLimit requestedLineLimit: Int?) -> TerminalOutputResult {
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
            outputVersion: session.outputVersion,
            screen: session.usesAlternateScreen ? "alternate" : "primary",
            contentVersion: session.contentVersion,
            lines: lines
        )
    }

    @MainActor
    private func rawOutput(for session: TerminalSession, maxBytes requestedMaxBytes: Int?) -> TerminalRawOutputResult {
        let maxBytes = min(max(requestedMaxBytes ?? 65_536, 1), 1_048_576)
        let snapshot = session.rawOutput(maxBytes: maxBytes)
        let data = snapshot.truncated
            ? Self.trimmedRawOutputSuffix(snapshot.data)
            : snapshot.data
        return TerminalRawOutputResult(
            terminalID: session.id.uuidString,
            text: String(decoding: data, as: UTF8.self),
            byteCount: data.count,
            truncated: snapshot.truncated
        )
    }

    // A truncated raw-output suffix can start mid-UTF-8-codepoint or in the
    // middle of an escape sequence; trim to the first clean decode boundary.
    nonisolated static func trimmedRawOutputSuffix(_ data: Data) -> Data {
        var bytes = data[...]
        while let first = bytes.first, (0x80...0xBF).contains(first) {
            bytes = bytes.dropFirst()
        }
        if let first = bytes.first, first != 0x1B, (0x30...0x3F).contains(first) {
            let window = bytes.prefix(256)
            if let boundary = window.firstIndex(where: { $0 == 0x1B || $0 == 0x0A }) {
                bytes = bytes[boundary...]
            }
        }
        return Data(bytes)
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

    /// One request line, without its newline: at most `limits.maxBytes`
    /// (refused before any decoding, `request_too_large`), all of it within
    /// `limits.deadline` when there is one (`request_timeout`).
    nonisolated static func readRequest(fileDescriptor fd: Int32, limits: RequestLimits = .thisMac) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = limits.deadline.map { Date().addingTimeInterval($0) }
        let tooLarge = CherryControlError(
            code: "request_too_large",
            message: "The request is larger than Cherry accepts (\(limits.maxBytes) bytes)."
        )
        while true {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw requestTimedOut }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(min(remaining * 1_000, 60_000).rounded(.up)))
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                // Only the new bytes are searched for the newline.
                if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                    guard data.count + newline <= limits.maxBytes else { throw tooLarge }
                    data.append(contentsOf: buffer[..<newline])
                    return data
                }
                guard data.count + count <= limits.maxBytes else { throw tooLarge }
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private nonisolated static let requestTimedOut = CherryControlError(
        code: "request_timeout",
        message: "The request did not arrive in time."
    )

    private nonisolated static func configureBlocking(fileDescriptor fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    private nonisolated static func configureSocketTimeouts(fileDescriptor fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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
