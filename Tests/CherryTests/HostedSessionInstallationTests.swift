import Foundation
import Testing
@testable import Cherry

private struct HostedInstallationFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func executable(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func HostedSessionLookupSkipsTheRunningGUIBinaryOnCaseInsensitiveVolumes() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // `swift run Cherry`: the GUI is .build/debug/Cherry, and on the default
    // case-insensitive APFS `.build/debug/cherry` opens that same file.
    let gui = try fixture.executable("build/debug/Cherry")
    let helper = try fixture.executable("source/Host/target/debug/cherry")
    let client = try HostedSessionClient.installed(
        environment: [:],
        runningExecutable: gui,
        bundleURL: gui.deletingLastPathComponent(),
        sourceRoot: fixture.url("source")
    )
    #expect(client.executableURL.standardizedFileURL == helper.standardizedFileURL)
    #expect(!HostedSessionClient.isHelper(fixture.url("build/debug/cherry"), runningExecutable: gui))
}

@Test func HostedSessionLookupRejectsAHelperThatIsTheRunningExecutable() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    let gui = try fixture.executable("bin/CherryGUI")
    let helper = fixture.url("bin/cherry")
    // Same inode under the exact-case helper name.
    try FileManager.default.linkItem(at: gui, to: helper)
    #expect(!HostedSessionClient.isHelper(helper, runningExecutable: gui))
    try FileManager.default.removeItem(at: helper)
    try fixture.executable("bin/cherry")
    #expect(HostedSessionClient.isHelper(helper, runningExecutable: gui))
    #expect(!HostedSessionClient.isHelper(fixture.url("bin/missing"), runningExecutable: gui))
}

@Test func HostedSessionPackagedAppUsesOnlyItsBundledHelper() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    let app = fixture.url("Cherry Sessions.app")
    let gui = try fixture.executable("Cherry Sessions.app/Contents/MacOS/CherryApp")
    try fixture.executable("source/Host/target/release/cherry")
    try fixture.executable("path/cherry")
    let environment = ["PATH": fixture.url("path").path]

    // A missing bundled helper fails instead of using the build tree, a
    // Cargo target directory from the environment, or PATH.
    try fixture.executable("cargo-out/release/cherry")
    var packagedEnvironment = environment
    packagedEnvironment["CARGO_TARGET_DIR"] = fixture.url("cargo-out").path
    do {
        let client = try HostedSessionClient.installed(
            environment: packagedEnvironment, runningExecutable: gui, bundleURL: app,
            sourceRoot: fixture.url("source"), isDebugBuild: false
        )
        Issue.record("Expected a missing-helper error, got \(client.executableURL.path)")
    } catch let HostedSessionError.message(message) {
        // It explains the likely cause and the launch-environment escape hatch.
        #expect(message.contains("CHERRY_SKIP_HOST=1"))
        #expect(message.contains("open --env CHERRY_CLI_PATH=/abs/path/to/cherry '\(app.path)'"))
    }
    let bundled = try fixture.executable("Cherry Sessions.app/Contents/MacOS/cherry")
    let client = try HostedSessionClient.installed(
        environment: environment, runningExecutable: gui, bundleURL: app,
        sourceRoot: fixture.url("source"), isDebugBuild: false
    )
    #expect(client.executableURL.standardizedFileURL == bundled.standardizedFileURL)
}

@Test func HostedSessionDebugAppBundleFallsBackToTheHostBuild() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // A debug app bundle without helpers (such as CherryDev.app built with
    // CHERRY_SKIP_HOST=1) whose GUI is named Cherry: on a case-insensitive
    // volume its Contents/MacOS/cherry names that GUI.
    let app = fixture.url("dist/CherryDev.app")
    let gui = try fixture.executable("dist/CherryDev.app/Contents/MacOS/Cherry")
    let helper = try fixture.executable("source/Host/target/debug/cherry")
    let client = try HostedSessionClient.installed(
        environment: [:], runningExecutable: gui, bundleURL: app,
        sourceRoot: fixture.url("source"), isDebugBuild: true
    )
    #expect(client.executableURL.standardizedFileURL == helper.standardizedFileURL)
    // The same bundle from a release build must ship its helper.
    #expect(throws: HostedSessionError.self) {
        try HostedSessionClient.installed(
            environment: [:], runningExecutable: gui, bundleURL: app,
            sourceRoot: fixture.url("source"), isDebugBuild: false
        )
    }
}

@Test func HostedSessionDevelopmentLookupHonoursCargoTargetDirectory() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    let gui = try fixture.executable("build/debug/Cherry")
    // A stale helper left in the workspace's own target directory.
    let workspaceHelper = try fixture.executable("source/Host/target/debug/cherry")
    let redirected = try fixture.executable("cargo-out/debug/cherry")
    let configured = try fixture.executable("cargo-config/release/cherry")
    func lookup(_ environment: [String: String]) throws -> String {
        try HostedSessionClient.installed(
            environment: environment, runningExecutable: gui,
            bundleURL: gui.deletingLastPathComponent(), sourceRoot: fixture.url("source")
        ).executableURL.standardizedFileURL.path
    }

    #expect(try lookup(["CARGO_TARGET_DIR": fixture.url("cargo-out").path]) == redirected.standardizedFileURL.path)
    #expect(try lookup(["CARGO_BUILD_TARGET_DIR": fixture.url("cargo-config").path])
        == configured.standardizedFileURL.path)
    // Cargo's precedence: CARGO_TARGET_DIR wins, and an empty value is unset.
    #expect(try lookup([
        "CARGO_TARGET_DIR": fixture.url("cargo-out").path,
        "CARGO_BUILD_TARGET_DIR": fixture.url("cargo-config").path,
    ]) == redirected.standardizedFileURL.path)
    #expect(try lookup([
        "CARGO_TARGET_DIR": "",
        "CARGO_BUILD_TARGET_DIR": fixture.url("cargo-config").path,
    ]) == configured.standardizedFileURL.path)
    // A target directory without helpers still falls back to Host/target.
    #expect(try lookup(["CARGO_TARGET_DIR": fixture.url("empty").path]) == workspaceHelper.standardizedFileURL.path)
    #expect(try lookup([:]) == workspaceHelper.standardizedFileURL.path)

    // Relative values are relative to the current directory, as for Cargo.
    let directories = HostedSessionClient.developmentTargetDirectories(
        environment: ["CARGO_TARGET_DIR": "relative/target"], sourceRoot: fixture.url("source")
    )
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    #expect(directories.map(\.path) == [
        currentDirectory.appendingPathComponent("relative/target").standardizedFileURL.path,
        fixture.url("source/Host/target").standardizedFileURL.path,
    ])
    // Pointing Cargo at Host/target itself does not list it twice.
    #expect(HostedSessionClient.developmentTargetDirectories(
        environment: ["CARGO_TARGET_DIR": fixture.url("source/Host/target").path], sourceRoot: fixture.url("source")
    ).count == 1)
}

@Test func HostedSessionDevelopmentRunFallsBackToPATHAndHonorsOverride() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    let gui = try fixture.executable("build/Cherry")
    let onPath = try fixture.executable("path/cherry")
    let client = try HostedSessionClient.installed(
        environment: ["PATH": "/nonexistent:\(fixture.url("path").path)"],
        runningExecutable: gui,
        bundleURL: gui.deletingLastPathComponent(),
        sourceRoot: fixture.url("empty-source")
    )
    #expect(client.executableURL.standardizedFileURL == onPath.standardizedFileURL)

    let override = try fixture.executable("override/custom-cherry")
    let overridden = try HostedSessionClient.installed(
        environment: ["CHERRY_CLI_PATH": override.path],
        runningExecutable: gui,
        bundleURL: gui.deletingLastPathComponent()
    )
    #expect(overridden.executableURL.path == override.path)
    #expect(throws: HostedSessionError.self) {
        try HostedSessionClient.installed(
            environment: ["CHERRY_CLI_PATH": fixture.url("override/missing").path],
            runningExecutable: gui,
            bundleURL: gui.deletingLastPathComponent()
        )
    }
}

@Test func HostedSessionDetectsAppsRunningFromADiskImage() {
    let readOnly: (URL) -> Bool = { _ in true }
    let writable: (URL) -> Bool = { _ in false }
    #expect(HostedSessionInstallation.runsFromDiskImage(
        bundleURL: URL(fileURLWithPath: "/Volumes/Cherry Sessions/Cherry Sessions.app"), volumeIsReadOnly: readOnly
    ))
    #expect(!HostedSessionInstallation.runsFromDiskImage(
        bundleURL: URL(fileURLWithPath: "/Volumes/External/Apps/Cherry Sessions.app"), volumeIsReadOnly: writable
    ))
    #expect(HostedSessionInstallation.runsFromDiskImage(
        bundleURL: URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Cherry Sessions.app"),
        volumeIsReadOnly: writable
    ))
    #expect(!HostedSessionInstallation.runsFromDiskImage(
        bundleURL: URL(fileURLWithPath: "/Applications/Cherry Sessions.app"), volumeIsReadOnly: readOnly
    ))
    #expect(HostedSessionInstallation.diskImageWarning(
        bundleURL: URL(fileURLWithPath: "/Volumes/Cherry Sessions/Cherry Sessions.app")
    ) == "Move Cherry Sessions to Applications first; sessions started from the disk image stop working when it is ejected.")
}

@Test func HostedSessionLoginEnvironmentParsesOnlyTheMarkedOutput() throws {
    let marker = "__MARK__"
    var data = Data("rc noise __MAR\n".utf8)
    data.append(Data(marker.utf8))
    for entry in [
        "SSH_AUTH_SOCK=/login/agent.sock", "PATH=/login/bin:/usr/bin", "EQUALS=a=b", "PWD=/tmp",
        "SHLVL=2", "CHERRY_PROCESS_ID=tab", "TERM=dumb", "=broken", "no-equals"
    ] {
        data.append(Data(entry.utf8))
        data.append(0)
    }
    data.append(Data(marker.utf8))
    data.append(Data("trailing noise".utf8))
    let environment = try #require(HostedSessionLoginEnvironment.parse(data, marker: marker))
    #expect(environment == [
        "SSH_AUTH_SOCK": "/login/agent.sock", "PATH": "/login/bin:/usr/bin", "EQUALS": "a=b"
    ])
    #expect(HostedSessionLoginEnvironment.parse(Data("no markers".utf8), marker: marker) == nil)

    let helper = HostedSessionLoginEnvironment.helperEnvironment(
        base: [
            "PATH": "/usr/bin", "HOME": "/Users/me", "CHERRY_PROCESS_ID": "tab", "TERM": "xterm-ghostty",
            "CHERRY_HOST_SOCKET": "/tmp/private/host.sock"
        ],
        login: ["PATH": "/login/bin", "SSH_AUTH_SOCK": "/login/agent.sock"]
    )
    // Helper configuration such as CHERRY_HOST_SOCKET still reaches the CLI.
    #expect(helper == [
        "PATH": "/login/bin", "HOME": "/Users/me", "SSH_AUTH_SOCK": "/login/agent.sock",
        "CHERRY_HOST_SOCKET": "/tmp/private/host.sock"
    ])
}

@Test func HostedSessionLoginEnvironmentCapturesWhatShellStartupFilesExport() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // Stands in for `$SHELL -l -i -c <command>`: rc output, an exported agent
    // socket, and a background job that keeps stdout open after the shell exits.
    let shell = fixture.url("login-shell")
    try """
    #!/bin/sh
    [ "$1" = -l ] && [ "$2" = -i ] && [ "$3" = -c ] || exit 64
    printf 'Welcome from .zshrc\\n'
    export SSH_AUTH_SOCK=/login/agent.sock
    export CHERRY_PROCESS_ID=leaked
    /bin/sleep 5 &
    exec /bin/sh -c "$4"
    """.write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

    let started = Date()
    let captured = try #require(HostedSessionLoginEnvironment.capture(
        shellPath: shell.path,
        baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "CHERRY_AGENT_ID": "agent"],
        timeout: 4
    ))
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(captured.fromUserShell)
    let environment = captured.environment
    #expect(environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    #expect(environment["HOME"] == NSHomeDirectory())
    #expect(environment["CHERRY_PROCESS_ID"] == nil)
    #expect(environment["CHERRY_AGENT_ID"] == nil)
    #expect(environment["PWD"] == nil)

    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: shell, atomically: true, encoding: .utf8)
    let hungStart = Date()
    #expect(HostedSessionLoginEnvironment.capture(shellPath: shell.path, baseEnvironment: [:], timeout: 0.3) == nil)
    #expect(Date().timeIntervalSince(hungStart) < 3)

    let resolver = HostedSessionLoginEnvironment(
        shellPath: fixture.url("missing-shell").path, fallbackShellPath: nil, timeout: 1
    )
    #expect(resolver.resolve() == nil)
}

@Test func HostedSessionLoginEnvironmentStartsEachShellTheWayItAcceptsALogin() {
    let command = "/usr/bin/env -0"
    for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/local/bin/nu"] {
        #expect(HostedSessionLoginEnvironment.invocations(shellPath: shell, fallbackShellPath: nil, command: command) == [
            .init(path: shell, arguments: [shell, "-l", "-i", "-c", command], input: nil)
        ])
    }
    // csh and tcsh reject -l next to any other flag ("Unknown option: `-l'").
    for shell in ["/bin/csh", "/bin/tcsh"] {
        #expect(HostedSessionLoginEnvironment.invocations(shellPath: shell, fallbackShellPath: "/bin/sh", command: command) == [
            .init(path: shell, arguments: [shell, "-l"], input: command + "\n"),
            .init(path: "/bin/sh", arguments: ["/bin/sh", "-l", "-c", command], input: nil)
        ])
    }
    #expect(HostedSessionLoginEnvironment.invocations(shellPath: "/bin/sh", fallbackShellPath: "/bin/sh", command: command).count == 1)

    // A shell that echoes its input never shows a whole marker.
    let marker = "__CHERRY_LOGIN_ENVIRONMENT_TEST__"
    #expect(!HostedSessionLoginEnvironment.command(marker: marker).contains(marker))
}

/// Real csh and tcsh, as a login shell of a user whose startup files export
/// the agent socket, one of them only for interactive shells. Skipped where
/// neither is installed.
@Test(arguments: ["/bin/tcsh", "/bin/csh"].filter { FileManager.default.isExecutableFile(atPath: $0) })
func HostedSessionLoginEnvironmentCapturesFromCsh(shell: String) throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    try """
    echo "Welcome from .cshrc"
    setenv FROM_CSHRC yes
    if ($?prompt) then
      setenv SSH_AUTH_SOCK /login/agent.sock
    endif
    """.write(to: fixture.url(".cshrc"), atomically: true, encoding: .utf8)
    try "echo 'Welcome from .login'\nsetenv FROM_LOGIN yes\n".write(to: fixture.url(".login"), atomically: true, encoding: .utf8)

    let started = Date()
    let captured = try #require(HostedSessionLoginEnvironment.capture(
        shellPath: shell,
        fallbackShellPath: nil,
        baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "USER": NSUserName()],
        timeout: 5
    ))
    #expect(Date().timeIntervalSince(started) < 4)
    #expect(captured.fromUserShell)
    let environment = captured.environment
    #expect(environment["FROM_CSHRC"] == "yes")
    #expect(environment["FROM_LOGIN"] == "yes")
    #expect(environment["SSH_AUTH_SOCK"] == "/login/agent.sock")
    #expect(environment["HOME"] == fixture.root.path)
}

@Test func HostedSessionLoginEnvironmentFallsBackToAPOSIXLoginShell() throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // A POSIX sh as a login shell: /etc/profile and ~/.profile.
    let fallback = fixture.url("sh")
    let fallbackRan = fixture.url("fallback-ran")
    try """
    #!/bin/sh
    : > '\(fallbackRan.path)'
    [ "$1" = -l ] && [ "$2" = -c ] || exit 64
    export FROM_PROFILE=yes
    exec /bin/sh -c "$3"
    """.write(to: fallback, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallback.path)
    func capture(_ shell: URL, timeout: TimeInterval = 4) -> HostedSessionLoginEnvironment.Capture? {
        HostedSessionLoginEnvironment.capture(
            shellPath: shell.path, fallbackShellPath: fallback.path,
            baseEnvironment: ["PATH": "/usr/bin:/bin"], timeout: timeout
        )
    }

    // A shell that rejects the flags, and one that does not exist.
    let shell = fixture.url("strict-shell")
    try "#!/bin/sh\nprintf 'unknown option -i\\n'\nexit 2\n".write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
    for primary in [shell, fixture.url("missing-shell")] {
        let started = Date()
        let captured = try #require(capture(primary))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(captured.environment["FROM_PROFILE"] == "yes")
        // The user's own startup files did not run.
        #expect(!captured.fromUserShell)
    }

    // A shell that works is used alone.
    try FileManager.default.removeItem(at: fallbackRan)
    try "#!/bin/sh\nexport FROM_SHELL=yes\nexec /bin/sh -c \"$4\"\n".write(to: shell, atomically: true, encoding: .utf8)
    let captured = try #require(capture(shell))
    #expect(captured.fromUserShell)
    #expect(captured.environment["FROM_SHELL"] == "yes")
    #expect(captured.environment["FROM_PROFILE"] == nil)
    #expect(!FileManager.default.fileExists(atPath: fallbackRan.path))

    // A shell that hangs uses up the whole deadline; nothing runs after it.
    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: shell, atomically: true, encoding: .utf8)
    let hungStart = Date()
    #expect(capture(shell, timeout: 0.3) == nil)
    #expect(Date().timeIntervalSince(hungStart) < 3)
    #expect(!FileManager.default.fileExists(atPath: fallbackRan.path))
}

@Test func HostedSessionLoginEnvironmentRetriesAFailedCaptureAfterABackoff() {
    typealias Capture = HostedSessionLoginEnvironment.Capture
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var clock: TimeInterval = 1_000
        var results: [Capture?] = []
        var captures = 0
        func now() -> TimeInterval { lock.withLock { clock } }
        func advance(to time: TimeInterval) { lock.withLock { clock = 1_000 + time } }
        func capture() -> Capture? {
            lock.withLock {
                captures += 1
                return results.isEmpty ? nil : results.removeFirst()
            }
        }
    }
    let script = Script()
    let captured = Capture(environment: ["SSH_AUTH_SOCK": "/login/agent.sock"])
    script.results = [nil, nil, captured]
    let resolver = HostedSessionLoginEnvironment(now: { script.now() }, capture: { script.capture() })

    // The first capture failed (a cold first launch that took too long).
    #expect(resolver.resolve() == nil)
    #expect(script.captures == 1)
    // Helper commands meanwhile do not each wait for a failing shell.
    script.advance(to: 14.9)
    #expect(resolver.resolve() == nil)
    #expect(script.captures == 1)
    script.advance(to: 15)
    #expect(resolver.resolve() == nil)
    #expect(script.captures == 2)
    // Each further failure waits twice as long.
    script.advance(to: 44.9)
    #expect(resolver.resolve() == nil)
    #expect(script.captures == 2)
    script.advance(to: 45)
    #expect(resolver.resolve() == captured)
    #expect(script.captures == 3)
    // A successful capture is kept, even for an explicit refresh.
    script.advance(to: 10_000)
    #expect(resolver.resolve() == captured)
    #expect(resolver.resolve(retryingNow: true) == captured)
    #expect(script.captures == 3)

    #expect((1...7).map(HostedSessionLoginEnvironment.retryDelay(afterFailures:)) == [15, 30, 60, 120, 240, 300, 300])
}

/// When only the POSIX fallback prints the environment, the user's own
/// shell startup files never ran: use what it found, but keep trying the
/// user's shell, sooner when the user refreshes.
@Test func HostedSessionLoginEnvironmentKeepsTryingTheUserShellAfterAFallbackCapture() {
    typealias Capture = HostedSessionLoginEnvironment.Capture
    final class Script: @unchecked Sendable {
        let lock = NSLock()
        var clock: TimeInterval = 1_000
        var results: [Capture?] = []
        var captures = 0
        func now() -> TimeInterval { lock.withLock { clock } }
        func advance(to time: TimeInterval) { lock.withLock { clock = 1_000 + time } }
        func capture() -> Capture? {
            lock.withLock {
                captures += 1
                return results.isEmpty ? nil : results.removeFirst()
            }
        }
    }
    let script = Script()
    let profile = Capture(environment: ["FROM_PROFILE": "yes"], fromUserShell: false)
    let captured = Capture(environment: ["SSH_AUTH_SOCK": "/login/agent.sock"])
    script.results = [profile, nil, nil, captured]
    let resolver = HostedSessionLoginEnvironment(now: { script.now() }, capture: { script.capture() })

    #expect(resolver.resolve() == profile)
    #expect(script.captures == 1)
    // Until the backoff passes, helpers use the fallback's capture.
    script.advance(to: 14.9)
    #expect(resolver.resolve() == profile)
    #expect(script.captures == 1)
    // A later attempt that fails outright keeps the fallback's capture.
    script.advance(to: 15)
    #expect(resolver.resolve() == profile)
    #expect(script.captures == 2)
    // An explicit refresh tries again at once.
    script.advance(to: 16)
    #expect(resolver.resolve(retryingNow: true) == profile)
    #expect(script.captures == 3)
    #expect(resolver.resolve(retryingNow: true) == captured)
    #expect(script.captures == 4)
    // The user's shell worked (its startup files were fixed): that is kept.
    script.advance(to: 10_000)
    #expect(resolver.resolve(retryingNow: true) == captured)
    #expect(script.captures == 4)
}

/// Two explicit refreshes at once, with a shell that fails slowly: the
/// second waits for the first attempt and uses its result instead of
/// running the shell again.
@Test func HostedSessionLoginEnvironmentSharesAnAttemptThatEndedWhileWaiting() {
    typealias Capture = HostedSessionLoginEnvironment.Capture
    final class Script: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let asked = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var clock: TimeInterval = 0
        var captureCount = 0
        var resolvedValues: [Capture?] = []
        var captures: Int { lock.withLock { captureCount } }
        var resolved: [Capture?] { lock.withLock { resolvedValues } }
        func record(_ capture: Capture?) { lock.withLock { resolvedValues.append(capture) } }
        /// Every reading is later than the one before, and is announced.
        func now() -> TimeInterval {
            defer { asked.signal() }
            return lock.withLock {
                clock += 1
                return clock
            }
        }
        func capture() -> Capture? {
            lock.withLock { captureCount += 1 }
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return nil
        }
    }
    let script = Script()
    let resolver = HostedSessionLoginEnvironment(now: { script.now() }, capture: { script.capture() })
    let calls = DispatchGroup()
    func resolveInBackground() {
        DispatchQueue.global().async(group: calls) {
            script.record(resolver.resolve(retryingNow: true))
        }
    }
    resolveInBackground()
    #expect(script.asked.wait(timeout: .now() + 5) == .success)
    #expect(script.started.wait(timeout: .now() + 5) == .success)
    resolveInBackground()
    // The second call has asked for the time, so it started before the
    // first attempt ends.
    #expect(script.asked.wait(timeout: .now() + 5) == .success)
    script.release.signal()
    #expect(calls.wait(timeout: .now() + 5) == .success)
    #expect(script.resolved == [nil, nil])
    #expect(script.captures == 1)
    // A refresh that starts after that attempt ended runs the shell again.
    script.release.signal()
    #expect(resolver.resolve(retryingNow: true) == nil)
    #expect(script.captures == 2)
}

@Test func HostedSessionLoginEnvironmentShellRunsWithoutCherrysTerminal() async throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // An interactive shell sharing the terminal Cherry was started from
    // (`swift run Cherry`) is stopped by SIGTTOU/SIGTTIN when it tries to
    // take that terminal over. The capture shell gets a session of its own.
    let pidFile = fixture.url("shell.pid")
    let proceed = fixture.url("proceed")
    let shell = fixture.url("login-shell")
    try """
    #!/bin/sh
    printf '%s\\n' "$$" > '\(pidFile.path)'
    if (: < /dev/tty) 2>/dev/null; then export CAPTURE_TTY=yes; else export CAPTURE_TTY=no; fi
    i=0
    while [ ! -f '\(proceed.path)' ] && [ "$i" -lt 250 ]; do /bin/sleep 0.02; i=$((i + 1)); done
    exec /bin/sh -c "$4"
    """.write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

    let shellPath = shell.path
    let capture = Task.detached {
        HostedSessionLoginEnvironment.capture(
            shellPath: shellPath, baseEnvironment: ["PATH": "/usr/bin:/bin"], timeout: 10
        )
    }
    var pid: pid_t?
    let deadline = Date().addingTimeInterval(5)
    while pid == nil, Date() < deadline {
        let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        if text.hasSuffix("\n") { pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if pid == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    let shellPID = try #require(pid)
    #expect(getsid(shellPID) == shellPID)
    #expect(getsid(shellPID) != getsid(0))
    try Data().write(to: proceed)

    let environment = try #require(await capture.value).environment
    #expect(environment["CAPTURE_TTY"] == "no")
    #expect(environment["PATH"] == "/usr/bin:/bin")
}

@Test func HostedSessionLoginEnvironmentTimeoutKillsTheShellAndItsJobs() async throws {
    let fixture = try HostedInstallationFixture()
    defer { fixture.cleanUp() }
    // Interactive shells ignore SIGTERM; a hung capture must still end.
    let pids = fixture.url("pids")
    let shell = fixture.url("login-shell")
    try """
    #!/bin/sh
    trap '' TERM HUP INT
    /bin/sleep 30 &
    printf '%s %s\\n' "$$" "$!" > '\(pids.path)'
    wait
    """.write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)

    let started = Date()
    #expect(HostedSessionLoginEnvironment.capture(shellPath: shell.path, baseEnvironment: [:], timeout: 0.5) == nil)
    #expect(Date().timeIntervalSince(started) < 3)
    let recorded = try String(contentsOf: pids, encoding: .utf8)
        .split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { pid_t($0) }
    #expect(recorded.count == 2)
    let deadline = Date().addingTimeInterval(3)
    while recorded.contains(where: { kill($0, 0) == 0 }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    for pid in recorded {
        #expect(kill(pid, 0) != 0)
    }
}
