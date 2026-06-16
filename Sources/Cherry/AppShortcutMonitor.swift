import AppKit
import SwiftUI

struct AppShortcutMonitor: NSViewRepresentable {
    @ObservedObject private var agentSettings = AgentSettings.shared

    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject var chromeState: ProjectWindowChromeState
    @ObservedObject var noteStore: ProjectNoteStore
    @ObservedObject var todoStore: ProjectTodoStore
    let projectRoot: String?
    let openSettings: () -> Void

    private var visibleCommandNames: [String] {
        visibleCommands.map(\.name)
    }

    private var visibleCommands: [ProjectCommandDefinition] {
        agentSettings.launchableProjectCommands(for: projectRoot)
    }

    private var projectFeatures: ProjectFeatureSettings {
        agentSettings.projectFeatures(for: projectRoot)
    }

    enum ShortcutAction: Equatable {
        case selectVisibleSidebarItem(Int)
        case presentCommandPalette
        case toggleSidebar
        case addSession
        case closeSelectedSessionOrWindow
        case terminate
        case openSettings
    }

    nonisolated static func shortcutAction(
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> ShortcutAction? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return nil }

        switch charactersIgnoringModifiers?.lowercased() {
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard let character = charactersIgnoringModifiers,
                  let number = Int(character)
            else {
                return nil
            }
            return .selectVisibleSidebarItem(number)
        case "p":
            return .presentCommandPalette
        case "s":
            return .toggleSidebar
        case "t":
            return .addSession
        case "w":
            return .closeSelectedSessionOrWindow
        case "q":
            return .terminate
        case ",":
            return .openSettings
        default:
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            workspace: workspace,
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
            projectRoot: projectRoot,
            visibleCommandNames: visibleCommandNames,
            visibleCommands: visibleCommands,
            projectFeatures: projectFeatures,
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
        context.coordinator.noteStore = noteStore
        context.coordinator.todoStore = todoStore
        context.coordinator.projectRoot = projectRoot
        context.coordinator.visibleCommandNames = visibleCommandNames
        context.coordinator.visibleCommands = visibleCommands
        context.coordinator.projectFeatures = projectFeatures
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

    enum SidebarItem {
        case session(TerminalSession)
        case command(ProjectCommandDefinition)
        case todoBoard
        case note(UUID)
    }

    @MainActor
    final class Coordinator {
        weak var workspace: TerminalWorkspace?
        weak var chromeState: ProjectWindowChromeState?
        weak var noteStore: ProjectNoteStore?
        weak var todoStore: ProjectTodoStore?
        var projectRoot: String?
        var visibleCommandNames: [String]
        var visibleCommands: [ProjectCommandDefinition]
        var projectFeatures: ProjectFeatureSettings
        var openSettings: () -> Void
        weak var window: NSWindow?
        private nonisolated(unsafe) var monitor: Any?

        init(
            workspace: TerminalWorkspace,
            chromeState: ProjectWindowChromeState,
            noteStore: ProjectNoteStore,
            todoStore: ProjectTodoStore,
            projectRoot: String?,
            visibleCommandNames: [String],
            visibleCommands: [ProjectCommandDefinition],
            projectFeatures: ProjectFeatureSettings,
            openSettings: @escaping () -> Void
        ) {
            self.workspace = workspace
            self.chromeState = chromeState
            self.noteStore = noteStore
            self.todoStore = todoStore
            self.projectRoot = projectRoot
            self.visibleCommandNames = visibleCommandNames
            self.visibleCommands = visibleCommands
            self.projectFeatures = projectFeatures
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
                    cycleSidebarSelection(offset: -1)
                    return true
                case 125:
                    cycleSidebarSelection(offset: 1)
                    return true
                default:
                    break
                }
            }

            guard let action = AppShortcutMonitor.shortcutAction(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: modifiers
            ) else {
                return false
            }

            perform(action)
            return true
        }

        private func perform(_ action: ShortcutAction) {
            switch action {
            case .selectVisibleSidebarItem(let number):
                selectVisibleSidebarItem(number: number)
            case .presentCommandPalette:
                chromeState?.presentCommandPalette()
            case .toggleSidebar:
                chromeState?.toggleSidebar()
            case .addSession:
                workspace?.addSession()
            case .closeSelectedSessionOrWindow:
                closeSelectedSessionOrWindow()
            case .terminate:
                NSApp.terminate(nil)
            case .openSettings:
                openSettings()
            }
        }

        private func closeSelectedSessionOrWindow() {
            guard let workspace else { return }
            if chromeState?.closeSelectedNoteIfNeeded() == true {
                return
            }

            if workspace.sessions.count > 1 {
                guard let session = workspace.selectedSession else { return }
                SessionCloseCoordinator.close(session, in: workspace, chromeState: chromeState)
            } else {
                window?.performClose(nil)
            }
        }

        private func selectVisibleSidebarItem(number: Int) {
            let items = sidebarItems()
            guard number >= 1, number - 1 < items.count else { return }
            activate(items[number - 1])
        }

        private func cycleSidebarSelection(offset: Int) {
            let items = sidebarItems()
            guard !items.isEmpty else { return }
            let currentIndex = currentSidebarIndex(in: items) ?? 0
            let nextIndex = (currentIndex + offset + items.count) % items.count
            activate(items[nextIndex])
        }

        private func sidebarItems() -> [SidebarItem] {
            guard let workspace else { return [] }
            var items: [SidebarItem] = []
            items += workspace.visibleAgentSessions(
                collapsedIDs: chromeState?.collapsedAgentGroupIDs ?? []
            ).map { .session($0) }
            items += workspace.terminalSessions.map { .session($0) }
            items += visibleCommands.map { .command($0) }
            if projectFeatures.todosEnabled {
                items.append(.todoBoard)
            }
            if projectFeatures.notesEnabled, let noteStore {
                items += noteStore.notes.map { .note($0.id) }
            }
            return items
        }

        private func currentSidebarIndex(in items: [SidebarItem]) -> Int? {
            if let chromeState {
                if let selectedNoteID = chromeState.selectedNoteID {
                    return items.firstIndex {
                        if case .note(let id) = $0 { return id == selectedNoteID }
                        return false
                    }
                }
                if chromeState.isTodoPanePresented {
                    return items.firstIndex {
                        if case .todoBoard = $0 { return true }
                        return false
                    }
                }
                if let idleName = chromeState.focusedIdleCommandName {
                    return items.firstIndex {
                        if case .command(let def) = $0 { return def.name == idleName }
                        return false
                    }
                }
            }
            if let selectedID = workspace?.selectedSessionID {
                return items.firstIndex { item in
                    switch item {
                    case .session(let s):
                        return s.id == selectedID
                    case .command(let def):
                        return workspace?.commandSession(named: def.name)?.id == selectedID
                    case .todoBoard, .note:
                        return false
                    }
                }
            }
            return nil
        }

        private func activate(_ item: SidebarItem) {
            guard let workspace, let chromeState else { return }
            switch item {
            case .session(let session):
                chromeState.selectTerminal()
                workspace.select(session)
            case .command(let command):
                if let session = workspace.commandSession(named: command.name) {
                    chromeState.selectTerminal()
                    workspace.select(session)
                } else {
                    chromeState.focusIdleCommand(name: command.name)
                }
            case .todoBoard:
                let firstSelectableTodoID = todoStore?.todos.first { $0.status != .done }?.id
                    ?? todoStore?.todos.first?.id
                chromeState.selectTodo(id: chromeState.selectedTodoID ?? firstSelectableTodoID)
            case .note(let id):
                chromeState.selectNote(id: id)
            }
        }
    }
}
