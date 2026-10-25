import AppKit
import QuartzCore
import SwiftUI

/// A complete preview is published together, so image decoding and metadata cannot resize
/// the pane in separate frames. Cached payloads live only for the current palette session.
@MainActor
final class ClipboardPreviewPayload {
    let itemID: ClipboardItem.ID
    let image: NSImage?
    let details: Details
    private let copiedAt: Date
    private let imageURL: URL?
    private let imageVersion: UInt64

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
    private static var cacheGeneration: UInt64 = 0

    static func purge() {
        cacheGeneration &+= 1
        cache.removeAllObjects()
    }

    private init(
        item: ClipboardItem, image: NSImage?, details: Details,
        imageURL: URL?, imageVersion: UInt64
    ) {
        self.itemID = item.id
        self.image = image
        self.details = details
        self.copiedAt = item.lastCopiedAt
        self.imageURL = imageURL
        self.imageVersion = imageVersion
    }

    func matches(_ item: ClipboardItem) -> Bool {
        itemID == item.id && copiedAt == item.lastCopiedAt
            && imageVersion == (imageURL.map { ImageThumbnail.fileVersion(for: $0) } ?? 0)
    }

    static func cached(for item: ClipboardItem) -> ClipboardPreviewPayload? {
        guard let payload = cache.object(forKey: item.id as NSUUID), payload.matches(item)
        else { return nil }
        return payload
    }

    static func load(for item: ClipboardItem, imageURL: URL?) async -> ClipboardPreviewPayload {
        if let hit = cached(for: item) { return hit }
        let generation = cacheGeneration
        let imageVersion = imageURL.map { ImageThumbnail.fileVersion(for: $0) } ?? 0
        let detailsTask = Task.detached(priority: .userInitiated) {
            var details = Details()
            guard !Task.isCancelled else { return details }
            if let text = item.text {
                details.characters = text.utf16.count
                var count = 0
                var inWord = false
                for scalar in text.unicodeScalars {
                    guard !Task.isCancelled else { return details }
                    let separator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                    if !separator && !inWord { count += 1 }
                    inWord = !separator
                }
                details.words = count
            }
            if let imageURL,
                FileManager.default.fileExists(atPath: imageURL.path)
            {
                details.pixelSize = ImageThumbnail.pixelSize(of: imageURL)
                details.fileBytes = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } else if item.isFileBacked {
                var totalBytes = 0
                var foundSize = false
                for url in item.fileURLs {
                    guard let values = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]),
                        values.isRegularFile == true,
                        let size = values.fileSize
                    else { continue }
                    totalBytes += size
                    foundSize = true
                }
                details.fileBytes = foundSize ? totalBytes : nil
            }
            return details
        }
        let payload = await withTaskCancellationHandler {
            let image: NSImage?
            if let imageURL, FileManager.default.fileExists(atPath: imageURL.path) {
                image = await ImageThumbnail.loadAsync(imageURL, maxPixel: 900)
            } else {
                image = nil
            }
            return ClipboardPreviewPayload(
                item: item, image: image, details: await detailsTask.value,
                imageURL: imageURL, imageVersion: imageVersion)
        } onCancel: {
            detailsTask.cancel()
        }
        if !Task.isCancelled, generation == cacheGeneration, payload.matches(item) {
            let cost = payload.image.map { Int($0.size.width * $0.size.height) * 4 } ?? 1
            cache.setObject(payload, forKey: item.id as NSUUID, cost: cost)
        }
        return payload
    }
}

struct ClipboardPreview: View {
    private struct LoadID: Hashable {
        let itemID: ClipboardItem.ID
        let copiedAt: Date
        let imageVersion: UInt64
    }

    private struct HighlightLoadID: Hashable {
        let url: URL
        let version: UInt64
    }

    let item: ClipboardItem?
    var query: String = ""
    @Bindable var vm: PaletteViewModel
    let store: ClipboardStore
    @ObservedObject var settings: AppSettings

    @State private var loadedPayload: ClipboardPreviewPayload?
    @State private var imageHighlights: ImageSearchHighlightPayload?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loadID: LoadID? {
        item.map {
            LoadID(
                itemID: $0.id, copiedAt: $0.lastCopiedAt,
                imageVersion: store.imageURL(for: $0).map { ImageThumbnail.fileVersion(for: $0) } ?? 0)
        }
    }

    var body: some View {
        let payload = item.flatMap { item in
            (vm.preparedPreview?.matches(item) == true ? vm.preparedPreview : nil)
                ?? ClipboardPreviewPayload.cached(for: item)
                ?? (loadedPayload?.matches(item) == true ? loadedPayload : nil)
        }
        let information = item.map {
            ClipboardInfoSection(item: $0, details: payload?.details ?? .init(), store: store, settings: settings)
        }
        ClipboardPreviewContainer(
            itemID: item?.id, kind: item?.kind, informationHeight: information?.contentHeight ?? 0,
            reduceMotion: reduceMotion,
            content: { onLayoutChange in
                Group { if let item { content(for: item, payload: payload, onLayoutChange: onLayoutChange) } }
            },
            information: Group { if let information { information } })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadID) {
            guard let item else {
                loadedPayload = nil
                return
            }
            let payload = await ClipboardPreviewPayload.load(
                for: item, imageURL: store.imageURL(for: item))
            guard !Task.isCancelled else { return }
            loadedPayload = payload
        }
        .task(id: imageHighlightURL.map {
            HighlightLoadID(url: $0, version: ImageThumbnail.fileVersion(for: $0))
        }) {
            guard let url = imageHighlightURL else {
                imageHighlights = nil
                return
            }
            let payload = await ImageSearchHighlightPayload.load(url)
            guard !Task.isCancelled else { return }
            imageHighlights = payload
        }
    }

    private var imageHighlightURL: URL? {
        guard let item, item.kind == .image,
            !ClipboardImageTextRecognition.normalizedText(query).isEmpty
        else { return nil }
        return store.imageURL(for: item)
    }

    @ViewBuilder
    private func content(
        for item: ClipboardItem, payload: ClipboardPreviewPayload?,
        onLayoutChange: @escaping () -> Void
    ) -> some View {
        switch item.kind {
        case .text, .path, .link:
            ClipboardTextPreview(text: item.text ?? "", query: query).equatable()
        case .markdown:
            if settings.renderMarkdown {
                MarkdownPreview(source: item.text ?? "", query: query, onRender: onLayoutChange)
            } else {
                ClipboardTextPreview(text: item.text ?? "", query: query).equatable()
            }
        case .code:
            CodePreview(code: item.text ?? "", query: query)
        case .file:
            if item.fileURLs.count == 1 {
                ClipboardFilePreview(url: item.fileURLs[0])
            } else {
                ClipboardFileCollectionPreview(urls: item.fileURLs)
            }
        case .image:
            let imageURL = store.imageURL(for: item)
            let highlights = imageURL.flatMap { url in
                ImageSearchHighlightPayload.cached(for: url)
                    ?? (imageHighlights?.matches(url) == true ? imageHighlights : nil)
            }?.layout.matchingBounds(query: query) ?? []
            Group {
                if let image = payload?.image {
                    ClipboardPreviewImage(
                        image: image, highlights: highlights, isPresented: vm.imageQuickLookOpen
                    ) {
                        vm.toggleImageQuickLook(for: item.id)
                    }
                } else {
                    Image(systemName: "photo").font(.system(.largeTitle))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.tertiary)
                }
            }
            // Anchor to the preview image's fitted bounds, not the full preview pane, so the
            // NSPopover arrow points at the image and placement can avoid covering it.
            .overlay {
                ImageQuickLookAnchor(
                    url: imageURL,
                    highlights: highlights,
                    isPresented: Binding(
                        get: { vm.imageQuickLookOpen },
                        set: { vm.imageQuickLookOpen = $0 }
                    ),
                    onActions: { vm.openActions(for: item.id) }
                )
            }
        }
    }
}

private struct ClipboardFilePreview: View {
    let url: URL

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ClipboardFileIcon(url: url, size: 72)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

private struct ClipboardFileCollectionPreview: View {
    let urls: [URL]

    private var height: CGFloat {
        min(320, CGFloat(urls.count) * 50)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: Theme.Spacing.md) {
                        ClipboardFileIcon(url: url, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(url.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(height: 50)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private struct ClipboardFileIcon: View {
    let url: URL
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
                    .padding(size / 7)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(url.absoluteString)#\(ImageThumbnail.fileVersion(for: url))") {
            let version = ImageThumbnail.fileVersion(for: url)
            image = nil
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let loaded = await IconCache.loadAsync(forFile: url.path, version: version)
            guard !Task.isCancelled, version == ImageThumbnail.fileVersion(for: url) else { return }
            image = loaded
        }
    }
}

private struct ClipboardPreviewImage: View {
    let image: NSImage
    let highlights: [CGRect]
    let isPresented: Bool
    let onActivate: () -> Void

    @State private var hovered = false
    @State private var hoverLiftSuppressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lifted: Bool { isPresented || (hovered && !hoverLiftSuppressed) }

    var body: some View {
        Button(action: onActivate) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay {
                    ImageSearchHighlightOverlay(imageSize: image.size, regions: highlights)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(lifted ? 0.14 : 0), radius: 6, x: 0, y: 3)
                .offset(y: lifted && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: lifted)
        }
        .buttonStyle(.plain)
        .onHover {
            hovered = $0
            if !$0 { hoverLiftSuppressed = false }
        }
        .onChange(of: isPresented) {
            if !isPresented { hoverLiftSuppressed = true }
        }
        .accessibilityLabel(Text("Content Preview"))
    }
}

/// AppKit owns pane geometry and transitions while the existing renderers stay hosted
private struct ClipboardPreviewContainer<Content: View, Information: View>: NSViewRepresentable {
    let itemID: ClipboardItem.ID?
    let kind: ClipboardItem.Kind?
    let informationHeight: CGFloat
    let reduceMotion: Bool
    let content: (@escaping () -> Void) -> Content
    let information: Information

    func makeNSView(context: Context) -> ClipboardPreviewContainerView { ClipboardPreviewContainerView() }

    func updateNSView(_ view: ClipboardPreviewContainerView, context: Context) {
        let environment = context.environment
        let itemID = itemID
        let content = content { [weak view] in
            view?.invalidateContentLayout(for: itemID)
        }
        view.update(
            itemID: itemID, kind: kind, informationHeight: informationHeight,
            reduceMotion: reduceMotion, locale: environment.locale,
            content: AnyView(content.environment(\.locale, environment.locale)),
            information: AnyView(information.environment(\.locale, environment.locale)))
    }

    static func dismantleNSView(_ view: ClipboardPreviewContainerView, coordinator: ()) {
        view.clear()
    }
}

private final class ClipboardPreviewContainerView: NSView {
    private var current: ClipboardPreviewPane?
    private var retiring: [ClipboardPreviewPane] = []
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(
        itemID: ClipboardItem.ID?, kind: ClipboardItem.Kind?, informationHeight: CGFloat,
        reduceMotion: Bool, locale: Locale, content: AnyView, information: AnyView
    ) {
        let changed = current?.itemID != itemID
        if changed, let old = current {
            old.retireSelection()
            current = nil
            retiring.append(old)
        }
        if let itemID, let kind {
            if current == nil {
                let pane = ClipboardPreviewPane(itemID: itemID, kind: kind)
                pane.frame = bounds
                addSubview(pane)
                current = pane
            }
            current?.update(kind: kind, informationHeight: informationHeight,
                            reduceMotion: reduceMotion, locale: locale,
                            content: content, information: information)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard changed else { return }
        let outgoing = retiring
        let incoming = current
        incoming?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Theme.Motion.menuDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming?.animator().alphaValue = 1
            outgoing.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                outgoing.forEach { $0.clear(); $0.removeFromSuperview() }
                self?.retiring.removeAll { pane in outgoing.contains { $0 === pane } }
            }
        }
    }

    override func layout() {
        super.layout()
        current?.frame = bounds
    }

    func invalidateContentLayout(for itemID: ClipboardItem.ID?) {
        // Wait for the hosted SwiftUI tree to apply its rendered content before measuring
        DispatchQueue.main.async { [weak self] in
            guard let current = self?.current, current.itemID == itemID else { return }
            current.needsLayout = true
        }
    }

    func clear() {
        ([current].compactMap { $0 } + retiring).forEach {
            $0.clear()
            $0.removeFromSuperview()
        }
        current = nil
        retiring.removeAll()
    }
}

private final class ClipboardPreviewPane: NSView, PreviewSelectionOwner {
    let itemID: ClipboardItem.ID
    private var kind: ClipboardItem.Kind
    private var content = NSHostingController(rootView: AnyView(EmptyView()))
    private let information = PreviewInformationScrollView()
    private let title = NSTextField(labelWithString: "")
    private var informationHeight: CGFloat = 0
    private var isRetiring = false
    override var isFlipped: Bool { true }

    var isPreviewSelectionCurrent: Bool {
        guard !isRetiring else { return false }
        guard let panel = window as? PalettePanel else { return true }
        return panel.paletteViewModel?.selectedID == itemID
    }

    func retireSelection() {
        isRetiring = true
        func clearSelection(in view: NSView) {
            if let text = view as? PreviewTextView {
                text.setSelectedRange(NSRange(location: 0, length: 0))
                text.isSelectable = false
            }
            view.subviews.forEach { clearSelection(in: $0) }
        }
        clearSelection(in: content.view)
    }

    init(itemID: ClipboardItem.ID, kind: ClipboardItem.Kind) {
        self.itemID = itemID
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        prepare(content)
        addSubview(content.view)
        title.font = .systemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        addSubview(title)
        addSubview(information)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func prepare(_ hosting: NSHostingController<AnyView>) {
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
    }

    func update(kind: ClipboardItem.Kind, informationHeight: CGFloat, reduceMotion: Bool,
                locale: Locale, content root: AnyView, information: AnyView) {
        let changedKind = self.kind != kind
        if changedKind {
            let old = content
            let replacement = NSHostingController(rootView: root)
            prepare(replacement)
            replacement.view.frame = old.view.frame
            addSubview(replacement.view, positioned: .above, relativeTo: old.view)
            content = replacement
            replacement.view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : Theme.Motion.contentDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                replacement.view.animator().alphaValue = 1
                old.view.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    old.rootView = AnyView(EmptyView())
                    old.view.removeFromSuperview()
                }
            }
        } else {
            content.rootView = root
        }
        self.kind = kind
        self.informationHeight = informationHeight
        title.stringValue = AppLocalization.string("Information", locale: locale)
        self.information.update(content: information, height: max(0, informationHeight - 40))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 40)
        let padding: CGFloat = kind == .image ? 0 : 12
        // Preserve the original layout proposal and information cap exactly
        let measured = content.sizeThatFits(in: CGSize(
            width: width, height: max(0, bounds.height * 0.6 - padding * 2))).height + padding * 2
        let infoHeight = min(informationHeight, max(bounds.height * 0.4, bounds.height - measured))
        let previewHeight = max(0, bounds.height - infoHeight)
        let available = max(0, previewHeight - padding * 2)
        let fitted = content.sizeThatFits(in: CGSize(width: width, height: available))
        content.view.frame = NSRect(x: 20, y: padding, width: width, height: min(available, fitted.height))
        title.frame = NSRect(x: 28, y: previewHeight + 12 + (28 - title.intrinsicContentSize.height) / 2,
                             width: max(0, width - 16), height: title.intrinsicContentSize.height)
        information.frame = NSRect(x: 20, y: previewHeight + 40,
                                    width: width, height: max(0, infoHeight - 40))
    }

    func clear() {
        content.rootView = AnyView(EmptyView())
        information.update(content: AnyView(EmptyView()), height: 0)
    }
}

private final class PreviewInformationScrollView: KitScrollView {
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    private let document = PreviewInformationDocument()
    private var rowsHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        document.addSubview(hosting.view)
        installDocumentView(document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(content: AnyView, height: CGFloat) {
        hosting.rootView = content
        rowsHeight = height
        needsLayout = true
    }

    override func layout() {
        super.layout()
        document.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: rowsHeight)
        hosting.view.frame = NSRect(x: 0, y: 0, width: max(0, contentSize.width - 16), height: rowsHeight)
        updateScrollAppearance()
    }
}

private final class PreviewInformationDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Selection, footer and metadata changes must not reformat unchanged preview text.
struct ClipboardTextPreview: View, Equatable {
    let text: String
    let query: String
    var fontSize: CGFloat? = nil

    var body: some View {
        AttributedTextPreview(
            attributed: SearchHighlight.attributed(text, query: query),
            contentID: PreviewContentID(source: text, query: query), fontSize: fontSize)
    }
}

/// Information rows keep their geometry while the complete preview payload loads off-main.
private struct ClipboardInfoSection: View {
    let item: ClipboardItem
    let details: ClipboardPreviewPayload.Details

    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettings

    private struct InfoRow: Identifiable {
        let label: String
        let value: String
        var localizesValue = false
        var icon: NSImage?
        var id: String { label }
    }

    /// Relative day name plus exact time ("Today at 1:22:57 AM"); shared because `DateFormatter` is expensive to build.
    @MainActor private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var contentHeight: CGFloat {
        12 + 28 + CGFloat(rows.count) * 28
    }

    var body: some View {
        VStack(spacing: 0) {
            let rows = self.rows
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: Theme.Spacing.sm) {
                    Text(LocalizedStringKey(row.label)).foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.lg)
                    if let icon = row.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Group {
                        if row.localizesValue {
                            Text(LocalizedStringKey(row.value))
                        } else {
                            Text(row.value)
                        }
                    }
                    .contentTransition(.opacity)
                    .animation(
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                            ? nil : Theme.Motion.content,
                        value: item.kind)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    if index.isMultiple(of: 2) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.025))
                    }
                }
            }
        }
    }
    private var rows: [InfoRow] {
        var rows: [InfoRow] = []
        if let source {
            rows.append(InfoRow(label: "Source", value: source.name, icon: source.icon))
        }
        rows.append(
            InfoRow(
                label: "Type",
                value: item.typeLabel,
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
            if item.isFileBacked {
                rows.append(filePathRow)
            }
            rows.append(InfoRow(label: "Dimensions", value: details.pixelSize.map {
                "\(Int($0.width))×\(Int($0.height))"
            } ?? "—"))
            rows.append(sizeRow)
        case .file:
            if item.fileURLs.count > 1 {
                rows.append(
                    InfoRow(
                        label: "Count", value: item.fileURLs.count.formatted(
                            .number.locale(settings.language.locale))))
            }
            rows.append(filePathRow)
            rows.append(sizeRow)
        }
        Self.timestampFormatter.locale = settings.language.locale
        if item.copyCount > 1 {
            rows.append(InfoRow(label: "Times copied", value: item.copyCount.formatted(.number.locale(settings.language.locale))))
            rows.append(
                InfoRow(label: "Last copied", value: Self.timestampFormatter.string(from: item.lastCopiedAt)))
            rows.append(
                InfoRow(label: "First copied", value: Self.timestampFormatter.string(from: item.firstCopiedAt)))
        } else {
            rows.append(
                InfoRow(label: "Copied", value: Self.timestampFormatter.string(from: item.lastCopiedAt)))
        }
        return rows
    }

    private var filePathRow: InfoRow {
        InfoRow(label: "Path", value: item.fileURLs.map(\.path).joined(separator: ", "))
    }

    private var sizeRow: InfoRow {
        InfoRow(label: "Size", value: details.fileBytes.map {
            Int64($0).formatted(.byteCount(style: .file).locale(settings.language.locale))
        } ?? "—")
    }

    /// Source app name + icon from the recorded bundle ID; the Launch Services lookup is a quick main-thread call and the icon comes from the shared `IconCache`.
    private var source: (name: String, icon: NSImage)? {
        guard let bundleID = item.sourceBundleID,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return (url.deletingPathExtension().lastPathComponent, IconCache.icon(forFile: url.path))
    }

}
