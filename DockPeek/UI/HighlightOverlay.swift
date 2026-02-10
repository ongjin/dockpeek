import AppKit
import CoreGraphics

/// Shows a translucent preview overlay at a window's actual screen position,
/// displaying the real window content so the user can identify it before clicking.
final class HighlightOverlay {

    private var overlayWindow: NSWindow?
    private var currentWindowID: CGWindowID?
    private var isHiding = false
    private var overlayGeneration = 0

    func show(for windowInfo: WindowInfo, cachedImage: NSImage? = nil) {
        // Skip if already showing for this window
        if currentWindowID == windowInfo.id { return }

        overlayGeneration &+= 1

        // If hide animation is in progress, force-finish it
        if isHiding, let window = overlayWindow {
            window.alphaValue = 0
            window.orderOut(nil)
            overlayWindow = nil
            isHiding = false
        }

        currentWindowID = windowInfo.id

        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard screenForCGRect(windowInfo.bounds, primaryH: primaryH) != nil else { return }

        // Convert CG bounds (top-left origin) to Cocoa (bottom-left origin)
        // Must use primary screen height — CG origin is at top-left of primary screen
        let cocoaRect = NSRect(
            x: windowInfo.bounds.origin.x,
            y: primaryH - windowInfo.bounds.origin.y - windowInfo.bounds.height,
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

        // Use cached image if available, skip re-capture entirely
        if let cachedImage {
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: cocoaRect.size))
            imageView.image = cachedImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            container.addSubview(imageView)
        } else {
            // Fallback: tinted background (no CGWindowListCreateImage)
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
        guard let window = overlayWindow, !isHiding else { return }
        isHiding = true
        currentWindowID = nil
        let gen = overlayGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Skip cleanup if show() was called during the animation
            guard let self, self.overlayGeneration == gen else { return }
            window.orderOut(nil)
            self.overlayWindow = nil
            self.isHiding = false
        })
    }

    private func screenForCGRect(_ rect: CGRect, primaryH: CGFloat? = nil) -> NSScreen? {
        let pH = primaryH ?? NSScreen.screens.first?.frame.height ?? 0
        let cocoaRect = NSRect(
            x: rect.origin.x,
            y: pH - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        for screen in NSScreen.screens {
            if screen.frame.intersects(cocoaRect) {
                return screen
            }
        }
        return NSScreen.screens.first
    }
}
