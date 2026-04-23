import AppKit
import Combine
import SwiftUI

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
    private let canvasView = TerminalCanvasView()
    private var revisionObserver: AnyCancellable?
    private weak var activeSession: TerminalSession?

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

    private func syncDocumentFrame(scrollToBottomIfPinned: Bool) {
        guard let activeSession else { return }

        let wasPinnedToBottom = isPinnedToBottom
        let targetHeight = max(contentSize.height, canvasView.preferredHeight(for: activeSession))
        canvasView.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, 1), height: targetHeight)
        canvasView.needsDisplay = true

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
}

private final class TerminalCanvasView: NSView {
    override var isFlipped: Bool { true }

    weak var session: TerminalSession?

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

    func preferredHeight(for session: TerminalSession) -> CGFloat {
        topInset + bottomInset + (CGFloat(session.lineCount) * lineHeight)
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
        NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.32, alpha: 0.9).setFill()
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
}
