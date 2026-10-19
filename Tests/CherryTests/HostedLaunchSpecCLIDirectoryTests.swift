import CherryControl
import CryptoKit
import Foundation
import Testing
@testable import Cherry

// `cherry` first on every tab's PATH (`TabCLIDirectory`,
// docs/specs/agent-cli.md, PATH): the directory holding only a link to the
// app's `cherry`, its `CHERRY_BIN_DIR`, in native and hosted launches alike,
// the zsh bootstrap putting it first again after the user's startup files,
// and a device's commands and agents getting their install's directory.

private let cliDirectory = "/Users/tester/Library/Application Support/Cherry/bin"
private let appCLI = "/Applications/Cherry.app/Contents/Helpers/cherry"

private func cliConfiguration(
    shell: String = "/bin/zsh",
    environment: [String: String] = [:],
    startupCommand: String? = nil
) -> ShellProcessController.Configuration {
    ShellProcessController.Configuration(
        shellPath: shell,
        workingDirectory: "/Users/tester/code/app",
        projectRoot: "/Users/tester/code/app",
        processID: UUID().uuidString,
        agentID: nil,
        environment: environment,
        term: "xterm-ghostty",
        initialSize: TerminalViewportSize(columns: 120, rows: 32),
        startupCommand: startupCommand
    )
}

@Test func HostedLaunchSpecCLIDirectoryPreparesALinkToTheAppsCherry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-dir-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("cherry-real")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let directory = root.appendingPathComponent("bin", isDirectory: true)

    // Another copy of the app makes nothing.
    #expect(TabCLIDirectory.prepare(cliPath: tool.path, directory: directory, canWrite: false) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    #expect(TabCLIDirectory.prepare(cliPath: tool.path, directory: directory, canWrite: true) == directory.path)
    let link = directory.appendingPathComponent("cherry")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == tool.path)
    // It uses what the holder made.
    #expect(TabCLIDirectory.prepare(cliPath: nil, directory: directory, canWrite: false) == directory.path)

    // A build elsewhere replaces the link.
    let other = root.appendingPathComponent("cherry-other")
    try Data("#!/bin/sh\n".utf8).write(to: other)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
    #expect(TabCLIDirectory.prepare(cliPath: other.path, directory: directory, canWrite: true) == directory.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == other.path)

    // A file of another kind named cherry is left alone, and not used.
    try FileManager.default.removeItem(at: link)
    try Data("mine".utf8).write(to: link)
    #expect(TabCLIDirectory.prepare(cliPath: tool.path, directory: directory, canWrite: true) == nil)
    #expect(try String(contentsOf: link, encoding: .utf8) == "mine")
}

@Test func HostedLaunchSpecCLIDirectoryPrependingPutsItFirstOnce() {
    #expect(TabCLIDirectory.prepending("/a", to: "/usr/bin:/a:/bin") == "/a:/usr/bin:/bin")
    #expect(TabCLIDirectory.prepending("/a", to: nil) == "/a")
    #expect(TabCLIDirectory.prepending("/a", to: "/usr/bin::/bin") == "/a:/usr/bin:/bin")
}

@Test func HostedLaunchSpecCLIDirectoryNativeTabsGetItFirstOnPath() {
    let native = ShellProcessController.nativeExecLaunch(
        for: cliConfiguration(),
        shellIntegration: ShellIntegrationBootstrap(zdotdir: "/tmp/zdotdir"),
        inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
        terminfoDirectories: nil,
        mcpHelperPath: nil,
        controlSocketPath: nil,
        cliPath: appCLI,
        cliDirectory: cliDirectory
    )
    #expect(native.environment[TabCLIDirectory.environmentKey] == cliDirectory)
    #expect(native.environment["PATH"] == "\(cliDirectory):/usr/bin:/bin")
    #expect(native.environment[CherryControl.cliEnvironmentKey] == appCLI)

    // A command's own PATH keeps its order behind it.
    let command = ShellProcessController.nativeExecLaunch(
        for: cliConfiguration(environment: ["PATH": "/opt/tool/bin:/usr/bin"]),
        shellIntegration: nil,
        inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
        terminfoDirectories: nil,
        mcpHelperPath: nil,
        controlSocketPath: nil,
        cliPath: appCLI,
        cliDirectory: cliDirectory
    )
    #expect(command.environment["PATH"] == "\(cliDirectory):/opt/tool/bin:/usr/bin")

    // Without one (tests, no cherry), nothing changes.
    let none = ShellProcessController.nativeExecLaunch(
        for: cliConfiguration(),
        shellIntegration: nil,
        inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
        terminfoDirectories: nil,
        mcpHelperPath: nil,
        controlSocketPath: nil,
        cliPath: appCLI,
        cliDirectory: nil
    )
    #expect(none.environment[TabCLIDirectory.environmentKey] == nil)
    #expect(none.environment["PATH"] == nil)
}

/// A hosted tab keeps the session's own PATH (its base environment's,
/// with Ghostty's bin directory), with `cherry`'s directory first, not the
/// app's PATH that its native launch would have used.
@Test func HostedLaunchSpecCLIDirectoryHostedTabsKeepTheirLoginPath() throws {
    let context = HostedLaunchContext(
        processEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/tester"],
        loginEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        account: HostedLaunchAccount(userName: "tester", homeDirectory: "/Users/tester", shell: "/bin/zsh"),
        launchedFromDesktop: true,
        ghosttyResources: nil,
        zshBootstrap: ShellIntegrationBootstrap(zdotdir: "/tmp/zdotdir"),
        executableDirectory: "/Applications/Cherry.app/Contents/MacOS",
        terminalProgramVersion: nil,
        shellFeatures: HostedLaunchContext.ghosttyShellFeatures(cursorBlink: true),
        controlSocketPath: nil,
        cliPath: appCLI,
        cliDirectory: cliDirectory
    )
    var without = context
    without.cliDirectory = nil
    let plain = HostedLaunchSpec.make(for: cliConfiguration(), context: without)
    let sessionPath = try #require(plain.environment["PATH"])
    #expect(sessionPath.hasSuffix(":/Applications/Cherry.app/Contents/MacOS"))
    #expect(plain.environment[TabCLIDirectory.environmentKey] == nil)

    let spec = HostedLaunchSpec.make(for: cliConfiguration(), context: context)
    #expect(spec.environment["PATH"] == "\(cliDirectory):\(sessionPath)")
    #expect(spec.environment[TabCLIDirectory.environmentKey] == cliDirectory)
}

/// The zsh bootstrap puts `cherry`'s directory first again after the
/// user's `.zshrc`, which may set PATH from scratch, before Cherry's
/// integration runs a tab's startup command.
@Test func HostedLaunchSpecCLIDirectoryZshBootstrapPutsItFirstAfterTheUsersFiles() throws {
    let zshrc = try #require(ShellIntegrationBootstrap.zshBootstrapFiles.first { $0.name == ".zshrc" }?.contents)
    let source = try #require(zshrc.range(of: "source \"$_cherry_original_zdotdir/.zshrc\""))
    let prepend = try #require(zshrc.range(of: "path=(\"$CHERRY_BIN_DIR\""))
    let integration = try #require(zshrc.range(of: "cherry-integration.zsh"))
    #expect(source.upperBound < prepend.lowerBound && prepend.upperBound < integration.lowerBound)

    // Run it: a .zshrc that sets PATH from scratch still leaves cherry first.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zsh-cli-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let bootstrap = root.appendingPathComponent("zdotdir", isDirectory: true)
    let bin = root.appendingPathComponent("bin dir", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("export PATH=/usr/bin:/bin\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
    for file in ShellIntegrationBootstrap.zshBootstrapFiles {
        try Data(file.contents.utf8).write(to: bootstrap.appendingPathComponent(file.name))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i", "-c", "print -r -- $PATH"]
    process.environment = [
        "HOME": home.path,
        "ZDOTDIR": bootstrap.path,
        "CHERRY_BOOTSTRAP_ZDOTDIR": bootstrap.path,
        "CHERRY_DISABLE_SHELL_INTEGRATION": "1",
        TabCLIDirectory.environmentKey: bin.path,
        "PATH": "\(bin.path):/usr/bin:/bin",
        "TERM": "dumb",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(path.split(separator: "\n").last.map(String.init) == "\(bin.path):/usr/bin:/bin")
}

/// A device's commands and agents get their install's directory first on
/// the login PATH their line sets; a device without the install's `cherry`
/// keeps its PATH as it is.
@Test func HostedLaunchSpecCLIDirectoryDeviceCommandsGetTheirInstallsDirectory() {
    let install = "/Users/them/Library/Application Support/cherry-host/bin/b1"
    let tab = UUID()
    let mcp = RemoteMCPLaunch(
        deviceID: UUID(), socketPath: "/var/folders/x/T/cherry-mcp-1/control.sock", helperPath: "\(install)/CherryMCP",
        cliPath: "\(install)/cherry", controlMachine: "Laptop", tokens: RemoteMCPTokens(key: SymmetricKey(size: .bits256))
    )
    let configuration = ShellProcessController.Configuration(
        shellPath: "/bin/zsh",
        workingDirectory: "/Users/them/app",
        projectRoot: nil,
        processID: tab.uuidString,
        agentID: nil,
        environment: [:],
        term: ShellProcessController.ghosttyTerm,
        initialSize: TerminalViewportSize(columns: 80, rows: 24),
        startupCommand: "make test"
    )
    let device = RemoteLaunchSpec.Device(
        shell: "/bin/zsh", homeDirectory: "/Users/them", mcp: mcp, loginEnvironment: ["PATH": "/Users/them/.local/bin:/usr/bin:/bin"]
    )
    let spec = RemoteLaunchSpec.make(for: configuration, device: device, localeEnvironment: [:])
    #expect(spec.environment[RemoteLaunchSpec.loginPathVariable] == "\(install):/Users/them/.local/bin:/usr/bin:/bin")

    var plainDevice = device
    plainDevice.mcp = nil
    let plain = RemoteLaunchSpec.make(for: configuration, device: plainDevice, localeEnvironment: [:])
    #expect(plain.environment[RemoteLaunchSpec.loginPathVariable] == "/Users/them/.local/bin:/usr/bin:/bin")
}
