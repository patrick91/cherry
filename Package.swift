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
        .executable(name: "CherryMCP", targets: ["CherryMCPStdio"]),
    ],
    dependencies: [
        .package(path: "ThirdParty/libghostty-spm"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "CherryControl"
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
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
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
                "CherryMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
