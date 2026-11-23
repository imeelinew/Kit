import AppKit
import Carbon.HIToolbox

final class PinnedImagePanel: NSPanel {
    enum PointerTarget: Equatable {
        case closeButton, move, resize(PinnedResizeEdge)
    }

    var onClose: (() -> Void)?
    var geometry: PinnedImageGeometry?
    private var appliedFrame: CGRect?
    private var cursorEdge: PinnedResizeEdge?
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
        // Adopt edge resizing before applying the shared gesture sizing policy
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

    override var contentView: NSView? {
        didSet { installPointerTracking() }
    }

    override func sendEvent(_ event: NSEvent) {
        if handleShortcut(event) { return }
        if event.type == .leftMouseDown, let target = pointerTarget(at: event.locationInWindow) {
            switch target {
            case .closeButton:
                break
            case .move:
                performDrag(with: event)
                return
            case .resize(let edge):
                trackResize(edge)
                return
            }
        }
        if geometry != nil, event.type == .magnify {
            zoom(by: event.magnification)
            return
        }
        super.sendEvent(event)
        // Apply after hosting dispatch so SwiftUI cannot replace the edge cursor
        switch event.type {
        case .mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseUp:
            updateCursor(at: event.locationInWindow)
        case .mouseExited:
            updateCursor(at: nil)
        default:
            break
        }
    }

    func pointerTarget(at location: CGPoint) -> PointerTarget? {
        guard let contentView else { return nil }
        let point = contentView.convert(location, from: nil)
        let bounds = contentView.bounds
        // Resize geometry uses a lower-left origin in either hosting coordinate system
        let local = CGPoint(x: point.x - bounds.minX,
                            y: contentView.isFlipped ? bounds.maxY - point.y : point.y - bounds.minY)
        let rect = CGRect(origin: .zero, size: bounds.size)
        guard rect.contains(local) else { return nil }
        let close = CGRect(x: 10, y: rect.maxY - 38, width: 28, height: 28)
        if close.contains(local) { return .closeButton }
        if let edge = PinnedResizeEdge.hit(at: local, in: rect) { return .resize(edge) }
        return .move
    }

    /// Synchronous tracking owns every drag event until mouse up, so neither SwiftUI nor the
    /// Window Server can turn an edge press into a click-through or a window move.
    private func trackResize(_ edge: PinnedResizeEdge) {
        makeKeyAndOrderFront(nil)
        let start = frame
        let pointer = NSEvent.mouseLocation
        // Include the start frame so a card partly outside the display never collapses
        let limit = resizeBounds.union(start)
        let minimum = geometry?.minimumFrameSize ?? minSize
        let cursor = NSCursor.frameResize(position: edge.cursorPosition, directions: .all)
        cursor.push()
        defer {
            NSCursor.pop()
            fitToScreen()
            updateCursor(at: mouseLocationOutsideOfEventStream)
        }
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
            event.type == .leftMouseDragged
        {
            let current = NSEvent.mouseLocation
            let delta = CGSize(width: current.x - pointer.x, height: current.y - pointer.y)
            let proposed = geometry != nil
                ? edge.frame(from: start, delta: delta, minimum: minimum, visible: limit)
                : edge.freeFrame(from: start, delta: delta, minimum: minimum, visible: limit)
            if proposed != frame {
                setFrame(proposed, display: true)
                cursor.set()
            }
        }
    }

    private func installPointerTracking() {
        guard let contentView else { return }
        // Window-owned tracking delivers hover events even while another app is active
        contentView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    private func updateCursor(at location: CGPoint?) {
        let edge: PinnedResizeEdge?
        if let location, case .resize(let hit) = pointerTarget(at: location) {
            edge = hit
        } else {
            edge = nil
        }
        if let edge {
            NSCursor.frameResize(position: edge.cursorPosition, directions: .all).set()
        } else if cursorEdge != nil {
            NSCursor.arrow.set()
        }
        cursorEdge = edge
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_W),
            event.modifierFlags.intersection(Self.commandModifiers) == .command
        else { return false }
        if !event.isARepeat { onClose?() }
        return true
    }
}
