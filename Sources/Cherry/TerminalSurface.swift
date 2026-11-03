import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI

enum TerminalInputEncoder {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let tabKeyCode: UInt16 = 48
    private static let backspaceKeyCode: UInt16 = 51
    private static let appKitTopRowDigitKeyCodes: Set<UInt16> = [
        18, // 1
        19, // 2
        20, // 3
        21, // 4
        23, // 5
        22, // 6
        26, // 7
        28, // 8
        25, // 9
        29  // 0
    ]
    private static let appKitLeftArrowKeyCode: UInt16 = 0x7B
    private static let appKitRightArrowKeyCode: UInt16 = 0x7C
    private static let appKitDownArrowKeyCode: UInt16 = 0x7D
    private static let appKitUpArrowKeyCode: UInt16 = 0x7E

    /// Enter is CR under every keyboard protocol Cherry types for: the
    /// kitty report-all-keys encoding (`CSI 13 u`) is not sent.
    static let enterData = Data("\r".utf8)

    static func terminalTextData(_ text: String) -> Data {
        let utf8 = text.utf8
        if !utf8.contains(0x0A), !utf8.contains(0x0D) {
            return Data(utf8)
        }

        var data = Data()
        data.reserveCapacity(utf8.count)
        var previousWasCarriageReturn = false

        for byte in utf8 {
            switch byte {
            case 0x0D:
                data.append(enterData)
                previousWasCarriageReturn = true
            case 0x0A:
                if !previousWasCarriageReturn {
                    data.append(enterData)
                }
                previousWasCarriageReturn = false
            default:
                data.append(byte)
                previousWasCarriageReturn = false
            }
        }

        return data
    }

    enum CursorKey {
        case up
        case down
        case right
        case left
    }

    static func cursorKeySequence(
        _ key: CursorKey,
        usesApplicationCursorKeys: Bool
    ) -> String {
        if usesApplicationCursorKeys {
            return switch key {
            case .up:
                "\u{1B}OA"
            case .down:
                "\u{1B}OB"
            case .right:
                "\u{1B}OC"
            case .left:
                "\u{1B}OD"
            }
        }

        return switch key {
        case .up:
            "\u{1B}[A"
        case .down:
            "\u{1B}[B"
        case .right:
            "\u{1B}[C"
        case .left:
            "\u{1B}[D"
        }
    }

    static func appKitUnmodifiedArrowSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        usesApplicationCursorKeys: Bool
    ) -> Data? {
        guard modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }

        let key: CursorKey
        switch keyCode {
        case appKitLeftArrowKeyCode:
            key = .left
        case appKitRightArrowKeyCode:
            key = .right
        case appKitDownArrowKeyCode:
            key = .down
        case appKitUpArrowKeyCode:
            key = .up
        default:
            return nil
        }

        return Data(cursorKeySequence(key, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
    }

    static func appKitOptionArrowSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        sendsModifiedArrowKeys: Bool = true
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.option),
              !modifiers.contains(.shift),
              !modifiers.contains(.control),
              !modifiers.contains(.command)
        else {
            return nil
        }

        if !sendsModifiedArrowKeys {
            switch keyCode {
            case appKitRightArrowKeyCode:
                return Data("\u{1B}f".utf8)
            case appKitLeftArrowKeyCode:
                return Data("\u{1B}b".utf8)
            default:
                break
            }
        }

        let suffix: String
        switch keyCode {
        case appKitUpArrowKeyCode:
            suffix = "A"
        case appKitDownArrowKeyCode:
            suffix = "B"
        case appKitRightArrowKeyCode:
            suffix = "C"
        case appKitLeftArrowKeyCode:
            suffix = "D"
        default:
            return nil
        }

        return Data("\u{1B}[1;3\(suffix)".utf8)
    }

    static func appKitOptionBackspaceSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.option),
              !modifiers.contains(.shift),
              !modifiers.contains(.control),
              !modifiers.contains(.command),
              keyCode == backspaceKeyCode
        else {
            return nil
        }

        return Data([0x1B, 0x7F])
    }

    static func appKitOptionDigitTextData(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.option),
              !modifiers.contains(.control),
              !modifiers.contains(.command),
              isAppKitTopRowDigitKey(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers)
        else {
            return nil
        }

        if let characters, !characters.isEmpty {
            guard let text = printableTerminalText(characters) else { return nil }
            return terminalTextData(text)
        }

        guard let text = translatedAppKitText(keyCode: keyCode, modifiers: modifiers) else {
            return nil
        }

        return terminalTextData(text)
    }

    private static func isAppKitTopRowDigitKey(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        if appKitTopRowDigitKeyCodes.contains(keyCode) {
            return true
        }

        guard let ignoredCharacters = charactersIgnoringModifiers,
              ignoredCharacters.unicodeScalars.count == 1,
              let ignoredScalar = ignoredCharacters.unicodeScalars.first
        else {
            return false
        }

        return ignoredScalar.value >= 0x30 && ignoredScalar.value <= 0x39
    }

    private static func printableTerminalText(_ text: String?) -> String? {
        guard let text,
              !text.isEmpty,
              !isAppKitFunctionKeyText(text),
              text.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F
              })
        else {
            return nil
        }

        return text
    }

    static func translatedAppKitText(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }

        let modifierKeyState = (carbonModifiers >> 8) & 0xFF
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var actualLength = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )

        guard status == noErr,
              actualLength > 0
        else {
            return nil
        }

        return printableTerminalText(String(utf16CodeUnits: chars, count: actualLength))
    }

    static func shiftEnterSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEnhancedKeyboardProtocolActive: Bool
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.shift),
              !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              keyCode == returnKeyCode || keyCode == keypadEnterKeyCode
        else {
            return nil
        }

        if isEnhancedKeyboardProtocolActive {
            return Data("\u{1B}[13;2u".utf8)
        }
        return Data("\r".utf8)
    }

    static func shiftTabSequence(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isEnhancedKeyboardProtocolActive: Bool
    ) -> Data? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.shift),
              !modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              keyCode == tabKeyCode
        else {
            return nil
        }

        if isEnhancedKeyboardProtocolActive {
            return Data("\u{1B}[9;2u".utf8)
        }
        return Data("\u{1B}[Z".utf8)
    }

    /// Bytes a paste never carries, replaced by a space in either mode, as
    /// Ghostty (`input/paste.zig`) and xterm do: ESC (so a paste cannot end
    /// its own bracket with `ESC [ 201 ~` and type the rest as keys), NUL,
    /// BS, ENQ, EOT, DEL, and the line discipline's control characters
    /// (Ctrl-C, -\\, -U, -Z, -Q, -S, -W, -V, -R, -O).
    static let pasteStrippedBytes: Set<UInt8> = [
        0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F,
        0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F,
    ]

    static func pastedTextData(_ text: String, bracketedPasteMode: Bool = false) -> Data {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let textData = Data(normalizedText.utf8.map { pasteStrippedBytes.contains($0) ? 0x20 : $0 })
        guard bracketedPasteMode else { return textData }

        var data = Data("\u{1B}[200~".utf8)
        data.append(textData)
        data.append(contentsOf: "\u{1B}[201~".utf8)
        return data
    }

    static func isAppKitFunctionKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0xF700 && scalar.value <= 0xF8FF
        }
    }
}

enum TerminalPasteboardContent {
    /// Where a pasted image is written (`PastedImageStore`).
    static var defaultImageDirectory: URL {
        PastedImageStore.defaultDirectory
    }

    /// The paste, wrapped in bracketed-paste markers when `bracketing`
    /// says so for the text that is pasted: the pasteboard's text, a URL,
    /// or the path of a pasted image (saved to `imageDirectory`, quoted as
    /// `PastedImage.quoted`).
    static func pasteData(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory,
        bracketing: (String) -> Bool
    ) -> Data? {
        guard let text = pasteText(from: pasteboard, imageDirectory: imageDirectory) else { return nil }
        return TerminalInputEncoder.pastedTextData(text, bracketedPasteMode: bracketing(text))
    }

    /// What a paste of `pasteboard` types: its text, else its URLs (file
    /// URLs as escaped paths), else the quoted path of its image written
    /// to `imageDirectory`. Nil when it has none of these.
    static func pasteText(from pasteboard: NSPasteboard, imageDirectory: URL = defaultImageDirectory) -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        if let urlText = urlPasteText(from: pasteboard) {
            return urlText
        }
        if let imageURL = pastedImageFileURL(from: pasteboard, imageDirectory: imageDirectory) {
            return PastedImage.quoted(imageURL.path)
        }
        return nil
    }

    static func urlPasteText(from pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else {
            return nil
        }

        return urls
            .map { $0.isFileURL ? shellEscaped($0.path) : $0.absoluteString }
            .joined(separator: " ")
    }

    /// The pasteboard's image written as a PNG to `imageDirectory`
    /// (`PastedImageStore`); nil when it has none.
    static func pastedImageFileURL(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory,
        imageID: UUID = UUID(),
        now: Date = Date()
    ) -> URL? {
        guard let pngData = PastedImage.pngData(from: pasteboard) else { return nil }
        return try? PastedImageStore.save(pngData, in: imageDirectory, now: now, id: imageID)
    }

    static func shellEscaped(_ value: String) -> String {
        var result = value
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(of: String(character), with: "\\\(character)")
        }
        return result
    }
}

struct TerminalSurfaceView: NSViewRepresentable {
    let session: TerminalSession
    @ObservedObject var chromeState: ProjectWindowChromeState
    let isActivePane: Bool
    let onActivate: (UUID) -> Void

    func makeNSView(context: Context) -> GhosttyTerminalContainerView {
        let containerView = GhosttyTerminalContainerView()
        updateNSView(containerView, context: context)
        return containerView
    }

    func updateNSView(_ nsView: GhosttyTerminalContainerView, context: Context) {
        TerminalPerformanceMonitor.recordRepresentableUpdate()
        nsView.configure(
            with: session,
            colorScheme: context.environment.colorScheme,
            allowsAutoFocus: isActivePane && !chromeState.isOmniBarPresented,
            isActivePane: isActivePane,
            onActivate: { onActivate(session.id) }
        )
        nsView.applySidebarAnimationState(
            isAnimating: chromeState.isSidebarAnimating,
            postAnimationDeltaWidth: chromeState.pendingPostAnimationDelta
        )
    }

    static func dismantleNSView(_ nsView: GhosttyTerminalContainerView, coordinator: ()) {
        nsView.detachActiveSession(releasesBridge: false, preservingSurface: true)
    }
}
