import Crypto
import Foundation
import NIOSSH
import Testing
@testable import CherryMobileKit

/// Runs `command` as the Mac's login shell would (`zsh -c`), with `HOME`.
private func runAsLoginShell(_ command: String, home: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-f", "-c", command]
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-mobile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func makeExecutable(_ url: URL, _ script: String = "#!/bin/sh\nexit 0\n") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func quotedWordsSurviveTheLoginShell() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let words = ["/bin/echo", "it's", "$HOME", "a b", "`x`", "\"q\""]
    #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
    let result = try runAsLoginShell(ShellQuote.command(words), home: home)
    #expect(result.output == "it's $HOME a b `x` \"q\"\n")
}

@Test func cherryIsFoundOnTheEndpointsPathFirstThenInTheApplicationsFolders() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let own = home.appendingPathComponent("tools dir/cherry")
    let userApp = home.appendingPathComponent("Applications/Cherry.app/Contents/MacOS/cherry")
    let systemApp = home.appendingPathComponent("System/Cherry.app/Contents/MacOS/cherry")
    // The same shape as the real candidates: `$HOME` expands there.
    let candidates = [#"$HOME/Applications/Cherry.app/Contents/MacOS/cherry"#, systemApp.path]

    #expect(try runAsLoginShell(CherryLocator.command(cherryPath: own.path, candidates: candidates), home: home).status == 127)
    try makeExecutable(systemApp)
    #expect(try runAsLoginShell(CherryLocator.command(cherryPath: nil, candidates: candidates), home: home).output == systemApp.path + "\n")
    try makeExecutable(userApp)
    #expect(try runAsLoginShell(CherryLocator.command(cherryPath: own.path, candidates: candidates), home: home).output == userApp.path + "\n")
    try makeExecutable(own)
    let found = try runAsLoginShell(CherryLocator.command(cherryPath: own.path, candidates: candidates), home: home)
    #expect(found == (0, own.path + "\n"))
    #expect(CherryLocator.candidates == [
        #"$HOME/Applications/Cherry.app/Contents/MacOS/cherry"#,
        "/Applications/Cherry.app/Contents/MacOS/cherry",
    ])
}

@Test func theAgentStateCommandsCallTheMCPHelperOncePerRoot() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    // A stand-in helper that prints its arguments, one call per line.
    let mcp = home.appendingPathComponent("Cherry.app/Contents/MacOS/CherryMCP")
    try makeExecutable(mcp, #"#!/bin/sh"# + "\n" + #"printf '%s|' "$@"; printf '\n'"# + "\n")
    let cherry = home.appendingPathComponent("Cherry.app/Contents/MacOS/cherry").path
    #expect(AgentStateCommands.mcpPath(nextTo: cherry) == mcp.path)

    let projects = try runAsLoginShell(AgentStateCommands.listProjects(mcpPath: mcp.path), home: home)
    #expect(projects == (0, "--call|list_projects|\n"))
    let processes = try runAsLoginShell(
        AgentStateCommands.listProcesses(mcpPath: mcp.path, roots: ["/Users/me/cherry", "/Users/me/it's \"here\""]),
        home: home
    )
    #expect(processes.output == #"""
    --call|list_processes|{"project_root":"/Users/me/cherry"}|
    --call|list_processes|{"project_root":"/Users/me/it's \"here\""}|

    """#)
    #expect(try runAsLoginShell(AgentStateCommands.listProjects(mcpPath: home.appendingPathComponent("none").path), home: home).status == 3)
}

@Test func fingerprintsAreOpenSSHs() throws {
    // `ssh-keygen -lf -E sha256` of this key: SHA256:bCclNLkphEJQt57YtXE+uupAKCJvqnlUC66A7FxPPbQ.
    let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzrcsuwOW8s1E5y8Bjh5i1hXht0NUgEslGAWBKdv8fb vector"
    #expect(SSHKeys.fingerprint(ofOpenSSHLine: line) == "SHA256:bCclNLkphEJQt57YtXE+uupAKCJvqnlUC66A7FxPPbQ")
    #expect(SSHKeys.fingerprint(of: try NIOSSHPublicKey(openSSHPublicKey: line)) == "SHA256:bCclNLkphEJQt57YtXE+uupAKCJvqnlUC66A7FxPPbQ")
    #expect(SSHKeys.fingerprint(ofOpenSSHLine: "not a key") == nil)
}

@Test func aDevicesPublicKeyIsAnAuthorizedKeysLine() throws {
    let raw = Data((0..<32).map { UInt8($0) })
    let identity = try InMemoryDeviceIdentity(rawRepresentation: raw)
    let line = try identity.publicKey()
    #expect(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    #expect(line.hasSuffix(" cherry-ios"))
    // NIOSSH reads it back as the same key.
    let parsed = try NIOSSHPublicKey(openSSHPublicKey: String(line.dropLast(" cherry-ios".count)))
    #expect(parsed == NIOSSHPrivateKey(ed25519Key: try identity.signingKey()).publicKey)
    let id = try identity.deviceID()
    #expect(id.count == 16 && id.allSatisfy(\.isHexDigit))
    #expect(try InMemoryDeviceIdentity(rawRepresentation: raw).deviceID() == id)
    #expect(try InMemoryDeviceIdentity().deviceID() != id)
}

@Test func anIdentityThatCannotSignIsRefused() async {
    struct PublicOnly: DeviceIdentity {
        func publicKey() throws -> String { "ssh-ed25519 AAAA" }
    }
    await #expect(throws: MacConnectionError.failed("This device's identity can't sign an SSH login.")) {
        _ = try await SSHMacConnector(identity: PublicOnly()).connect(to: DemoMac.endpoint)
    }
}

@Test func nothingListensMeansUnreachable() async throws {
    // A port nothing listens on, on this Mac's loopback only.
    let endpoint = MacEndpoint(name: "Nowhere", host: "127.0.0.1", port: 9, user: "me")
    do {
        _ = try await SSHMacConnector(identity: InMemoryDeviceIdentity()).connect(to: endpoint)
        Issue.record("connected to nothing")
    } catch let error as MacConnectionError {
        guard case .unreachable = error else {
            Issue.record("expected unreachable, got \(error)")
            return
        }
    }
}
