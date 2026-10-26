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
    dependencies: [
        // Apple's SSH implementation: Ed25519 user keys, curve25519 and
        // ECDH key exchange, AES-GCM, exec and PTY channels, window change,
        // host key validation. Citadel would add a convenience layer, but
        // its current release pulls a personal fork of swift-nio-ssh.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "CherryMobileKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "CherryMobileKitTests", dependencies: ["CherryMobileKit"]),
    ],
    swiftLanguageModes: [.v6]
)
