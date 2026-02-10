import AppKit
import ApplicationServices

final class AccessibilityManager {
    static let shared = AccessibilityManager()

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        let urlString = "x-apple.systemsettings:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        let urlString = "x-apple.systemsettings:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
