import AppKit
import Observation
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

    @MainActor
    private final class CloseProbe: NSObject {
        let core: AppCore
        let panel: PalettePanel
        let selectedID: ClipboardItem.ID
        var isHiding = false
        var checkedClose = false
        var shownPopover: NSPopover?

        init(core: AppCore, panel: PalettePanel, selectedID: ClipboardItem.ID) {
            self.core = core
            self.panel = panel
            self.selectedID = selectedID
        }

        @objc func didShow(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                popover.contentViewController?.view.window?.parent === panel else { return }
            shownPopover = popover
        }

        @objc func willClose(_ notification: Notification) {
            guard isHiding, notification.object as? NSPopover === shownPopover else { return }
            checkedClose = true
            precondition(panel.alphaValue == 0,
                         "The palette is invisible before AppKit starts closing its popover")
            precondition(core.palette.selectedID == selectedID && core.palette.isPreviewActive,
                         "Popover teardown starts before resetting selection and preview")
            // AppKit can call back into palette dismissal while restoring key focus.
            core.hidePalette(restoreFocus: false)
            precondition(core.palette.selectedID == selectedID && core.palette.isPreviewActive,
                         "A reentrant hide cannot reset the presentation during popover teardown")
        }
    }

    /// Closes the palette through the global shortcut while its AppKit popover is still open.
    private static func quickLookDismissal(core: AppCore, item: ClipboardItem) async throws {
        let vm = core.palette
        let first = core.clipboardStore.addText("First result", kind: .text, sourceBundleID: nil)!
        defer {
            core.hidePalette(restoreFocus: false)
            core.clipboardStore.remove(first)
        }
        core.showPalette()
        for _ in 0..<100 {
            if NSApp.windows.contains(where: {
                ($0 as? PalettePanel)?.paletteViewModel === vm && $0.isVisible
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let panel = NSApp.windows.compactMap({ $0 as? PalettePanel }).first(where: {
            $0.isVisible && $0.paletteViewModel === vm
        }) else { preconditionFailure("The palette must finish presenting") }
        precondition(panel.alphaValue == 1 && vm.selectedID == first.id && vm.isPreviewActive,
                     "Reopening restores opacity and prepares the first selection")
        vm.select(item.id)
        await settle()
        let probe = CloseProbe(core: core, panel: panel, selectedID: item.id)
        NotificationCenter.default.addObserver(
            probe, selector: #selector(CloseProbe.willClose(_:)),
            name: NSPopover.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            probe, selector: #selector(CloseProbe.didShow(_:)),
            name: NSPopover.didShowNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(probe) }
        vm.toggleImageQuickLook(for: item.id)
        for _ in 0..<100 {
            if probe.shownPopover?.isShown == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let popover = probe.shownPopover, popover.isShown,
            let previewWindow = popover.contentViewController?.view.window,
            previewWindow.isVisible else {
            preconditionFailure(
                "The regression must exercise a real, visible NSPopover, "
                    + "paletteVisible=\(panel.isVisible), requested=\(vm.imageQuickLookOpen), "
                    + "selectedImage=\(vm.selectedID == item.id), searchReady=\(vm.searchReady)")
        }
        probe.isHiding = true
        let displayedContent = panel.contentView!
        withObservationTracking {
            _ = vm.isPreviewActive
        } onChange: {
            MainActor.assumeIsolated {
                precondition(displayedContent.window == nil,
                             "Preview teardown must not render into the closing window")
            }
        }
        core.togglePalette() // The global close shortcut's entry point.
        probe.isHiding = false
        precondition(!panel.isVisible && panel.alphaValue == 0,
                     "Closing removes the palette from AppKit's visible window list")
        precondition(panel.contentView == nil && displayedContent.window == nil,
                     "Resetting the detached tree cannot change the closing window's pixels")
        precondition(!previewWindow.isVisible || previewWindow.alphaValue == 0,
                     "Closing does not leave a popover exit animation onscreen")
        precondition(vm.selectedID == first.id && !vm.isPreviewActive && !vm.imageQuickLookOpen,
                     "Selection and preview reset after the windows become invisible")
        precondition(probe.checkedClose, "The open-popover close callback was exercised")
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            precondition(!panel.isVisible,
                         "Delayed popover and focus callbacks cannot bring the palette back")
        }
        precondition(panel.contentView != nil && !vm.isPreviewActive,
                     "After dismissal settles, the attached hidden tree is ready without a preview")
        print("PASS: real popover teardown, shortcut hide, reentrant close, settled hidden tree")
    }

    private static func multiFilePreviewLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-file-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<8).map { root.appendingPathComponent("preview-file-\($0).txt") }
        for url in urls { try Data("fixture".utf8).write(to: url) }
        let store = ClipboardStore(directory: root.appendingPathComponent("store"))
        let item = store.addFiles(urls, sourceBundleID: nil)!
        let core = AppCore(clipboardStore: store)
        defer { withExtendedLifetime(core) {} }
        let hosting = NSHostingView(rootView: ClipboardPreview(
            item: item, vm: core.palette, store: store, settings: core.settings))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for height: CGFloat in [280, 160, 420] {
            window.setContentSize(NSSize(width: 420, height: height))
            hosting.layoutSubtreeIfNeeded()
            await settle()
            hosting.layoutSubtreeIfNeeded()
            let pane = descendants(hosting).first { String(describing: type(of: $0)) == "ClipboardPreviewPane" }!
            let content = pane.subviews.first!
            let title = pane.subviews.compactMap { $0 as? NSTextField }.first!
            let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
            let viewport = pane.convert(scroll.bounds, from: scroll)
            precondition(viewport.minY >= -1 && viewport.maxY <= title.frame.minY + 1,
                         "The file scroll viewport stays above the information region at every pane height")
            precondition(scroll.contentSize.height > 0 && scroll.documentView!.frame.height > scroll.contentSize.height,
                         "A constrained multi-file preview scrolls internally instead of expanding outside its pane")
            precondition(content.layer?.masksToBounds == true,
                         "Hosted preview content cannot draw into adjacent palette regions")
        }
        print("PASS: multi-file preview viewport, internal scrolling and clipping across pane sizes")
    }

    static func run() async throws {
        try await multiFilePreviewLayout()
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
        try await quickLookDismissal(core: core, item: item)

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
        precondition(ImageThumbnail.cached(url, maxPixel: 512) === row,
                     "Hiding keeps list thumbnails warm")

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

        for cycle in 0..<3 {
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
        precondition(textView(in: hosting) == nil, "Hiding unmounts the preview")
        precondition(releasedTextView == nil || releasedTextView?.textStorage?.length == 0,
                     "Detached preview views release their TextKit storage")
        await vm.prepare()
        hosting.layoutSubtreeIfNeeded()
        await settle()
        precondition(textView(in: hosting)?.string == source, "Reopening restores the preview")

        print("PASS: hidden prewarm/captures, payload and TextKit release, warm row cache, stale-load invalidation")
    }
}
