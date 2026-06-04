# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# CRITICAL RULES

- **Event tap 안전장치는 load-bearing — 절대 제거/약화 금지**: DockPeek 은 session-level `CGEventTap` (HID 레벨) 을 잡는다. 실행 중 손쉬운 사용(Accessibility) 권한이 회수되면 tap 이 모든 입력을 막아 **시스템 전체가 얼어붙을 수 있다**. 이를 막는 3중 방어가 있다 — ① `EventTapManager` 의 background `DispatchSource` watchdog (0.5s 주기, `AXIsProcessTrusted()` 확인 후 백그라운드 스레드에서 `emergencyInvalidateTap()`), ② C 콜백 `eventTapCallback` 진입부의 권한 재확인, ③ `AppDelegate` 의 30s `permissionMonitorTimer`. event tap 코드를 만질 때 이 경로들을 깨면 안 된다. 검증: 앱 실행 중 시스템 설정에서 권한을 끄고 입력이 안 먹는지 확인.
- **개발 중에는 `make dev` 로 hot-swap, 번들 재설치 금지**: 권한(손쉬운 사용/화면 기록)은 `/Applications/DockPeek.app` **번들에 귀속**된다. `make setup`·`make install` 처럼 번들을 통째로 갈아끼우면 권한이 날아가 매번 재허용해야 한다. `make dev` 는 같은 번들 안에서 바이너리만 교체(+ 재서명)하므로 권한이 유지된다. 첫 설치만 `make setup`, 이후 반복은 `make dev`.
- **버전 올릴 땐 두 곳을 같이**: `Makefile` 의 `VERSION` 과 `DockPeek/Info.plist` 의 `CFBundleShortVersionString` 가 일치해야 한다 (둘 다 현재 `1.5.20`). swiftc 빌드는 `Info.plist` 를 그대로 복사하므로 `project.yml` 의 `MARKETING_VERSION`(`1.0.0`) 은 stale 이며 안 쓰인다. 커밋 메시지 관례: `Bump version to X.Y.Z`.
- **커밋 메시지는 평범한 사람 스타일**: 이 레포 커밋엔 AI/Claude 언급·`Co-Authored-By`·생성 푸터 넣지 않는다.

# DockPeek

macOS Dock 아이콘을 클릭하면 그 앱의 열린 창들을 썸네일로 미리보기하고 원하는 창 하나만 골라 전면으로 가져오는 메뉴바 유틸리티 (Windows 식 Dock peek). 메뉴바 전용(`LSUIElement`) 앱이고, 배포는 GitHub Releases zip + Homebrew cask (`zerry-lab/tap`). **self-signed** (Apple Developer ID 미서명) 이라 Gatekeeper 경고와 일부 백신 false-positive 가 따라온다 — 이는 의도된 트레이드오프(아래 함정 참고).

## Tech Stack

- **언어/런타임**: Swift 5, target `arm64-apple-macos14.0` (Apple Silicon 전용, 최소 macOS 14.0)
- **UI**: AppKit + SwiftUI 하이브리드. 진입점은 SwiftUI `App` 라이프사이클이 아니라 **수동 `NSApplication` 구동** — `@main struct DockPeekMain` 이 `NSApplication.shared` 에 `AppDelegate` 를 직접 물린다 (`DockPeekApp.swift`). 패널/오버레이는 AppKit `NSPanel`/`NSWindow`, 그 안의 콘텐츠만 `NSHostingView` 로 SwiftUI.
- **빌드 시스템**: **SwiftPM 도 Xcode 프로젝트도 레포에 없다.** `Makefile` 이 `swiftc` 를 직접 호출해 `.app` 번들을 손으로 조립한다. `project.yml` 은 *선택적* XcodeGen 용(`make generate`/`open`) — Xcode 로 디버깅하고 싶을 때만.
- **권한**: 손쉬운 사용(Dock 클릭 감지 + 창 제어) + 화면 기록(썸네일 캡처). entitlements 파일은 빈 dict (샌드박스 미적용 — private API 와 system-wide tap 때문).
- **테스트/린트**: **없음.** 테스트 타깃도 lint 설정도 없다. 검증은 수동 (아래 함정의 권한 회수 테스트 등).
- **서명 ID**: `DockPeek Development` (로컬 self-signed). 배포 zip 도 같은 self-signed.

## Build & Commands

```bash
make setup     # 첫 설치: release 빌드 → /Applications 복사 → 실행 (권한 허용 프롬프트)
make dev       # 개발 루프: 바이너리만 in-place 교체 + 재서명 → 권한 유지한 채 재실행  ← 평소엔 이것
make kill      # 실행 중 인스턴스 종료 (pkill -x DockPeek)
make build     # Debug 번들 (-Onone -g)
make release   # Release 번들 (-O -whole-module-optimization)
make run       # build 후 실행
make dist      # release zip + sha256 (배포용)
make clean     # build/ DerivedData/ xcodeproj zip 삭제
make generate  # XcodeGen 으로 .xcodeproj 생성 (xcodegen 필요)
make open      # generate 후 Xcode 로 열기
```

- **새 `.swift` 파일 추가는 별도 등록 불필요**: `Makefile` 이 `find DockPeek -name '*.swift'` 로 전부 모아 컴파일한다. 파일을 `DockPeek/` 어디에 두든 자동 포함. (단 XcodeGen 으로 Xcode 빌드할 때만 `project.yml` 의 `sources` 규칙을 탄다.)
- **단위 테스트 실행 명령 없음** — 위에 적었듯 테스트 자체가 없다. 행동 변경은 `make dev` 후 실제 동작으로 확인.

## Architecture

핵심은 "전역 클릭을 가로채 Dock 클릭인지 판별하고, 해당 앱의 창들을 모아 미리보기를 띄우는" 파이프라인이다. 여러 파일에 걸쳐 있어 한 파일만 봐선 안 잡힌다.

**클릭 → 미리보기 흐름** (`AppDelegate.eventTapManager(_:didDetectClickAt:)` 가 오케스트레이터):

1. `EventTapManager` — `cgSessionEventTap` 으로 `leftMouseDown` 만 잡는다. C 콜백(`eventTapCallback`)이 권한·tap-disabled 를 점검한 뒤 delegate(`AppDelegate`)로 클릭 좌표 전달. delegate 가 `true` 를 반환하면 **이벤트를 삼켜** Dock 이 기본 동작(앱 전환)을 못 하게 한다.
2. `AppDelegate` — ① debounce(0.3s) → ② `isPointInDockArea()` **빠른 기하 판정**(AX 호출 없이 `screen.frame` vs `visibleFrame` gap 으로 Dock 영역인지) → ③ `DockAXInspector.appAtPoint()` AX hit-test → ④ `WindowManager.windowsForApp()` 로 창 개수 확인 → **창 ≥ 2 개면 클릭을 삼키고** `PreviewPanel` 표시, 1 개 이하면 통과시켜 Dock 기본 동작 유지.
3. `DockAXInspector` — `com.apple.dock` 의 `AXUIElement` 에 `AXUIElementCopyElementAtPosition` 으로 hit-test → 부모로 올라가며 `AXDockItem` 찾고 `AXApplicationDockItem` 인지 확인 → `kAXURLAttribute` 에서 bundle ID, 거기서 `NSRunningApplication` → pid 해석 (이름/AX 속성 fallback).
4. `WindowManager` — 시스템에서 가장 fragile 하고 핵심인 부분. (자세히는 아래 "Private/deprecated API")
5. `PreviewPanel` (non-activating `NSPanel`, `.borderless + .nonactivatingPanel`, level `.popUpMenu`) 가 `PreviewContentView`(SwiftUI 썸네일 그리드)를 호스팅. 키보드 네비(←→/Enter/Esc)는 panel 의 local event monitor 가 처리(`navState.selectedIndex`). 콜백 5종(`onSelect`/`onClose`/`onSnap`/`onDismiss`/`onHoverWindow`)으로 AppDelegate 와 통신.
6. `HighlightOverlay` — 썸네일 hover 시 **실제 창 위치**에 반투명 borderless 윈도(캡처 이미지 + 강조색 테두리)를 띄워 어느 창인지 시각적으로 알려준다.

**Hover 경로는 event tap 과 별개**: `AppDelegate` 가 adaptive `DispatchSourceTimer` 로 `NSEvent.mouseLocation` 을 폴링한다 — idle 4Hz, Dock 근처/패널 표시 중엔 15Hz 로 가속. 마우스가 안 움직이고 Dock-영역 상태도 그대로면 처리를 건너뛴다. hover 로도 클릭 없이 미리보기를 띄울 수 있다.

**좌표계 함정 (전반에 깔림)**: CG(좌상단 원점) vs Cocoa(좌하단 원점) 변환이 도처에 있는데, **항상 primary screen 높이**(`NSScreen.screens.first?.frame.height`)로 뒤집어야 한다 — CG 원점이 primary 의 좌상단이기 때문. screen 별 높이로 변환하면 멀티 디스플레이에서 깨진다. `AppDelegate`/`PreviewPanel`/`HighlightOverlay`/`WindowManager` 모두 이 규칙을 따른다.

**Private / deprecated API (fragile 코어 + 백신 false-positive 원인)** — `WindowManager` 상단에서 `dlopen`/`dlsym`/`@_silgen_name` 으로 런타임 로드:
- `_SLPSSetFrontProcessWithOptions` (SkyLight) — 단일 창 활성화. full-screen Space 전환까지 처리. **AltTab 과 동일 접근**. 활성화는 SkyLight → AX raise → `kAXMainAttribute`/`kAXFocusedWindowAttribute` 순.
- `_AXUIElementGetWindow` — `AXUIElement` ↔ `CGWindowID` 100% 정확 매칭. 창 활성화/닫기/스냅에서 대상 창을 특정할 때 씀.
- `GetProcessForPID` (`@_silgen_name`) — pid → `ProcessSerialNumber`.
- `CGWindowListCreateImage` — 썸네일/오버레이 캡처. **macOS 14 부터 deprecated** (아직 동작). 언젠가 ScreenCaptureKit 이관 필요.
- 창 닫기는 AX close 버튼 `kAXPressAction`, 스냅은 AX `kAXPosition`/`kAXSize` 직접 설정.

**캐싱 레이어 (성능 핵심)**: `WindowManager` 에 thumbnailCache(5s, 패널 열려있으면 10s)·windowListCache(0.5s)·axWindowIDsCache(1s), `AppDelegate` 에 cachedAXHitResult(100ms TTL)·cachedDockRect(화면/Dock 변경 시 갱신)·adaptive poll interval·"마우스 안 움직이면 skip". `windowOrderByBundle` 는 창 순서를 bundle ID 별로 UserDefaults 에 영속화해 미리보기 카드 순서를 안정화(앱 재시작 시 새 `CGWindowID` 라 자연 리셋).

**창 enumeration 의 핵심 트릭**: `CGWindowListCopyWindowInfo` (layer 0, alpha>0, 화면상) 결과를 **AX `kAXWindowsAttribute` (subrole `AXStandardWindow`) 와 교차 필터**한다 — Chrome 번역 바, 툴팁, 팝오버 같은 helper/overlay 창을 걸러내기 위함.

**Dock anchor 는 완전히 독립된 서브시스템** (`DockAnchorManager`, "Dock" 설정 탭): event tap 도 손쉬운 사용 권한도 안 쓴다. `com.apple.dock` 의 미문서화 키 `allow-display-switching=false` (커서가 다른 디스플레이로 넘어갈 때 Dock 따라가는 내부 경로를 막음) + `orientation` 을 `CFPreferences` 로 쓰고 `killall Dock` 으로 재적용. **"zero cursor interference" 가 이 기능의 설계 원칙** — 예전 CGEventTap/커서 기반 구현을 이 preference 토글 방식으로 갈아엎은 결과다.

**보조 유틸**: `UpdateChecker` (GitHub Releases API 폴링 → zip 다운로드 → 압축해제 → `codesign --verify` → `/Applications/DockPeek.app` 교체 in-app self-update), `DiagnosticChecker` (권한/event tap/Dock AX/화면 정보 진단 텍스트, 설정에서 복사), `L10n` (직접 만든 en/ko dict — `.strings`/`.lproj` 아님), `AppState` (`@AppStorage` 설정 보관).

## Conventions

- **빌드는 swiftc, SPM 아님**: 위 Build 섹션대로. 의존성 추가 불가 — 시스템 프레임워크(AppKit/SwiftUI/CoreGraphics/ApplicationServices/ServiceManagement)만.
- **로컬라이즈는 `L10n.swift` 의 dict 에 직접**: 새 문자열은 `en` 과 `ko` **두 dict 모두**에 키 추가하고 `static var` 접근자 정의. `L10n.current` 는 `appLanguage` UserDefaults 를 읽는다. 언어 전환은 `SettingsView` 가 `.id(langRefresh)` 의 UUID 를 갈아 SwiftUI 뷰를 강제 리프레시(재시작 불필요).
- **설정은 `AppState` 의 `@AppStorage`**: 새 설정은 여기에 추가. 제외 앱 목록은 콤마 구분 문자열을 `Set<String>` 으로 캐시(`cachedExcludedBundleIDs`).
- **디버그 로깅은 `dpLog()`**: DEBUG 빌드는 `print` + `os.log`, release 는 `os.log` 만. subsystem `com.dockpeek.app`.
- **메뉴바 앱 activation policy 토글**: 평소 `.accessory`(Dock 아이콘 없음), 설정/About 창 띄울 때만 `.regular` 로 올렸다가 창 닫히면 `restoreAccessoryPolicyIfNeeded()` 로 복귀.
- **이름 짓기**: 기존 유명 툴과 구현이 다르면 그 툴을 그대로 연상시키는 이름은 피한다(사용자 일반 선호).

## 주의할 함정 (이미 겪었거나 깨지기 쉬운 것)

- **권한 회수 시 입력 freeze**: CRITICAL RULES 의 event tap 안전장치 참고. 이게 깨지면 사용자 시스템이 멈춘다 — 가장 위험한 회귀.
- **`make dev` 안 쓰고 재설치하면 권한 날아감**: CRITICAL RULES 참고. 번들 교체 = 권한 재허용.
- **좌표 변환은 primary 높이로만**: Architecture 의 좌표계 함정. per-screen 높이로 바꾸면 멀티 모니터에서 미리보기/오버레이 위치가 틀어진다.
- **커서는 절대 움직이지 않는다 (load-bearing 원칙)**: "no cursor interference" 는 DockAnchor 뿐 아니라 앱 전체의 원칙이다 — `CGWarpMouseCursorPosition` 이나 보이는 synthetic 마우스 이벤트 금지. **현재 위반 1건**: "새 창을 primary 로" 기능이 아직 `warpCursorToPrimaryBriefly()` 에서 커서를 옮긴다 (`AppDelegate.swift:676`, 설정 토글 없는 always-on; event tap 에서 미실행 앱/창<2 일 때 호출). 이건 따라 할 패턴이 아니라 **걷어낼 wart** 다 — Dock launch display 는 커서가 아니라 `CGMainDisplayID` 로 잡아야 한다(경험적으로 검증됨; 커서 기반 secondary-display 고정은 동작하지 않아 폐기). primary-display 동작을 손댈 땐 커서 워프를 늘리지 말고 `CGMainDisplayID` 로 대체할 것.
- **`CGWindowListCreateImage` deprecated (macOS 14+)**: 지금은 동작하나 향후 OS 에서 끊기면 ScreenCaptureKit 이관 필요.
- **self-signed → 백신 false-positive & Gatekeeper**: system-wide `CGEventTap` + private SkyLight API + Apple Developer ID 미서명 조합이 휴리스틱 스캐너를 자극한다. **정상이며 의도된 것** — private API 를 들어내서 "고치려" 하지 말 것 (그게 곧 기능). 대응은 README 의 whitelist/build-from-source 안내.
- **Dock anchor 는 Dock 을 재시작(`killall Dock`)한다**: 토글/방향 변경 시 1 회. `start()` 는 값이 실제로 바뀔 때만 재시작하도록 idempotent.
- **README 의 구조 트리·설정 목록은 약간 stale**: `DockAnchorManager`/`UpdateChecker`/`DiagnosticChecker` 가 트리에 빠져 있고, README "Settings → Force new windows to primary display" 토글은 **현재 UI 에 없다**(코드상 always-on 워프 동작). 코드를 진실의 원천으로.
- **`AppState.isEnabled` 는 dead flag 로 보임**: 선언만 있고 참조처가 없다(`AppState.swift:5`). 건드릴 일 생기면 확인 후 정리.
