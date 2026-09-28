import AppKit
import CherryControl
import Foundation

// Images pasted into terminals. A terminal takes text only, so a screenshot
// on the pasteboard pastes nothing by itself; agents (Claude Code, Codex)
// attach an image whose path they are given. On ⌘V with image data and no
// text (nor file URLs, which paste as before), Cherry writes the image as a
// PNG to its cache folder and pastes the file's path, quoted for a shell and
// bracketed as any paste. A tab of another Mac gets the path of a copy made
// there (`RemoteFileDropCoordinator`), and Ctrl+V in an agent tab of another
// Mac puts the image on that Mac's clipboard first
// (`RemoteClipboardImagePaste`), since the agent reads its own Mac's.

/// What a paste carries: file URLs first (Finder puts the files' names on
/// the pasteboard as text too), then text, then image data. A tab of This
/// Mac pastes files and text as before; a tab of another Mac copies files.
enum PastedContent: Equatable {
    case text
    case files([URL])
    /// Image data (PNG, TIFF, HEIC, …) with no text and no file URLs,
    /// already as PNG.
    case image(Data)
    case nothing

    init(pasteboard: NSPasteboard) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            self = .files(urls.map(\.standardizedFileURL))
        } else if pasteboard.string(forType: .string)?.isEmpty == false {
            self = .text
        } else if let png = PastedImage.pngData(from: pasteboard) {
            self = .image(png)
        } else {
            self = .nothing
        }
    }

    /// The PNG of an image-only pasteboard.
    var image: Data? {
        if case .image(let data) = self { return data }
        return nil
    }
}

enum PastedImage {
    /// The pasteboard's image as PNG: its PNG as it is, anything else
    /// NSImage reads (TIFF, HEIC, JPEG, PDF) converted. Nil when it has no
    /// image.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), NSBitmapImageRep(data: data) != nil {
            return data
        }
        let types: [NSPasteboard.PasteboardType] = [
            .tiff, NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("public.jpeg"),
        ]
        for type in types {
            if let data = pasteboard.data(forType: type), let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                return png
            }
        }
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation
        else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// A path as a paste inserts it: as it is when it is simple, else in
    /// single quotes (what shells and the agents' input parsing both take;
    /// the cache folder's name has a space).
    static func quoted(_ path: String) -> String {
        RemoteFileDrop.escaped(path)
    }
}

/// The folder pasted images are written to: `~/Library/Caches/<app
/// identity>/Pasted Images`, one PNG per paste named after its time
/// (`20260928-101530-1a2b3c4d.png`). Files older than `retention` are
/// removed whenever another is written: an agent reads a pasted image soon
/// after the paste, and the folder is a cache (the system may empty it).
enum PastedImageStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(CherryAppIdentity.current.applicationSupportName, isDirectory: true)
            .appendingPathComponent("Pasted Images", isDirectory: true)
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// `<local time>-<first 8 of the id>.png`.
    static func fileName(at date: Date, id: UUID) -> String {
        "\(nameFormatter.string(from: date))-\(id.uuidString.prefix(8).lowercased()).png"
    }

    /// Writes `png` there (the folder is made private to the user), prunes
    /// the old ones, and returns its file.
    static func save(_ png: Data, in directory: URL = defaultDirectory, now: Date = Date(), id: UUID = UUID()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(directory, now: now)
        let url = directory.appendingPathComponent(fileName(at: now, id: id))
        try png.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Removes the PNGs modified before `now - retention`; returns them.
    @discardableResult
    static func prune(_ directory: URL, now: Date = Date(), retention: TimeInterval = retention) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-retention)
        var removed: [URL] = []
        for file in files where file.pathExtension.lowercased() == "png" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed.append(file) }
        }
        return removed
    }
}

/// ⌘V (or Edit › Paste) of an image into a tab of This Mac: the image is
/// saved (`PastedImageStore`) and its path pasted with `insert`, which
/// pastes it as the tab pastes text (bracketed while the program asks for
/// it). Files copied with no text (a screenshot tool's copy, which puts the
/// image's file and its data there; with no text a terminal would paste
/// nothing) paste their paths. False when the pasteboard has text (it
/// pastes as before: Finder's copied files paste their names), has none of
/// these, or the image could not be saved.
@MainActor
enum LocalImagePaste {
    static var directory: () -> URL = { PastedImageStore.defaultDirectory }

    @discardableResult
    static func handle(_ pasteboard: NSPasteboard, insert: (String) -> Void) -> Bool {
        guard let text = text(for: pasteboard) else { return false }
        insert(text)
        return true
    }

    /// What `handle` pastes; nil when it pastes nothing.
    static func text(for pasteboard: NSPasteboard) -> String? {
        switch PastedContent(pasteboard: pasteboard) {
        case .image(let png):
            guard let file = try? PastedImageStore.save(png, in: directory()) else { return nil }
            return PastedImage.quoted(file.path)
        case .files(let urls):
            guard pasteboard.string(forType: .string)?.isEmpty != false else { return nil }
            return urls.map { PastedImage.quoted($0.path) }.joined(separator: " ")
        case .text, .nothing:
            return nil
        }
    }
}
