import Foundation
import Testing
@testable import Cherry

private func ops(_ s: String) -> [NativeInputOp] {
    NativeInputTranslator.translate(Data(s.utf8))
}
private func ops(_ bytes: [UInt8]) -> [NativeInputOp] {
    NativeInputTranslator.translate(Data(bytes))
}

@Test func nativeInputPlainTextIsOneTextOp() {
    #expect(ops("echo hello") == [.text("echo hello")])
}

@Test func nativeInputCarriageReturnSubmitsAsReturnKey() {
    // kVK_Return = 36
    #expect(ops("ls\r") == [
        .text("ls"),
        .key(keycode: 36, shift: false, control: false, option: false),
    ])
}

@Test func nativeInputCollapsesCRLFIntoOneReturn() {
    #expect(ops("x\r\n") == [
        .text("x"),
        .key(keycode: 36, shift: false, control: false, option: false),
    ])
}

@Test func nativeInputControlCMapsToCtrlCKey() {
    // kVK_ANSI_C = 8
    #expect(ops([0x03]) == [.key(keycode: 8, shift: false, control: true, option: false)])
}

@Test func nativeInputCsiArrowsMapToArrowKeys() {
    // Left/Right/Up/Down = 123/124/126/125
    #expect(ops([0x1B, 0x5B, 0x44]) == [.key(keycode: 123, shift: false, control: false, option: false)])
    #expect(ops([0x1B, 0x5B, 0x43]) == [.key(keycode: 124, shift: false, control: false, option: false)])
    #expect(ops([0x1B, 0x5B, 0x41]) == [.key(keycode: 126, shift: false, control: false, option: false)])
    #expect(ops([0x1B, 0x5B, 0x42]) == [.key(keycode: 125, shift: false, control: false, option: false)])
}

@Test func nativeInputSS3ArrowsMapToArrowKeys() {
    // Application-cursor-keys form: ESC O D
    #expect(ops([0x1B, 0x4F, 0x44]) == [.key(keycode: 123, shift: false, control: false, option: false)])
}

@Test func nativeInputModifiedArrowParsesModifiers() {
    // ESC [ 1 ; 5 C  = Ctrl+Right
    #expect(ops([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43]) == [
        .key(keycode: 124, shift: false, control: true, option: false),
    ])
}

@Test func nativeInputTildeFormsMapToNavKeys() {
    // ESC [ 3 ~ = Forward Delete (117); ESC [ 5 ~ = PageUp (116)
    #expect(ops([0x1B, 0x5B, 0x33, 0x7E]) == [.key(keycode: 117, shift: false, control: false, option: false)])
    #expect(ops([0x1B, 0x5B, 0x35, 0x7E]) == [.key(keycode: 116, shift: false, control: false, option: false)])
}

@Test func nativeInputShiftTabMapsToTabWithShift() {
    // ESC [ Z = Shift-Tab; kVK_Tab = 48
    #expect(ops([0x1B, 0x5B, 0x5A]) == [.key(keycode: 48, shift: true, control: false, option: false)])
}

@Test func nativeInputLoneEscapeBecomesEscapeKey() {
    // kVK_Escape = 53
    #expect(ops([0x1B]) == [.key(keycode: 53, shift: false, control: false, option: false)])
}

@Test func nativeInputBackspaceAndTabMapToKeys() {
    #expect(ops([0x7F]) == [.key(keycode: 51, shift: false, control: false, option: false)]) // Backspace
    #expect(ops([0x09]) == [.key(keycode: 48, shift: false, control: false, option: false)]) // Tab
}

@Test func nativeInputMixedPromptThenSubmit() {
    // The common agent-driving case: a prompt followed by Enter.
    #expect(ops("do the thing\r") == [
        .text("do the thing"),
        .key(keycode: 36, shift: false, control: false, option: false),
    ])
}

@Test func nativeInputTextAroundArrowKeepsRunsSeparate() {
    // "ab" + Left + "cd"
    var bytes = Array("ab".utf8)
    bytes += [0x1B, 0x5B, 0x44]
    bytes += Array("cd".utf8)
    #expect(ops(bytes) == [
        .text("ab"),
        .key(keycode: 123, shift: false, control: false, option: false),
        .text("cd"),
    ])
}
