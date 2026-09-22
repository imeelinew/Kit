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

    /// Assigns the symbols font to any composed character the run / base font cannot render.
    static func applyFallback(to mutable: NSMutableAttributedString, baseFont: NSFont) {
        guard let symbols = nsFont(ofSize: baseFont.pointSize) else { return }
        let string = mutable.string as NSString
        let length = string.length
        guard length > 0 else { return }

        let symbolsCT = symbols as CTFont
        var location = 0
        while location < length {
            let range = string.rangeOfComposedCharacterSequence(at: location)
            let runFont =
                (mutable.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
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
            location = NSMaxRange(range)
        }
    }

    /// Applies symbols-font runs only where needed, leaving other characters unstyled so
    /// SwiftUI's view-level `.font` still controls normal text.
    static func applyFallback(to attributed: inout AttributedString, size: CGFloat) {
        guard nsFont(ofSize: size) != nil else { return }
        let probe = NSFont.systemFont(ofSize: size)
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return }

        let nsString = plain as NSString
        var location = 0
        let probeCT = probe as CTFont
        while location < nsString.length {
            let nsRange = nsString.rangeOfComposedCharacterSequence(at: location)
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
            location = NSMaxRange(nsRange)
        }
    }
}
