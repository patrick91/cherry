// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Cherry",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Cherry", targets: ["Cherry"]),
        .executable(name: "CherryMCP", targets: ["CherryMCPStdio"]),
    ],
    dependencies: [
        .package(path: "ThirdParty/libghostty-spm"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // Exact: the framework, its tools (sign_update), the launchd job labels Cherry removes and
        // the delegate behaviour Cherry relies on (docs/releasing.md) move together; upgrade deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CherryControl"
        ),
        .target(
            name: "CherryCrashGuard",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "CherryMCP",
            dependencies: [
                "CherryControl",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "CherryMCPStdio",
            dependencies: [
                "CherryControl",
                "CherryMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "Cherry",
            dependencies: [
                "CherryControl",
                "CherryCrashGuard",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources")
            ],
            // Sparkle.framework is embedded in Contents/Frameworks (Scripts/install-local-app,
            // script/build_and_run.sh). SwiftPM's own @loader_path keeps `swift run` and tests working.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "CherryTests",
            dependencies: [
                "Cherry",
                "CherryControl",
                "CherryMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
