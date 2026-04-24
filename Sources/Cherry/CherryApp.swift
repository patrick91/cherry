import AppKit
import SwiftUI

final class CherryAppDelegate: NSObject, NSApplicationDelegate {
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
}

@main
struct CherryApp: App {
    @NSApplicationDelegateAdaptor(CherryAppDelegate.self) private var appDelegate
    @StateObject private var workspace = TerminalWorkspace()

    var body: some Scene {
        WindowGroup("Cherry") {
            ContentView(workspace: workspace)
        }
        .defaultSize(width: 1_340, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Prototype") {
                Button("New Tab") {
                    workspace.addSession()
                }
                .keyboardShortcut("t")

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
    }
}
