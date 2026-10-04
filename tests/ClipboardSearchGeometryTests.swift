import AppKit
import SwiftUI
@testable import Kit

/// Includes the root content transition, which isolated table fixtures do not exercise.
@MainActor
enum ClipboardSearchGeometryTests {
    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func assertTop(_ scrollView: NSScrollView) {
        precondition(abs(scrollView.contentView.bounds.minY + scrollView.contentInsets.top) < 0.01,
                     "Search updates must never shift the viewport away from its resting top")
    }

    private static func assertPixelAlignment(_ scrollView: NSScrollView) {
        let backing = scrollView.convertToBacking(scrollView.bounds)
        for edge in [backing.minX, backing.minY, backing.maxX, backing.maxY] {
            precondition(abs(edge - edge.rounded()) < 0.01,
                         "The root transition must not leave the native viewport between pixels")
        }
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-search-geometry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        for index in 0..<40 {
            _ = store.addText("alphabet entry \(index)", kind: .text, sourceBundleID: nil)
        }
        _ = store.addText("xyz entry", kind: .text, sourceBundleID: nil)
        let core = AppCore(clipboardStore: store)
        let vm = core.palette
        // Mount while the initial asynchronous search is still empty. This exercises
        // the same empty-to-populated transition used by the production prewarm.
        let window = PalettePanel(
            rootView: RootPaletteView(vm: vm, store: store, settings: core.settings),
            visualStyle: .frosted)
        window.paletteViewModel = vm
        window.beginPresentation()
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        let hosting = window.contentView!
        hosting.layoutSubtreeIfNeeded()
        precondition(vm.searchReady && vm.results.count == 41)

        func checkSearch(_ query: String, expectedCount: Int) async throws {
            guard let table = table(in: hosting), let scrollView = table.enclosingScrollView else {
                preconditionFailure("The populated root must contain the production table")
            }
            assertTop(scrollView)
            assertPixelAlignment(scrollView)
            let initialFrame = scrollView.frame
            // Check every bounds notification, including transient movement that would
            // disappear before a settled-frame assertion gets a chance to run.
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { _ in
                MainActor.assumeIsolated { assertTop(scrollView) }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            vm.query = query
            try await settle()
            precondition(vm.searchReady && vm.results.count == expectedCount,
                         "Query \(query) must finish with \(expectedCount) results; ready=\(vm.searchReady), actual=\(vm.results.count)")
            precondition(scrollView.frame == initialFrame,
                         "Typing changes results without resizing the viewport")
            assertTop(scrollView)
            assertPixelAlignment(scrollView)
        }

        for query in ["a", "al", "alp", "alph", "alpha", "alph", "a", ""] {
            try await checkSearch(query, expectedCount: query.isEmpty ? 41 : 40)
        }

        // Recreating the list after no matches must not reintroduce fractional geometry.
        vm.query = "no matching fixture"
        try await settle()
        precondition(vm.searchReady && vm.results.isEmpty && table(in: hosting) == nil)
        vm.query = "alpha"
        try await settle()
        precondition(vm.searchReady && vm.results.count == 40)
        try await checkSearch("alph", expectedCount: 40)
        try await checkSearch("", expectedCount: 41)
        print("PASS: root appearance, pixel-aligned viewport, motionless typing/backspace/clear, empty-result recovery")
    }
}
