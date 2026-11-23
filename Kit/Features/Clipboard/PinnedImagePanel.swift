import AppKit
import Carbon.HIToolbox

final class PinnedImagePanel: NSPanel {
    var onClose: (() -> Void)?
    var geometry: PinnedImageGeometry?
    private var appliedFrame: CGRect?
    private static let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func zoom(by delta: CGFloat) {
        fitToScreen()
        geometry?.zoom(by: delta, visibleFrame: visibleFrame)
        applyGeometry()
    }

    func fitToScreen() {
        guard var geometry else {
            let bounds = resizeBounds
            let size = CGSize(width: min(frame.width, bounds.width), height: min(frame.height, bounds.height))
            minSize = CGSize(width: min(PinnedTextContent.minimumSize.width, bounds.width),
                             height: min(PinnedTextContent.minimumSize.height, bounds.height))
            let fitted = CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - size.width),
                                y: min(max(frame.minY, bounds.minY), bounds.maxY - size.height),
                                width: size.width, height: size.height)
            if fitted != frame { setFrame(fitted, display: true) }
            return
        }
        // Adopt native edge resizing before applying the shared gesture sizing policy
        if frame.size != geometry.frame.size {
            geometry.adopt(frame)
        }
        // Window Server drags are asynchronous and may not deliver mouseUp. Adopt the actual
        // position before the next sizing action, while retaining the exact zoom center otherwise.
        let movedCenter = frame != appliedFrame ? CGPoint(x: frame.midX, y: frame.midY) : nil
        geometry.fit(visibleFrame: visibleFrame, movedCenter: movedCenter)
        self.geometry = geometry
        applyGeometry()
    }

    private var visibleFrame: CGRect {
        screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
    }

    private var resizeBounds: CGRect {
        let visible = visibleFrame
        let inset = min(12, max(0, (min(visible.width, visible.height) - 1) / 2))
        return visible.insetBy(dx: inset, dy: inset)
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handleShortcut(event) { return }
        if event.type == .leftMouseDown, isDragRegion(at: event.locationInWindow) {
            performDrag(with: event)
            return
        }
        if geometry != nil, event.type == .magnify {
            zoom(by: event.magnification)
            return
        }
        super.sendEvent(event)
    }

    private func isDragRegion(at location: CGPoint) -> Bool {
        guard let contentView else { return false }
        let point = contentView.convert(location, from: nil)
        let bounds = contentView.bounds
        // Measure the close button from the top in either hosting coordinate system
        let local = CGPoint(x: point.x - bounds.minX,
                            y: contentView.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
        let close = CGRect(x: 10, y: 10, width: 28, height: 28)
        return bounds.contains(point) && !close.contains(local)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_W),
            event.modifierFlags.intersection(Self.commandModifiers) == .command
        else { return false }
        if !event.isARepeat { onClose?() }
        return true
    }
}
