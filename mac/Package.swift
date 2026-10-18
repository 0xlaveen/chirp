// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChirpMac",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "ChirpMac", targets: ["ChirpMac"]),
        .library(name: "ChirpCore", targets: ["ChirpCore"]),
    ],
    targets: [
        .target(name: "ChirpCore"),
        .target(name: "ChirpUI", dependencies: ["ChirpCore"]),
        .executableTarget(name: "ChirpMac", dependencies: ["ChirpCore", "ChirpUI"]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore", "ChirpUI"]),
    ],
    swiftLanguageModes: [.v6]
)
