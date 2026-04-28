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
                    })
                    server.start()
                    controlServer = server
                }
        }
        .defaultSize(width: 1_340, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
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

    let requestedProjectRoot: String?

    init(projectRoot: String?) {
        requestedProjectRoot = projectRoot
    }

    var body: some View {
        if let projectRoot {
            ProjectWorkspaceView(projectRoot: projectRoot)
                .id(projectRoot)
        } else {
            ProjectOnboardingView { project in
                onboardedProjectRoot = project.root
            }
        }
    }

    private var projectRoot: String? {
        agentSettings.projectRoot(for: requestedProjectRoot) ?? agentSettings.projectRoot(for: onboardedProjectRoot)
    }
}

private struct ProjectWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var workspace: TerminalWorkspace
    @StateObject private var chromeState = ProjectWindowChromeState()

    init(projectRoot: String) {
        _workspace = StateObject(wrappedValue: TerminalWorkspace(projectRoot: projectRoot))
    }

    var body: some View {
        ContentView(
            workspace: workspace,
            projectRoot: workspace.projectRoot,
            openProject: openProject,
            isSidebarHidden: $chromeState.isSidebarHidden,
            isSidebarRevealed: $chromeState.isSidebarRevealed,
            isCursorOverSidebar: $chromeState.isCursorOverSidebar
        )
        .background(ProjectWindowBinder(projectRoot: workspace.projectRoot, workspace: workspace))
        .focusedValue(\.terminalWorkspace, workspace)
        .focusedValue(\.projectWindowChromeState, chromeState)
        .onAppear {
            ProjectWindowRegistry.shared.activeWorkspace = workspace
        }
    }

    private func openProject(_ project: CherryProject) {
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }
}
