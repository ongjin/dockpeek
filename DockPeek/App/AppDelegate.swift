import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, EventTapManagerDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let appState = AppState()
    private let eventTapManager = EventTapManager()
    private let dockInspector = DockAXInspector()
    private let windowManager = WindowManager()
    private let previewPanel = PreviewPanel()
    private let highlightOverlay = HighlightOverlay()

    private let updateChecker = UpdateChecker.shared
    private var lastClickTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.3
    private var accessibilityTimer: Timer?
    private var axObservers: [pid_t: AXObserver] = [:]

    // Hover preview
    private var hoverPollTimer: DispatchSourceTimer?
    private var hoverTimer: DispatchWorkItem?
    private var hoverDismissTimer: DispatchWorkItem?
    private var lastHoveredBundleID: String?
    private var hoverSettingObserver: AnyCancellable?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupCmdCommaShortcut()
        setupNewWindowObserver()

        if AccessibilityManager.shared.isAccessibilityGranted {
            startEventTap()
            if appState.previewOnHover { startHoverMonitor() }
            startPermissionMonitor()
        } else {
            showOnboarding()
            startAccessibilityPolling()
        }

        observeHoverSetting()

        // Auto-check for updates (respects 24-hour cooldown)
        updateChecker.check(force: false) { [weak self] available in
            if available { self?.showUpdateAlert() }
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
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate()
    }

    // MARK: - Update Check

    @objc private func checkForUpdates() {
        updateChecker.check(force: true) { [weak self] available in
            if available {
                self?.showUpdateAlert()
            } else {
                self?.showUpToDateAlert()
            }
        }
    }

    private func showUpdateAlert() {
        let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let remote = updateChecker.latestVersion
        let hasBrew = updateChecker.isBrewInstalled

        let alert = NSAlert()
        alert.messageText = L10n.updateAvailable
        alert.informativeText = String(format: L10n.updateMessage, remote, local)
            + (hasBrew ? "\n\n" + L10n.autoUpdateHint : "\n\n" + L10n.brewHint)
        alert.alertStyle = .informational

        if hasBrew {
            alert.addButton(withTitle: L10n.autoUpdate) // First button
            alert.addButton(withTitle: L10n.later)
            alert.addButton(withTitle: L10n.download)   // Fallback
        } else {
            alert.addButton(withTitle: L10n.download)
            alert.addButton(withTitle: L10n.later)
        }

        NSApp.activate()
        let response = alert.runModal()

        if hasBrew {
            if response == .alertFirstButtonReturn {
                updateChecker.performBrewUpgrade()
            } else if response == .alertThirdButtonReturn,
                      let url = URL(string: updateChecker.releaseURL) {
                NSWorkspace.shared.open(url)
            }
        } else {
            if response == .alertFirstButtonReturn,
               let url = URL(string: updateChecker.releaseURL) {
                NSWorkspace.shared.open(url)
            }
        }
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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // Show in Dock while settings window is open
        NSApp.setActivationPolicy(.regular)

        let settingsView = SettingsView(appState: appState)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 520)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "DockPeek \(L10n.general)"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    // MARK: - Cmd+, Shortcut

    private func setupCmdCommaShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self?.openSettings()
                return nil
            }
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        // Hide from Dock when settings window closes
        NSApp.setActivationPolicy(.accessory)
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
        window.contentView = NSHostingView(rootView: OnboardingView(onDismiss: {
            window.close()
        }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startAccessibilityPolling() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityManager.shared.isAccessibilityGranted {
                self.startEventTap()
                if self.appState.previewOnHover { self.startHoverMonitor() }
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

    // MARK: - Hover Monitor

    /// Observe previewOnHover toggle — start/stop monitor dynamically
    private func observeHoverSetting() {
        hoverSettingObserver = appState.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.appState.previewOnHover {
                    if self.hoverPollTimer == nil,
                       AccessibilityManager.shared.isAccessibilityGranted {
                        self.startHoverMonitor()
                    }
                } else {
                    self.stopHoverMonitor()
                }
            }
        }
    }

    private func startHoverMonitor() {
        stopHoverMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.pollMouseForHover()
        }
        timer.resume()
        hoverPollTimer = timer
        dpLog("Hover poll timer started (200ms interval)")
    }

    private func stopHoverMonitor() {
        hoverPollTimer?.cancel()
        hoverPollTimer = nil
        hoverTimer?.cancel()
        hoverTimer = nil
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil
        lastHoveredBundleID = nil
    }

    private func pollMouseForHover() {
        let cocoaLoc = NSEvent.mouseLocation
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: cocoaLoc.x, y: screenH - cocoaLoc.y)

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
                // Delayed dismiss — gives time to cross the gap to the preview panel
                if hoverDismissTimer == nil {
                    let task = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lastHoveredBundleID = nil
                        self.hoverDismissTimer = nil
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

        // Different app — cancel old timer and dismiss current preview
        hoverTimer?.cancel()
        let wasVisible = previewPanel.isVisible
        if wasVisible {
            highlightOverlay.hide()
            previewPanel.dismissPanel(animated: false)
        }
        lastHoveredBundleID = bundleID

        guard dockApp.isRunning, let pid = dockApp.pid else {
            hoverTimer = nil
            return
        }

        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) {
            hoverTimer = nil
            return
        }

        // Instant switch when already browsing, normal delay for first hover
        if wasVisible {
            handleHoverPreview(for: pid, at: cgPoint)
        } else {
            let task = DispatchWorkItem { [weak self] in
                self?.handleHoverPreview(for: pid, at: cgPoint)
            }
            hoverTimer = task
            DispatchQueue.main.asyncAfter(deadline: .now() + appState.hoverDelay, execute: task)
        }
    }

    private func handleHoverPreview(for pid: pid_t, at point: CGPoint) {
        guard appState.previewOnHover else { return }

        let windows = windowManager.windowsForApp(pid: pid)
        guard !windows.isEmpty else { return }

        dpLog("Hover preview: \(windows.count) window(s) for PID \(pid)")
        showPreviewForWindows(windows, at: point)
    }

    // MARK: - Permission Monitor

    private var permissionMonitorTimer: Timer?

    /// Periodically checks if accessibility permission is still granted.
    /// If revoked, stops the event tap immediately to prevent system-wide input freeze.
    private func startPermissionMonitor() {
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
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
            }
        }
    }

    // MARK: - EventTapManagerDelegate

    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool {
        guard appState.isEnabled else { return false }

        // Cancel any pending hover timer on click
        hoverTimer?.cancel()
        hoverTimer = nil
        lastHoveredBundleID = nil

        // Cancel any pending dismiss timer
        hoverDismissTimer?.cancel()
        hoverDismissTimer = nil

        // If preview is visible, handle click without debounce
        if previewPanel.isVisible {
            let panelFrame = previewPanel.frame
            let screenH = NSScreen.main?.frame.height ?? 0
            // Convert CG point (top-left origin) to Cocoa (bottom-left origin)
            let cocoaPoint = NSPoint(x: point.x, y: screenH - point.y)
            if panelFrame.contains(cocoaPoint) {
                // Click is on the preview panel — let it through to SwiftUI
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
                            self?.showPreviewForWindows(windows, at: point)
                        }
                    }
                    // Same app — just keep existing preview
                    return true
                } else {
                    // 1 window: dismiss preview, let click through to activate app
                    highlightOverlay.hide()
                    previewPanel.dismissPanel(animated: false)
                    lastHoveredBundleID = nil
                    return false
                }
            }

            // Click is outside dock — dismiss and SUPPRESS
            highlightOverlay.hide()
            previewPanel.dismissPanel(animated: false)
            lastHoveredBundleID = nil
            return true
        }

        // Debounce (only for new preview triggers, not panel interactions)
        let now = Date()
        guard now.timeIntervalSince(lastClickTime) > debounceInterval else { return false }
        lastClickTime = now

        // Fast geometric check: skip AX calls if click is outside Dock area
        guard isPointInDockArea(point) else { return false }

        // Hit-test the Dock (AX call — only runs for Dock area clicks)
        guard let dockApp = dockInspector.appAtPoint(point) else { return false }

        // App not running → Dock will launch it. Warp cursor to primary
        // BEFORE the click reaches Dock so macOS natively places the window there.
        guard dockApp.isRunning, let pid = dockApp.pid else {
            if appState.forceNewWindowsToPrimary {
                warpCursorToPrimaryBriefly()
            }
            return false
        }
        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) { return false }

        // Count windows (fast — no thumbnails yet)
        let windows = windowManager.windowsForApp(pid: pid)

        // Running app with < 2 windows: Dock click will create/activate a window.
        // Warp cursor so the new window appears on primary.
        if windows.count < 2, appState.forceNewWindowsToPrimary {
            warpCursorToPrimaryBriefly()
            return false
        }

        guard windows.count >= 2 else { return false }

        // Suppress click and show preview asynchronously
        dpLog("Will show preview for \(dockApp.name) (\(windows.count) windows)")
        DispatchQueue.main.async { [weak self] in
            self?.showPreviewForWindows(windows, at: point)
        }
        return true
    }

    // MARK: - Cursor Warp (Primary Screen Enforcement)

    private var cursorRestoreTask: DispatchWorkItem?

    /// Warp cursor to primary screen center so macOS places the new window there.
    /// Called BEFORE the click reaches the Dock — the window is created natively on primary.
    /// Cursor is restored after the app window appears.
    private func warpCursorToPrimaryBriefly() {
        guard let primary = NSScreen.screens.first else { return }
        let pH = primary.frame.height

        // Save current position (Cocoa → CG)
        let savedCocoa = NSEvent.mouseLocation
        let savedCG = CGPoint(x: savedCocoa.x, y: pH - savedCocoa.y)
        let primaryCenter = CGPoint(x: primary.frame.midX, y: pH / 2)

        // Already on primary? Skip.
        let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                               width: primary.frame.width, height: primary.frame.height)
        if primaryCG.contains(savedCG) { return }

        dpLog("Warping cursor to primary center for window placement")

        // 1. Warp cursor position
        CGWarpMouseCursorPosition(primaryCenter)

        // 2. Post synthetic mouse-move event so macOS fully registers the new position.
        //    CGWarpMouseCursorPosition alone may not update all internal tracking.
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: primaryCenter, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        // Restore cursor after window has been placed
        cursorRestoreTask?.cancel()
        let task = DispatchWorkItem {
            CGWarpMouseCursorPosition(savedCG)
            if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                          mouseCursorPosition: savedCG, mouseButton: .left) {
                restoreEvent.post(tap: .cghidEventTap)
            }
        }
        cursorRestoreTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
    }

    // MARK: - Dock Area Detection

    /// Fast geometric check — is the click point in the Dock region?
    /// Uses the gap between screen.frame and screen.visibleFrame.
    private func isPointInDockArea(_ point: CGPoint) -> Bool {
        for screen in NSScreen.screens {
            let full = screen.frame
            let vis = screen.visibleFrame
            let screenH = full.height
            // Convert CG (top-left) to Cocoa (bottom-left)
            let cocoaY = screenH - point.y

            // Check if the point is on this screen
            let cocoaPoint = NSPoint(x: point.x, y: cocoaY)
            guard full.contains(cocoaPoint) else { continue }

            let bottomGap = vis.minY - full.minY
            let leftGap = vis.minX - full.minX
            let rightGap = full.maxX - vis.maxX

            if bottomGap > 30, cocoaY < vis.minY { return true }
            if leftGap > 30, point.x < vis.minX { return true }
            if rightGap > 30, point.x > vis.maxX { return true }
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
        guard appState.forceNewWindowsToPrimary else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        dpLog("appDidLaunch: \(app.localizedName ?? "?") pid=\(pid)")

        // Backup: AXObserver for apps launched via Spotlight/Launchpad (not through Dock click).
        // The primary strategy (cursor warp in event tap) handles Dock launches.
        let callback: AXObserverCallback = { _, element, _, _ in
            guard let primary = NSScreen.screens.first else { return }
            let pH = primary.frame.height
            let vis = primary.visibleFrame
            let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                                   width: primary.frame.width, height: primary.frame.height)

            // Try element as window first, fall back to focused window
            var axWin: AXUIElement = element
            var posRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) != .success {
                var focusedRef: AnyObject?
                AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef)
                guard let focused = focusedRef else { return }
                axWin = focused as! AXUIElement
                AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
            }

            var curPos = CGPoint.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &curPos) }
            if primaryCG.contains(curPos) { return }

            var sizeRef: AnyObject?
            AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef)
            var winSize = CGSize(width: 800, height: 600)
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &winSize) }

            var newPos = CGPoint(
                x: vis.minX + (vis.width - winSize.width) / 2,
                y: (pH - vis.maxY) + (vis.height - winSize.height) / 2
            )
            if let axPos = AXValueCreate(.cgPoint, &newPos) {
                AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, axPos)
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObservers[pid] = observer

        // Aggressive polling backup: check every 50ms for 2 seconds
        // AXObserver alone is unreliable — this catches windows the observer misses
        let axAppRef = axApp
        for i in 1...40 {
            let delay = Double(i) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.appState.forceNewWindowsToPrimary == true else { return }
                self?.moveAppWindowToPrimaryIfNeeded(axApp: axAppRef)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.removeAXObserver(pid: pid)
        }
    }

    /// Move the focused window of an app to primary screen if it's not already there.
    private func moveAppWindowToPrimaryIfNeeded(axApp: AXUIElement) {
        guard let primary = NSScreen.screens.first else { return }
        let pH = primary.frame.height
        let vis = primary.visibleFrame
        let primaryCG = CGRect(x: primary.frame.minX, y: pH - primary.frame.maxY,
                               width: primary.frame.width, height: primary.frame.height)

        var focusedRef: AnyObject?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard let focused = focusedRef else { return }
        let win = focused as! AXUIElement

        var posRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        guard !primaryCG.contains(pos) else { return }

        var sizeRef: AnyObject?
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var sz = CGSize(width: 800, height: 600)
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &sz) }

        var newPos = CGPoint(
            x: vis.minX + (vis.width - sz.width) / 2,
            y: (pH - vis.maxY) + (vis.height - sz.height) / 2
        )
        if let axPos = AXValueCreate(.cgPoint, &newPos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPos)
            dpLog("Polled and moved window to primary")
        }
    }

    private func removeAXObserver(pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Preview

    private func showPreviewForWindows(_ windows: [WindowInfo], at point: CGPoint) {
        let thumbSize = CGFloat(appState.thumbnailSize)
        var enriched = windows
        for i in enriched.indices {
            enriched[i].thumbnail = windowManager.thumbnail(for: enriched[i].id, maxSize: thumbSize)
        }

        previewPanel.showPreview(
            windows: enriched,
            thumbnailSize: thumbSize,
            showTitles: appState.showWindowTitles,
            near: point,
            onSelect: { [weak self] win in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel(animated: false)
                self?.windowManager.activateWindow(windowID: win.id, pid: win.ownerPID)
            },
            onClose: { [weak self] win in
                self?.highlightOverlay.hide()
                self?.windowManager.closeWindow(windowID: win.id, pid: win.ownerPID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let self else { return }
                    let remaining = self.windowManager.windowsForApp(pid: win.ownerPID)
                    if remaining.count < 2 {
                        self.previewPanel.dismissPanel()
                    } else {
                        self.showPreviewForWindows(remaining, at: point)
                    }
                }
            },
            onSnap: { [weak self] win, position in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel(animated: false)
                self?.windowManager.snapWindow(windowID: win.id, pid: win.ownerPID, position: position)
            },
            onDismiss: { [weak self] in
                self?.highlightOverlay.hide()
                self?.previewPanel.dismissPanel()
            },
            onHoverWindow: { [weak self] win in
                guard let self, self.appState.livePreviewOnHover else { return }
                if let win {
                    self.highlightOverlay.show(for: win)
                } else {
                    self.highlightOverlay.hide()
                }
            }
        )
    }
}
