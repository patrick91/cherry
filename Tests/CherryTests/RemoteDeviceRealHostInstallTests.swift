import CherryControl
import Darwin
import Foundation
import Testing
@testable import Cherry

// Installing this Cherry's cherry and cherry-host on another Mac
// (docs/specs/remote-devices.md, phase 2) end to end, against fake remote
// Macs (Scripts/fake-remote-mac: an ssh shim that runs the remote command
// here with the fake Mac's private HOME), so the real tar, xattr, codesign
// and helpers run, and nothing reaches ~/Library or the user's daemon. The
// helpers installed are the debug builds (Scripts/build-host debug), which
// are universal. Gated like the other real-host suites.
//
// RemoteDeviceRealHostInstallRunsTheRealCopyOverSSH also runs over a real
// sshd: Scripts/test-remote-mac-loopback sets CHERRY_TEST_LOOPBACK_SSH (its
// ssh, with a private config) and CHERRY_TEST_LOOPBACK_HOME (the private
// home its sshd gives the login) and runs it.

private let installRealHostEnabled = ProcessInfo.processInfo.environment["CHERRY_TEST_HOST_INTEGRATION"] == "1"

@MainActor
private func deviceStore(for mac: FakeRemoteMac, directory: URL) -> RemoteDeviceStore {
    RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: mac.hostStore,
        installationID: { mac.installationID },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        // Never the app's: the tests point the gateway at an install with
        // an override of the shared paths for their destination only.
        remoteHostPaths: HostedRemoteHostPaths(),
        makeHosting: { profile, installation in
            PersistentHostSessions.remote(
                profile: profile, installationID: installation,
                control: { mac.makeControl() },
                installationUnavailableReason: { nil },
                status: PersistentSessionsStatus(), instanceLock: nil, terminalColors: { nil }
            )
        }
    )
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cherry-rd-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A directory's entries, without dotfiles (`.installed`, `.used-by`).
private func entries(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

private func marker(_ build: URL, _ installation: UUID) -> URL {
    build.appendingPathComponent(".used-by/\(installation.uuidString.lowercased())")
}

/// Copies of the debug helpers in their own directory (to change them).
private func copiedHelpers(from binaries: URL) throws -> URL {
    let directory = try temporaryDirectory("helpers")
    for name in RemoteHostHelpers.names {
        try FileManager.default.copyItem(at: binaries.appendingPathComponent(name), to: directory.appendingPathComponent(name))
    }
    return directory
}

private func runTool(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A complete, good copy of `helpers` at `build` (as an install leaves it).
private func placeCopy(of helpers: RemoteHostHelpers, at build: URL) throws {
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    for name in RemoteHostHelpers.names {
        try FileManager.default.copyItem(at: helpers.directory.appendingPathComponent(name), to: build.appendingPathComponent(name))
    }
    // With Ghostty's resources, as the install places them.
    if let resources = helpers.resources {
        try FileManager.default.copyItem(at: resources.resourcesDirectory, to: build.appendingPathComponent("Ghostty"))
        try FileManager.default.copyItem(at: resources.terminfoDirectory, to: build.appendingPathComponent("terminfo"))
    }
}

/// No masters: every command logs in (through the shim).
private let noMasters = HostSSHMasterManager(configuration: .init(directory: { nil }))

// MARK: - Install & Add, then the gateway through the installed host

@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallAndAddRunsTheDevicesHostFromTheInstall() async throws {
    let mac = try FakeRemoteMac(name: "fresh", host: "none", startsDaemon: false)
    let directory = try temporaryDirectory("install")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let store = deviceStore(for: mac, directory: directory)
        let model = AddDeviceModel(
            store: store, aliases: [], shell: { mac.shell }, helpers: { .success(helpers) }, openInTerminal: { _ in }
        )
        model.destination = "fresh"
        await model.check()
        // Nothing there: Install & Add, and the first tab starts its host.
        let plan = try #require(model.installation?.plan)
        #expect(plan.daemon == .absent)
        #expect(plan.copyNeeded && !plan.isUpdate)
        #expect(model.primaryTitle == "Install & Add")
        #expect(model.checklist?.items.first { $0.id == "install" }?.status == .ok)
        #expect(model.canAdd)

        let device = try #require(await model.addInstallingIfNeeded(), "\(model.error ?? "")")
        let installed = mac.installRoot.appendingPathComponent(helpers.directoryName, isDirectory: true)
        #expect(device.remoteHostPath == "~/Library/Application Support/cherry-host/bin/\(helpers.directoryName)/cherry-host")
        #expect(device.installedBuild == helpers.build)
        // The fake Mac is this one: the copy runs as its architecture.
        #expect(device.installedArch == ProcessInfo.processInfo.machineHardwareName)
        // With Ghostty's terminfo and shell integration (phase 3).
        #expect(entries(installed) == ["Ghostty", "cherry", "cherry-host", "terminfo"])
        // Only the build's directory: no partial copy is left.
        #expect(entries(mac.installRoot) == [helpers.directoryName])
        // Marked as installed, and as used by this installation.
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".installed").path))
        #expect(FileManager.default.fileExists(atPath: marker(installed, mac.installationID).path))
        for name in RemoteHostHelpers.names {
            #expect(try RemoteHostHelpers.sha256(installed.appendingPathComponent(name)) == helpers.hashes[RemoteHostHelpers.names.firstIndex(of: name)!])
            let mode = try FileManager.default.attributesOfItem(atPath: installed.appendingPathComponent(name).path)[.posixPermissions] as? Int
            #expect(mode.map { $0 & 0o077 } == 0)
        }
        // The copy went as a tar stream into a partial directory, over ssh.
        #expect(mac.calls.contains { $0.contains("/usr/bin/tar -xf - -C") && $0.contains(".partial-") && $0.hasPrefix("-T -o ControlMaster=no") })

        // The device's tabs and control run that cherry-host's gateway,
        // which starts its daemon from the install.
        HostedRemoteHostPaths.shared.setOverride(device.remoteHostPath, for: "fresh")
        defer { HostedRemoteHostPaths.shared.setOverride(nil, for: "fresh") }
        let control = mac.makeControl()
        _ = try await control.list()
        #expect(mac.calls.contains { $0.contains("'Library/Application Support/cherry-host/bin/\(helpers.directoryName)/cherry-host' gateway") })
        let status = try mac.cliStatus()
        #expect(status.running)
        #expect(status.host?.executable?.hasPrefix(installed.path + "/") == true)

        // Update Session Host… with the same build there: nothing is copied.
        let copies = mac.calls.filter { $0.contains("tar -xf") }.count
        let update = UpdateDeviceHostModel(
            deviceID: device.id, store: store, shell: { mac.shell }, helpers: { .success(helpers) },
            masters: noMasters, reconnect: { _ in }
        )
        await update.check()
        let again = try #require(update.installation?.plan)
        #expect(!again.copyNeeded)
        #expect(update.primaryTitle == "Use It")
        #expect(again.daemon == .sameProtocol(build: helpers.build, newerBuild: false))
        // The check marks the build the device uses as used now.
        try FileManager.default.setAttributes(
            [.modificationDate: Date() - 20 * 86_400], ofItemAtPath: marker(installed, mac.installationID).path
        )
        await update.check()
        let marked = try FileManager.default.attributesOfItem(atPath: marker(installed, mac.installationID).path)[.modificationDate] as? Date
        #expect(marked.map { Date().timeIntervalSince($0) < 60 } == true)
        await update.install()
        let outcome = try #require(update.outcome, "\(update.error ?? "")")
        #expect(!outcome.copied && !outcome.handedOver && outcome.removed.isEmpty)
        #expect(outcome.placement == "existing")
        #expect(mac.calls.filter { $0.contains("tar -xf") }.count == copies)
        #expect(try mac.cliStatus().host?.pid == status.host?.pid)

        // A connection marks it too (the store's marker, over the shim).
        let other = UUID()
        _ = await mac.shell.run(RemoteHostInstaller.markScript(directoryName: helpers.directoryName, installationID: other), on: "fresh")
        #expect(FileManager.default.fileExists(atPath: marker(installed, other).path))

        // Its cherry-host gone: Reinstall, not "offline".
        let gone = RemoteHostInstall.remoteHostPath(directoryName: "gone")
        HostedRemoteHostPaths.shared.setOverride(gone, for: "fresh")
        let missing = mac.makeControl()
        var failure: HostedSessionError?
        do {
            _ = try await missing.list()
        } catch let error as HostedSessionError {
            failure = error
        }
        let error = try #require(failure)
        #expect(error.isRemoteHostMissing, "\(error)")
        guard case .hostMissing = RemoteDeviceConnectionState.failure(error) else {
            Issue.record("not hostMissing: \(RemoteDeviceConnectionState.failure(error))")
            await mac.tearDown()
            return
        }
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

// MARK: - Update Session Host… from an older build

@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostUpdateFromAnOlderBuildKeepsItsSessionsAndCollectsUnusedBuilds() async throws {
    // An older install of ours runs the daemon, with sessions.
    let mac = try FakeRemoteMac(name: "older", host: "old-build")
    let directory = try temporaryDirectory("update")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let old = FakeRemoteMac.oldBuild
        try await mac.waitFor("the old daemon") { (try? mac.cliStatus())?.running == true }
        let before = try mac.cliStatus()
        #expect(before.host?.build == old)
        let first = try mac.startSession(["/bin/sh", "-c", "sleep 600"])
        let second = try mac.startSession(["/bin/sh", "-c", "sleep 600"])
        try await mac.waitFor("both sessions") {
            (try mac.cliStatus().sessions ?? []).filter { $0.state == "running" }.count == 2
        }
        let sessionsBefore = try #require(try mac.cliStatus().sessions)
        #expect(sessionsBefore.allSatisfy { $0.holder_build == old })

        // Other builds: three installed this week (the two newest kept as
        // such, the third because it is younger than 7 days), older ones
        // another Mac's Cherry used lately (kept), used long ago or never
        // (removed), and a partial copy an install left.
        let fileManager = FileManager.default
        let now = Date()
        let day: TimeInterval = 86_400
        let anotherMac = UUID()
        func makeBuild(_ name: String, age: TimeInterval, usedAgo: TimeInterval? = nil) throws {
            let build = mac.installRoot.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: build.appendingPathComponent("cherry"))
            if let usedAgo {
                let used = marker(build, anotherMac)
                try fileManager.createDirectory(at: used.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: used)
                try fileManager.setAttributes([.modificationDate: now - usedAgo], ofItemAtPath: used.path)
            }
            try fileManager.setAttributes([.modificationDate: now - age], ofItemAtPath: build.path)
        }
        try fileManager.setAttributes([.modificationDate: now - 20 * day], ofItemAtPath: mac.installRoot.appendingPathComponent(old).path)
        try makeBuild("y1", age: 1 * day)
        try makeBuild("y2", age: 2 * day)
        try makeBuild("y3", age: 3 * day)
        try makeBuild("m1", age: 12 * day, usedAgo: 2 * day)
        try makeBuild("m0", age: 13 * day, usedAgo: 40 * day)
        try makeBuild("a9", age: 14 * day)
        try makeBuild("a0.partial-dead", age: 2 * 3_600)

        let store = deviceStore(for: mac, directory: directory)
        let device = try store.add(
            name: "Older", sshDestination: "older",
            remoteHostPath: RemoteHostInstall.remoteHostPath(directoryName: old)
        )
        store.update(device.id) { $0.installedBuild = old }

        let update = UpdateDeviceHostModel(
            deviceID: device.id, store: store, shell: { mac.shell }, helpers: { .success(helpers) },
            masters: noMasters, reconnect: { _ in }
        )
        await update.check()
        let plan = try #require(update.installation?.plan, "\(update.error ?? "")")
        #expect(plan.daemon == .sameProtocol(build: old, newerBuild: false))
        #expect(plan.isUpdate && plan.copyNeeded)
        #expect(update.primaryTitle == "Update")
        await update.install()
        let outcome = try #require(update.outcome, "\(update.error ?? "")")

        // The daemon moved to the new build (`cherry restart`); the
        // sessions' holders kept running and registered with it.
        #expect(outcome.handedOver)
        let after = try mac.cliStatus()
        let installed = mac.installRoot.appendingPathComponent(helpers.directoryName).path
        #expect(after.host?.executable?.hasPrefix(installed + "/") == true)
        #expect(after.host?.pid != before.host?.pid)
        let sessionsAfter = try #require(after.sessions)
        for id in [first, second] {
            let session = try #require(sessionsAfter.first { $0.id == id })
            #expect(session.state == "running")
            #expect(session.holder_build == old)
        }
        // The other Mac's own Cherry sees them running as before.
        let theirs = try await mac.sessions(mac.makeTheirControl()).filter { [first, second].contains($0.id) }
        #expect(theirs.count == 2 && theirs.allSatisfy(\.isRunning))

        // Kept: the new build, the two installed before it, one younger than
        // 7 days, one another Mac used lately, and the old one whose holders
        // still run (from it, and reporting its build); the rest went.
        #expect(Set(outcome.removed) == ["m0", "a9", "a0.partial-dead"])
        #expect(entries(mac.installRoot) == [old, "m1", "y1", "y2", "y3", helpers.directoryName].sorted())
        #expect(outcome.kept[old] == [.process, .holderBuild])

        // The device uses it from now on.
        let updated = try #require(store.device(id: device.id))
        #expect(updated.remoteHostPath == RemoteHostInstall.remoteHostPath(directoryName: helpers.directoryName))
        #expect(updated.installedBuild == helpers.build)
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

// MARK: - Refused installs

@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallIsRefusedForANewerHostAMissingArchitectureOrABadSignature() async throws {
    // A newer Cherry's session host runs there.
    let mac = try FakeRemoteMac(name: "newer", host: "newer", startsDaemon: false)
    let directory = try temporaryDirectory("refused")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let store = deviceStore(for: mac, directory: directory)
        let newer = AddDeviceModel(store: store, aliases: [], shell: { mac.shell }, helpers: { .success(helpers) }, openInTerminal: { _ in })
        newer.destination = "newer"
        await newer.check()
        guard case .blocked(let reason, false)? = newer.installation else {
            Issue.record("not refused: \(String(describing: newer.installation))")
            await mac.tearDown()
            return
        }
        #expect(reason.contains("protocol 99") && reason.contains("Update Cherry on this Mac"))
        #expect(!newer.canAdd)
        #expect(await newer.addInstallingIfNeeded() == nil)
        #expect(!FileManager.default.fileExists(atPath: mac.installRoot.path))

        // A Mac of an architecture these helpers lack.
        let thinDirectory = try temporaryDirectory("thin")
        defer { try? FileManager.default.removeItem(at: thinDirectory) }
        let hostArchitecture = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "x86_64" : "arm64"
        let otherArchitecture = hostArchitecture == "arm64" ? "x86_64" : "arm64"
        for name in RemoteHostHelpers.names {
            let source = mac.binaries.appendingPathComponent(name)
            let target = thinDirectory.appendingPathComponent(name)
            if MachOArchitectures.read(source)?.count ?? 0 > 1 {
                let lipo = Process()
                lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
                lipo.arguments = [source.path, "-thin", hostArchitecture, "-output", target.path]
                try lipo.run()
                lipo.waitUntilExit()
                #expect(lipo.terminationStatus == 0)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        let thin = try RemoteHostHelpers.load(directory: thinDirectory)
        #expect(thin.architectures == [hostArchitecture])
        try mac.addMac("intel", host: "link")
        try mac.set("arch", otherArchitecture, on: "intel")
        let intel = AddDeviceModel(store: store, aliases: [], shell: { mac.shell }, helpers: { .success(thin) }, openInTerminal: { _ in })
        intel.destination = "intel"
        await intel.check()
        guard case .blocked(let archReason, true)? = intel.installation else {
            Issue.record("not refused with a plain Add: \(String(describing: intel.installation))")
            await mac.tearDown()
            return
        }
        #expect(archReason.contains("built for \(hostArchitecture) only"))
        // Its own cherry-host (on its PATH) speaks this protocol: plain Add.
        #expect(intel.canAdd && intel.primaryTitle == "Add")
        let added = try #require(await intel.addInstallingIfNeeded())
        #expect(added.installedBuild == nil)
        #expect(!FileManager.default.fileExists(
            atPath: mac.root.appendingPathComponent("hosts/intel/home/\(RemoteHostInstall.rootRelativePath)").path
        ))

        // macOS there does not accept the copy's signature: a copy of the
        // helpers whose cherry-host lost its signature (the check runs
        // /usr/bin/codesign itself, which no stand-in replaces).
        let unsignedDirectory = try copiedHelpers(from: mac.binaries)
        defer { try? FileManager.default.removeItem(at: unsignedDirectory) }
        #expect(try runTool("/usr/bin/codesign", ["--remove-signature", unsignedDirectory.appendingPathComponent("cherry-host").path]) == 0)
        var unsignedHelpers = helpers
        unsignedHelpers.directory = unsignedDirectory
        unsignedHelpers.hashes = try RemoteHostHelpers.names.map { try RemoteHostHelpers.sha256(unsignedDirectory.appendingPathComponent($0)) }
        try mac.addMac("unsigned", host: "none")
        let unsigned = AddDeviceModel(
            store: store, aliases: [], shell: { mac.shell }, helpers: { .success(unsignedHelpers) }, openInTerminal: { _ in }
        )
        unsigned.destination = "unsigned"
        await unsigned.check()
        #expect(unsigned.primaryTitle == "Install & Add")
        #expect(await unsigned.addInstallingIfNeeded() == nil)
        #expect(unsigned.error?.contains("does not accept the copy's signature") == true)
        #expect(unsigned.error?.contains("not signed") == true, "\(unsigned.error ?? "")")
        // Nothing is left in place, not even the partial copy.
        #expect(entries(mac.root.appendingPathComponent("hosts/unsigned/home/\(RemoteHostInstall.rootRelativePath)")).isEmpty)
        #expect(store.devices.map(\.sshDestination) == ["intel"])
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

// MARK: - The copy over SSH (also over a real sshd)

@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallRunsTheRealCopyOverSSH() async throws {
    let environment = ProcessInfo.processInfo.environment
    let loopbackSSH = environment["CHERRY_TEST_LOOPBACK_SSH"]?.nilIfEmpty
    let mac: FakeRemoteMac? = loopbackSSH == nil ? try FakeRemoteMac(name: "copy", host: "none", startsDaemon: false) : nil
    do {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binaries = try #require(
            HostedSessionClient.developmentTargetDirectories(environment: environment, sourceRoot: repository)
                .map { $0.appendingPathComponent("debug") }
                .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("cherry-host").path) }
        )
        // The copy it sends has an extended attribute the tar stream
        // carries (quarantine), which the check there must clear.
        let source = try copiedHelpers(from: binaries)
        defer { try? FileManager.default.removeItem(at: source) }
        for name in RemoteHostHelpers.names {
            #expect(try runTool("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Test;", source.appendingPathComponent(name).path]) == 0)
            #expect(getxattr(source.appendingPathComponent(name).path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        }
        // tar carries it: a copy through tar alone keeps it.
        let roundTrip = try temporaryDirectory("tar")
        defer { try? FileManager.default.removeItem(at: roundTrip) }
        #expect(try runTool("/bin/sh", ["-c", "/usr/bin/tar -cf - -C \"$0\" cherry | /usr/bin/tar -xf - -C \"$1\"", source.path, roundTrip.path]) == 0)
        #expect(getxattr(roundTrip.appendingPathComponent("cherry").path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        // Read from the originals (running a quarantined copy here would
        // wait on Gatekeeper); sent from the copies, whose files are the same.
        var helpers = try RemoteHostHelpers.load(directory: binaries)
        helpers.directory = source
        #expect(try RemoteHostHelpers.names.map { try RemoteHostHelpers.sha256(source.appendingPathComponent($0)) } == helpers.hashes)
        let destination: String
        let home: URL
        let shell: RemoteDeviceShell
        if let loopbackSSH, let loopbackHome = environment["CHERRY_TEST_LOOPBACK_HOME"]?.nilIfEmpty {
            destination = environment["CHERRY_TEST_LOOPBACK_DESTINATION"]?.nilIfEmpty ?? "loopback"
            home = URL(fileURLWithPath: loopbackHome, isDirectory: true)
            shell = RemoteDeviceShell(
                sshExecutable: loopbackSSH,
                environment: [
                    "PATH": URL(fileURLWithPath: loopbackSSH).deletingLastPathComponent().path + ":/usr/bin:/bin",
                    "HOME": FileManager.default.temporaryDirectory.path,
                ],
                timeout: 60
            )
        } else {
            let mac = try #require(mac)
            destination = "copy"
            home = mac.home
            shell = mac.shell
        }
        let root = home.appendingPathComponent(RemoteHostInstall.rootRelativePath, isDirectory: true)

        let probe = await RemoteDeviceProbe.run(destination: destination, remoteHostPath: nil, shell: shell)
        #expect(probe.sshFailure == nil, "\(String(describing: probe.sshFailure))")
        let plan = try #require(RemoteHostInstall.decide(probe: probe, helpers: .success(helpers), machine: destination).plan)
        #expect(plan.copyNeeded)
        let installer = RemoteHostInstaller(shell: shell, helpers: helpers)
        let outcome = try await installer.install(plan, on: destination, machine: destination)
        #expect(outcome.copied)
        let installed = root.appendingPathComponent(outcome.directoryName, isDirectory: true)
        // What arrived is what was sent, signed, without extended
        // attributes, and runs.
        for (index, name) in RemoteHostHelpers.names.enumerated() {
            let file = installed.appendingPathComponent(name)
            #expect(try RemoteHostHelpers.sha256(file) == helpers.hashes[index])
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: installed.path)) ?? []).allSatisfy { !$0.hasPrefix("._") })
            #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        }
        // Cleared there: it runs here without Gatekeeper.
        for name in RemoteHostHelpers.names {
            #expect(getxattr(installed.appendingPathComponent(name).path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        }
        let copied = try RemoteHostHelpers.load(directory: installed)
        #expect(copied.version.build == helpers.build && copied.version.protocol == helpers.version.protocol)
        #expect(entries(root) == [outcome.directoryName])

        // Checked again: the same files are there, so nothing is copied.
        let second = await RemoteDeviceProbe.run(destination: destination, remoteHostPath: nil, shell: shell)
        #expect(second.installedBuilds == [RemoteInstalledBuild(name: outcome.directoryName, hashes: helpers.hashes, resourcesHash: helpers.resourcesHash)])
        let again = try #require(RemoteHostInstall.decide(probe: second, helpers: .success(helpers), machine: destination).plan)
        #expect(!again.copyNeeded)
        let skipped = try await installer.install(again, on: destination, machine: destination)
        #expect(!skipped.copied && skipped.remoteHostPath == outcome.remoteHostPath)
        await mac?.tearDown()
    } catch {
        await mac?.tearDown()
        throw error
    }
}

private extension ProcessInfo {
    /// `uname -m`.
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

// MARK: - A damaged or racing install

/// A directory of this build that is incomplete (only `cherry`, as an
/// interrupted older install could leave it): listed by the check, then
/// replaced by a checked copy, since nothing runs from it.
@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallRepairsADamagedBuildDirectory() async throws {
    let mac = try FakeRemoteMac(name: "damaged", host: "none", startsDaemon: false)
    let directory = try temporaryDirectory("damaged")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let build = mac.installRoot.appendingPathComponent(helpers.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: mac.binaries.appendingPathComponent("cherry"), to: build.appendingPathComponent("cherry"))

        let probe = await RemoteDeviceProbe.run(destination: "damaged", remoteHostPath: nil, shell: mac.shell)
        #expect(probe.installedBuilds == [RemoteInstalledBuild(name: helpers.directoryName, hashes: [helpers.hashes[0], "-"], resourcesHash: "-")])
        let plan = try #require(RemoteHostInstall.decide(probe: probe, helpers: .success(helpers), machine: "damaged").plan)
        #expect(plan.copyNeeded && plan.directoryName == helpers.directoryName)
        let outcome = try await RemoteHostInstaller(shell: mac.shell, helpers: helpers, installationID: mac.installationID)
            .install(plan, on: "damaged", machine: "damaged")
        #expect(outcome.placement == "replaced")
        #expect(outcome.directoryName == helpers.directoryName)
        for (index, name) in RemoteHostHelpers.names.enumerated() {
            #expect(try RemoteHostHelpers.sha256(build.appendingPathComponent(name)) == helpers.hashes[index])
        }
        // Nothing left aside or partial.
        #expect(entries(mac.installRoot) == [helpers.directoryName])
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

/// A damaged directory of this build that a process runs from stays; the
/// copy goes to `<build>-<hash>`, which the device then uses.
@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallLeavesADamagedBuildInUseAndUsesTheHashedDirectory() async throws {
    let mac = try FakeRemoteMac(name: "busy", host: "none", startsDaemon: false)
    let directory = try temporaryDirectory("busy")
    defer { try? FileManager.default.removeItem(at: directory) }
    var runner: Process?
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let build = mac.installRoot.appendingPathComponent(helpers.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho another build\n".utf8).write(to: build.appendingPathComponent("cherry"))
        try Data("#!/bin/sh\nsleep 600\n".utf8).write(to: build.appendingPathComponent("cherry-host"))
        for name in RemoteHostHelpers.names {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: build.appendingPathComponent(name).path)
        }
        // Something runs from it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [build.appendingPathComponent("cherry-host").path]
        try process.run()
        runner = process

        let probe = await RemoteDeviceProbe.run(destination: "busy", remoteHostPath: nil, shell: mac.shell)
        let plan = try #require(RemoteHostInstall.decide(probe: probe, helpers: .success(helpers), machine: "busy").plan)
        let outcome = try await RemoteHostInstaller(shell: mac.shell, helpers: helpers).install(plan, on: "busy", machine: "busy")
        let alternate = RemoteHostInstaller.alternateName(helpers.directoryName, hashes: helpers.hashes)
        #expect(outcome.directoryName == alternate)
        #expect(outcome.brokenKept == helpers.directoryName)
        #expect(outcome.remoteHostPath == RemoteHostInstall.remoteHostPath(directoryName: alternate))
        // The one in use is untouched.
        #expect(try String(contentsOf: build.appendingPathComponent("cherry"), encoding: .utf8).contains("another build"))
        for (index, name) in RemoteHostHelpers.names.enumerated() {
            #expect(try RemoteHostHelpers.sha256(mac.installRoot.appendingPathComponent("\(alternate)/\(name)")) == helpers.hashes[index])
        }
        #expect(entries(mac.installRoot) == [helpers.directoryName, alternate].sorted())
        // Checked again, the hashed one is used as it is.
        let again = await RemoteDeviceProbe.run(destination: "busy", remoteHostPath: nil, shell: mac.shell)
        let second = try #require(RemoteHostInstall.decide(probe: again, helpers: .success(helpers), machine: "busy").plan)
        #expect(!second.copyNeeded && second.directoryName == alternate)
        process.terminate()
        process.waitUntilExit()
        await mac.tearDown()
    } catch {
        runner?.terminate()
        await mac.tearDown()
        throw error
    }
}

/// Installs of the same build at once never nest one copy inside the
/// other: each renames its checked copy with rename(2), which fails when
/// the build is there; the others check that one and drop their own. A
/// partial copy an older installer nested inside is removed.
@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostConcurrentInstallsOfOneBuildNeverNest() async throws {
    let mac = try FakeRemoteMac(name: "race", host: "none", startsDaemon: false)
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        let probe = await RemoteDeviceProbe.run(destination: "race", remoteHostPath: nil, shell: mac.shell)
        let plan = try #require(RemoteHostInstall.decide(probe: probe, helpers: .success(helpers), machine: "race").plan)
        #expect(plan.copyNeeded)
        let installer = RemoteHostInstaller(shell: mac.shell, helpers: helpers)
        async let first = installer.install(plan, on: "race", machine: "race")
        async let second = installer.install(plan, on: "race", machine: "race")
        async let third = installer.install(plan, on: "race", machine: "race")
        let outcomes = try await [first, second, third]
        #expect(Set(outcomes.map(\.directoryName)) == [helpers.directoryName])
        #expect(outcomes.filter { $0.placement == "moved" }.count == 1)
        #expect(outcomes.filter { $0.placement == "existing" }.count == 2)
        let build = mac.installRoot.appendingPathComponent(helpers.directoryName, isDirectory: true)
        #expect(entries(build) == ["Ghostty", "cherry", "cherry-host", "terminfo"])
        #expect(entries(mac.installRoot) == [helpers.directoryName])

        // An older installer's copy nested inside the build: removed, and
        // the build (checked) used as it is.
        let nested = build.appendingPathComponent("\(helpers.directoryName).partial-old", isDirectory: true)
        try placeCopy(of: helpers, at: nested)
        let again = await RemoteDeviceProbe.run(destination: "race", remoteHostPath: nil, shell: mac.shell)
        let reuse = try #require(RemoteHostInstall.decide(probe: again, helpers: .success(helpers), machine: "race").plan)
        #expect(!reuse.copyNeeded)
        let outcome = try await installer.install(reuse, on: "race", machine: "race")
        #expect(outcome.placement == "existing")
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        #expect(entries(build) == ["Ghostty", "cherry", "cherry-host", "terminfo"])
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

// MARK: - The handover and the daemon found afterwards

/// The handover names the daemon it looked at: when another one runs by
/// the time it restarts, nothing is restarted.
@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostHandOverLeavesADaemonThatChangedMeanwhile() async throws {
    let mac = try FakeRemoteMac(name: "moving", host: "old-build")
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        try await mac.waitFor("the old daemon") { (try? mac.cliStatus())?.running == true }
        let status = try mac.cliStatus()
        let host = try #require(status.host)
        let build = mac.installRoot.appendingPathComponent(helpers.directoryName, isDirectory: true)
        try placeCopy(of: helpers, at: build)
        // Another pid, another executable, another build: each is refused.
        let executable = try #require(host.executable)
        let daemonBuild = try #require(host.build)
        for (pid, path, build) in [
            (try #require(host.pid) + 1, executable, daemonBuild),
            (try #require(host.pid), "/elsewhere/cherry-host", daemonBuild),
            (try #require(host.pid), executable, "20000101000000.other"),
        ] {
            let output = await mac.shell.run(
                RemoteHostInstaller.handOverScript(directoryName: helpers.directoryName, pid: pid, executable: path, build: build),
                on: "moving"
            )
            let report = RemoteHostInstaller.Report(fields: try #require(RemoteHostInstaller.fields(output)))
            #expect(report.restart == "changed", "\(report.restartOutput ?? "")")
            #expect(try mac.cliStatus().host?.pid == host.pid)
        }
        // The one it names: restarted.
        let output = await mac.shell.run(
            RemoteHostInstaller.handOverScript(directoryName: helpers.directoryName, pid: try #require(host.pid), executable: executable, build: daemonBuild),
            on: "moving"
        )
        let report = RemoteHostInstaller.Report(fields: try #require(RemoteHostInstaller.fields(output)))
        #expect(report.restart == "ok", "\(report.restartOutput ?? "")")
        try await mac.waitFor("the new daemon") { (try? mac.cliStatus())?.host?.executable?.hasPrefix(build.path + "/") == true }
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}

/// The check found no cherry-host to ask, so it took the daemon for absent;
/// once the new build is in place it asks, and says what it found.
@Test(.enabled(if: installRealHostEnabled))
@MainActor func RemoteDeviceRealHostInstallAsksTheDaemonAgainOnceItsBuildIsThere() async throws {
    let mac = try FakeRemoteMac(name: "hidden", host: "none")
    do {
        let helpers = try RemoteHostHelpers.load(directory: mac.binaries)
        try await mac.waitFor("its daemon") { (try? mac.cliStatus())?.running == true }
        let probe = await RemoteDeviceProbe.run(destination: "hidden", remoteHostPath: nil, shell: mac.shell)
        #expect(probe.hostStatus == nil)
        let plan = try #require(RemoteHostInstall.decide(probe: probe, helpers: .success(helpers), machine: "hidden").plan)
        #expect(plan.daemon == .absent)
        let outcome = try await RemoteHostInstaller(shell: mac.shell, helpers: helpers).install(plan, on: "hidden", machine: "hidden")
        #expect(outcome.warnings == ["A session host already runs on hidden; this Cherry's cherry-host relays to it."])
        await mac.tearDown()
    } catch {
        await mac.tearDown()
        throw error
    }
}
