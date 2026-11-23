import AppKit
import SwiftUI

/// Owns pinned-content panels independently from the clipboard palette. Each clipboard item gets
/// at most one panel; pinning it again brings the existing panel forward. Panels follow regular
/// Spaces and hide on exclusive fullscreen Spaces.
@MainActor
final class PinnedWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var panels: [ClipboardItem.ID: PinnedWindowPanel] = [:]
    private var hiddenForFullscreen: Set<ClipboardItem.ID> = []
    private var spaceObservers: [NotificationToken] = []
    private var fullscreenSyncTask: Task<Void, Never>?
    private var observesExclusiveFullScreen = false
    private var titleObserver: ObservationToken?

    init(core: AppCore) {
        self.core = core
    }

    func contains(_ itemID: ClipboardItem.ID) -> Bool { panels[itemID] != nil }

    func reveal(_ itemID: ClipboardItem.ID) {
        guard let panel = panels[itemID] else { return }
        reveal(panel, itemID: itemID)
    }

    func showImage(
        itemID: ClipboardItem.ID,
        title: String,
        preferredLongEdge: CGFloat,
        image: NSImage
    ) {
        let visibleFrame = targetVisibleFrame()
        let geometry = PinnedImageGeometry(
            imageSize: image.size,
            visibleFrame: visibleFrame,
            preferredLongEdge: preferredLongEdge
        )
        let panel = makePanel(title: title, frame: geometry.frame)
        panel.geometry = geometry
        panel.contentAspectRatio = geometry.baseSize
        let onClose = closeAction(for: itemID)
        panel.onClose = onClose

        install(
            PinnedImageContent(
                image: image,
                onClose: onClose
            ),
            in: panel
        )
        present(panel, itemID: itemID)
    }

    func showText(item: ClipboardItem, text: String) {
        let settings = core.settings
        let locale = settings.language.locale
        let frame = PinnedTextContent.initialFrame(text: text, kind: item.kind, visibleFrame: targetVisibleFrame())
        let panel = makePanel(title: item.displayTitle(locale: locale), frame: frame)
        panel.onClose = closeAction(for: item.id)
        install(PinnedTextContent(text: text, kind: item.kind, settings: settings), in: panel)
        present(panel, itemID: item.id)
    }

    var imageDecodeMaxPixel: CGFloat {
        NSScreen.screens.reduce(CGFloat(1_600)) { result, candidate in
            max(
                result,
                max(candidate.visibleFrame.width, candidate.visibleFrame.height)
                    * candidate.backingScaleFactor
            )
        }
    }

    private func activate(_ panel: PinnedWindowPanel) {
        // Trackpad gesture events are delivered to the active application. The clipboard palette
        // is intentionally non-activating. Pinned windows need mouse gestures and key events.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Bring an existing panel forward unless its display is in exclusive fullscreen.
    private func reveal(_ panel: PinnedWindowPanel, itemID: ClipboardItem.ID) {
        panel.fitToScreen()
        if hidesForExclusiveFullScreen(panel) {
            hideForFullscreen(itemID, panel)
            return
        }
        hiddenForFullscreen.remove(itemID)
        activate(panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? PinnedWindowPanel,
            let itemID = itemID(for: panel)
        else { return }
        panels.removeValue(forKey: itemID)
        hiddenForFullscreen.remove(itemID)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (notification.object as? PinnedWindowPanel)?.fitToScreen()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let panel = sender as? PinnedWindowPanel, let geometry = panel.geometry else {
            return frameSize
        }
        let minimum = geometry.minimumFrameSize
        if frameSize.width < minimum.width || frameSize.height < minimum.height {
            return minimum
        }
        return frameSize
    }

    private func close(_ itemID: ClipboardItem.ID) {
        hiddenForFullscreen.remove(itemID)
        panels[itemID]?.close()
    }

    private func closeAction(for itemID: ClipboardItem.ID) -> () -> Void {
        { [weak self] in self?.close(itemID) }
    }

    private func itemID(for panel: PinnedWindowPanel) -> ClipboardItem.ID? {
        panels.first(where: { $0.value === panel })?.key
    }

    private func observeTitlesIfNeeded() {
        guard titleObserver == nil else { return }
        titleObserver = core.clipboardStore.observeRevision { [weak self] in
            self?.syncPanelTitles()
        }
    }

    private func syncPanelTitles() {
        let locale = core.settings.language.locale
        let store = core.clipboardStore
        for (id, panel) in panels {
            let title = store.item(id: id)?.displayTitle(locale: locale) ?? ""
            if !title.isEmpty, panel.title != title {
                panel.title = title
            }
        }
    }

    private func makePanel(title: String, frame: CGRect) -> PinnedWindowPanel {
        let panel = PinnedWindowPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        // Follow regular Spaces, but stay off exclusive fullscreen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    private func install(_ view: some View, in panel: PinnedWindowPanel) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Theme.Radius.panel
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        // Apply frame constraints after hosting installation and enforce them during live resize
        if let geometry = panel.geometry {
            panel.minSize = geometry.minimumFrameSize
        }
    }

    private func present(_ panel: PinnedWindowPanel, itemID: ClipboardItem.ID) {
        observeExclusiveFullScreenIfNeeded()
        observeTitlesIfNeeded()
        panels[itemID] = panel
        reveal(panel, itemID: itemID)
    }

    private func observeExclusiveFullScreenIfNeeded() {
        guard !observesExclusiveFullScreen else { return }
        observesExclusiveFullScreen = true
        let workspace = NSWorkspace.shared.notificationCenter
        spaceObservers = [
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: workspace
            ),
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: workspace
            ),
            NotificationToken(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main,
                    using: { [weak self] (_: Notification) -> Void in
                        MainActor.assumeIsolated {
                            self?.panels.values.forEach { $0.fitToScreen() }
                            self?.handleSpaceChange()
                            return
                        }
                    }
                ),
                center: .default
            ),
        ]
    }

    private func handleSpaceChange() {
        scheduleFullscreenSync()
    }

    private func scheduleFullscreenSync() {
        syncFullscreenVisibility()
        fullscreenSyncTask?.cancel()
        fullscreenSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            syncFullscreenVisibility()
        }
    }

    private func syncFullscreenVisibility() {
        for (itemID, panel) in panels {
            if hidesForExclusiveFullScreen(panel) {
                hideForFullscreen(itemID, panel)
            } else if hiddenForFullscreen.remove(itemID) != nil {
                panel.orderFrontRegardless()
            }
        }
    }

    private func hideForFullscreen(_ itemID: ClipboardItem.ID, _ panel: PinnedWindowPanel) {
        hiddenForFullscreen.insert(itemID)
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func hidesForExclusiveFullScreen(_ panel: PinnedWindowPanel) -> Bool {
        guard let screen = screen(for: panel) else { return false }
        return ExclusiveFullScreen.contains(screen)
    }

    private func screen(for panel: NSPanel) -> NSScreen? {
        panel.screen
            ?? NSScreen.screens.first {
                NSMouseInRect(
                    NSPoint(x: panel.frame.midX, y: panel.frame.midY), $0.frame, false)
            }
            ?? NSScreen.main
    }

    private func targetVisibleFrame() -> CGRect {
        targetScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// Exclusive macOS fullscreen (a dedicated Space that owns the whole display), not a zoomed
/// window that still leaves the menu bar visible.
@MainActor
private enum ExclusiveFullScreen {
    static func contains(_ screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visible = screen.visibleFrame
        // A zoomed window keeps the menu bar, so `visibleFrame` is inset from `frame`.
        guard abs(frame.width - visible.width) < 1, abs(frame.height - visible.height) < 1 else {
            return false
        }
        return hasWindowCoveringDisplay(screen)
    }

    /// A layer-0 window that fills `screen.frame` (including the menu-bar strip). Finder's
    /// desktop and the Dock are excluded so an auto-hidden menu bar on the Desktop is not
    /// treated as fullscreen.
    private static func hasWindowCoveringDisplay(_ screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let screenFrame = screen.frame
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                alpha > 0.9,
                let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                ownerPID != Int(ourPID),
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { continue }

            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" { continue }

            let cocoa = cocoaRect(fromCGWindow: CGRect(x: x, y: y, width: width, height: height))
            guard abs(cocoa.width - screenFrame.width) < 4,
                abs(cocoa.height - screenFrame.height) < 4,
                cocoa.intersects(screenFrame)
            else { continue }
            return true
        }
        return false
    }

    /// `kCGWindowBounds` origin is the top-left of the primary display, Y increasing down.
    private static func cocoaRect(fromCGWindow bounds: CGRect) -> CGRect {
        let primaryHeight =
            NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? bounds.height
        return CGRect(
            x: bounds.origin.x,
            y: primaryHeight - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }
}
