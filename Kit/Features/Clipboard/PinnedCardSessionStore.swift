import AppKit

struct PinnedCardRecord: Codable, Identifiable {
    struct Frame: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ frame: NSRect) {
            x = frame.origin.x
            y = frame.origin.y
            width = frame.width
            height = frame.height
        }

        var rect: NSRect {
            NSRect(x: x, y: y, width: width, height: height)
        }
    }

    let id: UUID
    var frame: Frame

    var isValid: Bool {
        frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}

/// Small manifest plus one immutable payload file per open card. Payloads are independent from
/// clipboard retention, so an open card survives history cleanup and relaunches after a crash.
@MainActor
final class PinnedCardSessionStore {
    private struct Manifest: Codable {
        let version: Int
        var cards: [PinnedCardRecord]
    }

    private static let version = 1

    private let payloadDirectory: URL
    private let manifestURL: URL
    private(set) var records: [PinnedCardRecord]

    init() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            preconditionFailure("Paste requires a bundle identifier")
        }
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("pinned-cards", isDirectory: true)
        payloadDirectory = root.appendingPathComponent("payloads", isDirectory: true)
        manifestURL = root.appendingPathComponent("session.json")
        try? FileManager.default.createDirectory(
            at: payloadDirectory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            manifest.version == Self.version
        {
            var seen = Set<UUID>()
            records = manifest.cards.filter { $0.isValid && seen.insert($0.id).inserted }
        } else {
            records = []
        }
        removeOrphanedPayloads()
    }

    func writeImagePayload(from source: URL, itemID: UUID) -> URL? {
        let target = payloadURL(itemID: itemID)
        let temporary = payloadDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            return nil
        }
    }

    func imageURL(for record: PinnedCardRecord) -> URL? {
        let url = payloadURL(for: record)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func add(itemID: UUID, frame: NSRect) {
        guard FileManager.default.fileExists(atPath: payloadURL(itemID: itemID).path)
        else { return }
        records.removeAll { $0.id == itemID }
        records.append(
            PinnedCardRecord(
                id: itemID,
                frame: PinnedCardRecord.Frame(frame)
            )
        )
        saveNow()
    }

    func remove(itemID: UUID) {
        guard let record = records.first(where: { $0.id == itemID }) else { return }
        records.removeAll { $0.id == itemID }
        saveNow()
        try? FileManager.default.removeItem(at: payloadURL(for: record))
    }

    @discardableResult
    func updateFrame(itemID: UUID, frame: NSRect) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == itemID }) else { return false }
        let stored = records[index].frame.rect
        guard abs(stored.minX - frame.minX) > 0.5 || abs(stored.minY - frame.minY) > 0.5
            || abs(stored.width - frame.width) > 0.5 || abs(stored.height - frame.height) > 0.5
        else { return false }
        records[index].frame = PinnedCardRecord.Frame(frame)
        return true
    }

    @discardableResult
    func bringToFront(itemID: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == itemID }),
            index != records.endIndex - 1
        else { return false }
        let record = records.remove(at: index)
        records.append(record)
        return true
    }

    func saveNow() {
        let manifest = Manifest(version: Self.version, cards: records)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func payloadURL(for record: PinnedCardRecord) -> URL {
        payloadURL(itemID: record.id)
    }

    private func payloadURL(itemID: UUID) -> URL {
        payloadDirectory.appendingPathComponent(
            itemID.uuidString + ".png",
            isDirectory: false)
    }

    private func removeOrphanedPayloads() {
        let expected = Set(records.map { payloadURL(for: $0).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: nil,
            options: [])
        else { return }
        for file in files where !expected.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

