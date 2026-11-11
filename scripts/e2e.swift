// End-to-end check for DockPeek. Drives the real cursor and watches DockPeek from the outside.
//
//   make e2e                           hover, card overlay, card click, dismissals, app switch, click preview, Esc
//   make e2e E2E_ARGS=--hover-only     hover preview only: no clicks, no focus change
//   make e2e E2E_ARGS=--plan           list the Dock apps and exit; sends no input
//   make e2e E2E_ARGS=--dock-restart   full run, then restart the Dock and check previews recover
//   --windows=N                        windows the stand-in app opens (default 3); try 12 to overflow the screen
//   --app=NAME                         target a real Dock app whose title contains NAME instead of the stand-in
//
// By default the target is a stand-in app (scripts/e2e-target.swift) that the run launches and
// quits, so card clicks land on its windows and never on yours.
//
// Needs: DockPeek running, and this terminal trusted for Accessibility (plus Screen Recording for
// the screenshots). Keep your hands off the mouse and keyboard while it runs — it waits for you to
// go idle first and aborts if you touch them. It never presses a card's close or snap buttons.

import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared

// MARK: - Options

enum Mode { case plan, hoverOnly, full }

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })

guard let outDir = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: driver <dir> [--plan | --hover-only] [--dock-restart] [--windows=N] [--app=NAME]")
    exit(2)
}

let mode: Mode = flags.contains("--plan") ? .plan : flags.contains("--hover-only") ? .hoverOnly : .full
let restartsDock = flags.contains("--dock-restart")
let requestedApp = flags.first { $0.hasPrefix("--app=") }.map { String($0.dropFirst("--app=".count)) }
let standInWindows = flags.first { $0.hasPrefix("--windows=") }.flatMap { Int($0.dropFirst("--windows=".count)) } ?? 3

// MARK: - Constants

/// Mirrors PreviewContentView's layout, to find cards inside the panel.
enum Layout {
    static let outerPadding: CGFloat = 16
    static let cardPadding: CGFloat = 6
    static let cardSpacing: CGFloat = 12
    static let thumbnailAspect: CGFloat = 0.625
    static let minThumbnail: CGFloat = 80
    static let screenMargin: CGFloat = 8   // PreviewPanel.dockGap, applied on both sides
    static let heightBesidesThumbnail: CGFloat = 62   // paddings plus the title row
    static let heightTolerance: CGFloat = 16
    /// Fraction of the thumbnail height to aim at: below the close button, above the snap bar.
    static let safeClickHeight: CGFloat = 0.38
}

enum Pace {
    static let travel: CGFloat = 5000   // pt/s, far from the Dock
    static let settle: CGFloat = 420    // pt/s, final approach — well under DockPeek's 1200 pt/s velocity gate
    static let browse: CGFloat = 260    // pt/s, sliding along the Dock
    static let step: TimeInterval = 0.008
    static let stagingHeight: CGFloat = 260   // how far above the Dock icon to pause before descending
}

enum Guard {
    static let idleBeforeStart: TimeInterval = 2
    static let idleWait: TimeInterval = 30
    static let cursorTolerance: CGFloat = 4
}

let escapeKey: CGKeyCode = 53
let panelLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))   // PreviewPanel.level
let overlayLayer = panelLayer - 1                             // HighlightOverlay sits one below

// MARK: - Reporting

var failures = 0

func check(_ name: String, _ passed: Bool, _ detail: String = "") {
    print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
    if !passed { failures += 1 }
}

func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@discardableResult
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        spin(0.04)
    }
    return condition()
}

func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

// MARK: - Window queries

struct Win {
    let id: CGWindowID
    let bounds: CGRect
}

struct OwnWindow {
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

guard let dockPeek = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockpeek.app").first else {
    print("ABORT: DockPeek is not running")
    exit(2)
}
let dockPeekPID = dockPeek.processIdentifier

func windowList(_ options: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(of info: [String: Any]) -> CGRect {
    (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
}

func dockPeekWindows() -> [OwnWindow] {
    windowList([.optionOnScreenOnly]).compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == dockPeekPID else { return nil }
        return OwnWindow(layer: info[kCGWindowLayer as String] as? Int ?? 0,
                         bounds: bounds(of: info),
                         alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
    }
}

func panel() -> OwnWindow? { dockPeekWindows().first { $0.layer == panelLayer } }
func overlay() -> OwnWindow? { dockPeekWindows().first { $0.layer == overlayLayer } }
func panelShown() -> Bool { (panel()?.alpha ?? 0) > 0.9 }
func overlayShown() -> Bool { (overlay()?.alpha ?? 0) > 0.4 }

typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let axGetWindow: GetWindowFn? = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }

/// The windows DockPeek should list for an app — same rules as WindowManager.windowsForApp.
func expectedWindows(pid: pid_t) -> [Win] {
    var windows: [Win] = []
    for info in windowList([.optionAll, .excludeDesktopElements]) {
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true else { continue }

        let frame = bounds(of: info)
        guard frame.width > 1, frame.height > 1 else { continue }
        windows.append(Win(id: id, bounds: frame))
    }

    var standard = Set<CGWindowID>()
    var ref: AnyObject?
    if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &ref) == .success,
       let axWindows = ref as? [AXUIElement], let getWindow = axGetWindow {
        for axWindow in axWindows {
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subrole)
            guard (subrole as? String) == "AXStandardWindow" else { continue }

            var id: CGWindowID = 0
            if getWindow(axWindow, &id) == .success, id != 0 { standard.insert(id) }
        }
    }
    return standard.isEmpty ? windows : windows.filter { standard.contains($0.id) }
}

/// Front-to-back IDs of ordinary windows, DockPeek's own excluded.
func zOrder() -> [CGWindowID] {
    windowList([.optionOnScreenOnly, .excludeDesktopElements]).compactMap { info in
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              (info[kCGWindowOwnerPID as String] as? pid_t) != dockPeekPID,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        return info[kCGWindowNumber as String] as? CGWindowID
    }
}

// MARK: - Dock items

struct DockItem {
    let index: Int
    let title: String
    let bundleID: String
    let center: CGPoint
    let pid: pid_t
    let windows: [Win]
}

func dockPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
}

func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return value
}

func dockItems() -> [DockItem] {
    guard let pid = dockPID() else { return [] }

    var result: [DockItem] = []
    for list in (axValue(AXUIElementCreateApplication(pid), kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        let children = (axValue(list, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for (index, item) in children.enumerated() {
            guard (axValue(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem",
                  let url = (axValue(item, kAXURLAttribute) as? NSURL) as URL?,
                  let bundleID = Bundle(url: url)?.bundleIdentifier, bundleID != "com.dockpeek.app",
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }

            var origin = CGPoint.zero, size = CGSize.zero
            if let value = axValue(item, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
            if let value = axValue(item, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }

            // Aim slightly above the tile's middle: the bottom strip holds the running-app dot.
            let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2 - 6)
            result.append(DockItem(index: index, title: axValue(item, kAXTitleAttribute) as? String ?? "?", bundleID: bundleID,
                                   center: center, pid: app.processIdentifier, windows: expectedWindows(pid: app.processIdentifier)))
        }
    }
    return result
}

// MARK: - Input

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

var parkedAt: CGPoint?
var runStart = Date()
var ownKeyPress: Date?

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func glide(to target: CGPoint, speed: CGFloat) {
    let start = cursor()
    let distance = hypot(target.x - start.x, target.y - start.y)
    let steps = max(1, Int(ceil(distance / (speed * CGFloat(Pace.step)))))

    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        post(.mouseMoved, at: CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
        usleep(UInt32(Pace.step * 1_000_000))
    }
    parkedAt = target
}

/// Fast to a point above the Dock icon, then a slow descent like a hand settling on it.
func approach(_ target: CGPoint) {
    glide(to: CGPoint(x: target.x, y: target.y - Pace.stagingHeight), speed: Pace.travel)
    spin(0.25)
    glide(to: target, speed: Pace.settle)
}

func click(_ point: CGPoint) {
    post(.leftMouseDown, at: point)
    usleep(60_000)
    post(.leftMouseUp, at: point)
}

func pressEscape() {
    ownKeyPress = Date()
    CGEvent(keyboardEventSource: nil, virtualKey: escapeKey, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(keyboardEventSource: nil, virtualKey: escapeKey, keyDown: false)?.post(tap: .cghidEventTap)
}

func shot(_ region: CGRect, _ name: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", "\(outDir)/\(name)"]
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
}

// MARK: - Interference guard

/// A locked screen parks the Dock below the display, so every hover would miss and read as a
/// DockPeek failure.
func screenLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return session["CGSSessionScreenIsLocked"] != nil
}

func idleSeconds(_ types: [CGEventType]) -> TimeInterval {
    types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
}

/// What, if anything, other than this script touched the input devices. Synthetic mouse events
/// reset the same clocks as real ones, so mouse use is detected by the cursor leaving the spot
/// the last glide parked it; typing is detected by the key clock.
func interference() -> String? {
    if screenLocked() { return "the screen was locked" }

    if let parkedAt, hypot(cursor().x - parkedAt.x, cursor().y - parkedAt.y) > Guard.cursorTolerance {
        return "the cursor was moved to \(cursor())"
    }

    let lastKey = Date().addingTimeInterval(-idleSeconds([.keyDown]))
    let ours = ownKeyPress.map { abs(lastKey.timeIntervalSince($0)) < 0.5 } ?? false
    if lastKey > runStart, !ours { return "a key was pressed" }

    return nil
}

// MARK: - Target

guard AXIsProcessTrusted() else {
    print("ABORT: this terminal is not trusted for Accessibility")
    exit(2)
}

guard !screenLocked() else {
    print("ABORT: the screen is locked; unlock it and run again")
    exit(2)
}

let defaults = UserDefaults(suiteName: "com.dockpeek.app")
let preferredThumbnail: CGFloat = {
    let stored = defaults?.double(forKey: "thumbnailSize") ?? 0
    return stored > 0 ? CGFloat(stored) : 200
}()

/// The stand-in app, built next to the driver by `make e2e`.
let standInBundleID = "com.dockpeek.e2e-target"
let standInPath = "\(outDir)/DockPeekE2E.app"
var standIn: NSRunningApplication?

func launchStandIn(windows: Int) -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: standInBundleID).forEach { $0.terminate() }
    spin(0.5)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-n", standInPath, "--args", "\(windows)"]   // -g: don't bring it to the front
    try? task.run()
    task.waitUntilExit()

    let ready = waitFor(10) {
        standIn = NSRunningApplication.runningApplications(withBundleIdentifier: standInBundleID).first
        guard let pid = standIn?.processIdentifier else { return false }
        return expectedWindows(pid: pid).count == windows && dockItems().contains { $0.pid == pid }
    }
    spin(1)   // the Dock slides its icons apart to make room
    return ready
}

if mode == .plan {
    for item in dockItems() {
        print("  [\(item.index)] \(item.title): \(item.windows.count) window(s) at (\(Int(item.center.x)),\(Int(item.center.y)))")
    }
    print("target: \(requestedApp.map { "the Dock app matching '\($0)'" } ?? "the stand-in app with \(standInWindows) windows, launched at run time")")
    exit(0)
}

if requestedApp == nil, !launchStandIn(windows: standInWindows) {
    print("ABORT: the stand-in app did not come up with \(standInWindows) windows (it is built by `make e2e`)")
    standIn?.terminate()
    exit(2)
}

let items = dockItems()
let picked: DockItem?
if let requestedApp {
    picked = items.first { !$0.windows.isEmpty && $0.title.localizedCaseInsensitiveContains(requestedApp) }
} else {
    picked = items.first { $0.bundleID == standInBundleID }
}

guard let A = picked else {
    print("ABORT: no running Dock app with a window matches '\(requestedApp ?? standInBundleID)'")
    standIn?.terminate()
    exit(2)
}
if mode == .full, A.windows.count < 2 {
    print("ABORT: \(A.title) has \(A.windows.count) window(s); the full run needs at least 2 (use --hover-only)")
    standIn?.terminate()
    exit(2)
}

// B is the nearest other app with a window, for the switch step. It is only hovered.
let neighbour = items.filter { $0.pid != A.pid && !$0.windows.isEmpty }.min { abs($0.index - A.index) < abs($1.index - A.index) }
print("target A: \(A.title) (\(A.windows.count) windows) | target B: \(neighbour.map { "\($0.title) (\($0.windows.count))" } ?? "none")")

/// CG-space frame of the screen under a point, minus the Dock and menu bar.
func visibleFrame(at point: CGPoint) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: point.x, y: primaryHeight - point.y)) } ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { return .zero }
    return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
}

func rowWidth(cards: Int, thumbnail: CGFloat) -> CGFloat {
    CGFloat(cards) * (thumbnail + Layout.cardPadding * 2) + CGFloat(cards - 1) * Layout.cardSpacing + Layout.outerPadding * 2
}

/// Thumbnail size DockPeek should use: the setting, or smaller when the row would not fit the
/// screen (mirrors PreviewMetrics.fittedThumbnailSize).
let screenFrame = visibleFrame(at: A.center)
let thumbnail: CGFloat = {
    let available = screenFrame.width - Layout.screenMargin * 2
    let cards = CGFloat(A.windows.count)
    guard rowWidth(cards: A.windows.count, thumbnail: preferredThumbnail) > available else { return preferredThumbnail }

    let perCard = (available - Layout.outerPadding * 2 - (cards - 1) * Layout.cardSpacing) / cards - Layout.cardPadding * 2
    return max(Layout.minThumbnail, perCard.rounded(.down))
}()
let cardWidth = thumbnail + Layout.cardPadding * 2
let thumbnailHeight = thumbnail * Layout.thumbnailAspect

func panelWidth(cards: Int) -> CGFloat { rowWidth(cards: cards, thumbnail: thumbnail) }

func cardPoint(_ index: Int, in panelFrame: CGRect) -> CGPoint {
    CGPoint(x: panelFrame.minX + Layout.outerPadding + CGFloat(index) * (cardWidth + Layout.cardSpacing) + cardWidth / 2,
            y: panelFrame.minY + Layout.outerPadding + Layout.cardPadding + thumbnailHeight * Layout.safeClickHeight)
}

/// Window shown on each card, in DockPeek's own persisted per-app order. Bounds can't be used
/// for this: two maximized windows share them.
func cardWindows(_ item: DockItem) -> [Win] {
    defaults?.synchronize()
    let stored = ((defaults?.dictionary(forKey: "windowOrderByBundle")?[item.bundleID] as? [NSNumber]) ?? []).map { CGWindowID($0.uint32Value) }
    let byID = Dictionary(uniqueKeysWithValues: item.windows.map { ($0.id, $0) })

    var ordered = stored.compactMap { byID[$0] }
    ordered += item.windows.filter { window in !ordered.contains { $0.id == window.id } }
    return ordered
}

// MARK: - Run

if !waitFor(Guard.idleWait, { idleSeconds([.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]) >= Guard.idleBeforeStart }) {
    print("ABORT: mouse or keyboard still in use after \(Int(Guard.idleWait))s — nothing was sent")
    standIn?.terminate()
    exit(2)
}

let originalCursor = cursor()
let originalFront = NSWorkspace.shared.frontmostApplication
var changedFocus = false
runStart = Date()

func finish() -> Never {
    glide(to: originalCursor, speed: Pace.travel)
    standIn?.terminate()
    if changedFocus { originalFront?.activate() }
    spin(0.3)
    print(failures == 0 ? "E2E: ALL PASS" : "E2E: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Stop before sending more input if someone else is using the machine.
func requireUndisturbed() {
    guard let reason = interference() else { return }
    print("ABORT: \(reason) during the run — results up to here are unreliable")
    failures += 1
    finish()
}

func leaveAbove(_ panelFrame: CGRect) {
    glide(to: CGPoint(x: panelFrame.midX, y: panelFrame.minY - 220), speed: 900)
}

func hoverA(_ label: String) -> CGRect? {
    approach(A.center)
    check("\(label) hover preview appears", waitFor(2.5) { panelShown() })
    return panel()?.bounds
}

// 0. Synthetic input reaches the cursor
glide(to: CGPoint(x: A.center.x, y: A.center.y - Pace.stagingHeight), speed: Pace.travel)
spin(0.2)
guard interference() == nil else {
    print("ABORT: the cursor did not go where it was sent (event posting blocked, or the mouse is in use)")
    standIn?.terminate()
    exit(2)
}
check("0 no preview before hovering", panel() == nil)

// 1. Hover → preview after the dwell, sized for A's windows
glide(to: A.center, speed: Pace.settle)
check("1 hover preview appears", waitFor(2.5) { panelShown() })
guard panel() != nil else { finish() }

spin(0.7)   // thumbnails land asynchronously
let panelFrame = panel()?.bounds ?? .zero
let layoutMatches = abs(panelFrame.width - panelWidth(cards: A.windows.count)) <= 2
    && abs(panelFrame.height - (thumbnailHeight + Layout.heightBesidesThumbnail)) <= Layout.heightTolerance
check("1 panel laid out for \(A.windows.count) cards", layoutMatches,
      "panel \(Int(panelFrame.width))x\(Int(panelFrame.height)), expected width \(Int(panelWidth(cards: A.windows.count)))")
check("1 panel fits on the screen", panelFrame.minX >= screenFrame.minX - 1 && panelFrame.maxX <= screenFrame.maxX + 1,
      "panel x \(Int(panelFrame.minX))…\(Int(panelFrame.maxX)), screen x \(Int(screenFrame.minX))…\(Int(screenFrame.maxX))")
shot(panelFrame.insetBy(dx: -10, dy: -10), "1-hover-panel.png")

if mode == .hoverOnly {
    requireUndisturbed()
    leaveAbove(panelFrame)
    check("1 dismisses when the cursor passes above the panel", waitFor(1) { panel() == nil })
    finish()
}

// 2. Card hover → overlay on that card's window.
// Leave the icon straight up (never across a neighbouring icon), then move sideways inside the panel.
requireUndisturbed()
let cards = cardWindows(A)
glide(to: CGPoint(x: A.center.x, y: cardPoint(0, in: panelFrame).y), speed: Pace.settle)
check("2 still A's preview after crossing from the Dock into the panel",
      panelShown() && abs((panel()?.bounds.width ?? 0) - panelWidth(cards: A.windows.count)) <= 2)

glide(to: cardPoint(0, in: panelFrame), speed: Pace.settle)
check("2 overlay appears on card hover", waitFor(1.5) { overlayShown() })
check("2 overlay sits on card 0's window", near(overlay()?.bounds ?? .zero, cards[0].bounds), "overlay \(overlay()?.bounds ?? .zero)")
spin(0.7)   // full-size capture replaces the thumbnail
shot(overlay()?.bounds ?? .zero, "2-overlay.png")
shot(panelFrame.insetBy(dx: -10, dy: -10), "2-card-hovered.png")

glide(to: cardPoint(1, in: panelFrame), speed: Pace.browse)
check("2 overlay follows to card 1's window", waitFor(1.5) { overlayShown() && near(overlay()?.bounds ?? .zero, cards[1].bounds) },
      "overlay \(overlay()?.bounds ?? .zero)")

// 3. Click a card → that window comes to the front and the preview closes.
// Pick the card whose window is further back, so the change is observable.
if layoutMatches {
    let order = zOrder()
    let depth = cards.prefix(2).map { order.firstIndex(of: $0.id) ?? 0 }
    let index = depth[1] >= depth[0] ? 1 : 0
    let point = cardPoint(index, in: panelFrame)

    glide(to: point, speed: Pace.browse)
    spin(0.25)
    requireUndisturbed()
    print("  clicking card \(index): window \(cards[index].id) is at z-position \(depth[index])")
    changedFocus = true
    click(point)

    check("3 preview closes on select", waitFor(1.5) { panel() == nil })
    check("3 selected window is frontmost", waitFor(2.5) { zOrder().first == cards[index].id },
          "front window \(zOrder().first.map(String.init) ?? "?"), wanted \(cards[index].id)")
    check("3 its app is frontmost", waitFor(2) { NSWorkspace.shared.frontmostApplication?.processIdentifier == A.pid })
    check("3 overlay gone", waitFor(1) { overlay() == nil })
} else {
    print("SKIP 3 card click: panel layout not as expected, not clicking blind")
}

// 4a. Leave sideways → dismissed after the grace period
requireUndisturbed()
if let frame = hoverA("4a") {
    glide(to: CGPoint(x: frame.minX - 70, y: frame.midY), speed: 700)
    check("4a dismisses after leaving sideways", waitFor(2) { panel() == nil })
}

// 4b. Leave above → dismissed at once
requireUndisturbed()
if let frame = hoverA("4b") {
    leaveAbove(frame)
    check("4b dismisses when the cursor passes above the panel", waitFor(1) { panel() == nil })
}

// 5. Slide to another app → the panel switches in place
if let B = neighbour {
    requireUndisturbed()
    _ = hoverA("5")
    glide(to: B.center, speed: Pace.browse)

    let wanted = panelWidth(cards: B.windows.count)
    let switched = waitFor(2.5) { panelShown() && abs((panel()?.bounds.width ?? 0) - wanted) <= 2 }
    check("5 preview switches to \(B.title) (\(B.windows.count) cards)", switched, "panel \(panel()?.bounds ?? .zero)")

    spin(0.7)
    if let frame = panel()?.bounds {
        shot(frame.insetBy(dx: -10, dy: -10), "5-switched-panel.png")
        leaveAbove(frame)
    }
    check("5 dismissed", waitFor(1.5) { panel() == nil })
}

// 6. Click the Dock icon → a preview that owns the keyboard; Esc closes it
requireUndisturbed()
glide(to: CGPoint(x: A.center.x, y: A.center.y - Pace.stagingHeight), speed: Pace.travel)
spin(0.5)
glide(to: A.center, speed: 900)
click(A.center)
check("6 click preview appears", waitFor(1.5) { panelShown() })

spin(0.5)
if let frame = panel()?.bounds { shot(frame.insetBy(dx: -10, dy: -10), "6-click-panel.png") }
if panelShown() {
    pressEscape()
    check("6 Esc closes the click preview", waitFor(1.5) { panel() == nil })
}
if let frame = panel()?.bounds {
    leaveAbove(frame)
    waitFor(1.5) { panel() == nil }
}

// 6b. Hovering the same icon again must bring the preview back. It used to stay suppressed
// after Esc or a card click until some other icon was crossed.
requireUndisturbed()
if let frame = hoverA("6b") {
    leaveAbove(frame)
    check("6b dismissed", waitFor(1.5) { panel() == nil })
}

// 7. Restart the Dock → previews must keep working
if restartsDock {
    requireUndisturbed()
    glide(to: CGPoint(x: A.center.x, y: A.center.y - Pace.stagingHeight - 60), speed: Pace.travel)

    let oldDock = dockPID()
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    kill.arguments = ["Dock"]
    try? kill.run()
    kill.waitUntilExit()

    check("7 Dock restarted", waitFor(15) { dockPID() != nil && dockPID() != oldDock }, "pid \(oldDock ?? 0) → \(dockPID() ?? 0)")
    spin(4)   // the new Dock lays out its icons

    if let restarted = dockItems().first(where: { $0.pid == A.pid }) {
        approach(restarted.center)
        check("7 hover preview works after the Dock restart", waitFor(3) { panelShown() })
        if let frame = panel()?.bounds {
            leaveAbove(frame)
            waitFor(1.5) { panel() == nil }
        }
    } else {
        check("7 found \(A.title) in the restarted Dock", false)
    }
}

finish()
