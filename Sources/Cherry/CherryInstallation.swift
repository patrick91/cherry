import CryptoKit
import Foundation
import IOKit

/// This installation of Cherry on this Mac: an id made once and kept in the
/// app identity's Application Support folder (`installation.json`, next to
/// where the device list lives, docs/specs/remote-devices.md), so the
/// sessions it creates on other Macs keep one owner across launches
/// (`PersistentHostSessions.remoteOwner`).
///
/// The file also records a hash of this Mac's hardware UUID
/// (`IOPlatformUUID`): a copy of the folder on another Mac (Migration
/// Assistant, a restored backup) is another installation, and makes its own
/// id instead of claiming the first Mac's sessions on shared devices.
///
/// Only the copy of the app that holds the instance lock (`AppInstanceLock`)
/// creates or replaces the id; it writes it atomically. Another copy reads
/// what is there, and has none when nothing valid is (it owns no sessions
/// anyway), so two copies never end up with different ids.
struct CherryInstallation: Sendable {
    static let fileName = "installation.json"

    /// The identity's Application Support folder.
    let directory: URL
    /// Nil: this process may write (tests).
    let instanceLock: AppInstanceLock?
    /// A stable hash of this Mac's hardware identity; nil when it cannot
    /// say (the id is then kept whatever Mac reads it).
    let machine: @Sendable () -> String?

    static let shared = CherryInstallation(
        directory: AppInstanceLock.defaultFileURL().deletingLastPathComponent(),
        instanceLock: .shared,
        machine: { CherryInstallation.thisMacHash }
    )

    private struct Record: Codable {
        var id: UUID
        var machine: String?
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

    /// The installation's id, made (and saved) when there is none for this
    /// Mac yet and this copy holds the instance lock; nil otherwise, or when
    /// it could not be saved.
    func id() -> UUID? {
        let machine = machine()
        if let record = read(), record.machine == nil || machine == nil || record.machine == machine {
            return record.id
        }
        guard instanceLock?.isHeld ?? true else { return nil }
        let record = Record(id: UUID(), machine: machine)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(record)
            // Atomic: a reader sees the old file or the new one, never part.
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            SessionLog.error("could not save the installation id at \(fileURL.path): \(error.localizedDescription)")
            return nil
        }
        return record.id
    }

    private func read() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// SHA-256 of this Mac's `IOPlatformUUID` (never the UUID itself).
    static let thisMacHash: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !value.isEmpty
        else { return nil }
        return hash(value)
    }()

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
