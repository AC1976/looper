// swift-tools-version: 6.0
// Shared app layer for the Looper iOS and watchOS apps: state, preferences and planning,
// no views. Depends on LoopRouter (the package one folder up); LoopRouter never depends on this.
import PackageDescription

let package = Package(
    name: "LooperKit",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "LooperKit", targets: ["LooperKit"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .target(name: "LooperKit", dependencies: [.product(name: "LoopRouter", package: "looper")]),
        .testTarget(name: "LooperKitTests", dependencies: ["LooperKit"]),
    ],
    swiftLanguageModes: [.v6]
)
