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

@Test func ansiBackgroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48;5;236mhello\u{1B}[49m world".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs[0] == TerminalTextRun(
        text: "hello",
        style: TerminalTextStyle(background: .palette256(236))
    ))
    #expect(styled[0].runs[1] == TerminalTextRun(text: " world", style: TerminalTextStyle()))
}

@Test func colonSeparatedBackgroundColorIsPreserved() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48:5:236;38:5:250mhello\u{1B}[0m".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs == [
        TerminalTextRun(
            text: "hello",
            style: TerminalTextStyle(foreground: .palette256(250), background: .palette256(236))
        )
    ])
}

@Test func colonSeparatedTruecolorBackgroundIgnoresColorSpace() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("\u{1B}[48:2::49:48:55mempty\u{1B}[0m ".utf8))
    buffer.ingest(Data("\u{1B}[48:2:0:49:48:55mzero\u{1B}[0m".utf8))

    let styled = buffer.styledSnapshot(range: 0..<buffer.lineCount)

    #expect(styled[0].runs == [
        TerminalTextRun(
            text: "empty",
            style: TerminalTextStyle(background: .rgb(49, 48, 55))
        ),
        TerminalTextRun(text: " ", style: TerminalTextStyle()),
        TerminalTextRun(
            text: "zero",
            style: TerminalTextStyle(background: .rgb(49, 48, 55))
        )
    ])
}

@Test func eraseLineUsesCurrentBackgroundStyle() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    let viewportSize = TerminalViewportSize(columns: 8, rows: 3)

    buffer.ingest(Data("\u{1B}[48;5;236m\u{1B}[KX".utf8), viewportSize: viewportSize)

    #expect(buffer.lineLength(at: 0) == 8)
    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(
            text: "X       ",
            style: TerminalTextStyle(background: .palette256(236))
        )
    ])
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

@Test func nerdFontPrivateUseGlyphsSurviveBuffering() async throws {
    let branchGlyph = String(UnicodeScalar(0xE0A0)!)
    let fileGlyph = String(UnicodeScalar(0xF15B)!)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\(branchGlyph) main \(fileGlyph) README.md".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["\(branchGlyph) main \(fileGlyph) README.md"])
}

@Test func vt100CharsetDesignationDoesNotLeakSelectorBytes() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}(Bplain".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["plain"])
}

@Test func decSpecialGraphicsMapsLineDrawingCharacters() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}(0lqk\r\nx x\r\nmqj\u{1B}(B".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == [
        "┌─┐",
        "│ │",
        "└─┘"
    ])
}

@Test func shiftOutSelectsG1CharsetUntilShiftIn() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B})0\u{0E}q\u{0F}q".utf8))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["─q"])
}

@Test func wideEmojiGlyphsOccupyTwoTerminalCells() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("a\(upArrow)b".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a\(upArrow)b"])
    #expect(buffer.lineLength(at: 0) == 4)
    #expect(buffer.cursorState.column == 4)
}

@Test func styledWideGlyphBackgroundTracksCellWidth() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[48;5;236m\(upArrow)\u{1B}[0m".utf8))

    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(
            text: upArrow,
            style: TerminalTextStyle(background: .palette256(236)),
            cellWidth: 2
        )
    ])
}

@Test func wideGlyphSoftWrapsBeforeRightEdge() async throws {
    let upArrow = "\u{2B06}\u{FE0F}"
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("ab\(upArrow)c".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ab", "\(upArrow)c"])
}

@Test func disabledWraparoundOverwritesRightmostCell() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("abc\u{1B}[?7lXY".utf8), viewportSize: TerminalViewportSize(columns: 3, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["abY"])
    #expect(buffer.cursorState.column == 2)
}

@Test func privateKeyboardModifierSequenceDoesNotChangeTextStyle() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[>4;2mplain".utf8))

    #expect(buffer.styledSnapshot(range: 0..<1)[0].runs == [
        TerminalTextRun(text: "plain", style: TerminalTextStyle())
    ])
}

@Test func repeatPrecedingCharacterRepeatsLastGlyph() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("a\u{1B}[4b".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["aaaaa"])
}

@Test func insertCharactersShiftsTextRightWithinRow() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("abcdef\u{1B}[4D\u{1B}[2@".utf8), viewportSize: TerminalViewportSize(columns: 8, rows: 4))

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["ab  cdef"])
}

@Test func insertAndDeleteLinesShiftWithinScrollRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 8, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049ha\r\nb\r\nc\u{1B}[2;1H\u{1B}[L".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a", "", "b", "c"])

    buffer.ingest(Data("\u{1B}[2;1H\u{1B}[M".utf8), viewportSize: viewportSize)
    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["a", "b", "c", ""])
}

@Test func nerdFontFamiliesPreferMonoFonts() async throws {
    let families = [
        "Example Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "Apple Symbols",
        "CaskaydiaCove Nerd Font Mono"
    ]

    #expect(TerminalFontPalette.preferredNerdFontFamilies(from: families) == [
        "JetBrainsMono Nerd Font Mono",
        "CaskaydiaCove Nerd Font Mono",
        "Example Nerd Font"
    ])
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

@Test func terminalPaletteQueriesRespondWithDefaultColors() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    let responses = buffer.ingest(Data("\u{1B}]10;?\u{07}\u{1B}]11;?\u{1B}\\".utf8))

    #expect(responses == [
        Data("\u{1B}]10;rgb:dbdb/e3e3/ebeb\u{07}".utf8),
        Data("\u{1B}]11;rgb:1212/1111/1717\u{07}".utf8)
    ])
}

@Test func deviceAttributesAndKeyboardProtocolQueriesRespond() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    let startupProbe =
        "\u{1B}[?2004h" +
        "\u{1B}[>7u" +
        "\u{1B}[?1004h" +
        "\u{1B}[?u" +
        "\u{1B}[c" +
        "\u{1B}[>c"
    let responses = buffer.ingest(Data(startupProbe.utf8))

    #expect(responses == [
        Data("\u{1B}[?0u".utf8),
        Data("\u{1B}[?1;2c".utf8),
        Data("\u{1B}[>0;0;0c".utf8)
    ])
}

@Test func cursorStateTracksWritesAndMovement() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.ingest(Data("abc\u{1B}[D".utf8), viewportSize: TerminalViewportSize(columns: 10, rows: 5))

    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 2, shape: .block, isVisible: true))
}

@Test func cursorShapeAndVisibilityFollowControlSequences() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[5 q\u{1B}[?25l".utf8))
    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 0, shape: .bar, isVisible: false))

    buffer.ingest(Data("\u{1B}[4 q\u{1B}[?25h".utf8))
    #expect(buffer.cursorState == TerminalCursorState(row: 0, column: 0, shape: .underline, isVisible: true))

    buffer.ingest(Data("\u{1B}[2 q".utf8))
    #expect(buffer.cursorState.shape == .block)
}

@Test func terminalTracksMouseAndAlternateScrollModes() async throws {
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)

    buffer.ingest(Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1007l\u{1B}[?1004h".utf8))

    #expect(buffer.usesAlternateScreen)
    #expect(buffer.mouseState == TerminalMouseState(
        trackingMode: .normal,
        usesSGREncoding: true,
        alternateScrollMode: false,
        sendsFocusEvents: true
    ))
}

@Test func alternateScreenScrollWheelProducesCursorKeys() async throws {
    var remainder: CGFloat = 0

    let sequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )

    #expect(sequence == Data("\u{1B}[A".utf8))
}

@Test func preciseScrollAccumulatesByFullTerminalCell() async throws {
    var remainder: CGFloat = 0

    let firstSequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 10,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )
    let secondSequence = TerminalInputEncoder.alternateScreenScrollSequence(
        deltaY: 10,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        remainder: &remainder
    )

    #expect(firstSequence == nil)
    #expect(secondSequence == Data("\u{1B}[A".utf8))
}

@Test func sgrMouseWheelProducesTerminalMouseEvents() async throws {
    var remainder: CGFloat = 0

    let sequence = TerminalInputEncoder.mouseWheelSequence(
        deltaY: -20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        column: 5,
        row: 3,
        mouseState: TerminalMouseState(trackingMode: .normal, usesSGREncoding: true),
        remainder: &remainder
    )

    #expect(sequence == Data("\u{1B}[<65;5;3M".utf8))
}

@Test func terminalMousePositionUsesVisibleViewportCoordinates() async throws {
    let position = TerminalInputEncoder.mousePosition(
        documentLocation: NSPoint(x: 22 + 4.5 * 8, y: 900 + 24 + 2.5 * 20),
        visibleOrigin: NSPoint(x: 0, y: 900),
        viewportSize: TerminalViewportSize(columns: 80, rows: 24),
        sideInset: 22,
        topInset: 24,
        cellWidth: 8,
        lineHeight: 20
    )

    #expect(position.column == 5)
    #expect(position.row == 3)
}

@Test func viewportScrollOffsetClampsAtDocumentEdges() async throws {
    let contentHeight: CGFloat = 1_000
    let viewportHeight: CGFloat = 400

    #expect(TerminalInputEncoder.clampedViewportOffset(
        currentOffset: 4,
        deltaY: 20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        documentHeight: contentHeight,
        viewportHeight: viewportHeight
    ) == 0)
    #expect(TerminalInputEncoder.clampedViewportOffset(
        currentOffset: 590,
        deltaY: -20,
        hasPreciseScrollingDeltas: true,
        lineHeight: 20,
        documentHeight: contentHeight,
        viewportHeight: viewportHeight
    ) == 600)
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

@Test func screenRelativeCursorAddressingPreservesScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 3)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["old-0", "old-1", "screen-0", "screen-1", "screen-2"])

    buffer.ingest(Data("\u{1B}[1;1HX".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == [
        "old-0",
        "old-1",
        "Xcreen-0",
        "screen-1",
        "screen-2"
    ])
}

@Test func scrollRegionScrollsOnlyRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["top", "one", "two", "bottom"])

    buffer.ingest(Data("\u{1B}[2;3r\u{1B}[3;1H\r\n".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top", "two", "", "bottom"])
}

@Test func topAnchoredPrimaryScrollRegionPreservesScrollback() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["one", "two", "three", "status"])

    buffer.ingest(Data("\u{1B}[1;3r\u{1B}[3;1H\r\n".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["one", "two", "three", "", "status"])
    #expect(buffer.cursorState.row == 3)
}

@Test func reverseIndexScrollsOnlyRegion() async throws {
    let viewportSize = TerminalViewportSize(columns: 10, rows: 4)
    var buffer = PrototypeTerminalBuffer(maxScrollback: nil)
    buffer.appendPlainLines(["top", "one", "two", "bottom"])

    buffer.ingest(Data("\u{1B}[2;3r\u{1B}[2;1H\u{1B}M".utf8), viewportSize: viewportSize)

    #expect(buffer.snapshot(range: 0..<buffer.lineCount) == ["top", "", "one", "bottom"])
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
