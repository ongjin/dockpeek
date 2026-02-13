import AppKit
import ApplicationServices

enum DiagnosticChecker {

    struct Report {
        let lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    static func run() -> Report {
        var lines: [String] = []

        // Header
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("DockPeek v\(appVersion)")
        lines.append("macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        lines.append("---")

        // Accessibility
        let ax = AXIsProcessTrusted()
        lines.append("Accessibility: \(ax ? "OK" : "NOT GRANTED")")

        // Screen Recording — try listing Finder's windows
        let srResult = checkScreenRecording()
        lines.append("Screen Recording: \(srResult)")

        // Event tap — create a passive tap to test
        let tapOK = testEventTapCreation()
        lines.append("Event Tap: \(tapOK ? "OK" : "FAILED")")

        // Dock settings
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let autoHide = dockDefaults?.bool(forKey: "autohide") ?? false
        let orientation = dockDefaults?.string(forKey: "orientation") ?? "bottom"
        lines.append("Dock: orientation=\(orientation) autohide=\(autoHide)")

        // Dock area detection
        let dockRect = detectDockRect(autoHide: autoHide, orientation: orientation)
        if dockRect != .zero {
            lines.append("Dock Area: \(Int(dockRect.width))x\(Int(dockRect.height)) at (\(Int(dockRect.origin.x)),\(Int(dockRect.origin.y)))")
        } else {
            lines.append("Dock Area: NOT DETECTED")
        }

        // Dock AX hit-test
        let dockAX = testDockAXAccess()
        lines.append("Dock AX: \(dockAX)")

        // Private API
        let axGetWindow = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") != nil
        lines.append("_AXUIElementGetWindow: \(axGetWindow ? "OK" : "NOT FOUND")")

        // Screen info
        for (i, screen) in NSScreen.screens.enumerated() {
            let f = screen.frame
            let v = screen.visibleFrame
            lines.append("Screen \(i): \(Int(f.width))x\(Int(f.height))"
                         + " visible=\(Int(v.width))x\(Int(v.height))"
                         + " gap(B=\(Int(v.minY - f.minY)),L=\(Int(v.minX - f.minX)),R=\(Int(f.maxX - v.maxX)))")
        }

        return Report(lines: lines)
    }

    /// Check if Screen Recording permission is effective by listing Finder's windows.
    static var isScreenRecordingEffective: Bool {
        let result = checkScreenRecording()
        return result.hasPrefix("OK")
    }

    // MARK: - Private

    private static func checkScreenRecording() -> String {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return "FAILED (nil)"
        }

        guard let finderApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            return "UNKNOWN (Finder not running)"
        }
        let finderPID = finderApp.processIdentifier

        var finderWindowCount = 0
        var hasName = false
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == finderPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            finderWindowCount += 1
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                hasName = true
            }
        }

        if finderWindowCount > 0 && hasName {
            return "OK (\(finderWindowCount) Finder windows)"
        } else if finderWindowCount > 0 {
            return "PARTIAL (windows visible but names hidden — \(finderWindowCount) Finder windows)"
        } else {
            return "NOT EFFECTIVE (0 Finder windows visible)"
        }
    }

    private static func testEventTapCreation() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        CFMachPortInvalidate(tap)
        return true
    }

    private static func detectDockRect(autoHide: Bool, orientation: String) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let pH = primary.frame.height
        var rect = CGRect.zero
        for screen in NSScreen.screens {
            let full = screen.frame
            let vis = screen.visibleFrame
            let bottomGap = vis.minY - full.minY
            let leftGap = vis.minX - full.minX
            let rightGap = full.maxX - vis.maxX

            var dockZone = CGRect.zero
            if bottomGap > 30 {
                let cgTop = pH - vis.minY
                dockZone = CGRect(x: full.minX, y: cgTop, width: full.width, height: bottomGap)
            } else if leftGap > 30 {
                let cgTop = pH - full.maxY
                dockZone = CGRect(x: full.minX, y: cgTop, width: leftGap, height: full.height)
            } else if rightGap > 30 {
                let cgTop = pH - full.maxY
                dockZone = CGRect(x: vis.maxX, y: cgTop, width: rightGap, height: full.height)
            }

            if dockZone == .zero, autoHide {
                let dockSize: CGFloat = 100
                switch orientation {
                case "left":
                    let cgTop = pH - full.maxY
                    dockZone = CGRect(x: full.minX, y: cgTop, width: dockSize, height: full.height)
                case "right":
                    let cgTop = pH - full.maxY
                    dockZone = CGRect(x: full.maxX - dockSize, y: cgTop, width: dockSize, height: full.height)
                default:
                    dockZone = CGRect(x: full.minX, y: pH - full.minY - dockSize, width: full.width, height: dockSize)
                }
            }

            if dockZone != .zero {
                rect = rect == .zero ? dockZone : rect.union(dockZone)
            }
        }
        return rect
    }

    private static func testDockAXAccess() -> String {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            return "FAILED (Dock not found)"
        }
        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(dockAX, kAXChildrenAttribute as CFString, &childrenRef)
        if result == .success, let children = childrenRef as? [AXUIElement] {
            return "OK (\(children.count) children)"
        } else {
            return "FAILED (error: \(result.rawValue))"
        }
    }
}
