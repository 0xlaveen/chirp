// swift-tools-version: 6.0
import PackageDescription

// The typing keyboard under Chirp's strip: a thin adapter over KeyboardKit's open-source core, so the keys look and
// behave like Apple's (layouts, callouts, shift/caps, space-drag, delete repeat). Chirp's own decisions stay in
// KeyboardPolicy. KeyboardKit 9.9.1 is the last MIT-licensed source release (10.0 and later are closed-source
// binaries); it is pinned exactly and linked into the keyboard extension only. See THIRD-PARTY-NOTICES.md here.
let package = Package(
    name: "KeyboardTyping",
    platforms: [.iOS(.v18)],
    products: [.library(name: "KeyboardTyping", targets: ["KeyboardTyping"])],
    dependencies: [
        .package(url: "https://github.com/KeyboardKit/KeyboardKit.git", exact: "9.9.1"),
        .package(path: "../Policy"),
    ],
    targets: [
        .target(name: "KeyboardTyping", dependencies: [
            .product(name: "KeyboardKit", package: "KeyboardKit"),
            .product(name: "KeyboardPolicy", package: "Policy"),
        ], resources: [.copy("Resources/KeyboardKit-LICENSE.txt")]),
    ]
)
