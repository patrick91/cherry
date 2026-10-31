import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// Home (`HomePlace`): each Mac's place for terminals that belong to no
// project. It is the window of that Mac's home folder, named "Home", with
// no commands or to-dos; New Terminal in Home and Go to Home reach it from
// any window, and the Omni bar lists each Mac's Home first.

private let studioID = UUID()
private let studio = RemoteDevice(
    id: studioID, name: "Studio", sshDestination: "studio", homeDirectory: "/Users/them",
    addedProjects: ["/Users/them/app"]
)
private let studioHome = studio.projectKey(path: "/Users/them")
private let thisMac = ProjectSwitcherModel.thisMacInfo(sessionCount: nil, symbol: "desktopcomputer")

private func switcherModel(
    openWindows: [String: ProjectSwitcherModel.OpenStatus] = [:],
    currentProjectKey: String? = nil
) -> ProjectSwitcherModel {
    ProjectSwitcherModel.make(
        localProjects: [
            .init(root: "/Users/me/code/cherry", name: "cherry"),
            // The home folder, as a recently opened folder: Home's row.
            .init(root: "/Users/me", name: "me"),
        ],
        devices: [.init(device: studio, state: .connected(sessionCount: 0), sessions: [])],
        openWindows: openWindows,
        recency: [:],
        currentProjectKey: currentProjectKey,
        thisMac: thisMac,
        localHome: "/Users/me",
        listsHomes: true
    )
}

@Test func homePlaceIsTheWindowOfEachMacsHomeFolder() {
    #expect(HomePlace.isHome("/Users/me", localHome: "/Users/me"))
    #expect(HomePlace.isHome("/Users/me/", localHome: "/Users/me"))
    #expect(!HomePlace.isHome("/Users/me/code", localHome: "/Users/me"))
    #expect(!HomePlace.isHome(nil, localHome: "/Users/me"))
    #expect(HomePlace.isHome(studioHome, localHome: "/Users/me", deviceHomes: [studioID: "/Users/them"]))
    // A device whose home is not known yet, another folder there, and This
    // Mac's folder of the same path are not its Home.
    #expect(!HomePlace.isHome(studioHome, localHome: "/Users/me", deviceHomes: [:]))
    #expect(!HomePlace.isHome(
        studio.projectKey(path: "/Users/them/app"), localHome: "/Users/me", deviceHomes: [studioID: "/Users/them"]
    ))
    #expect(!HomePlace.isHome(studioHome, localHome: "/Users/them", deviceHomes: [:]))
    #expect(!HomePlace.isHome("/Users/them", localHome: "/Users/me", deviceHomes: [studioID: "/Users/them"]))

    #expect(HomePlace.key(on: .thisMac, deviceHomes: [:]) == HomePlace.thisMacKey)
    #expect(HomePlace.key(on: .device(studioID), deviceHomes: [studioID: "/Users/them"]) == studioHome)
    #expect(HomePlace.key(on: .device(studioID), deviceHomes: [:]) == nil)
}

@Test @MainActor func homePlaceIsNamedHomeAndHasNoCommandsOrTodos() throws {
    #expect(CherryProject(root: HomePlace.thisMacKey).name == "Home")
    #expect(CherryProject(root: "/tmp/home-place/app").name == "app")

    let defaults = try #require(UserDefaults(suiteName: "HomePlaceTests-\(UUID().uuidString)"))
    let settings = AgentSettings(defaults: defaults)
    #expect(settings.projects.isEmpty)
    // With no project, a window opens Home.
    #expect(settings.projectRoot(for: nil) == HomePlace.thisMacKey)
    // Even a command kept for the home folder is none of Home's.
    try settings.upsertCommand(
        ProjectCommandDefinition(name: "serve", command: "python3 -m http.server"),
        for: HomePlace.thisMacKey
    )
    #expect(settings.projectCommands(for: HomePlace.thisMacKey).isEmpty)
    #expect(!settings.projectFeatures(for: HomePlace.thisMacKey).todosEnabled)

    let repository = RepositoryWorkspace(projectRoot: HomePlace.thisMacKey, autoStartCommands: { _ in [] })
    defer { repository.closeAllSessions(intent: .windowClosed) }
    #expect(repository.isHome)
    #expect(repository.repositoryName == "Home")
}

@Test func homePlaceIsEachMacsFirstProjectInTheSwitcher() {
    let model = switcherModel(
        openWindows: ["/Users/me": .init(workingAgents: 1), studioHome: .init(workingAgents: 0)],
        currentProjectKey: "/Users/me"
    )
    let local = model.locations.filter { $0.machine == .thisMac }
    // Its home folder's own row is Home's.
    #expect(local.map(\.name) == ["Home", "cherry"])
    #expect(local[0].isHome && local[0].key == "/Users/me" && local[0].displayPath == "~")
    #expect(local[0].openStatus?.workingAgents == 1 && local[0].isCurrent)
    #expect(!local[1].isHome)

    let onStudio = model.locations.filter { $0.machine == .device(studioID) }
    #expect(onStudio.map(\.name) == ["Home", "app"])
    #expect(onStudio[0].isHome && onStudio[0].key == studioHome && onStudio[0].isOpen)

    // Without `listsHomes` (tests' default) nothing changes.
    let plain = ProjectSwitcherModel.make(
        localProjects: [.init(root: "/Users/me", name: "me")], devices: [], openWindows: [:], recency: [:],
        currentProjectKey: nil, thisMac: thisMac, localHome: "/Users/me"
    )
    #expect(plain.locations.map(\.name) == ["me"])
    #expect(!plain.locations[0].isHome)
}

@Test @MainActor func homePlaceRowsShowAHouseAndComeFirstAmongAllProjects() throws {
    var sources = OmniSources()
    sources.projects = switcherModel()
    sources.devices = [.init(device: studio, state: .connected(sessionCount: 0), sessions: [])]
    let rows = OmniProviders.projects(sources)
    let home = try #require(rows.first { $0.id == "project:/Users/me" })
    #expect(home.title == "Home")
    #expect(home.symbol == HomePlace.symbol)
    #expect(home.keywords.contains("home"))
    #expect(rows.first { $0.id == "project:/Users/me/code/cherry" }?.symbol == "folder")
    // A device's Home is never hidden; its other projects can be.
    let studioHomeRow = try #require(rows.first { $0.id == "project:\(studioHome)" })
    #expect(!studioHomeRow.actions.contains { $0.title == "Remove from Projects" })
    let app = try #require(rows.first { $0.id == "project:\(studio.projectKey(path: "/Users/them/app"))" })
    #expect(app.actions.contains { $0.title == "Remove from Projects" })

    let all = try #require(OmniProviders.projectSections(sources).first { $0.title == "All" })
    #expect(all.rows.map(\.item.title) == ["Home", "Home", "app", "cherry"])
}

@Test @MainActor func homePlaceCommandsAreInTheOmniBarWithTheirShortcuts() throws {
    let commands = OmniProviders.commands(OmniSources())
    let newTerminal = try #require(commands.first { $0.id == "command:newHomeTerminal" })
    #expect(newTerminal.title == "New Terminal in Home")
    #expect(newTerminal.detail == CherryShortcut.newHomeTerminal.display)
    #expect(newTerminal.primary == .menu(.newHomeTerminal))
    let goHome = try #require(commands.first { $0.id == "command:goHome" })
    #expect(goHome.title == "Go to Home")
    #expect(goHome.detail == CherryShortcut.goHome.display)
    #expect(goHome.primary == .menu(.goHome))
    #expect(CherryShortcut.newHomeTerminal.display == "⌥⌘T")
    #expect(CherryShortcut.goHome.display == "⇧⌘H")
}

@Test @MainActor func homePlaceNewTerminalGoesToHomeNeverToAProjectWindow() throws {
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    var opened: [String?] = []
    registry.projectWindowOpener = { opened.append($0) }
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("home-place-\(UUID().uuidString)", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: projectRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    var windows: [(window: NSWindow, repository: RepositoryWorkspace)] = []
    func claim(_ root: String) -> RepositoryWorkspace {
        let repository = RepositoryWorkspace(projectRoot: root, autoStartCommands: { _ in [] })
        let window = testWindow()
        #expect(registry.register(
            window: window, projectRoot: repository.repositoryRoot,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        windows.append((window, repository))
        return repository
    }
    defer {
        for (window, repository) in windows {
            registry.unregister(window: window, projectRoot: repository.repositoryRoot)
            repository.closeAllSessions(intent: .windowClosed)
        }
    }

    // Only a project's window is open: Home opens, the project gets nothing.
    let project = claim(projectRoot)
    #expect(registry.newTerminalInHome())
    #expect(opened == [HomePlace.thisMacKey])
    #expect(project.workspace.sessions.count == 1)
    // Home opens with its first terminal, and no second one.
    let home = claim(HomePlace.thisMacKey)
    #expect(home.workspace.sessions.count == 1)

    // Home is open: a new terminal there, in the home folder; nothing opens.
    #expect(registry.newTerminalInHome())
    #expect(opened.count == 1)
    #expect(home.workspace.sessions.count == 2)
    #expect(home.workspace.selectedSession?.workingDirectory == HomePlace.thisMacKey)
    #expect(project.workspace.sessions.count == 1)

    #expect(registry.showHome())
    #expect(opened == [HomePlace.thisMacKey, HomePlace.thisMacKey])
    // A device whose home folder is not known yet has no Home.
    #expect(!registry.newTerminalInHome(on: .device(UUID())))
    #expect(!registry.showHome(on: .device(UUID())))
    #expect(opened.count == 2)
}
