import Foundation
import Testing
@testable import CherryMobileKit

@Test func claudesPermissionPromptIsAMenuWithItsQuestion() throws {
    let menu = try #require(ScreenMenu.find(in: [
        "⏺ I'll run the key encoder tests before committing.",
        "",
        "╭──────────────────────────────────────────────────────╮",
        "│ Bash command                                         │",
        "│                                                      │",
        "│   swift test --filter AdapterAwayKeyInput            │",
        "│                                                      │",
        "│ Do you want to proceed?                              │",
        "│ ❯ 1. Yes                                             │",
        "│   2. Yes, and don't ask again for swift test         │",
        "│   3. No, and tell Claude what to do differently      │",
        "╰──────────────────────────────────────────────────────╯",
    ]))
    #expect(menu.question == "Do you want to proceed?")
    #expect(menu.options.map(\.label) == [
        "Yes", "Yes, and don't ask again for swift test", "No, and tell Claude what to do differently",
    ])
    #expect(menu.options.map(\.isSelected) == [true, false, false])
    #expect(menu.options[1].keys == [.text("2")])
}

@Test func codexsApprovalIsAMenu() throws {
    let menu = try #require(ScreenMenu.find(in: [
        "  Would you like to run the following command?",
        "",
        "  $ swift test",
        "",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for this command (a)",
        "  3. No, and tell Codex what to do differently (esc)",
        "",
        "  Press enter to confirm or esc to cancel",
    ]))
    #expect(menu.options.count == 3)
    #expect(menu.options[0].isSelected)
}

@Test func optionsWithDescriptionsUnderThemAreOneMenu() throws {
    let menu = try #require(ScreenMenu.find(in: [
        "☐ Storage",
        "",
        "Where should the samples go?",
        "",
        "❯ 1. Application Support",
        "     Private, out of backups",
        "  2. Scratch directory",
        "     Cleared on reboot",
        "  3. Type something.",
    ]))
    #expect(menu.question == "Where should the samples go?")
    #expect(menu.options.map(\.number) == [1, 2, 3])
}

@Test func aNumberedListInProseIsNotAMenu() {
    #expect(ScreenMenu.find(in: [
        "Summary of the change:",
        "1. Sampling skips animation-only screens.",
        "2. Heartbeats back off to every 5 minutes.",
        "",
        "> ",
    ]) == nil)
}

@Test func aQuestionMakesAMenuWithoutACursor() throws {
    let menu = try #require(ScreenMenu.find(in: [
        "Which one should I keep?",
        "1) the old parser",
        "2) the new parser",
    ]))
    #expect(menu.options.map(\.label) == ["the old parser", "the new parser"])
}

@Test func optionsMustCountFromOneInOrder() {
    #expect(ScreenMenu.find(in: ["Pick?", "❯ 2. Two", "  3. Three"]) == nil)
    #expect(ScreenMenu.find(in: ["Pick?", "❯ 1. One"]) == nil)
    #expect(ScreenMenu.find(in: ["Pick?", "❯ 1. One", "  3. Three"]) == nil)
}

@Test func aMenuFarAboveTheBottomIsGone() {
    let menu = ["Proceed?", "❯ 1. Yes", "  2. No"]
    #expect(ScreenMenu.find(in: menu) != nil)
    #expect(ScreenMenu.find(in: menu + Array(repeating: "output", count: 40)) == nil)
}

@Test func onlyTheLastMenuCounts() throws {
    let menu = try #require(ScreenMenu.find(in: [
        "Earlier?", "❯ 1. A", "  2. B",
        "⏺ Done.",
        "Now?", "❯ 1. C", "  2. D",
    ]))
    #expect(menu.options.map(\.label) == ["C", "D"])
}
