import AppKit
import CherryControl
import GhosttyTheme
import SwiftUI

struct SettingsView: View {
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @State private var selection: SettingsSelection = .page(.general)
    @State private var searchText = ""

    var body: some View {
        if #available(macOS 15.0, *) {
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
        } else {
            SettingsLegacySplitView(
                selection: $selection,
                searchText: $searchText,
                terminalSettings: terminalSettings,
                agentSettings: agentSettings
            )
            .onChange(of: searchText) { _, _ in
                keepSelectionVisible()
            }
            .onChange(of: agentSettings.projects) { _, _ in
                keepSelectionVisible()
            }
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

@available(macOS 15.0, *)
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

                        if pages.contains(.commands) {
                            Tab("Commands", systemImage: SettingsPage.commands.systemImage, value: SettingsSelection.page(.commands)) {
                                CommandSettingsPane(settings: agentSettings)
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
            VStack(alignment: .leading, spacing: 18) {
                SettingsSearchField(text: $searchText)
                SettingsSidebarAccount()
            }
            .padding(.top, 8)
        }
        .background(SettingsNativeWindowConfigurator())
        .frame(width: 980, height: 680)
    }
}

private struct SettingsLegacySplitView: View {
    @Binding var selection: SettingsSelection
    @Binding var searchText: String
    @ObservedObject var terminalSettings: TerminalSettings
    @ObservedObject var agentSettings: AgentSettings

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: $selection,
                searchText: $searchText,
                pages: SettingsPage.filtered(by: searchText),
                projects: CherryProject.filtered(agentSettings.projects, by: searchText)
            )
            .frame(width: 286)

            Divider()

            SettingsDetailPane(
                selection: selection,
                searchText: searchText,
                terminalSettings: terminalSettings,
                agentSettings: agentSettings
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .background(SettingsWindowConfigurator())
        .frame(width: 980, height: 680)
    }
}

private struct SettingsDetailPane: View {
    let selection: SettingsSelection
    let searchText: String
    @ObservedObject var terminalSettings: TerminalSettings
    @ObservedObject var agentSettings: AgentSettings

    var body: some View {
        detailPane
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .page(let page):
            switch page {
            case .general:
                GeneralSettingsPane(settings: terminalSettings)
            case .terminal:
                TerminalSettingsPane(settings: terminalSettings)
            case .projects:
                ProjectSettingsPane(settings: agentSettings)
            case .agents:
                AgentSettingsPane(settings: agentSettings)
            case .commands:
                CommandSettingsPane(settings: agentSettings)
            case .mcp:
                MCPSettingsPane()
            }
        case .project(let root):
            if let project = agentSettings.projects.first(where: { $0.root == root }) {
                ProjectDetailSettingsPane(project: project, settings: agentSettings)
            } else {
                ProjectSettingsPane(settings: agentSettings)
            }
        case .emptySearch:
            SettingsEmptySearchPane(query: searchText)
        }
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
        window.titlebarAppearsTransparent = true
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

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowChromeView {
        let view = SettingsWindowChromeView()
        DispatchQueue.main.async {
            view.configureWindowChrome()
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowChromeView, context: Context) {
        DispatchQueue.main.async {
            nsView.configureWindowChrome()
        }
    }

    static func dismantleNSView(_ nsView: SettingsWindowChromeView, coordinator: ()) {
        nsView.restoreTrafficLights()
    }
}

private final class SettingsWindowChromeView: NSView {
    private let trafficLightLeadingInset: CGFloat = 18
    private let trafficLightTopInset: CGFloat = 24
    private let trafficLightSpacing: CGFloat = 20
    private var hostedButtons: [NSButton] = []
    private weak var attachedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== attachedWindow {
            hostedButtons = []
            attachedWindow = window
            registerWindowObservers()
        }
        configureWindowChrome()
    }

    override func layout() {
        super.layout()
        repositionTrafficLights()
    }

    func configureWindowChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        window.toolbar = nil
        attachTrafficLightsIfNeeded()
        repositionTrafficLights()
    }

    func restoreTrafficLights() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        restoreStandardTrafficLights()
    }

    private func restoreStandardTrafficLights() {
        for button in hostedButtons {
            button.isHidden = false
            button.isEnabled = true
            button.autoresizingMask = []
        }
        hostedButtons.removeAll()
    }

    private func registerWindowObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }

        let names: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
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

    private func attachTrafficLightsIfNeeded() {
        guard hostedButtons.isEmpty, let window else { return }
        hostedButtons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        for button in hostedButtons {
            button.autoresizingMask = []
            button.isHidden = false
            button.wantsLayer = true
            button.layer?.mask = nil
        }
    }

    private func repositionTrafficLights() {
        attachTrafficLightsIfNeeded()
        guard !hostedButtons.isEmpty,
              let parent = hostedButtons.first?.superview
        else { return }

        let controlHeight = hostedButtons.map(\.frame.height).max() ?? 14
        let sourceView = window?.contentView ?? self
        let targetY = sourceView.isFlipped
            ? trafficLightTopInset
            : sourceView.bounds.height - trafficLightTopInset - controlHeight
        let originInParent = sourceView.convert(
            NSPoint(x: trafficLightLeadingInset, y: max(0, targetY)),
            to: parent
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, button) in hostedButtons.enumerated() {
            button.setFrameOrigin(NSPoint(
                x: originInParent.x + CGFloat(index) * trafficLightSpacing,
                y: originInParent.y + (controlHeight - button.frame.height) / 2
            ))
        }

        CATransaction.commit()
    }
}

private extension CherryProject {
    var settingsSearchTokens: String {
        "\(name) \(root) project projects workspace folder"
    }

    static func filtered(_ projects: [CherryProject], by query: String) -> [CherryProject] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return projects }
        return projects.filter {
            $0.settingsSearchTokens.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case terminal
    case projects
    case agents
    case commands
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .projects: "Projects"
        case .agents: "Agents"
        case .commands: "Commands"
        case .mcp: "MCP"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "App chrome, sidebar, and theme behavior"
        case .terminal: "Terminal themes, text, cursor, and contrast"
        case .projects: "Workspaces, local features, and identity colors"
        case .agents: "Agent tools and automatic summaries"
        case .commands: "Trusted project commands"
        case .mcp: "Install commands and connection status"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .terminal: "terminal.fill"
        case .projects: "folder.fill"
        case .agents: "sparkles"
        case .commands: "play.rectangle.fill"
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

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSelection
    @Binding var searchText: String
    let pages: [SettingsPage]
    let projects: [CherryProject]

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(text: $searchText)
                .padding(.horizontal, 20)
                .padding(.top, 80)
                .padding(.bottom, 20)

            SettingsSidebarAccount()
                .padding(.horizontal, 20)
                .padding(.bottom, 26)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSidebarSection(title: "Settings") {
                        ForEach(pages) { page in
                            SettingsSidebarRow(
                                page: page,
                                isSelected: selection == .page(page)
                            ) {
                                selection = .page(page)
                            }
                        }

                        if pages.isEmpty, projects.isEmpty {
                            SettingsSidebarEmptyRow(title: "No settings found")
                        }
                    }

                    SettingsSidebarSection(title: "Projects") {
                        ForEach(projects) { project in
                            SettingsProjectSidebarRow(
                                project: project,
                                isSelected: selection == .project(project.root)
                            ) {
                                selection = .project(project.root)
                            }
                        }

                        if projects.isEmpty, !pages.isEmpty {
                            SettingsSidebarEmptyRow(title: "No projects found")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.thickMaterial)
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .settingsSearchFieldSurface()
    }
}

private struct SettingsSidebarSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            VStack(spacing: 2) {
                content
            }
        }
    }
}

private struct SettingsSidebarAccount: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                    }

                Text("C")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cherry")
                    .font(.system(size: 13, weight: .semibold))
                Text("Settings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 2)
    }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 18)

                Text(page.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                SettingsSelectionSurface()
            }
        }
    }
}

private struct SettingsProjectSidebarRow: View {
    let project: CherryProject
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(project.root)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                SettingsSelectionSurface()
            }
        }
    }
}

private struct SettingsSidebarEmptyRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }
}

private struct SettingsSelectionSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor)
    }
}

private struct SettingsIconBadge: View {
    let systemImage: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                }

            Image(systemName: systemImage)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

private struct SettingsGroupedSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.6)
            }
    }
}

private struct SettingsGlassButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)
        }
    }
}

private struct SettingsProminentGlassButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)
        }
    }
}

private struct SettingsSearchFieldSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
        }
    }
}

private extension View {
    func settingsGroupedSurface() -> some View {
        modifier(SettingsGroupedSurfaceModifier())
    }

    func settingsGlassButtonStyle() -> some View {
        modifier(SettingsGlassButtonModifier())
    }

    func settingsProminentGlassButtonStyle() -> some View {
        modifier(SettingsProminentGlassButtonModifier())
    }

    func settingsSearchFieldSurface() -> some View {
        modifier(SettingsSearchFieldSurfaceModifier())
    }

    func settingsRowPadding() -> some View {
        padding(.horizontal, 18).padding(.vertical, 13)
    }
}

private struct SettingsPaneScroll<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: Content

    init(page: SettingsPage, @ViewBuilder content: () -> Content) {
        title = page.title
        subtitle = page.subtitle
        systemImage = page.systemImage
        self.content = content()
    }

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 660, alignment: .topLeading)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 13)
                    .padding(.bottom, 7)
            }

            content
        }
        .settingsGroupedSurface()
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 18)
    }
}

private struct SettingsEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

private struct MCPSettingsPane: View {
    @State private var copiedHarness: MCPHarness?
    @State private var socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)

    private var commands: [MCPInstallCommand] {
        MCPInstallCommandBuilder.commands()
    }

    var body: some View {
        SettingsPaneScroll(page: .mcp) {
            SettingsCard("Status") {
                SettingsRow("MCP helper", subtitle: "Installed next to the Cherry app.") {
                    Text("Stdio")
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                SettingsRow("MCP helper") {
                    Text(MCPInstallCommandBuilder.helperCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                SettingsDivider()

                SettingsRow("Cherry instance socket") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(socketExists ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(socketExists ? "Listening" : "Waiting for Cherry")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsDivider()

                SettingsRow("Instance socket path") {
                    Text(CherryControl.socketURL.path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                SettingsDivider()

                SettingsRow("Connection") {
                    Button("Refresh") {
                        socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
                    }
                    .settingsGlassButtonStyle()
                }
            }

            SettingsCard("Install Commands") {
                ForEach(commands) { installCommand in
                    MCPInstallCommandRow(
                        installCommand: installCommand,
                        isCopied: copiedHarness == installCommand.harness
                    ) {
                        copy(installCommand)
                    }

                    if installCommand.id != commands.last?.id {
                        SettingsDivider()
                    }
                }
            }
        }
        .onAppear {
            socketExists = FileManager.default.fileExists(atPath: CherryControl.socketURL.path)
        }
    }

    private func copy(_ installCommand: MCPInstallCommand) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand.command, forType: .string)
        copiedHarness = installCommand.harness

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            if copiedHarness == installCommand.harness {
                copiedHarness = nil
            }
        }
    }
}

private struct MCPInstallCommandRow: View {
    let installCommand: MCPInstallCommand
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(installCommand.harness.name)
                    .fontWeight(.medium)

                Text(installCommand.command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            }
            .settingsGlassButtonStyle()
            .help(isCopied ? "Copied" : "Copy command")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct ProjectSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var settings: AgentSettings

    var body: some View {
        SettingsPaneScroll(page: .projects) {
            SettingsCard("Library") {
                SettingsRow(
                    "\(settings.projects.count) \(settings.projects.count == 1 ? "project" : "projects")",
                    subtitle: "Projects can keep local overrides or share commands and feature flags through cherry.toml."
                ) {
                    Button {
                        chooseProjectRoot()
                    } label: {
                        Label("Add Project", systemImage: "plus")
                    }
                    .settingsProminentGlassButtonStyle()
                }

                if settings.projects.isEmpty {
                    SettingsDivider()
                    SettingsEmptyState(
                        title: "No projects yet",
                        message: "Add a folder to configure project features, commands, and identity colors.",
                        systemImage: "folder.badge.plus"
                    )
                }
            }

            ForEach(settings.projects) { project in
                ProjectSettingsCard(
                    project: project,
                    settings: settings,
                    onOpen: { openProject(project) },
                    onRemove: { settings.removeProject(project) }
                )
            }
        }
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let project = settings.addProject(path: url.path) {
            openProject(project)
        }
    }

    private func openProject(_ project: CherryProject) {
        settings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}

private struct ProjectDetailSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    let project: CherryProject
    @ObservedObject var settings: AgentSettings

    var body: some View {
        SettingsPaneScroll(
            title: project.name,
            subtitle: project.root,
            systemImage: "folder.fill"
        ) {
            SettingsCard("Project") {
                SettingsRow("Location", subtitle: project.root) {
                    HStack(spacing: 8) {
                        Button("Open") {
                            openProject()
                        }
                        .settingsProminentGlassButtonStyle()

                        Button("Remove", role: .destructive) {
                            settings.removeProject(project)
                        }
                        .settingsGlassButtonStyle()
                    }
                }
            }

            SettingsCard("Features") {
                ProjectFeatureControls(settings: settings, project: project)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }

            SettingsCard("Appearance") {
                ProjectAppearanceControls(settings: settings, project: project)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }
        }
    }

    private func openProject() {
        settings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}

private struct ProjectSettingsCard: View {
    let project: CherryProject
    @ObservedObject var settings: AgentSettings
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsCard {
            Button(action: onOpen) {
                ProjectRow(project: project)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Remove Project", role: .destructive, action: onRemove)
            }

            SettingsDivider()

            ProjectFeatureControls(settings: settings, project: project)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            SettingsDivider()

            ProjectAppearanceControls(settings: settings, project: project)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }
}

private struct ProjectRow: View {
    let project: CherryProject

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(
                systemImage: "folder.fill",
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(project.root)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private struct ProjectFeatureControls: View {
    @ObservedObject var settings: AgentSettings
    let project: CherryProject

    @State private var storage: ProjectFeatureStorage = .local
    @State private var errorMessage: String?

    private var features: ProjectFeatureSettings {
        settings.projectFeatures(for: project.root)
    }

    private var hasLocalOverrides: Bool {
        !settings.projectFeatureOverrides(for: project.root).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Notes", isOn: featureBinding(\.notesEnabled))
                Toggle("Todos", isOn: featureBinding(\.todosEnabled))

                Spacer()

                Picker("Storage", selection: $storage) {
                    Text("Local").tag(ProjectFeatureStorage.local)
                    Text("cherry.toml").tag(ProjectFeatureStorage.projectFile)
                }
                .labelsHidden()
                .frame(width: 130)

                if hasLocalOverrides {
                    Button("Clear Local") {
                        settings.clearLocalProjectFeatureOverrides(for: project.root)
                    }
                    .settingsGlassButtonStyle()
                    .help("Use cherry.toml feature settings for this project")
                }
            }
            .toggleStyle(.checkbox)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func featureBinding(_ keyPath: WritableKeyPath<ProjectFeatureSettings, Bool>) -> Binding<Bool> {
        Binding {
            features[keyPath: keyPath]
        } set: { newValue in
            var next = features
            next[keyPath: keyPath] = newValue
            do {
                try settings.setProjectFeatures(next, for: project.root, storage: storage)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProjectAppearanceControls: View {
    @ObservedObject var settings: AgentSettings
    let project: CherryProject

    @State private var storage: ProjectAppearanceStorage = .local
    @State private var errorMessage: String?

    private var appearance: ProjectAppearanceSettings {
        settings.projectAppearance(for: project.root)
    }

    private var hasLocalOverrides: Bool {
        !settings.projectAppearanceOverrides(for: project.root).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Color", selection: colorBinding) {
                    Label("None", systemImage: "slash.circle")
                        .tag(Optional<ProjectIdentityColor>.none)

                    ForEach(ProjectIdentityColor.allCases) { color in
                        ProjectColorPickerLabel(color: color)
                            .tag(Optional(color))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()

                Picker("Storage", selection: $storage) {
                    Text("Local").tag(ProjectAppearanceStorage.local)
                    Text("cherry.toml").tag(ProjectAppearanceStorage.projectFile)
                }
                .labelsHidden()
                .frame(width: 130)

                if hasLocalOverrides {
                    Button("Clear Local") {
                        settings.clearLocalProjectAppearanceOverrides(for: project.root)
                    }
                    .settingsGlassButtonStyle()
                    .help("Use cherry.toml appearance settings for this project")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var colorBinding: Binding<ProjectIdentityColor?> {
        Binding {
            appearance.color
        } set: { newColor in
            do {
                try settings.setProjectAppearance(
                    ProjectAppearanceSettings(color: newColor),
                    for: project.root,
                    storage: storage
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProjectColorPickerLabel: View {
    let color: ProjectIdentityColor

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: NSColor(hexRGB: color.hexRGB) ?? .controlAccentColor))
                .frame(width: 10, height: 10)
            Text(color.label)
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        SettingsPaneScroll(page: .general) {
            SettingsCard("Interface") {
                SettingsRow("App appearance", subtitle: "Choose whether Cherry follows macOS or uses a fixed appearance.") {
                    Picker("App appearance", selection: $settings.appearance) {
                        ForEach(CherryAppearancePreference.allCases) { appearance in
                            Text(appearance.label)
                                .tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                SettingsDivider()

                SettingsRow("Terminal path labels", subtitle: "Control how project and folder names are shown in the sidebar.") {
                    Picker("Terminal path labels", selection: $settings.sidebarTerminalPathDisplayMode) {
                        ForEach(SidebarTerminalPathDisplayMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }

                SettingsDivider()

                SettingsRow("Project colors", subtitle: "Use project identity colors in the window chrome and sidebar.") {
                    Picker("Project colors", selection: $settings.projectColorDisplayMode) {
                        ForEach(ProjectColorDisplayMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            SettingsCard("Reset") {
                SettingsRow("Terminal appearance", subtitle: "Restore default themes, font size, contrast, cursor, and sidebar display.") {
                    Button("Reset") {
                        settings.resetTerminalAppearance()
                    }
                    .settingsGlassButtonStyle()
                }
            }
        }
    }
}

private struct TerminalSettingsPane: View {
    @ObservedObject var settings: TerminalSettings

    var body: some View {
        SettingsPaneScroll(page: .terminal) {
            SettingsCard("Themes") {
                GhosttyThemePicker(
                    title: "Light",
                    selection: $settings.lightTerminalThemeName
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                GhosttyThemePicker(
                    title: "Dark",
                    selection: $settings.darkTerminalThemeName
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }

            SettingsCard("Text") {
                SettingsSlider(
                    title: "Font size",
                    value: $settings.fontSize,
                    range: 10...24,
                    step: 1,
                    suffix: "pt"
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                SettingsRow("Blink cursor", subtitle: "Animate the block cursor while the terminal is focused.") {
                    Toggle("Blink cursor", isOn: $settings.cursorBlink)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Color") {
                SettingsSlider(
                    title: "Minimum contrast",
                    value: $settings.minimumContrast,
                    range: 1...2,
                    step: 0.05,
                    suffix: "x"
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                SettingsSlider(
                    title: "Sidebar contrast",
                    value: $settings.sidebarBackgroundDepth,
                    range: 0...0.24,
                    step: 0.01,
                    suffix: "%",
                    displayScale: 100
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)

                SettingsDivider()

                SidebarThemeDebugPanel(settings: settings)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
            }
        }
    }
}

private struct SidebarThemeDebugPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: TerminalSettings

    private var sample: SidebarThemeSample {
        SidebarThemeSample(
            themeColors: settings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: settings.sidebarBackgroundDepth
        )
    }

    var body: some View {
        let sample = sample

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SidebarColorDebugSwatch(title: "Terminal", color: sample.background)
                SidebarColorDebugSwatch(title: "Sidebar", color: sample.sidebarBackground)

                if let selectionBackground = sample.selectionBackground {
                    SidebarColorDebugSwatch(title: "Selection", color: selectionBackground)
                }
            }

            Text("Luma delta \(luminanceDelta(for: sample))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private func luminanceDelta(for sample: SidebarThemeSample) -> String {
        let delta = abs(sample.background.relativeLuminance - sample.sidebarBackground.relativeLuminance)
        return Double(delta).formatted(.number.precision(.fractionLength(3)))
    }
}

private struct SidebarColorDebugSwatch: View {
    let title: String
    let color: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Text(color.hexRGBString)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: 120, alignment: .leading)
    }
}

private struct GhosttyThemePicker: View {
    let title: String
    @Binding var selection: String

    private var selectedTheme: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: selection)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Picker("Ghostty theme", selection: $selection) {
                if selectedTheme == nil {
                    Text(selection.isEmpty ? "Select a theme" : "\(selection) (unknown)")
                        .tag(selection)
                }

                ForEach(Self.themes) { theme in
                    Text(theme.name)
                        .tag(theme.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let selectedTheme {
                GhosttyThemeSwatch(theme: selectedTheme)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private static let themes = GhosttyThemeCatalog.allThemes.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

private struct GhosttyThemeSwatch: View {
    let theme: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 4) {
            swatch(theme.background)
            swatch(theme.foreground)
            swatch(theme.selectionBackground ?? theme.palette[4] ?? theme.foreground)
        }
        .frame(width: 42, alignment: .trailing)
        .help(theme.name)
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(nsColor: NSColor(hexRGB: hex) ?? .clear))
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    var displayScale = 1.0

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Slider(value: $value, in: range, step: step)

            Text(formattedValue)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        let displayValue = value * displayScale

        if step * displayScale >= 1 {
            return "\(Int(displayValue.rounded()))\(formattedSuffix)"
        } else {
            return "\(displayValue.formatted(.number.precision(.fractionLength(2))))\(formattedSuffix)"
        }
    }

    private var formattedSuffix: String {
        guard !suffix.isEmpty else { return "" }
        return suffix == "pt" ? " \(suffix)" : suffix
    }
}

private struct AgentSettingsPane: View {
    @ObservedObject var settings: AgentSettings

    @State private var editingAgent: AgentToolDefinition?
    @State private var editingOriginalName: String?
    @State private var agentError: String?

    var body: some View {
        SettingsPaneScroll(page: .agents) {
            SettingsCard("Agent Tools") {
                if settings.resolvedAgents.isEmpty {
                    SettingsEmptyState(
                        title: "No agents configured",
                        message: "Add one of the presets to start launching agents from Cherry.",
                        systemImage: "sparkles"
                    )
                } else {
                    ForEach(Array(settings.resolvedAgents.enumerated()), id: \.element.id) { index, agent in
                        AgentToolRow(agent: agent) {
                            editingAgent = agent.definition
                            editingOriginalName = agent.name
                        } onReset: {
                            settings.removeAgent(named: agent.name)
                        }

                        if index < settings.resolvedAgents.count - 1 {
                            SettingsDivider()
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Add agent", subtitle: "Start from a preset and customize the command if needed.") {
                    Menu {
                        ForEach(AgentConfiguration.presets) { preset in
                            Button(preset.name) {
                                editingAgent = preset
                                editingOriginalName = nil
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .settingsGlassButtonStyle()
                }
            }

            SummarySettingsSection(settings: settings)
        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: editingOriginalName != nil,
                errorMessage: agentError,
                onSave: { updatedAgent in
                    do {
                        try settings.upsertAgent(
                            updatedAgent,
                            replacing: editingOriginalName
                        )
                        agentError = nil
                        editingOriginalName = nil
                        editingAgent = nil
                    } catch {
                        agentError = error.localizedDescription
                    }
                },
                onDelete: {
                    settings.removeAgent(named: agent.name)
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                },
                onCancel: {
                    agentError = nil
                    editingOriginalName = nil
                    editingAgent = nil
                }
            )
        }
    }
}

private struct SummarySettingsSection: View {
    @ObservedObject var settings: AgentSettings
    @StateObject private var debugStore = AgentSummaryDebugStore.shared

    @State private var testTask: Task<Void, Never>?
    @State private var testStatus: SummaryTestStatus = .idle

    private var commandPreview: String {
        settings.effectiveAgentSummaryCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCard("Auto-Summarization") {
            SummarySettingsRow {
                Text("Summary engine")
                Text("Cherry uses Codex MCP for background agent summaries and sends a compact rendered-text snapshot from recent terminal output, not the full raw transcript.")
                    .foregroundStyle(.secondary)
            } control: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Codex MCP")
                        .foregroundStyle(.secondary)
                }
            }

            SettingsDivider()

            SummarySettingsRow {
                Text("Cadence")
                Text("Minimum time between auto-summary attempts for the same session. Cherry still waits for a brief idle pause before requesting a summary.")
                    .foregroundStyle(.secondary)
            } control: {
                Picker("Cadence", selection: $settings.agentSummaryCadence) {
                    ForEach(AgentSummaryCadence.allCases) { cadence in
                        Text(cadence.label)
                            .tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            SettingsDivider()

            SummarySettingsRow {
                Text("Model")
                Text(AgentSummaryTool.codex.modelFlagDescription)
                    .foregroundStyle(.secondary)
            } control: {
                Picker("Model", selection: $settings.agentSummaryModel) {
                    if !settings.agentSummaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !AgentSummaryTool.codex.modelOptions.contains(settings.agentSummaryModel) {
                        Text("\(settings.agentSummaryModel) (custom)")
                            .tag(settings.agentSummaryModel)
                    }

                    ForEach(AgentSummaryTool.codex.modelOptions, id: \.self) { model in
                        Text(model)
                            .tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 250)
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command preview")
                    Text("The Codex MCP command path Cherry uses for summarization.")
                        .foregroundStyle(.secondary)
                }

                Text(commandPreview)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            SettingsDivider()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test summarizer")
                        .font(.callout)
                    Text(testStatus.message)
                        .font(.callout)
                        .foregroundStyle(testStatus.isError ? .red : .secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(testStatus.isRunning ? "Testing" : "Test") {
                    runTest()
                }
                .disabled(testStatus.isRunning)
                .settingsGlassButtonStyle()
                .frame(width: 82)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            SettingsDivider()

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug")
                        .font(.callout)
                    Text(debugStore.lastRecord?.status ?? "No summary attempts recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(debugStore.logURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button("Copy") {
                        debugStore.copyLastRecord()
                    }
                    .disabled(debugStore.lastRecord == nil)
                    .settingsGlassButtonStyle()

                    Button("Reveal") {
                        debugStore.revealLog()
                    }
                    .settingsGlassButtonStyle()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    private func runTest() {
        testTask?.cancel()
        testStatus = .running
        testTask = Task {
            do {
                let transcript = """
                User asked Cherry to summarize an agent session.
                The agent inspected settings, changed SwiftUI, and ran tests.
                """
                let result = try await CodexMCPSummaryRunner.shared.run(
                    transcript: transcript,
                    workingDirectory: NSHomeDirectory(),
                    model: settings.agentSummaryModel
                )
                await MainActor.run {
                    testStatus = .success(result.summary)
                }
            } catch {
                await MainActor.run {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }
}

private struct SummarySettingsRow<Description: View, Control: View>: View {
    let description: () -> Description
    let control: () -> Control

    init(
        @ViewBuilder description: @escaping () -> Description,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.description = description
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                description()
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}

private enum SummaryTestStatus: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)

    var isRunning: Bool {
        self == .running
    }

    var isError: Bool {
        if case .failure = self {
            return true
        }
        return false
    }

    var message: String {
        switch self {
        case .idle:
            "Runs the selected tool directly to verify setup. Any OS permission prompts come from that tool."
        case .running:
            "Waiting for the summarizer to return one short line."
        case .success(let summary):
            "Returned: \(summary)"
        case .failure(let message):
            "Failed: \(message)"
        }
    }
}

private struct CommandSettingsPane: View {
    @ObservedObject var settings: AgentSettings

    @State private var selectedProjectRoot = ""
    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    private var selectedCommands: [ProjectCommandDefinition] {
        guard !selectedProjectRoot.isEmpty else { return [] }
        return settings.projectCommands(for: selectedProjectRoot)
    }

    var body: some View {
        SettingsPaneScroll(page: .commands) {
            SettingsCard("Project") {
                if settings.projects.isEmpty {
                    SettingsEmptyState(
                        title: "No projects configured",
                        message: "Add a project before creating project commands.",
                        systemImage: "folder"
                    )
                } else {
                    SettingsRow("Active project", subtitle: "Commands are stored per project.") {
                        Picker("Project", selection: $selectedProjectRoot) {
                            ForEach(settings.projects) { project in
                                Text(project.name)
                                    .tag(project.root)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }
            }

            SettingsCard("Commands") {
                if selectedProjectRoot.isEmpty || selectedCommands.isEmpty {
                    SettingsEmptyState(
                        title: settings.projects.isEmpty ? "No project selected" : "No commands yet",
                        message: settings.projects.isEmpty
                            ? "Projects appear here after you add them in Project settings."
                            : "Create trusted commands for repeatable local workflows.",
                        systemImage: "play.rectangle"
                    )
                } else {
                    ForEach(Array(selectedCommands.enumerated()), id: \.element.id) { index, command in
                        ProjectCommandRow(command: command) {
                            editingCommand = command
                            editingOriginalName = command.name
                        } onDelete: {
                            settings.removeCommand(named: command.name, for: selectedProjectRoot)
                        }

                        if index < selectedCommands.count - 1 {
                            SettingsDivider()
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Add command", subtitle: "Add a reusable command for the selected project.") {
                    Button {
                        editingCommand = ProjectCommandDefinition(name: "Dev server", command: "npm", arguments: "run dev")
                        editingOriginalName = nil
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(selectedProjectRoot.isEmpty)
                    .settingsGlassButtonStyle()
                }
            }
        }
        .onAppear {
            if selectedProjectRoot.isEmpty {
                selectedProjectRoot = settings.projects.first?.root ?? ""
            }
        }
        .onChange(of: settings.projects) { _, projects in
            guard !projects.contains(where: { $0.root == selectedProjectRoot }) else { return }
            selectedProjectRoot = projects.first?.root ?? ""
        }
        .sheet(item: $editingCommand) { command in
            ProjectCommandEditor(
                command: command,
                projectRoot: selectedProjectRoot,
                canDelete: editingOriginalName != nil,
                errorMessage: commandError,
                onSave: { updatedCommand, storage in
                    do {
                        try settings.upsertCommand(
                            updatedCommand,
                            for: selectedProjectRoot,
                            replacing: editingOriginalName,
                            storage: storage
                        )
                        commandError = nil
                        editingOriginalName = nil
                        editingCommand = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                },
                onDelete: {
                    settings.removeCommand(named: command.name, for: selectedProjectRoot)
                    commandError = nil
                    editingOriginalName = nil
                    editingCommand = nil
                },
                onCancel: {
                    commandError = nil
                    editingOriginalName = nil
                    editingCommand = nil
                }
            )
        }
    }
}

private struct ProjectCommandRow: View {
    let command: ProjectCommandDefinition
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.enabled ? "play.circle.fill" : "pause.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(command.enabled ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(command.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(command.enabled ? .primary : .secondary)

                    if !command.enabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(command.commandLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Edit", action: onEdit)
                .settingsGlassButtonStyle()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

struct ProjectCommandEditor: View {
    @State private var draft: ProjectCommandDraft
    @State private var isApplyingCommandExtraction = false
    @AppStorage("ProjectCommandEditor.extractsEnvironmentAssignments")
    private var extractsEnvironmentAssignments = true

    let projectRoot: String
    let canDelete: Bool
    let errorMessage: String?
    let onSave: (ProjectCommandDefinition, ProjectCommandStorage) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        command: ProjectCommandDefinition,
        projectRoot: String,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (ProjectCommandDefinition, ProjectCommandStorage) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: ProjectCommandDraft(command: command, projectRoot: projectRoot))
        self.projectRoot = projectRoot
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(canDelete ? "Edit command" : "Add command")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command name")
                        .foregroundStyle(.secondary)
                    TextField("e.g., Vite, Queue, Logs", text: $draft.name)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .foregroundStyle(.secondary)
                    TextField("e.g., npm run dev", text: $draft.commandLine)
                        .onChange(of: draft.commandLine) { oldValue, newValue in
                            extractEnvironmentFromCommandIfNeeded(oldValue: oldValue, newValue: newValue)
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Working directory")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("e.g., ., web, packages/api", text: $draft.workingDirectory)

                        Button("Browse") {
                            chooseWorkingDirectory()
                        }
                    }

                    Text("Leave empty to use project root. Relative paths resolve from the project root.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                environmentSection

                Toggle("Auto-start when project starts", isOn: $draft.autoStart)
                Toggle("Auto-restart if command exits", isOn: $draft.autoRestart)
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Where to save this command")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ProjectCommandStorageOption(
                    title: "Save to cherry.toml",
                    subtitle: CherryProjectFile.exists(projectRoot: projectRoot)
                        ? "Share this command through the project config"
                        : "No cherry.toml found — Cherry will create one",
                    isSelected: draft.storage == .projectFile
                ) {
                    draft.storage = .projectFile
                }

                ProjectCommandStorageOption(
                    title: "Store locally only",
                    subtitle: "Keep this command just for yourself on this machine",
                    isSelected: draft.storage == .local
                ) {
                    draft.storage = .local
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if canDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(draft.definition, draft.storage)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !draft.workingDirectory.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: draft.definition.resolvedWorkingDirectory(projectRoot: projectRoot),
                isDirectory: true
            )
        } else if !projectRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = ProjectCommandDefinition.portableWorkingDirectory(url.path, projectRoot: projectRoot)
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment variables")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    draft.addEnvironmentRow()
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            if !draft.environmentRows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Color.clear
                            .frame(width: 24)
                    }

                    ForEach($draft.environmentRows) { $row in
                        GridRow {
                            TextField("NAME", text: $row.name)
                                .textFieldStyle(.roundedBorder)
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                draft.removeEnvironmentRow(id: row.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove variable")
                        }
                    }
                }
            }

            Toggle("Detect env vars pasted into Command", isOn: $extractsEnvironmentAssignments)
                .font(.callout)
        }
    }

    private func extractEnvironmentFromCommandIfNeeded(oldValue: String, newValue: String) {
        guard extractsEnvironmentAssignments,
              !isApplyingCommandExtraction,
              isLikelyPaste(oldValue: oldValue, newValue: newValue),
              let extraction = ProjectCommandEnvironmentExtraction.extractLeadingAssignments(from: newValue)
        else {
            return
        }

        isApplyingCommandExtraction = true
        draft.commandLine = extraction.commandLine
        draft.mergeEnvironment(extraction.environment)
        isApplyingCommandExtraction = false
    }

    private func isLikelyPaste(oldValue: String, newValue: String) -> Bool {
        guard newValue.contains("="), newValue.contains(where: \.isWhitespace) else { return false }
        return oldValue.isEmpty || newValue.count > oldValue.count + 8
    }
}

private struct ProjectCommandStorageOption: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "smallcircle.filled.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProjectCommandDraft {
    var name: String
    var commandLine: String
    var workingDirectory: String
    var environmentRows: [ProjectCommandEnvironmentVariableDraft]
    var autoStart: Bool
    var autoRestart: Bool
    var enabled: Bool
    var storage: ProjectCommandStorage
    let projectRoot: String

    init(command: ProjectCommandDefinition, projectRoot: String) {
        name = command.name
        commandLine = command.commandLine
        workingDirectory = ProjectCommandDefinition.portableWorkingDirectory(
            command.workingDirectory,
            projectRoot: projectRoot
        )
        environmentRows = command.environment
            .keys
            .sorted()
            .compactMap { name in
                command.environment[name].map {
                    ProjectCommandEnvironmentVariableDraft(name: name, value: $0)
                }
            }
        autoStart = command.autoStart
        autoRestart = command.autoRestart
        enabled = command.enabled
        storage = .local
        self.projectRoot = projectRoot
        if name.isEmpty, commandLine.isEmpty, workingDirectory.isEmpty {
            self.workingDirectory = ""
        }
    }

    var definition: ProjectCommandDefinition {
        let parts = Self.splitCommandLine(commandLine)
        return ProjectCommandDefinition(
            name: name,
            command: parts.command,
            arguments: parts.arguments,
            workingDirectory: ProjectCommandDefinition.portableWorkingDirectory(
                workingDirectory,
                projectRoot: projectRoot
            ),
            environment: environment,
            autoStart: autoStart,
            autoRestart: autoRestart,
            enabled: enabled
        )
    }

    private var environment: [String: String] {
        var environment: [String: String] = [:]
        for row in environmentRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ProjectCommandEnvironmentExtraction.isValidEnvironmentName(name) else { continue }
            environment[name] = row.value
        }
        return environment
    }

    mutating func addEnvironmentRow() {
        environmentRows.append(ProjectCommandEnvironmentVariableDraft(name: "", value: ""))
    }

    mutating func removeEnvironmentRow(id: UUID) {
        environmentRows.removeAll { $0.id == id }
    }

    mutating func mergeEnvironment(_ nextEnvironment: [String: String]) {
        for name in nextEnvironment.keys.sorted() {
            guard let value = nextEnvironment[name] else { continue }
            if let index = environmentRows.firstIndex(where: { $0.name == name }) {
                environmentRows[index].value = value
            } else {
                environmentRows.append(ProjectCommandEnvironmentVariableDraft(name: name, value: value))
            }
        }
    }

    private static func splitCommandLine(_ commandLine: String) -> (command: String, arguments: String) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return (trimmed, "")
        }

        let command = String(trimmed[..<separator])
        let arguments = String(trimmed[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, arguments)
    }
}

private struct ProjectCommandEnvironmentVariableDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

private struct AgentToolRow: View {
    let agent: ResolvedAgentTool
    let onEdit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.enabled ? "sparkle.magnifyingglass" : "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(agent.enabled ? Color.accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .semibold))
                    if !agent.enabled {
                        Text("Disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !agent.isLaunchable {
                        Text("Blocked")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text(agent.commandLine.isEmpty ? "No command" : agent.commandLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(sourceLabel)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Edit", action: onEdit)
                .settingsGlassButtonStyle()
            Button("Delete", role: .destructive, action: onReset)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var sourceLabel: String {
        switch agent.source {
        case .global:
            "Global"
        }
    }
}

struct AgentToolEditor: View {
    @State private var draft: AgentToolDefinition

    let canDelete: Bool
    let errorMessage: String?
    let onSave: (AgentToolDefinition) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    init(
        agent: AgentToolDefinition,
        canDelete: Bool,
        errorMessage: String?,
        onSave: @escaping (AgentToolDefinition) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: agent)
        self.canDelete = canDelete
        self.errorMessage = errorMessage
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Edit agent tool")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $draft.name)
                TextField("Command", text: $draft.command)
                TextField("Default arguments", text: $draft.arguments)
                Toggle("Enabled", isOn: $draft.enabled)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if canDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
