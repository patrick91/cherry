import AppKit
import SwiftUI

/// The Settings window: the sidebar with its search, and the page the
/// navigator shows (`SettingsNavigator.shared`), with back and forward in
/// the toolbar. It opens 980 by 680 pt and resizes both ways, down to 800 by
/// 520 pt; the page's column stays at most 640 pt wide. ⌘F, ⌘[ and ⌘] are the
/// window's (`SettingsKeyMonitor`).
struct SettingsView: View {
    /// Not observed here: the sidebar and the detail observe what they show,
    /// so the shell is not built again for a page or a setting.
    private let navigator: SettingsNavigator
    private let agentSettings: AgentSettings
    @Environment(\.openWindow) private var openWindow

    init(navigator: SettingsNavigator = .shared, agentSettings: AgentSettings = .shared) {
        self.navigator = navigator
        self.agentSettings = agentSettings
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(
                navigator: navigator,
                agentSettings: agentSettings,
                rowsChanged: SettingsSearchContext.liveChanges
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(navigator: navigator)
        }
        .environment(\.settingsRowHighlight, navigator.highlight)
        .environment(\.settingsActions, .live(openWindow: openWindow))
        .background(SettingsKeyMonitor(navigator: navigator))
        .background(SettingsNativeWindowConfigurator {
            SettingsHostStatusRefresh.refresh()
        })
        .frame(minWidth: 800, idealWidth: 980, maxWidth: .infinity, minHeight: 520, idealHeight: 680, maxHeight: .infinity)
        .onReceive(agentSettings.$agents) { _ in scheduleReconcile() }
        .onReceive(agentSettings.$projects) { _ in scheduleReconcile() }
    }

    /// Agents and projects that went (deleted, renamed, removed) leave the
    /// history on the next turn, once `AgentSettings` changed: never from
    /// a view update.
    private func scheduleReconcile() {
        DispatchQueue.main.async { [navigator, agentSettings] in
            MainActor.assumeIsolated {
                navigator.reconcile(
                    agentIDs: Set(agentSettings.agents.map(\.id)),
                    projectRoots: Set(SettingsProjectOrdering.listed(agentSettings.projects).map(\.root))
                )
            }
        }
    }
}

/// The page of the route shown, from its top (`.id(route)`), under the
/// toolbar's back and forward. While a search finds nothing it says so
/// instead.
private struct SettingsDetail: View {
    @ObservedObject var navigator: SettingsNavigator

    var body: some View {
        page(for: navigator.route)
            .id(navigator.route)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                SettingsNoResults(search: navigator.search)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button {
                            navigator.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back")
                        .disabled(!navigator.canGoBack)

                        Button {
                            navigator.goForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.right")
                        }
                        .help("Forward")
                        .disabled(!navigator.canGoForward)
                    }
                    .controlGroupStyle(.navigation)
                }
            }
    }

    @ViewBuilder
    private func page(for route: SettingsRoute) -> some View {
        switch route {
        case .page(.sessions): SessionsSettingsPage()
        case .page(.interface): InterfaceSettingsPage()
        case .page(.themes): ThemesSettingsPage()
        case .page(.terminal): TerminalSettingsPage()
        case .page(.shortcuts): ShortcutsSettingsPage()
        case .page(.notifications): NotificationsSettingsPage()
        case .page(.macs): MacsSettingsPage()
        case .page(.agents): AgentsSettingsPage()
        case .page(.projects): ProjectsSettingsPage()
        case .page(.updates): UpdatesSettingsPage()
        case .agent(let id): AgentSettingsPage(agentID: id)
        case .project(let root): ProjectSettingsPage(projectRoot: root)
        }
    }
}

/// What the detail says while a search finds nothing (it observes only the
/// search, so a keystroke does not rebuild the page under it).
private struct SettingsNoResults: View {
    @ObservedObject var search: SettingsSearchModel

    var body: some View {
        if search.hasNoResults {
            SettingsEmptyState(
                title: "No settings match “\(search.query)”",
                message: "Search looks at setting names, descriptions and values, and at project names and paths.",
                systemImage: "magnifyingglass"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsDesign.Colors.window)
        }
    }
}

/// The window's chrome, which SwiftUI has no modifier for on a Settings
/// scene: the title shown, a unified toolbar without a separator, content
/// under the title bar. Tells `windowDidBecomeKey` when the window comes to
/// the front.
private struct SettingsNativeWindowConfigurator: NSViewRepresentable {
    let windowDidBecomeKey: @MainActor () -> Void

    func makeNSView(context: Context) -> SettingsNativeWindowChromeView {
        let view = SettingsNativeWindowChromeView()
        view.windowDidBecomeKey = windowDidBecomeKey
        DispatchQueue.main.async {
            view.configureWindowChrome()
        }
        return view
    }

    func updateNSView(_ nsView: SettingsNativeWindowChromeView, context: Context) {
        nsView.windowDidBecomeKey = windowDidBecomeKey
        DispatchQueue.main.async {
            nsView.configureWindowChrome()
        }
    }
}

private final class SettingsNativeWindowChromeView: NSView {
    var windowDidBecomeKey: (@MainActor () -> Void)?
    private weak var attachedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== attachedWindow {
            attachedWindow = window
            registerWindowObservers()
        }
        configureWindowChrome()
    }

    /// Runs on every update of the settings view and each time its window
    /// becomes key, so it sets only what differs: setting a window's chrome,
    /// even to the same value, can lay the whole window out again.
    func configureWindowChrome() {
        guard let window else { return }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
        if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        if let toolbar = window.toolbar, toolbar.showsBaselineSeparator {
            toolbar.showsBaselineSeparator = false
        }
        removeSidebarToolbarItems()
    }

    private func registerWindowObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }

        let names: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] notification in
                let becameKey = notification.name == NSWindow.didBecomeKeyNotification
                Task { @MainActor in
                    self?.configureWindowChrome()
                    if becameKey {
                        self?.windowDidBecomeKey?()
                    }
                }
            }
        }
    }

    /// The sidebar's toggle, should `.toolbar(removing: .sidebarToggle)`
    /// leave it: the sidebar is always shown. The tracking separator stays,
    /// since it keeps back and forward and the title over the detail.
    /// Tooltips are not read: a page's own toolbar item may mention the
    /// sidebar in one (an agent's Enabled switch).
    private func removeSidebarToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed() where isSidebarToolbarItem(toolbar.items[index]) {
            toolbar.removeItem(at: index)
        }
    }

    private func isSidebarToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar { return true }
        guard item.itemIdentifier != .sidebarTrackingSeparator else { return false }

        let fields = [
            item.itemIdentifier.rawValue,
            item.label,
            item.paletteLabel
        ]

        return fields.contains {
            let value = $0.lowercased()
            return value.contains("sidebar") || value.contains("side bar")
        }
    }
}
