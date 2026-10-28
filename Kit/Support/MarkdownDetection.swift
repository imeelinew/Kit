import Markdown

/// Decides whether clipboard text contains Markdown structure. Rendering stays in
/// `MarkdownAttributedRenderer`. Classification must not depend on AppKit text layout.
enum MarkdownDetection {
    /// Very large clipboard entries stay on the plain-text path. Parsing a selected
    /// half-megabyte document is already far beyond a useful palette preview.
    private static let maximumRenderedBytes = 512 * 1024

    nonisolated static func isMarkdown(_ source: String) -> Bool {
        document(for: source) != nil
    }

    nonisolated static func document(for source: String) -> Document? {
        guard source.utf8.count <= maximumRenderedBytes else { return nil }
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return containsVisibleMarkup(document) ? document : nil
    }

    /// A document containing only plain paragraphs and soft wrapping should remain byte-for-byte
    /// plain text. Any actual Markdown construct opts the whole document into rendered layout.
    private nonisolated static func containsVisibleMarkup(_ markup: any Markup) -> Bool {
        switch markup {
        case is Document, is Paragraph:
            return markup.children.contains { containsVisibleMarkup($0) }
        case is Markdown.Text, is SoftBreak:
            return false
        default:
            return true
        }
    }
}
