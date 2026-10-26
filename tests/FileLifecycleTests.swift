import AppKit
import Darwin
import Foundation
@testable import Kit

enum FileLifecycleTests {
    private enum FixtureFailure: Error {
        case invalidFixture(String)
    }

    @MainActor
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-file-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try availableFile(in: root.appendingPathComponent("available"))
        try movedFileIsNotFollowed(
            in: root.appendingPathComponent("moved"),
            storeDirectory: root.appendingPathComponent("moved-store"))
        try permanentlyDeletedFileIsUnavailable(
            in: root.appendingPathComponent("deleted"),
            storeDirectory: root.appendingPathComponent("deleted-store"))
        try permissionDeniedFileStaysSilent(
            in: root.appendingPathComponent("permission-denied"),
            storeDirectory: root.appendingPathComponent("permission-denied-store"))
        try partiallyAvailableGroupPreservesHistory(
            in: root.appendingPathComponent("partial"),
            storeDirectory: root.appendingPathComponent("partial-store"))
        try replacementWinsOverMovedBookmark(
            in: root.appendingPathComponent("replaced"),
            storeDirectory: root.appendingPathComponent("replaced-store"))
        try replacementAfterDeletionUsesCurrentPath(
            in: root.appendingPathComponent("recreated"),
            storeDirectory: root.appendingPathComponent("recreated-store"))
        try reopenedStorePreservesNormalAndReplacementSemantics(
            in: root.appendingPathComponent("reopened"),
            storeDirectory: root.appendingPathComponent("reopened-store"))
        try await thumbnailFileVersions(in: root.appendingPathComponent("thumbnails"))

        print("PASS: file access lifecycle, history stability, thumbnail refresh and replacement decode")
    }

    @MainActor
    private static func availableFile(in root: URL) throws {
        let path = root.appendingPathComponent("available.txt")
        let store = makeStore(in: root.appendingPathComponent("store"))
        try write(Data("available fixture".utf8), to: path)
        guard let item = store.addFiles([path], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("available file was not stored")
        }
        guard let historical = store.item(id: item.id),
              let lease = ClipboardFileAccess.acquire(historical, store: store, interactive: false)
        else {
            throw FixtureFailure.invalidFixture("available file did not create a lease")
        }

        try TestSupport.expect(lease.urls.count == 1, "A normal file returns one lease URL")
        guard let leaseURL = lease.urls.first else {
            throw FixtureFailure.invalidFixture("normal lease URL was missing")
        }
        try TestSupport.expect(
            (leaseURL as URL).standardizedFileURL == path.standardizedFileURL,
            "A normal file lease points at its recorded path")
        let availableData = try Data(contentsOf: leaseURL as URL)
        try TestSupport.expect(
            availableData == Data("available fixture".utf8),
            "A normal file lease can read the source bytes")
        try TestSupport.expect(
            store.item(id: item.id)?.fileURLs == [path.standardizedFileURL],
            "Acquiring a lease does not rewrite the stored file list")
    }

    @MainActor
    private static func movedFileIsNotFollowed(in root: URL, storeDirectory: URL) throws {
        let original = root.appendingPathComponent("moved.txt")
        let destination = root.appendingPathComponent("elsewhere.txt")
        let store = makeStore(in: storeDirectory)
        try write(Data("moved fixture".utf8), to: original)
        guard let item = store.addFiles([original], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("moved file was not stored")
        }
        try captureBookmarks(for: item, in: store)
        try FileManager.default.moveItem(at: original, to: destination)

        guard let historical = store.item(id: item.id) else {
            throw FixtureFailure.invalidFixture("moved file history disappeared")
        }
        try TestSupport.expect(
            ClipboardFileAccess.acquire(historical, store: store, interactive: false) == nil,
            "A bookmark cannot substitute a file moved away from the recorded path")
        try TestSupport.expect(
            FileManager.default.fileExists(atPath: destination.path),
            "The moved source remains available while its stale history path does not follow it")
        try TestSupport.expect(
            store.item(id: item.id)?.fileURLs == [original.standardizedFileURL],
            "Moving a source does not rewrite the historical path")
    }

    @MainActor
    private static func permanentlyDeletedFileIsUnavailable(
        in root: URL, storeDirectory: URL
    ) throws {
        let path = root.appendingPathComponent("deleted.txt")
        let store = makeStore(in: storeDirectory)
        try write(Data("deleted fixture".utf8), to: path)
        guard let item = store.addFiles([path], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("deleted file was not stored")
        }
        guard ClipboardFileAccess.acquire(item, store: store, interactive: false) != nil else {
            throw FixtureFailure.invalidFixture("deleted file was unavailable before deletion")
        }
        try FileManager.default.removeItem(at: path)

        try TestSupport.expect(
            ClipboardFileAccess.acquire(item, store: store, interactive: false) == nil,
            "A permanently deleted file does not acquire a lease")
        try TestSupport.expect(
            store.item(id: item.id)?.fileURLs == [path.standardizedFileURL],
            "Permanent deletion leaves the historical path unchanged")
    }

    @MainActor
    private static func permissionDeniedFileStaysSilent(
        in root: URL, storeDirectory: URL
    ) throws {
        guard geteuid() != 0 else { return }
        let path = root.appendingPathComponent("permission-denied.txt")
        let store = makeStore(in: storeDirectory)
        try write(Data("permission fixture".utf8), to: path)
        guard let item = store.addFiles([path], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("permission fixture was not stored")
        }

        var metadata = stat()
        guard stat(path.path, &metadata) == 0 else {
            throw FixtureFailure.invalidFixture("permission fixture metadata was unavailable")
        }
        let originalMode = metadata.st_mode & 0o777
        guard chmod(path.path, 0o000) == 0 else {
            throw FixtureFailure.invalidFixture("permission fixture could not remove read access")
        }
        defer { _ = chmod(path.path, originalMode) }

        guard case .needsPermission = ClipboardFileAccess.availability(of: path) else {
            throw FixtureFailure.invalidFixture("chmod fixture did not produce a permission denial")
        }
        try TestSupport.expect(
            ClipboardFileAccess.acquire(item, store: store, interactive: false) == nil,
            "A permission-denied file stays unavailable without starting an interactive grant")
    }

    @MainActor
    private static func partiallyAvailableGroupPreservesHistory(
        in root: URL, storeDirectory: URL
    ) throws {
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let store = makeStore(in: storeDirectory)
        try write(Data("first fixture".utf8), to: first)
        try write(Data("second fixture".utf8), to: second)
        guard let item = store.addFiles([first, second], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("file group was not stored")
        }
        let recordedURLs = item.fileURLs
        try FileManager.default.removeItem(at: second)

        guard let lease = ClipboardFileAccess.acquire(item, store: store, interactive: false) else {
            throw FixtureFailure.invalidFixture("partially available file group did not create a lease")
        }
        try TestSupport.expect(lease.urls.count == 1, "Only the surviving member of a file group is leased")
        guard let leaseURL = lease.urls.first else {
            throw FixtureFailure.invalidFixture("surviving group member was missing from the lease")
        }
        try TestSupport.expect(
            (leaseURL as URL).standardizedFileURL == first.standardizedFileURL,
            "The surviving group member retains its original order and path")
        let firstData = try Data(contentsOf: leaseURL as URL)
        try TestSupport.expect(
            firstData == Data("first fixture".utf8),
            "The surviving group member is readable through its lease")
        try TestSupport.expect(
            store.item(id: item.id)?.fileURLs == recordedURLs && recordedURLs.count == 2,
            "Partial availability does not remove missing files from history")
    }

    @MainActor
    private static func replacementWinsOverMovedBookmark(
        in root: URL, storeDirectory: URL
    ) throws {
        let original = root.appendingPathComponent("replace.txt")
        let moved = root.appendingPathComponent("old.txt")
        let store = makeStore(in: storeDirectory)
        let oldData = Data("OLD".utf8)
        let newData = Data("NEW".utf8)
        try write(oldData, to: original)
        guard let item = store.addFiles([original], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("replacement file was not stored")
        }
        try captureBookmarks(for: item, in: store)
        try FileManager.default.moveItem(at: original, to: moved)
        try write(newData, to: original)

        guard let lease = ClipboardFileAccess.acquire(item, store: store, interactive: false) else {
            throw FixtureFailure.invalidFixture("replacement at the original path did not create a lease")
        }
        guard let leaseURL = lease.urls.first else {
            throw FixtureFailure.invalidFixture("replacement lease URL was missing")
        }
        try TestSupport.expect(
            (leaseURL as URL).standardizedFileURL == original.standardizedFileURL,
            "A replacement at the recorded path is leased instead of the moved bookmark")
        let leasedNewData = try Data(contentsOf: leaseURL as URL)
        try TestSupport.expect(
            leasedNewData == newData,
            "A replacement at the recorded path exposes the new bytes")
        let movedData = try Data(contentsOf: moved)
        try TestSupport.expect(
            movedData == oldData,
            "The moved bookmark target retains the old bytes")
    }

    @MainActor
    private static func replacementAfterDeletionUsesCurrentPath(
        in root: URL, storeDirectory: URL
    ) throws {
        let path = root.appendingPathComponent("recreate.txt")
        let store = makeStore(in: storeDirectory)
        let newData = Data("NEW".utf8)
        try write(Data("OLD".utf8), to: path)
        guard let item = store.addFiles([path], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("file to recreate was not stored")
        }
        try captureBookmarks(for: item, in: store)
        try FileManager.default.removeItem(at: path)
        try write(newData, to: path)

        guard let lease = ClipboardFileAccess.acquire(item, store: store, interactive: false),
              let leaseURL = lease.urls.first
        else {
            throw FixtureFailure.invalidFixture("recreated file did not create a lease")
        }
        try TestSupport.expect(
            (leaseURL as URL).standardizedFileURL == path.standardizedFileURL,
            "A recreated file uses the current path")
        let recreatedData = try Data(contentsOf: leaseURL as URL)
        try TestSupport.expect(
            recreatedData == newData,
            "A recreated file exposes its current bytes instead of deleted bookmark content")
    }

    @MainActor
    private static func reopenedStorePreservesNormalAndReplacementSemantics(
        in root: URL, storeDirectory: URL
    ) throws {
        let normal = root.appendingPathComponent("normal.txt")
        let replaced = root.appendingPathComponent("stored-bookmark.txt")
        let normalData = Data("normal fixture".utf8)
        let replacementData = Data("NEW after reopen".utf8)
        try write(normalData, to: normal)
        try write(Data("OLD before reopen".utf8), to: replaced)

        var itemID: ClipboardItem.ID?
        do {
            let store = makeStore(in: storeDirectory)
            guard let item = store.addFiles([normal, replaced], sourceBundleID: nil) else {
                throw FixtureFailure.invalidFixture("reopen fixture was not stored")
            }
            try captureBookmarks(for: item, in: store)
            itemID = item.id
        }
        try write(replacementData, to: replaced)

        guard let itemID else {
            throw FixtureFailure.invalidFixture("reopen fixture ID was missing")
        }
        let reopened = makeStore(in: storeDirectory)
        guard let historical = reopened.item(id: itemID) else {
            throw FixtureFailure.invalidFixture("reopened store lost the file history")
        }
        try TestSupport.expect(
            reopened.fileBookmarks(for: itemID).count == 2,
            "Both captured bookmarks survive a store reopen")
        guard let lease = ClipboardFileAccess.acquire(
            historical, store: reopened, interactive: false)
        else {
            throw FixtureFailure.invalidFixture("reopened store could not lease its files")
        }
        try TestSupport.expect(lease.urls.count == 2, "Reopened history leases both available files")
        let leasedURLs = lease.urls.map { ($0 as URL).standardizedFileURL }
        try TestSupport.expect(
            leasedURLs == [normal.standardizedFileURL, replaced.standardizedFileURL],
            "Reopened history preserves file order and current paths")
        let reopenedNormalData = try Data(contentsOf: leasedURLs[0])
        try TestSupport.expect(
            reopenedNormalData == normalData,
            "A normal file remains readable after reopening the store")
        let reopenedReplacementData = try Data(contentsOf: leasedURLs[1])
        try TestSupport.expect(
            reopenedReplacementData == replacementData,
            "A replaced path remains current after reopening the store")
        try TestSupport.expect(
            reopened.item(id: itemID)?.fileURLs == historical.fileURLs,
            "Reopening and leasing do not alter the persisted file list")
    }

    @MainActor
    private static func thumbnailFileVersions(in root: URL) async throws {
        let source = root.appendingPathComponent("versioned.png")
        let first = try pngData(width: 120, height: 80)
        let replacement = try pngData(width: 240, height: 90)
        try write(first, to: source)

        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "The first observation of a thumbnail file records a version change")
        let firstVersion = ImageThumbnail.fileVersion(for: source)
        guard let firstImage = await ImageThumbnail.loadAsync(source, maxPixel: 4_096) else {
            throw FixtureFailure.invalidFixture("The initial PNG could not be decoded")
        }
        try TestSupport.expect(
            imagePixelSize(firstImage) == CGSize(width: 120, height: 80),
            "The initial decode returns the first PNG dimensions")
        try TestSupport.expect(
            !ImageThumbnail.refreshFile(at: source),
            "Repeated observation of unchanged file metadata keeps the version")
        try TestSupport.expect(
            ImageThumbnail.fileVersion(for: source) == firstVersion,
            "An unchanged file retains its current version")

        try write(replacement, to: source)
        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "Replacing the PNG at the same path changes its version")
        let replacementVersion = ImageThumbnail.fileVersion(for: source)
        try TestSupport.expect(
            replacementVersion != firstVersion,
            "The replacement version invalidates the earlier decoded request")
        guard let replacedImage = await ImageThumbnail.loadAsync(source, maxPixel: 4_096) else {
            throw FixtureFailure.invalidFixture("The replacement PNG could not be decoded")
        }
        try TestSupport.expect(
            imagePixelSize(replacedImage) == CGSize(width: 240, height: 90),
            "A current request decodes the replacement PNG rather than the stale image")

        try FileManager.default.removeItem(at: source)
        try TestSupport.expect(
            ImageThumbnail.refreshFile(at: source),
            "Deleting the PNG at a known path changes its version")
        let deletedVersion = ImageThumbnail.fileVersion(for: source)
        try TestSupport.expect(
            deletedVersion != replacementVersion,
            "The deletion version invalidates the replacement decode")
        try TestSupport.expect(
            !ImageThumbnail.refreshFile(at: source),
            "Repeated observation of the same deletion keeps the version")
        try TestSupport.expect(
            ImageThumbnail.fileVersion(for: source) == deletedVersion,
            "An unchanged deletion retains its current version")
        let deletedImage = await ImageThumbnail.loadAsync(source, maxPixel: 4_096)
        try TestSupport.expect(
            deletedImage == nil,
            "A deleted current PNG cannot be served from an older decode")
    }

    @MainActor
    private static func makeStore(in directory: URL) -> ClipboardStore {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClipboardStore(directory: directory, maintenanceInterval: 3_600)
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        store.load()
        return store
    }

    @MainActor
    private static func captureBookmarks(for item: ClipboardItem, in store: ClipboardStore) throws {
        let bookmarks = ClipboardFileAccess.capture(item.fileURLs.map { $0 as NSURL })
        try TestSupport.expect(
            bookmarks.count == item.fileURLs.count,
            "Every fixture file captures a bookmark")
        try TestSupport.expect(
            store.rememberFileBookmarks(bookmarks, for: item.id),
            "Captured bookmarks persist in the isolated store")
        try TestSupport.expect(
            store.fileBookmarks(for: item.id).count == item.fileURLs.count,
            "The isolated store exposes the captured bookmark set")
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
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
        ), let bitmapData = bitmap.bitmapData
        else {
            throw FixtureFailure.invalidFixture("PNG bitmap could not be allocated")
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmapData[offset] = UInt8(truncatingIfNeeded: x + y)
                bitmapData[offset + 1] = UInt8(truncatingIfNeeded: width - x)
                bitmapData[offset + 2] = UInt8(truncatingIfNeeded: height - y)
                bitmapData[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureFailure.invalidFixture("PNG bitmap could not be encoded")
        }
        return data
    }

    private static func imagePixelSize(_ image: NSImage) -> CGSize? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect, context: nil, hints: nil)
        else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
