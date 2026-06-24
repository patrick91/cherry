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

final class GhosttyOutputSink: @unchecked Sendable {
    private static let maximumRetainedPendingBytes = 1_048_576
    private static let defaultBurstCoalescingDelay: DispatchTimeInterval = .milliseconds(80)
    private static let defaultBurstDetectionWindowNanoseconds: UInt64 = 160_000_000
    private static let defaultInputLatencyBypassWindowNanoseconds: UInt64 = 180_000_000

    private struct PendingChunk {
        var data: Data
        let suppressHostInput: Bool
        var containsOverwrittenProgressFrameMarker: Bool
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Cherry.GhosttyOutputSink", qos: .userInitiated)
    private let receiveData: (InMemoryTerminalSession?, Data) -> Void
    private let hostInputSuppressor: (@escaping () -> Void) -> Void
    private let burstCoalescingDelay: DispatchTimeInterval
    private let burstDetectionWindowNanoseconds: UInt64
    private let inputLatencyBypassWindowNanoseconds: UInt64
    private var session: InMemoryTerminalSession?
    private var pendingChunks: [PendingChunk] = []
    private var pendingByteCount = 0
    private var isDrainScheduled = false
    private var lastDrainUptimeNanoseconds: UInt64?
    private var lastHostInputUptimeNanoseconds: UInt64?

    init(
        session: InMemoryTerminalSession,
        hostInputSuppressor: @escaping (@escaping () -> Void) -> Void = { operation in operation() },
        burstCoalescingDelay: DispatchTimeInterval = GhosttyOutputSink.defaultBurstCoalescingDelay,
        burstDetectionWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultBurstDetectionWindowNanoseconds,
        inputLatencyBypassWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultInputLatencyBypassWindowNanoseconds
    ) {
        self.session = session
        self.hostInputSuppressor = hostInputSuppressor
        self.burstCoalescingDelay = burstCoalescingDelay
        self.burstDetectionWindowNanoseconds = burstDetectionWindowNanoseconds
        self.inputLatencyBypassWindowNanoseconds = inputLatencyBypassWindowNanoseconds
        self.receiveData = { session, data in
            session?.receive(data)
        }
    }

    init(
        receiveForTesting: @escaping (Data) -> Void,
        hostInputSuppressor: @escaping (@escaping () -> Void) -> Void = { operation in operation() },
        burstCoalescingDelay: DispatchTimeInterval = GhosttyOutputSink.defaultBurstCoalescingDelay,
        burstDetectionWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultBurstDetectionWindowNanoseconds,
        inputLatencyBypassWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultInputLatencyBypassWindowNanoseconds
    ) {
        self.session = nil
        self.hostInputSuppressor = hostInputSuppressor
        self.burstCoalescingDelay = burstCoalescingDelay
        self.burstDetectionWindowNanoseconds = burstDetectionWindowNanoseconds
        self.inputLatencyBypassWindowNanoseconds = inputLatencyBypassWindowNanoseconds
        self.receiveData = { _, data in
            receiveForTesting(data)
        }
    }

    func setSession(_ session: InMemoryTerminalSession) {
        lock.withLock {
            self.session = session
            pendingChunks.removeAll(keepingCapacity: false)
            pendingByteCount = 0
            lastDrainUptimeNanoseconds = nil
            lastHostInputUptimeNanoseconds = nil
        }
    }

    func discardPending() {
        lock.withLock {
            pendingChunks.removeAll(keepingCapacity: false)
            pendingByteCount = 0
            lastDrainUptimeNanoseconds = nil
            lastHostInputUptimeNanoseconds = nil
        }
    }

    func noteHostInput() {
        lock.withLock {
            lastHostInputUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
    }

    func receive(_ data: Data, suppressHostInput: Bool = false) {
        guard !data.isEmpty else { return }

        let containsOverwrittenProgressFrameMarker =
            GhosttySessionBridge.containsOverwrittenProgressFrameMarker(data)
        let drainDelay: DispatchTimeInterval? = lock.withLock {
            if pendingByteCount + data.count > Self.maximumRetainedPendingBytes {
                pendingChunks.removeAll(keepingCapacity: true)
                pendingByteCount = 0
            }
            if let lastIndex = pendingChunks.indices.last,
               pendingChunks[lastIndex].suppressHostInput == suppressHostInput
            {
                pendingChunks[lastIndex].data.append(data)
                pendingChunks[lastIndex].containsOverwrittenProgressFrameMarker =
                    pendingChunks[lastIndex].containsOverwrittenProgressFrameMarker ||
                    containsOverwrittenProgressFrameMarker
            } else {
                pendingChunks.append(PendingChunk(
                    data: data,
                    suppressHostInput: suppressHostInput,
                    containsOverwrittenProgressFrameMarker: containsOverwrittenProgressFrameMarker
                ))
            }
            pendingByteCount += data.count
            let now = DispatchTime.now().uptimeNanoseconds
            let isRecentHostInput = if let lastHostInputUptimeNanoseconds {
                now >= lastHostInputUptimeNanoseconds &&
                    now - lastHostInputUptimeNanoseconds <= inputLatencyBypassWindowNanoseconds
            } else {
                false
            }
            let shouldDelayForCoalescing = containsOverwrittenProgressFrameMarker && !isRecentHostInput
            guard !isDrainScheduled else {
                return shouldDelayForCoalescing ? nil : .never
            }

            isDrainScheduled = true
            guard shouldDelayForCoalescing else { return .never }
            guard let lastDrainUptimeNanoseconds else { return .never }
            let elapsed = now >= lastDrainUptimeNanoseconds
                ? now - lastDrainUptimeNanoseconds
                : .max
            return elapsed <= burstDetectionWindowNanoseconds
                ? burstCoalescingDelay
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

    func flushForTesting() {
        queue.sync {}
    }

    private func drainPendingData() {
        while true {
            let next: (session: InMemoryTerminalSession?, chunks: [PendingChunk])? = lock.withLock {
                guard !pendingChunks.isEmpty else {
                    isDrainScheduled = false
                    lastDrainUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                    return nil
                }

                let chunks = pendingChunks
                pendingChunks.removeAll(keepingCapacity: true)
                pendingByteCount = 0
                return (session, chunks)
            }

            guard let next else { return }
            for chunk in next.chunks {
                let data = chunk.containsOverwrittenProgressFrameMarker
                    ? GhosttySessionBridge.collapseOverwrittenProgressFramesForTerminalFeed(chunk.data)
                    : chunk.data
                guard !data.isEmpty else { continue }

                TerminalPerformanceMonitor.recordGhosttyFeedChunk(bytes: data.count)
                let receive = { [receiveData, session = next.session, data] in
                    receiveData(session, data)
                }
                if chunk.suppressHostInput {
                    hostInputSuppressor(receive)
                } else {
                    receive()
                }
            }
        }
    }
}

private final class GhosttySessionProxy: @unchecked Sendable {
    private let lock = NSLock()
    private let inputWriter: TerminalInputWriter
    private var isHostInputSuppressed = false

    weak var session: TerminalSession?
    weak var bridge: GhosttySessionBridge?

    init(session: TerminalSession) {
        self.session = session
        self.inputWriter = session.hostInputWriter
    }

    func send(_ data: Data) {
        let shouldSuppress = lock.withLock {
            isHostInputSuppressed
        }
        guard !shouldSuppress else { return }
        let sanitizedData = GhosttySessionBridge.sanitizeHostInputFromGhostty(data)
        guard !sanitizedData.isEmpty else { return }

        inputWriter.write(sanitizedData)
    }

    func resize(_ viewport: InMemoryTerminalViewport) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let bridge {
                bridge.applyHostResize(viewport)
            } else {
                session?.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
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

enum TerminalSearchArrowDirection {
    case up
    case down

    var bindingAction: String {
        // Ghostty's "next" walks newest-to-oldest, which is visually upward in terminal scrollback.
        switch self {
        case .up:
            "navigate_search:next"
        case .down:
            "navigate_search:previous"
        }
    }
}

@MainActor
final class GhosttySessionBridge: NSObject, TerminalSurfaceCloseDelegate, TerminalSurfaceBellDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceScrollbarDelegate, TerminalSurfacePointerDelegate,
    TerminalSurfaceLinkHoverDelegate, TerminalSurfaceSearchDelegate, TerminalSurfaceHostInputDelegate,
    TerminalSurfaceScrollInputDelegate,
    TerminalSurfaceKeyEquivalentDelegate
{
    private(set) static var liveBridgeCount = 0
    private(set) static var installedOutputObserverCount = 0
    static var detachedSurfaceReleaseDelay: Duration = .milliseconds(750)

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
    private weak var searchState: TerminalSearchState?
    private var searchPresentationHandler: ((String?) -> Void)?
    private var searchDismissalHandler: (() -> Void)?
    private var pointerStyle: TerminalPointerStyle = .text
    private var hoveredLink: String?
    private var isReleased = false
    private var detachedSurfaceReleaseTask: Task<Void, Never>?

    init(session: TerminalSession) {
        let proxy = GhosttySessionProxy(session: session)
        let inMemorySession = Self.makeInMemorySession(proxy: proxy)
        let terminalConfiguration = TerminalSettings.shared.ghosttyConfiguration()
        let terminalTheme = TerminalSettings.shared.ghosttyTheme()

        self.proxy = proxy
        self.inMemorySession = inMemorySession
        self.outputSink = GhosttyOutputSink(session: inMemorySession) { operation in
            proxy.withHostInputSuppressed {
                operation()
            }
        }
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
        proxy.bridge = self
        observeSettingsChanges()
    }

    func attach(to container: GhosttyTerminalContainerView) {
        guard !isReleased else { return }
        cancelDetachedSurfaceRelease()
        let previousContainer = scrollContainer
        let isAlreadyInstalled = previousContainer === container && terminalView.superview != nil
        TerminalPerformanceMonitor.recordBridgeAttach(reused: isAlreadyInstalled)
        if previousContainer !== container {
            previousContainer?.detachTransferredTerminalView(terminalView)
        }
        scrollContainer = container
        if !isAlreadyInstalled {
            container.install(terminalView: terminalView, bridge: self)
        }
        terminalView.setSurfaceVisible(true)
        if !isAlreadyInstalled {
            // Drive a synchronous layout pass so the rebuilt surface receives
            // its real pixel size *before* installOutputObserver replays the
            // raw scrollback. Without this, fitToSize sees zero bounds on the
            // freshly-inserted terminalView and skips setSize, leaving the
            // surface at ghostty's default grid. Absolute cursor moves in the
            // replayed bytes (e.g. zsh's RPROMPT positioning) then land at the
            // wrong column and stay there after layout widens the grid.
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
            TerminalPerformanceMonitor.recordFitToSize()
            terminalView.fitToSize()
        }
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: GhosttyTerminalContainerView, preservingSurface: Bool = false) {
        guard !isReleased, scrollContainer === container else { return }
        terminalView.setSurfaceVisible(false)
        container.uninstall(terminalView: terminalView)
        terminalView.removeFromSuperview()
        scrollContainer = nil
        if preservingSurface {
            scheduleDetachedSurfaceRelease()
        } else {
            cancelDetachedSurfaceRelease()
            releaseDetachedSurface()
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

    func configureSearch(
        state: TerminalSearchState,
        onRequest: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        searchState = state
        searchPresentationHandler = onRequest
        searchDismissalHandler = onDismiss
    }

    @discardableResult
    func startSearch() -> Bool {
        terminalView.performBindingAction("start_search")
    }

    @discardableResult
    func updateSearch(query: String) -> Bool {
        terminalView.performBindingAction("search:\(query)")
    }

    @discardableResult
    func navigateSearch(next: Bool) -> Bool {
        terminalView.performBindingAction(next ? "navigate_search:next" : "navigate_search:previous")
    }

    @discardableResult
    func navigateSearch(_ direction: TerminalSearchArrowDirection) -> Bool {
        terminalView.performBindingAction(direction.bindingAction)
    }

    @discardableResult
    func endSearch() -> Bool {
        terminalView.performBindingAction("end_search")
    }

    func reset() {
        guard !isReleased else { return }
        uninstallOutputObserver()
        gridMetrics = nil
        scrollbarMetrics = nil

        let nextSession = Self.makeInMemorySession(proxy: proxy)
        inMemorySession = nextSession
        outputSink.setSession(nextSession)

        if let terminalSession = proxy.session {
            terminalView.configuration = Self.makeOptions(for: terminalSession, inMemorySession: nextSession)
        }
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
        scrollContainer?.synchronizeScrollState()
        activateOutputFeedWhenSurfaceIsReady()
    }

    func clearScreenAndScrollback() {
        guard !isReleased else { return }

        outputSink.discardPending()
        if terminalView.performBindingAction("clear_screen") {
            scrollbarMetrics = nil
            terminalView.performBindingAction("scroll_to_bottom")
            scrollContainer?.synchronizeScrollState()
        } else {
            reset()
        }
    }

    func releaseResources() {
        guard !isReleased else { return }
        isReleased = true
        Self.liveBridgeCount -= 1
        cancelDetachedSurfaceRelease()
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
        searchState = nil
        searchPresentationHandler = nil
        searchDismissalHandler = nil
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

    func terminalDidRequestSearch(_ request: TerminalSearchStartRequest) {
        if let query = request.query, !query.isEmpty {
            searchState?.query = query
            searchState?.writeQueryToPasteboard()
        } else {
            searchState?.readQueryFromPasteboard()
        }
        searchPresentationHandler?(request.query)
    }

    func terminalDidEndSearch() {
        searchState?.update(total: nil)
        searchState?.update(selected: nil)
        searchDismissalHandler?()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        searchState?.update(total: total)
    }

    func terminalDidUpdateSearchSelection(_ selected: Int?) {
        searchState?.update(selected: selected)
    }

    func scrollToBottomForHostInput() {
        scrollContainer?.beginHostInputScrollSuppression()
        terminalView.performBindingAction("scroll_to_bottom")
        scrollContainer?.scheduleHostInputScrollSynchronization()
    }

    func noteHostInputForOutputLatency() {
        outputSink.noteHostInput()
    }

    func terminalWillSendHostInput() {
        noteHostInputForOutputLatency()
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

    static func isClearScrollbackShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              modifiers.isDisjoint(with: [.shift, .control, .option])
        else {
            return false
        }

        return event.charactersIgnoringModifiers?.lowercased() == "k"
    }

    func terminalShouldSuppressScrollInput(isMomentum: Bool) -> Bool {
        scrollContainer?.shouldSuppressScrollInputForHostInput(isMomentum: isMomentum) ?? false
    }

    func terminalShouldHandleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard Self.isClearScrollbackShortcut(event),
              let session = proxy.session else { return false }
        session.clearScrollback()
        return true
    }

    deinit {
        MainActor.assumeIsolated {
            releaseResources()
            uninstallSettingsObserver()
        }
    }

    func activateOutputFeedWhenSurfaceIsReady() {
        guard !isReleased, outputObserverID == nil, !pendingFeedActivation else { return }
        pendingFeedActivation = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFeedActivation = false
            guard !self.isReleased else { return }
            guard self.prepareSurfaceForOutputReplay() else { return }
            self.installOutputObserver()
        }
    }

    private func prepareSurfaceForOutputReplay() -> Bool {
        guard terminalView.window != nil,
              terminalView.bounds.width > 0,
              terminalView.bounds.height > 0
        else {
            return false
        }

        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
        guard let gridMetrics,
              gridMetrics.columns > 0,
              gridMetrics.rows > 0,
              isViewportConsistentWithMountedSurface(
                  columns: Int(gridMetrics.columns),
                  rows: Int(gridMetrics.rows),
                  widthPixels: Int(gridMetrics.widthPixels),
                  heightPixels: Int(gridMetrics.heightPixels),
                  cellWidthPixels: Int(gridMetrics.cellWidthPixels),
                  cellHeightPixels: Int(gridMetrics.cellHeightPixels)
              )
        else {
            return false
        }

        return true
    }

    private func installOutputObserver() {
        guard !isReleased, outputObserverID == nil, let session = proxy.session else { return }

        let replayOutput = Self.renderedReplayOutput(for: session)
        if !replayOutput.isEmpty {
            outputSink.receive(replayOutput, suppressHostInput: true)
        }

        outputObserverID = session.observeRawOutput(replayExistingOutput: false) { [outputSink] data in
            outputSink.receive(data)
        }
        Self.installedOutputObserverCount += 1
    }

    static func renderedReplayOutput(
        for session: TerminalSession,
        maxBytes: Int = 1_048_576,
        maxLines: Int = 5_000
    ) -> Data {
        if let cachedOutput = session.cachedRenderedReplayOutput(maxBytes: maxBytes, maxLines: maxLines) {
            return cachedOutput
        }

        let lines = renderedReplayLines(for: session, maxBytes: maxBytes, maxLines: maxLines)
        guard !lines.isEmpty else {
            session.cacheRenderedReplayOutput(Data(), maxBytes: maxBytes, maxLines: maxLines)
            return Data()
        }

        var chunks: [Data] = []
        chunks.reserveCapacity(lines.count)
        var byteCount = 0

        for (index, line) in lines.enumerated() {
            var chunk = Data()
            encodeRenderedLine(line, into: &chunk)
            if index < lines.count - 1 {
                chunk.append(contentsOf: [0x0D, 0x0A])
            }

            chunks.append(chunk)
            byteCount += chunk.count
            while byteCount > maxBytes, chunks.count > 1 {
                byteCount -= chunks.removeFirst().count
            }
        }

        var output = Data()
        output.reserveCapacity(byteCount + Self.ansiResetData.count * 2)
        output.append(Self.ansiResetData)
        for chunk in chunks {
            output.append(chunk)
        }
        output.append(Self.ansiResetData)
        session.cacheRenderedReplayOutput(output, maxBytes: maxBytes, maxLines: maxLines)
        return output
    }

    private static func renderedReplayLines(
        for session: TerminalSession,
        maxBytes: Int,
        maxLines: Int
    ) -> [TerminalRenderedLine] {
        let totalLines = session.lineCount
        guard totalLines > 0 else { return [] }

        let startLine = max(0, totalLines - maxLines)
        let directLines = session.styledSnapshot(range: startLine..<totalLines)
        guard directLines.allSatisfy(\.isPlainDefaultStyled) else {
            return directLines
        }

        let styledReplayMaxBytes = min(maxBytes, Self.styledReplayFallbackMaxBytes)
        let rawSnapshot = session.rawOutput(maxBytes: styledReplayMaxBytes)
        let rawOutput = rawSnapshot.data
        guard containsSGRStyleSequence(rawOutput) else { return directLines }

        let styledReplayLineLimit = min(
            maxLines,
            max(
                Self.styledReplayFallbackMinimumLines,
                session.replayViewportSize.rows * Self.styledReplayFallbackViewportMultiplier
            )
        )

        var styledReplayBuffer = PrototypeTerminalBuffer(maxScrollback: styledReplayLineLimit)
        styledReplayBuffer.resize(to: session.replayViewportSize)
        styledReplayBuffer.ingest(
            sanitizeReplayOutputForHostManagedTerminal(rawOutput),
            viewportSize: session.replayViewportSize
        )

        let replayLineCount = styledReplayBuffer.lineCount
        guard replayLineCount > 0 else { return directLines }

        let replayStartLine = max(0, replayLineCount - styledReplayLineLimit)
        var replayLines = styledReplayBuffer.styledSnapshot(range: replayStartLine..<replayLineCount)
        if rawSnapshot.truncated, replayLines.count > 1 {
            replayLines.removeFirst()
        }
        guard !replayLines.isEmpty else { return directLines }

        if directLines.count > replayLines.count {
            return Array(directLines.dropLast(replayLines.count)) + replayLines
        }
        return replayLines
    }

    private static func containsSGRStyleSequence(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == 0x1B, bytes[index + 1] == UInt8(ascii: "[") else {
                index += 1
                continue
            }

            var scan = index + 2
            while scan < bytes.count, !(0x40...0x7E).contains(bytes[scan]) {
                scan += 1
            }
            guard scan < bytes.count else { return false }
            if bytes[scan] == UInt8(ascii: "m") {
                return true
            }
            index = scan + 1
        }

        return false
    }

    private static func encodeRenderedLine(_ line: TerminalRenderedLine, into output: inout Data) {
        var currentStyle = TerminalTextStyle()
        for run in line.runs {
            guard !run.text.isEmpty else { continue }
            if run.style != currentStyle {
                appendSGR(for: run.style, to: &output)
                currentStyle = run.style
            }
            output.append(Data(run.text.utf8))
        }
        if currentStyle != TerminalTextStyle() {
            output.append(Self.ansiResetData)
        }
    }

    private static let ansiResetData = Data("\u{1B}[0m".utf8)
    private static let styledReplayFallbackMaxBytes = 256 * 1024
    private static let styledReplayFallbackMinimumLines = 200
    private static let styledReplayFallbackViewportMultiplier = 4

    private static func appendSGR(for style: TerminalTextStyle, to output: inout Data) {
        var parameters = ["0"]

        if style.isBold {
            parameters.append("1")
        }
        if style.isDim {
            parameters.append("2")
        }
        if style.isItalic {
            parameters.append("3")
        }
        if style.isUnderline {
            parameters.append("4")
        }
        if style.isStrikethrough {
            parameters.append("9")
        }
        if style.isInverse {
            parameters.append("7")
        }
        if let foreground = replayForeground(for: style) {
            parameters.append(contentsOf: sgrColorParameters(for: foreground, isBackground: false))
        }
        if let background = style.background {
            parameters.append(contentsOf: sgrColorParameters(for: background, isBackground: true))
        }

        output.append(Data("\u{1B}[\(parameters.joined(separator: ";"))m".utf8))
    }

    private static func replayForeground(for style: TerminalTextStyle) -> TerminalANSIColor? {
        if let foreground = style.foreground {
            return foreground
        }

        // Cherry answers OSC 10 foreground queries with this color. When an app
        // paints a custom background but relies on that default foreground, a
        // freshly rebuilt Ghostty surface can otherwise render dark-on-dark.
        if style.background != nil {
            return reportedDefaultForegroundColor
        }

        return nil
    }

    private static let reportedDefaultForegroundColor = TerminalANSIColor.rgb(219, 227, 235)

    private static func sgrColorParameters(
        for color: TerminalANSIColor,
        isBackground: Bool
    ) -> [String] {
        switch color {
        case .ansi16(let value):
            let normalized = max(0, min(value, 15))
            if normalized < 8 {
                return [String((isBackground ? 40 : 30) + normalized)]
            }
            return [String((isBackground ? 100 : 90) + normalized - 8)]
        case .palette256(let value):
            return [isBackground ? "48" : "38", "5", String(max(0, min(value, 255)))]
        case let .rgb(red, green, blue):
            return [isBackground ? "48" : "38", "2", String(red), String(green), String(blue)]
        }
    }

    func installOutputObserverForTesting() {
        installOutputObserver()
    }

    func flushOutputForTesting() {
        outputSink.flushForTesting()
    }

    private func uninstallOutputObserver() {
        guard let outputObserverID else { return }
        proxy.session?.removeRawOutputObserver(id: outputObserverID)
        self.outputObserverID = nil
        Self.installedOutputObserverCount -= 1
    }

    private func scheduleDetachedSurfaceRelease() {
        cancelDetachedSurfaceRelease()
        let delay = Self.detachedSurfaceReleaseDelay
        detachedSurfaceReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isReleased, self.scrollContainer == nil else { return }
            self.detachedSurfaceReleaseTask = nil
            self.releaseDetachedSurface()
        }
    }

    private func cancelDetachedSurfaceRelease() {
        detachedSurfaceReleaseTask?.cancel()
        detachedSurfaceReleaseTask = nil
    }

    private func releaseDetachedSurface() {
        pendingFeedActivation = false
        uninstallOutputObserver()
        terminalView.freeSurface()
        gridMetrics = nil
        scrollbarMetrics = nil
    }

    nonisolated static func sanitizeReplayOutputForHostManagedTerminal(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = Array(data)
        var sanitized: [UInt8] = []
        sanitized.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case UInt8(ascii: "]"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isResponseGeneratingOSCQuery(payload) {
                            index = bounds.endIndex
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<bounds.endIndex])
                        index = bounds.endIndex
                        continue
                    }
                case UInt8(ascii: "["):
                    if let finalIndex = csiFinalIndex(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<finalIndex]
                        let finalByte = bytes[finalIndex]
                        if isResponseGeneratingCSIQuery(payload, finalByte: finalByte) {
                            index = finalIndex + 1
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<(finalIndex + 1)])
                        index = finalIndex + 1
                        continue
                    }
                case UInt8(ascii: "P"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isResponseGeneratingDCSQuery(payload) {
                            index = bounds.endIndex
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<bounds.endIndex])
                        index = bounds.endIndex
                        continue
                    }
                default:
                    break
                }
            }

            sanitized.append(bytes[index])
            index += 1
        }

        let querySanitized = sanitized.count == bytes.count ? data : Data(sanitized)
        let promptSanitized = stripZshPromptEndOfLineMarks(querySanitized)
        return collapseOverwrittenProgressFramesForTerminalFeed(promptSanitized)
    }

    nonisolated private static func stripZshPromptEndOfLineMarks(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = Array(data)
        var stripped: [UInt8] = []
        stripped.reserveCapacity(bytes.count)

        var index = 0
        var didStrip = false
        while index < bytes.count {
            if let markEnd = zshPromptEndOfLineMarkEnd(in: bytes, at: index) {
                didStrip = true
                index = markEnd
                continue
            }

            stripped.append(bytes[index])
            index += 1
        }

        return didStrip ? Data(stripped) : data
    }

    nonisolated private static func zshPromptEndOfLineMarkEnd(
        in bytes: [UInt8],
        at index: Int
    ) -> Int? {
        let marker = Array("\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m".utf8)
        guard index + marker.count < bytes.count,
              bytes[index..<(index + marker.count)].elementsEqual(marker)
        else {
            return nil
        }

        var scan = index + marker.count
        let spacesStart = scan
        while scan < bytes.count, bytes[scan] == UInt8(ascii: " ") {
            scan += 1
        }

        guard scan > spacesStart,
              scan < bytes.count,
              bytes[scan] == UInt8(ascii: "\r")
        else {
            return nil
        }

        scan += 1
        if scan + 1 < bytes.count,
           bytes[scan] == UInt8(ascii: " "),
           bytes[scan + 1] == UInt8(ascii: "\r")
        {
            scan += 2
        } else if scan < bytes.count, bytes[scan] == UInt8(ascii: "\r") {
            scan += 1
        }

        return scan
    }

    nonisolated fileprivate static func collapseOverwrittenProgressFramesForTerminalFeed(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard containsOverwrittenProgressFrameMarker(data) else { return data }

        let bytes = Array(data)
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(bytes.count)

        var index = 0
        var didCollapse = false
        while index < bytes.count {
            guard isEraseLineCarriageReturnMarker(in: bytes, at: index) else {
                collapsed.append(bytes[index])
                index += 1
                continue
            }

            let runStart = index
            var latestFrameStart = index
            var frameCount = 1
            var scan = index + eraseLineCarriageReturnMarkerLength
            var lineEndExclusive = bytes.count
            var canCollapse = true

            while scan < bytes.count {
                if bytes[scan] == UInt8(ascii: "\n") {
                    lineEndExclusive = scan + 1
                    break
                }

                if isEraseLineCarriageReturnMarker(in: bytes, at: scan) {
                    let payloadStart = latestFrameStart + eraseLineCarriageReturnMarkerLength
                    if bytes[payloadStart..<scan].contains(0x1B) {
                        canCollapse = false
                        break
                    }
                    latestFrameStart = scan
                    frameCount += 1
                    scan += eraseLineCarriageReturnMarkerLength
                    continue
                }

                scan += 1
            }

            if canCollapse, frameCount > 1 {
                collapsed.append(contentsOf: bytes[latestFrameStart..<lineEndExclusive])
                didCollapse = true
                index = lineEndExclusive
            } else {
                collapsed.append(contentsOf: bytes[runStart..<lineEndExclusive])
                index = lineEndExclusive
            }
        }

        return didCollapse ? Data(collapsed) : data
    }

    nonisolated private static var eraseLineCarriageReturnMarkerLength: Int { 5 }

    nonisolated fileprivate static func containsOverwrittenProgressFrameMarker(_ data: Data) -> Bool {
        guard data.count >= eraseLineCarriageReturnMarkerLength else { return false }

        return data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard bytes.count >= eraseLineCarriageReturnMarkerLength else { return false }

            var index = 0
            while index + eraseLineCarriageReturnMarkerLength <= bytes.count {
                if isEraseLineCarriageReturnMarker(in: bytes, at: index) {
                    return true
                }
                index += 1
            }
            return false
        }
    }

    nonisolated private static func isEraseLineCarriageReturnMarker(
        in bytes: [UInt8],
        at index: Int
    ) -> Bool {
        index + eraseLineCarriageReturnMarkerLength <= bytes.count
            && bytes[index] == 0x1B
            && bytes[index + 1] == UInt8(ascii: "[")
            && bytes[index + 2] == UInt8(ascii: "2")
            && bytes[index + 3] == UInt8(ascii: "K")
            && bytes[index + 4] == UInt8(ascii: "\r")
    }

    nonisolated private static func isEraseLineCarriageReturnMarker(
        in bytes: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> Bool {
        index + eraseLineCarriageReturnMarkerLength <= bytes.count
            && bytes[index] == 0x1B
            && bytes[index + 1] == UInt8(ascii: "[")
            && bytes[index + 2] == UInt8(ascii: "2")
            && bytes[index + 3] == UInt8(ascii: "K")
            && bytes[index + 4] == UInt8(ascii: "\r")
    }

    nonisolated static func sanitizeHostInputFromGhostty(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        let bytes = Array(data)
        var sanitized: [UInt8] = []
        sanitized.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case UInt8(ascii: "]"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isTerminalGeneratedOSCResponse(payload) {
                            index = bounds.endIndex
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<bounds.endIndex])
                        index = bounds.endIndex
                        continue
                    }
                case UInt8(ascii: "["):
                    if let finalIndex = csiFinalIndex(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<finalIndex]
                        let finalByte = bytes[finalIndex]
                        if isTerminalGeneratedCSIResponse(payload, finalByte: finalByte) {
                            index = finalIndex + 1
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<(finalIndex + 1)])
                        index = finalIndex + 1
                        continue
                    }
                case UInt8(ascii: "P"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isTerminalGeneratedDCSResponse(payload) {
                            index = bounds.endIndex
                            continue
                        }
                        sanitized.append(contentsOf: bytes[index..<bounds.endIndex])
                        index = bounds.endIndex
                        continue
                    }
                default:
                    break
                }
            }

            sanitized.append(bytes[index])
            index += 1
        }

        return sanitized.count == bytes.count ? data : Data(sanitized)
    }

    nonisolated private static func oscSequenceBounds(
        in bytes: [UInt8],
        payloadStart: Int
    ) -> (payloadEnd: Int, endIndex: Int)? {
        var index = payloadStart
        while index < bytes.count {
            if bytes[index] == 0x07 {
                return (payloadEnd: index, endIndex: index + 1)
            }

            if bytes[index] == 0x1B {
                guard index + 1 < bytes.count else { return nil }
                if bytes[index + 1] == UInt8(ascii: "\\") {
                    return (payloadEnd: index, endIndex: index + 2)
                }
                index += 2
                continue
            }

            index += 1
        }

        return nil
    }

    nonisolated private static func csiFinalIndex(in bytes: [UInt8], payloadStart: Int) -> Int? {
        var index = payloadStart
        while index < bytes.count {
            let byte = bytes[index]
            if (0x40...0x7E).contains(byte) {
                return index
            }
            index += 1
        }
        return nil
    }

    nonisolated private static func isResponseGeneratingOSCQuery(_ payload: ArraySlice<UInt8>) -> Bool {
        let fields = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard let command = fields.first else { return false }

        switch command {
        case "4":
            return fields.dropFirst().contains("?")
        case "10", "11", "12", "13", "17", "19":
            return fields.indices.contains(1) && fields[1] == "?"
        default:
            return false
        }
    }

    nonisolated private static func isTerminalGeneratedOSCResponse(_ payload: ArraySlice<UInt8>) -> Bool {
        let fields = String(decoding: payload, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        guard let command = fields.first else { return false }

        switch command {
        case "4":
            guard fields.count >= 3 else { return false }
            return fields.dropFirst().contains { $0.hasPrefix("rgb:") }
        case "10", "11", "12", "13", "17", "19":
            return fields.indices.contains(1) && fields[1].hasPrefix("rgb:")
        default:
            return false
        }
    }

    nonisolated private static func isResponseGeneratingDCSQuery(_ payload: ArraySlice<UInt8>) -> Bool {
        guard payload.starts(with: [UInt8(ascii: "+"), UInt8(ascii: "q")]) else {
            return false
        }

        return isXTGETTCAPPayload(payload.dropFirst(2), allowsValue: false)
    }

    nonisolated private static func isTerminalGeneratedDCSResponse(_ payload: ArraySlice<UInt8>) -> Bool {
        guard payload.count >= 3 else { return false }

        let prefix = Array(payload.prefix(3))
        guard prefix == [UInt8(ascii: "0"), UInt8(ascii: "+"), UInt8(ascii: "r")]
            || prefix == [UInt8(ascii: "1"), UInt8(ascii: "+"), UInt8(ascii: "r")]
        else {
            return false
        }

        return isXTGETTCAPPayload(payload.dropFirst(3), allowsValue: true)
    }

    nonisolated private static func isXTGETTCAPPayload(
        _ bytes: ArraySlice<UInt8>,
        allowsValue: Bool
    ) -> Bool {
        guard !bytes.isEmpty else { return false }

        var fieldStart = bytes.startIndex
        var index = fieldStart
        while true {
            if index == bytes.endIndex || bytes[index] == UInt8(ascii: ";") {
                guard isXTGETTCAPField(bytes[fieldStart..<index], allowsValue: allowsValue) else {
                    return false
                }

                guard index != bytes.endIndex else { return true }
                index = bytes.index(after: index)
                fieldStart = index
                continue
            }

            index = bytes.index(after: index)
        }
    }

    nonisolated private static func isXTGETTCAPField(
        _ bytes: ArraySlice<UInt8>,
        allowsValue: Bool
    ) -> Bool {
        guard !bytes.isEmpty else { return false }

        var sawEquals = false
        var hasNameBytes = false
        var hasValueBytes = false
        for byte in bytes {
            if byte == UInt8(ascii: "=") {
                guard allowsValue, !sawEquals else { return false }
                sawEquals = true
                continue
            }

            guard isASCIIHexDigit(byte) else { return false }
            if sawEquals {
                hasValueBytes = true
            } else {
                hasNameBytes = true
            }
        }

        guard hasNameBytes else { return false }
        return !sawEquals || hasValueBytes
    }

    nonisolated private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    nonisolated private static func isResponseGeneratingCSIQuery(
        _ payloadBytes: ArraySlice<UInt8>,
        finalByte: UInt8
    ) -> Bool {
        let payload = String(decoding: payloadBytes, as: UTF8.self)

        switch finalByte {
        case UInt8(ascii: "c"):
            return true
        case UInt8(ascii: "n"):
            return payload == "5" || payload == "6"
        case UInt8(ascii: "p"):
            return payload.hasPrefix("?") && payload.hasSuffix("$")
        case UInt8(ascii: "u"):
            return payload.first == "?"
        default:
            return false
        }
    }

    nonisolated private static func isTerminalGeneratedCSIResponse(
        _ payloadBytes: ArraySlice<UInt8>,
        finalByte: UInt8
    ) -> Bool {
        let payload = String(decoding: payloadBytes, as: UTF8.self)

        switch finalByte {
        case UInt8(ascii: "c"):
            return payload.hasPrefix("?") || payload.hasPrefix(">")
        case UInt8(ascii: "n"):
            return payload == "0"
        case UInt8(ascii: "R"):
            let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return false }
            return fields.allSatisfy { Int($0) != nil }
        case UInt8(ascii: "y"):
            guard payload.hasPrefix("?"), payload.contains(";"), payload.hasSuffix("$") else {
                return false
            }
            let body = payload.dropFirst().dropLast()
            let fields = body.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return false }
            return fields.allSatisfy { Int($0) != nil }
        case UInt8(ascii: "u"):
            return payload == "?0"
        default:
            return false
        }
    }

    private static func makeInMemorySession(proxy: GhosttySessionProxy) -> InMemoryTerminalSession {
        InMemoryTerminalSession(
            write: { data in
                proxy.send(data)
            },
            resize: { viewport in
                proxy.resize(viewport)
            }
        )
    }

    func applyHostResize(_ viewport: InMemoryTerminalViewport) {
        guard isViewportConsistentWithMountedSurface(
            columns: Int(viewport.columns),
            rows: Int(viewport.rows),
            widthPixels: Int(viewport.widthPixels),
            heightPixels: Int(viewport.heightPixels),
            cellWidthPixels: Int(viewport.cellWidthPixels),
            cellHeightPixels: Int(viewport.cellHeightPixels)
        ) else {
            return
        }

        proxy.session?.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
    }

    private func isViewportConsistentWithMountedSurface(
        columns: Int,
        rows: Int,
        widthPixels: Int,
        heightPixels: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) -> Bool {
        guard !isReleased, columns > 0, rows > 0 else { return false }
        guard scrollContainer != nil,
              terminalView.superview != nil,
              let window = terminalView.window
        else {
            return false
        }

        let bounds = terminalView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let expectedWidthPixels = bounds.width * window.backingScaleFactor
        let expectedHeightPixels = bounds.height * window.backingScaleFactor

        if widthPixels > 0,
           expectedWidthPixels >= 200,
           CGFloat(widthPixels) < expectedWidthPixels * 0.5
        {
            return false
        }

        if heightPixels > 0,
           expectedHeightPixels >= 200,
           CGFloat(heightPixels) < expectedHeightPixels * 0.5
        {
            return false
        }

        if widthPixels == 0, cellWidthPixels > 0 {
            let expectedColumns = Int(expectedWidthPixels / CGFloat(cellWidthPixels))
            if expectedColumns >= 40, columns < expectedColumns / 2 {
                return false
            }
        }

        if heightPixels == 0, cellHeightPixels > 0 {
            let expectedRows = Int(expectedHeightPixels / CGFloat(cellHeightPixels))
            if expectedRows >= 20, rows < expectedRows / 2 {
                return false
            }
        }

        return true
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
    private var isActivePane = true
    private var activatePane: (() -> Void)?
    private var pendingTerminalFocus = false
    private var isSidebarAnimating = false
    private var isSyncFrozen = false
    private var snapshotLayer: CALayer?
    private var activeColorScheme: ColorScheme = .dark
    private var pendingPostAnimationDelta: CGFloat = 0
    private var didApplyEarlyFit = false
    private var shouldSuppressMomentumScrollAfterHostInput = false
    private var isHostInputScrollSyncScheduled = false

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
        allowsAutoFocus: Bool = true,
        isActivePane: Bool = true,
        onActivate: (() -> Void)? = nil
    ) {
        TerminalPerformanceMonitor.recordContainerConfigure()
        let wasActivePane = self.isActivePane
        self.isActivePane = isActivePane
        activatePane = onActivate
        self.allowsAutoFocus = allowsAutoFocus
        if !allowsAutoFocus {
            pendingTerminalFocus = false
        }

        if activeSession !== session {
            resetSidebarAnimationStateForSurfaceChange()
            if let activeSession {
                activeSession.detachGhosttyBridge(from: self)
                activeSession.releaseGhosttyBridge()
            }
            activeSession = session
            session.ghosttyBridge.attach(to: self)
            if isActivePane {
                requestTerminalFocus()
            }
        } else {
            session.ghosttyBridge.attach(to: self)
        }

        if isActivePane, !wasActivePane {
            requestTerminalFocus()
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
        // `attach` can call `terminalView.fitToSize()`, which would re-issue
        // a Metal surface reconfigure on every layout pass — including the
        // final post-animation one — undoing the work the freeze + early-fit
        // are doing. Attachment is already handled in
        // `configure(with:colorScheme:)` (session changes) and
        // `viewDidMoveToWindow` (window changes), which is sufficient.
        synchronizeScrollState()
        activeBridge?.activateOutputFeedWhenSurfaceIsReady()

        updateSnapshotLayerFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detachActiveSession(clearsSession: false, releasesBridge: false, preservingSurface: true)
        } else {
            activeSession?.ghosttyBridge.attach(to: self)
            if isActivePane {
                requestTerminalFocus()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            guard isActivePane else {
                activatePane?()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isActivePane else { return }
                    self.activeSession?.ghosttyBridge.focus(in: window)
                }
                return
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
            resetSidebarAnimationStateForSurfaceChange()
            activeBridge = nil
        }
    }

    func detachTransferredTerminalView(_ terminalView: TerminalView) {
        let ownedTransferredView = activeBridge?.terminalView === terminalView
        if terminalView.superview === documentView {
            terminalView.removeFromSuperview()
        }
        guard ownedTransferredView else { return }

        activeSession = nil
        activeBridge = nil
        pendingTerminalFocus = false
        resetSidebarAnimationStateForSurfaceChange()
    }

    func detachActiveSession(
        clearsSession: Bool = true,
        releasesBridge: Bool = true,
        preservingSurface: Bool = false
    ) {
        guard let session = activeSession else {
            activeBridge = nil
            pendingTerminalFocus = false
            resetSidebarAnimationStateForSurfaceChange()
            return
        }

        session.detachGhosttyBridge(from: self, preservingSurface: preservingSurface)
        if releasesBridge {
            session.releaseGhosttyBridge()
        }
        if clearsSession {
            activeSession = nil
        }
        activeBridge = nil
        pendingTerminalFocus = false
        resetSidebarAnimationStateForSurfaceChange()
    }

    func synchronizeScrollState() {
        guard let terminalView = activeBridge?.terminalView else { return }

        // This runs after every rendered frame (scrollbar updates) and on
        // every keystroke, so skip the AppKit mutations when nothing moved —
        // `reflectScrolledClipView` alone dirties window-restoration state
        // and re-evaluates scroller visibility each call.
        var scrollStateChanged = false

        let documentSize = NSSize(
            width: max(scrollView.contentSize.width, 1),
            height: documentHeight()
        )
        if documentView.frame.size != documentSize {
            documentView.frame.size = documentSize
            scrollStateChanged = true
        }

        if !isLiveScrolling, let scrollbar = activeBridge?.scrollbarMetrics {
            let offsetY = scrollOffsetY(for: scrollbar)
            let target = NSPoint(x: 0, y: clampedScrollOffset(offsetY))
            if scrollView.contentView.bounds.origin != target {
                scrollView.contentView.scroll(to: target)
                scrollStateChanged = true
            }
            lastSentScrollRow = Int(scrollbar.offset)
        }

        if scrollStateChanged {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // While the sidebar is animating we want exactly zero resize-driven
        // re-fits; otherwise the terminal reflows on every scroll-bounds
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

    func scheduleHostInputScrollSynchronization() {
        guard !isHostInputScrollSyncScheduled else { return }
        isHostInputScrollSyncScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHostInputScrollSyncScheduled = false
            self.synchronizeScrollState()
        }
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

    private func resetSidebarAnimationStateForSurfaceChange() {
        isSidebarAnimating = false
        isSyncFrozen = false
        didApplyEarlyFit = false
        pendingPostAnimationDelta = 0
        removeSnapshotLayer(animated: false)
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
        // Best-effort screenshot of the live terminal area. AppKit's
        // `cacheDisplay` may not capture every GPU-backed surface; if it
        // fails we still suppress resize re-fits, the cross-fade just becomes
        // a no-op.
        guard scrollView.frame.width > 0,
              scrollView.frame.height > 0 else { return }

        let captureRect = scrollView.frame
        let cgImage = captureViewBitmap(scrollView, rect: scrollView.bounds)

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
           let pasteData = TerminalPasteboardContent.pasteData(
               from: .general,
               bracketedPasteMode: activeSession.usesBracketedPasteMode
           ) {
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

    func simulateSidebarSnapshotForTesting() {
        wantsLayer = true
        let layer = CALayer()
        layer.frame = bounds
        layer.zPosition = 1_000
        self.layer?.addSublayer(layer)
        snapshotLayer = layer
        isSidebarAnimating = true
        isSyncFrozen = true
        didApplyEarlyFit = true
        pendingPostAnimationDelta = 120
    }

    var hasSidebarSnapshotForTesting: Bool {
        snapshotLayer?.superlayer != nil
    }

    var isSidebarSyncFrozenForTesting: Bool {
        isSyncFrozen
    }

    var isSidebarAnimationActiveForTesting: Bool {
        isSidebarAnimating
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
