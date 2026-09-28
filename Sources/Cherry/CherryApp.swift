import AppKit
import CherryControl
import SwiftUI
import UserNotifications

final class CherryAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var openDefaultProjectWindow: (@MainActor @Sendable () -> Void)?
    var openProjectWindow: (@MainActor @Sendable (String) -> Void)?
    private var isQuitConfirmed = false
    /// Whether the latest quit to ask to terminate came with a quit Apple
    /// event naming a log out, restart or shut down (`kAEQuitReason`), not
    /// only one within `powerOffAnnouncementLifetime` of the system
    /// announcing one (which a cancelled log out leaves behind).
    private var lastQuitWasPowerOffEvent = false
    private var didScheduleInitialWindowOpen = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.configureSessionRecords(localSessions: .shared, store: .shared)
            // Each device's hosting records the same (docs/specs/remote-devices.md).
            RemoteDeviceStore.shared.endedSessionsStore = .shared
        }
    }

    /// Before any window restores or closes tabs: the sessions this app ends
    /// on purpose, and those the host reports lost, are recorded in `store`
    /// (`SystemEndedSessions`).
    @MainActor
    static func configureSessionRecords(localSessions: PersistentLocalSessions, store: WorkspaceStateStore) {
        localSessions.endedSessionsStore = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.observeQuitReasons()
        }
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
        MainActor.assumeIsolated {
            Self.finishLaunchingAfterInstanceLock(lock: .shared, store: .shared) {
                // Reach the local session host now, in the background, so
                // the first persistent tabs do not wait for its helper,
                // login environment and daemon to start.
                SessionBackendPolicy.userSettings.persistentHostingForNewTab()?.warmUp()
                // The menu bar's Background Sessions list; it starts no host.
                BackgroundSessionsModel.shared.start()
                // Each device's hosting, which finishes the ends it could
                // not do while its Mac was offline once that Mac answers
                // (it connects to none now).
                RemoteDeviceStore.shared.registerHostings()
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    Self.firstProjectCapableWindow?.makeKeyAndOrderFront(nil)
                    self.scheduleDefaultWindowOpenIfNeeded()
                }
            }
        }
    }

    /// Everything that needs to know whether this copy holds the instance
    /// lock waits for it off the main thread (`InstanceLockLaunchWait`: a
    /// copy launched while the previous one quits says so meanwhile), then
    /// runs in this order: old set-aside state files are pruned (`store`,
    /// which asks the lock), then `launch` (the warm-up, Background
    /// Sessions, the first windows). Nothing here touches the lock on the
    /// main thread before it is resolved.
    @MainActor
    @discardableResult
    static func finishLaunchingAfterInstanceLock(
        lock: AppInstanceLock,
        store: WorkspaceStateStore,
        presenter: InstanceLockLaunchWait.Presenter? = nil,
        then launch: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        InstanceLockLaunchWait.run(lock: lock, presenter: presenter ?? .app) {
            // Old copies of state files this version could not use.
            store.pruneSetAsideFiles()
            launch()
        }
    }

    /// What a Dock click does (`applicationShouldHandleReopen`).
    enum ReopenAction: Equatable {
        /// Bring the first project window forward.
        case focusProjectWindow
        /// Open the default project window.
        case openDefaultWindow
        /// The launch still waits for the instance lock and opens the
        /// windows itself once it has it: opening one now would load saved
        /// tabs on the main thread while the lock is not resolved.
        case waitForLaunch
    }

    static func reopenAction(lockResolved: Bool, hasProjectWindow: Bool) -> ReopenAction {
        guard lockResolved else { return .waitForLaunch }
        return hasProjectWindow ? .focusProjectWindow : .openDefaultWindow
    }

    /// A quit asked while the launch still waits for the instance lock
    /// terminates at once: no window opened, nothing of this copy's is
    /// saved or ended yet, and asking the lock now would block the main
    /// thread until the previous copy quits.
    static func quitsAtOnce(lockResolved: Bool) -> Bool {
        !lockResolved
    }

    /// Launch work that never holds up the first window: stops the SSH
    /// masters that app runs which ended (a crash, a kill) left logged in
    /// to their servers (`HostSSHMasterManager.sweepAbandonedMasters`,
    /// which does its work in the background), whether or not this run
    /// ever uses SSH or persistent sessions; and tells the user, on the
    /// first project window, when this copy leaves the persistent sessions
    /// and saved tabs alone because another copy holds the instance lock
    /// (`InstanceLockNotice`), or, once the launch's windows opened, that
    /// sessions of closed windows or tabs still run in the background
    /// (`BackgroundSessionsNotice`). The parameters are for tests.
    @MainActor
    static func startLaunchHousekeeping(
        registry: ProjectWindowRegistry = .shared,
        sweepSSHMasters: () -> Void = { HostSSHMasterManager.sweepAbandonedMasters() },
        instanceLockNotice: InstanceLockNotice? = nil,
        backgroundSessionsNotice: BackgroundSessionsNotice? = nil
    ) {
        sweepSSHMasters()
        registry.installInstanceLockNotice(instanceLockNotice ?? .app(registry: registry))
        registry.installBackgroundSessionsNotice(backgroundSessionsNotice ?? .app(registry: registry))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let projectWindow = MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.firstRegisteredProjectWindow()
        }
        let action = Self.reopenAction(lockResolved: AppInstanceLock.shared.isResolved, hasProjectWindow: projectWindow != nil)
        if action == .waitForLaunch {
            // The launch opens the windows once it has the lock.
        } else if let projectWindow {
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
        if Self.quitsAtOnce(lockResolved: AppInstanceLock.shared.isResolved) { return .terminateNow }
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.markCurrentActiveProjectOpened()
        }

        guard !isQuitConfirmed else { return .terminateNow }

        let reason = MainActor.assumeIsolated { Self.currentQuitReason() }
        lastQuitWasPowerOffEvent = Self.isPowerOffQuit(NSAppleEventManager.shared().currentAppleEvent)
        if let window = MainActor.assumeIsolated({ Self.windowToAnswerBeforeQuitting(reason: reason, among: NSApp.windows) }) {
            // A window's close question is up, or a tab close's: its answer
            // keeps, detaches or ends sessions, so the quit's own question
            // (which would queue behind it and list them still) waits for
            // it. Quit again once it is answered.
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return .terminateCancel
        }

        // Save every window's tabs and the open windows before anything is
        // torn down: the teardown saves nothing.
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.flushWorkspacePersistence()
        }

        // One dialog at most: the question about local sessions still
        // running (Settings › Sessions can keep or end them without it),
        // which also names the native programs quitting stops, or else the
        // confirmation for those programs. A log out, restart, shut down or
        // update asks nothing about sessions and ends none itself; a log
        // out, restart or shut down still confirms the busy programs of
        // persistent tabs, which the system is about to end.
        let (summary, decision) = MainActor.assumeIsolated {
            let summary = ProjectWindowRegistry.shared.teardownSummary(
                pathDisplayMode: TerminalSettings.shared.sidebarTerminalPathDisplayMode
            )
            let decision = SessionTeardownConfirmation.decide(
                summary,
                preference: TerminalSettings.shared.localSessionsOnQuit,
                mayAsk: reason == .user,
                systemEndsSessions: reason == .powerOff
            )
            return (summary, decision)
        }
        switch SessionQuitPlan(decision, summary: summary) {
        case .terminateNow:
            // Nothing running: quit immediately. Idle shells exit on the
            // SIGHUP they receive when Cherry dies, so there's nothing to
            // confirm — like ghostty. Kept sessions outlive the app. Only
            // sessions still being ended (a tab closed just before) are
            // waited for (`finishQuit`).
            return finishQuit(intent: .appQuit)
        case .finish(let intent):
            // Sessions quitting ends with nothing to ask (idle persistent
            // tabs, or saved tabs no open tab shows): end them, then quit.
            return finishQuit(intent: intent)
        case .confirmStopping(let count, let intent):
            return confirmStoppingProcesses(count, intent: intent)
        case .askAboutSessions:
            return askAboutSessions(SessionTeardownQuestion(teardown: .quit, summary: summary, projectName: nil))
        }
    }

    /// The project window whose close question, or tab close question
    /// ("Close “<name>”?", "Close Agent Group?"), must be answered before
    /// the user's quit asks its own (`ProjectWindowCloseDelegate`); none
    /// for a log out, restart, shut down or update, which never wait.
    @MainActor
    static func windowToAnswerBeforeQuitting(reason: QuitReason, among windows: [NSWindow]) -> NSWindow? {
        guard reason == .user else { return nil }
        return ProjectWindowCloseDelegate.windowAskingToClose(among: windows)
    }

    /// "Quit Cherry?" for `count` busy programs quitting stops.
    @MainActor
    private func confirmStoppingProcesses(_ count: Int, intent: SessionCloseIntent) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit Cherry?"
        alert.informativeText = count == 1
            ? "1 running process will be stopped."
            : "\(count) running processes will be stopped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        // The sheet goes on a project window the user can see: never the
        // menu bar panel (which closes as soon as it loses focus), a
        // closed or minimized window, or the status item's.
        if let window = Self.visibleProjectWindowForQuitConfirmation() {
            // Closing the sheet's window before it is answered cancels the
            // quit: AppKit is never left waiting for a reply.
            let answer = QuitConfirmationAnswer(parent: window) { [weak self] confirmed in
                guard confirmed, let self else {
                    self?.cancelQuit()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
                Self.replyToTermination(self.finishQuit(intent: intent))
            }
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { answer.resolve(response == .alertFirstButtonReturn) }
            }
            return .terminateLater
        } else if alert.runModal() == .alertFirstButtonReturn {
            return finishQuit(intent: intent)
        } else {
            cancelQuit()
            return .terminateCancel
        }
    }

    /// "Keep N sessions running in the background?", where the quit
    /// confirmation goes. Keep Running and End Sessions quit with that
    /// intent (`finishQuit`: Keep Running quits at once unless native
    /// programs must stop); "Don't ask again" stores the answer.
    @MainActor
    private func askAboutSessions(_ question: SessionTeardownQuestion) -> NSApplication.TerminateReply {
        let alert = question.makeAlert()
        // How the quit goes on.
        let finish: @MainActor (SessionTeardownAnswer) -> NSApplication.TerminateReply = { [weak self] answer in
            guard let self, let intent = SessionTeardown.quit.intent(for: answer) else {
                self?.cancelQuit()
                return .terminateCancel
            }
            return self.finishQuit(intent: intent)
        }
        let remember = { (answered: (answer: SessionTeardownAnswer, remember: LocalSessionsOnQuit?)) in
            if let remember = answered.remember {
                SessionBackendPolicy.userSettings.rememberLocalSessionsOnQuit(remember)
            }
        }
        guard let window = Self.visibleProjectWindowForQuitConfirmation() else {
            let answered = SessionTeardownQuestion.answer(of: alert, response: alert.runModal())
            remember(answered)
            return finish(answered.answer)
        }
        // Closing the sheet's window before it is answered cancels the
        // quit, as for "Quit Cherry?".
        let answer = QuitConfirmationAnswer<SessionTeardownAnswer>(parent: window, cancelled: .cancel) { answer in
            Self.replyToTermination(finish(answer))
        }
        RemoteViewCrashGuard.installIfNeeded()
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard !answer.isResolved else { return }
                let answered = SessionTeardownQuestion.answer(of: alert, response: response)
                remember(answered)
                answer.resolve(answered.answer)
            }
        }
        return .terminateLater
    }

    // MARK: Why the app quits

    /// Why Cherry quits, as far as asking about local sessions goes.
    enum QuitReason: Equatable {
        /// The user quit (the menu, ⌘Q, the Dock, the menu bar panel,
        /// Activity Monitor or AppleScript): the preference applies.
        case user
        /// Log out, restart or shut down: sessions are kept, unasked (the
        /// system ends them anyway, and waiting would hold it up), but busy
        /// programs in them are confirmed as native ones are.
        case powerOff
        /// A new version replaced this one: sessions are kept, unasked.
        case update
    }

    /// The quit reasons (`kAEQuitReason`) of a log out, restart or shut down.
    private static let powerOffQuitReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
        OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)
    ]

    /// How long a log out, restart or shut down the system announced
    /// (`willPowerOffNotification`) counts for a quit Apple event that does
    /// not say why (never for ⌘Q or a menu's Quit, which send none): a log
    /// out another app cancels leaves no trace.
    private static let powerOffAnnouncementLifetime: TimeInterval = 300

    /// `CFBundleVersion` of the app on disk at launch (nil for `swift run`).
    @MainActor private static var launchBundleVersion: String?
    @MainActor private static var powerOffAnnouncedAt: Date?
    /// `terminateKeepingSessions()` asked for this quit.
    @MainActor private static var quitKeepsSessionsForUpdate = false
    @MainActor private static var powerOffObserver: NSObjectProtocol?

    @MainActor
    private static func observeQuitReasons() {
        launchBundleVersion = bundleVersionOnDisk()
        guard powerOffObserver == nil else { return }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { powerOffAnnouncedAt = Date() }
        }
    }

    /// Quits keeping every local session running, asking nothing about
    /// them, as an update does: for an updater that relaunches the app. On
    /// the main thread.
    func terminateKeepingSessions() {
        MainActor.assumeIsolated {
            Self.quitKeepsSessionsForUpdate = true
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func currentQuitReason() -> QuitReason {
        quitReason(
            appleEvent: NSAppleEventManager.shared().currentAppleEvent,
            launchBundleVersion: launchBundleVersion,
            diskBundleVersion: bundleVersionOnDisk(),
            powerOffAnnounced: powerOffAnnouncedAt.map { Date().timeIntervalSince($0) < powerOffAnnouncementLifetime } ?? false,
            updateRequested: quitKeepsSessionsForUpdate
        )
    }

    /// Why this quit happens. `appleEvent`: the quit Apple event being
    /// handled, whose `kAEQuitReason` names a log out, restart or shut down
    /// (none for ⌘Q, which sends no event); with `powerOffAnnounced` (the
    /// system announced one) any quit event counts. A quit is an update
    /// when the app on disk has another `CFBundleVersion` than at launch
    /// (Scripts/install-local-app and Scripts/package-dmg stamp each build,
    /// and an install replaces the app while it runs), or when an updater
    /// asked for it.
    nonisolated static func quitReason(
        appleEvent: NSAppleEventDescriptor?,
        launchBundleVersion: String?,
        diskBundleVersion: String?,
        powerOffAnnounced: Bool = false,
        updateRequested: Bool = false
    ) -> QuitReason {
        if isPowerOffQuit(appleEvent) || (powerOffAnnounced && isQuitEvent(appleEvent)) {
            return .powerOff
        }
        if updateRequested {
            return .update
        }
        if let launchBundleVersion, let diskBundleVersion, launchBundleVersion != diskBundleVersion {
            return .update
        }
        return .user
    }

    private nonisolated static func isQuitEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return event.eventClass == AEEventClass(kCoreEventClass) && event.eventID == AEEventID(kAEQuitApplication)
    }

    nonisolated static func isPowerOffQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, isQuitEvent(event),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
                ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        return powerOffQuitReasons.contains(reason.typeCodeValue)
            || powerOffQuitReasons.contains(reason.enumCodeValue)
    }

    /// The `CFBundleVersion` in the app bundle's Info.plist on disk now, not
    /// the one loaded at launch; nil without one (`swift run`).
    nonisolated static func bundleVersionOnDisk(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
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
            Self.quitKeepsSessionsForUpdate = false
            Self.powerOffAnnouncedAt = nil
        }
    }

    /// The quit was answered or confirmed with `intent`, or asked nothing
    /// and ends sessions. One that keeps local sessions and stops no native
    /// program goes at once (`SessionQuitPlan.confirmed`): saved, it returns
    /// `.terminateNow`, as a quit with nothing running does. Otherwise
    /// every window leaves the screen at once and the tabs whose close does
    /// what the app's exit does not are torn down, then the pending
    /// termination goes through once they ended (`tearDownForQuit`), within
    /// `quitReplyDeadline`: `.terminateLater`. App termination skips the
    /// per-window `windowWillClose` teardown, so without it a SIGHUP-ignoring
    /// server like `tilt up` would outlive Cherry, and sessions a quit ends
    /// would run on.
    private func finishQuit(intent: SessionCloseIntent) -> NSApplication.TerminateReply {
        isQuitConfirmed = true
        return MainActor.assumeIsolated {
            let registry = ProjectWindowRegistry.shared
            guard Self.confirmedQuitPlan(intent, registry: registry) == .finish(intent) else {
                registry.prepareForTermination()
                return .terminateNow
            }
            Self.hasRepliedToTermination = false
            let reply: @MainActor @Sendable () -> Void = {
                guard !CherryAppDelegate.hasRepliedToTermination else { return }
                CherryAppDelegate.hasRepliedToTermination = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            Self.tearDownForQuit(intent: intent, registry: registry, reply: reply)
            // While a quit waits (`.terminateLater`), AppKit runs the run
            // loop in its modal panel mode. When the quit was asked for from
            // inside a main-queue block (a main-actor Task or a
            // DispatchQueue.main block calling `NSApp.terminate`), the main
            // queue, and with it the waits' task, cannot run until the
            // reply: only a run loop timer still fires, and lets the quit
            // through.
            let deadline = Timer(timeInterval: Self.quitReplyDeadline, repeats: false) { _ in
                MainActor.assumeIsolated { reply() }
            }
            RunLoop.main.add(deadline, forMode: .common)
            RunLoop.main.add(deadline, forMode: .modalPanel)
            return .terminateLater
        }
    }

    /// What a quit answered or confirmed with `intent` does
    /// (`SessionQuitPlan.confirmed`), with the native programs `registry`'s
    /// windows run now and the sessions `localSessions` is ending, or will
    /// end: once their tabs' closes can no longer be undone (a tab closed
    /// with ⌘W just before: the quit ends it, `tearDownForQuit`), or once
    /// the Create of a tab closed while it was under way answers (the quit
    /// waits for it): `.terminateNow` or `.finish`.
    @MainActor
    static func confirmedQuitPlan(
        _ intent: SessionCloseIntent,
        registry: ProjectWindowRegistry,
        localSessions: PersistentLocalSessions? = .shared,
        remoteHostings: [PersistentHostSessions] = PersistentHostingRegistry.shared.remote
    ) -> SessionQuitPlan {
        // Every host this app runs tabs on: This Mac's and each device's.
        let hostings = (localSessions.map { [$0] } ?? []) + remoteHostings
        let endingSessions = hostings.contains { hosting in
            hosting.hasPendingEnds || hosting.hasDeferredEnds
                || TerminalSession.hasLaunchesEndingTheirSessions(on: hosting)
        }
        return SessionQuitPlan.confirmed(
            intent,
            nativeProgramsStopped: registry.runningProcessCount(endingWith: .appQuit),
            endingSessions: endingSessions
        )
    }

    /// A confirmed quit's teardown (`finishQuit`): every window leaves the
    /// screen first, so the app looks gone at once; then `registry` saves
    /// what changed while the quit's question was up, ends the sessions of
    /// tabs closed (⌘W) while ⌘Z could still bring them back, and tears
    /// down the tabs whose close does what the app's exit does not
    /// (`ProjectWindowRegistry.tearDownForQuit`). Then it waits: for tabs
    /// whose session was still being created (or whose restart waited for
    /// the previous program) and that end what their Create makes, then for
    /// every session being ended, 8 s in all; and, only when native tabs'
    /// busy programs were stopped, for their HUP → TERM → KILL escalation
    /// (`ShellProcessController.terminationEscalationDuration`), which the
    /// exit would cut short. Then `reply`.
    @MainActor
    static func tearDownForQuit(
        intent: SessionCloseIntent,
        registry: ProjectWindowRegistry,
        steps: QuitTeardownSteps = .app,
        reply: @escaping @MainActor () -> Void
    ) {
        steps.takeWindowsOffScreen()
        let stoppedNativePrograms = registry.tearDownForQuit(intent: intent)
        let tornDown = ContinuousClock.now
        Task { @MainActor in
            await steps.waitForLaunches(.seconds(6))
            let endsBudget = max(.seconds(8) - (ContinuousClock.now - tornDown), .seconds(2))
            await steps.waitForEnds(endsBudget)
            if stoppedNativePrograms {
                let remaining = ShellProcessController.terminationEscalationDuration - (ContinuousClock.now - tornDown)
                if remaining > .zero {
                    await steps.sleep(remaining)
                }
            }
            reply()
        }
    }

    /// The quit goes through. For a log out, restart or shut down the
    /// saved state (flushed when the quit began) records it
    /// (`WorkspaceStateStore.noteSystemQuit`): the system then ends the
    /// sessions, and the next launch brings their tabs back ended. Then
    /// whatever the store still has queued (the sessions ended on purpose)
    /// is written before the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        let isPowerOffEvent = lastQuitWasPowerOffEvent
        MainActor.assumeIsolated {
            Self.recordSystemQuit(
                isPowerOffEvent: isPowerOffEvent,
                onQuit: TerminalSettings.shared.localSessionsOnQuit,
                store: .shared,
                sessionsEndedByAQuit: { ProjectWindowRegistry.shared.localSessionsEndedByAQuit() }
            )
        }
    }

    /// What `applicationWillTerminate` records. Only a quit Apple event
    /// that names a log out, restart or shut down counts (`isPowerOffEvent`),
    /// not a quit that merely came soon after the system announced one.
    /// While *on quit* is End Sessions, the sessions ⌘Q would have ended
    /// are recorded as ended on purpose first, so their tabs do not come
    /// back ended, as after ⌘Q. Then the store's queue is flushed.
    @MainActor
    static func recordSystemQuit(
        isPowerOffEvent: Bool,
        onQuit: LocalSessionsOnQuit,
        store: WorkspaceStateStore,
        sessionsEndedByAQuit: () -> [(hostID: String, sessionID: String)]
    ) {
        if isPowerOffEvent {
            if onQuit == .end {
                store.addEndedSessions(sessionsEndedByAQuit())
            }
            store.noteSystemQuit()
        }
        store.flush()
    }

    /// Answers a quit that waited for a sheet (`.terminateLater`): at once
    /// when it goes now or was cancelled. A quit that tears down answers
    /// once its waits are over (`finishQuit`).
    @MainActor
    private static func replyToTermination(_ reply: NSApplication.TerminateReply) {
        switch reply {
        case .terminateNow: NSApp.reply(toApplicationShouldTerminate: true)
        case .terminateCancel: NSApp.reply(toApplicationShouldTerminate: false)
        case .terminateLater: break
        @unknown default: break
        }
    }

    /// Takes `windows` off screen at once for a quit that tears down
    /// (`tearDownForQuit`), so the app looks gone while it does: project
    /// windows, Settings, sheets and panels, the key window last (a window
    /// becoming key activates its project). Ordered out, never closed:
    /// closing a project window would tear its tabs down with a window
    /// close's intent. Not the menu bar icon's window; the icon, as the
    /// Dock's, goes when the app exits.
    @MainActor
    static func takeWindowsOffScreen(_ windows: [NSWindow]) {
        let visible = windows.filter { $0.isVisible && !($0.className.contains("StatusBar")) }
        for window in visible.filter({ !$0.isKeyWindow }) + visible.filter(\.isKeyWindow) {
            window.animationBehavior = .none
            window.orderOut(nil)
        }
        // Hands the ordering to the window server now, before the teardown
        // holds the main thread.
        CATransaction.flush()
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

            // Windows that had tabs come back from the app's own list: AppKit
            // restores no project window. One a deep link opened meanwhile
            // is skipped, and opening a scene value that has a window only
            // focuses it.
            let plan = ProjectWindowRegistry.shared.launchWindowPlan(
                hasVisibleWindow: NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey })
            )
            var reopened: [String] = []
            switch plan {
            case .reopen(let projectRoots):
                if let openProjectWindow {
                    projectRoots.forEach(openProjectWindow)
                    reopened = projectRoots
                } else {
                    openDefaultProjectWindow?()
                }
            case .openDefault:
                openDefaultProjectWindow?()
            case .nothing:
                break
            }
            // Once those windows restored their tabs: sessions of closed
            // windows or tabs that still run.
            ProjectWindowRegistry.shared.backgroundSessionsNotice?.launchWindowsOpened(expecting: reopened)
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
        let backgroundSessionID = userInfo[BackgroundSessionNotificationContent.sessionIDKey] as? String

        await MainActor.run {
            if let backgroundSessionID {
                TerminalNotificationCenter.shared.handleResponse(
                    userInfo: [BackgroundSessionNotificationContent.sessionIDKey: backgroundSessionID],
                    backgroundSessions: .shared
                )
                return
            }
            TerminalNotificationCenter.shared.handleResponse(
                sessionIDString: sessionIDString,
                projectRoot: projectRoot
            )
        }
    }
}

/// A quit dialog's one answer: the sheet's, or `cancelled` when the window
/// it is on closes first (the quit is then cancelled, so AppKit is never
/// left waiting for a reply to `.terminateLater`). Later answers are
/// ignored.
@MainActor
final class QuitConfirmationAnswer<Answer: Sendable> {
    private var answer: (@MainActor (Answer) -> Void)?
    private var parentClose: NSObjectProtocol?

    init(parent: NSWindow, cancelled: Answer, answer: @escaping @MainActor (Answer) -> Void) {
        self.answer = answer
        // Held by the notification center until resolved.
        parentClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.resolve(cancelled) }
        }
    }

    var isResolved: Bool { answer == nil }

    /// Answers the quit once; later calls do nothing.
    func resolve(_ answered: Answer) {
        guard let answer else { return }
        self.answer = nil
        if let parentClose {
            NotificationCenter.default.removeObserver(parentClose)
            self.parentClose = nil
        }
        answer(answered)
    }
}

extension QuitConfirmationAnswer where Answer == Bool {
    /// "Quit Cherry?": true quits; the window closing first answers false.
    convenience init(parent: NSWindow, answer: @escaping @MainActor (Bool) -> Void) {
        self.init(parent: parent, cancelled: false, answer: answer)
    }
}

/// How a confirmed quit that tears down leaves the screen and waits
/// (`CherryAppDelegate.tearDownForQuit`). Tests replace them.
@MainActor
struct QuitTeardownSteps {
    /// Takes every window off screen (`CherryAppDelegate.takeWindowsOffScreen`).
    var takeWindowsOffScreen: @MainActor () -> Void
    /// Waits, at most this long, for launches of persistent tabs that end
    /// what their Create makes (`TerminalSession.waitForPersistentLaunches`).
    var waitForLaunches: @MainActor (Duration) async -> Void
    /// Waits, at most this long, for the sessions being ended
    /// (`PersistentLocalSessions.waitForPendingEnds`), once any whose end
    /// still waited for an undo no window ended were ended too.
    var waitForEnds: @MainActor (Duration) async -> Void
    /// Waits out native tabs' HUP → TERM → KILL escalation.
    var sleep: @MainActor (Duration) async -> Void

    static var app: QuitTeardownSteps {
        QuitTeardownSteps(
            takeWindowsOffScreen: { CherryAppDelegate.takeWindowsOffScreen(NSApp.windows) },
            waitForLaunches: { await TerminalSession.waitForPersistentLaunches(upTo: $0) },
            waitForEnds: { timeout in
                // This Mac's and every device's.
                PersistentHostingRegistry.shared.endAllDeferred()
                _ = await PersistentHostingRegistry.shared.waitForPendingEnds(timeout: timeout)
            },
            sleep: { try? await Task.sleep(for: $0) }
        )
    }
}

@main
struct CherryApp: App {
    private static let projectWindowSceneID = "project"

    @NSApplicationDelegateAdaptor(CherryAppDelegate.self) private var appDelegate
    @StateObject private var terminalSettings = TerminalSettings.shared
    @StateObject private var agentSettings = AgentSettings.shared
    @StateObject private var menuBarAgents = MenuBarAgentsModel()
    /// Only the count: the list itself would re-evaluate the app's body.
    @StateObject private var backgroundSessions = BackgroundSessionsModel.shared.summary
    @State private var controlServer: CherryControlServer?
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.terminalWorkspace) private var focusedWorkspace
    @FocusedValue(\.projectWindowChromeState) private var focusedChromeState

    init() {
        RemoteViewCrashGuard.installIfNeeded()
        // Saved windows of a device's projects reopen while it is known.
        ProjectWindowRegistry.shared.remoteProjectIsKnown = { key in
            RemoteDeviceStore.shared.device(forProjectKey: key) != nil
        }
        ProjectWindowRegistry.shared.configureWorkspacePersistence(store: .shared)
        ProjectWindowRegistry.shared.configureWindowFrames(ProjectWindowFrameStore())
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

    private var detachTabTitle: String {
        focusedWorkspaceHasActiveSplit ? "Detach Pane" : "Detach Tab"
    }

    /// Detach Tab is for a tab whose session can keep running without it
    /// (`SessionCloseCoordinator.canDetach`): never a native tab's.
    private var canDetachFocusedTab: Bool {
        guard focusedChromeState?.isShowingTerminalContent != false,
              let session = focusedWorkspace?.selectedSession
        else {
            return false
        }
        return SessionCloseCoordinator.canDetach(session)
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
                    // Devices' forwards reach its listeners (phase 4b).
                    RemoteMCPForwards.appServer = server
                    RemoteDeviceStore.shared.ensureMCPForwardsOfConnectedDevices()
                }
        }
        .defaultSize(width: 1_340, height: 840)
        .defaultLaunchBehavior(.suppressed)
        // Cherry reopens its windows, their tabs and their frames itself
        // (`ProjectWindowRegistry.launchWindowPlan`, `WorkspaceStateStore`,
        // `ProjectWindowFrameStore`). AppKit's window restoration would add
        // nothing but main-thread stalls while typing: it re-encodes and
        // snapshots restorable windows as their state changes. What only it
        // brought back after a restart: a window's full screen state and
        // Space, and windows without tabs.
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("End Background Sessions…") {
                    BackgroundSessionsModel.shared.confirmEndAll()
                }
                .disabled(backgroundSessions.count == 0)
            }
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
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!canSplitFocusedTerminal)

                Button(detachTabTitle) {
                    guard let workspace = keyWindowWorkspace else { return }
                    SessionCloseCoordinator.detachSelectedTabOrWindow(
                        workspace: workspace,
                        repository: keyWindowRepository,
                        chromeState: keyWindowChromeState,
                        window: NSApp.keyWindow
                    )
                }
                .keyboardShortcut("d")
                .disabled(!canDetachFocusedTab)

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
            MenuBarAgentsPanel(model: menuBarAgents, background: .shared)
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
        let openDefaultProjectWindow: @MainActor @Sendable () -> Void = {
            if let projectRoot = agentSettings.projectRoot(for: nil) {
                agentSettings.markProjectOpened(projectRoot)
                guard !ProjectWindowRegistry.shared.focus(projectRoot: projectRoot) else { return }
                openWindow(id: Self.projectWindowSceneID, value: projectRoot)
            } else {
                openWindow(id: Self.projectWindowSceneID)
            }
        }
        appDelegate.openDefaultProjectWindow = openDefaultProjectWindow
        // Background Sessions → Open, for a project whose window is closed.
        ProjectWindowRegistry.shared.projectWindowOpener = { projectRoot in
            guard let projectRoot else {
                openDefaultProjectWindow()
                return
            }
            agentSettings.markProjectOpened(projectRoot)
            guard !ProjectWindowRegistry.shared.focus(projectRoot: projectRoot) else { return }
            openWindow(id: Self.projectWindowSceneID, value: projectRoot)
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
    /// Saved per project (`ProjectSidebarWidthStore`), not as scene storage,
    /// which needs AppKit's window restoration.
    @State private var storedSidebarWidth: Double
    private let sidebarWidthProjectRoot: String

    init(projectRoot: String) {
        sidebarWidthProjectRoot = projectRoot
        _storedSidebarWidth = State(initialValue: ProjectSidebarWidthStore().width(projectRoot: projectRoot))
        // A project on another Mac runs its tabs on that Mac's host
        // (docs/specs/remote-devices.md); a device Cherry no longer knows
        // gets a hosting whose tabs fail, saying so, never local ones.
        let device = ProjectLocation.isRemoteKey(projectRoot)
            ? RemoteDeviceStore.shared.device(forProjectKey: projectRoot) : nil
        let hosting: PersistentHostSessions = if ProjectLocation.isRemoteKey(projectRoot) {
            device.flatMap { RemoteDeviceStore.shared.hosting(for: $0.id) }
                ?? RemoteDeviceStore.unavailableHosting(
                    for: projectRoot,
                    reason: "This Mac is not among your devices any more (or this copy of Cherry cannot run its tabs). Add it again from the project menu."
                )
        } else {
            .shared
        }
        _repository = StateObject(wrappedValue: RepositoryWorkspace(
            projectRoot: projectRoot,
            backendPolicy: hosting.profile.isThisMac ? .userSettings : .remote(hosting),
            stateStore: .shared,
            // An unknown device's saved tabs stay saved as they are.
            sessionRestorer: hosting.profile.isKnownDevice
                ? WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting)
                : RemoteDeviceStore.keepingRestorer,
            // A device's git worktrees and cherry.toml, read there (phase 3).
            remoteProject: hosting.profile.isKnownDevice ? device.map { RemoteProjectAccess.app($0) } : nil
        ))
        _noteStore = StateObject(wrappedValue: ProjectNoteStore(
            projectRoot: projectRoot,
            loadsInBackground: true
        ))
        _todoStore = StateObject(wrappedValue: ProjectTodoStore(projectRoot: projectRoot))
    }

    /// Folder name of the project, or "Cherry" for a project-less window;
    /// "<project> — <Mac>" for a project on another Mac.
    private var projectName: String {
        let name = repository.repositoryName.isEmpty ? "Cherry" : repository.repositoryName
        guard let device = RemoteDeviceStore.shared.device(forProjectKey: repository.repositoryRoot) else { return name }
        return "\(name) — \(device.name)"
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
        .overlay(alignment: .bottom) {
            // A device window whose saved tabs wait for the device.
            RemoteWindowWaitingBar(repository: repository)
                .padding(.bottom, 14)
        }
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
        .onChange(of: storedSidebarWidth) { _, width in
            ProjectSidebarWidthStore().setWidth(width, projectRoot: sidebarWidthProjectRoot)
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
