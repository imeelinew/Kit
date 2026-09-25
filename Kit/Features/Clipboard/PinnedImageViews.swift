import AppKit
import SwiftUI

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
    let onZoomOut: () -> Void
    let onResetSize: () -> Void
    let onZoomIn: () -> Void

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
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                PinnedCardButton(systemName: "minus", label: "Zoom Out", action: onZoomOut)
                PinnedCardButton(
                    systemName: "arrow.counterclockwise", label: "Reset Size", action: onResetSize
                )
                PinnedCardButton(systemName: "plus", label: "Zoom In", action: onZoomIn)
            }
            .padding(10)
        }
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
