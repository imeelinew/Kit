import Foundation

/// Mandarin romanization helpers for clipboard search (Foundation/`CFStringTransform` only).
enum Pinyin {
    struct SearchForms: Sendable {
        let full: String
        let initials: String
    }

    /// True when `query` is ASCII letters/spaces/apostrophes — the shape of typed pinyin.
    static func queryLooksLatin(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var sawLetter = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.value <= 127 else { return false }
                sawLetter = true
            } else if !(CharacterSet.whitespaces.contains(scalar) || scalar == "'") {
                return false
            }
        }
        return sawLetter
    }

    static func matches(query: String, text: String) -> Bool {
        !matchingSourceRanges(query: query, text: text).isEmpty
    }

    /// Source-character ranges whose Mandarin pinyin (full spelling or initials) contains `query`.
    static func matchingSourceRanges(query: String, text: String) -> [Range<String.Index>] {
        let q = compact(query)
        guard !q.isEmpty else { return [] }

        let syllables = syllables(of: text)
        guard !syllables.isEmpty else { return [] }

        var ranges = rangesMatching(
            query: q, syllables: syllables,
            token: \.compact)
        if ranges.isEmpty {
            ranges = rangesMatching(
                query: q, syllables: syllables,
                token: \.initial)
        }
        return ranges
    }

    private static func romanize(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// Persistent search terms contain only Han characters. Latin text already has a literal FTS
    /// path, so excluding it avoids thousands of unnecessary Core Foundation transforms for the
    /// overwhelmingly common English query.
    static func searchForms(for text: String) -> SearchForms {
        var full = ""
        var initials = ""
        for character in text where containsHan(character) {
            let syllable = compact(romanize(String(character)))
            guard !syllable.isEmpty else { continue }
            full += syllable
            initials.append(syllable.first!)
        }
        return SearchForms(full: full, initials: initials)
    }

    static func containsHan(_ text: String) -> Bool {
        text.contains(where: containsHan)
    }

    private struct Syllable {
        let range: Range<String.Index>
        let compact: String
        let initial: String
    }

    private static func syllables(of text: String) -> [Syllable] {
        var result: [Syllable] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let unit = String(text[index..<next])
            guard containsHan(text[index]) else {
                index = next
                continue
            }
            let romanized = compact(romanize(unit))
            if !romanized.isEmpty {
                result.append(
                    Syllable(
                        range: index..<next,
                        compact: romanized,
                        initial: String(romanized.prefix(1))))
            }
            index = next
        }
        return result
    }

    private static func rangesMatching(
        query: String, syllables: [Syllable],
        token: KeyPath<Syllable, String>
    ) -> [Range<String.Index>] {
        var concat = ""
        var map: [Int] = []
        for (syllableIndex, syllable) in syllables.enumerated() {
            let piece = syllable[keyPath: token]
            guard !piece.isEmpty else { continue }
            for _ in piece {
                map.append(syllableIndex)
            }
            concat += piece
        }
        guard !concat.isEmpty, !map.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStart = concat.startIndex
        while searchStart < concat.endIndex,
            let match = concat.range(of: query, range: searchStart..<concat.endIndex)
        {
            let lowerOffset = concat.distance(from: concat.startIndex, to: match.lowerBound)
            let upperOffset = concat.distance(from: concat.startIndex, to: match.upperBound) - 1
            guard map.indices.contains(lowerOffset), map.indices.contains(upperOffset) else { break }
            let start = syllables[map[lowerOffset]].range.lowerBound
            let end = syllables[map[upperOffset]].range.upperBound
            ranges.append(start..<end)
            searchStart = match.upperBound
        }
        return ranges
    }

    private static func compact(_ string: String) -> String {
        string.lowercased().filter(\.isLetter)
    }

    private static func containsHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}

