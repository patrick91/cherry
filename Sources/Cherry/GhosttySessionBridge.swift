import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI

private final class GhosttyOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var session: InMemoryTerminalSession

    init(session: InMemoryTerminalSession) {
        self.session = session
    }

    func setSession(_ session: InMemoryTerminalSession) {
        lock.withLock {
            self.session = session
        }
    }

    func receive(_ data: Data) {
        let session = lock.withLock {
            self.session
        }
        session.receive(data)
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
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceScrollbarDelegate
{
    let terminalView: TerminalView

    private let proxy: GhosttySessionProxy
    private let controller: TerminalController
    private let outputSink: GhosttyOutputSink
    private var inMemorySession: InMemoryTerminalSession
    private var outputObserverID: UUID?
    private var pendingFeedActivation = false
    private var activeColorScheme: ColorScheme?
    private nonisolated(unsafe) var settingsObserver: Any?
    private(set) var gridMetrics: TerminalGridMetrics?
    private(set) var scrollbarMetrics: TerminalScrollbarMetrics?
    private weak var scrollContainer: GhosttyTerminalContainerView?

    init(session: TerminalSession) {
        let proxy = GhosttySessionProxy(session: session)
        let inMemorySession = Self.makeInMemorySession(proxy: proxy)

        self.proxy = proxy
        self.inMemorySession = inMemorySession
        self.outputSink = GhosttyOutputSink(session: inMemorySession)
        self.controller = Self.makeController()
        self.terminalView = TerminalView(frame: .zero)

        super.init()

        terminalView.delegate = self
        terminalView.controller = controller
        terminalView.configuration = Self.makeOptions(for: session, inMemorySession: inMemorySession)
        observeSettingsChanges()
    }

    func attach(to container: GhosttyTerminalContainerView) {
        scrollContainer = container
        container.install(terminalView: terminalView, bridge: self)
        terminalView.setSurfaceVisible(true)
        terminalView.fitToSize()
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: GhosttyTerminalContainerView) {
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
        uninstallOutputObserver()

        let nextSession = Self.makeInMemorySession(proxy: proxy)
        inMemorySession = nextSession
        outputSink.setSession(nextSession)

        if let terminalSession = proxy.session {
            terminalView.configuration = Self.makeOptions(for: terminalSession, inMemorySession: nextSession)
        }
        terminalView.fitToSize()
        activateOutputFeedWhenSurfaceIsReady()
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

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func activateOutputFeedWhenSurfaceIsReady() {
        guard outputObserverID == nil, !pendingFeedActivation else { return }
        pendingFeedActivation = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFeedActivation = false
            self.installOutputObserver()
        }
    }

    private func installOutputObserver() {
        guard outputObserverID == nil, let session = proxy.session else { return }

        let existingOutput = session.rawOutput(maxBytes: 1_048_576).data
        if !existingOutput.isEmpty {
            proxy.withHostInputSuppressed {
                outputSink.receive(existingOutput)
            }
        }

        outputObserverID = session.observeRawOutput(replayExistingOutput: false) { [outputSink] data in
            outputSink.receive(data)
        }
    }

    private func uninstallOutputObserver() {
        guard let outputObserverID, let session = proxy.session else {
            self.outputObserverID = nil
            return
        }

        session.removeRawOutputObserver(id: outputObserverID)
        self.outputObserverID = nil
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

    private static func makeController() -> TerminalController {
        return TerminalController(
            configuration: TerminalSettings.shared.ghosttyConfiguration(),
            theme: TerminalSettings.shared.ghosttyTheme()
        )
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .terminalSettingsDidChange,
            object: TerminalSettings.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyTerminalSettings()
            }
        }
    }

    private func applyTerminalSettings() {
        controller.setTerminalConfiguration(TerminalSettings.shared.ghosttyConfiguration())
        controller.setTheme(TerminalSettings.shared.ghosttyTheme())
        if let activeColorScheme {
            controller.setColorScheme(terminalColorScheme(from: activeColorScheme))
        }
        terminalView.fitToSize()
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
    private var isLiveScrolling = false
    private var lastSentScrollRow: Int?
    private var pendingTerminalFocus = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureScrollView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    func configure(with session: TerminalSession, colorScheme: ColorScheme) {
        if activeSession !== session {
            activeSession?.ghosttyBridge.detach(from: self)
            activeSession = session
            session.ghosttyBridge.attach(to: self)
            requestTerminalFocus()
        } else {
            session.ghosttyBridge.attach(to: self)
        }

        session.ghosttyBridge.applyTerminalSettings(colorScheme: colorScheme)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        activeSession?.ghosttyBridge.attach(to: self)
        synchronizeScrollState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activeSession?.ghosttyBridge.attach(to: self)
        requestTerminalFocus()
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
        synchronizeTerminalFrame(terminalView)
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
            Task { @MainActor [weak self] in
                self?.handleScrollBoundsChange()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = true
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = false
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLiveScroll()
            }
        })
    }

    private func requestTerminalFocus() {
        guard !pendingTerminalFocus else { return }
        pendingTerminalFocus = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTerminalFocus = false
            guard let window = self.window else { return }
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            self.activeSession?.ghosttyBridge.focus(in: window)
        }
    }

    private func handleScrollBoundsChange() {
        guard let terminalView = activeBridge?.terminalView else { return }
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
        terminalView.frame = NSRect(
            origin: visibleRect.origin,
            size: CGSize(width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        )
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
