// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChirpMac",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "ChirpMac", targets: ["ChirpMac"]),
        .library(name: "ChirpCore", targets: ["ChirpCore"]),
        .library(name: "ChirpSpeakers", targets: ["ChirpSpeakers"]),
    ],
    dependencies: [
        // Live Notes speaker labels only (on-device Sortformer diarization, Apache-2.0). Pinned to the version the
        // bench measured; no traits, so FluidAudio's prebuilt text-normalization binary is not linked.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "ChirpCore"),
        .target(name: "ChirpUI", dependencies: ["ChirpCore"]),
        .target(name: "ChirpSpeakers", dependencies: ["ChirpCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "ChirpMac", dependencies: ["ChirpCore", "ChirpUI", "ChirpSpeakers"]),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore", "ChirpUI"]),
    ],
    swiftLanguageModes: [.v6]
)
