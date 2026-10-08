import AppKit
@testable import Kit

@MainActor
enum ImageDecodeCoordinatorTests {
    private typealias Request = ImageThumbnail.DecodeRequest
    private typealias Result = ImageThumbnail.Decoded
    private typealias Coordinator = ImageThumbnail.DecodeCoordinator

    /// Holds synchronous workers open so cancellation cannot masquerade as completed ImageIO work.
    private final class DecodeGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var calls: [Request: Int] = [:]
        private var released: [Request: Set<Int>] = [:]
        private var releaseEverything = false
        private var active = 0
        private var peak = 0
        private var cancelledFinishes = 0
        private var cached: [Request] = []

        var counts: (active: Int, peak: Int, cancelled: Int, cached: Int) {
            condition.lock()
            defer { condition.unlock() }
            return (active, peak, cancelledFinishes, cached.count)
        }

        func callCount(_ request: Request) -> Int {
            condition.lock()
            defer { condition.unlock() }
            return calls[request, default: 0]
        }

        func decode(_ request: Request) -> Result {
            condition.lock()
            let occurrence = calls[request, default: 0] + 1
            calls[request] = occurrence
            active += 1
            peak = max(peak, active)
            let deadline = Date().addingTimeInterval(10)
            while !releaseEverything, released[request]?.contains(occurrence) != true {
                precondition(condition.wait(until: deadline), "Timed out waiting for a test decode permit")
            }
            active -= 1
            if Task.isCancelled { cancelledFinishes += 1 }
            condition.unlock()
            // Deliberately return a bitmap even after cancellation to test coordinator ownership.
            return Result(image: NSImage(size: NSSize(width: 2, height: 2)))
        }

        func cache(_ request: Request, _ result: Result) {
            guard result.image != nil else { return }
            condition.lock()
            cached.append(request)
            condition.unlock()
        }

        func release(_ request: Request, occurrence: Int = 1) {
            condition.lock()
            released[request, default: []].insert(occurrence)
            condition.broadcast()
            condition.unlock()
        }

        func releaseAll() {
            condition.lock()
            releaseEverything = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private actor StartGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private static func request(_ name: String, size: Int = 900, generation: UInt64 = 0) -> Request {
        Request(url: URL(fileURLWithPath: "/temporary-fixture/\(name).png"),
                maxPixel: size, generation: generation)
    }

    private static func coordinator(_ gate: DecodeGate, limit: Int = 2) -> Coordinator {
        Coordinator(limit: limit, decode: { gate.decode($0) }, cache: { gate.cache($0, $1) })
    }

    /// Wait for observable state, never rely on a guessed task scheduling delay.
    private static func eventually(_ message: String, _ predicate: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            precondition(ContinuousClock.now < deadline, message)
            await Task.yield()
        }
    }

    private static func boundedBurst() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate)
        let requests = (0..<20).map { request("burst-\($0)") }
        var tasks: [Task<Result, Never>] = []
        for (index, request) in requests.enumerated() {
            tasks.append(Task { await queue.decode(request) })
            await eventually("Burst consumer registration") {
                await queue.activity.consumers == index + 1
            }
        }
        await eventually("Two workers start") { gate.counts.active == 2 }
        let activity = await queue.activity
        precondition(activity.running == 2 && activity.queued == 18)
        tasks[2].cancel()
        let cancelled = await tasks[2].value
        precondition(cancelled.image == nil && gate.callCount(requests[2]) == 0,
                     "Cancelling a queued request avoids decode entirely")
        gate.release(requests[0])
        await eventually("Next live queued job starts") { gate.callCount(requests[3]) == 1 }
        precondition(gate.callCount(requests[2]) == 0)
        gate.releaseAll()
        for (index, task) in tasks.enumerated() {
            let result = await task.value
            precondition((result.image != nil) == (index != 2))
        }
        let finished = await queue.activity
        precondition(finished.running == 0 && finished.queued == 0 && finished.consumers == 0)
        precondition(gate.counts.peak == 2 && gate.counts.cached == 19)
        print("PASS: 20 image requests, peak 2 decodes, queued cancellation skips work")
    }

    private static func sharedConsumers() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate)
        let image = request("shared")
        let first = Task { await queue.decode(image) }
        await eventually("Shared decode starts") { gate.callCount(image) == 1 }
        let second = Task { await queue.decode(image) }
        let third = Task { await queue.decode(image) }
        await eventually("Three consumers register") { await queue.activity.consumers == 3 }
        first.cancel()
        let cancelled = await first.value
        precondition(cancelled.image == nil && gate.counts.active == 1,
                     "A cancelled consumer returns before synchronous decode finishes")
        precondition(gate.callCount(image) == 1)
        gate.release(image)
        let remaining = await second.value
        let shared = await third.value
        precondition(remaining.image != nil && remaining.image === shared.image,
                     "Remaining views receive the same decoded bitmap")
        precondition(gate.counts.cancelled == 0 && gate.counts.cached == 1,
                     "Cancelling one view leaves the shared worker and cache intact")
        print("PASS: shared bitmap, independent consumer cancellation, prompt cancelled return")
    }

    private static func cancelledWorkerAndRetry() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate, limit: 1)
        let image = request("retry")
        let first = Task { await queue.decode(image) }
        await eventually("Initial decode starts") { gate.callCount(image) == 1 }
        first.cancel()
        let cancelled = await first.value
        precondition(cancelled.image == nil)
        await eventually("Last consumer leaves") { await queue.activity.consumers == 0 }
        let retry = Task { await queue.decode(image) }
        await eventually("Retry queues behind cancelled synchronous work") {
            let state = await queue.activity
            return state.running == 1 && state.queued == 1 && state.consumers == 1
        }
        precondition(gate.callCount(image) == 1 && gate.counts.active == 1,
                     "Cancellation does not release an occupied worker slot")
        gate.release(image)
        await eventually("Retry gets its own worker") { gate.callCount(image) == 2 }
        precondition(gate.counts.cancelled == 1 && gate.counts.cached == 0,
                     "The unused bitmap from a cancelled worker is discarded")
        let sharedRetry = Task { await queue.decode(image) }
        await eventually("Old completion preserves the replacement job") {
            await queue.activity.consumers == 2
        }
        gate.release(image, occurrence: 2)
        let result = await retry.value
        let shared = await sharedRetry.value
        precondition(result.image != nil && result.image === shared.image)
        precondition(gate.callCount(image) == 2 && gate.counts.peak == 1 && gate.counts.cached == 1)
        print("PASS: last-consumer cancellation, occupied slot retained, same-image retry survives old completion")
    }

    private static func cancelledBeforeRegistration() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate)
        let start = StartGate()
        let image = request("never-start")
        let task = Task {
            await start.wait()
            return await queue.decode(image)
        }
        await eventually("Caller waits before actor registration") { await start.isWaiting }
        task.cancel()
        await start.open()
        let result = await task.value
        precondition(result.image == nil && gate.callCount(image) == 0)
        let activity = await queue.activity
        precondition(activity.running == 0 && activity.queued == 0 && activity.consumers == 0)
        print("PASS: cancellation before actor registration creates no work or stranded continuation")
    }

    private static func startedRowsSurviveScrollCancellation() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate, limit: 1)
        let image = request("scroll-back", size: 512)
        let first = Task { await queue.decode(image) }
        await eventually("Row decode starts") { gate.callCount(image) == 1 }
        first.cancel()
        let cancelled = await first.value
        precondition(cancelled.image == nil)
        await eventually("Offscreen consumer leaves") { await queue.activity.consumers == 0 }
        let returning = Task { await queue.decode(image) }
        await eventually("Returning row rejoins its running work") { await queue.activity.consumers == 1 }
        let activity = await queue.activity
        precondition(gate.callCount(image) == 1 && activity.queued == 0)
        returning.cancel()
        _ = await returning.value
        gate.release(image)
        await eventually("Unused row warms the cache") { await queue.activity.running == 0 }
        precondition(gate.counts.cached == 1 && gate.counts.cancelled == 0,
                     "Started row work remains useful after every consumer scrolls away")
        print("PASS: scroll-away/return shares one row decode, completed offscreen row stays warm")
    }

    private static func visiblePriorityPromotesSharedPrefetch() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate, limit: 1)
        let blocker = request("priority-blocker")
        let row = request("priority-row", size: 512)
        let preview = request("priority-preview")
        let distant = request("priority-distant", size: 512)
        let blocking = Task { await queue.decode(blocker) }
        await eventually("Blocking decode starts") { gate.callCount(blocker) == 1 }
        let prefetched = Task { await queue.decode(row, priority: .prefetch) }
        await eventually("Prefetch queues") { await queue.activity.consumers == 2 }
        let previewed = Task { await queue.decode(preview) }
        await eventually("Preview queues") { await queue.activity.consumers == 3 }
        let distantLoad = Task { await queue.decode(distant, priority: .prefetch) }
        let visible = Task { await queue.decode(row, priority: .visibleRow) }
        await eventually("Visible row promotes the existing job") { await queue.activity.consumers == 5 }
        gate.release(blocker)
        await eventually("Visible row starts before preview") { gate.callCount(row) == 1 }
        precondition(gate.callCount(preview) == 0 && gate.callCount(distant) == 0)
        gate.release(row)
        await eventually("Preview starts before distant prefetch") { gate.callCount(preview) == 1 }
        precondition(gate.callCount(distant) == 0)
        gate.releaseAll()
        _ = await blocking.value
        let first = await prefetched.value
        let second = await visible.value
        _ = await previewed.value
        _ = await distantLoad.value
        precondition(first.image === second.image && gate.callCount(row) == 1)
        print("PASS: visible rows promote shared prefetch jobs; previews precede remaining prefetch")
    }

    private static func previewsReserveRoomForRows() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = Coordinator(limit: 2, previewLimit: 1,
            decode: { gate.decode($0) }, cache: { gate.cache($0, $1) })
        let a = request("large-a"), b = request("large-b")
        let row = request("reserved-row", size: 512)
        let first = Task { await queue.decode(a) }
        await eventually("Large preview starts") { gate.callCount(a) == 1 }
        let second = Task { await queue.decode(b) }
        await eventually("Second preview queues") { await queue.activity.queued == 1 }
        let visible = Task { await queue.decode(row) }
        await eventually("Row uses the reserved slot") { gate.callCount(row) == 1 }
        precondition(gate.callCount(b) == 0 && gate.counts.peak == 2)
        gate.releaseAll()
        _ = await first.value
        _ = await second.value
        _ = await visible.value
        print("PASS: synchronous previews cannot occupy both slots and block visible rows")
    }

    private static func independentSizesAndGenerations() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let queue = coordinator(gate)
        let requests = [request("same-file", size: 512), request("same-file"),
                        request("same-file", generation: 1)]
        var tasks: [Task<Result, Never>] = []
        for (index, request) in requests.enumerated() {
            tasks.append(Task { await queue.decode(request) })
            await eventually("Independent request registers") {
                await queue.activity.consumers == index + 1
            }
        }
        await eventually("Different sizes decode separately") {
            gate.callCount(requests[0]) == 1 && gate.callCount(requests[1]) == 1
        }
        precondition(gate.callCount(requests[2]) == 0)
        gate.releaseAll()
        var images: [NSImage] = []
        for task in tasks { images.append((await task.value).image!) }
        precondition(images[0] !== images[1] && images[1] !== images[2])
        precondition(gate.counts.cached == 3 && gate.counts.peak == 2)
        print("PASS: row/preview sizes and cache generations keep independent decode identities")
    }

    private static func failedDecodeReleasesSlot() async {
        let gate = DecodeGate()
        defer { gate.releaseAll() }
        let failure = request("failure")
        let success = request("success")
        let queue = Coordinator(limit: 1, decode: {
            $0 == failure ? .empty : gate.decode($0)
        }, cache: { gate.cache($0, $1) })
        let result = await queue.decode(failure)
        precondition(result.image == nil)
        let next = Task { await queue.decode(success) }
        await eventually("Decode failure frees its worker slot") { gate.callCount(success) == 1 }
        gate.release(success)
        let recovered = await next.value
        precondition(recovered.image != nil && gate.counts.cached == 1)
    }

    private static func realImageAndCancelledCacheHit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-image-decoder-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 150, bitmap.bytesPerRow * bitmap.pixelsHigh)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let image = await ImageThumbnail.loadAsync(url, maxPixel: 64)
        precondition(image?.size == NSSize(width: 64, height: 43))
        precondition(ImageThumbnail.cached(url, maxPixel: 64) === image)
        let fractional = await ImageThumbnail.loadAsync(url, maxPixel: 512.5)
        precondition(fractional != nil && ImageThumbnail.cached(url, maxPixel: 512.5) === fractional,
                     "Fractional sizes share the integer pixel cache identity")
        ImageThumbnail.purgePreviews()
        precondition(ImageThumbnail.cached(url, maxPixel: 512.5) === fractional,
                     "Normalized row sizes stay in the row cache")
        let start = StartGate()
        let cancelled = Task {
            await start.wait()
            return Result(image: await ImageThumbnail.loadAsync(url, maxPixel: 64))
        }
        await eventually("Cache hit caller waits") { await start.isWaiting }
        cancelled.cancel()
        await start.open()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.image == nil, "Cancelled callers also skip the cache fast path")
        let missing = await ImageThumbnail.loadAsync(directory.appendingPathComponent("missing.png"),
                                                     maxPixel: 64)
        precondition(missing == nil)
        print("PASS: real ImageIO downsampling/cache, cancelled cache hit, missing image")
    }

    static func run() async throws {
        await boundedBurst()
        await sharedConsumers()
        await cancelledWorkerAndRetry()
        await cancelledBeforeRegistration()
        await startedRowsSurviveScrollCancellation()
        await visiblePriorityPromotesSharedPrefetch()
        await previewsReserveRoomForRows()
        await independentSizesAndGenerations()
        await failedDecodeReleasesSlot()
        try await realImageAndCancelledCacheHit()
    }
}
