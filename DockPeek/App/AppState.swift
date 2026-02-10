import SwiftUI
import Combine
import ServiceManagement

final class AppState: ObservableObject {
    @AppStorage("isEnabled") var isEnabled = true
    @AppStorage("thumbnailSize") var thumbnailSize: Double = 200
    @AppStorage("showWindowTitles") var showWindowTitles = true
    @AppStorage("livePreviewOnHover") var livePreviewOnHover = true
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("forceNewWindowsToPrimary") var forceNewWindowsToPrimary = false
    @AppStorage("previewOnHover") var previewOnHover = false
    @AppStorage("hoverDelay") var hoverDelay: Double = 0.5
    @AppStorage("excludedBundleIDs") var excludedBundleIDsRaw = ""
    @AppStorage("appLanguage") var language: String = "en"

    var excludedBundleIDs: Set<String> {
        get {
            Set(excludedBundleIDsRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        set {
            excludedBundleIDsRaw = newValue.sorted().joined(separator: ", ")
        }
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }
}
