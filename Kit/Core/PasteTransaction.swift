import Foundation

/// Ordered commit protocol for a paste operation. Expensive payload preparation may suspend, but
/// the clipboard is written only after permission and target readiness have both succeeded.
/// Successful delivery may update usage metadata without changing the history's order.
@MainActor
enum PasteTransaction {
    static func run<Payload>(
        permission: () -> Bool,
        prepare: () async -> Payload?,
        willDeliver: () -> Void,
        targetReady: () async -> Bool,
        write: (Payload) -> Bool,
        deliver: () -> Bool,
        didDeliver: () -> Void = {}
    ) async -> Bool {
        guard permission() else { return false }
        guard let payload = await prepare(), !Task.isCancelled else { return false }
        willDeliver()
        guard await targetReady(), !Task.isCancelled else { return false }
        guard write(payload) else { return false }
        guard deliver() else { return false }
        didDeliver()
        return true
    }
}
