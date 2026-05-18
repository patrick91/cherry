import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

// Set `CHERRY_DEBUG_SIDEBAR_RESIZE=1` in the environment to see the
// terminal-resize diagnostics in stderr / Console.app. Off by default so
// the logs don't pollute normal runs.
private let sidebarResizeDebugEnabled =
    ProcessInfo.processInfo.environment["CHERRY_DEBUG_SIDEBAR_RESIZE"] == "1"

@inline(__always)
private func sidebarResizeLog(_ message: @autoclosure () -> String) {
    guard sidebarResizeDebugEnabled else { return }
    print("[sidebar.resize] \(message())")
}

private final class GhosttyOutputSink: @unchecked Sendable {
    private static let maximumRetainedPendingBytes = 1_048_576
    private static let burstCoalescingDelay: DispatchTimeInterval = .milliseconds(4)
    private static let burstDetectionWindowNanoseconds: UInt64 = 12_000_000

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Cherry.GhosttyOutputSink", qos: .userInitiated)
    private var session: InMemoryTerminalSession
    private var pendingData = Data()
    private var isDrainScheduled = false
    private var lastDrainUptimeNanoseconds: UInt64?

    init(session: InMemoryTerminalSession) {
        self.session = session
    }

    func setSession(_ session: InMemoryTerminalSession) {
        lock.withLock {
            self.session = session
            pendingData.removeAll(keepingCapacity: false)
            lastDrainUptimeNanoseconds = nil
        }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }

        let drainDelay: DispatchTimeInterval? = lock.withLock {
            pendingData.append(data)
            guard !isDrainScheduled else { return nil }
            isDrainScheduled = true
            let now = DispatchTime.now().uptimeNanoseconds
            guard let lastDrainUptimeNanoseconds else { return .never }
            let elapsed = now >= lastDrainUptimeNanoseconds
                ? now - lastDrainUptimeNanoseconds
                : .max
            return elapsed <= Self.burstDetectionWindowNanoseconds
                ? Self.burstCoalescingDelay
                : .never
        }

        switch drainDelay {
        case .none:
            return
        case .some(.never):
            queue.async { [weak self] in
                self?.drainPendingData()
            }
        case let .some(delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.drainPendingData()
            }
        }
    }

    private func drainPendingData() {
        while true {
            let next: (session: InMemoryTerminalSession, data: Data)? = lock.withLock {
                guard !pendingData.isEmpty else {
                    isDrainScheduled = false
                    lastDrainUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                    return nil
                }

                let data = pendingData
                if pendingData.count > Self.maximumRetainedPendingBytes {
                    pendingData = Data()
                } else {
                    pendingData.removeAll(keepingCapacity: true)
                }
                return (session, data)
            }

            guard let next else { return }
            TerminalPerformanceMonitor.recordGhosttyFeedChunk(bytes: next.data.count)
            next.session.receive(next.data)
        }
    }
}

private final class GhosttySessionProxy: @unchecked Sendable {
    private let lock = NSLock()
    private var isHostInputSuppressed = false

    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func send(_ data: Data) {
        let shouldSuppress = lock.withLock {
            isHostInputSuppressed
        }
        guard !shouldSuppress else { return }

        Task { @MainActor [weak self] in
            self?.session?.send(data: data)
        }
    }

    func resize(columns: Int, rows: Int) {
        Task { @MainActor [weak self] in
            self?.session?.resize(columns: columns, rows: rows)
        }
    }

    func withHostInputSuppressed(_ body: () -> Void) {
        lock.withLock {
            isHostInputSuppressed = true
        }
        defer {
            lock.withLock {
                isHostInputSuppressed = false
            }
        }

        body()
    }
}

@MainActor
final class GhosttySessionBridge: NSObject, TerminalSurfaceCloseDelegate, TerminalSurfaceBellDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceScrollbarDelegate, TerminalSurfacePointerDelegate,
    TerminalSurfaceLinkHoverDelegate, TerminalSurfaceHostInputDelegate, TerminalSurfaceScrollInputDelegate
{
    private(set) static var liveBridgeCount = 0
    private(set) static var installedOutputObserverCount = 0

    let terminalView: TerminalView

    private let proxy: GhosttySessionProxy
    private let controller: TerminalController
    private let outputSink: GhosttyOutputSink
    private var inMemorySession: InMemoryTerminalSession
    private var appliedTerminalConfiguration: TerminalConfiguration
    private var appliedTerminalTheme: TerminalTheme
    private var appliedTerminalColorScheme: TerminalColorScheme?
    private var outputObserverID: UUID?
    private var pendingFeedActivation = false
    private var activeColorScheme: ColorScheme?
    private nonisolated(unsafe) var settingsObserver: Any?
    private(set) var gridMetrics: TerminalGridMetrics?
    private(set) var scrollbarMetrics: TerminalScrollbarMetrics?
    private weak var scrollContainer: GhosttyTerminalContainerView?
    private var pointerStyle: TerminalPointerStyle = .text
    private var hoveredLink: String?
    private var isReleased = false

    init(session: TerminalSession) {
        let proxy = GhosttySessionProxy(session: session)
        let inMemorySession = Self.makeInMemorySession(proxy: proxy)
        let terminalConfiguration = TerminalSettings.shared.ghosttyConfiguration()
        let terminalTheme = TerminalSettings.shared.ghosttyTheme()

        self.proxy = proxy
        self.inMemorySession = inMemorySession
        self.outputSink = GhosttyOutputSink(session: inMemorySession)
        self.controller = TerminalController(configuration: terminalConfiguration, theme: terminalTheme)
        self.terminalView = TerminalView(frame: .zero)
        self.appliedTerminalConfiguration = terminalConfiguration
        self.appliedTerminalTheme = terminalTheme

        super.init()

        Self.liveBridgeCount += 1
        terminalView.delegate = self
        terminalView.onPostRender = {
            TerminalPerformanceMonitor.recordRenderTick()
        }
        terminalView.controller = controller
        terminalView.configuration = Self.makeOptions(for: session, inMemorySession: inMemorySession)
        observeSettingsChanges()
    }

    func attach(to container: GhosttyTerminalContainerView) {
        guard !isReleased else { return }
        let isAlreadyInstalled = scrollContainer === container && terminalView.superview != nil
        TerminalPerformanceMonitor.recordBridgeAttach(reused: isAlreadyInstalled)
        scrollContainer = container
        if !isAlreadyInstalled {
            container.install(terminalView: terminalView, bridge: self)
        }
        terminalView.setSurfaceVisible(true)
        if !isAlreadyInstalled {
            TerminalPerformanceMonitor.recordFitToSize()
            terminalView.fitToSize()
        }
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: GhosttyTerminalContainerView) {
        guard !isReleased || scrollContainer === container else { return }
        terminalView.setSurfaceVisible(false)
        container.uninstall(terminalView: terminalView)
        terminalView.removeFromSuperview()
        if scrollContainer === container {
            scrollContainer = nil
        }
    }

    func focus(in window: NSWindow?) {
        guard let window, window.firstResponder !== terminalView else { return }
        window.makeFirstResponder(terminalView)
    }

    func applyTerminalSettings(colorScheme: ColorScheme) {
        activeColorScheme = colorScheme
        applyTerminalSettings()
    }

    func reset() {
        guard !isReleased else { return }
        uninstallOutputObserver()

        let nextSession = Self.makeInMemorySession(proxy: proxy)
        inMemorySession = nextSession
        outputSink.setSession(nextSession)

        if let terminalSession = proxy.session {
            terminalView.configuration = Self.makeOptions(for: terminalSession, inMemorySession: nextSession)
        }
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
        activateOutputFeedWhenSurfaceIsReady()
    }

    func releaseResources() {
        guard !isReleased else { return }
        isReleased = true
        pendingFeedActivation = false
        uninstallOutputObserver()
        uninstallSettingsObserver()
        if let scrollContainer {
            terminalView.setSurfaceVisible(false)
            scrollContainer.uninstall(terminalView: terminalView)
            self.scrollContainer = nil
        } else {
            terminalView.setSurfaceVisible(false)
            terminalView.removeFromSuperview()
        }
        terminalView.delegate = nil
        terminalView.onPostRender = nil
        terminalView.freeSurface()
        terminalView.controller = nil
    }

    func finish(exitCode: UInt32) {
        inMemorySession.finish(exitCode: exitCode, runtimeMilliseconds: 0)
    }

    func terminalDidClose(processAlive _: Bool) {
        proxy.session?.stop()
    }

    func terminalDidRingBell() {
        NSSound.beep()
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        gridMetrics = size
        scrollContainer?.synchronizeScrollState()
    }

    func terminalDidUpdateScrollbar(_ metrics: TerminalScrollbarMetrics) {
        scrollbarMetrics = metrics
        scrollContainer?.synchronizeScrollState()
    }

    func terminalDidChangePointerStyle(_ style: TerminalPointerStyle) {
        pointerStyle = style
        updateTerminalPointerStyle()
    }

    func terminalDidHoverLink(_ url: String?) {
        hoveredLink = url
        updateTerminalPointerStyle()
    }

    func scrollToBottomForHostInput() {
        scrollContainer?.beginHostInputScrollSuppression()
        terminalView.performBindingAction("scroll_to_bottom")
        scrollContainer?.synchronizeScrollState()
    }

    func terminalWillSendHostInput() {
        guard Self.shouldScrollToBottomForHostInput(currentEvent: NSApp.currentEvent) else { return }
        scrollToBottomForHostInput()
    }

    static func shouldScrollToBottomForHostInput(currentEvent event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return true }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return true }
        guard modifiers.isDisjoint(with: [.control, .option]) else { return false }

        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    func terminalShouldSuppressScrollInput(isMomentum: Bool) -> Bool {
        scrollContainer?.shouldSuppressScrollInputForHostInput(isMomentum: isMomentum) ?? false
    }

    deinit {
        MainActor.assumeIsolated {
            releaseResources()
            uninstallSettingsObserver()
            Self.liveBridgeCount -= 1
        }
    }

    private func activateOutputFeedWhenSurfaceIsReady() {
        guard !isReleased, outputObserverID == nil, !pendingFeedActivation else { return }
        pendingFeedActivation = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFeedActivation = false
            guard !self.isReleased else { return }
            self.installOutputObserver()
        }
    }

    private func installOutputObserver() {
        guard !isReleased, outputObserverID == nil, let session = proxy.session else { return }

        let existingOutput = session.rawOutput(maxBytes: 1_048_576).data
        if !existingOutput.isEmpty {
            proxy.withHostInputSuppressed {
                outputSink.receive(existingOutput)
            }
        }

        outputObserverID = session.observeRawOutput(replayExistingOutput: false) { [outputSink] data in
            outputSink.receive(data)
        }
        Self.installedOutputObserverCount += 1
    }

    private func uninstallOutputObserver() {
        guard let outputObserverID else { return }
        proxy.session?.removeRawOutputObserver(id: outputObserverID)
        self.outputObserverID = nil
        Self.installedOutputObserverCount -= 1
    }

    private static func makeInMemorySession(proxy: GhosttySessionProxy) -> InMemoryTerminalSession {
        InMemoryTerminalSession(
            write: { data in
                proxy.send(data)
            },
            resize: { viewport in
                proxy.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )
    }

    private static func makeOptions(
        for session: TerminalSession,
        inMemorySession: InMemoryTerminalSession
    ) -> TerminalSurfaceOptions {
        TerminalSurfaceOptions(
            backend: .inMemory(inMemorySession),
            workingDirectory: session.workingDirectory,
            context: .window
        )
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSettingsDidChange,
            object: TerminalSettings.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTerminalSettings()
            }
        }
    }

    private func uninstallSettingsObserver() {
        guard let settingsObserver else { return }
        NotificationCenter.default.removeObserver(settingsObserver)
        self.settingsObserver = nil
    }

    private func applyTerminalSettings() {
        let settings = TerminalSettings.shared
        let nextConfiguration = settings.ghosttyConfiguration()
        let nextTheme = settings.ghosttyTheme()
        var needsFit = false

        if nextConfiguration != appliedTerminalConfiguration,
           controller.setTerminalConfiguration(nextConfiguration)
        {
            appliedTerminalConfiguration = nextConfiguration
            needsFit = true
        }

        if nextTheme != appliedTerminalTheme,
           controller.setTheme(nextTheme)
        {
            appliedTerminalTheme = nextTheme
        }

        if let activeColorScheme {
            let nextColorScheme = terminalColorScheme(from: activeColorScheme)
            if nextColorScheme != appliedTerminalColorScheme {
                controller.setColorScheme(nextColorScheme)
                appliedTerminalColorScheme = nextColorScheme
            }
        }

        if needsFit {
            TerminalPerformanceMonitor.recordFitToSize()
            terminalView.fitToSize()
        }
        TerminalPerformanceMonitor.recordSettingsApply(reconfigured: needsFit)
    }

    private func updateTerminalPointerStyle() {
        scrollContainer?.setTerminalPointerStyle(hoveredLink == nil ? pointerStyle : .pointingHand)
    }

    private func terminalColorScheme(from colorScheme: ColorScheme) -> TerminalColorScheme {
        switch colorScheme {
        case .dark: .dark
        case .light: .light
        @unknown default: .dark
        }
    }
}

@MainActor
final class GhosttyTerminalContainerView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private weak var activeSession: TerminalSession?
    private weak var activeBridge: GhosttySessionBridge?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var keyEventMonitor: Any?
    private var isLiveScrolling = false
    private var lastSentScrollRow: Int?
    private var allowsAutoFocus = true
    private var pendingTerminalFocus = false
    private var isSidebarAnimating = false
    private var isSyncFrozen = false
    private var snapshotLayer: CALayer?
    private var activeColorScheme: ColorScheme = .dark
    private var pendingPostAnimationDelta: CGFloat = 0
    private var didApplyEarlyFit = false
    private var shouldSuppressMomentumScrollAfterHostInput = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureScrollView()
        installKeyEventMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            detachActiveSession()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let keyEventMonitor {
                NSEvent.removeMonitor(keyEventMonitor)
            }
        }
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    func configure(
        with session: TerminalSession,
        colorScheme: ColorScheme,
        allowsAutoFocus: Bool = true
    ) {
        TerminalPerformanceMonitor.recordContainerConfigure()
        self.allowsAutoFocus = allowsAutoFocus
        if !allowsAutoFocus {
            pendingTerminalFocus = false
        }

        if activeSession !== session {
            activeSession?.releaseGhosttyBridge()
            activeSession = session
            session.ghosttyBridge.attach(to: self)
            requestTerminalFocus()
        } else {
            session.ghosttyBridge.attach(to: self)
        }

        activeColorScheme = colorScheme
        applyDocumentBackgroundColor(for: colorScheme)
        session.ghosttyBridge.applyTerminalSettings(colorScheme: colorScheme)
    }

    func applySidebarAnimationState(
        isAnimating: Bool,
        postAnimationDeltaWidth: CGFloat
    ) {
        let wasAnimating = isSidebarAnimating
        isSidebarAnimating = isAnimating
        pendingPostAnimationDelta = postAnimationDeltaWidth

        if !wasAnimating, isAnimating {
            sidebarResizeLog(
                "begin animation delta=\(postAnimationDeltaWidth) " +
                "scrollView.contentSize=\(scrollView.contentSize) bounds=\(bounds.size)"
            )
            beginSidebarAnimation()
        } else if wasAnimating, !isAnimating {
            sidebarResizeLog(
                "end animation didEarlyFit=\(didApplyEarlyFit) " +
                "scrollView.contentSize=\(scrollView.contentSize) " +
                "terminalView.frame=\(activeBridge?.terminalView.frame ?? .zero)"
            )
            endSidebarAnimation()
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        // We deliberately *do not* call `bridge.attach(to: self)` here.
        // `attach` calls `terminalView.fitToSize()` unconditionally, which
        // would re-issue a Metal surface reconfigure on every layout pass —
        // including the final post-animation one — undoing the work the
        // freeze + early-fit are doing. Attachment is already handled in
        // `configure(with:colorScheme:)` (session changes) and
        // `viewDidMoveToWindow` (window changes), which is sufficient.
        synchronizeScrollState()

        updateSnapshotLayerFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detachActiveSession(clearsSession: false)
        } else {
            activeSession?.ghosttyBridge.attach(to: self)
            requestTerminalFocus()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            activeSession?.ghosttyBridge.focus(in: window)
        }
        super.mouseDown(with: event)
    }

    func install(terminalView: TerminalView, bridge: GhosttySessionBridge) {
        activeBridge = bridge
        if terminalView.superview !== documentView {
            terminalView.removeFromSuperview()
            terminalView.autoresizingMask = []
            documentView.addSubview(terminalView)
        }

        synchronizeScrollState()
    }

    func uninstall(terminalView: TerminalView) {
        guard terminalView.superview === documentView else { return }
        terminalView.removeFromSuperview()
        if activeBridge?.terminalView === terminalView {
            activeBridge = nil
        }
    }

    func detachActiveSession(clearsSession: Bool = true, releasesBridge: Bool = true) {
        guard let session = activeSession else {
            activeBridge = nil
            return
        }

        session.detachGhosttyBridge(from: self)
        if releasesBridge {
            session.releaseGhosttyBridge()
        }
        if clearsSession {
            activeSession = nil
        }
        activeBridge = nil
        pendingTerminalFocus = false
        removeSnapshotLayer(animated: false)
    }

    func synchronizeScrollState() {
        guard let terminalView = activeBridge?.terminalView else { return }

        documentView.frame.size.width = max(scrollView.contentSize.width, 1)
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling, let scrollbar = activeBridge?.scrollbarMetrics {
            let offsetY = scrollOffsetY(for: scrollbar)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedScrollOffset(offsetY)))
            lastSentScrollRow = Int(scrollbar.offset)
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)

        // `synchronizeTerminalFrame` is the only path that calls
        // `fitToSize`. While the sidebar is animating we want exactly zero
        // re-fits — otherwise the terminal reflows on every scroll-bounds
        // change and the prompt visibly walks up/down under the snapshot.
        if !isSyncFrozen {
            synchronizeTerminalFrame(terminalView)
        }
    }

    func setTerminalPointerStyle(_ style: TerminalPointerStyle) {
        let cursor = style.nsCursor
        scrollView.documentCursor = cursor
        cursor.set()
    }

    func beginHostInputScrollSuppression() {
        shouldSuppressMomentumScrollAfterHostInput = true
    }

    func shouldSuppressScrollInputForHostInput(isMomentum: Bool) -> Bool {
        guard shouldSuppressMomentumScrollAfterHostInput else { return false }
        guard isMomentum else {
            shouldSuppressMomentumScrollAfterHostInput = false
            return false
        }
        return true
    }

    private func beginSidebarAnimation() {
        didApplyEarlyFit = false
        captureSnapshotIfPossible()
        isSyncFrozen = true
        // Resize the live terminal to its post-animation width *now*, while
        // the just-placed (fully opaque) snapshot is hiding the surface.
        // The Metal reconfigure flash that Ghostty emits when the surface
        // size changes happens here — under cover — so when the snapshot
        // eventually fades there's no pending fit and no flash to reveal.
        applyEarlyFitIfPossible()
    }

    private func endSidebarAnimation() {
        let wasFrozen = isSyncFrozen
        isSyncFrozen = false

        if wasFrozen, !didApplyEarlyFit {
            // Couldn't pre-fit (e.g. zero delta or no bridge yet) — fall
            // back to a single end-of-animation sync.
            synchronizeScrollState()
        } else if wasFrozen {
            // Pre-fit already brought the terminal to target. Just settle
            // the document-view metrics + scroll offset.
            updateDocumentViewMetrics()
        }

        // Hand a runloop tick to Core Animation / Metal so the live
        // surface is fully painted behind the snapshot before opacity
        // starts dropping.
        DispatchQueue.main.async { [weak self] in
            self?.crossfadeOutSnapshotLayer()
        }

        didApplyEarlyFit = false
    }

    private func applyEarlyFitIfPossible() {
        guard let terminalView = activeBridge?.terminalView,
              pendingPostAnimationDelta != 0 else {
            sidebarResizeLog("applyEarlyFit skipped (no bridge or zero delta)")
            return
        }

        let currentContentSize = scrollView.contentSize
        guard currentContentSize.width > 0, currentContentSize.height > 0 else {
            sidebarResizeLog("applyEarlyFit skipped (zero content size)")
            return
        }

        let targetWidth = max(100, currentContentSize.width + pendingPostAnimationDelta)
        let targetSize = CGSize(width: targetWidth, height: currentContentSize.height)

        sidebarResizeLog(
            "applyEarlyFit current=\(currentContentSize) delta=\(pendingPostAnimationDelta) " +
            "target=\(targetSize)"
        )

        // Pre-grow the document view too so the surface has somewhere to
        // live when the target is wider than the current scroll-view
        // contents (the closing case). Without this the terminal's frame
        // would extend past the document view and the right edge would be
        // briefly clipped at the wrong width.
        documentView.frame.size.width = max(documentView.frame.size.width, targetWidth)

        terminalView.frame = NSRect(origin: .zero, size: targetSize)
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
        didApplyEarlyFit = true
    }

    private func updateDocumentViewMetrics() {
        documentView.frame.size.width = max(scrollView.contentSize.width, 1)
        documentView.frame.size.height = documentHeight()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func captureSnapshotIfPossible() {
        // Best-effort screenshot of the live terminal area. Tries the
        // window-list compositor first (captures Metal contents), then falls
        // back to AppKit's `cacheDisplay` which won't capture the GPU surface
        // but still provides the surrounding chrome. If both fail we just
        // proceed without a snapshot — the freeze still suppresses the
        // flicker, the cross-fade just becomes a no-op.
        guard scrollView.frame.width > 0,
              scrollView.frame.height > 0 else { return }

        let captureRect = scrollView.frame
        let cgImage = captureWindowSnapshot(of: scrollView, rect: captureRect)
            ?? captureViewBitmap(scrollView, rect: scrollView.bounds)

        guard let cgImage else { return }

        snapshotLayer?.removeFromSuperlayer()

        wantsLayer = true
        let layer = CALayer()
        layer.contents = cgImage
        // Anchor the captured pixels at the layer's top-left without any
        // scaling. The live terminal underneath is left-aligned in the
        // scroll view, so an unscaled top-left snapshot tracks it
        // pixel-for-pixel — otherwise (e.g. with `.resizeAspectFill`) the
        // image would scale/crop from the center and snap visibly when the
        // cross-fade reveals the live content.
        layer.contentsGravity = .topLeft
        layer.masksToBounds = true
        // Ghostty's metal layer renders text on a *clear* background, so the
        // captured CGImage has alpha holes wherever the terminal background
        // would normally show. Without a layer background color, those
        // holes (and the area beyond the image when the layer grows on a
        // close) reveal the live terminal underneath — and the brief Metal
        // reconfigure flash from the end-of-animation `fitToSize` is
        // visible through them. Painting the layer with the active terminal
        // background color closes every hole so the snapshot is fully
        // opaque end-to-end.
        layer.backgroundColor = terminalBackgroundCGColor()
        layer.frame = captureRect
        layer.zPosition = 1_000
        // Disable implicit animations on layout-driven property changes so
        // the snapshot's frame interpolates with SwiftUI's animation curve
        // (driven from `layout()`) rather than running on Core Animation's
        // separate clock and visibly desyncing.
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        if let scale = window?.backingScaleFactor {
            layer.contentsScale = scale
        }
        self.layer?.addSublayer(layer)
        snapshotLayer = layer
    }

    private func terminalBackgroundCGColor() -> CGColor {
        let themeColors = TerminalSettings.shared.ghosttyThemeColors(for: activeColorScheme)
        let resolved = NSColor(hexRGB: themeColors.background)
            ?? (activeColorScheme == .light ? NSColor.white : NSColor.black)
        return resolved.cgColor
    }

    private func captureWindowSnapshot(of view: NSView, rect: NSRect) -> CGImage? {
        guard let window = view.window,
              window.windowNumber > 0 else { return nil }

        let viewRectInWindow = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(viewRectInWindow)

        // CGWindowListCreateImage takes screen coords with a top-left origin.
        // AppKit screen coords have a bottom-left origin from the primary
        // display, so flip the Y.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = CGRect(
            x: screenRect.origin.x,
            y: primary.frame.maxY - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )

        return CGWindowListCreateImage(
            flipped,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    private func captureViewBitmap(_ view: NSView, rect: NSRect) -> CGImage? {
        guard rect.width > 0, rect.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap.cgImage
    }

    private func crossfadeOutSnapshotLayer() {
        guard let snapshotLayer else {
            removeSnapshotLayer(animated: false)
            return
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = snapshotLayer.opacity
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.snapshotLayer?.removeFromSuperlayer()
            self?.snapshotLayer = nil
        }
        snapshotLayer.opacity = 0
        snapshotLayer.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    private func removeSnapshotLayer(animated: Bool) {
        guard let snapshotLayer else { return }
        if animated {
            crossfadeOutSnapshotLayer()
        } else {
            snapshotLayer.removeFromSuperlayer()
            self.snapshotLayer = nil
        }
    }

    private func updateSnapshotLayerFrame() {
        guard let snapshotLayer else { return }
        // Track the current visible area so the snapshot stays aligned with
        // the underlying scroll view as the container resizes during the
        // animation. Disable implicit layer animations or the snapshot will
        // animate independently from SwiftUI's frame interpolation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.frame = scrollView.frame
        CATransaction.commit()
    }

    // Painting the document background with the active terminal theme color
    // means that when the deferred strategy freezes the live terminal at its
    // pre-animation size, any newly exposed area on the right (sidebar
    // closing) reads as terminal background instead of bleeding through to
    // the scene's gradient.
    private func applyDocumentBackgroundColor(for colorScheme: ColorScheme) {
        let themeColors = TerminalSettings.shared.ghosttyThemeColors(for: colorScheme)
        let resolved = NSColor(hexRGB: themeColors.background)
            ?? (colorScheme == .light ? NSColor.white : NSColor.black)

        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = resolved.cgColor
    }

    private func configureScrollView() {
        // Ghostty's macOS app wraps the renderer in an NSScrollView instead of
        // relying on wheel events alone. The document view mirrors Ghostty's
        // scrollback metrics, which gives us native overlay scrollbars and lets
        // scrollbar drags send `scroll_to_row` back into the core.
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.clipsToBounds = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView

        addSubview(scrollView)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScrollBoundsChange()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveScrolling = true
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveScrolling = false
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleLiveScroll()
            }
        })
    }

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated {
                self.handleLocalKeyDown(event)
            }
            return handled ? nil : event
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window,
              let activeSession,
              activeSession.acceptsInput,
              window?.firstResponder === activeBridge?.terminalView
        else {
            return false
        }

        if isPasteShortcut(event),
           let pasteData = TerminalPasteboardContent.nonTextPasteData(from: .general) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: pasteData)
            return true
        }

        if let sequence = TerminalInputEncoder.shiftEnterSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isEnhancedKeyboardProtocolActive: activeSession.isEnhancedKeyboardProtocolActive
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: sequence)
            return true
        }

        if let sequence = TerminalInputEncoder.shiftTabSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isEnhancedKeyboardProtocolActive: activeSession.isEnhancedKeyboardProtocolActive
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: sequence)
            return true
        }

        if let sequence = TerminalInputEncoder.appKitOptionBackspaceSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: sequence)
            return true
        }

        if let sequence = TerminalInputEncoder.appKitOptionArrowSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            sendsModifiedArrowKeys: activeSession.usesAlternateScreen ||
                activeSession.isEnhancedKeyboardProtocolActive
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: sequence)
            return true
        }

        if let sequence = TerminalInputEncoder.appKitUnmodifiedArrowSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            usesApplicationCursorKeys: activeSession.usesApplicationCursorKeys
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: sequence)
            return true
        }

        return false
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return false
        }

        return true
    }

    private func requestTerminalFocus() {
        guard allowsAutoFocus else { return }
        guard !pendingTerminalFocus else { return }
        pendingTerminalFocus = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTerminalFocus = false
            guard self.allowsAutoFocus else { return }
            guard let window = self.window else { return }
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            self.activeSession?.ghosttyBridge.focus(in: window)
        }
    }

    private func handleScrollBoundsChange() {
        guard !isSyncFrozen,
              let terminalView = activeBridge?.terminalView else { return }
        synchronizeTerminalFrame(terminalView)
    }

    private func handleLiveScroll() {
        guard isLiveScrolling,
              let bridge = activeBridge,
              let cellHeight = terminalCellHeight,
              cellHeight > 0
        else {
            return
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let scrollOffset = documentView.frame.height - visibleRect.origin.y - visibleRect.height
        let row = max(0, Int(scrollOffset / cellHeight))
        guard row != lastSentScrollRow else { return }

        lastSentScrollRow = row
        bridge.terminalView.performBindingAction("scroll_to_row:\(row)")
    }

    private func synchronizeTerminalFrame(_ terminalView: TerminalView) {
        let visibleRect = scrollView.contentView.documentVisibleRect
        let targetFrame = NSRect(
            origin: visibleRect.origin,
            size: CGSize(width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        )
        // Skip when the terminal is essentially at the target size. The
        // tolerance covers SwiftUI's sub-pixel layout rounding around the
        // padding swap — observed deltas of ~0.7pt between our predicted
        // post-animation width and the value scrollView actually settles
        // on. A full point of tolerance is still well below one terminal
        // cell (~9pt at the default font), so this never papers over a
        // user-visible mis-size.
        let widthDelta = abs(terminalView.frame.size.width - targetFrame.size.width)
        let heightDelta = abs(terminalView.frame.size.height - targetFrame.size.height)
        let originDelta = max(
            abs(terminalView.frame.origin.x - targetFrame.origin.x),
            abs(terminalView.frame.origin.y - targetFrame.origin.y)
        )
        guard widthDelta > 1.0 || heightDelta > 1.0 || originDelta > 1.0 else { return }

        sidebarResizeLog("synchronizeTerminalFrame -> \(targetFrame.size)")
        terminalView.frame = targetFrame
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        guard let scrollbar = activeBridge?.scrollbarMetrics,
              let cellHeight = terminalCellHeight,
              cellHeight > 0
        else {
            return contentHeight
        }

        let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
        let padding = contentHeight - (CGFloat(scrollbar.length) * cellHeight)
        return max(contentHeight, documentGridHeight + padding)
    }

    private func scrollOffsetY(for scrollbar: TerminalScrollbarMetrics) -> CGFloat {
        guard let cellHeight = terminalCellHeight else { return 0 }
        let rowsFromBottom = max(
            0,
            Double(scrollbar.total) - Double(scrollbar.offset) - Double(scrollbar.length)
        )
        return CGFloat(rowsFromBottom) * cellHeight
    }

    private func clampedScrollOffset(_ offsetY: CGFloat) -> CGFloat {
        let maximumOffset = max(0, documentView.frame.height - scrollView.contentSize.height)
        return min(max(offsetY, 0), maximumOffset)
    }

    private var terminalCellHeight: CGFloat? {
        guard let metrics = activeBridge?.gridMetrics,
              metrics.cellHeightPixels > 0
        else {
            return nil
        }

        let scale = activeBridge?.terminalView.window?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return CGFloat(metrics.cellHeightPixels) / scale
    }
}

private extension TerminalPointerStyle {
    var nsCursor: NSCursor {
        switch self {
        case .arrow:
            .arrow
        case .text:
            .iBeam
        case .verticalText:
            .iBeamCursorForVerticalLayout
        case .pointingHand:
            .pointingHand
        case .openHand:
            .openHand
        case .closedHand:
            .closedHand
        case .resizeLeft:
            if #available(macOS 15.0, *) {
                .columnResize(directions: .left)
            } else {
                .resizeLeft
            }
        case .resizeRight:
            if #available(macOS 15.0, *) {
                .columnResize(directions: .right)
            } else {
                .resizeRight
            }
        case .resizeUp:
            if #available(macOS 15.0, *) {
                .rowResize(directions: .up)
            } else {
                .resizeUp
            }
        case .resizeDown:
            if #available(macOS 15.0, *) {
                .rowResize(directions: .down)
            } else {
                .resizeDown
            }
        case .resizeUpDown:
            if #available(macOS 15.0, *) {
                .rowResize
            } else {
                .resizeUpDown
            }
        case .resizeLeftRight:
            if #available(macOS 15.0, *) {
                .columnResize
            } else {
                .resizeLeftRight
            }
        case .contextualMenu:
            .contextualMenu
        case .crosshair:
            .crosshair
        case .operationNotAllowed:
            .operationNotAllowed
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
