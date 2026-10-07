import Foundation

enum LLMClassificationEngine: String, CaseIterable, Identifiable, Sendable {
    case typeSafe
    case openAIDecisions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .typeSafe: "TypeSafe AI"
        case .openAIDecisions: "OpenAI's Decisions API"
        }
    }
}

enum LLMAPIChannel: String, CaseIterable, Identifiable, Sendable {
    case direct
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Official API"
        case .openRouter: "OpenRouter"
        }
    }
}

enum LLMAPIKeyProvider: Hashable, Sendable {
    case typeSafe, openAI, openRouter

    var fieldTitle: String {
        switch self {
        case .typeSafe: "TypeSafe API Key"
        case .openAI: "OpenAI API Key"
        case .openRouter: "OpenRouter API Key"
        }
    }
}

/// A capture snapshots its route and credential; it never tries another classifier.
struct LLMClassificationConfiguration: Equatable, Sendable {
    let engine: LLMClassificationEngine
    let channel: LLMAPIChannel
    let apiKey: String

    var endpoint: URL {
        if channel == .openRouter {
            return URL(string: "https://openrouter.ai/api/alpha/decisions")!
        }
        switch engine {
        case .typeSafe: return URL(string: "https://api.typesafe.ai/v1/systemone")!
        case .openAIDecisions: return URL(string: "https://api.openai.com/v1/decisions")!
        }
    }

    var model: String {
        switch (engine, channel) {
        case (.typeSafe, .direct): "jev-latest"
        case (.typeSafe, .openRouter): "~typesafe/jev-latest"
        case (.openAIDecisions, .direct): "gpt-6-luna"
        case (.openAIDecisions, .openRouter): "openai/gpt-6-luna-decisions"
        }
    }

    var usesOpenAISchema: Bool { engine == .openAIDecisions && channel == .direct }
}

/// Remote classification is entirely separate from ClipboardTextClassifier.
enum LLMTextClassifier {
    static let sampleLimit = 12_000
    static let minConfidence = 0.4
    private static let textKinds: Set<String> = ["code", "markdown", "text", "link", "path"]
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    static func classify(
        _ text: String, configuration: LLMClassificationConfiguration,
        session: URLSession = session
    ) async -> ClipboardItem.Kind? {
        guard !Task.isCancelled, let request = request(for: text, configuration: configuration)
        else { return nil }
        guard
            let (data, response) = try? await session.data(for: request),
            !Task.isCancelled,
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return kind(from: data, configuration: configuration)
    }

    static func request(
        for text: String, configuration: LLMClassificationConfiguration
    ) -> URLRequest? {
        let sample = sampled(text)
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty, !key.isEmpty else { return nil }
        let body: [String: Any]
        if configuration.usesOpenAISchema {
            guard let criteria = question["criteria"] as? [String: String] else { return nil }
            let choices = criteria.keys.sorted().map { value in
                ["value": value, "description": criteria[value]!]
            }
            body = [
                "model": configuration.model,
                "input": sample,
                "questions": [[
                    "type": "choice", "name": "kind",
                    "instructions": question["instructions"]!, "choices": choices,
                ]],
            ]
        } else {
            body = [
                "model": configuration.model, "state": sample,
                "questions": ["kind": question],
            ]
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func kind(
        from data: Data, configuration: LLMClassificationConfiguration
    ) -> ClipboardItem.Kind? {
        let answer: ChoiceAnswer?
        if configuration.usesOpenAISchema {
            let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data)
            answer = response?.answers.first { $0.name == "kind" }
        } else {
            let response = try? JSONDecoder().decode(NamedResponse.self, from: data)
            answer = response?.answers["kind"]
        }
        guard let answer,
            answer.type == "choice",
            let choice = answer.choice, textKinds.contains(choice),
            let confidence = answer.confidence,
            confidence.isFinite, (minConfidence...1).contains(confidence),
            let kind = ClipboardItem.Kind(rawValue: choice)
        else { return nil }
        return kind
    }

    private struct ChoiceAnswer: Decodable {
        let type: String
        let name: String?
        let choice: String?
        let confidence: Double?
    }

    private struct OpenAIResponse: Decodable {
        let answers: [ChoiceAnswer]
    }

    private struct NamedResponse: Decodable {
        let answers: [String: ChoiceAnswer]
    }

    private static var question: [String: Any] {
        [
            "type": "choice",
            "instructions": "Classify the whole clipboard text by its format, not the topics it mentions.",
            "criteria": [
                "link": "A single http:// or https:// URL with nothing else.",
                "path": "A single macOS filesystem path: /..., ~/..., or file://... .",
                "code": "Source code, shell commands, configuration files, structured data, or a single fenced code block.",
                "markdown": "Markdown prose with headings, lists, emphasis, quotes, tables, or inline code. Includes articles containing code blocks.",
                "text": "Plain prose or content that does not match the other categories.",
            ],
        ]
    }

    /// Long captures keep the head and the tail: a document whose first half is a
    /// code block would otherwise be judged on code alone and lose its Markdown verdict.
    static func sampled(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= sampleLimit else { return trimmed }
        let half = sampleLimit / 2
        return trimmed.prefix(half) + "\n[…]\n" + trimmed.suffix(half)
    }
}
