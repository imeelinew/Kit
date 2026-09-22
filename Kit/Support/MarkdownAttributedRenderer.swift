import AppKit
import Markdown

/// Converts a GitHub-flavored Markdown syntax tree into fully styled AppKit text. Every block
/// boundary and font is explicit: `NSTextView` is only responsible for drawing and selection.
enum MarkdownAttributedRenderer {
    /// Very large clipboard entries stay on the existing plain-text path. Parsing a selected
    /// half-megabyte document is already far beyond a useful palette preview.
    private static let maximumRenderedBytes = 512 * 1024

    nonisolated static func render(
        _ source: String,
        basePointSize: CGFloat? = nil
    ) -> NSAttributedString? {
        guard let document = markdownDocument(for: source) else { return nil }

        var renderer = Renderer(
            basePointSize: basePointSize
                ?? NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
        renderer.renderDocument(document)
        return NSAttributedString(attributedString: renderer.output)
    }

    nonisolated static func isMarkdown(_ source: String) -> Bool {
        markdownDocument(for: source) != nil
    }

    private nonisolated static func markdownDocument(for source: String) -> Document? {
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

    private struct InlineStyle: OptionSet, Sendable {
        let rawValue: UInt8

        static let strong = InlineStyle(rawValue: 1 << 0)
        static let emphasis = InlineStyle(rawValue: 1 << 1)
        static let code = InlineStyle(rawValue: 1 << 2)
        static let strikethrough = InlineStyle(rawValue: 1 << 3)
    }

    private struct Renderer {
        let output = NSMutableAttributedString(string: "")

        private let basePointSize: CGFloat
        private let listStep: CGFloat = 18

        init(basePointSize: CGFloat) {
            self.basePointSize = basePointSize
        }

        mutating func renderDocument(_ document: Document) {
            for child in document.children {
                renderBlock(child, leftIndent: 0)
            }
        }

        private mutating func renderBlock(_ block: any Markup, leftIndent: CGFloat) {
            switch block {
            case let paragraph as Paragraph:
                appendParagraph(paragraph, leftIndent: leftIndent)
            case let heading as Heading:
                appendHeading(heading, leftIndent: leftIndent)
            case let list as OrderedList:
                appendOrderedList(list, leftIndent: leftIndent)
            case let list as UnorderedList:
                appendUnorderedList(list, leftIndent: leftIndent)
            case let quote as BlockQuote:
                appendBlockQuote(quote, leftIndent: leftIndent)
            case let code as CodeBlock:
                appendCodeBlock(code, leftIndent: leftIndent)
            case is ThematicBreak:
                appendThematicBreak(leftIndent: leftIndent)
            case let table as Table:
                appendTable(table, leftIndent: leftIndent)
            case let html as HTMLBlock:
                appendHTMLBlock(html, leftIndent: leftIndent)
            default:
                for child in block.children {
                    renderBlock(child, leftIndent: leftIndent)
                }
            }
        }

        private mutating func appendParagraph(_ paragraph: Paragraph, leftIndent: CGFloat) {
            let content = inlineContent(of: paragraph)
            commit(
                content,
                paragraphStyle: bodyParagraphStyle(leftIndent: leftIndent, spacingAfter: 8))
        }

        private mutating func appendHeading(_ heading: Heading, leftIndent: CGFloat) {
            let sizeIncrease: CGFloat
            switch heading.level {
            case 1: sizeIncrease = 3
            case 2: sizeIncrease = 2
            case 3: sizeIncrease = 1.5
            default: sizeIncrease = 0.5
            }

            let content = inlineContent(
                of: heading, inheritedStyle: .strong, pointSize: basePointSize + sizeIncrease)
            let style = bodyParagraphStyle(leftIndent: leftIndent, spacingAfter: 5)
            style.paragraphSpacingBefore = heading.level <= 2 ? 10 : 7
            commit(content, paragraphStyle: style)
        }

        private mutating func appendOrderedList(_ list: OrderedList, leftIndent: CGFloat) {
            for (offset, item) in list.listItems.enumerated() {
                appendListItem(
                    item, marker: "\(Int(list.startIndex) + offset).", leftIndent: leftIndent)
            }
        }

        private mutating func appendUnorderedList(_ list: UnorderedList, leftIndent: CGFloat) {
            for item in list.listItems {
                let marker: String
                switch item.checkbox {
                case .some(.checked): marker = "☑︎"
                case .some(.unchecked): marker = "☐"
                case nil: marker = "•"
                }
                appendListItem(item, marker: marker, leftIndent: leftIndent)
            }
        }

        private mutating func appendListItem(
            _ item: ListItem, marker: String, leftIndent: CGFloat
        ) {
            var emittedFirstParagraph = false

            for child in item.children {
                switch child {
                case let paragraph as Paragraph:
                    let content = NSMutableAttributedString(string: "")
                    append(
                        emittedFirstParagraph ? "\t" : marker + "\t",
                        to: content,
                        style: emittedFirstParagraph ? [] : .strong)
                    appendInlineChildren(of: paragraph, to: content)
                    commit(
                        content,
                        paragraphStyle: listParagraphStyle(leftIndent: leftIndent))
                    emittedFirstParagraph = true
                case let nested as OrderedList:
                    appendOrderedList(nested, leftIndent: leftIndent + listStep)
                case let nested as UnorderedList:
                    appendUnorderedList(nested, leftIndent: leftIndent + listStep)
                default:
                    if !emittedFirstParagraph {
                        let markerLine = NSMutableAttributedString(string: "")
                        append(marker, to: markerLine, style: .strong)
                        commit(
                            markerLine,
                            paragraphStyle: listParagraphStyle(leftIndent: leftIndent))
                        emittedFirstParagraph = true
                    }
                    renderBlock(child, leftIndent: leftIndent + listStep)
                }
            }

            if !emittedFirstParagraph {
                let markerLine = NSMutableAttributedString(string: "")
                append(marker, to: markerLine, style: .strong)
                commit(markerLine, paragraphStyle: listParagraphStyle(leftIndent: leftIndent))
            }
        }

        private mutating func appendBlockQuote(_ quote: BlockQuote, leftIndent: CGFloat) {
            for child in quote.children {
                if let paragraph = child as? Paragraph {
                    let content = NSMutableAttributedString(string: "")
                    append("▎\t", to: content, color: .tertiaryLabelColor)
                    appendInlineChildren(of: paragraph, to: content)
                    let style = bodyParagraphStyle(
                        leftIndent: leftIndent, spacingAfter: 6,
                        hangingIndent: leftIndent + 16)
                    style.tabStops = [NSTextTab(textAlignment: .left, location: leftIndent + 16)]
                    commit(content, paragraphStyle: style)
                } else {
                    renderBlock(child, leftIndent: leftIndent + 16)
                }
            }
        }

        private mutating func appendCodeBlock(_ codeBlock: CodeBlock, leftIndent: CGFloat) {
            let code = codeBlock.code.trimmingCharacters(in: .newlines)
            let content = CodeSyntaxHighlighter.highlight(
                code,
                attributes: [
                    .font: font(for: .code, pointSize: basePointSize - 0.5),
                    .foregroundColor: NSColor.labelColor,
                ])
            let style = bodyParagraphStyle(
                leftIndent: leftIndent + 8, spacingAfter: 8,
                hangingIndent: leftIndent + 8)
            style.paragraphSpacingBefore = 3
            commit(content, paragraphStyle: style)
        }

        private mutating func appendThematicBreak(leftIndent: CGFloat) {
            let content = NSMutableAttributedString(
                string: "━━━━━━━━━━━━━━━━",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .regular),
                    .foregroundColor: NSColor.separatorColor,
                ])
            let style = bodyParagraphStyle(leftIndent: leftIndent, spacingAfter: 7)
            style.paragraphSpacingBefore = 4
            commit(content, paragraphStyle: style)
        }

        /// A three-column table is unreadable in the palette's ~460pt preview. Render each row as
        /// an adaptive group of labeled values; column order and inline formatting remain intact.
        private mutating func appendTable(_ table: Table, leftIndent: CGFloat) {
            let headers = Array(table.head.cells).map {
                inlineContent(of: $0, inheritedStyle: .strong).string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rows = Array(table.body.rows)

            if rows.isEmpty {
                appendTableRow(Array(table.head.cells), headers: [], leftIndent: leftIndent)
                return
            }

            for row in rows {
                appendTableRow(Array(row.cells), headers: headers, leftIndent: leftIndent)
            }
        }

        private mutating func appendTableRow(
            _ cells: [Table.Cell], headers: [String], leftIndent: CGFloat
        ) {
            let content = NSMutableAttributedString(string: "")
            for (column, cell) in cells.enumerated() {
                if column > 0 { append("\n", to: content) }
                if headers.indices.contains(column), !headers[column].isEmpty {
                    append(
                        headers[column] + ": ", to: content, style: .strong,
                        pointSize: basePointSize - 1, color: .secondaryLabelColor)
                }
                appendInlineChildren(of: cell, to: content)
            }

            let style = bodyParagraphStyle(
                leftIndent: leftIndent + 6, spacingAfter: 9,
                hangingIndent: leftIndent + 6)
            style.lineSpacing = 1.5
            commit(content, paragraphStyle: style)
        }

        private mutating func appendHTMLBlock(_ block: HTMLBlock, leftIndent: CGFloat) {
            let content = NSMutableAttributedString(
                string: block.rawHTML,
                attributes: [
                    .font: font(for: .code),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            commit(
                content,
                paragraphStyle: bodyParagraphStyle(leftIndent: leftIndent, spacingAfter: 8))
        }

        private func inlineContent(
            of markup: any Markup, inheritedStyle: InlineStyle = [],
            pointSize: CGFloat? = nil
        ) -> NSMutableAttributedString {
            let content = NSMutableAttributedString(string: "")
            appendInlineChildren(
                of: markup, to: content, inheritedStyle: inheritedStyle,
                pointSize: pointSize ?? basePointSize)
            return content
        }

        private func appendInlineChildren(
            of markup: any Markup, to target: NSMutableAttributedString,
            inheritedStyle: InlineStyle = [], pointSize: CGFloat? = nil
        ) {
            let size = pointSize ?? basePointSize
            for child in markup.children {
                appendInline(child, to: target, style: inheritedStyle, pointSize: size)
            }
        }

        private func appendInline(
            _ markup: any Markup, to target: NSMutableAttributedString,
            style: InlineStyle, pointSize: CGFloat
        ) {
            switch markup {
            case let text as Markdown.Text:
                append(text.string, to: target, style: style, pointSize: pointSize)
            case is SoftBreak:
                append(" ", to: target, style: style, pointSize: pointSize)
            case is LineBreak:
                append("\n", to: target, style: style, pointSize: pointSize)
            case let code as InlineCode:
                append(
                    code.code, to: target, style: style.union(.code), pointSize: pointSize,
                    background: NSColor.labelColor.withAlphaComponent(0.08))
            case let strong as Strong:
                appendInlineChildren(
                    of: strong, to: target, inheritedStyle: style.union(.strong),
                    pointSize: pointSize)
            case let emphasis as Emphasis:
                appendInlineChildren(
                    of: emphasis, to: target, inheritedStyle: style.union(.emphasis),
                    pointSize: pointSize)
            case let strike as Strikethrough:
                appendInlineChildren(
                    of: strike, to: target, inheritedStyle: style.union(.strikethrough),
                    pointSize: pointSize)
            case let link as Link:
                let start = target.length
                appendInlineChildren(
                    of: link, to: target, inheritedStyle: style, pointSize: pointSize)
                let range = NSRange(location: start, length: target.length - start)
                guard range.length > 0 else { return }
                target.addAttributes(
                    [
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
                if let destination = link.destination, let url = URL(string: destination) {
                    target.addAttribute(.link, value: url, range: range)
                }
            case let image as Markdown.Image:
                append(
                    "▧ ", to: target, style: style, pointSize: pointSize,
                    color: .secondaryLabelColor)
                let start = target.length
                appendInlineChildren(
                    of: image, to: target, inheritedStyle: style, pointSize: pointSize)
                if target.length == start {
                    append(
                        image.title ?? image.source ?? "Image", to: target,
                        style: style, pointSize: pointSize, color: .secondaryLabelColor)
                }
            case let html as InlineHTML:
                let value = html.rawHTML.range(
                    of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil
                    ? "\n" : html.rawHTML
                append(value, to: target, style: style, pointSize: pointSize)
            default:
                appendInlineChildren(
                    of: markup, to: target, inheritedStyle: style, pointSize: pointSize)
            }
        }

        private func append(
            _ string: String, to target: NSMutableAttributedString,
            style: InlineStyle = [], pointSize: CGFloat? = nil,
            color: NSColor = .labelColor, background: NSColor? = nil
        ) {
            guard !string.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: style, pointSize: pointSize ?? basePointSize),
                .foregroundColor: color,
            ]
            if style.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let background { attributes[.backgroundColor] = background }
            target.append(NSAttributedString(string: string, attributes: attributes))
        }

        private func font(
            for style: InlineStyle, pointSize: CGFloat? = nil
        ) -> NSFont {
            let size = pointSize ?? basePointSize
            let weight: NSFont.Weight = style.contains(.strong) ? .semibold : .regular
            let base = style.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            guard style.contains(.emphasis) else { return base }
            let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: descriptor, size: size) ?? base
        }

        private mutating func commit(
            _ content: NSMutableAttributedString, paragraphStyle: NSParagraphStyle
        ) {
            guard content.length > 0 else { return }
            append("\n", to: content)
            content.addAttribute(
                .paragraphStyle, value: paragraphStyle,
                range: NSRange(location: 0, length: content.length))
            output.append(content)
        }

        private func bodyParagraphStyle(
            leftIndent: CGFloat, spacingAfter: CGFloat,
            hangingIndent: CGFloat? = nil
        ) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .natural
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 2
            style.paragraphSpacing = spacingAfter
            style.firstLineHeadIndent = leftIndent
            style.headIndent = hangingIndent ?? leftIndent
            return style
        }

        private func listParagraphStyle(leftIndent: CGFloat) -> NSMutableParagraphStyle {
            let contentIndent = leftIndent + listStep
            let style = bodyParagraphStyle(
                leftIndent: leftIndent, spacingAfter: 3, hangingIndent: contentIndent)
            style.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
            style.defaultTabInterval = listStep
            return style
        }
    }
}
