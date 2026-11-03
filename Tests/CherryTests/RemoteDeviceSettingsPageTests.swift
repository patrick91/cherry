import AppKit
import CherryControl
import Foundation
import SwiftUI
import Testing
@testable import Cherry

// Settings › Macs (docs/specs/remote-devices.md) without a real SSH host:
// each Mac's row (its projects, home, sessions and status), the model's
// changes (rename, hide and show a project again, color, Forget… of a
// saved SSH host) through its own stores, the questions it asks, the Color
// row's badge, and the page's search rows. A device's control is inert,
// or the in-process fake `cherry control` (FakeControlHelper) for its
// session count. Nothing here runs ssh or touches the app's stores.

// MARK: - Helpers

/// Whether a test's device store may write (another copy of Cherry holds
/// the instance lock when not).
@MainActor
private final class Writable {
    var value = true
}

/// A device store and a saved-host store of the test's own, and a model
/// over them whose controls never connect and whose alerts show nothing.
@MainActor
private final class MacsFixture {
    let directory: URL
    let suite: String
    let hostStore: HostedSessionHostStore
    let store: RemoteDeviceStore
    let writable = Writable()
    private var controls: [HostedSessionHost: HostControl] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-macs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (hostStore, _, suite) = try makeIsolatedHostedSessionHostStore()
        self.hostStore = hostStore
        self.suite = suite
        let writable = writable
        store = RemoteDeviceStore(
            fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
            canWrite: { writable.value },
            hostStore: hostStore,
            installationID: { UUID() },
            registry: PersistentHostingRegistry(local: PersistentHostSessions(
                installationUnavailableReason: { nil }, status: PersistentSessionsStatus()
            )),
            remoteHostPaths: HostedRemoteHostPaths()
        )
    }

    func model(
        presenters: RemoteDeviceSettingsModel.Presenters = MacsFixture.silentPresenters,
        control: (@MainActor (HostedSessionHost) -> HostControl)? = nil
    ) -> RemoteDeviceSettingsModel {
        RemoteDeviceSettingsModel(
            store: store,
            hostStore: hostStore,
            control: control ?? { [unowned self] host in inertControl(for: host) },
            bundledBuild: { nil },
            presenters: presenters
        )
    }

    private func inertControl(for host: HostedSessionHost) -> HostControl {
        if let control = controls[host] { return control }
        let control = RemoteDeviceStore.inertControl(host: host, reason: "test")
        controls[host] = control
        return control
    }

    static var silentPresenters: RemoteDeviceSettingsModel.Presenters {
        RemoteDeviceSettingsModel.Presenters(
            confirmRemove: { _, _ in },
            confirmTrustNewIdentity: { _, _ in },
            updateSessionHost: { _, _ in }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

// MARK: - Rows

@Test @MainActor func RemoteDeviceSettingsRowsCarryEachMacsProjectsHomeAndSessions() throws {
    let device = RemoteDevice(
        name: "Mac mini",
        sshDestination: "mini.local",
        homeDirectory: "/Users/me",
        addedProjects: ["/Users/me/code/api-server", "/opt/tools"],
        hiddenProjects: ["/Users/me/code/old-site"],
        installedBuild: "20260101000000.old",
        installedResources: true
    )
    let row = RemoteDeviceSettingsRow(device: device, state: .connected(sessionCount: 3), bundledBuild: "20260301000000.new")
    #expect(row.projects.map(\.displayPath) == ["~/code/api-server", "/opt/tools", "~/code/old-site"])
    #expect(row.projects.map(\.path) == device.addedProjects + device.hiddenProjects)
    #expect(row.projects.map(\.isHidden) == [false, false, true])
    #expect(Set(row.projects.map(\.id)).count == 3)
    #expect(row.homeDirectory == "/Users/me")
    #expect(row.homeProjectKey == device.projectKey(path: "/Users/me"))
    #expect(row.host == (try HostedSessionHost.ssh("mini.local")))
    #expect(row.status == .connected(sessionCount: 3))
    #expect(row.allowsOpening)
    #expect(row.color == nil && row.effectiveColor == RemoteDeviceColor.automatic(for: device.id))

    // The update is a tag on Macs; the old status line keeps its suffix.
    #expect(row.updateAvailable)
    #expect(row.statusText(includingUpdate: false) == "Connected · 3 sessions")
    #expect(row.statusText() == "Connected · 3 sessions · Update available")
    #expect(row.statusText(includingUpdate: true) == row.statusText())
    let lastSeen = Date(timeIntervalSince1970: 1_000_000)
    let away = RemoteDeviceSettingsRow(device: device, state: .unknown(lastSeen: lastSeen), bundledBuild: nil)
    #expect(away.statusText(now: lastSeen.addingTimeInterval(7_200), includingUpdate: false) == "Not connected · last seen 2 h ago")
    #expect(away.status == .notConnected(lastSeen: lastSeen))

    // Another identity answered: nothing of it opens until it is trusted.
    let changed = RemoteDeviceSettingsRow(device: device, state: .identityChanged(reason: "x"), bundledBuild: nil)
    #expect(!changed.allowsOpening && changed.offersTrustNewIdentity)

    // A home not found yet: paths as they are, and no home folder to open.
    var homeless = device
    homeless.homeDirectory = nil
    homeless.color = .teal
    let unknownHome = RemoteDeviceSettingsRow(device: homeless, state: .connected(sessionCount: 1), bundledBuild: nil)
    #expect(unknownHome.projects.first?.displayPath == "/Users/me/code/api-server")
    #expect(unknownHome.homeProjectKey == nil)
    #expect(unknownHome.color == .teal && unknownHome.effectiveColor == .teal)
    #expect(unknownHome.statusText() == "Connected · 1 session")
}

// MARK: - Changes

@Test @MainActor func RemoteDeviceSettingsModelRenamesTrimmedAndRefusesEmptyOrReadOnly() throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    let studio = try fixture.store.add(name: "Studio", sshDestination: "studio")
    let model = fixture.model()
    #expect(model.rows.map(\.name) == ["Studio"])

    #expect(model.rename(studio.id, to: "  Studio Display  "))
    #expect(fixture.store.device(id: studio.id)?.name == "Studio Display")
    #expect(model.rows.first?.name == "Studio Display")
    // An empty name, or a Mac that is gone, changes nothing.
    #expect(!model.rename(studio.id, to: "   "))
    #expect(!model.rename(UUID(), to: "Other"))
    #expect(fixture.store.device(id: studio.id)?.name == "Studio Display")

    // Another copy of Cherry keeps the Macs: refused.
    fixture.writable.value = false
    #expect(!model.canModify)
    #expect(!model.rename(studio.id, to: "Other"))
    #expect(fixture.store.device(id: studio.id)?.name == "Studio Display")
}

@Test @MainActor func RemoteDeviceSettingsModelHidesAProjectAndShowsItAgain() throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    let mini = try fixture.store.add(name: "Mini", sshDestination: "mini", homeDirectory: "/Users/me")
    fixture.store.addProject(path: "/Users/me/code/api-server", to: mini.id)
    let model = fixture.model()
    #expect(model.rows.first?.projects.map(\.displayPath) == ["~/code/api-server"])

    // Remove… hides it from the project picker: its row says Hidden.
    model.hideProject(path: "/Users/me/code/api-server", on: mini.id)
    #expect(fixture.store.device(id: mini.id)?.addedProjects == [])
    #expect(fixture.store.device(id: mini.id)?.hiddenProjects == ["/Users/me/code/api-server"])
    #expect(model.rows.first?.projects.map(\.isHidden) == [true])

    // Show Again adds it back.
    model.showProjectAgain(path: "/Users/me/code/api-server", on: mini.id)
    #expect(fixture.store.device(id: mini.id)?.addedProjects == ["/Users/me/code/api-server"])
    #expect(fixture.store.device(id: mini.id)?.hiddenProjects == [])
    #expect(model.rows.first?.projects.map(\.isHidden) == [false])

    // Read-only: nothing changes, either way.
    fixture.writable.value = false
    model.hideProject(path: "/Users/me/code/api-server", on: mini.id)
    #expect(fixture.store.device(id: mini.id)?.hiddenProjects == [])
    fixture.writable.value = true
    model.hideProject(path: "/Users/me/code/api-server", on: mini.id)
    fixture.writable.value = false
    model.showProjectAgain(path: "/Users/me/code/api-server", on: mini.id)
    #expect(fixture.store.device(id: mini.id)?.addedProjects == [])
    #expect(model.rows.first?.projects.map(\.isHidden) == [true])
}

@Test @MainActor func RemoteDeviceSettingsColorIsSetHereUntilItIsAutomaticAgain() throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    let mini = try fixture.store.add(name: "Mini", sshDestination: "mini")
    let model = fixture.model()
    var resets = 0
    func source(_ canModify: Bool = true) throws -> SettingsSourceState {
        MacsSettingsPage.colorSource(of: try #require(model.rows.first), canModify: canModify) { resets += 1 }
    }

    // Automatic: no badge, no ↺.
    #expect(try source().source == .cherryDefault)
    #expect(try source().rowReset == nil)
    #expect(try source().defaultText == "Automatic")

    model.setColor(.teal, for: mini.id)
    #expect(fixture.store.device(id: mini.id)?.color == .teal)
    let chosen = try source()
    #expect(chosen.source == .setHere && chosen.badgeText == "Set here")
    #expect(chosen.lines == [
        SettingsSourceState.Line("Set here", value: "Teal", isInUse: true),
        SettingsSourceState.Line("Cherry default", value: "Automatic"),
    ])
    let reset = try #require(chosen.rowReset)
    #expect(reset.title == "Reset to default (Automatic)")
    reset.perform()
    #expect(resets == 1)
    #expect(chosen.accessibilityLabel == "Source: Set here. Default: Automatic.")
    // A copy that cannot change the Macs offers no reset.
    #expect(try source(false).rowReset == nil)
    #expect(try source(false).buttons.isEmpty)

    model.setColor(nil, for: mini.id)
    #expect(fixture.store.device(id: mini.id)?.color == nil)
    #expect(try source().source == .cherryDefault)

    // The swatches are the Macs' colors, by name.
    #expect(MacsSettingsPage.colorSwatches(for: .dark).map(\.name) == RemoteDeviceColor.allCases.map(\.title))
    #expect(MacsSettingsPage.colorSwatches(for: .light).map(\.value) == RemoteDeviceColor.allCases.map { $0 })
}

@Test @MainActor func RemoteDeviceSettingsHeroShowsTheDotAndAColoredTileOnlyWhileConnected() {
    #expect(MacsSettingsPage.tone(.green) == .green)
    #expect(MacsSettingsPage.tone(.yellow) == .yellow)
    #expect(MacsSettingsPage.tone(.red) == .red)
    #expect(MacsSettingsPage.tone(.gray) == .gray)
    #expect(MacsSettingsPage.tileShowsColor(.connected(sessionCount: 0)))
    #expect(MacsSettingsPage.tileShowsColor(.connecting))
    #expect(!MacsSettingsPage.tileShowsColor(.notConnected(lastSeen: nil)))
    #expect(!MacsSettingsPage.tileShowsColor(.offline("timed out")))
    #expect(!MacsSettingsPage.tileShowsColor(.needsAttention("refused")))
}

// MARK: - SSH hosts

@Test @MainActor func RemoteDeviceSettingsSSHHostsAreTheSavedHostsNoMacUsesAndForgetDropsTheirIdentity() async throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    let deploy = try fixture.hostStore.add("deploy@build.example.com")
    fixture.hostStore.trust("h-deploy", for: deploy)
    let other = try fixture.hostStore.add("other")
    // Add Mac… saves its destination as a host too; it is listed as a Mac.
    let studio = try fixture.store.add(name: "Studio", sshDestination: "studio")
    #expect(studio.createdHostEntry)
    #expect(fixture.hostStore.hosts.contains(try HostedSessionHost.ssh("studio")))
    let model = fixture.model()
    #expect(model.sshHostsNotAdded.map(\.destination) == ["deploy@build.example.com", "other"])
    #expect(model.sshHostsNotAdded.map(\.isTrusted) == [true, false])
    #expect(model.sshHostsNotAdded.map(\.host) == [deploy, other])

    // Forget… drops the host and its trusted identity.
    model.forget(deploy)
    #expect(!fixture.hostStore.hosts.contains(deploy))
    #expect(fixture.hostStore.trustedHostIDs[deploy.id] == nil)
    #expect(model.sshHostsNotAdded.map(\.destination) == ["other"])

    // Hosts saved elsewhere (File › Persistent Sessions) show up.
    _ = try fixture.hostStore.add("late")
    #expect(await eventually { model.sshHostsNotAdded.map(\.destination) == ["other", "late"] })
    // And forgetting one there too.
    fixture.hostStore.remove(other)
    #expect(await eventually { model.sshHostsNotAdded.map(\.destination) == ["late"] })

    // The same filter, without a store.
    #expect(RemoteDeviceSettingsModel.sshHostsNotAdded(
        hosts: [try .ssh("studio"), try .ssh("late")],
        devices: [studio]
    ).map(\.destination) == ["late"])
}

// MARK: - Questions and sheets

@Test @MainActor func RemoteDeviceSettingsRemoveAlertsRemoveIsDestructive() {
    var device = RemoteDevice(name: "Mac mini", sshDestination: "mini.local")
    device.createdHostEntry = true
    let created = RemoteDeviceAlerts.makeRemoveAlert(device: device)
    #expect(created.messageText == "Remove Mac mini?")
    #expect(created.informativeText.contains("its saved SSH host and trusted identity are forgotten"))
    #expect(created.buttons.map(\.title) == ["Remove", "Cancel"])
    #expect(created.buttons.map(\.hasDestructiveAction) == [true, false])

    device.createdHostEntry = false
    let own = RemoteDeviceAlerts.makeRemoveAlert(device: device)
    #expect(own.informativeText.contains("your saved SSH host mini.local stays"))
    #expect(own.buttons.first?.hasDestructiveAction == true)
}

@Test @MainActor func RemoteDeviceSettingsForgetAndRemoveProjectSayWhatTheyDo() {
    var forgotten = 0
    let forget = RemoteDeviceAlerts.forgetHostConfirmation(destination: "deploy@build.example.com") { forgotten += 1 }
    #expect(forget == SettingsConfirmation(
        title: "Forget deploy@build.example.com?",
        message: "Its sessions keep running there. Cherry forgets the saved host and its trusted identity.",
        choices: [SettingsConfirmation.Choice("Forget", role: .destructive), .cancel()]
    ))
    forget.choices[0].perform()
    #expect(forgotten == 1)

    var removed = 0
    let remove = RemoteDeviceAlerts.removeProjectConfirmation(path: "~/code/api-server", deviceName: "Mac mini") { removed += 1 }
    #expect(remove == SettingsConfirmation(
        title: "Remove ~/code/api-server from Mac mini's projects?",
        message: "It's hidden from the project picker; Show Again brings it back.",
        choices: [SettingsConfirmation.Choice("Remove", role: .destructive), .cancel()]
    ))
    remove.choices[1].perform()
    #expect(removed == 0)
    remove.choices[0].perform()
    #expect(removed == 1)
}

@Test @MainActor func RemoteDeviceSettingsModelShowsItsAlertsAndSheetsWithItsOwnStore() throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    let mini = try fixture.store.add(name: "Mini", sshDestination: "mini")
    var shown: [(String, UUID, RemoteDeviceStore)] = []
    let model = fixture.model(presenters: RemoteDeviceSettingsModel.Presenters(
        confirmRemove: { shown.append(("remove", $0, $1)) },
        confirmTrustNewIdentity: { shown.append(("trust", $0, $1)) },
        updateSessionHost: { shown.append(("update", $0, $1)) }
    ))
    model.confirmRemove(mini.id)
    model.trustNewIdentity(mini.id)
    model.updateSessionHost(mini.id)
    #expect(shown.map(\.0) == ["remove", "trust", "update"])
    #expect(shown.allSatisfy { $0.1 == mini.id && $0.2 === fixture.store })
    // Asking is not removing.
    #expect(fixture.store.device(id: mini.id) != nil)
}

// MARK: - Sessions

@Test @MainActor func RemoteDeviceSettingsModelFollowsAConnectedMacsSessionCount() async throws {
    let fixture = try MacsFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.store.add(name: "Studio", sshDestination: "studio")
    let fake = FakeControlHelper(sessions: [hostedSession("s-one")])
    let control = makeFakeHostControl(fake, host: try .ssh("studio"), hostStore: fixture.hostStore)
    defer { control.disconnect() }
    let model = fixture.model(control: { _ in control })
    if let first = model.rows.first, case .connected = first.status {
        Issue.record("connected before its control connected")
    }

    let lease = control.retain()
    defer { lease.release() }
    #expect(await eventually { model.rows.first?.status == .connected(sessionCount: 1) })
    // A session the host adds changes the count while the state stays
    // connected.
    let connection = try #require(fake.connections.last)
    let added = hostedSession("s-two")
    fake.sessions.append(added)
    connection.push(.event(.added(added)))
    #expect(await eventually { model.rows.first?.status == .connected(sessionCount: 2) })
    #expect(model.rows.first?.statusText(includingUpdate: false) == "Connected · 2 sessions")
}

// MARK: - Search

@Test @MainActor func RemoteDeviceSettingsSearchFindsEachMacItsProjectsAndTheSSHHosts() throws {
    let defaults = privateDefaults("RemoteDeviceSettingsSearch")
    let mini = RemoteDevice(
        name: "Mac mini", sshDestination: "mini.local", homeDirectory: "/Users/me",
        addedProjects: ["/Users/me/code/api-server"], hiddenProjects: ["/Users/me/code/old-site"]
    )
    let studio = RemoteDevice(name: "Studio", sshDestination: "studio")
    func context(sshHosts: [HostedSessionHost]) -> SettingsSearchContext {
        SettingsSearchContext(
            terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
            agents: AgentSettings(defaults: defaults),
            devices: [mini, studio],
            sshHosts: sshHosts,
            defaults: defaults
        )
    }
    let withHosts = context(sshHosts: [try .ssh("mini.local"), try .ssh("deploy@build.example.com")])
    let rows = MacsSettingsPage.searchRows(in: withHosts)
    #expect(rows.map(\.id) == [.macsList, .mac(mini.id), .mac(studio.id), .macsSSHHosts])
    #expect(rows.allSatisfy { $0.route == .page(.macs) })
    #expect(rows[0].value == "2 Macs")
    let miniRow = rows[1]
    #expect(miniRow.title == "Mac mini" && miniRow.section == "Your Macs" && miniRow.value == "mini.local")
    #expect(miniRow.keywords.contains("~/code/api-server") && miniRow.keywords.contains("~/code/old-site"))
    // A Mac's own destination is its card's, not an SSH host's.
    let hosts = rows[3]
    #expect(hosts.keywords.contains("deploy@build.example.com"))
    #expect(!hosts.keywords.contains("mini.local"))
    #expect(hosts.value == "1 host")
    #expect(!MacsSettingsPage.searchRows(in: context(sshHosts: [try .ssh("studio")])).contains { $0.id == .macsSSHHosts })

    let index = SettingsSearchIndex.rows(in: withHosts)
    func macsResults(_ query: String) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: index)
            .first { $0.kind == .page(.macs) }?
            .results.map(\.id) ?? []
    }
    #expect(macsResults("mac mini").first == .mac(mini.id))
    #expect(macsResults("api-server") == [.mac(mini.id)])
    #expect(macsResults("studio").first == .mac(studio.id))
    #expect(macsResults("deploy") == [.macsSSHHosts])
    #expect(macsResults("identity").contains(.macsSSHHosts))
    #expect(macsResults("destination").contains(.macsList))
}
