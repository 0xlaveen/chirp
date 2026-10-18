// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ChirpIOSCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "ChirpIOSCore", targets: ["ChirpIOSCore"])],
    dependencies: [.package(path: "../../mac")],
    targets: [
        .target(name: "ChirpIOSCore", dependencies: [.product(name: "ChirpCore", package: "mac")]),
        .testTarget(name: "ChirpIOSCoreTests", dependencies: ["ChirpIOSCore"]),
    ],
    swiftLanguageModes: [.v6]
)
