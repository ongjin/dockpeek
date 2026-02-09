import Foundation

final class UpdateChecker {

    static let shared = UpdateChecker()

    private(set) var updateAvailable = false
    private(set) var latestVersion = ""
    private(set) var releaseURL = ""

    private let repoAPI = "https://api.github.com/repos/ongjin/dockpeek/releases/latest"
    private let lastCheckKey = "lastUpdateCheckTime"
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours

    private init() {}

    // MARK: - Public

    /// Check for updates. `force` bypasses the 24-hour cooldown.
    func check(force: Bool = false, completion: @escaping (Bool) -> Void) {
        if !force, let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval {
            completion(updateAvailable)
            return
        }

        guard let url = URL(string: repoAPI) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }

                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

                let available = Self.compareVersions(remote, isGreaterThan: local)

                DispatchQueue.main.async {
                    self.latestVersion = remote
                    self.releaseURL = htmlURL
                    self.updateAvailable = available
                    UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                    completion(available)
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }

    // MARK: - Semantic Version Comparison

    /// Returns true if `a` is strictly greater than `b` using semantic versioning.
    static func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)

        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
