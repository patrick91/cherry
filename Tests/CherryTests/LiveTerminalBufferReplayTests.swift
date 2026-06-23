import Foundation
import Testing
@testable import Cherry

@Suite struct LiveTerminalBufferReplayTests {
    private static let fixtureViewport = TerminalViewportSize(columns: 120, rows: 32)
    private static let claudeCorruptionSignatures = ["completedewith", "Workingsin8", "9smessages", "exitrcodet"]

    private func fixtureData(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "raw",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private func replay(_ data: Data, chunkSize: Int?) -> LiveTerminalOutputBuffer {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 10_000)
        guard let chunkSize else {
            buffer.ingest(data, viewportSize: Self.fixtureViewport)
            return buffer
        }

        var offset = 0
        while offset < data.count {
            let upperBound = min(offset + chunkSize, data.count)
            buffer.ingest(data.subdata(in: offset..<upperBound), viewportSize: Self.fixtureViewport)
            offset = upperBound
        }
        return buffer
    }

    private func assertClaudeFinalFrame(_ buffer: LiveTerminalOutputBuffer) {
        #expect(buffer.usesAlternateScreen)

        let lines = buffer.snapshot(range: 0..<buffer.lineCount)
        #expect(lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })
        #expect(lines.contains { $0.contains("bypass permissions on") })
        #expect(lines.contains { $0.contains("PROBE_SLEEP_DONE") })

        for signature in Self.claudeCorruptionSignatures {
            #expect(!lines.contains { $0.contains(signature) }, "found corruption signature \(signature)")
        }

        #expect(lines.contains("⏺ The command completed with exit code 0 and its output was:"))
        #expect(lines.contains("✻ Worked for 9s"))
        #expect(lines.contains("  PROBE_SLEEP_DONE"))
        #expect(lines.contains("❯\u{00A0}what's the output?"))
    }

    @Test func claudeFixtureChunkedReplayRendersCleanFinalFrame() throws {
        let data = try fixtureData(named: "claude-code-2.1.170-session")
        assertClaudeFinalFrame(replay(data, chunkSize: 1024))
    }

    @Test func claudeFixtureByteByByteReplayRendersCleanFinalFrame() throws {
        let data = try fixtureData(named: "claude-code-2.1.170-session")
        assertClaudeFinalFrame(replay(data, chunkSize: 1))
    }

    @Test func claudeFixtureSingleIngestMatchesChunkedReplay() throws {
        let data = try fixtureData(named: "claude-code-2.1.170-session")
        let wholeBuffer = replay(data, chunkSize: nil)
        let chunkedBuffer = replay(data, chunkSize: 1024)

        assertClaudeFinalFrame(wholeBuffer)
        let wholeLines = wholeBuffer.snapshot(range: 0..<wholeBuffer.lineCount)
        let chunkedLines = chunkedBuffer.snapshot(range: 0..<chunkedBuffer.lineCount)
        #expect(wholeLines == chunkedLines)
    }

    @Test func codexFixtureReplayRendersStableWorkingRow() throws {
        let data = try fixtureData(named: "codex-0.138.0-session")
        let buffer = replay(data, chunkSize: 1024)

        let lines = buffer.snapshot(range: 0..<buffer.lineCount)
        #expect(!lines.contains { $0.contains("Workingsin8") })
        #expect(lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("•") })
        #expect(lines.contains("• Working  33"))

        let wholeBuffer = replay(data, chunkSize: nil)
        #expect(wholeBuffer.snapshot(range: 0..<wholeBuffer.lineCount) == lines)
    }

    @Test func decstbmLineFeedAtBottomMarginScrollsRegion() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 5)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hone\r\ntwo\r\nthree\r\nfour\r\nfive".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<5) == ["one", "two", "three", "four", "five"])

        buffer.ingest(Data("\u{1B}[2;4r\u{1B}[4;1H\nnew".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<5) == ["one", "three", "four", "new", "five"])
    }

    @Test func reverseIndexAtTopMarginScrollsRegionDown() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 5)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hone\r\ntwo\r\nthree\r\nfour\r\nfive".utf8), viewportSize: viewport)
        buffer.ingest(Data("\u{1B}[2;4r\u{1B}[2;1H\u{1B}M".utf8), viewportSize: viewport)

        #expect(buffer.snapshot(range: 0..<5) == ["one", "", "two", "three", "five"])
    }

    @Test func scrollUpAndScrollDownCommandsMoveScreenContents() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 4)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049ha\r\nb\r\nc\r\nd".utf8), viewportSize: viewport)
        buffer.ingest(Data("\u{1B}[1S".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<4) == ["b", "c", "d", ""])

        buffer.ingest(Data("\u{1B}[1T".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<4) == ["", "b", "c", "d"])
    }

    @Test func insertAndDeleteLinesShiftRowsWithinRegion() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 5)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hone\r\ntwo\r\nthree\r\nfour\r\nfive".utf8), viewportSize: viewport)
        buffer.ingest(Data("\u{1B}[3;1H\u{1B}[2L".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<5) == ["one", "two", "", "", "three"])

        buffer.ingest(Data("\u{1B}[2M".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<5) == ["one", "two", "three", "", ""])
    }

    @Test func deleteCharactersShiftsRestOfLineLeft() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abcdef\r\u{1B}[2C\u{1B}[2P".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["abef"])
    }

    @Test func insertBlankCharactersShiftsRestOfLineRight() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abcdef\r\u{1B}[2C\u{1B}[2@".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["ab  cdef"])
    }

    @Test func eraseCharactersReplacesWithSpacesWithoutShifting() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abcdef\r\u{1B}[2C\u{1B}[3X".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["ab   f"])
    }

    @Test func verticalPositionAbsoluteKeepsColumn() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 5)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hone\r\ntwo\r\nthree\u{1B}[1dX".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<3) == ["one  X", "two", "three"])
    }

    @Test func horizontalPositionAbsoluteMovesColumn() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abcdef\u{1B}[2`XY".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["aXYdef"])
    }

    @Test func repeatLastPrintedCharacterExtendsRun() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("ab\u{1B}[3b".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["abbbb"])
    }

    @Test func eraseInDisplayModeOneClearsFromScreenStartToCursor() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 5)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hone\r\ntwo\r\nthree\u{1B}[2;3H\u{1B}[1J".utf8), viewportSize: viewport)
        #expect(buffer.snapshot(range: 0..<3) == ["", "   ", "three"])
    }

    @Test func commonRedrawCSISequencesUpdateFinalFrame() throws {
        let viewport = TerminalViewportSize(columns: 20, rows: 4)
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("\u{1B}[?1049hold-one\r\nold-two\r\nold-three".utf8), viewportSize: viewport)
        buffer.ingest(Data("\u{1B}[H\u{1B}[2Knew-one\r\n\u{1B}[2Knew-two".utf8), viewportSize: viewport)

        #expect(buffer.snapshot(range: 0..<3) == ["new-one", "new-two", "old-three"])

        buffer.ingest(Data("\u{1B}[1;1H\u{1B}[2Kabcdef\u{1B}[3G\u{1B}[K".utf8), viewportSize: viewport)

        #expect(buffer.snapshot(range: 0..<3) == ["ab", "new-two", "old-three"])
    }

    @Test func decscAndDecrcSaveAndRestoreCursor() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("hello\u{1B}7\u{1B}[HX\u{1B}8!".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["Xello!"])
    }

    @Test func ansiSaveAndRestoreCursorSequences() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("hello\u{1B}[s\u{1B}[HX\u{1B}[u!".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["Xello!"])
    }

    @Test func alternateScreen1049RestoresSavedCursorOnExit() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abc".utf8))
        buffer.ingest(Data("\u{1B}[?1049htui\u{1B}[2J\u{1B}[?1049l".utf8))
        #expect(!buffer.usesAlternateScreen)

        buffer.ingest(Data("def".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["abcdef"])
    }

    @Test func backspaceMovesCursorWithoutDeleting() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("abc\u{08}\u{08}X".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["aXc"])

        buffer.ingest(Data("\u{7F}Y".utf8))
        #expect(buffer.snapshot(range: 0..<1) == ["aYc"])
    }

    @Test func leavingAlternateScreenRetainsFinalFrameInScrollback() throws {
        var buffer = LiveTerminalOutputBuffer(maxScrollback: 100)

        buffer.ingest(Data("alpha\r\nbravo".utf8))
        buffer.ingest(Data("\u{1B}[?1049htui-line-1\r\n\r\ntui-line-3\r\n\r\n\u{1B}[?1049l".utf8))

        #expect(!buffer.usesAlternateScreen)
        #expect(buffer.snapshot(range: 0..<buffer.lineCount) == [
            "alpha",
            "bravo",
            "tui-line-1",
            "",
            "tui-line-3",
            ""
        ])
    }
}
