> **언제 읽나**: hover/클릭 미리보기의 등장·전환·dismiss 동작이나 키보드 네비를 만질 때. 이 인터랙션 모델은 load-bearing — 잘못 건드리면 "다른 앱에 타이핑 불가" freeze 나 좀비 프리뷰가 재발한다.

# 미리보기 인터랙션 모델 (preview-ux)

설계 이력: `docs/superpowers/specs/2026-06-04-preview-ux-design.md`. 이 문서는 현재 동작의 living reference.

## hover 게이팅 (`pollMousePosition` → `processHoverEvent`, `AppDelegate.swift`)

미리보기를 띄울지 결정하는 게이트들:

- **속도 게이트** (`hoverVelocityThreshold` 1200pt/s) — Dock 을 빠르게 가로지르는 패스는 무시. 속도는 `pollMousePosition` 에서 `lastPollMouseLocation` 갱신 *전* 에 계산하고, 게이트는 `lastHoveredBundleID` 변경 *전* 에 배치한다(순서가 중요).
- **첫 hover 0.5s dwell** (`hoverFirstDelay`) — 패널이 아직 없을 때 첫 등장은 `DispatchWorkItem`(`hoverTimer`)을 0.5s 뒤로 예약. 우발적 스침을 거른다.
- **브라우징 중 전환은 즉시** — 패널이 이미 떠 있으면(`wasVisible`) dwell 없이 `handleHoverPreview(reuse:true)` 로 내용만 교체. 속도 게이트가 이미 빠른 패스를 막았으므로, 즉시 전환은 의도적인 settle 이동에만 발동 → Windows 식 snappy 감각.

### 폴링 active 게이트 (잔상 미리보기 방지)

`needsActive = inDock || previewIsVisible || hoverTimer != nil`.

세 번째 항이 핵심: **dwell 이 예약된 동안엔 패널이 안 보여도 폴링을 active(15Hz)로 유지**한다. 이게 없으면, 미리보기가 뜨기 *전*에 커서가 Dock 을 벗어났을 때 `needsActive` 가 false 가 되어 `processHoverEvent` 가 스킵되고 → 예약된 dwell 타이머가 취소되지 않아 → **이미 떠난 앱의 미리보기가 뒤늦게 떠서 잔상으로 남는다**(커서가 Dock 밖에 멈춰 있으면 "마우스 안 움직임" 조기 return 에 걸려 leave-dismiss 도 안 돈다). active 유지로 leave 를 즉시 감지해 `hoverTimer` 를 취소한다. (2026-06 / v1.5.22 수정.)

## dismiss 모델

`processHoverEvent` 의 "Dock·패널 밖" 분기(`!inDock || dockApp == nil`)에서:

- **위로 오버슈트 → 즉시·무애니메이션 dismiss** — 커서가 패널 상단(`previewPanel.frame.maxY`)보다 위로 가면 `dismissPanel(animated: false)` 로 fade 없이 바로 닫는다. 패널을 뚫고 위로 지나친 건 "확실히 떠남" 신호. (2026-06 / v1.5.22 추가.)
- **옆/아래로 빠짐 → 0.3s 지연 dismiss** — Dock↔패널 사이 gap 을 건너 패널로 진입하는 정상 경로라 유예가 필요. `hoverDismissTimer`(0.3s) 예약, 발화 시 커서가 패널 안에 들어왔으면 취소.
- 정상 접근(Dock→패널)은 패널 **아래쪽**(`frame.minY` 밑 gap)을 지나므로 위 오버슈트 조건(`>= maxY`)엔 안 걸린다.

좌표 비교는 `cocoaLoc` 과 `previewPanel.frame` 둘 다 동일한 global Cocoa 좌표(primary 높이 round-trip)라 멀티모니터 규칙을 지킨다([architecture.md](architecture.md) 좌표계 함정).

## hover 프리뷰는 키보드를 잡지 않는다 (load-bearing)

`PreviewPanel.showPreview(grabsKeyboard:)` 는 **클릭**(`showPreviewForWindows(interactive:true)`)일 때만 `makeKey()`. hover 프리뷰는 non-key.

> hover 가 key 를 잡으면 사용자가 다른 앱에 타이핑을 못 하는 freeze 가 재발한다. **이 구분을 없애지 말 것.** 그래서 키보드 네비(←→/Enter/Esc, `navState.selectedIndex`)는 클릭으로 띄운 프리뷰에만 동작한다.

## 좀비 프리뷰 방지 3중

1. `PreviewPanel` 이 자기 `NSWindowDelegate` 로서 `windowDidResignKey`(클릭 프리뷰가 포커스를 잃으면 닫음).
2. `AppDelegate` 의 `didActivateApplicationNotification` 옵저버(`appDidActivate`) — Cmd-Tab·앱 전환 시 hover·click 공통으로 닫음.
3. `isDismissing` 가드 — `orderOut` 이 유발하는 재진입 `resignKey` 를 차단.

## 앱 전환은 패널 재사용

다른 Dock 앱으로 hover 가 옮겨가면 dismiss+재페이드 없이 `showPreview(reuse:)` 로 `rootView` 만 교체.

> 함정: `NSHostingView.fittingSize` 는 rootView 교체 직후 한 runloop 늦으므로, reframe 을 `DispatchQueue.main.async`(+`isVisible`/`dismissGeneration` 가드)로 미룬다. 이 지연을 없애면 첫 프레임이 잘못된 크기로 뜬다.

## 검증 (수동)

- 창 ≥2 앱에 0.5s 안에 잠깐 올렸다 Dock 밖으로 빼기 → 잔상 미리보기 안 뜸.
- 미리보기 떠 있을 때 커서를 패널 **위로** → 잔상·fade 없이 즉시 사라짐.
- Dock→패널 정상 진입(아래 gap 통과) → 안 꺼지고 붙음. 옆/아래로 빼면 ~0.3s 뒤 부드럽게 사라짐.
- hover 프리뷰가 떠 있어도 다른 앱에 타이핑 가능(키 안 뺏김).
- Cmd-Tab 으로 앱 전환 시 떠 있던 프리뷰가 닫힘.
