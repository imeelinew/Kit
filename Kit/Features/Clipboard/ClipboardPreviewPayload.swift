import AppKit

/// A complete preview is published together, so image decoding and metadata cannot resize
/// the pane in separate frames. Cached payloads live only for the current palette session.
@MainActor
final class ClipboardPreviewPayload {
    let itemID: ClipboardItem.ID
    let image: NSImage?
    let details: Details
    private let copiedAt: Date
    private let imageURL: URL?
    private let imageVersion: UInt64
    private let fileVersions: [UInt64]
    private let fileVersionLease: ImageThumbnail.FileVersionLease
    private let fileAccess: FileAccessLease?

    enum ContentState: Sendable, Equatable {
        case loading, ready, notFound, unavailablePreview
    }

    struct Details: Sendable {
        var contentState: ContentState = .loading
        var fileAvailability: [ClipboardFileAccess.Availability] = []
        var characters: Int?
        var words: Int?
        var pixelSize: CGSize?
        var fileBytes: Int?
    }

    private static let cache: NSCache<NSUUID, ClipboardPreviewPayload> = {
        let cache = NSCache<NSUUID, ClipboardPreviewPayload>()
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private static var cacheGeneration: UInt64 = 0

    static func purge() {
        cacheGeneration &+= 1
        cache.removeAllObjects()
    }

    private init(
        item: ClipboardItem, image: NSImage?, details: Details,
        imageURL: URL?, imageVersion: UInt64, fileVersions: [UInt64], fileAccess: FileAccessLease?,
        fileVersionLease: ImageThumbnail.FileVersionLease
    ) {
        self.itemID = item.id
        self.image = image
        self.details = details
        self.copiedAt = item.lastCopiedAt
        self.imageURL = imageURL
        self.imageVersion = imageVersion
        self.fileVersions = fileVersions
        self.fileAccess = fileAccess
        self.fileVersionLease = fileVersionLease
    }

    func matches(_ item: ClipboardItem) -> Bool {
        itemID == item.id && copiedAt == item.lastCopiedAt
            && imageVersion == (imageURL.map { ImageThumbnail.fileVersion(for: $0) } ?? 0)
            && fileVersions == item.fileURLs.map { ImageThumbnail.fileVersion(for: $0) }
    }

    var availableFileCount: Int? {
        guard !fileVersions.isEmpty, details.fileAvailability.count == fileVersions.count else { return nil }
        return details.fileAvailability.filter { $0 == .available }.count
    }

    var requiresFilePermission: Bool { details.fileAvailability.contains(.needsPermission) }

    static func cached(for item: ClipboardItem) -> ClipboardPreviewPayload? {
        guard let payload = cache.object(forKey: item.id as NSUUID), payload.matches(item)
        else { return nil }
        return payload
    }

    static func load(
        for item: ClipboardItem, imageURL: URL?, store: ClipboardStore? = nil
    ) async -> ClipboardPreviewPayload {
        let versionLease = ImageThumbnail.FileVersionLease(urls: item.fileURLs)
        let access: FileAccessLease?
        if item.isFileBacked, let store {
            access = await ClipboardFileAccess.acquire(item, store: store, interactive: false)
        } else {
            access = nil
        }
        if item.isFileBacked {
            let changed = await Task.detached(priority: .userInitiated) {
                var changed = false
                for url in item.fileURLs {
                    if ImageThumbnail.refreshFile(at: url) { changed = true }
                }
                return changed
            }.value
            if let store { await store.refreshFileReference(item) }
            if changed {
                NotificationCenter.default.post(name: ImageThumbnail.fileDidChange, object: nil)
            }
        }
        if let hit = cached(for: item) { return hit }
        let generation = cacheGeneration
        let imageVersion = imageURL.map { ImageThumbnail.fileVersion(for: $0) } ?? 0
        let fileVersions = item.fileURLs.map { ImageThumbnail.fileVersion(for: $0) }
        let detailsTask = Task.detached(priority: .userInitiated) {
            var details = Details()
            guard !Task.isCancelled else { return details }
            details.fileAvailability = item.fileURLs.map { ClipboardFileAccess.availability(of: $0) }
            if let text = item.text {
                details.characters = text.utf16.count
                var count = 0
                var inWord = false
                for scalar in text.unicodeScalars {
                    guard !Task.isCancelled else { return details }
                    let separator = CharacterSet.whitespacesAndNewlines.contains(scalar)
                    if !separator && !inWord { count += 1 }
                    inWord = !separator
                }
                details.words = count
            }
            if let imageURL,
                FileManager.default.fileExists(atPath: imageURL.path)
            {
                details.pixelSize = ImageThumbnail.pixelSize(of: imageURL)
                details.fileBytes = try? URL(fileURLWithPath: imageURL.path)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize
            } else if item.isFileBacked {
                var totalBytes = 0
                var foundSize = false
                for url in item.fileURLs {
                    let freshURL = URL(fileURLWithPath: url.path)
                    guard let values = try? freshURL.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]),
                        values.isRegularFile == true,
                        let size = values.fileSize
                    else { continue }
                    totalBytes += size
                    foundSize = true
                }
                details.fileBytes = foundSize ? totalBytes : nil
            }
            return details
        }
        let payload = await withTaskCancellationHandler {
            let image: NSImage?
            if let imageURL {
                image = await ImageThumbnail.loadAsync(imageURL, maxPixel: 900)
            } else {
                image = nil
            }
            var details = await detailsTask.value
            if image != nil {
                details.contentState = .ready
            } else if item.isFileBacked {
                if details.fileAvailability.allSatisfy({ $0 == .missing }) {
                    details.contentState = .notFound
                } else if item.hasImagePreview || !details.fileAvailability.contains(.available) {
                    details.contentState = .unavailablePreview
                } else {
                    details.contentState = .ready
                }
            } else if item.hasImagePreview {
                details.contentState = imageURL.map {
                    ClipboardFileAccess.availability(of: $0) == .missing
                } == true ? .notFound : .unavailablePreview
            } else {
                details.contentState = .ready
            }
            return ClipboardPreviewPayload(
                item: item, image: image, details: details,
                imageURL: imageURL, imageVersion: imageVersion,
                fileVersions: fileVersions, fileAccess: access, fileVersionLease: versionLease)
        } onCancel: {
            detailsTask.cancel()
        }
        if !Task.isCancelled, generation == cacheGeneration, payload.matches(item) {
            let cost = (payload.image.map { Int($0.size.width * $0.size.height) * 4 } ?? 1)
                + fileVersions.count * 512
            cache.setObject(payload, forKey: item.id as NSUUID, cost: cost)
        }
        return payload
    }
}
