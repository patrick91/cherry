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
    private let sidebarRevealHotZoneWidth: CGFloat = 24
    private let sidebarRevealHoverSlop: CGFloat = 10
    private let sidebarRevealDelay: Duration = .milliseconds(85)
    private let sidebarDismissDelay: Duration = .milliseconds(160)
    private let trafficLightAnimatedFinalSyncDelay: Duration = .milliseconds(600)
    private let titlebarProjectPickerLeadingInset = TitlebarProjectPickerLayout.leadingInset

    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let openProject: (CherryProject) -> Void
    @Binding var isSidebarHidden: Bool
    @Binding var isSidebarRevealed: Bool
    @Binding var isCursorOverSidebar: Bool
    @Binding var storedSidebarWidth: Double
    @State private var trafficLights = TrafficLightController()
    @State private var isCursorInsideSidebarRevealRegion = false
    @State private var sidebarRevealTask: Task<Void, Never>?
    @State private var sidebarDismissTask: Task<Void, Never>?
    @State private var trafficLightFinalSyncTask: Task<Void, Never>?
    @State private var floatingSidebarAnimationDepth = 0

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
                    todoStore: todoStore,
                    projectRoot: projectRoot,
                    includeLeadingPadding: isSidebarHidden
                )
                    .ignoresSafeArea(.all, edges: .top)
            }

            // Keep only the sidebar presentation that can currently be seen.
            // Each sidebar contains the complete sessions/agents/commands/todos
            // tree; retaining both at steady state doubled the SwiftUI work of a
            // workspace switch. Transition flags keep both alive only for the
            // brief handoff where they genuinely overlap.
            if isSidebarHidden || isSidebarRevealed || floatingSidebarAnimationDepth > 0 {
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
            }

            // Project picker, anchored to the window's top-leading corner so
            // it shares coordinate space with the traffic-light overlay
            // (which positions correctly at this level). It rides the same
            // chrome translation as the traffic lights so it slides off
            // with the sidebar, and is hidden via offset when the sidebar
            // is fully gone.
            TitlebarProjectPicker(
                settings: AgentSettings.shared,
                repository: repository,
                chromeState: chromeState,
                projectRoot: projectRoot,
                presentation: isSidebarRevealed ? .floating : .docked,
                maximumWidth: titlebarProjectPickerMaximumWidth
            )
            .padding(.leading, titlebarProjectPickerLeadingInset)
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

            if let omniBar = chromeState.omniBar {
                OmniBarOverlay(
                    window: OmniBarWindow(
                        projectRoot: projectRoot,
                        repository: repository,
                        workspace: workspace,
                        chromeState: chromeState
                    ),
                    request: omniBar,
                    openProject: openProject,
                    openSettings: { openSettings() },
                    restoreFocus: restoreTerminalFocus
                )
                .zIndex(2_000)
            }

            if chromeState.isSidebarPlaygroundPresented {
                SidebarPlaygroundOverlay(
                    projectRoot: projectRoot,
                    livePresentation: isSidebarRevealed ? .floating : .docked,
                    leadingOffset: iconDebugOverlayLeadingOffset,
                    isPresented: $chromeState.isSidebarPlaygroundPresented
                )
                .zIndex(2_120)
            }

            if chromeState.isCommandPalettePlaygroundPresented {
                CommandPalettePlaygroundOverlay(
                    chromeState: chromeState,
                    isPresented: $chromeState.isCommandPalettePlaygroundPresented
                )
                .zIndex(2_200)
            }

            if isSidebarHidden {
                // Passive tracking keeps the edge target alive while the
                // floating sidebar appears under the cursor, then expands to
                // the revealed sidebar so exits have a reliable close path.
                SidebarRevealHoverTrackingOverlay { hovering in
                    handleSidebarRevealHoverChange(hovering)
                }
                .frame(width: sidebarRevealTrackingWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .vertical)
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .background {
            AppShellBackground(projectRoot: repository.repositoryRoot)
                .ignoresSafeArea(.all)
        }
        .background(AppShortcutMonitor(
            repository: repository,
            workspace: workspace,
            chromeState: chromeState,
            todoStore: todoStore,
            projectRoot: projectRoot,
            openSettings: { openSettings() }
        ))
        .background(WindowConfigurator())
        .background(TabCloseAlertPresenter(chromeState: chromeState))
        .frame(minWidth: 320, minHeight: 460)
        .sheet(isPresented: $chromeState.isHostedSessionsPresented) {
            HostedSessionsSheet(workspace: workspace, chromeState: chromeState)
        }
        .sheet(isPresented: $chromeState.isAddDevicePresented) {
            AddDeviceSheet(model: AddDeviceModel()) { device in
                // Its home folder opens, where Add Project on <Mac>… and its
                // sessions' projects are one menu away.
                if let home = device.homeDirectory {
                    openProject(CherryProject(root: device.projectKey(path: home)))
                }
            }
        }
        .sheet(item: $chromeState.addProjectDevice) { reference in
            AddDeviceProjectSheet(deviceID: reference.id, store: .shared) { key in
                openProject(CherryProject(root: key))
            }
        }
        .confirmationDialog(
            "Close Agent Group?",
            isPresented: pendingAgentGroupCloseBinding,
            titleVisibility: .visible
        ) {
            if let session = pendingAgentGroupCloseSession {
                if canCloseAgentGroup(session) {
                    Button("Close Parent and Sub-Agents", role: .destructive) {
                        let allowEmptyWorkspace = chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace
                        SessionCloseCoordinator.closeTabs(
                            [session] + workspace.descendantAgentSessions(of: session),
                            in: workspace,
                            chromeState: chromeState
                        ) {
                            workspace.closeAgentGroup(session, allowEmptyWorkspace: allowEmptyWorkspace)
                        }
                        chromeState.pendingAgentGroupCloseSessionID = nil
                        chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace = false
                    }
                }

                Button("Close Parent Only") {
                    SessionCloseCoordinator.closeTabs([session], in: workspace, chromeState: chromeState) {
                        workspace.close(session)
                    }
                    chromeState.pendingAgentGroupCloseSessionID = nil
                    chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace = false
                }

                let group = [session] + workspace.descendantAgentSessions(of: session)
                if canCloseAgentGroup(session),
                   SessionCloseCoordinator.canDetachInstead(group, policy: workspace.backendPolicy) {
                    Button("Detach Parent and Sub-Agents") {
                        let allowEmptyWorkspace = chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace
                        SessionCloseCoordinator.closeTabs(
                            group, in: workspace, chromeState: chromeState, intent: .userDetachedTab
                        ) {
                            workspace.closeAgentGroup(
                                session, allowEmptyWorkspace: allowEmptyWorkspace, intent: .userDetachedTab
                            )
                        }
                        chromeState.pendingAgentGroupCloseSessionID = nil
                        chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace = false
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                chromeState.pendingAgentGroupCloseSessionID = nil
                chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace = false
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
                beginFloatingSidebarAnimation()
                withAnimation(.snappy(duration: 0.18)) {
                    isSidebarRevealed = false
                }
                // The docked sidebar's `.onHover` won't fire when it
                // appears under a stationary cursor (NSTrackingArea fires on
                // entry, not on becoming active). Seed the flag from the
                // real cursor position so a subsequent Cmd+S can switch
                // back to floating without requiring a mouse wiggle —
                // but never assume: blindly forcing `true` here is how the
                // flag went stale and made keyboard-only Cmd+S take the
                // unanimated phantom-swap branch.
                isCursorOverSidebar = chromeState.isCursorActuallyOverLeadingSidebar(width: sidebarWidth)
            }
            // The docked sidebar's `.onHover` only fires when its hit area
            // is active, so once it's hidden it can't update this flag. Reset
            // it so a stale `true` doesn't carry over and trigger the
            // "switch to floating" branch on the next Cmd+S.
            if hidden {
                isCursorOverSidebar = false
            } else {
                resetSidebarRevealTracking()
            }
            syncTrafficLightsForCurrentTransition()
        }
        .onChange(of: isSidebarRevealed) { _, revealed in
            if revealed {
                if isCursorInsideSidebarRevealRegion
                    || chromeState.isCursorActuallyOverLeadingSidebar(
                        width: sidebarWidth + floatingSidebarLeadingInset
                    )
                {
                    isCursorInsideSidebarRevealRegion = true
                    cancelSidebarDismiss()
                } else {
                    // The floating sidebar became revealed with the cursor
                    // somewhere else (stale-flag Cmd+S swap, programmatic
                    // chrome change). Hover tracking will never deliver the
                    // mouseExited that normally dismisses it, so without
                    // this watchdog `isSidebarRevealed` sticks forever —
                    // parking the traffic lights over the content and
                    // locking Cmd+S into its unanimated swap branch.
                    scheduleSidebarDismiss()
                }
            } else {
                cancelSidebarDismiss()
            }
            syncTrafficLightsForCurrentTransition()
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
            trafficLights.update(
                docked: isSidebarHidden ? 0 : sidebarWidth,
                floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
                sidebarWidth: sidebarWidth
            )
        }
        .onDisappear {
            resetSidebarRevealTracking()
            cancelTrafficLightFinalSync()
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
                chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace = false
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

    private var titlebarProjectPickerMaximumWidth: CGFloat {
        max(
            0,
            sidebarWidth - titlebarProjectPickerLeadingInset - SidebarLayout.trailingInset
        )
    }

    private var sidebarRevealTrackingWidth: CGFloat {
        if isSidebarRevealed {
            return sidebarWidth + floatingSidebarLeadingInset + sidebarRevealHoverSlop
        }
        return sidebarRevealHotZoneWidth
    }

    private func canCloseAgentGroup(_ session: TerminalSession) -> Bool {
        chromeState.pendingAgentGroupCloseAllowsEmptyWorkspace
            || workspace.sessions.count > workspace.descendantAgentSessions(of: session).count + 1
    }

    private var dockedSidebar: some View {
        SidebarTabsView(
            repository: repository,
            workspace: workspace,
            chromeState: chromeState,
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
        Group {
            if !isSidebarHidden || chromeState.isSidebarAnimating {
                dockedSidebar
            }
        }
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
            repository: repository,
            workspace: workspace,
            chromeState: chromeState,
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

    // Belt-and-suspenders for non-animated updates: SwiftUI's Animatable
    // setter only fires inside an animation transaction. Animated sidebar
    // changes schedule this after the animation window so the controller
    // catches the final state without snapping ahead mid-flight.
    private func syncTrafficLights() {
        trafficLights.update(
            docked: isSidebarHidden ? 0 : sidebarWidth,
            floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
            sidebarWidth: sidebarWidth
        )
    }

    private func syncTrafficLightsForCurrentTransition() {
        if chromeState.isSidebarAnimating || floatingSidebarAnimationDepth > 0 {
            scheduleTrafficLightFinalSync()
        } else {
            cancelTrafficLightFinalSync()
            syncTrafficLights()
        }
    }

    private func scheduleTrafficLightFinalSync() {
        cancelTrafficLightFinalSync()
        trafficLightFinalSyncTask = Task { @MainActor in
            do {
                try await Task.sleep(for: trafficLightAnimatedFinalSyncDelay)
            } catch {
                return
            }
            syncTrafficLights()
        }
    }

    private func syncDisabledFeatureSelection(features: ProjectFeatureSettings) {
        if !features.todosEnabled, chromeState.isTodoPanePresented {
            chromeState.selectTerminal()
        }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    private func handleSidebarRevealHoverChange(_ hovering: Bool) {
        isCursorInsideSidebarRevealRegion = hovering

        if hovering {
            cancelSidebarDismiss()
            scheduleSidebarReveal()
        } else {
            cancelSidebarReveal()
            scheduleSidebarDismiss()
        }
    }

    private func scheduleSidebarReveal() {
        guard isSidebarHidden, !isSidebarRevealed else { return }
        cancelSidebarReveal()
        sidebarRevealTask = Task { @MainActor in
            do {
                try await Task.sleep(for: sidebarRevealDelay)
            } catch {
                return
            }

            guard isCursorInsideSidebarRevealRegion, isSidebarHidden, !isSidebarRevealed else { return }
            beginFloatingSidebarAnimation()
            withAnimation(.snappy(duration: 0.18)) {
                isSidebarRevealed = true
            }
        }
    }

    private func scheduleSidebarDismiss() {
        guard isSidebarHidden, isSidebarRevealed else { return }
        cancelSidebarDismiss()
        sidebarDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: sidebarDismissDelay)
            } catch {
                return
            }

            guard !isCursorInsideSidebarRevealRegion, isSidebarHidden, isSidebarRevealed else { return }
            beginFloatingSidebarAnimation()
            withAnimation(.snappy(duration: 0.18)) {
                isSidebarRevealed = false
            }
        }
    }

    private func beginFloatingSidebarAnimation() {
        floatingSidebarAnimationDepth += 1
        Task { @MainActor in
            do {
                try await Task.sleep(for: trafficLightAnimatedFinalSyncDelay)
            } catch {
                return
            }
            floatingSidebarAnimationDepth = max(0, floatingSidebarAnimationDepth - 1)
            syncTrafficLightsForCurrentTransition()
        }
    }

    private func cancelSidebarReveal() {
        sidebarRevealTask?.cancel()
        sidebarRevealTask = nil
    }

    private func cancelSidebarDismiss() {
        sidebarDismissTask?.cancel()
        sidebarDismissTask = nil
    }

    private func cancelTrafficLightFinalSync() {
        trafficLightFinalSyncTask?.cancel()
        trafficLightFinalSyncTask = nil
    }

    private func resetSidebarRevealTracking() {
        isCursorInsideSidebarRevealRegion = false
        cancelSidebarReveal()
        cancelSidebarDismiss()
    }
}

private struct SidebarRevealHoverTrackingOverlay: NSViewRepresentable {
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarRevealHoverTrackingView {
        let view = SidebarRevealHoverTrackingView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: SidebarRevealHoverTrackingView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

private final class SidebarRevealHoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverStateFromWindow()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHoverStateFromWindow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let nextTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        refreshHoverStateFromWindow()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    func refreshHoverStateFromWindow() {
        // A window that ignores mouse events is never under the pointer.
        guard let window, !window.ignoresMouseEvents else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovering(bounds.contains(location))
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChange?(hovering)
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

private struct TabCloseAlertPresenter: NSViewRepresentable {
    @ObservedObject var chromeState: ProjectWindowChromeState

    func makeNSView(context: Context) -> TabCloseAlertPresenterView {
        let view = TabCloseAlertPresenterView()
        view.chromeState = chromeState
        return view
    }

    func updateNSView(_ nsView: TabCloseAlertPresenterView, context: Context) {
        nsView.chromeState = chromeState
        nsView.presentIfNeeded()
    }
}

/// Asks the window's pending "Close “<name>”?" (`TabCloseQuestion`) as a
/// sheet, and passes its answer on (`SessionCloseCoordinator.answerTabClose`).
@MainActor
final class TabCloseAlertPresenterView: NSView {
    weak var chromeState: ProjectWindowChromeState?
    private var presentedRequestID: UUID?

    func presentIfNeeded() {
        guard let chromeState,
              let request = chromeState.pendingTabClose,
              presentedRequestID != request.id
        else {
            return
        }
        presentedRequestID = request.id

        guard let question = SessionCloseCoordinator.question(for: request) else {
            // Its tab closed, or its program stopped, meanwhile: nothing to
            // ask. Not from inside this SwiftUI update.
            DispatchQueue.main.async { [weak self, weak chromeState] in
                self?.presentedRequestID = nil
                SessionCloseCoordinator.answerTabClose(.close, to: request, chromeState: chromeState)
            }
            return
        }

        let alert = question.makeAlert()
        let answer: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, weak chromeState] response in
            self?.presentedRequestID = nil
            SessionCloseCoordinator.answerTabClose(question.answer(for: response), to: request, chromeState: chromeState)
        }
        if let window {
            // ViewBridge loads lazily, so retry the compatibility hook at the exact
            // point where AppKit may create an NSRemoteView-backed alert sheet.
            RemoteViewCrashGuard.installIfNeeded()
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer(response) }
            }
        } else {
            answer(alert.runModal())
        }
    }
}

private struct DetailPaneView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject private var agentSettings = AgentSettings.shared
    let projectRoot: String?
    let includeLeadingPadding: Bool

    var body: some View {
        let features = agentSettings.projectFeatures(for: projectRoot)
        Group {
            if features.todosEnabled, chromeState.isTodoPanePresented {
                TodoPaneView(todoStore: todoStore, chromeState: chromeState)
            } else if let idleCommand = focusedIdleCommand {
                IdleCommandView(
                    command: idleCommand,
                    onStart: { startIdleCommand(idleCommand) },
                    onCancel: { chromeState.selectTerminal() }
                )
            } else if workspace.selectedSession != nil {
                TerminalSplitSceneView(
                    workspace: workspace,
                    chromeState: chromeState
                )
            } else {
                ContentUnavailableView {
                    Label("No Active Session", systemImage: "rectangle.stack")
                } description: {
                    Text("Open a terminal to get started.")
                } actions: {
                    Button("New Terminal") {
                        _ = workspace.addSession()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlayPreferenceValue(ProjectWindowToastObstacles.self, alignment: .bottom) { bottomBars in
            // Notices that ask nothing, such as a closed tab's Undo or a
            // detached tab's program running on (`ClosedTabNotice`), above
            // the pane's bottom bars.
            ProjectWindowToastOverlay(toasts: chromeState.toasts, closedTabs: chromeState.closedTabs, obstacles: bottomBars)
        }
        .padding(.top, 5)
        .padding(.leading, includeLeadingPadding ? 5 : 0)
        .padding(.trailing, 5)
        .padding(.bottom, 5)
        .onChange(of: todoStore.todos) { _, todos in
            guard let selectedID = chromeState.selectedTodoID,
                  !todos.contains(where: { $0.id == selectedID })
            else { return }
            chromeState.selectTodo(id: nil)
        }
        .onChange(of: chromeState.isShowingTerminalContent) { _, isShowingTerminalContent in
            if isShowingTerminalContent {
                workspace.clearUnreadNotificationForSelectedSession()
                if NSApp.isActive {
                    workspace.acknowledgeAgentResultForSelectedSession()
                }
            }
        }
    }

    private var focusedIdleCommand: ProjectCommandDefinition? {
        guard let name = chromeState.focusedIdleCommandName else { return nil }
        return agentSettings.launchableProjectCommands(for: projectRoot)
            .first { $0.name == name }
    }

    private func startIdleCommand(_ command: ProjectCommandDefinition, waitingForRestore: Bool = true) {
        guard command.isLaunchable,
              let root = agentSettings.resolvedProject(for: projectRoot).validProjectRoot
        else { return }
        if waitingForRestore, workspace.projectCommandSession(named: command.name) == nil,
           workspace.isRestoringCommand(named: command.name) {
            // Its saved tab may still come back (in any window of the
            // project): start (or show) it once the restore answered, never
            // as a second copy.
            let workspace = workspace
            Task { @MainActor in
                await workspace.waitUntilRestored(commandNamed: command.name)
                startIdleCommand(command, waitingForRestore: false)
            }
            return
        }
        // A command runs in one tab across the project's windows: another
        // window's tab is shown there.
        if let existingSession = workspace.projectCommandSession(named: command.name) {
            existingSession.restartManagedCommandIfNeeded()
            show(existingSession)
        } else {
            chromeState.selectTerminal()
            workspace.addCommandSession(command: command, projectRoot: root)
        }
    }

    /// Shows a command's tab: here when it is this window's, else in the
    /// window of the project that has it (`revealSession(id:)`).
    private func show(_ session: TerminalSession) {
        guard workspace.session(withID: session.id) === session else {
            ProjectWindowRegistry.shared.revealSession(id: session.id)
            return
        }
        chromeState.selectTerminal()
        workspace.select(session)
    }
}

private struct IdleCommandView: View {
    let command: ProjectCommandDefinition
    let onStart: () -> Void
    let onCancel: (() -> Void)?
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    private var themeColors: TerminalThemeColors {
        terminalSettings.ghosttyThemeColors(for: colorScheme)
    }

    private var dimOverlay: Color {
        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(themeColors.foregroundColor.opacity(0.55))

            VStack(spacing: 4) {
                Text(command.name.isEmpty ? "Command" : command.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(themeColors.foregroundColor)

                Text("Not running")
                    .font(.system(size: 12))
                    .foregroundStyle(themeColors.foregroundColor.opacity(0.55))
            }

            if !command.commandLine.isEmpty {
                Text(command.commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(themeColors.foregroundColor.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(themeColors.foregroundColor.opacity(0.06))
                    }
            }

            HStack(spacing: 10) {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!command.isLaunchable)

                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            themeColors.backgroundColor
            dimOverlay
        }
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
            .background(themeColors.backgroundColor)
        }
        .onAppear {
            if chromeState.selectedTodoID == nil {
                chromeState.selectedTodoID = todoStore.firstSelectableTodo?.id
            }
        }
        .onChange(of: todoStore.todos) { _, todos in
            guard let selectedID = chromeState.selectedTodoID,
                  !todos.contains(where: { $0.id == selectedID })
            else { return }
            chromeState.selectedTodoID = todoStore.firstSelectableTodo?.id
        }
    }

    private var splitBody: some View {
        HSplitView {
            TodoListPane(
                todoStore: todoStore,
                chromeState: chromeState,
                themeForeground: themeColors.foregroundColor
            )
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)

            Group {
                if let todo = selectedTodo {
                    TodoInspectorPane(
                        todo: todo,
                        todoStore: todoStore,
                        themeForeground: themeColors.foregroundColor,
                        themeColors: themeColors,
                        isCompact: false,
                        onBack: nil
                    )
                    .id(todo.id)
                } else {
                    ContentUnavailableView("No Todo Selected", systemImage: "checklist")
                        .foregroundStyle(themeColors.foregroundColor)
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
                themeForeground: themeColors.foregroundColor,
                themeColors: themeColors,
                isCompact: true,
                onBack: { chromeState.selectTodo(id: nil) }
            )
            .id(todo.id)
        } else {
            TodoListPane(
                todoStore: todoStore,
                chromeState: chromeState,
                themeForeground: themeColors.foregroundColor
            )
        }
    }

    private var selectedTodo: ProjectTodo? {
        guard let selectedID = chromeState.selectedTodoID else { return nil }
        return todoStore.todos.first { $0.id == selectedID }
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
            chromeState.selectedTodoID = todoStore.firstSelectableTodo?.id
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
        // A chip without a remove button is a filter toggle: dimmed while
        // its filter is off.
        .opacity(showsRemoveButton || isSelected ? 1 : 0.55)
        .contentShape(Capsule(style: .continuous))
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
                .disabled(ProjectTodoStore.normalizedTagName(draftTagInput) == nil)
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
            guard let normalized = ProjectTodoStore.normalizedTagName(name) else { return nil }
            let id = ProjectTodoStore.tagID(forNormalizedName: normalized)
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
        guard let normalized = ProjectTodoStore.normalizedTagName(name) else { return }
        let id = ProjectTodoStore.tagID(forNormalizedName: normalized)
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
            guard let normalized = ProjectTodoStore.normalizedTagName(name) else { return true }
            return ProjectTodoStore.tagID(forNormalizedName: normalized) == tag.id
        }
        saveNow()
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
            trafficLights.update(docked: 320, floating: 0, sidebarWidth: 320)
        }
    }

    private func chooseProjectRoot() {
        guard let url = NSOpenPanel.chooseFolder(prompt: "Create", canCreateDirectories: true),
              let project = settings.addProject(path: url.path)
        else {
            return
        }

        onProjectCreated(project)
    }
}

extension NSOpenPanel {
    /// Asks for one folder in a modal panel; nil when the user cancels.
    /// `canCreateDirectories` shows the panel's New Folder button.
    @MainActor
    static func chooseFolder(
        prompt: String,
        directoryURL: URL? = nil,
        canCreateDirectories: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = canCreateDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let directoryURL {
            panel.directoryURL = directoryURL
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

private struct AppShellBackground: View {
    let projectRoot: String?

    var body: some View {
        SidebarBackground(projectRoot: projectRoot, presentation: .docked)
    }
}

struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let accessibilityLabel: String
    /// The field's key commands (`moveUp:`, `insertNewline:`,
    /// `cancelOperation:`…): true when handled.
    let onCommand: (Selector) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand)
    }

    func makeNSView(context: Context) -> CommandPaletteSearchTextField {
        let textField = CommandPaletteSearchTextField()
        textField.delegate = context.coordinator
        textField.onMoveToWindow = { [weak coordinator = context.coordinator] textField in
            coordinator?.requestFocus(for: textField)
        }
        configure(textField)
        return textField
    }

    func updateNSView(_ nsView: CommandPaletteSearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
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
        textField.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: (Selector) -> Bool
        var lastFocusRequest: Int?

        init(text: Binding<String>, onCommand: @escaping (Selector) -> Bool) {
            self.text = text
            self.onCommand = onCommand
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField,
                  text.wrappedValue != textField.stringValue
            else {
                return
            }

            text.wrappedValue = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            onCommand(commandSelector)
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

final class CommandPaletteSearchTextField: NSTextField {
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

struct CommandPaletteSurface: ViewModifier {
    let usesGlass: Bool
    let cornerRadius: CGFloat
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if usesGlass {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .shadow(
                    color: colorScheme == .dark ? .clear : .black.opacity(0.18),
                    radius: 24,
                    y: 14
                )
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(
                    color: colorScheme == .dark ? .clear : .black.opacity(0.22),
                    radius: 28,
                    y: 18
                )
        }
    }
}

enum SidebarPresentation: Equatable {
    case docked
    case floating
}

private enum SidebarLayout {
    static let trafficLightLeadingInset = TrafficLightLayout.leadingInset
    static let floatingOuterInset: CGFloat = 3
    static let trailingInset: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 12
    static let agentTreeRowSpacing: CGFloat = 4
}

private enum TrafficLightLayout {
    static let leadingInset: CGFloat = 18
    static let topInset: CGFloat = 18
    static let buttonSpacing: CGFloat = 20
    static let fallbackButtonDiameter: CGFloat = 14

    static var clusterWidth: CGFloat {
        buttonSpacing * 2 + fallbackButtonDiameter
    }
}

private enum TitlebarProjectPickerLayout {
    private static let trafficLightClearance: CGFloat = 13

    static var leadingInset: CGFloat {
        TrafficLightLayout.leadingInset
            + TrafficLightLayout.clusterWidth
            + trafficLightClearance
    }
}

private enum AgentTreeLayout {
    static let guideX: CGFloat = 0
    static let guideElbowWidth: CGFloat = 5.5
    static let guideElbowStartInset: CGFloat = 1
    static let guideConnectorLength: CGFloat = 10
    static let guideConnectorDashLength: CGFloat = 1.5
    static let guideConnectorDashGap: CGFloat = 3
    static let guideConnectorOffsetX: CGFloat = 0.5
    static let guideConnectorOffsetY: CGFloat = -11
    static let disclosureOffset: CGFloat = -6
    static let guideTopOverlap: CGFloat = 0
    static let guideBottomOverlap: CGFloat = 1
    static let childRowHeight: CGFloat = 32
    static let childDetailRowHeight: CGFloat = 38
    static let nestedGuideReservationWidth = guideX + guideElbowStartInset + guideElbowWidth + 2
}

@MainActor
private func copyCherryLink(_ link: String?) {
    guard let link, !link.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link, forType: .string)
}

@ViewBuilder
private func nixShellContextMenuItems(for environment: NixShellEnvironment?) -> some View {
    if let environment {
        Divider()

        Button("Inspect Nix Shell...") {
            presentNixShellInspector(environment)
        }

        Button("Copy Nix Package Refs") {
            copyNixPackageReferences(environment)
        }
        .disabled(environment.packageReferences.isEmpty)

        Button("Copy Nix Command") {
            copyNixCommand(environment)
        }
    }
}

@MainActor
private func presentNixShellInspector(_ environment: NixShellEnvironment) {
    let alert = NSAlert()
    alert.messageText = environment.displayName
    alert.informativeText = environment.packageSummary.map {
        "Packages from the launch command: \($0)"
    } ?? "No package refs were found in the launch command."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Done")

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.string = nixShellInspectorText(for: environment)

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
    scrollView.hasVerticalScroller = true
    scrollView.documentView = textView
    alert.accessoryView = scrollView

    alert.runModal()
}

private func nixShellInspectorText(for environment: NixShellEnvironment) -> String {
    var sections = [
        "Mode: \(environment.displayName)"
    ]

    if environment.packageReferences.isEmpty {
        sections.append("Packages: none parsed from command")
    } else {
        sections.append("Packages:\n" + environment.packageReferences
            .map { "- \($0.rawValue)" }
            .joined(separator: "\n"))
    }

    sections.append("Command:\n\(environment.command)")
    return sections.joined(separator: "\n\n")
}

private func copyNixPackageReferences(_ environment: NixShellEnvironment) {
    guard !environment.packageList.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(environment.packageList, forType: .string)
}

private func copyNixCommand(_ environment: NixShellEnvironment) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(environment.command, forType: .string)
}

private func cherryLink(for todo: ProjectTodo) -> String {
    CherryDeepLink.todoURL(projectRoot: todo.projectRoot, todoID: todo.id)
}

private func cherryLink(for session: TerminalSession, projectRoot: String?) -> String? {
    guard let projectRoot else { return nil }
    return CherryDeepLink.terminalURL(projectRoot: projectRoot, terminalID: session.id)
}

/// The context menu of a terminal or agent tab in the sidebar, or of one pane
/// of a split group (`isPane`).
@MainActor
@ViewBuilder
private func sessionContextMenuItems(
    for session: TerminalSession,
    workspace: TerminalWorkspace,
    chromeState: ProjectWindowChromeState,
    linkRoot: String?,
    isPane: Bool = false
) -> some View {
    Button("Copy Link") {
        copyCherryLink(cherryLink(for: session, projectRoot: linkRoot))
    }
    .disabled(linkRoot == nil)

    Divider()

    Button("Rename...") {
        promptRenameSession(session)
    }

    Divider()

    Button(session.restartActionTitle) {
        session.restart()
    }
    .disabled(!session.canRestart)

    Button("Clear Scrollback") {
        session.clearScrollback()
    }

    nixShellContextMenuItems(for: session.nixShellEnvironment)

    Divider()

    Button(isPane ? "Detach Pane" : "Detach") {
        SessionCloseCoordinator.detach(session, in: workspace, chromeState: chromeState)
    }
    .disabled(workspace.sessions.count <= 1 || !SessionCloseCoordinator.canDetach(session))

    Button(
        isPane ? "Close Pane" : session.closeActionTitle,
        role: (isPane || session.hostedAttachment == nil) ? .destructive : nil
    ) {
        SessionCloseCoordinator.close(session, in: workspace, chromeState: chromeState)
    }
    .disabled(workspace.sessions.count <= 1)
}

@MainActor
@ViewBuilder
private func splitGroupMenuItems(
    _ group: TerminalSplitGroup,
    workspace: TerminalWorkspace,
    chromeState: ProjectWindowChromeState,
    dividerBeforeClose: Bool
) -> some View {
    Button("Balance Panes") {
        workspace.balanceSplitGroup(id: group.id)
    }

    Button("Separate Panes") {
        workspace.separateSplitGroup(id: group.id)
    }

    if dividerBeforeClose {
        Divider()
    }

    Button("Close Split Group...", role: .destructive) {
        SessionCloseCoordinator.confirmAndCloseSplitGroup(group, in: workspace, chromeState: chromeState)
    }
    .disabled(!workspace.canCloseSplitGroup(id: group.id))
}

private struct SidebarTabsView: View {
    let repository: RepositoryWorkspace
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EquatableSidebarTabsPage(
                workspace: workspace,
                chromeState: chromeState,
                todoStore: todoStore,
                projectRoot: projectRoot,
                presentation: presentation,
                openProject: openProject
            )
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Restart to Update, while an update is staged (nothing otherwise).
            SidebarUpdatePill(
                status: AppUpdater.shared.status,
                insets: EdgeInsets(
                    top: 0,
                    leading: SidebarLayout.trafficLightLeadingInset - floatingOuterInset,
                    bottom: 6,
                    trailing: SidebarLayout.trailingInset
                )
            )
        }
        .background {
            if presentation == .floating {
                SidebarBackground(projectRoot: repository.repositoryRoot, presentation: presentation)
            }
        }
        .overlay(alignment: .top) {
            SidebarTopChromeShield(projectRoot: repository.repositoryRoot, presentation: presentation)
        }
    }

    private var floatingOuterInset: CGFloat {
        presentation == .floating ? SidebarLayout.floatingOuterInset : 0
    }
}

/// The window re-renders its sidebar for changes that leave the page as it
/// was (its chrome, the sidebar's width). Giving the heavyweight page an
/// explicit identity boundary lets SwiftUI skip walking the entire sidebar
/// contents again; the observed models inside the page still invalidate it
/// normally when their actual data changes.
@MainActor
private struct EquatableSidebarTabsPage: View, @preconcurrency Equatable {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace === rhs.workspace
            && lhs.chromeState === rhs.chromeState
            && lhs.todoStore === rhs.todoStore
            && lhs.projectRoot == rhs.projectRoot
            && lhs.presentation == rhs.presentation
    }

    var body: some View {
        SidebarTabsPage(
            workspace: workspace,
            chromeState: chromeState,
            todoStore: todoStore,
            projectRoot: projectRoot,
            presentation: presentation,
            openProject: openProject
        )
    }
}

private struct SidebarTabsPage: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var agentSettings = AgentSettings.shared
    /// A device project's cherry.toml, once read there.
    @ObservedObject private var remoteProjectFiles = RemoteProjectFiles.shared
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let presentation: SidebarPresentation
    let openProject: (CherryProject) -> Void

    var body: some View {
        let features = agentSettings.projectFeatures(for: projectRoot)
        let agentTree = workspace.agentSessionTreeSnapshot()
        let visibleAgentItems = agentTree.visibleItems(
            collapsedIDs: chromeState.collapsedAgentGroupIDs
        )
        // A device's project reads its cherry.toml there (phase 3,
        // `RemoteProjectFiles`); it changes as that file is read again.
        let isRemote = projectRoot.map(ProjectLocation.isRemoteKey) ?? false
        let commands = agentSettings.launchableProjectCommands(for: projectRoot)
        let palette = SidebarPalette(
            terminalSettings: terminalSettings, agentSettings: agentSettings,
            projectRoot: projectRoot, colorScheme: colorScheme, presentation: presentation
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                SidebarAgentSessionSection(
                    settings: agentSettings,
                    workspace: workspace,
                    chromeState: chromeState,
                    projectRoot: projectRoot,
                    palette: palette,
                    agentTree: agentTree,
                    visibleAgentItems: visibleAgentItems,
                    pathDisplayMode: terminalSettings.sidebarTerminalPathDisplayMode,
                    showShortcutHints: chromeState.isCommandKeyPressed,
                    openSettings: { openSettings() }
                )
                .id("agents-\(projectRoot ?? "")")

                SidebarSessionSection(
                    title: "Terminals",
                    displayItems: workspace.terminalDisplayItems,
                    workspace: workspace,
                    chromeState: chromeState,
                    palette: palette,
                    pathDisplayMode: terminalSettings.sidebarTerminalPathDisplayMode,
                    shortcutStartIndex: visibleAgentItems.count,
                    showShortcutHints: chromeState.isCommandKeyPressed
                )
                .id("terminals-\(projectRoot ?? "")")

                if isRemote, let hosting = workspace.backendPolicy.localSessions, !hosting.profile.isThisMac {
                    RemoteNotOpenSection(workspace: workspace, hosting: hosting)
                        .id("not-open-\(projectRoot ?? "")")
                }

                SidebarCommandSection(
                    settings: agentSettings,
                    workspace: workspace,
                    chromeState: chromeState,
                    projectRoot: projectRoot,
                    palette: palette,
                    commands: commands,
                    shortcutStartIndex: visibleAgentItems.count + workspace.terminalDisplayItems.count,
                    showShortcutHints: chromeState.isCommandKeyPressed
                )
                .id("commands-\(projectRoot ?? "")")

                if features.todosEnabled {
                    SidebarTodosSection(
                        todoStore: todoStore,
                        chromeState: chromeState,
                        palette: palette,
                        shortcutNumber: visibleAgentItems.count
                            + workspace.terminalDisplayItems.count
                            + commands.count
                            + 1,
                        showShortcutHint: chromeState.isCommandKeyPressed
                    )
                }
            }
            // Keep the sidebar's text column aligned with the native
            // traffic-light leading edge in both docked and floating
            // presentations. Floating mode has an outer wrapper inset,
            // so the inner leading padding subtracts that amount.
            .padding(.leading, SidebarLayout.trafficLightLeadingInset - floatingOuterInset)
            .padding(.trailing, SidebarLayout.trailingInset)
            .padding(.top, TopChromeShieldMetrics.projectSidebar.contentTopInset + dockedCompensation)
            .padding(.bottom, 10 + dockedCompensation)
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

struct TitlebarProjectPicker: View {
    private static let fontSize: CGFloat = 14
    private static let fontWeight: NSFont.Weight = .semibold
    private static let titleFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
    private static let titleWidthCache = NSCache<NSString, NSNumber>()
    private static let accentDiameter: CGFloat = 7
    private static let titleSpacing: CGFloat = 6
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var settings: AgentSettings
    @ObservedObject var repository: RepositoryWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let presentation: SidebarPresentation
    let maximumWidth: CGFloat

    @State private var isHovering = false

    var body: some View {
        let palette = SidebarPalette(
            terminalSettings: terminalSettings, agentSettings: settings,
            projectRoot: repository.repositoryRoot, colorScheme: colorScheme, presentation: presentation
        )

        // A device window's Mac (nil for This Mac's: no store is asked),
        // and whether it answers.
        RemoteDeviceBadgeReader(projectKey: repository.repositoryRoot) { device in
            RemoteDeviceStatusReader(hosting: device == nil ? nil : repository.deviceHosting) { status in
                pickerButton(palette: palette, device: device, status: status)
            }
        }
    }

    private func pickerButton(
        palette: SidebarPalette,
        device: RemoteDeviceBadge?,
        status: RemoteDeviceHeaderStatus
    ) -> some View {
        // A plain Button (SwiftUI Menu's NSPopUpButton would own the
        // label's mouse tracking, so `.onHover` would never fire): it opens
        // the Omni bar on Projects, as ⌘O does.
        Button(action: { chromeState.showOmniBarProjects() }) {
            HStack(spacing: Self.titleSpacing) {
                if palette.showsProjectAccent {
                    Circle()
                        .fill(palette.projectAccent)
                        .frame(width: Self.accentDiameter, height: Self.accentDiameter)
                }

                titleContent(palette: palette, device: device, status: status)
            }
            .font(.system(size: Self.fontSize, weight: .semibold))
            .foregroundStyle(palette.rowText)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(
                width: preferredWidth(showsProjectAccent: palette.showsProjectAccent, device: device, status: status),
                alignment: .leading
            )
            .clipped()
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.hoverFill.opacity(isHovering ? 1 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(TitlebarProjectMenuAnchor())
        .help(help(device: device, status: status))
        .accessibilityLabel(accessibilityLabel(device: device, status: status))
        .accessibilityHint("Opens the Omni bar on Projects (\(CherryShortcut.openProject.display))")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var selectedProject: CherryProject? {
        settings.selectedProject(for: projectRoot)
    }

    private var projectTitle: String {
        if repository.isRemote {
            // Its Mac follows it ("@ <Mac>").
            return repository.repositoryName
        }
        let name = selectedProject?.name ?? repository.repositoryName
        return name.isEmpty ? "No Project" : name
    }

    private func help(device: RemoteDeviceBadge?, status: RemoteDeviceHeaderStatus) -> String {
        guard let device else { return projectTitle }
        return status.detail(machine: device.name) ?? "\(projectTitle) on \(device.name)"
    }

    private func accessibilityLabel(device: RemoteDeviceBadge?, status: RemoteDeviceHeaderStatus) -> String {
        guard let device else { return "Project: \(projectTitle)" }
        let label = "Project: \(projectTitle), on \(device.name)"
        return status.detail(machine: device.name).map { "\(label). \($0)" } ?? label
    }

    @ViewBuilder
    private func titleContent(
        palette: SidebarPalette,
        device: RemoteDeviceBadge?,
        status: RemoteDeviceHeaderStatus
    ) -> some View {
        if let device {
            // "cherry @ patmini": which Mac this window runs on.
            HStack(spacing: RemoteDeviceHeaderAddress.spacing) {
                Text(projectTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                RemoteDeviceHeaderAddress(
                    badge: device,
                    status: status,
                    fontSize: Self.fontSize,
                    textColor: palette.rowText
                )
            }
        } else {
            Text(projectTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func preferredWidth(
        showsProjectAccent: Bool,
        device: RemoteDeviceBadge?,
        status: RemoteDeviceHeaderStatus
    ) -> CGFloat {
        let addressWidth = device.map {
            RemoteDeviceHeaderAddress.spacing
                + RemoteDeviceHeaderAddress.width(of: $0, status: status, fontSize: Self.fontSize)
        } ?? 0
        let titleWidth = Self.measuredTitleWidth(projectTitle) + addressWidth
        let accentWidth = showsProjectAccent ? Self.accentDiameter + Self.titleSpacing : 0
        let paddedWidth = titleWidth + accentWidth + Self.horizontalPadding * 2
        return max(0, min(maximumWidth, paddedWidth))
    }

    private static func measuredTitleWidth(_ title: String) -> CGFloat {
        let cacheKey = title as NSString
        if let cached = titleWidthCache.object(forKey: cacheKey) {
            return CGFloat(truncating: cached)
        }

        let width = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        titleWidthCache.setObject(NSNumber(value: Double(width)), forKey: cacheKey)
        return width
    }
}

/// Marks the title-bar project button for tests that find it on screen.
private struct TitlebarProjectMenuAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .titlebarProjectPickerAnchor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = .titlebarProjectPickerAnchor
    }
}

extension NSUserInterfaceItemIdentifier {
    static let titlebarProjectPickerAnchor = NSUserInterfaceItemIdentifier(
        "Cherry.TitlebarProjectPickerAnchor"
    )
}

private struct SidebarAgentSessionSection: View {
    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let palette: SidebarPalette
    let agentTree: AgentSessionTreeSnapshot
    let visibleAgentItems: [AgentSessionTreeItem]
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let showShortcutHints: Bool
    let openSettings: () -> Void

    var body: some View {
        let project = settings.resolvedProject(for: projectRoot)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SidebarSectionHeader(
                    title: "Agents",
                    count: agentTree.sessions.count + (isIconDebugActive ? SidebarIconDebugFixtures.agentCount : 0),
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

            if agentTree.sessions.isEmpty && !isIconDebugActive {
                SidebarEmptyRow(
                    title: "No agents",
                    palette: palette
                )
            }

            if !agentTree.sessions.isEmpty {
                let shortcutNumbers = Dictionary(uniqueKeysWithValues: visibleAgentItems.enumerated().map { index, item in
                    (item.session.id, index + 1)
                })
                ForEach(agentTree.roots) { session in
                    let children = agentTree.children(of: session)
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
                            isActive: isActiveGroup,
                            hasDetail: { $0.sidebarDetail.nilIfEmpty != nil }
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
            }
        }
    }

    private func launch(_ agent: AgentToolDefinition) {
        let project = settings.resolvedProject(for: projectRoot)
        guard agent.isLaunchable, let root = project.validProjectRoot else { return }
        chromeState.selectTerminal()
        workspace.addAgentSession(agent: agent, projectRoot: root)
    }

    private var isIconDebugActive: Bool {
        chromeState.isSidebarPlaygroundPresented
    }

    private func select(_ session: TerminalSession) {
        chromeState.selectTerminal()
        workspace.select(session)
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
            palette: palette,
            pathDisplayMode: pathDisplayMode,
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
            sessionContextMenuItems(
                for: session,
                workspace: workspace,
                chromeState: chromeState,
                linkRoot: projectRoot
            )
        }
    }
}

private struct AgentLaunchMenu: View {
    let project: ResolvedAgentProject
    let palette: SidebarPalette
    let openSettings: () -> Void
    let launch: (AgentToolDefinition) -> Void

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

            Button("Edit Agents…") {
                SettingsOpening.editAgents(navigator: .shared, openSettings: openSettings)
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

private struct SidebarAgentChildrenGroup<Child: Identifiable, RowContent: View>: View {
    let children: [Child]
    let palette: SidebarPalette
    let isActive: Bool
    /// Whether a child's row shows a detail line, which makes it taller.
    let hasDetail: (Child) -> Bool
    let rowContent: (Child) -> RowContent

    init(
        children: [Child],
        palette: SidebarPalette,
        isActive: Bool,
        hasDetail: @escaping (Child) -> Bool,
        @ViewBuilder rowContent: @escaping (Child) -> RowContent
    ) {
        self.children = children
        self.palette = palette
        self.isActive = isActive
        self.hasDetail = hasDetail
        self.rowContent = rowContent
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SidebarAgentChildrenGuide(
                children: children,
                palette: palette,
                isActive: isActive,
                hasDetail: hasDetail
            )

            VStack(alignment: .leading, spacing: SidebarLayout.agentTreeRowSpacing) {
                ForEach(children) { child in
                    rowContent(child)
                }
            }
        }
    }
}

private struct SidebarAgentChildrenGuide<Child: Identifiable>: View {
    let children: [Child]
    let palette: SidebarPalette
    let isActive: Bool
    let hasDetail: (Child) -> Bool

    var body: some View {
        let x = AgentTreeLayout.guideX
        let elbowWidth = AgentTreeLayout.guideElbowWidth
        let elbowX = x + AgentTreeLayout.guideElbowStartInset
        let connectorLength = AgentTreeLayout.guideConnectorLength
        let connectorDashLength = AgentTreeLayout.guideConnectorDashLength
        let connectorDashGap = AgentTreeLayout.guideConnectorDashGap
        let connectorX = x + AgentTreeLayout.guideConnectorOffsetX
        let connectorY = AgentTreeLayout.guideConnectorOffsetY
        let topOverlap = AgentTreeLayout.guideTopOverlap
        let bottomOverlap = AgentTreeLayout.guideBottomOverlap
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

        let precedingRowsHeight = children.prefix(index).reduce(CGFloat.zero) { partialResult, child in
            partialResult + rowHeight(for: child)
        }
        return precedingRowsHeight
            + SidebarLayout.agentTreeRowSpacing * CGFloat(index)
            + rowHeight(for: children[index]) / 2
    }

    private func rowHeight(for child: Child?) -> CGFloat {
        guard let child else { return AgentTreeLayout.childDetailRowHeight }
        return hasDetail(child)
            ? AgentTreeLayout.childDetailRowHeight
            : AgentTreeLayout.childRowHeight
    }
}

private struct SidebarCommandSection: View {
    @ObservedObject var settings: AgentSettings
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let palette: SidebarPalette
    let commands: [ProjectCommandDefinition]
    let shortcutStartIndex: Int
    let showShortcutHints: Bool

    @State private var editingCommand: ProjectCommandDefinition?
    @State private var editingOriginalName: String?
    @State private var commandError: String?

    var body: some View {
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
                .help("Add Command")
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
                        palette: palette,
                        shortcutNumber: shortcutStartIndex + index + 1,
                        showShortcutHint: showShortcutHints,
                        start: { start(command, existingSession: session) },
                        stop: { stop(session) },
                        select: {
                            if let session {
                                chromeState.selectTerminal()
                                workspace.select(session)
                            } else {
                                chromeState.focusIdleCommand(name: command.name)
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
                            stop(session)
                        }
                        .disabled(session?.isRunningCommand != true)

                        if let session {
                            Button("Rename...") {
                                promptRenameSession(session)
                            }

                            Button("Clear Scrollback") {
                                session.clearScrollback()
                            }

                            nixShellContextMenuItems(for: session.nixShellEnvironment)
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
                storage: settings.commandStorage(named: editingOriginalName ?? command.name, for: projectRoot),
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
                        dismissEditor()
                    } catch {
                        commandError = error.localizedDescription
                    }
                },
                onDelete: {
                    if projectRoot != nil {
                        remove(command, existingSession: workspace.commandSession(named: command.name))
                    }
                    dismissEditor()
                },
                onCancel: { dismissEditor() }
            )
        }
    }

    private func dismissEditor() {
        commandError = nil
        editingOriginalName = nil
        editingCommand = nil
    }

    private func addCommand() {
        editingCommand = ProjectCommandDefinition(name: "", command: "")
        editingOriginalName = nil
    }

    private func start(
        _ command: ProjectCommandDefinition,
        existingSession: TerminalSession?,
        waitingForRestore: Bool = true
    ) {
        guard command.isLaunchable, let root = settings.resolvedProject(for: projectRoot).validProjectRoot else { return }
        // A command runs in one tab across the project's windows: a row
        // with no tab here starts (and shows) another window's.
        let existingSession = existingSession ?? workspace.projectCommandSession(named: command.name)
        if waitingForRestore, existingSession == nil, workspace.isRestoringCommand(named: command.name) {
            // Its saved tab may still come back (in any window of the
            // project): start (or show) it once the restore answered, never
            // as a second copy.
            let workspace = workspace
            Task { @MainActor in
                await workspace.waitUntilRestored(commandNamed: command.name)
                start(command, existingSession: workspace.commandSession(named: command.name), waitingForRestore: false)
            }
            return
        }
        if let existingSession {
            if !existingSession.isRunningCommand {
                existingSession.restart()
            }
            show(existingSession)
        } else {
            chromeState.selectTerminal()
            workspace.addCommandSession(command: command, projectRoot: root)
        }
    }

    /// Shows a command's tab: here when it is this window's, else in the
    /// window of the project that has it (`revealSession(id:)`).
    private func show(_ session: TerminalSession) {
        guard workspace.session(withID: session.id) === session else {
            ProjectWindowRegistry.shared.revealSession(id: session.id)
            return
        }
        chromeState.selectTerminal()
        workspace.select(session)
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

    // Deliberately selection-neutral: the exited terminal stays visible with
    // the exit-status bar, and stopping a command you're not looking at
    // shouldn't steal the detail pane.
    private func stop(_ existingSession: TerminalSession?) {
        existingSession?.stopManagedCommand()
    }

    private func remove(_ command: ProjectCommandDefinition, existingSession: TerminalSession?) {
        if let existingSession, workspace.sessions.count > 1 {
            workspace.close(existingSession)
        } else {
            existingSession?.stopProgram()
        }
        if let projectRoot {
            settings.removeCommand(named: command.name, for: projectRoot)
        }
    }

    private var isIconDebugActive: Bool {
        chromeState.isSidebarPlaygroundPresented
    }
}

private struct SidebarTodosSection: View {
    @ObservedObject var todoStore: ProjectTodoStore
    @ObservedObject var chromeState: ProjectWindowChromeState
    let palette: SidebarPalette
    let shortcutNumber: Int
    let showShortcutHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(title: "Todos", count: openTodoCount, palette: palette)

            Button {
                chromeState.selectTodo(id: chromeState.selectedTodoID ?? todoStore.firstSelectableTodo?.id)
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
                    SidebarRowBackground(isSelected: isSelected, showsShadow: false, palette: palette)
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

    private var isSelected: Bool {
        chromeState.isTodoPanePresented
    }
}

@MainActor
func promptRenameSession(_ session: TerminalSession) {
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
    let command: ProjectCommandDefinition
    let session: TerminalSession?
    let projectRoot: String?
    let isSelected: Bool
    let palette: SidebarPalette
    let shortcutNumber: Int
    let showShortcutHint: Bool
    let start: () -> Void
    let stop: () -> Void
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let label = SidebarProjectCommandFormatter.label(for: command, projectRoot: projectRoot)

        Button(action: select) {
            HStack(spacing: 8) {
                if label.leadingIconResourceName != nil || label.leadingIconFallback != nil {
                    SidebarProgramIcon(label: label, isSelected: isSelected, palette: palette)
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
                            }

                            Text(detail)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                    }
                }

                Spacer(minLength: 8)

                if showShortcutHint, shortcutNumber <= 9 {
                    SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected, palette: palette)
                } else if let session {
                    SidebarCommandRunButton(
                        session: session,
                        isSelected: isSelected,
                        palette: palette,
                        start: start,
                        stop: stop
                    )
                } else {
                    Button(action: start) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: label.detail == nil ? 42 : 46)
            .padding(.leading, SidebarLayout.rowHorizontalInset)
            .padding(.trailing, SidebarLayout.rowHorizontalInset)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                SidebarRowBackground(isSelected: isSelected, isHovered: isHovered, palette: palette)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// A sidebar row's background: the selected shape (with its shadow unless
/// `showsShadow` is false), else the hover fill.
private struct SidebarRowBackground: View {
    let isSelected: Bool
    var isHovered = false
    var showsShadow = true
    let palette: SidebarPalette

    var body: some View {
        if isSelected {
            if showsShadow {
                selectedShape
                    .shadow(color: palette.selectedShadow, radius: 9, y: 4)
            } else {
                selectedShape
            }
        } else if isHovered {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.hoverFill)
        }
    }

    private var selectedShape: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(palette.selectedFill)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.selectedStroke, lineWidth: 1)
            }
    }
}

// Observes the session directly: run state changes (including a process
// quitting on its own) must flip the icon without waiting for an unrelated
// re-render of the sidebar.
private struct SidebarCommandRunButton: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let palette: SidebarPalette
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        Button(action: session.isRunningCommand ? stop : start) {
            Image(systemName: session.isRunningCommand ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.isRunningCommand ? "Stop" : "Start")
    }
}

private extension TerminalSession {
    var isRunningCommand: Bool {
        switch state {
        case .launching, .live:
            true
        case .disconnected:
            // A persistent tab's program keeps running on its host while
            // its adapter reconnects: Start would end it.
            isPersistentLocalSession && isRunning
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
    let title: String
    let displayItems: [TerminalDisplayItem]
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let palette: SidebarPalette
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let shortcutStartIndex: Int
    let showShortcutHints: Bool

    @State private var draggedDisplayItemID: UUID?
    @State private var draggedRowOffsetY: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader(
                title: title,
                count: displayItems.count + (isIconDebugActive ? SidebarIconDebugFixtures.terminalCount : 0),
                palette: palette
            )

            if isIconDebugActive {
                SidebarIconDebugTerminalPreview(palette: palette)
            }

            ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                displayRow(item, index: index, palette: palette)
                    .offset(y: draggedDisplayItemID == item.id ? draggedRowOffsetY : 0)
                    .zIndex(draggedDisplayItemID == item.id ? 1 : 0)
                    .anchorPreference(key: SidebarInteractionAnchorsPreferenceKey.self, value: .bounds) { anchor in
                        .row(item.id, anchor)
                    }
            }
        }
        .overlayPreferenceValue(SidebarInteractionAnchorsPreferenceKey.self) { interactionAnchors in
            GeometryReader { geometry in
                SidebarInteractionOverlay(
                    rows: displayItems.compactMap { item in
                        interactionAnchors.rows[item.id].map { anchor in
                            SidebarRowFrame(
                                id: item.id,
                                rect: geometry[anchor].insetBy(dx: -4, dy: -3),
                                primarySelectionID: primarySelectionID(for: item),
                                paneSelectors: paneSelectors(
                                    for: item,
                                    anchors: interactionAnchors,
                                    geometry: geometry
                                )
                            )
                        }
                    },
                    onSelect: { sessionID in
                        guard let session = workspace.session(withID: sessionID) else { return }
                        chromeState.selectTerminal()
                        workspace.select(session)
                    },
                    onDragChanged: { displayItemID, offsetY in
                        draggedDisplayItemID = displayItemID
                        draggedRowOffsetY = offsetY
                    },
                    onMove: { displayItemID, targetIndex in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            workspace.moveTerminalDisplayItem(id: displayItemID, to: targetIndex)
                        }
                    },
                    onDragEnded: {
                        withAnimation(.snappy(duration: 0.16)) {
                            draggedDisplayItemID = nil
                            draggedRowOffsetY = 0
                        }
                    }
                )
            }
        }
    }

    private var isIconDebugActive: Bool {
        chromeState.isSidebarPlaygroundPresented
    }

    private func primarySelectionID(for item: TerminalDisplayItem) -> UUID {
        switch item {
        case .single(let sessionID):
            return sessionID
        case .split(let groupID):
            return workspace.splitGroup(id: groupID)?.activeSessionID ?? groupID
        }
    }

    private func paneSelectors(
        for item: TerminalDisplayItem,
        anchors: SidebarInteractionAnchors,
        geometry: GeometryProxy
    ) -> [SidebarPaneSelectorFrame] {
        guard case .split(let groupID) = item,
              let group = workspace.splitGroup(id: groupID),
              let selectorAnchors = anchors.paneSelectors[groupID]
        else {
            return []
        }

        return group.paneSessionIDs.compactMap { sessionID in
            selectorAnchors[sessionID].map { anchor in
                SidebarPaneSelectorFrame(
                    id: sessionID,
                    rect: geometry[anchor].insetBy(dx: -3, dy: -4)
                )
            }
        }
    }

    @ViewBuilder
    private func displayRow(
        _ item: TerminalDisplayItem,
        index: Int,
        palette: SidebarPalette
    ) -> some View {
        switch item {
        case .single(let sessionID):
            if let session = workspace.session(withID: sessionID) {
                SidebarTabRow(
                    session: session,
                    isSelected: chromeState.isShowingTerminalContent && workspace.selectedSessionID == session.id,
                    palette: palette,
                    pathDisplayMode: pathDisplayMode,
                    shortcutNumber: shortcutStartIndex + index + 1,
                    showShortcutHint: showShortcutHints,
                    onSelect: {
                        chromeState.selectTerminal()
                        workspace.select(session)
                    }
                )
                .contextMenu {
                    sessionContextMenuItems(
                        for: session,
                        workspace: workspace,
                        chromeState: chromeState,
                        linkRoot: workspace.projectRoot
                    )
                }
            }
        case .split(let groupID):
            if let group = workspace.splitGroup(id: groupID) {
                SidebarSplitTabRow(
                    group: group,
                    workspace: workspace,
                    chromeState: chromeState,
                    pathDisplayMode: pathDisplayMode,
                    shortcutNumber: shortcutStartIndex + index + 1,
                    showShortcutHint: showShortcutHints,
                    palette: palette
                )
            }
        }
    }
}

private struct SidebarSplitTabRow: View {
    let group: TerminalSplitGroup
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let shortcutNumber: Int
    let showShortcutHint: Bool
    let palette: SidebarPalette

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let activeSession {
                SidebarSplitActivePaneSummary(
                    session: activeSession,
                    pathDisplayMode: pathDisplayMode,
                    isSelected: isSelected,
                    palette: palette
                )
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(paneSessions) { session in
                    SidebarSplitPaneIconSelector(
                        groupID: group.id,
                        session: session,
                        workspace: workspace,
                        chromeState: chromeState,
                        pathDisplayMode: pathDisplayMode,
                        isActive: chromeState.isShowingTerminalContent && workspace.selectedSessionID == session.id,
                        isRowSelected: isSelected,
                        palette: palette,
                        onSelect: {
                            chromeState.selectTerminal()
                            workspace.select(session)
                        }
                    )
                }
            }

            if showShortcutHint, shortcutNumber <= 9 {
                SidebarShortcutHint(number: shortcutNumber, isSelected: isSelected, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 50)
        .padding(.leading, SidebarLayout.rowHorizontalInset)
        .padding(.trailing, SidebarLayout.rowHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            SidebarRowBackground(isSelected: isSelected, isHovered: isHovered, palette: palette)
        }
        .padding(.leading, -SidebarLayout.rowHorizontalInset)
        .onTapGesture {
            if let session = workspace.session(withID: group.activeSessionID) {
                chromeState.selectTerminal()
                workspace.select(session)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split terminal group")
        .contextMenu {
            splitGroupMenuItems(group, workspace: workspace, chromeState: chromeState, dividerBeforeClose: true)
        }
    }

    private var paneSessions: [TerminalSession] {
        group.paneSessionIDs.compactMap { workspace.session(withID: $0) }
    }

    private var activeSession: TerminalSession? {
        workspace.session(withID: group.activeSessionID) ?? paneSessions.first
    }

    private var isSelected: Bool {
        guard chromeState.isShowingTerminalContent,
              let selectedSessionID = workspace.selectedSessionID
        else {
            return false
        }
        return group.paneSessionIDs.contains(selectedSessionID)
    }

    private var helpText: String {
        paneSessions.map(\.title).joined(separator: " | ")
    }
}

private struct SidebarSplitActivePaneSummary: View {
    let session: TerminalSession
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let isSelected: Bool
    let palette: SidebarPalette

    @StateObject private var rowState: SidebarTabRowState
    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons =
        SidebarIconMetrics.defaultUsesInlineProgramDetailIcons

    init(
        session: TerminalSession,
        pathDisplayMode: SidebarTerminalPathDisplayMode,
        isSelected: Bool,
        palette: SidebarPalette
    ) {
        self.session = session
        self.pathDisplayMode = pathDisplayMode
        self.isSelected = isSelected
        self.palette = palette
        _rowState = StateObject(wrappedValue: SidebarTabRowState(
            session: session,
            pathDisplayMode: pathDisplayMode
        ))
    }

    var body: some View {
        HStack(spacing: 8) {
            if shouldShowLeadingIcon {
                SidebarProgramIcon(label: rowState.label, isSelected: isSelected, palette: palette)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(rowState.label.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .lineLimit(1)

                    if let nixShellEnvironment = rowState.nixShellEnvironment {
                        NixShellBadge(
                            environment: nixShellEnvironment,
                            isSelected: isSelected,
                            palette: palette
                        )
                        .help(nixShellEnvironment.tooltip)
                    }
                }

                if let detail = rowState.label.detail {
                    HStack(spacing: 4) {
                        if let resourceName = rowState.label.detailIconResourceName {
                            SidebarDetailIcon(resourceName: resourceName)
                        } else if usesInlineProgramDetailIcons,
                                  rowState.label.leadingIconResourceName != nil
                                      || rowState.label.leadingIconFallback != nil {
                            SidebarProgramInlineIcon(label: rowState.label)
                        }

                        Text(detail)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.56))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            rowState.updatePathDisplayMode(pathDisplayMode)
        }
        .onChange(of: pathDisplayMode) { _, mode in
            rowState.updatePathDisplayMode(mode)
        }
    }

    private var shouldShowLeadingIcon: Bool {
        rowState.label.detail == nil
            && (rowState.label.leadingIconResourceName != nil || rowState.label.leadingIconFallback != nil)
    }
}

private struct SidebarSplitPaneIconSelector: View {
    let groupID: UUID
    let session: TerminalSession
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let isActive: Bool
    let isRowSelected: Bool
    let palette: SidebarPalette
    let onSelect: () -> Void

    @StateObject private var rowState: SidebarTabRowState

    init(
        groupID: UUID,
        session: TerminalSession,
        workspace: TerminalWorkspace,
        chromeState: ProjectWindowChromeState,
        pathDisplayMode: SidebarTerminalPathDisplayMode,
        isActive: Bool,
        isRowSelected: Bool,
        palette: SidebarPalette,
        onSelect: @escaping () -> Void
    ) {
        self.groupID = groupID
        self.session = session
        self.workspace = workspace
        self.chromeState = chromeState
        self.pathDisplayMode = pathDisplayMode
        self.isActive = isActive
        self.isRowSelected = isRowSelected
        self.palette = palette
        self.onSelect = onSelect
        _rowState = StateObject(wrappedValue: SidebarTabRowState(
            session: session,
            pathDisplayMode: pathDisplayMode
        ))
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                paneIcon
                    .frame(width: 24, height: 24)

                Circle()
                    .fill(Color(nsColor: rowState.tint))
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: -1)
                    .opacity(rowState.hasUnreadNotification ? 1 : 0)
            }
            .frame(width: 26, height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                selectorBackground
            }
        }
        .buttonStyle(.plain)
        .help(rowState.helpText)
        .accessibilityLabel("\(rowState.label.title), split pane")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .onAppear {
            rowState.updatePathDisplayMode(pathDisplayMode)
        }
        .onChange(of: pathDisplayMode) { _, mode in
            rowState.updatePathDisplayMode(mode)
        }
        .anchorPreference(key: SidebarInteractionAnchorsPreferenceKey.self, value: .bounds) { anchor in
            .paneSelector(groupID: groupID, sessionID: session.id, anchor)
        }
        .contextMenu {
            sessionContextMenuItems(
                for: session,
                workspace: workspace,
                chromeState: chromeState,
                linkRoot: workspace.projectRoot,
                isPane: true
            )

            if let group = workspace.splitGroup(containing: session.id) {
                Divider()

                splitGroupMenuItems(group, workspace: workspace, chromeState: chromeState, dividerBeforeClose: false)
            }
        }
    }

    @ViewBuilder
    private var paneIcon: some View {
        if rowState.label.leadingIconResourceName != nil || rowState.label.leadingIconFallback != nil {
            SidebarProgramIcon(label: rowState.label, isSelected: isRowSelected, palette: palette)
                .opacity(isActive ? 1 : 0.50)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle((isRowSelected ? palette.selectedText : palette.rowText).opacity(isActive ? 1 : 0.50))
        }
    }

    @ViewBuilder
    private var selectorBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((isRowSelected ? palette.selectedText : palette.rowText).opacity(0.14))
        }
    }
}

private struct SidebarPaneSelectorFrame: Equatable {
    let id: UUID
    let rect: CGRect
}

private struct SidebarRowBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SidebarInteractionAnchors {
    var rows: [UUID: Anchor<CGRect>] = [:]
    var paneSelectors: [UUID: [UUID: Anchor<CGRect>]] = [:]

    static func row(_ id: UUID, _ anchor: Anchor<CGRect>) -> Self {
        var anchors = Self()
        anchors.rows[id] = anchor
        return anchors
    }

    static func paneSelector(groupID: UUID, sessionID: UUID, _ anchor: Anchor<CGRect>) -> Self {
        var anchors = Self()
        anchors.paneSelectors[groupID] = [sessionID: anchor]
        return anchors
    }

    mutating func merge(_ other: Self) {
        rows.merge(other.rows, uniquingKeysWith: { _, next in next })
        for (groupID, selectors) in other.paneSelectors {
            paneSelectors[groupID, default: [:]].merge(selectors, uniquingKeysWith: { _, next in next })
        }
    }
}

private struct SidebarInteractionAnchorsPreferenceKey: PreferenceKey {
    static let defaultValue = SidebarInteractionAnchors()

    static func reduce(value: inout SidebarInteractionAnchors, nextValue: () -> SidebarInteractionAnchors) {
        value.merge(nextValue())
    }
}

private struct SidebarRowFrame: Equatable {
    let id: UUID
    let rect: CGRect
    var primarySelectionID: UUID? = nil
    var paneSelectors: [SidebarPaneSelectorFrame] = []

    func selectionID(at point: CGPoint) -> UUID {
        if let paneSelector = paneSelectors.first(where: { $0.rect.contains(point) }) {
            return paneSelector.id
        }
        return primarySelectionID ?? id
    }
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
        onSelect?(row.selectionID(at: point))
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

    /// `rows` is kept sorted by `minY`.
    private func estimatedRowStep() -> CGFloat {
        guard rows.count > 1 else { return 46 }

        let deltas = zip(rows, rows.dropFirst()).map { next, previous in
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
        content
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
    private var applyScheduled = false

    fileprivate func attach(_ view: TrafficLightOverlayView) {
        self.view = view
        applyCurrentWhenSafe()
    }

    fileprivate func detach(_ view: TrafficLightOverlayView) {
        guard self.view === view else { return }
        self.view = nil
    }

    func update(docked: CGFloat, floating: CGFloat, sidebarWidth: CGFloat) {
        lastDocked = docked
        lastFloating = floating
        lastSidebarWidth = sidebarWidth
        applyCurrentWhenSafe()
    }

    fileprivate func refresh() {
        applyCurrentWhenSafe()
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

    private func applyCurrentWhenSafe() {
        if shouldDeferAppKitMutation {
            scheduleApplyCurrent()
        } else {
            applyCurrent()
        }
    }

    private var shouldDeferAppKitMutation: Bool {
        guard let window = view?.window else { return false }
        // Sheet dimming captures can force SwiftUI layout while
        // `ChromeWidthAnimator` is sampling. Moving AppKit titlebar buttons
        // synchronously from that stack re-enters AttributeGraph.
        return window.attachedSheet != nil
            || !window.sheets.isEmpty
            || window.sheetParent != nil
    }

    private func scheduleApplyCurrent() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyScheduled = false
                self.applyCurrent()
            }
        }
    }
}

enum TrafficLightWindowLayout {
    static let refreshNotificationNames: [NSNotification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didUpdateNotification,
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
        controller.refresh()
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

    private let leftInset = TrafficLightLayout.leadingInset
    private let topInset = TrafficLightLayout.topInset
    private let buttonSpacing = TrafficLightLayout.buttonSpacing

    private var hostedButtons: [NSButton] = []
    private weak var attachedWindow: NSWindow?
    private var lastTranslationX: CGFloat = 0
    private var windowObservers: Set<AnyCancellable> = []
    private var titleObservation: NSKeyValueObservation?
    private var lastAppliedPlacements: [(origin: NSPoint, isHidden: Bool)] = []
    private var stompRecheckScheduled = false
    private var stompRecheckBudget = 0
    private var repositionScheduled = false

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
        scheduleButtonReposition()
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
        titleObservation?.invalidate()
        titleObservation = nil

        guard let window else { return }

        // Assigning NSWindow.title synchronously restores the standard buttons
        // to AppKit's default frames. Observe the title without hopping run
        // loops so our custom placement is restored before the setter returns
        // and the default position can be displayed. Going through the
        // controller preserves the sheet-specific deferral above.
        titleObservation = window.observe(\.title, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            MainActor.assumeIsolated {
                self?.controller?.refresh()
            }
        }

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
        // Re-apply each call: AppKit can reset titlebar button chrome during
        // window state transitions, which would otherwise let the buttons
        // drift back to the default position or vanish entirely.
        for button in hostedButtons {
            button.autoresizingMask = []
            button.wantsLayer = true
            button.layer?.mask = nil
        }
    }

    @MainActor
    private func scheduleButtonReposition() {
        guard !repositionScheduled else { return }
        repositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repositionScheduled = false
                self.applyButtonTranslation(self.lastTranslationX)
            }
        }
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
        let controlWidth = buttonSpacing * CGFloat(max(hostedButtons.count - 1, 0))
            + (hostedButtons.last?.frame.width ?? TrafficLightLayout.fallbackButtonDiameter)
        let controlHeight = hostedButtons.map(\.frame.height).max()
            ?? TrafficLightLayout.fallbackButtonDiameter
        let controlsAreFullyOffscreen = baseX + controlWidth <= 0
        let targetY = bounds.height - topInset - controlHeight
        let originInParent = convert(
            NSPoint(x: baseX, y: max(0, targetY)),
            to: parent
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        lastAppliedPlacements = hostedButtons.enumerated().map { index, button in
            let origin = NSPoint(
                x: originInParent.x + CGFloat(index) * buttonSpacing,
                y: originInParent.y + (controlHeight - button.frame.height) / 2
            )
            button.setFrameOrigin(origin)
            button.isHidden = controlsAreFullyOffscreen
            return (origin: origin, isHidden: controlsAreFullyOffscreen)
        }

        CATransaction.commit()

        // AppKit's titlebar layout can stomp the placement we just made
        // within the same runloop turn (it re-lays the standard buttons
        // after us, restoring their default origin or visibility). During
        // animations the next tick re-applies, and any user event triggers
        // `didUpdateNotification` — but an unanimated change on an idle
        // window (hover-grace timers, MCP-driven chrome updates) has
        // neither, so the stomped state would stay on screen until the
        // user next interacts. Verify asynchronously and re-apply if so.
        stompRecheckBudget = 3
        scheduleStompRecheck()
    }

    @MainActor
    private func scheduleStompRecheck() {
        guard !stompRecheckScheduled else { return }
        stompRecheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stompRecheckScheduled = false
            guard self.window != nil, self.stompRecheckBudget > 0 else { return }
            self.stompRecheckBudget -= 1

            let stomped = self.hostedButtons.isEmpty
                || self.hostedButtons.count != self.lastAppliedPlacements.count
                || zip(self.hostedButtons, self.lastAppliedPlacements).contains { button, expected in
                    button.superview == nil
                        || button.frame.origin != expected.origin
                        || button.isHidden != expected.isHidden
                }
            guard stomped else { return }

            let budget = self.stompRecheckBudget
            self.refreshButtonState()
            // `applyButtonTranslation` resets the budget; restore the
            // decremented one so a persistent stomper can't ping-pong
            // with us indefinitely.
            self.stompRecheckBudget = budget
            self.scheduleStompRecheck()
        }
    }

    @MainActor
    func restore() {
        titleObservation?.invalidate()
        titleObservation = nil
        windowObservers.removeAll()
        for button in hostedButtons {
            button.layer?.mask = nil
            button.isEnabled = true
            button.isHidden = false
        }
        hostedButtons = []
        controller?.detach(self)
    }
}

private struct SidebarTopChromeShield: View {
    let projectRoot: String?
    let presentation: SidebarPresentation

    var body: some View {
        VStack(spacing: 0) {
            SidebarBackground(projectRoot: projectRoot, presentation: presentation)
                .frame(height: TopChromeShieldMetrics.projectSidebar.coverHeight)

            SidebarBackground(projectRoot: projectRoot, presentation: presentation)
                .mask {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: TopChromeShieldMetrics.projectSidebar.fadeHeight)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            terminalSettings: terminalSettings, agentSettings: agentSettings,
            projectRoot: projectRoot, colorScheme: colorScheme, presentation: presentation
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

private struct SidebarAgentWorkingIndicator: NSViewRepresentable {
    let isSelected: Bool
    let palette: SidebarPalette

    func makeNSView(context: Context) -> SidebarAgentWorkingIndicatorView {
        SidebarAgentWorkingIndicatorView()
    }

    func updateNSView(_ nsView: SidebarAgentWorkingIndicatorView, context: Context) {
        let color = NSColor(isSelected ? palette.selectedText : palette.rowText)
            .withAlphaComponent(0.66)
        nsView.update(color: color)
    }

    static func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarAgentWorkingIndicatorView,
        context: Context
    ) -> CGSize? {
        SidebarAgentWorkingIndicatorView.viewSize
    }
}

private final class SidebarAgentWorkingIndicatorView: NSView {
    fileprivate static let viewSize = NSSize(width: 14, height: 18)
    private static let animationKey = "sidebar-agent-working-spin"

    private let arcLayer = CAShapeLayer()
    private var indicatorColor = NSColor.labelColor.withAlphaComponent(0.66)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.viewSize))
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        arcLayer.fillColor = nil
        arcLayer.lineWidth = 1.7
        arcLayer.lineCap = .round
        attachArcLayerIfNeeded()

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Agent working")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        Self.viewSize
    }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            arcLayer.removeAnimation(forKey: Self.animationKey)
        } else {
            attachArcLayerIfNeeded()
            updateLayerGeometry()
            startAnimating()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColor()
    }

    func update(color: NSColor) {
        indicatorColor = color
        attachArcLayerIfNeeded()
        updateLayerColor()
        startAnimating()
    }

    private func attachArcLayerIfNeeded() {
        wantsLayer = true
        guard let layer, arcLayer.superlayer !== layer else { return }
        arcLayer.removeFromSuperlayer()
        layer.addSublayer(arcLayer)
    }

    private func updateLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachArcLayerIfNeeded()
        arcLayer.frame = bounds
        arcLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        let diameter: CGFloat = 10
        let radius = diameter / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: -CGFloat.pi / 2,
            endAngle: CGFloat.pi * 0.95,
            clockwise: false
        )
        arcLayer.path = path
        updateLayerColor()
        CATransaction.commit()
    }

    private func updateLayerColor() {
        arcLayer.strokeColor = indicatorColor.cgColor
    }

    private func startAnimating() {
        guard window != nil else { return }
        guard arcLayer.animation(forKey: Self.animationKey) == nil else { return }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 0.72
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        arcLayer.add(animation, forKey: Self.animationKey)
    }
}

private struct SidebarAgentPermissionIndicator: View {
    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
            .frame(width: 14, height: 18)
            .accessibilityLabel("Agent awaiting permission")
    }
}

/// The agent asks the user a question with a choice menu: like the
/// permission hand, it shows for as long as the menu waits.
private struct SidebarAgentQuestionIndicator: View {
    var body: some View {
        Image(systemName: "questionmark.bubble.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.orange)
            .frame(width: 14, height: 18)
            .help("The agent is asking you a question")
            .accessibilityLabel("Agent asking a question")
    }
}

/// The program finished (`done`) or failed (`error`) a turn the user has
/// not seen (`TerminalSession.hasUnseenAgentResult`).
private struct SidebarAgentResultIndicator: View {
    let failed: Bool

    var body: some View {
        Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(failed ? Color.red : Color.pink)
            .frame(width: 14, height: 18)
            .help(failed ? "The program failed" : "The program finished: its result is ready")
            .accessibilityLabel(failed ? "Program failed" : "Result ready")
    }
}

private struct SidebarTabRow: View {
    @StateObject private var rowState: SidebarTabRowState

    let isSelected: Bool
    let palette: SidebarPalette
    let pathDisplayMode: SidebarTerminalPathDisplayMode
    let shortcutNumber: Int
    let showShortcutHint: Bool
    let nestingDepth: Int
    let showsDisclosure: Bool
    let isDisclosureExpanded: Bool
    let onToggleDisclosure: (() -> Void)?
    let onSelect: () -> Void

    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons
    @State private var isHovered = false

    init(
        session: TerminalSession,
        isSelected: Bool,
        palette: SidebarPalette,
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
        self.palette = palette
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
        let label = rowState.label
        let nested = nestingDepth > 0
        let nestedGuideReservationWidth = AgentTreeLayout.nestedGuideReservationWidth
        let nestedBackgroundLeadingInset = nested
            ? SidebarLayout.rowHorizontalInset + nestedGuideReservationWidth + 2
            : 0
        let rowHeight: CGFloat = if nested {
            label.detail == nil ? AgentTreeLayout.childRowHeight : AgentTreeLayout.childDetailRowHeight
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
                .offset(x: AgentTreeLayout.disclosureOffset)
                .padding(.trailing, -6)
            }

            if let brand = rowState.agentBrand {
                if !usesInlineAgentIconsForRow {
                    AgentToolIcon(brand: brand, isSelected: isSelected, palette: palette)
                }
            } else if label.leadingIconResourceName != nil || label.leadingIconFallback != nil {
                if !usesInlineProgramIconsForRow {
                    SidebarProgramIcon(label: label, isSelected: isSelected, palette: palette)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label.title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                        .lineLimit(1)

                    if let nixShellEnvironment = rowState.nixShellEnvironment {
                        NixShellBadge(
                            environment: nixShellEnvironment,
                            isSelected: isSelected,
                            palette: palette
                        )
                        .help(nixShellEnvironment.tooltip)
                    }
                }

                if let detail = label.detail {
                    HStack(spacing: 4) {
                        if let resourceName = label.detailIconResourceName {
                            SidebarDetailIcon(resourceName: resourceName)
                        } else if usesInlineAgentDetailIcons, let brand = rowState.agentBrand {
                            AgentToolInlineIcon(brand: brand)
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

            if rowState.agentActivityState == .permission {
                SidebarAgentPermissionIndicator()
            } else if rowState.agentActivityState == .needsInput {
                SidebarAgentQuestionIndicator()
            } else if rowState.hasUnseenAgentResult, !isSelected {
                SidebarAgentResultIndicator(failed: rowState.agentActivityState == .error)
            } else if rowState.agentActivityState == .working {
                SidebarAgentWorkingIndicator(isSelected: isSelected, palette: palette)
            }

            // Cherry tasks (MCP spawn_agent with task): an orchestrator's
            // open runs as settled/total, a worker's task state.
            if let progress = rowState.runProgress {
                Text(progress.text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.6))
                    .accessibilityLabel("\(progress.settled) of \(progress.total) tasks settled")
            }

            if let badge = rowState.taskBadge {
                SidebarTaskStateGlyph(state: badge.state, isSelected: isSelected, palette: palette)
            }

            if rowState.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle((isSelected ? palette.selectedText : palette.rowText).opacity(0.5))
                    .help("Its session is also open in another client")
                    .accessibilityLabel("Shared session")
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
            SidebarRowBackground(isSelected: isSelected, isHovered: isHovered, palette: palette)
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
        .help(rowState.helpText)
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
    private(set) var agentBrand: AgentToolBrand?

    @Published private(set) var label: SidebarTerminalPathLabel
    @Published private(set) var hasUnreadNotification: Bool
    @Published private(set) var agentActivityState: AgentActivityState
    @Published private(set) var hasUnseenAgentResult: Bool
    /// What the program says it is doing or waits for (its root program
    /// status record's message): untrusted, shown as plain text.
    @Published private(set) var programStatusMessage: String?
    @Published private(set) var nixShellEnvironment: NixShellEnvironment?
    /// Its session is shared with other clients (`TerminalSession.sharedSessionBar`).
    @Published private(set) var isShared = false
    /// Its task, when it is a Cherry task's worker (`AgentTaskBoard`).
    @Published private(set) var taskBadge: AgentTaskBadge?
    /// Its open runs' progress, when it handed out tasks.
    @Published private(set) var runProgress: AgentRunProgress?

    private weak var session: TerminalSession?
    private var pathDisplayMode: SidebarTerminalPathDisplayMode
    private var cancellables: Set<AnyCancellable> = []

    init(session: TerminalSession, pathDisplayMode: SidebarTerminalPathDisplayMode) {
        self.session = session
        self.pathDisplayMode = pathDisplayMode
        self.tint = session.tint
        self.agentBrand = AgentToolBrand.forSession(
            kind: session.kind,
            agentName: session.agentName,
            title: session.title,
            commandLine: session.subtitle
        )
        self.label = SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode)
        self.hasUnreadNotification = session.hasUnreadNotification
        self.agentActivityState = session.agentActivityState
        self.hasUnseenAgentResult = session.hasUnseenAgentResult
        self.programStatusMessage = session.programStatus.root?.message.nilIfEmpty
        self.nixShellEnvironment = session.nixShellEnvironment

        observe(session)
    }

    var helpText: String {
        var lines = [label.title]
        if let detail = label.detail, !detail.isEmpty {
            lines.append(detail)
        }
        if let programStatusMessage {
            lines.append(programStatusMessage)
        }
        if let nixShellEnvironment {
            lines.append(nixShellEnvironment.tooltip)
        }
        if let taskBadge {
            lines.append("Task: \(taskBadge.label)\(taskBadge.phase.map { " (\($0))" } ?? "") · \(taskBadge.state.displayName)")
            if let summary = taskBadge.summary {
                lines.append(summary)
            }
        }
        if let runProgress {
            lines.append("Tasks: \(runProgress.settled) of \(runProgress.total) settled")
        }
        return lines.joined(separator: "\n")
    }

    func updatePathDisplayMode(_ mode: SidebarTerminalPathDisplayMode) {
        guard pathDisplayMode != mode else { return }
        pathDisplayMode = mode
        refreshLabel()
    }

    private func observe(_ session: TerminalSession) {
        // The label is read from the session on a later turn: @Published
        // emits before the session stores its new value.
        Publishers.Merge3(
            session.$hostedAttachmentStatus.removeDuplicates().map { _ in () },
            Publishers.CombineLatest3(session.$title, session.$titleSource, session.$subtitle)
                .combineLatest(session.$workingDirectory)
                .map { _ in () },
            session.$resolvedCommandLine.removeDuplicates().map { _ in () }
        )
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
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.agentActivityState = state
                }
            }
            .store(in: &cancellables)

        session.$hasUnseenAgentResult
            .removeDuplicates()
            .sink { [weak self] unseen in
                Task { @MainActor [weak self] in
                    self?.hasUnseenAgentResult = unseen
                }
            }
            .store(in: &cancellables)

        session.$programStatus
            .map { $0.root?.message.nilIfEmpty }
            .removeDuplicates()
            .sink { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.programStatusMessage = message
                }
            }
            .store(in: &cancellables)

        session.$nixShellEnvironment
            .removeDuplicates()
            .sink { [weak self] environment in
                Task { @MainActor [weak self] in
                    self?.nixShellEnvironment = environment
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(session.$hostSessionSharing, session.$adapterLiveStatus, session.$state)
            .sink { [weak self, weak session] _ in
                Task { @MainActor [weak self, weak session] in
                    let shared = session?.sharedSessionBar != nil
                    if self?.isShared != shared { self?.isShared = shared }
                }
            }
            .store(in: &cancellables)

        let sessionID = session.id
        AgentTaskBoard.shared.$badges
            .map { $0[sessionID] }
            .removeDuplicates()
            .sink { [weak self] badge in
                Task { @MainActor [weak self] in
                    self?.taskBadge = badge
                }
            }
            .store(in: &cancellables)

        AgentTaskBoard.shared.$runProgress
            .map { $0[sessionID] }
            .removeDuplicates()
            .sink { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.runProgress = progress
                }
            }
            .store(in: &cancellables)
    }

    private func refreshLabel() {
        guard let session else { return }
        agentBrand = AgentToolBrand.forSession(
            kind: session.kind,
            agentName: session.agentName,
            title: session.title,
            commandLine: session.subtitle
        )
        let nextLabel = SidebarSessionLabel.label(for: session, pathDisplayMode: pathDisplayMode)
        guard label != nextLabel else { return }
        label = nextLabel
    }
}

/// A Cherry task worker's state in its sidebar row (`AgentTaskState`).
private struct SidebarTaskStateGlyph: View {
    let state: AgentTaskState
    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Task: \(state.displayName)")
    }

    private var color: Color {
        switch state {
        case .reported: .green
        case .failed: .red
        case .needsInput, .awaitingApproval: .orange
        case .noReport: .yellow
        case .queued, .working, .cancelled: (isSelected ? palette.selectedText : palette.rowText).opacity(0.5)
        }
    }
}

/// A tab's name as the sidebar shows it; also the name the close and quit
/// questions list it by.
@MainActor
enum SidebarSessionLabel {
    static func label(
        for session: TerminalSession,
        pathDisplayMode: SidebarTerminalPathDisplayMode
    ) -> SidebarTerminalPathLabel {
        if session.kind == .agent {
            return .init(
                title: SidebarAgentTitleFormatter.title(
                    title: session.title,
                    titleSource: session.titleSource,
                    agentName: session.agentName,
                    commandLine: session.subtitle
                ),
                detail: session.sidebarDetail.nilIfEmpty
            )
        }

        guard session.kind == .terminal, !session.hasExplicitTitle else {
            return .init(title: session.title, detail: session.sidebarDetail.nilIfEmpty)
        }

        // A device's tab shortens its paths with that Mac's home.
        let home = session.pathHomeDirectory
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle == SidebarTerminalPathFormatter.displayPath(session.workingDirectory, homeDirectory: home) {
            return SidebarTerminalPathFormatter.label(
                for: session.workingDirectory,
                mode: pathDisplayMode,
                homeDirectory: home
            )
        }

        if let programLabel = SidebarTerminalProgramFormatter.label(
            for: session.title,
            workingDirectory: session.workingDirectory,
            homeDirectory: home,
            resolvedCommandLine: session.resolvedCommandLine
        ) {
            return programLabel
        }

        if SidebarTerminalPathFormatter.shouldUseWorkingDirectoryLabel(
            title: session.title,
            workingDirectory: session.workingDirectory,
            homeDirectory: home
        ) {
            return SidebarTerminalPathFormatter.label(
                for: session.workingDirectory,
                mode: pathDisplayMode,
                homeDirectory: home
            )
        }

        return .init(title: session.title, detail: session.sidebarDetail.nilIfEmpty)
    }
}

struct SidebarAgentTitleFormatter {
    static func title(
        title: String,
        titleSource: TerminalSession.TitleSource,
        agentName: String?,
        commandLine: String
    ) -> String {
        guard titleSource == .system,
              let brand = AgentToolBrand.detect(name: agentName ?? title, commandLine: commandLine)
        else {
            return title
        }
        return brand.displayName
    }
}

private struct NixShellBadge: View {
    let environment: NixShellEnvironment
    let isSelected: Bool
    let palette: SidebarPalette

    var body: some View {
        let accent = Color(nsColor: .systemCyan)
        let foreground = isSelected ? palette.selectedText : accent

        HStack(spacing: 2) {
            Image(systemName: "snowflake")
                .font(.system(size: 8, weight: .semibold))

            Text("Nix")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            Capsule(style: .continuous)
                .fill(accent.opacity(isSelected ? 0.18 : 0.12))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(accent.opacity(isSelected ? 0.28 : 0.22), lineWidth: 1)
                }
        }
        .fixedSize()
        .accessibilityLabel(environment.tooltip)
    }
}

private extension AgentToolBrand {
    /// The brand an agent tab's icon shows: nil for a terminal or an agent
    /// Cherry does not know.
    static func forSession(
        kind: TerminalSession.SessionKind,
        agentName: String?,
        title: String,
        commandLine: String?
    ) -> AgentToolBrand? {
        guard kind == .agent else { return nil }
        return detect(name: agentName ?? title, commandLine: commandLine)
    }
}

private enum SidebarIconMetrics {
    static let programGlyphScaleKey = "sidebar.icons.programGlyphScale"
    static let detailGlyphScaleKey = "sidebar.icons.detailGlyphScale"
    static let agentGlyphScaleKey = "sidebar.icons.agentGlyphScale"
    static let usesInlineProgramDetailIconsKey = "sidebar.icons.usesInlineDetailIcons"
    static let usesInlineAgentDetailIconsKey = "sidebar.icons.usesInlineAgentDetailIcons"
    static let usesIconBackgroundCirclesKey = "sidebar.icons.usesIconBackgroundCircles"

    static let defaultProgramGlyphScale = 1.00
    static let defaultDetailGlyphScale = 1.20
    static let defaultAgentGlyphScale = 1.15
    static let defaultUsesInlineProgramDetailIcons = false
    static let defaultUsesInlineAgentDetailIcons = false
    static let defaultUsesIconBackgroundCircles = false

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
        defaults.set(defaultUsesIconBackgroundCircles, forKey: usesIconBackgroundCirclesKey)
    }
}

private struct AgentToolIcon: View {
    let brand: AgentToolBrand
    let isSelected: Bool
    let palette: SidebarPalette

    @AppStorage(SidebarIconMetrics.agentGlyphScaleKey) private var agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale
    @AppStorage(SidebarIconMetrics.usesIconBackgroundCirclesKey) private var usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles

    var body: some View {
        let iconColor = isSelected ? palette.selectedText : palette.rowText
        let glyphSize = SidebarIconMetrics.agentGlyphSize * CGFloat(agentGlyphScale)

        ZStack {
            if usesIconBackgroundCircles {
                Circle()
                    .fill(iconColor.opacity(isSelected ? 0.18 : 0.10))
            }

            if let logoResourceName = brand.logoResourceName {
                AgentLogoImage(
                    resourceName: logoResourceName,
                    rendersAsTemplate: true,
                    fallbackLabel: brand.fallbackLabel
                )
                .frame(width: glyphSize, height: glyphSize)
            } else {
                Text(brand.fallbackLabel)
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
    @AppStorage(SidebarIconMetrics.usesIconBackgroundCirclesKey) private var usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles

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
            } else if label.leadingIconFallback != nil {
                if usesIconBackgroundCircles {
                    Circle()
                        .fill(iconColor.opacity(isSelected ? 0.16 : 0.10))
                }

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphSize, height: glyphSize)
                    .opacity(0.68)
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
    let brand: AgentToolBrand

    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale
    @AppStorage(SidebarIconMetrics.usesIconBackgroundCirclesKey) private var usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles

    var body: some View {
        let glyphSize = SidebarIconMetrics.detailGlyphSize * CGFloat(detailGlyphScale)

        ZStack {
            if let logoResourceName = brand.logoResourceName {
                AgentLogoImage(
                    resourceName: logoResourceName,
                    rendersAsTemplate: true,
                    fallbackLabel: brand.fallbackLabel
                )
                .frame(width: glyphSize, height: glyphSize)
            } else {
                if usesIconBackgroundCircles {
                    Circle()
                        .fill(.primary.opacity(0.14))
                }

                Text(brand.fallbackLabel)
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
    @AppStorage(SidebarIconMetrics.usesIconBackgroundCirclesKey) private var usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles

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
            } else if label.leadingIconFallback != nil {
                if usesIconBackgroundCircles {
                    Circle()
                        .fill(.primary.opacity(0.14))
                }

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphSize, height: glyphSize)
                    .opacity(0.68)
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

        let url = CherryResources.bundle.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "AgentLogos"
        ) ?? CherryResources.bundle.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "ProgramLogos"
        ) ?? CherryResources.bundle.url(
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

private struct SidebarPlaygroundOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @ObservedObject private var agentSettings = AgentSettings.shared

    let projectRoot: String?
    let livePresentation: SidebarPresentation
    let leadingOffset: CGFloat
    @Binding var isPresented: Bool

    @AppStorage(SidebarIconMetrics.programGlyphScaleKey) private var programGlyphScale = SidebarIconMetrics.defaultProgramGlyphScale
    @AppStorage(SidebarIconMetrics.detailGlyphScaleKey) private var detailGlyphScale = SidebarIconMetrics.defaultDetailGlyphScale
    @AppStorage(SidebarIconMetrics.agentGlyphScaleKey) private var agentGlyphScale = SidebarIconMetrics.defaultAgentGlyphScale
    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons
    @AppStorage(SidebarIconMetrics.usesIconBackgroundCirclesKey) private var usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles
    @State private var didCopyValues = false

    private let panelWidth: CGFloat = 430
    private let topInset: CGFloat = 22
    private let minimumInset: CGFloat = 8
    private let trailingInset: CGFloat = 18

    var body: some View {
        let palette = SidebarPalette(
            terminalSettings: terminalSettings, agentSettings: agentSettings,
            projectRoot: projectRoot, colorScheme: colorScheme, presentation: livePresentation
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
        usesIconBackgroundCircles = SidebarIconMetrics.defaultUsesIconBackgroundCircles
    }

    private func copyValues() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedValuesText, forType: .string)
        didCopyValues = true

        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            didCopyValues = false
        }
    }

    private var copiedValuesText: String {
        """
        static let defaultProgramGlyphScale = \(formatted(programGlyphScale))
        static let defaultDetailGlyphScale = \(formatted(detailGlyphScale))
        static let defaultAgentGlyphScale = \(formatted(agentGlyphScale))
        static let defaultUsesInlineProgramDetailIcons = \(usesInlineProgramDetailIcons)
        static let defaultUsesInlineAgentDetailIcons = \(usesInlineAgentDetailIcons)
        static let defaultUsesIconBackgroundCircles = \(usesIconBackgroundCircles)
        """
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func clampedLeadingOffset(in size: CGSize) -> CGFloat {
        max(minimumInset, min(leadingOffset, size.width - panelWidth - trailingInset))
    }

    private func panel(palette: SidebarPalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Sidebar Icons")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.rowText)

                Spacer()

                Button(action: copyValues) {
                    Label(didCopyValues ? "Copied" : "Copy Values", systemImage: didCopyValues ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.rowText.opacity(0.76))
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.rowText.opacity(0.08))
                }
                .help("Copy icon tuning values")

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

                Toggle(isOn: $usesInlineAgentDetailIcons) {
                    Text("Small agent icons in detail line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.rowText.opacity(0.72))
                }

                Toggle(isOn: $usesIconBackgroundCircles) {
                    Text("Icon background circles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.rowText.opacity(0.72))
                }
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
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: panelWidth)
        .frame(maxHeight: 690)
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
                if let brand = AgentToolBrand.detect(name: "Codex") {
                    AgentToolIcon(brand: brand, isSelected: false, palette: palette)
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

            SidebarAgentChildrenGroup(
                children: SidebarIconDebugFixtures.agentChildren,
                palette: palette,
                isActive: true,
                hasDetail: { $0.detail != nil }
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

    @AppStorage(SidebarIconMetrics.usesInlineProgramDetailIconsKey) private var usesInlineProgramDetailIcons = SidebarIconMetrics.defaultUsesInlineProgramDetailIcons
    @AppStorage(SidebarIconMetrics.usesInlineAgentDetailIconsKey) private var usesInlineAgentDetailIcons = SidebarIconMetrics.defaultUsesInlineAgentDetailIcons

    var body: some View {
        let nested = nestingDepth > 0
        let nestedGuideReservationWidth = AgentTreeLayout.nestedGuideReservationWidth
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
                    .offset(x: AgentTreeLayout.disclosureOffset)
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
        !shouldShowInlineIcon && !isEmptyIcon
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
            detail == nil ? AgentTreeLayout.childRowHeight : AgentTreeLayout.childDetailRowHeight
        } else {
            detail == nil ? 42 : 50
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .agent(let name):
            if let brand = AgentToolBrand.detect(name: name) {
                AgentToolIcon(brand: brand, isSelected: isSelected, palette: palette)
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
            if let brand = AgentToolBrand.detect(name: name) {
                AgentToolInlineIcon(brand: brand)
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
        .init(kind: .programs, name: "shortcake", fallback: "Sc"),
        .init(kind: .programs, name: "swift", fallback: "Sw"),
        .init(kind: .programs, name: "uv", fallback: "uv"),
        .init(kind: .programs, name: "vim", fallback: "Vi"),
        .init(kind: .programs, name: "vite", fallback: "Vt"),
        .init(kind: .programs, name: "yarn", fallback: "Ya")
    ]
}

private struct SidebarPalette: Equatable {
    private struct Signature: Equatable {
        let themeColors: TerminalThemeColors
        let fallbackIsDark: Bool
        let sidebarBackgroundDepth: Double
        let projectColor: ProjectIdentityColor?
        let projectColorDisplayMode: String
        let presentation: SidebarPresentation
    }

    private let signature: Signature
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
    }
}

// The initializers are in an extension, so Swift still synthesizes the
// memberwise one they build the palette with.
extension SidebarPalette {
    init(
        themeColors: TerminalThemeColors,
        fallbackColorScheme: ColorScheme,
        sidebarBackgroundDepth: Double,
        projectColor: ProjectIdentityColor? = nil,
        projectColorDisplayMode: ProjectColorDisplayMode = .accent,
        presentation: SidebarPresentation
    ) {
        let signature = Signature(
            themeColors: themeColors,
            fallbackIsDark: fallbackColorScheme == .dark,
            sidebarBackgroundDepth: sidebarBackgroundDepth,
            projectColor: projectColor,
            projectColorDisplayMode: projectColorDisplayMode.rawValue,
            presentation: presentation
        )
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
                signature: signature,
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
                signature: signature,
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

    /// The palette of a project's sidebar from the current settings.
    @MainActor
    init(
        terminalSettings: TerminalSettings,
        agentSettings: AgentSettings,
        projectRoot: String?,
        colorScheme: ColorScheme,
        presentation: SidebarPresentation
    ) {
        self.init(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: terminalSettings.sidebarBackgroundDepth,
            projectColor: agentSettings.projectAppearance(for: projectRoot).color,
            projectColorDisplayMode: terminalSettings.projectColorDisplayMode,
            presentation: presentation
        )
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

/// A theme's background and text colors for SwiftUI, with the system's where
/// the theme's are not valid hex colors.
extension TerminalThemeColors {
    var backgroundColor: Color {
        Color(nsColor: NSColor(hexRGB: background) ?? .windowBackgroundColor)
    }

    var foregroundColor: Color {
        Color(nsColor: NSColor(hexRGB: foreground) ?? .labelColor)
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

struct TerminalSplitSceneView: View {
    private static let dividerWidth: CGFloat = 5
    private static let paneCornerRadius: CGFloat = 9

    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @State private var dividerDragState: DividerDragState?

    init(workspace: TerminalWorkspace, chromeState: ProjectWindowChromeState) {
        self.workspace = workspace
        self.chromeState = chromeState
    }

    var body: some View {
        GeometryReader { geometry in
            let panes = paneSessions
            let group = activeGroup
            let contentWidth = max(0, geometry.size.width - Self.dividerWidth * CGFloat(max(0, panes.count - 1)))
            let widths = paneWidths(
                for: group,
                paneCount: panes.count,
                contentWidth: contentWidth,
                overrideWeights: previewWeights(for: group, paneCount: panes.count)
            )

            HStack(spacing: 0) {
                // A pane is a visual slot: keyed by its place, not its session,
                // so `updateNSView` hands a replacement session to the same
                // container instead of destroying its NSViewRepresentable.
                ForEach(Array(panes.enumerated()), id: \.offset) { index, session in
                    TerminalSceneView(
                        session: session,
                        chromeState: chromeState,
                        isActivePane: workspace.selectedSessionID == session.id,
                        onActivate: activate,
                        // Matches the sidebar: a workspace's last tab stays open.
                        closeHostedSession: workspace.sessions.count > 1 ? { workspace.close($0) } : nil
                    )
                    .frame(width: width(at: index, in: widths))
                    .roundedTerminalSplitPane(
                        isEnabled: panes.count > 1,
                        radius: Self.paneCornerRadius
                    )

                    if index < panes.count - 1 {
                        TerminalSplitDivider(
                            onDragChanged: { translation in
                                guard let group else { return }
                                resizeDivider(
                                    group: group,
                                    dividerIndex: index,
                                    translation: translation,
                                    contentWidth: contentWidth
                                )
                            },
                            onDragEnded: {
                                commitDividerDrag()
                            }
                        )
                        .frame(width: Self.dividerWidth)
                    }
                }
            }
            .transaction { transaction in
                if dividerDragState != nil {
                    transaction.animation = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .onAppear {
                workspace.updateTerminalDetailWidth(geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                workspace.updateTerminalDetailWidth(width)
            }
        }
    }

    private var activeGroup: TerminalSplitGroup? {
        guard let selectedSessionID = workspace.selectedSessionID else { return nil }
        return workspace.splitGroup(containing: selectedSessionID)
    }

    private var paneSessions: [TerminalSession] {
        if let group = activeGroup {
            return group.paneSessionIDs.compactMap { workspace.session(withID: $0) }
        }
        return workspace.selectedSession.map { [$0] } ?? []
    }

    private func activate(_ sessionID: UUID) {
        guard let session = workspace.session(withID: sessionID) else { return }
        chromeState.selectTerminal()
        workspace.select(session)
    }

    private func width(at index: Int, in widths: [CGFloat]) -> CGFloat {
        widths.indices.contains(index) ? widths[index] : 0
    }

    private func paneWidths(
        for group: TerminalSplitGroup?,
        paneCount: Int,
        contentWidth: CGFloat,
        overrideWeights: [Double]? = nil
    ) -> [CGFloat] {
        guard paneCount > 0 else { return [] }
        guard paneCount > 1, contentWidth > 0 else { return [max(0, contentWidth)] }

        let weights = effectiveWeights(for: group, paneCount: paneCount, overrideWeights: overrideWeights)
        var widths = weights.map { CGFloat($0) * contentWidth }
        let minimumWidth = contentWidth >= CGFloat(paneCount) * TerminalWorkspace.minimumSplitPaneWidth
            ? TerminalWorkspace.minimumSplitPaneWidth
            : 0

        guard minimumWidth > 0 else { return widths }

        var deficit: CGFloat = 0
        for index in widths.indices where widths[index] < minimumWidth {
            deficit += minimumWidth - widths[index]
            widths[index] = minimumWidth
        }

        guard deficit > 0 else { return widths }

        let flexibleIndices = widths.indices.filter { widths[$0] > minimumWidth }
        let flexibleCapacity = flexibleIndices.reduce(CGFloat(0)) { partial, index in
            partial + widths[index] - minimumWidth
        }
        guard flexibleCapacity > 0 else { return widths }

        for index in flexibleIndices {
            let capacity = widths[index] - minimumWidth
            widths[index] -= deficit * (capacity / flexibleCapacity)
        }
        return widths
    }

    private func resizeDivider(
        group: TerminalSplitGroup,
        dividerIndex: Int,
        translation: CGFloat,
        contentWidth: CGFloat
    ) {
        guard contentWidth > 0,
              dividerIndex >= 0,
              dividerIndex + 1 < group.paneSessionIDs.count
        else {
            return
        }

        let dragState: DividerDragState
        if let dividerDragState,
           dividerDragState.groupID == group.id,
           dividerDragState.dividerIndex == dividerIndex,
           dividerDragState.paneCount == group.paneSessionIDs.count {
            dragState = dividerDragState
        } else {
            let startWeights = paneWidths(
                for: group,
                paneCount: group.paneSessionIDs.count,
                contentWidth: contentWidth
            ).map { Double($0 / contentWidth) }
            dragState = DividerDragState(
                groupID: group.id,
                dividerIndex: dividerIndex,
                paneCount: group.paneSessionIDs.count,
                contentWidth: contentWidth,
                startWeights: startWeights,
                previewWeights: startWeights
            )
        }

        let dragContentWidth = max(dragState.contentWidth, 1)
        var widths = dragState.startWeights.map { CGFloat($0) * dragContentWidth }
        let pairTotal = widths[dividerIndex] + widths[dividerIndex + 1]
        let minimumPairWidth = min(TerminalWorkspace.minimumSplitPaneWidth, pairTotal / 2)
        let proposedLeft = widths[dividerIndex] + translation
        let left = min(max(proposedLeft, minimumPairWidth), pairTotal - minimumPairWidth)
        widths[dividerIndex] = left
        widths[dividerIndex + 1] = pairTotal - left

        dividerDragState = DividerDragState(
            groupID: dragState.groupID,
            dividerIndex: dragState.dividerIndex,
            paneCount: dragState.paneCount,
            contentWidth: dragContentWidth,
            startWeights: dragState.startWeights,
            previewWeights: widths.map { Double($0 / dragContentWidth) }
        )
    }

    private func previewWeights(for group: TerminalSplitGroup?, paneCount: Int) -> [Double]? {
        guard let group,
              let dividerDragState,
              dividerDragState.groupID == group.id,
              dividerDragState.paneCount == paneCount,
              dividerDragState.previewWeights.count == paneCount
        else {
            return nil
        }
        return dividerDragState.previewWeights
    }

    private func commitDividerDrag() {
        defer {
            dividerDragState = nil
        }

        guard let dividerDragState,
              workspace.splitGroup(id: dividerDragState.groupID)?.paneSessionIDs.count == dividerDragState.paneCount
        else {
            return
        }

        workspace.setSplitGroupWidthWeights(
            id: dividerDragState.groupID,
            weights: dividerDragState.previewWeights
        )
    }

    private func effectiveWeights(
        for group: TerminalSplitGroup?,
        paneCount: Int,
        overrideWeights: [Double]? = nil
    ) -> [Double] {
        if let overrideWeights,
           overrideWeights.count == paneCount {
            return overrideWeights
        }

        guard let group,
              group.widthWeights.count == paneCount
        else {
            return TerminalSplitGroup.balancedWeights(count: paneCount)
        }
        return group.widthWeights
    }

    private struct DividerDragState {
        let groupID: UUID
        let dividerIndex: Int
        let paneCount: Int
        let contentWidth: CGFloat
        let startWeights: [Double]
        let previewWeights: [Double]
    }
}

private struct TerminalSplitDivider: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        TerminalSplitDividerHandle(onDragChanged: onDragChanged, onDragEnded: onDragEnded)
            .frame(maxHeight: .infinity)
            .help("Drag to resize panes")
    }
}

private struct TerminalSplitDividerHandle: NSViewRepresentable {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> TerminalSplitDividerHandleView {
        let view = TerminalSplitDividerHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: TerminalSplitDividerHandleView, context: Context) {
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class TerminalSplitDividerHandleView: NSView {
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartLocationX: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var didPushCursor = false
    private var isDragging = false

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
        guard !isDragging else { return }
        popResizeCursorIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        dragStartLocationX = event.locationInWindow.x
        pushResizeCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartLocationX else { return }
        onDragChanged?(event.locationInWindow.x - dragStartLocationX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocationX = nil
        isDragging = false
        onDragEnded?()

        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            pushResizeCursor()
        } else {
            popResizeCursorIfNeeded()
        }
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

private extension View {
    /// A status bar's place over a terminal pane: centered at its bottom,
    /// `ProjectWindowToastOverlay.bottomInset` above the edge.
    func bottomStatusBarPlacement() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
    }
}

private struct TerminalSceneView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: TerminalSession
    @ObservedObject var chromeState: ProjectWindowChromeState
    let isActivePane: Bool
    let onActivate: (UUID) -> Void
    let closeHostedSession: ((TerminalSession) -> Void)?
    @StateObject private var searchState = TerminalSearchState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            paneContent

            if session.kind == .command {
                CommandExitStatusBar(session: session)
                    .bottomStatusBarPlacement()
            }

            PersistentSessionReconnectBar(session: session)
                .bottomStatusBarPlacement()

            HostWaitingBar(session: session)
                .bottomStatusBarPlacement()

            PersistentSessionFallbackBar(session: session)
                .bottomStatusBarPlacement()

            // A device's tab: its Mac offline, or it could not start there.
            RemoteHostStateBar(session: session)
                .bottomStatusBarPlacement()

            RemoteLaunchFailureBar(session: session)
                .bottomStatusBarPlacement()

            SharedSessionBar(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)

            PersistentSessionEndedBar(session: session, close: closeHostedSession.map { close in { close(session) } })
                .bottomStatusBarPlacement()

            if isActivePane, chromeState.isTerminalSearchPresented {
                TerminalSearchOverlay(
                    session: session,
                    searchState: searchState,
                    focusRequest: chromeState.terminalSearchFocusRequest,
                    onClose: closeSearch
                )
                .padding(.top, showsTerminalContextBar ? 48 : 12)
                .padding(.trailing, 12)
            }
        }
        .onAppear {
            configureSearchHandlersIfActive()
            acknowledgeAgentResultIfVisible()
        }
        .onChange(of: session.id) { _, _ in
            configureSearchHandlersIfActive()
        }
        .onChange(of: isActivePane) { _, isActivePane in
            if isActivePane {
                configureSearchHandlersIfActive()
                acknowledgeAgentResultIfVisible()
            }
        }
        .onChange(of: session.hasUnseenAgentResult) { _, _ in
            acknowledgeAgentResultIfVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            acknowledgeAgentResultIfVisible()
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if session.hostedAttachment != nil {
            // Any kind: a restored command or agent attached to its session
            // reconnects, or is removed, from here too.
            VStack(spacing: 0) {
                HostedSessionConnectionBar(
                    session: session,
                    close: closeHostedSession.map { close in { close(session) } }
                )
                terminalSurface
            }
        } else if showsTerminalContextBar {
            VStack(spacing: 0) {
                // A device tab's path starts with its Mac's name.
                RemoteDeviceBadgeReader(projectKey: session.projectRoot) { device in
                    TerminalContextBar(
                        content: TerminalContextBarContent(session: session, device: device),
                        isActivePane: isActivePane
                    )
                    .equatable()
                }
                terminalSurface
            }
        } else {
            terminalSurface
        }
    }

    private var showsTerminalContextBar: Bool {
        session.kind == .terminal || session.kind == .agent
    }

    private var terminalSurface: some View {
        TerminalSurfaceView(
            session: session,
            chromeState: chromeState,
            isActivePane: isActivePane,
            onActivate: onActivate
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var backgroundColors: [Color] {
        colorScheme == .light
            ? [
                Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.99, alpha: 1)),
                Color(nsColor: NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.96, alpha: 1))
            ]
            : [
                Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)),
                Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1))
            ]
    }

    private func configureSearchHandlersIfActive() {
        guard isActivePane else { return }
        session.ghosttyBridge.configureSearch(
            state: searchState,
            onRequest: { [weak chromeState] _ in
                chromeState?.presentTerminalSearch()
            },
            onDismiss: { [weak chromeState] in
                chromeState?.dismissTerminalSearch()
            }
        )
    }

    private func closeSearch() {
        session.ghosttyBridge.endSearch()
        chromeState.dismissTerminalSearch()
        session.ghosttyBridge.focus(in: NSApp.keyWindow)
    }

    private func acknowledgeAgentResultIfVisible() {
        guard isActivePane, chromeState.isShowingTerminalContent, NSApp.isActive else { return }
        session.acknowledgeAgentResult()
    }
}

/// What a tab's context bar shows: only these of the tab's values. The
/// bar is given this instead of observing the tab, so the tab's other
/// changes (a keystroke's bookkeeping, output counters, agent state)
/// never re-render it or re-format its path.
struct TerminalContextBarContent: Equatable {
    let kind: TerminalSession.SessionKind
    let agentName: String?
    let title: String
    let titleSource: TerminalSession.TitleSource
    let subtitle: String
    let workingDirectory: String
    /// What `~` stands for in its path (a device's home for its tabs).
    let homeDirectory: String
    /// The Mac a device tab runs on (its path's prefix); nil on This Mac.
    let device: RemoteDeviceBadge?

    @MainActor
    init(session: TerminalSession, device: RemoteDeviceBadge? = nil) {
        kind = session.kind
        agentName = session.agentName
        title = session.title
        titleSource = session.titleSource
        subtitle = session.subtitle
        workingDirectory = session.workingDirectory
        homeDirectory = session.pathHomeDirectory
        self.device = device
    }

    var displayPath: String {
        SidebarTerminalPathFormatter.displayPath(workingDirectory, homeDirectory: homeDirectory)
    }

    /// "patstudio:" before a device tab's path; nil on This Mac.
    var devicePrefix: String? {
        device.map { "\($0.name):" }
    }

    var sessionLabel: String {
        if kind == .agent {
            return SidebarAgentTitleFormatter.title(
                title: title,
                titleSource: titleSource,
                agentName: agentName,
                commandLine: subtitle
            )
        }

        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || SidebarTerminalPathFormatter.shouldUseWorkingDirectoryLabel(
            title: title,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ) {
            return subtitle.replacingOccurrences(of: " login shell", with: "")
        }
        return title
    }
}

private struct TerminalContextBar: View, Equatable {
    private static let height: CGFloat = 36

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    let content: TerminalContextBarContent
    let isActivePane: Bool

    nonisolated static func == (lhs: TerminalContextBar, rhs: TerminalContextBar) -> Bool {
        lhs.content == rhs.content && lhs.isActivePane == rhs.isActivePane
    }

    var body: some View {
        // Formatted once per render: the path and label read the same values.
        let displayPath = content.displayPath
        let sessionLabel = content.sessionLabel
        HStack(spacing: 8) {
            leadingIcon
                .frame(width: 15, height: 15)
                .foregroundStyle(themeColors.foregroundColor.opacity(isActivePane ? 0.70 : 0.46))
                .accessibilityHidden(true)

            HStack(spacing: 5) {
                if let device = content.device, let prefix = content.devicePrefix {
                    Text(verbatim: prefix)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(device.color.color(for: colorScheme).opacity(isActivePane ? 1 : 0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(verbatim: "\(displayPath)  ›  \(sessionLabel)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(themeColors.foregroundColor.opacity(isActivePane ? 0.68 : 0.46))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(themeColors.backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(themeColors.foregroundColor.opacity(isActivePane ? 0.10 : 0.07))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [
            content.kind == .agent ? "Agent" : "Terminal",
            content.device.map { "on \($0.name)" },
            displayPath,
            sessionLabel
        ].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let brand = AgentToolBrand.forSession(
            kind: content.kind,
            agentName: content.agentName,
            title: content.title,
            commandLine: content.subtitle
        ),
           let logoResourceName = brand.logoResourceName {
            AgentLogoImage(
                resourceName: logoResourceName,
                rendersAsTemplate: true,
                fallbackLabel: brand.fallbackLabel
            )
        } else {
            Image(systemName: content.kind == .agent ? "sparkles" : "terminal")
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var themeColors: TerminalThemeColors {
        terminalSettings.ghosttyThemeColors(for: colorScheme)
    }
}

// Floats over an exited command's terminal instead of replacing it, so the
// final output (usually the reason a dev server died) stays readable.
// Observes the session directly: nothing above this view in the SwiftUI tree
// re-renders when a process exits on its own.
private struct CommandExitStatusBar: View {
    @ObservedObject var session: TerminalSession

    private struct Status {
        let text: String
        let isFailure: Bool
    }

    private var status: Status? {
        // A command the system ended says so in PersistentSessionEndedBar.
        guard session.systemSessionEnd == nil else { return nil }
        return switch session.state {
        case .launching, .live:
            nil
        case .exited(let code):
            if let end = session.hostSessionEnd {
                Status(text: session.restartOnExit ? "\(end.message); not restarted" : end.message, isFailure: true)
            } else if let notFound = session.remoteProgramNotFoundMessage {
                // A device's command its login shell did not find.
                Status(text: notFound, isFailure: true)
            } else if session.isAutoRestartPaused {
                Status(text: "Keeps failing — auto-restart paused", isFailure: true)
            } else if code == 0 {
                Status(text: "Command exited", isFailure: false)
            } else {
                Status(text: "Command exited with code \(code)", isFailure: true)
            }
        case .failed(let message):
            Status(text: "Launch failed: \(message)", isFailure: true)
        case .disconnected:
            // Attached tabs report it in their connection bar, persistent
            // ones in PersistentSessionReconnectBar.
            nil
        }
    }

    var body: some View {
        if let status {
            HStack(spacing: 10) {
                Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "stop.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))

                Text(status.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(status.text)

                Button("Restart") {
                    session.restartManagedCommandIfNeeded()
                }
                .controlSize(.small)
            }
            .floatingBarChrome()
        }
    }
}

// A local persistent tab whose attach adapter keeps failing to reattach, or
// has been reconnecting by itself for a while (the session host is down or
// restarting). Its program may still run on the host; the adapter or the tab
// keeps retrying, and this offers to try now (a new adapter).
private struct PersistentSessionReconnectBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        // A device's tab says so in RemoteHostStateBar.
        if session.isPersistentLocalSession, session.remoteMachineName == nil, session.state == .disconnected {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)

                Text("Reconnecting to its session…")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button("Reconnect Now") {
                    session.reconnectHostedSession()
                }
                .controlSize(.small)
            }
            .floatingBarChrome()
        }
    }
}

// A tab attached to an SSH host's session whose adapter gave up (the host
// did not answer for a while, or could not be reached) waits for its host
// (`HostedReconnects`): this says how many tabs wait for that host, and
// offers to try now instead of at the next backoff step.
private struct HostWaitingBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if session.isWaitingForHost, let reconnects = session.hostReconnects,
           let host = session.hostedAttachment?.host {
            HostWaitingBarContent(reconnects: reconnects, host: host)
        }
    }
}

private struct HostWaitingBarContent: View {
    @ObservedObject var reconnects: HostedReconnects
    let host: HostedSessionHost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)

            Text(HostedReconnects.waitingText(count: max(1, reconnects.waitingCounts[host.id] ?? 0), host: host))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(reconnects.pausedReasons[host.id].map { "Paused until you retry: \($0)" } ?? "")

            Button("Retry Now") {
                reconnects.retryNow(host)
            }
            .controlSize(.small)
        }
        .floatingBarChrome()
    }
}

// A tab that was to run as a persistent session and runs natively because the
// host could not start it (it rejected the Create, or did not answer in
// time): its program ends with Cherry. Retry starts it again in the host
// (ending the program that runs natively); Restart does too once the host
// takes new tabs.
private struct PersistentSessionFallbackBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let reason = session.persistentFallbackReason {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)

                Text("Not a persistent session: \(reason)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)

                Button("Retry") {
                    session.retryPersistentSession()
                }
                .controlSize(.small)
                .help("Start this tab's program again as a persistent session. The program running now ends.")
            }
            .floatingBarChrome()
        }
    }
}

// A tab whose hosted session other clients show too: a slim bar at the top
// says it is shown at the size a smaller client gives it (the adapter shows a
// viewport), or how many other clients have it open, with Take Over, which
// disconnects them so the session follows this tab's size.
private struct SharedSessionBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let bar = session.sharedSessionBar {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(bar.message)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button("Take Over") {
                    session.takeOverSharedSession()
                }
                .controlSize(.mini)
                .help("Disconnect the other clients, so the session follows this tab's size")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .frame(maxWidth: 460)
        }
    }
}

// A local persistent terminal or agent tab whose program ended (while Cherry
// was closed, or since): its session stays on the host with the final screen
// until the tab closes (which removes it) or restarts. Commands show
// CommandExitStatusBar instead. A terminal whose shell exited with status 0
// closes instead (TerminalWorkspace.tabProgramDidExit), unless Settings ›
// Sessions keeps such tabs or it ended within its first second. Also a tab
// of any kind whose session the system ended while Cherry was closed ("Ended
// when the Mac restarted", TerminalSession.systemSessionEnd): it has no
// session, and Restart starts its program again.
private struct PersistentSessionEndedBar: View {
    @ObservedObject var session: TerminalSession
    /// nil when the tab cannot be closed (the workspace's last tab).
    let close: (() -> Void)?

    var body: some View {
        if let message = session.persistentSessionEndedMessage {
            HStack(spacing: 10) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(message)

                Button("Restart") {
                    session.restart()
                }
                .controlSize(.small)

                Button("Close") {
                    close?()
                }
                .controlSize(.small)
                .disabled(close == nil)
                .help(close == nil
                    ? "The last tab in a workspace stays open. Open another tab to close this one."
                    : session.systemSessionEnd != nil
                        ? "Close this tab"
                        : "Close this tab and remove its ended session from This Mac's session host")
            }
            .floatingBarChrome()
        }
    }
}

private struct TerminalSearchOverlay: View {
    let session: TerminalSession
    @ObservedObject var searchState: TerminalSearchState
    let focusRequest: Int
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @State private var pendingSearchTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchState.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .frame(width: 190)
                    .onSubmit {
                        session.ghosttyBridge.navigateSearch(next: true)
                    }

                if let resultCountDescription = searchState.resultCountDescription {
                    Text(resultCountDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .trailing)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }

            Button(action: { navigate(.up) }) {
                Image(systemName: "chevron.up")
                    .terminalSearchButtonLabel()
            }
            .buttonStyle(.plain)
            .help("Find Previous")

            Button(action: { navigate(.down) }) {
                Image(systemName: "chevron.down")
                    .terminalSearchButtonLabel()
            }
            .buttonStyle(.plain)
            .help("Find Next")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .terminalSearchButtonLabel()
            }
            .buttonStyle(.plain)
            .help("Close Find Bar")
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)
        .onAppear {
            searchState.readQueryFromPasteboard()
            focusSearchField()
            scheduleSearch(searchState.query)
        }
        .onDisappear {
            pendingSearchTask?.cancel()
            pendingSearchTask = nil
        }
        .onChange(of: focusRequest) { _, _ in
            searchState.readQueryFromPasteboard()
            focusSearchField()
        }
        .onChange(of: searchState.query) { _, query in
            searchState.writeQueryToPasteboard()
            scheduleSearch(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            searchState.readQueryFromPasteboard()
        }
        .onExitCommand(perform: onClose)
    }

    private func focusSearchField() {
        isSearchFieldFocused = true
        guard searchState.consumeSelectsQueryOnNextFocus() else { return }
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func scheduleSearch(_ query: String) {
        pendingSearchTask?.cancel()
        pendingSearchTask = Task { @MainActor in
            if !query.isEmpty && query.count < 3 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            session.ghosttyBridge.updateSearch(query: query)
        }
    }

    private func navigate(_ direction: TerminalSearchArrowDirection) {
        session.ghosttyBridge.navigateSearch(direction)
    }
}

private struct TerminalSearchButtonLabelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct RoundedTerminalSplitPaneModifier: ViewModifier {
    let isEnabled: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

private extension View {
    func terminalSearchButtonLabel() -> some View {
        modifier(TerminalSearchButtonLabelModifier())
    }

    func roundedTerminalSplitPane(isEnabled: Bool, radius: CGFloat) -> some View {
        modifier(RoundedTerminalSplitPaneModifier(isEnabled: isEnabled, radius: radius))
    }
}
