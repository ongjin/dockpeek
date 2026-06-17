import Cocoa
import os

protocol EventTapManagerDelegate: AnyObject {
    /// Return true to suppress the event (prevent Dock from handling it).
    func eventTapManager(_ manager: EventTapManager, didDetectClickAt point: CGPoint) -> Bool
    /// Called on the main thread after the tap was torn down because accessibility
    /// permission was lost (the watchdog's emergency path). Lets the delegate switch
    /// to permission polling so the tap restarts promptly when permission returns —
    /// the emergency stop beats the slow 30s monitor, which would otherwise never
    /// re-arm the recovery.
    func eventTapManagerDidLosePermission(_ manager: EventTapManager)
}

final class EventTapManager {
    weak var delegate: EventTapManagerDelegate?

    private(set) var isActive = false

    deinit {
        stop()
    }

    // Serializes access to `eventTap`, which is read from the C tap callback
    // (HID thread) and the background watchdog while stop() (main) nils it.
    // Critical sections are a single pointer read/write — nanoseconds — and main
    // holds the lock only inside start()/stop() (neither blocks), so the recovery
    // path (emergencyInvalidateTap) is never contended during an input freeze.
    private let lock = OSAllocatedUnfairLock()
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

        // Publish the tap under the lock BEFORE enabling it, so the callback
        // thread sees the write (memory barrier) once events start flowing.
        lock.withLock { eventTap = tap }
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
        lock.withLock { eventTap = nil }
        runLoopSource = nil
        isActive = false
        dpLog("Event tap stopped and invalidated")
    }

    /// Immediately invalidate the mach port — safe to call from ANY thread.
    /// This is the critical operation that unblocks HID events when permission is revoked.
    fileprivate func emergencyInvalidateTap() {
        // Snapshot under the lock, then operate on the snapshot OUTSIDE the lock.
        // The snapshot keeps the port alive even if stop() nils the property
        // concurrently, and CFMachPortInvalidate is idempotent, so a double
        // invalidation is harmless. The lock is released before the CG calls, so
        // this stays non-blocking — the load-bearing requirement for the
        // background watchdog's recovery path.
        guard let tap = snapshotTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    /// Thread-safe snapshot of the live tap (or nil).
    fileprivate func snapshotTap() -> CFMachPort? {
        lock.withLock { eventTap }
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
                // Cleanup + recovery on main (avoids race). Notify the delegate so
                // it can re-arm permission polling; the HID unblock above already
                // happened, so this runs outside the freeze-critical path.
                DispatchQueue.main.async {
                    self?.stop()
                    if let self { self.delegate?.eventTapManagerDidLosePermission(self) }
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
            if let tap = manager.snapshotTap() {
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
