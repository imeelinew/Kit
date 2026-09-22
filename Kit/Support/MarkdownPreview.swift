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

/// GitHub-flavored Markdown preview for ordinary clipboard text. Parsing and deterministic AppKit
/// layout run off the main actor; the raw source remains visible until the result is ready and
/// remains the payload used by clipboard actions.
struct MarkdownPreview: View {
    let source: String
    var query: String = ""
    var fontSize: CGFloat? = nil
    var scrollPosition: CGPoint? = nil
    var selection: NSRange? = nil
    var onScroll: ((CGPoint) -> Void)? = nil
    var onSelectionChange: ((NSRange) -> Void)? = nil

    @State private var rendered: Rendered?

    private enum Rendered: @unchecked Sendable {
        case swiftUI(AttributedString)
        case appKit(NSAttributedString)
    }

    private struct RenderID: Hashable {
        let source: String
        let query: String
        let fontSize: CGFloat?
    }

    private nonisolated static func render(
        _ source: String,
        query: String,
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
        if let markdown {
            return .appKit(SearchHighlight.applying(to: markdown, query: query))
        }
        return .swiftUI(SearchHighlight.attributed(source, query: query))
    }

    var body: some View {
        Group {
            switch rendered {
            case .appKit(let value):
                selectableText(nsAttributed: value)
            case .swiftUI(let value):
                selectableText(attributed: value)
            case nil:
                selectableText(attributed: AttributedString(source))
            }
        }
        .task(id: RenderID(source: source, query: query, fontSize: fontSize)) {
            rendered = nil
            let task = Task.detached(priority: .userInitiated) {
                Self.render(source, query: query, fontSize: fontSize)
            }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            rendered = result
        }
    }

    private func selectableText(attributed: AttributedString) -> SelectableAttributedText {
        SelectableAttributedText(
            attributed: attributed,
            fontSize: fontSize,
            scrollPosition: scrollPosition,
            selection: selection,
            onScroll: onScroll,
            onSelectionChange: onSelectionChange)
    }

    private func selectableText(nsAttributed: NSAttributedString) -> SelectableAttributedText {
        SelectableAttributedText(
            nsAttributed: nsAttributed,
            fontSize: fontSize,
            scrollPosition: scrollPosition,
            selection: selection,
            onScroll: onScroll,
            onSelectionChange: onSelectionChange)
    }
}
