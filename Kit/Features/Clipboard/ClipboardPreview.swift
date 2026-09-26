import AppKit
import SwiftUI

/// A complete preview is published together, so image decoding and metadata cannot resize
/// the pane in separate frames. Keep a small, evictable working set across palette dismissals.
@MainActor
final class ClipboardPreviewPayload {
    let itemID: ClipboardItem.ID
    let image: NSImage?
    let details: Details

    struct Details: Sendable {
        var characters: Int?
        var words: Int?
        var pixelSize: CGSize?
        var fileBytes: Int?
    }

    private static let cache: NSCache<NSUUID, ClipboardPreviewPayload> = {
        let cache = NSCache<NSUUID, ClipboardPreviewPayload>()
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private init(itemID: ClipboardItem.ID, image: NSImage?, details: Details) {
        self.itemID = itemID
        self.image = image
        self.details = details
    }

    static func cached(for item: ClipboardItem) -> ClipboardPreviewPayload? {
        cache.object(forKey: item.id as NSUUID)
    }

    static func load(for item: ClipboardItem, imageURL: URL?) async -> ClipboardPreviewPayload {
        if let hit = cached(for: item) { return hit }
        let detailsTask = Task.detached(priority: .userInitiated) {
            var details = Details()
            if let text = item.text {
                details.characters = text.count
                var count = 0
                var inWord = false
                for scalar in text.unicodeScalars {
                    let separator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                    if !separator && !inWord { count += 1 }
                    inWord = !separator
                }
                details.words = count
            }
            if let imageURL {
                details.pixelSize = ImageThumbnail.pixelSize(of: imageURL)
                details.fileBytes = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }
            return details
        }
        let image: NSImage?
        if let imageURL {
            image = await ImageThumbnail.loadAsync(imageURL, maxPixel: 900)
        } else {
            image = nil
        }
        let payload = ClipboardPreviewPayload(
            itemID: item.id, image: image, details: await detailsTask.value)
        if !Task.isCancelled {
            let cost = image.map { Int($0.size.width * $0.size.height) * 4 } ?? 1
            cache.setObject(payload, forKey: item.id as NSUUID, cost: cost)
        }
        return payload
    }
}

struct ClipboardPreview: View {
    let item: ClipboardItem?
    var query: String = ""
    @Bindable var vm: PaletteViewModel
    let store: ClipboardStore
    @ObservedObject private var settings = AppCore.shared.settings

    @State private var loadedPayload: ClipboardPreviewPayload?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let item {
                let payload = (vm.preparedPreview?.itemID == item.id ? vm.preparedPreview : nil)
                    ?? ClipboardPreviewPayload.cached(for: item)
                    ?? (loadedPayload?.itemID == item.id ? loadedPayload : nil)
                VStack(alignment: .leading, spacing: 0) {
                    content(for: item, payload: payload)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    ClipboardInfoSection(
                        item: item, details: payload?.details ?? .init(), store: store)
                }
                .padding(.horizontal, 12)
                .id(item.id)
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : Theme.Motion.menu, value: item?.id)
        .task(id: item?.id) {
            guard let item else {
                loadedPayload = nil
                return
            }
            let payload = await ClipboardPreviewPayload.load(
                for: item, imageURL: store.imageURL(for: item))
            guard !Task.isCancelled else { return }
            loadedPayload = payload
        }
    }

    @ViewBuilder
    private func content(for item: ClipboardItem, payload: ClipboardPreviewPayload?) -> some View {
        switch item.kind {
        case .text, .path, .link:
            ClipboardTextPreview(text: item.text ?? "", query: query).equatable()
        case .markdown:
            if settings.renderMarkdown {
                MarkdownPreview(source: item.text ?? "", query: query)
            } else {
                ClipboardTextPreview(text: item.text ?? "", query: query).equatable()
            }
        case .code:
            CodePreview(code: item.text ?? "", query: query)
        case .image:
            let imageURL = store.imageURL(for: item)
            Group {
                if let image = payload?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
                        )
                } else {
                    Image(systemName: "photo").font(.system(.largeTitle))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
                }
            }
            // Anchor to the thumbnail's fitted bounds, not the full preview pane, so the
            // NSPopover arrow points at the image and placement can avoid covering it.
            .overlay {
                ImageQuickLookAnchor(
                    url: imageURL,
                    isPresented: Binding(
                        get: { vm.imageQuickLookOpen },
                        set: { vm.imageQuickLookOpen = $0 }
                    )
                )
                .allowsHitTesting(false)
            }
        }
    }
}

/// Selection, footer and metadata changes must not reformat unchanged preview text.
private struct ClipboardTextPreview: View, Equatable {
    let text: String
    let query: String

    var body: some View {
        AttributedTextPreview(attributed: SearchHighlight.attributed(text, query: query))
    }
}

/// Information rows keep their geometry while the complete preview payload loads off-main.
private struct ClipboardInfoSection: View {
    let item: ClipboardItem
    let details: ClipboardPreviewPayload.Details

    @ObservedObject var store: ClipboardStore
    @ObservedObject private var settings = AppCore.shared.settings

    private struct InfoRow: Identifiable {
        let label: String
        let value: String
        var localizesValue = false
        var icon: NSImage?
        var id: String { label }
    }

    /// Relative day name plus exact time ("Today at 1:22:57 AM"); shared because `DateFormatter` is expensive to build.
    @MainActor private static let copiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Information")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let rows = self.rows
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Divider() }
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(LocalizedStringKey(row.label)).foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Spacing.lg)
                        if let icon = row.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Group {
                            if row.localizesValue {
                                Text(LocalizedStringKey(row.value))
                            } else {
                                Text(row.value)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    .font(.callout)
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
        .padding(.top, Theme.Spacing.xl)
    }

    private var rows: [InfoRow] {
        var rows: [InfoRow] = []
        if let source {
            rows.append(InfoRow(label: "Source", value: source.name, icon: source.icon))
        }
        rows.append(
            InfoRow(
                label: "Type",
                value: item.kind.typeLabel,
                localizesValue: true))
        if let stackID = store.stackID(for: item.id),
            let stack = store.stacks.first(where: { $0.id == stackID })
        {
            rows.append(InfoRow(label: "Stack", value: stack.name))
        }
        // Reserve both rows from the first frame, including missing/unreadable files.
        // Finishing a decode changes values, never the available image height.
        switch item.kind {
        case .text, .markdown, .code, .link, .path:
            rows.append(InfoRow(label: "Characters", value: details.characters.map {
                $0.formatted(.number.locale(settings.language.locale))
            } ?? "—"))
            rows.append(InfoRow(label: "Words", value: details.words.map {
                $0.formatted(.number.locale(settings.language.locale))
            } ?? "—"))
        case .image:
            rows.append(InfoRow(label: "Dimensions", value: details.pixelSize.map {
                "\(Int($0.width))×\(Int($0.height))"
            } ?? "—"))
            rows.append(InfoRow(label: "Size", value: details.fileBytes.map {
                Int64($0).formatted(.byteCount(style: .file).locale(settings.language.locale))
            } ?? "—"))
        }
        Self.copiedFormatter.locale = settings.language.locale
        rows.append(
            InfoRow(label: "Copied", value: Self.copiedFormatter.string(from: item.createdAt)))
        return rows
    }

    /// Source app name + icon from the recorded bundle ID; the Launch Services lookup is a quick main-thread call and the icon comes from the shared `IconCache`.
    private var source: (name: String, icon: NSImage)? {
        guard let bundleID = item.sourceBundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return (url.deletingPathExtension().lastPathComponent, IconCache.icon(forFile: url.path))
    }

}
