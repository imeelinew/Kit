import Foundation

/// Run with scripts/test-pinyin.sh. Exercises Mandarin romanization matching: the shape
/// of typed pinyin queries, per-character syllable conversion, and source range mapping.
@main
struct PinyinTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        // Typed-pinyin shape: ASCII letters, spaces, and apostrophes only.
        expect(Pinyin.queryLooksLatin("nihao"), "Plain pinyin looks Latin")
        expect(Pinyin.queryLooksLatin("ni hao"), "Spaces are allowed")
        expect(Pinyin.queryLooksLatin("ni'hao"), "Apostrophes are allowed")
        expect(Pinyin.queryLooksLatin("  nh  "), "Surrounding whitespace is trimmed")
        expect(!Pinyin.queryLooksLatin(""), "Empty is not a query")
        expect(!Pinyin.queryLooksLatin("   "), "Whitespace-only is not a query")
        expect(!Pinyin.queryLooksLatin("你好"), "Han queries do not take the pinyin path")
        expect(!Pinyin.queryLooksLatin("ni3"), "Digits disqualify the pinyin path")
        expect(!Pinyin.queryLooksLatin("ni-hao"), "Hyphens disqualify the pinyin path")
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
        expect(Pinyin.matches(query: "niha", text: "你好"), "Partial syllable suffixes match")
        expect(Pinyin.matches(query: "hao", text: "你好"), "A later syllable matches alone")
        expect(Pinyin.matches(query: "nh", text: "你好"), "Initials match")
        expect(Pinyin.matches(query: "n", text: "你好"), "A single initial matches")
        expect(!Pinyin.matches(query: "nhao", text: "你好"), "Mixed initial/spelling does not match")
        expect(!Pinyin.matches(query: "nihao", text: "hello"), "Latin text never pinyin-matches")
        expect(!Pinyin.matches(query: "", text: "你好"), "Empty queries match nothing")
        expect(
            Pinyin.matches(query: "nihao", text: "打印你好吗"),
            "Pinyin matches inside surrounding Han text")
        expect(!Pinyin.matches(query: "nihao", text: "再见"), "Non-matching Han fails")

        // Source ranges power highlight; they map back onto original characters.
        let thanks = "谢谢你"
        let doubled = Pinyin.matchingSourceRanges(query: "xi", text: thanks)
        expect(doubled.count == 2, "Each occurrence gets its own range")
        expect(String(thanks[doubled[0]]) == "谢" && String(thanks[doubled[1]]) == "谢",
               "Ranges cover exactly the matched characters")
        let whole = Pinyin.matchingSourceRanges(query: "xiexieni", text: thanks)
        expect(whole.count == 1 && whole[0] == thanks.startIndex..<thanks.endIndex,
               "A full-document match spans every character")
        let pair = Pinyin.matchingSourceRanges(query: "xiexie", text: thanks)
        expect(pair.count == 1 && String(thanks[pair[0]]) == "谢谢",
               "A multi-character match spans the exact characters")

        let greeting = "你好"
        let first = Pinyin.matchingSourceRanges(query: "ni", text: greeting)
        expect(first.count == 1 && String(greeting[first[0]]) == "你",
               "A single-character match covers one character")
        let viaInitials = Pinyin.matchingSourceRanges(query: "xn", text: thanks)
        expect(viaInitials.count == 1 && String(thanks[viaInitials[0]]) == "谢你",
               "Initial matches fall back when full spelling misses")

        expect(Pinyin.matchingSourceRanges(query: "hao", text: "hello").isEmpty,
               "No ranges without Han syllables")

        print("PASS: query shape, Han detection, search forms, full/initial matching, source ranges")
    }
}
