//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(AppKit) && !canImport(UIKit)
    /// The pasteboard the surfaces paste from and copy to
    /// (`NSPasteboard.general`). Tests use one of their own.
    public enum TerminalClipboard {
        public nonisolated(unsafe) static var pasteboard: () -> NSPasteboard = { .general }

        /// What a paste into `bridge`'s surface types: the pasteboard's
        /// text; with none, the delegate's text for it (an image's saved
        /// path, files' paths, or nothing when it copies them elsewhere),
        /// else the paths of its files (a copied file with no text would
        /// paste nothing). Nil when there is nothing to paste.
        @MainActor
        static func pasteText(for bridge: TerminalCallbackBridge) -> String? {
            let pasteboard = pasteboard()
            if let string = pasteboard.string(forType: .string) { return string }
            if let text = bridge.pastedImageText(from: pasteboard) { return text }
            let files = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            guard !files.isEmpty else { return nil }
            return files.map { TerminalPasteboardImage.escapedForInput($0.path) }.joined(separator: " ")
        }

        /// Whether a paste would type anything, found without saving an
        /// image or copying files anywhere: what a program that asked for
        /// paste events (the Kitty clipboard protocol's mode 5522) is told
        /// is there before it reads it.
        @MainActor
        static func hasPasteText(for bridge: TerminalCallbackBridge) -> Bool {
            let pasteboard = pasteboard()
            if pasteboard.string(forType: .string)?.isEmpty == false { return true }
            if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
                return true
            }
            return bridge.takesPastedImages && NSImage.canInit(with: pasteboard)
        }
    }
#endif

/// One representation of clipboard contents (a MIME type and its bytes),
/// copied out of Ghostty's memory, which it lends only for a callback, or
/// made here to answer a read.
struct TerminalClipboardContent {
    /// The one type the surfaces read and write: Ghostty asks for every
    /// text type by this name.
    static let textMime = "text/plain"

    let mime: String
    let data: Data

    init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    init?(_ content: ghostty_clipboard_content_s) {
        guard let mime = content.mime else { return nil }
        self.mime = String(cString: mime)
        if let bytes = content.data, content.len > 0 {
            data = Data(bytes: bytes, count: content.len)
        } else {
            data = Data()
        }
    }

    static func text(_ string: String) -> TerminalClipboardContent {
        TerminalClipboardContent(mime: textMime, data: Data(string.utf8))
    }

    /// Ghostty's text types (`terminal.clipboard.isTextMime`).
    var isText: Bool {
        ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"].contains(mime)
    }

    /// The text, invalid UTF-8 repaired.
    var string: String {
        String(decoding: data, as: UTF8.self)
    }
}

enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.tick()
            controller.onWakeup?()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            // Answered now: true keeps Ghostty from opening it itself. A
            // click is handled on the main thread; anywhere else Ghostty
            // opens it as before.
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { openURL(action, bridge: bridge) }
        }
        terminalRunOnMain {
            bridge.handleAction(action)
        }

        return false
    }

    /// Ghostty's `open_url` action: whether the surface's delegate opens
    /// the URL itself (`TerminalSurfaceOpenURLDelegate`); false leaves it
    /// to Ghostty, which opens it with the system's handler.
    @MainActor
    static func openURL(_ action: ghostty_action_s, bridge: TerminalCallbackBridge) -> Bool {
        guard action.tag == GHOSTTY_ACTION_OPEN_URL else { return false }
        let link = action.action.open_url
        guard link.len > 0, let buffer = link.url,
              let url = String(data: Data(bytes: buffer, count: Int(link.len)), encoding: .utf8)
        else { return false }
        return bridge.handleOpenURL(url)
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    /// A copy (a selection, or a program's OSC 52 write, which in a
    /// persistent or another Mac's tab comes through the attach adapter
    /// like any other output). `confirm` is Ghostty's `clipboard-write =
    /// ask`: the surface's delegate asks first, and nothing is written
    /// unless it allows it. Only text is written: of a copy with several
    /// representations (a selection's HTML, a Kitty clipboard protocol
    /// write) the text one, none when it has none.
    static func writeClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        guard contentsLen > 0, let contents else { return }
        guard let text = (0 ..< contentsLen).lazy
            .compactMap({ TerminalClipboardContent(contents[$0]) })
            .first(where: \.isText)
        else { return }
        let string = text.string

        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            func write() {
                let pasteboard = TerminalClipboard.pasteboard()
                pasteboard.clearContents()
                pasteboard.setString(string, forType: .string)
            }
            guard confirm else {
                write()
                return
            }
            guard let userdata else { return }
            let bridge = Unmanaged<TerminalCallbackBridge>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            terminalRunOnMain {
                bridge.handleClipboardConfirmation(contents: string, kind: .osc52Write) { allowed in
                    if allowed { write() }
                }
            }
        #endif
    }

    /// A read: a paste, a program's OSC 52 read, or the Kitty clipboard
    /// protocol's read (`mimes`) or listing (`list`, which also answers a
    /// paste into a program that asked for paste events). Only text is
    /// served, as `text/plain` (what Ghostty asks for any text type by):
    /// an image is the delegate's to save, and its path is the text (as
    /// files' paths are), never its bytes, so a Kitty read of an image
    /// type is not served and a listing names only `text/plain`. Nothing
    /// to serve (an empty text included, where an image's or files' copy
    /// to another Mac pastes nothing now) is `UNAVAILABLE`: nothing is
    /// pasted, an OSC 52 read is not answered, a Kitty read gets an empty
    /// answer.
    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let wantsText = (0 ..< mimesLen).contains { index in
            guard let mime = mimes?[index] else { return false }
            return TerminalClipboardContent(mime: String(cString: mime), data: Data()).isText
        }

        #if canImport(UIKit)
            let string = UIPasteboard.general.string.flatMap { $0.isEmpty ? nil : $0 }
            let contents = wantsText ? string.map { [TerminalClipboardContent.text($0)] } ?? [] : []
            let available = list && string != nil ? [TerminalClipboardContent.textMime] : []
            guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
            completeClipboardRequest(surface, state: opaquePtr, contents: contents, available: available)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        #elseif canImport(AppKit)
            /// What to serve: the paste's text when a text type is asked
            /// for, and the listing when it is.
            @MainActor
            func answer() -> (contents: [TerminalClipboardContent], available: [String]) {
                let text = wantsText ? TerminalClipboard.pasteText(for: bridge).flatMap { $0.isEmpty ? nil : $0 } : nil
                let available = list && (text != nil || TerminalClipboard.hasPasteText(for: bridge))
                    ? [TerminalClipboardContent.textMime] : []
                return (text.map { [.text($0)] } ?? [], available)
            }

            // What to paste may be the delegate's (an image's saved path,
            // a file copied to another Mac), which runs on the main thread.
            // A request made there (a key binding, Edit › Paste) is
            // answered now; one made elsewhere is answered on the main
            // thread next, which Ghostty allows (its request state lives
            // until it is completed).
            if Thread.isMainThread {
                let (contents, available) = MainActor.assumeIsolated { answer() }
                guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
                completeClipboardRequest(surface, state: opaquePtr, contents: contents, available: available)
                return GHOSTTY_CLIPBOARD_READ_STARTED
            }
            let requestState = UInt(bitPattern: opaquePtr)
            terminalRunOnMain {
                guard bridge.rawSurface == surface,
                      let opaquePtr = UnsafeMutableRawPointer(bitPattern: requestState)
                else {
                    return
                }
                // Completed (once) even when there is nothing to paste, so
                // the request is not left open. An answer that discloses
                // nothing is confirmed, as Ghostty answers an unavailable
                // read without asking: no paste, an empty OSC 52 or Kitty
                // reply.
                let (contents, available) = answer()
                completeClipboardRequest(
                    surface,
                    state: opaquePtr,
                    contents: contents,
                    available: available,
                    confirmed: contents.isEmpty && available.isEmpty
                )
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        #endif
    }

    /// Ghostty asks before it completes a read (`clipboard-read = ask`, a
    /// paste it finds unsafe) or a Kitty clipboard protocol write
    /// (`clipboard-write = ask`). The surface's delegate asks; allowed,
    /// the request completes with what Ghostty showed, confirmed, and
    /// otherwise it is denied (no paste, an empty OSC 52 reply, a Kitty
    /// refusal). It is never remembered: the delegate's question offers
    /// no "always". A request with no question to ask is denied, so none
    /// is left open.
    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let confirm, let kind = TerminalClipboardRequestKind(request) else {
            if let surface = bridge.rawSurface {
                ghostty_surface_deny_clipboard_request(surface, opaquePtr)
            }
            return
        }
        // Copied: Ghostty lends them only for this call, and the answer
        // comes later.
        let details = confirm.pointee
        let contents = (0 ..< details.contents_len).compactMap { index in
            details.contents.flatMap { TerminalClipboardContent($0[index]) }
        }
        let available = (0 ..< details.available_len).compactMap { index in
            details.available?[index].map { String(cString: $0) }
        }
        let shown = contents.first(where: \.isText)?.string
            ?? contents.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
        let requestState = UInt(bitPattern: opaquePtr)
        terminalRunOnMain {
            guard let surface = bridge.rawSurface,
                  let opaquePtr = UnsafeMutableRawPointer(bitPattern: requestState)
            else {
                return
            }
            bridge.handleClipboardConfirmation(contents: shown, kind: kind) { allowed in
                guard bridge.rawSurface == surface else { return }
                if allowed {
                    completeClipboardRequest(
                        surface,
                        state: opaquePtr,
                        contents: contents,
                        available: available,
                        confirmed: true
                    )
                } else {
                    ghostty_surface_deny_clipboard_request(surface, opaquePtr)
                }
            }
        }
    }

    /// Completes the read `state` of `surface` with `contents` and the
    /// listing `available`, in memory that lives for the call.
    static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        state: UnsafeMutableRawPointer,
        contents: [TerminalClipboardContent],
        available: [String] = [],
        confirmed: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        var cContents: [ghostty_clipboard_content_s] = []
        for content in contents {
            guard let mime = strdup(content.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(content.data.count, 1), alignment: 1)
            buffers.append(buffer)
            content.data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.copyMemory(from: base, byteCount: bytes.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: content.data.count
            ))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let string = strdup(mime) else { continue }
            strings.append(string)
            cAvailable.append(UnsafePointer(string))
        }
        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false
                )
                ghostty_surface_complete_clipboard_request(surface, &completion, state)
            }
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        list: list
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirm: confirm,
        opaquePtr: opaquePtr,
        request: request
    )
}
