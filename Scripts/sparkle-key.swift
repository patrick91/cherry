// Sparkle EdDSA (Ed25519) key checks for the release scripts (docs/releasing.md), with
// CryptoKit, so no Sparkle tool or keychain is needed:
//
//   xcrun swift Scripts/sparkle-key.swift derive                       < base64 private key
//   xcrun swift Scripts/sparkle-key.swift verify PUBLIC FILE SIGNATURE
//
// derive reads Sparkle's private key (base64) on standard input and prints its public key
// (base64, as SUPublicEDKey holds it). It takes the 32-byte seed generate_keys stores since
// Sparkle 2, or the legacy 96-byte key: the 64-byte orlp private key, then the public key
// (Sparkle's common_cli/Secret.swift). It never prints the private key, not even in an
// error. Scripts/release-preflight and Scripts/release-setup check the key against
// Packaging/release.conf with it.
//
// verify exits 0 when SIGNATURE (base64) is FILE's Ed25519 signature under PUBLIC (base64),
// 1 when it is not, and 2 on malformed input. `cherry-release appcast item` checks each
// signature against the zip's own SUPublicEDKey with it.
import CryptoKit
import Foundation

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("sparkle-key: \(message)\n".utf8))
    exit(status)
}

func decodeBase64(_ text: String, what: String) -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = Data(base64Encoded: trimmed) else {
        fail("\(what) is not base64")
    }
    return data
}

func derive() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: input, encoding: .utf8) else {
        fail("the private key on standard input is not UTF-8 text")
    }
    let secret = decodeBase64(text, what: "the private key on standard input")
    let publicKey: Data
    switch secret.count {
    case 32:
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else {
            fail("the private key is not a valid Ed25519 seed")
        }
        publicKey = key.publicKey.rawRepresentation
    case 96:
        publicKey = secret.suffix(32)
    default:
        fail("the private key is \(secret.count) bytes; a Sparkle key is 32 bytes (or 96, its legacy format)")
    }
    print(publicKey.base64EncodedString())
    exit(0)
}

func verify(publicKey publicText: String, file path: String, signature signatureText: String) -> Never {
    let publicData = decodeBase64(publicText, what: "the public key")
    guard publicData.count == 32, let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else {
        fail("the public key is \(publicData.count) bytes, not a 32-byte Ed25519 key")
    }
    let signature = decodeBase64(signatureText, what: "the signature")
    guard signature.count == 64 else {
        fail("the signature is \(signature.count) bytes, not 64")
    }
    let contents: Data
    do {
        contents = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    } catch {
        fail("cannot read \(path): \(error.localizedDescription)")
    }
    guard publicKey.isValidSignature(signature, for: contents) else {
        fail("the signature does not match \(path) under this public key", status: 1)
    }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "derive" where arguments.count == 1:
    derive()
case "verify" where arguments.count == 4:
    verify(publicKey: arguments[1], file: arguments[2], signature: arguments[3])
default:
    fail("usage: sparkle-key.swift derive < KEY | sparkle-key.swift verify PUBLIC FILE SIGNATURE")
}
