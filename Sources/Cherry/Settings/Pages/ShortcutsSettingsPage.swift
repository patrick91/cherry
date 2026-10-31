import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings › Shortcuts, read-only in v1: the keys Cherry takes
/// before the terminal sees them (`CherryShortcut`), and the terminal's key
/// bindings from the user's Ghostty config, as Cherry read it when it
/// opened. The search field narrows both lists, by name or by keys; Record
/// fills it with the next key pressed, which `SettingsKeyCapture` takes
/// before the window and the menus do.
struct ShortcutsSettingsPage: View, SettingsPageContent {
    @StateObject private var model: ShortcutsPageModel
    /// For paths shown with "~".
    private let homeDirectory: String

    @Environment(\.settingsActions) private var actions
    @Environment(\.settingsRowHighlight) private var highlight

    /// `reading`: what Cherry read of the user's Ghostty config when it
    /// opened, which its terminals use until it quits; nil in tests, which
    /// see Cherry's own binding only. `capture`: tests pass their own.
    init(
        reading: UserGhosttyKeyboardConfig? = TerminalSettings.nativeUserKeyboardConfigReading,
        capture: SettingsKeyCapture = .shared,
        homeDirectory: String = NSHomeDirectory()
    ) {
        _model = StateObject(wrappedValue: ShortcutsPageModel(reading: reading, capture: capture))
        self.homeDirectory = homeDirectory
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.shortcuts.title) {
            searchBar
            SettingsCaption(Self.intro)

            let listRows = model.visibleListRows
            ForEach(CherryShortcut.Group.allCases) { group in
                let rows = listRows.filter { $0.group == group }
                if !rows.isEmpty {
                    SettingsSection(group.title) {
                        ForEach(rows) { row in
                            listRow(row)
                        }
                    }
                }
            }

            let bindingRows = model.visibleBindingRows
            if !bindingRows.isEmpty {
                SettingsSection("Terminal key bindings", intro: Self.keyBindingsIntro, id: .shortcutsTerminalKeyBindings) {
                    ForEach(bindingRows) { row in
                        bindingRow(row)
                    }
                }
            }

            if listRows.isEmpty, bindingRows.isEmpty {
                SettingsEmptyState(
                    title: "No shortcuts match “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))”",
                    message: Self.noMatchMessage,
                    systemImage: "magnifyingglass"
                )
            }
        }
        .background {
            if let highlight {
                ShortcutsFlashFollower(highlight: highlight) { row in
                    model.reveal(row)
                }
            }
        }
        .onDisappear {
            model.stopRecording()
        }
    }

    // MARK: Search and Record

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search actions or keys", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onExitCommand { model.query = "" }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(SettingsDesign.Colors.fill2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Toggle(isOn: Binding(get: { model.isRecording }, set: { model.setRecording($0) })) {
                Label("Record", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .help(Self.recordHelp)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Cherry's keys

    private func listRow(_ row: ShortcutsSettings.ListRow) -> some View {
        SettingsListItem(id: row.id) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(SettingsDesign.Fonts.rowTitle)
                if let note = row.note {
                    Text(note)
                        .font(SettingsDesign.Fonts.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } trailing: {
            SettingsKeycaps(chips: row.chips, separator: row.separator)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spokenKeys)
        }
    }

    // MARK: Terminal key bindings

    private func bindingRow(_ row: ShortcutsSettings.BindingRow) -> some View {
        SettingsListItem {
            HStack(alignment: .center, spacing: 12) {
                SettingsKeycaps(chips: row.chips, separator: "›")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let action = row.actions.first {
                            ShortcutsBindingAction(action: action)
                        }
                        if let line = row.line {
                            let source = ShortcutsSettings.source(of: line, homeDirectory: homeDirectory, actions: actions)
                            SettingsSourceBadge(state: source, title: row.keysText)
                        }
                    }
                    ForEach(Array(row.actions.dropFirst().enumerated()), id: \.offset) { _, action in
                        HStack(spacing: 0) {
                            Text("chain=")
                                .font(SettingsDesign.Fonts.mono)
                                .foregroundStyle(.secondary)
                            ShortcutsBindingAction(action: action)
                        }
                    }
                    ForEach(row.notes) { note in
                        Text(note.text)
                            .font(SettingsDesign.Fonts.help)
                            .foregroundStyle(
                                note.isWarning ? AnyShapeStyle(SettingsDesign.Colors.warningText) : AnyShapeStyle(.secondary)
                            )
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } trailing: {
            bindingStatus(row.state)
            if row.offersEdit, let line = row.line {
                Button("Edit in Ghostty Config") {
                    actions.openTextFile(line.file)
                }
                .settingsButton(size: .small)
            }
        }
    }

    @ViewBuilder
    private func bindingStatus(_ state: ShortcutsSettings.BindingRow.State) -> some View {
        switch state {
        case .applied: SettingsStatusText(state.text, style: .ok, dot: .green)
        case .notApplied: SettingsStatusText(state.text, dot: .gray)
        case .leftOut: SettingsStatusText(state.text, style: .warning, dot: .yellow)
        }
    }

    // MARK: Texts

    static let intro = "Cherry takes these keys before the terminal sees them. "
        + "Every other key goes to the program in the tab."
    static let keyBindingsIntro = "From your Ghostty config. Cherry's terminals use text:, csi:, esc: and ignore bindings; "
        + "app actions stay Cherry's."
    static let recordHelp = "Press a key to search by shortcut"
    static let noMatchMessage = "Search looks at the actions and their keys, and at your terminal key bindings."

    // MARK: Search

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        ShortcutsSettings.listRows.map { row in
            SettingsSearchRow(
                id: row.id,
                route: .page(.shortcuts),
                section: row.group.title,
                title: row.title,
                help: row.note,
                keywords: row.searchKeywords,
                value: row.keysText
            )
        } + [
            SettingsSearchRow(
                id: .shortcutsTerminalKeyBindings,
                route: .page(.shortcuts),
                section: "",
                title: "Terminal key bindings",
                help: keyBindingsIntro,
                keywords: ["ghostty", "keybind", "key binding"],
                value: "From your Ghostty config"
            ),
        ]
    }
}

// MARK: - Page model

/// Settings › Shortcuts' search and Record. Record hands the page's key
/// capture (`SettingsKeyCapture`) a handler while it is on, and takes it
/// back when it stops or the page goes away.
@MainActor
final class ShortcutsPageModel: ObservableObject {
    /// The search field: an action's name, or keys as menus write them
    /// ("⇧⌘D", what Record puts there).
    @Published var query = ""
    /// Whether the next key pressed goes into the search field.
    @Published private(set) var isRecording = false
    /// Terminal key bindings: those of the reading Cherry took when it
    /// opened, which does not change until it quits.
    let bindingRows: [ShortcutsSettings.BindingRow]

    private let capture: SettingsKeyCapture
    private var holdsCapture = false

    init(reading: UserGhosttyKeyboardConfig?, capture: SettingsKeyCapture) {
        bindingRows = ShortcutsSettings.bindingRows(reading)
        self.capture = capture
    }

    /// Cherry's keys that match the search.
    var visibleListRows: [ShortcutsSettings.ListRow] {
        ShortcutsSettings.listRows.filter { ShortcutsSettings.matches($0, query: query) }
    }

    /// The terminal key bindings that match the search.
    var visibleBindingRows: [ShortcutsSettings.BindingRow] {
        bindingRows.filter { ShortcutsSettings.matches($0, query: query) }
    }

    /// The Record toggle.
    func setRecording(_ isOn: Bool) {
        if isOn { startRecording() } else { stopRecording() }
    }

    /// Record on: the key capture hands this model the next key pressed
    /// in the Settings window (`record`).
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        holdsCapture = true
        capture.handler = { [weak self] event in
            self?.record(event) ?? false
        }
    }

    /// Stops Record and lets go of the key capture: the toggle, Escape, a
    /// key recorded, the page going away.
    func stopRecording() {
        if isRecording { isRecording = false }
        if holdsCapture {
            capture.handler = nil
            holdsCapture = false
        }
    }

    /// A key pressed while Record is on: Escape stops it; any other key's
    /// shortcut goes into the search field and stops it. The key goes no
    /// further (true), not even ⌘W or ⌘Q.
    func record(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if !ShortcutsSettings.isEscape(keyCode: event.keyCode, modifiers: event.modifierFlags),
           let display = ShortcutsSettings.display(
               charactersIgnoringModifiers: event.charactersIgnoringModifiers,
               keyCode: event.keyCode,
               modifiers: event.modifierFlags
           ) {
            query = display
        }
        stopRecording()
        return true
    }

    /// A link or a search result opened `row`: the search ends if it hides
    /// the row, so the page can show it.
    func reveal(_ row: SettingsRowID) {
        guard !query.isEmpty else { return }
        let isHidden = if row == .shortcutsTerminalKeyBindings {
            visibleBindingRows.isEmpty
        } else {
            ShortcutsSettings.listRows.contains { $0.id == row } && !visibleListRows.contains { $0.id == row }
        }
        if isHidden { query = "" }
    }
}

/// Tells the page about each row flash (`SettingsRowHighlight`), so a
/// search on the page does not hide the row a link or a result opened.
private struct ShortcutsFlashFollower: View {
    @ObservedObject var highlight: SettingsRowHighlight
    let reveal: (SettingsRowID) -> Void

    var body: some View {
        Color.clear
            .onChange(of: highlight.generation) { _, _ in
                if let row = highlight.row { reveal(row) }
            }
    }
}

/// A binding's action in mono. What a `text:` binding types is hidden as
/// "•••" until Show.
private struct ShortcutsBindingAction: View {
    let action: String

    @State private var showsText = false

    var body: some View {
        HStack(spacing: 6) {
            if let shown = ShortcutsSettings.maskedPrefix(of: action), !showsText {
                HStack(spacing: 0) {
                    Text(shown)
                    Text("•••")
                        .accessibilityLabel("Hidden text")
                }
                .font(SettingsDesign.Fonts.mono)
                SettingsLinkButton("Show") { showsText = true }
                    .accessibilityLabel("Show the text this binding types")
            } else {
                Text(action)
                    .font(SettingsDesign.Fonts.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if ShortcutsSettings.maskedPrefix(of: action) != nil {
                    SettingsLinkButton("Hide") { showsText = false }
                        .accessibilityLabel("Hide the text this binding types")
                }
            }
        }
    }
}

// MARK: - Rows

/// What Settings › Shortcuts lists, as pure functions of the catalog
/// (`CherryShortcut`) and of a reading of the user's Ghostty config
/// (`UserGhosttyKeyboardConfig`).
enum ShortcutsSettings {
    /// A row of Cherry's keys: one shortcut, two that go together
    /// ("Previous Pane / Next Pane", ⌘[ / ⌘]) or a run (Go to Sidebar Item
    /// 1–9, ⌘1 … ⌘9).
    struct ListRow: Identifiable, Equatable, Sendable {
        var title: String
        /// Its shortcuts, in the catalog's order; never empty.
        var shortcuts: [CherryShortcut]
        /// A run shows its first and last keys.
        var isRun = false

        static func one(_ shortcut: CherryShortcut) -> ListRow {
            ListRow(title: shortcut.title, shortcuts: [shortcut])
        }

        static func pair(_ first: CherryShortcut, _ second: CherryShortcut) -> ListRow {
            ListRow(title: "\(first.title) / \(second.title)", shortcuts: [first, second])
        }

        static func run(_ shortcuts: [CherryShortcut], title: String) -> ListRow {
            ListRow(title: title, shortcuts: shortcuts, isRun: true)
        }

        /// "shortcuts.<its first shortcut's id>".
        var id: SettingsRowID {
            SettingsRowID(rawValue: "shortcuts.\(shortcuts[0].id)")
        }

        var group: CherryShortcut.Group {
            shortcuts[0].group
        }

        var note: String? {
            shortcuts[0].note
        }

        /// One keycap chip per shortcut; a run's first and last.
        var chips: [[String]] {
            let shown = isRun ? [shortcuts[0], shortcuts[shortcuts.count - 1]] : shortcuts
            return shown.map(\.keycaps)
        }

        /// Between the chips: "/" for a pair, "…" for a run.
        var separator: String {
            isRun ? "…" : "/"
        }

        /// "⌘[ / ⌘]", "⌘1 … ⌘9".
        var keysText: String {
            chips.map { $0.joined() }.joined(separator: " \(separator) ")
        }

        /// What VoiceOver reads for its keys: "Command Left Bracket or
        /// Command Right Bracket", "Command 1 to Command 9".
        var spokenKeys: String {
            guard isRun else {
                return SettingsKeycaps.accessibilityLabel(chips: chips, separator: separator)
            }
            return chips.map(SettingsKeycaps.spokenName).joined(separator: " to ")
        }

        /// Words search finds it by besides its title: each shortcut's
        /// name, keys as menus and VoiceOver say them, and Ghostty's name
        /// for them ("shift+super+d").
        var searchKeywords: [String] {
            var words = shortcuts.count > 1 ? shortcuts.map(\.title) : []
            for shortcut in shortcuts {
                words += [shortcut.display, SettingsKeycaps.spokenName(for: shortcut.keycaps), shortcut.ghosttyTrigger]
            }
            return words
        }
    }

    /// Cherry's keys as the page lists them: every shortcut of the catalog,
    /// in its order.
    static let listRows: [ListRow] = [
        .one(.newWindow), .one(.newTab), .one(.newHomeTerminal), .one(.goHome),
        .one(.closeTab), .one(.detachTab), .one(.undoCloseTab), .one(.restartTab),
        .pair(.previousTab, .nextTab), .run(CherryShortcut.sidebarItems, title: "Go to Sidebar Item 1–9"),
        .one(.hideSidebar),
        .one(.splitRight), .pair(.previousPane, .nextPane),
        .one(.find), .pair(.findNext, .findPrevious), .one(.hideFindBar), .one(.clearScrollback),
        .one(.omniBar), .one(.openProject), .one(.persistentSessions), .one(.settings), .one(.quit),
    ]

    /// A terminal key binding: a `keybind` line of the user's Ghostty
    /// config (with the `chain=` lines after it), or Cherry's own binding.
    struct BindingRow: Identifiable, Equatable {
        enum State: Equatable {
            /// Cherry's terminals take it.
            case applied
            /// Ghostty accepts it, but Cherry's terminals leave it out: an
            /// app action, or a later line replaced or cleared it.
            case notApplied
            /// Ghostty rejects it.
            case leftOut

            var text: String {
                switch self {
                case .applied: "Applied"
                case .notApplied: "Not applied"
                case .leftOut: "Left out"
                }
            }
        }

        /// A line under its action: why it does not run, or what it runs
        /// instead of; `isWarning` in orange.
        struct Note: Identifiable, Equatable {
            var text: String
            var isWarning = false

            var id: String { text }
        }

        var id: String
        /// The line; nil for Cherry's own binding.
        var line: UserGhosttyKeyboardConfig.Line?
        /// As the line writes it: "ctrl+shift+x", "a>b".
        var trigger: String
        /// One chip per step of its trigger.
        var chips: [[String]]
        /// What it does: its action, then those of the `chain=` lines after
        /// it.
        var actions: [String]
        var state: State
        var notes: [Note] = []

        /// Its keys as menus write them, steps joined by "›": "⌃⇧X",
        /// "A›B". The badge's popover title.
        var keysText: String {
            chips.map { $0.joined() }.joined(separator: "›")
        }

        /// Edit in Ghostty Config, on a line Cherry's terminals do not take.
        var offersEdit: Bool {
            line != nil && state != .applied
        }
    }

    /// The binding Cherry adds while no line of the user's binds Shift+Tab
    /// (`TerminalSettings.parseUserGhosttyKeyboardConfig`).
    static let cherrysOwnBinding = (key: "keybind", value: "shift+tab=csi:Z")

    /// Terminal key bindings: one row per `keybind` line of `reading` that
    /// binds a key, in Ghostty's order (not `keybind = clear` or an empty
    /// `keybind =`; a `chain=` line goes with the binding before it), then
    /// Cherry's own Shift+Tab. Without a reading (tests), Cherry's own
    /// alone, which its terminals then take.
    static func bindingRows(_ reading: UserGhosttyKeyboardConfig?) -> [BindingRow] {
        let lines = reading?.lines ?? []
        var rows: [BindingRow] = []
        var latest: Int?
        for line in lines where line.key == "keybind" {
            guard !line.value.isEmpty, line.value != "clear" else {
                latest = nil
                continue
            }
            let parts = TerminalSettings.keybindParts(line.value)
            if parts?.trigger == "chain" {
                guard let latest, let action = parts?.action else { continue }
                if line.rejection != nil {
                    let reason = GhosttyConfigSettings.rejectionReason(of: line)
                    rows[latest].notes.append(BindingRow.Note(
                        text: "Its chain= line is left out (\(location(of: line))). Ghostty: \(reason)",
                        isWarning: true
                    ))
                } else {
                    rows[latest].actions.append(action)
                }
                continue
            }
            rows.append(bindingRow(line, trigger: parts?.trigger ?? line.value, action: parts?.action, in: lines))
            latest = rows.count - 1
        }

        let ownTrigger = TerminalSettings.keybindParts(cherrysOwnBinding.value)
        let isApplied = reading.map { reading in
            reading.added.contains { $0 == (cherrysOwnBinding.key, cherrysOwnBinding.value) }
        } ?? true
        rows.append(BindingRow(
            id: "cherry:\(cherrysOwnBinding.value)",
            line: nil,
            trigger: ownTrigger?.trigger ?? "",
            chips: TerminalSettings.keybindSteps(ownTrigger?.trigger ?? "").map(keycaps(ofStep:)),
            actions: [ownTrigger?.action ?? ""],
            state: isApplied ? .applied : .notApplied,
            notes: [BindingRow.Note(text: "Cherry's own. Replaced when your Ghostty config binds Shift+Tab.")]
        ))
        return rows
    }

    private static func bindingRow(
        _ line: UserGhosttyKeyboardConfig.Line,
        trigger: String,
        action: String?,
        in lines: [UserGhosttyKeyboardConfig.Line]
    ) -> BindingRow {
        let steps = TerminalSettings.keybindSteps(trigger)
        let state: BindingRow.State = if line.rejection != nil {
            .leftOut
        } else if line.isApplied {
            .applied
        } else {
            .notApplied
        }
        var note: BindingRow.Note?
        if state == .leftOut {
            let reason = GhosttyConfigSettings.LeftOutLine(line: line).reason
            note = BindingRow.Note(text: "Left out. \(reason)", isWarning: true)
        } else if let shortcut = steps.first.flatMap(shortcutTakenFirst) {
            note = BindingRow.Note(
                text: "Cherry takes \(shortcut.display) first, so this binding never runs.",
                isWarning: true
            )
        } else if state == .notApplied, let reason = notAppliedText(line.notAppliedReason, in: lines) {
            note = BindingRow.Note(text: reason)
        } else if state == .applied, let shortcut = steps.first.flatMap(menuShortcut) {
            note = BindingRow.Note(text: "While a terminal has focus this binding runs instead of \(shortcut.title).")
        }
        return BindingRow(
            id: "\(line.file.path):\(line.line)",
            line: line,
            trigger: trigger,
            chips: steps.map(keycaps(ofStep:)),
            actions: action.map { [$0] } ?? [],
            state: state,
            notes: note.map { [$0] } ?? []
        )
    }

    /// The shortcut Cherry takes before a binding of this trigger step can
    /// run (`CherryShortcut.Taker.takesKeyBeforeTerminal`): the binding never
    /// does.
    static func shortcutTakenFirst(_ step: String) -> CherryShortcut? {
        CherryShortcut.all.first { $0.taker.takesKeyBeforeTerminal && $0.ghosttyTriggers.contains(step) }
    }

    /// The menu-only shortcut of this trigger step. The focused terminal
    /// sees the key before the menus, and runs a binding of it it takes:
    /// while a terminal has focus the binding wins.
    static func menuShortcut(_ step: String) -> CherryShortcut? {
        CherryShortcut.all.first { $0.taker == .menu && $0.ghosttyTriggers.contains(step) }
    }

    /// Why Cherry's terminals leave out a line Ghostty accepts.
    static func notAppliedText(
        _ reason: UserGhosttyKeyboardConfig.NotAppliedReason?,
        in lines: [UserGhosttyKeyboardConfig.Line]
    ) -> String? {
        switch reason {
        case .appAction:
            return "An app action, which stays Cherry's."
        case .replaced(let index):
            guard lines.indices.contains(index) else { return "A later line replaced it." }
            return "Replaced by \(location(of: lines[index]))."
        case .cleared(let index):
            guard lines.indices.contains(index) else { return "A later line cleared it." }
            let line = lines[index]
            let clear = line.value.isEmpty ? "an empty \(line.key) =" : "\(line.key) = \(line.value)"
            return "Cleared by \(clear) in \(location(of: line))."
        case .chainOfDropped:
            return "Chains to a binding that isn't applied."
        case nil:
            return nil
        }
    }

    /// "keys.conf, line 7".
    static func location(of line: UserGhosttyKeyboardConfig.Line) -> String {
        "\(line.file.lastPathComponent), line \(line.line)"
    }

    /// A binding's badge: the line that sets it, read-only here.
    @MainActor
    static func source(
        of line: UserGhosttyKeyboardConfig.Line,
        homeDirectory: String,
        actions: SettingsActions
    ) -> SettingsSourceState {
        SettingsSourceState(
            source: .ghosttyConfig(file: line.file, line: line.line),
            lines: [
                SettingsSourceState.Line(
                    "Ghostty config",
                    detail: SettingsSourceState.ghosttyLocation(
                        file: line.file,
                        line: line.line,
                        homeDirectory: homeDirectory
                    ),
                    isInUse: true
                ),
            ],
            note: "Cherry reads this file when it opens. Restart Cherry after you change it.",
            buttons: [
                SettingsAction("Edit in Ghostty Config") { actions.openTextFile(line.file) },
                SettingsAction("Reveal in Finder") { actions.revealInFinder([line.file]) },
            ]
        )
    }

    /// What a binding's action shows before the "•••" that hides what a
    /// `text:` binding types; nil for an action with nothing to hide.
    static func maskedPrefix(of action: String) -> String? {
        action.hasPrefix("text:") && action.count > "text:".count ? "text:" : nil
    }

    // MARK: Keycaps

    /// A trigger step (`TerminalSettings.keybindSteps`: "ctrl+shift+x") as
    /// keycaps, its modifiers in the order menus write them: ["⌃", "⇧",
    /// "X"].
    static func keycaps(ofStep step: String) -> [String] {
        let glyphs = ["caps_lock": "⇪", "num_lock": "⇭", "ctrl": "⌃", "alt": "⌥", "shift": "⇧", "super": "⌘"]
        let order = ["caps_lock", "num_lock", "ctrl", "alt", "shift", "super"]
        var held: Set<String> = []
        var rest = Substring(step)
        // Modifiers come first; an empty part after them is the `+` key.
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex, glyphs[String(rest[..<plus])] != nil {
            held.insert(String(rest[..<plus]))
            rest = rest[rest.index(after: plus)...]
        }
        let key = rest.isEmpty ? [] : [keyGlyph(String(rest))]
        return order.filter(held.contains).compactMap { glyphs[$0] } + key
    }

    /// A key by Ghostty's name for it (`TerminalSettings.keybindKeyName`) as
    /// a keycap shows it: "↩", "X", "F5"; else the name.
    static func keyGlyph(_ name: String) -> String {
        let named = [
            "enter": "↩", "numpad_enter": "⌤", "tab": "⇥", "backspace": "⌫", "delete": "⌦", "escape": "⎋",
            "space": "␣", "arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→",
            "page_up": "⇞", "page_down": "⇟", "home": "↖", "end": "↘", "bracket_left": "[", "bracket_right": "]",
            "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
            "backquote": "`", "minus": "-", "equal": "=",
        ]
        if let glyph = named[name] { return glyph }
        if name.hasPrefix("key_"), name.count == 5 { return name.dropFirst(4).uppercased() }
        if name.hasPrefix("digit_"), name.count == 7 { return String(name.dropFirst(6)) }
        if name.count > 1, name.first == "f", name.dropFirst().allSatisfy(\.isNumber) { return name.uppercased() }
        return name.count == 1 ? name.uppercased() : name
    }

    // MARK: Matching

    /// Whether a row of Cherry's keys matches the search: its name or one
    /// of its shortcut's (`OmniMatcher`), or its keys as menus write them
    /// ("⇧⌘D", spaces and case aside) or as a Ghostty trigger does
    /// ("cmd+shift+d").
    static func matches(_ row: ListRow, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let keys = compactKeys(query)
        if row.shortcuts.contains(where: { $0.display.lowercased() == keys }) { return true }
        if let steps = ghosttySteps(query), steps.count == 1,
           row.shortcuts.contains(where: { $0.ghosttyTriggers.contains(steps[0]) }) {
            return true
        }
        return ([row.title] + row.shortcuts.map(\.title)).contains { OmniMatcher.match(query, in: $0) != nil }
    }

    /// Whether a terminal key binding matches the search: its keys (the
    /// whole trigger, or its first step) as menus or a Ghostty trigger
    /// write them, its trigger as the line writes it, or its actions as
    /// the row shows them (hidden text stays hidden).
    static func matches(_ row: BindingRow, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let keys = compactKeys(query)
        if row.keysText.lowercased() == keys || row.chips.first?.joined().lowercased() == keys { return true }
        if let steps = ghosttySteps(query) {
            let rowSteps = TerminalSettings.keybindSteps(row.trigger)
            if steps == rowSteps || steps == Array(rowSteps.prefix(1)) { return true }
        }
        let shownActions = row.actions.map { action in maskedPrefix(of: action).map { $0 + "•••" } ?? action }
        return ([row.trigger] + shownActions).contains { OmniMatcher.match(query, in: $0) != nil }
    }

    private static func compactKeys(_ query: String) -> String {
        query.filter { !$0.isWhitespace }.lowercased()
    }

    /// A search written as a Ghostty trigger ("cmd+shift+d", "a>b"), its
    /// steps as `TerminalSettings.keybindSteps` spells them; nil for one
    /// that is not.
    private static func ghosttySteps(_ query: String) -> [String]? {
        let trigger = query.filter { !$0.isWhitespace }
        guard trigger.count > 1, trigger.contains("+") || trigger.contains(">") else { return nil }
        return TerminalSettings.keybindSteps(trigger)
    }

    // MARK: Record

    /// Whether a key press is Escape alone, which stops Record.
    static func isEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        Int(keyCode) == kVK_Escape && modifiers.isDisjoint(with: [.command, .control, .option, .shift])
    }

    /// What Record puts in the search field for a key press: its modifiers'
    /// glyphs and its key, as menus write a shortcut (`CherryShortcut
    /// .display`: "⇧⌘D", "⌥⌘↑"). Nil for a key with nothing to show.
    static func display(
        charactersIgnoringModifiers: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let names: [(NSEvent.ModifierFlags, SwiftUI.EventModifiers)] = [
            (.control, .control), (.option, .option), (.shift, .shift), (.command, .command),
        ]
        var held: SwiftUI.EventModifiers = []
        for (flag, modifier) in names where flags.contains(flag) {
            held.insert(modifier)
        }
        let key: String
        if let named = namedKeys[Int(keyCode)] {
            key = named
        } else if let character = charactersIgnoringModifiers?.first, isShown(character) {
            key = String(character).uppercased()
        } else {
            return nil
        }
        return CherryShortcut.glyphs(of: held).joined() + key
    }

    /// Not a control character, nor one of AppKit's function-key characters
    /// (U+F700 to U+F8FF), which a key without a name of its own has.
    private static func isShown(_ character: Character) -> Bool {
        !character.unicodeScalars.contains { scalar in
            (0xF700...0xF8FF).contains(scalar.value) || scalar.properties.generalCategory == .control
        }
    }

    /// Keys whose characters say nothing (arrows, function keys), by key
    /// code.
    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Space: "␣", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓",
        kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
