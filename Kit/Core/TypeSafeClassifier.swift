import Foundation

/// Optional cloud refinement of a captured item's kind through the TypeSafe judgment API
/// (docs.typesafe.ai). Local rules stay authoritative for links and on-disk paths, which have
/// objective answers; the API only adjudicates the code/Markdown/prose judgment call where the
/// rule heuristics are weakest (see tools/typesafe-bench).
enum TypeSafeClassifier {
    /// Mirror the local classifier's bounded sample so very large captures never leave the Mac.
    static let sampleLimit = 12_000
    /// Verdicts below this confidence keep the local rule-based kind; the bench's low-confidence
    /// answers were exactly its wrong ones.
    static let minimumConfidence = 0.75

    /// The question only offers these three; a stray link/path/image answer must never re-grade
    /// a text row into a kind with different rendering and actions (the bench saw it happen).
    static let refinableKinds: Set<String> = ["code", "markdown", "text"]

    struct Verdict: Sendable {
        let kind: ClipboardItem.Kind
        let confidence: Double
    }

    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    /// Returns nil on any failure, short input, or low confidence — the caller then simply
    /// keeps the local kind, so network trouble can never lose an item.
    static func refine(_ text: String, apiKey: String) async -> Verdict? {
        let sample = String(text.prefix(sampleLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 4, !apiKey.isEmpty else { return nil }

        // The question wording is a reviewed constant carrying the same semantics as the local
        // rules, minus the kinds those rules already decided before this call runs.
        let question: [String: Any] = [
            "type": "choice",
            "instructions": """
                This string was captured from a developer's clipboard and has already been ruled \
                out as a URL or a disk path. Which single kind is it? Judge the whole string: \
                source code embedded in a Markdown article keeps the article Markdown.
                """,
            "criteria": [
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
            refinableKinds.contains(choice),
            let kind = ClipboardItem.Kind(rawValue: choice),
            let confidence = kindAnswer["confidence"] as? Double
        else { return nil }
        guard confidence >= minimumConfidence else { return nil }
        return Verdict(kind: kind, confidence: confidence)
    }
}
