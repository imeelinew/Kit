import AppKit
import ImageIO
@testable import Kit

@MainActor
enum ClipboardRowThumbnailTests {
    private static func png(width: Int = 120, height: Int = 80) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func diskBudgetAndInvalidation(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = png()
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let urls = (0..<3).map { directory.appendingPathComponent("budget-\($0).png") }
        for url in urls { try data.write(to: url) }
        let seed = ClipboardRowThumbnailCache()
        let a = seed.ticket(for: urls[0])!, b = seed.ticket(for: urls[1])!
        seed.store(image, for: a)
        seed.store(image, for: b)
        let bytes = try a.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: a.destination.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: b.destination.path)
        let cache = ClipboardRowThumbnailCache(byteLimit: bytes * 2)
        let renewedA = cache.ticket(for: urls[0])!
        precondition(cache.cachedURL(for: renewedA) != nil)
        let c = cache.ticket(for: urls[2])!
        cache.store(image, for: c)
        precondition(FileManager.default.fileExists(atPath: a.destination.path))
        precondition(!FileManager.default.fileExists(atPath: b.destination.path),
                     "The disk budget evicts the least recently read thumbnail")
        let files = try FileManager.default.contentsOfDirectory(
            at: ClipboardRowThumbnailCache.directory(for: urls[0]), includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        precondition(total <= bytes * 2)
        cache.remove(for: urls[0])
        cache.store(image, for: renewedA)
        precondition(!FileManager.default.fileExists(atPath: renewedA.destination.path),
                     "A worker from before deletion cannot repopulate the disk cache")
        let fresh = cache.ticket(for: urls[0])!
        cache.removeAll(in: directory)
        cache.store(image, for: fresh)
        precondition(!FileManager.default.fileExists(atPath: fresh.destination.path),
                     "A history clear invalidates pending disk writes")
        let changed = cache.ticket(for: urls[0])!
        try png(width: 240, height: 160).write(to: urls[0], options: .atomic)
        let replacement = cache.ticket(for: urls[0])!
        precondition(changed.destination != replacement.destination,
                     "A restored or replaced source has a fresh disk identity")
        cache.store(image, for: changed)
        precondition(!FileManager.default.fileExists(atPath: changed.destination.path),
                     "A decode cannot persist against a changed source signature")
        try FileManager.default.removeItem(at: urls[0])
        precondition(cache.ticket(for: urls[0]) == nil,
                     "Cached thumbnails are not authority to display a missing original")
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlinkTicket = cache.ticket(for: urls[1])!
        cache.store(image, for: symlinkTicket)
        try FileManager.default.removeItem(at: ClipboardRowThumbnailCache.directory(for: urls[1]))
        let outsideFile = outside.appendingPathComponent(symlinkTicket.destination.lastPathComponent)
        try data.write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: ClipboardRowThumbnailCache.directory(for: urls[1]), withDestinationURL: outside)
        precondition(cache.cachedURL(for: symlinkTicket) == nil)
        cache.store(image, for: symlinkTicket)
        cache.remove(for: urls[1])
        let outsideData = try Data(contentsOf: outsideFile)
        precondition(outsideData == data,
                     "A cache-directory symlink cannot authorize writes or deletions outside the cache")
        cache.removeAll(in: directory)
        print("PASS: persistent row LRU budget, source deletion, clear and stale-write invalidation")
    }

    private static func loaderAndStoreLifecycle(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("fixture") })
        store.load()
        await store.addImage(png(width: 1200, height: 900), sourceBundleID: nil)
        await store.waitForImageOCR()
        let item = store.items.first!, url = store.imageURL(for: item)!
        let row = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel)
        precondition(row?.size == NSSize(width: 512, height: 384))
        let reader = ClipboardRowThumbnailCache()
        let ticket = reader.ticket(for: url)!
        precondition(reader.cachedURL(for: ticket) != nil, "Rows persist their downsampled bitmap")
        ImageThumbnail.purgeRowMemory()
        let reloaded = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel)
        precondition(reloaded?.size == row?.size && reloaded !== row,
                     "A cold memory cache can reload the persisted row at the same resolution")
        // An interrupted or corrupted cache is disposable; the original remains authoritative.
        try Data("broken".utf8).write(to: ticket.destination, options: .atomic)
        ImageThumbnail.purgeRowMemory()
        let recovered = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel)
        precondition(recovered?.size == row?.size)
        precondition(CGImageSourceCreateWithURL(ticket.destination as CFURL, nil) != nil)
        precondition(store.remove(item))
        precondition(!FileManager.default.fileExists(atPath: ticket.destination.path))
        precondition(ImageThumbnail.cached(url, maxPixel: ImageThumbnail.rowMaxPixel) == nil)
        precondition(store.undoLastDeletion()?.id == item.id)
        let restored = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel)
        precondition(restored?.size == row?.size)
        let restoredTicket = reader.ticket(for: url)!
        precondition(reader.cachedURL(for: restoredTicket) != nil)
        store.clearAll()
        precondition(!FileManager.default.fileExists(atPath: restoredTicket.destination.path))
        precondition(ImageThumbnail.cached(url, maxPixel: ImageThumbnail.rowMaxPixel) == nil)
        let missing = await ImageThumbnail.loadAsync(url, maxPixel: ImageThumbnail.rowMaxPixel)
        precondition(missing == nil)
        await store.addImage(png(), sourceBundleID: nil)
        let stacked = store.items.first!, stackedURL = store.imageURL(for: stacked)!
        _ = await ImageThumbnail.loadAsync(stackedURL, maxPixel: ImageThumbnail.rowMaxPixel)
        let stack = store.createStack(name: "Thumbnail fixture")!
        store.assign(stacked.id, to: stack.id)
        let stackTicket = reader.ticket(for: stackedURL)!
        precondition(store.deleteStack(stack.id))
        precondition(!FileManager.default.fileExists(atPath: stackTicket.destination.path))
        await store.addImage(png(width: 240, height: 160), sourceBundleID: nil)
        let expired = store.items.first!, expiredURL = store.imageURL(for: expired)!
        _ = await ImageThumbnail.loadAsync(expiredURL, maxPixel: ImageThumbnail.rowMaxPixel)
        let expiredTicket = reader.ticket(for: expiredURL)!
        store.maxAge = 1
        precondition(store.enforceLimits(at: expired.createdAt.addingTimeInterval(2)))
        await store.waitForRetentionCleanup()
        precondition(!FileManager.default.fileExists(atPath: expiredTicket.destination.path))
        precondition(ImageThumbnail.cached(expiredURL, maxPixel: ImageThumbnail.rowMaxPixel) == nil)
        print("PASS: capture warmup, cold disk reload, corrupt-cache repair, delete/undo/clear/Stack/retention row lifecycle")
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-row-thumbnail-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try diskBudgetAndInvalidation(in: directory.appendingPathComponent("budget"))
        try await loaderAndStoreLifecycle(in: directory.appendingPathComponent("store"))
    }
}
