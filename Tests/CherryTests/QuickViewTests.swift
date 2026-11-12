import AppKit
import CherryControl
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing
@testable import Cherry

// Quick View: a ⌘-click on a file's path shows the file, on This Mac or on
// the Mac a tab runs on. Nothing here presents the panel, reaches ssh or
// opens an app: the bridge's seams record, and another Mac's scripts run in
// /bin/sh through a stand-in `ssh` in a private home.

private func makeDirectory(_ label: String) throws -> URL {
    let created = FileManager.default.temporaryDirectory
        .appending(path: "QuickView-\(label)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // /var is a link to /private/var: the paths a shell reports are the latter.
    return created.resolvingSymlinksInPath()
}

/// A stand-in `ssh` that runs the script it is given with /bin/sh in
/// `home` (its arguments, logged to `log`, are ignored).
private struct LocalShell {
    let home: URL
    let log: URL
    let shell: RemoteDeviceShell

    init(home: URL) throws {
        self.home = home
        let bin = try makeDirectory("ssh")
        log = bin.appending(path: "calls.log")
        let ssh = bin.appending(path: "ssh")
        try """
        #!/bin/sh
        printf 'call\\n' >> "$QV_LOG"
        cd "$HOME" && exec /bin/sh -s
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        shell = RemoteDeviceShell(
            sshExecutable: ssh.path,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "QV_LOG": log.path]
        )
    }

    var calls: Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func run(_ script: String) async -> RemoteDeviceShell.DataOutput {
        await shell.runData(script, on: "studio")
    }

    func files(cache: QuickViewCache) -> QuickViewRemoteFiles {
        let shell = shell
        return QuickViewRemoteFiles(
            machine: .remote(name: "Studio", destination: "studio"), destination: "studio",
            shell: { _ in shell }, cache: cache
        )
    }
}

/// A source whose looks and copies the test decides.
private struct FakeSource: QuickViewFileSource {
    let machine: QuickViewMachine
    var look: @Sendable ([QuickViewCandidate]) async -> QuickViewLook
    var copy: @Sendable (QuickViewFoundFile, Bool) async -> QuickViewCopy = { file, _ in
        .local(URL(fileURLWithPath: file.path))
    }

    func look(at candidates: [QuickViewCandidate]) async -> QuickViewLook {
        await look(candidates)
    }

    func copy(_ file: QuickViewFoundFile, refresh: Bool) async -> QuickViewCopy {
        await copy(file, refresh)
    }
}

/// Puts the bridge's and the links' seams back on `restore()`.
@MainActor
private final class QuickViewSeams {
    var presented: [(QuickViewRequest, QuickViewMachine)] = []
    var opened: [URL] = []
    var toasts: [ProjectWindowToast] = []
    private let saved = (QuickViewOpening.isEnabled, QuickViewOpening.present, QuickViewOpening.remoteSource)
    private let savedLinks = (TerminalLinkOpening.opener, TerminalLinkOpening.showToast)

    init(enabled: Bool = true) {
        QuickViewOpening.isEnabled = { enabled }
        QuickViewOpening.present = { [unowned self] request, source, _ in
            self.presented.append((request, source.machine))
        }
        QuickViewOpening.remoteSource = { name, destination in
            FakeSource(machine: .remote(name: name, destination: destination), look: { _ in .missing })
        }
        TerminalLinkOpening.opener = { [unowned self] in self.opened.append($0) }
        TerminalLinkOpening.showToast = { [unowned self] toast, _ in self.toasts.append(toast) }
    }

    func restore() {
        (QuickViewOpening.isEnabled, QuickViewOpening.present, QuickViewOpening.remoteSource) = saved
        (TerminalLinkOpening.opener, TerminalLinkOpening.showToast) = savedLinks
    }
}

/// A Cmd-click on `text` in `tab`, as Ghostty reports one.
@MainActor
private func click(_ text: String, kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, in tab: TerminalSession) -> Bool {
    let buffer = strdup(text)!
    defer { free(buffer) }
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_OPEN_URL
    action.action.open_url = ghostty_action_open_url_s(kind: kind, url: UnsafePointer(buffer), len: UInt(strlen(buffer)))
    return TerminalCallbacks.openURL(action, bridge: TerminalCallbackBridge(delegate: tab.ghosttyBridge))
}

@Suite(.serialized) @MainActor
struct QuickViewTests {
    // MARK: Reading links

    @Test func QuickViewReadsThePathALinkNames() {
        #expect(QuickViewLink.path(of: "src/app.swift:12:4", kind: .unknown) == "src/app.swift:12:4")
        #expect(QuickViewLink.path(of: "/tmp/notes.md", kind: .unknown) == "/tmp/notes.md")
        #expect(QuickViewLink.path(of: "file:///tmp/a%20b.txt", kind: .unknown) == "/tmp/a b.txt")
        #expect(QuickViewLink.path(of: "file://studio.local/Users/me/a.png", kind: .osc8) == "/Users/me/a.png")
        // Web links, other schemes and an OSC 8 path that is no URL name no file.
        #expect(QuickViewLink.path(of: "https://example.com/a.png", kind: .unknown) == nil)
        #expect(QuickViewLink.path(of: "vscode://file/tmp/a.swift", kind: .osc8) == nil)
        #expect(QuickViewLink.path(of: "/tmp/notes.md", kind: .osc8) == nil)
        // Ghostty's own files are Ghostty's; hidden characters are refused elsewhere.
        #expect(QuickViewLink.path(of: "/tmp/config", kind: .text) == nil)
        #expect(QuickViewLink.path(of: "/tmp/a\u{202E}b.txt", kind: .unknown) == nil)
    }

    @Test func QuickViewTriesThePathAsPrintedThenWithoutItsLineAndPunctuation() {
        #expect(QuickViewLink.variants(of: "src/app.swift:12:4") == [
            QuickViewCandidate(path: "src/app.swift:12:4"),
            QuickViewCandidate(path: "src/app.swift", line: 12),
        ])
        #expect(QuickViewLink.variants(of: "notes.md.") == [
            QuickViewCandidate(path: "notes.md."), QuickViewCandidate(path: "notes.md"),
        ])
        #expect(QuickViewLink.variants(of: "../") == [QuickViewCandidate(path: "../")])
        #expect(QuickViewLink.variants(of: "a/b:0") == [QuickViewCandidate(path: "a/b:0")])
        let stripped = QuickViewLink.withoutLineSuffix("logs/out.txt:120")
        #expect(stripped?.0 == "logs/out.txt" && stripped?.1 == 120)
        #expect(QuickViewLink.withoutTrailingPunctuation("./..") == nil)
    }

    @Test func QuickViewLooksFromTheTabsDirectoryThenItsProject() throws {
        let local = QuickViewContext(
            machine: .thisMac, workingDirectory: "/Users/me/app/web", projectRoot: "/Users/me/app", homeDirectory: "/Users/me"
        )
        let request = try #require(QuickViewLink.request(text: ".reference/a.story", kind: .unknown, context: local))
        #expect(request.candidates.map(\.path) == ["/Users/me/app/web/.reference/a.story", "/Users/me/app/.reference/a.story"])
        #expect(try #require(QuickViewLink.request(text: "~/notes/./x.md", kind: .unknown, context: local)).candidates
            == [QuickViewCandidate(path: "/Users/me/notes/x.md")])
        #expect(try #require(QuickViewLink.request(text: "/etc//hosts:3", kind: .unknown, context: local)).candidates
            == [QuickViewCandidate(path: "/etc/hosts:3"), QuickViewCandidate(path: "/etc/hosts", line: 3)])

        // Another Mac whose home Cherry does not know: `~` is expanded there.
        let remote = QuickViewContext(
            machine: .remote(name: "Studio", destination: "studio"), workingDirectory: "/Users/them/app",
            projectRoot: "/Users/them/app", homeDirectory: nil
        )
        #expect(try #require(QuickViewLink.request(text: "~/a/b.txt", kind: .unknown, context: remote)).candidates
            == [QuickViewCandidate(path: "~/a/b.txt")])
        #expect(try #require(QuickViewLink.request(text: "src/x.swift", kind: .unknown, context: remote)).candidates
            == [QuickViewCandidate(path: "/Users/them/app/src/x.swift")])
        // Nothing to start a relative path from, and `~user`: no request.
        var lost = remote
        lost.workingDirectory = nil
        lost.projectRoot = nil
        #expect(QuickViewLink.request(text: "src/x.swift", kind: .unknown, context: lost) == nil)
        #expect(QuickViewLink.request(text: "~bob/x.txt", kind: .unknown, context: local) == nil)
    }

    // MARK: This Mac's files

    @Test func QuickViewFindsThisMacsFilesAndFolders() throws {
        let root = try makeDirectory("local")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "docs/b"), withIntermediateDirectories: true)
        try "hello".write(to: root.appending(path: "docs/a.txt"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: "docs/Z.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.txt"), withDestinationURL: root.appending(path: "docs/a.txt"))

        let file = QuickViewLocalFiles.lookSynchronously(at: [
            QuickViewCandidate(path: root.appending(path: "nope.txt").path),
            QuickViewCandidate(path: root.appending(path: "docs/a.txt").path, line: 3),
        ])
        guard case let .file(found, line) = file else {
            Issue.record("not a file: \(file)")
            return
        }
        #expect(found.path == root.appending(path: "docs/a.txt").path && found.size == 5 && line == 3)
        #expect(found.modified != nil && found.isReadable)

        // A link is the file it leads to.
        if case let .file(linked, _) = QuickViewLocalFiles.lookSynchronously(at: [QuickViewCandidate(path: root.appending(path: "link.txt").path)]) {
            #expect(linked.size == 5)
        } else {
            Issue.record("a link to a file is no file")
        }

        let folder = QuickViewLocalFiles.lookSynchronously(at: [QuickViewCandidate(path: root.appending(path: "docs").path)])
        #expect(folder == .folder(QuickViewFolder(path: root.appending(path: "docs").path, entries: [
            .init(name: "b", isFolder: true), .init(name: "a.txt", isFolder: false), .init(name: "Z.txt", isFolder: false),
        ])))
        #expect(QuickViewLocalFiles.lookSynchronously(at: [QuickViewCandidate(path: "/nowhere/at/all")]) == .missing)
    }

    // MARK: Another Mac's files

    @Test func QuickViewScriptsRunNothingFromPathsAndReportWhatIsThere() async throws {
        let home = try makeDirectory("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let shell = try LocalShell(home: home)
        let hostile = home.appending(path: "it's $(touch pwned) `touch pwned2` \"q\"")
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
        let note = hostile.appending(path: "note\nwith a newline.md")
        try "# Note\n".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: hostile.appending(path: "sub"), withIntermediateDirectories: true)
        try "x".write(to: hostile.appending(path: ".hidden"), atomically: true, encoding: .utf8)
        let secret = home.appending(path: "secret.txt")
        try "no".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path) }

        // The first path that exists, `~/…` expanded there, with its line.
        let relative = "~/" + String(note.path.dropFirst(home.path.count + 1))
        let found = QuickViewRemoteFiles.parseLook(
            await shell.run(QuickViewRemoteFiles.lookScript(candidates: ["/nowhere/x.md", relative])),
            machine: "Studio", lines: [relative: 9]
        )
        guard case let .file(file, line) = found else {
            Issue.record("not found: \(found)")
            return
        }
        #expect(file.path == note.path && file.size == 7 && file.modified != nil && file.isReadable && line == 9)

        // A folder lists its entries, folders first, hidden ones too.
        let listed = QuickViewRemoteFiles.parseLook(
            await shell.run(QuickViewRemoteFiles.lookScript(candidates: [hostile.path])), machine: "Studio"
        )
        guard case let .folder(contents) = listed else {
            Issue.record("not a folder: \(listed)")
            return
        }
        #expect(contents.path == hostile.path && !contents.isTruncated && contents.isReadable)
        #expect(contents.entries.first == .init(name: "sub", isFolder: true))
        #expect(Set(contents.entries) == [
            .init(name: "sub", isFolder: true), .init(name: ".hidden", isFolder: false),
            .init(name: "note\nwith a newline.md", isFolder: false),
        ])
        let capped = QuickViewRemoteFiles.parseLook(
            await shell.run(QuickViewRemoteFiles.lookScript(candidates: [hostile.path], limit: 2)), machine: "Studio"
        )
        if case let .folder(folder) = capped { #expect(folder.isTruncated && folder.entries.count == 2) } else { Issue.record("\(capped)") }

        // Nothing there; a file that cannot be read; the copy's bytes.
        #expect(QuickViewRemoteFiles.parseLook(await shell.run(QuickViewRemoteFiles.lookScript(candidates: ["/nowhere"])), machine: "Studio") == .missing)
        if case let .file(unreadable, _) = QuickViewRemoteFiles.parseLook(await shell.run(QuickViewRemoteFiles.lookScript(candidates: [secret.path])), machine: "Studio") {
            #expect(!unreadable.isReadable)
        } else {
            Issue.record("an unreadable file was not found")
        }
        let copied = try #require(QuickViewRemoteFiles.parseCopy(await shell.run(QuickViewRemoteFiles.copyScript(path: note.path))))
        #expect(copied.size == 7 && copied.bytes == Data("# Note\n".utf8))
        let gone = try #require(QuickViewRemoteFiles.parseCopy(await shell.run(QuickViewRemoteFiles.copyScript(path: secret.path))))
        #expect(gone.bytes == nil)

        // No name ran anything, there or here.
        let pwned = FileManager.default.enumerator(atPath: home.path)?.compactMap { $0 as? String }.filter { $0.contains("pwned") && !$0.contains("$(") && !$0.contains("`") }
        #expect(pwned?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))

        // An answer that never came is a failure, not "nothing there".
        let silent = RemoteDeviceShell.DataOutput(status: 255, standardOutput: Data(), standardError: "ssh: connect to host studio port 22: Connection refused")
        if case .failed = QuickViewRemoteFiles.parseLook(silent, machine: "Studio") {} else { Issue.record("a refused connection was not a failure") }
        #expect(QuickViewRemoteFiles.parseCopy(silent) == nil)
    }

    @Test func QuickViewCopiesAnotherMacsFileOnceAndKeepsItCached() async throws {
        let home = try makeDirectory("copy")
        let cacheDirectory = try makeDirectory("cache")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let shell = try LocalShell(home: home)
        let files = shell.files(cache: QuickViewCache(directory: cacheDirectory))
        // Binary bytes, NULs among them, come through unchanged.
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0x0A, 0xFF, 0, 0x41])
        let image = home.appending(path: "preview.png")
        try bytes.write(to: image)

        guard case let .file(file, _) = await files.look(at: [QuickViewCandidate(path: image.path)]) else {
            Issue.record("the image was not found")
            return
        }
        #expect(file.size == Int64(bytes.count))
        guard case let .local(copy) = await files.copy(file, refresh: false) else {
            Issue.record("not copied")
            return
        }
        #expect(copy.path.hasPrefix(cacheDirectory.path) && copy.lastPathComponent == "preview.png")
        #expect(try Data(contentsOf: copy) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // The same file again: the copy kept, no ssh. Reload copies again.
        let calls = shell.calls
        #expect(await files.copy(file, refresh: false) == .local(copy))
        #expect(shell.calls == calls)
        #expect(await files.copy(file, refresh: true) == .local(copy))
        #expect(shell.calls == calls + 1)

        // Too large to copy: said without asking that Mac.
        var huge = file
        huge.size = QuickViewRemoteFiles.maximumCopyBytes + 1
        #expect(await files.copy(huge, refresh: false) == .tooLarge(QuickViewRemoteFiles.maximumCopyBytes + 1))
        #expect(shell.calls == calls + 1)

        // Gone since it was looked at.
        try FileManager.default.removeItem(at: image)
        #expect(await files.copy(file, refresh: true) == .missing)
    }

    @Test func QuickViewCacheKeepsOneCopyPerFileAndForgetsOldOnes() throws {
        let directory = try makeDirectory("prune")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = QuickViewCache(directory: directory)
        let first = try cache.store(Data("one".utf8), destination: "studio", path: "/a/x.txt", size: 3, modified: 10)
        let second = try cache.store(Data("two!".utf8), destination: "studio", path: "/a/x.txt", size: 4, modified: 20)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(cache.cachedCopy(destination: "studio", path: "/a/x.txt", size: 4, modified: 20) == second)
        #expect(cache.cachedCopy(destination: "studio", path: "/a/x.txt", size: 3, modified: 10) == nil)
        // Another Mac's file of the same path is another copy.
        #expect(cache.fileDirectory(destination: "mini", path: "/a/x.txt") != cache.fileDirectory(destination: "studio", path: "/a/x.txt"))

        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.fileDirectory(destination: "studio", path: "/a/x.txt").path)
        _ = try cache.store(Data("y".utf8), destination: "studio", path: "/b/y.txt", size: 1, modified: 30)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(cache.cachedCopy(destination: "studio", path: "/b/y.txt", size: 1, modified: 30) != nil)
    }

    // MARK: Showing

    @Test func QuickViewShowsTextItselfAndLeavesTheRestToQuickLook() throws {
        let directory = try makeDirectory("present")
        defer { try? FileManager.default.removeItem(at: directory) }
        func presentation(_ name: String, _ data: Data) throws -> QuickViewDocument.Presentation {
            let url = directory.appending(path: name)
            try data.write(to: url)
            return QuickViewDocument.presentation(of: url)
        }
        #expect(try presentation("main.swift", Data("let a = 1\n".utf8)) == .text("let a = 1\n", isTruncated: false))
        #expect(try presentation("README", Data("plain".utf8)) == .text("plain", isTruncated: false))
        // A type no app here declares: text when its bytes are.
        #expect(try presentation("Accordion.qvstory", Data("{\"a\": 1}".utf8)) == .text("{\"a\": 1}", isTruncated: false))
        #expect(try presentation("blob.qvstory", Data([0x41, 0, 0x42])) == .quickLook)
        #expect(try presentation("shot.png", Data("not really".utf8)) == .quickLook)
        #expect(try presentation("page.html", Data("<p>hi</p>".utf8)) == .quickLook)
        #expect(try presentation("doc.pdf", Data("%PDF".utf8)) == .quickLook)

        // A long file shows its start; a character cut in two is left out.
        var long = Data(repeating: 0x61, count: QuickViewDocument.maximumTextBytes - 1)
        long.append(contentsOf: [0xC3, 0xA9, 0x62])
        if case let .text(text, isTruncated) = try presentation("long.txt", long) {
            #expect(isTruncated && text.utf8.count == QuickViewDocument.maximumTextBytes - 1)
        } else {
            Issue.record("a long text file is not text")
        }

        let text = "one\ntwo\nthree"
        #expect(QuickViewDocument.range(ofLine: 1, in: text) == NSRange(location: 0, length: 4))
        #expect(QuickViewDocument.range(ofLine: 3, in: text) == NSRange(location: 8, length: 5))
        #expect(QuickViewDocument.range(ofLine: 4, in: text) == nil)
    }

    @Test func QuickViewModelShowsWhatItFindsAndGoesBackThroughFolders() async throws {
        let directory = try makeDirectory("model")
        defer { try? FileManager.default.removeItem(at: directory) }
        let readme = directory.appending(path: "README.md")
        try "# Hi\n".write(to: readme, atomically: true, encoding: .utf8)
        let machine = QuickViewMachine.remote(name: "Studio", destination: "studio")
        let folder = QuickViewFolder(path: "/Users/them/app", entries: [.init(name: "README.md", isFolder: false)])
        let source = FakeSource(machine: machine, look: { candidates in
            switch candidates.first?.path {
            case "/Users/them/app": .folder(folder)
            case "/Users/them/app/README.md": .file(QuickViewFoundFile(path: "/Users/them/app/README.md", size: 5), line: nil)
            case "/big": .file(QuickViewFoundFile(path: "/big", size: 1), line: nil)
            case "/locked": .file(QuickViewFoundFile(path: "/locked", isReadable: false), line: nil)
            case "/down": .failed("Could not reach Studio.")
            default: .missing
            }
        }, copy: { file, _ in
            file.path == "/big" ? .tooLarge(99) : .local(readme)
        })
        let model = QuickViewModel()
        model.show(.path("/Users/them/app", on: machine), source: source)
        await model.currentLoad?.value
        #expect(model.phase == .folder(folder) && !model.canGoBack && model.title == "app")

        model.open(folder.entries[0])
        await model.currentLoad?.value
        let document = try #require(model.document)
        #expect(document.path == "/Users/them/app/README.md" && document.fileURL == readme && document.machine == machine)
        #expect(document.presentation == .text("# Hi\n", isTruncated: false))
        #expect(model.canGoBack && model.title == "README.md")

        model.goBack()
        await model.currentLoad?.value
        #expect(model.phase == .folder(folder) && !model.canGoBack)

        for (path, expected) in [
            ("/big", QuickViewModel.Phase.tooLarge(QuickViewFoundFile(path: "/big", size: 1), size: 99)),
            ("/locked", .unreadable(QuickViewFoundFile(path: "/locked", isReadable: false))),
            ("/down", .failed("Could not reach Studio.")),
            ("/none", .missing(.path("/none", on: machine))),
        ] {
            model.show(.path(path, on: machine), source: source)
            await model.currentLoad?.value
            #expect(model.phase == expected, Comment(rawValue: path))
        }

        // A load another one replaced is dropped.
        let slow = FakeSource(machine: machine, look: { candidates in
            if candidates.first?.path == "/slow" { try? await Task.sleep(for: .milliseconds(300)) }
            return .missing
        })
        model.show(.path("/slow", on: machine), source: slow)
        let replaced = model.currentLoad
        model.show(.path("/fast", on: machine), source: slow)
        await model.currentLoad?.value
        await replaced?.value
        #expect(model.phase == .missing(.path("/fast", on: machine)))
    }

    @Test func QuickViewStepsThroughAnAgentsSharedFiles() async throws {
        let machine = QuickViewMachine.remote(name: "Studio", destination: "studio")
        let source = FakeSource(machine: machine, look: { candidates in
            .folder(QuickViewFolder(path: candidates[0].path, entries: [.init(name: "inner", isFolder: true)]))
        })
        let model = QuickViewModel()
        model.show([.path("/a", on: machine), .path("/b", on: machine), .path("/c", on: machine)], source: source)
        await model.currentLoad?.value
        #expect(model.items.count == 3 && model.itemIndex == 0 && model.title == "a")
        #expect(!model.canShowPrevious && model.canShowNext)
        model.showItem(offset: -1)
        #expect(model.itemIndex == 0)

        // Into a folder of the first, then on to the next file: its own
        // way back, none of the first's.
        model.open(.init(name: "inner", isFolder: true))
        await model.currentLoad?.value
        #expect(model.canGoBack && model.title == "inner")
        model.showItem(offset: 1)
        await model.currentLoad?.value
        #expect(model.itemIndex == 1 && model.title == "b" && !model.canGoBack)
        model.showItem(offset: 1)
        await model.currentLoad?.value
        #expect(model.itemIndex == 2 && !model.canShowNext)
        model.showItem(offset: 1)
        #expect(model.itemIndex == 2)

        // A click shows one file, forgetting the others.
        model.show(.path("/d", on: machine), source: source)
        await model.currentLoad?.value
        #expect(model.items.count == 1 && model.itemIndex == 0)
    }

    @Test func QuickViewShowsThisMacsFileAgainWhenItChanges() async throws {
        let directory = try makeDirectory("watch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "out.log")
        try "first\n".write(to: file, atomically: false, encoding: .utf8)
        let model = QuickViewModel()
        defer { model.stop() }
        model.show(.path(file.path, on: .thisMac), source: QuickViewLocalFiles())
        await model.currentLoad?.value
        #expect(model.document?.presentation == .text("first\n", isTruncated: false))

        // Written in place, then replaced (as editors and agents save).
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        try await poll("the appended line to show", timeout: 10) {
            model.document?.presentation == .text("first\nsecond\n", isTruncated: false)
        }
        let revision = try #require(model.document?.revision)
        try "replaced\n".write(to: file, atomically: true, encoding: .utf8)
        try await poll("the replaced file to show", timeout: 10) {
            model.document?.presentation == .text("replaced\n", isTruncated: false)
        }
        #expect(try #require(model.document?.revision) > revision)
    }

    @Test func QuickViewOffersWhatEachMacCanDoWithWhatItShows() throws {
        let document = QuickViewDocument(
            fileURL: URL(fileURLWithPath: "/tmp/a.png"), path: "/tmp/a.png", machine: .thisMac, line: nil, size: 1,
            presentation: .quickLook
        )
        let here = QuickViewActionList.make(phase: .file(document), machine: .thisMac, appName: "Preview", editorName: "Zed")
        #expect(here.primary?.title == "Open with Preview")
        #expect(here.more.map(\.title) == ["Open in Zed", "Show in Finder", "Copy Path"])
        let studio = QuickViewMachine.remote(name: "Studio", destination: "studio")
        let there = QuickViewActionList.make(phase: .file(document), machine: studio, appName: nil, editorName: "Zed")
        #expect(there.primary == .init(action: .openInEditor, title: "Open in Zed"))
        #expect(there.more.map(\.action) == [.saveCopy, .copyPath])
        let noEditor = QuickViewActionList.make(phase: .folder(QuickViewFolder(path: "/x", entries: [])), machine: studio, appName: nil, editorName: nil)
        #expect(noEditor.primary == nil && noEditor.more.map(\.action) == [.copyPath])
        #expect(QuickViewActionList.make(phase: .looking("x"), machine: studio, appName: nil, editorName: "Zed") == .init(primary: nil, more: []))
    }

    // MARK: The click

    @Test func QuickViewTakesACmdClickOnThisMacsFileAndLeavesFoldersAndTheRest() throws {
        let seams = QuickViewSeams()
        defer { seams.restore() }
        let root = try makeDirectory("click")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".reference"), withIntermediateDirectories: true)
        try "{}".write(to: root.appending(path: ".reference/Accordion.story"), atomically: true, encoding: .utf8)
        let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
        defer { workspace.closeAllSessions(intent: .windowClosed) }
        let tab = workspace.addSession(title: "Local")

        // A path relative to the tab, with a line: previewed, at the file found.
        #expect(click(".reference/Accordion.story:3", in: tab))
        #expect(seams.presented.count == 1)
        #expect(seams.presented.first?.0.candidates == [
            QuickViewCandidate(path: root.appending(path: ".reference/Accordion.story").path, line: 3),
        ])
        #expect(seams.presented.first?.1 == .thisMac)
        #expect(seams.opened.isEmpty)

        // A folder opens in Finder; a path to nothing is refused, saying why;
        // a web link opens.
        #expect(click(root.appending(path: ".reference").path, in: tab))
        #expect(seams.opened.map(\.path) == [root.appending(path: ".reference").path])
        #expect(click("missing/file.txt", in: tab))
        #expect(seams.toasts.last?.message?.hasPrefix("There is no file or folder at that path on this Mac.") == true)
        #expect(click("https://example.com/a.png", in: tab))
        #expect(seams.opened.last == URL(string: "https://example.com/a.png"))
        #expect(seams.presented.count == 1)
    }

    @Test func QuickViewOffLeavesThisMacsFilesToTheirApp() throws {
        let seams = QuickViewSeams(enabled: false)
        defer { seams.restore() }
        let root = try makeDirectory("off")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "notes.md")
        try "# Notes".write(to: file, atomically: true, encoding: .utf8)
        let workspace = TerminalWorkspace(projectRoot: root.path, createInitialSession: false)
        defer { workspace.closeAllSessions(intent: .windowClosed) }
        let tab = workspace.addSession(title: "Local")
        #expect(click(file.path, in: tab))
        #expect(seams.presented.isEmpty)
        #expect(seams.opened == [file])
    }

    @Test func QuickViewTakesEveryPathLinkInADeviceTabAndLooksForItThere() throws {
        let seams = QuickViewSeams()
        defer { seams.restore() }
        let remotePath = "/Users/them/work/app"
        let key = ProjectLocation.remote(deviceID: UUID(), path: remotePath).key
        let hosting = inertDeviceHosting("studio-quickview", name: "Studio")
        let workspace = TerminalWorkspace(
            projectRoot: key, createInitialSession: false, launchBackend: .nativePTY,
            backendPolicy: .remote(hosting, settings: { .native }, hostReconnects: nil)
        )
        defer { workspace.closeAllSessions(intent: .windowClosed) }
        let tab = workspace.addSession(title: "Agent there")
        let context = try #require(QuickViewOpening.context(of: tab))
        #expect(context.machine == .remote(name: "Studio", destination: "studio-quickview"))
        #expect(context.projectRoot == remotePath)

        // Nothing here is looked at: the path is that Mac's.
        #expect(click("src/app.swift:12", in: tab))
        let (request, machine) = try #require(seams.presented.first)
        #expect(machine == .remote(name: "Studio", destination: "studio-quickview"))
        #expect(request.candidates.contains(QuickViewCandidate(path: remotePath + "/src/app.swift", line: 12)))
        #expect(click("file://studio.local/Users/them/shot.png", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, in: tab))
        #expect(seams.presented.last?.0.candidates == [QuickViewCandidate(path: "/Users/them/shot.png")])
        #expect(seams.opened.isEmpty && seams.toasts.isEmpty)

        // Off: refused as before, naming that Mac.
        QuickViewOpening.isEnabled = { false }
        #expect(click("src/app.swift", in: tab))
        #expect(seams.presented.count == 2)
        #expect(seams.toasts.last?.message?.hasPrefix("The file is on Studio, not on this Mac.") == true)
    }
}
