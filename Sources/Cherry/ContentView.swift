import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    private let minimumSidebarWidth: CGFloat = 190
    private let maximumSidebarWidth: CGFloat = 420
    private let floatingSidebarLeadingInset: CGFloat = SidebarLayout.floatingOuterInset
    private let floatingSidebarTopInset: CGFloat = 3
    private let floatingSidebarBottomInset: CGFloat = 3

    @Environment(\.openSettings) private var openSettings
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let openProject: (CherryProject) -> Void
    @Binding var isSidebarHidden: Bool
    @Binding var isSidebarRevealed: Bool
    @Binding var isCursorOverSidebar: Bool
    @AppStorage("sidebar.width") private var storedSidebarWidth: Double = 320
    @State private var trafficLights = TrafficLightController()

    private var sidebarWidth: CGFloat {
        clampedSidebarWidth(CGFloat(storedSidebarWidth))
    }

    private var sidebarWidthBinding: Binding<CGFloat> {
        Binding {
            sidebarWidth
        } set: { nextWidth in
            storedSidebarWidth = Double(clampedSidebarWidth(nextWidth))
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The overlay sits at the bottom of the z-stack on purpose.
            // Native AppKit traffic-light buttons render above all SwiftUI
            // content via the window's titlebar, so visual layering is
            // unaffected — but keeping the representable behind the hover
            // strip prevents any chance of it intercepting hover events
            // (which we observed happening in maximized/fullscreen windows
            // even with `.allowsHitTesting(false)` applied).
            TrafficLightOverlay(controller: trafficLights)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                dockedSidebarSlot

                DetailPaneView(
                    workspace: workspace,
                    chromeState: chromeState,
                    includeLeadingPadding: isSidebarHidden
                )
                    .ignoresSafeArea(.all, edges: .top)
            }

            // The floating sidebar is always in the tree so a `(hidden,
            // revealed) → Cmd+S` transition can fade it out *in place* while
            // the docked sidebar grows in behind it. If it were gated on
            // `isSidebarHidden` it would be removed mid-transition and the
            // user would see the jarring slide-off + slide-in.
            floatingSidebar
                // Only slide off-screen when the sidebar is BOTH hidden and
                // not revealed. When transitioning to `shown`, the offset
                // stays at 0 so the sidebar fades out without sliding.
                .offset(
                    x: (isSidebarHidden && !isSidebarRevealed)
                        ? -(sidebarWidth + floatingSidebarLeadingInset)
                        : 0
                )
                .opacity(isSidebarRevealed ? 1 : 0)
                .allowsHitTesting(isSidebarRevealed)

            // Project picker, anchored to the window's top-leading corner so
            // it shares coordinate space with the traffic-light overlay
            // (which positions correctly at this level). It rides the same
            // chrome translation as the traffic lights so it slides off
            // with the sidebar, and is hidden via offset when the sidebar
            // is fully gone.
            TitlebarProjectPicker(
                settings: AgentSettings.shared,
                projectRoot: projectRoot,
                presentation: isSidebarRevealed ? .floating : .docked,
                openProject: openProject,
                openSettings: { openSettings() }
            )
            .padding(.leading, 80)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Drive the picker's offset off the same animated
            // (dockedWidth, floatingWidth) pair the traffic lights use,
            // so it goes through the same `min(0, max(...) - sidebarWidth)`
            // clamping each tick. With a plain `.offset(x:)` bound to a
            // computed CGFloat, SwiftUI springs the offset directly and lets
            // the value overshoot past `-sidebarWidth` — but the traffic
            // lights are clamped by `max(docked, 0)`, so they pin at
            // `-sidebarWidth` while the picker bounces. Same modifier,
            // identical math: they slide in lockstep.
            .modifier(ChromeOffsetModifier(
                dockedWidth: isSidebarHidden ? 0 : sidebarWidth,
                floatingWidth: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
                sidebarWidth: sidebarWidth
            ))
            .allowsHitTesting(!isSidebarHidden || isSidebarRevealed)

            if chromeState.isCommandPalettePresented {
                CommandPaletteOverlay(
                    settings: AgentSettings.shared,
                    workspace: workspace,
                    selectedProjectRoot: projectRoot,
                    isPresented: $chromeState.isCommandPalettePresented,
                    openProject: openProject
                )
                .zIndex(2_000)
            }

            if isSidebarHidden {
                // Wider hot-zone (24pt) avoids the macOS fullscreen edge
                // gestures that reserve the leftmost few pixels. Using
                // `.contentShape` + `onContinuousHover` is more robust than
                // a near-transparent `Rectangle` + `onHover`, whose
                // NSTrackingArea has been observed to go stale on window
                // resize / fullscreen transitions.
                Color.clear
                    .frame(width: 24)
                    .ignoresSafeArea(.all, edges: .vertical)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase, !isSidebarRevealed {
                            withAnimation(.snappy(duration: 0.18)) {
                                isSidebarRevealed = true
                            }
                        }
                    }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .background {
            AppShellBackground()
                .ignoresSafeArea(.all)
        }
        .background(AppShortcutMonitor(
            workspace: workspace,
            projectRoot: projectRoot,
            openSettings: { openSettings() }
        ))
        .background(WindowConfigurator())
        .frame(minWidth: 320, minHeight: 460)
        .modifier(ChromeWidthAnimator(
            dockedWidth: isSidebarHidden ? 0 : sidebarWidth,
            floatingWidth: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
            sidebarWidth: sidebarWidth,
            controller: trafficLights
        ))
        // No `.animation(value: isSidebarHidden)` here — the toggle in
        // CherryApp wraps in `withAnimation` only when the floating sidebar
        // is NOT revealed. When it IS revealed, the toggle is unwrapped, so
        // the docked + pane snap into place behind the floating sidebar.
        // Reveal/dismiss animations are driven by their explicit
        // `withAnimation` calls so the Cmd+S handoff can opt out cleanly.
        .onChange(of: isSidebarHidden) { _, hidden in
            // When toggling from `(hidden, revealed)` to `shown`, dismiss
            // the floating sidebar within the same animation so it fades
            // out in place while the docked sidebar grows in.
            if !hidden, isSidebarRevealed {
                withAnimation(.snappy(duration: 0.18)) {
                    isSidebarRevealed = false
                }
                // The docked sidebar's `.onHover` won't fire when it
                // appears under a stationary cursor (NSTrackingArea fires on
                // entry, not on becoming active). The cursor was just over
                // the floating sidebar — so it's almost certainly over the
                // new docked sidebar too. Mark it explicitly so a
                // subsequent Cmd+S can switch back to floating without
                // requiring a mouse wiggle.
                isCursorOverSidebar = true
            }
            // The docked sidebar's `.onHover` only fires when its hit area
            // is active, so once it's hidden it can't update this flag. Reset
            // it so a stale `true` doesn't carry over and trigger the
            // "switch to floating" branch on the next Cmd+S.
            if hidden {
                isCursorOverSidebar = false
            }
            syncTrafficLights()
        }
        .onChange(of: isSidebarRevealed) { _, _ in
            syncTrafficLights()
        }
        .onChange(of: sidebarWidth) { _, newWidth in
            syncTrafficLights()
            chromeState.dockedSidebarWidth = newWidth
        }
        .onAppear {
            storedSidebarWidth = Double(sidebarWidth)
            chromeState.dockedSidebarWidth = sidebarWidth
            trafficLights.seedTarget(
                docked: isSidebarHidden ? 0 : sidebarWidth,
                floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
                sidebarWidth: sidebarWidth
            )
        }
    }

    private var dockedSidebar: some View {
        SidebarTabsView(
            workspace: workspace,
            projectRoot: projectRoot,
            presentation: .docked,
            openProject: openProject
        )
            .frame(width: sidebarWidth)
            .ignoresSafeArea(.all, edges: .top)
            .overlay(alignment: .trailing) {
                sidebarResizeHandle
            }
            // Track whether the cursor is over the docked sidebar so that
            // CherryApp's Cmd+S can decide between "hide" and "switch to
            // floating-revealed" — we want the sidebar to stay open if the
            // user is actively pointing at it when toggling.
            .onHover { hovering in
                isCursorOverSidebar = hovering
            }
    }

    private var dockedSidebarSlot: some View {
        dockedSidebar
            // .trailing pins the sidebar's content to the slot's right edge
            // as the slot's width animates from `sidebarWidth → 0`. As the
            // right edge slides left, the contents (and the traffic lights
            // riding on top) translate left in lockstep — Dia's behavior.
            .frame(width: isSidebarHidden ? 0 : sidebarWidth, alignment: .trailing)
            .clipped()
            .allowsHitTesting(!isSidebarHidden)
            // Explicit local .animation for the frame width change. It's
            // conditional on `isSidebarRevealed` because when handing off
            // from the floating sidebar, we want the docked slot to snap
            // into place behind the floating fade-out (matching the
            // unwrapped toggle in CherryApp). Without this modifier, the
            // frame change relies entirely on `withAnimation`, but in
            // practice that doesn't reliably drive the slide animation
            // through the binding chain — making it explicit fixes it.
            .animation(
                isSidebarRevealed ? nil : .snappy(duration: 0.18),
                value: isSidebarHidden
            )
    }

    private var floatingSidebar: some View {
        SidebarTabsView(
            workspace: workspace,
            projectRoot: projectRoot,
            presentation: .floating,
            openProject: openProject
        )
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                sidebarResizeHandle
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
            .padding(.leading, floatingSidebarLeadingInset)
            .padding(.top, floatingSidebarTopInset)
            .padding(.bottom, floatingSidebarBottomInset)
            .ignoresSafeArea(.all, edges: .top)
            .onHover { hovering in
                if !hovering, isSidebarRevealed {
                    withAnimation(.snappy(duration: 0.18)) {
                        isSidebarRevealed = false
                    }
                }
            }
    }

    private var sidebarResizeHandle: some View {
        SidebarResizeHandle(
            sidebarWidth: sidebarWidthBinding,
            minimumWidth: minimumSidebarWidth,
            maximumWidth: maximumSidebarWidth
        )
        .frame(width: 12)
        .frame(maxHeight: .infinity)
    }

    // Belt-and-suspenders: SwiftUI's Animatable setter only fires inside an
    // animation transaction, and the modifier's `body` side effect can be
    // skipped by SwiftUI's render diffing. Calling this from every
    // `.onChange(...)` guarantees the controller catches the new state.
    private func syncTrafficLights() {
        trafficLights.update(
            docked: isSidebarHidden ? 0 : sidebarWidth,
            floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
            sidebarWidth: sidebarWidth
        )
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat

    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        nsView.sidebarWidth = sidebarWidth
        nsView.minimumWidth = minimumWidth
        nsView.maximumWidth = maximumWidth
        nsView.onResize = { nextWidth in
            sidebarWidth = nextWidth
        }
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class SidebarResizeHandleView: NSView {
    var sidebarWidth: CGFloat = 320
    var minimumWidth: CGFloat = 190
    var maximumWidth: CGFloat = 420
    var onResize: ((CGFloat) -> Void)?

    private var dragStartWidth: CGFloat?
    private var dragStartLocationX: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var didPushCursor = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pushResizeCursor()
    }

    override func mouseExited(with event: NSEvent) {
        popResizeCursorIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pushResizeCursor()
        dragStartWidth = sidebarWidth
        dragStartLocationX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWidth, let dragStartLocationX else { return }
        let proposedWidth = dragStartWidth + event.locationInWindow.x - dragStartLocationX
        let clampedWidth = min(max(proposedWidth, minimumWidth), maximumWidth)
        sidebarWidth = clampedWidth
        onResize?(clampedWidth)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWidth = nil
        dragStartLocationX = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    private func pushResizeCursor() {
        guard !didPushCursor else {
            NSCursor.resizeLeftRight.set()
            return
        }

        NSCursor.resizeLeftRight.push()
        didPushCursor = true
    }

    private func popResizeCursorIfNeeded() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }

    deinit {
        MainActor.assumeIsolated {
            popResizeCursorIfNeeded()
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
    }
}

private struct DetailPaneView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let includeLeadingPadding: Bool

    var body: some View {
        Group {
            if let session = workspace.selectedSession {
                TerminalSceneView(session: session, chromeState: chromeState)
            } else {
                ContentUnavailableView("No Active Session", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.top, 5)
        .padding(.leading, includeLeadingPadding ? 5 : 0)
        .padding(.trailing, 5)
        .padding(.bottom, 5)
    }
}

struct ProjectOnboardingView: View {
    @ObservedObject private var settings = AgentSettings.shared
    @State private var trafficLights = TrafficLightController()

    let onProjectCreated: (CherryProject) -> Void

    var body: some View {
        ZStack {
            TrafficLightOverlay(controller: trafficLights)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("No Project")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Create a project to start using Cherry.")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                Button {
                    chooseProjectRoot()
                } label: {
                    Label("Create Project", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(height: 34)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background {
            AppShellBackground()
                .ignoresSafeArea(.all)
        }
        .background(WindowConfigurator())
        .modifier(ChromeWidthAnimator(
            dockedWidth: 320,
            floatingWidth: 0,
            sidebarWidth: 320,
            controller: trafficLights
        ))
        .onAppear {
            trafficLights.seedTarget(docked: 320, floating: 0, sidebarWidth: 320)
        }
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create"

        guard panel.runModal() == .OK, let url = panel.url,
              let project = settings.addProject(path: url.path)
        else {
            return
        }

        onProjectCreated(project)
    }
}

private struct AppShellBackground: View {
    var body: some View {
        SidebarBackground(presentation: .docked)
    }
}

private enum CommandPaletteMode {
    case commands
    case projects
    case agents
    case agentPresets
}

private enum CommandPaletteCommand: String, CaseIterable, Identifiable {
    case projects
    case agents
    case addAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .agents: "Agents"
        case .addAgent: "Add Agent"
        }
    }

    var subtitle: String {
        switch self {
        case .projects: "Switch project"
        case .agents: "Open a configured agent"
        case .addAgent: "Configure a global agent tool"
        }
    }

    var icon: String {
        switch self {
        case .projects: "folder"
        case .agents: "sparkles"
        case .addAgent: "sparkles"
        }
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(normalizedQuery) ||
            subtitle.localizedCaseInsensitiveContains(normalizedQuery)
    }
}

private enum CommandPaletteRootItem: Identifiable {
    case command(CommandPaletteCommand)
    case agent(ResolvedAgentTool)

    var id: String {
        switch self {
        case .command(let command):
            "command:\(command.id)"
        case .agent(let agent):
            "agent:\(agent.id)"
        }
    }

    var icon: String {
        switch self {
        case .command(let command):
            command.icon
        case .agent:
            "terminal"
        }
    }

    var title: String {
        switch self {
        case .command(let command):
            command.title
        case .agent(let agent):
            agent.name
        }
    }

    var subtitle: String {
        switch self {
        case .command(let command):
            command.subtitle
        case .agent(let agent):
            agent.commandLine
        }
    }
}

private struct CommandPaletteOverlay: View {
    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    let selectedProjectRoot: String?
    @Binding var isPresented: Bool
    let openProject: (CherryProject) -> Void

    @State private var mode = CommandPaletteMode.commands
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var editingAgent: AgentToolDefinition?
    @State private var agentError: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField(prompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($isSearchFocused)
                        .onSubmit(commitSelection)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)

                Divider()

                ScrollView {
                    VStack(spacing: 4) {
                        if mode == .commands {
                            commandRows
                        } else if mode == .projects {
                            projectRows
                        } else if mode == .agents {
                            agentRows
                        } else {
                            agentPresetRows
                        }
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxHeight: 340)
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 28, y: 18)
            .padding(.top, 86)
        }
        .background(CommandPaletteKeyMonitor(handle: handleKeyDown))
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIndex = 0
            isSearchFocused = true
        }
        .sheet(item: $editingAgent) { agent in
            AgentToolEditor(
                agent: agent,
                canDelete: false,
                errorMessage: agentError,
                onSave: { updatedAgent in
                    do {
                        try settings.upsertAgent(updatedAgent)
                        agentError = nil
                        editingAgent = nil
                        dismiss()
                    } catch {
                        agentError = error.localizedDescription
                    }
                },
                onDelete: {
                    agentError = nil
                    editingAgent = nil
                    dismiss()
                },
                onCancel: {
                    agentError = nil
                    editingAgent = nil
                    dismiss()
                }
            )
        }
    }

    private var prompt: String {
        switch mode {
        case .commands: "Command"
        case .projects: "Project"
        case .agents: "Agent"
        case .agentPresets: "Agent"
        }
    }

    private var filteredCommands: [CommandPaletteCommand] {
        CommandPaletteCommand.allCases.filter { $0.matches(query) }
    }

    private var filteredRootItems: [CommandPaletteRootItem] {
        filteredCommands.map(CommandPaletteRootItem.command) +
            filteredAgents.map(CommandPaletteRootItem.agent)
    }

    private var filteredProjects: [CherryProject] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return settings.projects }
        return settings.projects.filter { project in
            project.name.localizedCaseInsensitiveContains(normalizedQuery) ||
                project.root.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var filteredAgents: [ResolvedAgentTool] {
        let agents = settings.resolvedProject(for: selectedProjectRoot).launchableAgents
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return agents }
        return agents.filter { agent in
            agent.name.localizedCaseInsensitiveContains(normalizedQuery) ||
                agent.commandLine.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var filteredAgentPresets: [AgentToolDefinition] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return AgentConfiguration.presets }
        return AgentConfiguration.presets.filter { preset in
            preset.name.localizedCaseInsensitiveContains(normalizedQuery) ||
                preset.commandLine.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    @ViewBuilder
    private var commandRows: some View {
        if filteredRootItems.isEmpty {
            CommandPaletteEmptyRow(title: "No commands")
        } else {
            ForEach(Array(filteredRootItems.enumerated()), id: \.element.id) { index, item in
                CommandPaletteRow(
                    icon: item.icon,
                    title: item.title,
                    subtitle: item.subtitle,
                    isSelected: index == selectedIndex,
                    isCurrent: false
                ) {
                    selectedIndex = index
                    commitSelection()
                }
            }
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        if filteredProjects.isEmpty {
            CommandPaletteEmptyRow(title: "No projects")
        } else {
            ForEach(Array(filteredProjects.enumerated()), id: \.element.id) { index, project in
                CommandPaletteRow(
                    icon: "folder.fill",
                    title: project.name,
                    subtitle: project.root,
                    isSelected: index == selectedIndex,
                    isCurrent: project.root == selectedProjectRoot
                ) {
                    selectedIndex = index
                    commitSelection()
                }
            }
        }
    }

    @ViewBuilder
    private var agentRows: some View {
        let project = settings.resolvedProject(for: selectedProjectRoot)
        if project.validProjectRoot == nil {
            CommandPaletteEmptyRow(title: "Select a project first")
        } else if filteredAgents.isEmpty {
            CommandPaletteEmptyRow(title: "No launchable agents")
        } else {
            ForEach(Array(filteredAgents.enumerated()), id: \.element.id) { index, agent in
                CommandPaletteRow(
                    icon: "terminal",
                    title: agent.name,
                    subtitle: agent.commandLine,
                    isSelected: index == selectedIndex,
                    isCurrent: false
                ) {
                    selectedIndex = index
                    commitSelection()
                }
            }
        }
    }

    @ViewBuilder
    private var agentPresetRows: some View {
        if filteredAgentPresets.isEmpty {
            CommandPaletteEmptyRow(title: "No agent presets")
        } else {
            ForEach(Array(filteredAgentPresets.enumerated()), id: \.element.id) { index, preset in
                CommandPaletteRow(
                    icon: preset.command.isEmpty ? "plus" : "terminal",
                    title: preset.name,
                    subtitle: preset.commandLine.isEmpty ? "Custom agent tool" : preset.commandLine,
                    isSelected: index == selectedIndex,
                    isCurrent: false
                ) {
                    selectedIndex = index
                    commitSelection()
                }
            }
        }
    }

    private var resultCount: Int {
        switch mode {
        case .commands: filteredRootItems.count
        case .projects: filteredProjects.count
        case .agents: filteredAgents.count
        case .agentPresets: filteredAgentPresets.count
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            handleEscape()
            return true
        case 36, 76:
            commitSelection()
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        let count = resultCount
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func commitSelection() {
        switch mode {
        case .commands:
            guard filteredRootItems.indices.contains(selectedIndex) else { return }
            switch filteredRootItems[selectedIndex] {
            case .command(let command):
                switch command {
                case .projects:
                    mode = .projects
                case .agents:
                    mode = .agents
                case .addAgent:
                    mode = .agentPresets
                }
            case .agent(let agent):
                launch(agent)
            }
        case .projects:
            guard filteredProjects.indices.contains(selectedIndex) else { return }
            let project = filteredProjects[selectedIndex]
            dismiss()
            openProject(project)
        case .agents:
            guard filteredAgents.indices.contains(selectedIndex) else { return }
            launch(filteredAgents[selectedIndex])
        case .agentPresets:
            guard filteredAgentPresets.indices.contains(selectedIndex) else { return }
            editingAgent = filteredAgentPresets[selectedIndex]
        }
    }

    private func launch(_ agent: ResolvedAgentTool) {
        let project = settings.resolvedProject(for: selectedProjectRoot)
        guard let root = project.validProjectRoot else { return }
        workspace.addAgentSession(agent: agent.definition, projectRoot: root)
        dismiss()
    }

    private func handleEscape() {
        if mode != .commands {
            mode = .commands
        } else {
            dismiss()
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct CommandPaletteRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .white : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CommandPaletteEmptyRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
    }
}

private struct CommandPaletteKeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CommandPaletteKeyMonitorView {
        let view = CommandPaletteKeyMonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: CommandPaletteKeyMonitorView, context: Context) {
        nsView.handle = handle
    }
}

private final class CommandPaletteKeyMonitorView: NSView {
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle?(event) == true ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeMonitor()
        }
    }
}

private enum SidebarPresentation {
    case docked
    case floating
}

private enum SidebarLayout {
    static let trafficLightLeadingInset: CGFloat = 18
    static let floatingOuterInset: CGFloat = 3
    static let trailingInset: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 12
}

private struct SidebarTabsView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject var workspace: TerminalWorkspace
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SidebarAgentSessionSection(
                        settings: agentSettings,
                        workspace: workspace,
                        projectRoot: projectRoot,
                        presentation: presentation,
                        openSettings: { openSettings() }
                    )

                    SidebarSessionSection(
                        title: "Terminals",
                        sessions: workspace.terminalSessions,
                        kind: .terminal,
                        workspace: workspace,
                        presentation: presentation
                    )

                    SidebarCommandSection(
                        settings: agentSettings,
                        workspace: workspace,
                        projectRoot: projectRoot,
                        presentation: presentation
                    )
                }
                // Keep the sidebar's text column aligned with the native
                // traffic-light leading edge in both docked and floating
                // presentations. Floating mode has an outer wrapper inset,
                // so the inner leading padding subtracts that amount.
                .padding(.leading, SidebarLayout.trafficLightLeadingInset - floatingOuterInset)
                .padding(.trailing, SidebarLayout.trailingInset)
                .padding(.top, 48 + dockedCompensation)
                .padding(.bottom, 10 + dockedCompensation)
            }
        }
        .background {
            if presentation == .floating {
                SidebarBackground(presentation: presentation)
            }
        }
    }

    private var floatingOuterInset: CGFloat {
        presentation == .floating ? SidebarLayout.floatingOuterInset : 0
    }

    // Resolves to 3pt for `.docked` and 0 for `.floating`. Keeps the vertical
    // content at the same on-screen position across both presentations.
    private var dockedCompensation: CGFloat {
        presentation == .docked ? SidebarLayout.floatingOuterInset : 0
    }
}

private struct TitlebarProjectPicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var settings: AgentSettings
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void
    let openSettings: () -> Void

    @State private var isHovering = false
    @State private var anchorRef = TitlebarProjectMenuAnchorRef()

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        // SwiftUI Menu's underlying NSPopUpButton owns mouse-tracking on its
        // label, so neither `.onHover` nor an NSTrackingArea overlay fire.
        // A plain Button has no such interference — we present an NSMenu
        // programmatically on click.
        Button(action: presentMenu) {
            Text(selectedProject?.name ?? "No Project")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.rowText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.hoverFill.opacity(isHovering ? 1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(TitlebarProjectMenuAnchor(ref: anchorRef))
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private func presentMenu() {
        let menu = NSMenu()
        var targets: [TitlebarProjectMenuTarget] = []

        if settings.projects.isEmpty {
            let item = NSMenuItem(title: "No Projects", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Projects"))

            for project in settings.projects {
                let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
                if selectedProject?.id == project.id {
                    item.state = .on
                }
                let target = TitlebarProjectMenuTarget { [openProject] in
                    openProject(project)
                }
                targets.append(target)
                item.target = target
                item.action = #selector(TitlebarProjectMenuTarget.invoke)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add Project...", action: nil, keyEquivalent: "")
        let addTarget = TitlebarProjectMenuTarget(chooseProjectRoot)
        targets.append(addTarget)
        addItem.target = addTarget
        addItem.action = #selector(TitlebarProjectMenuTarget.invoke)
        menu.addItem(addItem)

        let editItem = NSMenuItem(title: "Edit Projects...", action: nil, keyEquivalent: "")
        let editTarget = TitlebarProjectMenuTarget(openSettings)
        targets.append(editTarget)
        editItem.target = editTarget
        editItem.action = #selector(TitlebarProjectMenuTarget.invoke)
        menu.addItem(editItem)

        // Anchor the menu's top-left to the bottom-leading corner of the
        // button, with a 4pt gap. NSMenuItem.target is `weak`, but
        // `popUp(positioning:at:in:)` is synchronous: actions fire before
        // the call returns, so the local `targets` array keeps them alive
        // long enough.
        if let anchor = anchorRef.view {
            let bounds = anchor.bounds
            let point: NSPoint = anchor.isFlipped
                ? NSPoint(x: bounds.minX, y: bounds.maxY + 4)
                : NSPoint(x: bounds.minX, y: bounds.minY - 4)
            menu.popUp(positioning: nil, at: point, in: anchor)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        _ = targets
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.addProject(path: url.path)
        if let project = settings.selectedProject(for: url.path) {
            openProject(project)
        }
    }

    private var selectedProject: CherryProject? {
        settings.selectedProject(for: projectRoot)
    }
}

@MainActor
private final class TitlebarProjectMenuTarget: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

@MainActor
private final class TitlebarProjectMenuAnchorRef {
    weak var view: NSView?
}

private struct TitlebarProjectMenuAnchor: NSViewRepresentable {
    let ref: TitlebarProjectMenuAnchorRef

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ref.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        ref.view = nsView
    }
}

private struct SidebarAgentSessionSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openSettings: () -> Void

    var body: some View {
        let project = settings.resolvedProject(for: projectRoot)
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(title: "Agents", count: workspace.agentSessions.count, palette: palette)

                AgentLaunchMenu(
                    project: project,
                    palette: palette,
                    openSettings: openSettings,
                    launch: launch
                )
            }

            if workspace.agentSessions.isEmpty {
                SidebarEmptyRow(
                    title: "No agents",
                    palette: palette
                )
            } else {
                ForEach(workspace.agentSessions) { session in
                    SidebarTabRow(
                        session: session,
                        isSelected: workspace.selectedSessionID == session.id,
                        presentation: presentation,
                        onSelect: { workspace.select(session) }
                    )
                    .contextMenu {
                        Button("Rename...") {
                            promptRenameSession(session)
                        }

                        Divider()

                        Button("Restart") {
                            session.restart()
                        }

                        Button("Clear Scrollback") {
                            session.clearScrollback()
                        }

                        Divider()

                        Button("Close", role: .destructive) {
                            workspace.close(session)
                        }
                        .disabled(workspace.sessions.count <= 1)
                    }
                }
            }
        }
    }

    private func launch(_ agent: ResolvedAgentTool) {
        let project = settings.resolvedProject(for: projectRoot)
        guard agent.isLaunchable, let root = project.validProjectRoot else { return }
        workspace.addAgentSession(agent: agent.definition, projectRoot: root)
    }
}

private struct AgentLaunchMenu: View {
    let project: ResolvedAgentProject
    let palette: SidebarPalette
    let openSettings: () -> Void
    let launch: (ResolvedAgentTool) -> Void

    var body: some View {
        Menu {
            if project.launchableAgents.isEmpty {
                Button(project.validProjectRoot == nil ? "Select a Project" : "No Launchable Agents") {}
                    .disabled(true)
            } else {
                ForEach(project.launchableAgents) { agent in
                    Button(agent.name) {
                        launch(agent)
                    }
                }
            }

            Divider()

            Button("Edit Agents...") {
                openSettings()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.headerText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("New agent")
    }
}

private struct SidebarCommandSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    let projectRoot: String?
    let presentation: SidebarPresentation

    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    var body: some View {
        let commands = settings.launchableProjectCommands(for: projectRoot)
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(title: "Commands", count: commands.count, palette: palette)

                Button(action: addCommand) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.headerText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(projectRoot == nil)
                .help("Add command")
            }

            if commands.isEmpty {
                SidebarEmptyRow(
                    title: projectRoot == nil ? "Select a project" : "No commands",
                    palette: palette
                )
            } else {
                ForEach(commands) { command in
                    let session = workspace.commandSession(named: command.name)
                    SidebarCommandRow(
                        command: command,
                        session: session,
                        isSelected: session.map { workspace.selectedSessionID == $0.id } ?? false,
                        presentation: presentation,
                        start: { start(command, existingSession: session) },
                        stop: { session?.stopManagedCommand() },
                        restart: { restart(command, existingSession: session) },
                        select: {
                            if let session {
                                workspace.select(session)
                            }
                        }
                    )
                    .contextMenu {
                        Button(session == nil ? "Start" : "Restart") {
                            restart(command, existingSession: session)
                        }

                        Button("Stop") {
                            session?.stopManagedCommand()
                        }
                        .disabled(session?.isRunningCommand != true)

                        if let session {
                            Button("Rename...") {
                                promptRenameSession(session)
                            }

                            Button("Clear Scrollback") {
                                session.clearScrollback()
                            }
                        }

                        Divider()

                        Button("Edit") {
                            editingCommand = command
                            editingOriginalName = command.name
                        }

                        Button("Remove", role: .destructive) {
                            remove(command, existingSession: session)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCommand) { command in
            ProjectCommandEditor(
                command: command,
                projectRoot: projectRoot ?? "",
                canDelete: editingOriginalName != nil,
                errorMessage: commandError,
                onSave: { updatedCommand, storage in
                    guard let projectRoot else { return }
                    do {
                        try settings.upsertCommand(
                            updatedCommand,
                            for: projectRoot,
                            replacing: editingOriginalName,
                            storage: storage
                        )
                        workspace.updateCommandSession(
                            named: editingOriginalName,
                            with: updatedCommand,
                            projectRoot: projectRoot
                        )
                        commandError = nil
                        editingOriginalName = nil
                        editingCommand = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                },
                onDelete: {
                    if projectRoot != nil {
                        remove(command, existingSession: workspace.commandSession(named: command.name))
                    }
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

    private func addCommand() {
        editingCommand = ProjectCommandDefinition(name: "", command: "")
        editingOriginalName = nil
    }

    private func start(_ command: ProjectCommandDefinition, existingSession: TerminalSession?) {
        guard command.isLaunchable, let root = settings.resolvedProject(for: projectRoot).validProjectRoot else { return }
        if let existingSession {
            if existingSession.isRunningCommand {
                workspace.select(existingSession)
            } else {
                existingSession.restart()
                workspace.select(existingSession)
            }
        } else {
            workspace.addCommandSession(command: command, projectRoot: root)
        }
    }

    private func restart(_ command: ProjectCommandDefinition, existingSession: TerminalSession?) {
        guard command.isLaunchable else { return }
        if let existingSession {
            existingSession.restart()
            workspace.select(existingSession)
        } else {
            start(command, existingSession: nil)
        }
    }

    private func remove(_ command: ProjectCommandDefinition, existingSession: TerminalSession?) {
        if let existingSession, workspace.sessions.count > 1 {
            workspace.close(existingSession)
        } else {
            existingSession?.stop()
        }
        if let projectRoot {
            settings.removeCommand(named: command.name, for: projectRoot)
        }
    }
}

@MainActor
private func promptRenameSession(_ session: TerminalSession) {
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    alert.informativeText = "Leave the title empty to return to the automatic name."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(string: session.hasExplicitTitle ? session.title : "")
    field.placeholderString = session.title
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field

    if alert.runModal() == .alertFirstButtonReturn {
        session.rename(to: field.stringValue)
    }
}

private struct SidebarCommandRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    let command: ProjectCommandDefinition
    let session: TerminalSession?
    let isSelected: Bool
    let presentation: SidebarPresentation
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        Button(action: select) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .lineLimit(1)

                    Text(command.commandLine)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: session?.isRunningCommand == true ? stop : start) {
                    Image(systemName: session?.isRunningCommand == true ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session?.isRunningCommand == true ? "Stop" : "Start")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 46)
            .padding(.leading, SidebarLayout.rowHorizontalInset)
            .padding(.trailing, SidebarLayout.rowHorizontalInset)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                rowBackground(palette: palette)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private func rowBackground(palette: SidebarPalette) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.selectedFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.selectedStroke, lineWidth: 1)
                }
                .shadow(color: palette.selectedShadow, radius: 9, y: 4)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.hoverFill)
        }
    }
}

private extension TerminalSession {
    var isRunningCommand: Bool {
        switch state {
        case .launching, .live:
            true
        case .exited, .failed:
            false
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    let palette: SidebarPalette

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.headerText)
                .textCase(.uppercase)

            Rectangle()
                .fill(palette.headerText.opacity(0.22))
                .frame(height: 1)

            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.headerText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarEmptyRow: View {
    let title: String
    let palette: SidebarPalette

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.headerText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            .padding(.trailing, 12)
    }
}

private struct SidebarSessionSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    let title: String
    let sessions: [TerminalSession]
    let kind: TerminalSession.SessionKind
    @ObservedObject var workspace: TerminalWorkspace
    let presentation: SidebarPresentation

    @State private var draggedSessionID: UUID?
    @State private var draggedRowOffsetY: CGFloat = 0

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(title: title, count: sessions.count, palette: palette)

            ForEach(sessions) { session in
                SidebarTabRow(
                    session: session,
                    isSelected: workspace.selectedSessionID == session.id,
                    presentation: presentation,
                    onSelect: { workspace.select(session) }
                )
                .offset(y: draggedSessionID == session.id ? draggedRowOffsetY : 0)
                .zIndex(draggedSessionID == session.id ? 1 : 0)
                .anchorPreference(key: SidebarRowBoundsPreferenceKey.self, value: .bounds) { anchor in
                    [session.id: anchor]
                }
                .contextMenu {
                    Button("Rename...") {
                        promptRenameSession(session)
                    }

                    Divider()

                    Button("Restart") {
                        session.restart()
                    }

                    Button("Clear Scrollback") {
                        session.clearScrollback()
                    }

                    Divider()

                    Button("Close", role: .destructive) {
                        workspace.close(session)
                    }
                    .disabled(workspace.sessions.count <= 1)
                }
            }
        }
        .overlayPreferenceValue(SidebarRowBoundsPreferenceKey.self) { rowBounds in
            GeometryReader { geometry in
                SidebarInteractionOverlay(
                    rows: sessions.compactMap { session in
                        rowBounds[session.id].map { anchor in
                            SidebarRowFrame(id: session.id, rect: geometry[anchor].insetBy(dx: -4, dy: -3))
                        }
                    },
                    onSelect: { sessionID in
                        guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return }
                        workspace.select(session)
                    },
                    onDragChanged: { sessionID, offsetY in
                        draggedSessionID = sessionID
                        draggedRowOffsetY = offsetY
                    },
                    onMove: { sessionID, targetIndex in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            workspace.moveSession(id: sessionID, to: targetIndex, within: kind)
                        }
                    },
                    onDragEnded: {
                        withAnimation(.snappy(duration: 0.16)) {
                            draggedSessionID = nil
                            draggedRowOffsetY = 0
                        }
                    }
                )
            }
        }
    }
}

private struct SidebarRowBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarRowFrame: Equatable {
    let id: UUID
    let rect: CGRect
}

private struct SidebarInteractionOverlay: NSViewRepresentable {
    let rows: [SidebarRowFrame]
    let onSelect: (UUID) -> Void
    let onDragChanged: (UUID, CGFloat) -> Void
    let onMove: (UUID, Int) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> SidebarInteractionOverlayView {
        let view = SidebarInteractionOverlayView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarInteractionOverlayView, context: Context) {
        nsView.rows = rows
        nsView.onSelect = onSelect
        nsView.onDragChanged = onDragChanged
        nsView.onMove = onMove
        nsView.onDragEnded = onDragEnded
    }
}

private final class SidebarInteractionOverlayView: NSView {
    var rows: [SidebarRowFrame] = [] {
        didSet {
            rows.sort { $0.rect.minY < $1.rect.minY }
            if activeDragID == nil {
                rowOrder = rows.map(\.id)
            }
        }
    }
    var onSelect: ((UUID) -> Void)?
    var onDragChanged: ((UUID, CGFloat) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onDragEnded: (() -> Void)?

    private var activeDragID: UUID?
    private var dragStartY: CGFloat = 0
    private var dragOffsetY: CGFloat = 0
    private var rowOrder: [UUID] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        let eventType = NSApp.currentEvent?.type
        guard eventType == .leftMouseDown || eventType == .leftMouseDragged else { return nil }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard let row = row(at: point) else {
            window?.performDrag(with: event)
            return
        }

        activeDragID = row.id
        dragStartY = point.y
        dragOffsetY = 0
        rowOrder = rows.map(\.id)
        onSelect?(row.id)
        onDragChanged?(row.id, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeDragID else { return }

        let point = convert(event.locationInWindow, from: nil)
        dragOffsetY = point.y - dragStartY

        reorderActiveRowIfNeeded()
        onDragChanged?(activeDragID, dragOffsetY)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeDragID != nil else { return }

        activeDragID = nil
        dragStartY = 0
        dragOffsetY = 0
        rowOrder = rows.map(\.id)
        onDragEnded?()
    }

    private func row(at point: CGPoint) -> SidebarRowFrame? {
        rows.first { $0.rect.contains(point) }
    }

    private func reorderActiveRowIfNeeded() {
        guard let activeDragID,
              var currentIndex = rowOrder.firstIndex(of: activeDragID)
        else {
            return
        }

        let rowStep = estimatedRowStep()
        var didMove = false

        while dragOffsetY > rowStep / 2, currentIndex < rowOrder.count - 1 {
            dragOffsetY -= rowStep
            dragStartY += rowStep
            rowOrder.remove(at: currentIndex)
            currentIndex += 1
            rowOrder.insert(activeDragID, at: currentIndex)
            onMove?(activeDragID, currentIndex)
            didMove = true
        }

        while dragOffsetY < -rowStep / 2, currentIndex > 0 {
            dragOffsetY += rowStep
            dragStartY -= rowStep
            rowOrder.remove(at: currentIndex)
            currentIndex -= 1
            rowOrder.insert(activeDragID, at: currentIndex)
            onMove?(activeDragID, currentIndex)
            didMove = true
        }

        if didMove {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func estimatedRowStep() -> CGFloat {
        let sortedRows = rows.sorted { $0.rect.minY < $1.rect.minY }
        guard sortedRows.count > 1 else { return 46 }

        let deltas = zip(sortedRows, sortedRows.dropFirst()).map { next, previous in
            previous.rect.minY - next.rect.minY
        }
        return deltas.first(where: { $0 > 0 }) ?? 46
    }
}

// Drives the traffic-light mask in lockstep with SwiftUI's own animation
// timeline. Because `animatableData` is interpolated by SwiftUI itself, the
// mask edge tracks the pane edge frame-by-frame instead of running on a
// separate Core Animation clock with a different curve.
@MainActor
private struct ChromeWidthAnimator: ViewModifier, @preconcurrency Animatable {
    var dockedWidth: CGFloat
    var floatingWidth: CGFloat
    let sidebarWidth: CGFloat
    let controller: TrafficLightController

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(dockedWidth, floatingWidth) }
        set {
            dockedWidth = newValue.first
            floatingWidth = newValue.second
            controller.update(
                docked: newValue.first,
                floating: newValue.second,
                sidebarWidth: sidebarWidth
            )
        }
    }

    func body(content: Content) -> some View {
        // SwiftUI only invokes `animatableData.set` while an animation
        // transaction is active. When `.animation(...)` resolves to `nil`
        // (e.g., the floating → docked snap), the setter is skipped and the
        // controller would otherwise hold the previous values forever — so
        // the buttons stay at their old translation. Pushing the current
        // values from `body` keeps the controller in sync regardless of
        // whether an animation is in scope. During a real animation the
        // setter still runs and overrides this with interpolated values
        // each tick, so the body update is harmless in that case.
        controller.update(
            docked: dockedWidth,
            floating: floatingWidth,
            sidebarWidth: sidebarWidth
        )
        return content
    }
}

// Mirrors `ChromeWidthAnimator`'s interpolation so the project picker rides
// the same `min(0, max(docked, floating) - sidebarWidth)` curve the
// traffic-light controller does. A plain `.offset(x:)` bound to a CGFloat
// computed off `isSidebarHidden` springs the raw offset and overshoots
// past `-sidebarWidth`, while the traffic lights' `max(docked, 0)` clamps
// the overshoot — so the two diverge at the tail of the animation. Going
// through the same Animatable pair keeps them in lockstep.
@MainActor
private struct ChromeOffsetModifier: ViewModifier, @preconcurrency Animatable {
    var dockedWidth: CGFloat
    var floatingWidth: CGFloat
    let sidebarWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(dockedWidth, floatingWidth) }
        set {
            dockedWidth = newValue.first
            floatingWidth = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let chrome = max(dockedWidth, floatingWidth)
        let translationX = min(0, chrome - sidebarWidth)
        return content.offset(x: translationX)
    }
}

@MainActor
final class TrafficLightController {
    fileprivate weak var view: TrafficLightOverlayView?
    private var lastDocked: CGFloat = 0
    private var lastFloating: CGFloat = 0
    private var lastSidebarWidth: CGFloat = 320

    fileprivate func attach(_ view: TrafficLightOverlayView) {
        self.view = view
        applyCurrent()
    }

    fileprivate func detach(_ view: TrafficLightOverlayView) {
        guard self.view === view else { return }
        self.view = nil
    }

    func seedTarget(docked: CGFloat, floating: CGFloat, sidebarWidth: CGFloat) {
        lastDocked = docked
        lastFloating = floating
        lastSidebarWidth = sidebarWidth
        applyCurrent()
    }

    func update(docked: CGFloat, floating: CGFloat, sidebarWidth: CGFloat) {
        lastDocked = docked
        lastFloating = floating
        lastSidebarWidth = sidebarWidth
        applyCurrent()
    }

    // Translation matches the sidebar's contents: when the sidebar is fully
    // collapsed (chrome = 0), the buttons have shifted by -sidebarWidth, the
    // same distance the sidebar's right-aligned contents have shifted. When
    // the sidebar is wider than `sidebarWidth` (e.g. floating sidebar reveal
    // overshooting by `floatingSidebarLeadingInset`), translation clamps to 0.
    private func applyCurrent() {
        let chrome = max(lastDocked, lastFloating)
        let translationX = min(0, chrome - lastSidebarWidth)
        view?.applyButtonTranslation(translationX)
    }
}

private struct TrafficLightOverlay: NSViewRepresentable {
    let controller: TrafficLightController

    func makeNSView(context: Context) -> TrafficLightOverlayView {
        let view = TrafficLightOverlayView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: TrafficLightOverlayView, context: Context) {
        nsView.controller = controller
        nsView.repositionButtons()
    }

    static func dismantleNSView(_ nsView: TrafficLightOverlayView, coordinator: ()) {
        nsView.restore()
    }
}

private final class TrafficLightOverlayView: NSView {
    weak var controller: TrafficLightController? {
        didSet {
            if oldValue !== controller {
                oldValue?.detach(self)
                controller?.attach(self)
            }
        }
    }

    private let leftInset: CGFloat = SidebarLayout.trafficLightLeadingInset
    private let topInset: CGFloat = 18
    private let buttonSpacing: CGFloat = 20

    private var hostedButtons: [NSButton] = []
    private weak var attachedWindow: NSWindow?
    private var lastTranslationX: CGFloat = 0
    private var windowObservers: Set<AnyCancellable> = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The window can change (or become nil) across fullscreen transitions
        // and other AppKit lifecycle events. Force a re-attach to make sure
        // hostedButtons references are pointing at the *current* window's
        // standard buttons, not stale ones from the previous window.
        if window !== attachedWindow {
            hostedButtons = []
            attachedWindow = window
            registerWindowObservers()
        }
        attachWindowButtonsIfNeeded()
        applyButtonTranslation(lastTranslationX)
        controller?.attach(self)
    }

    override func layout() {
        super.layout()
        applyButtonTranslation(lastTranslationX)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @MainActor
    private func registerWindowObservers() {
        windowObservers.removeAll()

        guard let window else { return }

        // Re-apply our translation after AppKit-driven window state changes
        // — these are the moments when the standard buttons can get moved
        // back to default by AppKit's titlebar layout.
        let names: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]

        for name in names {
            NotificationCenter.default.publisher(for: name, object: window)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refreshButtonState()
                    }
                }
                .store(in: &windowObservers)
        }
    }

    @MainActor
    private func refreshButtonState() {
        // Drop stale references and re-resolve from the window. AppKit may
        // have re-parented the buttons during the state change.
        hostedButtons = []
        attachWindowButtonsIfNeeded()
        applyButtonTranslation(lastTranslationX)
    }

    @MainActor
    private func attachWindowButtonsIfNeeded() {
        guard hostedButtons.isEmpty, let window else { return }

        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        guard buttons.count == 3 else { return }

        hostedButtons = buttons
        configureButtons()
    }

    @MainActor
    private func configureButtons() {
        // Re-apply each call: AppKit can reset autoresizingMask / isHidden
        // during window state transitions, which would otherwise let the
        // buttons drift back to default position or vanish entirely.
        for button in hostedButtons {
            button.autoresizingMask = []
            button.isHidden = false
            button.wantsLayer = true
            button.layer?.mask = nil
        }
    }

    @MainActor
    func repositionButtons() {
        applyButtonTranslation(lastTranslationX)
    }

    // Place the native traffic-light buttons at their standard top-left
    // position, shifted horizontally by `translationX`. SwiftUI's animation
    // clock drives this value frame-by-frame via `TrafficLightController`,
    // so the buttons slide in lockstep with the sidebar collapsing.
    @MainActor
    func applyButtonTranslation(_ translationX: CGFloat) {
        attachWindowButtonsIfNeeded()
        lastTranslationX = translationX

        guard !hostedButtons.isEmpty,
              let parent = hostedButtons.first?.superview
        else {
            return
        }

        // Reassert these every call — AppKit can flip them during titlebar
        // layout changes (key/non-key, fullscreen, etc.).
        configureButtons()

        let baseX = leftInset + translationX
        let controlHeight = hostedButtons.map(\.frame.height).max() ?? 14
        let targetY = bounds.height - topInset - controlHeight
        let originInParent = convert(
            NSPoint(x: baseX, y: max(0, targetY)),
            to: parent
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (index, button) in hostedButtons.enumerated() {
            button.setFrameOrigin(NSPoint(
                x: originInParent.x + CGFloat(index) * buttonSpacing,
                y: originInParent.y + (controlHeight - button.frame.height) / 2
            ))
        }

        CATransaction.commit()
    }

    @MainActor
    func restore() {
        for button in hostedButtons {
            button.layer?.mask = nil
            button.isEnabled = true
            button.isHidden = false
        }
        hostedButtons = []
        controller?.detach(self)
    }
}

private struct SidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    let presentation: SidebarPresentation

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        Rectangle()
            .fill(palette.backgroundMaterial)
            .overlay {
                Rectangle()
                    .fill(palette.backgroundTint)
            }
            .overlay {
                LinearGradient(
                    colors: palette.backgroundOverlay,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private struct SidebarTabRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var session: TerminalSession

    let isSelected: Bool
    let presentation: SidebarPresentation
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        Button(action: onSelect) {
            HStack(spacing: session.kind == .agent ? 8 : 0) {
                if let icon = AgentToolIconDescriptor(session: session) {
                    AgentToolIcon(descriptor: icon, isSelected: isSelected, palette: palette)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .lineLimit(1)

                    if !session.sidebarDetail.isEmpty {
                        Text(session.sidebarDetail)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: session.sidebarDetail.isEmpty ? 42 : 50)
            .padding(.leading, SidebarLayout.rowHorizontalInset)
            .padding(.trailing, SidebarLayout.rowHorizontalInset)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                rowBackground(palette: palette)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private func rowBackground(palette: SidebarPalette) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.selectedFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.selectedStroke, lineWidth: 1)
                }
                .shadow(color: palette.selectedShadow, radius: 9, y: 4)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.hoverFill)
        }
    }
}

private struct AgentToolIconDescriptor {
    let label: String
    let logoResourceName: String?
    let rendersAsTemplate: Bool
    let foreground: Color
    let background: Color

    private init(
        label: String,
        logoResourceName: String? = nil,
        rendersAsTemplate: Bool = true,
        foreground: Color,
        background: Color
    ) {
        self.label = label
        self.logoResourceName = logoResourceName
        self.rendersAsTemplate = rendersAsTemplate
        self.foreground = foreground
        self.background = background
    }

    @MainActor
    init?(session: TerminalSession) {
        guard session.kind == .agent else { return nil }

        let displayName = session.agentName != nil ? session.agentName! : session.title
        let name = displayName.lowercased()
        if name.contains("codex") || name.contains("openai") {
            self.init(label: "Cx", logoResourceName: "openai", foreground: .white, background: .black.opacity(0.82))
        } else if name.contains("claude") || name.contains("anthropic") {
            self.init(label: "Cl", logoResourceName: "claude", foreground: Color(red: 0.24, green: 0.16, blue: 0.10), background: Color(red: 0.86, green: 0.70, blue: 0.52))
        } else if name.contains("gemini") {
            self.init(label: "", logoResourceName: "gemini", foreground: .white, background: Color(red: 0.36, green: 0.42, blue: 0.95))
        } else if name.contains("amp") {
            self.init(label: "A", logoResourceName: "amp", rendersAsTemplate: false, foreground: Color(red: 0.95, green: 0.31, blue: 0.25), background: .white.opacity(0.94))
        } else if name == "pi" || name.contains(" pi ") || name.contains("pi.ai") || name.contains("inflection") {
            self.init(label: "Pi", foreground: .white, background: Color(red: 0.12, green: 0.54, blue: 0.53))
        } else {
            return nil
        }
    }
}

private struct AgentToolIcon: View {
    let descriptor: AgentToolIconDescriptor
    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? palette.selectedText.opacity(0.22) : descriptor.background)

            if let logoResourceName = descriptor.logoResourceName {
                AgentLogoImage(
                    resourceName: logoResourceName,
                    rendersAsTemplate: descriptor.rendersAsTemplate,
                    fallbackLabel: descriptor.label
                )
                .frame(width: 13, height: 13)
            } else {
                Text(descriptor.label)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(isSelected ? palette.selectedText : descriptor.foreground)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct AgentLogoImage: View {
    let resourceName: String
    let rendersAsTemplate: Bool
    let fallbackLabel: String

    var body: some View {
        if let image = Self.image(named: resourceName, rendersAsTemplate: rendersAsTemplate) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(rendersAsTemplate ? .template : .original)
                .scaledToFit()
        } else {
            Text(fallbackLabel)
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @MainActor
    private static func image(named name: String, rendersAsTemplate: Bool) -> NSImage? {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "AgentLogos"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "svg"
        )

        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = rendersAsTemplate
        return image
    }
}

private struct SidebarPalette {
    let backgroundMaterial: AnyShapeStyle
    let backgroundTint: Color
    let backgroundOverlay: [Color]
    let headerText: Color
    let rowText: Color
    let selectedText: Color
    let hoverFill: Color
    let selectedFill: Color
    let selectedStroke: Color
    let selectedShadow: Color

    private init(
        backgroundMaterial: AnyShapeStyle,
        backgroundTint: Color,
        backgroundOverlay: [Color],
        headerText: Color,
        rowText: Color,
        selectedText: Color,
        hoverFill: Color,
        selectedFill: Color,
        selectedStroke: Color,
        selectedShadow: Color
    ) {
        self.backgroundMaterial = backgroundMaterial
        self.backgroundTint = backgroundTint
        self.backgroundOverlay = backgroundOverlay
        self.headerText = headerText
        self.rowText = rowText
        self.selectedText = selectedText
        self.hoverFill = hoverFill
        self.selectedFill = selectedFill
        self.selectedStroke = selectedStroke
        self.selectedShadow = selectedShadow
    }

    init(
        themeColors: TerminalThemeColors,
        fallbackColorScheme: ColorScheme,
        presentation: SidebarPresentation
    ) {
        let sample = SidebarThemeSample(themeColors: themeColors, fallbackColorScheme: fallbackColorScheme)
        let background = Color(nsColor: sample.background)
        let shellBackground = Color(nsColor: sample.shellBackground)
        let foreground = Color(nsColor: sample.foreground)
        let selection = sample.selectionBackground.map { Color(nsColor: $0) }

        if sample.isDark {
            self = Self(
                backgroundMaterial: presentation == .floating
                    ? AnyShapeStyle(shellBackground)
                    : AnyShapeStyle(shellBackground),
                backgroundTint: presentation == .floating ? background.opacity(0.10) : .clear,
                backgroundOverlay: [
                    foreground.opacity(presentation == .floating ? 0.035 : 0),
                    .clear
                ],
                headerText: foreground.opacity(0.58),
                rowText: foreground.opacity(0.78),
                selectedText: foreground.opacity(0.96),
                hoverFill: foreground.opacity(0.08),
                selectedFill: selection?.opacity(0.44) ?? foreground.opacity(0.13),
                selectedStroke: foreground.opacity(0.16),
                selectedShadow: Color.black.opacity(presentation == .floating ? 0.22 : 0.16)
            )
        } else {
            self = Self(
                backgroundMaterial: presentation == .floating
                    ? AnyShapeStyle(shellBackground)
                    : AnyShapeStyle(shellBackground),
                backgroundTint: presentation == .floating ? background.opacity(0.08) : .clear,
                backgroundOverlay: [
                    Color.white.opacity(presentation == .floating ? 0.08 : 0),
                    .clear
                ],
                headerText: foreground.opacity(0.52),
                rowText: foreground.opacity(0.74),
                selectedText: foreground.opacity(0.92),
                hoverFill: foreground.opacity(0.06),
                selectedFill: selection?.opacity(0.34) ?? Color.white.opacity(0.64),
                selectedStroke: foreground.opacity(0.10),
                selectedShadow: Color.black.opacity(presentation == .floating ? 0.12 : 0.07)
            )
        }
    }
}

private struct SidebarThemeSample {
    let background: NSColor
    let foreground: NSColor
    let selectionBackground: NSColor?

    var isDark: Bool {
        background.relativeLuminance < 0.50
    }

    var shellBackground: NSColor {
        if isDark {
            background.mixed(toward: foreground, amount: 0.10)
        } else {
            background.mixed(toward: .white, amount: 0.08)
        }
    }

    init(themeColors: TerminalThemeColors, fallbackColorScheme: ColorScheme) {
        let fallbackBackground: NSColor = switch fallbackColorScheme {
        case .light:
            NSColor(calibratedWhite: 0.96, alpha: 1)
        case .dark:
            NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        @unknown default:
            NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        }

        let fallbackForeground: NSColor = switch fallbackColorScheme {
        case .light:
            NSColor(calibratedWhite: 0.08, alpha: 1)
        case .dark:
            NSColor(calibratedWhite: 0.92, alpha: 1)
        @unknown default:
            NSColor(calibratedWhite: 0.92, alpha: 1)
        }

        background = NSColor(hexRGB: themeColors.background) ?? fallbackBackground
        foreground = NSColor(hexRGB: themeColors.foreground) ?? fallbackForeground
        selectionBackground = themeColors.selectionBackground.flatMap(NSColor.init(hexRGB:))
    }
}

extension NSColor {
    convenience init?(hexRGB: String) {
        let trimmed = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("#")

        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }

        // Hex colors from Ghostty themes (and basically every other
        // source — web, design tools, terminal configs) are sRGB by
        // convention. Parsing them as `calibratedRed:` puts the color
        // in the deprecated NSCalibratedRGBColorSpace, which on a
        // Display P3 panel converts to a subtly different on-screen
        // pixel than Ghostty's own Metal renderer produces from the
        // same hex. The result was a visible color seam between the
        // terminal grid (Ghostty-painted) and any region we filled
        // ourselves (document view background, sidebar-animation
        // snapshot fill). Using `srgbRed:` matches Ghostty exactly.
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var relativeLuminance: CGFloat {
        guard let color = usingColorSpace(.sRGB) else { return 0 }

        func channel(_ value: CGFloat) -> CGFloat {
            if value <= 0.04045 {
                value / 12.92
            } else {
                pow((value + 0.055) / 1.055, 2.4)
            }
        }

        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    func mixed(toward otherColor: NSColor, amount: CGFloat) -> NSColor {
        guard let base = usingColorSpace(.sRGB),
              let other = otherColor.usingColorSpace(.sRGB)
        else {
            return self
        }

        let clampedAmount = min(max(amount, 0), 1)
        let inverseAmount = 1 - clampedAmount
        return NSColor(
            calibratedRed: base.redComponent * inverseAmount + other.redComponent * clampedAmount,
            green: base.greenComponent * inverseAmount + other.greenComponent * clampedAmount,
            blue: base.blueComponent * inverseAmount + other.blueComponent * clampedAmount,
            alpha: base.alphaComponent * inverseAmount + other.alphaComponent * clampedAmount
        )
    }
}

private struct TerminalSceneView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: TerminalSession
    @ObservedObject var chromeState: ProjectWindowChromeState

    var body: some View {
        TerminalSurfaceView(session: session, chromeState: chromeState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .ignoresSafeArea(.container, edges: .top)
    }

    private var backgroundColors: [Color] {
        switch colorScheme {
        case .light:
            [
                Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.99, alpha: 1)),
                Color(nsColor: NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.96, alpha: 1))
            ]
        case .dark:
            [
                Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)),
                Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1))
            ]
        @unknown default:
            [
                Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)),
                Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1))
            ]
        }
    }
}
