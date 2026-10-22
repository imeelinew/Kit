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
        precondition(store.remove(store.item(id: secondID)!) && store.remove(named))
        precondition(store.undoLastDeletion() == named, "Only the latest deletion preserves its metadata")
        precondition(store.undoLastDeletion() == nil && store.item(id: secondID) == nil,
                     "A second undo cannot restore an earlier deletion")
        precondition(store.stackID(for: a.id) == stack.id)
        precondition(!store.canUndoDeletion)
        await store.waitForSearchMetadata()
        let page = await store.searchAsync("chexiao", after: nil, limit: 20)
        precondition(page.items.contains { $0.id == a.id }, "Restored Han text remains searchable by pinyin")
        execute(directory, "INSERT INTO items_fts(items_fts, rank) VALUES('integrity-check', 1)")

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
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

        let member = store.addText("member", kind: .text, sourceBundleID: nil)!
        store.assign(member.id, to: stack.id)
        precondition(store.remove(member) && store.deleteStack(stack.id))
        precondition(!store.canUndoDeletion && store.undoLastDeletion() == nil,
                     "Deleting a Stack discards its pending deletion")
        print("PASS: latest-deletion undo, second-undo no-op, metadata, Stack membership, FTS integrity, image backup, failed-restore rollback, Stack deletion discards undo")
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

    static func interaction(in directory: URL) async {
        let store = ClipboardStore(directory: directory)
        let target = store.addText("undo target", kind: .text, sourceBundleID: nil)!
        let core = AppCore(clipboardStore: store)
        let vm = PaletteViewModel(core: core)
        await ready(vm)
        let panel = PalettePanel(rootView: Color.clear)
        panel.paletteViewModel = vm
        let selected = vm.selectedItem!
        let revision = store.revision
        func backspace() {
            panel.sendEvent(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false,
                keyCode: UInt16(kVK_Delete))!)
        }
        backspace()
        precondition(store.revision == revision && store.item(id: selected.id) != nil && !store.canUndoDeletion,
                     "Backspace at an empty search never deletes the selected item")
        vm.openActions(for: target.id)
        let deleteIndex = vm.menuActions.firstIndex { if case .delete = $0 { return true }; return false }!
        vm.activateMenuItem(at: deleteIndex)
        precondition(store.item(id: target.id) == nil)
        commandZ(panel)
        await ready(vm)
        precondition(store.item(id: target.id) != nil)
        let generation = vm.resultsGeneration
        commandZ(panel)
        precondition(vm.resultsGeneration == generation && store.item(id: target.id) != nil,
                     "A second Command-Z after a settled deletion is a no-op")
        panel.close()
        print("PASS: Backspace never deletes the selection and a settled second Command-Z is a no-op")
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-undo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await storage(in: root.appendingPathComponent("storage"))
        await interaction(in: root.appendingPathComponent("interaction"))
    }
}
