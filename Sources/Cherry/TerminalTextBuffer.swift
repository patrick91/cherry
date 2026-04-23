import Foundation

enum TerminalANSIColor: Equatable {
    case ansi16(Int)
    case palette256(Int)
    case rgb(UInt8, UInt8, UInt8)
}

struct TerminalTextStyle: Equatable {
    var foreground: TerminalANSIColor? = nil
    var isBold = false
    var isDim = false
}

struct TerminalTextRun: Equatable {
    let text: String
    let style: TerminalTextStyle
}

struct TerminalRenderedLine: Equatable {
    let runs: [TerminalTextRun]

    var plainText: String {
        runs.map(\.text).joined()
    }
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
        return cells[lower..<upper].map(\.character).map(String.init).joined()
    }
}

protocol TerminalBuffering {
    var lineCount: Int { get }
    var storedLineCount: Int { get }

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
        case csi
        case osc
        case ignoredString
    }

    private struct ScreenState {
        var cursorRow: Int
        var cursorColumn: Int
        var style: TerminalTextStyle
    }

    private let maxScrollback: Int?

    private var mainGrid = TerminalPageGrid()
    private var alternateGrid = TerminalPageGrid()
    private var currentViewportSize = TerminalViewportSize(columns: 120, rows: 32)
    private var isUsingAlternateScreen = false
    private var savedCursorState: ScreenState?
    private var cursorRow = 0
    private var cursorColumn = 0
    private var parserState: ParserState = .ground
    private var controlBuffer: [UInt8] = []
    private var pendingText: [UInt8] = []
    private var escapedStringPendingST = false
    private var currentStyle = TerminalTextStyle()

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

    var lineCount: Int {
        let minimumLineCount = isUsingAlternateScreen ? currentViewportSize.rows : 1
        return max(activeGrid.lineCount, minimumLineCount)
    }

    var storedLineCount: Int {
        lineCount
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
        mainGrid.removeAll(keepingCapacity: true)
        alternateGrid.removeAll(keepingCapacity: true)
        isUsingAlternateScreen = false
        savedCursorState = nil
        cursorRow = 0
        cursorColumn = 0
        parserState = .ground
        controlBuffer.removeAll(keepingCapacity: true)
        pendingText.removeAll(keepingCapacity: true)
        escapedStringPendingST = false
        currentStyle = TerminalTextStyle()
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
        case .csi:
            processCSI(byte, viewportSize: viewportSize, responses: &responses)
        case .osc, .ignoredString:
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
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            escapedStringPendingST = false
            parserState = .ignoredString
        case UInt8(ascii: "7"):
            saveCursorState()
            parserState = .ground
        case UInt8(ascii: "8"):
            restoreCursorState()
            parserState = .ground
        default:
            parserState = .ground
        }
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
            applySGR(parameters)
        case "n":
            handleDeviceStatusReport(parameter(at: 0, default: 0), viewportSize: viewportSize, responses: &responses)
        case "h", "l":
            guard isPrivateMode else { return }
            handlePrivateMode(
                isSet: finalByte == UInt8(ascii: "h"),
                parameters: parameters.compactMap { $0 },
                viewportSize: viewportSize
            )
        case "s":
            saveCursorState()
        case "u":
            restoreCursorState()
        case "q":
            return
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
        case "P":
            deleteCharacters(parameter(at: 0, default: 1))
        case "X":
            eraseCharacters(parameter(at: 0, default: 1))
        default:
            return
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
            style: currentStyle
        )
    }

    private mutating func restoreCursorState() {
        guard let savedCursorState else { return }
        cursorRow = savedCursorState.cursorRow
        cursorColumn = savedCursorState.cursorColumn
        currentStyle = savedCursorState.style
        clampCursor()
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
            case 30...37:
                currentStyle.foreground = .ansi16(code - 30)
            case 39:
                currentStyle.foreground = nil
            case 90...97:
                currentStyle.foreground = .ansi16(code - 90 + 8)
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
            }
            return blueIndex
        default:
            return index
        }
    }

    private mutating func eraseInDisplay(mode: Int) {
        guard !activeGrid.isEmpty else { return }
        ensureCursorLine()

        switch mode {
        case 1:
            if cursorRow > 0 {
                for index in 0..<cursorRow {
                    activeGrid.setCells([], at: index)
                    activeGrid.setSoftWrapped(false, at: index)
                }
            }
            eraseInLine(mode: 1)
        case 2:
            activeGrid.removeAll(keepingCapacity: true)
            activeGrid.appendLine()
            cursorRow = 0
            cursorColumn = 0
        default:
            eraseInLine(mode: 0)
            if cursorRow + 1 < activeGrid.lineCount {
                activeGrid.removeRows(in: (cursorRow + 1)..<activeGrid.lineCount)
            }
        }
    }

    private mutating func eraseInLine(mode: Int) {
        guard !activeGrid.isEmpty else { return }
        ensureCursorLine()

        var cells = activeGrid.cells(at: cursorRow)
        switch mode {
        case 1:
            let upperBound = min(cursorColumn + 1, cells.count)
            if upperBound > 0 {
                for index in 0..<upperBound {
                    cells[index] = TerminalCell(character: " ", style: currentStyle)
                }
            }
        case 2:
            cells.removeAll(keepingCapacity: true)
            activeGrid.setSoftWrapped(false, at: cursorRow)
            cursorColumn = 0
        default:
            guard cursorColumn < cells.count else {
                activeGrid.setCells(cells, at: cursorRow)
                return
            }

            for index in cursorColumn..<cells.count {
                cells[index] = TerminalCell(character: " ", style: currentStyle)
            }
        }

        activeGrid.setCells(cells, at: cursorRow)
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
        guard cursorColumn < cells.count else { return }

        let upperBound = min(cursorColumn + count, cells.count)
        for index in cursorColumn..<upperBound {
            cells[index] = TerminalCell(character: " ", style: currentStyle)
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
            writeCharacter(character)
        }
    }

    private mutating func writeCharacter(_ character: Character) {
        ensureCursorLine()

        let columns = max(1, currentViewportSize.columns)
        if cursorColumn >= columns {
            activeGrid.setSoftWrapped(true, at: cursorRow)
            appendNewLine()
        }

        var cells = activeGrid.cells(at: cursorRow)
        if cursorColumn > cells.count {
            cells.append(contentsOf: repeatElement(TerminalCell(character: " ", style: currentStyle), count: cursorColumn - cells.count))
        }

        let cell = TerminalCell(character: character, style: currentStyle)
        if cursorColumn == cells.count {
            cells.append(cell)
        } else {
            cells[cursorColumn] = cell
        }

        activeGrid.setCells(cells, at: cursorRow)
        cursorColumn += 1
    }

    private mutating func appendNewLine() {
        ensureCursorLine()
        cursorRow += 1

        if isUsingAlternateScreen {
            let rows = max(1, currentViewportSize.rows)
            if cursorRow >= rows {
                activeGrid.trimPrefix(cursorRow - rows + 1)
                activeGrid.ensureLine(at: rows - 1)
                cursorRow = rows - 1
            } else {
                activeGrid.ensureLine(at: cursorRow)
            }
            cursorColumn = 0
            return
        }

        if cursorRow == activeGrid.lineCount {
            activeGrid.appendLine()
        }
        cursorColumn = 0
    }

    private mutating func moveCursorRow(by delta: Int) {
        var nextRow = max(0, cursorRow + delta)
        if isUsingAlternateScreen {
            nextRow = min(nextRow, max(0, currentViewportSize.rows - 1))
        }
        cursorRow = nextRow
        ensureCursorLine()
    }

    private mutating func moveCursor(toRow row: Int, column: Int) {
        cursorRow = max(0, row)
        if isUsingAlternateScreen {
            cursorRow = min(cursorRow, max(0, currentViewportSize.rows - 1))
        }
        ensureCursorLine()
        cursorColumn = max(0, column)
    }

    private mutating func ensureCursorLine() {
        if isUsingAlternateScreen {
            cursorRow = min(max(cursorRow, 0), max(0, currentViewportSize.rows - 1))
        }
        activeGrid.ensureLine(at: cursorRow)
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
        text.map { TerminalCell(character: $0, style: TerminalTextStyle()) }
    }

    private static func text(from cells: [TerminalCell], startColumn: Int, endColumn: Int) -> String {
        let lower = max(0, min(startColumn, cells.count))
        let upper = max(lower, min(endColumn, cells.count))
        guard lower < upper else { return "" }
        return cells[lower..<upper].map(\.character).map(String.init).joined()
    }

    private mutating func cursorPositionReport(viewportSize: TerminalViewportSize) -> Data {
        ensureCursorLine()

        let rows = max(1, viewportSize.rows)
        let columns = max(1, viewportSize.columns)
        let screenTopRow = isUsingAlternateScreen ? 0 : max(0, activeGrid.lineCount - rows)
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
        var buffer = String(cells[0].character)

        for cell in cells.dropFirst() {
            if cell.style == currentStyle {
                buffer.append(cell.character)
                continue
            }

            runs.append(TerminalTextRun(text: buffer, style: currentStyle))
            currentStyle = cell.style
            buffer = String(cell.character)
        }

        runs.append(TerminalTextRun(text: buffer, style: currentStyle))
        return TerminalRenderedLine(runs: runs)
    }
}
