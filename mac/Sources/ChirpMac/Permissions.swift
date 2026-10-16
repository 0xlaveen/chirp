import AVFoundation
import AppKit
import ApplicationServices

enum Permissions {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var microphoneGranted: Bool { microphone == .authorized }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Prompts the first time; afterwards only reports the current state.
    static func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Shows the system Accessibility prompt (which links to System Settings).
    static func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
