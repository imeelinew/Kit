import AppKit
import Foundation
import ImageIO
@testable import Kit

enum ImageInfrastructureTests {
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var entered = false

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
                enteredContinuation?.resume()
                enteredContinuation = nil
            }
        }

        func waitUntilSuspended() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private static func bitmap(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        patterned: Bool = false
    ) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let data = bitmap.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                if patterned {
                    let value = UInt8(truncatingIfNeeded: x * 37 + y * 19)
                    data[offset] = value
                    data[offset + 1] = 255 - value
                    data[offset + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 13)
                } else {
                    data[offset] = red
                    data[offset + 1] = green
                    data[offset + 2] = blue
                }
                data[offset + 3] = 255
            }
        }
        return bitmap
    }

    private static func image(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        patterned: Bool = false
    ) -> (cgImage: CGImage, png: Data) {
        let bitmap = bitmap(
            width: width, height: height, red: red, green: green, blue: blue,
            patterned: patterned)
        return (bitmap.cgImage!, bitmap.representation(using: .png, properties: [:])!)
    }

    private static func write(_ png: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }

    private static func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values.isRegularFile == true ? values.fileSize ?? 0 : 0
    }

    private static func imagePixelSize(_ image: NSImage) -> CGSize? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect, context: nil, hints: nil)
        else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    private static func close(_ actual: CGFloat, _ expected: CGFloat) -> Bool {
        abs(actual - expected) < 0.000_1
    }

    private static func close(_ actual: CGSize, _ expected: CGSize) -> Bool {
        close(actual.width, expected.width) && close(actual.height, expected.height)
    }

    private static func close(_ actual: CGRect, _ expected: CGRect) -> Bool {
        close(actual.origin.x, expected.origin.x)
            && close(actual.origin.y, expected.origin.y)
            && close(actual.size.width, expected.size.width)
            && close(actual.size.height, expected.size.height)
    }

    @MainActor
    private static func fingerprintFixtures() throws {
        try TestSupport.expect(
            ImageFingerprint.digest(data: Data()) ==
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "The empty SHA256 digest matches the known fixture"
        )
        try TestSupport.expect(
            ImageFingerprint.digest(data: Data("abc".utf8)) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "The abc SHA256 digest matches the known fixture"
        )
    }

    @MainActor
    private static func rowCacheTickets(in root: URL) throws {
        let images = root.appendingPathComponent("tickets", isDirectory: true)
        let source = images.appendingPathComponent("source.png")
        let decoded = image(width: 80, height: 50, red: 240, green: 20, blue: 10)
        try write(decoded.png, to: source)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: source)

        let cache = ClipboardRowThumbnailCache(byteLimit: 8 * 1024 * 1024)
        guard let ticket = cache.ticket(for: source) else {
            throw TestSupport.Failure(description: "A regular source image creates a row ticket")
        }
        try TestSupport.expect(
            ticket.destination.deletingLastPathComponent().standardizedFileURL ==
                ClipboardRowThumbnailCache.directory(for: source).standardizedFileURL,
            "The ticket targets the source sibling row cache directory"
        )
        let sourcePrefix = ImageFingerprint.digest(
            data: Data(source.standardizedFileURL.path.utf8)) + "-"
        try TestSupport.expect(
            ticket.destination.lastPathComponent.hasPrefix(sourcePrefix)
                && ticket.destination.pathExtension == "png",
            "The ticket name binds the normalized source path and PNG extension"
        )

        cache.store(decoded.cgImage, for: ticket)
        guard let cached = cache.cachedURL(for: ticket) else {
            throw TestSupport.Failure(description: "A stored row image is visible through its ticket")
        }
        try TestSupport.expect(cached == ticket.destination, "cachedURL returns the ticket destination")
        let cachedSize = try fileSize(cached)
        try TestSupport.expect(cachedSize > 0, "The cached row image exists on disk")
        try TestSupport.expect(
            ImageThumbnail.pixelSize(of: cached) == CGSize(width: 80, height: 50),
            "The cached row image contains a decodable PNG payload"
        )

        try FileManager.default.removeItem(at: cached)
        try TestSupport.expect(
            cache.cachedURL(for: ticket) == nil,
            "A missing cached file invalidates cachedURL"
        )

        let missing = images.appendingPathComponent("missing.png")
        try TestSupport.expect(
            cache.ticket(for: missing) == nil,
            "A missing source cannot obtain a row ticket"
        )
    }

    @MainActor
    private static func rowCacheMutationAndRemoval(in root: URL) throws {
        let images = root.appendingPathComponent("mutation", isDirectory: true)
        let source = images.appendingPathComponent("mutable.png")
        let first = image(width: 90, height: 60, red: 20, green: 30, blue: 220)
        let second = image(
            width: 95, height: 65, red: 220, green: 180, blue: 10, patterned: true)
        try write(first.png, to: source)
        let initialDate = Date(timeIntervalSince1970: 1_700_100_000)
        try setModificationDate(initialDate, for: source)

        let cache = ClipboardRowThumbnailCache(byteLimit: 8 * 1024 * 1024)
        guard let firstTicket = cache.ticket(for: source) else {
            throw TestSupport.Failure(description: "The initial source creates a ticket")
        }
        cache.store(first.cgImage, for: firstTicket)
        try TestSupport.expect(
            cache.cachedURL(for: firstTicket) != nil,
            "The initial ticket stores its row image"
        )

        try write(second.png, to: source)
        try setModificationDate(initialDate.addingTimeInterval(3_600), for: source)
        guard let secondTicket = cache.ticket(for: source) else {
            throw TestSupport.Failure(description: "The mutated source creates a new ticket")
        }
        try TestSupport.expect(
            secondTicket.signature != firstTicket.signature
                && secondTicket.destination != firstTicket.destination,
            "Source metadata changes produce a new signature and destination"
        )
        cache.store(second.cgImage, for: secondTicket)
        try TestSupport.expect(
            cache.cachedURL(for: firstTicket) == nil,
            "Storing a mutated version removes the superseded row image"
        )
        try TestSupport.expect(
            cache.cachedURL(for: secondTicket) == secondTicket.destination,
            "The current source signature serves the replacement row image"
        )

        cache.remove(for: source)
        try TestSupport.expect(
            cache.cachedURL(for: secondTicket) == nil,
            "Removing one source invalidates its current ticket"
        )
        try TestSupport.expect(
            FileManager.default.fileExists(atPath: source.path),
            "Removing cached rows leaves the source image untouched"
        )

        guard let freshTicket = cache.ticket(for: source) else {
            throw TestSupport.Failure(description: "The retained source creates a fresh ticket after removal")
        }
        try TestSupport.expect(
            freshTicket.generation > secondTicket.generation,
            "remove advances the cache generation so the prior ticket stays invalid"
        )
        cache.store(second.cgImage, for: freshTicket)
        try TestSupport.expect(
            cache.cachedURL(for: freshTicket) == freshTicket.destination,
            "A fresh ticket after remove can repopulate its row image"
        )
        try TestSupport.expect(
            cache.cachedURL(for: secondTicket) == nil,
            "A ticket from before remove cannot read the replacement row image"
        )
        cache.removeAll(in: images)
        try TestSupport.expect(
            cache.cachedURL(for: freshTicket) == nil,
            "removeAll invalidates every ticket for the images directory"
        )
        try TestSupport.expect(
            !FileManager.default.fileExists(
                atPath: ClipboardRowThumbnailCache.directory(for: source).path),
            "removeAll deletes the row cache directory"
        )
    }

    @MainActor
    private static func rowCacheSymlinkDefense(in root: URL) throws {
        let images = root.appendingPathComponent("symlinks", isDirectory: true)
        let source = images.appendingPathComponent("source.png")
        let external = root.appendingPathComponent("external", isDirectory: true)
        let externalTarget = external.appendingPathComponent("target.png")
        let decoded = image(width: 70, height: 40, red: 40, green: 160, blue: 90)
        try write(decoded.png, to: source)
        try write(decoded.png, to: externalTarget)

        let cache = ClipboardRowThumbnailCache(byteLimit: 8 * 1024 * 1024)
        guard let ticket = cache.ticket(for: source) else {
            throw TestSupport.Failure(description: "The symlink fixture source creates a ticket")
        }
        cache.store(decoded.cgImage, for: ticket)
        try FileManager.default.removeItem(at: ticket.destination)
        try FileManager.default.createSymbolicLink(
            at: ticket.destination, withDestinationURL: externalTarget)
        try TestSupport.expect(
            cache.cachedURL(for: ticket) == nil,
            "A symlinked cached row image is rejected"
        )

        let sourceLink = images.appendingPathComponent("source-link.png")
        try FileManager.default.createSymbolicLink(
            at: sourceLink, withDestinationURL: source)
        try TestSupport.expect(
            cache.ticket(for: sourceLink) == nil,
            "A symlinked source image cannot obtain a row ticket"
        )

        let linkedImages = root.appendingPathComponent("linked-cache", isDirectory: true)
        let linkedSource = linkedImages.appendingPathComponent("source.png")
        try write(decoded.png, to: linkedSource)
        let externalCache = root.appendingPathComponent("external-cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalCache, withIntermediateDirectories: true)
        let cacheDirectory = ClipboardRowThumbnailCache.directory(for: linkedSource)
        try FileManager.default.createSymbolicLink(
            at: cacheDirectory, withDestinationURL: externalCache)
        guard let linkedTicket = cache.ticket(for: linkedSource) else {
            throw TestSupport.Failure(description: "The linked cache source creates a ticket")
        }
        cache.store(decoded.cgImage, for: linkedTicket)
        let externalCacheContents = try FileManager.default.contentsOfDirectory(
            at: externalCache, includingPropertiesForKeys: nil)
        try TestSupport.expect(
            externalCacheContents.isEmpty,
            "A symlinked row cache directory receives no writes"
        )
    }

    @MainActor
    private static func rowCacheByteBound(in root: URL) throws {
        let images = root.appendingPathComponent("bytes", isDirectory: true)
        let sourceA = images.appendingPathComponent("a.png")
        let sourceB = images.appendingPathComponent("b.png")
        let sourceC = images.appendingPathComponent("c.png")
        let a = image(
            width: 160, height: 110, red: 230, green: 20, blue: 30, patterned: true)
        let b = image(
            width: 150, height: 120, red: 30, green: 220, blue: 40, patterned: true)
        let c = image(width: 80, height: 80, red: 50, green: 60, blue: 230)
        try write(a.png, to: sourceA)
        try write(b.png, to: sourceB)
        try write(c.png, to: sourceC)

        let measurement = ClipboardRowThumbnailCache(byteLimit: 16 * 1024 * 1024)
        guard let ticketA = measurement.ticket(for: sourceA),
              let ticketB = measurement.ticket(for: sourceB),
              let ticketC = measurement.ticket(for: sourceC)
        else {
            throw TestSupport.Failure(description: "The byte bound sources create row tickets")
        }
        measurement.store(a.cgImage, for: ticketA)
        measurement.store(b.cgImage, for: ticketB)
        guard let measuredA = measurement.cachedURL(for: ticketA),
              let measuredB = measurement.cachedURL(for: ticketB)
        else {
            throw TestSupport.Failure(description: "The measurement cache stores both row images")
        }
        let sizeA = try fileSize(measuredA)
        let sizeB = try fileSize(measuredB)
        try TestSupport.expect(sizeA > 0 && sizeB > 0, "Both measured row images contain bytes")
        measurement.removeAll(in: images)

        let bounded = ClipboardRowThumbnailCache(byteLimit: sizeA + sizeB - 1)
        bounded.store(a.cgImage, for: ticketA)
        try TestSupport.expect(
            bounded.cachedURL(for: ticketA) != nil,
            "The bounded cache stores an individually eligible row image"
        )
        bounded.store(b.cgImage, for: ticketB)
        try TestSupport.expect(
            bounded.cachedURL(for: ticketA) == nil,
            "Adding a row image beyond the byte bound evicts the least recently used entry"
        )
        try TestSupport.expect(
            bounded.cachedURL(for: ticketB) == ticketB.destination,
            "The newly stored row image survives the size eviction"
        )

        let tiny = ClipboardRowThumbnailCache(byteLimit: 1)
        tiny.store(c.cgImage, for: ticketC)
        try TestSupport.expect(
            tiny.cachedURL(for: ticketC) == nil,
            "An encoded row image larger than the cache bound is rejected"
        )
    }

    @MainActor
    private static func thumbnailBehavior(in root: URL) async throws {
        let directory = root.appendingPathComponent("thumbnails", isDirectory: true)
        let source = directory.appendingPathComponent("large.png")
        let malformed = directory.appendingPathComponent("malformed.png")
        let other = directory.appendingPathComponent("other.png")
        defer {
            ImageThumbnail.removeCachedImage(for: source)
            ImageThumbnail.removeCachedImage(for: malformed)
            ImageThumbnail.removeCachedImage(for: other)
        }

        let large = image(width: 1_200, height: 600, red: 210, green: 60, blue: 40)
        try write(large.png, to: source)
        try TestSupport.expect(
            ImageThumbnail.pixelSize(of: source) == CGSize(width: 1_200, height: 600),
            "pixelSize reads dimensions from image metadata"
        )

        guard let first = await ImageThumbnail.loadAsync(source, maxPixel: 300) else {
            throw TestSupport.Failure(description: "A valid image loads asynchronously")
        }
        try TestSupport.expect(
            imagePixelSize(first).map { close($0, CGSize(width: 300, height: 150)) } == true,
            "loadAsync downsamples the longest image edge to maxPixel"
        )
        try TestSupport.expect(
            ImageThumbnail.cached(source, maxPixel: 300) === first,
            "A decoded thumbnail enters the bounded memory cache"
        )
        let otherImage = image(width: 80, height: 40, red: 10, green: 20, blue: 30)
        try write(otherImage.png, to: other)
        guard let kept = await ImageThumbnail.loadAsync(other, maxPixel: 40) else {
            throw TestSupport.Failure(description: "A second image loads asynchronously")
        }

        let replacement = image(width: 900, height: 900, red: 20, green: 200, blue: 80)
        try write(replacement.png, to: source)
        ImageThumbnail.removeCachedImage(for: source)
        try TestSupport.expect(
            ImageThumbnail.cached(source, maxPixel: 300) == nil,
            "removeCachedImage invalidates the memory cache entry"
        )
        try TestSupport.expect(
            ImageThumbnail.cached(other, maxPixel: 40) === kept,
            "Removing one image leaves other memory thumbnails in place"
        )
        guard let reloaded = await ImageThumbnail.loadAsync(source, maxPixel: 150) else {
            throw TestSupport.Failure(description: "The replacement image loads after invalidation")
        }
        try TestSupport.expect(
            imagePixelSize(reloaded).map { close($0, CGSize(width: 150, height: 150)) } == true,
            "The replacement image decodes with the requested cache key size"
        )

        try write(Data("not an image".utf8), to: malformed)
        try TestSupport.expect(
            ImageThumbnail.pixelSize(of: malformed) == nil,
            "Malformed image metadata has no pixel size"
        )
        let malformedResult = await ImageThumbnail.loadAsync(malformed, maxPixel: 128)
        try TestSupport.expect(
            malformedResult == nil,
            "Malformed image bytes fail asynchronous decoding"
        )
        try TestSupport.expect(
            ImageThumbnail.cached(malformed, maxPixel: 128) == nil,
            "A malformed image never enters the memory cache"
        )
    }

    @MainActor
    private static func previewDetailsDefaults() throws {
        let details = ClipboardPreviewPayload.Details()
        try TestSupport.expect(
            details.contentState == .loading
                && details.contentState != .unavailablePreview
                && details.fileAvailability.isEmpty,
            "New preview details start loading without reporting a failure"
        )
    }

    @MainActor
    private static func fileBackedPreviewLifecycle(in root: URL) async throws {
        let storeDirectory = root.appendingPathComponent("preview-store", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("preview-external", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("changing.png")
        let store = ClipboardStore(
            directory: storeDirectory, maintenanceInterval: 86_400,
            recognizeImage: { _ in .failed })
        store.setImageTextSearchEnabled(false)

        ClipboardPreviewPayload.purge()
        defer {
            ClipboardPreviewPayload.purge()
            ImageThumbnail.removeCachedImage(for: source)
        }

        let first = image(width: 48, height: 32, red: 210, green: 40, blue: 30)
        try write(first.png, to: source)
        guard let item = store.addFiles([source], sourceBundleID: nil) else {
            throw TestSupport.Failure(description: "The external PNG becomes a file-backed history item")
        }
        let itemID = item.id
        await store.waitForImageOCR()

        // OCR persistence reloads the row from SQLite, so lifecycle comparisons start here
        guard let baselineItem = store.item(id: itemID) else {
            throw TestSupport.Failure(description: "The inserted history item remains after OCR setup")
        }
        let copiedAt = baselineItem.lastCopiedAt
        let copyCount = baselineItem.copyCount
        let expectedPath = source.standardizedFileURL
        try TestSupport.expect(
            baselineItem.kind == .file && baselineItem.hasImagePreview,
            "The external PNG is classified as an image item")
        try TestSupport.expect(
            !expectedPath.path.hasPrefix(storeDirectory.standardizedFileURL.path + "/"),
            "The image fixture lives outside the store-owned images directory"
        )

        let firstPayload = await ClipboardPreviewPayload.load(
            for: item, imageURL: source, store: store)
        guard let firstImage = firstPayload.image else {
            throw TestSupport.Failure(description: "The initial file-backed preview has an image")
        }
        try TestSupport.expect(
            firstPayload.details.pixelSize == CGSize(width: 48, height: 32),
            "The initial preview reports the source PNG pixel dimensions"
        )
        try TestSupport.expect(
            imagePixelSize(firstImage).map { close($0, CGSize(width: 48, height: 32)) } == true,
            "The initial preview image contains the source PNG pixels"
        )
        try TestSupport.expect(
            firstPayload.details.fileBytes == first.png.count,
            "The initial preview reports the source PNG byte count"
        )
        try TestSupport.expect(
            firstPayload.details.contentState == .ready
                && firstPayload.details.fileAvailability == [.available]
                && firstPayload.availableFileCount == 1
                && !firstPayload.requiresFilePermission,
            "A decodable file-backed PNG is ready and available for copying"
        )
        try TestSupport.expect(
            firstPayload.matches(item) && ClipboardPreviewPayload.cached(for: item) === firstPayload,
            "The initial complete payload enters the current preview cache"
        )

        let replacement = image(width: 73, height: 29, red: 30, green: 120, blue: 220)
        try write(replacement.png, to: source)
        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "An atomic replacement at the same path advances the file version"
        )
        try TestSupport.expect(
            !firstPayload.matches(item) && ClipboardPreviewPayload.cached(for: item) == nil,
            "The pre-replacement payload no longer matches the source path"
        )

        let replacementPayload = await ClipboardPreviewPayload.load(
            for: item, imageURL: source, store: store)
        guard let replacementImage = replacementPayload.image else {
            throw TestSupport.Failure(description: "The replacement preview has an image")
        }
        try TestSupport.expect(
            replacementPayload !== firstPayload,
            "The replacement source produces a new preview payload"
        )
        try TestSupport.expect(
            replacementPayload.details.pixelSize == CGSize(width: 73, height: 29),
            "The replacement preview reports the new source pixel dimensions"
        )
        try TestSupport.expect(
            imagePixelSize(replacementImage).map {
                close($0, CGSize(width: 73, height: 29))
            } == true,
            "The replacement preview image contains the new source pixels"
        )
        try TestSupport.expect(
            replacementPayload.details.fileBytes == replacement.png.count,
            "The replacement preview reports the replacement PNG byte count"
        )
        try TestSupport.expect(
            replacementPayload.details.contentState == .ready
                && replacementPayload.details.fileAvailability == [.available]
                && replacementPayload.availableFileCount == 1,
            "A replaced file-backed PNG restores a ready copyable preview"
        )

        try FileManager.default.removeItem(at: source)
        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "Deleting the source advances the file version"
        )
        try TestSupport.expect(
            !replacementPayload.matches(item)
                && ClipboardPreviewPayload.cached(for: item) == nil,
            "The replacement payload no longer matches after source deletion"
        )

        let missingPayload = await ClipboardPreviewPayload.load(
            for: item, imageURL: source, store: store)
        try TestSupport.expect(
            missingPayload.image == nil
                && missingPayload.details.pixelSize == nil
                && missingPayload.details.fileBytes == nil,
            "A deleted source produces no stale preview image or metadata"
        )
        try TestSupport.expect(
            missingPayload.details.contentState == .notFound
                && missingPayload.details.fileAvailability == [.missing]
                && missingPayload.availableFileCount == 0
                && !missingPayload.requiresFilePermission,
            "A deleted file-backed PNG reports not found with no copyable file"
        )

        let restored = image(width: 36, height: 54, red: 180, green: 30, blue: 160)
        try write(restored.png, to: source)
        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "Recreating the source at the same path advances the file version"
        )
        try TestSupport.expect(
            !missingPayload.matches(item) && ClipboardPreviewPayload.cached(for: item) == nil,
            "The missing-source payload no longer matches after recreation"
        )

        let restoredPayload = await ClipboardPreviewPayload.load(
            for: item, imageURL: source, store: store)
        guard let restoredImage = restoredPayload.image else {
            throw TestSupport.Failure(description: "The recreated preview has an image")
        }
        try TestSupport.expect(
            restoredPayload.details.pixelSize == CGSize(width: 36, height: 54)
                && imagePixelSize(restoredImage).map {
                    close($0, CGSize(width: 36, height: 54))
                } == true,
            "The recreated source restores the current preview pixels"
        )
        try TestSupport.expect(
            restoredPayload.details.fileBytes == restored.png.count,
            "The recreated source restores the current preview byte count"
        )
        try TestSupport.expect(
            restoredPayload.details.contentState == .ready
                && restoredPayload.details.fileAvailability == [.available]
                && restoredPayload.availableFileCount == 1,
            "The recreated file-backed PNG restores a ready copyable preview"
        )

        guard let storedItem = store.item(id: itemID) else {
            throw TestSupport.Failure(description: "The original history item remains after source changes")
        }
        try TestSupport.expect(
            storedItem.id == itemID && storedItem.lastCopiedAt == copiedAt
                && storedItem.copyCount == copyCount,
            "Source replacement and deletion do not recopy or replace the history item"
        )
        try TestSupport.expect(
            storedItem.fileURLs == [expectedPath],
            "The history keeps the original standardized source path"
        )
    }

    @MainActor
    private static func unavailableImagePreviewStillCopies(in root: URL) async throws {
        let storeDirectory = root.appendingPathComponent("bad-image-store", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("bad-image-external", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("bad.png")
        let store = ClipboardStore(
            directory: storeDirectory, maintenanceInterval: 86_400,
            recognizeImage: { _ in .failed })
        store.setImageTextSearchEnabled(false)
        ClipboardPreviewPayload.purge()
        defer { ClipboardPreviewPayload.purge() }

        try write(Data("real bytes that are not a PNG image".utf8), to: source)
        guard let item = store.addFiles([source], sourceBundleID: nil) else {
            throw TestSupport.Failure(description: "The malformed PNG becomes a file-backed history item")
        }
        await store.waitForImageOCR()

        let payload = await ClipboardPreviewPayload.load(
            for: item, imageURL: source, store: store)
        try TestSupport.expect(
            item.kind == .file && item.hasImagePreview && payload.image == nil
                && payload.details.contentState == .unavailablePreview,
            "Readable non-PNG bytes report an unavailable image preview"
        )
        try TestSupport.expect(
            payload.details.fileAvailability == [.available]
                && payload.availableFileCount == 1
                && !payload.requiresFilePermission,
            "A preview decode failure does not mark the readable source file unavailable"
        )

        guard let historical = store.item(id: item.id),
              let lease = await ClipboardFileAccess.acquire(
                historical, store: store, interactive: false)
        else {
            throw TestSupport.Failure(
                description: "The malformed image source remains available for copying")
        }
        try TestSupport.expect(
            lease.urls.map { ($0 as URL).standardizedFileURL } == [source.standardizedFileURL],
            "A malformed preview can still lease its readable source file"
        )
    }

    private static func characterBounds(
        count: Int, values: [Int: CGRect]
    ) -> [CGRect?] {
        (0..<count).map { values[$0] }
    }

    @MainActor
    private static func layoutNormalization() throws {
        let source = "  Ａﬁ 中　文 English  "
        let line = ImageTextLayout.Line(
            text: source,
            characterBounds: characterBounds(
                count: source.count,
                values: [
                    2: CGRect(x: -0.2, y: 0.1, width: 0.3, height: 0.4),
                    3: CGRect(x: 0.8, y: 0.9, width: 0.5, height: 0.3),
                    5: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                    7: CGRect(x: 0.3, y: 0.2, width: 0.1, height: 0.1),
                ]
            )
        )
        let layout = ImageTextLayout(lines: [line])
        try TestSupport.expect(
            layout.text == "Afi 中文 English",
            "OCR layout folds compatibility glyphs, removes Han-adjacent spaces, and trims edges"
        )
        try TestSupport.expect(
            layout.regions.map(\.range) == [
                NSRange(location: 0, length: 1),
                NSRange(location: 1, length: 1),
                NSRange(location: 2, length: 1),
                NSRange(location: 4, length: 1),
                NSRange(location: 5, length: 1),
            ],
            "Character ranges follow the normalized UTF16 offsets"
        )
        try TestSupport.expect(
            layout.regions.map(\.line) == [0, 0, 0, 0, 0],
            "Every normalized glyph retains its OCR source line"
        )
        let clippedA = CGRect(x: 0, y: 0.1, width: 0.1, height: 0.4)
        let clippedLigature = CGRect(x: 0.8, y: 0.9, width: 0.2, height: 0.1)
        try TestSupport.expect(
            close(layout.regions[0].bounds, clippedA)
                && close(layout.regions[1].bounds, clippedLigature)
                && close(layout.regions[2].bounds, clippedLigature),
            "Clipped OCR bounds are shared by every compatibility-expanded character"
        )
        try TestSupport.expect(
            close(layout.regions[3].bounds, CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))
                && close(layout.regions[4].bounds, CGRect(x: 0.3, y: 0.2, width: 0.1, height: 0.1)),
            "Han character ranges keep their individual clipped regions"
        )
    }

    @MainActor
    private static func layoutMatches() throws {
        let firstText = "甲 甲 x甲"
        let firstBounds: [Int: CGRect] = [
            0: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1),
            2: CGRect(x: 0.3, y: 0.1, width: 0.1, height: 0.1),
            5: CGRect(x: 0.8, y: 0.1, width: 0.1, height: 0.1),
        ]
        let secondBounds = CGRect(x: 0.4, y: 0.6, width: 0.1, height: 0.1)
        let layout = ImageTextLayout(lines: [
            .init(
                text: firstText,
                characterBounds: characterBounds(count: firstText.count, values: firstBounds)),
            .init(
                text: "乙",
                characterBounds: characterBounds(count: 1, values: [0: secondBounds])),
        ])

        try TestSupport.expect(
            layout.text == "甲甲 x甲\n乙",
            "Multi-line layout retains one normalized newline"
        )
        let repeated = layout.matchingBounds(query: "甲")
        try TestSupport.expect(
            repeated.count == 3,
            "A repeated query produces one geometric box per non-overlapping match"
        )
        try TestSupport.expect(
            close(repeated[0], firstBounds[0]!)
                && close(repeated[1], firstBounds[2]!)
                && close(repeated[2], firstBounds[5]!),
            "Repeated match boxes map back to each original OCR region"
        )

        let multiline = layout.matchingBounds(query: "甲\n乙")
        try TestSupport.expect(
            multiline.count == 2,
            "A match spanning lines yields one box on each source line"
        )
        try TestSupport.expect(
            close(multiline[0], firstBounds[5]!) && close(multiline[1], secondBounds),
            "Multi-line match boxes retain lower-left source coordinates"
        )
        try TestSupport.expect(
            layout.matchingBounds(query: "missing").isEmpty,
            "A missing query produces no image highlight geometry"
        )
    }

    @MainActor
    private static func overlayGeometry() throws {
        let landscape = ImageSearchHighlightOverlay.imageRect(
            imageSize: CGSize(width: 400, height: 200),
            in: CGSize(width: 300, height: 300)
        )
        try TestSupport.expect(
            close(landscape, CGRect(x: 0, y: 75, width: 300, height: 150)),
            "A landscape image fits horizontally and centers vertically"
        )

        let portrait = ImageSearchHighlightOverlay.imageRect(
            imageSize: CGSize(width: 200, height: 400),
            in: CGSize(width: 300, height: 300)
        )
        try TestSupport.expect(
            close(portrait, CGRect(x: 75, y: 0, width: 150, height: 300)),
            "A portrait image fits vertically and centers horizontally"
        )
        try TestSupport.expect(
            ImageSearchHighlightOverlay.imageRect(
                imageSize: .zero, in: CGSize(width: 300, height: 300)) == .zero,
            "An invalid image size produces an empty fitted rect"
        )

        let imageRect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let displayed = ImageSearchHighlightOverlay.displayRect(
            CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4),
            imageRect: imageRect
        )
        try TestSupport.expect(
            close(displayed, CGRect(x: 60, y: 60, width: 100, height: 40)),
            "Vision's lower-left normalized region flips into local display coordinates"
        )
    }

    @MainActor
    private static func highlightPayloadCache() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight-\(UUID()).png")
        let text = "cache"
        let layout = ImageTextLayout(lines: [
            .init(
                text: text,
                characterBounds: characterBounds(
                    count: text.count,
                    values: [0: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.2)])
            ),
        ])
        ImageSearchHighlightPayload.purge()

        let gate = Gate()
        let inFlight = Task { @MainActor in
            let payload = await ImageSearchHighlightPayload.load(url, recognize: { _ in
                await gate.suspend()
                return layout
            })
            return payload != nil
        }
        await gate.waitUntilSuspended()
        ImageSearchHighlightPayload.purge()
        gate.resume()
        let stalePayloadReturned = await inFlight.value
        try TestSupport.expect(
            stalePayloadReturned,
            "Injected recognition returns a payload even when its cache generation becomes stale"
        )
        try TestSupport.expect(
            ImageSearchHighlightPayload.cached(for: url) == nil,
            "Purging during recognition prevents a stale payload from entering the cache"
        )

        guard let fresh = await ImageSearchHighlightPayload.load(url, recognize: { _ in layout }) else {
            throw TestSupport.Failure(description: "The fresh injected recognition returns a payload")
        }
        guard let cached = ImageSearchHighlightPayload.cached(for: url) else {
            throw TestSupport.Failure(description: "The current generation stores its recognized payload")
        }
        try TestSupport.expect(fresh === cached, "A cache hit returns the recognized payload instance")
        try TestSupport.expect(
            cached.layout.text == "cache",
            "The cached payload preserves normalized recognition layout"
        )

        ImageSearchHighlightPayload.purge()
        try TestSupport.expect(
            ImageSearchHighlightPayload.cached(for: url) == nil,
            "purge clears recognized payloads"
        )
    }

    @MainActor
    private static func boundedCacheMetadata() throws {
        let cache = ImageThumbnail.ImageCache(metadataLimit: 4)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let generation = cache.currentGeneration()
        for index in 0..<5 {
            cache.insert(image, forKey: "key-\(index)" as NSString,
                         path: "path-\(index)", epoch: 0, cost: 4, generation: generation)
        }
        try TestSupport.expect(cache.currentGeneration() != generation,
                               "Cache bookkeeping stays bounded even without NSCache eviction callbacks")
        cache.insert(image, forKey: "stale", path: "path-0", epoch: 0,
                     cost: 4, generation: generation)
        try TestSupport.expect(cache.values.object(forKey: "stale") == nil,
                               "Metadata cleanup rejects decodes from the previous generation")
        let invalidationGeneration = cache.currentGeneration()
        for index in 0..<5 { cache.invalidate(path: "deleted-\(index)") }
        try TestSupport.expect(cache.currentGeneration() != invalidationGeneration,
                               "Deleted paths do not accumulate unbounded invalidation records")
        let current = cache.currentGeneration()
        let epoch = cache.epoch(for: "restored")
        cache.invalidate(path: "restored")
        cache.insert(image, forKey: "deleted", path: "restored", epoch: epoch,
                     cost: 4, generation: current)
        try TestSupport.expect(cache.values.object(forKey: "deleted") == nil,
                               "Deleting one path rejects its pending decode")
        cache.insert(image, forKey: "restored", path: "restored", epoch: cache.epoch(for: "restored"),
                     cost: 4, generation: current)
        try TestSupport.expect(cache.values.object(forKey: "restored") === image,
                               "A new decode can populate a restored path")
    }

    @MainActor
    static func run() async throws {
        try boundedCacheMetadata()
        try fingerprintFixtures()
        try previewDetailsDefaults()
        try await TestSupport.withTemporaryDirectory { root in
            try rowCacheTickets(in: root)
            try rowCacheMutationAndRemoval(in: root)
            try rowCacheSymlinkDefense(in: root)
            try rowCacheByteBound(in: root)
            try await thumbnailBehavior(in: root)
            try await fileBackedPreviewLifecycle(in: root)
            try await unavailableImagePreviewStillCopies(in: root)
            try layoutNormalization()
            try layoutMatches()
            try overlayGeometry()
            try await highlightPayloadCache()
        }
        print("PASS: image fingerprints, row cache, thumbnails, file preview states, OCR layout")
    }
}
