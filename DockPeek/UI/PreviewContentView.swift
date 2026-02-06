import SwiftUI

struct PreviewContentView: View {
    let windows: [WindowInfo]
    let thumbnailSize: CGFloat
    let showTitles: Bool
    let onSelect: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onDismiss: () -> Void
    let onHoverWindow: (WindowInfo?) -> Void

    @State private var hoveredID: CGWindowID?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(windows) { window in
                windowCard(window)
            }
        }
        .padding(16)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    // MARK: - Card

    @ViewBuilder
    private func windowCard(_ w: WindowInfo) -> some View {
        let hovered = hoveredID == w.id

        VStack(spacing: 6) {
            thumbnailView(w)
                .frame(width: thumbnailSize, height: thumbnailSize * 0.625)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            hovered ? Color.accentColor : Color.white.opacity(0.08),
                            lineWidth: hovered ? 2 : 0.5
                        )
                )
                .overlay(alignment: .topLeading) {
                    if hovered {
                        Button {
                            onClose(w)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.black.opacity(0.6))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .transition(.opacity)
                    }
                }

            if showTitles {
                Text(w.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: thumbnailSize)
                    .foregroundColor(.primary)
            }

            if w.isMinimized {
                Text("Minimized")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .scaleEffect(hovered ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { over in
            hoveredID = over ? w.id : nil
            onHoverWindow(over ? w : nil)
        }
        .onTapGesture { onSelect(w) }
        .accessibilityLabel(w.displayTitle)
    }

    @ViewBuilder
    private func thumbnailView(_ w: WindowInfo) -> some View {
        if let img = w.thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "macwindow")
                        .font(.title2)
                        .foregroundColor(.secondary)
                )
        }
    }
}

// MARK: - NSVisualEffectView bridge

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
