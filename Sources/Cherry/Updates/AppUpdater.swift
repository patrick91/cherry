import AppKit
import Combine
import os
import Sparkle

/// Cherry's Sparkle updater (docs/releasing.md). The only file that imports
/// Sparkle: `AppUpdateModel` holds the state, `AppUpdateStatus` what the
/// views show. Nothing starts Sparkle until `startIfEnabled`, which the app
/// calls on a later turn once the launch's windows opened, and only a
/// release build of the release identity that holds the instance lock
/// starts it (`AppUpdateEnablement.decide`).
@MainActor
final class AppUpdater {
    /// Its init decides only the preliminary enablement and publishes nothing.
    static let shared = AppUpdater()

    let status: AppUpdateStatus
    let model: AppUpdateModel
    private let sparkle: SparkleHandle
    private var userDriver: SPUStandardUserDriver?
    /// Strong: Sparkle holds its delegates weakly.
    private var bridge: SparkleBridge?
    private var watch: StagedUpdateWatch?
    private var observations: Set<AnyCancellable> = []
    private var didStart = false
    private static let logger = Logger(subsystem: SessionLog.subsystem, category: "Updates")

    private init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let status = AppUpdateStatus(
            enablement: Self.enablement(bundle: bundle, holdsInstanceLock: nil),
            prereleases: defaults.bool(forKey: AppUpdateModel.prereleasesKey)
        )
        let sparkle = SparkleHandle()
        self.status = status
        self.sparkle = sparkle
        model = AppUpdateModel(
            status: status,
            quitRequest: .shared,
            defaults: defaults,
            actions: AppUpdateActions(
                checkForUpdates: { sparkle.updater?.checkForUpdates() },
                resetUpdateCycle: { sparkle.updater?.resetUpdateCycleAfterShortDelay() },
                busyNativePrograms: { CherryAppDelegate.updateRestartStoppedProgramCount() },
                confirmStopping: { count, answer in CherryAppDelegate.confirmRestartToUpdate(count: count, answer: answer) },
                mayRestartNow: { CherryAppDelegate.mayRestartToUpdateNow() },
                removeInstallerJobs: { SparkleInstallerJobs.remove(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") },
                now: { Date() },
                bundleReplacedSinceLaunch: { CherryAppDelegate.appBundleReplacedSinceLaunch() }
            )
        )
    }

    private static func enablement(bundle: Bundle, holdsInstanceLock: Bool?) -> AppUpdateEnablement {
        AppUpdateEnablement.decide(
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: bundle.bundleURL,
            info: bundle.infoDictionary ?? [:],
            isDebugBuild: AppUpdateEnablement.isDebugBuild,
            runsFromDiskImage: HostedSessionInstallation.runsFromDiskImage(bundleURL: bundle.bundleURL),
            holdsInstanceLock: holdsInstanceLock
        )
    }

    /// Starts Sparkle once, when this copy may update itself. Never
    /// `SPUStandardUpdaterController`, which pops an alert when it cannot start.
    func startIfEnabled(bundle: Bundle = .main, lock: AppInstanceLock = .shared) {
        guard !didStart else { return }
        didStart = true
        let enablement = Self.enablement(bundle: bundle, holdsInstanceLock: lock.isResolved ? lock.isHeld : nil)
        status.applyEnablement(enablement)
        guard enablement == .enabled else {
            Self.logger.info("updates are off: \(enablement.reason?.explanation ?? "", privacy: .public)")
            return
        }

        let bridge = SparkleBridge(model: model)
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: bridge)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: bridge)
        self.bridge = bridge
        self.userDriver = userDriver
        do {
            try updater.start()
        } catch {
            status.applyLastError(error.localizedDescription)
            Self.logger.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
            sparkle.updater = nil
            return
        }
        sparkle.updater = updater
        Self.logger.info("the updater started")

        let model = model
        updater.publisher(for: \.canCheckForUpdates)
            .sink { value in MainActor.assumeIsolated { model.canCheckChanged(value) } }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { value in MainActor.assumeIsolated { model.automaticallyChecksChanged(value) } }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { value in MainActor.assumeIsolated { model.automaticallyDownloadsChanged(value) } }
            .store(in: &observations)
        model.lastCheckLoaded(updater.lastUpdateCheckDate)

        // A staged build the feed no longer lists, or lists as pulled, is discarded.
        if let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)) {
            let watch = StagedUpdateWatch(feedURL: feed, fetch: StagedUpdateWatch.fetchFeed) { [weak model] _ in
                model?.discardDownloadedUpdate(reason: .pulled)
            }
            self.watch = watch
            // `$phase` publishes before the change, after `stagedBuild` is set.
            status.$phase
                .sink { phase in
                    MainActor.assumeIsolated {
                        if case .ready(_, _, throughSparkle: false) = phase {
                            watch.watch(build: model.stagedBuild)
                        } else {
                            watch.watch(build: nil)
                        }
                    }
                }
                .store(in: &observations)
        }
    }

    func checkForUpdates() {
        model.checkForUpdates()
    }

    func restartToUpdate() {
        model.restartToUpdate()
    }

    func discardDownloadedUpdate() {
        model.discardDownloadedUpdate(reason: .user)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        sparkle.updater?.automaticallyChecksForUpdates = on
    }

    func setAutomaticallyDownloads(_ on: Bool) {
        sparkle.updater?.automaticallyDownloadsUpdates = on
    }

    func setPrereleases(_ on: Bool) {
        model.prereleases = on
    }

    /// applicationShouldTerminate: the bundle on disk is not the one launched (install-local-app,
    /// a DMG drag) → discard any staged update so it never overwrites that build.
    func discardIfBundleReplacedByHand(launchVersion: String?, diskVersion: String?) {
        model.discardIfBundleReplacedByHand(launchVersion: launchVersion, diskVersion: diskVersion)
    }
}

/// The running `SPUUpdater`, for the model's actions, which are made
/// before it exists.
@MainActor
private final class SparkleHandle {
    var updater: SPUUpdater?
}

/// Sparkle's updater and standard user driver delegate. Internal (not
/// private) so AppUpdateTests can check its selectors.
@MainActor
final class SparkleBridge: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    /// The Objective-C selectors Cherry relies on, as Sparkle 2.10.0's headers name them.
    nonisolated static let requiredSelectors = [
        "allowedChannelsForUpdater:",
        "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
        "updaterWillRelaunchApplication:",
        "updater:didAbortWithError:",
        "updater:didFinishUpdateCycleForUpdateCheck:error:",
        "updater:mayPerformUpdateCheck:error:",
        "supportsGentleScheduledUpdateReminders",
        "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
        "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
        "standardUserDriverDidReceiveUserAttentionForUpdate:",
        "standardUserDriverWillFinishUpdateSession",
    ]

    /// `AppUpdateModel`'s copies of Sparkle's error domain and codes are Sparkle's.
    nonisolated static var constantsMatchSparkle: Bool {
        AppUpdateModel.sparkleErrorDomain == SUSparkleErrorDomain
            && AppUpdateModel.noUpdateErrorCode == Int(SUError.noUpdateError.rawValue)
            && AppUpdateModel.downgradeErrorCode == Int(SUError.downgradeError.rawValue)
    }

    private let model: AppUpdateModel

    init(model: AppUpdateModel) {
        self.model = model
        super.init()
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        model.allowedChannels
    }

    /// A scheduled check staged an update: Cherry keeps the block (Restart
    /// to Update) and Sparkle shows nothing; it installs at quit otherwise.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        model.updateStaged(
            version: item.displayVersionString,
            build: item.versionString,
            channel: item.channel,
            install: { immediateInstallHandler() }
        )
        return true
    }

    /// Synchronously before stage 2, so before Sparkle's quit event.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        model.relaunchArmed()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        model.aborted(error: error as NSError)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        model.checkFinished(at: updater.lastUpdateCheckDate, error: error.map { $0 as NSError })
    }

    /// `updater:mayPerformUpdateCheck:error:`: no check while another build
    /// is on disk (`AppUpdateModel.checkRefusal`). Swift cannot refuse with
    /// no error, so the refusal carries Cherry's own, which the model ignores
    /// when it comes back as the cycle's abort. Only scheduled checks get
    /// here then (Check Now stops in the model), their abort shows nothing,
    /// and Sparkle schedules the next one as usual.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let refusal = model.checkRefusal() { throw refusal }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates show in Cherry (the pill), never in Sparkle's window.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if state.stage == .installing {
            model.updateStagedThroughSparkle(version: update.displayVersionString, channel: update.channel)
        } else if !handleShowingUpdate {
            model.updateNeedsAttention(version: update.displayVersionString, channel: update.channel)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        model.attentionReceived()
    }

    func standardUserDriverWillFinishUpdateSession() {
        model.sessionFinished()
    }
}
