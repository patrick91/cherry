import AppKit
import Foundation
import Testing
@testable import Cherry

// The Settings window's search (SettingsSearch.swift): how a query matches
// rows, how results group and rank, the search model's keys, and that the
// rows are read once per search. Synthetic rows, except where a test says
// it reads the index's own (private defaults, a hand-built context; never
// `SettingsSearchContext.live()`).

private func row(
    _ id: SettingsRowID,
    _ route: SettingsRoute,
    _ section: String,
    _ title: String,
    help: String? = nil,
    keywords: [String] = [],
    value: String? = nil
) -> SettingsSearchRow {
    SettingsSearchRow(id: id, route: route, section: section, title: title, help: help, keywords: keywords, value: value)
}

private func pageRow(_ route: SettingsRoute, _ title: String, keywords: [String] = [], value: String? = nil) -> SettingsSearchRow {
    SettingsSearchRow(
        id: SettingsRowID(rawValue: "page:\(title)"),
        route: route,
        section: "",
        title: title,
        keywords: keywords,
        value: value,
        opensPage: true
    )
}

private let cherryRoot = "/Users/someone/code/cherry"

private let sampleRows: [SettingsSearchRow] = [
    pageRow(.page(.sessions), "Sessions", keywords: ["daemon"]),
    pageRow(.page(.interface), "Interface", keywords: ["appearance", "dark mode"]),
    pageRow(.page(.themes), "Themes", keywords: ["palette"]),
    pageRow(.page(.terminal), "Terminal", keywords: ["keyboard", "ghostty"]),
    pageRow(.page(.notifications), "Notifications", keywords: ["bell"]),
    pageRow(.page(.updates), "Updates", keywords: ["version", "beta"]),
    pageRow(.agent("claude"), "Claude", keywords: ["Claude Code"]),
    pageRow(.project(cherryRoot), "cherry", value: "~/code/cherry"),
    pageRow(.project("/Users/someone/Résumé"), "Résumé", value: "~/Résumé"),
    row("sessions.closeTabOnExit", .page(.sessions), "Tabs", "Close a tab when its shell exits", keywords: ["exit"]),
    row("interface.colorScheme", .page(.interface), "Appearance", "Color scheme", help: "Auto follows macOS.",
        keywords: ["dark mode", "light mode"], value: "Auto"),
    row("themes.dark", .page(.themes), "Dark Mode", "Dark Mode theme", value: "Afterglow"),
    row("terminal.fontSize", .page(.terminal), "Text", "Font size", keywords: ["typeface"], value: "14 pt"),
    row("terminal.optionKey", .page(.terminal), "Keyboard", "Option key", value: "set by your Ghostty config"),
    row("terminal.keyBindings", .page(.terminal), "Keyboard", "Key bindings from Ghostty", keywords: ["keybind"]),
    row("notifications.bell", .page(.notifications), "Terminal bell", "Bell", value: "Beep"),
    row("updates.prereleases", .page(.updates), "Automatic updates", "Get pre-release builds", keywords: ["beta"]),
    row(.agent("claude", "command"), .agent("claude"), "Command", "Command", value: "claude"),
    row(.project(cherryRoot, "todos"), .project(cherryRoot), "Features", "Todos",
        help: "Adds a to-do list to this project's windows.", keywords: ["tasks"]),
]

private func groups(_ query: String, in rows: [SettingsSearchRow] = sampleRows) -> [SettingsSearchGroup] {
    SettingsSearchIndex.groups(for: query, in: rows)
}

private func ids(_ groups: [SettingsSearchGroup]) -> [SettingsRowID] {
    groups.flatMap { $0.results.map(\.id) }
}

// MARK: - Matching

@Test func settingsWindowSearchMatchesOneRunOrRunsThatStartWords() throws {
    let option = try #require(groups("option").first { $0.kind == .page(.terminal) })
    #expect(option.results.map(\.id) == ["terminal.optionKey"])
    #expect(option.results.first?.titleIndices == [0, 1, 2, 3, 4, 5])

    // "kbg": Key bindings … Ghostty, each letter at a word's start.
    let bindings = try #require(SettingsSearchIndex.match("kbg", row: sampleRows[14], pageTitle: "Terminal"))
    #expect(bindings.titleIndices == [0, 4, 18])
    // A run inside a word: "inding".
    #expect(SettingsSearchIndex.match("inding", row: sampleRows[14], pageTitle: "Terminal")?.titleIndices
        == [5, 6, 7, 8, 9, 10])
}

@Test func settingsWindowSearchNeverMatchesScatteredLetters() {
    // o-t-k is in "Option key", but scattered inside words.
    #expect(SettingsSearchIndex.match("otk", row: sampleRows[13], pageTitle: "Terminal") == nil)
    #expect(SettingsSearchIndex.match("ptn", row: sampleRows[13], pageTitle: "Terminal") == nil)
    #expect(groups("otk").isEmpty)
}

@Test func settingsWindowSearchIgnoresCaseAndAccents() {
    #expect(ids(groups("OPTION KEY")) == ["terminal.optionKey"])
    #expect(ids(groups("resume")) == ["page:Résumé"])
    #expect(ids(groups("RÉSUMÉ")) == ["page:Résumé"])
    #expect(ids(groups("Fönt")) == ["terminal.fontSize"])
}

@Test func settingsWindowSearchBoldsTheTitleElseTheSecondLine() throws {
    let font = try #require(groups("font").flatMap(\.results).first)
    #expect(font.id == "terminal.fontSize")
    #expect(font.titleIndices == [0, 1, 2, 3])
    #expect(font.detailIndices.isEmpty)

    // "Dark Mode · Afterglow": the value, in the second line.
    let afterglow = try #require(groups("afterglow").flatMap(\.results).first)
    #expect(afterglow.id == "themes.dark")
    #expect(afterglow.row.detail == "Dark Mode · Afterglow")
    #expect(afterglow.titleIndices.isEmpty)
    #expect(afterglow.detailIndices == Array(12 ..< 21))

    // Help and extra words find a row and bold nothing.
    let tasks = try #require(groups("tasks").flatMap(\.results).first)
    #expect(tasks.id == SettingsRowID.project(cherryRoot, "todos"))
    #expect(tasks.titleIndices.isEmpty && tasks.detailIndices.isEmpty)
    let follows = try #require(groups("follows macos").flatMap(\.results).first)
    #expect(follows.id == "interface.colorScheme")
    #expect(follows.titleIndices.isEmpty && follows.detailIndices.isEmpty)
}

@Test func settingsWindowSearchRowsShowTheirSectionAndValue() {
    #expect(sampleRows[13].detail == "Keyboard · set by your Ghostty config")
    #expect(sampleRows[14].detail == "Keyboard")
    #expect(pageRow(.page(.terminal), "Terminal").detail == "")
    #expect(row("macs.list", .page(.macs), "", "Your Macs", value: "mini.local").detail == "mini.local")
}

@Test func settingsWindowSearchMatchesARowOnce() throws {
    // "dark mode" is the title's, the section's and an extra word: one
    // result, bold in its title.
    let darkMode = groups("dark mode").flatMap(\.results).filter { $0.id == "themes.dark" }
    #expect(darkMode.count == 1)
    #expect(darkMode.first?.titleIndices == Array(0 ..< 9))

    // A row listed twice is matched once.
    let twice = sampleRows + [sampleRows[13]]
    #expect(ids(groups("option", in: twice)) == ["terminal.optionKey"])
}

// MARK: - Groups

@Test func settingsWindowSearchGroupsFollowTheSidebarWithAgentsThenProjectsLast() {
    // Rows listed out of the sidebar's order, sharing a word.
    let rows = [
        row(.project(cherryRoot, "todos"), .project(cherryRoot), "Features", "Todos", keywords: ["shared"]),
        row(.agent("claude", "command"), .agent("claude"), "Command", "Command", keywords: ["shared"]),
        row("updates.prereleases", .page(.updates), "Automatic updates", "Get pre-release builds", keywords: ["shared"]),
        row("terminal.fontSize", .page(.terminal), "Text", "Font size", keywords: ["shared"]),
        row("sessions.host", .page(.sessions), "", "Session host", keywords: ["shared"]),
    ]

    let found = groups("shared", in: rows)

    #expect(found.map(\.kind) == [.page(.sessions), .page(.terminal), .page(.updates), .agents, .projects])
    #expect(found.map(\.title) == ["Sessions", "Terminal", "Updates", "Agents", "Projects"])
}

@Test func settingsWindowSearchListsAPagesOwnResultFirstInItsGroup() throws {
    // Terminal's page matches "keyboard" by an extra word, which ranks
    // below its rows' section; it is still first.
    let terminal = try #require(groups("keyboard").first { $0.kind == .page(.terminal) })
    #expect(terminal.results.map(\.id) == ["page:Terminal", "terminal.keyBindings", "terminal.optionKey"])
    #expect(terminal.results[1].score > terminal.results[0].score)
    // The whole second line beats its start.
    #expect(terminal.results[1].score > terminal.results[2].score)

    // A page's title finds its rows too, after the page, in their order.
    let byTitle = try #require(groups("terminal").first { $0.kind == .page(.terminal) })
    #expect(byTitle.results.map(\.id) == [
        "page:Terminal", "terminal.fontSize", "terminal.optionKey", "terminal.keyBindings",
    ])
    // Notifications' row whose section says it.
    #expect(groups("terminal").first { $0.kind == .page(.notifications) }?.results.map(\.id) == ["notifications.bell"])
}

@Test func settingsWindowSearchRanksTheTitleOverTheSecondLineOverTheRest() throws {
    let rows = [
        row("a.help", .page(.terminal), "Text", "Cursor", help: "Blink it."),
        row("a.value", .page(.terminal), "Text", "Shape", value: "Blink"),
        row("a.title", .page(.terminal), "Text", "Blink cursor"),
    ]

    let terminal = try #require(groups("blink", in: rows).first)
    #expect(terminal.results.map(\.id) == ["a.title", "a.value", "a.help"])
}

@Test func settingsWindowSearchFindsAProjectByItsPath() throws {
    let projects = try #require(groups("code/cherry").first { $0.kind == .projects })
    #expect(projects.results.map(\.id) == ["page:cherry"])
    #expect(projects.results.first?.detailIndices == Array(2 ..< 13))
    #expect(projects.results.first?.row.route == .project(cherryRoot))
}

@Test func settingsWindowSearchFindsNothingForNoMatchAndAnEmptyQuery() {
    #expect(groups("zzzz").isEmpty)
    #expect(groups("").isEmpty)
    #expect(groups("   ").isEmpty)
    // A leftover of worktree spaces.
    #expect(groups("workspace").isEmpty)
}

// MARK: - The index's own rows

@MainActor
private func searchContext(
    _ name: String,
    agents: [AgentToolDefinition] = [],
    projectPaths: [String] = []
) -> SettingsSearchContext {
    let defaults = privateDefaults(name)
    let agentSettings = AgentSettings(defaults: defaults)
    for agent in agents {
        _ = try? agentSettings.addAgent(agent)
    }
    for path in projectPaths {
        agentSettings.addProject(path: path)
    }
    return SettingsSearchContext(
        terminal: TerminalSettings(defaults: defaults, launchArguments: [:]),
        agents: agentSettings,
        defaults: defaults,
        homeDirectory: "/Users/someone"
    )
}

@Test @MainActor func settingsWindowSearchIndexHasARowForEachPageAgentAndProjectOfThisMac() throws {
    let folder = try canonicalTemporaryDirectory("SettingsWindowSearchProject")
    defer { try? FileManager.default.removeItem(at: folder) }
    let device = "device:6F1C2A3B-4D5E-4F60-8172-93A4B5C6D7E8:/Users/me/code/api"
    let context = searchContext(
        "SettingsWindowSearch",
        agents: [AgentToolDefinition(name: "Claude", command: "claude"), AgentToolDefinition(name: "Mine", command: "my-agent")],
        projectPaths: [folder.path, device]
    )

    let rows = SettingsSearchIndex.rows(in: context)
    let pages = rows.filter(\.opensPage)
    let projectRoot = try #require(context.agents.projects.first { $0.root != device }?.root)

    #expect(context.agents.projects.count == 2)
    #expect(pages.map(\.route) == SettingsPage.allCases.map(SettingsRoute.page)
        + [.agent("claude"), .agent("mine"), .project(projectRoot)])
    #expect(pages.map(\.title) == SettingsPage.allCases.map(\.title) + ["Claude", "Mine", folder.lastPathComponent])
    #expect(pages.first { $0.route == .page(.updates) }?.keywords == SettingsPage.updates.keywords)
    #expect(pages.first { $0.route == .agent("claude") }?.keywords == ["Claude Code"])
    // Not under the home folder: the path as it is.
    #expect(pages.last?.value == projectRoot)
    // Each row once, and the pages' own rows first.
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(rows.prefix(pages.count).allSatisfy { $0.opensPage })
    #expect(!rows.contains { if case .project(let root) = $0.route { root == device } else { false } })
}

@Test @MainActor func settingsWindowSearchIndexShowsAProjectsPathUnderHomeWithATilde() throws {
    let home = try canonicalTemporaryDirectory("SettingsWindowSearchHome")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent("code/cherry", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    var context = searchContext("SettingsWindowSearchHome", projectPaths: [project.path])
    // The home as the project's root spells it.
    let root = try #require(context.agents.projects.first?.root)
    context.homeDirectory = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().path

    let rows = SettingsSearchIndex.rows(in: context)
    let page = try #require(rows.first { $0.route == .project(root) && $0.opensPage })
    #expect(page.value == "~/code/cherry")
    // The full path finds it as well.
    #expect(page.keywords == [root])
    #expect(SettingsSearchIndex.groups(for: "~/code/cherry", in: rows).first?.kind == .projects)
    #expect(SettingsSearchIndex.groups(for: root, in: rows).first?.results.first?.row == page)
}

@Test @MainActor func settingsWindowSearchIndexRowsFindSettingsByNameAndValue() throws {
    let context = searchContext("SettingsWindowSearchValues")
    context.terminal.fontSize = 16
    let rows = SettingsSearchIndex.rows(in: context)

    let fontSize = try #require(SettingsSearchIndex.groups(for: "font size", in: rows).first { $0.kind == .page(.terminal) })
    #expect(fontSize.results.first { $0.id == .terminalFontSize }?.row.detail == "Text · 16 pt")
    let afterglow = SettingsSearchIndex.groups(for: "afterglow", in: rows).flatMap(\.results).map(\.id)
    #expect(afterglow == [.themesDark])
    #expect(SettingsSearchIndex.groups(for: "workspace", in: rows).isEmpty)
}

// MARK: - Search model

@Test @MainActor func settingsWindowSearchSelectsTheFirstResultAndMovesWithTheArrows() {
    let navigator = SettingsNavigator(searchRows: { sampleRows })
    let search = navigator.search

    search.text = "key"
    #expect(search.isSearching)
    // The page; then "Key bindings…", where "key" starts the title.
    #expect(search.results.map(\.id) == ["page:Terminal", "terminal.keyBindings", "terminal.optionKey"])
    #expect(search.selection == "page:Terminal")

    #expect(search.handle(#selector(NSResponder.moveDown(_:))))
    #expect(search.selection == "terminal.keyBindings")
    #expect(search.handle(#selector(NSResponder.moveDown(_:))))
    #expect(search.handle(#selector(NSResponder.moveDown(_:))))
    // The last result stays selected.
    #expect(search.selection == "terminal.optionKey")
    #expect(search.handle(#selector(NSResponder.moveUp(_:))))
    #expect(search.selection == "terminal.keyBindings")

    // Typing again selects the new first result.
    search.text = "option"
    #expect(search.selection == "terminal.optionKey")
    #expect(search.handle(#selector(NSResponder.moveUp(_:))))
    #expect(search.selection == "terminal.optionKey")
}

@Test @MainActor func settingsWindowSearchReturnOpensTheSelectedRowAndKeepsTheResults() {
    let navigator = SettingsNavigator(searchRows: { sampleRows })
    let search = navigator.search
    search.text = "key"
    _ = search.handle(#selector(NSResponder.moveDown(_:)))

    #expect(search.handle(#selector(NSResponder.insertNewline(_:))))
    #expect(navigator.route == .page(.terminal))
    #expect(navigator.highlight.row == "terminal.keyBindings")
    #expect(navigator.highlight.generation == 1)
    // The next result is one ↓ away.
    #expect(search.text == "key")
    #expect(search.selection == "terminal.keyBindings")
    _ = search.handle(#selector(NSResponder.moveDown(_:)))
    _ = search.handle(#selector(NSResponder.insertNewline(_:)))
    #expect(navigator.highlight.row == "terminal.optionKey")
    #expect(navigator.backHistory == [.page(.interface)])

    // A page's own result opens the page from its top, tinting no row.
    search.text = "claude"
    #expect(search.selection == "page:Claude")
    _ = search.handle(#selector(NSResponder.insertNewline(_:)))
    #expect(navigator.route == .agent("claude"))
    #expect(navigator.highlight.generation == 2)

    // A click opens a result too.
    search.open(SettingsRowID.agent("claude", "command"))
    #expect(search.selection == SettingsRowID.agent("claude", "command"))
    #expect(navigator.highlight.row == SettingsRowID.agent("claude", "command"))
    #expect(navigator.route == .agent("claude"))
}

@Test @MainActor func settingsWindowSearchEscapeClearsTheTextAndBringsThePagesBack() {
    let navigator = SettingsNavigator(searchRows: { sampleRows })
    let search = navigator.search
    search.text = "bell"
    #expect(!search.groups.isEmpty)

    #expect(search.handle(#selector(NSResponder.cancelOperation(_:))))
    #expect(search.text.isEmpty)
    #expect(!search.isSearching)
    #expect(search.groups.isEmpty)
    #expect(search.selection == nil)

    // With nothing to clear, the keys are the field's.
    #expect(!search.handle(#selector(NSResponder.cancelOperation(_:))))
    #expect(!search.handle(#selector(NSResponder.moveDown(_:))))
    #expect(!search.handle(#selector(NSResponder.moveUp(_:))))
    #expect(!search.handle(#selector(NSResponder.insertNewline(_:))))
    #expect(!search.handle(#selector(NSResponder.insertTab(_:))))
    #expect(navigator.route == .page(.interface))
}

@Test @MainActor func settingsWindowSearchSaysWhenNothingMatches() {
    let navigator = SettingsNavigator(searchRows: { sampleRows })
    let search = navigator.search

    #expect(!search.hasNoResults)
    search.text = "ghosty"
    #expect(search.hasNoResults)
    #expect(search.query == "ghosty")
    #expect(search.selection == nil)
    // Return opens nothing.
    #expect(search.handle(#selector(NSResponder.insertNewline(_:))))
    #expect(navigator.route == .page(.interface))
    #expect(navigator.highlight.generation == 0)
}

@Test @MainActor func settingsWindowSearchReadsTheRowsOncePerSearchNotPerKeystroke() async throws {
    var reads = 0
    var rows = sampleRows
    let search = SettingsSearchModel {
        reads += 1
        return rows
    }

    // Not until something is typed.
    search.text = "   "
    #expect(reads == 0)
    for text in ["f", "fo", "fon", "font", "fon"] {
        search.text = text
    }
    #expect(reads == 1)
    #expect(search.results.map(\.id) == ["terminal.fontSize"])

    // Cleared and typed again: a new search reads them again.
    search.text = ""
    search.text = "option"
    #expect(reads == 2)

    // A change of what they read, while searching: read again, the
    // selection kept where it still is.
    _ = search.handle(#selector(NSResponder.moveDown(_:)))
    rows[13].value = "Option is Alt"
    search.refreshRows()
    #expect(reads == 3)
    #expect(search.results.first?.row.value == "Option is Alt")
    #expect(search.selection == "terminal.optionKey")

    // Many changes in one turn read them once, on the next turn.
    search.scheduleRowsRefresh()
    search.scheduleRowsRefresh()
    search.scheduleRowsRefresh()
    #expect(reads == 3)
    try await poll("the scheduled refresh") { reads == 4 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads == 4)

    // Not while the pages show.
    search.text = ""
    search.scheduleRowsRefresh()
    search.refreshRows()
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads == 4)
}

@Test @MainActor func settingsWindowSearchFocusRequestsBump() {
    let search = SettingsSearchModel { [] }
    #expect(search.focusRequest == 0)
    search.requestFocus()
    search.requestFocus()
    #expect(search.focusRequest == 2)
}

@Test func settingsWindowSearchEmphasisBoldsTheMatchedCharacters() {
    let text = SettingsSearchEmphasis.text("Option key", bolding: [0, 1, 7])
    let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        .map { String(text[$0.range].characters) }
    #expect(bold == ["Op", "k"])
    #expect(String(text.characters) == "Option key")
}
