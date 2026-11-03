import Foundation
import Testing
@testable import Cherry

private let screenTexts = [
    "", "\n", "\n\n", "a", "a\n", "\na", "a\nb", "a\n\nb\n",
    // "\r\n" is one Character: String's split never splits it.
    "\r\n", "a\r\nb\n", "\r\r\n\n", "\n\r\n\r",
    // Combining marks, flags and joined emoji next to a newline.
    "x\n\u{301}y\n", "e\u{301}\nе\n🇮🇹\n👨‍👩‍👧\n", "\u{0}\n\u{0}",
    "╭─ ~/cherry  main ✔\n╰─❯ ls\n  trailing  \n",
]

@Test func terminalScreenTextLinesAreStringsSplitAtNewlines() {
    for text in screenTexts + screenTexts.map({ NSString(string: $0) as String }) {
        let expected = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = TerminalScreenText.lines(of: text)
        #expect(lines == expected, "\(text.debugDescription)")
        #expect(lines.map { Array($0.utf8) } == expected.map { Array($0.utf8) }, "\(text.debugDescription)")
    }
}

@Test func terminalScreenTextHashFollowsTheTextsBytes() {
    for text in screenTexts {
        #expect(TerminalScreenText.contentHash(of: text) == TerminalScreenText.contentHash(of: NSString(string: text) as String))
    }
    let screen = (0..<2_000).map { "line \($0) │ output" }.joined(separator: "\n")
    #expect(TerminalScreenText.contentHash(of: screen) == TerminalScreenText.contentHash(of: String(decoding: Array(screen.utf8), as: UTF8.self)))
    #expect(TerminalScreenText.contentHash(of: screen) != TerminalScreenText.contentHash(of: screen + "\n"))
    #expect(TerminalScreenText.contentHash(of: screen) != TerminalScreenText.contentHash(of: screen.replacingOccurrences(of: "line 1999", with: "line 1998")))
}
