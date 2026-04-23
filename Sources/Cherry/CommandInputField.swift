import AppKit
import SwiftUI

struct CommandInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> CommandPromptTextField {
        let field = CommandPromptTextField()
        field.delegate = context.coordinator
        field.submitAction = onSubmit
        field.placeholderString = placeholder
        field.stringValue = text
        field.isEnabled = isEnabled
        return field
    }

    func updateNSView(_ nsView: CommandPromptTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        nsView.submitAction = onSubmit
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func update(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }

            return false
        }
    }
}

final class CommandPromptTextField: NSTextField {
    var submitAction: (() -> Void)?

    private var canBecomeResponder = false

    override var acceptsFirstResponder: Bool {
        canBecomeResponder && isEnabled
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        font = TerminalFontPalette.medium(size: 13)
        focusRingType = .default
        lineBreakMode = .byTruncatingTail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        canBecomeResponder = true
        _ = window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            canBecomeResponder = false
        }

        return result
    }
}
