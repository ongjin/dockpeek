import AppKit
import CoreGraphics

/// Shows a translucent preview overlay at a window's actual screen position,
/// displaying the real window content so the user can identify it before clicking.
final class HighlightOverlay {

    private var overlayWindow: NSWindow?
    private var currentWindowID: CGWindowID?

    func show(for windowInfo: WindowInfo, cachedImage: NSImage? = nil) {
        // Skip if already showing for this window
        if currentWindowID == windowInfo.id { return }
        hide()
        currentWindowID = windowInfo.id

        guard let screen = screenForCGRect(windowInfo.bounds) else { return }
        let screenH = screen.frame.height

        // Convert CG bounds (top-left origin) to Cocoa (bottom-left origin)
        let cocoaRect = NSRect(
            x: windowInfo.bounds.origin.x,
            y: screenH - windowInfo.bounds.origin.y - windowInfo.bounds.height,
            width: windowInfo.bounds.width,
            height: windowInfo.bounds.height
        )

        // Reuse existing window or create one
        let window: NSWindow
        if let existing = overlayWindow {
            existing.setFrame(cocoaRect, display: false)
            window = existing
        } else {
            window = NSWindow(
                contentRect: cocoaRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .popUpMenu - 1
            window.ignoresMouseEvents = true
            window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        let container = NSView(frame: NSRect(origin: .zero, size: cocoaRect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        container.layer?.borderWidth = 3

        // Use cached image if available, otherwise capture
        let displayImage: NSImage?
        if let cachedImage {
            displayImage = cachedImage
        } else if let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowInfo.id,
            [.boundsIgnoreFraming, .nominalResolution]
        ) {
            displayImage = NSImage(cgImage: cgImage, size: cocoaRect.size)
        } else {
            displayImage = nil
        }

        if let displayImage {
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: cocoaRect.size))
            imageView.image = displayImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            container.addSubview(imageView)
        } else {
            // Fallback: tinted background
            container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }

        window.contentView = container

        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0.85
        }

        overlayWindow = window
    }

    func hide() {
        guard let window = overlayWindow else { return }
        currentWindowID = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
        overlayWindow = nil
    }

    private func screenForCGRect(_ rect: CGRect) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.intersects(NSRect(
                x: rect.origin.x,
                y: screen.frame.height - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )) {
                return screen
            }
        }
        return NSScreen.main
    }
}
