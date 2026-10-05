// swift-tools-version: 6.0
// The iOS app's UI-free layer: reaching a Mac over SSH, its host's
// sessions and screens, and its agents' state. Built for iOS (the app) and
// macOS (its tests). See docs/specs/ios-app.md.

import PackageDescription

let package = Package(
    name: "CherryMobileKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CherryMobileKit", targets: ["CherryMobileKit"]),
    ],
    targets: [
        .target(name: "CherryMobileKit"),
        .testTarget(name: "CherryMobileKitTests", dependencies: ["CherryMobileKit"]),
    ],
    swiftLanguageModes: [.v6]
)
