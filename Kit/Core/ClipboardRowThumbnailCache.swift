import Foundation
import ImageIO
import Synchronization

/// Disposable, lossless row images beside the store's immutable originals. All I/O runs
/// on decode workers; the mutex also makes deletion invalidate an in-progress write.
final class ClipboardRowThumbnailCache: Sendable {
    struct Ticket: Sendable {
        let source: URL
        let destination: URL
        let signature: String
        let generation: UInt64
    }

    private struct Entry: Sendable {
        let bytes: Int
        var accessed: Date
    }

    private struct State: Sendable {
        var generation: UInt64 = 0
        var directories: [URL: [URL: Entry]] = [:]
    }

    private let state = Mutex(State())
    private let byteLimit: Int
    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    private static let entryKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    private static let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

    init(byteLimit: Int = 64 * 1024 * 1024) {
        precondition(byteLimit > 0)
        self.byteLimit = byteLimit
    }

    static func directory(for source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(".row-thumbnails-v1", isDirectory: true)
    }

    private static func prefix(for source: URL) -> String {
        ImageFingerprint.digest(data: Data(source.standardizedFileURL.path.utf8)) + "-"
    }

    private static func signature(for source: URL) -> String? {
        // URL resource values can be cached on an existing URL, even after file deletion.
        let freshURL = URL(fileURLWithPath: source.path)
        guard let values = try? freshURL.resourceValues(forKeys: Self.entryKeys),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        return "\(size)#\(date.timeIntervalSince1970)"
    }

    func ticket(for source: URL) -> Ticket? {
        guard let signature = Self.signature(for: source) else { return nil }
        let suffix = ImageFingerprint.digest(data: Data(signature.utf8))
        let destination = Self.directory(for: source)
            .appendingPathComponent(Self.prefix(for: source) + suffix + ".png")
        return state.withLock { state in
            Ticket(source: source, destination: destination, signature: signature, generation: state.generation)
        }
    }

    func cachedURL(for ticket: Ticket) -> URL? {
        state.withLock { state in
            let freshURL = URL(fileURLWithPath: ticket.destination.path)
            guard ticket.generation == state.generation,
                Self.isCacheDirectory(ticket.destination.deletingLastPathComponent()),
                let values = try? freshURL.resourceValues(forKeys: Self.fileKeys),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            // Persist recency so eviction remains useful after restarting the app.
            let now = Date()
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: ticket.destination.path)
            state.directories[Self.directory(for: ticket.source)]?[ticket.destination]?.accessed = now
            return ticket.destination
        }
    }

    func store(_ image: CGImage, for ticket: Ticket) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= byteLimit else { return }
        state.withLock { state in
            guard ticket.generation == state.generation, Self.signature(for: ticket.source) == ticket.signature
            else { return }
            let directory = Self.directory(for: ticket.source)
            if !FileManager.default.fileExists(atPath: directory.path) { state.directories[directory] = nil }
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
                && Self.isCacheDirectory(directory)
            else { return }
            var entries = state.directories[directory] ?? inventory(in: directory)
            defer { state.directories[directory] = entries }
            // A replaced source must not leave multiple versions of its thumbnail behind.
            let prefix = Self.prefix(for: ticket.source)
            for url in entries.keys.filter({ $0.lastPathComponent.hasPrefix(prefix) }) {
                if ClipboardStore.removeImageFile(at: url) { entries[url] = nil }
            }
            var bytes = entries.values.reduce(0) { $0 + $1.bytes }
            for (url, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
                guard bytes + data.length > byteLimit else { break }
                if ClipboardStore.removeImageFile(at: url) { bytes -= entry.bytes; entries[url] = nil }
            }
            guard bytes + data.length <= byteLimit else { return }
            if (try? (data as Data).write(to: ticket.destination, options: .atomic)) != nil {
                entries[ticket.destination] = Entry(bytes: data.length, accessed: Date())
            }
        }
    }

    func remove(for source: URL) {
        state.withLock { state in
            state.generation &+= 1
            let prefix = Self.prefix(for: source)
            let directory = Self.directory(for: source)
            guard Self.isCacheDirectory(directory) else { state.directories[directory] = nil; return }
            var entries = state.directories[directory] ?? inventory(in: directory)
            for url in entries.keys.filter({ $0.lastPathComponent.hasPrefix(prefix) }) {
                if ClipboardStore.removeImageFile(at: url) { entries[url] = nil }
            }
            // Do not retain empty directories belonging to discarded temporary stores.
            state.directories[directory] = entries.isEmpty ? nil : entries
        }
    }

    func removeAll(in imagesDirectory: URL) {
        state.withLock { state in
            state.generation &+= 1
            let directory = Self.directory(for: imagesDirectory.appendingPathComponent("unused.png"))
            try? FileManager.default.removeItem(at: directory)
            state.directories[directory] = nil
        }
    }

    private func inventory(in directory: URL) -> [URL: Entry] {
        guard Self.isCacheDirectory(directory) else { return [:] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(Self.entryKeys),
            options: [.skipsHiddenFiles])) ?? []
        return Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            guard url.pathExtension == "png",
                let values = try? url.resourceValues(forKeys: Self.entryKeys),
                values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize
            else { return nil }
            return (url, Entry(bytes: bytes, accessed: values.contentModificationDate ?? .distantPast))
        })
    }

    private static func isCacheDirectory(_ directory: URL) -> Bool {
        let freshURL = URL(fileURLWithPath: directory.path)
        guard let values = try? freshURL.resourceValues(forKeys: Self.directoryKeys)
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
