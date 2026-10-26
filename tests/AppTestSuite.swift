import AppKit
@testable import Kit

@main
struct AppTestSuite {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        guard let bundleID = Bundle.main.bundleIdentifier,
            bundleID.hasPrefix("com.eli.Kit.tests.app.") else {
            print("FAIL: isolated test bundle required")
            exit(2)
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: bundleID) }

        let suites: [(String, @MainActor () async throws -> Void)] = [
            ("classifier", ClipboardClassifierTests.run),
            ("geometry", WindowGeometryTests.run),
            ("paste", PasteTransactionTests.run),
            ("store", ClipboardStoreIntegrationTests.run),
            ("files", FileLifecycleTests.run),
            ("settings", AppSettingsTests.run),
            ("search", SearchSemanticsTests.run),
            ("palette", PaletteInteractionTests.run),
            ("capture", CaptureBoundaryTests.run),
            ("date", DateGroupingTests.run),
            ("images", ImageInfrastructureTests.run),
        ]
        let requested = Set(CommandLine.arguments.dropFirst())
        let names = Set(suites.map(\.0))
        guard requested.isSubset(of: names) else {
            print("Unknown suites: \(requested.subtracting(names).sorted().joined(separator: ", "))")
            print("Available suites: \(suites.map(\.0).joined(separator: ", "))")
            exit(2)
        }
        var failures = 0
        var completed = 0
        for (name, run) in suites where requested.isEmpty || requested.contains(name) {
            let before = TestSupport.assertions
            do {
                try await run()
                print("PASS: \(name), \(TestSupport.assertions - before) assertions")
            } catch {
                failures += 1
                print("FAIL: \(name), \(error)")
            }
            completed += 1
        }
        print("\(completed) suites, \(TestSupport.assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
