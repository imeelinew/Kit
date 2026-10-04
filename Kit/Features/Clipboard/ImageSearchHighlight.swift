import AppKit
import SwiftUI
import Vision

/// Value-only OCR geometry. Normalized text offsets stay attached to their original image regions,
/// including compatibility glyph expansion and the spaces removed between Chinese characters.
struct ImageTextLayout: Sendable {
    struct Line: Sendable {
        let text: String
        let characterBounds: [CGRect?]
    }

    struct Region: Sendable {
        let range: NSRange
        let line: Int
        let bounds: CGRect
    }

    let text: String
    let regions: [Region]

    init(lines: [Line]) {
        struct Unit {
            let character: Character
            let line: Int
            let bounds: CGRect?
        }
        var units: [Unit] = []
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 { units.append(Unit(character: "\n", line: lineIndex, bounds: nil)) }
            for (index, character) in line.text.enumerated() {
                let bounds = line.characterBounds.indices.contains(index)
                    ? line.characterBounds[index] : nil
                for folded in String(character).precomposedStringWithCompatibilityMapping {
                    units.append(Unit(character: folded, line: lineIndex, bounds: bounds))
                }
            }
        }

        let folded = String(units.map(\.character))
        let removedSpaces = try! NSRegularExpression(pattern: #"(?<=\p{Han})[\t\p{Zs}]+(?=\p{Han})"#)
            .matches(in: folded, range: NSRange(folded.startIndex..., in: folded)).map(\.range)
        let first = units.firstIndex { !$0.character.isWhitespace } ?? units.endIndex
        let last = units.lastIndex { !$0.character.isWhitespace }.map { $0 + 1 } ?? first
        var sourceOffset = 0
        var normalizedOffset = 0
        var normalized = ""
        var mapped: [Region] = []
        for (index, unit) in units.enumerated() {
            let string = String(unit.character)
            let length = string.utf16.count
            defer { sourceOffset += length }
            guard index >= first, index < last,
                !removedSpaces.contains(where: { NSLocationInRange(sourceOffset, $0) })
            else { continue }
            let range = NSRange(location: normalizedOffset, length: length)
            normalized += string
            normalizedOffset += length
            if let bounds = unit.bounds {
                let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                if !clipped.isNull, !clipped.isEmpty {
                    mapped.append(Region(range: range, line: unit.line, bounds: clipped))
                }
            }
        }
        text = normalized
        regions = mapped
    }

    func matchingBounds(query: String) -> [CGRect] {
        let query = ClipboardImageTextRecognition.normalizedText(query)
        let matches = SearchHighlight.matchingRanges(source: text, query: query)
        var boxes: [(line: Int, bounds: CGRect)] = []
        for match in matches {
            let range = NSRange(match, in: text)
            var lines: [Int: CGRect] = [:]
            for region in regions where NSIntersectionRange(region.range, range).length > 0 {
                lines[region.line] = lines[region.line].map { $0.union(region.bounds) } ?? region.bounds
            }
            for line in lines.keys.sorted() {
                var bounds = lines[line]!
                // Literal and pinyin matches may overlap. Paint their union once so the tint
                // stays identical to text highlights instead of getting darker at overlaps.
                boxes.removeAll { box in
                    guard box.line == line, box.bounds.intersects(bounds) else { return false }
                    bounds = bounds.union(box.bounds)
                    return true
                }
                boxes.append((line, bounds))
            }
        }
        return boxes.map(\.bounds)
    }
}

/// Preview-only cache: historical images acquire geometry on demand, without changing the search
/// database or repeating OCR for each query. Quick Look receives the very same matching regions.
@MainActor
final class ImageSearchHighlightPayload {
    let url: URL
    let layout: ImageTextLayout

    private static let cache: NSCache<NSURL, ImageSearchHighlightPayload> = {
        let cache = NSCache<NSURL, ImageSearchHighlightPayload>()
        cache.countLimit = 16
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private static var generation: UInt64 = 0
    nonisolated private static let queue = DispatchQueue(
        label: "com.eli.Kit.image-search-geometry", qos: .userInitiated)

    private init(url: URL, layout: ImageTextLayout) {
        self.url = url
        self.layout = layout
    }

    static func cached(for url: URL) -> ImageSearchHighlightPayload? {
        cache.object(forKey: url as NSURL)
    }

    static func purge() {
        generation &+= 1
        cache.removeAllObjects()
    }

    static func load(
        _ url: URL,
        recognize: @escaping @Sendable (URL) async -> ImageTextLayout? = recognize
    ) async -> ImageSearchHighlightPayload? {
        guard !Task.isCancelled else { return nil }
        if let hit = cached(for: url) { return hit }
        let currentGeneration = generation
        guard let layout = await recognize(url), !Task.isCancelled else { return nil }
        let payload = ImageSearchHighlightPayload(url: url, layout: layout)
        if currentGeneration == generation {
            cache.setObject(payload, forKey: url as NSURL,
                            cost: layout.text.utf8.count + layout.regions.count * MemoryLayout<ImageTextLayout.Region>.stride)
        }
        return payload
    }

    nonisolated static func recognize(_ url: URL) async -> ImageTextLayout? {
        let job = RecognitionJob()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: autoreleasepool { job.run(url) })
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Vision's supported cross-thread cancel is the only concurrent access to the request.
    /// Recognition itself is serial, and cancelled queued jobs never start a Vision request.
    private final class RecognitionJob: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var request: VNRecognizeTextRequest?

        func cancel() {
            lock.withLock {
                cancelled = true
                request?.cancel()
            }
        }

        func run(_ url: URL) -> ImageTextLayout? {
            let request = ClipboardImageTextRecognition.makeRequest()
            guard lock.withLock({
                guard !cancelled else { return false }
                self.request = request
                return true
            }) else { return nil }
            defer { lock.withLock { self.request = nil } }
            do {
                let supported = try request.supportedRecognitionLanguages()
                guard request.recognitionLanguages.allSatisfy(supported.contains) else { return nil }
                try VNImageRequestHandler(url: url).perform([request])
                var lines: [ImageTextLayout.Line] = []
                for observation in request.results ?? [] {
                    guard !lock.withLock({ cancelled }) else { return nil }
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string
                    var bounds: [CGRect?] = []
                    for index in text.indices {
                        guard !lock.withLock({ cancelled }) else { return nil }
                        let range = index..<text.index(after: index)
                        bounds.append((try? candidate.boundingBox(for: range))?.boundingBox)
                    }
                    lines.append(ImageTextLayout.Line(text: text, characterBounds: bounds))
                }
                return ImageTextLayout(lines: lines)
            } catch {
                return nil
            }
        }
    }
}

/// Uses the image's fitted bounds in the local view, with Vision's lower-left origin flipped once.
/// A Canvas adds no hit targets or layout proposals to the image or its hover anchor.
struct ImageSearchHighlightOverlay: View {
    let imageSize: CGSize
    let regions: [CGRect]

    static func imageRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    static func displayRect(_ region: CGRect, imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + region.minX * imageRect.width,
               y: imageRect.minY + (1 - region.maxY) * imageRect.height,
               width: region.width * imageRect.width, height: region.height * imageRect.height)
    }

    var body: some View {
        Canvas { context, size in
            let fitted = Self.imageRect(imageSize: imageSize, in: size)
            var path = Path()
            for region in regions {
                let rect = Self.displayRect(region, imageRect: fitted)
                    .insetBy(dx: -1, dy: -1).intersection(fitted)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
            }
            context.fill(path, with: .color(SearchHighlight.background))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
