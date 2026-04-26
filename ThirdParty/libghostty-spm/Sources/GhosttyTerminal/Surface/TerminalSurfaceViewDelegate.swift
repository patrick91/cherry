//
//  TerminalSurfaceViewDelegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

@MainActor
public protocol TerminalSurfaceViewDelegate: AnyObject {}

@MainActor
public protocol TerminalSurfaceTitleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeTitle(_ title: String)
}

@MainActor
public protocol TerminalSurfaceGridResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics)
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
