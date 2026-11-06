import Crypto
import Foundation
import Network

/// The pairing code a Mac's Cherry shows in Settings › Devices › Pair
/// iPhone… (docs/specs/mobile-pairing.md): how to reach the Mac over SSH,
/// the fingerprints of its host keys, and where to send this device's key
/// with a proof of the one-time code.
///
/// Version 1 pairs with the Mac that shows the code: its listener and SSH
/// are at the same addresses. Version 2 pairs with another of the user's
/// Macs (that Mac's card in Settings › Devices): the listener is at
/// `listenerHosts` (the Mac showing the code), SSH at `hosts`.
public struct PairingOffer: Equatable, Sendable {
    /// Version 1's, and the listener's in either version.
    public static let version = 1
    public static let otherMacVersion = 2
    public static let scheme = "cherry-mobile"

    public var name: String
    public var user: String
    /// Where the Mac may be reached, best first.
    public var hosts: [String]
    public var sshPort: Int
    public var hostKeyFingerprints: [String]
    public var pairingPort: UInt16
    public var code: Data
    /// Where the listener is when the Mac is another one (version 2's
    /// `via`): the addresses of the Mac showing the code. Empty in version 1.
    public var listenerHosts: [String]

    /// Whether the code pairs with a Mac other than the one showing it.
    public var isForAnotherMac: Bool { !listenerHosts.isEmpty }

    public init(
        name: String, user: String, hosts: [String], sshPort: Int = 22, hostKeyFingerprints: [String],
        pairingPort: UInt16, code: Data, listenerHosts: [String] = []
    ) {
        self.name = name
        self.user = user
        self.hosts = hosts
        self.sshPort = sshPort
        self.hostKeyFingerprints = hostKeyFingerprints
        self.pairingPort = pairingPort
        self.code = code
        self.listenerHosts = listenerHosts
    }

    /// The offer of `cherry-mobile://pair?v=1&…` (or `v=2&…&via=…`), nil for
    /// any other URL.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        let version = value("v").flatMap(Int.init)
        let listenerHosts = values("via")
        guard version == Self.version && listenerHosts.isEmpty || version == Self.otherMacVersion && !listenerHosts.isEmpty,
              let name = value("name"), let user = value("user"),
              let sshPort = value("ssh").flatMap(Int.init), let port = value("port").flatMap(UInt16.init),
              let code = value("code").flatMap(Self.data(base64URL:)), code.count >= 16, !values("host").isEmpty
        else { return nil }
        self.init(
            name: name, user: user, hosts: values("host"), sshPort: sshPort,
            hostKeyFingerprints: values("fp"), pairingPort: port, code: code, listenerHosts: listenerHosts
        )
    }

    /// The HMAC-SHA256 of `message` under the code, in hex: what proves
    /// this device read it.
    public func proof(of message: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: code))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

public enum PairingError: Error, Equatable, LocalizedError {
    /// No address of the code reached the Mac's Cherry.
    case unreachable(mac: String)
    /// No address reached the Cherry of the Mac showing a code for
    /// another Mac.
    case codeUnreachable
    /// No address of another Mac's code took an SSH connection.
    case sshUnreachable(mac: String)
    case declined(mac: String)
    /// The code was used, or is no longer shown.
    case used
    /// The Mac is asking about another phone.
    case busy(mac: String)
    /// The Mac allowed this device but could not add its key.
    case notAdded(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let mac):
            "Couldn't reach \(mac). Your iPhone needs to be on the same network as the Mac, or both on Tailscale; if the Mac asked whether Cherry may accept incoming connections, allow it."
        case .codeUnreachable:
            "Couldn't reach the Mac showing the code. Your iPhone needs to be on the same network as that Mac, or both on Tailscale; if it asked whether Cherry may accept incoming connections, allow it."
        case .sshUnreachable(let mac):
            "Couldn't reach \(mac) over SSH. Your iPhone needs to be on the same network as \(mac), or both on Tailscale, with Remote Login on there."
        case .declined(let mac): "\(mac) didn't allow this iPhone."
        case .used: "This code was used or is no longer shown. Show a new one on the Mac."
        case .busy(let mac): "\(mac) is asking about another iPhone. Answer it, then scan again."
        case .notAdded(let message): message
        case .failed(let message): message
        }
    }
}

/// Pairing with a Mac: finds which of its addresses reaches its Cherry,
/// sends this device's key, and waits for the Mac's answer.
public enum MacPairing {
    /// The first of the listener's hosts (`offer.hosts`, or its
    /// `listenerHosts` for another Mac), in its order, whose Cherry answers
    /// `/hello` within `timeout`; once one answered, the ones before it get
    /// `grace` more (a Tailscale address that does not answer would hold
    /// the LAN's up for its whole timeout).
    public static func reachableHost(of offer: PairingOffer, timeout: Duration = .seconds(4), grace: Duration = .seconds(1)) async -> String? {
        let path = "/hello?proof=\(offer.proof(of: "hello"))"
        return await firstAnswering(offer.isForAnotherMac ? offer.listenerHosts : offer.hosts, grace: grace) { host in
            let response = try? await PairingHTTP.send(host: host, port: offer.pairingPort, method: "GET", path: path, timeout: timeout)
            return response?.status == 200
        }
    }

    /// The first of another Mac's `offer.hosts`, in its order, that takes
    /// a TCP connection on its SSH port within `timeout` (with `grace`, as
    /// `reachableHost`).
    public static func reachableSSHHost(of offer: PairingOffer, timeout: Duration = .seconds(4), grace: Duration = .seconds(1)) async -> String? {
        await firstAnswering(offer.hosts, grace: grace) { host in
            await PairingHTTP.connects(host: host, port: UInt16(clamping: offer.sshPort), timeout: timeout)
        }
    }

    /// The first of `hosts` for which `answers` is true, in their order:
    /// all are asked at once, and once one answered, those before it get
    /// `grace` more.
    static func firstAnswering(_ hosts: [String], grace: Duration, _ answers: @escaping @Sendable (String) async -> Bool) async -> String? {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask { (index, await answers(host)) }
            }
            var finished: Set<Int> = []
            var best: Int?
            // A finished host's index and whether it answered; -1 when the
            // grace ends.
            for await (index, answered) in group {
                if index < 0 { break }
                finished.insert(index)
                if answered {
                    if best == nil {
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return (-1, false)
                        }
                    }
                    best = min(best ?? index, index)
                }
                if let best, (0..<best).allSatisfy(finished.contains) { break }
            }
            group.cancelAll()
            return best.map { hosts[$0] }
        }
    }

    /// Sends `publicKey` (an OpenSSH line) and `deviceName` to the Mac of
    /// `offer`, and waits for it to allow them (`reached` is called with
    /// the listener's address meanwhile): the Mac to save, at the address
    /// that answered (for another Mac, the first of its addresses that
    /// takes an SSH connection, found before the key is sent), with the
    /// code's host keys to accept on its first connect.
    public static func pair(
        _ offer: PairingOffer,
        publicKey: String,
        deviceName: String,
        decisionTimeout: Duration = .seconds(240),
        reached: @Sendable (String) async -> Void = { _ in }
    ) async throws -> MacEndpoint {
        guard let host = await reachableHost(of: offer) else {
            throw offer.isForAnotherMac ? PairingError.codeUnreachable : PairingError.unreachable(mac: offer.name)
        }
        var sshHost = host
        if offer.isForAnotherMac {
            guard let found = await reachableSSHHost(of: offer) else { throw PairingError.sshUnreachable(mac: offer.name) }
            sshHost = found
        }
        await reached(host)
        let body = try JSONSerialization.data(withJSONObject: [
            "v": PairingOffer.version,
            "key": publicKey,
            "name": deviceName,
            "proof": offer.proof(of: "pair\n\(publicKey)\n\(deviceName)"),
        ])
        let response: PairingHTTP.Response
        do {
            response = try await PairingHTTP.send(host: host, port: offer.pairingPort, method: "POST", path: "/pair", body: body, timeout: decisionTimeout)
        } catch {
            throw PairingError.failed("Lost \(offer.name) while it was asked about this iPhone (\(error.localizedDescription)).")
        }
        switch response.status {
        case 200:
            return MacEndpoint(
                name: response.fields["name"] ?? offer.name,
                host: sshHost,
                port: offer.sshPort,
                user: response.fields["user"] ?? offer.user,
                pairedHostKeyFingerprints: offer.hostKeyFingerprints.isEmpty ? nil : offer.hostKeyFingerprints
            )
        case 403: throw PairingError.declined(mac: offer.name)
        case 409: throw PairingError.busy(mac: offer.name)
        case 410: throw PairingError.used
        case 500: throw PairingError.notAdded(response.fields["message"] ?? "\(offer.name) couldn't add this iPhone's key.")
        default: throw PairingError.failed("\(offer.name) refused the pairing (\(response.fields["error"] ?? "HTTP \(response.status)")).")
        }
    }
}

/// Plain HTTP/1.1 over Network.framework, one request per connection: the
/// Mac's pairing listener is on the local network or the tailnet, which App
/// Transport Security would refuse to `URLSession`.
enum PairingHTTP {
    struct Response: Sendable {
        var status: Int
        /// The JSON body's fields as text.
        var fields: [String: String]
    }

    struct Failure: Error, LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    static func send(host: String, port: UInt16, method: String, path: String, body: Data? = nil, timeout: Duration) async throws -> Response {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw Failure(reason: "no port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        let data = Data((request + "\r\n").utf8) + (body ?? Data())
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await exchange(data, over: connection) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure(reason: "timed out")
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            return try await group.next()!
        }
    }

    private static func exchange(_ request: Data, over connection: NWConnection) async throws -> Response {
        try await ready(connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        var received = Data()
        while true {
            let (chunk, isComplete) = try await receive(connection)
            received.append(chunk)
            if isComplete || received.count > 64 * 1024 { break }
        }
        return try parse(received)
    }

    /// Whether `host` takes a TCP connection on `port` within `timeout`.
    static func connects(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        defer { connection.cancel() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await ready(connection)) != nil }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            return await group.next() ?? false
        }
    }

    private static func ready(_ connection: NWConnection) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete || data == nil))
                }
            }
        }
    }

    static func parse(_ data: Data) throws -> Response {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { throw Failure(reason: "no answer") }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let status = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        guard let status else { throw Failure(reason: "not HTTP") }
        let json = (try? JSONSerialization.jsonObject(with: data[end.upperBound...])) as? [String: Any] ?? [:]
        return Response(status: status, fields: json.mapValues { "\($0)" })
    }
}

/// A flag that only its first claimer gets.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
