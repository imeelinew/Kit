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
        .compositingGroup()
        .opacity(0.65)
        .ignoresSafeArea()
    }
}

@MainActor
struct PinnedImageContent: View {
    let image: NSImage
    let onClose: () -> Void


    var body: some View {
        ZStack(alignment: .top) {
            PinnedCardBackground()

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

    private var resize: (edge: PinnedImageResizeEdge, frame: CGRect, mouse: CGPoint)?

    override func resetCursorRects() {
        super.resetCursorRects()
        let inset = PinnedImageResizeEdge.hitWidth
        let xs = [bounds.minX, bounds.minX + inset, bounds.maxX - inset, bounds.maxX]
        let ys = [bounds.minY, bounds.minY + inset, bounds.maxY - inset, bounds.maxY]
        let positions: [[NSCursor.FrameResizePosition?]] = [
            [.bottomLeft, .left, .topLeft],
            [.bottom, nil, .top],
            [.bottomRight, .right, .topRight]]
        for x in 0..<3 {
            for y in 0..<3 {
                guard let position = positions[x][y] else { continue }
                let rect = CGRect(x: xs[x], y: ys[y], width: xs[x + 1] - xs[x], height: ys[y + 1] - ys[y])
                // Leave the close button's entire padded area to SwiftUI
                let close = CGRect(x: bounds.minX + 10, y: bounds.maxY - 38, width: 28, height: 28)
                let overlap = rect.intersection(close)
                let pieces = overlap.isNull ? [rect] : [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
                for piece in pieces where !piece.isEmpty {
                    addCursorRect(piece, cursor: .frameResize(position: position, directions: .all))
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? PinnedImagePanel else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let edge = PinnedImageResizeEdge.hit(at: point, in: bounds) else {
            panel.performDrag(with: event)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        resize = (edge, panel.frame, panel.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resize, let panel = window as? PinnedImagePanel else { return }
        let mouse = panel.convertPoint(toScreen: event.locationInWindow)
        let visible = panel.screen?.visibleFrame ?? panel.frame
        let frame = resize.edge.frame(from: resize.frame,
            delta: CGSize(width: mouse.x - resize.mouse.x, height: mouse.y - resize.mouse.y),
            minimum: panel.geometry?.minimumFrameSize ?? panel.minSize,
            visible: visible.insetBy(dx: 12, dy: 12))
        panel.setFrame(frame, display: true)
        panel.geometry?.adopt(frame)
    }

    override func mouseUp(with event: NSEvent) {
        guard resize != nil else { return }
        resize = nil
        (window as? PinnedImagePanel)?.fitToScreen()
        window?.invalidateCursorRects(for: self)
    }
}
