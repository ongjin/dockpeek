import AppKit
import SwiftUI

final class PreviewPanel: NSPanel {

    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show

    func showPreview(
        windows: [WindowInfo],
        thumbnailSize: CGFloat,
        showTitles: Bool,
        near point: CGPoint,
        onSelect: @escaping (WindowInfo) -> Void,
        onClose: @escaping (WindowInfo) -> Void = { _ in },
        onDismiss: @escaping () -> Void,
        onHoverWindow: @escaping (WindowInfo?) -> Void = { _ in }
    ) {
        let content = PreviewContentView(
            windows: windows,
            thumbnailSize: thumbnailSize,
            showTitles: showTitles,
            onSelect: onSelect,
            onClose: onClose,
            onDismiss: onDismiss,
            onHoverWindow: onHoverWindow
        )
        let hosting = NSHostingView(rootView: AnyView(content))
        contentView = hosting

        let fitting = hosting.fittingSize
        let panelSize = NSSize(
            width: min(fitting.width, 800),
            height: min(fitting.height, 500)
        )

        let frame = calculateFrame(size: panelSize, nearPoint: point)
        setFrame(frame, display: true)

        alphaValue = 0
        orderFrontRegardless()
        makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        setupDismissMonitors(onDismiss: onDismiss)
    }

    // MARK: - Dismiss

    func dismissPanel(animated: Bool = true) {
        removeDismissMonitors()
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.orderOut(nil)
                self.alphaValue = 1
            })
        } else {
            orderOut(nil)
        }
    }

    // MARK: - Positioning

    private func calculateFrame(size: NSSize, nearPoint: CGPoint) -> NSRect {
        guard let screen = screenForCGPoint(nearPoint) else {
            return NSRect(origin: .zero, size: size)
        }

        let screenFrame = screen.visibleFrame
        let screenH = screen.frame.height

        // Convert CG (top-left origin) → Cocoa (bottom-left origin)
        let nsY = screenH - nearPoint.y

        let dockPos = detectDockPosition(screen: screen)
        var origin: NSPoint

        switch dockPos {
        case .bottom:
            origin = NSPoint(x: nearPoint.x - size.width / 2, y: screenFrame.minY + 8)
        case .left:
            origin = NSPoint(x: screenFrame.minX + 8, y: nsY - size.height / 2)
        case .right:
            origin = NSPoint(x: screenFrame.maxX - size.width - 8, y: nsY - size.height / 2)
        }

        // Clamp to visible area
        origin.x = max(screenFrame.minX + 4, min(origin.x, screenFrame.maxX - size.width - 4))
        origin.y = max(screenFrame.minY + 4, min(origin.y, screenFrame.maxY - size.height - 4))

        return NSRect(origin: origin, size: size)
    }

    private enum DockPosition { case bottom, left, right }

    private func detectDockPosition(screen: NSScreen) -> DockPosition {
        let full = screen.frame
        let vis = screen.visibleFrame
        if vis.minX - full.minX > 50 { return .left }
        if full.maxX - vis.maxX > 50 { return .right }
        return .bottom
    }

    private func screenForCGPoint(_ pt: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            let h = screen.frame.height
            if screen.frame.contains(NSPoint(x: pt.x, y: h - pt.y)) { return screen }
        }
        return NSScreen.main
    }

    // MARK: - Dismiss Monitors

    private func setupDismissMonitors(onDismiss: @escaping () -> Void) {
        removeDismissMonitors()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.isVisible else { return }
            onDismiss()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
            [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 { onDismiss(); return nil }
            if event.type == .leftMouseDown, event.window != self { onDismiss() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    deinit { removeDismissMonitors() }
}
