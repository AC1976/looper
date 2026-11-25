// swift-tools-version: 6.0
// Builds with Swift 6.0+ toolchains (developed and tested on Swift 6.4.3).
import PackageDescription

let package = Package(
    name: "LoopRouter",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "LoopRouter", targets: ["LoopRouter"]),
        .executable(name: "loop-router", targets: ["LoopRouterRunner"]),
        .executable(name: "pack-network", targets: ["PackNetwork"]),
    ],
    targets: [
        .target(name: "LoopRouter"),
        .executableTarget(name: "LoopRouterRunner", dependencies: ["LoopRouter"]),
        .executableTarget(name: "PackNetwork", dependencies: ["LoopRouter"]),
        .testTarget(name: "LoopRouterTests", dependencies: ["LoopRouter"]),
    ],
    swiftLanguageModes: [.v6]
)
