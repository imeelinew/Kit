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
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if saved == nil {
            saved = current
        }
        // Selecting an already active source still crosses into the input-method system.
        // Keep that synchronous work out of the window's presentation path.
        if let current, let id = sourceID(current), englishIDs.contains(id) { return }
        for id in englishIDs where select(id: id) { return }
    }

    static func restore() {
        if let saved {
            let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            if current.flatMap({ sourceID($0) }) != sourceID(saved) {
                TISSelectInputSource(saved)
            }
        }
        saved = nil
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
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
