import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI

private let terminalInputDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"

enum TerminalInputEncoder {
    private static let maximumScrollStepsPerEvent = 36
    private static let terminalScrollRowsPerLine: CGFloat = 3
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

    static func commandSequence(
        for selector: Selector,
        usesApplicationCursorKeys: Bool = false
    ) -> Data? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return Data("\r".utf8)
        case #selector(NSResponder.insertTab(_:)):
            return Data("\t".utf8)
        case #selector(NSResponder.cancelOperation(_:)):
            return Data([0x03])
        case #selector(NSResponder.deleteBackward(_:)):
            return Data([0x7F])
        case #selector(NSResponder.deleteForward(_:)):
            return Data("\u{1B}[3~".utf8)
        case #selector(NSResponder.moveLeft(_:)):
            return Data(cursorKeySequence(.left, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveRight(_:)):
            return Data(cursorKeySequence(.right, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveUp(_:)):
            return Data(cursorKeySequence(.up, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveDown(_:)):
            return Data(cursorKeySequence(.down, usesApplicationCursorKeys: usesApplicationCursorKeys).utf8)
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            return Data([0x01])
        case #selector(NSResponder.moveToEndOfLine(_:)):
            return Data([0x05])
        case #selector(NSResponder.moveWordLeft(_:)):
            return Data("\u{1B}b".utf8)
        case #selector(NSResponder.moveWordRight(_:)):
            return Data("\u{1B}f".utf8)
        case #selector(NSResponder.deleteWordBackward(_:)):
            return Data([0x1B, 0x7F])
        case #selector(NSResponder.pageUp(_:)):
            return Data("\u{1B}[5~".utf8)
        case #selector(NSResponder.pageDown(_:)):
            return Data("\u{1B}[6~".utf8)
        default:
            return nil
        }
    }

    static func enterSequence(keyboardProtocolFlags: Int) -> Data {
        return Data("\r".utf8)
    }

    static func terminalTextData(
        _ text: String,
        keyboardProtocolFlags: Int
    ) -> Data {
        let utf8 = text.utf8
        if !utf8.contains(0x0A), !utf8.contains(0x0D) {
            return Data(utf8)
        }

        let enter = enterSequence(keyboardProtocolFlags: keyboardProtocolFlags)
        var data = Data()
        data.reserveCapacity(utf8.count)
        var previousWasCarriageReturn = false

        for byte in utf8 {
            switch byte {
            case 0x0D:
                data.append(enter)
                previousWasCarriageReturn = true
            case 0x0A:
                if !previousWasCarriageReturn {
                    data.append(enter)
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
        modifiers: NSEvent.ModifierFlags,
        keyboardProtocolFlags: Int
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
            return terminalTextData(text, keyboardProtocolFlags: keyboardProtocolFlags)
        }

        guard let text = translatedAppKitText(keyCode: keyCode, modifiers: modifiers) else {
            return nil
        }

        return terminalTextData(text, keyboardProtocolFlags: keyboardProtocolFlags)
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

    static func pastedTextData(_ text: String, bracketedPasteMode: Bool = false) -> Data {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let textData = Data(normalizedText.utf8)
        guard bracketedPasteMode else { return textData }

        var data = Data("\u{1B}[200~".utf8)
        data.append(textData)
        data.append(contentsOf: "\u{1B}[201~".utf8)
        return data
    }

    static func insertedTextData(_ text: String) -> Data? {
        guard !isAppKitFunctionKeyText(text) else { return nil }
        return Data(text.utf8)
    }

    static func isAppKitFunctionKeyText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0xF700 && scalar.value <= 0xF8FF
        }
    }

    static func alternateScreenScrollSequence(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        remainder: inout CGFloat
    ) -> Data? {
        let steps = scrollStepCount(
            deltaY: deltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            lineHeight: lineHeight,
            remainder: &remainder
        )
        guard steps != 0 else { return nil }

        let sequence = steps > 0 ? "\u{1B}[A" : "\u{1B}[B"
        return Data(String(repeating: sequence, count: abs(steps)).utf8)
    }

    static func mouseWheelSequence(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        column: Int,
        row: Int,
        mouseState: TerminalMouseState,
        remainder: inout CGFloat
    ) -> Data? {
        let steps = scrollStepCount(
            deltaY: deltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            lineHeight: lineHeight,
            remainder: &remainder
        )
        guard steps != 0 else { return nil }

        let button = steps > 0 ? 64 : 65
        var data = Data()
        for _ in 0..<abs(steps) {
            if mouseState.usesSGREncoding {
                data.append(Data("\u{1B}[<\(button);\(column);\(row)M".utf8))
            } else if let legacySequence = legacyMouseWheelSequence(button: button, column: column, row: row) {
                data.append(legacySequence)
            }
        }

        return data.isEmpty ? nil : data
    }

    static func mousePosition(
        documentLocation: NSPoint,
        visibleOrigin: NSPoint,
        viewportSize: TerminalViewportSize,
        sideInset: CGFloat,
        topInset: CGFloat,
        cellWidth: CGFloat,
        lineHeight: CGFloat
    ) -> (column: Int, row: Int) {
        let visibleLocation = NSPoint(
            x: documentLocation.x - visibleOrigin.x,
            y: documentLocation.y - visibleOrigin.y
        )
        let rawColumn = Int(floor((visibleLocation.x - sideInset) / cellWidth)) + 1
        let rawRow = Int(floor((visibleLocation.y - topInset) / lineHeight)) + 1

        return (
            column: min(max(rawColumn, 1), viewportSize.columns),
            row: min(max(rawRow, 1), viewportSize.rows)
        )
    }

    static func clampedViewportOffset(
        currentOffset: CGFloat,
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maximumOffset = max(0, documentHeight - viewportHeight)
        let scrollDelta = hasPreciseScrollingDeltas
            ? deltaY
            : deltaY * lineHeight
        let proposedOffset = currentOffset - scrollDelta
        return min(max(proposedOffset, 0), maximumOffset)
    }

    private static func scrollStepCount(
        deltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        lineHeight: CGFloat,
        remainder: inout CGFloat
    ) -> Int {
        guard deltaY != 0 else { return 0 }

        let rawSteps: Int
        if hasPreciseScrollingDeltas {
            let scrollUnit = max(1, lineHeight / terminalScrollRowsPerLine)
            remainder += deltaY / scrollUnit
            rawSteps = Int(remainder.rounded(.towardZero))
            remainder -= CGFloat(rawSteps)
        } else {
            rawSteps = Int((deltaY * terminalScrollRowsPerLine).rounded(.awayFromZero))
        }

        return min(max(rawSteps, -maximumScrollStepsPerEvent), maximumScrollStepsPerEvent)
    }

    private static func legacyMouseWheelSequence(button: Int, column: Int, row: Int) -> Data? {
        guard (1...223).contains(column), (1...223).contains(row) else { return nil }

        return Data([
            0x1B,
            UInt8(ascii: "["),
            UInt8(ascii: "M"),
            UInt8(button + 32),
            UInt8(column + 32),
            UInt8(row + 32)
        ])
    }
}

enum TerminalPasteboardContent {
    static var defaultImageDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryPastedImages", isDirectory: true)
    }

    static func pasteData(
        from pasteboard: NSPasteboard,
        bracketedPasteMode: Bool = false
    ) -> Data? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return TerminalInputEncoder.pastedTextData(
                text,
                bracketedPasteMode: bracketedPasteMode
            )
        }

        return nonTextPasteData(
            from: pasteboard,
            bracketedPasteMode: bracketedPasteMode
        )
    }

    static func nonTextPasteData(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory,
        imageID: UUID = UUID(),
        bracketedPasteMode: Bool = false
    ) -> Data? {
        if let urlText = urlPasteText(from: pasteboard) {
            return TerminalInputEncoder.pastedTextData(
                urlText,
                bracketedPasteMode: bracketedPasteMode
            )
        }

        guard let imageURL = pastedImageFileURL(
            from: pasteboard,
            imageDirectory: imageDirectory,
            imageID: imageID
        ) else {
            return nil
        }

        return TerminalInputEncoder.pastedTextData(
            shellEscaped(imageURL.path),
            bracketedPasteMode: bracketedPasteMode
        )
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

    static func pastedImageFileURL(
        from pasteboard: NSPasteboard,
        imageDirectory: URL = defaultImageDirectory,
        imageID: UUID = UUID()
    ) -> URL? {
        guard let pngData = pngData(from: pasteboard) else { return nil }

        do {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            let url = imageDirectory.appendingPathComponent("cherry-paste-\(imageID.uuidString).png")
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func shellEscaped(_ value: String) -> String {
        var result = value
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(of: String(character), with: "\\\(character)")
        }
        return result
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        if let data = pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            return pngData(from: image)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return pngData(from: image)
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }
}

struct TerminalSurfaceView: NSViewRepresentable {
    let session: TerminalSession
    @ObservedObject var chromeState: ProjectWindowChromeState
    let isActivePane: Bool
    let usesWorktreeSurfaceTransition: Bool
    let onActivate: (UUID) -> Void

    func makeNSView(context: Context) -> GhosttyTerminalContainerView {
        TerminalPerformanceMonitor.recordRepresentableUpdate()
        let containerView = GhosttyTerminalContainerView()
        containerView.configure(
            with: session,
            colorScheme: context.environment.colorScheme,
            allowsAutoFocus: isActivePane && !chromeState.isCommandPalettePresented,
            isActivePane: isActivePane,
            usesWorktreeSurfaceTransition: usesWorktreeSurfaceTransition,
            onActivate: { onActivate(session.id) }
        )
        containerView.applySidebarAnimationState(
            isAnimating: chromeState.isSidebarAnimating,
            postAnimationDeltaWidth: chromeState.pendingPostAnimationDelta
        )
        return containerView
    }

    func updateNSView(_ nsView: GhosttyTerminalContainerView, context: Context) {
        TerminalPerformanceMonitor.recordRepresentableUpdate()
        nsView.configure(
            with: session,
            colorScheme: context.environment.colorScheme,
            allowsAutoFocus: isActivePane && !chromeState.isCommandPalettePresented,
            isActivePane: isActivePane,
            usesWorktreeSurfaceTransition: usesWorktreeSurfaceTransition,
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
