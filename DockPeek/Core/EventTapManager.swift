import Cocoa
import CoreGraphics

protocol EventTapManagerDelegate: AnyObject {
    /// Return true to suppress the event (prevent Dock from handling it).
    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool
}

final class EventTapManager {
    weak var delegate: EventTapManagerDelegate?

    private(set) var isActive = false
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionWatchdog: DispatchSourceTimer?

    func start() {
        guard !isActive else { return }

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            dpLog("Failed to create event tap — accessibility permission required")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isActive = true
            dpLog("Event tap started")
            startPermissionWatchdog()
        }
    }

    func stop() {
        stopPermissionWatchdog()
        emergencyInvalidateTap()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        dpLog("Event tap stopped and invalidated")
    }

    /// Immediately invalidate the mach port — safe to call from ANY thread.
    /// This is the critical operation that unblocks HID events when permission is revoked.
    fileprivate func emergencyInvalidateTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    // MARK: - Background Permission Watchdog

    /// Monitors accessibility permission from a BACKGROUND thread.
    /// When the user deletes the permission entry, the main thread may freeze
    /// because the HID-level event tap blocks all input. A background thread
    /// is NOT blocked by this, so it can invalidate the tap and unfreeze the system.
    private func startPermissionWatchdog() {
        stopPermissionWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            if !AXIsProcessTrusted() {
                dpLog("Watchdog: permission lost — emergency tap invalidation")
                // Invalidate from background thread to unblock HID events
                self?.emergencyInvalidateTap()
                // Let stop() on main thread handle watchdog cleanup (avoids race)
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
        }
        timer.resume()
        permissionWatchdog = timer
    }

    private func stopPermissionWatchdog() {
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
    }

    fileprivate func handleEvent(_ event: CGEvent) -> Bool {
        delegate?.eventTapManager(self, didDetectClickAt: event.location) ?? false
    }
}

// MARK: - C callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

    // SAFETY: If permission was revoked, pass event through and destroy tap immediately.
    // This prevents system-wide input freeze when the user deletes the permission entry.
    if !AXIsProcessTrusted() {
        dpLog("Callback: permission lost — passing event through and destroying tap")
        manager.emergencyInvalidateTap()
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Permission may have been revoked — check before re-enabling
        if AXIsProcessTrusted() {
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            dpLog("Event tap re-enabled after system disable")
        } else {
            // Permission revoked — stop the tap immediately to prevent input freeze
            dpLog("Accessibility permission lost — stopping event tap to prevent input freeze")
            DispatchQueue.main.async { manager.stop() }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .leftMouseDown else {
        return Unmanaged.passUnretained(event)
    }

    if manager.handleEvent(event) {
        dpLog("Event suppressed — showing preview")
        return nil
    }

    return Unmanaged.passUnretained(event)
}
