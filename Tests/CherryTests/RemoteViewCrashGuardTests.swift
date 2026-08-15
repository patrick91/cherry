import Foundation
import Testing
import CherryCrashGuard
@testable import Cherry

@Test func remoteViewCrashGuardIsScopedToMacOS27() {
    #expect(!RemoteViewCrashGuard.isRequired(on: OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 9,
        patchVersion: 0
    )))
    #expect(RemoteViewCrashGuard.isRequired(on: OperatingSystemVersion(
        majorVersion: 27,
        minorVersion: 0,
        patchVersion: 0
    )))
    #expect(RemoteViewCrashGuard.isRequired(on: OperatingSystemVersion(
        majorVersion: 27,
        minorVersion: 4,
        patchVersion: 1
    )))
    #expect(!RemoteViewCrashGuard.isRequired(on: OperatingSystemVersion(
        majorVersion: 28,
        minorVersion: 0,
        patchVersion: 0
    )))
}

@Test func remoteViewCrashGuardMatchesOnlyTheKnownViewBridgeAssertion() {
    let affected = NSException(
        name: .internalInconsistencyException,
        reason: "NSRemoteView containingWindowWillOrderOnScreen: stale containing window",
        userInfo: nil
    )
    let unrelated = NSException(
        name: .internalInconsistencyException,
        reason: "Unrelated AppKit invariant",
        userInfo: nil
    )

    #expect(CherryShouldSuppressRemoteViewException(affected))
    #expect(!CherryShouldSuppressRemoteViewException(unrelated))
}
