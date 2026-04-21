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
    var documentURL: URL?

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }

    /// Filename to show beneath the thumbnail. Prefers the document URL so that
    /// apps which append " — foldername" to the window title still get a clean
    /// filename in the preview.
    var displayFileName: String? {
        documentURL?.lastPathComponent
    }

    /// Abbreviated parent directory (e.g. `~/workspace/.../DockPeek`). Returned
    /// only when the window is backed by a document URL.
    var displayParentPath: String? {
        guard let url = documentURL else { return nil }
        let parent = url.deletingLastPathComponent().path
        guard !parent.isEmpty, parent != "/" else { return nil }
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}
