import Foundation


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

struct TerminalGridPoint: Equatable, Comparable {
    let row: Int
    let column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    static func < (lhs: TerminalGridPoint, rhs: TerminalGridPoint) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }

        return lhs.column < rhs.column
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

protocol TerminalBuffering {
    var lineCount: Int { get }
    var storedLineCount: Int { get }
    var cursorState: TerminalCursorState { get }
    var usesAlternateScreen: Bool { get }
    var usesApplicationCursorKeys: Bool { get }
    var usesBracketedPasteMode: Bool { get }
    var mouseState: TerminalMouseState { get }

    func snapshot(range: Range<Int>) -> [String]
    func lineLength(at row: Int) -> Int
    func gridPoint(row: Int, column: Int) -> TerminalGridPoint
    func selectedText(in selection: TerminalSelectionRange) -> String

    mutating func clear()
    mutating func clearScreenAndScrollbackPreservingState()
    mutating func resize(to viewportSize: TerminalViewportSize)
    mutating func appendPlainLines(_ newLines: [String])

    @discardableResult
    mutating func ingest(_ data: Data, viewportSize: TerminalViewportSize) -> [Data]
}

extension TerminalBuffering {
    mutating func clearScreenAndScrollbackPreservingState() {
        clear()
    }

    @discardableResult
    mutating func ingest(_ data: Data) -> [Data] {
        ingest(data, viewportSize: TerminalViewportSize(columns: 120, rows: 32))
    }
}

private func terminalNumericParameters(from payload: String) -> [Int?] {
    var parameters: [Int?] = []
    parameters.reserveCapacity(4)

    var value: Int?
    var overflowed = false

    func appendParameter() {
        parameters.append(overflowed ? nil : value)
        value = nil
        overflowed = false
    }

    for byte in payload.utf8 {
        if byte == UInt8(ascii: ";") {
            appendParameter()
            continue
        }

        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
            continue
        }

        guard !overflowed else { continue }
        let digit = Int(byte - UInt8(ascii: "0"))
        let current = value ?? 0
        if current > (Int.max - digit) / 10 {
            value = nil
            overflowed = true
        } else {
            value = current * 10 + digit
        }
    }

    appendParameter()
    return parameters
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
    private var primaryScrollRegion: (top: Int, bottom: Int)?
    private var alternateScrollRegion: (top: Int, bottom: Int)?
    private var savedPrimaryCursor: (row: Int, column: Int)?
    private var savedAlternateCursor: (row: Int, column: Int)?
    private var lastPrintedCharacter: Character?

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

    var usesBracketedPasteMode: Bool {
        isBracketedPasteMode
    }

    var mouseState: TerminalMouseState {
        currentMouseState
    }

    func snapshot(range: Range<Int>) -> [String] {
        range.map { line(at: $0) ?? "" }
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
        primaryScrollRegion = nil
        alternateScrollRegion = nil
        savedPrimaryCursor = nil
        savedAlternateCursor = nil
        lastPrintedCharacter = nil
    }

    mutating func clearScreenAndScrollbackPreservingState() {
        let preservedAlternateScreen = isUsingAlternateScreen
        let preservedApplicationCursorMode = isApplicationCursorMode
        let preservedBracketedPasteMode = isBracketedPasteMode
        let preservedMouseState = currentMouseState
        let preservedCursorShape = cursorShape
        let preservedCursorVisibility = isCursorVisible

        clear()

        isUsingAlternateScreen = preservedAlternateScreen
        isApplicationCursorMode = preservedApplicationCursorMode
        isBracketedPasteMode = preservedBracketedPasteMode
        currentMouseState = preservedMouseState
        cursorShape = preservedCursorShape
        isCursorVisible = preservedCursorVisibility
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

    private var activeScrollRegion: (top: Int, bottom: Int)? {
        get {
            isUsingAlternateScreen ? alternateScrollRegion : primaryScrollRegion
        }
        set {
            if isUsingAlternateScreen {
                alternateScrollRegion = newValue
            } else {
                primaryScrollRegion = newValue
            }
        }
    }

    private var scrollBounds: (top: Int, bottom: Int) {
        guard let region = activeScrollRegion else {
            return (screenTopRow, screenBottomRow)
        }

        let top = screenTopRow + min(max(0, region.top), viewportRowCount - 1)
        let bottom = min(screenTopRow + max(0, region.bottom), screenBottomRow)
        guard top <= bottom else { return (screenTopRow, screenBottomRow) }
        return (top, bottom)
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
            lineFeed(resetColumn: true)
        case 0x0D:
            flushPendingText()
            cursorColumn = 0
        case 0x08, 0x7F:
            flushPendingText()
            cursorColumn = max(0, cursorColumn - 1)
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
            reverseIndex()
            parserState = .ground
        case UInt8(ascii: "D"):
            lineFeed(resetColumn: false)
            parserState = .ground
        case UInt8(ascii: "E"):
            lineFeed(resetColumn: true)
            parserState = .ground
        case UInt8(ascii: "7"):
            saveCursor()
            parserState = .ground
        case UInt8(ascii: "8"):
            restoreCursor()
            parserState = .ground
        default:
            parserState = .ground
        }
    }

    private mutating func processCSI(_ byte: UInt8, responses: inout [Data]) {
        controlBuffer.append(byte)
        guard (0x40...0x7E).contains(byte) else { return }

        let finalByte = byte
        let rawPayload = controlBuffer.dropLast()
        if handleFastCSI(finalByte: finalByte, payload: rawPayload) {
            controlBuffer.removeAll(keepingCapacity: true)
            parserState = .ground
            return
        }

        let payload = String(decoding: rawPayload, as: UTF8.self)
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
        case "s":
            guard payload.isEmpty else { return }
            saveCursor()
        case "r":
            guard payload.first != "?" else { return }
            setScrollRegion(top: parameter(at: 0, default: 1), bottom: parameter(at: 1, default: viewportRowCount))
        case "S":
            guard payload.first != "?" else { return }
            scrollRowsUp(top: scrollBounds.top, bottom: scrollBounds.bottom, count: parameter(at: 0, default: 1))
        case "T":
            guard payload.isEmpty || parameters.count == 1 else { return }
            scrollRowsDown(top: scrollBounds.top, bottom: scrollBounds.bottom, count: parameter(at: 0, default: 1))
        case "L":
            insertLines(parameter(at: 0, default: 1))
        case "M":
            deleteLines(parameter(at: 0, default: 1))
        case "P":
            deleteCharacters(parameter(at: 0, default: 1))
        case "@":
            insertBlankCharacters(parameter(at: 0, default: 1))
        case "X":
            eraseCharacters(parameter(at: 0, default: 1))
        case "d":
            moveCursor(toScreenRow: parameter(at: 0, default: 1) - 1, column: cursorColumn)
        case "`":
            cursorColumn = max(0, parameter(at: 0, default: 1) - 1)
        case "b":
            repeatLastPrintedCharacter(parameter(at: 0, default: 1))
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

    private mutating func handleFastCSI(finalByte: UInt8, payload: ArraySlice<UInt8>) -> Bool {
        guard payload.first != UInt8(ascii: "?"),
              payload.first != UInt8(ascii: ">"),
              payload.first != UInt8(ascii: "<"),
              payload.first != UInt8(ascii: "=")
        else {
            return false
        }

        switch finalByte {
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            guard payload.isEmpty || payload.elementsEqual([
                UInt8(ascii: "1"),
                UInt8(ascii: ";"),
                UInt8(ascii: "1")
            ]) else {
                return false
            }
            moveCursor(toScreenRow: 0, column: 0)
            return true
        case UInt8(ascii: "J"):
            guard let mode = singleDigitCSIParameter(payload, default: 0, maximum: 3) else { return false }
            eraseInDisplay(mode: mode)
            return true
        case UInt8(ascii: "K"):
            guard let mode = singleDigitCSIParameter(payload, default: 0, maximum: 2) else { return false }
            eraseInLine(mode: mode)
            return true
        default:
            return false
        }
    }

    private func singleDigitCSIParameter(
        _ payload: ArraySlice<UInt8>,
        default fallback: Int,
        maximum: Int
    ) -> Int? {
        guard !payload.isEmpty else { return fallback }
        guard payload.count == 1,
              let byte = payload.first,
              byte >= UInt8(ascii: "0"),
              byte <= UInt8(ascii: "9")
        else {
            return nil
        }

        let value = Int(byte - UInt8(ascii: "0"))
        return value <= maximum ? value : nil
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
        case nil:
            restoreCursor()
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
        terminalNumericParameters(from: payload)
    }

    private mutating func handlePrivateMode(isSet: Bool, parameters: [Int]) {
        for parameter in parameters {
            switch parameter {
            case 1:
                isApplicationCursorMode = isSet
            case 25:
                isCursorVisible = isSet
            case 47, 1047:
                if isSet {
                    enterAlternateScreen()
                } else {
                    leaveAlternateScreen()
                }
            case 1048:
                if isSet {
                    saveCursor()
                } else {
                    restoreCursor()
                }
            case 1049:
                if isSet {
                    saveCursor()
                    enterAlternateScreen()
                } else if isUsingAlternateScreen {
                    leaveAlternateScreen()
                    restoreCursor()
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

        lastPrintedCharacter = text.last
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

    private mutating func lineFeed(resetColumn: Bool) {
        ensureActiveLineExists(at: cursorRow)
        if resetColumn {
            cursorColumn = 0
        }

        if activeScrollRegion != nil {
            let bounds = scrollBounds
            if cursorRow == bounds.bottom {
                scrollRowsUp(top: bounds.top, bottom: bounds.bottom, count: 1)
            } else if cursorRow < screenBottomRow {
                cursorRow += 1
                ensureActiveLineExists(at: cursorRow)
            }
            trimIfNeeded()
            return
        }

        if cursorRow >= activeCompletedLineCount {
            appendCompletedLine(activeCurrentLineText)
            clearCurrentLine(keepingCapacity: activeCurrentLineCount <= 4_096)
            cursorRow = activeCompletedLineCount
        } else {
            cursorRow = min(cursorRow + 1, screenBottomRow)
            ensureActiveLineExists(at: cursorRow)
        }
        trimIfNeeded()
    }

    private mutating func reverseIndex() {
        ensureActiveLineExists(at: cursorRow)
        let bounds = scrollBounds
        if cursorRow == bounds.top, activeScrollRegion != nil || isUsingAlternateScreen {
            scrollRowsDown(top: bounds.top, bottom: bounds.bottom, count: 1)
            return
        }

        moveCursorRow(by: -1)
    }

    private mutating func setScrollRegion(top: Int, bottom: Int) {
        let maximumRow = viewportRowCount - 1
        let normalizedTop = min(max(top - 1, 0), maximumRow)
        let normalizedBottom = min(max(bottom - 1, 0), maximumRow)
        if normalizedTop == 0, normalizedBottom == maximumRow {
            activeScrollRegion = nil
        } else {
            guard normalizedTop < normalizedBottom else { return }
            activeScrollRegion = (top: normalizedTop, bottom: normalizedBottom)
        }
        moveCursor(toScreenRow: 0, column: 0)
    }

    private mutating func scrollRowsUp(top: Int, bottom: Int, count: Int) {
        guard count > 0, top <= bottom else { return }

        var rows = (top...bottom).map { activeLineText(at: $0) }
        let amount = min(count, rows.count)
        rows.removeFirst(amount)
        rows.append(contentsOf: Array(repeating: "", count: amount))
        replaceRows(rows, startingAt: top)
    }

    private mutating func scrollRowsDown(top: Int, bottom: Int, count: Int) {
        guard count > 0, top <= bottom else { return }

        var rows = (top...bottom).map { activeLineText(at: $0) }
        let amount = min(count, rows.count)
        rows.removeLast(amount)
        rows.insert(contentsOf: Array(repeating: "", count: amount), at: 0)
        replaceRows(rows, startingAt: top)
    }

    private mutating func replaceRows(_ rows: [String], startingAt top: Int) {
        guard !rows.isEmpty else { return }

        ensureActiveLineExists(at: top + rows.count - 1)
        for (offset, text) in rows.enumerated() {
            setActiveLineText(text, at: top + offset)
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard count > 0 else { return }

        let bounds = scrollBounds
        guard cursorRow >= bounds.top, cursorRow <= bounds.bottom else { return }
        scrollRowsDown(top: cursorRow, bottom: bounds.bottom, count: count)
    }

    private mutating func deleteLines(_ count: Int) {
        guard count > 0 else { return }

        let bounds = scrollBounds
        guard cursorRow >= bounds.top, cursorRow <= bounds.bottom else { return }
        scrollRowsUp(top: cursorRow, bottom: bounds.bottom, count: count)
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard count > 0 else { return }

        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)
        guard cursorColumn < line.count else { return }
        line.replaceByCharacterColumns(cursorColumn..<(cursorColumn + count), with: "")
        setActiveLineText(line, at: cursorRow)
    }

    private mutating func insertBlankCharacters(_ count: Int) {
        guard count > 0 else { return }

        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)
        guard cursorColumn < line.count else { return }

        let maximumLength = max(max(1, currentViewportSize.columns), line.count)
        let insertCount = min(count, maximumLength - cursorColumn)
        guard insertCount > 0 else { return }
        line.replaceByCharacterColumns(cursorColumn..<cursorColumn, with: String(repeating: " ", count: insertCount))
        if line.count > maximumLength {
            line = line.substringByCharacterColumns(0..<maximumLength)
        }
        setActiveLineText(line, at: cursorRow)
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard count > 0 else { return }

        ensureActiveLineExists(at: cursorRow)
        var line = activeLineText(at: cursorRow)
        guard cursorColumn < line.count else { return }

        let upperBound = min(cursorColumn + count, line.count)
        line.replaceByCharacterColumns(cursorColumn..<upperBound, with: String(repeating: " ", count: upperBound - cursorColumn))
        setActiveLineText(line, at: cursorRow)
    }

    private mutating func repeatLastPrintedCharacter(_ count: Int) {
        guard count > 0, let lastPrintedCharacter else { return }

        let repeatCount = min(count, max(1, currentViewportSize.columns))
        appendText(String(repeating: String(lastPrintedCharacter), count: repeatCount))
    }

    private mutating func saveCursor() {
        let saved = (row: max(0, cursorRow - screenTopRow), column: max(0, cursorColumn))
        if isUsingAlternateScreen {
            savedAlternateCursor = saved
        } else {
            savedPrimaryCursor = saved
        }
    }

    private mutating func restoreCursor() {
        guard let saved = isUsingAlternateScreen ? savedAlternateCursor : savedPrimaryCursor else { return }
        moveCursor(toScreenRow: saved.row, column: saved.column)
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
            clearRows(in: (cursorRow + 1)..<(screenBottomRow + 1))
        case 1:
            ensureActiveLineExists(at: cursorRow)
            for row in screenTopRow..<cursorRow {
                setActiveLineText("", at: row)
            }
            eraseInLine(mode: 1)
        case 2 where isUsingAlternateScreen:
            clearActiveCompletedLines(keepingCapacity: false)
            clearCurrentLine(keepingCapacity: false)
            cursorRow = 0
            cursorColumn = 0
        case 2:
            let newScreenTop = activeCompletedLineCount + 1
            appendCompletedLine(activeCurrentLineText)
            clearCurrentLine(keepingCapacity: activeCurrentLineCount <= 4_096)
            cursorRow = newScreenTop
            cursorColumn = 0
            primaryScreenTopRow = newScreenTop
            clearRows(in: newScreenTop..<(newScreenTop + viewportRowCount))
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

    private mutating func clearRows(in range: Range<Int>) {
        guard !range.isEmpty else { return }

        ensureActiveLineExists(at: range.upperBound - 1)
        for row in range {
            setActiveLineText("", at: row)
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
        alternateScrollRegion = nil
        savedAlternateCursor = nil
        cursorRow = 0
        cursorColumn = 0
    }

    private mutating func leaveAlternateScreen() {
        guard isUsingAlternateScreen else { return }

        var retainedLines = alternateCompletedLines
        retainedLines.append(alternateCurrentLine)
        while let last = retainedLines.last, last.allSatisfy(\.isWhitespace) {
            retainedLines.removeLast()
        }

        alternateCompletedLines.removeAll(keepingCapacity: false)
        alternateCurrentLine.removeAll(keepingCapacity: false)
        alternateScrollRegion = nil
        savedAlternateCursor = nil
        isUsingAlternateScreen = false

        if !retainedLines.isEmpty {
            if !currentLine.isEmpty {
                completedLines.append(currentLine)
                currentLine.removeAll(keepingCapacity: true)
            }
            completedLines.append(contentsOf: retainedLines)
            trimIfNeeded()
            primaryScreenTopRow = completedLines.count
        }

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
