import Testing
@testable import Cherry

@Test func agentToolBrandRecognizesNamedProfilesAndCommands() {
    #expect(AgentToolBrand.detect(name: "Codex YOLO") == .codex)
    #expect(AgentToolBrand.detect(name: "Claude with Chrome") == .claude)
    #expect(AgentToolBrand.detect(name: "YOLO", commandLine: "/opt/homebrew/bin/codex --yolo") == .codex)
    #expect(AgentToolBrand.detect(name: "Example") == nil)
}

@Test func defaultSidebarAgentTitleUsesCanonicalBrandName() {
    #expect(SidebarAgentTitleFormatter.title(
        title: "Codex YOLO",
        titleSource: .system,
        agentName: "Codex YOLO",
        commandLine: "codex --yolo"
    ) == "Codex")
}

@Test func sidebarAgentTitlePreservesTaskTitlesAndSummaries() {
    #expect(SidebarAgentTitleFormatter.title(
        title: "Deploy app prompt",
        titleSource: .explicit,
        agentName: "Codex YOLO",
        commandLine: "codex --yolo"
    ) == "Deploy app prompt")

    #expect(SidebarAgentTitleFormatter.title(
        title: "Investigate deployment",
        titleSource: .automatic,
        agentName: "Codex YOLO",
        commandLine: "codex --yolo"
    ) == "Investigate deployment")
}
