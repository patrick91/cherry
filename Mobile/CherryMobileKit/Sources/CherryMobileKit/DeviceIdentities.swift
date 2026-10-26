import Crypto
import Foundation
import NIOSSH
#if canImport(Security)
import Security
#endif

/// A device identity that can sign SSH logins: what `SSHMacConnector`
/// needs of `DeviceIdentity`.
public protocol SSHSigningIdentity: DeviceIdentity {
    func signingKey() throws -> Curve25519.Signing.PrivateKey
}

extension SSHSigningIdentity {
    public func publicKey() throws -> String {
        SSHKeys.authorizedKeysLine(for: try signingKey())
    }

    /// Names this device's terminals to the Mac's host (`cherry attach
    /// --client-id mobile-<id>`), so a dropped connection's attachment is
    /// replaced, not doubled: the first 16 hex digits of the SHA-256 of its
    /// public key.
    public func deviceID() throws -> String {
        SSHKeys.deviceID(for: try signingKey().publicKey)
    }
}

/// This device's Ed25519 key, kept in the Keychain (this device only,
/// readable after its first unlock), made on first use.
public struct KeychainDeviceIdentity: SSHSigningIdentity {
    public let service: String
    static let account = "ssh-ed25519"

    public init(service: String = "dev.patrick.cherry.mobile.ssh-key") {
        self.service = service
    }

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        #if canImport(Security)
        if let stored = try read() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
        }
        let key = Curve25519.Signing.PrivateKey()
        try store(key.rawRepresentation)
        return key
        #else
        throw MacConnectionError.failed("This platform has no Keychain.")
        #endif
    }

    #if canImport(Security)
    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        #if os(macOS)
        // Never the login keychain: the iOS-style keychain, as on the phone.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func read() throws -> Data? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw MacConnectionError.failed("Couldn't read this device's SSH key from the Keychain (\(status)).")
        }
    }

    private func store(_ key: Data) throws {
        var add = query
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MacConnectionError.failed("Couldn't save this device's SSH key in the Keychain (\(status)).")
        }
    }
    #endif
}

/// A key that lives only in memory: for tests and previews.
public struct InMemoryDeviceIdentity: SSHSigningIdentity {
    private let rawKey: Data

    public init(privateKey: Curve25519.Signing.PrivateKey = .init()) {
        rawKey = privateKey.rawRepresentation
    }

    public init(rawRepresentation: Data) throws {
        rawKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation).rawRepresentation
    }

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    }
}

/// OpenSSH's spellings of keys.
public enum SSHKeys {
    /// `ssh-ed25519 <base64> cherry-ios`, the line for `authorized_keys`
    /// of `key`'s public key.
    public static func authorizedKeysLine(for key: Curve25519.Signing.PrivateKey, comment: String = "cherry-ios") -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " " + comment
    }

    /// OpenSSH's fingerprint of a public key (`ssh-keygen -l -E sha256`):
    /// `SHA256:` and the unpadded base64 of the SHA-256 of its wire form.
    public static func fingerprint(of key: NIOSSHPublicKey) -> String {
        fingerprint(ofOpenSSHLine: String(openSSHPublicKey: key)) ?? "SHA256:?"
    }

    /// The fingerprint of a `<type> <base64> [comment]` line; nil when it
    /// is not one.
    public static func fingerprint(ofOpenSSHLine line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func deviceID(for key: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
