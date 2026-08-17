import AppKit
import SwiftUI

enum NoteEditorStyle {
    /// Raw monospace source with terminal-palette colors (used by the todo inspector).
    case terminal
    /// Document look for notes: proportional type, left-anchored column, syntax
    /// markers hanging in a leading gutter so text sits flush.
    case document

    var contentWidth: CGFloat {
        self == .document ? 716 : 740
    }

    /// Minimum inset from the pane edge to the marker gutter.
    var horizontalInset: CGFloat {
        self == .document ? 12 : 32
    }

    var verticalInset: CGFloat {
        self == .document ? 14 : 24
    }

    var headerSpacing: CGFloat {
        self == .document ? 16 : 24
    }

    /// Left gutter that syntax markers hang into so text sits flush.
    var textGutter: CGFloat {
        self == .document ? 36 : 0
    }

    var centersContent: Bool {
        self == .terminal
    }
}

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
    var style: NoteEditorStyle = .terminal
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            themeColors: themeColors,
            bodyFontSize: bodyFontSize,
            useMonospacedFont: useMonospacedFont,
            style: style
        )
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
        let layoutManager = MarkdownLayoutManager()
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
        documentView.headerSpacing = headerSpacing
        documentView.centersContent = style.centersContent
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
        documentView.centersContent = style.centersContent
        documentView.onContentHeightChange = onContentHeightChange
        documentView.setHeader(rootView: header)
        documentView.needsLayout = true

        let textView = documentView.textView
        context.coordinator.themeColors = themeColors
        context.coordinator.bodyFontSize = bodyFontSize
        context.coordinator.useMonospacedFont = useMonospacedFont
        context.coordinator.style = style
        textView.defaultParagraphStyle = context.coordinator.bodyParagraphStyle
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
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        weak var documentView: MarkdownDocumentView?
        var themeColors: TerminalThemeColors?
        var bodyFontSize: CGFloat
        var useMonospacedFont: Bool
        var style: NoteEditorStyle
        private var isApplyingText = false

        init(
            text: Binding<String>,
            themeColors: TerminalThemeColors?,
            bodyFontSize: CGFloat,
            useMonospacedFont: Bool,
            style: NoteEditorStyle
        ) {
            _text = text
            self.themeColors = themeColors
            self.bodyFontSize = bodyFontSize
            self.useMonospacedFont = useMonospacedFont
            self.style = style
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
            let raw = themeColors.flatMap { NSColor(hexRGB: $0.foreground) } ?? .labelColor
            guard style == .document else { return raw }
            let background = themeColors.flatMap { NSColor(hexRGB: $0.background) }
            return raw.boostedForReading(against: background)
        }

        private func paletteColor(_ index: Int) -> NSColor? {
            guard let hex = themeColors?.palette[index] else { return nil }
            return NSColor(hexRGB: hex)
        }

        private var gutter: CGFloat { style.textGutter }

        var bodyParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.4
            paragraph.paragraphSpacing = style == .document ? 7 : 4
            if style == .document {
                paragraph.firstLineHeadIndent = gutter
                paragraph.headIndent = gutter
            }
            return paragraph
        }

        private var headingParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.2
            paragraph.paragraphSpacingBefore = style == .document ? 14 : 10
            paragraph.paragraphSpacing = 6
            if style == .document {
                paragraph.firstLineHeadIndent = gutter
                paragraph.headIndent = gutter
            }
            return paragraph
        }

        private var codeBlockParagraphStyle: NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.25
            paragraph.paragraphSpacing = style == .document ? 0 : 6
            if style == .document {
                let block = NSTextBlock()
                block.backgroundColor = foregroundColor.withAlphaComponent(0.05)
                block.setContentWidth(100, type: .percentageValueType)
                block.setWidth(gutter, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                paragraph.textBlocks = [block]
            }
            return paragraph
        }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: bodyFont(weight: .regular),
                .foregroundColor: foregroundColor,
                .kern: style == .terminal ? 0.1 : 0,
                .paragraphStyle: bodyParagraphStyle
            ]
        }

        private var effectiveBodyFontSize: CGFloat {
            style == .terminal ? bodyFontSize : 15
        }

        private func bodyFont(weight: NSFont.Weight) -> NSFont {
            let size = effectiveBodyFontSize
            if style == .terminal, useMonospacedFont {
                return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            }
            return NSFont.systemFont(ofSize: size, weight: weight)
        }

        private func headingFont(size: CGFloat) -> NSFont {
            if style == .terminal {
                if useMonospacedFont {
                    return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
                }
                return NSFont.systemFont(ofSize: size, weight: .semibold)
            }
            return NSFont.systemFont(ofSize: size, weight: .bold)
        }

        private func headingSize(forLevel level: Int) -> CGFloat {
            switch level {
            case 1: return effectiveBodyFontSize * 1.55
            case 2: return effectiveBodyFontSize * 1.3
            case 3: return effectiveBodyFontSize * 1.12
            default: return effectiveBodyFontSize
            }
        }

        private func codeFont(weight: NSFont.Weight = .regular) -> NSFont {
            let size = style == .terminal ? effectiveBodyFontSize : (effectiveBodyFontSize * 0.88).rounded()
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
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

        private static let boldPattern = #"(\*\*|__)([^\n]+?)(\*\*|__)"#
        private static let italicPattern = #"(?<!\*)(\*)([^\n*]+?)(\*)(?!\*)"#
        private static let inlineCodePattern = #"(`)([^`\n]+)(`)"#
        private static let linkPattern = #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#
        private static let bareURLPattern = #"(?<![\w/])(?:https?://|cherry://|file://|mailto:)[^\s<>"'`\)\]]+"#
        private static let headingMarkerPattern = #"(?m)^(#{1,6}[ \t])"#
        private static let fenceLinePattern = #"(?m)^(`{3}.*)$"#
        private static let fencedBlockPattern = #"(?m)^```[\s\S]*?^```"#

        private func applyPatterns(to storage: NSTextStorage?, text: String) {
            guard let storage else { return }
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let fencedCodeRanges = Self.fencedCodeRanges(in: text, range: fullRange)

            let rules = style == .terminal ? terminalRules() : documentRules()

            for rule in rules {
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

            if style == .document {
                applyFlushLayout(
                    to: storage,
                    text: text,
                    nsText: nsText,
                    fencedCodeRanges: fencedCodeRanges
                )
            }
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

        private func documentRules() -> [Rule] {
            let fg = foregroundColor
            let accent = paletteColor(4) ?? paletteColor(12) ?? .controlAccentColor
            let markerAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: fg.withAlphaComponent(0.4)]
            let quoteColor = fg.withAlphaComponent(0.7)
            let chipColor = fg.withAlphaComponent(0.09)
            let bulletColor = fg.withAlphaComponent(0.55)
            let linkAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: accent.withAlphaComponent(0.45)
            ]
            let linkDestinationAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: fg.withAlphaComponent(0.55)]

            let fencedBlockAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: fg.withAlphaComponent(0.9),
                .font: codeFont(),
                .paragraphStyle: codeBlockParagraphStyle
            ]

            return [
                Rule(pattern: #"(?m)^#\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: headingSize(forLevel: 1), color: fg)),
                Rule(pattern: #"(?m)^##\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: headingSize(forLevel: 2), color: fg)),
                Rule(pattern: #"(?m)^###\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: headingSize(forLevel: 3), color: fg)),
                Rule(pattern: #"(?m)^#{4,6}\s+.*$"#, captureGroup: 0, attributes: headingAttributes(size: headingSize(forLevel: 4), color: fg)),
                Rule(pattern: Coordinator.headingMarkerPattern, captureGroup: 1, attributes: markerAttributes),
                Rule(pattern: #"(?m)^>\s?.*$"#, captureGroup: 0, attributes: [.foregroundColor: quoteColor, .obliqueness: 0.12]),
                Rule(pattern: #"(?m)^\s*([-*+])(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: bulletColor]),
                Rule(pattern: #"(?m)^\s*(\d+\.)(?=\s)"#, captureGroup: 1, attributes: [.foregroundColor: bulletColor]),
                Rule(pattern: #"(?m)^\s*[-*+]\s+(\[[ xX]\])"#, captureGroup: 1, attributes: [.foregroundColor: bulletColor]),
                Rule(pattern: Coordinator.boldPattern, captureGroup: 0, attributes: [.font: bodyFont(weight: .semibold)]),
                Rule(pattern: Coordinator.boldPattern, captureGroup: 1, attributes: markerAttributes),
                Rule(pattern: Coordinator.boldPattern, captureGroup: 3, attributes: markerAttributes),
                Rule(pattern: Coordinator.italicPattern, captureGroup: 0, attributes: [.obliqueness: 0.16]),
                Rule(pattern: Coordinator.italicPattern, captureGroup: 1, attributes: markerAttributes),
                Rule(pattern: Coordinator.italicPattern, captureGroup: 3, attributes: markerAttributes),
                Rule(pattern: Coordinator.inlineCodePattern, captureGroup: 0, attributes: [.foregroundColor: fg, .font: codeFont(), .backgroundColor: chipColor, MarkdownLayoutManager.chipAttribute: true]),
                Rule(pattern: Coordinator.inlineCodePattern, captureGroup: 1, attributes: markerAttributes),
                Rule(pattern: Coordinator.inlineCodePattern, captureGroup: 3, attributes: markerAttributes),
                Rule(pattern: Coordinator.fencedBlockPattern, captureGroup: 0, attributes: fencedBlockAttributes, skipsFencedCode: false),
                Rule(pattern: Coordinator.fenceLinePattern, captureGroup: 1, attributes: markerAttributes, skipsFencedCode: false),
                Rule(pattern: Coordinator.linkPattern, captureGroup: 2, attributes: linkAttributes),
                Rule(pattern: Coordinator.linkPattern, captureGroup: 1, attributes: markerAttributes),
                Rule(pattern: Coordinator.linkPattern, captureGroup: 3, attributes: markerAttributes),
                Rule(pattern: Coordinator.linkPattern, captureGroup: 4, attributes: linkDestinationAttributes),
                Rule(pattern: Coordinator.linkPattern, captureGroup: 5, attributes: markerAttributes)
            ]
        }

        /// Hangs block prefixes (heading hashes, bullets, quote chevrons) into the left
        /// gutter so the text column sits flush.
        private func applyFlushLayout(
            to storage: NSTextStorage,
            text: String,
            nsText: NSString,
            fencedCodeRanges: [NSRange]
        ) {
            let fullRange = NSRange(location: 0, length: nsText.length)

            func isInsideFencedCode(_ range: NSRange) -> Bool {
                fencedCodeRanges.contains { NSIntersectionRange($0, range).length > 0 }
            }

            func hang(prefixRange: NSRange, markerRange: NSRange, font: NSFont, base: NSParagraphStyle) {
                guard let paragraph = base.mutableCopy() as? NSMutableParagraphStyle else { return }
                let leadingLength = markerRange.location - prefixRange.location
                let leading = leadingLength > 0
                    ? nsText.substring(with: NSRange(location: prefixRange.location, length: leadingLength))
                    : ""
                let marker = nsText.substring(with: markerRange)
                let leadingWidth = leading.isEmpty ? 0 : ceil((leading as NSString).size(withAttributes: [.font: font]).width)
                let markerWidth = ceil((marker as NSString).size(withAttributes: [.font: font]).width)
                paragraph.headIndent = gutter + leadingWidth
                paragraph.firstLineHeadIndent = max(0, gutter + leadingWidth - markerWidth)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: nsText.paragraphRange(for: markerRange))
            }

            if let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,6}[ \t])"#) {
                for match in regex.matches(in: text, range: fullRange) {
                    let markerRange = match.range(at: 1)
                    guard markerRange.location != NSNotFound,
                          !isInsideFencedCode(markerRange)
                    else { continue }
                    let level = markerRange.length - 1
                    hang(
                        prefixRange: markerRange,
                        markerRange: markerRange,
                        font: headingFont(size: headingSize(forLevel: level)),
                        base: headingParagraphStyle
                    )
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"(?m)^([ \t]*)((?:[-*+]|\d{1,3}\.)[ \t]+)"#) {
                for match in regex.matches(in: text, range: fullRange) {
                    let markerRange = match.range(at: 2)
                    guard markerRange.location != NSNotFound,
                          !isInsideFencedCode(markerRange)
                    else { continue }
                    hang(
                        prefixRange: match.range(at: 0),
                        markerRange: markerRange,
                        font: bodyFont(weight: .regular),
                        base: bodyParagraphStyle
                    )
                }
            }

            if let regex = try? NSRegularExpression(pattern: #"(?m)^(>[ \t]?)"#) {
                for match in regex.matches(in: text, range: fullRange) {
                    let markerRange = match.range(at: 1)
                    guard markerRange.location != NSNotFound,
                          !isInsideFencedCode(markerRange)
                    else { continue }
                    hang(
                        prefixRange: markerRange,
                        markerRange: markerRange,
                        font: bodyFont(weight: .regular),
                        base: bodyParagraphStyle
                    )
                }
            }
        }
    }
}

extension NSColor {
    /// Terminal-theme foregrounds are tuned for a text grid and often sit at a
    /// soft gray; prose wants a crisper contrast. Pulls the color part-way toward
    /// white (on dark backgrounds) or black (on light ones).
    func boostedForReading(against background: NSColor?, amount: CGFloat = 0.5) -> NSColor {
        guard let background else { return self }
        let pole: NSColor = background.relativeLuminance < 0.5 ? .white : .black
        guard let base = usingColorSpace(.sRGB), let target = pole.usingColorSpace(.sRGB) else { return self }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
        return NSColor(
            srgbRed: mix(base.redComponent, target.redComponent),
            green: mix(base.greenComponent, target.greenComponent),
            blue: mix(base.blueComponent, target.blueComponent),
            alpha: base.alphaComponent
        )
    }
}

/// Draws inline-code chip backgrounds as rounded rects clamped to the glyphs they
/// belong to. Stock TextKit extends a background run that starts a wrapped line back
/// to the line fragment's leading edge, which paints a stray slab left of the text.
final class MarkdownLayoutManager: NSLayoutManager {
    static let chipAttribute = NSAttributedString.Key("cherry.inlineCodeChip")

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let isChip = charRange.location < (textStorage?.length ?? 0)
            && textStorage?.attribute(Self.chipAttribute, at: charRange.location, effectiveRange: nil) != nil
        guard isChip else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil)
        else { return }

        var rects: [(bounds: NSRect, glyphIndex: Int)] = []
        enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard intersection.length > 0 else { return }
            rects.append((
                bounds: self.boundingRect(forGlyphRange: intersection, in: container),
                glyphIndex: intersection.location
            ))
        }
        guard !rects.isEmpty else { return }

        color.setFill()
        for rect in rects {
            guard let chipRect = inlineCodeChipRect(
                forGlyphBounds: rect.bounds,
                glyphIndex: rect.glyphIndex
            ) else { continue }
            NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3).fill()
        }
    }

    /// TextKit's glyph bounding rect is as tall as the line fragment, including
    /// paragraph leading. Anchor the chip to the run's baseline and font metrics
    /// so its background stays centered on the inline code instead.
    func inlineCodeChipRect(
        forGlyphBounds glyphBounds: NSRect,
        glyphIndex: Int
    ) -> NSRect? {
        guard let textStorage,
              glyphIndex < numberOfGlyphs
        else { return nil }

        let characterIndex = characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let font = textStorage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
        else { return nil }

        let lineRect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let baselineY = lineRect.minY + location(forGlyphAt: glyphIndex).y
        let horizontalPadding: CGFloat = 2
        let verticalPadding: CGFloat = 1

        return NSRect(
            x: glyphBounds.minX - horizontalPadding,
            y: baselineY - font.ascender - verticalPadding,
            width: glyphBounds.width + horizontalPadding * 2,
            height: font.ascender - font.descender + verticalPadding * 2
        )
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
    var centersContent: Bool = true
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
        let horizontal = centersContent
            ? max(minHorizontalInset, (availableWidth - maxContentWidth) / 2)
            : minHorizontalInset
        let contentWidth = min(maxContentWidth, max(0, availableWidth - horizontal * 2))

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
