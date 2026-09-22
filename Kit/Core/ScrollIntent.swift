import Foundation

/// A palette scroll request: reset and follow need different, estimation-safe scroll ops on a lazy container, so the caller states which it wants instead of the view guessing from one shared token.
struct ScrollIntent: Equatable {
    enum Kind {
        /// Reset: restore the content origin. Estimation-proof — the origin anchor sits at offset 0, so no row height has to be guessed.
        case top
        /// Keyboard nav: minimal scroll-to-visible, which leaves an already-visible row exactly where it is.
        case follow
    }

    var kind: Kind
    /// Distinguishes back-to-back intents of the same kind so `onChange` still fires.
    var nonce = UUID()
}
