import CryptoKit
import Foundation

/// The SHA-256 of `text` (its UTF-8) in lowercase hex: all 32 bytes, or
/// its first `bytes` bytes.
public func sha256Hex(_ text: String, bytes: Int = 32) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(bytes).map { String(format: "%02x", $0) }.joined()
}
