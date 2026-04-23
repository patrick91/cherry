import SwiftUI

@main
struct CherryApp: App {
    @StateObject private var workspace = TerminalWorkspace()

    var body: some Scene {
        WindowGroup("Cherry") {
            ContentView(workspace: workspace)
        }
        .defaultSize(width: 1_340, height: 840)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandMenu("Prototype") {
                Button("New Tab") {
                    workspace.addSession()
                }
                .keyboardShortcut("t")

                Button("Burst 1,000 Lines") {
                    workspace.burstSelectedSession()
                }
                .keyboardShortcut("b")

                Button("Clear Active Tab") {
                    workspace.clearSelectedSession()
                }
                .keyboardShortcut("k")
            }
        }
    }
}
