import AppKit
import SwiftUI
import UserNotifications

final class CherryAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var isQuitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        TerminalNotificationCenter.shared.configure(delegate: self)

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
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.markCurrentActiveProjectOpened()
        }

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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let sessionIDString = userInfo["sessionID"] as? String
        let projectRoot = userInfo["projectRoot"] as? String

        await MainActor.run {
            TerminalNotificationCenter.shared.handleResponse(
                sessionIDString: sessionIDString,
                projectRoot: projectRoot
            )
        }
    }
}

@main
struct CherryApp: App {
    @NSApplicationDelegateAdaptor(CherryAppDelegate.self) private var appDelegate
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @State private var controlServer: CherryControlServer?
    @FocusedValue(\.terminalWorkspace) private var focusedWorkspace
    @FocusedValue(\.projectWindowChromeState) private var focusedChromeState

    var body: some Scene {
        WindowGroup("Cherry", for: String.self) { projectRoot in
            ProjectWindowView(projectRoot: projectRoot.wrappedValue)
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
                .onAppear {
                    guard controlServer == nil else { return }
                    let server = CherryControlServer(workspaceProvider: {
                        ProjectWindowRegistry.shared.activeWorkspace
                    }, noteStoreProvider: {
                        ProjectWindowRegistry.shared.activeNoteStore
                    }, todoStoreProvider: {
                        ProjectWindowRegistry.shared.activeTodoStore
                    }, chromeStateProvider: {
                        ProjectWindowRegistry.shared.activeChromeState
                    })
                    server.start()
                    controlServer = server
                }
        }
        .defaultSize(width: 1_340, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .printItem) {
                Button("Command Palette") {
                    focusedChromeState?.presentCommandPalette()
                }
                .keyboardShortcut("p")
                .disabled(focusedChromeState == nil)
            }

            CommandMenu("Prototype") {
                Button(focusedChromeState?.isSidebarHidden == true ? "Show Sidebar" : "Hide Sidebar") {
                    focusedChromeState?.toggleSidebar()
                }
                .keyboardShortcut("s")
                .disabled(focusedChromeState == nil)

                Button("New Tab") {
                    focusedWorkspace?.addSession()
                }
                .keyboardShortcut("t")
                .disabled(focusedWorkspace == nil)

                Button("Close Tab") {
                    guard let workspace = focusedWorkspace else { return }
                    if workspace.sessions.count > 1 {
                        workspace.closeSelectedSession()
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
                .disabled(focusedWorkspace == nil)

                Button("Previous Tab") {
                    focusedWorkspace?.selectPreviousSession()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedWorkspace == nil)

                Button("Next Tab") {
                    focusedWorkspace?.selectNextSession()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedWorkspace == nil)

                Button("Interrupt Active Tab") {
                    focusedWorkspace?.interruptSelectedSession()
                }
                .keyboardShortcut("c", modifiers: [.control])
                .disabled(focusedWorkspace == nil)

                Button("Restart Active Tab") {
                    focusedWorkspace?.restartSelectedSession()
                }
                .keyboardShortcut("r")
                .disabled(focusedWorkspace == nil)

                Button("Clear Scrollback") {
                    focusedWorkspace?.clearSelectedSessionScrollback()
                }
                .keyboardShortcut("k")
                .disabled(focusedWorkspace == nil)
            }

            CommandMenu("Agents") {
                let project = agentSettings.resolvedProject(for: focusedWorkspace?.projectRoot)
                if project.launchableAgents.isEmpty {
                    Button("No Launchable Agents") {}
                        .disabled(true)
                } else {
                    ForEach(project.launchableAgents) { agent in
                        Button(agent.name) {
                            guard let workspace = focusedWorkspace, let projectRoot = project.validProjectRoot else { return }
                            workspace.addAgentSession(agent: agent.definition, projectRoot: projectRoot)
                        }
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
        }
    }
}

private struct ProjectWindowView: View {
    @ObservedObject private var agentSettings = AgentSettings.shared
    @State private var onboardedProjectRoot: String?
    @State private var lockedProjectRoot: String?

    let requestedProjectRoot: String?

    init(projectRoot: String?) {
        requestedProjectRoot = projectRoot
    }

    var body: some View {
        Group {
            if let projectRoot {
                ProjectWorkspaceView(projectRoot: projectRoot)
                    .id(projectRoot)
            } else {
                ProjectOnboardingView { project in
                    onboardedProjectRoot = project.root
                    lockedProjectRoot = project.root
                }
            }
        }
        .onAppear {
            lockProjectRootIfNeeded()
        }
    }

    private var projectRoot: String? {
        if let onboardedProjectRoot {
            return onboardedProjectRoot
        }
        if let lockedProjectRoot {
            return lockedProjectRoot
        }
        return agentSettings.projectRootForWindow(
            requestedRoot: requestedProjectRoot,
            onboardedRoot: onboardedProjectRoot
        )
    }

    private func lockProjectRootIfNeeded() {
        guard lockedProjectRoot == nil else { return }
        lockedProjectRoot = projectRoot
    }
}

private struct ProjectWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var agentSettings = AgentSettings.shared
    @StateObject private var workspace: TerminalWorkspace
    @StateObject private var chromeState = ProjectWindowChromeState()
    @StateObject private var noteStore: ProjectNoteStore
    @StateObject private var todoStore: ProjectTodoStore
    @State private var didAutoStartCommands = false

    init(projectRoot: String) {
        _workspace = StateObject(wrappedValue: TerminalWorkspace(projectRoot: projectRoot))
        _noteStore = StateObject(wrappedValue: ProjectNoteStore(projectRoot: projectRoot))
        _todoStore = StateObject(wrappedValue: ProjectTodoStore(projectRoot: projectRoot))
    }

    var body: some View {
        ContentView(
            workspace: workspace,
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
            projectRoot: workspace.projectRoot,
            openProject: openProject,
            isSidebarHidden: $chromeState.isSidebarHidden,
            isSidebarRevealed: $chromeState.isSidebarRevealed,
            isCursorOverSidebar: $chromeState.isCursorOverSidebar
        )
        .background(ProjectWindowBinder(
            projectRoot: workspace.projectRoot,
            workspace: workspace,
            noteStore: noteStore,
            todoStore: todoStore,
            chromeState: chromeState
        ))
        .focusedValue(\.terminalWorkspace, workspace)
        .focusedValue(\.projectWindowChromeState, chromeState)
        .onAppear {
            ProjectWindowRegistry.shared.activeWorkspace = workspace
            ProjectWindowRegistry.shared.activeNoteStore = noteStore
            ProjectWindowRegistry.shared.activeTodoStore = todoStore
            ProjectWindowRegistry.shared.activeChromeState = chromeState
            agentSettings.markProjectOpened(workspace.projectRoot)
            autoStartCommandsIfNeeded()
        }
    }

    private func openProject(_ project: CherryProject) {
        agentSettings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }

    private func autoStartCommandsIfNeeded() {
        guard !didAutoStartCommands, let projectRoot = workspace.projectRoot else { return }
        didAutoStartCommands = true
        for command in agentSettings.launchableProjectCommands(for: projectRoot) where command.autoStart {
            workspace.addCommandSession(command: command, projectRoot: projectRoot, select: false)
        }
    }
}
