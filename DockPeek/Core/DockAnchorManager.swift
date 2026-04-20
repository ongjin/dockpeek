// DockPeek/Core/DockAnchorManager.swift
import Foundation

/// Pins the macOS Dock to the primary display at a chosen orientation by
/// toggling two `com.apple.dock` preferences and restarting the Dock.
///
/// - `allow-display-switching` (undocumented): gates the Dock's internal
///   `_mouseEnterHelper:location:allowSwitchingBetweenDisplays:` hook via
///   the readonly `allowDockDisplaySwitching` ivar on `DockGlobals`. Set
///   to `false` to disable the cursor-edge display-reassignment path.
/// - `orientation` (documented): `"bottom"` | `"left"` | `"right"` — the
///   edge the Dock anchors to on its display.
///
/// Both values are read once at Dock launch, so every change is followed
/// by a `killall Dock` to force a reload. `stop()` only removes the
/// `allow-display-switching` key so the user's last chosen orientation
/// is preserved when the anchor is turned off.
final class DockAnchorManager {
    private static let dockDomain = "com.apple.dock" as CFString
    private static let switchKey = "allow-display-switching" as CFString
    private static let orientationKey = "orientation" as CFString

    func start(orientation: String) {
        var restart = false

        if read(Self.orientationKey) as? String != orientation {
            write(Self.orientationKey, orientation as CFString)
            restart = true
        }

        if read(Self.switchKey) as? Bool != false {
            write(Self.switchKey, false as CFBoolean)
            restart = true
        }

        guard restart else { return }
        CFPreferencesAppSynchronize(Self.dockDomain)
        restartDock()
        dpLog("DockAnchor: pinned Dock (orientation=\(orientation))")
    }

    func stop() {
        guard read(Self.switchKey) != nil else { return }
        write(Self.switchKey, nil)
        CFPreferencesAppSynchronize(Self.dockDomain)
        restartDock()
        dpLog("DockAnchor: restored default Dock behavior")
    }

    private func read(_ key: CFString) -> Any? {
        CFPreferencesCopyAppValue(key, Self.dockDomain)
    }

    private func write(_ key: CFString, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key, value, Self.dockDomain)
    }

    private func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
    }
}
