import AppKit
import CoreText
import SwiftUI
import wchar_h
import xlocale

@MainActor
private struct PinnedCardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            var squares = Path()
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in stride(from: row % 2, to: Int(ceil(size.width / tile)), by: 2) {
                    squares.addRect(CGRect(
                        x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                        width: tile, height: tile))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.82)))
        }
        .background(Color(white: 0.94))
        .compositingGroup()
        .opacity(0.65)
        .ignoresSafeArea()
    }
}

@MainActor
struct PinnedImageContent: View {
    let image: NSImage
    let onClose: () -> Void


    var body: some View {
        ZStack(alignment: .top) {
            PinnedCardBackground()

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            PinnedCloseButton(isImage: true, action: onClose)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .ignoresSafeArea()

    }
}

@MainActor
struct PinnedTextContent: View {
    static let minimumSize = CGSize(width: 200, height: 84)
    private static let headerHeight: CGFloat = 42
    private static let contentInset: CGFloat = 14

    let text: String
    let kind: ClipboardItem.Kind
    let terminalText: NSAttributedString?
    let settings: AppSettings
    let onClose: () -> Void

    var body: some View {
        let edge = Self.contentInset
        ZStack(alignment: .topLeading) {
            preview
                .environment(\.previewTextSelectable, false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(EdgeInsets(top: Self.headerHeight, leading: edge, bottom: edge, trailing: edge))

            PinnedCloseButton(isImage: false, action: onClose)
                .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    @ViewBuilder private var preview: some View {
        if let terminalText {
            AttributedTextPreview(nsAttributed: terminalText,
                                  contentID: PreviewContentID(source: text, query: ""), wrapsLines: false)
        } else {
            switch kind {
            case .markdown where settings.renderMarkdown:
                MarkdownPreview(source: text).equatable()
            default:
                ClipboardTextPreview(text: text, query: "").equatable()
            }
        }
    }

    static func initialFrame(
        text: String, kind: ClipboardItem.Kind, terminalText: NSAttributedString?, visibleFrame: CGRect
    ) -> CGRect {
        let availableWidth = max(1, visibleFrame.width - 24)
        let availableHeight = max(1, visibleFrame.height - 24)
        let pointSize = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = ClipboardPreviewFont.regular(ofSize: pointSize)
        let edge = contentInset
        let insets = 2 * edge + PreviewTextView.trailingGutter
        let lines = text.prefix(4_096).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(32)
        let widths = lines.map { line in
            let sample = line.prefix(240)
            if let terminalText {
                let range = NSRange(sample.startIndex..<sample.endIndex, in: text)
                return terminalText.attributedSubstring(from: range).size().width
            }
            return (String(sample) as NSString).size(withAttributes: [.font: font]).width
        }
        let idealWidth = max((widths.max() ?? 0) + insets, minimumSize.width)
        let widthLimit = terminalText != nil ? availableWidth : min(540, availableWidth)
        let width = min(ceil(idealWidth), widthLimit)
        let contentWidth = max(1, width - insets)
        let rows = terminalText != nil
            ? CGFloat(lines.count) : widths.reduce(0) { $0 + max(1, ceil($1 / contentWidth)) }
        let rowHeight = terminalText != nil ? terminalLineHeight(for: font) : font.ascender - font.descender + font.leading
        let idealHeight = max(Self.headerHeight + edge + rows * rowHeight + 4, minimumSize.height)
        let height = min(ceil(idealHeight), 360, availableHeight)
        return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                      width: width, height: height)
    }

    static func makeTerminalText(_ source: String) -> NSAttributedString {
        let font = ClipboardPreviewFont.regular(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
        let cellWidth = advance(of: " ", font: font)
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .leftToRight
        style.tabStops = []
        style.defaultTabInterval = cellWidth * 8
        style.minimumLineHeight = terminalLineHeight(for: font)
        style.maximumLineHeight = style.minimumLineHeight
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font, .ligature: 0, .paragraphStyle: style,
        ])
        MarkdownAttributedRenderer.colorTerminalText(result)
        NerdSymbolsFont.applyFallback(to: result, baseFont: font)
        guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { return result }
        defer { freelocale(locale) }

        // Fallback glyph advances can differ from the terminal's one- or two-cell widths
        var adjustments: [Character: CGFloat] = [:]
        var offset = 0
        for character in source {
            if character.unicodeScalars.count == 1, character.asciiValue != nil {
                offset += 1
                continue
            }
            let length = character.utf16.count
            let range = NSRange(location: offset, length: length)
            offset += length
            guard !character.isNewline else { continue }

            let adjustment: CGFloat
            if let cached = adjustments[character] {
                adjustment = cached
            } else {
                let scalars = character.unicodeScalars
                let columns = scalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
                    ? 2 : scalars.reduce(0) { max($0, Int(wcwidth_l(wchar_t($1.value), locale))) }
                let glyphFont = (result.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? font
                adjustment = columns > 0
                    ? CGFloat(columns) * cellWidth - advance(of: String(character), font: glyphFont) : 0
                adjustments[character] = adjustment
            }
            if abs(adjustment) > 0.01 { result.addAttribute(.kern, value: adjustment, range: range) }
        }
        return result
    }

    private static func advance(of text: String, font: NSFont) -> CGFloat {
        let value = NSAttributedString(string: text, attributes: [.font: font, .ligature: 0])
        let line = CTLineCreateWithAttributedString(value as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func terminalLineHeight(for font: NSFont) -> CGFloat {
        ceil(max(font.ascender - font.descender + font.leading, font.pointSize * 1.35))
    }
}

private struct PinnedCloseButton: View {
    private static let systemLabel = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])?
        .accessibilityLabel() ?? ""

    let isImage: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frosted(in: Circle())

        if isImage {
            button.accessibilityLabel("Close Pinned Image").help("Close Pinned Image")
        } else {
            button.accessibilityLabel(Text(verbatim: Self.systemLabel))
        }
    }
}
