import AppKit
@testable import Kit

@MainActor
enum ImageDecodeCoordinatorTests {
    private typealias Request = ImageThumbnail.DecodeRequest

    /// Holds synchronous workers open so cancellation cannot masquerade as completed ImageIO work.
    private final class DecodeGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var calls: [Request: Int] = [:]
        private var released: Set<Request> = []
        private var releaseEverything = false
        private var active = 0
        private var cancelledFinishes = 0

        var counts: (active: Int, cancelled: Int) {
            condition.withLock { (active: active, cancelled: cancelledFinishes) }
        }

        func callCount(_ request: Request) -> Int {
            condition.withLock { calls[request, default: 0] }
        }

        func decode(_ request: Request) -> ImageThumbnail.Decoded {
            condition.withLock {
                calls[request, default: 0] += 1
                active += 1
                let deadline = Date().addingTimeInterval(10)
                while !releaseEverything, !released.contains(request) {
                    precondition(condition.wait(until: deadline), "Timed out waiting for a test decode permit")
                }
                active -= 1
                if Task.isCancelled { cancelledFinishes += 1 }
                return ImageThumbnail.Decoded(image: NSImage(size: NSSize(width: 2, height: 2)))
            }
        }

        func release(_ request: Request) {
            condition.withLock {
                released.insert(request)
                condition.broadcast()
            }
        }

        func releaseAll() {
            condition.withLock {
                releaseEverything = true
                condition.broadcast()
            }
        }
    }

    private static func request(_ name: String) -> Request {
        Request(url: URL(fileURLWithPath: "/temporary-fixture/\(name).png"), maxPixel: 900, generation: 0)
    }

    private static func coordinator(_ gate: DecodeGate, limit: Int = 2) -> ImageThumbnail.DecodeCoordinator {
        ImageThumbnail.DecodeCoordinator(limit: limit, decode: { gate.decode($0) }, cache: { _, _ in })
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
        let queue = coordinator(gate)
        let requests = (0..<20).map { request("burst-\($0)") }
        let tasks = requests.map { request in Task { await queue.decode(request) } }
        await eventually("All consumers register") {
            await queue.activity.consumers == 20 && gate.counts.active == 2
        }
        let activity = await queue.activity
        precondition(activity.running == 2 && activity.queued == 18)
        tasks[2].cancel()
        let cancelled = await tasks[2].value
        precondition(cancelled.image == nil && gate.callCount(requests[2]) == 0,
                     "Cancelling a queued request avoids decode entirely")
        gate.release(requests[0])
        await eventually("Next live queued job starts") { gate.callCount(requests[3]) == 1 }
        gate.releaseAll()
        let tail = await tasks[19].value
        precondition(tail.image != nil)
        print("PASS: 20 image requests, two concurrent decodes, queued cancellation skips work")
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
        gate.release(image)
        let remaining = await second.value
        let shared = await third.value
        precondition(remaining.image != nil && remaining.image === shared.image && gate.counts.cancelled == 0,
                     "Remaining views receive the same bitmap from the surviving worker")
        print("PASS: shared bitmap, independent consumer cancellation, prompt cancelled return")
    }

    private static func cancelledWorkerAndRetry() async {
        let gate = DecodeGate()
        let queue = coordinator(gate, limit: 1)
        let image = request("retry")
        let first = Task { await queue.decode(image) }
        await eventually("Initial decode starts") { gate.callCount(image) == 1 }
        first.cancel()
        await eventually("Last consumer leaves") { await queue.activity.consumers == 0 }
        let retry = Task { await queue.decode(image) }
        await eventually("Retry queues behind cancelled work") { await queue.activity.queued == 1 }
        precondition(gate.callCount(image) == 1 && gate.counts.active == 1,
                     "Cancellation does not release an occupied worker slot")
        gate.release(image)
        await eventually("Retry gets its own worker") { gate.callCount(image) == 2 }
        precondition(gate.counts.cancelled == 1)
        gate.releaseAll()
        let result = await retry.value
        precondition(result.image != nil)
        print("PASS: last-consumer cancellation, occupied slot retained, retry gets a fresh worker")
    }

    private static func realImageDecode() async throws {
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
        print("PASS: real ImageIO downsampling to the requested 64px row size")
    }

    static func run() async throws {
        await boundedBurst()
        await sharedConsumers()
        await cancelledWorkerAndRetry()
        try await realImageDecode()
    }
}
