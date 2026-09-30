import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// Devices (docs/specs/remote-devices.md, phase 1) without a real SSH host:
// the device store, the Add Mac check's parsing, the picker's model, the
// discovery of a device's projects, saved records of device tabs, and ends
// recorded while a device is offline (against the in-process fake
// `cherry control`, FakeControlHelper). RemoteDeviceRealHostTests runs the
// same flows through a fake remote Mac (Scripts/fake-remote-mac).

// MARK: - Helpers

private func temporaryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeStore(
    directory: URL,
    hostStore: HostedSessionHostStore,
    registry: PersistentHostingRegistry = PersistentHostingRegistry(local: PersistentHostSessions(
        installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
    )),
    paths: HostedRemoteHostPaths = HostedRemoteHostPaths(),
    canWrite: @escaping @MainActor () -> Bool = { true },
    installationID: UUID? = UUID()
) -> RemoteDeviceStore {
    RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        canWrite: canWrite,
        hostStore: hostStore,
        installationID: { installationID },
        registry: registry,
        remoteHostPaths: paths,
        makeHosting: { profile, installation in
            PersistentHostSessions.remote(
                profile: profile,
                installationID: installation,
                // Never connected: a helper that cannot start.
                control: { unusedControl(for: profile.host, hostStore: hostStore) },
                installationUnavailableReason: { nil },
                status: PersistentSessionsStatus(),
                instanceLock: nil,
                terminalColors: { nil }
            )
        }
    )
}

/// A control connection a unit test never opens.
@MainActor
private func unusedControl(for host: HostedSessionHost, hostStore: HostedSessionHostStore) -> HostControl {
    HostControl(
        host: host,
        clientProvider: { throw HostedSessionError.message("no helper in unit tests") },
        hostStore: hostStore,
        masters: disabledSSHMasters,
        launcher: { _ in throw HostedSessionError.message("no helper in unit tests") },
        localHostUnavailableReason: nil,
        configuration: .fastTests
    )
}

private func session(
    _ id: String,
    owner: String?,
    project: String?,
    state: HostedSessionState = .running,
    createdAt: UInt64 = 1,
    tab: UUID? = nil
) -> HostedSessionInfo {
    var tags: [String: String] = [:]
    if let project { tags[PersistentSessionTag.project] = project }
    if let tab { tags[PersistentSessionTag.tab] = tab.uuidString }
    return HostedSessionInfo(
        id: id, name: "Shell \(id)", cwd: "/Users/me", state: state, pid: 7,
        exitCode: state == .exited ? 0 : nil, owner: owner, tags: tags, createdAt: createdAt
    )
}

// MARK: - Device store

@Test @MainActor func aDeviceStoreKeepsItsMacsInDevicesJSONAndSharesTheirHostsAndPaths() async throws {
    let directory = try temporaryDirectory("devices")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let paths = HostedRemoteHostPaths()
    let store = makeStore(directory: directory, hostStore: hostStore, paths: paths)

    let studio = try store.add(
        name: " Studio ", sshDestination: "me@studio.local",
        remoteHostPath: "~/Library/Application Support/Cherry/bin/cherry-host",
        machineNames: ["studio", "studio.local", ""], homeDirectory: "/Users/me"
    )
    #expect(studio.name == "Studio")
    #expect(studio.machineNames == ["studio", "studio.local"])
    // Its destination is a saved SSH host (its identity is pinned there).
    #expect(hostStore.hosts.contains(try HostedSessionHost.ssh("me@studio.local")))
    // Its cherry-host path reaches the CLI's arguments.
    #expect(paths.path(for: "me@studio.local") == "~/Library/Application Support/Cherry/bin/cherry-host")
    // The same destination twice is refused, and so is an option.
    #expect(throws: (any Error).self) { try store.add(name: "Again", sshDestination: "me@studio.local") }
    #expect(throws: (any Error).self) { try store.add(name: "Bad", sshDestination: "-oProxyCommand=x") }

    store.addProject(path: "/Users/me/work/app/", to: studio.id)
    store.addProject(path: "/Users/me/work/api", to: studio.id)
    store.hideProject(path: "/Users/me/work/api", on: studio.id)
    store.rename(studio.id, to: "Mac Studio")
    let saved = try #require(store.device(id: studio.id))
    #expect(saved.addedProjects == ["/Users/me/work/app"])
    #expect(saved.hiddenProjects == ["/Users/me/work/api"])
    #expect(saved.name == "Mac Studio")
    #expect(store.device(forProjectKey: saved.projectKey(path: "/Users/me/work/app"))?.id == studio.id)
    #expect(store.device(forProjectKey: "/Users/me/work/app") == nil)

    // Another store reads the same file.
    let reread = makeStore(directory: directory, hostStore: hostStore, paths: HostedRemoteHostPaths())
    #expect(reread.devices == store.devices)
    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(json.contains("\"version\" : 1"))

    // Removing forgets its host and path; its sessions are not touched
    // (nothing connected: the hosting's control would record an issue).
    store.remove(studio.id)
    #expect(store.devices.isEmpty)
    #expect(!hostStore.hosts.contains(try HostedSessionHost.ssh("me@studio.local")))
    #expect(paths.path(for: "me@studio.local") == nil)
}

/// The Omni bar's folders add a device's folder through the same path as
/// Add Project on <Mac>…: resolved there, added to the device, keyed
/// `device:<uuid>:<path>`.
@Test @MainActor func RemoteDeviceOmniFoldersAddAFolderAsTheDevicesProjectKey() async throws {
    let directory = try temporaryDirectory("devices-omni-add")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    var writable = true
    let store = makeStore(directory: directory, hostStore: hostStore, canWrite: { writable })
    let studio = try store.add(name: "Studio", sshDestination: "me@studio.local", homeDirectory: "/Users/me")
    store.hideProject(path: "/Users/me/github/duck-dash", on: studio.id)
    var asked: [String] = []
    let resolve: RemoteDeviceProjectAdding.Resolver = { path, device in
        asked.append("\(device.sshDestination) \(path)")
        // As `pwd -P` there reports it.
        return .success("/Users/me/github/duck-dash")
    }
    let key = try await RemoteDeviceProjectAdding.add("~/github/duck-dash", to: studio.id, store: store, resolve: resolve).get()
    #expect(key == ProjectLocation.remote(deviceID: studio.id, path: "/Users/me/github/duck-dash").key)
    #expect(key == "device:\(studio.id.uuidString.lowercased()):/Users/me/github/duck-dash")
    #expect(asked == ["me@studio.local ~/github/duck-dash"])
    let saved = try #require(store.device(id: studio.id))
    #expect(saved.addedProjects == ["/Users/me/github/duck-dash"])
    // Adding it again takes it out of the hidden ones.
    #expect(saved.hiddenProjects.isEmpty)

    // A folder that is not there, a Mac no longer known, or a copy that
    // does not keep the Macs: nothing added.
    let missing: RemoteDeviceProjectAdding.Resolver = { _, _ in .failure(.message("There is no folder at ~/nope on that Mac.")) }
    let failure = await RemoteDeviceProjectAdding.add("~/nope", to: studio.id, store: store, resolve: missing)
    #expect(failure == .failure(.message("There is no folder at ~/nope on that Mac.")))
    if case .success = await RemoteDeviceProjectAdding.add("~/x", to: UUID(), store: store, resolve: resolve) {
        Issue.record("added on an unknown Mac")
    }
    writable = false
    if case .success = await RemoteDeviceProjectAdding.add("~/y", to: studio.id, store: store, resolve: resolve) {
        Issue.record("added by a copy that does not keep the Macs")
    }
    #expect(asked.count == 1)
    #expect(store.device(id: studio.id)?.addedProjects == ["/Users/me/github/duck-dash"])
}

@Test @MainActor func onlyTheInstanceLockHolderWritesDevicesAndEachDeviceGetsOneRemoteHosting() throws {
    let directory = try temporaryDirectory("devices-lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let installation = UUID()
    let registry = PersistentHostingRegistry(local: PersistentHostSessions(
        installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
    ))
    // A copy that does not hold the lock changes nothing.
    let readOnly = makeStore(directory: directory, hostStore: hostStore, registry: registry, canWrite: { false })
    #expect(!readOnly.canModify)
    #expect(throws: (any Error).self) { try readOnly.add(name: "Studio", sshDestination: "studio") }
    #expect(readOnly.devices.isEmpty && hostStore.hosts.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: readOnly.fileURL.path))

    let store = makeStore(directory: directory, hostStore: hostStore, registry: registry, installationID: installation)
    let studio = try store.add(name: "Studio", sshDestination: "studio2", machineNames: ["studio"])
    let hosting = try #require(store.hosting(for: studio.id))
    #expect(store.hosting(for: studio.id) === hosting)
    #expect(registry.hosting(for: try HostedSessionHost.ssh("studio2")) === hosting)
    #expect(hosting.owner == PersistentHostSessions.remoteOwner(installationID: installation))
    #expect(!hosting.profile.allowsNativeFallback && !hosting.profile.isThisMac)
    #expect(hosting.profile.displayName == "Studio")
    #expect(hosting.profile.machineNames() == ["studio"])
    // No installation id (another copy holds the lock): no hosting.
    let noInstallation = makeStore(directory: directory, hostStore: hostStore, registry: registry, installationID: nil)
    #expect(noInstallation.hosting(for: studio.id) == nil)
    // Removing a device with no open tab unregisters its hosting.
    store.remove(studio.id)
    #expect(registry.hosting(for: try HostedSessionHost.ssh("studio2")) == nil)
}

@Test @MainActor func aWindowOfAnUnknownDeviceFailsItsTabsInsteadOfRunningThemHere() async throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let hosting = RemoteDeviceStore.unavailableHosting(for: key, reason: "Not among your devices.", instanceLock: nil)
    #expect(!hosting.profile.allowsNativeFallback)
    await #expect(throws: HostedSessionError.unavailable("Not among your devices.")) {
        _ = try await hosting.create(
            PersistentSessionRequest(tabID: UUID(), name: "Shell", kind: .terminal, columns: 80, rows: 24),
            configuration: ShellProcessController.Configuration(
                shellPath: "/bin/zsh", workingDirectory: "/Users/me/app", term: "xterm-256color",
                initialSize: TerminalViewportSize(columns: 80, rows: 24)
            )
        )
    }
}

// MARK: - SSH config

@Test func sshConfigAliasesSkipPatternsAndFollowIncludes() throws {
    let directory = try temporaryDirectory("ssh-config")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("config.d"), withIntermediateDirectories: true)
    try """
    # Global
    Include config.d/*
    Host studio studio-lan
      HostName studio.local
    Host *.corp !bastion web-?? "quoted alias"
      User me
    Host=devbox
    Host   mini # a comment
    Match host foo
      User x
    Host *
      ServerAliveInterval 30
    """.write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    try "Host work-mac\n  HostName 10.0.0.5\nHost studio\n".write(
        to: directory.appendingPathComponent("config.d/work"), atomically: true, encoding: .utf8
    )
    let aliases = SSHConfigHosts.aliases(configAt: directory.appendingPathComponent("config"), sshDirectory: directory)
    #expect(aliases == ["studio", "studio-lan", "devbox", "mini", "work-mac"])
    #expect(SSHConfigHosts.suggestions(for: "st", among: aliases) == ["studio", "studio-lan"])
    #expect(SSHConfigHosts.suggestions(for: "STUDIO-L", among: aliases) == ["studio-lan"])
    #expect(SSHConfigHosts.suggestions(for: "", among: aliases) == aliases)
    #expect(SSHConfigHosts.aliases(configAt: directory.appendingPathComponent("missing")).isEmpty)
}

// MARK: - The check

@Test func sshFailuresAreExplainedByKind() {
    #expect(RemoteDeviceSSHFailure.classify("ssh: connect to host studio port 22: Connection timed out")
        == .unreachable("ssh: connect to host studio port 22: Connection timed out"))
    #expect(RemoteDeviceSSHFailure.classify("No ED25519 host key is known for studio and you have requested strict checking.\nHost key verification failed.")
        == .hostKey("Host key verification failed."))
    #expect(RemoteDeviceSSHFailure.classify("me@studio: Permission denied (publickey).")
        == .permissionDenied("me@studio: Permission denied (publickey)."))
    #expect(RemoteDeviceSSHFailure.classify("ssh: Could not resolve hostname nosuch: nodename nor servname provided, or not known")
        == .unknownHost("ssh: Could not resolve hostname nosuch: nodename nor servname provided, or not known"))
    #expect(RemoteDeviceSSHFailure.classify("", timedOut: true) == .unreachable("ssh did not finish within the time allowed."))
    if case .other = RemoteDeviceSSHFailure.classify("kex_exchange_identification: weird") {} else { Issue.record("not other") }
    // Help for each.
    #expect(RemoteDeviceSSHFailure.permissionDenied("x").help.contains("authorized_keys"))
    #expect(RemoteDeviceSSHFailure.unreachable("x").help.contains("Remote Login"))
}

@Test func theCheckScriptQuotesTheHostPathForShAndParsesWhatTheMacReports() {
    #expect(RemoteDeviceProbe.shellWord("~/Library/Application Support/Cherry/bin/cherry-host")
        == #""$HOME"/'Library/Application Support/Cherry/bin/cherry-host'"#)
    #expect(RemoteDeviceProbe.shellWord("/opt/it's/cherry-host") == #"'/opt/it'\''s/cherry-host'"#)
    #expect(RemoteDeviceProbe.script(remoteHostPath: "/opt/cherry-host").contains("host='/opt/cherry-host'"))
    #expect(RemoteDeviceProbe.script(remoteHostPath: nil).contains("command -v cherry-host"))

    let output = RemoteDeviceShell.Output(status: 0, standardOutput: """
    motd junk from a startup file
    CHERRY-PROBE 1
    uname=Darwin arm64
    macos=26.0
    computer=Studio
    localhost=studio
    hostname=studio.lan
    home=/Users/me
    shell=/bin/zsh
    hostpath=/Users/me/Library/Application Support/Cherry/bin/cherry-host
    version={"protocol":\(HostProtocol.version),"build":"b1","version":"1.2.3","os":"macos","arch":"aarch64","min_macos":"11.0"}
    status={"running":true,"state":"ok","protocol":\(HostProtocol.version),"build":"b1","host_id":"h1"}
    fda=no
    keychain=locked
    CHERRY-PROBE-END

    """, standardError: "")
    let result = RemoteDeviceProbe.parse(output)
    #expect(result.sshFailure == nil)
    #expect(result.isMac && result.architecture == "arm64" && result.macOSVersion == "26.0")
    #expect(result.machineNames == ["studio.lan", "studio", "studio.local"])
    #expect(result.hostVersion?.protocol == HostProtocol.version)
    #expect(result.hostStatus?.host_id == "h1")
    #expect(result.fullDiskAccess == false && result.keychainUnlocked == false)
    #expect(AddDeviceModel.remoteHostPath(found: result.hostPath, home: result.homeDirectory)
        == "~/Library/Application Support/Cherry/bin/cherry-host")
    #expect(AddDeviceModel.remoteHostPath(found: "/opt/homebrew/bin/cherry-host", home: "/Users/me") == nil)

    let checklist = RemoteDeviceChecklist(result: result, destination: "studio")
    #expect(checklist.canAdd && checklist.hostIsCompatible)
    #expect(checklist.suggestedName == "Studio")
    #expect(checklist.items.map(\.id) == ["ssh", "system", "host", "fda", "keychain"])
    #expect(checklist.items.map(\.status) == [.ok, .ok, .ok, .warning, .warning])

    // ssh failed before the script ran.
    let failed = RemoteDeviceProbe.parse(.init(status: 255, standardOutput: "", standardError: "Host key verification failed."))
    let failedList = RemoteDeviceChecklist(result: failed, destination: "studio")
    #expect(!failedList.canAdd)
    #expect(failedList.items.first?.action == .openInTerminal)
}

@Test func theChecklistSaysWhenTheSessionHostIsMissingOrSpeaksAnotherProtocol() {
    var result = RemoteDeviceProbeResult(uname: "Darwin x86_64", macOSVersion: "15.5", computerName: "Mini")
    // Missing: a warning with manual instructions; the Mac can still be added.
    var checklist = RemoteDeviceChecklist(result: result, destination: "mini", localProtocol: 7)
    #expect(checklist.canAdd && !checklist.hostIsCompatible)
    let missing = checklist.items.first { $0.id == "host" }
    #expect(missing?.status == .warning)
    #expect(missing?.detail?.contains("copy this Cherry's helpers there by hand") == true)
    #expect(missing?.detail?.contains("ssh mini") == true)

    // Another protocol.
    result.hostVersion = RemoteHostVersionReport(protocol: 6, build: "old", version: "0.9")
    checklist = RemoteDeviceChecklist(result: result, destination: "mini", localProtocol: 7)
    #expect(checklist.items.first { $0.id == "host" }?.status == .failure)
    #expect(!checklist.hostIsCompatible)

    // Same protocol, but the other Mac's Cherry runs a daemon of another.
    result.hostVersion = RemoteHostVersionReport(protocol: 7)
    result.hostStatus = RemoteHostStatusReport(running: true, state: "ok", protocol: 6)
    checklist = RemoteDeviceChecklist(result: result, destination: "mini", localProtocol: 7)
    #expect(checklist.items.first { $0.id == "daemon" }?.status == .failure)
    #expect(!checklist.hostIsCompatible)

    // Not a Mac.
    let linux = RemoteDeviceChecklist(result: RemoteDeviceProbeResult(uname: "Linux x86_64"), destination: "box")
    #expect(!linux.canAdd)
}

// MARK: - Discovery

@Test func aDevicesProjectsComeFromEveryOwnersProjectTagsPlusAddedMinusHidden() {
    let ours = PersistentHostSessions.remoteOwner(installationID: UUID())
    let device = UUID()
    let otherInstallation = UUID()
    let sessions = [
        session("a", owner: ours, project: ProjectLocation.remote(deviceID: device, path: "/Users/me/app").key),
        // The other Mac's own Cherry tags the path itself.
        session("b", owner: "Cherry", project: "/Users/me/app"),
        // Another installation's key for the same folder.
        session("c", owner: "Cherry@X", project: ProjectLocation.remote(deviceID: otherInstallation, path: "/Users/me/app/").key),
        session("d", owner: "Cherry", project: "/Users/me/api"),
        session("e", owner: "Cherry", project: "/Users/me/secret"),
        // Untagged (the CLI, another client) and a tag that is no path.
        session("f", owner: nil, project: nil),
        session("g", owner: "Cherry", project: "relative/path"),
    ]
    let (projects, other) = RemoteDeviceDiscovery.projects(
        sessions: sessions, added: ["/Users/me/Zeta", "/Users/me/api"], hidden: ["/Users/me/secret"]
    )
    #expect(projects.map(\.path) == ["/Users/me/api", "/Users/me/app", "/Users/me/Zeta"])
    #expect(projects.map(\.sessionCount) == [1, 3, 0])
    #expect(projects.map(\.isAdded) == [true, false, true])
    #expect(other == 2)
    #expect(RemoteDeviceDiscovery.projectPath(ofTag: "  ") == nil)

    // A window's "Not open here": the project's sessions no tab shows.
    let notOpen = RemoteDeviceDiscovery.notOpenSessions(
        in: sessions + [session("h", owner: "Cherry", project: "/Users/me/app", state: .exited)],
        projectPath: "/Users/me/app",
        owner: ours,
        isShown: { $0.id == "c" },
        isEnding: { _ in false }
    )
    #expect(notOpen.own.map(\.id) == ["a"])
    // Another owner's ended session is left out.
    #expect(notOpen.others.map(\.id) == ["b"])
    #expect(RemoteNotOpenSection.ownerLabel(sessions[0], ownOwner: ours) == "This Cherry's")
    #expect(RemoteNotOpenSection.ownerLabel(sessions[1], ownOwner: ours) == "Cherry on that Mac")
    #expect(RemoteNotOpenSection.ownerLabel(sessions[2], ownOwner: ours) == "Another Cherry's")
    #expect(RemoteNotOpenSection.ownerLabel(sessions[5], ownOwner: ours) == "Another client's")
}

// MARK: - The picker

@Test func thePickerModelListsDevicesWithTheirStateProjectsAndActions() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let studioID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000A001"))
    let miniID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000A002"))
    let laptopID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000A003"))
    let ours = PersistentHostSessions.remoteOwner(installationID: UUID())
    let studio = RemoteDevice(
        id: studioID, name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me",
        addedProjects: ["/Users/me/notes"], hiddenProjects: ["/Users/me/secret"]
    )
    let mini = RemoteDevice(id: miniID, name: "Mini", sshDestination: "mini", lastSeen: now.addingTimeInterval(-7_200))
    let laptop = RemoteDevice(id: laptopID, name: "Laptop", sshDestination: "laptop")
    let studioSessions = [
        session("a", owner: ours, project: studio.projectKey(path: "/Users/me/app")),
        session("b", owner: "Cherry", project: "/Users/me/app"),
        session("c", owner: "Cherry", project: "/Users/me/secret"),
        session("d", owner: nil, project: nil),
    ]
    let model = TitlebarProjectMenuModel(
        worktrees: nil,
        projects: [
            .init(root: "/Users/local/site", name: "site", isSelected: false),
        ],
        devices: [
            .init(device: studio, state: .connected(sessionCount: 4), sessions: studioSessions),
            .init(device: mini, state: RemoteDeviceConnectionState(
                control: .waitingToReconnect(.unavailable("ssh: connect to host mini port 22: Connection timed out")),
                sessionCount: 0, lastSeen: mini.lastSeen
            ), sessions: []),
            .init(device: laptop, state: .identityChanged(reason: "Expected host identity a, received b."), sessions: []),
        ],
        currentProjectKey: studio.projectKey(path: "/Users/me/app"),
        now: now
    )
    #expect(model.snapshot == """
    ## Projects
    site
    ---
    Add Project...
    Edit Projects...
    ---
    ## Devices
    [x] ●green Studio — Connected · 4 sessions
      [x] app — 2 sessions · /Users/me/app
      ⌥ Hide app — /Users/me/app
      notes — /Users/me/notes
      ⌥ Hide notes — /Users/me/notes
      Other sessions — 1 session
      ---
      Open Home Folder — /Users/me
      Add Project on Studio…
      ---
      ●green Connected (off)
      Persistent Sessions on Studio…
      Set Up Cherry MCP on Studio…
      ---
      Rename…
      Remove…
    ●gray Mini — Offline
      No Projects (off)
      ---
      Open Home Folder (off)
      Add Project on Mini…
      ---
      ●gray Offline: ssh: connect to host mini port 22: Connection timed out (off)
      Reconnect
      Persistent Sessions on Mini…
      Set Up Cherry MCP on Mini…
      ---
      Rename…
      Remove…
    ●red Laptop — Its identity changed
      No Projects (off)
      ---
      Open Home Folder (off)
      Add Project on Laptop… (off)
      ---
      ●red Identity changed: Expected host identity a, received b. (off)
      Trust New Identity…
      Persistent Sessions on Laptop…
      Set Up Cherry MCP on Laptop… (off)
      ---
      Rename…
      Remove…
    Add Mac…
    """)
    // Each item says what it does.
    let studioItem = try #require(model.deviceItems[studioID])
    let actions = (studioItem.children ?? []).compactMap { entry -> TitlebarProjectMenuModel.Action? in
        if case .item(let item) = entry { return item.action }
        return nil
    }
    #expect(actions == [
        .openDeviceProject(deviceID: studioID, path: "/Users/me/app"),
        .hideDeviceProject(deviceID: studioID, path: "/Users/me/app"),
        .openDeviceProject(deviceID: studioID, path: "/Users/me/notes"),
        .hideDeviceProject(deviceID: studioID, path: "/Users/me/notes"),
        .openDeviceSessions(studioID),
        .openDeviceHome(studioID),
        .addDeviceProject(studioID),
        .openDeviceSessions(studioID),
        .setUpDeviceMCP(studioID),
        .renameDevice(studioID),
        .removeDevice(studioID),
    ])
}

@Test func thePickerModelSaysHowEachDeviceStands() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let states: [(RemoteDeviceConnectionState, String, RemoteDeviceConnectionState.Dot)] = [
        (.unknown(lastSeen: nil), "Not checked yet", .gray),
        (.unknown(lastSeen: now.addingTimeInterval(-30)), "Last seen just now", .gray),
        (.unknown(lastSeen: now.addingTimeInterval(-600)), "Last seen 10 min ago", .gray),
        (.unknown(lastSeen: now.addingTimeInterval(-86_400 * 3)), "Last seen 3 days ago", .gray),
        (.connecting, "Connecting…", .yellow),
        (.connected(sessionCount: 1), "Connected · 1 session", .green),
        (.offline(reason: "x"), "Offline", .gray),
        (.loginRefused(reason: "x"), "SSH login refused", .red),
        (.incompatible(reason: "x"), "Needs the same Cherry version", .red),
    ]
    for (state, subtitle, dot) in states {
        #expect(state.subtitle(now: now) == subtitle)
        #expect(state.dot == dot)
    }
    #expect(RemoteDeviceConnectionState.failure(.unavailable("studio: Permission denied (publickey).")) == .loginRefused(reason: "studio: Permission denied (publickey)."))
    #expect(RemoteDeviceConnectionState.failure(.identityMismatch("x")) == .identityChanged(reason: "x"))
    #expect(RemoteDeviceConnectionState.failure(.unavailable("The session host speaks protocol 6, but this Cherry speaks 7.")).offersReconnect)
    #expect(!RemoteDeviceConnectionState.connected(sessionCount: 0).offersReconnect)
    // This Mac's projects and the worktrees are listed as before.
    let model = TitlebarProjectMenuModel(
        worktrees: [.init(root: "/p", name: "main", isActive: true, isHidden: false), .init(root: "/p-x", name: "x", isActive: false, isHidden: true)],
        projects: [],
        devices: [],
        currentProjectKey: "/p"
    )
    #expect(model.snapshot == """
    ## Worktrees
    [x] main
    x — Hidden
    New Worktree...
    Manage Worktrees...
    ---
    No Projects (off)
    ---
    Add Project...
    Edit Projects...
    ---
    ## Devices
    Add Mac…
    """)
}

// MARK: - Saved records and restore wording

@Test func aDeviceRecordSavedWhileItsCreateRanNamesItsHost() throws {
    let studio = try HostedSessionHost.ssh("studio")
    let unbound = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/Users/me",
        launchRequestID: "abc", hostKey: studio.id
    )
    #expect(unbound.mayOwnSession(on: studio))
    #expect(!unbound.mayOwnSession(on: .local))
    #expect(!unbound.mayOwnLocalSession)
    #expect(unbound.ownsRemoteSession)
    #expect(unbound.identifyingSession.hostKey == studio.id)
    // A record without a host key is This Mac's, as before.
    let local = WorkspaceSessionRecord(id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/", launchRequestID: "abc")
    #expect(local.mayOwnLocalSession && !local.mayOwnSession(on: studio) && !local.ownsRemoteSession)
    // Round trip; older files decode without it.
    let data = try JSONEncoder().encode(unbound)
    #expect(try JSONDecoder().decode(WorkspaceSessionRecord.self, from: data) == unbound)
}

@Test @MainActor func aDeviceSessionItsHostReportsLostComesBackEndedWhenThatMacRestarted() throws {
    let studio = try HostedSessionHost.ssh("studio")
    let record = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/Users/me",
        hosted: HostedSessionBindingRecord(host: studio.id, hostID: "remote-host", sessionID: "s1", owned: true),
        savedAt: Date(timeIntervalSince1970: 10)
    )
    let ends = SystemEndedSessions(
        savedAt: nil,
        // This Mac booted after the record was saved: that says nothing of Studio.
        bootTime: Date(timeIntervalSince1970: 1_000),
        systemQuits: [Date(timeIntervalSince1970: 500)],
        endedOnPurpose: { _ in false }
    )
    let gone = HostedSessionList(hostID: "remote-host", sessions: [])
    #expect(ends.end(of: record, missingFrom: gone) == nil)
    let lost = HostedSessionList(hostID: "remote-host", sessions: [], lostSessionIDs: ["s1"])
    let end = try #require(ends.end(of: record, missingFrom: lost))
    #expect(end == .hostRestart)
    #expect(end.message(machine: "Studio") == "Ended when Studio restarted")
    #expect(end.predicate(machine: "Studio") == " ended when Studio restarted")
    #expect(SystemSessionEnd.restart.message == "Ended when the Mac restarted")
    // Saved and read back.
    #expect(try JSONDecoder().decode(SystemSessionEnd.self, from: JSONEncoder().encode(end)) == .hostRestart)
}

@Test @MainActor func windowsOfDeviceProjectsReopenOnlyWhileTheirDeviceIsKnown() throws {
    let directory = try temporaryDirectory("reopen")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let known = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let unknown = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    for key in [known, unknown] {
        store.saveSynchronously(RepositoryStateRecord(
            repositoryRoot: key,
            activeWorktreeRoot: key,
            worktrees: [WorktreeStateRecord(root: key, sessions: [WorkspaceSessionRecord(
                id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/Users/me/app",
                hosted: HostedSessionBindingRecord(host: "ssh:studio", hostID: "h", sessionID: "s", owned: true)
            )])],
            savedAt: Date()
        ))
    }
    store.saveOpenProjectWindowRoots([known, unknown], synchronously: true)
    #expect(store.projectWindowRootsToReopen(remoteProjectIsKnown: { $0 == known }) == [known])
    #expect(store.projectWindowRootsToReopen().isEmpty)
}

@Test @MainActor func aDeviceProjectsRepositoryKeepsItsKeyAndHasNoGitOrCommands() throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/work/app").key
    let hosting = PersistentHostSessions.remote(
        profile: .remote(host: try HostedSessionHost.ssh("studio"), displayName: "Studio"),
        installationID: UUID(),
        control: { unusedControl(for: try! HostedSessionHost.ssh("studio"), hostStore: HostedSessionHostStore(defaults: UserDefaults(suiteName: "CherryTests.RemoteDevice.unused")!)) },
        installationUnavailableReason: { nil },
        status: PersistentSessionsStatus(),
        instanceLock: nil,
        terminalColors: { nil }
    )
    let repository = RepositoryWorkspace(projectRoot: key, backendPolicy: .remote(hosting, settings: { .native }, hostReconnects: nil))
    defer { repository.closeAllSessions(intent: .windowClosed) }
    #expect(repository.isRemote)
    #expect(repository.repositoryRoot == key)
    #expect(repository.initialWorktreeRoot == key)
    #expect(repository.repositoryName == "app")
    #expect(repository.remoteHosting === hosting)
    #expect(!repository.supportsWorktrees)
    #expect(repository.activeWorkspace.projectRoot == key)
    #expect(repository.activeWorkspace.launchRoot == "/Users/me/work/app")
    // A device's policy runs tabs there whatever the local setting.
    #expect(repository.activeWorkspace.backendPolicy.prefersPersistentLocalSessions)
    #expect(repository.activeWorkspace.backendPolicy.persistentHostingForNewTab() === hosting)
}

// MARK: - Ends and keys while a device is offline (fake control)

@MainActor
private final class OfflineHarness {
    let fake = FakeControlHelper()
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let hosting: PersistentHostSessions
    let store: WorkspaceStateStore
    let directory: URL
    let host: HostedSessionHost
    static let offline = "ssh: connect to host studio port 22: Connection timed out"
    private let suite: String

    init(reconnectDelay: (initial: TimeInterval, maximum: TimeInterval) = (0.05, 0.2)) throws {
        directory = try temporaryDirectory("offline-ends")
        store = WorkspaceStateStore(directory: directory)
        host = try HostedSessionHost.ssh("studio")
        cli = try HostedSessionFakeCLI()
        let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
        self.suite = suite
        let executable = cli.executable
        control = HostControl(
            host: host,
            clientProvider: { HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: [:]) }) },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.terminationTimeout = .seconds(2)
        configuration.reconnectDelay = reconnectDelay
        configuration.endRetryDelay = (.milliseconds(50), .milliseconds(100))
        configuration.endRetryWindow = .milliseconds(600)
        configuration.keyInputTimeout = .milliseconds(500)
        configuration.forgottenTabsWindow = .seconds(10)
        let control = control
        hosting = PersistentHostSessions.remote(
            profile: .remote(host: host, displayName: "Studio"),
            installationID: UUID(),
            remoteShell: "/bin/zsh",
            control: { control },
            installationUnavailableReason: { nil },
            status: PersistentSessionsStatus(),
            instanceLock: nil,
            terminalColors: { nil },
            configuration: configuration
        )
        hosting.endedSessionsStore = store
        hosting.resumeRecordedEndsOnConnection()
    }

    var attachCalls: [String] { cli.calls.filter { $0.contains(" attach ") } }

    func statusFile(of call: String) throws -> URL {
        let parts = call.split(separator: " ").map(String.init)
        let index = try #require(parts.firstIndex(of: "--status-file"))
        return URL(fileURLWithPath: parts[index + 1])
    }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func endingADeviceSessionWhileItIsOfflineIsRecordedAndFinishedOnTheNextConnection() async throws {
    let harness = try OfflineHarness()
    defer { harness.cleanUp() }
    let owner = harness.hosting.owner
    harness.fake.sessions = [HostedSessionInfo(id: "s1", name: "Shell", cwd: "/Users/me", pid: 9, owner: owner)]
    let list = try await harness.control.list()
    let attachment = HostedSessionAttachment(
        host: harness.host, hostID: list.hostID, sessionID: "s1", name: "Shell",
        remoteWorkingDirectory: "/Users/me", executablePath: "/fake/bin/cherry"
    )
    // The Mac goes offline.
    harness.fake.launchFailure = OfflineHarness.offline
    harness.control.disconnect()

    let ending = harness.hosting.end(attachment)
    // Recorded at once, keyed by the host and its identity.
    harness.store.flush()
    let recorded = harness.store.loadSessionsToEnd()
    #expect(recorded.count == 1)
    #expect(recorded.first?.hosted?.host == harness.host.id)
    #expect(recorded.first?.hosted?.hostID == list.hostID)
    #expect(recorded.first?.id == PersistentHostSessions.endRecordID(hostID: list.hostID, sessionID: "s1"))
    // A quit does not wait for an offline Mac's ends.
    #expect(!harness.hosting.hasPendingEnds)
    #expect(await harness.hosting.waitForPendingEnds(timeout: .milliseconds(50)))
    await ending.value
    harness.store.flush()
    #expect(harness.store.loadSessionsToEnd().count == 1)
    #expect(harness.fake.requests("kill").isEmpty)

    // Back online: the next connection finishes the end.
    harness.fake.launchFailure = nil
    _ = try await harness.control.list()
    #expect(await harness.fake.wait(timeout: 10) { !harness.fake.requests("kill").isEmpty })
    #expect(await harness.fake.wait(timeout: 10) {
        harness.store.flush()
        return harness.store.loadSessionsToEnd().isEmpty
    })
    #expect(harness.fake.sessions.first { $0.id == "s1" }?.isRunning != true)
}

private func keyDown(_ characters: String, keyCode: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
    ))
}

@Test @MainActor func aDeviceTabWaitsForItsMacBeforeItsAdapterRunsAgainAndKeysTypedMeanwhileFailVisibly() async throws {
    let harness = try OfflineHarness()
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: harness.hosting)
    )
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.fake.wait {
        tab.persistentSession != nil && tab.usesNativePTYBackend && tab.state == .live
    })
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(tab.remoteMachineName == "Studio")
    #expect(!tab.isRemoteHostUnreachable)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)
    // Saved while it runs, the record names its session on Studio.
    let record = WorkspaceSessionRecord(session: tab, restoredRecord: nil)
    #expect(record.hosted?.host == harness.host.id)
    #expect(record.hostKey == nil)

    // Studio goes offline, and the adapter loses it.
    harness.fake.launchFailure = OfflineHarness.offline
    harness.fake.dropAll(stderr: OfflineHarness.offline)
    #expect(await harness.fake.wait { harness.control.state != .connected })
    try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
        .write(to: try harness.statusFile(of: call))
    tab.ingestNativeChildExit(exitCode: 1)
    #expect(tab.isRunning)
    #expect(tab.isRemoteHostUnreachable)
    #expect(tab.keyboardInputGoesThroughHost)
    // No adapter is launched while Studio cannot be reached (its ssh
    // would only fail), however long that lasts.
    try await Task.sleep(for: .milliseconds(600))
    #expect(harness.attachCalls.count == 1)
    #expect(tab.state == .disconnected)
    // Keys typed meanwhile are taken, not sent, and the tab says so.
    #expect(tab.offlineInputRejectedAt == nil)
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("l", keyCode: 37)))
    #expect(tab.offlineInputRejectedAt != nil)
    #expect(harness.fake.requests("send_input").isEmpty)
    // Never a local shell.
    #expect(tab.isPersistentLocalSession && tab.persistentFallbackReason == nil)

    // Studio answers again: the adapter runs again.
    harness.fake.launchFailure = nil
    harness.control.reconnectNow()
    #expect(await harness.fake.wait(timeout: 10) { harness.control.state == .connected })
    #expect(await harness.fake.wait(timeout: 10) { harness.attachCalls.count == 2 })
}

// MARK: - The Omni bar's Mac rows

@Test @MainActor func RemoteDeviceOmniBarMacRowsOfferThePickerMenusActionsAsTheDeviceAnswers() throws {
    let studioID = UUID()
    let studio = RemoteDevice(id: studioID, name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me")
    func sources(
        _ state: RemoteDeviceConnectionState,
        sessions: [HostedSessionInfo] = [],
        canModify: Bool = true,
        background: [OmniBackgroundSession] = []
    ) -> OmniSources {
        let entry = TitlebarProjectMenuModel.Device(device: studio, state: state, sessions: sessions)
        var sources = OmniSources()
        sources.devices = [entry]
        sources.canModifyDevices = canModify
        sources.backgroundSessions = background
        sources.projects = ProjectSwitcherModel.make(
            localProjects: [],
            devices: [entry],
            openWindows: [:],
            recency: [:],
            currentProjectKey: nil,
            thisMac: ProjectSwitcherModel.thisMacInfo(computerName: nil, sessionCount: 3, projectCount: 0, symbol: "laptopcomputer"),
            localHome: "/Users/me"
        )
        return sources
    }

    // Not answering: Offline, grey, with Reconnect.
    let offline = OmniProviders.macs(sources(.offline(reason: "timed out")))
    #expect(offline.map(\.title) == ["This Mac", "Studio"])
    #expect(offline[0].detail == "3 sessions" && offline[0].status == .idle)
    #expect(offline[1].detail == "Offline" && offline[1].status == .offline)
    #expect(offline[1].actions.contains { $0.title == "Reconnect" && $0.command == .switcher(.reconnectDevice(studioID)) })

    // It answers: its sessions, a green dot, and no Reconnect.
    let connected = OmniProviders.macs(sources(
        .connected(sessionCount: 1),
        sessions: [session("a", owner: "Cherry", project: "/Users/me/app")],
        background: [OmniBackgroundSession(id: "s1", title: "npm", machine: .device(studioID), isWorking: false)]
    ))[1]
    #expect(connected.detail == "1 session" && connected.status == .idle)
    #expect(connected.primary == .drill(.mac(.device(studioID), name: "Studio")))
    #expect(connected.actions.map(\.title) == [
        "Open Home Folder", "Add Project on Studio…", "New Terminal on Studio",
        "Persistent Sessions on Studio…", "Set Up Cherry MCP on Studio…",
        "End Background Sessions…", "Rename…", "Remove…",
    ])
    #expect(connected.actions[2].command == .newTerminal(on: .device(studioID)))
    #expect(connected.actions.last?.command == .switcher(.removeDevice(studioID)))
    #expect(connected.actions.last?.isDestructive == true)

    // The copy of the app that does not keep the devices changes none.
    let readOnly = OmniProviders.macs(sources(.connected(sessionCount: 0), canModify: false))[1].actions.map(\.title)
    #expect(!readOnly.contains("Rename…") && !readOnly.contains("Remove…"))
    #expect(!readOnly.contains { $0.hasPrefix("Add Project") })

    // Another identity answers: Trust New Identity…, nothing to open.
    let changed = OmniProviders.macs(sources(.identityChanged(reason: "Expected a, received b.")))[1]
    #expect(changed.actions.contains { $0.title == "Trust New Identity…" })
    #expect(!changed.actions.contains { $0.title == "Open Home Folder" })
}

// MARK: - Close, detach, undo and quit of a device's tab (fake control)

@Test @MainActor func aDeviceTabDetachesComesBackWithUndoAndCountsInTheQuitQuestion() async throws {
    let harness = try OfflineHarness()
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .defaults }, localSessions: harness.hosting)
    )
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let first = workspace.addSession(title: "One")
    let second = workspace.addSession(title: "Two")
    #expect(await harness.fake.wait { first.persistentSession != nil && second.persistentSession != nil })
    // The quit question counts them (they run on Studio).
    let summary = workspace.teardownSummary(.quit, pathDisplayMode: .fullPath)
    #expect(summary.persistentTabCount == 2)
    #expect(summary.runningSessions.count == 2)

    // Detach: the session keeps running there; ⌘Z brings the tab back as
    // its own.
    let binding = try #require(second.persistentSession)
    let closed = try #require(workspace.closedTab(for: second, name: "Two"))
    #expect(closed.ownsSession)
    workspace.close(second, intent: .userDetachedTab)
    #expect(workspace.session(withID: second.id) == nil)
    #expect(harness.fake.requests("kill").isEmpty)
    let back = try #require(workspace.reopenClosedTab(closed))
    #expect(back.id == second.id)
    #expect(back.isPersistentLocalSession)
    #expect(back.persistentSession?.sessionID == binding.sessionID)
    #expect(back.remoteMachineName == "Studio")

    // Closing it (a user's close, not in a window: at once) ends its session there.
    workspace.close(back, intent: .userClosedTab)
    #expect(await harness.fake.wait { harness.fake.requests("kill").contains { $0.string("id") == binding.sessionID } })
}

@Test @MainActor func aDeviceTabSavedWhileItsCreateRunsRecordsItsHostAndIsLookedForThere() async throws {
    let harness = try OfflineHarness()
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let held = FakeHeldRequest()
    harness.fake.respond = { request, connection in
        request.op == "create" ? held.hold(request, on: connection) : nil
    }
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: harness.hosting)
    )
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.fake.wait { held.isHeld })
    let record = WorkspaceSessionRecord(session: tab, restoredRecord: nil)
    #expect(record.hosted == nil)
    #expect(record.launchRequestID != nil)
    #expect(record.hostKey == harness.host.id)
    #expect(record.mayOwnSession(on: harness.host))
    #expect(!record.mayOwnLocalSession)
    // A quit that ends sessions ends it on its device, not This Mac.
    #expect(record.identifyingSession.creationHostKey == harness.host.id)
}


// MARK: - Review fixes

@Test @MainActor func removingAMacKeepsTheUsersOwnSavedHostAndAReadOnlyCopyChangesNothing() throws {
    let directory = try temporaryDirectory("devices-own-host")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    // The user saved `studio` (and trusts its identity) before adding it as a Mac.
    let own = try hostStore.add("studio")
    hostStore.trust("h-studio", for: own)
    var writable = true
    let store = makeStore(directory: directory, hostStore: hostStore, canWrite: { writable })
    let studio = try store.add(name: "Studio", sshDestination: "studio")
    #expect(!studio.createdHostEntry)
    let mini = try store.add(name: "Mini", sshDestination: "mini")
    #expect(mini.createdHostEntry)
    store.remove(studio.id)
    #expect(hostStore.hosts.contains(own))
    #expect(hostStore.trustedHostID(for: own) == "h-studio")
    // One Add Mac… saved goes with it.
    writable = false
    store.rename(mini.id, to: "Renamed")
    store.hideProject(path: "/x", on: mini.id)
    store.remove(mini.id)
    #expect(store.device(id: mini.id)?.name == "Mini")
    #expect(store.device(id: mini.id)?.hiddenProjects.isEmpty == true)
    writable = true
    store.remove(mini.id)
    #expect(!hostStore.hosts.contains(try HostedSessionHost.ssh("mini")))
    // The picker offers no change to a copy that cannot make it.
    let device = RemoteDevice(id: UUID(), name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me")
    let menu = TitlebarProjectMenuModel(
        worktrees: nil, projects: [],
        devices: [.init(device: device, state: .identityChanged(reason: "x"), sessions: [session("a", owner: "Cherry", project: "/Users/me/app")])],
        currentProjectKey: nil, canModifyDevices: false
    )
    for line in ["⌥ Hide app — /Users/me/app (off)", "Trust New Identity… (off)", "Rename… (off)", "Remove… (off)", "Add Mac… (off)"] {
        #expect(menu.snapshot.contains(line), "\(line)")
    }
}

@Test @MainActor func aMacsHostingStaysTheSameAcrossRenamesRemovalsInUseAndAddingItAgain() throws {
    let directory = try temporaryDirectory("devices-hostings")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let registry = PersistentHostingRegistry(local: PersistentHostSessions(
        installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
    ))
    let store = makeStore(directory: directory, hostStore: hostStore, registry: registry)
    let studio = try store.add(name: "Studio", sshDestination: "studio")
    let hosting = try #require(store.hosting(for: studio.id))
    // Renamed: the same hosting, with the new name.
    store.rename(studio.id, to: "Mac Studio")
    #expect(store.hosting(for: studio.id) === hosting)
    #expect(hosting.profile.displayName == "Mac Studio")
    // A window uses it (its tabs still wait for a restore): removing the
    // Mac leaves the hosting registered, and adding it again takes it back.
    hosting.beginUse()
    #expect(hosting.isInUse)
    store.remove(studio.id)
    #expect(registry.hosting(for: try HostedSessionHost.ssh("studio")) === hosting)
    let again = try store.add(name: "Studio 2", sshDestination: "studio")
    #expect(store.hosting(for: again.id) === hosting)
    #expect(hosting.profile.displayName == "Studio 2")
    hosting.endUse()
    #expect(!hosting.isInUse)
    store.remove(again.id)
    #expect(registry.hosting(for: try HostedSessionHost.ssh("studio")) == nil)
}

@Test @MainActor func anAliasOfAMacAlreadyAddedIsRefusedByItsHostIdentity() throws {
    let directory = try temporaryDirectory("devices-alias")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = makeStore(directory: directory, hostStore: hostStore)
    _ = try store.add(name: "Studio", sshDestination: "studio", hostID: "h-1")
    #expect(throws: (any Error).self) { try store.add(name: "Studio LAN", sshDestination: "studio.lan", hostID: "h-1") }
    // Or by the identity a connection already pinned.
    let mini = try store.add(name: "Mini", sshDestination: "mini")
    hostStore.trust("h-2", for: try #require(mini.host))
    #expect(store.device(withHostID: "h-2")?.id == mini.id)
    #expect(throws: (any Error).self) { try store.add(name: "Mini again", sshDestination: "me@mini.local", hostID: "h-2") }
    #expect(store.devices.count == 2)
}

@Test func destinationsThatSSHWouldReadAsAnOptionAreRefusedAndTheCheckNeverForwards() throws {
    #expect(throws: (any Error).self) { try HostedSessionHost.ssh("me@-oProxyCommand=x") }
    #expect(throws: (any Error).self) { try HostedSessionHost.ssh("-studio") }
    #expect((try? HostedSessionHost.ssh("me@studio-2")) != nil)
    let arguments = RemoteDeviceShell(sshExecutable: "/usr/bin/ssh", environment: [:]).arguments(destination: "studio")
    #expect(arguments.contains("-x") && arguments.contains("-a") && arguments.contains("BatchMode=yes"))
    #expect(arguments.suffix(3) == ["--", "studio", "sh -s"])
    // Open in Terminal quotes the destination for the shell.
    #expect(AddDeviceModel.terminalCommand(for: "me@studio[1]") == "ssh -- 'me@studio[1]'")
}

@Test func devicesBarsSayWhatStandsInTheWayAndWhatToDo() {
    typealias A = RemoteDeviceAvailability
    #expect(A.of(.connected, installationProblem: nil) == .online)
    #expect(A.of(.waitingToReconnect(.unavailable("ssh: connect to host s port 22: Connection timed out")), installationProblem: nil) == .reconnecting)
    #expect(A.of(.waitingToReconnect(.unavailable("s: Permission denied (publickey).")), installationProblem: nil).action == .retryLogin)
    #expect(A.of(.failed(.identityMismatch("x")), installationProblem: nil).action == .trustNewIdentity)
    #expect(A.of(.failed(.unavailable("The session host speaks protocol 6, but this Cherry speaks 7.")), installationProblem: nil).action == .update)
    #expect(A.of(.failed(.unavailable("boom")), installationProblem: nil).action == .checkAgain)
    let unknown = A.of(.idle, installationProblem: "This Mac is not among your devices.")
    #expect(unknown.action == .checkAgain)
    #expect(unknown.text(machine: "Studio") == "This Mac is not among your devices.")
    #expect(A.reconnecting.text(machine: "Studio") == "Studio is offline, reconnecting…")
    #expect(A.identityChanged("x").text(machine: "Studio") == "Another identity answers for Studio")
    // Opening the Omni bar never logs in again after a refusal (nor asks a
    // host of another identity or protocol).
    #expect(RemoteDevicePeeks.refreshesOnOpen(.idle))
    #expect(RemoteDevicePeeks.refreshesOnOpen(.waitingToReconnect(.unavailable("Connection timed out"))))
    #expect(!RemoteDevicePeeks.refreshesOnOpen(.waitingToReconnect(.unavailable("Permission denied (publickey)."))))
    #expect(!RemoteDevicePeeks.refreshesOnOpen(.failed(.identityMismatch("x"))))
    #expect(!RemoteDevicePeeks.refreshesOnOpen(.failed(.unavailable("(version_mismatch)"))))
}

@Test @MainActor func aChangedHostPathNeedsANewCheckBeforeAdd() async throws {
    let directory = try temporaryDirectory("devices-path")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    // A stand-in ssh that prints a check's answer.
    let ssh = directory.appendingPathComponent("ssh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\n' 'CHERRY-PROBE 1' 'uname=Darwin arm64' 'macos=26.0' 'computer=Studio' 'home=/Users/me' 'CHERRY-PROBE-END'
    """.write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    let store = makeStore(directory: directory, hostStore: hostStore)
    let model = AddDeviceModel(store: store, aliases: [], shell: {
        RemoteDeviceShell(sshExecutable: ssh.path, environment: ["PATH": "/usr/bin:/bin"])
    })
    model.destination = "studio"
    model.remoteHostPath = "~/bin/cherry-host"
    await model.check()
    #expect(model.canAdd)
    model.remoteHostPath = "~/other/cherry-host"
    #expect(!model.canAdd)
    #expect(model.add() == nil)
    await model.check()
    #expect(model.canAdd)
    #expect(model.add()?.remoteHostPath == "~/other/cherry-host")
}

@Test @MainActor func adapterRelaunchesAfterAReconnectGoAFewAtATime() async throws {
    var configuration = PersistentHostSessions.Configuration.remote
    configuration.relaunchBatchSize = 3
    configuration.relaunchBatchInterval = 0.2
    let hosting = PersistentHostSessions.remote(
        profile: .remote(host: try HostedSessionHost.ssh("studio"), displayName: "Studio"),
        installationID: UUID(), installationUnavailableReason: { nil }, status: PersistentSessionsStatus(),
        instanceLock: nil, terminalColors: { nil }, configuration: configuration
    )
    #expect(PersistentHostSessions.Configuration.remote.relaunchBatchSize == HostSSHMasterManager.Configuration().maxChannelsPerMaster)
    var ran = 0
    for _ in 0..<8 { hosting.enqueueAdapterRelaunch { ran += 1 } }
    #expect(ran == 0)
    try await Task.sleep(for: .milliseconds(60))
    #expect(ran == 3)
    #expect(hosting.pendingAdapterRelaunches == 5)
    let deadline = Date().addingTimeInterval(5)
    while ran < 8, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(ran == 8)
}

@Test @MainActor func aWindowOfAnUnknownMacNeitherConnectsNorRewritesItsSavedTabs() async throws {
    let directory = try temporaryDirectory("unknown-device")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStateStore(directory: directory)
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let saved = WorkspaceSessionRecord(
        id: UUID(), kind: .terminal, title: "Shell", workingDirectory: "/Users/me/app", projectRoot: key,
        hosted: HostedSessionBindingRecord(host: "ssh:studio", hostID: "h", sessionID: "s1", owned: true),
        savedAt: Date(timeIntervalSince1970: 1_000)
    )
    store.saveSynchronously(RepositoryStateRecord(
        repositoryRoot: key, activeWorktreeRoot: key, worktrees: [WorktreeStateRecord(root: key, sessions: [saved])],
        savedAt: Date(timeIntervalSince1970: 1_000)
    ))
    let hosting = RemoteDeviceStore.unavailableHosting(for: key, reason: "Not among your devices.", instanceLock: nil)
    #expect(!hosting.profile.isKnownDevice)
    // Its control never runs a helper (so never ssh).
    await #expect(throws: HostedSessionError.unavailable("Not among your devices.")) { try await hosting.control.list() }
    let repository = RepositoryWorkspace(
        projectRoot: key,
        backendPolicy: .remote(hosting, settings: { .defaults }, hostReconnects: nil),
        stateStore: store,
        sessionRestorer: RemoteDeviceStore.keepingRestorer,
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    #expect(repository.remoteHosting == nil)
    #expect(repository.deviceHosting === hosting)
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    #expect(repository.activeWorkspace.sessions.isEmpty)
    #expect(repository.remoteTabsWaitingCount == 1)
    repository.flushPersistentState()
    let after = try #require(store.load(repositoryRoot: key)?.worktrees.first?.sessions.first)
    #expect(after.hosted == saved.hosted)
    #expect(after.hosted?.owned == true)
    #expect(hosting.control.state != .connected)
}

@Test @MainActor func aDeviceWindowNeverAdoptsSessionsByThisMacsClock() async throws {
    let harness = try OfflineHarness()
    defer { harness.cleanUp() }
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    // A session of this installation's on the device that no saved tab names,
    // created (by the device's clock) long ago.
    let orphanTab = UUID()
    harness.fake.sessions = [HostedSessionInfo(
        id: "orphan", name: "Shell", cwd: "/Users/me/app", pid: 9, owner: harness.hosting.owner,
        tags: [PersistentSessionTag.tab: orphanTab.uuidString, PersistentSessionTag.kind: "terminal",
               PersistentSessionTag.project: key],
        createdAt: 1_000
    )]
    let repository = RepositoryWorkspace(
        projectRoot: key,
        backendPolicy: .remote(harness.hosting, settings: { .defaults }, hostReconnects: nil),
        stateStore: harness.store,
        sessionRestorer: WorkspaceSessionRestorers.hostedByDefault(localSessions: harness.hosting, control: { _ in harness.control }),
        autoStartCommands: { _ in [] },
        restoredTabLaunchQueue: RestoredTabLaunchQueue()
    )
    defer { repository.closeAllSessions(intent: .windowClosed) }
    repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
    await repository.waitForPendingRestores()
    try await Task.sleep(for: .milliseconds(500))
    #expect(repository.activeWorkspace.session(withID: orphanTab) == nil)
    #expect(!repository.isRestoringSessions)
}

@Test @MainActor func aReconnectWhileAClosedDeviceTabCanBeUndoneLeavesItsSessionForUndo() async throws {
    let harness = try OfflineHarness()
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .defaults }, localSessions: harness.hosting)
    )
    defer {
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let keep = workspace.addSession(title: "Keep")
    let tab = workspace.addSession(title: "Closed")
    #expect(await harness.fake.wait { tab.persistentSession != nil && keep.persistentSession != nil })
    let binding = try #require(tab.persistentSession)
    // Studio is offline when the tab is closed (⌘W): its end waits for the
    // undo window, recorded as a session to end.
    harness.fake.launchFailure = OfflineHarness.offline
    harness.fake.dropAll(stderr: OfflineHarness.offline)
    #expect(await harness.fake.wait { harness.control.state != .connected })
    let closed = try #require(workspace.closedTab(for: tab, name: "Closed"))
    let left = workspace.deferringSessionEnds { workspace.close(tab, intent: .userClosedTab) }
    #expect(left.map(\.id) == [tab.id])
    harness.hosting.deferEnd(ofSession: binding.sessionID, record: closed.record, recordedIn: harness.store) {
        tab.endPersistentSession()
    }
    harness.store.flush()
    #expect(harness.store.loadSessionsToEnd().map(\.id).contains(tab.id))
    // Studio answers again inside the undo window.
    harness.fake.launchFailure = nil
    harness.control.reconnectNow()
    #expect(await harness.fake.wait(timeout: 10) { harness.control.state == .connected })
    try await Task.sleep(for: .milliseconds(800))
    #expect(!harness.fake.requests("kill").contains { $0.string("id") == binding.sessionID })
    // ⌘Z: the live session comes back as the tab's own.
    #expect(harness.hosting.resumeDeferred(binding.sessionID))
    let back = try #require(workspace.reopenClosedTab(closed))
    #expect(back.persistentSession?.sessionID == binding.sessionID)
    #expect(harness.fake.sessions.first { $0.id == binding.sessionID }?.isRunning == true)
}

@Test @MainActor func keysForADeviceGoOnlyOverTheLiveConnectionAndAFailureDropsTheKeysBehindIt() async throws {
    // The adapter is launched again only after the test.
    let harness = try OfflineHarness(reconnectDelay: (30, 30))
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let workspace = TerminalWorkspace(
        projectRoot: key, createInitialSession: false,
        backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: harness.hosting)
    )
    let container = GhosttyTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    defer {
        container.detachActiveSession()
        workspace.closeAllSessions(intent: .windowClosed)
        harness.cleanUp()
    }
    let tab = workspace.addSession()
    #expect(await harness.fake.wait { tab.persistentSession != nil && tab.usesNativePTYBackend && tab.state == .live })
    container.configure(with: tab, colorScheme: .dark, allowsAutoFocus: false)
    #expect(await harness.fake.wait { harness.attachCalls.count == 1 })
    let call = try #require(harness.attachCalls.first)
    // The adapter ended; Studio still answers, so keys go through its host.
    try Data(#"{"outcome":"disconnected","exit_code":null,"signal":null,"message":"connection lost"}"#.utf8)
        .write(to: try harness.statusFile(of: call))
    tab.ingestNativeChildExit(exitCode: 1)
    #expect(tab.keyboardInputGoesThroughHost)
    // The host takes the first key but never answers.
    harness.fake.respond = { request, _ in request.op == "send_input" ? .silence : nil }
    let connections = harness.fake.connections.count
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("a", keyCode: 0)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("b", keyCode: 11)))
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("c", keyCode: 8)))
    // Within its short timeout it fails, saying so; the keys behind it are
    // dropped, not sent late.
    #expect(await harness.fake.wait(timeout: 10) { tab.offlineInputRejectedAt != nil })
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.fake.requests("send_input").count == 1)
    // Keys typed afterwards are sent again, over the same connection.
    harness.fake.respond = nil
    #expect(container.sendKeyThroughHostWhileAdapterIsAway(try keyDown("d", keyCode: 2)))
    #expect(await harness.fake.wait { harness.fake.requests("send_input").count == 2 })
    // Never through a new connection.
    #expect(harness.fake.connections.count == connections)
}
