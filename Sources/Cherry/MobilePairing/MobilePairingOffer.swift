import CryptoKit
import Darwin
import Foundation
import SystemConfiguration

/// What the QR code of Settings › Devices › Pair iPhone… carries
/// (docs/specs/mobile-pairing.md): how Cherry for iOS reaches this Mac over
/// SSH (its addresses, best first, the user and the port), the fingerprints
/// of its SSH host keys, which the phone accepts on its first connect and no
/// others, and where it sends its key (`MobilePairingListener`'s port) with
/// what proves it read this code: an HMAC under the one-time code, which
/// never travels.
struct MobilePairingOffer: Equatable, Sendable {
    static let version = 1
    static let scheme = "cherry-mobile"

    /// This Mac's name ("Patbook").
    var name: String
    var user: String
    /// Where the phone may reach it: Tailscale addresses, its `.local` name,
    /// then LAN addresses. The phone tries them all and keeps the first of
    /// these that answers.
    var hosts: [String]
    var sshPort: Int
    /// `SHA256:…`, as `ssh-keygen -l` prints them.
    var hostKeyFingerprints: [String]
    var pairingPort: UInt16
    /// The one-time code, 16 random bytes.
    var code: Data

    /// `cherry-mobile://pair?v=1&name=…&user=…&ssh=22&port=…&code=…&host=…&fp=…`:
    /// the iPhone's camera opens it in Cherry for iOS. The code is base64url;
    /// a fingerprint's `+` is escaped, as some parsers read it as a space.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "ssh", value: String(sshPort)),
            URLQueryItem(name: "port", value: String(pairingPort)),
            URLQueryItem(name: "code", value: Self.base64URL(code)),
        ] + hosts.map { URLQueryItem(name: "host", value: $0) }
            + hostKeyFingerprints.map { URLQueryItem(name: "fp", value: $0) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    init(name: String, user: String, hosts: [String], sshPort: Int = 22, hostKeyFingerprints: [String], pairingPort: UInt16, code: Data) {
        self.name = name
        self.user = user
        self.hosts = hosts
        self.sshPort = sshPort
        self.hostKeyFingerprints = hostKeyFingerprints
        self.pairingPort = pairingPort
        self.code = code
    }

    /// The offer `url` reads, as the phone reads it.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard value("v") == String(Self.version), let name = value("name"), let user = value("user"),
              let sshPort = value("ssh").flatMap(Int.init), let port = value("port").flatMap(UInt16.init),
              let code = value("code").flatMap(Self.data(base64URL:)), !values("host").isEmpty
        else { return nil }
        self.init(
            name: name, user: user, hosts: values("host"), sshPort: sshPort,
            hostKeyFingerprints: values("fp"), pairingPort: port, code: code
        )
    }

    /// What proves `message` came from someone who read the code: its
    /// HMAC-SHA256 under the code, in hex.
    static func proof(of message: String, code: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: code))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `proof` is `message`'s under `code`, compared in constant time.
    static func isProof(_ proof: String, of message: String, code: Data) -> Bool {
        guard let mac = Data(hex: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(message.utf8), using: SymmetricKey(data: code))
    }

    /// What the phone proves to find which address reaches the listener.
    static let helloMessage = "hello"

    /// What the phone proves with its key: the key and its name.
    static func pairMessage(key: String, name: String) -> String {
        "pair\n\(key)\n\(name)"
    }

    static func newCode() -> Data {
        Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// This Mac as an offer describes it, read from the system.
enum MobilePairingMac {
    /// Its name as Sharing settings has it, else the host's.
    static func name() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// Its addresses, best first: Tailscale's (100.64.0.0/10, stable and
    /// reachable away from home), its Bonjour name, then other IPv4
    /// addresses of interfaces that are up (no loopback or link-local).
    static func hosts() -> [String] {
        var tailscale: [String] = []
        var lan: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0, let first = interfaces {
            defer { freeifaddrs(interfaces) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let interface = pointer.pointee
                let flags = Int32(interface.ifa_flags)
                guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                      flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
                else { continue }
                let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let octets = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
                let text = octets.map(String.init).joined(separator: ".")
                if octets[0] == 169, octets[1] == 254 { continue }
                if octets[0] == 100, (64...127).contains(octets[1]) {
                    tailscale.append(text)
                } else {
                    lan.append(text)
                }
            }
        }
        let bonjour = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { ["\($0).local"] } ?? []
        return unique(tailscale + bonjour + lan)
    }

    /// The fingerprints of the SSH host keys the phone can be shown:
    /// Ed25519 and ECDSA (it cannot use RSA host keys).
    static func hostKeyFingerprints(directory: URL = URL(fileURLWithPath: "/etc/ssh")) -> [String] {
        ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub"].compactMap { file in
            (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
                .flatMap(SSHPublicKeyLine.init(_:))?.fingerprint
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// An OpenSSH public key line (`ssh-ed25519 AAAA… comment`): its type, its
/// key as base64, checked to decode and to name the same type inside.
struct SSHPublicKeyLine: Equatable, Sendable {
    var type: String
    var base64: String

    /// The types a phone's key may have: Cherry for iOS makes Ed25519 keys.
    static let phoneKeyTypes: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256"]

    init?(_ line: String) {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, fields[0].hasPrefix("ssh-") || fields[0].hasPrefix("ecdsa-"),
              let blob = Data(base64Encoded: fields[1]), blob.count > 4
        else { return nil }
        let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, blob.count >= 4 + length,
              String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8) == fields[0]
        else { return nil }
        type = fields[0]
        base64 = fields[1]
    }

    /// `SHA256:…` as `ssh-keygen -l` prints it.
    var fingerprint: String {
        let digest = SHA256.hash(data: Data(base64Encoded: base64) ?? Data())
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    var line: String {
        "\(type) \(base64)"
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
