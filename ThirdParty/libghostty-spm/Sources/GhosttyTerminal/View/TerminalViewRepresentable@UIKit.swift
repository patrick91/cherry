//
//  TerminalViewRepresentable@UIKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    @available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
    extension TerminalViewRepresentable: UIViewRepresentable {
        func makeUIView(context _: Context) -> TerminalView {
            let view = TerminalView(frame: .zero)
            configureView(view, initial: true)
            return view
        }

        func updateUIView(_ view: TerminalView, context _: Context) {
            configureView(view, initial: false)
        }
    }
#endif
