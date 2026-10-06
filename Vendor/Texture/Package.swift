// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Texture",
    platforms: [.iOS(.v15), .macCatalyst(.v15)],
    products: [.library(name: "AsyncDisplayKit", targets: ["AsyncDisplayKit"])],
    targets: [
        .target(
            name: "AsyncDisplayKit",
            path: "Source",
            exclude: ["Info.plist", "AsyncDisplayKit.modulemap"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fno-exceptions"])],
            cxxSettings: [.unsafeFlags(["-fobjc-arc", "-fno-exceptions"])],
            linkerSettings: [.linkedLibrary("c++")]
        )
    ],
    cxxLanguageStandard: .cxx14
)
