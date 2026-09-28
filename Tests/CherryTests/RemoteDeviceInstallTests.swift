import CherryControl
import Foundation
import Testing
@testable import Cherry

// Installing this Cherry's cherry and cherry-host on another Mac
// (docs/specs/remote-devices.md, phase 2): the decision table, the probe's
// report of installs and apps, build order, Mach-O architectures and the
// universal-helper check, the remote commands' quoting, garbage collection,
// the handover rule and the device menu's Update Session Host…. The copy
// itself runs in RemoteDeviceRealHostInstallTests.

private let local = HostProtocol.version

private func helpers(
    build: String = "20260928120000.abc1234",
    architectures: Set<String> = ["arm64", "x86_64"],
    protocol version: UInt32 = HostProtocol.version,
    hashes: [String] = ["aaaa1111", "bbbb2222"]
) -> RemoteHostHelpers {
    RemoteHostHelpers(
        directory: URL(fileURLWithPath: "/tmp/helpers"),
        version: RemoteHostVersionReport(protocol: version, build: build, version: "0.1.0", os: "macos", arch: "aarch64", min_macos: "11.0"),
        architectures: architectures,
        hashes: hashes
    )
}

private func probe(
    arch: String = "arm64",
    macOS: String = "26.0",
    hostVersion: RemoteHostVersionReport? = nil,
    status: RemoteHostStatusReport? = RemoteHostStatusReport(running: false, state: "absent"),
    installed: [RemoteInstalledBuild] = [],
    apps: [RemoteCherryApp] = []
) -> RemoteDeviceProbeResult {
    var result = RemoteDeviceProbeResult(uname: "Darwin \(arch)", macOSVersion: macOS, computerName: "Studio", homeDirectory: "/Users/me")
    result.hostVersion = hostVersion
    result.hostStatus = status
    result.installedBuilds = installed
    result.cherryApps = apps
    return result
}

private func running(_ version: UInt32, build: String? = nil) -> RemoteHostStatusReport {
    RemoteHostStatusReport(running: true, state: version == local ? "ready" : "older", protocol: version, build: build, host_id: "h1")
}

// MARK: - The decision table

@Test func remoteDeviceInstallDecidesFromTheDaemonThere() throws {
    let ours = helpers()
    // Absent: install and use.
    var decision = RemoteHostInstall.decide(probe: probe(), helpers: .success(ours), machine: "Studio")
    var plan = try #require(decision.plan)
    #expect(plan.daemon == .absent)
    #expect(plan.copyNeeded && !plan.isUpdate && plan.warnings.isEmpty)
    #expect(plan.directoryName == "20260928120000.abc1234")
    #expect(plan.addTitle == "Install & Add" && plan.updateTitle == "Install")

    // The same protocol: install ours; it relays to that daemon.
    decision = RemoteHostInstall.decide(
        probe: probe(hostVersion: .init(protocol: local, build: "20260928120000.abc1234"), status: running(local, build: "20260101000000.old")),
        helpers: .success(ours), machine: "Studio"
    )
    plan = try #require(decision.plan)
    #expect(plan.daemon == .sameProtocol(build: "20260101000000.old", newerBuild: false))
    #expect(plan.warnings.isEmpty)

    // A newer build of the same protocol keeps running: said so.
    decision = RemoteHostInstall.decide(
        probe: probe(status: running(local, build: "20270101000000.new")), helpers: .success(ours), machine: "Studio"
    )
    plan = try #require(decision.plan)
    #expect(plan.daemon == .sameProtocol(build: "20270101000000.new", newerBuild: true))
    #expect(plan.warnings.first?.contains("newer build") == true)

    // Older (4 or later): warn, then install; the gateway's Replace does the rest.
    let olderApp = RemoteCherryApp(path: "/Applications/Cherry.app", version: .init(protocol: local - 1))
    decision = RemoteHostInstall.decide(
        probe: probe(status: running(local - 1), apps: [olderApp]), helpers: .success(ours), machine: "Studio"
    )
    plan = try #require(decision.plan)
    #expect(plan.daemon == .olderProtocol(local - 1))
    #expect(plan.isUpdate && plan.addTitle == "Update & Add")
    #expect(plan.warnings == ["Cherry on Studio is older; connecting updates its session host; its sessions carry on; update Cherry there too."])
    // Without a Cherry.app there, it only says the daemon is replaced.
    decision = RemoteHostInstall.decide(probe: probe(status: running(4)), helpers: .success(ours), machine: "Studio")
    #expect(decision.plan?.warnings.first?.contains("speaks an older protocol (4)") == true)

    // Newer: blocked, "Update Cherry on this Mac".
    decision = RemoteHostInstall.decide(probe: probe(status: running(local + 1)), helpers: .success(ours), machine: "Studio")
    guard case .blocked(let newer, let plainAdd) = decision else { Issue.record("not blocked"); return }
    #expect(newer.contains("Update Cherry on this Mac") && !plainAdd)

    // Older than 4: blocked, with the README's shutdown instructions.
    decision = RemoteHostInstall.decide(probe: probe(status: running(3)), helpers: .success(ours), machine: "Studio")
    guard case .blocked(let tooOld, _) = decision else { Issue.record("not blocked"); return }
    #expect(tooOld.contains("cherry shutdown") && tooOld.contains("pkill -u \"$USER\" -f 'cherry-host serve'"))

    // A daemon that did not answer: install, with a warning.
    decision = RemoteHostInstall.decide(
        probe: probe(status: .init(running: true, state: "unresponsive", error: "timed out")), helpers: .success(ours), machine: "Studio"
    )
    #expect(decision.plan?.daemon == .unknown("timed out"))
}

@Test func remoteDeviceInstallRefusesWhatThisCherryCannotInstallThere() {
    // A missing architecture: helpers for arm64 only on an Intel Mac.
    var decision = RemoteHostInstall.decide(
        probe: probe(arch: "x86_64"), helpers: .success(helpers(architectures: ["arm64"])), machine: "Mini"
    )
    guard case .blocked(let reason, let plainAdd) = decision else { Issue.record("not blocked"); return }
    #expect(reason.contains("built for arm64 only") && reason.contains("Intel Mac"))
    // Only this Cherry's helpers are in the way: the Mac can still be added.
    #expect(plainAdd)
    var checklist = RemoteDeviceChecklist(result: probe(arch: "x86_64"), destination: "mini", installation: decision)
    #expect(checklist.canAdd && checklist.items.first { $0.id == "install" }?.status == .warning)
    // …using a cherry-host of this protocol already there.
    let withHost = probe(arch: "x86_64", hostVersion: .init(protocol: local))
    decision = RemoteHostInstall.decide(probe: withHost, helpers: .success(helpers(architectures: ["arm64"])), machine: "Mini")
    guard case .blocked(_, true) = decision else { Issue.record("no plain Add"); return }
    checklist = RemoteDeviceChecklist(result: withHost, destination: "mini", installation: decision)
    #expect(checklist.items.first { $0.id == "install" }?.detail?.contains("already there is used instead") == true)
    // An arm64e Mac runs arm64 code.
    #expect(RemoteHostInstall.decide(probe: probe(arch: "arm64e"), helpers: .success(helpers(architectures: ["arm64"])), machine: "M").plan != nil)

    // No helpers here.
    decision = RemoteHostInstall.decide(probe: probe(), helpers: .failure(.message("The cherry session client is missing.")), machine: "Mini")
    guard case .blocked(let missing, true) = decision else { Issue.record("not blocked"); return }
    #expect(missing == "The cherry session client is missing.")

    // Too old a macOS for the slice.
    var old = helpers()
    old.version.min_macos = "27.0"
    decision = RemoteHostInstall.decide(probe: probe(macOS: "26.1"), helpers: .success(old), machine: "Mini")
    guard case .blocked(let macOS, _) = decision else { Issue.record("not blocked"); return }
    #expect(macOS.contains("macOS 27.0") && macOS.contains("26.1"))
    #expect(RemoteHostInstall.compareVersions("26.1", "26.1.0") == .orderedSame)
    #expect(RemoteHostInstall.compareVersions("15.5", "26.0") == .orderedAscending)

    // SSH failed, or not a Mac.
    var failed = RemoteDeviceProbeResult()
    failed.sshFailure = .unreachable("x")
    #expect(RemoteHostInstall.decide(probe: failed, helpers: .success(helpers()), machine: "M").plan == nil)
    #expect(RemoteHostInstall.decide(probe: RemoteDeviceProbeResult(uname: "Linux x86_64"), helpers: .success(helpers()), machine: "M").plan == nil)
}

@Test func remoteDeviceInstallSkipsTheCopyWhenTheSameFilesAreThere() throws {
    let ours = helpers(hashes: ["aaaa1111", "bbbb2222"])
    // Installed with the same hashes: nothing to copy.
    var decision = RemoteHostInstall.decide(
        probe: probe(installed: [.init(name: ours.directoryName, hashes: ours.hashes)]), helpers: .success(ours), machine: "M"
    )
    var plan = try #require(decision.plan)
    #expect(!plan.copyNeeded && plan.addTitle == "Add" && plan.updateTitle == "Use It")
    #expect(plan.directoryName == ours.directoryName)
    // The same build with other files, or an incomplete one (a missing
    // file is "-"): copied, aimed at the build's directory; the finish
    // checks that one and repairs it, or uses `<build>-<hash>` when it is
    // in use.
    for damaged in [["x", "y"], ["aaaa1111", "-"]] {
        decision = RemoteHostInstall.decide(
            probe: probe(installed: [.init(name: ours.directoryName, hashes: damaged)]), helpers: .success(ours), machine: "M"
        )
        plan = try #require(decision.plan)
        #expect(plan.copyNeeded && plan.directoryName == ours.directoryName)
        #expect(!plan.isUpdate)
    }
    #expect(RemoteHostInstaller.alternateName(ours.directoryName, hashes: ours.hashes) == "\(ours.directoryName)-aaaa1111bbbb")
    // A good copy in the alternate directory is used as it is.
    decision = RemoteHostInstall.decide(
        probe: probe(installed: [
            .init(name: ours.directoryName, hashes: ["x", "-"]),
            .init(name: "\(ours.directoryName)-aaaa1111bbbb", hashes: ours.hashes),
        ]),
        helpers: .success(ours), machine: "M"
    )
    plan = try #require(decision.plan)
    #expect(!plan.copyNeeded && plan.directoryName == "\(ours.directoryName)-aaaa1111bbbb")
    // Another build of ours there: an update.
    decision = RemoteHostInstall.decide(
        probe: probe(installed: [.init(name: "20200101000000.old", hashes: ["x", "y"])]), helpers: .success(ours), machine: "M"
    )
    #expect(decision.plan?.isUpdate == true && decision.plan?.addTitle == "Update & Add")

    #expect(RemoteHostHelpers.directoryName(forBuild: "dev-20260928025554.05d5fe8") == "dev-20260928025554.05d5fe8")
    #expect(RemoteHostHelpers.directoryName(forBuild: "../a b/'c") == "_a_b__c")
    #expect(RemoteHostHelpers.directoryName(forBuild: "") == "unknown")
    #expect(RemoteHostInstall.remoteHostPath(directoryName: "b1") == "~/Library/Application Support/cherry-host/bin/b1/cherry-host")
    #expect(RemoteHostInstall.directoryName(ofRemoteHostPath: "~/Library/Application Support/cherry-host/bin/b1/cherry-host") == "b1")
    #expect(RemoteHostInstall.directoryName(ofRemoteHostPath: "/opt/cherry-host") == nil)
}

@Test func remoteDeviceInstallWarnsAboutCherryAppsThere() throws {
    let newerApp = RemoteCherryApp(path: "/Applications/Cherry.app", version: .init(protocol: local + 1))
    let olderApp = RemoteCherryApp(path: "/Users/me/Applications/Cherry.app", version: .init(protocol: local - 1))
    let plan = try #require(RemoteHostInstall.decide(
        probe: probe(apps: [newerApp, olderApp]), helpers: .success(helpers()), machine: "Studio"
    ).plan)
    #expect(plan.warnings.count == 2)
    #expect(plan.warnings.contains { $0.contains("/Users/me/Applications/Cherry.app") && $0.contains("Update Cherry there too") })
    #expect(plan.warnings.contains { $0.contains("is newer") && $0.contains("update Cherry on this Mac") })
}

// MARK: - The checklist

@Test func remoteDeviceInstallChecklistSaysWhatInstallAndAddDoes() {
    var result = probe()
    // Nothing there: Install & Add.
    var decision = RemoteHostInstall.decide(probe: result, helpers: .success(helpers()), machine: "Studio")
    var checklist = RemoteDeviceChecklist(result: result, destination: "studio", installation: decision)
    #expect(checklist.canAdd)
    #expect(checklist.items.map(\.id) == ["ssh", "system", "host", "install"])
    #expect(checklist.items.first { $0.id == "host" }?.status == .ok)
    let install = checklist.items.first { $0.id == "install" }
    #expect(install?.title == "Install" && install?.status == .ok)
    #expect(install?.detail?.contains("the first tab starts its session host") == true)

    // Another protocol's cherry-host there: ours is installed beside it.
    result = probe(hostVersion: .init(protocol: local - 1), status: running(local - 1))
    decision = RemoteHostInstall.decide(probe: result, helpers: .success(helpers()), machine: "Studio")
    checklist = RemoteDeviceChecklist(result: result, destination: "studio", installation: decision)
    #expect(checklist.canAdd)
    #expect(checklist.items.first { $0.id == "host" }?.status == .ok)
    #expect(checklist.items.first { $0.id == "install" }?.status == .warning)

    // Blocked: a newer daemon.
    result = probe(hostVersion: .init(protocol: local + 1), status: running(local + 1))
    decision = RemoteHostInstall.decide(probe: result, helpers: .success(helpers()), machine: "Studio")
    checklist = RemoteDeviceChecklist(result: result, destination: "studio", installation: decision)
    #expect(!checklist.canAdd)
    #expect(checklist.items.first { $0.id == "install" }?.status == .failure)
}

// MARK: - The probe

@Test func remoteDeviceInstallProbeReportsInstallsAndApps() {
    let script = RemoteDeviceProbe.script(remoteHostPath: nil)
    #expect(script.contains("root=\"$HOME\"/'Library/Application Support/cherry-host/bin'"))
    #expect(script.contains("printf 'installed=%s%s\\n'") && script.contains("printf 'app=%s\\t%s\\n'"))
    // Incomplete directories are listed too (a missing file is "-"), so an
    // install repairs them; only partial copies and moved-aside ones are not.
    #expect(script.contains("*.partial-*|*.broken-*) continue") && script.contains(#"hashes="$hashes ${h:--}""#))
    let output = RemoteDeviceShell.Output(status: 0, standardOutput: """
    CHERRY-PROBE 1
    uname=Darwin x86_64
    macos=15.5
    home=/Users/me
    installed=20260101000000.old 1111 2222
    installed=b-2 3333 4444
    installed=broken 5555 -
    app=/Applications/Cherry.app\t{"protocol":6,"build":"20250101000000.app","version":"0.1.0","os":"macos","arch":"x86_64","min_macos":"10.12"}
    app=/Users/me/Applications/Cherry.app\t
    hostpath=/Users/me/Library/Application Support/cherry-host/bin/b-2/cherry-host
    CHERRY-PROBE-END

    """, standardError: "")
    let result = RemoteDeviceProbe.parse(output)
    #expect(result.architecture == "x86_64")
    #expect(result.installedBuilds == [
        RemoteInstalledBuild(name: "20260101000000.old", hashes: ["1111", "2222"]),
        RemoteInstalledBuild(name: "b-2", hashes: ["3333", "4444"]),
        RemoteInstalledBuild(name: "broken", hashes: ["5555", "-"]),
    ])
    #expect(result.cherryApps.map(\.path) == ["/Applications/Cherry.app", "/Users/me/Applications/Cherry.app"])
    #expect(result.cherryApps.first?.version?.protocol == 6)
    #expect(result.cherryApps.last?.version == nil)
    #expect(AddDeviceModel.remoteHostPath(found: result.hostPath, home: result.homeDirectory)
        == "~/Library/Application Support/cherry-host/bin/b-2/cherry-host")
}

// MARK: - Builds and architectures

@Test func remoteDeviceInstallOrdersOnlyStampedBuilds() {
    #expect(HostBuildOrder.isNewer("20260928120000.abc", than: "20260101000000.def"))
    #expect(!HostBuildOrder.isNewer("20260101000000.def", than: "20260928120000.abc"))
    #expect(!HostBuildOrder.isNewer("20260928120000.abc", than: "20260928120000.xyz"))
    #expect(!HostBuildOrder.isNewer("dev-20260928120000.abc", than: "20200101000000.old"))
    #expect(!HostBuildOrder.isNewer("20260928120000.abc", than: nil))
    #expect(HostBuildOrder.stamp("2026092812000.abc") == nil)

    var device = RemoteDevice(name: "Studio", sshDestination: "studio", installedBuild: "20260101000000.old")
    #expect(device.hostIsOlder(thanBundled: "20260928120000.abc"))
    #expect(!device.hostIsOlder(thanBundled: "dev-20260928120000.abc"))
    #expect(!device.hostIsOlder(thanBundled: nil))
    device.installedBuild = nil
    #expect(!device.hostIsOlder(thanBundled: "20260928120000.abc"))
}

/// Minimal Mach-O files: a thin header, and a fat one with a slice per
/// architecture, as `lipo -archs` reads them.
private enum MachOFixture {
    static func thin(cpu: UInt32, subtype: UInt32 = 0) -> Data {
        var data = Data()
        for value: UInt32 in [0xFEED_FACF, cpu, subtype, 2, 0, 0, 0, 0] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fat(_ slices: [(cpu: UInt32, subtype: UInt32)]) -> Data {
        var header = Data()
        func big(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { header.append(contentsOf: $0) } }
        big(0xCAFE_BABE)
        big(UInt32(slices.count))
        for (index, slice) in slices.enumerated() {
            big(slice.cpu)
            big(slice.subtype)
            big(UInt32(4096 * (index + 1)))
            big(32)
            big(12)
        }
        var data = header + Data(count: 4096 - header.count)
        for (index, slice) in slices.enumerated() {
            data += thin(cpu: slice.cpu, subtype: slice.subtype)
            if index < slices.count - 1 { data += Data(count: 4096 - 32) }
        }
        return data
    }

    static let arm64: UInt32 = 0x0100_000C
    static let x86_64: UInt32 = 0x0100_0007
}

@Test func remoteDeviceInstallReadsMachOArchitectures() {
    #expect(MachOArchitectures.parse(MachOFixture.thin(cpu: MachOFixture.arm64)) == ["arm64"])
    #expect(MachOArchitectures.parse(MachOFixture.thin(cpu: MachOFixture.arm64, subtype: 0x8000_0002)) == ["arm64e"])
    #expect(MachOArchitectures.parse(MachOFixture.thin(cpu: MachOFixture.x86_64, subtype: 3)) == ["x86_64"])
    #expect(MachOArchitectures.parse(MachOFixture.fat([(MachOFixture.arm64, 0), (MachOFixture.x86_64, 3)])) == ["arm64", "x86_64"])
    #expect(MachOArchitectures.parse(Data("#!/bin/sh\n".utf8)) == nil)
    #expect(MachOArchitectures.parse(Data()) == nil)
}

/// Scripts/check-helper-archs (install-local-app and package-dmg run it)
/// passes universal helpers and names what a thin one lacks.
@Test func remoteDeviceInstallHelperArchitectureCheckNeedsBothArchitectures() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/lipo") else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-archs-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let thin = directory.appendingPathComponent("thin")
    let fat = directory.appendingPathComponent("fat")
    let intel = directory.appendingPathComponent("intel")
    try MachOFixture.thin(cpu: MachOFixture.arm64).write(to: thin)
    try MachOFixture.fat([(MachOFixture.arm64, 0), (MachOFixture.x86_64, 3)]).write(to: fat)
    try MachOFixture.thin(cpu: MachOFixture.x86_64, subtype: 3).write(to: intel)
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/check-helper-archs")

    func run(_ files: [URL]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = script
        process.arguments = files.map(\.path)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
    #expect(try run([fat]).0 == 0)
    let (status, text) = try run([fat, thin, intel])
    #expect(status == 1)
    #expect(text.contains("thin is built for arm64 only; it lacks x86_64"))
    #expect(text.contains("intel is built for x86_64 only; it lacks arm64"))
    #expect(!text.contains("fat is built"))
    #expect(MachOArchitectures.read(fat) == ["arm64", "x86_64"])
}

// MARK: - The remote commands

@Test func remoteDeviceInstallCopyCommandIsOneLineAnyLoginShellPassesOn() throws {
    let command = RemoteHostInstaller.copyCommand(partialName: "20260928120000.abc.partial-1234")
    #expect(!command.contains("\n") && !command.contains("!"))
    #expect(command.hasPrefix("/bin/sh -c '"))
    // Inside the quotes (outside, `'\''` closes and reopens them) there is
    // no backslash, which fish would read as an escape.
    let quoted = command.dropFirst("/bin/sh -c ".count)
    for part in quoted.components(separatedBy: "'\\''") {
        #expect(!part.contains("\\"), "\(part)")
    }
    // Each login shell there hands sh the script unchanged.
    let script = "umask 077 && mkdir -p \"$HOME\"/'Library/Application Support/cherry-host/bin/20260928120000.abc.partial-1234' && /usr/bin/tar -xf - -C \"$HOME\"/'Library/Application Support/cherry-host/bin/20260928120000.abc.partial-1234' && echo CHERRY-INSTALL-COPIED"
    let printed = command.replacingOccurrences(of: "/bin/sh -c ", with: "/usr/bin/printf '%s' ")
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    where FileManager.default.isExecutableFile(atPath: shell) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", printed]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(text == script, "\(shell)")
    }
}

@Test func remoteDeviceInstallReadsTheChecksAndReportsOfTheScripts() {
    let ours = helpers(hashes: ["h1", "h2"])
    let good: [(key: String, value: String)] = [
        ("codesign", "ok"), ("verify_status", "0"),
        ("verify", #"{"protocol":\#(local),"build":"20260928120000.abc1234","version":"0.1.0","os":"macos","arch":"x86_64","min_macos":"10.12"}"#),
        ("hashes", "h1 h2 "),
    ]
    #expect(RemoteHostInstaller.Verification(fields: good).problem(expected: ours, machine: "Mini") == nil)
    #expect(RemoteHostInstaller.Verification(fields: good).version?.arch == "x86_64")
    // macOS refused the signature: the copy was killed at launch.
    var killed = good
    killed[1] = ("verify_status", "137")
    #expect(RemoteHostInstaller.Verification(fields: killed).problem(expected: ours, machine: "Mini")?.contains("refused to run cherry-host") == true)
    var unsigned = good
    unsigned[0] = ("codesign", "failed")
    unsigned.append(("codesign_error", "x: invalid signature (code or signature have been modified) "))
    #expect(RemoteHostInstaller.Verification(fields: unsigned).problem(expected: ours, machine: "Mini")
        == "macOS on Mini does not accept the copy's signature (codesign: x: invalid signature (code or signature have been modified)).")
    var other = good
    other[3] = ("hashes", "h1 zz")
    #expect(RemoteHostInstaller.Verification(fields: other).problem(expected: ours, machine: "Mini")?.contains("SHA-256") == true)
    #expect(RemoteHostInstaller.Verification(fields: [("missing", "1")]).problem(expected: ours, machine: "Mini") == "The copy on Mini is incomplete.")

    let report = RemoteHostInstaller.Report(fields: [
        ("root", "/Users/me/Library/Application Support/cherry-host/bin"),
        ("installed", "1"),
        ("status", #"{"running":true,"build":"20260101000000.old","protocol":7,"host":{"version":7,"build":"20260101000000.old","pid":42,"executable":"/Users/me/Library/Application Support/cherry-host/bin/20260101000000.old/cherry-host"},"sessions":[{"id":"s1","state":"running","holder_build":"20250101000000.older"}]}"#),
        ("hoststatus", #"{"running":true,"state":"ready","protocol":7,"build":"b","host_id":"h"}"#),
        ("directory", "1700000000 0 20260101000000.old"),
        ("directory", "1700000100 1700000200 b with space"),
        ("placed", "b"), ("final", "replaced"), ("broken", "b incomplete"), ("nested", "b.partial-x"),
        ("process", "/Users/me/Library/Application Support/cherry-host/bin/b with space/cherry-host hold --socket /tmp/x"),
    ])
    #expect(report.homeDirectory == "/Users/me")
    #expect(report.installed && report.placed == "b" && report.final == "replaced")
    #expect(report.broken == ["b incomplete"] && report.nested == ["b.partial-x"])
    #expect(report.status?.host?.pid == 42)
    #expect(report.hostStatus?.protocol == 7)
    #expect(report.directories == [
        .init(name: "20260101000000.old", installed: Date(timeIntervalSince1970: 1_700_000_000), lastUsed: nil),
        .init(name: "b with space", installed: Date(timeIntervalSince1970: 1_700_000_100), lastUsed: Date(timeIntervalSince1970: 1_700_000_200)),
    ])
    #expect(report.processes.count == 1)

    // Every script names its paths quoted for sh.
    #expect(RemoteHostInstaller.cleanUpScript(names: ["it's"]).contains(#"d="$root"/'it'\''s'"#))
    #expect(RemoteHostInstaller.verifyScript(directoryName: "b", sourceName: "b.partial-1").contains("/usr/bin/codesign --verify --strict"))
    let finish = RemoteHostInstaller.finishScript(directoryName: "b", sourceName: "b.partial-1", expectedHashes: ["h1", "h2"])
    // rename(2), never `mv` into a directory that may exist.
    #expect(finish.contains("/usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1'"))
    #expect(!finish.contains("mv \"$src\""))
    #expect(finish.contains("expected='h1 h2 '"))
    #expect(finish.contains("place 'b' || place 'b-h1h2'"))
    let handOver = RemoteHostInstaller.handOverScript(directoryName: "b", pid: 42, executable: "/x/it's/cherry-host", build: "b0")
    #expect(handOver.contains(#""$dir/cherry" restart --if-pid 42 --if-executable '/x/it'\''s/cherry-host' --if-build 'b0'"#))
    #expect(handOver.contains("restart=changed"))
}

/// The scripts call system tools by absolute path, so a PATH with GNU
/// coreutils first (whose `stat -f` means --file-system) or a stand-in
/// changes nothing.
@Test func remoteDeviceInstallScriptsRunSystemToolsByAbsolutePath() {
    let scripts = [
        RemoteDeviceProbe.script(remoteHostPath: nil, marker: ("b", UUID())),
        RemoteHostInstaller.verifyScript(directoryName: "b", sourceName: "b.partial-1"),
        RemoteHostInstaller.finishScript(directoryName: "b", sourceName: "b.partial-1", expectedHashes: ["h1", "h2"], installationID: UUID()),
        RemoteHostInstaller.finishScript(directoryName: "b", sourceName: nil, expectedHashes: ["h1", "h2"]),
        RemoteHostInstaller.handOverScript(directoryName: "b", pid: 1, executable: "/e", build: "b"),
        RemoteHostInstaller.cleanUpScript(names: ["a"]),
        RemoteHostInstaller.markScript(directoryName: "b", installationID: UUID()),
        RemoteHostInstaller.copyCommand(partialName: "b.partial-1"),
    ]
    for script in scripts {
        for tool in ["stat", "tar", "shasum", "xattr", "codesign", "ps", "touch"] {
            let words = script.components(separatedBy: CharacterSet(charactersIn: " \n;(|&$\"'"))
            #expect(!words.contains(tool), "\(tool) without its path in:\n\(script)")
        }
    }
    #expect(RemoteHostInstaller.copyCommand(partialName: "b.partial-1").contains("/usr/bin/tar -xf -"))
}

// MARK: - Garbage collection and the handover

@Test func remoteDeviceInstallKeepsTheCurrentBuildTheTwoBeforeItAndThoseInUse() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400
    func build(_ name: String, age: TimeInterval, used: TimeInterval? = nil) -> RemoteHostInstall.BuildDirectory {
        .init(name: name, installed: now - age, lastUsed: used.map { now - $0 })
    }
    let directories = [
        build("current", age: 0),
        build("b6", age: 10 * day),
        build("b5", age: 11 * day),
        build("b4", age: 12 * day),
        build("b3", age: 13 * day, used: 2 * day),     // another Mac used it lately
        build("b2", age: 14 * day, used: 40 * day),    // used, but long ago
        build("b1", age: 15 * day),
        build("b0", age: 16 * day),
        build("b1.partial-old", age: 2 * 3_600),
        build("b1.broken-12", age: 2 * 3_600),
        build("current.partial-new", age: 60),
    ]
    // Kept: current, the two most recent others (b6, b5), b3 (a marker
    // younger than 30 days), b1 (in use); removed: the rest, and scratch
    // directories older than an hour.
    #expect(RemoteHostInstall.garbage(directories: directories, current: "current", inUse: ["b1"], now: now)
        == ["b1.partial-old", "b1.broken-12", "b4", "b2", "b0"])
    // Nothing younger than 7 days goes, used or not.
    let young = [build("current", age: 0), build("y2", age: 1 * day), build("y1", age: 2 * day), build("y0", age: 6 * day)]
    #expect(RemoteHostInstall.garbage(directories: young, current: "current", inUse: [], now: now).isEmpty)
    #expect(RemoteHostInstall.garbage(directories: [build("current", age: 0)], current: "current", inUse: [], now: now).isEmpty)
}

/// Each reason a build is in use, apart: a process runs from it (whatever
/// the daemon says), the daemon's executable is there, the daemon reports
/// its build, a running session's holder reports its build.
@Test func remoteDeviceInstallSaysWhyABuildIsInUse() {
    let root = "/Users/me/Library/Application Support/cherry-host/bin"
    let directories = ["daemon", "gateway", "20250101000000.h", "20250101000000.h-abcdef", "20260101000000.d", "20240101000000.gone", "idle"]
    // Only the process list names a directory.
    var used = RemoteHostInstall.directoriesInUse(
        root: root, directories: directories,
        processes: ["\(root)/gateway/cherry-host gateway", "/usr/bin/other", "\(root)/idle-not/cherry-host"],
        status: nil
    )
    #expect(used == ["gateway": [.process]])
    // Only a holder build names one (no process there).
    used = RemoteHostInstall.directoriesInUse(
        root: root, directories: directories, processes: [],
        status: RemoteCLIStatusReport(running: true, build: nil, host: nil, sessions: [
            .init(id: "a", state: "running", holder_build: "20250101000000.h"),
            .init(id: "b", state: "exited", holder_build: "20240101000000.gone"),
        ])
    )
    #expect(used == ["20250101000000.h": [.holderBuild], "20250101000000.h-abcdef": [.holderBuild]])
    // The daemon: its executable's directory and its build's.
    used = RemoteHostInstall.directoriesInUse(
        root: root, directories: directories, processes: [],
        status: RemoteCLIStatusReport(
            running: true, build: "20260101000000.d",
            host: .init(version: local, build: "20260101000000.d", pid: 1, executable: "\(root)/daemon/cherry-host"), sessions: []
        )
    )
    #expect(used == ["daemon": [.daemonExecutable], "20260101000000.d": [.daemonBuild]])
}

@Test func remoteDeviceInstallRechecksTheDaemonOnceItsBuildRunsThere() throws {
    let absent = RemoteHostInstallPlan(daemon: .absent, directoryName: "b", copyNeeded: true, isUpdate: false, warnings: [])
    func running(_ version: UInt32) -> RemoteHostStatusReport {
        .init(running: true, state: "ready", protocol: version, build: "x", host_id: "h")
    }
    #expect(try RemoteHostInstall.recheck(status: nil, plan: absent, machine: "M").get().isEmpty)
    #expect(try RemoteHostInstall.recheck(status: .init(running: false, state: "absent"), plan: absent, machine: "M").get().isEmpty)
    // The check found no cherry-host to ask, but a daemon runs.
    #expect(try RemoteHostInstall.recheck(status: running(local), plan: absent, machine: "M").get().first?.contains("relays") == true)
    #expect(try RemoteHostInstall.recheck(status: running(4), plan: absent, machine: "M").get().first?.contains("older protocol (4)") == true)
    guard case .failure(let newer) = RemoteHostInstall.recheck(status: running(local + 1), plan: absent, machine: "M") else {
        Issue.record("a newer daemon is not refused"); return
    }
    #expect(newer.errorDescription?.contains("Update Cherry on this Mac") == true)
    guard case .failure(let old) = RemoteHostInstall.recheck(status: running(3), plan: absent, machine: "M") else {
        Issue.record("a daemon older than 4 is not refused"); return
    }
    #expect(old.errorDescription?.contains("cherry shutdown") == true)
    // What the check already knew is not said twice.
    var relay = absent
    relay.daemon = .sameProtocol(build: "x", newerBuild: false)
    #expect(try RemoteHostInstall.recheck(status: running(local), plan: relay, machine: "M").get().isEmpty)
}

/// A device whose cherry-host is gone (removed by hand, or by an install
/// elsewhere) offers Reinstall, not "offline".
@Test func remoteDeviceInstallAMissingHostOffersReinstall() {
    let missing = HostedSessionError.transport(
        "/bin/sh: /Users/me/Library/Application Support/cherry-host/bin/b/cherry-host: No such file or directory\ncherry: the SSH connection closed before cherry-host gateway started (errors from ssh or cherry-host, if any, are shown above)"
    )
    #expect(missing.isRemoteHostMissing)
    #expect(HostedSessionError.transport("zsh:1: command not found: cherry-host").isRemoteHostMissing)
    #expect(!HostedSessionError.transport("ssh: connect to host m port 22: Connection timed out").isRemoteHostMissing)
    let state = RemoteDeviceConnectionState(control: .waitingToReconnect(missing), sessionCount: 0, lastSeen: nil)
    guard case .hostMissing = state else { Issue.record("\(state)"); return }
    #expect(state.dot == .red && state.subtitle() == "Its session host is missing")
    let device = RemoteDevice(name: "Studio", sshDestination: "studio")
    let menu = TitlebarProjectMenuModel(
        worktrees: nil, projects: [], devices: [.init(device: device, state: state, sessions: [])], currentProjectKey: nil
    ).snapshot
    #expect(menu.contains("  Reinstall Session Host…"))
    let availability = RemoteDeviceAvailability.of(.waitingToReconnect(missing), installationProblem: nil)
    #expect(availability.action == .reinstall && availability.actionTitle == "Reinstall…")
    #expect(RemoteDeviceAvailability.of(.failed(missing), installationProblem: nil).action == .reinstall)
}

/// Each connection of a device's control marks the build directory its
/// path names as used by this installation, at most once per interval.
@Test @MainActor func remoteDeviceInstallMarksTheBuildADeviceUsesOnConnection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-rd-mark-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "CherryTests.RemoteDeviceMark.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let installation = UUID()
    var marks: [(String, String, UUID)] = []
    let store = RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite))),
        installationID: { installation },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: HostedRemoteHostPaths(),
        markBuild: { device, name, id in marks.append((device.sshDestination, name, id)) }
    )
    let device = try store.add(
        name: "Studio", sshDestination: "studio", remoteHostPath: RemoteHostInstall.remoteHostPath(directoryName: "b1")
    )
    let now = Date()
    store.markUsedBuild(of: device.id, now: now)
    store.markUsedBuild(of: device.id, now: now + 60)
    try await Task.sleep(for: .milliseconds(50))
    #expect(marks.count == 1)
    #expect(marks.first?.0 == "studio" && marks.first?.1 == "b1" && marks.first?.2 == installation)
    store.markUsedBuild(of: device.id, now: now + RemoteDeviceStore.markInterval + 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(marks.count == 2)
    // A path that is not one of ours marks nothing.
    let other = try store.add(name: "Mini", sshDestination: "mini", remoteHostPath: "/opt/cherry-host")
    store.markUsedBuild(of: other.id, now: now)
    try await Task.sleep(for: .milliseconds(50))
    #expect(marks.count == 2)
    // The script touches `.used-by/<installation id>` in the build's directory.
    let script = RemoteHostInstaller.markScript(directoryName: "b1", installationID: installation)
    #expect(script.contains("/usr/bin/touch \"$dir/.used-by/\(installation.uuidString.lowercased())\""))
}

@Test func remoteDeviceInstallHandsOverOnlyOurOwnDaemonOfAnOlderOrUnorderedBuild() {
    let home = "/Users/me"
    let root = "\(home)/Library/Application Support/cherry-host/bin"
    func status(executable: String, build: String, protocol version: UInt32 = local) -> RemoteCLIStatusReport {
        RemoteCLIStatusReport(running: true, build: build, host: .init(version: version, build: build, pid: 1, executable: executable), sessions: [])
    }
    let ours = "20260928120000.new"
    // Our older install: handed over.
    #expect(RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/old/cherry-host", build: "20260101000000.old"), homeDirectory: home, current: "new", ourBuild: ours))
    // The phase 1 manual place counts as ours.
    #expect(RemoteHostInstall.shouldHandOver(status: status(executable: "\(home)/Library/Application Support/Cherry/bin/cherry-host", build: "20260101000000.old"), homeDirectory: home, current: "new", ourBuild: ours))
    // A development build is not newer: handed over too (the user asked).
    #expect(RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/dev/cherry-host", build: "dev-1.abc"), homeDirectory: home, current: "new", ourBuild: ours))
    // Never a newer build.
    #expect(!RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/newer/cherry-host", build: "20270101000000.newer"), homeDirectory: home, current: "new", ourBuild: ours))
    // Never the other Mac's own Cherry's daemon.
    #expect(!RemoteHostInstall.shouldHandOver(status: status(executable: "/Applications/Cherry.app/Contents/MacOS/cherry-host", build: "20260101000000.old"), homeDirectory: home, current: "new", ourBuild: ours))
    // Not the one it runs already, nor its own build, nor another protocol.
    #expect(!RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/new/cherry-host", build: "20260101000000.old"), homeDirectory: home, current: "new", ourBuild: ours))
    #expect(!RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/x/cherry-host", build: ours), homeDirectory: home, current: "new", ourBuild: ours))
    #expect(!RemoteHostInstall.shouldHandOver(status: status(executable: "\(root)/x/cherry-host", build: "20260101000000.old", protocol: local - 1), homeDirectory: home, current: "new", ourBuild: ours))
    #expect(!RemoteHostInstall.shouldHandOver(status: RemoteCLIStatusReport(running: false), homeDirectory: home, current: "new", ourBuild: ours))
}

// MARK: - The device

@Test func remoteDeviceInstallMenuOffersUpdateSessionHostForAnOlderInstall() {
    // Installed with Ghostty's resources (phase 3); one without them is
    // offered the update at any build (RemoteDeviceParityTests).
    let device = RemoteDevice(
        name: "Studio", sshDestination: "studio", installedBuild: "20260101000000.old", installedArch: "arm64",
        installedResources: true
    )
    func menu(_ entry: TitlebarProjectMenuModel.Device) -> String {
        TitlebarProjectMenuModel(worktrees: nil, projects: [], devices: [entry], currentProjectKey: nil).snapshot
    }
    #expect(menu(.init(device: device, state: .connected(sessionCount: 0), sessions: [], bundledBuild: "20260928120000.new"))
        .contains("  Update Session Host…\n  Persistent Sessions on Studio…"))
    #expect(!menu(.init(device: device, state: .connected(sessionCount: 0), sessions: [], bundledBuild: "20260101000000.old"))
        .contains("Update Session Host…"))
    #expect(!menu(.init(device: device, state: .connected(sessionCount: 0), sessions: [])).contains("Update Session Host…"))
    // Another protocol answers: offered whatever the builds say.
    var manual = device
    manual.installedBuild = nil
    #expect(menu(.init(device: manual, state: .incompatible(reason: "x"), sessions: [])).contains("Update Session Host…"))
    // Only the copy that keeps the devices changes one.
    let readOnly = TitlebarProjectMenuModel(
        worktrees: nil, projects: [],
        devices: [.init(device: device, state: .connected(sessionCount: 0), sessions: [], bundledBuild: "20260928120000.new")],
        currentProjectKey: nil, canModifyDevices: false
    )
    #expect(readOnly.snapshot.contains("Update Session Host… (off)"))
}

@Test func remoteDeviceInstallRecordsTheInstalledBuildAndReadsOlderFiles() throws {
    let old = #"{"id":"6F1C0000-0000-0000-0000-000000000001","name":"Studio","sshDestination":"studio","machineNames":[],"addedProjects":[],"hiddenProjects":[],"createdHostEntry":true}"#
    let decoded = try JSONDecoder().decode(RemoteDevice.self, from: Data(old.utf8))
    #expect(decoded.installedBuild == nil && decoded.installedArch == nil)
    var device = decoded
    device.installedBuild = "b1"
    device.installedArch = "x86_64"
    let again = try JSONDecoder().decode(RemoteDevice.self, from: JSONEncoder().encode(device))
    #expect(again.installedBuild == "b1" && again.installedArch == "x86_64")
}

@Test @MainActor func remoteDeviceInstallPointsTheDeviceAtTheInstalledHost() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-rd-install-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "CherryTests.RemoteDeviceInstall.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let paths = HostedRemoteHostPaths()
    let store = RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite))),
        installationID: { UUID() },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: paths
    )
    let device = try store.add(name: "Studio", sshDestination: "studio")
    store.recordInstall(RemoteHostInstaller.Outcome(
        remoteHostPath: RemoteHostInstall.remoteHostPath(directoryName: "b1"), directoryName: "b1",
        build: "20260928120000.b1", architecture: "x86_64", copied: true, handedOver: false, removed: []
    ), on: device.id)
    let updated = try #require(store.device(id: device.id))
    #expect(updated.remoteHostPath == "~/Library/Application Support/cherry-host/bin/b1/cherry-host")
    #expect(updated.installedBuild == "20260928120000.b1" && updated.installedArch == "x86_64")
    // The gateway command of its tabs and control uses it.
    #expect(paths.path(for: "studio") == updated.remoteHostPath)
    #expect(try HostedSessionHost.ssh("studio").arguments(sshControlPath: nil, remoteHostPaths: paths)
        .suffix(2) == ["--remote-host-path", "~/Library/Application Support/cherry-host/bin/b1/cherry-host"])
    // A test's override wins for its destination only.
    paths.setOverride("/opt/x/cherry-host", for: "studio")
    #expect(paths.path(for: "studio") == "/opt/x/cherry-host")
    paths.setOverride(nil, for: "studio")
    #expect(paths.path(for: "studio") == updated.remoteHostPath)
    // Saved.
    let reloaded = RemoteDeviceStore(
        fileURL: directory.appendingPathComponent(RemoteDeviceStore.fileName),
        hostStore: HostedSessionHostStore(defaults: try #require(UserDefaults(suiteName: suite))),
        installationID: { UUID() },
        registry: PersistentHostingRegistry(local: PersistentHostSessions(installationUnavailableReason: { nil }, status: PersistentSessionsStatus())),
        remoteHostPaths: HostedRemoteHostPaths()
    )
    #expect(reloaded.device(id: device.id)?.installedBuild == "20260928120000.b1")
}
