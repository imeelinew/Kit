import Foundation
import Synchronization
import Vision

/// Search metadata only: recognizing an image never changes its clipboard content or kind.
struct ClipboardImageOCR: Sendable, Hashable {
    enum Status: String, Sendable {
        case complete, empty, failed
    }

    let text: String?
    let status: Status
    let version: Int
    let attempts: Int
}

enum ClipboardImageOCRResult: Sendable {
    case recognized(String)
    case failed
}

enum ClipboardImageTextRecognition {
    /// Increment when recognition or normalization changes require historical images to be indexed again.
    static let version = 1
    static let maxAttempts = 2

    /// Vision's supported-language list is process-stable. The mutex keeps the first lookup single-flight.
    private final class LanguageSupportCache: Sendable {
        private let languages = Mutex<[String]?>(nil)

        func allows(_ requested: [String], load: () throws -> [String]) throws -> Bool {
            try languages.withLock { cached in
                if cached == nil { cached = try load() }
                guard let cached else { return false }
                return requested.allSatisfy(cached.contains)
            }
        }
    }

    private static let languageSupport = LanguageSupportCache()

    /// Use the same recognition settings for indexing and preview text geometry.
    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        return request
    }

    static func recognize(_ url: URL) async -> ClipboardImageOCRResult {
        let task = Task.detached(priority: .utility) {
            autoreleasepool {
                guard !Task.isCancelled else { return ClipboardImageOCRResult.failed }
                let request = makeRequest()
                do {
                    guard try configuredLanguagesAreSupported(request) else { return .failed }
                    try VNImageRequestHandler(url: url).perform([request])
                    guard !Task.isCancelled else { return .failed }
                    let lines = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    return .recognized(normalizedText(lines.joined(separator: "\n")))
                } catch {
                    return .failed
                }
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// `supportedRecognitionLanguages()` does not change for a process, so the first answer is reused.
    private static func configuredLanguagesAreSupported(_ request: VNRecognizeTextRequest) throws -> Bool {
        try languageSupport.allows(request.recognitionLanguages) {
            try request.supportedRecognitionLanguages()
        }
    }

    /// Fold full-width glyphs and OCR-inserted spaces between Han characters, preserving English spaces.
    static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(
                of: "(?<=\\p{Han})[\\t\\p{Zs}]+(?=\\p{Han})", with: "",
                options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
