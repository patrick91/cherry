import Foundation
import Testing
@testable import CherryMobileKit

@Test func markdownBecomesBlocks() {
    let text = """
    ## Findings
    The critique found **five** issues
    on the pen screen.

    1. What reaches Rise (P1)
    2. The suggestion card (P1)
       with a second line
    - a bullet
    * another

    ```swift
    let x = 1
    ```
    > Keep the stage
    > as it is.

    | Issue | Priority |
    |---|---|
    | Header | P2 |
    ---
    Done.
    """
    #expect(Markdown.blocks(text) == [
        .heading(level: 2, text: "Findings"),
        .paragraph("The critique found **five** issues on the pen screen."),
        .list(ordered: true, items: ["What reaches Rise (P1)", "The suggestion card (P1) with a second line"]),
        .list(ordered: false, items: ["a bullet", "another"]),
        .code(language: "swift", text: "let x = 1"),
        .quote("Keep the stage as it is."),
        .code(language: "table", text: "| Issue | Priority |\n|---|---|\n| Header | P2 |"),
        .rule,
        .paragraph("Done."),
    ])
}

@Test func anUnclosedFenceRunsToTheEnd() {
    #expect(Markdown.blocks("Look:\n```\nnpm test") == [.paragraph("Look:"), .code(language: nil, text: "npm test")])
    #expect(Markdown.blocks("#hashtag is text") == [.paragraph("#hashtag is text")])
}

@Test func pathsAreShortenedToWhereTheyAre() {
    let project = "/Users/patrick/github/farbun-dev/rispli"
    #expect(DisplayPath.shorten("/Users/patrick/github/farbun-dev/rispli/src/pen.tsx", project: project) == "src/pen.tsx")
    #expect(DisplayPath.shorten("/Users/patrick/notes/todo.md", project: project) == "~/notes/todo.md")
    #expect(DisplayPath.shorten("/Users/you/github/patrick91/cherry/Sources/A.swift", project: "~/github/patrick91/cherry") == "Sources/A.swift")
    #expect(DisplayPath.shorten(
        "/private/tmp/claude-501/-Users-patrick-github-farbun-dev-rispli/abc/scratchpad/review.md",
        project: project
    ) == "…/scratchpad/review.md")
    #expect(DisplayPath.shorten(project, project: project) == ".")
    #expect(DisplayPath.shortenPaths(in: "cd /Users/patrick/github/farbun-dev/rispli/web && npm test", project: project) == "cd web && npm test")
    #expect(DisplayPath.shortenURL("https://www.example.com/docs") == "example.com/docs")
}

@Test func toolCallsReadAsWhatTheyDid() {
    let project = "/Users/me/app"
    func shown(_ name: String, _ summary: String) -> ToolPresentation {
        ToolPresentation(TranscriptEntry(id: "t", kind: .tool, name: name, summary: summary, status: .ok), project: project)
    }
    #expect(shown("Bash", "cd /Users/me/app && npm test") == ToolPresentation(symbol: "terminal", title: "Ran", detail: "npm test", isCode: true))
    #expect(shown("Bash", "cd /Users/me/other && make").detail == "cd ~/other && make")
    #expect(shown("Bash", "cat /Users/me/app/src/a.ts").detail == "cat src/a.ts")
    #expect(shown("Read", "/Users/me/app/src/main.ts") == ToolPresentation(symbol: "doc.text", title: "Read", detail: "src/main.ts"))
    #expect(shown("Edit", "/Users/me/app/README.md").title == "Edited")
    #expect(shown("AskUserQuestion", #"{"questions":[{"header":"Fix"}]}"#) == ToolPresentation(symbol: "questionmark.bubble", title: "Asked a question", detail: ""))
    #expect(shown("read_web_page", "https://ampcode.com/manual").detail == "ampcode.com/manual")
    #expect(shown("mcp__cherry__list_processes", "").title == "cherry: list_processes")
    #expect(shown("Shell", "rg -l Printer").isCode)
}

@Test func toolCallsBetweenMessagesAreOneRow() {
    let entries = [
        TranscriptEntry(id: "u", kind: .user, text: "Go"),
        TranscriptEntry(id: "t1", kind: .tool, name: "Read"),
        TranscriptEntry(id: "t2", kind: .tool, name: "Bash"),
        TranscriptEntry(id: "a", kind: .assistant, text: "Done"),
        TranscriptEntry(id: "t3", kind: .tool, name: "Edit"),
        TranscriptEntry(id: "n", kind: .note, text: "Compacted"),
        TranscriptEntry(id: "t4", kind: .tool, name: "Bash"),
    ]
    #expect(ConversationRow.rows(of: entries).map(\.id) == ["u", "tools-t1", "a", "tools-t3", "n", "tools-t4"])
    guard case .tools(let tools) = ConversationRow.rows(of: entries)[1] else { return #expect(Bool(false)) }
    #expect(tools.map(\.id) == ["t1", "t2"])
}
