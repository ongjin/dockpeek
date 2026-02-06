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

    func start() {
        guard !isActive else { return }

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
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
        }
    }

    func stop() {
        guard isActive else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        dpLog("Event tap stopped")
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

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        dpLog("Event tap re-enabled after system disable")
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
