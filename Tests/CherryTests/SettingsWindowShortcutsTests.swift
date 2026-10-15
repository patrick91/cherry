import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Cherry

// Settings › Shortcuts (ShortcutsSettingsPage.swift) and the shortcut
// catalog it lists (CherryShortcuts.swift): the catalog against what the
// project window's key monitor takes and what the menus had, the page's
// rows, the terminal key bindings of a reading with their notes, the
// search and Record. Readings are built by hand or come from a temporary
// home (`TemporaryHome`), never the real one; Record uses a key capture of
// its own, never `SettingsKeyCapture.shared`.

/// What the closures a test hands the page were called with.
@MainActor
private final class ShortcutsCallLog {
    var calls: [String] = []
}

private func keyDown(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = [.command],
    keyCode: Int = 0
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: UInt16(keyCode)
    ))
}

/// The flags AppKit gives a key press with `modifiers` held.
private func flags(_ modifiers: SwiftUI.EventModifiers) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.command) { flags.insert(.command) }
    return flags
}

/// `charactersIgnoringModifiers` of a press of `shortcut`: Shift stays.
private func characters(of shortcut: CherryShortcut) -> String {
    let character = String(shortcut.key.character)
    return shortcut.modifiers.contains(.shift) ? character.uppercased() : character
}

// MARK: - The catalog and the key monitor

/// What `AppShortcutMonitor.shortcutAction` does with each shortcut it
/// takes. ⌥⌘↑ and ⌥⌘↓ are taken by key code in the monitor's coordinator
/// (they go through the sidebar's items), not by `shortcutAction`.
private let monitorActions: [String: AppShortcutMonitor.ShortcutAction] = {
    var actions: [String: AppShortcutMonitor.ShortcutAction] = [
        "newWindow": .openAnotherWindow,
        "newTab": .addSession,
        "closeTab": .closeSelectedSessionOrWindow,
        "detachTab": .detachSelectedSessionOrWindow,
        "undoCloseTab": .undoClosedTab,
        "hideSidebar": .toggleSidebar,
        "splitRight": .splitDuplicate,
        "previousPane": .focusPreviousPane,
        "nextPane": .focusNextPane,
        "omniBar": .toggleOmniBar,
        "openProject": .showOmniBarProjects,
        "settings": .openSettings,
        "quit": .terminate,
    ]
    for number in 1...9 {
        actions["sidebarItem\(number)"] = .selectVisibleSidebarItem(number)
    }
    return actions
}()

private let takenByKeyCode: Set<String> = ["previousTab", "nextTab"]

@Test func settingsWindowShortcutsTheMonitorsShortcutsRouteToTheirActions() {
    for shortcut in CherryShortcut.all {
        let action = AppShortcutMonitor.shortcutAction(
            charactersIgnoringModifiers: characters(of: shortcut),
            modifiers: flags(shortcut.modifiers)
        )
        switch shortcut.taker {
        case .monitor, .both:
            guard !takenByKeyCode.contains(shortcut.id) else { continue }
            #expect(action != nil, "\(shortcut.id)")
            #expect(action == monitorActions[shortcut.id], "\(shortcut.id)")
        case .menu, .terminal:
            // The monitor lets them through to the terminal and the menus.
            #expect(action == nil, "\(shortcut.id)")
        }
    }
    #expect(Set(monitorActions.keys).union(takenByKeyCode) == Set(
        CherryShortcut.all.filter { $0.taker == .monitor || $0.taker == .both }.map(\.id)
    ))
}

@Test func settingsWindowShortcutsTheCatalogHasEveryKeyTheMonitorTakes() {
    let keys = "abcdefghijklmnopqrstuvwxyz0123456789[],".map(String.init)
    for modifiers: SwiftUI.EventModifiers in [.command, [.command, .shift]] {
        for key in keys {
            let characters = modifiers.contains(.shift) ? key.uppercased() : key
            guard AppShortcutMonitor.shortcutAction(
                charactersIgnoringModifiers: characters,
                modifiers: flags(modifiers)
            ) != nil else { continue }
            let shortcut = CherryShortcut.all.first {
                String($0.key.character) == key && $0.modifiers == modifiers
            }
            #expect(shortcut != nil, "\(modifiers) \(key)")
            #expect(shortcut?.taker == .monitor || shortcut?.taker == .both, "\(modifiers) \(key)")
        }
    }
}

@Test @MainActor func settingsWindowShortcutsClearScrollbackIsTheTerminalsUnlessTheOmniBarIsOpen() throws {
    let shortcut = CherryShortcut.clearScrollback
    #expect(shortcut.taker == .terminal)
    #expect(shortcut.taker.takesKeyBeforeTerminal)
    #expect(AppShortcutMonitor.shortcutAction(charactersIgnoringModifiers: "k", modifiers: [.command]) == nil)
    #expect(AppShortcutMonitor.shortcutAction(
        charactersIgnoringModifiers: "k",
        modifiers: [.command],
        omniBarIsOpen: true
    ) == .toggleOmniBarActions)
    // The terminal takes ⌘K itself, before a binding of it can run.
    #expect(GhosttySessionBridge.isClearScrollbackShortcut(try keyDown("k")))
    #expect(!CherryShortcut.restartTab.taker.takesKeyBeforeTerminal)
}

@Test func settingsWindowShortcutsAreWrittenInTheMenusOrder() {
    #expect(CherryShortcut.splitRight.display == "⇧⌘D")
    #expect(CherryShortcut.splitRight.keycaps == ["⇧", "⌘", "D"])
    #expect(CherryShortcut.persistentSessions.display == "⇧⌘R")
    #expect(CherryShortcut.previousTab.display == "⌥⌘↑")
    #expect(CherryShortcut.nextTab.keycaps == ["⌥", "⌘", "↓"])
    #expect(CherryShortcut.settings.display == "⌘,")
    #expect(CherryShortcut.previousPane.display == "⌘[")
    #expect(CherryShortcut.sidebarItems.map(\.display) == (1...9).map { "⌘\($0)" })
    let everything = CherryShortcut(
        "test", "Test", group: .cherry, key: "k", modifiers: [.command, .shift, .option, .control], taker: .menu
    )
    #expect(everything.display == "⌃⌥⇧⌘K")
    #expect(CherryShortcut.glyph(of: .return) == "↩")

    // As Ghostty spells a trigger (`keybindSteps`), by character and by
    // physical key.
    #expect(CherryShortcut.splitRight.ghosttyTrigger == "shift+super+d")
    #expect(TerminalSettings.keybindSteps("cmd+shift+d") == [CherryShortcut.splitRight.ghosttyTrigger])
    #expect(CherryShortcut.previousTab.ghosttyTrigger == "alt+super+arrow_up")
    #expect(TerminalSettings.keybindSteps("super+alt+up") == [CherryShortcut.previousTab.ghosttyTrigger])
    #expect(CherryShortcut.detachTab.ghosttyTriggers == ["super+d", "super+key_d"])
    #expect(CherryShortcut.sidebarItems[0].ghosttyTriggers == ["super+1", "super+digit_1"])
    #expect(CherryShortcut.previousPane.ghosttyTriggers == ["super+[", "super+bracket_left"])
    #expect(CherryShortcut.settings.ghosttyTriggers == ["super+,", "super+comma"])
    #expect(CherryShortcut.nextTab.ghosttyTriggers == ["alt+super+arrow_down"])
}

@Test func settingsWindowShortcutsTheMenusKeepTheirKeys() {
    // File
    #expect(CherryShortcut.newWindow.keyboardShortcut == KeyboardShortcut("n"))
    #expect(CherryShortcut.openProject.keyboardShortcut == KeyboardShortcut("o"))
    #expect(CherryShortcut.persistentSessions.keyboardShortcut == KeyboardShortcut("r", modifiers: [.command, .shift]))
    #expect(CherryShortcut.omniBar.keyboardShortcut == KeyboardShortcut("p"))
    // Edit
    #expect(CherryShortcut.find.keyboardShortcut == KeyboardShortcut("f"))
    #expect(CherryShortcut.findNext.keyboardShortcut == KeyboardShortcut("g"))
    #expect(CherryShortcut.findPrevious.keyboardShortcut == KeyboardShortcut("g", modifiers: [.command, .shift]))
    #expect(CherryShortcut.hideFindBar.keyboardShortcut == KeyboardShortcut("f", modifiers: [.command, .shift]))
    // Prototype
    #expect(CherryShortcut.hideSidebar.keyboardShortcut == KeyboardShortcut("s"))
    #expect(CherryShortcut.newTab.keyboardShortcut == KeyboardShortcut("t"))
    #expect(CherryShortcut.splitRight.keyboardShortcut == KeyboardShortcut("d", modifiers: [.command, .shift]))
    #expect(CherryShortcut.detachTab.keyboardShortcut == KeyboardShortcut("d"))
    #expect(CherryShortcut.closeTab.keyboardShortcut == KeyboardShortcut("w"))
    #expect(CherryShortcut.previousPane.keyboardShortcut == KeyboardShortcut("["))
    #expect(CherryShortcut.nextPane.keyboardShortcut == KeyboardShortcut("]"))
    #expect(CherryShortcut.previousTab.keyboardShortcut == KeyboardShortcut(.upArrow, modifiers: [.command, .option]))
    #expect(CherryShortcut.nextTab.keyboardShortcut == KeyboardShortcut(.downArrow, modifiers: [.command, .option]))
    #expect(CherryShortcut.restartTab.keyboardShortcut == KeyboardShortcut("r"))
    #expect(CherryShortcut.clearScrollback.keyboardShortcut == KeyboardShortcut("k"))
    // The system's own menu items have these keys.
    #expect(CherryShortcut.undoCloseTab.keyboardShortcut == KeyboardShortcut("z"))
    #expect(CherryShortcut.settings.keyboardShortcut == KeyboardShortcut(","))
    #expect(CherryShortcut.quit.keyboardShortcut == KeyboardShortcut("q"))
    // Ids are unique.
    #expect(Set(CherryShortcut.all.map(\.id)).count == CherryShortcut.all.count)
}

// MARK: - The page's lists

@Test func settingsWindowShortcutsThePageListsTheCatalogAsItIs() {
    let rows = ShortcutsSettings.listRows
    #expect(rows.flatMap(\.shortcuts) == CherryShortcut.all)
    #expect(rows.map(\.title) == [
        "New Window", "New Tab", "Close Tab", "Detach Tab", "Undo Close Tab", "Restart Tab",
        "Previous Tab / Next Tab", "Go to Sidebar Item 1–9", "Hide Sidebar",
        "Split Right", "Previous Pane / Next Pane",
        "Find", "Find Next / Find Previous", "Hide Find Bar", "Clear Scrollback",
        "Omni Bar", "Open Project…", "Persistent Sessions…", "Settings", "Quit",
    ])
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(CherryShortcut.Group.allCases.map(\.title) == ["Tabs and windows", "Panes", "Terminal", "Cherry"])
    #expect(rows.filter { $0.group == .panes }.map(\.title) == ["Split Right", "Previous Pane / Next Pane"])

    let panes = rows[10]
    #expect(panes.id == "shortcuts.previousPane")
    #expect(panes.chips == [["⌘", "["], ["⌘", "]"]])
    #expect(panes.separator == "/")
    #expect(panes.keysText == "⌘[ / ⌘]")
    #expect(panes.spokenKeys == "Command Left Bracket or Command Right Bracket")

    let sidebarItems = rows[7]
    #expect(sidebarItems.chips == [["⌘", "1"], ["⌘", "9"]])
    #expect(sidebarItems.separator == "…")
    #expect(sidebarItems.keysText == "⌘1 … ⌘9")
    #expect(sidebarItems.spokenKeys == "Command 1 to Command 9")
    #expect(sidebarItems.note == "Tabs, commands and the to-do board, in sidebar order.")

    #expect(rows.first { $0.title == "Detach Tab" }?.note == "Ghostty's own ⌘D (split) never reaches the terminal.")
    #expect(rows.first { $0.title == "Clear Scrollback" }?.note == "While the Omni bar is open, ⌘K shows its actions instead.")
    #expect(rows.first { $0.title == "Close Tab" }?.note == "Asks first when a program is at work.")
    #expect(rows.first { $0.title == "Undo Close Tab" }?.note == "Only while no text field has focus.")
    #expect(rows.first { $0.title == "Quit" }?.note == nil)
}

@Test func settingsWindowShortcutsKeycapsOfGhosttyTriggers() {
    func chips(_ trigger: String) -> [[String]] {
        TerminalSettings.keybindSteps(trigger).map(ShortcutsSettings.keycaps(ofStep:))
    }

    #expect(chips("ctrl+shift+x") == [["⌃", "⇧", "X"]])
    #expect(chips("shift+ctrl+x") == [["⌃", "⇧", "X"]])
    #expect(chips("super+d") == [["⌘", "D"]])
    #expect(chips("cmd+alt+up") == [["⌥", "⌘", "↑"]])
    #expect(chips("shift+enter") == [["⇧", "↩"]])
    #expect(chips("a>b") == [["A"], ["B"]])
    #expect(chips("ctrl+a>ctrl+shift+tab") == [["⌃", "A"], ["⌃", "⇧", "⇥"]])
    #expect(chips("ctrl++") == [["⌃", "+"]])
    #expect(chips("global:ctrl+grave_accent") == [["⌃", "`"]])
    #expect(chips("f5") == [["F5"]])
    #expect(chips("super+KeyQ") == [["⌘", "Q"]])
    #expect(chips("super+physical:one") == [["⌘", "1"]])
    #expect(chips("super+bracket_left") == [["⌘", "["]])
    #expect(chips("ctrl+numpad_add") == [["⌃", "numpad_add"]])
}

// MARK: - Terminal key bindings

private let configURL = URL(fileURLWithPath: "/Users/someone/.config/ghostty/config")
private let keysURL = URL(fileURLWithPath: "/Users/someone/.config/ghostty/keys.conf")

private func line(
    _ file: URL,
    _ number: Int,
    _ value: String,
    applied: Bool = false,
    rejection: String? = nil,
    reason: UserGhosttyKeyboardConfig.NotAppliedReason? = nil
) -> UserGhosttyKeyboardConfig.Line {
    UserGhosttyKeyboardConfig.Line(
        file: file,
        line: number,
        key: "keybind",
        value: value,
        rejection: rejection,
        isApplied: applied,
        notAppliedReason: reason
    )
}

/// A reading of a few bindings and one of each other case.
private let reading = UserGhosttyKeyboardConfig(
    files: [configURL, keysURL],
    lines: [
        line(keysURL, 2, "shift+enter=text:\\n", applied: true),
        line(keysURL, 4, "alt+left=esc:b", applied: true),
        line(configURL, 20, "super+d=new_split:right", reason: .appAction),
        line(keysURL, 7, "ctrl+shift+x=new_spilt:right", rejection: "keybind: invalid action \"new_spilt\""),
        line(configURL, 21, "super+r=text:reload", applied: true),
        line(configURL, 22, "super+k=text:clear", applied: true),
        // 6: replaced by 7.
        line(configURL, 23, "ctrl+a=text:x", reason: .replaced(byLine: 7)),
        line(keysURL, 12, "ctrl+a=csi:A", applied: true),
        line(configURL, 24, "ctrl+b=new_tab", reason: .appAction),
        // 9: cleared by 10, which binds nothing.
        line(configURL, 25, "ctrl+c=text:c", reason: .cleared(byLine: 10)),
        line(configURL, 26, "clear"),
        // 11 and its chain= lines.
        line(configURL, 27, "ctrl+d=text:d", applied: true),
        line(configURL, 28, "chain=csi:B", applied: true),
        line(configURL, 29, "chain=nope", rejection: "keybind: invalid value"),
        UserGhosttyKeyboardConfig.Line(file: configURL, line: 30, key: "macos-option-as-alt", value: "left", isApplied: true),
    ],
    added: [("keybind", "shift+tab=csi:Z")]
)

@Test func settingsWindowShortcutsBindingRowsSayWhatHappensToEachLine() throws {
    let rows = ShortcutsSettings.bindingRows(reading)
    #expect(rows.map(\.keysText) == ["⇧↩", "⌥←", "⌘D", "⌃⇧X", "⌘R", "⌘K", "⌃A", "⌃A", "⌃B", "⌃C", "⌃D", "⇧⇥"])
    #expect(rows.map(\.state.text) == [
        "Applied", "Applied", "Not applied", "Left out", "Applied", "Applied",
        "Not applied", "Applied", "Not applied", "Not applied", "Applied", "Applied",
    ])

    // The bindings' rows.
    #expect(rows[0].actions == ["text:\\n"])
    #expect(rows[0].notes.isEmpty)
    #expect(rows[0].id == "\(keysURL.path):2")
    #expect(!rows[0].offersEdit)
    #expect(rows[1].actions == ["esc:b"])
    #expect(rows[2].notes == [.init(text: "Cherry takes ⌘D first, so this binding never runs.", isWarning: true)])
    #expect(rows[2].offersEdit)
    #expect(rows[3].notes == [.init(text: "Left out. Ghostty: invalid action \"new_spilt\"", isWarning: true)])
    #expect(rows[3].offersEdit)
    #expect(rows[3].trigger == "ctrl+shift+x")

    // A binding on a key only the menus have runs while a terminal has
    // focus; ⌘K the terminal takes itself, first.
    #expect(rows[4].notes == [.init(text: "While a terminal has focus this binding runs instead of Restart Tab.")])
    #expect(rows[5].notes == [.init(text: "Cherry takes ⌘K first, so this binding never runs.", isWarning: true)])

    // Why a line Ghostty accepts is not applied.
    #expect(rows[6].notes == [.init(text: "Replaced by keys.conf, line 12.")])
    #expect(rows[8].notes == [.init(text: "An app action, which stays Cherry's.")])
    #expect(rows[9].notes == [.init(text: "Cleared by keybind = clear in config, line 26.")])

    // chain= lines go with the binding before them; one Ghostty rejects
    // says so.
    #expect(rows[10].actions == ["text:d", "csi:B"])
    #expect(rows[10].notes == [.init(text: "Its chain= line is left out (config, line 29). Ghostty: invalid value", isWarning: true)])

    // Cherry's own Shift+Tab, last, applied while Cherry adds it.
    let own = try #require(rows.last)
    #expect(own.line == nil)
    #expect(own.chips == [["⇧", "⇥"]])
    #expect(own.actions == ["csi:Z"])
    #expect(own.notes == [.init(text: "Cherry's own. Replaced when your Ghostty config binds Shift+Tab.")])
    #expect(!own.offersEdit)
    var replaced = reading
    replaced.added = [("macos-option-as-alt", "true")]
    #expect(ShortcutsSettings.bindingRows(replaced).last?.state == .notApplied)
    // It is what the parser adds while nothing binds Shift+Tab.
    #expect(TerminalSettings.parseUserGhosttyKeyboardConfig("").contains {
        $0 == (ShortcutsSettings.cherrysOwnBinding.key, ShortcutsSettings.cherrysOwnBinding.value)
    })

    // An empty value clears too.
    #expect(ShortcutsSettings.notAppliedText(.cleared(byLine: 0), in: [line(configURL, 3, "")])
        == "Cleared by an empty keybind = in config, line 3.")

    // No reading (tests, or before Cherry read the files): Cherry's own
    // binding only, which its terminals take.
    let none = ShortcutsSettings.bindingRows(nil)
    #expect(none.map(\.keysText) == ["⇧⇥"])
    #expect(none.map(\.state) == [.applied])
}

@MainActor
@Test func settingsWindowShortcutsBindingRowsOfARealReading() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(".config/ghostty/config", """
    # Keys
    keybind = super+d=new_split:right

    keybind = shift+enter=text:\\n
    keybind = chain=csi:A
    keybind = ctrl+shift+x=new_spilt:right
    """)
    let rows = ShortcutsSettings.bindingRows(home.reading())

    #expect(rows.map(\.keysText) == ["⌘D", "⇧↩", "⌃⇧X", "⇧⇥"])
    #expect(rows.map(\.line?.line) == [2, 4, 6, nil])
    #expect(rows.map(\.state) == [.notApplied, .applied, .leftOut, .applied])
    #expect(rows[0].notes.map(\.text) == ["Cherry takes ⌘D first, so this binding never runs."])
    #expect(rows[1].actions == ["text:\\n", "csi:A"])
    let leftOut = try #require(rows[2].notes.first)
    #expect(leftOut.isWarning)
    #expect(leftOut.text.hasPrefix("Left out. Ghostty: "))
    #expect(!leftOut.text.contains("keybind:"))

    // A binding of Shift+Tab replaces Cherry's own.
    try home.write(".config/ghostty/config", "keybind = shift+tab=text:x\n")
    let replaced = ShortcutsSettings.bindingRows(home.reading())
    #expect(replaced.map(\.state) == [.applied, .notApplied])
}

@Test func settingsWindowShortcutsHideWhatTextBindingsType() throws {
    #expect(ShortcutsSettings.maskedPrefix(of: "text:hello") == "text:")
    #expect(ShortcutsSettings.maskedPrefix(of: "text:") == nil)
    #expect(ShortcutsSettings.maskedPrefix(of: "csi:Z") == nil)
    #expect(ShortcutsSettings.maskedPrefix(of: "esc:b") == nil)

    // Search finds a text binding by what it shows, never by what it hides.
    let row = try #require(ShortcutsSettings.bindingRows(reading).first { $0.trigger == "super+r" })
    #expect(ShortcutsSettings.matches(row, query: "text"))
    #expect(!ShortcutsSettings.matches(row, query: "reload"))
}

@Test @MainActor func settingsWindowShortcutsABindingsBadgeNamesItsLine() {
    let log = ShortcutsCallLog()
    let actions = SettingsActions(
        revealInFinder: { urls in log.calls.append("reveal \(urls.map(\.lastPathComponent))") },
        openTextFile: { url in log.calls.append("open \(url.lastPathComponent)") }
    )
    let state = ShortcutsSettings.source(of: reading.lines[0], homeDirectory: "/Users/someone", actions: actions)

    #expect(state.source == .ghosttyConfig(file: keysURL, line: 2))
    #expect(state.badgeText == "Ghostty config")
    #expect(state.lines == [
        SettingsSourceState.Line("Ghostty config", detail: "~/.config/ghostty/keys.conf, line 2", isInUse: true),
    ])
    #expect(state.rowReset == nil)
    #expect(state.buttons.map(\.title) == ["Edit in Ghostty Config", "Reveal in Finder"])
    for button in state.buttons {
        button.perform()
    }
    #expect(log.calls == ["open keys.conf", "reveal [\"keys.conf\"]"])
}

// MARK: - Search on the page and Record

@Test func settingsWindowShortcutsSearchFindsActionsByNameOrKeys() throws {
    func titles(_ query: String) -> [String] {
        ShortcutsSettings.listRows.filter { ShortcutsSettings.matches($0, query: query) }.map(\.title)
    }

    #expect(titles("").count == ShortcutsSettings.listRows.count)
    #expect(titles("⇧⌘D") == ["Split Right"])
    #expect(titles("⌘D") == ["Detach Tab"])
    #expect(titles(" ⌘ d ") == ["Detach Tab"])
    #expect(titles("⌘5") == ["Go to Sidebar Item 1–9"])
    #expect(titles("⌥⌘↓") == ["Previous Tab / Next Tab"])
    #expect(titles("next") == ["Previous Tab / Next Tab", "Previous Pane / Next Pane", "Find Next / Find Previous"])
    #expect(titles("omni") == ["Omni Bar"])
    #expect(titles("⌃⌘Z").isEmpty)
    // Keys as a Ghostty trigger writes them, by any of its spellings.
    #expect(titles("super+d") == ["Detach Tab"])
    #expect(titles("cmd + shift + d") == ["Split Right"])
    #expect(titles("super+key_d") == ["Detach Tab"])
    #expect(titles("cmd+alt+down") == ["Previous Tab / Next Tab"])
    #expect(titles("super+comma") == ["Settings"])
    #expect(titles("ctrl+super+z").isEmpty)

    let rows = ShortcutsSettings.bindingRows(reading)
    func keys(_ query: String) -> [String] {
        rows.filter { ShortcutsSettings.matches($0, query: query) }.map(\.keysText)
    }
    #expect(keys("⇧↩") == ["⇧↩"])
    #expect(keys("⌃A") == ["⌃A", "⌃A"])
    #expect(keys("esc") == ["⌥←"])
    #expect(keys("shift+enter") == ["⇧↩"])
    #expect(keys("shift+ctrl+x") == ["⌃⇧X"])
    #expect(keys("cmd+d") == ["⌘D"])
    #expect(keys("csi:Z") == ["⇧⇥"])
}

@Test @MainActor func settingsWindowShortcutsSearchShowsWhatALinkOpens() {
    let model = ShortcutsPageModel(reading: nil, capture: SettingsKeyCapture())
    model.query = "⌘D"
    #expect(model.visibleListRows.map(\.title) == ["Detach Tab"])
    #expect(model.visibleBindingRows.isEmpty)

    // A row the search shows stays as it is.
    model.reveal("shortcuts.detachTab")
    #expect(model.query == "⌘D")
    // Rows of other pages are no business of it.
    model.reveal(.terminalKeyBindings)
    #expect(model.query == "⌘D")
    // Show in Shortcuts opens the bindings, which the search hides: it ends.
    model.reveal(.shortcutsTerminalKeyBindings)
    #expect(model.query == "")
    #expect(model.visibleBindingRows.count == 1)

    model.query = "⌘D"
    model.reveal("shortcuts.splitRight")
    #expect(model.query == "")
}

@Test @MainActor func settingsWindowShortcutsRecordPutsTheNextKeyInTheSearch() throws {
    let capture = SettingsKeyCapture()
    let model = ShortcutsPageModel(reading: nil, capture: capture)
    var performed: [SettingsKeyMonitor.Action] = []

    #expect(capture.handler == nil)
    model.setRecording(true)
    #expect(model.isRecording)
    #expect(capture.handler != nil)

    // The key goes no further: not even ⌘[ (Back) or ⌘W.
    #expect(SettingsKeyMonitor.handle(try keyDown("D", modifiers: [.command, .shift]), inSettingsWindow: true, capture: capture) {
        performed.append($0)
    })
    #expect(performed.isEmpty)
    #expect(model.query == CherryShortcut.splitRight.display)
    #expect(model.visibleListRows.map(\.title) == ["Split Right"])
    // One key: Record stops and lets go of the capture.
    #expect(!model.isRecording)
    #expect(capture.handler == nil)
    #expect(SettingsKeyMonitor.handle(try keyDown("["), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(performed == [.goBack])

    model.setRecording(true)
    #expect(SettingsKeyMonitor.handle(try keyDown("["), inSettingsWindow: true, capture: capture) { performed.append($0) })
    #expect(performed == [.goBack])
    #expect(model.query == "⌘[")

    // An arrow by its key code.
    model.startRecording()
    #expect(capture.take(try keyDown("\u{F700}", modifiers: [.command, .option, .numericPad, .function], keyCode: kVK_UpArrow)))
    #expect(model.query == CherryShortcut.previousTab.display)

    // Escape stops without searching.
    model.startRecording()
    #expect(capture.take(try keyDown("\u{1B}", modifiers: [], keyCode: kVK_Escape)))
    #expect(model.query == CherryShortcut.previousTab.display)
    #expect(!model.isRecording)
    #expect(capture.handler == nil)

    // The toggle, and the page going away, stop it; a capture it does not
    // hold is left alone.
    model.setRecording(true)
    model.setRecording(false)
    #expect(capture.handler == nil)
    capture.handler = { _ in true }
    model.stopRecording()
    #expect(capture.handler != nil)
    #expect(!model.record(try keyDown("a", modifiers: [])))
}

@Test func settingsWindowShortcutsRecordWritesKeysAsMenusDo() {
    func display(_ characters: String?, _ modifiers: NSEvent.ModifierFlags, keyCode: Int = 0) -> String? {
        ShortcutsSettings.display(charactersIgnoringModifiers: characters, keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    #expect(display("D", [.command, .shift]) == "⇧⌘D")
    #expect(display("d", [.command]) == CherryShortcut.detachTab.display)
    #expect(display(",", [.command]) == CherryShortcut.settings.display)
    #expect(display("k", [.command, .shift, .option, .control, .capsLock]) == "⌃⌥⇧⌘K")
    #expect(display("\r", [.shift], keyCode: kVK_Return) == "⇧↩")
    #expect(display("\t", [.shift], keyCode: kVK_Tab) == "⇧⇥")
    #expect(display("\u{F708}", [.function], keyCode: kVK_F5) == "F5")
    #expect(display("\u{F700}", [.command, .option, .numericPad, .function], keyCode: kVK_UpArrow) == "⌥⌘↑")
    // A key with nothing to show.
    #expect(display("\u{F72D}", [.function], keyCode: 0) == nil)
    #expect(display(nil, [.command]) == nil)
    #expect(ShortcutsSettings.isEscape(keyCode: UInt16(kVK_Escape), modifiers: []))
    #expect(!ShortcutsSettings.isEscape(keyCode: UInt16(kVK_Escape), modifiers: [.option]))
}

// MARK: - Settings search

@MainActor
private func shortcutsSearchContext(_ name: String, ghostty: UserGhosttyKeyboardConfig?) -> SettingsSearchContext {
    let defaults = privateDefaults(name)
    return SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: AgentSettings(defaults: defaults),
        ghostty: ghostty,
        defaults: defaults
    )
}

@Test @MainActor func settingsWindowShortcutsSearchFindsEveryActionAndItsKeys() throws {
    let rows = SettingsSearchIndex.rows(in: shortcutsSearchContext("SettingsWindowShortcutsSearch", ghostty: nil))
    func results(_ query: String) -> [SettingsSearchResult] {
        SettingsSearchIndex.groups(for: query, in: rows).first { $0.kind == .page(.shortcuts) }?.results ?? []
    }

    let pageRows = ShortcutsSettingsPage.searchRows(in: shortcutsSearchContext("SettingsWindowShortcutsRows", ghostty: nil))
    #expect(pageRows.map(\.id) == ShortcutsSettings.listRows.map(\.id) + [.shortcutsTerminalKeyBindings])
    #expect(pageRows.allSatisfy { $0.route == .page(.shortcuts) })

    let split = try #require(results("split").first { $0.id == "shortcuts.splitRight" })
    #expect(split.row.detail == "Panes · ⇧⌘D")
    #expect(results("⇧⌘D").map(\.id) == ["shortcuts.splitRight"])
    #expect(results("command d").map(\.id).first == "shortcuts.detachTab")
    #expect(results("next pane").map(\.id) == ["shortcuts.previousPane"])
    #expect(results("close").map(\.id).contains("shortcuts.closeTab"))
    #expect(results("super+d").map(\.id).contains("shortcuts.detachTab"))
    #expect(rows.first { $0.id == "shortcuts.sidebarItem1" }?.detail == "Tabs and windows · ⌘1 … ⌘9")
    // The page itself, by its words.
    #expect(results("hotkey").first?.row.opensPage == true)
}

@Test @MainActor func settingsWindowShortcutsGhosttyFindsTerminalsRowsAndTheKeyBindingsTogether() throws {
    let home = try TemporaryHome()
    defer { home.remove() }
    try home.write(".config/ghostty/config", "macos-option-as-alt = left\nkeybind = shift+enter=text:\\n\n")
    let rows = SettingsSearchIndex.rows(in: shortcutsSearchContext("SettingsWindowShortcutsGhostty", ghostty: home.reading()))
    let groups = SettingsSearchIndex.groups(for: "ghostty", in: rows)

    let terminal = try #require(groups.first { $0.kind == .page(.terminal) })
    #expect(terminal.results.map(\.id).contains(.terminalKeyBindings))
    #expect(terminal.results.map(\.id).contains(.terminalOptionKey))
    let shortcuts = try #require(groups.first { $0.kind == .page(.shortcuts) })
    // First, by its second line; then Detach Tab, whose note names
    // Ghostty's own ⌘D.
    #expect(shortcuts.results.map(\.id) == [.shortcutsTerminalKeyBindings, "shortcuts.detachTab"])
    let keyBindings = try #require(shortcuts.results.first)
    #expect(keyBindings.row.title == "Terminal key bindings")
    #expect(keyBindings.row.detail == "From your Ghostty config")
    // Its second line is what matched: bold there.
    #expect(keyBindings.titleIndices.isEmpty)
    #expect(!keyBindings.detailIndices.isEmpty)
    // In the sidebar's order: Terminal before Shortcuts.
    let kinds = groups.map(\.kind)
    #expect(try #require(kinds.firstIndex(of: .page(.terminal))) < #require(kinds.firstIndex(of: .page(.shortcuts))))
}
