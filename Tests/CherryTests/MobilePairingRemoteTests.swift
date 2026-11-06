import Foundation
import Testing
@testable import Cherry

// Pairing with another Mac (MobilePairing/RemotePhonePairing.swift): its
// scripts run with `sh -s` in a temporary home through a fake ssh, as they
// run there over the device's SSH connection, with stand-in `cherry`
// builds (one that runs Cherry for iOS's gateway, one too old to) and host
// keys of the test's own. Nothing reads the real ~/.ssh or /etc/ssh.

private let phoneKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINsyIgyIP7VL9sFdYMZoAQs+q3BI8YDzU5dnjxVy1Jkz"
private let phoneFingerprint = "SHA256:w4eVI3TcBZZFR+dpMlGRFoDeYOl8S0DD9BtCkbOTUBU"
private let hostKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFVwL5R0QIeHf1+iQZMDHAZQ5XTTWtK251fPmVPqRROmH1wkgnqAIfTuyx1EIup7FiYrJt9XDz02tVnGtrd2ZCI="
private let hostFingerprint = "SHA256:9AvBDX/szDYr+uQKFx/fZRYIpdw72Qng8feINQKwgyI"

/// Another Mac in a temporary folder: its home, its installs of cherry, its
/// host keys, and an ssh that runs a script there.
private struct FakeOtherMac {
    let root: URL
    let home: URL
    let hostKeys: URL
    let ssh: URL

    init() throws {
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-remote-pairing-\(UUID().uuidString)")
        root = URL(fileURLWithPath: created.path.withCString { pointer in
            try? FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            guard let resolved = realpath(pointer, nil) else { return created.path }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        home = root.appendingPathComponent("home")
        hostKeys = root.appendingPathComponent("etc-ssh")
        ssh = root.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostKeys, withIntermediateDirectories: true)
        try (hostKey + " root@patstudio\n").write(to: hostKeys.appendingPathComponent("ssh_host_ecdsa_key.pub"), atomically: true, encoding: .utf8)
        // ssh's arguments are the destination's; the script comes on stdin.
        try Self.executable(at: ssh, """
        #!/bin/sh
        HOME="$FAKE_OTHER_MAC_HOME"
        export HOME
        exec /bin/sh -s
        """)
    }

    /// A build directory of this Cherry's install there with a `cherry`
    /// that runs the gateway (refusing a missing command as it does), or
    /// one from before it.
    func install(_ build: String, runsGateway: Bool) throws {
        let directory = home.appendingPathComponent("\(RemoteHostInstall.rootRelativePath)/\(build)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.executable(at: directory.appendingPathComponent("cherry"), runsGateway
            ? """
            #!/bin/sh
            [ "$1 $2" = "host mobile-gateway" ] || exit 2
            echo "cherry: this key reaches only Cherry's sessions, for Cherry for iOS: it runs no shell" >&2
            exit 1
            """
            : """
            #!/bin/sh
            echo "error: unrecognized subcommand '$2'" >&2
            exit 2
            """)
    }

    var keysFile: URL { home.appendingPathComponent(".ssh/authorized_keys") }
    var gatewayLink: URL { home.appendingPathComponent(RemoteHostInstall.gatewayLinkRelativePath) }

    func keys(install: String?) -> RemotePhoneKeys {
        let ssh = ssh.path
        let home = home.path
        return RemotePhoneKeys(
            machine: "patstudio", destination: "patstudio", installDirectory: install, hostKeyDirectory: hostKeys.path,
            shell: { RemoteDeviceShell(sshExecutable: ssh, environment: ["FAKE_OTHER_MAC_HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) }
        )
    }

    static func executable(at url: URL, _ text: String) throws {
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

@Test func anotherMacIsDescribedWithItsUserAddressesAndHostKeysOnceItsGatewayIsReady() async throws {
    let mac = try FakeOtherMac()
    try mac.install("20261101000000.old", runsGateway: false)
    try mac.install("20261105000000.new", runsGateway: true)
    let described = await mac.keys(install: "20261105000000.new").describe(name: "patstudio")
    guard case .success(let description) = described else {
        Issue.record("not described: \(described)")
        return
    }
    #expect(description.name == "patstudio")
    #expect(description.user == NSUserName())
    #expect(description.hostKeyFingerprints == [hostFingerprint])
    #expect(!description.hosts.isEmpty && !description.hosts.contains { $0.hasPrefix("127.") })
    // The link the key runs points at the install, relative to its folder.
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mac.gatewayLink.path) == "bin/20261105000000.new/cherry")
}

@Test func anotherMacWhoseInstallPredatesTheGatewayCannotBePairedWith() async throws {
    let mac = try FakeOtherMac()
    try mac.install("20261101000000.old", runsGateway: false)
    let keys = mac.keys(install: "20261101000000.old")
    let key = try #require(SSHPublicKeyLine(phoneKey))
    #expect(await keys.describe(name: "patstudio") == .failure(.unavailable(RemotePhoneKeys.noGatewayMessage(machine: "patstudio"))))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: mac.gatewayLink.path)) == nil)
    await #expect(throws: RemotePhoneKeys.Failure.noGateway(machine: "patstudio")) {
        try await keys.add(key, name: "iPhone")
    }
    #expect(!FileManager.default.fileExists(atPath: mac.keysFile.path))

    // A link a newer install left keeps working when the device's own
    // install is the old one.
    try mac.install("20261105000000.new", runsGateway: true)
    try FileManager.default.createSymbolicLink(atPath: mac.gatewayLink.path, withDestinationPath: "bin/20261105000000.new/cherry")
    if case .failure(let problem) = await keys.describe(name: "patstudio") { Issue.record("not described: \(problem)") }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mac.gatewayLink.path) == "bin/20261105000000.new/cherry")
}

@Test func anotherMacsPhonesAreAddedLimitedListedAndRemovedKeepingItsOtherLines() async throws {
    let mac = try FakeOtherMac()
    try mac.install("20261105000000.new", runsGateway: true)
    let keys = mac.keys(install: "20261105000000.new")
    let key = try #require(SSHPublicKeyLine(phoneKey))
    let gateway = "\(mac.home.path)/\(RemoteHostInstall.gatewayLinkRelativePath)"

    // No ~/.ssh yet: made 0700, the file 0600, the line runs the link.
    try await keys.add(key, name: "Patrick's iPhone")
    let ssh = mac.home.appendingPathComponent(".ssh")
    #expect(try FileManager.default.attributesOfItem(atPath: ssh.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: mac.keysFile.path)[.posixPermissions] as? Int == 0o600)
    #expect(try String(contentsOf: mac.keysFile, encoding: .utf8)
        == "restrict,pty,command=\"'\(gateway)' host mobile-gateway\" \(phoneKey) cherry-mobile Patrick's iPhone\n")
    #expect(try await keys.phones().map(\.name) == ["Patrick's iPhone"])

    // The user's lines and the file's mode stay; an old unlimited line of
    // Cherry's is limited in place.
    try "# mine\nssh-ed25519 AAAAmine me@laptop\n\n\(phoneKey) cherry-mobile Old iPhone\n".write(to: mac.keysFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: mac.keysFile.path)
    let old = try #require(try await keys.phones().first)
    #expect(!old.isLimited)
    try await keys.limit(old)
    #expect(try String(contentsOf: mac.keysFile, encoding: .utf8) == """
    # mine
    ssh-ed25519 AAAAmine me@laptop

    restrict,pty,command="'\(gateway)' host mobile-gateway" \(phoneKey) cherry-mobile Old iPhone

    """)
    #expect(try FileManager.default.attributesOfItem(atPath: mac.keysFile.path)[.posixPermissions] as? Int == 0o640)
    #expect(try await keys.phones().map(\.isLimited) == [true])

    try await keys.remove(try #require(try await keys.phones().first))
    #expect(try String(contentsOf: mac.keysFile, encoding: .utf8) == "# mine\nssh-ed25519 AAAAmine me@laptop\n\n")
    #expect(try await keys.phones().isEmpty)
    // No temporary file is left beside it.
    #expect(try FileManager.default.contentsOfDirectory(atPath: ssh.path) == ["authorized_keys"])
}

@Test func anotherMacsLinkedAuthorizedKeysIsLeftAloneWithTheLineToAdd() async throws {
    let mac = try FakeOtherMac()
    try mac.install("20261105000000.new", runsGateway: true)
    let managed = mac.root.appendingPathComponent("managed_keys")
    try "ssh-ed25519 AAAAmine me@laptop\n".write(to: managed, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: mac.keysFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: mac.keysFile, withDestinationURL: managed)
    do {
        try await mac.keys(install: "20261105000000.new").add(try #require(SSHPublicKeyLine(phoneKey)), name: "iPhone")
        Issue.record("added through a link")
    } catch let failure as RemotePhoneKeys.Failure {
        guard case .linked(let machine, let destination, let line) = failure else {
            Issue.record("not linked: \(failure)")
            return
        }
        #expect(machine == "patstudio" && destination == managed.path)
        #expect(line.hasSuffix("\(phoneKey) cherry-mobile iPhone"))
        #expect(failure.errorDescription?.contains("on patstudio is a link") == true)
    }
    #expect(try String(contentsOf: managed, encoding: .utf8) == "ssh-ed25519 AAAAmine me@laptop\n")
}

@Test func aFileThatChangedSinceItWasReadIsNotOverwritten() async throws {
    let mac = try FakeOtherMac()
    try FileManager.default.createDirectory(at: mac.keysFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "ssh-ed25519 AAAAmine me@laptop\n".write(to: mac.keysFile, atomically: true, encoding: .utf8)
    let script = RemotePhonePairing.writeScript(text: "replaced\n", mode: "600", expectedHash: String(repeating: "0", count: 64))
    let output = await mac.keys(install: nil).shell().run(script, on: "patstudio")
    #expect(RemoteHostInstaller.fields(output)?.last { $0.key == "written" }?.value == "changed")
    #expect(try String(contentsOf: mac.keysFile, encoding: .utf8) == "ssh-ed25519 AAAAmine me@laptop\n")
}

@Test func anotherMacsAddressesComeTailscaleFirstThenTheOneThisMacReached() {
    let report = RemotePhonePairingReport(fields: [
        ("home", "/Users/pat"), ("user", "pat"),
        ("reached", "192.168.1.30 22"),
        ("localhost", "patstudio"),
        ("address", "192.168.1.30"), ("address", "169.254.3.4"), ("address", "100.124.84.74"), ("address", "10.0.0.5"),
        ("hostkey", hostKey + " root@patstudio"), ("hostkey", "ssh-rsa AAAAB3 root@patstudio"),
        ("gateway", "ready"),
        ("keys", "missing"),
    ])
    #expect(report.hosts == ["100.124.84.74", "192.168.1.30", "patstudio.local", "10.0.0.5"])
    #expect(report.hostKeyFingerprints == [hostFingerprint])
    #expect(report.reachedPort == 22)
    #expect(report.gateway == .ready)
    #expect(report.keys == .missing)

    let file = RemotePhonePairingReport(fields: [
        ("keys", "file"), ("keys_mode", "640"), ("keys_hash", "abc"), ("keys_text", Data("a\n".utf8).base64EncodedString()),
    ])
    #expect(file.keys == .file(text: "a\n", mode: "640", hash: "abc"))
    // A mode that is not octal digits is never passed to chmod.
    let odd = RemotePhonePairingReport(fields: [("keys", "file"), ("keys_mode", "6;rm"), ("keys_hash", "abc")])
    #expect(odd.keys == .file(text: nil, mode: "600", hash: "abc"))
}

private let pairingRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

/// With the real `cherry` (Scripts/build-host debug) installed there: the
/// pairing check finds its gateway, and the line it writes runs it as sshd
/// does (`$SHELL -c` of the forced command, through the link and the space
/// in "Application Support"), refusing a shell's command and answering the
/// phone's locator.
@Test(.enabled(if: pairingRealHostEnabled))
func MobilePairingRealHostLineRunsTheInstalledGateway() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cherry = try #require(
        HostedSessionClient.developmentTargetDirectories(environment: ProcessInfo.processInfo.environment, sourceRoot: repository)
            .map { $0.appendingPathComponent("debug/cherry") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) },
        "Build the Rust helpers first: Scripts/build-host debug"
    )
    let mac = try FakeOtherMac()
    let build = mac.home.appendingPathComponent("\(RemoteHostInstall.rootRelativePath)/20261105000000.real")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: build.appendingPathComponent("cherry"), withDestinationURL: cherry)
    let keys = mac.keys(install: "20261105000000.real")
    if case .failure(let problem) = await keys.describe(name: "patstudio") { Issue.record("not described: \(problem)") }
    try await keys.add(try #require(SSHPublicKeyLine(phoneKey)), name: "iPhone")

    let line = try String(contentsOf: mac.keysFile, encoding: .utf8)
    let options = try #require(AuthorizedPhoneKeys.options(of: line).options)
    let command = String(options.dropFirst("restrict,pty,command=\"".count).dropLast())
    func sshd(_ original: String) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": mac.home.path, "PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": original]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
    let refused = try sshd("id")
    #expect(refused.status == 1 && refused.errors.contains("reaches only Cherry's sessions"))
    let located = try sshd("'/bin/sh' '-c' 'exit 127' 'cherry-mobile' ''")
    #expect(located.status == 0)
    #expect(located.output.trimmingCharacters(in: .newlines) == mac.gatewayLink.path)
}

/// A Mac's card lists its phones only when it can be read without
/// connecting, and shows a removal at once even when it had to log in.
@Test @MainActor func aMacsCardListsItsPhonesOnlyWhileItsConnectionIsUp() async throws {
    let mac = try FakeOtherMac()
    try mac.install("20261105000000.new", runsGateway: true)
    try await mac.keys(install: "20261105000000.new").add(try #require(SSHPublicKeyLine(phoneKey)), name: "iPhone")
    let device = RemoteDevice(name: "patstudio", sshDestination: "patstudio")
    var isUp = false
    let model = DevicePhonesModel { _, connects in connects || isUp ? mac.keys(install: "20261105000000.new") : nil }
    func settle() async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if model.phones[device.id] != nil { return }
        }
    }

    model.reload([device])
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.phones[device.id] == nil)

    isUp = true
    model.reload([device])
    try await settle()
    #expect(model.phones[device.id]?.map(\.name) == ["iPhone"])

    isUp = false
    try await model.remove(try #require(model.phones[device.id]?.first), from: device)
    for _ in 0..<200 where model.phones[device.id]?.isEmpty != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.phones[device.id] == [])
    // A Mac no longer there is forgotten.
    model.reload([])
    #expect(model.phones.isEmpty)
}
