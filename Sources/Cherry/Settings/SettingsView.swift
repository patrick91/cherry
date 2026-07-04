import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @State private var selection: SettingsSelection = .page(.general)
    @State private var searchText = ""

    var body: some View {
        SettingsNativeTabView(
            selection: $selection,
            searchText: $searchText,
            terminalSettings: terminalSettings,
            agentSettings: agentSettings,
            pages: SettingsPage.filtered(by: searchText),
            projects: CherryProject.filtered(agentSettings.projects, by: searchText)
        )
        .onChange(of: searchText) { _, _ in
            keepSelectionVisible()
        }
        .onChange(of: agentSettings.projects) { _, _ in
            keepSelectionVisible()
        }
    }

    private func keepSelectionVisible() {
        let visible = visibleSelections()
        guard !visible.isEmpty else { return }
        guard !visible.contains(selection) else { return }
        selection = visible.first ?? .page(.general)
    }

    private func visibleSelections() -> [SettingsSelection] {
        let visible = SettingsPage.filtered(by: searchText).map(SettingsSelection.page)
            + CherryProject.filtered(agentSettings.projects, by: searchText).map { .project($0.root) }
        return visible.isEmpty ? [.emptySearch] : visible
    }
}

private enum SettingsSelection: Hashable {
    case page(SettingsPage)
    case project(String)
    case emptySearch
}

private struct SettingsNativeTabView: View {
    @Binding var selection: SettingsSelection
    @Binding var searchText: String
    @ObservedObject var terminalSettings: TerminalSettings
    @ObservedObject var agentSettings: AgentSettings
    let pages: [SettingsPage]
    let projects: [CherryProject]

    var body: some View {
        TabView(selection: $selection) {
            if pages.isEmpty, projects.isEmpty {
                Tab("No Results", systemImage: "magnifyingglass", value: SettingsSelection.emptySearch) {
                    SettingsEmptySearchPane(query: searchText)
                }
            } else {
                if !pages.isEmpty {
                    TabSection("Settings") {
                        if pages.contains(.general) {
                            Tab("General", systemImage: SettingsPage.general.systemImage, value: SettingsSelection.page(.general)) {
                                GeneralSettingsPane(settings: terminalSettings)
                            }
                        }

                        if pages.contains(.terminal) {
                            Tab("Terminal", systemImage: SettingsPage.terminal.systemImage, value: SettingsSelection.page(.terminal)) {
                                TerminalSettingsPane(settings: terminalSettings)
                            }
                        }

                        if pages.contains(.projects) {
                            Tab("Projects", systemImage: SettingsPage.projects.systemImage, value: SettingsSelection.page(.projects)) {
                                ProjectSettingsPane(settings: agentSettings)
                            }
                        }

                        if pages.contains(.agents) {
                            Tab("Agents", systemImage: SettingsPage.agents.systemImage, value: SettingsSelection.page(.agents)) {
                                AgentSettingsPane(settings: agentSettings)
                            }
                        }

                        if pages.contains(.mcp) {
                            Tab("MCP", systemImage: SettingsPage.mcp.systemImage, value: SettingsSelection.page(.mcp)) {
                                MCPSettingsPane()
                            }
                        }
                    }
                }

                if !projects.isEmpty {
                    TabSection("Projects") {
                        ForEach(projects) { project in
                            Tab(project.name, systemImage: "folder", value: SettingsSelection.project(project.root)) {
                                ProjectDetailSettingsPane(project: project, settings: agentSettings)
                            }
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader {
            SettingsSearchField(text: $searchText)
                .padding(.top, 8)
        }
        .background(SettingsNativeWindowConfigurator())
        .frame(width: 980, height: 680)
    }
}

private struct SettingsEmptySearchPane: View {
    let query: String

    var body: some View {
        SettingsPaneScroll(
            title: "No Results",
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No settings are available."
                : "No settings match \"\(query)\".",
            systemImage: "magnifyingglass"
        ) {
            SettingsCard {
                SettingsEmptyState(
                    title: "No settings found",
                    message: "Try searching for a section, project name, or folder path.",
                    systemImage: "magnifyingglass"
                )
            }
        }
    }
}

private struct SettingsNativeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsNativeWindowChromeView {
        let view = SettingsNativeWindowChromeView()
        DispatchQueue.main.async {
            view.configureWindowChrome()
        }
        return view
    }

    func updateNSView(_ nsView: SettingsNativeWindowChromeView, context: Context) {
        DispatchQueue.main.async {
            nsView.configureWindowChrome()
        }
    }
}

private final class SettingsNativeWindowChromeView: NSView {
    private weak var attachedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var sidebarCleanupGeneration = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== attachedWindow {
            attachedWindow = window
            registerWindowObservers()
        }
        configureWindowChrome()
    }

    func configureWindowChrome() {
        guard let window else { return }
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        removeSidebarToolbarItems()
        scheduleSidebarToolbarCleanup()
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
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.configureWindowChrome()
                }
            }
        }
    }

    private func removeSidebarToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        for index in toolbar.items.indices.reversed() {
            if isSidebarToolbarItem(toolbar.items[index]) {
                toolbar.removeItem(at: index)
            }
        }
    }

    private func scheduleSidebarToolbarCleanup() {
        sidebarCleanupGeneration += 1
        let generation = sidebarCleanupGeneration
        let delays: [Duration] = [
            .milliseconds(0),
            .milliseconds(50),
            .milliseconds(150),
            .milliseconds(400)
        ]

        for delay in delays {
            Task { @MainActor [weak self] in
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                guard let self, sidebarCleanupGeneration == generation else { return }
                removeSidebarToolbarItems()
            }
        }
    }

    private func isSidebarToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar || item.itemIdentifier == .sidebarTrackingSeparator {
            return true
        }

        let fields = [
            item.itemIdentifier.rawValue,
            item.label,
            item.paletteLabel,
            item.toolTip ?? ""
        ]

        return fields.contains {
            let value = $0.lowercased()
            return value.contains("sidebar") || value.contains("side bar")
        }
    }
}

private extension CherryProject {
    var settingsSearchTokens: String {
        "\(name) \(root) project projects workspace folder commands features appearance color"
    }

    static func filtered(_ projects: [CherryProject], by query: String) -> [CherryProject] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return projects }
        return projects.filter {
            $0.settingsSearchTokens.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case terminal
    case projects
    case agents
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .projects: "Projects"
        case .agents: "Agents"
        case .mcp: "MCP"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "App chrome, sidebar, and theme behavior"
        case .terminal: "Terminal themes, text, cursor, and contrast"
        case .projects: "Workspaces, local features, and identity colors"
        case .agents: "Agent tools and automatic summaries"
        case .mcp: "Install commands and connection status"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .terminal: "terminal.fill"
        case .projects: "folder.fill"
        case .agents: "sparkles"
        case .mcp: "point.3.connected.trianglepath.dotted"
        }
    }

    var searchTokens: String {
        "\(title) \(subtitle) \(rawValue)"
    }

    static func filtered(by query: String) -> [SettingsPage] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return allCases }
        return allCases.filter {
            $0.searchTokens.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}
