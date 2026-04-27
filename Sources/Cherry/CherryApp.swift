import AppKit
import SwiftUI

final class CherryAppDelegate: NSObject, NSApplicationDelegate {
    private var isQuitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }

        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitConfirmed else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Cherry?"
        alert.informativeText = "Active terminal sessions will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let window = sender.keyWindow ?? sender.windows.first
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.isQuitConfirmed = true
                sender.terminate(nil)
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            isQuitConfirmed = true
            return .terminateNow
        }

        return .terminateCancel
    }
}

@main
struct CherryApp: App {
    @NSApplicationDelegateAdaptor(CherryAppDelegate.self) private var appDelegate
    @StateObject private var workspace = TerminalWorkspace()
    @StateObject private var terminalSettings = TerminalSettings.shared
    @State private var isSidebarHidden = false
    @State private var isSidebarRevealed = false
    @State private var isCursorOverSidebar = false
    @State private var controlServer: CherryControlServer?

    var body: some Scene {
        WindowGroup("Cherry") {
            ContentView(
                workspace: workspace,
                isSidebarHidden: $isSidebarHidden,
                isSidebarRevealed: $isSidebarRevealed,
                isCursorOverSidebar: $isCursorOverSidebar
            )
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
                .onAppear {
                    guard controlServer == nil else { return }
                    let server = CherryControlServer(workspace: workspace)
                    server.start()
                    controlServer = server
                }
        }
        .defaultSize(width: 1_340, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Prototype") {
                Button(isSidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
                    // Cmd+S behavior:
                    //  - (hidden, revealed): toggle without `withAnimation`
                    //    so the docked sidebar snaps into place behind the
                    //    floating fade-out (handoff handled in ContentView).
                    //  - (hidden, ¬revealed): wrap in `withAnimation` so the
                    //    docked sidebar slides in normally.
                    //  - (shown, cursor-over-sidebar): switch to floating-
                    //    revealed in one shot so the sidebar visibly
                    //    transitions from docked to floating without the
                    //    user losing their place.
                    //  - (shown, cursor-elsewhere): hide normally.
                    if isSidebarHidden {
                        if isSidebarRevealed {
                            isSidebarHidden.toggle()
                        } else {
                            withAnimation(.snappy(duration: 0.18)) {
                                isSidebarHidden.toggle()
                            }
                        }
                    } else if isCursorOverSidebar {
                        // Snap both states — the sidebar swaps presentation
                        // from docked to floating without any motion. Mirror
                        // of the (hidden, revealed) → docked handoff, which
                        // also snaps.
                        withAnimation(nil) {
                            isSidebarHidden = true
                            isSidebarRevealed = true
                        }
                    } else {
                        withAnimation(.snappy(duration: 0.18)) {
                            isSidebarHidden = true
                        }
                    }
                }
                .keyboardShortcut("s")

                Button("New Tab") {
                    workspace.addSession()
                }
                .keyboardShortcut("t")

                Button("Close Tab") {
                    if workspace.sessions.count > 1 {
                        workspace.closeSelectedSession()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")

                Button("Previous Tab") {
                    workspace.selectPreviousSession()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button("Next Tab") {
                    workspace.selectNextSession()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button("Interrupt Active Tab") {
                    workspace.interruptSelectedSession()
                }
                .keyboardShortcut("c", modifiers: [.control])

                Button("Restart Active Tab") {
                    workspace.restartSelectedSession()
                }
                .keyboardShortcut("r")

                Button("Clear Scrollback") {
                    workspace.clearSelectedSessionScrollback()
                }
                .keyboardShortcut("k")
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
        }
    }
}
