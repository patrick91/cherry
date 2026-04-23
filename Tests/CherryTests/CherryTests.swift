import AppKit
import Foundation
import Testing
@testable import Cherry

@Test func scrollbackIsBounded() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 3)
    buffer.appendPlainLines(["one", "two", "three", "four"])

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["two", "three", "four"])
}

@Test func pagedScrollbackStoresLinesAcrossPageBoundaries() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines((0..<300).map { "line-\($0)" })

    #expect(buffer.lineCount == 300)
    #expect(buffer.snapshot(range: 254..<258) == ["line-254", "line-255", "line-256", "line-257"])
}

@Test func pagedScrollbackTrimsAcrossPageBoundaries() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 260)
    buffer.appendPlainLines((0..<300).map { "line-\($0)" })

    #expect(buffer.lineCount == 260)
    #expect(buffer.snapshot(range: 0..<3) == ["line-40", "line-41", "line-42"])
}

@Test func ansiForegroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[32mhello\u{1B}[0m world".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["hello world"])
    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)
    #expect(styled.count == 1)
    #expect(styled[0].runs.count == 2)
    #expect(styled[0].runs[0] == TerminalTextRun(text: "hello", style: TerminalTextStyle(foreground: .ansi16(2))))
    #expect(styled[0].runs[1] == TerminalTextRun(text: " world", style: TerminalTextStyle()))
}

@Test func carriageReturnRewritesTheCurrentLine() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("loading".utf8))
    buffer.ingest(Data("\r\u{1B}[2Kready".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ready"])
}

@Test func splitUTF8ScalarSurvivesReadBoundary() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data([0xC3]))
    buffer.ingest(Data([0xA9]))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["é"])
}

@Test func outputSoftWrapsAtViewportWidth() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abcdef".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 10))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["abc", "def"])
}

@Test func selectedTextOmitsNewlineAcrossSoftWrap() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abcdef".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 10))
    let selection = TerminalSelectionRange(
        anchor: buffer.gridPoint(row: 0, column: 0),
        extent: buffer.gridPoint(row: 1, column: 3)
    )

    #expect(buffer.selectedText(in: selection) == "abcdef")
}

@Test func cursorPositionReportRespondsToDeviceStatusRequest() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    let viewportSize = TerminalViewportSize(columns: 10, rows: 5)
    buffer.ingest(Data("abc\r\nxy".utf8), viewportSize: viewportSize)

    let responses = buffer.ingest(Data("\u{1B}[6n".utf8), viewportSize: viewportSize)

    #expect(responses == [Data("\u{1B}[2;3R".utf8)])
}

@Test func terminalEnterSendsCarriageReturn() async throws {
    let enter = TerminalInputEncoder.commandSequence(for: #selector(NSResponder.insertNewline(_:)))

    #expect(enter == Data("\r".utf8))
}

@Test func selectedTextSpansRows() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("alpha\r\nbravo\r\ncharlie".utf8))
    let selection = TerminalSelectionRange(
        anchor: TerminalGridPoint(row: 0, column: 2),
        extent: TerminalGridPoint(row: 2, column: 4)
    )

    #expect(buffer.selectedText(in: selection) == "pha\nbravo\nchar")
}

@Test func selectedTextHandlesReverseSelection() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("alpha\r\nbravo".utf8))
    let selection = TerminalSelectionRange(
        anchor: TerminalGridPoint(row: 1, column: 3),
        extent: TerminalGridPoint(row: 0, column: 1)
    )

    #expect(buffer.selectedText(in: selection) == "lpha\nbra")
}

@Test func selectedTextAnchorsSurviveScrollbackTrim() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: 260)
    buffer.appendPlainLines((0..<260).map { "line-\($0)" })
    let selection = TerminalSelectionRange(
        anchor: buffer.gridPoint(row: 250, column: 0),
        extent: buffer.gridPoint(row: 251, column: 8)
    )

    buffer.appendPlainLines((260..<300).map { "line-\($0)" })

    #expect(buffer.selectedText(in: selection) == "line-250\nline-251")
}

@Test func alternateScreenDoesNotPolluteScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["main-1", "main-2"])

    buffer.ingest(Data("\u{1B}[?1049hfull".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["full", "", "", ""])

    buffer.ingest(Data("\u{1B}[?1049l".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["main-1", "main-2"])
}

@Test func alternateScreenScrollsWithinViewport() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 3)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049ha\r\nb\r\nc\r\nd".utf8), viewportSize: viewportSize)

    #expect(buffer.lineCount == 3)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["b", "c", "d"])
}

@Test func cursorUpAndEraseDisplayAllowPromptRepaint() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("top line\r\n> a".utf8))
    buffer.ingest(Data("\r\r\u{1B}[A\u{1B}[Jtop line\r\n> abc".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top line", "> abc"])
}

@Test func capturedZshPromptRedrawKeepsFullCommand() async throws {
    let prompt = Data(hexEncoded:
        "7e2020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020200d200d1b5d373b6b697474792d7368656c6c2d6377643a2f2f706174626f6f6b2f55736572732f7061747269636b2f6769746875622f7061747269636b39312f636865727279071b5d373b6b697474792d7368656c6c2d6377643a2f2f706174626f6f6b2f55736572732f7061747269636b2f6769746875622f7061747269636b39312f636865727279071b5d323be280a62f6769746875622f7061747269636b39312f636865727279070d1b5b306d1b5b32376d1b5b32346d1b5b4a1b5d3133333b413b636c3d6c696e65071b5b313b33366d7e2f6769746875622f7061747269636b39312f6368657272791b5b306d201b5b313b33356d206d61696e1b5b306d201b5b313b33336d5b21363f335d1b5b306d200d0a1b5b313b33326de29daf1b5b306d201b5d3133333b42071b5b4b1b5b3520711b5b3f3230303468"
    )
    let redraw = Data(hexEncoded:
        "611b5b411b5b306d1b5b32376d1b5b32346d1b5b4a1b5d3133333b413b636c3d6c696e65071b5b313b33366d7e2f6769746875622f7061747269636b39312f6368657272791b5b306d201b5b313b33356d206d61696e1b5b306d201b5b313b33336d5b21363f335d1b5b306d200d0a1b5b313b33326de29daf1b5b306d201b5d3133333b42076162630808081b5b316d1b5b33316d611b5b316d1b5b33316d621b5b316d1b5b33316d631b5b306d1b5b33396d"
    )

    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(prompt)
    buffer.ingest(redraw)

    let snapshot = buffer.snapshot(range: 0..<buffer.lineCount)
    #expect(snapshot.last?.contains("abc") == true)
}

private extension Data {
    init(hexEncoded string: String) {
        self.init()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            let byte = UInt8(string[index..<next], radix: 16)!
            append(byte)
            index = next
        }
    }
}
