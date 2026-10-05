import Foundation

/// Mandarin romanization helpers shared by indexed search, resident entries, and highlights.
enum Pinyin {
    struct SearchForms: Sendable {
        let full: String
        let initials: String
    }

    /// UTF-16 offsets belong to the exact source bytes, so canonically equivalent strings
    /// with different encodings never share incompatible highlight positions.
    struct SourceIndex: Sendable {
        let forms: SearchForms
        let sourceRanges: [NSRange]
        let fullEnds: [Int]
        let initialEnds: [Int]

        func matchingRanges(query: String) -> [NSRange] {
            let full = ranges(in: forms.full, ends: fullEnds, query: query)
            return full.isEmpty ? ranges(in: forms.initials, ends: initialEnds, query: query) : full
        }

        private func ranges(in spelling: String, ends: [Int], query: String) -> [NSRange] {
            let spelling = spelling as NSString
            var start = 0
            var result: [NSRange] = []
            while start < spelling.length {
                guard !Task.isCancelled else { return [] }
                let match = spelling.range(of: query, range: NSRange(location: start, length: spelling.length - start))
                guard match.location != NSNotFound else { break }
                let first = syllable(at: match.location, ends: ends)
                let last = syllable(at: NSMaxRange(match) - 1, ends: ends)
                guard sourceRanges.indices.contains(first), sourceRanges.indices.contains(last) else { break }
                result.append(NSRange(location: sourceRanges[first].location,
                                      length: NSMaxRange(sourceRanges[last]) - sourceRanges[first].location))
                start = NSMaxRange(match)
            }
            return result
        }

        private func syllable(at offset: Int, ends: [Int]) -> Int {
            var lower = 0
            var upper = ends.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if ends[middle] <= offset { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
    }

    /// NSCache is thread-safe. Only a cold character conversion holds the lock; completed
    /// source indexes and character hits remain available to independent search workers.
    final class Cache: @unchecked Sendable {
        private final class IndexBox {
            let value: SourceIndex
            init(_ value: SourceIndex) { self.value = value }
        }
        private final class TokenBox {
            let value: String
            init(_ value: String) { self.value = value }
        }
        private let sources = NSCache<NSData, IndexBox>()
        private let characters = NSCache<NSData, TokenBox>()
        private let conversionLock = NSLock()
        private let convert: @Sendable (String) -> String

        init(convert: @escaping @Sendable (String) -> String = Pinyin.romanize) {
            self.convert = convert
            sources.countLimit = 2048
            sources.totalCostLimit = 8 * 1024 * 1024
            characters.countLimit = 4096
        }

        func index(for text: String) -> SourceIndex? {
            guard !Task.isCancelled else { return nil }
            let key = Data(text.utf8) as NSData
            if let hit = sources.object(forKey: key) { return hit.value }
            var full = ""
            var initials = ""
            var sourceRanges: [NSRange] = []
            var fullEnds: [Int] = []
            var initialEnds: [Int] = []
            var sourceOffset = 0
            var fullOffset = 0
            var initialOffset = 0
            var index = text.startIndex
            while index < text.endIndex {
                guard !Task.isCancelled else { return nil }
                let next = text.index(after: index)
                let length = text[index..<next].utf16.count
                if containsHan(text[index]) {
                    guard let syllable = token(for: String(text[index..<next])) else { return nil }
                    if let initial = syllable.first {
                        full += syllable
                        initials.append(initial)
                        fullOffset += syllable.utf16.count
                        initialOffset += String(initial).utf16.count
                        sourceRanges.append(NSRange(location: sourceOffset, length: length))
                        fullEnds.append(fullOffset)
                        initialEnds.append(initialOffset)
                    }
                }
                sourceOffset += length
                index = next
            }
            guard !Task.isCancelled else { return nil }
            let value = SourceIndex(forms: SearchForms(full: full, initials: initials),
                                    sourceRanges: sourceRanges, fullEnds: fullEnds, initialEnds: initialEnds)
            let cost = key.length + full.utf8.count + initials.utf8.count
                + sourceRanges.count * MemoryLayout<NSRange>.stride
                + (fullEnds.count + initialEnds.count) * MemoryLayout<Int>.stride
            sources.setObject(IndexBox(value), forKey: key, cost: cost)
            return value
        }

        private func token(for character: String) -> String? {
            let key = Data(character.utf8) as NSData
            if let hit = characters.object(forKey: key) { return hit.value }
            conversionLock.lock()
            defer { conversionLock.unlock() }
            guard !Task.isCancelled else { return nil }
            if let hit = characters.object(forKey: key) { return hit.value }
            let token = compact(convert(character))
            guard !Task.isCancelled else { return nil }
            characters.setObject(TokenBox(token), forKey: key)
            return token
        }
    }

    private static let cache = Cache()

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
        let query = compact(query)
        guard !query.isEmpty, let index = cache.index(for: text) else { return false }
        return index.forms.full.contains(query) || index.forms.initials.contains(query)
    }

    /// Matching uses cached spelling and UTF-16 positions; bool-only search never allocates ranges.
    static func matchingSourceRanges(query: String, text: String) -> [Range<String.Index>] {
        let query = compact(query)
        guard !query.isEmpty, let index = cache.index(for: text) else { return [] }
        return index.matchingRanges(query: query).compactMap { Range($0, in: text) }
    }

    private static func romanize(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }

    /// Persistent search forms cover Han characters; Latin text already has a literal FTS path.
    static func searchForms(for text: String) -> SearchForms {
        cache.index(for: text)?.forms ?? SearchForms(full: "", initials: "")
    }

    static func containsHan(_ text: String) -> Bool {
        text.contains(where: containsHan)
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
