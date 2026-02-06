import AppKit
import CoreGraphics
import ApplicationServices

// Private/deprecated API wrappers loaded at runtime via dlsym
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private typealias SLPSSetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private let _slpsSetFront: SLPSSetFrontFn? = {
    guard let handle = skylight, let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: SLPSSetFrontFn.self)
}()

@_silgen_name("GetProcessForPID")
@discardableResult
private func GetPSNForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// Private API: get CGWindowID from an AXUIElement (100% reliable window matching)
private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let _axGetWindow: AXUIElementGetWindowFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: AXUIElementGetWindowFn.self)
}()

final class WindowManager {

    /// Thumbnail cache: windowID → (image, timestamp)
    private var thumbnailCache: [CGWindowID: (NSImage, Date)] = [:]
    private let cacheTTL: TimeInterval = 0.5

    // MARK: - Window Enumeration

    /// Enumerate windows for an app. Only returns on-screen (visible) windows by default.
    func windowsForApp(pid: pid_t, includeMinimized: Bool = false) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            dpLog("CGWindowListCopyWindowInfo failed")
            return []
        }

        var windows: [WindowInfo] = []

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }

            guard let bd = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  bounds.width > 1, bounds.height > 1 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0 else { continue }

            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

            // Skip off-screen / hidden windows unless includeMinimized is set
            if !isOnScreen && !includeMinimized { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""

            windows.append(WindowInfo(
                id: windowID, title: title, bounds: bounds,
                ownerPID: ownerPID, ownerName: ownerName,
                isOnScreen: isOnScreen, isMinimized: !isOnScreen,
                thumbnail: nil
            ))
        }

        dpLog("Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized))")
        return windows
    }

    // MARK: - Thumbnails

    func thumbnail(for windowID: CGWindowID, maxSize: CGFloat = 200) -> NSImage? {
        // Check cache
        if let cached = thumbnailCache[windowID],
           Date().timeIntervalSince(cached.1) < cacheTTL {
            return cached.0
        }

        // Prune expired entries
        let now = Date()
        thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.1) < cacheTTL }

        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            dpLog("Thumbnail capture failed for window \(windowID)")
            return nil
        }

        let full = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let aspect = full.size.width / full.size.height
        let scaled: NSSize = aspect > 1
            ? NSSize(width: maxSize, height: maxSize / aspect)
            : NSSize(width: maxSize * aspect, height: maxSize)

        let result = NSImage(size: scaled, flipped: false) { rect in
            full.draw(in: rect)
            return true
        }

        thumbnailCache[windowID] = (result, now)
        return result
    }

    // MARK: - Window Activation

    func activateWindow(windowID: CGWindowID, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        let app = NSRunningApplication(processIdentifier: pid)

        // 1. Get AX windows
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
            dpLog("Could not get AX windows for PID \(pid) — activating app only")
            app?.activate()
            return
        }

        // 2. Match AX window by CGWindowID (100% reliable via private API)
        var targetAXWindow: AXUIElement?

        if let getWindow = _axGetWindow {
            // Direct match: AXUIElement → CGWindowID
            for axWindow in axWindows {
                var axWID: CGWindowID = 0
                if getWindow(axWindow, &axWID) == .success, axWID == windowID {
                    targetAXWindow = axWindow
                    dpLog("Matched by CGWindowID: \(windowID)")
                    break
                }
            }
        }

        // Fallback: title match, then position+size
        if targetAXWindow == nil {
            var targetTitle: String?
            var targetBounds: CGRect?
            if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                for info in list {
                    if let wid = info[kCGWindowNumber as String] as? CGWindowID, wid == windowID {
                        targetTitle = info[kCGWindowName as String] as? String
                        if let bd = info[kCGWindowBounds as String] as? [String: Any] {
                            targetBounds = CGRect(dictionaryRepresentation: bd as CFDictionary)
                        }
                        break
                    }
                }
            }

            // Title match
            if let t = targetTitle, !t.isEmpty {
                for axWindow in axWindows {
                    var titleRef: AnyObject?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                    if let axTitle = titleRef as? String, axTitle == t {
                        targetAXWindow = axWindow
                        dpLog("Fallback matched by title: '\(t)'")
                        break
                    }
                }
            }

            // Position+size match
            if targetAXWindow == nil, let tb = targetBounds {
                for axWindow in axWindows {
                    var posRef: AnyObject?
                    var sizeRef: AnyObject?
                    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
                    if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
                    if abs(tb.origin.x - pos.x) < 5, abs(tb.origin.y - pos.y) < 5,
                       abs(tb.width - size.width) < 5, abs(tb.height - size.height) < 5 {
                        targetAXWindow = axWindow
                        dpLog("Fallback matched by position+size")
                        break
                    }
                }
            }
        }

        if targetAXWindow == nil {
            dpLog("No match — fallback to first AX window")
            targetAXWindow = axWindows[0]
        }

        guard let axWindow = targetAXWindow else { return }

        // 3. Activate: SkyLight first, then AX raise (AltTab's proven approach)
        //    SkyLight handles both Space switching (full-screen) and single-window
        //    activation (normal). AX raise after ensures the correct window is on top.
        var psn = ProcessSerialNumber()
        GetPSNForPID(pid, &psn)

        if let slps = _slpsSetFront {
            slps(&psn, UInt32(windowID), 0x2)
        } else {
            app?.activate()
        }

        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)

        dpLog("Activated window \(windowID) for PID \(pid)")
    }

    func activateApp(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    // MARK: - Close Window

    func closeWindow(windowID: CGWindowID, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            dpLog("closeWindow: could not get AX windows for PID \(pid)")
            return
        }

        // Match by CGWindowID (same logic as activateWindow)
        var target: AXUIElement?
        if let getWindow = _axGetWindow {
            for axWin in axWindows {
                var axWID: CGWindowID = 0
                if getWindow(axWin, &axWID) == .success, axWID == windowID {
                    target = axWin
                    break
                }
            }
        }

        guard let axWindow = target else {
            dpLog("closeWindow: no AX match for window \(windowID)")
            return
        }

        // Get the close button and press it
        var closeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success else {
            dpLog("closeWindow: no close button for window \(windowID)")
            return
        }
        let closeButton = closeRef as! AXUIElement
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        dpLog("Closed window \(windowID)")
    }
}
