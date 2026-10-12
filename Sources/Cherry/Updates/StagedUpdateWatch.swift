import Foundation
import os

/// While a build is staged (.ready with a block), every `interval` (2 h): fetch SUFeedURL
/// (ephemeral URLSession, reloadIgnoringLocalCacheData, 30 s timeout) and parse it (XMLParser,
/// namespaces on). When the answer is HTTP 200 and holds at least one <item>, and the staged
/// build's sparkle:version is absent from every item or is listed in <cherry:pulled>, call
/// `onGone` once. Any failure (network, status, parse, zero items) does nothing.
@MainActor
final class StagedUpdateWatch {
    /// Sparkle's appcast namespace.
    nonisolated static let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    /// Cherry's own appcast elements (`<cherry:pulled version="V">BUILD</cherry:pulled>`),
    /// which Sparkle ignores: it reads only /rss/channel/item.
    nonisolated static let cherryNamespace = "https://updates.cherry.patrick.wtf/xmlns/appcast"

    private let feedURL: URL
    private let interval: Duration
    private let fetch: @Sendable (URL) async throws -> (Data, Int)
    private let onGone: @MainActor (_ build: String) -> Void
    private var task: Task<Void, Never>?
    /// The build watched now.
    private(set) var build: String?
    private let logger = Logger(subsystem: SessionLog.subsystem, category: "Updates")

    init(
        feedURL: URL,
        interval: Duration = .seconds(7200),
        fetch: @escaping @Sendable (URL) async throws -> (Data, Int),
        onGone: @escaping @MainActor (_ build: String) -> Void
    ) {
        self.feedURL = feedURL
        self.interval = interval
        self.fetch = fetch
        self.onGone = onGone
    }

    /// Watches `build`; nil stops it.
    func watch(build: String?) {
        guard build != self.build else { return }
        task?.cancel()
        task = nil
        self.build = build
        guard build != nil else { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if await self.check() { return }
            }
        }
    }

    /// One look at the feed for the watched build. True when it was gone
    /// (`onGone` was called and the watch stopped).
    @discardableResult
    func check() async -> Bool {
        guard let build else { return false }
        let fetched: (Data, Int)
        do {
            fetched = try await fetch(feedURL)
        } catch {
            logger.info("the feed could not be read: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // The build may have changed or stopped while the feed was read.
        guard self.build == build else { return false }
        guard fetched.1 == 200 else {
            logger.info("the feed answered HTTP \(fetched.1, privacy: .public)")
            return false
        }
        guard let feed = Self.parse(fetched.0), !feed.versions.isEmpty else {
            logger.info("the feed lists no items")
            return false
        }
        guard !feed.versions.contains(build) || feed.pulled.contains(build) else { return false }
        logger.info("the staged build \(build, privacy: .public) was pulled from the feed")
        task?.cancel()
        task = nil
        self.build = nil
        onGone(build)
        return true
    }

    /// Reads the feed: a fresh copy, never a cached one.
    nonisolated static let fetchFeed: @Sendable (URL) async throws -> (Data, Int) = { url in
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Pure, for tests: the item versions and the pulled builds of a feed.
    nonisolated static func parse(_ data: Data) -> (versions: Set<String>, pulled: Set<String>)? {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return (reader.versions, reader.pulled)
    }
}

/// Collects `<item>`s' sparkle:version (the element, else the enclosure's
/// attribute) and `<cherry:pulled>` builds.
private final class FeedReader: NSObject, XMLParserDelegate {
    var versions: Set<String> = []
    var pulled: Set<String> = []
    private var itemDepth = 0
    private var itemVersion: String?
    private var enclosureVersion: String?
    private var text: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch (namespaceURI ?? "", elementName) {
        case ("", "item"):
            itemDepth += 1
            itemVersion = nil
            enclosureVersion = nil
        case ("", "enclosure") where itemDepth > 0:
            enclosureVersion = attributes["sparkle:version"]
        case (StagedUpdateWatch.sparkleNamespace, "version") where itemDepth > 0,
             (StagedUpdateWatch.cherryNamespace, "pulled"):
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if text != nil, let string = String(data: CDATABlock, encoding: .utf8) {
            text?.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (namespaceURI ?? "", elementName) {
        case ("", "item") where itemDepth > 0:
            itemDepth -= 1
            if let version = itemVersion ?? enclosureVersion, !version.isEmpty {
                versions.insert(version)
            }
        case (StagedUpdateWatch.sparkleNamespace, "version") where itemDepth > 0:
            itemVersion = value
            text = nil
        case (StagedUpdateWatch.cherryNamespace, "pulled"):
            if let value, !value.isEmpty { pulled.insert(value) }
            text = nil
        default:
            break
        }
    }
}
