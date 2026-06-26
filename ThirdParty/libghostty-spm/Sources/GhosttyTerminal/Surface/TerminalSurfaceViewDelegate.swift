//
//  TerminalSurfaceViewDelegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

@MainActor
public protocol TerminalSurfaceViewDelegate: AnyObject {}

#if canImport(AppKit) && !canImport(UIKit)
    @MainActor
    public protocol TerminalSurfaceKeyEquivalentDelegate: TerminalSurfaceViewDelegate {
        func terminalShouldHandleKeyEquivalent(_ event: NSEvent) -> Bool
    }
#endif

@MainActor
public protocol TerminalSurfaceTitleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeTitle(_ title: String)
}

@MainActor
public protocol TerminalSurfaceGridResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics)
}

@MainActor
public protocol TerminalSurfaceHostInputDelegate: TerminalSurfaceViewDelegate {
    func terminalWillSendHostInput()
}

@MainActor
public protocol TerminalSurfaceScrollInputDelegate: TerminalSurfaceViewDelegate {
    func terminalShouldSuppressScrollInput(isMomentum: Bool) -> Bool
}

@MainActor
public protocol TerminalSurfaceResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(columns: Int, rows: Int)
}

public struct TerminalScrollbarMetrics: Sendable, Equatable {
    public let total: UInt64
    public let offset: UInt64
    public let length: UInt64

    public init(total: UInt64, offset: UInt64, length: UInt64) {
        self.total = total
        self.offset = offset
        self.length = length
    }

    init(_ rawValue: ghostty_action_scrollbar_s) {
        total = rawValue.total
        offset = rawValue.offset
        length = rawValue.len
    }
}

@MainActor
public protocol TerminalSurfaceScrollbarDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateScrollbar(_ metrics: TerminalScrollbarMetrics)
}

public enum TerminalPointerStyle: Sendable, Equatable {
    case arrow
    case text
    case verticalText
    case pointingHand
    case openHand
    case closedHand
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case resizeUpDown
    case resizeLeftRight
    case contextualMenu
    case crosshair
    case operationNotAllowed

    init?(_ rawValue: ghostty_action_mouse_shape_e) {
        switch rawValue {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            self = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            self = .text
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            self = .verticalText
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            self = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            self = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            self = .closedHand
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            self = .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            self = .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            self = .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            self = .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            self = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            self = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            self = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            self = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            self = .operationNotAllowed
        default:
            return nil
        }
    }
}

@MainActor
public protocol TerminalSurfacePointerDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangePointerStyle(_ style: TerminalPointerStyle)
}

@MainActor
public protocol TerminalSurfaceLinkHoverDelegate: TerminalSurfaceViewDelegate {
    func terminalDidHoverLink(_ url: String?)
}

public struct TerminalSearchStartRequest: Sendable, Equatable {
    public let query: String?

    public init(query: String?) {
        self.query = query
    }
}

@MainActor
public protocol TerminalSurfaceSearchDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestSearch(_ request: TerminalSearchStartRequest)
    func terminalDidEndSearch()
    func terminalDidUpdateSearchTotal(_ total: Int?)
    func terminalDidUpdateSearchSelection(_ selected: Int?)
}

@MainActor
public protocol TerminalSurfaceFocusDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeFocus(_ focused: Bool)
}

@MainActor
public protocol TerminalSurfaceBellDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRingBell()
}

@MainActor
public protocol TerminalSurfaceCloseDelegate: TerminalSurfaceViewDelegate {
    func terminalDidClose(processAlive: Bool)
}

@MainActor
public protocol TerminalSurfaceWorkingDirectoryDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String)
}

@MainActor
public protocol TerminalSurfaceNotificationDelegate: TerminalSurfaceViewDelegate {
    func terminalDidPostNotification(title: String?, body: String)
}

@MainActor
public protocol TerminalSurfaceChildExitDelegate: TerminalSurfaceViewDelegate {
    func terminalDidExit(exitCode: UInt32)
}
