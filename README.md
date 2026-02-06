# DockPeek

**Windows-style window preview for macOS Dock.**

Dock 아이콘을 클릭하면 해당 앱의 모든 윈도우를 썸네일로 미리보기 할 수 있습니다.
원하는 창만 골라서 전환하세요.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Window Preview** — Dock 아이콘 클릭 시 해당 앱의 모든 윈도우 썸네일을 표시
- **Single Window Activation** — 썸네일을 클릭하면 해당 윈도우만 활성화 (전체화면 Space 전환 포함)
- **Live Preview on Hover** — 썸네일 위에 마우스를 올리면 실제 윈도우 위치에 미리보기 오버레이 표시
- **Close from Preview** — 썸네일의 X 버튼으로 프리뷰에서 바로 윈도우 닫기
- **Configurable** — 썸네일 크기 조절, 윈도우 제목 표시/숨김, 앱별 제외 설정

## Install

### Homebrew (Recommended)

```bash
brew tap ongjin/dockpeek
brew install --cask dockpeek
```

### Build from Source

```bash
git clone https://github.com/ongjin/dockpeek.git
cd dockpeek
make setup
```

> 처음 실행 시 Accessibility 권한을 부여해야 합니다.
> 이후 `make dev`로 빠르게 다시 빌드할 수 있습니다.

## Permissions

DockPeek은 두 가지 시스템 권한이 필요합니다:

| Permission | Purpose | Path |
|---|---|---|
| **Accessibility** | Dock 클릭 감지 및 윈도우 제어 | System Settings → Privacy & Security → Accessibility |
| **Screen Recording** | 윈도우 썸네일 캡처 | System Settings → Privacy & Security → Screen Recording |

## Usage

1. DockPeek을 실행하면 메뉴바에 아이콘이 나타납니다
2. 윈도우가 2개 이상 열린 앱의 Dock 아이콘을 클릭하세요
3. 프리뷰 패널에서 원하는 윈도우를 클릭하면 해당 윈도우만 활성화됩니다
4. 썸네일 위에 마우스를 올리면 실제 화면 위치에 미리보기가 표시됩니다
5. X 버튼으로 프리뷰에서 바로 윈도우를 닫을 수 있습니다

> 윈도우가 1개인 앱은 기존 Dock 동작 그대로 작동합니다.

## Settings

메뉴바 아이콘을 클릭하면 설정 패널이 열립니다:

- **Enable DockPeek** — 기능 켜기/끄기
- **Thumbnail size** — 미리보기 크기 조절 (120~360px)
- **Show window titles** — 썸네일 아래 제목 표시
- **Live preview on hover** — 호버 시 실제 윈도우 위치에 오버레이 표시
- **Excluded Apps** — 특정 앱 제외 (Bundle ID 기반)

## How It Works

1. `CGEventTap`으로 전역 클릭 이벤트를 감지합니다
2. 클릭 위치가 Dock 영역인지 빠르게 판별합니다
3. Accessibility API로 Dock 아이콘의 앱을 식별합니다
4. 해당 앱의 윈도우 목록을 조회하고 썸네일을 캡처합니다
5. 프리뷰 패널을 표시하고, 선택 시 SkyLight Private API로 해당 윈도우만 활성화합니다

## Project Structure

```
DockPeek/
├── App/
│   ├── DockPeekApp.swift          # @main entry point
│   ├── AppDelegate.swift          # Menubar, event handling, orchestration
│   └── AppState.swift             # User settings (ObservableObject)
├── Core/
│   ├── EventTapManager.swift      # CGEventTap for global click interception
│   ├── DockAXInspector.swift      # Accessibility hit-test for Dock icons
│   ├── WindowManager.swift        # Window enumeration, thumbnails, activation
│   └── AccessibilityManager.swift # Permission check & prompt
├── UI/
│   ├── PreviewPanel.swift         # Floating NSPanel (non-activating)
│   ├── PreviewContentView.swift   # SwiftUI thumbnail grid with close button
│   ├── HighlightOverlay.swift     # Live preview overlay at window position
│   ├── SettingsView.swift         # Menubar popover settings
│   └── OnboardingView.swift       # First-launch permission guide
├── Models/
│   ├── WindowInfo.swift           # Window metadata + thumbnail
│   └── DockApp.swift              # Dock icon → app mapping
└── Utilities/
    └── DebugLog.swift             # Debug-only logging
```

## Development

```bash
make setup      # 첫 설치: 빌드 → /Applications 복사 → 실행
make dev        # 개발 중: 바이너리만 교체 (권한 유지)
make kill       # 실행 중인 DockPeek 종료
make dist       # 배포용 zip 생성
make clean      # 빌드 산출물 정리
```

## Known Limitations

- macOS에는 공식 Dock 클릭 API가 없어 Accessibility 기반 hit-test를 사용합니다
- `CGWindowListCreateImage`는 macOS 14부터 deprecated 되었지만 현재까지 정상 작동합니다
- Dock 자동 숨김 사용 시 타이밍에 따라 감지가 안 될 수 있습니다

## License

MIT
