// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CherrySidebarPlayground",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SidebarPlayground", targets: ["SidebarPlayground"])],
    targets: [
        .executableTarget(name: "SidebarPlayground", resources: [.copy("Resources")]),
        .testTarget(name: "SidebarPlaygroundTests", dependencies: ["SidebarPlayground"])
    ]
)
