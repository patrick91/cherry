import Foundation
import GhosttyTerminal
import Testing
@testable import Cherry

@Test func ghosttyRuntimeResourcesAreBundled() throws {
    let resources = try #require(GhosttyRuntimeResources.directoryURL)
    let terminfo = try #require(GhosttyRuntimeResources.terminfoDirectoryURL)

    #expect(FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("shell-integration/zsh/ghostty-integration").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path
    ))
}

@Test func shellLaunchUsesBundledGhosttyTerminfo() throws {
    let terminfo = try #require(GhosttyRuntimeResources.terminfoDirectoryURL)

    #expect(ShellProcessController.preferredTerminfo.term == "xterm-ghostty")
    #expect(ShellProcessController.preferredTerminfo.additionalDirs == terminfo.path)
}

@Test func ttySessionIdentityRejectsInvalidNames() {
    #expect(TerminalTTYSessionIdentity(ttyName: "") == nil)
    #expect(TerminalTTYSessionIdentity(ttyName: "not a tty") == nil)
    #expect(TerminalTTYSessionIdentity(ttyName: "/dev/cherry-does-not-exist") == nil)
}
