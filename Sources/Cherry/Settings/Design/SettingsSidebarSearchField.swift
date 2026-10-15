import AppKit
import SwiftUI

/// The sidebar's search capsule, "Search settings". The
/// field is AppKit's, as the Omni bar's (`CommandPaletteSearchField`), so
/// its key commands reach `onCommand` (`moveUp:`, `moveDown:`,
/// `insertNewline:`, `cancelOperation:`; true when handled), which
/// SwiftUI's field does not pass on reliably. It takes focus only when
/// asked (`focusRequest` changes: ⌘F, a click), never when the window
/// opens.
struct SettingsSidebarSearchField: View {
    @Binding var text: String
    let focusRequest: Int
    let onCommand: (Selector) -> Bool

    init(text: Binding<String>, focusRequest: Int, onCommand: @escaping (Selector) -> Bool) {
        _text = text
        self.focusRequest = focusRequest
        self.onCommand = onCommand
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            SettingsSearchTextFieldRepresentable(text: $text, focusRequest: focusRequest, onCommand: onCommand)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(SettingsDesign.Colors.fill2, in: Capsule())
    }
}

private struct SettingsSearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onCommand: (Selector) -> Bool

    func makeCoordinator() -> Coordinator {
        // The request the field starts with is not one: no focus on appear.
        Coordinator(text: $text, onCommand: onCommand, lastFocusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> SettingsSearchTextField {
        let textField = SettingsSearchTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = "Search settings"
        textField.font = .systemFont(ofSize: 13.5)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityLabel("Search settings")
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: SettingsSearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            context.coordinator.requestFocus(for: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: (Selector) -> Bool
        var lastFocusRequest: Int

        init(text: Binding<String>, onCommand: @escaping (Selector) -> Bool, lastFocusRequest: Int) {
            self.text = text
            self.onCommand = onCommand
            self.lastFocusRequest = lastFocusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField,
                  text.wrappedValue != textField.stringValue
            else {
                return
            }
            text.wrappedValue = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            onCommand(commandSelector)
        }

        /// Focuses the field on the next turn, its text selected (⌘F), as a
        /// search field does.
        func requestFocus(for textField: SettingsSearchTextField) {
            DispatchQueue.main.async { [weak textField] in
                textField?.focus()
            }
        }
    }
}

/// The search field. AppKit picks a window's first responder as the window
/// comes on screen and becomes key, so the field refuses focus until its
/// window has been key for one main-queue turn, and again once the window
/// closes: opening Settings never focuses it. A click, ⌘F or Tab does
/// after that.
final class SettingsSearchTextField: NSTextField {
    private var takesFocus = false
    private var windowObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        guard takesFocus, window?.isVisible == true else { return false }
        return super.becomeFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        takesFocus = false
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidBecomeKey() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            },
        ]
        if window.isKeyWindow {
            windowDidBecomeKey()
        }
    }

    /// Focuses the field when asked (⌘F), its text selected.
    func focus() {
        guard let window else { return }
        takesFocus = true
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    /// The window's first responder is picked by now.
    private func windowDidBecomeKey() {
        guard !takesFocus else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                self.takesFocus = true
            }
        }
    }

    /// A window opened again starts with the field unfocused too.
    private func windowWillClose() {
        takesFocus = false
        if currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
    }
}
