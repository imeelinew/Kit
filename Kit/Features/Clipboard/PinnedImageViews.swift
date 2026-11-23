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

            PinnedDragSurface()
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

@MainActor
struct PinnedTextContent: View {
    static let minimumSize = CGSize(width: 200, height: 72)
    private static let headerHeight: CGFloat = 28

    let text: String
    let kind: ClipboardItem.Kind
    let settings: AppSettings

    var body: some View {
        let edge = PinnedResizeEdge.hitWidth
        VStack(spacing: 0) {
            PinnedDragSurface().frame(height: Self.headerHeight)

            HStack(spacing: 0) {
                PinnedDragSurface().frame(width: edge)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                PinnedDragSurface().frame(width: edge)
            }
            PinnedDragSurface().frame(height: edge)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    @ViewBuilder private var preview: some View {
        switch kind {
        case .markdown where settings.renderMarkdown:
            MarkdownPreview(source: text).equatable()
        case .code:
            CodePreview(code: text, wrapsLines: false)
        default:
            ClipboardTextPreview(text: text, query: "").equatable()
        }
    }

    static func initialFrame(text: String, kind: ClipboardItem.Kind, visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - 24)
        let availableHeight = max(1, visibleFrame.height - 24)
        let pointSize = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = ClipboardPreviewFont.regular(ofSize: pointSize)
        let edge = PinnedResizeEdge.hitWidth
        let insets = 2 * edge + PreviewTextView.trailingGutter
        let lines = text.prefix(4_096).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(32)
        let widths = lines.map { (String($0.prefix(240)) as NSString).size(withAttributes: [.font: font]).width }
        let idealWidth = max((widths.max() ?? 0) + insets, minimumSize.width)
        let width = min(ceil(idealWidth), kind == .code ? 640 : 540, availableWidth)
        let contentWidth = max(1, width - insets)
        let rows = kind == .code ? CGFloat(lines.count) : widths.reduce(0) { $0 + max(1, ceil($1 / contentWidth)) }
        let rowHeight = font.ascender - font.descender + font.leading
        let idealHeight = max(Self.headerHeight + edge + rows * rowHeight + 4, minimumSize.height)
        let height = min(ceil(idealHeight), 360, availableHeight)
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                      width: width, height: height)
    }
}

private struct PinnedDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedDragView {
        PinnedDragView()
    }

    func updateNSView(_ nsView: PinnedDragView, context: Context) {}
}

private final class PinnedDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var resize: (edge: PinnedResizeEdge, frame: CGRect, mouse: CGPoint)?

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
        (window as? PinnedWindowPanel)?.updateResizeCursor(at: event.locationInWindow, overDragSurface: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? PinnedWindowPanel else { return }
        guard let edge = panel.resizeEdge(at: event.locationInWindow) else {
            panel.performDrag(with: event)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        resize = (edge, panel.frame, panel.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resize, let panel = window as? PinnedWindowPanel else { return }
        let mouse = panel.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: mouse.x - resize.mouse.x, height: mouse.y - resize.mouse.y)
        let bounds = panel.resizeBounds
        let frame: CGRect
        if let geometry = panel.geometry {
            frame = resize.edge.frame(from: resize.frame, delta: delta,
                                      minimum: geometry.minimumFrameSize, visible: bounds)
        } else {
            frame = resize.edge.freeFrame(from: resize.frame, delta: delta,
                                          minimum: panel.minSize, visible: bounds)
        }
        panel.setFrame(frame, display: true)
        panel.geometry?.adopt(frame)
    }

    override func mouseUp(with event: NSEvent) {
        guard resize != nil else { return }
        resize = nil
        (window as? PinnedWindowPanel)?.fitToScreen()
        window?.invalidateCursorRects(for: self)
    }
}
