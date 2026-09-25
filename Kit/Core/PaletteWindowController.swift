import AppKit
import Combine
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var panel: PalettePanel?
    private var panelStyle: PaletteVisualStyle?
    private var styleObserver: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var presentationID = UUID()
    private(set) var isPresenting = false
    private var hiding = false
    private var modalAlertDepth = 0
    private(set) var previousApp: NSRunningApplication?

    init(core: AppCore) {
        self.core = core
        super.init()
        styleObserver = core.settings.$paletteVisualStyle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildPanelForStyleChange()
            }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    var pasteTargetApp: NSRunningApplication? {
        guard let previousApp, !previousApp.isTerminated else { return nil }
        return previousApp
    }

    /// Build the hosting tree while the app is idle, before the first shortcut.
    func prewarm() {
        let panel = ensurePanel()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func show() {
        guard !isPresenting else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost.flatMap { app in
            app.processIdentifier != NSRunningApplication.current.processIdentifier
                && !app.isTerminated ? app : nil
        }
        let target = PasteTarget(app: previousApp)
        core.palette.pasteTarget = target
        if let path = target?.iconPath {
            _ = IconCache.icon(forFile: path)
        }

        let panel = ensurePanel()
        let request = UUID()
        presentationID = request
        isPresenting = true
        presentationTask = Task { [weak self, weak panel] in
            guard let self, let panel else { return }
            await core.palette.prepare()
            guard !Task.isCancelled, presentationID == request else { return }
            guard let finalFrame = positionedFrame() else {
                isPresenting = false
                presentationTask = nil
                return
            }
            panel.beginPresentation()
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: false)
            // Commit the complete selection, preview and footer while still offscreen.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            if core.settings.switchToEnglishInputOnOpen {
                InputSourceSwitcher.selectEnglish()
            }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            panel.requestSearchFocus()
            isPresenting = false
            presentationTask = nil
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, presentationID == request,
                    let panel, panel.isVisible, !panel.isKeyWindow
                else { return }
                panel.makeKeyAndOrderFront(nil)
                panel.requestSearchFocus()
            }
        }
    }

    func hide(restoreFocus: Bool) {
        presentationID = UUID()
        presentationTask?.cancel()
        presentationTask = nil
        isPresenting = false
        guard let panel else { return }
        if !panel.isVisible {
            ImageThumbnail.purgePreviews()
            if restoreFocus { previousApp?.activate() }
            return
        }
        if hiding { return }
        hiding = true
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.restore()
        }
        panel.orderOut(nil)
        hiding = false
        ImageThumbnail.purgePreviews()
        core.palette.prepareForNextPresentation()
        if restoreFocus { previousApp?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !hiding, modalAlertDepth == 0 else { return }
        core.hidePalette(restoreFocus: false)
    }

    /// The delete confirmation takes key focus. Keep the palette up until that alert closes.
    func runModalAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        modalAlertDepth += 1
        let response = alert.runModal()
        modalAlertDepth = max(0, modalAlertDepth - 1)
        if let panel, panel.isVisible, !hiding {
            panel.makeKeyAndOrderFront(nil)
        }
        return response
    }

    private func ensurePanel() -> PalettePanel {
        let style = core.settings.paletteVisualStyle
        if let panel, panelStyle == style { return panel }
        panel?.orderOut(nil)
        let root = RootPaletteView(vm: core.palette, store: core.clipboardStore)
        let panel = PalettePanel(rootView: root, visualStyle: style)
        panel.delegate = self
        panel.paletteViewModel = core.palette
        self.panel = panel
        panelStyle = style
        return panel
    }

    private func rebuildPanelForStyleChange() {
        guard panel != nil else { return }
        let visible = isVisible || isPresenting
        presentationID = UUID()
        presentationTask?.cancel()
        presentationTask = nil
        isPresenting = false
        panel?.orderOut(nil)
        panel = nil
        panelStyle = nil
        if visible {
            show()
        } else {
            prewarm()
        }
    }

    private func positionedFrame() -> NSRect? {
        guard let screen = targetScreen() else { return nil }
        let visible = screen.visibleFrame
        let width = min(Theme.Size.panelWidth, max(1, visible.width - 32))
        let height = min(Theme.Size.panelHeight, max(1, visible.height - 32))
        let topEdge = visible.maxY - visible.height * Theme.Size.paletteTopMarginFraction
        return NSRect(
            x: visible.midX - width / 2,
            y: topEdge - height,
            width: width,
            height: height)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
