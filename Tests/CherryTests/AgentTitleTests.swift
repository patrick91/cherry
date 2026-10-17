import Foundation
import Testing
@testable import Cherry

// An agent's terminal title as its tab's task name (`AgentTerminalTitleParser`):
// each CLI's own title format, and the chrome left out of it.

@Test func agentTerminalTitleParserHandlesCodexAndClaudeChrome() {
    let projects: Set<String> = ["cherry"]

    #expect(AgentTerminalTitleParser.taskTitle(
        from: "⠋ Review PR #4676 ⠹ | cherry",
        brand: .codex,
        projectNames: projects,
        agentName: "Codex"
    ) == "Review PR #4676")
    #expect(AgentTerminalTitleParser.taskTitle(
        from: "[ ! ] Action Required | Review PR #4676 | cherry",
        brand: .codex,
        projectNames: projects,
        agentName: "Codex"
    ) == "Review PR #4676")
    #expect(AgentTerminalTitleParser.taskTitle(
        from: "⠹ cherry",
        brand: .codex,
        projectNames: projects,
        agentName: "Codex"
    ) == nil)
    #expect(AgentTerminalTitleParser.taskTitle(
        from: "⠹ cherry | gpt-5.6-sol",
        brand: .codex,
        projectNames: projects,
        agentName: "Codex"
    ) == nil)
    #expect(AgentTerminalTitleParser.taskTitle(
        from: "✳ Probe session initialization",
        brand: .claude,
        projectNames: projects,
        agentName: "Claude"
    ) == "Probe session initialization")
    #expect(AgentTerminalTitleParser.taskTitle(
        from: "✳ Claude Code",
        brand: .claude,
        projectNames: projects,
        agentName: "Claude"
    ) == nil)
}

@Test func agentTerminalTitleParserReadsPisTitles() {
    let projects: Set<String> = ["cherry"]
    func task(_ title: String, agentName: String = "Pi") -> String? {
        AgentTerminalTitleParser.taskTitle(from: title, brand: .pi, projectNames: projects, agentName: agentName)
    }

    // Pi's own title: `π - <session name> - <folder>`.
    #expect(task("π - Fix login redirect - cherry") == "Fix login redirect")
    #expect(task("π - Fix login redirect - Sources") == "Fix login redirect")
    // A session name with the separator in it keeps it.
    #expect(task("π - Review - part 2 - cherry") == "Review - part 2")
    // A spinner extension's frame is chrome.
    #expect(task("⠹ π - Fix login redirect - cherry") == "Fix login redirect")
    // No session name yet: only the program and the folder.
    #expect(task("π - cherry") == nil)
    #expect(task("π") == nil)
    // A Pi under another app name, when that is the agent's name.
    #expect(task("mypi - Fix login redirect - cherry", agentName: "mypi") == "Fix login redirect")
    // An extension's own title is the task as it is.
    #expect(task("Fix login redirect") == "Fix login redirect")
    #expect(task("⠋ Fix login redirect") == "Fix login redirect")
    // Names of the program, the agent or the project, and paths, are not tasks.
    #expect(task("Pi") == nil)
    #expect(task("cherry") == nil)
    #expect(task("~/github/patrick91/cherry") == nil)
    #expect(task("/Users/someone/cherry") == nil)
}

@Test func agentTerminalTitleParserReadsOpenCodesTitles() {
    let projects: Set<String> = ["cherry"]
    func task(_ title: String) -> String? {
        AgentTerminalTitleParser.taskTitle(from: title, brand: .openCode, projectNames: projects, agentName: "OpenCode")
    }

    // OpenCode's own title: `OC | <session title>`.
    #expect(task("OC | Fix login redirect loop") == "Fix login redirect loop")
    // Cut past 40 characters: the cut is the title as OpenCode shows it.
    #expect(task("OC | Refactor terminal title parsing fo…") == "Refactor terminal title parsing fo…")
    // Before 1.0.147 the prefix was lower case.
    #expect(task("oc | Add dark mode") == "Add dark mode")
    // A session title with the separator in it keeps it.
    #expect(task("OC | API | retry logic") == "API | retry logic")
    // No session title yet (start, home, after /new), and the empty title at exit.
    #expect(task("OpenCode") == nil)
    #expect(task("opencode") == nil)
    #expect(task("") == nil)
    // Its full-screen views and a 1.x subagent's session are not this tab's task.
    #expect(task("OC | diff") == nil)
    #expect(task("OC | stats") == nil)
    #expect(task("OC | storybook") == nil)
    #expect(task("OC | Explore codebase (@explore subagent)") == nil)
    // Names of the program or the project, paths, and other titles are not tasks.
    #expect(task("OC | OpenCode") == nil)
    #expect(task("OC | cherry") == nil)
    #expect(task("OC | ~/github/patrick91/cherry") == nil)
    #expect(task("Fix login redirect loop") == nil)
    #expect(task("OC |") == nil)
}

@Test func agentTerminalTitleParserLeavesUnknownFormatsAlone() {
    for brand in [AgentToolBrand.amp, .gemini] {
        #expect(AgentTerminalTitleParser.taskTitle(
            from: "Fix login redirect",
            brand: brand,
            projectNames: ["cherry"],
            agentName: brand.displayName
        ) == nil)
    }
}

@MainActor
@Test func piOSCTitleNamesItsTabsTask() async throws {
    let session = TerminalSession(
        title: "Pi",
        subtitle: "pi",
        tint: .systemGreen,
        workingDirectory: "/Users/someone/code/cherry",
        projectRoot: "/Users/someone/code/cherry",
        launchShell: false,
        kind: .agent,
        agentName: "Pi"
    )
    defer {
        session.stop()
        session.releaseGhosttyBridge()
    }

    // Before the session has a name, the tab keeps the agent's name.
    session.ingestTestingData(Data("\u{1B}]0;π - cherry\u{7}".utf8))
    #expect(session.title == "Pi")

    session.ingestTestingData(Data("\u{1B}]0;π - Fix login redirect - cherry\u{7}".utf8))
    #expect(session.title == "Fix login redirect")
    #expect(session.titleSource == .automatic)

    // An explicit name wins, as for the other agents.
    session.rename(to: "Auth work")
    session.ingestTestingData(Data("\u{1B}]0;π - Check the session cookie - cherry\u{7}".utf8))
    #expect(session.title == "Auth work")
    session.rename(to: "")
    #expect(session.title == "Check the session cookie")
}

@MainActor
@Test func openCodeOSCTitleNamesItsTabsTask() async throws {
    let session = TerminalSession(
        title: "OpenCode",
        subtitle: "opencode",
        tint: .systemGreen,
        workingDirectory: "/Users/someone/code/cherry",
        projectRoot: "/Users/someone/code/cherry",
        launchShell: false,
        kind: .agent,
        agentName: "OpenCode"
    )
    defer {
        session.stop()
        session.releaseGhosttyBridge()
    }

    // Before the session has a title, the tab keeps the agent's name.
    session.ingestTestingData(Data("\u{1B}]0;OpenCode\u{7}".utf8))
    #expect(session.title == "OpenCode")

    session.ingestTestingData(Data("\u{1B}]0;OC | Fix login redirect loop\u{7}".utf8))
    #expect(session.title == "Fix login redirect loop")
    #expect(session.titleSource == .automatic)

    // Its diff view leaves the task's name.
    session.ingestTestingData(Data("\u{1B}]0;OC | diff\u{7}".utf8))
    #expect(session.title == "Fix login redirect loop")
}
