//
//  TerminalPasteboardImage.swift
//  libghostty-spm
//
//  Escaping dropped files' paths. Images pasted or dropped are the
//  delegate's to save (`TerminalSurfacePastedImageDelegate`).
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    enum TerminalPasteboardImage {
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
