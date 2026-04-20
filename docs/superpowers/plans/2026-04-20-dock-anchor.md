# Dock Anchor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anchor the macOS Dock to the primary display with zero cursor interference and zero Dock flicker, by intercepting mouse-moved events scoped to the Dock's process only.

**Architecture:** New self-contained `DockAnchorManager` owns a `CGEventTapCreateForPid` tap targeted at `com.apple.dock`'s pid. The tap drops mouse-moved events whose CG-coordinate location falls inside any non-primary display's Dock trigger zone; every other process (and the window-server cursor renderer) still receives those events, so the user's cursor experiences zero stickiness while the Dock never receives the trigger pressure needed to relocate. A one-time synthetic-mouse warp handles the case where the Dock is already on a non-primary display at `start()`. Observers handle Dock respawn, display hotplug, and accessibility revocation.

**Tech Stack:** Swift 5.9, AppKit, CoreGraphics (`CGEventTapCreateForPid`, `CGWarpMouseCursorPosition`), ApplicationServices (AX), macOS 14+. Build via `make dev` (see `Makefile`). No automated test target — verification is manual with the running app.

**Spec:** `docs/superpowers/specs/2026-04-20-dock-anchor-design.md`

**Testing note:** The project has no unit-test target. Each implementation task verifies via `make dev` (compile + launch) plus a scripted manual check. Do not add a test target — out of scope.

**Commit messages:** Plain, human-style. Do NOT include `Co-Authored-By: Claude`, `Generated with Claude Code`, or any Claude/AI/Anthropic mention.

---

## Task 1: PoC — per-pid event tap on Dock with logging only

**Files:**
- Create: `DockPeek/Core/DockAnchorManager.swift`
- Modify: `DockPeek/App/AppDelegate.swift` (wire a temporary call to `start()`)

**Goal of this task:** Validate that `CGEventTapCreateForPid(dockPid, ...)` receives mouse-moved events delivered to the Dock process. This proves the mechanism before we build the rest of the feature. **If logs show zero events when the mouse moves near the bottom of any display, stop and report — the whole design is invalidated and we reconsider.**

- [ ] **Step 1: Create the manager skeleton with tap creation + raw logging**

```swift
// DockPeek/Core/DockAnchorManager.swift
import AppKit
import ApplicationServices

final class DockAnchorManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPID: pid_t = 0

    func start() {
        guard AXIsProcessTrusted() else {
            dpLog("DockAnchor: accessibility not granted, skipping")
            return
        }
        guard let pid = Self.findDockPID() else {
            dpLog("DockAnchor: Dock process not found")
            return
        }
        dockPID = pid

        let mask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreateForPid(
            pid: pid,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<DockAnchorManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            dpLog("DockAnchor: tapCreateForPid failed (pid=\(pid))")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        dpLog("DockAnchor: PoC tap installed on Dock pid \(pid)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        dpLog("DockAnchor: stopped")
    }

    // PoC: log-only. Does not drop events yet.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .mouseMoved {
            let loc = event.location
            dpLog("DockAnchor PoC: mouseMoved at (\(Int(loc.x)), \(Int(loc.y)))")
        }
        return Unmanaged.passUnretained(event)
    }

    private static func findDockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
    }
}

// Swift shim: CGEventTapCreateForPid is exposed via CGEvent.tapCreateForPid in newer SDKs,
// but the underlying C function has signature we can bridge ourselves if needed.
extension CGEvent {
    static func tapCreateForPid(
        pid: pid_t,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        return CGEventTapCreateForPid(pid, place, options, eventsOfInterest, callback, userInfo)
    }
}
```

- [ ] **Step 2: Wire a temporary call from AppDelegate**

In `DockPeek/App/AppDelegate.swift`, add a property near the other managers (around line 10):

```swift
    private let dockAnchorManager = DockAnchorManager()
```

At the bottom of `applicationDidFinishLaunching`, add:

```swift
        // TEMPORARY PoC — will be gated by a setting in Task 5
        dockAnchorManager.start()
```

At the top of `applicationWillTerminate`, add:

```swift
        dockAnchorManager.stop()
```

- [ ] **Step 3: Build**

Run: `make dev`
Expected: compiles clean (pre-existing deprecation warnings only), app launches, logs contain `DockAnchor: PoC tap installed on Dock pid <N>`.

- [ ] **Step 4: Validate the mechanism**

With the app running:
1. Move the mouse around the screen, including near the bottom edge of both primary and secondary displays.
2. Stream the app log:

Run: `log stream --predicate 'processImagePath CONTAINS "DockPeek"' --style compact | grep DockAnchor`

Expected: the `DockAnchor PoC: mouseMoved at (x, y)` line fires repeatedly as the mouse moves. Coordinates should reflect CG (top-left origin) coordinates spanning the full multi-display arrangement.

**GO/NO-GO:** if you see the events flowing, the mechanism works — proceed to Task 2. If you see zero events when the mouse moves, or only events at certain positions, STOP and report. The design assumption has failed and the approach must be reconsidered.

- [ ] **Step 5: Commit**

```bash
git add DockPeek/Core/DockAnchorManager.swift DockPeek/App/AppDelegate.swift
git commit -m "PoC: per-pid event tap on Dock with mouse-moved logging"
```

---

## Task 2: Drop events inside non-primary Dock trigger zones

**Files:**
- Modify: `DockPeek/Core/DockAnchorManager.swift` (add trigger-zone computation + event filtering)

**Goal:** The tap now drops mouseMoved events whose location falls in any non-primary display's Dock trigger zone (bottom 10 px for the default `bottom` orientation, or left/right 10 px per `com.apple.dock` `orientation` pref). With this in place, the Dock must stop relocating to secondary displays.

- [ ] **Step 1: Add orientation detection and zone computation**

Insert inside the `DockAnchorManager` class, after the `dockPID` property:

```swift
    private var triggerZones: [CGRect] = []
    private var dockOrientation: String = "bottom"  // "bottom" | "left" | "right"

    private func recomputeTriggerZones() {
        dockOrientation = UserDefaults(suiteName: "com.apple.dock")?
            .string(forKey: "orientation") ?? "bottom"

        guard let primary = NSScreen.screens.first else {
            triggerZones = []
            return
        }
        let primaryH = primary.frame.height

        var zones: [CGRect] = []
        for screen in NSScreen.screens where screen != primary {
            let f = screen.frame  // Cocoa (bottom-left origin)
            // Convert to CG (top-left origin) using primary height
            let cgMinX = f.minX
            let cgMinY = primaryH - f.maxY
            let cgMaxX = f.maxX
            let cgMaxY = primaryH - f.minY

            let thickness: CGFloat = 10
            let zone: CGRect
            switch dockOrientation {
            case "left":
                zone = CGRect(x: cgMinX, y: cgMinY,
                              width: thickness, height: cgMaxY - cgMinY)
            case "right":
                zone = CGRect(x: cgMaxX - thickness, y: cgMinY,
                              width: thickness, height: cgMaxY - cgMinY)
            default: // "bottom"
                zone = CGRect(x: cgMinX, y: cgMaxY - thickness,
                              width: cgMaxX - cgMinX, height: thickness)
            }
            zones.append(zone)
        }
        triggerZones = zones
        dpLog("DockAnchor: \(zones.count) trigger zone(s), orientation=\(dockOrientation)")
    }
```

- [ ] **Step 2: Call `recomputeTriggerZones()` from `start()`**

Inside `start()`, after the guard clauses and before `CGEvent.tapCreateForPid`, add:

```swift
        recomputeTriggerZones()
```

- [ ] **Step 3: Replace the PoC event handler with real filtering**

Replace the body of `handleEvent(type:event:)`:

```swift
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
        let loc = event.location
        for zone in triggerZones where zone.contains(loc) {
            // Drop this event — the Dock will not see it.
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
```

Also remove the PoC log line added in Task 1 (it's now inside the removed branch — no action needed since we replaced the whole function body).

- [ ] **Step 4: Build**

Run: `make dev`
Expected: clean compile.

- [ ] **Step 5: Validate: cursor freedom + Dock stays**

1. Arrange two displays (primary + at least one secondary). The Dock starts on primary.
2. Move cursor aggressively to the bottom-center of the secondary display and hold there.
3. Try the same at the bottom-left, bottom-right, and side edges of the secondary.

Expected:
- Cursor reaches the very bottom pixel of the secondary display — **no stickiness**.
- Dock does NOT appear on the secondary display.

If the Dock still moves: (a) confirm Dock orientation matches what `recomputeTriggerZones` read (log line), (b) widen `thickness` to 15 px and retry. Report findings.

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Core/DockAnchorManager.swift
git commit -m "Drop mouse-moved events in non-primary dock trigger zones"
```

---

## Task 3: Initial reposition when Dock starts on non-primary

**Files:**
- Modify: `DockPeek/Core/DockAnchorManager.swift`

**Goal:** At `start()`, detect whether the Dock is already on a non-primary display (e.g., user dragged it there before enabling the anchor). If so, perform a one-time synthetic mouse warp to the primary's bottom trigger point to pull the Dock to primary. After that, the tap prevents any further movement.

- [ ] **Step 1: Add AX-based detection of the Dock's current display**

Add these methods inside `DockAnchorManager`:

```swift
    /// True if Dock's first window lives on a non-primary screen.
    private func isDockOnNonPrimary() -> Bool {
        guard dockPID != 0 else { return false }
        let axApp = AXUIElementCreateApplication(dockPID)

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let first = windows.first else { return false }

        var posRef: AnyObject?
        guard AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &posRef) == .success,
              let p = posRef else { return false }

        var pos = CGPoint.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)

        guard let primary = NSScreen.screens.first else { return false }
        let primaryH = primary.frame.height
        let primaryCG = CGRect(
            x: primary.frame.minX,
            y: primaryH - primary.frame.maxY,
            width: primary.frame.width,
            height: primary.frame.height
        )
        return !primaryCG.contains(pos)
    }
```

- [ ] **Step 2: Add the one-time warp**

Add below `isDockOnNonPrimary()`:

```swift
    /// One-time synthetic cursor warp to the primary's trigger point.
    /// This is the ONLY situation in which we let the Dock move.
    private func warpDockToPrimary() {
        guard let primary = NSScreen.screens.first else { return }
        let primaryH = primary.frame.height
        let f = primary.frame

        let target: CGPoint
        switch dockOrientation {
        case "left":
            target = CGPoint(x: f.minX + 1, y: primaryH - f.midY)
        case "right":
            target = CGPoint(x: f.maxX - 1, y: primaryH - f.midY)
        default: // "bottom"
            target = CGPoint(x: f.midX, y: primaryH - f.minY - 1)
        }

        let original = CGEvent(source: nil)?.location ?? target
        dpLog("DockAnchor: warping cursor to primary trigger \(target) (restore to \(original))")

        // Briefly disable our tap so our synthetic events aren't filtered
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }

        // Hold at the trigger point for a few frames so the Dock latches
        for _ in 0..<6 {
            CGWarpMouseCursorPosition(target)
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Restore original position
        CGWarpMouseCursorPosition(original)

        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
```

- [ ] **Step 3: Invoke warp in `start()` after the tap is installed**

Inside `start()`, after the line that sets `runLoopSource = source`, add:

```swift
        if isDockOnNonPrimary() {
            DispatchQueue.main.async { [weak self] in
                self?.warpDockToPrimary()
            }
        }
```

- [ ] **Step 4: Build**

Run: `make dev`
Expected: clean compile.

- [ ] **Step 5: Validate initial reposition**

1. Disable the PoC trigger (temporarily comment out the `dockAnchorManager.start()` line in `AppDelegate`; `make kill && make dev`).
2. Without DockPeek active, move your cursor to the secondary display's bottom and wait for the Dock to appear there.
3. Uncomment `dockAnchorManager.start()`, `make dev`.

Expected: on launch, DockPeek sees the Dock on the non-primary, performs the warp, and the Dock visibly moves back to the primary. After that, regular Dock anchoring (Task 2) keeps it there.

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Core/DockAnchorManager.swift
git commit -m "Warp Dock to primary on startup if it's on a non-primary display"
```

---

## Task 4: Observers — Dock restart and display changes

**Files:**
- Modify: `DockPeek/Core/DockAnchorManager.swift`

**Goal:** When the Dock process dies/respawns (e.g., `killall Dock`), recreate the tap with the new pid. When the display configuration changes, recompute trigger zones and re-warp if needed. When `stop()` runs, detach all observers.

- [ ] **Step 1: Add observer tokens and helper methods**

Add these properties inside `DockAnchorManager`, after `dockOrientation`:

```swift
    private var dockTerminateObserver: NSObjectProtocol?
    private var dockLaunchObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
```

Add these methods near the bottom of the class, before the closing `}`:

```swift
    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        dockTerminateObserver = ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self?.handleDockTerminated()
        }

        dockLaunchObserver = ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self?.handleDockLaunched(pid: app.processIdentifier)
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenChanged()
        }
    }

    private func removeObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        if let o = dockTerminateObserver { ws.removeObserver(o); dockTerminateObserver = nil }
        if let o = dockLaunchObserver { ws.removeObserver(o); dockLaunchObserver = nil }
        if let o = screenChangeObserver { NotificationCenter.default.removeObserver(o); screenChangeObserver = nil }
    }

    private func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    private func handleDockTerminated() {
        dpLog("DockAnchor: Dock terminated — tearing down tap")
        tearDownTap()
        dockPID = 0
    }

    private func handleDockLaunched(pid: pid_t) {
        dpLog("DockAnchor: Dock relaunched pid=\(pid) — rebuilding tap")
        tearDownTap()
        dockPID = pid

        let mask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreateForPid(
            pid: pid,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<DockAnchorManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            dpLog("DockAnchor: relaunch tap failed pid=\(pid)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source

        // Give the relaunched Dock a moment to settle, then correct position if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.isDockOnNonPrimary() { self.warpDockToPrimary() }
        }
    }

    private func handleScreenChanged() {
        dpLog("DockAnchor: screen parameters changed — recomputing zones")
        recomputeTriggerZones()
        if isDockOnNonPrimary() {
            warpDockToPrimary()
        }
    }
```

- [ ] **Step 2: Call `installObservers()` in `start()` and `removeObservers()` in `stop()`**

Inside `start()`, at the end (after the post-tap warp block):

```swift
        installObservers()
```

Inside `stop()`, at the top:

```swift
        removeObservers()
```

Also make `stop()` use the new `tearDownTap()` helper. Replace the body of `stop()` with:

```swift
    func stop() {
        removeObservers()
        tearDownTap()
        triggerZones = []
        dockPID = 0
        dpLog("DockAnchor: stopped")
    }
```

- [ ] **Step 3: Build**

Run: `make dev`
Expected: clean compile.

- [ ] **Step 4: Validate Dock restart handling**

1. App running with DockAnchor active (Task 3 smoke test).
2. In a terminal: `killall Dock`
3. Watch the log: expect `DockAnchor: Dock terminated — tearing down tap` followed within ~1 s by `DockAnchor: Dock relaunched pid=N — rebuilding tap`.
4. Move cursor to secondary-display bottom again — Dock still stays on primary.

- [ ] **Step 5: Validate display-change handling**

1. With DockAnchor active, log line `DockAnchor: N trigger zone(s), orientation=bottom` should appear at startup.
2. Unplug/replug a secondary display (or toggle mirroring).
3. Expect `DockAnchor: screen parameters changed — recomputing zones` followed by `DockAnchor: N trigger zone(s)` with the new count.

- [ ] **Step 6: Commit**

```bash
git add DockPeek/Core/DockAnchorManager.swift
git commit -m "Handle Dock restart and display changes in DockAnchorManager"
```

---

## Task 5: AppState toggle + AppDelegate lifecycle wiring

**Files:**
- Modify: `DockPeek/App/AppState.swift`
- Modify: `DockPeek/App/AppDelegate.swift`

**Goal:** Add the `anchorDockToPrimary` setting (default off). `AppDelegate` exposes `applyDockAnchorSetting()` which starts or stops the manager based on the setting. Remove the temporary unconditional `start()` from Task 1. Integrate into the accessibility permission lifecycle.

- [ ] **Step 1: Add the @AppStorage in AppState**

In `DockPeek/App/AppState.swift`, add a line after the `launchAtLogin` storage:

```swift
    @AppStorage("anchorDockToPrimary") var anchorDockToPrimary = false
```

- [ ] **Step 2: Add `applyDockAnchorSetting()` to AppDelegate**

In `DockPeek/App/AppDelegate.swift`, add this method somewhere reasonable (e.g., near `startEventTap()`):

```swift
    /// Start or stop the Dock anchor based on the current setting and
    /// accessibility permission. Safe to call from anywhere, anytime.
    func applyDockAnchorSetting() {
        if appState.anchorDockToPrimary && AccessibilityManager.shared.isAccessibilityGranted {
            dockAnchorManager.start()
        } else {
            dockAnchorManager.stop()
        }
    }
```

- [ ] **Step 3: Replace the temporary call in `applicationDidFinishLaunching`**

In `applicationDidFinishLaunching`, find and remove:

```swift
        // TEMPORARY PoC — will be gated by a setting in Task 5
        dockAnchorManager.start()
```

Instead, inside the `if AccessibilityManager.shared.isAccessibilityGranted { … }` block, add after the existing `startHoverMonitor()` call:

```swift
            applyDockAnchorSetting()
```

And in `startAccessibilityPolling()`, inside the `if AccessibilityManager.shared.isAccessibilityGranted { … }` block after the existing `startHoverMonitor()` call, also add:

```swift
                self.applyDockAnchorSetting()
```

- [ ] **Step 4: Stop DockAnchor when accessibility is revoked**

In `startPermissionMonitor()`, find the block that triggers when permission is revoked (`if !AccessibilityManager.shared.isAccessibilityGranted`). Inside that block, after `self.stopHoverMonitor()`, add:

```swift
                self.dockAnchorManager.stop()
```

- [ ] **Step 5: Build**

Run: `make dev`
Expected: clean compile. Default setting is off → DockAnchor does NOT activate. Log line `DockAnchor: PoC tap installed …` should NOT appear.

- [ ] **Step 6: Validate toggle behavior via defaults (temporary)**

Since Task 6 adds the UI, test via UserDefaults directly for now:

```
defaults write com.dockpeek.app anchorDockToPrimary -bool true
make kill && make dev
```

Expected: log shows `DockAnchor: PoC tap installed on Dock pid N`. Mouse-to-secondary-bottom test — Dock stays on primary.

Revert:
```
defaults delete com.dockpeek.app anchorDockToPrimary
```

- [ ] **Step 7: Commit**

```bash
git add DockPeek/App/AppState.swift DockPeek/App/AppDelegate.swift
git commit -m "Gate DockAnchor behind anchorDockToPrimary setting"
```

---

## Task 6: Settings toggle + localization

**Files:**
- Modify: `DockPeek/Utilities/L10n.swift`
- Modify: `DockPeek/UI/SettingsView.swift`

**Goal:** A single Toggle in the General tab labeled "Anchor dock to primary display" (en) / "Dock을 메인 디스플레이에 고정" (ko), calling `applyDockAnchorSetting()` on change.

- [ ] **Step 1: Add localization keys**

In `DockPeek/Utilities/L10n.swift`, add the accessor under the General-Tab section (around line 50):

```swift
    static var anchorDockToPrimary: String { s("anchorDockToPrimary") }
```

In the English dictionary, add after `"launchAtLogin": "Launch at login",`:

```swift
        "anchorDockToPrimary": "Anchor dock to primary display",
```

In the Korean dictionary, add after `"launchAtLogin": "로그인 시 자동 실행",`:

```swift
        "anchorDockToPrimary": "Dock을 메인 디스플레이에 고정",
```

- [ ] **Step 2: Add the Toggle in the General tab**

In `DockPeek/UI/SettingsView.swift`, locate the `generalTab` `VStack`. Below the existing `Toggle(L10n.launchAtLogin, …)` block and its `.onChange(…)` closure, insert:

```swift
            Toggle(L10n.anchorDockToPrimary, isOn: $appState.anchorDockToPrimary)
                .onChange(of: appState.anchorDockToPrimary) { _, _ in
                    (NSApp.delegate as? AppDelegate)?.applyDockAnchorSetting()
                }
```

- [ ] **Step 3: Build**

Run: `make dev`
Expected: clean compile. Open Settings (Cmd+,); General tab now shows the new toggle below "Launch at login".

- [ ] **Step 4: End-to-end validation**

1. Open Settings → General. Toggle **on** "Anchor dock to primary display".
2. Expect log `DockAnchor: PoC tap installed on Dock pid N` immediately.
3. Mouse to secondary-bottom — Dock stays on primary, cursor freely reaches the edge.
4. Toggle **off**. Expect log `DockAnchor: stopped`. Mouse to secondary-bottom — Dock relocates to secondary (normal macOS behavior is back).
5. Toggle on again — Dock is pulled back to primary via the warp.
6. `killall Dock` while the anchor is on — Dock respawns on primary.

- [ ] **Step 5: Commit**

```bash
git add DockPeek/Utilities/L10n.swift DockPeek/UI/SettingsView.swift
git commit -m "Add Anchor dock to primary display toggle in Settings"
```

---

## Task 7: Version bump, dist, and release

**Files:**
- Modify: `Makefile`
- Modify: `DockPeek/Info.plist`

**Goal:** Ship 1.5.11 through the existing release pipeline (GitHub release + `zerry-lab/homebrew-tap` cask update).

- [ ] **Step 1: Bump Makefile version**

In `Makefile`, change:

```makefile
VERSION     := 1.5.10
```

to:

```makefile
VERSION     := 1.5.11
```

- [ ] **Step 2: Bump Info.plist**

In `DockPeek/Info.plist`, change:

```xml
    <key>CFBundleShortVersionString</key>
    <string>1.5.10</string>
```

to:

```xml
    <key>CFBundleShortVersionString</key>
    <string>1.5.11</string>
```

- [ ] **Step 3: Commit the bump**

```bash
git add Makefile DockPeek/Info.plist
git commit -m "Bump version to 1.5.11"
```

- [ ] **Step 4: Build release zip**

Run: `make kill && make dist`
Expected: last line prints `<sha256>  DockPeek.zip`. **Record the SHA256** — needed for the cask update below.

- [ ] **Step 5: Push main + tag**

```bash
git push origin main
git tag v1.5.11
git push origin v1.5.11
```

- [ ] **Step 6: Create GitHub release**

```bash
gh release create v1.5.11 DockPeek.zip --title "v1.5.11" --notes "$(cat <<'EOF'
## 변경 사항

- **Dock 메인 디스플레이 고정 (신규)**: 일반 탭의 토글로 활성화. Dock이 서브 모니터로 이동하지 않도록 고정. 마우스 커서는 서브 모니터 바닥까지 자유롭게 움직임(벽에 막힘 없음). macOS 기본값과 달리 DockPeek 프로세스-범위 이벤트 필터링을 사용해 커서 간섭과 Dock 깜빡임이 모두 0.

## Changes

- **Anchor dock to primary display (new)**: Opt-in toggle in the General tab. The Dock no longer auto-relocates to secondary displays. Unlike typical tools that drop mouse events system-wide, DockPeek filters events scoped to the Dock's process only, so the cursor has zero stickiness on secondary displays and the Dock never flickers on the wrong monitor.
EOF
)"
```

- [ ] **Step 7: Update the brew cask**

Replace `<SHA256>` with the value printed in Step 4.

```bash
CUR_SHA=$(gh api repos/zerry-lab/homebrew-tap/contents/Casks/dockpeek.rb --jq '.sha')
NEW_CONTENT=$(cat <<'EOF'
cask "dockpeek" do
  version "1.5.11"
  sha256 "<SHA256>"

  url "https://github.com/ongjin/dockpeek/releases/download/v#{version}/DockPeek.zip"
  name "DockPeek"
  desc "Windows-style Dock window preview for macOS"
  homepage "https://github.com/ongjin/dockpeek"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "DockPeek.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/DockPeek.app"]
  end

  uninstall quit: "com.dockpeek.app"

  zap trash: [
    "~/Library/Preferences/com.dockpeek.app.plist",
  ]

  caveats <<~EOS
    FIRST LAUNCH (important — app is self-signed, not notarized):

    1. Open DockPeek — macOS will block it
    2. Go to: System Settings → Privacy & Security
    3. Scroll down to Security — click "Open Anyway" next to the DockPeek message
    4. Click "Open" in the confirmation dialog

    REQUIRED PERMISSIONS (grant after first launch):

    1. Accessibility — System Settings → Privacy & Security → Accessibility → Enable DockPeek
    2. Screen Recording — System Settings → Privacy & Security → Screen Recording → Enable DockPeek
  EOS
end
EOF
)
B64=$(printf '%s' "$NEW_CONTENT" | base64)
gh api --method PUT repos/zerry-lab/homebrew-tap/contents/Casks/dockpeek.rb \
  -f message="Bump dockpeek to 1.5.11" \
  -f sha="$CUR_SHA" \
  -f content="$B64" --jq '.commit.html_url'
```

Expected: prints the commit URL on the brew tap repo.

---

## Self-Review Notes

- **Spec coverage:** Architecture (Task 1+2), data flow per-event filtering (Task 2), initial reposition (Task 3), Dock restart (Task 4), display change (Task 4), settings observer pattern via `onChange` (Task 6 calling `applyDockAnchorSetting()` added in Task 5), accessibility revocation tie-in (Task 5 Step 4), trigger-zone geometry incl. orientation (Task 2), out-of-scope notes respected (no user-selectable anchor, no reactive relocation). PoC task corresponds to the spec's "Risk and Feasibility Check" — explicit GO/NO-GO.
- **Placeholder scan:** No TBD/TODO. Every code step shows concrete code. `<SHA256>` in Task 7 is a literal substitution instruction, not a placeholder for logic.
- **Type consistency:** `DockAnchorManager`, `triggerZones`, `dockPID`, `eventTap`, `runLoopSource`, `dockOrientation` used consistently. `CGEvent.tapCreateForPid` helper defined in Task 1 and referenced in Task 4. `applyDockAnchorSetting()` defined in Task 5, called from Task 6. `anchorDockToPrimary` key identical in AppState, UserDefaults, L10n dictionaries, and Toggle binding.
