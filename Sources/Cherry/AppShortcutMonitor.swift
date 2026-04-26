import AppKit
import SwiftUI

struct AppShortcutMonitor: NSViewRepresentable {
    @ObservedObject var workspace: TerminalWorkspace
    let openSettings: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace, openSettings: openSettings)
    }

    func makeNSView(context: Context) -> ShortcutMonitorView {
        let view = ShortcutMonitorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ShortcutMonitorView, context: Context) {
        context.coordinator.workspace = workspace
        context.coordinator.openSettings = openSettings
        nsView.coordinator = context.coordinator
    }

    final class ShortcutMonitorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.window = window
        }
    }

    @MainActor
    final class Coordinator {
        weak var workspace: TerminalWorkspace?
        var openSettings: () -> Void
        weak var window: NSWindow?
        private nonisolated(unsafe) var monitor: Any?

        init(workspace: TerminalWorkspace, openSettings: @escaping () -> Void) {
            self.workspace = workspace
            self.openSettings = openSettings
            install()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return consumed ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains([.command, .option]),
               modifiers.isDisjoint(with: [.control, .shift])
            {
                switch event.keyCode {
                case 126:
                    workspace?.selectPreviousSession()
                    return true
                case 125:
                    workspace?.selectNextSession()
                    return true
                default:
                    break
                }
            }

            guard modifiers == .command else { return false }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t":
                workspace?.addSession()
                return true
            case "w":
                closeSelectedSessionOrWindow()
                return true
            case "q":
                NSApp.terminate(nil)
                return true
            case ",":
                openSettings()
                return true
            default:
                return false
            }
        }

        private func closeSelectedSessionOrWindow() {
            guard let workspace else { return }

            if workspace.sessions.count > 1 {
                workspace.closeSelectedSession()
            } else {
                window?.performClose(nil)
            }
        }
    }
}
