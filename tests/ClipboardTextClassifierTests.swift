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
        // The fixture lives under the home directory so a "~/" path can point at it.
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("kit-classifier-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let realFile = root.appendingPathComponent("notes.txt")
        try? Data("x".utf8).write(to: realFile)

        // Links: a single http(s) URL, and a URL inside prose is not a link capture.
        expect(ClipboardTextClassifier.kind(for: "https://example.com/a?q=1#frag") == .link,
               "An https URL classifies as a link")
        expect(ClipboardTextClassifier.kind(for: "go to https://example.com now") != .link,
               "A URL inside prose is not a link capture")

        // Paths: must resolve to a real file, including home-relative paths.
        expect(ClipboardTextClassifier.kind(for: realFile.path) == .path,
               "An existing file path classifies as a path")
        let tildePath = "~/" + realFile.path.dropFirst(NSHomeDirectory().count + 1)
        expect(ClipboardTextClassifier.kind(for: tildePath) == .path,
               "Home-relative paths expand and resolve")
        expect(ClipboardTextClassifier.kind(for: "/definitely/not/here.txt") == .text,
               "Nonexistent paths fall back to plain text")

        // Code: JSON objects and declarations.
        expect(ClipboardTextClassifier.kind(for: #"{"kind": "x", "n": 1}"#) == .code,
               "JSON objects classify as code")
        expect(ClipboardTextClassifier.kind(for: "func render() {\n    let view = make()\n}") == .code,
               "Declarations classify as code")

        // Markdown: a representative heading, and inline code inside prose stays markdown.
        expect(ClipboardTextClassifier.kind(for: "# Notes\n\n- a\n- b") == .markdown,
               "Headings classify as markdown")
        expect(ClipboardTextClassifier.kind(for: "Use `return () => {}` carefully") == .markdown,
               "Inline snippets do not count toward the code score")

        // Plain text keeps its shape.
        expect(ClipboardTextClassifier.kind(for: "The quick brown fox jumps over the lazy dog.") == .text,
               "Prose classifies as plain text")

        print("PASS: link/path/code/markdown/plain classification, filesystem paths, prose guards")
    }
}
