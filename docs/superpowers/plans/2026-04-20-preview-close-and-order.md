# Preview Close Responsiveness + Stable Window Ordering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Dock preview's X button close a window instantly (no 300ms delay / no re-render), and stabilize thumbnail order so new windows always appear at the end.

**Architecture:** Two independent changes in the same pass. (1) `PreviewPanel` gains a `removeWindow(id:)` method that mutates its stored window array and rebuilds the SwiftUI hosting view once — `AppDelegate.onClose` calls that directly instead of the current fetch-and-re-show dance, and `WindowManager.closeWindow` invalidates its per-PID caches so the next query is correct. (2) `WindowManager` adds a persisted `[bundleID: [CGWindowID]]` map; `windowsForApp(pid:)` orders results by that map (existing IDs first in stored order, new IDs appended in CG natural order), then saves the map back to `UserDefaults`.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Accessibility (AX) APIs, UserDefaults. Build via `make dev` (see `Makefile`). No unit test infrastructure — verification is manual with the running app.

**Spec:** `docs/superpowers/specs/2026-04-20-preview-close-and-order-design.md`

**Testing note:** The project has no unit test target. Each task verifies via `make dev` (compile + launch) plus a scripted manual check. Do not add a test target — that is out of scope.

---

## Task 1: Add per-PID cache invalidation inside `closeWindow`

**Files:**
- Modify: `DockPeek/Core/WindowManager.swift` (function `closeWindow`, around lines 326–342)

**Why first:** The `onClose` rewrite in Task 3 relies on `windowsForApp` returning fresh results right after close — otherwise the 0.5s `windowListCache` can still return the closed window. Doing this first keeps later tasks self-contained.

- [ ] **Step 1: Read the current `closeWindow` and the two cache properties**

Open `DockPeek/Core/WindowManager.swift`. Confirm these still exist:
- `windowListCache: [pid_t: ([[String: Any]], Date)]` (around line 37)
- `axWindowIDsCache: [pid_t: (Set<CGWindowID>, Date)]` (around line 41)
- `closeWindow(windowID:pid:)` (around lines 326–342)

- [ ] **Step 2: Update `closeWindow` to invalidate both caches after the AX press**

Replace the current `closeWindow` body with:

```swift
func closeWindow(windowID: CGWindowID, pid: pid_t) {
    guard let axWindow = findAXWindow(for: windowID, pid: pid) else {
        dpLog("closeWindow: no AX match for window \(windowID)")
        return
    }

    // Get the close button and press it
    var closeRef: AnyObject?
    guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success else {
        dpLog("closeWindow: no close button for window \(windowID)")
        return
    }
    // Safe: AXCloseButtonAttribute returns an AXUIElement
    let closeButton = closeRef as! AXUIElement
    AXUIElementPerformAction(closeButton, kAXPressAction as CFString)

    // Invalidate caches so the next windowsForApp(pid:) sees the post-close state
    windowListCache.removeValue(forKey: pid)
    axWindowIDsCache.removeValue(forKey: pid)

    dpLog("Closed window \(windowID)")
}
```

- [ ] **Step 3: Build to verify compile**

Run: `make dev`
Expected: `Compiling...` → `Binary updated. Launching...` with no compiler errors. The app launches.

- [ ] **Step 4: Smoke test — existing close still works**

With the running app:
1. Open two Chrome/Safari windows.
2. Click the app's Dock icon → preview appears.
3. Click X on a thumbnail.

Expected: The window closes. (UI latency still ~300ms — that's fixed in Task 3. This task only verifies we didn't break close.)

- [ ] **Step 5: Commit**

```bash
git add DockPeek/Core/WindowManager.swift
git commit -m "Invalidate per-PID caches inside closeWindow"
```

---

## Task 2: Add persistent window ordering to `WindowManager`

**Files:**
- Modify: `DockPeek/Core/WindowManager.swift`

**What this task does:** Adds a `windowOrderByBundle: [String: [CGWindowID]]` map persisted to `UserDefaults`. Rewrites `windowsForApp(pid:)` to return results in that order, appending new IDs to the end.

- [ ] **Step 1: Add the stored property, key, and load helper**

Inside the `WindowManager` class, immediately below the `axWindowIDsCache` block (around line 42), add:

```swift
/// Per-app stable window order. Keyed by bundleID so restarts of the target
/// app (which generate fresh CGWindowIDs) naturally reset the order.
/// Persisted to UserDefaults; see `loadWindowOrder` / `saveWindowOrder`.
private var windowOrderByBundle: [String: [CGWindowID]] = [:]
private let windowOrderDefaultsKey = "windowOrderByBundle"
```

Then add an `init()` that loads the map, below the `isPreviewVisible` property:

```swift
init() {
    loadWindowOrder()
}

private func loadWindowOrder() {
    guard let raw = UserDefaults.standard.dictionary(forKey: windowOrderDefaultsKey) else { return }
    var result: [String: [CGWindowID]] = [:]
    for (bundle, value) in raw {
        if let nums = value as? [NSNumber] {
            result[bundle] = nums.map { CGWindowID($0.uint32Value) }
        }
    }
    windowOrderByBundle = result
    dpLog("Loaded window order for \(result.count) bundle(s)")
}

private func saveWindowOrder() {
    var serializable: [String: [NSNumber]] = [:]
    for (bundle, ids) in windowOrderByBundle {
        serializable[bundle] = ids.map { NSNumber(value: UInt32($0)) }
    }
    UserDefaults.standard.set(serializable, forKey: windowOrderDefaultsKey)
}
```

- [ ] **Step 2: Rewrite the tail of `windowsForApp(pid:)` to order by the stored map**

Locate `windowsForApp(pid:includeMinimized:)` (around lines 49–113). Replace the final block (from the `// Cross-reference with AX windows ...` comment through the `return windows`) with:

```swift
    // Cross-reference with AX windows to filter out overlays/helper windows.
    // AX kAXWindowsAttribute only returns "real" user-facing windows,
    // excluding Chrome translation bars, tooltips, popovers, etc.
    let axIDs = axWindowIDs(for: pid)
    if !axIDs.isEmpty {
        let before = windows.count
        windows = windows.filter { axIDs.contains($0.id) }
        if windows.count != before {
            dpLog("AX filter: \(before) → \(windows.count) windows for PID \(pid)")
        }
    }

    // Apply stable per-bundle ordering. New windows go to the end; existing
    // windows keep their prior position; closed windows drop out.
    if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let currentIDs = Set(byID.keys)
        let stored = windowOrderByBundle[bundleID] ?? []

        var orderedIDs: [CGWindowID] = stored.filter { currentIDs.contains($0) }
        let already = Set(orderedIDs)
        for w in windows where !already.contains(w.id) {
            orderedIDs.append(w.id)
        }

        if orderedIDs != stored {
            windowOrderByBundle[bundleID] = orderedIDs
            saveWindowOrder()
        }

        windows = orderedIDs.compactMap { byID[$0] }
    }

    dpLog("Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized))")
    return windows
}
```

Note: the closing `}` is the end of `windowsForApp`. Do not duplicate it.

- [ ] **Step 3: Build**

Run: `make dev`
Expected: compile succeeds, app launches.

- [ ] **Step 4: Manual order test**

1. Quit any running DockPeek. Delete prior state to start clean:
   ```bash
   defaults delete com.dockpeek.app windowOrderByBundle 2>/dev/null || true
   ```
2. Open three Chrome windows (name them mentally A, B, C by title or visible content).
3. Run `make dev`. Click the Chrome Dock icon → note thumbnail order (call it order1).
4. Click the first thumbnail to activate that window.
5. Click the Chrome Dock icon again → note thumbnail order (order2).

Expected: `order2 == order1`. (Without this change, the activated window would have jumped to the front.)

- [ ] **Step 5: Manual "new window appended" test**

Continuing from Step 4:
1. Preview is visible. Dismiss it (Esc or click away).
2. Open a new Chrome window (Cmd+N).
3. Click the Chrome Dock icon.

Expected: the four thumbnails are in order1 with the new one last.

- [ ] **Step 6: Manual persistence test**

1. Quit DockPeek: `make kill`.
2. Leave Chrome running with the four windows.
3. `make dev` again, click the Chrome Dock icon.

Expected: same order as Step 5.

- [ ] **Step 7: Commit**

```bash
git add DockPeek/Core/WindowManager.swift
git commit -m "Persist per-bundle window order, append new windows to end"
```

---

## Task 3: Instant-remove thumbnail on close

**Files:**
- Modify: `DockPeek/UI/PreviewPanel.swift` (add a new method)
- Modify: `DockPeek/App/AppDelegate.swift` (rewrite the `onClose` closure inside `showPreviewForWindows`)

**What this task does:** When X is clicked, drop the thumbnail from the panel's state immediately (no 300ms wait, no re-query, no thumbnail regeneration). If count drops below 2, dismiss.

- [ ] **Step 1: Add `removeWindow(id:)` to `PreviewPanel`**

Open `DockPeek/UI/PreviewPanel.swift`. Immediately after the `updateThumbnails(_:)` method (around line 129), add:

```swift
/// Remove a single window card from the visible panel without re-fetching
/// the window list or regenerating thumbnails. If fewer than 2 windows
/// remain, the panel is dismissed.
func removeWindow(id: CGWindowID) {
    guard isVisible,
          let onSelect = storedOnSelect,
          let onClose = storedOnClose,
          let onSnap = storedOnSnap,
          let onDismiss = storedOnDismiss,
          let onHoverWindow = storedOnHoverWindow else { return }

    let filtered = storedWindows.filter { $0.id != id }
    if filtered.count < 2 {
        dismissPanel()
        return
    }

    storedWindows = filtered

    // Clamp the keyboard selection so we never point past the end
    if navState.selectedIndex >= filtered.count {
        navState.selectedIndex = filtered.count - 1
    }

    let content = PreviewContentView(
        windows: filtered,
        thumbnailSize: storedThumbnailSize,
        showTitles: storedShowTitles,
        onSelect: onSelect,
        onClose: onClose,
        onSnap: onSnap,
        onDismiss: onDismiss,
        onHoverWindow: onHoverWindow,
        navState: navState
    )
    if let hosting = contentView as? NSHostingView<AnyView> {
        hosting.rootView = AnyView(content)
    }
}
```

- [ ] **Step 2: Rewrite `onClose` in `AppDelegate.showPreviewForWindows`**

Open `DockPeek/App/AppDelegate.swift`. Find the `onClose` closure in `showPreviewForWindows` (around lines 910–922). Replace it with:

```swift
            onClose: { [weak self] win in
                guard let self else { return }
                self.highlightOverlay.hide()
                // Immediately drop the card from the panel; no 300ms wait,
                // no re-render, no thumbnail regeneration. If count drops
                // below 2 the panel handles its own dismissal.
                self.previewPanel.removeWindow(id: win.id)
                if !self.previewPanel.isVisible {
                    self.previewIsVisible = false
                }
                // Fire the AX close. closeWindow invalidates its caches
                // so any follow-up query reflects the close.
                self.windowManager.closeWindow(windowID: win.id, pid: win.ownerPID)
            },
```

- [ ] **Step 3: Build**

Run: `make dev`
Expected: compile succeeds, app launches.

- [ ] **Step 4: Manual instant-close test**

1. Open three Chrome windows.
2. Click the Chrome Dock icon → preview.
3. Click the X on the middle thumbnail.

Expected:
- The middle thumbnail disappears *immediately* (no visible ~300ms hang).
- The two remaining thumbnails stay in their prior positions (no reshuffle).
- The Chrome window actually closes.

- [ ] **Step 5: Manual "dismiss when one left" test**

Continuing:
1. Click X on another thumbnail.

Expected: panel dismisses cleanly (only one window would remain).

- [ ] **Step 6: Manual "close then reopen preview" test**

1. Open three Chrome windows (call the visible order A, B, C from the current preview).
2. Preview → click X on B. B disappears instantly, A and C remain.
3. Dismiss preview (Esc).
4. Open a new Chrome window D.
5. Preview again.

Expected: order is A, C, D. (A and C held position; D appended.)

- [ ] **Step 7: Commit**

```bash
git add DockPeek/UI/PreviewPanel.swift DockPeek/App/AppDelegate.swift
git commit -m "Instant-remove closed thumbnail from preview panel"
```

---

## Task 4: End-to-end acceptance run

**Files:** none modified.

**Purpose:** Walk the full spec test plan to confirm all requirements are met together.

- [ ] **Step 1: Reset persistence**

```bash
make kill
defaults delete com.dockpeek.app windowOrderByBundle 2>/dev/null || true
```

- [ ] **Step 2: Launch fresh**

Run: `make dev`

- [ ] **Step 3: Run the full spec test sequence**

From `docs/superpowers/specs/2026-04-20-preview-close-and-order-design.md` — Testing section:

1. Open 3 Chrome windows, preview → note order.
2. Click a thumbnail to activate it. Preview again → order unchanged.
3. Close one via X → thumbnail disappears instantly, no delay, no reshuffle.
4. Open a new Chrome window. Preview → new window appears at the end.
5. Close down to one window via X → panel dismisses.
6. Quit DockPeek (`make kill`), relaunch (`make dev`) with Chrome still running → order preserved.
7. Quit Chrome entirely and reopen → preview order resets naturally.

Expected: every step matches its description.

- [ ] **Step 4: If anything fails, stop and report**

If a step fails, do not patch silently. Report which step failed, what you saw, and what you expected. The implementation may need to loop back to the relevant task.

- [ ] **Step 5: Commit (empty) to mark acceptance**

```bash
git commit --allow-empty -m "Verify preview close + order behavior end-to-end"
```

---

## Self-Review Notes

- **Spec coverage:** Section 1 (Instant close) → Tasks 1 + 3. Section 2 (Stable ordering) → Task 2. Section 3 (Cache invalidation on close) → Task 1. Files Touched list matches tasks. Edge cases covered: bundleID nil (Task 2 skips ordering block), corrupt defaults (Task 2 `loadWindowOrder` only accepts `[NSNumber]`), close while thumbnail loading (Task 3 filters by id regardless of thumbnail state), keyboard selection after removal (Task 3 clamps `navState.selectedIndex`).
- **Placeholder scan:** No TBDs, no "handle edge cases", no "similar to Task N". Each code step shows complete code.
- **Type consistency:** `removeWindow(id: CGWindowID)` used consistently. `windowOrderByBundle: [String: [CGWindowID]]` and `windowOrderDefaultsKey` match between load/save/query sites. `NSNumber(value: UInt32(...))` round-trips correctly with `$0.uint32Value` since `CGWindowID` is `UInt32`.
