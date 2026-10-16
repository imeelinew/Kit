import Foundation

/// Run with scripts/test-pinyin.sh. Exercises Mandarin romanization matching: the shape
/// of typed pinyin queries, per-character syllable conversion, and source range mapping.
@main
struct PinyinTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() async {
        // Typed-pinyin shape: ASCII letters, spaces, and apostrophes only.
        expect(Pinyin.queryLooksLatin("nihao"), "Plain pinyin looks Latin")
        expect(Pinyin.queryLooksLatin("ni hao"), "Spaces are allowed")
        expect(Pinyin.queryLooksLatin("ni'hao"), "Apostrophes are allowed")
        expect(!Pinyin.queryLooksLatin(""), "Empty is not a query")
        expect(!Pinyin.queryLooksLatin("   "), "Whitespace-only is not a query")
        expect(!Pinyin.queryLooksLatin("你好"), "Han queries do not take the pinyin path")
        expect(!Pinyin.queryLooksLatin("ni3"), "Digits disqualify the pinyin path")
        expect(!Pinyin.queryLooksLatin("café"), "Non-ASCII letters disqualify the pinyin path")

        expect(Pinyin.containsHan("你好"), "Han text is detected")
        expect(Pinyin.containsHan("a好b"), "Han inside Latin is detected")
        expect(!Pinyin.containsHan("abc"), "Latin-only text has no Han")
        expect(!Pinyin.containsHan("カタカナ"), "Katakana is not Han")

        // Persistent search forms cover only the Han characters.
        let hello = Pinyin.searchForms(for: "你好")
        expect(hello.full == "nihao" && hello.initials == "nh", "你好 romanizes to nihao/nh")
        let mixed = Pinyin.searchForms(for: "hi你好world")
        expect(mixed.full == "nihao" && mixed.initials == "nh", "Latin characters are skipped")
        let plain = Pinyin.searchForms(for: "no han here")
        expect(plain.full.isEmpty && plain.initials.isEmpty, "Latin-only text has no forms")
        expect(Pinyin.searchForms(for: "你").full == "ni", "Single characters romanize")

        // Full-spelling and initial matching over concatenated syllables.
        expect(Pinyin.matches(query: "nihao", text: "你好"), "Full pinyin matches")
        expect(Pinyin.matches(query: "nh", text: "你好"), "Initials match")
        expect(
            Pinyin.matches(query: "nihao", text: "打印你好吗"),
            "Pinyin matches inside surrounding Han text")
        expect(!Pinyin.matches(query: "nihao", text: "hello"), "Latin text never pinyin-matches")

        // Source ranges power highlight; they map back onto original characters.
        let thanks = "谢谢你"
        let doubled = Pinyin.matchingSourceRanges(query: "xi", text: thanks)
        expect(doubled.count == 2, "Each occurrence gets its own range")
        expect(String(thanks[doubled[0]]) == "谢" && String(thanks[doubled[1]]) == "谢",
               "Ranges cover exactly the matched characters")
        let pair = Pinyin.matchingSourceRanges(query: "xiexie", text: thanks)
        expect(pair.count == 1 && String(thanks[pair[0]]) == "谢谢",
               "A multi-character match spans the exact characters")
        let viaInitials = Pinyin.matchingSourceRanges(query: "xn", text: thanks)
        expect(viaInitials.count == 1 && String(thanks[viaInitials[0]]) == "谢你",
               "Initial matches fall back when full spelling misses")

        for query in ["NI HAO", "ni'hao", "n h"] {
            expect(Pinyin.matches(query: query, text: "你好"), "Query compaction remains compatible")
        }
        for source in ["é你好🙂谢谢", "e\u{301}你好🙂谢谢"] {
            let ranges = Pinyin.matchingSourceRanges(query: "nihao", text: source)
            expect(ranges.count == 1 && NSRange(ranges[0], in: source) == (source as NSString).range(of: "你好"),
                   "Equivalent Unicode encodings retain their own UTF-16 highlight offsets")
        }
        let separated = "你🙂a好"
        expect(Pinyin.matchingSourceRanges(query: "nihao", text: separated).first == separated.startIndex..<separated.endIndex,
               "Mapped pinyin still spans intervening non-Han characters and emoji")

        print("PASS: query shape, Han detection, search forms, full/initial matching, source ranges")
        print("PASS: exact Unicode offsets, compacted queries and spans across intervening non-Han characters")
    }
}
