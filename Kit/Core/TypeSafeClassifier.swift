import Foundation

/// Classifies clipboard text independently through TypeSafe's jev model.
enum TypeSafeClassifier {
    static let sampleLimit = 12_000
    static let minConfidence = 0.4
    private static let textKinds: Set<String> = ["code", "markdown", "text", "link", "path"]

    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Failure leaves the capture as plain text; local classification is never used here.
    static func classify(_ text: String, apiKey: String) async -> ClipboardItem.Kind? {
        let sample = sampled(text)
        guard !sample.isEmpty, !apiKey.isEmpty else { return nil }

        let question: [String: Any] = [
            "type": "choice",
            "instructions": """
                This string was captured from a developer's clipboard on macOS. \
                Which single kind is it? Judge the whole string: source code embedded \
                in a Markdown article keeps the article Markdown, and one sentence \
                mentioning a URL, a path, or code terms keeps the sentence plain text. \
                When in doubt between two kinds, answer text.
                """,
            "criteria": [
                "link": """
                    The entire string is exactly one http:// or https:// URL and nothing else. \
                    NOT link: two or more URLs, a bare domain like example.com, other schemes \
                    (ftp:, magnet:, mailto:), a URL wrapped in <angle brackets>, or any surrounding words
                    """,
                "path": """
                    The entire string is a single filesystem path that could exist on this Mac: \
                    an absolute / path, a ~/ path, or a file:// URL, and nothing else. \
                    NOT path: Windows paths like C:\\Users\\..., device URIs, non-filesystem \
                    schemes like ftp:, or paths inside sentences or code
                    """,
                "code": """
                    Source code, shell commands, terminal transcripts, JSON, YAML/TOML/INI config \
                    files, CSV or other tabular data, hex dumps, or a string that is exactly one \
                    fenced ``` code block. NOT code: prose sentences that merely mention code \
                    words, or settings mentioned inside a sentence
                    """,
                "markdown": """
                    A Markdown document: headings, lists, emphasis like **bold**, blockquotes, \
                    tables with a |---| separator row, or inline code — even a short one. \
                    A fenced code block surrounded by headings or prose is a Markdown article, not code
                    """,
                "text": """
                    Plain prose: sentences, notes, emails, chat messages — including prose in any \
                    language that mentions technical terms. Also text: ASCII art, pseudocode and \
                    numbered steps written in plain words, base64 strings, regex patterns, opaque \
                    token strings like JWTs, and tiny fragments of 1–3 characters or a single \
                    unmatched brace
                    """,
            ],
        ]
        let body: [String: Any] = [
            "state": sample, "model": "jev-latest", "questions": ["kind": question]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let answers = root["answers"] as? [String: Any],
            let kindAnswer = answers["kind"] as? [String: Any],
            let choice = kindAnswer["choice"] as? String,
            textKinds.contains(choice),
            let confidence = kindAnswer["confidence"] as? Double,
            confidence >= minConfidence,
            let kind = ClipboardItem.Kind(rawValue: choice)
        else { return nil }
        return kind
    }

    /// Long captures keep the head and the tail: a document whose first half is a
    /// code block would otherwise be judged on code alone and lose its Markdown verdict.
    private static func sampled(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= sampleLimit else { return trimmed }
        let half = sampleLimit / 2
        return trimmed.prefix(half) + "\n[…]\n" + trimmed.suffix(half)
    }
}
