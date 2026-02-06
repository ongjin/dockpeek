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
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
