import AppKit
import ApplicationServices

final class AccessibilityManager {
    static let shared = AccessibilityManager()

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systemsettings:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for urlString in candidates {
            if let url = URL(string: urlString),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }

}
