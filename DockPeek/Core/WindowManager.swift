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

enum SnapPosition { case left, right, fill }

final class WindowManager {

    /// Thumbnail cache: windowID → (image, timestamp)
    private var thumbnailCache: [CGWindowID: (NSImage, Date)] = [:]
    private let cacheTTL: TimeInterval = 5.0
    private let maxCacheSize = 30

    // MARK: - Window Enumeration

    /// Enumerate windows for an app. Only returns on-screen (visible) windows by default.
    /// Cross-references CGWindow list with AXUIElement windows to filter out
    /// overlays, helper windows, and other non-standard windows (e.g. Chrome translation bar).
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

        // Cross-reference with AX windows to filter out overlays/helper windows.
        // AX kAXWindowsAttribute only returns "real" user-facing windows,
        // excluding Chrome translation bars, tooltips, popovers, etc.
        let axIDs = axWindowIDs(for: pid)
        if !axIDs.isEmpty {
            let before = windows.count
            windows = windows.filter { axIDs.contains($0.id) }
            if windows.count != before {
                dpLog("AX filter: \(before) → \(windows.count) windows for PID \(pid)")
            }
        }

        dpLog("Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized))")
        return windows
    }

    /// Get the set of CGWindowIDs that correspond to real standard AX windows.
    /// Filters out popups, dialogs, floating panels, overlays (e.g. Chrome translation bar).
    private func axWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        guard let getWindow = _axGetWindow else { return [] }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let axWindows = ref as? [AXUIElement] else { return [] }

        var ids = Set<CGWindowID>()
        for axWin in axWindows {
            // Only include standard windows (skip dialogs, floating panels, popups)
            var subroleRef: AnyObject?
            AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = subroleRef as? String ?? ""
            guard subrole == "AXStandardWindow" else {
                dpLog("AX skip subrole=\(subrole) for PID \(pid)")
                continue
            }

            var wid: CGWindowID = 0
            if getWindow(axWin, &wid) == .success, wid != 0 {
                ids.insert(wid)
            }
        }
        return ids
    }

    // MARK: - Thumbnails

    func thumbnail(for windowID: CGWindowID, maxSize: CGFloat = 200) -> NSImage? {
        // Check cache
        if let cached = thumbnailCache[windowID],
           Date().timeIntervalSince(cached.1) < cacheTTL {
            return cached.0
        }

        // Prune expired entries and enforce size limit
        let now = Date()
        if thumbnailCache.count > maxCacheSize {
            thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.1) < cacheTTL }
            // Still over limit — remove oldest entries
            if thumbnailCache.count >= maxCacheSize {
                let sorted = thumbnailCache.sorted { $0.value.1 < $1.value.1 }
                for (id, _) in sorted.prefix(thumbnailCache.count - maxCacheSize + 1) {
                    thumbnailCache.removeValue(forKey: id)
                }
            }
        }

        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            dpLog("Thumbnail capture failed for window \(windowID)")
            return nil
        }

        // Draw CGImage directly into scaled size — avoids intermediate full-size NSImage
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let aspect = w / h
        let scaled: NSSize = aspect > 1
            ? NSSize(width: maxSize, height: maxSize / aspect)
            : NSSize(width: maxSize * aspect, height: maxSize)

        let result = NSImage(size: scaled, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.draw(cgImage, in: rect)
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

    // MARK: - Window Snapping

    func snapWindow(windowID: CGWindowID, pid: pid_t, position: SnapPosition) {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

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
        guard let axWindow = target else { return }

        // Get current window position to determine which screen it's on
        var posRef: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        var currentPos = CGPoint.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &currentPos) }

        let primaryH = NSScreen.screens[0].frame.height
        let screen = NSScreen.screens.first { s in
            let f = s.frame
            let cgFrame = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
            return cgFrame.contains(currentPos)
        } ?? NSScreen.main!

        let vis = screen.visibleFrame
        let cgY = primaryH - vis.maxY

        var targetRect: CGRect
        switch position {
        case .left:
            targetRect = CGRect(x: vis.minX, y: cgY, width: vis.width / 2, height: vis.height)
        case .right:
            targetRect = CGRect(x: vis.midX, y: cgY, width: vis.width / 2, height: vis.height)
        case .fill:
            targetRect = CGRect(x: vis.minX, y: cgY, width: vis.width, height: vis.height)
        }

        var pos = targetRect.origin
        var size = targetRect.size
        if let axPos = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
        }
        if let axSize = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        }

        activateWindow(windowID: windowID, pid: pid)
        dpLog("Snapped window \(windowID) to \(position)")
    }

    // MARK: - Move to Primary Screen

    /// Move all windows of an app that are NOT on the primary screen to its center.
    func moveNewWindowsToPrimary(pid: pid_t) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryH = primary.frame.height
        let primaryCG = CGRect(x: primary.frame.minX,
                               y: primaryH - primary.frame.maxY,
                               width: primary.frame.width,
                               height: primary.frame.height)

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        let vis = primary.visibleFrame
        let targetCGY = primaryH - vis.maxY

        for axWindow in axWindows {
            // Get current position
            var posRef: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
            var currentPos = CGPoint.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &currentPos) }

            // Skip if already on primary screen
            if primaryCG.contains(currentPos) { continue }

            // Get window size
            var sizeRef: AnyObject?
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
            var winSize = CGSize.zero
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &winSize) }

            // Center on primary screen's visible area
            var newPos = CGPoint(
                x: vis.minX + (vis.width - winSize.width) / 2,
                y: targetCGY + (vis.height - winSize.height) / 2
            )

            if let axPos = AXValueCreate(.cgPoint, &newPos) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
            }
            dpLog("Moved window to primary screen for PID \(pid)")
        }
    }
}
