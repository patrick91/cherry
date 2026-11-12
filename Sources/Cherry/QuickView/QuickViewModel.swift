import AppKit
import Foundation
import UniformTypeIdentifiers

/// A file Quick View shows, as a file here.
struct QuickViewDocument: Equatable, Sendable {
    enum Presentation: Equatable, Sendable {
        /// Text Cherry shows itself (monospaced, at the link's line): plain
        /// text, source, and files of a type no app here declares whose
        /// bytes read as UTF-8.
        case text(String, isTruncated: Bool)
        /// Quick Look's preview (images, PDF, media, rich text, documents,
        /// and anything else a Quick Look extension here shows).
        case quickLook
    }

    /// The file here: the file itself on This Mac, its copy for another.
    let fileURL: URL
    /// Its path on its Mac.
    let path: String
    let machine: QuickViewMachine
    /// The line its link named.
    let line: Int?
    let size: Int64?
    let presentation: Presentation
    /// Bumped when the same file is shown again after it changed, so the
    /// preview reads it again.
    var revision = 0

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// The most text Cherry shows of a file.
    static let maximumTextBytes = 4 * 1024 * 1024

    /// The document for `fileURL`, read off the main actor.
    static func make(fileURL: URL, path: String, machine: QuickViewMachine, line: Int?, size: Int64?) async -> QuickViewDocument {
        let presentation = await Task.detached(priority: .userInitiated) { Self.presentation(of: fileURL) }.value
        return QuickViewDocument(fileURL: fileURL, path: path, machine: machine, line: line, size: size, presentation: presentation)
    }

    /// How a file is shown: by its type, and for a type that may be text,
    /// by whether its first `maximumTextBytes` read as UTF-8 without NULs.
    static func presentation(of fileURL: URL) -> Presentation {
        guard mayBeText(type: UTType(filenameExtension: fileURL.pathExtension)),
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return .quickLook }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumTextBytes + 1) ?? Data() else { return .quickLook }
        let isTruncated = data.count > maximumTextBytes
        guard let text = text(of: isTruncated ? data.prefix(maximumTextBytes) : data) else { return .quickLook }
        return .text(text, isTruncated: isTruncated)
    }

    /// Whether a file of `type` may be shown as text: no type (no
    /// extension), a type no app here declares, or one that is plain text,
    /// source, JSON, XML or YAML. Images (SVG is XML too), PDF, media, rich
    /// text, HTML and documents are Quick Look's.
    static func mayBeText(type: UTType?) -> Bool {
        guard let type else { return true }
        if type.isDynamic { return true }
        let quickLooks: [UTType] = [.image, .pdf, .audiovisualContent, .rtf, .rtfd, .flatRTFD, .html, .webArchive]
        if quickLooks.contains(where: { type.conforms(to: $0) }) { return false }
        let texts: [UTType] = [.plainText, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .tabSeparatedText, .log]
        return texts.contains(where: { type.conforms(to: $0) })
    }

    /// `data` as text when it is UTF-8 (a character the read cut in two at
    /// its end aside) without NULs; nil otherwise.
    static func text(of data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        for cut in 1...3 where data.count > cut {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        return nil
    }

    /// The range of line `line` (1-based) in `text`, as NSString counts;
    /// nil past its end.
    static func range(ofLine line: Int, in text: String) -> NSRange? {
        guard line > 0 else { return nil }
        let string = text as NSString
        var start = 0
        var current = 1
        while current < line {
            let next = string.range(of: "\n", options: [], range: NSRange(location: start, length: string.length - start))
            guard next.location != NSNotFound else { return nil }
            start = next.location + 1
            current += 1
        }
        guard start <= string.length else { return nil }
        return string.lineRange(for: NSRange(location: start, length: 0))
    }
}

/// What Quick View shows, one link (or folder entry) at a time, with the
/// way back through the folders it went into; an agent's several files
/// (`cherry preview`) one after another.
@MainActor
final class QuickViewModel: ObservableObject {
    enum Phase: Equatable {
        /// Looking for the link's file (another Mac's take a moment).
        case looking(String)
        /// Copying a file from another Mac.
        case copying(QuickViewFoundFile)
        case file(QuickViewDocument)
        case folder(QuickViewFolder)
        /// Nothing at any of the request's paths.
        case missing(QuickViewRequest)
        /// Something that is no file or folder.
        case special(String)
        /// Larger than Quick View copies from another Mac.
        case tooLarge(QuickViewFoundFile, size: Int64)
        /// A file that cannot be read.
        case unreadable(QuickViewFoundFile)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .looking("")
    @Published private(set) var request: QuickViewRequest?
    @Published private(set) var canGoBack = false
    /// The files shown one after another (one for a click).
    @Published private(set) var items: [QuickViewRequest] = []
    @Published private(set) var itemIndex = 0

    private(set) var source: QuickViewFileSource?
    private var history: [QuickViewRequest] = []
    private var loading: Task<Void, Never>?
    /// The current load; a load's results are dropped once another began.
    private var generation = 0
    /// Watches a shown This Mac file and shows it again when it changes.
    private var watch: QuickViewFileWatch?

    var machine: QuickViewMachine {
        request?.machine ?? .thisMac
    }

    /// The path shown (the file's or folder's once found, else the link).
    var shownPath: String? {
        switch phase {
        case let .file(document): document.path
        case let .folder(folder): folder.path
        case let .copying(file), let .tooLarge(file, _), let .unreadable(file): file.path
        case let .special(path): path
        case .looking, .missing, .failed: request?.linkText
        }
    }

    /// The name the title shows.
    var title: String {
        guard let path = shownPath, !path.isEmpty else { return "Quick View" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The file shown, when one is.
    var document: QuickViewDocument? {
        if case let .file(document) = phase { return document }
        return nil
    }

    /// The latest load (tests wait for it).
    var currentLoad: Task<Void, Never>? {
        loading
    }

    /// Shows what `request` names, from `source` (its Mac's files),
    /// forgetting the folders it went through.
    func show(_ request: QuickViewRequest, source: QuickViewFileSource) {
        show([request], source: source)
    }

    /// Shows `requests` one after another, the first now.
    func show(_ requests: [QuickViewRequest], source: QuickViewFileSource) {
        guard let first = requests.first else { return }
        self.source = source
        items = requests
        itemIndex = 0
        history = []
        load(first, refresh: false)
    }

    var canShowPrevious: Bool { itemIndex > 0 }
    var canShowNext: Bool { itemIndex + 1 < items.count }

    /// The file before or after the one shown (`offset` -1 or 1).
    func showItem(offset: Int) {
        let index = itemIndex + offset
        guard items.indices.contains(index) else { return }
        itemIndex = index
        history = []
        load(items[index], refresh: false)
    }

    /// Goes into a folder entry: a file shows, a folder lists.
    func open(_ entry: QuickViewFolder.Entry) {
        guard case let .folder(folder) = phase, let request else { return }
        history.append(request)
        let path = folder.path == "/" ? "/" + entry.name : folder.path + "/" + entry.name
        load(.path(path, on: machine), refresh: false)
    }

    /// Back to the folder it came from.
    func goBack() {
        guard let previous = history.popLast() else { return }
        load(previous, refresh: false)
    }

    /// Reads what is shown again (another Mac's file is copied again).
    func reload() {
        guard let request else { return }
        load(request, refresh: true)
    }

    /// Stops loading and watching (the panel closed).
    func stop() {
        generation += 1
        loading?.cancel()
        loading = nil
        watch = nil
    }

    private func load(_ request: QuickViewRequest, refresh: Bool) {
        guard let source else { return }
        generation += 1
        let generation = generation
        loading?.cancel()
        watch = nil
        self.request = request
        canGoBack = !history.isEmpty
        let previous = document
        if !refresh || document == nil {
            phase = .looking(request.linkText)
        }
        loading = Task { [weak self] in
            let look = await source.look(at: request.candidates)
            guard let self, self.generation == generation else { return }
            switch look {
            case .missing:
                phase = .missing(request)
            case let .failed(message):
                phase = .failed(message)
            case let .special(path):
                phase = .special(path)
            case let .folder(folder):
                phase = .folder(folder)
            case let .file(file, line):
                await showFile(file, line: line, source: source, refresh: refresh, previous: previous, generation: generation)
            }
        }
    }

    private func showFile(
        _ file: QuickViewFoundFile, line: Int?, source: QuickViewFileSource, refresh: Bool,
        previous: QuickViewDocument?, generation: Int
    ) async {
        guard file.isReadable else {
            phase = .unreadable(file)
            return
        }
        if source.machine.isRemote, !refresh || previous == nil {
            phase = .copying(file)
        }
        let copy = await source.copy(file, refresh: refresh)
        guard self.generation == generation else { return }
        switch copy {
        case let .local(url):
            var document = await QuickViewDocument.make(
                fileURL: url, path: file.path, machine: source.machine, line: line, size: file.size
            )
            guard self.generation == generation else { return }
            if let previous, previous.path == document.path {
                document.revision = previous.revision + 1
            }
            phase = .file(document)
            if !source.machine.isRemote {
                watch = QuickViewFileWatch(path: url.path) { [weak self] in self?.reload() }
            }
        case let .tooLarge(size):
            phase = .tooLarge(file, size: size)
        case .missing:
            phase = .missing(request ?? .path(file.path, on: source.machine))
        case let .failed(message):
            phase = .failed(message)
        }
    }
}

/// Calls `changed` (on the main actor, at most every 0.3 s) when a file of
/// This Mac is written, replaced or removed, until it is released.
@MainActor
final class QuickViewFileWatch {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(path: String, changed: @escaping @MainActor () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                let work = DispatchWorkItem { MainActor.assumeIsolated { changed() } }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    isolated deinit {
        pending?.cancel()
        source?.cancel()
    }
}
