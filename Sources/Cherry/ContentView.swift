import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    private let minimumSidebarWidth: CGFloat = 190
    private let maximumSidebarWidth: CGFloat = 420
    private let floatingSidebarLeadingInset: CGFloat = 3
    private let floatingSidebarTopInset: CGFloat = 3
    private let floatingSidebarBottomInset: CGFloat = 3

    @Environment(\.openSettings) private var openSettings
    @ObservedObject var workspace: TerminalWorkspace
    @Binding var isSidebarHidden: Bool
    @Binding var isSidebarRevealed: Bool
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

                DetailPaneView(workspace: workspace, includeLeadingPadding: isSidebarHidden)
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
        .background(AppShortcutMonitor(workspace: workspace, openSettings: { openSettings() }))
        .background(WindowConfigurator())
        .frame(minWidth: 320, minHeight: 460)
        // The Animatable modifier MUST be inside the `.animation(...)` scope:
        // SwiftUI only calls `animatableData.set` when a transaction is in
        // play, and `.animation(...)` only creates one for views *within* its
        // scope. If the modifier sat outside, hover-driven state changes
        // would skip the setter entirely and the controller would stay stale.
        .modifier(ChromeWidthAnimator(
            dockedWidth: isSidebarHidden ? 0 : sidebarWidth,
            floatingWidth: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
            sidebarWidth: sidebarWidth,
            controller: trafficLights
        ))
        // No `.animation(value: isSidebarHidden)` here — the toggle in
        // CherryApp wraps in `withAnimation` only when the floating sidebar
        // is NOT revealed. When it IS revealed, the toggle is unwrapped, so
        // the docked + pane snap into place behind the floating's fade-out
        // (driven by the `.animation(value: isSidebarRevealed)` below).
        .animation(.snappy(duration: 0.18), value: isSidebarRevealed)
        .onChange(of: isSidebarHidden) { _, hidden in
            // When toggling from `(hidden, revealed)` to `shown`, dismiss
            // the floating sidebar within the same animation so it fades
            // out in place while the docked sidebar grows in.
            if !hidden, isSidebarRevealed {
                withAnimation(.snappy(duration: 0.18)) {
                    isSidebarRevealed = false
                }
            }
            syncTrafficLights()
        }
        .onChange(of: isSidebarRevealed) { _, _ in
            syncTrafficLights()
        }
        .onChange(of: sidebarWidth) { _, _ in
            syncTrafficLights()
        }
        .onAppear {
            storedSidebarWidth = Double(sidebarWidth)
            trafficLights.seedTarget(
                docked: isSidebarHidden ? 0 : sidebarWidth,
                floating: isSidebarRevealed ? sidebarWidth + floatingSidebarLeadingInset : 0,
                sidebarWidth: sidebarWidth
            )
        }
    }

    private var dockedSidebar: some View {
        SidebarTabsView(workspace: workspace, presentation: .docked)
            .frame(width: sidebarWidth)
            .ignoresSafeArea(.all, edges: .top)
            .overlay(alignment: .trailing) {
                sidebarResizeHandle
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
        SidebarTabsView(workspace: workspace, presentation: .floating)
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
    let includeLeadingPadding: Bool

    var body: some View {
        Group {
            if let session = workspace.selectedSession {
                TerminalSceneView(session: session)
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

private struct AppShellBackground: View {
    var body: some View {
        SidebarBackground(presentation: .docked)
    }
}

private enum SidebarPresentation {
    case docked
    case floating
}

private struct SidebarTabsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var terminalSettings = TerminalSettings.shared

    @ObservedObject var workspace: TerminalWorkspace
    let presentation: SidebarPresentation

    var body: some View {
        let palette = SidebarPalette(
            themeColors: terminalSettings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            presentation: presentation
        )

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sessions")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.headerText)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10)

                            ForEach(workspace.sessions) { session in
                                SidebarTabRow(
                                    session: session,
                                    isSelected: workspace.selectedSessionID == session.id,
                                    presentation: presentation,
                                    onSelect: { workspace.select(session) }
                                )
                                .contextMenu {
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
                                }
                            }
                        }
                    }
                }
                // The floating sidebar's outer wrapper adds 3pt leading/top/
                // bottom inset (`floatingSidebarLeadingInset` etc.). The
                // docked sidebar has no such outer wrapper, so without
                // compensation the content sits 3pt up + left of where it
                // sits in floating mode — and the user sees text shift
                // every time the presentation changes.
                .padding(.leading, 8 + dockedCompensation)
                .padding(.trailing, 8 - dockedCompensation)
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

    // Resolves to 3pt for `.docked` and 0 for `.floating`. Keeps the inner
    // content at the same on-screen position across both presentations.
    private static let floatingOuterInset: CGFloat = 3
    private var dockedCompensation: CGFloat {
        presentation == .docked ? Self.floatingOuterInset : 0
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

    private let leftInset: CGFloat = 18
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
            HStack(spacing: 0) {
                Text(session.title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? palette.selectedText : palette.rowText)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 42)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                rowBackground(palette: palette)
            }
        }
        .buttonStyle(.plain)
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

private extension NSColor {
    convenience init?(hexRGB: String) {
        let trimmed = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("#")

        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }

        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
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

    var body: some View {
        TerminalSurfaceView(session: session)
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
