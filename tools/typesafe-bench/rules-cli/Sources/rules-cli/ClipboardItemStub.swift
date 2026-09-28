import Foundation

// Minimal stand-in for Kit's ClipboardItem, providing only the Kind cases the
// classifier returns. Copied from Kit/Core/ClipboardItem.swift.
enum ClipboardItem {
    enum Kind: String, Sendable {
        case text, markdown, code, link, path, image
    }
}
