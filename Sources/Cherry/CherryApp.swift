import AppKit
import CherryControl
import SwiftUI
import UserNotifications

final class CherryAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var openDefaultProjectWindow: (@MainActor @Sendable () -> Void)?
    /// Opens a saved project window (the launch's), unless it is open.
    var openProjectWindow: (@MainActor @Sendable (ProjectWindowValue) -> Void)?
    private var isQuitConfirmed = false
    /// Whether the latest quit to ask to terminate came with a quit Apple
    /// event naming a log out, restart or shut down (`kAEQuitReason`), not
    /// only one within `powerOffAnnouncementLifetime` of the system
    /// announcing one (which a cancelled log out leaves behind).
    private var lastQuitWasPowerOffEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTimeline.mark("will finish launching")
        MainActor.assumeIsolated {
            // Keys typed once the app is active, before its first window
            // shows with a terminal to take them, are held for that window.
            HiddenWindowKeyHold.shared.holdWindowlessKeys(atMost: .seconds(3))
            // Before any window restores or closes tabs: the sessions this
            // app ends on purpose, and those the host reports lost, are
            // recorded in the store (`SystemEndedSessions`).
            PersistentLocalSessions.shared.endedSessionsStore = .shared
            // Each device's hosting records the same (docs/specs/remote-devices.md).
            RemoteDeviceStore.shared.endedSessionsStore = .shared
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTimeline.mark("did finish launching")
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
        // In the background, early: nothing waits for it (the first
        // restored tab's attach would start it otherwise).
        HostedAttachmentStatusFile.removeAbandonedLaunchDirectoriesInBackground()
        MainActor.assumeIsolated {
            Self.finishLaunchingAfterInstanceLock(lock: .shared, store: .shared) {
                LaunchTimeline.mark("instance lock resolved")
                // The windows to reopen, read before any window registers.
                ProjectWindowRegistry.shared.configureWorkspacePersistence(store: .shared)
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
                LaunchTimeline.mark("warm-up and background sessions started")
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

    // The menu bar item's status-item window is always in `NSApp.windows`
    // (once it is made), so naive first/visible checks see "a window" on a
    // windowless launch and never open the default project window.
    // Key-capable filters it out (its panel is key-capable only while shown).
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
        // An update staged before this app was replaced on disk by hand
        // (Scripts/install-local-app, a DMG drag) would overwrite that build
        // once Cherry quits: it is discarded first.
        MainActor.assumeIsolated {
            AppUpdater.shared.discardIfBundleReplacedByHand(
                launchVersion: Self.launchBundleVersion,
                diskVersion: Self.bundleVersionOnDisk()
            )
        }
        MainActor.assumeIsolated {
            ProjectWindowRegistry.shared.markCurrentActiveProjectOpened()
        }

        guard !isQuitConfirmed else { return .terminateNow }
        MainActor.assumeIsolated { Self.quitIsPending = true }

        let reason = MainActor.assumeIsolated { Self.currentQuitReason() }
        lastQuitWasPowerOffEvent = Self.isPowerOffQuit(NSAppleEventManager.shared().currentAppleEvent)
        if let window = MainActor.assumeIsolated({ Self.windowToAnswerBeforeQuitting(reason: reason, among: NSApp.windows) }) {
            // A window's close question is up, or a tab close's: its answer
            // keeps, detaches or ends sessions, so the quit's own question
            // (which would queue behind it and list them still) waits for
            // it. Quit again once it is answered.
            MainActor.assumeIsolated {
                Self.quitIsPending = false
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
        // persistent tabs, which the system is about to end. Restart to
        // Update confirmed native tabs' busy programs before Sparkle's
        // install block ran (`UpdateQuitRequest.confirmStopping`), so its
        // quit does not ask again.
        let (summary, decision) = MainActor.assumeIsolated { Self.quitTeardown(reason: reason) }
        let stoppingConfirmed = MainActor.assumeIsolated { UpdateQuitRequest.shared.stoppingConfirmed(now: Date()) }
        switch SessionQuitPlan(decision, summary: summary).forUpdate(reason: reason, stoppingConfirmed: stoppingConfirmed) {
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
            return confirmStoppingProcesses(count, intent: intent, reason: reason)
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

    /// "Quit Cherry?" for `count` busy programs quitting stops, or "Restart
    /// Cherry to update?" for an update's quit that Sparkle relaunches
    /// (`QuitConfirmationText`): Sparkle's own Install and Relaunch (Check
    /// for Updates…) gets it, and cancelling it leaves the relaunch armed,
    /// so a later quit is an update too. A bundle replaced by hand is an
    /// update quit as well, but nothing relaunches it: "Quit Cherry?".
    @MainActor
    private func confirmStoppingProcesses(
        _ count: Int,
        intent: SessionCloseIntent,
        reason: QuitReason
    ) -> NSApplication.TerminateReply {
        let alert = QuitConfirmationText.forQuit(
            count: count,
            reason: reason,
            relaunchArmed: UpdateQuitRequest.shared.isUpdateQuit
        ).makeAlert()

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
    @MainActor private static var powerOffObserver: NSObjectProtocol?
    /// A quit got past its first checks and is not cancelled (it asks, or
    /// tears down): Restart to Update waits (`mayRestartToUpdateNow`).
    @MainActor static var quitIsPending = false

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

    @MainActor
    private static func currentQuitReason() -> QuitReason {
        quitReason(
            appleEvent: NSAppleEventManager.shared().currentAppleEvent,
            launchBundleVersion: launchBundleVersion,
            diskBundleVersion: bundleVersionOnDisk(),
            powerOffAnnounced: powerOffAnnouncedAt.map { Date().timeIntervalSince($0) < powerOffAnnouncementLifetime } ?? false,
            updateRequested: UpdateQuitRequest.shared.isUpdateQuit
        )
    }

    /// Why this quit happens, in this order. `appleEvent`: the quit Apple
    /// event being handled, whose `kAEQuitReason` names a log out, restart
    /// or shut down (none for ⌘Q, which sends no event). `updateRequested`:
    /// Sparkle armed its relaunch (`UpdateQuitRequest`), and its installer's
    /// quit event, or any quit after it, installs and relaunches. With
    /// `powerOffAnnounced` (the system announced a log out, restart or shut
    /// down) any other quit event counts as one. A quit is an update too
    /// when the app on disk has another `CFBundleVersion` than at launch
    /// (Scripts/install-local-app and Scripts/package-dmg stamp each build,
    /// and an install replaces the app while it runs).
    nonisolated static func quitReason(
        appleEvent: NSAppleEventDescriptor?,
        launchBundleVersion: String?,
        diskBundleVersion: String?,
        powerOffAnnounced: Bool = false,
        updateRequested: Bool = false
    ) -> QuitReason {
        // The event names a log out, restart or shut down.
        if isPowerOffQuit(appleEvent) {
            return .powerOff
        }
        // Sparkle armed a relaunch.
        if updateRequested {
            return .update
        }
        // Announced in the last `powerOffAnnouncementLifetime`.
        if powerOffAnnounced && isQuitEvent(appleEvent) {
            return .powerOff
        }
        if let launchBundleVersion, let diskBundleVersion, launchBundleVersion != diskBundleVersion {
            return .update
        }
        return .user
    }

    /// The app on disk has another `CFBundleVersion` than at launch: it was
    /// replaced by another build while it ran.
    @MainActor
    static func appBundleReplacedSinceLaunch() -> Bool {
        guard let launchBundleVersion, let diskBundleVersion = bundleVersionOnDisk() else { return false }
        return launchBundleVersion != diskBundleVersion
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
            // A relaunch Sparkle armed stays armed: its installer relaunches
            // after any later quit.
            UpdateQuitRequest.shared.quitWasCancelled()
            Self.quitIsPending = false
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
    /// is written before the process ends, and so are the MCP tasks'
    /// latest changes (`AgentTaskRegistry.saveNow`).
    func applicationWillTerminate(_ notification: Notification) {
        let isPowerOffEvent = lastQuitWasPowerOffEvent
        MainActor.assumeIsolated {
            // MCP tasks' latest changes (saves wait a second for more).
            AgentTaskRegistry.app?.saveNow()
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

    /// How long the launch waits before it decides whether to open the
    /// default project's window: a window a deep link opens (its URL
    /// arrives just after launch) is then there, and none is opened.
    static let defaultWindowDecisionDelay: Duration = .milliseconds(250)

    @MainActor
    private func scheduleDefaultWindowOpenIfNeeded() {
        let openDefaultProjectWindow = openDefaultProjectWindow
        let openProjectWindow = openProjectWindow

        let open: @MainActor (LaunchWindowPlan) -> Void = { plan in
            LaunchTimeline.mark({
                switch plan {
                case .reopen(let windows): "window plan: reopen \(windows.count)"
                case .openDefault: "window plan: default window"
                case .nothing: "window plan: nothing"
                }
            }())
            var reopened: [ProjectWindowValue] = []
            switch plan {
            case .reopen(let windows):
                if let openProjectWindow {
                    // Off screen from the moment AppKit orders them in until
                    // their saved tabs are back (`ProjectWindowReveal`); the
                    // most recently active first, the others once it shows.
                    let registry = ProjectWindowRegistry.shared
                    let recency = registry.projectRecency
                    // A quit before the later windows open ends (or keeps)
                    // their sessions as theirs would.
                    registry.launchWindowHosting = SessionBackendPolicy.userSettings.localSessions
                    // Tabs no window shows attach once the windows are up.
                    RestoredTabLaunchQueue.shared.holdBackgroundTabs(atMost: 3)
                    registry.openLaunchWindows(
                        LaunchWindowOrder.frontFirst(windows) { recency?.lastOpened($0.projectRoot) },
                        beforeLaterWindows: { proceed in
                            // Building the others holds the main thread,
                            // which the connection to This Mac's host needs
                            // for each of its steps: it comes up first
                            // (briefly), and the first window's tabs are
                            // confirmed sooner.
                            PersistentLocalSessions.shared.control.whenConnected(
                                waitingAtMost: .milliseconds(200), proceed
                            )
                        }
                    ) { window in
                        openProjectWindow(window)
                    }
                    registry.whenLaunchWindowsOpened {
                        RestoredTabLaunchQueue.shared.releaseBackgroundTabs()
                    }
                    reopened = windows
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
            Self.installMenuBarItemOnceLaunchWindowsOpened(registry: .shared) {
                MenuBarStatusItem.shared.installSoon()
            }
            Self.startUpdaterOnceLaunchWindowsOpened(registry: .shared)
            // Saved tabs of windows no list names any more (a crash during
            // a close, an older build), in the background.
            ProjectWindowRegistry.shared.removeAbandonedWindowStatesOnceLaunchWindowsOpened()
        }

        // Windows that had tabs come back from the app's own list (AppKit
        // restores no project window), at once: opening a scene value that
        // has a window (one a deep link opened) only focuses it.
        if let plan = ProjectWindowRegistry.shared.savedWindowsLaunchPlan() {
            open(plan)
            return
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: Self.defaultWindowDecisionDelay)
            } catch {
                return
            }
            // The default project's window, unless a deep link opened one
            // meanwhile.
            open(ProjectWindowRegistry.shared.launchWindowPlan(
                hasVisibleWindow: NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey })
            ))
        }
    }

    /// The menu bar item (`MenuBarStatusItem`) comes once the launch's
    /// windows are open: making it earlier would hold up the first one.
    @MainActor
    static func installMenuBarItemOnceLaunchWindowsOpened(
        registry: ProjectWindowRegistry,
        install: @escaping @MainActor () -> Void
    ) {
        registry.whenLaunchWindowsOpened(install)
    }

    /// Sparkle (`AppUpdater.startIfEnabled`) starts once the launch's
    /// windows are open, on a later turn.
    @MainActor
    static func startUpdaterOnceLaunchWindowsOpened(registry: ProjectWindowRegistry) {
        registry.whenLaunchWindowsOpened {
            // A later turn: the waiters can run from inside a window's registration
            // (finishOpeningLaunchWindows), and starting publishes AppUpdateStatus.
            DispatchQueue.main.async { MainActor.assumeIsolated { AppUpdater.shared.startIfEnabled() } }
        }
    }

    // MARK: Restart to Update

    /// The busy native (fallback) programs an update's quit stops: it keeps
    /// sessions and asks nothing about them, as `applicationShouldTerminate`
    /// decides for `.update`.
    @MainActor
    static func updateRestartStoppedProgramCount() -> Int {
        if case .confirmStopping(let count, _) = quitTeardown(reason: .update).decision { return count }
        return 0
    }

    /// What a quit for `reason` would do across every window, and what it
    /// asks or confirms first: only a user's quit may ask about sessions,
    /// and a log out, restart or shut down counts what ending them stops.
    @MainActor
    static func quitTeardown(reason: QuitReason) -> (summary: SessionTeardownSummary, decision: SessionTeardownConfirmation) {
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

    /// "Restart Cherry to update?" for `count` busy programs, as a sheet on
    /// the project window the quit confirmation would use (closing that
    /// window answers false), else app-modal.
    @MainActor
    static func confirmRestartToUpdate(count: Int, answer: @escaping @MainActor (Bool) -> Void) {
        let alert = QuitConfirmationText(count: count, reason: .update).makeAlert()
        guard let window = visibleProjectWindowForQuitConfirmation() else {
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        let confirmation = QuitConfirmationAnswer(parent: window, answer: answer)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { confirmation.resolve(response == .alertFirstButtonReturn) }
        }
    }

    /// Whether Restart to Update may go on now: not while a quit is
    /// pending; while a window's close question is up, that window comes
    /// forward instead.
    @MainActor
    static func mayRestartToUpdateNow() -> Bool {
        guard !quitIsPending else { return false }
        if let window = ProjectWindowCloseDelegate.windowAskingToClose(among: NSApp.windows) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
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
        // Cherry's notifications carry strings only: a tab's id and project,
        // or a background session's id and host.
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) { strings, entry in
            if let key = entry.key as? String, let value = entry.value as? String { strings[key] = value }
        }

        await MainActor.run {
            TerminalNotificationCenter.shared.handleResponse(userInfo: userInfo, backgroundSessions: .shared)
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
    /// Only the count: the list itself would re-evaluate the app's body.
    @StateObject private var backgroundSessions = BackgroundSessionsModel.shared.summary
    @State private var controlServer: CherryControlServer?
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.terminalWorkspace) private var focusedWorkspace
    @FocusedValue(\.projectWindowChromeState) private var focusedChromeState

    init() {
        // Before anything reads the defaults: a release build's first launch
        // takes the settings of the local builds before it, once.
        LegacyDefaultsImport.runIfNeeded()
        // Decides only whether this copy may update itself; Sparkle starts
        // once the launch's windows opened (`startUpdaterOnceLaunchWindowsOpened`).
        _ = AppUpdater.shared
        LaunchTimeline.isEnabled = true
        LaunchTimeline.mark("app init")
        LaunchInteractivity.start()
        // Launched from a Cherry tab (`open`, a script): its identity must
        // not reach this app's tabs, whose adapters would refuse to attach
        // that tab's session as "from inside itself".
        CherryTabEnvironment.removeFromProcess()
        RemoteViewCrashGuard.installIfNeeded()
        // Helpers and adapters start with the last run's login environment
        // while this run's is captured (`LoginEnvironmentCache`).
        HostedSessionLoginEnvironment.shared.lastRunCache = .shared
        // Saved windows of a device's projects reopen while it is known.
        ProjectWindowRegistry.shared.remoteProjectIsKnown = { key in
            RemoteDeviceStore.shared.device(forProjectKey: key) != nil
        }
        // The saved state (`configureWorkspacePersistence`) is read once the
        // instance lock is resolved, off this thread (`applicationDidFinishLaunching`):
        // reading it here would take the lock on the main thread, blocking
        // the launch while a previous copy quits.
        ProjectWindowRegistry.shared.configureWindowFrames(ProjectWindowFrameStore())
        // The Omni bar's Projects › Recent and project frecency.
        ProjectWindowRegistry.shared.projectRecency = .shared
        // Keys typed into a window still off screen come once it shows.
        ProjectWindowRegistry.shared.hiddenWindowKeyHold = .shared
        ProjectWindowRegistry.shared.launchWindowCover = LaunchWindowCover(keyHold: .shared) { window in
            // A window of the project scene (SwiftUI names them after it).
            !(window is NSPanel) && (window.identifier?.rawValue.hasPrefix(Self.projectWindowSceneID) ?? false)
        }
        LaunchTimeline.mark("app init done")
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

        // A window's value names its project and, for every window but the
        // project's primary one, its id (`ProjectWindowValue`): an open
        // value only brings its window forward.
        WindowGroup("Cherry", id: Self.projectWindowSceneID, for: ProjectWindowValue.self) { value in
            ProjectWindowView(value: value.wrappedValue)
                .preferredColorScheme(terminalSettings.appearance.preferredColorScheme)
                .onAppear {
                    guard controlServer == nil else { return }
                    let server = CherryControlServer(workspaceProvider: {
                        ProjectWindowRegistry.shared.activeWorkspace
                    }, todoStoreProvider: {
                        ProjectWindowRegistry.shared.activeTodoStore
                    }, chromeStateProvider: {
                        ProjectWindowRegistry.shared.activeChromeState
                    }, openProjectProvider: { projectRoot in
                        showProject(projectRoot)
                    })
                    // MCP tasks survive a relaunch: the last run's are read
                    // back (off this thread) before any request is handled.
                    server.configureTaskPersistence(store: .shared, hostings: .shared, stateStore: .shared)
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
            // Observes the updater's status itself: this body never does.
            CommandGroup(after: .appInfo) {
                UpdateMenuItems(status: AppUpdater.shared.status)
            }
            CommandGroup(after: .appSettings) {
                Button("End Background Sessions…") {
                    BackgroundSessionsModel.shared.confirmEndAll()
                }
                .disabled(backgroundSessions.count == 0)
            }
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    keyWindowChromeState?.showOmniBarProjects()
                }
                .keyboardShortcut("o")
                .disabled(focusedChromeState == nil)
                Button("Persistent Sessions…") {
                    keyWindowChromeState?.isHostedSessionsPresented = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedWorkspace == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Omni Bar") {
                    keyWindowChromeState?.toggleOmniBar()
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

                Button(focusedChromeState?.isSidebarPlaygroundPresented == true ? "Hide Sidebar Icon Playground" : "Show Sidebar Icon Playground") {
                    keyWindowChromeState?.toggleSidebarPlayground()
                }
                .disabled(focusedChromeState == nil)

                Button(focusedChromeState?.isCommandPalettePlaygroundPresented == true ? "Hide Omni Bar Playground" : "Show Omni Bar Playground") {
                    keyWindowChromeState?.toggleCommandPalettePlayground()
                }
                .disabled(focusedChromeState == nil)

                Divider()

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

                Button(closeTabTitle) {
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
                            workspace.addAgentSession(agent: agent, projectRoot: projectRoot)
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

    private func configureDefaultWindowOpener() {
        appDelegate.openProjectWindow = { window in
            guard !ProjectWindowRegistry.shared.hasWindow(window) else { return }
            openWindow(id: Self.projectWindowSceneID, value: window)
        }
        let openDefaultProjectWindow: @MainActor @Sendable () -> Void = {
            if let projectRoot = agentSettings.projectRoot(for: nil) {
                showProject(projectRoot)
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
            showProject(projectRoot)
        }
    }

    /// Brings `projectRoot`'s project's most recently active window
    /// forward, or opens its primary window.
    private func showProject(_ projectRoot: String) {
        agentSettings.markProjectOpened(projectRoot)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: projectRoot) else { return }
        openWindow(id: Self.projectWindowSceneID, value: ProjectWindowValue.primary(projectRoot))
    }
}

private struct ProjectWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var agentSettings = AgentSettings.shared
    @State private var lockedProjectRoot: String?

    /// The window the scene was opened for; nil for a window SwiftUI
    /// opened by itself, a URL event's or onboarding's.
    let requested: ProjectWindowValue?

    init(value: ProjectWindowValue?) {
        requested = value
    }

    var body: some View {
        Group {
            if let projectRoot {
                ProjectWorkspaceView(projectRoot: projectRoot, windowID: windowID, implicit: isImplicit)
                    .id(ProjectWindowValue(projectRoot: projectRoot, windowID: windowID))
            } else {
                ProjectOnboardingView { project in
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
        lockedProjectRoot ?? agentSettings.projectRoot(for: requested?.projectRoot)
    }

    /// The window the value names, when its project is the one this shows.
    private var windowID: UUID? {
        requested.flatMap { $0.projectRoot == projectRoot ? $0.windowID : nil }
    }

    /// Opened with no value, or its value's project could not be opened:
    /// it claims its project's primary window only while none of the
    /// project's windows is open.
    private var isImplicit: Bool {
        requested.map { $0.projectRoot != projectRoot } ?? true
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
        // A terminal link's tab is in the window that has it; a to-do's in
        // the project's most recently active window.
        let registry = ProjectWindowRegistry.shared
        if registry.hasWindow(for: projectRoot) {
            if !registry.select(deepLink, projectRoot: projectRoot) {
                _ = registry.focus(projectRoot: projectRoot)
                CherryDeepLinkOpenQueue.shared.enqueue(deepLink, projectRoot: projectRoot)
            }
        } else {
            CherryDeepLinkOpenQueue.shared.enqueue(deepLink, projectRoot: projectRoot)
            openWindow(value: ProjectWindowValue.primary(projectRoot))
        }
    }
}

/// Observes the currently selected session and keeps the AppKit window title in
/// sync as "<project> — <selected tab>" (`ProjectWindowTitle`). @ObservedObject so a live title change
/// (e.g. an agent renaming its tab) updates the window title while the tab stays
/// selected; the parent re-passes a new `session` when the selection changes.
private struct WindowTitleBinder: View {
    let projectName: String
    /// The Mac a device window runs on.
    let deviceName: String?
    @ObservedObject var session: TerminalSession

    var body: some View {
        WindowTitleWriter(title: ProjectWindowTitle.title(
            project: projectName, deviceName: deviceName, tab: session.title
        ))
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
    @StateObject private var repository: RepositoryWorkspace
    @StateObject private var chromeState = ProjectWindowChromeState()
    @StateObject private var todoStore: ProjectTodoStore
    /// Saved per project (`ProjectSidebarWidthStore`), not as scene storage,
    /// which needs AppKit's window restoration.
    @State private var storedSidebarWidth: Double
    private let sidebarWidthProjectRoot: String
    /// Which of the project's windows this is (`ProjectWindowValue.windowID`).
    private let windowID: UUID?
    /// Opened with no value of its own (`ProjectWindowRegistry.register`).
    private let isImplicit: Bool

    init(projectRoot: String, windowID: UUID? = nil, implicit: Bool = false) {
        sidebarWidthProjectRoot = projectRoot
        self.windowID = windowID
        isImplicit = implicit
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
            windowID: windowID,
            backendPolicy: hosting.profile.isThisMac ? .userSettings : .remote(hosting, windowGridWait: .standard),
            stateStore: .shared,
            // An unknown device's saved tabs stay saved as they are.
            sessionRestorer: hosting.profile.isKnownDevice
                ? WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting)
                : RemoteDeviceStore.keepingRestorer,
            // A device's cherry.toml, read there (phase 3).
            remoteProject: hosting.profile.isKnownDevice ? device.map { RemoteProjectAccess.app($0) } : nil,
            // This Mac's saved tabs show before its host answers; a device's
            // wait for that Mac.
            showsSavedTabsBeforeHostAnswers: hosting.profile.isThisMac
        ))
        // The project's to-dos, which all its windows share.
        _todoStore = StateObject(wrappedValue: ProjectTodoStore.shared(projectRoot: projectRoot))
    }

    /// Folder name of the project, or "Cherry" for a project-less window.
    private var projectName: String {
        repository.repositoryName.isEmpty ? "Cherry" : repository.repositoryName
    }

    private var workspace: TerminalWorkspace {
        repository.workspace
    }

    var body: some View {
        ContentView(
            repository: repository,
            workspace: workspace,
            chromeState: chromeState,
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
        .overlay(alignment: .bottom) {
            // A window that had to show before its saved tabs were back.
            WindowRestoringBar(repository: repository)
                .padding(.bottom, 14)
        }
        .background(ProjectWindowBinder(
            projectRoot: repository.repositoryRoot,
            windowID: windowID,
            implicit: isImplicit,
            workspace: workspace,
            repository: repository,
            todoStore: todoStore,
            chromeState: chromeState
        ))
        .background {
            // "<project> @ <Mac>" for a device window.
            RemoteDeviceBadgeReader(projectKey: repository.repositoryRoot) { device in
                if let session = workspace.selectedSession {
                    WindowTitleBinder(projectName: projectName, deviceName: device?.name, session: session)
                } else {
                    WindowTitleWriter(title: ProjectWindowTitle.title(project: projectName, deviceName: device?.name))
                }
            }
        }
        // A device window's views read its Mac (header, path prefix, colour)
        // from the device store; This Mac's never ask it.
        .environment(\.remoteDeviceStore, repository.isRemote ? RemoteDeviceStore.shared : nil)
        .focusedValue(\.terminalWorkspace, workspace)
        .focusedValue(\.projectWindowChromeState, chromeState)
        .onAppear {
            ProjectWindowRegistry.shared.activeWorkspace = workspace
            ProjectWindowRegistry.shared.activeTodoStore = todoStore
            ProjectWindowRegistry.shared.activeChromeState = chromeState
            agentSettings.markProjectOpened(workspace.projectRoot)
            // Waits for the window to claim its project and for its saved
            // tabs to be restored, so a restored command tab is not started
            // twice; only the window that opened the project starts them.
            repository.autoStartInitialCommandsIfNeeded()
            openPendingDeepLinks()
            Task {
                await repository.refresh()
            }
        }
        .onChange(of: storedSidebarWidth) { _, width in
            ProjectSidebarWidthStore().setWidth(width, projectRoot: sidebarWidthProjectRoot)
        }
    }

    /// The project's most recently active window, else its primary one.
    private func openProject(_ project: CherryProject) {
        agentSettings.markProjectOpened(project.root)
        guard !ProjectWindowRegistry.shared.focus(projectRoot: project.root) else { return }
        openWindow(value: ProjectWindowValue.primary(project.root))
    }

    private func openPendingDeepLinks() {
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
