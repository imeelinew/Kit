import AppKit
import Carbon.HIToolbox

final class PinnedImagePanel: NSPanel {
    var onClose: (() -> Void)?
    var geometry: PinnedImageGeometry?
    private var appliedFrame: CGRect?

    func zoom(by delta: CGFloat) {
        fitToScreen()
        geometry?.zoom(by: delta, visibleFrame: visibleFrame)
        applyGeometry()
    }

    func resetSize() {
        fitToScreen()
        geometry?.reset(visibleFrame: visibleFrame)
        applyGeometry()
    }

    func fitToScreen() {
        // Window Server drags are asynchronous and may not deliver mouseUp. Adopt the actual
        // position before the next sizing action, while retaining the exact zoom center otherwise.
        let movedCenter = frame != appliedFrame ? CGPoint(x: frame.midX, y: frame.midY) : nil
        geometry?.fit(visibleFrame: visibleFrame, movedCenter: movedCenter)
        applyGeometry()
    }

    private var visibleFrame: CGRect {
        screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
    }

    private func applyGeometry() {
        guard let geometry else { return }
        if frame != geometry.frame {
            setFrame(geometry.frame, display: true)
            contentView?.layoutSubtreeIfNeeded()
        }
        appliedFrame = frame
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if isCloseShortcut(event) {
                if !event.isARepeat {
                    onClose?()
                }
                return
            }
        }
        if event.type == .magnify {
            zoom(by: event.magnification)
            return
        }
        super.sendEvent(event)
    }

    private func isCloseShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_ANSI_W)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }
}
