import AppKit
@testable import Cherry
import Testing

// The notes Sparkle's update window shows (`UpdateReleaseNotes`): every
// release between the running build and the update, joined, newest first.

private let repoPage = "https://github.com/patrick91/cherry/releases/tag/"

private func release(
    _ build: String,
    _ version: String,
    channel: String? = "prerelease",
    notes: String? = nil,
    format: String? = "markdown"
) -> UpdateReleaseNotes.Release {
    UpdateReleaseNotes.Release(
        build: build,
        version: version,
        channel: channel,
        notes: notes,
        format: format,
        page: URL(string: repoPage + "v\(version)\(channel == "prerelease" ? "-pre" : "")")
    )
}

/// Build stamps order by their time, as Sparkle's comparator orders them.
private func byBuild(_ build: String, _ other: String) -> ComparisonResult {
    build.compare(other, options: .numeric)
}

private let running = release("20261110160843.0ed361b", "2026.11.10.4", notes: "- Notify an orchestrator's wake turns once")
private let first = release(
    "20261111122405.5807956",
    "2026.11.11.1",
    notes: "- Find a tab by the start of its ID ([5807956](https://github.com/patrick91/cherry/commit/5807956))"
)
private let update = release(
    "20261111150000.22e9624",
    "2026.11.11.2",
    notes: """
    - Name a subscription's tabs `process_ids` where agents read it ([a98faf6](https://github.com/patrick91/cherry/commit/a98faf6))
    - Keep **processIDs** in structured content ([53198a1](https://github.com/patrick91/cherry/commit/53198a1))

    …and 3 more changes.
    """
)
private let later = release("20261112090000.1234567", "2026.11.12.1", notes: "- Not yet")

@Test func appUpdateReleaseNotesAreTheReleasesAfterTheRunningBuildUpToTheUpdate() {
    let stable = release("20261111130000.aaaaaaa", "2026.11.11.1", channel: nil, notes: "- Stable")
    let releases = UpdateReleaseNotes.releases(
        [later, update, stable, first, running, first],
        after: running.build,
        through: update,
        compare: byBuild
    )
    #expect(releases.map(\.build) == [update.build, stable.build, first.build])

    // The update counts when the appcast Sparkle loaded is not at hand.
    #expect(UpdateReleaseNotes.releases([], after: running.build, through: update, compare: byBuild) == [update])
}

@Test func appUpdateReleaseNotesLinkGitHubsComparisonOfTheTwoBuilds() {
    #expect(UpdateReleaseNotes.compareURL(from: running.build, to: update)?.absoluteString
        == "https://github.com/patrick91/cherry/compare/0ed361b...22e9624")
    var elsewhere = update
    elsewhere.page = URL(string: "https://example.com/patrick91/cherry/releases/tag/v1")
    #expect(UpdateReleaseNotes.compareURL(from: running.build, to: elsewhere) == nil)
    #expect(UpdateReleaseNotes.compareURL(from: "dev-20261110.0ed", to: update) == nil)
    #expect(UpdateReleaseNotes.revision(of: "20261110160843.0ed361b") == "0ed361b")
    #expect(UpdateReleaseNotes.revision(of: "20261110160843") == nil)
}

@Test func appUpdateReleaseNotesKeepSparklesOwnWhenOnlyTheUpdateIsNewer() {
    #expect(UpdateReleaseNotes.attributedNotes(
        appcast: [update, running],
        update: update,
        runningVersion: running.version,
        runningBuild: running.build,
        compare: byBuild
    ) == nil)
}

@Test func appUpdateReleaseNotesJoinEveryReleaseNewestFirst() throws {
    let notes = try #require(UpdateReleaseNotes.attributedNotes(
        appcast: [update, first, running],
        update: update,
        runningVersion: running.version,
        runningBuild: running.build,
        compare: byBuild,
        fontSize: 13
    ))
    #expect(notes.string == """
    Cherry 2026.11.11.2 (pre-release)
    •\tName a subscription's tabs process_ids where agents read it (a98faf6)
    •\tKeep processIDs in structured content (53198a1)
    …and 3 more changes.
    Cherry 2026.11.11.1 (pre-release)
    •\tFind a tab by the start of its ID (5807956)
    All changes since 2026.11.10.4 on GitHub
    """)

    let text = notes.string as NSString
    func attribute(_ key: NSAttributedString.Key, at substring: String) -> Any? {
        let range = text.range(of: substring)
        return range.location == NSNotFound ? nil : notes.attribute(key, at: range.location, effectiveRange: nil)
    }
    func font(at substring: String) -> NSFont? { attribute(.font, at: substring) as? NSFont }

    // Headers bold and larger; items in the system font, code in Menlo,
    // their commits linked.
    #expect(font(at: "Cherry 2026.11.11.2")?.pointSize == 13 * 1.2)
    #expect(font(at: "Cherry 2026.11.11.2")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(font(at: "Name a subscription")?.pointSize == 13)
    #expect(font(at: "process_ids")?.isFixedPitch == true)
    #expect(font(at: "Name a subscription")?.isFixedPitch == false)
    #expect(font(at: "processIDs")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect((attribute(.link, at: "a98faf6") as? URL)?.absoluteString == "https://github.com/patrick91/cherry/commit/a98faf6")
    #expect(attribute(.link, at: "Name a subscription") == nil)
    #expect((attribute(.link, at: "All changes since") as? URL)?.absoluteString
        == "https://github.com/patrick91/cherry/compare/0ed361b...22e9624")

    // List items wrap under their text, after the bullet's tab.
    let item = try #require(attribute(.paragraphStyle, at: "Name a subscription") as? NSParagraphStyle)
    #expect(item.headIndent == item.defaultTabInterval)
    #expect(item.defaultTabInterval == 13 * 1.38)
}

@Test func appUpdateReleaseNotesLinkTheReleasePageOfNotesInHTMLOrPlainText() throws {
    let html = release("20261111100000.bbbbbbb", "2026.11.11.0", notes: "<ul><li>Old</li></ul>", format: nil)
    let plain = release("20261111110000.ccccccc", "2026.11.11.05", notes: "- Plain `text`", format: "plain-text")
    let notes = try #require(UpdateReleaseNotes.attributedNotes(
        appcast: [update, plain, html, running],
        update: update,
        runningVersion: running.version,
        runningBuild: running.build,
        compare: byBuild
    ))
    let text = notes.string as NSString
    #expect(notes.string.contains("Cherry 2026.11.11.05 (pre-release)\n•\tPlain `text`\nCherry 2026.11.11.0 (pre-release)\nRelease notes\n"))
    #expect(!notes.string.contains("<ul>"))
    let link = notes.attribute(.link, at: text.range(of: "Release notes").location, effectiveRange: nil) as? URL
    #expect(link == html.page)
}
