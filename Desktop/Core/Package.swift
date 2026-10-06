// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MidokuCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MidokuCore", targets: ["MidokuCore"])],
    targets: [
        .target(name: "MidokuCore"),
        .testTarget(name: "MidokuCoreTests", dependencies: ["MidokuCore"])
    ]
)
