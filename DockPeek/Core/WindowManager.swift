import AppKit

// Private/deprecated API wrappers loaded at runtime via dlsym
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private typealias SLPSSetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private let _slpsSetFront: SLPSSetFrontFn? = {
    guard let handle = skylight, let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: SLPSSetFrontFn.self)
}()

private typealias SLPSPostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
private let _slpsPostEventRecordTo: SLPSPostEventRecordToFn? = {
    guard let handle = skylight, let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
    return unsafeBitCast(sym, to: SLPSPostEventRecordToFn.self)
}()

/// Make a specific window the key (keyboard-focused) window of its process.
/// `_SLPSSetFrontProcessWithOptions` raises the process but does not transfer
/// key status to a particular window in a multi-window app — so the clicked
/// window comes forward yet stays unfocused. These two synthetic SkyLight event
/// records (the Hammerspoon/AltTab sequence) transfer key focus to the window.
/// Purely internal window-server IPC: no cursor movement, no visible events.
private func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
    guard let post = _slpsPostEventRecordTo else { return }
    var wid = windowID
    var bytes1 = [UInt8](repeating: 0, count: 0xf8)
    bytes1[0x04] = 0xf8
    bytes1[0x08] = 0x01
    bytes1[0x3a] = 0x10
    _ = withUnsafeBytes(of: &wid) { memcpy(&bytes1[0x3c], $0.baseAddress!, MemoryLayout<UInt32>.size) }
    memset(&bytes1[0x20], 0xff, 0x10)
    var bytes2 = bytes1
    bytes2[0x08] = 0x02
    _ = post(&psn, &bytes1)
    _ = post(&psn, &bytes2)
}

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

    /// A downscaled capture, tagged with the size it was rendered for so a
    /// changed thumbnail-size setting doesn't reuse a bitmap of the wrong size.
    private struct CachedThumbnail {
        let image: NSImage
        let maxSize: CGFloat
        let timestamp: Date
    }

    /// Thumbnail cache keyed by window. Main thread only.
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]
    private let cacheTTL: TimeInterval = 5.0
    private let extendedCacheTTL: TimeInterval = 10.0
    private var cachePurgeTask: DispatchWorkItem?

    /// Whether preview panel is currently visible — set by AppDelegate to extend cache TTL.
    /// Hiding the preview schedules a purge so captures don't stay in memory while idle.
    var isPreviewVisible = false {
        didSet {
            guard oldValue, !isPreviewVisible else { return }
            scheduleCachePurge()
        }
    }

    init() {
        loadWindowOrder()
    }

    private func loadWindowOrder() {
        guard let raw = UserDefaults.standard.dictionary(forKey: windowOrderDefaultsKey) else { return }
        var result: [String: [CGWindowID]] = [:]
        for (bundle, value) in raw {
            if let nums = value as? [NSNumber] {
                result[bundle] = nums.map { CGWindowID($0.uint32Value) }
            }
        }
        windowOrderByBundle = result
        dpLog("Loaded window order for \(result.count) bundle(s)")
    }

    private func saveWindowOrder() {
        var serializable: [String: [NSNumber]] = [:]
        for (bundle, ids) in windowOrderByBundle {
            serializable[bundle] = ids.map { NSNumber(value: UInt32($0)) }
        }
        UserDefaults.standard.set(serializable, forKey: windowOrderDefaultsKey)
    }

    /// Latest CGWindowListCopyWindowInfo snapshot. The list is system-wide, so one
    /// entry serves every pid — keying it per pid kept a full copy per app forever.
    private var windowListCache: (list: [[String: Any]], timestamp: Date)?
    private let windowListCacheTTL: TimeInterval = 0.5

    /// AX window IDs cache: pid → (ids, timestamp)
    private var axWindowIDsCache: [pid_t: (Set<CGWindowID>, Date)] = [:]
    private let axWindowIDsCacheTTL: TimeInterval = 1.0

    /// Per-app stable window order. Keyed by bundleID so restarts of the target
    /// app (which generate fresh CGWindowIDs) naturally reset the order.
    /// Persisted to UserDefaults; see `loadWindowOrder` / `saveWindowOrder`.
    private var windowOrderByBundle: [String: [CGWindowID]] = [:]
    private let windowOrderDefaultsKey = "windowOrderByBundle"

    // MARK: - Window Enumeration

    /// Enumerate windows for an app. Only returns on-screen (visible) windows by default.
    /// Cross-references CGWindow list with AXUIElement windows to filter out
    /// overlays, helper windows, and other non-standard windows (e.g. Chrome translation bar).
    func windowsForApp(pid: pid_t, includeMinimized: Bool = false) -> [WindowInfo] {
        scheduleCachePurge()

        let list: [[String: Any]]
        let now = Date()
        if let cached = windowListCache,
           now.timeIntervalSince(cached.timestamp) < windowListCacheTTL {
            list = cached.list
        } else {
            guard let fetched = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                dpLog("CGWindowListCopyWindowInfo failed")
                return []
            }
            list = fetched
            windowListCache = (fetched, now)
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

        // Apply stable per-bundle ordering. New windows go to the end; existing
        // windows keep their prior position; closed windows drop out.
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            let currentIDs = Set(byID.keys)
            let stored = windowOrderByBundle[bundleID] ?? []

            var orderedIDs: [CGWindowID] = stored.filter { currentIDs.contains($0) }
            let already = Set(orderedIDs)
            for w in windows where !already.contains(w.id) {
                orderedIDs.append(w.id)
            }

            if orderedIDs != stored {
                windowOrderByBundle[bundleID] = orderedIDs
                saveWindowOrder()
            }

            windows = orderedIDs.compactMap { byID[$0] }
        }

        dpLog("Found \(windows.count) windows for PID \(pid) (includeMinimized=\(includeMinimized))")
        return windows
    }

    /// Get the set of CGWindowIDs that correspond to real standard AX windows.
    /// Filters out popups, dialogs, floating panels, overlays (e.g. Chrome translation bar).
    /// Results are cached for 1 second to avoid redundant AX IPC calls.
    private func axWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        let now = Date()
        if let cached = axWindowIDsCache[pid],
           now.timeIntervalSince(cached.1) < axWindowIDsCacheTTL {
            return cached.0
        }

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
        axWindowIDsCache[pid] = (ids, now)
        return ids
    }

    // MARK: - Thumbnails

    /// Use extended TTL while preview panel is open to reduce redundant captures
    private var thumbnailTTL: TimeInterval {
        isPreviewVisible ? extendedCacheTTL : cacheTTL
    }

    /// Fresh cached thumbnail for a window, if any. Main thread only.
    func cachedThumbnail(for windowID: CGWindowID, maxSize: CGFloat) -> NSImage? {
        guard let cached = thumbnailCache[windowID],
              cached.maxSize == maxSize,
              Date().timeIntervalSince(cached.timestamp) < thumbnailTTL else { return nil }
        return cached.image
    }

    /// Capture and downscale thumbnails off the main thread, cache them, then
    /// deliver the ones that succeeded on the main thread.
    func loadThumbnails(
        for windowIDs: [CGWindowID],
        maxSize: CGFloat,
        completion: @escaping ([CGWindowID: NSImage]) -> Void
    ) {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var thumbnails: [CGWindowID: NSImage] = [:]
            for windowID in windowIDs {
                guard let capture = Self.captureImage(windowID: windowID) else {
                    dpLog("Thumbnail capture failed for window \(windowID)")
                    continue
                }
                thumbnails[windowID] = Self.downscale(capture, maxSize: maxSize, scale: scale)
            }

            let captured = thumbnails
            DispatchQueue.main.async {
                self?.storeThumbnails(captured, maxSize: maxSize)
                completion(captured)
            }
        }
    }

    /// Capture a window at full size for the highlight overlay. Not cached — the
    /// overlay shows one window at a time and drops the image when it hides.
    func captureFullImage(windowID: CGWindowID, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.captureImage(windowID: windowID).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Capture a window's contents at nominal (1x) resolution. Thread-safe.
    private static func captureImage(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    /// Redraw a capture at thumbnail size so the cache holds small bitmaps instead
    /// of pinning every window's full-size capture. Thread-safe.
    static func downscale(_ image: CGImage, maxSize: CGFloat, scale: CGFloat) -> NSImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }

        let aspect = w / h
        let pointSize: NSSize = aspect > 1
            ? NSSize(width: maxSize, height: maxSize / aspect)
            : NSSize(width: maxSize * aspect, height: maxSize)

        // Never upscale: a window smaller than the thumbnail keeps its own pixels.
        let ratio = min(1, pointSize.width * scale / w)
        let pixelWidth = max(1, Int((w * ratio).rounded()))
        let pixelHeight = max(1, Int((h * ratio).rounded()))

        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            // Unsupported color space — keep the capture as-is rather than lose the thumbnail.
            return NSImage(cgImage: image, size: pointSize)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: pointSize)
    }

    private func storeThumbnails(_ thumbnails: [CGWindowID: NSImage], maxSize: CGFloat) {
        let now = Date()
        let ttl = thumbnailTTL
        thumbnailCache = thumbnailCache.filter { now.timeIntervalSince($0.value.timestamp) < ttl }
        for (windowID, image) in thumbnails {
            thumbnailCache[windowID] = CachedThumbnail(image: image, maxSize: maxSize, timestamp: now)
        }

        // A capture that lands after the preview closed would otherwise linger.
        if !isPreviewVisible { scheduleCachePurge() }
    }

    /// Drop every cache once the preview has been hidden for `cacheTTL` with no
    /// further window queries. Each call pushes the deadline back.
    private func scheduleCachePurge() {
        cachePurgeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.isPreviewVisible else { return }
            self.thumbnailCache.removeAll()
            self.windowListCache = nil
            self.axWindowIDsCache.removeAll()
        }
        cachePurgeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + cacheTTL, execute: task)
    }

    // MARK: - AX Window Matching

    /// Find the AXUIElement for a given CGWindowID by matching against AX windows.
    /// Uses private API _AXUIElementGetWindow for 100% reliable matching.
    private func findAXWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        guard let getWindow = _axGetWindow else { return nil }
        for axWin in axWindows {
            var axWID: CGWindowID = 0
            if getWindow(axWin, &axWID) == .success, axWID == windowID {
                return axWin
            }
        }
        return nil
    }

    // MARK: - Window Activation

    func activateWindow(windowID: CGWindowID, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)

        // 1. Match AX window by CGWindowID (100% reliable via private API)
        var targetAXWindow = findAXWindow(for: windowID, pid: pid)

        if targetAXWindow != nil {
            dpLog("Matched by CGWindowID: \(windowID)")
        }

        // Fallback: get AX windows list for title/position matching
        if targetAXWindow == nil {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement], !axWindows.isEmpty else {
                dpLog("Could not get AX windows for PID \(pid) — activating app only")
                app?.activate()
                return
            }

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
                    if let p = posRef, CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID() {
                        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                    }
                    if let s = sizeRef, CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() {
                        AXValueGetValue(s as! AXValue, .cgSize, &size)
                    }
                    if abs(tb.origin.x - pos.x) < 5, abs(tb.origin.y - pos.y) < 5,
                       abs(tb.width - size.width) < 5, abs(tb.height - size.height) < 5 {
                        targetAXWindow = axWindow
                        dpLog("Fallback matched by position+size")
                        break
                    }
                }
            }

            if targetAXWindow == nil {
                dpLog("No match — fallback to first AX window")
                targetAXWindow = axWindows.first
            }
        }

        guard let axWindow = targetAXWindow else { return }

        // 3. Activate (AltTab's full proven sequence):
        //    SkyLight brings the process front (.userGenerated = 0x200),
        //    makeKeyWindow transfers key/keyboard focus to THIS window, AX raise
        //    puts it on top. _SLPSSetFront alone raises the window but leaves it
        //    unfocused in multi-window apps — makeKeyWindow is the missing step.
        var psn = ProcessSerialNumber()
        GetPSNForPID(pid, &psn)

        if let slps = _slpsSetFront {
            _ = slps(&psn, UInt32(windowID), 0x200)
            makeKeyWindow(&psn, windowID)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        } else {
            // No SkyLight — public-API fallback (AX focus + app activation).
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
            app?.activate()
        }

        dpLog("Activated window \(windowID) for PID \(pid)")
    }

    // MARK: - Close Window

    func closeWindow(windowID: CGWindowID, pid: pid_t) {
        guard let axWindow = findAXWindow(for: windowID, pid: pid) else {
            dpLog("closeWindow: no AX match for window \(windowID)")
            return
        }

        // Get the close button and press it
        var closeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success else {
            dpLog("closeWindow: no close button for window \(windowID)")
            return
        }
        // Guard the type before force-casting — a misbehaving app could return
        // a non-AXUIElement for the close-button attribute.
        guard let closeRef, CFGetTypeID(closeRef as CFTypeRef) == AXUIElementGetTypeID() else {
            dpLog("closeWindow: close button has unexpected type for window \(windowID)")
            return
        }
        let closeButton = closeRef as! AXUIElement
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)

        // Invalidate caches so the next windowsForApp(pid:) sees the post-close state
        windowListCache = nil
        axWindowIDsCache.removeValue(forKey: pid)

        dpLog("Closed window \(windowID)")
    }

    // MARK: - Window Snapping

    func snapWindow(windowID: CGWindowID, pid: pid_t, position: SnapPosition) {
        guard let axWindow = findAXWindow(for: windowID, pid: pid) else { return }

        // Get current window position to determine which screen it's on
        var posRef: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        var currentPos = CGPoint.zero
        if let p = posRef, CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(p as! AXValue, .cgPoint, &currentPos)
        }

        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryH = primaryScreen.frame.height
        let screen = NSScreen.screens.first { s in
            let f = s.frame
            let cgFrame = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
            return cgFrame.contains(currentPos)
        } ?? primaryScreen

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

}
