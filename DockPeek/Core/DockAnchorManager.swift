// DockPeek/Core/DockAnchorManager.swift
import AppKit
import ApplicationServices

final class DockAnchorManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPID: pid_t = 0
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

    deinit {
        stop()
    }

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

        recomputeTriggerZones()

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
        dpLog("DockAnchor: tap installed on Dock pid \(pid)")

        if isDockOnNonPrimary() {
            DispatchQueue.main.async { [weak self] in
                self?.warpDockToPrimary()
            }
        }
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

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
        let loc = event.location
        for zone in triggerZones where zone.contains(loc) {
            // Drop this event — the Dock will not see it.
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

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

    private static func findDockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
    }
}
