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
        let first = try Array(records(in: directory, sampler: sampler).dropFirst(before))
        #expect(first.count == 1)

        sampler.tick()
        let afterSecond = try records(in: directory, sampler: sampler)
        let second = Array(afterSecond.dropFirst(before + first.count))
        #expect(second.count == 1)
        #expect(second.first?["type"] as? String == "unchanged")
        let lastSample = try #require(afterSecond.last { $0["type"] as? String == "sample" })
        #expect(second.first?["sample"] as? String == lastSample["id"] as? String)

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

    @Test func samplesHoldTheClassifiersExactInputsAndATail() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = makeSampler(directory)
        let session = makeAgentSession(sampler: sampler, rows: 80)
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
