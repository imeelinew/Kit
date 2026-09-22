import SwiftUI
import AppKit

/// Search emphasis for clipboard list titles and preview bodies: literal substrings, plus Mandarin
/// pinyin hits mapped back onto the matching Chinese characters.
enum SearchHighlight {
    static let background = Color.accentColor.opacity(0.32)

    static func attributed(_ string: String, query: String) -> AttributedString {
        var output = AttributedString(string)
        apply(to: &output, source: string, query: query)
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        NerdSymbolsFont.applyFallback(to: &output, size: size)
        return output
    }

    /// AppKit counterpart used by reusable clipboard table cells.
    static func nsAttributed(
        _ string: String, query: String, font: NSFont, foreground: NSColor = .labelColor
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: foreground]
        )
        let ranges = matchingRanges(source: string, query: query)
        guard !ranges.isEmpty else {
            NerdSymbolsFont.applyFallback(to: output, baseFont: font)
            return output
        }

        let color = NSColor.controlAccentColor.withAlphaComponent(0.32)
        for range in ranges {
            output.addAttribute(.backgroundColor, value: color, range: NSRange(range, in: string))
        }
        NerdSymbolsFont.applyFallback(to: output, baseFont: font)
        return output
    }

    /// Layers a blue background onto existing attributes (e.g. syntax-colored code) without clearing them.
    static func apply(to output: inout AttributedString, source: String, query: String) {
        for range in matchingRanges(source: source, query: query) {
            paint(range, in: source, onto: &output)
        }
    }

    /// Adds search emphasis without rebuilding an AppKit attributed string, preserving every
    /// explicit font and paragraph-layout attribute produced by the Markdown renderer.
    static func applying(to attributed: NSAttributedString, query: String) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: attributed)
        let source = output.string
        let ranges = matchingRanges(source: source, query: query)
        guard !ranges.isEmpty else { return output }

        let color = NSColor.controlAccentColor.withAlphaComponent(0.32)
        for range in ranges {
            output.addAttribute(.backgroundColor, value: color, range: NSRange(range, in: source))
        }
        return output
    }

    private static func matchingRanges(
        source: String, query: String
    ) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !source.isEmpty else { return [] }
        var ranges = literalRanges(source: source, query: needle)
        if Pinyin.queryLooksLatin(needle) {
            ranges.append(contentsOf: Pinyin.matchingSourceRanges(query: needle, text: source))
        }
        return ranges
    }

    private static func literalRanges(source: String, query: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
            let range = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<source.endIndex
            )
        {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func paint(
        _ range: Range<String.Index>, in source: String, onto output: inout AttributedString
    ) {
        guard let lower = AttributedString.Index(range.lowerBound, within: output),
            let upper = AttributedString.Index(range.upperBound, within: output)
        else { return }
        output[lower..<upper].backgroundColor = background
    }
}
