import AppKit
import Combine
import SwiftUI

private let terminalInputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"

struct TerminalSurfaceView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> TerminalScrollView {
        let scrollView = TerminalScrollView()
        scrollView.configure(with: session)
        return scrollView
    }

    func updateNSView(_ nsView: TerminalScrollView, context: Context) {
        nsView.configure(with: session)
    }
}

final class TerminalScrollView: NSScrollView {
    private let canvasView = TerminalCanvasView(frame: .zero)
    private var revisionObserver: AnyCancellable?
    private weak var activeSession: TerminalSession?

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
        documentView = canvasView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with session: TerminalSession) {
        if activeSession !== session {
            activeSession = session
            canvasView.session = session
            canvasView.sendInput = { [weak session] data in
                session?.send(data: data)
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

    private func syncDocumentFrame(scrollToBottomIfPinned: Bool) {
        guard let activeSession else { return }

        let wasPinnedToBottom = isPinnedToBottom
        let targetHeight = max(contentSize.height, canvasView.preferredHeight(for: activeSession))
        canvasView.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, 1), height: targetHeight)
        canvasView.needsDisplay = true
        let viewport = canvasView.viewportSize(for: contentSize)
        activeSession.resize(columns: viewport.columns, rows: viewport.rows)

        guard scrollToBottomIfPinned, wasPinnedToBottom else { return }
        scrollToBottom()
    }

    private var isPinnedToBottom: Bool {
        abs(contentView.bounds.maxY - canvasView.frame.height) < 40
    }

    private func scrollToBottom() {
        let origin = NSPoint(x: 0, y: max(0, canvasView.frame.height - contentSize.height))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func focusScrollViewIfPossible() {
        guard let window else { return }
        guard activeSession?.acceptsInput == true else { return }
        _ = window.makeFirstResponder(self)
    }
}

@MainActor
private final class TerminalCanvasView: NSView, @preconcurrency NSTextInputClient {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    weak var session: TerminalSession?
    var sendInput: ((Data) -> Void)?

    private let lineHeight: CGFloat = 20
    private let topInset: CGFloat = 24
    private let bottomInset: CGFloat = 28
    private let sideInset: CGFloat = 22
    private let backgroundColor = NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)
    private let gridColor = NSColor.white.withAlphaComponent(0.035)
    private let defaultTextColor = NSColor(calibratedRed: 0.83, green: 0.86, blue: 0.90, alpha: 1)
    private let dimTextColor = NSColor(calibratedRed: 0.63, green: 0.67, blue: 0.72, alpha: 1)
    private let errorTextColor = NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.48, alpha: 1)
    private let promptTextColor = NSColor(calibratedRed: 0.52, green: 0.89, blue: 0.60, alpha: 1)
    private let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private lazy var cellWidth = max(7.8, "W".size(withAttributes: [.font: font]).width)
    private var isFocused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var handledCommand = false
    nonisolated(unsafe) private var eventMonitor: Any?

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
    }

    func preferredHeight(for session: TerminalSession) -> CGFloat {
        topInset + bottomInset + (CGFloat(session.lineCount) * lineHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

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

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()

        drawGrid(in: dirtyRect)
        drawFocusStrip(in: dirtyRect)

        guard let session else { return }

        let startingRow = max(0, Int(floor((dirtyRect.minY - topInset) / lineHeight)))
        let endingRow = min(session.lineCount, Int(ceil((dirtyRect.maxY - topInset) / lineHeight)) + 1)

        guard endingRow > startingRow else { return }

        let visibleLines = session.snapshot(range: startingRow..<endingRow)
        for (offset, line) in visibleLines.enumerated() {
            let row = startingRow + offset
            let point = NSPoint(x: sideInset, y: topInset + (CGFloat(row) * lineHeight))
            line.draw(at: point, withAttributes: textAttributes(for: line))
        }
    }

    private func drawGrid(in dirtyRect: NSRect) {
        let path = NSBezierPath()
        let firstLine = Int(floor((dirtyRect.minY - topInset) / lineHeight))
        let lastLine = Int(ceil((dirtyRect.maxY - topInset) / lineHeight))

        for row in max(firstLine, 0)...max(lastLine, 0) {
            let y = topInset + CGFloat(row) * lineHeight + 15
            path.move(to: NSPoint(x: sideInset, y: y))
            path.line(to: NSPoint(x: bounds.width - sideInset, y: y))
        }

        gridColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawFocusStrip(in dirtyRect: NSRect) {
        guard dirtyRect.minX < 10 else { return }

        let stripRect = NSRect(x: 0, y: 0, width: 5, height: bounds.height)
        let path = NSBezierPath(roundedRect: stripRect, xRadius: 4, yRadius: 4)
        let stripColor = session?.tint ?? NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 1)
        stripColor.withAlphaComponent(isFocused ? 0.95 : 0.45).setFill()
        path.fill()
    }

    private func textAttributes(for line: String) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        if line.hasPrefix("$") {
            color = promptTextColor
        } else if line.localizedCaseInsensitiveContains("error") {
            color = errorTextColor
        } else if line.isEmpty {
            color = dimTextColor
        } else if line.hasPrefix("[watch]") || line.hasPrefix("[") {
            color = dimTextColor
        } else {
            color = defaultTextColor
        }

        return [
            .font: font,
            .foregroundColor: color
        ]
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            _ = window.makeFirstResponder(self)
        }

        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            isFocused = true
            needsDisplay = true
        }

        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isFocused = false
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
        needsDisplay = true
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard session?.acceptsInput == true else {
            return false
        }

        if terminalInputDebugEnabled {
            fputs("[keyDown] chars=\(String(describing: event.characters)) charsIgnoringMods=\(String(describing: event.charactersIgnoringModifiers)) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)\n", stderr)
        }

        keyTextAccumulator = []
        handledCommand = false
        defer {
            keyTextAccumulator = nil
            handledCommand = false
        }

        interpretKeyEvents([event])

        if let accumulator = keyTextAccumulator, !accumulator.isEmpty {
            for text in accumulator {
                sendInput?(Data(text.utf8))
            }
            return true
        }

        if handledCommand {
            return true
        }

        if let encoded = encodedInput(for: event) {
            sendInput?(encoded)
            return true
        }

        return false
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
           let mappedSequence = specialSequence(for: scalar.value) {
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

    private func specialSequence(for scalar: UInt32) -> String? {
        switch scalar {
        case UInt32(NSUpArrowFunctionKey):
            "\u{1B}[A"
        case UInt32(NSDownArrowFunctionKey):
            "\u{1B}[B"
        case UInt32(NSRightArrowFunctionKey):
            "\u{1B}[C"
        case UInt32(NSLeftArrowFunctionKey):
            "\u{1B}[D"
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
            sendInput?(sequence)
        }
    }

    private func commandSequence(for selector: Selector) -> Data? {
        switch selector {
        case #selector(insertNewline(_:)):
            return Data("\n".utf8)
        case #selector(insertTab(_:)):
            return Data("\t".utf8)
        case #selector(cancelOperation(_:)):
            return Data([0x03])
        case #selector(deleteBackward(_:)):
            return Data([0x7F])
        case #selector(deleteForward(_:)):
            return Data("\u{1B}[3~".utf8)
        case #selector(moveLeft(_:)):
            return Data("\u{1B}[D".utf8)
        case #selector(moveRight(_:)):
            return Data("\u{1B}[C".utf8)
        case #selector(moveUp(_:)):
            return Data("\u{1B}[A".utf8)
        case #selector(moveDown(_:)):
            return Data("\u{1B}[B".utf8)
        case #selector(moveToBeginningOfLine(_:)):
            return Data([0x01])
        case #selector(moveToEndOfLine(_:)):
            return Data([0x05])
        case #selector(moveWordLeft(_:)):
            return Data("\u{1B}b".utf8)
        case #selector(moveWordRight(_:)):
            return Data("\u{1B}f".utf8)
        case #selector(pageUp(_:)):
            return Data("\u{1B}[5~".utf8)
        case #selector(pageDown(_:)):
            return Data("\u{1B}[6~".utf8)
        default:
            return nil
        }
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
        } else {
            sendInput?(Data(text.utf8))
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
