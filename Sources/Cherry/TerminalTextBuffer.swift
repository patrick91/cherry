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

private struct TerminalCell: Equatable {
    let character: Character
    let style: TerminalTextStyle
}

struct TerminalTextBuffer {
    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case ignoredString
    }

    private let maxScrollback: Int?

    private var lines: [[TerminalCell]] = []
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

    var lineCount: Int {
        max(lines.count, 1)
    }

    var storedLineCount: Int {
        max(lines.count, 1)
    }

    mutating func snapshot(range: Range<Int>) -> [String] {
        styledSnapshot(range: range).map(\.plainText)
    }

    mutating func styledSnapshot(range: Range<Int>) -> [TerminalRenderedLine] {
        guard !lines.isEmpty else { return [TerminalRenderedLine(runs: [])] }

        let lower = max(0, min(range.lowerBound, lines.count))
        let upper = max(lower, min(range.upperBound, lines.count))
        return lines[lower..<upper].map(Self.renderedLine(from:))
    }

    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
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
        if lines.isEmpty {
            lines = newLines.map(Self.plainLine(from:))
        } else {
            lines.append(contentsOf: newLines.map(Self.plainLine(from:)))
        }

        cursorRow = max(0, lines.count - 1)
        cursorColumn = lines.last?.count ?? 0
        trimIfNeeded()
    }

    mutating func ingest(_ data: Data) {
        for byte in data {
            process(byte)
        }

        flushPendingText()
        trimIfNeeded()
        clampCursor()
    }

    private mutating func process(_ byte: UInt8) {
        switch parserState {
        case .ground:
            processGround(byte)
        case .escape:
            processEscape(byte)
        case .csi:
            processCSI(byte)
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
        default:
            parserState = .ground
        }
    }

    private mutating func processCSI(_ byte: UInt8) {
        controlBuffer.append(byte)

        guard (0x40...0x7E).contains(byte) else { return }

        let finalByte = byte
        let payload = Array(controlBuffer.dropLast())
        handleCSI(finalByte: finalByte, payload: payload)

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

    private mutating func handleCSI(finalByte: UInt8, payload: [UInt8]) {
        let rawPayload = String(decoding: payload, as: UTF8.self)
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
        case "h", "l", "s", "u", "n", "q":
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
        guard !lines.isEmpty else { return }
        ensureCursorLine()

        switch mode {
        case 1:
            if cursorRow > 0 {
                for index in 0..<cursorRow {
                    lines[index] = []
                }
            }
            eraseInLine(mode: 1)
        case 2:
            lines = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            eraseInLine(mode: 0)
            if cursorRow + 1 < lines.count {
                lines.removeSubrange((cursorRow + 1)..<lines.count)
            }
        }
    }

    private mutating func eraseInLine(mode: Int) {
        guard !lines.isEmpty else { return }
        ensureCursorLine()

        var cells = lines[cursorRow]
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
            cursorColumn = 0
        default:
            guard cursorColumn < cells.count else {
                lines[cursorRow] = cells
                return
            }

            for index in cursorColumn..<cells.count {
                cells[index] = TerminalCell(character: " ", style: currentStyle)
            }
        }

        lines[cursorRow] = cells
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard !lines.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var cells = lines[cursorRow]
        guard cursorColumn < cells.count else { return }

        let upperBound = min(cursorColumn + count, cells.count)
        cells.removeSubrange(cursorColumn..<upperBound)
        lines[cursorRow] = cells
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard !lines.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var cells = lines[cursorRow]
        guard cursorColumn < cells.count else { return }

        let upperBound = min(cursorColumn + count, cells.count)
        for index in cursorColumn..<upperBound {
            cells[index] = TerminalCell(character: " ", style: currentStyle)
        }
        lines[cursorRow] = cells
    }

    private mutating func flushPendingText() {
        guard !pendingText.isEmpty else { return }

        let text = String(decoding: pendingText, as: UTF8.self)
        pendingText.removeAll(keepingCapacity: true)
        writeText(text)
    }

    private mutating func writeText(_ text: String) {
        ensureCursorLine()

        if cursorColumn == lines[cursorRow].count {
            lines[cursorRow].append(contentsOf: text.map { TerminalCell(character: $0, style: currentStyle) })
            cursorColumn += text.count
            return
        }

        for character in text {
            writeCharacter(character)
        }
    }

    private mutating func writeCharacter(_ character: Character) {
        ensureCursorLine()

        var cells = lines[cursorRow]
        if cursorColumn > cells.count {
            cells.append(contentsOf: repeatElement(TerminalCell(character: " ", style: currentStyle), count: cursorColumn - cells.count))
        }

        let cell = TerminalCell(character: character, style: currentStyle)
        if cursorColumn == cells.count {
            cells.append(cell)
        } else {
            cells[cursorColumn] = cell
        }

        lines[cursorRow] = cells
        cursorColumn += 1
    }

    private mutating func appendNewLine() {
        ensureCursorLine()
        cursorRow += 1
        if cursorRow == lines.count {
            lines.append([])
        }
        cursorColumn = 0
    }

    private mutating func moveCursorRow(by delta: Int) {
        let nextRow = max(0, cursorRow + delta)
        cursorRow = nextRow
        ensureCursorLine()
    }

    private mutating func moveCursor(toRow row: Int, column: Int) {
        cursorRow = max(0, row)
        ensureCursorLine()
        cursorColumn = max(0, column)
    }

    private mutating func ensureCursorLine() {
        if lines.isEmpty {
            lines = [[]]
        }

        if cursorRow >= lines.count {
            lines.append(contentsOf: repeatElement([], count: cursorRow - lines.count + 1))
        }
    }

    private mutating func clampCursor() {
        if lines.isEmpty {
            cursorRow = 0
            cursorColumn = 0
            return
        }

        cursorRow = min(max(cursorRow, 0), lines.count - 1)
        cursorColumn = max(0, cursorColumn)
    }

    private mutating func trimIfNeeded() {
        guard let maxScrollback, lines.count > maxScrollback else { return }
        let removedCount = lines.count - maxScrollback
        lines.removeFirst(removedCount)
        cursorRow = max(0, cursorRow - removedCount)
    }

    private static func plainLine(from text: String) -> [TerminalCell] {
        text.map { TerminalCell(character: $0, style: TerminalTextStyle()) }
    }

    private static func renderedLine(from cells: [TerminalCell]) -> TerminalRenderedLine {
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
