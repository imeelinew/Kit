import AppKit
@testable import Kit

@MainActor
enum CaptureBoundaryTests {
    static func run() async throws {
        for marker in ClipboardCapturePolicy.sensitiveTypes {
            try TestSupport.expect(!ClipboardCapturePolicy.shouldCapture(
                types: [.string, marker, ClipboardCapturePolicy.selectionType],
                sourceBundleID: nil, disabledApps: []), "Every sensitive marker blocks capture")
        }
        try TestSupport.expect(!ClipboardCapturePolicy.shouldCapture(
            types: [.string, ClipboardCapturePolicy.internalType],
            sourceBundleID: "allowed", disabledApps: []), "Internal writes block capture")
        try TestSupport.expect(!ClipboardCapturePolicy.shouldCapture(
            types: [.string], sourceBundleID: "secret", disabledApps: ["secret"]),
            "An excluded source blocks normal text")
        try TestSupport.expect(ClipboardCapturePolicy.shouldCapture(
            types: [.string, ClipboardCapturePolicy.selectionType],
            sourceBundleID: "allowed", disabledApps: ["secret"]), "UI selections can be captured")
        try TestSupport.expect(ClipboardCapturePolicy.shouldCapture(
            types: [], sourceBundleID: nil, disabledApps: ["secret"]), "An unknown source is allowed")

        let pipeline = ClipboardCapturePipeline()
        func snapshot(_ text: String? = nil, image: Data? = nil, png: Bool = false,
                      files: [URL] = []) -> PasteboardSnapshot {
            PasteboardSnapshot(text: text, imageData: image, imageIsPNG: png,
                               fileURLs: files, sourceBundleID: "fixture", generation: 42)
        }
        let local = URL(fileURLWithPath: "/tmp/kit-capture/../fixture.txt")
        let fileCapture = await pipeline.process(snapshot("fallback", image: Data([1]), png: true,
                                                          files: [local]))
        try TestSupport.expect(fileCapture == ClipboardCapture(
            content: .files([local.standardizedFileURL]), sourceBundleID: "fixture", generation: 42),
            "Files take precedence and preserve source and generation")
        let remote = await pipeline.process(snapshot("fallback", files: [local, URL(string: "https://example.com")!]))
        try TestSupport.expect(remote == nil, "Mixed remote files reject the entire capture")
        let corrupt = await pipeline.process(snapshot("  Keep whitespace\n", image: Data([1, 2, 3])))
        try TestSupport.expect(corrupt?.content == .text("  Keep whitespace\n"),
                               "Undecodable non-PNG image falls back to exact text")
        for text in ["", " \t\n\r", "\u{3000}\u{00a0}"] {
            let result = await pipeline.process(snapshot(text))
            try TestSupport.expect(result == nil, "Unicode whitespace has no capture payload")
        }
        let byteLimit = ClipboardCapturePipeline.maxTextBytes
        let atLimit = String(repeating: "😀", count: byteLimit / 4)
        let exact = await pipeline.process(snapshot(atLimit))
        try TestSupport.expect(exact?.content == .text(atLimit), "UTF-8 bytes at the size cap are accepted")
        let over = await pipeline.process(snapshot(atLimit + "a"))
        try TestSupport.expect(over == nil, "UTF-8 byte overflow is rejected despite fewer characters")

        var policies: [Bool] = []
        let coordinator = ActivationPolicyCoordinator { policies.append($0) }
        coordinator.acquire("settings")
        coordinator.acquire("about")
        coordinator.release("settings")
        try TestSupport.expect(policies.last == true, "An overlapping window retains regular activation")
        coordinator.acquire("about")
        coordinator.release("about")
        try TestSupport.expect(policies.last == false, "Duplicate lease acquisition is idempotent")
        coordinator.release("missing")
        try TestSupport.expect(policies.last == false, "An unknown release does not create a lease")
        coordinator.acquire("settings")
        coordinator.reset()
        try TestSupport.expect(policies.last == false, "Reset drops every lease")
    }
}
