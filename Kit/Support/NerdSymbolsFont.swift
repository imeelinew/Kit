import AppKit
import CoreText
import SwiftUI

/// Bundled [Symbols Nerd Font Mono](https://www.nerdfonts.com) (v3.5.0) used as a
/// glyph fallback for Powerline / Nerd Font PUA icons. CoreText will not cascade
/// BMP private-use characters to an installed symbols font on its own, so we
/// rewrite runs that the base font cannot draw.
enum NerdSymbolsFont {
    private static let resourceName = "SymbolsNerdFontMono-Regular"
    private static let postScriptName = "SymbolsNFM"
    static let familyName = "Symbols Nerd Font Mono"

    /// Lazily registers the embedded TTF once for this process.
    private static let registration: Bool = {
        let url =
            Bundle.main.url(forResource: resourceName, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "ttf")
        guard let url else { return false }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return ok
    }()

    /// Ensures the embedded font is registered. Safe to call repeatedly.
    static func register() {
        _ = registration
    }

    static func nsFont(ofSize size: CGFloat) -> NSFont? {
        register()
        return NSFont(name: postScriptName, size: size)
    }

    /// Only Nerd Font private-use icons need an explicit cascade. Ordinary text stays on
    /// the system fallback path, without allocating glyph buffers for every character.
    static func privateUseRanges(in plain: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0
        let string = plain as NSString
        for scalar in plain.unicodeScalars {
            switch scalar.value {
            case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
                let range = string.rangeOfComposedCharacterSequence(at: offset)
                if ranges.last != range { ranges.append(range) }
            default: break
            }
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        return ranges
    }

    /// Assigns the symbols font to private-use characters the run / base font cannot render.
    static func applyFallback(to mutable: NSMutableAttributedString, baseFont: NSFont) {
        let ranges = privateUseRanges(in: mutable.string)
        guard !ranges.isEmpty else { return }
        guard let symbols = nsFont(ofSize: baseFont.pointSize) else { return }
        let string = mutable.string as NSString

        let symbolsCT = symbols as CTFont
        for range in ranges {
            let runFont =
                (mutable.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                ?? baseFont
            var characters = [UniChar](repeating: 0, count: range.length)
            string.getCharacters(&characters, range: range)
            var glyphs = [CGGlyph](repeating: 0, count: range.length)
            let baseHasGlyph = CTFontGetGlyphsForCharacters(
                runFont as CTFont, &characters, &glyphs, range.length)
            if !baseHasGlyph {
                var symbolGlyphs = [CGGlyph](repeating: 0, count: range.length)
                if CTFontGetGlyphsForCharacters(
                    symbolsCT, &characters, &symbolGlyphs, range.length)
                {
                    mutable.addAttribute(.font, value: symbols, range: range)
                }
            }
        }
    }

    /// Applies symbols-font runs only where needed, leaving other characters unstyled so
    /// SwiftUI's view-level `.font` still controls normal text.
    static func applyFallback(to attributed: inout AttributedString, size: CGFloat) {
        let plain = String(attributed.characters)
        let ranges = privateUseRanges(in: plain)
        guard !ranges.isEmpty else { return }
        guard nsFont(ofSize: size) != nil else { return }
        let probe = NSFont.systemFont(ofSize: size)

        let nsString = plain as NSString
        let probeCT = probe as CTFont
        for nsRange in ranges {
            var characters = [UniChar](repeating: 0, count: nsRange.length)
            nsString.getCharacters(&characters, range: nsRange)
            var glyphs = [CGGlyph](repeating: 0, count: nsRange.length)
            let hasGlyph = CTFontGetGlyphsForCharacters(
                probeCT, &characters, &glyphs, nsRange.length)
            if !hasGlyph,
                let symbols = nsFont(ofSize: size),
                CTFontGetGlyphsForCharacters(
                    symbols as CTFont, &characters, &glyphs, nsRange.length),
                let swiftRange = Range(nsRange, in: plain),
                let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
                let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
            {
                attributed[lower..<upper].font = Font.custom(familyName, size: size)
            }
        }
    }
}
