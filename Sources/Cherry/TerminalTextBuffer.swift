import Foundation

struct TerminalTextBuffer {
    private enum ParserState {
        case ground
        case escape
        case csi
        case osc
        case ignoredString
    }

    private let maxScrollback: Int?

    private var lines: [String] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var parserState: ParserState = .ground
    private var controlBuffer: [UInt8] = []
    private var pendingText: [UInt8] = []
    private var escapedStringPendingST = false

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
        guard !lines.isEmpty else { return [""] }

        let lower = max(0, min(range.lowerBound, lines.count))
        let upper = max(lower, min(range.upperBound, lines.count))
        return Array(lines[lower..<upper])
    }

    mutating func clear() {
        lines.removeAll(keepingCapacity: true)
        cursorRow = 0
        cursorColumn = 0
        parserState = .ground
        controlBuffer.removeAll(keepingCapacity: true)
        pendingText.removeAll(keepingCapacity: true)
        escapedStringPendingST = false
    }

    mutating func appendPlainLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }

        flushPendingText()
        if lines.isEmpty {
            lines = newLines
        } else {
            lines.append(contentsOf: newLines)
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
        case "m", "h", "l", "s", "u", "n", "q":
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

    private mutating func eraseInDisplay(mode: Int) {
        guard !lines.isEmpty else { return }
        ensureCursorLine()

        switch mode {
        case 1:
            if cursorRow > 0 {
                for index in 0..<cursorRow {
                    lines[index] = ""
                }
            }
            eraseInLine(mode: 1)
        case 2:
            lines = [""]
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

        var characters = Array(lines[cursorRow])
        switch mode {
        case 1:
            let upperBound = min(cursorColumn + 1, characters.count)
            if upperBound > 0 {
                for index in 0..<upperBound {
                    characters[index] = " "
                }
            }
        case 2:
            characters.removeAll(keepingCapacity: true)
            cursorColumn = 0
        default:
            guard cursorColumn < characters.count else {
                lines[cursorRow] = String(characters)
                return
            }

            for index in cursorColumn..<characters.count {
                characters[index] = " "
            }
        }

        lines[cursorRow] = String(characters)
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard !lines.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var characters = Array(lines[cursorRow])
        guard cursorColumn < characters.count else { return }

        let upperBound = min(cursorColumn + count, characters.count)
        characters.removeSubrange(cursorColumn..<upperBound)
        lines[cursorRow] = String(characters)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard !lines.isEmpty, count > 0 else { return }
        ensureCursorLine()

        var characters = Array(lines[cursorRow])
        guard cursorColumn < characters.count else { return }

        let upperBound = min(cursorColumn + count, characters.count)
        for index in cursorColumn..<upperBound {
            characters[index] = " "
        }
        lines[cursorRow] = String(characters)
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
            lines[cursorRow].append(text)
            cursorColumn += text.count
            return
        }

        for character in text {
            writeCharacter(character)
        }
    }

    private mutating func writeCharacter(_ character: Character) {
        ensureCursorLine()

        var characters = Array(lines[cursorRow])
        if cursorColumn > characters.count {
            characters.append(contentsOf: repeatElement(" ", count: cursorColumn - characters.count))
        }

        if cursorColumn == characters.count {
            characters.append(character)
        } else {
            characters[cursorColumn] = character
        }

        lines[cursorRow] = String(characters)
        cursorColumn += 1
    }

    private mutating func appendNewLine() {
        ensureCursorLine()
        cursorRow += 1
        if cursorRow == lines.count {
            lines.append("")
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
            lines = [""]
        }

        if cursorRow >= lines.count {
            lines.append(contentsOf: repeatElement("", count: cursorRow - lines.count + 1))
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
}
