# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

위 본문에는 매 세션 필요한 공통 컨텍스트만 둔다. 특정 작업에 들어갈 땐 아래 **추가 문서(docs/claude/)** 를 직접 읽어와서 참고할 것.

# CRITICAL RULES

- **Event tap 안전장치는 load-bearing — 절대 제거/약화 금지**: DockPeek 은 session-level `CGEventTap`(HID 레벨)을 잡는다. 실행 중 손쉬운 사용 권한이 회수되면 tap 이 모든 입력을 막아 **시스템 전체가 얼어붙을 수 있다**. 3중 방어(background watchdog · C 콜백 재확인 · 30s monitor)가 이를 막는다. event tap 코드를 만지기 전 반드시 [docs/claude/event-tap-safety.md](docs/claude/event-tap-safety.md) 를 읽고, 검증(앱 실행 중 권한 끄고 입력이 막히지 않는지)까지 한다.
- **개발 중에는 `make dev` 로 hot-swap, 번들 재설치 금지**: 권한(손쉬운 사용/화면 기록)은 `/Applications/DockPeek.app` **번들에 귀속**된다. `make setup`·`make install`·`brew upgrade` 처럼 번들을 통째로 갈아끼우면 권한이 날아가 매번 재허용해야 한다. `make dev` 는 같은 번들 안에서 바이너리만 교체(+재서명)하므로 권한이 유지된다. 첫 설치만 `make setup`, 이후 반복은 `make dev`.
- **버전 올릴 땐 두 곳을 같이**: `Makefile` 의 `VERSION` 과 `DockPeek/Info.plist` 의 `CFBundleShortVersionString` 가 일치해야 한다(둘 다 현재 `1.5.22`). swiftc 빌드는 `Info.plist` 를 그대로 복사하므로 `project.yml` 의 `MARKETING_VERSION`(`1.0.0`)은 stale 이며 안 쓰인다. 커밋 메시지 관례: `Bump version to X.Y.Z`. 전체 릴리스 절차는 [docs/claude/release.md](docs/claude/release.md).
- **커밋 메시지는 평범한 사람 스타일**: 이 레포 커밋엔 AI/Claude 언급·`Co-Authored-By`·생성 푸터 넣지 않는다.

# DockPeek

macOS Dock 아이콘을 클릭하면 그 앱의 열린 창들을 썸네일로 미리보기하고 원하는 창 하나만 골라 전면으로 가져오는 메뉴바 유틸리티(Windows 식 Dock peek). 메뉴바 전용(`LSUIElement`) 앱이고, 배포는 GitHub Releases zip + Homebrew cask(`zerry-lab/tap`). **self-signed**(Apple Developer ID 미서명)이라 Gatekeeper 경고와 일부 백신 false-positive 가 따라온다 — 의도된 트레이드오프([docs/claude/private-apis.md](docs/claude/private-apis.md)).

## Tech Stack

- **언어/런타임**: Swift 5, target `arm64-apple-macos14.0`(Apple Silicon 전용, 최소 macOS 14.0)
- **UI**: AppKit + SwiftUI 하이브리드. 진입점은 SwiftUI `App` 라이프사이클이 아니라 **수동 `NSApplication` 구동**(`DockPeekApp.swift`). 패널/오버레이는 AppKit `NSPanel`/`NSWindow`, 그 안 콘텐츠만 `NSHostingView` 로 SwiftUI.
- **빌드 시스템**: **SwiftPM 도 Xcode 프로젝트도 레포에 없다.** `Makefile` 이 `swiftc` 를 직접 호출해 `.app` 번들을 손으로 조립한다. `project.yml` 은 *선택적* XcodeGen 용(`make generate`/`open`).
- **권한**: 손쉬운 사용(Dock 클릭 감지 + 창 제어) + 화면 기록(썸네일 캡처). entitlements 는 빈 dict(샌드박스 미적용 — private API + system-wide tap).
- **테스트/린트**: **없음.** 검증은 수동(권한 회수 테스트 등).
- **서명 ID**: `DockPeek Development`(로컬 self-signed). 배포 zip 도 같은 self-signed.

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

- **새 `.swift` 파일 추가는 별도 등록 불필요**: `Makefile` 이 `find DockPeek -name '*.swift'` 로 전부 모아 컴파일한다. `DockPeek/` 어디에 두든 자동 포함.(XcodeGen 빌드 때만 `project.yml` 의 `sources` 규칙을 탄다.)
- **단위 테스트 실행 명령 없음** — 테스트 자체가 없다. 행동 변경은 `make dev` 후 실제 동작으로 확인.
- **릴리스**(버전 bump → `make dist` → GitHub Release → Homebrew cask)는 [docs/claude/release.md](docs/claude/release.md) 의 런북을 따른다.

## Architecture (개요)

소스 구조(파일 → 책임):

```
DockPeek/
├── App/
│   ├── DockPeekApp.swift       # @main DockPeekMain — 수동 NSApplication 구동
│   ├── AppDelegate.swift       # 오케스트레이터: 클릭/hover→미리보기·폴링·권한 모니터 (최대 파일)
│   └── AppState.swift          # @AppStorage 설정
├── Core/
│   ├── EventTapManager.swift   # session CGEventTap + 안전장치 watchdog
│   ├── DockAXInspector.swift   # Dock AX hit-test → bundle/pid
│   ├── WindowManager.swift     # 창 enumeration·활성화·캡처 (private API fragile 코어)
│   ├── DockAnchorManager.swift # Dock 디스플레이 고정 (독립 서브시스템)
│   └── AccessibilityManager.swift
├── UI/
│   ├── PreviewPanel.swift      # non-activating NSPanel + 키보드 네비
│   ├── PreviewContentView.swift# SwiftUI 썸네일 그리드
│   ├── HighlightOverlay.swift  # 실제 창 위치 강조 오버레이
│   ├── SettingsView.swift      # 설정 창 (launch-at-login = SMAppService)
│   └── OnboardingView.swift    # 권한 안내
├── Models/                     # DockApp, WindowInfo
├── Utilities/                  # UpdateChecker, DiagnosticChecker, L10n, DebugLog
├── Info.plist                  # CFBundleShortVersionString (버전 bump 대상)
└── DockPeek.entitlements       # 빈 dict (샌드박스 미적용)
```

핵심은 "전역 클릭을 가로채 Dock 클릭인지 판별하고, 해당 앱의 창들을 모아 미리보기를 띄우는" 파이프라인이다(오케스트레이터 `AppDelegate`). 여러 파일에 걸쳐 있어 한 파일만 봐선 안 잡힌다:

`EventTapManager`(클릭 가로채기) → `AppDelegate`(debounce → Dock 영역 기하 판정 → AX hit-test → 창 개수 ≥2 면 클릭 삼키고 표시) → `DockAXInspector`(Dock AX hit-test → bundle/pid) → `WindowManager`(창 enumeration·활성화·캡처, fragile 코어) → `PreviewPanel`(SwiftUI 썸네일 그리드) + `HighlightOverlay`(실제 창 위치 강조).

hover 경로는 event tap 과 별개로 `AppDelegate` 의 adaptive 폴링이 담당. **좌표 변환은 항상 primary screen 높이로**(멀티모니터 함정). Dock anchor 는 권한·event tap 안 쓰는 독립 서브시스템.

→ 전체 흐름·좌표계·캐싱·컴포넌트 맵: [docs/claude/architecture.md](docs/claude/architecture.md).

## Conventions

- **빌드는 swiftc, SPM 아님**: 의존성 추가 불가 — 시스템 프레임워크(AppKit/SwiftUI/CoreGraphics/ApplicationServices/ServiceManagement)만.
- **로컬라이즈는 `L10n.swift` 의 dict 에 직접**: 새 문자열은 `en`·`ko` **두 dict 모두**에 키 추가하고 `static var` 접근자 정의. 언어 전환은 `SettingsView` 가 `.id(langRefresh)` UUID 를 갈아 SwiftUI 뷰 강제 리프레시(재시작 불필요).
- **설정은 `AppState` 의 `@AppStorage`**: 제외 앱 목록은 콤마 구분 문자열을 `Set<String>` 으로 캐시(`cachedExcludedBundleIDs`).
- **디버그 로깅은 `dpLog()`**: DEBUG 는 `print`+`os.log`, release 는 `os.log` 만. subsystem `com.dockpeek.app`.
- **메뉴바 앱 activation policy 토글**: 평소 `.accessory`, 설정/About 창 띄울 때만 `.regular` → 닫히면 `restoreAccessoryPolicyIfNeeded()`.
- **이름 짓기**: 기존 유명 툴과 구현이 다르면 그 툴을 그대로 연상시키는 이름은 피한다.

## 주의할 함정 (요약 — 상세는 각 doc)

- **권한 회수 시 입력 freeze**: 가장 위험한 회귀. → [event-tap-safety.md](docs/claude/event-tap-safety.md)
- **`make dev` 안 쓰고 재설치/`brew upgrade` 하면 권한 날아감**: CRITICAL RULES 참고.
- **좌표 변환은 primary 높이로만**: per-screen 높이로 바꾸면 멀티모니터에서 미리보기/오버레이 위치가 틀어진다. → [architecture.md](docs/claude/architecture.md)
- **커서는 절대 움직이지 않는다 (load-bearing 원칙)**: `CGWarpMouseCursorPosition` 이나 보이는 synthetic 마우스 이벤트 금지. **현재 위반 1건** — "새 창을 primary 로" 기능이 `warpCursorToPrimaryBriefly()`(`AppDelegate.swift` 근처)에서 커서를 옮긴다(설정 토글 없는 always-on). 따라 할 패턴이 아니라 **걷어낼 wart** — Dock launch display 는 커서가 아니라 `CGMainDisplayID` 로 잡아야 한다(경험적 검증).
- **`CGWindowListCreateImage` deprecated(macOS 14+)**: 지금은 동작하나 향후 ScreenCaptureKit 이관 필요. → [private-apis.md](docs/claude/private-apis.md)
- **self-signed → 백신 false-positive & Gatekeeper**: 정상이며 의도된 것. private API 를 들어내서 "고치려" 하지 말 것. → [private-apis.md](docs/claude/private-apis.md)
- **Dock anchor 는 Dock 을 재시작(`killall Dock`)한다**: 토글/방향 변경 시 1회, idempotent. → [architecture.md](docs/claude/architecture.md)
- **프리뷰 인터랙션 모델은 load-bearing**: hover 프리뷰는 키보드를 잡지 않는다(잡으면 타이핑 freeze 재발) + 좀비 프리뷰 방지 3중 + dwell/속도/오버슈트 dismiss 게이팅. → [preview-ux.md](docs/claude/preview-ux.md)
- **README·`AppState.isEnabled` 미세 stale**: README 구조 트리/설정 목록이 약간 낡았고(`DockAnchorManager`/`UpdateChecker`/`DiagnosticChecker` 누락, "Force new windows to primary" 토글은 현재 UI 에 없음), `AppState.isEnabled` 는 선언만 있고 참조처 없는 dead flag 로 보인다. 코드를 진실의 원천으로.

# 추가 문서 (docs/claude/)

**문서화 규칙** (lean 한 CLAUDE.md 유지):

- **작업 끝나면 동기화**: 의미 있는 작업(새 서브시스템·구조 변경·새 함정·새 컨벤션)은 같은 세션에서 관련 CLAUDE.md 섹션·`docs/claude/` 문서를 갱신한다. 커밋/푸시는 수동. 자잘한 일회성 작업은 제외.
- **CLAUDE.md 는 high-signal 만**(CRITICAL RULES·Tech Stack·Commands·Conventions·함정 요약). 한 주제가 깊고 *특정 작업 시에만* 필요하면 `docs/claude/<topic>.md` 로 분할하고 본문엔 인덱스 한 줄·포인터만 남긴다.
- **포맷**: 인덱스 = `- [docs/claude/X.md](...) — **태그**. 키워드. 언제 읽나(한 문장).` / 각 doc 첫 줄 = `> **언제 읽나**: ...` blockquote.

- [docs/claude/release.md](docs/claude/release.md) — **릴리스 런북**. UpdateChecker 자가업데이트(폴링→unzip→`codesign --verify`→교체→relaunch), 버전 bump 2곳·`make dist`·`gh release`·Homebrew cask 갱신·해시 검증, 함정(stale cask·`brew upgrade` 권한 소실·self-signed), 체크리스트. 새 버전 배포할 때.
- [docs/claude/event-tap-safety.md](docs/claude/event-tap-safety.md) — **입력 freeze 방지**(load-bearing). session-level `CGEventTap` 의 위험, 3중 방어(background watchdog 0.5s·C 콜백 재확인·30s monitor), `emergencyInvalidateTap` 스레드 안전성, 검증 절차. event tap 코드 만지기 전 필독.
- [docs/claude/architecture.md](docs/claude/architecture.md) — **클릭/hover→미리보기 파이프라인**. 파일 교차 흐름, 수동 `NSApplication` 구동, hover 폴링, 좌표계(primary 높이) 함정, 캐싱 레이어, 창 enumeration 교차필터, Dock anchor 서브시스템, 보조 유틸. 흐름 따라가거나 새 단계 끼울 때.
- [docs/claude/private-apis.md](docs/claude/private-apis.md) — **fragile 코어**. `WindowManager` 가 런타임 로드하는 private/deprecated API(SkyLight `_SLPSSetFront…`·`_AXUIElementGetWindow`·`GetProcessForPID`·`CGWindowListCreateImage`), 창 동작별 구현(활성화/닫기/스냅/캡처), enumeration 교차필터, AV false-positive 근거. 창 제어·캡처 만지거나 보안경고 답할 때.
- [docs/claude/preview-ux.md](docs/claude/preview-ux.md) — **미리보기 인터랙션 모델**(load-bearing). hover 게이팅(속도/dwell/브라우징·active 폴링 게이트), dismiss 모델(위 오버슈트 즉시·옆아래 0.3s), hover non-key 원칙, 좀비 방지 3중, 패널 재사용 `fittingSize` 함정. 미리보기 등장/전환/dismiss·키보드 네비 만질 때.
