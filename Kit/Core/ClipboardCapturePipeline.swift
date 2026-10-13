import AppKit
import Foundation
import ImageIO

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
        // A copied file or folder must retain its file identity when pasted again.
        // Until captures can do that, ignore file URLs and any accompanying text or image data.
        guard snapshot.fileURLs.isEmpty else { return nil }

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

    private static func normalizedImageData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return normalizedPNG(from: source)
    }

    private static func normalizedPNG(from source: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Gatekeeper deciding whether an observed pasteboard change may become a capture.
/// Pure so the privacy rules stay testable without a live pasteboard.
enum ClipboardCapturePolicy {
    /// Marker attached to Kit's own writes so monitoring ignores them.
    static let internalType = NSPasteboard.PasteboardType("com.eli.Kit.internal")

    /// Pasteboard markers password managers, browsers, and the OS put on secret copies.
    static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive"),
    ]

    static func shouldCapture(
        types: [NSPasteboard.PasteboardType],
        sourceBundleID: String?,
        disabledApps: [String]
    ) -> Bool {
        if types.contains(internalType) { return false }
        if !Set(types).isDisjoint(with: sensitiveTypes) { return false }
        if let sourceBundleID, disabledApps.contains(sourceBundleID) { return false }
        return true
    }
}
