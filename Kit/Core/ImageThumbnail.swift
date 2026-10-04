import AppKit
import CryptoKit
import ImageIO

/// Stable identity for the normalized PNG payload owned by the clipboard store.
enum ImageFingerprint {
    static func digest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Downsampled, memory-capped image loading for the clipboard UI: ImageIO decodes each on-disk image to exactly the pixel size needed and caches it in a system-evicted `NSCache`.
enum ImageThumbnail {
    /// `NSCache` is thread-safe but not annotated `Sendable`, so cross-thread use (a detached decode populating what the main actor reads) needs the guarantee asserted once here.
    private final class ImageCache: NSCache<NSString, NSImage>, @unchecked Sendable {
        private let mutationLock = NSLock()
        private var generation: UInt64 = 0

        func currentGeneration() -> UInt64 {
            mutationLock.withLock { generation }
        }

        func insert(_ image: NSImage, forKey key: NSString, cost: Int, generation: UInt64) {
            mutationLock.withLock {
                guard generation == self.generation else { return }
                setObject(image, forKey: key, cost: cost)
            }
        }

        func purge() {
            mutationLock.withLock {
                generation &+= 1
                removeAllObjects()
            }
        }
    }

    /// Small row thumbnails (≤ `rowThreshold` px), byte-bounded and kept warm across palette dismissals so re-opening draws instantly.
    private static let rowCache: ImageCache = {
        let cache = ImageCache()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Large previews (> `rowThreshold` px), byte-bounded (not object-count, which leaked) and purged on palette close so browsing memory stays flat.
    private static let previewCache: ImageCache = {
        let cache = ImageCache()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Longest-edge size at or below which a decode is a "row" thumbnail; larger is a "preview".
    private static let rowThreshold: CGFloat = 512

    private static func pick(_ maxPixel: CGFloat) -> ImageCache {
        maxPixel <= rowThreshold ? rowCache : previewCache
    }

    private static func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    struct DecodeRequest: Hashable, Sendable {
        let url: URL
        let maxPixel: Int
        let generation: UInt64
    }

    /// A freshly-decoded, thereafter-immutable image is safe to move across the actor boundary.
    struct Decoded: @unchecked Sendable {
        let image: NSImage?
        var cost: Int = 0
        static let empty = Decoded(image: nil)
    }

    actor DecodeCoordinator {
        /// Cancellation can arrive before actor registration or completion; record it synchronously.
        private final class Consumer: @unchecked Sendable {
            private enum State { case waiting, cancelled, completed }
            private let lock = NSLock()
            private var state = State.waiting

            func cancel() {
                lock.withLock { if state == .waiting { state = .cancelled } }
            }
            var isCancelled: Bool { lock.withLock { state == .cancelled } }
            func complete() -> Bool {
                lock.withLock {
                    guard state == .waiting else { return false }
                    state = .completed
                    return true
                }
            }
        }

        private struct Waiter {
            let consumer: Consumer
            let continuation: CheckedContinuation<Decoded, Never>
        }

        private struct Job {
            let request: DecodeRequest
            var waiters: [UUID: Waiter]
            var worker: Task<Void, Never>?
        }

        private let limit: Int
        private let decodeImage: @Sendable (DecodeRequest) -> Decoded
        private let cacheImage: @Sendable (DecodeRequest, Decoded) -> Void
        private var jobs: [UUID: Job] = [:]
        private var requestJobs: [DecodeRequest: UUID] = [:]
        private var queue: [UUID] = []
        private var running = 0

        init(limit: Int, decode: @escaping @Sendable (DecodeRequest) -> Decoded,
             cache: @escaping @Sendable (DecodeRequest, Decoded) -> Void) {
            precondition(limit > 0)
            self.limit = limit
            decodeImage = decode
            cacheImage = cache
        }

        var activity: (running: Int, queued: Int, consumers: Int) {
            (running, queue.count, jobs.values.reduce(0) { $0 + $1.waiters.count })
        }

        func decode(_ request: DecodeRequest) async -> Decoded {
            let id = UUID()
            let consumer = Consumer()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, !consumer.isCancelled else {
                        continuation.resume(returning: .empty)
                        return
                    }
                    let waiter = Waiter(consumer: consumer, continuation: continuation)
                    if let jobID = requestJobs[request] {
                        jobs[jobID]?.waiters[id] = waiter
                    } else {
                        let jobID = UUID()
                        jobs[jobID] = Job(request: request, waiters: [id: waiter])
                        requestJobs[request] = jobID
                        queue.append(jobID)
                    }
                    startQueued()
                }
            } onCancel: {
                consumer.cancel()
                Task { await self.cancel(id, request: request) }
            }
        }

        private func cancel(_ id: UUID, request: DecodeRequest) {
            guard let jobID = requestJobs[request],
                  let waiter = jobs[jobID]?.waiters.removeValue(forKey: id)
            else { return }
            waiter.continuation.resume(returning: .empty)
            guard let job = jobs[jobID], job.waiters.isEmpty else { return }
            requestJobs[request] = nil
            if let worker = job.worker {
                worker.cancel()
                // ImageIO is synchronous: keep its slot until the worker actually finishes.
            } else {
                jobs[jobID] = nil
                queue.removeAll { $0 == jobID }
            }
        }

        private func startQueued() {
            while running < limit, !queue.isEmpty {
                let jobID = queue.removeFirst()
                guard var job = jobs[jobID] else { continue }
                // Skip consumers cancelled before their cancellation message reaches this actor.
                for (id, waiter) in job.waiters where waiter.consumer.isCancelled {
                    job.waiters[id] = nil
                    waiter.continuation.resume(returning: .empty)
                }
                guard !job.waiters.isEmpty else {
                    jobs[jobID] = nil
                    requestJobs[job.request] = nil
                    continue
                }
                let request = job.request
                let decodeImage = decodeImage
                job.worker = Task.detached(priority: .userInitiated) {
                    let result = Task.isCancelled ? .empty : decodeImage(request)
                    await self.finish(jobID, result: result)
                }
                jobs[jobID] = job
                running += 1
            }
        }

        private func finish(_ jobID: UUID, result: Decoded) {
            guard let job = jobs.removeValue(forKey: jobID) else { return }
            running -= 1
            if requestJobs[job.request] == jobID { requestJobs[job.request] = nil }
            let active = job.waiters.values.filter { $0.consumer.complete() }
            // Unused or cancelled results never warm the cache; purges also invalidate generations.
            if !active.isEmpty, job.worker?.isCancelled == false {
                cacheImage(job.request, result)
            }
            for waiter in job.waiters.values {
                waiter.continuation.resume(returning: waiter.consumer.isCancelled ? .empty : result)
            }
            startQueued()
        }
    }

    private static let decodeCoordinator = DecodeCoordinator(
        limit: 2,
        decode: { load($0.url, maxPixel: CGFloat($0.maxPixel)) },
        cache: { request, result in
            guard let image = result.image else { return }
            pick(CGFloat(request.maxPixel)).insert(
                image, forKey: cacheKey(request.url, CGFloat(request.maxPixel)),
                cost: result.cost, generation: request.generation)
        })

    /// Frees the large preview bitmaps on palette dismiss; row thumbnails stay warm for an instant re-open.
    static func purgePreviews() {
        previewCache.purge()
    }

    /// Cache-only lookup (never touches disk) so views render an already-decoded thumbnail on the same frame.
    static func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        pick(CGFloat(Int(maxPixel))).object(forKey: cacheKey(url, maxPixel))
    }

    /// Decodes off the main thread and returns the decode directly, not a cache re-read — a purge or eviction mid-decode must not strand a thumbnail on its placeholder.
    static func loadAsync(_ url: URL, maxPixel: CGFloat) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let maxPixel = CGFloat(Int(maxPixel))
        if let cached = cached(url, maxPixel: maxPixel) { return cached }
        let generation = pick(maxPixel).currentGeneration()
        let decoded = await decodeCoordinator.decode(DecodeRequest(
            url: url, maxPixel: Int(maxPixel), generation: generation))
        guard !Task.isCancelled else { return nil }
        return decoded.image
    }

    /// ImageIO is synchronous; cancellation checks surround the expensive decode and bitmap creation.
    private static func load(_ url: URL, maxPixel: CGFloat) -> Decoded {
        autoreleasepool {
            guard !Task.isCancelled else { return .empty }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), !Task.isCancelled
            else { return .empty }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  !Task.isCancelled
            else { return .empty }
            let image = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return Decoded(image: image, cost: cgImage.bytesPerRow * cgImage.height)
        }
    }

    /// Pixel dimensions read from image metadata — no full decode.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
