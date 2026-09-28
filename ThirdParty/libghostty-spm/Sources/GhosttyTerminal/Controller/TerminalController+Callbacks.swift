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
        opaquePtr: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata, let opaquePtr else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return false }

        #if canImport(UIKit)
            let string = UIPasteboard.general.string
        #elseif canImport(AppKit)
            var string = NSPasteboard.general.string(forType: .string)
            // No text but an image on the clipboard (a screenshot pasted
            // from the menu, or read by OSC 52): the delegate saves it and
            // says what to paste for it (its file's path).
            if string == nil, Thread.isMainThread {
                string = MainActor.assumeIsolated { bridge.pastedImageText(from: .general) }
            }
        #endif

        guard let string else { return false }
        string.withCString { cString in
            ghostty_surface_complete_clipboard_request(surface, cString, opaquePtr, false)
        }
        return true
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let string, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let text = String(cString: string)
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
                completedText.withCString { cString in
                    ghostty_surface_complete_clipboard_request(
                        surface,
                        cString,
                        opaquePtr,
                        true
                    )
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
    opaquePtr: UnsafeMutableRawPointer?
) -> Bool {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        string: string,
        opaquePtr: opaquePtr,
        request: request
    )
}
