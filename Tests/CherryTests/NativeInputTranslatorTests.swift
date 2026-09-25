import Foundation
import Testing
@testable import Cherry

private func ops(_ s: String) -> [NativeInputOp] {
    NativeInputTranslator.translate(Data(s.utf8))
}
private func ops(_ bytes: [UInt8]) -> [NativeInputOp] {
    NativeInputTranslator.translate(Data(bytes))
}
private func rawOps(_ bytes: [UInt8]) -> [NativeInputOp] {
    NativeInputTranslator.translate(Data(bytes), raw: true)
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

@Test func nativeInputControlLettersGoToThePTYAsTheirBytes() {
    // A synthesized Ctrl-letter key carries no text or unshifted code point,
    // so Ghostty's kitty encoder would drop it: the byte goes to the PTY.
    #expect(ops([0x03]) == [.bytes(Data([0x03]))])
    #expect(ops([0x05, 0x06, 0x04]) == [.bytes(Data([0x05, 0x06, 0x04]))])
    // Ctrl-@ and Ctrl-\ … Ctrl-_ too (the text path would drop them).
    #expect(ops([0x00, 0x1C, 0x1D, 0x1E, 0x1F]) == [.bytes(Data([0x00, 0x1C, 0x1D, 0x1E, 0x1F]))])
    #expect(ops(Array("ab".utf8) + [0x15] + Array("cd".utf8)) == [
        .text("ab"), .bytes(Data([0x15])), .text("cd"),
    ])
}

@Test func nativeInputRawPrintableBytesAreTypedNotPasted() {
    // nvim: `j`, Ctrl-E, `:x`, Enter.
    #expect(rawOps(Array("j".utf8) + [0x05] + Array(":x".utf8) + [0x0D]) == [
        .bytes(Data("j\u{05}:x".utf8)),
        .key(keycode: 36, shift: false, control: false, option: false),
    ])
    #expect(rawOps(Array("é".utf8)) == [.bytes(Data("é".utf8))])
    // Keys are still keys, which Ghostty encodes for the program's modes.
    #expect(rawOps([0x1B, 0x5B, 0x42, 0x09, 0x7F, 0x1B]) == [
        .key(keycode: 125, shift: false, control: false, option: false),
        .key(keycode: 48, shift: false, control: false, option: false),
        .key(keycode: 51, shift: false, control: false, option: false),
        .key(keycode: 53, shift: false, control: false, option: false),
    ])
}

@Test func nativeInputRawAltKeysGoToThePTYAsTheirBytes() {
    // Alt-j, Alt-Shift-O, Alt-[ and Alt-é: ESC and the key, in one run.
    #expect(rawOps(Array("\u{1B}j".utf8)) == [.bytes(Data("\u{1B}j".utf8))])
    #expect(rawOps(Array("x\u{1B}Oy".utf8)) == [.bytes(Data("x\u{1B}Oy".utf8))])
    #expect(rawOps(Array("\u{1B}[".utf8)) == [.bytes(Data("\u{1B}[".utf8))])
    #expect(rawOps(Array("\u{1B}é".utf8)) == [.bytes(Data("\u{1B}é".utf8))])
    // A lone Escape, or one before a control character, stays a key.
    #expect(rawOps([0x1B, 0x1B, 0x0D]) == [
        .key(keycode: 53, shift: false, control: false, option: false),
        .key(keycode: 53, shift: false, control: false, option: false),
        .key(keycode: 36, shift: false, control: false, option: false),
    ])
    #expect(rawOps([0x1B, 0x7F]) == [
        .key(keycode: 53, shift: false, control: false, option: false),
        .key(keycode: 51, shift: false, control: false, option: false),
    ])
    // Text input is unchanged: Escape, then the pasted text.
    #expect(ops(Array("\u{1B}j".utf8)) == [
        .key(keycode: 53, shift: false, control: false, option: false),
        .text("j"),
    ])
}

@Test func nativeInputUnmappedSequencesGoToThePTYWhole() {
    // A kitty `CSI u` key (Ctrl-E) and bracketed paste markers are no key
    // the translator maps: not an Escape key and a pasted tail.
    #expect(ops(Array("\u{1B}[101;5u".utf8)) == [.bytes(Data("\u{1B}[101;5u".utf8))])
    #expect(rawOps(Array("\u{1B}[200~x\u{1B}[201~".utf8)) == [.bytes(Data("\u{1B}[200~x\u{1B}[201~".utf8))])
    #expect(ops(Array("\u{1B}[97;5:1u".utf8)) == [.bytes(Data("\u{1B}[97;5:1u".utf8))])
    // Incomplete: a lone Escape, then text.
    #expect(ops(Array("\u{1B}[".utf8)) == [
        .key(keycode: 53, shift: false, control: false, option: false),
        .text("["),
    ])
}

@Test func nativeInputTextBindingActionEscapesForGhostty() {
    #expect(NativeInputTranslator.textBindingAction(for: Data([0x05])) == "text:\\x05")
    #expect(NativeInputTranslator.textBindingAction(for: Data([0x00, 0x1B, 0x7F])) == "text:\\x00\\x1b\\x7f")
    #expect(NativeInputTranslator.textBindingAction(for: Data(#"a\b "c":x"#.utf8)) == #"text:a\\b "c":x"#)
    // `\xNN` is a code point in Ghostty's string syntax: other characters go
    // as their UTF-8.
    #expect(NativeInputTranslator.textBindingAction(for: Data("é→".utf8)) == "text:é→")
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

// MARK: - What a program reads, through a real Ghostty EXEC surface

/// A program in raw mode with bracketed paste on and, when `kittyFlags` is
/// not 0, the kitty keyboard protocol with those flags pushed (nvim 0.12
/// pushes 3). It records every byte it reads once the terminal answered a
/// status report sent after the modes, so they were applied before any
/// input came.
@MainActor
private final class InputProbe {
    let directory: URL
    let session: TerminalSession
    private let output: URL
    private let ready: URL

    init(kittyFlags: Int) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-input-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        output = directory.appendingPathComponent("input.bin")
        ready = directory.appendingPathComponent("ready")
        let script = directory.appendingPathComponent("probe.py")
        try #"""
        import os, select, sys, time, tty
        flags, output, ready = int(sys.argv[1]), sys.argv[2], sys.argv[3]
        tty.setraw(0)
        os.write(1, b"\x1b[?2004h")
        if flags:
            os.write(1, b"\x1b[>%du" % flags)
        os.write(1, b"\x1b[5n")
        answer, deadline = b"", time.time() + 10
        while b"\x1b[0n" not in answer and time.time() < deadline:
            if select.select([0], [], [], 0.5)[0]:
                answer += os.read(0, 1024)
        open(output, "wb").close()
        open(ready, "wb").write(answer)
        with open(output, "ab", buffering=0) as recorded:
            deadline = time.time() + 60
            while time.time() < deadline:
                if select.select([0], [], [], 0.5)[0]:
                    data = os.read(0, 4096)
                    if not data:
                        break
                    recorded.write(data)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let arguments = [script.path, String(kittyFlags), output.path, ready.path]
            .map(TerminalPasteboardContent.shellEscaped).joined(separator: " ")
        session = TerminalSession(
            title: "Probe",
            subtitle: "input probe",
            tint: .systemGreen,
            workingDirectory: directory.path,
            launchCommand: "/usr/bin/python3 \(arguments)"
        )
    }

    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path), "the probe did not start")
        #expect(session.usesNativePTYBackend)
    }

    /// What the program read so far.
    var received: Data { (try? Data(contentsOf: output)) ?? Data() }

    /// Waits until the program read `count` bytes, then a little longer
    /// for anything extra.
    func receive(atLeast count: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(5)
        while received.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        return received
    }

    func reset() throws {
        try Data().write(to: output)
    }

    func cleanUp() {
        session.stop()
        session.releaseGhosttyBridge()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Raw input (`raw_base64`, `sendRaw`) reaches the program as its bytes,
/// with the kitty keyboard protocol on or off: control letters are not
/// dropped and printable keys are typed, never pasted.
@Test(arguments: [0, 1, 3]) @MainActor
func rawInputReachesTheProgramAsItsBytes(kittyFlags: Int) async throws {
    let probe = try InputProbe(kittyFlags: kittyFlags)
    defer { probe.cleanUp() }
    try await probe.waitUntilReady()

    // nvim: `j`, Ctrl-E, `:x`, Ctrl-F, Ctrl-D; a backslash, UTF-8 and
    // Ctrl-@, which Ghostty's text action must not mangle; Enter.
    let keys = Data("j".utf8) + Data([0x05]) + Data(":x".utf8) + Data([0x06, 0x04])
        + Data(#"\é"#.utf8) + Data([0x00, 0x0D])
    probe.session.sendRaw(data: keys)
    let received = try await probe.receive(atLeast: keys.count)
    #expect(hex(received) == hex(keys), "kitty flags \(kittyFlags)")
}

/// Raw Alt keys (`ESC x`) reach the program as a legacy terminal sends
/// them, with the kitty keyboard protocol on or off: not as an Escape key
/// (`CSI 27 u` under the kitty protocol) and then the key.
@Test(arguments: [0, 1, 3]) @MainActor
func rawAltKeysReachTheProgramAsTheirBytes(kittyFlags: Int) async throws {
    let probe = try InputProbe(kittyFlags: kittyFlags)
    defer { probe.cleanUp() }
    try await probe.waitUntilReady()

    let keys = Data("\u{1B}j\u{1B}x".utf8)
    probe.session.sendRaw(data: keys)
    let received = try await probe.receive(atLeast: keys.count)
    #expect(hex(received) == hex(keys), "kitty flags \(kittyFlags)")
}

/// Control letters in text input (MCP `text`, `send(data:)`) reach the
/// program too, with the kitty keyboard protocol on or off.
@Test(arguments: [0, 1, 3]) @MainActor
func controlLettersInTextInputReachTheProgram(kittyFlags: Int) async throws {
    let probe = try InputProbe(kittyFlags: kittyFlags)
    defer { probe.cleanUp() }
    try await probe.waitUntilReady()

    probe.session.send(data: Data([0x05, 0x15, 0x03]))
    let received = try await probe.receive(atLeast: 3)
    #expect(hex(received) == hex(Data([0x05, 0x15, 0x03])), "kitty flags \(kittyFlags)")
}

/// Text input keeps its paste semantics: a program with bracketed paste on
/// reads it as one paste (an agent's message is not typed key by key into
/// its shortcuts), then Enter as the key.
@Test(arguments: [0, 1]) @MainActor
func textInputIsPastedAndItsEnterIsAKey(kittyFlags: Int) async throws {
    let probe = try InputProbe(kittyFlags: kittyFlags)
    defer { probe.cleanUp() }
    try await probe.waitUntilReady()

    probe.session.send(data: Data("hi there\r".utf8))
    let expected = Data("\u{1B}[200~hi there\u{1B}[201~\r".utf8)
    let received = try await probe.receive(atLeast: expected.count)
    #expect(hex(received) == hex(expected), "kitty flags \(kittyFlags)")
}

/// Key sequences are still keys Ghostty encodes for the program's modes.
@Test(arguments: [0, 1]) @MainActor
func rawArrowKeysAreEncodedForTheProgramsModes(kittyFlags: Int) async throws {
    let probe = try InputProbe(kittyFlags: kittyFlags)
    defer { probe.cleanUp() }
    try await probe.waitUntilReady()

    probe.session.sendRaw(data: Data("\u{1B}[B".utf8))
    let received = try await probe.receive(atLeast: 3)
    #expect(hex(received) == hex(Data("\u{1B}[B".utf8)), "kitty flags \(kittyFlags)")
}
