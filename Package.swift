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
        .executable(name: "CherryMCP", targets: ["CherryMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.1776871800"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
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
            ]
        ),
        .executableTarget(
            name: "CherryMCP",
            dependencies: [
                "CherryControl",
                .product(name: "MCP", package: "swift-sdk"),
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
