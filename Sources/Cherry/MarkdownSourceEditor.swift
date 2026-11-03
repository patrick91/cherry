import AppKit
import CherryControl
import SwiftUI

/// Markdown source with terminal-palette colors in a centered column (the
/// to-do inspector's details).
struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var themeColors: TerminalThemeColors?
    var maxContentWidth: CGFloat = 740
    var minHorizontalInset: CGFloat = 32
    var verticalInset: CGFloat = 24
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, themeColors: themeColors)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // The pane sits under the transparent titlebar; without this AppKit pads
        // the content down by the titlebar height.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
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
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.defaultParagraphStyle = context.coordinator.bodyParagraphStyle
        textView.typingAttributes = context.coordinator.baseAttributes

        let documentView = MarkdownDocumentView(textView: textView)
        documentView.maxContentWidth = maxContentWidth
        documentView.minHorizontalInset = minHorizontalInset
        documentView.verticalInset = verticalInset
        documentView.onContentHeightChange = onContentHeightChange
        documentView.autoresizingMask = .width

        context.coordinator.textView = textView
        context.coordinator.documentView = documentView
        context.coordinator.appliedAppearance = Coordinator.Appearance(themeColors: themeColors)
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
        documentView.onContentHeightChange = onContentHeightChange
        documentView.needsLayout = true

        let textView = documentView.textView
        let coordinator = context.coordinator
        let appearance = Coordinator.Appearance(themeColors: themeColors)
        let appearanceChanged = coordinator.appliedAppearance != appearance
        coordinator.themeColors = themeColors
        if appearanceChanged {
            coordinator.appliedAppearance = appearance
            textView.defaultParagraphStyle = coordinator.bodyParagraphStyle
            textView.typingAttributes = coordinator.baseAttributes
            coordinator.applyInsertionPoint(to: textView)
            coordinator.applySelectionColors(to: textView)
        }
        if textView.string != text {
            coordinator.setText(text, in: textView)
        } else if appearanceChanged {
            // Unrelated SwiftUI updates (e.g. typing in the to-do's title) must not
            // re-highlight the whole document: that repaints everything and flashes.
            coordinator.applyHighlighting(to: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        weak var documentView: MarkdownDocumentView?
        var themeColors: TerminalThemeColors?
        private var isApplyingText = false
        private let bodyFontSize: CGFloat = 15

        /// Everything that feeds into highlighting; re-highlight only when it changes.
        struct Appearance: Equatable {
            var themeColors: TerminalThemeColors?
        }
        var appliedAppearance: Appearance?

        init(text: Binding<String>, themeColors: TerminalThemeColors?) {
            _text = text
            self.themeColors = themeColors
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

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let value = link as? URL {
                url = value
            } else if let value = link as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }

        private func scrollSelectionIntoView(in textView: NSTextView) {
            // Only follow the caret while the body is being edited. Re-highlighting on
            // unrelated SwiftUI updates (e.g. typing in the to-do's title) re-sets the
            // selection and would otherwise yank the scroll position to the caret.
            guard textView.window?.firstResponder === textView else { return }
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

        var bodyParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.4
            paragraph.paragraphSpacing = 4
            return paragraph
        }

        private var headingParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.2
            paragraph.paragraphSpacingBefore = 10
            paragraph.paragraphSpacing = 6
            return paragraph
        }

        private var codeBlockParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.25
            paragraph.paragraphSpacing = 6
            return paragraph
        }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: bodyFont(weight: .regular),
                .foregroundColor: foregroundColor,
                .kern: 0.1,
                .paragraphStyle: bodyParagraphStyle
            ]
        }

        private func bodyFont(weight: NSFont.Weight) -> NSFont {
            NSFont.systemFont(ofSize: bodyFontSize, weight: weight)
        }

        private func headingFont(size: CGFloat) -> NSFont {
            NSFont.systemFont(ofSize: size, weight: .semibold)
        }

        private func codeFont(weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: weight)
        }

        private func headingAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
            [
                .font: headingFont(size: size),
                .foregroundColor: color,
                .paragraphStyle: headingParagraphStyle
            ]
        }

        private struct Rule {
            let pattern: String
            let captureGroup: Int
            let attributes: [NSAttributedString.Key: Any]
            let skipsFencedCode: Bool

            init(
                pattern: String,
                captureGroup: Int,
                attributes: [NSAttributedString.Key: Any],
                skipsFencedCode: Bool = true
            ) {
                self.pattern = pattern
                self.captureGroup = captureGroup
                self.attributes = attributes
                self.skipsFencedCode = skipsFencedCode
            }
        }

        private static let linkPattern = #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#
        private static let bareURLPattern = #"(?<![\w/])(?:https?://|"#
            + NSRegularExpression.escapedPattern(for: CherryDeepLink.scheme)
            + #"://|file://|mailto:)[^\s<>"'`\)\]]+"#
        private static let fencedBlockPattern = #"(?m)^```[\s\S]*?^```"#

        private func applyPatterns(to storage: NSTextStorage?, text: String) {
            guard let storage else { return }
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let fencedCodeRanges = Self.fencedCodeRanges(in: text, range: fullRange)

            for rule in terminalRules() {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                for match in regex.matches(in: text, range: fullRange) {
                    let range = match.range(at: rule.captureGroup)
                    guard range.location != NSNotFound else { continue }
                    if rule.skipsFencedCode,
                       fencedCodeRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                        continue
                    }
                    storage.addAttributes(rule.attributes, range: range)
                }
            }

            applyLinks(to: storage, text: text, nsText: nsText, fencedCodeRanges: fencedCodeRanges)
        }

        /// Marks markdown link labels and bare URLs with `.link` so a click opens them.
        /// Link destinations inside `](...)` stay plain so the URL is still click-editable.
        private func applyLinks(
            to storage: NSTextStorage,
            text: String,
            nsText: NSString,
            fencedCodeRanges: [NSRange]
        ) {
            let fullRange = NSRange(location: 0, length: nsText.length)
            func isInsideFencedCode(_ range: NSRange) -> Bool {
                fencedCodeRanges.contains { NSIntersectionRange($0, range).length > 0 }
            }

            var markdownLinkRanges: [NSRange] = []
            if let regex = try? NSRegularExpression(pattern: Self.linkPattern) {
                for match in regex.matches(in: text, range: fullRange) {
                    let labelRange = match.range(at: 2)
                    let destinationRange = match.range(at: 4)
                    guard labelRange.location != NSNotFound,
                          destinationRange.location != NSNotFound,
                          !isInsideFencedCode(match.range)
                    else { continue }
                    markdownLinkRanges.append(match.range)
                    guard let url = Self.linkURL(from: nsText.substring(with: destinationRange)) else { continue }
                    storage.addAttribute(.link, value: url, range: labelRange)
                }
            }

            guard let regex = try? NSRegularExpression(pattern: Self.bareURLPattern) else { return }
            let urlColor = paletteColor(4) ?? paletteColor(12) ?? .linkColor
            for match in regex.matches(in: text, range: fullRange) {
                var range = match.range
                guard range.location != NSNotFound,
                      !isInsideFencedCode(range),
                      !markdownLinkRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
                else { continue }
                // Trailing sentence punctuation is almost never part of the URL.
                while range.length > 0,
                      ".,;:!?".contains(Character(nsText.substring(with: NSRange(location: range.location + range.length - 1, length: 1)))) {
                    range.length -= 1
                }
                guard range.length > 0,
                      let url = Self.linkURL(from: nsText.substring(with: range))
                else { continue }
                storage.addAttributes([.link: url, .foregroundColor: urlColor], range: range)
            }
        }

        /// Only destinations with a scheme are opened; `#anchor` / relative paths are left alone.
        private static func linkURL(from destination: String) -> URL? {
            var candidate = destination.trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("<"), candidate.hasSuffix(">"), candidate.count >= 2 {
                candidate = String(candidate.dropFirst().dropLast())
            }
            // `[label](url "title")` — drop the optional title.
            if let space = candidate.firstIndex(where: \.isWhitespace) {
                candidate = String(candidate[..<space])
            }
            guard let url = URL(string: candidate), url.scheme != nil else { return nil }
            return url
        }

        private static func fencedCodeRanges(in text: String, range: NSRange) -> [NSRange] {
            guard let regex = try? NSRegularExpression(pattern: fencedBlockPattern) else { return [] }
            return regex.matches(in: text, range: range).map(\.range)
        }

        private func terminalRules() -> [Rule] {
            let headingColor = paletteColor(12) ?? paletteColor(4) ?? .systemPurple
            let codeColor = paletteColor(11) ?? paletteColor(3) ?? .systemOrange
            let linkColor = paletteColor(4) ?? paletteColor(12) ?? .linkColor
            let markerColor = foregroundColor.withAlphaComponent(0.42)
            let quoteColor = foregroundColor.withAlphaComponent(0.62)

            let h1Size = bodyFontSize * 1.55
            let h2Size = bodyFontSize * 1.32
            let h3Size = bodyFontSize * 1.15
            let h4Size = bodyFontSize

            return [
                Rule(pattern: #"(?m)^#\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h1Size, color: headingColor)),
                Rule(pattern: #"(?m)^##\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h2Size, color: headingColor)),
                Rule(pattern: #"(?m)^###\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h3Size, color: headingColor)),
                Rule(pattern: #"(?m)^#{4,6}\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: h4Size, color: headingColor)),
                Rule(pattern: #"(?m)^>\s?.*$"#, captureGroup: 0, attributes: [.foregroundColor: quoteColor, .obliqueness: 0.12]),
                Rule(pattern: #"(?m)^\s*([-*+])(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"(?m)^\s*(\d+\.)(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"(?m)^\s*[-*+]\s+(\[[ xX]\])"#, captureGroup: 1, attributes: [.foregroundColor: markerColor]),
                Rule(pattern: #"`[^`\n]+`"#, captureGroup: 0, attributes: [.foregroundColor: codeColor, .font: codeFont()]),
                Rule(pattern: Coordinator.fencedBlockPattern, captureGroup: 0, attributes: [.foregroundColor: codeColor, .font: codeFont(), .paragraphStyle: codeBlockParagraphStyle], skipsFencedCode: false),
                Rule(pattern: #"\[[^\]\n]+\]\([^\)\n]+\)"#, captureGroup: 0, attributes: [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]),
                Rule(pattern: #"(\*\*|__)[^\n]+?(\*\*|__)"#, captureGroup: 0, attributes: [.font: bodyFont(weight: .semibold)]),
                Rule(pattern: #"(?<!\*)\*[^\n*]+?\*(?!\*)"#, captureGroup: 0, attributes: [.obliqueness: 0.16])
            ]
        }
    }
}

final class MarkdownDocumentView: NSView {
    let textView: NSTextView
    private var lastReportedContentHeight: CGFloat = 0

    var maxContentWidth: CGFloat = 740
    var minHorizontalInset: CGFloat = 32
    var verticalInset: CGFloat = 24
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

    @objc private func textViewFrameChanged() {
        adjustHeightToContent()
    }

    override func layout() {
        super.layout()
        let availableWidth = bounds.width
        let horizontal = max(minHorizontalInset, (availableWidth - maxContentWidth) / 2)
        let contentWidth = min(maxContentWidth, max(0, availableWidth - horizontal * 2))
        let y = verticalInset

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
