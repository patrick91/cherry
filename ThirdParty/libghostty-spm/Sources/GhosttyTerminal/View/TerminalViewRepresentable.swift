//
//  TerminalViewRepresentable.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import SwiftUI

@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
@MainActor
struct TerminalViewRepresentable {
    let context: TerminalViewState
    let controller: TerminalController
    let configuration: TerminalSurfaceOptions

    func configureView(_ view: TerminalView, initial: Bool) {
        if initial {
            view.delegate = context
        }

        if let currentController = view.controller, currentController === controller {
            // Keep the current surface.
        } else {
            view.controller = controller
        }

        if !view.configuration.isEquivalent(to: configuration) {
            view.configuration = configuration
        }
    }
}
