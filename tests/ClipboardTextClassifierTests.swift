import Foundation
@testable import Kit

/// Runs with test-clipboard-list.sh, which links the full app including the Markdown parser.
/// The classifier's priority order is link → path → code → markdown → plain text, where paths
/// must exist on disk and code checks ignore snippets embedded in Markdown prose.
enum ClipboardTextClassifierTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func run() {
        // Paths: must resolve to a real file, including file URLs and home-relative paths.
        // The fixture lives under the home directory so a "~/" path can point at it.
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("kit-classifier-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Links: a single http(s) URL, whitespace tolerated only at the edges.
        expect(ClipboardTextClassifier.kind(for: "https://example.com/a?q=1#frag") == .link,
               "An https URL classifies as a link")
        expect(ClipboardTextClassifier.kind(for: "http://kit.local/x") == .link,
               "An http URL with any host classifies as a link")
        expect(ClipboardTextClassifier.kind(for: "  https://example.com  ") == .link,
               "Edge whitespace does not break link detection")
        expect(ClipboardTextClassifier.kind(for: "go to https://example.com now") != .link,
               "A URL inside prose is not a link capture")
        expect(ClipboardTextClassifier.kind(for: "ftp://example.com/file") != .link,
               "Non-http schemes are not links")

        // Paths: must resolve to a real file, including file URLs and home-relative paths.
        let realFile = root.appendingPathComponent("notes.txt")
        try? Data("x".utf8).write(to: realFile)
        expect(ClipboardTextClassifier.fileURL(for: realFile.path) == realFile,
               "Existing absolute paths resolve")
        expect(ClipboardTextClassifier.kind(for: realFile.path) == .path,
               "An existing file path classifies as a path")
        let tildePath = "~/" + realFile.path.dropFirst(NSHomeDirectory().count + 1)
        expect(ClipboardTextClassifier.kind(for: tildePath) == .path,
               "Home-relative paths expand and resolve")
        expect(ClipboardTextClassifier.fileURL(for: realFile.absoluteString) == realFile,
               "file:// URLs resolve to the same location")
        expect(ClipboardTextClassifier.kind(for: "/definitely/not/here.txt") == .text,
               "Nonexistent paths fall back to plain text")

        // Code: shebangs, JSON, standalone fences, declarations, includes, SQL, markup.
        expect(ClipboardTextClassifier.kind(for: "#!/bin/zsh\necho hi") == .code,
               "Shebang lines classify as code")
        expect(ClipboardTextClassifier.kind(for: #"{"kind": "x", "n": 1}"#) == .code,
               "JSON objects classify as code")
        expect(ClipboardTextClassifier.kind(for: "```\nlet x = 1\n```") == .code,
               "A standalone fenced block classifies as code")
        expect(ClipboardTextClassifier.kind(for: "~~~swift\nprint(1)\n~~~") == .code,
               "Tilde fences classify as code")
        expect(ClipboardTextClassifier.kind(for: "func render() {\n    let view = make()\n}") == .code,
               "Declarations classify as code")
        expect(ClipboardTextClassifier.kind(for: "#include <stdio.h>\nint main() {}") == .code,
               "C includes classify as code")
        expect(ClipboardTextClassifier.kind(
            for: "SELECT id, name FROM users WHERE age > 21") == .code,
            "SQL statements classify as code")
        expect(ClipboardTextClassifier.kind(for: "<div class=\"x\">hi</div>") == .code,
            "Markup tags classify as code")
        expect(ClipboardTextClassifier.kind(
            for: "value = {\n  count: 1\n}\nif flag {\n  return value\n}") == .code,
            "Punctuation-dense text scores as code without declarations")

        // Markdown: headings, emphasis, links, and inline code — but code inside prose
        // must not flip the document to the code kind.
        expect(ClipboardTextClassifier.kind(for: "# Notes\n\n- a\n- b") == .markdown,
               "Headings classify as markdown")
        expect(ClipboardTextClassifier.kind(for: "run `make build` first") == .markdown,
               "Inline code spans classify as markdown")
        expect(ClipboardTextClassifier.kind(
            for: "See **this** [guide](https://example.com).") == .markdown,
            "Emphasis and links classify as markdown")
        expect(ClipboardTextClassifier.kind(
            for: "# Guide\n\n```swift\nlet x = 1\n```\n\nDone.") == .markdown,
            "A fenced block inside a Markdown article stays markdown")
        expect(ClipboardTextClassifier.kind(for: "Use `return () => {}` carefully") == .markdown,
               "Inline snippets do not count toward the code score")

        // Plain text keeps its shape.
        expect(ClipboardTextClassifier.kind(for: "The quick brown fox jumps over the lazy dog.") == .text,
               "Prose classifies as plain text")
        expect(ClipboardTextClassifier.kind(for: "hi") == .text,
               "Short strings stay plain text")
        expect(ClipboardTextClassifier.kind(
            for: "1. first\n2. second\n3. third") == .markdown,
            "Numbered lists are markdown, not code")

        print("PASS: link/path/code/markdown/plain classification, filesystem paths, prose guards")
    }
}
