//
//  TerminalPasteboardImage.swift
//  libghostty-spm
//
//  Pasting/dropping an image into a terminal: terminals can't carry image bytes,
//  so (like ghostty's own apprt) we materialize the image as a temp file and
//  insert its path — which terminal agents (Claude Code, Codex) attach.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    enum TerminalPasteboardImage {
        /// If `pasteboard` carries image bytes (not a file URL, not plain text),
        /// write them to a temp PNG and return its path. nil if there's no image.
        static func temporaryFilePath(from pasteboard: NSPasteboard) -> String? {
            guard let image = NSImage(pasteboard: pasteboard) else { return nil }
            return write(image)
        }

        static func write(_ image: NSImage) -> String? {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cherry-images", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
            do {
                try png.write(to: url)
                return url.path
            } catch {
                return nil
            }
        }

        /// Escape a path for insertion as terminal input. Simple paths pass through
        /// raw; anything with spaces/specials is single-quoted (safe for shells and
        /// accepted by the agents' input parsing).
        static func escapedForInput(_ path: String) -> String {
            let isSimple = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
            if isSimple { return path }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif
