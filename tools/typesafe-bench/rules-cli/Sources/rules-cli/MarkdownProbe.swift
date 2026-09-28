import Markdown

// Verbatim port of the isMarkdown probe from Kit/Support/MarkdownAttributedRenderer.swift.
// Only the render path (AppKit-dependent) is dropped; the detection logic is unchanged.
enum MarkdownAttributedRenderer {
    private static let maximumRenderedBytes = 512 * 1024

    nonisolated static func isMarkdown(_ source: String) -> Bool {
        markdownDocument(for: source) != nil
    }

    private nonisolated static func markdownDocument(for source: String) -> Document? {
        guard source.utf8.count <= maximumRenderedBytes else { return nil }
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return containsVisibleMarkup(document) ? document : nil
    }

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
