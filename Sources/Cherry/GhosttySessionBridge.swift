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
    let line = "[sidebar.resize] \(message())"
    print(line)
    if let data = (line + "\n").data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/cherry-sidebar-resize.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

final class GhosttyOutputSink: @unchecked Sendable {
    private static let maximumRetainedPendingBytes = 1_048_576
    private static let defaultBurstCoalescingDelay: DispatchTimeInterval = .milliseconds(80)
    private static let defaultPromptMarkCoalescingDelay: DispatchTimeInterval = .milliseconds(12)
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
    private let promptMarkCoalescingDelay: DispatchTimeInterval
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
        promptMarkCoalescingDelay: DispatchTimeInterval = GhosttyOutputSink.defaultPromptMarkCoalescingDelay,
        burstDetectionWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultBurstDetectionWindowNanoseconds,
        inputLatencyBypassWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultInputLatencyBypassWindowNanoseconds
    ) {
        self.session = session
        self.hostInputSuppressor = hostInputSuppressor
        self.burstCoalescingDelay = burstCoalescingDelay
        self.promptMarkCoalescingDelay = promptMarkCoalescingDelay
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
        promptMarkCoalescingDelay: DispatchTimeInterval = GhosttyOutputSink.defaultPromptMarkCoalescingDelay,
        burstDetectionWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultBurstDetectionWindowNanoseconds,
        inputLatencyBypassWindowNanoseconds: UInt64 = GhosttyOutputSink.defaultInputLatencyBypassWindowNanoseconds
    ) {
        self.session = nil
        self.hostInputSuppressor = hostInputSuppressor
        self.burstCoalescingDelay = burstCoalescingDelay
        self.promptMarkCoalescingDelay = promptMarkCoalescingDelay
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
        let endsWithIncompletePromptEndMark =
            GhosttySessionBridge.endsWithIncompleteZshPromptEndOfLineMark(data)
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
            let shouldDelayForProgressCoalescing = containsOverwrittenProgressFrameMarker && !isRecentHostInput
            let shouldDelayForCoalescing =
                endsWithIncompletePromptEndMark || shouldDelayForProgressCoalescing
            guard !isDrainScheduled else {
                return shouldDelayForCoalescing ? nil : .never
            }

            isDrainScheduled = true
            guard shouldDelayForCoalescing else { return .never }
            if endsWithIncompletePromptEndMark {
                return promptMarkCoalescingDelay
            }
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
                let promptSanitizedData =
                    GhosttySessionBridge.stripZshPromptEndOfLineMarks(chunk.data)
                let data = chunk.containsOverwrittenProgressFrameMarker
                    ? GhosttySessionBridge.collapseOverwrittenProgressFramesForTerminalFeed(promptSanitizedData)
                    : promptSanitizedData
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
            guard let bridge else { return }
            bridge.applyHostResize(viewport)
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
    TerminalSurfaceTitleDelegate, TerminalSurfaceWorkingDirectoryDelegate,
    TerminalSurfaceNotificationDelegate, TerminalSurfaceChildExitDelegate,
    TerminalSurfaceRenderDelegate, TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceKeyEquivalentDelegate
{
    private(set) static var liveBridgeCount = 0
    private(set) static var installedOutputObserverCount = 0
    static var detachedSurfaceReleaseDelay: Duration = .milliseconds(750)
    private static let transientStartupShrinkInterval: TimeInterval = 0.9

    /// Cap on the number of *background* (parked) Ghostty surfaces kept warm
    /// across tab switches.
    ///
    /// Warm by default (`defaultLiveSurfaceLimit`, 64): the most-recently-used
    /// background surfaces stay alive *and fed* (the output observer is left
    /// installed), so switching back is a plain re-show with no rebuild and no
    /// replay — matching how Ghostty and cmux keep a live surface per pane. Only
    /// surfaces evicted past the cap fall back to the rebuild-by-replay cold path.
    ///
    /// `nil` disables keep-warm entirely (the old replay-on-every-switch
    /// behavior); `unlimitedLiveSurfaceLimit` never evicts (keep every surface
    /// alive forever, the pure-Ghostty model — memory grows with tab count).
    /// Override at runtime with `CHERRY_LIVE_SURFACE_LIMIT=N` (`=0` to disable,
    /// `=unlimited` or a negative value to never evict), or build the old behavior
    /// with `-DCHERRY_REPLAY_ON_SWITCH` (`CHERRY_KEEP_SURFACES_WARM=0
    /// Scripts/install-local-app`). The active surface is always live; this only
    /// bounds how many *inactive* ones stay warm.
    static var liveSurfaceLimit: Int? = resolveInitialLiveSurfaceLimit()

    /// Sentinel for "never evict" — large enough that the eviction loop never
    /// fires, so every parked surface stays warm.
    static let unlimitedLiveSurfaceLimit = Int.max

    /// Default cap when nothing overrides it. 64 is effectively "keep everything
    /// warm" for realistic tab counts while still bounding a runaway; measured
    /// cost is ~3 MiB per light surface, ~8-10 MiB with heavy scrollback.
    private static let defaultLiveSurfaceLimit = 64

    private static func resolveInitialLiveSurfaceLimit() -> Int? {
        // Native-PTY: every surface owns a live child process, so evicting one
        // would kill a running agent/command. Keep them all alive.
        if nativePTYEnabled {
            return unlimitedLiveSurfaceLimit
        }
        if let raw = ProcessInfo.processInfo.environment["CHERRY_LIVE_SURFACE_LIMIT"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "unlimited" || trimmed == "all" {
                return unlimitedLiveSurfaceLimit
            }
            if let value = Int(trimmed) {
                // Explicit runtime override: a positive value sets the cap, a
                // negative value never evicts, 0 disables keep-warm.
                if value == 0 { return nil }
                return value < 0 ? unlimitedLiveSurfaceLimit : value
            }
        }
        #if CHERRY_REPLAY_ON_SWITCH
        return nil
        #else
        return defaultLiveSurfaceLimit
        #endif
    }

    /// Parked (detached-but-alive) bridges in least-recently-used order. A parked
    /// bridge is still owned by its session's `ghosttyBridgeStorage`; this list
    /// governs when that ownership ends — eviction fully releases the surface so a
    /// later switch-back falls back to the cold replay path.
    private static var parkedBridges: [GhosttySessionBridge] = []

    private static func notePark(_ bridge: GhosttySessionBridge) {
        parkedBridges.removeAll { $0 === bridge }
        parkedBridges.append(bridge)
        guard let limit = liveSurfaceLimit, limit > 0 else { return }
        while parkedBridges.count > limit {
            parkedBridges.removeFirst().releaseFromLiveSurfaceLRU()
        }
    }

    private static func noteUnpark(_ bridge: GhosttySessionBridge) {
        parkedBridges.removeAll { $0 === bridge }
    }

    static func resetLiveSurfaceLRUForTesting() {
        parkedBridges.removeAll()
        liveSurfaceLimit = resolveInitialLiveSurfaceLimit()
    }

    private func releaseFromLiveSurfaceLRU() {
        // Drop the session's ownership of this bridge so a later switch-back
        // lazily rebuilds a fresh surface (cold path). `releaseGhosttyBridge`
        // funnels through `releaseResources`, which frees the surface and removes
        // this bridge from `parkedBridges`.
        if let session = proxy.session {
            session.releaseGhosttyBridge()
        } else {
            releaseResources()
        }
    }

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
    private var outputFeedActivationRetryCount = 0
    fileprivate var isPreparingOutputReplay = false
    private var postAttachGeometryRefreshGeneration = 0
    private var attachedAt: Date?
    private var lastReplayedGridSize: TerminalViewportSize?
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
        if Self.nativePTYEnabled {
            // Native eagerly creates the EXEC surface on the next line, which spawns
            // the child immediately. A background-spawned agent queries the terminal
            // background (OSC 11) for its very first render, so the theme/scheme must
            // be on the controller BEFORE the surface exists — otherwise that first
            // prompt renders with ghostty's default (light) background while later
            // output is correct. The displaying container re-applies the real scheme.
            activeColorScheme = Self.resolvedColorScheme()
            applyTerminalSettings()
        }
        terminalView.configuration = Self.makeOptions(for: session, inMemorySession: inMemorySession)
        proxy.bridge = self
        observeSettingsChanges()
    }

    private static func resolvedColorScheme() -> ColorScheme {
        // Cherry sets its OWN appearance (`.preferredColorScheme(...)`), so honor
        // that first — a user on Dark with a Light system would otherwise get a
        // light background baked into a background-spawned agent's surface, which
        // Codex then probes via OSC 11 for its first input box. Only "follow
        // system" falls back to the OS setting (read directly; NSApp's appearance
        // is unreliable while Cherry isn't the active app).
        if let preferred = TerminalSettings.shared.appearance.preferredColorScheme {
            return preferred
        }
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
           style.lowercased().contains("dark") {
            return .dark
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    func attach(to container: GhosttyTerminalContainerView) {
        guard !isReleased else { return }
        cancelDetachedSurfaceRelease()
        Self.noteUnpark(self)
        let previousContainer = scrollContainer
        let isAlreadyInstalled = previousContainer === container && terminalView.superview != nil
        TerminalPerformanceMonitor.recordBridgeAttach(reused: isAlreadyInstalled)
        if previousContainer !== container {
            previousContainer?.detachTransferredTerminalView(terminalView)
        }
        scrollContainer = container
        attachedAt = Date()
        outputFeedActivationRetryCount = 0
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
            container.synchronizeScrollState(forceTerminalFrame: true)
            synchronizeMountedSurfaceGeometry()
        }
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: GhosttyTerminalContainerView, preservingSurface: Bool = false) {
        guard !isReleased, scrollContainer === container else { return }
        let canPreserveSurface = preservingSurface
            && container.bounds.width > 0
            && container.bounds.height > 0
        terminalView.setSurfaceVisible(false)
        container.uninstall(terminalView: terminalView)
        terminalView.removeFromSuperview()
        scrollContainer = nil
        if Self.nativePTYEnabled {
            // EXEC surface == live child process. Never free it on detach (that
            // would kill a running agent/command); keep it parked and alive so a
            // non-active tab keeps running. Freed only when the session closes.
            cancelDetachedSurfaceRelease()
            Self.notePark(self)
            return
        }
        if Self.liveSurfaceLimit != nil, canPreserveSurface {
            // Live-surface LRU: keep the surface alive and fed (the output
            // observer is left installed), so a switch-back is a re-show with no
            // replay. Release timing is governed by LRU eviction in `notePark`,
            // not the per-bridge timer.
            cancelDetachedSurfaceRelease()
            Self.notePark(self)
        } else if canPreserveSurface {
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
        lastReplayedGridSize = nil
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
        scrollContainer?.synchronizeScrollState()
        activateOutputFeedWhenSurfaceIsReady()
    }

    func clearScreenAndScrollback() {
        guard !isReleased else { return }

        outputSink.discardPending()
        // ghostty's clear_screen only scrolls the prompt to the top under shell
        // integration (it leaves scrollback intact — ghostty #970), and ED 3
        // (CSI 3 J, erase scrollback) is a no-op in this libghostty, so the only way
        // to actually drop scrollback under native is a full RIS reset. RIS would
        // wreck a full-screen TUI, so only use it when the program hasn't grabbed the
        // mouse (a good proxy for "at a plain shell prompt", and it's true for agents
        // too). RIS also blanks the prompt, so nudge zsh to repaint with Ctrl+L.
        if Self.nativePTYEnabled, !terminalView.isMouseCaptured,
           terminalView.performBindingAction("reset") {
            terminalView.sendKeyPress(keycode: 37, shift: false, control: true, option: false) // Ctrl+L
        } else {
            _ = terminalView.performBindingAction("clear_screen")
        }
        scrollbarMetrics = nil
        terminalView.performBindingAction("scroll_to_bottom")
        scrollContainer?.synchronizeScrollState()
    }

    func releaseResources() {
        guard !isReleased else { return }
        isReleased = true
        Self.liveBridgeCount -= 1
        Self.noteUnpark(self)
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

    // MARK: - Native-PTY chrome (forwarded ghostty actions)
    //
    // Under the EXEC backend the ghostty surface owns the PTY, so the chrome the
    // host path derives by parsing PTY bytes itself instead arrives as ghostty
    // actions. Only forward when native is on: in host-managed mode TerminalSession
    // already parses these from the byte stream, and double-applying would race.

    func terminalDidChangeTitle(_ title: String) {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.ingestNativeTitle(title)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.ingestNativeWorkingDirectory(path)
    }

    func terminalDidPostNotification(title: String?, body: String) {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.ingestNativeNotification(title: title, body: body)
    }

    func terminalDidExit(exitCode: UInt32) {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.ingestNativeChildExit(exitCode: Int32(bitPattern: exitCode))
    }

    func terminalDidRequestRender() {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.noteNativeRenderRequest()
    }

    func terminalDidFinishCommand(exitCode: Int32?, durationNanoseconds: UInt64) {
        guard Self.nativePTYEnabled, let session = proxy.session else { return }
        session.noteNativeCommandFinished(exitCode: exitCode)
    }

    /// Routes programmatic input to the surface-owned PTY under native mode (the
    /// host has no PTY fd to write to). `send(text:)`/`send(data:)` funnel here.
    ///
    /// Printable runs go through the surface text path; control/escape sequences
    /// (Enter, arrows, Tab, Esc, Ctrl-combos) become real key events, because
    /// `ghostty_surface_text` filters control bytes — this is the path agents use
    /// to drive other agents' TUIs. See `NativeInputTranslator`.
    func sendNativeInput(_ data: Data) {
        for op in NativeInputTranslator.translate(data) {
            switch op {
            case .text(let text):
                terminalView.sendText(text)
            case .key(let keycode, let shift, let control, let option):
                terminalView.sendKeyPress(keycode: keycode, shift: shift, control: control, option: option)
            }
        }
    }

    /// Full scrollback text from the surface, for native-PTY data reads (the host
    /// owns no byte stream under EXEC). nil when the surface is unavailable.
    func readNativeScreenText() -> String? {
        terminalView.readScreenText()
    }

    /// Visible viewport text — cheaper than the full scrollback; used to detect
    /// content changes under native PTY.
    func readNativeViewportText() -> String? {
        terminalView.readViewportText()
    }

    func terminalDidRingBell() {
        NSSound.beep()
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        sidebarResizeLog(
            "terminalDidResize grid=\(size.columns)x\(size.rows) " +
            "pixels=\(size.widthPixels)x\(size.heightPixels) " +
            "terminalBounds=\(terminalView.bounds.size)"
        )
        gridMetrics = size
        scrollContainer?.synchronizeScrollState()
        activateOutputFeedWhenSurfaceIsReady()
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
            self.isPreparingOutputReplay = true
            let isReady = self.prepareSurfaceForOutputReplay()
            self.isPreparingOutputReplay = false
            guard isReady else {
                self.scheduleOutputFeedActivationRetry()
                return
            }
            self.outputFeedActivationRetryCount = 0
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

        scrollContainer?.synchronizeScrollState(forceTerminalFrame: true)
        synchronizeMountedSurfaceGeometry()
        if let gridMetrics {
            let sessionViewport = proxy.session?.replayViewportSize
            sidebarResizeLog(
                "prepare replay bounds=\(terminalView.bounds.size) " +
                "grid=\(gridMetrics.columns)x\(gridMetrics.rows) " +
                "pixels=\(gridMetrics.widthPixels)x\(gridMetrics.heightPixels) " +
                "cell=\(gridMetrics.cellWidthPixels)x\(gridMetrics.cellHeightPixels) " +
                "session=\(sessionViewport?.columns ?? 0)x\(sessionViewport?.rows ?? 0)"
            )
        } else {
            sidebarResizeLog("prepare replay skipped: missing grid metrics bounds=\(terminalView.bounds.size)")
        }
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

        if shouldIgnoreTransientStartupShrink(
            columns: Int(gridMetrics.columns),
            rows: Int(gridMetrics.rows)
        ) {
            return true
        }

        resizeSessionIfNeededToMountedGrid(columns: Int(gridMetrics.columns), rows: Int(gridMetrics.rows))
        return true
    }

    private func scheduleOutputFeedActivationRetry() {
        guard !isReleased,
              outputObserverID == nil,
              terminalView.window != nil,
              outputFeedActivationRetryCount < 20
        else {
            return
        }

        outputFeedActivationRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.activateOutputFeedWhenSurfaceIsReady()
        }
    }

    private func synchronizeMountedSurfaceGeometry() {
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
    }

    private func installOutputObserver() {
        guard !isReleased, outputObserverID == nil, let session = proxy.session else { return }

        replayCurrentFrameForMountedGrid(force: true)

        outputObserverID = session.observeRawOutput(replayExistingOutput: false) { [outputSink] data in
            outputSink.receive(data)
        }
        Self.installedOutputObserverCount += 1
        schedulePostAttachGeometryRefresh()
    }

    private func schedulePostAttachGeometryRefresh() {
        postAttachGeometryRefreshGeneration &+= 1
        let generation = postAttachGeometryRefreshGeneration
        for delay in [0.05, 0.15, 0.35, 0.75, 1.25, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.postAttachGeometryRefreshGeneration == generation
                else {
                    return
                }
                self.refreshMountedGeometryAndForceShellResize()
            }
        }
    }

    private func refreshMountedGeometryAndForceShellResize() {
        guard !isReleased, outputObserverID != nil else { return }
        scrollContainer?.synchronizeScrollState(forceTerminalFrame: true)
        synchronizeMountedSurfaceGeometry()
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
            return
        }
        if shouldIgnoreTransientStartupShrink(
            columns: Int(gridMetrics.columns),
            rows: Int(gridMetrics.rows)
        ) {
            return
        }
        resizeSessionIfNeededToMountedGrid(columns: Int(gridMetrics.columns), rows: Int(gridMetrics.rows))
        replayCurrentFrameForMountedGrid(force: true)
    }

    func refreshMountedGeometryAndReplayForSidebarAnimation() {
        refreshMountedGeometryAndForceShellResize()
    }

    private func replayCurrentFrameForMountedGrid(force: Bool) {
        guard let session = proxy.session,
              let gridSize = currentGridSize()
        else {
            return
        }

        guard force || lastReplayedGridSize != gridSize else { return }
        let replayOutput = Self.renderedReplayOutput(for: session)
        if !replayOutput.isEmpty {
            outputSink.receive(replayOutput, suppressHostInput: true)
            synchronizeMountedSurfaceGeometry()
            terminalView.drawImmediately()
        }
        lastReplayedGridSize = gridSize
    }

    private func currentGridSize() -> TerminalViewportSize? {
        guard let gridMetrics,
              gridMetrics.columns > 0,
              gridMetrics.rows > 0
        else {
            return nil
        }

        return TerminalViewportSize(columns: Int(gridMetrics.columns), rows: Int(gridMetrics.rows))
    }

    static func renderedReplayOutput(
        for session: TerminalSession,
        maxBytes: Int = 1_048_576,
        maxLines: Int = 5_000
    ) -> Data {
        session.synchronizeReplayModelIfNeededForRenderedReplay()

        if let cachedOutput = session.cachedRenderedReplayOutput(maxBytes: maxBytes, maxLines: maxLines) {
            return cachedOutput
        }

        let snapshot = renderedReplaySnapshot(for: session, maxBytes: maxBytes, maxLines: maxLines)
        guard !snapshot.lines.isEmpty else {
            session.cacheRenderedReplayOutput(Data(), maxBytes: maxBytes, maxLines: maxLines)
            return Data()
        }

        var chunks: [Data] = []
        chunks.reserveCapacity(snapshot.lines.count)
        var byteCount = 0

        for (index, line) in snapshot.lines.enumerated() {
            var chunk = Data()
            encodeRenderedLine(line, into: &chunk)
            if index < snapshot.lines.count - 1 {
                chunk.append(contentsOf: [0x0D, 0x0A])
            }

            chunks.append(chunk)
            byteCount += chunk.count
            while byteCount > maxBytes, chunks.count > 1 {
                byteCount -= chunks.removeFirst().count
            }
        }

        var output = Data()
        output.reserveCapacity(byteCount + Self.ansiResetData.count * 2 + 64)
        output.append(Self.ansiResetData)
        output.append(Self.ansiResetViewportData)
        output.append(Self.ansiHomeAndClearData)
        output.append(Self.ansiDisableWraparoundData)
        for chunk in chunks {
            output.append(chunk)
        }
        output.append(Self.ansiEnableWraparoundData)
        output.append(Self.ansiResetData)
        appendCursorRestore(
            for: session.cursorState,
            replayStartLine: snapshot.startLine,
            replayLineCount: snapshot.lines.count,
            viewportSize: session.replayViewportSize,
            to: &output
        )
        session.cacheRenderedReplayOutput(output, maxBytes: maxBytes, maxLines: maxLines)
        return output
    }

    private struct RenderedReplaySnapshot {
        let lines: [TerminalRenderedLine]
        let startLine: Int
    }

    private static func renderedReplaySnapshot(
        for session: TerminalSession,
        maxBytes: Int,
        maxLines: Int
    ) -> RenderedReplaySnapshot {
        let totalLines = session.lineCount
        guard totalLines > 0 else {
            return RenderedReplaySnapshot(lines: [], startLine: 0)
        }

        let startLine = max(0, totalLines - maxLines)
        let directLines = session.styledSnapshot(range: startLine..<totalLines)
        guard directLinesNeedStyleRecovery(directLines) else {
            return RenderedReplaySnapshot(lines: directLines, startLine: startLine)
        }

        let styledReplayMaxBytes = min(maxBytes, Self.styledReplayFallbackMaxBytes)
        let rawSnapshot = session.rawOutput(maxBytes: styledReplayMaxBytes)
        let rawOutput = rawSnapshot.data
        guard containsSGRStyleSequence(rawOutput) else {
            return RenderedReplaySnapshot(lines: directLines, startLine: startLine)
        }

        let styledReplayLineLimit = min(
            maxLines,
            max(
                Self.styledReplayFallbackMinimumLines,
                session.replayViewportSize.rows * Self.styledReplayFallbackViewportMultiplier
            )
        )

        let replayLines = styledReplayLines(
            from: rawOutput,
            lineLimit: styledReplayLineLimit,
            viewportSize: session.replayViewportSize,
            rawWasTruncated: rawSnapshot.truncated
        )
        guard !replayLines.isEmpty else {
            return RenderedReplaySnapshot(lines: directLines, startLine: startLine)
        }

        var bestMerge = mergedStyledReplayLines(
            replayLines,
            totalLineCount: totalLines,
            directLines: directLines,
            directStartLine: startLine
        )
        if let queryStart = lastResponseGeneratingQueryStart(in: rawOutput), queryStart > 0 {
            let prefixReplayLines = styledReplayLines(
                from: Data(rawOutput.prefix(queryStart)),
                lineLimit: styledReplayLineLimit,
                viewportSize: session.replayViewportSize,
                rawWasTruncated: rawSnapshot.truncated
            )
            if !prefixReplayLines.isEmpty {
                let prefixMerge = mergedStyledReplayLines(
                    prefixReplayLines,
                    totalLineCount: totalLines,
                    directLines: directLines,
                    directStartLine: startLine
                )
                if prefixMerge.isBetter(than: bestMerge) {
                    bestMerge = prefixMerge
                }
            }
        }

        return RenderedReplaySnapshot(
            lines: bestMerge.lines,
            startLine: startLine
        )
    }

    private struct StyledReplayMerge {
        let lines: [TerminalRenderedLine]
        let incompatibleLineCount: Int
        let styledCompatibleLineCount: Int
        let styledCellCount: Int
        let paintedBackgroundCellCount: Int

        func isBetter(than other: StyledReplayMerge) -> Bool {
            if incompatibleLineCount != other.incompatibleLineCount {
                return incompatibleLineCount < other.incompatibleLineCount
            }
            if paintedBackgroundCellCount != other.paintedBackgroundCellCount {
                return paintedBackgroundCellCount > other.paintedBackgroundCellCount
            }
            if styledCellCount != other.styledCellCount {
                return styledCellCount > other.styledCellCount
            }
            return styledCompatibleLineCount > other.styledCompatibleLineCount
        }
    }

    private static func styledReplayLines(
        from rawOutput: Data,
        lineLimit: Int,
        viewportSize: TerminalViewportSize,
        rawWasTruncated: Bool
    ) -> [TerminalRenderedLine] {
        var styledReplayBuffer = PrototypeTerminalBuffer(maxScrollback: lineLimit)
        styledReplayBuffer.resize(to: viewportSize)
        styledReplayBuffer.ingest(
            sanitizeReplayOutputForHostManagedTerminal(rawOutput),
            viewportSize: viewportSize
        )

        let replayLineCount = styledReplayBuffer.lineCount
        guard replayLineCount > 0 else { return [] }

        let replayStartLine = max(0, replayLineCount - lineLimit)
        var replayLines = styledReplayBuffer.styledSnapshot(range: replayStartLine..<replayLineCount)
        if rawWasTruncated, replayLines.count > 1 {
            replayLines.removeFirst()
        }
        return replayLines
    }

    private static func mergedStyledReplayLines(
        _ replayLines: [TerminalRenderedLine],
        totalLineCount: Int,
        directLines: [TerminalRenderedLine],
        directStartLine: Int
    ) -> StyledReplayMerge {
        let replayOffset = alignedReplayOffset(
            replayLines: replayLines,
            totalLineCount: totalLineCount,
            directLines: directLines,
            directStartLine: directStartLine
        )
        return mergedStyledReplayLines(
            replayLines,
            directLines: directLines,
            replayOffset: replayOffset
        )
    }

    private static func mergedStyledReplayLines(
        _ replayLines: [TerminalRenderedLine],
        directLines: [TerminalRenderedLine],
        replayOffset: Int
    ) -> StyledReplayMerge {
        var mergedLines: [TerminalRenderedLine] = []
        mergedLines.reserveCapacity(directLines.count)
        var incompatibleLineCount = 0
        var styledCompatibleLineCount = 0
        var styledCellCount = 0
        var paintedBackgroundCellCount = 0

        for (offset, directLine) in directLines.enumerated() {
            let replayIndex = replayOffset + offset
            guard replayLines.indices.contains(replayIndex) else {
                if !normalizedReplayText(directLine.plainText).isEmpty {
                    incompatibleLineCount += 1
                }
                mergedLines.append(directLine)
                continue
            }

            let replayLine = replayLines[replayIndex]
            if canUseStyledReplayLine(replayLine, for: directLine) {
                let selectedLine = preferredStyledLine(replayLine, over: directLine)
                if !selectedLine.isPlainDefaultStyled {
                    styledCompatibleLineCount += 1
                }
                if !normalizedReplayText(selectedLine.plainText).isEmpty {
                    styledCellCount += selectedLine.styledCellCount
                    paintedBackgroundCellCount += selectedLine.paintedBackgroundCellCount
                }
                mergedLines.append(selectedLine)
            } else {
                let directText = normalizedReplayText(directLine.plainText)
                let replayText = normalizedReplayText(replayLine.plainText)
                if !directText.isEmpty || !replayText.isEmpty {
                    incompatibleLineCount += 1
                }
                mergedLines.append(directLine)
            }
        }

        return StyledReplayMerge(
            lines: mergedLines,
            incompatibleLineCount: incompatibleLineCount,
            styledCompatibleLineCount: styledCompatibleLineCount,
            styledCellCount: styledCellCount,
            paintedBackgroundCellCount: paintedBackgroundCellCount
        )
    }

    private static func alignedReplayOffset(
        replayLines: [TerminalRenderedLine],
        totalLineCount: Int,
        directLines: [TerminalRenderedLine],
        directStartLine: Int
    ) -> Int {
        guard !replayLines.isEmpty, !directLines.isEmpty else { return 0 }

        let expectedReplayStartLine = max(0, totalLineCount - replayLines.count)
        let expectedOffset = expectedReplayStartLine - directStartLine
        let minimumOffset = -directLines.count + 1
        let maximumOffset = replayLines.count - 1

        var replayIndicesByText: [String: [Int]] = [:]
        for (index, line) in replayLines.enumerated() {
            let text = normalizedReplayText(line.plainText)
            guard !text.isEmpty else { continue }
            replayIndicesByText[text, default: []].append(index)
        }

        var matchCountsByOffset: [Int: Int] = [:]
        for (directIndex, directLine) in directLines.enumerated() {
            let text = normalizedReplayText(directLine.plainText)
            guard !text.isEmpty, let replayIndices = replayIndicesByText[text] else { continue }
            for replayIndex in replayIndices {
                let candidateOffset = replayIndex - directIndex
                guard candidateOffset >= minimumOffset, candidateOffset <= maximumOffset else { continue }
                matchCountsByOffset[candidateOffset, default: 0] += 1
            }
        }

        var candidateOffsets = Set<Int>()
        candidateOffsets.insert(min(max(expectedOffset, minimumOffset), maximumOffset))
        candidateOffsets.insert(min(max(0, minimumOffset), maximumOffset))
        for offset in matchCountsByOffset
            .sorted(by: { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return abs(lhs.key - expectedOffset) < abs(rhs.key - expectedOffset)
            })
            .prefix(8)
            .map(\.key)
        {
            candidateOffsets.insert(offset)
        }

        let sortedCandidateOffsets = candidateOffsets.sorted { lhs, rhs in
            if abs(lhs - expectedOffset) != abs(rhs - expectedOffset) {
                return abs(lhs - expectedOffset) < abs(rhs - expectedOffset)
            }
            return lhs < rhs
        }
        var bestOffset = sortedCandidateOffsets.first ?? expectedOffset
        var bestMerge = mergedStyledReplayLines(
            replayLines,
            directLines: directLines,
            replayOffset: bestOffset
        )
        for offset in sortedCandidateOffsets.dropFirst() {
            let merge = mergedStyledReplayLines(
                replayLines,
                directLines: directLines,
                replayOffset: offset
            )
            if merge.isBetter(than: bestMerge) {
                bestOffset = offset
                bestMerge = merge
            }
        }
        return bestOffset
    }

    private static func canUseStyledReplayLine(
        _ replayLine: TerminalRenderedLine,
        for directLine: TerminalRenderedLine
    ) -> Bool {
        normalizedReplayText(replayLine.plainText) == normalizedReplayText(directLine.plainText)
    }

    private static func preferredStyledLine(
        _ replayLine: TerminalRenderedLine,
        over directLine: TerminalRenderedLine
    ) -> TerminalRenderedLine {
        // The merge exists to RECOVER lost styling, never to downgrade a correctly styled
        // direct line. The background/styled-cell heuristics below would otherwise prefer a
        // re-parsed replay line that merely paints more background cells even when it has no
        // real foreground color, dropping the direct line's foreground (the "colors lost on
        // tab switch / resize" regression). Keep whichever side actually carries a foreground
        // when only one of them does; only fall through to the cell-count tie-breaks when the
        // foreground signal is equivalent.
        let replayHasForeground = replayLine.hasRealForeground
        let directHasForeground = directLine.hasRealForeground
        if replayHasForeground != directHasForeground {
            return directHasForeground ? directLine : replayLine
        }
        if replayLine.paintedBackgroundCellCount != directLine.paintedBackgroundCellCount {
            return replayLine.paintedBackgroundCellCount > directLine.paintedBackgroundCellCount
                ? replayLine
                : directLine
        }
        if replayLine.styledCellCount != directLine.styledCellCount {
            return replayLine.styledCellCount > directLine.styledCellCount
                ? replayLine
                : directLine
        }

        return directLine
    }

    private static func directLinesNeedStyleRecovery(_ lines: [TerminalRenderedLine]) -> Bool {
        lines.contains { line in
            !normalizedReplayText(line.plainText).isEmpty && line.hasDefaultStyledText
        }
    }

    private static func normalizedReplayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let text = replayText(for: run)
            guard !text.isEmpty else { continue }

            if run.style != currentStyle {
                appendSGR(for: run.style, to: &output)
                currentStyle = run.style
            }
            output.append(Data(text.utf8))
        }
        if currentStyle != TerminalTextStyle() {
            output.append(Self.ansiResetData)
        }
    }

    private static func replayText(for run: TerminalTextRun) -> String {
        if !run.text.isEmpty {
            return run.text
        }
        guard run.cellWidth > 0, run.style.paintsBackground else { return "" }
        return String(repeating: " ", count: run.cellWidth)
    }

    private static let ansiResetData = Data("\u{1B}[0m".utf8)
    private static let ansiResetViewportData = Data("\u{1B}[?6l\u{1B}[r\u{1B}[?69l".utf8)
    private static let ansiHomeAndClearData = Data("\u{1B}[H\u{1B}[J".utf8)
    private static let ansiDisableWraparoundData = Data("\u{1B}[?7l".utf8)
    private static let ansiEnableWraparoundData = Data("\u{1B}[?7h".utf8)
    private static let styledReplayFallbackMaxBytes = 256 * 1024
    private static let styledReplayFallbackMinimumLines = 200
    private static let styledReplayFallbackViewportMultiplier = 4

    private static func appendCursorRestore(
        for cursor: TerminalCursorState,
        replayStartLine: Int,
        replayLineCount: Int,
        viewportSize: TerminalViewportSize,
        to output: inout Data
    ) {
        let viewportRows = max(1, viewportSize.rows)
        let visibleReplayStartLine = replayStartLine + max(0, replayLineCount - viewportRows)
        let maximumReplayRow = min(viewportRows - 1, max(0, replayLineCount - 1))
        let row = min(max(cursor.row - visibleReplayStartLine, 0), maximumReplayRow)
        let maximumColumn = max(0, viewportSize.columns - 1)
        let column = min(max(cursor.column, 0), maximumColumn)

        output.append(Data("\u{1B}[\(row + 1);\(column + 1)H".utf8))
        output.append(Data(cursorShapeSequence(for: cursor.shape).utf8))
        output.append(cursor.isVisible ? Self.ansiShowCursorData : Self.ansiHideCursorData)
    }

    private static func cursorShapeSequence(for shape: TerminalCursorShape) -> String {
        switch shape {
        case .block:
            "\u{1B}[2 q"
        case .underline:
            "\u{1B}[4 q"
        case .bar:
            "\u{1B}[6 q"
        }
    }

    private static let ansiShowCursorData = Data("\u{1B}[?25h".utf8)
    private static let ansiHideCursorData = Data("\u{1B}[?25l".utf8)

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
        // relies on that default foreground for styled text, a freshly rebuilt
        // Ghostty surface can otherwise render it too dark to read.
        if style.background != nil || style.isDim {
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

    static func dispatchDetachedResizeForTesting(
        session: TerminalSession,
        viewport: InMemoryTerminalViewport
    ) {
        let proxy = GhosttySessionProxy(session: session)
        proxy.resize(viewport)
    }

    private func uninstallOutputObserver() {
        guard let outputObserverID else { return }
        proxy.session?.removeRawOutputObserver(id: outputObserverID)
        self.outputObserverID = nil
        lastReplayedGridSize = nil
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
        lastReplayedGridSize = nil
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

    nonisolated private static func lastResponseGeneratingQueryStart(in data: Data) -> Int? {
        guard !data.isEmpty else { return nil }

        let bytes = Array(data)
        var lastQueryStart: Int?
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case UInt8(ascii: "]"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isResponseGeneratingOSCQuery(payload) {
                            lastQueryStart = index
                        }
                        index = bounds.endIndex
                        continue
                    }
                case UInt8(ascii: "["):
                    if let finalIndex = csiFinalIndex(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<finalIndex]
                        let finalByte = bytes[finalIndex]
                        if isResponseGeneratingCSIQuery(payload, finalByte: finalByte) {
                            lastQueryStart = index
                        }
                        index = finalIndex + 1
                        continue
                    }
                case UInt8(ascii: "P"):
                    if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                        let payload = bytes[index + 2..<bounds.payloadEnd]
                        if isResponseGeneratingDCSQuery(payload) {
                            lastQueryStart = index
                        }
                        index = bounds.endIndex
                        continue
                    }
                default:
                    break
                }
            }

            index += 1
        }

        return lastQueryStart
    }

    nonisolated fileprivate static func stripZshPromptEndOfLineMarks(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        guard data.contains(0x1B),
              data.contains(UInt8(ascii: "%")) || data.contains(UInt8(ascii: "#"))
        else {
            return data
        }

        let bytes = Array(data)
        var stripped: [UInt8] = []
        stripped.reserveCapacity(bytes.count)

        var index = 0
        var didStrip = false
        // Tracks whether a visible glyph has already been drawn on the current row before
        // `index`. zsh's PROMPT_EOL_MARK only legitimately appears at the start of a row
        // (on its own line). When real partial-line output precedes the mark on the same
        // row — e.g. `printf foo` with no trailing newline, or a mid-line inverse `%` in a
        // progress bar — collapsing it to `\r\x1b[K` would erase that output (the carriage
        // return rewinds to column 0 and the erase-to-end clears the row). Leave such
        // occurrences untouched so legitimate characters are never destroyed.
        var rowHasPrintableContent = false
        while index < bytes.count {
            if !rowHasPrintableContent,
               let markEnd = zshPromptEndOfLineMarkEnd(in: bytes, at: index) {
                didStrip = true
                stripped.append(UInt8(ascii: "\r"))
                stripped.append(contentsOf: [0x1B, UInt8(ascii: "["), UInt8(ascii: "K")])
                index = markEnd
                rowHasPrintableContent = false
                continue
            }

            let byte = bytes[index]
            if byte == 0x1B {
                // Copy escape/control sequences verbatim, but do not let their internal
                // bytes (which are printable ASCII like `[`, `m`, digits) count as drawn
                // glyphs for the row-start check.
                let sequenceEnd = escapeSequenceEndIndex(in: bytes, at: index)
                stripped.append(contentsOf: bytes[index..<sequenceEnd])
                index = sequenceEnd
                continue
            }

            switch byte {
            case 0x0A, 0x0D:
                rowHasPrintableContent = false
            case 0x08:
                break // backspace moves the cursor but leaves drawn content on the row
            default:
                if byte >= 0x20, byte != 0x7F {
                    rowHasPrintableContent = true
                }
            }

            stripped.append(byte)
            index += 1
        }

        return didStrip ? Data(stripped) : data
    }

    /// Returns the index immediately past the escape sequence beginning at `index`
    /// (where `bytes[index] == 0x1B`). Handles CSI (`ESC [ … final`), string sequences
    /// (OSC/DCS/PM/APC terminated by BEL or ST) and two-byte escapes. Used to skip over
    /// non-printing control sequences when scanning for drawn content.
    nonisolated private static func escapeSequenceEndIndex(in bytes: [UInt8], at index: Int) -> Int {
        guard index + 1 < bytes.count else { return bytes.count }
        switch bytes[index + 1] {
        case UInt8(ascii: "["):
            if let finalIndex = csiFinalIndex(in: bytes, payloadStart: index + 2) {
                return finalIndex + 1
            }
            return bytes.count
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            if let bounds = oscSequenceBounds(in: bytes, payloadStart: index + 2) {
                return bounds.endIndex
            }
            return bytes.count
        default:
            return index + 2
        }
    }

    nonisolated fileprivate static func endsWithIncompleteZshPromptEndOfLineMark(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }

        let bytes = Array(data.suffix(512))
        for index in bytes.indices where bytes[index] == 0x1B {
            if isIncompleteZshPromptEndOfLineMarkPrefix(in: bytes, at: index) {
                return true
            }
        }

        return false
    }

    nonisolated private static func isIncompleteZshPromptEndOfLineMarkPrefix(
        in bytes: [UInt8],
        at index: Int
    ) -> Bool {
        var scan = index
        var sawAnySGR = false
        var sawInverse = false
        leadingSGRs: while true {
            switch sgrSequencePrefix(in: bytes, at: scan) {
            case .complete(let endIndex, let containsInverse, _):
                sawAnySGR = true
                sawInverse = sawInverse || containsInverse
                scan = endIndex
            case .incomplete:
                return sawAnySGR || scan == index
            case .noMatch:
                break leadingSGRs
            }
        }

        guard sawInverse else { return false }
        guard scan < bytes.count else { return true }
        guard bytes[scan] == UInt8(ascii: "%") || bytes[scan] == UInt8(ascii: "#") else {
            return false
        }
        scan += 1
        guard scan < bytes.count else { return true }

        var sawReset = false
        trailingSGRs: while true {
            switch sgrSequencePrefix(in: bytes, at: scan) {
            case .complete(let endIndex, _, let containsResetOrInverseOff):
                sawReset = sawReset || containsResetOrInverseOff
                scan = endIndex
            case .incomplete:
                return true
            case .noMatch:
                break trailingSGRs
            }
        }

        guard sawReset else { return false }
        while scan < bytes.count, bytes[scan] == UInt8(ascii: " ") {
            scan += 1
        }
        guard scan < bytes.count else { return true }
        guard bytes[scan] == UInt8(ascii: "\r") else { return false }

        scan += 1
        guard scan < bytes.count else { return true }
        if bytes[scan] == UInt8(ascii: " ") {
            return scan + 1 == bytes.count
        }

        return false
    }

    nonisolated private static func zshPromptEndOfLineMarkEnd(
        in bytes: [UInt8],
        at index: Int
    ) -> Int? {
        var scan = index
        var sawInverse = false
        while let sequence = sgrSequence(in: bytes, at: scan) {
            sawInverse = sawInverse || sequence.containsInverse
            scan = sequence.endIndex
        }

        guard sawInverse,
              scan < bytes.count,
              bytes[scan] == UInt8(ascii: "%") || bytes[scan] == UInt8(ascii: "#")
        else {
            return nil
        }
        scan += 1

        var sawReset = false
        while let sequence = sgrSequence(in: bytes, at: scan) {
            sawReset = sawReset || sequence.containsResetOrInverseOff
            scan = sequence.endIndex
        }
        guard sawReset else { return nil }

        while scan < bytes.count, bytes[scan] == UInt8(ascii: " ") {
            scan += 1
        }

        guard scan < bytes.count,
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

    private enum SGRSequencePrefix {
        case complete(endIndex: Int, containsInverse: Bool, containsResetOrInverseOff: Bool)
        case incomplete
        case noMatch
    }

    nonisolated private static func sgrSequencePrefix(
        in bytes: [UInt8],
        at index: Int
    ) -> SGRSequencePrefix {
        guard index < bytes.count, bytes[index] == 0x1B else {
            return .noMatch
        }
        guard index + 1 < bytes.count else {
            return .incomplete
        }
        guard bytes[index + 1] == UInt8(ascii: "[") else {
            return .noMatch
        }
        guard index + 2 < bytes.count else {
            return .incomplete
        }

        var scan = index + 2
        while scan < bytes.count {
            let byte = bytes[scan]
            if byte == UInt8(ascii: "m") {
                let payload = bytes[(index + 2)..<scan]
                let codes = String(decoding: payload, as: UTF8.self)
                    .split(whereSeparator: { $0 == ";" || $0 == ":" })
                let normalizedCodes = codes.isEmpty ? ["0"] : codes.map(String.init)
                let flags = sgrFlags(in: normalizedCodes)
                return .complete(
                    endIndex: scan + 1,
                    containsInverse: flags.containsInverse,
                    containsResetOrInverseOff: flags.containsResetOrInverseOff
                )
            }
            guard (0x30...0x3F).contains(byte) else { return .noMatch }
            scan += 1
        }

        return .incomplete
    }

    nonisolated private static func sgrSequence(
        in bytes: [UInt8],
        at index: Int
    ) -> (endIndex: Int, containsInverse: Bool, containsResetOrInverseOff: Bool)? {
        guard index + 2 < bytes.count,
              bytes[index] == 0x1B,
              bytes[index + 1] == UInt8(ascii: "[")
        else {
            return nil
        }

        var scan = index + 2
        while scan < bytes.count {
            let byte = bytes[scan]
            if byte == UInt8(ascii: "m") {
                let payload = bytes[(index + 2)..<scan]
                let codes = String(decoding: payload, as: UTF8.self)
                    .split(whereSeparator: { $0 == ";" || $0 == ":" })
                let normalizedCodes = codes.isEmpty ? ["0"] : codes.map(String.init)
                let flags = sgrFlags(in: normalizedCodes)
                return (
                    endIndex: scan + 1,
                    containsInverse: flags.containsInverse,
                    containsResetOrInverseOff: flags.containsResetOrInverseOff
                )
            }
            guard (0x30...0x3F).contains(byte) else { return nil }
            scan += 1
        }

        return nil
    }

    nonisolated private static func sgrFlags(
        in codes: [String]
    ) -> (containsInverse: Bool, containsResetOrInverseOff: Bool) {
        var containsInverse = false
        var containsResetOrInverseOff = false
        var index = 0

        while index < codes.count {
            let code = codes[index].isEmpty ? "0" : codes[index]
            switch code {
            case "0":
                containsResetOrInverseOff = true
                index += 1
            case "7":
                containsInverse = true
                index += 1
            case "27":
                containsResetOrInverseOff = true
                index += 1
            case "38", "48", "58":
                if index + 1 < codes.count {
                    switch codes[index + 1] {
                    case "2":
                        index += 5
                    case "5":
                        index += 3
                    default:
                        index += 2
                    }
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }

        return (containsInverse, containsResetOrInverseOff)
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
        if shouldIgnoreTransientStartupShrink(
            columns: Int(viewport.columns),
            rows: Int(viewport.rows)
        ) {
            return
        }

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

        sidebarResizeLog(
            "host resize accepted viewport=\(viewport.columns)x\(viewport.rows) " +
            "pixels=\(viewport.widthPixels)x\(viewport.heightPixels) " +
            "terminalBounds=\(terminalView.bounds.size)"
        )
        resizeSessionIfNeededToMountedGrid(columns: Int(viewport.columns), rows: Int(viewport.rows))
    }

    private func resizeSessionIfNeededToMountedGrid(columns: Int, rows: Int) {
        guard let session = proxy.session else { return }
        let currentViewport = session.replayViewportSize
        guard Self.shouldResizeSession(from: currentViewport, toColumns: columns, rows: rows) else {
            sidebarResizeLog("skip unchanged shell resize viewport=\(columns)x\(rows)")
            return
        }

        session.resize(columns: columns, rows: rows)
    }

    nonisolated static func shouldResizeSession(
        from currentViewport: TerminalViewportSize,
        toColumns columns: Int,
        rows: Int
    ) -> Bool {
        currentViewport.columns != columns || currentViewport.rows != rows
    }

    private func shouldIgnoreTransientStartupShrink(columns: Int, rows: Int) -> Bool {
        guard let attachedAt,
              Date().timeIntervalSince(attachedAt) < Self.transientStartupShrinkInterval,
              let currentViewport = proxy.session?.replayViewportSize
        else {
            return false
        }

        if scrollContainer?.isApplyingSidebarGeometryChangeForBridge == true {
            sidebarResizeLog(
                "accept sidebar geometry resize current=\(currentViewport.columns)x\(currentViewport.rows) " +
                "incoming=\(columns)x\(rows)"
            )
            return false
        }

        let minimumColumnDelta = max(8, Int((Double(currentViewport.columns) * 0.2).rounded(.up)))
        let minimumRowDelta = max(4, Int((Double(currentViewport.rows) * 0.2).rounded(.up)))
        let collapsedColumns = currentViewport.columns - columns >= minimumColumnDelta
        let collapsedRows = currentViewport.rows - rows >= minimumRowDelta
        guard collapsedColumns || collapsedRows else { return false }

        sidebarResizeLog(
            "reject transient startup shrink current=\(currentViewport.columns)x\(currentViewport.rows) " +
            "incoming=\(columns)x\(rows)"
        )
        return true
    }

    private func isViewportConsistentWithMountedSurface(
        columns: Int,
        rows: Int,
        widthPixels: Int,
        heightPixels: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int
    ) -> Bool {
        guard !isReleased, columns > 0, rows > 0 else {
            sidebarResizeLog("reject viewport: released=\(isReleased) size=\(columns)x\(rows)")
            return false
        }
        guard scrollContainer != nil,
              terminalView.superview != nil,
              let window = terminalView.window
        else {
            sidebarResizeLog("reject viewport: surface not mounted")
            return false
        }

        let bounds = terminalView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            sidebarResizeLog("reject viewport: empty bounds=\(bounds.size)")
            return false
        }

        let expectedWidthPixels = bounds.width * window.backingScaleFactor
        let expectedHeightPixels = bounds.height * window.backingScaleFactor

        if widthPixels > 0, expectedWidthPixels >= 200 {
            let cellTolerance = CGFloat(max(cellWidthPixels, 1) * 2)
            let tolerance = max(cellTolerance, expectedWidthPixels * 0.08)
            if abs(CGFloat(widthPixels) - expectedWidthPixels) > tolerance {
                sidebarResizeLog(
                    "reject viewport: width pixels actual=\(widthPixels) " +
                    "expected=\(expectedWidthPixels) tolerance=\(tolerance)"
                )
                return false
            }
        }

        if heightPixels > 0, expectedHeightPixels >= 200 {
            let cellTolerance = CGFloat(max(cellHeightPixels, 1) * 2)
            let tolerance = max(cellTolerance, expectedHeightPixels * 0.08)
            if abs(CGFloat(heightPixels) - expectedHeightPixels) > tolerance {
                sidebarResizeLog(
                    "reject viewport: height pixels actual=\(heightPixels) " +
                    "expected=\(expectedHeightPixels) tolerance=\(tolerance)"
                )
                return false
            }
        }

        if cellWidthPixels > 0 {
            let expectedColumns = Int(expectedWidthPixels / CGFloat(cellWidthPixels))
            let tolerance = max(2, Int((CGFloat(expectedColumns) * 0.08).rounded(.up)))
            if expectedColumns >= 40, abs(columns - expectedColumns) > tolerance {
                sidebarResizeLog(
                    "reject viewport: columns actual=\(columns) " +
                    "expected=\(expectedColumns) tolerance=\(tolerance)"
                )
                return false
            }
        }

        if cellHeightPixels > 0 {
            let expectedRows = Int(expectedHeightPixels / CGFloat(cellHeightPixels))
            let tolerance = max(2, Int((CGFloat(expectedRows) * 0.08).rounded(.up)))
            if expectedRows >= 20, abs(rows - expectedRows) > tolerance {
                sidebarResizeLog(
                    "reject viewport: rows actual=\(rows) " +
                    "expected=\(expectedRows) tolerance=\(tolerance)"
                )
                return false
            }
        }

        return true
    }

    /// Ghostty's native-PTY model — **the default**. Surfaces use the EXEC backend
    /// (ghostty owns the PTY/Screen) instead of host-managed in-memory feeding, so
    /// replay is impossible by construction. Force the legacy host-managed (replay)
    /// path with `CHERRY_NATIVE_PTY=0` or `-DCHERRY_DISABLE_NATIVE_PTY`.
    static let nativePTYEnabled: Bool = {
        if let raw = ProcessInfo.processInfo.environment["CHERRY_NATIVE_PTY"] {
            // Explicit override: 0/false/no/off forces the legacy host-managed
            // (replay) path; anything else keeps native on.
            return !["0", "false", "no", "off"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
        }
        // Native-PTY is the default: the ghostty surface owns the PTY (no replay).
        // Build the legacy host-managed path with `-DCHERRY_DISABLE_NATIVE_PTY`.
        #if CHERRY_DISABLE_NATIVE_PTY
        return false
        #else
        return true
        #endif
    }()

    private static func makeOptions(
        for session: TerminalSession,
        inMemorySession: InMemoryTerminalSession
    ) -> TerminalSurfaceOptions {
        // Native-PTY mode (CHERRY_NATIVE_PTY): the ghostty surface owns the PTY
        // (spawns Cherry's resolved shell + env in the cwd) instead of Cherry
        // feeding bytes to an in-memory session. EXEC means there is no
        // host->surface output path, so replay is impossible by construction.
        let native = Self.nativePTYEnabled ? session.nativeExecLaunch : nil
        return TerminalSurfaceOptions(
            backend: Self.nativePTYEnabled ? .exec : .inMemory(inMemorySession),
            workingDirectory: session.workingDirectory,
            context: .window,
            execCommand: native?.command,
            execEnvironment: native?.environment ?? [:]
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

    var isApplyingSidebarGeometryChangeForBridge: Bool {
        isSidebarAnimating || isSyncFrozen || didApplyEarlyFit
    }

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
                if GhosttySessionBridge.liveSurfaceLimit != nil {
                    // Park the outgoing surface in the live-surface LRU instead of
                    // tearing it down; its bridge stays owned by the session so a
                    // switch-back re-shows it with no replay.
                    activeSession.detachGhosttyBridge(from: self, preservingSurface: true)
                } else {
                    activeSession.detachGhosttyBridge(from: self)
                    activeSession.releaseGhosttyBridge()
                }
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

    func synchronizeScrollState(forceTerminalFrame: Bool = false) {
        guard let terminalView = activeBridge?.terminalView else { return }
        if forceTerminalFrame {
            scrollView.frame = bounds
            scrollView.layoutSubtreeIfNeeded()
        }

        // This runs after every rendered frame (scrollbar updates) and on
        // every keystroke, so skip the AppKit mutations when nothing moved —
        // `reflectScrolledClipView` alone dirties window-restoration state
        // and re-evaluates scroller visibility each call.
        var scrollStateChanged = false

        let documentSize = NSSize(
            width: max(scrollView.contentSize.width, bounds.width),
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
            synchronizeTerminalFrame(terminalView, force: forceTerminalFrame)
        }
        if activeBridge?.isPreparingOutputReplay != true {
            activeBridge?.activateOutputFeedWhenSurfaceIsReady()
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
        if didApplyEarlyFit {
            activeBridge?.refreshMountedGeometryAndReplayForSidebarAnimation()
            refreshSnapshotContentsAfterEarlyFitIfPossible()
        }
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

        activeBridge?.refreshMountedGeometryAndReplayForSidebarAnimation()
        refreshSnapshotContentsAfterEarlyFitIfPossible()

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

        terminalView.setFrameOrigin(.zero)
        terminalView.setFrameSize(targetSize)
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
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

    private func refreshSnapshotContentsAfterEarlyFitIfPossible() {
        guard let snapshotLayer,
              let terminalView = activeBridge?.terminalView,
              scrollView.bounds.width > 0,
              scrollView.bounds.height > 0
        else {
            return
        }

        let visibleOrigin = scrollView.contentView.bounds.origin
        let captureSize = NSSize(
            width: max(scrollView.bounds.width, terminalView.frame.width),
            height: scrollView.bounds.height
        )
        let captureRect = NSRect(origin: visibleOrigin, size: captureSize)
        guard let cgImage = captureViewBitmap(documentView, rect: captureRect) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.contents = cgImage
        if let scale = window?.backingScaleFactor {
            snapshotLayer.contentsScale = scale
        }
        CATransaction.commit()
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
        let fadingLayer = snapshotLayer

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingLayer.opacity
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            fadingLayer.removeFromSuperlayer()
            if self?.snapshotLayer === fadingLayer {
                self?.snapshotLayer = nil
            }
        }
        fadingLayer.opacity = 0
        fadingLayer.add(fade, forKey: "fadeOut")
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
        // Native-PTY: the ghostty surface owns the PTY and encodes its own keyboard
        // input — arrows, paste, option-combos, kitty protocol, app-cursor-keys
        // mode — exactly like standalone ghostty. This monitor exists only because
        // the host-managed surface is a pure renderer that doesn't own input; under
        // EXEC it would double-encode (e.g. arrows would arrive at the shell as
        // literal escape text via the text path). Let the event fall through.
        if GhosttySessionBridge.nativePTYEnabled { return false }
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

        if let data = TerminalInputEncoder.appKitOptionDigitTextData(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            keyboardProtocolFlags: activeSession.keyboardProtocolFlags
        ) {
            activeBridge?.scrollToBottomForHostInput()
            activeSession.send(data: data)
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

    private func synchronizeTerminalFrame(_ terminalView: TerminalView, force: Bool = false) {
        let visibleRect = scrollView.contentView.documentVisibleRect
        let targetFrame = NSRect(
            origin: visibleRect.origin,
            size: CGSize(
                width: max(scrollView.contentSize.width, bounds.width),
                height: max(scrollView.contentSize.height, bounds.height)
            )
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
        guard force || widthDelta > 1.0 || heightDelta > 1.0 || originDelta > 1.0 else { return }

        sidebarResizeLog("synchronizeTerminalFrame -> \(targetFrame.size)")
        terminalView.setFrameOrigin(targetFrame.origin)
        terminalView.setFrameSize(targetFrame.size)
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
        TerminalPerformanceMonitor.recordFitToSize()
        terminalView.fitToSize()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = max(scrollView.contentSize.height, bounds.height)
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

    var sidebarSnapshotIdentityForTesting: ObjectIdentifier? {
        snapshotLayer.map(ObjectIdentifier.init)
    }

    var isSidebarSyncFrozenForTesting: Bool {
        isSyncFrozen
    }

    var isSidebarAnimationActiveForTesting: Bool {
        isSidebarAnimating
    }

    func crossfadeSidebarSnapshotForTesting() {
        crossfadeOutSnapshotLayer()
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

private extension TerminalRenderedLine {
    var hasDefaultStyledText: Bool {
        runs.contains { !$0.text.isEmpty && $0.style == TerminalTextStyle() }
    }

    var hasRealForeground: Bool {
        runs.contains { !$0.text.isEmpty && $0.style.foreground != nil }
    }

    var styledCellCount: Int {
        runs.reduce(0) { count, run in
            run.style == TerminalTextStyle() ? count : count + run.cellWidth
        }
    }

    var paintedBackgroundCellCount: Int {
        runs.reduce(0) { count, run in
            run.style.paintsBackground ? count + run.cellWidth : count
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
