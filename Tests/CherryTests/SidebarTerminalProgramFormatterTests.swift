import Foundation
import Testing
@testable import Cherry

@Test func sidebarTerminalProgramFormatterUsesGitHubLogoForGitHubCLI() async throws {
    #expect(SidebarTerminalProgramFormatter.label(
        for: "gh pr checkout https://github.com/patrick91/cherry/pull/42",
        workingDirectory: "/Users/patrick/github/patrick91/cherry",
        homeDirectory: "/Users/patrick"
    ) == SidebarTerminalPathLabel(
        title: "GitHub pr",
        detail: "gh pr checkout https://github.com/patrick91/cherry/pull/42",
        leadingIconResourceName: "github",
        leadingIconFallback: "GH",
        leadingIconRendersAsTemplate: true
    ))
}
