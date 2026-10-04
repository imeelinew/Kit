import AppKit
import SwiftUI
@testable import Kit

/// Exercises the real palette against disposable history, without starting clipboard monitoring.
@MainActor
enum ClipboardPreviewLifecycleTests {
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func textView(in view: NSView) -> PreviewTextView? {
        if let text = view as? PreviewTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-preview-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("fixture") })
        let core = AppCore(clipboardStore: store)
        let vm = core.palette
        let controller = PaletteWindowController(core: core)
        defer { controller.hide(restoreFocus: false) }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 900, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
        await store.addImage(bitmap.representation(using: .png, properties: [:])!, sourceBundleID: nil)
        await store.waitForImageOCR()
        let item = store.items.first!
        let url = store.imageURL(for: item)!

        controller.prewarm()
        await settle()
        precondition(!vm.isPreviewActive && vm.preparedPreview == nil,
                     "Prewarming the window does not prepare a hidden image preview")
        precondition(ClipboardPreviewPayload.cached(for: item) == nil,
                     "Hidden search results do not warm preview payloads")
        let row = await ImageThumbnail.loadAsync(url, maxPixel: 512)
        precondition(row != nil)

        await vm.prepare()
        precondition(vm.isPreviewActive && vm.preparedPreview?.image != nil,
                     "Opening prepares the complete first-frame image")
        weak let releasedPayload = vm.preparedPreview
        controller.hide(restoreFocus: false)
        await settle()
        precondition(!vm.isPreviewActive && vm.preparedPreview == nil)
        precondition(releasedPayload == nil, "Hiding releases the prepared and cached payload")
        precondition(ClipboardPreviewPayload.cached(for: item) == nil)
        precondition(ImageThumbnail.cached(url, maxPixel: 900) == nil)
        precondition(ImageThumbnail.cached(url, maxPixel: 512) === row,
                     "Hiding keeps list thumbnails warm")

        // An active pinned image owns its bitmap independently of the palette cache.
        let pinnedHosting = NSHostingView(rootView: PinnedImageContent(
            url: url, decodeMaxPixel: 1600, onClose: {}))
        pinnedHosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let pinnedWindow = NSWindow(
            contentRect: pinnedHosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        pinnedWindow.isReleasedWhenClosed = false
        pinnedWindow.contentView = pinnedHosting
        defer { pinnedWindow.close() }
        pinnedHosting.layoutSubtreeIfNeeded()
        await settle()
        weak let pinnedBitmap = ImageThumbnail.cached(url, maxPixel: 1600)
        precondition(pinnedBitmap != nil, "Pinned content loads its own image")
        controller.hide(restoreFocus: false)
        await settle()
        precondition(ImageThumbnail.cached(url, maxPixel: 1600) == nil)
        precondition(pinnedBitmap != nil, "Purging palette caches preserves an active pinned image")

        // Start a cold load, then purge before its asynchronous result can be cached.
        var started = false
        let loading = Task {
            started = true
            return await ClipboardPreviewPayload.load(for: item, imageURL: url)
        }
        while !started { await Task.yield() }
        controller.hide(restoreFocus: false)
        _ = await loading.value
        precondition(ClipboardPreviewPayload.cached(for: item) == nil,
                     "A load from the previous session cannot refill the payload cache")
        precondition(ImageThumbnail.cached(url, maxPixel: 900) == nil,
                     "A decode from the previous session cannot refill the bitmap cache")

        for cycle in 0..<10 {
            let text = store.addText("Hidden capture \(cycle)", kind: .text, sourceBundleID: nil)!
            await settle()
            precondition(vm.results.contains { $0.id == text.id }, "Hidden captures still update history")
            precondition(ClipboardPreviewPayload.cached(for: text) == nil,
                         "Hidden captures do not prepare preview metadata")
            await vm.prepare()
            precondition(vm.selectedID == text.id && vm.preparedPreview?.itemID == text.id)
            weak let textPayload = vm.preparedPreview
            controller.hide(restoreFocus: false)
            await settle()
            precondition(textPayload == nil, "Repeated presentations release each payload")
        }

        let source = String(repeating: "A long preview line\n", count: 3000)
        _ = store.addText(source, kind: .text, sourceBundleID: nil)
        await settle()
        await vm.prepare()
        let hosting = NSHostingView(rootView: RootPaletteView(vm: vm, store: store, settings: core.settings))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        await settle()
        weak let releasedTextView = textView(in: hosting)
        precondition(releasedTextView?.string == source, "The active pane hosts the complete text preview")
        controller.hide(restoreFocus: false)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        precondition(textView(in: hosting) == nil,
                     "Hiding unmounts the preview")
        precondition(releasedTextView == nil || releasedTextView?.textStorage?.length == 0,
                     "Detached preview views release their TextKit storage")
        await vm.prepare()
        hosting.layoutSubtreeIfNeeded()
        await settle()
        precondition(textView(in: hosting)?.string == source, "Reopening restores the preview")

        print("PASS: hidden prewarm/captures, payload and TextKit release, warm row cache, pinned image survival, stale-load invalidation, repeated reopen")
    }
}
