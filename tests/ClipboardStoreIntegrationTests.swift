import AppKit
import Foundation
import SQLite3
@testable import Kit

enum ClipboardStoreIntegrationTests {
    private actor OCRAttempts {
        private(set) var count = 0

        func recognize(_ url: URL) -> ClipboardImageOCRResult {
            count += 1
            return .recognized("precision rollback fixture")
        }
    }

    private enum FixtureFailure: Error {
        case invalidFixture(String)
        case sqlite(String)
    }

    @MainActor
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-store-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await metadataContracts(in: root.appendingPathComponent("metadata"))
        try await stackContracts(in: root.appendingPathComponent("stacks"))
        try await fileAndImageContracts(in: root.appendingPathComponent("files"))
        try await clearAllContract(in: root.appendingPathComponent("clear-all"))
        try await migrationAndCorruptionContract(in: root.appendingPathComponent("migration"))
        try await undoEdgeContracts(in: root.appendingPathComponent("undo"))
        try await nonresidentHistory(in: root.appendingPathComponent("history-window"))
        try await imageOCRTimestampRoundTrip(in: root.appendingPathComponent("ocr-precision"))
    }

    @MainActor
    private static func imageOCRTimestampRoundTrip(in directory: URL) async throws {
        let attempts = OCRAttempts()
        let store = ClipboardStore(directory: directory, recognizeImage: { await attempts.recognize($0) })
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        await store.addImage(try pngData(red: 20, green: 50, blue: 100), sourceBundleID: nil)
        let item = store.items.first!
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_1)
        let persisted = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970)
        try TestSupport.expect(timestamp != persisted,
                               "Fixture exposes precision loss across the SQLite epoch round trip")
        try TestSupport.expect(store.recordHistoryAction(id: item.id, at: timestamp),
                               "Fixture installs the precise in-memory timestamp")
        try executeDatabase(in: directory, """
            CREATE TRIGGER reject_ocr BEFORE UPDATE OF ocr_text ON items
            BEGIN SELECT RAISE(ABORT, 'precision fixture'); END
            """)
        store.setImageTextSearchEnabled(true)
        await store.waitForImageOCR()
        let failedCalls = await attempts.count
        try TestSupport.expect(failedCalls == 1 && store.item(id: item.id)?.imageOCR == nil,
                               "A failed OCR write retries its result without recognizing the same pixels again")
        try executeDatabase(in: directory, "DROP TRIGGER reject_ocr")
        store.load()
        await store.waitForImageOCR()
        let recoveredCalls = await attempts.count
        try TestSupport.expect(recoveredCalls == 2
                               && store.item(id: item.id)?.imageOCR?.text == "precision rollback fixture",
                               "Pending OCR resumes and commits after the write failure is removed")
    }

    @MainActor
    private static func nonresidentHistory(in directory: URL) async throws {
        let store = makeStore(in: directory)
        var inserted: [ClipboardItem] = []
        for index in 0..<1_005 {
            guard let item = store.addText("window entry \(index)", kind: .text, sourceBundleID: "fixture") else {
                throw FixtureFailure.invalidFixture("history window insert \(index)")
            }
            inserted.append(item)
        }
        await store.waitForSearchMetadata()
        let oldest = inserted[0]
        try TestSupport.expect(store.items.count == 1_000 && !store.items.contains { $0.id == oldest.id },
                               "The resident history is bounded while older rows remain on disk")
        let fetched = store.item(id: oldest.id)
        try TestSupport.expect(fetched?.id == oldest.id && fetched?.text == oldest.text
                               && fetched?.copyCount == oldest.copyCount,
                               "Item lookup reaches nonresident history")
        let page = await store.searchAsync("window entry 0", after: nil, limit: 10)
        try TestSupport.expect(page.items.map(\.id) == [oldest.id], "Search reaches rows outside the resident window")
        var allIDs: [UUID] = []
        var cursor: ClipboardSearchCursor?
        repeat {
            let next = await store.searchAsync("", after: cursor, limit: 137)
            allIDs.append(contentsOf: next.items.map(\.id))
            cursor = next.nextCursor
            try TestSupport.expect(allIDs.count <= inserted.count, "Nonresident pagination terminates without duplicate pages")
        } while cursor != nil
        try TestSupport.expect(allIDs == inserted.reversed().map(\.id),
                               "Cursor pagination preserves all history beyond the resident limit")
        let recopy = store.addText("window entry 0", kind: .text, sourceBundleID: "fixture")
        try TestSupport.expect(recopy?.id == oldest.id && recopy?.copyCount == 2,
                               "Recopy deduplicates a row that is no longer resident")
        try TestSupport.expect(store.items.first?.id == oldest.id && store.items.count == 1_000,
                               "Nonresident recopy moves to the front without growing the memory window")
        await store.waitForSearchMetadata()
    }

    @MainActor
    private static func metadataContracts(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = makeStore(in: directory)
        let text = "第一行 👩🏽‍💻 e\u{301}\n第二行"

        guard let created = store.addText(text, kind: .markdown, sourceBundleID: "fixture.editor") else {
            throw FixtureFailure.invalidFixture("text item was not created")
        }
        let recopied = store.addText(text, kind: .text, sourceBundleID: "fixture.editor")
        try TestSupport.expect(recopied?.id == created.id, "exact Unicode recopy reuses the same row")
        try TestSupport.expect(
            recopied?.copyCount == 2 && recopied?.kind == .text,
            "recopy updates the copy count and observable kind")
        // SQLite Unix-time round trips may lose a fraction of a microsecond
        try TestSupport.expect(
            recopied.map { abs($0.firstCopiedAt.timeIntervalSince(created.firstCopiedAt)) < 0.000_001 } == true,
            "recopy preserves the original capture date")

        guard let stack = store.createStack(name: "保存位置") else {
            throw FixtureFailure.invalidFixture("metadata stack was not created")
        }
        store.assign(created.id, to: stack.id)
        try executeDatabase(
            in: directory,
            """
            UPDATE items SET custom_title = '自定义标题 🧪'
            WHERE id = '\(created.id.uuidString)'
            """)
        store.load()

        guard let titled = store.item(id: created.id) else {
            throw FixtureFailure.invalidFixture("titled item was not reloaded")
        }
        try TestSupport.expect(titled.customTitle == "自定义标题 🧪", "custom title persists")
        try TestSupport.expect(
            store.stackID(for: titled.id) == stack.id,
            "metadata reload keeps stack membership")
        let titlePage = await store.searchAsync("自定义标题", after: nil, limit: 10)
        try TestSupport.expect(
            titlePage.items.map(\.id) == [created.id],
            "persisted custom title participates in search")

        guard let fallback = store.addText("fallback title\nsecond line", kind: .text, sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("fallback item was not created")
        }
        try executeDatabase(
            in: directory,
            """
            UPDATE items SET custom_title = '   '
            WHERE id = '\(fallback.id.uuidString)'
            """)
        store.load()
        guard let emptyTitled = store.item(id: fallback.id) else {
            throw FixtureFailure.invalidFixture("fallback item was not reloaded")
        }
        try TestSupport.expect(
            emptyTitled.customTitle == "   ",
            "whitespace custom title remains represented in storage")
        try TestSupport.expect(
            emptyTitled.displayTitle(locale: Locale(identifier: "en")) == "fallback title",
            "whitespace custom title falls back to copied content")

        let reopened = makeStore(in: directory)
        guard let persisted = reopened.item(id: created.id) else {
            throw FixtureFailure.invalidFixture("item did not survive store reopen")
        }
        try TestSupport.expect(
            persisted.text == text && persisted.customTitle == "自定义标题 🧪",
            "text and custom title survive a store reopen")
        try TestSupport.expect(
            reopened.stackID(for: created.id) == stack.id,
            "stack membership survives a store reopen")

        try TestSupport.expect(reopened.remove(persisted), "stored item can be removed")
        try TestSupport.expect(reopened.item(id: created.id) == nil, "removed item disappears from item lookup")
        let restored = reopened.undoLastDeletion()
        try TestSupport.expect(restored?.id == created.id, "removed item can be restored")
        try TestSupport.expect(
            restored?.customTitle == "自定义标题 🧪"
                && reopened.stackID(for: created.id) == stack.id,
            "undo restores persisted title and stack metadata")
    }

    @MainActor
    private static func stackContracts(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = makeStore(in: directory)

        try TestSupport.expect(store.createStack(name: "") == nil, "empty stack name is rejected")
        try TestSupport.expect(store.createStack(name: " \n\t ") == nil, "whitespace stack name is rejected")
        guard let first = store.createStack(name: "  工作 🗂️  "),
            let second = store.createStack(name: "档案 🗄️")
        else {
            throw FixtureFailure.invalidFixture("Unicode stacks were not created")
        }
        try TestSupport.expect(first.name == "工作 🗂️", "stack name is trimmed")
        try TestSupport.expect(
            store.stacks.map(\.name) == ["工作 🗂️", "档案 🗄️"],
            "stack creation order is observable")

        guard let moved = store.addText("moved member", kind: .text, sourceBundleID: nil),
            let removedMember = store.addText("removed member", kind: .text, sourceBundleID: nil),
            let survivor = store.addText("not in a stack", kind: .text, sourceBundleID: nil)
        else {
            throw FixtureFailure.invalidFixture("stack member fixtures were not created")
        }
        store.assign(moved.id, to: first.id)
        store.assign(removedMember.id, to: first.id)
        store.assign(moved.id, to: second.id)
        try TestSupport.expect(
            store.stackID(for: moved.id) == second.id
                && store.stackID(for: removedMember.id) == first.id,
            "an item belongs to only its latest assigned stack")
        try TestSupport.expect(store.removeFromStack(removedMember.id), "known stack membership can be removed")
        try TestSupport.expect(store.removeFromStack(removedMember.id), "removing missing stack membership is idempotent")
        try TestSupport.expect(store.stackID(for: removedMember.id) == nil, "removed membership is no longer observed")

        try TestSupport.expect(!store.renameStack(first.id, to: " \n "), "empty stack rename is rejected")
        try TestSupport.expect(store.renameStack(first.id, to: "  重命名 📚  "), "Unicode stack rename succeeds")
        try TestSupport.expect(
            store.stacks.first(where: { $0.id == first.id })?.name == "重命名 📚",
            "renamed stack is trimmed in memory")

        let reopened = makeStore(in: directory)
        try TestSupport.expect(
            reopened.stacks.map(\.name) == ["重命名 📚", "档案 🗄️"],
            "stacks and their order survive reload")
        try TestSupport.expect(
            reopened.stackID(for: moved.id) == second.id,
            "membership survives reload")

        let imageData = try pngData(red: 220, green: 20, blue: 80)
        await reopened.addImage(imageData, sourceBundleID: nil)
        guard let image = reopened.items.first(where: {
            $0.kind == .image && $0.imagePath != nil
        }), let imageURL = reopened.imageURL(for: image)
        else {
            throw FixtureFailure.invalidFixture("cascade image was not created")
        }
        reopened.assign(image.id, to: second.id)
        try TestSupport.expect(FileManager.default.fileExists(atPath: imageURL.path), "owned image exists before cascade")
        try TestSupport.expect(reopened.deleteStack(second.id), "stack deletion succeeds")
        try TestSupport.expect(reopened.item(id: moved.id) == nil, "stack deletion removes assigned text")
        try TestSupport.expect(reopened.item(id: image.id) == nil, "stack deletion removes assigned image row")
        try TestSupport.expect(
            !FileManager.default.fileExists(atPath: imageURL.path),
            "stack deletion removes the assigned owned image file")
        try TestSupport.expect(reopened.item(id: survivor.id) != nil, "stack deletion preserves unassigned history")
        try TestSupport.expect(reopened.stackID(for: moved.id) == nil, "cascade clears deleted membership")
        try TestSupport.expect(!reopened.deleteStack(second.id), "deleting a missing stack is rejected")

        let afterCascade = makeStore(in: directory)
        try TestSupport.expect(
            afterCascade.stacks.map(\.id) == [first.id],
            "stack removal persists")
        try TestSupport.expect(
            afterCascade.item(id: moved.id) == nil && afterCascade.item(id: survivor.id) != nil,
            "cascade row changes persist")
    }

    @MainActor
    private static func fileAndImageContracts(in directory: URL) async throws {
        let storeDirectory = directory.appendingPathComponent("store")
        let fixtures = directory.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

        let textURL = fixtures.appendingPathComponent("notes.txt")
        let secondURL = fixtures.appendingPathComponent("second.txt")
        let imageFileURL = fixtures.appendingPathComponent("external.png")
        let imageData = try pngData(red: 10, green: 180, blue: 90)
        try Data("fixture text".utf8).write(to: textURL)
        try Data("second fixture".utf8).write(to: secondURL)
        try imageData.write(to: imageFileURL)

        let store = makeStore(in: storeDirectory)
        try TestSupport.expect(store.addFiles([], sourceBundleID: nil) == nil, "empty file list is rejected")
        try TestSupport.expect(
            store.addFiles([URL(string: "https://example.com/file.txt")!], sourceBundleID: nil) == nil,
            "non-file URL is rejected")

        guard let fileItem = store.addFiles([textURL], sourceBundleID: "fixture.finder") else {
            throw FixtureFailure.invalidFixture("file item was not created")
        }
        let normalizedVariant = URL(
            fileURLWithPath: fixtures.appendingPathComponent("nested/../notes.txt").path)
        let normalizedRecopy = store.addFiles(
            [normalizedVariant], sourceBundleID: "fixture.finder")
        try TestSupport.expect(normalizedRecopy?.id == fileItem.id, "normalized file URL recopy reuses item")
        try TestSupport.expect(normalizedRecopy?.copyCount == 2, "file recopy increments copy count")
        try TestSupport.expect(
            normalizedRecopy?.fileURLs == [textURL.standardizedFileURL],
            "file URL is stored in standardized form")

        guard let bundle = store.addFiles(
            [textURL, secondURL], sourceBundleID: nil)
        else {
            throw FixtureFailure.invalidFixture("multi-file item was not created")
        }
        try TestSupport.expect(bundle.kind == .file, "multiple files use the file kind")
        try TestSupport.expect(
            bundle.fileURLs == [textURL.standardizedFileURL, secondURL.standardizedFileURL],
            "multi-file order is preserved")

        guard let fileImage = store.addFiles([imageFileURL], sourceBundleID: nil) else {
            throw FixtureFailure.invalidFixture("file-backed image was not created")
        }
        try TestSupport.expect(
            fileImage.kind == .image && fileImage.imagePath == nil
                && store.imageURL(for: fileImage) == imageFileURL.standardizedFileURL,
            "single image file remains externally owned")
        try TestSupport.expect(store.remove(fileImage), "file-backed image can be removed")
        try TestSupport.expect(
            FileManager.default.fileExists(atPath: imageFileURL.path),
            "removing a file-backed image does not delete its source file")

        await store.addImage(imageData, sourceBundleID: nil)
        guard let ownedImage = store.items.first(where: {
            $0.kind == .image && $0.imagePath != nil
        }), let ownedURL = store.imageURL(for: ownedImage)
        else {
            throw FixtureFailure.invalidFixture("owned image was not created")
        }
        let ownedData = try Data(contentsOf: ownedURL)
        try TestSupport.expect(ownedData == imageData, "owned image bytes are persisted")
        try TestSupport.expect(
            ownedURL.deletingLastPathComponent().standardizedFileURL
                == storeDirectory.appendingPathComponent("images").standardizedFileURL,
            "owned image is isolated inside its store directory")

        await store.addImage(imageData, sourceBundleID: nil)
        let ownedImages = store.items.filter { $0.kind == .image && $0.imagePath != nil }
        try TestSupport.expect(ownedImages.count == 1, "identical image data does not create a duplicate row")
        try TestSupport.expect(ownedImages.first?.copyCount == 2, "identical image data increments copy count")
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: storeDirectory.appendingPathComponent("images"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
        try TestSupport.expect(imageFiles.count == 1, "identical image data does not orphan a second file")
        await store.waitForImageOCR()

        guard let stack = store.createStack(name: "Files") else {
            throw FixtureFailure.invalidFixture("file isolation stack was not created")
        }
        store.assign(bundle.id, to: stack.id)
        let staleGeneration = store.captureGeneration
        store.clearAll()
        try TestSupport.expect(store.items.isEmpty, "clear all removes every history item")
        try TestSupport.expect(
            store.stacks.map(\.id) == [stack.id],
            "clear all keeps empty stacks available")
        try TestSupport.expect(store.stackID(for: bundle.id) == nil, "clear all removes memberships")
        try TestSupport.expect(!store.canUndoDeletion, "clear all invalidates undo")
        try TestSupport.expect(
            !FileManager.default.fileExists(atPath: ownedURL.path),
            "clear all removes owned image bytes")
        try TestSupport.expect(
            FileManager.default.fileExists(atPath: textURL.path)
                && FileManager.default.fileExists(atPath: secondURL.path)
                && FileManager.default.fileExists(atPath: imageFileURL.path),
            "clear all leaves external files untouched")
        try TestSupport.expect(
            store.addText(
                "stale capture", kind: .text, sourceBundleID: nil,
                expectedGeneration: staleGeneration) == nil,
            "capture generation rejects work started before clear all")

        let reopened = makeStore(in: storeDirectory)
        try TestSupport.expect(reopened.items.isEmpty, "clear all remains empty after reload")
        try TestSupport.expect(reopened.stacks.map(\.name) == ["Files"], "kept stack persists after reload")
    }

    @MainActor
    private static func clearAllContract(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = makeStore(in: directory)
        guard let text = store.addText("clear fixture", kind: .text, sourceBundleID: nil),
            let stack = store.createStack(name: "Persistent")
        else {
            throw FixtureFailure.invalidFixture("clear all fixtures were not created")
        }
        store.assign(text.id, to: stack.id)
        let oldGeneration = store.captureGeneration
        let revision = store.revision

        store.clearAll()
        try TestSupport.expect(store.captureGeneration > oldGeneration, "clear all advances capture generation")
        try TestSupport.expect(store.revision > revision, "clear all publishes a visible revision")
        try TestSupport.expect(store.item(id: text.id) == nil, "cleared item cannot be looked up")
        try TestSupport.expect(
            store.addText(
                "delayed", kind: .text, sourceBundleID: nil,
                expectedGeneration: oldGeneration) == nil,
            "old capture generation stays rejected after clear all")
    }

    @MainActor
    private static func migrationAndCorruptionContract(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let titledID = UUID()
        let fallbackID = UUID()
        let badUUIDID = UUID()
        let badFileID = UUID()
        let laterCorruptID = UUID()
        let stackID = UUID()

        try executeDatabase(
            in: directory,
            """
            CREATE TABLE items(
              id TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL,
              text TEXT,
              image_path TEXT,
              created_at REAL NOT NULL,
              source_app TEXT,
              image_fingerprint TEXT,
              custom_title TEXT,
              pinyin TEXT,
              pinyin_initials TEXT,
              last_used_at REAL
            );
            CREATE TABLE stacks(
              id TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              position INTEGER NOT NULL
            );
            CREATE TABLE stack_items(
              item_id TEXT NOT NULL UNIQUE,
              stack_id TEXT NOT NULL
            );
            INSERT INTO items(
              id, kind, text, created_at, source_app, custom_title
            ) VALUES(
              '\(titledID.uuidString)', 'text', 'legacy unicode 文字', 1700000000,
              'legacy.app', '旧标题 🧭'
            );
            INSERT INTO items(
              id, kind, text, created_at, custom_title
            ) VALUES(
              '\(fallbackID.uuidString)', 'text', 'legacy fallback', 1699999000, '   '
            );
            INSERT INTO items(
              id, kind, text, created_at
            ) VALUES(
              'broken-uuid', 'text', 'bad row', 1699998000
            );
            INSERT INTO items(
              id, kind, text, created_at
            ) VALUES(
              '\(badUUIDID.uuidString)', 'unknown-kind', 'bad kind', 1699997000
            );
            INSERT INTO items(
              id, kind, text, created_at
            ) VALUES(
              '\(badFileID.uuidString)', 'file', 'bad file', 1699996000
            );
            INSERT INTO stacks(id, name, position)
            VALUES('\(stackID.uuidString)', 'Legacy Stack', 0);
            INSERT INTO stack_items(item_id, stack_id)
            VALUES('\(titledID.uuidString)', '\(stackID.uuidString)');
            """)

        let store = ClipboardStore(directory: directory, maintenanceInterval: 3_600)
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        try executeDatabase(
            in: directory,
            """
            INSERT INTO items(id, kind, text, created_at, file_urls)
            VALUES(
              '\(laterCorruptID.uuidString)', 'file', 'corrupt JSON', 1699995000,
              '[not-json'
            )
            """)
        store.load()

        let migratedColumns = try scalar(
            in: directory,
            """
            SELECT COUNT(*) FROM pragma_table_info('items')
            WHERE name IN (
              'first_copied_at', 'copy_count', 'file_urls',
              'ocr_text', 'ocr_status', 'ocr_version', 'ocr_attempts'
            )
            """)
        try TestSupport.expect(migratedColumns == 7, "legacy schema receives every new column")

        guard let titled = store.item(id: titledID),
            let fallback = store.item(id: fallbackID)
        else {
            throw FixtureFailure.invalidFixture("valid legacy rows were not loaded")
        }
        try TestSupport.expect(store.items.map(\.id) == [titledID, fallbackID], "invalid legacy rows are skipped")
        try TestSupport.expect(
            titled.customTitle == "旧标题 🧭" && titled.copyCount == 1,
            "legacy custom title and copy count are preserved")
        try TestSupport.expect(
            titled.firstCopiedAt == Date(timeIntervalSince1970: 1_700_000_000),
            "legacy timestamp becomes the first captured date")
        try TestSupport.expect(
            fallback.displayTitle(locale: Locale(identifier: "en")) == "legacy fallback",
            "legacy whitespace title falls back to text")
        try TestSupport.expect(store.stackID(for: titledID) == stackID, "legacy stack membership survives migration")
        try TestSupport.expect(
            store.item(id: badUUIDID) == nil
                && store.item(id: badFileID) == nil
                && store.item(id: laterCorruptID) == nil,
            "malformed identifiers kinds and file payloads remain isolated")

        let reopened = makeStore(in: directory)
        try TestSupport.expect(
            reopened.items.map(\.id) == [titledID, fallbackID],
            "migrated valid rows survive another reload")
        try TestSupport.expect(reopened.stackID(for: titledID) == stackID, "migrated stack state survives another reload")
    }

    @MainActor
    private static func undoEdgeContracts(in directory: URL) async throws {
        let collisionDirectory = directory.appendingPathComponent("collision")
        let expiryDirectory = directory.appendingPathComponent("expiry")
        try FileManager.default.createDirectory(at: collisionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expiryDirectory, withIntermediateDirectories: true)

        let collisionStore = makeStore(in: collisionDirectory)
        guard let original = collisionStore.addText(
            "same content", kind: .text, sourceBundleID: "fixture.editor"),
            let stack = collisionStore.createStack(name: "Undo Stack")
        else {
            throw FixtureFailure.invalidFixture("undo collision fixtures were not created")
        }
        collisionStore.assign(original.id, to: stack.id)
        try executeDatabase(
            in: collisionDirectory,
            """
            UPDATE items SET custom_title = 'original title'
            WHERE id = '\(original.id.uuidString)'
            """)
        collisionStore.load()
        guard let titledOriginal = collisionStore.item(id: original.id) else {
            throw FixtureFailure.invalidFixture("undo collision title was not reloaded")
        }
        try TestSupport.expect(collisionStore.remove(titledOriginal), "collision fixture can be removed")

        guard let newer = collisionStore.addText(
            "same content", kind: .text, sourceBundleID: "fixture.editor")
        else {
            throw FixtureFailure.invalidFixture("newer duplicate was not created")
        }
        try TestSupport.expect(newer.id != original.id, "newer duplicate receives a new identifier")
        let restored = collisionStore.undoLastDeletion()
        try TestSupport.expect(
            restored?.id == newer.id,
            "undo returns the newer item when equivalent content already exists")
        try TestSupport.expect(
            collisionStore.item(id: original.id) == nil
                && collisionStore.items.filter { $0.text == "same content" }.count == 1,
            "undo collision creates no duplicate row")
        try TestSupport.expect(
            restored?.customTitle == nil,
            "undo collision does not overwrite newer metadata")
        try TestSupport.expect(
            collisionStore.stackID(for: newer.id) == stack.id,
            "undo collision restores the deleted item's stack association")
        try TestSupport.expect(!collisionStore.canUndoDeletion, "collision undo consumes the snapshot")
        try TestSupport.expect(collisionStore.undoLastDeletion() == nil, "second collision undo is a no-op")
        let collisionRows = try scalar(
            in: collisionDirectory,
            "SELECT COUNT(*) FROM items WHERE text = 'same content'")
        try TestSupport.expect(collisionRows == 1, "collision undo leaves one persisted content row")

        let expiryStore = makeStore(in: expiryDirectory)
        guard let expiring = expiryStore.addText(
            "expired undo", kind: .text, sourceBundleID: nil)
        else {
            throw FixtureFailure.invalidFixture("expiry fixture was not created")
        }
        try TestSupport.expect(expiryStore.remove(expiring), "expiry fixture can be removed")
        expiryStore.maxAge = 0
        try TestSupport.expect(!expiryStore.canUndoDeletion, "zero-age deletion is not undoable")
        try TestSupport.expect(expiryStore.undoLastDeletion() == nil, "expired snapshot is rejected")
        try TestSupport.expect(
            expiryStore.item(id: expiring.id) == nil && !expiryStore.canUndoDeletion,
            "rejected expired undo leaves the row deleted and consumes undo")
    }

    @MainActor
    private static func makeStore(in directory: URL) -> ClipboardStore {
        let store = ClipboardStore(directory: directory, maintenanceInterval: 3_600)
        store.setImageTextSearchEnabled(false)
        store.maxAge = ClipboardRetention.forever.maxAge
        store.load()
        return store
    }

    private static func executeDatabase(in directory: URL, _ sql: String) throws {
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let database { sqlite3_close_v2(database) }
            throw FixtureFailure.sqlite("failed to open temporary database: \(message)")
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_000)
        if sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK {
            throw FixtureFailure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func scalar(in directory: URL, _ sql: String) throws -> Int {
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let database { sqlite3_close_v2(database) }
            throw FixtureFailure.sqlite("failed to open temporary database: \(message)")
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw FixtureFailure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FixtureFailure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func pngData(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let bitmapData = bitmap.bitmapData
        else {
            throw FixtureFailure.invalidFixture("image fixture could not be allocated")
        }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmapData[offset] = red
                bitmapData[offset + 1] = green
                bitmapData[offset + 2] = blue
                bitmapData[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureFailure.invalidFixture("image fixture could not be encoded")
        }
        return data
    }
}
