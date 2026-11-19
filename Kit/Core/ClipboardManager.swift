import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardManager {
    /// Marker attached to Kit's own writes so monitoring ignores them.
    static let internalType = ClipboardCapturePolicy.internalType

    private static let pollInterval: TimeInterval = 0.1

    private let store: ClipboardStore
    private let settings: AppSettings
    private let pipeline = ClipboardCapturePipeline()
    private var timer: Timer?
    private var lastObservedChangeCount = 0
    private var captureTail: Task<Void, Never>?
    /// Pasteboard reads run one at a time. Processing stays ordered behind `captureTail`.
    private var readTail: Task<Void, Never>?
    private(set) var isPaused = false

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    isolated deinit {
        timer?.invalidate()
        captureTail?.cancel()
        readTail?.cancel()
    }

    func start() {
        lastObservedChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.pollInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            captureTail?.cancel()
            captureTail = nil
            // Keep the read barrier until synchronous pasteboard access has returned
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
        let sourceBundleID =
            types.contains(ClipboardCapturePolicy.selectionType)
            ? Bundle.main.bundleIdentifier
            : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard ClipboardCapturePolicy.shouldCapture(
            types: types,
            sourceBundleID: sourceBundleID,
            disabledApps: settings.clipboardDisabledApps
        ) else { return }

        let generation = store.captureGeneration
        let disabledApps = settings.clipboardDisabledApps
        let previous = captureTail
        let previousRead = readTail
        let readTask = Task.detached(priority: .utility) { () -> PasteboardSnapshot? in
            _ = await previousRead?.value
            guard !Task.isCancelled else { return nil }
            return await Self.readSnapshot(
                changeCount: changeCount, sourceBundleID: sourceBundleID,
                generation: generation, disabledApps: disabledApps)
        }
        // Retain only completion, not the last snapshot and its potentially large image data
        readTail = Task { _ = await readTask.value }

        captureTail = Task { [weak self] in
            let snapshot = await withTaskCancellationHandler {
                await readTask.value
            } onCancel: {
                readTask.cancel()
            }
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard let snapshot else { return }
            guard
                let capture = await self.pipeline.process(snapshot), !Task.isCancelled
            else { return }

            switch capture.content {
            case .text(let text):
                let kind = await Task.detached(priority: .utility) {
                    ClipboardTextClassifier.kind(for: text)
                }.value
                guard !Task.isCancelled else { return }
                self.store.addText(
                    text, kind: kind, sourceBundleID: capture.sourceBundleID,
                    expectedGeneration: capture.generation)
            case .image(let png):
                await self.store.addImage(
                    png, sourceBundleID: capture.sourceBundleID,
                    expectedGeneration: capture.generation)
            case .files(let urls):
                let supportsImage = await Task.detached(priority: .utility) {
                    ClipboardStore.fileSupportsImagePreview(urls)
                }.value
                guard !Task.isCancelled else { return }
                guard
                    let item = self.store.addFiles(
                        urls, sourceBundleID: capture.sourceBundleID,
                        expectedGeneration: capture.generation, fileIsImage: supportsImage)
                else { return }
                self.store.rememberFileBookmarks(capture.fileBookmarks, for: item.id)
            }
        }
    }

    nonisolated static func readSnapshot(
        changeCount: Int, sourceBundleID: String?, generation: UInt64,
        disabledApps: [String], pasteboardName: NSPasteboard.Name = .general
    ) async -> PasteboardSnapshot? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !Task.isCancelled {
            let pasteboard = NSPasteboard(name: pasteboardName)
            guard pasteboard.changeCount == changeCount else { return nil }
            let types = pasteboard.types ?? []
            guard ClipboardCapturePolicy.shouldCapture(
                types: types, sourceBundleID: sourceBundleID, disabledApps: disabledApps
            ) else { return nil }

            // Promised images can become readable without changing the pasteboard generation
            // Refresh the types on every attempt, retaining the original source and store generation
            let preferredImageTypes = [NSPasteboard.PasteboardType.png, .tiff].filter(types.contains)
            let imageTypes = preferredImageTypes + types.filter {
                !preferredImageTypes.contains($0)
                    && UTType($0.rawValue)?.conforms(to: .image) == true
            }
            let snapshot = readAvailableSnapshot(
                pasteboard: pasteboard, changeCount: changeCount, imageTypes: imageTypes,
                sourceBundleID: sourceBundleID, generation: generation
            )
            if let snapshot {
                let waitingForImage = !imageTypes.isEmpty && snapshot.imageData == nil
                    && snapshot.fileURLs.isEmpty
                if !waitingForImage && !types.isEmpty { return snapshot }
            }
            guard ContinuousClock.now < deadline else { return snapshot }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func readAvailableSnapshot(
        pasteboard: NSPasteboard, changeCount: Int, imageTypes: [NSPasteboard.PasteboardType],
        sourceBundleID: String?, generation: UInt64
    ) -> PasteboardSnapshot? {
        guard !Task.isCancelled else { return nil }
        guard pasteboard.changeCount == changeCount else { return nil }
        var fileURLs: [URL] = []
        var fileBookmarks: [String: Data] = [:]
        let legacyFileURLsType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let types = pasteboard.types ?? []
        // Object coercion can turn a path string into an NSURL, so require a file representation.
        if types.contains(.fileURL) || types.contains(legacyFileURLsType) {
            let originalURLs =
                (pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [NSURL]) ?? []
            fileBookmarks = ClipboardFileAccess.capture(originalURLs)
            fileURLs = originalURLs.map { $0 as URL }
            if fileURLs.isEmpty,
                let paths = pasteboard.propertyList(forType: legacyFileURLsType) as? [String]
            {
                let legacyURLs = paths.map { NSURL(fileURLWithPath: $0) }
                fileBookmarks = ClipboardFileAccess.capture(legacyURLs)
                fileURLs = legacyURLs.map { $0 as URL }
            }
            guard !fileURLs.isEmpty else { return nil }
        }
        if !fileURLs.isEmpty {
            guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return nil }
            return PasteboardSnapshot(
                text: nil, imageData: nil, imageIsPNG: false, fileURLs: fileURLs,
                sourceBundleID: sourceBundleID, generation: generation,
                fileBookmarks: fileBookmarks)
        }

        let text = pasteboard.string(forType: .string)
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
        if imageData == nil,
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
