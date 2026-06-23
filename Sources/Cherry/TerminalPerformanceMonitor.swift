import Foundation
import OSLog

enum TerminalPerformanceMonitor {
    static let isEnabled = ProcessInfo.processInfo.environment["CHERRY_TERMINAL_PERF"] == "1"

    private static let store = Store()

    struct CounterSnapshot: Equatable, Sendable {
        let ptyChunks: Int
        let ptyBytes: Int
        let ghosttyFeedChunks: Int
        let ghosttyFeedBytes: Int
        let processorBacklogDropCount: Int
        let processorBacklogDroppedBytes: Int
        let backgroundOutputThrottleCount: Int
        let processorChanges: Int
        let representableUpdates: Int
        let containerConfigures: Int
        let bridgeAttaches: Int
        let reusedBridgeAttaches: Int
        let fitToSizeCalls: Int
        let settingsApplies: Int
        let settingsReconfigures: Int
        let renderTicks: Int
    }

    static func recordPTYOutputChunk(bytes: Int) {
        guard isEnabled else { return }
        store.record { counters in
            counters.ptyChunks += 1
            counters.ptyBytes += bytes
        }
    }

    static func recordGhosttyFeedChunk(bytes: Int) {
        guard isEnabled else { return }
        store.record { counters in
            counters.ghosttyFeedChunks += 1
            counters.ghosttyFeedBytes += bytes
        }
    }

    static func recordProcessorChange() {
        guard isEnabled else { return }
        store.record { $0.processorChanges += 1 }
    }

    static func recordProcessorBacklogDrop(bytes: Int) {
        guard isEnabled, bytes > 0 else { return }
        store.record { counters in
            counters.processorBacklogDropCount += 1
            counters.processorBacklogDroppedBytes += bytes
        }
    }

    static func recordBackgroundOutputThrottle() {
        guard isEnabled else { return }
        store.record { $0.backgroundOutputThrottleCount += 1 }
    }

    static func recordRepresentableUpdate() {
        guard isEnabled else { return }
        store.record { $0.representableUpdates += 1 }
    }

    static func recordContainerConfigure() {
        guard isEnabled else { return }
        store.record { $0.containerConfigures += 1 }
    }

    static func recordBridgeAttach(reused: Bool) {
        guard isEnabled else { return }
        store.record { counters in
            counters.bridgeAttaches += 1
            if reused {
                counters.reusedBridgeAttaches += 1
            }
        }
    }

    static func recordFitToSize() {
        guard isEnabled else { return }
        store.record { $0.fitToSizeCalls += 1 }
    }

    static func recordSettingsApply(reconfigured: Bool) {
        guard isEnabled else { return }
        store.record { counters in
            counters.settingsApplies += 1
            if reconfigured {
                counters.settingsReconfigures += 1
            }
        }
    }

    static func recordRenderTick() {
        guard isEnabled else { return }
        store.record { $0.renderTicks += 1 }
    }

    static func snapshot() -> CounterSnapshot {
        store.snapshot()
    }

    private struct Counters {
        var ptyChunks = 0
        var ptyBytes = 0
        var ghosttyFeedChunks = 0
        var ghosttyFeedBytes = 0
        var processorBacklogDropCount = 0
        var processorBacklogDroppedBytes = 0
        var backgroundOutputThrottleCount = 0
        var processorChanges = 0
        var representableUpdates = 0
        var containerConfigures = 0
        var bridgeAttaches = 0
        var reusedBridgeAttaches = 0
        var fitToSizeCalls = 0
        var settingsApplies = 0
        var settingsReconfigures = 0
        var renderTicks = 0

        var snapshot: CounterSnapshot {
            CounterSnapshot(
                ptyChunks: ptyChunks,
                ptyBytes: ptyBytes,
                ghosttyFeedChunks: ghosttyFeedChunks,
                ghosttyFeedBytes: ghosttyFeedBytes,
                processorBacklogDropCount: processorBacklogDropCount,
                processorBacklogDroppedBytes: processorBacklogDroppedBytes,
                backgroundOutputThrottleCount: backgroundOutputThrottleCount,
                processorChanges: processorChanges,
                representableUpdates: representableUpdates,
                containerConfigures: containerConfigures,
                bridgeAttaches: bridgeAttaches,
                reusedBridgeAttaches: reusedBridgeAttaches,
                fitToSizeCalls: fitToSizeCalls,
                settingsApplies: settingsApplies,
                settingsReconfigures: settingsReconfigures,
                renderTicks: renderTicks
            )
        }
    }

    private struct Snapshot {
        let interval: TimeInterval
        let counters: Counters
    }

    private final class Store: @unchecked Sendable {
        private let logger = Logger(subsystem: "Cherry", category: "TerminalPerf")
        private let lock = NSLock()
        private var windowStart = Date()
        private var counters = Counters()
        private var totalCounters = Counters()

        func record(_ update: (inout Counters) -> Void) {
            let snapshot: Snapshot? = lock.withLock {
                update(&counters)
                update(&totalCounters)

                let now = Date()
                let interval = now.timeIntervalSince(windowStart)
                guard interval >= 1 else { return nil }

                let snapshot = Snapshot(interval: interval, counters: counters)
                windowStart = now
                counters = Counters()
                return snapshot
            }

            if let snapshot {
                log(snapshot)
            }
        }

        func snapshot() -> CounterSnapshot {
            lock.withLock {
                totalCounters.snapshot
            }
        }

        private func log(_ snapshot: Snapshot) {
            let interval = String(format: "%.2f", snapshot.interval)
            let c = snapshot.counters
            logger.info(
                """
                interval=\(interval, privacy: .public)s \
                pty=\(c.ptyChunks, privacy: .public)/\(c.ptyBytes, privacy: .public)B \
                ghosttyFeed=\(c.ghosttyFeedChunks, privacy: .public)/\(c.ghosttyFeedBytes, privacy: .public)B \
                processorDrop=\(c.processorBacklogDropCount, privacy: .public)/\(c.processorBacklogDroppedBytes, privacy: .public)B \
                backgroundThrottle=\(c.backgroundOutputThrottleCount, privacy: .public) \
                processor=\(c.processorChanges, privacy: .public) \
                render=\(c.renderTicks, privacy: .public) \
                representableUpdate=\(c.representableUpdates, privacy: .public) \
                configure=\(c.containerConfigures, privacy: .public) \
                attach=\(c.bridgeAttaches, privacy: .public) \
                attachReused=\(c.reusedBridgeAttaches, privacy: .public) \
                fit=\(c.fitToSizeCalls, privacy: .public) \
                settingsApply=\(c.settingsApplies, privacy: .public) \
                settingsReconfigure=\(c.settingsReconfigures, privacy: .public)
                """
            )
        }
    }
}
