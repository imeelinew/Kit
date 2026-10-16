import Foundation

/// Exercises the production transfer boundary without sending keys or touching the pasteboard.
@main
struct PasteTransactionTests {
    /// Full success-path effect order, with the trailing usage event that only a delivered paste records
    static let order = ["permission", "prepare", "hide", "target", "write", "deliver", "usage"]

    @MainActor
    static func checkFailure(at failedStage: String?) async {
        var events: [String] = []
        let succeeded = await PasteTransaction.run(
            permission: { events.append("permission"); return failedStage != "permission" },
            prepare: { () -> String? in
                events.append("prepare")
                return failedStage == "prepare" ? nil : "saved image or text"
            },
            willDeliver: { events.append("hide") },
            targetReady: { events.append("target"); return failedStage != "target" },
            write: { payload in
                precondition(payload == "saved image or text")
                events.append("write")
                return failedStage != "write"
            },
            deliver: { events.append("deliver"); return failedStage != "deliver" },
            didDeliver: { events.append("usage") })

        let failed = failedStage.flatMap(order.firstIndex(of:))
        let expected = failed.map { Array(order[...$0]) } ?? order
        precondition(events == expected && succeeded == (failedStage == nil), "Unexpected transfer effects: \(events)")
    }

    @MainActor
    static func checkCancellation(at stage: String) async {
        var events: [String] = []
        let task = Task { @MainActor in
            await PasteTransaction.run(
                permission: { true },
                prepare: {
                    events.append("prepare")
                    if stage == "prepare" { withUnsafeCurrentTask { $0?.cancel() } }
                    return "saved image or text"
                },
                willDeliver: { events.append("hide") },
                targetReady: {
                    events.append("target")
                    if stage == "target" { withUnsafeCurrentTask { $0?.cancel() } }
                    return true
                },
                write: { _ in events.append("write"); return true },
                deliver: { events.append("deliver"); return true },
                didDeliver: { events.append("usage") })
        }
        let succeeded = await task.value
        let expected = stage == "prepare" ? ["prepare"] : ["prepare", "hide", "target"]
        precondition(!succeeded && events == expected, "Cancelled transfer must not write or deliver")
    }

    static func main() async {
        for stage: String? in [nil, "permission", "prepare", "target", "write", "deliver"] {
            await checkFailure(at: stage)
        }
        await checkCancellation(at: "prepare")
        await checkCancellation(at: "target")
        print("PASS: transfer ordering, usage only after successful delivery, five failure paths, cancellation")
    }
}
