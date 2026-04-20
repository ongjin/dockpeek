// DockPeek/Core/DockAnchorManager.swift
import AppKit
import ApplicationServices

final class DockAnchorManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPID: pid_t = 0

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
        dpLog("DockAnchor: PoC tap installed on Dock pid \(pid)")
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

    // PoC: log-only. Does not drop events yet.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .mouseMoved {
            let loc = event.location
            dpLog("DockAnchor PoC: mouseMoved at (\(Int(loc.x)), \(Int(loc.y)))")
        }
        return Unmanaged.passUnretained(event)
    }

    private static func findDockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
    }
}
