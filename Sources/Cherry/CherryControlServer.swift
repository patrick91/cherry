import CherryControl
import Darwin
import Foundation
import os

private let mcpControlDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_MCP"] == "1"

private func mcpControlDebugLog(_ message: @autoclosure () -> String) {
    guard mcpControlDebugEnabled else { return }
    fputs("[mcp-control] \(message())\n", stderr)
}

final class CherryControlServer: @unchecked Sendable {
    private let workspaceProvider: @MainActor () -> TerminalWorkspace?
    private let todoStoreProvider: @MainActor () -> ProjectTodoStore?
    private let chromeStateProvider: @MainActor () -> ProjectWindowChromeState?
    private let workspaceForProjectRootProvider: @MainActor (String) -> TerminalWorkspace?
    private let todoStoreForProjectRootProvider: @MainActor (String) -> ProjectTodoStore?
    private let chromeStateForProjectRootProvider: @MainActor (String) -> ProjectWindowChromeState?
    private let openProjectRootsProvider: @MainActor () -> [String]
    /// Every open project window's workspace, a project's several windows
    /// each (`openWorkspaces`).
    private let openWorkspacesProvider: @MainActor () -> [TerminalWorkspace]
    /// The chrome state of the window that shows a workspace, never another
    /// window of its project.
    private let chromeStateForWorkspaceProvider: @MainActor (TerminalWorkspace) -> ProjectWindowChromeState?
    private let openProjectProvider: @MainActor (String) -> Void
    private let agentSettings: AgentSettings
    private let serviceDetector: any ServiceDetecting
    /// Services of tabs of other Macs (docs/specs/remote-devices.md, phase 4a).
    private let remoteServiceDetector: DeviceServiceDetector
    let socketURL: URL
    private let queue = DispatchQueue(label: "Cherry.ControlServer", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    /// The socket file this server bound (nil while it does not listen):
    /// only that file is ever removed, never another server's that took
    /// the path.
    private var boundSocket: UnixIO.FileIdentity?

    /// A server for one window and its stores (tests).
    @MainActor
    convenience init(
        workspace: TerminalWorkspace,
        todoStore: ProjectTodoStore? = nil,
        chromeState: ProjectWindowChromeState? = nil,
        socketURL: URL = CherryControlServer.appSocketURL(),
        agentSettings: AgentSettings = .shared,
        serviceDetector: any ServiceDetecting = MacOSServiceDetector(),
        remoteServiceDetector: DeviceServiceDetector? = nil,
        monitorDefaults: UserDefaults = .standard,
        taskBoard: AgentTaskBoard? = nil
    ) {
        self.init(
            workspaceProvider: { workspace },
            todoStoreProvider: { todoStore },
            chromeStateProvider: { chromeState },
            workspaceForProjectRootProvider: { projectRoot in
                workspace.projectRoot == projectRoot ? workspace : nil
            },
            todoStoreForProjectRootProvider: { projectRoot in
                todoStore?.projectRoot == projectRoot ? todoStore : nil
            },
            chromeStateForProjectRootProvider: { projectRoot in
                workspace.projectRoot == projectRoot ? chromeState : nil
            },
            openProjectRootsProvider: {
                workspace.projectRoot.map { [$0] } ?? []
            },
            openWorkspacesProvider: { [workspace] },
            chromeStateForWorkspaceProvider: { $0 === workspace ? chromeState : nil },
            openProjectProvider: { _ in },
            socketURL: socketURL,
            agentSettings: agentSettings,
            serviceDetector: serviceDetector,
            remoteServiceDetector: remoteServiceDetector,
            monitorDefaults: monitorDefaults,
            taskBoard: taskBoard
        )
    }

    @MainActor
    init(
        workspaceProvider: @escaping @MainActor () -> TerminalWorkspace?,
        todoStoreProvider: @escaping @MainActor () -> ProjectTodoStore? = {
            ProjectWindowRegistry.shared.activeTodoStore
        },
        chromeStateProvider: @escaping @MainActor () -> ProjectWindowChromeState? = {
            ProjectWindowRegistry.shared.activeChromeState
        },
        workspaceForProjectRootProvider: @escaping @MainActor (String) -> TerminalWorkspace? = {
            ProjectWindowRegistry.shared.workspace(for: $0)
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
        openWorkspacesProvider: @escaping @MainActor () -> [TerminalWorkspace] = {
            ProjectWindowRegistry.shared.allWorkspaces()
        },
        chromeStateForWorkspaceProvider: @escaping @MainActor (TerminalWorkspace) -> ProjectWindowChromeState? = {
            ProjectWindowRegistry.shared.chromeState(for: $0)
        },
        openProjectProvider: @escaping @MainActor (String) -> Void = { _ in },
        socketURL: URL = CherryControlServer.appSocketURL(),
        agentSettings: AgentSettings = .shared,
        serviceDetector: any ServiceDetecting = MacOSServiceDetector(),
        remoteServiceDetector: DeviceServiceDetector? = nil,
        monitorDefaults: UserDefaults = .standard,
        taskBoard: AgentTaskBoard? = nil
    ) {
        self.monitors = AgentMonitorRegistry(defaults: monitorDefaults)
        self.tasks = AgentTaskRegistry(board: taskBoard ?? .shared)
        self.workspaceProvider = workspaceProvider
        self.todoStoreProvider = todoStoreProvider
        self.chromeStateProvider = chromeStateProvider
        self.workspaceForProjectRootProvider = workspaceForProjectRootProvider
        self.todoStoreForProjectRootProvider = todoStoreForProjectRootProvider
        self.chromeStateForProjectRootProvider = chromeStateForProjectRootProvider
        self.openProjectRootsProvider = openProjectRootsProvider
        self.openWorkspacesProvider = openWorkspacesProvider
        self.chromeStateForWorkspaceProvider = chromeStateForWorkspaceProvider
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

    /// The socket the app's server binds: `CHERRY_CONTROL_SOCKET` when it
    /// names a path no server answers (a private run's fresh path), else
    /// the derived namespace path (`CherryControl.socketURL` with that
    /// variable ignored). A Cherry started from a Cherry tab inherits that
    /// tab's live socket and never takes it over. The probe runs only while
    /// the variable is set, so a normal launch pays nothing.
    nonisolated static func appSocketURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL
    ) -> URL {
        var derivedEnvironment = environment
        derivedEnvironment[CherryControl.socketEnvironmentKey] = nil
        let derived = CherryControl.socketURL(environment: derivedEnvironment, executableURL: executableURL)
        guard let named = environment[CherryControl.socketEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return derived }
        return UnixIO.hasListener(atPath: named) ? derived : URL(fileURLWithPath: named)
    }

    /// The path the app's server binds, which its tabs name: `CherryApp.init`
    /// sets it once from `appSocketURL()`, before any tab exists; `start()`
    /// sets it back to nil when the server does not listen there. Nil in
    /// tests.
    static var appSocketPath: String? {
        get { appSocketPathStorage.withLock { $0 } }
        set { appSocketPathStorage.withLock { $0 = newValue } }
    }

    private static let appSocketPathStorage = OSAllocatedUnfairLock<String?>(initialState: nil)

    func start() {
        guard acceptSource == nil else { return }

        do {
            try prepareSocketDirectory()
            try bindAndListen()
        } catch {
            let message = (error as? CherryControlError)?.message ?? error.localizedDescription
            fputs("[control] failed to start: \(message)\n", stderr)
            SessionLog.error("control socket: \(message)")
            // Tabs name only a socket this app answers.
            if Self.appSocketPath == socketURL.path { Self.appSocketPath = nil }
        }
    }

    /// The window an unscoped request falls back to.
    @MainActor
    func workspaceForMonitors() -> TerminalWorkspace? {
        workspaceProvider()
    }

    func stop() {
        Task { @MainActor [monitors, tasks] in
            monitors.stopSampler()
            tasks.pruneTask?.cancel()
        }
        // The source's cancel handler closes the listening descriptor
        // (closing it before then would close whatever reused its number).
        acceptSource?.cancel()
        acceptSource = nil
        // Only the socket this server bound: one that did not listen (another
        // copy of Cherry listens there, or a second server on the path) must
        // leave the live server's socket in place.
        if let boundSocket {
            UnixIO.removeFile(atPath: socketURL.path, ifStill: boundSocket)
            self.boundSocket = nil
        }
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

    /// The user's other Macs, for list_devices and add_project: none
    /// unless set (the app sets its store's, `ControlDeviceDirectory.app`).
    @MainActor var deviceDirectory: ControlDeviceDirectory = .none

    private struct DeviceListener {
        var url: URL
        var source: DispatchSourceRead
        /// The socket file it bound, the only one it removes.
        var socket: UnixIO.FileIdentity?
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
        /// cap only (pasted input can be large).
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
        // Only a stale socket of this user's is replaced: another copy's
        // live listener keeps its device's forward.
        try Self.removeStaleSocket(at: url.path)
        let fd = try Self.bindListeningSocket(path: url.path)
        let source = makeAcceptSource(fileDescriptor: fd, origin: .device(deviceID))
        let listener = DeviceListener(url: url, source: source, socket: UnixIO.FileIdentity(path: url.path))
        listenerLock.withLock { deviceListeners[deviceID] = listener }
        source.resume()
        return url
    }

    /// Stops listening for `deviceID`'s callers and removes its socket
    /// (only while its path is still the socket it bound).
    func removeDeviceListener(deviceID: UUID) {
        guard let listener = listenerLock.withLock({ deviceListeners.removeValue(forKey: deviceID) }) else { return }
        listener.source.cancel()
        if let socket = listener.socket {
            UnixIO.removeFile(atPath: listener.url.path, ifStill: socket)
        }
    }

    /// The directory a derived socket path's namespaces share
    /// (`CherryControl.sharedSocketRoot`), when `socketURL` is one; nil for
    /// a path named explicitly (`CHERRY_CONTROL_SOCKET`, tests).
    nonisolated static func sharedSocketRoot(of socketURL: URL) -> URL? {
        let root = CherryControl.sharedSocketRoot
        let namespace = socketURL.deletingLastPathComponent()
        return namespace.deletingLastPathComponent().path == root.path ? root : nil
    }

    /// Makes the socket's directory, private (0700), and checks it is this
    /// user's own; with `removingSocket`, replaces a stale socket file. A
    /// directory of another owner, or a link, makes `start()` log and not
    /// listen; so does a live socket at the path (another copy of Cherry
    /// listens there: it is never taken over).
    private func prepareSocketDirectory(removingSocket: Bool = true) throws {
        let directoryURL = socketURL.deletingLastPathComponent()
        // The derived path's shared level too: another account can create
        // that predictable directory in /tmp first, and as its owner rename
        // the namespace directory away under this server.
        if let root = Self.sharedSocketRoot(of: socketURL) {
            if mkdir(root.path, S_IRWXU) != 0, errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try Self.closeDirectory(root.path, forbiddenModeBits: S_IWGRP | S_IWOTH)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.closeDirectory(directoryURL.path)
        if removingSocket { try Self.removeStaleSocket(at: socketURL.path) }
    }

    /// Throws `socket_not_private` unless `path` is a real directory of this
    /// user's with none of `forbiddenModeBits` set (`UnixIO.directoryProblem`).
    /// One of this user's with some of them set has them cleared first,
    /// and is checked again (a failed chmod leaves it refused).
    private nonisolated static func closeDirectory(_ path: String, forbiddenModeBits: mode_t = 0o077) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(), status.st_mode & forbiddenModeBits != 0 {
            _ = chmod(path, status.st_mode & 0o7777 & ~forbiddenModeBits)
            guard lstat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if let problem = UnixIO.directoryProblem(path, status: status, forbiddenModeBits: forbiddenModeBits) {
            throw UnixIO.socketNotPrivate(problem)
        }
    }

    /// Removes the socket file at `path` when nothing listens there; throws
    /// when a server does (another copy of Cherry, never taken over) or the
    /// file is not a socket of this user's (never removed).
    private nonisolated static func removeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == geteuid() else {
            throw UnixIO.socketNotPrivate("\(path) is not a socket owned by this user")
        }
        guard !UnixIO.hasListener(atPath: path) else {
            throw CherryControlError(
                code: "socket_in_use",
                message: "Another Cherry is listening on \(path); this one has no control socket"
            )
        }
        unlink(path)
    }

    private func bindAndListen() throws {
        let fd = try Self.bindListeningSocket(path: socketURL.path)
        boundSocket = UnixIO.FileIdentity(path: socketURL.path)
        let source = makeAcceptSource(fileDescriptor: fd, origin: .thisMac)
        acceptSource = source
        source.resume()
    }

    /// A listening Unix socket at `path` (mode 0600, non-blocking).
    private nonisolated static func bindListeningSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        UnixIO.setCloseOnExec(fd)

        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        guard let bindResult = UnixIO.withSocketAddress(path: path, { Darwin.bind(fd, $0, $1) }) else {
            close(fd)
            throw CherryControlError(code: "socket_path_too_long", message: "Control socket path is too long.")
        }

        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        chmod(path, S_IRUSR | S_IWUSR)

        // Room for bursts of clients (each MCP helper, probes): with a full
        // backlog a connection is refused as by a stale socket.
        guard listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private func makeAcceptSource(fileDescriptor fd: Int32, origin: CallerOrigin) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections(on: fd, origin: origin)
        }
        source.setCancelHandler {
            close(fd)
        }
        return source
    }

    private nonisolated func acceptAvailableConnections(on listenFileDescriptor: Int32, origin: CallerOrigin) {
        while true {
            let clientFD = accept(listenFileDescriptor, nil, nil)
            if clientFD >= 0 {
                UnixIO.setCloseOnExec(clientFD)
                Self.configureBlocking(fileDescriptor: clientFD)
                // A client that went away (a device's ssh, whose other end
                // closed) makes a write fail with EPIPE, never SIGPIPE.
                UnixIO.setNoSigPipe(clientFD)
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

            // Only this account's processes, whichever socket they reached
            // (a device's forward is This Mac's ssh, this account's too).
            guard UnixIO.peerUserID(fileDescriptor: clientFD) == geteuid() else {
                Self.writeResponse(.init(error: Self.otherAccountRefused), to: clientFD)
                finish()
                return
            }

            // The connecting process (e.g. an agent's MCP server) and its
            // parents, pinned now with when each started: the caller's tab is
            // the one whose program is among them (`verifiedCallerSession`,
            // `callerWorkspace`), even once the caller exited and its pid went
            // to another process. Never for a device's listener: its peer is
            // This Mac's ssh, and its callers are another Mac's processes.
            let callerChain = origin == .thisMac
                ? Self.peerProcessID(fileDescriptor: clientFD).flatMap(CallerProcessChain.pinned(peer:))
                : nil
            self.acceptedCallerChainForTesting?(callerChain)

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
                    response = await self.handleRequestData(requestData, callerChain: callerChain, origin: origin)
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

    /// A request of `peerPID`'s, its chain pinned now (tests, which hand
    /// requests in without a connection).
    @MainActor
    func handleRequestData(_ data: Data, peerPID: Int32?, origin: CallerOrigin = .thisMac) async -> CherryControlResponse {
        await handleRequestData(data, callerChain: peerPID.flatMap(CallerProcessChain.pinned(peer:)), origin: origin)
    }

    /// A request, as `callerChain` (This Mac's, pinned when it connected)
    /// or a device's token makes it.
    @MainActor
    func handleRequestData(_ data: Data, callerChain: CallerProcessChain?, origin: CallerOrigin = .thisMac) async -> CherryControlResponse {
        do {
            let (credentials, request) = try CherryControlEnvelope.decode(data)
            // appInfo and listTools never wait for the task restore below
            // (`CherryControlTools.swift`).
            if let answer = try toolRequestAnsweredAtOnce(request, credentials: credentials, origin: origin) {
                return answer
            }
            // The last run's tasks are read back first (at launch).
            if let restoring = tasks.restoreTask { await restoring.value }
            if let credentials {
                let caller = try remoteCaller(credentials, origin: origin)
                // Everything this request reaches is checked against the
                // caller's device (`requireOnRemoteDevice`, the one choke
                // point), however it was mapped.
                return try await Self.$remoteDevice.withValue(caller.deviceID) {
                    try await Self.$remoteCallerSessionID.withValue(caller.session.id) {
                        // Each of a tool's requests is checked as when each
                        // was a connection of its own: the token again (a tab
                        // closed meanwhile is refused the rest), then the
                        // device's choke point.
                        let dispatch: @Sendable @MainActor (CherryControlRequest) async throws -> CherryControlResponse = { request in
                            let caller = try self.remoteCaller(credentials, origin: origin)
                            return try await self.handle(request, remoteCaller: caller)
                        }
                        switch request {
                        case .callTool(let call):
                            return .init(result: .callTool(await handleToolCall(call, dispatch: dispatch)))
                        case .runCommand(let command):
                            return .init(result: .runCommand(await handleCommand(command, dispatch: dispatch)))
                        default:
                            return try await handle(request, remoteCaller: caller)
                        }
                    }
                }
            }
            guard origin == .thisMac else { throw Self.missingDeviceToken }
            return try await Self.$callerProcessChain.withValue(callerChain) {
                try await Self.$callerPeerPID.withValue(callerChain?.pids.first) {
                    // Each of a tool's requests goes where the caller's own
                    // typed request would: to its window, found from its process.
                    let dispatch: @Sendable @MainActor (CherryControlRequest) async throws -> CherryControlResponse = { request in
                        try await self.handle(request, callerChain: callerChain)
                    }
                    switch request {
                    case .callTool(let call):
                        return .init(result: .callTool(await handleToolCall(call, dispatch: dispatch)))
                    case .runCommand(let command):
                        return .init(result: .runCommand(await handleCommand(command, dispatch: dispatch)))
                    default:
                        return try await handle(request, callerChain: callerChain)
                    }
                }
            }
        } catch let error as CherryControlError {
            return .init(error: error)
        } catch {
            return .init(error: Self.removedNotesError(in: data)
                ?? .init(code: "invalid_request", message: error.localizedDescription))
        }
    }

    /// A connection from a process of another account (or one whose
    /// account cannot be read): refused before its request is read.
    nonisolated static let otherAccountRefused = CherryControlError(
        code: "unauthorized",
        message: "Cherry's control socket answers only its own account's processes; this connection came from another account."
    )

    /// A request on a device's listener without a token.
    static let missingDeviceToken = CherryControlError(
        code: "unauthorized",
        message: "This request came from another Mac without a Cherry token. Run cherry in a Cherry tab of that Mac."
    )

    /// The requests of the notes Cherry no longer has, as a CherryMCP from
    /// before their removal still sends them (an agent's helper an update
    /// kept running, a build installed on another Mac). They no longer
    /// decode; their callers are told why instead of a decoding error.
    nonisolated static let removedNotesRequests: Set<String> = [
        "listNotes", "createNote", "getNote", "updateNote", "appendNote",
        "renameNote", "searchNotes", "deleteNote", "selectNote",
    ]

    /// `notes_removed` when `data` is a request of `removedNotesRequests`:
    /// plain, in an envelope, or scoped (`{"scoped":{"_0":{…,"request":…}}}`).
    nonisolated static func removedNotesError(in data: Data) -> CherryControlError? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var request: Any? = object
        if object["cherryAuth"] != nil {
            request = object["request"]
        }
        while let current = request as? [String: Any], current.count == 1, let name = current.keys.first {
            if removedNotesRequests.contains(name) {
                return CherryControlError(
                    code: "notes_removed",
                    message: "Cherry no longer has notes; this request came from an older CherryMCP. Restart the agent to get the current tools."
                )
            }
            guard name == "scoped", let scoped = current[name] as? [String: Any] else { return nil }
            let scopedRequest = scoped["_0"] as? [String: Any] ?? scoped
            request = scopedRequest["request"]
        }
        return nil
    }

    @MainActor
    private func handle(_ request: CherryControlRequest, callerChain: CallerProcessChain?) async throws -> CherryControlResponse {
        if case .scoped(let scopedRequest) = request {
            let workspace = try scopedWorkspace(projectRoot: scopedRequest.projectRoot)
            return try await handleUnscoped(scopedRequest.request, workspace: workspace, isProjectScoped: true)
        }

        // An unscoped request: prefer the caller's OWN workspace, resolved from the
        // connecting process's ancestry (pinned when it connected), so an MCP
        // whose agent CLI stripped CHERRY_PROJECT_ROOT still routes to its own
        // project window instead of the frontmost one. Fall back to the active
        // workspace.
        if let callerWorkspace = callerWorkspace(callerChain: callerChain) {
            return try await handleUnscoped(request, workspace: callerWorkspace, isProjectScoped: true)
        }

        guard let workspace = workspaceProvider() else {
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
    func remoteCaller(_ credentials: CherryControlCredentials, origin: CallerOrigin) throws -> RemoteCaller {
        let refused = CherryControlError(
            code: "unauthorized",
            message: "Cherry refused this Cherry token: it does not belong to an open tab of this Mac's Cherry (the tab was closed, or it was started by another copy of Cherry)."
        )
        guard let tabID = UUID(uuidString: credentials.processID) else { throw refused }
        // Every window: a tab of a project's second window is as much its
        // device's as one of the first.
        for candidate in openWorkspaces() {
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

    /// The processes of the This Mac caller whose request is being handled
    /// (its CherryMCP and its parents), pinned when it connected, for
    /// `verifiedCallerSession` and `callerWorkspace`; nil for callers on
    /// another Mac (no pid crosses machines).
    @TaskLocal static var callerProcessChain: CallerProcessChain?

    /// The peer process of the This Mac caller whose request is being
    /// handled (`callerProcessChain`'s first): `callerSessionResolverForTesting`
    /// gets it.
    @TaskLocal static var callerPeerPID: Int32?

    /// A This Mac caller's process and its parents (`processAncestry`, up
    /// to launchd), each with when it started (`UnixIO.processStartIdentity`),
    /// as they were when it connected.
    struct CallerProcessChain: Equatable, Sendable {
        var pids: [Int32]
        /// Each pid's start, nil when it could not be read.
        var startIdentities: [String?]

        /// `peer`'s chain, now; nil when the peer's own start cannot be read
        /// (it exited already), since its pid could be another process's by
        /// the time it is matched.
        static func pinned(peer: Int32) -> CallerProcessChain? {
            let pids = CherryControl.processAncestry(of: peer, maxDepth: 20)
            let startIdentities = pids.map(UnixIO.processStartIdentity)
            guard startIdentities.first.flatMap({ $0 }) != nil else { return nil }
            return CallerProcessChain(pids: pids, startIdentities: startIdentities)
        }

        /// Whether `pid` is one of the chain's processes still: a pid whose
        /// process started at another time than when the chain was pinned
        /// went to another process since (the caller exited); when either
        /// start is unknown, the pid stands.
        func contains(_ pid: Int32, currentStartIdentity: (Int32) -> String? = UnixIO.processStartIdentity) -> Bool {
            guard let index = pids.firstIndex(of: pid) else { return false }
            guard index < startIdentities.count, let recorded = startIdentities[index],
                  let current = currentStartIdentity(pid)
            else { return true }
            return recorded == current
        }
    }

    /// The tab whose program is one of `chain`'s processes, and its window:
    /// a tab that runs the program first; a tab attached to the same session
    /// of This Mac (another window's view of it) only when no window runs
    /// it. A persistent tab's program pid comes from This Mac's host; a tab
    /// attached to another machine's session has none.
    @MainActor
    static func callerSession(
        matching chain: CallerProcessChain,
        in workspaces: [TerminalWorkspace]
    ) -> (session: TerminalSession, workspace: TerminalWorkspace)? {
        for attached in [false, true] {
            for workspace in workspaces {
                for session in workspace.sessions where (session.hostedAttachment != nil) == attached {
                    if let pid = session.programProcessID, chain.contains(pid) {
                        return (session, workspace)
                    }
                }
            }
        }
        return nil
    }

    /// Tests: sees each connection's caller chain (nil on a device's
    /// listener) as it is accepted, before its request is read. Set it
    /// before `start()`.
    var acceptedCallerChainForTesting: (@Sendable (CallerProcessChain?) -> Void)?

    /// Monitors (`subscribe`, `wait_for_events`, wake lines).
    let monitors: AgentMonitorRegistry

    /// Tasks (`spawn_agent` with `task`, `report_result`, `wait_for_tasks`):
    /// each tied to its worker's tab; the app's are saved, so they survive
    /// its relaunch (`configureTaskPersistence`).
    let tasks: AgentTaskRegistry

    /// Tests: the caller's own tab, in place of the peer's process ancestry.
    @MainActor var callerSessionResolverForTesting: ((Int32?) -> TerminalSession?)?

    /// Tests: false answers appInfo, listTools and callTool with
    /// invalid_request, as an app from before control protocol 2 does.
    @MainActor var answersToolRequests = true

    /// Tests: the `toolsDigest` every callTool answers with, in place of the
    /// catalog's (as when the app's tools changed under a running client).
    @MainActor var toolsDigestOverrideForTesting: String?

    /// Tests: sees each request of a tool call before it is dispatched.
    @MainActor var toolDispatchWillSendForTesting: ((CherryControlRequest) -> Void)?

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
        workspace.childAgentSessions(of: session).filter { callerReaches($0, in: workspace) }.count
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
            let workspace = try remoteWorkspace(projectRoot: scopedRequest.projectRoot, deviceID: caller.deviceID, caller: caller)
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

    /// The open window of the device's project at `projectRoot` (or of the
    /// project containing it), matched by location: the same device and the path, never through
    /// `standardizedProjectRoot`. Of a project's several windows, the
    /// caller's own, else the one active most recently.
    @MainActor
    private func remoteWorkspace(projectRoot: String, deviceID: UUID, caller: RemoteCaller) throws -> TerminalWorkspace {
        let location = try Self.remoteProjectLocation(projectRoot, deviceID: deviceID)
        let path = location.path
        let workspaces = openWorkspaces().filter { Self.isOnDevice($0.projectRoot, deviceID) }
        let exact = workspaces.filter { $0.projectRoot.map { ProjectLocation(key: $0).path } == path }
        if let window = preferredWindow(among: exact, caller: caller.workspace) {
            return window
        }
        let containing = workspaces
            .compactMap { candidate -> (TerminalWorkspace, String)? in
                guard let root = candidate.projectRoot.map({ ProjectLocation(key: $0).path }),
                      path.hasPrefix(root == "/" ? "/" : root + "/")
                else { return nil }
                return (candidate, root)
            }
        guard let longest = containing.map(\.1.count).max(),
              let window = preferredWindow(among: containing.filter { $0.1.count == longest }.map(\.0), caller: caller.workspace)
        else {
            throw CherryControlError(
                code: "project_unavailable",
                message: "Cherry project is not open for scoped request: \(projectRoot). Open it first: cherry project open \(projectRoot)"
            )
        }
        return window
    }

    /// Of `windows`, the windows of one project: `caller`'s own when it is
    /// one of them, else the project's most recently active
    /// (`workspaceForProjectRootProvider`), else the first.
    @MainActor
    private func preferredWindow(among windows: [TerminalWorkspace], caller: TerminalWorkspace?) -> TerminalWorkspace? {
        if let caller, windows.contains(where: { $0 === caller }) { return caller }
        if let root = windows.first?.projectRoot, let recent = workspaceForProjectRootProvider(root),
           windows.contains(where: { $0 === recent }) {
            return recent
        }
        return windows.first
    }

    /// Open Project for a caller on another Mac: only a project of its Mac
    /// that Cherry knows, matched by its key exactly.
    @MainActor
    private func openRemoteProject(_ request: OpenProjectRequest, caller: RemoteCaller) throws -> OpenProjectResult {
        let key = try Self.remoteProjectLocation(request.projectRoot, deviceID: caller.deviceID).key
        let known = agentSettings.projects.map(\.root) + openProjectRootsProvider() + [caller.workspace.projectRoot].compactMap { $0 }
            + deviceProjectKeys(of: caller.deviceID)
        guard known.contains(key) else {
            throw CherryControlError(code: "project_not_found", message: "Cherry project is not configured: \(request.projectRoot).")
        }
        let alreadyOpen = openProjectRootsProvider().contains(key)
        openProjectProvider(key)
        return OpenProjectResult(projectRoot: key, alreadyOpen: alreadyOpen)
    }

    /// The workspace whose session process tree contains the connecting peer (the
    /// agent's MCP server): the window of the tab whose program is one of the
    /// peer's processes pinned when it connected (`callerSession(matching:in:)`).
    /// nil if no match.
    @MainActor
    private func callerWorkspace(callerChain: CallerProcessChain?) -> TerminalWorkspace? {
        guard let callerChain else { return nil }
        return Self.callerSession(matching: callerChain, in: openWorkspaces())?.workspace
    }

    /// Every open project window's workspace, each once: the windows'
    /// (`openWorkspacesProvider`, a project's several windows each), each
    /// open project's (`workspaceForProjectRootProvider`), and the active
    /// one.
    @MainActor
    func openWorkspaces() -> [TerminalWorkspace] {
        var seen = Set<ObjectIdentifier>()
        return (openWorkspacesProvider()
            + openProjectRootsProvider().compactMap { workspaceForProjectRootProvider($0) }
            + [workspaceProvider()].compactMap { $0 })
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
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
        case .listDevices:
            return .init(result: .listDevices(listDevices()))
        case .addProject(let request):
            return .init(result: .addProject(try await addProject(request)))
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
            return .init(result: .getProcessStatus(.init(
                process: processInfo(for: session, workspace: sessionWorkspace),
                prompt: await statusPrompt(of: session)
            )))
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
            let (session, sentBytes, inputError) = try await spawnProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .spawnProcess(.init(
                process: processInfo(for: session, workspace: owningWorkspace(of: session, from: workspace)),
                sentBytes: sentBytes,
                output: output,
                task: tasks.latestTask(forWorker: session.id)
                    .flatMap { $0.device == Self.remoteDevice ? tasks.info(for: $0) : nil },
                inputError: inputError
            )))
        case .startProcess(let request):
            // A command's tab can be another window's of the project: it is
            // described as that window shows it.
            let session = try await startProcess(request, workspace: workspace)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .startProcess(.init(
                process: processInfo(for: session, workspace: owningWorkspace(of: session, from: workspace)),
                output: output
            )))
        case .stopProcess(let request):
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            stopProcess(session)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .stopProcess(.init(process: processInfo(for: session, workspace: sessionWorkspace), output: output)))
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
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            session.rename(to: request.title)
            return .init(result: .renameProcess(.init(process: processInfo(for: session, workspace: sessionWorkspace))))
        case .selectProcess(let request):
            // Selected in the window that has it (an id can name another
            // window's tab), which stays where it is.
            let (session, sessionWorkspace) = try resolveProcessWithWorkspace(workspace: workspace, processID: request.processID, processName: request.processName)
            sessionWorkspace.select(session)
            chromeState(for: sessionWorkspace)?.selectTerminal()
            return .init(result: .selectProcess(.init(process: processInfo(for: session, workspace: sessionWorkspace))))
        case .sendProcessInput(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            let sentBytes = try await sendControlInput(
                text: request.text,
                rawBase64: request.rawBase64,
                submit: request.submit,
                to: session
            )
            // A message to a worker waiting for approval is the answer.
            noteRequestInput(to: session)
            let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
            return .init(result: .sendProcessInput(.init(processID: session.id.uuidString, sentBytes: sentBytes, output: output)))
        case .answerPrompt(let request):
            let session = try resolveProcess(workspace: workspace, processID: request.processID, processName: request.processName)
            return .init(result: .answerPrompt(try await answerPrompt(request, of: session)))
        case .startAllCommands(let request):
            _ = try await startAllCommands(workspace: workspace)
            if let waitMilliseconds = request.waitMilliseconds, waitMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(min(max(waitMilliseconds, 0), 5_000)))
            }
            return .init(result: .startAllCommands(try listProcesses(workspace: workspace, kind: nil)))
        case .stopAllCommands(let request):
            // The project's commands, in every one of its windows.
            for commandWorkspace in [workspace] + workspace.otherProjectWindows() {
                commandWorkspace.commandSessions
                    .filter { callerReaches($0, in: commandWorkspace) }
                    .forEach { $0.stopManagedCommand() }
            }
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
        case .listTodos:
            let todoStore = try activeTodoStore(for: workspace)
            return .init(result: .listTodos(listTodos(todoStore: todoStore, workspace: workspace)))
        case .createTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.create(
                title: request.title,
                markdown: request.markdown,
                status: request.status ?? .backlog,
                tags: request.tags ?? []
            )
            return .init(result: .createTodo(todoDetail(todo, in: workspace)))
        case .getTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.todo(id: try todoID(from: request.todoID))
            return .init(result: .getTodo(todoDetail(todo, in: workspace)))
        case .updateTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.update(
                id: try todoID(from: request.todoID),
                title: request.title,
                markdown: request.markdown,
                status: request.status,
                tags: request.tags
            )
            return .init(result: .updateTodo(todoDetail(todo, in: workspace)))
        case .moveTodo(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let afterTodoID = try request.afterTodoID.map { try todoID(from: $0) }
            let todo = try todoStore.move(
                id: try todoID(from: request.todoID),
                status: request.status,
                afterTodoID: afterTodoID
            )
            return .init(result: .moveTodo(todoDetail(todo, in: workspace)))
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
            return .init(result: .addTodoComment(todoDetail(todo, in: workspace)))
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
            return .init(result: .updateTodoComment(todoDetail(todo, in: workspace)))
        case .deleteTodoComment(let request):
            let todoStore = try activeTodoStore(for: workspace)
            let todo = try todoStore.deleteComment(
                todoID: try todoID(from: request.todoID),
                commentID: try commentID(from: request.commentID)
            )
            return .init(result: .deleteTodoComment(todoDetail(todo, in: workspace)))
        case .clearOutput(let request):
            let session = try findSession(workspace: workspace, terminalID: request.terminalID)
            // A persistent tab's host clears its copy before this answers,
            // so the output read next no longer has it; or says why not.
            let kept = await session.clearScrollback()?.value ?? nil
            return .init(result: .clearOutput(.init(
                terminalID: session.id.uuidString, cleared: kept == nil, hostKeptHistory: kept
            )))
        case .appInfo, .listTools, .callTool, .runCommand:
            // `handleRequestData` answers these before any window is
            // resolved: here they could only come nested in a scoped request.
            throw CherryControlError(
                code: "invalid_request",
                message: "A tool call is never scoped: pass project_root in its arguments."
            )
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
    private func todoStore(forProjectRoot projectRoot: String, fallbackWorkspace workspace: TerminalWorkspace) -> ProjectTodoStore {
        if workspace.projectRoot == projectRoot,
           let store = todoStoreProvider(),
           store.projectRoot == projectRoot {
            return store
        }
        if let store = ProjectWindowRegistry.shared.todoStore(for: projectRoot) {
            return store
        }
        // Shared with a window of the project that opens meanwhile.
        return ProjectTodoStore.shared(projectRoot: projectRoot)
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
                    // Cheap, non-refreshing line count, as process listings.
                    lineCount: session.listingLineCount,
                    link: link(for: session, workspace: workspace),
                    kind: session.kind.rawValue,
                    agentName: session.agentName,
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
            agents: agentSettings.agents.map { agent in
                let normalizedName = agent.normalizedName
                let activeSessionCount = workspace.agentSessions.filter { callerReaches($0, in: workspace) }.filter {
                    $0.agentName.map { AgentToolDefinition.normalizedName($0) } == normalizedName
                }.count

                return AgentInfo(
                    id: agent.id,
                    name: agent.name,
                    command: agent.command,
                    arguments: agent.arguments,
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
        let openRoots = Set(openProjectRootsProvider().map(CherryControl.standardizedProjectRoot))
        var seenRepositoryRoots = Set<String>()

        return ListProjectsResult(
            activeProjectRoot: activeRoot,
            projects: roots.compactMap { requestedRoot in
                let root = agentSettings.repositoryRoot(for: requestedRoot) ?? requestedRoot
                let standardizedRoot = CherryControl.standardizedProjectRoot(root)
                guard seenRepositoryRoots.insert(standardizedRoot).inserted else { return nil }
                return ProjectInfo(
                    root: root,
                    name: URL(fileURLWithPath: root, isDirectory: true).lastPathComponent,
                    active: standardizedRoot == activeRepositoryRoot.map(CherryControl.standardizedProjectRoot),
                    open: openRoots.contains(standardizedRoot),
                    features: projectFeatureAvailability(for: root)
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
        let candidateRoots = agentSettings.projects.map(\.root)
            + openProjectRootsProvider()
            + ProjectWindowRegistry.shared.knownProjectRoots
            + [workspace.projectRoot].compactMap { $0 }
            + deviceProjectKeys()
        // A device's key names its project by location, never as a path
        // of This Mac.
        let requested = request.projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = if ProjectLocation.isRemoteKey(requested) {
            { ProjectLocation(key: $0) == ProjectLocation(key: requested) }
        } else {
            { [requestedRoot = CherryControl.standardizedProjectRoot(requested)] in
                !ProjectLocation.isRemoteKey($0) && CherryControl.standardizedProjectRoot($0) == requestedRoot
            }
        }
        guard let projectRoot = candidateRoots.first(where: matches) else {
            throw CherryControlError(
                code: "project_not_found",
                message: "Cherry project is not configured: \(request.projectRoot)."
            )
        }

        let openRoots = Set(openProjectRootsProvider().map(CherryControl.standardizedProjectRoot))
        let alreadyOpen = openRoots.contains(CherryControl.standardizedProjectRoot(projectRoot))
        openProjectProvider(projectRoot)

        return OpenProjectResult(projectRoot: projectRoot, alreadyOpen: alreadyOpen)
    }

    /// The added projects' keys of every device, or of `deviceID`'s.
    @MainActor
    private func deviceProjectKeys(of deviceID: UUID? = nil) -> [String] {
        deviceDirectory.devices()
            .filter { deviceID == nil || $0.id == deviceID }
            .flatMap { device in device.projects.map { ProjectLocation.remote(deviceID: device.id, path: $0).key } }
    }

    /// list_devices: This Mac, then the user's other Macs, each with its
    /// projects. A caller on another Mac sees only its own.
    @MainActor
    private func listDevices() -> ListDevicesResult {
        let open = Set(openProjectRootsProvider())
        var devices: [DeviceInfo] = []
        if Self.remoteDevice == nil {
            // A saved root and its window's may spell the folder apart
            // (/var and /private/var): one project, named as its window is.
            func folder(_ root: String) -> String { URL(fileURLWithPath: root).resolvingSymlinksInPath().path }
            let openRoots = Dictionary(
                openProjectRootsProvider().filter { !ProjectLocation.isRemoteKey($0) }.map { (folder($0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var seen = Set<String>()
            let roots = (agentSettings.projects.map(\.root) + openProjectRootsProvider())
                .filter { !ProjectLocation.isRemoteKey($0) && seen.insert(folder($0)).inserted }
                .map { openRoots[folder($0)] ?? $0 }
            devices.append(DeviceInfo(
                id: DeviceInfo.thisMacID,
                name: DeviceInfo.thisMacName,
                caller: true,
                connected: true,
                homeDirectory: NSHomeDirectory(),
                projects: roots.map { DeviceProject(root: $0, path: $0, open: open.contains($0)) }
            ))
        }
        for device in deviceDirectory.devices() where Self.remoteDevice == nil || Self.remoteDevice == device.id {
            // Its added projects, then its open windows' others.
            var seen = Set<String>()
            let keys = (device.projects.map { ProjectLocation.remote(deviceID: device.id, path: $0).key }
                + openProjectRootsProvider().filter { Self.isOnDevice($0, device.id) })
                .filter { seen.insert($0).inserted }
            devices.append(DeviceInfo(
                id: device.id.uuidString.lowercased(),
                name: device.name,
                caller: Self.remoteDevice == device.id,
                connected: device.connected,
                homeDirectory: device.homeDirectory,
                projects: keys.map { DeviceProject(root: $0, path: ProjectLocation(key: $0).path, open: open.contains($0)) }
            ))
        }
        return ListDevicesResult(devices: devices)
    }

    /// add_project: the folder on This Mac (`AgentSettings.addProject`) or
    /// on a device (`deviceDirectory`), made first when asked, then opened.
    /// A caller on another Mac adds only on its own.
    @MainActor
    private func addProject(_ request: AddProjectRequest) async throws -> AddProjectResult {
        let devices = listDevices().devices
        let device: DeviceInfo
        if let name = request.device?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            do {
                device = try DeviceInfo.named(name, in: devices)
            } catch where Self.remoteDevice != nil {
                // It lists its own Mac only.
                throw Self.refusedOutsideDevice(name.debugDescription)
            }
        } else {
            guard let caller = devices.first(where: \.caller) else {
                throw CherryControlError(code: "device_not_found", message: "Which device? Run cherry devices.")
            }
            device = caller
        }
        let path = try device.expandedPath(request.path)
        if ProjectLocation.hasDotComponents(path) {
            throw CherryControlError(code: "invalid_project_root", message: "A project path may not contain . or .. components.")
        }
        let create = request.create ?? false
        let key: String
        let resolvedPath: String
        let created: Bool
        let alreadyAdded: Bool
        if device.isThisMac {
            var isDirectory: ObjCBool = false
            let existed = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            if !existed, create, case .failed(let message) = OmniLocalFolders.create(path) {
                throw CherryControlError(code: "folder_not_created", message: "\(path) could not be made: \(message)")
            }
            let rootsBefore = Set(agentSettings.projects.map(\.root))
            guard let project = agentSettings.addProject(path: path) else {
                throw CherryControlError(
                    code: "folder_not_found",
                    message: "There is no folder at \(path)." + (create ? "" : " Pass create to make it.")
                )
            }
            key = project.root
            resolvedPath = project.root
            created = !existed
            alreadyAdded = rootsBefore.contains(project.root)
        } else {
            guard let deviceID = UUID(uuidString: device.id) else {
                throw CherryControlError(code: "device_not_found", message: "Not a device id: \(device.id).")
            }
            let added = try await deviceDirectory.addProject(path, deviceID, create)
            key = ProjectLocation.remote(deviceID: deviceID, path: added.path).key
            resolvedPath = added.path
            created = added.created
            alreadyAdded = added.alreadyAdded
        }
        let opens = request.open ?? true
        if opens { openProjectProvider(key) }
        return AddProjectResult(
            projectRoot: key, device: device.name, path: resolvedPath,
            created: created, alreadyAdded: alreadyAdded, opened: opens
        )
    }

    @MainActor
    private func projectStatus(workspace: TerminalWorkspace) -> ProjectStatusResult {
        let selectedSession = callerSelectedSession(workspace)
        let todoStore = try? activeTodoStore(for: workspace)
        let features = projectFeatureAvailability(for: workspace.projectRoot)
        return ProjectStatusResult(
            projectRoot: workspace.projectRoot,
            processCounts: processCounts(workspace: workspace),
            todoCount: todoStore?.todos.count,
            features: features,
            selectedProcessID: selectedSession?.id.uuidString,
            selectedProcessName: selectedSession.map(processName),
            health: workspace.projectRoot == nil ? "no_project" : "ok"
        )
    }

    @MainActor
    private func performanceStatus(workspace: TerminalWorkspace) -> PerformanceStatusResult {
        PerformanceStatusResult(
            activeProjectRoot: workspace.projectRoot,
            processCounts: processCounts(workspace: workspace),
            selectedProcessID: callerSelectedSession(workspace)?.id.uuidString,
            ghosttyLiveBridgeCount: GhosttySessionBridge.liveBridgeCount,
            ghosttyInstalledOutputObserverCount: GhosttySessionBridge.installedOutputObserverCount,
            rawOutputObserverCount: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputObserverCount },
            rawOutputRetainedBytes: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputRetainedByteCount },
            rawOutputRetainedChunkCount: callerSessions(workspace).reduce(0) { $0 + $1.rawOutputRetainedChunkCount },
            terminalPerfEnabled: TerminalPerformanceMonitor.isEnabled,
            terminalPerfCounters: TerminalPerformanceMonitor.snapshot()
        )
    }

    @MainActor
    private func processCounts(workspace: TerminalWorkspace) -> ProcessCounts {
        ProcessCounts(
            total: callerSessions(workspace).count,
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
            resultSummary: task?.result?.summary,
            programStatus: session.programStatus.root.map { status in
                ProcessProgramStatus(
                    state: status.state.rawValue,
                    kind: status.kind?.rawValue,
                    progress: status.progress,
                    app: status.app.nilIfEmpty,
                    title: status.title.nilIfEmpty,
                    message: status.message.nilIfEmpty
                )
            }
        )
    }

    /// An agent's activity state as MCP reports it: what its program
    /// status reports say (`unknown` while it sends none).
    @MainActor
    func reportedAgentActivityState(of session: TerminalSession) -> String? {
        guard session.kind == .agent else { return nil }
        return session.agentActivityState.rawValue
    }

    /// How long after a message an agent that reported no turn may be taken
    /// as done: a CLI reports `working` a moment after the message, and one
    /// that reports nothing never does.
    static let agentTurnStartGrace: TimeInterval = 4

    /// Whether the agent's latest submitted turn started: it was at work
    /// when the message was sent (the CLI queued it behind that turn), or
    /// reported `working` since. Nil when Cherry saw no turn submitted, or
    /// the agent sends no program status reports: its output going quiet is
    /// all there is.
    @MainActor
    static func agentTurnStarted(_ session: TerminalSession) -> Bool? {
        guard session.kind == .agent, let submittedAt = session.lastAgentSubmitAt,
              session.reportsProgramStatus
        else { return nil }
        if session.agentWasWorkingAtLastSubmit { return true }
        if let working = session.lastWorkingReportAt, working >= submittedAt { return true }
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
            // A project command runs in one tab across the project's
            // windows: its name finds that tab in another window too.
            for other in workspace.otherProjectWindows() {
                if let tab = other.commandSession(named: requestedName), callerReaches(tab, in: other) {
                    mcpControlDebugLog("resolved process selector=name:\(requestedName) session=\(tab.id.uuidString) kind=\(tab.kind.rawValue) name=\(self.processName(for: tab)) in another window")
                    return (tab, other)
                }
            }
            throw CherryControlError(code: "process_not_found", message: "No Cherry process exists with name \(requestedName).")
        }
        guard matches.count == 1 else {
            throw CherryControlError(code: "ambiguous_process_name", message: "Multiple Cherry processes match name \(requestedName); use process_id.")
        }
        mcpControlDebugLog("resolved process selector=name:\(requestedName) session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(self.processName(for: session))")
        return (session, workspace)
    }

    /// The new process, the bytes of its first input that reached it, and
    /// why that input did not when it was refused or failed (the process
    /// runs either way).
    @MainActor
    private func spawnProcess(
        _ request: SpawnProcessRequest,
        workspace: TerminalWorkspace
    ) async throws -> (session: TerminalSession, sentBytes: Int, inputError: CherryControlError?) {
        let kind = try requiredProcessKind(from: request.kind)
        let session: TerminalSession
        let agent: AgentToolDefinition?
        // A task's worker (`spawn_agent` with `task`): its kickoff line is
        // the agent's first input. Until it is typed, the task's sampler
        // types nothing into it (`AgentTaskTyping.kickoffPending`).
        var task: AgentTask?
        defer { task?.typing = nil }
        if kind != .agent, request.task != nil {
            throw CherryControlError(code: "invalid_process_request", message: "Only agent processes take a task.")
        }
        switch kind {
        case .terminal:
            guard request.name == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Terminal processes do not use name; pass title instead.")
            }
            guard request.model == nil, request.effort == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Model and effort overrides are only valid for agent processes.")
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
            let agentDefinition = try agentDefinition(resolvedAgent, overridingModel: request.model, effort: request.effort)
            let parent = try spawnParent(from: request.parentAgentID, workspace: workspace)
            // Checked (its schema too) before anything is spawned.
            let taskPlan = try prepareTaskSpawn(request, parentAgentID: parent.owner, workspace: workspace)
            session = workspace.addAgentSession(
                agent: agentDefinition,
                projectRoot: projectRoot,
                title: request.title ?? taskPlan?.label,
                parentAgentID: parent.tab,
                select: false
            )
            if let taskPlan {
                task = registerTask(taskPlan, worker: session, workspace: workspace)
                task?.typing = .kickoffPending
            }
            agent = agentDefinition
        case .command:
            guard request.model == nil, request.effort == nil else {
                throw CherryControlError(code: "invalid_process_request", message: "Model and effort overrides are only valid for agent processes.")
            }
            guard let projectRoot = workspace.projectRoot else {
                throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
            }
            let command = try findProjectCommand(named: request.name ?? "", projectRoot: projectRoot)
            // A restore under way (in any window of the project) may bring
            // back this command's tab: use it rather than start a second
            // copy. Another window's tab is returned as it is.
            await workspace.waitUntilRestored(commandNamed: command.name)
            session = workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
            agent = nil
        }

        mcpControlDebugLog("spawned process session=\(session.id.uuidString) kind=\(session.kind.rawValue) name=\(processName(for: session)) parent=\(session.parentAgentID?.uuidString ?? "nil") submit=\(String(describing: request.submit))")

        // A task's kickoff is worded once its worker started (after the
        // readiness wait): it names the `cherry` commands for a worker
        // whose launch got the CLI (`AgentTask.kickoffLine`).
        let text = task != nil ? "" : request.text
        let submit = task != nil ? true : request.submit
        if (text != nil || request.rawBase64 != nil || submit == true), let agent {
            if task != nil {
                await waitForTaskKickoffReadiness(session: session, agent: agent)
            } else {
                await waitForAgentInitialInputReadiness(session: session, agent: agent)
            }
        }

        let sentBytes: Int
        var inputError: CherryControlError?
        if session.kind == .agent, let agent {
            let input = try agentInputPayload(
                text: task?.kickoffLine ?? text,
                rawBase64: request.rawBase64,
                submit: submit,
                to: session
            )
            let typedSince = Date()
            if let input, !input.isEmpty {
                // A task's kickoff goes under the tab's typing lock, as
                // every line Cherry types (`typeCherryLine`).
                let typingLock = task != nil ? tasks.typingLocks : nil
                await typingLock?.acquire(session.id)
                if let task { beginKickoff(task, into: session) }
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
            let input = try optionalTerminalInputPayload(text: request.text, rawBase64: request.rawBase64)
            if let input, !input.payload.isEmpty || request.submit == true {
                do {
                    sentBytes = try await sendTerminalInput(input, submit: request.submit == true, to: session)
                } catch {
                    mcpControlDebugLog("initial input not delivered session=\(session.id.uuidString): \(error)")
                    inputError = error as? CherryControlError
                    sentBytes = 0
                }
            } else {
                sentBytes = 0
            }
        }
        return (session, sentBytes, inputError)
    }

    private func agentDefinition(
        _ agent: AgentToolDefinition,
        overridingModel requestedModel: String?,
        effort requestedEffort: String? = nil
    ) throws -> AgentToolDefinition {
        let agent = try agentDefinition(agent, overridingModel: requestedModel)
        guard let requestedEffort else { return agent }
        let effort = requestedEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A word ("low", "xhigh"): each CLI checks its own levels.
        guard (1...16).contains(effort.count), effort.allSatisfy({ ("a"..."z").contains($0) }) else {
            throw CherryControlError(code: "invalid_effort", message: "Effort must be a level such as low, medium or high.")
        }
        let brand = AgentToolBrand.detect(name: nil, commandLine: agent.commandLine)
            ?? AgentToolBrand.detect(name: agent.name)
        guard let brand, brand.effortArguments(effort) != nil else {
            throw CherryControlError(
                code: "unsupported_effort_override",
                message: "Agent '\(agent.name)' does not support a per-launch effort."
            )
        }
        return agent.overridingEffort(effort, for: brand)
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
            return workspace.addAgentSession(agent: agent, projectRoot: projectRoot, select: false)
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
            // Reading the output can note output the loop had not read yet.
            observedNewOutput = observedNewOutput || ProcessIdleDetector.observedNewOutput(
                currentOutputVersion: session.outputVersion,
                sinceOutputVersion: sinceOutputVersion
            )
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
            // read at most once per `hostContentPollInterval`, a surface's
            // whole text when its visible screen changed (and every 0.5 s).
            // A reported `working` never ends the wait, so its screen is then
            // read only every 0.5 s.
            await session.refreshContentFromHostIfNeeded(maximumAge: session.hostContentPollInterval, recentOnly: true)
            session.watchContentForChanges(
                periodicallyOnly: session.kind == .agent && session.reportsProgramStatus
                    && session.agentActivityState == .working
            )
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
            if session.kind == .agent, session.reportsProgramStatus {
                // The agent says what it is doing (OSC 7501).
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
                    // Reported a moment after the message, `working` starts
                    // the turn: idle counts once it did, or after the start
                    // grace, and once its last output was drawn.
                    if contentIsQuiet, Self.agentTurnMayHaveEnded(session, now: now),
                       session.contentStayedUnchanged() {
                        return await result(reason: .idle)
                    }
                case .working, .unknown:
                    break
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
            ), session.contentStayedUnchanged() {
                // Quiet as far as the loop read: output its reads could not
                // see (`watchContentForChanges`) keeps the wait going.
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
            workspace.close(session, intent: .mcpClose)
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

    /// The agent a spawned agent is nested under (`tab`) and the one that
    /// owns its task (`owner`): the same agent, except one in another
    /// window, another project's included (an orchestrator handing a task
    /// to a worker in another project, `project_root`; the tool layer names
    /// the caller as the parent). That one owns the task, and the worker
    /// opens top-level in `workspace`: a sidebar nests only its own
    /// window's tabs.
    @MainActor
    private func spawnParent(from rawValue: String?, workspace: TerminalWorkspace) throws -> (tab: UUID?, owner: UUID?) {
        do {
            let parentID = try parentAgentID(from: rawValue, workspace: workspace)
            return (parentID, parentID)
        } catch let error as CherryControlError where error.code == "parent_agent_not_found" {
            guard let rawValue, let parentID = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let found = try? findSessionWithWorkspace(workspace: workspace, terminalID: parentID.uuidString),
                  found.workspace !== workspace,
                  callerReaches(found.session, in: found.workspace)
            else { throw error }
            guard found.session.kind == .agent else {
                throw CherryControlError(code: "parent_agent_not_agent", message: "parent_agent_id must refer to an agent session.")
            }
            mcpControlDebugLog("parent_agent_id=\(parentID.uuidString) is in another window: owns the task, worker top-level")
            return (nil, parentID)
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
        for session in sessions where callerReaches(session, in: owningWorkspace(of: session, from: workspace)) {
            session.restart()
        }
    }

    /// The window of `workspace`'s project that has `session`: a command's
    /// tab can be another window's (`TerminalWorkspace.addCommandSession`).
    /// `workspace` when none has it.
    @MainActor
    private func owningWorkspace(of session: TerminalSession, from workspace: TerminalWorkspace) -> TerminalWorkspace {
        ([workspace] + workspace.otherProjectWindows()).first { $0.sessions.contains { $0 === session } } ?? workspace
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
        let openRoots = Set(openProjectRootsProvider().map(CherryControl.standardizedProjectRoot))
        guard openRoots.count > 1 else { return }

        throw CherryControlError(
            code: "project_scope_required",
            message: "This Cherry tool mutates project-scoped data, but multiple Cherry projects are open and the request did not include a project scope. Relaunch the agent in an updated Cherry terminal or pass a scoped Cherry control request."
        )
    }

    private func requestRequiresProjectScope(_ request: CherryControlRequest) -> Bool {
        switch request {
        case .createTodo,
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

    /// The project's to-dos, and the one `workspace`'s window selects.
    @MainActor
    private func listTodos(todoStore: ProjectTodoStore, workspace: TerminalWorkspace) -> ListTodosResult {
        ListTodosResult(
            activeProjectRoot: todoStore.projectRoot,
            todos: todoStore.todos.map(todoInfo),
            selectedTodoID: chromeState(for: workspace)?.selectedTodoID?.uuidString
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
    private func findAgent(named requestedName: String) throws -> AgentToolDefinition {
        let normalizedName = AgentToolDefinition.normalizedName(requestedName)
        guard let agent = agentSettings.agents.first(where: { $0.normalizedName == normalizedName }) else {
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
        // Every window the server is given (`openWorkspacesProvider`, a
        // project's several windows each), then the app's registry's (a
        // test's server for one window still finds them).
        let candidates = openWorkspacesProvider() + ProjectWindowRegistry.shared.workspacesByProjectRoot().map(\.workspace)
        for openWorkspace in candidates
        where openWorkspace !== workspace && (device.map { Self.isOnDevice(openWorkspace.projectRoot, $0) } ?? true) {
            if let session = openWorkspace.session(id: terminalID),
               device.map({ Self.isSession(session, in: openWorkspace, onDevice: $0) }) ?? true {
                return (session, openWorkspace)
            }
        }
        throw CherryControlError(code: "terminal_not_found", message: "No Cherry terminal exists with id \(terminalID).")
    }

    /// The window a request scoped to `rawProjectRoot` goes to: of a
    /// project's several windows, the caller's own (`verifiedCallerSession`);
    /// else the active window when it is the project's, else the project's
    /// most recently active one, else that of the open project containing
    /// it.
    @MainActor
    private func scopedWorkspace(projectRoot rawProjectRoot: String) throws -> TerminalWorkspace {
        let projectRoot = CherryControl.standardizedProjectRoot(rawProjectRoot)
        if let callersWindow = callersWindow(ofProjectAt: projectRoot) {
            return callersWindow
        }
        if let activeWorkspace = workspaceProvider(),
           activeWorkspace.projectRoot.map(CherryControl.standardizedProjectRoot) == projectRoot {
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
            message: "Cherry project is not open for scoped request: \(rawProjectRoot). Open it first: cherry project open \(rawProjectRoot)"
        )
    }

    /// The caller's own window, when the project at `projectRoot` (or the
    /// open project containing it) has several and the caller is a tab of
    /// one of them. A project with one window looks up no caller.
    @MainActor
    private func callersWindow(ofProjectAt projectRoot: String) -> TerminalWorkspace? {
        let open = openWorkspaces()
        func windowsOfProject(at root: String) -> [TerminalWorkspace] {
            open.filter { $0.projectRoot.map(CherryControl.standardizedProjectRoot) == root }
        }
        var windows = windowsOfProject(at: projectRoot)
        if windows.isEmpty, let containing = containingOpenProjectRoot(for: projectRoot) {
            windows = windowsOfProject(at: containing)
        }
        guard windows.count > 1, let caller = verifiedCallerSession() else { return nil }
        return windows.first { $0.sessions.contains { $0 === caller } }
    }

    @MainActor
    private func containingOpenProjectRoot(for path: String) -> String? {
        openProjectRootsProvider()
            .map(CherryControl.standardizedProjectRoot)
            .filter { CherryControl.path(path, isInsideProjectRoot: $0) }
            .max { $0.count < $1.count }
    }

    @MainActor
    private func activeTodoStore(for workspace: TerminalWorkspace) throws -> ProjectTodoStore {
        guard let projectRoot = workspace.projectRoot else {
            throw CherryControlError(code: "project_unavailable", message: "The active Cherry workspace has no project.")
        }
        try requireTodosEnabled(projectRoot: projectRoot)
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
        ProjectFeatureAvailability(todosEnabled: agentSettings.projectFeatures(for: projectRoot).todosEnabled)
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
        if let activeWorkspace = workspaceProvider(), activeWorkspace.projectRoot == projectRoot {
            return chromeStateProvider()
        }
        return nil
    }

    /// The chrome state of the window that shows `workspace`
    /// (`chromeStateForWorkspaceProvider`, by identity: never another
    /// window of its project's); else, for a server told only its
    /// projects' chrome (tests), its project's.
    @MainActor
    private func chromeState(for workspace: TerminalWorkspace) -> ProjectWindowChromeState? {
        if let state = chromeStateForWorkspaceProvider(workspace) {
            return state
        }
        guard let projectRoot = workspace.projectRoot else {
            return nil
        }
        return chromeState(forProjectRoot: projectRoot)
    }

    @MainActor
    private func select(todo: ProjectTodo, workspace: TerminalWorkspace) {
        chromeState(for: workspace)?.selectTodo(id: todo.id)
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

    private func link(for todo: ProjectTodo) -> String {
        CherryDeepLink.todoURL(projectRoot: todo.projectRoot, todoID: todo.id)
    }

    @MainActor
    private func todoDetail(_ todo: ProjectTodo, in workspace: TerminalWorkspace) -> TodoDetailResult {
        TodoDetailResult(todo: todo, link: link(for: todo), selected: chromeState(for: workspace)?.selectedTodoID == todo.id)
    }

    @MainActor
    private func link(for session: TerminalSession, workspace: TerminalWorkspace) -> String? {
        guard let projectRoot = workspace.projectRoot else { return nil }
        return CherryDeepLink.terminalURL(projectRoot: projectRoot, terminalID: session.id)
    }

    private struct TerminalControlInput {
        let payload: Data
        let isRaw: Bool
    }

    @MainActor
    private func terminalInputPayload(text: String?, rawBase64: String?) throws -> TerminalControlInput {
        guard (text == nil) != (rawBase64 == nil),
              let input = try optionalTerminalInputPayload(text: text, rawBase64: rawBase64)
        else {
            throw CherryControlError(code: "invalid_input", message: "Provide exactly one of text or raw_base64.")
        }
        return input
    }

    /// Text or raw bytes (base64); nil when neither is given.
    @MainActor
    private func optionalTerminalInputPayload(text: String?, rawBase64: String?) throws -> TerminalControlInput? {
        switch (text, rawBase64) {
        case let (text?, nil):
            return .init(payload: TerminalInputEncoder.terminalTextData(text), isRaw: false)
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

    /// A terminal's input, and with `submit` (asked for explicitly: a
    /// terminal's text is not submitted by default) the Enter after it, on
    /// its own, as for an agent: text and Enter in one write read as a paste
    /// to a program that tells them apart (Claude Code in a terminal tab) or
    /// to a shell that brackets pastes, which then never runs the line.
    /// Returns the bytes sent.
    @MainActor
    private func sendTerminalInput(_ input: TerminalControlInput, submit: Bool, to session: TerminalSession) async throws -> Int {
        guard submit else {
            try await sendTerminalInput(input, to: session)
            return input.payload.count
        }
        if !input.payload.isEmpty {
            try await sendTerminalInput(input, to: session)
            try? await Task.sleep(for: Self.terminalSubmitPause)
        }
        let enter = TerminalInputEncoder.enterData
        try await deliver(enter, raw: false, to: session, alreadySent: input.payload.count)
        return input.payload.count + enter.count
    }

    /// Between a terminal's text and the Enter MCP submits it with.
    static let terminalSubmitPause: Duration = .milliseconds(150)

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
                to: session
            )
            guard let input, !input.isEmpty else { return 0 }
            return try await sendAgentInput(
                input,
                to: session,
                shouldDeferSubmit: shouldDeferSubmittedInput(for: session),
                source: "message"
            )
        }

        let input = try terminalInputPayload(text: text, rawBase64: rawBase64)
        return try await sendTerminalInput(input, submit: submit == true, to: session)
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
        /// A message of several lines in one paste: its Enter always goes
        /// on its own, after the paste (`agentMessagePaste`).
        var isPaste = false

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
        if shouldDeferSubmit || input.isPaste, input.submit {
            // The text, then its Enter on its own (`terminalSubmitPause`).
            return try await sendTerminalInput(.init(payload: input.payload, isRaw: false), submit: true, to: session)
        }

        var payload = input.payload
        if input.submit {
            payload.append(TerminalInputEncoder.enterData)
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
    /// letter such as `y`) typed into one approves the pending command. An
    /// agent that reports its status (OSC 7501) says when it is blocked on
    /// a permission or a question; for one that does not, its screen is read
    /// as it is now (from its host when no surface shows it, as for a
    /// restored agent whose adapter waits) for such a prompt. Input is
    /// refused, with nothing sent, while it waits on one. Raw keys sent
    /// without submit (`keysOnly`) are the caller's own answer and go
    /// through. When the screen cannot be read (its host does not answer),
    /// nothing is sent either.
    @MainActor
    private func refuseInputIntoPermissionPrompt(of session: TerminalSession, keysOnly: Bool) async throws {
        // A tab that takes no input says so when the input is sent.
        guard session.acceptsControlInput else { return }
        let name = processName(for: session)
        if session.reportsProgramStatus {
            guard !keysOnly else { return }
            switch session.agentActivityState {
            case .permission:
                throw Self.awaitingPermission(session: session, name: name, prompt: Self.shownPrompt(of: session))
            case .needsInput:
                throw Self.awaitingInput(session: session, name: name, prompt: Self.shownPrompt(of: session))
            case .unknown, .idle, .working, .error:
                return
            }
        }
        guard let lines = await session.programScreenLinesForInput() else {
            throw CherryControlError(
                code: "input_not_delivered",
                message: "Input for agent '\(name)' was not sent: its screen could not be read from its host, so Cherry cannot tell whether it is waiting for a permission answer. Nothing was sent."
            )
        }
        guard !keysOnly else { return }
        if AgentPermissionPrompt.isShowing(in: lines) {
            throw Self.awaitingPermission(session: session, name: name, prompt: AgentPromptMenu.read(from: lines))
        }
        if AgentQuestionPrompt.isShowing(in: lines) {
            throw Self.awaitingInput(session: session, name: name, prompt: AgentPromptMenu.read(from: lines))
        }
    }

    @MainActor
    private static func awaitingPermission(session: TerminalSession, name: String, prompt: AgentPromptInfo?) -> CherryControlError {
        mcpControlDebugLog("agent input refused at permission prompt session=\(session.id.uuidString)")
        return CherryControlError(
            code: "agent_awaiting_permission",
            message: "Agent '\(name)' is waiting for an answer to a permission prompt\(Self.programStatusDetail(of: session)); nothing was sent, so the prompt was not answered. Let the user answer it in Cherry, or pick one of its options with answer_prompt\(prompt == nil ? "" : " (they are in prompt)").",
            prompt: prompt
        )
    }

    @MainActor
    private static func awaitingInput(session: TerminalSession, name: String, prompt: AgentPromptInfo?) -> CherryControlError {
        // Enter picks the highlighted option of a question menu.
        mcpControlDebugLog("agent input refused at question menu session=\(session.id.uuidString)")
        return CherryControlError(
            code: "agent_awaiting_input",
            message: "Agent '\(name)' is asking the user a question\(Self.programStatusDetail(of: session)); nothing was sent, since Enter would pick the highlighted option. Let the user answer it, or pick one of its options with answer_prompt\(prompt == nil ? "" : " (they are in prompt)").",
            prompt: prompt
        )
    }

    // MARK: - answer_prompt

    /// Between the arrow keys answer_prompt types, and before its Enter.
    static let answerPromptKeyPause: Duration = .milliseconds(40)
    /// How long answer_prompt waits for the menu to show the option it
    /// moved to highlighted before it presses Enter.
    static let answerPromptHighlightWait: TimeInterval = 2

    /// Picks an option of the menu the agent shows: the menu is read off its
    /// screen again now (never an earlier read), the option found by its
    /// number or label, the highlight moved to it with arrow keys, and only
    /// once the screen shows it highlighted, Enter. Under the tab's typing
    /// lock, so no line Cherry types (a wake line, a nudge) goes between.
    @MainActor
    private func answerPrompt(_ request: AnswerPromptRequest, of session: TerminalSession) async throws -> AnswerPromptResult {
        let name = processName(for: session)
        guard session.kind == .agent else {
            throw CherryControlError(
                code: "not_agent_process",
                message: "answer_prompt answers an agent's menu; \(name) is kind \(session.kind.rawValue)."
            )
        }
        guard session.acceptsControlInput else {
            throw Self.inputError(for: .notAccepting(state: session.state.label), processName: name, totalBytes: 0)
        }
        await tasks.typingLocks.acquire(session.id)
        defer { tasks.typingLocks.release(session.id) }

        let prompt = try await promptToAnswer(of: session, name: name)
        let option: AgentPromptOption
        switch AgentPromptMenu.match(request.choice, in: prompt) {
        case .option(let found):
            option = found
        case .ambiguous(let found):
            throw CherryControlError(
                code: "ambiguous_choice",
                message: "\"\(request.choice.prefix(80))\" names several options of \(name)'s menu (\(AgentPromptMenu.describe(found))); nothing was sent. Give its number.",
                prompt: prompt
            )
        case .none:
            throw CherryControlError(
                code: "unknown_choice",
                message: "\(name)'s menu has no option \"\(request.choice.prefix(80))\"; nothing was sent. Its options: \(AgentPromptMenu.describe(prompt.options)).",
                prompt: prompt
            )
        }
        guard let highlighted = prompt.options.firstIndex(where: \.selected),
              let target = prompt.options.firstIndex(of: option)
        else {
            throw CherryControlError(
                code: "prompt_unreadable",
                message: "Cherry cannot tell which option of \(name)'s menu is highlighted, so it cannot move to \(option.number); nothing was sent. Send the keys with send_process_input (raw_base64, without submit), or let the user answer.",
                prompt: prompt
            )
        }

        var sent = 0
        if target != highlighted {
            let key = Data((target > highlighted ? "\u{1B}[B" : "\u{1B}[A").utf8)
            for _ in 0..<abs(target - highlighted) {
                try await deliver(key, raw: true, to: session, alreadySent: sent)
                sent += key.count
                try? await Task.sleep(for: Self.answerPromptKeyPause)
            }
            try await waitForHighlight(of: option, in: prompt, of: session, name: name)
        }
        let enter = TerminalInputEncoder.enterData
        try await deliver(enter, raw: false, to: session, alreadySent: sent)
        sent += enter.count
        mcpControlDebugLog("answer_prompt session=\(session.id.uuidString) option=\(option.number) bytes=\(sent)")
        let output = try await lifecycleOutput(for: session, waitMilliseconds: request.waitMilliseconds, lineLimit: request.lineLimit)
        return AnswerPromptResult(processID: session.id.uuidString, prompt: prompt, answered: option, sentBytes: sent, output: output)
    }

    /// The menu answer_prompt answers, read now: from the agent's screen (its
    /// host's when no surface shows it), and only while an agent that
    /// reports its status says it waits on one.
    @MainActor
    private func promptToAnswer(of session: TerminalSession, name: String) async throws -> AgentPromptInfo {
        if session.reportsProgramStatus {
            switch session.agentActivityState {
            case .permission, .needsInput:
                break
            case .unknown, .idle, .working, .error:
                throw CherryControlError(
                    code: "no_prompt",
                    message: "Agent '\(name)' reports \(session.agentActivityState.rawValue), not a permission or a question; nothing was sent."
                )
            }
        }
        guard let lines = await session.programScreenLinesForInput() else {
            throw CherryControlError(
                code: "input_not_delivered",
                message: "Cherry could not read agent '\(name)'s screen from its host, so it cannot see its menu; nothing was sent."
            )
        }
        guard let prompt = AgentPromptMenu.read(from: lines) else {
            throw CherryControlError(
                code: "no_prompt",
                message: "Agent '\(name)' shows no permission or question menu Cherry can read; nothing was sent. Read its screen with get_process_output."
            )
        }
        return prompt
    }

    /// Waits until the agent's screen shows `option` highlighted in the same
    /// menu; throws, with Enter not pressed, when the menu changed or the
    /// highlight did not get there.
    @MainActor
    private func waitForHighlight(of option: AgentPromptOption, in prompt: AgentPromptInfo, of session: TerminalSession, name: String) async throws {
        let deadline = Date().addingTimeInterval(Self.answerPromptHighlightWait)
        var shown: AgentPromptInfo?
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
            if let lines = await session.programScreenLinesForInput() {
                let read = AgentPromptMenu.read(from: lines)
                guard let read, read.options.map(\.label) == prompt.options.map(\.label) else {
                    throw CherryControlError(
                        code: "prompt_changed",
                        message: "\(name)'s menu changed while Cherry moved to option \(option.number); Enter was not pressed. Read its status again before answering.",
                        prompt: read
                    )
                }
                shown = read
                if read.options.first(where: \.selected)?.number == option.number { return }
            }
        } while Date() < deadline
        let highlighted = shown?.options.first(where: \.selected).map { "\($0.number)" } ?? "none"
        throw CherryControlError(
            code: "prompt_not_answered",
            message: "Cherry moved \(name)'s highlight toward option \(option.number), but the menu shows \(highlighted) highlighted; Enter was not pressed. Read its status and try again.",
            prompt: shown ?? prompt
        )
    }

    /// get_process_status's menu: for an agent that reports it waits on a
    /// permission or a question, its screen read now (its host's when no
    /// surface shows it); for one that reports nothing, the menu its screen
    /// shows as the tab last read it. None while an agent reports it waits
    /// for nothing (a menu left on screen is no question then).
    @MainActor
    private func statusPrompt(of session: TerminalSession) async -> AgentPromptInfo? {
        guard session.kind == .agent else { return nil }
        guard session.reportsProgramStatus else { return Self.shownPrompt(of: session) }
        switch session.agentActivityState {
        case .permission, .needsInput:
            return await session.programScreenLinesForInput().flatMap(AgentPromptMenu.read)
        case .unknown, .idle, .working, .error:
            return nil
        }
    }

    /// The menu an agent's screen shows, as the tab last read it (no read
    /// from its host): what events and status give, at no cost. Nil for a
    /// tab that is no agent, or a screen that shows no menu (yet).
    @MainActor
    static func shownPrompt(of session: TerminalSession) -> AgentPromptInfo? {
        guard session.kind == .agent else { return nil }
        let lineCount = session.lineCount
        guard lineCount > 0 else { return nil }
        return AgentPromptMenu.read(from: session.snapshot(range: max(0, lineCount - 60)..<lineCount))
    }

    /// What the agent says it waits for (its program status message), quoted
    /// as its own words.
    @MainActor
    private static func programStatusDetail(of session: TerminalSession) -> String {
        guard let message = session.programStatus.root?.message, !message.isEmpty else { return "" }
        return " (it reports: \"\(message.prefix(300))\")"
    }

    /// How long a task's first kickoff waits, after the agent's usual
    /// readiness, for its composer on a still screen.
    static let taskKickoffComposerWait: TimeInterval = 6

    /// Before a task's first kickoff into a CLI Cherry knows: its usual
    /// readiness (its startup prompt answered) with a full second of a
    /// still screen, then until it shows its composer on a screen still for
    /// a second (at most `taskKickoffComposerWait` more). A CLI can show its
    /// composer before it takes input (Claude Code while its MCP servers
    /// load), so the kickoff is checked after it is typed too
    /// (`checkKickoff`).
    @MainActor
    private func waitForTaskKickoffReadiness(session: TerminalSession, agent: AgentToolDefinition) async {
        guard shouldDeferInitialInput(for: agent) else { return }
        await waitForDeferredAgentInputReadiness(session: session, quietInterval: 1)
        let key = AgentScreenActivity.agentKey(name: agent.name, commandLine: agent.commandLine)
        let deadline = Date().addingTimeInterval(Self.taskKickoffComposerWait)
        while Date() < deadline {
            switch session.state {
            case .disconnected where session.isPersistentLocalSession && session.isRunning, .launching, .live:
                break
            case .exited, .failed, .disconnected:
                return
            }
            await session.refreshContentFromHostIfNeeded(maximumAge: session.hostContentPollInterval, recentOnly: true)
            let changedAt = session.lastContentChangeAt ?? session.startedAt ?? .distantPast
            if Date().timeIntervalSince(changedAt) >= 1 {
                // An agent that reports its status says when it is at its
                // composer; another's screen is read for it.
                if session.reportsProgramStatus {
                    if session.agentActivityState == .idle { return }
                } else {
                    let lines = terminalOutput(for: session, startLine: nil, lineLimit: 80).lines
                    if AgentScreenActivity.verdict(for: lines, agent: key, includesAnswerMenus: false) == .prompt { return }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func waitForDeferredAgentInputReadiness(session: TerminalSession, quietInterval: TimeInterval = 0.75) async {
        var startedAt = Date()
        // A session being created holds the wait no longer than this.
        let creationDeadline = startedAt.addingTimeInterval(30)
        let maximumWait: TimeInterval = 6
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
                        let enterSequence = TerminalInputEncoder.enterData
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

    /// An agent's input: text is submitted unless `submit` says otherwise,
    /// raw bytes only when it asks; never a second Enter after one the
    /// input ends with. Text of several lines is one paste
    /// (`agentMessagePaste`) and its Enter, so the agent gets one message
    /// instead of one per line.
    @MainActor
    private func agentInputPayload(
        text: String?,
        rawBase64: String?,
        submit: Bool?,
        to session: TerminalSession
    ) throws -> AgentInitialInput? {
        if let text, rawBase64 == nil,
           let paste = Self.agentMessagePaste(text, bracketed: session.bracketsAgentMessage) {
            return AgentInitialInput(payload: paste.payload, submit: (submit ?? true) || paste.endsWithNewline, isPaste: true)
        }
        guard let input = try optionalTerminalInputPayload(text: text, rawBase64: rawBase64) else { return nil }
        let wantsSubmit = submit ?? !input.isRaw
        let shouldSubmit = wantsSubmit && input.payload.last != 0x0d && input.payload.last != 0x0a
        return AgentInitialInput(payload: input.payload, submit: shouldSubmit)
    }

    /// A message of several lines as an agent gets it: its lines in one
    /// paste (bracketed unless the program has bracketed paste off, then
    /// with LF between them, a newline in an agent's composer, not
    /// Enter), without its trailing newlines, which `endsWithNewline`
    /// keeps. Nil for a message of one line (trailing newlines aside),
    /// which is typed as before.
    nonisolated static func agentMessagePaste(_ text: String, bracketed: Bool) -> (payload: Data, endsWithNewline: Bool)? {
        var body = Substring(text)
        while let last = body.last, last == "\n" || last == "\r" || last == "\r\n" { body.removeLast() }
        guard body.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return nil }
        return (
            TerminalInputEncoder.pastedTextData(String(body), bracketedPasteMode: bracketed),
            body.endIndex != text.endIndex
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

    private nonisolated static func writeResponse(_ response: CherryControlResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                // MSG_NOSIGNAL as well as SO_NOSIGPIPE: the kernel refuses
                // that option on a connection its peer already closed (a
                // client that connects and goes, as `UnixIO.hasListener`
                // does), and the answer's EPIPE would raise SIGPIPE.
                let written = send(fd, baseAddress.advanced(by: offset), data.count - offset, MSG_NOSIGNAL)
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
