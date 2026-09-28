import CherryControl
import Foundation
import Testing
@testable import Cherry

// Tabs of another Mac's host (a device, docs/specs/remote-devices.md), here
// against the in-process fake `cherry control` (FakeControlHelper) for an
// SSH host and the fake attach adapter (HostedSessionFakeCLI). No ssh runs.

/// A workspace of a project on another Mac whose tabs run on a fake SSH
/// host's `PersistentHostSessions.remote(…)`.
@MainActor
private final class RemoteHarness {
    let fake = FakeControlHelper()
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let hosting: PersistentHostSessions
    let status = PersistentSessionsStatus()
    let installationID = UUID()
    let deviceID = UUID()
    let host: HostedSessionHost
    private let suite: String

    init(configuration: PersistentHostSessions.Configuration = RemoteHarness.fastConfiguration) throws {
        cli = try HostedSessionFakeCLI()
        suite = "CherryTests.PersistentRemote.\(UUID().uuidString)"
        host = try HostedSessionHost.ssh("studio")
        let hostStore = HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let executable = cli.executable
        control = HostControl(
            host: host,
            clientProvider: {
                HostedSessionClient(
                    executableURL: executable,
                    // This Mac's login environment: only its locale may reach
                    // the other Mac.
                    loginEnvironment: { _ in .init(environment: [
                        "SSH_AUTH_SOCK": "/login/agent.sock", "PATH": "/login/bin:/usr/bin", "HOME": "/Users/local",
                        "LANG": "it_IT.UTF-8", "LC_CTYPE": "it_IT.UTF-8", "SHELL": "/opt/homebrew/bin/fish"
                    ]) }
                )
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        let control = control
        hosting = PersistentHostSessions.remote(
            profile: .remote(host: host, displayName: "Studio", machineNames: ["studio.local"]),
            installationID: installationID,
            remoteShell: "/bin/zsh",
            control: { control },
            installationUnavailableReason: { nil },
            status: status,
            instanceLock: nil,
            terminalColors: { nil },
            configuration: configuration
        )
    }

    static let fastConfiguration: PersistentHostSessions.Configuration = {
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.terminationTimeout = .seconds(3)
        configuration.restartExitTimeout = .seconds(3)
        configuration.reconnectDelay = (0.05, 0.2)
        configuration.lostCreateChecks = [.milliseconds(200)]
        return configuration
    }()

    var projectKey: String { ProjectLocation.remote(deviceID: deviceID, path: "/Users/me/work/app").key }

    /// A workspace whose settings keep local tabs native: the device's
    /// hosting runs its tabs whatever they say.
    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(
            projectRoot: projectKey,
            createInitialSession: false,
            backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: hosting)
        )
    }

    func creates() -> [FakeControlHelper.Request] { fake.requests("create") }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private func json(_ request: FakeControlHelper.Request, _ key: String) -> [String: String] {
    request.json[key] as? [String: String] ?? [:]
}

@Test @MainActor func aRemoteProjectsTabsRunOnItsHostWithTheRemoteLaunchSpecAndADistinctOwner() async throws {
    let harness = try RemoteHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    #expect(workspace.projectRoot == harness.projectKey)
    #expect(workspace.launchRoot == "/Users/me/work/app")

    // Persistent on the device although local tabs are set to run natively.
    let terminal = workspace.addSession(title: "Build")
    #expect(terminal.isPersistentLocalSession)
    #expect(terminal.projectRoot == harness.projectKey)
    #expect(await harness.fake.wait { terminal.persistentSession != nil })
    #expect(terminal.persistentSession?.host == harness.host)

    let create = try #require(harness.creates().first)
    // The installation's own owner: the other Mac's Cherry never adopts it.
    let owner = PersistentHostSessions.remoteOwner(installationID: harness.installationID)
    #expect(create.string("owner") == owner)
    #expect(owner == "\(PersistentHostSessions.appOwner)@\(harness.installationID.uuidString)")
    #expect(owner != PersistentHostSessions.appOwner)
    // The host runs the account's login shell; the directory is the path
    // there, never looked for (or replaced by the home directory) here.
    #expect(create.json["command"] as? [String] == [])
    #expect(create.string("cwd") == "/Users/me/work/app")
    let environment = json(create, "env")
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
    #expect(environment["CHERRY_PROCESS_ID"] == terminal.id.uuidString)
    #expect(environment["CHERRY_PROJECT_ROOT"] == "/Users/me/work/app")
    #expect(environment["LANG"] == "it_IT.UTF-8")
    #expect(environment["LC_CTYPE"] == "it_IT.UTF-8")
    for key in ["PATH", "HOME", "SHELL", "SSH_AUTH_SOCK", "CHERRY_CONTROL_SOCKET", "TERMINFO", "ZDOTDIR",
                "GHOSTTY_RESOURCES_DIR", "CHERRY_BOOTSTRAP_ZDOTDIR"] {
        #expect(environment[key] == nil, "\(key)")
    }
    // The project's tag is its key.
    #expect(json(create, "tags")[PersistentSessionTag.project] == harness.projectKey)

    // A command runs through the other Mac's login shell, with its own
    // variables but never a local PATH or control socket.
    let command = workspace.addCommandSession(
        command: ProjectCommandDefinition(
            name: "server", command: "npm", arguments: "run dev", workingDirectory: "web",
            environment: ["PORT": "8000", "PATH": "/local/bin", "CHERRY_CONTROL_SOCKET": "/tmp/cherry.sock"]
        ),
        projectRoot: harness.projectKey
    )
    #expect(await harness.fake.wait { command.persistentSession != nil })
    let commandCreate = try #require(harness.creates().first { json($0, "tags")[PersistentSessionTag.tab] == command.id.uuidString })
    #expect(commandCreate.json["command"] as? [String] == ["/bin/zsh", "-l", "-c", "npm run dev"])
    #expect(commandCreate.string("cwd") == "/Users/me/work/app/web")
    #expect(json(commandCreate, "env")["PORT"] == "8000")
    #expect(json(commandCreate, "env")["PATH"] == nil)
    #expect(json(commandCreate, "env")["CHERRY_CONTROL_SOCKET"] == nil)
}

@Test @MainActor func aRemoteTabNeverTakesItsHostsPidForALocalProcess() async throws {
    let harness = try RemoteHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let terminal = workspace.addSession()
    #expect(await harness.fake.wait { terminal.persistentSession != nil })
    // The fake host reports pid 42 for every session: a pid of the other
    // Mac, which names nothing (or something else) here.
    let sessionID = try #require(terminal.persistentSession?.sessionID)
    #expect(harness.hosting.sessionInfo(sessionID)?.pid == 42 || harness.fake.sessions.first?.pid == 42)
    #expect(terminal.hostedProgramProcessID == nil)
    #expect(terminal.programProcessID == nil)
    #expect(!terminal.reportsLocalWorkingDirectory)
    // Nor from a later report.
    let info = try #require(harness.fake.sessions.first { $0.id == sessionID })
    terminal.persistentSessionDidChange(info)
    #expect(terminal.hostedProgramProcessID == nil)
}

@Test @MainActor func aRemoteTabThatCannotStartSaysSoAndNeverRunsALocalShell() async throws {
    let harness = try RemoteHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let limit = "host session limit reached"
    harness.fake.respond = { request, _ in
        request.op == "create" ? .answer(.error(code: "request_failed", message: limit)) : nil
    }
    let tab = workspace.addSession()
    #expect(await harness.fake.wait { tab.persistentLaunchFailureReason != nil })
    #expect(tab.persistentLaunchFailureReason?.hasPrefix("Couldn't start on Studio: ") == true)
    #expect(tab.persistentLaunchFailureReason?.contains(limit) == true)
    #expect(tab.state == .failed(try #require(tab.persistentLaunchFailureReason)))
    // Still the device's tab, not running, not native.
    #expect(tab.isPersistentLocalSession)
    #expect(!tab.isRunning)
    #expect(!tab.usesNativePTYBackend)
    #expect(tab.persistentFallbackReason == nil)
    #expect(tab.persistentSession == nil)
    #expect(harness.status.lastLaunchFailure?.contains(limit) == true)
    // Nothing takes input now: no local shell runs.
    await #expect(throws: (any Error).self) { try await tab.sendControlInput(Data("ls\n".utf8), raw: false) }

    // Retry tries the same host, and the tab runs there once it can.
    harness.fake.respond = nil
    #expect(tab.retryPersistentSession())
    #expect(await harness.fake.wait { tab.persistentSession != nil })
    #expect(tab.persistentLaunchFailureReason == nil)
    #expect(tab.isRunning)
    #expect(harness.creates().count == 2)
    #expect(!tab.retryPersistentSession())

    // A new tab while the host cannot be reached is still the device's.
    harness.fake.launchFailure = "ssh: connect to host studio port 22: Operation timed out"
    harness.control.disconnect()
    let second = workspace.addSession()
    #expect(second.isPersistentLocalSession)
    #expect(await harness.fake.wait(timeout: 10) { second.persistentLaunchFailureReason != nil })
    #expect(second.persistentLaunchFailureReason?.hasPrefix("Couldn't start on Studio: ") == true)
    #expect(!second.isRunning)
    #expect(second.persistentFallbackReason == nil)
    #expect(workspace.backendPolicy.persistentHostingForNewTab() === harness.hosting)
}

@Test @MainActor func aRemoteTabWaitsForItsHostLongerAndThenFailsWithoutFallback() async throws {
    #expect(PersistentHostSessions.Configuration.remote.creationTimeout == 45)
    #expect(PersistentHostSessions.Configuration().creationTimeout == 14)
    var configuration = RemoteHarness.fastConfiguration
    configuration.creationTimeout = 0.4
    let harness = try RemoteHarness(configuration: configuration)
    harness.fake.respond = { request, _ in request.op == "create" ? .silence : nil }
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.fake.wait { harness.creates().count == 1 })
    // MCP input while the session is created waits for it, and is reported
    // undelivered when it never comes (never typed into a local shell).
    let input = Task { @MainActor in try await tab.sendControlInput(Data("ls\n".utf8), raw: false) }
    #expect(await harness.fake.wait(timeout: 5) { tab.persistentLaunchFailureReason != nil })
    if case .success = await input.result { Issue.record("the input was delivered") }
    #expect(tab.persistentLaunchFailureReason?.contains("The session host on Studio did not start a session within") == true)
    #expect(tab.isPersistentLocalSession)
    #expect(!tab.isRunning)
    #expect(tab.persistentFallbackReason == nil)
    // The Create answers later: its session is ended, the tab stays failed.
    harness.fake.respond = nil
    await TerminalSession.waitForPersistentLaunches(upTo: .seconds(20))
    #expect(tab.persistentSession == nil)
}

@Test @MainActor func thisMacsHostingNeverAdoptsARemoteOwnersSessionNorDoesTheRemoteOneAdoptThisMacs() {
    let installation = UUID()
    let remoteOwner = PersistentHostSessions.remoteOwner(installationID: installation)
    let local = PersistentHostSessions(
        owner: PersistentHostSessions.appOwner,
        control: { Issue.record("no connection"); return HostControlRegistry.shared.control(for: .local) },
        installationUnavailableReason: { nil },
        status: PersistentSessionsStatus()
    )
    let theirs = HostedSessionInfo(
        id: "s1", name: "Shell", cwd: "/Users/me", command: [], cols: 80, rows: 24, state: .running,
        pid: 7, exitCode: nil, owner: remoteOwner, tags: [PersistentSessionTag.tab: UUID().uuidString]
    )
    // The other Mac's own Cherry sees this installation's session as foreign.
    #expect(!local.canAdopt(theirs))
    #expect(PersistentHostSessions.tabID(of: theirs, owner: PersistentHostSessions.appOwner) == nil)
    let own = HostedSessionInfo(
        id: "s2", name: "Shell", cwd: "/Users/me", command: [], cols: 80, rows: 24, state: .running,
        pid: 7, exitCode: nil, owner: PersistentHostSessions.appOwner, tags: [:]
    )
    #expect(local.canAdopt(own))
    #expect(local.profile.isThisMac && local.profile.allowsNativeFallback)
    // The same installation always has the same owner; another one another.
    #expect(PersistentHostSessions.remoteOwner(installationID: installation) == remoteOwner)
    #expect(PersistentHostSessions.remoteOwner(installationID: UUID()) != remoteOwner)
}

@Test @MainActor func theHostingRegistryEndsAndWaitsOnEveryHost() async throws {
    let harness = try RemoteHarness()
    defer { harness.cleanUp() }
    let local = PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())
    let registry = PersistentHostingRegistry(local: local)
    registry.register(harness.hosting)
    #expect(registry.all.count == 2)
    #expect(registry.hosting(for: .local) === local)
    #expect(registry.hosting(for: harness.host) === harness.hosting)
    #expect(await registry.waitForPendingEnds(timeout: .milliseconds(100)))
    registry.unregister(harness.host)
    #expect(registry.remote.isEmpty)
}

@Test @MainActor func aNewRemoteTabStartsWhereTheSelectedTabOfTheSameHostIsElseInTheLaunchRoot() async throws {
    let harness = try RemoteHarness()
    let workspace = harness.workspace()
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let first = workspace.addSession()
    #expect(await harness.fake.wait { first.persistentSession != nil })
    #expect(first.workingDirectory == "/Users/me/work/app")
    // Its program reports a directory on the device (OSC 7 names it).
    let sessionID = try #require(first.persistentSession?.sessionID)
    let info = try #require(harness.fake.sessions.first { $0.id == sessionID })
    let moved = HostedSessionInfo(
        id: info.id, name: info.name, cwd: info.cwd, command: info.command, pid: info.pid,
        pwd: "file://studio.local/Users/me/work/app/src%20dir", owner: info.owner, tags: info.tags
    )
    first.persistentSessionDidChange(moved)
    #expect(first.workingDirectory == "/Users/me/work/app/src dir")
    // A report naming another machine (the program ran ssh) is ignored.
    first.persistentSessionDidChange(HostedSessionInfo(
        id: info.id, name: info.name, cwd: info.cwd, command: info.command, pid: info.pid,
        pwd: "file://elsewhere/home/me", owner: info.owner, tags: info.tags
    ))
    #expect(first.workingDirectory == "/Users/me/work/app/src dir")

    // A new tab starts where the selected tab of the same host is.
    workspace.select(first)
    let second = workspace.addSession()
    #expect(await harness.fake.wait { harness.creates().count == 2 })
    #expect(harness.creates().last?.string("cwd") == "/Users/me/work/app/src dir")
    #expect(await harness.fake.wait { second.persistentSession != nil })

    // A selected tab of another host (here attached to a session of This
    // Mac) never seeds it with a directory of this Mac: the launch root.
    let local = workspace.attachHostedSession(
        HostedSessionAttachment(
            host: .local, hostID: "host-local", sessionID: "local-1", name: "Local",
            remoteWorkingDirectory: NSTemporaryDirectory(), executablePath: "/c"
        ),
        launchShell: false
    )
    #expect(local.persistentHosting == nil)
    #expect(local.reportsLocalWorkingDirectory)
    workspace.select(local)
    let third = workspace.addSession()
    #expect(await harness.fake.wait { harness.creates().count == 3 })
    #expect(harness.creates().last?.string("cwd") == "/Users/me/work/app")
    #expect(await harness.fake.wait { third.persistentSession != nil })
}
