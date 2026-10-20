// swift-tools-version: 6.2
import PackageDescription

// Live Notes speaker-label bench (docs/bench.md, Speaker labels). Links the app's own ChirpCore and ChirpSpeakers, so
// it measures the shipped code: the real NotesRecorder, segmenter and attribution against a local chirp-server.
let package = Package(
    name: "SpeakerBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "SpeakerBench", dependencies: [
            .product(name: "ChirpCore", package: "mac"),
            .product(name: "ChirpSpeakers", package: "mac"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
