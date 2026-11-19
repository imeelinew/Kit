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

        try await promisedImageTests()

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

    private static func promisedImageTests() async throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.representation(using: .tiff, properties: [:])!
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        func beginRead() -> Task<PasteboardSnapshot?, Never> {
            let name = pasteboard.name
            let count = pasteboard.changeCount
            return Task.detached {
                await ClipboardManager.readSnapshot(
                    changeCount: count, sourceBundleID: "browser.fixture", generation: 42,
                    disabledApps: [], pasteboardName: name)
            }
        }

        // A browser can advertise an image before supplying its bytes or even its final types
        for initialTypes: [NSPasteboard.PasteboardType] in [[.png], [.png, .string], []] {
            pasteboard.declareTypes(initialTypes, owner: nil)
            if initialTypes.contains(.string) {
                pasteboard.setString("https://example.com/image", forType: .string)
            }
            let count = pasteboard.changeCount
            let read = beginRead()
            defer { read.cancel() }
            try await Task.sleep(for: .milliseconds(250))
            if initialTypes.isEmpty { pasteboard.addTypes([.png], owner: nil) }
            try TestSupport.expect(pasteboard.setData(png, forType: .png), "Delayed PNG is published")
            try TestSupport.expect(pasteboard.changeCount == count,
                                   "Supplying promised bytes does not create a new generation")
            let result = await read.value
            try TestSupport.expect(result?.imageData == png && result?.imageIsPNG == true,
                                   "A delayed image is captured without a second copy")
            try TestSupport.expect(result?.sourceBundleID == "browser.fixture" && result?.generation == 42,
                                   "Retries retain the original source and store generation")
        }

        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(tiff, forType: .tiff)
        let fallback = await beginRead().value
        try TestSupport.expect(fallback?.imageData == tiff && fallback?.imageIsPNG == false,
                               "Readable TIFF is captured when the advertised PNG is unavailable")

        pasteboard.declareTypes([.png, .fileURL], owner: nil)
        let file = URL(fileURLWithPath: "/tmp/kit-promised-image.png")
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        let files = await beginRead().value
        try TestSupport.expect(files?.fileURLs == [file],
                               "File copies are captured without waiting for an unavailable image")

        pasteboard.declareTypes([.fileURL], owner: nil)
        let delayedFiles = beginRead()
        defer { delayedFiles.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        pasteboard.setString(file.absoluteString, forType: .fileURL)
        let suppliedFiles = await delayedFiles.value
        try TestSupport.expect(suppliedFiles?.fileURLs == [file],
                               "Delayed file URLs retain the existing retry behavior")

        pasteboard.declareTypes([.png], owner: nil)
        let superseded = beginRead()
        defer { superseded.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        pasteboard.clearContents()
        pasteboard.setString("newer copy", forType: .string)
        let stale = await superseded.value
        try TestSupport.expect(stale == nil, "A newer copy stops retries for the previous image")
        let latest = await beginRead().value
        try TestSupport.expect(latest?.text == "newer copy", "The newer copy remains readable")

        pasteboard.declareTypes([.png], owner: nil)
        let concealed = beginRead()
        defer { concealed.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        pasteboard.addTypes([.init("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setData(png, forType: .png)
        let secret = await concealed.value
        try TestSupport.expect(secret == nil, "Privacy markers added during a retry suppress capture")

        pasteboard.declareTypes([.png], owner: nil)
        let cancelled = beginRead()
        try await Task.sleep(for: .milliseconds(150))
        cancelled.cancel()
        let stopped = await cancelled.value
        try TestSupport.expect(stopped == nil, "Pausing can cancel a pending image retry")
    }
}
