import AppKit
import Metal
import SwiftUI
@testable import Kit

private actor ImageLayoutProbe {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<ImageTextLayout?, Never>?

    func recognize(_ url: URL) async -> ImageTextLayout? {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForCall() async {
        let deadline = Date().addingTimeInterval(5)
        while calls == 0, Date() < deadline { await Task.yield() }
        precondition(calls == 1, "The asynchronous geometry request starts")
    }

    func release(_ layout: ImageTextLayout) {
        continuation!.resume(returning: layout)
        continuation = nil
    }
}

@MainActor @Observable
private final class ImageHighlightFixture {
    var query = ""
    var highlights: [CGRect] = []
    var presented = false
}

private struct ImageHighlightPreviewFixture: View {
    let item: ClipboardItem
    let core: AppCore
    let fixture: ImageHighlightFixture

    var body: some View {
        ClipboardPreview(item: item, query: fixture.query, vm: core.palette,
                         store: core.clipboardStore, settings: core.settings)
    }
}

private struct ImageHighlightAnchorFixture: View {
    let url: URL
    @Bindable var fixture: ImageHighlightFixture

    var body: some View {
        ImageQuickLookAnchor(url: url, highlights: fixture.highlights,
                             isPresented: $fixture.presented)
    }
}

@MainActor
enum ImageSearchHighlightTests {
    private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    private static func line(_ text: String, y: CGFloat) -> ImageTextLayout.Line {
        ImageTextLayout.Line(text: text, characterBounds: text.enumerated().map { index, _ in
            CGRect(x: 0.03 + CGFloat(index) * 0.03, y: y, width: 0.025, height: 0.08)
        })
    }

    private static func matchingAndGeometry() {
        let lines = [line("  账 户管理 ＡＰＩ café ﬃ 😀  ", y: 0.7),
                     line("账户 Alpha API", y: 0.4)]
        let layout = ImageTextLayout(lines: lines)
        precondition(layout.text == ClipboardImageTextRecognition.normalizedText(
            lines.map(\.text).joined(separator: "\n")), "Geometry uses the indexer's normalization")
        for query in ["账户", "账 户", "zhanghu", "ＡＰＩ", "api", "cafe", "ffi", "😀"] {
            precondition(!layout.matchingBounds(query: query).isEmpty, "Normalized image match: \(query)")
        }
        let chinese = layout.matchingBounds(query: "zhanghu")
        precondition(chinese.count == 2, "Repeated pinyin hits retain separate line geometry")
        precondition(close(chinese[0].minX, 0.09) && close(chinese[0].width, 0.085),
                     "Removing Han spaces preserves the original character coordinates")
        precondition(close(chinese[0].minY, 0.7) && close(chinese[1].minY, 0.4))
        precondition(layout.matchingBounds(query: " ").isEmpty)
        precondition(layout.matchingBounds(query: "missing").isEmpty)
        let crossLine = ImageTextLayout(lines: [line("API", y: 0.7), line("账户", y: 0.4)])
        precondition(crossLine.matchingBounds(query: "API\n账").count == 2,
                     "A cross-line query paints each line separately")
        let sameWord = CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.1)
        let overlapping = ImageTextLayout(lines: [.init(text: "Aa", characterBounds: [sameWord, sameWord])])
        let deduplicated = overlapping.matchingBounds(query: "a")
        precondition(deduplicated.count == 1 && close(deduplicated[0].minX, sameWord.minX)
                     && close(deduplicated[0].width, sameWord.width),
                     "Word-precision OCR boxes are painted once even for repeated substring hits")
        let unlocated = ImageTextLayout(lines: [.init(text: "API", characterBounds: [nil, nil, nil])])
        precondition(unlocated.matchingBounds(query: "api").isEmpty, "Missing geometry cannot highlight unrelated pixels")

        let wide = ImageSearchHighlightOverlay.imageRect(
            imageSize: CGSize(width: 1000, height: 500), in: CGSize(width: 300, height: 300))
        precondition(wide == CGRect(x: 0, y: 75, width: 300, height: 150))
        let tall = ImageSearchHighlightOverlay.imageRect(
            imageSize: CGSize(width: 500, height: 1000), in: CGSize(width: 300, height: 300))
        precondition(tall == CGRect(x: 75, y: 0, width: 150, height: 300))
        let display = ImageSearchHighlightOverlay.displayRect(
            CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), imageRect: wide)
        precondition(close(display.minX, 30) && close(display.minY, 105)
                     && close(display.width, 60) && close(display.height, 15),
                     "Vision coordinates scale into the fitted image, including letterboxing and the Y flip")
        print("PASS: image highlight literal/pinyin, full-width/diacritics/ligatures, original offsets, cross-line/repeated hits, fit and Y origin")
    }

    private static func cacheLifecycle(in directory: URL) async {
        ImageSearchHighlightPayload.purge()
        let layout = ImageTextLayout(lines: [line("Alpha 账户", y: 0.5)])
        let url = directory.appendingPathComponent("cache.png")
        let cached = await ImageSearchHighlightPayload.load(url, recognize: { _ in layout })!
        let reused = await ImageSearchHighlightPayload.load(url, recognize: { _ in
            preconditionFailure("Changing the query or opening Quick Look cannot repeat OCR")
        })!
        precondition(cached === reused)
        precondition(!reused.layout.matchingBounds(query: "alpha").isEmpty)
        precondition(!reused.layout.matchingBounds(query: "zhanghu").isEmpty)
        precondition(reused.layout.matchingBounds(query: "").isEmpty)
        ImageSearchHighlightPayload.purge()
        precondition(ImageSearchHighlightPayload.cached(for: url) == nil)

        let staleProbe = ImageLayoutProbe()
        let stale = Task { await ImageSearchHighlightPayload.load(url, recognize: { await staleProbe.recognize($0) }) }
        await staleProbe.waitForCall()
        ImageSearchHighlightPayload.purge()
        await staleProbe.release(layout)
        _ = await stale.value
        precondition(ImageSearchHighlightPayload.cached(for: url) == nil,
                     "An OCR result from a dismissed palette cannot repopulate its cache")
        let cancelledProbe = ImageLayoutProbe()
        let cancelled = Task { await ImageSearchHighlightPayload.load(url, recognize: { await cancelledProbe.recognize($0) }) }
        await cancelledProbe.waitForCall()
        cancelled.cancel()
        await cancelledProbe.release(layout)
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil && ImageSearchHighlightPayload.cached(for: url) == nil,
                     "Cancelled selection work cannot publish or cache stale regions")
        print("PASS: image geometry cache reuse, query/clear, session purge, stale and cancelled recognition")
    }

    private static var fixtureLines: [(text: String, origin: NSPoint, font: NSFont)] {
        [
            ("Alpha TARGET Omega TARGET", NSPoint(x: 45, y: 350),
             NSFont.monospacedSystemFont(ofSize: 44, weight: .regular)),
            ("中文图片搜索 账户管理", NSPoint(x: 45, y: 160), NSFont.systemFont(ofSize: 46)),
        ]
    }

    /// The same font metrics drive the PNG and injected OCR boxes on virtual runners.
    private static func fixtureLayout() -> ImageTextLayout {
        ImageTextLayout(lines: fixtureLines.map { line in
            let attributes: [NSAttributedString.Key: Any] = [.font: line.font]
            return ImageTextLayout.Line(text: line.text, characterBounds: line.text.indices.map { index in
                let lower = (String(line.text[..<index]) as NSString).size(withAttributes: attributes).width
                let next = line.text.index(after: index)
                let upper = (String(line.text[..<next]) as NSString).size(withAttributes: attributes).width
                return CGRect(x: (line.origin.x + lower) / 1000, y: line.origin.y / 500,
                              width: (upper - lower) / 1000, height: line.font.pointSize / 500)
            })
        })
    }

    private static func fixturePNG() -> Data {
        let image = NSImage(size: NSSize(width: 1000, height: 500))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 500).fill()
        for line in fixtureLines {
            (line.text as NSString).draw(at: line.origin,
                withAttributes: [.font: line.font, .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func tintedPixels(before: NSBitmapImageRep, after: NSBitmapImageRep) -> Int {
        precondition(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh,
                     "Search emphasis cannot resize a preview")
        var count = 0
        for y in stride(from: 0, to: before.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: before.pixelsWide, by: 2) {
                let a = before.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let b = after.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if a.redComponent - b.redComponent > 0.06 && b.blueComponent - b.redComponent > 0.06 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(350))
    }

    private static func quickLookHosting(in view: NSView) -> NSHostingView<ImageQuickLookContent>? {
        if let hosting = view as? NSHostingView<ImageQuickLookContent> { return hosting }
        return view.subviews.lazy.compactMap { quickLookHosting(in: $0) }.first
    }

    private static func rendering(in directory: URL, injectedLayout: ImageTextLayout? = nil) async throws {
        let data = fixturePNG()
        let store = ClipboardStore(directory: directory, recognizeImage: { url in
            if let injectedLayout { return .recognized(injectedLayout.text) }
            return await ClipboardImageTextRecognition.recognize(url)
        })
        await store.addImage(data, sourceBundleID: nil)
        await store.waitForImageOCR()
        let item = store.items.first!
        let url = store.imageURL(for: item)!
        guard let payload = await ImageSearchHighlightPayload.load(url, recognize: { url in
            if let injectedLayout { return injectedLayout }
            return await ImageSearchHighlightPayload.recognize(url)
        }) else {
            preconditionFailure("Vision geometry failed; persisted OCR status: \(String(describing: item.imageOCR?.status))")
        }
        precondition(item.imageOCR?.text == payload.layout.text,
                     "Preview recognition agrees with persisted search text")
        let english = payload.layout.matchingBounds(query: "target")
        precondition(english.count == 2 && english.allSatisfy { $0.minY > 0.6 && $0.width < 0.25 },
                     "Recognition locates both target words instead of highlighting the whole line")
        let chinese = payload.layout.matchingBounds(query: "zhanghu")
        precondition(!chinese.isEmpty && chinese.allSatisfy { $0.maxY < 0.6 },
                     "Recognition maps a pinyin hit to the lower Chinese text")

        let core = AppCore(clipboardStore: store)
        let fixture = ImageHighlightFixture()
        let hosting = NSHostingView(rootView: ImageHighlightPreviewFixture(item: item, core: core, fixture: fixture))
        hosting.frame = NSRect(x: 0, y: 0, width: 350, height: 480)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        let plain = snapshot(hosting)
        fixture.query = "target"
        try await settle()
        let highlighted = snapshot(hosting)
        precondition(tintedPixels(before: plain, after: highlighted) > 100,
                     "The actual right preview paints translucent blue over matching image words")
        fixture.query = "zhanghu"
        try await settle()
        let chineseHighlighted = snapshot(hosting)
        precondition(tintedPixels(before: plain, after: chineseHighlighted) > 50,
                     "A pinyin query paints the matching Chinese characters in the actual preview")
        fixture.query = ""
        try await settle()
        precondition(tintedPixels(before: plain, after: snapshot(hosting)) == 0,
                     "Clearing search removes image emphasis immediately")

        // Mount the real AppKit popover anchor, then deliver late OCR geometry while it is open.
        let anchor = NSHostingView(rootView: ImageHighlightAnchorFixture(url: url, fixture: fixture))
        let screen = NSScreen.main!.visibleFrame
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: screen.midX, y: screen.midY, width: 300, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.appearance = NSAppearance(named: .aqua)
        anchorWindow.contentView = anchor
        anchorWindow.makeKeyAndOrderFront(nil)
        defer { ImageQuickLook.close(); anchorWindow.close() }
        fixture.presented = true
        try await settle()
        let popover = NSApp.windows.compactMap { $0.contentView.flatMap(quickLookHosting(in:)) }.first!
        let originalWindow = popover.window!
        let popoverPlain = snapshot(popover)
        fixture.highlights = english
        try await settle()
        precondition(popover.window === originalWindow && popover.rootView.highlights == english,
                     "Late geometry updates the shown popover without closing or replacing it")
        let popoverHighlighted = snapshot(popover)
        precondition(tintedPixels(before: popoverPlain, after: popoverHighlighted) > 500,
                     "The actual Quick Look content paints the same matching regions")
        fixture.highlights = chinese
        try await settle()
        precondition(popover.rootView.highlights == chinese, "Quick Look updates its regions in place")
        let chinesePopover = snapshot(popover)
        precondition(tintedPixels(before: popoverPlain, after: chinesePopover) > 200,
                     "Quick Look paints a pinyin match on the Chinese image text")
        fixture.highlights = []
        try await settle()
        precondition(tintedPixels(before: popoverPlain, after: snapshot(popover)) == 0,
                     "Quick Look can remove all search emphasis without retaining old regions")

        if let artifactPath = ProcessInfo.processInfo.environment["KIT_IMAGE_HIGHLIGHT_ARTIFACT_DIR"] {
            let output = URL(fileURLWithPath: artifactPath, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try highlighted.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("right-preview.png"))
            try popoverHighlighted.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("popover.png"))
            try chineseHighlighted.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("right-preview-pinyin.png"))
            try chinesePopover.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("popover-pinyin.png"))
        }
        let recognition = injectedLayout == nil ? "real Vision" : "injected OCR"
        print("PASS: \(recognition), Chinese/English right preview and popover pixels, stable layout, clear, late geometry and live popover updates")
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kit-image-highlight-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory); ImageSearchHighlightPayload.purge() }
        matchingAndGeometry()
        await cacheLifecycle(in: directory)
        // Always exercise rendering with deterministic geometry. Paravirtual Metal devices
        // cannot run Vision's image reader even when its compute stage is assigned to the CPU.
        try await rendering(in: directory.appendingPathComponent("fixture"), injectedLayout: fixtureLayout())
        if MTLCreateSystemDefaultDevice()?.name.localizedCaseInsensitiveContains("paravirtual") == true {
            print("SKIP: real Vision integration on a paravirtual GPU; injected OCR rendering checks passed")
        } else {
            ImageSearchHighlightPayload.purge()
            try await rendering(in: directory.appendingPathComponent("vision"))
        }
    }
}
