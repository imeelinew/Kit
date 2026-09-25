import AppKit
import Combine
import SwiftUI

/// Owns pinned-content panels independently from the clipboard palette. Each clipboard item gets
/// at most one panel; pinning it again brings the existing panel forward. Panels follow regular
/// Spaces and hide on exclusive fullscreen Spaces.
@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    private var panels: [ClipboardItem.ID: PinnedImagePanel] = [:]
    private var closingPanels: Set<ClipboardItem.ID> = []
    private var hiddenForFullscreen: Set<ClipboardItem.ID> = []
    private var spaceObservers: [NotificationToken] = []
    private var fullscreenSyncTask: Task<Void, Never>?
    private var observesExclusiveFullScreen = false
    private var titleObserver: AnyCancellable?

    func show(
        itemID: ClipboardItem.ID,
        url: URL,
        title: String,
        preferredLongEdge: @escaping () -> CGFloat
    ) {
        observeExclusiveFullScreenIfNeeded()
        observeTitlesIfNeeded()
        if let panel = panels[itemID] {
            reveal(panel, itemID: itemID)
            return
        }

        let visibleFrame = targetVisibleFrame()
        let pixelSize = ImageThumbnail.pixelSize(of: url) ?? CGSize(width: 1_200, height: 900)
        let imageSize = NSImage(contentsOf: url)?.size ?? pixelSize
        let initialSize = PinnedImageLayout.initialSize(
            imageSize: imageSize,
            visibleFrame: visibleFrame,
            preferredLongEdge: preferredLongEdge()
        )
        let panel = makePanel(
            title: title,
            initialSize: initialSize,
            aspectRatio: imageSize,
            minSize: PinnedImageLayout.minimumSize(
                imageSize: imageSize,
                visibleFrame: visibleFrame
            )
        )
        panel.onClose = { [weak self] in
            self?.close(itemID)
        }

        install(
            PinnedImageContent(
                itemID: itemID,
                url: url,
                decodeMaxPixel: imageDecodeMaxPixel,
                onClose: { [weak self] in self?.close(itemID) }
            ),
            in: panel
        )
        present(panel, size: initialSize, in: visibleFrame, itemID: itemID)
    }

    private var imageDecodeMaxPixel: CGFloat {
        NSScreen.screens.reduce(CGFloat(1_600)) { result, candidate in
            max(
                result,
                max(candidate.visibleFrame.width, candidate.visibleFrame.height)
                    * candidate.backingScaleFactor
            )
        }
    }

    private func activate(_ panel: PinnedImagePanel) {
        // Trackpad gesture events are delivered to the active application. The clipboard palette
        // is intentionally non-activating, but an interactive pinned image cannot be: activating
        // here lets AppKit route physical magnify events to this window.
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
    private func reveal(_ panel: PinnedImagePanel, itemID: ClipboardItem.ID) {
        if hidesForExclusiveFullScreen(panel) {
            hideForFullscreen(itemID, panel)
            return
        }
        hiddenForFullscreen.remove(itemID)
        applyVisibleAlpha(to: panel)
        activate(panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? PinnedImagePanel,
            let itemID = itemID(for: panel)
        else { return }
        panels.removeValue(forKey: itemID)
        closingPanels.remove(itemID)
        hiddenForFullscreen.remove(itemID)
    }

    private func close(_ itemID: ClipboardItem.ID) {
        hiddenForFullscreen.remove(itemID)
        guard let panel = panels[itemID], closingPanels.insert(itemID).inserted else { return }

        panel.ignoresMouseEvents = true
        let targetFrame = Self.scaledFrame(panel.frame, scale: 0.96)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        }

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let panel,
                closingPanels.contains(itemID), panels[itemID] === panel
            else { return }
            panel.close()
        }
    }

    private func itemID(for panel: PinnedImagePanel) -> ClipboardItem.ID? {
        panels.first(where: { $0.value === panel })?.key
    }

    private func observeTitlesIfNeeded() {
        guard titleObserver == nil else { return }
        titleObserver = AppCore.shared.clipboardStore.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncPanelTitles()
            }
    }

    private let visibleAlpha: CGFloat = 1

    private func applyVisibleAlpha(to panel: PinnedImagePanel) {
        panel.alphaValue = visibleAlpha
        panel.ignoresMouseEvents = false
    }

    private func syncPanelTitles() {
        let locale = AppCore.shared.settings.language.locale
        let store = AppCore.shared.clipboardStore
        for (id, panel) in panels {
            let title = store.item(id: id)?.displayTitle(locale: locale) ?? ""
            if !title.isEmpty, panel.title != title {
                panel.title = title
            }
        }
    }

    private func makePanel(
        title: String,
        initialSize: CGSize,
        aspectRatio: CGSize?,
        minSize: CGSize
    ) -> PinnedImagePanel {
        let panel = PinnedImagePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
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
        if let aspectRatio {
            panel.contentAspectRatio = aspectRatio
        }
        panel.contentMinSize = minSize
        panel.delegate = self
        return panel
    }

    private func install(_ view: some View, in panel: PinnedImagePanel) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Theme.Radius.panel
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
    }

    private func present(
        _ panel: PinnedImagePanel,
        size: CGSize,
        in visibleFrame: CGRect,
        itemID: ClipboardItem.ID
    ) {
        let finalFrame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.alphaValue = 0
        panel.setFrame(Self.scaledFrame(finalFrame, scale: 0.96), display: false)
        panels[itemID] = panel
        if hidesForExclusiveFullScreen(panel) {
            panel.setFrame(finalFrame, display: false)
            applyVisibleAlpha(to: panel)
            hideForFullscreen(itemID, panel)
            return
        }
        activate(panel)
        panel.ignoresMouseEvents = visibleAlpha <= 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = visibleAlpha
            panel.animator().setFrame(finalFrame, display: true)
        }
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
            guard !closingPanels.contains(itemID) else { continue }
            if hidesForExclusiveFullScreen(panel) {
                hideForFullscreen(itemID, panel)
            } else if hiddenForFullscreen.remove(itemID) != nil {
                applyVisibleAlpha(to: panel)
                panel.orderFrontRegardless()
            }
        }
    }

    private func hideForFullscreen(_ itemID: ClipboardItem.ID, _ panel: PinnedImagePanel) {
        hiddenForFullscreen.insert(itemID)
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func hidesForExclusiveFullScreen(_ panel: PinnedImagePanel) -> Bool {
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

    private static func scaledFrame(_ frame: NSRect, scale: CGFloat) -> NSRect {
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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

/// Pure sizing policy kept separate from AppKit window ownership so unusual image ratios and
/// multi-display bounds remain deterministic.
enum PinnedImageLayout {
    static func initialSize(
        imageSize: CGSize,
        visibleFrame: CGRect,
        preferredLongEdge: CGFloat
    ) -> CGSize {
        let natural = normalized(imageSize)
        let maxSize = CGSize(
            width: max(visibleFrame.width - 24, 1),
            height: max(visibleFrame.height - 24, 1)
        )
        let preferredScale = max(preferredLongEdge, 1) / max(natural.width, natural.height)
        let screenScale = min(maxSize.width / natural.width, maxSize.height / natural.height)
        let scale = max(min(preferredScale, screenScale, 1), 0.001)
        return rounded(CGSize(width: natural.width * scale, height: natural.height * scale))
    }

    static func minimumSize(imageSize: CGSize, visibleFrame: CGRect) -> CGSize {
        let natural = normalized(imageSize)
        let longSideScale = 160 / max(natural.width, natural.height)
        // The 28-point close control has 10-point card insets on both sides. Never let either
        // image dimension fall below 48 points, even for extreme panoramas or long screenshots.
        let shortSideScale = 48 / min(natural.width, natural.height)
        let desiredScale = max(longSideScale, shortSideScale)
        let displayScale = min(
            visibleFrame.width * 0.9 / natural.width,
            visibleFrame.height * 0.9 / natural.height
        )
        let scale = max(min(desiredScale, displayScale), 0.001)
        return rounded(CGSize(width: natural.width * scale, height: natural.height * scale))
    }

    private static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    private static func rounded(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))
    }
}
