import AppKit
import Carbon.HIToolbox
import SQLite3
import SwiftUI
@testable import Kit

/// Runs with test-clipboard-list.sh, using real SQLite, AppKit key routing, and temporary stores.
@MainActor
enum ClipboardUndoTests {
    static func execute(_ directory: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite3").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    static func backups(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("deleted-images"),
            includingPropertiesForKeys: nil)) ?? []
    }

    static func storage(in directory: URL) async throws {
        let store = ClipboardStore(directory: directory)
        store.load()
        let a = store.addText("撤销测试", kind: .text, sourceBundleID: "original")!
        let secondID = store.addText("second", kind: .code, sourceBundleID: "editor")!.id
        let stack = store.createStack(name: "Saved")!
        store.assign(a.id, to: stack.id)
        execute(directory, "UPDATE items SET custom_title = 'Saved title' WHERE id = '\(a.id)'")
        store.load()
        let named = store.item(id: a.id)!
        let b = store.item(id: secondID)!
        var captured = 0
        store.onItemInserted = { captured += 1 }
        precondition(store.remove(named) && store.remove(b))
        precondition(store.undoLastDeletion() == b, "Undo follows reverse deletion order")
        precondition(store.undoLastDeletion() == named, "Original ID, time, title, source and content survive")
        precondition(store.stackID(for: a.id) == stack.id)
        precondition(captured == 0 && !store.canUndoDeletion, "Undo is not a new capture")
        await store.waitForSearchMetadata()
        let page = await store.searchAsync("chexiao", after: nil, limit: 20)
        precondition(page.items.contains { $0.id == a.id }, "Restored Han text remains searchable by pinyin")
        execute(directory, "INSERT INTO items_fts(items_fts, rank) VALUES('integrity-check', 1)")

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let data = bitmap.representation(using: .png, properties: [:])!
        await store.addImage(data, sourceBundleID: "image-source")
        let image = store.items.first!
        let imageURL = store.imageURL(for: image)!
        precondition(store.remove(image))
        precondition(!FileManager.default.fileExists(atPath: imageURL.path) && backups(directory).count == 1)
        execute(directory, "CREATE TRIGGER fail_restore BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        precondition(store.undoLastDeletion() == nil && store.canUndoDeletion)
        precondition(!FileManager.default.fileExists(atPath: imageURL.path), "Failed restore rolls back the copied image")
        precondition(backups(directory).count == 1, "Failed restore keeps the undo backup")
        execute(directory, "DROP TRIGGER fail_restore")
        precondition(store.undoLastDeletion() == image)
        let restoredData = try Data(contentsOf: imageURL)
        precondition(restoredData == data && backups(directory).isEmpty)

        let revision = store.revision
        execute(directory, "CREATE TRIGGER fail_delete BEFORE DELETE ON items BEGIN SELECT RAISE(ABORT, 'test'); END")
        precondition(!store.remove(image) && !store.remove(named))
        precondition(store.revision == revision && !store.canUndoDeletion)
        precondition(store.item(id: image.id) == image && store.stackID(for: named.id) == stack.id)
        precondition(FileManager.default.fileExists(atPath: imageURL.path) && backups(directory).isEmpty)
        execute(directory, "DROP TRIGGER fail_delete")

        precondition(store.remove(image))
        await store.addImage(data, sourceBundleID: "recopy")
        let recopiedImage = store.items.first!
        // Compare by id: Date() and Date(timeIntervalSince1970:) can sit 1 ULP apart, so a
        // full == between an in-memory item and its DB-read copy flakes on createdAt.
        precondition(recopiedImage.id != image.id && store.undoLastDeletion()?.id == recopiedImage.id)
        precondition(store.items.filter { $0.imageFingerprint == image.imageFingerprint }.count == 1)
        precondition(backups(directory).isEmpty)
        precondition(store.remove(b))
        let recopiedText = store.addText("second", kind: .code, sourceBundleID: "new")!
        precondition(store.undoLastDeletion()?.id == recopiedText.id, "Undo preserves a more recent copy")

        precondition(store.remove(recopiedImage))
        store.clearAll()
        precondition(!store.canUndoDeletion && store.undoLastDeletion() == nil && backups(directory).isEmpty)
        await store.addImage(data, sourceBundleID: nil)
        precondition(store.remove(store.items.first!))
        for index in 0..<21 {
            let entry = store.addText("entry \(index)", kind: .text, sourceBundleID: nil)!
            precondition(store.remove(entry))
        }
        precondition(backups(directory).isEmpty, "Evicting an old undo releases its image")
        for index in (1..<21).reversed() {
            precondition(store.undoLastDeletion()?.text == "entry \(index)")
        }
        precondition(store.undoLastDeletion() == nil, "Only 20 deletions are retained")

        let unstacked = store.items.first!
        precondition(store.remove(unstacked))
        let member = store.addText("member", kind: .text, sourceBundleID: nil)!
        store.assign(member.id, to: stack.id)
        precondition(store.remove(member) && store.deleteStack(stack.id))
        precondition(store.undoLastDeletion() == unstacked, "Deleting a Stack discards only its undo entries")
        precondition(!store.canUndoDeletion)
        precondition(store.remove(unstacked))
        store.maxAge = 0
        store.enforceLimits()
        precondition(!store.canUndoDeletion && store.undoLastDeletion() == nil, "Retention also expires undo")

        let sessionDirectory = directory.appendingPathComponent("session")
        var session: ClipboardStore? = ClipboardStore(directory: sessionDirectory)
        await session!.addImage(data, sourceBundleID: nil)
        precondition(session!.remove(session!.items.first!))
        session = nil
        precondition(backups(sessionDirectory).isEmpty, "Ending a session cleans up backups")
        let reopened = ClipboardStore(directory: sessionDirectory)
        reopened.load()
        precondition(reopened.items.isEmpty && !reopened.canUndoDeletion)
        print("PASS: undo metadata, images, Stack membership, FTS, rollback, recopy, limit, clear, expiration, session cleanup")
    }

    static func ready(_ vm: PaletteViewModel) async {
        let deadline = Date().addingTimeInterval(10)
        while !vm.searchReady && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(vm.searchReady, "Search finishes")
    }

    static func commandZ(_ panel: PalettePanel, repeating: Bool = false) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: repeating, keyCode: UInt16(kVK_ANSI_Z))!
        panel.sendEvent(event)
    }

    private final class UndoProbe: NSObject {
        var invoked = false
    }

    static func interaction(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        let target = store.addText("undo target", kind: .text, sourceBundleID: nil)!
        for index in 0..<170 {
            _ = store.addText("filler \(index)", kind: .text, sourceBundleID: nil)
        }
        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        await ready(vm)
        let panel = PalettePanel(rootView: Color.clear, visualStyle: .frosted)
        panel.paletteViewModel = vm
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        editor.allowsUndo = true
        panel.contentView = editor
        precondition(panel.makeFirstResponder(editor))
        let manager = editor.undoManager!
        manager.groupsByEvent = false
        let probe = UndoProbe()
        func registerTextUndo() {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: probe) { $0.invoked = true }
            manager.endUndoGrouping()
        }

        vm.query = "undo target"
        await ready(vm)
        vm.openActions(for: target.id)
        let deleteIndex = vm.menuActions.firstIndex { if case .delete = $0 { return true }; return false }!
        vm.activateMenuItem(at: deleteIndex)
        precondition(store.item(id: target.id) == nil && vm.prefersDeletionUndo)
        registerTextUndo()
        commandZ(panel, repeating: true)
        precondition(store.item(id: target.id) == nil && !probe.invoked, "Holding the key never repeats undo")
        commandZ(panel)
        await ready(vm)
        precondition(vm.selectedID == target.id && vm.query == "undo target" && !probe.invoked,
                     "A deletion from filtered results takes precedence over earlier search edits")

        vm.openActions(for: target.id)
        vm.activateMenuItem(at: deleteIndex)
        vm.query = "new search"
        await ready(vm)
        commandZ(panel)
        precondition(probe.invoked && store.item(id: target.id) == nil, "Typing gives text undo priority")
        probe.invoked = false
        registerTextUndo()
        vm.toggleStackFilter()
        vm.beginStackName()
        commandZ(panel)
        precondition(probe.invoked && store.item(id: target.id) == nil, "Naming never consumes entry undo")
        vm.cancelStackName()
        vm.closeMenu()
        vm.handle(.undoDelete)
        await ready(vm)
        precondition(vm.query.isEmpty && vm.selectedID == target.id && vm.results.count == 171,
                     "Undo reveals an older entry across pagination and incompatible filters")
        precondition(store.item(id: target.id)?.createdAt == target.createdAt)

        vm.query = "undo target"
        await ready(vm)
        vm.openActions(for: target.id)
        vm.activateMenuItem(at: deleteIndex)
        await ready(vm)
        precondition(vm.results.isEmpty)
        commandZ(panel)
        await ready(vm)
        precondition(vm.selectedID == target.id, "Undo works after deleting the last search result")
        panel.close()
        print("PASS: Command-Z, repeated keys, text/naming priority, filtered deletion, older-page reveal, empty results")
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await storage(in: root.appendingPathComponent("storage"))
        await interaction(in: root.appendingPathComponent("interaction"))
    }
}
