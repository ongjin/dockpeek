# Preview UX Improvement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Dock preview less intrusive — hover stops hijacking the keyboard, stuck/zombie previews dismiss reliably, hover triggers less eagerly, and app-to-app switches stop flickering.

**Architecture:** Four independent changes to the two files that own the preview lifecycle. (A) `showPreview` only grabs key focus when the trigger is a click. (B) A frontmost-app-change observer plus a `windowDidResignKey` delegate guarantee dismissal. (C) Cursor velocity + dwell gate when a hover preview arms or switches. (D) Already-open previews swap content in place instead of dismiss-then-refade.

**Tech Stack:** Swift 5 / AppKit (`NSPanel`, `NSHostingView`, `NSWorkspace` notifications), built with `swiftc` via the Makefile. No SwiftUI App lifecycle.

**Spec:** `docs/superpowers/specs/2026-06-04-preview-ux-design.md`

---

## Testing Approach (read first)

**This repo has no test target and no test runner.** The Makefile compiles every `.swift` under `DockPeek/` with `swiftc` and assembles a bundle by hand; verification is manual, per CLAUDE.md and the spec. The bugs here (key-window stealing, app-activation dismissal, hover feel) are integration/behavioral and only reproduce against the real window server, so unit tests are not applicable.

Each task therefore uses this loop instead of TDD red/green:

1. **Compile gate:** `make build` → must finish with no errors (Debug bundle, non-disruptive, does not touch the installed app).
2. **Behavioral gate:** `make dev` → hot-swaps the binary in `/Applications/DockPeek.app` keeping permissions, then reruns. Perform the exact manual check listed; it maps to a numbered success criterion in the spec.
3. **Commit** with a plain message (no AI footer — repo rule).

> `make dev` requires DockPeek already installed with Accessibility + Screen Recording granted (the user's normal setup). If a check fails, stop and report — do not mark the task done.

## File Structure

No new files. Two existing files change; each keeps its current single responsibility.

- **`DockPeek/UI/PreviewPanel.swift`** — the `NSPanel` subclass owning the preview window. Gains: a `grabsKeyboard` flag on `showPreview`, a `reuse` flag for in-place swaps, `NSWindowDelegate` conformance with `windowDidResignKey`, and an `isDismissing` re-entrancy guard.
- **`DockPeek/App/AppDelegate.swift`** — the orchestrator owning hover polling and preview triggering. Gains: an `interactive`/`reuse` argument threaded through `showPreviewForWindows`, a frontmost-app-change observer, cursor-velocity computation in the poll, and velocity/dwell gating in `processHoverEvent`.

Implement tasks **in order** — Task 3 edits code introduced by Task 1, and Task 4 edits code introduced by Task 3.

---

### Task 1: Hover previews stop grabbing keyboard focus (Spec §A)

**Files:**
- Modify: `DockPeek/UI/PreviewPanel.swift`
- Modify: `DockPeek/App/AppDelegate.swift`

- [ ] **Step 1: Add a `grabsKeyboard` parameter to `showPreview` and gate `makeKey()`**

In `DockPeek/UI/PreviewPanel.swift`, add the parameter to the signature (insert between `useAccentTint:` and `near point:`):

```swift
        backgroundOpacity: CGFloat,
        useAccentTint: Bool,
        grabsKeyboard: Bool = true,
        near point: CGPoint,
```

Then gate the key grab (in the same method, the show/present block):

```swift
        alphaValue = 0
        orderFrontRegardless()
        if grabsKeyboard { makeKey() }
```

(replaces the unconditional `makeKey()`.)

- [ ] **Step 2: Thread an `interactive` flag through `showPreviewForWindows`**

In `DockPeek/App/AppDelegate.swift`, change the method signature:

```swift
    private func showPreviewForWindows(_ windows: [WindowInfo], at point: CGPoint, interactive: Bool) {
```

Pass it to the panel by inserting `grabsKeyboard:` into the `previewPanel.showPreview(` call (between `useAccentTint:` and `near:`):

```swift
            useAccentTint: appState.previewUseAccentTint,
            grabsKeyboard: interactive,
            near: point,
```

- [ ] **Step 3: Update the three call sites**

Hover trigger — inside `handleHoverPreview(for:at:)`:

```swift
        showPreviewForWindows(windows, at: point, interactive: false)
```

Click trigger, app-switch path — inside `eventTapManager(_:didDetectClickAt:)` (the more-indented `DispatchQueue.main.async` that switches preview to a clicked app):

```swift
                        DispatchQueue.main.async { [weak self] in
                            self?.showPreviewForWindows(windows, at: point, interactive: true)
                        }
```

Click trigger, new-preview path — the `DispatchQueue.main.async` near the end of `eventTapManager(_:didDetectClickAt:)`:

```swift
        DispatchQueue.main.async { [weak self] in
            self?.showPreviewForWindows(windows, at: point, interactive: true)
        }
```

- [ ] **Step 4: Compile gate**

Run: `make build`
Expected: completes with no errors; `build/DockPeek.app` written.

- [ ] **Step 5: Behavioral gate (spec criterion 1)**

Run: `make dev`
Then: hover (don't click) a Dock app that has 2+ windows so a preview appears. **Without moving the mouse**, type into another already-focused app (e.g. a text editor).
Expected: keystrokes land in the editor immediately — the preview no longer steals the keyboard. (Click-triggered previews are covered in Task 2.)

- [ ] **Step 6: Commit**

```bash
git add DockPeek/UI/PreviewPanel.swift DockPeek/App/AppDelegate.swift
git commit -m "Stop hover previews from grabbing keyboard focus"
```

---

### Task 2: Bulletproof dismissal — app switch + key loss (Spec §B)

**Files:**
- Modify: `DockPeek/UI/PreviewPanel.swift`
- Modify: `DockPeek/App/AppDelegate.swift`

- [ ] **Step 1: Make `PreviewPanel` its own window delegate and add a dismiss guard**

In `DockPeek/UI/PreviewPanel.swift`, adopt the protocol on the class declaration:

```swift
final class PreviewPanel: NSPanel, NSWindowDelegate {
```

Add the guard flag next to `dismissGeneration`:

```swift
    private var dismissGeneration = 0
    private var isDismissing = false
```

Set the delegate at the end of `init()`:

```swift
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        delegate = self
    }
```

- [ ] **Step 2: Reset the guard in `showPreview` and toggle it across `dismissPanel`; add `windowDidResignKey`**

In `showPreview`, reset the flag right after the generation bump:

```swift
        dismissGeneration &+= 1  // Invalidate any pending deferred cleanup
        isDismissing = false
```

Replace the whole `dismissPanel(...)` method with this version (sets `isDismissing` true on entry, false after `orderOut`, and adds the delegate callback after it):

```swift
    func dismissPanel(animated: Bool = true) {
        removeDismissMonitors()
        isDismissing = true
        let gen = dismissGeneration
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: {
                guard self.dismissGeneration == gen else { return }
                self.orderOut(nil)
                self.isDismissing = false
                self.alphaValue = 1
                self.clearStoredState()
            })
        } else {
            orderOut(nil)
            isDismissing = false
            DispatchQueue.main.async {
                guard self.dismissGeneration == gen else { return }
                self.clearStoredState()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A keyboard-grabbing (click) preview lost key focus — e.g. user opened
        // our own Settings window. Dismiss it. Guarded against the re-entrant
        // resignKey that our own orderOut() fires during teardown.
        guard isVisible, !isDismissing else { return }
        storedOnDismiss?()
    }
```

- [ ] **Step 3: Register a frontmost-app-change observer in `AppDelegate`**

In `DockPeek/App/AppDelegate.swift`, call the setup in `applicationDidFinishLaunching`:

```swift
        setupNewWindowObserver()
        setupScreenChangeObserver()
        setupAppActivationObserver()
```

Add the setup method and handler immediately after the `setupScreenChangeObserver()` method:

```swift

    private func setupAppActivationObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard previewPanel.isVisible else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        dpLog("Another app activated (\(app.localizedName ?? "?")) — dismissing preview")
        hoverTimer?.cancel(); hoverTimer = nil
        hoverDismissTimer?.cancel(); hoverDismissTimer = nil
        lastHoveredBundleID = nil
        previewIsVisible = false
        highlightOverlay.hide()
        previewPanel.dismissPanel()
    }
```

- [ ] **Step 4: Compile gate**

Run: `make build`
Expected: completes with no errors.

- [ ] **Step 5: Behavioral gate (spec criteria 2 & 3)**

Run: `make dev`
- *Criterion 2 (hover, parked mouse):* hover a 2+ window app to show a preview, leave the mouse still, press **Cmd-Tab** to another app. Expected: the preview disappears on its own.
- *Criterion 3 (click preview):* click a Dock icon of a 2+ window app to open the preview (keyboard mode); confirm **←/→/Enter/Esc** navigate/select/dismiss. Reopen it, then switch to another app (Cmd-Tab or click). Expected: it dismisses and the keyboard is free.

- [ ] **Step 6: Commit**

```bash
git add DockPeek/UI/PreviewPanel.swift DockPeek/App/AppDelegate.swift
git commit -m "Dismiss preview on app switch and key-focus loss"
```

---

### Task 3: Reuse the panel on app switch — no flicker (Spec §D)

**Files:**
- Modify: `DockPeek/UI/PreviewPanel.swift`
- Modify: `DockPeek/App/AppDelegate.swift`

- [ ] **Step 1: Add a `reuse` parameter and an in-place swap path to `showPreview`**

In `DockPeek/UI/PreviewPanel.swift`, add `reuse` after `grabsKeyboard` in the signature:

```swift
        grabsKeyboard: Bool = true,
        reuse: Bool = false,
        near point: CGPoint,
```

Replace the body section that builds the hosting view and presents the panel (from `contentView = nil  // Release old hosting view…` through the fade-in `NSAnimationContext` block) with this reuse-aware version:

```swift
        let hosting: NSHostingView<AnyView>
        if isReusing, let existing = contentView as? NSHostingView<AnyView> {
            // Swap content into the live panel — no order-out, no re-fade.
            existing.rootView = AnyView(content)
            hosting = existing
        } else {
            contentView = nil  // Release old hosting view before creating new one
            let fresh = NSHostingView(rootView: AnyView(content))
            contentView = fresh
            hosting = fresh
        }
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        let panelSize = NSSize(
            width: min(fitting.width, 800),
            height: min(fitting.height, 500)
        )
        let frame = calculateFrame(size: panelSize, nearPoint: point)

        if isReusing {
            // Reposition in place; alpha stays 1, key state unchanged.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInOut)
                self.animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
            alphaValue = 0
            orderFrontRegardless()
            if grabsKeyboard { makeKey() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
```

Define `isReusing` right after the `isDismissing = false` line added in Task 2:

```swift
        dismissGeneration &+= 1  // Invalidate any pending deferred cleanup
        isDismissing = false
        let isReusing = reuse && isVisible
```

- [ ] **Step 2: Thread `reuse` through `showPreviewForWindows`**

In `DockPeek/App/AppDelegate.swift`, extend the signature:

```swift
    private func showPreviewForWindows(_ windows: [WindowInfo], at point: CGPoint, interactive: Bool, reuse: Bool = false) {
```

Pass it into the `previewPanel.showPreview(` call (insert after `grabsKeyboard:`):

```swift
            useAccentTint: appState.previewUseAccentTint,
            grabsKeyboard: interactive,
            reuse: reuse,
            near: point,
```

- [ ] **Step 3: Give `handleHoverPreview` a `reuse` argument**

Replace `handleHoverPreview` with:

```swift
    private func handleHoverPreview(for pid: pid_t, at point: CGPoint, reuse: Bool) {
        let windows = windowManager.windowsForApp(pid: pid)
        guard !windows.isEmpty else {
            // New app has no previewable windows — drop the lingering panel.
            if reuse, previewPanel.isVisible {
                highlightOverlay.hide()
                previewPanel.dismissPanel(animated: false)
                previewIsVisible = false
            }
            return
        }

        dpLog("Hover preview: \(windows.count) window(s) for PID \(pid)")
        showPreviewForWindows(windows, at: point, interactive: false, reuse: reuse)
    }
```

- [ ] **Step 4: Switch in place instead of dismiss-then-reshow**

In `processHoverEvent(cgPoint:)`, replace the "Different app" block (from `// Different app — cancel old timer and dismiss current preview` through the instant/delayed `if wasVisible { … } else { … }` show block at the end of the method) with:

```swift
        // Different app — cancel old timer. Keep the current panel up so the
        // switch can swap content in place (no dismiss/re-fade).
        hoverTimer?.cancel()
        let wasVisible = previewPanel.isVisible
        if wasVisible { highlightOverlay.hide() }
        lastHoveredBundleID = bundleID

        // New app can't produce a preview → drop the old panel and stop.
        guard dockApp.isRunning, let pid = dockApp.pid,
              !appState.isExcluded(bundleID: dockApp.bundleIdentifier) else {
            hoverTimer = nil
            if wasVisible {
                previewPanel.dismissPanel(animated: false)
                previewIsVisible = false
            }
            return
        }

        // Switch in place when already browsing; fade in fresh after a delay otherwise.
        if wasVisible {
            handleHoverPreview(for: pid, at: cgPoint, reuse: true)
        } else {
            let task = DispatchWorkItem { [weak self] in
                self?.handleHoverPreview(for: pid, at: cgPoint, reuse: false)
            }
            hoverTimer = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
        }
```

- [ ] **Step 5: Compile gate**

Run: `make build`
Expected: completes with no errors.

- [ ] **Step 6: Behavioral gate (spec criterion 6 + regression 7)**

Run: `make dev`
- *Criterion 6 (no flicker):* with two apps that each have 2+ windows side by side in the Dock, hover one to open a preview, then slowly move onto the other. Expected: the panel slides/cross-updates to the new app's windows with **no fade-out/fade-in flicker**.
- *Regression 7:* click a Dock icon → preview opens; click a thumbnail → that window activates; open another preview and click a card's **X** → that window closes and the card disappears; use a **snap** control → the window snaps and the preview stays. All must still work.

- [ ] **Step 7: Commit**

```bash
git add DockPeek/UI/PreviewPanel.swift DockPeek/App/AppDelegate.swift
git commit -m "Reuse preview panel on app switch to remove flicker"
```

---

### Task 4: Velocity + dwell gating for hover (Spec §C)

**Files:**
- Modify: `DockPeek/App/AppDelegate.swift`

- [ ] **Step 1: Add tuning constants**

In `DockPeek/App/AppDelegate.swift`, add below the existing poll-interval constants:

```swift
    private static let idlePollInterval: TimeInterval = 0.25   // 4 Hz
    private static let activePollInterval: TimeInterval = 0.066 // ~15 Hz
    private static let hoverVelocityThreshold: CGFloat = 1200   // pt/s; faster = passing through, ignore
    private static let hoverFirstDelay: TimeInterval = 0.5      // first-hover dwell before showing
    private static let hoverSwitchDelay: TimeInterval = 0.12    // dwell before switching to another app
```

- [ ] **Step 2: Compute cursor speed in the poll and pass it on**

In `pollMousePosition()`, insert the speed computation **after** the interval-adapt block and **before** the "Skip processing if mouse hasn't moved" check:

```swift
        // Cursor speed (pt/s) from the previous sample — used to ignore fast passes.
        var speed: CGFloat = 0
        if let last = lastPollMouseLocation, currentPollInterval > 0 {
            let dx = cgPoint.x - last.x
            let dy = cgPoint.y - last.y
            speed = (dx * dx + dy * dy).squareRoot() / CGFloat(currentPollInterval)
        }
```

Then change the dispatch at the end of the method to forward `speed`:

```swift
        // Only process when near dock or preview is visible
        if needsActive {
            processHoverEvent(cgPoint: cgPoint, speed: speed)
        }
```

- [ ] **Step 3: Accept `speed` in `processHoverEvent` and gate fast passes**

Change the signature:

```swift
    fileprivate func processHoverEvent(cgPoint: CGPoint, speed: CGFloat) {
```

Insert the velocity gate immediately after the same-app early return, **before** the "Different app" block (so `lastHoveredBundleID` is left untouched on a fast pass and the app is re-evaluated once the cursor settles):

```swift
        // Same app — keep existing timer/preview
        if bundleID == lastHoveredBundleID { return }

        // Velocity gate: ignore fast passes over a different app (crossing the
        // Dock). Leave lastHoveredBundleID untouched so the app is re-evaluated
        // once the cursor settles.
        if speed > Self.hoverVelocityThreshold {
            hoverTimer?.cancel()
            hoverTimer = nil
            return
        }

        // Different app — cancel old timer. Keep the current panel up so the
```

- [ ] **Step 4: Replace the instant switch with a short dwell**

Still in `processHoverEvent`, replace the show block from Task 3 (the `if wasVisible { handleHoverPreview(... reuse: true) } else { …0.5… }`) with the unified dwell version:

```swift
        // Dwell before (re)showing: short when switching while browsing, longer
        // for a first hover. Reuse the open panel for switches.
        let delay = wasVisible ? Self.hoverSwitchDelay : Self.hoverFirstDelay
        let task = DispatchWorkItem { [weak self] in
            self?.handleHoverPreview(for: pid, at: cgPoint, reuse: wasVisible)
        }
        hoverTimer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
```

- [ ] **Step 5: Compile gate**

Run: `make build`
Expected: completes with no errors.

- [ ] **Step 6: Behavioral gate (spec criteria 4 & 5)**

Run: `make dev`
- *Criterion 4 (fast cross):* sweep the cursor quickly straight across the Dock over several app icons. Expected: **no preview appears.**
- *Criterion 5 (browsing, fast pass):* open a preview by dwelling on one app, then move quickly across neighboring icons. Expected: the preview does **not** chase every icon; it only switches when the cursor **settles** (~0.12 s) on an app. Dwelling ~0.5 s on a cold app still opens it.

- [ ] **Step 7: Commit**

```bash
git add DockPeek/App/AppDelegate.swift
git commit -m "Add velocity and dwell gating to hover previews"
```

---

## Post-Implementation

- **Full regression pass:** run `make dev` once more and walk all 7 spec success criteria end to end.
- **Version bump (release only, not part of these tasks):** when shipping, bump `Makefile` `VERSION` and `DockPeek/Info.plist` `CFBundleShortVersionString` together and commit as `Bump version to X.Y.Z`, per CLAUDE.md.
- **Out of scope (do not touch):** event-tap safety watchdog, cursor-warp, Dock anchor, thumbnail capture path.

## Plan Self-Review

- **Spec coverage:** §A → Task 1; §B → Task 2; §C → Task 4; §D → Task 3. Success criteria 1–7 each have a behavioral gate (T1→1, T2→2,3, T3→6,7, T4→4,5). ✓
- **Type/signature consistency across tasks:** `showPreview(... grabsKeyboard:Bool, reuse:Bool, near:...)` (T1 adds `grabsKeyboard`, T3 adds `reuse`); `showPreviewForWindows(_:at:interactive:reuse:)` (T1 adds `interactive`, T3 adds `reuse` defaulted); `handleHoverPreview(for:at:reuse:)` (T3); `processHoverEvent(cgPoint:speed:)` (T4). Later tasks edit the exact strings earlier tasks produce. ✓
- **Ordering dependency:** T3 Step 4 edits the block T1 left; T4 Steps 3–4 edit the block T3 produced. Must run in order — stated at top. ✓
- **Re-entrancy:** `isDismissing` set true on dismiss entry, false after `orderOut`, and reset in `showPreview`; `windowDidResignKey` guards on `isVisible && !isDismissing`. ✓
- **No placeholders:** every code step shows complete code; commands have expected output. ✓
