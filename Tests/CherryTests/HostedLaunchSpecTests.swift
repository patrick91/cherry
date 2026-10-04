import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// MARK: - Helpers

private let bundleTerminfo = "/Applications/Cherry.app/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/terminfo"
private let bundlePrefix = "/Applications/Cherry.app/Contents/Resources"
private let stableRoot = "/Users/tester/Library/Application Support/Cherry/GhosttyResources/0123456789abcdef0123456789abcdef"
private let bootstrapDirectory = "/Users/tester/Library/Application Support/Cherry/ShellIntegration/zsh"
private let binDirectory = "/Applications/Cherry.app/Contents/MacOS"
private let tabID = "6F1C1F7E-5B7A-4C1B-9A55-3D2F8E0C4A11"
/// The embedded Ghostty whose launch code HostedLaunchSpec reproduces.
private let auditedGhosttyVersion = "1.3.2-HEAD-+3c47ca159"

/// Cherry's environment as launchd gives it to a Dock launch, after
/// libghostty's init set LANG, LANGUAGE and GHOSTTY_RESOURCES_DIR, plus
/// leftovers of a terminal or tab Cherry could have been started from.
private let processEnvironment: [String: String] = [
    "HOME": "/Users/tester",
    "USER": "tester",
    "LOGNAME": "tester",
    "SHELL": "/bin/zsh",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR": "/var/folders/xy/T/",
    "LANG": "en_GB.UTF-8",
    "LANGUAGE": "it_IT.UTF-8:en_GB.UTF-8",
    "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.abc/Listeners",
    "XDG_DATA_DIRS": "/nix/share",
    "TERMINFO_DIRS": "/usr/share/terminfo",
    "__CFBundleIdentifier": "dev.patrick.cherry",
    "__CF_USER_TEXT_ENCODING": "0x1F5:0:2",
    "GHOSTTY_RESOURCES_DIR": "\(bundlePrefix)/GhosttyKit_GhosttyTerminal.bundle/Contents/Resources/Ghostty",
    "CHERRY_CONTROL_SOCKET": "/tmp/cherry-dev/control.sock",
    "XPC_SERVICE_NAME": "application.dev.patrick.cherry",
    "XPC_FLAGS": "0x0",
    "GHOSTTY_SURFACE_ID": "0x0000000000000001",
    "NO_COLOR": "1",
    "OLDPWD": "/somewhere",
    "SHLVL": "3",
    "TERM_SESSION_ID": "w0t0p0:ABC",
    "TMUX": "/tmp/tmux-501/default,1,0",
    "CHERRY_AGENT_ID": "11111111-2222-3333-4444-555555555555",
    "CHERRY_STARTUP_COMMAND": "should-never-run"
]

private let loginEnvironment: [String: String] = [
    "SSH_AUTH_SOCK": "/Users/tester/.1password/agent.sock",
    "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    "LANG": "it_IT.UTF-8"
]

private let account = HostedLaunchAccount(
    userName: "tester",
    homeDirectory: "/Users/tester",
    shell: "/bin/zsh",
    hushLogin: false
)

private func context(
    processEnvironment: [String: String] = processEnvironment,
    loginEnvironment: [String: String]? = loginEnvironment,
    account: HostedLaunchAccount? = account,
    launchedFromDesktop: Bool = true,
    resources: GhosttyStagedResources? = GhosttyStagedResources(rootDirectory: stableRoot),
    bootstrap: ShellIntegrationBootstrap? = ShellIntegrationBootstrap(zdotdir: bootstrapDirectory)
) -> HostedLaunchContext {
    HostedLaunchContext(
        processEnvironment: processEnvironment,
        loginEnvironment: loginEnvironment,
        account: account,
        launchedFromDesktop: launchedFromDesktop,
        ghosttyResources: resources,
        zshBootstrap: bootstrap,
        executableDirectory: binDirectory,
        terminalProgramVersion: auditedGhosttyVersion,
        shellFeatures: HostedLaunchContext.ghosttyShellFeatures(cursorBlink: true)
    )
}

private enum TabKind: String, CaseIterable {
    case terminal
    case agent
    case command
}

private func configuration(
    _ kind: TabKind,
    shell: String,
    workingDirectory: String = "/Users/tester/code/app",
    startupCommand: String? = nil
) -> ShellProcessController.Configuration {
    ShellProcessController.Configuration(
        shellPath: shell,
        workingDirectory: workingDirectory,
        projectRoot: "/Users/tester/code/app",
        processID: tabID,
        agentID: kind == .agent ? tabID : nil,
        environment: kind == .command ? ["PORT": "8000", "NODE_ENV": "development", "TERM": "dumb"] : [:],
        term: "xterm-ghostty",
        initialSize: TerminalViewportSize(columns: 120, rows: 32),
        startupCommand: startupCommand ?? {
            switch kind {
            case .terminal: nil
            case .agent: "claude --dangerously-skip-permissions --model 'opus[1m]'"
            case .command: "npm run dev -- --port \"$PORT\""
            }
        }()
    )
}

private func nativeLaunch(
    for configuration: ShellProcessController.Configuration,
    bootstrap: ShellIntegrationBootstrap? = ShellIntegrationBootstrap(zdotdir: bootstrapDirectory)
) -> (command: String, environment: [String: String]) {
    let isZsh = URL(fileURLWithPath: configuration.shellPath).lastPathComponent == "zsh"
    return ShellProcessController.nativeExecLaunch(
        for: configuration,
        shellIntegration: isZsh ? bootstrap : nil,
        inheritedEnvironment: processEnvironment,
        terminfoDirectories: bundleTerminfo
    )
}

private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
        throw CocoaError(.fileNoSuchFile)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

/// Runs a program to completion, reading its output until EOF before
/// waiting, and kills it after a generous deadline so a hung shell fails the
/// test instead of the suite.
private func run(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    workingDirectory: URL? = nil,
    timeout: TimeInterval = 60
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let watchdog = DispatchWorkItem { [process] in
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private func writeFile(_ contents: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func makeResourceSource(in directory: URL) throws -> GhosttyResourceStaging.Source {
    let resources = directory.appendingPathComponent("Ghostty", isDirectory: true)
    let terminfo = directory.appendingPathComponent("terminfo", isDirectory: true)
    try writeFile("# bash integration\n", to: resources.appendingPathComponent("shell-integration/bash/ghostty.bash"))
    try writeFile("# zsh\n", to: resources.appendingPathComponent("shell-integration/zsh/.zshenv"))
    try writeFile("#!/bin/sh\n", to: resources.appendingPathComponent("shell-integration/helper"), executable: true)
    try writeFile("# fish\n", to: resources.appendingPathComponent("shell-integration/fish/vendor_conf.d/ghostty.fish"))
    try FileManager.default.createSymbolicLink(
        atPath: resources.appendingPathComponent("shell-integration/latest").path,
        withDestinationPath: "bash"
    )
    try writeFile("compiled xterm-ghostty", to: terminfo.appendingPathComponent("78/xterm-ghostty"))
    try writeFile("compiled ghostty", to: terminfo.appendingPathComponent("67/ghostty"))
    return GhosttyResourceStaging.Source(resourcesDirectory: resources, terminfoDirectory: terminfo)
}

private func inode(_ path: String) -> ino_t? {
    var status = stat()
    return lstat(path, &status) == 0 ? status.st_ino : nil
}

private func entries(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Parity with the native launch

@Test(arguments: ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/fish"])
func hostedLaunchMatchesNativeLaunchForEveryTabKind(shell: String) throws {
    let context = context()
    let staged = try #require(context.ghosttyResources)
    for kind in TabKind.allCases {
        let configuration = configuration(kind, shell: shell)
        let native = nativeLaunch(for: configuration)
        let hosted = HostedLaunchSpec.make(for: configuration, context: context)
        let label = Comment(rawValue: "\(shell) \(kind.rawValue)")

        // Same effective command, in the shell layer Ghostty runs inside
        // login(1) on macOS (hosted sessions leave login out: it hides the
        // exit status).
        let ghosttyRewritesCommand = shell == "/opt/homebrew/bin/bash" && kind == .terminal
        let expectedCommand = ghosttyRewritesCommand ? "\(shell) --posix -l" : native.command
        #expect(hosted.argv == [
            "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(expectedCommand)"
        ], label)
        #expect(hosted.shellCommand == expectedCommand, label)
        #expect(hosted.workingDirectory == configuration.workingDirectory, label)

        // Every variable Cherry sets natively, with the same value, except
        // that terminfo comes from the stable copy.
        for (key, value) in native.environment {
            if key == "TERMINFO_DIRS" {
                #expect(value == "\(bundleTerminfo):/usr/share/terminfo", label)
                #expect(hosted.environment[key] == "\(staged.terminfoDirectory):/usr/share/terminfo", label)
            } else {
                #expect(hosted.environment[key] == value, Comment(rawValue: "\(shell) \(kind.rawValue) \(key)"))
            }
        }
        #expect(hosted.environment["TERMINFO"] == staged.terminfoDirectory, label)
        #expect(hosted.environment["GHOSTTY_RESOURCES_DIR"] == staged.resourcesDirectory, label)
        #expect(!hosted.environment.values.contains { $0.contains(bundlePrefix) }, label)
    }
}

@Test func hostedZshTerminalEnvironmentMatchesANativeCherryTab() {
    let hosted = HostedLaunchSpec.make(for: configuration(.terminal, shell: "/bin/zsh"), context: context())
    let resources = "\(stableRoot)/Ghostty"
    let expected: [String: String] = [
        // Cherry's environment, as Ghostty passes it on.
        "HOME": "/Users/tester",
        "USER": "tester",
        "LOGNAME": "tester",
        "SHELL": "/bin/zsh",
        "TMPDIR": "/var/folders/xy/T/",
        "LANG": "en_GB.UTF-8",
        "__CFBundleIdentifier": "dev.patrick.cherry",
        "__CF_USER_TEXT_ENCODING": "0x1F5:0:2",
        "CHERRY_CONTROL_SOCKET": "/tmp/cherry-dev/control.sock",
        // The login shell's agent, not launchd's.
        "SSH_AUTH_SOCK": "/Users/tester/.1password/agent.sock",
        // Ghostty's additions.
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(binDirectory)",
        "GHOSTTY_BIN_DIR": binDirectory,
        "GHOSTTY_RESOURCES_DIR": resources,
        "GHOSTTY_SHELL_FEATURES": "cursor:blink,path,title",
        "TERMINFO": "\(stableRoot)/terminfo",
        "XDG_DATA_DIRS": "/nix/share:\(resources)/..",
        "MANPATH": ":\(resources)/../man",
        "TERM_PROGRAM_VERSION": auditedGhosttyVersion,
        // Cherry's launch environment.
        "TERM": "xterm-ghostty",
        "TERM_PROGRAM": "Ghostty",
        "COLORTERM": "truecolor",
        "TERMINFO_DIRS": "\(stableRoot)/terminfo:/usr/share/terminfo",
        "PWD": "/Users/tester/code/app",
        "CHERRY_TERM_PROGRAM": "Cherry",
        "INSIDE_CHERRY": "1",
        "CHERRY_EMIT_OSC133": "1",
        "CHERRY_PROJECT_ROOT": "/Users/tester/code/app",
        "CHERRY_PROCESS_ID": tabID,
        "CHERRY_BOOTSTRAP_ZDOTDIR": bootstrapDirectory,
        "ZDOTDIR": bootstrapDirectory
    ]
    #expect(hosted.environment == expected)
    #expect(hosted.argv == ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l /bin/zsh -l"])
}

@Test func hostedAgentAndCommandCarryIdentityStartupCommandAndCommandEnvironment() {
    let agent = HostedLaunchSpec.make(for: configuration(.agent, shell: "/bin/zsh"), context: context())
    #expect(agent.environment["CHERRY_PROCESS_ID"] == tabID)
    #expect(agent.environment["CHERRY_AGENT_ID"] == tabID)
    #expect(agent.environment["CHERRY_STARTUP_COMMAND"] == "claude --dangerously-skip-permissions --model 'opus[1m]'")
    #expect(agent.shellCommand == "/bin/zsh -l")

    let command = HostedLaunchSpec.make(for: configuration(.command, shell: "/bin/zsh"), context: context())
    #expect(command.environment["CHERRY_AGENT_ID"] == nil)
    #expect(command.environment["PORT"] == "8000")
    #expect(command.environment["NODE_ENV"] == "development")
    // Cherry's own TERM wins over a cherry.toml TERM, as natively.
    #expect(command.environment["TERM"] == "xterm-ghostty")
    #expect(command.environment["CHERRY_STARTUP_COMMAND"] == "npm run dev -- --port \"$PORT\"")

    // A cherry.toml PATH overrides Ghostty's, as Cherry's env_override does.
    let base = configuration(.command, shell: "/bin/zsh")
    let withPath = ShellProcessController.Configuration(
        shellPath: base.shellPath,
        workingDirectory: base.workingDirectory,
        projectRoot: base.projectRoot,
        processID: base.processID,
        environment: ["PATH": "/project/bin:/usr/bin"],
        term: base.term,
        initialSize: base.initialSize,
        startupCommand: base.startupCommand
    )
    #expect(HostedLaunchSpec.make(for: withPath, context: context()).environment["PATH"] == "/project/bin:/usr/bin")
}

@Test func hostedLaunchDropsStateOfTheTerminalCherryWasStartedFrom() {
    var environment = processEnvironment
    environment["CHERRY_BOOTSTRAP_ZDOTDIR"] = bootstrapDirectory
    environment["ZDOTDIR"] = bootstrapDirectory
    environment["CHERRY_PROJECT_ROOT"] = "/other/project"
    environment["TERM_PROGRAM"] = "iTerm.app"
    environment["VTE_VERSION"] = "7000"
    environment["GHOSTTY_ZSH_ZDOTDIR"] = "/elsewhere"
    // Cherry started from an SSH login: This Mac's tabs are still local.
    environment["SSH_CONNECTION"] = "10.0.0.2 50000 10.0.0.1 22"
    environment["SSH_CLIENT"] = "10.0.0.2 50000 22"
    environment["SSH_TTY"] = "/dev/ttys003"
    let configuration = ShellProcessController.Configuration(
        shellPath: "/bin/bash",
        workingDirectory: "/tmp",
        processID: tabID,
        term: "xterm-ghostty",
        initialSize: TerminalViewportSize(columns: 80, rows: 24)
    )
    let hosted = HostedLaunchSpec.make(for: configuration, context: context(processEnvironment: environment))

    for key in [
        "XPC_SERVICE_NAME", "XPC_FLAGS", "GHOSTTY_SURFACE_ID", "GHOSTTY_ZSH_ZDOTDIR", "NO_COLOR", "OLDPWD", "SHLVL",
        "TERM_SESSION_ID", "TMUX", "VTE_VERSION", "CHERRY_AGENT_ID", "CHERRY_PROJECT_ROOT", "CHERRY_STARTUP_COMMAND",
        "CHERRY_BOOTSTRAP_ZDOTDIR", "ZDOTDIR", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"
    ] {
        #expect(hosted.environment[key] == nil, Comment(rawValue: key))
    }
    #expect(hosted.environment["TERM_PROGRAM"] == "Ghostty")
    #expect(hosted.environment["CHERRY_PROCESS_ID"] == tabID)
    #expect(hosted.environment["CHERRY_CONTROL_SOCKET"] == "/tmp/cherry-dev/control.sock")
    #expect(hosted.environment["PWD"] == "/tmp")
}

/// Every tab of This Mac names the app's CherryMCP in CHERRY_MCP_HELPER,
/// native and hosted alike, so `"$CHERRY_MCP_HELPER" --call …` works
/// whatever the tab's PATH; one the app inherited is never passed on.
@Test func hostedAndNativeLaunchesNameTheAppsCherryMCP() {
    let helper = "\(binDirectory)/CherryMCP"
    var inherited = processEnvironment
    inherited[CherryControl.mcpHelperEnvironmentKey] = "/elsewhere/CherryMCP"
    var hostedContext = context(processEnvironment: inherited)
    hostedContext.mcpHelperPath = helper
    for kind in TabKind.allCases {
        let hosted = HostedLaunchSpec.make(for: configuration(kind, shell: "/bin/zsh"), context: hostedContext)
        #expect(hosted.environment[CherryControl.mcpHelperEnvironmentKey] == helper, Comment(rawValue: kind.rawValue))
        let native = ShellProcessController.nativeExecLaunch(
            for: configuration(kind, shell: "/bin/bash"),
            shellIntegration: nil,
            inheritedEnvironment: inherited,
            terminfoDirectories: nil,
            mcpHelperPath: helper
        )
        #expect(native.environment[CherryControl.mcpHelperEnvironmentKey] == helper, Comment(rawValue: kind.rawValue))
    }
    // Without a CherryMCP next to the app: none, not the inherited one.
    let without = HostedLaunchSpec.make(for: configuration(.agent, shell: "/bin/zsh"), context: context(processEnvironment: inherited))
    #expect(without.environment[CherryControl.mcpHelperEnvironmentKey] == nil)
    #expect(CherryTabEnvironment.keys.contains(CherryControl.mcpHelperEnvironmentKey))
}

@Test func hostedLaunchNeverPassesOnACherryTabsVariables() {
    var environment = processEnvironment
    for key in CherryTabEnvironment.keys { environment[key] = "leaked" }
    for shell in ["/bin/zsh", "/bin/bash"] {
        let hosted = HostedLaunchSpec.make(
            for: configuration(.terminal, shell: shell),
            context: context(processEnvironment: environment)
        )
        for key in CherryTabEnvironment.keys {
            #expect(hosted.environment[key] != "leaked", Comment(rawValue: "\(shell) \(key)"))
        }
    }
}

@Test func hostedLaunchLeavesOutWhatGhosttyKeepsFromItsChildren() {
    let terminal = configuration(.terminal, shell: "/bin/zsh")
    func launch(_ environment: [String: String], launchedFromDesktop: Bool = true) -> [String: String] {
        HostedLaunchSpec.make(
            for: terminal,
            context: context(processEnvironment: environment, launchedFromDesktop: launchedFromDesktop)
        ).environment
    }

    // From the desktop, LANGUAGE is the one libghostty set for Cherry's own
    // translations; started from a shell, it is the user's.
    #expect(launch(processEnvironment)["LANGUAGE"] == nil)
    #expect(launch(processEnvironment, launchedFromDesktop: false)["LANGUAGE"] == "it_IT.UTF-8:en_GB.UTF-8")

    // Loader variables go only when Xcode started Cherry.
    var loader = processEnvironment
    loader["DYLD_LIBRARY_PATH"] = "/opt/lib"
    loader["SECURITYSESSIONID"] = "186a5"
    #expect(launch(loader)["DYLD_LIBRARY_PATH"] == "/opt/lib")
    #expect(launch(loader)["SECURITYSESSIONID"] == "186a5")
    var xcode = loader
    let products = "/Users/tester/Library/Developer/Xcode/DerivedData/Cherry/Build/Products/Debug"
    xcode["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] = products
    xcode["__XPC_DYLD_LIBRARY_PATH"] = products
    xcode["DYLD_FRAMEWORK_PATH"] = products
    xcode["DYLD_INSERT_LIBRARIES"] = "/usr/lib/libMainThreadChecker.dylib"
    xcode["LD_LIBRARY_PATH"] = products
    let fromXcode = launch(xcode)
    for key in [
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS", "__XPC_DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SECURITYSESSIONID"
    ] {
        #expect(fromXcode[key] == nil, Comment(rawValue: key))
    }
    #expect(fromXcode["TMPDIR"] == "/var/folders/xy/T/")
}

@Test func desktopLaunchDetectionIsGhosttys() {
    #expect(HostedLaunchContext.isLaunchedFromDesktop(processEnvironment: [:], parentProcessID: 1))
    #expect(!HostedLaunchContext.isLaunchedFromDesktop(processEnvironment: [:], parentProcessID: 4242))
    #expect(HostedLaunchContext.isLaunchedFromDesktop(
        processEnvironment: ["GHOSTTY_MAC_LAUNCH_SOURCE": "app"],
        parentProcessID: 4242
    ))
    #expect(!HostedLaunchContext.isLaunchedFromDesktop(
        processEnvironment: ["GHOSTTY_MAC_LAUNCH_SOURCE": "cli"],
        parentProcessID: 4242
    ))
}

@Test func hostedLaunchDropsVariablesTheHostCannotCarry() {
    let base = configuration(.command, shell: "/bin/zsh")
    let odd = ShellProcessController.Configuration(
        shellPath: base.shellPath,
        workingDirectory: base.workingDirectory,
        projectRoot: base.projectRoot,
        processID: base.processID,
        environment: [
            "PORT": "8000",
            "BAD=KEY": "x",
            "": "nameless",
            "NUL\0KEY": "x",
            "VALUE_NUL": "a\0b",
            "dotted.name-ok": "kept"
        ],
        term: base.term,
        initialSize: base.initialSize,
        startupCommand: base.startupCommand
    )
    var process = processEnvironment
    process["weird name"] = "kept too"
    let hosted = HostedLaunchSpec.make(for: odd, context: context(processEnvironment: process))

    for key in ["BAD=KEY", "", "NUL\0KEY", "VALUE_NUL"] {
        #expect(hosted.environment[key] == nil, Comment(rawValue: key))
    }
    #expect(hosted.environment["PORT"] == "8000")
    #expect(hosted.environment["dotted.name-ok"] == "kept")
    #expect(hosted.environment["weird name"] == "kept too")
    #expect(hosted.environment.allSatisfy { HostedLaunchSpec.isValidEnvironmentVariable(name: $0.key, value: $0.value) })
}

@Test func hostedLaunchTakesSSHAgentFromTheLoginEnvironmentThenLaunchd() {
    let terminal = configuration(.terminal, shell: "/bin/zsh")
    #expect(HostedLaunchSpec.make(for: terminal, context: context()).environment["SSH_AUTH_SOCK"]
        == "/Users/tester/.1password/agent.sock")
    #expect(HostedLaunchSpec.make(for: terminal, context: context(loginEnvironment: nil)).environment["SSH_AUTH_SOCK"]
        == "/private/tmp/com.apple.launchd.abc/Listeners")

    var noAgent = processEnvironment
    noAgent["SSH_AUTH_SOCK"] = nil
    noAgent["LANG"] = nil
    let hosted = HostedLaunchSpec.make(for: terminal, context: context(processEnvironment: noAgent, loginEnvironment: [:]))
    // Left to the host's agent link.
    #expect(hosted.environment["SSH_AUTH_SOCK"] == nil)
    #expect(hosted.environment["LANG"] == "en_US.UTF-8")
    #expect(HostedLaunchSpec.make(for: terminal, context: context(processEnvironment: noAgent)).environment["LANG"]
        == "it_IT.UTF-8")
}

@Test func hostedLaunchFillsAccountVariablesTheHostWouldOtherwiseChoose() {
    var sparse = processEnvironment
    for key in ["HOME", "USER", "LOGNAME", "SHELL", "PATH"] { sparse[key] = nil }
    let hosted = HostedLaunchSpec.make(
        for: configuration(.terminal, shell: "/bin/zsh"),
        context: context(processEnvironment: sparse)
    )
    #expect(hosted.environment["HOME"] == "/Users/tester")
    #expect(hosted.environment["USER"] == "tester")
    #expect(hosted.environment["LOGNAME"] == "tester")
    #expect(hosted.environment["SHELL"] == "/bin/zsh")
    #expect(hosted.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:\(binDirectory)")
}

// MARK: - Shell layer (no login wrapper)

@Test func hostedLaunchRunsNoLoginWrapperAndFallsBackWithoutAnAccount() {
    // login(1) exits 0 whatever the shell's status, so hosted sessions run
    // without it; there is no banner for ~/.hushlogin to silence.
    var quiet = account
    quiet.hushLogin = true
    let terminal = configuration(.terminal, shell: "/bin/zsh")
    for account in [account, quiet] {
        let argv = HostedLaunchSpec.make(for: terminal, context: context(account: account)).argv
        #expect(argv == ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l /bin/zsh -l"])
        #expect(!argv.contains(HostedLaunchSpec.loginProgram))
    }

    let unwrapped = HostedLaunchSpec.make(for: terminal, context: context(account: nil))
    #expect(unwrapped.argv == ["/bin/sh", "-c", "/bin/zsh -l"])
    #expect(unwrapped.shellCommand == "/bin/zsh -l")
}

@Test func currentAccountIsTheLoggedInUser() throws {
    let current = try #require(HostedLaunchAccount.current())
    let record = try #require(getpwuid(getuid()))
    #expect(current.userName == String(cString: record.pointee.pw_name))
    #expect(current.homeDirectory == String(cString: record.pointee.pw_dir))
    #expect(current.shell == String(cString: record.pointee.pw_shell))
    #expect(current.hushLogin == FileManager.default.fileExists(atPath: "\(current.homeDirectory)/.hushlogin"))
}

// MARK: - Ghostty shell integration

@Test func hostedLaunchInjectsGhosttyIntegrationForShellsWithoutCherrysBootstrap() throws {
    let resources = "\(stableRoot)/Ghostty"

    var withEnv = processEnvironment
    withEnv["ENV"] = "/Users/tester/.shrc"
    let bash = HostedLaunchSpec.make(
        for: configuration(.terminal, shell: "/opt/homebrew/bin/bash"),
        context: context(processEnvironment: withEnv)
    )
    #expect(bash.shellCommand == "/opt/homebrew/bin/bash --posix -l")
    #expect(bash.environment["ENV"] == "\(resources)/shell-integration/bash/ghostty.bash")
    #expect(bash.environment["GHOSTTY_BASH_ENV"] == "/Users/tester/.shrc")
    #expect(bash.environment["GHOSTTY_BASH_INJECT"] == "1")
    #expect(bash.environment["HISTFILE"] == "/Users/tester/.bash_history")
    #expect(bash.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")

    // `-c` is never interactive, and Apple's bash ignores ENV: no injection.
    for bashCase in [
        configuration(.agent, shell: "/opt/homebrew/bin/bash"),
        configuration(.terminal, shell: "/bin/bash")
    ] {
        let hosted = HostedLaunchSpec.make(for: bashCase, context: context())
        #expect(hosted.environment["ENV"] == nil)
        #expect(hosted.environment["GHOSTTY_BASH_INJECT"] == nil)
        #expect(hosted.shellCommand == nativeLaunch(for: bashCase).command)
    }

    let fish = HostedLaunchSpec.make(for: configuration(.terminal, shell: "/opt/homebrew/bin/fish"), context: context())
    #expect(fish.shellCommand == "/opt/homebrew/bin/fish -l")
    #expect(fish.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == "\(resources)/shell-integration")
    #expect(fish.environment["XDG_DATA_DIRS"] == "\(resources)/shell-integration:/nix/share:\(resources)/..")

    let nushell = HostedLaunchSpec.make(for: configuration(.terminal, shell: "/opt/homebrew/bin/nu"), context: context())
    #expect(nushell.shellCommand == "/opt/homebrew/bin/nu --execute 'use ghostty *' -l")
    #expect(nushell.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == "\(resources)/shell-integration")
    let nushellAgent = HostedLaunchSpec.make(for: configuration(.agent, shell: "/opt/homebrew/bin/nu"), context: context())
    #expect(nushellAgent.shellCommand == nativeLaunch(for: configuration(.agent, shell: "/opt/homebrew/bin/nu")).command)

    // Without Cherry's bootstrap (it could not be written) zsh gets Ghostty's.
    var customZdotdir = processEnvironment
    customZdotdir["ZDOTDIR"] = "/Users/tester/.config/zsh"
    let zsh = HostedLaunchSpec.make(
        for: configuration(.terminal, shell: "/bin/zsh"),
        context: context(processEnvironment: customZdotdir, bootstrap: nil)
    )
    #expect(zsh.environment["ZDOTDIR"] == "\(resources)/shell-integration/zsh")
    #expect(zsh.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/Users/tester/.config/zsh")
    #expect(zsh.environment["CHERRY_BOOTSTRAP_ZDOTDIR"] == nil)

    // With it, Cherry's bootstrap wins and keeps the user's ZDOTDIR.
    let bootstrapped = HostedLaunchSpec.make(
        for: configuration(.terminal, shell: "/bin/zsh"),
        context: context(processEnvironment: customZdotdir)
    )
    #expect(bootstrapped.environment["ZDOTDIR"] == bootstrapDirectory)
    #expect(bootstrapped.environment["CHERRY_ORIGINAL_ZDOTDIR"] == "/Users/tester/.config/zsh")
}

private struct Integration: Equatable {
    let command: String
    let environment: [String: String]
}

/// Ghostty's own cases for its automatic shell integration
/// (termio/shell_integration.zig tests); Ghostty's "no integration" is the
/// command and environment left as they were.
@Test func ghosttyShellIntegrationMatchesGhosttysOwnCases() {
    let resources = "/stage/Ghostty"
    let integration = "\(resources)/shell-integration"
    func apply(_ command: String, _ environment: [String: String] = [:]) -> Integration {
        var environment = environment
        let command = HostedLaunchSpec.ghosttyShellIntegration(
            command: command,
            resourcesDirectory: resources,
            homeDirectory: "/Users/tester",
            environment: &environment
        )
        return Integration(command: command, environment: environment)
    }
    func bash(_ command: String, inject: String = "1", _ extra: [String: String] = [:]) -> Integration {
        Integration(
            command: command,
            environment: [
                "ENV": "\(integration)/bash/ghostty.bash",
                "GHOSTTY_BASH_INJECT": inject,
                "HISTFILE": "/Users/tester/.bash_history",
                "GHOSTTY_BASH_UNEXPORT_HISTFILE": "1"
            ].merging(extra) { _, extra in extra }
        )
    }

    // bash, inject flags, rcfile and additional arguments.
    #expect(apply("bash") == bash("bash --posix"))
    #expect(apply("bash --norc") == bash("bash --posix", inject: "1 --norc"))
    #expect(apply("bash --noprofile") == bash("bash --posix", inject: "1 --noprofile"))
    #expect(apply("bash --rcfile profile.sh") == bash("bash --posix", ["GHOSTTY_BASH_RCFILE": "profile.sh"]))
    #expect(apply("bash --init-file profile.sh") == bash("bash --posix", ["GHOSTTY_BASH_RCFILE": "profile.sh"]))
    #expect(apply("bash - --arg file1 file2") == bash("bash --posix - --arg file1 file2"))
    #expect(apply("bash -- --arg file1 file2") == bash("bash --posix -- --arg file1 file2"))
    #expect(apply("/opt/homebrew/bin/bash -l") == bash("/opt/homebrew/bin/bash --posix -l"))
    // bash: ENV and HISTFILE are kept.
    #expect(apply("bash", ["ENV": "env.sh"]) == bash("bash --posix", ["GHOSTTY_BASH_ENV": "env.sh"]))
    #expect(apply("bash", ["HISTFILE": "my_history"]) == Integration(
        command: "bash --posix",
        environment: [
            "ENV": "\(integration)/bash/ghostty.bash",
            "GHOSTTY_BASH_INJECT": "1",
            "HISTFILE": "my_history"
        ]
    ))
    // bash: unsupported options, and Apple's bash 3.2.
    for command in [
        "bash --posix", "bash --rcfile script.sh --posix", "bash --init-file script.sh --posix",
        "bash -c script.sh", "bash -ic script.sh", "/bin/bash -l"
    ] {
        #expect(apply(command) == Integration(command: command, environment: [:]), Comment(rawValue: command))
    }

    // fish and elvish: XDG_DATA_DIRS, empty and existing.
    let xdg = ["GHOSTTY_SHELL_INTEGRATION_XDG_DIR": integration]
    for shell in ["fish", "elvish"] {
        #expect(apply("\(shell) -l") == Integration(
            command: "\(shell) -l",
            environment: xdg.merging(["XDG_DATA_DIRS": "\(integration):/usr/local/share:/usr/share"]) { $1 }
        ))
        #expect(apply(shell, ["XDG_DATA_DIRS": "/opt/share"]) == Integration(
            command: shell,
            environment: xdg.merging(["XDG_DATA_DIRS": "\(integration):/opt/share"]) { $1 }
        ))
    }

    // nushell: the module is used; unsupported options keep only XDG.
    let nuEnvironment = xdg.merging(["XDG_DATA_DIRS": "\(integration):/usr/local/share:/usr/share"]) { $1 }
    #expect(apply("nu") == Integration(command: "nu --execute 'use ghostty *'", environment: nuEnvironment))
    #expect(apply("nu -- script.nu") == Integration(
        command: "nu --execute 'use ghostty *' -- script.nu",
        environment: nuEnvironment
    ))
    for command in ["nu --command exit", "nu --lsp", "nu -c script.sh", "nu -ic script.sh"] {
        #expect(apply(command) == Integration(command: command, environment: nuEnvironment), Comment(rawValue: command))
    }

    // zsh: ZDOTDIR, kept for Ghostty's own .zshenv to restore.
    #expect(apply("zsh") == Integration(command: "zsh", environment: ["ZDOTDIR": "\(integration)/zsh"]))
    #expect(apply("zsh", ["ZDOTDIR": "$HOME/.config/zsh"]) == Integration(
        command: "zsh",
        environment: ["ZDOTDIR": "\(integration)/zsh", "GHOSTTY_ZSH_ZDOTDIR": "$HOME/.config/zsh"]
    ))

    // Anything else is left alone.
    #expect(apply("sh") == Integration(command: "sh", environment: [:]))
}

@Test func hostedLaunchWithoutStagedResourcesAvoidsAnUndescribedTerm() {
    let hosted = HostedLaunchSpec.make(
        for: configuration(.terminal, shell: "/opt/homebrew/bin/bash"),
        context: context(resources: nil)
    )
    #expect(hosted.environment["TERM"] == "xterm-256color")
    #expect(hosted.environment["TERMINFO"] == nil)
    #expect(hosted.environment["GHOSTTY_RESOURCES_DIR"] == nil)
    #expect(hosted.environment["TERMINFO_DIRS"] == "/usr/share/terminfo")
    #expect(hosted.environment["ENV"] == nil)
    #expect(hosted.environment["TERM_PROGRAM"] == "Ghostty")
    #expect(hosted.shellCommand == "/opt/homebrew/bin/bash -l")
}

// MARK: - Startup commands

@Test(arguments: [
    "printf '%s|' \"it's\" 'a\"b' \"$((2 + 3))\" '$HOME' 'x;y' 'p|q' > \"$CHERRY_TEST_OUTPUT\"",
    "  printf   '%s|' 'tab\there' '\\\\back' '*' \"`echo tick`\" > \"$CHERRY_TEST_OUTPUT\""
])
func hostedNonZshStartupCommandSurvivesTheLoginWrapperQuoting(startupCommand: String) throws {
    let directory = try makeTemporaryDirectory("cherry-hosted-quoting")
    defer { try? FileManager.default.removeItem(at: directory) }
    let argumentsFile = directory.appendingPathComponent("arguments")
    let outputFile = directory.appendingPathComponent("output")
    // A stand-in login shell that records its arguments, then runs `-c`.
    let shell = directory.appendingPathComponent("fake-shell")
    try writeFile(
        """
        #!/bin/sh
        printf '%s\\0' "$@" > '\(argumentsFile.path)'
        while [ "$#" -gt 1 ]; do shift; done
        exec /bin/sh -c "$1"
        """,
        to: shell,
        executable: true
    )
    let configuration = configuration(.command, shell: shell.path, startupCommand: startupCommand)
    let hosted = HostedLaunchSpec.make(for: configuration, context: context())
    #expect(hosted.environment["CHERRY_STARTUP_COMMAND"] == nil)

    // The whole launch: the bash that `exec -l`s the shell.
    let afterLogin = hosted.argv
    #expect(afterLogin.count == 5)
    #expect(afterLogin.first == "/bin/bash")
    var environment = hosted.environment
    environment["CHERRY_TEST_OUTPUT"] = outputFile.path
    let result = try run(
        afterLogin[0],
        Array(afterLogin.dropFirst()),
        environment: environment,
        workingDirectory: directory
    )
    #expect(result.status == 0, Comment(rawValue: result.output))

    let recorded = try Data(contentsOf: argumentsFile)
        .split(separator: 0, omittingEmptySubsequences: false)
        .dropLast()
        .map { String(decoding: $0, as: UTF8.self) }
    #expect(recorded == ["-l", "-i", "-c", "exec \(startupCommand)"])

    let output = try String(contentsOf: outputFile, encoding: .utf8)
    if startupCommand.hasPrefix("printf") {
        #expect(output == "it's|a\"b|5|$HOME|x;y|p|q|")
    } else {
        #expect(output == "tab\there|\\\\back|*|tick|")
    }
}

@Test func hostedZshLaunchRunsTheStartupCommandThroughCherrysBootstrap() throws {
    let home = try makeTemporaryDirectory("cherry-hosted-zsh")
    defer { try? FileManager.default.removeItem(at: home) }
    let bootstrap = try #require(try ShellIntegrationBootstrap.prepare(shellPath: "/bin/zsh", homeDirectory: home))
    let outputFile = home.appendingPathComponent("output")
    let startupCommand = "printf '%s|%s|%s' \"it's\" \"$CHERRY_PROCESS_ID\" \"$PWD\" > '\(outputFile.path)'; exit 7"
    var environment = processEnvironment
    environment["HOME"] = home.path
    let source = try #require(GhosttyResourceStaging.bundledSource())
    let resources = try GhosttyResourceStaging.stage(source, into: home.appendingPathComponent("GhosttyResources"))
    let configuration = configuration(.agent, shell: "/bin/zsh", workingDirectory: home.path, startupCommand: startupCommand)
    let hosted = HostedLaunchSpec.make(
        for: configuration,
        context: context(processEnvironment: environment, resources: resources, bootstrap: bootstrap)
    )
    #expect(hosted.environment["CHERRY_STARTUP_COMMAND"] == startupCommand)

    // The whole launch, on a terminal so zsh is interactive; its status
    // is the startup command's (no login(1) to swallow it).
    let afterLogin = hosted.argv
    #expect(afterLogin.first == "/bin/bash")
    let result = try run("/usr/bin/script", ["-q", "/dev/null"] + afterLogin, environment: hosted.environment, workingDirectory: home)
    #expect(result.status == 7, Comment(rawValue: result.output))
    let output = try String(contentsOf: outputFile, encoding: .utf8)
    #expect(output == "it's|\(tabID)|\(home.path)")
}

// MARK: - Ghostty version

/// HostedLaunchSpec reproduces what the embedded Ghostty does before it runs
/// a native tab's command: termio/Exec.zig (Subprocess.init, execCommand),
/// termio/shell_integration.zig, apprt/embedded.zig (defaultTermioEnv), the
/// environment block of Surface.zig and os/locale.zig. When libghostty is
/// updated, compare those with the audited version's, bring `make` and
/// `baseEnvironment` in line, then update `auditedGhosttyVersion`.
@Test func embeddedGhosttyIsTheVersionTheLaunchReproductionFollows() {
    #expect(HostedLaunchContext.embeddedGhosttyVersion == auditedGhosttyVersion)
}

// MARK: - Native launch refactor

@Test func nativeExecLaunchStillReadsCherrysOwnEnvironmentAndBundledTerminfo() {
    // bash: no zsh bootstrap is written anywhere.
    let configuration = configuration(.agent, shell: "/bin/bash")
    let wrapper = ShellProcessController.nativeExecLaunch(for: configuration)
    let explicit = ShellProcessController.nativeExecLaunch(
        for: configuration,
        shellIntegration: nil,
        inheritedEnvironment: ProcessInfo.processInfo.environment,
        terminfoDirectories: ShellProcessController.preferredTerminfo.additionalDirs
    )
    #expect(wrapper.command == explicit.command)
    #expect(wrapper.environment == explicit.environment)
}

// MARK: - Resource staging

@Test func stagingCopiesResourcesOnceIntoAContentAddressedDirectory() throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-stage")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let base = directory.appendingPathComponent("GhosttyResources", isDirectory: true)

    let staged = try GhosttyResourceStaging.stage(source, into: base)
    let hash = try GhosttyResourceStaging.contentHash(
        resourcesDirectory: source.resourcesDirectory,
        terminfoDirectory: source.terminfoDirectory
    )
    #expect(staged.rootDirectory == base.appendingPathComponent(hash).path)
    #expect(hash.count == 32)
    #expect(entries(base) == [hash])
    #expect(staged.resourcesDirectory == "\(staged.rootDirectory)/Ghostty")
    #expect(staged.terminfoDirectory == "\(staged.rootDirectory)/terminfo")
    #expect(staged.shellIntegrationDirectory == "\(staged.rootDirectory)/Ghostty/shell-integration")
    #expect(try String(contentsOfFile: "\(staged.shellIntegrationDirectory)/bash/ghostty.bash", encoding: .utf8)
        == "# bash integration\n")
    #expect(try String(contentsOfFile: "\(staged.terminfoDirectory)/78/xterm-ghostty", encoding: .utf8)
        == "compiled xterm-ghostty")
    #expect(FileManager.default.isExecutableFile(atPath: "\(staged.shellIntegrationDirectory)/helper"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(staged.shellIntegrationDirectory)/latest") == "bash")

    // Present and intact: nothing is copied again.
    let rootInode = inode(staged.rootDirectory)
    let fileInode = inode("\(staged.terminfoDirectory)/78/xterm-ghostty")
    #expect(try GhosttyResourceStaging.stage(source, into: base) == staged)
    #expect(inode(staged.rootDirectory) == rootInode)
    #expect(inode("\(staged.terminfoDirectory)/78/xterm-ghostty") == fileInode)
    #expect(entries(base) == [hash])

    // New contents stage beside the old copy, which running sessions use.
    try writeFile("# bash integration v2\n", to: source.resourcesDirectory.appendingPathComponent("shell-integration/bash/ghostty.bash"))
    let updated = try GhosttyResourceStaging.stage(source, into: base)
    #expect(updated != staged)
    #expect(entries(base).count == 2)
    #expect(FileManager.default.fileExists(atPath: "\(staged.shellIntegrationDirectory)/bash/ghostty.bash"))

    // The hash covers the executable bit and link targets too.
    let before = try GhosttyResourceStaging.contentHash(
        resourcesDirectory: source.resourcesDirectory,
        terminfoDirectory: source.terminfoDirectory
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: source.resourcesDirectory.appendingPathComponent("shell-integration/helper").path
    )
    let afterMode = try GhosttyResourceStaging.contentHash(
        resourcesDirectory: source.resourcesDirectory,
        terminfoDirectory: source.terminfoDirectory
    )
    #expect(afterMode != before)
}

@Test func stagingRepairsADamagedCopyInPlaceAndKeepsWhatItDoesNotOwn() throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-repair")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let base = directory.appendingPathComponent("GhosttyResources", isDirectory: true)
    let staged = try GhosttyResourceStaging.stage(source, into: base)
    let integration = staged.shellIntegrationDirectory
    let rootInode = inode(staged.rootDirectory)
    let intactInode = inode("\(staged.terminfoDirectory)/67/ghostty")

    // A missing file, changed contents, a lost executable bit, a moved link,
    // a file where a directory was and a directory where a file was.
    let fileManager = FileManager.default
    try fileManager.removeItem(atPath: "\(staged.terminfoDirectory)/78/xterm-ghostty")
    try "tampered".write(toFile: "\(integration)/zsh/.zshenv", atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(integration)/helper")
    try fileManager.removeItem(atPath: "\(integration)/latest")
    try fileManager.createSymbolicLink(atPath: "\(integration)/latest", withDestinationPath: "zsh")
    try fileManager.removeItem(atPath: "\(integration)/bash")
    try "not a directory".write(toFile: "\(integration)/bash", atomically: true, encoding: .utf8)
    try fileManager.removeItem(atPath: "\(integration)/fish/vendor_conf.d/ghostty.fish")
    try writeFile("stray", to: URL(fileURLWithPath: "\(integration)/fish/vendor_conf.d/ghostty.fish/inside"))
    // What `tic` compiles into TERMINFO belongs to the user, not to the copy.
    try writeFile("compiled by tic", to: URL(fileURLWithPath: "\(staged.terminfoDirectory)/61/alacritty"))

    #expect(try GhosttyResourceStaging.stage(source, into: base) == staged)
    // Repaired where it is: the directory sessions use is never replaced,
    // and entries that were fine are not rewritten.
    #expect(inode(staged.rootDirectory) == rootInode)
    #expect(inode("\(staged.terminfoDirectory)/67/ghostty") == intactInode)
    #expect(try String(contentsOfFile: "\(staged.terminfoDirectory)/78/xterm-ghostty", encoding: .utf8)
        == "compiled xterm-ghostty")
    #expect(try String(contentsOfFile: "\(integration)/zsh/.zshenv", encoding: .utf8) == "# zsh\n")
    #expect(fileManager.isExecutableFile(atPath: "\(integration)/helper"))
    #expect(try fileManager.destinationOfSymbolicLink(atPath: "\(integration)/latest") == "bash")
    #expect(try String(contentsOfFile: "\(integration)/bash/ghostty.bash", encoding: .utf8) == "# bash integration\n")
    #expect(try String(contentsOfFile: "\(integration)/fish/vendor_conf.d/ghostty.fish", encoding: .utf8) == "# fish\n")
    #expect(try String(contentsOfFile: "\(staged.terminfoDirectory)/61/alacritty", encoding: .utf8) == "compiled by tic")
    #expect(try GhosttyResourceStaging.contentHash(
        resourcesDirectory: source.resourcesDirectory,
        terminfoDirectory: source.terminfoDirectory
    ) == URL(fileURLWithPath: staged.rootDirectory).lastPathComponent)
    // Nothing is left beside the copy.
    #expect(entries(base) == [URL(fileURLWithPath: staged.rootDirectory).lastPathComponent])

    // A copy with extra entries only is intact: nothing is rewritten.
    let repairedInode = inode("\(staged.terminfoDirectory)/78/xterm-ghostty")
    #expect(try GhosttyResourceStaging.stage(source, into: base) == staged)
    #expect(inode("\(staged.terminfoDirectory)/78/xterm-ghostty") == repairedInode)
    #expect(fileManager.fileExists(atPath: "\(staged.terminfoDirectory)/61/alacritty"))
}

@Test func concurrentStagingConvergesOnOneCompleteCopy() throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-race")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let base = directory.appendingPathComponent("GhosttyResources", isDirectory: true)

    let results = Locked<[Result<GhosttyStagedResources, Error>]>([])
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        let result = Result { try GhosttyResourceStaging.stage(source, into: base) }
        results.withValue { $0.append(result) }
    }
    let staged = try results.withValue { $0 }.map { try $0.get() }
    #expect(Set(staged.map(\.rootDirectory)).count == 1)
    #expect(entries(base) == [URL(fileURLWithPath: staged[0].rootDirectory).lastPathComponent])
    #expect(try String(contentsOfFile: "\(staged[0].terminfoDirectory)/67/ghostty", encoding: .utf8) == "compiled ghostty")
}

@Test func stagingRemovesOldLeftoversOfInterruptedStages() throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-leftovers")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let base = directory.appendingPathComponent("GhosttyResources", isDirectory: true)
    let old = base.appendingPathComponent(".staging-old", isDirectory: true)
    let recent = base.appendingPathComponent(".staging-recent", isDirectory: true)
    let stale = base.appendingPathComponent(".stale-old", isDirectory: true)
    for leftover in [old, recent, stale] {
        try writeFile("partial", to: leftover.appendingPathComponent("Ghostty/file"))
    }
    let longAgo = Date().addingTimeInterval(-2 * GhosttyResourceStaging.leftoverAge)
    for leftover in [old, stale] {
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: leftover.path)
    }

    let staged = try GhosttyResourceStaging.stage(source, into: base)
    let hash = URL(fileURLWithPath: staged.rootDirectory).lastPathComponent
    #expect(entries(base) == [".staging-recent", hash].sorted())

    // Also when the copy is already there and intact.
    let replacement = base.appendingPathComponent(".staging-file", isDirectory: false)
    try writeFile("partial", to: replacement)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: replacement.path)
    try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: recent.path)
    #expect(try GhosttyResourceStaging.stage(source, into: base) == staged)
    #expect(entries(base) == [hash])
}

@Test func stagingFailsWhenTheBundleHasNoResources() throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-missing")
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = GhosttyResourceStaging.Source(
        resourcesDirectory: directory.appendingPathComponent("Ghostty"),
        terminfoDirectory: directory.appendingPathComponent("terminfo")
    )
    #expect(throws: GhosttyResourceStagingError.resourcesMissing) {
        try GhosttyResourceStaging.stage(missing, into: directory.appendingPathComponent("GhosttyResources"))
    }
}

@Test func stagerStagesOnceOffTheCallersThreadAndRetriesFailures() async throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-stager")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let base = directory.appendingPathComponent("GhosttyResources", isDirectory: true)

    let calls = Locked(0)
    let available = Locked(false)
    let stager = GhosttyResourceStager(
        source: {
            calls.withValue { $0 += 1 }
            return available.withValue { $0 } ? source : nil
        },
        baseDirectory: base
    )
    await #expect(throws: GhosttyResourceStagingError.resourcesMissing) { try await stager.resolve() }
    available.withValue { $0 = true }
    let first = try await stager.resolve()
    let second = try await stager.resolve()
    #expect(first == second)
    #expect(calls.withValue { $0 } == 2)

    // A copy deleted while the app runs is staged again at the same path.
    try FileManager.default.removeItem(atPath: first.rootDirectory)
    let restaged = try await stager.resolve()
    #expect(restaged == first)
    #expect(FileManager.default.fileExists(atPath: "\(restaged.terminfoDirectory)/78/xterm-ghostty"))
    #expect(calls.withValue { $0 } == 3)
    let label = await stager.perform { String(cString: __dispatch_queue_get_label(nil)) }
    #expect(label == "Cherry.GhosttyResourceStager")
}

@Test func bundledGhosttyResourcesStageWithAUsableTerminfo() async throws {
    let directory = try makeTemporaryDirectory("cherry-ghostty-bundled")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try #require(GhosttyResourceStaging.bundledSource())
    let staged = try GhosttyResourceStaging.stage(source, into: directory)

    for script in ["bash/ghostty.bash", "zsh/ghostty-integration", "fish/vendor_conf.d/ghostty-shell-integration.fish"] {
        #expect(FileManager.default.fileExists(atPath: "\(staged.shellIntegrationDirectory)/\(script)"), Comment(rawValue: script))
    }
    let infocmp = try run(
        "/usr/bin/infocmp",
        ["-x", "xterm-ghostty"],
        environment: ["TERMINFO": staged.terminfoDirectory, "PATH": "/usr/bin:/bin"]
    )
    #expect(infocmp.status == 0, Comment(rawValue: infocmp.output))
    #expect(infocmp.output.contains("xterm-ghostty"))

    // The prepared context stages into the stager's directory and reads the
    // account; a bash tab writes no zsh bootstrap.
    let home = directory.appendingPathComponent("home", isDirectory: true)
    let prepared = await HostedLaunchContext.prepare(
        for: configuration(.terminal, shell: "/bin/bash"),
        loginEnvironment: ["SSH_AUTH_SOCK": "/agent"],
        cursorBlink: false,
        processEnvironment: ["HOME": "/Users/tester"],
        executableDirectory: "/Applications/Cherry.app/Contents/MacOS",
        homeDirectory: home,
        parentProcessID: 4242,
        stager: GhosttyResourceStager(source: { source }, baseDirectory: directory)
    )
    #expect(prepared.ghosttyResources == staged)
    #expect(prepared.zshBootstrap == nil)
    #expect(!FileManager.default.fileExists(atPath: home.path))
    #expect(!prepared.launchedFromDesktop)
    #expect(prepared.account == HostedLaunchAccount.current())
    #expect(prepared.shellFeatures == "cursor:steady,path,title")
    #expect(prepared.loginEnvironment == ["SSH_AUTH_SOCK": "/agent"])
    let version = try #require(prepared.terminalProgramVersion)
    #expect(version.first?.isNumber == true)
}

@Test func preparingAZshTabWritesTheBootstrapItsLaunchUses() async throws {
    let directory = try makeTemporaryDirectory("cherry-hosted-prepare")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try makeResourceSource(in: directory.appendingPathComponent("bundle", isDirectory: true))
    let stager = GhosttyResourceStager(
        source: { source },
        baseDirectory: directory.appendingPathComponent("GhosttyResources", isDirectory: true)
    )
    let home = directory.appendingPathComponent("home", isDirectory: true)
    let agent = configuration(.agent, shell: "/bin/zsh")

    let spec = await HostedLaunchSpec.prepare(
        for: agent,
        loginEnvironment: loginEnvironment,
        cursorBlink: true,
        processEnvironment: processEnvironment,
        executableDirectory: binDirectory,
        homeDirectory: home,
        parentProcessID: 1,
        stager: stager
    )
    let bootstrap = home
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent(CherryAppIdentity.current.applicationSupportName, isDirectory: true)
        .appendingPathComponent("ShellIntegration/zsh", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: bootstrap.appendingPathComponent(".zshenv").path))
    #expect(spec.environment["ZDOTDIR"] == bootstrap.path)
    #expect(spec.environment["CHERRY_BOOTSTRAP_ZDOTDIR"] == bootstrap.path)
    #expect(spec.environment["CHERRY_STARTUP_COMMAND"] == agent.startupCommand)
    #expect(spec.environment["GHOSTTY_ZSH_ZDOTDIR"] == nil)
    #expect(spec.environment["LANGUAGE"] == nil)
    #expect(spec.shellCommand == "/bin/zsh -l")
    let staged = try await stager.resolve()
    #expect(spec.environment["TERMINFO"] == staged.terminfoDirectory)
}

// MARK: - RemoteLaunchSpec (docs/specs/remote-devices.md)

@Test func remoteLaunchSpecCarriesTheTabNotThisMac() {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/me/app").key
    let processID = UUID().uuidString
    let terminal = ShellProcessController.Configuration(
        shellPath: "/opt/homebrew/bin/fish",
        workingDirectory: "/Users/me/app/web",
        projectRoot: key,
        processID: processID,
        environment: [
            "PORT": "8000", "PATH": "/local/bin", "HOME": "/Users/local", "CHERRY_CONTROL_SOCKET": "/tmp/cherry.sock",
            "ZDOTDIR": "/local/zdotdir", "GHOSTTY_RESOURCES_DIR": "/Applications/Cherry.app/x", "SSH_AUTH_SOCK": "/tmp/agent",
            "TERMINFO": "/local/terminfo", "CHERRY_STARTUP_COMMAND": "echo local", "SSH_TTY": "/dev/ttys003"
        ],
        term: ShellProcessController.ghosttyTerm,
        initialSize: TerminalViewportSize(columns: 80, rows: 24)
    )
    let locale = ["LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8", "PATH": "/login/bin", "HOME": "/Users/local", "TMPDIR": "/var/x"]
    let spec = RemoteLaunchSpec.make(for: terminal, remoteShell: "/bin/zsh", localeEnvironment: locale)
    // The host runs the other Mac's account's login shell, in the path there.
    #expect(spec.argv.isEmpty)
    #expect(spec.workingDirectory == "/Users/me/app/web")
    #expect(spec.environment == [
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Cherry", "CHERRY_TERM_PROGRAM": "Cherry",
        "INSIDE_CHERRY": "1", "CHERRY_PROJECT_ROOT": "/Users/me/app", "CHERRY_PROCESS_ID": processID,
        "PORT": "8000", "LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8",
        // Remote, as over ssh, so programs copy with OSC 52 (to this Mac's
        // clipboard); SSH_TTY is the holder's, never this Mac's.
        "SSH_CONNECTION": "127.0.0.1 0 127.0.0.1 22", "SSH_CLIENT": "127.0.0.1 0 22"
    ])
    for key in ["PATH", "HOME", "CHERRY_CONTROL_SOCKET", "SSH_AUTH_SOCK", "SSH_TTY", "TMPDIR", "ZDOTDIR", "TERMINFO", "SHELL"] {
        #expect(spec.environment[key] == nil, "\(key)")
    }
    #expect(spec.resourcesCopy == nil)

    // An agent (or a command) runs its line in the other Mac's login shell.
    let agent = ShellProcessController.Configuration(
        shellPath: "/opt/homebrew/bin/fish",
        workingDirectory: "/Users/me/app",
        projectRoot: key,
        processID: processID,
        agentID: processID,
        term: ShellProcessController.ghosttyTerm,
        initialSize: TerminalViewportSize(columns: 80, rows: 24),
        startupCommand: "claude --resume 'it''s'"
    )
    let agentSpec = RemoteLaunchSpec.make(for: agent, remoteShell: "/bin/bash", localeEnvironment: [:])
    #expect(agentSpec.argv == ["/bin/bash", "-l", "-c", "claude --resume 'it''s'"])
    #expect(agentSpec.environment["CHERRY_AGENT_ID"] == processID)
    #expect(agentSpec.environment["CHERRY_STARTUP_COMMAND"] == nil)
    #expect(agentSpec.environment["SSH_CONNECTION"] == "127.0.0.1 0 127.0.0.1 22")
    // A shell the device did not report: macOS's default.
    #expect(RemoteLaunchSpec.make(for: agent, remoteShell: "", localeEnvironment: [:]).argv.first == "/bin/zsh")
}

@Test func theAppDropsATabsIdentityItWasLaunchedWith() {
    // `open` from a Cherry tab passes that tab's environment to the app.
    let keys = [
        "CHERRY_SESSION_ID", CherryControl.processIDEnvironmentKey, CherryControl.agentIDEnvironmentKey,
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION",
    ]
    // Never this process's own environment: libghostty, initialised by
    // other tests, builds native surfaces' environments from the block it
    // saw then, which a change here would move or shorten under it.
    var removed: Set<String> = []
    CherryTabEnvironment.removeFromProcess { removed.insert($0) }
    for key in keys { #expect(removed.contains(key)) }
    #expect(!removed.contains("CHERRY_HOST_SOCKET_PROBE_KEEP"))
    #expect(!removed.contains("PATH"))
}
