import AppKit
import QuartzCore

/// The scroll destination, indicator and edge mask share one AppKit lifecycle
class KitScrollView: NSScrollView {
    var edgeDissolve: EdgeDissolve = .none { didSet { updateScrollAppearance() } }
    private let indicator = ThinScrollbarView()
    private let edgeMask = CAGradientLayer()
    private var boundsObserver: NotificationToken?
    private var documentObserver: NotificationToken?
    private var styleObserver: NotificationToken?
    private var previousOffset: CGFloat?

    /// AppKit reads documentView from its concurrent scrolling queue
    /// Keep the inherited getter free of Swift actor isolation checks
    func installDocumentView(_ view: NSView) {
        documentObserver = nil
        documentView = view
        view.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollAppearance() }
        }
        documentObserver = NotificationToken(token, center: .default)
        updateScrollAppearance()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false
        contentView.wantsLayer = true
        contentView.postsBoundsChangedNotifications = true
        indicator.scrollView = self
        addSubview(indicator)
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScrollAppearance() }
        }
        boundsObserver = NotificationToken(token, center: .default)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        indicator.frame = bounds
        updateScrollAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            styleObserver = nil
            previousOffset = nil
            indicator.reset()
            return
        }
        if styleObserver == nil {
            let token = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.hideSystemScrollers() }
            }
            styleObserver = NotificationToken(token, center: .default)
        }
        hideSystemScrollers()
        updateScrollAppearance()
    }

    private func hideSystemScrollers() {
        guard scrollerStyle != .overlay || !autohidesScrollers || hasVerticalScroller else { return }
        scrollerStyle = .overlay
        autohidesScrollers = true
        hasVerticalScroller = false
        tile()
    }

    func updateScrollAppearance() {
        let viewport = contentView.bounds.height
        let content = (documentView?.frame.height ?? 0) + contentInsets.top + contentInsets.bottom
        let maximum = max(0, content - viewport)
        let offset = min(maximum, max(0, contentView.bounds.minY + contentInsets.top))
        let moved = previousOffset.map { $0 != offset } ?? false
        previousOffset = offset
        indicator.update(content: content, viewport: viewport, offset: offset, moved: moved)
        edgeDissolve.apply(to: contentView, mask: edgeMask, content: content)
    }

    func scroll(toFraction fraction: CGFloat) {
        let clip = contentView
        var probe = clip.bounds
        probe.origin.y = -1_000_000_000
        let minimum = clip.constrainBoundsRect(probe).origin.y
        probe.origin.y = 1_000_000_000
        let maximum = clip.constrainBoundsRect(probe).origin.y
        var origin = clip.bounds.origin
        origin.y = minimum + min(1, max(0, fraction)) * (maximum - minimum)
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}

private final class ThinScrollbarView: NSView {
    weak var scrollView: KitScrollView?
    private let rail = CALayer()
    private let thumb = CALayer()
    private var content: CGFloat = 0
    private var viewport: CGFloat = 0
    private var offset: CGFloat = 0
    private var scrolling = false
    private var hovering = false
    private var inZone = false
    private var dragStart: (pointerY: CGFloat, fraction: CGFloat)?
    private var scrollStop: DispatchWorkItem?
    private var hoverExit: DispatchWorkItem?
    private let inset: CGFloat = 3
    private let hoverZone: CGFloat = 16
    private var scrollable: Bool { content > viewport + 1 }
    private var dragging: Bool { dragStart != nil }
    private var expanded: Bool { hovering || dragging }
    private var visible: Bool { scrolling || hovering || dragging }
    private var track: CGFloat { max(0, viewport - inset * 2) }
    private var thumbHeight: CGFloat { min(track, max(28, content > 0 ? track * viewport / content : 28)) }
    private var travel: CGFloat { max(0, track - thumbHeight) }
    private var fraction: CGFloat { min(1, max(0, offset / max(1, content - viewport))) }
    private var thumbY: CGFloat { inset + fraction * travel }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(rail)
        layer?.addSublayer(thumb)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(content: CGFloat, viewport: CGFloat, offset: CGFloat, moved: Bool) {
        self.content = content
        self.viewport = viewport
        self.offset = offset
        if moved {
            let wasVisible = visible
            scrolling = true
            scheduleScrollStop()
            updateLayers(animation: wasVisible ? nil : .fade)
        } else {
            updateLayers()
        }
    }

    func reset() {
        scrollStop?.cancel()
        hoverExit?.cancel()
        scrolling = false
        hovering = false
        inZone = false
        dragStart = nil
        rail.removeAllAnimations()
        thumb.removeAllAnimations()
        updateLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers()
    }

    private enum Motion { case fade, morph }

    private func updateLayers(animation: Motion? = nil) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let width: CGFloat = expanded ? 8 : 4
            let railRect = CGRect(x: bounds.width - inset - 8, y: inset, width: 8, height: track)
            let thumbRect = CGRect(x: bounds.width - inset - 4 - width / 2, y: thumbY,
                                   width: width, height: thumbHeight)
            set(rail, frame: railRect, opacity: scrollable && expanded ? 1 : 0,
                color: NSColor.labelColor.withAlphaComponent(0.05).cgColor, animation: animation)
            set(thumb, frame: thumbRect, opacity: scrollable && visible ? 1 : 0,
                color: NSColor.labelColor.withAlphaComponent(dragging ? 0.38 : (expanded ? 0.28 : 0.18)).cgColor,
                animation: animation)
        }
    }

    private func set(_ layer: CALayer, frame: CGRect, opacity: Float, color: CGColor, animation: Motion?) {
        let targets: [(String, Any)] = [
            ("bounds.size.width", frame.width), ("position.x", frame.midX),
            ("cornerRadius", frame.width / 2), ("opacity", opacity), ("backgroundColor", color)]
        let presentation = layer.presentation() ?? layer
        let starts = targets.map { presentation.value(forKeyPath: $0.0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = frame.width / 2
        layer.opacity = opacity
        layer.backgroundColor = color
        CATransaction.commit()
        guard let animation else { return }
        for (index, target) in targets.enumerated() {
            let change: CABasicAnimation
            if animation == .morph {
                let spring = CASpringAnimation(keyPath: target.0)
                let frequency = 2 * CGFloat.pi / 0.28
                spring.mass = 1
                spring.stiffness = frequency * frequency
                spring.damping = 2 * 0.85 * frequency
                spring.duration = spring.settlingDuration
                change = spring
            } else {
                change = CABasicAnimation(keyPath: target.0)
                change.duration = 0.18
                change.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            change.fromValue = starts[index]
            change.toValue = target.1
            layer.add(change, forKey: target.0)
        }
    }

    private func scheduleScrollStop() {
        scrollStop?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            scrolling = false
            updateLayers(animation: .fade)
        }
        scrollStop = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type != .scrollWheel, scrollable, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x >= bounds.width - hoverZone else { return nil }
        return expanded || (visible && (thumbY...(thumbY + thumbHeight)).contains(local.y)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard travel > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        var target = fraction
        if !(thumbY...(thumbY + thumbHeight)).contains(point.y) {
            target = min(1, max(0, (point.y - thumbHeight / 2 - inset) / travel))
        }
        dragStart = (point.y, target)
        scrollStop?.cancel()
        updateLayers(animation: .morph)
        scrollView?.scroll(toFraction: target)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, travel > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        scrollView?.scroll(toFraction: dragStart.fraction + (point.y - dragStart.pointerY) / travel)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragStart = nil
        scrolling = true
        scheduleScrollStop()
        updateLayers(animation: .morph)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { updateZone(false) }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateZone(bounds.contains(point) && point.x >= bounds.width - hoverZone)
    }

    private func updateZone(_ inside: Bool) {
        guard inside != inZone else { return }
        inZone = inside
        hoverExit?.cancel()
        if inside {
            hovering = true
            updateLayers(animation: .morph)
        } else {
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hovering = false
                updateLayers(animation: .morph)
            }
            hoverExit = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
        }
    }
}
