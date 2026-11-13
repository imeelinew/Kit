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

    private var cursorTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (window as? PinnedImagePanel)?.updateResizeCursor(at: event.locationInWindow)
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
