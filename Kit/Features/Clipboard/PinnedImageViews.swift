import AppKit
import SwiftUI

@MainActor
private struct PinnedCardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            var squares = Path()
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in stride(from: row % 2, to: Int(ceil(size.width / tile)), by: 2) {
                    squares.addRect(CGRect(
                        x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                        width: tile, height: tile))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.82)))
        }
        .background(Color(white: 0.94))
        .ignoresSafeArea()
    }
}

@MainActor
struct PinnedImageContent: View {
    let url: URL
    let decodeMaxPixel: CGFloat
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack(alignment: .top) {
            PinnedCardBackground()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            PinnedImageDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frosted(in: Circle())
            .accessibilityLabel("Close Pinned Image")
            .help("Close Pinned Image")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .ignoresSafeArea()
        .task(id: url) {
            let loaded = await ImageThumbnail.loadAsync(url, maxPixel: decodeMaxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            loadFailed = image == nil
        }
    }
}

private struct PinnedImageDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedImageDragView {
        PinnedImageDragView()
    }

    func updateNSView(_ nsView: PinnedImageDragView, context: Context) {}
}

private final class PinnedImageDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
