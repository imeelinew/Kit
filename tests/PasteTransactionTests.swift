import Foundation
@testable import Kit

enum PasteTransactionTests {
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var entered = false

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
                enteredContinuation?.resume()
                enteredContinuation = nil
            }
        }

        func waitUntilSuspended() async {
            guard !entered else { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class NotificationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func receive() {
            lock.withLock { count += 1 }
        }

        var receivedCount: Int {
            lock.withLock { count }
        }
    }

    @MainActor
    private static func sourceInvalidatedDuringActivation() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: { true }, prepare: { "file lease" },
            willDeliver: { events.append("hide") },
            targetReady: { events.append("activate"); return true },
            validate: { _ in events.append("revalidate"); return false },
            write: { _ in events.append("write"); return true },
            deliver: { events.append("paste"); return true },
            didDeliver: { events.append("history") })
        try TestSupport.expect(!result && events == ["hide", "activate", "revalidate"],
                               "Changed sources abort after activation without clipboard writes or history updates")
    }

    @MainActor
    private static func permissionDenial() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return false
            },
            prepare: {
                events.append("prepare")
                return "payload"
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return true
            },
            write: { _ in
                events.append("write")
                return true
            },
            deliver: {
                events.append("deliver")
                return true
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(!result, "Permission denial returns false")
        try TestSupport.expect(
            events == ["permission"],
            "Permission denial stops before preparation and callbacks"
        )
    }

    @MainActor
    private static func preparationFailure() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return true
            },
            prepare: { () async -> String? in
                events.append("prepare.start")
                events.append("prepare.failure")
                return nil
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return true
            },
            write: { _ in
                events.append("write")
                return true
            },
            deliver: {
                events.append("deliver")
                return true
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(!result, "Preparation failure returns false")
        try TestSupport.expect(
            events == ["permission", "prepare.start", "prepare.failure"],
            "Preparation failure suppresses delivery callbacks and later stages"
        )
    }

    @MainActor
    private static func targetNotReady() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return true
            },
            prepare: {
                events.append("prepare")
                return "payload"
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return false
            },
            write: { _ in
                events.append("write")
                return true
            },
            deliver: {
                events.append("deliver")
                return true
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(!result, "An unavailable target returns false")
        try TestSupport.expect(
            events == ["permission", "prepare", "willDeliver", "targetReady"],
            "An unavailable target stops before write and delivery"
        )
    }

    @MainActor
    private static func writeFailure() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return true
            },
            prepare: {
                events.append("prepare")
                return "payload"
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return true
            },
            write: { payload in
                events.append("write:\(payload)")
                return false
            },
            deliver: {
                events.append("deliver")
                return true
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(!result, "A failed write returns false")
        try TestSupport.expect(
            events == ["permission", "prepare", "willDeliver", "targetReady", "write:payload"],
            "A failed write stops before delivery and its callback"
        )
    }

    @MainActor
    private static func deliveryFailure() async throws {
        var events: [String] = []
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return true
            },
            prepare: {
                events.append("prepare")
                return "payload"
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return true
            },
            write: { payload in
                events.append("write:\(payload)")
                return true
            },
            deliver: {
                events.append("deliver")
                return false
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(!result, "A failed delivery returns false")
        try TestSupport.expect(
            events == [
                "permission", "prepare", "willDeliver", "targetReady",
                "write:payload", "deliver",
            ],
            "A failed delivery does not call the success callback"
        )
    }

    @MainActor
    private static func successfulDelivery() async throws {
        var events: [String] = []
        var writtenPayload: String?
        let result = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return true
            },
            prepare: {
                events.append("prepare.start")
                events.append("prepare.end")
                return "payload"
            },
            willDeliver: { events.append("willDeliver") },
            targetReady: {
                events.append("targetReady")
                return true
            },
            write: { payload in
                writtenPayload = payload
                events.append("write:\(payload)")
                return true
            },
            deliver: {
                events.append("deliver")
                return true
            },
            didDeliver: { events.append("didDeliver") }
        )

        try TestSupport.expect(result, "Successful delivery returns true")
        try TestSupport.expect(writtenPayload == "payload", "Write receives the prepared payload")
        try TestSupport.expect(
            events == [
                "permission", "prepare.start", "prepare.end", "willDeliver",
                "targetReady", "write:payload", "deliver", "didDeliver",
            ],
            "Successful delivery follows the complete ordered trace exactly once"
        )
        for event in events {
            try TestSupport.expect(
                events.filter { $0 == event }.count == 1,
                "Every successful delivery event occurs exactly once: \(event)"
            )
        }
    }

    @MainActor
    private static func cancellationAfterPreparation() async throws {
        let gate = Gate()
        var events: [String] = []
        let task = Task { @MainActor in
            await PasteTransaction.run(
                permission: {
                    events.append("permission")
                    return true
                },
                prepare: {
                    events.append("prepare.start")
                    await gate.suspend()
                    events.append("prepare.resume")
                    return "payload"
                },
                willDeliver: { events.append("willDeliver") },
                targetReady: {
                    events.append("targetReady")
                    return true
                },
                write: { _ in
                    events.append("write")
                    return true
                },
                deliver: {
                    events.append("deliver")
                    return true
                },
                didDeliver: { events.append("didDeliver") }
            )
        }

        await gate.waitUntilSuspended()
        try TestSupport.expect(
            events == ["permission", "prepare.start"],
            "Preparation suspends after permission and before readiness"
        )
        task.cancel()
        gate.resume()

        let result = await task.value
        try TestSupport.expect(!result, "Cancellation after preparation returns false")
        try TestSupport.expect(
            events == ["permission", "prepare.start", "prepare.resume"],
            "Cancellation after preparation skips willDeliver, readiness, write, and delivery"
        )
    }

    @MainActor
    private static func cancellationDuringTargetReadiness() async throws {
        let gate = Gate()
        var events: [String] = []
        let task = Task { @MainActor in
            await PasteTransaction.run(
                permission: {
                    events.append("permission")
                    return true
                },
                prepare: {
                    events.append("prepare")
                    return "payload"
                },
                willDeliver: { events.append("willDeliver") },
                targetReady: {
                    events.append("targetReady.start")
                    await gate.suspend()
                    events.append("targetReady.resume")
                    return true
                },
                write: { _ in
                    events.append("write")
                    return true
                },
                deliver: {
                    events.append("deliver")
                    return true
                },
                didDeliver: { events.append("didDeliver") }
            )
        }

        await gate.waitUntilSuspended()
        try TestSupport.expect(
            events == ["permission", "prepare", "willDeliver", "targetReady.start"],
            "Target readiness suspends only after preparation and willDeliver"
        )
        task.cancel()
        gate.resume()

        let result = await task.value
        try TestSupport.expect(!result, "Cancellation during target readiness returns false")
        try TestSupport.expect(
            events == [
                "permission", "prepare", "willDeliver",
                "targetReady.start", "targetReady.resume",
            ],
            "Cancellation during target readiness skips write and delivery"
        )
        try TestSupport.expect(
            events.filter { $0 == "willDeliver" }.count == 1,
            "Cancellation during target readiness calls willDeliver exactly once"
        )
        try TestSupport.expect(
            !events.contains("didDeliver"),
            "Cancellation during target readiness never calls didDeliver"
        )
    }

    @MainActor
    private static func notificationTokenLifetime() async throws {
        let center = NotificationCenter()
        let name = Notification.Name("kit.tests.notification-token.\(UUID().uuidString)")
        let probe = NotificationProbe()
        var token: NotificationToken? = NotificationToken(
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                probe.receive()
            },
            center: center
        )

        center.post(name: name, object: nil)
        try TestSupport.expect(
            probe.receivedCount == 1,
            "A retained token observes a posted notification"
        )
        center.post(name: name, object: nil)
        try TestSupport.expect(
            probe.receivedCount == 2,
            "A retained token continues observing repeated notifications"
        )
        try TestSupport.expect(token != nil, "The token remains retained for the lifespan of the observation")

        token = nil
        center.post(name: name, object: nil)
        try TestSupport.expect(
            probe.receivedCount == 2,
            "Releasing a token removes its observer"
        )
    }

    @MainActor
    static func run() async throws {
        try await sourceInvalidatedDuringActivation()
        try await permissionDenial()
        try await preparationFailure()
        try await targetNotReady()
        try await writeFailure()
        try await deliveryFailure()
        try await successfulDelivery()
        try await cancellationAfterPreparation()
        try await cancellationDuringTargetReadiness()
        try await notificationTokenLifetime()
        print("PASS: PasteTransaction exits, ordered delivery, cancellation gates, NotificationToken lifetime")
    }
}
