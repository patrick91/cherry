import AppKit
import GhosttyTerminal
import UniformTypeIdentifiers

/// A link terminal output chose: a Cmd-click on text a `link` pattern
/// matched, or an OSC 8 hyperlink (`TerminalOpenURLKind.isUntrusted`). Any
/// program in the terminal can print one, so it never goes to Launch
/// Services unchecked: web and mail links open, a local file or folder opens
/// unless opening it could run code, another scheme asks first, and anything
/// else is refused.
///
/// The rules are Ghostty's macOS app's (`macos/Sources/Helpers/UntrustedURL.swift`
/// at v1.4.0, MIT), which the embedded Ghostty no longer applies for us:
/// since 1.4 it refuses an untrusted link its embedder leaves to it.
struct UntrustedLink: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile
        /// A file a tab of another Mac names: it is on that Mac.
        case fileOnAnotherMac(String)
        /// A scheme no app on this Mac opens.
        case noHandler(String)

        var message: String {
            switch self {
            case .malformedURL:
                "It is not a complete URL."
            case .unsafeCharacters:
                "It contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web address names no server."
            case .inaccessibleFile:
                "There is no file or folder at that path on this Mac."
            case .unsafeFile:
                "Opening it could run code."
            case let .fileOnAnotherMac(machine):
                "The file is on \(machine), not on this Mac."
            case let .noHandler(scheme):
                "No app on this Mac opens \(scheme): links."
            }
        }
    }

    enum Decision: Equatable {
        /// Opens at once: a scheme whose handler runs nothing it is given.
        case allow(URL)
        /// Asks first: another scheme can reach any app registered for it.
        case confirm(URL)
        /// Never opens.
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        decision(filesOn: nil)
    }

    /// The decision for a link a tab of `machine` printed (nil: This Mac):
    /// a file link there names that Mac's file, never one here.
    func decision(filesOn machine: String?) -> Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation takes control and formatting characters in a URL that
        // AppKit then draws as line breaks, nothing or reversed text, so the
        // link shown would not be the link opened.
        guard !Self.containsUnsafeCharacters(string) else {
            return .deny(.unsafeCharacters)
        }

        // A relative reference has no scheme: something later could read it
        // as a local path.
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            // "https:relative" has a scheme and no authority, which handlers
            // resolve against different bases.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)

        case "mailto":
            // A bare "mailto:" would open an empty message.
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)

        case "file":
            if let machine { return .deny(.fileOnAnotherMac(machine)) }
            return Self.fileDecision(for: url)

        default:
            return .confirm(url)
        }
    }

    /// Whether `value` has control, invisible or text-reversing characters.
    /// Check before making a URL of it, which can percent-encode them.
    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeCharacter)
    }

    /// The link on one line as it would open: a path standardized (so `..`
    /// and repeated slashes cannot hide where it goes), then every unsafe
    /// character written out as `\u{…}`.
    var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            // Other schemes stay byte for byte: their handlers may read
            // repeated separators.
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            normalized = URL(filePath: string).standardizedFileURL.path
        }
        var result = ""
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func fileDecision(for url: URL) -> Decision {
        // Queries and fragments name no part of a file, and handlers read
        // them differently.
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }
        // Only this Mac: a file URL naming another host could reach the
        // network.
        if let host = url.host, !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }
        // Judge what the path leads to, not how the output spelled it: `..`
        // and a harmless-looking link name must not hide an executable.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(forKeys: [
                .contentTypeKey, .isDirectoryKey, .isExecutableKey, .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }
        // No devices, sockets or other special files. A folder opens in
        // Finder unless it is an app bundle.
        guard values.isDirectory == true || values.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !isUnsafeFile(canonical, values: values) else {
            return .deny(.unsafeFile)
        }
        return .allow(canonical)
    }

    private static func isUnsafeFile(_ url: URL, values: URLResourceValues) -> Bool {
        // Launch Services picks a handler by extension, so these run even
        // without the executable bit.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        // The type catches a missing or misleading extension (shell
        // scripts, app bundles).
        if let type = values.contentType,
           unsafeContentTypes.contains(where: { type.conforms(to: $0) }) {
            return true
        }
        return values.isDirectory != true && values.isExecutable == true
    }

    private static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 and C1 controls: CR, LF, NEL and other unprinted bytes.
        case 0x00...0x1F, 0x7F...0x9F:
            true
        // Directional marks and zero-width characters reorder or hide text.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        // Line and paragraph separators.
        case 0x2028...0x2029:
            true
        // Word joiner and byte order mark: invisible padding.
        case 0x2060, 0xFEFF:
            true
        default:
            false
        }
    }

    private static let unsafePathExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop", "inetloc", "jar",
        "mobileconfig", "mpkg", "pkg", "scpt", "terminal", "tool", "url", "webloc", "workflow",
    ]

    private static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
}

/// What a click on a link in a terminal does
/// (`GhosttySessionBridge.terminalShouldHandleOpenURL`): an untrusted link
/// (`TerminalOpenURLKind.isUntrusted`) opens, asks or is refused by
/// `UntrustedLink`'s rules, and a refusal says why in a toast; a link
/// Ghostty itself names (`text`, `html`) stays Ghostty's to open.
@MainActor
enum TerminalLinkOpening {
    /// Asking before a link of another scheme opens.
    struct Confirmation: Equatable {
        let url: URL
        /// The app that would open it ("Visual Studio Code").
        let application: String
        /// The link as `UntrustedLink.displayString` shows it.
        let displayString: String
    }

    /// Test seams. The defaults present on the next main-loop turn: Ghostty
    /// calls `open_url` from its mouse handling with its renderer's lock
    /// held, and a sheet's drawing must not run under it.
    static var opener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var applicationName: @MainActor (URL) -> String? = { url in
        NSWorkspace.shared.urlForApplication(toOpen: url).map { $0.deletingPathExtension().lastPathComponent }
    }
    static var confirm: @MainActor (Confirmation, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = { confirmation, window, answer in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { presentConfirmation(confirmation, window: window, answer: answer) }
        }
    }
    static var showToast: @MainActor (ProjectWindowToast, NSWindow?) -> Void = { toast, window in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let window, let chromeState = ProjectWindowRegistry.shared.chromeState(for: window) else { return }
                chromeState.toasts.show(toast)
            }
        }
    }

    /// What Ghostty's macOS app opens for a Cmd-click's text: the text when
    /// it has a scheme, else a path (`~` expanded) as a file URL, so a path
    /// is judged as a file and not refused for lacking a scheme. An OSC 8
    /// target is taken as the program sent it.
    static func target(of text: String, kind: TerminalOpenURLKind) -> String {
        guard kind == .unknown else { return text }
        // Unsafe characters stay in, to be refused before a file URL
        // percent-encodes them out of sight.
        if URL(string: text)?.scheme != nil || UntrustedLink.containsUnsafeCharacters(text) {
            return text
        }
        return URL(filePath: NSString(string: text).standardizingPath).absoluteString
    }

    /// The Mac whose files a link in `session` names, when it is not this
    /// one: a tab of a device or an SSH host.
    static func fileMachine(of session: TerminalSession?) -> String? {
        guard let hosting = session?.persistentHosting, !hosting.profile.isThisMac else { return nil }
        return hosting.profile.displayName
    }

    /// Opens, asks about or refuses a link of `kind` a terminal in `window`
    /// was clicked on: true when it was Cherry's to decide (every untrusted
    /// link, so Ghostty does not refuse it again), false for one Ghostty
    /// names itself.
    @discardableResult
    static func open(_ text: String, kind: TerminalOpenURLKind, filesOn machine: String?, window: NSWindow?) -> Bool {
        guard kind.isUntrusted else { return false }
        let link = UntrustedLink(target(of: text, kind: kind))
        switch link.decision(filesOn: machine) {
        case let .allow(url):
            opener(url)
        case let .confirm(url):
            guard let application = applicationName(url) else {
                showToast(refusedToast(.noHandler(url.scheme ?? ""), link: link), window)
                break
            }
            confirm(Confirmation(url: url, application: application, displayString: link.displayString), window) { allowed in
                if allowed { opener(url) }
            }
        case let .deny(reason):
            showToast(refusedToast(reason, link: link), window)
        }
        return true
    }

    /// The toast for a link Cherry did not open: why, the link, and a way
    /// to copy it (the shown, escaped form) instead.
    static func refusedToast(_ reason: UntrustedLink.DenialReason, link: UntrustedLink) -> ProjectWindowToast {
        let shown = link.displayString
        return ProjectWindowToast(
            title: "Cherry didn’t open this link",
            message: "\(reason.message)\n\(shown)",
            action: .init(title: "Copy Link") {
                let pasteboard = TerminalClipboard.pasteboard()
                pasteboard.clearContents()
                pasteboard.setString(shown, forType: .string)
            }
        )
    }

    /// A sheet on `window` asking whether to open the link, Cancel the
    /// default; without a window it does not open.
    private static func presentConfirmation(
        _ confirmation: Confirmation,
        window: NSWindow?,
        answer: @escaping @MainActor (Bool) -> Void
    ) {
        guard let window else {
            answer(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this link in “\(confirmation.application)”?"
        alert.informativeText = "A program in this terminal printed it. Open it only if you recognize and trust where it goes."
        alert.accessoryView = linkView(confirmation.displayString)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        RemoteViewCrashGuard.installIfNeeded()
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .alertSecondButtonReturn) }
        }
    }

    /// The link in a small scrolling, selectable monospaced box.
    private static func linkView(_ text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = text
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }
}
