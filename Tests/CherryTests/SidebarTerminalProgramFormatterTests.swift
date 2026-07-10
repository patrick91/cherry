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

@Test func sidebarTerminalProgramFormatterUsesResolvedAliasCommandForProgramIcon() async throws {
    #expect(SidebarTerminalProgramFormatter.label(
        for: "ga -p",
        workingDirectory: "/Users/patrick/github/patrick91/cherry",
        homeDirectory: "/Users/patrick",
        resolvedCommandLine: "git add -p"
    ) == SidebarTerminalPathLabel(
        title: "Git add",
        detail: "ga -p",
        leadingIconResourceName: "git",
        leadingIconFallback: "Gt",
        leadingIconRendersAsTemplate: true
    ))
}

@Test func sidebarTerminalProgramFormatterFindsCommandAfterUvxPackageOptions() async throws {
    let command = "uvx --from 'fastapi[standard]' --with-editable /Users/patrick/github/fastapilabs/fastapi --with-editable /Users/patrick/github/fastapilabs/fastapi-cloud-cli fastapi deploy"

    #expect(SidebarTerminalProgramFormatter.label(
        for: command,
        workingDirectory: "/Users/patrick/github/test-patrick/kenbun-workspace",
        homeDirectory: "/Users/patrick"
    ) == SidebarTerminalPathLabel(
        title: "FastAPI",
        detail: command,
        leadingIconResourceName: "fastapi",
        leadingIconFallback: "Fa",
        leadingIconRendersAsTemplate: true
    ))
}

@Test func sidebarProjectCommandFormatterUsesCommandLineProgramIcon() async throws {
    let command = ProjectCommandDefinition(
        name: "fastapi dev",
        command: "uv",
        arguments: "run fastapi dev",
        environment: [
            "FASTAPI_ENV": "development",
            "PYTHONUNBUFFERED": "1"
        ]
    )

    #expect(SidebarProjectCommandFormatter.label(
        for: command,
        projectRoot: "/Users/patrick/github/farboon-dev/shot",
        homeDirectory: "/Users/patrick"
    ) == SidebarTerminalPathLabel(
        title: "fastapi dev",
        detail: "FASTAPI_ENV=... PYTHONUNBUFFERED=... uv run fastapi dev",
        leadingIconResourceName: "fastapi",
        leadingIconFallback: "Fa",
        leadingIconRendersAsTemplate: true
    ))
}
