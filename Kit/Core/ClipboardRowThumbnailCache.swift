import Foundation
import ImageIO

/// Disposable, lossless row images beside the store's immutable originals. All I/O runs
/// on decode workers; the lock also makes deletion invalidate an in-progress write.
final class ClipboardRowThumbnailCache: @unchecked Sendable {
    struct Ticket: Sendable {
        let source: URL
        let destination: URL
        let signature: String
        let generation: UInt64
    }

    private struct Entry {
        let bytes: Int
        var accessed: Date
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var generation: UInt64 = 0
    private var directories: [URL: [URL: Entry]] = [:]

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
        guard let values = try? freshURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        return "\(size)#\(date.timeIntervalSince1970)"
    }

    func ticket(for source: URL) -> Ticket? {
        guard let signature = Self.signature(for: source) else { return nil }
        let suffix = ImageFingerprint.digest(data: Data(signature.utf8))
        let destination = Self.directory(for: source)
            .appendingPathComponent(Self.prefix(for: source) + suffix + ".png")
        return lock.withLock {
            Ticket(source: source, destination: destination, signature: signature, generation: generation)
        }
    }

    func cachedURL(for ticket: Ticket) -> URL? {
        lock.withLock {
            let freshURL = URL(fileURLWithPath: ticket.destination.path)
            guard ticket.generation == generation,
                Self.isCacheDirectory(ticket.destination.deletingLastPathComponent()),
                let values = try? freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            // Persist recency so eviction remains useful after restarting the app.
            let now = Date()
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: ticket.destination.path)
            directories[Self.directory(for: ticket.source)]?[ticket.destination]?.accessed = now
            return ticket.destination
        }
    }

    func store(_ image: CGImage, for ticket: Ticket) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= byteLimit else { return }
        lock.withLock {
            guard ticket.generation == generation, Self.signature(for: ticket.source) == ticket.signature
            else { return }
            let directory = Self.directory(for: ticket.source)
            if !FileManager.default.fileExists(atPath: directory.path) { directories[directory] = nil }
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
                && Self.isCacheDirectory(directory)
            else { return }
            var entries = directories[directory] ?? inventory(in: directory)
            defer { directories[directory] = entries }
            // A replaced source must not leave multiple versions of its thumbnail behind.
            let prefix = Self.prefix(for: ticket.source)
            for url in entries.keys.filter({ $0.lastPathComponent.hasPrefix(prefix) }) {
                if removeFile(url) { entries[url] = nil }
            }
            var bytes = entries.values.reduce(0) { $0 + $1.bytes }
            for (url, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
                guard bytes + data.length > byteLimit else { break }
                if removeFile(url) { bytes -= entry.bytes; entries[url] = nil }
            }
            guard bytes + data.length <= byteLimit else { return }
            if (try? (data as Data).write(to: ticket.destination, options: .atomic)) != nil {
                entries[ticket.destination] = Entry(bytes: data.length, accessed: Date())
            }
        }
    }

    func remove(for source: URL) {
        lock.withLock {
            generation &+= 1
            let prefix = Self.prefix(for: source)
            let directory = Self.directory(for: source)
            guard Self.isCacheDirectory(directory) else { directories[directory] = nil; return }
            var entries = directories[directory] ?? inventory(in: directory)
            for url in entries.keys.filter({ $0.lastPathComponent.hasPrefix(prefix) }) {
                if removeFile(url) { entries[url] = nil }
            }
            // Do not retain empty directories belonging to discarded temporary stores.
            directories[directory] = entries.isEmpty ? nil : entries
        }
    }

    func removeAll(in imagesDirectory: URL) {
        lock.withLock {
            generation &+= 1
            let directory = Self.directory(for: imagesDirectory.appendingPathComponent("unused.png"))
            try? FileManager.default.removeItem(at: directory)
            directories[directory] = nil
        }
    }

    private func removeFile(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    private func inventory(in directory: URL) -> [URL: Entry] {
        guard Self.isCacheDirectory(directory) else { return [:] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            guard url.pathExtension == "png", let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize
            else { return nil }
            return (url, Entry(bytes: bytes, accessed: values.contentModificationDate ?? .distantPast))
        })
    }

    private static func isCacheDirectory(_ directory: URL) -> Bool {
        let freshURL = URL(fileURLWithPath: directory.path)
        guard let values = try? freshURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
