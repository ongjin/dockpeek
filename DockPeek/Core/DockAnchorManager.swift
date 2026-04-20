// DockPeek/Core/DockAnchorManager.swift
import Foundation

/// Anchors the macOS Dock to the primary display by toggling the
/// undocumented `com.apple.dock` key `allow-display-switching`.
///
/// Setting the key to `false` disables the Dock's cursor-edge
/// display-reassignment path (the `_mouseEnterHelper:location:
/// allowSwitchingBetweenDisplays:` hook gated by `allowDockDisplaySwitching`
/// on the Dock's `DockGlobals`). Unlike the `com.apple.spaces
/// spans-displays` alternative, this key has no side effects on
/// menu-bar behavior or full-screen apps.
///
/// The Dock reads this preference once at launch, so every change
/// is followed by a `killall Dock` to force a reload.
final class DockAnchorManager {
    private static let dockDomain = "com.apple.dock" as CFString
    private static let key = "allow-display-switching" as CFString

    func start() {
        if currentValue() == false { return }
        setValue(false)
        restartDock()
        dpLog("DockAnchor: pinned Dock to primary display")
    }

    func stop() {
        if currentValue() == nil { return }
        setValue(nil)
        restartDock()
        dpLog("DockAnchor: restored Dock to default behavior")
    }

    private func currentValue() -> Bool? {
        CFPreferencesCopyAppValue(Self.key, Self.dockDomain) as? Bool
    }

    private func setValue(_ value: Bool?) {
        CFPreferencesSetAppValue(Self.key, value as CFPropertyList?, Self.dockDomain)
        CFPreferencesAppSynchronize(Self.dockDomain)
    }

    private func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
    }
}
