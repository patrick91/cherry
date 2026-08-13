import Foundation
import Testing
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
