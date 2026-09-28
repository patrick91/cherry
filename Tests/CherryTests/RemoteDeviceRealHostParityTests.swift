import AppKit
import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Phase 3 of devices (docs/specs/remote-devices.md) against a fake remote
// Mac (Scripts/fake-remote-mac): the real `cherry`, `cherry-host` (its
// `project-info`), git, scp and zsh, reached through the ssh shim with the
// fake Mac's private HOME. Gated like the other real-host suites
// (CHERRY_TEST_HOST_INTEGRATION=1, Scripts/build-host debug).
//
// RemoteDeviceRealHostShardsSSHMastersAboveTheChannelCap also runs over a
// real sshd with MaxSessions 3: Scripts/test-remote-mac-loopback sets
// CHERRY_TEST_LOOPBACK_SSH and runs it; otherwise it uses the fake Mac's
// stand-in masters (DIR/masters, DIR/max-sessions).

private let parityRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
private func git(_ directory: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
    ]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HostedSessionError.message("git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
}

@MainActor
private func access(_ mac: FakeRemoteMac, remoteHostPath: String? = nil) -> RemoteProjectAccess {
    let shell = mac.shell
    return RemoteProjectAccess(
        deviceID: mac.deviceID, deviceName: "Studio", destination: mac.name,
        remoteHostPath: remoteHostPath, homeDirectory: mac.home.path, shell: { shell }
    )
}

@MainActor
private func deviceWindow(
    _ mac: FakeRemoteMac,
    hosting: PersistentHostSessions,
    access: RemoteProjectAccess,
    autoStartCommands: (@MainActor (String) -> [ProjectCommandDefinition])? = nil
) -> RepositoryWorkspace {
    if let autoStartCommands {
        return RepositoryWorkspace(
            projectRoot: mac.projectKey,
            backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil),
            autoStartCommands: autoStartCommands,
            restoredTabLaunchQueue: RestoredTabLaunchQueue(),
            remoteProject: access
        )
    }
    return RepositoryWorkspace(
        projectRoot: mac.projectKey,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil),
        restoredTabLaunchQueue: RestoredTabLaunchQueue(),
        remoteProject: access
    )
}

// MARK: - Git worktrees on the device

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostWorktreesRunGitOnTheDeviceThroughTheRunner() async throws {
    let mac = try FakeRemoteMac()
    let previous = TerminalSettings.shared.worktreeSpacesEnabled
    TerminalSettings.shared.worktreeSpacesEnabled = true
    defer { TerminalSettings.shared.worktreeSpacesEnabled = previous }
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    var window: RepositoryWorkspace?
    do {
        // A repository on the device, with a linked worktree.
        try git(mac.projectPath, ["init", "-q", "-b", "main"])
        try git(mac.projectPath, ["commit", "-q", "--allow-empty", "-m", "first"])
        let linked = mac.home.appendingPathComponent("wt/feature").path
        try git(mac.projectPath, ["worktree", "add", "-q", "-b", "feature", linked])
        let device = access(mac)
        let repository = deviceWindow(mac, hosting: hosting, access: device, autoStartCommands: { _ in [] })
        window = repository
        #expect(!repository.remoteProjectLoaded)
        await repository.refresh()
        #expect(repository.remoteProjectLoaded)
        #expect(repository.remoteProjectNote == nil)
        // The device's worktrees, by key.
        #expect(repository.worktrees.map(\.root) == [mac.projectKey, device.key(forPath: linked)])
        #expect(repository.worktrees.map(\.displayPath) == [mac.projectPath, linked])
        #expect(repository.worktrees.map(\.branch) == ["main", "feature"])
        #expect(repository.supportsWorktrees)
        #expect(repository.commonDirectory == mac.projectPath + "/.git")
        #expect(repository.dirtyByRoot == [mac.projectKey: false, device.key(forPath: linked): false])
        // Everything went through the shim: `sh -s` scripts on the device.
        #expect(mac.calls.contains { $0.hasSuffix("-- \(mac.name) sh -s") })

        // New Worktree… puts it under the device's home.
        let destination = try await repository.managedWorktreeDestination(branchName: "topic/new")
        let destinationPath = ProjectLocation.launchPath(forKey: destination)
        #expect(ProjectLocation.isRemoteKey(destination))
        #expect(destinationPath.hasPrefix(mac.home.path + "/.cherry/worktrees/app-"))
        #expect(destinationPath.hasSuffix("/topic-new"))
        try await repository.validateBranchName("topic/new")
        await #expect(throws: GitWorktreeCommandError.self) { try await repository.validateBranchName("bad..name") }
        try await repository.create(.newBranch(name: "topic/new", startPoint: "HEAD", destination: destination), chromeState: nil)
        #expect(FileManager.default.fileExists(atPath: destinationPath + "/.git"))
        #expect(repository.worktrees.count == 3)
        #expect(repository.activeWorktreeRoot == destination)
        #expect(repository.activeWorkspace.projectRoot == destination)
        #expect(try await repository.branchReferences().contains { $0.displayName == "topic/new" })

        // Its status there.
        try "x".write(toFile: destinationPath + "/untracked.txt", atomically: true, encoding: .utf8)
        await repository.refreshDirtyStatus()
        #expect(repository.dirtyByRoot[destination] == true)
        let worktree = try #require(repository.worktrees.first { $0.root == destination })
        #expect(await repository.removalBlockers(for: worktree).isDirty)
        // Removed there (forced: it has a file of its own).
        try await repository.remove(worktree, force: true, chromeState: nil)
        #expect(!FileManager.default.fileExists(atPath: destinationPath))
        #expect(repository.worktrees.map(\.root) == [mac.projectKey, device.key(forPath: linked)])
        #expect(repository.activeWorktreeRoot != destination)

        // No local folder is ever looked at: this Mac has none of these
        // keys, and git ran with the device's paths.
        #expect(!FileManager.default.fileExists(atPath: destination))
    } catch {
        window?.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    window?.closeAllSessions(intent: .windowClosedEndingSessions)
    await mac.tearDown()
}

// MARK: - cherry.toml on the device

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostCherryTomlCommandsAutoStartAndRestartOnTheDevice() async throws {
    let mac = try FakeRemoteMac()
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    let their = mac.makeTheirControl()
    var window: RepositoryWorkspace?
    let key = mac.projectKey
    defer {
        RemoteProjectFiles.shared.set(nil, for: key)
        AgentSettings.shared.removeCommand(named: "extra", for: key)
    }
    do {
        try """
        [[commands]]
        name = "server"
        command = "echo SERVER_$((40 + 2)); sleep 600"
        autoStart = true

        [[commands]]
        name = "flaky"
        command = "echo FLAKY; exit 3"
        autoStart = true
        autoRestart = true

        [[commands]]
        name = "manual"
        command = "echo MANUAL; sleep 600"
        """.write(toFile: mac.projectPath + "/cherry.toml", atomically: true, encoding: .utf8)
        let repository = deviceWindow(mac, hosting: hosting, access: access(mac))
        window = repository
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        // As the window opens: auto-start waits for project-info.
        repository.autoStartInitialCommandsIfNeeded()
        #expect(repository.activeWorkspace.commandSession(named: "server") == nil)
        await repository.refresh()
        #expect(CherryProjectFile.loadCommands(projectRoot: key).map(\.name) == ["server", "flaky", "manual"])
        #expect(AgentSettings.shared.launchableProjectCommands(for: key).map(\.name) == ["server", "flaky", "manual"])
        let workspace = repository.activeWorkspace
        try await mac.waitFor("the auto-started command") { workspace.commandSession(named: "server")?.persistentSession != nil }
        let server = try #require(workspace.commandSession(named: "server"))
        #expect(workspace.commandSession(named: "manual") == nil)
        let binding = try #require(server.persistentSession)
        let listed = try #require(try await mac.sessions(their).first { $0.id == binding.sessionID })
        #expect(listed.tags[PersistentSessionTag.command] == "server")
        #expect(listed.cwd == mac.projectPath)
        try await mac.waitFor("its output on the device") {
            (try? await hosting.screen(of: binding).text.contains("SERVER_42")) == true
        }
        // restartOnExit: it exits 3 and starts again, on the device.
        let flaky = try #require(workspace.commandSession(named: "flaky"))
        try await mac.waitFor("the first run of flaky") { flaky.persistentSession != nil }
        let firstRun = try #require(flaky.persistentSession?.sessionID)
        try await mac.waitFor("flaky to restart", timeout: 30) {
            flaky.persistentSession.map { $0.sessionID != firstRun } == true
        }
        #expect(flaky.persistentSession?.host == mac.host)

        // A command saved on this Mac, keyed by the project's key; its
        // cherry.toml stays read-only.
        try AgentSettings.shared.upsertCommand(
            ProjectCommandDefinition(name: "extra", command: "echo EXTRA"), for: key, storage: .local
        )
        #expect(AgentSettings.shared.projectCommands(for: key).map(\.name) == ["server", "flaky", "manual", "extra"])
        #expect(AgentSettings.shared.commandStorage(named: "extra", for: key) == .local)
        #expect(AgentSettings.shared.commandStorage(named: "server", for: key) == .projectFile)
        #expect(throws: CherryProjectFile.RemoteProjectFileError.self) {
            try AgentSettings.shared.upsertCommand(
                ProjectCommandDefinition(name: "shared", command: "true"), for: key, storage: .projectFile
            )
        }
        // The file there is unchanged.
        #expect(try String(contentsOfFile: mac.projectPath + "/cherry.toml", encoding: .utf8).contains("name = \"manual\""))
        #expect(!(try String(contentsOfFile: mac.projectPath + "/cherry.toml", encoding: .utf8).contains("shared")))

        // A cherry.toml over 256 KiB is not read, and says so.
        let large = mac.home.appendingPathComponent("work/large").path
        try FileManager.default.createDirectory(atPath: large, withIntermediateDirectories: true)
        try String(repeating: "# padding\n", count: 30_000).write(toFile: large + "/cherry.toml", atomically: true, encoding: .utf8)
        let report = try await access(mac).projectInfo(paths: [large, mac.home.appendingPathComponent("nowhere").path])
        #expect(report.projects.first?.cherryTomlText == nil)
        #expect(report.projects.first?.cherryTomlProblem == "cherry.toml is larger than 256 KiB")
        #expect(report.projects.last?.exists == false)
        // An older cherry-host there without project-info: said so.
        let stale = access(mac, remoteHostPath: "/usr/bin/true")
        await #expect(throws: RemoteProjectError.self) { _ = try await stale.projectInfo(paths: [large]) }
    } catch {
        window?.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    window?.closeAllSessions(intent: .windowClosedEndingSessions)
    await mac.tearDown()
}

// MARK: - Terminfo and shell integration there

private func hostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count)
    return String(cString: buffer)
}

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallsTerminfoAndShellIntegrationAndTabsReportTheirDirectory() async throws {
    let mac = try FakeRemoteMac(name: "term", host: "none", startsDaemon: false)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-rd-term-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var workspace: TerminalWorkspace?
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        #expect(helpers.resources != nil && helpers.resourcesHash != nil)
        var controls: [HostControl] = []
        let store = RemoteDeviceStore(
            fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
            hostStore: mac.hostStore,
            installationID: { mac.installationID },
            registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
            remoteHostPaths: HostedRemoteHostPaths(),
            makeHosting: { profile, installation in
                let control = mac.makeControl()
                controls.append(control)
                return PersistentHostSessions.remote(
                    profile: profile, installationID: installation, remoteShell: "/bin/zsh",
                    control: { control }, installationUnavailableReason: { nil },
                    status: PersistentSessionsStatus(), instanceLock: nil, terminalColors: { nil },
                    configuration: FakeRemoteMac.fastConfiguration
                )
            }
        )
        let model = AddDeviceModel(store: store, aliases: [], shell: { mac.shell }, helpers: { .success(helpers) }, openInTerminal: { _ in })
        model.destination = "term"
        await model.check()
        var device = try #require(await model.addInstallingIfNeeded(), "\(model.error ?? "")")
        #expect(device.installedResources)
        let build = mac.installRoot.appendingPathComponent(helpers.directoryName)
        // Next to the helpers, immutable per build like them.
        for file in ["terminfo/78/xterm-ghostty", "Ghostty/shell-integration/zsh/ghostty-integration",
                     "Ghostty/shell-integration/bash/ghostty.bash"] {
            #expect(FileManager.default.fileExists(atPath: build.appendingPathComponent(file).path), "\(file)")
        }
        // A second check sees the same resources: nothing to copy.
        let recheck = await RemoteDeviceProbe.run(destination: "term", remoteHostPath: nil, shell: mac.shell)
        #expect(recheck.installedBuilds.first { $0.name == helpers.directoryName }?.resourcesHash == helpers.resourcesHash)
        #expect(RemoteHostInstall.decide(probe: recheck, helpers: .success(helpers), machine: "Term").plan?.copyNeeded == false)

        // Its tabs: zsh with Ghostty's integration, its OSC 7 host being
        // this Mac's name (the fake Mac is this Mac).
        store.update(device.id) { device in
            device.shell = "/bin/zsh"
            device.machineNames = [hostName()]
        }
        device = try #require(store.device(id: device.id))
        let launch = device.launchDevice
        #expect(launch.resources?.root == build.path)
        HostedRemoteHostPaths.shared.setOverride(device.remoteHostPath, for: "term")
        defer { HostedRemoteHostPaths.shared.setOverride(nil, for: "term") }
        let hosting = try #require(store.hosting(for: device.id))
        let key = device.projectKey(path: mac.projectPath)
        let window = TerminalWorkspace(
            projectRoot: key, createInitialSession: false,
            backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil)
        )
        workspace = window
        let tab = window.addSession(title: "Remote")
        try await mac.waitFor("the tab's session") { tab.persistentSession != nil }
        let binding = try #require(tab.persistentSession)
        let their = mac.makeTheirControl()
        let listed = try #require(try await mac.sessions(their).first { $0.id == binding.sessionID })
        #expect(listed.command.first == "/bin/bash")
        #expect(listed.command.last == "exec -l /bin/zsh")
        try await tab.sendControlInput(Data("printf 'T=%s:%s\\n' \"$TERM\" \"$(infocmp -x xterm-ghostty >/dev/null 2>&1 && echo ok)\"\n".utf8), raw: false)
        try await mac.waitFor("TERM and its terminfo there") {
            (try? await hosting.screen(of: binding).text.contains("T=xterm-ghostty:ok")) == true
        }
        // OSC 7 (Ghostty's zsh integration) reaches the tab through the host.
        let work = mac.home.appendingPathComponent("work").path
        try await tab.sendControlInput(Data("cd '\(work)'\n".utf8), raw: false)
        do {
            try await mac.waitFor("the directory the shell reports") { tab.workingDirectory == work }
        } catch {
            let info = try await mac.sessions(their).first { $0.id == binding.sessionID }
            Issue.record("pwd=\(info?.pwd ?? "nil") tab=\(tab.workingDirectory) names=\(hosting.profile.machineNames()) screen=\((try? await hosting.screen(of: binding).text) ?? "")")
            throw error
        }
        // A new tab starts in the selected tab's directory there.
        window.select(tab)
        let next = window.addSession(title: "Next")
        try await mac.waitFor("the next tab's session") { next.persistentSession != nil }
        let nextInfo = try #require(try await mac.sessions(their).first { $0.id == next.persistentSession?.sessionID })
        #expect(nextInfo.cwd == work)
        // Its label shortens paths with the device's home.
        #expect(TerminalContextBarContent(session: tab).displayPath == "~/work")
        for control in controls { control.disconnect() }
    } catch {
        workspace?.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    workspace?.closeAllSessions(intent: .windowClosedEndingSessions)
    await mac.tearDown()
}

// MARK: - Dropped files

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostCopiesDroppedFilesToTheDeviceAndInsertsTheirPathsThere() async throws {
    let mac = try FakeRemoteMac(startsDaemon: false)
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-drop-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: local.appendingPathComponent("folder"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    do {
        let file = local.appendingPathComponent("shot with space.png")
        try Data("png".utf8).write(to: file)
        try "nested".write(to: local.appendingPathComponent("folder/inner.txt"), atomically: true, encoding: .utf8)
        let copier = RemoteFileCopier(shell: mac.shell, destination: mac.name, machine: "Studio")
        let paths = try await copier.copy([file, local.appendingPathComponent("folder")])
        #expect(paths.count == 2)
        let folder = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path
        #expect(URL(fileURLWithPath: folder).lastPathComponent.hasPrefix("cherry-drop."))
        // Copied there (the fake Mac is this Mac: the files are here too).
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data("png".utf8))
        #expect(try String(contentsOfFile: paths[1] + "/inner.txt", encoding: .utf8) == "nested")
        // Over the device's ssh (scp's protocol through the shim).
        #expect(mac.calls.contains { $0.contains("scp") && $0.contains("-t") })
        #expect(RemoteFileDrop.insertionText(remotePaths: paths).hasPrefix("'\(folder)/shot with space.png' "))
        try? FileManager.default.removeItem(atPath: folder)
        // An offline Mac: said so.
        mac.set("offline", true)
        await #expect(throws: HostedSessionError.self) { _ = try await copier.copy([file]) }
        mac.set("offline", false)
    } catch {
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}

// MARK: - SSH master shards

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostShardsSSHMastersAboveTheChannelCap() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ch-sh-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = root.appendingPathComponent("s")
    try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let ssh: String
    let destination: String
    var fake: FakeRemoteMac?
    if let loopback = environment["CHERRY_TEST_LOOPBACK_SSH"]?.nilIfEmpty {
        // A real sshd with MaxSessions 3 (Scripts/test-remote-mac-loopback).
        ssh = loopback
        destination = environment["CHERRY_TEST_LOOPBACK_DESTINATION"]?.nilIfEmpty ?? "loopback"
    } else {
        let mac = try FakeRemoteMac(name: "shards", startsDaemon: false)
        fake = mac
        try Data().write(to: mac.root.appendingPathComponent("masters"))
        try "3".write(to: mac.root.appendingPathComponent("max-sessions"), atomically: true, encoding: .utf8)
        ssh = mac.bin.appendingPathComponent("ssh").path
        destination = "shards"
    }
    // sshd's MaxSessions 3: the control helper and two adapters per master.
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets },
        sshExecutable: { _ in ssh },
        startTimeout: 20, healthCheckInterval: 3_600, idleStopDelay: 0.2,
        commandTimeout: 5, maxChannelsPerMaster: 2, spareChannels: 1
    ))
    var channels: [Process] = []
    func channel(_ controlPath: String?, _ command: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = (controlPath.map { ["-o", HostSSHMasterManager.controlPathOption($0)] } ?? [])
            + ["-o", "BatchMode=yes", "-T", "--", destination, command]
        process.environment = ["PATH": URL(fileURLWithPath: ssh).deletingLastPathComponent().path + ":/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
    func stderr(_ process: Process) -> String {
        String(decoding: (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(), as: UTF8.self)
    }
    do {
        let lease = manager.acquire(destination, environment: ["PATH": "/usr/bin:/bin"])
        let first = try #require(await manager.waitUntilUp(destination), "the first master")
        // The control helper's channel.
        channels.append(try channel(first, "sleep 8"))
        // Two adapter launches fill the first master; the one before the
        // last free slot starts the second.
        #expect(manager.controlPath(forLaunch: "/launch/1", destination: destination) == first)
        channels.append(try channel(first, "sleep 8"))
        var second: String?
        for _ in 0..<400 {
            if let status = manager.shardStatuses(of: destination).last, status.shard == 2, status.phase == .up {
                second = status.controlPath
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let secondPath = try #require(second, "a second master")
        #expect(secondPath != first)
        #expect(manager.controlPath(forLaunch: "/launch/2", destination: destination) == first)
        channels.append(try channel(first, "sleep 8"))
        try await Task.sleep(for: .milliseconds(300))
        // The first connection is full now: sshd refuses a fourth session.
        let ended = channels.filter { !$0.isRunning }
        var endedErrors: [String] = []
        for process in ended { endedErrors.append(stderr(process)) }
        #expect(ended.isEmpty, "\(endedErrors)")
        let refused = try channel(first, "true")
        refused.waitUntilExit()
        // (OpenSSH then connects on its own, the fake exits 255: either way
        // not through that master.)
        let refusal = stderr(refused)
        #expect(refusal.contains("Session open refused by peer"))
        // The third launch shares the second master instead, and runs.
        #expect(manager.controlPath(forLaunch: "/launch/3", destination: destination) == secondPath)
        let third = try channel(secondPath, "echo SHARD")
        third.waitUntilExit()
        #expect(third.terminationStatus == 0, "\(stderr(third))")
        // (A third starts as the spare: the second has one free slot left.)
        #expect(Array(manager.shardStatuses(of: destination).map(\.launches).prefix(2)) == [2, 1])
        for process in channels where process.isRunning { process.terminate() }
        for launch in ["/launch/1", "/launch/2", "/launch/3"] { manager.endLaunch(launch) }
        lease.release()
        for _ in 0..<200 where !manager.shardStatuses(of: destination).allSatisfy({ $0.phase == .stopped }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.shardStatuses(of: destination).allSatisfy { $0.phase == .stopped })
    } catch {
        for process in channels where process.isRunning { process.terminate() }
        manager.stopAll()
        await fake?.tearDown()
        throw error
    }
    manager.stopAll()
    await fake?.tearDown()
}

// MARK: - A master with no session to spare

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostShellAndScpConnectDirectlyWhenTheMasterRefusesASession() async throws {
    let mac = try FakeRemoteMac(name: "refusing", startsDaemon: false)
    // Short: control sockets must fit a Unix socket path.
    let sockets = FileManager.default.temporaryDirectory.appendingPathComponent("ch-rf-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: sockets) }
    let ssh = mac.bin.appendingPathComponent("ssh").path
    let manager = HostSSHMasterManager(configuration: .init(
        directory: { sockets }, sshExecutable: { _ in ssh }, startTimeout: 10, healthCheckInterval: 3_600, idleStopDelay: 0.2
    ))
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-refused-\(UUID().uuidString.prefix(8)).txt")
    try "hello".write(to: local, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: local) }
    do {
        // The master is up, but has no session to spare (MaxSessions 0).
        try Data().write(to: mac.root.appendingPathComponent("masters"))
        try "0".write(to: mac.root.appendingPathComponent("max-sessions"), atomically: true, encoding: .utf8)
        let lease = manager.acquire("refusing", environment: ["PATH": "/usr/bin:/bin"])
        defer { lease.release() }
        let controlPath = try #require(await manager.waitUntilUp("refusing"))
        var shell = mac.shell
        shell.controlPath = controlPath
        let output = await shell.run("echo DIRECT-OK\n", on: "refusing")
        #expect(output.status == 0, "\(output.standardError)")
        #expect(output.standardOutput.contains("DIRECT-OK"))
        let copier = RemoteFileCopier(shell: shell, destination: "refusing", machine: "Refusing")
        let paths = try await copier.copy([local])
        #expect(try String(contentsOfFile: paths[0], encoding: .utf8) == "hello")
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path)
        // Each went to the master first (refused), then directly.
        let viaMaster = mac.calls.filter { $0.contains(controlPath) && !$0.contains("-O ") && !$0.contains("-M ") }
        #expect(viaMaster.count >= 2, "\(mac.calls)")
        manager.stopAll()
    } catch {
        manager.stopAll()
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}

// MARK: - Looking at a device starts nothing there

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostLookingAtADeviceNeverStartsItsDaemon() async throws {
    let mac = try FakeRemoteMac(name: "looked", startsDaemon: false)
    do {
        let control = mac.makeControl()
        // No daemon there: the look says so, and starts none.
        #expect(await control.listWithoutStarting() == .notRunning)
        #expect(!FileManager.default.fileExists(atPath: mac.socket.path))
        #expect(mac.calls.contains { $0.contains("gateway --no-start") })
        #expect(control.state == .idle)
        // The Background Sessions panel and the picker, through the shared
        // throttle: nothing either.
        let peeks = RemoteDevicePeeks(startMonitoring: {})
        #expect(await peeks.refresh(control) == .notRunning)
        #expect(!FileManager.default.fileExists(atPath: mac.socket.path))
        // Its daemon started by the other Mac's own Cherry: the look lists it.
        let theirs = try mac.startSessionStartingDaemon(["/bin/sleep", "60"])
        guard case .listed(let list) = await control.listWithoutStarting() else {
            Issue.record("not listed")
            await mac.tearDown()
            return
        }
        #expect(list.sessions.map(\.id) == [theirs])
        #expect(control.state == .idle && control.sessions.isEmpty)
        // A refused login is reported as such (and blocks the throttle).
        mac.set("denied", true)
        peeks.retry(control.host)
        guard case .failed(let error)? = await peeks.refresh(control) else {
            Issue.record("not failed")
            await mac.tearDown()
            return
        }
        #expect(error.isAuthenticationFailure, "\(error)")
        #expect(!peeks.mayPeek(control.host))
        mac.set("denied", false)
    } catch {
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}

// MARK: - A device offline when its window opens

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostOfflineWindowReadsItsProjectOnceTheDeviceConnects() async throws {
    let mac = try FakeRemoteMac()
    let control = mac.makeControl()
    let hosting = mac.makeHosting(control: control)
    var window: RepositoryWorkspace?
    let key = mac.projectKey
    defer { RemoteProjectFiles.shared.set(nil, for: key) }
    do {
        try "[[commands]]\nname = \"server\"\ncommand = \"sleep 600\"\nautoStart = true\n"
            .write(toFile: mac.projectPath + "/cherry.toml", atomically: true, encoding: .utf8)
        mac.set("offline", true)
        let repository = deviceWindow(mac, hosting: hosting, access: access(mac))
        window = repository
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        repository.autoStartInitialCommandsIfNeeded()
        await repository.refresh()
        // Not read: auto-start keeps waiting, and the window says why.
        #expect(!repository.remoteProjectLoaded)
        #expect(repository.remoteProjectNote?.contains("could not be reached") == true)
        #expect(repository.activeWorkspace.commandSession(named: "server") == nil)
        // The device answers and its control connects: its project is read,
        // and its commands start.
        mac.set("offline", false)
        _ = try await control.list()
        try await mac.waitFor("the project to be read") { repository.remoteProjectLoaded }
        try await mac.waitFor("the auto-started command") {
            repository.activeWorkspace.commandSession(named: "server")?.persistentSession != nil
        }
    } catch {
        mac.set("offline", false)
        window?.closeAllSessions(intent: .windowClosed)
        await mac.tearDown()
        throw error
    }
    window?.closeAllSessions(intent: .windowClosedEndingSessions)
    await mac.tearDown()
}

// MARK: - New Worktree without a recorded home

@Test(.enabled(if: parityRealHostEnabled))
@MainActor func RemoteDeviceRealHostNewWorktreeAsksTheDeviceForItsHome() async throws {
    let mac = try FakeRemoteMac(startsDaemon: false)
    do {
        try git(mac.projectPath, ["init", "-q", "-b", "main"])
        try git(mac.projectPath, ["commit", "-q", "--allow-empty", "-m", "first"])
        var recorded: [String] = []
        let shell = mac.shell
        let access = RemoteProjectAccess(
            deviceID: mac.deviceID, deviceName: "Studio", destination: mac.name,
            remoteHostPath: nil, homeDirectory: nil, shell: { shell }, recordHome: { recorded.append($0) }
        )
        let control = mac.makeControl()
        let repository = deviceWindow(mac, hosting: mac.makeHosting(control: control), access: access, autoStartCommands: { _ in [] })
        let destination = ProjectLocation.launchPath(forKey: try await repository.managedWorktreeDestination(branchName: "b"))
        // Under the device's home, never next to the project.
        #expect(destination.hasPrefix(mac.home.path + "/.cherry/worktrees/app-"))
        #expect(recorded == [mac.home.path])
        // Offline, with no home recorded: refused, not guessed.
        mac.set("offline", true)
        await #expect(throws: RemoteProjectError.self) { _ = try await repository.managedWorktreeDestination(branchName: "c") }
        mac.set("offline", false)
        repository.closeAllSessions(intent: .windowClosed)
    } catch {
        mac.set("offline", false)
        await mac.tearDown()
        throw error
    }
    await mac.tearDown()
}
