import Foundation

enum TerminalANSIColor: Equatable {
    case ansi16(Int)
    case palette256(Int)
    case rgb(UInt8, UInt8, UInt8)
}

struct TerminalTextStyle: Equatable {
    var foreground: TerminalANSIColor? = nil
    var background: TerminalANSIColor? = nil
    var isBold = false
    var isDim = false
    var isInverse = false

    var paintsBackground: Bool {
        background != nil || isInverse
    }
}

struct TerminalTextRun: Equatable {
    let text: String
    let style: TerminalTextStyle
    let cellWidth: Int

    init(text: String, style: TerminalTextStyle, cellWidth: Int? = nil) {
        self.text = text
        self.style = style
        self.cellWidth = cellWidth ?? text.reduce(0) { $0 + Self.cellWidth(for: $1) }
    }

    static func cellWidth(for character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }

        if scalars.contains(where: { $0.value == 0xFE0E }) {
            return 1
        }

        if scalars.contains(where: { $0.value == 0xFE0F }) {
            return 2
        }

        return scalars.map { cellWidth(for: $0) }.max() ?? 1
    }

    private static func cellWidth(for scalar: UnicodeScalar) -> Int {
        let value = scalar.value

        if value == 0 ||
            value == 0x200D ||
            (0x0300...0x036F).contains(value) ||
            (0x1AB0...0x1AFF).contains(value) ||
            (0x1DC0...0x1DFF).contains(value) ||
            (0x20D0...0x20FF).contains(value) ||
            (0xFE00...0xFE0F).contains(value) ||
            (0xFE20...0xFE2F).contains(value) ||
            (0xE0100...0xE01EF).contains(value) {
            return 0
        }

        if (0x1100...0x115F).contains(value) ||
            (0x2329...0x232A).contains(value) ||
            (0x2E80...0xA4CF).contains(value) ||
            (0xAC00...0xD7A3).contains(value) ||
            (0xF900...0xFAFF).contains(value) ||
            (0xFE10...0xFE19).contains(value) ||
            (0xFE30...0xFE6F).contains(value) ||
            (0xFF00...0xFF60).contains(value) ||
            (0xFFE0...0xFFE6).contains(value) ||
            (0x1F000...0x1FAFF).contains(value) ||
            (0x20000...0x3FFFD).contains(value) {
            return 2
        }

        return 1
    }
}

struct TerminalRenderedLine: Equatable {
    let runs: [TerminalTextRun]

    var plainText: String {
        runs.map(\.text).joined()
    }
}

enum TerminalCursorShape: Equatable {
    case block
    case bar
    case underline
}

struct TerminalCursorState: Equatable {
    let row: Int
    let column: Int
    let shape: TerminalCursorShape
    let isVisible: Bool
}

enum TerminalMouseTrackingMode: Equatable {
    case disabled
    case normal
    case buttonEvent
    case anyEvent

    var isEnabled: Bool {
        self != .disabled
    }
}

struct TerminalMouseState: Equatable {
    var trackingMode = TerminalMouseTrackingMode.disabled
    var usesSGREncoding = false
    var alternateScrollMode = true
    var sendsFocusEvents = false
}

struct TerminalBufferLineID: Equatable, Hashable, Comparable {
    let rawValue: UInt64

    static func < (lhs: TerminalBufferLineID, rhs: TerminalBufferLineID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TerminalGridPoint: Equatable, Comparable {
    let row: Int
    let column: Int
    let lineID: TerminalBufferLineID?

    init(row: Int, column: Int, lineID: TerminalBufferLineID? = nil) {
        self.row = row
        self.column = column
        self.lineID = lineID
    }

    static func < (lhs: TerminalGridPoint, rhs: TerminalGridPoint) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }

        if lhs.column != rhs.column {
            return lhs.column < rhs.column
        }

        switch (lhs.lineID, rhs.lineID) {
        case let (lhsID?, rhsID?):
            return lhsID < rhsID
        case (nil, _?):
            return true
        default:
            return false
        }
    }
}

struct TerminalSelectionRange: Equatable {
    let anchor: TerminalGridPoint
    let extent: TerminalGridPoint

    var isEmpty: Bool {
        anchor == extent
    }

    var normalized: (start: TerminalGridPoint, end: TerminalGridPoint) {
        anchor <= extent
            ? (anchor, extent)
            : (extent, anchor)
    }
}

private struct TerminalCell: Equatable {
    let character: Character
    let style: TerminalTextStyle
    var isSpacer = false
}

private struct TerminalBufferLine: Equatable {
    let id: TerminalBufferLineID
    var cells: [TerminalCell] = []
    var isSoftWrapped = false
}

private struct TerminalBufferPage: Equatable {
    var lines: [TerminalBufferLine] = []
}

private struct TerminalPageGrid: Equatable {
    private let pageCapacity: Int
    private var pages: [TerminalBufferPage] = []
    private var nextLineID: UInt64 = 1

    init(pageCapacity: Int = 256) {
        self.pageCapacity = max(1, pageCapacity)
    }

    var isEmpty: Bool {
        lineCount == 0
    }

    var lineCount: Int {
        pages.reduce(0) { $0 + $1.lines.count }
    }

    func cells(at row: Int) -> [TerminalCell] {
        guard let location = locate(row: row) else { return [] }
        return pages[location.page].lines[location.line].cells
    }

    func lineLength(at row: Int) -> Int {
        cells(at: row).count
    }

    func isSoftWrapped(at row: Int) -> Bool {
        line(at: row)?.isSoftWrapped ?? false
    }

    func gridPoint(row: Int, column: Int) -> TerminalGridPoint {
        TerminalGridPoint(
            row: row,
            column: column,
            lineID: lineID(at: row)
        )
    }

    func renderedLines(range: Range<Int>) -> [TerminalRenderedLine] {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        return (lower..<upper).map { row in
            guard row < lineCount else { return TerminalRenderedLine(runs: []) }
            return PrototypeTerminalBuffer.renderedLine(from: cells(at: row))
        }
    }

    func selectedText(in selection: TerminalSelectionRange) -> String {
        guard !selection.isEmpty, !isEmpty else { return "" }

        let anchor = resolvedPoint(selection.anchor)
        let extent = resolvedPoint(selection.extent)
        let startPoint: TerminalGridPoint
        let endPoint: TerminalGridPoint
        if anchor <= extent {
            startPoint = anchor
            endPoint = extent
        } else {
            startPoint = extent
            endPoint = anchor
        }
        let startRow = max(0, min(startPoint.row, lineCount - 1))
        let endRow = max(0, min(endPoint.row, lineCount - 1))
        guard startRow <= endRow else { return "" }

        var selectedText = ""

        for row in startRow...endRow {
            let cells = cells(at: row)
            let startColumn: Int
            let endColumn: Int

            if row == startRow, row == endRow {
                startColumn = startPoint.column
                endColumn = endPoint.column
            } else if row == startRow {
                startColumn = startPoint.column
                endColumn = cells.count
            } else if row == endRow {
                startColumn = 0
                endColumn = endPoint.column
            } else {
                startColumn = 0
                endColumn = cells.count
            }

            if row > startRow {
                selectedText += isSoftWrapped(at: row - 1) ? "" : "\n"
            }
            selectedText += Self.text(from: cells, startColumn: startColumn, endColumn: endColumn)
        }

        return selectedText
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        pages.removeAll(keepingCapacity: keepingCapacity)
        nextLineID = 1
    }

    mutating func appendLine(_ cells: [TerminalCell] = []) {
        ensureWritablePage()
        pages[pages.count - 1].lines.append(TerminalBufferLine(id: makeLineID(), cells: cells))
    }

    mutating func insertLine(_ cells: [TerminalCell] = [], at row: Int) {
        let newLine = TerminalBufferLine(id: makeLineID(), cells: cells)
        let clampedRow = max(0, min(row, lineCount))
        var lines = (0..<lineCount).compactMap { line(at: $0) }
        lines.insert(newLine, at: clampedRow)
        rebuild(from: lines)
    }

    mutating func appendLines(_ lines: [[TerminalCell]]) {
        for line in lines {
            appendLine(line)
        }
    }

    mutating func ensureLine(at row: Int) {
        guard row >= 0 else { return }
        while lineCount <= row {
            appendLine()
        }
    }

    mutating func setCells(_ cells: [TerminalCell], at row: Int) {
        ensureLine(at: row)
        guard let location = locate(row: row) else { return }
        pages[location.page].lines[location.line].cells = cells
    }

    mutating func setSoftWrapped(_ isSoftWrapped: Bool, at row: Int) {
        ensureLine(at: row)
        guard let location = locate(row: row) else { return }
        pages[location.page].lines[location.line].isSoftWrapped = isSoftWrapped
    }

    mutating func appendCells(_ cells: [TerminalCell], at row: Int) {
        ensureLine(at: row)
        guard let location = locate(row: row) else { return }
        pages[location.page].lines[location.line].cells.append(contentsOf: cells)
    }

    mutating func removeRows(in range: Range<Int>) {
        guard !range.isEmpty, !isEmpty else { return }

        let lower = max(0, min(range.lowerBound, lineCount))
        let upper = max(lower, min(range.upperBound, lineCount))
        guard lower < upper else { return }

        let kept = (0..<lineCount)
            .filter { !((lower..<upper).contains($0)) }
            .compactMap { line(at: $0) }
        rebuild(from: kept)
    }

    mutating func trimPrefix(_ count: Int) {
        guard count > 0 else { return }
        var remaining = min(count, lineCount)
        while remaining > 0, !pages.isEmpty {
            let pageLineCount = pages[0].lines.count
            if remaining >= pageLineCount {
                pages.removeFirst()
                remaining -= pageLineCount
            } else {
                pages[0].lines.removeFirst(remaining)
                remaining = 0
            }
        }
    }

    private func locate(row: Int) -> (page: Int, line: Int)? {
        guard row >= 0 else { return nil }

        var remaining = row
        for pageIndex in pages.indices {
            let count = pages[pageIndex].lines.count
            if remaining < count {
                return (pageIndex, remaining)
            }

            remaining -= count
        }

        return nil
    }

    private func locate(lineID: TerminalBufferLineID) -> (row: Int, page: Int, line: Int)? {
        var row = 0
        for pageIndex in pages.indices {
            for lineIndex in pages[pageIndex].lines.indices {
                if pages[pageIndex].lines[lineIndex].id == lineID {
                    return (row, pageIndex, lineIndex)
                }
                row += 1
            }
        }

        return nil
    }

    private func line(at row: Int) -> TerminalBufferLine? {
        guard let location = locate(row: row) else { return nil }
        return pages[location.page].lines[location.line]
    }

    private func lineID(at row: Int) -> TerminalBufferLineID? {
        line(at: row)?.id
    }

    private func resolvedPoint(_ point: TerminalGridPoint) -> TerminalGridPoint {
        guard let lineID = point.lineID,
              let location = locate(lineID: lineID) else {
            return point
        }

        return TerminalGridPoint(row: location.row, column: point.column, lineID: lineID)
    }

    private mutating func ensureWritablePage() {
        guard let lastPage = pages.indices.last else {
            pages.append(TerminalBufferPage())
            return
        }

        if pages[lastPage].lines.count >= pageCapacity {
            pages.append(TerminalBufferPage())
        }
    }

    private mutating func rebuild(from lines: [TerminalBufferLine]) {
        pages.removeAll(keepingCapacity: true)
        for line in lines {
            ensureWritablePage()
            pages[pages.count - 1].lines.append(line)
        }
    }

    private mutating func makeLineID() -> TerminalBufferLineID {
        defer { nextLineID &+= 1 }
        return TerminalBufferLineID(rawValue: nextLineID)
    }

    private static func text(from cells: [TerminalCell], startColumn: Int, endColumn: Int) -> String {
        let lower = max(0, min(startColumn, cells.count))
        let upper = max(lower, min(endColumn, cells.count))
        guard lower < upper else { return "" }
        return cells[lower..<upper]
            .filter { !$0.isSpacer }
            .map(\.character)
            .map(String.init)
            .joined()
    }
}

protocol TerminalBuffering {
    var lineCount: Int { get }
    var storedLineCount: Int { get }
    var cursorState: TerminalCursorState { get }
    var usesAlternateScreen: Bool { get }
    var usesApplicationCursorKeys: Bool { get }
    var mouseState: TerminalMouseState { get }

    func snapshot(range: Range<Int>) -> [String]
    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine]
    func lineLength(at row: Int) -> Int
    func gridPoint(row: Int, column: Int) -> TerminalGridPoint
    func selectedText(in selection: TerminalSelectionRange) -> String

    mutating func clear()
    mutating func resize(to viewportSize: TerminalViewportSize)
    mutating func appendPlainLines(_ newLines: [String])

    @discardableResult
    mutating func ingest(_ data: Data, viewportSize: TerminalViewportSize) -> [Data]
}

extension TerminalBuffering {
    @discardableResult
    mutating func ingest(_ data: Data) -> [Data] {
        ingest(data, viewportSize: TerminalViewportSize(columns: 120, rows: 32))
    }
}

struct PrototypeTerminalBuffer: TerminalBuffering {
    private enum ParserState {
        case ground
        case escape
        case charsetDesignation(GraphicCharsetSlot)
        case csi
        case osc
        case ignoredString
    }

    private enum GraphicCharsetSlot {
        case g0
        case g1
        case g2
        case g3
    }

    private enum GraphicCharset {
        case ascii
        case british
        case decSpecial
    }

    private struct ScreenState {
        var cursorRow: Int
        var cursorColumn: Int
        var style: TerminalTextStyle
        var g0Charset: GraphicCharset
        var g1Charset: GraphicCharset
        var g2Charset: GraphicCharset
        var g3Charset: GraphicCharset
        var activeGraphicCharsetSlot: GraphicCharsetSlot
    }

    private let maxScrollback: Int?

    private var mainGrid = TerminalPageGrid()
    private var alternateGrid = TerminalPageGrid()
    private var currentViewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var isUsingAlternateScreen = false
    private var savedCursorState: ScreenState?
    private var cursorRow = 0
    private var cursorColumn = 0
    private var cursorShape = TerminalCursorShape.block
    private var isCursorVisible = true
    private var isApplicationCursorMode = false
    private var scrollRegionTop: Int?
    private var scrollRegionBottom: Int?
    private var isLeftRightMarginMode = false
    private var leftMarginColumn = 0
    private var rightMarginColumn: Int?
    private var currentMouseState = TerminalMouseState()
    private var isBracketedPasteMode = false
    private var parserState: ParserState = .ground
    private var controlBuffer: [UInt8] = []
    private var pendingText: [UInt8] = []
    private var escapedStringPendingST = false
    private var currentStyle = TerminalTextStyle()
    private var g0Charset = GraphicCharset.ascii
    private var g1Charset = GraphicCharset.ascii
    private var g2Charset = GraphicCharset.ascii
    private var g3Charset = GraphicCharset.ascii
    private var activeGraphicCharsetSlot = GraphicCharsetSlot.g0
    private var lastWrittenCharacter: Character?
    private var isWraparoundMode = true

    private static let defaultForegroundColor: (red: UInt8, green: UInt8, blue: UInt8) = (219, 227, 235)
    private static let defaultBackgroundColor: (red: UInt8, green: UInt8, blue: UInt8) = (18, 17, 23)
    private static let maximumOSCBytes = 8_192

    init(maxScrollback: Int?) {
        self.maxScrollback = maxScrollback
    }

    private var activeGrid: TerminalPageGrid {
        get {
            isUsingAlternateScreen ? alternateGrid : mainGrid
        }
        set {
            if isUsingAlternateScreen {
                alternateGrid = newValue
            } else {
                mainGrid = newValue
            }
        }
    }

    private var screenRows: Int {
        max(1, currentViewportSize.rows)
    }

    private var screenTopRow: Int {
        isUsingAlternateScreen ? 0 : max(0, activeGrid.lineCount - screenRows)
    }

    private var screenBottomRow: Int {
        screenTopRow + screenRows - 1
    }

    private var hasExplicitScrollRegion: Bool {
        scrollRegionTop != nil || scrollRegionBottom != nil
    }

    private var isScrollRegionActive: Bool {
        isUsingAlternateScreen || hasExplicitScrollRegion
    }

    private var relativeScrollRegion: (top: Int, bottom: Int) {
        let maximumRow = screenRows - 1
        let top = min(max(scrollRegionTop ?? 0, 0), maximumRow)
        let bottom = min(max(scrollRegionBottom ?? maximumRow, 0), maximumRow)
        guard top < bottom else { return (0, maximumRow) }
        return (top, bottom)
    }

    private var absoluteScrollRegion: (top: Int, bottom: Int) {
        let relativeRegion = relativeScrollRegion
        let screenTop = screenTopRow
        return (
            top: screenTop + relativeRegion.top,
            bottom: screenTop + relativeRegion.bottom
        )
    }

    var lineCount: Int {
        let minimumLineCount = isUsingAlternateScreen ? currentViewportSize.rows : 1
        return max(activeGrid.lineCount, minimumLineCount)
    }

    var storedLineCount: Int {
        lineCount
    }

    var cursorState: TerminalCursorState {
        TerminalCursorState(
            row: cursorRow,
            column: cursorColumn,
            shape: cursorShape,
            isVisible: isCursorVisible
        )
    }

    var usesAlternateScreen: Bool {
        isUsingAlternateScreen
    }

    var usesApplicationCursorKeys: Bool {
        isApplicationCursorMode
    }

    var mouseState: TerminalMouseState {
        currentMouseState
    }

    func snapshot(range: Range<Int>) -> [String] {
        styledSnapshot(range: range).map(\.plainText)
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        activeGrid.renderedLines(range: range)
    }

    func lineLength(at row: Int) -> Int {
        activeGrid.lineLength(at: row)
    }

    func gridPoint(row: Int, column: Int) -> TerminalGridPoint {
        activeGrid.gridPoint(row: row, column: column)
    }

    func selectedText(in selection: TerminalSelectionRange) -> String {
        activeGrid.selectedText(in: selection)
    }

    mutating func clear() {
        mainGrid.removeAll(keepingCapacity: false)
        alternateGrid.removeAll(keepingCapacity: false)
        isUsingAlternateScreen = false
        savedCursorState = nil
        cursorRow = 0
        cursorColumn = 0
        cursorShape = .block
        isCursorVisible = true
        isApplicationCursorMode = false
        scrollRegionTop = nil
        scrollRegionBottom = nil
        currentMouseState = TerminalMouseState()
        parserState = .ground
        controlBuffer.removeAll(keepingCapacity: false)
        pendingText.removeAll(keepingCapacity: false)
        escapedStringPendingST = false
        currentStyle = TerminalTextStyle()
        g0Charset = .ascii
        g1Charset = .ascii
        g2Charset = .ascii
        g3Charset = .ascii
        activeGraphicCharsetSlot = .g0
        lastWrittenCharacter = nil
        isWraparoundMode = true
    }

    mutating func appendPlainLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }

        flushPendingText()
        activeGrid.appendLines(newLines.map(Self.plainLine(from:)))

        cursorRow = max(0, activeGrid.lineCount - 1)
        cursorColumn = activeGrid.lineLength(at: cursorRow)
        trimIfNeeded()
    }

    mutating func resize(to viewportSize: TerminalViewportSize) {
        currentViewportSize = Self.normalizedViewportSize(viewportSize)
        normalizeScrollRegion()
        trimIfNeeded()
        clampCursor()
    }

    @discardableResult
    mutating func ingest(
        _ data: Data,
        viewportSize: TerminalViewportSize = TerminalViewportSize(columns: 120, rows: 32)
    ) -> [Data] {
        var responses: [Data] = []
        currentViewportSize = Self.normalizedViewportSize(viewportSize)

        for byte in data {
            process(byte, viewportSize: currentViewportSize, responses: &responses)
        }

        flushPendingText(preservingIncompleteUTF8: true)
        trimIfNeeded()
        clampCursor()

        return responses
    }

    private mutating func process(
        _ byte: UInt8,
        viewportSize: TerminalViewportSize,
        responses: inout [Data]
    ) {
        switch parserState {
        case .ground:
            processGround(byte)
        case .escape:
            processEscape(byte)
        case .charsetDesignation(let slot):
            processCharsetDesignation(byte, slot: slot)
        case .csi:
            processCSI(byte, viewportSize: viewportSize, responses: &responses)
        case .osc:
            processOSC(byte, responses: &responses)
        case .ignoredString:
            processIgnoredString(byte)
        }
    }

    private mutating func processGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            flushPendingText()
            parserState = .escape
        case 0x0A:
            flushPendingText()
            appendNewLine()
        case 0x0D:
            flushPendingText()
            cursorColumn = 0
        case 0x08, 0x7F:
            flushPendingText()
            cursorColumn = max(0, cursorColumn - 1)
        case 0x09:
            flushPendingText()
            let spaces = max(1, 8 - (cursorColumn % 8))
            writeText(String(repeating: " ", count: spaces))
        case 0x0E:
            flushPendingText()
            activeGraphicCharsetSlot = .g1
        case 0x0F:
            flushPendingText()
            activeGraphicCharsetSlot = .g0
        case 0x07:
            flushPendingText()
        case 0x00...0x1F:
            flushPendingText()
        default:
            pendingText.append(byte)
        }
    }

    private mutating func processEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            controlBuffer.removeAll(keepingCapacity: true)
            parserState = .csi
        case UInt8(ascii: "]"):
            controlBuffer.removeAll(keepingCapacity: true)
            escapedStringPendingST = false
            parserState = .osc
        case UInt8(ascii: "("):
            parserState = .charsetDesignation(.g0)
        case UInt8(ascii: ")"):
            parserState = .charsetDesignation(.g1)
        case UInt8(ascii: "*"):
            parserState = .charsetDesignation(.g2)
        case UInt8(ascii: "+"):
            parserState = .charsetDesignation(.g3)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            escapedStringPendingST = false
            parserState = .ignoredString
        case UInt8(ascii: "7"):
            saveCursorState()
            parserState = .ground
        case UInt8(ascii: "8"):
            restoreCursorState()
            parserState = .ground
        case UInt8(ascii: "M"):
            reverseIndex()
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private mutating func processCharsetDesignation(_ byte: UInt8, slot: GraphicCharsetSlot) {
        switch byte {
        case UInt8(ascii: "0"):
            setGraphicCharset(.decSpecial, for: slot)
        case UInt8(ascii: "A"):
            setGraphicCharset(.british, for: slot)
        case UInt8(ascii: "B"):
            setGraphicCharset(.ascii, for: slot)
        default:
            break
        }

        parserState = .ground
    }

    private mutating func processCSI(
        _ byte: UInt8,
        viewportSize: TerminalViewportSize,
        responses: inout [Data]
    ) {
        controlBuffer.append(byte)

        guard (0x40...0x7E).contains(byte) else { return }

        let finalByte = byte
        let payload = Array(controlBuffer.dropLast())
        handleCSI(finalByte: finalByte, payload: payload, viewportSize: viewportSize, responses: &responses)

        controlBuffer.removeAll(keepingCapacity: true)
        parserState = .ground
    }

    private mutating func processIgnoredString(_ byte: UInt8) {
        if escapedStringPendingST {
            escapedStringPendingST = false
            if byte == UInt8(ascii: "\\") {
                parserState = .ground
            } else if byte == 0x1B {
                escapedStringPendingST = true
            }

            return
        }

        if byte == 0x07 {
            parserState = .ground
        } else if byte == 0x1B {
            escapedStringPendingST = true
        }
    }

    private mutating func processOSC(_ byte: UInt8, responses: inout [Data]) {
        if escapedStringPendingST {
            escapedStringPendingST = false
            if byte == UInt8(ascii: "\\") {
                finishOSC(responses: &responses)
                return
            }

            appendOSCByte(0x1B)
        }

        if byte == 0x07 {
            finishOSC(responses: &responses)
        } else if byte == 0x1B {
            escapedStringPendingST = true
        } else {
            appendOSCByte(byte)
        }
    }

    private mutating func appendOSCByte(_ byte: UInt8) {
        guard controlBuffer.count < Self.maximumOSCBytes else { return }
        controlBuffer.append(byte)
    }

    private mutating func finishOSC(responses: inout [Data]) {
        let rawPayload = String(decoding: controlBuffer, as: UTF8.self)
        handleOSC(rawPayload: rawPayload, responses: &responses)

        controlBuffer.removeAll(keepingCapacity: true)
        escapedStringPendingST = false
        parserState = .ground
    }

    private func handleOSC(rawPayload: String, responses: inout [Data]) {
        let fields = rawPayload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, fields[1] == "?" else { return }

        switch fields[0] {
        case "10":
            responses.append(Self.oscColorResponse(code: "10", color: Self.defaultForegroundColor))
        case "11":
            responses.append(Self.oscColorResponse(code: "11", color: Self.defaultBackgroundColor))
        default:
            break
        }
    }

    private static func oscColorResponse(
        code: String,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> Data {
        let payload = "\u{1B}]\(code);rgb:\(hex16(color.red))/\(hex16(color.green))/\(hex16(color.blue))\u{07}"
        return Data(payload.utf8)
    }

    private static func hex16(_ value: UInt8) -> String {
        String(format: "%04x", UInt16(value) * 257)
    }

    private mutating func handleCSI(
        finalByte: UInt8,
        payload: [UInt8],
        viewportSize: TerminalViewportSize,
        responses: inout [Data]
    ) {
        let rawPayload = String(decoding: payload, as: UTF8.self)
        let isPrivateMode = rawPayload.first == "?"
        let parameters = rawPayload
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { segment -> Int? in
                let digits = segment.filter(\.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }

        func parameter(at index: Int, default fallback: Int) -> Int {
            guard parameters.indices.contains(index), let value = parameters[index] else {
                return fallback
            }

            return value
        }

        switch Character(UnicodeScalar(finalByte)) {
        case "m":
            guard !rawPayload.hasPrefix(">"),
                  !rawPayload.hasPrefix("?"),
                  !rawPayload.hasPrefix("=") else {
                return
            }
            applySGR(Self.sgrParameters(from: rawPayload))
        case "c":
            handleDeviceAttributes(rawPayload: rawPayload, responses: &responses)
        case "n":
            handleDeviceStatusReport(parameter(at: 0, default: 0), viewportSize: viewportSize, responses: &responses)
        case "p":
            handleModeStatusReport(rawPayload: rawPayload, responses: &responses)
        case "h", "l":
            guard isPrivateMode else { return }
            handlePrivateMode(
                isSet: finalByte == UInt8(ascii: "h"),
                parameters: parameters.compactMap { $0 },
                viewportSize: viewportSize
            )
        case "s":
            if isLeftRightMarginMode, !rawPayload.isEmpty {
                setHorizontalMargins(
                    left: parameter(at: 0, default: 1),
                    right: parameter(at: 1, default: currentViewportSize.columns)
                )
            } else {
                saveCursorState()
            }
        case "u":
            handleCursorRestoreOrKeyboardProtocol(rawPayload: rawPayload, responses: &responses)
        case "q":
            applyCursorShape(parameter(at: 0, default: 0))
        case "r":
            setScrollRegion(
                rawPayload: rawPayload,
                top: parameter(at: 0, default: 1),
                bottom: parameter(at: 1, default: screenRows)
            )
        case "A":
            moveCursorRow(by: -parameter(at: 0, default: 1))
        case "B":
            moveCursorRow(by: parameter(at: 0, default: 1))
        case "C":
            cursorColumn += parameter(at: 0, default: 1)
        case "D":
            cursorColumn = max(0, cursorColumn - parameter(at: 0, default: 1))
        case "E":
            moveCursorRow(by: parameter(at: 0, default: 1))
            cursorColumn = 0
        case "F":
            moveCursorRow(by: -parameter(at: 0, default: 1))
            cursorColumn = 0
        case "G":
            cursorColumn = max(0, parameter(at: 0, default: 1) - 1)
        case "H", "f":
            moveCursor(toRow: parameter(at: 0, default: 1) - 1, column: parameter(at: 1, default: 1) - 1)
        case "J":
            eraseInDisplay(mode: parameter(at: 0, default: 0))
        case "K":
            eraseInLine(mode: parameter(at: 0, default: 0))
        case "@":
            insertCharacters(parameter(at: 0, default: 1))
        case "P":
            deleteCharacters(parameter(at: 0, default: 1))
        case "X":
            eraseCharacters(parameter(at: 0, default: 1))
        case "L":
            insertLines(parameter(at: 0, default: 1))
        case "M":
            deleteLines(parameter(at: 0, default: 1))
        case "S":
            scrollAreaUp(parameter(at: 0, default: 1), top: absoluteScrollRegion.top, bottom: absoluteScrollRegion.bottom)
        case "T":
            scrollAreaDown(parameter(at: 0, default: 1), top: absoluteScrollRegion.top, bottom: absoluteScrollRegion.bottom)
        case "b":
            repeatPrecedingCharacter(parameter(at: 0, default: 1))
        default:
            return
        }
    }

    private func handleDeviceAttributes(rawPayload: String, responses: inout [Data]) {
        if rawPayload.first == ">" {
            responses.append(Data("\u{1B}[>0;0;0c".utf8))
            return
        }

        if rawPayload.isEmpty || rawPayload == "0" {
            responses.append(Data("\u{1B}[?1;2c".utf8))
        }
    }

    private mutating func handleCursorRestoreOrKeyboardProtocol(rawPayload: String, responses: inout [Data]) {
        switch rawPayload.first {
        case "?":
            responses.append(Data("\u{1B}[?0u".utf8))
        case ">", "<", "=":
            return
        default:
            restoreCursorState()
        }
    }

    private mutating func handleDeviceStatusReport(
        _ code: Int,
        viewportSize: TerminalViewportSize,
        responses: inout [Data]
    ) {
        switch code {
        case 5:
            responses.append(Data("\u{1B}[0n".utf8))
        case 6:
            responses.append(cursorPositionReport(viewportSize: viewportSize))
        default:
            return
        }
    }

    private func handleModeStatusReport(rawPayload: String, responses: inout [Data]) {
        guard rawPayload.hasPrefix("?"), rawPayload.hasSuffix("$") else { return }

        let modeText = rawPayload
            .dropFirst()
            .dropLast()
        guard let mode = Int(modeText) else { return }

        let status = privateModeStatus(mode)
        responses.append(Data("\u{1B}[?\(mode);\(status)$y".utf8))
    }

    private func privateModeStatus(_ mode: Int) -> Int {
        switch mode {
        case 1:
            isApplicationCursorMode ? 1 : 2
        case 25:
            isCursorVisible ? 1 : 2
        case 7:
            isWraparoundMode ? 1 : 2
        case 47, 1047, 1049:
            isUsingAlternateScreen ? 1 : 2
        case 69:
            isLeftRightMarginMode ? 1 : 2
        case 1000:
            currentMouseState.trackingMode == .normal ? 1 : 2
        case 1002:
            currentMouseState.trackingMode == .buttonEvent ? 1 : 2
        case 1003:
            currentMouseState.trackingMode == .anyEvent ? 1 : 2
        case 1004:
            currentMouseState.sendsFocusEvents ? 1 : 2
        case 1006:
            currentMouseState.usesSGREncoding ? 1 : 2
        case 1007:
            currentMouseState.alternateScrollMode ? 1 : 2
        case 2004:
            isBracketedPasteMode ? 1 : 2
        case 2026, 2027, 2031, 2048:
            4
        default:
            0
        }
    }

    private mutating func handlePrivateMode(
        isSet: Bool,
        parameters: [Int],
        viewportSize: TerminalViewportSize
    ) {
        for parameter in parameters {
            switch parameter {
            case 47, 1047:
                if isSet {
                    enterAlternateScreen(viewportSize: viewportSize, saveCursor: false)
                } else {
                    exitAlternateScreen(restoreCursor: false)
                }
            case 1048:
                if isSet {
                    saveCursorState()
                } else {
                    restoreCursorState()
                }
            case 1049:
                if isSet {
                    enterAlternateScreen(viewportSize: viewportSize, saveCursor: true)
                } else {
                    exitAlternateScreen(restoreCursor: true)
                }
            case 25:
                isCursorVisible = isSet
            case 1:
                isApplicationCursorMode = isSet
            case 69:
                isLeftRightMarginMode = isSet
                if !isSet {
                    resetHorizontalMargins()
                }
            case 7:
                isWraparoundMode = isSet
            case 1000:
                currentMouseState.trackingMode = isSet ? .normal : .disabled
            case 1002:
                currentMouseState.trackingMode = isSet ? .buttonEvent : .disabled
            case 1003:
                currentMouseState.trackingMode = isSet ? .anyEvent : .disabled
            case 1006:
                currentMouseState.usesSGREncoding = isSet
            case 1007:
                currentMouseState.alternateScrollMode = isSet
            case 1004:
                currentMouseState.sendsFocusEvents = isSet
            case 2004:
                isBracketedPasteMode = isSet
            case 2026:
                continue
            default:
                continue
            }
        }
    }

    private mutating func enterAlternateScreen(viewportSize: TerminalViewportSize, saveCursor: Bool) {
        if saveCursor {
            saveCursorState()
        }

        currentViewportSize = Self.normalizedViewportSize(viewportSize)
        isUsingAlternateScreen = true
        scrollRegionTop = nil
        scrollRegionBottom = nil
        resetHorizontalMargins()
        alternateGrid.removeAll(keepingCapacity: true)
        alternateGrid.appendLine()
        cursorRow = 0
        cursorColumn = 0
        ensureAlternateScreenRows()
    }

    private mutating func exitAlternateScreen(restoreCursor: Bool) {
        guard isUsingAlternateScreen else { return }

        alternateGrid.removeAll(keepingCapacity: true)
        isUsingAlternateScreen = false
        scrollRegionTop = nil
        scrollRegionBottom = nil
        resetHorizontalMargins()

        if restoreCursor {
            restoreCursorState()
        } else {
            clampCursor()
        }
    }

    private mutating func saveCursorState() {
        savedCursorState = ScreenState(
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            style: currentStyle,
            g0Charset: g0Charset,
            g1Charset: g1Charset,
            g2Charset: g2Charset,
            g3Charset: g3Charset,
            activeGraphicCharsetSlot: activeGraphicCharsetSlot
        )
    }

    private mutating func restoreCursorState() {
        guard let savedCursorState else { return }
        cursorRow = savedCursorState.cursorRow
        cursorColumn = savedCursorState.cursorColumn
        currentStyle = savedCursorState.style
        g0Charset = savedCursorState.g0Charset
        g1Charset = savedCursorState.g1Charset
        g2Charset = savedCursorState.g2Charset
        g3Charset = savedCursorState.g3Charset
        activeGraphicCharsetSlot = savedCursorState.activeGraphicCharsetSlot
        clampCursor()
    }

    private mutating func applyCursorShape(_ code: Int) {
        cursorShape = switch code {
        case 3, 4:
            .underline
        case 5, 6:
            .bar
        default:
            .block
        }
    }

    private mutating func setScrollRegion(rawPayload: String, top: Int, bottom: Int) {
        if rawPayload.isEmpty {
            scrollRegionTop = nil
            scrollRegionBottom = nil
            moveCursor(toRow: 0, column: 0)
            return
        }

        let maximumRow = screenRows - 1
        let normalizedTop = min(max(top - 1, 0), maximumRow)
        let normalizedBottom = min(max(bottom - 1, 0), maximumRow)
        guard normalizedTop < normalizedBottom else { return }

        scrollRegionTop = normalizedTop
        scrollRegionBottom = normalizedBottom
        moveCursor(toRow: 0, column: 0)
    }

    private mutating func setHorizontalMargins(left: Int, right: Int) {
        let columns = max(1, currentViewportSize.columns)
        let normalizedLeft = min(max(left - 1, 0), columns - 1)
        let normalizedRight = min(max(right - 1, 0), columns - 1)
        guard normalizedLeft < normalizedRight else {
            resetHorizontalMargins()
            return
        }

        leftMarginColumn = normalizedLeft
        rightMarginColumn = normalizedRight
        cursorRow = screenTopRow
        cursorColumn = normalizedLeft
    }

    private mutating func resetHorizontalMargins() {
        leftMarginColumn = 0
        rightMarginColumn = nil
    }

    private mutating func normalizeScrollRegion() {
        guard hasExplicitScrollRegion else { return }

        let maximumRow = screenRows - 1
        let normalizedTop = min(max(scrollRegionTop ?? 0, 0), maximumRow)
        let normalizedBottom = min(max(scrollRegionBottom ?? maximumRow, 0), maximumRow)
        guard normalizedTop < normalizedBottom else {
            scrollRegionTop = nil
            scrollRegionBottom = nil
            return
        }

        scrollRegionTop = normalizedTop
        scrollRegionBottom = normalizedBottom
    }

    private static func sgrParameters(from rawPayload: String) -> [Int?] {
        guard !rawPayload.isEmpty else { return [] }

        var values: [Int?] = []
        var separators: [Character?] = []
        var segment = ""

        func appendSegment(separator: Character?) {
            let digits = segment.filter(\.isNumber)
            values.append(digits.isEmpty ? nil : Int(digits))
            separators.append(separator)
            segment.removeAll(keepingCapacity: true)
        }

        for character in rawPayload {
            if character == ";" || character == ":" {
                appendSegment(separator: character)
            } else {
                segment.append(character)
            }
        }
        appendSegment(separator: nil)

        var normalized: [Int?] = []
        var index = 0

        while index < values.count {
            let value = values[index]
            normalized.append(value)

            if (value == 38 || value == 48),
               separators[index] == ":",
               values.indices.contains(index + 1),
               values[index + 1] == 2 {
                index += 1
                normalized.append(values[index])

                if separators[index] == ":",
                   values.count - (index + 1) >= 4 {
                    index += 1
                }
            }

            index += 1
        }

        return normalized
    }

    private mutating func applySGR(_ parameters: [Int?]) {
        let codes = parameters.isEmpty ? [0] : parameters.map { $0 ?? 0 }
        var index = 0

        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                currentStyle = TerminalTextStyle()
            case 1:
                currentStyle.isBold = true
            case 2:
                currentStyle.isDim = true
            case 22:
                currentStyle.isBold = false
                currentStyle.isDim = false
            case 7:
                currentStyle.isInverse = true
            case 27:
                currentStyle.isInverse = false
            case 30...37:
                currentStyle.foreground = .ansi16(code - 30)
            case 40...47:
                currentStyle.background = .ansi16(code - 40)
            case 39:
                currentStyle.foreground = nil
            case 49:
                currentStyle.background = nil
            case 90...97:
                currentStyle.foreground = .ansi16(code - 90 + 8)
            case 100...107:
                currentStyle.background = .ansi16(code - 100 + 8)
            case 38:
                index = applyExtendedColor(from: codes, startingAt: index, isForeground: true)
            case 48:
                index = applyExtendedColor(from: codes, startingAt: index, isForeground: false)
            default:
                break
            }

            index += 1
        }
    }

    private mutating func applyExtendedColor(from codes: [Int], startingAt index: Int, isForeground: Bool) -> Int {
        let next = index + 1
        guard codes.indices.contains(next) else { return index }

        switch codes[next] {
        case 5:
            let valueIndex = next + 1
            guard codes.indices.contains(valueIndex) else { return index }
            if isForeground {
                currentStyle.foreground = .palette256(codes[valueIndex])
            } else {
                currentStyle.background = .palette256(codes[valueIndex])
            }
            return valueIndex
        case 2:
            let redIndex = next + 1
            let greenIndex = next + 2
            let blueIndex = next + 3
            guard codes.indices.contains(redIndex),
                  codes.indices.contains(greenIndex),
                  codes.indices.contains(blueIndex) else {
                return index
            }
            if isForeground {
                currentStyle.foreground = .rgb(
                    UInt8(clamping: codes[redIndex]),
                    UInt8(clamping: codes[greenIndex]),
                    UInt8(clamping: codes[blueIndex])
                )
            } else {
                currentStyle.background = .rgb(
                    UInt8(clamping: codes[redIndex]),
                    UInt8(clamping: codes[greenIndex]),
                    UInt8(clamping: codes[blueIndex])
                )
            }
            return blueIndex
        default:
            return index
        }
    }

    private mutating func eraseInDisplay(mode: Int) {
        ensureCursorLine()

        switch mode {
        case 1:
            clearRows(in: screenTopRow..<cursorRow, ensureStorage: false)
            eraseInLine(mode: 1)
        case 2:
            clearRows(in: screenTopRow..<(screenBottomRow + 1), ensureStorage: isUsingAlternateScreen)
        case 3:
            activeGrid.removeAll(keepingCapacity: true)
            activeGrid.appendLine()
            cursorRow = 0
            cursorColumn = 0
        default:
            eraseInLine(mode: 0)
            clearRows(in: (cursorRow + 1)..<(screenBottomRow + 1), ensureStorage: false)
        }
    }

    private mutating func eraseInLine(mode: Int) {
        ensureCursorLine()

        var cells = activeGrid.cells(at: cursorRow)
        let columns = max(1, currentViewportSize.columns)
        switch mode {
        case 1:
            let upperBound = currentStyle.paintsBackground
                ? min(cursorColumn + 1, columns)
                : min(cursorColumn + 1, cells.count)
            ensureCellsExist(upTo: upperBound, in: &cells)
            if upperBound > 0 {
                for index in 0..<upperBound {
                    cells[index] = TerminalCell(character: " ", style: currentStyle)
                }
            }
        case 2:
            if currentStyle.paintsBackground {
                cells = blankCells(count: columns)
            } else {
                cells.removeAll(keepingCapacity: true)
            }
            activeGrid.setSoftWrapped(false, at: cursorRow)
        default:
            let upperBound = currentStyle.paintsBackground ? columns : cells.count
            guard cursorColumn < upperBound else {
                activeGrid.setCells(cells, at: cursorRow)
                return
            }

            ensureCellsExist(upTo: upperBound, in: &cells)
            for index in cursorColumn..<upperBound {
                cells[index] = TerminalCell(character: " ", style: currentStyle)
            }
        }

        activeGrid.setCells(cells, at: cursorRow)
    }

    private mutating func clearRows(in range: Range<Int>, ensureStorage: Bool) {
        guard !range.isEmpty else { return }

        let lowerBound = max(0, range.lowerBound)
        let upperBound: Int
        if ensureStorage {
            upperBound = max(lowerBound, range.upperBound)
            if upperBound > lowerBound {
                activeGrid.ensureLine(at: upperBound - 1)
            }
        } else {
            upperBound = min(max(lowerBound, range.upperBound), activeGrid.lineCount)
        }
        guard lowerBound < upperBound else { return }

        for row in lowerBound..<upperBound {
            let cells = currentStyle.paintsBackground ? blankCells(count: currentViewportSize.columns) : []
            activeGrid.setCells(cells, at: row)
            activeGrid.setSoftWrapped(false, at: row)
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard !activeGrid.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var cells = activeGrid.cells(at: cursorRow)
        guard cursorColumn < cells.count else { return }

        let upperBound = min(cursorColumn + count, cells.count)
        cells.removeSubrange(cursorColumn..<upperBound)
        activeGrid.setCells(cells, at: cursorRow)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard !activeGrid.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var cells = activeGrid.cells(at: cursorRow)
        let upperBound = currentStyle.paintsBackground
            ? min(cursorColumn + count, max(1, currentViewportSize.columns))
            : min(cursorColumn + count, cells.count)
        guard cursorColumn < upperBound else { return }

        ensureCellsExist(upTo: upperBound, in: &cells)
        for index in cursorColumn..<upperBound {
            cells[index] = TerminalCell(character: " ", style: currentStyle)
        }
        activeGrid.setCells(cells, at: cursorRow)
    }

    private func blankCells(count: Int) -> [TerminalCell] {
        Array(repeating: TerminalCell(character: " ", style: currentStyle), count: max(0, count))
    }

    private func spacerCell() -> TerminalCell {
        TerminalCell(character: " ", style: currentStyle, isSpacer: true)
    }

    private func blankLineCells() -> [TerminalCell] {
        currentStyle.paintsBackground ? blankCells(count: currentViewportSize.columns) : []
    }

    private func ensureCellsExist(upTo count: Int, in cells: inout [TerminalCell]) {
        guard count > cells.count else { return }
        cells.append(contentsOf: blankCells(count: count - cells.count))
    }

    private mutating func insertCharacters(_ count: Int) {
        guard count > 0 else { return }
        ensureCursorLine()

        let columns = max(1, currentViewportSize.columns)
        guard cursorColumn < columns else { return }

        let insertCount = min(count, columns - cursorColumn)
        var cells = activeGrid.cells(at: cursorRow)
        ensureCellsExist(upTo: cursorColumn, in: &cells)
        cells.insert(contentsOf: blankCells(count: insertCount), at: cursorColumn)
        if cells.count > columns {
            cells.removeSubrange(columns..<cells.count)
        }

        activeGrid.setCells(cells, at: cursorRow)
    }

    private mutating func flushPendingText(preservingIncompleteUTF8: Bool = false) {
        guard !pendingText.isEmpty else { return }

        let flushCount = preservingIncompleteUTF8
            ? Self.completeUTF8PrefixLength(in: pendingText)
            : pendingText.count
        guard flushCount > 0 else { return }

        let text = String(decoding: pendingText.prefix(flushCount), as: UTF8.self)
        pendingText.removeSubrange(0..<flushCount)
        writeText(text)
    }

    private mutating func writeText(_ text: String) {
        for character in text {
            writeCharacter(mappedCharacter(character))
        }
    }

    private mutating func writeCharacter(_ character: Character) {
        ensureCursorLine()

        let columns = max(1, currentViewportSize.columns)
        let rawWidth = max(0, min(2, TerminalTextRun.cellWidth(for: character)))

        if rawWidth == 0 {
            appendZeroWidthCharacter(character)
            return
        }

        let width = min(rawWidth, columns)
        if cursorColumn + width > columns {
            if isWraparoundMode {
                activeGrid.setSoftWrapped(true, at: cursorRow)
                appendNewLine()
            } else {
                cursorColumn = max(0, columns - width)
            }
        }
        let shouldClampAtRightEdge = !isWraparoundMode && cursorColumn + width >= columns

        var cells = activeGrid.cells(at: cursorRow)
        if cursorColumn > cells.count {
            cells.append(contentsOf: repeatElement(TerminalCell(character: " ", style: currentStyle), count: cursorColumn - cells.count))
        }

        ensureCellsExist(upTo: cursorColumn + width, in: &cells)
        clearSplitWideCharacter(at: cursorColumn, in: &cells)
        clearSplitWideCharacter(at: cursorColumn + width, in: &cells)

        cells[cursorColumn] = TerminalCell(character: character, style: currentStyle)
        if width == 2 {
            cells[cursorColumn + 1] = spacerCell()
        }

        if cells.count > columns {
            cells.removeSubrange(columns..<cells.count)
        }

        activeGrid.setCells(cells, at: cursorRow)
        cursorColumn += width
        if shouldClampAtRightEdge {
            cursorColumn = max(0, columns - 1)
        }
        lastWrittenCharacter = character
    }

    private mutating func appendZeroWidthCharacter(_ character: Character) {
        guard !activeGrid.isEmpty else { return }

        var cells = activeGrid.cells(at: cursorRow)
        var index = min(max(cursorColumn - 1, 0), max(0, cells.count - 1))
        while index > 0, cells[index].isSpacer {
            index -= 1
        }

        guard cells.indices.contains(index), !cells[index].isSpacer else { return }

        let combined = String(cells[index].character) + String(character)
        cells[index] = TerminalCell(character: Character(combined), style: cells[index].style)
        activeGrid.setCells(cells, at: cursorRow)
    }

    private func clearSplitWideCharacter(at column: Int, in cells: inout [TerminalCell]) {
        guard cells.indices.contains(column) else { return }

        if cells[column].isSpacer, column > 0 {
            cells[column - 1] = TerminalCell(character: " ", style: cells[column - 1].style)
            cells[column] = TerminalCell(character: " ", style: cells[column].style)
        } else if TerminalTextRun.cellWidth(for: cells[column].character) == 2,
                  cells.indices.contains(column + 1),
                  cells[column + 1].isSpacer {
            cells[column] = TerminalCell(character: " ", style: cells[column].style)
            cells[column + 1] = TerminalCell(character: " ", style: cells[column + 1].style)
        }
    }

    private mutating func repeatPrecedingCharacter(_ count: Int) {
        guard count > 0, let lastWrittenCharacter else { return }
        for _ in 0..<count {
            writeCharacter(lastWrittenCharacter)
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard count > 0 else { return }
        let scrollRegion = absoluteScrollRegion
        guard cursorRow >= scrollRegion.top, cursorRow <= scrollRegion.bottom else { return }
        activeGrid.ensureLine(at: scrollRegion.bottom)

        let amount = min(count, scrollRegion.bottom - cursorRow + 1)
        for _ in 0..<amount {
            activeGrid.insertLine(blankLineCells(), at: cursorRow)
            activeGrid.removeRows(in: (scrollRegion.bottom + 1)..<(scrollRegion.bottom + 2))
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard count > 0 else { return }
        let scrollRegion = absoluteScrollRegion
        guard cursorRow >= scrollRegion.top, cursorRow <= scrollRegion.bottom else { return }
        activeGrid.ensureLine(at: scrollRegion.bottom)

        let amount = min(count, scrollRegion.bottom - cursorRow + 1)
        for _ in 0..<amount {
            activeGrid.removeRows(in: cursorRow..<(cursorRow + 1))
            activeGrid.insertLine(blankLineCells(), at: scrollRegion.bottom)
        }
    }

    private mutating func scrollAreaUp(_ count: Int, top: Int, bottom: Int) {
        guard count > 0, top <= bottom else { return }
        activeGrid.ensureLine(at: bottom)

        let amount = min(count, bottom - top + 1)
        for _ in 0..<amount {
            activeGrid.removeRows(in: top..<(top + 1))
            activeGrid.insertLine(blankLineCells(), at: bottom)
        }
    }

    private mutating func scrollAreaDown(_ count: Int, top: Int, bottom: Int) {
        guard count > 0, top <= bottom else { return }
        activeGrid.ensureLine(at: bottom)

        let amount = min(count, bottom - top + 1)
        for _ in 0..<amount {
            activeGrid.removeRows(in: bottom..<(bottom + 1))
            activeGrid.insertLine(blankLineCells(), at: top)
        }
    }

    private mutating func setGraphicCharset(_ charset: GraphicCharset, for slot: GraphicCharsetSlot) {
        switch slot {
        case .g0:
            g0Charset = charset
        case .g1:
            g1Charset = charset
        case .g2:
            g2Charset = charset
        case .g3:
            g3Charset = charset
        }
    }

    private func mappedCharacter(_ character: Character) -> Character {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return character
        }
        let value = scalar.value
        guard value <= UInt8.max else { return character }

        let mappedScalar: UnicodeScalar?
        switch activeGraphicCharset {
        case .ascii:
            mappedScalar = scalar
        case .british:
            mappedScalar = value == 0x23 ? UnicodeScalar(0x00A3) : scalar
        case .decSpecial:
            mappedScalar = Self.decSpecialGraphicScalar(for: UInt8(value))
        }

        guard let mappedScalar else { return character }
        return Character(mappedScalar)
    }

    private var activeGraphicCharset: GraphicCharset {
        switch activeGraphicCharsetSlot {
        case .g0:
            g0Charset
        case .g1:
            g1Charset
        case .g2:
            g2Charset
        case .g3:
            g3Charset
        }
    }

    private static func decSpecialGraphicScalar(for byte: UInt8) -> UnicodeScalar? {
        let value: Int
        switch byte {
        case 0x60:
            value = 0x25C6
        case 0x61:
            value = 0x2592
        case 0x62:
            value = 0x2409
        case 0x63:
            value = 0x240C
        case 0x64:
            value = 0x240D
        case 0x65:
            value = 0x240A
        case 0x66:
            value = 0x00B0
        case 0x67:
            value = 0x00B1
        case 0x68:
            value = 0x2424
        case 0x69:
            value = 0x240B
        case 0x6A:
            value = 0x2518
        case 0x6B:
            value = 0x2510
        case 0x6C:
            value = 0x250C
        case 0x6D:
            value = 0x2514
        case 0x6E:
            value = 0x253C
        case 0x6F:
            value = 0x23BA
        case 0x70:
            value = 0x23BB
        case 0x71:
            value = 0x2500
        case 0x72:
            value = 0x23BC
        case 0x73:
            value = 0x23BD
        case 0x74:
            value = 0x251C
        case 0x75:
            value = 0x2524
        case 0x76:
            value = 0x2534
        case 0x77:
            value = 0x252C
        case 0x78:
            value = 0x2502
        case 0x79:
            value = 0x2264
        case 0x7A:
            value = 0x2265
        case 0x7B:
            value = 0x03C0
        case 0x7C:
            value = 0x2260
        case 0x7D:
            value = 0x00A3
        case 0x7E:
            value = 0x00B7
        default:
            value = Int(byte)
        }

        return UnicodeScalar(value)
    }

    private mutating func appendNewLine() {
        ensureCursorLine()

        if isScrollRegionActive {
            let scrollRegion = absoluteScrollRegion
            activeGrid.ensureLine(at: scrollRegion.bottom)
            if cursorRow >= scrollRegion.bottom {
                cursorRow = scrollRegionUp(top: scrollRegion.top, bottom: scrollRegion.bottom)
            } else {
                cursorRow = min(cursorRow + 1, screenBottomRow)
                ensureCursorLine()
            }
            cursorColumn = 0
            return
        }

        cursorRow += 1

        if cursorRow == activeGrid.lineCount {
            activeGrid.appendLine()
        }
        cursorColumn = 0
    }

    private mutating func moveCursorRow(by delta: Int) {
        let top = screenTopRow
        let bottom = screenBottomRow
        cursorRow = min(max(cursorRow + delta, top), bottom)
        ensureCursorLine()
    }

    private mutating func moveCursor(toRow row: Int, column: Int) {
        let top = screenTopRow
        cursorRow = min(max(top + max(0, row), top), screenBottomRow)
        ensureCursorLine()
        cursorColumn = max(0, column)
    }

    private mutating func ensureCursorLine() {
        if isUsingAlternateScreen {
            cursorRow = min(max(cursorRow, 0), max(0, currentViewportSize.rows - 1))
        }
        activeGrid.ensureLine(at: cursorRow)
    }

    private mutating func reverseIndex() {
        ensureCursorLine()

        if isScrollRegionActive {
            let scrollRegion = absoluteScrollRegion
            activeGrid.ensureLine(at: scrollRegion.bottom)
            if cursorRow <= scrollRegion.top {
                scrollRegionDown(top: scrollRegion.top, bottom: scrollRegion.bottom)
                cursorRow = scrollRegion.top
            } else {
                cursorRow = max(cursorRow - 1, screenTopRow)
            }
            return
        }

        cursorRow = max(cursorRow - 1, screenTopRow)
    }

    private mutating func scrollRegionUp(top: Int, bottom: Int) -> Int {
        guard top < bottom else { return cursorRow }

        activeGrid.ensureLine(at: bottom)
        if !isUsingAlternateScreen, top == screenTopRow {
            activeGrid.ensureLine(at: screenBottomRow)
            activeGrid.insertLine(at: bottom + 1)
            return bottom + 1
        }

        activeGrid.removeRows(in: top..<(top + 1))
        activeGrid.insertLine(at: bottom)
        return bottom
    }

    private mutating func scrollRegionDown(top: Int, bottom: Int) {
        guard top < bottom else { return }

        activeGrid.ensureLine(at: bottom)
        activeGrid.removeRows(in: bottom..<(bottom + 1))
        activeGrid.insertLine(at: top)
    }

    private mutating func clampCursor() {
        if activeGrid.isEmpty {
            cursorRow = 0
            cursorColumn = 0
            return
        }

        let maximumRow = isUsingAlternateScreen
            ? max(0, currentViewportSize.rows - 1)
            : activeGrid.lineCount - 1
        cursorRow = min(max(cursorRow, 0), maximumRow)
        cursorColumn = max(0, cursorColumn)
        ensureCursorLine()
    }

    private mutating func trimIfNeeded() {
        if isUsingAlternateScreen {
            ensureAlternateScreenRows()
            return
        }

        guard let maxScrollback, activeGrid.lineCount > maxScrollback else { return }
        let removedCount = activeGrid.lineCount - maxScrollback
        activeGrid.trimPrefix(removedCount)
        cursorRow = max(0, cursorRow - removedCount)
    }

    private mutating func ensureAlternateScreenRows() {
        guard isUsingAlternateScreen else { return }

        let rows = max(1, currentViewportSize.rows)
        if activeGrid.lineCount > rows {
            let removedCount = activeGrid.lineCount - rows
            activeGrid.trimPrefix(removedCount)
            cursorRow = max(0, cursorRow - removedCount)
        }
        activeGrid.ensureLine(at: rows - 1)
        cursorRow = min(max(cursorRow, 0), rows - 1)
    }

    private static func plainLine(from text: String) -> [TerminalCell] {
        cells(from: text, style: TerminalTextStyle())
    }

    private static func text(from cells: [TerminalCell], startColumn: Int, endColumn: Int) -> String {
        let lower = max(0, min(startColumn, cells.count))
        let upper = max(lower, min(endColumn, cells.count))
        guard lower < upper else { return "" }
        return cells[lower..<upper]
            .filter { !$0.isSpacer }
            .map(\.character)
            .map(String.init)
            .joined()
    }

    private mutating func cursorPositionReport(viewportSize: TerminalViewportSize) -> Data {
        ensureCursorLine()

        let rows = max(1, viewportSize.rows)
        let columns = max(1, viewportSize.columns)
        let row = min(rows, max(1, cursorRow - screenTopRow + 1))
        let column = min(columns, max(1, cursorColumn + 1))

        return Data("\u{1B}[\(row);\(column)R".utf8)
    }

    private static func normalizedViewportSize(_ viewportSize: TerminalViewportSize) -> TerminalViewportSize {
        TerminalViewportSize(
            columns: max(1, viewportSize.columns),
            rows: max(1, viewportSize.rows)
        )
    }

    private static func completeUTF8PrefixLength(in bytes: [UInt8]) -> Int {
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                index += 1
                continue
            }

            let expectedLength: Int
            switch byte {
            case 0xC2...0xDF:
                expectedLength = 2
            case 0xE0...0xEF:
                expectedLength = 3
            case 0xF0...0xF4:
                expectedLength = 4
            default:
                index += 1
                continue
            }

            guard index + expectedLength <= bytes.count else {
                break
            }

            let continuationRange = (index + 1)..<(index + expectedLength)
            let hasContinuationBytes = continuationRange.allSatisfy { continuationIndex in
                (bytes[continuationIndex] & 0xC0) == 0x80
            }

            index += hasContinuationBytes ? expectedLength : 1
        }

        return index
    }

    fileprivate static func renderedLine(from cells: [TerminalCell]) -> TerminalRenderedLine {
        guard !cells.isEmpty else { return TerminalRenderedLine(runs: []) }

        var runs: [TerminalTextRun] = []
        var currentStyle = cells[0].style
        var buffer = cells[0].isSpacer ? "" : String(cells[0].character)
        var runCellWidth = 1

        for cell in cells.dropFirst() {
            if cell.style == currentStyle {
                if !cell.isSpacer {
                    buffer.append(cell.character)
                }
                runCellWidth += 1
                continue
            }

            runs.append(TerminalTextRun(text: buffer, style: currentStyle, cellWidth: runCellWidth))
            currentStyle = cell.style
            buffer = cell.isSpacer ? "" : String(cell.character)
            runCellWidth = 1
        }

        runs.append(TerminalTextRun(text: buffer, style: currentStyle, cellWidth: runCellWidth))
        return TerminalRenderedLine(runs: runs)
    }

    private static func cells(from text: String, style: TerminalTextStyle) -> [TerminalCell] {
        var cells: [TerminalCell] = []
        for character in text {
            let width = max(0, min(2, TerminalTextRun.cellWidth(for: character)))
            if width == 0, let lastIndex = cells.indices.last, !cells[lastIndex].isSpacer {
                let combined = String(cells[lastIndex].character) + String(character)
                cells[lastIndex] = TerminalCell(character: Character(combined), style: cells[lastIndex].style)
                continue
            }
            guard width > 0 else { continue }

            cells.append(TerminalCell(character: character, style: style))
            if width == 2 {
                cells.append(TerminalCell(character: " ", style: style, isSpacer: true))
            }
        }

        return cells
    }
}

struct LiveTerminalOutputBuffer: TerminalBuffering {
    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case ignoredString
        case charsetDesignation
    }

    private let maxScrollback: Int?
    private let trimSlack: Int
    private static let defaultForegroundColor: (red: UInt8, green: UInt8, blue: UInt8) = (219, 227, 235)
    private static let defaultBackgroundColor: (red: UInt8, green: UInt8, blue: UInt8) = (18, 17, 23)
    private static let maximumOSCBytes = 8_192

    private var completedLines: [String] = []
    private var currentLine = ""
    private var alternateCompletedLines: [String] = []
    private var alternateCurrentLine = ""
    private var parserState = ParserState.ground
    private var controlBuffer: [UInt8] = []
    private var pendingText: [UInt8] = []
    private var escapedStringPendingST = false
    private var isUsingAlternateScreen = false
    private var currentViewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var isApplicationCursorMode = false
    private var isBracketedPasteMode = false
    private var currentMouseState = TerminalMouseState()
    private var cursorRow = 0
    private var cursorColumn = 0
    private var cursorShape = TerminalCursorShape.block
    private var isCursorVisible = true
    private var primaryScreenTopRow: Int?

    init(maxScrollback: Int?) {
        self.maxScrollback = maxScrollback
        trimSlack = max(512, (maxScrollback ?? 4096) / 10)
    }

    var lineCount: Int {
        max(1, activeCompletedLineCount + 1)
    }

    var storedLineCount: Int {
        lineCount
    }

    var cursorState: TerminalCursorState {
        TerminalCursorState(
            row: cursorRow,
            column: cursorColumn,
            shape: cursorShape,
            isVisible: isCursorVisible
        )
    }

    var usesAlternateScreen: Bool {
        isUsingAlternateScreen
    }

    var usesApplicationCursorKeys: Bool {
        isApplicationCursorMode
    }

    var mouseState: TerminalMouseState {
        currentMouseState
    }

    func snapshot(range: Range<Int>) -> [String] {
        range.map { line(at: $0) ?? "" }
    }

    func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        snapshot(range: range).map { line in
            TerminalRenderedLine(runs: [
                TerminalTextRun(text: line, style: TerminalTextStyle())
            ])
        }
    }

    func lineLength(at row: Int) -> Int {
        line(at: row)?.count ?? 0
    }

    func gridPoint(row: Int, column: Int) -> TerminalGridPoint {
        TerminalGridPoint(row: row, column: column)
    }

    func selectedText(in selection: TerminalSelectionRange) -> String {
        let lower = min(selection.anchor.row, selection.extent.row)
        let upper = max(selection.anchor.row, selection.extent.row)
        guard lower <= upper else { return "" }

        return (lower...upper).compactMap { row -> String? in
            guard let line = line(at: row) else { return nil }
            let startColumn: Int
            let endColumn: Int
            if row == selection.anchor.row && row == selection.extent.row {
                startColumn = min(selection.anchor.column, selection.extent.column)
                endColumn = max(selection.anchor.column, selection.extent.column)
            } else if row == selection.anchor.row {
                startColumn = selection.anchor.row < selection.extent.row ? selection.anchor.column : 0
                endColumn = selection.anchor.row < selection.extent.row ? line.count : selection.anchor.column
            } else if row == selection.extent.row {
                startColumn = selection.anchor.row < selection.extent.row ? 0 : selection.extent.column
                endColumn = selection.anchor.row < selection.extent.row ? selection.extent.column : line.count
            } else {
                startColumn = 0
                endColumn = line.count
            }
            return line.substringByCharacterColumns(startColumn..<endColumn)
        }.joined(separator: "\n")
    }

    mutating func clear() {
        completedLines.removeAll(keepingCapacity: false)
        currentLine.removeAll(keepingCapacity: false)
        alternateCompletedLines.removeAll(keepingCapacity: false)
        alternateCurrentLine.removeAll(keepingCapacity: false)
        parserState = .ground
        controlBuffer.removeAll(keepingCapacity: false)
        pendingText.removeAll(keepingCapacity: false)
        escapedStringPendingST = false
        isUsingAlternateScreen = false
        isApplicationCursorMode = false
        isBracketedPasteMode = false
        currentMouseState = TerminalMouseState()
        cursorRow = 0
        cursorColumn = 0
        cursorShape = .block
        isCursorVisible = true
        primaryScreenTopRow = nil
    }

    mutating func resize(to viewportSize: TerminalViewportSize) {
        currentViewportSize = viewportSize
        trimIfNeeded(force: true)
    }

    mutating func appendPlainLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        flushPendingText()
        appendCompletedLines(newLines)
        clearCurrentLine(keepingCapacity: true)
        cursorRow = max(0, lineCount - 1)
        cursorColumn = 0
        trimIfNeeded(force: true)
    }

    @discardableResult
    mutating func ingest(
        _ data: Data,
        viewportSize: TerminalViewportSize = TerminalViewportSize(columns: 120, rows: 32)
    ) -> [Data] {
        guard !data.isEmpty else { return [] }

        currentViewportSize = viewportSize
        var responses: [Data] = []
        if let plainLines = plainCompletedLines(from: data) {
            appendCompletedLines(plainLines)
            clearCurrentLine(keepingCapacity: true)
            cursorRow = activeCompletedLineCount
            cursorColumn = 0
            trimIfNeeded()
            return []
        }

        for byte in data {
            process(byte, responses: &responses)
        }

        flushPendingText(preservingIncompleteUTF8: true)
        trimIfNeeded()
        return responses
    }

    private func line(at row: Int) -> String? {
        if isUsingAlternateScreen {
            if alternateCompletedLines.indices.contains(row) {
                return alternateCompletedLines[row]
            }
            if row == alternateCompletedLines.count {
                return alternateCurrentLine
            }
        } else {
            if completedLines.indices.contains(row) {
                return completedLines[row]
            }
            if row == completedLines.count {
                return currentLine
            }
        }
        return nil
    }

    private func plainCompletedLines(from data: Data) -> [String]? {
        guard case .ground = parserState,
              pendingText.isEmpty,
              activeCurrentLineText.isEmpty,
              cursorColumn == 0,
              data.last == 0x0A
        else { return nil }

        return data.withUnsafeBytes { rawBuffer -> [String]? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else { return [] }

            var lines: [String] = []
            lines.reserveCapacity(max(1, data.count / 80))

            var lineStart = 0
            var index = 0
            while index < bytes.count {
                switch bytes[index] {
                case 0x0A:
                    lines.append(String(
                        decoding: UnsafeBufferPointer(
                            start: baseAddress.advanced(by: lineStart),
                            count: index - lineStart
                        ),
                        as: UTF8.self
                    ))
                    index += 1
                    lineStart = index
                case 0x0D:
                    guard index + 1 < bytes.count, bytes[index + 1] == 0x0A else {
                        return nil
                    }
                    lines.append(String(
                        decoding: UnsafeBufferPointer(
                            start: baseAddress.advanced(by: lineStart),
                            count: index - lineStart
                        ),
                        as: UTF8.self
                    ))
                    index += 2
                    lineStart = index
                case 0x00..<0x20, 0x7F:
                    return nil
                default:
                    index += 1
                }
            }

            guard lineStart == bytes.count else { return nil }
            return lines
        }
    }

    private var activeCompletedLineCount: Int {
        isUsingAlternateScreen ? alternateCompletedLines.count : completedLines.count
    }

    private var activeCurrentLineCount: Int {
        isUsingAlternateScreen ? alternateCurrentLine.count : currentLine.count
    }

    private var activeCurrentLineText: String {
        isUsingAlternateScreen ? alternateCurrentLine : currentLine
    }

    private var viewportRowCount: Int {
        max(1, currentViewportSize.rows)
    }

    private var screenTopRow: Int {
        guard !isUsingAlternateScreen else { return 0 }

        let naturalTopRow = max(0, lineCount - viewportRowCount)
        guard let primaryScreenTopRow else { return naturalTopRow }

        return max(naturalTopRow, max(0, primaryScreenTopRow))
    }

    private var screenBottomRow: Int {
        screenTopRow + viewportRowCount - 1
    }

    private func activeLineText(at row: Int) -> String {
        line(at: row) ?? ""
    }

    private mutating func setActiveLineText(_ line: String, at row: Int) {
        let targetRow = max(0, row)
        ensureActiveLineExists(at: targetRow)

        if isUsingAlternateScreen {
            if targetRow < alternateCompletedLines.count {
                alternateCompletedLines[targetRow] = line
            } else {
                alternateCurrentLine = line
            }
        } else if targetRow < completedLines.count {
            completedLines[targetRow] = line
        } else {
            currentLine = line
        }
    }

    private mutating func ensureActiveLineExists(at row: Int) {
        let targetRow = max(0, row)
        while activeCompletedLineCount < targetRow {
            appendCompletedLine(activeCurrentLineText)
            clearCurrentLine(keepingCapacity: activeCurrentLineCount <= 4_096)
        }
    }

    private mutating func makeActiveLineCurrent(at row: Int) {
        let targetRow = max(0, row)
        ensureActiveLineExists(at: targetRow)
        let line = activeLineText(at: targetRow)

        if isUsingAlternateScreen {
            if targetRow < alternateCompletedLines.count {
                alternateCompletedLines.removeSubrange(targetRow..<alternateCompletedLines.count)
            }
            alternateCurrentLine = line
        } else {
            if targetRow < completedLines.count {
                completedLines.removeSubrange(targetRow..<completedLines.count)
            }
            currentLine = line
        }
    }

    private mutating func appendCompletedLine(_ line: String) {
        if isUsingAlternateScreen {
            alternateCompletedLines.append(line)
        } else {
            completedLines.append(line)
        }
    }

    private mutating func appendCompletedLines(_ lines: [String]) {
        if isUsingAlternateScreen {
            alternateCompletedLines.append(contentsOf: lines)
        } else {
            completedLines.append(contentsOf: lines)
        }
    }

    private mutating func clearActiveCompletedLines(keepingCapacity: Bool) {
        if isUsingAlternateScreen {
            alternateCompletedLines.removeAll(keepingCapacity: keepingCapacity)
        } else {
            completedLines.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    private mutating func clearCurrentLine(keepingCapacity: Bool) {
        if isUsingAlternateScreen {
            alternateCurrentLine.removeAll(keepingCapacity: keepingCapacity)
        } else {
            currentLine.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    private mutating func process(_ byte: UInt8, responses: inout [Data]) {
        switch parserState {
        case .ground:
            processGround(byte)
        case .escape:
            processEscape(byte)
        case .csi:
            processCSI(byte, responses: &responses)
        case .osc:
            processOSC(byte, responses: &responses)
        case .ignoredString:
            processIgnoredString(byte)
        case .charsetDesignation:
            parserState = .ground
        }
    }

    private mutating func processGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            flushPendingText()
            parserState = .escape
        case 0x0A:
            flushPendingText()
            appendNewLine()
        case 0x0D:
            flushPendingText()
            cursorColumn = 0
        case 0x08, 0x7F:
            flushPendingText()
            removeCharacterBeforeCursor()
        case 0x09:
            flushPendingText()
            let spaces = max(1, 8 - (cursorColumn % 8))
            appendText(String(repeating: " ", count: spaces))
        case 0x07, 0x00...0x1F:
            flushPendingText()
        default:
            pendingText.append(byte)
        }
    }

    private mutating func processEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            controlBuffer.removeAll(keepingCapacity: true)
            parserState = .csi
        case UInt8(ascii: "]"):
            controlBuffer.removeAll(keepingCapacity: true)
            escapedStringPendingST = false
            parserState = .osc
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            escapedStringPendingST = false
            parserState = .ignoredString
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            parserState = .charsetDesignation
        case UInt8(ascii: "M"):
            moveCursorRow(by: -1)
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private mutating func processCSI(_ byte: UInt8, responses: inout [Data]) {
        controlBuffer.append(byte)
        guard (0x40...0x7E).contains(byte) else { return }

        let finalByte = byte
        let payload = String(decoding: controlBuffer.dropLast(), as: UTF8.self)
        handleCSI(finalByte: finalByte, payload: payload, responses: &responses)

        controlBuffer.removeAll(keepingCapacity: true)
        parserState = .ground
    }

    private mutating func processOSC(_ byte: UInt8, responses: inout [Data]) {
        if escapedStringPendingST {
            escapedStringPendingST = false
            if byte == UInt8(ascii: "\\") {
                finishOSC(responses: &responses)
                return
            }

            appendOSCByte(0x1B)
        }

        if byte == 0x07 {
            finishOSC(responses: &responses)
        } else if byte == 0x1B {
            escapedStringPendingST = true
        } else {
            appendOSCByte(byte)
        }
    }

    private mutating func appendOSCByte(_ byte: UInt8) {
        guard controlBuffer.count < Self.maximumOSCBytes else { return }
        controlBuffer.append(byte)
    }

    private mutating func finishOSC(responses: inout [Data]) {
        let rawPayload = String(decoding: controlBuffer, as: UTF8.self)
        handleOSC(rawPayload: rawPayload, responses: &responses)

        controlBuffer.removeAll(keepingCapacity: true)
        escapedStringPendingST = false
        parserState = .ground
    }

    private func handleOSC(rawPayload: String, responses: inout [Data]) {
        let fields = rawPayload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, fields[1] == "?" else { return }

        switch fields[0] {
        case "10":
            responses.append(Self.oscColorResponse(code: "10", color: Self.defaultForegroundColor))
        case "11":
            responses.append(Self.oscColorResponse(code: "11", color: Self.defaultBackgroundColor))
        default:
            break
        }
    }

    private static func oscColorResponse(
        code: String,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> Data {
        let payload = "\u{1B}]\(code);rgb:\(hex16(color.red))/\(hex16(color.green))/\(hex16(color.blue))\u{07}"
        return Data(payload.utf8)
    }

    private static func hex16(_ value: UInt8) -> String {
        String(format: "%04x", UInt16(value) * 257)
    }

    private mutating func processIgnoredString(_ byte: UInt8) {
        if escapedStringPendingST {
            escapedStringPendingST = false
            if byte == UInt8(ascii: "\\") {
                parserState = .ground
            } else if byte == 0x1B {
                escapedStringPendingST = true
            }
            return
        }

        if byte == 0x07 {
            parserState = .ground
        } else if byte == 0x1B {
            escapedStringPendingST = true
        }
    }

    private mutating func handleCSI(finalByte: UInt8, payload: String, responses: inout [Data]) {
        let parameters = numericParameters(from: payload)

        func parameter(at index: Int, default fallback: Int) -> Int {
            guard parameters.indices.contains(index), let value = parameters[index] else {
                return fallback
            }
            return value
        }

        switch Character(UnicodeScalar(finalByte)) {
        case "c":
            handleDeviceAttributes(rawPayload: payload, responses: &responses)
        case "n":
            handleDeviceStatusReport(parameter(at: 0, default: 0), responses: &responses)
        case "p":
            handleModeStatusReport(rawPayload: payload, responses: &responses)
        case "h", "l":
            guard payload.first == "?" else { return }
            handlePrivateMode(isSet: finalByte == UInt8(ascii: "h"), parameters: parameters.compactMap { $0 })
        case "u":
            handleCursorRestoreOrKeyboardProtocol(rawPayload: payload, responses: &responses)
        case "q":
            applyCursorShape(parameter(at: 0, default: 0))
        case "A":
            moveCursorRow(by: -parameter(at: 0, default: 1))
        case "B":
            moveCursorRow(by: parameter(at: 0, default: 1))
        case "C":
            cursorColumn += parameter(at: 0, default: 1)
        case "D":
            cursorColumn = max(0, cursorColumn - parameter(at: 0, default: 1))
        case "E":
            moveCursorRow(by: parameter(at: 0, default: 1))
            cursorColumn = 0
        case "F":
            moveCursorRow(by: -parameter(at: 0, default: 1))
            cursorColumn = 0
        case "G":
            cursorColumn = max(0, parameter(at: 0, default: 1) - 1)
        case "H", "f":
            moveCursor(toScreenRow: parameter(at: 0, default: 1) - 1, column: parameter(at: 1, default: 1) - 1)
        case "J":
            eraseInDisplay(mode: parameter(at: 0, default: 0))
        case "K":
            eraseInLine(mode: parameter(at: 0, default: 0))
        default:
            return
        }
    }

    private func handleDeviceAttributes(rawPayload: String, responses: inout [Data]) {
        if rawPayload.first == ">" {
            responses.append(Data("\u{1B}[>0;0;0c".utf8))
            return
        }

        if rawPayload.isEmpty || rawPayload == "0" {
            responses.append(Data("\u{1B}[?1;2c".utf8))
        }
    }

    private mutating func handleCursorRestoreOrKeyboardProtocol(rawPayload: String, responses: inout [Data]) {
        switch rawPayload.first {
        case "?":
            responses.append(Data("\u{1B}[?0u".utf8))
        case ">", "<", "=":
            return
        default:
            return
        }
    }

    private func handleDeviceStatusReport(_ code: Int, responses: inout [Data]) {
        switch code {
        case 5:
            responses.append(Data("\u{1B}[0n".utf8))
        case 6:
            responses.append(cursorPositionReport())
        default:
            return
        }
    }

    private func handleModeStatusReport(rawPayload: String, responses: inout [Data]) {
        guard rawPayload.hasPrefix("?"), rawPayload.hasSuffix("$") else { return }

        let modeText = rawPayload.dropFirst().dropLast()
        guard let mode = Int(modeText) else { return }

        responses.append(Data("\u{1B}[?\(mode);\(privateModeStatus(mode))$y".utf8))
    }

    private func privateModeStatus(_ mode: Int) -> Int {
        switch mode {
        case 1:
            isApplicationCursorMode ? 1 : 2
        case 25:
            isCursorVisible ? 1 : 2
        case 47, 1047, 1049:
            isUsingAlternateScreen ? 1 : 2
        case 69:
            2
        case 1000:
            currentMouseState.trackingMode == .normal ? 1 : 2
        case 1002:
            currentMouseState.trackingMode == .buttonEvent ? 1 : 2
        case 1003:
            currentMouseState.trackingMode == .anyEvent ? 1 : 2
        case 1004:
            currentMouseState.sendsFocusEvents ? 1 : 2
        case 1006:
            currentMouseState.usesSGREncoding ? 1 : 2
        case 1007:
            currentMouseState.alternateScrollMode ? 1 : 2
        case 2004:
            isBracketedPasteMode ? 1 : 2
        case 2026, 2027, 2031, 2048:
            4
        default:
            0
        }
    }

    private func numericParameters(from payload: String) -> [Int?] {
        payload
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { segment -> Int? in
                let digits = segment.filter(\.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }
    }

    private mutating func handlePrivateMode(isSet: Bool, parameters: [Int]) {
        for parameter in parameters {
            switch parameter {
            case 1:
                isApplicationCursorMode = isSet
            case 25:
                isCursorVisible = isSet
            case 47, 1047, 1049:
                if isSet {
                    enterAlternateScreen()
                } else {
                    leaveAlternateScreen()
                }
            case 1000:
                currentMouseState.trackingMode = isSet ? .normal : .disabled
            case 1002:
                currentMouseState.trackingMode = isSet ? .buttonEvent : .disabled
            case 1003:
                currentMouseState.trackingMode = isSet ? .anyEvent : .disabled
            case 1004:
                currentMouseState.sendsFocusEvents = isSet
            case 1006:
                currentMouseState.usesSGREncoding = isSet
            case 1007:
                currentMouseState.alternateScrollMode = isSet
            case 2004:
                isBracketedPasteMode = isSet
            default:
                continue
            }
        }
    }

    private mutating func applyCursorShape(_ code: Int) {
        cursorShape = switch code {
        case 3, 4:
            .underline
        case 5, 6:
            .bar
        default:
            .block
        }
    }

    private mutating func flushPendingText(preservingIncompleteUTF8: Bool = false) {
        guard !pendingText.isEmpty else { return }

        if preservingIncompleteUTF8 {
            var validEnd = pendingText.count
            while validEnd > 0 {
                let candidate = pendingText[..<validEnd]
                if let text = String(bytes: candidate, encoding: .utf8) {
                    appendText(text)
                    pendingText.removeFirst(validEnd)
                    return
                }
                validEnd -= 1
            }
            return
        }

        appendText(String(decoding: pendingText, as: UTF8.self))
        pendingText.removeAll(keepingCapacity: true)
    }

    private mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }

        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)
        if cursorColumn <= 0 {
            if line.isEmpty {
                line = text
            } else {
                line.replaceByCharacterColumns(0..<text.count, with: text)
            }
            setActiveLineText(line, at: cursorRow)
            cursorColumn = text.count
            return
        }

        if cursorColumn >= line.count {
            if cursorColumn > line.count {
                line += String(repeating: " ", count: cursorColumn - line.count)
            }
            line += text
            setActiveLineText(line, at: cursorRow)
            cursorColumn = line.count
            return
        }

        line.replaceByCharacterColumns(cursorColumn..<(cursorColumn + text.count), with: text)
        setActiveLineText(line, at: cursorRow)
        cursorColumn += text.count
    }

    private mutating func appendNewLine() {
        ensureActiveLineExists(at: cursorRow)
        if cursorRow >= activeCompletedLineCount {
            appendCompletedLine(activeCurrentLineText)
            clearCurrentLine(keepingCapacity: activeCurrentLineCount <= 4_096)
            cursorRow = activeCompletedLineCount
        } else {
            cursorRow = min(cursorRow + 1, screenBottomRow)
            ensureActiveLineExists(at: cursorRow)
        }
        cursorColumn = 0
        trimIfNeeded()
    }

    private mutating func removeCharacterBeforeCursor() {
        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)
        guard cursorColumn > 0, !line.isEmpty else { return }
        let removalColumn = cursorColumn - 1
        line.replaceByCharacterColumns(removalColumn..<cursorColumn, with: "")
        setActiveLineText(line, at: cursorRow)
        cursorColumn = removalColumn
    }

    private mutating func moveCursorRow(by delta: Int) {
        let top = screenTopRow
        let bottom = screenBottomRow
        cursorRow = min(max(cursorRow + delta, top), bottom)
        ensureActiveLineExists(at: cursorRow)
    }

    private mutating func moveCursor(toScreenRow row: Int, column: Int) {
        let top = screenTopRow
        let bottom = screenBottomRow
        cursorRow = min(max(top + max(0, row), top), bottom)
        ensureActiveLineExists(at: cursorRow)
        cursorColumn = max(0, column)
    }

    private mutating func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseInLine(mode: 0)
            makeActiveLineCurrent(at: cursorRow)
        case 2 where isUsingAlternateScreen:
            clearActiveCompletedLines(keepingCapacity: false)
            clearCurrentLine(keepingCapacity: false)
            cursorRow = 0
            cursorColumn = 0
        case 2:
            appendCompletedLine(activeCurrentLineText)
            clearCurrentLine(keepingCapacity: activeCurrentLineCount <= 4_096)
            cursorRow = activeCompletedLineCount
            cursorColumn = 0
            primaryScreenTopRow = cursorRow
        case 3:
            clearActiveCompletedLines(keepingCapacity: false)
            clearCurrentLine(keepingCapacity: false)
            cursorRow = 0
            cursorColumn = 0
            primaryScreenTopRow = nil
        default:
            break
        }
    }

    private mutating func eraseInLine(mode: Int) {
        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)

        switch mode {
        case 1:
            let erasedColumnCount = min(max(0, cursorColumn + 1), line.count)
            guard erasedColumnCount > 0 else { return }
            line.replaceByCharacterColumns(0..<erasedColumnCount, with: String(repeating: " ", count: erasedColumnCount))
        case 2:
            line.removeAll(keepingCapacity: line.count <= 4_096)
        default:
            guard cursorColumn < line.count else { return }
            if cursorColumn <= 0 {
                line.removeAll(keepingCapacity: line.count <= 4_096)
            } else {
                line = line.substringByCharacterColumns(0..<cursorColumn)
            }
        }

        setActiveLineText(line, at: cursorRow)
    }

    private mutating func trimIfNeeded(force: Bool = false) {
        if isUsingAlternateScreen {
            let maximumCompletedLines = max(0, currentViewportSize.rows - 1)
            guard alternateCompletedLines.count > maximumCompletedLines else { return }

            let removeCount = alternateCompletedLines.count - maximumCompletedLines
            alternateCompletedLines.removeFirst(removeCount)
            cursorRow = max(0, cursorRow - removeCount)
            return
        }

        guard let maxScrollback, maxScrollback >= 0 else { return }

        let maximumCompletedLines = max(0, maxScrollback - 1)
        let threshold = force ? maximumCompletedLines : maximumCompletedLines + trimSlack
        guard completedLines.count > threshold else { return }

        let removeCount = completedLines.count - maximumCompletedLines
        completedLines.removeFirst(removeCount)
        cursorRow = max(0, cursorRow - removeCount)
        if let screenTopRow = primaryScreenTopRow {
            primaryScreenTopRow = max(0, screenTopRow - removeCount)
        }
    }

    private mutating func enterAlternateScreen() {
        isUsingAlternateScreen = true
        alternateCompletedLines.removeAll(keepingCapacity: false)
        alternateCurrentLine.removeAll(keepingCapacity: false)
        cursorRow = 0
        cursorColumn = 0
    }

    private mutating func leaveAlternateScreen() {
        guard isUsingAlternateScreen else { return }
        alternateCompletedLines.removeAll(keepingCapacity: false)
        alternateCurrentLine.removeAll(keepingCapacity: false)
        isUsingAlternateScreen = false
        cursorRow = max(0, lineCount - 1)
        cursorColumn = activeCurrentLineCount
    }

    private func cursorPositionReport() -> Data {
        let rows = max(1, currentViewportSize.rows)
        let columns = max(1, currentViewportSize.columns)
        let row = min(rows, max(1, cursorRow - screenTopRow + 1))
        let column = min(columns, max(1, cursorColumn + 1))

        return Data("\u{1B}[\(row);\(column)R".utf8)
    }
}

private extension String {
    func substringByCharacterColumns(_ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        guard lower < upper else { return "" }

        let start = index(startIndex, offsetBy: lower)
        let end = index(startIndex, offsetBy: upper)
        return String(self[start..<end])
    }

    mutating func replaceByCharacterColumns(_ range: Range<Int>, with replacement: String) {
        let lower = max(0, min(range.lowerBound, count))
        let upper = max(lower, min(range.upperBound, count))
        let start = index(startIndex, offsetBy: lower)
        let end = index(startIndex, offsetBy: upper)
        replaceSubrange(start..<end, with: replacement)
    }
}
