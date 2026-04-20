# Dock Anchor to Primary Display

Date: 2026-04-20

## Problem

On multi-display macOS setups, the Dock auto-relocates to whichever display the cursor approaches at the bottom edge. Users who prefer the Dock to stay on the primary display have to tolerate this. Existing tools (DockAnchor, MIT-licensed) solve it by intercepting mouse-moved events at the session level and dropping them in the trigger zones of non-anchor displays. That works but introduces two problems that the user finds unacceptable:

1. **Cursor interference.** Session-level event filtering drops events globally, so the cursor physically sticks 10 px from the bottom edge on non-anchor displays. The user has tried this approach before and calls it "마우스가 벽에 가로막혀있는듯한 느낌" (feels like the mouse hit a wall).
2. **Flicker.** Any approach that lets the Dock move and then relocates it back produces a visible jump on the wrong display, even if only for ~50 ms.

Goal: anchor the Dock to the primary display with **zero cursor interference** and **zero dock flicker**.

## Key Insight

DockAnchor's filtering prevents the Dock from moving because the Dock subscribes to the standard session event stream. If we filter the stream **only for the Dock's process**, the Dock still doesn't see the mouse reaching trigger zones — so it doesn't move — but every other process (including the window server's cursor renderer) sees events normally, so the cursor has no stickiness.

The public API for this is `CGEventTapCreateForPid(pid:place:options:eventsOfInterest:callback:userInfo:)`, available since macOS 10.11.

## Design

### Architecture

A new, self-contained unit `DockAnchorManager` owns the per-process event tap, the list of non-primary trigger zones, and the lifecycle bookkeeping (Dock restart, display configuration changes). `AppDelegate` owns one instance and starts/stops it based on an `AppState` toggle.

```
AppDelegate
    owns DockAnchorManager (1)
    owns AppState (1)

AppState
    @AppStorage("anchorDockToPrimary"): Bool  // default false

DockAnchorManager
    start()                        // create per-pid tap, initial reposition if needed
    stop()                         // tear down tap, detach observers
    private dockPID: pid_t?        // cached Dock PID
    private eventTap: CFMachPort?
    private runLoopSource: CFRunLoopSource?
    private triggerZones: [CGRect] // non-primary trigger zones (CG coords)
    private dockOrientation: String // "bottom" | "left" | "right"
    // observers: Dock terminate/launch, screen parameter changes, permission loss
```

### Files

- **Create** `DockPeek/Core/DockAnchorManager.swift` — new unit, ~200 lines, single responsibility.
- **Modify** `DockPeek/App/AppState.swift` — add one `@AppStorage` line.
- **Modify** `DockPeek/App/AppDelegate.swift` — instantiate manager, toggle start/stop based on the setting, clean up on terminate.
- **Modify** `DockPeek/UI/SettingsView.swift` — one `Toggle` in the General tab.
- **Modify** `DockPeek/Utilities/L10n.swift` — two label keys (en + ko).

### Data Flow

**Enabling the anchor:**

```
User toggles on in Settings  →  AppState.anchorDockToPrimary = true
AppDelegate observes the value change  →  dockAnchorManager.start()

start() {
    find Dock pid via NSRunningApplication(bundleIdentifier: "com.apple.dock")
    compute triggerZones for every non-primary screen (bottom 10 px, or left/right 10 px
      per com.apple.dock orientation preference)
    if isDockOnNonPrimary():
        perform a one-time synthetic mouse warp to the primary screen's bottom trigger point
        (this is the only time the Dock is allowed to move under our control)

    where isDockOnNonPrimary() queries the Dock's AX window position:
        AXUIElementCreateApplication(dockPID) → kAXWindowsAttribute → first window's kAXPositionAttribute
        compare that CG point against each NSScreen.frame (converted to CG coords); return true
        if the containing screen is not the primary.
    create per-pid event tap on the Dock pid, .headInsertEventTap, filtering mouseMoved
    install in the main run loop, enable
    register observers:
        NSWorkspace.didTerminateApplicationNotification  (Dock died)
        NSWorkspace.didLaunchApplicationNotification     (Dock restarted)
        NSApplication.didChangeScreenParametersNotification  (display layout changed)
}
```

**Per-event behavior (in the tap callback):**

```
event type: mouseMoved (only type we register)
location = event.location  (CG coordinates, top-left origin)

if location ∈ any triggerZone:
    return nil              // Dock does not receive this event
else:
    return passUnretained(event)   // Dock sees a normal mouseMoved
```

Dropping a mouse-moved event at `.headInsertEventTap` for a specific pid removes that event from that pid's input queue only. The event still reaches every other process and the window server's cursor rendering, so the visible cursor is untouched.

**Dock restart:**

Dock processes die and respawn occasionally (e.g., user runs `killall Dock`, or system-initiated restart). Our observer detects this:

```
didTerminate(app) where app.bundleIdentifier == "com.apple.dock"  →  tap becomes stale, tear down
didLaunch(app)    where app.bundleIdentifier == "com.apple.dock"  →  recreate tap for new pid,
                                                                     reposition Dock if needed
```

There is a brief window (Dock terminated → respawned → our observer fires → new tap installed) during which Dock is unsupervised. Empirically this is sub-second, but the Dock also doesn't normally move during that instant (it's not receiving events during restart). The relaunch handler does a single post-install position check: if the new Dock came up on a non-primary display, we perform the same one-time warp used at `start()`.

**Display reconfiguration:**

`didChangeScreenParametersNotification` fires when displays are attached, detached, rearranged, or primary changes. Handler: recompute `triggerZones` and, if primary changed and Dock is on a non-primary display, do a one-time warp. No re-creation of the tap — it's still valid for the same Dock pid.

**Disabling the anchor:**

```
User toggles off  →  dockAnchorManager.stop()

stop() {
    disable tap, release CFMachPort
    remove run-loop source
    detach observers
    triggerZones = []
}
```

The Dock resumes its normal auto-follow behavior immediately.

### Trigger Zone Geometry

`com.apple.dock` defaults key `orientation` is one of `"bottom"`, `"left"`, `"right"` (AppDelegate already reads this). For every non-primary `NSScreen`:

```
frameCG = screen.frame converted from Cocoa (bottom-left) to CG (top-left) coords
                using the primary screen's height

switch orientation {
  case "bottom":  zone = CGRect(x: frameCG.minX, y: frameCG.maxY - 10,
                                width: frameCG.width, height: 10)
  case "left":    zone = CGRect(x: frameCG.minX, y: frameCG.minY,
                                width: 10, height: frameCG.height)
  case "right":   zone = CGRect(x: frameCG.maxX - 10, y: frameCG.minY,
                                width: 10, height: frameCG.height)
}
```

10 px matches DockAnchor's empirical value — wide enough to reliably catch the Dock's trigger detection, narrow enough that we don't accidentally block events far from the edge (though the per-pid tap means this doesn't visibly matter for the user).

### Settings UI

In the General tab (General is now the only configuration tab after the 1.5.10 simplification), add one toggle above the Permissions section:

```swift
Toggle(L10n.anchorDockToPrimary, isOn: $appState.anchorDockToPrimary)
```

Label: `Anchor dock to primary display` / `Dock을 메인 디스플레이에 고정`.

Default: **off**. This is an override of macOS default behavior; opt-in matches existing behavior-override toggles (e.g., Launch at login).

`AppDelegate` observes the setting via a SwiftUI `.onChange(of: appState.anchorDockToPrimary)` modifier attached to the Toggle. On change, it calls `(NSApp.delegate as? AppDelegate)?.applyDockAnchorSetting()` which inspects `appState.anchorDockToPrimary` and calls `dockAnchorManager.start()` or `.stop()` accordingly. No Combine / no UserDefaults notification observer reintroduced.

### Lifecycle Integration

In `AppDelegate.applicationDidFinishLaunching`:

```
if AccessibilityManager.shared.isAccessibilityGranted {
    ...existing setup...
    if appState.anchorDockToPrimary {
        dockAnchorManager.start()
    }
}
```

In `applicationWillTerminate`:

```
dockAnchorManager.stop()
```

When accessibility permission is revoked mid-session (existing `permissionMonitorTimer` logic in `AppDelegate`), also call `dockAnchorManager.stop()` because per-pid taps require accessibility.

### Risk and Feasibility Check

The design rests on the assumption that `CGEventTapCreateForPid` targeting the Dock pid can drop mouseMoved events and thereby prevent Dock's trigger-zone detection. This is strongly suggested by:

- DockAnchor demonstrates Dock's auto-relocation is event-driven (session-level drop works → per-pid drop should work equivalently for the scoped process).
- `CGEventTapCreateForPid` is public API available since 10.11 with Accessibility permission.

But per-pid taps targeting system processes can have quirks on newer macOS. **Task 1 of implementation is a minimal PoC** that creates the tap on the Dock pid, logs every mouseMoved it sees, and confirms that dropping events within the trigger zone prevents Dock from relocating. If the PoC fails, the whole approach is reconsidered before any UI work.

### Out of Scope

- User-selectable anchor display (only primary is supported — matches the user's requirement "메인모니터에 고정").
- Auto-hide Dock handling (existing DockPeek code handles it for other purposes; this feature inherits whatever the user's Dock setting is).
- Relocation beyond the one-time initial warp (we rely on the tap to prevent movement, not on reactive relocation).
- Multiple profiles / per-display anchoring (DockAnchor has this; we don't need it for v1).

### Edge Cases

- **Single display.** `triggerZones` is empty; the tap runs but never drops. Negligible CPU (tap callback returns passUnretained immediately).
- **Dock not running at `start()`.** Rare, but possible briefly after system wake. Retry via `didLaunchApplicationNotification`; until then the feature is inactive but doesn't crash.
- **User quits DockPeek.** `applicationWillTerminate` calls `stop()`, which disables the tap. Dock becomes free again — fine.
- **Permission revoked.** Existing permission monitor stops event tap + hover; add one line to also stop the DockAnchor tap.

### Testing

Automated: none (project has no test target). Manual verification at each task:

1. **PoC task:** with anchor enabled, move cursor to bottom of secondary display — log confirms callback fires and event is dropped; observe Dock stays on primary.
2. **Cursor freedom:** move cursor all the way to the bottom-center of a secondary display — cursor reaches the last pixel without stickiness.
3. **No flicker:** with Dock on primary and anchor enabled, mouse around aggressively on secondary — Dock never appears on secondary.
4. **Initial reposition:** with anchor disabled, force Dock onto secondary (move cursor there, wait for it to appear). Enable anchor — Dock warps to primary once.
5. **Dock restart:** with anchor enabled, `killall Dock` — Dock respawns on primary; tap re-created without user intervention.
6. **Display hotplug:** connect/disconnect secondary — trigger zones recomputed; no crashes; Dock stays on primary.
7. **Toggle off:** disable anchor — Dock regains free movement behavior immediately.
