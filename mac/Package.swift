// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChirpMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ChirpMac", targets: ["ChirpMac"]),
        .library(name: "ChirpCore", targets: ["ChirpCore"]),
    ],
    targets: [
        .target(name: "ChirpCore"),
        .executableTarget(name: "ChirpMac", dependencies: ["ChirpCore"]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore"]),
    ],
    swiftLanguageModes: [.v6]
)
