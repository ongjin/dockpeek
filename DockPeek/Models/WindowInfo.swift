import AppKit

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let isOnScreen: Bool
    let isMinimized: Bool
    var thumbnail: NSImage?

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }
}
