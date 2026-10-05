import AppKit
import CherryControl
import CryptoKit
import Foundation
import os

/// Continuous attention sampling (docs/attention-classifier.md, "Collect
/// Samples Continuously"): every agent tab's screen, the classifier's
/// inputs and verdict, and the user's interactions with the tab, written
/// locally so `Scripts/attention-autolabel` can label them from what
/// happened next. Nothing here leaves the Mac.
enum TerminalAttentionSampling {
    static let enabledDefaultsKey = "attention.collectSamples"
    /// The user's own local install (`Scripts/install-local-app`), the one
    /// identity whose user agreed to collection: sampling defaults on only
    /// there. Tests, CherryDev, packaged builds and `swift run` (no bundle
    /// identifier) default off, and nothing is written for them unless
    /// someone turns the setting on.
    static let ownInstallBundleIdentifier = "dev.patrick.cherry.local"
    static let maximumManagedBytes: Int64 = 200 * 1_024 * 1_024
    /// Samples and heartbeats one day file may take (events always go):
    /// about twice the busiest day measured (6.6 MB over ten agent tabs).
    static let maximumDailyBytes: Int64 = 16 * 1_024 * 1_024
    static let periodicInterval: TimeInterval = 30
    /// The longest gap between heartbeats of a tab whose screen stays as
    /// its last sample: they back off from every check to this.
    static let maximumHeartbeatInterval: TimeInterval = 300
    /// A periodic sample whose screen differs from the tab's last one only
    /// in animation (`TerminalAttentionSampler.animationKey`) is skipped
    /// until the last one is this old.
    static let animationRefreshInterval: TimeInterval = 300
    /// While the tab works (live lines in this and its last sample, the
    /// same turn, state and prediction), a periodic sample is written at
    /// most this often; heartbeats carry its live lines in between.
    static let workingSampleInterval: TimeInterval = 120
    /// Lines of each sample's screen tail, up to its last line with text.
    static let screenTailLineLimit = 60
    /// A screen change this soon after a key, input or resize is its
    /// effect, not the program's own output.
    static let inputEchoWindow: TimeInterval = 1.5

    static func defaultEnabled(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == ownInstallBundleIdentifier
    }

    /// The setting, else its default for this identity. Never written here:
    /// only the Settings toggle stores a value.
    static func isEnabled(
        defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        switch defaults.object(forKey: enabledDefaultsKey) {
        case let value as String:
            switch value.lowercased() {
            case "1", "yes", "true": return true
            case "0", "no", "false": return false
            default: break
            }
        case let value as Bool:
            return value
        default:
            break
        }
        return defaultEnabled(bundleIdentifier: bundleIdentifier)
    }

    /// `<Application Support>/<identity>/Attention Study/Samples`.
    static func samplesDirectoryURL(fileManager: FileManager = .default) -> URL {
        TerminalAttentionStudy.recordingsDirectoryURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("Samples", isDirectory: true)
    }

    /// A pseudonymous stable id: the first 16 hex digits of the SHA-256 of
    /// the UUID's string. `Scripts/attention-autolabel` hashes a correction's
    /// `session.id` the same way to keep its tab out of training.
    static func stableID(_ uuid: UUID) -> String {
        stableID(uuid.uuidString)
    }

    static func stableID(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The day file (`yyyy-MM-dd.jsonl`, local time) a record belongs to.
    static func dayFileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDayFileName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil
    }
}

/// One sample of an agent tab: what the classifier saw and said, the turn's
/// lifecycle, and the screen's tail. `observation` is the classifier's
/// input exactly (its `terminal.grid` holds only the tail; the feature
/// fields, including `scrollbackLinesOmitted`, are the full screen's), and
/// `features` is `TerminalAttentionClassifier.features(for:)` of it.
struct TerminalAttentionSample: Codable, Equatable, Sendable {
    /// 2: `changes` count from the tab's previous record, a sample or a
    /// heartbeat (1: from its previous sample), and heartbeats may carry
    /// `liveLines`.
    static let currentSchemaVersion = 2
    static let recordType = "sample"

    enum Trigger: String, Codable, Equatable, Sendable {
        /// The 30 s cadence.
        case periodic
        /// Cherry's activity state, its evidence, the turn or the
        /// prediction changed.
        case stateChanged = "state_changed"
    }

    struct Prediction: Codable, Equatable, Sendable {
        let modelID: String
        let attentionProbability: Double
        let threshold: Double
        let label: TerminalAttentionLabel
        /// The rule that decided over the score: `not_started`,
        /// `live_work` or `answer_menu`.
        let rule: String?

        init(_ prediction: TerminalAttentionPrediction) {
            modelID = prediction.modelID
            attentionProbability = prediction.attentionProbability
            threshold = prediction.threshold
            label = prediction.label
            rule = prediction.isGatedBeforeFirstTurn ? "not_started"
                : prediction.isGatedByLiveWork ? "live_work"
                : prediction.isRaisedByAnswerMenu ? "answer_menu"
                : nil
        }
    }

    struct Lifecycle: Codable, Equatable, Sendable {
        let turnState: TerminalAttentionTurnState
        let submittedTurns: Int
        let selfResumedTurns: Int
        let lastSubmitAt: Date?
        let lastOutputAt: Date?
        let lastContentChangeAt: Date?
        let lastStrongWorkingEvidenceAt: Date?
        let lastKeystrokeAt: Date?
        let lastInputAt: Date?
        let alertGeneration: Int
        let hasUnacknowledgedAttention: Bool
    }

    /// Screen changes since the tab's previous record (sample or heartbeat).
    struct Changes: Codable, Equatable, Sendable {
        static let maximumRecordedTimes = 600

        var contentChanges = 0
        /// Changes no key, input or resize caused (none in the 1.5 s
        /// before): the program changed its screen by itself.
        var selfDrivenChanges = 0
        /// When they happened, in seconds since 1970 (a tenth of a second
        /// precision), at most one a second and the first 600: what
        /// hindsight labels read to tell work from a waiting screen.
        var selfDrivenChangeTimes: [Double] = []

        mutating func noteSelfDrivenChange(at date: Date) {
            selfDrivenChanges += 1
            let seconds = (date.timeIntervalSince1970 * 10).rounded() / 10
            guard selfDrivenChangeTimes.count < Self.maximumRecordedTimes,
                  selfDrivenChangeTimes.last.map({ seconds - $0 >= 1 }) ?? true
            else { return }
            selfDrivenChangeTimes.append(seconds)
        }
    }

    struct Screen: Codable, Equatable, Sendable {
        /// The row of the viewport grid where the tail starts.
        let tailStartRow: Int
        let viewportGridRows: Int
        /// `AgentScreenActivity.workingLines` of the tail: what advances
        /// while the agent works.
        let liveLines: [String]
        /// `AgentScreenActivity.verdict` of the tail.
        let verdict: String
    }

    let type: String
    let schemaVersion: Int
    let id: UUID
    let recordedAt: Date
    let trigger: Trigger
    /// `TerminalAttentionSampling.stableID` of the tab, and of the launch
    /// of its program (a restart is a new run).
    let tab: String
    let run: String
    /// The persistent or attached session's id, hashed the same way.
    let hostSession: String?
    /// The screen rules' agent key (`claude`, `codex`, `pi`, `amp`, …).
    let agent: String
    /// `persistent`, `device`, `attached` or `native`.
    let backend: String
    let observation: TerminalAttentionObservation
    let features: [String: Double]
    /// The classifier's verdict for `observation`.
    let prediction: Prediction
    /// What the tab shows now (its last observation's verdict).
    let shownPrediction: Prediction?
    let lifecycle: Lifecycle
    let screen: Screen
    var changes: Changes
}

/// An interaction between samples: its kind and time only, never what was
/// typed or shown.
struct TerminalAttentionSampleEvent: Codable, Equatable, Sendable {
    static let recordType = "event"

    enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        /// Keys that edit the composer's draft (at most one every 2 s).
        case typed
        case submitted
        /// A key answered a permission or question menu (`detail`: which).
        case menuKey = "menu_key"
        /// Escape or Control-C during a turn.
        case interrupted
        /// The tab was selected or shown (at most one every 5 s).
        case focused
        /// The tab closed (`detail`: the `SessionCloseIntent`).
        case closed
        case bell
        case notification
        /// The program exited (`detail`: its status).
        case exited
    }

    let type: String
    let schemaVersion: Int
    let recordedAt: Date
    let tab: String
    let run: String
    let kind: Kind
    /// An enumerated qualifier, never content.
    let detail: String?
}

/// A periodic check skipped a sample: the tab's previous sample still
/// describes it, apart from animation or, while it works, its live lines.
struct TerminalAttentionSampleHeartbeat: Codable, Equatable, Sendable {
    static let recordType = "unchanged"

    let type: String
    let schemaVersion: Int
    let recordedAt: Date
    let tab: String
    let run: String
    let sample: UUID
    /// Since the tab's previous record.
    let changes: TerminalAttentionSample.Changes
    /// The screen's live lines, when they read differently from the tab's
    /// previous record: what tells hindsight labels the agent still works.
    var liveLines: [String]? = nil
}

/// Appends sample records to one private file per day, off the main
/// thread and in batches, and keeps the directory under its size cap by
/// removing the oldest days first. A day file stops taking samples and
/// heartbeats at `maximumDailyBytes`; events, small and rate-limited, still
/// go (hindsight labels read them).
final class TerminalAttentionSampleWriter: @unchecked Sendable {
    enum Record: Sendable {
        case sample(TerminalAttentionSample)
        case event(TerminalAttentionSampleEvent)
        case unchanged(TerminalAttentionSampleHeartbeat)

        var recordedAt: Date {
            switch self {
            case .sample(let sample): sample.recordedAt
            case .event(let event): event.recordedAt
            case .unchanged(let heartbeat): heartbeat.recordedAt
            }
        }

        var isEvent: Bool {
            if case .event = self { return true }
            return false
        }
    }

    let directoryURL: URL
    let maximumBytes: Int64
    let maximumDailyBytes: Int64

    private let flushInterval: TimeInterval
    private let maximumBufferedBytes: Int
    private let timeZone: TimeZone
    private let queue = DispatchQueue(label: "Cherry.TerminalAttentionSampleWriter", qos: .utility)
    private static let logger = Logger(subsystem: SessionLog.subsystem, category: "AttentionSamples")

    // Confined to `queue`.
    private var pending: [(day: String, line: Data, isEvent: Bool)] = []
    private var pendingBytes = 0
    private var isFlushScheduled = false
    private var totalBytes: Int64?
    /// Each day file's size, read when the writer first touches it.
    private var dayBytes: [String: Int64] = [:]
    private var reportedFailure = false
    private var reportedCap = false
    private var reportedDailyCap: Set<String> = []
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Milliseconds: hindsight labels compare event and sample times.
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(
        directoryURL: URL,
        maximumBytes: Int64 = TerminalAttentionSampling.maximumManagedBytes,
        maximumDailyBytes: Int64 = TerminalAttentionSampling.maximumDailyBytes,
        flushInterval: TimeInterval = 5,
        maximumBufferedBytes: Int = 64 * 1_024,
        timeZone: TimeZone = .current
    ) {
        self.directoryURL = directoryURL
        self.maximumBytes = maximumBytes
        self.maximumDailyBytes = maximumDailyBytes
        self.flushInterval = flushInterval
        self.maximumBufferedBytes = maximumBufferedBytes
        self.timeZone = timeZone
    }

    func append(_ record: Record) {
        queue.async { [self] in
            guard let line = encode(record) else { return }
            pending.append((
                TerminalAttentionSampling.dayFileName(for: record.recordedAt, timeZone: timeZone),
                line,
                record.isEvent
            ))
            pendingBytes += line.count
            if pendingBytes >= maximumBufferedBytes {
                writePending()
            } else if !isFlushScheduled {
                isFlushScheduled = true
                queue.asyncAfter(deadline: .now() + flushInterval) { [self] in
                    isFlushScheduled = false
                    writePending()
                }
            }
        }
    }

    /// Writes what is buffered now and returns once it is on disk.
    func flush() {
        queue.sync { writePending() }
    }

    private func encode(_ record: Record) -> Data? {
        var data: Data?
        switch record {
        case .sample(let sample): data = try? encoder.encode(sample)
        case .event(let event): data = try? encoder.encode(event)
        case .unchanged(let heartbeat): data = try? encoder.encode(heartbeat)
        }
        data?.append(0x0A)
        return data
    }

    private func writePending() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        pendingBytes = 0
        do {
            try prepareDirectory()
        } catch {
            reportFailure("could not create \(directoryURL.path): \(error.localizedDescription)")
            return
        }
        if totalBytes == nil {
            totalBytes = managedFiles().reduce(0) { $0 + $1.bytes }
        }

        var days: [String] = []
        var lines: [String: Data] = [:]
        for (day, line, isEvent) in batch {
            if lines[day] == nil {
                days.append(day)
                lines[day] = Data()
            }
            let dayTotal = bytesOfDay(day) + Int64(lines[day]?.count ?? 0)
            if !isEvent, dayTotal + Int64(line.count) > maximumDailyBytes {
                if reportedDailyCap.insert(day).inserted {
                    Self.logger.notice("attention samples of \(day, privacy: .public) reached their \(self.maximumDailyBytes) byte daily cap; only events are kept until a new day")
                }
                continue
            }
            lines[day]?.append(line)
        }
        for day in days {
            guard let data = lines[day], !data.isEmpty else { continue }
            makeRoom(for: Int64(data.count), keeping: day)
            guard (totalBytes ?? 0) + Int64(data.count) <= maximumBytes else {
                // Only this day is left and it is full: drop until tomorrow.
                if !reportedCap {
                    reportedCap = true
                    Self.logger.notice("attention samples reached their \(self.maximumBytes) byte cap; dropping until a new day")
                }
                continue
            }
            do {
                try append(data, toFileNamed: day)
                totalBytes = (totalBytes ?? 0) + Int64(data.count)
                dayBytes[day] = bytesOfDay(day) + Int64(data.count)
            } catch {
                reportFailure("could not write \(day): \(error.localizedDescription)")
            }
        }
    }

    /// The day file's size as this writer knows it, read from disk once.
    private func bytesOfDay(_ day: String) -> Int64 {
        if let known = dayBytes[day] { return known }
        let path = directoryURL.appendingPathComponent(day).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
        dayBytes[day] = size
        return size
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )
    }

    private func managedFiles() -> [(name: String, bytes: Int64)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .filter(TerminalAttentionSampling.isDayFileName)
            .sorted()
            .compactMap { name in
                let path = directoryURL.appendingPathComponent(name).path
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular
                else { return nil }
                return (name, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
            }
    }

    /// Removes the oldest day files (never `keeping`) until `incoming`
    /// more bytes fit under the cap.
    private func makeRoom(for incoming: Int64, keeping day: String) {
        guard (totalBytes ?? 0) + incoming > maximumBytes else { return }
        var total = managedFiles().reduce(Int64(0)) { $0 + $1.bytes }
        for file in managedFiles() where file.name != day && total + incoming > maximumBytes {
            do {
                try FileManager.default.removeItem(at: directoryURL.appendingPathComponent(file.name))
                total -= file.bytes
                dayBytes.removeValue(forKey: file.name)
            } catch {
                reportFailure("could not remove \(file.name): \(error.localizedDescription)")
            }
        }
        totalBytes = total
    }

    private func append(_ data: Data, toFileNamed name: String) throws {
        let path = directoryURL.appendingPathComponent(name).path
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fchmod(descriptor, 0o600)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func reportFailure(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Self.logger.error("attention samples: \(message, privacy: .public)")
    }
}

/// Samples every agent tab about every 30 s, and whenever the tab's state
/// changes, skipping a sample its previous one already holds. Tabs register
/// while their program runs; the timer runs only while sampling is on and
/// an agent tab is registered.
///
/// A periodic sample is skipped, and a heartbeat may be written instead,
/// when its screen and features repeat the tab's last sample; when they
/// differ only in animation (`animationKey`) and the last sample is under
/// `animationRefreshInterval` old; or while the tab works
/// (`isSameWork`) and the last sample is under `workingSampleInterval`
/// old. A heartbeat carries the live lines whenever they read differently
/// from the tab's previous record; otherwise heartbeats back off from
/// every check to one every `maximumHeartbeatInterval`.
@MainActor
final class TerminalAttentionSampler {
    static let shared = TerminalAttentionSampler()

    let interval: TimeInterval
    /// Sampling is on: tabs record into it. Read on every hook, so a tab
    /// does no sampling work while it is off.
    private(set) var isCollecting: Bool

    private let isEnabledProvider: @MainActor () -> Bool
    private let directoryProvider: @MainActor () -> URL
    private let maximumBytes: Int64
    private let maximumDailyBytes: Int64
    private let flushInterval: TimeInterval
    private let schedulesTimer: Bool
    private var writer: TerminalAttentionSampleWriter?
    private var sessions: [ObjectIdentifier: WeakSession] = [:]
    private var timer: Timer?
    private var lastSamples: [String: LastSample] = [:]
    private var changes: [String: TerminalAttentionSample.Changes] = [:]

    /// A tab run's last written sample, and its records since.
    private struct LastSample {
        let key: Int
        let animationKey: Int
        let work: WorkKey?
        let id: UUID
        let recordedAt: Date
        /// The tab's last record, sample or heartbeat.
        var lastRecordAt: Date
        /// The live lines its last record showed.
        var liveLines: [String]
        /// How long after `lastRecordAt` the next plain heartbeat is due:
        /// none yet after the sample, then doubling to the maximum.
        var heartbeatDelay: TimeInterval = 0
    }

    /// What must stay the same for samples to show one stretch of work.
    struct WorkKey: Hashable {
        let turnState: TerminalAttentionTurnState
        let submittedTurns: Int
        let selfResumedTurns: Int
        let activityState: String
        let label: TerminalAttentionLabel
        let rule: String?
    }
    private var lastRateLimitedEventAt: [String: Date] = [:]
    private var terminationObserver: NSObjectProtocol?

    private static let rateLimits: [TerminalAttentionSampleEvent.Kind: TimeInterval] = [
        .typed: 2,
        .focused: 5,
    ]

    private struct WeakSession {
        weak var session: TerminalSession?
    }

    init(
        interval: TimeInterval = TerminalAttentionSampling.periodicInterval,
        maximumBytes: Int64 = TerminalAttentionSampling.maximumManagedBytes,
        maximumDailyBytes: Int64 = TerminalAttentionSampling.maximumDailyBytes,
        flushInterval: TimeInterval = 5,
        schedulesTimer: Bool = true,
        isEnabled: @escaping @MainActor () -> Bool = { TerminalAttentionSampling.isEnabled() },
        directoryURL: @escaping @MainActor () -> URL = { TerminalAttentionSampling.samplesDirectoryURL() }
    ) {
        self.interval = interval
        self.maximumBytes = maximumBytes
        self.maximumDailyBytes = maximumDailyBytes
        self.flushInterval = flushInterval
        self.schedulesTimer = schedulesTimer
        self.isEnabledProvider = isEnabled
        self.directoryProvider = directoryURL
        self.isCollecting = isEnabled()
    }

    /// The setting changed: start or stop.
    func settingDidChange() {
        let enabled = isEnabledProvider()
        guard enabled != isCollecting else { return }
        isCollecting = enabled
        if !enabled {
            writer?.flush()
            lastSamples.removeAll()
            changes.removeAll()
            lastRateLimitedEventAt.removeAll()
        }
        updateTimer()
    }

    var registeredSessionCount: Int {
        sessions.values.filter { $0.session != nil }.count
    }

    var isTimerRunning: Bool { timer != nil }

    func register(_ session: TerminalSession) {
        sessions[ObjectIdentifier(session)] = WeakSession(session: session)
        updateTimer()
    }

    func unregister(_ session: TerminalSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        updateTimer()
    }

    /// The tab's run ended for good (closed): forget its state.
    func forget(tab: String, run: String) {
        let key = Self.key(tab: tab, run: run)
        lastSamples.removeValue(forKey: key)
        changes.removeValue(forKey: key)
        lastRateLimitedEventAt = lastRateLimitedEventAt.filter { !$0.key.hasPrefix(key + "|") }
    }

    /// The periodic pass: one sample (or heartbeat) per registered tab.
    func tick() {
        sessions = sessions.filter { $0.value.session != nil }
        guard isCollecting else {
            updateTimer()
            return
        }
        for entry in sessions.values {
            guard let session = entry.session,
                  let sample = session.makePeriodicAttentionSample()
            else { continue }
            record(sample)
        }
        updateTimer()
    }

    /// The tab's screen changed; `selfDriven` when no key, input or resize
    /// caused it.
    func noteContentChange(tab: String, run: String, selfDriven: Bool, at date: Date) {
        guard isCollecting else { return }
        let key = Self.key(tab: tab, run: run)
        var tally = changes[key] ?? .init()
        tally.contentChanges += 1
        if selfDriven {
            tally.noteSelfDrivenChange(at: date)
        }
        changes[key] = tally
    }

    /// Writes `sample` unless the tab's previous sample already holds it
    /// (see the type's comment; a skipped periodic one may write a
    /// heartbeat). Returns whether the sample was written.
    @discardableResult
    func record(_ sample: TerminalAttentionSample) -> Bool {
        guard isCollecting else { return false }
        let key = Self.key(tab: sample.tab, run: sample.run)
        let dedupeKey = Self.dedupeKey(of: sample)
        if var last = lastSamples[key] {
            if last.key == dedupeKey {
                if sample.trigger == .periodic {
                    writeHeartbeatIfDue(&last, for: sample, key: key, liveLines: nil)
                    lastSamples[key] = last
                }
                return false
            }
            if sample.trigger == .periodic, skipsPeriodic(sample, after: last) {
                let liveLines = sample.screen.liveLines
                writeHeartbeatIfDue(
                    &last,
                    for: sample,
                    key: key,
                    liveLines: liveLines == last.liveLines ? nil : liveLines
                )
                lastSamples[key] = last
                return false
            }
        }
        var written = sample
        written.changes = changes[key] ?? .init()
        lastSamples[key] = LastSample(
            key: dedupeKey,
            animationKey: Self.animationKey(of: sample),
            work: Self.workKey(of: sample),
            id: sample.id,
            recordedAt: sample.recordedAt,
            lastRecordAt: sample.recordedAt,
            liveLines: sample.screen.liveLines
        )
        changes.removeValue(forKey: key)
        activeWriter().append(.sample(written))
        return true
    }

    /// A periodic `sample` that differs from the tab's last one only in
    /// animation, or shows the same stretch of work, while that one is
    /// recent.
    private func skipsPeriodic(_ sample: TerminalAttentionSample, after last: LastSample) -> Bool {
        let age = sample.recordedAt.timeIntervalSince(last.recordedAt)
        if age < TerminalAttentionSampling.animationRefreshInterval,
           Self.animationKey(of: sample) == last.animationKey {
            return true
        }
        if age < TerminalAttentionSampling.workingSampleInterval,
           let work = Self.workKey(of: sample), work == last.work {
            return true
        }
        return false
    }

    /// A heartbeat now when the live lines advanced (`liveLines`), else
    /// when the backed-off delay since the tab's last record passed.
    private func writeHeartbeatIfDue(
        _ last: inout LastSample,
        for sample: TerminalAttentionSample,
        key: String,
        liveLines: [String]?
    ) {
        let elapsed = sample.recordedAt.timeIntervalSince(last.lastRecordAt)
        // Half a period of slack: the timer fires with tolerance.
        guard liveLines != nil || elapsed >= last.heartbeatDelay - interval / 2 else { return }
        activeWriter().append(.unchanged(.init(
            type: TerminalAttentionSampleHeartbeat.recordType,
            schemaVersion: TerminalAttentionSample.currentSchemaVersion,
            recordedAt: sample.recordedAt,
            tab: sample.tab,
            run: sample.run,
            sample: last.id,
            changes: changes[key] ?? .init(),
            liveLines: liveLines
        )))
        changes.removeValue(forKey: key)
        last.lastRecordAt = sample.recordedAt
        if let liveLines {
            last.liveLines = liveLines
            last.heartbeatDelay = 0
        } else {
            last.heartbeatDelay = min(
                TerminalAttentionSampling.maximumHeartbeatInterval,
                max(interval, last.heartbeatDelay * 2)
            )
        }
    }

    func recordEvent(
        _ kind: TerminalAttentionSampleEvent.Kind,
        detail: String?,
        tab: String,
        run: String,
        at date: Date
    ) {
        guard isCollecting else { return }
        if let limit = Self.rateLimits[kind] {
            let limitKey = Self.key(tab: tab, run: run) + "|" + kind.rawValue
            if let last = lastRateLimitedEventAt[limitKey], date.timeIntervalSince(last) < limit {
                return
            }
            lastRateLimitedEventAt[limitKey] = date
        }
        activeWriter().append(.event(.init(
            type: TerminalAttentionSampleEvent.recordType,
            schemaVersion: TerminalAttentionSample.currentSchemaVersion,
            recordedAt: date,
            tab: tab,
            run: run,
            kind: kind,
            detail: detail
        )))
    }

    /// Writes buffered records now.
    func flush() {
        writer?.flush()
    }

    private func activeWriter() -> TerminalAttentionSampleWriter {
        if let writer { return writer }
        let writer = TerminalAttentionSampleWriter(
            directoryURL: directoryProvider(),
            maximumBytes: maximumBytes,
            maximumDailyBytes: maximumDailyBytes,
            flushInterval: flushInterval
        )
        self.writer = writer
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [writer] _ in
                writer.flush()
            }
        }
        return writer
    }

    private func updateTimer() {
        let wantsTimer = schedulesTimer && isCollecting && sessions.values.contains { $0.session != nil }
        if wantsTimer, timer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            timer.tolerance = min(5, interval / 6)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wantsTimer, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private static func key(tab: String, run: String) -> String {
        tab + "|" + run
    }

    /// What must differ for a sample to be new: the screen and every
    /// feature but the elapsed times, which always advance, and the event
    /// that made the tab's last observation (a periodic sample reuses it;
    /// it says nothing about the screen).
    static func dedupeKey(of sample: TerminalAttentionSample) -> Int {
        var hasher = Hasher()
        let terminal = sample.observation.terminal
        hasher.combine(terminal.grid)
        hasher.combine(terminal.cursor.column)
        hasher.combine(sample.screen.liveLines)
        combineState(of: sample, into: &hasher)
        return hasher.finalize()
    }

    /// The dedupe key with the screen's animation left out: its live lines,
    /// the leading symbols and spaces of every other line (a spinner, a
    /// blinking `⏺`), digits (clocks, token counts), trailing spaces and
    /// the cursor's column.
    static func animationKey(of sample: TerminalAttentionSample) -> Int {
        var hasher = Hasher()
        let liveLines = Set(sample.screen.liveLines.map { $0.trimmingCharacters(in: .whitespaces) })
        for line in sample.observation.terminal.grid {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, liveLines.contains(trimmed) {
                hasher.combine(0 as UInt8)
            } else {
                hasher.combine(animationFreeText(of: line))
            }
        }
        combineState(of: sample, into: &hasher)
        return hasher.finalize()
    }

    /// The sample's stretch of work, when its screen shows live lines.
    static func workKey(of sample: TerminalAttentionSample) -> WorkKey? {
        guard !sample.screen.liveLines.isEmpty else { return nil }
        return WorkKey(
            turnState: sample.lifecycle.turnState,
            submittedTurns: sample.lifecycle.submittedTurns,
            selfResumedTurns: sample.lifecycle.selfResumedTurns,
            activityState: sample.observation.activity.state,
            label: sample.prediction.label,
            rule: sample.prediction.rule
        )
    }

    /// `line` from its first letter or digit, without trailing spaces, each
    /// run of digits as `#`.
    static func animationFreeText(of line: String) -> String {
        let scalars = line.unicodeScalars
            .drop { !CharacterSet.alphanumerics.contains($0) }
        var text = String(String.UnicodeScalarView(scalars))
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        var result = ""
        var inDigits = false
        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                if !inDigits { result.append("#") }
                inDigits = true
            } else {
                result.unicodeScalars.append(scalar)
                inDigits = false
            }
        }
        return result
    }

    private static func combineState(of sample: TerminalAttentionSample, into hasher: inout Hasher) {
        let terminal = sample.observation.terminal
        hasher.combine(terminal.columns)
        hasher.combine(terminal.rows)
        hasher.combine(terminal.usesAlternateScreen)
        hasher.combine(terminal.cursor.row)
        hasher.combine(terminal.cursor.isVisible)
        for name in sample.features.keys.sorted()
        where !name.hasPrefix("numeric.") && !name.hasPrefix("category.event=") {
            hasher.combine(name)
            hasher.combine(sample.features[name])
        }
        hasher.combine(sample.prediction.label.rawValue)
        hasher.combine(sample.prediction.rule)
        hasher.combine(sample.lifecycle.turnState.rawValue)
        hasher.combine(sample.lifecycle.submittedTurns)
        hasher.combine(sample.lifecycle.selfResumedTurns)
        hasher.combine(sample.backend)
    }
}

extension TerminalAttentionObservation {
    /// The observation with `grid` as its terminal's lines and the cursor
    /// row moved by `rowOffset`; its other fields, the classifier's inputs,
    /// are unchanged. `sessionID` and `runID` replace the tab's raw ids.
    func sampled(grid: [String], rowOffset: Int, sessionID: String, runID: String) -> TerminalAttentionObservation {
        TerminalAttentionObservation(
            schemaVersion: schemaVersion,
            id: id,
            recordedAt: recordedAt,
            event: event,
            label: label,
            annotation: annotation,
            scenarioID: scenarioID,
            checkpoint: checkpoint,
            session: .init(
                id: sessionID,
                kind: session.kind,
                harness: session.harness,
                harnessVersion: session.harnessVersion,
                runID: runID
            ),
            terminal: .init(
                columns: terminal.columns,
                rows: terminal.rows,
                usesAlternateScreen: terminal.usesAlternateScreen,
                cursor: .init(
                    row: terminal.cursor.row - rowOffset,
                    column: terminal.cursor.column,
                    shape: terminal.cursor.shape,
                    isVisible: terminal.cursor.isVisible
                ),
                grid: grid,
                styledGrid: nil,
                scrollbackLinesOmitted: terminal.scrollbackLinesOmitted
            ),
            timing: timing,
            activity: activity,
            interaction: interaction,
            turn: turn,
            correction: correction,
            outputVersion: outputVersion,
            contentVersion: contentVersion
        )
    }
}
