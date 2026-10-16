import AppKit
import SQLite3

enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}

actor ImageTextOCRProbe {
    private(set) var calls = 0, waiting: [CheckedContinuation<ClipboardImageOCRResult, Never>] = []

    func recognize(_ url: URL) async -> ClipboardImageOCRResult {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ result: ClipboardImageOCRResult) {
        precondition(!waiting.isEmpty)
        waiting.removeFirst().resume(returning: result)
    }

    func waitForCall(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while calls < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        precondition(calls == count, "Recognition remains serial")
    }
}

@main
struct ImageTextSearchSettingsTests {
    static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
                     String(cString: sqlite3_errmsg(db)))
    }

    static func png(_ color: NSColor = .red) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.deviceRGB)!, pixel = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, 1.0].map { UInt8(($0 * 255).rounded()) }
        for row in 0..<8 {
            for x in 0..<8 { for c in 0..<4 { bitmap.bitmapData![row * bitmap.bytesPerRow + x * 4 + c] = pixel[c] } }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    @MainActor
    static func gating(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.setImageTextSearchEnabled(false)
        store.load(); await store.addImage(png(), sourceBundleID: nil)
        let imageID = store.items.first!.id
        let calls = await probe.calls
        precondition(calls == 0 && store.imageTextIndexState == .none)
        store.setImageTextSearchEnabled(true)
        await probe.waitForCall(1)
        await probe.release(.recognized("账户管理 PaddleOCR 50%_off"))
        await store.waitForImageOCR()
        let enabled = await store.searchAsync("zhanghu", kind: .image, after: nil, limit: 20)
        precondition(enabled.items.map(\.id) == [imageID] && store.imageTextIndexState == .indexed)
        store.setImageTextSearchEnabled(false)
        let disabled = await store.searchAsync("zhanghu", kind: .image, after: nil, limit: 20)
        precondition(disabled.items.isEmpty, "Disabled OCR drops image text from resident search")
        store.setImageTextSearchEnabled(true)
        await store.waitForImageOCR()
        let restored = await probe.calls
        precondition(restored == 1, "Enabling preserves completed indices")
        print("PASS: capture gating while disabled, disabled OCR gating, re-enable preserves completed indices")
    }

    @MainActor
    static func cancelManualWork(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        await probe.waitForCall(1)
        store.setImageTextSearchEnabled(false); store.setImageTextSearchEnabled(true)
        await probe.release(.recognized("discarded result"))
        await probe.waitForCall(2)
        let stale = await store.searchAsync("discarded", after: nil, limit: 20); precondition(stale.items.isEmpty)
        await probe.release(.recognized("current result"))
        await store.waitForImageOCR()
        precondition(store.items.first?.imageOCR?.attempts == 1)
        precondition(store.rebuildImageTextIndex())
        await probe.waitForCall(3)
        precondition(!store.rebuildImageTextIndex(), "A second rebuild cannot start concurrently")
        store.setImageTextSearchEnabled(false)
        await probe.release(.recognized("cancelled manual result"))
        await store.waitForImageOCR()
        let calls = await probe.calls
        precondition(calls == 3 && !store.imageTextSearchEnabled)
        precondition(store.imageTextIndexState == .indexed
                     && store.items.first?.imageOCR?.text == "current result",
                     "Cancelling manual work preserves the previous completed index")
        print("PASS: rapid off/on, serial cancellation, disabling cancels manual work without erasing indices")
    }

    @MainActor
    static func migratedClear(in directory: URL) async {
        let original = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("历史图片文字") }); original.load()
        await original.addImage(png(), sourceBundleID: nil)
        await original.waitForImageOCR()
        execute(directory, "UPDATE items SET ocr_version = 0 WHERE kind = 'image'")
        let reopened = ClipboardStore(directory: directory, recognizeImage: { _ in
            preconditionFailure("A cleared migrated row must not be automatically recognized")
        })
        reopened.setImageTextSearchEnabled(false); reopened.load()
        precondition(reopened.imageTextIndexState == .indexed)
        precondition(reopened.clearImageTextIndex())
        reopened.setImageTextSearchEnabled(true)
        await reopened.waitForImageOCR()
        precondition(reopened.imageTextIndexState == .none)
        print("PASS: clearing version-migrated pending indices prevents automatic resurrection")
    }

    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-image-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        await gating(in: root.appendingPathComponent("gating"))
        await cancelManualWork(in: root.appendingPathComponent("cancellation"))
        await migratedClear(in: root.appendingPathComponent("migration"))
    }
}
