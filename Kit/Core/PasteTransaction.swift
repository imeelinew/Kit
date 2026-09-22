import Foundation

/// Ordered commit protocol for a paste operation. Expensive payload preparation may suspend, but
/// no externally visible state changes until permission and target readiness have both succeeded;
/// history promotion is the final commit after the key event has been scheduled.
@MainActor
enum PasteTransaction {
    static func run<Payload>(
        permission: () -> Bool,
        prepare: () async -> Payload?,
        willDeliver: () -> Void,
        targetReady: () async -> Bool,
        write: (Payload) -> Bool,
        deliver: () -> Bool,
        commit: () -> Void
    ) async -> Bool {
        guard permission() else { return false }
        guard let payload = await prepare(), !Task.isCancelled else { return false }
        willDeliver()
        guard await targetReady(), !Task.isCancelled else { return false }
        guard write(payload) else { return false }
        guard deliver() else { return false }
        commit()
        return true
    }
}
