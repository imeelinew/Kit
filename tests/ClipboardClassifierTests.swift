import Foundation
@testable import Kit

enum ClipboardClassifierTests {
    @MainActor
    private static func assertKind(
        _ text: String,
        equals expected: ClipboardItem.Kind,
        label: String
    ) throws {
        let actual = ClipboardTextClassifier.kind(for: text)
        try TestSupport.expect(
            actual == expected,
            "\(label): expected \(expected.rawValue), got \(actual.rawValue)")
    }

    @MainActor
    private static func assertFileURL(
        _ text: String,
        resolvesTo expectedPath: String?,
        label: String
    ) throws {
        let resolved = ClipboardTextClassifier.fileURL(for: text)
        try TestSupport.expect(
            resolved?.standardizedFileURL.path == expectedPath,
            "\(label): \(expectedPath == nil ? "expected no file URL" : "wrong local path"), got \(resolved?.path ?? "nil")")
    }

    @MainActor
    private static func linkCases() throws {
        let cases: [(label: String, text: String, expected: ClipboardItem.Kind)] = [
            ("HTTPS link", "https://example.com/path?q=1", .link),
            ("HTTP link with surrounding whitespace", "  http://example.com  ", .link),
            ("Uppercase HTTP scheme", "HTTP://EXAMPLE.COM/status", .link),
            ("localhost link", "https://localhost:8443/health", .link),
            ("link followed by prose", "Read https://example.com before shipping", .text),
            ("two links with prose", "https://example.com and https://openai.com", .text),
            ("multiline URL", "https://example.com\n/tools", .text),
            ("missing HTTP host", "https://", .text),
            ("space in HTTP authority", "https://example .com/path", .text),
            ("non-HTTP scheme", "ftp://example.com/archive.zip", .text),
        ]
        for item in cases {
            try assertKind(item.text, equals: item.expected, label: item.label)
        }
    }

    @MainActor
    private static func fileCases(in directory: URL) throws {
        let file = directory.appendingPathComponent("name with space.txt")
        let folder = directory.appendingPathComponent("existing folder")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let fileURL = file.standardizedFileURL.absoluteString
        var localhostComponents = URLComponents(
            url: file.standardizedFileURL,
            resolvingAgainstBaseURL: false
        )!
        localhostComponents.host = "localhost"
        let localhostURL = localhostComponents.string!

        var remoteComponents = localhostComponents
        remoteComponents.host = "remote.example"
        let remoteURL = remoteComponents.string!

        let existingCases: [(label: String, text: String, expectedPath: String)] = [
            ("absolute file path", file.path, file.standardizedFileURL.path),
            ("padded absolute file path", " \n\(file.path)\t ", file.standardizedFileURL.path),
            ("file URL", fileURL, file.standardizedFileURL.path),
            ("localhost file URL", localhostURL, file.standardizedFileURL.path),
            ("existing directory", folder.path, folder.standardizedFileURL.path),
            ("home-relative directory", "~/", FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path),
        ]
        for item in existingCases {
            try assertFileURL(item.text, resolvesTo: item.expectedPath, label: item.label)
            try assertKind(item.text, equals: .path, label: item.label)
        }

        let invalidCases: [(label: String, text: String)] = [
            ("nonexistent absolute path",
             directory.appendingPathComponent("missing.txt").path),
            ("remote file URL", remoteURL),
            ("path with embedded newline", "\(file.path)\nrelease notes"),
            ("nonexistent home-relative path", "~/kit-classifier-missing-\(UUID())"),
            ("relative path", "fixtures/missing.txt"),
            ("empty text", "   \n\t"),
        ]
        for item in invalidCases {
            try assertFileURL(item.text, resolvesTo: nil, label: item.label)
        }

        for item in invalidCases {
            try assertKind(item.text, equals: .text, label: item.label)
        }
    }

    @MainActor
    private static func codeCases() throws {
        let cases: [(label: String, text: String)] = [
            ("JSON object",
             "{\n  \"name\": \"Kit\",\n  \"enabled\": true\n}"),
            ("JSON array", "[\"text\", \"code\", \"markdown\"]"),
            ("uppercase SQL", "SELECT name FROM items WHERE pinned = 1;"),
            ("JavaScript declaration",
             "const labels = items.map((item) => item.name);"),
            ("Swift declaration",
             "struct Greeting {\n    let message: String\n}"),
            ("Python function",
             "def greet(name):\n    return f\"Hello, {name}\""),
            ("shebang script",
             "#!/usr/bin/env python3\nprint(\"hello\")"),
            ("HTML markup",
             "<article>\n  <h1>Hello</h1>\n</article>"),
        ]
        for item in cases {
            try assertKind(item.text, equals: .code, label: item.label)
        }

        let negativeCases: [(label: String, text: String)] = [
            ("invalid JSON-like text", "{not valid json}"),
            ("code-like prose", "Use const when declaring a stable value"),
        ]
        for item in negativeCases {
            try assertKind(item.text, equals: .text, label: item.label)
        }
    }

    @MainActor
    private static func markdownCases() throws {
        let article = """
        # Release notes

        Run `npm test` before merging

        ```javascript
        const ready = items.map((item) => item.id)
        ```

        Review the changes afterward
        """
        try assertKind(article, equals: .markdown, label: "Markdown article with source examples")

        let proseWithFence = """
        Configuration is shown below

        ```swift
        let enabled = true
        ```

        Restart Kit afterward
        """
        try assertKind(proseWithFence, equals: .markdown, label: "Markdown prose with fenced source")

        try assertKind(
            "Use `print(\"ready\")` as the example",
            equals: .markdown,
            label: "Markdown prose with inline source")

        let standaloneBackticks = "```swift\nlet answer = 42\n```"
        try assertKind(standaloneBackticks, equals: .code, label: "standalone backtick fence")

        let standaloneTildes = "~~~python\nprint(\"answer\")\n~~~"
        try assertKind(standaloneTildes, equals: .code, label: "standalone tilde fence")

        let unclosedFence = "```swift\nlet answer = 42"
        try assertKind(unclosedFence, equals: .code, label: "standalone unclosed fence")
    }

    @MainActor
    private static func unicodeAndPrefixCases() throws {
        let plainCases: [(label: String, text: String)] = [
            ("Han prose", "测试、剪贴板与搜索"),
            ("decomposed Unicode prose", "Cafe\u{301} déjà vu"),
            ("emoji-only text", "🧪🚀✨"),
        ]
        for item in plainCases {
            try assertKind(item.text, equals: .text, label: item.label)
        }

        let codeAtSampleBoundary =
            String(repeating: "🙂", count: 11_984) + "\nstruct Early {}"
        try TestSupport.expect(
            codeAtSampleBoundary.count == 12_000,
            "Code fixture ends at the classifier sample boundary")
        try assertKind(
            codeAtSampleBoundary,
            equals: .code,
            label: "Unicode prefix with code at the sample boundary")

        let codeAfterSampleBoundary =
            String(repeating: "🙂", count: 12_000) + "\nstruct Late {}"
        try assertKind(
            codeAfterSampleBoundary,
            equals: .text,
            label: "Unicode prefix with code beyond the sample boundary")
    }

    @MainActor
    static func run() async throws {
        try linkCases()
        try codeCases()
        try markdownCases()
        try unicodeAndPrefixCases()
        try await TestSupport.withTemporaryDirectory { directory in
            try fileCases(in: directory)
        }
    }
}
