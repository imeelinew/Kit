import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardManager {
    /// Marker attached to Paste's own writes so monitoring ignores them.
    static let internalType = NSPasteboard.PasteboardType("com.eli.Kit.internal")

    /// Pasteboard markers password managers, browsers, and the OS put on secret copies.
    static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive"),
    ]

    private static let pollInterval: TimeInterval = 0.1

    private let store: ClipboardStore
    private let settings: AppSettings
    private let pipeline = ClipboardCapturePipeline()
    private var timer: Timer?
    private var lastObservedChangeCount = 0
    private var captureTail: Task<Void, Never>?
    private(set) var isPaused = false

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    isolated deinit {
        timer?.invalidate()
        captureTail?.cancel()
    }

    func start() {
        lastObservedChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            captureTail?.cancel()
            captureTail = nil
        }
        // Ignore changes made during the pause instead of importing them when monitoring resumes.
        lastObservedChangeCount = NSPasteboard.general.changeCount
    }

    /// Observe quickly, snapshot off-main, then process captures in observed order. Reading the
    /// source and exclusion list at change detection narrows the old 0.5-second attribution race.
    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = changeCount
        guard !isPaused else { return }

        let types = pasteboard.types ?? []
        if types.contains(Self.internalType) { return }
        if !Set(types).isDisjoint(with: Self.sensitiveTypes) { return }

        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceBundleID, settings.clipboardDisabledApps.contains(sourceBundleID) { return }

        // A browser may advertise several representations while only some of them are readable.
        // Keep every image type so a missing promised PNG can fall through to TIFF or another
        // bitmap representation instead of losing the copy altogether.
        let preferredImageTypes = [NSPasteboard.PasteboardType.png, .tiff].filter(types.contains)
        let imageTypes = preferredImageTypes + types.filter {
            !preferredImageTypes.contains($0)
                && UTType($0.rawValue)?.conforms(to: .image) == true
        }
        let generation = store.captureGeneration
        let previous = captureTail
        let readTask = Task.detached(priority: .utility) {
            Self.readSnapshot(
                changeCount: changeCount, imageTypes: imageTypes,
                sourceBundleID: sourceBundleID, generation: generation)
        }

        captureTail = Task { [weak self] in
            let snapshot = await withTaskCancellationHandler {
                await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard let snapshot else {
                // Some owners publish types just before their promised data becomes readable. If
                // the pasteboard is still on this generation, retry on the next tick.
                if NSPasteboard.general.changeCount == changeCount,
                    self.lastObservedChangeCount == changeCount
                {
                    self.lastObservedChangeCount = .min
                }
                return
            }
            guard
                let capture = await self.pipeline.process(snapshot)
            else { return }

            switch capture.content {
            case .text(let text):
                self.store.addText(
                    text, sourceBundleID: capture.sourceBundleID,
                    expectedGeneration: capture.generation)
            case .image(let png):
                await self.store.addImage(
                    png, sourceBundleID: capture.sourceBundleID,
                    expectedGeneration: capture.generation)
            }
        }
    }

    private nonisolated static func readSnapshot(
        changeCount: Int, imageTypes: [NSPasteboard.PasteboardType],
        sourceBundleID: String?, generation: UInt64
    ) -> PasteboardSnapshot? {
        guard !Task.isCancelled else { return nil }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return nil }
        let text = pasteboard.string(forType: .string)
        let fileURLs =
            (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [NSURL])?.map { $0 as URL } ?? []

        var imageData: Data?
        var imageIsPNG = false
        for type in imageTypes {
            guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return nil }
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            imageData = data
            imageIsPNG = type == .png
            break
        }

        // `NSImage` understands additional browser and AppKit representations (including
        // promised data) that are not necessarily declared as a UTI conforming to `public.image`.
        // Avoid this fallback for copied files so Finder icons cannot replace file contents.
        if imageData == nil, fileURLs.isEmpty,
            let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
                as? [NSImage])?.first,
            let tiff = image.tiffRepresentation, !tiff.isEmpty
        {
            imageData = tiff
        }
        guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return nil }
        return PasteboardSnapshot(
            text: text, imageData: imageData, imageIsPNG: imageIsPNG, fileURLs: fileURLs,
            sourceBundleID: sourceBundleID, generation: generation)
    }
}
