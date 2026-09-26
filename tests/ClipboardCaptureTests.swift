import AppKit
import ImageIO

/// Run with scripts/test-capture.sh. Exercises the capture decision boundary and the
/// snapshot-to-capture normalization with real files, without a live pasteboard.
@main
struct ClipboardCaptureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    /// A 2×2 solid-color bitmap as PNG and TIFF encodings of the same pixels.
    /// Built through CGContext: `NSBitmapImageRep.setColor` silently drops writes on a
    /// freshly allocated rep, leaving zeroed pixels behind.
    static func makeImage(_ red: CGFloat, _ blue: CGFloat) -> (png: Data, tiff: Data) {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return (
            rep.representation(using: .png, properties: [:])!,
            rep.representation(using: .tiff, properties: [:])!
        )
    }

    static func decodeIsPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            && NSBitmapImageRep(data: data) != nil
    }

    static func dominantChannel(_ data: Data, _ channel: (NSColor) -> CGFloat) -> CGFloat {
        let rep = NSBitmapImageRep(data: data)!
        return channel(rep.colorAt(x: 0, y: 0)!)
    }

    static func snapshot(
        text: String? = nil, imageData: Data? = nil, imageIsPNG: Bool = false,
        fileURLs: [URL] = [], sourceBundleID: String? = nil, generation: UInt64 = 0
    ) -> PasteboardSnapshot {
        PasteboardSnapshot(
            text: text, imageData: imageData, imageIsPNG: imageIsPNG,
            fileURLs: fileURLs, sourceBundleID: sourceBundleID, generation: generation)
    }

    static func policyTests() {
        let plain: [NSPasteboard.PasteboardType] = [.string]
        expect(ClipboardCapturePolicy.shouldCapture(types: plain, sourceBundleID: nil, disabledApps: []),
               "A normal copy with no source is captured")
        expect(ClipboardCapturePolicy.shouldCapture(types: plain, sourceBundleID: "app.good", disabledApps: []),
               "A normal copy from a tracked app is captured")
        expect(!ClipboardCapturePolicy.shouldCapture(
            types: plain + [ClipboardCapturePolicy.internalType],
            sourceBundleID: nil, disabledApps: []),
            "Kit's own pasteboard writes are never captured")
        for marker in ClipboardCapturePolicy.sensitiveTypes {
            expect(!ClipboardCapturePolicy.shouldCapture(
                types: plain + [marker], sourceBundleID: nil, disabledApps: []),
                "Secret-copy markers suppress capture: \(marker.rawValue)")
        }
        expect(!ClipboardCapturePolicy.shouldCapture(
            types: [ClipboardCapturePolicy.sensitiveTypes.first!],
            sourceBundleID: nil, disabledApps: []),
            "A marker alone is enough to suppress capture")
        expect(!ClipboardCapturePolicy.shouldCapture(
            types: plain, sourceBundleID: "app.hidden", disabledApps: ["app.hidden"]),
            "Excluded apps are not captured")
        expect(ClipboardCapturePolicy.shouldCapture(
            types: plain, sourceBundleID: "app.other", disabledApps: ["app.hidden"]),
            "Only the excluded app itself is suppressed")
        expect(ClipboardCapturePolicy.shouldCapture(
            types: plain, sourceBundleID: nil, disabledApps: ["app.hidden"]),
            "An unknown frontmost app still captures")
        expect(ClipboardCapturePolicy.shouldCapture(types: [], sourceBundleID: nil, disabledApps: []),
               "Empty types defer to the snapshot read rather than failing early")
    }

    @MainActor
    static func main() async {
        policyTests()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-capture-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let pipeline = ClipboardCapturePipeline()
        let red = makeImage(1, 0)
        let blue = makeImage(0, 1)

        // PNG bytes announced as PNG pass through untouched.
        let passthrough = await pipeline.process(
            snapshot(text: nil, imageData: red.png, imageIsPNG: true))
        expect(passthrough?.content == .image(red.png), "Announced PNG data is not re-encoded")

        // Non-PNG bitmap data is re-encoded to PNG.
        let reencoded = await pipeline.process(
            snapshot(text: nil, imageData: red.tiff, imageIsPNG: false))
        guard case .image(let png)? = reencoded?.content else {
            preconditionFailure("TIFF data normalizes to an image capture")
        }
        expect(decodeIsPNG(png), "TIFF data is re-encoded as PNG")
        expect(dominantChannel(png, \.redComponent) > 0.9, "Re-encoding keeps the pixels")

        // Copied image files resolve through ImageIO, whatever the disk format.
        let tiffFile = root.appendingPathComponent("shot.tiff")
        try! blue.tiff.write(to: tiffFile)
        let fromFile = await pipeline.process(snapshot(text: nil, fileURLs: [tiffFile]))
        guard case .image(let filePNG)? = fromFile?.content else {
            preconditionFailure("A copied TIFF file becomes an image capture")
        }
        expect(decodeIsPNG(filePNG), "Image files normalize to PNG")
        expect(dominantChannel(filePNG, \.blueComponent) > 0.9, "File pixels survive normalization")

        // A copied plain file falls through to its path text; image files outrank pasted data.
        let textFile = root.appendingPathComponent("notes.txt")
        try! Data("hello".utf8).write(to: textFile)
        let pathText = await pipeline.process(
            snapshot(text: textFile.lastPathComponent, fileURLs: [textFile]))
        expect(pathText?.content == .text(textFile.lastPathComponent),
               "Non-image files fall through to the filename text")

        let fileWins = await pipeline.process(
            snapshot(text: nil, imageData: red.png, imageIsPNG: true, fileURLs: [tiffFile]))
        guard case .image(let winner)? = fileWins?.content else {
            preconditionFailure("File URLs take priority over pasteboard data")
        }
        expect(dominantChannel(winner, \.blueComponent) > 0.9, "The image file wins over pasted data")

        // Text rules: images outrank text; blanks and oversize payloads are dropped.
        let imageOverText = await pipeline.process(
            snapshot(text: "stale filename", imageData: red.png, imageIsPNG: true))
        expect(imageOverText?.content == .image(red.png), "Image data outranks accompanying text")

        let blank = await pipeline.process(snapshot(text: "  \n\t "))
        expect(blank == nil, "Whitespace-only text is dropped")
        let empty = await pipeline.process(snapshot())
        expect(empty == nil, "An empty snapshot captures nothing")

        let limit = ClipboardCapturePipeline.maxTextBytes
        let capped = await pipeline.process(snapshot(text: String(repeating: "a", count: limit)))
        expect(capped?.content == .text(String(repeating: "a", count: limit)),
               "Text exactly at the size cap is captured")
        let oversized = await pipeline.process(
            snapshot(text: String(repeating: "a", count: limit + 1)))
        expect(oversized == nil, "Text beyond the size cap is dropped")

        print("PASS: capture policy, file/data priority, PNG passthrough, TIFF normalization, text limits")
    }
}
