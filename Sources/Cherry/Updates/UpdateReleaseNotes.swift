import AppKit

/// The notes Sparkle's update window shows: those of every release between
/// the running build and the update, not only the update's own. Each appcast
/// item's notes list the commits since the release before it (markdown,
/// `sparkle:format`; docs/releasing.md), so Cherry joins them, newest first,
/// under a header per release, and links GitHub's comparison of the two
/// builds. `SparkleBridge` gives it the appcast Sparkle loaded and calls it
/// from `standardUserDriverWillShowReleaseNotesText`, which Sparkle calls only
/// for markdown and plain-text notes. No Sparkle here: AppUpdater.swift
/// turns `SUAppcastItem`s into `Release`s and passes Sparkle's comparator.
enum UpdateReleaseNotes {
    /// An appcast item, as far as its notes go.
    struct Release: Equatable {
        /// `sparkle:version`: the build stamp `<YYYYMMDDHHMMSS>.<rev>`.
        var build: String
        /// `sparkle:shortVersionString`.
        var version: String
        var channel: String?
        /// The item's `<description>`, and its `sparkle:format` (`html`
        /// when it names none).
        var notes: String?
        var format: String?
        /// The release's page (`<link>`).
        var page: URL?
    }

    /// The releases after `runningBuild`, up to `update` (included), newest
    /// first, one per build. `update` counts even if the appcast Sparkle
    /// loaded is not at hand.
    static func releases(
        _ appcast: [Release],
        after runningBuild: String,
        through update: Release,
        compare: (String, String) -> ComparisonResult
    ) -> [Release] {
        var seen: Set<String> = []
        let between = ([update] + appcast).filter { release in
            compare(release.build, runningBuild) == .orderedDescending
                && compare(release.build, update.build) != .orderedDescending
                && seen.insert(release.build).inserted
        }
        return between.sorted { compare($0.build, $1.build) == .orderedDescending }
    }

    /// GitHub's comparison of the two builds' commits (each build stamp ends
    /// in its commit), on the repository of the update's page; nil when
    /// either is not to be had.
    static func compareURL(from runningBuild: String, to update: Release) -> URL? {
        guard let page = update.page, page.host == "github.com",
              let from = revision(of: runningBuild), let to = revision(of: update.build)
        else { return nil }
        let parts = page.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/compare/\(from)...\(to)")
    }

    /// The commit a build stamp ends in (`20261110160843.0ed361b`).
    static func revision(of build: String) -> String? {
        guard let dot = build.lastIndex(of: ".") else { return nil }
        let revision = build[build.index(after: dot)...]
        guard revision.count >= 7, revision.allSatisfy(\.isHexDigit) else { return nil }
        return String(revision)
    }

    /// The window's notes for `update`, or nil to keep Sparkle's own: none
    /// but the update comes after the running build.
    static func attributedNotes(
        appcast: [Release],
        update: Release,
        runningVersion: String,
        runningBuild: String,
        compare: (String, String) -> ComparisonResult,
        fontSize: CGFloat = CGFloat(Int(NSFont.systemFontSize))
    ) -> NSAttributedString? {
        let releases = releases(appcast, after: runningBuild, through: update, compare: compare)
        guard releases.count > 1 else { return nil }
        let text = Text(fontSize: fontSize)
        for release in releases {
            text.header(release.channel == "prerelease" ? "Cherry \(release.version) (pre-release)" : "Cherry \(release.version)")
            text.notes(of: release)
        }
        if let compareURL = compareURL(from: runningBuild, to: update) {
            text.paragraph(NSAttributedString(
                string: "All changes since \(runningVersion) on GitHub",
                attributes: [.link: compareURL]
            ))
        }
        return text.output
    }

    /// Builds the notes as Sparkle formats markdown (SUTextViewReleaseNotesView's
    /// `formatMarkdownAttributedString`): the system font at Sparkle's size,
    /// headers bold and larger, list items after a Menlo bullet and a tab,
    /// spacing in fractions of the font size, colors left to the text view.
    private final class Text {
        let output = NSMutableAttributedString()
        private let font: NSFont
        private let monospacedFont: NSFont
        private let headerFont: NSFont
        private let bullet: NSAttributedString
        private let tabInterval: CGFloat

        init(fontSize: CGFloat) {
            font = NSFont.systemFont(ofSize: fontSize)
            monospacedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            headerFont = NSFont.boldSystemFont(ofSize: fontSize * 1.2)
            bullet = NSAttributedString(string: "•", attributes: [.font: NSFont(name: "Menlo Regular", size: fontSize) ?? font])
            tabInterval = font.pointSize * 1.38
        }

        func header(_ title: String) {
            let spacing = headerFont.pointSize * 0.8
            append(NSAttributedString(string: title, attributes: [.font: headerFont]), before: output.length > 0 ? spacing : 0, after: spacing)
        }

        /// A release's notes: its list items as items, other lines as
        /// paragraphs. Notes in HTML (a release from before the appcast's
        /// were markdown) link the release's page instead.
        func notes(of release: Release) {
            let format = release.format?.lowercased() ?? "html"
            guard format == "markdown" || format == "plain-text" else {
                if let page = release.page {
                    paragraph(NSAttributedString(string: "Release notes", attributes: [.link: page, .font: font]))
                }
                return
            }
            for rawLine in (release.notes ?? "").components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if let item = Self.listItemText(line) {
                    listItem(inline(item, markdown: format == "markdown"))
                } else {
                    paragraph(inline(line, markdown: format == "markdown"))
                }
            }
        }

        func paragraph(_ content: NSAttributedString) {
            let spacing = font.pointSize * 0.5
            append(withFont(content), before: spacing, after: spacing)
        }

        private func listItem(_ content: NSAttributedString) {
            let line = NSMutableAttributedString(attributedString: bullet)
            line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            line.append(withFont(content))
            append(line, before: 0, after: font.pointSize * 0.3, headIndent: tabInterval)
        }

        /// `- item` or `* item`.
        private static func listItemText(_ line: String) -> String? {
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
            return nil
        }

        /// A line's inline markdown: links and code spans (in Menlo); the
        /// line as it is when it is plain text or does not parse.
        private func inline(_ line: String, markdown: Bool) -> NSAttributedString {
            guard markdown, let parsed = try? NSAttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
                baseURL: nil
            ) else {
                return NSAttributedString(string: line, attributes: [.font: font])
            }
            let styled = NSMutableAttributedString(attributedString: parsed)
            let whole = NSRange(location: 0, length: styled.length)
            styled.addAttribute(.font, value: font, range: whole)
            styled.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                if intent.contains(.code) {
                    styled.addAttribute(.font, value: monospacedFont, range: range)
                } else if intent.contains(.stronglyEmphasized) {
                    styled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: range)
                }
            }
            return styled
        }

        /// `content` with the paragraph font where it has none.
        private func withFont(_ content: NSAttributedString) -> NSAttributedString {
            let styled = NSMutableAttributedString(attributedString: content)
            styled.enumerateAttribute(.font, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
                if value == nil { styled.addAttribute(.font, value: font, range: range) }
            }
            return styled
        }

        private func append(_ content: NSAttributedString, before: CGFloat, after: CGFloat, headIndent: CGFloat = 0) {
            if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.tabStops = []
            style.defaultTabInterval = tabInterval
            style.headIndent = headIndent
            let start = output.length
            output.append(content)
            output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        }
    }
}
