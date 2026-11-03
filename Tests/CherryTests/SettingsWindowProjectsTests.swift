import AppKit
import Foundation
import Testing
@testable import Cherry

// Settings › Projects (ProjectsSettingsPage.swift): the Default editor's
// pop-up and badge, the project rows, Removed folders and Offer Again, Add
// Project…, and what search finds on the page. Private defaults and
// temporary folders; the editors are made up (no Launch Services); never
// `SettingsSearchContext.live()`. Remove…'s question is in
// BackgroundSessionsTests (`ProjectRemoval`).

private func installedEditor(_ id: String) throws -> InstalledEditor {
    let editor = try #require(ExternalEditorCatalog.all.first { $0.id == id })
    return InstalledEditor(
        editor: editor,
        bundleIdentifier: editor.bundleIdentifiers[0],
        appURL: URL(fileURLWithPath: "/Applications/\(editor.displayName).app", isDirectory: true)
    )
}

/// A folder as Settings names it: the way `AgentSettings` stores a
/// project's root (the temporary folder without its /private).
@MainActor
private func settingsPath(_ url: URL) throws -> String {
    try #require(AgentSettings.validDirectory(url.path))
}

private func folder(_ path: String, in base: URL) throws -> URL {
    let url = base.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func theDefaultEditorMenuIsNamedAfterTheFirstInstalledEditor() throws {
    let editors = [try installedEditor("zed"), try installedEditor("cursor")]

    let automatic = DefaultEditorMenu(installed: editors, storedID: "")
    #expect(automatic.options.map(\.title) == ["Automatic (Zed)", "Zed", "Cursor"])
    #expect(automatic.options.map(\.id) == ["", "zed", "cursor"])
    #expect(automatic.selectedTitle == "Automatic (Zed)")

    let cursor = DefaultEditorMenu(installed: editors, storedID: "cursor")
    #expect(cursor.options == automatic.options)
    #expect(cursor.selectedTitle == "Cursor")
}

@Test func aDefaultEditorThatIsGoneShowsAsNotInstalled() throws {
    let zed = try installedEditor("zed")

    let xcode = DefaultEditorMenu(installed: [zed], storedID: "xcode")
    #expect(xcode.options.map(\.title) == ["Automatic (Zed)", "Zed", "Xcode (not installed)"])
    #expect(xcode.selection == "xcode")
    #expect(xcode.selectedTitle == "Xcode (not installed)")
    // One Cherry no longer knows keeps its id.
    #expect(DefaultEditorMenu(installed: [zed], storedID: "kate").selectedTitle == "kate (not installed)")

    // No editor installed: no pop-up, "No editors found".
    let none = DefaultEditorMenu(installed: [], storedID: "zed")
    #expect(none.options.isEmpty)
    #expect(none.selectedTitle == nil)
    #expect(DefaultEditorMenu.noEditorsText == "No editors found")
}

@Test @MainActor func aChosenDefaultEditorIsSetHereAndItsResetGoesBackToAutomatic() {
    let defaults = privateDefaults("SettingsWindowProjects")
    let terminal = TerminalSettings(defaults: defaults)
    #expect(SettingsSourceState.terminal(.defaultEditorID, in: terminal).badgeText == nil)

    terminal.defaultEditorID = "xcode"
    let source = SettingsSourceState.terminal(.defaultEditorID, in: terminal)
    #expect(source.badgeText == "Set here")
    #expect(source.source.isEditable)
    #expect(source.rowReset?.title == "Reset to default (Automatic)")

    source.rowReset?.perform()
    #expect(terminal.defaultEditorID == "")
    #expect(defaults.object(forKey: TerminalSettings.Setting.defaultEditorID.rawValue) == nil)
}

@Test @MainActor func projectsAreListedByNameOnTilesOfTheirColorWithPathsFromHome() {
    let cherry = "/Users/someone/code/cherry"
    let projects = [
        CherryProject(root: "/Users/someone/code/docs-site"),
        CherryProject(root: cherry),
        CherryProject(root: "/Volumes/Work/api-server"),
        CherryProject(root: "device:\(UUID().uuidString):/Users/me/code/remote"),
    ]
    let colors: [String: ProjectIdentityColor] = [cherry: .blue]

    let rows = ProjectsSettingsContent.projectRows(projects, home: "/Users/someone") { colors[$0] }

    #expect(rows.map(\.name) == ["api-server", "cherry", "docs-site"])
    #expect(rows.map(\.path) == ["/Volumes/Work/api-server", "~/code/cherry", "~/code/docs-site"])
    #expect(rows.map(\.tile.background) == ["#7C7C84", ProjectIdentityColor.blue.hexRGB, "#7C7C84"])
    #expect(rows.allSatisfy { $0.tile.glyph == .symbol("folder.fill") })
}

@Test @MainActor func offerAgainForgetsARemovedFolderWithoutAddingIt() throws {
    let defaults = privateDefaults("SettingsWindowProjects")
    let settings = AgentSettings(defaults: defaults)
    let home = try canonicalTemporaryDirectory("cherry-settings-projects")
    defer { try? FileManager.default.removeItem(at: home) }
    let homePath = try settingsPath(home)
    var roots: [String] = []
    for path in ["Downloads/demo", "code/scratch"] {
        let removedFolder = try folder(path, in: home)
        let project = try #require(settings.addProject(path: removedFolder.path))
        settings.removeProject(project)
        roots.append(project.root)
    }

    let removed = ProjectsSettingsContent.removedFolders(settings.removedProjectRoots, home: homePath)
    #expect(removed.map(\.path) == ["~/code/scratch", "~/Downloads/demo"])
    #expect(removed.map(\.root) == [roots[1], roots[0]])

    // Offer Again.
    settings.forgetRemovedProjectRoot(roots[1])
    #expect(ProjectsSettingsContent.removedFolders(settings.removedProjectRoots, home: homePath).map(\.path)
        == ["~/Downloads/demo"])
    #expect(settings.projects.isEmpty)
    #expect(AgentSettings(defaults: defaults).removedProjectRoots == [roots[0]])

    // Another Mac's folder is never listed here.
    #expect(ProjectsSettingsContent.removedFolders(["device:\(UUID().uuidString):/Users/me/old"], home: homePath).isEmpty)
}

@Test @MainActor func addProjectAddsTheFolderAndOpensItsWindow() throws {
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjects"))
    let base = try canonicalTemporaryDirectory("cherry-settings-add")
    defer { try? FileManager.default.removeItem(at: base) }
    let basePath = try settingsPath(base)
    let opened = Recorder<[String]>([])
    let actions = SettingsActions(openProjectWindow: { opened.value.append($0) })

    let project = try #require(ProjectsSettingsContent.add(folder: base, to: settings, actions: actions))
    #expect(project.root == basePath)
    #expect(settings.projects.map(\.root) == [basePath])
    #expect(opened.value == [basePath])

    // A folder removed earlier is offered again.
    settings.removeProject(project)
    #expect(settings.removedProjectRoots == [basePath])
    #expect(ProjectsSettingsContent.add(folder: base, to: settings, actions: actions) != nil)
    #expect(settings.removedProjectRoots.isEmpty)
    #expect(opened.value == [basePath, basePath])

    // A folder that is gone: nothing is added, nothing opens.
    #expect(ProjectsSettingsContent.add(folder: base.appendingPathComponent("gone"), to: settings, actions: actions) == nil)
    #expect(settings.projects.map(\.root) == [basePath])
    #expect(opened.value.count == 2)
}

@Test @MainActor func searchFindsAProjectByNameAndByItsPathFromHome() throws {
    let home = try canonicalTemporaryDirectory("cherry-settings-search")
    defer { try? FileManager.default.removeItem(at: home) }
    let homePath = try settingsPath(home)
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjects"))
    let cherry = try folder("code/cherry", in: home)
    let project = try #require(settings.addProject(path: cherry.path))
    let context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: privateDefaults("SettingsWindowProjects")),
        agents: settings,
        defaults: privateDefaults("SettingsWindowProjects"),
        homeDirectory: homePath
    )
    let rows = SettingsSearchIndex.rows(in: context)
    func projectPages(_ query: String) -> [SettingsSearchRow] {
        SettingsSearchIndex.groups(for: query, in: rows).first { $0.kind == .projects }?.results.map(\.row) ?? []
    }

    for query in ["cherry", "~/code/cherry", project.root] {
        let first = try #require(projectPages(query).first, "\(query)")
        #expect(first.route == .project(project.root))
        #expect(first.opensPage)
        #expect(first.value == "~/code/cherry")
    }
    #expect(projectPages("~/code/elsewhere").isEmpty)
}

@Test @MainActor func searchFindsTheDefaultEditorByItsEditorsAndRemovedFoldersByTheirPaths() throws {
    let home = try canonicalTemporaryDirectory("cherry-settings-search")
    defer { try? FileManager.default.removeItem(at: home) }
    let homePath = try settingsPath(home)
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjects"))
    var context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: privateDefaults("SettingsWindowProjects")),
        agents: settings,
        editors: [try installedEditor("zed"), try installedEditor("sublime-text")],
        defaults: privateDefaults("SettingsWindowProjects"),
        homeDirectory: homePath
    )
    func projectsPage(_ query: String) -> [SettingsRowID] {
        SettingsSearchIndex.groups(for: query, in: SettingsSearchIndex.rows(in: context))
            .first { $0.kind == .page(.projects) }?.results.map(\.row.id) ?? []
    }

    let editorRow = try #require(ProjectsSettingsPage.searchRows(in: context).first { $0.id == .projectsDefaultEditor })
    #expect(editorRow.section == "Every project")
    #expect(editorRow.value == "Automatic (Zed)")
    #expect(projectsPage("sublime") == [.projectsDefaultEditor])
    context.editors = []
    #expect(projectsPage("sublime").isEmpty)

    // Removed folders is there only while it lists a folder.
    #expect(projectsPage("offer again").isEmpty)
    let scratchFolder = try folder("code/scratch", in: home)
    let scratch = try #require(settings.addProject(path: scratchFolder.path))
    settings.removeProject(scratch)
    #expect(projectsPage("offer again") == [.projectsRemovedFolders])
    #expect(projectsPage("~/code/scratch") == [.projectsRemovedFolders])
    #expect(projectsPage(scratch.root) == [.projectsRemovedFolders])
}

@Test @MainActor func theProjectsSearchRowsCountThisMacsProjectsAndTheRemovedFolders() throws {
    let home = try canonicalTemporaryDirectory("cherry-settings-search")
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = AgentSettings(defaults: privateDefaults("SettingsWindowProjects"))
    let context = SettingsSearchContext(
        terminal: TerminalSettings(defaults: privateDefaults("SettingsWindowProjects")),
        agents: settings,
        defaults: privateDefaults("SettingsWindowProjects"),
        homeDirectory: try settingsPath(home)
    )
    func value(_ id: SettingsRowID) -> String?? {
        ProjectsSettingsPage.searchRows(in: context).first { $0.id == id }.map(\.value)
    }

    #expect(value(.projectsList) == "0 projects")
    #expect(value(.projectsRemovedFolders) == nil)

    let cherry = try #require(settings.addProject(path: try folder("code/cherry", in: home).path))
    _ = try #require(settings.addProject(path: "device:\(UUID().uuidString):/Users/me/code/remote"))
    #expect(value(.projectsList) == "1 project")

    for path in ["code/scratch", "Downloads/demo"] {
        let project = try #require(settings.addProject(path: try folder(path, in: home).path))
        settings.removeProject(project)
    }
    #expect(value(.projectsList) == "1 project")
    #expect(value(.projectsRemovedFolders) == "2 folders")
    settings.removeProject(cherry)
    #expect(value(.projectsList) == "0 projects")
    #expect(value(.projectsRemovedFolders) == "3 folders")
}
