// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardPolicy",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "KeyboardPolicy", targets: ["KeyboardPolicy"])],
    targets: [
        .target(name: "KeyboardPolicy"),
        .testTarget(name: "KeyboardPolicyTests", dependencies: ["KeyboardPolicy"])
    ]
)
