import Foundation
import Metal
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

    /// Use the same recognition settings for indexing and preview text geometry.
    static func makeRequest(
        useCPUOnly: Bool = MTLCreateSystemDefaultDevice() == nil
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        // Hosted macOS VMs may have no Metal device. Choose a supported CPU before
        // recognition rather than letting Vision initialize an unavailable accelerator.
        if useCPUOnly, let stages = try? request.supportedComputeStageDevices {
            for (stage, devices) in stages {
                if let cpu = devices.first(where: {
                    if case .cpu = $0 { return true }
                    return false
                }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        return request
    }

    static func recognize(_ url: URL) async -> ClipboardImageOCRResult {
        let task = Task.detached(priority: .utility) {
            autoreleasepool {
                guard !Task.isCancelled else { return ClipboardImageOCRResult.failed }
                let request = makeRequest()
                do {
                    let supported = try request.supportedRecognitionLanguages()
                    guard request.recognitionLanguages.allSatisfy(supported.contains) else {
                        return .failed
                    }
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

    /// Fold full-width glyphs and OCR-inserted spaces between Han characters, preserving English spaces.
    static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(
                of: "(?<=\\p{Han})[\\t\\p{Zs}]+(?=\\p{Han})", with: "",
                options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
