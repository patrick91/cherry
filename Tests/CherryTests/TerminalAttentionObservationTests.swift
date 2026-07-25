import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

@MainActor
@Suite(.serialized)
struct TerminalAttentionObservationTests {
    @Test func labeledCheckpointWritesVersionedPrivateJSONL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let session = TerminalSession(
            title: "Classifier fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "FutureHarness",
            attentionObservationDirectoryProvider: { directory }
        )
        defer {
            session.stop()
        }

        session.resize(columns: 24, rows: 3)
        session.ingestTestingData(Data(
            "old scrollback\nworking\n\u{1B}[38;5;82mapproval required\u{1B}[0m\n❯ \n".utf8
        ))
        try await Task.sleep(for: .milliseconds(150))

        let capture = try session.captureAttentionObservation(
            label: .approvalRequired,
            scenarioID: "approval-required",
            checkpoint: "human_verified",
            harnessVersion: "future-agent 1.2.3",
            runID: "run-123"
        )

        let data = try Data(contentsOf: capture.outputURL)
        let observations = try decodeObservations(data)
        let observation = try #require(observations.first { $0.id == capture.id })

        #expect(observation.schemaVersion == TerminalAttentionObservation.currentSchemaVersion)
        #expect(observation.event == .labeledCheckpoint)
        #expect(observation.label == .approvalRequired)
        #expect(observation.scenarioID == "approval-required")
        #expect(observation.checkpoint == "human_verified")
        #expect(observation.session.harness == "FutureHarness")
        #expect(observation.session.harnessVersion == "future-agent 1.2.3")
        #expect(observation.session.runID == "run-123")
        #expect(observation.terminal.columns == 24)
        #expect(observation.terminal.rows == 3)
        #expect(observation.terminal.grid.count <= 3)
        #expect(observation.terminal.grid.joined(separator: "\n").contains("approval required"))
        let styledGrid = try #require(observation.terminal.styledGrid)
        let approvalRun = try #require(styledGrid.flatMap { $0 }.first {
            $0.text.contains("approval required")
        })
        #expect(approvalRun.foreground == .init(space: .palette256, components: [82]))
        #expect(observation.terminal.scrollbackLinesOmitted > 0)

        let attributes = try FileManager.default.attributesOfItem(atPath: capture.outputURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
    }

    @Test func automaticObservationsRemainUnlabeled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let session = TerminalSession(
            title: "Automatic fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { directory }
        )
        defer {
            session.stop()
        }

        session.ingestTestingData(Data("actively working\n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))
        let capture = try session.captureAttentionObservation(
            label: .noAttentionNeeded,
            scenarioID: "working",
            checkpoint: "human_verified",
            harnessVersion: nil,
            runID: nil
        )

        let observations = try decodeObservations(Data(contentsOf: capture.outputURL))
        #expect(observations.contains { $0.event == .contentChanged && $0.label == nil })
        #expect(observations.contains { $0.event == .labeledCheckpoint && $0.label == .noAttentionNeeded })
    }

    @Test func schemaOneObservationWithoutStyledGridStillDecodes() throws {
        let json = """
        {
          "activity": {
            "evidence": "none",
            "hasUnreadNotification": false,
            "processState": "Running",
            "state": "unknown"
          },
          "contentVersion": 1,
          "event": "content_changed",
          "id": "6594bade-c891-42cb-8cb1-e51c16f1ab95",
          "outputVersion": 1,
          "recordedAt": "2026-07-22T12:00:01Z",
          "schemaVersion": 1,
          "session": {
            "id": "4c5d7267-f12c-4e8d-a821-65b9f8bf848c",
            "kind": "agent"
          },
          "terminal": {
            "columns": 80,
            "cursor": {"column": 0, "isVisible": true, "row": 0, "shape": "block"},
            "grid": ["plain text"],
            "rows": 24,
            "scrollbackLinesOmitted": 0,
            "usesAlternateScreen": false
          },
          "timing": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(
            TerminalAttentionObservation.self,
            from: Data(json.utf8)
        )

        #expect(observation.terminal.grid == ["plain text"])
        #expect(observation.terminal.styledGrid == nil)
        #expect(observation.interaction == nil)
    }

    @Test func nativeHostSubmissionRecordsInputSubmittedEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-native-input-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let session = TerminalSession(
            title: "Native input fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { directory }
        )
        defer {
            session.stop()
        }

        let letterKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        session.noteNativeHostInput(event: letterKey)
        let draftCapture = try session.captureAttentionObservation(
            label: .noAttentionNeeded,
            scenarioID: "native-draft-regression",
            checkpoint: "draft_visible",
            harnessVersion: nil,
            runID: nil
        )
        let draftObservations = try decodeObservations(Data(contentsOf: draftCapture.outputURL))
        let draft = try #require(draftObservations.first { $0.id == draftCapture.id })
        #expect(draft.interaction?.hasUnsubmittedInput == true)
        #expect(draft.interaction?.millisecondsSinceLastKeystroke != nil)

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        session.noteNativeHostInput(event: returnKey)
        let capture = try session.captureAttentionObservation(
            label: .unknown,
            scenarioID: "native-input-regression",
            checkpoint: "test_flush",
            harnessVersion: nil,
            runID: nil
        )

        let observations = try decodeObservations(Data(contentsOf: capture.outputURL))
        let submitted = try #require(observations.first { $0.event == .inputSubmitted })
        #expect(submitted.label == nil)
        #expect(submitted.activity.evidence == "input_submit")
        #expect(submitted.timing.millisecondsSinceLastHumanInput != nil)
        #expect(submitted.interaction?.hasUnsubmittedInput == false)
    }

    @Test func draftInputPersistsUntilSubmissionWithoutRecordingItsTextSeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-draft-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let session = TerminalSession(
            title: "Draft input fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { directory }
        )
        defer {
            session.stop()
        }

        session.noteTestingInput(Data("still typing this prompt".utf8))
        let draftCapture = try session.captureAttentionObservation(
            label: .noAttentionNeeded,
            scenarioID: "draft-input",
            checkpoint: "before_submit",
            harnessVersion: nil,
            runID: nil
        )
        let draftObservations = try decodeObservations(Data(contentsOf: draftCapture.outputURL))
        let draft = try #require(draftObservations.first { $0.id == draftCapture.id })
        let interaction = try #require(draft.interaction)
        #expect(interaction.hasUnsubmittedInput)
        #expect(interaction.millisecondsSinceLastKeystroke != nil)
        #expect(interaction.terminalFocused == false)

        session.noteTestingInput(Data("\r".utf8))
        let submittedCapture = try session.captureAttentionObservation(
            label: .unknown,
            scenarioID: "draft-input",
            checkpoint: "after_submit",
            harnessVersion: nil,
            runID: nil
        )
        let submittedObservations = try decodeObservations(Data(contentsOf: submittedCapture.outputURL))
        let submitted = try #require(submittedObservations.first { $0.id == submittedCapture.id })
        #expect(submitted.interaction?.hasUnsubmittedInput == false)
        #expect(submitted.timing.millisecondsSinceLastHumanInput != nil)
    }

    @Test func captureRequestRoundTripsAllDatasetMetadata() throws {
        let request = CherryControlRequest.captureAttentionObservation(.init(
            processID: UUID().uuidString,
            label: "waiting_for_input",
            scenarioID: "waiting-for-input",
            checkpoint: "human_verified",
            harnessVersion: "example 2.0",
            runID: "run-456"
        ))

        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(CherryControlRequest.self, from: encoded) == request)
    }

    @Test func studyModePreferencePersistsAndEnvironmentOverrideWins() throws {
        let defaultsName = "CherryTests.AttentionStudy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        #expect(TerminalAttentionStudy.configuredDirectoryURL(environment: [:], defaults: defaults) == nil)
        let settings = TerminalSettings(defaults: defaults)
        settings.attentionStudyEnabled = true
        #expect(TerminalSettings(defaults: defaults).attentionStudyEnabled)
        #expect(
            TerminalAttentionStudy.configuredDirectoryURL(environment: [:], defaults: defaults)
                == TerminalAttentionStudy.recordingsDirectoryURL()
        )

        let override = "/tmp/cherry-attention-study-override"
        #expect(
            TerminalAttentionStudy.configuredDirectoryURL(
                environment: [TerminalAttentionObservationRecorder.environmentKey: override],
                defaults: defaults
            )?.path == override
        )
    }

    @Test func studyModeDefaultsToStyledTerminalPathUnlessExplicitlyOverridden() {
        #expect(
            GhosttySessionBridge.resolveNativePTYEnabled(
                environment: [:],
                attentionRecordingEnabled: true
            ) == false
        )
        #expect(
            GhosttySessionBridge.resolveNativePTYEnabled(
                environment: ["CHERRY_NATIVE_PTY": "1"],
                attentionRecordingEnabled: true
            )
        )
        #expect(
            GhosttySessionBridge.resolveNativePTYEnabled(
                environment: ["CHERRY_NATIVE_PTY": "off"],
                attentionRecordingEnabled: false
            ) == false
        )
    }

    @Test func studyDirectoryPrunesOldestJSONLFilesToLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let oldest = directory.appendingPathComponent("oldest.jsonl")
        let middle = directory.appendingPathComponent("middle.jsonl")
        let newest = directory.appendingPathComponent("newest.jsonl")
        try Data(repeating: 0x41, count: 4).write(to: oldest)
        try Data(repeating: 0x42, count: 4).write(to: middle)
        try Data(repeating: 0x43, count: 4).write(to: newest)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldest.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newest.path)

        let removed = try TerminalAttentionStudy.pruneRecordings(in: directory, maximumBytes: 8)

        #expect(removed.map(\.lastPathComponent) == [oldest.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test func recordingProviderCanEnableAnExistingSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-dynamic-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        var configuredDirectory: URL? = nil
        let session = TerminalSession(
            title: "Dynamic fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { configuredDirectory }
        )
        defer {
            session.stop()
        }

        session.ingestTestingData(Data("recording disabled\n".utf8))
        try await Task.sleep(for: .milliseconds(350))
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        configuredDirectory = directory
        session.ingestTestingData(Data("recording enabled\n".utf8))
        try await Task.sleep(for: .milliseconds(1_250))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.pathExtension == "jsonl" })
    }

    @Test func studyBundleExportAndImportDeduplicateObservationIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-attention-transfer-\(UUID().uuidString)", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let session = TerminalSession(
            title: "Transfer fixture",
            subtitle: "fixture-agent",
            tint: .systemBlue,
            launchShell: false,
            kind: .agent,
            agentName: "Fixture",
            attentionObservationDirectoryProvider: { recordings }
        )
        defer {
            session.stop()
        }
        session.ingestTestingData(Data("Choose alpha or beta\n".utf8))
        _ = try session.captureAttentionObservation(
            label: .waitingForInput,
            scenarioID: "waiting-for-input",
            checkpoint: "test",
            harnessVersion: "fixture 1.0",
            runID: "transfer-test"
        )

        let export = try runStudyDataCommand(["export", "--source", recordings.path, "--output", bundle.path])
        #expect(export.status == 0)
        let firstImport = try runStudyDataCommand(["import", "--bundle", bundle.path, "--destination", dataset.path])
        #expect(firstImport.status == 0)
        #expect(firstImport.output.contains("Imported 1 observations"))
        let secondImport = try runStudyDataCommand(["import", "--bundle", bundle.path, "--destination", dataset.path])
        #expect(secondImport.status == 0)
        #expect(secondImport.output.contains("Imported 0 observations"))
        #expect(secondImport.output.contains("Skipped 1 observations already present"))

        let importedFiles = try FileManager.default.contentsOfDirectory(
            at: dataset.appendingPathComponent("observations", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(importedFiles.filter { $0.pathExtension == "jsonl" }.count == 1)

        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: bundle.appendingPathComponent("observations", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let bundledFile = try #require(bundledFiles.first { $0.pathExtension == "jsonl" })
        let handle = try FileHandle(forWritingTo: bundledFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered\n".utf8))
        try handle.close()

        let tamperedDataset = root.appendingPathComponent("tampered-dataset", isDirectory: true)
        let tamperedImport = try runStudyDataCommand([
            "import", "--bundle", bundle.path, "--destination", tamperedDataset.path,
        ])
        #expect(tamperedImport.status == 2)
        #expect(tamperedImport.output.contains("checksum mismatch"))
    }

    private func decodeObservations(_ data: Data) throws -> [TerminalAttentionObservation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data
            .split(separator: 0x0A)
            .map { try decoder.decode(TerminalAttentionObservation.self, from: Data($0)) }
    }

    private func runStudyDataCommand(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("Scripts/attention-study-data")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
