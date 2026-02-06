import AppKit
import ApplicationServices

final class DockAXInspector {

    private var dockElement: AXUIElement?
    private var dockPID: pid_t = 0

    init() { refreshDockReference() }

    func refreshDockReference() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            dpLog("Dock process not found")
            return
        }
        dockPID = dock.processIdentifier
        dockElement = AXUIElementCreateApplication(dockPID)
        dpLog("Dock AX reference created (PID: \(dockPID))")
    }

    /// Hit-test at a screen point (CG top-left coordinates). Returns a `DockApp` if
    /// the click lands on a running application's Dock icon.
    func appAtPoint(_ point: CGPoint) -> DockApp? {
        guard let dockElement else {
            dpLog("No Dock AX reference")
            return nil
        }

        // 1. Hit-test
        var rawElement: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(
            dockElement, Float(point.x), Float(point.y), &rawElement
        )
        guard hitResult == .success, let hitElement = rawElement else {
            return nil
        }

        // 2. Walk up to AXDockItem (the hit may land on a child)
        guard let dockItem = findDockItem(from: hitElement) else { return nil }

        // 3. Must be an application dock item
        let subrole = axString(dockItem, kAXSubroleAttribute) ?? ""
        guard subrole == "AXApplicationDockItem" else {
            dpLog("Not an app dock item (subrole: \(subrole))")
            return nil
        }

        let title = axString(dockItem, kAXTitleAttribute) ?? "Unknown"
        dpLog("Dock hit: \(title)")

        // 4. Resolve bundle ID from URL
        var bundleID: String?
        var appURL: URL?

        if let urlRef = axValue(dockItem, kAXURLAttribute) {
            if CFGetTypeID(urlRef as CFTypeRef) == CFURLGetTypeID() {
                appURL = (urlRef as! CFURL) as URL
                bundleID = Bundle(url: appURL!)?.bundleIdentifier
            }
        }

        // 5. Find running application → PID
        var pid: pid_t?
        var isRunning = false

        if let bid = bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            pid = app.processIdentifier
            isRunning = true
        }

        // Fallback: match by name
        if pid == nil,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == title }) {
            pid = app.processIdentifier
            bundleID = bundleID ?? app.bundleIdentifier
            isRunning = true
        }

        // Fallback: AX attribute
        if !isRunning {
            isRunning = (axValue(dockItem, "AXIsApplicationRunning") as? Bool) ?? false
        }

        dpLog("Resolved: \(title) bundle=\(bundleID ?? "nil") pid=\(pid.map(String.init) ?? "nil") running=\(isRunning)")
        return DockApp(bundleIdentifier: bundleID, name: title, url: appURL, pid: pid, isRunning: isRunning)
    }

    // MARK: - Helpers

    private func findDockItem(from element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<5 {
            if let role = axString(current, kAXRoleAttribute), role == "AXDockItem" {
                return current
            }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  CFGetTypeID(parent!) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axValue(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value
    }
}
