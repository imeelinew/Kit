import Foundation

/// Classifies clipboard text independently through TypeSafe's jev model.
enum TypeSafeClassifier {
    static let sampleLimit = 12_000
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
        let sample = String(text.prefix(sampleLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty, !apiKey.isEmpty else { return nil }

        let question: [String: Any] = [
            "type": "choice",
            "instructions": """
                This string was captured from a developer's clipboard. \
                Which single kind is it? Judge the whole string: \
                source code embedded in a Markdown article keeps the article Markdown.
                """,
            "criteria": [
                "link": "A single URL without surrounding prose",
                "path": "A filesystem path or file URL without surrounding prose",
                "code": "Source code, shell commands, terminal transcripts, JSON, or config files",
                "markdown": "A Markdown document with headings, lists, emphasis, or inline code",
                "text": "Plain prose: sentences, notes, emails, chat messages",
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
            let kind = ClipboardItem.Kind(rawValue: choice)
        else { return nil }
        return kind
    }
}
