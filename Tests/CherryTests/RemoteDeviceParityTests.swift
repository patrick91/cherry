import AppKit
import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Phase 3 of devices (docs/specs/remote-devices.md), without a real host:
// project-info parsing and caps, the shell integration a device's tabs get,
// editor links, `~` labels, Settings › Sessions' device rows, the quit
// question, Background Sessions per device (against the in-process fake
// `cherry control`), dropped files, and Ghostty's resources in the install.
// Nothing here runs ssh.

// MARK: - A device's hosting over the fake control

@MainActor
private final class DeviceHarness {
    let fake = FakeControlHelper()
    let cli: HostedSessionFakeCLI
    let control: HostControl
    let hosting: PersistentHostSessions
    let installationID = UUID()
    let deviceID = UUID()
    let host: HostedSessionHost
    private let suite: String

    init(name: String = "studio", displayName: String = "Studio", home: String? = "/Users/me") throws {
        cli = try HostedSessionFakeCLI()
        suite = "CherryTests.RemoteParity.\(UUID().uuidString)"
        host = try HostedSessionHost.ssh(name)
        let hostStore = HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite)))
        let executable = cli.executable
        control = HostControl(
            host: host,
            clientProvider: {
                HostedSessionClient(executableURL: executable, loginEnvironment: { _ in .init(environment: ["PATH": "/usr/bin"]) })
            },
            hostStore: hostStore,
            masters: disabledSSHMasters,
            launcher: fake.launcher,
            localHostUnavailableReason: nil,
            configuration: .fastTests
        )
        let control = control
        var configuration = PersistentHostSessions.Configuration.remote
        configuration.terminationTimeout = .seconds(3)
        configuration.restartExitTimeout = .seconds(3)
        configuration.reconnectDelay = (0.05, 0.2)
        configuration.lostCreateChecks = [.milliseconds(200)]
        fake.hostID = "host-\(name)"
        hosting = PersistentHostSessions.remote(
            profile: .remote(host: host, displayName: displayName, machineNames: ["studio.local"]) {
                RemoteLaunchSpec.Device(shell: "/bin/zsh", homeDirectory: home)
            },
            installationID: installationID,
            remoteShell: "/bin/zsh",
            control: { control },
            installationUnavailableReason: { nil },
            status: PersistentSessionsStatus(),
            instanceLock: nil,
            terminalColors: { nil },
            configuration: configuration
        )
    }

    var projectKey: String { ProjectLocation.remote(deviceID: deviceID, path: "/Users/me/work/app").key }

    func workspace() -> TerminalWorkspace {
        TerminalWorkspace(
            projectRoot: projectKey,
            createInitialSession: false,
            backendPolicy: SessionBackendPolicy(settings: { .native }, localSessions: hosting)
        )
    }

    /// A session of this installation on the device, for a closed tab.
    func ownSession(_ id: String, command: String? = nil, running: Bool = true) -> HostedSessionInfo {
        var tags = [
            PersistentSessionTag.tab: UUID().uuidString,
            PersistentSessionTag.kind: command == nil ? "terminal" : "command",
            PersistentSessionTag.project: projectKey,
        ]
        if let command { tags[PersistentSessionTag.command] = command }
        return HostedSessionInfo(
            id: id, name: "Session", cwd: "/Users/me/work/app", state: running ? .running : .exited, pid: 300,
            exitCode: running ? nil : 1, owner: hosting.owner, tags: tags
        )
    }

    func cleanUp() {
        control.disconnect()
        cli.cleanUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - project-info

private func output(_ text: String, status: Int32 = 0, errors: String = "") -> RemoteDeviceShell.DataOutput {
    RemoteDeviceShell.DataOutput(status: status, standardOutput: Data(text.utf8), standardError: errors)
}

@Test func RemoteDeviceProjectInfoIsParsedWithItsWorktreesAndCherryToml() throws {
    let json = """
    {"version":1,"projects":[{"path":"/Users/me/app","exists":true,"is_directory":true,\
    "git":{"top_level":"/Users/me/app","common_dir":"/Users/me/app/.git",\
    "worktrees":"worktree /Users/me/app\\u0000HEAD 1111111\\u0000branch refs/heads/main\\u0000\\u0000worktree /Users/me/wt/feature\\u0000HEAD 2222222\\u0000branch refs/heads/feature\\u0000locked\\u0000\\u0000"},\
    "cherry_toml":{"size":38,"text":"[commands.web]\\ncommand = \\"npm run\\"\\n"}},\
    {"path":"/Users/me/none","exists":false,"is_directory":false,"git":null,"cherry_toml":null}]}
    """
    let report = try RemoteProjectAccess.parseProjectInfo(
        output("login banner\n\(RemoteProjectAccess.projectInfoBegin)\n\(json)\n"), machine: "Studio"
    )
    let app = try #require(report.project(at: "/Users/me/app"))
    #expect(app.isDirectory && app.exists)
    #expect(app.cherryTomlText == "[commands.web]\ncommand = \"npm run\"\n")
    #expect(app.cherryTomlProblem == nil)
    let snapshot = try #require(app.git).snapshot()
    #expect(snapshot.commonDirectory == "/Users/me/app/.git")
    #expect(snapshot.worktrees.map(\.root) == ["/Users/me/app", "/Users/me/wt/feature"])
    #expect(snapshot.worktrees.map(\.branch) == ["main", "feature"])
    #expect(snapshot.worktrees[0].isMain && !snapshot.worktrees[1].isMain)
    #expect(snapshot.worktrees[1].isLocked)
    let missing = try #require(report.project(at: "/Users/me/none"))
    #expect(!missing.exists && missing.git == nil && missing.cherryTomlText == nil)
}

@Test func RemoteDeviceProjectInfoCapsAndFailuresAreReported() throws {
    let begin = RemoteProjectAccess.projectInfoBegin
    // cherry.toml larger than 256 KiB: the host sends none; one sent anyway
    // is refused here too.
    let large = """
    {"version":1,"projects":[{"path":"/p","exists":true,"is_directory":true,"git":null,\
    "cherry_toml":{"size":300000,"text":null,"error":"cherry.toml is larger than 256 KiB"}}]}
    """
    let tooLarge = try #require(try RemoteProjectAccess.parseProjectInfo(output("\(begin)\n\(large)"), machine: "Studio").projects.first)
    #expect(tooLarge.cherryTomlText == nil)
    #expect(tooLarge.cherryTomlProblem == "cherry.toml is larger than 256 KiB")
    let sneaky = RemoteProjectInfo(
        path: "/p", exists: true, isDirectory: true,
        cherryToml: .init(size: 1, text: String(repeating: "#", count: Int(RemoteProjectAccess.cherryTomlLimit) + 1))
    )
    #expect(sneaky.cherryTomlText == nil)
    #expect(sneaky.cherryTomlProblem?.contains("256 KiB") == true)
    let exact = RemoteProjectInfo(
        path: "/p", exists: true, isDirectory: true,
        cherryToml: .init(size: 1, text: String(repeating: "#", count: Int(RemoteProjectAccess.cherryTomlLimit)))
    )
    #expect(exact.cherryTomlText?.utf8.count == Int(RemoteProjectAccess.cherryTomlLimit))

    // ssh could not reach it.
    #expect(throws: RemoteProjectError.unreachable(RemoteDeviceSSHFailure.classify("ssh: connect to host studio port 22: Connection timed out").message)) {
        try RemoteProjectAccess.parseProjectInfo(output("", status: 255, errors: "ssh: connect to host studio port 22: Connection timed out"), machine: "Studio")
    }
    // An older cherry-host has no project-info.
    #expect(throws: RemoteProjectError.unsupported("Studio")) {
        try RemoteProjectAccess.parseProjectInfo(
            output("\(begin)\n", status: 2, errors: "error: unrecognized subcommand 'project-info'"), machine: "Studio"
        )
    }
    // A newer format.
    #expect(throws: RemoteProjectError.unsupported("Studio")) {
        try RemoteProjectAccess.parseProjectInfo(output("\(begin)\n{\"version\":2,\"projects\":[]}"), machine: "Studio")
    }
    // Garbage, and an answer longer than Cherry reads.
    #expect(throws: RemoteProjectError.self) {
        try RemoteProjectAccess.parseProjectInfo(output("\(begin)\nnot json"), machine: "Studio")
    }
    let huge = "\(begin)\n" + String(repeating: " ", count: RemoteProjectAccess.reportLimit + 10) + "{}"
    #expect(throws: RemoteProjectError.invalid("Studio described its project at more length than Cherry reads.")) {
        try RemoteProjectAccess.parseProjectInfo(output(huge), machine: "Studio")
    }
}

@Test func RemoteDeviceProjectInfoAndGitScriptsQuoteEveryPathForSh() throws {
    let script = RemoteProjectAccess.projectInfoScript(
        paths: ["/Users/me/it's here", "/Users/me/$(oops)"],
        remoteHostPath: "~/Library/Application Support/cherry-host/bin/b/cherry-host"
    )
    #expect(script.contains("host=\"$HOME\"/'Library/Application Support/cherry-host/bin/b/cherry-host'"))
    #expect(script.contains("exec \"$host\" project-info --json '/Users/me/it'\\''s here' '/Users/me/$(oops)'"))
    #expect(script.contains("CHERRY_GIT=$git; export CHERRY_GIT"))
    // /usr/bin/git only with the command line tools (else it asks to
    // install them on that Mac's screen).
    #expect(script.contains("/usr/bin/xcode-select -p"))
    let git = RemoteProjectAccess.gitScript(["-C", "/Users/me/a b", "worktree", "list", "--porcelain", "-z"], machine: "Studio")
    #expect(git.hasSuffix("exec \"$git\" '-C' '/Users/me/a b' 'worktree' 'list' '--porcelain' '-z'\n"))
    #expect(git.contains("GIT_TERMINAL_PROMPT=0"))
    // Run through sh, the script finds this Mac's git and runs it.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    let input = Pipe()
    let out = Pipe()
    process.standardInput = input
    process.standardOutput = out
    try process.run()
    input.fileHandleForWriting.write(Data(RemoteProjectAccess.gitScript(["--version"], machine: "Studio").utf8))
    try input.fileHandleForWriting.close()
    let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(printed.hasPrefix("git version"))
}

@Test @MainActor func RemoteDeviceCherryTomlIsReadFromWhatTheDeviceReportedAndNeverWritten() throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    #expect(CherryProjectFile.loadCommands(projectRoot: key).isEmpty)
    #expect(!CherryProjectFile.exists(projectRoot: key))
    RemoteProjectFiles.shared.record(
        RemoteProjectInfo(
            path: "/Users/me/app", exists: true, isDirectory: true,
            cherryToml: .init(size: 1, text: """
            [[commands]]
            name = "web"
            command = "npm run dev"
            autoStart = true

            [features]
            todos = true
            """)
        ),
        for: key
    )
    defer { RemoteProjectFiles.shared.set(nil, for: key) }
    #expect(CherryProjectFile.exists(projectRoot: key))
    let commands = CherryProjectFile.loadCommands(projectRoot: key)
    #expect(commands.map(\.name) == ["web"])
    #expect(commands.first?.autoStart == true)
    #expect(CherryProjectFile.loadFeatureSettings(projectRoot: key)?.todosEnabled == true)
    // Read again when the device reports another file.
    RemoteProjectFiles.shared.record(
        RemoteProjectInfo(path: "/Users/me/app", exists: true, isDirectory: true, cherryToml: .init(size: 1, text: "[[commands]]\nname = \"api\"\ncommand = \"make api\"\n")),
        for: key
    )
    #expect(CherryProjectFile.loadCommands(projectRoot: key).map(\.name) == ["api"])
    // Never written: a clear error, and the editor's note.
    #expect(throws: CherryProjectFile.RemoteProjectFileError.self) {
        try CherryProjectFile.upsertCommand(commands[0], projectRoot: key, replacing: nil)
    }
    #expect(CherryProjectFile.RemoteProjectFileError().errorDescription?.contains("read-only") == true)
    #expect(CherryProjectFile.remoteReadOnlyNote.contains("on this Mac only"))
}

@Test func RemoteDeviceProjectInfoWithoutAGitThereRunsNoGit() throws {
    // A stand-in cherry-host that says whether CHERRY_GIT reached it.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-nogit-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let host = directory.appendingPathComponent("cherry-host")
    try "#!/bin/sh\nprintf 'git=[%s]\\n' \"${CHERRY_GIT-unset}\"\n".write(to: host, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
    func run(_ candidates: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        // An inherited CHERRY_GIT is dropped too.
        process.environment = ["PATH": "/bin", "CHERRY_GIT": "/usr/bin/git"]
        let input = Pipe()
        let out = Pipe()
        process.standardInput = input
        process.standardOutput = out
        try process.run()
        input.fileHandleForWriting.write(Data(RemoteProjectAccess.projectInfoScript(
            paths: ["/p"], remoteHostPath: host.path, gitCandidates: candidates
        ).utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }
    #expect(try run(["/nonexistent/git", "\"$(command -v git 2>/dev/null)\""]).contains("git=[unset]"))
    // With one found, it is passed.
    let git = directory.appendingPathComponent("git")
    try "#!/bin/sh\n".write(to: git, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
    #expect(try run([git.path]).contains("git=[\(git.path)]"))
}

// MARK: - Shell integration on the device

@Test func RemoteDeviceTerminalsGetGhosttysTerminfoAndShellIntegrationThere() throws {
    let resources = try #require(RemoteLaunchSpec.Resources.of(
        remoteHostPath: "~/Library/Application Support/cherry-host/bin/20260101000000.abc/cherry-host",
        homeDirectory: "/Users/me"
    ))
    let root = "/Users/me/Library/Application Support/cherry-host/bin/20260101000000.abc"
    #expect(resources.root == root)
    #expect(resources.terminfoDirectory == root + "/terminfo")
    #expect(resources.resourcesDirectory == root + "/Ghostty")
    // Not ours, or no home: none.
    #expect(RemoteLaunchSpec.Resources.of(remoteHostPath: "/usr/local/bin/cherry-host", homeDirectory: "/Users/me") == nil)
    #expect(RemoteLaunchSpec.Resources.of(remoteHostPath: "~/Library/Application Support/cherry-host/bin/b/cherry-host", homeDirectory: nil) == nil)

    let projectKey = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    func configuration(_ line: String? = nil) -> ShellProcessController.Configuration {
        ShellProcessController.Configuration(
            shellPath: "/bin/zsh", workingDirectory: "/Users/me/app", projectRoot: projectKey,
            term: "xterm-ghostty", initialSize: TerminalViewportSize(columns: 80, rows: 24), startupCommand: line
        )
    }
    let terminal = configuration()
    // zsh: its login shell through bash's `exec -l`, with ZDOTDIR on
    // Ghostty's zsh integration there.
    let zsh = RemoteLaunchSpec.make(
        for: terminal, device: .init(shell: "/bin/zsh", homeDirectory: "/Users/me", resources: resources),
        cursorBlink: false, localeEnvironment: ["LANG": "en_GB.UTF-8"]
    )
    #expect(zsh.argv == ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l /bin/zsh"])
    #expect(zsh.environment["TERM"] == "xterm-ghostty")
    #expect(zsh.environment["TERMINFO"] == root + "/terminfo")
    #expect(zsh.environment["GHOSTTY_RESOURCES_DIR"] == root + "/Ghostty")
    #expect(zsh.environment["ZDOTDIR"] == root + "/Ghostty/shell-integration/zsh")
    #expect(zsh.environment["GHOSTTY_SHELL_FEATURES"] == "cursor:steady,path,title")
    #expect(zsh.environment["COLORTERM"] == "truecolor")
    #expect(zsh.environment["LANG"] == "en_GB.UTF-8")
    #expect(zsh.environment["CHERRY_PROJECT_ROOT"] == "/Users/me/app")
    // Nothing names This Mac.
    for key in ["PATH", "HOME", "SHELL", CherryControl.socketEnvironmentKey] { #expect(zsh.environment[key] == nil) }

    // A newer bash: POSIX mode with Ghostty's ENV hook.
    let bash = RemoteLaunchSpec.make(
        for: terminal, device: .init(shell: "/opt/homebrew/bin/bash", homeDirectory: "/Users/me", resources: resources),
        localeEnvironment: [:]
    )
    #expect(bash.argv == ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l /opt/homebrew/bin/bash --posix"])
    #expect(bash.environment["ENV"] == root + "/Ghostty/shell-integration/bash/ghostty.bash")
    #expect(bash.environment["HISTFILE"] == "/Users/me/.bash_history")
    // fish: its data directories.
    let fish = RemoteLaunchSpec.make(
        for: terminal, device: .init(shell: "/opt/homebrew/bin/fish", homeDirectory: "/Users/me", resources: resources),
        localeEnvironment: [:]
    )
    #expect(fish.argv.last == "exec -l /opt/homebrew/bin/fish")
    #expect(fish.environment["XDG_DATA_DIRS"] == root + "/Ghostty/shell-integration:/usr/local/share:/usr/share")

    // A command: its line through the login shell, with the terminfo.
    let command = configuration("npm run dev")
    let commandSpec = RemoteLaunchSpec.make(
        for: command, device: .init(shell: "/bin/zsh", homeDirectory: "/Users/me", resources: resources), localeEnvironment: [:]
    )
    #expect(commandSpec.argv == ["/bin/zsh", "-l", "-c", "npm run dev"])
    #expect(commandSpec.environment["TERM"] == "xterm-ghostty")
    #expect(commandSpec.environment["ZDOTDIR"] == nil)

    // Without the resources (an older install): phase 1's launch.
    let plain = RemoteLaunchSpec.make(for: terminal, device: .init(shell: "/bin/zsh", homeDirectory: "/Users/me"), localeEnvironment: [:])
    #expect(plain.argv.isEmpty)
    #expect(plain.environment["TERM"] == "xterm-256color")
    #expect(plain.environment["TERMINFO"] == nil && plain.environment["ZDOTDIR"] == nil)
    // A shell not known: the host's own login shell, with the terminfo.
    let unknown = RemoteLaunchSpec.make(for: terminal, device: .init(resources: resources), localeEnvironment: [:])
    #expect(unknown.argv.isEmpty)
    #expect(unknown.environment["TERM"] == "xterm-ghostty")
}

@Test @MainActor func RemoteDeviceRecordsGiveItsTabsTheShellHomeAndResourcesOfItsInstall() throws {
    var device = RemoteDevice(
        name: "Studio", sshDestination: "studio",
        remoteHostPath: "~/Library/Application Support/cherry-host/bin/b1/cherry-host",
        homeDirectory: "/Users/me", installedBuild: "b1", shell: "/bin/zsh"
    )
    #expect(device.launchDevice == RemoteLaunchSpec.Device(shell: "/bin/zsh", homeDirectory: "/Users/me", resources: nil))
    device.installedResources = true
    #expect(device.launchDevice.resources?.root == "/Users/me/Library/Application Support/cherry-host/bin/b1")
    // Saved and read back; an older devices.json has neither.
    let data = try JSONEncoder().encode(device)
    #expect(try JSONDecoder().decode(RemoteDevice.self, from: data) == device)
    let old = #"{"id":"\#(UUID().uuidString)","name":"Mini","sshDestination":"mini"}"#
    let decoded = try JSONDecoder().decode(RemoteDevice.self, from: Data(old.utf8))
    #expect(decoded.shell == nil && !decoded.installedResources)
}

// MARK: - Ghostty's resources in the install

@Test func RemoteDeviceResourcesDigestMatchesWhatTheOtherMacsScriptComputes() throws {
    let source = try #require(GhosttyResourceStaging.bundledSource())
    let installable = try #require(RemoteHostResources.installable(source))
    let digest = try RemoteHostResources.digest(of: installable)
    #expect(digest.count == 64)
    // Laid out as the install does, the shell function agrees.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-res-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.copyItem(at: installable.resourcesDirectory, to: directory.appendingPathComponent("Ghostty"))
    try FileManager.default.copyItem(at: installable.terminfoDirectory, to: directory.appendingPathComponent("terminfo"))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("terminfo/78/xterm-ghostty").path))
    func shellHash(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", (RemoteHostResources.hashFunction + ["resources_hash \"$1\""]).joined(separator: "\n"), "sh", path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #expect(try shellHash(directory.path) == digest)
    // Changed, or missing: another digest, or `-`.
    try "# changed\n".write(to: directory.appendingPathComponent("Ghostty/shell-integration/bash/ghostty.bash"), atomically: true, encoding: .utf8)
    #expect(try shellHash(directory.path) != digest)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("terminfo"))
    #expect(try shellHash(directory.path) == "-")

    // The probe reports each build's digest; a build matches only with the
    // same resources.
    let helpers = RemoteHostHelpers(
        directory: directory, version: .init(protocol: HostProtocol.version, build: "b"), architectures: ["arm64"],
        hashes: ["h1", "h2"], resources: installable, resourcesHash: digest
    )
    #expect(RemoteInstalledBuild(name: "b", hashes: ["h1", "h2"], resourcesHash: digest).matches(helpers))
    #expect(!RemoteInstalledBuild(name: "b", hashes: ["h1", "h2"], resourcesHash: "-").matches(helpers))
    #expect(!RemoteInstalledBuild(name: "b", hashes: ["h1", "h2"]).matches(helpers))
    let probe = RemoteDeviceProbe.parse(.init(status: 0, standardOutput: """
    \(RemoteDeviceProbe.beginMarker)
    uname=Darwin arm64
    installed=b h1 h2
    resources=b \(digest)
    installed=old h3 h4
    resources=old -
    \(RemoteDeviceProbe.endMarker)
    """, standardError: ""))
    #expect(probe.installedBuilds == [
        RemoteInstalledBuild(name: "b", hashes: ["h1", "h2"], resourcesHash: digest),
        RemoteInstalledBuild(name: "old", hashes: ["h3", "h4"], resourcesHash: "-"),
    ])
    // The archive carries both trees next to the helpers.
    let arguments = RemoteHostInstaller.archiveArguments(helpers)
    #expect(Array(arguments.suffix(6)) == [
        "-C", installable.resourcesDirectory.deletingLastPathComponent().path, "Ghostty",
        "-C", installable.terminfoDirectory.deletingLastPathComponent().path, "terminfo",
    ])
    // The check of a copy compares the digest.
    var verification = RemoteHostInstaller.Verification(fields: [
        ("codesign", "ok"), ("verify_status", "0"),
        ("verify", #"{"protocol":\#(HostProtocol.version),"build":"b"}"#), ("hashes", "h1 h2 "), ("resources_hash", "-"),
    ])
    #expect(verification.problem(expected: helpers, machine: "Studio")?.contains("terminfo and shell integration") == true)
    verification.resourcesHash = digest
    #expect(verification.problem(expected: helpers, machine: "Studio") == nil)
}

// MARK: - Editors

@Test @MainActor func RemoteDeviceProjectsOpenInEditorsThatReachThemOverSSH() throws {
    func editor(_ id: String, _ bundle: String, app: String) -> InstalledEditor {
        InstalledEditor(
            editor: try! #require(ExternalEditorCatalog.all.first { $0.id == id }),
            bundleIdentifier: bundle, appURL: URL(fileURLWithPath: "/Applications/\(app).app")
        )
    }
    let vscode = editor("vscode", "com.microsoft.VSCode", app: "Visual Studio Code")
    let insiders = editor("vscode", "com.microsoft.VSCodeInsiders", app: "Code Insiders")
    let cursor = editor("cursor", "com.todesktop.230313mzl4w4u92", app: "Cursor")
    let zed = editor("zed", "dev.zed.Zed", app: "Zed")
    let sublime = editor("sublime-text", "com.sublimetext.4", app: "Sublime Text")

    #expect(RemoteEditorLink.make(editor: vscode, destination: "me@studio", path: "/Users/me/my app")
        == .url(URL(string: "vscode://vscode-remote/ssh-remote+me@studio/Users/me/my%20app")!))
    #expect(RemoteEditorLink.make(editor: insiders, destination: "studio", path: "/p")
        == .url(URL(string: "vscode-insiders://vscode-remote/ssh-remote+studio/p")!))
    #expect(RemoteEditorLink.make(editor: cursor, destination: "studio", path: "/p")
        == .url(URL(string: "cursor://vscode-remote/ssh-remote+studio/p")!))
    #expect(RemoteEditorLink.make(editor: zed, destination: "studio", path: "/Users/me/app")
        == .url(URL(string: "zed://ssh/studio/Users/me/app")!))
    // A path with spaces: percent-encoded, and it decodes (as Zed decodes
    // its hotlink's path) to the path itself; the host stays as typed.
    guard case .url(let spaced)? = RemoteEditorLink.make(editor: zed, destination: "me@studio.local", path: "/Users/me/my app/ü") else {
        Issue.record("no Zed link")
        return
    }
    #expect(spaced.absoluteString == "zed://ssh/me@studio.local/Users/me/my%20app/%C3%BC")
    #expect(spaced.path(percentEncoded: false) == "/me@studio.local/Users/me/my app/ü")
    #expect(!spaced.absoluteString.contains(" "))
    #expect(RemoteEditorLink.make(editor: sublime, destination: "studio", path: "/p") == nil)
    #expect(RemoteEditorLink.make(editor: zed, destination: "studio", path: "relative") == nil)

    // A device's project offers only the editors that can reach it.
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let installed = [zed, vscode, sublime]
    #expect(ExternalEditorLauncher.editors(installed, forProjectRoot: key).map(\.id) == ["zed", "vscode"])
    #expect(ExternalEditorLauncher.editors(installed, forProjectRoot: "/Users/me/local").map(\.id) == ["zed", "vscode", "sublime-text"])

    // Opening goes through the injected opener, never NSWorkspace here.
    var opened: [(RemoteEditorLink, String)] = []
    var localOpens: [URL] = []
    let launcher = ExternalEditorLauncher(
        openHandler: { folder, _ in localOpens.append(folder) },
        remoteOpener: { link, editor in opened.append((link, editor.id)) },
        destination: { $0 == key ? "studio" : nil }
    )
    launcher.open(projectRoot: key, with: vscode)
    launcher.open(projectRoot: key, with: sublime)
    launcher.open(projectRoot: ProjectLocation.remote(deviceID: UUID(), path: "/x").key, with: zed)
    launcher.open(projectRoot: key, with: zed)
    #expect(opened.map(\.1) == ["vscode", "zed"])
    #expect(opened.first?.0 == .url(URL(string: "vscode://vscode-remote/ssh-remote+studio/Users/me/app")!))
    #expect(localOpens.isEmpty)
    launcher.open(projectRoot: "/Users/me/local", with: sublime)
    #expect(localOpens == [URL(fileURLWithPath: "/Users/me/local", isDirectory: true)])
}

// MARK: - `~` labels

@Test @MainActor func RemoteDeviceTabsShortenPathsWithTheDevicesHome() async throws {
    #expect(SidebarTerminalPathFormatter.displayPath("/Users/me/work/app", homeDirectory: "/Users/me") == "~/work/app")
    #expect(SidebarTerminalPathFormatter.displayPath("/Users/me", homeDirectory: "/Users/me") == "~")
    // A home that is not known shortens nothing (never with This Mac's).
    #expect(SidebarTerminalPathFormatter.displayPath(NSHomeDirectory() + "/x", homeDirectory: "") == NSHomeDirectory() + "/x")
    #expect(SidebarTerminalPathFormatter.label(for: "/Users/me/github/o/repo", mode: .repoFocused, homeDirectory: "/Users/me").detail == "o/repo")

    let harness = try DeviceHarness(home: "/Users/me")
    defer { harness.cleanUp() }
    #expect(harness.hosting.profile.homeDirectory == "/Users/me")
    #expect(PersistentHostProfile.thisMac.homeDirectory == NSHomeDirectory())
    let workspace = harness.workspace()
    let tab = workspace.addSession(title: "Remote")
    #expect(tab.pathHomeDirectory == "/Users/me")
    #expect(tab.workingDirectory == "/Users/me/work/app")
    #expect(TerminalContextBarContent(session: tab).displayPath == "~/work/app")
    let unknown = try DeviceHarness(name: "mini", displayName: "Mini", home: nil)
    defer { unknown.cleanUp() }
    let other = unknown.workspace().addSession(title: "Remote")
    #expect(other.pathHomeDirectory == "")
    workspace.closeAllSessions(intent: .windowClosed)
}

// MARK: - Settings › Sessions

@Test @MainActor func RemoteDeviceSettingsListEachMacsStatusAndWhatToDo() throws {
    let device = RemoteDevice(
        name: "Studio", sshDestination: "studio", installedBuild: "20260101000000.old", installedResources: true
    )
    let connected = RemoteDeviceSettingsRow(device: device, state: .connected(sessionCount: 2), bundledBuild: "20260101000000.old")
    #expect(connected.statusText() == "Connected · 2 sessions")
    #expect(!connected.updateAvailable && !connected.offersReconnect && connected.dot == .green)
    let update = RemoteDeviceSettingsRow(device: device, state: .connected(sessionCount: 1), bundledBuild: "20260301000000.new")
    #expect(update.statusText() == "Connected · 1 session · Update available")
    #expect(update.updateTitle == "Update Session Host…")
    let offline = RemoteDeviceSettingsRow(device: device, state: .offline(reason: "Connection timed out"), bundledBuild: nil)
    #expect(offline.statusText() == "Offline" && offline.detail == "Connection timed out" && offline.offersReconnect)
    let refused = RemoteDeviceSettingsRow(device: device, state: .loginRefused(reason: "Permission denied"), bundledBuild: nil)
    #expect(refused.statusText() == "Needs attention")
    #expect(refused.detail == "SSH login refused: Permission denied" && refused.dot == .red)
    let identity = RemoteDeviceSettingsRow(device: device, state: .identityChanged(reason: "x"), bundledBuild: nil)
    #expect(identity.offersTrustNewIdentity && !identity.offersReconnect)
    let missing = RemoteDeviceSettingsRow(device: device, state: .hostMissing(reason: "gone"), bundledBuild: nil)
    #expect(missing.updateAvailable && missing.updateTitle == "Reinstall Session Host…")
    let never = RemoteDeviceSettingsRow(device: device, state: .unknown(lastSeen: nil), bundledBuild: nil)
    #expect(never.statusText() == "Not checked yet")
    // An install without Ghostty's resources (before phase 3) is offered the
    // update even at the same build; one with them is not.
    var installed = device
    installed.installedBuild = "20260301000000.new"
    installed.installedResources = false
    #expect(RemoteDeviceSettingsRow(device: installed, state: .connected(sessionCount: 0), bundledBuild: "20260301000000.new").updateAvailable)
    installed.installedResources = true
    #expect(!RemoteDeviceSettingsRow(device: installed, state: .connected(sessionCount: 0), bundledBuild: "20260301000000.new").updateAvailable)

    // The model lists the store's devices from their controls, connecting
    // none.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-rds-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "CherryTests.RemoteSettings.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let store = RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite))),
        installationID: { UUID() },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: HostedRemoteHostPaths()
    )
    let added = try store.add(name: "Studio", sshDestination: "studio", installedBuild: "20260101000000.old")
    _ = try store.add(name: "Mini", sshDestination: "mini")
    var controls: [HostedSessionHost: HostControl] = [:]
    let model = RemoteDeviceSettingsModel(
        store: store,
        control: { host in
            if let control = controls[host] { return control }
            let control = RemoteDeviceStore.inertControl(host: host, reason: "test")
            controls[host] = control
            return control
        },
        bundledBuild: { "20260301000000.new" }
    )
    #expect(model.rows.map(\.name) == ["Studio", "Mini"])
    #expect(model.rows.first?.statusText().hasSuffix("Update available") == true)
    #expect(model.rows.first?.id == added.id)
    #expect(controls.values.allSatisfy { $0.state == .idle })
}

// MARK: - The quit question and End Sessions

@Test @MainActor func RemoteDeviceQuitQuestionSaysWhichMacsSessionsKeepRunning() {
    func session(_ machine: String?) -> SessionTeardownSummary.Session {
        .init(id: UUID(), hostSessionID: nil, title: "zsh", place: nil, isBusy: false, machine: machine)
    }
    func question(_ machines: [String?]) -> String {
        SessionTeardownQuestion(
            teardown: .quit, summary: SessionTeardownSummary(runningSessions: machines.map(session)), projectName: nil
        ).messageText
    }
    #expect(question([nil, nil, "Studio", nil, "Studio"]) == "Keep 5 sessions running (3 on this Mac, 2 on Studio)?")
    #expect(question(["Studio", nil, "Mini"]) == "Keep 3 sessions running (1 on this Mac, 1 on Studio, 1 on Mini)?")
    #expect(question(["Studio", "Studio"]) == "Keep 2 sessions running on Studio?")
    #expect(question(["Studio"]) == "Keep 1 session running on Studio?")
    #expect(question([nil, nil]) == "Keep 2 sessions running in the background?")
}

@Test @MainActor func RemoteDeviceEndSessionsEndsTheDevicesSessionsToo() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    let workspace = harness.workspace()
    let tab = workspace.addSession(title: "Remote")
    #expect(await eventually { tab.persistentSession != nil })
    let summary = workspace.teardownSummary(.quit, place: "app", pathDisplayMode: .fullPath)
    #expect(summary.runningSessions.map(\.machine) == ["Studio"])
    #expect(SessionTeardownQuestion(teardown: .quit, summary: summary, projectName: nil).messageText == "Keep 1 session running on Studio?")
    let sessionID = try #require(tab.persistentSession?.sessionID)
    workspace.closeAllSessions(intent: .appQuitEndingSessions)
    #expect(await eventually { harness.fake.requests("kill").contains { $0.string("id") == sessionID } })
}

// MARK: - Background Sessions per device

/// A look that starts nothing, answered by the test.
@MainActor
private final class FakePeeks {
    var answer: HostSessionPeek = .notRunning
    private(set) var looks: [String] = []
    var now = Date()

    lazy var peeks = RemoteDevicePeeks(
        peek: { [unowned self] control in
            looks.append(control.host.id)
            return answer
        },
        now: { [unowned self] in now },
        startMonitoring: {}
    )
}

@Test @MainActor func RemoteDeviceBackgroundSessionsListOnlyConnectedDevicesAndNeverConnectByThemselves() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    harness.fake.sessions = [
        harness.ownSession("d-agent", command: "server"),
        harness.ownSession("d-ended", running: false),
        // Another owner's (the device's own Cherry): never listed.
        HostedSessionInfo(id: "d-theirs", name: "Theirs", cwd: "/", pid: 1, owner: "Cherry",
                          tags: [PersistentSessionTag.project: "/Users/me/work/app"]),
    ]
    let local = try PersistentHarness()
    defer { local.cleanUp() }
    let fakePeeks = FakePeeks()
    var posted: [BackgroundSessionNotificationContent] = []
    let model = BackgroundSessionsModel(
        localSessions: local.hosting,
        registry: ProjectWindowRegistry(),
        prefersPersistentLocalSessions: { false },
        presentAlert: { _, _, answer in answer(.alertFirstButtonReturn) },
        postNotification: { posted.append($0) },
        isAppActive: { true },
        deviceHostings: { [BackgroundDeviceHosting(id: harness.deviceID, name: "Studio", hosting: harness.hosting)] },
        peeks: fakePeeks.peeks
    )
    model.start()
    defer { model.stop() }
    // Not connected: nothing listed, and nothing connected to find out.
    #expect(model.devices.count == 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.devices[0].sessions.isEmpty)
    #expect(harness.fake.launches.isEmpty)
    #expect(local.fake.launches.isEmpty)
    #expect(fakePeeks.looks.isEmpty)

    // Its control connects (a window of it, the picker): its own sessions
    // are listed, under its name.
    _ = try await harness.control.list()
    #expect(await eventually { model.devices[0].sessions.count == 2 })
    #expect(Set(model.devices[0].sessions.map(\.id)) == ["d-agent", "d-ended"])
    #expect(model.devices[0].sessions.allSatisfy { $0.machine == "Studio" })
    #expect(model.allSessions.count == 2 && model.sessions.isEmpty)
    #expect(model.summary.count == 2 && model.summary.runningCount == 1)
    // The device's list holds no lease on its connection.
    #expect(harness.control.activeLeaseCount == 0)
    #expect(local.control.activeLeaseCount == 0)

    // A bell of a background session there: marked unread, posted naming
    // the Mac, and a click opens it on that host.
    let info = try #require(harness.fake.sessions.first { $0.id == "d-agent" })
    #expect(model.devices[0].backgroundSessionDidSignal(info, .bell))
    #expect(model.devices[0].unreadSessionIDs == ["d-agent"])
    #expect(posted.first?.subtitle == "app on Studio · in the background")
    #expect(posted.first?.userInfo[BackgroundSessionNotificationContent.hostIDKey] == "host-studio")

    // Disconnected: the list empties rather than showing stale sessions,
    // and its unread mark is kept for when it is listed again.
    harness.control.disconnect()
    #expect(await eventually { model.devices[0].sessions.isEmpty })
    #expect(model.devices[0].unreadSessionIDs == ["d-agent"])
    _ = try await harness.control.list()
    #expect(await eventually { model.devices[0].sessions.count == 2 })
    #expect(model.devices[0].unreadSessionIDs == ["d-agent"])

    harness.control.disconnect()
    #expect(await eventually { model.devices[0].sessions.isEmpty })

    // The panel opens: the device is looked at without its control (which
    // would start its daemon through the gateway): nothing launches, and a
    // daemon that is not running shows nothing.
    let launchesBefore = harness.fake.launches.count
    fakePeeks.answer = .notRunning
    model.panelDidAppear()
    #expect(await eventually { fakePeeks.looks.count == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.devices[0].sessions.isEmpty)
    #expect(harness.fake.launches.count == launchesBefore)
    #expect(harness.control.state != .connected)
    // Running there: what it listed shows while the panel is open.
    model.panelDidDisappear()
    fakePeeks.now += 10
    fakePeeks.answer = .listed(HostedSessionList(hostID: "host-studio", sessions: [harness.ownSession("d-peeked")], pendingHolders: 0))
    model.panelDidAppear()
    #expect(await eventually { model.devices[0].sessions.map(\.id) == ["d-peeked"] })
    #expect(harness.fake.launches.count == launchesBefore)
    model.panelDidDisappear()
    #expect(model.devices[0].sessions.isEmpty)
    // Offline: looked at again at most once a minute; a refused login not
    // until a wake, a network change or Retry.
    fakePeeks.now += 10
    fakePeeks.answer = .failed(.unavailable("ssh: connect to host studio port 22: Connection timed out"))
    model.panelDidAppear()
    #expect(await eventually { fakePeeks.looks.count == 3 })
    model.panelDidDisappear()
    fakePeeks.now += 30
    model.panelDidAppear()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fakePeeks.looks.count == 3)
    model.panelDidDisappear()
    fakePeeks.now += 31
    fakePeeks.answer = .failed(.unavailable("studio: Permission denied (publickey)."))
    model.panelDidAppear()
    #expect(await eventually { fakePeeks.looks.count == 4 })
    model.panelDidDisappear()
    fakePeeks.now += 3_600
    model.panelDidAppear()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fakePeeks.looks.count == 4)
    fakePeeks.peeks.systemChanged()
    model.panelDidDisappear()
    model.panelDidAppear()
    #expect(await eventually { fakePeeks.looks.count == 5 })
    #expect(harness.fake.launches.count == launchesBefore)
    model.panelDidDisappear()

    // Connected again: Clear Ended and End work there as here.
    _ = try await harness.control.list()
    #expect(await eventually { model.devices[0].sessions.count == 2 })
    model.clearEnded()
    #expect(await eventually { harness.fake.requests("remove").contains { $0.string("id") == "d-ended" } })
    model.confirmEndAll()
    #expect(await eventually { harness.fake.requests("kill").contains { $0.string("id") == "d-agent" } })
}

@Test @MainActor func RemoteDevicePeeksAreThrottledAndARefusedLoginWaitsForRetry() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    let fake = FakePeeks()
    let peeks = fake.peeks
    let host = harness.host
    fake.answer = .failed(.unavailable("Connection timed out"))
    #expect(await peeks.refresh(harness.control) == fake.answer)
    #expect(!peeks.mayPeek(host))
    fake.now += 59
    #expect(!peeks.mayPeek(host))
    fake.now += 2
    #expect(peeks.mayPeek(host))
    fake.answer = .listed(HostedSessionList(hostID: "h", sessions: []))
    await peeks.refresh(harness.control)
    #expect(peeks.list(for: host)?.hostID == "h")
    // An answer is looked at again only after a few seconds.
    #expect(!peeks.mayPeek(host))
    fake.now += 6
    #expect(peeks.mayPeek(host))
    // A refused login, another identity or protocol: until Retry.
    for failure in [HostedSessionError.unavailable("Permission denied (publickey)."), .identityMismatch("x"), .unavailable("(version_mismatch)")] {
        fake.answer = .failed(failure)
        fake.now += 3_600
        await peeks.refresh(harness.control)
        fake.now += 3_600
        #expect(!peeks.mayPeek(host))
        peeks.retry(host)
        #expect(peeks.mayPeek(host))
    }
    #expect(fake.looks.count == 5)
    // What the picker shows of a device looked at.
    #expect(RemoteDeviceConnectionState(control: .idle, sessionCount: 0, lastSeen: nil, peek: .notRunning).subtitle() == "Its session host is not running")
    let list = HostedSessionList(hostID: "h", sessions: [harness.ownSession("a")])
    #expect(RemoteDeviceConnectionState(control: .idle, sessionCount: 0, lastSeen: nil, peek: .listed(list)) == .reachable(sessionCount: 1))
    // The helper's answers.
    #expect(HostControl.peek(status: 1, standardOutput: "", standardError: "cherry: cherry-host on studio: no cherry-host is running at /tmp/x (this command never starts one)\n", trusted: nil) == .notRunning)
    #expect(HostControl.peek(status: 0, standardOutput: #"{"host_id":"h","pending_holders":0,"sessions":[]}"#, standardError: "", trusted: nil) == .listed(HostedSessionList(hostID: "h", sessions: [], pendingHolders: 0)))
    let trusted = UUID().uuidString
    guard case .failed(let error) = HostControl.peek(status: 0, standardOutput: #"{"host_id":"other","pending_holders":0,"sessions":[]}"#, standardError: "", trusted: trusted) else {
        Issue.record("another identity was accepted")
        return
    }
    #expect(error.isIdentityMismatch)
}

@Test @MainActor func RemoteDevicePickerLooksAtDevicesWithoutConnectingThem() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    let fake = FakePeeks()
    fake.answer = .notRunning
    let controller = TitlebarProjectMenuController(
        makeModel: { TitlebarProjectMenuModel(worktrees: nil, projects: [], devices: [], currentProjectKey: nil) },
        controls: { [harness.control] },
        peeks: fake.peeks,
        perform: { _ in }
    )
    controller.startRefreshing()
    #expect(await eventually { fake.looks.count == 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.fake.launches.isEmpty)
    #expect(harness.control.state == .idle)
    // Opened again within the minute after a failure: not looked at again.
    fake.answer = .failed(.unavailable("Connection timed out"))
    fake.now += 10
    controller.startRefreshing()
    #expect(await eventually { fake.looks.count == 2 })
    controller.startRefreshing()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fake.looks.count == 2)
    // A connected device refreshes over its connection instead.
    _ = try await harness.control.list()
    fake.now += 120
    controller.startRefreshing()
    try await Task.sleep(for: .milliseconds(200))
    #expect(fake.looks.count == 2)
    #expect(harness.fake.launches.count == 1)
}

@Test @MainActor func RemoteDeviceLaunchNoticeNamesTheBackgroundSessionsOfDevicesThatAnswer() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    harness.fake.sessions = [harness.ownSession("d-server", command: "server")]
    let local = try PersistentHarness()
    defer { local.cleanUp() }
    let model = BackgroundSessionsModel(
        localSessions: local.hosting,
        registry: ProjectWindowRegistry(),
        prefersPersistentLocalSessions: { false },
        isAppActive: { true },
        deviceHostings: { [BackgroundDeviceHosting(id: harness.deviceID, name: "Studio", hosting: harness.hosting)] },
        peeks: FakePeeks().peeks
    )
    let suite = "CherryTests.RemoteNotice.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let registry = ProjectWindowRegistry()
    let notice = BackgroundSessionsNotice(
        model: model, registry: registry, isEnabled: { true }, defaults: defaults,
        canPresent: { _ in false }, settleDelay: .zero, restoreWait: .milliseconds(10), retries: 0
    )
    // This run reached the device (a window of it restored).
    _ = try await harness.control.list()
    model.start()
    defer { model.stop() }
    notice.launchWindowsOpened()
    #expect(await eventually {
        if case .waitingForWindow = notice.phase { return true }
        return false
    })
    guard case .waitingForWindow(let content) = notice.phase else { return }
    #expect(content.sessionIDs == ["d-server"])
    #expect(content.title == "1 session is still running in the background")
    #expect(content.message.contains("(app on Studio)"))
}

// MARK: - Dropped and pasted files

@Test @MainActor func RemoteDeviceDroppedFilesAreOfferedForCopyingNotInsertedAsThisMacsPaths() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cherry-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let files = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/notes.txt")]
    pasteboard.clearContents()
    pasteboard.writeObjects(files as [NSURL])
    #expect(RemoteFileDrop.localFiles(from: pasteboard, preferringText: true) == files)
    // Text is pasted as usual.
    pasteboard.clearContents()
    pasteboard.setString("echo hi", forType: .string)
    #expect(RemoteFileDrop.localFiles(from: pasteboard, preferringText: true) == nil)
    #expect(RemoteFileDrop.localFiles(from: pasteboard, preferringText: false) == nil)

    #expect(RemoteFileDrop.insertionText(remotePaths: ["/var/t/cherry-drop.1/a b.png", "/var/t/cherry-drop.1/notes.txt"])
        == "'/var/t/cherry-drop.1/a b.png' /var/t/cherry-drop.1/notes.txt ")
    let question = RemoteFileDrop.Question(files: files, machine: "Studio")
    #expect(question.title == "Copy 2 files to Studio?")
    #expect(question.confirmTitle == "Copy to Studio")
    #expect(RemoteFileDrop.Question(files: [files[1]], machine: "Studio").title == "Copy “notes.txt” to Studio?")
    #expect(RemoteFileCopier.scpArguments(
        files: files, folder: "/var/t/cherry-drop.1", destination: "studio", ssh: "/usr/bin/ssh", controlPath: "/t/s"
    ) == [
        "-O", "-r", "-q", "-B", "-S", "/usr/bin/ssh", "-o", "ControlMaster=no", "-o", "ControlPath=/t/s",
        "-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", "/tmp/a b.png", "/tmp/notes.txt",
        "studio:'/var/t/cherry-drop.1/'",
    ])
    // The same options as the device's shell, without a master.
    let direct = RemoteFileCopier.scpArguments(files: [files[1]], folder: "/f", destination: "studio", ssh: "/usr/bin/ssh", controlPath: nil)
    #expect(!direct.contains { $0.hasPrefix("ControlPath=") })
    for option in ["ControlMaster=no", "RemoteCommand=none", "ClearAllForwardings=yes", "PermitLocalCommand=no", "BatchMode=yes"] {
        #expect(direct.contains(option) && RemoteDeviceShell(sshExecutable: "/usr/bin/ssh", environment: [:]).arguments(destination: "studio").contains(option), "\(option)")
    }
}

@Test @MainActor func RemoteDeviceTabAsksBeforeCopyingDroppedFilesAndThisMacsTabsDoNot() async throws {
    let harness = try DeviceHarness()
    defer { harness.cleanUp() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("cherry-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/x.txt")] as [NSURL])
    let savedAsk = RemoteFileDropCoordinator.ask
    defer { RemoteFileDropCoordinator.ask = savedAsk }
    var asked: [RemoteFileDrop.Question] = []
    RemoteFileDropCoordinator.ask = { question, _, answer in
        asked.append(question)
        answer(false)
    }
    var inserted: [String] = []
    let tab = harness.workspace().addSession(title: "Remote")
    #expect(RemoteFileDropCoordinator.handle(pasteboard, for: tab, isPaste: false, window: nil) { inserted.append($0) })
    #expect(asked.map(\.title) == ["Copy “x.txt” to Studio?"])
    #expect(inserted.isEmpty)
    // A tab of This Mac inserts its paths as before.
    let local = TerminalWorkspace(projectRoot: NSTemporaryDirectory(), createInitialSession: false)
    let localTab = local.addSession(title: "Local")
    #expect(!RemoteFileDropCoordinator.handle(pasteboard, for: localTab, isPaste: false, window: nil) { inserted.append($0) })
    local.closeAllSessions(intent: .windowClosed)
}
