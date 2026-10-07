import Foundation

/// Classifies clipboard text independently through TypeSafe's jev model.
enum TypeSafeClassifier {
    static func classify(_ text: String, apiKey: String) async -> ClipboardItem.Kind? {
        await LLMTextClassifier.classify(
            text,
            configuration: LLMClassificationConfiguration(
                engine: .typeSafe, channel: .direct, apiKey: apiKey))
    }
}
