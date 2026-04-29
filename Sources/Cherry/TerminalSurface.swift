import AppKit
import Combine
import SwiftUI

private let terminalInputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"

enum TerminalInputEncoder {
    private static let maximumScrollStepsPerEvent = 36
    private static let terminalScrollRowsPerLine: CGFloat = 3
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let appKitLeftArrowKeyCode: UInt16 = 0x7B
    private static let appKitRightArrowKeyCode: UInt16 = 0x7C
    private static let appKitDownArrowKeyCode: UInt16 = 0x7D
    private static let appKitUpArrowKeyCode: UInt16 = 0x7E

    static func commandSequence(
        for selector: Selector,
        usesApplicationCursorKeys: Bool = false
    ) -> Data? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return Data("\r".utf8)
        case #selector(NSResponder.insertTab(_:)):
            return Data("\t".utf8)
        case #selector(NSResponder.cancelOperation(_:)):
            return Data([0x03])
        case #selector(NSResponder.deleteBackward(_:)):
            return Data([0x7F])
        case #selector(NSResponder.deleteForward(_:)):
            return Data("\u{1B}[3~".utf8)
        case #selector(NSResponder.moveLeft(_:)):
            return Data(cursorKeySequence(.left, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveRight(_:)):
            return Data(cursorKeySequence(.right, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveUp(_:)):
            return Data(cursorKeySequence(.up, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveDown(_:)):
            return Data(cursorKeySequence(.down, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            return Data([0x01])
        case #selector(NSResponder.moveToEndOfLine(_:)):
            return Data([0x05])
        case #selector(NSResponder.moveWordLeft(_:)):
            return Data("\u{1B}b".utf8)
        case #selector(NSResponder.moveWordRight(_:)):
            return Data("\u{1B}f".utf8)
        case #selector(NSResponder.pageUp(_:)):
            return Data("\u{1B}[5~".utf8)
        case #selector(NSResponder.pageDown(_:)):
            return Data("\u{1B}[6~".utf8)
        default:
            return nil
        }
    }

    enum CursorKey {
        case up
        case down
        case right
        case left
    }

    static func cursorKeySequence(
        _ key: CursorKey,
        usesApplicationCursorKeys: Bool
    ) -> String {
        if usesApplicationCursorKeys {
            return switch key {
            case .up:
                "\u{1B}OA"
            case .down:
                "\u{1B}OB"
            case .right:
                "\u{1B}OC"
            case .left:
                "\u{1B}OD"
            }
        }

        return switch key {
        case .up:
            "\u{1B}[A"
        case .down:
            "\u{1B}[B"
        case .right:
            "\u{1B}[C"
        case .left:
            "\u{1B}[D"
        }
    }

    static func appKitUnmodifiedArrowSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        usesApplicationCursorKeys: Bool
    ) -> Data? {
        guard modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }

        let key: CursorKey
        switch keyCode {
        case appKitLeftArrowKeyCode:
            key = .left
        case appKitRightArrowKeyCode:
            key = .right
        case appKitDownArrowKeyCode:
            key = .down
        case appKitUpArrowKeyCode:
            key = .up
        default:
            return nil
        }

        return Data(cursorKeySequence(key, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
    }

    static func shiftEnterSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEnhancedKeyboardProtocolActive: Bool
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.shift),
              !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              keyCode == returnKeyCode || keyCode == keypadEnterKeyCode
        else {
            return nil
        }

        if isEnhancedKeyboardProtocolActive {
            return Data("\u{1B}[13;2u".utf8)
        }
        return Data("\r".utf8)
    }

    static func pastedTextData(_ text: String) -> Data {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return Data(normalizedText.utf8)
    }

    static func insertedTextData(_ text: String) -> Data? {
        guard !isAppKitFunctionKeyText(text) else { return nil }
        return Data(text.utf8)
    }

    static func isAppKitFunctionKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0xF700 && scalar.value <= 0xF8FF
        }
    }

    static func alternateScreenScrollSequence(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        remainder: inout CGFloat
    ) -> Data? {
        let steps = scrollStepCount(
            deltaY: deltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            lineHeight: lineHeight,
            remainder: &remainder
        )
        guard steps != 0 else { return nil }

        let sequence = steps > 0 ? "\u{1B}[A" : "\u{1B}[B"
        return Data(String(repeating: sequence, count: abs(steps)).utf8)
    }

    static func mouseWheelSequence(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        column: Int,
        row: Int,
        mouseState: TerminalMouseState,
        remainder: inout CGFloat
    ) -> Data? {
        let steps = scrollStepCount(
            deltaY: deltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            lineHeight: lineHeight,
            remainder: &remainder
        )
        guard steps != 0 else { return nil }

        let button = steps > 0 ? 64 : 65
        var data = Data()
        for _ in 0..<abs(steps) {
            if mouseState.usesSGREncoding {
                data.append(Data("\u{1B}[<\(button);\(column);\(row)M".utf8))
            } else if let legacySequence = legacyMouseWheelSequence(button: button, column: column, row: row) {
                data.append(legacySequence)
            }
        }

        return data.isEmpty ? nil : data
    }

    static func mousePosition(
        documentLocation: NSPoint,
        visibleOrigin: NSPoint,
        viewportSize: TerminalViewportSize,
        sideInset: CGFloat,
        topInset: CGFloat,
        cellWidth: CGFloat,
        lineHeight: CGFloat
    ) -> (column: Int, row: Int) {
        let visibleLocation = NSPoint(
            x: documentLocation.x - visibleOrigin.x,
            y: documentLocation.y - visibleOrigin.y
        )
        let rawColumn = Int(floor((visibleLocation.x - sideInset) / cellWidth)) + 1
        let rawRow = Int(floor((visibleLocation.y - topInset) / lineHeight)) + 1

        return (
            column: min(max(rawColumn, 1), viewportSize.columns),
            row: min(max(rawRow, 1), viewportSize.rows)
        )
    }

    static func clampedViewportOffset(
        currentOffset: CGFloat,
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maximumOffset = max(0, documentHeight - viewportHeight)
        let scrollDelta = hasPreciseScrollingDeltas
            ? deltaY
            : deltaY * lineHeight
        let proposedOffset = currentOffset - scrollDelta
        return min(max(proposedOffset, 0), maximumOffset)
    }

    private static func scrollStepCount(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        remainder: inout CGFloat
    ) -> Int {
        guard deltaY != 0 else { return 0 }

        let rawSteps: Int
        if hasPreciseScrollingDeltas {
            let scrollUnit = max(1, lineHeight / terminalScrollRowsPerLine)
            remainder += deltaY / scrollUnit
            rawSteps = Int(remainder.rounded(.towardZero))
            remainder -= CGFloat(rawSteps)
        } else {
            rawSteps = Int((deltaY * terminalScrollRowsPerLine).rounded(.awayFromZero))
        }

        return min(max(rawSteps, -maximumScrollStepsPerEvent), maximumScrollStepsPerEvent)
    }

    private static func legacyMouseWheelSequence(button: Int, column: Int, row: Int) -> Data? {
        guard (1...223).contains(column), (1...223).contains(row) else { return nil }

        return Data([
            0x1B,
            UInt8(ascii: "["),
            UInt8(ascii: "M"),
            UInt8(button + 32),
            UInt8(column + 32),
            UInt8(row + 32)
        ])
    }
}

struct TerminalSurfaceView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var chromeState: ProjectWindowChromeState

    func makeNSView(context: Context) -> GhosttyTerminalContainerView {
        let containerView = GhosttyTerminalContainerView()
        containerView.configure(with: session, colorScheme: context.environment.colorScheme)
        containerView.applySidebarAnimationState(
            isAnimating: chromeState.isSidebarAnimating,
            postAnimationDeltaWidth: chromeState.pendingPostAnimationDelta
        )
        return containerView
    }

    func updateNSView(_ nsView: GhosttyTerminalContainerView, context: Context) {
        nsView.configure(with: session, colorScheme: context.environment.colorScheme)
        nsView.applySidebarAnimationState(
            isAnimating: chromeState.isSidebarAnimating,
            postAnimationDeltaWidth: chromeState.pendingPostAnimationDelta
        )
    }
}

final class TerminalScrollView: NSScrollView {
    private static let bottomPinTolerance: CGFloat = 1

    private struct SessionViewportState {
        var offsetY: CGFloat
        var isFollowingOutput: Bool
    }

    private let canvasView = TerminalCanvasView(frame: .zero)
    private var revisionObserver: AnyCancellable?
    private weak var activeSession: TerminalSession?
    private var viewportStates: [UUID: SessionViewportState] = [:]
    private var pendingRestoredOffsetY: CGFloat?
    private var terminalScrollRemainder: CGFloat = 0
    private var isFollowingOutput = true

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        documentView = canvasView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with session: TerminalSession) {
        if activeSession !== session {
            saveViewportStateForActiveSession()

            activeSession = session
            let restoredState = viewportStates[session.id]
            isFollowingOutput = restoredState?.isFollowingOutput ?? true
            pendingRestoredOffsetY = restoredState?.offsetY
            canvasView.session = session
            canvasView.clearSelection()
            canvasView.sendInput = { [weak self, weak session] data in
                self?.isFollowingOutput = true
                self?.scrollToBottom()
                session?.send(data: data)
            }
            canvasView.sendInterrupt = { [weak session] in
                session?.sendInterrupt()
            }
            revisionObserver = session.$revision.sink { [weak self] _ in
                self?.syncDocumentFrame(scrollToBottomIfPinned: true)
            }
        }

        syncDocumentFrame(scrollToBottomIfPinned: false)
    }

    override func layout() {
        super.layout()
        syncDocumentFrame(scrollToBottomIfPinned: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        DispatchQueue.main.async { [weak self] in
            self?.focusScrollViewIfPossible()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            _ = window.makeFirstResponder(self)
        }

        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        canvasView.setFocused(result)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            canvasView.setFocused(false)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if !canvasView.handleKeyDown(event) {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        resetTerminalScrollRemainderIfNeeded(for: event)

        guard let activeSession else {
            scrollDocument(with: event)
            return
        }

        if activeSession.acceptsInput, activeSession.mouseState.trackingMode.isEnabled {
            let mousePosition = canvasView.terminalMousePosition(for: event)
            if let sequence = TerminalInputEncoder.mouseWheelSequence(
                deltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                lineHeight: canvasView.terminalLineHeight,
                column: mousePosition.column,
                row: mousePosition.row,
                mouseState: activeSession.mouseState,
                remainder: &terminalScrollRemainder
            ) {
                activeSession.send(data: sequence)
            }
            return
        }

        if activeSession.acceptsInput, shouldRouteWheelToCursorKeys(for: activeSession) {
            if let sequence = TerminalInputEncoder.alternateScreenScrollSequence(
                deltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                lineHeight: canvasView.terminalLineHeight,
                remainder: &terminalScrollRemainder
            ) {
                activeSession.send(data: sequence)
            }
            return
        }

        activeSession.deferOutputForUserInteraction()
        if scrollDocument(with: event) {
            isFollowingOutput = isPinnedToBottom
        }
    }

    @objc func copy(_ sender: Any?) {
        if canvasView.copySelectionToPasteboard() {
            return
        }
    }

    @objc func paste(_ sender: Any?) {
        _ = canvasView.pasteFromPasteboard()
    }

    private func syncDocumentFrame(scrollToBottomIfPinned: Bool) {
        guard let activeSession else { return }

        let shouldFollowOutput = isFollowingOutput || (scrollToBottomIfPinned && isPinnedToBottom)
        let targetHeight = max(contentSize.height, canvasView.preferredHeight(for: activeSession))
        canvasView.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, 1), height: targetHeight)
        canvasView.resetCursorBlink()
        canvasView.needsDisplay = true
        let viewport = canvasView.viewportSize(for: contentSize)
        activeSession.resize(columns: viewport.columns, rows: viewport.rows)

        if shouldFollowOutput {
            isFollowingOutput = true
            pendingRestoredOffsetY = nil
            scrollToBottom()
        } else if let pendingRestoredOffsetY {
            self.pendingRestoredOffsetY = nil
            scrollToOffsetY(pendingRestoredOffsetY)
        }
    }

    private var isPinnedToBottom: Bool {
        abs(contentView.bounds.maxY - canvasView.frame.height) <= Self.bottomPinTolerance
    }

    private func scrollToBottom() {
        let origin = NSPoint(x: 0, y: max(0, canvasView.frame.height - contentSize.height))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        saveViewportStateForActiveSession()
    }

    private func scrollToOffsetY(_ offsetY: CGFloat) {
        let maximumOffset = max(0, canvasView.frame.height - contentSize.height)
        let origin = NSPoint(x: 0, y: min(max(offsetY, 0), maximumOffset))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        saveViewportStateForActiveSession()
    }

    @discardableResult
    private func scrollDocument(with event: NSEvent) -> Bool {
        let currentOrigin = contentView.bounds.origin
        let nextY = TerminalInputEncoder.clampedViewportOffset(
            currentOffset: currentOrigin.y,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            lineHeight: canvasView.terminalLineHeight,
            documentHeight: canvasView.frame.height,
            viewportHeight: contentSize.height
        )
        guard nextY != currentOrigin.y else { return false }

        contentView.scroll(to: NSPoint(x: currentOrigin.x, y: nextY))
        reflectScrolledClipView(contentView)
        saveViewportStateForActiveSession()
        return true
    }

    private func saveViewportStateForActiveSession() {
        guard let activeSession else { return }

        viewportStates[activeSession.id] = SessionViewportState(
            offsetY: contentView.bounds.origin.y,
            isFollowingOutput: isFollowingOutput
        )
    }

    private func focusScrollViewIfPossible() {
        guard let window else { return }
        guard activeSession?.acceptsInput == true else { return }
        _ = window.makeFirstResponder(self)
    }

    private func resetTerminalScrollRemainderIfNeeded(for event: NSEvent) {
        if event.phase == .ended || event.phase == .cancelled ||
            event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            terminalScrollRemainder = 0
        }
    }

    private func shouldRouteWheelToCursorKeys(for session: TerminalSession) -> Bool {
        guard session.mouseState.alternateScrollMode else { return false }
        return session.usesAlternateScreen
    }
}

@MainActor
private final class TerminalCanvasView: NSView, @preconcurrency NSTextInputClient {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    weak var session: TerminalSession?
    var sendInput: ((Data) -> Void)?
    var sendInterrupt: (() -> Void)?

    private let lineHeight: CGFloat = 20
    private let topInset: CGFloat = 14
    private let bottomInset: CGFloat = 28
    private let sideInset: CGFloat = 14
    private let backgroundColor = NSColor(calibratedRed: 0.07, green: 0.065, blue: 0.09, alpha: 1)
    private let defaultTextColor = NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.92, alpha: 1)
    private let regularFont = TerminalFontPalette.regular(size: 13.5)
    private let boldFont = TerminalFontPalette.semibold(size: 13.5)
    private let selectionDragThreshold: CGFloat = 3
    private lazy var cellWidth = TerminalFontPalette.cellWidth(for: [regularFont, boldFont])
    private var isFocused = false
    private var selection: TerminalSelectionRange?
    private var selectionAnchor: TerminalGridPoint?
    private var selectionMouseDownPoint: NSPoint?
    private var isSelecting = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var handledCommand = false
    private var isCursorBlinkVisible = true
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var cursorBlinkTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleLocalMouseDown(event) ?? event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        cursorBlinkTimer?.invalidate()
    }

    func preferredHeight(for session: TerminalSession) -> CGFloat {
        topInset + bottomInset + (CGFloat(session.lineCount) * lineHeight)
    }

    var terminalLineHeight: CGFloat {
        lineHeight
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            stopCursorBlink()
            return
        }

        startCursorBlink()

        DispatchQueue.main.async { [weak self] in
            self?.focusSurfaceIfPossible()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.focusSurfaceIfPossible()
        }
    }

    func viewportSize(for contentSize: NSSize) -> TerminalViewportSize {
        let columns = max(40, Int(floor((contentSize.width - (sideInset * 2)) / cellWidth)))
        let rows = max(10, Int(floor((contentSize.height - topInset - bottomInset) / lineHeight)))
        return TerminalViewportSize(columns: columns, rows: rows)
    }

    func terminalMousePosition(for event: NSEvent) -> (column: Int, row: Int) {
        let location = convert(event.locationInWindow, from: nil)
        let scrollView = enclosingScrollView
        let visibleOrigin = scrollView?.contentView.bounds.origin ?? .zero
        return TerminalInputEncoder.mousePosition(
            documentLocation: location,
            visibleOrigin: visibleOrigin,
            viewportSize: viewportSize(for: scrollView?.contentSize ?? bounds.size),
            sideInset: sideInset,
            topInset: topInset,
            cellWidth: cellWidth,
            lineHeight: lineHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        guard let session else { return }

        let startingRow = max(0, Int(floor((dirtyRect.minY - topInset) / lineHeight)))
        let endingRow = min(session.lineCount, Int(ceil((dirtyRect.maxY - topInset) / lineHeight)) + 1)

        guard endingRow > startingRow else { return }

        let visibleLines = session.styledSnapshot(range: startingRow..<endingRow)
        drawBackgrounds(for: visibleLines, startingAt: startingRow)
        drawSelection(in: startingRow..<endingRow)

        for (offset, line) in visibleLines.enumerated() {
            let row = startingRow + offset
            drawLine(line, row: row)
        }

        drawTerminalCursor(
            session.cursorState,
            visibleRows: startingRow..<endingRow,
            visibleLines: visibleLines
        )
    }

    private func drawSelection(in visibleRows: Range<Int>) {
        guard let selection, !selection.isEmpty else { return }

        let columns = viewportSize(for: enclosingScrollView?.contentSize ?? bounds.size).columns
        let fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(isFocused ? 0.42 : 0.28)
        fillColor.setFill()

        for row in visibleRows {
            guard let columnsRange = selectionColumns(for: row, viewportColumns: columns) else { continue }
            let rect = NSRect(
                x: sideInset + (CGFloat(columnsRange.lowerBound) * cellWidth),
                y: topInset + (CGFloat(row) * lineHeight),
                width: max(cellWidth, CGFloat(columnsRange.count) * cellWidth),
                height: lineHeight
            )
            rect.fill()
        }
    }

    private func drawBackgrounds(for lines: [TerminalRenderedLine], startingAt startingRow: Int) {
        for (offset, line) in lines.enumerated() {
            let row = startingRow + offset
            var column = 0

            for run in line.runs {
                let width = run.cellWidth
                defer { column += width }
                guard width > 0,
                      let background = resolvedBackgroundColor(for: run.style) else {
                    continue
                }

                background.setFill()
                NSRect(
                    x: sideInset + (CGFloat(column) * cellWidth),
                    y: topInset + (CGFloat(row) * lineHeight),
                    width: CGFloat(width) * cellWidth,
                    height: lineHeight
                ).fill()
            }
        }
    }

    private func drawLine(_ line: TerminalRenderedLine, row: Int) {
        var column = 0
        for run in line.runs {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: run.style.isBold ? boldFont : regularFont,
                .foregroundColor: resolvedForegroundColor(for: run.style)
            ]

            for character in run.text {
                let point = NSPoint(
                    x: sideInset + (CGFloat(column) * cellWidth),
                    y: topInset + (CGFloat(row) * lineHeight)
                )
                NSAttributedString(string: String(character), attributes: attributes).draw(at: point)
                column += TerminalTextRun.cellWidth(for: character)
            }

            let measuredWidth = run.text.reduce(0) { $0 + TerminalTextRun.cellWidth(for: $1) }
            column += max(0, run.cellWidth - measuredWidth)
        }
    }

    private func resolvedForegroundColor(for style: TerminalTextStyle) -> NSColor {
        let baseColor: NSColor
        if style.isInverse {
            baseColor = style.background?.resolve() ?? backgroundColor
        } else {
            baseColor = switch style.foreground {
            case .none:
                defaultTextColor
            case .some(let color):
                color.resolve() ?? defaultTextColor
            }
        }

        if style.isDim {
            return baseColor.withAlphaComponent(0.72)
        }

        return baseColor
    }

    private func resolvedBackgroundColor(for style: TerminalTextStyle) -> NSColor? {
        if style.isInverse {
            return style.foreground?.resolve() ?? defaultTextColor
        }

        return style.background?.resolve()
    }

    private func drawTerminalCursor(
        _ cursor: TerminalCursorState,
        visibleRows: Range<Int>,
        visibleLines: [TerminalRenderedLine]
    ) {
        guard cursor.isVisible,
              visibleRows.contains(cursor.row),
              !isSelecting else {
            return
        }

        if isFocused, !isCursorBlinkVisible {
            return
        }

        let viewportColumns = viewportSize(for: enclosingScrollView?.contentSize ?? bounds.size).columns
        let column = max(0, min(cursor.column, max(0, viewportColumns - 1)))
        let rect = cursorRect(row: cursor.row, column: column)
        let cursorColor = terminalCursorColor()

        switch cursor.shape {
        case .block:
            drawBlockCursor(
                rect: rect,
                color: cursorColor,
                line: visibleLines[cursor.row - visibleRows.lowerBound],
                column: column
            )
        case .bar:
            drawBarCursor(rect: rect, color: cursorColor)
        case .underline:
            drawUnderlineCursor(rect: rect, color: cursorColor)
        }
    }

    private func cursorRect(row: Int, column: Int) -> NSRect {
        NSRect(
            x: sideInset + (CGFloat(column) * cellWidth),
            y: topInset + (CGFloat(row) * lineHeight),
            width: cellWidth,
            height: lineHeight
        ).integral
    }

    private func terminalCursorColor() -> NSColor {
        let tint = session?.tint ?? NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1)
        return isFocused ? tint.withAlphaComponent(0.96) : defaultTextColor.withAlphaComponent(0.65)
    }

    private func drawBlockCursor(rect: NSRect, color: NSColor, line: TerminalRenderedLine, column: Int) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1.5), xRadius: 2.5, yRadius: 2.5)

        if isFocused {
            color.setFill()
            path.fill()
            drawCursorCharacter(from: line, column: column, at: rect.origin)
        } else {
            color.setStroke()
            path.lineWidth = 1.25
            path.stroke()
        }
    }

    private func drawBarCursor(rect: NSRect, color: NSColor) {
        color.setFill()
        let width: CGFloat = isFocused ? 2.25 : 1.5
        NSRect(x: rect.minX, y: rect.minY + 1.5, width: width, height: rect.height - 3).fill()
    }

    private func drawUnderlineCursor(rect: NSRect, color: NSColor) {
        color.setFill()
        let height: CGFloat = isFocused ? 2.25 : 1.5
        NSRect(x: rect.minX, y: rect.maxY - height - 2, width: rect.width, height: height).fill()
    }

    private func drawCursorCharacter(from line: TerminalRenderedLine, column: Int, at origin: NSPoint) {
        let cell = cursorCell(in: line, column: column)
        guard let character = cell.character else { return }

        let style = cell.style ?? TerminalTextStyle()
        NSAttributedString(
            string: String(character),
            attributes: [
                .font: style.isBold ? boldFont : regularFont,
                .foregroundColor: backgroundColor
            ]
        ).draw(at: origin)
    }

    private func cursorCell(in line: TerminalRenderedLine, column: Int) -> (character: Character?, style: TerminalTextStyle?) {
        guard column >= 0 else { return (nil, nil) }

        var remaining = column
        for run in line.runs {
            for character in run.text {
                if remaining == 0 {
                    return (character, run.style)
                }
                remaining -= TerminalTextRun.cellWidth(for: character)
            }

            if remaining < 0 {
                return (nil, run.style)
            }
        }

        return (nil, nil)
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            _ = window.makeFirstResponder(self)
        }

        let anchor = gridPoint(for: event, rounding: .down)
        selectionAnchor = anchor
        selectionMouseDownPoint = convert(event.locationInWindow, from: nil)
        selection = nil
        isSelecting = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let selectionAnchor,
              let selectionMouseDownPoint else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        if !isSelecting {
            guard location.distance(to: selectionMouseDownPoint) >= selectionDragThreshold else {
                return
            }
            isSelecting = true
        }

        autoscroll(with: event)
        let extent = gridPoint(for: event, rounding: rounding(for: event, from: selectionAnchor))
        let nextSelection = TerminalSelectionRange(anchor: selectionAnchor, extent: extent)
        selection = nextSelection.isEmpty ? nil : nextSelection
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            selectionAnchor = nil
            selectionMouseDownPoint = nil
            isSelecting = false
        }

        guard isSelecting, let selectionAnchor else { return }

        let extent = gridPoint(for: event, rounding: rounding(for: event, from: selectionAnchor))
        let nextSelection = TerminalSelectionRange(anchor: selectionAnchor, extent: extent)
        selection = nextSelection.isEmpty ? nil : nextSelection
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            isFocused = true
            resetCursorBlink()
            needsDisplay = true
        }

        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isFocused = false
            resetCursorBlink()
            needsDisplay = true
        }

        return result
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) {
            super.keyDown(with: event)
        }
    }

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        resetCursorBlink()
        needsDisplay = true
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        needsDisplay = true
    }

    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let selectedText = selectedTextForCopy(), !selectedText.isEmpty else {
            return false
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
        return true
    }

    @objc func copy(_ sender: Any?) {
        _ = copySelectionToPasteboard()
    }

    @discardableResult
    func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard session?.acceptsInput == true,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty else {
            return false
        }

        clearSelection()
        resetCursorBlink()
        sendInput?(TerminalInputEncoder.pastedTextData(text))
        return true
    }

    @objc func paste(_ sender: Any?) {
        _ = pasteFromPasteboard()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if isCopyShortcut(event), copySelectionToPasteboard() {
            return true
        }

        if isPasteShortcut(event), pasteFromPasteboard() {
            return true
        }

        guard let session, session.acceptsInput else {
            return false
        }

        if terminalInputDebugEnabled {
            fputs("[keyDown] chars=\(String(describing: event.characters)) charsIgnoringMods=\(String(describing: event.charactersIgnoringModifiers)) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)\n", stderr)
        }
        resetCursorBlink()

        if let encoded = TerminalInputEncoder.shiftEnterSequence(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isEnhancedKeyboardProtocolActive: session.isEnhancedKeyboardProtocolActive
        ) {
            clearSelection()
            sendInput?(encoded)
            return true
        }

        keyTextAccumulator = []
        handledCommand = false
        defer {
            keyTextAccumulator = nil
            handledCommand = false
        }

        interpretKeyEvents([event])

        if let accumulator = keyTextAccumulator, !accumulator.isEmpty {
            var sentText = false
            for text in accumulator {
                guard let data = TerminalInputEncoder.insertedTextData(text) else { continue }
                if !sentText {
                    clearSelection()
                    sentText = true
                }
                sendInput?(data)
            }
            if sentText {
                return true
            }
        }

        if handledCommand {
            return true
        }

        if let encoded = encodedInput(for: event) {
            clearSelection()
            sendEncodedInput(encoded)
            return true
        }

        return false
    }

    private enum SelectionColumnRounding {
        case down
        case up
    }

    private func selectedTextForCopy() -> String? {
        guard let selection, !selection.isEmpty else { return nil }
        return session?.selectedText(in: selection)
    }

    private func selectionColumns(for row: Int, viewportColumns: Int) -> Range<Int>? {
        guard let selection, !selection.isEmpty else { return nil }

        let normalized = selection.normalized
        guard row >= normalized.start.row, row <= normalized.end.row else { return nil }

        let lower: Int
        let upper: Int
        if normalized.start.row == normalized.end.row {
            lower = normalized.start.column
            upper = normalized.end.column
        } else if row == normalized.start.row {
            lower = normalized.start.column
            upper = viewportColumns
        } else if row == normalized.end.row {
            lower = 0
            upper = normalized.end.column
        } else {
            lower = 0
            upper = viewportColumns
        }

        let visualColumns = max(viewportColumns, session?.lineLength(at: row) ?? 0, 1)
        let clampedLower = max(0, min(lower, visualColumns))
        let clampedUpper = max(clampedLower, min(upper, visualColumns))
        guard clampedUpper > clampedLower else { return nil }
        return clampedLower..<clampedUpper
    }

    private func gridPoint(for event: NSEvent, rounding: SelectionColumnRounding) -> TerminalGridPoint {
        let location = convert(event.locationInWindow, from: nil)
        let rawRow = Int(floor((location.y - topInset) / lineHeight))
        let maxRow = max(0, (session?.lineCount ?? 1) - 1)
        let row = max(0, min(rawRow, maxRow))

        let rawColumn = (location.x - sideInset) / cellWidth
        let roundedColumn = switch rounding {
        case .down:
            Int(floor(rawColumn))
        case .up:
            Int(ceil(rawColumn))
        }
        let viewportColumns = viewportSize(for: enclosingScrollView?.contentSize ?? bounds.size).columns
        let maxColumn = max(viewportColumns, session?.lineLength(at: row) ?? 0)
        let column = max(0, min(roundedColumn, maxColumn))

        return session?.gridPoint(row: row, column: column) ?? TerminalGridPoint(row: row, column: column)
    }

    private func rounding(for event: NSEvent, from anchor: TerminalGridPoint) -> SelectionColumnRounding {
        let location = convert(event.locationInWindow, from: nil)
        let row = Int(floor((location.y - topInset) / lineHeight))
        if row > anchor.row {
            return .up
        }
        if row < anchor.row {
            return .down
        }

        let rawColumn = (location.x - sideInset) / cellWidth
        return rawColumn >= CGFloat(anchor.column) ? .up : .down
    }

    private func isCopyShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return false
        }

        return true
    }

    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return false
        }

        return true
    }

    override func keyUp(with event: NSEvent) {
        // The PTY prototype does not need key-up handling yet.
    }

    private func encodedInput(for event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            return nil
        }

        if modifiers.contains(.control),
           let characters = event.charactersIgnoringModifiers,
           let scalar = characters.unicodeScalars.first,
           let control = controlCharacter(for: scalar) {
            return Data([control])
        }

        if let characters = event.charactersIgnoringModifiers,
           let scalar = characters.unicodeScalars.first,
           let mappedSequence = specialSequence(
               for: scalar.value,
               usesApplicationCursorKeys: session?.usesApplicationCursorKeys ?? false
           ) {
            return Data(mappedSequence.utf8)
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return nil
        }

        return Data(characters.utf8)
    }

    private func controlCharacter(for scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 0x40...0x5F:
            return UInt8(scalar.value - 0x40)
        case 0x61...0x7A:
            return UInt8(scalar.value - 0x60)
        default:
            return nil
        }
    }

    private func specialSequence(
        for scalar: UInt32,
        usesApplicationCursorKeys: Bool
    ) -> String? {
        switch scalar {
        case UInt32(NSUpArrowFunctionKey):
            TerminalInputEncoder.cursorKeySequence(.up, usesApplicationCursorKeys: usesApplicationCursorKeys)
        case UInt32(NSDownArrowFunctionKey):
            TerminalInputEncoder.cursorKeySequence(.down, usesApplicationCursorKeys: usesApplicationCursorKeys)
        case UInt32(NSRightArrowFunctionKey):
            TerminalInputEncoder.cursorKeySequence(.right, usesApplicationCursorKeys: usesApplicationCursorKeys)
        case UInt32(NSLeftArrowFunctionKey):
            TerminalInputEncoder.cursorKeySequence(.left, usesApplicationCursorKeys: usesApplicationCursorKeys)
        case UInt32(NSDeleteFunctionKey):
            "\u{1B}[3~"
        default:
            nil
        }
    }

    override func doCommand(by selector: Selector) {
        if terminalInputDebugEnabled {
            fputs("[doCommand] \(NSStringFromSelector(selector))\n", stderr)
        }
        if let sequence = commandSequence(for: selector) {
            handledCommand = true
            clearSelection()
            sendEncodedInput(sequence)
        }
    }

    private func commandSequence(for selector: Selector) -> Data? {
        TerminalInputEncoder.commandSequence(
            for: selector,
            usesApplicationCursorKeys: session?.usesApplicationCursorKeys ?? false
        )
    }

    private func sendEncodedInput(_ data: Data) {
        if data == Data([0x03]) {
            sendInterrupt?()
            return
        }

        sendInput?(data)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString:
            text = attributed.string
        case let plain as String:
            text = plain
        default:
            return
        }

        if terminalInputDebugEnabled {
            fputs("[insertText] \(text.debugDescription)\n", stderr)
        }

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
        } else if let data = TerminalInputEncoder.insertedTextData(text) {
            clearSelection()
            sendInput?(data)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            markedText = NSMutableAttributedString()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText = NSMutableAttributedString()
        }
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let localRect = NSRect(x: sideInset, y: bounds.height - bottomInset - lineHeight, width: cellWidth, height: lineHeight)
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func focusSurfaceIfPossible() {
        guard let window else { return }
        guard session?.acceptsInput == true else { return }
        _ = window.makeFirstResponder(preferredFirstResponder)
    }

    func resetCursorBlink() {
        isCursorBlinkVisible = true
        needsDisplay = true
    }

    private func startCursorBlink() {
        guard cursorBlinkTimer == nil else { return }

        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCursorBlinkVisible.toggle()
                self.needsDisplay = true
            }
        }
    }

    private func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        isCursorBlinkVisible = true
    }

    private func handleLocalMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return event }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        _ = window.makeFirstResponder(preferredFirstResponder)
        needsDisplay = true
        return event
    }

    private var preferredFirstResponder: NSResponder {
        enclosingScrollView ?? self
    }
}

private extension TerminalANSIColor {
    func resolve() -> NSColor? {
        switch self {
        case .ansi16(let index):
            switch index {
            case 0: return NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.31, alpha: 1)
            case 1: return NSColor(calibratedRed: 0.92, green: 0.37, blue: 0.37, alpha: 1)
            case 2: return NSColor(calibratedRed: 0.58, green: 0.87, blue: 0.54, alpha: 1)
            case 3: return NSColor(calibratedRed: 0.91, green: 0.78, blue: 0.43, alpha: 1)
            case 4: return NSColor(calibratedRed: 0.45, green: 0.68, blue: 0.95, alpha: 1)
            case 5: return NSColor(calibratedRed: 0.84, green: 0.59, blue: 0.95, alpha: 1)
            case 6: return NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.86, alpha: 1)
            case 7: return NSColor(calibratedRed: 0.79, green: 0.82, blue: 0.86, alpha: 1)
            case 8: return NSColor(calibratedRed: 0.38, green: 0.43, blue: 0.48, alpha: 1)
            case 9: return NSColor(calibratedRed: 0.98, green: 0.51, blue: 0.50, alpha: 1)
            case 10: return NSColor(calibratedRed: 0.67, green: 0.95, blue: 0.62, alpha: 1)
            case 11: return NSColor(calibratedRed: 0.98, green: 0.87, blue: 0.52, alpha: 1)
            case 12: return NSColor(calibratedRed: 0.58, green: 0.80, blue: 0.99, alpha: 1)
            case 13: return NSColor(calibratedRed: 0.92, green: 0.69, blue: 0.99, alpha: 1)
            case 14: return NSColor(calibratedRed: 0.57, green: 0.93, blue: 0.95, alpha: 1)
            case 15: return NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1)
            default: return nil
            }
        case .palette256(let index):
            return Self.xterm256Color(index)
        case .rgb(let red, let green, let blue):
            return NSColor(
                calibratedRed: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }
    }

    private static func xterm256Color(_ index: Int) -> NSColor? {
        if index < 16 {
            return TerminalANSIColor.ansi16(index).resolve()
        }

        if (16...231).contains(index) {
            let adjusted = index - 16
            let red = adjusted / 36
            let green = (adjusted / 6) % 6
            let blue = adjusted % 6
            let levels: [CGFloat] = [0, 95.0 / 255.0, 135.0 / 255.0, 175.0 / 255.0, 215.0 / 255.0, 1]
            return NSColor(
                calibratedRed: levels[red],
                green: levels[green],
                blue: levels[blue],
                alpha: 1
            )
        }

        guard (232...255).contains(index) else { return nil }
        let value = CGFloat((index - 232) * 10 + 8) / 255
        return NSColor(calibratedWhite: value, alpha: 1)
    }
}

private extension NSPoint {
    func distance(to other: NSPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
