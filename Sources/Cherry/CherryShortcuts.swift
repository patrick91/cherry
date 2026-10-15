import SwiftUI

/// Cherry's keyboard shortcuts, in one table: the app's menus
/// take their keys from it, the Omni bar its labels, and Settings ›
/// Shortcuts lists it as it is. Which key a press in a project window is,
/// and when, stays `AppShortcutMonitor.shortcutAction`'s (it knows whether
/// a text view has the keyboard and whether the Omni bar is open); tests
/// hold the two together.
struct CherryShortcut: Identifiable, Equatable, Sendable {
    /// Where Settings › Shortcuts lists it.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case tabsAndWindows = "Tabs and windows"
        case panes = "Panes"
        case terminal = "Terminal"
        case cherry = "Cherry"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    /// Who takes the key, which decides whether a Ghostty binding of it
    /// can run. A key press in a project window goes to its key monitor
    /// first, then to the focused terminal, which runs a Ghostty binding of
    /// the key (`AppTerminalView.performKeyEquivalent`), then to the app's
    /// menus.
    enum Taker: Equatable, Sendable {
        /// The project window's key monitor (`AppShortcutMonitor`), before
        /// the terminal sees the key.
        case monitor
        /// The app's menus, after the terminal: while a terminal has focus a
        /// Ghostty binding of the key runs instead.
        case menu
        /// The project window's key monitor, and a menu item elsewhere.
        case both
        /// The terminal itself, before its bindings
        /// (`GhosttySessionBridge.terminalShouldHandleKeyEquivalent`), and a
        /// menu item elsewhere.
        case terminal

        /// Whether Cherry has the key before a Ghostty binding of it can
        /// run, so such a binding never does.
        var takesKeyBeforeTerminal: Bool {
            self != .menu
        }
    }

    /// Its name in Settings ("splitRight"): a row's id is "shortcuts.<id>".
    var id: String
    var title: String
    var group: Group
    var key: KeyEquivalent
    var modifiers: EventModifiers
    /// What Settings says under it: "Only while no text field has focus."
    var note: String?
    var taker: Taker

    init(
        _ id: String,
        _ title: String,
        group: Group,
        key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        note: String? = nil,
        taker: Taker
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.key = key
        self.modifiers = modifiers
        self.note = note
        self.taker = taker
    }

    /// What a menu item takes.
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }

    /// Its modifiers' glyphs in the order menus write them (⌃⌥⇧⌘), then
    /// its key: ["⇧", "⌘", "D"].
    var keycaps: [String] {
        Self.glyphs(of: modifiers) + [Self.glyph(of: key)]
    }

    /// As menus write it: "⇧⌘D".
    var display: String {
        keycaps.joined()
    }

    /// How a Ghostty `keybind` line names this key, as
    /// `TerminalSettings.keybindSteps` spells a trigger: "shift+super+d".
    var ghosttyTrigger: String {
        Self.ghosttyTrigger(modifiers: modifiers, keyName: Self.ghosttyKeyName(of: key))
    }

    /// The triggers a Ghostty `keybind` line can bind this key with: by its
    /// character ("super+d") and by its physical key on a US layout
    /// ("super+key_d"), which the same press fires.
    var ghosttyTriggers: Set<String> {
        var triggers: Set<String> = [ghosttyTrigger]
        if let physical = Self.ghosttyPhysicalKeyName(of: key) {
            triggers.insert(Self.ghosttyTrigger(modifiers: modifiers, keyName: physical))
        }
        return triggers
    }

    // MARK: Glyphs

    /// The glyphs of `modifiers`, in the order menus write them.
    static func glyphs(of modifiers: EventModifiers) -> [String] {
        let glyphs: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1)
    }

    /// A key as menus show it: a letter in upper case, an arrow as its
    /// arrow.
    static func glyph(of key: KeyEquivalent) -> String {
        let named: [(KeyEquivalent, String)] = [
            (.upArrow, "↑"), (.downArrow, "↓"), (.leftArrow, "←"), (.rightArrow, "→"), (.return, "↩"),
            (.tab, "⇥"), (.delete, "⌫"), (.deleteForward, "⌦"), (.escape, "⎋"), (.space, "␣"),
            (.home, "↖"), (.end, "↘"), (.pageUp, "⇞"), (.pageDown, "⇟"),
        ]
        return named.first { $0.0 == key }?.1 ?? String(key.character).uppercased()
    }

    // MARK: Ghostty's names

    private static func ghosttyTrigger(modifiers: EventModifiers, keyName: String) -> String {
        let names: [(EventModifiers, String)] = [
            (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "super"),
        ]
        let parts = names.filter { modifiers.contains($0.0) }.map(\.1) + [keyName]
        return TerminalSettings.keybindSteps(parts.joined(separator: "+")).first ?? ""
    }

    private static func ghosttyKeyName(of key: KeyEquivalent) -> String {
        let named: [(KeyEquivalent, String)] = [
            (.upArrow, "up"), (.downArrow, "down"), (.leftArrow, "left"), (.rightArrow, "right"),
            (.return, "enter"), (.tab, "tab"), (.delete, "backspace"), (.deleteForward, "delete"),
            (.escape, "escape"), (.space, "space"), (.home, "home"), (.end, "end"),
            (.pageUp, "page_up"), (.pageDown, "page_down"),
        ]
        return named.first { $0.0 == key }?.1 ?? String(key.character).lowercased()
    }

    /// The physical key that types `key` on a US layout, by Ghostty's name
    /// for it; nil where that is its name already (an arrow).
    private static func ghosttyPhysicalKeyName(of key: KeyEquivalent) -> String? {
        let character = String(key.character).lowercased()
        if character.count == 1, let scalar = character.unicodeScalars.first, scalar.isASCII {
            if CharacterSet.lowercaseLetters.contains(scalar) { return "key_\(character)" }
            if CharacterSet.decimalDigits.contains(scalar) { return "digit_\(character)" }
        }
        return ["[": "bracket_left", "]": "bracket_right", ",": "comma"][character]
    }
}

// MARK: - The table

extension CherryShortcut {
    // Tabs and windows
    static let newWindow = CherryShortcut("newWindow", "New Window", group: .tabsAndWindows, key: "n", taker: .both)
    static let newTab = CherryShortcut("newTab", "New Tab", group: .tabsAndWindows, key: "t", taker: .both)
    static let closeTab = CherryShortcut(
        "closeTab", "Close Tab", group: .tabsAndWindows, key: "w",
        note: "Asks first when a program is at work.", taker: .both
    )
    static let detachTab = CherryShortcut(
        "detachTab", "Detach Tab", group: .tabsAndWindows, key: "d",
        note: "Ghostty's own ⌘D (split) never reaches the terminal.", taker: .both
    )
    /// Edit › Undo, and the key monitor while no text view has the
    /// keyboard.
    static let undoCloseTab = CherryShortcut(
        "undoCloseTab", "Undo Close Tab", group: .tabsAndWindows, key: "z",
        note: "Only while no text field has focus.", taker: .both
    )
    static let restartTab = CherryShortcut("restartTab", "Restart Tab", group: .tabsAndWindows, key: "r", taker: .menu)
    /// The key monitor takes ⌥⌘↑ and ⌥⌘↓ by their key codes (it goes through
    /// the sidebar's items), not through `AppShortcutMonitor.shortcutAction`.
    static let previousTab = CherryShortcut(
        "previousTab", "Previous Tab", group: .tabsAndWindows, key: .upArrow, modifiers: [.command, .option], taker: .both
    )
    static let nextTab = CherryShortcut(
        "nextTab", "Next Tab", group: .tabsAndWindows, key: .downArrow, modifiers: [.command, .option], taker: .both
    )
    /// ⌘1 to ⌘9: the key monitor's only.
    static let sidebarItems: [CherryShortcut] = (1...9).map { number in
        CherryShortcut(
            "sidebarItem\(number)", "Go to Sidebar Item \(number)", group: .tabsAndWindows,
            key: KeyEquivalent(Character("\(number)")),
            note: "Tabs, commands and the to-do board, in sidebar order.", taker: .monitor
        )
    }
    static let hideSidebar = CherryShortcut("hideSidebar", "Hide Sidebar", group: .tabsAndWindows, key: "s", taker: .both)

    // Panes
    static let splitRight = CherryShortcut(
        "splitRight", "Split Right", group: .panes, key: "d", modifiers: [.command, .shift], taker: .both
    )
    static let previousPane = CherryShortcut("previousPane", "Previous Pane", group: .panes, key: "[", taker: .both)
    static let nextPane = CherryShortcut("nextPane", "Next Pane", group: .panes, key: "]", taker: .both)

    // Terminal
    static let find = CherryShortcut("find", "Find", group: .terminal, key: "f", taker: .menu)
    static let findNext = CherryShortcut("findNext", "Find Next", group: .terminal, key: "g", taker: .menu)
    static let findPrevious = CherryShortcut(
        "findPrevious", "Find Previous", group: .terminal, key: "g", modifiers: [.command, .shift], taker: .menu
    )
    static let hideFindBar = CherryShortcut(
        "hideFindBar", "Hide Find Bar", group: .terminal, key: "f", modifiers: [.command, .shift], taker: .menu
    )
    /// The terminal's own ⌘K; the key monitor's while the Omni bar is open.
    static let clearScrollback = CherryShortcut(
        "clearScrollback", "Clear Scrollback", group: .terminal, key: "k",
        note: "While the Omni bar is open, ⌘K shows its actions instead.", taker: .terminal
    )

    // Cherry
    static let omniBar = CherryShortcut("omniBar", "Omni Bar", group: .cherry, key: "p", taker: .both)
    static let openProject = CherryShortcut("openProject", "Open Project…", group: .cherry, key: "o", taker: .both)
    static let persistentSessions = CherryShortcut(
        "persistentSessions", "Persistent Sessions…", group: .cherry, key: "r", modifiers: [.command, .shift], taker: .menu
    )
    /// The app menu's Settings… and the key monitor.
    static let settings = CherryShortcut("settings", "Settings", group: .cherry, key: ",", taker: .both)
    /// The app menu's Quit and the key monitor.
    static let quit = CherryShortcut("quit", "Quit", group: .cherry, key: "q", taker: .both)

    /// Every shortcut, in Settings › Shortcuts' order.
    static let all: [CherryShortcut] = [
        newWindow, newTab, closeTab, detachTab, undoCloseTab, restartTab, previousTab, nextTab,
    ] + sidebarItems + [
        hideSidebar,
        splitRight, previousPane, nextPane,
        find, findNext, findPrevious, hideFindBar, clearScrollback,
        omniBar, openProject, persistentSessions, settings, quit,
    ]
}
