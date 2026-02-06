import SwiftUI
import Combine

final class AppState: ObservableObject {
    @AppStorage("isEnabled") var isEnabled = true
    @AppStorage("thumbnailSize") var thumbnailSize: Double = 200
    @AppStorage("showWindowTitles") var showWindowTitles = true
    @AppStorage("livePreviewOnHover") var livePreviewOnHover = true
    @AppStorage("excludedBundleIDs") var excludedBundleIDsRaw = ""

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
