import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// The project switcher's model (`ProjectSwitcherModel`), which the Omni bar
// lists projects and Macs from: recency, Macs' states, building from the
// app's state, opening, offline Macs and paths. No window comes on screen and
// no real store is touched.

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let studioID = UUID(uuidString: "00000000-0000-0000-0000-0000000057D1")!
private let miniID = UUID(uuidString: "00000000-0000-0000-0000-0000000057D2")!

private func minutesAgo(_ minutes: Double) -> Date {
    now.addingTimeInterval(-minutes * 60)
}

private func privateDefaults() -> UserDefaults {
    let name = "cherry-project-switcher-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let thisMac = ProjectSwitcherModel.MachineInfo(
    machine: .thisMac, name: "This Mac", status: "3 sessions", dot: .green, sessionCount: 3, detail: "MacBook"
)

private func device(
    _ id: UUID,
    _ name: String,
    reachable: Bool = true,
    allowsOpening: Bool = true
) -> ProjectSwitcherModel.MachineInfo {
    .init(
        machine: .device(id), name: name, status: reachable ? "Connected · 1 session" : "Offline",
        dot: reachable ? .green : .gray, sessionCount: reachable ? 1 : nil, detail: name,
        isReachable: reachable, allowsOpening: allowsOpening,
        unreachableMessage: reachable ? nil : "\(name) isn't reachable."
    )
}

private func local(
    _ name: String,
    path: String? = nil,
    open: ProjectSwitcherModel.OpenStatus? = nil,
    current: Bool = false,
    lastOpened: Date? = nil
) -> ProjectSwitcherModel.Location {
    let path = path ?? "/Users/me/code/\(name)"
    return .init(
        machine: .thisMac, key: path, name: name, path: path,
        displayPath: ProjectSwitcherModel.displayPath(path, home: "/Users/me"),
        openStatus: open, isCurrent: current, lastOpened: lastOpened
    )
}

private func remote(
    _ id: UUID,
    _ name: String,
    open: ProjectSwitcherModel.OpenStatus? = nil,
    lastOpened: Date? = nil
) -> ProjectSwitcherModel.Location {
    let path = "/Users/me/code/\(name)"
    return .init(
        machine: .device(id), key: ProjectLocation.remote(deviceID: id, path: path).key, name: name, path: path,
        displayPath: ProjectSwitcherModel.displayPath(path, home: "/Users/me"),
        openStatus: open, lastOpened: lastOpened
    )
}

// MARK: - Recency

@Test @MainActor func recencyStoreKeepsTheLastOpeningPerKeyAcrossInstances() {
    let defaults = privateDefaults()
    let store = ProjectRecencyStore(defaults: defaults)
    store.markOpened("/a", at: minutesAgo(30))
    store.markOpened("/b", at: minutesAgo(20))
    store.markOpened("device:\(studioID.uuidString.lowercased()):/c", at: minutesAgo(10))
    #expect(store.recentKeys(limit: 2) == ["device:\(studioID.uuidString.lowercased()):/c", "/b"])

    store.markOpened("/a", at: minutesAgo(1))
    #expect(store.recentKeys(limit: 1) == ["/a"])
    #expect(store.lastOpened("/a") == minutesAgo(1))

    let reloaded = ProjectRecencyStore(defaults: defaults)
    #expect(reloaded.dates == store.dates)
    #expect(reloaded.recentKeys(limit: 3).first == "/a")
}

@Test @MainActor func recencyStoreKeepsOnlyTheMostRecentKeys() {
    let store = ProjectRecencyStore(defaults: privateDefaults())
    for index in 0 ..< (ProjectRecencyStore.capacity + 10) {
        store.markOpened("/p\(index)", at: now.addingTimeInterval(Double(index) * 60))
    }
    #expect(store.dates.count == ProjectRecencyStore.capacity)
    #expect(store.lastOpened("/p0") == nil)
    #expect(store.lastOpened("/p\(ProjectRecencyStore.capacity + 9)") != nil)
}

@Test @MainActor func aProjectWindowMarksItsProjectOpenedWhenItBecomesActive() throws {
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    let recency = ProjectRecencyStore(defaults: privateDefaults())
    registry.projectRecency = recency
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-switcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer {
        registry.unregister(window: window, projectRoot: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    #expect(registry.register(
        window: window, projectRoot: root.path, workspace: workspace,
        noteStore: nil, todoStore: nil, chromeState: nil
    ))
    let key = registry.canonicalProjectRoot(for: root.path)
    #expect(recency.lastOpened(key) != nil)
    #expect(registry.openProjectWindowStatuses()[key] == .init(tabs: 0, workingAgents: 0))

    #expect(registry.focus(projectRoot: root.path))
    #expect(recency.recentKeys(limit: 1) == [key])
}

// MARK: - Offline Macs

@Test func anOfflineMacsProjectsStillOpenButAnotherIdentityCannot() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio"), device(miniID, "Mini", reachable: false)],
        locations: [local("shop"), remote(miniID, "argocd"), remote(studioID, "cherry")]
    )
    #expect(!model.isReachable(.device(miniID)))
    // Its projects still open (the window waits for it), as from the menu.
    #expect(model.action(opening: model.locations[1]) == .openDeviceProject(deviceID: miniID, path: "/Users/me/code/argocd"))
    #expect(model.action(opening: model.locations[0]) == .openProject("/Users/me/code/shop"))
    #expect(model.machine(.device(miniID))?.unreachableMessage == "Mini isn't reachable.")
    #expect(model.name(of: .device(studioID)) == "Studio")
    #expect(model.projectCount(on: .thisMac) == 1)

    let changed = ProjectSwitcherModel(
        machines: [thisMac, device(miniID, "Mini", reachable: false, allowsOpening: false)],
        locations: [remote(miniID, "argocd")]
    )
    #expect(changed.action(opening: changed.locations[0]) == nil)
}

@Test func deviceStatesBecomeMachineInfoWithoutConnecting() {
    let studio = RemoteDevice(
        id: studioID, name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me",
        addedProjects: ["/Users/me/notes"], lastSeen: now.addingTimeInterval(-3 * 86_400),
        installedBuild: "20260928211211"
    )
    let offline = ProjectSwitcherModel.machineInfo(
        for: .init(device: studio, state: .offline(reason: "timed out"), sessions: []),
        projectCount: 1, now: now
    )
    #expect(!offline.isReachable)
    #expect(offline.allowsOpening)
    #expect(offline.status == "Offline")
    #expect(offline.dot == .gray)
    #expect(offline.sessionCount == nil)
    #expect(offline.unreachableMessage?.hasPrefix("Studio isn't reachable (last seen") == true)
    #expect(offline.detail == "studio over SSH · session host 20260928211211 · 1 project")

    let reachable = ProjectSwitcherModel.machineInfo(
        for: .init(device: studio, state: .reachable(sessionCount: 2), sessions: []),
        projectCount: 1, now: now
    )
    #expect(reachable.isReachable)
    #expect(reachable.sessionCount == 2)
    #expect(reachable.status == "Reachable · 2 sessions")
    #expect(reachable.unreachableMessage == nil)

    let changed = ProjectSwitcherModel.machineInfo(
        for: .init(device: studio, state: .identityChanged(reason: "Expected a, received b."), sessions: []),
        projectCount: 1, now: now
    )
    #expect(!changed.allowsOpening)
    #expect(changed.offersTrustNewIdentity)
}

// MARK: - Building from the app's state

@Test func makeMergesSettingsProjectsDeviceFoldersOpenWindowsAndRecency() {
    let studio = RemoteDevice(
        id: studioID, name: "Studio", sshDestination: "studio", homeDirectory: "/Users/me",
        addedProjects: ["/Users/me/code/cherry", "/Users/me/code/rignore"]
    )
    let cherryKey = studio.projectKey(path: "/Users/me/code/cherry")
    let homeKey = studio.projectKey(path: "/Users/me")
    let model = ProjectSwitcherModel.make(
        localProjects: [
            .init(root: "/Users/me/code/cherry", name: "cherry"),
            .init(root: "/Users/me/code/pix", name: "pix"),
            .init(root: "/Users/me/code/pix", name: "pix"),
        ],
        devices: [.init(device: studio, state: .connected(sessionCount: 0), sessions: [])],
        openWindows: [
            "/Users/me/code/pix": .init(tabs: 3, workingAgents: 2),
            homeKey: .init(tabs: 1, workingAgents: 0),
        ],
        recency: [cherryKey: minutesAgo(3), "/Users/me/code/cherry": minutesAgo(30)],
        currentProjectKey: homeKey,
        thisMac: thisMac,
        localHome: "/Users/me",
        now: now
    )
    #expect(model.machines.map(\.name) == ["This Mac", "Studio"])
    #expect(model.currentMachine == .device(studioID))
    #expect(model.locations.filter { $0.machine == .thisMac }.map(\.name) == ["cherry", "pix"])
    let locations = Dictionary(uniqueKeysWithValues: model.locations.map { ($0.key, $0) })
    #expect(locations[cherryKey]?.lastOpened == minutesAgo(3))
    #expect(locations["/Users/me/code/cherry"]?.lastOpened == minutesAgo(30))
    #expect(locations["/Users/me/code/pix"]?.openStatus?.text == "2 agents working · 3 tabs")
    #expect(locations["/Users/me/code/pix"]?.displayPath == "~/code/pix")
    // A device window of a folder its host does not list is listed too.
    #expect(locations[homeKey]?.name == "me")
    #expect(locations[homeKey]?.isCurrent == true)
    #expect(model.locations.filter { $0.machine == .device(studioID) }.count == 3)
}

// MARK: - Paths and labels

@Test func pathLikeQueriesOpenAsFolders() {
    #expect(ProjectSwitcherModel.looksLikePath("/tmp/x"))
    #expect(ProjectSwitcherModel.looksLikePath("~"))
    #expect(ProjectSwitcherModel.looksLikePath(" ~/code "))
    #expect(!ProjectSwitcherModel.looksLikePath("cherry"))
    #expect(!ProjectSwitcherModel.looksLikePath("~me"))
    #expect(ProjectSwitcherModel.expandedPath("~/code", home: "/Users/me") == "/Users/me/code")
    #expect(ProjectSwitcherModel.expandedPath("~", home: "/Users/me") == "/Users/me")
    #expect(ProjectSwitcherModel.expandedPath("/opt/x", home: nil) == "/opt/x")
    #expect(ProjectSwitcherModel.expandedPath("~/code", home: nil) == nil)
    #expect(ProjectSwitcherModel.displayPath("/Users/me/code", home: "/Users/me") == "~/code")
    #expect(ProjectSwitcherModel.displayPath("/Users/meta", home: "/Users/me") == "/Users/meta")
    #expect(ProjectSwitcherModel.displayPath("/Users/me", home: "/Users/me/") == "~")
}
