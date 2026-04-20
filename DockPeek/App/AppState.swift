import SwiftUI
import Combine

final class AppState: ObservableObject {
    @AppStorage("isEnabled") var isEnabled = true
    @AppStorage("thumbnailSize") var thumbnailSize: Double = 200
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("anchorDockToPrimary") var anchorDockToPrimary = false
    @AppStorage("dockAnchorOrientation") var dockAnchorOrientation: String = "bottom"
    @AppStorage("excludedBundleIDs") var excludedBundleIDsRaw = "" {
        didSet { cachedExcludedBundleIDs = Self.parseExcludedIDs(excludedBundleIDsRaw) }
    }
    @AppStorage("appLanguage") var language: String = "en"
    @AppStorage("autoUpdateEnabled") var autoUpdateEnabled = true
    @AppStorage("updateCheckInterval") var updateCheckInterval = "daily" // "daily", "weekly", "manual"

    private lazy var cachedExcludedBundleIDs: Set<String> = Self.parseExcludedIDs(excludedBundleIDsRaw)

    private static func parseExcludedIDs(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    var excludedBundleIDs: Set<String> {
        get { cachedExcludedBundleIDs }
        set {
            excludedBundleIDsRaw = newValue.sorted().joined(separator: ", ")
        }
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return cachedExcludedBundleIDs.contains(bundleID)
    }
}
