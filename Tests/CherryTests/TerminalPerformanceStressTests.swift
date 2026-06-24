import AppKit
import Darwin
import Foundation
import Testing
@testable import Cherry

@Suite struct TerminalPerformanceStressTests {
    private static let viewport = TerminalViewportSize(columns: 120, rows: 40)

    @Test func liveBufferReplaysLongScrollbackWorkload() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let workload = TerminalPerfHarness.makeScrollbackWorkload(
            lineCount: scale.scrollbackLines,
            columns: Self.viewport.columns
        )
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 50_000)

        let result = TerminalPerfHarness.measure(
            name: "live-buffer-scrollback",
            bytes: workload.count,
            metadata: scale.description
        ) {
            TerminalPerfHarness.ingest(workload, chunkSize: scale.chunkSize) { chunk in
                _ = buffer.ingest(chunk, viewportSize: Self.viewport)
            }
        }

        let tail = buffer.snapshot(range: max(0, buffer.lineCount - 8)..<buffer.lineCount)
        #expect(tail.contains { $0.contains("scrollback-\(scale.scrollbackLines - 1)") })
        #expect(buffer.lineCount <= TerminalPerfHarness.retainedLineUpperBound(maxScrollback: 50_000))
        TerminalPerfHarness.printResult(result, extra: "lines=\(buffer.lineCount)")
    }

    @Test func liveBufferReplaysTUIRedrawWorkload() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let workload = TerminalPerfHarness.makeTUIRedrawWorkload(
            frames: scale.tuiFrames,
            rows: Self.viewport.rows,
            columns: Self.viewport.columns
        )
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 10_000)

        let result = TerminalPerfHarness.measure(
            name: "live-buffer-tui-redraw",
            bytes: workload.count,
            metadata: scale.description
        ) {
            TerminalPerfHarness.ingest(workload, chunkSize: scale.chunkSize) { chunk in
                _ = buffer.ingest(chunk, viewportSize: Self.viewport)
            }
        }

        let visible = buffer.snapshot(range: 0..<buffer.lineCount)
        #expect(buffer.usesAlternateScreen)
        #expect(visible.contains { $0.contains("frame=\(scale.tuiFrames - 1)") })
        TerminalPerfHarness.printResult(result, extra: "visibleLines=\(buffer.lineCount)")
    }

    @MainActor
    @Test func terminalSessionRetainsBoundedRawOutputDuringLongRun() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let workload = TerminalPerfHarness.makeScrollbackWorkload(
            lineCount: scale.sessionLines,
            columns: Self.viewport.columns
        )
        let session = TerminalSession(
            title: "Perf Raw Output",
            subtitle: "No shell",
            tint: .systemGreen,
            buffer: LiveTerminalOutputBuffer(maxScrollback: 50_000),
            launchShell: false
        )
        defer {
            session.releaseGhosttyBridge()
            session.stop()
        }
        session.resize(columns: Self.viewport.columns, rows: Self.viewport.rows)

        let result = TerminalPerfHarness.measure(
            name: "terminal-session-raw-retention",
            bytes: workload.count,
            metadata: scale.description
        ) {
            TerminalPerfHarness.ingest(workload, chunkSize: scale.chunkSize) { chunk in
                session.ingestTestingData(chunk)
            }
        }

        let rawOutput = session.rawOutput(maxBytes: 1_048_576)
        #expect(rawOutput.data.count <= 1_048_576)
        #expect(rawOutput.truncated == (workload.count > 1_048_576))
        TerminalPerfHarness.printResult(
            result,
            extra: "lines=\(session.lineCount) rawBytes=\(rawOutput.data.count) truncated=\(rawOutput.truncated)"
        )
    }

    @MainActor
    @Test func ghosttyRenderedReplayRestoresStyledLiveBufferSnapshotEfficiently() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let workload = TerminalPerfHarness.makeStyledScrollbackWorkload(
            lineCount: scale.sessionLines,
            columns: Self.viewport.columns
        )
        let session = TerminalSession(
            title: "Perf Styled Replay",
            subtitle: "No shell",
            tint: .systemGreen,
            buffer: LiveTerminalOutputBuffer(maxScrollback: 50_000),
            launchShell: false
        )
        defer {
            session.releaseGhosttyBridge()
            session.stop()
        }
        session.resize(columns: Self.viewport.columns, rows: Self.viewport.rows)
        TerminalPerfHarness.ingest(workload, chunkSize: scale.chunkSize) { chunk in
            session.ingestTestingData(chunk)
        }

        let rawBytes = session.rawOutput(maxBytes: 1_048_576).data.count
        let iterations = max(3, scale.churnRounds)
        var replayOutput = Data()

        let result = TerminalPerfHarness.measure(
            name: "ghostty-rendered-styled-live-buffer-replay",
            bytes: rawBytes * iterations,
            metadata: scale.description
        ) {
            for _ in 0..<iterations {
                replayOutput = GhosttySessionBridge.renderedReplayOutput(for: session)
            }
        }

        let finalLineIndex = scale.sessionLines - 1
        let finalColor = TerminalANSIColor.palette256(16 + (finalLineIndex % 216))
        var replayedBuffer = PrototypeTerminalBuffer(maxScrollback: nil)
        replayedBuffer.ingest(replayOutput)
        let replayedLines = replayedBuffer.styledSnapshot(range: 0..<replayedBuffer.lineCount)
        let finalLine = try #require(replayedLines.first { line in
            line.runs.contains { $0.text.contains("styled-\(finalLineIndex)") }
        })
        let finalRun = try #require(finalLine.runs.first { $0.text.contains("styled-\(finalLineIndex)") })

        #expect(finalRun.style.foreground == finalColor)
        TerminalPerfHarness.printResult(
            result,
            extra: "iterations=\(iterations) rawBytes=\(rawBytes) replayBytes=\(replayOutput.count)"
        )
    }

    @MainActor
    @Test func ghosttyBridgeChurnsAcrossManySessions() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let startingBridgeCount = GhosttySessionBridge.liveBridgeCount
        let startingObserverCount = GhosttySessionBridge.installedOutputObserverCount
        let previousDelay = GhosttySessionBridge.detachedSurfaceReleaseDelay
        GhosttySessionBridge.detachedSurfaceReleaseDelay = .milliseconds(1)

        let container = GhosttyTerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640)
        )
        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(scale.sessionCount)

        let result = TerminalPerfHarness.measure(
            name: "ghostty-bridge-session-churn",
            bytes: 0,
            metadata: scale.description
        ) {
            for index in 0..<scale.sessionCount {
                let session = TerminalSession(
                    title: "Perf \(index)",
                    subtitle: "No shell",
                    tint: .systemBlue,
                    launchShell: false
                )
                session.ingestTestingData(Data("session-\(index)\r\n".utf8))
                sessions.append(session)
                container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
            }

            for _ in 0..<scale.churnRounds {
                for session in sessions {
                    container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
                }
            }

            container.detachActiveSession()
            for session in sessions {
                session.releaseGhosttyBridge()
                session.stop()
            }
            sessions.removeAll(keepingCapacity: false)
        }

        GhosttySessionBridge.detachedSurfaceReleaseDelay = previousDelay
        #expect(GhosttySessionBridge.liveBridgeCount == startingBridgeCount)
        #expect(GhosttySessionBridge.installedOutputObserverCount == startingObserverCount)
        TerminalPerfHarness.printResult(
            result,
            extra: "sessions=\(scale.sessionCount) rounds=\(scale.churnRounds)"
        )
    }

    @MainActor
    @Test func detachedGhosttySurfacesReleaseAfterManySessionSwitches() async throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        let startingObserverCount = GhosttySessionBridge.installedOutputObserverCount
        let previousDelay = GhosttySessionBridge.detachedSurfaceReleaseDelay
        GhosttySessionBridge.detachedSurfaceReleaseDelay = .milliseconds(1)

        let container = GhosttyTerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640)
        )
        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(scale.sessionCount)
        defer {
            container.detachActiveSession()
            for session in sessions {
                session.releaseGhosttyBridge()
                session.stop()
            }
            GhosttySessionBridge.detachedSurfaceReleaseDelay = previousDelay
        }

        let result = TerminalPerfHarness.measure(
            name: "ghostty-detached-surface-release",
            bytes: 0,
            metadata: scale.description
        ) {
            for index in 0..<scale.sessionCount {
                let session = TerminalSession(
                    title: "Detach Perf \(index)",
                    subtitle: "No shell",
                    tint: .systemBlue,
                    launchShell: false
                )
                session.ingestTestingData(Data("session-\(index)\r\n".utf8))
                sessions.append(session)
                container.configure(with: session, colorScheme: .dark, allowsAutoFocus: false)
                session.ghosttyBridge.installOutputObserverForTesting()
            }
        }

        try await Task.sleep(for: .milliseconds(20))

        let observerCountAfterRelease = GhosttySessionBridge.installedOutputObserverCount
        let retainedDetachedObservers = sessions.dropLast().reduce(0) { $0 + $1.rawOutputObserverCount }
        let activeObserverCount = sessions.last?.rawOutputObserverCount ?? 0

        #expect(retainedDetachedObservers == 0)
        #expect(activeObserverCount == 1)
        TerminalPerfHarness.printResult(
            result,
            extra: "sessions=\(scale.sessionCount) observersAfterRelease=\(observerCountAfterRelease - startingObserverCount) retainedDetachedObservers=\(retainedDetachedObservers)"
        )
    }

    @MainActor
    @Test func manySessionsRetainSmallOutputBurstsEfficiently() throws {
        guard TerminalPerfHarness.isEnabled else { return }
        let scale = TerminalPerfHarness.scale
        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(scale.smallOutputSessionCount)
        let chunks = TerminalPerfHarness.makeSmallOutputChunks(count: scale.smallOutputChunksPerSession)
        let bytesPerSession = chunks.reduce(0) { $0 + $1.count }
        let totalBytes = bytesPerSession * scale.smallOutputSessionCount

        let result = TerminalPerfHarness.measure(
            name: "many-session-small-output-retention",
            bytes: totalBytes,
            metadata: scale.description
        ) {
            for sessionIndex in 0..<scale.smallOutputSessionCount {
                let session = TerminalSession(
                    title: "Small Output \(sessionIndex)",
                    subtitle: "No shell",
                    tint: .systemPurple,
                    buffer: LiveTerminalOutputBuffer(maxScrollback: 1_000),
                    launchShell: false
                )
                session.resize(columns: Self.viewport.columns, rows: Self.viewport.rows)
                for chunk in chunks {
                    session.ingestTestingData(chunk)
                }
                sessions.append(session)
            }
        }

        let retainedChunks = sessions.reduce(0) { $0 + $1.rawOutputRetainedChunkCount }
        let retainedRawBytes = sessions.reduce(0) { $0 + $1.rawOutput(maxBytes: 1_048_576).data.count }
        let truncatedCount = sessions.filter { $0.rawOutput(maxBytes: 1_048_576).truncated }.count
        for session in sessions {
            session.releaseGhosttyBridge()
            session.stop()
        }
        sessions.removeAll(keepingCapacity: false)

        TerminalPerfHarness.printResult(
            result,
            extra: "sessions=\(scale.smallOutputSessionCount) chunksPerSession=\(scale.smallOutputChunksPerSession) rawChunks=\(retainedChunks) rawBytes=\(retainedRawBytes) truncatedSessions=\(truncatedCount)"
        )
    }
}

private enum TerminalPerfHarness {
    struct Scale {
        let name: String
        let scrollbackLines: Int
        let sessionLines: Int
        let tuiFrames: Int
        let sessionCount: Int
        let churnRounds: Int
        let smallOutputSessionCount: Int
        let smallOutputChunksPerSession: Int
        let chunkSize: Int

        var description: String {
            "scale=\(name) chunkSize=\(chunkSize)"
        }
    }

    struct Measurement {
        let name: String
        let seconds: Double
        let bytes: Int
        let metadata: String
        let maxRSSBytes: Int64

        var megabytesPerSecond: Double {
            guard seconds > 0 else { return 0 }
            return (Double(bytes) / 1_048_576.0) / seconds
        }
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CHERRY_PERF_STRESS"] == "1"
    }

    static var scale: Scale {
        switch ProcessInfo.processInfo.environment["CHERRY_PERF_SCALE"]?.lowercased() {
        case "smoke":
            Scale(
                name: "smoke",
                scrollbackLines: 10_000,
                sessionLines: 8_000,
                tuiFrames: 120,
                sessionCount: 8,
                churnRounds: 3,
                smallOutputSessionCount: 8,
                smallOutputChunksPerSession: 2_000,
                chunkSize: 16 * 1024
            )
        case "soak":
            Scale(
                name: "soak",
                scrollbackLines: 1_000_000,
                sessionLines: 250_000,
                tuiFrames: 10_000,
                sessionCount: 80,
                churnRounds: 20,
                smallOutputSessionCount: 80,
                smallOutputChunksPerSession: 25_000,
                chunkSize: 64 * 1024
            )
        default:
            Scale(
                name: "standard",
                scrollbackLines: 200_000,
                sessionLines: 80_000,
                tuiFrames: 2_000,
                sessionCount: 32,
                churnRounds: 8,
                smallOutputSessionCount: 32,
                smallOutputChunksPerSession: 8_000,
                chunkSize: 32 * 1024
            )
        }
    }

    static func measure(
        name: String,
        bytes: Int,
        metadata: String,
        _ body: () throws -> Void
    ) rethrows -> Measurement {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let seconds = Double(elapsedNanoseconds) / 1_000_000_000
        return Measurement(
            name: name,
            seconds: seconds,
            bytes: bytes,
            metadata: metadata,
            maxRSSBytes: maxRSSBytes()
        )
    }

    static func printResult(_ measurement: Measurement, extra: String = "") {
        let seconds = String(format: "%.3f", measurement.seconds)
        let mib = String(format: "%.1f", Double(measurement.bytes) / 1_048_576.0)
        let mibPerSecond = String(format: "%.1f", measurement.megabytesPerSecond)
        let rss = String(format: "%.1f", Double(measurement.maxRSSBytes) / 1_048_576.0)
        let suffix = extra.isEmpty ? "" : " \(extra)"
        print(
            "[perf] \(measurement.name) \(measurement.metadata) " +
            "elapsed=\(seconds)s bytes=\(mib)MiB throughput=\(mibPerSecond)MiB/s maxRSS=\(rss)MiB\(suffix)"
        )
    }

    static func ingest(_ data: Data, chunkSize: Int, _ receive: (Data) -> Void) {
        var offset = 0
        while offset < data.count {
            let nextOffset = min(offset + chunkSize, data.count)
            receive(data.subdata(in: offset..<nextOffset))
            offset = nextOffset
        }
    }

    static func makeScrollbackWorkload(lineCount: Int, columns: Int) -> Data {
        var data = Data()
        data.reserveCapacity(lineCount * min(columns, 96))
        let fillWidth = max(16, columns - 32)
        let fill = String(repeating: "x", count: fillWidth)
        for index in 0..<lineCount {
            data.append(Data("scrollback-\(index) \(fill)\r\n".utf8))
        }
        return data
    }

    static func makeTUIRedrawWorkload(frames: Int, rows: Int, columns: Int) -> Data {
        var data = Data()
        data.reserveCapacity(frames * rows * min(columns, 96))
        data.append(Data("\u{1B}[?1049h\u{1B}[?25l".utf8))
        let fillWidth = max(12, columns - 32)
        for frame in 0..<frames {
            data.append(Data("\u{1B}[H".utf8))
            for row in 0..<rows {
                let fillCharacter = UnicodeScalar(UInt8(ascii: "a") + UInt8((frame + row) % 26))
                let fill = String(repeating: Character(fillCharacter), count: fillWidth)
                data.append(Data("\u{1B}[2Kframe=\(frame) row=\(row) \(fill)".utf8))
                if row + 1 < rows {
                    data.append(Data("\r\n".utf8))
                }
            }
        }
        data.append(Data("\u{1B}[?25h".utf8))
        return data
    }

    static func makeStyledScrollbackWorkload(lineCount: Int, columns: Int) -> Data {
        var data = Data()
        data.reserveCapacity(lineCount * min(columns, 96))
        let fillWidth = max(16, columns - 44)
        let fill = String(repeating: "s", count: fillWidth)
        for index in 0..<lineCount {
            let color = 16 + (index % 216)
            data.append(Data("\u{1B}[38;5;\(color)mstyled-\(index) \(fill)\u{1B}[0m\r\n".utf8))
        }
        return data
    }

    static func makeSmallOutputChunks(count: Int) -> [Data] {
        var chunks: [Data] = []
        chunks.reserveCapacity(count)
        for index in 0..<count {
            chunks.append(Data("tick-\(index) status=ok value=\(index % 97)\r\n".utf8))
        }
        return chunks
    }

    static func retainedLineUpperBound(maxScrollback: Int) -> Int {
        maxScrollback + max(512, maxScrollback / 10) + 1
    }

    private static func maxRSSBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }
}
