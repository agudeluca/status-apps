// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatusApps",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "StatusAppsCore"),
        .executableTarget(name: "StatusApps", dependencies: ["StatusAppsCore"]),
        .testTarget(name: "StatusAppsCoreTests", dependencies: ["StatusAppsCore"]),
    ]
)
