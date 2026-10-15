import AppKit
import Combine
import SwiftUI

// MARK: - Rows

/// A row search can find: where it is (its page's route, its
/// section), what it says, and the value it shows now. Pages list theirs
/// (`SettingsPageContent.searchRows`); the index adds one for each page.
struct SettingsSearchRow: Identifiable, Equatable, Sendable {
    var id: SettingsRowID
    var route: SettingsRoute
    /// Its section's title on the page: "Keyboard". Empty for a row with
    /// none.
    var section: String
    /// "Option key".
    var title: String
    var help: String? = nil
    /// Words search finds it by that its title, help and value lack.
    var keywords: [String] = []
    /// What the row shows now: "16 pt", "Afterglow", "Ask", "set by your
    /// Ghostty config".
    var value: String? = nil
    /// A page's own result (`SettingsSearchIndex` adds them): opening it
    /// shows the page from its top, tinting no row.
    var opensPage = false

    /// A result's second line: "Section · value", or either alone.
    var detail: String {
        [section, value ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What a page's rows read to say their values: published model state and
/// accessors that are already cached (cherry.toml's parse, which a stat
/// checks, as the pages' bodies read it). Never other I/O, a process, a
/// socket or a fresh Ghostty reading: the rows are read when a search
/// starts and again when `liveChanges` fires. Tests
/// build one by hand with private defaults; only the app uses `live()`.
@MainActor
struct SettingsSearchContext {
    var terminal: TerminalSettings
    var agents: AgentSettings
    /// The user's other Macs (`RemoteDeviceStore`).
    var devices: [RemoteDevice]
    /// The saved SSH hosts (`HostedSessionHostStore`).
    var sshHosts: [HostedSessionHost]
    /// The editors found when they were last looked for.
    var editors: [InstalledEditor]
    /// What Cherry read of the user's Ghostty config at launch; nil in
    /// tests.
    var ghostty: UserGhosttyKeyboardConfig?
    var updates: AppUpdateStatus
    var backgroundSessions: BackgroundSessionsSummary
    /// Where stored values no model publishes are (Wake idle agents).
    var defaults: UserDefaults
    var launchArguments: [String: Any]
    /// For paths shown with "~".
    var homeDirectory: String

    init(
        terminal: TerminalSettings,
        agents: AgentSettings,
        devices: [RemoteDevice] = [],
        sshHosts: [HostedSessionHost] = [],
        editors: [InstalledEditor] = [],
        ghostty: UserGhosttyKeyboardConfig? = nil,
        updates: AppUpdateStatus = AppUpdateStatus(enablement: .disabled(.notAnApp)),
        backgroundSessions: BackgroundSessionsSummary = BackgroundSessionsSummary(),
        defaults: UserDefaults,
        launchArguments: [String: Any] = [:],
        homeDirectory: String = "/Users/someone"
    ) {
        self.terminal = terminal
        self.agents = agents
        self.devices = devices
        self.sshHosts = sshHosts
        self.editors = editors
        self.ghostty = ghostty
        self.updates = updates
        self.backgroundSessions = backgroundSessions
        self.defaults = defaults
        self.launchArguments = launchArguments
        self.homeDirectory = homeDirectory
    }

    /// The app's state, as it is now. Only the app's Settings window reads
    /// it; tests never do.
    static func live() -> SettingsSearchContext {
        SettingsSearchContext(
            terminal: .shared,
            agents: .shared,
            devices: RemoteDeviceStore.shared.devices,
            sshHosts: HostedSessionHostStore.shared.hosts,
            editors: ExternalEditorDiscovery.shared.installedEditors,
            ghostty: TerminalSettings.nativeUserKeyboardConfigReading,
            updates: AppUpdater.shared.status,
            backgroundSessions: BackgroundSessionsModel.shared.summary,
            defaults: .standard,
            launchArguments: SettingSource.launchArguments(for: .standard),
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Fires when something `live()` reads changes, so a search reads its
    /// rows again (`SettingsSearchModel.scheduleRowsRefresh`): the pages a
    /// result opens change these too. Each is an `objectWillChange`, which
    /// sends nothing when subscribed to. A value only UserDefaults keeps
    /// (Wake idle agents) refreshes the rows from its own row.
    static let liveChanges: AnyPublisher<Void, Never> = Publishers.MergeMany(
        TerminalSettings.shared.objectWillChange,
        AgentSettings.shared.objectWillChange,
        RemoteDeviceStore.shared.objectWillChange,
        HostedSessionHostStore.shared.objectWillChange,
        ExternalEditorDiscovery.shared.objectWillChange,
        AppUpdater.shared.status.objectWillChange,
        BackgroundSessionsModel.shared.summary.objectWillChange
    )
    .eraseToAnyPublisher()

    /// `path` with the home folder as "~".
    func displayPath(_ path: String) -> String {
        ProjectSwitcherModel.displayPath(path, home: homeDirectory)
    }
}

/// A Settings page: a view in `Pages/` whose body is a `SettingsPageScroll`,
/// and the rows search finds on it.
@MainActor
protocol SettingsPageContent: View {
    /// The rows search finds on this page. Cheap: cached model state only
    /// (`SettingsSearchContext`), never other I/O or a process.
    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow]
}

// MARK: - Results

/// A row a query matched: the letters to bold in its title or in its
/// second line, and how well it matched.
struct SettingsSearchResult: Identifiable, Equatable, Sendable {
    var row: SettingsSearchRow
    /// The title's matched characters (offsets), bold in the result.
    var titleIndices: [Int] = []
    /// The second line's matched characters, when the title had none.
    var detailIndices: [Int] = []
    var score: Double

    var id: SettingsRowID { row.id }
}

/// The results under one page's name; agents' pages under "Agents" and
/// projects' under "Projects", after the pages.
struct SettingsSearchGroup: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case page(SettingsPage)
        case agents
        case projects

        init(_ route: SettingsRoute) {
            switch route {
            case .page(let page): self = .page(page)
            case .agent: self = .agents
            case .project: self = .projects
            }
        }

        /// The sidebar's order.
        static let ordered: [Kind] = SettingsPage.allCases.map(Kind.page) + [.agents, .projects]

        var title: String {
            switch self {
            case .page(let page): page.title
            case .agents: "Agents"
            case .projects: "Projects"
            }
        }
    }

    var kind: Kind
    var results: [SettingsSearchResult]

    var id: Kind { kind }
    var title: String { kind.title }
}

// MARK: - Index

/// Every row search can find, and how a query matches them:
/// the Omni bar's rule (`OmniMatcher`: one run of the text, or runs that
/// each start a word; case and accents ignored), on the title first, then
/// the second line ("Section · value"), then help, extra words and the
/// page's title. A row matches once, at its best place.
enum SettingsSearchIndex {
    /// How a match ranks by where it is: the title over the second line
    /// over the rest. `OmniMatcher` scores stay under 100.
    static let titleScore = 200.0
    static let detailScore = 100.0

    /// One row for each page, each agent and each of This Mac's projects
    /// (a project's with its path, "~/code/cherry"), then every page's
    /// rows, in the sidebar's order.
    @MainActor
    static func rows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let pages = SettingsPage.allCases.map { page in
            SettingsSearchRow(
                id: pageRowID(.page(page)),
                route: .page(page),
                section: "",
                title: page.title,
                keywords: page.keywords,
                opensPage: true
            )
        }
        let agents = context.agents.agents.map { agent in
            SettingsSearchRow(
                id: pageRowID(.agent(agent.id)),
                route: .agent(agent.id),
                section: "",
                title: agent.name,
                keywords: [AgentToolBrand.detect(name: agent.name, commandLine: agent.commandLine)?.productName]
                    .compactMap { $0 },
                opensPage: true
            )
        }
        let projects = SettingsProjectOrdering.listed(context.agents.projects).map { project in
            let path = context.displayPath(project.root)
            return SettingsSearchRow(
                id: pageRowID(.project(project.root)),
                route: .project(project.root),
                section: "",
                title: project.name,
                // A path pasted as it is finds it too.
                keywords: path == project.root ? [] : [project.root],
                value: path,
                opensPage: true
            )
        }
        return pages + agents + projects + pageTypeRows(in: context)
    }

    /// The pages' own rows: the status item's page, the four groups, then
    /// the agents' and the projects' pages.
    @MainActor
    private static func pageTypeRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        SessionsSettingsPage.searchRows(in: context)
            + InterfaceSettingsPage.searchRows(in: context)
            + ThemesSettingsPage.searchRows(in: context)
            + TerminalSettingsPage.searchRows(in: context)
            + ShortcutsSettingsPage.searchRows(in: context)
            + NotificationsSettingsPage.searchRows(in: context)
            + MacsSettingsPage.searchRows(in: context)
            + AgentsSettingsPage.searchRows(in: context)
            + ProjectsSettingsPage.searchRows(in: context)
            + UpdatesSettingsPage.searchRows(in: context)
            + AgentSettingsPage.searchRows(in: context)
            + ProjectSettingsPage.searchRows(in: context)
    }

    /// The id of a page's own result: "page:terminal", "page:agent.claude".
    private static func pageRowID(_ route: SettingsRoute) -> SettingsRowID {
        switch route {
        case .page(let page): SettingsRowID(rawValue: "page:\(page.rawValue)")
        case .agent(let id): SettingsRowID(rawValue: "page:agent.\(id)")
        case .project(let root): SettingsRowID(rawValue: "page:project.\(root)")
        }
    }

    /// `rows` that match `query`, by page in the sidebar's order (agents'
    /// and projects' pages last). In a group a page's own result comes
    /// first, then the best matches, then the rows' order. Empty for an
    /// empty query or no match.
    static func groups(for query: String, in rows: [SettingsSearchRow]) -> [SettingsSearchGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var pageTitles: [SettingsRoute: String] = [:]
        for row in rows where row.opensPage {
            pageTitles[row.route] = row.title
        }
        var seen = Set<SettingsRowID>()
        var matches: [SettingsSearchGroup.Kind: [(order: Int, result: SettingsSearchResult)]] = [:]
        for (order, row) in rows.enumerated() where seen.insert(row.id).inserted {
            let pageTitle = row.opensPage ? nil : pageTitles[row.route] ?? fallbackTitle(of: row.route)
            guard let result = match(query, row: row, pageTitle: pageTitle) else { continue }
            matches[SettingsSearchGroup.Kind(row.route), default: []].append((order, result))
        }

        return SettingsSearchGroup.Kind.ordered.compactMap { kind in
            guard let entries = matches[kind], !entries.isEmpty else { return nil }
            let results = entries.sorted { left, right in
                if left.result.row.opensPage != right.result.row.opensPage { return left.result.row.opensPage }
                if left.result.score != right.result.score { return left.result.score > right.result.score }
                return left.order < right.order
            }
            return SettingsSearchGroup(kind: kind, results: results.map(\.result))
        }
    }

    /// How `query` matches `row`, at its best place: its title, else its
    /// second line, else its help, extra words or page's title (`pageTitle`,
    /// nil for a page's own row), which bold nothing.
    static func match(_ query: String, row: SettingsSearchRow, pageTitle: String?) -> SettingsSearchResult? {
        if let match = OmniMatcher.match(query, in: row.title) {
            return SettingsSearchResult(row: row, titleIndices: match.indices, score: titleScore + match.score)
        }
        let detail = row.detail
        if !detail.isEmpty, let match = OmniMatcher.match(query, in: detail) {
            return SettingsSearchResult(row: row, detailIndices: match.indices, score: detailScore + match.score)
        }
        let others = [row.help].compactMap { $0 } + row.keywords + [pageTitle].compactMap { $0 }
        let best = others.compactMap { OmniMatcher.match(query, in: $0)?.score }.max()
        return best.map { SettingsSearchResult(row: row, score: $0) }
    }

    /// The title of a page no row names (its row missing from a test's list).
    private static func fallbackTitle(of route: SettingsRoute) -> String {
        switch route {
        case .page(let page): page.title
        case .agent(let id): id
        case .project(let root): URL(fileURLWithPath: root, isDirectory: true).lastPathComponent
        }
    }
}

// MARK: - Search model

/// The sidebar's search: its text, the results by page and the one
/// selected. The rows come from `rows` once per search, when the text
/// stops being empty, and again when the settings they read change
/// (`scheduleRowsRefresh`); each keystroke only matches against them. The
/// first result is selected; ↑ and ↓ move, Return opens the selected one
/// (the results stay, so the next is one ↓ away), Escape clears the text
/// and the pages come back.
@MainActor
final class SettingsSearchModel: ObservableObject {
    @Published var text = "" {
        didSet {
            if text != oldValue { textDidChange() }
        }
    }
    @Published private(set) var groups: [SettingsSearchGroup] = []
    @Published private(set) var selection: SettingsRowID?
    /// Bumped by ⌘F: the field takes the keyboard (`SettingsSidebarSearchField`).
    @Published private(set) var focusRequest = 0

    /// Opens a result's page and row; the navigator sets it.
    var opensResult: @MainActor (SettingsSearchRow) -> Void = { _ in }

    private let rowSource: @MainActor () -> [SettingsSearchRow]
    private var rows: [SettingsSearchRow]?
    private var refreshIsScheduled = false

    init(rows: @escaping @MainActor () -> [SettingsSearchRow]) {
        rowSource = rows
    }

    var query: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the sidebar shows results instead of pages.
    var isSearching: Bool {
        !query.isEmpty
    }

    /// Whether a search found nothing: the sidebar says "No results", the
    /// detail "No settings match “q”".
    var hasNoResults: Bool {
        isSearching && groups.isEmpty
    }

    var results: [SettingsSearchResult] {
        groups.flatMap(\.results)
    }

    var selectedResult: SettingsSearchResult? {
        guard let selection else { return nil }
        return results.first { $0.id == selection }
    }

    /// The search field's key commands (`SettingsSidebarSearchField`); true
    /// when one was handled.
    func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)):
            guard isSearching else { return false }
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard isSearching else { return false }
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard isSearching else { return false }
            openSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !text.isEmpty else { return false }
            text = ""
            return true
        default:
            return false
        }
    }

    /// Selects a result and opens it (a click).
    func open(_ id: SettingsRowID) {
        guard results.contains(where: { $0.id == id }) else { return }
        if selection != id { selection = id }
        openSelection()
    }

    func openSelection() {
        guard let result = selectedResult else { return }
        opensResult(result.row)
    }

    /// Focuses the search field (⌘F).
    func requestFocus() {
        focusRequest += 1
    }

    /// The settings the rows read changed: while searching, reads the rows
    /// again on the next turn, once however many changed. The selection
    /// stays where it can.
    func scheduleRowsRefresh() {
        guard isSearching, !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshRows()
            }
        }
    }

    /// Reads the rows again now, while searching.
    func refreshRows() {
        refreshIsScheduled = false
        guard isSearching else { return }
        let rows = rowSource()
        self.rows = rows
        update(keepingSelection: true, rows: rows)
    }

    private func textDidChange() {
        guard isSearching else {
            rows = nil
            if !groups.isEmpty { groups = [] }
            if selection != nil { selection = nil }
            return
        }
        let rows = rows ?? rowSource()
        self.rows = rows
        update(keepingSelection: false, rows: rows)
    }

    private func update(keepingSelection: Bool, rows: [SettingsSearchRow]) {
        let groups = SettingsSearchIndex.groups(for: query, in: rows)
        if self.groups != groups { self.groups = groups }
        let ids = groups.flatMap { $0.results.map(\.id) }
        let kept = keepingSelection ? selection.flatMap { ids.contains($0) ? $0 : nil } : nil
        let selection = kept ?? ids.first
        if self.selection != selection { self.selection = selection }
    }

    private func moveSelection(by offset: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        let next = ids[min(max(index + offset, 0), ids.count - 1)]
        if selection != next { selection = next }
    }
}
