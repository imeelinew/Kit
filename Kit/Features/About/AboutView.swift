import AppKit
import SwiftUI

/// Reference-counted ownership of the app's regular activation policy. Settings and About may
/// overlap; closing either one can no longer hide the Dock icon while the other still needs it or
/// leave the icon behind after the final auxiliary window closes.
@MainActor
final class ActivationPolicyCoordinator {
    private var leases = Set<String>()
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void = { regular in
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }) {
        self.apply = apply
    }

    func acquire(_ lease: String) {
        leases.insert(lease)
        apply(true)
    }

    func release(_ lease: String) {
        leases.remove(lease)
        apply(!leases.isEmpty)
    }

    func reset() {
        leases.removeAll()
        apply(false)
    }
}
