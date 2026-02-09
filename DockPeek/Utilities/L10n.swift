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
    static var appearance: String { s("appearance") }
    static var about: String { s("about") }

    // MARK: - General Tab

    static var enableDockPeek: String { s("enableDockPeek") }
    static var launchAtLogin: String { s("launchAtLogin") }
    static var forceNewWindowsToPrimary: String { s("forceNewWindowsToPrimary") }
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

    // MARK: - Lookup

    private static func s(_ key: String) -> String {
        let dict: [String: String]
        switch current {
        case .en: dict = en
        case .ko: dict = ko
        }
        return dict[key] ?? key
    }

    // MARK: - English

    private static let en: [String: String] = [
        "settings": "Settings...",
        "aboutDockPeek": "About DockPeek",
        "quitDockPeek": "Quit DockPeek",

        "general": "General",
        "appearance": "Appearance",
        "about": "About",

        "enableDockPeek": "Enable DockPeek",
        "launchAtLogin": "Launch at login",
        "forceNewWindowsToPrimary": "Force new windows to primary display",
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
    ]

    // MARK: - Korean

    private static let ko: [String: String] = [
        "settings": "설정...",
        "aboutDockPeek": "DockPeek에 대하여",
        "quitDockPeek": "DockPeek 종료",

        "general": "일반",
        "appearance": "모양",
        "about": "정보",

        "enableDockPeek": "DockPeek 활성화",
        "launchAtLogin": "로그인 시 자동 실행",
        "forceNewWindowsToPrimary": "새 창을 메인 디스플레이에 표시",
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
    ]
}
