import AppKit
import SwiftUI

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var themeColors: TerminalThemeColors?
    var maxContentWidth: CGFloat = 740
    var minHorizontalInset: CGFloat = 32
    var verticalInset: CGFloat = 24
    var headerSpacing: CGFloat = 24
    var header: AnyView? = nil
    var bodyFontSize: CGFloat = 13.5
    var useMonospacedFont: Bool = true
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            themeColors: themeColors,
            bodyFontSize: bodyFontSize,
            useMonospacedFont: useMonospacedFont
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        textView.defaultParagraphStyle = Coordinator.defaultParagraphStyle
        textView.typingAttributes = context.coordinator.baseAttributes

        let documentView = MarkdownDocumentView(textView: textView)
        documentView.maxContentWidth = maxContentWidth
        documentView.minHorizontalInset = minHorizontalInset
        documentView.verticalInset = verticalInset
        documentView.headerSpacing = headerSpacing
        documentView.onContentHeightChange = onContentHeightChange
        documentView.autoresizingMask = .width
        documentView.setHeader(rootView: header)

        context.coordinator.textView = textView
        context.coordinator.documentView = documentView
        context.coordinator.applyInsertionPoint(to: textView)
        context.coordinator.applySelectionColors(to: textView)
        context.coordinator.setText(text, in: textView)

        scrollView.documentView = documentView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let documentView = scrollView.documentView as? MarkdownDocumentView else { return }
        documentView.maxContentWidth = maxContentWidth
        documentView.minHorizontalInset = minHorizontalInset
        documentView.verticalInset = verticalInset
        documentView.headerSpacing = headerSpacing
        documentView.onContentHeightChange = onContentHeightChange
        documentView.setHeader(rootView: header)
        documentView.needsLayout = true

        let textView = documentView.textView
        context.coordinator.themeColors = themeColors
        context.coordinator.bodyFontSize = bodyFontSize
        context.coordinator.useMonospacedFont = useMonospacedFont
        textView.typingAttributes = context.coordinator.baseAttributes
        context.coordinator.applyInsertionPoint(to: textView)
        context.coordinator.applySelectionColors(to: textView)
        if textView.string != text {
            context.coordinator.setText(text, in: textView)
        } else {
            context.coordinator.applyHighlighting(to: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        weak var documentView: MarkdownDocumentView?
        var themeColors: TerminalThemeColors?
        var bodyFontSize: CGFloat
        var useMonospacedFont: Bool
        private var isApplyingText = false

        init(
            text: Binding<String>,
            themeColors: TerminalThemeColors?,
            bodyFontSize: CGFloat,
            useMonospacedFont: Bool
        ) {
            _text = text
            self.themeColors = themeColors
            self.bodyFontSize = bodyFontSize
            self.useMonospacedFont = useMonospacedFont
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText,
                  let textView = notification.object as? NSTextView
            else { return }
            text = textView.string
            applyHighlighting(to: textView)
            scrollSelectionIntoView(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            scrollSelectionIntoView(in: textView)
        }

        private func scrollSelectionIntoView(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let documentView,
                  let scrollView = textView.enclosingScrollView
            else { return }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }
            layoutManager.ensureLayout(forCharacterRange: selection)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let origin = textView.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            if rect.size.width < 1 { rect.size.width = 1 }
            let rectInDocument = textView.convert(rect, to: documentView)

            let clipView = scrollView.contentView
            let visible = clipView.documentVisibleRect
            let padding: CGFloat = 12
            var targetY = clipView.bounds.origin.y
            if rectInDocument.minY - padding < visible.minY {
                targetY = max(0, rectInDocument.minY - padding)
            } else if rectInDocument.maxY + padding > visible.maxY {
                targetY = rectInDocument.maxY + padding - visible.height
                let maxY = max(0, documentView.bounds.height - visible.height)
                targetY = min(targetY, maxY)
            } else {
                return
            }
            let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: targetY)
            if abs(targetOrigin.y - clipView.bounds.origin.y) < 0.5 { return }
            clipView.setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }

        func setText(_ value: String, in textView: NSTextView) {
            isApplyingText = true
            textView.string = value
            isApplyingText = false
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributes(baseAttributes, range: fullRange)
            applyPatterns(to: storage, text: text)
            storage?.endEditing()
            textView.selectedRanges = selectedRanges
        }

        func applyInsertionPoint(to textView: NSTextView) {
            textView.insertionPointColor = foregroundColor
        }

        func applySelectionColors(to textView: NSTextView) {
            guard let hex = themeColors?.selectionBackground,
                  let color = NSColor(hexRGB: hex)
            else {
                textView.selectedTextAttributes = [
                    .backgroundColor: NSColor.selectedTextBackgroundColor,
                    .foregroundColor: NSColor.selectedTextColor
                ]
                return
            }
            textView.selectedTextAttributes = [
                .backgroundColor: color,
                .foregroundColor: foregroundColor
            ]
        }

        private var foregroundColor: NSColor {
            themeColors.flatMap { NSColor(hexRGB: $0.foreground) } ?? .labelColor
        }

        private func paletteColor(_ index: Int) -> NSColor? {
            guard let hex = themeColors?.palette[index] else { return nil }
            return NSColor(hexRGB: hex)
        }

        static let defaultParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.4
            style.paragraphSpacing = 4
            return style
        }()

        static let headingParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.2
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 6
            return style
        }()

        static let codeBlockParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.25
            style.paragraphSpacing = 6
            return style
        }()

        var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: bodyFont(weight: .regular),
                .foregroundColor: foregroundColor,
                .kern: 0.1,
                .paragraphStyle: Coordinator.defaultParagraphStyle
            ]
        }

        private func bodyFont(weight: NSFont.Weight) -> NSFont {
            if useMonospacedFont {
                return NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: weight)
            }
            return NSFont.systemFont(ofSize: bodyFontSize, weight: weight)
        }

        private func headingFont(size: CGFloat) -> NSFont {
            if useMonospacedFont {
                return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            }
            return NSFont.systemFont(ofSize: size, weight: .semibold)
        }

        private func codeFont(weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: weight)
        }

        private func headingAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
            [
                .font: headingFont(size: size),
                .foregroundColor: color,
                .paragraphStyle: Coordinator.headingParagraphStyle
            ]
        }

        private func applyPatterns(to storage: NSTextStorage?, text: String) {
            guard let storage else { return }
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            let headingColor = paletteColor(12) ?? paletteColor(4) ?? .systemPurple
            let codeColor = paletteColor(11) ?? paletteColor(3) ?? .systemOrange
            let linkColor = paletteColor(4) ?? paletteColor(12) ?? .linkColor
            let markerColor = foregroundColor.withAlphaComponent(0.42)
            let quoteColor = foregroundColor.withAlphaComponent(0.62)

            struct Rule {
                let pattern: String
                let captureGroup: Int
                let attributes: [NSAttributedString.Key: Any]
            }

            let h1Size = bodyFontSize * 1.55
            let h2Size = bodyFontSize * 1.32
            let h3Size = bodyFontSize * 1.15
            let h4Size = bodyFontSize

            let rules: [Rule] = [
                Rule(pattern: #"(?m)^#\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h1Size, color: headingColor)),
                Rule(pattern: #"(?m)^##\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h2Size, color: headingColor)),
                Rule(pattern: #"(?m)^###\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h3Size, color: headingColor)),
                Rule(pattern: #"(?m)^#{4,6}\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h4Size, color: headingColor)),
                Rule(pattern: #"(?m)^>\s?.*$"#, captureGroup: 0, attributes: [.foregroundColor: quoteColor, .obliqueness: 0.12]),
                Rule(pattern: #"(?m)^\s*([-*+])(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"(?m)^\s*(\d+\.)(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"(?m)^\s*[-*+]\s+(\[[ xX]\])"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"`[^`\n]+`"#, captureGroup: 0, attributes: [.foregroundColor: codeColor, .font: codeFont()]),
                Rule(pattern: #"(?m)^```[\s\S]*?^```"#, captureGroup: 0, attributes: [.foregroundColor: codeColor, .font: codeFont(), .paragraphStyle: Coordinator.codeBlockParagraphStyle]),
                Rule(pattern: #"\[[^\]\n]+\]\([^\)\n]+\)"#, captureGroup: 0, attributes: [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]),
                Rule(pattern: #"(\*\*|__)[^\n]+?(\*\*|__)"#, captureGroup: 0, attributes: [.font: bodyFont(weight: .semibold)]),
                Rule(pattern: #"(?<!\*)\*[^\n*]+?\*(?!\*)"#, captureGroup: 0, attributes: [.obliqueness: 0.16])
            ]

            for rule in rules {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                for match in regex.matches(in: text, range: fullRange) {
                    let range = match.range(at: rule.captureGroup)
                    guard range.location != NSNotFound else { continue }
                    storage.addAttributes(rule.attributes, range: range)
                }
            }
        }
    }
}

final class MarkdownDocumentView: NSView {
    let textView: NSTextView
    private var headerHost: NSHostingView<AnyView>?
    private var lastReportedContentHeight: CGFloat = 0

    var maxContentWidth: CGFloat = 740
    var minHorizontalInset: CGFloat = 32
    var verticalInset: CGFloat = 24
    var headerSpacing: CGFloat = 24
    var onContentHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setHeader(rootView: AnyView?) {
        if let rootView {
            if let host = headerHost {
                host.rootView = rootView
            } else {
                let host = NSHostingView(rootView: rootView)
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                headerHost = host
            }
        } else if let host = headerHost {
            host.removeFromSuperview()
            headerHost = nil
        }
        needsLayout = true
    }

    @objc private func textViewFrameChanged() {
        adjustHeightToContent()
    }

    override func layout() {
        super.layout()
        let availableWidth = bounds.width
        let horizontal = max(minHorizontalInset, (availableWidth - maxContentWidth) / 2)
        let contentWidth = max(0, availableWidth - horizontal * 2)

        var y: CGFloat = verticalInset

        if let host = headerHost {
            if host.frame.size.width != contentWidth {
                host.frame.size.width = contentWidth
            }
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            host.frame = NSRect(x: horizontal, y: y, width: contentWidth, height: height)
            y = host.frame.maxY + headerSpacing
        }

        if textView.frame.origin.x != horizontal || textView.frame.origin.y != y {
            textView.frame.origin = NSPoint(x: horizontal, y: y)
        }
        if textView.frame.size.width != contentWidth {
            textView.frame.size.width = contentWidth
        }

        adjustHeightToContent()
    }

    private func adjustHeightToContent() {
        let bottom = textView.frame.maxY + verticalInset
        let scrollHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let target = max(bottom, scrollHeight)
        if abs(frame.size.height - target) > 0.5 {
            setFrameSize(NSSize(width: frame.size.width, height: target))
        }
        if abs(bottom - lastReportedContentHeight) > 0.5 {
            lastReportedContentHeight = bottom
            if let callback = onContentHeightChange {
                DispatchQueue.main.async {
                    callback(bottom)
                }
            }
        }
    }
}
