import Foundation

/// Transport fixtures use documented wire formats and never contact a live provider.
private final class DecisionURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture {
        var requests: [URLRequest] = []
        var status = 200
        var data = Data()
        var error: URLError?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture()

    static func configure(status: Int = 200, json: String = "{}", error: URLError? = nil) {
        lock.withLock {
            fixture = Fixture(status: status, data: Data(json.utf8), error: error)
        }
    }

    static var requests: [URLRequest] { lock.withLock { fixture.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let snapshot = Self.lock.withLock {
            Self.fixture.requests.append(request)
            return Self.fixture
        }
        if let error = snapshot.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: snapshot.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: snapshot.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct LLMClassificationTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func configuration(
        _ engine: LLMClassificationEngine, _ channel: LLMAPIChannel, key: String = "fixture-key"
    ) -> LLMClassificationConfiguration {
        LLMClassificationConfiguration(engine: engine, channel: channel, apiKey: key)
    }

    static func response(_ configuration: LLMClassificationConfiguration, answer: String) -> String {
        if configuration.usesOpenAISchema { return "{\"answers\": [\(answer)]}" }
        return "{\"answers\": {\"kind\": \(answer)}}"
    }

    @MainActor
    static func settingsTests() {
        let suite = "Kit.LLMClassificationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppSettings(defaults: defaults)
        expect(!fresh.llmClassificationEnabled, "LLM classification must remain opt-in")
        expect(fresh.llmClassificationEngine == .typeSafe && fresh.llmAPIChannel == .direct,
               "Existing users must keep the TypeSafe direct route")
        defaults.set(true, forKey: "typesafeAIEnabled")
        defaults.set("old-typesafe-key", forKey: "typesafeAPIKey")
        let settings = AppSettings(defaults: defaults)
        expect(settings.llmClassificationEnabled && settings.llmAPIKey == "old-typesafe-key",
               "The existing enabled flag and TypeSafe key must survive")
        settings.llmClassificationEngine = .openAIDecisions
        expect(settings.llmClassificationConfiguration == nil,
               "Never use a TypeSafe key for OpenAI")
        settings.saveLLMAPIKey("  openai-key\n")
        expect(settings.llmAPIKey == "openai-key", "Trim keys when saving")
        let oldConfiguration = settings.llmClassificationConfiguration
        settings.llmAPIChannel = .openRouter
        expect(settings.llmClassificationConfiguration == nil,
               "Never use an OpenAI key for OpenRouter")
        settings.saveLLMAPIKey("router-key")
        expect(settings.llmClassificationConfiguration != oldConfiguration,
               "An in-flight verdict must be identifiable as stale after a route change")
        settings.llmClassificationEngine = .typeSafe
        expect(settings.llmAPIKey == "router-key", "Both OpenRouter models use the OpenRouter key")
        settings.llmAPIChannel = .direct
        expect(settings.llmAPIKey == "old-typesafe-key", "Keep inactive credentials")
        settings.llmClassificationEngine = .openAIDecisions
        expect(settings.llmAPIKey == "openai-key", "Restore each direct provider's key")
        settings.saveLLMAPIKey(" ")
        expect(settings.llmClassificationConfiguration == nil,
               "Clearing a selected key must leave classification unconfigured")
        settings.llmAPIChannel = .openRouter
        let restored = AppSettings(defaults: defaults)
        expect(restored.llmClassificationEngine == .openAIDecisions
               && restored.llmAPIChannel == .openRouter && restored.llmAPIKey == "router-key",
               "The selected route and its key must survive relaunch")
    }

    static func requestTests() throws {
        let routes: [(LLMClassificationEngine, LLMAPIChannel, String, String)] = [
            (.typeSafe, .direct, "https://api.typesafe.ai/v1/systemone", "jev-latest"),
            (.typeSafe, .openRouter, "https://openrouter.ai/api/alpha/decisions", "~typesafe/jev-latest"),
            (.openAIDecisions, .direct, "https://api.openai.com/v1/decisions", "gpt-6-luna"),
            (.openAIDecisions, .openRouter, "https://openrouter.ai/api/alpha/decisions", "openai/gpt-6-luna-decisions"),
        ]
        for (engine, channel, endpoint, model) in routes {
            let config = configuration(engine, channel, key: " fixture-key ")
            let request = LLMTextClassifier.request(for: " sample ", configuration: config)!
            expect(request.url?.absoluteString == endpoint, "Use the dedicated Decisions endpoint")
            expect(request.httpMethod == "POST", "Classification requests must be POST")
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
                   "Authenticate only with the selected route's key")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            expect(body["model"] as? String == model, "Send the selected decision model")
            if config.usesOpenAISchema {
                expect(body["input"] as? String == "sample" && body["state"] == nil,
                       "OpenAI uses input rather than state")
                let question = (body["questions"] as! [[String: Any]]).first!
                expect(question["name"] as? String == "kind" && question["type"] as? String == "choice",
                       "OpenAI names each question in an array")
                let choices = question["choices"] as! [[String: String]]
                expect(Set(choices.compactMap { $0["value"] }) == ["text", "code", "markdown", "link", "path"],
                       "Offer exactly the supported text kinds")
                expect(choices.allSatisfy { !($0["description"] ?? "").isEmpty }, "Describe each category")
            } else {
                expect(body["state"] as? String == "sample" && body["input"] == nil,
                       "OpenRouter and TypeSafe use state")
                let question = (body["questions"] as! [String: [String: Any]])["kind"]!
                expect(question["type"] as? String == "choice", "Ask a choice question")
                expect(Set((question["criteria"] as! [String: String]).keys) == ["text", "code", "markdown", "link", "path"],
                       "Keep the same categories in the named-question schema")
            }
            expect(LLMTextClassifier.request(for: " \n ", configuration: config) == nil,
                   "Do not send empty content")
            expect(LLMTextClassifier.request(for: "text", configuration: configuration(engine, channel, key: " ")) == nil,
                   "Do not send a request without a credential")
        }
        let longDocument = "# Heading\n" + String(repeating: "中", count: 15_000) + "\nEnd of article"
        let sample = LLMTextClassifier.sampled(longDocument)
        expect(sample.hasPrefix("# Heading") && sample.hasSuffix("End of article"),
               "Long captures retain both document boundaries")
        expect(sample.count == 12_005, "Bound the sample even for Unicode text")
    }

    static func transportTests() async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DecisionURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        for engine in LLMClassificationEngine.allCases {
            for channel in LLMAPIChannel.allCases {
                let config = configuration(engine, channel)
                for kind in ["text", "code", "markdown", "link", "path"] {
                    let answer = "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"\(kind)\",\"confidence\":0.8}"
                    DecisionURLProtocol.configure(json: response(config, answer: answer))
                    let result = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
                    expect(result?.rawValue == kind, "The chosen LLM alone determines the kind")
                    expect(DecisionURLProtocol.requests.count == 1, "Use exactly one selected model")
                }
                let invalidAnswers = [
                    "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"code\",\"confidence\":0.39}",
                    "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"image\",\"confidence\":0.9}",
                    "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"code\",\"confidence\":1.1}",
                    "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"code\",\"confidence\":true}",
                    "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"code\"}",
                    "{\"name\":\"kind\",\"type\":\"refusal\"}",
                    "{\"name\":\"kind\",\"type\":\"score\",\"choice\":\"code\",\"confidence\":0.9}",
                ]
                for answer in invalidAnswers {
                    DecisionURLProtocol.configure(json: response(config, answer: answer))
                    let result = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
                    expect(result == nil, "Invalid or refused verdicts leave plain text")
                    expect(DecisionURLProtocol.requests.count == 1, "Do not fall back to another provider")
                }
                for status in [401, 402, 429, 500] {
                    DecisionURLProtocol.configure(status: status)
                    let result = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
                    expect(result == nil && DecisionURLProtocol.requests.count == 1,
                           "HTTP errors do not invoke a classifier fallback")
                }
                DecisionURLProtocol.configure(error: URLError(.timedOut))
                let timeout = await LLMTextClassifier.classify("text", configuration: config, session: session)
                expect(timeout == nil && DecisionURLProtocol.requests.count == 1, "Timeouts leave plain text")
                DecisionURLProtocol.configure(json: "not JSON")
                let malformed = await LLMTextClassifier.classify("text", configuration: config, session: session)
                expect(malformed == nil, "Malformed responses leave plain text")
                DecisionURLProtocol.configure()
                let missingKey = await LLMTextClassifier.classify("text", configuration: configuration(engine, channel, key: ""), session: session)
                expect(missingKey == nil && DecisionURLProtocol.requests.isEmpty, "Missing keys make no network request")
            }
        }
    }

    @MainActor
    static func main() async throws {
        settingsTests()
        try requestTests()
        await transportTests()
        print("LLM classification tests passed: routes, schemas, credentials, persistence, and failure isolation")
    }
}
