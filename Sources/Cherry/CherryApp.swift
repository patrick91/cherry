import AppKit
import CherryControl
import SwiftUI
import UserNotifications

final class CherryAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var openDefaultProjectWindow: (@MainActor @Sendable () -> Void)?
    var openProjectWindow: (@MainActor @Sendable (String) -> Void)?
    private var isQuitConfirmed = false
    private var didScheduleInitialWindowOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
           Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
           let iconURL = CherryResources.bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        TerminalNotificationCenter.shared.configure(delegate: self)
        MainActor.assumeIsolated {
            Self.startLaunchHousekeeping()
        }
        // Reach the local session host now, in the background, so the first
        // persistent tabs do not wait for its helper, login environment and
        // daemon to start.
        MainActor.assumeIsolated {
            SessionBackendPolicy.userSettings.persistentHostingForNewTab()?.warmUp()
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            Self.firstProjectCapableWindow?.makeKeyAndOrderFront(nil)
            self.scheduleDefaultWindowOpenIfNeeded()
        }
    }

    /// Launch work that never holds up the first window: stops the SSH
    /// masters that app runs which ended (a crash, a kill) left logged in
    /// to their servers (`HostSSHMasterManager.sweepAbandonedMasters`,
    /// which does its work in the background), whether or not this run
    /// ever uses SSH or persistent sessions; and tells the user, on the
    /// first project window, when this copy leaves the persistent sessions
    /// and saved tabs alone because another copy holds the instance lock
    /// (`InstanceLockNotice`). The parameters are for tests.
    @MainActor
    static func startLaunchHousekeeping(
        registry: ProjectWindowRegistry = .shared,
        sweepSSHMasters: () -> Void = { HostSSHMasterManager.sweepAbandonedMasters() },
        instanceLockNotice: InstanceLockNotice? = nil
    ) {
        sweepSSHMasters()
        registry.installInstanceLockNotice(instanceLockNotice ?? .app(registry: registry))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let projectWindow = MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.firstRegisteredProjectWindow()
        }
        if let projectWindow {
            projectWindow.makeKeyAndOrderFront(nil)
        } else {
            let openDefaultProjectWindow = openDefaultProjectWindow
            Task { @MainActor in
                openDefaultProjectWindow?()
            }
        }

        sender.activate(ignoringOtherApps: true)
        return false
    }

    // The MenuBarExtra's status-item window is always in `NSApp.windows`, so
    // naive first/visible checks see "a window" on a windowless launch and
    // never open the default project window. Key-capable filters it out.
    private static var firstProjectCapableWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeKey }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.handleApplicationDidBecomeActive()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.markCurrentActiveProjectOpened()
        }

        guard !isQuitConfirmed else { return .terminateNow }

        // Save every window's tabs and the open windows before anything is
        // torn down: the teardown saves nothing.
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.flushWorkspacePersistence()
        }

        // What quitting ends: native tabs' processes, and persistent tabs'
        // sessions only with Settings › Sessions › End sessions when quitting
        // (otherwise they keep running and come back at the next launch).
        let (runningCount, endedSessionCount) = MainActor.assumeIsolated {
            (
                ProjectWindowRegistry.shared.runningProcessCount(endingWith: .appQuit),
                ProjectWindowRegistry.shared.persistentSessionCountEndedByQuit()
            )
        }
        // Nothing running: quit immediately. Idle shells exit on the SIGHUP they
        // receive when Cherry dies, so there's nothing to confirm — like ghostty.
        guard runningCount > 0 else {
            guard endedSessionCount > 0 else {
                MainActor.assumeIsolated {
                    ProjectWindowRegistry.shared.prepareForTermination()
                }
                return .terminateNow
            }
            // Idle persistent sessions that quitting ends: end them, then quit.
            finishQuit()
            return .terminateLater
        }

        let alert = NSAlert()
        alert.messageText = "Quit Cherry?"
        alert.informativeText = runningCount == 1
            ? "1 running process will be stopped."
            : "\(runningCount) running processes will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        // The sheet goes on a project window the user can see: never the
        // menu bar panel (which closes as soon as it loses focus), a
        // closed or minimized window, or the status item's.
        let window = MainActor.assumeIsolated { Self.visibleProjectWindowForQuitConfirmation() }
        if let window {
            // Closing the sheet's window before it is answered cancels the
            // quit: AppKit is never left waiting for a reply.
            let answer = MainActor.assumeIsolated {
                QuitConfirmationAnswer(parent: window) { [weak self] confirmed in
                    guard confirmed else {
                        self?.cancelQuit()
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    self?.finishQuit()
                }
            }
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer.resolve(response == .alertFirstButtonReturn) }
            }
            return .terminateLater
        } else if alert.runModal() == .alertFirstButtonReturn {
            finishQuit()
            return .terminateLater
        } else {
            cancelQuit()
            return .terminateCancel
        }
    }

    /// The project window a quit confirmation sheet goes on
    /// (`quitConfirmationParent`), brought on screen (unhidden,
    /// deminiaturized, in front). Nil when no project window is open; the
    /// confirmation is then an app-modal alert.
    @MainActor
    static func visibleProjectWindowForQuitConfirmation() -> NSWindow? {
        let registry = ProjectWindowRegistry.shared
        guard let window = quitConfirmationParent(
            keyWindow: NSApp.keyWindow,
            keyWindowIsProjectWindow: registry.keyWindowWorkspace != nil,
            activeProjectWindow: registry.firstRegisteredProjectWindow()
        ) else { return nil }
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window.isVisible ? window : nil
    }

    /// Which window the quit confirmation goes on: the key window when it
    /// is a project window, else the active project's window (the
    /// registry's; nil when none is open). Never another key window: the
    /// menu bar panel closes as soon as it loses focus, taking the sheet
    /// with it, and the status item's window is not one the user sees.
    @MainActor
    static func quitConfirmationParent(
        keyWindow: NSWindow?,
        keyWindowIsProjectWindow: Bool,
        activeProjectWindow: NSWindow?
    ) -> NSWindow? {
        if let keyWindow, keyWindowIsProjectWindow {
            return keyWindow
        }
        return activeProjectWindow
    }

    private func cancelQuit() {
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.cancelTermination()
        }
    }

    /// Tear down every window's tabs (tabs and windows that changed while the
    /// alert was up are saved first), then let the pending termination go
    /// through once their programs have ended: native tabs get the HUP →
    /// TERM → KILL escalation's 900 ms (app termination skips the per-window
    /// `windowWillClose` teardown, so without this a SIGHUP-ignoring server
    /// like `tilt up` would outlive Cherry), and persistent sessions a quit
    /// ends get a bounded wait for their host to confirm they exited.
    private func finishQuit() {
        isQuitConfirmed = true
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.tearDownForQuit()
            Self.hasRepliedToTermination = false
        }
        let reply: @MainActor @Sendable () -> Void = {
            guard !CherryAppDelegate.hasRepliedToTermination else { return }
            CherryAppDelegate.hasRepliedToTermination = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            let started = ContinuousClock.now
            // Tabs whose session was still being created (or whose restart
            // waited for the previous program) end what their Create makes;
            // then every ending is waited for, 8 s in all.
            await TerminalSession.waitForPersistentLaunches(upTo: .seconds(6))
            let endsBudget = max(.seconds(8) - (ContinuousClock.now - started), .seconds(2))
            _ = await PersistentLocalSessions.shared.waitForPendingEnds(timeout: endsBudget)
            let remaining = .milliseconds(900) - (ContinuousClock.now - started)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            reply()
        }
        // While a quit waits (`.terminateLater`), AppKit runs the run loop in
        // its modal panel mode. When the quit was asked for from inside a
        // main-queue block (a main-actor Task or a DispatchQueue.main block
        // calling `NSApp.terminate`), the main queue, and with it the task
        // above, cannot run until the reply: only a run loop timer still
        // fires, and lets the quit through.
        let deadline = Timer(timeInterval: Self.quitReplyDeadline, repeats: false) { _ in
            MainActor.assumeIsolated { reply() }
        }
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .modalPanel)
    }

    /// The longest a confirmed quit waits for sessions and processes to end.
    private static let quitReplyDeadline: TimeInterval = 10
    @MainActor private static var hasRepliedToTermination = false

    private func scheduleDefaultWindowOpenIfNeeded() {
        guard !didScheduleInitialWindowOpen else { return }
        didScheduleInitialWindowOpen = true
        let openDefaultProjectWindow = openDefaultProjectWindow
        let openProjectWindow = openProjectWindow

        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }

            // Windows that had tabs come back even when macOS window
            // restoration is off. One SwiftUI already restored is skipped, and
            // opening a scene value that has a window only focuses it.
            let reopenedProjectWindow = openProjectWindow.map {
                ProjectWindowRegistry.shared.reopenSavedProjectWindows($0)
            } ?? false

            guard !reopenedProjectWindow,
                  !ProjectWindowRegistry.shared.hasRegisteredProjectWindow,
                  !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey })
            else {
                return
            }

            openDefaultProjectWindow?()
        }
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

/// The quit confirmation's one answer: the sheet's, or false when the
/// window it is on closes first (the quit is then cancelled, so AppKit is
/// never left waiting for a reply to `.terminateLater`). Later answers are
/// ignored.
@MainActor
final class QuitConfirmationAnswer {
    private var answer: (@MainActor (Bool) -> Void)?
    private var parentClose: NSObjectProtocol?

    init(parent: NSWindow, answer: @escaping @MainActor (Bool) -> Void) {
        self.answer = answer
        // Held by the notification center until resolved.
        parentClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.resolve(false) }
        }
    }

    var isResolved: Bool { answer == nil }

    /// Answers the quit once; later calls do nothing.
    func resolve(_ confirmed: Bool) {
        guard let answer else { return }
        self.answer = nil
        if let parentClose {
            NotificationCenter.default.removeObserver(parentClose)
            self.parentClose = nil
        }
        answer(confirmed)
    }
}

@main
struct CherryApp: App {
    private static let projectWindowSceneID = "project"

    @NSApplicationDelegateAdaptor(CherryAppDelegate.self) private var appDelegate
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @StateObject private var menuBarAgents = MenuBarAgentsModel()
    @State private var controlServer: CherryControlServer?
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.terminalWorkspace) private var focusedWorkspace
    @FocusedValue(\.projectWindowChromeState) private var focusedChromeState

    init() {
        RemoteViewCrashGuard.installIfNeeded()
        ProjectWindowRegistry.shared.configureWorkspacePersistence(store: .shared)
    }

    // Menu actions resolve their target from the key window, not the
    // focused values: `@FocusedValue` only updates while SwiftUI owns
    // focus, so with the AppKit terminal view as first responder it can
    // keep pointing at a previously focused window — sending shortcuts
    // like ^C to the wrong window. Focused values stay in use for menu
    // labels and enablement, where staleness is cosmetic.
    private var keyWindowWorkspace: TerminalWorkspace? {
        ProjectWindowRegistry.shared.keyWindowWorkspace ?? focusedWorkspace
    }

    private var keyWindowRepository: RepositoryWorkspace? {
        ProjectWindowRegistry.shared.keyWindowRepository
    }

    private var keyWindowChromeState: ProjectWindowChromeState? {
        ProjectWindowRegistry.shared.keyWindowChromeState ?? focusedChromeState
    }

    private var canSplitFocusedTerminal: Bool {
        guard let workspace = focusedWorkspace,
              let session = workspace.selectedSession,
              session.kind == .terminal
        else {
            return false
        }
        return workspace.canAddSplitPane(to: session.id)
    }

    private var focusedWorkspaceHasActiveSplit: Bool {
        guard let workspace = focusedWorkspace,
              let selectedSessionID = workspace.selectedSessionID
        else {
            return false
        }
        return workspace.splitGroup(containing: selectedSessionID) != nil
    }

    private var closeTabTitle: String {
        focusedWorkspaceHasActiveSplit ? "Close Pane" : "Close Tab"
    }

    var body: some Scene {
        let _ = configureDefaultWindowOpener()

        WindowGroup("Cherry", id: Self.projectWindowSceneID, for: String.self) { projectRoot in
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
                    }, openProjectProvider: { projectRoot in
                        agentSettings.markProjectOpened(projectRoot)
                        guard !ProjectWindowRegistry.shared.focus(projectRoot: projectRoot) else { return }
                        openWindow(id: Self.projectWindowSceneID, value: projectRoot)
                    })
                    server.start()
                    controlServer = server
                }
        }
        .defaultSize(width: 1_340, height: 840)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.automatic)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Persistent Sessions…") {
                    keyWindowChromeState?.isHostedSessionsPresented = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedWorkspace == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Command Palette") {
                    keyWindowChromeState?.presentCommandPalette()
                }
                .keyboardShortcut("p")
                .disabled(focusedChromeState == nil)
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Find") {
                    keyWindowWorkspace?.selectedSession?.ghosttyBridge.startSearch()
                }
                .keyboardShortcut("f")
                .disabled(focusedWorkspace?.selectedSession == nil || focusedChromeState == nil)

                Button("Find Next") {
                    keyWindowWorkspace?.selectedSession?.ghosttyBridge.navigateSearch(next: true)
                }
                .keyboardShortcut("g")
                .disabled(focusedWorkspace?.selectedSession == nil)

                Button("Find Previous") {
                    keyWindowWorkspace?.selectedSession?.ghosttyBridge.navigateSearch(next: false)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(focusedWorkspace?.selectedSession == nil)

                Button("Hide Find Bar") {
                    keyWindowWorkspace?.selectedSession?.ghosttyBridge.endSearch()
                    keyWindowChromeState?.dismissTerminalSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(focusedWorkspace?.selectedSession == nil || focusedChromeState == nil)
            }

            CommandMenu("Prototype") {
                Button(focusedChromeState?.isSidebarHidden == true ? "Show Sidebar" : "Hide Sidebar") {
                    keyWindowChromeState?.toggleSidebar()
                }
                .keyboardShortcut("s")
                .disabled(focusedChromeState == nil)

                if PrototypeFeatureFlags.isIconDebugEnabled {
                    Button(focusedChromeState?.isIconDebugOverlayPresented == true ? "Hide Icon Debug Overlay" : "Show Icon Debug Overlay") {
                        keyWindowChromeState?.toggleIconDebugOverlay()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(focusedChromeState == nil)
                }

                Button(focusedChromeState?.isSidebarPlaygroundPresented == true ? "Hide Sidebar Icon Playground" : "Show Sidebar Icon Playground") {
                    keyWindowChromeState?.toggleSidebarPlayground()
                }
                .disabled(focusedChromeState == nil)

                Button(focusedChromeState?.isCommandPalettePlaygroundPresented == true ? "Hide Command Palette Playground" : "Show Command Palette Playground") {
                    keyWindowChromeState?.toggleCommandPalettePlayground()
                }
                .disabled(focusedChromeState == nil)

                Button(focusedChromeState?.isProjectTabsPrototypePresented == true ? "Hide Project Tabs Prototype" : "Show Project Tabs Prototype") {
                    keyWindowChromeState?.toggleProjectTabsPrototype()
                }
                .disabled(focusedChromeState == nil)

                Button("New Tab") {
                    keyWindowWorkspace?.addSession()
                }
                .keyboardShortcut("t")
                .disabled(focusedWorkspace == nil)

                Button("Split Right") {
                    keyWindowWorkspace?.splitDuplicateActiveTerminal()
                }
                .keyboardShortcut("d")
                .disabled(!canSplitFocusedTerminal)

                Button(focusedChromeState?.selectedNoteID == nil ? closeTabTitle : "Close Note") {
                    guard let workspace = keyWindowWorkspace else { return }
                    SessionCloseCoordinator.closeSelectedTabOrWindow(
                        workspace: workspace,
                        repository: keyWindowRepository,
                        chromeState: keyWindowChromeState,
                        window: NSApp.keyWindow
                    )
                }
                .keyboardShortcut("w")
                .disabled(focusedWorkspace == nil)

                Button("Previous Pane") {
                    keyWindowWorkspace?.focusPreviousPane()
                }
                .keyboardShortcut("[")
                .disabled(!focusedWorkspaceHasActiveSplit)

                Button("Next Pane") {
                    keyWindowWorkspace?.focusNextPane()
                }
                .keyboardShortcut("]")
                .disabled(!focusedWorkspaceHasActiveSplit)

                Button("Previous Tab") {
                    keyWindowWorkspace?.selectPreviousSession()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedWorkspace == nil)

                Button("Next Tab") {
                    keyWindowWorkspace?.selectNextSession()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedWorkspace == nil)

                Button("\(focusedWorkspace?.selectedSession?.restartActionTitle ?? "Restart") Active Tab") {
                    keyWindowWorkspace?.restartSelectedSession()
                }
                .keyboardShortcut("r")
                .disabled(focusedWorkspace == nil || focusedWorkspace?.selectedSession?.canRestart == false)

                Button("Clear Scrollback") {
                    keyWindowWorkspace?.clearSelectedSessionScrollback()
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
                            guard let workspace = keyWindowWorkspace,
                                  let projectRoot = agentSettings.resolvedProject(for: workspace.projectRoot).validProjectRoot
                            else { return }
                            keyWindowChromeState?.selectTerminal()
                            workspace.addAgentSession(agent: agent.definition, projectRoot: projectRoot)
                        }
                    }
                }
            }
        }

        MenuBarExtra {
            MenuBarAgentsPanel(model: menuBarAgents)
        } label: {
            MenuBarStatusLabel(model: menuBarAgents)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
        }
    }

    private func configureDefaultWindowOpener() {
        appDelegate.openProjectWindow = { projectRoot in
            guard !ProjectWindowRegistry.shared.hasWindow(for: projectRoot) else { return }
            openWindow(id: Self.projectWindowSceneID, value: projectRoot)
        }
        appDelegate.openDefaultProjectWindow = {
            if let projectRoot = agentSettings.projectRoot(for: nil) {
                agentSettings.markProjectOpened(projectRoot)
                guard !ProjectWindowRegistry.shared.focus(projectRoot: projectRoot) else { return }
                openWindow(id: Self.projectWindowSceneID, value: projectRoot)
            } else {
                openWindow(id: Self.projectWindowSceneID)
            }
        }
    }
}

private struct ProjectWindowView: View {
    @Environment(\.openWindow) private var openWindow
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
        .onOpenURL(perform: openDeepLink)
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

    private func openDeepLink(_ url: URL) {
        guard let deepLink = try? CherryDeepLink.parse(url.absoluteString),
              let projectRoot = ProjectWindowRegistry.shared.projectRoot(forProjectKey: deepLink.projectKey)
        else {
            return
        }

        agentSettings.markProjectOpened(projectRoot)
        let shouldActivateWorktree: Bool
        switch deepLink.kind {
        case .terminal:
            shouldActivateWorktree = true
        case .note, .todo:
            shouldActivateWorktree = false
        }
        if ProjectWindowRegistry.shared.focus(
            projectRoot: projectRoot,
            activateWorktree: shouldActivateWorktree
        ) {
            if !ProjectWindowRegistry.shared.select(deepLink, projectRoot: projectRoot) {
                CherryDeepLinkOpenQueue.shared.enqueue(deepLink, projectRoot: projectRoot)
            }
        } else {
            CherryDeepLinkOpenQueue.shared.enqueue(deepLink, projectRoot: projectRoot)
            openWindow(value: projectRoot)
        }
    }
}

/// Observes the currently selected session and keeps the AppKit window title in
/// sync as "<project> — <selected tab>". @ObservedObject so a live title change
/// (e.g. an agent renaming its tab) updates the window title while the tab stays
/// selected; the parent re-passes a new `session` when the selection changes.
private struct WindowTitleBinder: View {
    let projectName: String
    @ObservedObject var session: TerminalSession

    var body: some View {
        WindowTitleWriter(title: windowTitle)
    }

    private var windowTitle: String {
        let tab = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.isEmpty ? projectName : "\(projectName) — \(tab)"
    }
}

/// Writes a string to the enclosing window's `title`. The titlebar text is hidden
/// (custom chrome), but the title still drives the Window menu, Mission Control,
/// and the app switcher. Reactive: a changed `title` re-runs `updateNSView`.
private struct WindowTitleWriter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let title = title
        DispatchQueue.main.async {
            guard let window = nsView.window, window.title != title else { return }
            window.title = title
        }
    }
}

private struct ProjectWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var agentSettings = AgentSettings.shared
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var repository: RepositoryWorkspace
    @StateObject private var chromeState = ProjectWindowChromeState()
    @StateObject private var noteStore: ProjectNoteStore
    @StateObject private var todoStore: ProjectTodoStore
    @SceneStorage("sidebar.width") private var storedSidebarWidth: Double = 320

    init(projectRoot: String) {
        _repository = StateObject(wrappedValue: RepositoryWorkspace(
            projectRoot: projectRoot,
            backendPolicy: .userSettings,
            stateStore: .shared,
            sessionRestorer: WorkspaceSessionRestorers.hostedByDefault(localSessions: .shared)
        ))
        _noteStore = StateObject(wrappedValue: ProjectNoteStore(
            projectRoot: projectRoot,
            loadsInBackground: true
        ))
        _todoStore = StateObject(wrappedValue: ProjectTodoStore(projectRoot: projectRoot))
    }

    /// Folder name of the project, or "Cherry" for a project-less window.
    private var projectName: String {
        repository.repositoryName.isEmpty ? "Cherry" : repository.repositoryName
    }

    private var workspace: TerminalWorkspace {
        repository.activeWorkspace
    }

    private var workspaceTitle: String {
        guard repository.supportsWorktrees,
              let worktree = repository.activeWorktree
        else {
            return projectName
        }
        return "\(projectName) / \(worktree.displayName)"
    }

    var body: some View {
        ContentView(
            repository: repository,
            workspace: workspace,
            chromeState: chromeState,
            noteStore: noteStore,
            todoStore: todoStore,
            projectRoot: workspace.projectRoot,
            openProject: openProject,
            isSidebarHidden: $chromeState.isSidebarHidden,
            isSidebarRevealed: $chromeState.isSidebarRevealed,
            isCursorOverSidebar: $chromeState.isCursorOverSidebar,
            storedSidebarWidth: $storedSidebarWidth
        )
        .background(ProjectWindowBinder(
            projectRoot: repository.repositoryRoot,
            workspace: workspace,
            repository: repository,
            noteStore: noteStore,
            todoStore: todoStore,
            chromeState: chromeState
        ))
        .background {
            if let session = workspace.selectedSession {
                WindowTitleBinder(projectName: workspaceTitle, session: session)
            } else {
                WindowTitleWriter(title: workspaceTitle)
            }
        }
        .focusedValue(\.terminalWorkspace, workspace)
        .focusedValue(\.projectWindowChromeState, chromeState)
        .onAppear {
            ProjectWindowRegistry.shared.activeWorkspace = workspace
            ProjectWindowRegistry.shared.activeNoteStore = noteStore
            ProjectWindowRegistry.shared.activeTodoStore = todoStore
            ProjectWindowRegistry.shared.activeChromeState = chromeState
            if Self.isAgentTreePreviewEnabled {
                _ = workspace.installPreviewAgentTree()
            }
            agentSettings.markProjectOpened(workspace.projectRoot)
            // Waits for the window's saved tabs to be restored, so a restored
            // command tab is not started twice.
            repository.autoStartInitialCommandsIfNeeded()
            openPendingDeepLinks()
            Task {
                await repository.refresh()
            }
        }
        .onChange(of: repository.activeWorktreeRoot) { _, _ in
            // RepositoryWorkspace synchronously updates the window registry as
            // part of activation. Repeating it here acknowledged sessions and
            // persisted the same root a second time during the first render of
            // every switch.
            openPendingDeepLinks()
        }
        .onChange(of: noteStore.isLoading) { _, isLoading in
            if !isLoading {
                openPendingDeepLinks()
            }
        }
        .onChange(of: terminalSettings.worktreeSpacesEnabled) { _, isEnabled in
            if isEnabled {
                Task {
                    await repository.refresh()
                }
            } else {
                repository.disableWorktreeSpaces(chromeState: chromeState)
            }
        }
    }

    private static var isAgentTreePreviewEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["CHERRY_PREVIEW_AGENT_TREE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private func openProject(_ project: CherryProject) {
        agentSettings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: project.root)
    }

    private func openPendingDeepLinks() {
        guard !noteStore.isLoading else { return }
        guard let projectRoot = workspace.projectRoot else { return }
        var links = CherryDeepLinkOpenQueue.shared.consume(projectRoot: projectRoot)
        if repository.repositoryRoot != projectRoot {
            links.append(contentsOf: CherryDeepLinkOpenQueue.shared.consume(
                projectRoot: repository.repositoryRoot
            ))
        }
        guard !links.isEmpty else { return }
        DispatchQueue.main.async {
            for link in links {
                if !selectDeepLink(link) {
                    _ = ProjectWindowRegistry.shared.select(link, projectRoot: projectRoot)
                }
            }
        }
    }

    @discardableResult
    private func selectDeepLink(_ link: CherryDeepLink) -> Bool {
        switch link.kind {
        case .note:
            let projectRoot = repository.repositoryRoot
            guard CherryDeepLink.projectKey(forProjectRoot: projectRoot) == link.projectKey,
                  agentSettings.projectFeatures(for: projectRoot).notesEnabled
            else {
                return false
            }
            guard let noteID = UUID(uuidString: link.targetID),
                  noteStore.notes.contains(where: { $0.id == noteID })
            else {
                return false
            }
            chromeState.selectNote(id: noteID)
            return true
        case .todo:
            let projectRoot = repository.repositoryRoot
            guard CherryDeepLink.projectKey(forProjectRoot: projectRoot) == link.projectKey,
                  agentSettings.projectFeatures(for: projectRoot).todosEnabled
            else {
                return false
            }
            guard let todoID = UUID(uuidString: link.targetID),
                  todoStore.todos.contains(where: { $0.id == todoID })
            else {
                return false
            }
            chromeState.selectTodo(id: todoID)
            return true
        case .terminal:
            guard let projectRoot = workspace.projectRoot,
                  CherryDeepLink.projectKey(forProjectRoot: projectRoot) == link.projectKey,
                  let sessionID = UUID(uuidString: link.targetID),
                  let session = workspace.sessions.first(where: { $0.id == sessionID })
            else {
                return false
            }
            workspace.select(session)
            chromeState.selectTerminal()
            return true
        }
    }
}

@MainActor
private final class CherryDeepLinkOpenQueue {
    static let shared = CherryDeepLinkOpenQueue()

    private var linksByProjectRoot: [String: [CherryDeepLink]] = [:]

    private init() {}

    func enqueue(_ link: CherryDeepLink, projectRoot: String) {
        linksByProjectRoot[projectRoot, default: []].append(link)
    }

    func consume(projectRoot: String) -> [CherryDeepLink] {
        linksByProjectRoot.removeValue(forKey: projectRoot) ?? []
    }
}
