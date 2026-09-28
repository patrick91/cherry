import Foundation
import Testing
@testable import Cherry

// The installation id behind the owner of this Cherry's sessions on other
// Macs (docs/specs/remote-devices.md): kept in Application Support, made
// only by the copy that holds the instance lock, and new on another Mac.

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-installation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func theInstallationIdIsMadeOnceAndKeptInApplicationSupport() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = CherryInstallation(directory: directory, instanceLock: nil, machine: { "mac-a" })
    let id = try #require(installation.id())
    #expect(installation.id() == id)
    // Written atomically, alone in its folder, readable by this user only.
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == [CherryInstallation.fileName])
    let attributes = try FileManager.default.attributesOfItem(atPath: installation.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: installation.fileURL)) as? [String: Any]
    #expect(saved?["id"] as? String == id.uuidString)
    #expect(saved?["machine"] as? String == "mac-a")
    // Another process reading the same folder on the same Mac agrees.
    #expect(CherryInstallation(directory: directory, instanceLock: nil, machine: { "mac-a" }).id() == id)
    // Nothing in the app's defaults.
    #expect(UserDefaults.standard.string(forKey: "devices.installationID") == nil)
}

@Test func aCopyOfTheFolderOnAnotherMacIsAnotherInstallation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try #require(CherryInstallation(directory: directory, instanceLock: nil, machine: { "mac-a" }).id())
    // Migration Assistant brought the folder to mac-b: a new id there, kept.
    let migrated = CherryInstallation(directory: directory, instanceLock: nil, machine: { "mac-b" })
    let second = try #require(migrated.id())
    #expect(second != first)
    #expect(migrated.id() == second)
    // A Mac that cannot tell its hardware keeps what is there.
    #expect(CherryInstallation(directory: directory, instanceLock: nil, machine: { nil }).id() == second)
    // This Mac's own hash is a digest, never the hardware UUID itself.
    if let hash = CherryInstallation.thisMacHash {
        #expect(hash.count == 64 && hash.allSatisfy(\.isHexDigit))
    }
}

@Test func onlyTheCopyHoldingTheInstanceLockMakesTheId() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockFile = directory.appendingPathComponent("instance.lock")
    let holder = AppInstanceLock(fileURL: lockFile, applicationSupportName: "CherryTests")
    let other = AppInstanceLock(fileURL: lockFile, applicationSupportName: "CherryTests", quittingHolderWait: 0)
    #expect(holder.state == .held)
    #expect(other.state == .heldElsewhere(pid: getpid()))
    defer { holder.release() }

    // The second copy makes nothing while there is no id.
    let second = CherryInstallation(directory: directory, instanceLock: other, machine: { "mac-a" })
    #expect(second.id() == nil)
    #expect(!FileManager.default.fileExists(atPath: second.fileURL.path))
    // The holder makes it; the second copy then reads the same one.
    let id = try #require(CherryInstallation(directory: directory, instanceLock: holder, machine: { "mac-a" }).id())
    #expect(second.id() == id)
    // On another Mac the second copy does not replace it; the holder does.
    #expect(CherryInstallation(directory: directory, instanceLock: other, machine: { "mac-b" }).id() == nil)
    #expect(CherryInstallation(directory: directory, instanceLock: holder, machine: { "mac-b" }).id() != id)
}
