// swift-tools-version: 6.0
// THROWAWAY notch spike (Chirp v2 PR 0). Never merged to main. Delete the whole spikes/notch directory when done.
import PackageDescription

let package = Package(
    name: "NotchSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchSpike", path: "Sources/NotchSpike")
    ]
)
