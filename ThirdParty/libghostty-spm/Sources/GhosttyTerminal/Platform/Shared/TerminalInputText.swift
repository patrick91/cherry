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

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}
