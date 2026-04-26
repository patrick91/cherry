//
//  TerminalViewRepresentable@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import SwiftUI

    @available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
    extension TerminalViewRepresentable: NSViewRepresentable {
        func makeNSView(context _: Context) -> TerminalView {
            let view = TerminalView(frame: .zero)
            configureView(view, initial: true)
            return view
        }

        func updateNSView(_ view: TerminalView, context _: Context) {
            configureView(view, initial: false)
        }
    }
#endif
