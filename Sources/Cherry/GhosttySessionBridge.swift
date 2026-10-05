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
    TerminalSurfaceLinkHoverDelegate, TerminalSurfaceOpenURLDelegate, TerminalSurfacePastedImageDelegate,
    TerminalSurfaceSearchDelegate, TerminalSurfaceHostInputDelegate,
    TerminalSurfaceScrollInputDelegate, TerminalSurfaceClipboardConfirmationDelegate,
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
    private(set) var attachCountForTesting = 0
    fileprivate var isPreparingOutputReplay = false
    private var postAttachGeometryRefreshGeneration = 0
    private var attachedAt: Date?
    private var lastReplayedGridSize: TerminalViewportSize?
    private var activeColorScheme: ColorScheme?
    private nonisolated(unsafe) var settingsObserver: Any?
    private nonisolated(unsafe) var windowSettlingObserver: Any?
    private(set) var gridMetrics: TerminalGridMetrics?
    private(set) var scrollbarMetrics: TerminalScrollbarMetrics?
    private weak var scrollContainer: GhosttyTerminalContainerView?
    private weak var searchState: TerminalSearchState?
    private var searchPresentationHandler: ((String?) -> Void)?
    private var searchDismissalHandler: (() -> Void)?
    private var pointerStyle: TerminalPointerStyle = .text
    private var hoveredLink: String?
    private var isReleased = false
    private(set) var isNativePTYBacked: Bool
    private var detachedSurfaceReleaseTask: Task<Void, Never>?
    private var settledRenderHandler: (() -> Void)?
    private var settledRenderTask: Task<Void, Never>?
    private var settledRenderGeneration: UInt64 = 0
    private var hasRenderedSinceSettledRenderRequest = false
    private var isScrollbarSynchronizationScheduled = false
    private var didLogLaunchContent = false
    private var launchContentCheck = LaunchContentCheck()

    init(session: TerminalSession) {
        let proxy = GhosttySessionProxy(session: session)
        let inMemorySession = Self.makeInMemorySession(proxy: proxy)
        let isNativePTYBacked = session.usesNativePTYBackend
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
        // A surface built while no view shows it (a restored tab's adapter
        // launching in the background) takes the size its window's terminal
        // has at the window's grid, so its program attaches at the size the
        // tab is shown at (`TerminalSession.detachedSurfaceSize`); Ghostty's
        // default otherwise.
        self.terminalView = TerminalView(frame: NSRect(origin: .zero, size: session.detachedSurfaceSize?() ?? .zero))
        self.appliedTerminalConfiguration = terminalConfiguration
        self.appliedTerminalTheme = terminalTheme
        self.isNativePTYBacked = isNativePTYBacked

        super.init()

        Self.liveBridgeCount += 1
        terminalView.delegate = self
        // Files dropped on a tab of another Mac are copied there first
        // (`RemoteFileDropCoordinator`), never inserted as This Mac's paths.
        terminalView.dropHandler = { [weak self] pasteboard in
            MainActor.assumeIsolated { self?.handleRemoteFiles(pasteboard, isPaste: false) ?? false }
        }
        // Edit › Paste: images, files and host-routed input are Cherry's,
        // as ⌘V (the window's key monitor) is.
        terminalView.pasteHandler = { [weak self] in
            MainActor.assumeIsolated { self?.handleMenuPaste(TerminalClipboard.pasteboard()) ?? false }
        }
        terminalView.onPostRender = { [weak self] in
            TerminalPerformanceMonitor.recordRenderTick()
            self?.handlePostRender()
            self?.noteLaunchContentFrame()
            if let self { LaunchInteractivity.noteFrame(of: self) }
        }
        if isNativePTYBacked {
            // Native eagerly creates the EXEC surface below, which spawns
            // the child immediately. A background-spawned agent queries the terminal
            // background (OSC 11) for its very first render, so the theme/scheme must
            // be on the controller BEFORE the surface exists — otherwise that first
            // prompt renders with ghostty's default (light) background while later
            // output is correct. The displaying container re-applies the real scheme.
            activeColorScheme = Self.resolvedColorScheme()
            applyTerminalSettings()
        }
        // The tab's options go on before the controller: the view builds a
        // surface as soon as it has a controller, from the options it has
        // then. Before them it has the default options, an EXEC surface of
        // Ghostty's default command, so each bridge started the user's login
        // shell only to kill it a moment later, and replaced that surface in
        // the same main-thread turn, which lets the freed surface's queued
        // messages reach its replacement (see `relaunchNativeSurface`).
        terminalView.configuration = Self.makeOptions(
            for: session,
            inMemorySession: inMemorySession,
            useNativePTY: isNativePTYBacked
        )
        terminalView.controller = controller
        proxy.bridge = self
        observeSettingsChanges()
        observeWindowSettling()
    }

    static func resolvedColorScheme() -> ColorScheme {
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
        // No application object (a test process): dark, the terminal default.
        guard let app = NSApp else { return .dark }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    func attach(to container: GhosttyTerminalContainerView) {
        guard !isReleased else { return }
        attachCountForTesting += 1
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
        // In a window that may be settling, or no longer.
        announceAdapterWindowSize()
        reportWindowGrid()
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: GhosttyTerminalContainerView, preservingSurface: Bool = false) {
        guard !isReleased, scrollContainer === container else { return }
        cancelSettledRenderHandler()
        let canPreserveSurface = preservingSurface
            && container.bounds.width > 0
            && container.bounds.height > 0
        terminalView.setSurfaceVisible(false)
        container.uninstall(terminalView: terminalView)
        terminalView.removeFromSuperview()
        scrollContainer = nil
        // Out of a window that may be settling: its size is the one it keeps.
        announceAdapterWindowSize()
        if isNativePTYBacked {
            // EXEC surface == live child process. Never free it on detach (that
            // would kill a running agent/command); keep it parked and alive so a
            // non-active tab keeps running. Freed only when the session closes.
            cancelDetachedSurfaceRelease()
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

    var isTerminalFocused: Bool {
        guard let window = terminalView.window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.firstResponder === terminalView
    }

    func applyTerminalSettings(colorScheme: ColorScheme) {
        activeColorScheme = colorScheme
        applyTerminalColorSchemeIfNeeded()
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

        // Every reset is followed by startShell, which rebuilds a native surface
        // with fresh options. Assigning them here would rebuild it once more
        // when they changed (after a `cd` or a command edit), spawning an extra
        // shell or command that the relaunch kills straight away.
        if !isNativePTYBacked, let terminalSession = proxy.session {
            terminalView.configuration = Self.makeOptions(
                for: terminalSession,
                inMemorySession: nextSession,
                useNativePTY: false
            )
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
        if isNativePTYBacked, !terminalView.isMouseCaptured,
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
        uninstallWindowSettlingObserver()
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
        cancelSettledRenderHandler()
        searchState = nil
        searchPresentationHandler = nil
        searchDismissalHandler = nil
        terminalView.freeSurface()
        terminalView.controller = nil
    }

    func finish(exitCode: UInt32) {
        inMemorySession.finish(exitCode: exitCode, runtimeMilliseconds: 0)
    }

    func performAfterRenderedViewportSettles(_ handler: @escaping () -> Void) {
        cancelSettledRenderHandler()
        settledRenderHandler = handler
    }

    /// Logs, once per surface and only during the launch, the first frame
    /// that shows text in an on-screen window (`LaunchTimeline`: "first
    /// content win=<window number>").
    private func noteLaunchContentFrame() {
        guard !didLogLaunchContent else { return }
        // Only while the launch opens its windows (or its first seconds are
        // logged), and at most every 50 ms: reading the viewport's text on
        // every frame of every surface would cost them.
        let logs = LaunchTimeline.isLogging(within: 5)
        guard logs || LaunchContentFrames.isWatching, launchContentCheck.isDue() else { return }
        guard let window = terminalView.window, window.isVisible,
              let text = terminalView.readViewportText(),
              text.contains(where: { !$0.isWhitespace })
        else { return }
        didLogLaunchContent = true
        if logs {
            LaunchTimeline.mark("first content win=\(window.windowNumber) alpha=\(window.alphaValue) \(proxy.session?.title ?? "")")
        }
        LaunchContentFrames.noteContentFrame(in: window)
    }

    private func handlePostRender() {
        hasRenderedSinceSettledRenderRequest = true
        scheduleSettledRenderCompletionIfPossible()
    }

    private func scheduleSettledRenderCompletionIfPossible() {
        guard settledRenderHandler != nil,
              hasRenderedSinceSettledRenderRequest,
              isMountedViewportReadyForReveal
        else { return }

        // A fit first paints Ghostty's resized grid, then the foreground TUI
        // reacts to SIGWINCH and paints its new layout. Debounce render ticks so
        // the outgoing snapshot is only removed once that short redraw burst has
        // gone quiet, rather than exposing the intermediate composition.
        settledRenderTask?.cancel()
        settledRenderGeneration &+= 1
        let generation = settledRenderGeneration
        settledRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  let self,
                  generation == self.settledRenderGeneration,
                  self.isMountedViewportReadyForReveal,
                  let handler = self.settledRenderHandler
            else { return }

            self.settledRenderHandler = nil
            self.settledRenderTask = nil
            self.hasRenderedSinceSettledRenderRequest = false
            handler()
        }
    }

    private var isMountedViewportReadyForReveal: Bool {
        guard let gridMetrics,
              gridMetrics.columns > 0,
              gridMetrics.rows > 0
        else { return false }

        return isViewportConsistentWithMountedSurface(
            columns: Int(gridMetrics.columns),
            rows: Int(gridMetrics.rows),
            widthPixels: Int(gridMetrics.widthPixels),
            heightPixels: Int(gridMetrics.heightPixels),
            cellWidthPixels: Int(gridMetrics.cellWidthPixels),
            cellHeightPixels: Int(gridMetrics.cellHeightPixels)
        )
    }

    private func cancelSettledRenderHandler() {
        settledRenderGeneration &+= 1
        settledRenderTask?.cancel()
        settledRenderTask = nil
        settledRenderHandler = nil
        hasRenderedSinceSettledRenderRequest = false
    }

    func simulatePostRenderForTesting() {
        handlePostRender()
    }

    /// Respawn the native (EXEC) child in place. ghostty only rebuilds a
    /// surface when its configuration *changes*, and restarting the same
    /// command produces an equivalent configuration — so force the rebuild.
    /// Tearing down the old surface closes its PTY, which also terminates a
    /// still-running child before the new one spawns.
    ///
    /// ghostty routes queued surface messages by surface address, and the
    /// replacement surface is often allocated at the freed one's address. A
    /// child that already exited (e.g. one `stop()` just signalled) has queued
    /// `child_exited`; delivered after the rebuild, it would end the new launch
    /// and mark the new surface's child as exited. Free the old surface and
    /// drain the app mailbox first, so those messages are dropped.
    func relaunchNativeSurface() {
        guard !isReleased, let session = proxy.session else { return }
        isNativePTYBacked = true
        // First: the previous adapter must be gone before the next one of
        // this tab attaches with the same client id (`nativeExecLaunch`).
        terminalView.freeSurface()
        terminalView.controller?.tick()
        terminalView.relaunchSurface(
            configuration: Self.makeOptions(
                for: session,
                inMemorySession: inMemorySession,
                useNativePTY: true
            )
        )
        scrollContainer?.synchronizeScrollState()
    }

    /// Replaces the EXEC surface with an in-memory one, which runs no
    /// process: a persistent tab restarting shows it while its next session
    /// is created, and the keys typed into it go to the tab
    /// (`TerminalSession.hostInputWriter`), which queues them for that
    /// session's program, instead of to the ended adapter's PTY.
    /// `relaunchNativeSurface` then launches the new session's adapter.
    func relaunchInMemorySurface() {
        guard !isReleased, isNativePTYBacked, let session = proxy.session else { return }
        isNativePTYBacked = false
        terminalView.freeSurface()
        terminalView.controller?.tick()
        terminalView.relaunchSurface(
            configuration: Self.makeOptions(
                for: session,
                inMemorySession: inMemorySession,
                useNativePTY: false
            )
        )
        scrollContainer?.synchronizeScrollState()
    }

    func terminalDidClose(processAlive _: Bool) {
        proxy.session?.nativeSurfaceDidClose()
    }

    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        guard !isReleased, let window = terminalView.window else {
            request.respond(allow: false)
            return
        }

        let alert = NSAlert()
        switch request.kind {
        case .paste:
            alert.messageText = "Paste into Terminal?"
            alert.informativeText =
                "Ghostty marked this paste as potentially unsafe. Only paste it if you trust its contents."
            alert.addButton(withTitle: "Paste")
        case .osc52Read:
            alert.messageText = "Allow Clipboard Access?"
            alert.informativeText = "A program in this terminal wants to read your clipboard."
            alert.addButton(withTitle: "Allow")
        case .osc52Write:
            alert.messageText = "Allow Clipboard Change?"
            alert.informativeText = "A program in this terminal wants to replace your clipboard."
            alert.addButton(withTitle: "Allow")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            request.respond(allow: response == .alertFirstButtonReturn)
        }
    }

    /// Stable process anchor for a Ghostty-owned PTY. The foreground PID changes
    /// as commands run, while the controlling terminal's session leader remains
    /// the shell we need for ancestry routing and whole-session teardown.
    func nativeSessionLeaderPID() -> pid_t? {
        guard isNativePTYBacked, let ttyName = terminalView.ttyName else { return nil }
        return TerminalTTYSessionIdentity(ttyName: ttyName)?.sessionLeaderPID
    }

    // MARK: - Native-PTY chrome (forwarded ghostty actions)
    //
    // Under the EXEC backend the ghostty surface owns the PTY, so the chrome the
    // host path derives by parsing PTY bytes itself instead arrives as ghostty
    // actions. Only forward when native is on: in host-managed mode TerminalSession
    // already parses these from the byte stream, and double-applying would race.

    func terminalDidChangeTitle(_ title: String) {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.ingestNativeTitle(title)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.ingestNativeWorkingDirectory(path)
    }

    func terminalDidPostNotification(title: String?, body: String) {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.ingestNativeNotification(title: title, body: body)
    }

    func terminalDidExit(exitCode: UInt32) {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.ingestNativeChildExit(exitCode: Int32(bitPattern: exitCode))
    }

    func terminalDidRequestRender() {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.noteNativeRenderRequest()
    }

    func terminalDidFinishCommand(exitCode: Int32?, durationNanoseconds: UInt64) {
        guard isNativePTYBacked, let session = proxy.session else { return }
        session.noteNativeCommandFinished(exitCode: exitCode)
    }

    /// Routes programmatic input to the surface-owned PTY under native mode (the
    /// host has no PTY fd to write to). `send(text:)`/`send(data:)` funnel here.
    ///
    /// Printable runs of text input are pasted through the surface text path;
    /// Enter, Tab, Backspace, Escape and arrow/navigation sequences become key
    /// events Ghostty encodes for the program's modes; control characters (and
    /// the printable bytes of `raw` input) are written to the PTY as they are,
    /// with the kitty keyboard protocol on or off — this is the path agents use
    /// to drive other agents' TUIs. See `NativeInputTranslator`.
    func sendNativeInput(_ data: Data, raw: Bool = false) {
        for op in NativeInputTranslator.translate(data, raw: raw) {
            switch op {
            case .text(let text):
                terminalView.sendText(text)
            case .bytes(let bytes):
                terminalView.performBindingAction(NativeInputTranslator.textBindingAction(for: bytes))
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
        guard let session = proxy.session else {
            NSSound.beep()
            return
        }
        // A persistent tab's host may have rung this bell already.
        session.ingestNativeBell()
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        sidebarResizeLog(
            "terminalDidResize grid=\(size.columns)x\(size.rows) " +
            "pixels=\(size.widthPixels)x\(size.heightPixels) " +
            "terminalBounds=\(terminalView.bounds.size)"
        )
        // A resize invalidates any render that was about to reveal this
        // surface. Require a fresh post-render at the new mounted grid.
        settledRenderGeneration &+= 1
        settledRenderTask?.cancel()
        settledRenderTask = nil
        hasRenderedSinceSettledRenderRequest = false
        gridMetrics = size
        announceAdapterWindowSize()
        reportWindowGrid()
        scrollContainer?.synchronizeScrollState()
        activateOutputFeedWhenSurfaceIsReady()
    }

    func terminalDidUpdateScrollbar(_ metrics: TerminalScrollbarMetrics) {
        scrollbarMetrics = metrics
        scheduleScrollbarSynchronization()
        // Scrollbar metrics reposition the document-hosted surface even when
        // Ghostty does not need another paint. Treat that layout update as part
        // of the same settling burst before revealing the incoming viewport.
        scheduleSettledRenderCompletionIfPossible()
    }

    private func scheduleScrollbarSynchronization() {
        guard !isScrollbarSynchronizationScheduled else { return }
        isScrollbarSynchronizationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScrollbarSynchronizationScheduled = false
            guard !self.isReleased else { return }
            self.scrollContainer?.synchronizeScrollState()
        }
    }

    func terminalDidChangePointerStyle(_ style: TerminalPointerStyle) {
        pointerStyle = style
        updateTerminalPointerStyle()
    }

    func terminalDidHoverLink(_ url: String?) {
        hoveredLink = url
        updateTerminalPointerStyle()
    }

    /// A click on a URL. In a tab of another Mac, a URL of that Mac's
    /// loopback opens through a forward of its port (`RemoteURLOpening`);
    /// anything else is Ghostty's to open.
    func terminalShouldHandleOpenURL(_ url: String) -> Bool {
        guard let session = proxy.session else { return false }
        return RemoteURLOpening.open(url, for: session, window: terminalView.window)
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
        if isNativePTYBacked {
            proxy.session?.noteNativeHostInput(event: NSApp.currentEvent)
        }
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
            uninstallWindowSettlingObserver()
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
            var chunk = Data(line.utf8)
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
        let lines: [String]
        let startLine: Int
    }

    private static func renderedReplaySnapshot(
        for session: TerminalSession,
        maxBytes _: Int,
        maxLines: Int
    ) -> RenderedReplaySnapshot {
        let totalLines = session.lineCount
        guard totalLines > 0 else {
            return RenderedReplaySnapshot(lines: [], startLine: 0)
        }

        let startLine = max(0, totalLines - maxLines)
        return RenderedReplaySnapshot(
            lines: session.snapshot(range: startLine..<totalLines),
            startLine: startLine
        )
    }

    private static let ansiResetData = Data("\u{1B}[0m".utf8)
    private static let ansiResetViewportData = Data("\u{1B}[?6l\u{1B}[r\u{1B}[?69l".utf8)
    private static let ansiHomeAndClearData = Data("\u{1B}[H\u{1B}[J".utf8)
    private static let ansiDisableWraparoundData = Data("\u{1B}[?7l".utf8)
    private static let ansiEnableWraparoundData = Data("\u{1B}[?7h".utf8)

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

    private static func makeOptions(
        for session: TerminalSession,
        inMemorySession: InMemoryTerminalSession,
        useNativePTY: Bool
    ) -> TerminalSurfaceOptions {
        // Running Cherry sessions always use EXEC: the Ghostty surface owns the
        // PTY and spawns Cherry's resolved shell + environment. The in-memory
        // backend remains only for shell-less previews and renderer tests.
        let native = useNativePTY ? session.nativeExecLaunch : nil
        return TerminalSurfaceOptions(
            backend: useNativePTY ? .exec : .inMemory(inMemorySession),
            workingDirectory: session.nativeSurfaceWorkingDirectory,
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

    /// A window starting or ending a change of size
    /// (`TerminalWindowSettling`): the adapter of the tab it shows holds
    /// its resizes meanwhile, and resizes the session to the size the
    /// window settled at.
    private func observeWindowSettling() {
        windowSettlingObserver = NotificationCenter.default.addObserver(
            forName: TerminalWindowSettling.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, self.terminalView.window === window else { return }
                self.announceAdapterWindowSize()
            }
        }
        // AppKit's full-screen transitions are followed from now on.
        _ = TerminalWindowSettling.shared
    }

    private func uninstallWindowSettlingObserver() {
        guard let windowSettlingObserver else { return }
        NotificationCenter.default.removeObserver(windowSettlingObserver)
        self.windowSettlingObserver = nil
    }

    /// What the tab's attach adapter is told of its window's size
    /// (`HostedAttachmentSizeFile`): the surface's grid, or that the size
    /// is changing while the window that shows it settles
    /// (`TerminalWindowSettling`). A surface no window shows (a tab
    /// attaching in the background) has the size its window's terminal had
    /// at the window's settled grid (`TerminalSession.detachedSurfaceSize`,
    /// `RestoredTabLaunchQueue`), which it keeps.
    func announceAdapterWindowSize() {
        guard !isReleased, isNativePTYBacked, let session = proxy.session else { return }
        if TerminalWindowSettling.shared.isSettling(terminalView.window) {
            session.announceAdapterWindowSize(.hold)
            return
        }
        guard let gridMetrics, gridMetrics.columns > 0, gridMetrics.rows > 0 else { return }
        session.announceAdapterWindowSize(.grid(TerminalViewportSize(
            columns: Int(gridMetrics.columns),
            rows: Int(gridMetrics.rows)
        )))
    }

    /// Tells the tab's workspace which grid the window showing this surface
    /// gives a terminal (`TerminalWindowGrid`), and the view's size at it,
    /// once the surface is laid out at its view's size
    /// (`isMountedViewportReadyForReveal`): whatever its backend, so a
    /// persistent tab still being created learns its window's grid from its
    /// own in-memory surface.
    private func reportWindowGrid() {
        guard !isReleased, let session = proxy.session, let window = terminalView.window,
              isMountedViewportReadyForReveal, let gridMetrics
        else { return }
        session.surfaceDidShowWindowGrid(
            TerminalViewportSize(columns: Int(gridMetrics.columns), rows: Int(gridMetrics.rows)),
            size: terminalView.bounds.size,
            in: window
        )
    }

    /// The window size this tab's terminal reports to a program: its PTY's
    /// (`TIOCGWINSZ`) while a native (EXEC) surface runs its program or
    /// attach adapter, else the size Ghostty last gave its in-memory
    /// surface's terminal, which is what it gives a PTY at that size.
    var terminalWindowSize: TerminalTTYWindowSize? {
        guard !isReleased else { return nil }
        if isNativePTYBacked {
            return terminalView.ttyName.flatMap(TerminalTTYWindowSize.init(ttyName:))
        }
        guard let size = inMemorySession.terminalSize, size.columns > 0, size.rows > 0 else { return nil }
        return TerminalTTYWindowSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            widthPixels: Int(size.widthPixels),
            heightPixels: Int(size.heightPixels)
        )
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

        applyTerminalColorSchemeIfNeeded()

        if needsFit {
            TerminalPerformanceMonitor.recordFitToSize()
            terminalView.fitToSize()
        }
        TerminalPerformanceMonitor.recordSettingsApply(reconfigured: needsFit)
    }

    private func applyTerminalColorSchemeIfNeeded() {
        guard let activeColorScheme else { return }
        let nextColorScheme = terminalColorScheme(from: activeColorScheme)
        guard nextColorScheme != appliedTerminalColorScheme else { return }
        controller.setColorScheme(nextColorScheme)
        appliedTerminalColorScheme = nextColorScheme
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

extension GhosttySessionBridge {
    /// Files pasted or dropped on a tab whose program runs on another Mac
    /// (docs/specs/remote-devices.md, phase 3): asked about, copied there
    /// and their paths there inserted; an image pasted or dropped there is
    /// copied without asking. False when it is not such a tab or it carries
    /// no files or image (the default paste or drop then runs).
    func handleRemoteFiles(_ pasteboard: NSPasteboard, isPaste: Bool) -> Bool {
        guard let session = proxy.session else { return false }
        return RemoteFileDropCoordinator.handle(
            pasteboard, for: session, isPaste: isPaste, window: terminalView.window
        ) { [weak self] text in
            self?.insertPastedText(text)
        }
    }

    /// ⌘V: files and images into a tab of another Mac
    /// (`handleRemoteFiles`); an image alone into a tab of This Mac, as its
    /// saved file's path, and files copied with no text as their paths
    /// (`LocalImagePaste`). False for anything else (text, Finder's files,
    /// which carry their names as text): the surface pastes it.
    func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard let session = proxy.session else { return false }
        if let hosting = session.persistentHosting, !hosting.profile.isThisMac {
            return handleRemoteFiles(pasteboard, isPaste: true)
        }
        return LocalImagePaste.handle(pasteboard) { [weak self] text in
            self?.insertPastedText(text)
        }
    }

    /// Edit › Paste (`AppTerminalView.paste(_:)`), as ⌘V: what Cherry
    /// pastes itself (`handlePaste`), and, while the surface's process
    /// takes no keys (a host-managed surface, or a persistent tab whose
    /// attach adapter is away), the pasteboard's text through the host,
    /// bracketed as it reports the program's mode. False leaves the rest
    /// to the surface's own paste.
    func handleMenuPaste(_ pasteboard: NSPasteboard) -> Bool {
        guard let session = proxy.session, session.acceptsInput else { return false }
        if handlePaste(pasteboard) { return true }
        guard session.keyboardInputGoesThroughHost || !isNativePTYBacked else { return false }
        if let data = TerminalPasteboardContent.pasteData(from: pasteboard, bracketing: session.bracketsPaste) {
            if isNativePTYBacked {
                session.noteNativeHostInput(event: nil)
            } else {
                scrollToBottomForHostInput()
            }
            session.send(data: data)
        }
        return true
    }

    /// A pasteboard with no text the surface pastes by itself (Edit ›
    /// Paste, a context menu, an OSC 52 read) or an image dropped on it:
    /// in a tab of This Mac, an image's saved file's quoted path or the
    /// files' paths (`LocalImagePaste`, as ⌘V); in a tab of another Mac
    /// nothing now (an empty text), and the copy's path there once it is
    /// copied (`handleRemoteFiles`).
    func terminalText(forImageOn pasteboard: NSPasteboard) -> String? {
        guard let session = proxy.session else { return nil }
        if let hosting = session.persistentHosting, !hosting.profile.isThisMac {
            return handleRemoteFiles(pasteboard, isPaste: true) ? "" : nil
        }
        return LocalImagePaste.text(for: pasteboard)
    }

    /// Ctrl+V with an image in an agent tab of another Mac
    /// (`RemoteClipboardImagePaste`): the image goes to that Mac's
    /// clipboard first, then the key.
    func handleRemoteClipboardImagePaste(_ pasteboard: NSPasteboard, replay: @escaping @MainActor (NSEvent) -> Void) -> Bool {
        guard let session = proxy.session else { return false }
        return RemoteClipboardImagePaste.handle(
            pasteboard, for: session, window: terminalView.window,
            sendControlV: { [weak session] in
                // Encoded for the program's keyboard mode by the surface
                // (or the host while the adapter is away).
                session?.send(data: Data([0x16]))
            },
            insert: { [weak self] text in self?.insertPastedText(text) },
            replay: replay
        )
    }

    /// Pastes `text` into the tab as the tab pastes: through the surface
    /// (which brackets it while the program asks for it), or, when the
    /// host takes the tab's input now, bracketed as the host reports the
    /// program's mode (`TerminalSession.bracketsPaste`).
    func insertPastedText(_ text: String) {
        guard let session = proxy.session, session.acceptsInput else { return }
        if session.keyboardInputGoesThroughHost || !isNativePTYBacked {
            session.send(data: TerminalInputEncoder.pastedTextData(text, bracketedPasteMode: session.bracketsPaste(text)))
        } else {
            terminalView.sendText(text)
        }
    }
}

@MainActor
final class GhosttyTerminalContainerView: NSView {
    private static let snapshotFadeDuration: CFTimeInterval = 0.18

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private weak var activeSession: TerminalSession?
    private weak var activeBridge: GhosttySessionBridge?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var keyEventMonitor: Any?
    private var isLiveScrolling = false
    private var lastSentScrollRow: Int?
    private var allowsAutoFocus = true
    /// Where ⌘V takes what Cherry pastes itself (images, files, and text
    /// for the host-managed surface or a persistent tab whose attach
    /// adapter is away): the surfaces' clipboard (`TerminalClipboard`),
    /// unless set. Tests use their own.
    var pasteboard: NSPasteboard {
        get { pasteboardOverride ?? TerminalClipboard.pasteboard() }
        set { pasteboardOverride = newValue }
    }
    private var pasteboardOverride: NSPasteboard?
    private var isActivePane = true
    private var activatePane: (() -> Void)?
    private var pendingTerminalFocus = false
    private var isSidebarAnimating = false
    private var isSyncFrozen = false
    private var snapshotLayer: CALayer?
    private var surfaceTransitionSnapshotLayer: CALayer?
    private var surfaceTransitionFallbackTask: Task<Void, Never>?
    private var surfaceTransitionGeneration: UInt64 = 0
    private var activeColorScheme: ColorScheme = .dark
    private var appliedDocumentBackgroundScheme: ColorScheme?
    private var appliedDocumentBackgroundRevision: UInt64?
    private var documentBackgroundApplyCount = 0
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
        usesWorktreeSurfaceTransition: Bool = false,
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
            // Terminal selection is intentionally immediate. Only worktree
            // navigation keeps the outgoing pixels briefly while the incoming
            // surface fits and its foreground TUI redraws.
            let transitionGeneration: UInt64? = activeSession.flatMap { source -> UInt64? in
                guard usesWorktreeSurfaceTransition
                    || isWorktreeTransition(from: source, to: session)
                else {
                    cancelSurfaceTransition()
                    return nil
                }
                return beginSurfaceTransitionIfPossible()
            } ?? nil
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
            let bridge = session.ghosttyBridge
            if let transitionGeneration {
                bridge.performAfterRenderedViewportSettles { [weak self] in
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        self?.completeSurfaceTransition(generation: transitionGeneration)
                    }
                }
            }
            bridge.attach(to: self)
            if isActivePane {
                requestTerminalFocus()
            }
        } else if activeBridge !== session.ghosttyBridge {
            // Disconnecting a hosted session releases its bridge while this
            // container still displays the same session. Mount the replacement
            // after reconnecting; session identity alone cannot detect it.
            cancelSurfaceTransition()
            resetSidebarAnimationStateForSurfaceChange()
            session.ghosttyBridge.attach(to: self)
            if isActivePane {
                requestTerminalFocus()
            }
        }

        if isActivePane, !wasActivePane {
            requestTerminalFocus()
        }

        activeColorScheme = colorScheme
        applyDocumentBackgroundColorIfNeeded(for: colorScheme)
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
        cancelSurfaceTransition()
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

    private func beginSurfaceTransitionIfPossible() -> UInt64? {
        guard scrollView.frame.width > 0,
              scrollView.frame.height > 0,
              let capture = captureTerminalLayerContents()
        else {
            cancelSurfaceTransition()
            return nil
        }

        cancelSurfaceTransition()
        surfaceTransitionGeneration &+= 1
        let generation = surfaceTransitionGeneration
        surfaceTransitionSnapshotLayer = makeSnapshotLayer(
            capture: capture,
            frame: scrollView.frame,
            zPosition: 1_100
        )
        surfaceTransitionFallbackTask = Task { @MainActor [weak self] in
            // Safety valve for a stopped or otherwise non-rendering surface.
            // Normal transitions complete through the stable-render callback.
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            self?.completeSurfaceTransition(generation: generation)
        }
        return generation
    }

    private func completeSurfaceTransition(generation: UInt64) {
        guard generation == surfaceTransitionGeneration,
              let fadingLayer = surfaceTransitionSnapshotLayer
        else { return }

        surfaceTransitionFallbackTask?.cancel()
        surfaceTransitionFallbackTask = nil
        fadingLayer.removeFromSuperlayer()
        surfaceTransitionSnapshotLayer = nil
    }

    private func cancelSurfaceTransition() {
        surfaceTransitionFallbackTask?.cancel()
        surfaceTransitionFallbackTask = nil
        surfaceTransitionSnapshotLayer?.removeFromSuperlayer()
        surfaceTransitionSnapshotLayer = nil
    }

    private func isWorktreeTransition(
        from source: TerminalSession,
        to target: TerminalSession
    ) -> Bool {
        guard let sourceRoot = source.projectRoot,
              let targetRoot = target.projectRoot,
              sourceRoot != targetRoot,
              let sourceRepositoryRoot = AgentSettings.shared.repositoryRoot(for: sourceRoot),
              let targetRepositoryRoot = AgentSettings.shared.repositoryRoot(for: targetRoot)
        else {
            return false
        }
        return sourceRepositoryRoot == targetRepositoryRoot
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
        // Best-effort freeze-frame of the live terminal area; if the surface
        // has never presented we still suppress resize re-fits, the cross-fade
        // just becomes a no-op.
        guard scrollView.frame.width > 0,
              scrollView.frame.height > 0,
              let capture = captureTerminalLayerContents()
        else { return }

        snapshotLayer?.removeFromSuperlayer()
        snapshotLayer = makeSnapshotLayer(
            capture: capture,
            frame: scrollView.frame,
            zPosition: 1_000
        )
    }

    private func refreshSnapshotContentsAfterEarlyFitIfPossible() {
        guard let snapshotLayer,
              let contentsLayer = snapshotLayer.sublayers?.first,
              let capture = captureTerminalLayerContents()
        else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsLayer.contents = capture.contents
        contentsLayer.contentsScale = capture.contentsScale
        contentsLayer.frame = capture.frame.offsetBy(
            dx: -snapshotLayer.frame.minX,
            dy: -snapshotLayer.frame.minY
        )
        CATransaction.commit()
    }

    private func terminalBackgroundCGColor() -> CGColor {
        let themeColors = TerminalSettings.shared.ghosttyThemeColors(for: activeColorScheme)
        let resolved = NSColor(hexRGB: themeColors.background)
            ?? (activeColorScheme == .light ? NSColor.white : NSColor.black)
        return resolved.cgColor
    }

    private struct TerminalLayerCapture {
        let contents: Any
        let contentsScale: CGFloat
        /// Terminal view rect in container-view coordinates.
        let frame: NSRect
    }

    /// Zero-copy grab of the terminal's currently presented IOSurface.
    /// `cacheDisplay` software-rasterizes the GPU layer through CoreGraphics
    /// (~250-330ms per capture on a retina window, measured 2026-07);
    /// referencing the presented surface is O(1). Callers capture before the
    /// outgoing bridge detaches, and detach hides the surface, so the pixels
    /// stay stable while the snapshot is on screen.
    private func captureTerminalLayerContents() -> TerminalLayerCapture? {
        guard let terminalView = activeBridge?.terminalView,
              let sourceLayer = terminalView.layer,
              let contents = sourceLayer.contents
        else { return nil }
        return TerminalLayerCapture(
            contents: contents,
            contentsScale: sourceLayer.contentsScale,
            frame: terminalView.convert(terminalView.bounds, to: self)
        )
    }

    private func makeSnapshotLayer(
        capture: TerminalLayerCapture,
        frame: CGRect,
        zPosition: CGFloat
    ) -> CALayer {
        wantsLayer = true
        let container = CALayer()
        // Ghostty's Metal layer renders text on a clear background. Filling the
        // snapshot makes it fully opaque, covering resize/reconfigure flashes.
        container.backgroundColor = terminalBackgroundCGColor()
        container.masksToBounds = true
        container.frame = frame
        container.zPosition = zPosition
        container.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]

        // The sublayer frame below is expressed in this view's coordinate
        // space, which matches the container's CA space only while neither
        // this view nor its backing layer is flipped.
        let contentsLayer = CALayer()
        contentsLayer.contents = capture.contents
        // Anchor captured terminal pixels at the top-left without scaling so
        // text stays pixel-aligned while the live Metal surface changes below.
        contentsLayer.contentsGravity = .topLeft
        contentsLayer.contentsScale = capture.contentsScale
        contentsLayer.frame = capture.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        contentsLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
        ]
        container.addSublayer(contentsLayer)

        self.layer?.addSublayer(container)
        return container
    }

    private func crossfadeOutSnapshotLayer() {
        guard let snapshotLayer else {
            removeSnapshotLayer(animated: false)
            return
        }
        let fadingLayer = snapshotLayer

        animateSnapshotFadeOut(fadingLayer) { [weak self] in
            fadingLayer.removeFromSuperlayer()
            if self?.snapshotLayer === fadingLayer {
                self?.snapshotLayer = nil
            }
        }
    }

    private func animateSnapshotFadeOut(
        _ fadingLayer: CALayer,
        completion: @escaping () -> Void
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadingLayer.presentation()?.opacity ?? fadingLayer.opacity
        fade.toValue = 0
        fade.duration = Self.snapshotFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        // Only the explicit compositor animation should drive opacity. Without
        // this, assigning the model value also installs Core Animation's default
        // implicit opacity animation; the two overlapping curves make the short
        // crossfade appear to step or drop frames.
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
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
        guard snapshotLayer != nil || surfaceTransitionSnapshotLayer != nil else { return }
        // Track the current visible area so the snapshot stays aligned with
        // the underlying scroll view as the container resizes during the
        // animation. Disable implicit layer animations or the snapshot will
        // animate independently from SwiftUI's frame interpolation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer?.frame = scrollView.frame
        surfaceTransitionSnapshotLayer?.frame = scrollView.frame
        CATransaction.commit()
    }

    // Painting the document background with the active terminal theme color
    // means that when the deferred strategy freezes the live terminal at its
    // pre-animation size, any newly exposed area on the right (sidebar
    // closing) reads as terminal background instead of bleeding through to
    // the scene's gradient.
    private func applyDocumentBackgroundColorIfNeeded(for colorScheme: ColorScheme) {
        let settings = TerminalSettings.shared
        let revision = settings.terminalAppearanceRevision
        guard appliedDocumentBackgroundScheme != colorScheme
            || appliedDocumentBackgroundRevision != revision
        else {
            return
        }

        let themeColors = settings.ghosttyThemeColors(for: colorScheme)
        let resolved = NSColor(hexRGB: themeColors.background)
            ?? (colorScheme == .light ? NSColor.white : NSColor.black)

        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = resolved.cgColor
        appliedDocumentBackgroundScheme = colorScheme
        appliedDocumentBackgroundRevision = revision
        documentBackgroundApplyCount += 1
    }

    private func configureScrollView() {
        // The scrollback document can extend above the visible terminal. Keep
        // its background and the Metal surface inside this pane's bounds so
        // they cannot paint over the SwiftUI context bar above the terminal.
        clipsToBounds = true

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
        // literal escape text via the text path). Let the event fall through,
        // unless the surface's process takes no keys now (a persistent tab
        // whose attach adapter is away): then the host types them.
        if activeBridge?.isNativePTYBacked == true {
            guard event.window === window,
                  Self.terminalHasKeyboard(window?.firstResponder, terminalView: activeBridge?.terminalView)
            else {
                return false
            }
            if holdKeyWhileAdapterAttaches(event) { return true }
            switch Self.nativeKeyRoute(
                modifiers: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                holdsKeys: activeSession.map { RemoteClipboardImagePaste.holdsKeys(for: $0.id) } ?? false
            ) {
            case .hold:
                // A Ctrl+V's image is on its way to another Mac: keys typed
                // meanwhile follow its Ctrl+V.
                if let activeSession { RemoteClipboardImagePaste.hold(event, for: activeSession.id) }
                return true
            case .paste:
                // Files and images pasted into a tab of another Mac are
                // copied there; an image pasted into one of This Mac is
                // saved and its path pasted.
                if activeBridge?.handlePaste(pasteboard) == true { return true }
            case .controlV:
                // Ctrl+V with an image in an agent tab of another Mac: the
                // image goes to that Mac's clipboard first.
                if let activeBridge,
                   activeBridge.handleRemoteClipboardImagePaste(pasteboard, replay: { [weak self, weak activeBridge] held in
                       guard let self, let activeBridge else { return }
                       if !self.sendKeyThroughHostWhileAdapterIsAway(held) {
                           activeBridge.terminalView.keyDown(with: held)
                       }
                   }) {
                    return true
                }
            case .other:
                break
            }
            return sendKeyThroughHostWhileAdapterIsAway(event)
        }
        guard event.window === window,
              let activeSession,
              activeSession.acceptsInput,
              Self.terminalHasKeyboard(window?.firstResponder, terminalView: activeBridge?.terminalView)
        else {
            return false
        }

        if isPasteShortcut(event),
           let pasteData = TerminalPasteboardContent.pasteData(
               from: pasteboard,
               bracketing: activeSession.bracketsPaste
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

    /// Whether the window's keys go to the tab's terminal: its view, or a
    /// view inside it, is the first responder.
    static func terminalHasKeyboard(_ firstResponder: NSResponder?, terminalView: NSView?) -> Bool {
        guard let terminalView, let view = firstResponder as? NSView else { return false }
        return view === terminalView || view.isDescendant(of: terminalView)
    }

    /// A key typed into a persistent tab's EXEC surface while its attach
    /// adapter is away (`TerminalSession.keyboardInputGoesThroughHost`: it
    /// ended and is launched again, or reconnects by itself): no process
    /// takes it there, so it goes through the host (`send(data:)`), and
    /// the surface keeps showing the last screen. Cursor keys are encoded
    /// for the program's cursor key mode as its host reports it
    /// (`TerminalSession.usesApplicationCursorKeys`), and every key for its
    /// modifyOtherKeys (`TerminalSession.usesModifyOtherKeys`). True when it was
    /// sent; false leaves the event to the surface (Command shortcuts,
    /// which the menu handles; keys `HostRoutedKeyEncoder` has no encoding
    /// for; text being composed with an input method).
    func sendKeyThroughHostWhileAdapterIsAway(_ event: NSEvent) -> Bool {
        guard let activeSession, let activeBridge else { return false }
        return sendKeyThroughHostWhileAdapterIsAway(event, session: activeSession, bridge: activeBridge)
    }

    /// A key typed into the tab while its attach adapter attaches
    /// (`TerminalSession.holdsKeysUntilAdapterAttaches`), or while keys held
    /// so still wait: its terminal does not read the program's input yet,
    /// so the key waits for it behind those, and goes on in order once it
    /// attached (`deliverHeldKey`). True when held; Command shortcuts and
    /// text being composed with an input method are not.
    func holdKeyWhileAdapterAttaches(_ event: NSEvent) -> Bool {
        guard let activeSession, let activeBridge, activeBridge.isNativePTYBacked,
              !event.modifierFlags.contains(.command),
              !activeBridge.terminalView.hasMarkedText(),
              activeSession.holdsKeysUntilAdapterAttaches || activeSession.hasKeysAwaitingAdapter
        else { return false }
        activeSession.holdKeyUntilAdapterAttaches(event) { [weak self, weak activeSession, weak activeBridge] held in
            guard let activeSession, let activeBridge else { return }
            Self.deliverHeldKey(held, session: activeSession, bridge: activeBridge, container: self)
        }
        return true
    }

    /// A key `session` held while its adapter attached
    /// (`TerminalSession.holdKeyUntilAdapterAttaches`), sent where a key
    /// typed into it now would go: held again while another adapter of the
    /// tab attaches, else through the host while its adapter is away, else
    /// to its surface (the attached adapter).
    static func deliverHeldKey(
        _ event: NSEvent,
        session: TerminalSession,
        bridge: GhosttySessionBridge,
        container: GhosttyTerminalContainerView?
    ) {
        if session.holdsKeysUntilAdapterAttaches {
            session.holdKeyUntilAdapterAttaches(event) { [weak session, weak bridge, weak container] held in
                guard let session, let bridge else { return }
                deliverHeldKey(held, session: session, bridge: bridge, container: container)
            }
            return
        }
        if let container, container.sendKeyThroughHostWhileAdapterIsAway(event, session: session, bridge: bridge) {
            return
        }
        bridge.terminalView.keyDown(with: event)
    }

    private func sendKeyThroughHostWhileAdapterIsAway(
        _ event: NSEvent,
        session activeSession: TerminalSession,
        bridge activeBridge: GhosttySessionBridge
    ) -> Bool {
        guard activeBridge.isNativePTYBacked,
              activeSession.acceptsInput,
              activeSession.keyboardInputGoesThroughHost,
              !activeBridge.terminalView.hasMarkedText()
        else {
            return false
        }
        let optionAsAlt = HostRoutedKeyEncoder.OptionAsAlt.nativeSurfaces
        // Ghostty's modifyOtherKeys encoding applies in legacy key encoding
        // only.
        let modifyOtherKeys = activeSession.usesModifyOtherKeys && !activeSession.isEnhancedKeyboardProtocolActive
        let data: Data
        if isPasteShortcut(event) {
            // Bracketed as the host reports the program's mode: the
            // surface, which would know it, is not taking input now.
            guard let pasteData = TerminalPasteboardContent.pasteData(
                from: pasteboard,
                bracketing: activeSession.bracketsPaste
            ) else { return false }
            data = pasteData
        } else if let encoded = HostRoutedKeyEncoder.data(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            // Only the kitty keyboard protocol's codes, and under
            // modifyOtherKeys an Alt key that types no single character,
            // use it.
            unshiftedCharacters: activeSession.isEnhancedKeyboardProtocolActive || modifyOtherKeys
                ? event.characters(byApplyingModifiers: []) : nil,
            typedText: modifyOtherKeys ? HostRoutedKeyEncoder.surfaceText(for: event, optionAsAlt: optionAsAlt) : nil,
            usesApplicationCursorKeys: activeSession.usesApplicationCursorKeys,
            isEnhancedKeyboardProtocolActive: activeSession.isEnhancedKeyboardProtocolActive,
            keyboardProtocolFlags: activeSession.keyboardProtocolFlags,
            sendsModifiedArrowKeys: activeSession.usesAlternateScreen
                || activeSession.isEnhancedKeyboardProtocolActive,
            modifyOtherKeys: modifyOtherKeys,
            optionAsAlt: optionAsAlt
        ) {
            data = encoded
        } else {
            return false
        }
        activeSession.noteNativeHostInput(event: event)
        activeSession.send(data: data)
        return true
    }

    /// Ctrl+V alone (no Command, Option or Shift).
    /// What the key monitor does with a key typed into a native surface
    /// (the default tabs, whose surface owns their input) before the surface
    /// sees it.
    enum NativeKeyRoute: Equatable {
        /// A Ctrl+V's image paste is under way in the tab: held until it
        /// is done (Command shortcuts still reach the menu).
        case hold
        /// ⌘V: files and images are Cherry's to paste.
        case paste
        /// Ctrl+V: an image may go to another Mac's clipboard first.
        case controlV
        case other
    }

    static func nativeKeyRoute(
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        holdsKeys: Bool
    ) -> NativeKeyRoute {
        if holdsKeys, !modifiers.contains(.command) { return .hold }
        if isPasteShortcut(modifiers: modifiers, charactersIgnoringModifiers: charactersIgnoringModifiers) { return .paste }
        if isControlV(modifiers: modifiers, charactersIgnoringModifiers: charactersIgnoringModifiers) { return .controlV }
        return .other
    }

    /// Ctrl+V alone (no Command, Option or Shift).
    static func isControlV(modifiers: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?) -> Bool {
        modifiers.intersection([.command, .control, .option, .shift]) == .control
            && charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// ⌘V (with or without Shift; not with Control or Option).
    static func isPasteShortcut(modifiers: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?) -> Bool {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option)
            && charactersIgnoringModifiers?.lowercased() == "v"
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        Self.isPasteShortcut(modifiers: event.modifierFlags, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
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
        // Scrolling moves the renderer with the clip view but does not resize
        // its terminal grid. A refit here needlessly calls into Ghostty's resize
        // and render paths for every scrollback row.
        guard force || widthDelta > 1.0 || heightDelta > 1.0 else { return }
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

    var hasSurfaceTransitionSnapshotForTesting: Bool {
        surfaceTransitionSnapshotLayer?.superlayer != nil
    }

    var activeSessionIDForTesting: UUID? {
        activeSession?.id
    }

    var documentBackgroundApplyCountForTesting: Int {
        documentBackgroundApplyCount
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Encodes a key typed into a persistent tab whose attach adapter is away
/// (`GhosttyTerminalContainerView.sendKeyThroughHostWhileAdapterIsAway`),
/// for its host to type: Ghostty's surface would encode it, but its
/// process takes nothing then. It types what a terminal in legacy (xterm)
/// mode types, with the arrow, Home and End keys in the form the program's
/// cursor key mode (DECCKM, as its host reports it) takes:
/// - text; with Option, its composed characters, unless Option acts as Alt
///   (`OptionAsAlt`, Ghostty's `macos-option-as-alt`): then ESC and the
///   key without Option;
/// - Return, Tab, Backspace, Escape, Forward Delete, arrows, Home, End,
///   Page Up/Down and F1–F12, with Shift, Control and Option as xterm's
///   modifier parameter (`ESC [ 1 ; 5 C`, `ESC [ 15 ; 2 ~`);
/// - Control letters and symbols as their C0 byte (Control+Option as Alt:
///   ESC first); Control with a key that has none types the key;
/// - Cherry's own Shift+Return, Shift+Tab and Option encodings, as the
///   host-managed surface uses them.
///
/// While the program uses the kitty keyboard protocol (its flags are not
/// 0), the keys that protocol encodes differently when it disambiguates
/// (flag 1) go as Ghostty's surface types them: Escape as `CSI 27 u`;
/// Control or Alt (Option as Alt) with a key that types a character as
/// `CSI code ; m u`, its code the key's unshifted character; modified
/// Return, Tab and Backspace as `CSI 13 ; m u`…; F1, F2 and F4 as
/// `CSI P`… and F3 as `CSI 13 ~`. What the protocol's other flags add is
/// not: plain text keys as `CSI … u` (report all keys, flag 8; the host
/// path only turns a lone Tab into `CSI 9 u` then, `normalizedInputData`),
/// alternate keys (flag 4) and associated text (flag 16).
///
/// While the program set xterm's modifyOtherKeys to level 2 and uses no
/// kitty flags (`modifyOtherKeys`, as its host reports it), every key goes
/// as Ghostty's surface types it then (`modifyOtherKeysData`): keys with
/// modifiers mostly as `CSI 27 ; m ; code ~`.
///
/// Nil for Command shortcuts (the menu's) and keys it has no encoding for
/// (F13 and above, keys with no character).
enum HostRoutedKeyEncoder {
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let backspace: UInt16 = 51
        static let escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
        static let home: UInt16 = 115
        static let end: UInt16 = 119
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let f3: UInt16 = 99
    }

    /// The keypad keys (`kVK_ANSI_Keypad…`) Ghostty types as their character
    /// whatever the modifiers, as the numeric keypad does by default (mode
    /// 1035 on, so never in application keypad form), and keypad Enter as CR.
    private static let keypadKeys: [UInt16: String] = [
        65: ".", 67: "*", 69: "+", 75: "/", 76: "\r", 78: "-",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]

    /// F1–F12 (`kVK_F1`…) as xterm types them: F1–F4 as `ESC O P`…`S`
    /// (`ESC [ 1 ; m P` with modifiers), the others as `ESC [ n ~`
    /// (`ESC [ n ; m ~`).
    private static let functionKeys: [UInt16: (number: Int, final: String)] = [
        122: (1, "P"), 120: (1, "Q"), 99: (1, "R"), 118: (1, "S"),
        96: (15, "~"), 97: (17, "~"), 98: (18, "~"), 100: (19, "~"),
        101: (20, "~"), 109: (21, "~"), 103: (23, "~"), 111: (24, "~"),
    ]

    /// The letter keys (`kVK_ANSI_A`…), for Control with a layout whose
    /// letters are not Latin: Control+the key where A is on a US layout is
    /// still Control+A.
    private static let letterKeys: [UInt16: UInt8] = [
        0: 0x61, 11: 0x62, 8: 0x63, 2: 0x64, 14: 0x65, 3: 0x66, 5: 0x67, 4: 0x68, 34: 0x69,
        38: 0x6A, 40: 0x6B, 37: 0x6C, 46: 0x6D, 45: 0x6E, 31: 0x6F, 35: 0x70, 12: 0x71,
        15: 0x72, 1: 0x73, 17: 0x74, 32: 0x75, 9: 0x76, 13: 0x77, 7: 0x78, 16: 0x79, 6: 0x7A,
    ]

    /// Which Option keys act as Alt (Meta), sending ESC and the key without
    /// Option rather than the character Option composes: Ghostty's
    /// `macos-option-as-alt`, which Cherry's surfaces default to `true`
    /// (`TerminalSettings.nativeUserKeyboardConfig`).
    enum OptionAsAlt: Equatable, Sendable {
        case neither
        case both
        case left
        case right

        /// From the setting's value; unset or unknown is Cherry's default,
        /// both.
        init(configValue: String?) {
            switch configValue?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "false": self = .neither
            case "left": self = .left
            case "right": self = .right
            default: self = .both
            }
        }

        /// What Cherry's native surfaces use.
        @MainActor static var nativeSurfaces: OptionAsAlt {
            OptionAsAlt(configValue: TerminalSettings.nativeUserKeyboardConfig.last { $0.0 == "macos-option-as-alt" }?.1)
        }

        /// Whether the Option key held in `modifiers` (an event's own
        /// flags, which say which side) acts as Alt.
        func applies(to modifiers: NSEvent.ModifierFlags) -> Bool {
            guard modifiers.contains(.option) else { return false }
            switch self {
            case .neither: return false
            case .both: return true
            // NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK
            case .left: return modifiers.rawValue & 0x20 != 0
            case .right: return modifiers.rawValue & 0x40 != 0
            }
        }
    }

    /// `unshiftedCharacters`: what the key types with no modifiers at all
    /// (`NSEvent.characters(byApplyingModifiers: [])`), the code of a
    /// Control or Alt key under the kitty keyboard protocol; nil uses
    /// `charactersIgnoringModifiers` in lowercase.
    /// `modifyOtherKeys`: the program set xterm's modifyOtherKeys to level 2
    /// (`TerminalSession.usesModifyOtherKeys`); it applies only while the
    /// kitty keyboard protocol does not, as in Ghostty.
    /// `typedText`: the text Ghostty's surface takes the key to type
    /// (`surfaceText(for:optionAsAlt:)`), used only with `modifyOtherKeys`;
    /// nil works it out from `characters` and `charactersIgnoringModifiers`.
    static func data(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?,
        unshiftedCharacters: String? = nil,
        typedText: String? = nil,
        usesApplicationCursorKeys: Bool,
        isEnhancedKeyboardProtocolActive: Bool,
        keyboardProtocolFlags: Int,
        sendsModifiedArrowKeys: Bool,
        modifyOtherKeys: Bool = false,
        optionAsAlt: OptionAsAlt = .both
    ) -> Data? {
        let modifiers = eventModifiers.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return nil }
        if modifyOtherKeys, !isEnhancedKeyboardProtocolActive {
            return modifyOtherKeysData(
                keyCode: keyCode,
                modifiers: eventModifiers,
                text: typedText ?? surfaceText(
                    characters: characters,
                    charactersIgnoringModifiers: charactersIgnoringModifiers,
                    optionActsAsAlt: optionAsAlt.applies(to: eventModifiers)
                ),
                unshiftedCharacters: unshiftedCharacters,
                usesApplicationCursorKeys: usesApplicationCursorKeys,
                optionAsAlt: optionAsAlt
            )
        }
        if let sequence = TerminalInputEncoder.shiftEnterSequence(
            keyCode: keyCode, modifiers: modifiers, isEnhancedKeyboardProtocolActive: isEnhancedKeyboardProtocolActive
        ) ?? TerminalInputEncoder.shiftTabSequence(
            keyCode: keyCode, modifiers: modifiers, isEnhancedKeyboardProtocolActive: isEnhancedKeyboardProtocolActive
        ) ?? TerminalInputEncoder.appKitOptionBackspaceSequence(
            keyCode: keyCode, modifiers: modifiers
        ) ?? TerminalInputEncoder.appKitOptionArrowSequence(
            keyCode: keyCode, modifiers: modifiers, sendsModifiedArrowKeys: sendsModifiedArrowKeys
        ) ?? TerminalInputEncoder.appKitOptionDigitTextData(
            keyCode: keyCode, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers, keyboardProtocolFlags: keyboardProtocolFlags
        ) ?? TerminalInputEncoder.appKitUnmodifiedArrowSequence(
            keyCode: keyCode, modifiers: modifiers, usesApplicationCursorKeys: usesApplicationCursorKeys
        ) {
            return sequence
        }
        let held = modifiers.intersection([.shift, .control, .option])
        let alt = optionAsAlt.applies(to: eventModifiers)
        // xterm's modifier parameter: 1, plus 1 for Shift, 2 for Option
        // (Alt), 4 for Control.
        let parameter = 1 + (held.contains(.shift) ? 1 : 0) + (held.contains(.option) ? 2 : 0)
            + (held.contains(.control) ? 4 : 0)

        /// Return, Tab or Backspace (`byte`, kitty's `code`) with modifiers.
        func modifiedKey(_ byte: UInt8, code: Int) -> Data {
            if held.isEmpty { return Data([byte]) }
            if isEnhancedKeyboardProtocolActive { return csi("\(code);\(parameter)u") }
            return alt ? Data([0x1B, byte]) : Data([byte])
        }

        if let key = functionKeys[keyCode] {
            if isEnhancedKeyboardProtocolActive, key.final != "~" {
                // The kitty keyboard protocol: `CSI P`, `CSI Q`, `CSI S`
                // (`CSI 1 ; m P`…), and F3 as `CSI 13 ~`, as `CSI R` is a
                // cursor position report.
                if keyCode == KeyCode.f3 { return csi(held.isEmpty ? "13~" : "13;\(parameter)~") }
                return csi(held.isEmpty ? key.final : "1;\(parameter)\(key.final)")
            }
            if key.final == "~" {
                return csi(held.isEmpty ? "\(key.number)~" : "\(key.number);\(parameter)~")
            }
            return held.isEmpty ? Data("\u{1B}O\(key.final)".utf8) : csi("1;\(parameter)\(key.final)")
        }
        switch keyCode {
        case KeyCode.up, KeyCode.down, KeyCode.right, KeyCode.left:
            // Without modifiers, or with Option alone: encoded above.
            let final = [KeyCode.up: "A", KeyCode.down: "B", KeyCode.right: "C", KeyCode.left: "D"][keyCode] ?? "A"
            return csi("1;\(parameter)\(final)")
        case KeyCode.home, KeyCode.end:
            let final = keyCode == KeyCode.home ? "H" : "F"
            guard held.isEmpty else { return csi("1;\(parameter)\(final)") }
            return Data(((usesApplicationCursorKeys ? "\u{1B}O" : "\u{1B}[") + final).utf8)
        case KeyCode.pageUp:
            return csi(held.isEmpty ? "5~" : "5;\(parameter)~")
        case KeyCode.pageDown:
            return csi(held.isEmpty ? "6~" : "6;\(parameter)~")
        case KeyCode.forwardDelete:
            return csi(held.isEmpty ? "3~" : "3;\(parameter)~")
        case KeyCode.returnKey, KeyCode.keypadEnter:
            // Shift alone: encoded above.
            return modifiedKey(0x0D, code: 13)
        case KeyCode.tab:
            // Shift alone: encoded above.
            return modifiedKey(0x09, code: 9)
        case KeyCode.backspace:
            // Option alone: encoded above. Control+Backspace is ^H.
            return modifiedKey(held.contains(.control) ? 0x08 : 0x7F, code: 127)
        case KeyCode.escape:
            if isEnhancedKeyboardProtocolActive { return csi(held.isEmpty ? "27u" : "27;\(parameter)u") }
            return Data([0x1B])
        default:
            break
        }
        if isEnhancedKeyboardProtocolActive, held.contains(.control) || alt {
            // The kitty keyboard protocol: `CSI code ; m u`, the code being
            // the key's unshifted character (Control+Shift+A is `CSI 97 ; 6 u`).
            guard let code = kittyKeyCode(
                unshiftedCharacters: unshiftedCharacters, charactersIgnoringModifiers: charactersIgnoringModifiers
            ) else { return nil }
            return csi("\(code);\(parameter)u")
        }
        if held.contains(.control) {
            guard let control = controlData(charactersIgnoringModifiers: charactersIgnoringModifiers, keyCode: keyCode)
            else { return nil }
            return alt ? Data([0x1B]) + control : control
        }
        if alt {
            // Option as Alt: ESC, then the key as typed without Option.
            guard let base = printableText(charactersIgnoringModifiers) else { return nil }
            return Data([0x1B]) + Data(base.utf8)
        }
        // Text, as the key composed it (Option's characters included).
        guard let text = printableText(characters) else { return nil }
        return Data(text.utf8)
    }

    /// What Ghostty's surface types for a key while the program set xterm's
    /// modifyOtherKeys to level 2 (`CSI > 4 ; 2 m`) and uses legacy key
    /// encoding: Ghostty's legacy encoder in that state (`input/key_encode.zig`
    /// `legacy`, with its `function_keys.zig` table), for the event the
    /// surface gets (`text` as `surfaceText(for:optionAsAlt:)` gives it). `m`
    /// is xterm's modifier parameter, 1 plus 1 for Shift, 2 for Alt and 4
    /// for Control:
    /// - Return, Tab, Escape and Backspace with modifiers as
    ///   `CSI 27 ; m ; code ~` (Shift+Return `CSI 27 ; 2 ; 13 ~`, Option+Escape
    ///   `CSI 27 ; 3 ; 27 ~`), Option counted whatever `optionAsAlt` says;
    ///   Control+Backspace stays ^H, and Shift+Tab is `CSI Z`, Cherry's
    ///   `shift+tab=csi:Z` binding (`TerminalSettings.nativeUserKeyboardConfig`);
    /// - a key that types one character, with Control or Option as Alt, or
    ///   with Shift when that character is in `@`…`~` (letters among them)
    ///   or a space, as `CSI 27 ; m ; character ~`: Control+P is
    ///   `CSI 27 ; 5 ; 112 ~`, Control+Shift+H `CSI 27 ; 6 ; 72 ~`, Shift+A
    ///   `CSI 27 ; 2 ; 65 ~`; Option that composes is not counted (Option+8
    ///   as `[` types `[`);
    /// - arrows, Home, End, Page Up/Down, Forward Delete and F1–F12 as
    ///   without it, with `m` (F3 with modifiers is `CSI 13 ; m ~`, as in
    ///   Ghostty); keypad keys as their character; other text as typed.
    /// A key whose text is not one character goes as in legacy encoding:
    /// Control with a letter key as its C0 byte, Alt as ESC and the key.
    private static func modifyOtherKeysData(
        keyCode: UInt16,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        text: String?,
        unshiftedCharacters: String?,
        usesApplicationCursorKeys: Bool,
        optionAsAlt: OptionAsAlt
    ) -> Data? {
        let held = eventModifiers.intersection(.deviceIndependentFlagsMask).intersection([.shift, .control, .option])
        let alt = optionAsAlt.applies(to: eventModifiers)
        func parameter(_ modifiers: NSEvent.ModifierFlags) -> Int {
            1 + (modifiers.contains(.shift) ? 1 : 0) + (modifiers.contains(.option) ? 2 : 0)
                + (modifiers.contains(.control) ? 4 : 0)
        }
        let m = parameter(held)
        /// Return, Tab, Escape or Backspace with modifiers.
        func otherKey(_ code: Int) -> Data { csi("27;\(m);\(code)~") }

        if let key = functionKeys[keyCode] {
            if held.isEmpty {
                return key.final == "~" ? csi("\(key.number)~") : Data("\u{1B}O\(key.final)".utf8)
            }
            if keyCode == KeyCode.f3 { return csi("13;\(m)~") }
            return key.final == "~" ? csi("\(key.number);\(m)~") : csi("1;\(m)\(key.final)")
        }
        if let keypad = keypadKeys[keyCode] {
            return Data(keypad.utf8)
        }
        switch keyCode {
        case KeyCode.up, KeyCode.down, KeyCode.right, KeyCode.left, KeyCode.home, KeyCode.end:
            let final = [
                KeyCode.up: "A", KeyCode.down: "B", KeyCode.right: "C", KeyCode.left: "D",
                KeyCode.home: "H", KeyCode.end: "F",
            ][keyCode] ?? "A"
            guard held.isEmpty else { return csi("1;\(m)\(final)") }
            return Data(((usesApplicationCursorKeys ? "\u{1B}O" : "\u{1B}[") + final).utf8)
        case KeyCode.pageUp:
            return csi(held.isEmpty ? "5~" : "5;\(m)~")
        case KeyCode.pageDown:
            return csi(held.isEmpty ? "6~" : "6;\(m)~")
        case KeyCode.forwardDelete:
            return csi(held.isEmpty ? "3~" : "3;\(m)~")
        case KeyCode.returnKey:
            return held.isEmpty ? Data([0x0D]) : otherKey(13)
        case KeyCode.tab:
            if held.isEmpty { return Data([0x09]) }
            return held == .shift ? csi("Z") : otherKey(9)
        case KeyCode.escape:
            return held.isEmpty ? Data([0x1B]) : otherKey(27)
        case KeyCode.backspace:
            if held.isEmpty { return Data([0x7F]) }
            return held == .control ? Data([0x08]) : otherKey(127)
        default:
            break
        }
        // Option that composes the text is not a modifier here.
        var textModifiers = held
        if !alt { textModifiers.remove(.option) }
        if let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first {
            let modifies = (0x40...0x7F).contains(scalar.value) || scalar.value == 0x20
                || !textModifiers.subtracting(.shift).isEmpty
            if modifies, !textModifiers.isEmpty {
                return csi("27;\(parameter(textModifiers));\(scalar.value)~")
            }
            guard let typed = printableText(text) else { return nil }
            return Data(typed.utf8)
        }
        // No single character: as without modifyOtherKeys.
        if held.subtracting(.option) == .control, let letter = letterKeys[keyCode] {
            return (alt ? Data([0x1B]) : Data()) + Data([letter - 0x60])
        }
        guard let typed = printableText(text) ?? (alt ? printableText(unshiftedCharacters) : nil) else { return nil }
        return alt ? Data([0x1B]) + Data(typed.utf8) : Data(typed.utf8)
    }

    /// The text Ghostty's surface takes a key to type, as libghostty-spm
    /// gives it (`TerminalKeyEventHandler`, `filteredCharacters`): the
    /// characters with the key's modifiers, but without Option when it acts
    /// as Alt (`ghostty_surface_key_translation_mods`), and without Control
    /// when that makes a control character (Control+Shift+H types `H`).
    static func surfaceText(for event: NSEvent, optionAsAlt: OptionAsAlt) -> String? {
        var modifiers = event.modifierFlags
        let translated = optionAsAlt.applies(to: modifiers)
        if translated { modifiers.remove(.option) }
        var text = translated ? event.characters(byApplyingModifiers: modifiers) : event.characters
        if let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first, scalar.value < 0x20 {
            modifiers.remove(.control)
            text = event.characters(byApplyingModifiers: modifiers)
        }
        return text
    }

    /// `surfaceText(for:optionAsAlt:)` from an event's characters alone:
    /// `charactersIgnoringModifiers` (Shift only) when Option acts as Alt
    /// or Control made a control character, else `characters`. Unlike the
    /// event's own, it cannot tell what Control+Option types when Option
    /// composes, and takes the key without both.
    private static func surfaceText(
        characters: String?,
        charactersIgnoringModifiers: String?,
        optionActsAsAlt: Bool
    ) -> String? {
        if optionActsAsAlt { return charactersIgnoringModifiers }
        if let scalars = characters?.unicodeScalars, scalars.count == 1, let scalar = scalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F {
            return charactersIgnoringModifiers
        }
        return characters
    }

    /// What Control and a key type: its C0 byte (Control+A is 0x01,
    /// Control+[ is ESC, Control+/ is 0x1F, Control+? is DEL), or the key
    /// itself when Control changes nothing about it in a legacy terminal
    /// (Control+1). Nil when the key types no character.
    private static func controlData(charactersIgnoringModifiers: String?, keyCode: UInt16) -> Data? {
        guard let typed = charactersIgnoringModifiers, typed.unicodeScalars.count == 1,
              let scalar = typed.lowercased().unicodeScalars.first
        else { return nil }
        guard scalar.isASCII else {
            // A letter of a non-Latin layout: the key's Latin letter.
            return letterKeys[keyCode].map { Data([$0 - 0x60]) }
        }
        switch scalar {
        case "a"..."z":
            return Data([UInt8(scalar.value - 0x60)])
        case "@", " ", "2":
            return Data([0x00])
        case "[", "3":
            return Data([0x1B])
        case "\\", "4":
            return Data([0x1C])
        case "]", "5":
            return Data([0x1D])
        case "^", "6":
            return Data([0x1E])
        case "_", "-", "7", "/":
            return Data([0x1F])
        case "?", "8":
            return Data([0x7F])
        case "!"..."~":
            return Data([UInt8(scalar.value)])
        default:
            return nil
        }
    }

    /// The kitty keyboard protocol's code for a key that types a
    /// character: that character without modifiers, as one code point.
    private static func kittyKeyCode(unshiftedCharacters: String?, charactersIgnoringModifiers: String?) -> UInt32? {
        let key = printableText(unshiftedCharacters) ?? printableText(charactersIgnoringModifiers)?.lowercased()
        guard let scalars = key?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else { return nil }
        return scalar.value
    }

    /// `text` when it is something to type: no control characters, and
    /// none of AppKit's function-key characters (U+F700…).
    private static func printableText(_ text: String?) -> String? {
        guard let text, !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return text
    }

    private static func csi(_ body: String) -> Data {
        Data(("\u{1B}[" + body).utf8)
    }
}
