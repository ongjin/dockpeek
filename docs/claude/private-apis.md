> **언제 읽나**: `WindowManager` 의 창 활성화/닫기/스냅/캡처를 만지거나, 백신 false-positive·Gatekeeper 문의에 답할 때. 여기가 시스템에서 가장 fragile 한 코어다.

# Private / Deprecated API (fragile 코어)

`WindowManager` 는 단일 창 제어와 썸네일 캡처를 위해 공개 API 로는 불가능한 동작을 한다. 그래서 **private/deprecated 심볼을 런타임에 `dlopen`/`dlsym`/`@_silgen_name` 으로 로드**한다(`WindowManager.swift` 상단). 이 조합이 곧 기능이자, 백신 false-positive 의 원인이다.

## 런타임 로드 심볼

| 심볼 | 출처 | 용도 |
|---|---|---|
| `_SLPSSetFrontProcessWithOptions` | SkyLight (PrivateFramework, `dlopen`+`dlsym`) | **단일 창 활성화**. full-screen Space 전환까지 처리. **AltTab 과 동일 접근.** |
| `_AXUIElementGetWindow` | ApplicationServices (`dlsym(dlopen(nil))`) | `AXUIElement` ↔ `CGWindowID` **100% 정확 매칭**. 대상 창 특정에 필수 |
| `GetProcessForPID` | `@_silgen_name` | pid → `ProcessSerialNumber`(SLPS 호출에 필요) |
| `CGWindowListCreateImage` | CoreGraphics (공개지만 **deprecated**) | 썸네일/오버레이 캡처 |

로드 패턴(예시):
```swift
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let _slpsSetFront: SLPSSetFrontFn? = {
    guard let h = skylight, let sym = dlsym(h, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: SLPSSetFrontFn.self)
}()
```
모두 옵셔널 — 심볼을 못 찾으면 `nil` 로 떨어지고 공개 API fallback(예: `NSRunningApplication.activate()`)을 탄다.

## 창 동작별 구현

- **활성화** — `_SLPSSetFrontProcessWithOptions`(`GetPSNForPID` 로 얻은 PSN + `CGWindowID`) → AX raise → `kAXMainAttribute`/`kAXFocusedWindowAttribute` 순으로 시도.
- **닫기** — AX close 버튼의 `kAXPressAction`.
- **스냅** — AX `kAXPosition`/`kAXSize` 직접 설정(`SnapPosition` left/right/fill).
- **캡처** — `CGWindowListCreateImage(.optionIncludingWindow, wid, [.boundsIgnoreFraming, .nominalResolution])`.

## 창 enumeration 교차 필터

`windowsForApp(pid:)` 의 핵심 트릭:

1. `CGWindowListCopyWindowInfo` 로 layer 0, alpha>0, 화면상 창 목록을 얻고,
2. 그 `CGWindowID` 들을 **AX `kAXWindowsAttribute`(subrole `AXStandardWindow`) 집합과 교차**시켜,
3. helper/overlay(Chrome 번역 바, 툴팁, 팝오버 등)를 걸러낸다.

`_AXUIElementGetWindow` 가 AX 창 ↔ `CGWindowID` 를 정확히 이어주기에 이 교차가 가능하다. CGWindow 목록만으로는 standard 창과 overlay 를 못 가른다.

## deprecated 경고

`CGWindowListCreateImage` 는 **macOS 14 부터 deprecated**(빌드 시 경고 1건 — 정상). 아직 동작하지만, 향후 OS 에서 끊기면 **ScreenCaptureKit 이관**이 필요하다.

## 백신 false-positive / Gatekeeper — 의도된 것

system-wide `CGEventTap`(→ [event-tap-safety.md](event-tap-safety.md)) + private SkyLight API + **Apple Developer ID 미서명(self-signed)** 조합이 휴리스틱 스캐너를 자극한다.

> **이건 정상이며 의도된 트레이드오프다.** private API 를 "고치려고" 들어내면 그게 곧 단일 창 활성화/정확 매칭 기능의 상실이다. 대응은 코드 변경이 아니라 README 의 whitelist/build-from-source 안내, cask 의 `xattr -dr com.apple.quarantine`(postflight) + 첫 실행 caveats 다. 배포 맥락은 [release.md](release.md) 함정 ③.
