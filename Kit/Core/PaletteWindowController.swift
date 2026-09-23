import AppKit
import Combine
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private enum Motion {
        static let showDuration: TimeInterval = 0.15
        static let hideDuration: TimeInterval = 0.10
        static let insetScale: CGFloat = 0.985
    }

    private unowned let core: AppCore
    private var panel: PalettePanel?
    private var panelStyle: PaletteVisualStyle?
    private var styleObserver: AnyCancellable?
    private var showToken = 0
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
        showToken += 1
        let token = showToken
        let wasHiding = hiding
        hiding = false
        guard let finalFrame = positionedFrame() else { return }
        let continuingPresentation = panel.isVisible && !wasHiding
        let alreadyShown = continuingPresentation && panel.allowsHoverSelection
        if !alreadyShown {
            panel.allowsHoverSelection = false
        }
        if !continuingPresentation {
            panel.alphaValue = 0
            panel.setFrame(Self.scaledFrame(finalFrame, scale: Motion.insetScale), display: false)
        } else if alreadyShown {
            panel.setFrame(finalFrame, display: false)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.selectEnglish()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        panel.orderFrontRegardless()
        panel.requestSearchFocus()
        if !alreadyShown {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.showDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.86, 0.24, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, let panel, token == self.showToken, !self.hiding,
                        panel.isVisible
                    else { return }
                    panel.allowsHoverSelection = true
                }
            }
        }
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow, token == self.showToken else {
                return
            }
            panel.makeKeyAndOrderFront(nil)
            panel.requestSearchFocus()
        }
    }

    func hide(restoreFocus: Bool) {
        guard let panel else { return }
        if !panel.isVisible && !hiding {
            ImageThumbnail.purgePreviews()
            if restoreFocus { previousApp?.activate() }
            return
        }
        if hiding { return }
        hiding = true
        panel.allowsHoverSelection = false
        let token = showToken
        if core.settings.switchToEnglishInputOnOpen {
            InputSourceSwitcher.restore()
        }
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.hideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.84, 0.45)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(Self.scaledFrame(frame, scale: Motion.insetScale), display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, token == self.showToken, self.hiding else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.hiding = false
                ImageThumbnail.purgePreviews()
                if restoreFocus { self.previousApp?.activate() }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, modalAlertDepth == 0 else { return }
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
        let root = RootPaletteView()
            .environmentObject(core)
            .environmentObject(core.palette)
            .environmentObject(core.clipboardStore)
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

    private static func scaledFrame(_ frame: NSRect, scale: CGFloat) -> NSRect {
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
