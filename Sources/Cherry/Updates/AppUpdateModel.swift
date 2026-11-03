import Foundation
import os

/// Why the next quit is an update relaunch (`CherryAppDelegate.currentQuitReason`).
@MainActor
final class UpdateQuitRequest {
    static let shared = UpdateQuitRequest()

    /// Sparkle told its installer to relaunch (`updaterWillRelaunchApplication`, synchronously
    /// before stage 2, so before any quit event). From then on every quit installs and
    /// relaunches, so a cancelled quit keeps it; only an abort clears it.
    private(set) var relaunchArmed = false
    /// When the user confirmed stopping busy native programs for Restart to Update.
    private var stoppingConfirmedAt: Date?
    /// How long that confirmation lets an update quit go on without asking again.
    static let stoppingConfirmationLifetime: TimeInterval = 60

    var isUpdateQuit: Bool { relaunchArmed }

    init() {}

    func confirmStopping(at now: Date) {
        stoppingConfirmedAt = now
    }

    /// Whether busy native programs were confirmed within the lifetime.
    func stoppingConfirmed(now: Date) -> Bool {
        guard let stoppingConfirmedAt else { return false }
        let age = now.timeIntervalSince(stoppingConfirmedAt)
        return age >= 0 && age <= Self.stoppingConfirmationLifetime
    }

    func noteRelaunchArmed() {
        relaunchArmed = true
    }

    /// A quit was cancelled: the confirmation goes, an armed relaunch stays.
    func quitWasCancelled() {
        stoppingConfirmedAt = nil
    }

    /// Sparkle aborted the update: nothing is armed or confirmed any more.
    func updateAborted() {
        relaunchArmed = false
        stoppingConfirmedAt = nil
    }
}

/// What the updater shows: the app menu, the sidebar pill, the menu bar
/// row and Settings › Updates observe it (each through its own
/// `@ObservedObject`; `CherryApp` never does). Changes come only from
/// Sparkle callbacks, timers and button actions, through `AppUpdateModel`
/// and `AppUpdater`, and publish only what differs.
@MainActor
final class AppUpdateStatus: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Found, but Sparkle needs the user before it downloads it (a
        /// scheduled check with automatic downloads off, a major upgrade).
        case available(version: String, channel: String?)
        /// Downloaded and staged; installs at quit. `throughSparkle`: staged from Sparkle's own
        /// window ("Install on Quit"), so Restart to Update resumes Sparkle's Install and Relaunch.
        case ready(version: String, channel: String?, throughSparkle: Bool)
    }

    @Published private(set) var enablement: AppUpdateEnablement
    @Published private(set) var phase: Phase = .idle
    /// Sparkle armed its relaunch.
    @Published private(set) var isRestarting = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var prereleases = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    /// The app on disk is another build than the one running, as the model
    /// last saw (`CherryAppDelegate.appBundleReplacedSinceLaunch`): this copy
    /// installs nothing more, and Settings says to reopen Cherry.
    @Published private(set) var isReplacedOnDisk = false

    var isEnabled: Bool { enablement == .enabled }

    /// Discard Downloaded Update is offered only for an update Cherry staged.
    /// One staged from Sparkle's own window is skipped there (Restart to
    /// Update shows it): when Sparkle resumed it in a scheduled session,
    /// removing its jobs ends nothing, and that session would wait for good,
    /// with no further checks and its stale alert on Check Now.
    var offersDiscard: Bool {
        if case .ready(_, _, throughSparkle: false) = phase { return true }
        return false
    }

    init(enablement: AppUpdateEnablement, prereleases: Bool = false) {
        self.enablement = enablement
        self.prereleases = prereleases
    }

    func applyEnablement(_ value: AppUpdateEnablement) {
        if enablement != value { enablement = value }
    }

    func applyPhase(_ value: Phase) {
        if phase != value { phase = value }
    }

    func applyRestarting(_ value: Bool) {
        if isRestarting != value { isRestarting = value }
    }

    func applyCanCheckForUpdates(_ value: Bool) {
        if canCheckForUpdates != value { canCheckForUpdates = value }
    }

    func applyAutomaticallyChecks(_ value: Bool) {
        if automaticallyChecks != value { automaticallyChecks = value }
    }

    func applyAutomaticallyDownloads(_ value: Bool) {
        if automaticallyDownloads != value { automaticallyDownloads = value }
    }

    func applyPrereleases(_ value: Bool) {
        if prereleases != value { prereleases = value }
    }

    func applyLastCheck(_ value: Date?) {
        if lastCheck != value { lastCheck = value }
    }

    func applyLastError(_ value: String?) {
        if lastError != value { lastError = value }
    }

    func applyReplacedOnDisk(_ value: Bool) {
        if isReplacedOnDisk != value { isReplacedOnDisk = value }
    }
}

/// What `AppUpdateModel` asks of Sparkle and the app. `AppUpdater` gives
/// the real ones; tests pass fakes.
struct AppUpdateActions {
    var checkForUpdates: @MainActor () -> Void
    var resetUpdateCycle: @MainActor () -> Void
    /// Busy native programs an update quit would stop
    /// (`CherryAppDelegate.updateRestartStoppedProgramCount`).
    var busyNativePrograms: @MainActor () -> Int
    /// "Restart Cherry to update?" for that many programs; answers true to go on.
    var confirmStopping: @MainActor (_ count: Int, _ answer: @escaping @MainActor (Bool) -> Void) -> Void
    /// False while a quit is pending; when a window's close question is up it brings
    /// that window forward and returns false.
    var mayRestartNow: @MainActor () -> Bool
    /// Removes Sparkle's launchd jobs (SparkleInstallerJobs.remove).
    var removeInstallerJobs: @MainActor () -> Void
    var now: @MainActor () -> Date = { Date() }
    /// The app bundle on disk has another CFBundleVersion than at launch
    /// (`CherryAppDelegate.appBundleReplacedSinceLaunch`).
    var bundleReplacedSinceLaunch: @MainActor () -> Bool = { false }
}

/// The updater's state machine, without Sparkle: `AppUpdater`'s bridge
/// reports what Sparkle does, the UI asks it to restart, check or discard.
@MainActor
final class AppUpdateModel {
    static let prereleasesKey = "updates.prereleases"
    /// `SUSparkleErrorDomain` and the codes Cherry reads (Sparkle's SUErrors.h;
    /// `SparkleBridge.constantsMatchSparkle` checks them).
    nonisolated static let sparkleErrorDomain = "SUSparkleErrorDomain"
    /// `SUNoUpdateError`: a check that found nothing newer.
    nonisolated static let noUpdateErrorCode = 1001
    /// `SUDowngradeError`: Autoupdate refused to put an older build over the
    /// one on disk.
    nonisolated static let downgradeErrorCode = 4006
    /// Cherry's own errors (`checkRefusal`).
    nonisolated static let errorDomain = "CherryUpdates"
    nonisolated static let checkRefusedErrorCode = 1

    enum DiscardReason: String, Sendable {
        /// Discard Downloaded Update (Settings › Updates).
        case user
        /// The feed no longer lists the staged build, or lists it as pulled (`StagedUpdateWatch`).
        case pulled
        /// The app on disk was replaced by another build (install-local-app, a DMG drag).
        case bundleReplaced
    }

    let status: AppUpdateStatus
    private let quitRequest: UpdateQuitRequest
    private let defaults: UserDefaults
    private let actions: AppUpdateActions
    /// Sparkle's immediate installation block for the staged update.
    private var install: (@MainActor () -> Void)?
    /// The staged item's sparkle:version (for `StagedUpdateWatch`).
    private(set) var stagedBuild: String?
    /// A discard removed Sparkle's jobs; its abort is expected and says nothing.
    private var isDiscarding = false
    private let logger = Logger(subsystem: SessionLog.subsystem, category: "Updates")

    init(status: AppUpdateStatus, quitRequest: UpdateQuitRequest, defaults: UserDefaults, actions: AppUpdateActions) {
        self.status = status
        self.quitRequest = quitRequest
        self.defaults = defaults
        self.actions = actions
        status.applyPrereleases(defaults.bool(forKey: Self.prereleasesKey))
    }

    // MARK: From Sparkle

    /// A scheduled check downloaded and staged an update (`willInstallUpdateOnQuit`).
    func updateStaged(version: String, build: String, channel: String?, install: @escaping @MainActor () -> Void) {
        self.install = install
        stagedBuild = build
        isDiscarding = false
        status.applyLastError(nil)
        status.applyPhase(.ready(version: version, channel: channel, throughSparkle: false))
    }

    /// Staged from Sparkle's own window ("Install on Quit"): there is no block.
    func updateStagedThroughSparkle(version: String, channel: String?) {
        install = nil
        stagedBuild = nil
        isDiscarding = false
        status.applyLastError(nil)
        status.applyPhase(.ready(version: version, channel: channel, throughSparkle: true))
    }

    /// A scheduled check found an update Cherry shows instead of Sparkle.
    /// A pre-release found while Get pre-release builds is off is not offered.
    func updateNeedsAttention(version: String, channel: String?) {
        if case .ready = status.phase { return }
        if channel == "prerelease", !status.prereleases { return }
        status.applyPhase(.available(version: version, channel: channel))
    }

    /// Sparkle's window took over the update the pill showed.
    func attentionReceived() {
        if case .available = status.phase { status.applyPhase(.idle) }
    }

    /// Sparkle's session ended; a staged update stays staged.
    func sessionFinished() {
        if case .available = status.phase { status.applyPhase(.idle) }
    }

    /// `updaterWillRelaunchApplication`: the next quit installs and relaunches.
    func relaunchArmed() {
        quitRequest.noteRelaunchArmed()
        status.applyRestarting(true)
    }

    /// Sparkle aborted the update session (`didAbortWithError`; "no update"
    /// is no abort). Says why, unless a discard caused it, Autoupdate refused
    /// a downgrade, the app on disk is another build than the one launched
    /// (a newer build installed by hand refuses the older update, and a
    /// removed installer ends with a generic error), or Sparkle gave no
    /// reason (no `NSLocalizedDescriptionKey`).
    func aborted(error: NSError) {
        if Self.isNoUpdate(error) || Self.isCheckRefusal(error) { return }
        let wasDiscarding = isDiscarding
        isDiscarding = false
        quitRequest.updateAborted()
        install = nil
        stagedBuild = nil
        status.applyPhase(.idle)
        status.applyRestarting(false)
        let code = error.code
        let message = error.userInfo[NSLocalizedDescriptionKey] as? String
        let downgrade = Self.isDowngrade(error)
        let replaced = noticeReplacedOnDisk()
        if wasDiscarding || downgrade || replaced || message == nil {
            logger.info("update aborted (\(code, privacy: .public), downgrade: \(downgrade, privacy: .public), replaced: \(replaced, privacy: .public)), not shown: \(message ?? error.localizedDescription, privacy: .public)")
            return
        }
        logger.error("update aborted (\(code, privacy: .public)): \(message ?? "", privacy: .public)")
        status.applyLastError(message)
    }

    /// `SUNoUpdateError`: the check found nothing newer.
    nonisolated static func isNoUpdate(_ error: NSError?) -> Bool {
        guard let error else { return false }
        return error.domain == sparkleErrorDomain && error.code == noUpdateErrorCode
    }

    /// `error`, or an error under it (`NSUnderlyingErrorKey`), is Sparkle's
    /// downgrade refusal. Autoupdate's first stage raises it, and the app is
    /// told only the generic installation error (4005) that wraps it.
    nonisolated static func isDowngrade(_ error: NSError) -> Bool {
        var current: NSError? = error
        var depth = 0
        while let level = current, depth < 8 {
            if level.domain == sparkleErrorDomain, level.code == downgradeErrorCode { return true }
            current = level.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// `mayPerformUpdateCheck`: the error that refuses a check while the app
    /// on disk is another build than the one launched, since nothing found
    /// may install over that build (and Autoupdate would refuse an older one
    /// after each hourly download); nil to let it run.
    func checkRefusal() -> NSError? {
        guard noticeReplacedOnDisk() else { return nil }
        return NSError(domain: Self.errorDomain, code: Self.checkRefusedErrorCode, userInfo: [
            NSLocalizedDescriptionKey: "Another build of Cherry was installed while this one ran. Quit and reopen Cherry to use it.",
        ])
    }

    /// The abort of a check `checkRefusal` refused: nothing ran.
    nonisolated static func isCheckRefusal(_ error: NSError) -> Bool {
        error.domain == errorDomain && error.code == checkRefusedErrorCode
    }

    func canCheckChanged(_ value: Bool) {
        status.applyCanCheckForUpdates(value)
    }

    func automaticallyChecksChanged(_ value: Bool) {
        status.applyAutomaticallyChecks(value)
    }

    func automaticallyDownloadsChanged(_ value: Bool) {
        status.applyAutomaticallyDownloads(value)
    }

    /// An update cycle ended (`didFinishUpdateCycleForUpdateCheck`, after
    /// its abort, if any, which carried the same `error`). One that ended
    /// without an error, or found nothing newer, clears the last failure; a
    /// check refused because another build is on disk is no success.
    func checkFinished(at date: Date?, error: NSError?) {
        isDiscarding = false
        status.applyLastCheck(date)
        if error == nil || Self.isNoUpdate(error), !status.isReplacedOnDisk {
            status.applyLastError(nil)
        }
    }

    /// The last check Sparkle remembers, when it starts.
    func lastCheckLoaded(_ date: Date?) {
        status.applyLastCheck(date)
    }

    /// Whether the app on disk is another build than the one launched; once
    /// seen, Settings says so for the rest of the run.
    private func noticeReplacedOnDisk() -> Bool {
        if status.isReplacedOnDisk { return true }
        guard actions.bundleReplacedSinceLaunch() else { return false }
        logger.info("the app on disk is another build: this copy installs no update")
        status.applyReplacedOnDisk(true)
        return true
    }

    // MARK: From the UI and the app

    /// Restart to Update: confirms the busy native programs an update quit
    /// stops, then runs Sparkle's block, which relaunches through Sparkle's
    /// installer (never `NSApp.terminate`).
    func restartToUpdate() {
        guard status.isEnabled, !quitRequest.relaunchArmed, case .ready = status.phase else { return }
        if discardIfReplacedOnDisk() { return }
        guard actions.mayRestartNow() else { return }
        // Staged through Sparkle's window: resume its UI.
        guard let install else {
            actions.checkForUpdates()
            return
        }
        let count = actions.busyNativePrograms()
        if count > 0 {
            actions.confirmStopping(count) { [weak self] confirmed in
                // Cancel: nothing armed. The answer can come after a quit
                // started, Sparkle armed its relaunch or the app on disk was
                // replaced; then it installs nothing either.
                guard confirmed, let self, !self.quitRequest.relaunchArmed, case .ready = self.status.phase else { return }
                if self.discardIfReplacedOnDisk() { return }
                guard self.actions.mayRestartNow(), let install = self.install else { return }
                self.quitRequest.confirmStopping(at: self.actions.now())
                install()
            }
        } else {
            // Reusable: Sparkle ≥2.3 retries the termination when called again.
            install()
        }
    }

    /// Another build replaced the app on disk: the staged update, made for
    /// the build launched, never installs over it (Autoupdate's last stage
    /// compares no versions), so it is discarded and Settings says to
    /// reopen Cherry.
    private func discardIfReplacedOnDisk() -> Bool {
        guard noticeReplacedOnDisk() else { return false }
        discardDownloadedUpdate(reason: .bundleReplaced)
        return true
    }

    /// Check for Updates…: restarts when an update is staged. Nothing while
    /// another build is on disk (Settings says to reopen Cherry): an update
    /// found earlier would come back in Sparkle's window.
    func checkForUpdates() {
        guard status.isEnabled else { return }
        if case .ready = status.phase {
            restartToUpdate()
            return
        }
        if noticeReplacedOnDisk() {
            if case .available = status.phase { status.applyPhase(.idle) }
            return
        }
        actions.checkForUpdates()
    }

    /// Removes Sparkle's installer jobs, so a staged update never installs,
    /// and shows nothing staged at once; Sparkle's abort follows, silent,
    /// and Sparkle schedules its next check as usual. Nothing once a
    /// relaunch is armed, and nothing the user asks for an update staged
    /// from Sparkle's window (`AppUpdateStatus.offersDiscard`); quitting, or
    /// another build on disk (after which Cherry asks Sparkle for nothing),
    /// still removes its jobs.
    func discardDownloadedUpdate(reason: DiscardReason) {
        guard !quitRequest.relaunchArmed else { return }
        if reason == .user, case .ready(_, _, throughSparkle: true) = status.phase { return }
        // Sparkle's session that holds the block aborts; with no block
        // (staged through Sparkle's window, or nothing staged) none may.
        isDiscarding = install != nil
        actions.removeInstallerJobs()
        install = nil
        stagedBuild = nil
        status.applyPhase(.idle)
        logger.info("discarded the downloaded update: \(reason.rawValue, privacy: .public)")
    }

    /// At quit: the bundle on disk is not the one launched → discard any
    /// staged update so it never overwrites that build. Only while updates
    /// are enabled and no relaunch is armed.
    func discardIfBundleReplacedByHand(launchVersion: String?, diskVersion: String?) {
        guard status.isEnabled, !quitRequest.relaunchArmed,
              let launchVersion, let diskVersion, launchVersion != diskVersion
        else { return }
        discardDownloadedUpdate(reason: .bundleReplaced)
    }

    /// Get pre-release builds (`updates.prereleases`); a change resets
    /// Sparkle's cycle so the next check uses the channel. Turned off, a
    /// pre-release found but not downloaded is no longer offered (Sparkle
    /// keeps the session that found it until it is answered, so its window
    /// can still show it); one downloaded stays until it is discarded.
    var prereleases: Bool {
        get { status.prereleases }
        set {
            guard newValue != status.prereleases else { return }
            defaults.set(newValue, forKey: Self.prereleasesKey)
            status.applyPrereleases(newValue)
            if !newValue, case .available(_, "prerelease") = status.phase {
                status.applyPhase(.idle)
            }
            actions.resetUpdateCycle()
        }
    }

    /// Sparkle's allowed channels: stable items carry none.
    var allowedChannels: Set<String> { prereleases ? ["prerelease"] : [] }
}
