// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Cherry",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Cherry", targets: ["Cherry"]),
    ],
    dependencies: [
        .package(path: "ThirdParty/libghostty-spm"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "CherryControl"
        ),
        .executableTarget(
            name: "Cherry",
            dependencies: [
                "CherryControl",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CherryTests",
            dependencies: [
                "Cherry",
                "CherryControl",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
