//
//  TerminalCallbackBridge.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Dispatches C runtime callbacks to a ``TerminalSurfaceViewDelegate``.
///
/// An instance of this class is passed as the `userdata` pointer in the
/// surface config so that Ghostty callbacks can route actions back to
/// the owning view.
@MainActor
final class TerminalCallbackBridge {
    weak var delegate: (any TerminalSurfaceViewDelegate)?
    /// Raw surface pointer for use in C callbacks (e.g. clipboard).
    nonisolated(unsafe) var rawSurface: ghostty_surface_t?
    var onCellSizeChange: ((UInt32, UInt32) -> Void)?
    var onRenderRequest: (() -> Void)?

    init(delegate: (any TerminalSurfaceViewDelegate)? = nil) {
        self.delegate = delegate
    }

    func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                let title = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=set_title title=\(TerminalDebugLog.describe(title))"
                )
                (delegate as? any TerminalSurfaceTitleDelegate)?
                    .terminalDidChangeTitle(title)
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = action.action.cell_size
            TerminalDebugLog.log(
                .actions,
                "callback action=cell_size width=\(cellSize.width) height=\(cellSize.height)"
            )
            onCellSizeChange?(cellSize.width, cellSize.height)

        case GHOSTTY_ACTION_RING_BELL:
            TerminalDebugLog.log(.actions, "callback action=ring_bell")
            (delegate as? any TerminalSurfaceBellDelegate)?
                .terminalDidRingBell()

        case GHOSTTY_ACTION_RENDER:
            TerminalDebugLog.log(.render, "callback action=render")
            onRenderRequest?()

        case GHOSTTY_ACTION_SCROLLBAR:
            let metrics = TerminalScrollbarMetrics(action.action.scrollbar)
            TerminalDebugLog.log(
                .actions,
                "callback action=scrollbar total=\(metrics.total) offset=\(metrics.offset) length=\(metrics.length)"
            )
            (delegate as? any TerminalSurfaceScrollbarDelegate)?
                .terminalDidUpdateScrollbar(metrics)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let style = TerminalPointerStyle(action.action.mouse_shape) else { return }
            TerminalDebugLog.log(
                .actions,
                "callback action=mouse_shape style=\(style)"
            )
            (delegate as? any TerminalSurfacePointerDelegate)?
                .terminalDidChangePointerStyle(style)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = action.action.mouse_over_link
            let url: String?
            if link.len > 0, let buffer = link.url {
                url = String(data: Data(bytes: buffer, count: link.len), encoding: .utf8)
            } else {
                url = nil
            }
            TerminalDebugLog.log(
                .actions,
                "callback action=mouse_over_link url=\(TerminalDebugLog.describe(url ?? ""))"
            )
            (delegate as? any TerminalSurfaceLinkHoverDelegate)?
                .terminalDidHoverLink(url)

        case GHOSTTY_ACTION_START_SEARCH:
            let startSearch = action.action.start_search
            let query = startSearch.needle.map { String(cString: $0) }
            TerminalDebugLog.log(
                .actions,
                "callback action=start_search query=\(TerminalDebugLog.describe(query ?? ""))"
            )
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidRequestSearch(TerminalSearchStartRequest(query: query))

        case GHOSTTY_ACTION_END_SEARCH:
            TerminalDebugLog.log(.actions, "callback action=end_search")
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidEndSearch()

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let rawTotal = action.action.search_total.total
            let total = rawTotal < 0 ? nil : Int(rawTotal)
            TerminalDebugLog.log(
                .actions,
                "callback action=search_total total=\(total.map(String.init) ?? "nil")"
            )
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidUpdateSearchTotal(total)

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let rawSelected = action.action.search_selected.selected
            let selected = rawSelected < 0 ? nil : Int(rawSelected)
            TerminalDebugLog.log(
                .actions,
                "callback action=search_selected selected=\(selected.map(String.init) ?? "nil")"
            )
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidUpdateSearchSelection(selected)

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Colors/theme may have changed (e.g. on system appearance
            // toggle). Ghostty applies the new config internally but won't
            // repaint until the next frame — request one so the refreshed
            // theme is visible without waiting for input or layout.
            TerminalDebugLog.log(.actions, "callback action=config_change")
            onRenderRequest?()

        default:
            TerminalDebugLog.log(
                .actions,
                "callback action=\(TerminalDebugLog.describe(action.tag))"
            )
        }
    }

    func handleClose(processAlive: Bool) {
        TerminalDebugLog.log(
            .lifecycle,
            "callback close processAlive=\(processAlive)"
        )
        (delegate as? any TerminalSurfaceCloseDelegate)?
            .terminalDidClose(processAlive: processAlive)
    }
}
