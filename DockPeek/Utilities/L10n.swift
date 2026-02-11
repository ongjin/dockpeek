import Foundation

enum Language: String, CaseIterable {
    case en, ko

    var displayName: String {
        switch self {
        case .en: return "English"
        case .ko: return "한국어"
        }
    }
}

struct L10n {
    static var current: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }

    // MARK: - Menu

    static var settings: String { s("settings") }
    static var aboutDockPeek: String { s("aboutDockPeek") }
    static var quitDockPeek: String { s("quitDockPeek") }

    // MARK: - Update

    static var checkForUpdates: String { s("checkForUpdates") }
    static var updateAvailable: String { s("updateAvailable") }
    static var updateMessage: String { s("updateMessage") }
    static var autoUpdate: String { s("autoUpdate") }
    static var autoUpdateHint: String { s("autoUpdateHint") }
    static var download: String { s("download") }
    static var later: String { s("later") }
    static var brewHint: String { s("brewHint") }
    static var upToDate: String { s("upToDate") }
    static var upToDateMessage: String { s("upToDateMessage") }

    // MARK: - Tabs

    static var general: String { s("general") }
    static var behavior: String { s("behavior") }
    static var appearance: String { s("appearance") }
    static var update: String { s("update") }
    static var about: String { s("about") }

    // MARK: - General Tab

    static var enableDockPeek: String { s("enableDockPeek") }
    static var launchAtLogin: String { s("launchAtLogin") }
    static var forceNewWindowsToPrimary: String { s("forceNewWindowsToPrimary") }
    static var previewOnHover: String { s("previewOnHover") }
    static var hoverDelay: String { s("hoverDelay") }
    static var language: String { s("language") }
    static var permissions: String { s("permissions") }
    static var accessibilityGranted: String { s("accessibilityGranted") }
    static var accessibilityRequired: String { s("accessibilityRequired") }
    static var grantPermission: String { s("grantPermission") }

    // MARK: - Appearance Tab

    static var thumbnailSize: String { s("thumbnailSize") }
    static var showWindowTitles: String { s("showWindowTitles") }
    static var livePreviewOnHover: String { s("livePreviewOnHover") }

    // MARK: - About Tab

    static var version: String { s("version") }
    static var buyMeACoffee: String { s("buyMeACoffee") }
    static var buyMeACoffeeDesc: String { s("buyMeACoffeeDesc") }
    static var gitHub: String { s("gitHub") }
    static var excludedApps: String { s("excludedApps") }
    static var addPlaceholder: String { s("addPlaceholder") }
    static var add: String { s("add") }
    static var quit: String { s("quit") }
    static var minimized: String { s("minimized") }

    // MARK: - Update Tab

    static var autoUpdateToggle: String { s("autoUpdate_toggle") }
    static var updateInterval: String { s("updateInterval") }
    static var daily: String { s("daily") }
    static var weekly: String { s("weekly") }
    static var manual: String { s("manual") }
    static var lastChecked: String { s("lastChecked") }
    static var never: String { s("never") }
    static var checkNow: String { s("checkNow") }
    static var releaseNotes: String { s("releaseNotes") }
    static var newVersionAvailable: String { s("newVersionAvailable") }
    static var currentVersion: String { s("currentVersion") }
    static var updateNow: String { s("updateNow") }
    static var upgrading: String { s("upgrading") }
    static var upgradeComplete: String { s("upgradeComplete") }
    static var upgradeFailed: String { s("upgradeFailed") }
    static var restart: String { s("restart") }
    static var retry: String { s("retry") }

    // MARK: - Lookup

    private static func s(_ key: String) -> String {
        switch current {
        case .en: return en[key] ?? key
        case .ko: return ko[key] ?? key
        }
    }

    // MARK: - English

    private static let en: [String: String] = [
        "settings": "Settings...",
        "aboutDockPeek": "About DockPeek",
        "quitDockPeek": "Quit DockPeek",

        "general": "General",
        "behavior": "Behavior",
        "appearance": "Appearance",
        "update": "Update",
        "about": "About",

        "enableDockPeek": "Enable DockPeek",
        "launchAtLogin": "Launch at login",
        "forceNewWindowsToPrimary": "Force new windows to primary display",
        "previewOnHover": "Preview on mouse hover",
        "hoverDelay": "Hover delay",
        "language": "Language",
        "permissions": "Permissions",
        "accessibilityGranted": "Accessibility: Granted",
        "accessibilityRequired": "Accessibility: Required",
        "grantPermission": "Grant",

        "thumbnailSize": "Thumbnail size",
        "showWindowTitles": "Show window titles",
        "livePreviewOnHover": "Live preview on hover",

        "version": "Version",
        "buyMeACoffee": "Buy me a coffee",
        "buyMeACoffeeDesc": "If you enjoy DockPeek, consider supporting development!",
        "gitHub": "GitHub",
        "excludedApps": "Excluded Apps",
        "addPlaceholder": "com.example.app",
        "add": "Add",
        "quit": "Quit DockPeek",
        "minimized": "Minimized",

        "checkForUpdates": "Check for Updates...",
        "updateAvailable": "Update Available",
        "updateMessage": "DockPeek %@ is available. You are currently on %@.",
        "autoUpdate": "Update Now",
        "autoUpdateHint": "Homebrew detected. Click \"Update Now\" to upgrade automatically.",
        "download": "Download",
        "later": "Later",
        "brewHint": "Homebrew: brew update && brew upgrade --cask dockpeek",
        "upToDate": "Up to Date",
        "upToDateMessage": "You're running the latest version of DockPeek.",

        "autoUpdate_toggle": "Check for updates automatically",
        "updateInterval": "Check interval",
        "daily": "Daily",
        "weekly": "Weekly",
        "manual": "Manual",
        "lastChecked": "Last checked",
        "never": "Never",
        "checkNow": "Check Now",
        "releaseNotes": "Release Notes",
        "newVersionAvailable": "New version available: %@",
        "currentVersion": "Current version",
        "updateNow": "Update Now",
        "upgrading": "Updating via Homebrew...",
        "upgradeComplete": "Update complete!",
        "upgradeFailed": "Update failed",
        "restart": "Restart",
        "retry": "Retry",
    ]

    // MARK: - Korean

    private static let ko: [String: String] = [
        "settings": "설정...",
        "aboutDockPeek": "DockPeek에 대하여",
        "quitDockPeek": "DockPeek 종료",

        "general": "일반",
        "behavior": "동작",
        "appearance": "모양",
        "update": "업데이트",
        "about": "정보",

        "enableDockPeek": "DockPeek 활성화",
        "launchAtLogin": "로그인 시 자동 실행",
        "forceNewWindowsToPrimary": "새 창을 메인 디스플레이에 표시",
        "previewOnHover": "마우스 호버시 프리뷰",
        "hoverDelay": "호버 지연 시간",
        "language": "언어",
        "permissions": "권한",
        "accessibilityGranted": "손쉬운 사용: 허용됨",
        "accessibilityRequired": "손쉬운 사용: 필요",
        "grantPermission": "허용",

        "thumbnailSize": "미리보기 크기",
        "showWindowTitles": "창 제목 표시",
        "livePreviewOnHover": "마우스 호버 시 실시간 미리보기",

        "version": "버전",
        "buyMeACoffee": "커피 한 잔 사주기",
        "buyMeACoffeeDesc": "DockPeek이 마음에 드신다면 개발을 응원해 주세요!",
        "gitHub": "GitHub",
        "excludedApps": "제외된 앱",
        "addPlaceholder": "com.example.app",
        "add": "추가",
        "quit": "DockPeek 종료",
        "minimized": "최소화됨",

        "checkForUpdates": "업데이트 확인...",
        "updateAvailable": "업데이트 있음",
        "updateMessage": "DockPeek %@ 버전을 사용할 수 있습니다. 현재 버전: %@",
        "autoUpdate": "지금 업데이트",
        "autoUpdateHint": "Homebrew가 감지되었습니다. \"지금 업데이트\"를 누르면 자동으로 업그레이드됩니다.",
        "download": "다운로드",
        "later": "나중에",
        "brewHint": "Homebrew: brew update && brew upgrade --cask dockpeek",
        "upToDate": "최신 버전",
        "upToDateMessage": "현재 최신 버전의 DockPeek을 사용 중입니다.",

        "autoUpdate_toggle": "자동으로 업데이트 확인",
        "updateInterval": "확인 주기",
        "daily": "매일",
        "weekly": "매주",
        "manual": "수동",
        "lastChecked": "마지막 확인",
        "never": "확인한 적 없음",
        "checkNow": "지금 확인",
        "releaseNotes": "릴리스 노트",
        "newVersionAvailable": "새 버전 사용 가능: %@",
        "currentVersion": "현재 버전",
        "updateNow": "지금 업데이트",
        "upgrading": "Homebrew로 업데이트 중...",
        "upgradeComplete": "업데이트 완료!",
        "upgradeFailed": "업데이트 실패",
        "restart": "재시작",
        "retry": "재시도",
    ]
}
