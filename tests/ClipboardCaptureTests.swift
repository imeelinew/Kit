import AppKit
import ImageIO

/// Run with scripts/test-capture.sh. Exercises the capture decision boundary and the
/// snapshot-to-capture normalization without a live pasteboard.
@main
struct ClipboardCaptureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func makeImage(_ red: CGFloat, _ blue: CGFloat) -> (png: Data, tiff: Data) {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return (rep.representation(using: .png, properties: [:])!,
                rep.representation(using: .tiff, properties: [:])!)
    }

    static func decodeIsPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) && NSBitmapImageRep(data: data) != nil
    }

    static func snapshot(text: String? = nil, imageData: Data? = nil, imageIsPNG: Bool = false,
                         fileURLs: [URL] = []) -> PasteboardSnapshot {
        PasteboardSnapshot(text: text, imageData: imageData, imageIsPNG: imageIsPNG,
                           fileURLs: fileURLs, sourceBundleID: nil, generation: 0)
    }

    static func policyTests() {
        let plain: [NSPasteboard.PasteboardType] = [.string]
        expect(ClipboardCapturePolicy.shouldCapture(types: plain, sourceBundleID: "app.good", disabledApps: []),
               "A normal copy from a tracked app is captured")
        expect(!ClipboardCapturePolicy.shouldCapture(
            types: plain + [ClipboardCapturePolicy.internalType], sourceBundleID: nil, disabledApps: []),
            "Kit's own pasteboard writes are never captured")
        for marker in ClipboardCapturePolicy.sensitiveTypes {
            expect(!ClipboardCapturePolicy.shouldCapture(
                types: plain + [marker], sourceBundleID: nil, disabledApps: []),
                "Secret-copy markers suppress capture: \(marker.rawValue)")
        }
        expect(!ClipboardCapturePolicy.shouldCapture(
            types: plain, sourceBundleID: "app.hidden", disabledApps: ["app.hidden"]),
            "Excluded apps are not captured")
    }

    @MainActor
    static func main() async {
        policyTests()

        let pipeline = ClipboardCapturePipeline()
        let red = makeImage(1, 0)

        let passthrough = await pipeline.process(
            snapshot(text: nil, imageData: red.png, imageIsPNG: true))
        expect(passthrough?.content == .image(red.png), "Announced PNG data is not re-encoded")

        let reencoded = await pipeline.process(
            snapshot(text: nil, imageData: red.tiff, imageIsPNG: false))
        guard case .image(let png)? = reencoded?.content, decodeIsPNG(png) else {
            preconditionFailure("TIFF data normalizes to a decodable PNG")
        }

        let fileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileDirectory) }
        let textFile = fileDirectory.appendingPathComponent("notes.txt")
        let imageFile = fileDirectory.appendingPathComponent("draft.png")
        try! Data("captured notes\n".utf8).write(to: textFile)
        try! red.png.write(to: imageFile)
        let copiedFiles = [textFile.standardizedFileURL, imageFile.standardizedFileURL]
        let fileCopy = await pipeline.process(
            snapshot(text: "notes.txt", imageData: red.png, imageIsPNG: true,
                     fileURLs: copiedFiles))
        expect(fileCopy?.content == .files(copiedFiles),
               "Copied files preserve their ordered URL set ahead of text and image representations")

        let limit = ClipboardCapturePipeline.maxTextBytes
        let capped = await pipeline.process(snapshot(text: String(repeating: "a", count: limit)))
        expect(capped?.content == .text(String(repeating: "a", count: limit)),
               "Text exactly at the size cap is captured")
        let oversized = await pipeline.process(snapshot(text: String(repeating: "a", count: limit + 1)))
        expect(oversized == nil, "Text beyond the size cap is dropped")

        let blank = await pipeline.process(snapshot(text: "  \n\t "))
        expect(blank == nil, "Whitespace-only text is dropped")

        print("PASS: capture policy, file capture precedence, PNG passthrough, TIFF normalization, text limits")
    }
}
