# Preview Close Responsiveness + Stable Window Ordering

Date: 2026-04-20

## Problem

Two UX issues in the Dock preview panel:

1. **Sluggish close.** When the user clicks the X button on a thumbnail, the thumbnail stays visible for ~300ms before the panel refreshes. On Windows, the thumbnail disappears instantly.
2. **Unstable window order.** The thumbnails reorder themselves between previews. A new window might appear in the middle, at the front, or at the back — the position feels random. The user wants new windows to always appear at the end, with existing windows keeping their position.

## Root Cause

### Close delay

`AppDelegate.showPreviewForWindows` closes via:

```swift
onClose: { [weak self] win in
    self?.highlightOverlay.hide()
    self?.windowManager.closeWindow(windowID: win.id, pid: win.ownerPID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let remaining = self.windowManager.windowsForApp(pid: win.ownerPID)
        if remaining.count < 2 { self.previewPanel.dismissPanel() }
        else { self.showPreviewForWindows(remaining, at: point) }  // full re-render
    }
}
```

The UI waits 300ms, then re-queries and re-renders from scratch.

### Reorder

`WindowManager.windowsForApp(pid:)` returns windows in whatever order `CGWindowListCopyWindowInfo` gives. That API orders by z-order (frontmost first). Activating a window promotes it to the top, so the next preview shows a different order.

## Design

### 1. Instant close

Remove the cross-fetch + re-render. Drop the closed thumbnail from the panel immediately; invoke the AX close action synchronously on main thread as today, but without waiting for post-close state.

**Flow (all on main thread):**

1. `onClose(win)` fires.
2. `PreviewPanel.removeWindow(id: CGWindowID)` mutates the SwiftUI-bound array in place — SwiftUI diffs out the single card.
3. After removal, if count falls below 2, call `dismissPanel()`.
4. Call `windowManager.closeWindow(...)` (unchanged — AX close button press).
5. `closeWindow` internally invalidates `WindowManager.windowListCache[pid]` and `axWindowIDsCache[pid]` so the next query reflects the close.

No 300ms delay, no full re-render, no thumbnail regeneration.

### 2. Stable window ordering

Introduce a per-bundle, persistent window order in `WindowManager`.

**State:**

```swift
// WindowManager
private var windowOrderByBundle: [String: [CGWindowID]]
private let orderDefaultsKey = "windowOrderByBundle"
```

Loaded from `UserDefaults.standard` on init; saved whenever the order for any bundle changes.

**UserDefaults encoding:** Store as `[String: [NSNumber]]` (NSNumber wrapping `UInt32`/`CGWindowID`). UserDefaults accepts this natively — no JSON/Data encoding needed. Decode defensively: unexpected shapes reset to empty dict.

**`windowsForApp(pid:)` changes:**

```
1. Fetch and filter windows (unchanged — CGWindowListCopyWindowInfo + AX cross-ref)
2. currentIDs = Set of surviving window IDs
3. bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
   - If nil: fall back to current behavior (no stable order)
4. stored = windowOrderByBundle[bundleID] ?? []
5. finalOrder = stored.filter { currentIDs.contains($0) }
                + currentIDs (minus those already in finalOrder), in CG natural order
6. windowOrderByBundle[bundleID] = finalOrder; persist
7. Return WindowInfo array ordered by finalOrder
```

**Result:**

- Existing windows keep their previous position.
- New windows (not in stored order) are appended at the end.
- Closed windows are pruned automatically.
- DockPeek restart: target app still running → window IDs still match → order preserved.
- Target app restart / reboot: all IDs new → stored order has zero matches → natural fresh order (no reshuffling bug).

### 3. Cache invalidation on close

Without invalidation, the 0.5s `windowListCache` would briefly claim the closed window still exists. Inside `closeWindow`, after the AX press, clear `windowListCache[pid]` and `axWindowIDsCache[pid]`.

## Files Touched

- `DockPeek/Core/WindowManager.swift`
  - Add `windowOrderByBundle` + UserDefaults load/save helpers.
  - Rewrite `windowsForApp(pid:)` ordering step.
  - Invalidate `windowListCache[pid]` and `axWindowIDsCache[pid]` inside `closeWindow`.
- `DockPeek/UI/PreviewPanel.swift`
  - Add `removeWindow(id: CGWindowID)` that updates the bound array and dismisses panel when count < 2.
- `DockPeek/App/AppDelegate.swift`
  - Replace `onClose` body with: `previewPanel.removeWindow(id: win.id)` then async `windowManager.closeWindow(...)`.

## Out of Scope

- No changes to snap, activate, hover-preview logic.
- No visual changes (no animation on close, per "칼같이" requirement).
- No user-facing setting to toggle persistence.
- No migration / schema versioning for UserDefaults (format is a plain `[String: [UInt32]]`).

## Edge Cases

- **BundleID nil** (e.g., helper processes without a bundle): skip persistence, use natural order. Preview still works.
- **Corrupt UserDefaults data**: decode defensively; reset to empty dict on failure.
- **Storage growth**: entries accumulate per bundleID forever. Acceptable for now — each entry is a handful of UInt32s. Future cleanup can prune entries whose IDs no longer match any running window.
- **Close while thumbnail still loading**: `removeWindow(id:)` removes by ID regardless of thumbnail state.

## Testing

Manual verification:

1. Open 3 Chrome windows, preview them, note order A-B-C.
2. Click a thumbnail → window activates. Preview again → still A-B-C.
3. Close B via X → A-C instantly, no delay.
4. Open a new Chrome window D. Preview → A-C-D (D at end).
5. Close all but one → panel dismisses.
6. Quit DockPeek, relaunch with Chrome still running → same order.
7. Quit Chrome, reopen → order resets naturally.
