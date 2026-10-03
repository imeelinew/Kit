import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardSQLite {
    static func row(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let idString = columnString(stmt, 0), let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, 1),
            let storedKind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        let imageOCR: ClipboardImageOCR?
        if let status = columnString(stmt, 10).flatMap(ClipboardImageOCR.Status.init(rawValue:)) {
            imageOCR = ClipboardImageOCR(
                text: columnString(stmt, 9), status: status,
                version: Int(sqlite3_column_int(stmt, 11)),
                attempts: Int(sqlite3_column_int(stmt, 12)))
        } else {
            imageOCR = nil
        }
        return ClipboardItem(
            id: id, kind: storedKind, text: columnString(stmt, 2), imagePath: columnString(stmt, 3),
            imageFingerprint: columnString(stmt, 6),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: columnString(stmt, 5), customTitle: columnString(stmt, 7),
            lastUsedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            imageOCR: imageOCR)
    }

    static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}
