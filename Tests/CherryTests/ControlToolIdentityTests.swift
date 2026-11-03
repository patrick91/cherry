@testable import Cherry
import CherryControl
import Darwin
import Foundation
import Testing

// Who may use the control socket. The client trusts only a socket of this
// user's, in a directory no one else may enter, answered by a process of
// this user's (Rust's `cherry_protocol` rules). The server never takes
// over a live socket and removes only the one it bound. A This Mac
// caller's processes are pinned, with when each started, as it connects,
// and its tab is the one whose program is among them still.

/// A new directory under /tmp (short enough for a socket path) with `mode`.
private func identityDirectory(mode: mode_t = 0o700) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/cherry-id-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    #expect(chmod(url.path, mode) == 0)
    return url
}

/// One request over `socketURL`, off the main thread.
private func identitySend(
    _ request: CherryControlRequest,
    socketURL: URL,
    credentials: CherryControlCredentials? = nil
) async throws -> CherryControlResponse {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result {
                try CherryControlClient(socketURL: socketURL, timeout: 5, credentials: credentials, controlMachine: "Laptop").send(request)
            })
        }
    }
}

/// The code of the error `request` over `socketURL` fails with (nil when it
/// is answered).
private func identityErrorCode(
    _ request: CherryControlRequest = .listTerminals,
    socketURL: URL,
    credentials: CherryControlCredentials? = nil
) async -> String? {
    do {
        let response = try await identitySend(request, socketURL: socketURL, credentials: credentials)
        return response.error?.code
    } catch let error as CherryControlError {
        return error.code
    } catch {
        return "\(error)"
    }
}

/// A socket bound at `path` and closed again: a server that went away left
/// it (nothing listens there).
private func identityStaleSocket(at path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    let bound = UnixIO.withSocketAddress(path: path) { Darwin.bind(fd, $0, $1) }
    try #require(bound == 0)
}

/// The project root the listing of `request`'s window names
/// (`listProcesses`' `activeProjectRoot`): where an unscoped request went.
@MainActor
private func identityRoutedRoot(
    _ server: CherryControlServer,
    callerChain: CherryControlServer.CallerProcessChain?
) async throws -> String? {
    let response = await server.handleRequestData(
        try JSONEncoder().encode(CherryControlRequest.listProcesses(.init())),
        callerChain: callerChain
    )
    guard case .listProcesses(let listed)? = response.result else {
        Issue.record("Expected listProcesses, got \(String(describing: response))")
        return nil
    }
    return listed.activeProjectRoot
}

private final class IdentityChainRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CherryControlServer.CallerProcessChain?] = []

    var chains: [CherryControlServer.CallerProcessChain?] { lock.withLock { recorded } }

    func record(_ chain: CherryControlServer.CallerProcessChain?) {
        lock.withLock { recorded.append(chain) }
    }
}

// MARK: - The client

/// The client refuses a socket in a directory others may enter, or one
/// reached through a linked directory, even while a server answers there;
/// it never takes that for Cherry being away.
@MainActor
@Test func controlToolIdentityClientRefusesADirectoryOthersMayEnterOrALinkedOne() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let socketURL = harness.socketURL
    let directory = socketURL.deletingLastPathComponent().path
    #expect(await identityErrorCode(socketURL: socketURL) == nil)

    #expect(chmod(directory, 0o755) == 0)
    #expect(await identityErrorCode(socketURL: socketURL) == "socket_not_private")
    // A caller on another Mac is told the same, never "not reachable".
    let credentials = CherryControlCredentials(token: "t", processID: UUID().uuidString)
    #expect(await identityErrorCode(socketURL: socketURL, credentials: credentials) == "socket_not_private")
    do {
        _ = try await identitySend(.listTerminals, socketURL: socketURL)
        Issue.record("Expected socket_not_private")
    } catch let error as CherryControlError {
        #expect(error.message.contains("\(directory) must be private (mode 0700, not 755)"), "\(error.message)")
    }
    #expect(chmod(directory, 0o700) == 0)
    #expect(await identityErrorCode(socketURL: socketURL) == nil)

    // A link to the private directory is not that directory.
    let link = "/tmp/cherry-id-link-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory)
    defer { try? FileManager.default.removeItem(atPath: link) }
    let linked = URL(fileURLWithPath: link).appendingPathComponent("control.sock")
    #expect(await identityErrorCode(socketURL: linked) == "socket_not_private")
}

/// A link to the socket inside a private directory is trusted (the fake
/// Mac's forward is one), as long as it leads to a socket of this user's;
/// a file that is no socket is refused.
@MainActor
@Test func controlToolIdentityClientFollowsALinkedSocketInAPrivateDirectory() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let directory = try identityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let linked = directory.appendingPathComponent("control.sock")
    try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: harness.socketURL.path)
    let response = try await identitySend(.listTerminals, socketURL: linked)
    guard case .listTerminals? = response.result else {
        Issue.record("Expected listTerminals, got \(String(describing: response))")
        return
    }

    let file = directory.appendingPathComponent("file.sock")
    try Data().write(to: file)
    #expect(await identityErrorCode(socketURL: file) == "socket_not_private")
}

/// Nothing at the path is Cherry not running, as before: `cherry_unavailable`
/// here, `cherry_unreachable` for a caller on another Mac.
@Test func controlToolIdentityClientSaysCherryIsAwayWhenNothingIsThere() async throws {
    let missing = URL(fileURLWithPath: "/tmp/cherry-id-missing-\(UUID().uuidString.prefix(8))/control.sock")
    #expect(await identityErrorCode(socketURL: missing) == "cherry_unavailable")
    let credentials = CherryControlCredentials(token: "t", processID: UUID().uuidString)
    #expect(await identityErrorCode(socketURL: missing, credentials: credentials) == "cherry_unreachable")

    // A private directory without a socket, or with one nothing listens on.
    let directory = try identityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketURL = directory.appendingPathComponent("control.sock")
    #expect(await identityErrorCode(socketURL: socketURL) == "cherry_unavailable")
    try identityStaleSocket(at: socketURL.path)
    #expect(await identityErrorCode(socketURL: socketURL) == "cherry_unavailable")
}

/// The directory checks, over `lstat` results (another account's
/// directory cannot be made in a test): a socket's own directory must be
/// a real directory of this user's that no one else may enter; the level
/// a derived path's namespaces share, one no one else may write to.
@Test func controlToolIdentityDirectoryChecksLookAtOwnerModeAndLinks() {
    func status(_ mode: mode_t, owner: uid_t = geteuid()) -> stat {
        var status = stat()
        status.st_mode = mode
        status.st_uid = owner
        return status
    }
    let path = "/tmp/cherry-\(getuid())"
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o700)) == nil)
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o755)) == "\(path) must be private (mode 0700, not 755)")
    #expect(UnixIO.directoryProblem(path, status: status(S_IFLNK | 0o755)) == "\(path) is not a real directory")
    #expect(UnixIO.directoryProblem(path, status: status(S_IFREG | 0o600)) == "\(path) is not a real directory")
    let otherOwner = geteuid() + 1
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o700, owner: otherOwner))?
        .hasPrefix("\(path) is owned by uid \(otherOwner), not this user") == true)

    // The shared level: readable by others, but writable by no one else.
    let shared = S_IWGRP | S_IWOTH
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o755), forbiddenModeBits: shared) == nil)
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o775), forbiddenModeBits: shared)
        == "\(path) must not be writable by other accounts (mode 775)")
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o1777), forbiddenModeBits: shared) != nil)
    #expect(UnixIO.directoryProblem(path, status: status(S_IFDIR | 0o755, owner: otherOwner), forbiddenModeBits: shared) != nil)
    #expect(UnixIO.directoryProblem(path, status: status(S_IFLNK | 0o755), forbiddenModeBits: shared) == "\(path) is not a real directory")

    // Only a derived path has a shared level the server checks.
    let derived = CherryControl.socketURL(environment: [:], executableURL: URL(fileURLWithPath: "/Applications/Cherry.app/Contents/MacOS/Cherry"))
    #expect(CherryControlServer.sharedSocketRoot(of: derived)?.path == path)
    #expect(CherryControlServer.sharedSocketRoot(of: URL(fileURLWithPath: "/tmp/cherry-control-1234/control.sock")) == nil)
    #expect(CherryControlServer.sharedSocketRoot(of: URL(fileURLWithPath: "\(path)/control.sock")) == nil)
}

/// A peer's uid, and a process's start in `cherry_protocol::start_identity`'s
/// format: the same each time, nil once there is no such process.
@Test func controlToolIdentityPeerAndStartIdentity() throws {
    var pair: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { pair.forEach { close($0) } }
    #expect(UnixIO.peerUserID(fileDescriptor: pair[0]) == geteuid())
    #expect(UnixIO.peerUserID(fileDescriptor: -1) == nil)

    let identity = try #require(UnixIO.processStartIdentity(getpid()))
    #expect(identity.wholeMatch(of: /\d+\.\d{6}/) != nil, "\(identity)")
    #expect(UnixIO.processStartIdentity(getpid()) == identity)
    #expect(HostedAdapterProcess.startIdentity(of: getpid()) == identity)
    #expect(UnixIO.processStartIdentity(getppid()) != nil)
    // Root's processes too (launchd; a native tab's login(1)), which
    // proc_pidinfo does not describe to this user.
    let launchd = try #require(UnixIO.processStartIdentity(1))
    #expect(launchd.wholeMatch(of: /\d+\.\d{6}/) != nil, "\(launchd)")
    #expect(UnixIO.processStartIdentity(1) == launchd)

    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try exited.run()
    exited.waitUntilExit()
    #expect(UnixIO.processStartIdentity(exited.processIdentifier) == nil)
    // A peer gone before it was pinned is no caller.
    #expect(CherryControlServer.CallerProcessChain.pinned(peer: exited.processIdentifier) == nil)
    #expect(CherryControlServer.CallerProcessChain.pinned(peer: getpid())?.pids.first == getpid())
    #expect(UnixIO.processStartIdentity(Int32.max) == nil)
    #expect(UnixIO.processStartIdentity(0) == nil)
}

// MARK: - The server's socket

/// A second server on a running one's path does not listen: the first
/// still answers, also after the second was stopped and released (it
/// leaves the first's socket file in place).
@MainActor
@Test func controlToolIdentitySecondServerNeverTakesOverALiveSocket() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let socketURL = harness.socketURL
    let firstSocket = try #require(UnixIO.FileIdentity(path: socketURL.path))

    func routedRoot() async throws -> String? {
        let response = try await identitySend(.listProcesses(.init()), socketURL: socketURL)
        guard case .listProcesses(let listed)? = response.result else {
            Issue.record("Expected listProcesses, got \(String(describing: response))")
            return nil
        }
        return listed.activeProjectRoot
    }
    #expect(try await routedRoot() == harness.workspace.projectRoot)

    let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let otherWindow = TerminalWorkspace(projectRoot: otherRoot.path, createInitialSession: false)
    var second: CherryControlServer? = CherryControlServer(
        workspace: otherWindow,
        socketURL: socketURL,
        agentSettings: harness.settings,
        taskBoard: AgentTaskBoard()
    )
    second?.start()
    #expect(UnixIO.FileIdentity(path: socketURL.path) == firstSocket)
    #expect(try await routedRoot() == harness.workspace.projectRoot)

    second?.stop()
    second = nil
    #expect(UnixIO.FileIdentity(path: socketURL.path) == firstSocket)
    #expect(try await routedRoot() == harness.workspace.projectRoot)

    // The first removes its own socket when it stops.
    harness.server.stop()
    #expect(!FileManager.default.fileExists(atPath: socketURL.path))
}

/// A socket file nothing listens on (a server that went away left it) is
/// replaced; a file at the path that is no socket is never removed, and
/// the server does not listen.
@MainActor
@Test func controlToolIdentityServerReplacesOnlyAStaleSocket() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    let socketURL = harness.socketURL
    try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try identityStaleSocket(at: socketURL.path)
    harness.server.start()
    #expect(await identityErrorCode(socketURL: socketURL) == nil)
    harness.server.stop()

    try Data("not a socket".utf8).write(to: socketURL)
    let blocked = CherryControlServer(
        workspace: harness.workspace,
        socketURL: socketURL,
        agentSettings: harness.settings,
        taskBoard: AgentTaskBoard()
    )
    blocked.start()
    blocked.stop()
    #expect(try Data(contentsOf: socketURL) == Data("not a socket".utf8))
}

/// Whether a server listens: a stale socket file or none says no at once;
/// a live server, or one that never accepts, says yes. Clients that come
/// and go before the server accepts them (as such a probe of an older
/// Cherry would) never raise SIGPIPE answering them.
@MainActor
@Test func controlToolIdentityProbesAndClientsThatLeaveAtOnceAreSafe() async throws {
    let directory = try identityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = directory.appendingPathComponent("stale.sock").path
    #expect(!UnixIO.hasListener(atPath: stale))
    try identityStaleSocket(at: stale)
    #expect(!UnixIO.hasListener(atPath: stale))

    // Listening, never accepting: counts as live, after the timeout.
    let hung = directory.appendingPathComponent("hung.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(UnixIO.withSocketAddress(path: hung) { Darwin.bind(fd, $0, $1) } == 0)
    try #require(listen(fd, 4) == 0)
    let started = Date()
    #expect(UnixIO.hasListener(atPath: hung, timeout: 0.1))
    #expect(Date().timeIntervalSince(started) < 2)

    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let socketURL = harness.socketURL
    for _ in 0..<20 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        _ = UnixIO.withSocketAddress(path: socketURL.path) { Darwin.connect(client, $0, $1) }
        close(client)
    }
    for _ in 0..<5 {
        #expect(UnixIO.hasListener(atPath: socketURL.path))
    }
    #expect(await identityErrorCode(socketURL: socketURL) == nil)
}

/// A listener whose backlog is full refuses a connection as a stale socket
/// file does (ECONNREFUSED): the probe tries again within its timeout, as a
/// busy server accepts what waited, so it is never taken for a stale one.
@Test func controlToolIdentityProbeWaitsOutAFullBacklog() throws {
    let directory = try identityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("busy.sock").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { close(listener) }
    try #require(UnixIO.withSocketAddress(path: path) { Darwin.bind(listener, $0, $1) } == 0)
    try #require(listen(listener, 1) == 0)

    // Fill its backlog until a connection is refused.
    var queued: [Int32] = []
    defer { queued.forEach { close($0) } }
    var refused = false
    for _ in 0..<8 where !refused {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        if UnixIO.withSocketAddress(path: path, { Darwin.connect(client, $0, $1) }) == 0 {
            queued.append(client)
        } else {
            refused = errno == ECONNREFUSED
            close(client)
        }
    }
    try #require(refused, "the backlog never filled")

    // It accepts a moment later, as a busy server does.
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        let end = Date().addingTimeInterval(1)
        while Date() < end {
            let accepted = accept(listener, nil, nil)
            if accepted >= 0 { close(accepted) } else { usleep(5_000) }
        }
        done.signal()
    }
    #expect(UnixIO.hasListener(atPath: path, timeout: 0.5))
    done.wait()
}

/// The server makes its directory private: one of this user's that others
/// may enter is closed first; a linked directory is refused, and nothing
/// listens.
@MainActor
@Test func controlToolIdentityServerClosesItsDirectoryAndRefusesALink() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    let directory = try identityDirectory(mode: 0o755)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = harness.workspace
    let socketURL = directory.appendingPathComponent("control.sock")
    let server = CherryControlServer(workspace: workspace, socketURL: socketURL, agentSettings: harness.settings, taskBoard: AgentTaskBoard())
    server.start()
    defer { server.stop() }
    var status = stat()
    #expect(lstat(directory.path, &status) == 0 && status.st_mode & 0o777 == 0o700)
    #expect(await identityErrorCode(socketURL: socketURL) == nil)

    let link = "/tmp/cherry-id-link-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory.path)
    defer { try? FileManager.default.removeItem(atPath: link) }
    let linkedURL = URL(fileURLWithPath: link).appendingPathComponent("other.sock")
    let linked = CherryControlServer(workspace: workspace, socketURL: linkedURL, agentSettings: harness.settings, taskBoard: AgentTaskBoard())
    linked.start()
    defer { linked.stop() }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.sock").path))
}

/// The app's socket: `CHERRY_CONTROL_SOCKET` when nothing answers there (a
/// private run's fresh path), else the derived path, never a live socket
/// it inherited (a Cherry started from a Cherry tab).
@MainActor
@Test func controlToolIdentityAppSocketNeverTakesALiveInheritedSocket() async throws {
    let executable = URL(fileURLWithPath: "/Applications/Cherry Identity.app/Contents/MacOS/Cherry")
    let derived = CherryControl.socketURL(environment: [:], executableURL: executable)
    let key = CherryControl.socketEnvironmentKey
    #expect(CherryControlServer.appSocketURL(environment: [:], executableURL: executable) == derived)
    #expect(CherryControlServer.appSocketURL(environment: [key: "  "], executableURL: executable) == derived)

    let directory = try identityDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fresh = directory.appendingPathComponent("control.sock")
    #expect(CherryControlServer.appSocketURL(environment: [key: fresh.path], executableURL: executable).path == fresh.path)
    try identityStaleSocket(at: fresh.path)
    #expect(CherryControlServer.appSocketURL(environment: [key: " \(fresh.path)\n"], executableURL: executable).path == fresh.path)

    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let live = harness.socketURL.path
    #expect(CherryControlServer.appSocketURL(environment: [key: live], executableURL: executable) == derived)
    // The namespace still applies to the derived path.
    let namespace = CherryControl.socketNamespaceEnvironmentKey
    #expect(CherryControlServer.appSocketURL(environment: [key: live, namespace: "Identity Test"], executableURL: executable)
        == CherryControl.socketURL(environment: [namespace: "Identity Test"], executableURL: executable))
}

/// A device's listener replaces only a stale socket: another server's live
/// listener for that device keeps its forward, also after that server is
/// stopped; each removes only the socket it bound. Its callers are checked
/// for their account and get no process chain (no pid crosses machines).
@MainActor
@Test func controlToolIdentityDeviceListenerNeverTakesOverALiveSocket() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    let recorder = IdentityChainRecorder()
    harness.server.acceptedCallerChainForTesting = { recorder.record($0) }
    let deviceID = UUID()
    let listener = try harness.server.addDeviceListener(deviceID: deviceID)
    let firstSocket = try #require(UnixIO.FileIdentity(path: listener.path))
    #expect(await identityErrorCode(socketURL: listener) == "unauthorized")
    #expect(!recorder.chains.isEmpty && recorder.chains.allSatisfy { $0 == nil })

    let second = CherryControlServer(
        workspace: harness.workspace,
        socketURL: harness.socketURL.deletingLastPathComponent().appendingPathComponent("second.sock"),
        agentSettings: harness.settings,
        taskBoard: AgentTaskBoard()
    )
    #expect(second.deviceListenerURL(deviceID: deviceID) == listener)
    do {
        try second.addDeviceListener(deviceID: deviceID)
        Issue.record("Expected socket_in_use")
    } catch let error as CherryControlError {
        #expect(error.code == "socket_in_use", "\(error.message)")
    }
    second.removeDeviceListener(deviceID: deviceID)
    second.stop()
    #expect(UnixIO.FileIdentity(path: listener.path) == firstSocket)
    #expect(await identityErrorCode(socketURL: listener) == "unauthorized")

    harness.server.removeDeviceListener(deviceID: deviceID)
    #expect(!FileManager.default.fileExists(atPath: listener.path))
    try identityStaleSocket(at: listener.path)
    #expect(try harness.server.addDeviceListener(deviceID: deviceID) == listener)
    #expect(await identityErrorCode(socketURL: listener) == "unauthorized")
    #expect(recorder.chains.allSatisfy { $0 == nil })
}

// MARK: - The caller's processes

/// Each connection's caller chain is pinned as it is accepted, before its
/// request is read: the connecting process and its parents, each with
/// its start.
@MainActor
@Test func controlToolIdentityCallerChainIsPinnedWhenItConnects() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    let recorder = IdentityChainRecorder()
    harness.server.acceptedCallerChainForTesting = { recorder.record($0) }
    harness.server.start()

    // Connected, nothing sent yet.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    let connected = UnixIO.withSocketAddress(path: harness.socketURL.path) { Darwin.connect(fd, $0, $1) }
    try #require(connected == 0)
    #expect(await eventually(timeout: 5) { recorder.chains.count == 1 })
    let chain = try #require(recorder.chains.first ?? nil)
    let ancestry = CherryControl.processAncestry(of: getpid(), maxDepth: 20)
    #expect(chain.pids == ancestry)
    #expect(chain.pids.first == getpid())
    #expect(chain.startIdentities == ancestry.map(UnixIO.processStartIdentity))
    #expect(chain.startIdentities.first == UnixIO.processStartIdentity(getpid()))
    #expect(chain.startIdentities.first != nil)

    // A request's own connection is pinned the same way.
    #expect(await identityErrorCode(socketURL: harness.socketURL) == nil)
    #expect(recorder.chains.count == 2)
    #expect(recorder.chains.last == chain)
}

/// A chain matches the tab whose program is among its processes, unless
/// that pid's process started at another time than when it was pinned
/// (the caller exited and its pid went to another process); an unknown
/// start still matches.
@MainActor
@Test func controlToolIdentityCallerSessionMatchesOnlyTheProcessesPinned() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let agent = try await harness.spawnAgent(named: "Pinned")
    #expect(await eventually(timeout: 5) { agent.programProcessID != nil })
    let pid = try #require(agent.programProcessID)
    let started = try #require(UnixIO.processStartIdentity(pid))
    typealias Chain = CherryControlServer.CallerProcessChain

    let match = CherryControlServer.callerSession(
        matching: Chain(pids: [Int32.max, pid, getpid()], startIdentities: [nil, started, nil]),
        in: [harness.workspace]
    )
    #expect(match?.session === agent)
    #expect(match?.workspace === harness.workspace)

    let reused = Chain(pids: [pid], startIdentities: ["1.000000"])
    #expect(CherryControlServer.callerSession(matching: reused, in: [harness.workspace]) == nil)
    #expect(!reused.contains(pid))
    // Unknown either way: the pid stands.
    #expect(CherryControlServer.callerSession(matching: Chain(pids: [pid], startIdentities: [nil]), in: [harness.workspace])?.session === agent)
    #expect(reused.contains(pid, currentStartIdentity: { _ in nil }))
    #expect(CherryControlServer.callerSession(matching: Chain(pids: [Int32.max], startIdentities: [nil]), in: [harness.workspace]) == nil)
    #expect(CherryControlServer.callerSession(matching: Chain(pids: [pid], startIdentities: [started]), in: []) == nil)
}

/// Without a test resolver, the verified caller and the window of an
/// unscoped request come from the pinned chain: its tab's agent defaults,
/// task lookups and routing; a chain whose pid went to another process
/// reaches none of them.
@MainActor
@Test func controlToolIdentityVerifiedCallerAndItsWindowComeFromTheChain() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let agent = try await harness.spawnAgent(named: "Caller")
    #expect(await eventually(timeout: 5) { agent.programProcessID != nil })
    let pid = try #require(agent.programProcessID)
    let pinned = try #require(CherryControlServer.CallerProcessChain.pinned(peer: pid))
    #expect(pinned.pids.first == pid && pinned.pids.contains(getpid()))
    let reused = CherryControlServer.CallerProcessChain(pids: pinned.pids, startIdentities: ["1.000000"] + pinned.startIdentities.dropFirst())

    #expect(CherryControlServer.$callerProcessChain.withValue(pinned) { harness.server.verifiedCallerSession() } === agent)
    #expect(CherryControlServer.$callerProcessChain.withValue(reused) { harness.server.verifiedCallerSession() } == nil)
    #expect(harness.server.verifiedCallerSession() == nil)

    // A tool call's defaults, end to end through the request path.
    func whoami(_ chain: CherryControlServer.CallerProcessChain?) async throws -> JSONValue? {
        let response = await harness.server.handleRequestData(
            try JSONEncoder().encode(CherryControlRequest.callTool(.init(name: "whoami", arguments: [:], context: nil))),
            callerChain: chain
        )
        guard case .callTool(let result)? = response.result else {
            Issue.record("Expected callTool, got \(String(describing: response))")
            return nil
        }
        return result.structured?.objectValue?["callerProcessID"]
    }
    #expect(try await whoami(pinned) == .string(agent.id.uuidString))
    #expect(try await whoami(reused) == nil)
    #expect(try await whoami(nil) == nil)

    // Tasks: the caller's own tab has none, which only a verified caller hears.
    func myTask(_ chain: CherryControlServer.CallerProcessChain?) async throws -> String? {
        let response = await harness.server.handleRequestData(try JSONEncoder().encode(CherryControlRequest.getMyTask), callerChain: chain)
        return response.error?.message
    }
    #expect(try await myTask(pinned)?.hasPrefix("This tab has no Cherry task") == true)
    #expect(try await myTask(reused)?.hasPrefix("Cherry could not tell which of its tabs") == true)

    // Routing: an unscoped request goes to the caller's window, else the
    // active one.
    let frontRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: frontRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: frontRoot) }
    let front = TerminalWorkspace(projectRoot: frontRoot.path, createInitialSession: false)
    let windows = [front, harness.workspace]
    _ = harness.settings.addProject(path: frontRoot.path)
    let routing = CherryControlServer(
        workspaceProvider: { front },
        todoStoreProvider: { nil },
        chromeStateProvider: { nil },
        workspaceForProjectRootProvider: { root in windows.first { $0.projectRoot == root } },
        todoStoreForProjectRootProvider: { _ in nil },
        chromeStateForProjectRootProvider: { _ in nil },
        openProjectRootsProvider: { windows.compactMap(\.projectRoot) },
        openWorkspacesProvider: { windows },
        socketURL: harness.socketURL.deletingLastPathComponent().appendingPathComponent("routing.sock"),
        agentSettings: harness.settings,
        taskBoard: AgentTaskBoard()
    )
    #expect(try await identityRoutedRoot(routing, callerChain: pinned) == harness.workspace.projectRoot)
    #expect(try await identityRoutedRoot(routing, callerChain: reused) == front.projectRoot)
    #expect(try await identityRoutedRoot(routing, callerChain: nil) == front.projectRoot)
}
