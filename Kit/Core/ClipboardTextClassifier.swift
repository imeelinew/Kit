import Foundation

/// Assign one persistent kind when text is captured: links, paths, Markdown, then plain text.
enum ClipboardTextClassifier {
    private static let sampleLimit = 12_000

    static func kind(for text: String) -> ClipboardItem.Kind {
        if isLink(text) { return .link }
        if fileURL(for: text) != nil { return .path }
        if MarkdownDetection.isMarkdown(text) { return .markdown }
        return .text
    }

    static func preservesTerminalLayout(for item: ClipboardItem, text: String) -> Bool {
        guard item.kind == .text || item.kind == .markdown else { return false }
        let sample = text.prefix(sampleLimit)
        guard sample.contains(where: \.isNewline) else { return false }
        if sample.contains(where: { "─━═".contains($0) })
            && sample.contains(where: { "┌┐└┘├┤┬┼┴╭╮╯╰╋╔╗╚╝╦╬╩".contains($0) }) {
            return true
        }
        guard item.sourceBundleID == "com.superlogical.rex" else { return false }
        return item.kind == .text || sample.split(whereSeparator: \.isNewline).contains {
            $0.drop(while: \.isWhitespace).hasPrefix("• ")
        }
    }

    /// Resolve a single existing local path, including file URLs and home-relative paths.
    /// Checking the filesystem keeps prose that merely looks path-like as text.
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
}
