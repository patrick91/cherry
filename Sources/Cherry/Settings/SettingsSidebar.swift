import AppKit
import Combine
import SwiftUI

// MARK: - Items

/// A row of the sidebar: a page, an agent's page or a project's page, with
/// its tile.
struct SettingsSidebarItem: Identifiable, Equatable, Sendable {
    var route: SettingsRoute
    var title: String
    var tile: SettingsTileStyle
    /// A disabled agent: its tile dimmed and "Off" after its name.
    var isOff = false

    var id: SettingsRoute { route }
}

/// What the sidebar lists, apart from the status item: the pages of one
/// group, the agents in their stored order (the Agents menu's), and This
/// Mac's projects by name.
enum SettingsSidebarItems {
    /// The opacity of a disabled agent's tile.
    static let offOpacity = 0.55

    static func pages(inGroup group: Int) -> [SettingsSidebarItem] {
        SettingsPage.allCases.filter { $0.sidebarGroup == group }.map { page in
            SettingsSidebarItem(route: .page(page), title: page.title, tile: page.tile)
        }
    }

    /// Each agent's letters on its gray tile; "Off" for a disabled one.
    static func agents(_ agents: [AgentToolDefinition]) -> [SettingsSidebarItem] {
        agents.map { agent in
            SettingsSidebarItem(
                route: .agent(agent.id),
                title: agent.name,
                tile: .agent(letters: letters(for: agent)),
                isOff: !agent.enabled
            )
        }
    }

    /// A folder tile in each project's color (gray without one); projects
    /// on other Macs are left out (`SettingsProjectOrdering.listed`).
    static func projects(
        _ projects: [CherryProject],
        color: (String) -> ProjectIdentityColor?
    ) -> [SettingsSidebarItem] {
        SettingsProjectOrdering.listed(projects).map { project in
            SettingsSidebarItem(
                route: .project(project.root),
                title: project.name,
                tile: .project(color: color(project.root))
            )
        }
    }

    /// The letters on an agent's tile: its CLI's ("Cl", "Cx"), or the first
    /// two letters of a custom agent's name.
    static func letters(for agent: AgentToolDefinition) -> String {
        if let brand = AgentToolBrand.detect(name: agent.name, commandLine: agent.commandLine) {
            return brand.fallbackLabel
        }
        let letters = agent.name.filter { $0.isLetter || $0.isNumber }.prefix(2)
        return letters.prefix(1).uppercased() + letters.dropFirst()
    }
}

// MARK: - Status item

/// The sidebar's status item, which is the Sessions page: the local
/// session host's state as `cherry status` last reported it
/// (`SessionHostDiagnostics`), which never starts a host.
enum SettingsStatusItem {
    struct Summary: Equatable, Sendable {
        /// The whole state, for VoiceOver and the row's tooltip.
        var text: String
        /// What the row shows after its title, beside the dot.
        var label: String
        var tone: SettingsStatusDot.Tone
    }

    /// "Host running · 3 sessions" (green), "Host not running" (gray),
    /// "Checking…" (gray, no status yet), "Restarting…" (yellow),
    /// "Sessions unavailable" (orange: local sessions cannot run, or the
    /// status could not be read), "Restart failed" (red); each with its
    /// short label ("3 sessions", "Not running", "Unavailable").
    static func summary(
        status: SessionHostStatus?,
        problem: String?,
        isRestarting: Bool,
        restartFailure: String?,
        unavailableReason: String?
    ) -> Summary {
        if isRestarting { return Summary(text: "Restarting…", label: "Restarting…", tone: .yellow) }
        if restartFailure != nil { return Summary(text: "Restart failed", label: "Restart failed", tone: .red) }
        if unavailableReason != nil || problem != nil {
            return Summary(text: "Sessions unavailable", label: "Unavailable", tone: .orange)
        }
        guard let status else { return Summary(text: "Checking…", label: "Checking…", tone: .gray) }
        guard status.running else { return Summary(text: "Host not running", label: "Not running", tone: .gray) }
        guard let sessions = status.sessions else { return Summary(text: "Host running", label: "Running", tone: .green) }
        let count = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return Summary(text: "Host running · \(count)", label: count, tone: .green)
    }
}

/// Keeps the status item current: `cherry status` (never a host start)
/// when the window opens or comes to the front, at most every few seconds.
@MainActor
final class SettingsHostStatusRefresh {
    static let minimumInterval: Duration = .seconds(5)
    /// The app's: the window's status item.
    static let shared = SettingsHostStatusRefresh()

    private let now: () -> ContinuousClock.Instant
    private var lastRefresh: ContinuousClock.Instant?

    /// `now`: tests pass their own clock.
    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    static func refresh(_ diagnostics: SessionHostDiagnostics = .shared) {
        shared.refresh(diagnostics)
    }

    /// Reads `diagnostics`' status again (`cherry status --json`), unless
    /// it did less than `minimumInterval` ago.
    @discardableResult
    func refresh(_ diagnostics: SessionHostDiagnostics) -> Task<Void, Never>? {
        let now = now()
        if let lastRefresh, now - lastRefresh < Self.minimumInterval { return nil }
        lastRefresh = now
        return Task { await diagnostics.refresh() }
    }
}

// MARK: - Sidebar

/// The Settings window's sidebar: the search field, then
/// either the pages (the status item, the four groups, and the Agents and
/// Projects sections, which collapse and remember it for each viewer) or,
/// while the field has text, the results by page. A selected row opens
/// its page (`SettingsNavigator.open`).
struct SettingsSidebar: View {
    @ObservedObject var navigator: SettingsNavigator
    @ObservedObject var search: SettingsSearchModel
    @ObservedObject var agentSettings: AgentSettings
    /// Fires when what the results' rows read changes
    /// (`SettingsSearchContext.liveChanges`).
    let rowsChanged: AnyPublisher<Void, Never>

    @AppStorage("settings.sidebar.agentsExpanded") private var agentsExpanded = true
    @AppStorage("settings.sidebar.projectsExpanded") private var projectsExpanded = true
    /// The page list starts with keyboard focus, as System Settings' does, so
    /// its selection draws in the accent color and the arrow keys move it.
    @FocusState private var pageListHasFocus: Bool

    init(
        navigator: SettingsNavigator,
        agentSettings: AgentSettings,
        rowsChanged: AnyPublisher<Void, Never>
    ) {
        self.navigator = navigator
        search = navigator.search
        self.agentSettings = agentSettings
        self.rowsChanged = rowsChanged
    }

    private var agentItems: [SettingsSidebarItem] {
        SettingsSidebarItems.agents(agentSettings.agents)
    }

    private var projectItems: [SettingsSidebarItem] {
        SettingsSidebarItems.projects(agentSettings.projects) { agentSettings.projectAppearance(for: $0).color }
    }

    var body: some View {
        Group {
            if search.isSearching {
                let tiles = resultTiles()
                SettingsSearchResultsList(search: search) { route in
                    tiles[route] ?? Self.fallbackTile(for: route)
                }
            } else {
                pageList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingsSidebarSearchField(text: $search.text, focusRequest: search.focusRequest) { command in
                search.handle(command)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        // What the results read changed: they follow, once per turn.
        .onReceive(rowsChanged) { _ in search.scheduleRowsRefresh() }
    }

    private var pageList: some View {
        List(selection: routeSelection) {
            Section {
                SettingsStatusItemRow(diagnostics: .shared, sessionsStatus: .shared)
                    .tag(SettingsRoute.page(.sessions))
            }
            ForEach(1...4, id: \.self) { group in
                Section {
                    ForEach(SettingsSidebarItems.pages(inGroup: group)) { item in
                        SettingsSidebarRow(item: item)
                            .tag(item.route)
                    }
                }
            }
            let agents = agentItems
            if !agents.isEmpty {
                Section(isExpanded: $agentsExpanded) {
                    ForEach(agents) { item in
                        SettingsSidebarRow(item: item)
                            .tag(item.route)
                    }
                } header: {
                    Text("Agents")
                }
            }
            let projects = projectItems
            if !projects.isEmpty {
                Section(isExpanded: $projectsExpanded) {
                    ForEach(projects) { item in
                        SettingsSidebarRow(item: item)
                            .tag(item.route)
                    }
                } header: {
                    Text("Projects")
                }
            }
        }
        .listStyle(.sidebar)
        .focused($pageListHasFocus)
        .task { pageListHasFocus = true }
    }

    /// The list's selection is the page shown; selecting a row opens its
    /// page (an action: the list sets it from a click or an arrow key).
    private var routeSelection: Binding<SettingsRoute?> {
        Binding(
            get: { navigator.route },
            set: { route in
                if let route { navigator.open(route) }
            }
        )
    }

    /// The results' tiles, by page: the agents' and the projects' as the
    /// sidebar shows them, read once for all the results.
    private func resultTiles() -> [SettingsRoute: SettingsTileStyle] {
        var tiles: [SettingsRoute: SettingsTileStyle] = [:]
        for item in agentItems + projectItems {
            tiles[item.route] = item.tile
        }
        return tiles
    }

    private static func fallbackTile(for route: SettingsRoute) -> SettingsTileStyle {
        switch route {
        case .page(let page):
            page.tile
        case .agent:
            SettingsTileStyle(.symbol("sparkles"), background: SettingsDesign.TileColors.agent)
        case .project:
            .project(color: nil)
        }
    }
}

/// A page's, an agent's or a project's row.
private struct SettingsSidebarRow: View {
    let item: SettingsSidebarItem

    var body: some View {
        HStack(spacing: 8) {
            SettingsTile(item.tile)
                .opacity(item.isOff ? SettingsSidebarItems.offOpacity : 1)
            Text(item.title)
                .lineLimit(1)
            if item.isOff {
                Spacer(minLength: 4)
                Text("Off")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isOff ? "\(item.title), off" : item.title)
    }
}

/// The status item: a row like the others (the cherry tile and "Sessions"),
/// with the host's state after it: its dot and a short label.
private struct SettingsStatusItemRow: View {
    @ObservedObject var diagnostics: SessionHostDiagnostics
    @ObservedObject var sessionsStatus: PersistentSessionsStatus

    var body: some View {
        let summary = SettingsStatusItem.summary(
            status: diagnostics.status,
            problem: diagnostics.problem,
            isRestarting: diagnostics.isRestarting,
            restartFailure: diagnostics.restartFailure,
            unavailableReason: sessionsStatus.localSessionsUnavailableReason
        )
        HStack(spacing: 8) {
            SettingsTile(.cherry)
            Text(SettingsPage.sessions.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                SettingsStatusDot(summary.tone)
                Text(summary.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(summary.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SettingsPage.sessions.title), \(summary.text)")
        .onAppear {
            SettingsHostStatusRefresh.refresh(diagnostics)
        }
    }
}

// MARK: - Results

/// The results while the field has text: a group
/// for each page, each result with its tile, its title and its second
/// line, the matched letters bold; then the keys' hint. "No results" when
/// nothing matches. The selected result is the one Return opens; a click
/// opens one too.
private struct SettingsSearchResultsList: View {
    @ObservedObject var search: SettingsSearchModel
    let tile: (SettingsRoute) -> SettingsTileStyle

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: resultSelection) {
                if search.groups.isEmpty {
                    Text("No results")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(search.groups) { group in
                        Section(group.title) {
                            ForEach(group.results) { result in
                                SettingsSearchResultRow(result: result, tile: tile(result.row.route))
                                    .tag(result.id)
                            }
                        }
                    }
                    Text("↑ ↓ move · Return opens · Escape clears")
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                        .padding(.top, 6)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: search.selection) { _, selection in
                if let selection {
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    private var resultSelection: Binding<SettingsRowID?> {
        Binding(
            get: { search.selection },
            set: { id in
                if let id { search.open(id) }
            }
        )
    }
}

private struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult
    let tile: SettingsTileStyle

    var body: some View {
        HStack(spacing: 8) {
            SettingsTile(tile)
            VStack(alignment: .leading, spacing: 1) {
                Text(SettingsSearchEmphasis.text(result.row.title, bolding: result.titleIndices))
                    .lineLimit(1)
                let detail = result.row.detail
                if !detail.isEmpty {
                    Text(SettingsSearchEmphasis.text(detail, bolding: result.detailIndices))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// A result's text with its matched letters bold.
enum SettingsSearchEmphasis {
    /// `text` with the characters at `indices` (offsets) strongly
    /// emphasized, which SwiftUI draws bold.
    static func text(_ text: String, bolding indices: [Int]) -> AttributedString {
        var attributed = AttributedString()
        let bold = Set(indices)
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if bold.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            attributed.append(piece)
        }
        return attributed
    }
}
