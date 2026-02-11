import AppKit
import Combine

enum UpgradeState: Equatable {
    case idle
    case updating
    case completed
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
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

    /// Resolved Homebrew binary path, or nil if not installed.
    lazy var brewPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/brew",   // Apple Silicon
            "/usr/local/bin/brew",      // Intel
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    var isBrewInstalled: Bool { brewPath != nil }

    private init() {}

    // MARK: - Interval

    /// Returns the check interval in seconds based on the user's setting.
    /// Returns nil for "manual" (no automatic checking).
    static func intervalForSetting(_ setting: String) -> TimeInterval? {
        switch setting {
        case "daily":  return 24 * 60 * 60
        case "weekly": return 7 * 24 * 60 * 60
        default:       return nil // manual
        }
    }

    // MARK: - Public

    /// Check for updates. `force` bypasses the cooldown.
    /// `intervalSetting` should be "daily", "weekly", or "manual".
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
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }

                let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

                let available = Self.compareVersions(remote, isGreaterThan: local)

                let body = json["body"] as? String ?? ""

                DispatchQueue.main.async {
                    self.latestVersion = remote
                    self.releaseURL = htmlURL
                    self.releaseBody = body
                    self.updateAvailable = available
                    UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                    completion(available)
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }.resume()
    }

    // MARK: - Brew Upgrade

    /// Runs Homebrew upgrade in the background, reporting progress via `upgradeState`.
    /// Does NOT terminate the app -- the UI shows a "Restart" button on completion.
    func performBrewUpgrade() {
        guard let brew = brewPath else {
            upgradeState = .failed("Homebrew not found")
            return
        }
        guard upgradeState != .updating else { return }

        upgradeState = .updating

        let script = """
        \(brew) update && \(brew) upgrade --cask dockpeek
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    self.upgradeState = .completed
                    self.updateAvailable = false
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let lastLine = output.split(separator: "\n").last.map(String.init) ?? "Exit code \(proc.terminationStatus)"
                    self.upgradeState = .failed(lastLine)
                }
            }
        }

        do {
            try process.run()
        } catch {
            upgradeState = .failed(error.localizedDescription)
        }
    }

    /// Relaunch the app after a successful upgrade.
    func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open -a DockPeek"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Reset upgrade state back to idle.
    func resetUpgradeState() {
        upgradeState = .idle
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
