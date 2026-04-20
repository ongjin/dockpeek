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

    private static func findDockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
    }
}
