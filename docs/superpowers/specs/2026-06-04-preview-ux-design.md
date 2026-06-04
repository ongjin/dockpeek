# 프리뷰 UX 개선 설계

- **날짜**: 2026-06-04
- **상태**: 승인됨 (구현 대기)
- **범위**: hover/click 프리뷰의 트리거·포커스·닫힘·전환 동작. 썸네일 렌더링·스냅·Dock anchor 등은 건드리지 않음.

## 배경 / 문제

프리뷰는 편리하지만 "가끔 거슬린다". 사용자 피드백으로 확인된 불만 3가지:

1. **(가장 심각) 좀비 프리뷰 + 키보드 차단** — 프리뷰가 가끔 안 사라지고, 그동안 다른 앱에 키보드 입력이 안 됨. 결국 아무 데나 클릭해서 강제로 끔.
2. **의도 없는 hover 트리거** — Dock 위/근처로 마우스만 옮겨도(지나가거나 멈추기만 해도) 프리뷰가 불쑥 뜸.
3. **등장/전환 깜빡임** — 앱 간 전환 시 flicker.

(참고: "창 1개 앱에도 뜸"은 큰 불만 아님 → 현행 유지.)

### 근본 원인 분석 (코드 기준)

- **키보드 차단**: `PreviewPanel.showPreview`가 항상 `makeKey()` 호출(`PreviewPanel.swift:103`, `canBecomeKey: true`). 비활성 패널이지만 key가 되면서 **시스템 키보드 포커스를 가로챔**. hover로 뜬 프리뷰조차 키보드를 빼앗아, 떠 있는 동안 사용자가 실제 앱에 타이핑하면 죽은 패널로 키가 감.
- **좀비(안 닫힘)**: 닫힘 경로가 ⓐ 마우스가 dock/패널을 벗어나는 *움직임*(`AppDelegate.processHoverEvent`의 0.3s `hoverDismissTimer`) 또는 ⓑ 어딘가 *클릭*(`PreviewPanel`의 global mouse monitor)에만 의존. **키보드 전환(Cmd-Tab)·마우스 정지 시 닫는 경로가 없음.** `pollMousePosition`의 "마우스 안 움직이면 skip" 최적화(`AppDelegate.swift:333-338`)가 정지 상태의 재평가를 막아 악화.
- **의도 없는 hover**: 첫 hover는 0.5s 딜레이가 있지만, **한 번 프리뷰가 뜨면 그 뒤엔 아이콘 위를 지나가기만 해도 즉시 전환**(`processHoverEvent`의 `if wasVisible { handleHoverPreview }`, `AppDelegate.swift:504`). 속도 개념이 없어 빠르게 가로질러도 반응.
- **깜빡임**: 앱 전환이 `dismissPanel(animated:false)` → `showPreview`(alpha 0→1 재페이드) 구조라 매 전환마다 페이드.

## 목표 / 비목표

**목표**
- hover는 유지하되 **덜 민감하게** (사용자 선택).
- 좀비 프리뷰·키보드 차단을 **근본 제거**.
- 앱 전환 깜빡임 제거.
- **설정 추가 없음** — 더 나은 기본 동작으로만 해결 (프로젝트의 "설정 최소" 원칙).

**비목표**
- 키보드 네비 모델을 hover로 확장하지 않음 (클릭 프리뷰 전용으로 둠).
- 창 1개 앱의 hover 프리뷰 동작 변경 안 함.
- 썸네일 캡처/렌더 성능, 스냅, ScreenCaptureKit 이관은 범위 밖.

## 설계

채택 접근: **마우스 우선 hover + 안전망 닫힘** (브레인스토밍의 접근 1).

### A. 키보드 & 포커스 모델

`PreviewPanel.showPreview(...)`에 `grabsKeyboard: Bool` 추가. `makeKey()`는 이 값이 `true`일 때만 호출.

| 트리거 | `grabsKeyboard` | `makeKey()` | 키보드 네비(←→/Enter/Esc) |
|--------|:--------------:|:-----------:|:--------------------------:|
| Hover (마우스 올림) | `false` | 호출 안 함 | 없음 — 마우스로만 |
| Click (Dock 아이콘 클릭) | `true` | 호출 | 현행 유지 |

- `AppDelegate.showPreviewForWindows`에 출처 인자(`interactive: Bool`)를 받아 패널까지 전달.
  - hover 호출부 `handleHoverPreview` → `false`
  - 클릭 호출부 2곳(`eventTapManager`의 신규 표시 경로, 앱 전환 경로) → `true`
- **불변식**: 비활성 패널은 key가 아니어도 SwiftUI 썸네일 클릭/X버튼/스냅이 정상 동작(마우스 히트테스트는 key 무관). 따라서 hover 프리뷰는 **키보드만** 빠지고 마우스 조작은 그대로.
- hover 프리뷰는 key를 가진 적이 없으므로 `windowDidResignKey`로 닫히지 않음 → 섹션 B의 전면-앱-변경 옵저버가 hover의 안전망을 담당.

### B. 방탄 닫힘

안전망 2개 추가:

1. **전면 앱 변경 감지 (주 안전망, hover·click 공통)**
   - `AppDelegate`에서 `NSWorkspace.shared.notificationCenter`의 `didActivateApplicationNotification` 구독.
   - 활성화된 앱의 bundle ID가 DockPeek이 아니면 프리뷰 즉시 닫힘(+`highlightOverlay.hide()`, hover 상태 초기화).
   - Cmd-Tab·다른 앱 클릭 등 "전환하는 순간" 좀비 제거. 비활성 패널 표시는 앱 활성화를 일으키지 않으므로 자기 자신 때문에 오발화하지 않음.

2. **`windowDidResignKey` → 닫힘 (보조, 키보드 잡은 클릭 프리뷰용)**
   - `PreviewPanel`을 자신의 `NSWindowDelegate`로 설정, `windowDidResignKey`에서 저장된 `onDismiss` 호출.
   - **재진입 가드**: `dismissPanel`이 `orderOut`을 부르면 resignKey가 다시 발생 → 무한 루프 위험. `isDismissing` 플래그(또는 `dismissGeneration` 활용)로 dismiss 진행 중엔 resignKey 핸들러를 무시.

이 둘 + 기존 경로(마우스 leave 0.3s, global click monitor, Esc)로 "마우스 안 움직여도", "키보드로 전환해도" 닫힘 보장.

### C. Hover 둔감화 (속도 + dwell 게이팅)

`pollMousePosition`에서 마우스 **속도**를 계산(이전 위치 `lastPollMouseLocation`·폴 간격 보유)해 `processHoverEvent`로 전달. 두 지점에서 게이팅:

| 상황 | 현재 | 변경 |
|------|------|------|
| 첫 hover (프리뷰 없음) | 0.5s 뒤 표시 | 속도 < 임계치일 때만 0.5s 타이머 **무장**. 빠르게 지나가면 타이머를 켜지 않음 |
| 앱 전환 (프리뷰 떠 있음) | **즉시** 전환 | **짧은 dwell(≈0.12s) + 저속**일 때만 전환. 빠르게 지나가는 아이콘은 무시 |

- 튜닝 상수(속도 임계치, dwell, 첫-hover 딜레이)는 **구현 중 실제 감각으로 조정** — 설계는 의도만 고정. 초기값 제안: 속도 임계치 ≈1200 pt/s, 전환 dwell ≈0.12s, 첫-hover 딜레이 0.5s 유지.
- 마우스가 같은 아이콘에서 멀어지면 타이머 취소(현행 bundleID 변경 로직 유지).
- 효과: Dock을 가로질러 가도 안 뜨고, 브라우징 중 휙휙 지나가도 따라붙지 않음. **머무를 때만** 반응.

### D. 깜빡임 제거 (앱 전환 시 패널 재사용)

- 프리뷰가 **이미 visible일 때**의 앱 전환은 닫았다 재표시하지 않고 **내용 교체 + 위치 재계산**만, alpha는 1 유지(재페이드 생략). 최초 등장·최종 닫힘 페이드는 유지.
- 구현: `showPreview`에 `reuse: Bool` 추가 — visible이면 alpha 리셋·재페이드를 건너뛰고 프레임만 (옵션) 애니메이션 이동, 콜백/저장 상태/dismiss 모니터 갱신. 기존 `updateThumbnails`의 in-place 콘텐츠 교체를 토대로 프레임 재계산을 더함.
- 전환 시 `grabsKeyboard`는 출처를 따름(클릭 전환=true, hover 전환=false).

## 변경 파일

- **`DockPeek/UI/PreviewPanel.swift`**
  - `showPreview(...)`에 `grabsKeyboard: Bool`, `reuse: Bool` 파라미터.
  - `makeKey()`를 `grabsKeyboard`로 가드.
  - `NSWindowDelegate` 채택 + `windowDidResignKey` → `onDismiss`, `isDismissing` 재진입 가드.
  - visible일 때 재사용(페이드 생략·프레임 재계산) 경로.
- **`DockPeek/App/AppDelegate.swift`**
  - `showPreviewForWindows`에 `interactive: Bool` 인자, 패널 호출까지 전달.
  - hover/click 호출부 분기(`handleHoverPreview`=false, 클릭 2곳=true).
  - `didActivateApplicationNotification` 옵저버 → 타 앱 활성화 시 닫힘.
  - `pollMousePosition`: 속도 계산해 `processHoverEvent`로 전달.
  - `processHoverEvent`: 첫-hover 무장·앱전환을 속도/dwell로 게이팅.

## 엣지/리스크

- **resignKey 재진입**: `isDismissing` 가드 필수 (위 B-2).
- **비활성 패널 클릭 동작**: 마우스 선택·X·스냅이 key 없이도 동작하는지 `make dev` 후 실제 확인(설계 전제).
- **CRITICAL RULES 영향 없음**: event tap 안전장치(watchdog/콜백/permission monitor) 경로는 건드리지 않음. hover poll·프리뷰 패널만 수정.
- **좌표계**: 신규 좌표 변환을 추가하면 항상 primary 높이로 뒤집기(기존 규칙 유지).

## 성공 기준 (수동 검증 — 테스트 타깃 없음)

`make dev` 후 실제 동작으로 확인:

1. **키보드 차단 해소**: 창 2+ 앱에 hover로 프리뷰를 띄운 뒤, 마우스를 움직이지 않고 다른 앱(에디터 등)에 타이핑 → **즉시 입력됨**(프리뷰가 키보드를 안 잡음).
2. **좀비 제거 (마우스 정지)**: 프리뷰를 띄우고 마우스를 멈춘 채 Cmd-Tab으로 다른 앱 전환 → 프리뷰가 **자동으로 닫힘**.
3. **좀비 제거 (클릭 프리뷰)**: Dock 아이콘 클릭으로 프리뷰(키보드 모드)를 띄운 뒤 다른 앱으로 전환 → 닫히고 키보드 풀림. Esc·←→·Enter는 여전히 동작.
4. **hover 둔감화 (가로지르기)**: Dock을 빠르게 가로질러 마우스를 이동 → 프리뷰가 **안 뜸**.
5. **hover 둔감화 (브라우징 중)**: 프리뷰가 뜬 상태에서 아이콘들 위를 빠르게 지나감 → 프리뷰가 **따라붙지 않음**. 한 아이콘에 머물면 전환됨.
6. **깜빡임 제거**: 두 앱 사이를 천천히 오가며 전환 → 페이드 깜빡임 **없이** 매끄럽게 내용만 바뀜.
7. **회귀 없음**: 클릭→프리뷰→썸네일 클릭으로 창 활성화, X로 닫기, 스냅이 모두 정상.
