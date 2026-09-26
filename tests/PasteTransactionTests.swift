import Foundation

/// Exercises the production transfer boundary without sending keys or touching the pasteboard.
@main
struct PasteTransactionTests {
    @MainActor
    static func checkFailure(at failedStage: String?) async {
        var events: [String] = []
        let succeeded = await PasteTransaction.run(
            permission: {
                events.append("permission")
                return failedStage != "permission"
            },
            prepare: { () -> String? in
                events.append("prepare")
                return failedStage == "prepare" ? nil : "saved image or text"
            },
            willDeliver: { events.append("hide") },
            targetReady: {
                events.append("target")
                return failedStage != "target"
            },
            write: { payload in
                precondition(payload == "saved image or text")
                events.append("write")
                return failedStage != "write"
            },
            deliver: {
                events.append("deliver")
                return failedStage != "deliver"
            })
        let sequence = ["permission", "prepare", "hide", "target", "write", "deliver"]
        let expected: [String]
        if let failedStage, let index = sequence.firstIndex(of: failedStage) {
            expected = Array(sequence[...index])
        } else {
            expected = sequence
        }
        precondition(events == expected, "Unexpected transfer effects: \(events)")
        precondition(succeeded == (failedStage == nil))
    }

    @MainActor
    static func checkCancellation(at stage: String) async {
        var events: [String] = []
        let task = Task { @MainActor in
            await PasteTransaction.run(
                permission: { true },
                prepare: { () -> String? in
                    events.append("prepare")
                    if stage == "prepare" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return "saved image or text"
                },
                willDeliver: { events.append("hide") },
                targetReady: {
                    events.append("target")
                    if stage == "target" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return true
                },
                write: { _ in
                    events.append("write")
                    return true
                },
                deliver: {
                    events.append("deliver")
                    return true
                })
        }
        let succeeded = await task.value
        precondition(!succeeded)
        let expected = stage == "prepare" ? ["prepare"] : ["prepare", "hide", "target"]
        precondition(events == expected, "Cancelled transfer must not write or deliver")
    }

    static func main() async {
        for stage: String? in [nil, "permission", "prepare", "target", "write", "deliver"] {
            await checkFailure(at: stage)
        }
        await checkCancellation(at: "prepare")
        await checkCancellation(at: "target")
        print("PASS: transfer ordering, five failure paths, cancellation before write/delivery")
    }
}
