import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

/// Continuous attention sampling (`TerminalAttentionSampler`): cadence and
/// dedupe, interaction events without content, the size cap, and the
/// setting. Every sampler here writes to a private temporary directory.
@MainActor
@Suite(.serialized)
struct TerminalAttentionSamplingTests {
    // MARK: Setting and identity

    @Test func samplingDefaultsOnOnlyForTheUsersOwnLocalInstall() throws {
        #expect(TerminalAttentionSampling.defaultEnabled(bundleIdentifier: "dev.patrick.cherry.local"))
        #expect(!TerminalAttentionSampling.defaultEnabled(bundleIdentifier: nil))
        #expect(!TerminalAttentionSampling.defaultEnabled(bundleIdentifier: "app.cherry.CherryDev"))
        #expect(!TerminalAttentionSampling.defaultEnabled(bundleIdentifier: "dev.patrick.cherry.sessions"))

        let (defaults, suiteName) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The test runner is not the user's install: off, and so is the
        // shared sampler every other test's agent tabs use.
        #expect(!TerminalAttentionSampling.isEnabled(defaults: defaults))
        #expect(!TerminalAttentionSampler.shared.isCollecting)
        #expect(TerminalAttentionSampling.isEnabled(defaults: defaults, bundleIdentifier: "dev.patrick.cherry.local"))

        defaults.set(false, forKey: TerminalAttentionSampling.enabledDefaultsKey)
        #expect(!TerminalAttentionSampling.isEnabled(defaults: defaults, bundleIdentifier: "dev.patrick.cherry.local"))
        // A launch argument (`-attention.collectSamples NO`) is a string.
        defaults.set("NO", forKey: TerminalAttentionSampling.enabledDefaultsKey)
        #expect(!TerminalAttentionSampling.isEnabled(defaults: defaults, bundleIdentifier: "dev.patrick.cherry.local"))
        defaults.set("YES", forKey: TerminalAttentionSampling.enabledDefaultsKey)
        #expect(TerminalAttentionSampling.isEnabled(defaults: defaults))
    }

    @Test func settingsReadTheIdentityDefaultWithoutWritingIt() throws {
        let (defaults, suiteName) = try privateDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var changes = 0
        let settings = TerminalSettings(
            defaults: defaults,
            attentionSamplesBundleIdentifier: "dev.patrick.cherry.local",
            attentionSamplesSettingDidChange: { changes += 1 }
        )
        #expect(settings.attentionSamplesEnabled)
        #expect(defaults.object(forKey: TerminalAttentionSampling.enabledDefaultsKey) == nil)
        #expect(changes == 0)

        settings.attentionSamplesEnabled = false
        #expect(defaults.object(forKey: TerminalAttentionSampling.enabledDefaultsKey) as? Bool == false)
        #expect(changes == 1)

        let other = TerminalSettings(
            defaults: try privateDefaults().0,
            attentionSamplesBundleIdentifier: "app.cherry.CherryDev",
            attentionSamplesSettingDidChange: {}
        )
        #expect(!other.attentionSamplesEnabled)
    }

    @Test func settingOffWritesNoFilesAndRunsNoTimer() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var enabled = false
        let sampler = TerminalAttentionSampler(
            interval: 60,
            isEnabled: { enabled },
            directoryURL: { directory }
        )
        let session = makeAgentSession(sampler: sampler)
        defer { session.stop() }
        await showScreen(session, ["Claude Code", "", "❯ "])

        sampler.register(session)
        #expect(!sampler.isTimerRunning)
        sampler.tick()
        session.noteAttentionSampleEvent(.focused)
        session.noteTestingInput(Data("x".utf8))
        sampler.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // On: the timer runs while an agent tab is registered, and only then.
        enabled = true
        sampler.settingDidChange()
        #expect(sampler.isTimerRunning)
        sampler.unregister(session)
        #expect(!sampler.isTimerRunning)
        sampler.register(session)
        enabled = false
        sampler.settingDidChange()
        #expect(!sampler.isTimerRunning)
    }

    // MARK: Cadence and dedupe

    @Test func periodicSamplesSkipAnUnchangedScreenWithAHeartbeat() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let session = makeAgentSession(sampler: sampler)
        defer { session.stop() }
        await showScreen(session, ["✻ Worked for 12s", "", "Done: the change is ready.", "", "❯ "])
        // Let the debounced observation (1 s) settle first.
        try await Task.sleep(for: .milliseconds(1_200))
        sampler.register(session)

        let before = try records(in: directory, sampler: sampler).count
        sampler.tick()
        sampler.tick()
        sampler.tick()
        let afterTicks = try records(in: directory, sampler: sampler)
        let ticks = Array(afterTicks.dropFirst(before))
        // A sample (none when the tab's state-change sample already holds
        // the screen), then one heartbeat naming it: checks this soon after
        // a heartbeat write nothing (heartbeats back off).
        #expect(ticks.filter { $0["type"] as? String == "sample" }.count <= 1)
        let heartbeats = ticks.filter { $0["type"] as? String == "unchanged" }
        #expect(heartbeats.count == 1)
        let lastSample = try #require(afterTicks.last { $0["type"] as? String == "sample" })
        #expect(heartbeats.first?["sample"] as? String == lastSample["id"] as? String)

        await showScreen(session, ["✻ Worked for 12s", "", "Done: the change is ready.", "Also updated the docs.", "", "❯ "])
        sampler.tick()
        let all = try records(in: directory, sampler: sampler)
        let periodic = all.filter { $0["type"] as? String == "sample" && $0["trigger"] as? String == "periodic" }
        let latest = try #require(periodic.last)
        let observation = try #require(latest["observation"] as? [String: Any])
        let terminal = try #require(observation["terminal"] as? [String: Any])
        #expect((terminal["grid"] as? [String])?.contains("Also updated the docs.") == true)
        let changes = try #require(latest["changes"] as? [String: Any])
        #expect((changes["contentChanges"] as? Int ?? 0) >= 1)
    }

    @Test func heartbeatsOfAnUnchangedScreenBackOffToTheirMaximum() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let base = try await baseSample(["✻ Worked for 12s", "", "Done: the change is ready.", "", "❯ "])
        #expect(sampler.record(try variant(of: base, after: 0)))
        for step in 1...40 {
            #expect(!sampler.record(try variant(of: base, after: Double(step) * 30)))
        }

        let heartbeats = try records(in: directory, sampler: sampler).filter { $0["type"] as? String == "unchanged" }
        let offsets = heartbeats.compactMap { $0["recordedAt"] as? String }.map { offset(of: $0, from: base) }
        // Every check at first, then doubling gaps, then one every 5 min.
        #expect(offsets == [30, 60, 120, 240, 480, 780, 1_080])
        #expect(heartbeats.allSatisfy { $0["liveLines"] == nil })
    }

    @Test func aScreenThatOnlyAnimatesIsSkippedUntilItsSampleIsFiveMinutesOld() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let base = try await baseSample(["⏺ Reading 3 files", "", "✻ Worked for 12s", "", "❯ "])
        #expect(sampler.record(try variant(of: base, after: 0, liveLines: [])))
        // A blinking `⏺`, a spinner and a clock are animation.
        let animated = ["  Reading 3 files", "", "✶ Worked for 14s", "", "❯ "]
        #expect(!sampler.record(try variant(of: base, after: 30, grid: animated, liveLines: [])))
        #expect(!sampler.record(try variant(of: base, after: 270, grid: animated, liveLines: [])))
        #expect(sampler.record(try variant(of: base, after: 300, grid: animated, liveLines: [])))
        // New text is a new sample at once, and so is any state change.
        #expect(sampler.record(try variant(
            of: base, after: 330, grid: ["⏺ Reading 4 files", "⏺ Edited main.rs", "", "❯ "], liveLines: []
        )))
        #expect(sampler.record(try variant(of: base, after: 331, trigger: .stateChanged, liveLines: [], submittedTurns: 3)))

        #expect(TerminalAttentionSampler.animationFreeText(of: "  ⏺ Reading 12 files   ") == "Reading # files")
        #expect(TerminalAttentionSampler.animationFreeText(of: "✻ Frosting… (1m 12s · esc)") == "Frosting… (#m #s · esc)")
    }

    @Test func aWorkingTabIsSampledEveryTwoMinutesWithItsLiveLinesInBetween() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let live = "✻ Frosting… (3s · esc to interrupt)"
        let base = try await baseSample(["❯ fix it", "", "⏺ Reading files", "", live, "", "❯ "])
        #expect(sampler.record(try variant(of: base, after: 0, liveLines: [live])))

        // New output and advancing live lines: the same work, so heartbeats.
        let later = "✻ Frosting… (33s · esc to interrupt)"
        sampler.noteContentChange(tab: base.tab, run: base.run, selfDriven: true, at: date(of: base, after: 10))
        #expect(!sampler.record(try variant(
            of: base, after: 30, grid: ["❯ fix it", "", "⏺ Reading files", "⏺ Edited main.rs", "", later, "", "❯ "],
            liveLines: [later]
        )))
        #expect(!sampler.record(try variant(
            of: base, after: 60, grid: ["❯ fix it", "", "⏺ Edited main.rs", "⏺ Ran the tests", "", later, "", "❯ "],
            liveLines: [later]
        )))
        // Two minutes after the last sample, a sample again.
        let last = "✻ Frosting… (2m 3s · esc to interrupt)"
        #expect(sampler.record(try variant(
            of: base, after: 120, grid: ["❯ fix it", "", "⏺ Ran the tests", "⏺ All green", "", last, "", "❯ "],
            liveLines: [last]
        )))
        // Another turn is other work.
        #expect(sampler.record(try variant(of: base, after: 150, liveLines: [live], submittedTurns: 2)))

        let all = try records(in: directory, sampler: sampler)
        let heartbeats = all.filter { $0["type"] as? String == "unchanged" }
        #expect(heartbeats.count == 2)
        #expect(heartbeats.first?["liveLines"] as? [String] == [later])
        // The second shows the same live lines as the first: none.
        #expect(heartbeats.last?["liveLines"] == nil)
        // Changes count from the tab's previous record.
        let firstChanges = try #require(heartbeats.first?["changes"] as? [String: Any])
        #expect(firstChanges["selfDrivenChanges"] as? Int == 1)
        let samples = all.filter { $0["type"] as? String == "sample" }
        let refreshed = try #require(samples.dropFirst().first?["changes"] as? [String: Any])
        #expect(refreshed["selfDrivenChanges"] as? Int == 0)
        #expect(all.allSatisfy { $0["schemaVersion"] as? Int == TerminalAttentionSample.currentSchemaVersion })
    }

    @Test func theEventThatMadeTheLastObservationIsNotANewScreen() async throws {
        let base = try await baseSample(["✻ Worked for 12s", "", "Done.", "", "❯ "])
        var features = base.features
        for name in features.keys where name.hasPrefix("category.event=") {
            features.removeValue(forKey: name)
        }
        var other = features
        features["category.event=content_changed"] = 1
        other["category.event=activity_state_changed"] = 1
        let first = try variant(of: base, after: 0, features: features)
        let second = try variant(of: base, after: 30, features: other)
        #expect(TerminalAttentionSampler.dedupeKey(of: first) == TerminalAttentionSampler.dedupeKey(of: second))
        var focused = other
        focused["boolean.interaction.terminalFocused=true"] = 1
        #expect(TerminalAttentionSampler.dedupeKey(of: first) != TerminalAttentionSampler.dedupeKey(of: try variant(of: base, after: 60, features: focused)))
    }

    @Test func samplesHoldTheClassifiersExactInputsAndATail() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        // The tab's own state-change samples go to a sampler that is off,
        // so the periodic one is not skipped as their repeat.
        let idle = TerminalAttentionSampler(schedulesTimer: false, isEnabled: { false }, directoryURL: { directory })
        let session = makeAgentSession(sampler: idle, rows: 80)
        defer { session.stop() }
        let screen = (1...70).map { "transcript line \($0)" } + ["", "❯ "]
        await showScreen(session, screen)
        sampler.register(session)
        sampler.tick()
        sampler.flush()

        let samples = try decodedSamples(in: directory)
        let sample = try #require(samples.last { $0.trigger == .periodic })
        #expect(sample.observation.terminal.grid.count == TerminalAttentionSampling.screenTailLineLimit)
        #expect(sample.observation.terminal.grid.last?.trimmingCharacters(in: .whitespaces) == "❯")
        #expect(sample.agent == "claude")
        #expect(sample.backend == "native")
        #expect(sample.tab == TerminalAttentionSampling.stableID(session.id))
        #expect(sample.observation.session.id == sample.tab)
        #expect(!sample.observation.session.id.contains(session.id.uuidString))
        // What the model computes from the recorded observation is what
        // the sample says it saw.
        #expect(TerminalAttentionClassifier.features(for: sample.observation) == sample.features)
        let prediction = TerminalAttentionClassifier.shared.predict(sample.observation)
        #expect(abs(prediction.attentionProbability - sample.prediction.attentionProbability) < 1e-12)
        #expect(sample.lifecycle.turnState == .notStarted)
    }

    @Test func stateChangesAreSampledAtOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let session = makeAgentSession(sampler: sampler)
        defer { session.stop() }
        await showScreen(session, ["Claude Code", "", "❯ "])
        session.noteTestingInput(Data("fix it".utf8))
        session.noteTestingInput(Data("\r".utf8))
        await showScreen(session, ["❯ fix it", "", "✻ Frosting… (3s · esc to interrupt)", "", "❯ "])
        // The state was already working (from the submit): the new evidence
        // comes with the debounced observation.
        try await Task.sleep(for: .milliseconds(1_200))
        sampler.flush()

        let samples = try decodedSamples(in: directory).filter { $0.trigger == .stateChanged }
        #expect(samples.contains { $0.lifecycle.turnState == .active && $0.lifecycle.submittedTurns == 1 })
        let working = try #require(samples.last { $0.observation.activity.evidence == "working_marker" })
        #expect(working.screen.liveLines.contains { $0.contains("esc to interrupt") })
    }

    @Test func selfDrivenChangesRecordAtMostOneTimeASecond() throws {
        var changes = TerminalAttentionSample.Changes()
        let start = Date(timeIntervalSince1970: 1_791_200_000)
        for offset in [0.0, 0.3, 0.9, 1.0, 1.4, 2.5, 30.0] {
            changes.noteSelfDrivenChange(at: start.addingTimeInterval(offset))
        }
        #expect(changes.selfDrivenChanges == 7)
        #expect(changes.selfDrivenChangeTimes == [1_791_200_000, 1_791_200_001, 1_791_200_002.5, 1_791_200_030])

        var busy = TerminalAttentionSample.Changes()
        for second in 0..<(TerminalAttentionSample.Changes.maximumRecordedTimes + 50) {
            busy.noteSelfDrivenChange(at: start.addingTimeInterval(Double(second)))
        }
        #expect(busy.selfDrivenChangeTimes.count == TerminalAttentionSample.Changes.maximumRecordedTimes)
    }

    // MARK: Events

    @Test func eventsRecordKindsAndTimesNeverTypedContent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let session = makeAgentSession(sampler: sampler)
        defer { session.stop() }
        await showScreen(session, ["Claude Code", "", "❯ "])

        session.noteTestingInput(Data("hunter2-secret".utf8))
        session.noteTestingInput(Data("x".utf8))
        session.noteTestingInput(Data("\r".utf8))
        session.noteAttentionSampleEvent(.focused, detail: "selected")
        session.noteAttentionSampleEvent(.focused, detail: "viewed")
        session.noteAttentionSampleEvent(.bell)
        session.noteAttentionSampleClosed(intent: .userDetachedTab)
        sampler.flush()

        let text = try dayFiles(in: directory)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
        #expect(!text.contains("hunter2"))

        let events = try records(in: directory, sampler: sampler).filter { $0["type"] as? String == "event" }
        let kinds = events.compactMap { $0["kind"] as? String }
        // Typing is rate-limited to one event every 2 s, focus to one every 5 s.
        #expect(kinds.filter { $0 == "typed" }.count == 1)
        #expect(kinds.filter { $0 == "submitted" }.count == 1)
        #expect(kinds.filter { $0 == "focused" }.count == 1)
        #expect(kinds.contains("bell"))
        let closed = try #require(events.last { $0["kind"] as? String == "closed" })
        #expect(closed["detail"] as? String == "userDetachedTab")
        for event in events {
            #expect(Set(event.keys).isSubset(of: ["type", "schemaVersion", "recordedAt", "tab", "run", "kind", "detail"]))
        }
    }

    @Test func aMenuKeyIsRecordedAsSuch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let session = makeAgentSession(sampler: sampler)
        defer { session.stop() }
        await showScreen(session, ["Claude Code", "", "❯ "])
        session.noteTestingInput(Data("go\r".utf8))
        await showScreen(session, [
            "⏺ Bash(rm -rf build)",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. No, and tell Claude what to do differently (esc)",
        ])
        session.noteTestingInput(Data("1".utf8))
        sampler.flush()

        let events = try records(in: directory, sampler: sampler).filter { $0["type"] as? String == "event" }
        let menuKey = try #require(events.last { $0["kind"] as? String == "menu_key" })
        #expect(menuKey["detail"] as? String == "permission")
    }

    // MARK: Writer

    @Test func writerKeepsUnderItsCapDroppingTheOldestDaysFirst() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let utc = try #require(TimeZone(identifier: "UTC"))
        let writer = TerminalAttentionSampleWriter(
            directoryURL: directory,
            maximumBytes: 6_000,
            flushInterval: 3_600,
            timeZone: utc
        )
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        for day in 0..<4 {
            for index in 0..<10 {
                writer.append(.event(event(at: start.addingTimeInterval(Double(day) * 86_400 + Double(index)))))
            }
            writer.flush()
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(!names.contains("2026-10-01.jsonl"))
        #expect(names.contains("2026-10-04.jsonl"))
        let sizes = try names.map { name -> Int64 in
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        #expect(sizes.reduce(0, +) <= 6_000)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        // A day that alone outgrows the cap stops growing.
        let small = TerminalAttentionSampleWriter(directoryURL: directory, maximumBytes: 500, flushInterval: 3_600, timeZone: utc)
        for index in 0..<20 {
            small.append(.event(event(at: start.addingTimeInterval(10 * 86_400 + Double(index)))))
        }
        small.flush()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .map { try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path) }
            .compactMap { ($0[.size] as? NSNumber)?.int64Value }
        #expect(remaining.reduce(0, +) <= 500)
    }

    @Test func aDayStopsTakingSamplesAtItsDailyCapButKeepsEvents() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let utc = try #require(TimeZone(identifier: "UTC"))
        let writer = TerminalAttentionSampleWriter(
            directoryURL: directory,
            maximumBytes: 1_000_000,
            maximumDailyBytes: 2_000,
            flushInterval: 3_600,
            timeZone: utc
        )
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z"))
        for index in 0..<20 {
            writer.append(.unchanged(heartbeat(at: start.addingTimeInterval(Double(index)))))
        }
        writer.flush()
        for index in 0..<5 {
            writer.append(.event(event(at: start.addingTimeInterval(100 + Double(index)))))
            writer.append(.unchanged(heartbeat(at: start.addingTimeInterval(100 + Double(index)))))
        }
        // The next day starts afresh.
        writer.append(.unchanged(heartbeat(at: start.addingTimeInterval(86_400))))
        writer.flush()

        let today = try String(contentsOf: directory.appendingPathComponent("2026-10-05.jsonl"), encoding: .utf8)
        let lines = today.split(separator: "\n")
        let heartbeatLines = lines.filter { $0.contains("\"type\":\"unchanged\"") }
        #expect(heartbeatLines.count < 20)
        #expect(heartbeatLines.reduce(0) { $0 + $1.utf8.count + 1 } <= 2_000)
        #expect(lines.filter { $0.contains("\"type\":\"event\"") }.count == 5)
        let tomorrow = try String(contentsOf: directory.appendingPathComponent("2026-10-06.jsonl"), encoding: .utf8)
        #expect(tomorrow.split(separator: "\n").count == 1)

        // A writer that starts on a day already full reads its size first.
        let later = TerminalAttentionSampleWriter(
            directoryURL: directory,
            maximumBytes: 1_000_000,
            maximumDailyBytes: 2_000,
            flushInterval: 3_600,
            timeZone: utc
        )
        later.append(.unchanged(heartbeat(at: start.addingTimeInterval(200))))
        later.flush()
        let after = try String(contentsOf: directory.appendingPathComponent("2026-10-05.jsonl"), encoding: .utf8)
        #expect(after.split(separator: "\n").filter { $0.contains("\"type\":\"unchanged\"") }.count == heartbeatLines.count)
    }

    @Test func writerLeavesFilesItDoesNotManage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 4_000).write(to: notes)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let writer = TerminalAttentionSampleWriter(directoryURL: directory, maximumBytes: 1_000, flushInterval: 3_600, timeZone: utc)
        writer.append(.event(event(at: Date())))
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: notes.path))
    }

    // MARK: Helpers

    private func privateDefaults() throws -> (UserDefaults, String) {
        let name = "cherry-attention-sampling-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-samples-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeSampler(_ directory: URL) -> TerminalAttentionSampler {
        TerminalAttentionSampler(
            flushInterval: 3_600,
            schedulesTimer: false,
            isEnabled: { true },
            directoryURL: { directory }
        )
    }

    private func makeAgentSession(sampler: TerminalAttentionSampler, rows: Int = 12) -> TerminalSession {
        let session = TerminalSession(
            title: "Claude",
            subtitle: "claude",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Claude",
            attentionObservationDirectoryProvider: { nil },
            attentionNotificationHandler: { _, _ in },
            attentionSampler: sampler
        )
        session.resize(columns: 80, rows: rows)
        return session
    }

    /// Shows `lines` on the alternate screen, as agent CLIs draw, and waits
    /// for the session to read it.
    private func showScreen(_ session: TerminalSession, _ lines: [String]) async {
        session.ingestTestingData(Data(("\u{1B}[?1049h\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\r\n")).utf8))
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func dayFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { TerminalAttentionSampling.isDayFileName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func records(in directory: URL, sampler: TerminalAttentionSampler) throws -> [[String: Any]] {
        sampler.flush()
        return try dayFiles(in: directory).flatMap { url in
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .compactMap { line in
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                }
        }
    }

    private func decodedSamples(in directory: URL) throws -> [TerminalAttentionSample] {
        let decoder = JSONDecoder()
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try style.parse(value)
        }
        return try dayFiles(in: directory).flatMap { url in
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { $0.contains("\"type\":\"sample\"") }
                .map { try decoder.decode(TerminalAttentionSample.self, from: Data($0.utf8)) }
        }
    }

    /// A real periodic sample of a tab showing `lines`, from a tab whose
    /// own sampler is off, so only what a test records reaches its sampler.
    private func baseSample(_ lines: [String]) async throws -> TerminalAttentionSample {
        let idle = TerminalAttentionSampler(schedulesTimer: false, isEnabled: { false }, directoryURL: { self.temporaryDirectory() })
        let session = makeAgentSession(sampler: idle)
        defer { session.stop() }
        await showScreen(session, lines)
        return try #require(session.makePeriodicAttentionSample())
    }

    /// `sample` `seconds` later (a new id), with its screen, live lines,
    /// turn count or features replaced. The features stay as given: the
    /// sampler compares what samples say, it does not recompute them.
    private func variant(
        of sample: TerminalAttentionSample,
        after seconds: TimeInterval,
        trigger: TerminalAttentionSample.Trigger = .periodic,
        grid: [String]? = nil,
        liveLines: [String]? = nil,
        submittedTurns: Int? = nil,
        features: [String: Double]? = nil
    ) throws -> TerminalAttentionSample {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        object["id"] = UUID().uuidString
        object["recordedAt"] = date(of: sample, after: seconds).timeIntervalSinceReferenceDate
        object["trigger"] = trigger.rawValue
        if let grid {
            var observation = try #require(object["observation"] as? [String: Any])
            var terminal = try #require(observation["terminal"] as? [String: Any])
            terminal["grid"] = grid
            observation["terminal"] = terminal
            object["observation"] = observation
        }
        if let liveLines {
            var screen = try #require(object["screen"] as? [String: Any])
            screen["liveLines"] = liveLines
            object["screen"] = screen
        }
        if let submittedTurns {
            var lifecycle = try #require(object["lifecycle"] as? [String: Any])
            lifecycle["submittedTurns"] = submittedTurns
            object["lifecycle"] = lifecycle
        }
        if let features {
            object["features"] = features
        }
        return try JSONDecoder().decode(
            TerminalAttentionSample.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func date(of sample: TerminalAttentionSample, after seconds: TimeInterval) -> Date {
        sample.recordedAt.addingTimeInterval(seconds)
    }

    /// Seconds from `sample` to a record's `recordedAt`, rounded.
    private func offset(of recordedAt: String, from sample: TerminalAttentionSample) -> Int {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = try? style.parse(recordedAt) else { return -1 }
        return Int(date.timeIntervalSince(sample.recordedAt).rounded())
    }

    private func heartbeat(at date: Date) -> TerminalAttentionSampleHeartbeat {
        TerminalAttentionSampleHeartbeat(
            type: TerminalAttentionSampleHeartbeat.recordType,
            schemaVersion: TerminalAttentionSample.currentSchemaVersion,
            recordedAt: date,
            tab: "0123456789abcdef",
            run: "fedcba9876543210",
            sample: UUID(),
            changes: .init()
        )
    }

    private func event(at date: Date) -> TerminalAttentionSampleEvent {
        TerminalAttentionSampleEvent(
            type: TerminalAttentionSampleEvent.recordType,
            schemaVersion: TerminalAttentionSample.currentSchemaVersion,
            recordedAt: date,
            tab: "0123456789abcdef",
            run: "fedcba9876543210",
            kind: .bell,
            detail: String(repeating: "x", count: 120)
        )
    }
}
