import AppKit
import SwiftUI

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var themeColors: TerminalThemeColors?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, themeColors: themeColors)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.applyInsertionPoint(to: textView)
        context.coordinator.applySelectionColors(to: textView)
        context.coordinator.setText(text, in: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.themeColors = themeColors
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
        var themeColors: TerminalThemeColors?
        private var isApplyingText = false

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

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: foregroundColor
            ]
        }

        private func applyPatterns(to storage: NSTextStorage?, text: String) {
            guard let storage else { return }
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            let headingColor = paletteColor(12) ?? paletteColor(4) ?? .systemBlue
            let quoteColor = paletteColor(13) ?? paletteColor(5) ?? .systemPurple
            let listColor = paletteColor(14) ?? paletteColor(6) ?? .systemTeal
            let taskColor = paletteColor(10) ?? paletteColor(2) ?? .systemGreen
            let codeColor = paletteColor(11) ?? paletteColor(3) ?? .systemOrange
            let linkColor = paletteColor(6) ?? paletteColor(14) ?? .linkColor

            let patterns: [(String, [NSAttributedString.Key: Any])] = [
                (#"(?m)^#{1,6}\s+.*$"#, [.foregroundColor: headingColor, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)]),
                (#"(?m)^>\s?.*$"#, [.foregroundColor: quoteColor]),
                (#"(?m)^\s*[-*+]\s+.*$"#, [.foregroundColor: listColor]),
                (#"(?m)^\s*\d+\.\s+.*$"#, [.foregroundColor: listColor]),
                (#"(?m)^\s*[-*+]\s+\[[ xX]\]\s+.*$"#, [.foregroundColor: taskColor]),
                (#"`[^`\n]+`"#, [.foregroundColor: codeColor]),
                (#"(?m)^```[\s\S]*?^```"#, [.foregroundColor: codeColor]),
                (#"\[[^\]\n]+\]\([^\)\n]+\)"#, [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]),
                (#"(\*\*|__)[^\n]+?(\*\*|__)"#, [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)]),
                (#"(?<!\*)\*[^\n*]+?\*(?!\*)"#, [.obliqueness: 0.16])
            ]

            for (pattern, attributes) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: text, range: fullRange) {
                    guard match.range.location != NSNotFound else { continue }
                    storage.addAttributes(attributes, range: match.range)
                }
            }
        }
    }
}
