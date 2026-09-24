import Foundation

/// Assign one persistent kind when text is captured: links, paths, code, Markdown, then plain text.
/// Code checks inspect a bounded prefix and ignore snippets embedded in Markdown prose.
enum ClipboardTextClassifier {
    private static let sampleLimit = 12_000
    /// Opening fence, optional info string, body, then a matching closing fence.
    private static let closedFenceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]{0,3}\1[ \t]*$"#
    )
    private static let openFenceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(`{3,}|~{3,})"#
    )
    private static let inlineCodeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?s)(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)"#
    )

    static func kind(for text: String) -> ClipboardItem.Kind {
        if isLink(text) { return .link }
        if fileURL(for: text) != nil { return .path }
        if isCode(text) { return .code }
        if MarkdownAttributedRenderer.isMarkdown(text) { return .markdown }
        return .text
    }

    /// Resolve a single existing local path, including file URLs and home-relative paths.
    /// Checking the filesystem keeps prose and code that merely look path-like as text.
    static func fileURL(for text: String) -> URL? {
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains(where: \.isNewline) else { return nil }

        let url: URL
        if path.hasPrefix("file://") {
            guard let parsed = URL(string: path), parsed.isFileURL,
                parsed.host == nil || parsed.host == "localhost"
            else { return nil }
            url = parsed.standardizedFileURL
        } else {
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whole clipboard string is a single http(s) URL (no surrounding prose).
    private static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else { return false }
        return true
    }

    private static func isCode(_ text: String) -> Bool {
        let sample = String(text.prefix(sampleLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 4 else { return false }

        if sample.hasPrefix("#!") { return true }
        if isJSONObject(sample) { return true }
        if isStandaloneFencedBlock(sample) { return true }

        let body = strippingMarkdownCode(sample)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 4 else { return false }

        let strongSyntax = #"(?m)^\s*(?:(?:import\s+.+(?:\s+from\s+)?[\"'<])|(?:export\s+(?:default\s+)?)|(?:(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*(?::[^=\n]+)?=)|(?:(?:func|function|def|class|struct|enum|protocol|extension|interface|type|fn)\s+[A-Za-z_][A-Za-z0-9_]*)|(?:(?:public|private|protected|internal|open|static|final|pub)\s+(?:class|struct|enum|func|fn|let|var|const)\b)|(?:#include\s*[<\"])|(?:(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER)\b.+\b(?:FROM|INTO|TABLE|SET)\b))"#
        if matches(strongSyntax, in: body) { return true }

        let standaloneCall = #"^\s*[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*\s*\([^\n]*\)\s*;?\s*$"#
        if matches(standaloneCall, in: body) { return true }

        let markup = #"(?s)<[A-Za-z][^>]*>.*</[A-Za-z][^>]*>"#
        if matches(markup, in: body) { return true }

        var score = 0
        if body.contains("{") && body.contains("}") { score += 1 }
        if body.contains("=>") || body.contains("::") || body.contains("?.") { score += 1 }
        if matches(#"(?m);\s*$"#, in: body) { score += 1 }
        if matches(#"\b(?:return|await|throw|guard|switch|case|while|foreach|impl|lambda)\b"#, in: body) {
            score += 1
        }
        if matches(#"(?m)^\s{2,}\S+"#, in: body) && body.contains("\n") { score += 1 }
        if matches(#"\b[A-Za-z_$][A-Za-z0-9_$]*\s*\([^\n)]*\)"#, in: body) {
            score += 1
        }
        return score >= 3
    }

    /// A copy that is only a fenced block (including the fences) is source, not an article.
    private static func isStandaloneFencedBlock(_ sample: String) -> Bool {
        guard sample.hasPrefix("```") || sample.hasPrefix("~~~") else { return false }
        return strippingFencedCodeBlocks(sample)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Inline snippets such as `return () => {}` are prose examples and must not contribute code
    /// punctuation or keywords to the whole-document score.
    private static func strippingMarkdownCode(_ text: String) -> String {
        let withoutFences = strippingFencedCodeBlocks(text)
        guard let inlineCodeRegex else { return withoutFences }
        return inlineCodeRegex.stringByReplacingMatches(
            in: withoutFences,
            range: NSRange(withoutFences.startIndex..., in: withoutFences),
            withTemplate: " "
        )
    }

    /// Drop closed fences, then a trailing unclosed opener (the 12k prefix may cut mid-block).
    private static func strippingFencedCodeBlocks(_ text: String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        var result = text
        if let closedFenceRegex {
            result = closedFenceRegex.stringByReplacingMatches(
                in: result, range: full, withTemplate: "\n")
        }
        if let openFenceRegex {
            let remaining = NSRange(result.startIndex..., in: result)
            if let match = openFenceRegex.firstMatch(in: result, range: remaining),
                let start = Range(match.range, in: result)
            {
                result = String(result[..<start.lowerBound])
            }
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isJSONObject(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[", let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return object is [String: Any] || object is [Any]
    }
}
