import SwiftUI

struct PreviewContentView: View {
    let windows: [WindowInfo]
    let thumbnailSize: CGFloat
    let showTitles: Bool
    let onSelect: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onSnap: (WindowInfo, SnapPosition) -> Void
    let onDismiss: () -> Void
    let onHoverWindow: (WindowInfo?) -> Void
    @ObservedObject var navState: PreviewNavState

    @State private var hoveredID: CGWindowID?
    @State private var closeHoveredID: CGWindowID?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                windowCard(window, index: index)
            }
        }
        .onChange(of: navState.selectedIndex) { _, newIndex in
            if newIndex >= 0, newIndex < windows.count {
                onHoverWindow(windows[newIndex])
            } else {
                onHoverWindow(nil)
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
    private func windowCard(_ w: WindowInfo, index: Int) -> some View {
        let hovered = hoveredID == w.id
        let keySelected = navState.selectedIndex == index
        let highlighted = hovered || keySelected

        VStack(spacing: 6) {
            thumbnailView(w)
                .frame(width: thumbnailSize, height: thumbnailSize * 0.625)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            keySelected ? Color.accentColor : (hovered ? Color.accentColor : Color.white.opacity(0.08)),
                            lineWidth: highlighted ? 2 : 0.5
                        )
                )
                .overlay(alignment: .topLeading) {
                    if highlighted {
                        let closeHovered = closeHoveredID == w.id
                        Button {
                            onClose(w)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(closeHovered ? Color.red : Color.black.opacity(0.6))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .scaleEffect(closeHovered ? 1.2 : 1.0)
                            .animation(.easeOut(duration: 0.12), value: closeHovered)
                        }
                        .buttonStyle(.plain)
                        .onHover { over in
                            closeHoveredID = over ? w.id : nil
                        }
                        .padding(6)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if highlighted {
                        HStack(spacing: 6) {
                            snapButton(icon: "rectangle.lefthalf.filled", position: .left, window: w)
                            snapButton(icon: "rectangle.inset.filled", position: .fill, window: w)
                            snapButton(icon: "rectangle.righthalf.filled", position: .right, window: w)
                        }
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 6)
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
                .fill(highlighted ? Color.white.opacity(0.1) : Color.clear)
        )
        .onHover { over in
            hoveredID = over ? w.id : nil
            if over { navState.selectedIndex = -1 }
            onHoverWindow(over ? w : nil)
        }
        .onTapGesture { onSelect(w) }
        .accessibilityLabel(w.displayTitle)
    }

    @ViewBuilder
    private func snapButton(icon: String, position: SnapPosition, window: WindowInfo) -> some View {
        Button {
            onSnap(window, position)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.plain)
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
