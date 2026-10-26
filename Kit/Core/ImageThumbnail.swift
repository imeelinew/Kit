import AppKit
import CryptoKit
import Darwin
import ImageIO

/// Stable identity for the normalized PNG payload owned by the clipboard store.
enum ImageFingerprint {
    static func digest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Downsampled, memory-capped image loading for the clipboard UI: ImageIO decodes each on-disk image to exactly the pixel size needed and caches it in a system-evicted `NSCache`.
enum ImageThumbnail {
    static let rowMaxPixel: CGFloat = 512
    static let fileDidChange = Notification.Name("com.eli.Kit.fileAppearanceDidChange")
    private static let rowDiskCache = ClipboardRowThumbnailCache()

    private final class ManagedImageDirectories: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func register(_ url: URL) {
            _ = lock.withLock { paths.insert(url.standardizedFileURL.path) }
        }

        func contains(_ url: URL) -> Bool {
            lock.withLock { paths.contains(url.standardizedFileURL.path) }
        }
    }

    private static let managedImageDirectories = ManagedImageDirectories()

    private enum FileSignature: Equatable {
        case metadata(
            device: dev_t,
            inode: ino_t,
            mode: mode_t,
            size: off_t,
            modifiedSeconds: time_t,
            modifiedNanoseconds: Int,
            changedSeconds: time_t,
            changedNanoseconds: Int)
        case failure(Int32)

        static func read(at url: URL) -> FileSignature {
            var info = stat()
            let result = url.path.withCString { stat($0, &info) }
            guard result == 0 else { return .failure(errno) }
            return .metadata(
                device: info.st_dev,
                inode: info.st_ino,
                mode: info.st_mode,
                size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec,
                changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
    }

    private final class FileVersions: @unchecked Sendable {
        private struct Entry {
            let version: UInt64
            var accessed: UInt64
            let signature: FileSignature?
        }
        private let lock = NSLock()
        private var clock: UInt64 = 0
        private var entries: [String: Entry] = [:]

        func version(for url: URL, invalidating: Bool = false) -> UInt64 {
            lock.withLock {
                clock &+= 1
                let path = url.standardizedFileURL.path
                if var entry = entries[path], !invalidating {
                    entry.accessed = clock
                    entries[path] = entry
                    return entry.version
                }
                if entries[path] == nil, entries.count >= 1024,
                    let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key
                {
                    entries[oldest] = nil
                }
                entries[path] = Entry(
                    version: clock, accessed: clock,
                    signature: invalidating ? entries[path]?.signature : nil)
                return clock
            }
        }

        func refresh(_ signature: FileSignature, for url: URL) -> Bool {
            lock.withLock {
                clock &+= 1
                let path = url.standardizedFileURL.path
                if var entry = entries[path], entry.signature == signature {
                    entry.accessed = clock
                    entries[path] = entry
                    return false
                }
                if entries[path] == nil, entries.count >= 1024,
                    let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key
                {
                    entries[oldest] = nil
                }
                entries[path] = Entry(version: clock, accessed: clock, signature: signature)
                return true
            }
        }
    }

    private static let fileVersions = FileVersions()

    static func fileVersion(for url: URL) -> UInt64 {
        if managedImageDirectories.contains(url.deletingLastPathComponent()) { return 0 }
        return fileVersions.version(for: url)
    }

    /// Refreshes the cached metadata signature without blocking readers on filesystem access
    @discardableResult
    nonisolated static func refreshFile(at url: URL) -> Bool {
        if managedImageDirectories.contains(url.deletingLastPathComponent()) { return false }
        let signature = FileSignature.read(at: url)
        return fileVersions.refresh(signature, for: url)
    }

    /// A fresh version prevents pending decodes from repopulating the current file's cache
    static func invalidateFile(at url: URL) {
        _ = fileVersions.version(for: url, invalidating: true)
    }

    /// Persist thumbnails only beside originals owned by a clipboard store
    static func registerManagedImageDirectory(_ url: URL) {
        managedImageDirectories.register(url)
    }

    enum Priority: Int, Sendable {
        case visibleRow, preview, prefetch
    }

    /// `NSCache` is thread-safe but not annotated `Sendable`, so cross-thread use (a detached decode populating what the main actor reads) needs the guarantee asserted once here.
    private final class ImageCache: @unchecked Sendable {
        let values = NSCache<NSString, NSImage>()
        private let mutationLock = NSLock()
        private var generation: UInt64 = 0

        func currentGeneration() -> UInt64 {
            mutationLock.withLock { generation }
        }

        func insert(_ image: NSImage, forKey key: NSString, cost: Int, generation: UInt64) {
            mutationLock.withLock {
                guard generation == self.generation else { return }
                values.setObject(image, forKey: key, cost: cost)
            }
        }

        func purge() {
            mutationLock.withLock {
                generation &+= 1
                values.removeAllObjects()
            }
        }
    }

    /// Small row thumbnails (≤ `rowThreshold` px), byte-bounded and kept warm across palette dismissals so re-opening draws instantly.
    private static let rowCache: ImageCache = {
        let cache = ImageCache()
        cache.values.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// Large previews (> `rowThreshold` px), byte-bounded (not object-count, which leaked) and purged on palette close so browsing memory stays flat.
    private static let previewCache: ImageCache = {
        let cache = ImageCache()
        cache.values.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Longest-edge size at or below which a decode is a "row" thumbnail; larger is a "preview".
    private static let rowThreshold = rowMaxPixel

    private static func pick(_ maxPixel: CGFloat) -> ImageCache {
        maxPixel <= rowThreshold ? rowCache : previewCache
    }

    private static func cacheKey(_ url: URL, _ maxPixel: CGFloat, version: UInt64) -> NSString {
        "\(url.path)#\(Int(maxPixel))#\(version)" as NSString
    }

    struct DecodeRequest: Hashable, Sendable {
        let url: URL
        let maxPixel: Int
        let generation: UInt64
        let sourceVersion: UInt64

        init(url: URL, maxPixel: Int, generation: UInt64, sourceVersion: UInt64 = 0) {
            self.url = url
            self.maxPixel = maxPixel
            self.generation = generation
            self.sourceVersion = sourceVersion
        }
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
            let priority: Priority
        }

        private struct Job {
            let request: DecodeRequest
            var waiters: [UUID: Waiter]
            var worker: Task<Void, Never>?
        }

        private let limit: Int
        private let previewLimit: Int
        private let decodeImage: @Sendable (DecodeRequest) -> Decoded
        private let cacheImage: @Sendable (DecodeRequest, Decoded) -> Void
        private var jobs: [UUID: Job] = [:]
        private var requestJobs: [DecodeRequest: UUID] = [:]
        private var queue: [UUID] = []
        private var running = 0
        private var runningPreviews = 0

        init(limit: Int, previewLimit: Int? = nil, decode: @escaping @Sendable (DecodeRequest) -> Decoded,
             cache: @escaping @Sendable (DecodeRequest, Decoded) -> Void) {
            precondition(limit > 0)
            self.limit = limit
            self.previewLimit = previewLimit ?? limit
            precondition(self.previewLimit > 0 && self.previewLimit <= limit)
            decodeImage = decode
            cacheImage = cache
        }

        var activity: (running: Int, queued: Int, consumers: Int) {
            (running, queue.count, jobs.values.reduce(0) { $0 + $1.waiters.count })
        }

        func decode(_ request: DecodeRequest, priority: Priority? = nil) async -> Decoded {
            let id = UUID()
            let consumer = Consumer()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled, !consumer.isCancelled else {
                        continuation.resume(returning: .empty)
                        return
                    }
                    let waiter = Waiter(consumer: consumer, continuation: continuation,
                        priority: priority ?? (request.maxPixel <= Int(rowMaxPixel) ? .visibleRow : .preview))
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
            if let worker = job.worker {
                // Keep started row work reusable when the user scrolls back. Large previews
                // still cancel as soon as their last consumer leaves.
                if request.maxPixel > Int(rowMaxPixel) {
                    requestJobs[request] = nil
                    worker.cancel()
                }
                // ImageIO is synchronous: keep its slot until the worker actually finishes.
            } else {
                requestJobs[request] = nil
                jobs[jobID] = nil
                queue.removeAll { $0 == jobID }
            }
        }

        private func startQueued() {
            while running < limit, !queue.isEmpty {
                // A preview cannot take the slot reserved for visible row images. Already
                // running synchronous work cannot be preempted, so bound previews at start.
                let eligible = queue.indices.filter { index in
                    guard let job = jobs[queue[index]] else { return true }
                    return job.request.maxPixel <= Int(rowMaxPixel) || runningPreviews < previewLimit
                }
                guard let index = eligible.min(by: { left, right in
                    let lhs = jobs[queue[left]]?.waiters.values.map(\.priority.rawValue).min() ?? Int.max
                    let rhs = jobs[queue[right]]?.waiters.values.map(\.priority.rawValue).min() ?? Int.max
                    return lhs == rhs ? left < right : lhs < rhs
                }) else { break }
                let jobID = queue.remove(at: index)
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
                if request.maxPixel > Int(rowMaxPixel) { runningPreviews += 1 }
            }
        }

        private func finish(_ jobID: UUID, result: Decoded) {
            guard let job = jobs.removeValue(forKey: jobID) else { return }
            running -= 1
            if job.request.maxPixel > Int(rowMaxPixel) { runningPreviews -= 1 }
            if requestJobs[job.request] == jobID { requestJobs[job.request] = nil }
            let active = job.waiters.values.filter { $0.consumer.complete() }
            // Started rows warm the bounded cache even after scrolling away. Preview
            // results still require a consumer; cache generations guard both paths.
            if (!active.isEmpty || job.request.maxPixel <= Int(rowMaxPixel)), job.worker?.isCancelled == false {
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
        previewLimit: 1,
        decode: { load($0.url, maxPixel: CGFloat($0.maxPixel)) },
        cache: { request, result in
            guard let image = result.image else { return }
            pick(CGFloat(request.maxPixel)).insert(
                image, forKey: cacheKey(
                    request.url, CGFloat(request.maxPixel), version: request.sourceVersion),
                cost: result.cost, generation: request.generation)
        })

    /// Frees the large preview bitmaps on palette dismiss; row thumbnails stay warm for an instant re-open.
    static func purgePreviews() {
        previewCache.purge()
    }

    /// Called after original deletion, invalidating pending writes before an undo can restore it.
    static func removeCachedImage(for url: URL) {
        rowCache.purge()
        previewCache.purge()
        rowDiskCache.remove(for: url)
    }

    static func removeCachedRows(in imagesDirectory: URL) {
        rowCache.purge()
        previewCache.purge()
        rowDiskCache.removeAll(in: imagesDirectory)
    }

    /// Drop only decoded row bitmaps; persistent thumbnails remain available for a cold reload.
    static func purgeRowMemory() {
        rowCache.purge()
    }

    @MainActor
    final class RowPrefetcher {
        private var tasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]

        isolated deinit { cancel() }

        func cancel() {
            for entry in tasks.values { entry.task.cancel() }
            tasks.removeAll()
        }

        /// The caller supplies a bounded viewport neighborhood, ordered by scroll direction.
        func update(_ urls: [URL]) {
            let desired = Set(urls)
            for url in tasks.keys.filter({ !desired.contains($0) }) {
                tasks.removeValue(forKey: url)?.task.cancel()
            }
            for url in urls where tasks[url] == nil && cached(url, maxPixel: rowMaxPixel) == nil {
                let id = UUID()
                let task = Task { [weak self] in
                    _ = await loadAsync(url, maxPixel: rowMaxPixel, priority: .prefetch)
                    if self?.tasks[url]?.id == id { self?.tasks[url] = nil }
                }
                tasks[url] = (id, task)
            }
        }
    }

    /// Cache-only lookup (never touches disk) so views render an already-decoded thumbnail on the same frame.
    static func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        pick(CGFloat(Int(maxPixel))).values.object(
            forKey: cacheKey(url, maxPixel, version: fileVersion(for: url)))
    }

    /// Decodes off the main thread and returns the decode directly, not a cache re-read — a purge or eviction mid-decode must not strand a thumbnail on its placeholder.
    static func loadAsync(_ url: URL, maxPixel: CGFloat, priority: Priority? = nil) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let maxPixel = CGFloat(Int(maxPixel))
        let version = fileVersion(for: url)
        if let cached = pick(maxPixel).values.object(
            forKey: cacheKey(url, maxPixel, version: version)) { return cached }
        let generation = pick(maxPixel).currentGeneration()
        let decoded = await decodeCoordinator.decode(DecodeRequest(
            url: url, maxPixel: Int(maxPixel), generation: generation, sourceVersion: version),
            priority: priority)
        guard !Task.isCancelled, version == fileVersion(for: url) else { return nil }
        return decoded.image
    }

    /// ImageIO is synchronous; cancellation checks surround the expensive decode and bitmap creation.
    private static func load(_ url: URL, maxPixel: CGFloat) -> Decoded {
        autoreleasepool {
            guard !Task.isCancelled else { return .empty }
            let usesDiskCache = maxPixel == rowMaxPixel
                && managedImageDirectories.contains(url.deletingLastPathComponent())
            let ticket = usesDiskCache ? rowDiskCache.ticket(for: url) : nil
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            let cachedImage: CGImage? = ticket.flatMap { ticket in
                guard let cachedURL = rowDiskCache.cachedURL(for: ticket),
                    let source = CGImageSourceCreateWithURL(cachedURL as CFURL, sourceOptions)
                else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            let cgImage: CGImage
            if let cachedImage {
                cgImage = cachedImage
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions), !Task.isCancelled,
                    let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                    !Task.isCancelled
                else { return .empty }
                cgImage = decoded
                if let ticket { rowDiskCache.store(cgImage, for: ticket) }
            }
            guard !Task.isCancelled else { return .empty }
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
