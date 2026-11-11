// Throwaway target app for scripts/e2e.swift. It opens N plain windows and sits in the Dock, so
// the end-to-end run can hover and click cards without touching your real apps.
// Usage: DockPeekE2E <window count>

import AppKit

/// Quits on its own if the driver dies before terminating it.
let lifetime: TimeInterval = 180

let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 3
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let size = NSSize(width: 380, height: 250)
let cascade: CGFloat = 28

var windows: [NSWindow] = []
for index in 0..<count {
    let offset = CGFloat(index) * cascade
    let origin = NSPoint(x: visible.minX + 80 + offset, y: visible.maxY - size.height - 80 - offset)
    let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    window.title = "E2E Window \(index + 1)"
    window.isReleasedWhenClosed = false

    // A big number on a distinct color, so each thumbnail is recognizable in a screenshot.
    let label = NSTextField(labelWithString: "\(index + 1)")
    label.font = .systemFont(ofSize: 120, weight: .bold)
    label.alignment = .center
    label.frame = NSRect(origin: .zero, size: size)
    label.autoresizingMask = [.width, .height]
    label.drawsBackground = true
    label.backgroundColor = NSColor(hue: CGFloat(index) / CGFloat(max(count, 1)), saturation: 0.45, brightness: 0.9, alpha: 1)
    window.contentView = label

    window.orderFront(nil)   // show without activating the app
    windows.append(window)
}

DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { app.terminate(nil) }
app.run()
