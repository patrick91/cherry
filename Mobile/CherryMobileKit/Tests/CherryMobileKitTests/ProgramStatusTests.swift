import Foundation
import Testing
@testable import CherryMobileKit

/// A `SessionInfo` as the host sends it, with `fields` added.
private func sessionInfo(_ fields: String = "", state: String = "running") throws -> HostWireSession {
    let json = """
    {"id":"s1","name":"✳ Fix the tests","cwd":"/Users/me/app","command":["claude"],"cols":120,"rows":40,
     "state":"\(state)","pid":42,"exit_code":null,"attached":false,"exit_signal":null,
     "tags":{"cherry.kind":"agent","cherry.agent":"claude"}\(fields.isEmpty ? "" : ",\(fields)")}
    """
    return try JSONDecoder().decode(HostWireSession.self, from: Data(json.utf8))
}

private let mac = UUID()

@Test func anAgentsOwnStatusSaysWhatItNeeds() throws {
    let cases: [(String, AgentAttention)] = [
        (#"{"state":"blocked","kind":"permission","app":"claude-code","message":"Approve Bash: npm test"}"#, .approval),
        (#"{"state":"blocked","kind":"question","app":"claude-code"}"#, .question),
        (#"{"state":"blocked","kind":"auth"}"#, .question),
        (#"{"state":"blocked"}"#, .question),
        (#"{"state":"done","message":"Tests pass"}"#, .resultReady),
        (#"{"state":"working"}"#, .working),
        (#"{"state":"idle"}"#, .idle),
        (#"{"state":"error","message":"Rate limited"}"#, .error),
        (#"{"state":"sparkling"}"#, .unknown),
    ]
    for (record, attention) in cases {
        let info = try sessionInfo(#""program_status":[\#(record)]"#)
        #expect(SessionMapping.session(info, macID: mac).attention == attention, "\(record)")
    }

    // The message says what it waits for; the title stands in for none.
    let blocked = try sessionInfo(#""program_status":[{"state":"blocked","kind":"permission","title":"Claude Code","message":"Approve Bash: npm test"}]"#)
    #expect(SessionMapping.session(blocked, macID: mac).detail == "Approve Bash: npm test")
    let titled = try sessionInfo(#""program_status":[{"state":"working","title":"Fixing the tests","message":" "}]"#)
    #expect(SessionMapping.session(titled, macID: mac).detail == "Fixing the tests")
}

@Test func onlyTheProgramsOwnRecordCounts() throws {
    // A child's record (a build step) is not the program's.
    let child = try sessionInfo(#""program_status":[{"id":"build/test","state":"blocked","kind":"permission"}]"#)
    #expect(SessionMapping.session(child, macID: mac).attention == .unknown)
    #expect(SessionMapping.session(child, macID: mac).detail == nil)

    let both = try sessionInfo(#""program_status":[{"state":"working"},{"id":"build","state":"error"}]"#)
    #expect(SessionMapping.session(both, macID: mac).attention == .working)
}

@Test func aProgramThatReportsNothingOrEndedIsUnknown() throws {
    // Codex and Amp report nothing; an older host sends no field.
    let silent = try sessionInfo()
    #expect(silent.programStatus.isEmpty)
    #expect(SessionMapping.session(silent, macID: mac).attention == .unknown)

    let exited = try sessionInfo(#""program_status":[{"state":"done","message":"Tests pass"}]"#, state: "exited")
    let session = SessionMapping.session(exited, macID: mac)
    #expect(session.attention == .unknown)
    #expect(session.detail == nil)
    #expect(!session.isRunning)
}

@Test func theKeyModesAreTheHosts() throws {
    let legacy = try sessionInfo()
    #expect(legacy.keyModes == KeyModes())

    let set = try sessionInfo(#""kitty_keyboard_flags":5,"application_cursor_keys":true,"bracketed_paste":true"#)
    #expect(set.keyModes == KeyModes(applicationCursorKeys: true, kittyKeyboardFlags: 5, bracketedPaste: true))
}

@Test func keysFollowTheProgramsKeyModes() {
    let esc = "\u{1B}"
    // Legacy: what a terminal types.
    #expect(MobileKey.up.bytes(in: KeyModes()) == Data("\(esc)[A".utf8))
    #expect(MobileKey.tab.bytes(in: KeyModes()) == Data([0x09]))

    // Application cursor keys (less, vim): ESC O, unless the kitty
    // encoding is on, which sends them as CSI.
    let application = KeyModes(applicationCursorKeys: true)
    #expect(MobileKey.up.bytes(in: application) == Data("\(esc)OA".utf8))
    #expect(MobileKey.left.bytes(in: application) == Data("\(esc)OD".utf8))
    let kitty = KeyModes(applicationCursorKeys: true, kittyKeyboardFlags: 1)
    #expect(MobileKey.down.bytes(in: kitty) == Data("\(esc)[B".utf8))

    // Tab as an escape code only when the program asked for every key.
    #expect(MobileKey.tab.bytes(in: kitty) == Data([0x09]))
    #expect(MobileKey.tab.bytes(in: KeyModes(kittyKeyboardFlags: 0b1001)) == Data("\(esc)[9u".utf8))

    // Escape, Enter and ⌃C are the same in every mode, as `cherry keys`
    // types them.
    for modes in [KeyModes(), application, kitty] {
        #expect(MobileKey.escape.bytes(in: modes) == Data([0x1B]))
        #expect(MobileKey.enter.bytes(in: modes) == Data([0x0D]))
        #expect(MobileKey.controlC.bytes(in: modes) == Data([0x03]))
    }
}

@Test func aReplyOfSeveralLinesIsOnePaste() {
    let esc = "\u{1B}"
    let reply = MobileKey.text("Review these:\n1. the tests")
    let pasted = Data("\(esc)[200~Review these:\n1. the tests\(esc)[201~".utf8)
    #expect(reply.bytes(in: KeyModes(bracketedPaste: true)) == pasted)
    // An older holder can't tell: bracketed anyway, as the Mac pastes.
    #expect(reply.bytes(in: KeyModes()) == pasted)
    // A program that turned it off gets the lines.
    #expect(reply.bytes(in: KeyModes(bracketedPaste: false)) == Data("Review these:\n1. the tests".utf8))
    // One line is typed as it is.
    #expect(MobileKey.text("yes").bytes(in: KeyModes(bracketedPaste: true)) == Data("yes".utf8))
    // Nothing in it ends the paste early.
    #expect(MobileKey.text("a\n\(esc)[201~b").bytes(in: KeyModes(bracketedPaste: true))
        == Data("\(esc)[200~a\n[201~b\(esc)[201~".utf8))
}
