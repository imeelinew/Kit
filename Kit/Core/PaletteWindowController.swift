import AppKit
import Combine
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var panel: PalettePanel?
    private var panelStyle: PaletteVisualStyle?
    private var styleObserver: AnyCancellable?
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

    func show() {
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
        guard let finalFrame = positionedFrame() else { return }
        panel.alphaValue = 1
        panel.setFrame(finalFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.selectEnglish()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        panel.orderFrontRegardless()
        panel.requestSearchFocus()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else {
                return
            }
            panel.makeKeyAndOrderFront(nil)
            panel.requestSearchFocus()
        }
    }

    func hide(restoreFocus: Bool) {
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
        let visible = isVisible
        panel?.orderOut(nil)
        panel = nil
        panelStyle = nil
        if visible { show() }
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
