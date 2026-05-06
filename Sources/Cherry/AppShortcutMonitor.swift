import AppKit
import SwiftUI

struct AppShortcutMonitor: NSViewRepresentable {
    @ObservedObject private var agentSettings = AgentSettings.shared

    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    let projectRoot: String?
    let openSettings: () -> Void

    private var visibleCommandNames: [String] {
        visibleCommands.map(\.name)
    }

    private var visibleCommands: [ProjectCommandDefinition] {
        agentSettings.launchableProjectCommands(for: projectRoot)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            workspace: workspace,
            chromeState: chromeState,
            projectRoot: projectRoot,
            visibleCommandNames: visibleCommandNames,
            visibleCommands: visibleCommands,
            openSettings: openSettings
        )
    }

    func makeNSView(context: Context) -> ShortcutMonitorView {
        let view = ShortcutMonitorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ShortcutMonitorView, context: Context) {
        context.coordinator.workspace = workspace
        context.coordinator.chromeState = chromeState
        context.coordinator.projectRoot = projectRoot
        context.coordinator.visibleCommandNames = visibleCommandNames
        context.coordinator.visibleCommands = visibleCommands
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
        weak var chromeState: ProjectWindowChromeState?
        var projectRoot: String?
        var visibleCommandNames: [String]
        var visibleCommands: [ProjectCommandDefinition]
        var openSettings: () -> Void
        weak var window: NSWindow?
        private nonisolated(unsafe) var monitor: Any?

        init(
            workspace: TerminalWorkspace,
            chromeState: ProjectWindowChromeState,
            projectRoot: String?,
            visibleCommandNames: [String],
            visibleCommands: [ProjectCommandDefinition],
            openSettings: @escaping () -> Void
        ) {
            self.workspace = workspace
            self.chromeState = chromeState
            self.projectRoot = projectRoot
            self.visibleCommandNames = visibleCommandNames
            self.visibleCommands = visibleCommands
            self.openSettings = openSettings
            install()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return consumed ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window else {
                chromeState?.isCommandKeyPressed = false
                return false
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            chromeState?.isCommandKeyPressed = modifiers.contains(.command)

            guard event.type == .keyDown else { return false }

            if modifiers.contains([.command, .option]),
               modifiers.isDisjoint(with: [.control, .shift])
            {
                switch event.keyCode {
                case 126:
                    workspace?.selectPreviousSession(visibleCommandNames: visibleCommandNames)
                    return true
                case 125:
                    workspace?.selectNextSession(visibleCommandNames: visibleCommandNames)
                    return true
                default:
                    break
                }
            }

            guard modifiers == .command else { return false }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                guard let number = event.charactersIgnoringModifiers.flatMap(Int.init) else { return false }
                selectVisibleSidebarItem(number: number)
                return true
            case "p":
                chromeState?.presentCommandPalette()
                return true
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

        private func selectVisibleSidebarItem(number: Int) {
            guard let workspace else { return }
            let zeroBasedIndex = number - 1
            guard zeroBasedIndex >= 0 else { return }

            let agentSessions = workspace.agentSessions
            if zeroBasedIndex < agentSessions.count {
                chromeState?.selectNote(id: nil)
                workspace.select(agentSessions[zeroBasedIndex])
                return
            }

            let terminalIndex = zeroBasedIndex - agentSessions.count
            let terminalSessions = workspace.terminalSessions
            if terminalIndex < terminalSessions.count {
                chromeState?.selectNote(id: nil)
                workspace.select(terminalSessions[terminalIndex])
                return
            }

            let commandIndex = terminalIndex - terminalSessions.count
            guard commandIndex >= 0, commandIndex < visibleCommands.count else { return }

            let command = visibleCommands[commandIndex]
            if let session = workspace.commandSession(named: command.name) {
                chromeState?.selectNote(id: nil)
                workspace.select(session)
                session.restartManagedCommandIfNeeded()
            } else if let root = AgentSettings.shared.resolvedProject(for: projectRoot).validProjectRoot {
                chromeState?.selectNote(id: nil)
                workspace.addCommandSession(command: command, projectRoot: root)
            }
        }
    }
}
