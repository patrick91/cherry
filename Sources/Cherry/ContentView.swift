import AppKit
import CherryControl
import Combine
import SwiftUI

struct ContentView: View {
    private let minimumSidebarWidth: CGFloat = 190
    private let maximumSidebarWidth: CGFloat = 420
    private let floatingSidebarLeadingInset: CGFloat = SidebarLayout.floatingOuterInset
    private let floatingSidebarTopInset: CGFloat = 3
    private let floatingSidebarBottomInset: CGFloat = 3

    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject var todoStore: ProjectTodoStore
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
                    noteStore: noteStore,
                    todoStore: todoStore,
                    projectRoot: projectRoot,
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
                    chromeState: chromeState,
                    selectedProjectRoot: projectRoot,
                    isPresented: $chromeState.isCommandPalettePresented,
                    focusRequest: chromeState.commandPaletteFocusRequest,
                    openProject: openProject,
                    restoreFocus: restoreTerminalFocus
                )
                .zIndex(2_000)
            }

            if PrototypeFeatureFlags.isIconDebugEnabled,
               chromeState.isIconDebugOverlayPresented {
                SidebarIconDebugOverlay(
                    projectRoot: projectRoot,
                    presentation: isSidebarRevealed ? .floating : .docked,
                    leadingOffset: iconDebugOverlayLeadingOffset,
                    isPresented: $chromeState.isIconDebugOverlayPresented
                )
                .zIndex(2_100)
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
            AppShellBackground(projectRoot: projectRoot)
                .ignoresSafeArea(.all)
        }
        .background(AppShortcutMonitor(
            workspace: workspace,
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
            projectRoot: projectRoot,
            openSettings: { openSettings() }
        ))
        .background(WindowConfigurator())
        .frame(minWidth: 320, minHeight: 460)
        .confirmationDialog(
            "Close Agent Group?",
            isPresented: pendingAgentGroupCloseBinding,
            titleVisibility: .visible
        ) {
            if let session = pendingAgentGroupCloseSession {
                if canCloseAgentGroup(session) {
                    Button("Close Parent and Sub-Agents", role: .destructive) {
                        workspace.closeAgentGroup(session)
                        chromeState.pendingAgentGroupCloseSessionID = nil
                    }
                }

                Button("Close Parent Only") {
                    workspace.closeAgentPromotingChildren(session)
                    chromeState.pendingAgentGroupCloseSessionID = nil
                }
            }

            Button("Cancel", role: .cancel) {
                chromeState.pendingAgentGroupCloseSessionID = nil
            }
        } message: {
            if let session = pendingAgentGroupCloseSession {
                let count = workspace.descendantAgentSessions(of: session).count
                Text("\"\(session.title)\" has \(count) sub-agent\(count == 1 ? "" : "s").")
            }
        }
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
        .onChange(of: agentSettings.projectFeatures(for: projectRoot)) { _, features in
            syncDisabledFeatureSelection(features: features)
        }
        .onAppear {
            storedSidebarWidth = Double(sidebarWidth)
            chromeState.dockedSidebarWidth = sidebarWidth
            syncDisabledFeatureSelection(features: agentSettings.projectFeatures(for: projectRoot))
            trafficLights.seedTarget(
                docked: isSidebarHidden ? 0 : sidebarWidth,
                floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
                sidebarWidth: sidebarWidth
            )
        }
    }

    private func restoreTerminalFocus() {
        DispatchQueue.main.async {
            workspace.selectedSession?.ghosttyBridge.focus(in: NSApp.keyWindow)
        }
    }

    private var pendingAgentGroupCloseBinding: Binding<Bool> {
        Binding {
            chromeState.pendingAgentGroupCloseSessionID != nil
        } set: { isPresented in
            if !isPresented {
                chromeState.pendingAgentGroupCloseSessionID = nil
            }
        }
    }

    private var pendingAgentGroupCloseSession: TerminalSession? {
        guard let id = chromeState.pendingAgentGroupCloseSessionID else { return nil }
        return workspace.sessions.first { $0.id == id }
    }

    private var iconDebugOverlayLeadingOffset: CGFloat {
        let sidebarRightEdge: CGFloat
        if isSidebarRevealed {
            sidebarRightEdge = sidebarWidth + floatingSidebarLeadingInset
        } else if isSidebarHidden {
            sidebarRightEdge = floatingSidebarLeadingInset
        } else {
            sidebarRightEdge = sidebarWidth
        }
        return sidebarRightEdge + 10
    }

    private func canCloseAgentGroup(_ session: TerminalSession) -> Bool {
        workspace.sessions.count > workspace.descendantAgentSessions(of: session).count + 1
    }

    private var dockedSidebar: some View {
        SidebarTabsView(
            workspace: workspace,
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
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
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
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

    private func syncDisabledFeatureSelection(features: ProjectFeatureSettings) {
        if !features.notesEnabled, chromeState.selectedNoteID != nil {
            chromeState.selectTerminal()
        }
        if !features.todosEnabled, chromeState.isTodoPanePresented {
            chromeState.selectTerminal()
        }
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
    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject private var agentSettings = AgentSettings.shared
    let projectRoot: String?
    let includeLeadingPadding: Bool

    var body: some View {
        let features = agentSettings.projectFeatures(for: projectRoot)
        Group {
            if features.notesEnabled, let note = selectedNote {
                NoteDetailView(note: note, noteStore: noteStore)
            } else if features.todosEnabled, chromeState.isTodoPanePresented {
                TodoPaneView(todoStore: todoStore, chromeState: chromeState)
            } else if let idleCommand = focusedIdleCommand {
                IdleCommandView(
                    command: idleCommand,
                    onStart: { startIdleCommand(idleCommand) },
                    onClear: { chromeState.selectTerminal() }
                )
            } else if let session = workspace.selectedSession {
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
        .onChange(of: noteStore.notes) { _, notes in
            guard let selectedID = chromeState.selectedNoteID,
                  !notes.contains(where: { $0.id == selectedID })
            else { return }
            chromeState.selectNote(id: nil)
        }
        .onChange(of: todoStore.todos) { _, todos in
            guard let selectedID = chromeState.selectedTodoID,
                  !todos.contains(where: { $0.id == selectedID })
            else { return }
            chromeState.selectTodo(id: nil)
        }
        .onChange(of: chromeState.isShowingTerminalContent) { _, isShowingTerminalContent in
            guard isShowingTerminalContent else { return }
            workspace.clearUnreadNotificationForSelectedSession()
        }
    }

    private var selectedNote: ProjectNote? {
        guard let selectedID = chromeState.selectedNoteID else { return nil }
        return noteStore.notes.first { $0.id == selectedID }
    }

    private var focusedIdleCommand: ProjectCommandDefinition? {
        guard let name = chromeState.focusedIdleCommandName else { return nil }
        return agentSettings.launchableProjectCommands(for: projectRoot)
            .first { $0.name == name }
    }

    private func startIdleCommand(_ command: ProjectCommandDefinition) {
        guard command.isLaunchable,
              let root = agentSettings.resolvedProject(for: projectRoot).validProjectRoot
        else { return }
        chromeState.selectTerminal()
        workspace.addCommandSession(command: command, projectRoot: root)
    }
}

private struct IdleCommandView: View {
    let command: ProjectCommandDefinition
    let onStart: () -> Void
    let onClear: () -> Void
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private var themeColors: TerminalThemeColors {
        terminalSettings.ghosttyThemeColors(for: colorScheme)
    }

    private var themeBackground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.background) ?? .windowBackgroundColor)
    }

    private var themeForeground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.foreground) ?? .labelColor)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(themeForeground.opacity(0.55))

            VStack(spacing: 4) {
                Text(command.name.isEmpty ? "Command" : command.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(themeForeground)

                Text("Not running")
                    .font(.system(size: 12))
                    .foregroundStyle(themeForeground.opacity(0.55))
            }

            if !command.commandLine.isEmpty {
                Text(command.commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(themeForeground.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(themeForeground.opacity(0.06))
                    }
            }

            HStack(spacing: 10) {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!command.isLaunchable)

                Button("Cancel", action: onClear)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeBackground)
    }
}

private struct NoteDetailView: View {
    let note: ProjectNote
    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var draftTitle: String
    @State private var draftMarkdown: String
    @State private var pendingSave: Task<Void, Never>?

    init(note: ProjectNote, noteStore: ProjectNoteStore) {
        self.note = note
        self.noteStore = noteStore
        _draftTitle = State(initialValue: note.title)
        _draftMarkdown = State(initialValue: note.markdown)
    }

    private var themeColors: TerminalThemeColors {
        terminalSettings.ghosttyThemeColors(for: colorScheme)
    }

    private var themeBackground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.background) ?? .windowBackgroundColor)
    }

    private var themeForeground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.foreground) ?? .labelColor)
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(themeForeground)
                .onSubmit { saveNow() }

            Text("Edited \(note.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11))
                .foregroundStyle(themeForeground.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        MarkdownSourceEditor(
            text: $draftMarkdown,
            themeColors: themeColors,
            header: AnyView(titleHeader)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(themeBackground)
        .contextMenu {
            Button("Copy Link") {
                copyCherryLink(cherryLink(for: note))
            }
        }
        .onChange(of: draftTitle) { _, _ in scheduleSave() }
        .onChange(of: draftMarkdown) { _, _ in scheduleSave() }
        .onChange(of: note.id) { _, _ in
            pendingSave?.cancel()
            draftTitle = note.title
            draftMarkdown = note.markdown
        }
        .onChange(of: note.updatedAt) { _, _ in
            guard draftTitle != note.title || draftMarkdown != note.markdown else { return }
            pendingSave?.cancel()
            draftTitle = note.title
            draftMarkdown = note.markdown
        }
        .onDisappear {
            saveNow()
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard draftTitle != note.title || draftMarkdown != note.markdown else { return }
        _ = try? noteStore.update(id: note.id, title: draftTitle, markdown: draftMarkdown)
    }
}

private struct TodoPaneView: View {
    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private static let compactWidthThreshold: CGFloat = 640

    private var themeColors: TerminalThemeColors {
        terminalSettings.ghosttyThemeColors(for: colorScheme)
    }

    private var themeBackground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.background) ?? .windowBackgroundColor)
    }

    private var themeForeground: Color {
        Color(nsColor: NSColor(hexRGB: themeColors.foreground) ?? .labelColor)
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < Self.compactWidthThreshold
            Group {
                if isCompact {
                    compactBody
                } else {
                    splitBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeBackground)
        }
        .onAppear {
            if chromeState.selectedTodoID == nil {
                chromeState.selectedTodoID = firstSelectableTodo?.id
            }
        }
        .onChange(of: todoStore.todos) { _, todos in
            guard let selectedID = chromeState.selectedTodoID,
                  !todos.contains(where: { $0.id == selectedID })
            else { return }
            chromeState.selectedTodoID = firstSelectableTodo?.id
        }
    }

    private var splitBody: some View {
        HSplitView {
            TodoListPane(
                todoStore: todoStore,
                chromeState: chromeState,
                themeForeground: themeForeground
            )
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)

            Group {
                if let todo = selectedTodo {
                    TodoInspectorPane(
                        todo: todo,
                        todoStore: todoStore,
                        themeForeground: themeForeground,
                        themeColors: themeColors,
                        isCompact: false,
                        onBack: nil
                    )
                    .id(todo.id)
                } else {
                    ContentUnavailableView("No Todo Selected", systemImage: "checklist")
                        .foregroundStyle(themeForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 280)
        }
    }

    @ViewBuilder
    private var compactBody: some View {
        if let todo = selectedTodo {
            TodoInspectorPane(
                todo: todo,
                todoStore: todoStore,
                themeForeground: themeForeground,
                themeColors: themeColors,
                isCompact: true,
                onBack: { chromeState.selectTodo(id: nil) }
            )
            .id(todo.id)
        } else {
            TodoListPane(
                todoStore: todoStore,
                chromeState: chromeState,
                themeForeground: themeForeground
            )
        }
    }

    private var selectedTodo: ProjectTodo? {
        guard let selectedID = chromeState.selectedTodoID else { return nil }
        return todoStore.todos.first { $0.id == selectedID }
    }

    private var firstSelectableTodo: ProjectTodo? {
        todoStore.todos.first { $0.status != .done } ?? todoStore.todos.first
    }
}

private struct TodoListPane: View {
    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject var chromeState: ProjectWindowChromeState
    let themeForeground: Color

    @AppStorage("todos.listStyle") private var listStyleRaw: String = TodoListRowStyle.thingsLike.rawValue
    @State private var collapsedStatuses: Set<TodoStatus> = [.done]

    private var listStyle: Binding<TodoListRowStyle> {
        Binding(
            get: { TodoListRowStyle(rawValue: listStyleRaw) ?? .thingsLike },
            set: { listStyleRaw = $0.rawValue }
        )
    }

    var body: some View {
        let filterTags = availableFilterTags
        let groupedTodos = groupedFilteredTodos
        let filteredTodoCount = groupedTodos.values.reduce(0) { $0 + $1.count }
        let openCount = openTodoCount

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Todos")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(themeForeground.opacity(0.58))

                Rectangle()
                    .fill(themeForeground.opacity(0.18))
                    .frame(height: 1)

                Text("\(openCount)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(themeForeground.opacity(0.58))

                if !chromeState.selectedTodoTagFilterIDs.isEmpty {
                    Button(action: clearTagFilters) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear tag filters")
                }

                Button(action: createTodo) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("New todo")
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, filterTags.isEmpty ? 10 : 6)

            if !filterTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 5) {
                        ForEach(filterTags) { tag in
                            let isSelected = chromeState.selectedTodoTagFilterIDs.contains(tag.id)
                            Button {
                                toggleTagFilter(tag)
                            } label: {
                                TodoTagChip(
                                    tag: tag,
                                    isSelected: isSelected,
                                    showsRemoveButton: false,
                                    size: .small
                                )
                            }
                            .buttonStyle(.plain)
                            .help(isSelected ? "Remove tag filter" : "Filter by tag")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }
                .frame(height: 28, alignment: .top)
            }

            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(TodoStatus.allCases) { status in
                            let todos = groupedTodos[status, default: []]
                            if !todos.isEmpty {
                                TodoStatusGroup(
                                    status: status,
                                    todos: todos,
                                    selectedTodoID: chromeState.selectedTodoID,
                                    themeForeground: themeForeground,
                                    style: listStyle.wrappedValue,
                                    isCollapsed: collapsedStatuses.contains(status),
                                    toggleCollapsed: { toggleCollapsed(status) },
                                    select: { chromeState.selectTodo(id: $0.id) },
                                    moveUp: moveUp,
                                    moveDown: moveDown,
                                    reorder: reorder(_:to:),
                                    moveToStatus: move(_:to:),
                                    delete: delete
                                )
                            }
                        }

                        if todoStore.todos.isEmpty {
                            ContentUnavailableView {
                                Label("No Todos", systemImage: "checklist")
                            } description: {
                                Text("Create one with the + button above.")
                            }
                            .foregroundStyle(themeForeground.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        } else if filteredTodoCount == 0 {
                            ContentUnavailableView {
                                Label("No Matching Todos", systemImage: "tag")
                            } description: {
                                Text("Clear tag filters to show all todos.")
                            }
                            .foregroundStyle(themeForeground.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 56)
                }

                TodoListStylePicker(style: listStyle, themeForeground: themeForeground)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(themeForeground.opacity(0.035))
        .onAppear {
            expandStatusForSelectedTodo(chromeState.selectedTodoID)
        }
        .onChange(of: chromeState.selectedTodoID) { _, selectedID in
            expandStatusForSelectedTodo(selectedID)
        }
    }

    private func todos(in status: TodoStatus) -> [ProjectTodo] {
        filteredTodos.filter { $0.status == status }
    }

    private var groupedFilteredTodos: [TodoStatus: [ProjectTodo]] {
        Dictionary(grouping: filteredTodos, by: \.status)
    }

    private var filteredTodos: [ProjectTodo] {
        let filterIDs = chromeState.selectedTodoTagFilterIDs
        guard !filterIDs.isEmpty else { return todoStore.todos }

        return todoStore.todos.filter { todo in
            todo.tags.contains { filterIDs.contains($0.id) }
        }
    }

    private var availableFilterTags: [TodoTag] {
        let usedIDs = Set(todoStore.todos.flatMap { $0.tags.map(\.id) })
        let visibleIDs = usedIDs.union(chromeState.selectedTodoTagFilterIDs)
        return todoStore.tagCatalog.filter { visibleIDs.contains($0.id) }
    }

    private var openTodoCount: Int {
        todoStore.todos.filter { $0.status != .done }.count
    }

    private func createTodo() {
        if let todo = try? todoStore.create(title: "Untitled Todo", markdown: "", status: .backlog) {
            chromeState.selectTodo(id: todo.id)
        }
    }

    private func moveUp(_ todo: ProjectTodo) {
        let todos = todos(in: todo.status)
        guard let index = todos.firstIndex(where: { $0.id == todo.id }), index > 0 else { return }
        let afterID = index > 1 ? todos[index - 2].id : nil
        _ = try? todoStore.move(id: todo.id, status: nil, afterTodoID: afterID)
    }

    private func moveDown(_ todo: ProjectTodo) {
        let todos = todos(in: todo.status)
        guard let index = todos.firstIndex(where: { $0.id == todo.id }), index < todos.count - 1 else { return }
        _ = try? todoStore.move(id: todo.id, status: nil, afterTodoID: todos[index + 1].id)
    }

    private func reorder(_ todo: ProjectTodo, to targetIndex: Int) {
        _ = try? todoStore.move(id: todo.id, to: targetIndex, within: todo.status)
    }

    private func move(_ todo: ProjectTodo, to status: TodoStatus) {
        _ = try? todoStore.move(id: todo.id, status: status, afterTodoID: nil)
    }

    private func delete(_ todo: ProjectTodo) {
        try? todoStore.delete(id: todo.id)
        if chromeState.selectedTodoID == todo.id {
            chromeState.selectedTodoID = todoStore.todos.first { $0.status != .done }?.id ?? todoStore.todos.first?.id
        }
    }

    private func toggleTagFilter(_ tag: TodoTag) {
        if chromeState.selectedTodoTagFilterIDs.contains(tag.id) {
            chromeState.selectedTodoTagFilterIDs.remove(tag.id)
        } else {
            chromeState.selectedTodoTagFilterIDs.insert(tag.id)
        }
    }

    private func clearTagFilters() {
        chromeState.selectedTodoTagFilterIDs.removeAll()
    }

    private func toggleCollapsed(_ status: TodoStatus) {
        if collapsedStatuses.contains(status) {
            collapsedStatuses.remove(status)
        } else {
            collapsedStatuses.insert(status)
        }
    }

    private func expandStatusForSelectedTodo(_ selectedID: UUID?) {
        guard let selectedID,
              let todo = todoStore.todos.first(where: { $0.id == selectedID })
        else { return }
        collapsedStatuses.remove(todo.status)
    }
}

private enum TodoListRowStyle: String, CaseIterable, Identifiable {
    case thingsLike
    case linearDense
    case stripeCompact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thingsLike: "Things"
        case .linearDense: "Linear"
        case .stripeCompact: "Stripe"
        }
    }

    var symbol: String {
        switch self {
        case .thingsLike: "circle"
        case .linearDense: "list.bullet"
        case .stripeCompact: "rectangle.lefthalf.inset.filled"
        }
    }
}

private struct TodoListStylePicker: View {
    @Binding var style: TodoListRowStyle
    let themeForeground: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TodoListRowStyle.allCases) { option in
                Button {
                    style = option
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(style == option ? themeForeground : themeForeground.opacity(0.5))
                        .frame(width: 26, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(style == option ? themeForeground.opacity(0.15) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(themeForeground.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

private struct TodoStatusGroup: View {
    let status: TodoStatus
    let todos: [ProjectTodo]
    let selectedTodoID: UUID?
    let themeForeground: Color
    let style: TodoListRowStyle
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let select: (ProjectTodo) -> Void
    let moveUp: (ProjectTodo) -> Void
    let moveDown: (ProjectTodo) -> Void
    let reorder: (ProjectTodo, Int) -> Void
    let moveToStatus: (ProjectTodo, TodoStatus) -> Void
    let delete: (ProjectTodo) -> Void

    @State private var draggedTodoID: UUID?
    @State private var draggedRowOffsetY: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggleCollapsed) {
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Image(systemName: status.symbolName)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(status.displayName.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.6)
                    Spacer(minLength: 4)
                    Text("\(todos.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(themeForeground.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(themeForeground.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            if !isCollapsed {
                ForEach(todos) { todo in
                    TodoListRow(
                        todo: todo,
                        isSelected: selectedTodoID == todo.id,
                        themeForeground: themeForeground,
                        style: style,
                        action: { select(todo) }
                    )
                    .offset(y: draggedTodoID == todo.id ? draggedRowOffsetY : 0)
                    .zIndex(draggedTodoID == todo.id ? 1 : 0)
                    .anchorPreference(key: SidebarRowBoundsPreferenceKey.self, value: .bounds) { anchor in
                        [todo.id: anchor]
                    }
                    .contextMenu {
                        Button("Copy Link") {
                            copyCherryLink(cherryLink(for: todo))
                        }

                        Divider()

                        Button("Move Up") { moveUp(todo) }
                        Button("Move Down") { moveDown(todo) }

                        Menu("Move to Status") {
                            ForEach(TodoStatus.allCases) { targetStatus in
                                Button(targetStatus.displayName) {
                                    moveToStatus(todo, targetStatus)
                                }
                                .disabled(targetStatus == todo.status)
                            }
                        }

                        Divider()

                        Button("Delete", role: .destructive) {
                            delete(todo)
                        }
                    }
                }
            }
        }
        .overlayPreferenceValue(SidebarRowBoundsPreferenceKey.self) { rowBounds in
            if !isCollapsed {
                GeometryReader { geometry in
                    SidebarInteractionOverlay(
                        rows: todos.compactMap { todo in
                            rowBounds[todo.id].map { anchor in
                                SidebarRowFrame(id: todo.id, rect: geometry[anchor].insetBy(dx: -4, dy: -3))
                            }
                        },
                        onSelect: { todoID in
                            guard let todo = todos.first(where: { $0.id == todoID }) else { return }
                            select(todo)
                        },
                        onDragChanged: { todoID, offsetY in
                            draggedTodoID = todoID
                            draggedRowOffsetY = offsetY
                        },
                        onMove: { todoID, targetIndex in
                            guard let todo = todos.first(where: { $0.id == todoID }) else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                reorder(todo, targetIndex)
                            }
                        },
                        onDragEnded: {
                            withAnimation(.snappy(duration: 0.16)) {
                                draggedTodoID = nil
                                draggedRowOffsetY = 0
                            }
                        }
                    )
                }
            }
        }
    }
}

private struct TodoListRow: View {
    let todo: ProjectTodo
    let isSelected: Bool
    let themeForeground: Color
    let style: TodoListRowStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(themeForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? themeForeground.opacity(0.13) : Color.clear)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .thingsLike: thingsLikeRow
        case .linearDense: linearDenseRow
        case .stripeCompact: stripeCompactRow
        }
    }

    // MARK: - Things-like row

    private var thingsLikeRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: todo.status == .done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(themeForeground.opacity(todo.status == .done ? 0.55 : 0.4))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 13.5, weight: .regular))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .strikethrough(todo.status == .done, color: themeForeground.opacity(0.4))
                    .opacity(todo.status == .done ? 0.6 : 1)

                inlineMetaRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var inlineMetaRow: some View {
        HStack(spacing: 7) {
            if !todo.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(todo.tags.prefix(4))) { tag in
                        Circle()
                            .fill(tagColor(for: tag))
                            .frame(width: 6, height: 6)
                    }
                    if todo.tags.count > 4 {
                        Text("+\(todo.tags.count - 4)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(themeForeground.opacity(0.45))
                            .padding(.leading, 1)
                    }
                }
                .help(todo.tags.map(\.name).joined(separator: ", "))
            }

            Text(TodoListRow.relativeTimeString(for: todo.updatedAt))

            if !todo.comments.isEmpty {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                Text("\(todo.comments.count)")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(themeForeground.opacity(0.5))
    }

    // MARK: - Linear-dense row

    private var linearDenseRow: some View {
        HStack(spacing: 8) {
            Image(systemName: linearStatusSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(themeForeground.opacity(0.55))
                .frame(width: 14)

            Text(displayTitle)
                .font(.system(size: 12.5, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(todo.status == .done, color: themeForeground.opacity(0.4))
                .opacity(todo.status == .done ? 0.55 : 1)

            Spacer(minLength: 6)

            if !todo.comments.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                    Text("\(todo.comments.count)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .foregroundStyle(themeForeground.opacity(0.45))
            }

            if !todo.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(todo.tags.prefix(3))) { tag in
                        Circle()
                            .fill(tagColor(for: tag))
                            .frame(width: 7, height: 7)
                    }
                    if todo.tags.count > 3 {
                        Text("·")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(themeForeground.opacity(0.55))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help(linearTooltip)
    }

    private var linearStatusSymbol: String {
        switch todo.status {
        case .backlog: "circle"
        case .ready: "circle.dotted"
        case .doing: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    private var linearTooltip: String {
        let tagNames = todo.tags.map(\.name).joined(separator: ", ")
        let time = TodoListRow.relativeTimeString(for: todo.updatedAt)
        if tagNames.isEmpty {
            return "\(displayTitle)\nUpdated \(time)"
        }
        return "\(displayTitle)\n\(tagNames)\nUpdated \(time)"
    }

    // MARK: - Stripe + compact row

    private var stripeCompactRow: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(stripeColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(todo.status == .done, color: themeForeground.opacity(0.4))
                    .opacity(todo.status == .done ? 0.6 : 1)

                HStack(spacing: 8) {
                    if !todo.tags.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(todo.tags.prefix(2))) { tag in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(softenedTagColor(for: tag))
                                        .frame(width: 6, height: 6)
                                    Text(tag.name.lowercased())
                                        .font(.system(size: 11))
                                        .foregroundStyle(themeForeground.opacity(0.65))
                                        .lineLimit(1)
                                }
                            }
                            if todo.tags.count > 2 {
                                Text("+\(todo.tags.count - 2)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(themeForeground.opacity(0.45))
                            }
                        }
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(themeForeground.opacity(0.3))
                    }
                    Text(TodoListRow.relativeTimeString(for: todo.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(themeForeground.opacity(0.5))
                    if !todo.comments.isEmpty {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(themeForeground.opacity(0.3))
                        HStack(spacing: 2) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                            Text("\(todo.comments.count)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                        }
                        .foregroundStyle(themeForeground.opacity(0.5))
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
    }

    private var stripeColor: Color {
        if let firstTag = todo.tags.first {
            return softenedTagColor(for: firstTag)
        }
        return themeForeground.opacity(0.2)
    }

    // MARK: - Shared helpers

    private var displayTitle: String {
        todo.title.isEmpty ? "Untitled Todo" : todo.title
    }

    private func tagColor(for tag: TodoTag) -> Color {
        Color(nsColor: NSColor(hexRGB: tag.colorHex) ?? .controlAccentColor)
    }

    private func softenedTagColor(for tag: TodoTag) -> Color {
        let base = (NSColor(hexRGB: tag.colorHex) ?? .controlAccentColor)
            .usingColorSpace(.deviceRGB) ?? .controlAccentColor
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let softened = NSColor(
            hue: h,
            saturation: min(s, 0.55),
            brightness: min(b, 0.78),
            alpha: a
        )
        return Color(nsColor: softened)
    }

    static func relativeTimeString(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3_600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h ago" }
        if interval < 604_800 { return "\(Int(interval / 86_400))d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private enum TodoTagChipSize {
    case small
    case regular

    var fontSize: CGFloat {
        switch self {
        case .small:
            10
        case .regular:
            11.5
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small:
            7
        case .regular:
            9
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small:
            2
        case .regular:
            3
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .small:
            110
        case .regular:
            160
        }
    }
}

private struct TodoTagChip: View {
    let tag: TodoTag
    let isSelected: Bool
    let showsRemoveButton: Bool
    let size: TodoTagChipSize

    private var nsColor: NSColor {
        NSColor(hexRGB: tag.colorHex) ?? .controlAccentColor
    }

    private var color: Color {
        Color(nsColor: nsColor)
    }

    private var textColor: Color {
        Color(nsColor: nsColor.relativeLuminance > 0.55 ? .black : .white)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)

            if showsRemoveButton {
                Image(systemName: "xmark")
                    .font(.system(size: size.fontSize - 1, weight: .bold))
                    .opacity(0.75)
            }
        }
        .font(.system(size: size.fontSize, weight: .semibold))
        .foregroundStyle(textColor)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .frame(maxWidth: size.maxWidth)
        .background {
            Capsule(style: .continuous)
                .fill(color)
        }
        .opacity(dimsWhenInactive && !isSelected ? 0.55 : 1)
        .contentShape(Capsule(style: .continuous))
    }

    private var dimsWhenInactive: Bool {
        // Filter-row chips (regular size) act as toggles; the small variant in
        // list rows is purely informational and should always render at full
        // strength.
        size == .regular && showsRemoveButton == false
    }
}

private struct TodoInspectorPane: View {
    let todo: ProjectTodo
    @ObservedObject var todoStore: ProjectTodoStore
    let themeForeground: Color
    let themeColors: TerminalThemeColors
    let isCompact: Bool
    let onBack: (() -> Void)?

    @State private var draftTitle: String
    @State private var draftMarkdown: String
    @State private var draftStatus: TodoStatus
    @State private var draftTagNames: [String]
    @State private var draftTagInput = ""
    @State private var draftComment = ""
    @State private var pendingSave: Task<Void, Never>?
    @State private var detailsContentHeight: CGFloat = 0

    init(
        todo: ProjectTodo,
        todoStore: ProjectTodoStore,
        themeForeground: Color,
        themeColors: TerminalThemeColors,
        isCompact: Bool,
        onBack: (() -> Void)?
    ) {
        self.todo = todo
        self.todoStore = todoStore
        self.themeForeground = themeForeground
        self.themeColors = themeColors
        self.isCompact = isCompact
        self.onBack = onBack
        _draftTitle = State(initialValue: todo.title)
        _draftMarkdown = State(initialValue: todo.markdown)
        _draftStatus = State(initialValue: todo.status)
        _draftTagNames = State(initialValue: todo.tags.map(\.name))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let onBack {
                    Button {
                        onBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Todos")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(themeForeground.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Untitled Todo", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: isCompact ? 22 : 26, weight: .bold))
                        .foregroundStyle(themeForeground)
                        .onSubmit { saveNow() }

                    statusRow
                }

                tagsSection

                detailsSection

                commentsSection
            }
            .padding(.horizontal, isCompact ? 18 : 26)
            .padding(.top, 4)
            .padding(.bottom, isCompact ? 18 : 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(themeForeground)
        .contextMenu {
            Button("Copy Link") {
                copyCherryLink(cherryLink(for: todo))
            }
        }
        .onChange(of: draftTitle) { _, _ in scheduleSave() }
        .onChange(of: draftMarkdown) { _, _ in scheduleSave() }
        .onChange(of: draftStatus) { _, _ in saveNow() }
        .onChange(of: todo.id) { _, _ in resetDrafts() }
        .onChange(of: todo.updatedAt) { _, _ in
            guard draftTitle != todo.title || draftMarkdown != todo.markdown || draftStatus != todo.status || draftTagNames != todo.tags.map(\.name) else { return }
            resetDrafts()
        }
        .onDisappear {
            saveNow()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 6) {
                statusPicker
                timestampLabel
            }
        } else {
            HStack(spacing: 10) {
                statusPicker
                timestampLabel
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    private var timestampLabel: some View {
        Text(timestampText)
            .font(.system(size: 11))
            .foregroundStyle(themeForeground.opacity(0.5))
            .help(timestampTooltip)
    }

    private var timestampText: String {
        let createdText = "Created \(todo.createdAt.formatted(.relative(presentation: .named)))"
        let updatedAt = todo.updatedAt
        let createdAt = todo.createdAt
        let sameMinute = abs(updatedAt.timeIntervalSince(createdAt)) < 60
        if sameMinute {
            return createdText
        }
        let editedText = "Edited \(updatedAt.formatted(.relative(presentation: .named)))"
        return "\(createdText) · \(editedText)"
    }

    private var timestampTooltip: String {
        let createdAbs = todo.createdAt.formatted(date: .abbreviated, time: .shortened)
        let updatedAbs = todo.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "Created \(createdAbs)\nEdited \(updatedAbs)"
    }

    private var statusPicker: some View {
        Picker("Status", selection: $draftStatus) {
            ForEach(TodoStatus.allCases) { status in
                Label(status.displayName, systemImage: status.symbolName)
                    .tag(status)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Details")

            ZStack(alignment: .topLeading) {
                if draftMarkdown.isEmpty {
                    Text("Add notes, links, or context — Markdown supported.")
                        .font(.system(size: 15))
                        .foregroundStyle(themeForeground.opacity(0.35))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }

                MarkdownSourceEditor(
                    text: $draftMarkdown,
                    themeColors: themeColors,
                    maxContentWidth: .greatestFiniteMagnitude,
                    minHorizontalInset: 0,
                    verticalInset: 4,
                    headerSpacing: 0,
                    bodyFontSize: 15,
                    useMonospacedFont: false,
                    onContentHeightChange: { detailsContentHeight = $0 }
                )
                .frame(height: max(120, detailsContentHeight))
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("Tags")
                Spacer(minLength: 8)
                if !availableTagSuggestions.isEmpty {
                    Menu {
                        ForEach(availableTagSuggestions) { tag in
                            Button(tag.name) {
                                addTag(tag.name)
                            }
                        }
                    } label: {
                        Image(systemName: "tag")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add existing tag")
                }
            }

            if displayTags.isEmpty {
                Text("No tags.")
                    .font(.system(size: 12))
                    .foregroundStyle(themeForeground.opacity(0.45))
                    .padding(.vertical, 2)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 78), spacing: 6, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(displayTags) { tag in
                        Button {
                            removeTag(tag)
                        } label: {
                            TodoTagChip(
                                tag: tag,
                                isSelected: false,
                                showsRemoveButton: true,
                                size: .regular
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag")
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add tag", text: $draftTagInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit(addTagFromInput)

                Button(action: addTagFromInput) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(normalizedDraftTagName(draftTagInput) == nil)
                .help("Add tag")
            }
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sectionHeader("Comments")
                if !todo.comments.isEmpty {
                    Text("\(todo.comments.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(themeForeground.opacity(0.45))
                }
            }

            if !todo.comments.isEmpty {
                ForEach(todo.comments) { comment in
                    commentRow(comment)
                }
            }

            commentComposer
        }
    }

    private func commentRow(_ comment: TodoComment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(comment.authorLabel)
                    .font(.system(size: 12, weight: .semibold))
                Text(comment.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(themeForeground.opacity(0.48))
            }
            Text(comment.markdown)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(themeForeground)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(themeForeground.opacity(0.05))
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draftComment.isEmpty {
                    Text("Write a comment…")
                        .font(.system(size: 13))
                        .foregroundStyle(themeForeground.opacity(0.35))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 13)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draftComment)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64)
                    .padding(8)
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(themeForeground.opacity(0.055))
            }

            Button("Add Comment", action: addComment)
                .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(themeForeground.opacity(0.55))
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard draftTitle != todo.title || draftMarkdown != todo.markdown || draftStatus != todo.status || draftTagNames != todo.tags.map(\.name) else { return }
        _ = try? todoStore.update(
            id: todo.id,
            title: draftTitle,
            markdown: draftMarkdown,
            status: draftStatus,
            tags: draftTagNames
        )
    }

    private func resetDrafts() {
        pendingSave?.cancel()
        pendingSave = nil
        draftTitle = todo.title
        draftMarkdown = todo.markdown
        draftStatus = todo.status
        draftTagNames = todo.tags.map(\.name)
        draftTagInput = ""
    }

    private var displayTags: [TodoTag] {
        draftTagNames.compactMap { name in
            guard let normalized = normalizedDraftTagName(name) else { return nil }
            let id = draftTagID(forNormalizedName: normalized)
            if let existing = todoStore.tagCatalog.first(where: { $0.id == id }) {
                return existing
            }
            return TodoTag(id: id, name: normalized, colorHex: "#0366D6")
        }
    }

    private var availableTagSuggestions: [TodoTag] {
        let selectedIDs = Set(displayTags.map(\.id))
        return todoStore.tagCatalog.filter { !selectedIDs.contains($0.id) }
    }

    private func addTagFromInput() {
        addTag(draftTagInput)
    }

    private func addTag(_ name: String) {
        guard let normalized = normalizedDraftTagName(name) else { return }
        let id = draftTagID(forNormalizedName: normalized)
        guard !displayTags.contains(where: { $0.id == id }) else {
            draftTagInput = ""
            return
        }
        draftTagNames.append(normalized)
        draftTagInput = ""
        saveNow()
    }

    private func removeTag(_ tag: TodoTag) {
        draftTagNames.removeAll { name in
            guard let normalized = normalizedDraftTagName(name) else { return true }
            return draftTagID(forNormalizedName: normalized) == tag.id
        }
        saveNow()
    }

    private func normalizedDraftTagName(_ name: String) -> String? {
        let normalized = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private func draftTagID(forNormalizedName name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private func addComment() {
        let markdown = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return }
        draftComment = ""
        _ = try? todoStore.addComment(
            id: todo.id,
            markdown: markdown,
            authorLabel: "You",
            authorTerminalID: nil,
            authorAgentName: nil
        )
    }
}

private extension TodoStatus {
    var displayName: String {
        switch self {
        case .backlog:
            "Backlog"
        case .ready:
            "Ready"
        case .doing:
            "Doing"
        case .blocked:
            "Blocked"
        case .done:
            "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .backlog:
            "tray"
        case .ready:
            "circle"
        case .doing:
            "play.circle"
        case .blocked:
            "exclamationmark.octagon"
        case .done:
            "checkmark.circle"
        }
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
            AppShellBackground(projectRoot: nil)
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
    let projectRoot: String?

    var body: some View {
        SidebarBackground(projectRoot: projectRoot, presentation: .docked)
    }
}

private enum CommandPaletteMode {
    case commands
    case projects
    case agents
    case agentPresets
}

enum CommandPaletteCommand: String, CaseIterable, Identifiable {
    case projects
    case addProject
    case agents
    case addAgent
    case toggleAppearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .addProject: "Add Project"
        case .agents: "Agents"
        case .addAgent: "Add Agent"
        case .toggleAppearance: "Toggle Light/Dark Mode"
        }
    }

    var subtitle: String {
        switch self {
        case .projects: "Switch project"
        case .addProject: "Create a Cherry project"
        case .agents: "Open a configured agent"
        case .addAgent: "Configure a global agent tool"
        case .toggleAppearance: "Switch app appearance"
        }
    }

    var icon: String {
        switch self {
        case .projects: "folder"
        case .addProject: "folder.badge.plus"
        case .agents: "sparkles"
        case .addAgent: "sparkles"
        case .toggleAppearance: "circle.lefthalf.filled"
        }
    }

    func matches(_ query: String) -> Bool {
        CommandPaletteMatcher.matches(query: query, fields: [title, subtitle])
    }
}

enum CommandPaletteMatcher {
    static func matches(query: String, fields: [String]) -> Bool {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        return tokens.allSatisfy { token in
            fields.contains { field in
                fieldMatches(token, in: field)
            }
        }
    }

    private static func fieldMatches(_ token: String, in field: String) -> Bool {
        let normalizedToken = normalized(token)
        guard !normalizedToken.isEmpty else { return true }

        let normalizedField = normalized(field)
        var fieldIndex = normalizedField.startIndex
        for character in normalizedToken {
            guard let matchIndex = normalizedField[fieldIndex...].firstIndex(of: character) else {
                return false
            }
            fieldIndex = normalizedField.index(after: matchIndex)
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

enum CommandPaletteRootItem: Identifiable, Equatable {
    case command(CommandPaletteCommand)
    case agent(ResolvedAgentTool)
    case project(CherryProject)

    var id: String {
        switch self {
        case .command(let command):
            "command:\(command.id)"
        case .agent(let agent):
            "agent:\(agent.id)"
        case .project(let project):
            "project:\(project.root)"
        }
    }

    var icon: String {
        switch self {
        case .command(let command):
            command.icon
        case .agent:
            "terminal"
        case .project:
            "folder.fill"
        }
    }

    var title: String {
        switch self {
        case .command(let command):
            command.title
        case .agent(let agent):
            agent.name
        case .project(let project):
            project.name
        }
    }

    var subtitle: String {
        switch self {
        case .command(let command):
            command.subtitle
        case .agent(let agent):
            agent.commandLine
        case .project(let project):
            project.root
        }
    }

    static func filteredItems(
        query: String,
        agents: [ResolvedAgentTool],
        projects: [CherryProject]
    ) -> [CommandPaletteRootItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = CommandPaletteCommand.allCases
            .filter { $0.matches(query) }
            .map(CommandPaletteRootItem.command)
        let matchedAgents = agents
            .filter { agent in
                guard !normalizedQuery.isEmpty else { return true }
                return CommandPaletteMatcher.matches(query: normalizedQuery, fields: [
                    agent.name,
                    agent.commandLine
                ])
            }
            .map(CommandPaletteRootItem.agent)
        let matchedProjects = normalizedQuery.isEmpty
            ? []
            : projects
                .filter { project in
                    CommandPaletteMatcher.matches(query: normalizedQuery, fields: [
                        project.name,
                        project.root
                    ])
                }
                .map(CommandPaletteRootItem.project)

        return commands + matchedAgents + matchedProjects
    }

    func isCurrent(selectedProjectRoot: String?) -> Bool {
        switch self {
        case .command, .agent:
            false
        case .project(let project):
            project.root == selectedProjectRoot
        }
    }
}

private struct CommandPaletteOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: AgentSettings
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let selectedProjectRoot: String?
    @Binding var isPresented: Bool
    let focusRequest: Int
    let openProject: (CherryProject) -> Void
    let restoreFocus: () -> Void

    @State private var mode = CommandPaletteMode.commands
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var scrollTopIndex = 0
    @State private var editingAgent: AgentToolDefinition?
    @State private var agentError: String?
    @State private var searchFocusRequest = 0

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

                    CommandPaletteSearchField(
                        text: $query,
                        placeholder: prompt,
                        focusRequest: searchFocusRequest,
                        onSubmit: commitSelection
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)

                Divider()

                ScrollViewReader { proxy in
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
                    .onChange(of: selectedIndex) { _, _ in
                        scrollSelectionIntoView(proxy)
                    }
                    .onChange(of: mode) { _, _ in
                        resetPaletteScroll(proxy)
                    }
                    .onChange(of: query) { _, _ in
                        resetPaletteScroll(proxy)
                    }
                }
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
            requestSearchFocus()
            selectedIndex = 0
        }
        .onChange(of: focusRequest) { _, _ in
            requestSearchFocus()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            scrollTopIndex = 0
        }
        .onChange(of: mode) { _, _ in
            query = ""
            selectedIndex = 0
            scrollTopIndex = 0
            requestSearchFocus()
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

    private var filteredRootItems: [CommandPaletteRootItem] {
        CommandPaletteRootItem.filteredItems(
            query: query,
            agents: settings.resolvedProject(for: selectedProjectRoot).launchableAgents,
            projects: settings.projects
        )
    }

    private var filteredProjects: [CherryProject] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return settings.projects }
        return settings.projects.filter { project in
            CommandPaletteMatcher.matches(query: normalizedQuery, fields: [
                project.name,
                project.root
            ])
        }
    }

    private var filteredAgents: [ResolvedAgentTool] {
        let agents = settings.resolvedProject(for: selectedProjectRoot).launchableAgents
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return agents }
        return agents.filter { agent in
            CommandPaletteMatcher.matches(query: normalizedQuery, fields: [
                agent.name,
                agent.commandLine
            ])
        }
    }

    private var filteredAgentPresets: [AgentToolDefinition] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return AgentConfiguration.presets }
        return AgentConfiguration.presets.filter { preset in
            CommandPaletteMatcher.matches(query: normalizedQuery, fields: [
                preset.name,
                preset.commandLine
            ])
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
                    isCurrent: item.isCurrent(selectedProjectRoot: selectedProjectRoot)
                ) {
                    selectedIndex = index
                    commitSelection()
                }
                .id(rowID(for: index))
            }
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        if filteredProjects.isEmpty {
            VStack(spacing: 4) {
                CommandPaletteEmptyRow(title: "No projects")
                CommandPaletteRow(
                    icon: CommandPaletteCommand.addProject.icon,
                    title: CommandPaletteCommand.addProject.title,
                    subtitle: CommandPaletteCommand.addProject.subtitle,
                    isSelected: selectedIndex == 0,
                    isCurrent: false,
                    action: chooseProjectRoot
                )
                .id(rowID(for: 0))
            }
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
                .id(rowID(for: index))
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
                .id(rowID(for: index))
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
                .id(rowID(for: index))
            }
        }
    }

    private var resultCount: Int {
        switch mode {
        case .commands: filteredRootItems.count
        case .projects: max(1, filteredProjects.count)
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

    private func rowID(for index: Int) -> String {
        "\(rowIDPrefix)-\(index)"
    }

    private var visibleRowCount: Int {
        6
    }

    private var rowIDPrefix: String {
        switch mode {
        case .commands: "commands"
        case .projects: "projects"
        case .agents: "agents"
        case .agentPresets: "agentPresets"
        }
    }

    private func scrollSelectionIntoView(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard resultCount > 0 else { return }
        let lastPossibleTopIndex = max(0, resultCount - visibleRowCount)
        let nextTopIndex: Int
        if selectedIndex < scrollTopIndex {
            nextTopIndex = selectedIndex
        } else if selectedIndex >= scrollTopIndex + visibleRowCount {
            nextTopIndex = selectedIndex - visibleRowCount + 1
        } else {
            return
        }

        scrollTopIndex = min(max(nextTopIndex, 0), lastPossibleTopIndex)
        scrollToTopIndex(proxy, animated: animated)
    }

    private func resetPaletteScroll(_ proxy: ScrollViewProxy) {
        scrollTopIndex = 0
        scrollToTopIndex(proxy, animated: false)
    }

    private func scrollToTopIndex(_ proxy: ScrollViewProxy, animated: Bool) {
        let id = rowID(for: scrollTopIndex)
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            } else {
                proxy.scrollTo(id, anchor: .top)
            }
        }
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
                case .addProject:
                    chooseProjectRoot()
                case .agents:
                    mode = .agents
                case .addAgent:
                    mode = .agentPresets
                case .toggleAppearance:
                    terminalSettings.toggleLightDarkAppearance(currentColorScheme: colorScheme)
                    dismiss()
                }
            case .agent(let agent):
                launch(agent)
            case .project(let project):
                dismiss()
                openProject(project)
            }
        case .projects:
            if filteredProjects.isEmpty {
                chooseProjectRoot()
                return
            }
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
        chromeState.selectTerminal()
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

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK, let url = panel.url,
              let project = settings.addProject(path: url.path)
        else {
            requestSearchFocus()
            return
        }

        dismiss()
        openProject(project)
    }

    private func dismiss() {
        isPresented = false
        restoreFocus()
    }

    private func requestSearchFocus() {
        searchFocusRequest &+= 1
    }
}

private struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> CommandPaletteSearchTextField {
        let textField = CommandPaletteSearchTextField()
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit(_:))
        textField.onMoveToWindow = { [weak coordinator = context.coordinator] textField in
            coordinator?.requestFocus(for: textField)
        }
        configure(textField)
        return textField
    }

    func updateNSView(_ nsView: CommandPaletteSearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        configure(nsView)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            context.coordinator.requestFocus(for: nsView)
        }
    }

    private func configure(_ textField: NSTextField) {
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 17)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityLabel("Command Palette Search")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var lastFocusRequest: Int?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField,
                  text.wrappedValue != textField.stringValue
            else {
                return
            }

            text.wrappedValue = textField.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            onSubmit()
        }

        func requestFocus(for textField: NSTextField, remainingAttempts: Int = 5) {
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self, let textField else { return }
                guard let window = textField.window else {
                    retryFocus(for: textField, remainingAttempts: remainingAttempts)
                    return
                }

                if !window.isKeyWindow {
                    window.makeKeyAndOrderFront(nil)
                }

                window.makeFirstResponder(textField)
                if let editor = textField.currentEditor() {
                    editor.selectedRange = NSRange(location: textField.stringValue.utf16.count, length: 0)
                } else {
                    retryFocus(for: textField, remainingAttempts: remainingAttempts)
                }
            }
        }

        private func retryFocus(for textField: NSTextField, remainingAttempts: Int) {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak textField] in
                guard let self, let textField else { return }
                requestFocus(for: textField, remainingAttempts: remainingAttempts - 1)
            }
        }
    }
}

private final class CommandPaletteSearchTextField: NSTextField {
    var onMoveToWindow: ((CommandPaletteSearchTextField) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMoveToWindow?(self)
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
    static let agentTreeRowSpacing: CGFloat = 4
}

private enum AgentTreeLayout {
    static let tuningEnvironmentKey = "CHERRY_AGENT_TREE_TUNING"

    static let guideXKey = "agentTree.guideX"
    static let guideElbowWidthKey = "agentTree.guideElbowWidth"
    static let guideElbowStartInsetKey = "agentTree.guideElbowStartInset"
    static let guideConnectorLengthKey = "agentTree.guideConnectorLength"
    static let guideConnectorDashLengthKey = "agentTree.guideConnectorDashLength"
    static let guideConnectorDashGapKey = "agentTree.guideConnectorDashGap"
    static let guideConnectorOffsetXKey = "agentTree.guideConnectorOffsetX"
    static let guideConnectorOffsetYKey = "agentTree.guideConnectorOffsetY"
    static let disclosureOffsetKey = "agentTree.disclosureOffset"
    static let guideTopOverlapKey = "agentTree.guideTopOverlap"
    static let guideBottomOverlapKey = "agentTree.guideBottomOverlap"
    static let childRowHeightKey = "agentTree.childRowHeight"
    static let childDetailRowHeightKey = "agentTree.childDetailRowHeight"

    static let defaultGuideX = 0.0
    static let defaultGuideElbowWidth = 5.5
    static let defaultGuideElbowStartInset = 1.0
    static let defaultGuideConnectorLength = 10.0
    static let defaultGuideConnectorDashLength = 1.5
    static let defaultGuideConnectorDashGap = 3.0
    static let defaultGuideConnectorOffsetX = 0.5
    static let defaultGuideConnectorOffsetY = -11.0
    static let defaultDisclosureOffset = -6.0
    static let defaultGuideTopOverlap = 0.0
    static let defaultGuideBottomOverlap = 1.0
    static let defaultChildRowHeight = 32.0
    static let defaultChildDetailRowHeight = 38.0

    static var isTuningEnabled: Bool {
        truthyEnvironmentValue(for: tuningEnvironmentKey)
    }

    private static func truthyEnvironmentValue(for key: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }
}

enum PrototypeFeatureFlags {
    static var isIconDebugEnabled: Bool {
        truthyEnvironmentValue(for: "CHERRY_ICON_DEBUG")
    }

    private static func truthyEnvironmentValue(for key: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }
}

@MainActor
private func copyCherryLink(_ link: String?) {
    guard let link, !link.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link, forType: .string)
}

private func cherryLink(for note: ProjectNote) -> String {
    CherryDeepLink.noteURL(projectRoot: note.projectRoot, noteID: note.id)
}

private func cherryLink(for todo: ProjectTodo) -> String {
    CherryDeepLink.todoURL(projectRoot: todo.projectRoot, todoID: todo.id)
}

private func cherryLink(for session: TerminalSession, projectRoot: String?) -> String? {
    guard let projectRoot else { return nil }
    return CherryDeepLink.terminalURL(projectRoot: projectRoot, terminalID: session.id)
}

private struct SidebarTabsView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void

    var body: some View {
        let features = agentSettings.projectFeatures(for: projectRoot)
        let visibleAgentCount = workspace.visibleAgentSessions(
            collapsedIDs: chromeState.collapsedAgentGroupIDs
        ).count
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SidebarAgentSessionSection(
                        settings: agentSettings,
                        workspace: workspace,
                        chromeState: chromeState,
                        projectRoot: projectRoot,
                        presentation: presentation,
                        showShortcutHints: chromeState.isCommandKeyPressed,
                        openSettings: { openSettings() }
                    )

                    SidebarSessionSection(
                        title: "Terminals",
                        sessions: workspace.terminalSessions,
                        kind: .terminal,
                        workspace: workspace,
                        chromeState: chromeState,
                        projectRoot: projectRoot,
                        presentation: presentation,
                        shortcutStartIndex: visibleAgentCount,
                        showShortcutHints: chromeState.isCommandKeyPressed
                    )

                    SidebarCommandSection(
                        settings: agentSettings,
                        workspace: workspace,
                        chromeState: chromeState,
                        projectRoot: projectRoot,
                        presentation: presentation,
                        shortcutStartIndex: visibleAgentCount + workspace.terminalSessions.count,
                        showShortcutHints: chromeState.isCommandKeyPressed
                    )

                    if features.todosEnabled {
                        SidebarTodosSection(
                            todoStore: todoStore,
                            chromeState: chromeState,
                            projectRoot: projectRoot,
                            presentation: presentation,
                            shortcutNumber: todoBoardShortcutNumber,
                            showShortcutHint: chromeState.isCommandKeyPressed
                        )
                    }

                    if features.notesEnabled {
                        SidebarNotesSection(
                            noteStore: noteStore,
                            chromeState: chromeState,
                            projectRoot: projectRoot,
                            presentation: presentation,
                            shortcutStartIndex: notesShortcutStartIndex(features: features),
                            showShortcutHints: chromeState.isCommandKeyPressed
                        )
                    }
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
                SidebarBackground(projectRoot: projectRoot, presentation: presentation)
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

    private var todoBoardShortcutNumber: Int {
        workspace.visibleAgentSessions(collapsedIDs: chromeState.collapsedAgentGroupIDs).count
            + workspace.terminalSessions.count
            + agentSettings.launchableProjectCommands(for: projectRoot).count
            + 1
    }

    private func notesShortcutStartIndex(features: ProjectFeatureSettings) -> Int {
        workspace.visibleAgentSessions(collapsedIDs: chromeState.collapsedAgentGroupIDs).count
            + workspace.terminalSessions.count
            + agentSettings.launchableProjectCommands(for: projectRoot).count
            + (features.todosEnabled ? 1 : 0)
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
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: settings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        // SwiftUI Menu's underlying NSPopUpButton owns mouse-tracking on its
        // label, so neither `.onHover` nor an NSTrackingArea overlay fire.
        // A plain Button has no such interference — we present an NSMenu
        // programmatically on click.
        Button(action: presentMenu) {
            HStack(spacing: 6) {
                if palette.showsProjectAccent {
                    Circle()
                        .fill(palette.projectAccent)
                        .frame(width: 7, height: 7)
                }

                Text(selectedProject?.name ?? "No Project")
                    .lineLimit(1)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.rowText)
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
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let showShortcutHints: Bool
    let openSettings: () -> Void

    var body: some View {
        let project = settings.resolvedProject(for: projectRoot)
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: settings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(
                    title: "Agents",
                    count: workspace.agentSessions.count + (isIconDebugActive ? SidebarIconDebugFixtures.agentCount : 0),
                    palette: palette
                )

                AgentLaunchMenu(
                    project: project,
                    palette: palette,
                    openSettings: openSettings,
                    launch: launch
                )
            }

            if isIconDebugActive {
                SidebarIconDebugAgentPreview(palette: palette)
            }

            if workspace.agentSessions.isEmpty && !isIconDebugActive {
                SidebarEmptyRow(
                    title: "No agents",
                    palette: palette
                )
            }

            if !workspace.agentSessions.isEmpty {
                let items = workspace.visibleAgentTreeItems(collapsedIDs: chromeState.collapsedAgentGroupIDs)
                let shortcutNumbers = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
                    (item.session.id, index + 1)
                })
                ForEach(workspace.rootAgentSessions) { session in
                    let children = workspace.childAgentSessions(of: session)
                    let isCollapsed = chromeState.collapsedAgentGroupIDs.contains(session.id)
                    let isActiveGroup = chromeState.isShowingTerminalContent
                        && (workspace.selectedSessionID == session.id
                            || children.contains { $0.id == workspace.selectedSessionID })
                    agentRow(
                        session: session,
                        shortcutNumber: shortcutNumbers[session.id] ?? 1,
                        nestingDepth: 0,
                        showsDisclosure: !children.isEmpty,
                        isDisclosureExpanded: !isCollapsed
                    )

                    if !children.isEmpty && !isCollapsed {
                        SidebarAgentChildrenGroup(
                            children: children,
                            palette: palette,
                            isActive: isActiveGroup
                        ) { child in
                            agentRow(
                                session: child,
                                shortcutNumber: shortcutNumbers[child.id] ?? 1,
                                nestingDepth: 1,
                                showsDisclosure: false,
                                isDisclosureExpanded: true
                            )
                        }
                    }
                }

                if AgentTreeLayout.isTuningEnabled {
                    AgentTreeTuningPanel(palette: palette)
                }
            }
        }
    }

    private func launch(_ agent: ResolvedAgentTool) {
        let project = settings.resolvedProject(for: projectRoot)
        guard agent.isLaunchable, let root = project.validProjectRoot else { return }
        chromeState.selectTerminal()
        workspace.addAgentSession(agent: agent.definition, projectRoot: root)
    }

    private var isIconDebugActive: Bool {
        PrototypeFeatureFlags.isIconDebugEnabled && chromeState.isIconDebugOverlayPresented
    }

    private func select(_ session: TerminalSession) {
        chromeState.selectTerminal()
        workspace.select(session)
    }

    private func close(_ session: TerminalSession) {
        if !workspace.descendantAgentSessions(of: session).isEmpty {
            chromeState.requestAgentGroupClose(sessionID: session.id)
        } else {
            workspace.close(session)
        }
    }

    private func agentRow(
        session: TerminalSession,
        shortcutNumber: Int,
        nestingDepth: Int,
        showsDisclosure: Bool,
        isDisclosureExpanded: Bool
    ) -> some View {
        SidebarTabRow(
            session: session,
            isSelected: chromeState.isShowingTerminalContent && workspace.selectedSessionID == session.id,
            projectRoot: projectRoot,
            presentation: presentation,
            pathDisplayMode: terminalSettings.sidebarTerminalPathDisplayMode,
            shortcutNumber: shortcutNumber,
            showShortcutHint: showShortcutHints,
            nestingDepth: nestingDepth,
            showsDisclosure: showsDisclosure,
            isDisclosureExpanded: isDisclosureExpanded,
            onToggleDisclosure: showsDisclosure ? {
                chromeState.toggleAgentGroupCollapsed(session.id)
            } : nil,
            onSelect: { select(session) }
        )
        .contextMenu {
            Button("Copy Link") {
                copyCherryLink(cherryLink(for: session, projectRoot: projectRoot))
            }
            .disabled(projectRoot == nil)

            Divider()

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
                close(session)
            }
            .disabled(workspace.sessions.count <= 1)
        }
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

private struct SidebarAgentChildrenGroup<RowContent: View>: View {
    let children: [TerminalSession]
    let palette: SidebarPalette
    let isActive: Bool
    let rowContent: (TerminalSession) -> RowContent

    init(
        children: [TerminalSession],
        palette: SidebarPalette,
        isActive: Bool,
        @ViewBuilder rowContent: @escaping (TerminalSession) -> RowContent
    ) {
        self.children = children
        self.palette = palette
        self.isActive = isActive
        self.rowContent = rowContent
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarAgentChildrenGuide(
                children: children,
                palette: palette,
                isActive: isActive
            )

            VStack(alignment: .leading, spacing: SidebarLayout.agentTreeRowSpacing) {
                ForEach(children) { child in
                    rowContent(child)
                }
            }
        }
    }
}

private struct SidebarAgentChildrenGuide: View {
    let children: [TerminalSession]
    let palette: SidebarPalette
    let isActive: Bool

    @AppStorage(AgentTreeLayout.guideXKey) private var guideX = AgentTreeLayout.defaultGuideX
    @AppStorage(AgentTreeLayout.guideElbowWidthKey) private var guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
    @AppStorage(AgentTreeLayout.guideElbowStartInsetKey) private var guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
    @AppStorage(AgentTreeLayout.guideConnectorLengthKey) private var guideConnectorLength = AgentTreeLayout.defaultGuideConnectorLength
    @AppStorage(AgentTreeLayout.guideConnectorDashLengthKey) private var guideConnectorDashLength = AgentTreeLayout.defaultGuideConnectorDashLength
    @AppStorage(AgentTreeLayout.guideConnectorDashGapKey) private var guideConnectorDashGap = AgentTreeLayout.defaultGuideConnectorDashGap
    @AppStorage(AgentTreeLayout.guideConnectorOffsetXKey) private var guideConnectorOffsetX = AgentTreeLayout.defaultGuideConnectorOffsetX
    @AppStorage(AgentTreeLayout.guideConnectorOffsetYKey) private var guideConnectorOffsetY = AgentTreeLayout.defaultGuideConnectorOffsetY
    @AppStorage(AgentTreeLayout.guideTopOverlapKey) private var guideTopOverlap = AgentTreeLayout.defaultGuideTopOverlap
    @AppStorage(AgentTreeLayout.guideBottomOverlapKey) private var guideBottomOverlap = AgentTreeLayout.defaultGuideBottomOverlap
    @AppStorage(AgentTreeLayout.childRowHeightKey) private var childRowHeight = AgentTreeLayout.defaultChildRowHeight
    @AppStorage(AgentTreeLayout.childDetailRowHeightKey) private var childDetailRowHeight = AgentTreeLayout.defaultChildDetailRowHeight

    var body: some View {
        let x = CGFloat(guideX)
        let elbowWidth = CGFloat(guideElbowWidth)
        let elbowX = x + CGFloat(guideElbowStartInset)
        let connectorLength = CGFloat(guideConnectorLength)
        let connectorDashLength = CGFloat(guideConnectorDashLength)
        let connectorDashGap = CGFloat(guideConnectorDashGap)
        let connectorX = x + CGFloat(guideConnectorOffsetX)
        let connectorY = CGFloat(guideConnectorOffsetY)
        let topOverlap = CGFloat(guideTopOverlap)
        let bottomOverlap = CGFloat(guideBottomOverlap)
        let color = palette.rowText.opacity(isActive ? 0.16 : 0.08)
        let lastCenterY = centerY(forChildAt: max(children.count - 1, 0))

        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: connectorX, y: connectorY - connectorLength))
                path.addLine(to: CGPoint(x: connectorX, y: connectorY + connectorLength))
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [connectorDashLength, connectorDashGap])
            )

            Rectangle()
                .fill(color)
                .frame(width: 1, height: lastCenterY + topOverlap + bottomOverlap)
                .offset(x: x, y: -topOverlap)

            ForEach(Array(children.enumerated()), id: \.element.id) { index, _ in
                Rectangle()
                    .fill(color)
                    .frame(width: elbowWidth, height: 1)
                    .offset(x: elbowX, y: centerY(forChildAt: index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func centerY(forChildAt index: Int) -> CGFloat {
        guard index > 0 else {
            return rowHeight(for: children.first) / 2
        }

        let precedingRowsHeight = children.prefix(index).reduce(CGFloat.zero) { partialResult, session in
            partialResult + rowHeight(for: session)
        }
        return precedingRowsHeight
            + SidebarLayout.agentTreeRowSpacing * CGFloat(index)
            + rowHeight(for: children[index]) / 2
    }

    private func rowHeight(for session: TerminalSession?) -> CGFloat {
        guard let session else { return CGFloat(childDetailRowHeight) }
        return CGFloat(session.sidebarDetail.nilIfEmpty == nil ? childRowHeight : childDetailRowHeight)
    }
}

private struct AgentTreeTuningPanel: View {
    let palette: SidebarPalette

    @AppStorage(AgentTreeLayout.guideXKey) private var guideX = AgentTreeLayout.defaultGuideX
    @AppStorage(AgentTreeLayout.guideElbowWidthKey) private var guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
    @AppStorage(AgentTreeLayout.guideElbowStartInsetKey) private var guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
    @AppStorage(AgentTreeLayout.guideConnectorLengthKey) private var guideConnectorLength = AgentTreeLayout.defaultGuideConnectorLength
    @AppStorage(AgentTreeLayout.guideConnectorDashLengthKey) private var guideConnectorDashLength = AgentTreeLayout.defaultGuideConnectorDashLength
    @AppStorage(AgentTreeLayout.guideConnectorDashGapKey) private var guideConnectorDashGap = AgentTreeLayout.defaultGuideConnectorDashGap
    @AppStorage(AgentTreeLayout.guideConnectorOffsetXKey) private var guideConnectorOffsetX = AgentTreeLayout.defaultGuideConnectorOffsetX
    @AppStorage(AgentTreeLayout.guideConnectorOffsetYKey) private var guideConnectorOffsetY = AgentTreeLayout.defaultGuideConnectorOffsetY
    @AppStorage(AgentTreeLayout.disclosureOffsetKey) private var disclosureOffset = AgentTreeLayout.defaultDisclosureOffset
    @AppStorage(AgentTreeLayout.guideTopOverlapKey) private var guideTopOverlap = AgentTreeLayout.defaultGuideTopOverlap
    @AppStorage(AgentTreeLayout.guideBottomOverlapKey) private var guideBottomOverlap = AgentTreeLayout.defaultGuideBottomOverlap
    @AppStorage(AgentTreeLayout.childRowHeightKey) private var childRowHeight = AgentTreeLayout.defaultChildRowHeight
    @AppStorage(AgentTreeLayout.childDetailRowHeightKey) private var childDetailRowHeight = AgentTreeLayout.defaultChildDetailRowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Tree Tune")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.headerText)

                Spacer()

                Button("Reset") {
                    reset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.headerText.opacity(0.72))
            }

            tuningHeader("Guide")
            tuningRow("x", value: $guideX, range: 0...12, step: 0.5)
            tuningRow("stem", value: $guideConnectorLength, range: 0...24, step: 1)
            tuningRow("top", value: $guideTopOverlap, range: 0...12, step: 0.5)
            tuningRow("bottom", value: $guideBottomOverlap, range: 0...12, step: 0.5)

            tuningHeader("Elbows")
            tuningRow("width", value: $guideElbowWidth, range: 0...16, step: 0.5)
            tuningRow("join", value: $guideElbowStartInset, range: 0...4, step: 0.5)

            tuningHeader("Dash")
            tuningRow("length", value: $guideConnectorDashLength, range: 1...8, step: 0.5)
            tuningRow("gap", value: $guideConnectorDashGap, range: 1...8, step: 0.5)
            tuningRow("x", value: $guideConnectorOffsetX, range: -12...12, step: 0.5)
            tuningRow("y", value: $guideConnectorOffsetY, range: -24...24, step: 1)

            tuningHeader("Rows")
            tuningRow("arrow", value: $disclosureOffset, range: -10...4, step: 0.5)
            tuningRow("row", value: $childRowHeight, range: 32...46, step: 1)
            tuningRow("detail", value: $childDetailRowHeight, range: 36...52, step: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.rowText.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.rowText.opacity(0.10), lineWidth: 1)
                }
        }
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .padding(.top, 3)
    }

    private func tuningHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.rowText.opacity(0.46))
            .textCase(.uppercase)
            .padding(.top, 3)
    }

    private func tuningRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.rowText.opacity(0.62))
                .frame(width: 38, alignment: .leading)

            Slider(value: value, in: range, step: step)

            Text(value.wrappedValue, format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.rowText.opacity(0.72))
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func reset() {
        guideX = AgentTreeLayout.defaultGuideX
        guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
        guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
        guideConnectorLength = AgentTreeLayout.defaultGuideConnectorLength
        guideConnectorDashLength = AgentTreeLayout.defaultGuideConnectorDashLength
        guideConnectorDashGap = AgentTreeLayout.defaultGuideConnectorDashGap
        guideConnectorOffsetX = AgentTreeLayout.defaultGuideConnectorOffsetX
        guideConnectorOffsetY = AgentTreeLayout.defaultGuideConnectorOffsetY
        disclosureOffset = AgentTreeLayout.defaultDisclosureOffset
        guideTopOverlap = AgentTreeLayout.defaultGuideTopOverlap
        guideBottomOverlap = AgentTreeLayout.defaultGuideBottomOverlap
        childRowHeight = AgentTreeLayout.defaultChildRowHeight
        childDetailRowHeight = AgentTreeLayout.defaultChildDetailRowHeight
    }
}

private struct SidebarCommandSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let shortcutStartIndex: Int
    let showShortcutHints: Bool

    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    var body: some View {
        let commands = settings.launchableProjectCommands(for: projectRoot)
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: settings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(
                    title: "Commands",
                    count: commands.count + (isIconDebugActive ? SidebarIconDebugFixtures.commandCount : 0),
                    palette: palette
                )

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

            if isIconDebugActive {
                SidebarIconDebugCommandPreview(palette: palette)
            }

            if commands.isEmpty && !isIconDebugActive {
                SidebarEmptyRow(
                    title: projectRoot == nil ? "Select a project" : "No commands",
                    palette: palette
                )
            }

            if !commands.isEmpty {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    let session = workspace.commandSession(named: command.name)
                    SidebarCommandRow(
                        command: command,
                        session: session,
                        projectRoot: projectRoot,
                        isSelected: chromeState.focusedIdleCommandName == command.name
                            || (chromeState.isShowingTerminalContent && (session.map { workspace.selectedSessionID == $0.id } ?? false)),
                        presentation: presentation,
                        shortcutNumber: shortcutStartIndex + index + 1,
                        showShortcutHint: showShortcutHints,
                        start: { start(command, existingSession: session) },
                        stop: { session?.stopManagedCommand() },
                        restart: { restart(command, existingSession: session) },
                        select: {
                            if let session {
                                chromeState.selectNote(id: nil)
                                workspace.select(session)
                            }
                        }
                    )
                    .contextMenu {
                        if let session {
                            Button("Copy Link") {
                                copyCherryLink(cherryLink(for: session, projectRoot: projectRoot))
                            }

                            Divider()
                        }

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
                chromeState.selectTerminal()
                workspace.select(existingSession)
            } else {
                existingSession.restart()
                chromeState.selectTerminal()
                workspace.select(existingSession)
            }
        } else {
            chromeState.selectTerminal()
            workspace.addCommandSession(command: command, projectRoot: root)
        }
    }

    private func restart(_ command: ProjectCommandDefinition, existingSession: TerminalSession?) {
        guard command.isLaunchable else { return }
        if let existingSession {
            existingSession.restart()
            chromeState.selectTerminal()
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

    private var isIconDebugActive: Bool {
        PrototypeFeatureFlags.isIconDebugEnabled && chromeState.isIconDebugOverlayPresented
    }
}

private struct SidebarNotesSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject private var agentSettings = AgentSettings.shared

    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let shortcutStartIndex: Int
    let showShortcutHints: Bool

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(title: "Notes", count: noteStore.notes.count, palette: palette)

                Button(action: createNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.headerText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note")
            }

            if noteStore.notes.isEmpty {
                SidebarEmptyRow(title: "No notes", palette: palette)
            } else {
                ForEach(Array(noteStore.notes.enumerated()), id: \.element.id) { index, note in
                    let shortcutNumber = shortcutStartIndex + index + 1
                    Button {
                        chromeState.selectNote(id: note.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "note.text")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(isSelected(note) ? palette.selectedText : palette.rowText)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title.isEmpty ? "Untitled Note" : note.title)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(isSelected(note) ? palette.selectedText : palette.rowText)
                                    .lineLimit(1)

                                Text(note.updatedAt, style: .relative)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle((isSelected(note) ? palette.selectedText : palette.rowText).opacity(0.56))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            if showShortcutHints, shortcutNumber <= 9 {
                                SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected(note), palette: palette)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 46)
                        .padding(.leading, SidebarLayout.rowHorizontalInset)
                        .padding(.trailing, SidebarLayout.rowHorizontalInset)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .background {
                            if isSelected(note) {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(palette.selectedFill)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(palette.selectedStroke, lineWidth: 1)
                                    }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -SidebarLayout.rowHorizontalInset)
                    .contextMenu {
                        Button("Copy Link") {
                            copyCherryLink(cherryLink(for: note))
                        }

                        Divider()

                        Button("Delete", role: .destructive) {
                            try? noteStore.delete(id: note.id)
                            if chromeState.selectedNoteID == note.id {
                                chromeState.selectNote(id: nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func createNote() {
        if let note = try? noteStore.create(title: "Untitled Note", markdown: "# Untitled Note\n") {
            chromeState.selectNote(id: note.id)
        }
    }

    private func isSelected(_ note: ProjectNote) -> Bool {
        chromeState.selectedNoteID == note.id
    }
}

private struct SidebarTodosSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject private var agentSettings = AgentSettings.shared

    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let shortcutNumber: Int
    let showShortcutHint: Bool

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(title: "Todos", count: openTodoCount, palette: palette)

            Button {
                chromeState.selectTodo(id: chromeState.selectedTodoID ?? firstSelectableTodo?.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Todo Board")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                            .lineLimit(1)

                        Text(openTodoSubtitle)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if showShortcutHint, shortcutNumber <= 9 {
                        SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected, palette: palette)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 46)
                .padding(.leading, SidebarLayout.rowHorizontalInset)
                .padding(.trailing, SidebarLayout.rowHorizontalInset)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(palette.selectedFill)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(palette.selectedStroke, lineWidth: 1)
                            }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, -SidebarLayout.rowHorizontalInset)
        }
    }

    private var openTodoCount: Int {
        todoStore.todos.filter { $0.status != .done }.count
    }

    private var openTodoSubtitle: String {
        switch openTodoCount {
        case 0:
            "No open todos"
        case 1:
            "1 open todo"
        default:
            "\(openTodoCount) open todos"
        }
    }

    private var firstSelectableTodo: ProjectTodo? {
        todoStore.todos.first { $0.status != .done } ?? todoStore.todos.first
    }

    private var isSelected: Bool {
        chromeState.isTodoPanePresented
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
    @ObservedObject private var agentSettings = AgentSettings.shared

    let command: ProjectCommandDefinition
    let session: TerminalSession?
    let projectRoot: String?
    let isSelected: Bool
    let presentation: SidebarPresentation
    let shortcutNumber: Int
    let showShortcutHint: Bool
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )
        let subtitle = sidebarSubtitle()

        Button(action: select) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .lineLimit(1)

                    if let subtitle {
                        HStack(spacing: 4) {
                            if let resourceName = subtitle.iconResourceName {
                                SidebarDetailIcon(resourceName: resourceName)
                            }

                            Text(subtitle.text)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                    }
                }

                Spacer(minLength: 8)

                if showShortcutHint, shortcutNumber <= 9 {
                    SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected, palette: palette)
                } else {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: subtitle == nil ? 42 : 46)
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

    private func sidebarSubtitle() -> SidebarCommandSubtitle? {
        let hasArguments = !command.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasArguments,
           let projectRoot,
           let repoPath = SidebarTerminalPathFormatter.githubRepositoryPath(
               for: command.resolvedWorkingDirectory(projectRoot: projectRoot)
           ) {
            return SidebarCommandSubtitle(text: repoPath, iconResourceName: "github")
        }

        return command.commandLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .map { SidebarCommandSubtitle(text: $0, iconResourceName: nil) }
    }
}

private struct SidebarCommandSubtitle {
    let text: String
    let iconResourceName: String?
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
    @ObservedObject private var agentSettings = AgentSettings.shared

    let title: String
    let sessions: [TerminalSession]
    let kind: TerminalSession.SessionKind
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let shortcutStartIndex: Int
    let showShortcutHints: Bool

    @State private var draggedSessionID: UUID?
    @State private var draggedRowOffsetY: CGFloat = 0

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(
                title: title,
                count: sessions.count + (isIconDebugActive && kind == .terminal ? SidebarIconDebugFixtures.terminalCount : 0),
                palette: palette
            )

            if isIconDebugActive, kind == .terminal {
                SidebarIconDebugTerminalPreview(palette: palette)
            }

            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SidebarTabRow(
                    session: session,
                    isSelected: chromeState.isShowingTerminalContent && workspace.selectedSessionID == session.id,
                    projectRoot: projectRoot,
                    presentation: presentation,
                    pathDisplayMode: terminalSettings.sidebarTerminalPathDisplayMode,
                    shortcutNumber: shortcutStartIndex + index + 1,
                    showShortcutHint: showShortcutHints,
                    onSelect: {
                        chromeState.selectTerminal()
                        workspace.select(session)
                    }
                )
                .offset(y: draggedSessionID == session.id ? draggedRowOffsetY : 0)
                .zIndex(draggedSessionID == session.id ? 1 : 0)
                .anchorPreference(key: SidebarRowBoundsPreferenceKey.self, value: .bounds) { anchor in
                    [session.id: anchor]
                }
                .contextMenu {
                    Button("Copy Link") {
                        copyCherryLink(cherryLink(for: session, projectRoot: workspace.projectRoot))
                    }
                    .disabled(workspace.projectRoot == nil)

                    Divider()

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
                        chromeState.selectNote(id: nil)
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

    private var isIconDebugActive: Bool {
        PrototypeFeatureFlags.isIconDebugEnabled && chromeState.isIconDebugOverlayPresented
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

enum TrafficLightWindowLayout {
    static let refreshNotificationNames: [NSNotification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification
    ]
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
        for name in TrafficLightWindowLayout.refreshNotificationNames {
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
    @ObservedObject private var agentSettings = AgentSettings.shared

    let projectRoot: String?
    let presentation: SidebarPresentation

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        Rectangle()
            .fill(palette.backgroundMaterial)
            .overlay(alignment: .leading) {
                if palette.showsProjectAccent {
                    Rectangle()
                        .fill(palette.projectAccent)
                        .frame(width: 3)
                        .opacity(presentation == .floating ? 0.75 : 0.62)
                }
            }
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

private struct SidebarShortcutHint: View {
    let number: Int
    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.52))
            .frame(width: 26, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

private struct SidebarAgentWorkingIndicator: View {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { timeline in
            let index = Int(timeline.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count

            Text(Self.frames[index])
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.66))
                .frame(width: 14, height: 18)
                .accessibilityLabel("Agent working")
        }
    }
}

private struct SidebarTabRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject private var agentSettings = AgentSettings.shared

    @StateObject private var rowState: SidebarTabRowState

    let isSelected: Bool
    let projectRoot: String?
    let presentation: SidebarPresentation
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let shortcutNumber: Int
    let showShortcutHint: Bool
    let nestingDepth: Int
    let showsDisclosure: Bool
    let isDisclosureExpanded: Bool
    let onToggleDisclosure: (() -> Void)?
    let onSelect: () -> Void

    @AppStorage(AgentTreeLayout.guideXKey) private var guideX = AgentTreeLayout.defaultGuideX
    @AppStorage(AgentTreeLayout.guideElbowWidthKey) private var guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
    @AppStorage(AgentTreeLayout.guideElbowStartInsetKey) private var guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
    @AppStorage(AgentTreeLayout.disclosureOffsetKey) private var disclosureOffset = AgentTreeLayout.defaultDisclosureOffset
    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons
    @AppStorage(AgentTreeLayout.childRowHeightKey) private var childRowHeight = AgentTreeLayout.defaultChildRowHeight
    @AppStorage(AgentTreeLayout.childDetailRowHeightKey) private var childDetailRowHeight = AgentTreeLayout.defaultChildDetailRowHeight
    @State private var isHovered = false

    init(
        session: TerminalSession,
        isSelected: Bool,
        projectRoot: String?,
        presentation: SidebarPresentation,
        pathDisplayMode: SidebarTerminalPathDisplayMode,
        shortcutNumber: Int,
        showShortcutHint: Bool,
        nestingDepth: Int = 0,
        showsDisclosure: Bool = false,
        isDisclosureExpanded: Bool = true,
        onToggleDisclosure: (() -> Void)? = nil,
        onSelect: @escaping () -> Void
    ) {
        _rowState = StateObject(wrappedValue: SidebarTabRowState(
            session: session,
            pathDisplayMode: pathDisplayMode
        ))
        self.isSelected = isSelected
        self.projectRoot = projectRoot
        self.presentation = presentation
        self.pathDisplayMode = pathDisplayMode
        self.shortcutNumber = shortcutNumber
        self.showShortcutHint = showShortcutHint
        self.nestingDepth = nestingDepth
        self.showsDisclosure = showsDisclosure
        self.isDisclosureExpanded = isDisclosureExpanded
        self.onToggleDisclosure = onToggleDisclosure
        self.onSelect = onSelect
    }

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )
        let label = rowState.label
        let nested = nestingDepth > 0
        let nestedGuideReservationWidth = CGFloat(guideX + guideElbowStartInset + guideElbowWidth + 2)
        let nestedBackgroundLeadingInset = nested
            ? SidebarLayout.rowHorizontalInset + nestedGuideReservationWidth + 2
            : 0
        let rowHeight: CGFloat = if nested {
            CGFloat(label.detail == nil ? childRowHeight : childDetailRowHeight)
        } else {
            label.detail == nil ? 42 : 50
        }

        HStack(spacing: nested ? 6 : 8) {
            if nested {
                Color.clear
                    .frame(width: nestedGuideReservationWidth, height: rowHeight)
            }

            if showsDisclosure {
                Button(action: { onToggleDisclosure?() }) {
                    Image(systemName: isDisclosureExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.54))
                        .frame(width: 14, height: 22)
                }
                .buttonStyle(.plain)
                .help(isDisclosureExpanded ? "Collapse sub-agents" : "Expand sub-agents")
                .offset(x: CGFloat(disclosureOffset))
                .padding(.trailing, -6)
            }

            if let icon = rowState.agentIconDescriptor {
                if !usesInlineAgentIconsForRow {
                    AgentToolIcon(descriptor: icon, isSelected: isSelected, palette: palette)
                }
            } else if label.leadingIconResourceName != nil || label.leadingIconFallback != nil {
                if !usesInlineProgramIconsForRow {
                    SidebarProgramIcon(label: label, isSelected: isSelected, palette: palette)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label.title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                    .lineLimit(1)

                if let detail = label.detail {
                    HStack(spacing: 4) {
                        if let resourceName = label.detailIconResourceName {
                            SidebarDetailIcon(resourceName: resourceName)
                        } else if usesInlineAgentDetailIcons, let icon = rowState.agentIconDescriptor {
                            AgentToolInlineIcon(descriptor: icon)
                        } else if usesInlineProgramDetailIcons,
                                  label.leadingIconResourceName != nil || label.leadingIconFallback != nil {
                            SidebarProgramInlineIcon(label: label)
                        }

                        Text(detail)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                }
            }

            Spacer(minLength: 8)

            if rowState.showsAgentWorkingIndicator {
                SidebarAgentWorkingIndicator(isSelected: isSelected, palette: palette)
            }

            Circle()
                .fill(Color(nsColor: rowState.tint))
                .frame(width: 7, height: 7)
                .opacity(rowState.hasUnreadNotification ? 1 : 0)

            if showShortcutHint, shortcutNumber <= 9 {
                SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .padding(.leading, SidebarLayout.rowHorizontalInset)
        .padding(.trailing, SidebarLayout.rowHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(alignment: .leading) {
            rowBackground(palette: palette)
                .padding(.leading, nestedBackgroundLeadingInset)
        }
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            rowState.updatePathDisplayMode(pathDisplayMode)
        }
        .onChange(of: pathDisplayMode) { _, mode in
            rowState.updatePathDisplayMode(mode)
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

    private var usesInlineAgentIconsForRow: Bool {
        usesInlineAgentDetailIcons && rowState.label.detail != nil
    }

    private var usesInlineProgramIconsForRow: Bool {
        usesInlineProgramDetailIcons && rowState.label.detail != nil
    }

}

@MainActor
private final class SidebarTabRowState: ObservableObject {
    let tint: NSColor
    private(set) var agentIconDescriptor: AgentToolIconDescriptor?

    @Published private(set) var label: SidebarTerminalPathLabel
    @Published private(set) var hasUnreadNotification: Bool
    @Published private(set) var showsAgentWorkingIndicator: Bool

    private weak var session: TerminalSession?
    private var pathDisplayMode: SidebarTerminalPathDisplayMode
    private var cancellables: Set<AnyCancellable> = []

    init(session: TerminalSession, pathDisplayMode: SidebarTerminalPathDisplayMode) {
        self.session = session
        self.pathDisplayMode = pathDisplayMode
        self.tint = session.tint
        self.agentIconDescriptor = AgentToolIconDescriptor(
            kind: session.kind,
            agentName: session.agentName,
            title: session.title
        )
        self.label = Self.label(for: session, pathDisplayMode: pathDisplayMode)
        self.hasUnreadNotification = session.hasUnreadNotification
        self.showsAgentWorkingIndicator = session.agentActivityState.showsWorkingIndicator

        observe(session)
    }

    func updatePathDisplayMode(_ mode: SidebarTerminalPathDisplayMode) {
        guard pathDisplayMode != mode else { return }
        pathDisplayMode = mode
        refreshLabel()
    }

    private func observe(_ session: TerminalSession) {
        Publishers.CombineLatest4(session.$title, session.$titleSource, session.$subtitle, session.$summary)
            .combineLatest(session.$workingDirectory)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLabel()
                }
            }
            .store(in: &cancellables)

        session.$hasUnreadNotification
            .removeDuplicates()
            .sink { [weak self] hasUnreadNotification in
                Task { @MainActor [weak self] in
                    self?.hasUnreadNotification = hasUnreadNotification
                }
            }
            .store(in: &cancellables)

        session.$agentActivityState
            .map(\.showsWorkingIndicator)
            .removeDuplicates()
            .sink { [weak self] showsAgentWorkingIndicator in
                Task { @MainActor [weak self] in
                    self?.showsAgentWorkingIndicator = showsAgentWorkingIndicator
                }
            }
            .store(in: &cancellables)
    }

    private func refreshLabel() {
        guard let session else { return }
        agentIconDescriptor = AgentToolIconDescriptor(
            kind: session.kind,
            agentName: session.agentName,
            title: session.title
        )
        let nextLabel = Self.label(for: session, pathDisplayMode: pathDisplayMode)
        guard label != nextLabel else { return }
        label = nextLabel
    }

    private static func label(
        for session: TerminalSession,
        pathDisplayMode: SidebarTerminalPathDisplayMode
    ) -> SidebarTerminalPathLabel {
        guard session.kind == .terminal, !session.hasExplicitTitle else {
            return .init(title: session.title, detail: session.sidebarDetail.nilIfEmpty)
        }

        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle == SidebarTerminalPathFormatter.displayPath(session.workingDirectory) {
            return SidebarTerminalPathFormatter.label(
                for: session.workingDirectory,
                mode: pathDisplayMode
            )
        }

        if let programLabel = SidebarTerminalProgramFormatter.label(
            for: session.title,
            workingDirectory: session.workingDirectory
        ) {
            return programLabel
        }

        if SidebarTerminalPathFormatter.shouldUseWorkingDirectoryLabel(
            title: session.title,
            workingDirectory: session.workingDirectory
        ) {
            return SidebarTerminalPathFormatter.label(
                for: session.workingDirectory,
                mode: pathDisplayMode
            )
        }

        return .init(title: session.title, detail: session.sidebarDetail.nilIfEmpty)
    }
}

private struct AgentToolIconDescriptor {
    let label: String
    let logoResourceName: String?
    let rendersAsTemplate: Bool

    private init(
        label: String,
        logoResourceName: String? = nil,
        rendersAsTemplate: Bool = true
    ) {
        self.label = label
        self.logoResourceName = logoResourceName
        self.rendersAsTemplate = rendersAsTemplate
    }

    @MainActor
    init?(session: TerminalSession) {
        self.init(kind: session.kind, agentName: session.agentName, title: session.title)
    }

    init?(kind: TerminalSession.SessionKind, agentName: String?, title: String) {
        guard kind == .agent else { return nil }

        let displayName = agentName ?? title
        let name = displayName.lowercased()
        if name.contains("codex") || name.contains("openai") {
            self.init(label: "Cx", logoResourceName: "openai")
        } else if name.contains("claude") || name.contains("anthropic") {
            self.init(label: "Cl", logoResourceName: "claude")
        } else if name.contains("gemini") {
            self.init(label: "Ge", logoResourceName: "gemini")
        } else if name.contains("amp") {
            self.init(label: "A", logoResourceName: "amp")
        } else if name == "pi" || name.contains(" pi ") || name.contains("pi.ai") || name.contains("inflection") {
            self.init(label: "Pi")
        } else {
            return nil
        }
    }
}

private enum SidebarIconMetrics {
    static let programGlyphScaleKey = "sidebar.icons.programGlyphScale"
    static let detailGlyphScaleKey = "sidebar.icons.detailGlyphScale"
    static let agentGlyphScaleKey = "sidebar.icons.agentGlyphScale"
    static let usesInlineProgramDetailIconsKey = "sidebar.icons.usesInlineDetailIcons"
    static let usesInlineAgentDetailIconsKey = "sidebar.icons.usesInlineAgentDetailIcons"

    static let defaultProgramGlyphScale = 1.20
    static let defaultDetailGlyphScale = 1.0
    static let defaultAgentGlyphScale = 0.90
    static let defaultUsesInlineProgramDetailIcons = true
    static let defaultUsesInlineAgentDetailIcons = false

    static let programFrameSize: CGFloat = 20
    static let programGlyphSize: CGFloat = 18
    static let detailGlyphSize: CGFloat = 11
    static let agentFrameSize: CGFloat = 20
    static let agentGlyphSize: CGFloat = 13

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(defaultProgramGlyphScale, forKey: programGlyphScaleKey)
        defaults.set(defaultDetailGlyphScale, forKey: detailGlyphScaleKey)
        defaults.set(defaultAgentGlyphScale, forKey: agentGlyphScaleKey)
        defaults.set(defaultUsesInlineProgramDetailIcons, forKey: usesInlineProgramDetailIconsKey)
        defaults.set(defaultUsesInlineAgentDetailIcons, forKey: usesInlineAgentDetailIconsKey)
    }
}

private struct AgentToolIcon: View {
    let descriptor: AgentToolIconDescriptor
    let isSelected: Bool
    let palette: SidebarPalette

    @AppStorage(SidebarIconMetrics.agentGlyphScaleKey) private var agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale

    var body: some View {
        let iconColor = isSelected ? palette.selectedText : palette.rowText
        let glyphSize = SidebarIconMetrics.agentGlyphSize * CGFloat(agentGlyphScale)

        ZStack {
            Circle()
                .fill(iconColor.opacity(isSelected ? 0.18 : 0.10))

            if let logoResourceName = descriptor.logoResourceName {
                AgentLogoImage(
                    resourceName: logoResourceName,
                    rendersAsTemplate: descriptor.rendersAsTemplate,
                    fallbackLabel: descriptor.label
                )
                .frame(width: glyphSize, height: glyphSize)
            } else {
                Text(descriptor.label)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(iconColor)
        .frame(width: SidebarIconMetrics.agentFrameSize, height: SidebarIconMetrics.agentFrameSize)
        .accessibilityHidden(true)
    }
}

private struct SidebarProgramIcon: View {
    let label: SidebarTerminalPathLabel
    let isSelected: Bool
    let palette: SidebarPalette

    @AppStorage(SidebarIconMetrics.programGlyphScaleKey) private var programGlyphScale = SidebarIconMetrics.defaultProgramGlyphScale

    var body: some View {
        let iconColor = isSelected ? palette.selectedText : palette.rowText
        let glyphSize = SidebarIconMetrics.programGlyphSize * CGFloat(programGlyphScale)

        ZStack {
            if let resourceName = label.leadingIconResourceName {
                AgentLogoImage(
                    resourceName: resourceName,
                    rendersAsTemplate: true,
                    fallbackLabel: label.leadingIconFallback ?? ""
                )
                .frame(width: glyphSize, height: glyphSize)
            } else if let fallback = label.leadingIconFallback {
                Circle()
                    .fill(iconColor.opacity(isSelected ? 0.16 : 0.10))

                Text(fallback)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(iconColor)
        .frame(width: SidebarIconMetrics.programFrameSize, height: SidebarIconMetrics.programFrameSize)
        .accessibilityHidden(true)
    }
}

private struct SidebarDetailIcon: View {
    let resourceName: String

    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale

    var body: some View {
        let glyphSize = SidebarIconMetrics.detailGlyphSize * CGFloat(detailGlyphScale)

        AgentLogoImage(
            resourceName: resourceName,
            rendersAsTemplate: true,
            fallbackLabel: ""
        )
        .frame(width: glyphSize, height: glyphSize)
        .frame(width: SidebarIconMetrics.detailGlyphSize, height: SidebarIconMetrics.detailGlyphSize)
        .accessibilityHidden(true)
    }
}

private struct AgentToolInlineIcon: View {
    let descriptor: AgentToolIconDescriptor

    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale

    var body: some View {
        let glyphSize = SidebarIconMetrics.detailGlyphSize * CGFloat(detailGlyphScale)

        ZStack {
            if let logoResourceName = descriptor.logoResourceName {
                AgentLogoImage(
                    resourceName: logoResourceName,
                    rendersAsTemplate: descriptor.rendersAsTemplate,
                    fallbackLabel: descriptor.label
                )
                .frame(width: glyphSize, height: glyphSize)
            } else {
                Circle()
                    .fill(.primary.opacity(0.14))

                Text(descriptor.label)
                    .font(.system(size: 7, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(width: SidebarIconMetrics.detailGlyphSize, height: SidebarIconMetrics.detailGlyphSize)
        .accessibilityHidden(true)
    }
}

private struct SidebarProgramInlineIcon: View {
    let label: SidebarTerminalPathLabel

    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale

    var body: some View {
        let glyphSize = SidebarIconMetrics.detailGlyphSize * CGFloat(detailGlyphScale)

        ZStack {
            if let resourceName = label.leadingIconResourceName {
                AgentLogoImage(
                    resourceName: resourceName,
                    rendersAsTemplate: true,
                    fallbackLabel: label.leadingIconFallback ?? ""
                )
                .frame(width: glyphSize, height: glyphSize)
            } else if let fallback = label.leadingIconFallback {
                Circle()
                    .fill(.primary.opacity(0.14))

                Text(fallback)
                    .font(.system(size: 7, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .frame(width: SidebarIconMetrics.detailGlyphSize, height: SidebarIconMetrics.detailGlyphSize)
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
        let cacheKey = "\(name)#\(rendersAsTemplate)"
        if let cachedImage = imageCache[cacheKey] {
            return cachedImage
        }

        let url = Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "AgentLogos"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "ProgramLogos"
        ) ?? Bundle.module.url(
            forResource: name,
            withExtension: "svg"
        )

        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }

        if image.size.width <= 0 || image.size.height <= 0 {
            image.size = NSSize(width: 24, height: 24)
        }
        image.isTemplate = rendersAsTemplate
        imageCache[cacheKey] = image
        return image
    }

    @MainActor
    private static var imageCache: [String: NSImage] = [:]
}

private struct SidebarIconDebugOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject private var agentSettings = AgentSettings.shared

    let projectRoot: String?
    let presentation: SidebarPresentation
    let leadingOffset: CGFloat
    @Binding var isPresented: Bool

    @AppStorage(SidebarIconMetrics.programGlyphScaleKey) private var programGlyphScale = SidebarIconMetrics.defaultProgramGlyphScale
    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale
    @AppStorage(SidebarIconMetrics.agentGlyphScaleKey) private var agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale
    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons

    private let panelWidth: CGFloat = 430
    private let topInset: CGFloat = 22
    private let minimumInset: CGFloat = 8
    private let trailingInset: CGFloat = 18

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )

        GeometryReader { geometry in
            panel(palette: palette)
                .padding(.top, topInset)
                .padding(.leading, clampedLeadingOffset(in: geometry.size))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .transition(.opacity)
    }

    private func reset() {
        SidebarIconMetrics.reset()
        programGlyphScale = SidebarIconMetrics.defaultProgramGlyphScale
        detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale
        agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale
        usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
        usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons
    }

    private func clampedLeadingOffset(in size: CGSize) -> CGFloat {
        max(minimumInset, min(leadingOffset, size.width - panelWidth - trailingInset))
    }

    private func panel(palette: SidebarPalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Icon Debug")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.rowText)

                Spacer()

                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.rowText.opacity(0.72))
                .help("Reset icon tuning")

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.rowText.opacity(0.72))
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $usesInlineProgramDetailIcons) {
                    Text("Small terminal icons in detail line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.rowText.opacity(0.72))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: $usesInlineAgentDetailIcons) {
                    Text("Small agent icons in detail line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.rowText.opacity(0.72))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 9) {
                SidebarIconDebugSlider(
                    title: "Program",
                    value: $programGlyphScale,
                    range: 0.70...1.30,
                    step: 0.05,
                    palette: palette
                )

                SidebarIconDebugSlider(
                    title: "Detail",
                    value: $detailGlyphScale,
                    range: 0.70...1.45,
                    step: 0.05,
                    palette: palette
                )

                SidebarIconDebugSlider(
                    title: "Agent",
                    value: $agentGlyphScale,
                    range: 0.70...1.35,
                    step: 0.05,
                    palette: palette
                )
            }

            SidebarIconDebugLivePreview(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SidebarIconDebugResource.Kind.allCases, id: \.self) { kind in
                        SidebarIconDebugResourceSection(
                            title: kind.title,
                            resources: SidebarIconDebugResource.resources(for: kind),
                            palette: palette
                        )
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(14)
        .frame(width: panelWidth)
        .frame(maxHeight: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.rowText.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 14)
    }
}

private struct SidebarIconDebugSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let palette: SidebarPalette

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.rowText.opacity(0.72))
                .frame(width: 52, alignment: .leading)

            Slider(value: $value, in: range, step: step)

            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.rowText.opacity(0.62))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct SidebarIconDebugLivePreview: View {
    let palette: SidebarPalette

    var body: some View {
        HStack(spacing: 10) {
            previewItem("Program") {
                SidebarProgramIcon(
                    label: SidebarTerminalPathLabel(
                        title: "Vite",
                        leadingIconResourceName: "vite",
                        leadingIconFallback: "Vt",
                        leadingIconRendersAsTemplate: true
                    ),
                    isSelected: false,
                    palette: palette
                )
            }

            previewItem("Detail") {
                HStack(spacing: 4) {
                    SidebarDetailIcon(resourceName: "github")
                    Text("owner/repo")
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.rowText.opacity(0.56))
            }

            previewItem("Agent") {
                if let descriptor = AgentToolIconDescriptor(
                    kind: .agent,
                    agentName: "Codex",
                    title: "Codex"
                ) {
                    AgentToolIcon(descriptor: descriptor, isSelected: false, palette: palette)
                }
            }
        }
    }

    private func previewItem<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.headerText)
                .textCase(.uppercase)

            HStack {
                content()
                Spacer(minLength: 0)
            }
            .frame(height: 36)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.rowText.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.rowText.opacity(0.10), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private enum SidebarIconDebugPreviewIcon {
    case agent(String)
    case program(String, String)
    case programFallback(String)
    case none
}

private enum SidebarIconDebugFixtures {
    static let agentCount = 5
    static let terminalCount = 4
    static let commandCount = 2

    static let agentChildren = [
        SidebarIconDebugPreviewAgent(title: "Codex", detail: "tuning sidebar UI", agentName: "Codex"),
        SidebarIconDebugPreviewAgent(title: "Gemini", detail: "checking icon scale", agentName: "Gemini"),
        SidebarIconDebugPreviewAgent(title: "Amp Icons", detail: "template render pass", agentName: "Amp")
    ]
}

private struct SidebarIconDebugPreviewAgent: Identifiable {
    let id = UUID()
    let title: String
    let detail: String?
    let agentName: String
}

private struct SidebarIconDebugAgentPreview: View {
    let palette: SidebarPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarIconDebugPreviewRow(
                title: "Claude",
                detail: "parent agent with nested work",
                icon: .agent("Claude"),
                isSelected: true,
                palette: palette,
                showsDisclosure: true
            )

            SidebarIconDebugAgentChildrenGroup(
                children: SidebarIconDebugFixtures.agentChildren,
                palette: palette,
                isActive: true
            ) { child in
                SidebarIconDebugPreviewRow(
                    title: child.title,
                    detail: child.detail,
                    icon: .agent(child.agentName),
                    isSelected: false,
                    palette: palette,
                    nestingDepth: 1
                )
            }

            SidebarIconDebugPreviewRow(
                title: "Pi",
                detail: "fallback initials agent",
                icon: .agent("Pi"),
                isSelected: false,
                palette: palette
            )
        }
    }
}

private struct SidebarIconDebugAgentChildrenGroup<RowContent: View>: View {
    let children: [SidebarIconDebugPreviewAgent]
    let palette: SidebarPalette
    let isActive: Bool
    let rowContent: (SidebarIconDebugPreviewAgent) -> RowContent

    init(
        children: [SidebarIconDebugPreviewAgent],
        palette: SidebarPalette,
        isActive: Bool,
        @ViewBuilder rowContent: @escaping (SidebarIconDebugPreviewAgent) -> RowContent
    ) {
        self.children = children
        self.palette = palette
        self.isActive = isActive
        self.rowContent = rowContent
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarIconDebugAgentChildrenGuide(
                children: children,
                palette: palette,
                isActive: isActive
            )

            VStack(alignment: .leading, spacing: SidebarLayout.agentTreeRowSpacing) {
                ForEach(children) { child in
                    rowContent(child)
                }
            }
        }
    }
}

private struct SidebarIconDebugAgentChildrenGuide: View {
    let children: [SidebarIconDebugPreviewAgent]
    let palette: SidebarPalette
    let isActive: Bool

    @AppStorage(AgentTreeLayout.guideXKey) private var guideX = AgentTreeLayout.defaultGuideX
    @AppStorage(AgentTreeLayout.guideElbowWidthKey) private var guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
    @AppStorage(AgentTreeLayout.guideElbowStartInsetKey) private var guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
    @AppStorage(AgentTreeLayout.guideConnectorLengthKey) private var guideConnectorLength = AgentTreeLayout.defaultGuideConnectorLength
    @AppStorage(AgentTreeLayout.guideConnectorDashLengthKey) private var guideConnectorDashLength = AgentTreeLayout.defaultGuideConnectorDashLength
    @AppStorage(AgentTreeLayout.guideConnectorDashGapKey) private var guideConnectorDashGap = AgentTreeLayout.defaultGuideConnectorDashGap
    @AppStorage(AgentTreeLayout.guideConnectorOffsetXKey) private var guideConnectorOffsetX = AgentTreeLayout.defaultGuideConnectorOffsetX
    @AppStorage(AgentTreeLayout.guideConnectorOffsetYKey) private var guideConnectorOffsetY = AgentTreeLayout.defaultGuideConnectorOffsetY
    @AppStorage(AgentTreeLayout.guideTopOverlapKey) private var guideTopOverlap = AgentTreeLayout.defaultGuideTopOverlap
    @AppStorage(AgentTreeLayout.guideBottomOverlapKey) private var guideBottomOverlap = AgentTreeLayout.defaultGuideBottomOverlap
    @AppStorage(AgentTreeLayout.childDetailRowHeightKey) private var childDetailRowHeight = AgentTreeLayout.defaultChildDetailRowHeight

    var body: some View {
        let x = CGFloat(guideX)
        let elbowWidth = CGFloat(guideElbowWidth)
        let elbowX = x + CGFloat(guideElbowStartInset)
        let connectorLength = CGFloat(guideConnectorLength)
        let connectorDashLength = CGFloat(guideConnectorDashLength)
        let connectorDashGap = CGFloat(guideConnectorDashGap)
        let connectorX = x + CGFloat(guideConnectorOffsetX)
        let connectorY = CGFloat(guideConnectorOffsetY)
        let topOverlap = CGFloat(guideTopOverlap)
        let bottomOverlap = CGFloat(guideBottomOverlap)
        let color = palette.rowText.opacity(isActive ? 0.16 : 0.08)
        let lastCenterY = centerY(forChildAt: max(children.count - 1, 0))

        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: connectorX, y: connectorY - connectorLength))
                path.addLine(to: CGPoint(x: connectorX, y: connectorY + connectorLength))
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [connectorDashLength, connectorDashGap])
            )

            Rectangle()
                .fill(color)
                .frame(width: 1, height: lastCenterY + topOverlap + bottomOverlap)
                .offset(x: x, y: -topOverlap)

            ForEach(Array(children.enumerated()), id: \.element.id) { index, _ in
                Rectangle()
                    .fill(color)
                    .frame(width: elbowWidth, height: 1)
                    .offset(x: elbowX, y: centerY(forChildAt: index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func centerY(forChildAt index: Int) -> CGFloat {
        guard index > 0 else { return rowHeight / 2 }
        return rowHeight * CGFloat(index)
            + SidebarLayout.agentTreeRowSpacing * CGFloat(index)
            + rowHeight / 2
    }

    private var rowHeight: CGFloat {
        CGFloat(childDetailRowHeight)
    }
}

private struct SidebarIconDebugTerminalPreview: View {
    let palette: SidebarPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarIconDebugPreviewRow(
                title: "shot",
                detail: "farbun-dev/shot",
                icon: .none,
                detailIconResourceName: "github",
                isSelected: true,
                palette: palette
            )

            SidebarIconDebugPreviewRow(
                title: "Vite",
                detail: "bunx vite --host 0.0.0.0",
                icon: .program("vite", "Vt"),
                isSelected: false,
                palette: palette
            )

            SidebarIconDebugPreviewRow(
                title: "nvim ContentView.swift",
                detail: "Nvim",
                icon: .program("neovim", "Nv"),
                isSelected: false,
                palette: palette
            )

            SidebarIconDebugPreviewRow(
                title: "FastAPI",
                detail: "uv run fastapi dev",
                icon: .programFallback("Fa"),
                isSelected: false,
                palette: palette
            )
        }
    }
}

private struct SidebarIconDebugCommandPreview: View {
    let palette: SidebarPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarIconDebugCommandPreviewRow(
                title: "Dev Server",
                detail: "farbun-dev/shot",
                detailIconResourceName: "github",
                isSelected: true,
                palette: palette
            )

            SidebarIconDebugCommandPreviewRow(
                title: "Lint",
                detail: "swift test --no-parallel",
                detailIconResourceName: nil,
                isSelected: false,
                palette: palette
            )
        }
    }
}

private struct SidebarIconDebugCommandPreviewRow: View {
    let title: String
    let detail: String
    let detailIconResourceName: String?
    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let detailIconResourceName {
                        SidebarDetailIcon(resourceName: detailIconResourceName)
                    }

                    Text(detail)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                .frame(width: 22, height: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
        .padding(.leading, SidebarLayout.rowHorizontalInset)
        .padding(.trailing, SidebarLayout.rowHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.selectedFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.selectedStroke, lineWidth: 1)
                    }
            }
        }
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
    }
}

private struct SidebarIconDebugPreviewRow: View {
    let title: String
    let detail: String?
    let icon: SidebarIconDebugPreviewIcon
    var detailIconResourceName: String? = nil
    let isSelected: Bool
    let palette: SidebarPalette
    var nestingDepth = 0
    var showsDisclosure = false

    @AppStorage(AgentTreeLayout.guideXKey) private var guideX = AgentTreeLayout.defaultGuideX
    @AppStorage(AgentTreeLayout.guideElbowWidthKey) private var guideElbowWidth = AgentTreeLayout.defaultGuideElbowWidth
    @AppStorage(AgentTreeLayout.guideElbowStartInsetKey) private var guideElbowStartInset = AgentTreeLayout.defaultGuideElbowStartInset
    @AppStorage(AgentTreeLayout.disclosureOffsetKey) private var disclosureOffset = AgentTreeLayout.defaultDisclosureOffset
    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons

    var body: some View {
        let nested = nestingDepth > 0
        let nestedGuideReservationWidth = CGFloat(guideX + guideElbowStartInset + guideElbowWidth + 2)
        let nestedBackgroundLeadingInset = nested
            ? SidebarLayout.rowHorizontalInset + nestedGuideReservationWidth + 2
            : 0

        HStack(spacing: nested ? 6 : 8) {
            if nested {
                Color.clear
                    .frame(width: nestedGuideReservationWidth, height: rowHeight)
            }

            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.54))
                    .frame(width: 14, height: 22)
                    .offset(x: CGFloat(disclosureOffset))
                    .padding(.trailing, -6)
            }

            if shouldShowLeadingIcon {
                iconView
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                    .lineLimit(1)

                if let detail {
                    HStack(spacing: 4) {
                        if let detailIconResourceName {
                            SidebarDetailIcon(resourceName: detailIconResourceName)
                        } else if shouldShowInlineIcon {
                            inlineIconView
                        }

                        Text(detail)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .padding(.leading, SidebarLayout.rowHorizontalInset)
        .padding(.trailing, SidebarLayout.rowHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.selectedFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.selectedStroke, lineWidth: 1)
                    }
                    .padding(.leading, nestedBackgroundLeadingInset)
            }
        }
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
    }

    private var shouldShowLeadingIcon: Bool {
        !shouldShowInlineIcon
    }

    private var shouldShowInlineIcon: Bool {
        detail != nil && usesInlineDetailIconsForIcon && !isEmptyIcon
    }

    private var usesInlineDetailIconsForIcon: Bool {
        switch icon {
        case .agent:
            usesInlineAgentDetailIcons
        case .program, .programFallback:
            usesInlineProgramDetailIcons
        case .none:
            false
        }
    }

    private var isEmptyIcon: Bool {
        if case .none = icon {
            return true
        }
        return false
    }

    private var rowHeight: CGFloat {
        if nestingDepth > 0 {
            CGFloat(detail == nil ? AgentTreeLayout.defaultChildRowHeight : AgentTreeLayout.defaultChildDetailRowHeight)
        } else {
            detail == nil ? 42 : 50
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .agent(let name):
            if let descriptor = AgentToolIconDescriptor(
                kind: .agent,
                agentName: name,
                title: name
            ) {
                AgentToolIcon(descriptor: descriptor, isSelected: isSelected, palette: palette)
            } else {
                Color.clear
                    .frame(width: SidebarIconMetrics.agentFrameSize, height: SidebarIconMetrics.agentFrameSize)
            }
        case .program(let resourceName, let fallback):
            SidebarProgramIcon(
                label: SidebarTerminalPathLabel(
                    title: title,
                    leadingIconResourceName: resourceName,
                    leadingIconFallback: fallback,
                    leadingIconRendersAsTemplate: true
                ),
                isSelected: isSelected,
                palette: palette
            )
        case .programFallback(let fallback):
            SidebarProgramIcon(
                label: SidebarTerminalPathLabel(
                    title: title,
                    leadingIconFallback: fallback
                ),
                isSelected: isSelected,
                palette: palette
            )
        case .none:
            Color.clear
                .frame(width: SidebarIconMetrics.programFrameSize, height: SidebarIconMetrics.programFrameSize)
        }
    }

    @ViewBuilder
    private var inlineIconView: some View {
        switch icon {
        case .agent(let name):
            if let descriptor = AgentToolIconDescriptor(
                kind: .agent,
                agentName: name,
                title: name
            ) {
                AgentToolInlineIcon(descriptor: descriptor)
            }
        case .program(let resourceName, let fallback):
            SidebarProgramInlineIcon(
                label: SidebarTerminalPathLabel(
                    title: title,
                    leadingIconResourceName: resourceName,
                    leadingIconFallback: fallback,
                    leadingIconRendersAsTemplate: true
                )
            )
        case .programFallback(let fallback):
            SidebarProgramInlineIcon(
                label: SidebarTerminalPathLabel(
                    title: title,
                    leadingIconFallback: fallback
                )
            )
        case .none:
            EmptyView()
        }
    }
}

private struct SidebarIconDebugResourceSection: View {
    let title: String
    let resources: [SidebarIconDebugResource]
    let palette: SidebarPalette

    private let columns = [
        GridItem(.adaptive(minimum: 72), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.headerText)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(resources) { resource in
                    SidebarIconDebugTile(resource: resource, palette: palette)
                }
            }
        }
    }
}

private struct SidebarIconDebugTile: View {
    let resource: SidebarIconDebugResource
    let palette: SidebarPalette

    @AppStorage(SidebarIconMetrics.programGlyphScaleKey) private var programGlyphScale = SidebarIconMetrics.defaultProgramGlyphScale
    @AppStorage(SidebarIconMetrics.agentGlyphScaleKey) private var agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }

                AgentLogoImage(
                    resourceName: resource.name,
                    rendersAsTemplate: true,
                    fallbackLabel: resource.fallback
                )
                .frame(width: glyphSize, height: glyphSize)
                .foregroundStyle(Color.white)
            }
            .frame(width: 46, height: 38)

            Text(resource.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.rowText.opacity(0.66))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 72)
    }

    private var glyphSize: CGFloat {
        switch resource.kind {
        case .agents:
            SidebarIconMetrics.agentGlyphSize * CGFloat(agentGlyphScale)
        case .programs:
            SidebarIconMetrics.programGlyphSize * CGFloat(programGlyphScale)
        }
    }
}

private struct SidebarIconDebugResource: Identifiable {
    enum Kind: CaseIterable {
        case agents
        case programs

        var title: String {
            switch self {
            case .agents: "Agent Logos"
            case .programs: "Program Logos"
            }
        }
    }

    let kind: Kind
    let name: String
    let fallback: String

    var id: String {
        "\(kind)-\(name)"
    }

    static func resources(for kind: Kind) -> [SidebarIconDebugResource] {
        all.filter { $0.kind == kind }
    }

    private static let all: [SidebarIconDebugResource] = [
        .init(kind: .agents, name: "amp", fallback: "A"),
        .init(kind: .agents, name: "claude", fallback: "Cl"),
        .init(kind: .agents, name: "gemini", fallback: "Ge"),
        .init(kind: .agents, name: "github", fallback: "Gh"),
        .init(kind: .agents, name: "openai", fallback: "Cx"),
        .init(kind: .programs, name: "bun", fallback: "Bn"),
        .init(kind: .programs, name: "deno", fallback: "De"),
        .init(kind: .programs, name: "docker", fallback: "Do"),
        .init(kind: .programs, name: "fastapi", fallback: "Fa"),
        .init(kind: .programs, name: "git", fallback: "Gt"),
        .init(kind: .programs, name: "gnuemacs", fallback: "Em"),
        .init(kind: .programs, name: "go", fallback: "Go"),
        .init(kind: .programs, name: "neovim", fallback: "Nv"),
        .init(kind: .programs, name: "nextdotjs", fallback: "Nx"),
        .init(kind: .programs, name: "nodedotjs", fallback: "JS"),
        .init(kind: .programs, name: "npm", fallback: "np"),
        .init(kind: .programs, name: "pnpm", fallback: "pn"),
        .init(kind: .programs, name: "python", fallback: "Py"),
        .init(kind: .programs, name: "pytest", fallback: "Py"),
        .init(kind: .programs, name: "ruff", fallback: "Rf"),
        .init(kind: .programs, name: "rust", fallback: "Rs"),
        .init(kind: .programs, name: "swift", fallback: "Sw"),
        .init(kind: .programs, name: "uv", fallback: "uv"),
        .init(kind: .programs, name: "vim", fallback: "Vi"),
        .init(kind: .programs, name: "vite", fallback: "Vt"),
        .init(kind: .programs, name: "yarn", fallback: "Ya")
    ]
}

private struct SidebarPalette {
    let backgroundMaterial: AnyShapeStyle
    let backgroundTint: Color
    let backgroundOverlay: [Color]
    let projectAccent: Color
    let showsProjectAccent: Bool
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
        projectAccent: Color,
        showsProjectAccent: Bool,
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
        self.projectAccent = projectAccent
        self.showsProjectAccent = showsProjectAccent
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
        sidebarBackgroundDepth: Double,
        projectColor: ProjectIdentityColor? = nil,
        projectColorDisplayMode: ProjectColorDisplayMode = .accent,
        presentation: SidebarPresentation
    ) {
        let sample = SidebarThemeSample(
            themeColors: themeColors,
            fallbackColorScheme: fallbackColorScheme,
            sidebarBackgroundDepth: sidebarBackgroundDepth,
            projectColor: projectColor,
            projectColorDisplayMode: projectColorDisplayMode
        )
        let background = Color(nsColor: sample.background)
        let sidebarBackground = Color(nsColor: sample.sidebarBackground)
        let foreground = Color(nsColor: sample.foreground)
        let selection = sample.selectionBackground.map { Color(nsColor: $0) }
        let projectAccent = sample.projectAccent.map { Color(nsColor: $0) } ?? foreground.opacity(0)
        let useAccentChrome = sample.projectColorDisplayMode == .accent
        let selectedFill = useAccentChrome
            ? sample.projectAccent.map { Color(nsColor: $0).opacity(sample.isDark ? 0.24 : 0.18) }
            ?? selection?.opacity(sample.isDark ? 0.44 : 0.34)
            : selection?.opacity(sample.isDark ? 0.44 : 0.34)

        if sample.isDark {
            self = Self(
                backgroundMaterial: AnyShapeStyle(sidebarBackground),
                backgroundTint: presentation == .floating ? background.opacity(0.10) : .clear,
                backgroundOverlay: [
                    foreground.opacity(presentation == .floating ? 0.035 : 0),
                    .clear
                ],
                projectAccent: projectAccent,
                showsProjectAccent: useAccentChrome && sample.projectAccent != nil,
                headerText: foreground.opacity(0.58),
                rowText: foreground.opacity(0.78),
                selectedText: foreground.opacity(0.96),
                hoverFill: foreground.opacity(0.08),
                selectedFill: selectedFill ?? foreground.opacity(0.13),
                selectedStroke: useAccentChrome
                    ? sample.projectAccent.map { Color(nsColor: $0).opacity(0.42) } ?? foreground.opacity(0.16)
                    : foreground.opacity(0.16),
                selectedShadow: Color.black.opacity(presentation == .floating ? 0.22 : 0.16)
            )
        } else {
            self = Self(
                backgroundMaterial: AnyShapeStyle(sidebarBackground),
                backgroundTint: presentation == .floating ? background.opacity(0.08) : .clear,
                backgroundOverlay: [
                    Color.white.opacity(presentation == .floating ? 0.08 : 0),
                    .clear
                ],
                projectAccent: projectAccent,
                showsProjectAccent: useAccentChrome && sample.projectAccent != nil,
                headerText: foreground.opacity(0.52),
                rowText: foreground.opacity(0.74),
                selectedText: foreground.opacity(0.92),
                hoverFill: foreground.opacity(0.06),
                selectedFill: selectedFill ?? Color.white.opacity(0.64),
                selectedStroke: useAccentChrome
                    ? sample.projectAccent.map { Color(nsColor: $0).opacity(0.34) } ?? foreground.opacity(0.10)
                    : foreground.opacity(0.10),
                selectedShadow: Color.black.opacity(presentation == .floating ? 0.12 : 0.07)
            )
        }
    }
}

struct SidebarThemeSample {
    let background: NSColor
    let foreground: NSColor
    let selectionBackground: NSColor?
    let projectAccent: NSColor?
    let sidebarBackgroundDepth: CGFloat
    let projectColorDisplayMode: ProjectColorDisplayMode

    var isDark: Bool {
        background.relativeLuminance < 0.50
    }

    var sidebarBackground: NSColor {
        let base: NSColor
        if isDark {
            base = background.mixed(toward: foreground, amount: sidebarBackgroundDepth)
        } else {
            base = background.mixed(toward: .black, amount: sidebarBackgroundDepth)
        }
        guard projectColorDisplayMode == .tinted, let projectAccent else { return base }
        return base.mixed(toward: projectAccent, amount: isDark ? 0.12 : 0.09)
    }

    init(
        themeColors: TerminalThemeColors,
        fallbackColorScheme: ColorScheme,
        sidebarBackgroundDepth: Double,
        projectColor: ProjectIdentityColor? = nil,
        projectColorDisplayMode: ProjectColorDisplayMode = .accent
    ) {
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
        if projectColorDisplayMode == .off {
            projectAccent = nil
        } else {
            projectAccent = projectColor.flatMap { NSColor(hexRGB: $0.hexRGB) }
        }
        self.sidebarBackgroundDepth = CGFloat(min(max(sidebarBackgroundDepth, 0), 0.40))
        self.projectColorDisplayMode = projectColorDisplayMode
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

    var hexRGBString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
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
            srgbRed: base.redComponent * inverseAmount + other.redComponent * clampedAmount,
            green: base.greenComponent * inverseAmount + other.greenComponent * clampedAmount,
            blue: base.blueComponent * inverseAmount + other.blueComponent * clampedAmount,
            alpha: base.alphaComponent * inverseAmount + other.alphaComponent * clampedAmount
        )
    }
}

private struct TerminalSceneView: View {
    @Environment(\.colorScheme) private var colorScheme
    let session: TerminalSession
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
