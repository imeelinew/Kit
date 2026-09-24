import AppKit
import SwiftUI

/// Renders a downsampled clipboard thumbnail, decoding misses off the main thread (cache hits resolve on the first tick, misses show `placeholder`); `content` styles the loaded image per site.
private struct AsyncThumbnail<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixel: CGFloat
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                content(Image(nsImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageThumbnail.cached(url, maxPixel: maxPixel) {
                image = hit
                return
            }
            image = nil  // show the placeholder while a new image decodes
            let loaded = await ImageThumbnail.loadAsync(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct ClipboardPreview: View {
    /// The preview pane is ~460pt wide (panel 750 − list 290); 900px keeps it crisp at 2× Retina without over-decoding.
    private static let previewMaxPixel: CGFloat = 900

    let item: ClipboardItem?
    var query: String = ""
    @Bindable var vm: PaletteViewModel
    let store: ClipboardStore
    @ObservedObject private var settings = AppCore.shared.settings

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ClipboardInfoSection(
                    item: item, imageURL: store.imageURL(for: item), store: store)
            }
            .padding(.horizontal, 12)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text, .path:
            SelectableAttributedText(
                attributed: SearchHighlight.attributed(item.text ?? "", query: query),
                selectionEnabled: !vm.menuOpen
            )
        case .markdown:
            if settings.renderMarkdown {
                MarkdownPreview(
                    source: item.text ?? "", query: query,
                    selectionEnabled: !vm.menuOpen)
            } else {
                SelectableAttributedText(
                    attributed: SearchHighlight.attributed(item.text ?? "", query: query),
                    selectionEnabled: !vm.menuOpen
                )
            }
        case .link:
            SelectableAttributedText(
                attributed: SearchHighlight.attributed(item.text ?? "", query: query),
                selectionEnabled: !vm.menuOpen
            )
        case .code:
            CodePreview(
                code: item.text ?? "", query: query,
                selectionEnabled: !vm.menuOpen)
        case .image:
            let imageURL = store.imageURL(for: item)
            AsyncThumbnail(url: imageURL, maxPixel: Self.previewMaxPixel) {
                image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
                    )
            } placeholder: {
                Image(systemName: "photo").font(.system(.largeTitle))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
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

/// The "Information" block under the preview (label/value rows split by hairlines); disk- or full-text-touching details are gathered off the main actor per selection so clicking huge entries never hitches.
private struct ClipboardInfoSection: View {
    let item: ClipboardItem
    let imageURL: URL?

    @ObservedObject var store: ClipboardStore
    @State private var details = Details()
    @ObservedObject private var settings = AppCore.shared.settings

    private struct Details: Equatable, Sendable {
        var characters: Int?
        var words: Int?
        var pixelSize: CGSize?
        var fileBytes: Int?
    }

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
        .task(id: item.id) { await loadDetails() }
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
        switch item.kind {
        case .text, .markdown, .code, .link, .path:
            if let characters = details.characters {
                rows.append(
                    InfoRow(
                        label: "Characters",
                        value: characters.formatted(
                            .number.locale(settings.language.locale))))
            }
            if let words = details.words {
                rows.append(
                    InfoRow(
                        label: "Words",
                        value: words.formatted(.number.locale(settings.language.locale))))
            }
        case .image:
            if let size = details.pixelSize {
                rows.append(
                    InfoRow(label: "Dimensions", value: "\(Int(size.width))×\(Int(size.height))"))
            }
            if let bytes = details.fileBytes {
                rows.append(
                    InfoRow(
                        label: "Size",
                        value: Int64(bytes).formatted(
                            .byteCount(style: .file).locale(settings.language.locale))))
            }
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

    private func loadDetails() async {
        let text = item.text
        let url = imageURL
        let loaded = await Task.detached(priority: .userInitiated) {
            var details = Details()
            if let text {
                details.characters = text.count
                details.words = Self.wordCount(text)
            }
            if let url {
                details.pixelSize = ImageThumbnail.pixelSize(of: url)
                details.fileBytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }
            return details
        }.value
        guard !Task.isCancelled else { return }
        details = loaded
    }

    /// Single pass over scalars — `split(whereSeparator:)` would allocate a substring per word, which matters for a multi-MB copy.
    private nonisolated static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let separator = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if !separator && !inWord { count += 1 }
            inWord = !separator
        }
        return count
    }
}
