import AppKit
import Combine

enum UpgradeState: Equatable {
    case idle
    case downloading(Double)   // progress 0.0–1.0
    case completed
    case failed(String)
}

final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion = ""
    @Published private(set) var releaseURL = ""
    @Published private(set) var releaseBody = ""
    @Published private(set) var upgradeState: UpgradeState = .idle

    private let repoAPI = "https://api.github.com/repos/ongjin/dockpeek/releases/latest"
    let lastCheckKey = "lastUpdateCheckTime"

    var lastCheckDate: Date? {
        UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    private init() {}

    // MARK: - Interval

    static func intervalForSetting(_ setting: String) -> TimeInterval? {
        switch setting {
        case "daily":  return 24 * 60 * 60
        case "weekly": return 7 * 24 * 60 * 60
        default:       return nil
        }
    }

    // MARK: - Check for Updates

    func check(force: Bool = false, intervalSetting: String = "daily", completion: @escaping (Bool) -> Void) {
        if !force, let interval = Self.intervalForSetting(intervalSetting),
           let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < interval {
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
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let remote = release.tagName.trimmingCharacters(in: .init(charactersIn: "vV"))
                let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                let available = Self.compareVersions(remote, isGreaterThan: local)

                DispatchQueue.main.async {
                    self.latestVersion = remote
                    self.releaseURL = release.htmlURL
                    self.releaseBody = release.body ?? ""
                    self.updateAvailable = available
                    self.downloadURL = release.assets.first { $0.name.hasSuffix(".zip") }?.browserDownloadURL
                    UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                    completion(available)
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }

    // MARK: - Download and Install

    private var downloadURL: String?

    /// Download the latest release ZIP, extract, verify, and replace the running app.
    func downloadAndInstall() {
        guard case .idle = upgradeState, let urlString = downloadURL,
              let url = URL(string: urlString) else { return }

        upgradeState = .downloading(0)

        URLSession.shared.downloadTask(with: url) { [weak self] tempZip, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                guard let tempZip, error == nil else {
                    self.upgradeState = .failed(error?.localizedDescription ?? "Download failed")
                    return
                }

                self.upgradeState = .downloading(0.5)
                self.installFromZip(tempZip)
            }
        }.resume()
    }

    private func installFromZip(_ zipURL: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("DockPeekUpdate-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Unzip
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", zipURL.path, "-d", tempDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()

            guard unzip.terminationStatus == 0 else {
                try? fm.removeItem(at: tempDir)
                upgradeState = .failed("Failed to extract update")
                return
            }

            upgradeState = .downloading(0.7)

            // Find .app bundle
            let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                try? fm.removeItem(at: tempDir)
                upgradeState = .failed("No app found in archive")
                return
            }

            // Verify code signature
            guard verifyCodeSignature(of: appBundle) else {
                try? fm.removeItem(at: tempDir)
                upgradeState = .failed("Code signature verification failed")
                return
            }

            upgradeState = .downloading(0.85)

            // Replace app: backup old → move new → cleanup
            let appPath = URL(fileURLWithPath: "/Applications/DockPeek.app")
            let backupDir = fm.temporaryDirectory.appendingPathComponent("DockPeek-backup-\(UUID().uuidString)")

            var hasBackup = false
            if fm.fileExists(atPath: appPath.path) {
                try fm.moveItem(at: appPath, to: backupDir)
                hasBackup = true
            }

            do {
                try fm.moveItem(at: appBundle, to: appPath)
            } catch {
                if hasBackup { try? fm.moveItem(at: backupDir, to: appPath) }
                try? fm.removeItem(at: tempDir)
                upgradeState = .failed("Failed to install: \(error.localizedDescription)")
                return
            }

            if hasBackup { try? fm.removeItem(at: backupDir) }
            try? fm.removeItem(at: tempDir)

            upgradeState = .completed
            updateAvailable = false

        } catch {
            try? fm.removeItem(at: tempDir)
            upgradeState = .failed(error.localizedDescription)
        }
    }

    private func verifyCodeSignature(of appURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Relaunch

    func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open /Applications/DockPeek.app"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    func resetUpgradeState() {
        upgradeState = .idle
    }

    // MARK: - Semantic Version Comparison

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

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
