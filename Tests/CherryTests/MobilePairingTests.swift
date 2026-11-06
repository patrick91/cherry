import Foundation
import Testing
@testable import Cherry

// Pair iPhone… (MobilePairing/): the offer its QR code carries, the phone
// keys Cherry adds to authorized_keys, the listener the phone sends its key
// to, and the sheet's model. Each test uses a temporary home and a listener
// on 127.0.0.1 of its own; nothing reads the real ~/.ssh or /etc/ssh.

private let phoneKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINsyIgyIP7VL9sFdYMZoAQs+q3BI8YDzU5dnjxVy1Jkz"
private let phoneFingerprint = "SHA256:w4eVI3TcBZZFR+dpMlGRFoDeYOl8S0DD9BtCkbOTUBU"
private let otherKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFVwL5R0QIeHf1+iQZMDHAZQ5XTTWtK251fPmVPqRROmH1wkgnqAIfTuyx1EIup7FiYrJt9XDz02tVnGtrd2ZCI="

private func pairingHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-pairing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// The `cherry` a phone's key runs, as the app's link is named.
private let gateway = "/Users/me/Library/Application Support/Cherry/bin/cherry"
private let limited = #"restrict,pty,command="'/Users/me/Library/Application Support/Cherry/bin/cherry' host mobile-gateway""#

private func phoneKeys(home: URL, gateway: String? = gateway) -> AuthorizedPhoneKeys {
    .standard(home: home, gateway: { gateway })
}

@Test func theOfferURLCarriesWhatThePhoneNeedsAndReadsBack() throws {
    let offer = MobilePairingOffer(
        name: "Patbook", user: "patrick", hosts: ["100.101.1.2", "Patbook.local", "192.168.1.20"],
        hostKeyFingerprints: [phoneFingerprint], pairingPort: 53123, code: Data(repeating: 0xFB, count: 16)
    )
    let url = offer.url.absoluteString
    #expect(url.hasPrefix("cherry-mobile://pair?v=1&"))
    // A fingerprint's + is escaped, the code is base64url.
    #expect(!url.contains("+"))
    #expect(url.contains("code=-_v7-_v7-_v7-_v7-_v7-w"))
    #expect(MobilePairingOffer(url: offer.url) == offer)
    #expect(MobilePairingOffer(url: URL(string: "cherry-mobile://pair?v=2&name=x")!) == nil)
}

@Test func anotherMacsOfferIsVersionTwoWithThisMacsAddressesForTheListener() throws {
    let offer = MobilePairingOffer(
        name: "patstudio", user: "pat", hosts: ["100.124.84.74", "patstudio.local"], sshPort: 2222,
        hostKeyFingerprints: [phoneFingerprint], pairingPort: 53123, code: Data(repeating: 0xFB, count: 16),
        listenerHosts: ["100.101.1.2", "Patbook.local"]
    )
    #expect(offer.offerVersion == 2)
    let url = offer.url.absoluteString
    #expect(url.hasPrefix("cherry-mobile://pair?v=2&"))
    #expect(url.contains("&host=100.124.84.74&host=patstudio.local&via=100.101.1.2&via=Patbook.local&"))
    #expect(url.contains("&ssh=2222&"))
    #expect(MobilePairingOffer(url: offer.url) == offer)
    // A version says whether the listener is elsewhere: never one without
    // the other.
    let v2WithoutVia = url.replacingOccurrences(of: "&via=100.101.1.2&via=Patbook.local", with: "")
    #expect(MobilePairingOffer(url: try #require(URL(string: v2WithoutVia))) == nil)
    let v1WithVia = url.replacingOccurrences(of: "v=2&", with: "v=1&")
    #expect(MobilePairingOffer(url: try #require(URL(string: v1WithVia))) == nil)
}

@Test func aProofIsTheMessagesHMACUnderTheCode() {
    let code = MobilePairingOffer.newCode()
    let proof = MobilePairingOffer.proof(of: "hello", code: code)
    #expect(proof.count == 64)
    #expect(MobilePairingOffer.isProof(proof, of: "hello", code: code))
    #expect(!MobilePairingOffer.isProof(proof, of: "hello!", code: code))
    #expect(!MobilePairingOffer.isProof(proof, of: "hello", code: MobilePairingOffer.newCode()))
    #expect(!MobilePairingOffer.isProof("zz", of: "hello", code: code))
}

@Test func publicKeyLinesAreCheckedAndFingerprintedAsOpenSSHDoes() throws {
    let key = try #require(SSHPublicKeyLine(phoneKey + " test"))
    #expect(key.type == "ssh-ed25519")
    #expect(key.fingerprint == phoneFingerprint)
    #expect(SSHPublicKeyLine(otherKey)?.fingerprint == "SHA256:9AvBDX/szDYr+uQKFx/fZRYIpdw72Qng8feINQKwgyI")
    // The type outside must be the type inside.
    #expect(SSHPublicKeyLine(phoneKey.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa")) == nil)
    #expect(SSHPublicKeyLine("ssh-ed25519 not-base64") == nil)
    #expect(SSHPublicKeyLine("command=\"x\" " + phoneKey) == nil)
}

@Test func theHostKeyFingerprintsAreEd25519AndECDSAs() throws {
    let directory = try pairingHome()
    try (phoneKey + " root@mac\n").write(to: directory.appendingPathComponent("ssh_host_ed25519_key.pub"), atomically: true, encoding: .utf8)
    try (otherKey + "\n").write(to: directory.appendingPathComponent("ssh_host_ecdsa_key.pub"), atomically: true, encoding: .utf8)
    try "ssh-rsa AAAA\n".write(to: directory.appendingPathComponent("ssh_host_rsa_key.pub"), atomically: true, encoding: .utf8)
    #expect(MobilePairingMac.hostKeyFingerprints(directory: directory) == [
        phoneFingerprint, "SHA256:9AvBDX/szDYr+uQKFx/fZRYIpdw72Qng8feINQKwgyI",
    ])
}

@Test func phoneKeysAreAddedLimitedListedAndRemovedLeavingOtherLinesAlone() throws {
    let home = try pairingHome()
    let keys = phoneKeys(home: home)
    let key = try #require(SSHPublicKeyLine(phoneKey))
    // ~/.ssh is made 0700, the file 0600; the line runs only the gateway.
    try keys.add(key, name: "Patrick's iPhone\nsecond line")
    let ssh = home.appendingPathComponent(".ssh")
    #expect(try FileManager.default.attributesOfItem(atPath: ssh.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: keys.file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try String(contentsOf: keys.file, encoding: .utf8) == "\(limited) \(phoneKey) cherry-mobile Patrick's iPhone second line\n")
    #expect(keys.phones().map(\.name) == ["Patrick's iPhone second line"])
    #expect(keys.phones().map(\.isLimited) == [true])

    // Someone else's lines stay, blank and comment lines too, and pairing
    // the key again renames its line rather than adding another.
    let mine = "# mine\n\n\(otherKey) me@laptop"
    try (mine + "\n" + String(contentsOf: keys.file, encoding: .utf8)).write(to: keys.file, atomically: true, encoding: .utf8)
    try keys.add(key, name: "Again")
    #expect(keys.phones().map(\.name) == ["Again"])
    #expect(try String(contentsOf: keys.file, encoding: .utf8) == "\(mine)\n\(limited) \(phoneKey) cherry-mobile Again\n")
    let phone = try #require(keys.phones().first)
    #expect(phone.key.fingerprint == phoneFingerprint)
    try keys.remove(phone)
    #expect(keys.phones().isEmpty)
    #expect(try String(contentsOf: keys.file, encoding: .utf8) == mine + "\n")
}

@Test func aPhonePairedBeforeKeysWereLimitedIsListedAsFullAccessThenLimited() throws {
    let home = try pairingHome()
    let keys = phoneKeys(home: home)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    try "\(otherKey) me@laptop\n\(phoneKey) cherry-mobile Old iPhone\n".write(to: keys.file, atomically: true, encoding: .utf8)
    let phone = try #require(keys.phones().first)
    #expect(phone.name == "Old iPhone")
    #expect(!phone.isLimited)
    try keys.limit(phone)
    #expect(try String(contentsOf: keys.file, encoding: .utf8) == "\(otherKey) me@laptop\n\(limited) \(phoneKey) cherry-mobile Old iPhone\n")
    #expect(keys.phones() == [AuthorizedPhoneKeys.Phone(name: "Old iPhone", key: phone.key, isLimited: true)])
}

@Test func aKeyTheUserAddedIsNotAPhoneAndIsLeftAsItIs() throws {
    let home = try pairingHome()
    let keys = phoneKeys(home: home)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    let text = "\(phoneKey) my phone, by hand\n"
    try text.write(to: keys.file, atomically: true, encoding: .utf8)
    try keys.add(try #require(SSHPublicKeyLine(phoneKey)), name: "iPhone")
    #expect(keys.phones().isEmpty)
    #expect(try String(contentsOf: keys.file, encoding: .utf8) == text)
}

@Test func nothingIsAddedWithoutAGatewayToRunOrToAFileThatIsNotText() throws {
    let home = try pairingHome()
    let key = try #require(SSHPublicKeyLine(phoneKey))
    for path in [nil, "relative/cherry", "/Users/o'brien/cherry", "/tmp/a\"b/cherry"] {
        #expect(throws: AuthorizedPhoneKeys.Failure.noGateway) {
            try phoneKeys(home: home, gateway: path).add(key, name: "iPhone")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: phoneKeys(home: home).file.path))

    let keys = phoneKeys(home: home)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    // "René" in Latin-1: rewriting it as text would lose every line.
    var latin1 = Data("\(otherKey) Ren".utf8)
    latin1.append(0xE9)
    latin1.append(contentsOf: "\n".utf8)
    try latin1.write(to: keys.file)
    #expect(throws: AuthorizedPhoneKeys.Failure.self) { try keys.add(key, name: "iPhone") }
    #expect(try Data(contentsOf: keys.file) == latin1)
}

@Test func optionsAreReadUpToTheKeyTypeQuotesAndAll() {
    let (options, rest) = AuthorizedPhoneKeys.options(of: "\(limited) \(phoneKey) cherry-mobile iPhone")
    #expect(options == limited)
    #expect(rest == "\(phoneKey) cherry-mobile iPhone")
    let (none, plain) = AuthorizedPhoneKeys.options(of: "\(phoneKey) me")
    #expect(none == nil)
    #expect(plain == "\(phoneKey) me")
    #expect(AuthorizedPhoneKeys.options(of: #"command="echo \"a b\"",no-pty ssh-ed25519 AAAA x"#).options == #"command="echo \"a b\"",no-pty"#)
}

@Test func aLinkedAuthorizedKeysIsLeftAloneWithTheLineToAdd() throws {
    let home = try pairingHome()
    let managed = home.appendingPathComponent("managed_keys")
    try "ssh-ed25519 AAAA mine\n".write(to: managed, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    let keys = phoneKeys(home: home)
    try FileManager.default.createSymbolicLink(at: keys.file, withDestinationURL: managed)
    let key = try #require(SSHPublicKeyLine(phoneKey))
    #expect(throws: AuthorizedPhoneKeys.Failure.linked(destination: managed.path, line: "\(limited) \(phoneKey) cherry-mobile iPhone")) {
        try keys.add(key, name: "iPhone")
    }
    #expect(try String(contentsOf: managed, encoding: .utf8) == "ssh-ed25519 AAAA mine\n")
}

@Test func httpRequestsAreReadWholeAndWithinTheirLimit() throws {
    let request = "POST /pair?x=1 HTTP/1.1\r\nHost: mac\r\nContent-Length: 4\r\n\r\nbody"
    #expect(try HTTPRequest(parsing: Data(request.dropLast(2).utf8), limit: 1024) == nil)
    let read = try #require(try HTTPRequest(parsing: Data(request.utf8), limit: 1024))
    #expect(read.method == "POST")
    #expect(read.path == "/pair")
    #expect(read.query == ["x": "1"])
    #expect(read.body == Data("body".utf8))
    #expect(throws: HTTPRequest.Malformed.self) {
        try HTTPRequest(parsing: Data("POST /pair HTTP/1.1\r\nContent-Length: 4096\r\n\r\n".utf8), limit: 1024)
    }
    #expect(throws: HTTPRequest.Malformed.self) {
        try HTTPRequest(parsing: Data("nonsense\r\n\r\n".utf8), limit: 1024)
    }
}

/// The listener's answer: its status and its JSON's fields as text.
private struct PhoneAnswer: Sendable {
    var status: Int
    var fields: [String: String]
}

/// What the phone does: proves the code over HTTP to 127.0.0.1.
private struct Phone: Sendable {
    let port: UInt16
    let code: Data

    func hello(proof: String? = nil) async throws -> PhoneAnswer {
        let proof = proof ?? MobilePairingOffer.proof(of: MobilePairingOffer.helloMessage, code: code)
        return try await send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hello?proof=\(proof)")!))
    }

    func pair(key: String = phoneKey, name: String = "iPhone", proofCode: Data? = nil) async throws -> PhoneAnswer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "v": 1, "key": key, "name": name,
            "proof": MobilePairingOffer.proof(of: MobilePairingOffer.pairMessage(key: key, name: name), code: proofCode ?? code),
        ])
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> PhoneAnswer {
        var request = request
        request.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return PhoneAnswer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, fields: json.mapValues { "\($0)" })
    }
}

@Test func theListenerAnswersOnlyTheCodeAndPairsOnce() async throws {
    let code = MobilePairingOffer.newCode()
    let decisions = OSAllocatedUnfairLockBox(false)
    let listener = MobilePairingListener(code: code, macName: "Patbook", user: "patrick") { request in
        #expect(request.key.fingerprint == phoneFingerprint)
        #expect(request.name == "iPhone")
        return decisions.claim() ? .declined : .added
    }
    let port = try await listener.start()
    defer { listener.stop() }
    let phone = Phone(port: port, code: code)

    #expect(try await phone.hello(proof: "00").status == 404)
    let hello = try await phone.hello()
    #expect(hello.status == 200)
    #expect(hello.fields["name"] == "Patbook")

    #expect(try await phone.pair(proofCode: MobilePairingOffer.newCode()).status == 401)
    #expect(try await phone.pair(key: "ssh-rsa AAAA", name: "iPhone").status == 400)
    let declined = try await phone.pair()
    #expect(declined.status == 403)
    #expect(declined.fields["error"] == "declined")
    // The first answer spent the code.
    #expect(try await phone.pair().status == 410)
}

@Test func tenWrongProofsSpendTheCode() async throws {
    let code = MobilePairingOffer.newCode()
    let listener = MobilePairingListener(code: code, macName: "Patbook", user: "patrick") { _ in .added }
    let port = try await listener.start()
    defer { listener.stop() }
    let phone = Phone(port: port, code: code)
    for _ in 0..<MobilePairingListener.maximumFailedProofs {
        #expect(try await phone.pair(proofCode: MobilePairingOffer.newCode()).status == 401)
    }
    #expect(try await phone.pair().status == 410)
}

@MainActor
private func pairingModel(home: URL, remoteLogin: Bool = true) -> MobilePairingModel {
    MobilePairingModel(
        keys: phoneKeys(home: home),
        environment: MobilePairingEnvironment(
            macName: { "Patbook" },
            user: { "patrick" },
            hosts: { ["127.0.0.1"] },
            hostKeyFingerprints: { [phoneFingerprint] },
            remoteLoginIsOn: { remoteLogin },
            lifetime: .seconds(600)
        )
    )
}

@Test @MainActor func theSheetSaysWhenRemoteLoginIsOff() async throws {
    let model = pairingModel(home: try pairingHome(), remoteLogin: false)
    await model.start()
    #expect(model.state == .remoteLoginOff)
}

@Test @MainActor func aPhoneThatSendsItsKeyIsAskedAboutThenAdded() async throws {
    let home = try pairingHome()
    let model = pairingModel(home: home)
    var paired = 0
    model.onPaired = { paired += 1 }
    await model.start()
    guard case .waiting(let offer) = model.state else {
        Issue.record("no offer: \(model.state)")
        return
    }
    #expect(offer.hosts == ["127.0.0.1"])
    #expect(offer.hostKeyFingerprints == [phoneFingerprint])

    let phone = Phone(port: offer.pairingPort, code: offer.code)
    let answer = Task { try await phone.pair(name: "Patrick's iPhone") }
    for _ in 0..<200 where model.state == .waiting(offer) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.state == .asking(.init(phone: "Patrick's iPhone", fingerprint: phoneFingerprint)))
    await model.allow()
    let answered = try await answer.value
    #expect(answered.status == 200)
    #expect(answered.fields["user"] == "patrick")
    #expect(model.state == .paired("Patrick's iPhone"))
    #expect(paired == 1)
    #expect(phoneKeys(home: home).phones().map(\.name) == ["Patrick's iPhone"])
}

@Test @MainActor func closingTheSheetDeclinesTheAskingPhone() async throws {
    let model = pairingModel(home: try pairingHome())
    await model.start()
    guard case .waiting(let offer) = model.state else {
        Issue.record("no offer: \(model.state)")
        return
    }
    let answer = Task { try await Phone(port: offer.pairingPort, code: offer.code).pair() }
    for _ in 0..<200 where model.state == .waiting(offer) {
        try await Task.sleep(for: .milliseconds(10))
    }
    model.stop()
    let answered = try await answer.value
    #expect(answered.status == 403)
}

/// What a fake other Mac's pairing records: the keys its target was asked
/// to add.
private final class AddedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [(key: String, name: String)] = []
    var all: [(key: String, name: String)] { lock.withLock { added } }
    func record(_ key: SSHPublicKeyLine, _ name: String) { lock.withLock { added.append((key.line, name)) } }
}

@MainActor
private func anotherMacsModel(added: AddedKeys, failure: (any Error)? = nil) -> MobilePairingModel {
    MobilePairingModel(
        target: MobilePairingTarget(
            displayName: "patstudio",
            isThisMac: false,
            describe: {
                .success(MobilePairingMacDescription(
                    name: "patstudio", user: "pat", hosts: ["100.124.84.74"], sshPort: 2222, hostKeyFingerprints: [phoneFingerprint]
                ))
            },
            addKey: { key, name in
                if let failure { throw failure }
                added.record(key, name)
            }
        ),
        listenerHosts: { ["127.0.0.1"] }
    )
}

@Test @MainActor func aPhonePairsWithAnotherMacThroughThisMacsListener() async throws {
    let added = AddedKeys()
    let model = anotherMacsModel(added: added)
    await model.start()
    guard case .waiting(let offer) = model.state else {
        Issue.record("no offer: \(model.state)")
        return
    }
    // The phone reaches the listener here and SSH there.
    #expect(offer.offerVersion == 2)
    #expect(offer.listenerHosts == ["127.0.0.1"])
    #expect(offer.hosts == ["100.124.84.74"])
    #expect(offer.sshPort == 2222)

    let phone = Phone(port: offer.pairingPort, code: offer.code)
    let answer = Task { try await phone.pair(name: "Patrick's iPhone") }
    for _ in 0..<200 where model.state == .waiting(offer) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.state == .asking(.init(phone: "Patrick's iPhone", fingerprint: phoneFingerprint)))
    #expect(model.describedMac?.user == "pat")
    await model.allow()
    let answered = try await answer.value
    #expect(answered.status == 200)
    #expect(answered.fields["user"] == "pat")
    #expect(answered.fields["name"] == "patstudio")
    #expect(model.state == .paired("Patrick's iPhone"))
    #expect(added.all.map(\.key) == [phoneKey] && added.all.map(\.name) == ["Patrick's iPhone"])
}

@Test @MainActor func anotherMacThatCannotTakeTheKeyShowsTheLineAndTellsThePhone() async throws {
    let line = "restrict,pty,command=\"'/Users/pat/Library/Application Support/cherry-host/cherry' host mobile-gateway\" \(phoneKey) cherry-mobile Patrick's iPhone"
    let model = anotherMacsModel(added: AddedKeys(), failure: RemotePhoneKeys.Failure.linked(machine: "patstudio", destination: "/nix/store/keys", line: line))
    await model.start()
    guard case .waiting(let offer) = model.state else {
        Issue.record("no offer: \(model.state)")
        return
    }
    let answer = Task { try await Phone(port: offer.pairingPort, code: offer.code).pair(name: "Patrick's iPhone") }
    for _ in 0..<200 where model.state == .waiting(offer) {
        try await Task.sleep(for: .milliseconds(10))
    }
    await model.allow()
    #expect(try await answer.value.status == 500)
    guard case .failed(let message, let shownLine) = model.state else {
        Issue.record("not failed: \(model.state)")
        return
    }
    #expect(message.contains("on patstudio is a link to /nix/store/keys"))
    #expect(shownLine == line)
}

@Test @MainActor func anotherMacThatCannotBePairedWithSaysWhyAndShowsNoCode() async throws {
    let model = MobilePairingModel(
        target: MobilePairingTarget(
            displayName: "patstudio", isThisMac: false,
            describe: { .failure(.unavailable(RemotePhoneKeys.noGatewayMessage(machine: "patstudio"))) },
            addKey: { _, _ in Issue.record("a key was added") }
        )
    )
    await model.start()
    #expect(model.state == .failed(RemotePhoneKeys.noGatewayMessage(machine: "patstudio"), line: nil))
}

