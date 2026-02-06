import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, EventTapManagerDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let eventTapManager = EventTapManager()
    private let dockInspector = DockAXInspector()
    private let windowManager = WindowManager()
    private let previewPanel = PreviewPanel()
    private let highlightOverlay = HighlightOverlay()

    private var lastClickTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.3
    private var accessibilityTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()

        if AccessibilityManager.shared.isAccessibilityGranted {
            startEventTap()
        } else {
            showOnboarding()
            startAccessibilityPolling()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle",
                                   accessibilityDescription: "DockPeek")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(appState: appState)
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                timer.invalidate()
                self.accessibilityTimer = nil
            }
        }
    }

    // MARK: - Event Tap

    private func startEventTap() {
        eventTapManager.delegate = self
        eventTapManager.start()
        dpLog("Event tap delegate connected")
    }

    // MARK: - EventTapManagerDelegate

    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool {
        guard appState.isEnabled else { return false }

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
            // Click is outside — dismiss and SUPPRESS (prevent Dock activation)
            previewPanel.dismissPanel(animated: false)
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
        guard dockApp.isRunning, let pid = dockApp.pid else { return false }
        if appState.isExcluded(bundleID: dockApp.bundleIdentifier) { return false }

        // Count windows (fast — no thumbnails yet)
        let windows = windowManager.windowsForApp(pid: pid)
        guard windows.count >= 2 else { return false }

        // Suppress click and show preview asynchronously
        dpLog("Will show preview for \(dockApp.name) (\(windows.count) windows)")
        DispatchQueue.main.async { [weak self] in
            self?.showPreviewForWindows(windows, at: point)
        }
        return true
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
                // Refresh preview after short delay to let window close
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
