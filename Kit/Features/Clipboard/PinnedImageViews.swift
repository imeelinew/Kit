import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PinnedImagePanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if isEditingTitle {
                super.sendEvent(event)
                return
            }
            if isCloseShortcut(event) {
                if !event.isARepeat {
                    onClose?()
                }
                return
            }
        }
        if event.type == .magnify {
            resize(
                by: max(1 + event.magnification, 0.1),
                anchorInWindow: event.locationInWindow
            )
            return
        }
        super.sendEvent(event)
    }

    private var isEditingTitle: Bool {
        (firstResponder as? NSTextView)?.isEditable == true
    }

    func resize(by requestedScale: CGFloat, anchorInWindow requestedAnchor: NSPoint? = nil) {
        guard requestedScale.isFinite, requestedScale > 0, requestedScale != 1 else { return }

        let current = frame
        guard current.width > 0, current.height > 0 else { return }

        let visibleFrame = resizeVisibleFrame()
        let maximumScale = min(
            visibleFrame.width / current.width,
            visibleFrame.height / current.height
        )
        guard maximumScale.isFinite, maximumScale > 0 else { return }
        let minimumScale = min(max(
            contentMinSize.width / current.width,
            contentMinSize.height / current.height
        ), maximumScale)
        let scale = min(max(requestedScale, minimumScale), maximumScale)
        let size = CGSize(width: current.width * scale, height: current.height * scale)

        let rawAnchor = requestedAnchor ?? NSPoint(x: current.width / 2, y: current.height / 2)
        let anchor = NSPoint(
            x: min(max(rawAnchor.x, 0), current.width),
            y: min(max(rawAnchor.y, 0), current.height)
        )
        let unitAnchor = NSPoint(x: anchor.x / current.width, y: anchor.y / current.height)
        let screenAnchor = NSPoint(x: current.minX + anchor.x, y: current.minY + anchor.y)
        let proposedOrigin = NSPoint(
            x: screenAnchor.x - size.width * unitAnchor.x,
            y: screenAnchor.y - size.height * unitAnchor.y
        )
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        let resizedFrame = NSRect(origin: origin, size: size)
        guard !resizedFrame.nearlyEquals(current) else { return }

        setFrame(resizedFrame, display: true)
        // Magnify events arrive much faster than SwiftUI's normal display pass. Keep the hosting
        // tree and its clipping layer synchronized with every window frame so stale bounds cannot
        // crop the image or card controls mid-gesture.
        contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeVisibleFrame() -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let inset = min(12, max(min(visible.width, visible.height) / 4, 0))
        return visible.insetBy(dx: inset, dy: inset)
    }

    private func isCloseShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_ANSI_W)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }
}

private extension NSRect {
    func nearlyEquals(_ other: NSRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

@MainActor
private struct PinnedCardBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

@MainActor
struct PinnedImageContent: View {
    let itemID: ClipboardItem.ID
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

            PinnedCardChrome(
                itemID: itemID,
                trailingWidth: 28,
                closeLabel: "Close Pinned Image",
                onClose: onClose
            ) {
                Color.clear
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .ignoresSafeArea()
        .task(id: url) {
            image = await ImageThumbnail.loadAsync(url, maxPixel: decodeMaxPixel)
            loadFailed = image == nil
        }
    }
}

private struct PinnedCardChrome<Trailing: View>: View {
    let itemID: ClipboardItem.ID
    let trailingWidth: CGFloat
    let closeLabel: LocalizedStringKey
    let onClose: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { geometry in
            let titleWidth = max(geometry.size.width - 2 * (trailingWidth + 8), 0)

            ZStack {
                PinnedCardTitle(itemID: itemID)
                    .frame(width: titleWidth)
                    .clipped()

                PinnedCardButton(
                    systemName: "xmark",
                    label: closeLabel,
                    action: onClose
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 28)
        .padding(10)
        .frame(maxWidth: .infinity)
    }
}

private struct PinnedCardTitle: View {
    let itemID: ClipboardItem.ID

    @ObservedObject private var store = AppCore.shared.clipboardStore
    @ObservedObject private var settings = AppCore.shared.settings

    private var title: String {
        store.item(id: itemID)?.displayTitle(locale: settings.language.locale) ?? ""
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: 280)
    }
}

private struct PinnedCardButton: View {
    let systemName: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frosted(in: Circle())
        .accessibilityLabel(Text(label))
        .help(Text(label))
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
