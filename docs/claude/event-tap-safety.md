> **언제 읽나**: `EventTapManager` 나 event tap 관련 코드를 만질 때. **반드시 먼저 읽는다.** 이 방어가 깨지면 사용자 시스템 전체가 입력 불능으로 얼어붙는 가장 위험한 회귀가 난다.

# Event Tap 안전장치 — 입력 freeze 방지

## 위험의 정체

DockPeek 은 Dock 클릭을 가로채려고 **session-level `CGEventTap`(HID 레벨)** 을 잡는다(`EventTapManager.start()`, `tap: .cgSessionEventTap`, `place: .headInsertEventTap`). 이 tap 은 모든 `leftMouseDown` 이 먼저 통과하는 길목에 끼어든다.

문제: 앱 **실행 중**에 사용자가 시스템 설정에서 손쉬운 사용(Accessibility) 권한을 회수하면, tap 이 무효화되지 않은 채 남아 **모든 입력 이벤트를 막아버린다 → 시스템 전체 freeze**. 메인 스레드도 같이 막히므로 메인 스레드에서 정리하려는 시도는 소용없다(이미 늦음).

> 이 freeze 는 사용자가 마우스·키보드로 아무것도 못 하는 상태라 강제 재부팅 외엔 답이 없다. **그래서 아래 3중 방어는 load-bearing 이다 — 절대 제거·약화 금지.**

## 3중 방어

### ① Background watchdog (가장 중요)

`EventTapManager.startPermissionWatchdog()` — **백그라운드 스레드**(`DispatchQueue.global(qos: .userInteractive)`)에서 도는 `DispatchSourceTimer`, **0.5s 주기**.

```swift
timer.setEventHandler { [weak self] in
    if !AXIsProcessTrusted() {                 // 권한 회수 감지
        self?.emergencyInvalidateTap()         // 백그라운드에서 즉시 tap 무효화 → HID 언블록
        DispatchQueue.main.async { self?.stop() }  // 정리는 main 에서(레이스 회피)
    }
}
```

**핵심: 백그라운드 스레드는 HID freeze 에 안 막힌다.** 메인 스레드가 얼어도 이 watchdog 은 계속 돌아 `emergencyInvalidateTap()` 으로 mach port 를 끊어 입력을 되살린다. 이게 1차 방어선.

### ② C 콜백 진입부 재확인

`eventTapCallback`(C 콜백)이 이벤트를 받을 때마다 맨 앞에서 권한을 재확인:

```swift
if !AXIsProcessTrusted() {
    manager.emergencyInvalidateTap()           // 이 이벤트는 통과시키고 tap 파괴
    return Unmanaged.passUnretained(event)
}
```

`tapDisabledByTimeout`/`tapDisabledByUserInput` 로 시스템이 tap 을 끈 경우도 **재활성화 전에 권한을 확인** — 권한이 있으면 `tapEnable(true)`, 없으면 `stop()`. 이벤트가 한 번이라도 흐르면 즉시 자가 치유된다.

### ③ AppDelegate 30s 권한 모니터

`AppDelegate.startPermissionMonitor()` — 30초 주기 `Timer`. 권한이 사라졌으면 `eventTapManager.stop()` + `stopHoverMonitor()` 후 `startAccessibilityPolling()` 로 재허용 대기로 전환. ①·② 가 놓친 느린 경로의 백스톱이며, 권한 재허용 시 자동 복구도 담당. 추가로 **reconciler**: 권한이 있는데 `eventTapManager.isActive == false`(긴급 경로가 tap 만 내린 경우)면 `startEventTap()` 로 재시작.

### 긴급 정지 후 복구 (load-bearing)

①(watchdog)/②(콜백)가 권한 상실로 tap 을 **긴급 정지**하면, watchdog 이 main 에서 `stop()` 직후 `delegate.eventTapManagerDidLosePermission(_:)` 를 호출 → `AppDelegate` 가 `stopHoverMonitor()` + 30s 모니터 무효화 + `startAccessibilityPolling()`(2s) 로 전환 → 권한 재허용 시 **~2s 안에** tap 자동 재시작.

> **왜 필요한가**: 긴급 경로(①·②)는 tap 만 내리고 끝이라, 이게 없으면 빠른 OFF→ON 토글 시 30s 모니터가 "이미 권한 ON" 을 보고 아무것도 안 해 **tap 이 앱 재시작 전까지 영영 다운**(hover 만 살아남아 "클릭 프리뷰만 안 뜸"). delegate 알림은 ①의 HID unblock(`emergencyInvalidateTap`, bg) **이후** main 에서 도므로 freeze 안전엔 무관. ③ reconciler 는 알림이 누락돼도 ≤30s 안에 복구하는 2차 백스톱.

## `emergencyInvalidateTap()` — 모든 스레드 안전

```swift
fileprivate func emergencyInvalidateTap() {
    guard let tap = snapshotTap() else { return }  // 락 안에서 스냅샷만
    CGEvent.tapEnable(tap: tap, enable: false)     // CG 호출은 락 밖에서
    CFMachPortInvalidate(tap)                       // HID 언블록의 핵심 연산
}
fileprivate func snapshotTap() -> CFMachPort? { lock.withLock { eventTap } }
```

`CGEvent.tapEnable(false)` + `CFMachPortInvalidate` 는 **어느 스레드에서 호출해도 안전**하도록 의도됐다. watchdog(백그라운드)·콜백(tap 스레드)·`stop()`(main) 모두 이걸 호출한다. `runLoopSource` 제거 같은 main-only 정리는 `stop()` 이 main 에서 처리해 레이스를 피한다.

### `eventTap` 락 (`OSAllocatedUnfairLock`)

`eventTap`(`CFMachPort?`)은 C 콜백(HID)·watchdog(백그라운드)에서 읽고 `stop()`(main)에서 nil 로 쓴다 → 무동기면 ARC refcount 레이스. 그래서 `eventTap` 접근만 `lock` 으로 직렬화한다(`isActive`/`runLoopSource` 는 main 전용이라 미보호).

> **왜 복구 경로를 안 막나(load-bearing)**: 임계영역은 **포인터 read/write 1회(나노초)** 뿐이고, main 은 `start()`/`stop()` 안에서만 락을 잡는데 그 블록엔 블로킹 연산이 없다. 권한 회수 freeze 는 임의 시점에 나는데 그때 main 은 `start/stop` 안에 있지 않으므로 **락이 경합되지 않는다** → watchdog 의 `snapshotTap()` 은 즉시 락을 얻어 tap 을 끊는다. `emergencyInvalidateTap` 은 스냅샷만 락 안에서 뜨고 CG 호출은 **락 밖**에서 하므로 락을 든 채 블록되는 일도 없다.

## 만질 때 지켜야 할 것

- watchdog 의 **0.5s 주기·백그라운드 큐·`AXIsProcessTrusted()` 게이트**를 유지. 큐를 main 으로 바꾸면 freeze 시 같이 막혀 방어가 죽는다.
- `emergencyInvalidateTap()` 을 main-only 로 만들지 말 것(스레드 안전성이 방어의 전제).
- `lock` 임계영역은 **포인터 read/write 만** 유지 — 락을 든 채 CG 호출·블로킹 연산 금지(복구 경로가 막힌다). `eventTap` 읽기는 항상 `snapshotTap()` 경유.
- 콜백 진입부의 권한 재확인을 제거하지 말 것.
- 새 경로로 tap 을 잡거나 재활성화한다면 같은 권한 게이트를 통과시킬 것.

## 검증 (수동 — 자동 테스트 없음)

1. `make dev` 로 실행.
2. 앱이 도는 동안 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 DockPeek 권한을 **끈다**.
3. 마우스·키보드 입력이 막히지 않는지 확인 — 최대 0.5s(watchdog 주기) 안에 정상으로 돌아와야 한다.
4. 권한을 다시 켜면 **~2s 안에** event tap 이 자동 복구되는지 확인 — Dock 아이콘 클릭 시 **클릭 프리뷰가 다시 뜨면** OK(앱이 바로 켜지면 tap 이 아직 다운). hover 프리뷰만 뜨고 클릭 프리뷰가 안 뜨면 복구 갭 회귀.
