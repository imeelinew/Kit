import AppKit
@testable import Kit

/// Entry point for the suites that link the full app binary.
/// Run with scripts/test-clipboard-list.sh.
@main
struct ClipboardListSuite {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let bundleID = Bundle.main.bundleIdentifier!
        precondition(bundleID.hasPrefix("com.eli.Kit.tests.clipboard-list."),
                     "The list harness requires an isolated bundle identity")
        await ClipboardPreviewTests.run()
        try await ClipboardPreviewLifecycleTests.run()
        try await ClipboardUndoTests.run()
        await ClipboardRetentionSettingsTests.run()
        ClipboardTextClassifierTests.run()
        try await ImageDecodeCoordinatorTests.run()
    }
}
