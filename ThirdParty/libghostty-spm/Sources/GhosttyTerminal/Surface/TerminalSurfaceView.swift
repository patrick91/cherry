//
//  TerminalSurfaceView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import SwiftUI

@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, *)
public struct TerminalSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme

    let context: TerminalViewState

    public init(context: TerminalViewState) {
        self.context = context
    }

    public var body: some View {
        TerminalViewRepresentable(
            context: context,
            controller: context.controller,
            configuration: context.configuration
        )
        .background(.clear)
        .onChange(of: colorScheme, initial: true) {
            context.adopt(colorScheme: colorScheme)
        }
    }
}
