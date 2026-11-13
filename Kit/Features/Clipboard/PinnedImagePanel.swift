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

    func fitToScreen() {
        // Adopt native edge resizing before applying the shared gesture sizing policy
        if let geometry, frame.size != geometry.frame.size {
            self.geometry?.adopt(frame)
        }
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
        // Apply after hosting dispatch so SwiftUI cannot replace the edge cursor with its arrow
        if event.type == .mouseMoved || event.type == .leftMouseUp {
            updateResizeCursor(at: event.locationInWindow)
        }
    }

    func updateResizeCursor(at location: CGPoint) {
        guard let contentView else { return }
        let point = contentView.convert(location, from: nil)
        let bounds = contentView.bounds
        // Hosting coordinates are flipped, resize geometry uses a lower-left origin
        let local = CGPoint(x: point.x - bounds.minX,
                            y: contentView.isFlipped ? bounds.maxY - point.y : point.y - bounds.minY)
        let rect = CGRect(origin: .zero, size: bounds.size)
        guard rect.contains(local) else { return }
        let close = CGRect(x: 10, y: rect.maxY - 38, width: 28, height: 28)
        guard !close.contains(local), let edge = PinnedImageResizeEdge.hit(at: local, in: rect) else {
            NSCursor.arrow.set()
            return
        }
        let position: NSCursor.FrameResizePosition
        switch (edge.x, edge.y) {
        case (-1, -1): position = .bottomLeft
        case (-1, 1): position = .topLeft
        case (1, -1): position = .bottomRight
        case (1, 1): position = .topRight
        case (-1, _): position = .left
        case (1, _): position = .right
        case (_, -1): position = .bottom
        default: position = .top
        }
        NSCursor.frameResize(position: position, directions: .all).set()
    }

    private func isCloseShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_ANSI_W)
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }
}
