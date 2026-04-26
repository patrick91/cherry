import AppKit
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
    @AppStorage("sidebar.width") private var storedSidebarWidth: Double = 320
    @State private var isSidebarRevealed = false

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
            HStack(spacing: 0) {
                if !isSidebarHidden {
                    dockedSidebar
                }

                DetailPaneView(workspace: workspace, includeLeadingPadding: isSidebarHidden)
                    .ignoresSafeArea(.all, edges: .top)
            }

            if isSidebarHidden {
                floatingSidebar
                    .offset(x: isSidebarRevealed ? 0 : -(sidebarWidth + floatingSidebarLeadingInset))
                    .opacity(isSidebarRevealed ? 1 : 0)
                    .allowsHitTesting(isSidebarRevealed)

                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14)
                    .ignoresSafeArea(.all, edges: .vertical)
                    .onHover { hovering in
                        if hovering {
                            isSidebarRevealed = true
                        }
                    }
            }

            NativeWindowControlsOverlay(
                isVisible: !isSidebarHidden || isSidebarRevealed,
                sidebarWidth: sidebarWidth,
                leadingOffset: isSidebarHidden ? floatingSidebarLeadingInset : 0,
                topOffset: isSidebarHidden ? floatingSidebarTopInset : 0
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all, edges: .top)
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(AppShellBackground())
        .background(AppShortcutMonitor(workspace: workspace, openSettings: { openSettings() }))
        .background(WindowConfigurator())
        .frame(minWidth: 320, minHeight: 460)
        .animation(.snappy(duration: 0.18), value: isSidebarHidden)
        .animation(.snappy(duration: 0.16), value: isSidebarRevealed)
        .onChange(of: isSidebarHidden) { _, hidden in
            if !hidden {
                isSidebarRevealed = false
            }
        }
        .onAppear {
            storedSidebarWidth = Double(sidebarWidth)
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
                if !hovering {
                    isSidebarRevealed = false
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
        window.backgroundColor = NSColor(calibratedWhite: 0.82, alpha: 1)
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
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        .padding(.top, 5)
        .padding(.leading, includeLeadingPadding ? 5 : 0)
        .padding(.trailing, 5)
        .padding(.bottom, 5)
        .background(AppShellBackground())
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
                .padding(.horizontal, 8)
                .padding(.top, 48)
                .padding(.bottom, 10)
            }
        }
        .background {
            SidebarBackground(presentation: presentation)
        }
    }
}

private struct NativeWindowControlsOverlay: NSViewRepresentable {
    let isVisible: Bool
    let sidebarWidth: CGFloat
    let leadingOffset: CGFloat
    let topOffset: CGFloat

    func makeNSView(context: Context) -> NativeWindowControlsOverlayView {
        let view = NativeWindowControlsOverlayView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NativeWindowControlsOverlayView, context: Context) {
        nsView.isControlsVisible = isVisible
        nsView.sidebarWidth = sidebarWidth
        nsView.leadingOffset = leadingOffset
        nsView.topOffset = topOffset
        DispatchQueue.main.async {
            nsView.attachWindowButtons()
            nsView.updateControlsPosition(animated: true)
        }
    }

    static func dismantleNSView(_ nsView: NativeWindowControlsOverlayView, coordinator: ()) {
        nsView.restoreWindowButtons()
    }
}

private final class NativeWindowControlsOverlayView: NSView {
    var isControlsVisible = true
    var sidebarWidth: CGFloat = 320
    var leadingOffset: CGFloat = 0
    var topOffset: CGFloat = 0

    private let leftInset: CGFloat = 18
    private let topInset: CGFloat = 18
    private let buttonSpacing: CGFloat = 20
    private weak var originalSuperview: NSView?
    private var hostedButtons: [NSButton] = []
    private var didAttachButtons = false
    private var lastButtonOrigins: [NSPoint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowButtons()
        updateControlsPosition(animated: false)
    }

    override func layout() {
        super.layout()
        updateControlsPosition(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @MainActor
    func attachWindowButtons() {
        guard let window else { return }

        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        guard buttons.count == 3 else { return }

        if originalSuperview == nil {
            originalSuperview = buttons.first?.superview
        }

        hostedButtons = buttons

        for button in buttons {
            button.autoresizingMask = []
            button.isHidden = false
        }

        didAttachButtons = true
    }

    @MainActor
    func restoreWindowButtons() {
        hostedButtons = []
        didAttachButtons = false
        lastButtonOrigins = []
    }

    @MainActor
    func updateControlsPosition(animated: Bool) {
        guard didAttachButtons, let originalSuperview else { return }

        let visibleX = leadingOffset + leftInset
        let controlWidth = buttonSpacing * CGFloat(max(hostedButtons.count - 1, 0)) + (hostedButtons.last?.frame.width ?? 14)
        let controlHeight = hostedButtons.map(\.frame.height).max() ?? 14
        let hiddenX = visibleX - max(sidebarWidth + leadingOffset, controlWidth + visibleX)
        let targetX = isControlsVisible ? visibleX : hiddenX
        let targetY = bounds.height - topOffset - topInset - controlHeight
        let targetRect = convert(
            NSRect(
                x: targetX,
                y: max(0, targetY),
                width: controlWidth,
                height: controlHeight
            ),
            to: originalSuperview
        )
        let targetOrigins = hostedButtons.enumerated().map { index, button in
            NSPoint(
                x: targetRect.minX + CGFloat(index) * buttonSpacing,
                y: targetRect.minY + (controlHeight - button.frame.height) / 2
            )
        }

        let shouldAnimate = animated && !lastButtonOrigins.isEmpty && lastButtonOrigins != targetOrigins
        lastButtonOrigins = targetOrigins

        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (button, origin) in zip(hostedButtons, targetOrigins) {
                    button.animator().setFrameOrigin(origin)
                }
            }
        } else {
            for (button, origin) in zip(hostedButtons, targetOrigins) {
                button.setFrameOrigin(origin)
            }
        }
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
        let foreground = Color(nsColor: sample.foreground)
        let selection = sample.selectionBackground.map { Color(nsColor: $0) }

        if sample.isDark {
            self = Self(
                backgroundMaterial: presentation == .floating
                    ? AnyShapeStyle(.thinMaterial)
                    : AnyShapeStyle(.ultraThinMaterial),
                backgroundTint: background.opacity(presentation == .floating ? 0.84 : 0.68),
                backgroundOverlay: [
                    foreground.opacity(presentation == .floating ? 0.05 : 0.08),
                    background.opacity(0.18)
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
                    ? AnyShapeStyle(.regularMaterial)
                    : AnyShapeStyle(.ultraThinMaterial),
                backgroundTint: background.opacity(presentation == .floating ? 0.76 : 0.48),
                backgroundOverlay: [
                    Color.white.opacity(presentation == .floating ? 0.14 : 0.24),
                    foreground.opacity(0.03)
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
