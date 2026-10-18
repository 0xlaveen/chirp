#!/bin/bash
# Optional CLT compiler aid. Never an iOS SDK, simulator build, or runtime test.
# ActivityKit is unavailable on Catalyst; only its app facade is substituted in a TEMP directory.
# Shipping iOS sources are unmodified. SwiftUI view macro expansion remains an Xcode-only check.
set -euo pipefail
cd "$(dirname "$0")/../.."
checkdir=$(mktemp -d /tmp/chirp-app-types.XXXXXX)
trap 'rm -rf "$checkdir"' EXIT
sdk=$(xcrun --show-sdk-path)
flags=(-swift-version 6 -target arm64-apple-ios18.0-macabi -sdk "$sdk" -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$checkdir")
echo 'Compiler-only Catalyst aid. Does not validate iOS SDK, signing, Simulator, SwiftUI views, App Intents, or ActivityKit.'
mkdir "$checkdir/CDarwinNotify"
printf 'module CDarwinNotify { header "%s/ios/Shared/Sources/CDarwinNotify/include/CDarwinNotify.h" export * }\n' "$PWD" >"$checkdir/CDarwinNotify/module.modulemap"
swiftc "${flags[@]}" -emit-module -module-name ChirpCore -emit-module-path "$checkdir/ChirpCore.swiftmodule" mac/Sources/ChirpCore/*.swift mac/Sources/ChirpCore/Insertion/*.swift
swiftc "${flags[@]}" -I "$checkdir/CDarwinNotify" -emit-module -module-name ChirpIOSCore -emit-module-path "$checkdir/ChirpIOSCore.swiftmodule" ios/Shared/Sources/ChirpIOSCore/*.swift
cat >"$checkdir/ActivityFacade.swift" <<'SWIFT'
import Foundation
// Compiler-only signature substitute. This file is never included in the iOS project.
@MainActor enum ChirpLiveActivity {
    static func begin(debugRetention: Bool) throws {}
    static var isActive: Bool { true }
    static func update(phase: String, debugRetention: Bool) async {}
    static func end() async {}
}
SWIFT
swiftc "${flags[@]}" -I "$checkdir/CDarwinNotify" -D DEBUG -D CHIRP_APP -enable-testing \
    -emit-module -module-name ChirpIOS -emit-module-path "$checkdir/ChirpIOS.swiftmodule" \
    ios/App/SessionCoordinator.swift ios/App/MicrophoneCapture.swift ios/App/PairingScanner.swift \
    ios/App/DebugFixtures.swift ios/App/PrivacyController.swift "$checkdir/ActivityFacade.swift"
echo 'PASS: Catalyst typecheck: SessionCoordinator, MicrophoneCapture, PairingScanner, DebugFixtures, PrivacyController; temporary Activity facade substituted.'
echo 'Excluded: ChirpApp/SettingsViews (missing CLT SwiftUIMacros), actual ActivityKit/Intents/Widgets and all simulator runtime behavior.'
