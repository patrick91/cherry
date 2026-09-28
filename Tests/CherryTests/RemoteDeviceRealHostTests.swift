import AppKit
import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Devices (docs/specs/remote-devices.md) end to end against a fake remote Mac
// (Scripts/fake-remote-mac): the real `cherry` and `cherry-host`, reached
// through an `ssh` shim that runs the remote command locally with the fake
// Mac's private HOME and CHERRY_HOST_SOCKET. Masters are off, the shim never
// runs the real ssh, and every `cherry` this runs is a wrapper that puts the
// shim alone on PATH (an adapter Ghostty starts through login(1) included),
// so no ssh ever reaches another machine or reads ~/.ssh. Gated like the other
// real-host suites: CHERRY_TEST_HOST_INTEGRATION=1 and the Rust helpers built
// (Scripts/build-host debug). Each test's fake Mac runs its own daemon, which
// never outlives the test (RealHostTestDaemon), and is stopped at the end.

private let realHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
final class FakeRemoteMac {
    let name: String
    let root: URL
    /// The shim's directory: the only PATH entry of every local `cherry`.
    let bin: URL
    let hostDirectory: URL
    let home: URL
    let socket: URL
    /// The wrapper every local helper and adapter runs as `cherry`.
    let cli: URL
    let binaries: URL
    let host: HostedSessionHost
    let hostStore: HostedSessionHostStore
    let installationID = UUID()
    let deviceID = UUID()
    let projectPath: String
    private let suite: String
    private let daemonEnvironment: [String: String]
    /// The cherry-host its daemon runs as (its PATH's, or an install).
    private let daemonExecutable: URL
    private var daemon: RealHostTestDaemon?
    private var controls: [HostControl] = []

    /// Where this Cherry installs its session host there.
    var installRoot: URL {
        home.appendingPathComponent(RemoteHostInstall.rootRelativePath, isDirectory: true)
    }

    /// `host`: what cherry-host it has (`CHERRY_FAKE_REMOTE_HOST`: link,
    /// none, newer, old-build). `startsDaemon`: a daemon runs there from the
    /// start (from its PATH's cherry-host, or for old-build from that
    /// install, reporting that build).
    init(name: String = "studio", host kind: String = "link", startsDaemon: Bool = true) throws {
        self.name = name
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        binaries = try #require(
            HostedSessionClient.developmentTargetDirectories(
                environment: ProcessInfo.processInfo.environment, sourceRoot: repository
            )
            .map { $0.appendingPathComponent("debug") }
            .first { directory in
                ["cherry", "cherry-host"].allSatisfy {
                    FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
                }
            },
            "Build the Rust helpers first: Scripts/build-host debug"
        )
        // Private and short: the fake Mac's socket lives under it.
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("ch-rm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Its physical path, as `pwd -P` on the fake Mac reports it.
        root = URL(fileURLWithPath: created.path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return created.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }, isDirectory: true)
        try Self.run(
            repository.appendingPathComponent("Scripts/fake-remote-mac").path,
            ["setup", root.path, name],
            environment: ["CHERRY_FAKE_REMOTE_BIN": binaries.path, "CHERRY_FAKE_REMOTE_HOST": kind]
        )
        bin = root.appendingPathComponent("bin", isDirectory: true)
        hostDirectory = root.appendingPathComponent("hosts/\(name)", isDirectory: true)
        home = hostDirectory.appendingPathComponent("home", isDirectory: true)
        socket = hostDirectory.appendingPathComponent("host.sock")
        projectPath = home.appendingPathComponent("work/app").path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        // The local `cherry`: the shim alone on PATH, whatever runs it.
        cli = root.appendingPathComponent("cherry-local")
        try """
        #!/bin/sh
        PATH='\(bin.path)'
        export PATH
        exec '\(binaries.appendingPathComponent("cherry").path)' "$@"
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        host = try HostedSessionHost.ssh(name)
        suite = "CherryTests.RemoteDevice.\(UUID().uuidString)"
        hostStore = HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite)))
        // The fake Mac's daemon, as its own login would start it.
        var environment = [
            "HOME": home.path,
            "CHERRY_HOST_SOCKET": socket.path,
            "PATH": hostDirectory.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/bash",
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        if kind == "old-build" {
            daemonExecutable = home.appendingPathComponent("\(RemoteHostInstall.rootRelativePath)/\(Self.oldBuild)/cherry-host")
            environment["CHERRY_HOST_TEST_BUILD"] = Self.oldBuild
        } else if kind == "none" {
            // A daemon no check can ask (no cherry-host where it looks).
            daemonExecutable = binaries.appendingPathComponent("cherry-host")
        } else {
            daemonExecutable = hostDirectory.appendingPathComponent("bin/cherry-host")
        }
        daemonEnvironment = environment
        if startsDaemon { try startDaemon() }
    }

    /// The build of the install `old-build` puts there.
    static let oldBuild = "20200101000000.old"

    private func startDaemon() throws {
        daemon = try RealHostTestDaemon(
            executable: daemonExecutable,
            environment: daemonEnvironment,
            socket: socket
        )
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
            usleep(25_000)
        }
    }

    /// The fake Mac restarts: its daemon and every holder are killed (the
    /// holders leave their manifests), and a new daemon starts, which
    /// reports those sessions lost.
    func restart() throws {
        daemon?.stop()
        daemon = nil
        try startDaemon()
    }

    /// This Mac's control connection to the device, through the shim.
    func makeControl(configuration: HostControl.Configuration = .fastTests) -> HostControl {
        let cli = cli
        let bin = bin
        let localHome = root.appendingPathComponent("local-home").path
        let control = HostControl(
            host: host,
            clientProvider: {
                HostedSessionClient(
                    executableURL: cli,
                    loginEnvironment: { _ in .init(environment: ["PATH": bin.path, "HOME": localHome]) }
                )
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            localHostUnavailableReason: nil,
            configuration: configuration
        )
        controls.append(control)
        return control
    }

    /// The other Mac's own Cherry ("Cherry"): its local connection to the
    /// same daemon, never through ssh.
    func makeTheirControl() -> HostControl {
        let helperVariables = [
            "HOME": home.path,
            "CHERRY_HOST_SOCKET": socket.path,
            "CHERRY_HOST_PATH": root.appendingPathComponent("no-auto-start").path,
        ]
        let executable = binaries.appendingPathComponent("cherry")
        let control = HostControl(
            host: .local,
            clientProvider: {
                HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: helperVariables) })
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        controls.append(control)
        return control
    }

    static let fastConfiguration: PersistentHostSessions.Configuration = {
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.creationTimeout = 20
        configuration.terminationTimeout = .seconds(5)
        configuration.restartExitTimeout = .seconds(5)
        configuration.reconnectDelay = (0.1, 0.5)
        configuration.disappearanceConfirmationDelay = .milliseconds(400)
        configuration.lostCreateChecks = [.milliseconds(300)]
        return configuration
    }()

    /// The device's hosting, as the device store makes it.
    func makeHosting(
        control: HostControl,
        configuration: PersistentHostSessions.Configuration = FakeRemoteMac.fastConfiguration
    ) -> PersistentHostSessions {
        PersistentHostSessions.remote(
            profile: .remote(host: host, displayName: "Studio", machineNames: []),
            installationID: installationID,
            remoteShell: "/bin/bash",
            control: { control },
            installationUnavailableReason: { nil },
            status: PersistentSessionsStatus(),
            instanceLock: nil,
            terminalColors: { nil },
            configuration: configuration
        )
    }

    var projectKey: String { ProjectLocation.remote(deviceID: deviceID, path: projectPath).key }

    /// What a check runs: the shim itself, with nothing else on PATH.
    var shell: RemoteDeviceShell {
        RemoteDeviceShell(
            sshExecutable: bin.appendingPathComponent("ssh").path,
            environment: ["PATH": bin.path, "HOME": root.appendingPathComponent("local-home").path],
            timeout: 20
        )
    }

    /// Turns a shim switch (offline, hostkey, denied) on or off.
    func set(_ behaviour: String, _ on: Bool) {
        let file = hostDirectory.appendingPathComponent(behaviour)
        if on {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Another fake Mac beside this one without a cherry-host.
    func addBareMac(_ name: String) throws {
        try addMac(name, host: "none")
    }

    /// Another fake Mac beside this one (no daemon runs there).
    func addMac(_ name: String, host kind: String) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Self.run(
            repository.appendingPathComponent("Scripts/fake-remote-mac").path,
            ["setup", root.path, name],
            environment: ["CHERRY_FAKE_REMOTE_BIN": binaries.path, "CHERRY_FAKE_REMOTE_HOST": kind]
        )
    }

    /// Turns a switch of another fake Mac beside this one on.
    func set(_ behaviour: String, _ contents: String, on name: String) throws {
        try contents.write(
            to: root.appendingPathComponent("hosts/\(name)/\(behaviour)"), atomically: true, encoding: .utf8
        )
    }

    /// `cherry status --json` for its daemon, as a process there would ask
    /// (never through ssh, never starting one).
    func cliStatus() throws -> RemoteCLIStatusReport {
        let process = Process()
        process.executableURL = binaries.appendingPathComponent("cherry")
        process.arguments = ["status", "--json"]
        process.environment = daemonEnvironment.filter { $0.key != "CHERRY_HOST_TEST_BUILD" }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(RemoteCLIStatusReport.self, from: data)
    }

    /// Starts `command` as a session there, as the other Mac's own Cherry
    /// would (owner "Cherry", locally, never starting or replacing a
    /// daemon); returns its id.
    func startSession(_ command: [String]) throws -> String {
        let process = Process()
        process.executableURL = binaries.appendingPathComponent("cherry")
        process.arguments = ["new", "--cwd", home.path, "--owner", "Cherry", "--name", "work", "--"] + command
        var environment = daemonEnvironment.filter { $0.key != "CHERRY_HOST_TEST_BUILD" }
        environment["CHERRY_HOST_PATH"] = root.appendingPathComponent("no-auto-start").path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct Created: Decodable { var id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// As `startSession`, but starting the daemon there as that Mac's own
    /// Cherry would (a test whose fake Mac has none yet).
    func startSessionStartingDaemon(_ command: [String]) throws -> String {
        if daemon == nil { try startDaemon() }
        return try startSession(command)
    }

    var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func waitFor(_ description: String, timeout: TimeInterval = 20, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HostedSessionError.message("Timed out waiting for \(description)")
    }

    /// Every session, as the device's own Cherry lists it (not through ssh).
    func sessions(_ their: HostControl) async throws -> [HostedSessionInfo] {
        try await their.list().sessions
    }

    func tearDown() async {
        set("offline", false)
        let their = makeTheirControl()
        if let sessions = try? await their.list().sessions {
            for session in sessions where session.isRunning {
                try? await their.terminate(session.id)
            }
        }
        for control in controls { control.disconnect() }
        daemon?.stop()
        daemon = nil
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try? Self.run(repository.appendingPathComponent("Scripts/fake-remote-mac").path, ["stop", root.path], environment: [:])
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostedSessionError.message("\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
    }
}

private func temporaryStore() throws -> (WorkspaceStateStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-rd-state-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (WorkspaceStateStore(directory: directory), directory)
}

@MainActor
private func remoteRepository(
    _ mac: FakeRemoteMac,
    hosting: PersistentHostSessions,
    control: HostControl,
    store: WorkspaceStateStore?
) -> RepositoryWorkspace {
    let queue = RestoredTabLaunchQueue()
    return RepositoryWorkspace(
        projectRoot: mac.projectKey,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil),
        stateStore: store,
        sessionRestorer: WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting, control: { _ in control }),
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: queue
    )
}

// MARK: - Add Mac…

@Test(.enabled(if: realHostEnabled))
@MainActor func RemoteDeviceRealHostAddMacChecksTheOtherMacOverSSH() async throws {
    let mac = try FakeRemoteMac()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-rd-devices-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let store = RemoteDeviceStore(
            fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
            hostStore: mac.hostStore,
            installationID: { mac.installationID },
            registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
            remoteHostPaths: HostedRemoteHostPaths(),
            // This test's own control and no instance lock: never the app's.
            makeHosting: { profile, installation in
                PersistentHostSessions.remote(
                    profile: profile, installationID: installation,
                    control: { mac.makeControl() },
                    installationUnavailableReason: { nil },
                    status: PersistentSessionsStatus(), instanceLock: nil, terminalColors: { nil }
                )
            }
        )
        var opened: [String] = []
        let model = AddDeviceModel(
            store: store, aliases: ["studio", "other"], shell: { mac.shell }, openInTerminal: { opened.append($0) }
        )
        // SSH problems, each explained.
        for (behaviour, id) in [("hostkey", "hostKey"), ("denied", "denied"), ("offline", "offline")] {
            mac.set(behaviour, true)
            let failing = AddDeviceModel(store: store, aliases: [], shell: { mac.shell }, openInTerminal: { opened.append($0) })
            failing.destination = "studio"
            await failing.check()
            mac.set(behaviour, false)
            let item = try #require(failing.checklist?.items.first)
            #expect(item.status == .failure, "\(id)")
            #expect(!(failing.checklist?.canAdd ?? true))
            switch behaviour {
            case "hostkey":
                #expect(failing.probe?.sshFailure == .hostKey("Host key verification failed."))
                #expect(item.action == .openInTerminal)
                failing.openInTerminal(failing.trimmedDestination)
            case "denied":
                #expect(failing.probe?.sshFailure == .permissionDenied("studio: Permission denied (publickey)."))
            default:
                #expect(failing.probe?.sshFailure == .unreachable("ssh: connect to host studio port 22: Connection timed out"))
            }
        }
        model.destination = "st"
        #expect(model.suggestions == ["studio"])
        model.destination = "studio"
        await model.check()
        let checklist = try #require(model.checklist)
        #expect(checklist.items.first { $0.id == "ssh" }?.status == .ok)
        #expect(checklist.items.first { $0.id == "system" }?.status == .ok)
        // The fake Mac's cherry-host (on its PATH) speaks this protocol, and
        // its daemon runs.
        #expect(checklist.items.first { $0.id == "host" }?.status == .ok)
        #expect(checklist.hostIsCompatible)
        #expect(model.probe?.hostStatus?.running == true)
        // Its keychain is locked over SSH (the stand-in `security`).
        #expect(checklist.items.first { $0.id == "keychain" }?.status == .warning)
        #expect(model.name == "Fake studio")
        #expect(model.canAdd)
        let device = try #require(model.add())
        #expect(device.sshDestination == "studio")
        #expect(device.homeDirectory == mac.home.path)
        #expect(device.machineNames.contains("fake-studio"))
        #expect(device.remoteHostPath == nil)
        #expect(mac.hostStore.hosts.contains(mac.host))
        // A check is a BatchMode ssh running `sh -s`, never a master.
        let check = try #require(mac.calls.first)
        #expect(check.contains("BatchMode=yes") && check.hasSuffix("-- studio sh -s"))

        // Add Project on <Mac>…: checked there.
        let resolved = await RemoteDeviceProbe.resolveDirectory("~/work/app", on: "studio", shell: mac.shell)
        #expect(resolved == .success(mac.projectPath))
        let missing = await RemoteDeviceProbe.resolveDirectory("~/nowhere", on: "studio", shell: mac.shell)
        #expect(missing == .failure(.message("There is no folder at ~/nowhere on that Mac.")))

        #expect(opened == ["studio"])
        // Another alias of the same Mac: its host has the same identity.
        try FileManager.default.createSymbolicLink(
            at: mac.hostDirectory.deletingLastPathComponent().appendingPathComponent("studio-alias"),
            withDestinationURL: mac.hostDirectory
        )
        let alias = AddDeviceModel(store: store, aliases: [], shell: { mac.shell })
        alias.destination = "studio-alias"
        await alias.check()
        #expect(alias.error?.contains("same Mac as Fake studio") == true)
        #expect(alias.add() == nil)
        #expect(store.devices.count == 1)
        // Already added.
        let again = AddDeviceModel(store: store, aliases: [], shell: { mac.shell })
        again.destination = "studio"
        await again.check()
        #expect(again.error?.contains("already") == true)

        // A Mac without cherry-host: said so; this Cherry installs its own
        // (Install & Add, phase 2)…
        try mac.addBareMac("bare")
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let bare = AddDeviceModel(store: store, aliases: [], shell: { mac.shell }, helpers: { .success(helpers) })
        bare.destination = "bare"
        await bare.check()
        let hostItem = try #require(bare.checklist?.items.first { $0.id == "host" })
        #expect(hostItem.status == .ok)
        #expect(hostItem.detail?.contains("No cherry-host was found") == true)
        #expect(bare.checklist?.items.first { $0.id == "install" }?.title == "Install")
        #expect(bare.primaryTitle == "Install & Add")
        #expect(bare.checklist?.canAdd == true)
        // …and without helpers of its own, says what to do meanwhile.
        let noHelpers = AddDeviceModel(
            store: store, aliases: [], shell: { mac.shell }, helpers: { .failure(.message("no helpers here")) }
        )
        noHelpers.destination = "bare"
        await noHelpers.check()
        let manual = try #require(noHelpers.checklist?.items.first { $0.id == "host" })
        #expect(manual.status == .warning)
        #expect(manual.detail?.contains("by hand") == true)
        #expect(noHelpers.checklist?.items.first { $0.id == "install" }?.detail == "no helpers here")
        #expect(noHelpers.primaryTitle == "Add" && noHelpers.checklist?.canAdd == true)
        #expect(mac.calls.allSatisfy { !$0.contains("-M") && !$0.contains("-O ") })
    } catch {
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}

// MARK: - Tabs on the device, and owners

@Test(.enabled(if: realHostEnabled))
@MainActor func RemoteDeviceRealHostTabsRunOnTheDeviceAndOwnersStayApart() async throws {
    let mac = try FakeRemoteMac()
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let their = mac.makeTheirControl()
    let workspace = TerminalWorkspace(
        projectRoot: mac.projectKey, createInitialSession: false,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
    )
    do {
        // A new tab runs on the device, created through ssh.
        let tab = workspace.addSession(title: "Remote")
        #expect(tab.isPersistentLocalSession)
        try await mac.waitFor("the tab's session on the device") { tab.persistentSession != nil }
        let binding = try #require(tab.persistentSession)
        #expect(binding.host == mac.host)
        let ours = try #require(try await mac.sessions(their).first { $0.id == binding.sessionID })
        #expect(ours.owner == hosting.owner)
        #expect(ours.owner == PersistentHostSessions.remoteOwner(installationID: mac.installationID))
        #expect(ours.tags[PersistentSessionTag.project] == mac.projectKey)
        #expect(ours.tags[PersistentSessionTag.tab] == tab.id.uuidString)
        #expect(ours.cwd == mac.projectPath)
        #expect(tab.hostedProgramProcessID == nil)
        #expect(mac.calls.contains { $0.contains("-- studio") && $0.contains("cherry-host gateway") })

        // Its program runs there: input through the host, screen from it.
        try await tab.sendControlInput(Data("echo REMOTE_$((20 + 22)) $HOME\n".utf8), raw: false)
        try await mac.waitFor("the echo on the device") {
            (try? await hosting.screen(of: binding).text.contains("REMOTE_42 \(mac.home.path)")) == true
        }

        // The device's own Cherry has a session of the same project, and
        // there is one no project names.
        let theirTab = UUID()
        let theirs = try await their.create(HostCreateRequest(
            requestID: UUID(), name: "Their shell", cwd: mac.projectPath, command: ["/bin/bash", "--noprofile", "--norc"],
            owner: "Cherry",
            tags: [PersistentSessionTag.tab: theirTab.uuidString, PersistentSessionTag.kind: "terminal",
                   PersistentSessionTag.project: mac.projectPath]
        ))
        let untagged = try await their.create(HostCreateRequest(
            requestID: UUID(), name: "CLI", cwd: mac.projectPath, command: ["/bin/bash", "--noprofile", "--norc"]
        ))
        let listed = try await control.list().sessions
        let (projects, other) = RemoteDeviceDiscovery.projects(sessions: listed, added: [], hidden: [])
        #expect(projects.map(\.path) == [mac.projectPath])
        #expect(projects.first?.sessionCount == 2)
        #expect(other == 1)
        #expect(RemoteDeviceDiscovery.projects(sessions: listed, added: [], hidden: [mac.projectPath]).projects.isEmpty)
        let device = RemoteDevice(id: mac.deviceID, name: "Studio", sshDestination: "studio", homeDirectory: mac.home.path)
        let menu = TitlebarProjectMenuModel(
            worktrees: nil, projects: [], devices: [.init(device: device, state: .connected(sessionCount: listed.count), sessions: listed)],
            currentProjectKey: mac.projectKey
        )
        #expect(menu.snapshot.contains("[x] app — 2 sessions · \(mac.projectPath)"))
        #expect(menu.snapshot.contains("Other sessions — 1 session"))

        // Neither adopts the other's: the device's own Cherry never takes
        // this installation's session, and this one never takes theirs.
        let theirHosting = PersistentHostSessions(
            owner: "Cherry", control: { their }, installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
        )
        #expect(!theirHosting.canAdopt(ours))
        #expect(!hosting.canAdopt(theirs))
        #expect(OrphanedSessionCriteria(owner: "Cherry", savedState: nil, createdBefore: .distantFuture).orphanTabID(of: ours) == nil)
        #expect(OrphanedSessionCriteria(owner: hosting.owner, savedState: nil, createdBefore: .distantFuture, host: mac.host)
            .orphanTabID(of: theirs) == nil)
        // Their restore of a tab with our tab's id finds nothing of ours.
        let theirWorkspace = TerminalWorkspace(projectRoot: mac.projectPath, createInitialSession: false, backendPolicy: SessionBackendPolicy(
            settings: { .defaults }, localSessions: theirHosting
        ))
        let theirRestore = await WorkspaceSessionRestorers.hostedByDefault(localSessions: theirHosting)(WorkspaceRestoreRequest(
            repositoryRoot: mac.projectPath, worktreeRoot: mac.projectPath, records: [], workspace: theirWorkspace,
            unboundRecords: [WorkspaceSessionRecord(
                id: tab.id, kind: .terminal, title: "Remote", workingDirectory: mac.projectPath,
                launchRequestID: PersistentHostSessions.launchRequestID(of: ours)
            )]
        ))
        #expect(theirRestore.sessions.isEmpty)
        // Ours of a tab with their tab's id finds nothing of theirs.
        let ourRestore = await WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting, control: { _ in control })(WorkspaceRestoreRequest(
            repositoryRoot: mac.projectKey, worktreeRoot: mac.projectKey, records: [], workspace: workspace,
            unboundRecords: [WorkspaceSessionRecord(
                id: theirTab, kind: .terminal, title: "Theirs", workingDirectory: mac.projectPath,
                launchRequestID: PersistentHostSessions.launchRequestID(of: theirs), hostKey: mac.host.id
            )]
        ))
        #expect(ourRestore.sessions.isEmpty)

        // Detached, ours is not open here any more; theirs never was.
        workspace.close(tab, allowEmptyWorkspace: true, intent: .userDetachedTab)
        try await mac.waitFor("the detached session in the host's list") {
            hosting.sessionInfo(binding.sessionID)?.isRunning == true && hosting.owningTab(of: binding.sessionID) == nil
        }
        let listedAgain = try await control.list()
        let notOpen = RemoteDeviceDiscovery.notOpenSessions(
            in: listedAgain.sessions, projectPath: mac.projectPath, owner: hosting.owner,
            isShown: { hosting.isShownByOpenTab($0, hostID: listedAgain.hostID) },
            isEnding: { hosting.isEnding($0.id) }
        )
        #expect(notOpen.own.map(\.id) == [binding.sessionID])
        #expect(notOpen.others.map(\.id) == [theirs.id])

        // Attach theirs: shown without owning it; closing only disconnects.
        let theirAttachment = try #require(hosting.attachment(for: theirs))
        let attached = workspace.attachHostedSession(theirAttachment, info: theirs)
        #expect(attached.hostedAttachment != nil)
        #expect(!attached.isPersistentLocalSession)
        workspace.close(attached, allowEmptyWorkspace: true, intent: .userClosedTab)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await mac.sessions(their).first { $0.id == theirs.id }?.isRunning == true)

        // Reopen ours: this window owns it again.
        let ourInfo = try #require(listedAgain.sessions.first { $0.id == binding.sessionID })
        let reopened = workspace.attachHostedSession(try #require(hosting.attachment(for: ourInfo)), info: ourInfo)
        #expect(reopened.isPersistentLocalSession)
        #expect(reopened.id == tab.id)
        #expect(reopened.persistentSession?.sessionID == binding.sessionID)
        #expect(hosting.owningTab(of: binding.sessionID) === reopened)
        _ = untagged
        theirWorkspace.closeAllSessions(intent: .windowClosed)
    } catch {
        workspace.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    workspace.closeAllSessions(intent: .windowClosedEndingSessions)
    await mac.tearDown()
}

// MARK: - Restore

@Test(.enabled(if: realHostEnabled))
@MainActor func RemoteDeviceRealHostRestoreAfterThisMacRestartsKeepsDeviceTabsAndADeviceRestartEndsThem() async throws {
    let mac = try FakeRemoteMac()
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    hosting.endedSessionsStore = store
    var repositories: [RepositoryWorkspace] = []
    do {
        let first = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repositories.append(first)
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let workspace = first.activeWorkspace
        // The window's default shell ran on the device.
        let tab = try #require(workspace.sessions.first)
        try await mac.waitFor("the tab's session") { tab.persistentSession != nil }
        let sessionID = try #require(tab.persistentSession?.sessionID)
        first.flushPersistentState()
        // Quit, keeping sessions.
        first.closeAllSessions(intent: .appQuit)
        store.flush()

        // This Mac restarted since: its records say they were saved long
        // before it booted. That is no evidence about the device.
        var state = try #require(store.load(repositoryRoot: mac.projectKey))
        state.savedAt = Date(timeIntervalSince1970: 1_000)
        state.worktrees = state.worktrees.map { worktree in
            var worktree = worktree
            worktree.sessions = worktree.sessions.map { var record = $0; record.savedAt = Date(timeIntervalSince1970: 1_000); return record }
            return worktree
        }
        store.saveSynchronously(state)
        #expect(state.worktrees.first?.sessions.first?.hosted?.host == mac.host.id)
        #expect(state.worktrees.first?.sessions.first?.hosted?.owned == true)

        let second = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repositories.append(second)
        second.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await second.waitForPendingRestores()
        let restored = try #require(second.activeWorkspace.session(withID: tab.id))
        #expect(restored.isPersistentLocalSession)
        #expect(restored.persistentSession?.sessionID == sessionID)
        #expect(restored.systemSessionEnd == nil)
        #expect(restored.isRunning)
        #expect(second.activeWorkspace.sessions.count == 1)
        second.flushPersistentState()
        second.closeAllSessions(intent: .appQuit)
        store.flush()

        // Now the device restarts while Cherry is closed: its host reports
        // the session lost, and the tab comes back ended, naming it.
        try mac.restart()
        control.disconnect()
        let third = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repositories.append(third)
        third.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await third.waitForPendingRestores()
        let ended = try #require(third.activeWorkspace.session(withID: tab.id))
        #expect(ended.systemSessionEnd == .hostRestart)
        #expect(ended.persistentSessionEndedMessage == "Ended when Studio restarted")
        #expect(!ended.isRunning)
        // Restart starts it on the device again, never here.
        #expect(ended.remoteMachineName == "Studio")
        #expect(third.activeWorkspace.restart(ended))
        try await mac.waitFor("the restarted tab's new session") { ended.persistentSession != nil }
        #expect(ended.persistentSession?.host == mac.host)
    } catch {
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await mac.tearDown()
        throw error
    }
    for repository in repositories { repository.closeAllSessions(intent: .windowClosedEndingSessions) }
    await mac.tearDown()
}

// MARK: - Offline

@Test(.enabled(if: realHostEnabled))
@MainActor func RemoteDeviceRealHostOfflineDeviceKeepsTabsPendingAndNeverRunsThemHere() async throws {
    let mac = try FakeRemoteMac()
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var controlConfiguration = HostControl.Configuration.fastTests
    controlConfiguration.reconnectDelay = (.milliseconds(100), .milliseconds(400))
    let control = mac.makeControl(configuration: controlConfiguration)
    var configuration = FakeRemoteMac.fastConfiguration
    configuration.creationTimeout = 8
    let hosting = mac.makeHosting(control: control, configuration: configuration)
    hosting.endedSessionsStore = store
    var repositories: [RepositoryWorkspace] = []
    do {
        let first = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repositories.append(first)
        first.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await first.waitForPendingRestores()
        let tab = try #require(first.activeWorkspace.sessions.first)
        try await mac.waitFor("the tab's session") { tab.persistentSession != nil }
        first.flushPersistentState()
        first.closeAllSessions(intent: .appQuit)
        store.flush()

        // The device goes offline ("Connection timed out").
        mac.set("offline", true)
        control.disconnect()
        let second = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repositories.append(second)
        second.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await second.waitForPendingRestores()
        // The saved tab waits; no tab, and no new shell, runs meanwhile.
        #expect(second.activeWorkspace.sessions.isEmpty)
        #expect(second.remoteTabsWaitingCount == 1)
        #expect(second.savedRecordsAwaitingRestore().map(\.id) == [tab.id])

        // Still waiting a while later: nothing here runs it instead.
        try await Task.sleep(for: .seconds(1))
        #expect(second.activeWorkspace.sessions.isEmpty)
        #expect(control.state != .connected)

        // Back online: the waiting tab comes back by itself (its restore
        // keeps the device's connection trying, with backoff, as for SSH
        // tabs; a wake or a network change would try at once).
        mac.set("offline", false)
        try await mac.waitFor("the waiting tab to come back", timeout: 30) {
            second.activeWorkspace.session(withID: tab.id) != nil
        }
        let restored = try #require(second.activeWorkspace.session(withID: tab.id))
        #expect(restored.isPersistentLocalSession && restored.isRunning)
        #expect(second.remoteTabsWaitingCount == 0)

        // A new tab while the device is offline fails, saying so, and never
        // runs a local shell.
        mac.set("offline", true)
        control.disconnect()
        let offlineTab = second.activeWorkspace.addSession()
        #expect(offlineTab.isPersistentLocalSession)
        try await mac.waitFor("the offline tab to fail") { offlineTab.persistentLaunchFailureReason != nil }
        #expect(offlineTab.persistentLaunchFailureReason?.hasPrefix("Couldn't start on Studio: ") == true)
        #expect(offlineTab.persistentLaunchFailureReason?.contains("Connection timed out") == true)
        #expect(!offlineTab.isRunning && !offlineTab.usesNativePTYBackend)
        #expect(offlineTab.persistentFallbackReason == nil)
        mac.set("offline", false)
    } catch {
        mac.set("offline", false)
        for repository in repositories { repository.closeAllSessions(intent: .windowClosed) }
        await mac.tearDown()
        throw error
    }
    for repository in repositories { repository.closeAllSessions(intent: .windowClosedEndingSessions) }
    await mac.tearDown()
}

@Test(.enabled(if: realHostEnabled))
@MainActor func RemoteDeviceRealHostEndSessionsWhileOfflineIsFinishedOnTheNextConnection() async throws {
    let mac = try FakeRemoteMac()
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var controlConfiguration = HostControl.Configuration.fastTests
    controlConfiguration.reconnectDelay = (.milliseconds(100), .milliseconds(400))
    let control = mac.makeControl(configuration: controlConfiguration)
    var configuration = FakeRemoteMac.fastConfiguration
    configuration.endRetryDelay = (.milliseconds(100), .milliseconds(200))
    configuration.endRetryWindow = .seconds(1)
    let hosting = mac.makeHosting(control: control, configuration: configuration)
    hosting.endedSessionsStore = store
    hosting.resumeRecordedEndsOnConnection()
    let their = mac.makeTheirControl()
    var repository: RepositoryWorkspace?
    do {
        let window = remoteRepository(mac, hosting: hosting, control: control, store: store)
        repository = window
        window.beginRestoringSavedStateIfNeeded(chromeState: nil)
        await window.waitForPendingRestores()
        let tab = try #require(window.activeWorkspace.sessions.first)
        try await mac.waitFor("the tab's session") { tab.persistentSession != nil }
        let sessionID = try #require(tab.persistentSession?.sessionID)

        // Offline, then the window closes with End Sessions.
        mac.set("offline", true)
        control.disconnect()
        window.flushPersistentState()
        window.closeAllSessions(intent: .windowClosedEndingSessions)
        store.flush()
        let recorded = store.loadSessionsToEnd()
        #expect(recorded.contains { $0.hosted?.sessionID == sessionID && $0.hosted?.host == mac.host.id })
        // A quit would not wait for it.
        #expect(await hosting.waitForPendingEnds(timeout: .milliseconds(100)))
        // The end could not get through: the session still runs there.
        try await Task.sleep(for: .seconds(2))
        #expect(try await mac.sessions(their).first { $0.id == sessionID }?.isRunning == true)
        store.flush()
        #expect(!store.loadSessionsToEnd().isEmpty)

        // The next connection finishes it.
        mac.set("offline", false)
        _ = try await control.list()
        try await mac.waitFor("the session to end", timeout: 30) {
            try await mac.sessions(their).first { $0.id == sessionID }?.isRunning != true
        }
        try await mac.waitFor("the record to go", timeout: 30) {
            store.flush()
            return !store.loadSessionsToEnd().contains { $0.hosted?.sessionID == sessionID }
        }
    } catch {
        mac.set("offline", false)
        repository?.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}
