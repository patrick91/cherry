import Foundation
import Network
import Testing
@testable import CherryMobileKit

// Pairing with a Mac's code (MacPairing.swift): reading the code, proving
// it, finding the address that reaches the Mac and sending this device's
// key, against a stand-in for the Mac's listener on 127.0.0.1.

private let code = Data(0..<16)
private let phoneKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINsyIgyIP7VL9sFdYMZoAQs+q3BI8YDzU5dnjxVy1Jkz cherry-ios"

@Test func aPairingCodeIsReadFromTheMacsURL() throws {
    let url = try #require(URL(string:
        "cherry-mobile://pair?v=1&name=Patbook&user=patrick&ssh=22&port=53123&code=AAECAwQFBgcICQoLDA0ODw"
        + "&host=100.101.1.2&host=Patbook.local&fp=SHA256:w4eVI3TcBZZFR%2BdpMlGRFoDeYOl8S0DD9BtCkbOTUBU"))
    let offer = try #require(PairingOffer(url: url))
    #expect(offer == PairingOffer(
        name: "Patbook", user: "patrick", hosts: ["100.101.1.2", "Patbook.local"],
        hostKeyFingerprints: ["SHA256:w4eVI3TcBZZFR+dpMlGRFoDeYOl8S0DD9BtCkbOTUBU"], pairingPort: 53123, code: code
    ))
    #expect(PairingOffer(url: URL(string: "cherry-mobile://pair?v=2&name=x")!) == nil)
    #expect(PairingOffer(url: URL(string: "https://example.com/pair?v=1")!) == nil)
}

@Test func aProofIsTheHMACOfTheMessageUnderTheCode() {
    let offer = PairingOffer(name: "Mac", user: "me", hosts: ["h"], hostKeyFingerprints: [], pairingPort: 1, code: code)
    // Python's hmac.new(bytes(range(16)), …, sha256).hexdigest().
    #expect(offer.proof(of: "hello") == "9163eb0d568a28e3994c969c9d5dfef181ccbbb0a8742b30464d4d200cbcb4f4")
    #expect(offer.proof(of: "pair\n\(phoneKey)\niPhone") == "2c597b6a0973cbbd3582ef7a724174b98811a10a3b227ae5e2e7cd005d2f1437")
}

@Test func anAnswerIsReadForItsStatusAndFields() throws {
    let answer = try PairingHTTP.parse(Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 40\r\n\r\n{\"error\":\"not_added\",\"message\":\"Nope\"}".utf8))
    #expect(answer.status == 500)
    #expect(answer.fields == ["error": "not_added", "message": "Nope"])
}

/// A stand-in for the Mac's pairing listener: answers `/hello` with a valid
/// proof and `/pair` with `pairStatus`, keeping what was sent.
private final class FakeMac: @unchecked Sendable {
    let listener: NWListener
    let pairStatus: Int
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    init(pairStatus: Int) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.pairStatus = pairStatus
    }

    var pairBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            receive(connection, Data())
        }
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, once.claim() { continuation.resume(returning: listener.port!.rawValue) }
                if case .failed(let error) = state, once.claim() { continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, _, error in
            guard error == nil, let data else { return connection.cancel() }
            let buffer = buffer + data
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return receive(connection, buffer) }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else { return receive(connection, buffer) }
            respond(to: head, body: Data(body), on: connection)
        }
    }

    private func respond(to head: String, body: Data, on connection: NWConnection) {
        let offer = PairingOffer(name: "Mac", user: "me", hosts: [], hostKeyFingerprints: [], pairingPort: 1, code: code)
        var status = 404
        var json: [String: Any] = ["error": "not_found"]
        if head.hasPrefix("GET /hello?proof=\(offer.proof(of: "hello")) ") {
            (status, json) = (200, ["v": 1, "name": "Patbook"])
        } else if head.hasPrefix("POST /pair "), let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            lock.lock()
            bodies.append(fields)
            lock.unlock()
            status = pairStatus
            json = status == 200 ? ["v": 1, "name": "Patbook", "user": "patrick"] : ["error": status == 403 ? "declined" : "used"]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = Data("HTTP/1.1 \(status) X\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8) + data
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

@Test func pairingSendsTheKeyToTheFirstAddressThatAnswersAndSavesTheMac() async throws {
    let mac = try FakeMac(pairStatus: 200)
    let port = try await mac.start()
    defer { mac.listener.cancel() }
    // 192.0.2.1 (TEST-NET-1) never answers; 127.0.0.1 does.
    let offer = PairingOffer(
        name: "Patbook", user: "patrick", hosts: ["192.0.2.1", "127.0.0.1"], sshPort: 2222,
        hostKeyFingerprints: ["SHA256:abc"], pairingPort: port, code: code
    )
    // The answer from 127.0.0.1 waits a grace, not 192.0.2.1's timeout.
    let clock = ContinuousClock()
    let started = clock.now
    #expect(await MacPairing.reachableHost(of: offer, timeout: .seconds(20), grace: .milliseconds(300)) == "127.0.0.1")
    #expect(clock.now - started < .seconds(5))
    let endpoint = try await MacPairing.pair(offer, publicKey: phoneKey, deviceName: "iPhone")
    #expect(endpoint.name == "Patbook")
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port == 2222)
    #expect(endpoint.user == "patrick")
    #expect(endpoint.hostKeyFingerprint == nil)
    #expect(endpoint.pairedHostKeyFingerprints == ["SHA256:abc"])
    let sent = try #require(mac.pairBodies.first)
    #expect(sent["key"] as? String == phoneKey)
    #expect(sent["name"] as? String == "iPhone")
    #expect(sent["proof"] as? String == offer.proof(of: "pair\n\(phoneKey)\niPhone"))
}

@Test func aMacThatDeclinesOrIsUnreachableSaysSo() async throws {
    let mac = try FakeMac(pairStatus: 403)
    let port = try await mac.start()
    defer { mac.listener.cancel() }
    let offer = PairingOffer(name: "Patbook", user: "patrick", hosts: ["127.0.0.1"], hostKeyFingerprints: [], pairingPort: port, code: code)
    await #expect(throws: PairingError.declined(mac: "Patbook")) {
        try await MacPairing.pair(offer, publicKey: phoneKey, deviceName: "iPhone")
    }
    var wrongCode = offer
    wrongCode.code = Data(repeating: 7, count: 16)
    #expect(await MacPairing.reachableHost(of: wrongCode, timeout: .seconds(1)) == nil)
}
