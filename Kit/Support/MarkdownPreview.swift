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

    // NSCache synchronizes access, entries are immutable after insertion
    final class Store: @unchecked Sendable {
        let values = NSCache<Key, Entry>()
    }

    static let shared: Store = {
        let cache = Store()
        cache.values.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}

/// GitHub-flavored Markdown preview for stored Markdown items. Parsed documents are cached in
/// `MarkdownPreviewCache` so first-frame layout and search highlight updates never flash or jump.
struct MarkdownPreview: View, Equatable {
    let source: String
    var query: String = ""
    var fontSize: CGFloat? = nil

    private enum Rendered {
        case plainText
        case appKit(NSAttributedString)
    }

    nonisolated static func prewarm(_ source: String, fontSize: CGFloat? = nil) {
        _ = render(source, fontSize: fontSize)
    }

    private nonisolated static func render(
        _ source: String,
        fontSize: CGFloat?
    ) -> Rendered {
        let key = MarkdownPreviewCache.Key(source: source, fontSize: fontSize)
        let markdown: NSAttributedString?
        if let cached = MarkdownPreviewCache.shared.values.object(forKey: key) {
            markdown = cached.markdown
        } else {
            markdown = MarkdownAttributedRenderer.render(source, basePointSize: fontSize)
            MarkdownPreviewCache.shared.values.setObject(
                MarkdownPreviewCache.Entry(markdown: markdown), forKey: key,
                cost: max(source.utf8.count, markdown?.length ?? 0))
        }
        if let markdown { return .appKit(markdown) }
        return .plainText
    }

    var body: some View {
        switch Self.render(source, fontSize: fontSize) {
        case .appKit(let value):
            AttributedTextPreview(
                nsAttributed: SearchHighlight.applying(to: value, query: query),
                contentID: PreviewContentID(source: source, query: query),
                fontSize: fontSize)
        case .plainText:
            AttributedTextPreview(
                attributed: SearchHighlight.attributed(source, query: query),
                contentID: PreviewContentID(source: source, query: query),
                fontSize: fontSize)
        }
    }
}
