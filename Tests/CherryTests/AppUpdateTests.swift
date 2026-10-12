import AppKit
import Foundation
import Testing
@testable import Cherry

// The updater without Sparkle (docs/releasing.md): who may update itself
// (`AppUpdateEnablement`), Restart to Update and the quit it arms
// (`AppUpdateModel`, `UpdateQuitRequest`), discarding a staged update
// (`SparkleInstallerJobs`, `StagedUpdateWatch`), Settings › Updates, and
// the delegate selectors Sparkle calls. Fakes only: nothing here touches
// `AppUpdater.shared` or starts Sparkle.

// MARK: - Fakes

/// What the model asked of Sparkle and the app.
@MainActor
private final class FakeUpdateActions {
    var checks = 0
    var cycleResets = 0
    var installerJobRemovals = 0
    var installs = 0
    /// Busy native programs an update quit would stop.
    var busy = 0
    var mayRestart = true
    var bundleReplaced = false
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    /// The counts "Restart Cherry to update?" was asked for.
    var confirmations: [Int] = []
    private var pendingAnswer: (@MainActor (Bool) -> Void)?

    var actions: AppUpdateActions {
        AppUpdateActions(
            checkForUpdates: { self.checks += 1 },
            resetUpdateCycle: { self.cycleResets += 1 },
            busyNativePrograms: { self.busy },
            confirmStopping: { count, answer in
                self.confirmations.append(count)
                self.pendingAnswer = answer
            },
            mayRestartNow: { self.mayRestart },
            removeInstallerJobs: { self.installerJobRemovals += 1 },
            now: { self.now },
            bundleReplacedSinceLaunch: { self.bundleReplaced }
        )
    }

    /// Answers the pending confirmation.
    func answer(_ confirmed: Bool) {
        let answer = pendingAnswer
        pendingAnswer = nil
        answer?(confirmed)
    }

    /// Sparkle's immediate installation block.
    func install() {
        installs += 1
    }
}

/// A model on private defaults (removed by `tearDown`) and its own quit request.
@MainActor
private final class UpdateHarness {
    let fake = FakeUpdateActions()
    let quit = UpdateQuitRequest()
    let status: AppUpdateStatus
    let suiteName = "CherryTests.AppUpdate.\(UUID().uuidString)"
    let defaults: UserDefaults
    let model: AppUpdateModel

    init(enablement: AppUpdateEnablement = .enabled) {
        defaults = UserDefaults(suiteName: suiteName)!
        status = AppUpdateStatus(enablement: enablement)
        model = AppUpdateModel(status: status, quitRequest: quit, defaults: defaults, actions: fake.actions)
    }

    func stage(
        version: String = "2026.10.11.2",
        build: String = "20261011140300.abc1234",
        channel: String? = "prerelease"
    ) {
        let fake = fake
        model.updateStaged(version: version, build: build, channel: channel, install: { fake.install() })
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// An error as Sparkle reports it: `SUSparkleErrorDomain`, its message under
/// `NSLocalizedDescriptionKey` and what it wraps under `NSUnderlyingErrorKey`.
private func sparkleError(_ code: Int, _ message: String?, wrapping underlying: NSError? = nil) -> NSError {
    var userInfo: [String: Any] = [:]
    if let message { userInfo[NSLocalizedDescriptionKey] = message }
    if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: "SUSparkleErrorDomain", code: code, userInfo: userInfo)
}

/// What the app hears when Autoupdate refuses to put an older build over a
/// newer one installed by hand: `SPUInstallerDriver` reports the generic
/// installation error (4005), wrapping Autoupdate's `SPUInstallerError` (10),
/// which wraps the downgrade error (4006) its first stage raised.
private let downgradeRefusal = sparkleError(
    4005,
    "An error occurred while running the updater. Please try again later.",
    wrapping: sparkleError(
        10,
        "Error: Failed to start installer",
        wrapping: sparkleError(4006, "For security reasons, updates that downgrade version of the application are not allowed.")
    )
)

// MARK: - Enablement

/// A release build's Info.plist, as Scripts/install-local-app writes it.
private var releaseInfo: [String: Any] {
    [
        "CherryApplicationSupportName": "Cherry",
        "CherryURLScheme": "cherry",
        "SUFeedURL": "https://updates.cherry.patrick.wtf/appcast.xml",
        "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
        "CFBundleVersion": "20261011140300.abc1234",
    ]
}

@Test func enablementDecidesInOrder() {
    let app = URL(fileURLWithPath: "/Applications/Cherry.app")
    func decide(
        id: String? = "dev.patrick.cherry",
        url: URL = app,
        info: [String: Any] = releaseInfo,
        debug: Bool = false,
        diskImage: Bool = false,
        lock: Bool? = true
    ) -> AppUpdateEnablement {
        AppUpdateEnablement.decide(
            bundleIdentifier: id, bundleURL: url, info: info,
            isDebugBuild: debug, runsFromDiskImage: diskImage, holdsInstanceLock: lock
        )
    }
    func with(_ changes: [String: Any?]) -> [String: Any] {
        var info = releaseInfo
        for (key, value) in changes { info[key] = value }
        return info
    }

    // A full release Info.plist, with the lock held.
    #expect(decide() == .enabled)

    // Each reason.
    #expect(decide(url: URL(fileURLWithPath: "/tmp/cherry/.build/debug/Cherry")) == .disabled(.notAnApp))
    #expect(decide(id: "dev.patrick.cherry.local") == .disabled(.otherIdentity("dev.patrick.cherry.local")))
    #expect(decide(id: "app.cherry.CherryDev") == .disabled(.otherIdentity("app.cherry.CherryDev")))
    #expect(decide(id: nil) == .disabled(.otherIdentity(nil)))
    // The release id with another data folder or scheme is a variant.
    #expect(decide(info: with(["CherryApplicationSupportName": "Cherry Local"]))
        == .disabled(.otherIdentity("dev.patrick.cherry")))
    #expect(decide(info: with(["CherryURLScheme": "cherry-local"])) == .disabled(.otherIdentity("dev.patrick.cherry")))
    #expect(decide(info: with(["CherryApplicationSupportName": nil])) == .disabled(.otherIdentity("dev.patrick.cherry")))
    #expect(decide(debug: true) == .disabled(.debugBuild))
    #expect(decide(info: with(["SUFeedURL": "http://updates.cherry.patrick.wtf/appcast.xml"])) == .disabled(.notConfigured))
    #expect(decide(info: with(["SUFeedURL": nil])) == .disabled(.notConfigured))
    #expect(decide(info: with(["SUPublicEDKey": Data(repeating: 7, count: 31).base64EncodedString()]))
        == .disabled(.notConfigured))
    #expect(decide(info: with(["SUPublicEDKey": ""])) == .disabled(.notConfigured))
    #expect(decide(info: with(["SUPublicEDKey": "not base64!"])) == .disabled(.notConfigured))
    #expect(decide(info: with(["CFBundleVersion": ""])) == .disabled(.notConfigured))
    #expect(decide(diskImage: true) == .disabled(.diskImage))
    #expect(decide(lock: nil) == .disabled(.pending))
    #expect(decide(lock: false) == .disabled(.secondCopy))

    // The first failing rule wins, in that order.
    #expect(decide(id: "app.cherry.CherryDev", url: URL(fileURLWithPath: "/tmp/Cherry")) == .disabled(.notAnApp))
    #expect(decide(id: "app.cherry.CherryDev", debug: true) == .disabled(.otherIdentity("app.cherry.CherryDev")))
    #expect(decide(info: with(["SUFeedURL": nil]), debug: true) == .disabled(.debugBuild))
    #expect(decide(info: with(["SUFeedURL": nil]), diskImage: true) == .disabled(.notConfigured))
    #expect(decide(diskImage: true, lock: nil) == .disabled(.diskImage))
    #expect(decide(diskImage: true, lock: false) == .disabled(.diskImage))

    // What Settings › Updates says.
    #expect(AppUpdateEnablement.Reason.otherIdentity("app.cherry.CherryDev").explanation
        == "This build (app.cherry.CherryDev) doesn't update itself; only Cherry (dev.patrick.cherry) does.")
    #expect(AppUpdateEnablement.Reason.diskImage.explanation == "Move Cherry to Applications to get updates.")
    #expect(AppUpdateEnablement.disabled(.pending).reason == .pending)
    #expect(AppUpdateEnablement.enabled.reason == nil)
}

// MARK: - Restart to Update and the quit request

@Test @MainActor func stagedUpdateShowsRestartToUpdateWithItsChannel() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    #expect(harness.status.phase == .idle)

    harness.stage(channel: "prerelease")
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: "prerelease", throughSparkle: false))
    #expect(harness.model.stagedBuild == "20261011140300.abc1234")
    #expect(!harness.status.isRestarting)

    // A stable item carries no channel.
    harness.stage(version: "2026.10.12.1", build: "20261012090000.def5678", channel: nil)
    #expect(harness.status.phase == .ready(version: "2026.10.12.1", channel: nil, throughSparkle: false))
    #expect(harness.model.stagedBuild == "20261012090000.def5678")
}

@Test @MainActor func restartToUpdateInvokesTheBlockAndOnlySparklesArmingMakesTheQuitAnUpdate() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()

    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 1)
    #expect(harness.fake.confirmations.isEmpty)
    // The click alone arms nothing: Sparkle may still decline to relaunch.
    #expect(!harness.quit.isUpdateQuit)
    #expect(!harness.status.isRestarting)
    #expect(CherryAppDelegate.quitReason(
        appleEvent: nil, launchBundleVersion: "a", diskBundleVersion: "a", updateRequested: harness.quit.isUpdateQuit
    ) == .user)

    // updaterWillRelaunchApplication, before Sparkle's quit event.
    harness.model.relaunchArmed()
    #expect(harness.quit.isUpdateQuit)
    #expect(harness.status.isRestarting)
    #expect(CherryAppDelegate.quitReason(
        appleEvent: nil, launchBundleVersion: "a", diskBundleVersion: "a", updateRequested: harness.quit.isUpdateQuit
    ) == .update)
}

@Test @MainActor func restartToUpdateAsksFirstWhenNativeProgramsAreBusy() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.fake.busy = 2
    harness.stage()

    // Cancel: nothing is installed or confirmed.
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [2])
    #expect(harness.fake.installs == 0)
    harness.fake.answer(false)
    #expect(harness.fake.installs == 0)
    #expect(!harness.quit.stoppingConfirmed(now: harness.fake.now))
    #expect(!harness.quit.isUpdateQuit)

    // Restart: confirmed, then the block runs.
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [2, 2])
    harness.fake.answer(true)
    #expect(harness.fake.installs == 1)
    #expect(harness.quit.stoppingConfirmed(now: harness.fake.now))
    // So the update's quit does not ask again.
    #expect(SessionQuitPlan.confirmStopping(count: 2, intent: .appQuit).forUpdate(
        reason: .update, stoppingConfirmed: harness.quit.stoppingConfirmed(now: harness.fake.now)
    ) == .finish(.appQuit))
}

@Test @MainActor func stoppingConfirmationExpiresAfterAMinute() {
    let quit = UpdateQuitRequest()
    let confirmed = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!quit.stoppingConfirmed(now: confirmed))
    quit.confirmStopping(at: confirmed)
    #expect(quit.stoppingConfirmed(now: confirmed))
    #expect(quit.stoppingConfirmed(now: confirmed.addingTimeInterval(59)))
    #expect(quit.stoppingConfirmed(now: confirmed.addingTimeInterval(UpdateQuitRequest.stoppingConfirmationLifetime)))
    #expect(!quit.stoppingConfirmed(now: confirmed.addingTimeInterval(61)))
    #expect(!quit.stoppingConfirmed(now: confirmed.addingTimeInterval(-1)))

    // Through the model, with its clock.
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.fake.busy = 1
    harness.stage()
    harness.model.restartToUpdate()
    harness.fake.answer(true)
    #expect(harness.quit.stoppingConfirmed(now: harness.fake.now.addingTimeInterval(30)))
    let late = harness.fake.now.addingTimeInterval(90)
    #expect(!harness.quit.stoppingConfirmed(now: late))
    // A quit a minute and a half later asks again.
    #expect(SessionQuitPlan.confirmStopping(count: 1, intent: .appQuit).forUpdate(
        reason: .update, stoppingConfirmed: harness.quit.stoppingConfirmed(now: late)
    ) == .confirmStopping(count: 1, intent: .appQuit))
}

@Test @MainActor func restartToUpdateDoesNothingWhileAQuitIsPendingOrARelaunchIsArmed() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.fake.busy = 1

    // Nothing staged.
    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 0)
    #expect(harness.fake.confirmations.isEmpty)

    // A quit is pending, or a window's close question is up.
    harness.stage()
    harness.fake.mayRestart = false
    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 0)
    #expect(harness.fake.confirmations.isEmpty)

    // A quit started (⌘Q) while the confirmation was up: its answer
    // installs nothing; the update installs when that quit finishes.
    harness.fake.mayRestart = true
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [1])
    harness.fake.mayRestart = false
    harness.fake.answer(true)
    #expect(harness.fake.installs == 0)
    #expect(!harness.quit.stoppingConfirmed(now: harness.fake.now))
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: "prerelease", throughSparkle: false))

    // Sparkle armed its relaunch while the confirmation was up: its answer
    // installs nothing more.
    harness.fake.mayRestart = true
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [1, 1])
    harness.model.relaunchArmed()
    harness.fake.answer(true)
    #expect(harness.fake.installs == 0)
    #expect(!harness.quit.stoppingConfirmed(now: harness.fake.now))

    // Armed: nothing until it installs or aborts.
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [1, 1])
    #expect(harness.fake.installs == 0)

    // An updater that is off does nothing either.
    let off = UpdateHarness(enablement: .disabled(.secondCopy))
    defer { off.tearDown() }
    off.stage()
    off.model.restartToUpdate()
    #expect(off.fake.installs == 0)
}

@Test @MainActor func restartToUpdateAgainAfterACancelledQuitInvokesTheBlockAgain() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()

    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 1)
    // The quit Sparkle asked for was cancelled before it armed anything.
    harness.quit.quitWasCancelled()
    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 2)

    // With busy programs, a cancelled quit forgets their confirmation: the
    // next Restart to Update asks again.
    harness.fake.busy = 1
    harness.model.restartToUpdate()
    harness.fake.answer(true)
    #expect(harness.fake.installs == 3)
    #expect(harness.quit.stoppingConfirmed(now: harness.fake.now))
    harness.quit.quitWasCancelled()
    #expect(!harness.quit.stoppingConfirmed(now: harness.fake.now))
    harness.model.restartToUpdate()
    #expect(harness.fake.confirmations == [1, 1])
    harness.fake.answer(true)
    #expect(harness.fake.installs == 4)
}

@Test @MainActor func armedRelaunchSurvivesACancelledQuitButAnAbortClearsIt() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()
    harness.model.restartToUpdate()
    harness.model.relaunchArmed()
    harness.quit.confirmStopping(at: harness.fake.now)

    harness.quit.quitWasCancelled()
    #expect(harness.quit.isUpdateQuit)
    #expect(!harness.quit.stoppingConfirmed(now: harness.fake.now))
    #expect(harness.status.isRestarting)

    harness.model.aborted(error: sparkleError(4005, "An error occurred while running the updater."))
    #expect(!harness.quit.isUpdateQuit)
    #expect(!harness.status.isRestarting)
    #expect(harness.status.phase == .idle)
    #expect(harness.model.stagedBuild == nil)
    #expect(harness.status.lastError == "An error occurred while running the updater.")
}

@Test @MainActor func abortShowsTheErrorUnlessDiscardingADowngradeOrAReplacedBundle() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }

    // An ordinary failure says why.
    harness.stage()
    harness.model.aborted(error: sparkleError(2001, "The update could not be downloaded."))
    #expect(harness.status.lastError == "The update could not be downloaded.")
    #expect(harness.status.phase == .idle)
    // A new staged update clears it.
    harness.stage()
    #expect(harness.status.lastError == nil)

    // The abort a discard causes says nothing, and only that one.
    harness.model.discardDownloadedUpdate(reason: .user)
    harness.model.aborted(error: sparkleError(4005, "The remote port connection was invalidated from the updater."))
    #expect(harness.status.lastError == nil)
    harness.model.aborted(error: sparkleError(2001, "The update could not be downloaded."))
    #expect(harness.status.lastError == "The update could not be downloaded.")

    // A discard whose session ended without aborting (its cycle finished)
    // leaves the next failure to be said.
    harness.stage()
    harness.model.discardDownloadedUpdate(reason: .pulled)
    harness.model.checkFinished(at: harness.fake.now, error: nil)
    harness.model.aborted(error: sparkleError(2001, "The update could not be downloaded again."))
    #expect(harness.status.lastError == "The update could not be downloaded again.")

    // A newer build installed by hand refuses the older update: Sparkle
    // reports 4005, with the downgrade (4006) two levels under it.
    #expect(AppUpdateModel.isDowngrade(downgradeRefusal))
    #expect(!AppUpdateModel.isDowngrade(sparkleError(4005, "An error occurred while running the updater.")))
    #expect(!AppUpdateModel.isDowngrade(NSError(domain: NSCocoaErrorDomain, code: 4006)))
    harness.stage()
    harness.model.aborted(error: downgradeRefusal)
    #expect(harness.status.lastError == nil)
    #expect(harness.status.phase == .idle)
    #expect(harness.model.stagedBuild == nil)

    // Its installer removed by hand (install-local-app's bootout) ends with
    // the generic 4005 and nothing under it: quiet once the app on disk is
    // another build, which Settings then says.
    harness.stage()
    harness.fake.bundleReplaced = true
    harness.model.aborted(error: sparkleError(4005, "An error occurred while running the updater. Please try again later."))
    #expect(harness.status.lastError == nil)
    #expect(harness.status.isReplacedOnDisk)

    // No reason: nothing to say.
    let quiet = UpdateHarness()
    defer { quiet.tearDown() }
    quiet.stage()
    quiet.model.aborted(error: sparkleError(4005, nil))
    #expect(quiet.status.lastError == nil)
    #expect(quiet.status.phase == .idle)
    #expect(!quiet.status.isReplacedOnDisk)

    // "No update" is no abort: a staged update stays staged.
    quiet.stage()
    quiet.model.aborted(error: sparkleError(1001, "You're up to date!"))
    #expect(quiet.status.lastError == nil)
    #expect(quiet.model.stagedBuild != nil)
}

@Test @MainActor func aCheckThatSucceedsClearsTheLastFailure() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    let failure = sparkleError(2001, "An error occurred in retrieving update information. Please try again later.")

    // A failed check: its abort says why, and its cycle's end (same error) keeps it.
    harness.model.aborted(error: failure)
    harness.model.checkFinished(at: harness.fake.now, error: failure)
    #expect(harness.status.lastError == failure.localizedDescription)
    #expect(harness.status.lastCheck == harness.fake.now)

    // The next check finds nothing newer: the error goes.
    let later = harness.fake.now.addingTimeInterval(3600)
    harness.model.checkFinished(at: later, error: sparkleError(1001, "You're up to date!"))
    #expect(harness.status.lastError == nil)
    #expect(harness.status.lastCheck == later)

    // A cycle that ends with no error clears it too.
    harness.model.aborted(error: failure)
    harness.model.checkFinished(at: later, error: nil)
    #expect(harness.status.lastError == nil)

    // Loading Sparkle's last check at start clears nothing.
    harness.model.aborted(error: failure)
    harness.model.lastCheckLoaded(later)
    #expect(harness.status.lastError == failure.localizedDescription)
}

@Test @MainActor func checksAreRefusedWhileAnotherBuildIsOnDisk() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }

    // The same build: checks run.
    #expect(harness.model.checkRefusal() == nil)
    harness.model.checkForUpdates()
    #expect(harness.fake.checks == 1)
    #expect(!harness.status.isReplacedOnDisk)

    // Another build on disk: Sparkle's checks are refused (its scheduled
    // ones would download an update Autoupdate refuses, every hour).
    harness.model.aborted(error: sparkleError(2001, "An earlier failure."))
    harness.fake.bundleReplaced = true
    let refusal = harness.model.checkRefusal()
    #expect(refusal != nil)
    #expect(harness.status.isReplacedOnDisk)
    // The refusal comes back as the cycle's abort and end: it changes
    // nothing, and the earlier failure stays (nothing was checked).
    harness.model.updateNeedsAttention(version: "2026.10.12.1", channel: nil)
    harness.model.aborted(error: refusal!)
    harness.model.checkFinished(at: harness.fake.now, error: refusal)
    #expect(harness.status.phase == .available(version: "2026.10.12.1", channel: nil))
    #expect(harness.status.lastError == "An earlier failure.")

    // Check Now and Install… reach nothing in Sparkle; what it found is no
    // longer offered.
    harness.model.checkForUpdates()
    #expect(harness.fake.checks == 1)
    #expect(harness.status.phase == .idle)
}

@Test @MainActor func restartToUpdateDiscardsAnUpdateStagedBeforeTheAppWasReplacedOnDisk() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()

    // Copied over by hand: Restart to Update never installs the older build.
    harness.fake.bundleReplaced = true
    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 0)
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .idle)
    #expect(harness.model.stagedBuild == nil)
    #expect(harness.status.isReplacedOnDisk)
    // Sparkle's abort for the removed installer says nothing.
    harness.model.aborted(error: sparkleError(4005, "An error occurred while running the updater. Please try again later."))
    #expect(harness.status.lastError == nil)

    // Replaced while "Restart Cherry to update?" was up: the answer discards.
    let asking = UpdateHarness()
    defer { asking.tearDown() }
    asking.fake.busy = 1
    asking.stage()
    asking.model.restartToUpdate()
    #expect(asking.fake.confirmations == [1])
    asking.fake.bundleReplaced = true
    asking.fake.answer(true)
    #expect(asking.fake.installs == 0)
    #expect(asking.fake.installerJobRemovals == 1)
    #expect(!asking.quit.stoppingConfirmed(now: asking.fake.now))
    #expect(asking.status.phase == .idle)

    // Staged from Sparkle's window: discarded too, and Sparkle's window is not reopened.
    let sparkle = UpdateHarness()
    defer { sparkle.tearDown() }
    sparkle.model.updateStagedThroughSparkle(version: "2026.10.11.2", channel: nil)
    sparkle.fake.bundleReplaced = true
    sparkle.model.restartToUpdate()
    #expect(sparkle.fake.checks == 0)
    #expect(sparkle.fake.installerJobRemovals == 1)
    #expect(sparkle.status.phase == .idle)
}

// MARK: - Discarding

@Test @MainActor func discardRemovesSparklesInstallerJobsAndReturnsToIdle() {
    #expect(SparkleInstallerJobs.labels(bundleIdentifier: "dev.patrick.cherry")
        == ["dev.patrick.cherry-sparkle-updater", "dev.patrick.cherry-sparkle-progress"])
    var commands: [[String]] = []
    SparkleInstallerJobs.remove(bundleIdentifier: "dev.patrick.cherry") { commands.append($0) }
    #expect(commands == [
        ["remove", "dev.patrick.cherry-sparkle-updater"],
        ["remove", "dev.patrick.cherry-sparkle-progress"],
    ])
    // No bundle identifier (`swift run`): nothing to remove.
    commands.removeAll()
    SparkleInstallerJobs.remove(bundleIdentifier: "") { commands.append($0) }
    #expect(commands.isEmpty)

    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()
    harness.model.discardDownloadedUpdate(reason: .user)
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .idle)
    #expect(harness.model.stagedBuild == nil)
    // Its block is gone: Restart to Update has nothing to run.
    harness.model.restartToUpdate()
    #expect(harness.fake.installs == 0)

    // Never once Sparkle armed its relaunch.
    harness.stage()
    harness.model.restartToUpdate()
    harness.model.relaunchArmed()
    harness.model.discardDownloadedUpdate(reason: .user)
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: "prerelease", throughSparkle: false))
}

@Test @MainActor func bundleReplacedByHandDiscardsTheStagedUpdate() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage()

    // The same build on disk, or no bundle to compare: nothing.
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: "20261011140300.abc1234")
    harness.model.discardIfBundleReplacedByHand(launchVersion: nil, diskVersion: "20261012090000.def5678")
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: nil)
    #expect(harness.fake.installerJobRemovals == 0)
    #expect(harness.model.stagedBuild != nil)

    // Another build on disk: the staged update goes.
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: "20261012090000.def5678")
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .idle)
    // Its jobs are removed even when Cherry knows of nothing staged.
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: "20261012090000.def5678")
    #expect(harness.fake.installerJobRemovals == 2)

    // An armed relaunch installs as Sparkle planned.
    harness.stage()
    harness.model.relaunchArmed()
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: "20261012090000.def5678")
    #expect(harness.fake.installerJobRemovals == 2)
    #expect(harness.status.phase != .idle)

    // An updater that is off removes nothing.
    let off = UpdateHarness(enablement: .disabled(.otherIdentity("app.cherry.CherryDev")))
    defer { off.tearDown() }
    off.model.discardIfBundleReplacedByHand(launchVersion: "a", diskVersion: "b")
    #expect(off.fake.installerJobRemovals == 0)
}

/// An appcast as Scripts/cherry-release writes it.
private func feed(items: [String], pulled: [String] = []) -> Data {
    let itemXML = items.map { build in
        """
        <item>
          <title>Cherry</title>
          <sparkle:version>\(build)</sparkle:version>
          <sparkle:shortVersionString>2026.10.11.1</sparkle:shortVersionString>
          <description><![CDATA[<ul><li>notes</li></ul>]]></description>
          <enclosure url="https://github.com/patrick91/cherry/releases/download/v1/Cherry.zip" length="1" type="application/octet-stream" sparkle:edSignature="c2ln"/>
        </item>
        """
    }.joined(separator: "\n")
    let pulledXML = pulled.map { "<cherry:pulled version=\"2026.10.11.1\">\($0)</cherry:pulled>" }.joined()
    return Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:cherry="https://updates.cherry.patrick.wtf/xmlns/appcast">
      <channel>
        <title>Cherry</title>
        \(pulledXML)
        \(itemXML)
      </channel>
    </rss>
    """.utf8)
}

/// The builds `StagedUpdateWatch` reported gone.
@MainActor
private final class GoneBuilds {
    var builds: [String] = []
}

private struct FeedUnreachable: Error {}

@Test @MainActor func stagedUpdateWatchDiscardsOnlyAPulledOrMissingBuild() async {
    // Parsing.
    let parsed = StagedUpdateWatch.parse(feed(items: ["B2", "B1"], pulled: ["B0"]))
    #expect(parsed?.versions == ["B2", "B1"])
    #expect(parsed?.pulled == ["B0"])
    #expect(StagedUpdateWatch.parse(Data("not a feed <".utf8)) == nil)
    #expect(StagedUpdateWatch.parse(feed(items: []))?.versions == [])
    // A version given only on the enclosure counts too.
    let enclosureOnly = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>\
    <enclosure url="https://example.invalid/a.zip" sparkle:version="B3"/></item></channel></rss>
    """.utf8)
    #expect(StagedUpdateWatch.parse(enclosureOnly)?.versions == ["B3"])

    func gone(_ answer: Result<(Data, Int), any Error>, watching build: String = "B1") async -> [String] {
        let gone = GoneBuilds()
        let watch = StagedUpdateWatch(
            feedURL: URL(string: "https://example.invalid/appcast.xml")!,
            interval: .seconds(3600),
            fetch: { _ in try answer.get() },
            onGone: { gone.builds.append($0) }
        )
        watch.watch(build: build)
        await watch.check()
        // Once: the watch stopped.
        await watch.check()
        return gone.builds
    }

    // Gone from the feed, or listed as pulled: discard.
    #expect(await gone(.success((feed(items: ["B2"]), 200))) == ["B1"])
    #expect(await gone(.success((feed(items: ["B2", "B1"], pulled: ["B1"]), 200))) == ["B1"])
    // Never on a failure or an answer that says nothing.
    #expect(await gone(.failure(FeedUnreachable())) == [])
    #expect(await gone(.success((feed(items: ["B2"]), 404))) == [])
    #expect(await gone(.success((Data("<html>challenge".utf8), 200))) == [])
    #expect(await gone(.success((feed(items: []), 200))) == [])
    // Still listed: nothing.
    #expect(await gone(.success((feed(items: ["B2", "B1"], pulled: ["B0"]), 200))) == [])

    // A watch stopped (nothing staged) looks at nothing.
    let stopped = GoneBuilds()
    let watch = StagedUpdateWatch(
        feedURL: URL(string: "https://example.invalid/appcast.xml")!,
        fetch: { _ in (feed(items: ["B2"]), 200) },
        onGone: { stopped.builds.append($0) }
    )
    watch.watch(build: "B1")
    watch.watch(build: nil)
    #expect(await watch.check() == false)
    #expect(stopped.builds.isEmpty)

    // Gone discards the staged update.
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.stage(build: "B1")
    let model = harness.model
    let discarding = StagedUpdateWatch(
        feedURL: URL(string: "https://example.invalid/appcast.xml")!,
        fetch: { _ in (feed(items: ["B2"]), 200) },
        onGone: { _ in model.discardDownloadedUpdate(reason: .pulled) }
    )
    discarding.watch(build: model.stagedBuild)
    await discarding.check()
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .idle)
}

// MARK: - Sparkle's own window, checks and channels

@Test @MainActor func installOnQuitChosenInSparklesWindowShowsRestartToUpdateThatResumesSparkle() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    harness.fake.busy = 2
    // SPUUserUpdateState.stage == .installing.
    harness.model.updateStagedThroughSparkle(version: "2026.10.11.2", channel: nil)
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: nil, throughSparkle: true))
    // Not watched: no block, no build.
    #expect(harness.model.stagedBuild == nil)

    // Restart to Update resumes Sparkle's Install and Relaunch, which asks itself.
    harness.model.restartToUpdate()
    #expect(harness.fake.checks == 1)
    #expect(harness.fake.installs == 0)
    #expect(harness.fake.confirmations.isEmpty)

    // Not discarded from Cherry: it is skipped in Sparkle's window, since
    // removing the jobs of a session Sparkle resumed ends nothing and leaves
    // that session waiting for good.
    #expect(!harness.status.offersDiscard)
    harness.model.discardDownloadedUpdate(reason: .user)
    #expect(harness.fake.installerJobRemovals == 0)
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: nil, throughSparkle: true))
    // Its abort, if Sparkle's window then skips it, says nothing new.
    harness.model.aborted(error: sparkleError(4005, nil))
    #expect(harness.status.phase == .idle)
    #expect(harness.status.lastError == nil)

    // At quit, another build on disk still removes its jobs.
    harness.model.updateStagedThroughSparkle(version: "2026.10.11.2", channel: nil)
    harness.model.discardIfBundleReplacedByHand(launchVersion: "20261011140300.abc1234", diskVersion: "20261012090000.def5678")
    #expect(harness.fake.installerJobRemovals == 1)
    #expect(harness.status.phase == .idle)

    // An update Cherry staged offers it.
    harness.stage()
    #expect(harness.status.offersDiscard)
}

@Test @MainActor func scheduledUpdateNeedingAttentionShowsUpdateAvailableUntilHandled() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }

    harness.model.updateNeedsAttention(version: "2026.10.12.1", channel: nil)
    #expect(harness.status.phase == .available(version: "2026.10.12.1", channel: nil))
    // Update Available opens Sparkle's window.
    harness.model.checkForUpdates()
    #expect(harness.fake.checks == 1)
    harness.model.attentionReceived()
    #expect(harness.status.phase == .idle)

    // Or Sparkle's session ends.
    harness.model.prereleases = true
    harness.model.updateNeedsAttention(version: "2026.10.12.1", channel: "prerelease")
    #expect(harness.status.phase == .available(version: "2026.10.12.1", channel: "prerelease"))
    harness.model.sessionFinished()
    #expect(harness.status.phase == .idle)

    // A staged update stays staged.
    harness.stage()
    harness.model.updateNeedsAttention(version: "2026.10.12.1", channel: nil)
    harness.model.attentionReceived()
    harness.model.sessionFinished()
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: "prerelease", throughSparkle: false))
}

@Test @MainActor func checkForUpdatesWhileReadyRestarts() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }

    harness.model.checkForUpdates()
    #expect(harness.fake.checks == 1)

    harness.stage()
    harness.model.checkForUpdates()
    #expect(harness.fake.installs == 1)
    #expect(harness.fake.checks == 1)

    let off = UpdateHarness(enablement: .disabled(.notAnApp))
    defer { off.tearDown() }
    off.model.checkForUpdates()
    #expect(off.fake.checks == 0)
}

@Test @MainActor func prereleaseToggleChoosesTheChannelAndResetsTheCycleOnce() {
    let harness = UpdateHarness()
    defer { harness.tearDown() }
    #expect(!harness.model.prereleases)
    #expect(harness.model.allowedChannels == [])

    harness.model.prereleases = true
    #expect(harness.model.allowedChannels == ["prerelease"])
    #expect(harness.status.prereleases)
    #expect(harness.defaults.bool(forKey: AppUpdateModel.prereleasesKey))
    #expect(harness.fake.cycleResets == 1)
    // The same value again changes nothing.
    harness.model.prereleases = true
    #expect(harness.fake.cycleResets == 1)

    // A pre-release found but not downloaded is no longer offered once
    // they are turned off, and none found later is.
    harness.model.updateNeedsAttention(version: "2026.10.12.1", channel: "prerelease")
    #expect(harness.status.phase == .available(version: "2026.10.12.1", channel: "prerelease"))
    harness.model.prereleases = false
    #expect(harness.model.allowedChannels == [])
    #expect(!harness.defaults.bool(forKey: AppUpdateModel.prereleasesKey))
    #expect(harness.fake.cycleResets == 2)
    #expect(harness.status.phase == .idle)
    harness.model.updateNeedsAttention(version: "2026.10.12.2", channel: "prerelease")
    #expect(harness.status.phase == .idle)
    // A stable release still is.
    harness.model.updateNeedsAttention(version: "2026.10.13.1", channel: nil)
    #expect(harness.status.phase == .available(version: "2026.10.13.1", channel: nil))
    // A downloaded pre-release stays until it is discarded.
    harness.model.prereleases = true
    harness.stage(channel: "prerelease")
    harness.model.prereleases = false
    #expect(harness.status.phase == .ready(version: "2026.10.11.2", channel: "prerelease", throughSparkle: false))
    #expect(harness.fake.cycleResets == 4)

    // The choice is kept for the next launch.
    harness.defaults.set(true, forKey: AppUpdateModel.prereleasesKey)
    let next = AppUpdateModel(
        status: AppUpdateStatus(enablement: .enabled),
        quitRequest: UpdateQuitRequest(),
        defaults: harness.defaults,
        actions: harness.fake.actions
    )
    #expect(next.allowedChannels == ["prerelease"])
    #expect(next.status.prereleases)
    #expect(harness.fake.cycleResets == 4)
}

// MARK: - Settings, configuration and Sparkle's selectors

@Test func updatesSettingsPageIsFoundBySearch() {
    for query in ["update", "pre-release", "version", "Updates", "beta"] {
        #expect(SettingsPage.filtered(by: query).contains(.updates), Comment(rawValue: query))
    }
    // The Sessions page's searches find only it.
    for query in ["quitting", "exit", "shell", "close"] {
        #expect(SettingsPage.filtered(by: query) == [.sessions], Comment(rawValue: query))
    }
    #expect(SettingsPage.allCases.last == .updates)
    #expect(SettingsPage.updates.title == "Updates")
}

@Test func releaseBundleIdentifierMatchesPackagingReleaseConf() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let conf = try String(contentsOf: root.appendingPathComponent("Packaging/release.conf"), encoding: .utf8)
    // As the scripts read it: the last RELEASE_BUNDLE_ID= line.
    let identifier = conf.split(separator: "\n")
        .last { $0.hasPrefix("RELEASE_BUNDLE_ID=") }
        .map { String($0.dropFirst("RELEASE_BUNDLE_ID=".count)) }
    #expect(identifier == CherryRelease.bundleIdentifier)
}

@Test @MainActor func sparkleBridgeRespondsToEverySelectorCherryReliesOn() {
    #expect(SparkleBridge.requiredSelectors.count == 11)
    for selector in SparkleBridge.requiredSelectors {
        #expect(SparkleBridge.instancesRespond(to: NSSelectorFromString(selector)), Comment(rawValue: selector))
    }
    // The model's copies of Sparkle's error domain and codes.
    #expect(SparkleBridge.constantsMatchSparkle)
}
