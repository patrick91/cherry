import AppKit
import CherryControl
import SwiftUI

/// Settings › Projects: what every project shares (Default
/// editor), This Mac's projects, each with a page of its own, and the
/// folders removed from them. A project on another Mac is on its Mac's
/// card (Settings › Macs).
struct ProjectsSettingsPage: View, SettingsPageContent {
    static let projectsIntro = "Each project can share commands, features and a color through its cherry.toml."
    static let removedFoldersNote = "The Omni bar doesn't offer these as “Not added yet”."

    @ObservedObject private var settings: AgentSettings
    @ObservedObject private var terminal: TerminalSettings
    @ObservedObject private var editorDiscovery: ExternalEditorDiscovery
    private let navigator: SettingsNavigator
    private let homeDirectory: String

    @Environment(\.settingsActions) private var actions
    @State private var showsRemovedFolders = false

    init(
        settings: AgentSettings = .shared,
        terminal: TerminalSettings = .shared,
        editorDiscovery: ExternalEditorDiscovery = .shared,
        navigator: SettingsNavigator = .shared,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.settings = settings
        self.terminal = terminal
        self.editorDiscovery = editorDiscovery
        self.navigator = navigator
        self.homeDirectory = homeDirectory
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.projects.title) {
            everyProjectSection
            projectsSection
            let removed = ProjectsSettingsContent.removedFolders(settings.removedProjectRoots, home: homeDirectory)
            if !removed.isEmpty {
                removedFoldersSection(removed)
            }
        }
        .task {
            // Launch Services: the editors installed now, never from a body.
            editorDiscovery.refresh()
        }
    }

    // MARK: Every project

    private var everyProjectSection: some View {
        let menu = DefaultEditorMenu(installed: editorDiscovery.installedEditors, storedID: terminal.defaultEditorID)
        let source = SettingsSourceState.terminal(.defaultEditorID, in: terminal)
        let title = TerminalSettings.Setting.defaultEditorID.title
        return SettingsSection("Every project") {
            SettingsItem(id: .projectsDefaultEditor, title, help: DefaultEditorMenu.help, source: source) {
                if menu.options.isEmpty {
                    Text(DefaultEditorMenu.noEditorsText)
                        .font(SettingsDesign.Fonts.value)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(title, selection: Binding(
                        get: { menu.selection },
                        set: { terminal.defaultEditorID = $0 }
                    )) {
                        ForEach(menu.options) { option in
                            Text(option.title)
                                .tag(option.id)
                        }
                    }
                    .settingsMenuPicker()
                    .disabled(!source.source.isEditable)
                }
            }
        }
    }

    // MARK: Projects

    private var projectsSection: some View {
        let rows = ProjectsSettingsContent.projectRows(settings.projects, home: homeDirectory) { root in
            settings.projectAppearance(for: root).color
        }
        return SettingsSection(
            "Projects",
            note: rows.isEmpty ? nil : "\(rows.count)",
            intro: Self.projectsIntro,
            caption: rows.isEmpty
                ? nil
                : "A click opens the project's page; Open brings its window forward. Remove… always asks.",
            id: .projectsList
        ) {
            SettingsLinkButton("+ Add Project…", action: chooseProject)
        } content: {
            if rows.isEmpty {
                SettingsEmptyState(
                    title: "No projects yet",
                    message: "Add a folder to give it commands, features and a color.",
                    systemImage: "folder.badge.plus"
                ) {
                    Button("Add Project…", action: chooseProject)
                        .settingsButton(.primary)
                }
            } else {
                ForEach(rows) { row in
                    projectItem(row)
                }
            }
        }
    }

    private func projectItem(_ row: ProjectsSettingsContent.ProjectRow) -> some View {
        SettingsListItem(opens: { navigator.open(.project(row.root)) }) {
            SettingsListLabel(
                row.name,
                subtitle: row.path,
                monospacedSubtitle: true,
                tile: SettingsTile(row.tile, size: .medium)
            )
        } trailing: {
            Button("Open") {
                actions.openProjectWindow(row.root)
            }
            .settingsButton(size: .small)

            SettingsMoreMenu("More actions for \(row.name)") {
                Button("Open Window") {
                    actions.openProjectWindow(row.root)
                }
                Button("Reveal in Finder") {
                    actions.revealInFinder([URL(fileURLWithPath: row.root, isDirectory: true)])
                }
                Divider()
                Button("Remove…", role: .destructive) {
                    ProjectRemoval.remove(CherryProject(root: row.root), settings: settings)
                }
            }
        }
    }

    /// Add Project…: a folder picker whose button says Add, then the
    /// project's window, as the Omni bar's Add Project… does.
    private func chooseProject() {
        guard let folder = NSOpenPanel.chooseFolder(prompt: "Add", canCreateDirectories: true) else { return }
        ProjectsSettingsContent.add(folder: folder, to: settings, actions: actions)
    }

    // MARK: Removed folders

    private func removedFoldersSection(_ folders: [ProjectsSettingsContent.RemovedFolder]) -> some View {
        SettingsSection(id: .projectsRemovedFolders) {
            SettingsDisclosureHeader("Removed folders (\(folders.count))", isExpanded: $showsRemovedFolders)
            if showsRemovedFolders {
                SettingsSubItem {
                    Text(Self.removedFoldersNote)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                }
                .settingsSeparatorAbove(false)

                ForEach(folders) { folder in
                    SettingsListItem {
                        Text(folder.path)
                            .font(SettingsDesign.Fonts.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.root)
                    } trailing: {
                        Button("Offer Again") {
                            settings.forgetRemovedProjectRoot(folder.root)
                        }
                        .settingsButton(size: .small)
                    }
                }
            }
        }
        .expandsWhenFlashed(.projectsRemovedFolders, isExpanded: $showsRemovedFolders)
    }

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let agents = context.agents
        let editor = DefaultEditorMenu(installed: context.editors, storedID: context.terminal.defaultEditorID)
        let projectCount = SettingsProjectOrdering.listed(agents.projects).count
        var rows = [
            SettingsSearchRow(
                id: .projectsDefaultEditor,
                route: .page(.projects),
                section: "Every project",
                title: TerminalSettings.Setting.defaultEditorID.title,
                help: DefaultEditorMenu.help,
                keywords: ["editor", "open in", "ide", "zed", "vs code", "cursor", "xcode"]
                    + context.editors.map(\.displayName),
                value: editor.selectedTitle ?? context.terminal.valueText(.defaultEditorID)
            ),
            SettingsSearchRow(
                id: .projectsList,
                route: .page(.projects),
                section: "Projects",
                title: "Projects",
                help: projectsIntro,
                keywords: ["project", "folder", "cherry.toml"],
                value: projectCount == 1 ? "1 project" : "\(projectCount) projects"
            ),
        ]
        let removed = ProjectsSettingsContent.removedFolders(agents.removedProjectRoots, home: context.homeDirectory)
        if !removed.isEmpty {
            rows.append(SettingsSearchRow(
                id: .projectsRemovedFolders,
                route: .page(.projects),
                section: "",
                title: "Removed folders",
                help: removedFoldersNote,
                // Its folders, as it shows them and as a pasted path.
                keywords: ["removed", "offer again"]
                    + removed.flatMap { $0.path == $0.root ? [$0.root] : [$0.path, $0.root] },
                value: removed.count == 1 ? "1 folder" : "\(removed.count) folders"
            ))
        }
        return rows
    }
}

extension SettingsRowID {
    static let projectsDefaultEditor: Self = "projects.defaultEditor"
    static let projectsList: Self = "projects.list"
    static let projectsRemovedFolders: Self = "projects.removedFolders"
}

// MARK: - Content

/// What Settings › Projects lists, apart from its views: the rows, their
/// tiles and paths, and Add Project…'s effect.
@MainActor
enum ProjectsSettingsContent {
    /// A project of the Projects list: its row opens its page.
    struct ProjectRow: Identifiable, Equatable {
        var root: String
        var name: String
        /// Its folder with the home folder as "~": "~/code/cherry".
        var path: String
        var tile: SettingsTileStyle

        var id: String { root }
    }

    /// A folder removed from Projects, which Offer Again forgets.
    struct RemovedFolder: Identifiable, Equatable {
        var root: String
        /// "~/code/scratch".
        var path: String

        var id: String { root }
    }

    /// This Mac's projects by name (`SettingsProjectOrdering.listed`), each
    /// on a folder tile in its color (`color`, by root).
    static func projectRows(
        _ projects: [CherryProject],
        home: String,
        color: (String) -> ProjectIdentityColor?
    ) -> [ProjectRow] {
        SettingsProjectOrdering.listed(projects).map { project in
            ProjectRow(
                root: project.root,
                name: project.name,
                path: ProjectSwitcherModel.displayPath(project.root, home: home),
                tile: .project(color: color(project.root))
            )
        }
    }

    /// The folders removed from Projects (`AgentSettings.removedProjectRoots`),
    /// by path. Only This Mac's are ever recorded; another Mac's would be
    /// left out.
    static func removedFolders(_ roots: Set<String>, home: String) -> [RemovedFolder] {
        roots
            .filter { !ProjectLocation.isRemoteKey($0) }
            .map { RemovedFolder(root: $0, path: ProjectSwitcherModel.displayPath($0, home: home)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Adds the folder Add Project… picked (one removed earlier is offered
    /// again) and opens its window. Nil, and nothing opens, for a folder
    /// that is gone.
    @discardableResult
    static func add(folder: URL, to settings: AgentSettings, actions: SettingsActions) -> CherryProject? {
        guard let project = settings.addProject(path: folder.path) else { return nil }
        actions.openProjectWindow(project.root)
        return project
    }
}

/// Projects › Default editor's pop-up: "Automatic (Zed)",
/// named after the first installed editor (the one Open in … uses then),
/// then each installed editor. An editor chosen earlier and uninstalled
/// since stays chosen, as "Zed (not installed)", so the row shows what is
/// stored, with its Set here badge and ↺ back to Automatic, rather than a
/// blank pop-up; Open in … uses the first installed editor meanwhile.
/// With no editor installed there is no pop-up: "No editors found".
struct DefaultEditorMenu: Equatable {
    struct Option: Identifiable, Equatable {
        /// What `TerminalSettings.defaultEditorID` stores: "" for Automatic.
        var id: String
        var title: String
    }

    static let help = "Used by Open in … in the Omni bar (⌘P)."
    static let noEditorsText = "No editors found"

    /// Empty when no editor is installed.
    var options: [Option]
    /// The option shown.
    var selection: String

    init(installed: [InstalledEditor], storedID: String) {
        selection = storedID
        guard let first = installed.first else {
            options = []
            return
        }
        var options = [Option(id: "", title: "Automatic (\(first.displayName))")]
        options += installed.map { Option(id: $0.id, title: $0.displayName) }
        if !storedID.isEmpty, !installed.contains(where: { $0.id == storedID }) {
            options.append(Option(id: storedID, title: "\(Self.name(of: storedID)) (not installed)"))
        }
        self.options = options
    }

    /// The pop-up's text: "Automatic (Zed)", "Cursor (not installed)"; nil
    /// without a pop-up.
    var selectedTitle: String? {
        options.first { $0.id == selection }?.title
    }

    /// An editor's name by its id (the id itself for one Cherry no longer
    /// knows).
    static func name(of editorID: String) -> String {
        ExternalEditorCatalog.all.first { $0.id == editorID }?.displayName ?? editorID
    }
}
