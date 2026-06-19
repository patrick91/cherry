import AppKit
import Foundation
import Testing
@testable import Cherry

@Test func nixShellParserExtractsFlakePackageRefs() async throws {
    let environment = try #require(NixShellCommandParser.environment(
        from: "nix shell nixpkgs#sops nixpkgs#jq --command zsh"
    ))

    #expect(environment.kind == .shell)
    #expect(environment.command == "nix shell nixpkgs#sops nixpkgs#jq --command zsh")
    #expect(environment.packageReferences.map(\.rawValue) == ["nixpkgs#sops", "nixpkgs#jq"])
    #expect(environment.packageReferences.map(\.displayName) == ["sops", "jq"])
    #expect(environment.packageSummary == "sops, jq")
}

@Test func nixShellParserHandlesDevelopWithGlobalOptions() async throws {
    let environment = try #require(NixShellCommandParser.environment(
        from: "nix --extra-experimental-features 'nix-command flakes' develop .#tools --command make"
    ))

    #expect(environment.kind == .develop)
    #expect(environment.packageReferences.map(\.rawValue) == [".#tools"])
    #expect(environment.packageReferences.first?.displayName == "tools")
}

@Test func nixShellParserHandlesLegacyNixShellPackages() async throws {
    let environment = try #require(NixShellCommandParser.environment(
        from: "nix-shell -p sops jq --run 'sops --version'"
    ))

    #expect(environment.kind == .legacyShell)
    #expect(environment.packageReferences.map(\.rawValue) == ["sops", "jq"])
}

@MainActor
@Test func terminalSessionTracksNixShellMetadata() async throws {
    let session = TerminalSession(
        title: "Shell 1",
        subtitle: "No shell",
        tint: .systemBlue,
        launchShell: false
    )

    session.ingestTestingData(Data("\u{1B}]777;cherry-nix;enter;nix shell nixpkgs#sops nixpkgs#jq\u{7}".utf8))

    let environment = try #require(session.nixShellEnvironment)
    #expect(environment.kind == .shell)
    #expect(environment.packageReferences.map(\.displayName) == ["sops", "jq"])

    session.ingestTestingData(Data("\u{1B}]777;cherry-nix;exit;\u{7}".utf8))
    #expect(session.nixShellEnvironment == nil)
}

@MainActor
@Test func terminalSessionTracksResolvedCommandMetadataForNextTitle() async throws {
    let session = TerminalSession(
        title: "Shell 1",
        subtitle: "No shell",
        tint: .systemBlue,
        launchShell: false
    )

    session.ingestTestingData(Data((
        "\u{1B}]777;cherry-command;git add -p\u{7}" +
        "\u{1B}]2;ga -p\u{7}"
    ).utf8))

    #expect(session.title == "ga -p")
    #expect(session.resolvedCommandLine == "git add -p")

    session.ingestTestingData(Data("\u{1B}]2;~/github/patrick91/cherry\u{7}".utf8))
    #expect(session.resolvedCommandLine == nil)
}

@Test func zshShellIntegrationBootstrapInstallsNixShellHooks() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let bootstrap = try #require(try ShellIntegrationBootstrap.prepare(
        shellPath: "/bin/zsh",
        homeDirectory: temporaryDirectory
    ))

    let integrationURL = URL(fileURLWithPath: bootstrap.zdotdir)
        .appendingPathComponent("cherry-integration.zsh")
    let integration = try String(contentsOf: integrationURL, encoding: .utf8)

    #expect(integration.contains("cherry-nix"))
    #expect(integration.contains("cherry-command"))
    #expect(integration.contains("_cherry_emit_command_metadata"))
    #expect(integration.contains("_cherry_is_nix_shell_command"))
    #expect(integration.contains("CHERRY_NIX_SHELL_ZDOTDIR_OVERRIDE"))

    let syntaxCheck = Process()
    syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
    syntaxCheck.arguments = ["-n", integrationURL.path]
    try syntaxCheck.run()
    syntaxCheck.waitUntilExit()
    #expect(syntaxCheck.terminationStatus == 0)
}
