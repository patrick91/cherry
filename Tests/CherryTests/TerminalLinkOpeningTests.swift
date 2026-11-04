import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing
@testable import Cherry

// A click on a link in terminal output (TerminalLinkOpening, UntrustedLink).
// Ghostty 1.4 refuses an untrusted link its embedder leaves to it, so Cherry
// opens, asks about or refuses each one itself. No test here opens anything,
// presents a sheet or touches the general pasteboard: each injects the seams.

/// Records what `TerminalLinkOpening` would have done, and puts its seams
/// back on `restore()`.
@MainActor
private final class LinkSeams {
    var opened: [URL] = []
    var confirmations: [TerminalLinkOpening.Confirmation] = []
    var toasts: [ProjectWindowToast] = []
    var answer = false
    var application: String? = "Visual Studio Code"

    private let saved = (
        TerminalLinkOpening.opener, TerminalLinkOpening.applicationName,
        TerminalLinkOpening.confirm, TerminalLinkOpening.showToast
    )

    init() {
        TerminalLinkOpening.opener = { [unowned self] in self.opened.append($0) }
        TerminalLinkOpening.applicationName = { [unowned self] _ in self.application }
        TerminalLinkOpening.confirm = { [unowned self] confirmation, _, reply in
            self.confirmations.append(confirmation)
            reply(self.answer)
        }
        TerminalLinkOpening.showToast = { [unowned self] toast, _ in self.toasts.append(toast) }
    }

    func restore() {
        (TerminalLinkOpening.opener, TerminalLinkOpening.applicationName,
         TerminalLinkOpening.confirm, TerminalLinkOpening.showToast) = saved
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "TerminalLink-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Suite(.serialized) @MainActor
struct TerminalLinkOpeningTests {
    // MARK: The rules (Ghostty's UntrustedURLTests, v1.4.0)

    @Test func TerminalLinkAllowsWebAndMailLinks() {
        for value in ["http://example.com", "https://example.com/path", "mailto:user@example.com"] {
            guard case let .allow(url) = UntrustedLink(value).decision else {
                Issue.record("\(value) should open")
                continue
            }
            #expect(url.absoluteString == value)
        }
        for value in ["https:relative", "http:///missing-host"] {
            #expect(UntrustedLink(value).decision == .deny(.invalidWebURL))
        }
        #expect(UntrustedLink("mailto:").decision == .deny(.malformedURL))
    }

    @Test func TerminalLinkRefusesTextWithoutASchemeAndAsksForOtherSchemes() {
        for value in ["/tmp/file.txt", "../file.txt", "payload.command", ""] {
            #expect(UntrustedLink(value).decision == .deny(.malformedURL))
        }
        for value in ["vscode://file/tmp/example.swift", "ssh://example.com"] {
            guard case let .confirm(url) = UntrustedLink(value).decision else {
                Issue.record("\(value) should ask first")
                continue
            }
            #expect(url.absoluteString == value)
        }
        for scalar in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}", "\u{200B}"] {
            #expect(UntrustedLink("https://example.com/before\(scalar)after").decision == .deny(.unsafeCharacters))
        }
        // A file URL naming another host, or with a query.
        #expect(UntrustedLink("file://example.com/etc/hosts").decision == .deny(.malformedURL))
        #expect(UntrustedLink("file:///etc/hosts?x=1").decision == .deny(.malformedURL))
    }

    @Test func TerminalLinkOpensLocalFilesThatRunNothing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = directory.appending(path: "document.txt")
        try "safe".write(to: document, atomically: true, encoding: .utf8)
        #expect(UntrustedLink(document.absoluteString).decision == .allow(document.standardizedFileURL.resolvingSymlinksInPath()))
        // A folder opens in Finder.
        #expect(UntrustedLink(directory.absoluteString).decision == .allow(directory.standardizedFileURL.resolvingSymlinksInPath()))
        #expect(UntrustedLink(directory.appending(path: "missing.txt").absoluteString).decision == .deny(.inaccessibleFile))

        // By extension, by type, by the executable bit, and through a link.
        for name in ["payload.command", "payload.tool", "payload.app", "payload.workflow", "payload.sh"] {
            let file = directory.appending(path: name)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            #expect(UntrustedLink(file.absoluteString).decision == .deny(.unsafeFile), "\(name)")
        }
        let executable = directory.appending(path: "payload.txt")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(UntrustedLink(executable.absoluteString).decision == .deny(.unsafeFile))
        let link = directory.appending(path: "notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appending(path: "payload.command"))
        #expect(UntrustedLink(link.absoluteString).decision == .deny(.unsafeFile))

        // A tab of another Mac names that Mac's files: none opens here,
        // whatever this Mac has at that path. Its web links still open.
        #expect(UntrustedLink(document.absoluteString).decision(filesOn: "Studio") == .deny(.fileOnAnotherMac("Studio")))
        #expect(UntrustedLink("https://example.com").decision(filesOn: "Studio") == .allow(URL(string: "https://example.com")!))
    }

    @Test func TerminalLinkShowsTheLinkAsItWouldOpen() {
        for separator in ["\u{0085}", "\u{2028}", "\u{2029}"] {
            #expect(UntrustedLink("/tmp/preview\(separator)////../payload.command////").displayString == "/tmp/payload.command")
        }
        #expect(UntrustedLink("https://example.com/a\u{202E}b").displayString == "https://example.com/a\\u{202E}b")
        #expect(UntrustedLink("https://example.com//a").displayString == "https://example.com//a")
    }

    // MARK: A Cmd-click's text

    @Test func TerminalLinkReadsACmdClickedPathAsAFile() {
        #expect(TerminalLinkOpening.target(of: "https://example.com/a", kind: .unknown) == "https://example.com/a")
        #expect(TerminalLinkOpening.target(of: "/tmp/a b.txt", kind: .unknown) == "file:///tmp/a%20b.txt")
        let home = TerminalLinkOpening.target(of: "~/notes.txt", kind: .unknown)
        #expect(home.hasPrefix("file:///") && home.hasSuffix("/notes.txt") && !home.contains("~"))
        // Unsafe characters stay, to be refused rather than encoded away.
        let hidden = "/tmp/a\u{202E}b"
        #expect(TerminalLinkOpening.target(of: hidden, kind: .unknown) == hidden)
        #expect(UntrustedLink(TerminalLinkOpening.target(of: hidden, kind: .unknown)).decision == .deny(.unsafeCharacters))
        // An OSC 8 target is taken as sent: a bare path is no URL.
        #expect(TerminalLinkOpening.target(of: "/tmp/x", kind: .osc8) == "/tmp/x")
        #expect(UntrustedLink(TerminalLinkOpening.target(of: "/tmp/x", kind: .osc8)).decision == .deny(.malformedURL))
    }

    // MARK: Opening, asking, refusing

    @Test func TerminalLinkOpensAsksOrRefusesAndLeavesGhosttysOwnLinksToIt() throws {
        let seams = LinkSeams()
        defer { seams.restore() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A web link opens at once.
        #expect(TerminalLinkOpening.open("https://example.com/docs", kind: .unknown, filesOn: nil, window: nil))
        #expect(seams.opened == [URL(string: "https://example.com/docs")!])
        #expect(seams.toasts.isEmpty && seams.confirmations.isEmpty)

        // A Cmd-clicked path to a document opens it.
        seams.opened = []
        let document = directory.appending(path: "notes.md")
        try "# Notes".write(to: document, atomically: true, encoding: .utf8)
        #expect(TerminalLinkOpening.open(document.path, kind: .unknown, filesOn: nil, window: nil))
        #expect(seams.opened == [document.standardizedFileURL.resolvingSymlinksInPath()])

        // Another scheme asks, naming the app; only a yes opens it.
        seams.opened = []
        let custom = URL(string: "vscode://file/tmp/example.swift")!
        #expect(TerminalLinkOpening.open(custom.absoluteString, kind: .osc8, filesOn: nil, window: nil))
        #expect(seams.confirmations == [.init(url: custom, application: "Visual Studio Code", displayString: custom.absoluteString)])
        #expect(seams.opened.isEmpty)
        seams.answer = true
        #expect(TerminalLinkOpening.open(custom.absoluteString, kind: .osc8, filesOn: nil, window: nil))
        #expect(seams.opened == [custom])

        // A scheme no app opens is refused without asking.
        seams.opened = []
        seams.confirmations = []
        seams.application = nil
        #expect(TerminalLinkOpening.open("nothing-opens-this://x", kind: .osc8, filesOn: nil, window: nil))
        #expect(seams.confirmations.isEmpty && seams.opened.isEmpty)
        #expect(seams.toasts.last?.title == "Cherry didn’t open this link")
        #expect(seams.toasts.last?.message == "No app on this Mac opens nothing-opens-this: links.\nnothing-opens-this://x")

        // A script is refused, and says why.
        let script = directory.appending(path: "install.command")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(TerminalLinkOpening.open(script.path, kind: .unknown, filesOn: nil, window: nil))
        #expect(seams.opened.isEmpty)
        #expect(seams.toasts.last?.message?.hasPrefix("Opening it could run code.\n") == true)

        // In a tab of another Mac, a path is that Mac's.
        #expect(TerminalLinkOpening.open(document.path, kind: .unknown, filesOn: "Studio", window: nil))
        #expect(seams.opened.isEmpty)
        #expect(seams.toasts.last?.message?.hasPrefix("The file is on Studio, not on this Mac.\n") == true)

        // A link Ghostty names itself (its configuration) stays Ghostty's.
        let toastCount = seams.toasts.count
        #expect(!TerminalLinkOpening.open(document.path, kind: .text, filesOn: nil, window: nil))
        #expect(!TerminalLinkOpening.open("https://example.com", kind: .html, filesOn: nil, window: nil))
        #expect(seams.opened.isEmpty && seams.toasts.count == toastCount)
    }

    @Test func TerminalLinkRefusalCopiesTheLinkAsShown() throws {
        let pasteboard = NSPasteboard(name: .init("TerminalLinkOpeningTests-\(UUID().uuidString)"))
        let savedPasteboard = TerminalClipboard.pasteboard
        TerminalClipboard.pasteboard = { pasteboard }
        defer {
            TerminalClipboard.pasteboard = savedPasteboard
            pasteboard.releaseGlobally()
        }
        let link = UntrustedLink("https://example.com/a\u{202E}b")
        let toast = TerminalLinkOpening.refusedToast(.unsafeCharacters, link: link)
        #expect(toast.actions.map(\.title) == ["Copy Link"])
        toast.actions.first?.perform()
        #expect(pasteboard.string(forType: .string) == "https://example.com/a\\u{202E}b")
    }

    // MARK: Cherry's bridge

    @Test func TerminalLinkCmdClickInAThisMacTabOpensThroughCherry() {
        let seams = LinkSeams()
        defer { seams.restore() }
        let workspace = TerminalWorkspace(projectRoot: NSTemporaryDirectory(), createInitialSession: false)
        defer { workspace.closeAllSessions(intent: .windowClosed) }
        let tab = workspace.addSession(title: "Local")
        #expect(TerminalLinkOpening.fileMachine(of: tab) == nil)
        #expect(TerminalLinkOpening.fileMachine(of: nil) == nil)

        func click(_ text: String, kind: ghostty_action_open_url_kind_e) -> Bool {
            let buffer = strdup(text)!
            defer { free(buffer) }
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            action.action.open_url = ghostty_action_open_url_s(kind: kind, url: UnsafePointer(buffer), len: UInt(strlen(buffer)))
            return TerminalCallbacks.openURL(action, bridge: TerminalCallbackBridge(delegate: tab.ghosttyBridge))
        }
        // Ghostty is told it was handled (else it refuses it), and it opened.
        #expect(click("https://example.com/a", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN))
        #expect(click("https://example.com/b", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8))
        #expect(seams.opened == [URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!])
        // A link of Ghostty's own goes back to Ghostty.
        #expect(!click("/tmp/config", kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT))
        #expect(seams.opened.count == 2)
    }

    /// A real Cmd-click: a native tab whose program fills its screen with a
    /// link, a ⌘ mouse down and up in the middle of the surface through
    /// NSApp.sendEvent, Ghostty's own link matching and `open_url`. This is
    /// what Ghostty 1.4 broke: it found the link, Cherry left it to Ghostty,
    /// and Ghostty refused it.
    @Test(.timeLimit(.minutes(2)))
    func TerminalLinkCmdClickOnARealSurfaceOpensAsksOrRefuses() async throws {
        _ = NSApplication.shared
        let seams = LinkSeams()
        defer { seams.restore() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Prints its link on every line (as text, or as an OSC 8 hyperlink
        // over other text), then waits.
        let printer = directory.appending(path: "print-link.sh")
        try """
        #!/bin/sh
        i=0
        while [ $i -lt 80 ]; do
          if [ "$1" = osc8 ]; then
            printf '\\033]8;;%s\\033\\\\%s\\033]8;;\\033\\\\\\n' "$2" "open-the-hyperlink-under-this-text"
          else
            printf '%s\\n' "$2"
          fi
          i=$((i + 1))
        done
        exec sleep 120
        """.write(to: printer, atomically: true, encoding: .utf8)
        let script = directory.appending(path: "install.command")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)

        let workspace = TerminalWorkspace(projectRoot: directory.path, createInitialSession: false, launchBackend: .nativePTY)
        let stage = KeyPathStage()
        defer {
            stage.cleanUp()
            workspace.closeAllSessions(intent: .windowClosed)
        }

        func cmdClick(_ mode: String, _ link: String, shows marker: String) async throws {
            let tab = workspace.addSession(title: mode, command: "/bin/sh '\(printer.path)' \(mode) '\(link)'")
            stage.show(tab)
            #expect(tab.ghosttyBridge.isNativePTYBacked)
            try await poll("the \(mode) link to fill the screen", timeout: 30) {
                (tab.ghosttyBridge.readNativeScreenText() ?? "").components(separatedBy: marker).count > 20
            }
            let view = tab.ghosttyBridge.terminalView
            let cellWidth = CGFloat(tab.ghosttyBridge.gridMetrics?.cellWidthPixels ?? 16) / (stage.window.backingScaleFactor)
            // Six cells in (past the 2 pt padding), halfway down: a link.
            let point = view.convert(NSPoint(x: 2 + cellWidth * 6.5, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: stage.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApp.sendEvent(event)
            }
        }

        // A web link opens.
        try await cmdClick("plain", "https://example.com/cherry-link", shows: "https://example.com/cherry-link")
        #expect(seams.opened == [URL(string: "https://example.com/cherry-link")!])

        // A path to a script is refused, with the reason.
        try await cmdClick("plain", script.path, shows: "install.command")
        #expect(seams.opened.count == 1)
        #expect(seams.toasts.last?.message?.hasPrefix("Opening it could run code.\n") == true)

        // An OSC 8 hyperlink to another scheme asks first.
        seams.answer = true
        try await cmdClick("osc8", "vscode://file/tmp/example.swift", shows: "open-the-hyperlink")
        #expect(seams.confirmations.map(\.url) == [URL(string: "vscode://file/tmp/example.swift")!])
        #expect(seams.opened.last == URL(string: "vscode://file/tmp/example.swift")!)
    }
}
