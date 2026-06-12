> **언제 읽나**: 클릭/hover → 미리보기 흐름을 따라가거나, 새 단계를 끼우거나, 좌표/캐싱 동작을 디버깅할 때. 이 파이프라인은 여러 파일에 걸쳐 있어 한 파일만 봐선 안 잡힌다.

# Architecture — 클릭/hover → 미리보기 파이프라인

핵심은 "전역 클릭을 가로채 Dock 클릭인지 판별하고, 해당 앱의 창들을 모아 미리보기를 띄우는" 파이프라인이다. 오케스트레이터는 `AppDelegate`(`eventTapManager(_:didDetectClickAt:)`).

## 진입점 / 구동 모델

SwiftUI `App` 라이프사이클이 아니라 **수동 `NSApplication` 구동**이다 — `@main struct DockPeekMain`(`DockPeekApp.swift`)이 `NSApplication.shared` 에 `AppDelegate` 를 직접 물린다. 패널/오버레이는 AppKit `NSPanel`/`NSWindow`, 그 안 콘텐츠만 `NSHostingView` 로 SwiftUI.

메뉴바 전용(`LSUIElement`). activation policy 는 평소 `.accessory`(Dock 아이콘 없음), 설정/About 창 띄울 때만 `.regular` 로 올렸다가 닫히면 `restoreAccessoryPolicyIfNeeded()` 로 복귀.

## 클릭 → 미리보기 흐름

1. **`EventTapManager`** — `cgSessionEventTap` 으로 `leftMouseDown` 만 잡는다. C 콜백(`eventTapCallback`)이 권한·tap-disabled 를 점검한 뒤 delegate(`AppDelegate`)로 클릭 좌표 전달. delegate 가 `true` 를 반환하면 **이벤트를 삼켜** Dock 기본 동작(앱 전환)을 막는다. (안전장치는 [event-tap-safety.md](event-tap-safety.md).)
2. **`AppDelegate`** — ① debounce(0.3s) → ② `isPointInDockArea()` **빠른 기하 판정**(AX 호출 없이 `screen.frame` vs `visibleFrame` gap 으로 Dock 영역인지) → ③ `DockAXInspector.appAtPoint()` AX hit-test → ④ `WindowManager.windowsForApp()` 로 창 개수 확인 → **창 ≥ 2 개면 클릭을 삼키고** `PreviewPanel` 표시, 1 개 이하면 통과시켜 Dock 기본 동작 유지.
3. **`DockAXInspector`** — `com.apple.dock` 의 `AXUIElement` 에 `AXUIElementCopyElementAtPosition` 으로 hit-test → 부모로 올라가며 `AXDockItem` 찾고 `AXApplicationDockItem` 인지 확인 → `kAXURLAttribute` 에서 bundle ID, 거기서 `NSRunningApplication` → pid 해석(이름/AX 속성 fallback).
4. **`WindowManager`** — 시스템에서 가장 fragile 하고 핵심. 창 enumeration·활성화·캡처. 상세는 [private-apis.md](private-apis.md).
5. **`PreviewPanel`** (non-activating `NSPanel`, `.borderless + .nonactivatingPanel`, level `.popUpMenu`)가 `PreviewContentView`(SwiftUI 썸네일 그리드)를 호스팅. 키보드 네비(←→/Enter/Esc)는 panel 의 local event monitor 가 처리 — **클릭으로 띄운 프리뷰만** key. 콜백 5종(`onSelect`/`onClose`/`onSnap`/`onDismiss`/`onHoverWindow`)으로 `AppDelegate` 와 통신. 인터랙션 모델 상세는 [preview-ux.md](preview-ux.md).
6. **`HighlightOverlay`** — 썸네일 hover 시 **실제 창 위치**에 반투명 borderless 윈도(캡처 이미지 + 강조 테두리)를 띄워 어느 창인지 알려준다.

## Hover 경로 (event tap 과 별개)

`AppDelegate` 가 adaptive `DispatchSourceTimer`(`.main` 큐)로 `NSEvent.mouseLocation` 을 폴링한다(`pollMousePosition`). idle 4Hz(`idlePollInterval` 0.25s), Dock 근처/패널 표시 중/dwell 예약 중엔 ~15Hz(`activePollInterval` 0.066s)로 가속. 마우스가 안 움직이고 Dock-영역 상태도 그대로면 처리를 건너뛴다. hover 로도 클릭 없이 미리보기를 띄울 수 있다. 게이팅/dismiss 규칙은 [preview-ux.md](preview-ux.md).

## 좌표계 함정 (전반에 깔림)

CG(좌상단 원점) vs Cocoa(좌하단 원점) 변환이 도처에 있는데, **항상 primary screen 높이**(`NSScreen.screens.first?.frame.height`)로 뒤집어야 한다 — CG 원점이 primary 의 좌상단이기 때문. **screen 별 높이로 변환하면 멀티 디스플레이에서 깨진다.** `AppDelegate`/`PreviewPanel`/`HighlightOverlay`/`WindowManager` 모두 이 규칙을 따른다.

## 캐싱 레이어 (성능 핵심)

| 위치 | 캐시 | TTL |
|---|---|---|
| `WindowManager` | thumbnailCache | 5s (패널 열려있으면 10s, `isPreviewVisible`) |
| `WindowManager` | windowListCache (`CGWindowListCopyWindowInfo` 결과) | 0.5s |
| `WindowManager` | axWindowIDsCache | 1s |
| `AppDelegate` | cachedAXHitResult | 100ms TTL |
| `AppDelegate` | cachedDockRect | 화면/Dock 변경 시 갱신(`updateCachedDockRect`) |
| `AppDelegate` | adaptive poll interval + "마우스 안 움직이면 skip" | — |

`windowOrderByBundle` 는 창 순서를 bundle ID 별로 UserDefaults 에 영속화해 미리보기 카드 순서를 안정화(앱 재시작 시 새 `CGWindowID` 라 자연 리셋).

## 창 enumeration 의 핵심 트릭

`CGWindowListCopyWindowInfo`(layer 0, alpha>0, 화면상) 결과를 **AX `kAXWindowsAttribute`(subrole `AXStandardWindow`)와 교차 필터**한다 — Chrome 번역 바, 툴팁, 팝오버 같은 helper/overlay 창을 걸러내기 위함. 상세는 [private-apis.md](private-apis.md).

## Dock anchor (완전히 독립된 서브시스템)

`DockAnchorManager`("Dock" 설정 탭) — event tap 도 손쉬운 사용 권한도 안 쓴다. `com.apple.dock` 의 미문서화 키 `allow-display-switching=false`(커서가 다른 디스플레이로 넘어갈 때 Dock 따라가는 내부 경로를 막음) + `orientation` 을 `CFPreferences` 로 쓰고 `killall Dock` 으로 재적용(값이 실제로 바뀔 때만 — idempotent). **"zero cursor interference" 가 이 기능의 설계 원칙** — 예전 CGEventTap/커서 기반 구현을 이 preference 토글 방식으로 갈아엎은 결과다.

## 보조 유틸

- **`UpdateChecker`** — GitHub Releases 폴링 → in-app self-update. 상세는 [release.md](release.md).
- **`DiagnosticChecker`** — 권한/event tap/Dock AX/화면 정보 진단 텍스트(설정에서 복사).
- **`L10n`** — 직접 만든 en/ko dict(`.strings`/`.lproj` 아님). 새 문자열은 두 dict 모두에 추가.
- **`AppState`** — `@AppStorage` 설정 보관.
