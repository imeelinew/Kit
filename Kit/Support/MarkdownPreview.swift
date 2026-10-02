import AppKit
import SwiftUI

/// Lives outside `MarkdownPreview` so the byte-bounded parse cache is not MainActor-isolated.
private enum MarkdownPreviewCache {
    final class Key: NSObject {
        let source: String
        let fontSize: CGFloat?

        init(source: String, fontSize: CGFloat?) {
            self.source = source
            self.fontSize = fontSize
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(source)
            hasher.combine(fontSize)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return source == other.source && fontSize == other.fontSize
        }
    }

    final class Entry: NSObject {
        let markdown: NSAttributedString?
        init(markdown: NSAttributedString?) { self.markdown = markdown }
    }

    final class Store: NSCache<Key, Entry>, @unchecked Sendable {}

    static let shared: Store = {
        let cache = Store()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}

/// GitHub-flavored Markdown preview for stored Markdown items. Parsing and deterministic AppKit
/// layout run off the main actor; the raw source remains visible until the result is ready and
/// remains the payload used by clipboard actions.
struct MarkdownPreview: View {
    let source: String
    var query: String = ""
    var fontSize: CGFloat? = nil

    @State private var rendered: Rendered?
    @State private var renderedID: RenderID?

    private var currentRendered: Rendered? {
        if renderedID == RenderID(source: source, fontSize: fontSize) {
            return rendered
        }
        // Reopening a cached preview should never briefly show the raw Markdown.
        return MarkdownPreviewCache.shared.object(
            forKey: MarkdownPreviewCache.Key(source: source, fontSize: fontSize)
        ).map { Self.renderedContent(markdown: $0.markdown) }
    }

    private enum Rendered: @unchecked Sendable {
        case plainText
        case appKit(NSAttributedString)
    }

    private struct RenderID: Hashable {
        let source: String
        let fontSize: CGFloat?
    }

    private nonisolated static func render(
        _ source: String,
        fontSize: CGFloat?
    ) -> Rendered {
        let key = MarkdownPreviewCache.Key(source: source, fontSize: fontSize)
        let markdown: NSAttributedString?
        if let cached = MarkdownPreviewCache.shared.object(forKey: key) {
            markdown = cached.markdown
        } else {
            markdown = MarkdownAttributedRenderer.render(source, basePointSize: fontSize)
            MarkdownPreviewCache.shared.setObject(
                MarkdownPreviewCache.Entry(markdown: markdown), forKey: key,
                cost: max(source.utf8.count, markdown?.length ?? 0))
        }
        return renderedContent(markdown: markdown)
    }

    private nonisolated static func renderedContent(
        markdown: NSAttributedString?
    ) -> Rendered {
        if let markdown { return .appKit(markdown) }
        return .plainText
    }

    var body: some View {
        Group {
            switch currentRendered {
            case .appKit(let value):
                previewText(nsAttributed: SearchHighlight.applying(to: value, query: query))
            case .plainText:
                previewText(attributed: SearchHighlight.attributed(source, query: query))
            case nil:
                previewText(attributed: AttributedString(source))
            }
        }
        .task(id: RenderID(source: source, fontSize: fontSize)) {
            // Search changes only update highlighting; keep the parsed document intact.
            let task = Task.detached(priority: .userInitiated) {
                Self.render(source, fontSize: fontSize)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            rendered = result
            renderedID = RenderID(source: source, fontSize: fontSize)
        }
    }

    private func previewText(attributed: AttributedString) -> AttributedTextPreview {
        AttributedTextPreview(
            attributed: attributed,
            contentID: PreviewContentID(source: source, query: query, rendered: currentRendered != nil),
            fontSize: fontSize)
    }

    private func previewText(nsAttributed: NSAttributedString) -> AttributedTextPreview {
        AttributedTextPreview(
            nsAttributed: nsAttributed,
            contentID: PreviewContentID(source: source, query: query, rendered: currentRendered != nil),
            fontSize: fontSize)
    }
}
