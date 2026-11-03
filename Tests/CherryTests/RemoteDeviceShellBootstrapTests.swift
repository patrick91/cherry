import Foundation
import Testing
@testable import Cherry

// A device terminal's `cherry` (`RemoteShellBootstrap`): the launch
// `RemoteLaunchSpec` builds, run here as the holder runs it there (in a
// pseudo-terminal, with Ghostty's integration from an install's copy), in a
// temporary home whose startup files set PATH from scratch with another
// `cherry` first, as nix-darwin's /etc/zshenv and an older Cherry.app's
// ~/.local/bin link do. The install's comes first anyway, the user's files
// still run, and a second launch reuses the files the first wrote.

private struct BootstrapHome {
    let home: URL
    let installRoot: URL
    let resources: RemoteLaunchSpec.Resources

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-shell-\(UUID().uuidString.prefix(8))", isDirectory: true)
        installRoot = home.appendingPathComponent("Library/Application Support/cherry-host/bin/20260101000000.abc", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let source = try #require(GhosttyResourceStaging.bundledSource())
        try fileManager.copyItem(at: source.resourcesDirectory, to: installRoot.appendingPathComponent(GhosttyResourceStaging.resourcesName))
        try fileManager.copyItem(at: source.terminfoDirectory, to: installRoot.appendingPathComponent(GhosttyResourceStaging.terminfoName))
        try Self.tool(named: "cherry", in: installRoot)
        // The Mac's own, which its startup files put first.
        try Self.tool(named: "cherry", in: home.appendingPathComponent("other", isDirectory: true))
        resources = try #require(RemoteLaunchSpec.Resources.of(
            remoteHostPath: "~/\(RemoteHostInstall.rootRelativePath)/20260101000000.abc/cherry-host",
            homeDirectory: home.path
        ))
        #expect(resources.root == installRoot.path)
    }

    private static func tool(named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try "#!/bin/sh\necho \(name)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func write(_ text: String, to name: String) throws {
        let file = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The terminal's launch for `shell`, run in a pseudo-terminal with
    /// `input` typed: what it printed.
    func run(shell: String, input: String) throws -> (output: String, spec: HostedLaunchSpec) {
        let configuration = ShellProcessController.Configuration(
            shellPath: shell, workingDirectory: home.path, projectRoot: nil,
            term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 120, rows: 40), startupCommand: nil
        )
        let spec = RemoteLaunchSpec.make(
            for: configuration, device: .init(shell: shell, homeDirectory: home.path, resources: resources),
            cursorBlink: false, localeEnvironment: [:]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null"] + spec.argv
        // What the host adds (HOME, SHELL, a plain PATH).
        process.environment = spec.environment.merging([
            "HOME": home.path, "SHELL": shell, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]) { _, host in host }
        process.currentDirectoryURL = home
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? stdin.fileHandleForWriting.close()
        return (String(decoding: output, as: UTF8.self), spec)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

private let report = "printf 'CHERRY=%s RC=%s\\n' \"$(command -v cherry)\" \"$RC_RAN\"; exit\n"

@Test func RemoteDeviceShellBootstrapPutsTheInstallsCherryFirstInZshAfterItsStartupFiles() throws {
    let setup = try BootstrapHome()
    defer { setup.remove() }
    // PATH from scratch in .zshenv (as nix-darwin's /etc/zshenv), the
    // Mac's own `cherry` first in .zshrc.
    try setup.write("export PATH=/usr/bin:/bin\n", to: ".zshenv")
    try setup.write("export PATH=\"$HOME/other:$PATH\"\nexport RC_RAN=yes\n", to: ".zshrc")

    let first = try setup.run(shell: "/bin/zsh", input: report)
    #expect(first.spec.environment["CHERRY_BIN_DIR"] == setup.installRoot.path)
    #expect(first.output.contains("CHERRY=\(setup.installRoot.path)/cherry RC=yes"), "\(first.output)")
    let directory = RemoteShellBootstrap.directory(installRoot: setup.installRoot.path)
    #expect(directory == setup.home.path + "/Library/Application Support/cherry-host/shell/" + RemoteShellBootstrap.digest)
    let file = directory + "/" + RemoteShellBootstrap.Shell.zsh.path
    #expect(try String(contentsOfFile: file, encoding: .utf8) == RemoteShellBootstrap.zshenv)
    // Its files are only the shell's, none left half written.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["zsh"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory + "/zsh") == [".zshenv"])

    // Again: the file is there (not written again), same result.
    let modified = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
    let second = try setup.run(shell: "/bin/zsh", input: report)
    #expect(second.output.contains("CHERRY=\(setup.installRoot.path)/cherry RC=yes"), "\(second.output)")
    #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date == modified)
}

@Test func RemoteDeviceShellBootstrapFallsBackToGhosttysAloneWhenItsFilesCannotBeWritten() throws {
    let setup = try BootstrapHome()
    defer { setup.remove() }
    try setup.write("export PATH=\"$HOME/other:$PATH\"\nexport RC_RAN=yes\n", to: ".zshrc")
    // A file where the directory goes: nothing can be written there.
    try setup.write("", to: "Library/Application Support/cherry-host/shell")

    let run = try setup.run(shell: "/bin/zsh", input: report)
    // Today's terminal: the startup files ran, the Mac's own `cherry`.
    #expect(run.output.contains("CHERRY=\(setup.home.path)/other/cherry RC=yes"), "\(run.output)")
}

@Test func RemoteDeviceShellBootstrapPutsTheInstallsCherryFirstInBash() throws {
    // A bash Ghostty integrates (not Apple's /bin/bash).
    let candidates = ["/run/current-system/sw/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"]
    guard let bash = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    let setup = try BootstrapHome()
    defer { setup.remove() }
    try setup.write("export PATH=\"$HOME/other:/usr/bin:/bin\"\nexport RC_RAN=yes\n", to: ".bash_profile")

    let run = try setup.run(shell: bash, input: report)
    #expect(run.spec.environment["ENV"] == setup.resources.resourcesDirectory + "/shell-integration/bash/ghostty.bash")
    #expect(run.output.contains("CHERRY=\(setup.installRoot.path)/cherry RC=yes"), "\(run.output)")
}

@Test func RemoteDeviceShellBootstrapLeavesApplesBashAndUnknownShellsAsTheyWere() throws {
    let setup = try BootstrapHome()
    defer { setup.remove() }
    for shell in ["/bin/bash", "/bin/ksh"] {
        let configuration = ShellProcessController.Configuration(
            shellPath: shell, workingDirectory: setup.home.path, projectRoot: nil,
            term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 80, rows: 24), startupCommand: nil
        )
        let spec = RemoteLaunchSpec.make(
            for: configuration, device: .init(shell: shell, homeDirectory: setup.home.path, resources: setup.resources),
            localeEnvironment: [:]
        )
        #expect(spec.argv.last == "exec -l \(shell)", "\(shell)")
        #expect(spec.environment["CHERRY_BIN_DIR"] == nil, "\(shell)")
    }
}

@Test func RemoteDeviceShellBootstrapPutsTheInstallsCherryFirstInFish() throws {
    let candidates = [
        ProcessInfo.processInfo.environment["CHERRY_TEST_FISH"] ?? "",
        "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/run/current-system/sw/bin/fish",
    ]
    guard let fish = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else { return }
    let setup = try BootstrapHome()
    defer { setup.remove() }
    try setup.write("set -gx PATH $HOME/other /usr/bin /bin\nset -gx RC_RAN yes\n", to: ".config/fish/config.fish")

    let run = try setup.run(
        shell: fish,
        input: "printf 'CHERRY=%s RC=%s XDG=%s\\n' (command -v cherry) $RC_RAN \"$XDG_DATA_DIRS\"; exit\n"
    )
    #expect(run.output.contains("CHERRY=\(setup.installRoot.path)/cherry RC=yes"), "\(run.output)")
    // Its directory is out of XDG_DATA_DIRS again.
    #expect(!run.output.contains("cherry-host/shell"), "\(run.output)")
}
