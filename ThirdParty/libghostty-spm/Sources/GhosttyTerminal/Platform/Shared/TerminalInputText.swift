//
//  TerminalInputText.swift
//  libghostty-spm
//

import Foundation

enum TerminalInputText {
    static func filteredFunctionKeyText(_ text: String?) -> String? {
        guard let text else { return nil }
        if isUIKitNamedFunctionKey(text) {
            return nil
        }
        guard text.count == 1, let scalar = text.unicodeScalars.first else {
            return text
        }

        if isPrivateUseFunctionKey(scalar) {
            return nil
        }

        return text
    }

    /// `text` as the text of a key event, as Ghostty's macOS app gives it
    /// (`String.keyEventText`): nil when it is empty or begins with an ASCII
    /// control character (C0 or DEL). Ghostty encodes those keys itself, from
    /// the physical key and all its modifiers; as text they would consume
    /// the modifiers that made them, so under the kitty keyboard protocol
    /// Shift+Return (text `\r`) would type a bare CR, as Return does.
    static func keyEventText(_ text: String?) -> String? {
        guard let text, let scalar = text.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F
        else { return nil }
        return text
    }

    /// Whether `text` is a lone C0 control character that came while an
    /// input method composes (`composing`), as Ghostty's macOS app tells
    /// (`shouldSuppressComposingControlInput`): the input method's (Ctrl+H,
    /// J, M or N in a Japanese one), never the terminal's.
    static func isComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else {
            return false
        }
        return scalar.value < 0x20
    }

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}
