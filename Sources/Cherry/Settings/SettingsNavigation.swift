import AppKit
import CherryControl
import SwiftUI

// MARK: - Pages and routes

/// The Settings window's pages, in the sidebar's order: Sessions (its
/// status item), then four groups ([Interface, Themes], [Terminal,
/// Shortcuts, Notifications], [Macs, Agents, Projects], [Updates]).
/// Each agent and each project has a page of its own besides
/// (`SettingsRoute`).
enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case sessions
    case interface
    case themes
    case terminal
    case shortcuts
    case notifications
    case macs
    case agents
    case projects
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .interface: "Interface"
        case .themes: "Themes"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .notifications: "Notifications"
        case .macs: "Macs"
        case .agents: "Agents"
        case .projects: "Projects"
        case .updates: "Updates"
        }
    }

    /// Its tile in the sidebar and in search results.
    var tile: SettingsTileStyle {
        typealias Colors = SettingsDesign.TileColors
        return switch self {
        case .sessions: .cherry
        case .interface: SettingsTileStyle(.symbol("sidebar.left"), background: Colors.interface)
        case .themes: SettingsTileStyle(.symbol("paintpalette.fill"), background: Colors.themes)
        case .terminal:
            SettingsTileStyle(.symbol("apple.terminal"), background: Colors.terminal, foreground: Colors.terminalGlyph)
        case .shortcuts: SettingsTileStyle(.symbol("command"), background: Colors.shortcuts)
        case .notifications: SettingsTileStyle(.symbol("bell.fill"), background: Colors.notifications)
        case .macs: SettingsTileStyle(.symbol("desktopcomputer"), background: Colors.macs)
        case .agents: SettingsTileStyle(.symbol("sparkles"), background: Colors.agents)
        case .projects: SettingsTileStyle(.symbol("folder.fill"), background: Colors.projects)
        case .updates: SettingsTileStyle(.symbol("arrow.down.circle"), background: Colors.updates)
        }
    }

    /// Where the sidebar lists it: 0 is the status item, then the groups
    /// 1 to 4, split by gaps.
    var sidebarGroup: Int {
        switch self {
        case .sessions: 0
        case .interface, .themes: 1
        case .terminal, .shortcuts, .notifications: 2
        case .macs, .agents, .projects: 3
        case .updates: 4
        }
    }

    /// Words a search finds the page by that its title lacks.
    var keywords: [String] {
        switch self {
        case .sessions: ["session host", "daemon", "persistent", "background"]
        case .interface: ["appearance", "dark mode", "light mode", "sidebar"]
        case .themes: ["theme", "colors", "color scheme", "palette", "ghostty"]
        case .terminal: ["keyboard", "ghostty", "scrollback", "font"]
        case .shortcuts: ["shortcut", "key binding", "keybind", "hotkey", "keys"]
        case .notifications: ["notify", "notification", "alert", "sound", "badge", "bell"]
        case .macs: ["mac", "device", "ssh", "remote", "host", "tailscale"]
        case .agents: ["agent", "mcp", "claude", "codex", "pi", "gemini", "opencode", "amp"]
        case .projects: ["project", "folder", "cherry.toml"]
        case .updates: ["version", "build", "release", "upgrade", "restart", "prerelease", "pre-release", "beta", "sparkle"]
        }
    }
}

/// What the Settings window shows: a page, an agent's page (its
/// `AgentToolDefinition.id`, the normalized name, so a rename changes it:
/// `SettingsNavigator.renameAgent`) or a project's page (its
/// `CherryProject.root`).
enum SettingsRoute: Hashable, Sendable {
    case page(SettingsPage)
    case agent(String)
    case project(String)
}

/// The rows other pages link to, and "Edit Agents…" opens. Each page
/// defines its other row ids in its own file.
extension SettingsRowID {
    static let agentsList: Self = "agents.list"
    /// The cherry command's section (its id from when it was Cherry MCP's).
    static let agentsCherryCommand: Self = "agents.mcpServer"
    static let notificationsBackground: Self = "notifications.background"
    static let sessionsBackground: Self = "sessions.background"
    static let terminalKeyBindings: Self = "terminal.keyBindings"
    static let terminalGhosttyConfig: Self = "terminal.ghosttyConfig"
    static let shortcutsTerminalKeyBindings: Self = "shortcuts.terminalKeyBindings"
    static let macsList: Self = "macs.list"
}

/// The projects Settings lists, as the sidebar and Projects show them.
enum SettingsProjectOrdering {
    static func byName(_ projects: [CherryProject]) -> [CherryProject] {
        projects.sorted { left, right in
            let nameOrder = left.name.localizedStandardCompare(right.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return left.root.localizedStandardCompare(right.root) == .orderedAscending
        }
    }

    /// This Mac's projects, by name: a project on another Mac is on its
    /// Mac's card (Settings › Macs) and has no page here.
    static func listed(_ projects: [CherryProject]) -> [CherryProject] {
        byName(projects.filter { !ProjectLocation.isRemoteKey($0.root) })
    }
}

// MARK: - Navigator

/// Which page the Settings window shows, its back and forward history, and
/// the row a link or a search result opened. Every way into Settings goes
/// through `open(_:row:)` (then `openSettings()`, when it comes from outside
/// the window), so the route outlives the window: ⌘, opens the last page
/// (in memory only). The row highlight and the search are objects of their
/// own, so a keystroke in the search field re-renders neither the rows nor
/// the page, and a highlight not the sidebar. Its methods run from actions,
/// never from a view update.
@MainActor
final class SettingsNavigator: ObservableObject {
    /// The app's: its search reads the app's settings (`SettingsSearchContext.live()`).
    /// Tests make their own.
    static let shared = SettingsNavigator(searchRows: { SettingsSearchIndex.rows(in: .live()) })

    @Published private(set) var route: SettingsRoute
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The row a link or a result opened; rows observe only it.
    let highlight: SettingsRowHighlight
    /// The sidebar's search; the sidebar observes it.
    let search: SettingsSearchModel

    private var backStack: [SettingsRoute] = []
    private var forwardStack: [SettingsRoute] = []

    /// `searchRows` gives the search its rows, once per search
    /// (`SettingsSearchModel`).
    init(
        initial: SettingsRoute = .page(.interface),
        highlight: SettingsRowHighlight = SettingsRowHighlight(),
        searchRows: @escaping @MainActor () -> [SettingsSearchRow] = { [] }
    ) {
        route = initial
        self.highlight = highlight
        search = SettingsSearchModel(rows: searchRows)
        search.opensResult = { [weak self] row in
            // A page's own result shows the page from its top.
            self?.open(row.route, row: row.opensPage ? nil : row.id)
        }
    }

    /// The routes Back would go to, the latest last.
    var backHistory: [SettingsRoute] { backStack }
    /// The routes Forward would go to, the next one last.
    var forwardHistory: [SettingsRoute] { forwardStack }

    /// Shows `route`, and scrolls its page to `row` and tints it. A route
    /// other than the current one goes into the history and ends what
    /// Forward had; the same route again only flashes the row.
    func open(_ route: SettingsRoute, row: SettingsRowID? = nil) {
        if route != self.route {
            backStack.append(self.route)
            forwardStack.removeAll()
            self.route = route
            updateHistoryFlags()
        }
        if let row {
            highlight.flash(row)
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
        updateHistoryFlags()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
        updateHistoryFlags()
    }

    /// Drops the pages of agents and projects that are gone (deleted,
    /// renamed, removed) from the history; the page shown falls back to
    /// Agents or Projects. Runs on the turn after `AgentSettings`
    /// published, since it publishes itself.
    func reconcile(agentIDs: Set<String>, projectRoots: Set<String>) {
        func exists(_ route: SettingsRoute) -> Bool {
            switch route {
            case .page: true
            case .agent(let id): agentIDs.contains(id)
            case .project(let root): projectRoots.contains(root)
            }
        }

        var current = route
        if !exists(current) {
            current = switch current {
            case .agent: .page(.agents)
            case .project: .page(.projects)
            case .page: current
            }
        }
        // Gone routes go, and so do the repeats their going leaves, next to
        // each other or next to the page shown.
        let back = Self.withoutRepeats(backStack.filter(exists) + [current]).dropLast()
        let forward = Self.withoutRepeats(forwardStack.filter(exists) + [current]).dropLast()
        if backStack != Array(back) { backStack = Array(back) }
        if forwardStack != Array(forward) { forwardStack = Array(forward) }
        if route != current { route = current }
        updateHistoryFlags()
    }

    /// Follows an agent's rename (its id is its normalized name): the page
    /// shown and the history name the new id.
    func renameAgent(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        func renamed(_ route: SettingsRoute) -> SettingsRoute {
            route == .agent(oldID) ? .agent(newID) : route
        }
        backStack = backStack.map(renamed)
        forwardStack = forwardStack.map(renamed)
        let current = renamed(route)
        if route != current { route = current }
    }

    private func updateHistoryFlags() {
        if canGoBack != !backStack.isEmpty { canGoBack = !backStack.isEmpty }
        if canGoForward != !forwardStack.isEmpty { canGoForward = !forwardStack.isEmpty }
    }

    private static func withoutRepeats(_ routes: [SettingsRoute]) -> [SettingsRoute] {
        routes.reduce(into: []) { result, route in
            if result.last != route { result.append(route) }
        }
    }
}

// MARK: - Opening Settings at a page

/// Opening Settings at a page or a row from outside the window (spec
/// §1.4): the navigator is set first, then the window opens (or comes to
/// the front) on that page. ⌘,, the app menu, the Omni bar's Settings row
/// and the menu bar panel's Settings… open the last page.
@MainActor
enum SettingsOpening {
    /// "Edit Agents…" in the sidebar's agent + menu: Agents › Agents.
    static func editAgents(navigator: SettingsNavigator, openSettings: () -> Void) {
        open(.page(.agents), row: .agentsList, navigator: navigator, openSettings: openSettings)
    }

    /// A search left in the field ends, so the sidebar shows the page
    /// selected and no "No settings match" covers it.
    static func open(
        _ route: SettingsRoute,
        row: SettingsRowID? = nil,
        navigator: SettingsNavigator,
        openSettings: () -> Void
    ) {
        if !navigator.search.text.isEmpty {
            navigator.search.text = ""
        }
        navigator.open(route, row: row)
        openSettings()
    }
}

// MARK: - Keys

/// The Settings window's own keys, as System Settings has them: ⌘F
/// focuses the search field, ⌘[ and ⌘] go back and forward. A local
/// monitor sees a key down before the app's menus, whose Find (⌘F) and
/// pane keys (⌘[ and ⌘]) would otherwise take them, so it takes keys only
/// of the Settings window and passes every other window's on untouched. A
/// page's `SettingsKeyCapture` (Shortcuts' Record) sees each key first.
struct SettingsKeyMonitor: NSViewRepresentable {
    let navigator: SettingsNavigator
    var capture: SettingsKeyCapture = .shared

    enum Action: Equatable {
        case focusSearch
        case goBack
        case goForward
    }

    /// The window's key a press is; nil for any other. Caps Lock, and the
    /// keypad and function flags AppKit adds to some keys, are not held
    /// modifiers.
    nonisolated static func action(for charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags) -> Action? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers == .command else { return nil }
        switch charactersIgnoringModifiers?.lowercased() {
        case "f": return .focusSearch
        case "[": return .goBack
        case "]": return .goForward
        default: return nil
        }
    }

    /// What the monitor does with `event`: nothing unless it is a key down
    /// in the Settings window; then the capture's, else the window's own
    /// key (`perform`). True takes the event.
    static func handle(
        _ event: NSEvent,
        inSettingsWindow: Bool,
        capture: SettingsKeyCapture,
        perform: (Action) -> Void
    ) -> Bool {
        guard inSettingsWindow, event.type == .keyDown else { return false }
        if capture.take(event) { return true }
        guard let action = action(for: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
            return false
        }
        perform(action)
        return true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(navigator: navigator, capture: capture)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.navigator = navigator
        nsView.coordinator = context.coordinator
    }

    final class MonitorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.window = window
        }
    }

    @MainActor
    final class Coordinator {
        var navigator: SettingsNavigator
        let capture: SettingsKeyCapture
        weak var window: NSWindow?
        private nonisolated(unsafe) var monitor: Any?

        init(navigator: SettingsNavigator, capture: SettingsKeyCapture) {
            self.navigator = navigator
            self.capture = capture
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return consumed ? nil : event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            let inSettingsWindow = window != nil && event.window === window
            return SettingsKeyMonitor.handle(event, inSettingsWindow: inSettingsWindow, capture: capture) { action in
                switch action {
                case .focusSearch: navigator.search.requestFocus()
                case .goBack: navigator.goBack()
                case .goForward: navigator.goForward()
                }
            }
        }
    }
}
