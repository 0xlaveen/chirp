// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChirpMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ChirpMac", targets: ["ChirpMac"]),
        .library(name: "ChirpCore", targets: ["ChirpCore"]),
    ],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .target(name: "ChirpCore"),
        .executableTarget(
            name: "ChirpMac",
            dependencies: [
                "ChirpCore",
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ]
        ),
        .testTarget(name: "ChirpCoreTests", dependencies: ["ChirpCore"]),
    ],
    swiftLanguageModes: [.v6]
)
