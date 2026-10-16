import Foundation

/// Transport fixtures use documented wire formats and never contact a live provider.
private final class DecisionURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture { var requests: [URLRequest] = []; var status = 200; var data = Data(); var error: URLError? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture()
    static func configure(status: Int = 200, json: String = "{}", error: URLError? = nil) {
        lock.withLock { fixture = Fixture(status: status, data: Data(json.utf8), error: error) }
    }
    static var requests: [URLRequest] { lock.withLock { fixture.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let snapshot = Self.lock.withLock { Self.fixture.requests.append(request); return Self.fixture }
        if let error = snapshot.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: snapshot.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: snapshot.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct LLMClassificationTests {
    @MainActor
    static func settingsTests() {
        let defaults = UserDefaults(suiteName: "Kit.LLMClassificationTests.\(UUID())")!
        precondition(!AppSettings(defaults: defaults).llmClassificationEnabled, "LLM classification must remain opt-in")
        defaults.set("typesafe-key", forKey: "typesafeAPIKey")
        let settings = AppSettings(defaults: defaults)
        settings.llmClassificationEngine = .openAIDecisions
        precondition(settings.llmClassificationConfiguration == nil, "Never use a TypeSafe key for OpenAI")
        settings.llmAPIChannel = .openRouter
        settings.saveLLMAPIKey("router-key")
        let restored = AppSettings(defaults: defaults)
        precondition(restored.llmClassificationEngine == .openAIDecisions && restored.llmAPIChannel == .openRouter
                     && restored.llmAPIKey == "router-key", "The selected route and its key must survive relaunch")
    }

    static func requestTests() throws {
        let routes: [(LLMClassificationEngine, String, String)] = [
            (.typeSafe, "https://api.typesafe.ai/v1/systemone", "jev-latest"),
            (.openAIDecisions, "https://api.openai.com/v1/decisions", "gpt-6-luna"),
        ]
        for (engine, endpoint, model) in routes {
            let config = LLMClassificationConfiguration(engine: engine, channel: .direct, apiKey: " fixture-key ")
            let request = LLMTextClassifier.request(for: " sample ", configuration: config)!
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(request.url?.absoluteString == endpoint && request.httpMethod == "POST"
                         && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
                         "POST to the dedicated Decisions endpoint with the selected route's key")
            precondition(body["model"] as? String == model, "Send the selected decision model")
            if config.usesOpenAISchema {
                let question = (body["questions"] as! [[String: Any]]).first!
                precondition(body["input"] as? String == "sample" && body["state"] == nil
                             && Set((question["choices"] as! [[String: String]]).compactMap { $0["value"] })
                             == ["text", "code", "markdown", "link", "path"], "Send the OpenAI questions schema")
            } else {
                precondition(body["state"] as? String == "sample" && body["input"] == nil,
                             "TypeSafe sends state rather than input")
            }
            precondition(LLMTextClassifier.request(for: " \n ", configuration: config) == nil, "Do not send empty content")
            precondition(LLMTextClassifier.request(for: "text", configuration: LLMClassificationConfiguration(engine: engine, channel: .direct, apiKey: " ")) == nil,
                         "Do not send a request without a credential")
        }
    }

    static func transportTests() async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DecisionURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        for engine in LLMClassificationEngine.allCases {
            let config = LLMClassificationConfiguration(engine: engine, channel: .direct, apiKey: "fixture-key")
            let answer = "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"code\",\"confidence\":0.8}"
            DecisionURLProtocol.configure(json: config.usesOpenAISchema ? "{\"answers\": [\(answer)]}" : "{\"answers\": {\"kind\": \(answer)}}")
            let result = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
            precondition(result?.rawValue == "code" && DecisionURLProtocol.requests.count == 1,
                         "The chosen LLM alone determines the kind")
            let invalid = "{\"name\":\"kind\",\"type\":\"choice\",\"choice\":\"image\",\"confidence\":0.9}"
            DecisionURLProtocol.configure(json: config.usesOpenAISchema ? "{\"answers\": [\(invalid)]}" : "{\"answers\": {\"kind\": \(invalid)}}")
            let rejected = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
            precondition(rejected == nil, "Unsupported kinds leave plain text")
            DecisionURLProtocol.configure(status: 500)
            let failed = await LLMTextClassifier.classify("https://example.com", configuration: config, session: session)
            precondition(failed == nil && DecisionURLProtocol.requests.count == 1,
                         "HTTP errors do not invoke a classifier fallback")
            DecisionURLProtocol.configure(error: URLError(.timedOut))
            let timedOut = await LLMTextClassifier.classify("text", configuration: config, session: session)
            precondition(timedOut == nil, "Timeouts leave plain text")
            DecisionURLProtocol.configure(json: "not JSON")
            let malformed = await LLMTextClassifier.classify("text", configuration: config, session: session)
            precondition(malformed == nil, "Malformed responses leave plain text")
        }
    }

    @MainActor
    static func main() async throws {
        settingsTests()
        try requestTests()
        await transportTests()
        print("LLM classification tests passed: request/response wire format, credentials, route persistence, and failure isolation")
    }
}
