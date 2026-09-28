import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// The project switcher's model (`ProjectSwitcherModel`): ranking, grouping
// across Macs, sections, recency, the Mac filter cycle, offline Macs and the
// style setting. No window comes on screen and no real store is touched.

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

private func titles(_ sections: [ProjectSwitcherModel.Section]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: sections.map { ($0.title, $0.groups.map(\.name)) })
}

// MARK: - Style

@Test func projectSwitcherStyleDefaultsToThePaletteAndReadsTheSetting() {
    let defaults = privateDefaults()
    #expect(ProjectSwitcherStyle.current(in: defaults) == .palette)
    defaults.set("sidebar", forKey: ProjectSwitcherStyle.defaultsKey)
    #expect(ProjectSwitcherStyle.current(in: defaults) == .sidebar)
    defaults.set("menu", forKey: ProjectSwitcherStyle.defaultsKey)
    #expect(ProjectSwitcherStyle.current(in: defaults) == .menu)
    defaults.set("something-else", forKey: ProjectSwitcherStyle.defaultsKey)
    #expect(ProjectSwitcherStyle.current(in: defaults) == .palette)
    #expect(ProjectSwitcherStyle.allCases.map(\.title) == ["Menu", "Palette", "Macs Sidebar"])
}

@Test @MainActor func projectSwitcherToggleOpensTheChosenStyleAndClosesTheOneShown() {
    let chrome = ProjectWindowChromeState()
    chrome.toggleProjectSwitcher(style: .palette)
    #expect(chrome.projectSwitcherPresentation == .palette)
    chrome.toggleProjectSwitcher(style: .palette)
    #expect(chrome.projectSwitcherPresentation == nil)

    chrome.toggleProjectSwitcher(style: .sidebar)
    #expect(chrome.projectSwitcherPresentation == .sidebarPopover)
    chrome.toggleProjectSwitcher(style: .sidebar)

    // The picker slides away with a hidden sidebar: nothing to anchor to.
    chrome.isSidebarHidden = true
    chrome.toggleProjectSwitcher(style: .sidebar)
    #expect(chrome.projectSwitcherPresentation == .sidebarOverlay)
    chrome.toggleProjectSwitcher(style: .sidebar)

    let requests = chrome.projectSwitcherMenuRequest
    chrome.toggleProjectSwitcher(style: .menu)
    #expect(chrome.projectSwitcherPresentation == nil)
    #expect(chrome.projectSwitcherMenuRequest == requests + 1)

    // The command palette and the switcher never show together.
    chrome.toggleProjectSwitcher(style: .palette)
    chrome.presentCommandPalette()
    #expect(chrome.projectSwitcherPresentation == nil)
    chrome.toggleProjectSwitcher(style: .palette)
    #expect(!chrome.isCommandPalettePresented)
}

@Test func commandOTogglesTheProjectSwitcher() {
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "o", modifiers: .command) == .toggleProjectSwitcher)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "o", modifiers: [.command, .shift]) == nil)
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

// MARK: - Grouping across Macs

@Test func aProjectOnSeveralMacsIsOneGroupWhosePrimaryIsTheOpenOrMostRecentOne() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio")],
        locations: [
            local("cherry", lastOpened: minutesAgo(60)),
            remote(studioID, "cherry", lastOpened: minutesAgo(3)),
            local("pix", open: .init(tabs: 1, workingAgents: 0), lastOpened: minutesAgo(90)),
            remote(studioID, "pix", lastOpened: minutesAgo(1)),
            remote(studioID, "rignore"),
        ]
    )
    let groups = Dictionary(uniqueKeysWithValues: model.groups().map { ($0.name, $0) })
    #expect(groups.count == 3)
    // The most recent opening wins…
    #expect(groups["cherry"]?.locations.map(\.machine) == [.device(studioID), .thisMac])
    // …but an open window wins over it.
    #expect(groups["pix"]?.primary.machine == .thisMac)
    #expect(groups["pix"]?.isOpen == true)
    #expect(groups["rignore"]?.locations.map(\.machine) == [.device(studioID)])

    // Enter opens the primary through the picker's own actions.
    let cherry = try! #require(groups["cherry"])
    #expect(model.action(opening: cherry.primary) == .openDeviceProject(deviceID: studioID, path: "/Users/me/code/cherry"))
    #expect(model.action(opening: cherry.locations[1]) == .openProject("/Users/me/code/cherry"))
}

@Test func twoFoldersOfOneNameOnOneMacStayApartAndNamesMatchCaseInsensitively() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio")],
        locations: [
            local("app", path: "/Users/me/work/app"),
            local("app", path: "/Users/me/play/app"),
            remote(studioID, "App"),
        ]
    )
    let groups = model.groups()
    #expect(groups.count == 2)
    #expect(groups.map { $0.locations.count }.sorted() == [1, 2])
    #expect(Set(groups.map(\.id)).count == 2)
    #expect(groups.allSatisfy { group in Set(group.locations.map(\.machine)).count == group.locations.count })
}

@Test func theMacFilterKeepsOnlyThatMacsProjects() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio")],
        locations: [local("cherry"), remote(studioID, "cherry"), local("site"), remote(studioID, "rignore")]
    )
    #expect(model.groups(filter: .device(studioID)).map(\.name).sorted() == ["cherry", "rignore"])
    #expect(model.groups(filter: .device(studioID)).allSatisfy { $0.locations.count == 1 })
    #expect(model.groups(filter: .thisMac).map(\.name).sorted() == ["cherry", "site"])
    #expect(model.groups(filter: nil).count == 3)
}

// MARK: - Sections

@Test func anEmptyQueryListsOpenRecentAndAllProjects() {
    var locations = [
        local("cherry", open: .init(tabs: 4, workingAgents: 1), current: true, lastOpened: minutesAgo(0)),
        local("pix", open: .init(tabs: 1, workingAgents: 0), lastOpened: minutesAgo(2)),
        remote(studioID, "rignore", open: .init(tabs: 2, workingAgents: 0), lastOpened: minutesAgo(1)),
    ]
    for (index, name) in ["a1", "a2", "a3", "a4", "a5", "a6"].enumerated() {
        locations.append(local(name, lastOpened: minutesAgo(Double(10 + index))))
    }
    locations += [local("zeta"), local("Beta"), local("alpha")]
    let model = ProjectSwitcherModel(machines: [thisMac, device(studioID, "Studio")], locations: locations)
    let sections = model.sections(query: "")
    #expect(sections.map(\.kind) == [.open, .recent, .all])
    // The current window first, then the most recent.
    #expect(sections[0].groups.map(\.name) == ["cherry", "rignore", "pix"])
    #expect(sections[1].groups.map(\.name) == ["a1", "a2", "a3", "a4", "a5"])
    #expect(sections[2].groups.map(\.name) == ["a6", "alpha", "Beta", "zeta"])
    #expect(sections[0].groups[0].openLocation?.openStatus?.text == "1 agent working · 4 tabs")
    #expect(sections[0].groups[2].openLocation?.openStatus?.text == "1 tab")
}

@Test func emptySectionsAreLeftOut() {
    let model = ProjectSwitcherModel(machines: [thisMac], locations: [local("b"), local("a")])
    let sections = model.sections(query: "  ")
    #expect(sections.map(\.kind) == [.all])
    #expect(sections[0].groups.map(\.name) == ["a", "b"])
    #expect(ProjectSwitcherModel(machines: [thisMac], locations: []).sections(query: "").isEmpty)
}

@Test func aQueryRanksNamePrefixThenNameThenPathThenRecency() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio")],
        locations: [
            local("strawberry.rocks", lastOpened: minutesAgo(5)),
            local("pytest-strawberry-plugin", lastOpened: minutesAgo(1)),
            local("straw", lastOpened: minutesAgo(50)),
            local("docs", path: "/Users/me/strawberry/docs"),
            local("unrelated"),
            remote(studioID, "Stray", lastOpened: minutesAgo(2)),
        ]
    )
    let results = model.sections(query: "STRA")
    #expect(results.map(\.kind) == [.results])
    #expect(results[0].groups.map(\.name) == ["Stray", "strawberry.rocks", "straw", "pytest-strawberry-plugin", "docs"])

    // Paths match as shown (`~`) and in full.
    #expect(model.sections(query: "~/strawberry").first?.groups.map(\.name) == ["docs"])
    #expect(model.sections(query: "/users/me/strawberry/d").first?.groups.map(\.name) == ["docs"])
    // Nothing matches: no section at all.
    #expect(model.sections(query: "nope").isEmpty)
    // Diacritics fold.
    #expect(model.sections(query: "strä").first?.groups.first?.name == "Stray")
}

@Test func aQueryWithAFilterSearchesOnlyThatMac() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio")],
        locations: [local("cherry"), remote(studioID, "cherry"), remote(studioID, "cherry-docs")]
    )
    let results = model.sections(query: "cher", filter: .thisMac)
    #expect(results.first?.groups.map(\.name) == ["cherry"])
    #expect(results.first?.groups.first?.locations.map(\.machine) == [.thisMac])
    #expect(model.sections(query: "cher", filter: .device(studioID)).first?.groups.count == 2)
}

// MARK: - Filter cycle

@Test func tabCyclesAllMacsThisMacAndEachDevice() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(studioID, "Studio"), device(miniID, "Mini", reachable: false)],
        locations: []
    )
    var filter: ProjectSwitcherModel.Machine? = nil
    var seen: [ProjectSwitcherModel.Machine?] = []
    for _ in 0 ..< 4 {
        filter = model.nextFilter(after: filter)
        seen.append(filter)
    }
    #expect(seen == [.thisMac, .device(studioID), .device(miniID), nil])
    #expect(model.nextFilter(after: nil, backwards: true) == .device(miniID))
    #expect(model.nextFilter(after: .thisMac, backwards: true) == nil)

    // The sidebar has no All Macs.
    #expect(model.nextMachine(after: .device(miniID)) == .thisMac)
    #expect(model.nextMachine(after: .thisMac, backwards: true) == .device(miniID))
    #expect(model.nextMachine(after: .thisMac) == .device(studioID))
}

// MARK: - Offline Macs

@Test func anOfflineMacsProjectsStayListedButAReachableCopyIsPrimary() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(miniID, "Mini", reachable: false)],
        locations: [
            local("shop", lastOpened: minutesAgo(600)),
            remote(miniID, "shop", lastOpened: minutesAgo(1)),
            remote(miniID, "argocd"),
        ]
    )
    let groups = Dictionary(uniqueKeysWithValues: model.groups().map { ($0.name, $0) })
    #expect(groups["shop"]?.primary.machine == .thisMac)
    #expect(groups["argocd"]?.primary.machine == .device(miniID))
    #expect(!model.isReachable(.device(miniID)))
    // Its projects still open (the window waits for it), as from the menu.
    #expect(model.action(opening: groups["argocd"]!.primary) != nil)
    #expect(model.machine(.device(miniID))?.unreachableMessage == "Mini isn't reachable.")
}

@Test func aMacWithAnotherIdentityCannotBeOpened() {
    let model = ProjectSwitcherModel(
        machines: [thisMac, device(miniID, "Mini", reachable: false, allowsOpening: false)],
        locations: [remote(miniID, "argocd")]
    )
    #expect(model.action(opening: model.groups()[0].primary) == nil)
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
    let groups = Dictionary(uniqueKeysWithValues: model.groups().map { ($0.name, $0) })
    #expect(groups["cherry"]?.primary.key == cherryKey)
    #expect(groups["cherry"]?.locations.count == 2)
    #expect(groups["pix"]?.openLocation?.openStatus?.text == "2 agents working · 3 tabs")
    #expect(groups["pix"]?.primary.displayPath == "~/code/pix")
    // A device window of a folder its host does not list is listed too.
    #expect(groups["me"]?.primary.key == homeKey)
    #expect(groups["me"]?.isCurrent == true)
    #expect(model.sections(query: "").first?.groups.first?.name == "me")
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

@Test func agoLabelsReadAsThePrototypeDoes() {
    #expect(ProjectSwitcherModel.agoLabel(nil, now: now) == "")
    #expect(ProjectSwitcherModel.agoLabel(minutesAgo(0.2), now: now) == "just now")
    #expect(ProjectSwitcherModel.agoLabel(minutesAgo(5), now: now) == "5 min ago")
    #expect(ProjectSwitcherModel.agoLabel(minutesAgo(125), now: now) == "2 h ago")
    #expect(ProjectSwitcherModel.agoLabel(minutesAgo(60 * 30), now: now) == "yesterday")
    #expect(ProjectSwitcherModel.agoLabel(minutesAgo(60 * 24 * 4), now: now) == "4 days ago")
}

// MARK: - Performance

@Test func sectionsStayFastWithManyProjects() {
    var locations: [ProjectSwitcherModel.Location] = []
    for index in 0 ..< 300 {
        locations.append(local("project-\(index)", lastOpened: index % 3 == 0 ? minutesAgo(Double(index)) : nil))
        if index % 4 == 0 { locations.append(remote(studioID, "project-\(index)")) }
    }
    let model = ProjectSwitcherModel(machines: [thisMac, device(studioID, "Studio")], locations: locations)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for query in ["", "p", "pr", "pro", "project-1", "project-12"] {
            _ = model.sections(query: query)
        }
    }
    #expect(model.groups().count == 300)
    #expect(elapsed < .milliseconds(500))
}
