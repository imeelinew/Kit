import AppKit
import Combine
import SQLite3

enum AppLocalization {
    static func string(_ key: String, locale: Locale) -> String { key }
}

actor ImageTextOCRProbe {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<ClipboardImageOCRResult, Never>] = []

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
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK,
                     String(cString: sqlite3_errmsg(db)))
    }

    static func count(_ directory: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func png(_ color: NSColor = .red) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.deviceRGB)!
        let pixel = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
            .map { UInt8(($0 * 255).rounded()) }
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * bitmap.bytesPerRow + x * 4
                for component in 0..<4 { bitmap.bitmapData![offset + component] = pixel[component] }
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func databaseSearch(
        _ directory: URL, _ query: String, includesImageText: Bool,
        kind: ClipboardItem.Kind? = nil, stackID: UUID? = nil,
        after: ClipboardSearchCursor? = nil, limit: Int = 20
    ) -> ClipboardSearchPage {
        let page = ClipboardSearch.queryDatabase(
            path: directory.appendingPathComponent("clipboard.sqlite3").path,
            query: query, kind: kind, stackID: stackID, after: after, limit: limit,
            includesImageText: includesImageText)
        precondition(page != nil, "Every SQL branch binds all filters correctly")
        return page!
    }

    @MainActor
    static func toggleAndSearch(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.setImageTextSearchEnabled(false)
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        let imageID = store.items.first!.id
        let callsBefore = await probe.calls
        precondition(callsBefore == 0 && store.imageTextIndexState == .none)
        var observedRevisions = 0
        let observer = store.$revision.dropFirst().sink { _ in observedRevisions += 1 }
        store.setImageTextSearchEnabled(true)
        precondition(observedRevisions > 0 && store.imageTextIndexState == .indexing)
        await probe.waitForCall(1)
        await probe.release(.recognized("账 户管理 ＰａｄｄｌｅＯＣＲ 50%_off"))
        await store.waitForImageOCR()
        precondition(store.imageTextIndexState == .indexed)
        let text = store.addText("账户管理 PaddleOCR 50%_off", kind: .text, sourceBundleID: nil)!
        let secondText = store.addText("账户管理 PaddleOCR 50%_off extra", kind: .text, sourceBundleID: nil)!
        await store.waitForSearchMetadata()
        let stack = store.createStack(name: "Saved")!
        store.assign(imageID, to: stack.id)
        execute(directory, "UPDATE items SET custom_title = '旅行备份' WHERE id = '\(imageID)'")
        store.load()
        let queries = ["账", "账户", "账户管理", "账 户", "zhanghu", "zh", "PaddleOCR", "ＰａｄｄｌｅＯＣＲ", "0%", "%_"]
        for query in queries {
            let page = await store.searchAsync(query, after: nil, limit: 20)
            precondition(page.items.contains { $0.id == imageID }, "Enabled OCR: \(query)")
        }
        let beforeDisable = observedRevisions
        store.setImageTextSearchEnabled(false)
        precondition(observedRevisions > beforeDisable && store.imageTextIndexState == .indexed)
        for query in queries {
            let page = await store.searchAsync(query, after: nil, limit: 20)
            precondition(!page.items.contains { $0.id == imageID }, "Disabled resident OCR: \(query)")
            let databasePage = databaseSearch(directory, query, includesImageText: false)
            precondition(!databasePage.items.contains { $0.id == imageID }, "Disabled database OCR: \(query)")
        }
        for query in ["账", "账户管理", "zh", "zhanghu", "PaddleOCR", "%_"] {
            let page = await store.searchAsync(query, after: nil, limit: 20)
            precondition(Set(page.items.map(\.id)) == [text.id, secondText.id], "Text search remains intact")
        }
        for query in ["zh", "zhanghu"] {
            let first = databaseSearch(directory, query, includesImageText: false, kind: .text, limit: 1)
            precondition(first.items.count == 1 && first.nextCursor != nil)
            let second = databaseSearch(directory, query, includesImageText: false, kind: .text,
                                        after: first.nextCursor, limit: 1)
            precondition(Set((first.items + second.items).map(\.id)) == [text.id, secondText.id])
            precondition(second.nextCursor == nil)
        }
        precondition(databaseSearch(directory, "旅行备份", includesImageText: false,
                                    kind: .image, stackID: stack.id).items.map(\.id) == [imageID])
        precondition(databaseSearch(directory, "", includesImageText: false,
                                    kind: .image, stackID: stack.id, limit: 1).items.map(\.id) == [imageID])
        precondition(store.items.first { $0.id == imageID }!.matches("旅行备份", includeImageText: false))
        store.setImageTextSearchEnabled(true)
        await store.waitForImageOCR()
        let callsAfter = await probe.calls
        precondition(callsAfter == 1, "Enabling preserves completed indices")
        let restored = await store.searchAsync("zhanghu", kind: .image, after: nil, limit: 20)
        precondition(restored.items.map(\.id) == [imageID])
        withExtendedLifetime(observer) {}
        print("PASS: capture gating, OCR/pinyin search gating, titles, filters, paging, search revisions, re-enable")
    }

    @MainActor
    static func clearAndUndo(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.load()
        await store.addImage(png(), sourceBundleID: "original")
        await probe.waitForCall(1)
        await probe.release(.recognized("账户管理"))
        await store.waitForImageOCR()
        let image = store.items.first!
        let text = store.addText("账户管理", kind: .text, sourceBundleID: nil)!
        await store.waitForSearchMetadata()
        execute(directory, """
            CREATE TRIGGER reject_index_clear BEFORE UPDATE OF ocr_text ON items
            WHEN new.ocr_text IS NULL BEGIN SELECT RAISE(ABORT, 'test clear failure'); END;
            """)
        precondition(!store.clearImageTextIndex())
        precondition(store.imageTextIndexState == .indexed && store.item(id: image.id)?.imageOCR?.text != nil)
        execute(directory, "DROP TRIGGER reject_index_clear")
        precondition(store.clearImageTextIndex())
        precondition(store.imageTextIndexState == .none)
        precondition(store.items.first { $0.id == image.id }!.imageOCR?.status == .complete)
        precondition(!store.items.first { $0.id == image.id }!.matches("zhanghu"))
        let page = await store.searchAsync("账户管理", after: nil, limit: 20)
        precondition(page.items.map(\.id) == [text.id], "Cleared images cannot return through the resident overlay")
        precondition(FileManager.default.fileExists(atPath: image.imagePath!))
        precondition(count(directory, "SELECT COUNT(*) FROM image_ocr_fts") == 0)
        execute(directory, "INSERT INTO image_ocr_fts(image_ocr_fts) VALUES('integrity-check')")
        execute(directory, "INSERT INTO items_fts(items_fts, rank) VALUES('integrity-check', 1)")
        store.setImageTextSearchEnabled(false)
        store.setImageTextSearchEnabled(true)
        await store.waitForImageOCR()
        let calls = await probe.calls
        precondition(calls == 1, "Clearing is not undone by enabling")

        precondition(store.rebuildImageTextIndex())
        await probe.waitForCall(2)
        await probe.release(.recognized("重建内容"))
        await store.waitForImageOCR()
        precondition(store.imageTextIndexState == .indexed)
        precondition(store.remove(store.item(id: image.id)!))
        precondition(store.imageTextIndexState == .none)
        precondition(store.clearImageTextIndex())
        let restored = store.undoLastDeletion()!
        await store.waitForImageOCR()
        precondition(restored.imageOCR?.text == nil && store.imageTextIndexState == .none,
                     "Undo never resurrects a cleared OCR snapshot")
        print("PASS: clear failure handling, resident/FTS clearing, image preservation, rebuild, deletion, sanitized undo")
    }

    @MainActor
    static func manualRebuildWhileDisabled(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.setImageTextSearchEnabled(false)
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        await store.addImage(png(.blue), sourceBundleID: nil)
        let historicalIDs = Set(store.items.map(\.id))
        precondition(store.imageTextIndexImageCount() == 2 && store.rebuildImageTextIndex())
        precondition(!store.imageTextSearchEnabled && store.imageTextIndexState == .indexing)
        await probe.waitForCall(1)
        precondition(!store.rebuildImageTextIndex(), "A second rebuild cannot start concurrently")
        await store.addImage(png(.green), sourceBundleID: nil)
        let newID = store.items.first!.id
        await probe.release(.recognized("历史重建"))
        await probe.waitForCall(2)
        precondition(store.imageTextIndexState == .indexing, "Busy state takes precedence over partial indices")
        await probe.release(.recognized("历史重建"))
        await store.waitForImageOCR()
        let calls = await probe.calls
        precondition(calls == 2 && !store.imageTextSearchEnabled && store.imageTextIndexState == .indexed)
        precondition(store.item(id: newID)?.imageOCR == nil, "New captures never join a disabled manual rebuild")
        let disabled = await store.searchAsync("历史重建", after: nil, limit: 20)
        precondition(disabled.items.isEmpty)
        store.setImageTextSearchEnabled(true)
        await probe.waitForCall(3)
        let enabled = await store.searchAsync("历史重建", after: nil, limit: 20)
        precondition(Set(enabled.items.map(\.id)) == historicalIDs, "Completed history is immediately searchable")
        await probe.release(.recognized("新图文字"))
        await store.waitForImageOCR()
        let stack = store.createStack(name: "Images")!
        for item in store.items { store.assign(item.id, to: stack.id) }
        precondition(store.deleteStack(stack.id) && store.imageTextIndexState == .none)
        print("PASS: disabled manual rebuild, serial snapshot, partial/busy state, new captures, immediate recovery, Stack deletion")
    }

    @MainActor
    static func enableDuringManualRebuild(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.setImageTextSearchEnabled(false)
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        await store.addImage(png(.blue), sourceBundleID: nil)
        let firstHistoricalID = store.items.first!.id
        precondition(store.rebuildImageTextIndex())
        await probe.waitForCall(1)
        await store.addImage(png(.green), sourceBundleID: nil)
        let newID = store.items.first!.id
        store.setImageTextSearchEnabled(true)
        await probe.release(.recognized("first historical result"))
        await probe.waitForCall(2)
        precondition(store.item(id: firstHistoricalID)?.imageOCR?.text == "first historical result",
                     "Enabling search must not invalidate a manual recognition already in flight")
        await probe.release(.recognized("new capture takes priority"))
        await probe.waitForCall(3)
        precondition(store.item(id: newID)?.imageOCR?.text == "new capture takes priority",
                     "Enabled captures take priority over the remaining backfill")
        await probe.release(.recognized("last historical result"))
        await store.waitForImageOCR()
        precondition(store.imageTextIndexState == .indexed)
        precondition(store.rebuildImageTextIndex())
        await probe.waitForCall(4)
        store.setImageTextSearchEnabled(false)
        await probe.release(.recognized("cancelled manual result"))
        await store.waitForImageOCR()
        let calls = await probe.calls
        precondition(calls == 4 && !store.imageTextSearchEnabled)
        precondition(store.imageTextIndexState == .indexed)
        let retained = store.items.first { $0.id == newID }!
        precondition(retained.imageOCR?.text == "new capture takes priority",
                     "Cancelling manual work preserves the previous completed index")
        print("PASS: enable during manual rebuild, capture priority, disabling cancels manual work without erasing indices")
    }

    @MainActor
    static func cancellation(in directory: URL) async {
        let probe = ImageTextOCRProbe()
        let store = ClipboardStore(directory: directory, recognizeImage: { await probe.recognize($0) })
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        await probe.waitForCall(1)
        store.setImageTextSearchEnabled(false)
        store.setImageTextSearchEnabled(true)
        await probe.release(.recognized("discarded result"))
        await probe.waitForCall(2)
        let stale = await store.searchAsync("discarded", after: nil, limit: 20)
        precondition(stale.items.isEmpty)
        await probe.release(.recognized("current result"))
        await store.waitForImageOCR()
        precondition(store.items.first?.imageOCR?.attempts == 1)

        precondition(store.rebuildImageTextIndex())
        await probe.waitForCall(3)
        precondition(store.clearImageTextIndex())
        await probe.release(.recognized("late rebuild result"))
        await store.waitForImageOCR()
        precondition(store.imageTextIndexState == .none && store.items.first?.imageOCR?.text == nil)
        let calls = await probe.calls
        precondition(calls == 3, "A stale rebuild cannot repopulate cleared rows")
        print("PASS: rapid off/on, serial cancellation, late rebuild writes discarded")
    }

    @MainActor
    static func migratedClear(in directory: URL) async {
        let original = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("历史图片文字") })
        original.load()
        await original.addImage(png(), sourceBundleID: nil)
        await original.waitForImageOCR()
        execute(directory, "UPDATE items SET ocr_version = 0 WHERE kind = 'image'")
        let reopened = ClipboardStore(directory: directory, recognizeImage: { _ in
            preconditionFailure("A cleared migrated row must not be automatically recognized")
        })
        reopened.setImageTextSearchEnabled(false)
        reopened.load()
        precondition(reopened.imageTextIndexState == .indexed)
        precondition(count(directory, "SELECT COUNT(*) FROM items WHERE ocr_status IS NULL AND ocr_text IS NOT NULL") == 1)
        precondition(reopened.clearImageTextIndex())
        reopened.setImageTextSearchEnabled(true)
        await reopened.waitForImageOCR()
        precondition(reopened.imageTextIndexState == .none)
        precondition(count(directory, "SELECT COUNT(*) FROM items WHERE ocr_status = 'complete' AND ocr_version = 1 AND ocr_text IS NULL") == 1)
        print("PASS: clearing version-migrated pending indices prevents automatic resurrection")
    }

    @MainActor
    static func fullHistoryAndRetention(in directory: URL) async {
        let store = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("历史窗口外") })
        store.setImageTextSearchEnabled(false)
        store.load()
        await store.addImage(png(), sourceBundleID: nil)
        let imageID = store.items.first!.id
        let now = Date().timeIntervalSince1970
        execute(directory, """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 1005)
            INSERT INTO items(id, kind, text, created_at)
            SELECT printf('00000000-0000-0000-0000-%012d', x), 'text', 'resident text', \(now) + x FROM n;
            """)
        store.load()
        precondition(!store.items.contains { $0.kind == .image } && store.imageTextIndexImageCount() == 1)
        precondition(store.rebuildImageTextIndex())
        await store.waitForImageOCR()
        precondition(store.imageTextIndexState == .indexed)
        execute(directory, "UPDATE items SET created_at = 0 WHERE id = '\(imageID)'")
        store.enforceLimits()
        precondition(store.imageTextIndexState == .none && store.imageTextIndexImageCount() == 0)
        precondition(store.rebuildImageTextIndex() && store.imageTextIndexState == .none)
        print("PASS: rebuild/count beyond the resident window, retention deletion, no-image rebuild")
    }

    @MainActor
    static func emptyAndFailure(in directory: URL) async {
        let empty = ClipboardStore(directory: directory.appendingPathComponent("empty"),
                                   recognizeImage: { _ in .recognized("   ") })
        empty.load()
        await empty.addImage(png(), sourceBundleID: nil)
        await empty.waitForImageOCR()
        precondition(empty.imageTextIndexState == .none && empty.items.first?.imageOCR?.status == .empty)
        precondition(empty.rebuildImageTextIndex())
        await empty.waitForImageOCR()
        precondition(empty.imageTextIndexState == .none)
        let failed = ClipboardStore(directory: directory.appendingPathComponent("failed"),
                                    recognizeImage: { _ in .failed })
        failed.load()
        await failed.addImage(png(), sourceBundleID: nil)
        await failed.waitForImageOCR()
        precondition(failed.imageTextIndexState == .none && failed.items.first?.imageOCR?.attempts == 2)
        precondition(failed.rebuildImageTextIndex())
        await failed.waitForImageOCR()
        precondition(failed.imageTextIndexState == .none && failed.items.first?.imageOCR?.attempts == 2)
        let indexed = ClipboardStore(directory: directory.appendingPathComponent("indexed"),
                                     recognizeImage: { _ in .recognized("searchable") })
        indexed.load()
        await indexed.addImage(png(), sourceBundleID: nil)
        await indexed.waitForImageOCR()
        precondition(indexed.imageTextIndexState == .indexed)
        indexed.clearAll()
        precondition(indexed.imageTextIndexState == .none)
        print("PASS: empty images, bounded failures, manual retries, history clear state")
    }

    @MainActor
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-image-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        await toggleAndSearch(in: root.appendingPathComponent("toggle"))
        await clearAndUndo(in: root.appendingPathComponent("clear"))
        await manualRebuildWhileDisabled(in: root.appendingPathComponent("manual"))
        await enableDuringManualRebuild(in: root.appendingPathComponent("enable-during-manual"))
        await cancellation(in: root.appendingPathComponent("cancellation"))
        await migratedClear(in: root.appendingPathComponent("migration"))
        await fullHistoryAndRetention(in: root.appendingPathComponent("history"))
        await emptyAndFailure(in: root.appendingPathComponent("empty-failure"))
    }
}
