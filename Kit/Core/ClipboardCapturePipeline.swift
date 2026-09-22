import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PasteboardSnapshot: Sendable {
    let text: String?
    let imageData: Data?
    let imageIsPNG: Bool
    let fileURLs: [URL]
    let sourceBundleID: String?
    let generation: UInt64
}

enum CapturedClipboardContent: Sendable, Equatable {
    case text(String)
    case image(Data)
}

struct ClipboardCapture: Sendable, Equatable {
    let content: CapturedClipboardContent
    let sourceBundleID: String?
    let generation: UInt64
}

/// Serial normalization boundary for pasteboard snapshots. Conversion order now matches observed
/// change order, while large text accounting and image decoding stay off the main actor.
actor ClipboardCapturePipeline {
    static let maxTextBytes = 8 * 1024 * 1024

    func process(_ snapshot: PasteboardSnapshot) -> ClipboardCapture? {
        // Finder publishes copied files as file URLs and may also expose the filename as plain
        // text. Resolve image files first so WebP, HEIC, JPEG, and other ImageIO formats do not
        // fall through as filename strings.
        for url in snapshot.fileURLs {
            guard !Task.isCancelled else { return nil }
            if let png = Self.normalizedImageFile(at: url) {
                return ClipboardCapture(
                    content: .image(png), sourceBundleID: snapshot.sourceBundleID,
                    generation: snapshot.generation)
            }
        }

        if let data = snapshot.imageData,
            let png = snapshot.imageIsPNG ? data : Self.normalizedImageData(data)
        {
            return ClipboardCapture(
                content: .image(png), sourceBundleID: snapshot.sourceBundleID,
                generation: snapshot.generation)
        }

        if let text = snapshot.text,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= Self.maxTextBytes
        {
            return ClipboardCapture(
                content: .text(text), sourceBundleID: snapshot.sourceBundleID,
                generation: snapshot.generation)
        }
        return nil
    }

    private static func normalizedImageFile(at url: URL) -> Data? {
        guard url.isFileURL,
            let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
            let contentType = values.contentType,
            contentType.conforms(to: .image),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        return normalizedPNG(from: source)
    }

    private static func normalizedImageData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return normalizedPNG(from: source)
    }

    private static func normalizedPNG(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
