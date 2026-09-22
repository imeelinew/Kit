import Carbon
import Foundation

/// Selects the system English keyboard when the palette opens, and restores the previous source on hide.
@MainActor
enum InputSourceSwitcher {
    private static var saved: TISInputSource?

    private static let englishIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
        "com.apple.keylayout.British",
    ]

    static func selectEnglish() {
        if saved == nil {
            saved = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        }
        for id in englishIDs where select(id: id) { return }
    }

    static func restore() {
        if let saved {
            TISSelectInputSource(saved)
        }
        saved = nil
    }

    @discardableResult
    private static func select(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
            let source = list.first
        else { return false }
        return TISSelectInputSource(source) == noErr
    }
}
