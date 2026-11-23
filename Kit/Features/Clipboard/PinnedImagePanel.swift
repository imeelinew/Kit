import AppKit
import Carbon.HIToolbox

final class PinnedImagePanel: NSPanel {
    enum PointerTarget: Equatable {
        case closeButton, move, resize(PinnedImageResizeEdge)
    }

    var onClose: (() -> Void)?
    var geometry: PinnedImageGeometry?
    private var appliedFrame: CGRect?
    private var resize: (edge: PinnedImageResizeEdge, frame: CGRect, pointer: CGPoint)?
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

    var resizeBounds: CGRect {
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
        if handlePointer(event) { return }
        if geometry != nil, event.type == .magnify {
            zoom(by: event.magnification)
            return
        }
        super.sendEvent(event)
        // Apply after hosting dispatch so SwiftUI cannot replace the edge cursor with its arrow
        if event.type == .mouseMoved || event.type == .leftMouseUp || event.type == .cursorUpdate {
            updateResizeCursor(at: event.locationInWindow)
        }
    }

    func pointerTarget(at location: CGPoint) -> PointerTarget? {
        guard let contentView else { return nil }
        let point = contentView.convert(location, from: nil)
        let bounds = contentView.bounds
        // Hosting coordinates are flipped, resize geometry uses a lower-left origin
        let local = CGPoint(x: point.x - bounds.minX,
                            y: contentView.isFlipped ? bounds.maxY - point.y : point.y - bounds.minY)
        let rect = CGRect(origin: .zero, size: bounds.size)
        guard rect.contains(local) else { return nil }
        let close = CGRect(x: 10, y: rect.maxY - 38, width: 28, height: 28)
        if close.contains(local) { return .closeButton }
        if let edge = PinnedImageResizeEdge.hit(at: local, in: rect) { return .resize(edge) }
        return .move
    }

    private func handlePointer(_ event: NSEvent) -> Bool {
        // Route drags before AppKit hit testing so hosted text and scrollbars cannot consume them
        switch event.type {
        case .leftMouseDown:
            guard let target = pointerTarget(at: event.locationInWindow) else { return false }
            switch target {
            case .closeButton:
                return false
            case .move:
                performDrag(with: event)
            case .resize(let edge):
                makeKeyAndOrderFront(nil)
                resize = (edge, frame, convertPoint(toScreen: event.locationInWindow))
            }
        case .leftMouseDragged:
            guard let resize else { return false }
            let pointer = convertPoint(toScreen: event.locationInWindow)
            let delta = CGSize(width: pointer.x - resize.pointer.x, height: pointer.y - resize.pointer.y)
            let proposed: CGRect
            if let geometry {
                proposed = resize.edge.frame(from: resize.frame, delta: delta,
                                             minimum: geometry.minimumFrameSize, visible: resizeBounds)
            } else {
                proposed = resize.edge.freeFrame(from: resize.frame, delta: delta,
                                                 minimum: minSize, visible: resizeBounds)
            }
            setFrame(proposed, display: true)
            geometry?.adopt(proposed)
        case .leftMouseUp:
            guard resize != nil else { return false }
            resize = nil
            fitToScreen()
            updateResizeCursor(at: event.locationInWindow)
        default:
            return false
        }
        return true
    }

    private func updateResizeCursor(at location: CGPoint) {
        guard case .resize(let edge) = pointerTarget(at: location) else {
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

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_W),
            event.modifierFlags.intersection(Self.commandModifiers) == .command
        else { return false }
        if !event.isARepeat { onClose?() }
        return true
    }
}
