import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, EventTapManagerDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let appState = AppState()
    private let eventTapManager = EventTapManager()
    private let dockInspector = DockAXInspector()
    private let windowManager = WindowManager()
    private let previewPanel = PreviewPanel()
    private let highlightOverlay = HighlightOverlay()
    private let dockAnchorManager = DockAnchorManager()

    private let updateChecker = UpdateChecker.shared
    private static let updatePollInterval: TimeInterval = 6 * 60 * 60
    private var updatePollTimer: Timer?
    private var lastClickTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.3
    private var accessibilityTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    // Hover preview — adaptive polling timer
    private var hoverPollTimer: DispatchSourceTimer?
    private var currentPollInterval: TimeInterval = 0.25
    private static let idlePollInterval: TimeInterval = 0.25   // 4 Hz
    private static let activePollInterval: TimeInterval = 0.066 // ~15 Hz
    private static let asleepPollInterval: TimeInterval = 5     // displays off: only watch for wake
    private var displaysAsleep = false
    private var lastPollTime: TimeInterval = 0
    private static let hoverVelocityThreshold: CGFloat = 1200   // pt/s; faster = passing through, ignore
    private static let hoverFirstDelay: TimeInterval = 0.5      // first-hover dwell before showing
    fileprivate var cachedDockRect: CGRect = .zero
    fileprivate var previewIsVisible = false {
        didSet { windowManager.isPreviewVisible = previewIsVisible }
    }
    private var cmdCommaMonitor: Any?
    private var hoverTimer: DispatchWorkItem?
    private var hoverDismissTimer: DispatchWorkItem?
    private var lastHoveredBundleID: String?

    // Mouse position tracking: skip processing when mouse hasn't moved
    private var lastPollMouseLocation: CGPoint?
    private var lastPollInDock = false

    // Cached Dock settings (auto-hide, orientation) — updated in updateCachedDockRect()
    private var isDockAutoHide = false
    private var dockOrientation = "bottom"

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        eventTapManager.stop()
        stopHoverMonitor()
        permissionMonitorTimer?.invalidate()
        accessibilityTimer?.invalidate()
        updatePollTimer?.invalidate()
        if let m = cmdCommaMonitor { NSEvent.removeMonitor(m) }

        // Remove notification observers
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        // Clean up all AX observers
        for pid in axObservers.keys {
            removeAXObserver(pid: pid)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupCmdCommaShortcut()
        setupNewWindowObserver()
        setupScreenChangeObserver()
        setupAppActivationObserver()
        setupDisplaySleepObserver()

        applyDockAnchorSetting()

        if AccessibilityManager.shared.isAccessibilityGranted {
            startEventTap()
            startHoverMonitor()
            startPermissionMonitor()
        } else {
            showOnboarding()
            startAccessibilityPolling()
        }

        // Auto-check for updates (respects cooldown, interval, and user setting)
        autoCheckForUpdates { [weak self] in self?.notifyUpdateAvailable() }

        // A menu bar app stays up for weeks, so keep checking while it runs.
        // These checks are silent: a found update only marks the menu item.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.updatePollInterval, repeats: true) {
            [weak self] _ in
            self?.autoCheckForUpdates()
        }
        timer.tolerance = Self.updatePollInterval / 10
        updatePollTimer = timer
    }

    private func autoCheckForUpdates(onAvailable: @escaping () -> Void = {}) {
        guard appState.autoUpdateEnabled, appState.updateCheckInterval != "manual" else { return }

        updateChecker.check(force: false, intervalSetting: appState.updateCheckInterval) { available in
            if available { onAvailable() }
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: "DockPeek")
            button.action = #selector(showMenu)
            button.target = self
        }
    }

    // MARK: - Menu

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")

        let updateTitle = updateChecker.updateAvailable
            ? "\(L10n.checkForUpdates) ●"
            : L10n.checkForUpdates
        menu.addItem(withTitle: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.aboutDockPeek, action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(withTitle: L10n.quitDockPeek, action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear menu so subsequent clicks trigger action again
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openAbout() {
        NSApp.setActivationPolicy(.regular)
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate()
        // Restore accessory mode when about panel closes (check after delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restoreAccessoryPolicyIfNeeded()
        }
    }

    // MARK: - Update Check

    @objc private func checkForUpdates() {
        updateChecker.check(force: true, intervalSetting: appState.updateCheckInterval) { [weak self] available in
            if available {
                self?.openSettings()
            } else {
                self?.showUpToDateAlert()
            }
        }
    }

    /// Called when an automatic update check finds a new version.
    /// Opens the Settings window on the Update tab instead of a modal alert.
    private func notifyUpdateAvailable() {
        openSettings()
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.upToDate
        alert.informativeText = L10n.upToDateMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Settings Window

    @objc func openSettings() {
        if let window = settingsWindow, window.isVisible {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }

        // Show in Dock while settings window is open
        NSApp.setActivationPolicy(.regular)

        let settingsView = SettingsView(appState: appState)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "DockPeek \(L10n.general)"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        settingsWindow = window
    }

    // MARK: - Cmd+, Shortcut

    private func setupCmdCommaShortcut() {
        cmdCommaMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self?.openSettings()
                return nil
            }
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isSettings = window === settingsWindow
        guard isSettings || window === onboardingWindow else { return }

        // Delay to allow any other windows to be checked, and to drop our
        // reference only after the close has finished — that frees the window
        // and its SwiftUI hierarchy. The identity checks leave a window that was
        // reopened in the meantime alone.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindow === window { self.settingsWindow = nil }
            if self.onboardingWindow === window { self.onboardingWindow = nil }
            if isSettings { self.restoreAccessoryPolicyIfNeeded() }
        }
    }

    /// Restore accessory mode only when no app windows are visible.
    private func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleWindow = settingsWindow?.isVisible == true
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "DockPeek Setup"
        window.center()
        // Owned by onboardingWindow and released in windowWillClose. The default
        // release-on-close over-releases a window that ARC also owns, and a
        // strong capture in onDismiss would keep window ↔ content view alive.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(onDismiss: { [weak window] in
            window?.close()
        }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        onboardingWindow = window
    }

    private func startAccessibilityPolling() {
        guard accessibilityTimer == nil else { return }  // idempotent — may be re-armed from several paths
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityManager.shared.isAccessibilityGranted {
                self.startEventTap()
                self.startHoverMonitor()
                timer.invalidate()
                self.accessibilityTimer = nil
                self.startPermissionMonitor()
            }
        }
    }

    // MARK: - Event Tap

    private func startEventTap() {
        eventTapManager.delegate = self
        eventTapManager.start()
        dpLog("Event tap delegate connected")
    }

    /// Start or stop the Dock anchor based on the current setting.
    /// Independent of accessibility permission — anchoring works via
    /// `com.apple.dock` preferences, not event taps.
    func applyDockAnchorSetting() {
        if appState.anchorDockToPrimary {
            dockAnchorManager.start(orientation: appState.dockAnchorOrientation)
        } else {
            dockAnchorManager.stop()
        }
    }

    // MARK: - Hover Monitor

    private func startHoverMonitor() {
        stopHoverMonitor()
        updateCachedDockRect()

        currentPollInterval = Self.idlePollInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + currentPollInterval,
                       repeating: currentPollInterval,
                       leeway: Self.pollLeeway(for: currentPollInterval))
        timer.setEventHandler { [weak self] in
            self?.pollMousePosition()
        }
        timer.resume()
        hoverPollTimer = timer
        dpLog("Hover poll timer started (idle \(Self.idlePollInterval)s)")
    }

    private func stopHoverMonitor() {
        hoverPollTimer?.cancel()
        hoverPollTimer = nil
        hoverTimer?.cancel()
        hoverTimer = nil
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil
        lastHoveredBundleID = nil
        lastPollMouseLocation = nil
        lastPollInDock = false
        previewIsVisible = false
    }

    /// Active ticks drive hover gating and stay precise. Slower ticks only need to
    /// notice the cursor arriving, so the system may coalesce them with other wakeups.
    private static func pollLeeway(for interval: TimeInterval) -> DispatchTimeInterval {
        guard interval > activePollInterval else { return .nanoseconds(0) }
        return .milliseconds(Int(interval * 200))
    }

    private func setPollInterval(_ interval: TimeInterval) {
        guard abs(currentPollInterval - interval) > 0.001 else { return }
        currentPollInterval = interval
        hoverPollTimer?.schedule(deadline: .now() + interval, repeating: interval,
                                 leeway: Self.pollLeeway(for: interval))
        dpLog("Poll interval → \(interval)s")
    }

    private func setupDisplaySleepObserver() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    /// Nobody can hover the Dock with the displays off — slow the poll right down
    /// so a machine left on overnight isn't woken 4x/s for nothing.
    @objc private func screensDidSleep() {
        displaysAsleep = true
        setPollInterval(Self.asleepPollInterval)
    }

    @objc private func screensDidWake() {
        displaysAsleep = false
        setPollInterval(Self.idlePollInterval)
    }

    /// Lightweight poll: reads NSEvent.mouseLocation and checks dock proximity.
    /// Adapts timer interval based on whether mouse is near dock or preview is visible.
    /// Skips processing if mouse position and dock-area state haven't changed.
    private func pollMousePosition() {
        // Displays off: keep ticking slowly rather than stopping, so a missed wake
        // notification costs a few seconds instead of hover previews until relaunch.
        if displaysAsleep {
            guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
            displaysAsleep = false
        }

        let cocoaLoc = NSEvent.mouseLocation
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: cocoaLoc.x, y: screenH - cocoaLoc.y)

        let inDock = cachedDockRect.contains(cgPoint)
        previewIsVisible = previewPanel.isVisible
        // While a first-hover dwell is armed (panel not yet visible), keep polling
        // active even off the Dock — otherwise leaving the Dock before the preview
        // appears skips processHoverEvent, so the pending timer never gets cancelled
        // and pops a preview for an app the cursor already left.
        let needsActive = inDock || previewIsVisible || hoverTimer != nil

        // Adapt polling interval
        setPollInterval(needsActive ? Self.activePollInterval : Self.idlePollInterval)

        // Cursor speed (pt/s) from the previous sample — used to ignore fast passes.
        // Divided by the real time since the last tick: the nominal interval is
        // wrong on the tick where the timer changes rate (it just switched, but
        // the distance was covered at the old rate) and whenever a tick runs late.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastPollTime
        lastPollTime = now

        var speed: CGFloat = 0
        if let last = lastPollMouseLocation, elapsed > 0 {
            let dx = cgPoint.x - last.x
            let dy = cgPoint.y - last.y
            speed = (dx * dx + dy * dy).squareRoot() / CGFloat(elapsed)
        }

        // Skip processing if mouse hasn't moved and dock-area status unchanged
        if let lastLoc = lastPollMouseLocation,
           lastLoc.x == cgPoint.x, lastLoc.y == cgPoint.y,
           lastPollInDock == inDock {
            return
        }
        lastPollMouseLocation = cgPoint
        lastPollInDock = inDock

        // Only process when near dock or preview is visible
        if needsActive {
            processHoverEvent(cgPoint: cgPoint, speed: speed)
        }
    }

    fileprivate func updateCachedDockRect() {
        guard let primary = NSScreen.screens.first else { cachedDockRect = .zero; return }
        let pH = primary.frame.height

        // Read Dock settings
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        isDockAutoHide = dockDefaults?.bool(forKey: "autohide") ?? false
        dockOrientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"

        var rect = CGRect.zero
        for screen in NSScreen.screens {
            let full = screen.frame
            let vis = screen.visibleFrame
            let bottomGap = vis.minY - full.minY
            let leftGap = vis.minX - full.minX
            let rightGap = full.maxX - vis.maxX

            var dockZone = CGRect.zero
            if bottomGap > 30 {
                let cgTop = pH - vis.minY
                dockZone = CGRect(x: full.minX, y: cgTop, width: full.width, height: bottomGap)
            } else if leftGap > 30 {
                let cgTop = pH - full.maxY
                dockZone = CGRect(x: full.minX, y: cgTop, width: leftGap, height: full.height)
            } else if rightGap > 30 {
                let cgTop = pH - full.maxY
                dockZone = CGRect(x: vis.maxX, y: cgTop, width: rightGap, height: full.height)
            }

            // Auto-hide Dock: no visible gap, create detection zone at screen edge
            if dockZone == .zero, isDockAutoHide {
                let dockSize: CGFloat = 100
                switch dockOrientation {
                case "left":
                    let cgTop = pH - full.maxY
                    dockZone = CGRect(x: full.minX, y: cgTop, width: dockSize, height: full.height)
                case "right":
                    let cgTop = pH - full.maxY
                    dockZone = CGRect(x: full.maxX - dockSize, y: cgTop, width: dockSize, height: full.height)
                default: // "bottom"
                    dockZone = CGRect(x: full.minX, y: pH - full.minY - dockSize, width: full.width, height: dockSize)
                }
            }

            if dockZone != .zero {
                rect = rect == .zero ? dockZone : rect.union(dockZone)
            }
        }
        cachedDockRect = rect
        dpLog("Cached dock rect (CG): \(cachedDockRect) autoHide=\(isDockAutoHide) orientation=\(dockOrientation)")
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

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

    @objc private func screenDidChange() {
        updateCachedDockRect()
    }

    /// Called from the poll timer when mouse is near the dock or preview panel.
    /// Accepts pre-computed cgPoint to avoid redundant coordinate conversion.
    fileprivate func processHoverEvent(cgPoint: CGPoint, speed: CGFloat) {
        // Convert CG point back to Cocoa for panel frame check
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let cocoaLoc = NSPoint(x: cgPoint.x, y: screenH - cgPoint.y)

        // If mouse is over the preview panel, cancel any pending dismiss and let user interact
        if previewPanel.isVisible, previewPanel.frame.contains(cocoaLoc) {
            hoverDismissTimer?.cancel()
            hoverDismissTimer = nil
            return
        }

        let inDock = isPointInDockArea(cgPoint)
        let dockApp = inDock ? dockInspector.appAtPoint(cgPoint) : nil

        // Mouse is outside both dock and preview panel
        if !inDock || dockApp == nil {
            hoverTimer?.cancel()
            hoverTimer = nil
            if previewPanel.isVisible {
                // Overshot above the preview's top edge → the user is clearly
                // leaving; kill it instantly with no fade. The delayed dismiss
                // below only covers leaving sideways or back toward the Dock,
                // where the grace period helps cross the Dock↔panel gap.
                if cocoaLoc.y >= previewPanel.frame.maxY {
                    hoverDismissTimer?.cancel()
                    hoverDismissTimer = nil
                    lastHoveredBundleID = nil
                    previewIsVisible = false
                    highlightOverlay.hide()
                    previewPanel.dismissPanel(animated: false)
                    return
                }
                // Delayed dismiss — gives time to cross the gap to the preview panel
                if hoverDismissTimer == nil {
                    let task = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        // Re-check: mouse may have reached the preview panel
                        let currentLoc = NSEvent.mouseLocation
                        if self.previewPanel.isVisible, self.previewPanel.frame.contains(currentLoc) {
                            self.hoverDismissTimer = nil
                            return
                        }
                        self.lastHoveredBundleID = nil
                        self.hoverDismissTimer = nil
                        self.previewIsVisible = false
                        self.highlightOverlay.hide()
                        self.previewPanel.dismissPanel()
                    }
                    hoverDismissTimer = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
                }
            } else {
                lastHoveredBundleID = nil
            }
            return
        }

        // Mouse is in dock on an app — cancel any pending dismiss
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil

        guard let dockApp else { return }

        let bundleID = dockApp.bundleIdentifier ?? dockApp.name

        // Same app — keep existing timer/preview
        if bundleID == lastHoveredBundleID { return }

        // Velocity gate: ignore fast passes over a different app (crossing the
        // Dock). Clear lastHoveredBundleID so whatever app the cursor finally
        // settles on is re-evaluated and armed afresh.
        if speed > Self.hoverVelocityThreshold {
            hoverTimer?.cancel()
            hoverTimer = nil
            // Only forget the app when no panel is up — while a preview is
            // visible, lastHoveredBundleID must stay equal to the displayed app.
            if !previewPanel.isVisible { lastHoveredBundleID = nil }
            return
        }

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

        // Already browsing → switch instantly. The panel is reused (Task 3), so
        // the swap is flicker-free, and the velocity gate above already blocked
        // fast passes — so an instant switch here only fires on a deliberate,
        // settled move, giving a snappy Windows-like feel. First hover → dwell.
        if wasVisible {
            hoverTimer = nil
            handleHoverPreview(for: pid, at: cgPoint, reuse: true)
        } else {
            let task = DispatchWorkItem { [weak self] in
                self?.handleHoverPreview(for: pid, at: cgPoint, reuse: false)
            }
            hoverTimer = task
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverFirstDelay, execute: task)
        }
    }

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

    // MARK: - Permission Monitor

    private var permissionMonitorTimer: Timer?

    /// Periodically checks if accessibility permission is still granted.
    /// If revoked, stops the event tap immediately to prevent system-wide input freeze.
    private func startPermissionMonitor() {
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !AccessibilityManager.shared.isAccessibilityGranted {
                dpLog("Permission revoked — stopping event tap")
                self.eventTapManager.stop()
                self.stopHoverMonitor()
                timer.invalidate()
                self.permissionMonitorTimer = nil
                // Resume polling so we can restart when permission is re-granted
                self.startAccessibilityPolling()
            } else if !self.eventTapManager.isActive {
                // Backstop: permission is present but the tap is down — an emergency
                // stop (watchdog/callback) tore it down. The delegate callback
                // normally re-arms recovery faster; this catches any missed signal.
                dpLog("Event tap down while permission granted — restarting")
                self.startEventTap()
            }
        }
    }

    // MARK: - EventTapManagerDelegate

    func eventTapManagerDidLosePermission(_ manager: EventTapManager) {
        // The tap was emergency-stopped because accessibility permission was lost.
        // Switch to fast (2s) permission polling so the tap restarts promptly when
        // permission returns — without this the tap stays down until app restart
        // (the 30s monitor only re-arms recovery if it catches permission still off).
        dpLog("Event tap lost permission — switching to accessibility polling")
        stopHoverMonitor()
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = nil
        startAccessibilityPolling()
    }

    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool {
        // Cancel any pending hover timer on click
        hoverTimer?.cancel()
        hoverTimer = nil

        // Cancel any pending dismiss timer
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil

        // If preview is visible, handle click without debounce
        if previewPanel.isVisible {
            let panelFrame = previewPanel.frame
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            // Convert CG point (top-left origin) to Cocoa (bottom-left origin)
            // Must use primary screen height — CG origin is at top-left of primary screen
            let cocoaPoint = NSPoint(x: point.x, y: screenH - point.y)
            if panelFrame.contains(cocoaPoint) {
                // Click is on the preview panel — let it through to SwiftUI.
                // Keep lastHoveredBundleID so the hover poll doesn't re-show
                // a preview after the onSelect handler activates a window.
                return false
            }

            // Click is on a Dock icon — check what app it is
            if isPointInDockArea(point), let dockApp = dockInspector.appAtPoint(point),
               dockApp.isRunning, let pid = dockApp.pid,
               !appState.isExcluded(bundleID: dockApp.bundleIdentifier) {
                let windows = windowManager.windowsForApp(pid: pid)
                if windows.count >= 2 {
                    // 2+ windows: suppress click, keep preview (or switch to this app's preview)
                    let bundleID = dockApp.bundleIdentifier ?? dockApp.name
                    if bundleID != lastHoveredBundleID {
                        // Clicked a different app — switch preview
                        highlightOverlay.hide()
                        previewPanel.dismissPanel(animated: false)
                        lastHoveredBundleID = bundleID
                        DispatchQueue.main.async { [weak self] in
                            self?.showPreviewForWindows(windows, at: point, interactive: true)
                        }
                    }
                    // Same app — just keep existing preview
                    return true
                } else {
                    // 1 window: dismiss preview, let click through to activate app
                    highlightOverlay.hide()
                    previewPanel.dismissPanel(animated: false)
                    previewIsVisible = false
                    // Keep bundle ID so hover poll doesn't re-trigger for this app
                    lastHoveredBundleID = dockApp.bundleIdentifier ?? dockApp.name
                    return false
                }
            }

            // Click is outside both the panel and the Dock — dismiss the preview
            // and let the click reach its target (pass-through), matching the
            // single-window Dock branch above. Reset previewIsVisible so the next
            // hover-poll tick doesn't briefly treat stale state as a fresh hover.
            highlightOverlay.hide()
            previewPanel.dismissPanel(animated: false)
            previewIsVisible = false
            lastHoveredBundleID = nil
            return false
        }

        // No preview visible — clear hover state
        lastHoveredBundleID = nil

        // Debounce (only for new preview triggers, not panel interactions)
        let now = Date()
        guard now.timeIntervalSince(lastClickTime) > debounceInterval else { return false }
        lastClickTime = now

        // Fast geometric check: skip AX calls if click is outside Dock area
        guard isPointInDockArea(point) else { return false }

        // Hit-test the Dock (AX call — only runs for Dock area clicks)
        guard let dockApp = dockInspector.appAtPoint(point) else { return false }

        // App not running → let the click through so the Dock launches it.
        guard dockApp.isRunning, let pid = dockApp.pid else { return false }
        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) { return false }

        // Count windows (fast — no thumbnails yet)
        let windows = windowManager.windowsForApp(pid: pid)

        // Fewer than 2 windows: nothing to choose between, keep the Dock's default behavior.
        if windows.count < 2 { return false }

        // Suppress click and show preview asynchronously.
        // Record the clicked bundle BEFORE dispatching — the hover poll runs
        // at ~15Hz and would otherwise see `lastHoveredBundleID == nil`, treat
        // the mouse-on-dock position as a fresh hover, dismiss the just-shown
        // panel and re-show it (visible as a flicker since showPreview fades
        // from alpha 0 each time).
        dpLog("Will show preview for \(dockApp.name) (\(windows.count) windows)")
        lastHoveredBundleID = dockApp.bundleIdentifier ?? dockApp.name
        DispatchQueue.main.async { [weak self] in
            self?.showPreviewForWindows(windows, at: point, interactive: true)
        }
        return true
    }

    // MARK: - Dock Area Detection

    /// Fast geometric check — is the click point in the Dock region?
    /// Uses the gap between screen.frame and screen.visibleFrame.
    private func isPointInDockArea(_ point: CGPoint) -> Bool {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let full = screen.frame
            let vis = screen.visibleFrame
            // Convert CG (top-left) to Cocoa (bottom-left)
            // Must use primary screen height — CG origin is at top-left of primary screen
            let cocoaY = primaryH - point.y

            // Check if the point is on this screen
            let cocoaPoint = NSPoint(x: point.x, y: cocoaY)
            guard full.contains(cocoaPoint) else { continue }

            let bottomGap = vis.minY - full.minY
            let leftGap = vis.minX - full.minX
            let rightGap = full.maxX - vis.maxX

            if bottomGap > 30, cocoaY < vis.minY { return true }
            if leftGap > 30, point.x < vis.minX { return true }
            if rightGap > 30, point.x > vis.maxX { return true }

            // Auto-hide Dock: check if point is near screen edge
            if isDockAutoHide {
                let dockSize: CGFloat = 100
                switch dockOrientation {
                case "left":
                    if point.x < full.minX + dockSize { return true }
                case "right":
                    if point.x > full.maxX - dockSize { return true }
                default: // "bottom"
                    if cocoaY < full.minY + dockSize { return true }
                }
            }
        }
        return false
    }

    // MARK: - Preview

    // MARK: - New Window → Primary Screen

    private func setupNewWindowObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        dpLog("appDidLaunch: \(app.localizedName ?? "?") pid=\(pid)")

        // Watch the newly launched app and move its first window to the primary
        // screen once it appears. The cursor is never moved to steer placement.
        let callback: AXObserverCallback = { _, element, _, _ in
            // Try element as window first, fall back to focused window
            var axWin: AXUIElement = element
            var posRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) != .success {
                var focusedRef: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef)
                guard let focused = focusedRef,
                      CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID() else { return }
                axWin = focused as! AXUIElement
            }
            moveAXWindowToPrimaryIfNeeded(axWin)
        }

        // Clean up existing observer for this PID if any
        removeAXObserver(pid: pid)

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer

        // Also observe app termination to clean up immediately.
        // Use a class-based box to avoid a retain cycle between the closure
        // and the local variable that holds the notification token.
        class TokenBox { var token: NSObjectProtocol? }
        let tokenBox = TokenBox()
        tokenBox.token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self, weak tokenBox] note in
            guard let terminated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  terminated.processIdentifier == pid else { return }
            self?.removeAXObserver(pid: pid)
            if let token = tokenBox?.token {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                tokenBox?.token = nil
            }
        }

        // Exponential backoff polling: 5 checks covering ~2s window
        // AXObserver alone is unreliable — this catches windows the observer misses
        let axAppRef = axApp
        let backoffDelays: [Double] = [0.1, 0.3, 0.7, 1.2, 2.0]
        for delay in backoffDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.moveAppWindowToPrimaryIfNeeded(axApp: axAppRef)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak tokenBox] in
            self?.removeAXObserver(pid: pid)
            if let token = tokenBox?.token {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                tokenBox?.token = nil
            }
        }
    }

    /// Move the focused window of an app to primary screen if it's not already there.
    private func moveAppWindowToPrimaryIfNeeded(axApp: AXUIElement) {
        var focusedRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard let focusedVal = focusedRef,
              CFGetTypeID(focusedVal as CFTypeRef) == AXUIElementGetTypeID() else { return }
        moveAXWindowToPrimaryIfNeeded(focusedVal as! AXUIElement)
    }

    private func removeAXObserver(pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Preview

    private func showPreviewForWindows(_ windows: [WindowInfo], at point: CGPoint, interactive: Bool, reuse: Bool = false) {
        previewIsVisible = true
        let thumbSize = CGFloat(appState.thumbnailSize)

        // Cache hits render immediately; misses are captured off the main thread
        // and merged into the panel when ready.
        var enriched = windows
        var missingIDs: [CGWindowID] = []
        for i in enriched.indices {
            if let cached = windowManager.cachedThumbnail(for: enriched[i].id, maxSize: thumbSize) {
                enriched[i].thumbnail = cached
            } else {
                missingIDs.append(enriched[i].id)
            }
        }

        if !missingIDs.isEmpty {
            windowManager.loadThumbnails(for: missingIDs, maxSize: thumbSize) { [weak self] thumbnails in
                guard let self, self.previewIsVisible else { return }
                self.previewPanel.updateThumbnails(thumbnails)
            }
        }

        previewPanel.showPreview(
            windows: enriched,
            thumbnailSize: thumbSize,
            showTitles: true,
            backgroundOpacity: CGFloat(appState.previewOpacity),
            useAccentTint: appState.previewUseAccentTint,
            grabsKeyboard: interactive,
            reuse: reuse,
            near: point,
            onSelect: { [weak self] win in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel(animated: false)
                self?.previewIsVisible = false
                self?.windowManager.activateWindow(windowID: win.id, pid: win.ownerPID)
            },
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
            onSnap: { [weak self] win, position in
                // Keep the preview open — user may want to snap another window
                // or continue interacting. Hide the highlight overlay because
                // the snapped window's position has changed.
                self?.highlightOverlay.hide()
                self?.windowManager.snapWindow(windowID: win.id, pid: win.ownerPID, position: position)
            },
            onDismiss: { [weak self] in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel()
            },
            onHoverWindow: { [weak self] (win: WindowInfo?) in
                guard let self else { return }
                guard let win else {
                    self.highlightOverlay.hide()
                    return
                }

                let isNewTarget = self.highlightOverlay.currentWindowID != win.id
                self.highlightOverlay.show(
                    for: win,
                    cachedImage: win.thumbnail,
                    opacity: CGFloat(self.appState.previewOpacity),
                    useAccentTint: self.appState.previewUseAccentTint
                )
                guard isNewTarget else { return }

                // The thumbnail is card-sized; swap in a full-size capture once
                // it's ready so the overlay isn't a blurry upscale.
                self.windowManager.captureFullImage(windowID: win.id) { [weak self] image in
                    guard let image else { return }
                    self?.highlightOverlay.updateImage(image, for: win.id)
                }
            }
        )
    }
}

// MARK: - Primary Screen Move Helper

/// Move an AX window to the center of the primary screen if it's not already there.
/// Free function so it can be called from both the AXObserverCallback (C function)
/// and from AppDelegate instance methods.
private func moveAXWindowToPrimaryIfNeeded(_ axWindow: AXUIElement) {
    guard let primary = NSScreen.screens.first else { return }
    let pH = primary.frame.height
    let vis = primary.visibleFrame
    let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                           width: primary.frame.width, height: primary.frame.height)

    var posRef: AnyObject?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
    var pos = CGPoint.zero
    if let p = posRef, CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID() {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    }
    guard !primaryCG.contains(pos) else { return }

    var sizeRef: AnyObject?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
    var sz = CGSize(width: 800, height: 600)
    if let s = sizeRef, CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() {
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
    }

    var newPos = CGPoint(
        x: vis.minX + (vis.width - sz.width) / 2,
        y: (pH - vis.maxY) + (vis.height - sz.height) / 2
    )
    if let axPos = AXValueCreate(.cgPoint, &newPos) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
        dpLog("Moved window to primary screen center")
    }
}
