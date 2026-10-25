import AppKit

enum IconCache {
    // NSCache synchronizes access, cached images are immutable after insertion
    private final class Cache: @unchecked Sendable {
        let values = NSCache<NSString, NSImage>()
    }

    private static let displayPixel: CGFloat = 48

    private static let cache: Cache = {
        let cache = Cache()
        cache.values.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static func key(for path: String, version: UInt64) -> NSString {
        "\(path)#\(version)" as NSString
    }

    static func cached(forFile path: String, version: UInt64 = 0) -> NSImage? {
        cache.values.object(forKey: key(for: path, version: version))
    }

    private struct Decoded: @unchecked Sendable { let image: NSImage? }

    static func loadAsync(forFile path: String, version: UInt64 = 0) async -> NSImage? {
        if let cached = cached(forFile: path, version: version) { return cached }
        let task = Task.detached(priority: .userInitiated) { () -> Decoded in
            guard !Task.isCancelled else { return Decoded(image: nil) }
            guard FileManager.default.fileExists(atPath: path) else { return Decoded(image: nil) }
            return Decoded(image: icon(forFile: path, version: version))
        }
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : decoded.image
    }

    static func icon(forFile path: String, version: UInt64 = 0) -> NSImage {
        let key = key(for: path, version: version)
        if let cached = cache.values.object(forKey: key) { return cached }
        let (icon, cost) = downsampled(NSWorkspace.shared.icon(forFile: path))
        cache.values.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    private static func downsampled(_ source: NSImage) -> (NSImage, Int) {
        let pixels = Int(displayPixel * 2)
        let fallbackCost = Int(displayPixel * displayPixel * 4)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return (source, fallbackCost) }
        rep.size = NSSize(width: displayPixel, height: displayPixel)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return (source, fallbackCost)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return (image, rep.bytesPerRow * rep.pixelsHigh)
    }
}
