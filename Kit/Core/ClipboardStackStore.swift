import Foundation
import SQLite3

extension ClipboardStore {
    func stackID(for itemID: ClipboardItem.ID) -> ClipboardStack.ID? {
        stackMembership[itemID]
    }

    /// Moves an item into `stackID`, leaving any stack it was in before.
    func assign(_ itemID: ClipboardItem.ID, to stackID: ClipboardStack.ID) {
        guard stacks.contains(where: { $0.id == stackID }) else { return }
        guard stackMembership[itemID] != stackID else { return }
        guard writeMembership(itemID, stackID: stackID) else { return }
        stackMembership[itemID] = stackID
        revision &+= 1
    }

    func removeFromStack(_ itemID: ClipboardItem.ID) -> Bool {
        guard stackMembership[itemID] != nil else { return true }
        guard deleteMembership(itemID) else { return false }
        stackMembership.removeValue(forKey: itemID)
        revision &+= 1
        return true
    }

    func createStack(name: String) -> ClipboardStack? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stmt = insertStackStmt else { return nil }
        let stack = ClipboardStack(id: UUID(), name: trimmed)
        ClipboardSQLite.reset(stmt)
        ClipboardSQLite.bindText(stack.id.uuidString, to: stmt, at: 1)
        ClipboardSQLite.bindText(trimmed, to: stmt, at: 2)
        ClipboardSQLite.bindInt64(Int64(stacks.count), to: stmt, at: 3)
        guard stepAndReset(stmt) else { return nil }
        stacks.append(stack)
        revision &+= 1
        return stack
    }

    func renameStack(_ id: ClipboardStack.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = stacks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if stacks[index].name == trimmed { return true }
        guard let stmt = prepare("UPDATE stacks SET name = ? WHERE id = ?") else { return false }
        defer { sqlite3_finalize(stmt) }
        ClipboardSQLite.bindText(trimmed, to: stmt, at: 1)
        ClipboardSQLite.bindText(id.uuidString, to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        stacks[index].name = trimmed
        revision &+= 1
        return true
    }

    /// Remove a stack together with every history row assigned to it.
    @discardableResult
    func deleteStack(_ id: ClipboardStack.ID) -> Bool {
        guard stacks.contains(where: { $0.id == id }) else { return false }
        var contents: (itemIDs: Set<ClipboardItem.ID>, imageURLs: [URL])?
        guard transaction({
            contents = stackContents(id)
            guard contents != nil else { return false }
            return deleteStackRows(
                "DELETE FROM items WHERE id IN (SELECT item_id FROM stack_items WHERE stack_id = ?)",
                stackID: id)
                && deleteStackRows("DELETE FROM stack_items WHERE stack_id = ?", stackID: id)
                && deleteStackRows("DELETE FROM stacks WHERE id = ?", stackID: id)
        }), let contents
        else { return false }

        if deletedEntry?.stackID == id { discardDeletion() }
        stacks.removeAll { $0.id == id }
        stackMembership = stackMembership.filter { $0.value != id }
        let remaining = items.filter { !contents.itemIDs.contains($0.id) }
        if remaining.count != items.count {
            items = remaining
        } else {
            revision &+= 1
        }
        for url in contents.imageURLs {
            try? FileManager.default.removeItem(at: url)
            ImageThumbnail.removeCachedImage(for: url)
        }
        refreshImageTextIndexState()
        return true
    }

    private func stackContents(
        _ id: ClipboardStack.ID
    ) -> (itemIDs: Set<ClipboardItem.ID>, imageURLs: [URL])? {
        guard let stmt = prepare(
            """
            SELECT i.id, i.image_path FROM items i
            JOIN stack_items s ON s.item_id = i.id
            WHERE s.stack_id = ?
            """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard ClipboardSQLite.bindText(id.uuidString, to: stmt, at: 1) else { return nil }

        var itemIDs = Set<ClipboardItem.ID>()
        var imageURLs: [URL] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            if let idString = ClipboardSQLite.columnString(stmt, 0), let itemID = UUID(uuidString: idString) {
                itemIDs.insert(itemID)
            }
            if let path = ClipboardSQLite.columnString(stmt, 1), let url = managedBlobURL(for: path) {
                imageURLs.append(url)
            }
            status = sqlite3_step(stmt)
        }
        return status == SQLITE_DONE ? (itemIDs, imageURLs) : nil
    }

    private func deleteStackRows(_ sql: String, stackID: ClipboardStack.ID) -> Bool {
        guard let stmt = prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        guard ClipboardSQLite.bindText(stackID.uuidString, to: stmt, at: 1) else { return false }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func loadStackState() {
        stacks = []
        stackMembership = [:]
        if let stmt = prepare("SELECT id, name FROM stacks ORDER BY position, rowid") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idString = ClipboardSQLite.columnString(stmt, 0),
                    let id = UUID(uuidString: idString),
                    let name = ClipboardSQLite.columnString(stmt, 1)
                {
                    stacks.append(ClipboardStack(id: id, name: name))
                }
            }
            sqlite3_finalize(stmt)
        }
        ClipboardSQLite.execute(
            "DELETE FROM stack_items WHERE item_id NOT IN (SELECT id FROM items)", in: db)
        if let stmt = prepare("SELECT item_id, stack_id FROM stack_items") {
            let known = Set(stacks.map(\.id))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let itemString = ClipboardSQLite.columnString(stmt, 0),
                    let itemID = UUID(uuidString: itemString),
                    let stackString = ClipboardSQLite.columnString(stmt, 1),
                    let stackID = UUID(uuidString: stackString),
                    known.contains(stackID)
                else { continue }
                stackMembership[itemID] = stackID
            }
            sqlite3_finalize(stmt)
        }
    }

    func writeMembership(_ itemID: ClipboardItem.ID, stackID: ClipboardStack.ID) -> Bool {
        guard let stmt = upsertMembershipStmt else { return false }
        ClipboardSQLite.reset(stmt)
        ClipboardSQLite.bindText(itemID.uuidString, to: stmt, at: 1)
        ClipboardSQLite.bindText(stackID.uuidString, to: stmt, at: 2)
        return stepAndReset(stmt)
    }

    func deleteMembership(_ itemID: ClipboardItem.ID) -> Bool {
        guard let stmt = deleteMembershipStmt else { return false }
        ClipboardSQLite.reset(stmt)
        ClipboardSQLite.bindText(itemID.uuidString, to: stmt, at: 1)
        return stepAndReset(stmt)
    }
}
