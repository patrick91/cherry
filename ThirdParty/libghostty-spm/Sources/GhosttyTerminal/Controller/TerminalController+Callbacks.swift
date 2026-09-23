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

private enum TerminalCallbacks {
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
        terminalRunOnMain {
            bridge.handleAction(action)
        }

        return false
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

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm _: Bool
    ) {
        guard contentsLen > 0 else { return }
        guard let content = contents?.pointee else { return }
        guard let data = content.data else { return }
        let string = String(cString: data)

        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes _: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen _: Int,
        list _: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        #if canImport(UIKit)
            let string = UIPasteboard.general.string
        #elseif canImport(AppKit)
            var string = NSPasteboard.general.string(forType: .string)
            // No text but an image on the clipboard (e.g. a screenshot pasted with
            // Cmd+V): write it to a temp file and paste its path so agents attach it.
            if string == nil,
               let path = TerminalPasteboardImage.temporaryFilePath(from: .general) {
                string = TerminalPasteboardImage.escapedForInput(path)
            }
        #endif

        guard let string else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        "text/plain".withCString { mime in
            string.withCString { cString in
                var content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: cString,
                    len: string.utf8.count
                )
                withUnsafePointer(to: &content) { contentPtr in
                    var completion = ghostty_clipboard_complete_s(
                        contents: contentPtr,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: false,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &completion, opaquePtr)
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let confirm, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let content = confirm.pointee.contents?.pointee,
              let data = content.data
        else { return }
        let text = String(
            data: Data(bytes: data, count: content.len),
            encoding: .utf8
        ) ?? ""
        guard let kind = TerminalClipboardRequestKind(request) else { return }
        let requestState = UInt(bitPattern: opaquePtr)
        terminalRunOnMain {
            guard let surface = bridge.rawSurface,
                  let opaquePtr = UnsafeMutableRawPointer(bitPattern: requestState)
            else {
                return
            }
            bridge.handleClipboardConfirmation(contents: text, kind: kind) { allowed in
                guard bridge.rawSurface == surface else { return }
                let completedText = allowed ? text : ""
                "text/plain".withCString { mime in
                    completedText.withCString { cString in
                        var content = ghostty_clipboard_content_s(
                            mime: mime,
                            data: cString,
                            len: completedText.utf8.count
                        )
                        withUnsafePointer(to: &content) { contentPtr in
                            var completion = ghostty_clipboard_complete_s(
                                contents: contentPtr,
                                contents_len: 1,
                                available: nil,
                                available_len: 0,
                                confirmed: allowed,
                                remember: false
                            )
                            ghostty_surface_complete_clipboard_request(
                                surface,
                                &completion,
                                opaquePtr
                            )
                        }
                    }
                }
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
